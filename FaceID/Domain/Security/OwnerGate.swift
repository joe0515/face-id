//
//  OwnerGate.swift
//  Face ID
//
//  The "prove it's you" gate in front of the two menu actions that would otherwise
//  make app locking decorative: pausing protection, and quitting.
//
//  Why those two specifically: the status menu is reachable even while an app is
//  blocked — the shield covers the app's windows, not the menu bar. Without a gate,
//  anyone who walks up to an unlocked Mac can pick "暂停 15 分钟" or "退出 Face ID"
//  and then simply open the locked app. Neither action is destructive on its own, so
//  the gate is not about data loss; it is about not handing out an off switch.
//
//  Scope worth knowing: this covers the menu-bar and Cmd-Q paths, which are the ones
//  a person at the machine can reach. It cannot stop `killall` or `osascript -e
//  'quit app "Face ID"'` — no in-process code can, and pretending otherwise would be
//  worse than saying so.
//

import AppKit

@MainActor
final class OwnerGate {

    static let shared = OwnerGate()

    /// One prompt at a time. Menu items stay clickable while a system sheet is up, and
    /// running two `LAContext` evaluations at once is how you get one of them
    /// cancelled by the other.
    private(set) var isVerifying = false

    private init() {}

    /// - Parameter isRequired: decided by the caller, because only it knows whether
    ///   app locking is actually enforcing anything. Prompting when nothing is
    ///   protected would be pure friction.
    /// - Returns: `true` when the caller may go ahead.
    func authorize(reason: String, isRequired: Bool) async -> Bool {
        guard isRequired else { return true }
        guard !isVerifying else { return false }

        isVerifying = true
        defer { isVerifying = false }

        switch await TouchIDAuth.shared.authenticateOwner(reason: reason) {
        case .success:
            return true

        case .failure(.cancelled), .failure(.fallbackRequested):
            // "Changed my mind", not a failure. Matches how the app-lock ladder treats
            // a cancelled Touch ID sheet: no second prompt, no alert.
            return false

        case .failure(let error):
            presentFailure(error.localizedDescription)
            return false
        }
    }

    /// Only reached for something the user didn't cause by cancelling — a missing
    /// password policy, a locked-out secure enclave, and so on. Silent refusal there
    /// would look like the menu item is broken.
    private func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法验证身份"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        // An `.accessory` app has no Dock icon to bounce, so without this the alert can
        // appear behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
