//
//  NotchOverlayContentTests.swift
//  Face ID Tests
//
//  The app-lock payload has to survive a resolve. `finish(success:)` and
//  `beginScanning()` both rewrite the panel's video, and if they did so by
//  assigning `.scan(...)` the app's icon and name would vanish the instant the
//  success animation started — leaving a generic scan panel as the last thing the
//  user sees. `content(_:withMedia:)` is the rule that prevents it.
//

import Foundation
import Testing
@testable import FaceID

@Suite("Notch overlay content")
@MainActor
struct NotchOverlayContentTests {

    private func payload(media: ScanMedia = .idle) -> AppLockContent {
        AppLockContent(bundleID: "com.example.app", displayName: "Example", icon: nil, media: media)
    }

    // MARK: - Media preservation

    @Test("Resolving an app-lock attempt swaps the video and keeps the app's identity")
    func appLockKeepsIdentityWhenMediaChanges() {
        let resolved = NotchOverlayController.content(.appLock(payload()), withMedia: .success)

        guard case .appLock(let result) = resolved else {
            Issue.record("expected the payload to stay an .appLock, got \(resolved)")
            return
        }
        #expect(result.bundleID == "com.example.app")
        #expect(result.displayName == "Example")
        #expect(result.media == .success)
    }

    @Test("Resetting the video to idle also keeps an app-lock payload")
    func appLockSurvivesIdleReset() {
        // This is `beginScanning()`'s path: a hover-to-retry must not lose the app.
        let started = NotchOverlayController.content(.appLock(payload(media: .failure)), withMedia: .idle)

        guard case .appLock(let result) = started else {
            Issue.record("expected .appLock, got \(started)")
            return
        }
        #expect(result.media == .idle)
        #expect(result.bundleID == "com.example.app")
    }

    @Test("Plain scan content simply takes the new media")
    func scanContentTakesMedia() {
        #expect(NotchOverlayController.content(.scan(.idle), withMedia: .failure) == .scan(.failure))
    }

    // MARK: - Equality drives SwiftUI diffing

    @Test("App-lock payloads compare on their displayed fields and video")
    func appLockEquality() {
        #expect(payload() == payload())
        #expect(payload(media: .idle) != payload(media: .success))
        #expect(
            payload()
                != AppLockContent(bundleID: "com.other.app", displayName: "Example", icon: nil, media: .idle)
        )
        #expect(
            payload()
                != AppLockContent(bundleID: "com.example.app", displayName: "Other", icon: nil, media: .idle)
        )
    }

    @Test("Different content kinds are never equal")
    func kindsAreDistinct() {
        // Guards the `default: return false` arm — a regression there would make the
        // view stop re-rendering when the panel switches mode.
        #expect(NotchOverlayController.Content.appLock(payload()) != .scan(.idle))
        #expect(NotchOverlayController.Content.scan(.idle) != .appLock(payload()))
    }
}
