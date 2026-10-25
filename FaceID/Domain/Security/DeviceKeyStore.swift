//
//  DeviceKeyStore.swift
//  Face ID
//
//  The device-level key that encrypts face templates and the stored macOS
//  password from 1.3 on.
//
//  Why it exists: both blobs used to be encrypted under the Touch-ID session
//  key (`SecureCredentialManager`), which made *face unlock itself* depend on
//  the session being unlocked — so every cold launch needed a Touch ID prompt
//  before the notch could scan, and a session that auto-locked during sleep
//  silently disabled face unlock on wake ("sleep, wake, no face prompt").
//  The session lock now guards Settings only; the data it no longer protects
//  moved here.
//
//  Why a **file** and not a keychain item — measured, not assumed (probe ran
//  2026-10-25 on this machine):
//
//  - A `SecItemAdd` generic password always gets an ACL naming the creating
//    application. For an ad-hoc signature that identity is the cdhash, so
//    every rebuild turns the previous build's item into a foreign one and the
//    next read blocks on the system's "wants to access confidential
//    information" dialog (it asks for the login keychain password).
//  - `SecAccessCreate` with an *empty* trusted list does not mean
//    "unrestricted": a cross-identity read of such an item still blocks on
//    the confirmation dialog (the probe hung until killed).
//  - `SecTrustedApplicationCreateFromPath(NULL)` is "yourself", not "any app".
//
//  So a keychain item cannot be both prompt-free and stable across ad-hoc
//  rebuilds — which is exactly the bug class this refactor removes. A file
//  with mode 0600 inside a 0700 directory has no identity binding at all:
//  no dialog, no per-build re-authorization, and it survives Migration
//  Assistant along with the stores it encrypts.
//
//  What protects it: FileVault (on, on the development machine) plus POSIX
//  permissions — the same trust boundary as a no-ACL keychain item, namely
//  "someone logged in as this user". The files it encrypts stay ciphertext
//  at rest; the gates that must stay strong (Settings, pausing app lock,
//  quitting) are separate `LAContext` checks in the UI layer and never touch
//  this key. With a stable `TEAM_ID` signature the item could move back into
//  the keychain later — the stores don't care which storage backs the key.
//

import Foundation
import CryptoKit
import Security

enum DeviceKeyStoreError: LocalizedError {
    case keyGenerationFailed
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "无法生成设备密钥。"
        case .storageUnavailable:
            return "无法读写设备密钥文件。"
        }
    }
}

nonisolated enum DeviceKeyStore {
    private static let fileName = "device.key"
    private static let keySize = 32

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Face ID", isDirectory: true).appendingPathComponent(fileName)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SymmetricKey?
    /// Held across the whole read-or-mint sequence: two threads minting at
    /// once would each cache a *different* key, and data written by one
    /// couldn't be read by the other.
    private static let mintLock = NSLock()

    /// Reads the device key, minting it on first use. Never prompts.
    ///
    /// Throws only when the file itself can't be read or written — callers on
    /// the unlock path treat that as "can't scan right now", never as a
    /// reason to put a dialog on the lock screen.
    static func deviceKey() throws -> SymmetricKey {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        mintLock.lock(); defer { mintLock.unlock() }
        // A waiter may have minted while this call queued on the lock.
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let url = fileURL else { throw DeviceKeyStoreError.storageUnavailable }
        let directory = url.deletingLastPathComponent()

        let data: Data
        if FileManager.default.fileExists(atPath: url.path) {
            guard let stored = try? Data(contentsOf: url), stored.count == keySize else {
                throw DeviceKeyStoreError.storageUnavailable
            }
            data = stored
        } else {
            var bytes = [UInt8](repeating: 0, count: keySize)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw DeviceKeyStoreError.keyGenerationFailed
            }
            let minted = Data(bytes)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                // `.atomic` writes through a sibling temp file, so the key is
                // never observable half-written.
                try minted.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                throw DeviceKeyStoreError.storageUnavailable
            }
            data = minted
        }

        let key = SymmetricKey(data: data)
        lock.lock()
        cached = key
        lock.unlock()
        return key
    }
}
