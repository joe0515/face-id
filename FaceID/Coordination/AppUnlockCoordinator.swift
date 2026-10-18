//
//  AppUnlockCoordinator.swift
//  Face ID
//
//  Closes the app-locking loop. Takes the pieces Phase 2–4 built — detection, the
//  window shield, the notch panel, the password prompt — and wires them into one
//  flow:
//
//      AppMonitor detects a locked app reaching the front
//        → the notch panel shows the challenge (immediate feedback)
//        → WindowShieldManager covers the app's windows, or hides it
//        → AppLocker records it as held
//        → AuthenticationCoordinator runs face → Touch ID → password
//        → success restores the app, Esc ends it
//
//  Modeled on `FaceUnlockCoordinator`, but the two deliberately share nothing at
//  runtime. The lock-screen path injects the machine password on success; this one
//  only ever releases a single app. They meet in exactly two places: the same
//  `FaceRecognitionPipeline` (via `AuthenticationCoordinator`), and `CameraArbiter`,
//  where the lock screen outranks this feature — a lock that lands mid-challenge
//  takes the camera away rather than opening a second capture session.
//
//  Only one challenge can be in flight. `AppLocker` enforces that too, but the guard
//  is duplicated here on purpose: a burst of launch+activate notifications would
//  otherwise start a second task that immediately no-ops and leaves `isChallenging`
//  latched on.
//

import AppKit
import Observation

@Observable
@MainActor
final class AppUnlockCoordinator: AppLockChallengePresenting {

    private let monitor: AppMonitor
    private let locker: AppLocker
    private let shield: WindowShieldManager
    private let notch: NotchOverlayController
    private let store: LockedAppsStore
    private let passwordPrompt: ChallengePasswordPanel

    /// Holds the camera, the pipeline and the attempt ledger.
    let auth: AuthenticationCoordinator

    private let cameraArbiter: CameraArbiter

    /// Master switch. Persisted so it survives relaunch; the real gate is still the
    /// locked-apps list — this only lets the user stand the feature down entirely.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: FIDConstants.Defaults.appLockEnabled) }
    }

    private(set) var isMonitoring = false
    /// True from detection until the challenge is resolved one way or the other.
    /// A hover-driven retry does *not* clear it — it re-runs the ladder in place.
    private(set) var isChallenging = false
    private(set) var statusMessage = "Idle"
    /// How the last challenge ended, and which enforcement mode was used. Diagnostics.
    private(set) var lastOutcome: String?

    @ObservationIgnored private var challengeTask: Task<Void, Never>?
    /// Waiting a beat for a locked app to actually put a window on screen — see
    /// `handleLockedAppDetected`.
    @ObservationIgnored private var windowProbeTask: Task<Void, Never>?
    @ObservationIgnored private var challengeContent: AppLockContent?
    @ObservationIgnored private var blockedApp: NSRunningApplication?
    @ObservationIgnored private var userBailed = false

    /// No default arguments: every one of these is a main-actor-isolated singleton,
    /// and a default argument is evaluated in a nonisolated context. Callers pass
    /// the instances they already hold — see `AppEnvironment`.
    init(
        monitor: AppMonitor,
        locker: AppLocker,
        shield: WindowShieldManager,
        notch: NotchOverlayController,
        store: LockedAppsStore,
        auth: AuthenticationCoordinator,
        cameraArbiter: CameraArbiter,
        passwordPrompt: ChallengePasswordPanel
    ) {
        self.monitor = monitor
        self.locker = locker
        self.shield = shield
        self.notch = notch
        self.store = store
        self.auth = auth
        self.cameraArbiter = cameraArbiter
        self.passwordPrompt = passwordPrompt
        self.isEnabled = UserDefaults.standard
            .object(forKey: FIDConstants.Defaults.appLockEnabled) as? Bool ?? true

        passwordPrompt.onClose = { [weak self] in self?.restoreChallengeKey() }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isMonitoring else { return }

        monitor.onLockedAppDetected = { [weak self] bundleID, runningApp in
            self?.handleLockedAppDetected(bundleID: bundleID, runningApp: runningApp)
        }
        // A challenge whose app quits has nothing left to resolve. Without this it
        // stays latched and swallows every later detection.
        monitor.onAppTerminated = { [weak self] bundleID in
            self?.handleAppTerminated(bundleID: bundleID)
        }
        // Esc on a window cover is the user's guaranteed way out.
        shield.onCancelRequested = { [weak self] in self?.cancelCurrentChallenge() }
        // Esc on the notch panel covers the mode where no cover exists to press it on.
        notch.onAppLockCancel = { [weak self] in self?.cancelCurrentChallenge() }
        // The lock screen outranks this feature. Preemption only needs to drop our
        // face attempt — the ladder's own lease check then runs the rest without one.
        cameraArbiter.register(.appLock) { [weak self] in self?.auth.cancelFaceAttempt() }

        monitor.startMonitoring()
        isMonitoring = true
    }

    func stop() {
        guard isMonitoring else { return }

        monitor.onLockedAppDetected = nil
        monitor.onAppTerminated = nil
        shield.onCancelRequested = nil
        notch.onAppLockCancel = nil
        cameraArbiter.unregister(.appLock)
        monitor.stopMonitoring()

        challengeTask?.cancel()
        challengeTask = nil
        windowProbeTask?.cancel()
        windowProbeTask = nil

        switch challengeContent {
        case .some where locker.isBlocking:
            // Shutting down mid-challenge: give the app back rather than leaving it
            // hidden (and therefore unreachable) or ending it for a decision the user
            // never got to make.
            lastOutcome = "启动器退出，已恢复被锁应用"
            teardown()
            locker.unlockCurrentApp()
            notch.endAppLockChallenge()
        default:
            teardown()
        }

        isMonitoring = false
    }

    // MARK: - Detection

    private func handleLockedAppDetected(bundleID: String, runningApp: NSRunningApplication) {
        guard isEnabled else { return }

        // A challenge that never resolved must not wedge detection forever. The old
        // flow could get here with `isChallenging == true` and no app left to resolve
        // (a background launch that fell back to hiding, an app the user quit from
        // the Dock), after which *every* locked app was silently ignored until the
        // whole app was relaunched.
        if isChallenging {
            guard !isChallengeStillLive else { return }
            abandonStaleChallenge()
        }

        guard store.isLocked(bundleID) else { return }
        // A pinned display that isn't connected means there is nowhere to show the
        // challenge; blocking with no way to authenticate would strand the app.
        guard NotchGeometry.preferredScreen() != nil else { return }
        guard let lockedApp = store.app(for: bundleID) else { return }

        let pid = runningApp.processIdentifier

        // ① Already painting — challenge it right now, covers can go straight up.
        if shield.hasOnScreenWindow(pid: pid) {
            beginChallenge(for: lockedApp, runningApp: runningApp)
            return
        }

        // ② Nothing on screen and the process just started. `launchDate` is the
        // authoritative signal; "no windows at all" only backs it up when the launch
        // date is unavailable. Deliberately *not* "has no windows": an app that really
        // destroys its windows when they are closed (unlike WeChat, which only orders
        // them out) would then be mistaken for a cold start and get challenged with
        // nothing on screen — exactly the failure mode branch ③ exists to prevent.
        if let launchDate = runningApp.launchDate {
            if Date().timeIntervalSince(launchDate) < FIDConstants.freshLaunchThreshold {
                beginChallenge(for: lockedApp, runningApp: runningApp)
                return
            }
        } else if !shield.hasAnyWindow(pid: pid) {
            beginChallenge(for: lockedApp, runningApp: runningApp)
            return
        }

        // ③ Nothing on screen and the app isn't starting up: its windows were closed
        // while the process kept running (WeChat after its window is closed). macOS
        // activates it when another app quits, and there is nothing to protect —
        // challenging it there is pure noise (an authentication panel for a window
        // that doesn't exist, plus a black flash). Give it a short grace in case a
        // window is on its way, and stay quiet if none ever appears.
        windowProbeTask?.cancel()
        windowProbeTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(FIDConstants.windowAppearGrace)
            while Date() < deadline, !Task.isCancelled {
                if self.shield.hasOnScreenWindow(pid: pid) { break }
                try? await Task.sleep(for: .seconds(FIDConstants.windowProbeInterval))
            }
            guard !Task.isCancelled,
                  self.shield.hasOnScreenWindow(pid: pid),
                  !self.isChallenging,
                  self.store.isLocked(bundleID),
                  let stillLocked = self.store.app(for: bundleID) else { return }
            self.beginChallenge(for: stillLocked, runningApp: runningApp)
        }
    }

    private func beginChallenge(for lockedApp: LockedApp, runningApp: NSRunningApplication) {
        let bundleID = lockedApp.bundleIdentifier
        // The store's persisted icon is the one the user picked; the running app's is
        // the fallback for entries saved before an icon could be captured.
        let icon = lockedApp.icon ?? runningApp.icon
        let content = AppLockContent(bundleID: bundleID, displayName: lockedApp.displayName, icon: icon)

        challengeContent = content
        blockedApp = runningApp
        userBailed = false
        isChallenging = true
        statusMessage = "已拦截「\(content.displayName)」"

        // Synchronously, before anything that can suspend: the app has already drawn
        // its window by now, and the per-window covers cannot go up until AX reports
        // its geometry. Without this the user sees the app's contents for a beat —
        // see `WindowShieldManager.imposeEmergencyCover`.
        //
        // `isFreshLaunch` keeps the stopgap for a cold launch (window not created yet)
        // while skipping it for a background app that has no window to hide at all.
        let freshlyLaunched = runningApp.launchDate.map { Date().timeIntervalSince($0) < FIDConstants.freshLaunchThreshold } ?? false
        shield.imposeEmergencyCover(
            pid: runningApp.processIdentifier,
            bundleID: bundleID,
            appName: content.displayName,
            icon: icon,
            isFreshLaunch: freshlyLaunched
        )

        // Shown before the shield is set up so the user immediately sees *why* their
        // app just vanished. The blocking itself happens in the task below, where the
        // ordering constraint actually lives.
        notch.presentAppLock(content) { [weak self] in
            self?.restartChallenge()
        }

        challengeTask = Task { [weak self] in
            await self?.blockThenAuthenticate(content: content, runningApp: runningApp)
        }
    }

    /// Whether the app a challenge is holding still exists. `AppLocker` is the source
    /// of truth for *which* app; no entry there means the challenge is already gone.
    private var isChallengeStillLive: Bool {
        guard let blocked = locker.blockedBundleID else {
            // Detected but not yet blocked — the shield task is still in flight.
            return true
        }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: blocked).isEmpty
    }

    /// Drops a challenge whose subject is gone, without touching any other app.
    private func abandonStaleChallenge() {
        challengeTask?.cancel()
        challengeTask = nil
        auth.cancelFaceAttempt()
        teardown()
        notch.endAppLockChallenge()
        locker.reset()
        lastOutcome = "上一次挑战没有结果，已清理"
    }

    /// The blocked app quit on its own — nothing left to unlock or terminate.
    private func handleAppTerminated(bundleID: String) {
        guard isChallenging, challengeContent?.bundleID == bundleID else { return }
        lastOutcome = "被锁应用已退出，挑战结束"
        challengeTask?.cancel()
        challengeTask = nil
        auth.cancelFaceAttempt()
        teardown()
        notch.endAppLockChallenge()
        locker.reset()
    }

    /// Enforcement, then authentication.
    ///
    /// The order matters and is not interchangeable: the app must **not** be hidden
    /// before `shield` runs. A hidden app has no on-screen windows, so the window
    /// shield would find nothing to cover and every challenge would silently degrade
    /// to the hidden fallback. `shield` owns both strategies and reports which one
    /// actually took effect; hiding only happens if that is what it chose.
    private func blockThenAuthenticate(content: AppLockContent, runningApp: NSRunningApplication) async {
        let mode = await shield.shield(
            pid: runningApp.processIdentifier,
            bundleID: content.bundleID,
            appName: content.displayName,
            icon: content.icon
        )
        guard !Task.isCancelled else { return }

        locker.block(bundleID: content.bundleID, runningApp: runningApp, hidesApp: mode == .hidden)

        switch mode {
        case .windowShield:
            lastOutcome = "以窗口遮罩拦截"
        case .hidden:
            lastOutcome = "以隐藏应用拦截（\(shield.fallbackReason ?? "回落")）"
            // No cover exists, so nothing else can catch Esc — the notch panel must.
            notch.makeAppLockKey()
        case .none:
            lastOutcome = "未拦截"
        }

        await runLadder(content: content)
    }

    /// A hover on the panel starts another pass: the app stays blocked throughout, so
    /// only the authentication is repeated — the shield is left exactly as it is.
    private func restartChallenge() {
        guard isChallenging, !userBailed, let content = challengeContent else { return }
        challengeTask?.cancel()
        challengeTask = Task { [weak self] in
            await self?.runLadder(content: content)
        }
    }

    private func runLadder(content: AppLockContent) async {
        let outcome = await auth.authenticate(app: content, presenting: self)
        // A cancel bumps the task's cancellation, and `settle` would then race the
        // teardown that already ran — leave the resolution to whoever cancelled.
        guard !Task.isCancelled else { return }
        settle(outcome)
    }

    private func settle(_ outcome: AuthenticationOutcome) {
        statusMessage = auth.statusMessage

        switch outcome {
        case .success:
            lastOutcome = "已通过\(auth.lastMethod?.title ?? "验证")解锁"
            teardown()
            locker.unlockCurrentApp()
            notch.completeAppLock()

        case .cancelled:
            lastOutcome = "用户取消，已结束被锁应用"
            teardown()
            locker.terminateBlockedApp()
            notch.endAppLockChallenge()

        case .retryable:
            // Stay blocked. The panel holds its failure frame — and, because an
            // app-lock payload keeps it on screen, hovering starts another pass.
            lastOutcome = "本轮验证未通过，等待重试"

        case .lockedOut(let remaining):
            lastOutcome = "已锁定 \(Int(remaining.rounded(.up))) 秒"
        }
    }

    /// Esc — or the shield's cancel affordance. The user explicitly asked to be rid of
    /// the app, so it is ended rather than left in a half-open challenge.
    private func cancelCurrentChallenge() {
        guard isChallenging else { return }
        userBailed = true
        challengeTask?.cancel()
        challengeTask = nil
        auth.cancelFaceAttempt()

        teardown()
        locker.terminateBlockedApp()
        notch.endAppLockChallenge()
        lastOutcome = "用户取消，已结束被锁应用"
    }

    /// Drops per-challenge state and every surface it put up, without touching the
    /// app itself — that is the caller's call (`unlockCurrentApp` / `terminateBlockedApp`).
    private func teardown() {
        challengeTask = nil
        isChallenging = false
        userBailed = false
        challengeContent = nil
        blockedApp = nil
        // Before the shield goes away, so the key hand-back it triggers is a no-op
        // rather than a re-key of panels that are already gone.
        passwordPrompt.dismiss()
        shield.unshield()
    }

    /// Hands key back to whichever surface should be holding it.
    private func restoreChallengeKey() {
        guard isChallenging else { return }
        if shield.activeMode == .windowShield {
            shield.restoreKeyPanel()
        } else {
            notch.makeAppLockKey()
        }
    }

    // MARK: - AppLockChallengePresenting

    func challengeDidBeginFaceScan() {
        // Re-aligned here rather than left to `presentAppLock`: that call fires while
        // the shield is still being set up, so this is what actually pairs the panel's
        // scan timeout with the moment capture begins. A no-op cost on the first pass.
        notch.beginScanning()
    }

    func challengeDidFinishFaceScan(success: Bool) {
        notch.finish(success: success)
    }

    func challengeDidReport(_ message: String) {
        statusMessage = message
        // Only meaningful while the prompt is up; `prompt(...)` re-reads the error
        // from the ladder on the next pass anyway.
        passwordPrompt.showError(message)
    }

    func challengeRequestPassword(appName: String, icon: NSImage?) async -> String? {
        // Carries forward whatever failed on the way here — a locked-out Touch ID is
        // the common case, and without it the prompt would look like a bare retry.
        await passwordPrompt.prompt(
            appName: appName,
            icon: icon,
            errorMessage: auth.lastFailureMessage
        )
    }
}
