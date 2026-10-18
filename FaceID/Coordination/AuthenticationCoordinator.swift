//
//  AuthenticationCoordinator.swift
//  Face ID
//
//  The app-lock authentication ladder: face → Touch ID → app password.
//
//  Replaces FaceGate's `AuthenticationManager`. What changed and why:
//  • Combine + `ObservableObject` → Swift Observation, matching the rest of the app.
//  • It no longer owns a `FaceAuthManager`. Face recognition is the *same*
//    `FaceRecognitionPipeline` the lock-screen path uses, driven by the same
//    `CameraManager` — one enrollment store, one model, one threshold. Two
//    independent face stacks in one binary was the main thing this merge set out
//    to remove.
//  • Presentation is injected (`AppLockChallengePresenting`) rather than reached
//    for. The lock-screen path can afford to call `NotchOverlayController.shared`
//    directly because it is the only consumer; here the ladder has to be usable
//    from the coordinator that owns the shield and the password prompt too.
//  • The failure/lockout arithmetic lives in `AttemptLedger`, away from the camera
//    and the UI, so it can be tested directly.
//
//  This type deliberately does *not* decide what happens to a locked app on
//  failure — that is `AppUnlockCoordinator`'s call. It reports an outcome and stops.
//

import AppKit
import CoreGraphics
import Foundation
import Observation

// MARK: - Method & outcome

/// One rung of the ladder.
nonisolated enum AuthenticationMethod: String, CaseIterable, Identifiable {
    case face
    case touchID
    case appPassword

    var id: String { rawValue }

    var title: String {
        switch self {
        case .face: return "人脸识别"
        case .touchID: return "触控 ID"
        case .appPassword: return "应用密码"
        }
    }
}

/// How one full pass over the ladder ended.
nonisolated enum AuthenticationOutcome: Equatable {
    /// Verified. The caller restores the app.
    case success

    /// The user explicitly gave up — Esc on the shield, or a face attempt aborted
    /// by a higher-priority camera holder. The caller ends the app.
    case cancelled

    /// Every rung was tried and none succeeded. The app stays blocked and the
    /// challenge stays on screen; a hover starts another pass.
    ///
    /// This exists so a bad angle or an empty chair never costs the user their
    /// running app — only an explicit cancel does.
    case retryable

    /// Too many consecutive failures. Cleared automatically after the lockout window.
    case lockedOut(remaining: TimeInterval)
}

// MARK: - Attempt accounting

/// Failed-attempt accounting, isolated from the camera and the UI so the lockout
/// arithmetic can be exercised without either.
///
/// A *timeout* (nobody in frame) is deliberately not recorded as a failure — only a
/// wrong face, a spoof rejection, a failed Touch ID read, or a wrong password are.
/// Otherwise walking away from the desk would lock the user out.
nonisolated struct AttemptLedger: Equatable {
    private(set) var failedAttempts = 0
    private(set) var lockedOutUntil: Date?

    var isLockedOut: Bool { lockedOutUntil != nil }

    /// Seconds left on the lockout, or `nil` when not locked out. An expired lockout
    /// is cleared here, so reading is what ends it.
    mutating func remainingLockout(now: Date = Date()) -> TimeInterval? {
        guard let until = lockedOutUntil else { return nil }
        let remaining = until.timeIntervalSince(now)
        guard remaining > 0 else {
            clear()
            return nil
        }
        return remaining
    }

    /// Records one failure.
    /// - Returns: `true` when this failure is what tripped the lockout.
    @discardableResult
    mutating func recordFailure(now: Date = Date()) -> Bool {
        failedAttempts += 1
        guard failedAttempts >= FIDConstants.maxFailedAttempts else { return false }
        lockedOutUntil = now.addingTimeInterval(FIDConstants.lockoutDuration)
        return true
    }

    /// Clears everything. The counter resets on any success, so five failures spread
    /// across a working day never compound into a lockout.
    mutating func recordSuccess() {
        clear()
    }

    private mutating func clear() {
        failedAttempts = 0
        lockedOutUntil = nil
    }
}

// MARK: - Presentation seam

/// Everything the ladder needs from the UI. Implemented by `AppUnlockCoordinator`
/// over the notch panel and the password prompt.
///
/// Kept as a protocol rather than a concrete type so the ladder never grows an
/// opinion about *where* the challenge is drawn — swapping the notch panel for a
/// plain window would be a change to the conformer alone.
@MainActor
protocol AppLockChallengePresenting: AnyObject {
    /// A face attempt has started — show the scan animation.
    func challengeDidBeginFaceScan()

    /// The face attempt resolved. `false` plays the failure animation; the ladder may
    /// still go on to Touch ID, so this is not the end of the challenge.
    func challengeDidFinishFaceScan(success: Bool)

    /// A human-readable line the UI can surface (wrong password, locked out, …).
    func challengeDidReport(_ message: String)

    /// Asks for the app password.
    /// - Returns: the entered password, or `nil` if the user dismissed the prompt.
    func challengeRequestPassword(appName: String, icon: NSImage?) async -> String?
}

// MARK: - Coordinator

@Observable
@MainActor
final class AuthenticationCoordinator {

    // No `shared`: this one owns a camera and a pipeline, and `AppEnvironment` is
    // where the app's singletons are assembled. Sitting on a `CameraArbiter.shared`
    // reference inside a static initializer would also put a main-actor-isolated
    // read in a place the compiler only tolerates, not welcomes.

    private let camera: CameraManager
    private let pipeline: FaceRecognitionPipeline
    private let cameraArbiter: CameraArbiter
    private let touchID: TouchIDAuth

    private(set) var ledger = AttemptLedger()
    private(set) var statusMessage = "Idle"
    /// Short description of the last successful verification, for diagnostics.
    private(set) var lastMethod: AuthenticationMethod?

    /// Bumped by every new face attempt. A superseded attempt notices at its next
    /// check and bails without touching the camera — `Task.cancel()` on its own is
    /// cooperative, so a cancelled attempt could otherwise still be mid-`start()` and
    /// leave a hot session behind for the next one.
    @ObservationIgnored private var faceAttemptToken = 0

    init(
        camera: CameraManager,
        pipeline: FaceRecognitionPipeline,
        cameraArbiter: CameraArbiter,
        touchID: TouchIDAuth
    ) {
        self.camera = camera
        self.pipeline = pipeline
        self.cameraArbiter = cameraArbiter
        self.touchID = touchID
    }

    // MARK: - Queries

    var isLockedOut: Bool { ledger.isLockedOut }

    /// Rungs the user can actually use right now, in ladder order.
    var availableMethods: [AuthenticationMethod] {
        var methods: [AuthenticationMethod] = []
        if FaceEnrollmentStore.shared.activeIdentities.isEmpty == false {
            methods.append(.face)
        }
        if touchID.canUse { methods.append(.touchID) }
        if AppPasswordAuth.isPasswordSet { methods.append(.appPassword) }
        return methods
    }

    // MARK: - Preemption

    /// Aborts any in-flight face attempt and hands the camera back.
    ///
    /// Called through `CameraArbiter`'s stopper when a higher-priority owner — the
    /// lock-screen scanner — needs the device. The ladder's own `acquire` check then
    /// makes the next rung run without a face scan rather than opening a second session.
    func cancelFaceAttempt() {
        faceAttemptToken &+= 1
        stopCapture()
    }

    // MARK: - Ladder

    /// Runs one full pass: face, then Touch ID, then the app password.
    ///
    /// - Parameter presenter: how to show and ask. `AppUnlockCoordinator` passes itself.
    func authenticate(
        app: AppLockContent,
        presenting presenter: AppLockChallengePresenting
    ) async -> AuthenticationOutcome {
        if let remaining = ledger.remainingLockout() {
            statusMessage = "尝试次数过多，请 \(formatted(remaining)) 后重试。"
            presenter.challengeDidReport(statusMessage)
            return .lockedOut(remaining: remaining)
        }

        // 1) Face. The primary path, and the only one that needs the camera.
        switch await attemptFace(presenting: presenter) {
        case .matched:
            return succeed(with: .face)
        case .aborted:
            return .cancelled
        case .wrongFace, .spoofSuspected:
            presenter.challengeDidFinishFaceScan(success: false)
            if let lockedOut = registerFailure(presenting: presenter) { return lockedOut }
        case .noFace:
            // Timeout, not a wrong guess — see `AttemptLedger`. Still resolved as a
            // failed attempt visually, because the scan did end without success.
            presenter.challengeDidFinishFaceScan(success: false)
            statusMessage = "没有检测到人脸。"
        case .spoofOnly:
            presenter.challengeDidFinishFaceScan(success: false)
            if let lockedOut = registerFailure(presenting: presenter) { return lockedOut }
        case .cameraBusy:
            statusMessage = "摄像头正被其他功能占用，跳过人脸验证。"
            presenter.challengeDidReport(statusMessage)
            // Not a failure: another part of the app legitimately holds the device.
        }

        if Task.isCancelled { return .cancelled }

        // 2) Touch ID. A system sheet, so there is nothing for us to draw.
        if touchID.canUse {
            let result = await touchID.authenticate(reason: "解锁「\(app.displayName)」")
            switch result {
            case .success:
                return succeed(with: .touchID)
            case .failure(.cancelled), .failure(.fallbackRequested):
                // The user backed out of the system sheet. Treat the whole pass as
                // over but not failed — popping the password prompt right after
                // someone declined biometrics is the opposite of what they asked for.
                statusMessage = "已取消触控 ID 验证。"
                presenter.challengeDidReport(statusMessage)
                return .retryable
            case .failure(let error):
                // `TouchIDError.localizedDescription` comes from `LocalizedError` and
                // is already a non-optional `String`.
                statusMessage = error.localizedDescription
                presenter.challengeDidReport(statusMessage)
                if let lockedOut = registerFailure(presenting: presenter) { return lockedOut }
            }
        }

        if Task.isCancelled { return .cancelled }

        // 3) App password. The only rung that can repeat within one pass — a typo
        //    shouldn't cost a whole round trip through the camera.
        if AppPasswordAuth.isPasswordSet {
            while true {
                guard let entered = await presenter.challengeRequestPassword(
                    appName: app.displayName,
                    icon: app.icon
                ) else {
                    // Dismissed without entering anything: the user neither passed nor
                    // failed, so the challenge stays open for another hover-driven pass.
                    statusMessage = "已取消密码输入。"
                    presenter.challengeDidReport(statusMessage)
                    return .retryable
                }

                if Task.isCancelled { return .cancelled }

                if AppPasswordAuth.verifyPassword(entered) {
                    return succeed(with: .appPassword)
                }

                statusMessage = "密码不正确。"
                presenter.challengeDidReport(statusMessage)
                if let lockedOut = registerFailure(presenting: presenter) { return lockedOut }
            }
        }

        statusMessage = "未能验证身份。"
        presenter.challengeDidReport(statusMessage)
        return .retryable
    }

    // MARK: - Face attempt

    private enum FaceAttempt {
        case matched
        case wrongFace
        case spoofSuspected
        case spoofOnly
        case noFace
        case cameraBusy
        /// A newer attempt (or a preemption) superseded this one.
        case aborted
    }

    /// Last failure worth surfacing in the password prompt, so a locked-out Touch ID
    /// hardware doesn't get silently re-presented as a password problem. Read by
    /// `AppUnlockCoordinator` when it opens the prompt.
    private(set) var lastFailureMessage: String?

    private func attemptFace(presenting presenter: AppLockChallengePresenting) async -> FaceAttempt {
        faceAttemptToken &+= 1
        let token = faceAttemptToken

        // No lease, no scan. Another holder at equal-or-higher priority refused to
        // yield, so skip the rung rather than open a second session on the device.
        guard cameraArbiter.acquire(.appLock) else {
            return Task.isCancelled ? .aborted : .cameraBusy
        }

        await camera.start()
        guard token == faceAttemptToken, !Task.isCancelled else { return .aborted }

        if let error = camera.errorMessage {
            statusMessage = error
            lastFailureMessage = error
            stopCapture()
            return .noFace
        }

        presenter.challengeDidBeginFaceScan()
        statusMessage = "正在识别人脸…"

        let outcome = await observeFaceWindow(token: token)
        guard token == faceAttemptToken, !Task.isCancelled else { return .aborted }

        stopCapture()
        return outcome
    }

    /// Stops capture and returns the device to the arbiter. Always paired with
    /// `cameraArbiter.acquire(.appLock)`; a no-op when the lease was already lost.
    private func stopCapture() {
        camera.stop()
        cameraArbiter.release(.appLock)
    }

    /// Mirrors `FaceUnlockCoordinator.observeScanWindow`, minus the password
    /// injection: recognition and liveness latch independently and the attempt
    /// succeeds the moment both land, otherwise it runs until the scan window ends.
    ///
    /// The window is anchored to the **first frame** rather than to this call. A cold
    /// `AVCaptureSession.startRunning()` takes 0.8–2 s, and every app-lock attempt is
    /// cold — so the old deadline was expiring before the camera had produced
    /// anything, which is why face would routinely hand over to Touch ID.
    private func observeFaceWindow(token: Int) async -> FaceAttempt {
        let livenessEnabled = FIDSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { FIDSettings.shared.livenessMode }

        let scanWindow = TimeInterval(FIDSettings.shared.faceDetectionSeconds)
        let hardDeadline = Date().addingTimeInterval(scanWindow + FIDConstants.cameraWarmupAllowance)
        /// Relaxed to `firstFrame + scanWindow` once frames arrive; never past `hardDeadline`.
        var deadline = hardDeadline
        var firstFrameAt: Date?

        var consecutiveWrongFaceFrames = 0
        var scoredFrames = 0
        /// When the streak first crossed the threshold — the clock for the early give-up.
        var wrongFaceSince: Date?
        var readyMatch: ScoredIdentity?
        var livenessConfirmed = !livenessEnabled
        var lastFaceBoundingBox: CGRect?
        var lastProcessedFrameID: UInt64?
        /// A deny cue fired but the face itself may not even have been scored yet —
        /// remembered so the attempt still reports a spoof rather than "no face".
        var sawDenial = false

        while Date() < deadline, !Task.isCancelled, token == faceAttemptToken {
            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            lastProcessedFrameID = frame.id

            if firstFrameAt == nil {
                firstFrameAt = Date()
                // Re-anchor: `scanWindow` seconds of frames, but never more than the
                // warm-up allowance on top of the original call.
                deadline = min(Date().addingTimeInterval(scanWindow), hardDeadline)
            }

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let analysed = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else {
                    return nil
                }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard token == faceAttemptToken, !Task.isCancelled else { return .aborted }

            guard let (result, livenessFrame) = analysed else {
                consecutiveWrongFaceFrames = 0
                // Restart the give-up clock too: the face left the frame entirely, so
                // whatever follows is a new attempt rather than a persisting mismatch.
                wrongFaceSince = nil
                lastFaceBoundingBox = nil
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Fed regardless of the match, so liveness stays an independent gate
            // rather than one starved by recognition confidence.
            if livenessEnabled {
                switch liveness.observe(livenessFrame).decision {
                case .denied:
                    sawDenial = true
                case .confirmed:
                    livenessConfirmed = true
                case .pending:
                    break
                }
            }

            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: FIDSettings.shared.matchThreshold)

            if let matched {
                consecutiveWrongFaceFrames = 0
                wrongFaceSince = nil
                scoredFrames += 1
                readyMatch = matched
            } else {
                // Cleared so a latched match can't be handed to whoever steps in next.
                readyMatch = nil
                scoredFrames += 1
                // The old code gave up after six consecutive frames — roughly 200 ms
                // at 30 fps, which is before a user who just looked up has settled
                // into frame. Wait out the grace period first, then require a real
                // streak, then let it persist before giving up.
                let pastGrace = firstFrameAt.map {
                    Date().timeIntervalSince($0) >= FIDConstants.wrongFaceGraceDuration
                } ?? false

                if pastGrace, scoredFrames >= FIDConstants.wrongFaceMinScoredFrames {
                    consecutiveWrongFaceFrames += 1
                    if consecutiveWrongFaceFrames >= FIDConstants.wrongFaceStreakThreshold {
                        if let since = wrongFaceSince {
                            if Date().timeIntervalSince(since) >= FIDConstants.wrongFaceAbortDuration {
                                return sawDenial ? .spoofSuspected : .wrongFace
                            }
                        } else {
                            wrongFaceSince = Date()
                        }
                    }
                }
            }

            if let readyMatch, livenessConfirmed {
                statusMessage = "已识别 \(readyMatch.identity.name)。"
                lastFailureMessage = nil
                return .matched
            }

            try? await Task.sleep(for: .milliseconds(20))
        }

        if Task.isCancelled || token != faceAttemptToken { return .aborted }
        if sawDenial { return .spoofOnly }
        // A streak that never resolved inside the window is still "someone else was
        // in frame", not "nobody was there".
        return wrongFaceSince != nil ? .wrongFace : .noFace
    }

    // MARK: - Failure plumbing

    /// Records a failure and turns a tripped lockout into an outcome.
    /// - Returns: the `.lockedOut` outcome, or `nil` when the pass may continue.
    private func registerFailure(presenting presenter: AppLockChallengePresenting) -> AuthenticationOutcome? {
        let tripped = ledger.recordFailure()
        guard tripped, let remaining = ledger.remainingLockout() else {
            lastFailureMessage = statusMessage
            return nil
        }
        statusMessage = "尝试次数过多，请 \(formatted(remaining)) 后重试。"
        presenter.challengeDidReport(statusMessage)
        return .lockedOut(remaining: remaining)
    }

    private func succeed(with method: AuthenticationMethod) -> AuthenticationOutcome {
        ledger.recordSuccess()
        lastFailureMessage = nil
        lastMethod = method
        statusMessage = "已通过\(method.title)验证。"
        return .success
    }

    /// Whole seconds, minimum 1 — `Int(0.4.rounded(.up)) == 1`, but a raw `0` would
    /// read as "retry now" while still being locked out.
    private func formatted(_ remaining: TimeInterval) -> String {
        "\(max(1, Int(remaining.rounded(.up)))) 秒"
    }
}
