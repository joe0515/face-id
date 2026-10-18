//
//  OnboardingControls.swift
//  Face ID
//
//  Shared pill-shaped primitives (buttons, permission rows, the password field) so each
//  step view stays a plain layout description instead of re-deriving this chrome.
//

import SwiftUI
import AppKit

/// The primary (accent-filled) or secondary (dark) pill button used for
/// Next/Back/Confirm across every step.
struct PillButton: View {
    enum Style { case primary, secondary }

    let title: String
    var style: Style = .primary
    var width: CGFloat = OnboardingMetrics.primaryButtonWidth
    var isEnabled = true
    /// Return/Enter activates this button when a focused text field doesn't
    /// consume it — same as a Mac dialog's default button.
    var isDefault = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Text(title)
                .font(FIDTheme.Font.button)
                .foregroundStyle(FIDTheme.textPrimary)
                .frame(width: width, height: OnboardingMetrics.pillButtonHeight)
                .background(background)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)

        if isDefault {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    private var background: Color {
        style == .primary ? FIDTheme.accent : FIDTheme.surface
    }
}

/// One row on the Permissions screen: status dot, title/detail, and a Grant
/// pill that disables once granted.
struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? FIDTheme.statusGranted : FIDTheme.statusDenied)
                .frame(width: OnboardingMetrics.statusDotSize, height: OnboardingMetrics.statusDotSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(FIDTheme.Font.rowTitle)
                    .foregroundStyle(FIDTheme.textPrimary)
                Text(detail)
                    .font(FIDTheme.Font.rowDetail)
                    .foregroundStyle(FIDTheme.textDetail)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            Button(action: grant) {
                Text(granted ? "已授权" : "授权")
                    .font(FIDTheme.Font.grantLabel)
                    .foregroundStyle(FIDTheme.textPrimary)
                    .frame(width: OnboardingMetrics.grantButtonSize.width, height: OnboardingMetrics.grantButtonSize.height)
                    .background(FIDTheme.surfaceRaised)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(granted)
            .opacity(granted ? 0.6 : 1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: OnboardingMetrics.permissionRowHeight)
        .background(FIDTheme.surface)
        .clipShape(Capsule())
    }
}

/// The camera picker on the "Select camera" step: a full-width capsule row (same chrome
/// as `PermissionRow`) holding a compact native pull-down, left-aligned — the same
/// `Menu`/`.menuStyle(.borderlessButton)` construction as `CameraSettingsPage.cameraPicker`
/// and `GeneralSettingsPage.displayPicker`. Stretching that construction to fill the whole
/// row breaks its internal label layout; left hugging its own content, at the width those
/// two already prove out, it behaves correctly.
struct CameraSelectionPill: View {
    let label: String
    let devices: [CameraDevice]
    let onSelect: (String?) -> Void

    var body: some View {
        HStack {
            Menu {
                Button("系统默认") { onSelect(nil) }
                ForEach(devices) { device in
                    Button(device.name) { onSelect(device.id) }
                }
            } label: {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(FIDTheme.textPrimary)
                    .font(.system(size: 12))
                    .padding(.horizontal, 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            // Window-level accent tint otherwise paints the menu label blue.
            .tint(FIDTheme.textPrimary)
            .frame(width: 220, height: 30)

            Spacer(minLength: 0)

            // Decorative only — the menu above is the actual tap target.
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FIDTheme.textSecondary)
        }
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity)
        .frame(height: OnboardingMetrics.permissionRowHeight)
        .background(FIDTheme.surface)
        .clipShape(Capsule())
    }
}

/// The password entry field — a pill-shaped `SecureField`.
struct PillSecureField: View {
    let placeholder: String
    @Binding var text: String
    var autofocus = false
    var onSubmit: () -> Void = {}
    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(FIDTheme.placeholder))
            .textFieldStyle(.plain)
            .font(FIDTheme.Font.passwordPlaceholder)
            .foregroundStyle(FIDTheme.textPrimary)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .background(OnboardingFieldFirstResponder(enabled: autofocus, onReady: { isFocused = true }))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(FIDTheme.surface)
            .clipShape(Capsule())
    }
}

/// The plain-text twin of `PillSecureField`, used by the naming step. Same
/// capsule so the two read as one control family — only the echo differs.
struct PillTextField: View {
    let placeholder: String
    @Binding var text: String
    var autofocus = false
    var onSubmit: () -> Void = {}
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(FIDTheme.placeholder))
            .textFieldStyle(.plain)
            .font(FIDTheme.Font.passwordPlaceholder)
            .foregroundStyle(FIDTheme.textPrimary)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .background(OnboardingFieldFirstResponder(enabled: autofocus, onReady: { isFocused = true }))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(FIDTheme.surface)
            .clipShape(Capsule())
    }
}

/// Makes a notch-hosted field first responder after the step spring finishes. SwiftUI's
/// `.focused` alone is ignored while the panel is still becoming key.
private struct OnboardingFieldFirstResponder: NSViewRepresentable {
    let enabled: Bool
    let onReady: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard enabled, !context.coordinator.didSchedule else { return }
        context.coordinator.didSchedule = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.fieldAutofocusDelay))
            NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<8 {
                if nsView.window != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let window = nsView.window else { return }
            window.makeKeyAndOrderFront(nil)
            if let field = nearestTextField(from: nsView) {
                window.makeFirstResponder(field)
            }
            onReady()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var didSchedule = false }
}

private func nearestTextField(from view: NSView) -> NSView? {
    var current: NSView? = view.superview
    while let node = current {
        if let field = firstTextField(in: node) { return field }
        current = node.superview
    }
    return nil
}

private func firstTextField(in view: NSView) -> NSView? {
    if view is NSTextField { return view }
    for child in view.subviews {
        if let found = firstTextField(in: child) { return found }
    }
    return nil
}
