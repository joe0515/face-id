//
//  WindowShieldPanel.swift
//  Face ID
//
//  One borderless panel parked exactly over one window of the app being shielded.
//
//  Two things matter about its configuration:
//
//  • It **accepts mouse events**, so a click can't reach the window underneath.
//  • It **can become key**, so keystrokes can't either. Without that, the app's
//    window would stay key and the user could type blindly into a locked app —
//    the visible cover would be cosmetic.
//
//  It is `nonactivatingPanel`, so taking key never activates Face ID itself:
//  activating would fight the notch overlay and the menu bar for focus.
//

import AppKit
import SwiftUI

final class WindowShieldPanel: NSPanel {

    /// Esc abandons the challenge, mirroring the notch panel's cancel affordance.
    var onCancel: (() -> Void)?

    private static let escapeKeyCode: UInt16 = 53

    init(frame: CGRect, content: some View) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        // No fade-in: a shield that animates in leaves a frame where the app's
        // content is briefly visible.
        animationBehavior = .none

        // Above ordinary app windows (which sit at `.normal`), below the notch
        // overlay which rides at `.mainMenu + 3`.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false

        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Geometry

    /// Repositions onto the tracked window. Called on every geometry change.
    func apply(frame: CGRect) {
        guard self.frame != frame else { return }
        setFrame(frame, display: true)
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == Self.escapeKeyCode else {
            // Deliberately not forwarded to `super`: NSResponder's default beeps,
            // and passing the event on is precisely what the shield prevents.
            return
        }
        onCancel?()
    }
}
