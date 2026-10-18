//
//  LockedApp.swift
//  Face ID
//
//  One entry in the user's "keep these apps locked" list. Value type, `Codable`
//  so the whole list round-trips through UserDefaults as one blob.
//

import AppKit
import Foundation

/// Represents an application the user has asked Face ID to gate.
nonisolated struct LockedApp: Codable, Identifiable, Hashable {
    /// The app's bundle identifier (e.g. `com.apple.MobileSMS`).
    let bundleIdentifier: String

    /// Human-readable name shown in Settings and the notch panel.
    let displayName: String

    /// The app's icon as PNG data, so the list renders without touching disk.
    let iconData: Data?

    /// Whether this entry is currently enforced. Kept on the model (rather than
    /// deleting the row) so "turn it off for now" doesn't lose the per-app config.
    var isLocked: Bool

    /// Per-app session timeout override, in seconds. `nil` uses the global value.
    var customSessionTimeout: TimeInterval?

    /// Per-app timer mode. `true` counts from when the app last lost focus
    /// instead of from unlock. `nil` uses the global setting.
    var timerFromFocus: Bool?

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        displayName: String,
        iconData: Data? = nil,
        isLocked: Bool = true,
        customSessionTimeout: TimeInterval? = nil,
        timerFromFocus: Bool? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.iconData = iconData
        self.isLocked = isLocked
        self.customSessionTimeout = customSessionTimeout
        self.timerFromFocus = timerFromFocus
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, displayName, iconData, isLocked, customSessionTimeout, timerFromFocus
    }

    /// Hand-written so an older payload missing `isLocked` still decodes as locked,
    /// rather than silently disabling a lock the user asked for.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        displayName = try container.decode(String.self, forKey: .displayName)
        iconData = try container.decodeIfPresent(Data.self, forKey: .iconData)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? true
        customSessionTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .customSessionTimeout)
        timerFromFocus = try container.decodeIfPresent(Bool.self, forKey: .timerFromFocus)
    }

    /// Decoding a PNG per row on every render is wasteful — `NSCache` keyed by
    /// bundle ID keeps it to one decode per app.
    @MainActor private static let iconCache = NSCache<NSString, NSImage>()

    /// The decoded icon, if any was persisted.
    @MainActor var icon: NSImage? {
        guard let iconData else { return nil }
        let key = bundleIdentifier as NSString
        if let cached = Self.iconCache.object(forKey: key) { return cached }
        guard let image = NSImage(data: iconData) else { return nil }
        Self.iconCache.setObject(image, forKey: key)
        return image
    }

    @MainActor static func clearIconCache() {
        iconCache.removeAllObjects()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }

    static func == (lhs: LockedApp, rhs: LockedApp) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}
