//
//  SecureEnvelopeTests.swift
//  Face IDTests
//
//  The on-disk envelope format (1.3): a one-byte ring tag in front of an
//  AES-GCM combined blob, plus the tagless 1.2 layout the migration still
//  has to open. Pure data in, pure data out — no keychain, no files.
//

import CryptoKit
import Foundation
import Testing

@testable import FaceID

@Suite("SecureEnvelope")
struct SecureEnvelopeTests {

    private let key = SymmetricKey(size: .bits256)
    private let payload = Data("correct horse battery staple".utf8)

    @Test("Device-ring round trip returns the original plaintext")
    func deviceRoundTrip() throws {
        let sealed = try SecureEnvelope.seal(payload, using: key, ring: .device)
        #expect(try SecureEnvelope.open(sealed, using: key) == payload)
    }

    @Test("A sealed blob states its ring in the first byte")
    func ringTag() throws {
        let sealed = try SecureEnvelope.seal(payload, using: key, ring: .device)
        #expect(SecureEnvelope.ring(of: sealed) == .device)
    }

    @Test("Session-ring blobs are labelled too, so a reader can refuse them")
    func sessionRingTag() throws {
        let sealed = try SecureEnvelope.seal(payload, using: key, ring: .session)
        #expect(SecureEnvelope.ring(of: sealed) == .session)
    }

    @Test("Opening with the wrong key throws instead of returning bytes")
    func wrongKey() throws {
        let sealed = try SecureEnvelope.seal(payload, using: key, ring: .device)
        let other = SymmetricKey(size: .bits256)
        #expect(throws: SecureEnvelopeError.self) {
            _ = try SecureEnvelope.open(sealed, using: other)
        }
    }

    @Test("A truncated blob is reported as corruption, not a crash")
    func truncated() {
        #expect(throws: SecureEnvelopeError.self) {
            _ = try SecureEnvelope.open(Data([SecureEnvelope.Ring.device.rawValue]), using: key)
        }
        #expect(throws: SecureEnvelopeError.self) {
            _ = try SecureEnvelope.open(Data(), using: key)
        }
    }

    @Test("Legacy (untagged) blobs still open with the session key")
    func legacyRoundTrip() throws {
        let combined = try AES.GCM.seal(payload, using: key).combined
        let legacy = try #require(combined)
        #expect(try SecureEnvelope.openLegacy(legacy, using: key) == payload)
    }

    @Test("A tagged v2 blob is not mistaken for a legacy one")
    func taggedIsNotLegacy() throws {
        let sealed = try SecureEnvelope.seal(payload, using: key, ring: .device)
        // The ring byte lands where the nonce should start, so the legacy
        // parser sees a malformed box — or, at best, an authentication
        // failure. Either way it must not hand back plaintext.
        #expect(throws: (any Error).self) {
            _ = try SecureEnvelope.openLegacy(sealed, using: key)
        }
    }

    @Test("An unknown tag byte is not a ring")
    func unknownTag() {
        #expect(SecureEnvelope.ring(of: Data([0x00, 0x01])) == nil)
    }
}
