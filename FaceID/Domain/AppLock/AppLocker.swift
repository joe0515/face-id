//
//  AppLocker.swift
//  Face ID
//
//  The enforcement layer: takes a running app away from the user and gives it
//  back, or ends it. Deliberately knows nothing about *how* the user is asked to
//  authenticate — presentation belongs to `AppUnlockCoordinator`, which owns the
//  notch panel and the window shield.
//
//  Ported from FaceGate's `AppLocker`, with `showOverlays`/`dismissOverlays`
//  removed: those built full-screen `NSPanel`s, which Phase 3/4 replace with the
//  window-level shield plus the notch panel.
//
//  Why `hide()` rather than terminating: the app keeps its state and window
//  contents, so unlocking is instant and lossless. The user never sees the app's
//  UI while it's blocked, and macOS removes it from the window list entirely, so
//  it can't be reached via Mission Control either.
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppLocker {

    static let shared = AppLocker()

    /// Bundle identifier of the app currently being held, if any.
    private(set) var blockedBundleID: String?

    /// The running app instance being held.
    private(set) var blockedRunningApp: NSRunningApplication?

    var isBlocking: Bool { blockedBundleID != nil }

    @ObservationIgnored private let sessions = AppLockSessionManager.shared
    @ObservationIgnored private let monitor = AppMonitor.shared

    private init() {}

    // MARK: - Blocking

    /// Records `runningApp` as the app under challenge.
    ///
    /// Re-entrant calls for the same app are ignored, so a burst of
    /// launch+activate notifications can't stack two challenges.
    ///
    /// - Parameter hidesApp: whether *this* call should hide the app. It is `true`
    ///   for the `.hidden` strategy, and `false` when the window shield is covering
    ///   the app instead — hiding it there would remove the very windows being
    ///   covered. Enforcement therefore stays with whichever strategy actually won;
    ///   this type only tracks state and owns the release/terminate paths.
    func block(bundleID: String, runningApp: NSRunningApplication, hidesApp: Bool) {
        guard blockedBundleID != bundleID else { return }
        // A different app is already being challenged — the caller should resolve
        // that one first rather than silently stealing the slot.
        guard blockedBundleID == nil else { return }

        blockedBundleID = bundleID
        blockedRunningApp = runningApp
        if hidesApp { runningApp.hide() }
    }

    // MARK: - Resolving

    /// Authentication succeeded: restore the app and open an unlock session.
    func unlockCurrentApp() {
        guard let bundleID = blockedBundleID else { return }
        let app = blockedRunningApp

        // Clear state *before* activating: activating fires
        // `didActivateApplication`, and `AppMonitor` would otherwise see a locked,
        // session-less app still registered and immediately re-block it.
        blockedBundleID = nil
        blockedRunningApp = nil

        sessions.createSession(for: bundleID)
        monitor.recordUnlock(for: bundleID)

        guard let app else { return }
        app.unhide()
        // Deliberately no activation options: `.activateIgnoringOtherApps` is
        // deprecated as of macOS 14 and ignored there — the system now decides
        // whether activation is warranted, and restoring an app the user just
        // unlocked is exactly the intended case.
        app.activate()
        // …but "the system decides" also means it may decide *not* to bring the
        // windows back for an app whose windows were ordered out — leaving the user
        // to click the Dock icon after a successful unlock. Raising the window
        // explicitly is what actually restores it.
        DispatchQueue.main.async {
            AppWindowPresenter.raiseMainWindow(of: app)
        }
    }

    /// User cancelled, or authentication failed permanently: end the app.
    ///
    /// Termination is asked for politely first — an app mid-save gets a moment to
    /// flush — with a forced kill as the backstop.
    func terminateBlockedApp() {
        guard let app = blockedRunningApp else {
            reset()
            return
        }

        blockedBundleID = nil
        blockedRunningApp = nil

        app.terminate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(FIDConstants.terminateGracePeriod))
            guard !app.isTerminated else { return }
            app.forceTerminate()
        }
    }

    /// Drops local state without touching the app. Used when the feature is being
    /// shut down (e.g. app quit) so a restart doesn't inherit a stale challenge.
    func reset() {
        blockedBundleID = nil
        blockedRunningApp = nil
    }
}
