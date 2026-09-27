//
//  GeminiLiveProtocol.swift
//  Conduit
//
//  Wire format for the Gemini Live API (v1beta BidiGenerateContent) as used
//  by Conduit's Gemini Live voice mode. Pure encode/decode: no sockets, no
//  audio, so every message shape is unit-testable.
//

import Foundation

enum GeminiLiveProtocol {
    static let model = "models/gemini-3.8-live"
    static let inputSampleRate: Double = 16_000
    static let outputSampleRate: Double = 24_000
    static let inputMimeType = "audio/pcm;rate=16000"

    // MARK: Client → server

    /// Function scheduling for a response to a NON_BLOCKING call.
    enum Scheduling: String {
        /// Tell the user right away, interrupting what the model is saying.
        case interrupt = "INTERRUPT"
        /// Wait until the model has finished what it is currently doing.
        case whenIdle = "WHEN_IDLE"
        /// Absorb silently; use later in the conversation.
        case silent = "SILENT"
    }

    enum FunctionBehavior: String {
        case blocking = "BLOCKING"
        case nonBlocking = "NON_BLOCKING"
    }

    struct FunctionDeclaration {
        let name: String
        let description: String
        /// OpenAPI-subset schema object for the arguments.
        let parameters: [String: Any]
        let behavior: FunctionBehavior

        var json: [String: Any] {
            [
                "name": name,
                "description": description,
                "parameters": parameters,
                "behavior": behavior.rawValue,
            ]
        }
    }

    /// `gemini-3.8-live` → `models/gemini-3.8-live`.
    static func qualifiedModel(_ model: String) -> String {
        model.hasPrefix("models/") ? model : "models/" + model
    }

    static func setupMessage(
        model: String = GeminiLiveProtocol.model,
        systemInstruction: String,
        functions: [FunctionDeclaration],
        googleSearch: Bool = true,
        resumptionHandle: String?
    ) -> [String: Any] {
        var tools: [[String: Any]] = [["functionDeclarations": functions.map(\.json)]]
        // Gemini's own Google Search answers quick lookups (weather, news,
        // facts) directly instead of sending them through a Hermes job.
        if googleSearch { tools.append(["googleSearch": [String: Any]()]) }
        var sessionResumption: [String: Any] = [:]
        if let resumptionHandle, !resumptionHandle.isEmpty {
            sessionResumption["handle"] = resumptionHandle
        }
        return [
            "setup": [
                "model": qualifiedModel(model),
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                ],
                "systemInstruction": [
                    "parts": [["text": systemInstruction]],
                ],
                "tools": tools,
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": false],
                    // The user's speech always interrupts the model: it must
                    // never talk over the user.
                    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                ],
                // An empty object still opts in: the server then sends
                // resumption handles to reconnect with after a GoAway.
                "sessionResumption": sessionResumption,
                "contextWindowCompression": [
                    "slidingWindow": [String: Any](),
                ],
                "inputAudioTranscription": [String: Any](),
                "outputAudioTranscription": [String: Any](),
            ] as [String: Any],
        ]
    }

    static func audioMessage(pcm16: Data) -> [String: Any] {
        [
            "realtimeInput": [
                "audio": [
                    "mimeType": inputMimeType,
                    "data": pcm16.base64EncodedString(),
                ],
            ],
        ]
    }

    /// Sent when the microphone is muted mid-utterance so the server does
    /// not wait for more audio before it ends the user's turn.
    static func audioStreamEndMessage() -> [String: Any] {
        ["realtimeInput": ["audioStreamEnd": true]]
    }

    /// A text turn from the client (used for background-job updates whose
    /// function call is no longer open).
    static func textTurnMessage(_ text: String) -> [String: Any] {
        [
            "clientContent": [
                "turns": [
                    ["role": "user", "parts": [["text": text]]],
                ],
                "turnComplete": true,
            ] as [String: Any],
        ]
    }

    static func toolResponseMessage(
        id: String,
        name: String,
        result: [String: Any],
        scheduling: Scheduling?
    ) -> [String: Any] {
        var response = result
        if let scheduling { response["scheduling"] = scheduling.rawValue }
        return [
            "toolResponse": [
                "functionResponses": [
                    ["id": id, "name": name, "response": response] as [String: Any],
                ],
            ],
        ]
    }

    static func encode(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Server → client

    struct FunctionCall: Equatable {
        let id: String
        let name: String
        /// String-valued arguments only: every Conduit tool takes strings.
        let arguments: [String: String]
    }

    enum ServerEvent: Equatable {
        case setupComplete
        /// Model speech: 16-bit PCM at `sampleRate`.
        case audio(Data, sampleRate: Double)
        case inputTranscription(String)
        case outputTranscription(String)
        /// The user started speaking: stop playback now.
        case interrupted
        case turnComplete
        case toolCall([FunctionCall])
        case toolCallCancellation([String])
        case goAway(timeLeft: TimeInterval?)
        case resumptionUpdate(handle: String?, resumable: Bool)
    }

    /// One server frame can carry several events (e.g. audio plus a
    /// transcription plus turnComplete). Unknown fields are ignored.
    static func decode(_ data: Data) -> [ServerEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var events: [ServerEvent] = []
        if object["setupComplete"] != nil {
            events.append(.setupComplete)
        }
        if let content = object["serverContent"] as? [String: Any] {
            if let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
                for part in parts {
                    guard let inline = part["inlineData"] as? [String: Any],
                          let mime = inline["mimeType"] as? String,
                          mime.hasPrefix("audio/pcm"),
                          let base64 = inline["data"] as? String,
                          let pcm = Data(base64Encoded: base64) else { continue }
                    events.append(.audio(pcm, sampleRate: sampleRate(fromMimeType: mime) ?? outputSampleRate))
                }
            }
            if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                events.append(.inputTranscription(text))
            }
            if let text = (content["outputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                events.append(.outputTranscription(text))
            }
            if content["interrupted"] as? Bool == true {
                events.append(.interrupted)
            }
            if content["turnComplete"] as? Bool == true {
                events.append(.turnComplete)
            }
        }
        if let calls = (object["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] {
            let parsed = calls.compactMap { call -> FunctionCall? in
                guard let id = call["id"] as? String, let name = call["name"] as? String else { return nil }
                let rawArguments = call["args"] as? [String: Any] ?? [:]
                var arguments: [String: String] = [:]
                for (key, value) in rawArguments {
                    if let string = value as? String {
                        arguments[key] = string
                    } else if let number = value as? NSNumber {
                        arguments[key] = number.stringValue
                    }
                }
                return FunctionCall(id: id, name: name, arguments: arguments)
            }
            if !parsed.isEmpty { events.append(.toolCall(parsed)) }
        }
        if let ids = (object["toolCallCancellation"] as? [String: Any])?["ids"] as? [String], !ids.isEmpty {
            events.append(.toolCallCancellation(ids))
        }
        if let goAway = object["goAway"] as? [String: Any] {
            events.append(.goAway(timeLeft: duration(goAway["timeLeft"])))
        }
        if let update = object["sessionResumptionUpdate"] as? [String: Any] {
            let handle = (update["newHandle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            events.append(.resumptionUpdate(handle: handle, resumable: update["resumable"] as? Bool ?? false))
        }
        return events
    }

    /// `audio/pcm;rate=24000` → 24000.
    static func sampleRate(fromMimeType mime: String) -> Double? {
        for parameter in mime.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "rate",
                  let rate = Double(pair[1].trimmingCharacters(in: .whitespaces)),
                  rate > 0 else { continue }
            return rate
        }
        return nil
    }

    /// Protobuf Duration in JSON: `"10s"`/`"1.5s"`, or `{seconds, nanos}`.
    static func duration(_ value: Any?) -> TimeInterval? {
        if let string = value as? String {
            guard string.hasSuffix("s"), let seconds = Double(string.dropLast()) else { return nil }
            return seconds
        }
        if let object = value as? [String: Any] {
            let seconds = (object["seconds"] as? NSNumber)?.doubleValue
                ?? (object["seconds"] as? String).flatMap(Double.init) ?? 0
            let nanos = (object["nanos"] as? NSNumber)?.doubleValue ?? 0
            return seconds + nanos / 1_000_000_000
        }
        return nil
    }
}
