//
//  ProgressiveHeaderBlur.swift
//  Face ID
//
//  A backdrop blur behind the header whose strength fades from strongest at
//  the window's top edge to none by the bottom of the blur zone, so
//  scrolled rows sharpen up as they pass underneath rather than cutting
//  from blurred to crisp at a hard line.
//
//  SwiftUI's native `scrollEdgeEffectStyle(.soft, for: .top)` (macOS 26) is
//  the system version of exactly this, but it needs macOS 26 — this
//  window's deployment target is 15.0, and the header here is a custom
//  overlay rather than a real toolbar/safe-area inset for that system
//  effect to attach to. So this fakes it manually: each `Material` (weakest
//  to strongest) is masked to fade out over a shorter distance than the
//  last, so only a thin band right at the top ever stacks every layer —
//  the same layered-mask trick most manual "progressive blur" implementations
//  use, since `.blur(radius:)` itself has no per-pixel-varying radius.
//

import SwiftUI

struct ProgressiveHeaderBlur: View {
    var height: CGFloat

    /// Weakest to strongest. The weakest spans the whole zone (top fully
    /// opaque, fading to clear by the bottom edge); each stronger material
    /// after it fades out over a shorter span, so only the topmost band
    /// accumulates all of them for the strongest combined blur.
    private static let materials: [Material] = [
        .ultraThinMaterial, .thinMaterial, .regularMaterial,
    ]

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(Self.materials.enumerated()), id: \.offset) { index, material in
                let fadeEnd = 1 - CGFloat(index) / CGFloat(Self.materials.count)
                Rectangle()
                    .fill(material)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .clear, location: fadeEnd),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .frame(height: height)
        // Purely decorative — never intercept clicks meant for the header
        // buttons layered on top of it or rows scrolling underneath.
        .allowsHitTesting(false)
    }
}
