//
//  AppLockSessionManagerTests.swift
//  Face ID Tests
//
//  Session timing is the part of the app-lock kernel most likely to regress
//  silently — a wrong sentinel turns "keep unlocked indefinitely" into "locked
//  out", or makes "lock immediately" impossible. Every sentinel gets a test.
//

import Foundation
import Testing
@testable import FaceID

@Suite("AppLockSessionManager")
@MainActor
struct AppLockSessionManagerTests {

    private static let appID = "com.example.app"

    /// Scratch defaults + store + session manager, isolated per test.
    private final class Harness {
        let suiteName: String
        let defaults: UserDefaults
        let store: LockedAppsStore
        let sessions: AppLockSessionManager

        init() {
            suiteName = "FaceIDTests.Session.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            store = LockedAppsStore(defaults: defaults)
            store.overrideNotifier = { _, _ in }
            sessions = AppLockSessionManager(store: store, defaults: defaults)
        }

        /// Locks the fixture app with a specific timeout, in seconds.
        func lockApp(timeout: TimeInterval?, fromFocus: Bool? = nil) {
            store.lockApp(LockedApp(bundleIdentifier: AppLockSessionManagerTests.appID, displayName: "App"))
            if let timeout {
                store.updateCustomSessionTimeout(for: AppLockSessionManagerTests.appID, timeout: timeout)
            }
            if let fromFocus {
                store.updateTimerFromFocus(for: AppLockSessionManagerTests.appID, fromFocus: fromFocus)
            }
        }

        deinit {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("No session exists before an unlock")
    func noSessionByDefault() {
        let harness = Harness()
        #expect(!harness.sessions.hasActiveSession(for: Self.appID))
    }

    @Test("A positive timeout opens a session that is immediately active")
    func positiveTimeoutCreatesSession() {
        let harness = Harness()
        harness.lockApp(timeout: 300)
        harness.sessions.createSession(for: Self.appID)
        #expect(harness.sessions.hasActiveSession(for: Self.appID))
    }

    @Test("A zero timeout means 'lock immediately' — no session at all")
    func zeroTimeoutCreatesNothing() {
        let harness = Harness()
        harness.lockApp(timeout: 0)
        harness.sessions.createSession(for: Self.appID)
        #expect(!harness.sessions.hasActiveSession(for: Self.appID))
    }

    @Test("The indefinite sentinel never expires")
    func indefiniteNeverExpires() {
        let harness = Harness()
        harness.lockApp(timeout: FIDConstants.indefiniteSessionValue)
        harness.sessions.createSession(for: Self.appID)
        #expect(harness.sessions.hasActiveSession(for: Self.appID))
        #expect(harness.sessions.activeSessions[Self.appID] == .distantFuture)
    }

    @Test("A session expires once its timeout elapses")
    func sessionExpires() async throws {
        let harness = Harness()
        harness.lockApp(timeout: 0.05)
        harness.sessions.createSession(for: Self.appID)
        #expect(harness.sessions.hasActiveSession(for: Self.appID))

        try await Task.sleep(for: .milliseconds(150))
        #expect(!harness.sessions.hasActiveSession(for: Self.appID))
    }

    @Test("revokeAllSessions locks everything")
    func revokeAll() {
        let harness = Harness()
        harness.lockApp(timeout: 300)
        harness.sessions.createSession(for: Self.appID)
        harness.sessions.revokeAllSessions()
        #expect(harness.sessions.activeSessions.isEmpty)
    }

    @Test("Setting a zero global timeout revokes live sessions")
    func zeroGlobalTimeoutRevokes() {
        let harness = Harness()
        harness.lockApp(timeout: nil)
        harness.sessions.createSession(for: Self.appID)
        #expect(harness.sessions.hasActiveSession(for: Self.appID))

        harness.sessions.setSessionTimeout(0)
        #expect(!harness.sessions.hasActiveSession(for: Self.appID))
    }

    @Test("Switching to the indefinite timeout extends live sessions forever")
    func switchingToIndefiniteExtendsLiveSessions() {
        let harness = Harness()
        harness.lockApp(timeout: nil)
        harness.sessions.createSession(for: Self.appID)

        harness.sessions.setSessionTimeout(FIDConstants.indefiniteSessionValue)
        #expect(harness.sessions.activeSessions[Self.appID] == .distantFuture)
    }

    @Test("Focus mode drops a session that was away longer than its timeout")
    func focusModeRevokesAfterLongAway() async throws {
        let harness = Harness()
        harness.lockApp(timeout: 0.05, fromFocus: true)
        harness.sessions.createSession(for: Self.appID)

        harness.sessions.appDidBlur(Self.appID)
        try await Task.sleep(for: .milliseconds(150))
        harness.sessions.appDidFocus(Self.appID)

        #expect(!harness.sessions.hasActiveSession(for: Self.appID))
    }

    @Test("Focus mode keeps a session that came back in time")
    func focusModeKeepsQuickReturn() {
        let harness = Harness()
        harness.lockApp(timeout: 300, fromFocus: true)
        harness.sessions.createSession(for: Self.appID)

        harness.sessions.appDidBlur(Self.appID)
        harness.sessions.appDidFocus(Self.appID)

        #expect(harness.sessions.hasActiveSession(for: Self.appID))
    }

    /// macOS can post an activation for an app that is already frontmost, and a missed
    /// `didDeactivate` looks the same. Extending on those (no blur record) pushed the
    /// expiry forward forever, so the app never re-locked no matter how much time passed.
    @Test("An activation without a blur record does not extend an expired session")
    func activationWithoutBlurDoesNotExtend() async throws {
        let harness = Harness()
        harness.lockApp(timeout: 0.05, fromFocus: true)
        harness.sessions.createSession(for: Self.appID)

        try await Task.sleep(for: .milliseconds(150))
        harness.sessions.appDidFocus(Self.appID)

        #expect(!harness.sessions.hasActiveSession(for: Self.appID))
    }

    /// The same activation, while the window is still valid, must leave it exactly as it
    /// was — no extension, because the app never left.
    @Test("An activation without a blur record leaves a live session's expiry alone")
    func activationWithoutBlurDoesNotExtendLiveSession() {
        let harness = Harness()
        harness.lockApp(timeout: 300, fromFocus: true)
        harness.sessions.createSession(for: Self.appID)

        let before = harness.sessions.activeSessions[Self.appID]
        harness.sessions.appDidFocus(Self.appID)

        #expect(harness.sessions.hasActiveSession(for: Self.appID))
        #expect(harness.sessions.activeSessions[Self.appID] == before)
    }

    @Test("Changing the timeout re-bases live sessions and forgets old blur stamps")
    func changingTimeoutRebasesAndClearsBlur() async throws {
        let harness = Harness()
        harness.lockApp(timeout: nil, fromFocus: true)
        harness.sessions.createSession(for: Self.appID)

        harness.sessions.appDidBlur(Self.appID)
        harness.sessions.setSessionTimeout(300)

        // The stale away-period must not be able to revoke (or extend) the re-based window.
        harness.sessions.appDidFocus(Self.appID)
        #expect(harness.sessions.hasActiveSession(for: Self.appID))
    }
}
