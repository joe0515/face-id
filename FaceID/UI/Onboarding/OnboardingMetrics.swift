//
//  OnboardingMetrics.swift
//  Face ID
//
//  Onboarding's layout numbers, centralized so panel-fit tuning happens in
//  one place instead of being scattered across the step views.
//

import SwiftUI

enum OnboardingMetrics {
    /// Shared spring for both the notch panel's resize and the step content's
    /// scroll+blur transition, so the two always move together.
    static let stepAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// Wait for `stepAnimation` to settle before focusing a text field — focusing during
    /// the spring is a no-op since the field isn't in a key window yet.
    static let fieldAutofocusDelay: Double = 0.48

    // MARK: - Panel size — EDIT HERE
    //
    // `panelWidth` is shared by every step except `.enroll`; widths are not split per
    // style, but height is fully independent per step and per style.

    /// Width used by every step except `.enroll`.
    static let panelWidth: CGFloat = 380

    /// The camera/enrollment step's width — deliberately independent of `panelWidth`.
    static let enrollPanelWidth: CGFloat = 320

    static let notchIntroHeight: CGFloat = 175
    static let pillIntroHeight: CGFloat = 175
    /// **Measured, not guessed.** 245 used to sit here, which is 31pt short of what the
    /// stack actually needs — the padded content overflows the panel and the bottom
    /// inset (and part of the button row) gets cut off, so the buttons end up flush
    /// against the rounded corner.
    static let notchPermissionsHeight: CGFloat = 276
    static let pillPermissionsHeight: CGFloat = 254

    /// The launch-time permission review replays the permissions step with one extra
    /// row (the Accessibility privilege is split in two) **and a Keychain row**, plus a
    /// one-line caption that may or may not be there.
    ///
    /// These are the **fitted heights of the real stacks** (measured by rendering the
    /// same fonts, insets and fixed row/button heights at `panelWidth`), not sums of
    /// hand-picked parts. `OnboardingNotchView` clips to `panelSize`, so a constant
    /// that is even a few points short silently eats the bottom inset instead of
    /// failing loudly — which is exactly how the buttons ended up touching the panel
    /// edge. If the copy or the row count changes, re-measure rather than add a fudge
    /// factor.
    ///
    /// The value is the **taller** of the two states so `maxPanelHeight(for:)` sizes the
    /// window envelope from it; `permissionReviewPanelSize` subtracts the caption when
    /// it isn't on screen.
    ///
    /// Re-measured 2026-10-24 after the two Accessibility rows were merged into one
    /// (they are a single checkbox in System Settings): three rows, rendered at
    /// `panelWidth` with `ImageRenderer` — notch 354 / pill 332 without the caption,
    /// and +38 with it.
    static let notchPermissionReviewHeight: CGFloat = 392
    static let pillPermissionReviewHeight: CGFloat = 370
    /// The caption line plus the stack spacing it introduces — 38 in both styles.
    static let permissionReviewHintHeight: CGFloat = 38

    /// `withHint` is false while both Accessibility privileges are still missing — the
    /// caption only exists in the half-granted state, and reserving room for it
    /// otherwise leaves the panel visibly too tall.
    static func permissionReviewPanelSize(for style: NotchPanelStyle, withHint: Bool) -> CGSize {
        let full = style == .notch ? notchPermissionReviewHeight : pillPermissionReviewHeight
        return CGSize(width: panelWidth, height: withHint ? full : full - permissionReviewHintHeight)
    }
    static let notchSecurityNoticeHeight: CGFloat = 260
    static let pillSecurityNoticeHeight: CGFloat = 260
    static let notchPreSetupHeight: CGFloat = 220
    static let pillPreSetupHeight: CGFloat = 220
    static let notchSelectCameraHeight: CGFloat = 228
    static let pillSelectCameraHeight: CGFloat = 228
    static let notchEnrollHeight: CGFloat = 344
    static let pillEnrollHeight: CGFloat = 350
    static let notchNameHeight: CGFloat = 230
    static let pillNameHeight: CGFloat = 230
    static let notchPasswordHeight: CGFloat = 260
    static let pillPasswordHeight: CGFloat = 260
    static let notchAppLockingHeight: CGFloat = 262
    static let pillAppLockingHeight: CGFloat = 262
    static let notchCompleteHeight: CGFloat = 95
    static let pillCompleteHeight: CGFloat = 95

    static func panelHeight(for step: OnboardingStep, style: NotchPanelStyle) -> CGFloat {
        switch (step, style) {
        case (.intro, .notch): return notchIntroHeight
        case (.intro, .pill): return pillIntroHeight
        case (.permissions, .notch): return notchPermissionsHeight
        case (.permissions, .pill): return pillPermissionsHeight
        case (.securityNotice, .notch): return notchSecurityNoticeHeight
        case (.securityNotice, .pill): return pillSecurityNoticeHeight
        case (.preSetup, .notch): return notchPreSetupHeight
        case (.preSetup, .pill): return pillPreSetupHeight
        case (.selectCamera, .notch): return notchSelectCameraHeight
        case (.selectCamera, .pill): return pillSelectCameraHeight
        case (.enroll, .notch): return notchEnrollHeight
        case (.enroll, .pill): return pillEnrollHeight
        case (.name, .notch): return notchNameHeight
        case (.name, .pill): return pillNameHeight
        case (.password, .notch): return notchPasswordHeight
        case (.password, .pill): return pillPasswordHeight
        case (.appLocking, .notch): return notchAppLockingHeight
        case (.appLocking, .pill): return pillAppLockingHeight
        case (.complete, .notch): return notchCompleteHeight
        case (.complete, .pill): return pillCompleteHeight
        }
    }

    static func panelSize(for step: OnboardingStep, style: NotchPanelStyle) -> CGSize {
        let width = step == .enroll ? enrollPanelWidth : panelWidth
        return CGSize(width: width, height: panelHeight(for: step, style: style))
    }

    static func panelBottomRadius(for step: OnboardingStep) -> CGFloat {
        switch step {
        case .enroll: return 51.5
        default: return 55
        }
    }

    /// The envelope the fixed notch window itself must be sized to fit — see
    /// `NotchGeometry.windowSize(for:)`.
    static let maxPanelWidth: CGFloat = max(panelWidth, enrollPanelWidth)

    static func maxPanelHeight(for style: NotchPanelStyle) -> CGFloat {
        switch style {
        case .notch:
            return [
                notchIntroHeight, notchPermissionsHeight, notchPermissionReviewHeight, notchSecurityNoticeHeight, notchPreSetupHeight,
                notchSelectCameraHeight, notchEnrollHeight, notchNameHeight, notchPasswordHeight,
                notchAppLockingHeight, notchCompleteHeight,
            ].max() ?? notchEnrollHeight
        case .pill:
            return [
                pillIntroHeight, pillPermissionsHeight, pillPermissionReviewHeight, pillSecurityNoticeHeight, pillPreSetupHeight,
                pillSelectCameraHeight, pillEnrollHeight, pillNameHeight, pillPasswordHeight,
                pillAppLockingHeight, pillCompleteHeight,
            ].max() ?? pillEnrollHeight
        }
    }

    // MARK: - Content insets, per style — EDIT HERE
    //
    // Independent top/left/right/bottom insets for onboarding step content — does NOT
    // apply to scan/unlock content (see `NotchGeometry.notchContentPadding*` for that).

    /// Deliberately generous in notch style: the physical notch's camera
    /// housing overlaps the very top of the panel, so title/text content
    /// needs real clearance below it or it reads as clipped.
    static let titleTopInset: CGFloat = 50
    /// Pill style has no housing to clear — the panel floats free of the
    /// screen edge — so the same inset just leaves content sitting low.
    static let pillTitleTopInset: CGFloat = 32

    static let notchContentLeadingInset: CGFloat = 28
    static let notchContentTrailingInset: CGFloat = 28
    static let notchContentBottomInset: CGFloat = 40

    static let pillContentLeadingInset: CGFloat = 30
    static let pillContentTrailingInset: CGFloat = 30
    static let pillContentBottomInset: CGFloat = 36

    static func titleTopInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillTitleTopInset : titleTopInset
    }

    static func contentLeadingInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentLeadingInset : notchContentLeadingInset
    }

    static func contentTrailingInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentTrailingInset : notchContentTrailingInset
    }

    static func contentBottomInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentBottomInset : notchContentBottomInset
    }

    // MARK: - Shared control geometry

    static let controlHorizontalPadding: CGFloat = 24

    static let pillButtonHeight: CGFloat = 38
    static let pillButtonRadius: CGFloat = 17
    static let primaryButtonWidth: CGFloat = 160

    static let permissionRowHeight: CGFloat = 44
    static let grantButtonSize = CGSize(width: 60, height: 26)
    static let statusDotSize: CGFloat = 16

    // MARK: - Camera / tick ring
    //
    // The preview is kept smaller than the ring so the tick marks stay
    // visible around its edge instead of being covered by the video.

    static let cameraCircleDiameter: CGFloat = 185
    static let tickRingOuterDiameter: CGFloat = 200

    /// 10 ticks per 45deg sector x 8 sectors = 80 ticks tiling the ring.
    static let tickCount = 80
    static let ticksPerSector = 10
    /// Width of the live turn indicator, in ticks — under a sector's 10 so it reads as a pointer.
    static let turnIndicatorTickSpan = 6
    /// Indicator stretch at full intensity — short of `tickLengthLit` so it never reads as captured.
    static let turnIndicatorLengthBoost: CGFloat = 5
    static let tickLengthUnlit: CGFloat = 12
    static let tickLengthLit: CGFloat = 20
    static let tickWidth: CGFloat = 2.4
    /// Stroke width of the solid ring the ticks merge into on completion. Its own
    /// constant rather than reusing `tickLengthLit`, so it can be tuned independently.
    static let completionRingWidth: CGFloat = 14
    /// How far inside the lit ticks' outer tips the completion ring's outer edge sits —
    /// without this it reads as slightly too large once the ticks vanish.
    static let completionRingRadiusInset: CGFloat = 8
    /// Width ticks expand to when they merge into the completion ring.
    static var tickWidthComplete: CGFloat {
        2 * .pi * (tickRingOuterDiameter / 2) / CGFloat(tickCount) * 1.2
    }
    /// Per-tick stagger so a captured sector fills as a sweep rather than
    /// snapping all ten ticks at once.
    static let tickStagger: Double = 0.008

    /// Diameter reserved for the camera + ring, including room for lit
    /// ticks that grow outward from `tickRingOuterDiameter`.
    static var enrollCameraClusterDiameter: CGFloat {
        tickRingOuterDiameter + tickLengthLit * 2
    }

    // MARK: - Enrollment camera-complete sequence timings (seconds)

    static let guideOverlayFadeOut: Double = 0.35
    static let previewFadeOut: Double = 0.4
    static let checkmarkDelay: Double = 0.2
    static let checkmarkDrawDuration: Double = 0.28
    /// How long the checkmark holds after the nine poses before the panel
    /// moves on to the naming step.
    static let cameraCompleteToNameDelay: Double = 3.0
    static let completeScreenDismissDelay: Double = 3.0

    // MARK: - In-panel enrollment chrome

    static let enrollInstructionBottomPadding: CGFloat = 30
    static let enrollInstructionHorizontalPadding: CGFloat = 20
    static let enrollCameraTopPaddingNotch: CGFloat = 40
    static let enrollCameraTopPaddingPill: CGFloat = 30

    static let enrollCloseButtonSize: CGFloat = 28
    /// Inset from the panel's top and trailing edges — independent of
    /// enroll content padding so the control sits on the window chrome,
    /// not the camera cluster.
    static let enrollCloseButtonEdgePadding: CGFloat = 18

    static let enrollTooFarChevronSize: CGFloat = 32
    static let enrollInstructionFadeIn: Double = 0.3
    static let enrollInstructionFadeOut: Double = 0.35

    // MARK: - Enrollment direction sweep

    /// Pause between the last streak of a cycle finishing and the next
    /// cycle starting, so the motion reads as a repeated cue rather than
    /// a continuous wash of light.
    static let sweepLoopGap: Double = 1
    /// Caps the stacked streak opacities so the camera preview stays
    /// visually dominant even when several ribbons overlap.
    static let sweepMasterOpacity: Double = 0.6
    static let sweepFadeIn: Double = 0.5
    static let sweepFadeOut: Double = 0.35
    static let sweepDirectionCrossfade: Double = 0.25
    /// Beat of stillness after a pose change before the next sweep plays.
    static let sweepPoseDelay: Double = 0.36

    /// How long `presentOnce(direction:)` waits before tearing its window down — sized to
    /// the slowest streak in `EnrollmentDirectionSweep.makeSpecs()` plus a small buffer.
    static let introSweepAutoDismissDelay: Double = 1.6
}

extension View {
    /// All four content-edge insets for a step view, sized to whichever silhouette the
    /// panel is currently wearing. Reads style from the environment so every step view
    /// stays a plain `(controller) -> View`.
    func onboardingContentPadding() -> some View {
        modifier(OnboardingContentPadding())
    }

    /// Just the left/right insets — for steps (like `.complete`) that use
    /// their own top/bottom spacing instead of the standard title/content
    /// insets.
    func onboardingContentHorizontalPadding() -> some View {
        modifier(OnboardingContentHorizontalPadding())
    }
}

private struct OnboardingContentHorizontalPadding: ViewModifier {
    @Environment(\.notchPanelStyle) private var style

    func body(content: Content) -> some View {
        content
            .padding(.leading, OnboardingMetrics.contentLeadingInset(for: style))
            .padding(.trailing, OnboardingMetrics.contentTrailingInset(for: style))
    }
}

private struct OnboardingContentPadding: ViewModifier {
    @Environment(\.notchPanelStyle) private var style

    func body(content: Content) -> some View {
        content
            .onboardingContentHorizontalPadding()
            .padding(.top, OnboardingMetrics.titleTopInset(for: style))
            .padding(.bottom, OnboardingMetrics.contentBottomInset(for: style))
    }
}
