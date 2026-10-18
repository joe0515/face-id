//
//  NotchWindow.swift
//  Face ID
//
//  Borderless, transparent, click-through panel. Created once and never resized —
//  all expansion/collapse is SwiftUI animating content inside this fixed window
//  (never call setFrame/setContentSize on it; only setFrameOrigin, to reposition).
//

import AppKit

final class NotchWindow: NSPanel {
    /// Whether the panel may become key. Tracked separately from
    /// `ignoresMouseEvents`, which `NotchWindowController` flips on and off as
    /// the cursor moves over/away from the visible panel — tying key status to
    /// that would stop onboarding's text fields taking focus whenever the
    /// cursor happened to sit outside the panel.
    var acceptsKey = false

    /// Esc while an app-lock challenge is on screen. Exists because the window
    /// shield isn't always there to catch it — in the `.hidden` fallback the app has
    /// no windows to cover, so this panel is the only surface left that can offer a
    /// way out of a challenge the user can't pass.
    var onEscape: (() -> Void)?

    private static let escapeKeyCode: UInt16 = 53

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Decorative by default — clicks pass through until a failed attempt is
        // waiting to be tapped for retry (see NotchWindowController.setInteractive).
        ignoresMouseEvents = true
    }

    /// Must become key while interactive or the tap-to-retry gesture never receives
    /// the click; never becomes main, so it doesn't take over as the app's primary window.
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == Self.escapeKeyCode, let onEscape else {
            // Not forwarded to `super`: the panel has no responder that wants these,
            // and NSResponder's default is to beep.
            return
        }
        onEscape()
    }
}
