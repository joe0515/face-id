//
//  LockedAppsStore.swift
//  Face ID
//
//  Single source of truth for "which apps are locked". Everything else — the
//  monitor, the locker, the schedule manager, Settings — reads the list from here.
//
//  Ported from FaceGate's `LockedAppsManager`; the only substantive change is
//  Combine's `@Published` → Observation, plus the namespaced `FID.` keys.
//

import Foundation
import Observation

@Observable
@MainActor
final class LockedAppsStore {

    static let shared = LockedAppsStore()

    /// Every app the user has configured. Entries with `isLocked == false` are
    /// kept so their per-app session config survives a temporary disable.
    private(set) var lockedApps: [LockedApp] = []

    /// Only the entries currently being enforced.
    var enforcedApps: [LockedApp] { lockedApps.filter(\.isLocked) }

    @ObservationIgnored private let defaults: UserDefaults

    /// Forwards "the user just made an explicit choice" to the schedule manager,
    /// so a manual toggle isn't reverted by the timer. Tests replace this to stay
    /// off the real scheduler (and the real `UserDefaults`).
    @ObservationIgnored var overrideNotifier: ((String, Bool?) -> Void)?

    /// Injectable so tests can run against a scratch `UserDefaults` suite instead
    /// of the developer's real list.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Queries

    func isLocked(_ bundleIdentifier: String) -> Bool {
        lockedApps.contains { $0.bundleIdentifier == bundleIdentifier && $0.isLocked }
    }

    func app(for bundleIdentifier: String) -> LockedApp? {
        lockedApps.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func displayName(for bundleIdentifier: String) -> String? {
        app(for: bundleIdentifier)?.displayName
    }

    // MARK: - Mutation

    /// Adds `app` to the list (or re-enables it if already present).
    func lockApp(_ app: LockedApp) {
        if let index = lockedApps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            lockedApps[index].isLocked = true
        } else {
            var newApp = app
            newApp.isLocked = true
            lockedApps.append(newApp)
        }
        save()
        // The user just made an explicit choice — the scheduler must not undo it.
        notifyOverride(app.bundleIdentifier, wantsLocked: true)
    }

    /// Removes the app from the list entirely.
    func unlockApp(_ bundleIdentifier: String) {
        lockedApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        save()
        notifyOverride(bundleIdentifier, wantsLocked: nil)
        LockedApp.clearIconCache()
    }

    /// Flips the app's enforced state. Turning it off removes the entry, matching
    /// FaceGate's behaviour — the list is "apps to lock", not "apps with config".
    func toggleLock(for bundleIdentifier: String) {
        guard let index = lockedApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        if lockedApps[index].isLocked {
            lockedApps.remove(at: index)
            notifyOverride(bundleIdentifier, wantsLocked: nil)
        } else {
            lockedApps[index].isLocked = true
            notifyOverride(bundleIdentifier, wantsLocked: true)
        }
        save()
    }

    /// Replaces the whole list — used by the enrollment/picker flow.
    func setLockedApps(_ apps: [LockedApp]) {
        lockedApps = apps.filter(\.isLocked)
        save()
    }

    func updateCustomSessionTimeout(for bundleIdentifier: String, timeout: TimeInterval?) {
        guard let index = lockedApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        lockedApps[index].customSessionTimeout = timeout
        save()
    }

    func updateTimerFromFocus(for bundleIdentifier: String, fromFocus: Bool?) {
        guard let index = lockedApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        lockedApps[index].timerFromFocus = fromFocus
        save()
    }

    /// Clears every entry — used when the user removes all locks or resets.
    func removeAll() {
        lockedApps.removeAll()
        save()
        LockedApp.clearIconCache()
    }

    // MARK: - Override forwarding

    /// `wantsLocked == nil` means "clear the override".
    private func notifyOverride(_ bundleIdentifier: String, wantsLocked: Bool?) {
        if let overrideNotifier {
            overrideNotifier(bundleIdentifier, wantsLocked)
        } else if let wantsLocked {
            AppScheduleManager.shared.recordUserOverride(for: bundleIdentifier, wantsLocked: wantsLocked)
        } else {
            AppScheduleManager.shared.clearOverride(for: bundleIdentifier)
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(lockedApps) else { return }
        defaults.set(data, forKey: FIDConstants.Defaults.lockedApps)
    }

    private func load() {
        guard let data = defaults.data(forKey: FIDConstants.Defaults.lockedApps),
              let apps = try? JSONDecoder().decode([LockedApp].self, from: data) else { return }
        lockedApps = apps
    }
}
