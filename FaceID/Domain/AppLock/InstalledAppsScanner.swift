//
//  InstalledAppsScanner.swift
//  Face ID
//
//  Enumerates the apps installed on this Mac so the locked-apps picker has
//  something to offer. Read-only: nothing here locks or launches anything.
//
//  Ported from FaceGate's `InstalledAppsScanner`. Icons are downscaled to a
//  single 64×64 thumbnail — holding every app's full .icns would cost several
//  MB each once the list is a few hundred entries long.
//

import AppKit
import Foundation

@MainActor
final class InstalledAppsScanner {

    /// An app found on disk, ready to be shown in the picker.
    struct DiscoveredApp: Identifiable, Hashable {
        let bundleIdentifier: String
        let displayName: String
        let icon: NSImage
        let path: URL

        var id: String { bundleIdentifier }

        func hash(into hasher: inout Hasher) { hasher.combine(bundleIdentifier) }

        static func == (lhs: DiscoveredApp, rhs: DiscoveredApp) -> Bool {
            lhs.bundleIdentifier == rhs.bundleIdentifier
        }
    }

    static let shared = InstalledAppsScanner()

    /// Apps that must never appear in the picker: Face ID itself (self-locking
    /// would deadlock the unlock path) and Finder (which can't meaningfully be
    /// locked — it's always running and reopening is trivial).
    private static let alwaysExcluded: Set<String> = [
        FIDConstants.bundleIdentifier,
        "com.apple.finder",
    ]

    private init() {}

    /// Scans the standard application directories, de-duplicated by bundle ID and
    /// sorted by display name.
    func scanInstalledApps() -> [DiscoveredApp] {
        var found: [String: DiscoveredApp] = [:]

        let searchPaths = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]

        for path in searchPaths {
            scanDirectory(path, into: &found, depth: 0, maxDepth: 2)
        }

        return found.values
            .filter { !Self.alwaysExcluded.contains($0.bundleIdentifier) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Converts a discovered app into the persistable model.
    func toLockedApp(_ discovered: DiscoveredApp, isLocked: Bool = true) -> LockedApp {
        LockedApp(
            bundleIdentifier: discovered.bundleIdentifier,
            displayName: discovered.displayName,
            iconData: Self.pngData(from: discovered.icon),
            isLocked: isLocked
        )
    }

    // MARK: - Private

    private func scanDirectory(
        _ directory: URL,
        into found: inout [String: DiscoveredApp],
        depth: Int,
        maxDepth: Int
    ) {
        guard depth <= maxDepth else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents {
            if url.pathExtension == "app" {
                if let app = makeDiscoveredApp(from: url) {
                    found[app.bundleIdentifier] = app
                }
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // Recurse so /Applications/Utilities and vendor subfolders are covered.
                scanDirectory(url, into: &found, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    private func makeDiscoveredApp(from appURL: URL) -> DiscoveredApp? {
        guard let bundle = Bundle(url: appURL),
              let bundleIdentifier = bundle.bundleIdentifier else { return nil }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent

        return DiscoveredApp(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            icon: Self.thumbnail(forFileAt: appURL.path),
            path: appURL
        )
    }

    private static let thumbnailSide: CGFloat = 64

    /// `NSImage(size:flipped:drawingHandler:)` rather than the older
    /// `lockFocus`/`unlockFocus` pair — the latter is not safe to call from
    /// arbitrary contexts and is deprecated on recent SDKs.
    private static func thumbnail(forFileAt path: String) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: path)
        let side = thumbnailSide
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
