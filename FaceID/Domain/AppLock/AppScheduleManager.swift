//
//  AppScheduleManager.swift
//  Face ID
//
//  Time-of-day windows that lock or unlock every managed app automatically.
//  Evaluated on a repeating timer, with user overrides honoured so a manual
//  toggle is never silently reverted by the scheduler.
//
//  Ported from FaceGate's `AppScheduleManager`. Two deliberate changes:
//   • Combine (`@Published` + merged publishers + debounce) → Observation with a
//     single `didSet` per window. Recomputing overlap is a 1440-iteration loop —
//     microseconds — so the 50ms debounce was buying nothing but complexity.
//   • The five loose scalars per window became one `ScheduleWindow` value type,
//     so a window can never be observed half-updated.
//

import Foundation
import Observation

/// A single enable-flag + start/end time-of-day window. Cross-midnight windows
/// (start > end) are supported.
nonisolated struct ScheduleWindow: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int

    /// Minutes since midnight for the start, for arithmetic.
    var startMinutes: Int { startHour * 60 + startMinute }
    var endMinutes: Int { endHour * 60 + endMinute }

    /// An empty window (`start == end`) is treated as "never".
    var isEmpty: Bool { startMinutes == endMinutes }

    func contains(hour: Int, minute: Int) -> Bool {
        // Checked first: with `start == end` the cross-midnight branch below would
        // report "now >= start" for that one minute and match a window the user
        // never asked to be active. Caught by ScheduleWindowTests.
        guard !isEmpty else { return false }

        let now = hour * 60 + minute
        if startMinutes < endMinutes {
            return now >= startMinutes && now < endMinutes
        }
        // Crosses midnight: 22:00 → 07:00 means >= 22:00 OR < 07:00.
        return now >= startMinutes || now < endMinutes
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        return contains(hour: hour, minute: minute)
    }
}

@Observable
@MainActor
final class AppScheduleManager {

    static let shared = AppScheduleManager()

    /// Window during which every managed app is forced locked.
    var lockWindow: ScheduleWindow {
        didSet { persistWindows(); recomputeOverlap() }
    }

    /// Window during which every managed app is force-unlocked. Ignored while
    /// `lockWindow` is active — lock wins, security first.
    var unlockWindow: ScheduleWindow {
        didSet { persistWindows(); recomputeOverlap() }
    }

    /// True when the two windows overlap at any point — surfaced in Settings as a
    /// warning, since lock silently takes precedence inside the overlap.
    private(set) var windowsOverlap = false

    /// `bundleID → user's intent` (true = wants locked). Populated by explicit
    /// user toggles and cleared whenever either window boundary is crossed, so a
    /// manual choice only survives while the user is still inside that window.
    @ObservationIgnored private var userOverrides: [String: Bool] = [:]

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wasInLockWindow = false
    @ObservationIgnored private var wasInUnlockWindow = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        lockWindow = Self.loadWindow(
            key: FIDConstants.Defaults.lockSchedule,
            fallback: ScheduleWindow(
                isEnabled: false,
                startHour: FIDConstants.defaultLockScheduleStartHour, startMinute: 0,
                endHour: FIDConstants.defaultLockScheduleEndHour, endMinute: 0
            )
        )
        unlockWindow = Self.loadWindow(
            key: FIDConstants.Defaults.unlockSchedule,
            fallback: ScheduleWindow(
                isEnabled: false,
                startHour: FIDConstants.defaultUnlockScheduleStartHour, startMinute: 0,
                endHour: FIDConstants.defaultUnlockScheduleEndHour, endMinute: 0
            )
        )

        if let data = defaults.data(forKey: FIDConstants.Defaults.scheduleUserOverrides),
           let stored = try? JSONDecoder().decode([String: Bool].self, from: data) {
            userOverrides = stored
        }

        windowsOverlap = computeOverlap()
        startTimer()
    }

    // MARK: - User overrides

    /// Remembers an explicit user choice so the scheduler won't revert it.
    func recordUserOverride(for bundleID: String, wantsLocked: Bool) {
        userOverrides[bundleID] = wantsLocked
        persistOverrides()
    }

    /// Forgets a user's override — called when the app leaves the locked list.
    func clearOverride(for bundleID: String) {
        userOverrides.removeValue(forKey: bundleID)
        persistOverrides()
    }

    func isOverridden(_ bundleID: String) -> Bool {
        userOverrides.keys.contains(bundleID)
    }

    /// Forces an immediate re-evaluation — used after the user edits a window.
    func refresh() {
        evaluateSchedules()
    }

    // MARK: - Evaluation

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: FIDConstants.scheduleEvaluationInterval, repeats: true) { [weak self] _ in
            // Runs on the main run loop — see `AppLockSessionManager.startCleanupTimer`
            // for why this asserts rather than spawning a Task.
            MainActor.assumeIsolated { self?.evaluateSchedules() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        evaluateSchedules()
    }

    private func evaluateSchedules() {
        let now = Date()
        windowsOverlap = computeOverlap()

        let inLockWindow = lockWindow.isEnabled && lockWindow.contains(now)
        let inUnlockWindow = unlockWindow.isEnabled && unlockWindow.contains(now)

        if inLockWindow {
            applyLock()
        }
        // Lock wins inside an overlap — security first.
        if inUnlockWindow && !inLockWindow {
            applyUnlock()
        }

        // Leaving either window invalidates manual overrides: they were a choice
        // about *this* window, not a permanent preference.
        if wasInLockWindow && !inLockWindow { userOverrides.removeAll(); persistOverrides() }
        if wasInUnlockWindow && !inUnlockWindow { userOverrides.removeAll(); persistOverrides() }

        wasInLockWindow = inLockWindow
        wasInUnlockWindow = inUnlockWindow && !inLockWindow
    }

    private func applyLock() {
        for app in LockedAppsStore.shared.enforcedApps where userOverrides[app.bundleIdentifier] != false {
            AppLockSessionManager.shared.revokeSession(for: app.bundleIdentifier)
        }
    }

    private func applyUnlock() {
        for app in LockedAppsStore.shared.enforcedApps where userOverrides[app.bundleIdentifier] != true {
            AppLockSessionManager.shared.createSession(for: app.bundleIdentifier)
        }
    }

    /// True if the two enabled windows share any minute of the day.
    private func computeOverlap() -> Bool {        guard lockWindow.isEnabled, unlockWindow.isEnabled,
              !lockWindow.isEmpty, !unlockWindow.isEmpty else { return false }

        // Minute-granular scan: this is a one-shot check on load and on edit, not
        // a per-frame cost, so the simple loop beats a clever closed-form version
        // that would need its own test suite.
        for minute in 0..<1440 {
            let hour = minute / 60
            let minuteOfHour = minute % 60
            if lockWindow.contains(hour: hour, minute: minuteOfHour),
               unlockWindow.contains(hour: hour, minute: minuteOfHour) {
                return true
            }
        }
        return false
    }

    /// Recomputes the overlap flag. Called from each window's `didSet`.
    private func recomputeOverlap() {
        windowsOverlap = computeOverlap()
    }

    // MARK: - Persistence

    private func persistWindows() {
        if let data = try? JSONEncoder().encode(lockWindow) {
            defaults.set(data, forKey: FIDConstants.Defaults.lockSchedule)
        }
        if let data = try? JSONEncoder().encode(unlockWindow) {
            defaults.set(data, forKey: FIDConstants.Defaults.unlockSchedule)
        }
    }

    private func persistOverrides() {
        guard let data = try? JSONEncoder().encode(userOverrides) else { return }
        defaults.set(data, forKey: FIDConstants.Defaults.scheduleUserOverrides)
    }

    private static func loadWindow(key: String, fallback: ScheduleWindow) -> ScheduleWindow {
        guard let data = UserDefaults.standard.data(forKey: key),
              let window = try? JSONDecoder().decode(ScheduleWindow.self, from: data) else {
            return fallback
        }
        return window
    }
}
