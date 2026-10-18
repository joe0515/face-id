//
//  WindowShieldView.swift
//  Face ID
//
//  What the user sees over a locked app's window: the app's own content blurred
//  out, dimmed, and badged as locked. Deliberately quiet — the actual challenge is
//  carried by the notch panel, so this only has to explain why the app stopped
//  responding.
//

import AppKit
import SwiftUI

struct WindowShieldView: View {
    let appName: String
    let icon: NSImage?

    var body: some View {
        ZStack {
            ShieldBackdrop()
            Color.black.opacity(FIDConstants.shieldDimOpacity)
            content
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            iconBadge

            Text(appName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text("已被 Face ID 锁定")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))

            Text("看向刘海即可解锁 —— 或按 Esc 退出该应用")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 2)
        }
        .padding(24)
    }

    /// The app's own icon, so the cover names itself without a second label. Falls
    /// back to a lock glyph when the icon wasn't persisted.
    @ViewBuilder
    private var iconBadge: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .offset(x: 6, y: 6)
                }
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// `blendingMode = .behindWindow` is what makes this blur the *other app's* content
/// rather than Face ID's own (empty) window — the material samples whatever the
/// window server has underneath.
private struct ShieldBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
