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
    /// One notice per lock session for the unreadable-store bail-out — see `presentStoreUnreadableNoticeIfNeeded`.
    private var hasPresentedUnreadableNotice = false
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
        observeSessionChanges()
    }

    /// The unreadable-store notice says "verify once from the menu bar" — stale the
    /// moment the user does (that verification is also what runs the one-time
    /// migration). Dropping it on unlock also re-arms it for the next lock session.
    private func observeSessionChanges() {
        NotificationCenter.default.addObserver(
            forName: .secureCredentialSessionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasPresentedUnreadableNotice = false
                if case .notice = NotchOverlayController.shared.phase {
                    NotchOverlayController.shared.dismissNotice()
                }
            }
        }
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
                // Logged inside the actor context: the closure itself is nonisolated,
                // and both the monitor's properties and the logger are main-actor
                // isolated.
                if let self {
                    UnlockDiagnostics.log("事件：lastEvent=\(String(describing: self.lockMonitor.lastEvent)) eventCount=\(self.lockMonitor.eventCount)")
                }
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
    /// The loop is cheap (4 Hz) and stops early once the machine is unlocked — the
    /// `disarm` path runs `cancel()` on it. It deliberately does **not** stop when a
    /// scan arms: `arm()` happens 250 ms later and can fail on its own (the machine
    /// got unlocked in the meantime, the camera lease was refused, the camera failed
    /// to start), and those failures used to leave this lock session permanently
    /// unarmed — "the prompt never comes back".
    private func scheduleTriggerEvaluation() {
        triggerProbeTask?.cancel()
        triggerProbeTask = Task { [weak self] in
            // 24 × 250 ms ≈ 6 s — comfortably covers the login window's entrance.
            for probe in 0..<24 {
                guard let self, !Task.isCancelled else { return }
                self.lockMonitor.reconcileSleepState()

                if LockMonitor.isScreenActuallyLocked() {
                    self.evaluateTrigger()
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
        let locked = LockMonitor.isScreenActuallyLocked()
        UnlockDiagnostics.log("evaluateTrigger: locked=\(locked) lastEvent=\(String(describing: lockMonitor.lastEvent)) sleeping=\(lockMonitor.isSleeping) armed=\(hasArmedForCurrentLock)")

        guard locked else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            // A notice (e.g. "re-authorize the keychain once you're logged in") has
            // nothing to say once the machine is unlocked.
            NotchOverlayController.shared.dismissNotice()
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else {
            UnlockDiagnostics.log("  → 放弃：isSleeping 仍为 true")
            return
        }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear the one-shot guard.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard isEnabled else {
            UnlockDiagnostics.log("  → 放弃：整机解锁开关未开启")
            return
        }

        // `hasArmedForCurrentLock` is a one-shot per lock session, reset when the
        // machine is seen unlocked or on a new wake. The distributed
        // `screenIsUnlocked` notification it depends on can be **lost** — the process
        // may be suspended across the transition, which is exactly what happens when
        // the lid closes. A lost reset latches this flag on forever and every later
        // wake is swallowed here: "the face prompt never appears again."
        //
        // So the flag is only honoured while an attempt is genuinely still running.
        // Once nothing is scanning, nothing is retrying and the panel is back at
        // rest, a later signal may arm again — which is also what makes a failed arm
        // (camera refused, machine unlocked mid-delay) recoverable.
        if hasArmedForCurrentLock, isAttemptInFlight {
            UnlockDiagnostics.log("  → 放弃：本次锁定已 arm 且尝试仍在进行")
            return
        }
        if hasArmedForCurrentLock {
            UnlockDiagnostics.log("  · 上一次 arm 的尝试已结束，允许本次锁定再次 arm（不依赖 screenIsUnlocked 通知）")
            hasArmedForCurrentLock = false
        }

        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else {
            UnlockDiagnostics.log("  → 放弃：lastEvent=\(String(describing: lockMonitor.lastEvent)) 不是可触发信号")
            return
        }
        // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Main display" (nil) always resolves.
        guard NotchGeometry.preferredScreen() != nil else {
            UnlockDiagnostics.log("  → 放弃：没有可用的屏幕")
            return
        }

        // 1.3 起模板存在设备密钥下，刷脸不再依赖设置会话；只有还没完成一次性迁移的
        // 旧安装（或设备密钥文件本身不可读）才会在这里卡住。
        if let reason = SecureFaceStore.unreadableReason() {
            statusMessage = "整机解锁已开启，但已录入的人脸数据还无法读取。"
            UnlockDiagnostics.log("  → 放弃：人脸数据不可读（\(String(describing: reason))）")
            presentStoreUnreadableNoticeIfNeeded()
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "整机解锁已开启，但还没有存储密码。"
            UnlockDiagnostics.log("  → 放弃：尚未存储密码")
            return
        }

        // A deselected trigger means "don't auto-scan for this signal," not "do nothing" — the user can still opt in by hand.
        let shouldAutoScan = FIDSettings.shared.unlockTriggers.contains(signal)

        // Headless has nothing to arm/hover, so if this signal isn't selected there's nothing to do — and hasArmedForCurrentLock
        // must stay false, or a later selected signal could never fire (nothing else calls arm() to reset it).
        guard showsUI || shouldAutoScan else { return }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        UnlockDiagnostics.log("  → arm（信号 \(signal.title)，autoScan=\(shouldAutoScan)）")
        Task { [weak self] in
            // arm() only shows a small closed notch silhouette, so this only needs a brief buffer past the login window's entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            // The 250 ms buffer is exactly where a failed arm used to disappear:
            // the machine got unlocked, or `arm()`'s own guard rejected it. Log which,
            // and leave `hasArmedForCurrentLock` consistent with what actually shows.
            guard LockMonitor.isScreenActuallyLocked() else {
                UnlockDiagnostics.log("  → arm 前机器已解锁，放弃本次 arm（下次唤醒可重新触发）")
                self.hasArmedForCurrentLock = false
                return
            }

            // 1.3 起扫描路径不再读任何钥匙串条目：模板和密码都在设备密钥下，
            // 锁屏上没有任何系统对话框需要弹给用户。
            await self.arm(autoScan: shouldAutoScan)
        }
    }

    /// The unreadable-store bail-out used to be invisible: no panel, no notice, nothing —
    /// indistinguishable from the feature being switched off. The notch panel is the only
    /// surface we have on the lock screen, so say what happened and how to undo it.
    ///
    /// Two causes, two texts: a 1.2-era store that hasn't been through the one-time
    /// migration yet (the verification it asks for is exactly what runs that migration),
    /// and a device key that can't be read at all. Since 1.3 the settings session itself
    /// never blocks face unlock.
    ///
    /// Once per lock session: `scheduleTriggerEvaluation`'s probe loop re-evaluates ~24
    /// times in six seconds, and `presentNotice` unconditionally re-shows the panel —
    /// without the one-shot flag that's a strobe.
    private func presentStoreUnreadableNoticeIfNeeded() {
        guard showsUI, !hasPresentedUnreadableNotice else { return }
        switch SecureFaceStore.unreadableReason() {
        case .legacyNeedsVerification:
            hasPresentedUnreadableNotice = true
            NotchOverlayController.shared.presentNotice(
                "Face ID 的人脸数据还停留在旧版加密格式，需要升级后才能刷脸。\n请登录 macOS，然后在菜单栏 Face ID 图标里验证一次（仅此一次，之后不再需要）。"
            )
        case .deviceKeyUnavailable:
            hasPresentedUnreadableNotice = true
            NotchOverlayController.shared.presentNotice(
                "Face ID 暂时读不出设备密钥，无法加载已录入的人脸。\n请登录 macOS 后在菜单栏 Face ID 图标里验证一次；若仍然失败，请在「密码」页移除存储的数据后重新设置。"
            )
        case .none:
            return
        }
    }

    /// Whether an unlock attempt is genuinely still occupying the camera or the
    /// overlay. See `evaluateTrigger` — this is what `hasArmedForCurrentLock` is
    /// allowed to suppress.
    ///
    /// The panel phases are part of the answer, not just the tasks: after a successful
    /// unlock `scanTask` is already nil (the disarm path cancels it) while the success
    /// animation is still playing. Judging by tasks alone let the next wake notification
    /// re-arm inside that 1.7 s window, resetting the panel to `.closed` — the success
    /// animation vanished, but only sometimes, depending on whether a stray notification
    /// arrived.
    private var isAttemptInFlight: Bool {
        if scanTask != nil || autoRetryTask != nil { return true }
        switch NotchOverlayController.shared.phase {
        case .scanning, .success, .failure, .collapsing:
            return true
        case .closed, .onboarding, .notice:
            return false
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
        // A disarm means the machine is unlocked (or the feature was switched off) —
        // either way the unreadable-store notice is stale and the next lock session may
        // show it again.
        hasPresentedUnreadableNotice = false
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
              SecureFaceStore.isReadable(),
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
        guard LockMonitor.isScreenActuallyLocked() else {
            UnlockDiagnostics.log("arm(): 屏幕已解锁，不显示面板")
            return
        }
        guard showsUI else {
            // Headless: evaluateTrigger() already guaranteed autoScan is true here, so this is just "start scanning."
            UnlockDiagnostics.log("arm(): 无界面模式，直接扫描")
            startScanCycle()
            return
        }
        UnlockDiagnostics.log("arm(): 显示刘海面板（autoScan=\(autoScan)）")
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
        guard cameraArbiter.acquire(.systemUnlock) else {
            UnlockDiagnostics.log("runScanCycle: 相机租约被拒绝（当前持有者 \(String(describing: cameraArbiter.currentOwner))），本次不扫描")
            return
        }

        // Hover- and auto-retry reach this point without going through
        // `evaluateTrigger`, so the store gate there doesn't cover them. Since 1.3
        // nothing on this path reads the keychain, so there is no second gate to
        // keep in step — an unreadable store is surfaced once, by `evaluateTrigger`,
        // before a scan ever starts.
        await camera.start()
        guard generation == scanGeneration else { return }

        if let error = camera.errorMessage {
            UnlockDiagnostics.log("runScanCycle: 相机启动失败 —— \(error)")
            statusMessage = error
            stopCapture()
            return
        }
        UnlockDiagnostics.log("runScanCycle: 相机已启动，开始扫描（窗口 \(scanWindowDuration)s）")

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
            // Nothing to do: the success animation was started inside
            // `observeScanWindow`, *before* the password was injected. Injecting unlocks the
            // Mac, which lands here as "screen is no longer locked" → `disarmOverlay()` →
            // the panel is gone. Calling `finish` at this point was always too late, so the
            // user only ever saw the scanning animation stop.
            break
        case .injectionFailed:
            statusMessage = "已识别，但无法注入解锁密码 —— 检查辅助功能权限与钥匙串授权。"
            if showsUI {
                // `finish(success: false)` already ran inside `observeScanWindow`; this
                // only gives hover-to-retry the same lifetime a plain failure gets.
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
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
        /// A face matched but the password could not be injected — the success animation
        /// was already started, so it is walked back to the failure frame.
        case injectionFailed
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

                // 成功动画必须**先于**注入开始。
                //
                // 注入密码会让系统立刻解锁，而我们监听「屏幕已解锁」并据此 `disarmOverlay()`
                // 收起面板。等注入返回再调 `finish(success:)`，面板已经没了 —— 现场表现就是
                // 「只有识别中的动画，没有成功的动画」。`disarm()` 对 `.success` 有保护，所以
                // 先播动画反而能让它活到播完。
                if requireOverlayScanning {
                    NotchOverlayController.shared.finish(success: true)
                }

                let injected = await pocController.injectStoredPassword(requireAuthoritativeLock: true)
                guard injected else {
                    // The animation already claimed success; take it back rather than leave
                    // the user looking at a checkmark over a Mac that never unlocked.
                    if requireOverlayScanning {
                        NotchOverlayController.shared.finish(success: false)
                    }
                    return .injectionFailed
                }
                return .matched
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // A streak that never resolved inside the window is still "wrong face", not
        // "nobody there" — the two carry different weight in the ledger.
        return wrongFaceSince != nil ? .consistentlyWrongFace : .noResolution
    }
}
