//
//  AppIconAppearanceController.swift
//  Face ID
//
//  Swaps the Dock icon between the light and dark artwork when the system
//  appearance changes.
//
//  Why this exists at all: `AppIcon.appiconset` is authored with a
//  `luminosity: dark` variant, but the toolchain's actool does not currently emit
//  appearance variants for a macOS app icon — `assetutil --info` on the built
//  `Assets.car` shows only the ten light renditions, and no `Appearance` field on
//  anything in the catalog. The bundle's `.icns` is static too. So the asset
//  catalog cannot deliver this, and assigning `NSApp.applicationIconImage` is the
//  only mechanism that works — on every macOS version, not just the older ones.
//
//  The `appearances` entries are left in the appiconset anyway: they cost nothing,
//  and if a future actool starts honouring them, macOS 26+ gets the native path and
//  this controller simply resolves to the same artwork.
//
//  Scope worth knowing: this changes the Dock and app-switcher icon live. Finder and
//  the About box read the bundle's icon at launch time — those settle on whichever
//  variant was in force then, until the app is relaunched under the other appearance.
//  Nothing can fix that from inside the process; it is how the icon formats work.
//

import AppKit

@MainActor
final class AppIconAppearanceController {

    static let shared = AppIconAppearanceController()

    private var appearanceObservation: NSKeyValueObservation?

    private init() {}

    /// Idempotent. Call once, after launch.
    func start() {
        apply()
        observe()
    }

    // MARK: - Applying

    private func apply() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let image = NSImage(named: isDark ? "AppIconDark" : "AppIconLight") else { return }
        NSApp.applicationIconImage = image
    }

    // MARK: - Observing

    /// KVO on `NSApplication.effectiveAppearance`, which AppKit documents as the
    /// supported way to watch this: `NSCell.h` says changes to the accent colour can be
    /// observed "by Key-Value Observing the -effectiveAppearance property on
    /// NSApplication", and `NSWindow.h` notes window inheritance does the same. No
    /// reliance on the undocumented `AppleInterfaceThemeChangedNotification`.
    private func observe() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }
}
