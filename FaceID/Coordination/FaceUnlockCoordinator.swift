//
//  FaceUnlockCoordinator.swift
//  Face ID
//
//  Connects face recognition to the actual unlock path. Off by default; user opts in after validating accuracy in Face Lab.
//
//  Known limitation: LivenessAnalyzer defeats a photo but not a replayed video (real non-rigid motion looks live) — a successful spoof types the real macOS password.
//

import Foundation
import CoreGraphics
import Observation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()
    /// Only one feature may capture at a time — see `CameraArbiter`.
    private let cameraArbiter: CameraArbiter

    /// Persisted via FIDSettings. Setting to false cancels any in-flight scan and disarms the overlay immediately.
    var isEnabled: Bool {
        didSet {
            FIDSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { disarmOverlay() }
        }
    }

    /// Kept independent from Face Lab's own `threshold` so tuning the debug tool never silently changes the real unlock gate.
    var matchThreshold: Float {
        didSet { FIDSettings.shared.matchThreshold = matchThreshold }
    }
    /// Shares its setting with NotchOverlayController's scanning timeout, so the background loop stops in step with the UI collapsing.
    private var scanWindowDuration: TimeInterval {
        TimeInterval(FIDSettings.shared.faceDetectionSeconds)
    }
    /// Requires several consecutive below-threshold frames so a single bad-angle read doesn't trigger the failure animation.
    /// Shared with the app-lock ladder via `FIDConstants` so both paths fail at the same rate.
    private let wrongFaceStreakThreshold = FIDConstants.wrongFaceStreakThreshold

    private(set) var statusMessage = "空闲"
    private(set) var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    /// One-shot per lock session — an auto-retry that could itself auto-retry would loop the camera for the whole lock session.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle bails once superseded (see `runScanCycle(generation:)`).
    private var scanGeneration = 0
    /// Re-evaluates the trigger for a few seconds after a lock/wake event — see
    /// `scheduleTriggerEvaluation()`.
    private var triggerProbeTask: Task<Void, Never>?
    /// When the last scan cycle was armed — collapses a single wake into a single arm (see `.wake` branch of `evaluateTrigger`).
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms of each other; anything in this window counts as the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    /// Held separately from `scanTask` since it's scheduled from inside the scan task it follows — reusing `scanTask` would self-cancel it.
    private var autoRetryTask: Task<Void, Never>?
    /// Gap between headless auto-retries, just to keep the camera from restarting in a tight loop.
    private let headlessRetryDelay: Duration = .seconds(1)

    /// When off, no notch/pill presence at all — every overlay call in this file is conditioned on this rather than just skipping the video.
    private var showsUI: Bool { FIDSettings.shared.showUnlockAnimation }

    /// Reads the space key on the lock screen for the "On space" trigger; only runs while locked + opted in.
    private let spaceKeyMonitor = SpaceKeyMonitor()

    /// No default argument: `CameraArbiter.shared` is main-actor isolated, and a
    /// default argument is evaluated in a nonisolated context. Callers pass the
    /// instance they already hold (see `AppEnvironment`).
    init(pocController: POCController, cameraArbiter: CameraArbiter) {
        self.pocController = pocController
        self.cameraArbiter = cameraArbiter
        self.isEnabled = FIDSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = FIDSettings.shared.matchThreshold
        spaceKeyMonitor.onSpaceKeyDown = { [weak self] in self?.handleSpaceKeyPress() }
        // The lock-screen path outranks every other camera consumer, so in
        // practice this stopper is never invoked — registering it keeps the
        // arbiter's contract honest if priorities are ever reordered.
        cameraArbiter.register(.systemUnlock) { [weak self] in
            self?.disarmOverlay()
        }
        observeLockAndWakeEvents()
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            // Also tracked so screensaver-stop and display-only wakes still wake this up.
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLockAndWakeEvents()
                self?.scheduleTriggerEvaluation()
            }
        }
    }

    /// Re-probes the trigger for a few seconds instead of once.
    ///
    /// One probe ~300 ms after the wake notification is not enough. On lid-open the
    /// display comes back before the login window is drawn, so
    /// `CGSSessionScreenIsLocked` still reads `false` at that moment — and the
    /// `screenIsLocked` notification that would have retried already fired back when
    /// the lid closed, so nothing ever fires again. The scan then simply never arms,
    /// which is indistinguishable from "the feature is switched off".
    ///
    /// The loop stops as soon as a scan is armed, and is cheap otherwise (4 Hz).
    private func scheduleTriggerEvaluation() {
        triggerProbeTask?.cancel()
        triggerProbeTask = Task { [weak self] in
            // 24 × 250 ms ≈ 6 s — comfortably covers the login window's entrance.
            for probe in 0..<24 {
                guard let self, !Task.isCancelled else { return }
                self.lockMonitor.reconcileSleepState()

                if LockMonitor.isScreenActuallyLocked() {
                    self.evaluateTrigger()
                    if self.hasArmedForCurrentLock { return }
                } else if probe == 0 {
                    // Keep the original bookkeeping for the "still unlocked" case: it
                    // clears the one-shot guards and drops any stale overlay.
                    self.evaluateTrigger()
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func evaluateTrigger() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else { return }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear the one-shot guard.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard isEnabled, !hasArmedForCurrentLock else { return }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else { return }
        // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Main display" (nil) always resolves.
        guard NotchGeometry.preferredScreen() != nil else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "整机解锁已开启，但会话处于锁定状态 —— 请先在「密码」设置里验证一次。"
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "整机解锁已开启，但还没有存储密码。"
            return
        }

        // A deselected trigger means "don't auto-scan for this signal," not "do nothing" — the user can still opt in by hand.
        let shouldAutoScan = FIDSettings.shared.unlockTriggers.contains(signal)

        // Headless has nothing to arm/hover, so if this signal isn't selected there's nothing to do — and hasArmedForCurrentLock
        // must stay false, or a later selected signal could never fire (nothing else calls arm() to reset it).
        guard showsUI || shouldAutoScan else { return }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        Task { [weak self] in
            // arm() only shows a small closed notch silhouette, so this only needs a brief buffer past the login window's entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.arm(autoScan: shouldAutoScan)
        }
    }

    /// Whether the last arm was recent enough to be part of the same wake burst rather than a new one.
    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// nil for signals that shouldn't arm anything — including a nil `lastEvent`, or the first observation would fire regardless of user selection.
    private func requiredTrigger(for event: LockEventKind?) -> UnlockTrigger? {
        switch event {
        case .wake: return .onWake
        case .screenLocked: return .onLock
        case .screenUnlocked, .willSleep, nil: return nil
        }
    }

    private func disarmOverlay() {
        scanTask?.cancel()
        scanTask = nil
        // Bumping makes any cycle still suspended at `await camera.start()` inert, rather than resuming and re-showing the overlay.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        stopCapture()
        NotchOverlayController.shared.disarm()
        // Covers isEnabled being switched off directly, keeping "disarmed" and "not listening for space" in lockstep.
        spaceKeyMonitor.stop()
    }

    /// Idempotent and safe to call on every lock/wake event. Deliberately does not prompt for Input Monitoring — a missing grant just means "don't listen."
    private func updateSpaceMonitor() {
        let shouldListen = isEnabled
            && FIDSettings.shared.unlockTriggers.contains(.onSpace)
            && LockMonitor.isScreenActuallyLocked()
            && SpaceKeyMonitor.hasInputMonitoringAccess()
        if shouldListen {
            spaceKeyMonitor.start()
        } else {
            spaceKeyMonitor.stop()
        }
    }

    /// Runs the same gate chain as `evaluateTrigger`, then starts a scan. Independent of `LockMonitor` events, so doesn't touch `hasArmedForCurrentLock`.
    private func handleSpaceKeyPress() {
        guard isEnabled,
              FIDSettings.shared.unlockTriggers.contains(.onSpace),
              LockMonitor.isScreenActuallyLocked(),
              NotchGeometry.preferredScreen() != nil,
              SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword()
        else { return }

        // Already looking — swallows auto-repeat/double-presses and lets "On wake"/"On lock" override "On space" with no special-casing.
        guard NotchOverlayController.shared.phase != .scanning else { return }

        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // Closed pill/notch already up — expand and scan, like a hover retry.
            startScanCycle()
        } else {
            Task { [weak self] in await self?.arm(autoScan: true) }
        }
    }

    /// Either way the overlay still arms — a deselected trigger only skips the automatic scan, leaving hover-to-start available.
    private func arm(autoScan: Bool) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        guard showsUI else {
            // Headless: evaluateTrigger() already guaranteed autoScan is true here, so this is just "start scanning."
            startScanCycle()
            return
        }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        if autoScan {
            startScanCycle()
        }
    }

    /// Called on arm, and again whenever the overlay hover-activates.
    private func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// Stops capture and returns the camera to the arbiter — always paired with
    /// `cameraArbiter.acquire(.systemUnlock)`. Safe to call when we don't hold it
    /// (the release is a no-op then).
    private func stopCapture() {
        camera.stop()
        cameraArbiter.release(.systemUnlock)
    }

    /// `generation` is what makes overlapping cycles safe: `Task.cancel()` is cooperative, so a superseded cycle still runs to the
    /// end of this function, and its global side effects (`camera.stop()` etc.) could otherwise land on the newer cycle instead
    /// of itself. This was a real bug — a superseded `camera.stop()` queued behind the newer cycle's `startRunning()` made the
    /// camera visibly switch on then die mid-warm-up, leaving the surviving cycle polling a dead session and never unlocking.
    private func runScanCycle(generation: Int) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        // The lock-screen path always wins the camera, but be defensive: if a
        // holder of equal-or-higher priority refused to yield, skip this cycle
        // rather than opening a second session. The scan timeout / hover-to-retry
        // path picks it up again shortly.
        guard cameraArbiter.acquire(.systemUnlock) else { return }

        await camera.start()
        guard generation == scanGeneration else { return }

        if let error = camera.errorMessage {
            statusMessage = error
            stopCapture()
            return
        }

        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.beginScanning()
        }
        statusMessage = "正在寻找人脸…"

        let outcome = await observeScanWindow(
            scanWindow: scanWindowDuration,
            requireOverlayScanning: showsUI
        )

        // A newer cycle now owns the camera and overlay — leave both alone, and leave the auto-retry one-shot unspent.
        guard generation == scanGeneration else { return }

        stopCapture()

        switch outcome {
        case .matched:
            // The unlock already happened inside observeScanWindow — this only decides whether anything is shown about it.
            if showsUI {
                NotchOverlayController.shared.finish(success: true)
            }
        case .consistentlyWrongFace:
            statusMessage = "未能识别。"
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "未能识别 —— 悬停刘海可重试。"
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .spoofSuspected:
            statusMessage = "无法确认是活体。"
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "无法确认是活体 —— 悬停刘海可重试。"
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .noResolution:
            statusMessage = "没有检测到人脸。"
            if showsUI {
                // No explicit collapse call: NotchOverlayController's own scanning timeout fires on the same mark and collapses itself.
                statusMessage = "没有检测到人脸 —— 悬停刘海可重试。"
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        }
    }

    /// `delay` waits out whatever the overlay is still showing so the retry doesn't start underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard FIDSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentLock else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Re-check rather than trust the delay: the user may have unlocked by password or retried manually while this waited.
            guard LockMonitor.isScreenActuallyLocked(), self.isEnabled else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    private enum ScanOutcome {
        case matched
        case consistentlyWrongFace
        /// A deny cue (glare, device rectangle) fired — actively rejected as a spoof regardless of match. Same failure path as `.consistentlyWrongFace`.
        case spoofSuspected
        case noResolution
    }

    /// Recognition and liveness run concurrently and each latches when it succeeds, so unlock fires the moment the second lands;
    /// liveness never fails the scan by staying undecided, it just keeps scanning until the window closes.
    ///
    /// The window is anchored to the **first frame**, not to the call: a cold `AVCaptureSession.startRunning()` — always cold
    /// after a display wake — used to consume a second or two of the scan before a single frame existed.
    ///
    /// `requireOverlayScanning` bails early once the overlay's own timeout collapses the UI — only applied when there is an
    /// overlay, since headlessly `phase` never becomes `.scanning` at all.
    private func observeScanWindow(scanWindow: TimeInterval, requireOverlayScanning: Bool) async -> ScanOutcome {
        let livenessEnabled = FIDSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { FIDSettings.shared.livenessMode }
        var consecutiveWrongFaceFrames = 0
        var scoredFrames = 0

        let hardDeadline = Date().addingTimeInterval(scanWindow + FIDConstants.cameraWarmupAllowance)
        /// Relaxed to `firstFrame + scanWindow` once frames arrive; never past `hardDeadline`.
        var deadline = hardDeadline
        var firstFrameAt: Date?
        /// When the streak first crossed the threshold — the clock for the early give-up.
        var wrongFaceSince: Date?

        /// Cleared the moment a detected face fails to match, so a latched match can't be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        /// Turning liveness off in Settings makes this half permanently ready.
        var livenessConfirmed = !livenessEnabled
        /// Last frame's selected face, passed back so `selectDominantFace` stays on the same person instead of flip-flopping.
        var lastFaceBoundingBox: CGRect?
        /// Cheap way to detect "no new camera frame yet" vs. "fresh frame" — without it a repeat frame would corrupt the liveness motion signal.
        var lastProcessedFrameID: UInt64?

        while Date() < deadline, !Task.isCancelled,
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            guard LockMonitor.isScreenActuallyLocked() else { return .noResolution }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                // 20ms keeps the liveness window's sample count high while staying close to the camera's native ~33ms cadence.
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            if firstFrameAt == nil {
                firstFrameAt = Date()
                // Re-anchor: the scan is worth `scanWindow` seconds *of frames*, but
                // never more than the warm-up allowance on top of the original call.
                deadline = min(Date().addingTimeInterval(scanWindow), hardDeadline)
            }

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                consecutiveWrongFaceFrames = 0
                // Restart the give-up clock too: the face left the frame entirely, so
                // whatever follows is a new attempt rather than a persisting mismatch.
                wrongFaceSince = nil
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Fed regardless of match, so liveness stays a genuinely independent gate rather than one starved by recognition confidence.
            var confirmingCue: LivenessCue?
            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    // Overrides everything, including a match and any confirmation that already happened.
                    lastOutcome = snapshot.decision.denialReason
                    return .spoofSuspected
                case .confirmed(let cue):
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            // `activeIdentities`, not `identities`: someone switched off on the Your Face page stays enrolled but must not unlock.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold)

            if let matched {
                consecutiveWrongFaceFrames = 0
                wrongFaceSince = nil
                scoredFrames += 1
                readyMatch = matched
            } else {
                // Cleared so a latched match can't be handed to whoever steps in next.
                readyMatch = nil
                scoredFrames += 1
                // Only start counting once the scan has had a fair chance. The first
                // frames catch the user still sitting down or turning towards the
                // camera, and used to abort the whole attempt after ~200 ms.
                let pastGrace = firstFrameAt.map {
                    Date().timeIntervalSince($0) >= FIDConstants.wrongFaceGraceDuration
                } ?? false

                if pastGrace, scoredFrames >= FIDConstants.wrongFaceMinScoredFrames {
                    consecutiveWrongFaceFrames += 1
                    if consecutiveWrongFaceFrames >= wrongFaceStreakThreshold {
                        if let since = wrongFaceSince {
                            // Kept scanning after the streak in case it was just a bad
                            // angle — only give up once the mismatch has persisted.
                            if Date().timeIntervalSince(since) >= FIDConstants.wrongFaceAbortDuration {
                                return .consistentlyWrongFace
                            }
                        } else {
                            wrongFaceSince = Date()
                        }
                    }
                }
            }

            if let readyMatch, livenessConfirmed {
                statusMessage = "已识别 —— 正在解锁…"
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "活体：\($0.title)" } ?? "活体通过")
                    : "活体检测已关闭"
                lastOutcome = "匹配 \(readyMatch.identity.name)，相似度 \(String(format: "%.3f", readyMatch.centroidSimilarity))，\(livenessNote)。"
                await pocController.injectStoredPassword(requireAuthoritativeLock: true)
                return .matched
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // A streak that never resolved inside the window is still "wrong face", not
        // "nobody there" — the two carry different weight in the ledger.
        return wrongFaceSince != nil ? .consistentlyWrongFace : .noResolution
    }
}
