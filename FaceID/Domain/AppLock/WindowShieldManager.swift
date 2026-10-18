//
//  WindowShieldManager.swift
//  Face ID
//
//  Lays a cover over each window of a locked app, and decides when that approach
//  can't be trusted — falling back to hiding the app entirely.
//
//  The fallback is the interesting half. A cover panel is *painted over* the app's
//  window, which means it is invisible to anything that renders windows from the
//  window server's own content rather than from the screen: Mission Control's
//  thumbnails, and other Spaces. So whenever the situation stops being "one visible
//  window on the current Space", the shield gives up and hides the app, which
//  removes it from all of those surfaces at once.
//

//  The cover itself (`WindowShieldPanel` / `WindowShieldView`, in `UI/Shield/`) is
//  a thin mechanism rather than product presentation — it could equally be a blank
//  rectangle. The product's presentation layer is the notch panel, driven by the
//  coordinator. That's why a `Domain` type is allowed to name those two view types
//  here, and why the layering rule in the plan is read as "presentation doesn't
//  depend on domain logic", not "domain may not own its own mechanism".
//
//  **Contract with the caller:** do not hide the app before calling `shield`. A
//  hidden app has no on-screen windows, so there would be nothing to locate and
//  cover — the two enforcement strategies are mutually exclusive by construction.
//  Hiding is this type's own fallback (`switchToHidden`) and happens on its terms.
//
//  The other half of that contract is timing: an app is already painting by the
//  time it is reported active, and AX geometry arrives a beat later. Callers must
//  call `imposeEmergencyCover` synchronously from the detection callback to close
//  that gap; `shield` replaces it with the real covers as soon as they exist.
//

import AppKit
import Observation

@Observable
@MainActor
final class WindowShieldManager {

    /// What is actually in force — which can differ from what was requested, since
    /// the manager may fall back on its own.
    enum ActiveMode: Equatable {
        case none
        /// Cover panels over the app's own windows.
        case windowShield
        /// The app itself has been hidden.
        case hidden
    }

    private(set) var activeMode: ActiveMode = .none

    /// Why the window shield was abandoned. Surfaced in diagnostics; `nil` when the
    /// requested mode is in force.
    private(set) var fallbackReason: String?

    /// Invoked when the user presses Esc on a shield — the coordinator turns this
    /// into "cancel the challenge".
    @ObservationIgnored var onCancelRequested: (() -> Void)?

    private struct Target {
        let pid: pid_t
        let bundleID: String
        let appName: String
        let icon: NSImage?
    }

    @ObservationIgnored private var target: Target?
    @ObservationIgnored private let tracker = WindowTracker()
    @ObservationIgnored private var panels: [AXWindowKey: WindowShieldPanel] = [:]
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?
    /// Full-screen stopgap used between "a locked app came forward" and "the
    /// per-window covers are up". See `imposeEmergencyCover`.
    @ObservationIgnored private var emergencyCover: WindowShieldPanel?
    /// When the current stopgap was ordered front — see
    /// `dismissEmergencyCoverWhenReady`.
    @ObservationIgnored private var emergencyCoverShownAt: Date?
    /// Hard deadline for the stopgap; see `FIDConstants.emergencyCoverMaxWait`.
    @ObservationIgnored private var emergencyCoverDeadline: Date?

    private init() {}

    static let shared = WindowShieldManager()

    var isShielding: Bool { activeMode != .none }

    /// How many windows are currently covered — diagnostics only.
    var shieldedWindowCount: Int { panels.count }

    // MARK: - User preference

    /// The user's requested presentation. `.hidden` skips window tracking entirely.
    var requestedMode: FIDConstants.ShieldMode {
        get {
            let raw = UserDefaults.standard.string(forKey: FIDConstants.Defaults.appLockShieldMode)
            return raw.flatMap(FIDConstants.ShieldMode.init(rawValue:)) ?? .windowShield
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: FIDConstants.Defaults.appLockShieldMode) }
    }

    // MARK: - Lifecycle

    /// Covers `pid`'s windows. Returns the mode that actually took effect.
    ///
    /// `async` because of the settle wait below — the caller must not hide the app
    /// first, or there would be no windows left to find (see `settleForWindows`).
    @discardableResult
    func shield(pid: pid_t, bundleID: String, appName: String, icon: NSImage?) async -> ActiveMode {
        // `teardownPanels`, not `unshield`: an emergency cover put up by
        // `imposeEmergencyCover` must survive until the real covers replace it,
        // otherwise the app's window is exposed again for the whole settle wait.
        teardownPanels()

        let target = Target(pid: pid, bundleID: bundleID, appName: appName, icon: icon)
        self.target = target
        observeSpaceChanges()

        guard requestedMode == .windowShield else {
            return switchToHidden(reason: "设置中已关闭窗口遮罩")
        }

        // No Accessibility means no window geometry, which means nothing to cover.
        // `AppMonitor` is unaffected — it only needs NSWorkspace.
        guard WindowTracker.isTrusted else {
            return switchToHidden(reason: "未获得辅助功能权限")
        }

        guard tracker.start(pid: pid, onChange: { [weak self] windows in
            self?.handleTrackerChange(windows)
        }) else {
            return switchToHidden(reason: "无法观察该应用的窗口")
        }

        let windows = await settleForWindows()
        guard !windows.isEmpty else {
            return switchToHidden(reason: "没有可覆盖的窗口")
        }
        guard !windows.contains(where: \.isFullScreen) else {
            return switchToHidden(reason: "应用处于全屏")
        }

        activeMode = .windowShield
        fallbackReason = nil
        syncPanels(with: windows)
        return .windowShield
    }

    /// Removes every cover and stops tracking. Does **not** unhide the app — the
    /// caller owns that, so a fallback hide and a normal hide are undone the same way.
    func unshield() {
        teardownPanels()
        dismissEmergencyCover()
    }

    private func teardownPanels() {
        for panel in panels.values {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()

        tracker.stop()
        stopObservingSpaceChanges()
        target = nil
        activeMode = .none
        fallbackReason = nil
    }

    // MARK: - Emergency cover

    /// Covers the display the app is actually painting on, for the window between
    /// detection and the first real cover.
    ///
    /// It exists because of a gap that cannot be closed any other way: the app is
    /// already drawing by the time `NSWorkspace` reports it, and `shield` cannot
    /// place a cover until AX hands over the window geometry (worst case, the full
    /// `windowSettleTimeout`). Without this the user sees the app's contents for a
    /// few hundred milliseconds — the exact thing they asked to have hidden.
    ///
    /// Three things it deliberately does **not** do:
    ///
    /// - It no longer assumes `NSScreen.main`. That is the screen with the key window,
    ///   which for an accessory app (us) is wherever the menu bar is — so an app opened
    ///   on a second display got no stopgap at all, and its window was visible until
    ///   the real covers arrived.
    /// - It does not cover an app whose windows all exist **off screen**. Closing
    ///   WeChat's window only orders it out, so the process still owns four windows;
    ///   when macOS activates it after another app quits, nothing is painted — a
    ///   full-screen cover there is a black flash with nothing behind it.
    /// - It does not cover based on "has windows" alone, for the same reason. The
    ///   question is "is something on screen right now, or about to be".
    ///
    /// Deliberately synchronous and called from the detection callback, so it lands
    /// in the same runloop turn as the notification.
    func imposeEmergencyCover(
        pid: pid_t,
        bundleID: String,
        appName: String,
        icon: NSImage?,
        isFreshLaunch: Bool
    ) {
        dismissEmergencyCover()

        let windows = Self.windowInfo(for: pid)
        let onScreen = windows.filter(\.isOnScreen)
        // 冷启动时窗口还不存在（`windows` 为空）—— 正是最需要挡住的时刻。
        guard !onScreen.isEmpty || windows.isEmpty || isFreshLaunch else { return }

        guard let screen = Self.screen(containingLargestOf: onScreen.isEmpty ? windows : onScreen) ?? Self.screenUnderMouse else {
            return
        }

        let panel = WindowShieldPanel(
            frame: screen.frame,
            content: WindowShieldView(appName: appName, icon: icon)
        )
        panel.onCancel = { [weak self] in self?.onCancelRequested?() }
        // Key as well as front: otherwise the app keeps keyboard focus and a user
        // typing during the hand-off would still be typing *into* it.
        panel.makeKeyAndOrderFront(nil)
        emergencyCover = panel
        emergencyCoverShownAt = Date()
        emergencyCoverDeadline = Date().addingTimeInterval(FIDConstants.emergencyCoverMaxWait)
    }

    private struct OwnedWindow {
        let frame: CGRect
        let isOnScreen: Bool
    }

    /// Whether the process has any window at all — on screen or not.
    ///
    /// The complement of `hasOnScreenWindow`'s question. "No windows whatsoever"
    /// means the process is still starting up and is about to paint, which is exactly
    /// when a stopgap is needed; "windows exist but none on screen" means they were
    /// closed, and covering would be a black flash. See
    /// `AppUnlockCoordinator.handleLockedAppDetected`.
    func hasAnyWindow(pid: pid_t) -> Bool {
        !Self.windowInfo(for: pid).isEmpty
    }

    /// Whether the process currently has anything on screen.
    ///
    /// Used by the coordinator to decide whether a locked app is worth challenging at
    /// all: an app that keeps running with its windows ordered out (WeChat after its
    /// window is closed) can be "activated" by macOS when another app quits, and
    /// challenging it there puts up an authentication panel for a window that does not
    /// exist. Cheap enough to poll for a fraction of a second — one window-server query.
    func hasOnScreenWindow(pid: pid_t) -> Bool {
        Self.windowInfo(for: pid).contains(where: \.isOnScreen)
    }

    /// The pid's layer-0 windows in Cocoa global coordinates, tagged with whether the
    /// window server currently has them on screen.
    ///
    /// `CGWindowList` rather than AX on purpose: this runs synchronously inside the
    /// detection callback, where AX's first query costs tens of milliseconds. Window
    /// *bounds* need no Screen Recording grant (only window names do).
    private static func windowInfo(for pid: pid_t) -> [OwnedWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 80, rect.height >= 80
            else { return nil }
            // CGWindow 的原点在主屏左上，NSScreen 在左下。
            let cocoa = CGRect(
                x: rect.minX,
                y: primaryHeight - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            return OwnedWindow(
                frame: cocoa,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false
            )
        }
    }

    private static func screen(containingLargestOf windows: [OwnedWindow]) -> NSScreen? {
        guard let largest = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return nil
        }
        let center = CGPoint(x: largest.frame.midX, y: largest.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    /// Where a window is about to appear when the app hasn't created one yet.
    ///
    /// The pointer is the best available hint — a cold launch is triggered from the Dock
    /// or Launchpad, which sit on the display the user is looking at. `NSScreen.main`
    /// is *not* that: for an accessory app like us it is wherever our own panel or the
    /// menu bar lives, which on a two-display setup is often the other one.
    private static var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func dismissEmergencyCover() {
        guard let panel = emergencyCover else { return }
        emergencyCover = nil
        emergencyCoverShownAt = nil
        emergencyCoverDeadline = nil
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - Settling

    /// Waits briefly for the target to have *some* window before giving up.
    ///
    /// The first read after `tracker.start` is empty for any app that is still
    /// laying out its first window — which is the normal state of a freshly
    /// launched app at the moment `NSWorkspace` reports it active. Without this
    /// wait every launch would degrade to the hidden fallback and the window
    /// shield would only ever engage for already-running apps.
    ///
    /// The tracker's own callback covers windows that appear later, so this only
    /// decides whether to abandon the attempt now.
    private func settleForWindows() async -> [TrackedWindow] {
        let deadline = Date().addingTimeInterval(FIDConstants.windowSettleTimeout)
        var found = tracker.windows

        while found.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
            if Task.isCancelled { break }
            found = tracker.windows
        }
        return found
    }

    // MARK: - Tracking callbacks

    private func handleTrackerChange(_ windows: [TrackedWindow]) {
        guard activeMode == .windowShield else { return }

        // A window going full screen takes it into its own Space, where a cover is
        // useless. Bail out rather than leave a stale panel behind.
        guard !windows.contains(where: \.isFullScreen) else {
            switchToHidden(reason: "应用切换到了全屏")
            return
        }
        guard !windows.isEmpty else {
            switchToHidden(reason: "应用没有可覆盖的窗口")
            return
        }
        syncPanels(with: windows)
    }

    private func syncPanels(with windows: [TrackedWindow]) {
        guard let target else { return }
        let live = Set(windows.map(\.key))

        for key in panels.keys where !live.contains(key) {
            guard let panel = panels[key] else { continue }
            panel.orderOut(nil)
            panel.close()
            panels.removeValue(forKey: key)
        }

        for window in windows {
            if let existing = panels[window.key] {
                existing.apply(frame: coverFrame(for: window))
            } else {
                let size = coverFrame(for: window).size
                guard size.width >= 1, size.height >= 1 else { continue }
                let panel = makePanel(for: window, target: target)
                panels[window.key] = panel
            }
        }

        presentPanels()
        // The real covers are on screen, so the stopgap is only in the way now —
        // removing it here is what turns "whole screen blacked out" into "only the
        // app's windows".
        dismissEmergencyCoverWhenReady()
    }

    /// Dismisses the stopgap once it has actually been composited **and** the
    /// per-window covers have taken its place.
    ///
    /// Two failure modes it exists to prevent:
    ///
    /// 1. *The stopgap never appears.* For an already-running app, `shield` can find
    ///    its windows on the very first read: the cover is created and torn down
    ///    inside one runloop turn, the window server never paints it, and the app's
    ///    window is visible until the per-window covers land.
    /// 2. *The stopgap disappears too early.* `makeKeyAndOrderFront` only *asks* the
    ///    window server to composite the new panels. If the stopgap is dropped before
    ///    that happens, the user gets a frame with nothing covering the app — the
    ///    "full-screen cover vanished, then the app appeared" symptom.
    ///
    /// So it waits for both a minimum on-screen time and every window cover to report
    /// `isVisible`, polling once per frame, and gives up at `emergencyCoverMaxWait`
    /// rather than blocking the screen forever.
    private func dismissEmergencyCoverWhenReady() {
        guard let panel = emergencyCover else { return }

        let shownFor = emergencyCoverShownAt.map { Date().timeIntervalSince($0) } ?? 1
        let pastMinimum = shownFor >= FIDConstants.emergencyCoverMinimumOnScreen
        let coversReady = !panels.isEmpty && panels.values.allSatisfy(\.isVisible)
        let overdue = emergencyCoverDeadline.map { Date() >= $0 } ?? true

        guard pastMinimum && (coversReady || overdue) else {
            // One frame later, then look again. The deadline guarantees this ends.
            DispatchQueue.main.async { [weak self] in
                // A later challenge may have replaced the cover while we waited.
                guard let self, self.emergencyCover === panel else { return }
                self.dismissEmergencyCoverWhenReady()
            }
            return
        }

        dismissEmergencyCover()
    }

    private func presentPanels() {
        // One key panel is enough to keep keystrokes off the app; making every
        // panel key would make focus depend on window ordering.
        var firstVisible = true
        for panel in panels.values where !panel.isVisible {
            if firstVisible {
                panel.makeKeyAndOrderFront(nil)
                firstVisible = false
            } else {
                panel.orderFront(nil)
            }
        }
    }

    /// Re-takes key after something else held it — currently the password prompt,
    /// which must be able to type but hands focus back when it goes away.
    ///
    /// Without this the shield would keep covering the app while no longer
    /// intercepting keystrokes, which is exactly the cosmetic-cover failure the
    /// panel's `canBecomeKey` exists to prevent.
    func restoreKeyPanel() {
        guard activeMode == .windowShield else { return }
        panels.values.first(where: \.isVisible)?.makeKey()
    }

    private func coverFrame(for window: TrackedWindow) -> CGRect {
        let outset = FIDConstants.shieldPanelOutset
        return window.frame.insetBy(dx: -outset, dy: -outset)
    }

    private func makePanel(for window: TrackedWindow, target: Target) -> WindowShieldPanel {
        let panel = WindowShieldPanel(
            frame: coverFrame(for: window),
            content: WindowShieldView(appName: target.appName, icon: target.icon)
        )
        panel.onCancel = { [weak self] in self?.onCancelRequested?() }
        return panel
    }

    // MARK: - Fallback

    /// Abandons the covers and hides the app instead.
    @discardableResult
    private func switchToHidden(reason: String) -> ActiveMode {
        for panel in panels.values {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        tracker.stop()
        if let target, let app = NSRunningApplication(processIdentifier: target.pid) {
            app.hide()
        }
        // After the hide, not before: dropping the stopgap first would leave a frame
        // with the app still on screen and nothing covering it.
        dismissEmergencyCover()

        activeMode = .hidden
        fallbackReason = reason
        return .hidden
    }

    // MARK: - Space changes

    /// Mission Control renders thumbnails from the window server, not from the
    /// screen, so cover panels don't appear in them. Hiding the app is the only way
    /// to keep its content out of that view.
    private func observeSpaceChanges() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activeMode == .windowShield else { return }
                self.switchToHidden(reason: "锁定时切换了 Space")
            }
        }
    }

    private func stopObservingSpaceChanges() {
        guard let spaceObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        self.spaceObserver = nil
    }
}
