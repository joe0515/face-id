//
//  SecureCredentialManager.swift
//  Face ID
//
//  Two-tier storage on KeychainManager: a Touch-ID-gated session key (unwrapped once per launch) wraps an ungated encrypted
//  password blob, safe to read anytime — including the lock screen, where no app UI exists to host a Touch ID prompt.
//  Touch ID authorizes the session; nothing yet authorizes each individual unlock beyond that (face recognition will).
//

import Foundation
import CryptoKit
import LocalAuthentication

enum SecureCredentialError: LocalizedError {
    case emptyPassword
    case sessionLocked
    case encryptionFailed
    case decryptionFailed
    case sessionKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "密码不能为空。"
        case .sessionLocked:
            return "会话已锁定。请先用触控 ID 验证，再存储或使用密码。"
        case .encryptionFailed:
            return "加密失败。"
        case .decryptionFailed:
            return "解密失败。存储的凭据可能已损坏。"
        case .sessionKeyUnavailable:
            return "会话密钥缺失，但仍存在只有它能解开的加密数据。没有删除任何内容。请在「密码」页移除已存储的密码，把两者一并清除后重新开始。"
        }
    }
}

extension Notification.Name {
    /// Fires whenever the cached session key changes, so anything encrypted under it (e.g. `FaceEnrollmentStore`) can reload
    /// itself instead of relying on each call site to remember to — a past bug had the sidebar's unlock forget this, leaving
    /// face unlock silently running on stale pre-unlock data.
    static let secureCredentialSessionDidChange = Notification.Name("SecureCredentialManager.sessionDidChange")
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"
    nonisolated private static let passwordBlobAccount = "encryptedPassword"

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?
    /// Last unlock or successful `readPassword` — what `SessionAutoLocker` compares against the idle limit. Guarded by
    /// `sessionLock` alongside the key so the two can never be observed out of step.
    nonisolated(unsafe) private static var _lastActivityAt: Date?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    /// `nil` whenever the session is locked — there is no activity to age.
    nonisolated static var lastActivityAt: Date? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _lastActivityAt
    }

    nonisolated private static func cachedKey() -> SymmetricKey? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey
    }

    nonisolated private static func setCachedKey(_ key: SymmetricKey?) {
        sessionLock.lock()
        let changed = (key != nil) != (_cachedKey != nil)
        _cachedKey = key
        _lastActivityAt = key == nil ? nil : Date()
        sessionLock.unlock()
        // Posted after releasing the lock — observers may call back into `isSessionUnlocked` (re-acquiring it) from a
        // background thread, so posting while still locked risks a real self-deadlock, not a theoretical one.
        guard changed else { return }
        NotificationCenter.default.post(name: .secureCredentialSessionDidChange, object: nil)
    }

    /// Resets the idle countdown on each successful use, so an actively-used session never auto-locks.
    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _cachedKey != nil { _lastActivityAt = Date() }
        sessionLock.unlock()
    }

    // MARK: - Generic session-key crypto (shared by passwords here and face embeddings in SecureFaceStore; requires an unlocked session)

    nonisolated static func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw SecureCredentialError.encryptionFailed }
            return combined
        } catch {
            throw SecureCredentialError.encryptionFailed
        }
    }

    nonisolated static func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureCredentialError.decryptionFailed
        }
    }

    // MARK: - Session-key protection

    /// How the session key is protected at rest.
    ///
    /// Two rungs, because the strong one is not always available:
    ///
    /// - `.keychainGated` — the item is created with a `.userPresence` access control,
    ///   so **the system** refuses to hand the key over without the user's biometry.
    ///   This is what the design wants.
    /// - `.appVerified` — the item is stored plainly and this app asks for Touch ID
    ///   (or the login password) before reading it. Used only when the keychain
    ///   rejects a gated item outright.
    ///
    /// A gated item requires the app to carry a `keychain-access-groups` entitlement,
    /// which in turn requires a real Apple signing identity. Unsigned builds, ad-hoc
    /// builds, and ad-hoc builds with every entitlement we can sign all get
    /// `errSecMissingEntitlement` from `SecItemAdd`; adding `keychain-access-groups`
    /// to an ad-hoc signature instead gets the process **killed by AMFI at launch**.
    /// So there is no packaging-script fix for this — hence the fallback.
    ///
    /// The difference is real and is surfaced in Settings: under `.appVerified` the
    /// only thing standing between the key and a caller is this app's own check, so
    /// code injected into this process could read it without a prompt.
    ///
    /// ⚠️ Sign the app with a development team (`TEAM_ID=… make release`) to get the
    /// strong rung; that also stops the Accessibility grant from dying on every
    /// rebuild.
    ///
    /// `nonisolated` explicitly: a nested type does **not** inherit the enclosing
    /// type's isolation, so without this it would pick up the project's default
    /// `MainActor` and its `static var` could not be touched from the nonisolated
    /// session-key paths.
    nonisolated enum SessionKeyProtection: String {
        case keychainGated
        case appVerified

        /// Recorded when the key is minted and read back on every later launch. The
        /// read path **must** know this in advance: handing an `LAContext` to a plain
        /// item is a silent success, so assuming "gated" would return the key with no
        /// prompt at all. Defaults to `.keychainGated`, matching pre-fallback builds.
        static var stored: SessionKeyProtection {
            get {
                UserDefaults.standard.string(forKey: FIDConstants.Defaults.sessionKeyProtection)
                    .flatMap(SessionKeyProtection.init(rawValue:)) ?? .keychainGated
            }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: FIDConstants.Defaults.sessionKeyProtection)
            }
        }

        var title: String {
            switch self {
            case .keychainGated: return "钥匙串强制（Touch ID）"
            case .appVerified: return "应用内校验（当前构建无法使用钥匙串强制）"
            }
        }
    }

    // MARK: - Public API

    nonisolated static func hasStoredPassword() -> Bool {
        KeychainManager.exists(account: passwordBlobAccount)
    }

    /// Prompts for identity and unwraps the session key, creating it on first run.
    /// Caches only after a real gated read-back succeeds — `SecItemAdd` alone returns
    /// success even if the user hit Cancel on the auth UI, and bridging
    /// `LAContext.evaluatePolicy` synchronously via a semaphore deadlocks the thread
    /// pool and crashes the process.
    /// Must succeed before `savePassword`/`readPassword`.
    nonisolated static func unlockSession(reason: String) async throws {
        if cachedKey() != nil { return }

        // The existence check, not the read, decides whether a key gets created (load-bearing): a cancelled Touch ID prompt on
        // a user-presence item reports `errSecItemNotFound`, indistinguishable from no key — deciding on the read's error would
        // mint a fresh key (destroying the one that decrypts existing data) on every mis-tap.
        if KeychainManager.exists(account: sessionKeyAccount) {
            let data = try await readSessionKey(reason: reason)
            setCachedKey(SymmetricKey(data: data))
            return
        }

        // No key at all, but minting one is still destructive if data is already encrypted under a previous key (e.g. a
        // re-signed dev build) — refuse rather than silently render it unreadable forever.
        guard !hasSessionEncryptedData else {
            throw SecureCredentialError.sessionKeyUnavailable
        }

        let key = SymmetricKey(size: .bits256)
        try await mintSessionKey(key.withUnsafeBytes { Data($0) }, reason: reason)
        setCachedKey(key)
    }

    /// Mints the key at the strongest rung this build can actually hold.
    ///
    /// Decided by *trying*, not by inspecting entitlements: an entitlement can be
    /// present and still be rejected by AMFI, so any local check would be a second,
    /// wronger copy of the system's rules.
    nonisolated private static func mintSessionKey(_ keyBytes: Data, reason: String) async throws {
        do {
            let access = try KeychainManager.makeUserPresenceAccessControl()
            try KeychainManager.save(account: sessionKeyAccount, data: keyBytes, accessControl: access)

            let readBackContext = LAContext()
            readBackContext.localizedReason = reason
            _ = try KeychainManager.read(account: sessionKeyAccount, context: readBackContext)
            SessionKeyProtection.stored = .keychainGated
        } catch let error as KeychainError where error.isMissingEntitlement {
            // The keychain won't gate an item for this build. Store it plainly and let
            // the app do the asking — see `SessionKeyProtection` for the trade-off.
            try KeychainManager.save(account: sessionKeyAccount, data: keyBytes)
            SessionKeyProtection.stored = .appVerified
        }
    }

    /// Reads the key back at whichever rung it was stored.
    nonisolated private static func readSessionKey(reason: String) async throws -> Data {
        let data: Data
        switch SessionKeyProtection.stored {
        case .keychainGated:
            let context = LAContext()
            context.localizedReason = reason
            data = try KeychainManager.read(account: sessionKeyAccount, context: context)
        case .appVerified:
            // The item itself is ungated, so the prompt has to come from here —
            // a plain read would otherwise hand the key over silently.
            try await requireUserPresence(reason: reason)
            data = try KeychainManager.read(account: sessionKeyAccount)
        }
        // Only a read that actually returned data proves this build is on the item's
        // ACL — see `KeychainTrust`.
        KeychainTrust.markAuthorized()
        return data
    }

    /// Forces a fresh read even when the key is already cached, so the ACL dialog (if
    /// this build hasn't been authorized yet) appears at a moment the user chose rather
    /// than in the middle of a face scan. Called from the menu bar item, and from the
    /// unlock path *before* it starts scanning.
    ///
    /// Reads the password blob as well as the session key. They are two separate
    /// keychain items with independent ACLs, and both are keyed to the cdhash — an
    /// authorization that only covers the key leaves the read on the unlock path to
    /// spring the very dialog this method exists to pre-empt. That is where the
    /// "two prompts in a row" report came from.
    nonisolated static func reauthorizeKeychain(reason: String) async throws {
        guard KeychainManager.exists(account: sessionKeyAccount) else {
            throw SecureCredentialError.sessionKeyUnavailable
        }
        let data = try await readSessionKey(reason: reason)
        setCachedKey(SymmetricKey(data: data))
        if KeychainManager.exists(account: passwordBlobAccount) {
            _ = try readPassword()
        }
    }

    /// Asks for Touch ID — or the login password where there's no biometric hardware.
    ///
    /// `.deviceOwnerAuthentication` rather than the biometrics-only policy
    /// `TouchIDAuth` uses: this rung has to work on every Mac, and a machine without
    /// Touch ID would otherwise be unable to unlock the session at all.
    nonisolated private static func requireUserPresence(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw KeychainError.accessControlFailed(error?.localizedDescription ?? "这台 Mac 无法进行身份验证")
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw KeychainError.authenticationFailed
        }
    }

    /// Checked without needing the key itself, so this stays answerable precisely when the key can't be read.
    nonisolated static var hasSessionEncryptedData: Bool {
        KeychainManager.exists(account: passwordBlobAccount) || SecureFaceStore.exists
    }

    /// Clears the cached session key. Next save/read requires Touch ID again.
    nonisolated static func lockSession() {
        setCachedKey(nil)
    }

    /// Encrypts and stores `passwordBytes`. Requires an unlocked session —
    /// call `unlockSession(reason:)` first. Blocking; call from a background task.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        let combined = try encrypt(passwordBytes)
        try KeychainManager.save(account: passwordBlobAccount, data: combined)
    }

    /// No separate Touch ID prompt — only the session key was gated, at unlock time. Caller MUST zero the returned bytes via
    /// `.resetBytes(in:)` after use. Blocking; call from a background task.
    nonisolated static func readPassword() throws -> Data {
        guard cachedKey() != nil else { throw SecureCredentialError.sessionLocked }
        let ciphertext = try KeychainManager.read(account: passwordBlobAccount)
        let plaintext = try decrypt(ciphertext)
        // Only on success: a failed read shouldn't extend the idle window.
        recordActivity()
        return plaintext
    }

    /// Deletes both Keychain items and clears the cached session key.
    nonisolated static func deletePassword() throws {
        try KeychainManager.delete(account: passwordBlobAccount)
        try KeychainManager.delete(account: sessionKeyAccount)
        setCachedKey(nil)
    }
}
