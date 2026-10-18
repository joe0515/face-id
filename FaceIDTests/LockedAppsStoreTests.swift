//
//  LockedAppsStoreTests.swift
//  Face ID Tests
//
//  CRUD and persistence for the locked-apps list, run against a scratch
//  `UserDefaults` suite so tests never touch the developer's real list.
//

import Foundation
import Testing
@testable import FaceID

@Suite("LockedApp model")
struct LockedAppTests {

    @Test("Codable round-trips every field")
    func codableRoundTrip() throws {
        let app = LockedApp(
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            iconData: Data([0x01, 0x02]),
            isLocked: true,
            customSessionTimeout: 120,
            timerFromFocus: true
        )
        let data = try JSONEncoder().encode(app)
        let decoded = try JSONDecoder().decode(LockedApp.self, from: data)

        #expect(decoded.bundleIdentifier == app.bundleIdentifier)
        #expect(decoded.displayName == app.displayName)
        #expect(decoded.iconData == app.iconData)
        #expect(decoded.isLocked)
        #expect(decoded.customSessionTimeout == 120)
        #expect(decoded.timerFromFocus == true)
    }

    @Test("A payload without isLocked decodes as locked, not unlocked")
    func missingIsLockedDefaultsToLocked() throws {
        // Fail-safe: a lock the user asked for must never be silently dropped by
        // an older payload that predates the field.
        let json = #"{"bundleIdentifier":"com.example.app","displayName":"Example"}"#
        let decoded = try JSONDecoder().decode(LockedApp.self, from: Data(json.utf8))
        #expect(decoded.isLocked)
    }
}

@Suite("LockedAppsStore")
@MainActor
struct LockedAppsStoreTests {

    /// A store backed by a throwaway `UserDefaults` suite, with the schedule
    /// manager detached so tests never write to real user state.
    private final class Harness {
        let suiteName: String
        let defaults: UserDefaults
        let store: LockedAppsStore

        init() {
            suiteName = "FaceIDTests.LockedAppsStore.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            store = LockedAppsStore(defaults: defaults)
            store.overrideNotifier = { _, _ in }
        }

        deinit {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }

    private func app(_ id: String) -> LockedApp {
        LockedApp(bundleIdentifier: id, displayName: id)
    }

    @Test("lockApp adds and marks the app locked")
    func lockAppAdds() {
        let harness = Harness()
        harness.store.lockApp(app("com.example.a"))

        #expect(harness.store.lockedApps.count == 1)
        #expect(harness.store.isLocked("com.example.a"))
        #expect(harness.store.displayName(for: "com.example.a") == "com.example.a")
    }

    @Test("lockApp on an existing entry re-enables it instead of duplicating")
    func lockAppReenables() {
        let harness = Harness()
        harness.store.lockApp(app("com.example.a"))
        harness.store.toggleLock(for: "com.example.a")   // removes it
        harness.store.lockApp(app("com.example.a"))

        #expect(harness.store.lockedApps.count == 1)
        #expect(harness.store.isLocked("com.example.a"))
    }

    @Test("toggleLock removes an entry that is currently locked")
    func toggleRemoves() {
        let harness = Harness()
        harness.store.lockApp(app("com.example.a"))
        harness.store.toggleLock(for: "com.example.a")

        #expect(harness.store.lockedApps.isEmpty)
        #expect(!harness.store.isLocked("com.example.a"))
    }

    @Test("toggleLock on an unknown app is a no-op")
    func toggleUnknownIsNoOp() {
        let harness = Harness()
        harness.store.toggleLock(for: "com.example.missing")
        #expect(harness.store.lockedApps.isEmpty)
    }

    @Test("unlockApp removes the entry")
    func unlockRemoves() {
        let harness = Harness()
        harness.store.lockApp(app("com.example.a"))
        harness.store.unlockApp("com.example.a")
        #expect(harness.store.lockedApps.isEmpty)
    }

    @Test("Per-app session config is written back")
    func perAppConfig() {
        let harness = Harness()
        harness.store.lockApp(app("com.example.a"))
        harness.store.updateCustomSessionTimeout(for: "com.example.a", timeout: 90)
        harness.store.updateTimerFromFocus(for: "com.example.a", fromFocus: true)

        let stored = harness.store.app(for: "com.example.a")
        #expect(stored?.customSessionTimeout == 90)
        #expect(stored?.timerFromFocus == true)
    }

    @Test("The list survives a reload from the same defaults")
    func persistsAcrossReload() {
        let harness = Harness()
        harness.store.lockApp(app("com.example.a"))

        let reloaded = LockedAppsStore(defaults: harness.defaults)
        #expect(reloaded.lockedApps.count == 1)
        #expect(reloaded.isLocked("com.example.a"))
    }
}
