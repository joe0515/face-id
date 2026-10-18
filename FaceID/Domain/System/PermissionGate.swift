//
//  PermissionGate.swift
//  Face ID
//
//  "Is anything Face ID depends on missing right now?"
//
//  Kept apart from any UI so the launch path and the menu bar can ask the same
//  question without dragging a window in. The guidance itself is drawn in the notch
//  (`OnboardingController.startPermissionReview()`), not in a separate dialog.
//
//  Accessibility is the load-bearing grant: without it `WindowShieldManager` has no
//  window geometry to attach a cover to and falls back to hiding the app — and when
//  that fallback can't run either, the "locked" app simply shows.
//

import AVFoundation

nonisolated enum PermissionGate {

    /// True when at least one grant is missing.
    ///
    /// Deliberately *not* a one-shot "have we shown the gate yet" flag: a reinstall,
    /// a `tccutil reset`, and every rebuild with a new ad-hoc cdhash all invalidate
    /// the grants without touching UserDefaults, so the state has to be re-derived.
    ///
    /// The keychain counts as a grant too: an ad-hoc build only gets access to the items
    /// written by an earlier build after the user answers the ACL dialog once, and until
    /// that happens every unlock is interrupted by it.
    static var needsAttention: Bool {
        !AccessibilityPermission.check().isFullyGranted
            || AVCaptureDevice.authorizationStatus(for: .video) != .authorized
            || KeychainTrust.needsAuthorization
    }
}
