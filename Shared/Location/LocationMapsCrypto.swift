//
//  LocationMapsCrypto.swift
//  Conduit
//
//  The sealing of a maps request the host asks this iPhone to answer
//  (designs/maps-v1-contract.md section 2), with the location key's maps
//  keys: the host seals the request (GET /location/maps/{id}), the phone
//  seals its answer (POST /location/maps/{id}). The associated data binds
//  each to its key, device and request id. Must match the notifier's
//  location store; both check the "maps" vector.
//

import CryptoKit
import Foundation

extension LocationCrypto {
    enum MapsFailure: Error, Equatable {
        /// The key predates maps; the next send sets up a new one.
        case noMapsKey
        case malformedRequest
    }

    /// `direction` is "maps-request" or "maps-answer".
    static func mapsAAD(direction: String, kid: String, deviceID: String, id: String) -> Data {
        Data([aadTag, direction, "kid=\(kid)", "dev=\(deviceID)", "id=\(id)"].joined(separator: "\n").utf8)
    }

    /// The request's JSON object, from the host's `{ok, v, nonce, ct}`.
    static func openMapsRequest(_ response: [String: Any], key: SessionKey, id: String) throws -> [String: Any] {
        guard let requestKey = key.mapsRequestKey else { throw MapsFailure.noMapsKey }
        guard let nonceText = response["nonce"] as? String, let nonceData = NotificationE2E.base64URLDecoded(nonceText),
              let sealedText = response["ct"] as? String, let sealed = NotificationE2E.base64URLDecoded(sealedText),
              sealed.count >= 16, nonceData.count == 12 else {
            throw MapsFailure.malformedRequest
        }
        let box = try ChaChaPoly.SealedBox(combined: nonceData + sealed)
        let plaintext = try ChaChaPoly.open(
            box,
            using: SymmetricKey(data: requestKey),
            authenticating: mapsAAD(direction: "maps-request", kid: key.kid, deviceID: key.deviceID, id: id)
        )
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw MapsFailure.malformedRequest
        }
        return object
    }

    /// The `POST /location/maps/{id}` body for the answer's JSON.
    static func mapsAnswer(
        plaintext: Data,
        key: SessionKey,
        id: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        guard let answerKey = key.mapsAnswerKey else { throw MapsFailure.noMapsKey }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: answerKey),
            nonce: nonce,
            authenticating: mapsAAD(direction: "maps-answer", kid: key.kid, deviceID: key.deviceID, id: id)
        )
        return [
            "v": 1,
            "device_id": key.deviceID,
            "kid": key.kid,
            "nonce": NotificationE2E.base64URL(Data(box.nonce)),
            "ct": NotificationE2E.base64URL(box.ciphertext + box.tag),
        ]
    }
}
