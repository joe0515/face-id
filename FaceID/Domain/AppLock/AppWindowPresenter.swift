//
//  AppWindowPresenter.swift
//  Face ID
//
//  Puts an app's windows back on screen after a challenge.
//
//  Two very different situations have to be handled, and they are not the same bug:
//
//  - **A cold-launched app** (Photos) creates its window *while* the challenge is
//    running, i.e. while the app is hidden. `unhide()` brings that window straight
//    back — measured on this machine.
//  - **An app that was already running** (WeChat after its window was closed, then
//    re-opened from the Dock) gets a window that macOS creates for the Dock click and
//    that our `hide()` immediately orders out again. `unhide()` does *not* bring that
//    one back, and `activate()` is not obliged to either — on macOS 14+ the system
//    decides on its own whether activation is warranted. The result is the app being
//    back with no window on screen, and the user having to click the Dock icon a
//    second time.
//
//  So restoration is layered, each step only running when the previous one left the
//  app windowless. The last step — `openApplication` — is the programmatic equivalent
//    of that second Dock click, which is exactly what the user should not have to do.
//

import AppKit
import ApplicationServices

enum AppWindowPresenter {

    /// Whether the app currently has a reasonably large window actually on screen.
    ///
    /// Uses the window server, not AX: it must answer correctly while the app is still
    /// hidden (AX reports nothing then), and window bounds need no extra grant.
    @MainActor
    static func hasVisibleWindow(_ app: NSRunningApplication) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && (info[kCGWindowLayer as String] as? Int) == 0
                && (info[kCGWindowIsOnscreen as String] as? Bool) == true
                && ((info[kCGWindowBounds as String] as? [String: Any])
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }?.width ?? 0) >= 200
                && ((info[kCGWindowBounds as String] as? [String: Any])
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }?.height ?? 0) >= 200
        }
    }

    /// Raises the app's frontmost standard window, if it has any. Safe to call for an
    /// app with no windows — it simply does nothing.
    @MainActor
    static func raiseMainWindow(of app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return }

        // AX order is not guaranteed, so prefer the window that already claims to be
        // main, and fall back to the first one.
        let target = windows.first(where: { isMain($0) }) ?? windows.first
        guard let target else { return }

        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }

    /// Restores the app's windows after a successful unlock, escalating only as far as
    /// needed. Call once, right after `unhide()` + `activate()`.
    ///
    /// Every step is gated on "still no visible window", so the common case (a
    /// cold-launched app, or one whose `unhide()` worked) costs nothing beyond one
    /// window-server query. The whole sequence stays inside `reLockCooldown` so the
    /// re-open can't immediately trigger another challenge.
    @MainActor
    static func scheduleRestore(_ app: NSRunningApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard !hasVisibleWindow(app) else { return }
            raiseMainWindow(of: app)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !hasVisibleWindow(app) else { return }
                // Last resort: re-open the application. For an already-running process
                // this is the same thing the Dock does — activate plus the reopen
                // semantics that make an app with no windows show one.
                guard let url = app.bundleURL else { return }
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            }
        }
    }

    private static func isMain(_ window: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &raw) == .success,
              let value = raw as? Bool else { return false }
        return value
    }
}
