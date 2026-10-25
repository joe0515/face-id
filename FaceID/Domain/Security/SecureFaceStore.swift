//
//  SecureFaceStore.swift
//  Face ID
//
//  Low-level encrypted persistence for enrolled face identities.
//
//  From 1.3 the store is encrypted under the **device key** (`DeviceKeyStore`),
//  not the Touch-ID session: face unlock has to read templates on the lock
//  screen, where no settings session exists and none can be created. The
//  session lock now guards Settings only — see `SecureCredentialManager`.
//
//  Two files:
//  - `face-identities.v2.enc` — ring-tagged envelope under the device key.
//    Every new write goes here.
//  - `face-identities.enc` — 1.2-and-earlier: raw AES-GCM under the (now
//    legacy) session key. Only the one-time migration reads it
//    (`migrateLegacyStoreIfNeeded`); `load()` refuses it rather than
//    pretending an empty store.
//

import CryptoKit
import Foundation

enum SecureFaceStoreError: LocalizedError {
    case legacyNeedsVerification
    case deviceKeyUnavailable
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .legacyNeedsVerification:
            return "这份人脸数据还是 1.2 及以前的加密格式，需要验证一次身份完成升级。请登录 macOS，然后在菜单栏 Face ID 图标里验证一次（仅此一次）。"
        case .deviceKeyUnavailable:
            return "暂时读不出设备密钥。设备密钥文件可能被移动或删除过 —— 退出并重新打开 Face ID 可重试。"
        case .decryptionFailed:
            return "解密失败。存储的人脸数据可能已损坏。"
        }
    }
}

nonisolated enum SecureFaceStore {
    /// Why `load()` can't read the store right now, if it can't. Answerable
    /// without prompting, so the unlock path can explain itself instead of
    /// silently not scanning.
    enum UnreadableReason {
        case legacyNeedsVerification
        case deviceKeyUnavailable
    }

    private static let legacyFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("Face ID", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("face-identities.enc")
    }()

    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("Face ID", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("face-identities.v2.enc")
    }()

    /// True if a store exists on disk in either format.
    static var exists: Bool {
        hasLegacyStore || FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// True while a 1.2-format store is still on disk — i.e. the one-time
    /// migration hasn't retired it yet.
    static var hasLegacyStore: Bool {
        FileManager.default.fileExists(atPath: legacyFileURL.path)
    }

    static func unreadableReason() -> UnreadableReason? {
        // v1-only: the data is there, but nothing in this build can read it
        // until the migration runs.
        if hasLegacyStore, !FileManager.default.fileExists(atPath: fileURL.path) {
            return .legacyNeedsVerification
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return (try? DeviceKeyStore.deviceKey()) == nil ? .deviceKeyUnavailable : nil
    }

    static func isReadable() -> Bool {
        unreadableReason() == nil
    }

    /// Throws rather than returning an empty array, so callers can tell
    /// "nothing enrolled" apart from "enrolled, but not readable right now".
    static func load() throws -> [FaceIdentity] {
        if hasLegacyStore, !FileManager.default.fileExists(atPath: fileURL.path) {
            throw SecureFaceStoreError.legacyNeedsVerification
        }
        guard let envelope = try? Data(contentsOf: fileURL) else { return [] }
        guard SecureEnvelope.ring(of: envelope) == .device else {
            throw SecureFaceStoreError.decryptionFailed
        }
        let plaintext = try SecureEnvelope.open(envelope, using: DeviceKeyStore.deviceKey())
        return try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
    }

    /// Always writes the device-keyed format. A successful write retires the
    /// legacy file so a stale session-keyed copy of the same data can't
    /// linger (the reader prefers v2 either way).
    static func save(_ identities: [FaceIdentity]) throws {
        let plaintext = try JSONEncoder().encode(identities)
        let envelope = try SecureEnvelope.seal(plaintext, using: DeviceKeyStore.deviceKey(), ring: .device)
        try envelope.write(to: fileURL, options: .atomic)
        if hasLegacyStore { try? FileManager.default.removeItem(at: legacyFileURL) }
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: legacyFileURL)
    }

    /// One-time 1.2 → 1.3 upgrade: re-encrypts the legacy store under the
    /// device key. `sessionKey` is the v1 key, read from the keychain by the
    /// caller while the user is authenticated — this method never touches the
    /// keychain itself. No-op (beyond retiring a stale copy) once the v2 file
    /// exists. A store that fails to decrypt is left untouched for the user
    /// to clear from the Password page.
    static func migrateLegacyStoreIfNeeded(sessionKey: SymmetricKey) throws {
        guard hasLegacyStore else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: legacyFileURL)
            return
        }
        guard let ciphertext = try? Data(contentsOf: legacyFileURL) else { return }
        let plaintext = try SecureEnvelope.openLegacy(ciphertext, using: sessionKey)
        let identities = try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
        let reencoded = try JSONEncoder().encode(identities)
        let envelope = try SecureEnvelope.seal(reencoded, using: DeviceKeyStore.deviceKey(), ring: .device)
        try envelope.write(to: fileURL, options: .atomic)
        try? FileManager.default.removeItem(at: legacyFileURL)
    }
}
