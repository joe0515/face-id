//
//  ScanSweepIndicator.swift
//  Face ID
//
//  Live "actively scanning" feedback for the full scan panel.
//
//  The scanning phase legitimately runs for several seconds (camera warm-up
//  plus the detection window), and it used to show nothing but the static
//  face glyph with the breathing pulse — which read as frozen rather than as
//  working. A soft light bar sweeping down over the glyph says "scanning"
//  in the most literal way possible, matches the accent palette the rest of
//  the panel uses, and costs no new assets.
//
//  The loop is built from discrete animated passes (the same pattern as
//  `NotchOverlayView`'s scan pulse) rather than one `repeatForever`: a
//  repeat-forever animation owns its properties for its whole lifetime and
//  snaps when the view leaves the hierarchy, whereas discrete passes let the
//  phase change tear the view down on any frame without a jump.
//

import SwiftUI

struct ScanSweepIndicator: View {
    /// One full top→bottom pass.
    static let sweepDuration: Double = 1.6
    /// Fade in/out at the ends of each pass so the loop point never pops.
    static let edgeFadeDuration: Double = 0.22
    /// A short beat between passes — a continuous back-to-back sweep reads
    /// as mechanical; a pause reads as a deliberate scan rhythm.
    static let interPassGap: Double = 0.15

    @State private var travel: CGFloat = 0
    @State private var isVisible = false
    @State private var loopTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            bar
                .offset(y: travel * proxy.size.height)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    /// A soft horizontal light bar: bright core, transparent ends, slight
    /// blur so it reads as a beam rather than a rule.
    private var bar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        FIDTheme.accentDeep,
                        FIDTheme.accentBright,
                        Color.white.opacity(0.85),
                        FIDTheme.accentBright,
                        FIDTheme.accentDeep,
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 2.5)
            .blur(radius: 1.5)
    }

    private func start() {
        guard loopTask == nil else { return }
        loopTask = Task {
            while !Task.isCancelled {
                // Fade in while the pass begins, so the bar materializes as
                // it enters rather than popping in at the top edge.
                withAnimation(.easeIn(duration: Self.edgeFadeDuration)) { isVisible = true }
                withAnimation(.easeInOut(duration: Self.sweepDuration)) { travel = 1 }
                try? await Task.sleep(for: .seconds(Self.sweepDuration))
                guard !Task.isCancelled else { break }

                withAnimation(.easeOut(duration: Self.edgeFadeDuration)) { isVisible = false }
                try? await Task.sleep(for: .seconds(Self.edgeFadeDuration))
                guard !Task.isCancelled else { break }

                // Rewind for the next pass without animating the jump — the
                // bar is invisible here, so the reset must never render.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { travel = 0 }

                try? await Task.sleep(for: .seconds(Self.interPassGap))
            }
        }
    }

    private func stop() {
        loopTask?.cancel()
        loopTask = nil
    }
}
