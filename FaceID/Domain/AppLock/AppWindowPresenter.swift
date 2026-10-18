//
//  AppWindowPresenter.swift
//  Face ID
//
//  Puts an app's windows back on screen after a challenge.
//
//  `NSRunningApplication.unhide()` restores the app's hidden flag, and
//  `activate()` asks the system to make it frontmost — but on macOS 14+
//  `activateIgnoringOtherApps` is deprecated and ignored, and the system decides
//  on its own whether activation is warranted. For an app whose windows were
//  ordered out (WeChat after Cmd+W, or any app we hid during the challenge) that
//  decision is often "no": the process is back, the windows are not, and the user
//  has to click the Dock icon to see anything.
//
//  Raising the window through Accessibility is explicit and works regardless of
//  what the system decides. Requires the same grant the window shield already uses.
//

import AppKit
import ApplicationServices

enum AppWindowPresenter {

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

    private static func isMain(_ window: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &raw) == .success,
              let value = raw as? Bool else { return false }
        return value
    }
}
