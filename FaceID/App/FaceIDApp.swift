//
//  FaceIDApp.swift
//  Face ID
//
//  Created by Jonathan Zhou on 2026-07-21.
//

import SwiftUI

@main
struct FaceIDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Only reliable way to reopen a `Window` scene once its `NSWindow` has fully closed.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        settingsWindow
    }

    /// Suppressed so Settings doesn't appear on launch/restore. `openWindow` is captured here, not in `onAppear`, since the
    /// window may never have appeared before the menu bar needs to open it.
    private var settingsWindow: some Scene {
        let open = openWindow
        let delegate = appDelegate
        DispatchQueue.main.async {
            delegate.bindOpenWindowAction { open(id: "settings") }
        }
        return Window("Face ID 设置", id: "settings") {
            SettingsWindowView(environment: appDelegate.environment)
                .onAppear {
                    delegate.bindOpenWindowAction { open(id: "settings") }
                }
        }
        // Deliberately no `.windowResizability(.contentSize)`: it kept re-deriving the window size from the titlebar band,
        // growing the window whenever that band's height changed. Size is set once by WindowConfiguringView instead.
        //
        // Creates the window at its final size from the start. WindowConfiguringView only applies the size a runloop after
        // the window first draws, so without this the first frame showed SwiftUI's own guess (much wider, much shorter).
        .defaultSize(SettingsMetrics.windowSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Owns the long-lived controllers so every Settings page and the menu bar's session row share the same instances instead of
    /// each spinning up its own camera/lock-monitor (see AppEnvironment.swift). Lives here rather than as `@State` because
    /// `@NSApplicationDelegateAdaptor` constructs this delegate before the scene body runs, so it's always safe to read.
    let environment = AppEnvironment()

    /// Kept alive for the app's lifetime — a local variable would vanish (and the icon with it) once `applicationDidFinishLaunching` returns.
    private var statusItem: NSStatusItem?
    /// Held so `menuNeedsUpdate` can refresh this row in place rather than rebuilding the whole menu.
    private var sessionMenuItem: NSMenuItem?
    /// App-locking row plus its submenu's items — see `updateAppLockMenuItem()`.
    private var appLockMenuItem: NSMenuItem?
    private var pauseAppLockItems: [NSMenuItem] = []
    private var resumeAppLockItem: NSMenuItem?
    /// "需要授权…" row — hidden whenever every grant is in place.
    private var permissionMenuItem: NSMenuItem?
    /// Bridges SwiftUI's `openWindow(\.settings)` action in from `FaceIDApp.body`, since this plain `NSObject` has no
    /// `@Environment` of its own. Bound from the scene body (not `onAppear`) so it's ready before Settings has ever shown —
    /// `NSApp.windows` stops containing the window once fully closed, so only `openWindow(id:)` can reliably re-create it.
    var openSettingsWindowAction: (() -> Void)?

    /// Reassigned on every scene rebuild so the (cheap) action never goes stale.
    func bindOpenWindowAction(_ action: @escaping () -> Void) {
        openSettingsWindowAction = action
    }

    /// Guards `environment.updater.start()` against running twice — reachable from two call sites, and Sparkle doesn't promise
    /// starting an already-started `SPUUpdater` is a safe no-op.
    private var hasStartedUpdater = false

    /// Accessory before the Dock binds this launch to a persistent tile — starting `.regular` made the pinned icon bounce and
    /// get replaced by a Recents tile the moment the Dock icon was later hidden/shown.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// True while this process is a unit-test host. Xcode injects
    /// `XCTestConfigurationFilePath` into the host app's environment for the
    /// lifetime of the test session.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests boot this app as their host. None of the startup below is
        // wanted then: a status item, the first-run onboarding gate and the
        // updater all put UI on screen, and a host that is still settling is what
        // makes the test runner "hang before establishing connection". Bail out
        // and leave the process quiescent — the tests only need the module loaded.
        guard !Self.isRunningTests else { return }

        // Started here rather than from a Settings page: it is a workspace observer,
        // and a locked app has to be caught on its very first activation, not only
        // after the user has opened Settings once.
        environment.appUnlockCoordinator.start()

        // 刷脸比对的模板是用**会话密钥**加密的，而密钥只在内存里：进程一重启，会话就是
        // 锁定态，`FaceEnrollmentStore` 载不出任何人脸 —— 表现出来就是「重装/重启之后
        // 录入过的人脸一个都认不出」，而且扫描照常进行、只是永远匹配不到。
        //
        // 所以启动时补这一次会话解锁（一次触控 ID / 登录密码），之后整段会话内刷脸可用。
        if FIDSettings.shared.isFaceUnlockEnabled,
           SecureCredentialManager.hasStoredPassword(),
           !SecureCredentialManager.isSessionUnlocked {
            Task { @MainActor in
                // 让启动期的权限面板/状态栏先就位，避免验证弹窗和它们抢焦点。
                try? await Task.sleep(for: .seconds(1.5))
                await environment.pocController.unlockSession()
            }
        }

        // macOS 15–25 can't resolve the appiconset's dark variant, so the Dock icon is
        // switched by hand there. No-op on 26+ — see the controller's header.
        AppIconAppearanceController.shared.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Custom mark, not an SF Symbol; `isTemplate` is cheap insurance against a plain black-square render.
        // It is also what makes the glyph follow the menu bar's own light/dark treatment.
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        // Used at the size the asset declares: the imageset ships a real 18×18pt
        // design (18px @1x, 36px @2x), so trimming it to a nominal height would only
        // shrink artwork that was already drawn for this bar.
        item.button?.image = icon

        let menu = NSMenu()
        // Refreshes `sessionMenuItem` right before the menu displays — see `menuNeedsUpdate` below.
        menu.delegate = self

        let sessionItem = NSMenuItem(title: "", action: #selector(toggleSession), keyEquivalent: "")
        sessionItem.target = self
        menu.addItem(sessionItem)
        sessionMenuItem = sessionItem

        let permissionItem = NSMenuItem(title: "需要授权…", action: #selector(openPermissionGate), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        menu.addItem(permissionItem)
        permissionMenuItem = permissionItem

        // Only shown right after a reinstall/rebuild — see `KeychainTrust` for why an
        // ad-hoc build has to re-authorize the keychain item every time. The row itself
        // lives in the permission review panel (one place for every grant), and this
        // item just opens that panel.
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(makeAppLockItem())

        let quitItem = NSMenuItem(title: "退出 Face ID", action: #selector(quitFaceID), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        quitItem.toolTip = "应用加锁开启时需要验证身份"
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item

        updateSessionMenuItem()
        updateAppLockMenuItem()

        // SwiftUI can flip the app back to `.regular` while installing scenes even with `.suppressed`; re-assert accessory.
        NSApp.setActivationPolicy(.accessory)

        // `object: nil` deliberately — the Settings window may not exist yet (SwiftUI creates scene content lazily), and this
        // still matches it by identity in the handler below once it does close.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )

        // Deferred until onboarding is done — Sparkle's own "Check for updates automatically?" consent alert fires the moment
        // it starts on a fresh install, and starting unconditionally here used to pop it mid-onboarding.
        if FIDSettings.shared.hasCompletedOnboarding {
            if FIDSettings.shared.hasAcknowledgedSecurityNotice {
                startUpdaterIfNeeded()
                // The reinstall path. `hasCompletedOnboarding` lives in UserDefaults,
                // which a reinstall doesn't touch — so onboarding never runs again,
                // while the ad-hoc signature's cdhash *has* changed and taken the TCC
                // grants with it. Replaying the permissions step in the notch is the
                // only screen left that can say so.
                if PermissionGate.needsAttention {
                    OnboardingController.startPermissionReview()
                }
            } else {
                // Upgraded from a version before the notice existed — show it once, standalone.
                presentPostUpdateSecurityNotice()
            }
        } else {
            presentOnboardingGate()
        }
    }

    /// First-run gate: onboarding lives entirely in the notch, so this stays accessory. Called once at launch if onboarding
    /// isn't done, and again from `revealSettingsWindow()` if the user reaches Settings mid-flow. Closing any main window here
    /// is defense in depth against SwiftUI's `.suppressed` scene timing not being guaranteed.
    private func presentOnboardingGate() {
        for window in NSApp.windows where window.canBecomeMain {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        OnboardingController.startFlow(
            resumingAt: FIDSettings.shared.onboardingResumeStep,
            onFirstRunComplete: { [weak self] in
                // First time Settings should appear, which also brings the Dock icon back.
                self?.revealSettingsWindow()
                self?.startUpdaterIfNeeded()
            }
        )
    }

    /// One-time catch-up for users who completed onboarding before the security-notice step
    /// existed — same accessory/window-closing treatment as `presentOnboardingGate()`, but
    /// resumes straight into the updater afterward instead of revealing Settings, since setup
    /// itself is already done.
    private func presentPostUpdateSecurityNotice() {
        for window in NSApp.windows where window.canBecomeMain {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        // Reachable repeatedly — every gated menu action re-enters here while unacknowledged.
        // A fresh `startPostUpdateNotice()` would just replace the one already on screen.
        guard NotchOverlayController.shared.phase != .onboarding else { return }
        OnboardingController.startPostUpdateNotice { [weak self] in
            self?.startUpdaterIfNeeded()
        }
    }

    /// Reachable from launch (onboarding already done) or from first-run completion — `hasStartedUpdater` collapses both into "exactly once."
    private func startUpdaterIfNeeded() {
        guard !hasStartedUpdater else { return }
        hasStartedUpdater = true
        environment.updater.start()
    }

    /// Hides the Dock icon once no `canBecomeMain` window is left (`revealSettingsWindow()` brings it back) — excludes non-main
    /// windows like the lock-screen notch overlay, and backs off while Sparkle's update window is showing.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow.canBecomeMain else { return }
        guard !environment.updater.isPresentingUpdateUI else { return }
        let stillOpen = NSApp.windows.contains { $0 !== closingWindow && $0.canBecomeMain && $0.isVisible }
        guard !stillOpen else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Fires right before the menu opens — simpler than keeping an `NSMenuItem` reactively bound to `isSessionUnlocked`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateSessionMenuItem()
        updateAppLockMenuItem()
        // Hidden rather than disabled: once everything is granted the row has nothing
        // left to say, and a permanently greyed-out item is just noise. Recomputed
        // here so a grant made in System Settings shows up on the next open.
        permissionMenuItem?.isHidden = !PermissionGate.needsAttention
    }

    private func updateSessionMenuItem() {
        guard let sessionMenuItem else { return }
        let isUnlocked = environment.pocController.isSessionUnlocked
        sessionMenuItem.title = isUnlocked ? "会话已解锁" : "会话已锁定"
        sessionMenuItem.image = NSImage(
            systemSymbolName: isUnlocked ? "lock.open.fill" : "lock.fill",
            accessibilityDescription: nil
        )
    }

    // MARK: - App locking menu

    /// "App Locking" plus its pause submenu. A submenu rather than three top-level rows
    /// because pausing is a rare, deliberate act and the top level is already four items.
    private func makeAppLockItem() -> NSMenuItem {
        let item = NSMenuItem(title: "应用加锁", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for (title, minutes) in [("暂停 15 分钟", 15), ("暂停 1 小时", 60)] {
            let entry = NSMenuItem(title: title, action: #selector(pauseAppLock(_:)), keyEquivalent: "")
            entry.target = self
            // Carries the duration so one action serves both rows — see `pauseAppLock(_:)`.
            entry.tag = minutes
            // Pausing hands out an off switch for the feature — see `OwnerGate`.
            entry.toolTip = "需要验证身份"
            submenu.addItem(entry)
            pauseAppLockItems.append(entry)
        }

        submenu.addItem(.separator())

        let resume = NSMenuItem(title: "立即恢复保护", action: #selector(resumeAppLock), keyEquivalent: "")
        resume.target = self
        submenu.addItem(resume)
        resumeAppLockItem = resume

        item.submenu = submenu
        appLockMenuItem = item
        return item
    }

    /// Pausing is stored by `AppMonitor`, not here: it's the component that needs to honor
    /// it, and it self-expires, so a forgotten pause can't leave the Mac unprotected.
    ///
    /// Gated on identity: the status menu stays reachable while an app is blocked, so
    /// without this anyone at the machine could pause protection and then open it.
    @objc private func pauseAppLock(_ sender: NSMenuItem) {
        // Read before the suspension point — the menu is gone by the time the sheet
        // answers, and `NSMenuItem` is not ours to keep alive across it.
        let minutes = sender.tag
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await OwnerGate.shared.authorize(
                reason: "暂停应用加锁前需要验证身份。暂停期间，被锁定的应用将不再要求刷脸。",
                isRequired: self.isAppLockEnforcing
            )
            guard allowed else { return }
            AppMonitor.pauseProtection(forMinutes: minutes)
            self.updateAppLockMenuItem()
        }
    }

    /// Quitting is the other way to stand the feature down, so it takes the same gate.
    /// `NSApp.terminate` is only reached after the gate says yes — and a quit that
    /// lands mid-challenge is handed back by `applicationWillTerminate`.
    @objc private func quitFaceID() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await OwnerGate.shared.authorize(
                reason: "退出 Face ID 前需要验证身份。退出后，应用加锁将停止保护。",
                isRequired: self.isAppLockEnforcing && !AppMonitor.isProtectionPaused
            )
            guard allowed else { return }
            NSApp.terminate(nil)
        }
    }

    /// Whether pausing or quitting would actually let someone past app locking.
    /// With the feature off, or no apps selected, there is nothing to protect and
    /// prompting would be pure friction.
    private var isAppLockEnforcing: Bool {
        environment.appUnlockCoordinator.isEnabled
            && !LockedAppsStore.shared.lockedApps.isEmpty
    }

    @objc private func resumeAppLock() {
        // `minutes <= 0` is the clear path — see `AppMonitor.pauseProtection(forMinutes:)`.
        AppMonitor.pauseProtection(forMinutes: 0)
        updateAppLockMenuItem()
    }

    /// Reflects three distinct states, because "off" and "paused" look identical from the
    /// outside but need different fixes: one is a Settings switch, the other is a menu click.
    private func updateAppLockMenuItem() {
        guard let appLockMenuItem else { return }
        let isEnabled = environment.appUnlockCoordinator.isEnabled
        let isPaused = AppMonitor.isProtectionPaused

        if !isEnabled {
            appLockMenuItem.title = "应用加锁：已关闭"
        } else if isPaused {
            appLockMenuItem.title = "应用加锁：已暂停"
        } else {
            appLockMenuItem.title = "应用加锁：已开启"
        }
        appLockMenuItem.image = NSImage(
            systemSymbolName: isEnabled && !isPaused ? "lock.shield.fill" : "lock.shield",
            accessibilityDescription: nil
        )

        for pauseItem in pauseAppLockItems {
            pauseItem.isEnabled = isEnabled && !isPaused
        }
        resumeAppLockItem?.isEnabled = isPaused
    }

    /// Locking is immediate; unlocking prompts Touch ID, so this can't be a plain synchronous action for that branch.
    @objc private func toggleSession() {
        guard !isBlockedByPostUpdateNotice else {
            presentPostUpdateSecurityNotice()
            return
        }
        if environment.pocController.isSessionUnlocked {
            environment.pocController.lockSession()
        } else {
            Task { await environment.pocController.unlockSession() }
        }
    }

    /// Keeps the process alive after the window closes so it can still react to the screen locking (e.g. for face unlock).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Hands back an app that is currently being held.
    ///
    /// Quitting mid-challenge used to leave it hidden with nothing left running to
    /// unhide it — the app simply vanished until Face ID was started again. `stop()`
    /// owns that decision: it restores the app when a challenge is open and does
    /// nothing otherwise.
    func applicationWillTerminate(_ notification: Notification) {
        environment.appUnlockCoordinator.stop()
    }

    /// A Dock click must not create the Settings window — that produced a duplicate Recents icon. If already open, the default
    /// reopen behavior just brings it forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return flag
    }

    /// Menu bar "Settings" — the only user-facing way to open the window after onboarding.
    @objc private func openSettingsWindow() {
        revealSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-opens the permission review — same notch panel the launch path uses, so
    /// there is only ever one way this question is asked.
    @objc private func openPermissionGate() {
        OnboardingController.startPermissionReview()
    }

    /// True whenever an updated user hasn't acknowledged the post-update security notice yet.
    /// Checked by every menu-bar action that would otherwise let them use the app — Settings,
    /// locking/unlocking — before the notice has been seen.
    private var isBlockedByPostUpdateNotice: Bool {
        FIDSettings.shared.hasCompletedOnboarding && !FIDSettings.shared.hasAcknowledgedSecurityNotice
    }

    /// Restores the Dock icon before bringing the window forward — doing it after the window is already key can leave the icon
    /// out of sync. During onboarding this only ensures the notch flow is up; it doesn't open Settings or show a Dock icon.
    private func revealSettingsWindow() {
        if isBlockedByPostUpdateNotice {
            presentPostUpdateSecurityNotice()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard FIDSettings.shared.hasCompletedOnboarding else {
            // Re-present rather than restart: a fresh startFlow() would throw away the in-session step already navigated to,
            // since it only knows the last step written to disk.
            if NotchOverlayController.shared.phase != .onboarding {
                presentOnboardingGate()
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        if let openSettingsWindowAction {
            openSettingsWindowAction()
        } else {
            // `body` hasn't run yet somehow — falls back to a direct walk, which only works if a window instance still exists.
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        // Coming from `.accessory` there's no user gesture to activate the app, so without this Settings appears inactive and
        // won't take focus until the user Cmd-Tabs away and back.
        makeSettingsKeyAndActive()
    }

    /// Two runloop hops: `openWindow(id:)` hasn't created the `NSWindow` on this turn, and `WindowConfiguringView` configures it
    /// on the next — waiting one extra cycle orders front after the window actually exists.
    private func makeSettingsKeyAndActive() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.orderSettingsFront()
            DispatchQueue.main.async {
                self?.orderSettingsFront()
            }
        }
    }

    private func orderSettingsFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
