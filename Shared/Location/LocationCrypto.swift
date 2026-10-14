//
//  LocationCrypto.swift
//  Conduit
//
//  End-to-end sealing of location uploads, the health scheme with its own
//  labels (designs/location-v1-contract.md section 1). The phone and the
//  Hermes profile agree a key by X25519 (POST /location/key); every batch
//  is sealed with ChaCha20-Poly1305 under an HKDF-SHA256 key, and the
//  associated data binds it to the key id, the device and the batch id.
//  Location has its own key, so health and location can each be on, off or
//  wiped without the other. Must match the notifier's location store; both
//  check the vector in its tests/location_vector.json.
//
//  A live voice call reads the location back with the same agreement
//  (POST /voice-tools/call): one more key per direction, so the host
//  answers only the phone that holds them (LocationVoiceCrypto.swift).
//

import CryptoKit
import Foundation

enum LocationCrypto {
    static let salt = Data("conduit-location-v1".utf8)
    static let ingestInfo = Data("conduit-location-v1 ingest device-to-host".utf8)
    static let voiceRequestInfo = Data("conduit-location-v1 voice device-to-host".utf8)
    static let voiceAnswerInfo = Data("conduit-location-v1 voice host-to-device".utf8)
    static let kidLabel = Data("conduit-location-kid\n".utf8)
    static let aadTag = "conduit-location/1"

    enum Failure: Error, Equatable {
        case malformedHostKey
        case keyIDMismatch
    }

    /// The agreed key, kept in the App Group Keychain so the Location Push
    /// extension can seal its answer too.
    struct SessionKey: Codable, Equatable {
        var kid: String
        var key: Data
        /// The device id the key was agreed for.
        var deviceID: String
        /// Voice reads, one key per direction. Nil in a key agreed before
        /// voice reads existed.
        var voiceRequestKey: Data?
        var voiceAnswerKey: Data?

        var readsByVoice: Bool { voiceRequestKey != nil && voiceAnswerKey != nil }
    }

    static func keyID(devicePublic: Data, hostPublic: Data) -> String {
        let digest = SHA256.hash(data: kidLabel + devicePublic + hostPublic)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// The key both sides derive once the host answers `/location/key`.
    static func agree(
        devicePrivate: Curve25519.KeyAgreement.PrivateKey,
        deviceID: String,
        hostPublicKey: String,
        kid: String
    ) throws -> SessionKey {
        guard let hostPublic = NotificationE2E.base64URLDecoded(hostPublicKey), hostPublic.count == 32,
              let host = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPublic) else {
            throw Failure.malformedHostKey
        }
        let devicePublic = devicePrivate.publicKey.rawRepresentation
        // The host derives the id the same way: a mismatch means the answer
        // isn't for this key.
        guard keyID(devicePublic: devicePublic, hostPublic: hostPublic) == kid else { throw Failure.keyIDMismatch }
        let shared = try devicePrivate.sharedSecretFromKeyAgreement(with: host)
        func derived(_ purpose: Data) -> Data {
            let info = purpose + Data("\n\(deviceID)\n".utf8) + devicePublic + hostPublic
            let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
            return symmetric.withUnsafeBytes { Data($0) }
        }
        return SessionKey(kid: kid, key: derived(ingestInfo), deviceID: deviceID,
                          voiceRequestKey: derived(voiceRequestInfo), voiceAnswerKey: derived(voiceAnswerInfo))
    }

    static func aad(kid: String, deviceID: String, batchID: String) -> Data {
        Data([aadTag, "ingest", "kid=\(kid)", "dev=\(deviceID)", "batch=\(batchID)"].joined(separator: "\n").utf8)
    }

    /// The `/location/ingest` body for a batch's JSON.
    static func envelope(
        plaintext: Data,
        key: SessionKey,
        batchID: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key.key),
            nonce: nonce,
            authenticating: aad(kid: key.kid, deviceID: key.deviceID, batchID: batchID)
        )
        return [
            "v": 1,
            "device_id": key.deviceID,
            "kid": key.kid,
            "batch_id": batchID,
            "nonce": NotificationE2E.base64URL(Data(box.nonce)),
            "ct": NotificationE2E.base64URL(box.ciphertext + box.tag),
        ]
    }
}
