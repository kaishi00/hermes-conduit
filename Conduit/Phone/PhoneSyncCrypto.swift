//
//  PhoneSyncCrypto.swift
//  Conduit
//
//  End-to-end sealing for calendar, reminders, Focus and phone status, the
//  same scheme as health (HealthSyncCrypto) with its own labels and key, so
//  either can be on alone and deleting one never touches the other. One
//  X25519 agreement (POST /phone/key) gives three keys by HKDF purpose:
//  uploads (device to host), and each direction of an exchange (the phone
//  asks for pending changes and gets them back sealed). Must match
//  phone_store.py in hermes-conduit-notifier; both check the vector in its
//  tests/phone_vector.json.
//

import CryptoKit
import Foundation

enum PhoneSyncCrypto {
    static let salt = Data("conduit-phone-v1".utf8)
    static let ingestInfo = Data("conduit-phone-v1 ingest device-to-host".utf8)
    static let exchangeRequestInfo = Data("conduit-phone-v1 exchange device-to-host".utf8)
    static let exchangeAnswerInfo = Data("conduit-phone-v1 exchange host-to-device".utf8)
    static let aadTag = "conduit-phone/1"

    enum Failure: Error, Equatable {
        case malformedHostKey
        case keyIDMismatch
        case malformedAnswer
    }

    /// The three keys from one agreement, kept in the Keychain until sharing
    /// is turned off or the host forgets them.
    struct SessionKey: Codable, Equatable {
        var kid: String
        var ingest: Data
        var request: Data
        var answer: Data
    }

    static func keyID(devicePublic: Data, hostPublic: Data) -> String {
        let digest = SHA256.hash(data: Data("conduit-phone-kid\n".utf8) + devicePublic + hostPublic)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// The keys both sides derive once the host answers `/phone/key`.
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
        func derive(_ purpose: Data) -> Data {
            let info = purpose + Data("\n\(deviceID)\n".utf8) + devicePublic + hostPublic
            let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
            return key.withUnsafeBytes { Data($0) }
        }
        return SessionKey(kid: kid, ingest: derive(ingestInfo), request: derive(exchangeRequestInfo),
                          answer: derive(exchangeAnswerInfo))
    }

    static func ingestAAD(kid: String, deviceID: String, batchID: String) -> Data {
        Data([aadTag, "ingest", "kid=\(kid)", "dev=\(deviceID)", "batch=\(batchID)"].joined(separator: "\n").utf8)
    }

    /// `direction` is "request" or "answer".
    static func exchangeAAD(direction: String, op: String, kid: String, deviceID: String, callID: String) -> Data {
        Data([aadTag, "exchange-\(direction)", "op=\(op)", "kid=\(kid)", "dev=\(deviceID)", "call=\(callID)"]
            .joined(separator: "\n").utf8)
    }

    private static func seal(_ plaintext: Data, key: Data, aad: Data, nonce: ChaChaPoly.Nonce) throws -> (nonce: String, ct: String) {
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad)
        return (NotificationE2E.base64URL(Data(box.nonce)), NotificationE2E.base64URL(box.ciphertext + box.tag))
    }

    /// The `/phone/ingest` body for a batch's JSON.
    static func envelope(
        plaintext: Data,
        key: SessionKey,
        deviceID: String,
        batchID: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        let sealed = try seal(plaintext, key: key.ingest,
                              aad: ingestAAD(kid: key.kid, deviceID: deviceID, batchID: batchID), nonce: nonce)
        return ["v": 1, "device_id": deviceID, "kid": key.kid, "batch_id": batchID, "nonce": sealed.nonce, "ct": sealed.ct]
    }

    /// The `/phone/exchange` body for a request's JSON.
    static func exchangeEnvelope(
        plaintext: Data,
        op: String,
        key: SessionKey,
        deviceID: String,
        callID: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        let aad = exchangeAAD(direction: "request", op: op, kid: key.kid, deviceID: deviceID, callID: callID)
        let sealed = try seal(plaintext, key: key.request, aad: aad, nonce: nonce)
        return ["v": 1, "device_id": deviceID, "kid": key.kid, "call_id": callID, "op": op,
                "nonce": sealed.nonce, "ct": sealed.ct]
    }

    /// Opens the host's sealed answer to an exchange.
    static func openAnswer(_ answer: [String: Any], op: String, key: SessionKey, deviceID: String, callID: String) throws -> Data {
        guard let nonceText = answer["nonce"] as? String, let ctText = answer["ct"] as? String,
              let nonceData = NotificationE2E.base64URLDecoded(nonceText), nonceData.count == 12,
              let ct = NotificationE2E.base64URLDecoded(ctText), ct.count >= 16 else {
            throw Failure.malformedAnswer
        }
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceData), ciphertext: ct.dropLast(16), tag: ct.suffix(16))
        let aad = exchangeAAD(direction: "answer", op: op, kid: key.kid, deviceID: deviceID, callID: callID)
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key.answer), authenticating: aad)
    }
}
