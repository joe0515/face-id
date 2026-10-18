//
//  KeychainTrust.swift
//  Face ID
//
//  Tracks whether the *current* build is on the keychain items' ACL.
//
//  Why this exists: a legacy keychain item records who may read it in its ACL, and
//  for an ad-hoc signed app that identity is the cdhash. Every rebuild changes it, so
//  items written by an earlier build stop trusting the new one — macOS then interrupts
//  with "Face ID wants to use confidential information stored in … " and asks for the
//  login keychain password. Because the read happens on the unlock path, that dialog
//  reads as "face unlock is broken".
//
//  Nothing in-process can make an ad-hoc build keep the trust — the ACL is keyed to a
//  signature we don't have. What we *can* do is stop it from ambushing a scan: notice
//  that the build changed, and let the user perform that one authorization from a
//  menu item, where the dialog is expected and "始终允许" actually sticks.
//
//  A stable identity (`TEAM_ID=… make release`) removes the whole problem.
//

import Foundation
import Security

enum KeychainTrust {

    // 显式 nonisolated：项目默认 MainActor 隔离，enum 的 static let 也会被带上，
    // 而下面几个方法都是 nonisolated 的（钥匙串读写本来就不在主线程）。
    private nonisolated static let defaultsKey = "FID.settings.keychainAuthorizedBuild"

    /// The current binary's cdhash — the identity an ad-hoc ACL entry actually records.
    ///
    /// Cached because the permission panel polls its rows: computing this means walking
    /// the code signature, which is far too heavy for a once-a-second refresh. It cannot
    /// change while the process is alive.
    nonisolated static var currentBuildFingerprint: String? {
        if let cachedBuildFingerprint { return cachedBuildFingerprint }
        let fingerprint = computeBuildFingerprint()
        cachedBuildFingerprint = fingerprint
        return fingerprint
    }

    /// `nonisolated(unsafe)` with a benign race: both callers would compute the same
    /// string, and a lost write only costs one extra signature walk.
    nonisolated(unsafe) private static var cachedBuildFingerprint: String?

    private nonisolated static func computeBuildFingerprint() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let info = information as? [String: Any],
            let unique = info[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint recorded the last time a read succeeded.
    nonisolated static var lastAuthorizedFingerprint: String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }

    /// A password is stored, but this build has never read it — expect the ACL dialog.
    nonisolated static var needsAuthorization: Bool {
        guard SecureCredentialManager.hasStoredPassword() else { return false }
        guard let current = currentBuildFingerprint else { return false }
        return lastAuthorizedFingerprint != current
    }

    /// Records the current build as trusted. Only meaningful after a real read succeeded —
    /// a dialog the user cancelled leaves the ACL untouched.
    nonisolated static func markAuthorized() {
        guard let current = currentBuildFingerprint else { return }
        UserDefaults.standard.set(current, forKey: defaultsKey)
    }
}
