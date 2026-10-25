//
//  SecureEnvelope.swift
//  Face ID
//
//  The on-disk format for everything Face ID encrypts: a one-byte ring tag in
//  front of an AES-GCM combined blob.
//
//  Two rings, because 1.3 moved both blobs off the Touch-ID session key onto
//  a device-level key (see `DeviceKeyStore`):
//
//  - `.device` — what every new write uses.
//  - `.session` — what 1.2-and-earlier wrote, with **no tag at all**: those
//    files are the raw `AES.GCM.SealedBox.combined` bytes. They live at their
//    own legacy paths (`face-identities.enc`, `credential.enc`) rather than
//    being sniffed here — a raw combined blob starts with a random nonce, so
//    "does this file start with a tag byte?" cannot be answered by looking.
//
//  The tag lets a v2 file state which key it expects, so reading one that
//  claims `.session` is reported as corruption instead of being silently
//  decrypted with whichever key happens to be lying around.
//

import Foundation
import CryptoKit

nonisolated enum SecureEnvelope {
    enum Ring: UInt8 {
        case session = 0x53 // 'S'
        case device = 0x44  // 'D'
    }

    static func seal(_ plaintext: Data, using key: SymmetricKey, ring: Ring) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard var combined = sealed.combined else {
            throw SecureEnvelopeError.encryptionFailed
        }
        combined.insert(ring.rawValue, at: 0)
        return combined
    }

    static func ring(of envelope: Data) -> Ring? {
        guard let first = envelope.first else { return nil }
        return Ring(rawValue: first)
    }

    static func open(_ envelope: Data, using key: SymmetricKey) throws -> Data {
        guard envelope.count > 1, let sealed = try? AES.GCM.SealedBox(combined: envelope.dropFirst()) else {
            throw SecureEnvelopeError.decryptionFailed
        }
        do {
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureEnvelopeError.decryptionFailed
        }
    }

    /// Opens a 1.2-era blob: raw combined bytes, no ring tag.
    static func openLegacy(_ combined: Data, using key: SymmetricKey) throws -> Data {
        guard let sealed = try? AES.GCM.SealedBox(combined: combined) else {
            throw SecureEnvelopeError.decryptionFailed
        }
        do {
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureEnvelopeError.decryptionFailed
        }
    }
}

enum SecureEnvelopeError: LocalizedError {
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "加密失败。"
        case .decryptionFailed:
            return "解密失败。数据可能已损坏。"
        }
    }
}
