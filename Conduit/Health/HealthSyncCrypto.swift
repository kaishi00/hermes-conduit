//
//  HealthSyncCrypto.swift
//  Conduit
//
//  End-to-end sealing of health uploads. The phone and the Hermes profile
//  agree a key once by X25519 (POST /health/key): only public keys cross
//  the wire, so someone who only watched that exchange, even on a plain-http
//  LAN dashboard, can't open later uploads. The host key isn't otherwise
//  authenticated: over plain http, someone able to alter that one answer
//  could put in their own key, so HTTPS or a private tunnel still matters. Every batch is sealed
//  with ChaCha20-Poly1305 under an HKDF-SHA256 key; the associated data
//  binds it to the key id, the device and the batch id. Must match
//  health_store.py in hermes-conduit-notifier; both check the vector in
//  its tests/health_vector.json.
//
//  A live voice call reads the user's data back with the same agreement
//  (POST /voice-tools/call): one more key per direction, so the host
//  answers only the phone that holds them.
//

import CryptoKit
import Foundation

enum HealthSyncCrypto {
    static let salt = Data("conduit-health-v1".utf8)
    static let ingestInfo = Data("conduit-health-v1 ingest device-to-host".utf8)
    static let aadTag = "conduit-health/1"
    static let voiceRequestInfo = Data("conduit-health-v1 voice device-to-host".utf8)
    static let voiceAnswerInfo = Data("conduit-health-v1 voice host-to-device".utf8)

    enum Failure: Error, Equatable {
        case malformedHostKey
        case keyIDMismatch
        /// The key predates voice reads; the next sync sets up a new one.
        case noVoiceKey
    }

    /// The agreed key, kept in the Keychain until sharing is turned off or
    /// the host forgets it.
    struct SessionKey: Codable, Equatable {
        var kid: String
        var key: Data
        /// Voice reads, one key per direction. Nil in a key agreed before
        /// voice reads existed.
        var voiceRequestKey: Data?
        var voiceAnswerKey: Data?

        var readsByVoice: Bool { voiceRequestKey != nil && voiceAnswerKey != nil }
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
        func derived(_ purpose: Data) -> Data {
            let info = purpose + Data("\n\(deviceID)\n".utf8) + devicePublic + hostPublic
            let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
            return symmetric.withUnsafeBytes { Data($0) }
        }
        return SessionKey(kid: kid, key: derived(ingestInfo),
                          voiceRequestKey: derived(voiceRequestInfo), voiceAnswerKey: derived(voiceAnswerInfo))
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

    // MARK: Voice reads

    /// `direction` is "request" or "answer".
    static func voiceAAD(direction: String, tool: String, kid: String, deviceID: String, callID: String) -> Data {
        VoiceReadSeal.aad(tag: aadTag, direction: direction, tool: tool, kid: kid, deviceID: deviceID, callID: callID)
    }

    /// The `/voice-tools/call` body: `plaintext` is the request's JSON
    /// (`call_id`, `args`, `provider`).
    static func voiceRequest(
        tool: String,
        plaintext: Data,
        key: SessionKey,
        deviceID: String,
        callID: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        guard let requestKey = key.voiceRequestKey else { throw Failure.noVoiceKey }
        return try VoiceReadSeal.request(tag: aadTag, tool: tool, plaintext: plaintext, requestKey: requestKey,
                                         kid: key.kid, deviceID: deviceID, callID: callID, nonce: nonce)
    }

    /// The opened answer's `result`, checked against the tool and call it
    /// answers.
    static func openVoiceAnswer(_ response: [String: Any], tool: String, key: SessionKey,
                                deviceID: String, callID: String) throws -> Any {
        guard let answerKey = key.voiceAnswerKey else { throw Failure.noVoiceKey }
        return try VoiceReadSeal.openAnswer(response, tag: aadTag, tool: tool, answerKey: answerKey,
                                            kid: key.kid, deviceID: deviceID, callID: callID)
    }
}
