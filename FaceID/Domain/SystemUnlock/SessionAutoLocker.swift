//
//  SessionAutoLocker.swift
//  Face ID
//
//  Enforces `FIDSettings.autoLockInterval`: re-locks the session once idle past the user's chosen limit.
//

import Foundation
import AppKit

@MainActor
final class SessionAutoLocker {
    private let pocController: POCController
    private var timer: Timer?

    /// Fine enough that the shortest selectable limit (1 minute) locks within a
    /// reasonable margin, but not so tight it spins the run loop.
    private let checkInterval: TimeInterval = 30

    /// How long after a wake signal the idle clock stays frozen.
    ///
    /// A sleeping Mac isn't an unattended one: the user closed the lid, they didn't leave.
    /// But the idle clock is wall-clock, so on wake it reads the entire sleep as away-time —
    /// any sleep longer than the limit (3 minutes by default) would re-lock the settings
    /// session the instant the machine wakes. Waking counts as activity; the countdown
    /// restarts from the wake.
    ///
    /// (Face unlock used to share this fate — templates were encrypted under the
    /// in-memory session key, so a re-lock silently disabled it on wake. Since 1.3 the
    /// templates live under the device key and the session guards Settings only, so this
    /// is purely about not yanking the settings session out from under a returning user.)
    ///
    /// Also closes a race: the repeating timer doesn't tick during sleep and fires its
    /// backlog immediately on wake, potentially before the `didWake` observer below runs.
    /// Both paths consult the same `LockMonitor.lastWakeAt`, so whichever runs first sees
    /// the wake and leaves the session alone.
    private let wakeGrace: TimeInterval = 15

    init(pocController: POCController) {
        self.pocController = pocController
        // `.common` so the countdown keeps being checked during tracking runloop modes (an open menu, a drag).
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Re-evaluate on wake: no timer fires during sleep, but the elapsed time
        // still counts as idle once compared.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }

        // Treat returning to the app as activity so an actively-used session
        // doesn't auto-lock mid-edit; only time spent away from the app ages it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.touchActivity() }
        }

        evaluate()
    }

    deinit {
        timer?.invalidate()
    }

    /// Bumps the idle timestamp so active use extends the session — see the
    /// `didBecomeActiveNotification` observer above.
    private func touchActivity() {
        SecureCredentialManager.touchActivity()
    }

    /// Routed through `POCController.lockSession()` rather than `SecureCredentialManager` directly, so the Settings UI's
    /// `isSessionUnlocked` flag doesn't go stale.
    func evaluate() {
        // A recent wake is activity, not idle time — see `wakeGrace`. A frozen clock
        // also means a session that was already locked before sleep stays locked
        // (`touchActivity` is a no-op then).
        if let wakeAt = LockMonitor.lastWakeAt, Date().timeIntervalSince(wakeAt) < wakeGrace {
            touchActivity()
            return
        }

        guard SecureCredentialManager.isSessionUnlocked,
              let lastActivityAt = SecureCredentialManager.lastActivityAt
        else { return }

        let idleLimit = FIDSettings.shared.autoLockInterval.duration
        guard Date().timeIntervalSince(lastActivityAt) >= idleLimit else { return }

        pocController.lockSession()
    }
}
