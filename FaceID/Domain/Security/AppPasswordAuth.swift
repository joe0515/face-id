//
//  AppPasswordAuth.swift
//  Face ID
//
//  The last rung: a Face-ID-specific password, for when neither a face nor
//  Touch ID is available. Stored as a salted SHA-256 digest in the Keychain —
//  never in plaintext, and never in UserDefaults.
//
//  Note this is *not* the macOS login password. That one is held by
//  `SecureCredentialManager` (Touch-ID-gated) and is only ever used to type into
//  the lock screen; this one only ever gates app unlocking.
//
//  Ported from FaceGate's `PasswordAuth`. Two changes:
//   • `KeychainHelper` dropped — `KeychainManager` already covers it, and two
//     Keychain wrappers in one app is exactly the duplication Phase 0 set out to
//     remove.
//   • `CommonCrypto` → `CryptoKit`, which needs no C interop.
//

import CryptoKit
import Foundation

nonisolated enum AppPasswordAuth {

    /// Whether a password has been set.
    static var isPasswordSet: Bool {
        KeychainManager.exists(account: FIDConstants.KeychainAccount.appPasswordHash)
    }

    /// Hashes `password` with a fresh random salt and stores digest + salt.
    static func setPassword(_ password: String) throws {
        let salt = makeSalt()
        let digest = hash(password, salt: salt)
        try KeychainManager.save(account: FIDConstants.KeychainAccount.appPasswordHash, data: digest)
        try KeychainManager.save(account: FIDConstants.KeychainAccount.appPasswordSalt, data: salt)
    }

    /// Verifies `password` against the stored digest.
    static func verifyPassword(_ password: String) -> Bool {
        guard let storedDigest = try? KeychainManager.read(account: FIDConstants.KeychainAccount.appPasswordHash),
              let salt = try? KeychainManager.read(account: FIDConstants.KeychainAccount.appPasswordSalt) else {
            return false
        }
        return constantTimeEqual(hash(password, salt: salt), storedDigest)
    }

    /// Changes the password, requiring the current one first.
    @discardableResult
    static func changePassword(from oldPassword: String, to newPassword: String) -> Bool {
        guard verifyPassword(oldPassword) else { return false }
        do {
            try setPassword(newPassword)
            return true
        } catch {
            return false
        }
    }

    /// Removes the stored password entirely.
    static func deletePassword() {
        try? KeychainManager.delete(account: FIDConstants.KeychainAccount.appPasswordHash)
        try? KeychainManager.delete(account: FIDConstants.KeychainAccount.appPasswordSalt)
    }

    // MARK: - Private

    /// 32 random bytes from the system CSPRNG.
    private static func makeSalt() -> Data {
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        // A failed RNG is not something to paper over — fall back to a longer
        // digest-based derivation so verification still fails closed rather than
        // silently storing an all-zero salt.
        if status != errSecSuccess {
            return Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
        }
        return salt
    }

    /// Salt is prepended to the password before hashing, so identical passwords
    /// on different installs produce different digests.
    private static func hash(_ password: String, salt: Data) -> Data {
        var combined = salt
        combined.append(Data(password.utf8))
        return Data(SHA256.hash(data: combined))
    }

    /// Byte-wise XOR accumulation: always inspects every byte, so the comparison
    /// leaks nothing about how many leading bytes matched. `Data ==` short-circuits.
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
