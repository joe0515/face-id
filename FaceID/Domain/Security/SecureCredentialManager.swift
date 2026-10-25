//
//  SecureCredentialManager.swift
//  Face ID
//
//  Two things live here, deliberately separate since 1.3:
//
//  1. **The device key** — file-backed (`DeviceKeyStore`), readable after
//     login without any prompt. It encrypts the two secrets: the stored macOS
//     password and the face templates. Being prompt-free is what lets face
//     unlock arm on the lock screen, where no settings session exists and
//     none can be created. Before 1.3 both were encrypted under the Touch-ID
//     session key, so a locked session silently disabled face unlock — that
//     coupling is what this type used to be.
//
//  2. **The settings session** — an in-memory flag behind one
//     `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`. It gates the
//     Settings UI (plus the enrollment and Face Lab entry points) and
//     auto-locks after `FIDSettings.autoLockInterval`. It protects **no
//     data**: nothing is encrypted under it any more, so there is no session
//     key in the keychain, no ACL dialog per rebuild, and no re-authorization
//     dance. The 1.2 keychain item (`sessionKey`) is read exactly once — by
//     the migration below — to move old data onto the device key, then
//     deleted.
//
//  What still requires identity, and why: enrolling or deleting faces
//  (`OnboardingController.unlockForEnrollment`), pausing app locking and
//  quitting (`OwnerGate`), and the settings session itself. A successful face
//  match is the authorization for *using* the stored password — that is the
//  feature.
//

import Foundation
import CryptoKit
import LocalAuthentication

enum SecureCredentialError: LocalizedError {
    case emptyPassword
    case noStoredPassword
    case legacyNeedsVerification
    case encryptionFailed
    case decryptionFailed
    case authenticationFailed
    case authenticationUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "密码不能为空。"
        case .noStoredPassword:
            return "还没有存储密码。"
        case .legacyNeedsVerification:
            return "这份数据还是 1.2 及以前的加密格式，需要验证一次身份完成升级。请登录 macOS，然后在菜单栏 Face ID 图标里验证一次（仅此一次）。"
        case .encryptionFailed:
            return "加密失败。"
        case .decryptionFailed:
            return "解密失败。存储的凭据可能已损坏。"
        case .authenticationFailed:
            return "验证被取消或失败。"
        case .authenticationUnavailable:
            return "这台 Mac 无法进行身份验证。"
        }
    }
}

extension Notification.Name {
    /// Fires whenever the settings session locks or unlocks, so the UI (and
    /// `FaceEnrollmentStore`'s "locked" flag) can follow it without every call
    /// site remembering to poll. The *data* no longer depends on the session —
    /// only these flags do.
    static let secureCredentialSessionDidChange = Notification.Name("SecureCredentialManager.sessionDidChange")
}

enum SecureCredentialManager {
    // MARK: - Keychain accounts

    /// The 1.2-and-earlier session key. Read **only** by the one-time
    /// migration (`migrateLegacyStoresIfNeeded`), which deletes it on
    /// success; nothing in 1.3 encrypts under it.
    nonisolated private static let sessionKeyAccount = "sessionKey"
    /// Pre-1.1 location of the password ciphertext, same v1 session key.
    /// Also migrated away and deleted by the same path.
    nonisolated private static let passwordBlobAccount = "encryptedPassword"

    // MARK: - Files

    /// 1.2-and-earlier password ciphertext: raw AES-GCM combined bytes under
    /// the v1 session key.
    nonisolated private static var legacyPasswordFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Face ID", isDirectory: true).appendingPathComponent("credential.enc")
    }

    /// The encrypted password: a ring-tagged envelope under the device key.
    ///
    /// Still a file rather than a keychain item, for the reasons in
    /// `DeviceKeyStore`'s header — every keychain item carries an ACL naming
    /// the build that created it, and this blob must stay readable on the
    /// unlock path across rebuilds without a dialog.
    nonisolated private static var passwordFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Face ID", isDirectory: true).appendingPathComponent("credential.v2.enc")
    }

    nonisolated private static var hasPasswordFileV2: Bool {
        guard let url = passwordFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated private static var hasLegacyPasswordFile: Bool {
        guard let url = legacyPasswordFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated private static var hasLegacyPasswordData: Bool {
        hasLegacyPasswordFile || KeychainManager.exists(account: passwordBlobAccount)
    }

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _isSessionUnlocked = false
    /// Last unlock or successful `readPassword` — what `SessionAutoLocker`
    /// compares against the idle limit.
    nonisolated(unsafe) private static var _lastActivityAt: Date?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _isSessionUnlocked
    }

    /// `nil` whenever the session is locked — there is no activity to age.
    nonisolated static var lastActivityAt: Date? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _lastActivityAt
    }

    nonisolated private static func setSessionUnlocked(_ unlocked: Bool) {
        sessionLock.lock()
        let changed = unlocked != _isSessionUnlocked
        _isSessionUnlocked = unlocked
        _lastActivityAt = unlocked ? Date() : nil
        sessionLock.unlock()
        // Posted after releasing the lock — observers may call back into
        // `isSessionUnlocked` (re-acquiring it) from a background thread.
        guard changed else { return }
        NotificationCenter.default.post(name: .secureCredentialSessionDidChange, object: nil)
    }

    /// Resets the idle countdown on each successful use, so an actively-used
    /// session never auto-locks.
    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _isSessionUnlocked { _lastActivityAt = Date() }
        sessionLock.unlock()
    }

    /// Public entry point for `SessionAutoLocker` to refresh the idle
    /// timestamp when the user returns to the app. No-op while locked.
    nonisolated static func touchActivity() {
        recordActivity()
    }

    // MARK: - Session gate (Settings only)

    /// Verifies identity and unlocks the **settings session**. No keychain,
    /// no key: since 1.3 the session protects no data, so the only honest
    /// implementation is the check itself.
    ///
    /// A successful call also runs the one-time migration of 1.2-era data
    /// (see `migrateLegacyStoresIfNeeded`) while the user is right here —
    /// the evaluated `LAContext` is passed along so a gated keychain read
    /// can't produce a second prompt.
    ///
    /// The early return deliberately keeps `needsLegacyMigration` in the
    /// condition: a session that is already unlocked but whose migration
    /// hasn't landed yet (the user cancelled the launch prompt, or the
    /// keychain read failed) must be able to re-run it — otherwise the
    /// data would stay stuck on the old format until the next relaunch,
    /// with the lock-screen notice pointing at a verification that does
    /// nothing.
    nonisolated static func unlockSession(reason: String) async throws {
        if isSessionUnlocked, !needsLegacyMigration { return }

        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw SecureCredentialError.authenticationUnavailable
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw SecureCredentialError.authenticationFailed
        }

        // Ordered before the flag flips so observers (which reload the face
        // store) see post-migration data. A failure here is retried on the
        // next unlock — the session itself is still useful without it.
        try? await migrateLegacyStoresIfNeeded(context: context)
        setSessionUnlocked(true)
    }

    /// Locks the settings session. Next Settings use requires identity again.
    nonisolated static func lockSession() {
        setSessionUnlocked(false)
    }

    // MARK: - Password storage (device key)

    nonisolated static func hasStoredPassword() -> Bool {
        hasPasswordFileV2 || hasLegacyPasswordData
    }

    /// Encrypts and stores `passwordBytes` under the device key.
    ///
    /// No session check: the crypto no longer needs one, and every caller is
    /// already behind the UI's identity gate (`unlockSession` at the
    /// Settings / onboarding entry points). Blocking; call from a background
    /// task.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        let envelope = try SecureEnvelope.seal(passwordBytes, using: DeviceKeyStore.deviceKey(), ring: .device)
        try writePasswordCiphertext(envelope)
        // Older copies would otherwise keep a stale credential around — and
        // the keychain one would keep demanding its own ACL authorization.
        if let legacyURL = legacyPasswordFileURL {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        try? KeychainManager.delete(account: passwordBlobAccount)
    }

    nonisolated private static func writePasswordCiphertext(_ envelope: Data) throws {
        guard let url = passwordFileURL else { throw SecureCredentialError.encryptionFailed }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try envelope.write(to: url, options: .atomic)
    }

    /// Reads and decrypts the stored password. No prompt, no session: the
    /// caller's face match is the authorization. Caller MUST zero the
    /// returned bytes via `.resetBytes(in:)` after use. Blocking; call from a
    /// background task.
    nonisolated static func readPassword() throws -> Data {
        guard hasPasswordFileV2, let url = passwordFileURL else {
            if hasLegacyPasswordData { throw SecureCredentialError.legacyNeedsVerification }
            throw SecureCredentialError.noStoredPassword
        }
        let envelope = try Data(contentsOf: url)
        guard SecureEnvelope.ring(of: envelope) == .device else {
            throw SecureCredentialError.decryptionFailed
        }
        let plaintext = try SecureEnvelope.open(envelope, using: DeviceKeyStore.deviceKey())
        // Only on success: a failed read shouldn't extend the idle window.
        recordActivity()
        return plaintext
    }

    /// Removes every copy of the password. The device key file deliberately
    /// stays: it is 32 random bytes, and deleting it while the face store
    /// still uses it would destroy enrolled faces.
    nonisolated static func deletePassword() throws {
        if let url = passwordFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = legacyPasswordFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        try? KeychainManager.delete(account: passwordBlobAccount)
        // The v1 session-key item only survives while a legacy store still
        // needs it for the migration.
        if !SecureFaceStore.hasLegacyStore {
            try? KeychainManager.delete(account: sessionKeyAccount)
        }
        lockSession()
    }

    // MARK: - One-time migration (1.2 → 1.3)

    /// True while any 1.2-and-earlier encrypted data is still on disk. This
    /// is the only thing that still triggers a launch-time identity prompt.
    nonisolated static var needsLegacyMigration: Bool {
        SecureFaceStore.hasLegacyStore || hasLegacyPasswordData
    }

    /// Re-encrypts 1.2-era data under the device key, then deletes the v1
    /// session-key item. Idempotent and cheap when there is nothing to do.
    ///
    /// The v1 key is a keychain item whose ACL names the build that created
    /// it. On an ad-hoc build that is an older cdhash, so this read can raise
    /// the system's confirmation dialog — one time, right here, while the user
    /// is authenticated and expecting it. (A stable `TEAM_ID` signature reads
    /// the same item silently through the passed context.) The keychain read
    /// is preceded by `relinquishKeyForSystemPrompt` for the same reason the
    /// old permission panel did it: the dialog belongs to SecurityAgent and
    /// needs the keyboard.
    nonisolated static func migrateLegacyStoresIfNeeded(context: LAContext? = nil) async throws {
        guard needsLegacyMigration else { return }

        let panelIsUp = await MainActor.run { NotchOverlayController.shared.phase != .closed }
        if panelIsUp {
            await MainActor.run { NotchOverlayController.shared.relinquishKeyForSystemPrompt() }
        }

        let legacyKeyData = try KeychainManager.read(account: sessionKeyAccount, context: context)
        let legacyKey = SymmetricKey(data: legacyKeyData)

        // Password first: it is the blob the unlock path needs, and an
        // undecryptable face store shouldn't hold it back.
        try migrateLegacyPasswordIfNeeded(sessionKey: legacyKey, context: context)
        // Contained: a face store that no longer decrypts stays on disk for
        // the user to clear from the Password page — never deleted silently.
        try? SecureFaceStore.migrateLegacyStoreIfNeeded(sessionKey: legacyKey)

        if !SecureFaceStore.hasLegacyStore, !hasLegacyPasswordData {
            try? KeychainManager.delete(account: sessionKeyAccount)
        }
    }

    nonisolated private static func migrateLegacyPasswordIfNeeded(sessionKey: SymmetricKey, context: LAContext?) throws {
        guard !hasPasswordFileV2 else {
            // v2 already won — retire the older copies.
            if let legacyURL = legacyPasswordFileURL {
                try? FileManager.default.removeItem(at: legacyURL)
            }
            try? KeychainManager.delete(account: passwordBlobAccount)
            return
        }
        let ciphertext: Data
        if hasLegacyPasswordFile, let url = legacyPasswordFileURL {
            ciphertext = try Data(contentsOf: url)
        } else if KeychainManager.exists(account: passwordBlobAccount) {
            // Pre-1.1 installs: the ciphertext is still a keychain item under
            // the same v1 key. Its ACL may need the user's answer — pass the
            // evaluated context so it rides along with the read above.
            ciphertext = try KeychainManager.read(account: passwordBlobAccount, context: context)
        } else {
            return
        }
        let plaintext = try SecureEnvelope.openLegacy(ciphertext, using: sessionKey)
        try writePasswordCiphertext(try SecureEnvelope.seal(plaintext, using: DeviceKeyStore.deviceKey(), ring: .device))
        if let legacyURL = legacyPasswordFileURL {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        try? KeychainManager.delete(account: passwordBlobAccount)
    }
}
