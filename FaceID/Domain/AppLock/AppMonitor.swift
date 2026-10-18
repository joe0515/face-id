//
//  AppMonitor.swift
//  Face ID
//
//  Watches app launches and activations system-wide and reports any *locked* app
//  that reaches the front without a live session.
//
//  Event-driven, not polled: three `NSWorkspace` notifications cover everything
//  the feature needs, and a poll would burn CPU for no added coverage.
//
//  Ported from FaceGate's `AppMonitor`; Combine → Observation, and the detection
//  callback is now a plain property the coordinator wires up (see
//  `AppUnlockCoordinator` in Phase 5).
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppMonitor {

    static let shared = AppMonitor()

    private(set) var isMonitoring = false

    /// Invoked when a locked app is launched or brought forward without a valid
    /// session. The parameter is the app the caller must gate.
    ///
    /// A closure rather than an `AsyncStream`: the receiver is a single
    /// long-lived coordinator, and the callback must run synchronously inside the
    /// notification to hide the app before it draws — an await point here would
    /// let the window become visible first.
    @ObservationIgnored var onLockedAppDetected: ((String, NSRunningApplication) -> Void)?

    /// Invoked when an app terminates on its own.
    ///
    /// A challenge has nothing left to resolve once its app is gone, and leaving it
    /// latched would suppress every later detection — see `AppUnlockCoordinator`.
    @ObservationIgnored var onAppTerminated: ((String) -> Void)?

    @ObservationIgnored private var launchObserver: NSObjectProtocol?
    @ObservationIgnored private var activateObserver: NSObjectProtocol?
    @ObservationIgnored private var deactivateObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    /// Recently unlocked apps → timestamp. A short cooldown after unlock stops
    /// "lock immediately" mode from re-locking the app it just released, which
    /// would otherwise loop the overlay forever.
    @ObservationIgnored private var recentlyUnlocked: [String: Date] = [:]

    private init() {}

    // MARK: - Lifecycle

    func startMonitoring() {
        guard !isMonitoring else { return }
        let center = NSWorkspace.shared.notificationCenter

        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleAppEvent(notification) }
        }

        activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleAppEvent(notification) }
        }

        // Deactivation feeds the session manager's "count from last focus" mode.
        deactivateObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                self?.sessions.appDidBlur(bundleID)
            }
        }

        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                self?.onAppTerminated?(bundleID)
            }
        }

        isMonitoring = true
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        let center = NSWorkspace.shared.notificationCenter
        for observer in [launchObserver, activateObserver, deactivateObserver, terminateObserver].compactMap({ $0 }) {
            center.removeObserver(observer)
        }
        launchObserver = nil
        activateObserver = nil
        deactivateObserver = nil
        terminateObserver = nil
        isMonitoring = false
    }

    /// Starts the post-unlock cooldown for an app.
    func recordUnlock(for bundleIdentifier: String) {
        recentlyUnlocked[bundleIdentifier] = Date()
    }

    // MARK: - Detection

    @ObservationIgnored private let store = LockedAppsStore.shared
    @ObservationIgnored private let sessions = AppLockSessionManager.shared

    private func handleAppEvent(_ notification: Notification) {
        guard !Self.isProtectionPaused else { return }

        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }

        guard store.isLocked(bundleID) else { return }

        // A launch notification also fires for background/agent launches, where
        // there is no window to cover. Challenging one of those spent the settle
        // wait, fell back to hiding, and left the challenge latched — which
        // silently disabled every later detection until relaunch. Activation is the
        // event that actually means "this is on screen"; a launch only counts when
        // the app is already frontmost.
        if notification.name == NSWorkspace.didLaunchApplicationNotification {
            guard app.isActive else { return }
        }

        // Feed focus first — it may revoke an over-long away-period session.
        sessions.appDidFocus(bundleID)

        guard !sessions.hasActiveSession(for: bundleID) else { return }

        if let lastUnlock = recentlyUnlocked[bundleID],
           Date().timeIntervalSince(lastUnlock) < FIDConstants.reLockCooldown {
            return
        }

        onLockedAppDetected?(bundleID, app)
    }

    /// True while the user has paused protection from the menu bar. The pause
    /// self-expires: reading it here also cleans up a stale flag.
    nonisolated static var isProtectionPaused: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: FIDConstants.Defaults.protectionTemporarilyDisabled) else { return false }

        if let expiry = defaults.object(forKey: FIDConstants.Defaults.protectionDisableExpiry) as? Date {
            if Date() < expiry { return true }
            defaults.set(false, forKey: FIDConstants.Defaults.protectionTemporarilyDisabled)
            defaults.removeObject(forKey: FIDConstants.Defaults.protectionDisableExpiry)
            return false
        }
        return false
    }

    /// Pauses enforcement for `minutes`, or clears the pause when `minutes <= 0`.
    @MainActor static func pauseProtection(forMinutes minutes: Int) {
        let defaults = UserDefaults.standard
        guard minutes > 0 else {
            defaults.set(false, forKey: FIDConstants.Defaults.protectionTemporarilyDisabled)
            defaults.removeObject(forKey: FIDConstants.Defaults.protectionDisableExpiry)
            return
        }
        defaults.set(true, forKey: FIDConstants.Defaults.protectionTemporarilyDisabled)
        defaults.set(Date().addingTimeInterval(TimeInterval(minutes) * 60),
                     forKey: FIDConstants.Defaults.protectionDisableExpiry)
    }
}
