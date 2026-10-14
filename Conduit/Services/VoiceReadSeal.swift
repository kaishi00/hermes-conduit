//
//  VoiceReadSeal.swift
//  Conduit
//
//  The sealing a live voice call's read of the host uses (POST
//  /voice-tools/call), shared by health and location: one key per
//  direction from the data's own agreement, and associated data that
//  binds each request and answer to its tool, key, device and call. Only
//  the tag differs ("conduit-health/1", "conduit-location/1"). Must match
//  the notifier's health_store.py and location_store.py; both are checked
//  against the "voice" vectors in its tests.
//

import CryptoKit
import Foundation

enum VoiceReadSeal {
    enum Failure: Error, Equatable {
        case malformedAnswer
        /// The tool name isn't a plain identifier, so it can't go into the
        /// associated data.
        case badToolName
    }

    /// `direction` is "request" or "answer". `tool` must be a plain
    /// identifier (`VoiceHostTool.isToolName`): `request` and `openAnswer`
    /// refuse any other.
    static func aad(tag: String, direction: String, tool: String, kid: String, deviceID: String, callID: String) -> Data {
        Data([tag, "voice-\(direction)", "tool=\(tool)", "kid=\(kid)", "dev=\(deviceID)", "call=\(callID)"]
            .joined(separator: "\n").utf8)
    }

    /// A fresh id for one voice read; the answer is bound to it.
    static func newCallID() -> String {
        NotificationE2E.base64URL(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
    }

    /// The `/voice-tools/call` body: `plaintext` is the request's JSON
    /// (`call_id`, `args`, `provider`).
    static func request(
        tag: String,
        tool: String,
        plaintext: Data,
        requestKey: Data,
        kid: String,
        deviceID: String,
        callID: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        guard VoiceHostTool.isToolName(tool) else { throw Failure.badToolName }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: requestKey),
            nonce: nonce,
            authenticating: aad(tag: tag, direction: "request", tool: tool, kid: kid, deviceID: deviceID, callID: callID)
        )
        return [
            "v": 1,
            "tool": tool,
            "device_id": deviceID,
            "kid": kid,
            "call_id": callID,
            "nonce": NotificationE2E.base64URL(Data(box.nonce)),
            "ct": NotificationE2E.base64URL(box.ciphertext + box.tag),
        ]
    }

    /// The opened answer's `result`, checked against the tool and call it
    /// answers.
    static func openAnswer(
        _ response: [String: Any],
        tag: String,
        tool: String,
        answerKey: Data,
        kid: String,
        deviceID: String,
        callID: String
    ) throws -> Any {
        guard VoiceHostTool.isToolName(tool) else { throw Failure.badToolName }
        guard let nonceText = response["nonce"] as? String, let nonceData = NotificationE2E.base64URLDecoded(nonceText),
              let sealedText = response["ct"] as? String, let sealed = NotificationE2E.base64URLDecoded(sealedText),
              sealed.count >= 16, nonceData.count == 12 else {
            throw Failure.malformedAnswer
        }
        let box = try ChaChaPoly.SealedBox(combined: nonceData + sealed)
        let plaintext = try ChaChaPoly.open(
            box,
            using: SymmetricKey(data: answerKey),
            authenticating: aad(tag: tag, direction: "answer", tool: tool, kid: kid, deviceID: deviceID, callID: callID)
        )
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              object["call_id"] as? String == callID, let result = object["result"] else {
            throw Failure.malformedAnswer
        }
        return result
    }
}
