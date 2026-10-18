//
//  SettingsMetrics.swift
//  Face ID
//
//  Design tokens for the Settings window — one file to tune sizing/color
//  in rather than scattered literals.
//

import SwiftUI

enum SettingsMetrics {
    static let windowSize = CGSize(width: 500, height: 620)
    /// No `outerCornerRadius` token — the window's outer corner is AppKit's
    /// own native mask (see WindowConfiguringView), not a hardcoded clip.
    ///
    /// Strip across the top of the window: AppKit draws the real traffic
    /// lights in it on the leading side, the session lock button sits on
    /// the trailing side.
    ///
    static let headerHeight: CGFloat = 52
    static let headerButtonHeight: CGFloat = 30
    static let headerButtonFont = Font.system(size: 13, weight: .medium)

    /// Taller than `headerHeight` so the blur has room to fade all the way
    /// to nothing before the first row, rather than getting cut off mid-fade.
    static let headerBlurHeight: CGFloat = headerHeight + 28

    /// Tint over `VisualEffectView`'s `.sidebar` material, which spans the
    /// whole window. Clear in both appearances — the material alone is the
    /// look — but kept as the one place to tune it.
    static let windowTintColor = adaptiveColor(
        dark: NSColor(red: 0x37 / 255, green: 0x37 / 255, blue: 0x37 / 255, alpha: 0),
        light: NSColor(red: 0xFF / 255, green: 0xFF / 255, blue: 0xFF / 255, alpha: 0)
    )

    // MARK: - Tab bar
    //
    // Floating pill pinned to the bottom edge, above the scrolling page. Same
    // `.sidebar` material as the window, blended within-window so it blurs
    // the rows passing beneath it, plus `tabBarTint` to lift it a touch.

    static let tabBarHeight: CGFloat = 54
    static let tabBarBottomInset: CGFloat = 14
    /// Gap between the bar's edge and the first/last item's own padding.
    static let tabBarHorizontalPadding: CGFloat = 6
    static let tabBarTint = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.15),
        light: NSColor(white: 1, alpha: 0.5)
    )
    static let tabBarBorder = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.16),
        light: NSColor(white: 0, alpha: 0.08)
    )
    static let tabItemHeight: CGFloat = 42
    static let tabItemHorizontalPadding: CGFloat = 11
    static let selectedTabItemHorizontalPadding: CGFloat = 14
    static let tabGlyphSize: CGFloat = 15
    static let tabTitleFont = Font.system(size: 13, weight: .medium)
    static let selectedPillColor = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.1),
        light: NSColor(white: 1, alpha: 0.7)
    )
    /// Same treatment as `tabBarBorder`, one step subtler — the inner pill
    /// reads as sitting on the outer one rather than a separate outline.
    static let selectedPillBorder = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.12),
        light: NSColor(white: 0, alpha: 0.06)
    )
    static let tabSelectionAnimation = Animation.spring(response: 0.35, dampingFraction: 0.82)
    /// How far a tab's label slides toward its icon as it collapses away
    /// (or unfurls back out), in points.
    static let tabLabelRevealOffset: CGFloat = 10
    /// Max blur radius at the fully-collapsed end of the label reveal.
    static let tabLabelRevealBlur: CGFloat = 4

    /// Extra scroll room below a page's last row so it can clear the tab bar.
    static let pageBottomInset: CGFloat = tabBarHeight + tabBarBottomInset + 16

    /// Light-mode values match the exact resolved alpha AppKit's own
    /// `NSColor.labelColor`/`.secondaryLabelColor` use (`black @ 0.85`/`0.50`),
    /// so text reads with the same contrast as every other native app.
    static let textPrimary = adaptiveColor(
        dark: NSColor(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255, alpha: 1),
        light: NSColor(white: 0, alpha: 0.85)
    )
    static let textSecondary = adaptiveColor(
        dark: NSColor(red: 0xBF / 255, green: 0xBF / 255, blue: 0xBF / 255, alpha: 1),
        light: NSColor(white: 0, alpha: 0.50)
    )
    static let textTertiary = adaptiveColor(
        dark: NSColor(red: 0x99 / 255, green: 0x99 / 255, blue: 0x99 / 255, alpha: 1),
        light: NSColor(white: 0, alpha: 0.4)
    )

    static let rowHeight: CGFloat = 44
    static let rowRadius: CGFloat = 16
    /// Light mode goes slightly darker than the page instead of lighter,
    /// since a white tint is invisible over the light material.
    static let rowColor = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.08),
        light: NSColor(white: 1, alpha: 0.75)
    )
    static let rowBorder = adaptiveColor(
        dark: NSColor(white: 0.8, alpha: 0.12),
        light: NSColor(white: 0, alpha: 0.15)
    )
    static let rowBorderWidth: CGFloat = 1
    static let rowFont = Font.system(size: 13, weight: .regular)
    static let rowSpacing: CGFloat = 12
    static let rowHorizontalInset: CGFloat = 14
    /// Shared cap on a row's subtitle width — keeps a longer explanatory
    /// line from stretching toward the trailing control/tiles, and keeps
    /// every subtitle (plain rows and `SettingsLabeledOptionRow` alike)
    /// wrapping at the same width.
    static let rowSubtitleMaxWidth: CGFloat = 260
    /// Two-line slider rows size to their content instead of `rowHeight`;
    /// this keeps their total height visually in step with single-line rows
    /// in the same group.
    static let sliderRowVerticalPadding: CGFloat = 12

    /// Neutral (non-accent, non-destructive) button fill — the resting state
    /// of `HoldToConfirmButton`, which only turns red as it fills.
    static let neutralButtonFill = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.14),
        light: NSColor(white: 0, alpha: 0.10)
    )
    static let destructiveFill = Color(red: 0xE0 / 255, green: 0x3B / 255, blue: 0x2F / 255)

    /// Centered empty/locked-state block (icon, caption, action button).
    static let emptyStateIconSize: CGFloat = 34
    static let emptyStateSpacing: CGFloat = 12
    static let emptyStateMinHeight: CGFloat = 340
    /// Crossfade between the locked and unlocked states of the Password page.
    static let stateTransitionAnimation = Animation.easeInOut(duration: 0.28)

    /// Taller card used by multi-option pickers (e.g. Unlock Animation).
    static let optionCardVerticalPadding: CGFloat = 14
    static let optionPreviewHeight: CGFloat = 58
    /// Fixed-size tiles for pickers that share their row with a leading
    /// title (`SettingsLabeledOptionRow`) instead of spanning the card.
    static let triggerOptionPreviewSize = CGSize(width: 70, height: 44)
    static let unlockAnimationOptionPreviewSize = CGSize(width: 112, height: 76)
    static let optionPreviewCornerRadius: CGFloat = 13
    static let optionPreviewFill = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.05),
        light: NSColor(white: 0, alpha: 0.05)
    )
    /// Fill for trailing menu/picker pills inside settings rows — stronger
    /// than `optionPreviewFill` so it still reads against `rowColor`.
    static let pickerPillFill = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.05),
        light: NSColor(white: 0, alpha: 0.10)
    )
    /// Accent wash over `optionPreviewFill` when the tile is selected.
    static let optionPreviewSelectedTintOpacity: CGFloat = 0.12
    static let optionLabelFont = Font.system(size: 12, weight: .medium)
    /// Blue selection ring sits this far outside the preview tile's edge.
    static let optionSelectionOutset: CGFloat = 2.5
    static let optionSelectionStrokeWidth: CGFloat = 3.5
    static let optionItemSpacing: CGFloat = 15
    /// Zero-offset soft edge so the preview tiles lift evenly on all sides.
    static let optionPreviewShadowColor = Color.black.opacity(0.15)
    static let optionPreviewShadowRadius: CGFloat = 4
    /// Dark-mode-only ring drawn just outside the rowBorder stroke.
    /// Clear in light mode so the overlay can stay unconditional.
    static let optionPreviewOuterStroke = adaptiveColor(
        dark: NSColor(white: 0.1, alpha: 0.35),
        light: NSColor(white: 0, alpha: 0)
    )
    static let optionPreviewOuterStrokeWidth: CGFloat = 1
    static let optionPreviewBorderWidth: CGFloat = 1
    static let sectionTitleFont = Font.system(size: 13, weight: .medium)
    static let sectionTitleHorizontalInset: CGFloat = 10
    static let sectionTitleVerticalPadding: CGFloat = 8

    /// Page content's inset from the window's side edges; the header's
    /// trailing button lines up with it.
    static let contentHorizontalPadding: CGFloat = 16

    // MARK: - Capture-quality tick strip (Your Face)
    //
    // One tick per stored sample, colored by `FaceSample.QualityTier`.
    // Fixed literals rather than `adaptiveColor` — semantic red/amber/green
    // that reads correctly against both dark and light content panels.

    static let qualityPoorColor = Color(red: 0xFF / 255, green: 0x54 / 255, blue: 0x54 / 255)
    static let qualityFairColor = Color(red: 0xFF / 255, green: 0xBE / 255, blue: 0x54 / 255)
    static let qualityGoodColor = Color(red: 0x85 / 255, green: 0xFF / 255, blue: 0x77 / 255)
    /// Samples with no recorded score — enrollments predating per-sample
    /// quality. Deliberately neutral: unrated is not the same as poor.
    static let qualityUnratedColor = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.22),
        light: NSColor(white: 0, alpha: 0.20)
    )

    static let qualityTickWidth: CGFloat = 3.5
    static let qualityTickSpacing: CGFloat = 5.5
    static let qualityTickHeight: CGFloat = 26
    /// Caps the strip so an identity with an unusual number of samples
    /// compresses its ticks rather than running off the card.
    static let qualityStripMaxWidth: CGFloat = 250

    static let buttonBackgroundColor = Color(red: 0x3F / 255, green: 0x3F / 255, blue: 0x3F / 255)

    /// Resolves live against the current system appearance rather than a
    /// value fixed at evaluation time.
    private static func adaptiveColor(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
