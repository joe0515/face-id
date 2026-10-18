//
//  ChallengePasswordPanel.swift
//  Face ID
//
//  The last rung of the app-lock ladder: a small centred prompt for the app
//  password, shown when neither a face nor Touch ID got the user through.
//
//  Why its own window rather than the notch panel: the notch silhouette is a
//  glanceable status surface with no room for a text field, and the panel is
//  deliberately reserved for "look here and wait". Asking for input is a different
//  interaction and gets a different surface.
//
//  Why not the shielded app's own window: in the `.hidden` fallback there is no
//  window to host anything, and a challenge that only works in one of the two
//  enforcement modes would be worse than one that works in both.
//
//  The same instance is reused across a wrong-password retry — the prompt stays up
//  and only the inline error changes, so a typo doesn't make the window blink.
//

import AppKit
import Observation
import SwiftUI

// MARK: - Content

@Observable
@MainActor
final class ChallengePasswordModel {
    let appName: String
    let icon: NSImage?
    var password = ""
    /// Non-nil shows the inline error under the field.
    var errorMessage: String?

    init(appName: String, icon: NSImage?) {
        self.appName = appName
        self.icon = icon
    }
}

struct ChallengePasswordView: View {
    let model: ChallengePasswordModel
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            header
            field
            footer
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(background)
        .onAppear { isFieldFocused = true }
    }

    static let size = CGSize(width: 340, height: 208)

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 8) {
            iconBadge

            Text(model.appName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FIDTheme.textPrimary)
                .lineLimit(1)

            Text("输入应用密码以继续")
                .font(.system(size: 12))
                .foregroundStyle(FIDTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var iconBadge: some View {
        if let icon = model.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(FIDTheme.textPrimary)
                .frame(width: 44, height: 44)
        }
    }

    private var field: some View {
        VStack(spacing: 6) {
            SecureField("应用密码", text: Binding(
                get: { model.password },
                set: { model.password = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .focused($isFieldFocused)
            .onSubmit(onSubmit)

            // Reserved whether or not there is an error, so the buttons don't jump
            // when one appears.
            Text(model.errorMessage ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(model.errorMessage == nil ? .clear : Color.red.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("解锁", action: onSubmit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.password.isEmpty)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

// MARK: - Panel

/// Borderless prompt that can take key. It must be able to, or the secure field
/// would never receive a keystroke.
private final class PasswordPromptWindow: NSPanel {

    var onCancel: (() -> Void)?

    private static let escapeKeyCode: UInt16 = 53

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: ChallengePasswordView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        // Below the notch overlay (`mainMenu + 3`), above the window shield
        // (`.floating`) it would otherwise sit level with and lose to on ordering.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == Self.escapeKeyCode else {
            super.keyDown(with: event)
            return
        }
        onCancel?()
    }
}

// MARK: - Controller

@MainActor
final class ChallengePasswordPanel {

    /// Called whenever the prompt goes away — the window shield has to take key back,
    /// or keystrokes would start reaching the app it is covering again.
    @ObservationIgnored var onClose: (() -> Void)?

    @ObservationIgnored private var window: PasswordPromptWindow?
    @ObservationIgnored private var model: ChallengePasswordModel?
    @ObservationIgnored private var continuation: CheckedContinuation<String?, Never>?

    var isVisible: Bool { window?.isVisible == true }

    /// Shows the prompt and waits for the user to submit or dismiss it.
    ///
    /// Re-entrant by design: calling it again while already open reuses the window,
    /// clears the field and swaps in a new error line.
    /// - Returns: the entered password, or `nil` if the user dismissed the prompt.
    func prompt(appName: String, icon: NSImage?, errorMessage: String?) async -> String? {
        // A previous wait is still outstanding — resolve it before replacing it, or
        // the awaiting task would hang forever.
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: nil)
        }

        let model = makePanelIfNeeded(appName: appName, icon: icon)
        model.errorMessage = errorMessage
        model.password = ""

        showWindow()

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Swaps the inline error while the prompt is open. Ignored when it isn't —
    /// `prompt(...)` takes the current message as an argument on the next pass.
    func showError(_ message: String) {
        guard isVisible else { return }
        model?.errorMessage = message
    }

    /// Closes the prompt for good. Resolves any outstanding wait as a dismissal.
    func dismiss() {
        guard let window else { return }
        window.orderOut(nil)
        window.close()
        self.window = nil
        model = nil
        onClose?()

        if let continuation {
            self.continuation = nil
            continuation.resume(returning: nil)
        }
    }

    // MARK: - Private

    private func makePanelIfNeeded(appName: String, icon: NSImage?) -> ChallengePasswordModel {
        if let model { return model }

        let model = ChallengePasswordModel(appName: appName, icon: icon)
        let window = PasswordPromptWindow()
        window.onCancel = { [weak self] in self?.cancel() }
        window.contentView = NSHostingView(
            rootView: ChallengePasswordView(
                model: model,
                onSubmit: { [weak self] in self?.submit() },
                onCancel: { [weak self] in self?.cancel() }
            )
        )
        self.model = model
        self.window = window
        return model
    }

    private func showWindow() {
        guard let window else { return }
        centerOnActiveScreen(window)
        // Deliberately not `makeKeyAndOrderFront` *plus* an explicit activate: the
        // panel is `nonactivatingPanel` so it can take key without pulling Face ID
        // forward, which would fight the notch panel and the shield for focus.
        window.makeKeyAndOrderFront(nil)
    }

    private func submit() {
        guard let model, let continuation else { return }
        let entered = model.password
        self.continuation = nil
        // The window stays up: a wrong password is followed immediately by another
        // `prompt(...)` call, and hiding/reshowing would make it flicker.
        continuation.resume(returning: entered)
    }

    private func cancel() {
        guard let window, let continuation else { return }
        self.continuation = nil
        window.orderOut(nil)
        continuation.resume(returning: nil)
        onClose?()
    }

    /// Centres on the screen holding the key window, falling back to the main one.
    private func centerOnActiveScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrame(CGRect(origin: origin, size: size), display: false)
    }
}
