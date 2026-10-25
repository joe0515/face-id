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
            Task { @MainActor [weak self] in self?.evaluate() }
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
        guard SecureCredentialManager.isSessionUnlocked,
              let lastActivityAt = SecureCredentialManager.lastActivityAt
        else { return }

        let idleLimit = FIDSettings.shared.autoLockInterval.duration
        guard Date().timeIntervalSince(lastActivityAt) >= idleLimit else { return }

        pocController.lockSession()
    }
}
