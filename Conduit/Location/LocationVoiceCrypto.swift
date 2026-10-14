//
//  LocationVoiceCrypto.swift
//  Conduit
//
//  A live voice call's sealed read of the shared location (POST
//  /voice-tools/call, tool conduit_location), with the location key's
//  voice keys. Must match the notifier's location_store.py; both check the
//  "voice" vector in its tests/location_vector.json.
//

import CryptoKit
import Foundation

extension LocationCrypto {
    enum VoiceFailure: Error, Equatable {
        /// The key predates voice reads; the next send sets up a new one.
        case noVoiceKey
    }

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
        callID: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        guard let requestKey = key.voiceRequestKey else { throw VoiceFailure.noVoiceKey }
        return try VoiceReadSeal.request(tag: aadTag, tool: tool, plaintext: plaintext, requestKey: requestKey,
                                         kid: key.kid, deviceID: key.deviceID, callID: callID, nonce: nonce)
    }

    /// The opened answer's `result`, checked against the tool and call it
    /// answers.
    static func openVoiceAnswer(_ response: [String: Any], tool: String, key: SessionKey, callID: String) throws -> Any {
        guard let answerKey = key.voiceAnswerKey else { throw VoiceFailure.noVoiceKey }
        return try VoiceReadSeal.openAnswer(response, tag: aadTag, tool: tool, answerKey: answerKey,
                                            kid: key.kid, deviceID: key.deviceID, callID: callID)
    }
}
