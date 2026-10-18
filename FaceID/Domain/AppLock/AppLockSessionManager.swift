//
//  AppLockSessionManager.swift
//  Face ID
//
//  Per-app unlock sessions. After a successful unlock the app stays unlocked for
//  a configurable window, then re-locks the next time it comes to the front.
//
//  Named `AppLockSessionManager` (not `SessionManager`) to keep it clearly
//  distinct from `SessionAutoLocker`, which re-locks the *whole-machine*
//  credential session. Different scope, different lifetime, different lifetime
//  source — the two must never be collapsed into one type.
//
//  Ported from FaceGate's `SessionManager`; Combine → Observation, `FID.` keys.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppLockSessionManager {

    static let shared = AppLockSessionManager()

    /// Active unlock sessions keyed by bundle identifier; the value is the expiry
    /// date. `.distantFuture` marks "keep unlocked indefinitely".
    private(set) var activeSessions: [String: Date] = [:]

    /// Per-app duration captured when the session was created — needed by
    /// "count from last focus" to decide whether an away-period was too long.
    @ObservationIgnored private var sessionDurations: [String: TimeInterval] = [:]

    /// When each unlocked app last lost focus, for "count from last focus" mode.
    @ObservationIgnored private var focusLostAt: [String: Date] = [:]

    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private let defaults: UserDefaults

    /// Per-app timeouts and timer modes live on the locked-apps entries, so the
    /// session manager must read from the same store the rest of the feature uses.
    @ObservationIgnored private let store: LockedAppsStore

    /// Singleton for app code. A separate designated init exists for tests, which
    /// drive timing against a scratch store and `UserDefaults` suite.
    private convenience init() {
        self.init(store: .shared, defaults: .standard)
    }

    init(store: LockedAppsStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
        startCleanupTimer()
    }

    // MARK: - Configuration

    /// Global session timeout. `0` means "lock immediately" (no session is
    /// created); `FIDConstants.indefiniteSessionValue` means "never expire".
    var sessionTimeout: TimeInterval {
        get {
            guard defaults.object(forKey: FIDConstants.Defaults.appLockSessionTimeout) != nil else {
                return FIDConstants.defaultAppSessionTimeout
            }
            return defaults.double(forKey: FIDConstants.Defaults.appLockSessionTimeout)
        }
        set { setSessionTimeout(newValue) }
    }

    /// Global "count from last focus" mode. A per-app override wins over this.
    var sessionTimerFromFocus: Bool {
        get { defaults.bool(forKey: FIDConstants.Defaults.appLockSessionTimerFromFocus) }
        set { defaults.set(newValue, forKey: FIDConstants.Defaults.appLockSessionTimerFromFocus) }
    }

    /// Per-app override if set, else the global mode.
    private func timerFromFocus(for bundleIdentifier: String) -> Bool {
        store.app(for: bundleIdentifier)?.timerFromFocus ?? sessionTimerFromFocus
    }

    /// Effective duration for an app: its override if set, else the global value.
    private func duration(for bundleIdentifier: String) -> TimeInterval {
        store.app(for: bundleIdentifier)?.customSessionTimeout ?? sessionTimeout
    }

    // MARK: - Session lifecycle

    /// Records a successful unlock and starts (or skips) the session window.
    func createSession(for bundleIdentifier: String) {
        let duration = duration(for: bundleIdentifier)
        focusLostAt.removeValue(forKey: bundleIdentifier)

        if duration == FIDConstants.indefiniteSessionValue {
            activeSessions[bundleIdentifier] = .distantFuture
            sessionDurations[bundleIdentifier] = duration
            return
        }

        // "Lock immediately": no session at all, so the next activation re-prompts.
        guard duration > 0 else { return }

        activeSessions[bundleIdentifier] = Date().addingTimeInterval(duration)
        sessionDurations[bundleIdentifier] = duration
    }

    func hasActiveSession(for bundleIdentifier: String) -> Bool {
        guard let expiry = activeSessions[bundleIdentifier] else { return false }
        if Date() < expiry { return true }
        revokeSession(for: bundleIdentifier)
        return false
    }

    func revokeSession(for bundleIdentifier: String) {
        activeSessions.removeValue(forKey: bundleIdentifier)
        sessionDurations.removeValue(forKey: bundleIdentifier)
        focusLostAt.removeValue(forKey: bundleIdentifier)
    }

    func revokeAllSessions() {
        activeSessions.removeAll()
        sessionDurations.removeAll()
        focusLostAt.removeAll()
    }

    // MARK: - Focus tracking ("count from last focus")

    /// Called when an app comes to the front. If it was away longer than its
    /// window, the session is dropped; otherwise the expiry is pushed out so
    /// wall-clock time spent in the app doesn't count against it.
    ///
    /// In focus mode the **away period is the only criterion** — time spent using the
    /// app must never lock it. What was wrong was the other branch: with no blur
    /// record, the old code extended the expiry on every activation anyway. macOS also
    /// posts activation for an app that is already frontmost, and a missed
    /// `didDeactivate` produces the same shape — so those activations pushed the window
    /// forward forever and the app never re-locked, no matter how much time passed.
    func appDidFocus(_ bundleIdentifier: String) {
        guard timerFromFocus(for: bundleIdentifier),
              let duration = sessionDurations[bundleIdentifier],
              duration > 0,
              duration != FIDConstants.indefiniteSessionValue else { return }

        guard let lostAt = focusLostAt.removeValue(forKey: bundleIdentifier) else {
            // No evidence it ever left: don't extend. Only drop an already-expired one.
            if let expiry = activeSessions[bundleIdentifier], Date() >= expiry {
                revokeSession(for: bundleIdentifier)
            }
            return
        }

        if Date().timeIntervalSince(lostAt) > duration {
            revokeSession(for: bundleIdentifier)
            return
        }
        activeSessions[bundleIdentifier] = Date().addingTimeInterval(duration)
    }

    /// Called when an app leaves the front, to stamp the away-period start.
    func appDidBlur(_ bundleIdentifier: String) {
        guard timerFromFocus(for: bundleIdentifier),
              activeSessions[bundleIdentifier] != nil else { return }
        focusLostAt[bundleIdentifier] = Date()
    }

    /// Re-applies the current timer mode to a live session — used when the mode
    /// changes mid-session so the new rule takes effect immediately.
    func refreshSessionForTimerMode(_ bundleIdentifier: String) {
        guard timerFromFocus(for: bundleIdentifier),
              activeSessions[bundleIdentifier] != nil,
              let duration = sessionDurations[bundleIdentifier],
              duration > 0,
              duration != FIDConstants.indefiniteSessionValue else { return }
        activeSessions[bundleIdentifier] = Date().addingTimeInterval(duration)
    }

    // MARK: - Configuration changes

    /// Applies a new global timeout to existing sessions immediately.
    func setSessionTimeout(_ timeout: TimeInterval) {
        defaults.set(timeout, forKey: FIDConstants.Defaults.appLockSessionTimeout)

        if timeout == FIDConstants.indefiniteSessionValue {
            for bundleID in activeSessions.keys {
                activeSessions[bundleID] = .distantFuture
                sessionDurations[bundleID] = timeout
                focusLostAt.removeValue(forKey: bundleID)
            }
        } else if timeout <= 0 {
            revokeAllSessions()
        } else {
            let expiry = Date().addingTimeInterval(timeout)
            for bundleID in activeSessions.keys {
                activeSessions[bundleID] = expiry
                sessionDurations[bundleID] = timeout
                // The new window starts *now*; a blur stamped under the old setting
                // would otherwise be measured against the new duration on the next
                // activation and could revoke (or extend) for the wrong reason.
                focusLostAt.removeValue(forKey: bundleID)
            }
        }
    }

    // MARK: - Expiry sweep

    /// Expiry is also checked lazily in `hasActiveSession`, but a sleeping app
    /// that never re-activates would otherwise keep a stale entry forever.
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(
            withTimeInterval: FIDConstants.scheduleEvaluationInterval,
            repeats: true
        ) { [weak self] _ in
            // The timer fires on the main run loop, so asserting main-actor
            // isolation is both correct and cheaper than hopping through a Task —
            // and it avoids capturing the weakly-bound `self` into a concurrent
            // closure, which Swift 6 rejects outright.
            MainActor.assumeIsolated { self?.cleanupExpiredSessions() }
        }
    }

    private func cleanupExpiredSessions() {
        let now = Date()
        let expired = activeSessions.filter { $0.value <= now }.map(\.key)
        for bundleID in expired { revokeSession(for: bundleID) }
    }
}
