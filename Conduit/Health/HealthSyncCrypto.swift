//
//  HealthSyncCrypto.swift
//  Conduit
//
//  End-to-end sealing of health uploads. The phone and the Hermes profile
//  agree a key once by X25519 (POST /health/key): only public keys cross
//  the wire, so someone who watched that exchange, even on a plain-http
//  LAN dashboard, still can't open later uploads. Every batch is sealed
//  with ChaCha20-Poly1305 under an HKDF-SHA256 key; the associated data
//  binds it to the key id, the device and the batch id. Must match
//  health_store.py in hermes-conduit-notifier; both check the vector in
//  its tests/health_vector.json.
//

import CryptoKit
import Foundation

enum HealthSyncCrypto {
    static let salt = Data("conduit-health-v1".utf8)
    static let ingestInfo = Data("conduit-health-v1 ingest device-to-host".utf8)
    static let aadTag = "conduit-health/1"

    enum Failure: Error, Equatable {
        case malformedHostKey
        case keyIDMismatch
    }

    /// The agreed key, kept in the Keychain until sharing is turned off or
    /// the host forgets it.
    struct SessionKey: Codable, Equatable {
        var kid: String
        var key: Data
    }

    static func keyID(devicePublic: Data, hostPublic: Data) -> String {
        let digest = SHA256.hash(data: Data("conduit-health-kid\n".utf8) + devicePublic + hostPublic)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// The key both sides derive once the host answers `/health/key`.
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
        let info = ingestInfo + Data("\n\(deviceID)\n".utf8) + devicePublic + hostPublic
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        return SessionKey(kid: kid, key: symmetric.withUnsafeBytes { Data($0) })
    }

    static func aad(kid: String, deviceID: String, batchID: String) -> Data {
        Data([aadTag, "ingest", "kid=\(kid)", "dev=\(deviceID)", "batch=\(batchID)"].joined(separator: "\n").utf8)
    }

    /// The `/health/ingest` body for a batch's JSON.
    static func envelope(
        plaintext: Data,
        key: SessionKey,
        deviceID: String,
        batchID: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key.key),
            nonce: nonce,
            authenticating: aad(kid: key.kid, deviceID: deviceID, batchID: batchID)
        )
        return [
            "v": 1,
            "device_id": deviceID,
            "kid": key.kid,
            "batch_id": batchID,
            "nonce": NotificationE2E.base64URL(Data(box.nonce)),
            "ct": NotificationE2E.base64URL(box.ciphertext + box.tag),
        ]
    }
}
