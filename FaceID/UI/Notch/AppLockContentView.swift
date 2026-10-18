//
//  AppLockContentView.swift
//  Face ID
//
//  The app-lock face of the notch panel: the locked app's own icon, then the same
//  scan animation the whole-machine path uses.
//
//  It deliberately mirrors `MinimalUnlockView`'s `[leading][gap][media]` silhouette
//  and its slot widths rather than inventing a second layout, so the panel keeps the
//  same shape and metrics whichever kind of unlock is in flight. What differs is the
//  leading slot: an app icon (which identifies *what* is locked) instead of the lock
//  glyph (which only signals *that* something is).
//
//  The panel stays in the compact silhouette for this — never the full square scan
//  panel — because covering more of the screen than necessary is exactly what this
//  feature was asked not to do.
//

import AppKit
import SwiftUI

/// Payload for a locked app's challenge.
///
/// Carries its own `ScanMedia` rather than relying on the controller's `.scan` case:
/// resolving an attempt (success/failure) swaps the video, and if that lived in a
/// separate content case it would evict the app's icon and name mid-animation.
///
/// Main-actor isolated (the project's default) rather than `nonisolated`: `ScanMedia`
/// is itself main-actor isolated, so its `Equatable` conformance is only usable from
/// this side.
struct AppLockContent: Equatable {
    let bundleID: String
    let displayName: String
    /// Shown in the leading slot. `nil` falls back to a generic glyph.
    let icon: NSImage?
    var media: ScanMedia = .idle

    static func == (lhs: AppLockContent, rhs: AppLockContent) -> Bool {
        // The icon isn't `Equatable`; identity is the right test here because the
        // payload is built once per challenge from the store's cached image.
        lhs.bundleID == rhs.bundleID
            && lhs.displayName == rhs.displayName
            && lhs.media == rhs.media
            && lhs.icon === rhs.icon
    }
}

struct AppLockContentView: View {
    let content: AppLockContent
    /// Inset from the silhouette's left/right edges. The caller folds the notch's
    /// flare allowance into this where it applies.
    let edgeInset: CGFloat
    var iconSize: CGFloat = NotchGeometry.minimalAppIconSize
    var mediaWidth: CGFloat = NotchGeometry.minimalMediaWidth
    var mediaVerticalInset: CGFloat = NotchGeometry.minimalMediaVerticalInset
    /// Applied to the video only — the icon must stay steady while the scan breathes.
    var pulseScale: CGFloat = 1
    var pulseOpacity: Double = 1

    var body: some View {
        HStack(spacing: 0) {
            appIcon
                // Same slot width as the lock glyph it stands in for, so the two
                // silhouettes line up pixel-for-pixel.
                .frame(width: mediaWidth)

            Spacer(minLength: 0)

            ScanAnimationView(media: content.media)
                .padding(.vertical, mediaVerticalInset)
                .frame(width: mediaWidth)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, edgeInset)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = content.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .accessibilityLabel(content.displayName)
        } else {
            // macOS app icons ship pre-masked, so no clipping here — rounding again
            // would visibly eat into the artwork's own corner radius.
            Image(systemName: "app.dashed")
                .font(.system(size: iconSize * 0.92, weight: .semibold))
                .foregroundStyle(FIDTheme.textPrimary)
                .accessibilityLabel(content.displayName)
        }
    }
}
