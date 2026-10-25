//
//  LockMonitor.swift
//  Face ID
//
//  Detects macOS lock/unlock state for the CGEvent injection POC.
//

import Foundation
import AppKit
import CoreGraphics
import Observation

/// Which signal most recently fired — `withObservationTracking`'s `onChange` doesn't say which property changed, so observers
/// read this alongside the monotonic `eventCount` to tell events apart.
enum LockEventKind {
    case screenLocked
    case screenUnlocked
    case willSleep
    /// Display turned back on, from system sleep, display sleep, or the screensaver stopping.
    case wake
}

@Observable
final class LockMonitor {
    /// NOT trustworthy alone: any same-user process can post these distributed notifications, and this process can be
    /// suspended before one is delivered (e.g. lid-close sleep racing a lock). UI/trigger signal only, never a security gate.
    private(set) var isScreenLocked: Bool = false

    /// Catches the case above: lock may have already happened while suspended, so wake is the first chance to notice — callers
    /// should re-derive lock state via `isScreenActuallyLocked()` on change rather than trust `isScreenLocked`.
    private(set) var wakeEventCount: Int = 0

    /// True from `willSleepNotification` until the next wake. `screenIsLocked` fires ~150ms before the system actually finishes
    /// suspending (measured via pmset/os_log correlation), so callers should skip acting on a lock while this is true and wait
    /// for the wake trigger instead.
    private(set) var isSleeping: Bool = false

    /// Observers track `eventCount` (changes on every event, even repeats of the same kind) then read `lastEvent`.
    private(set) var lastEvent: LockEventKind?
    private(set) var eventCount: Int = 0

    /// Process-wide timestamp of the most recent wake signal. Static (not per-instance) so non-coordinator
    /// consumers — notably `SessionAutoLocker` — can see the same wake the coordinator does.
    ///
    /// Exists so a wall-clock idle timer doesn't count an entire sleep as "away": `SessionAutoLocker.evaluate`
    /// treats a recent wake as activity and leaves the settings session alone. `unsafe` because it is mutable
    /// state, but every access is on the main thread: written from the `.main`-queue notification observers
    /// below, read from main-actor consumers.
    nonisolated(unsafe) static private(set) var lastWakeAt: Date?

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        startMonitoring()
    }

    deinit {
        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributed.removeObserver(observer)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
    }

    private func startMonitoring() {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenLocked = true
            self?.record(.screenLocked)
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenLocked = false
            self?.record(.screenUnlocked)
        })
        // Observing the key press that dismissed the screensaver isn't possible — Secure Event Input suppresses keyboard taps
        // on the lock screen regardless of Accessibility trust — so this notification stands in for it.
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.wake)
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSleeping = true
            self?.record(.willSleep)
        })
        // Display- and system-level wake are treated as equivalent triggers — they land within ~100ms of each other in either order.
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordWake()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordWake()
        })
    }

    private func recordWake() {
        isSleeping = false
        wakeEventCount += 1
        Self.lastWakeAt = Date()
        record(.wake)
    }

    private func record(_ kind: LockEventKind) {
        lastEvent = kind
        eventCount += 1
    }

    /// Authoritative lock state from the CoreGraphics session server, not a spoofable notification. Fails closed if unavailable.
    nonisolated static func isScreenActuallyLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Whether the main display is physically asleep.
    ///
    /// `isSleeping` is driven by notifications, and the wake one is not guaranteed to
    /// arrive: the process can be suspended across the transition, and a lid-close
    /// sleep is exactly the case where that happens. A latched `true` silently
    /// suppresses every later trigger, so it is corroborated against the display
    /// server rather than trusted on its own.
    nonisolated static var isDisplayAsleep: Bool {
        // `CGDisplayIsAsleep` returns `boolean_t` (Int32), not Swift `Bool`.
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Clears an `isSleeping` that no wake notification ever came back for.
    /// Idempotent; cheap enough to call on every trigger probe.
    func reconcileSleepState() {
        guard isSleeping, !Self.isDisplayAsleep else { return }
        isSleeping = false
    }
}
