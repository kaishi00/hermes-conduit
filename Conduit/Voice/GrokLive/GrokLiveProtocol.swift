//
//  GrokLiveProtocol.swift
//  Conduit
//
//  Wire format for xAI's realtime voice API (Grok Live), whose events
//  follow OpenAI's Realtime API: session.update, input_audio_buffer.append,
//  conversation.item.create, response.create out; audio and transcript
//  deltas, function calls and response.done back. Server events decode into
//  the same events Gemini Live's do, so one conversation controller drives
//  both. Pure encode/decode, so every message shape is unit-testable.
//

import Foundation

enum GrokLiveProtocol {
    static let defaultModel = "grok-voice-latest"
    /// What the session declares and xAI's own voice clients send. The
    /// microphone stream is Gemini Live's 16 kHz capture
    /// (`GeminiLiveProtocol.inputSampleRate`), upsampled to it.
    static let inputSampleRate: Double = 24_000
    static let outputSampleRate: Double = 24_000
    /// The transcription model xAI's own voice clients use.
    static let transcriptionModel = "grok-transcribe"

    // MARK: Client → server

    /// The session's configuration: server-side turn detection (the user's
    /// speech interrupts the model), PCM audio both ways, the instructions,
    /// the voice and the function tools.
    static func sessionUpdate(
        instructions: String,
        functions: [GeminiLiveProtocol.FunctionDeclaration],
        voice: String?
    ) -> [String: Any] {
        var session: [String: Any] = [
            "instructions": instructions,
            // Fast replies: this is a conversation, the work goes to Hermes.
            "reasoning": ["effort": "none"],
            "turn_detection": [
                "type": "server_vad",
                "silence_duration_ms": 700,
                "prefix_padding_ms": 300,
            ] as [String: Any],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": Int(inputSampleRate)],
                    "transcription": ["model": transcriptionModel],
                ] as [String: Any],
                "output": [
                    "format": ["type": "audio/pcm", "rate": Int(outputSampleRate)],
                ],
            ],
            "tools": functions.map(functionTool),
            "tool_choice": "auto",
        ]
        if let voice, !voice.isEmpty { session["voice"] = voice }
        return ["type": "session.update", "session": session]
    }

    /// A Gemini declaration as a Realtime function tool: JSON Schema types
    /// are lowercase where Gemini's are uppercase.
    static func functionTool(_ declaration: GeminiLiveProtocol.FunctionDeclaration) -> [String: Any] {
        [
            "type": "function",
            "name": declaration.name,
            "description": declaration.description,
            "parameters": jsonSchema(declaration.parameters),
        ]
    }

    static func jsonSchema(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var converted: [String: Any] = [:]
            for (key, inner) in object {
                if key == "type", let type = inner as? String {
                    converted[key] = type.lowercased()
                } else {
                    converted[key] = jsonSchema(inner)
                }
            }
            return converted
        }
        if let array = value as? [Any] { return array.map(jsonSchema) }
        return value
    }

    /// The frames that carry one client message, in order. A message the
    /// model should answer ends with `response.create`; the session holds
    /// that back while a response is still running.
    static func frames(for message: LiveVoiceClientMessage) -> (frames: [[String: Any]], wantsResponse: Bool) {
        switch message {
        case .audio(let pcm16):
            let audio = upsampledForInput(pcm16).base64EncodedString()
            return ([["type": "input_audio_buffer.append", "audio": audio]], false)
        case .audioStreamEnd:
            // Server turn detection ends a turn on silence, and a muted
            // microphone sends none: a short silence closes the turn now.
            return ([["type": "input_audio_buffer.append", "audio": silence.base64EncodedString()]], false)
        case .textTurn(let text):
            return ([[
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": text]],
                ] as [String: Any],
            ]], true)
        case .toolResponse(let id, _, let result, let scheduling):
            let output = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let item: [String: Any] = [
                "type": "conversation.item.create",
                "item": ["type": "function_call_output", "call_id": id, "output": output],
            ]
            // A silent answer is absorbed without the model speaking.
            return ([item], scheduling != .silent)
        }
    }

    static let responseCreate: [String: Any] = ["type": "response.create"]

    /// 0.8 s of PCM16 silence at the input rate: longer than the turn
    /// detector's silence window.
    static let silence = Data(count: Int(inputSampleRate * 0.8) * 2)

    /// 16 kHz capture as 24 kHz PCM16 (little-endian), by linear
    /// interpolation: three output samples for every two captured.
    static func upsampledForInput(_ pcm16: Data) -> Data {
        let bytes = [UInt8](pcm16)
        let count = bytes.count / 2
        guard count > 0 else { return Data() }
        let samples = (0..<count).map { Int16(bitPattern: UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8) }
        let outputCount = count * 3 / 2
        var output = Data(capacity: outputCount * 2)
        for index in 0..<outputCount {
            // Position in the captured stream: index * 2/3 (24 kHz from 16).
            let numerator = index * 2
            let lower = numerator / 3
            let fraction = Double(numerator % 3) / 3
            let a = Double(samples[lower])
            let b = Double(samples[min(lower + 1, count - 1)])
            let value = UInt16(bitPattern: Int16(clamping: Int((a + (b - a) * fraction).rounded())))
            output.append(UInt8(value & 0xFF))
            output.append(UInt8(value >> 8))
        }
        return output
    }

    static func encode(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Server → client

    /// What one server frame means to the session, beyond the shared
    /// conversation events.
    enum ServerFrame: Equatable {
        /// The session.update was applied: the session is ready.
        case sessionUpdated
        case responseStarted
        /// A response ended (`turnComplete` is also delivered).
        case responseDone
        case error(String)
        /// A response's whole spoken transcript; only used when no deltas
        /// carried it.
        case outputTranscriptDone(String)
        case event(GeminiLiveProtocol.ServerEvent)
    }

    /// One frame can carry at most one event; unknown types are ignored.
    static func decode(_ data: Data) -> [ServerFrame] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "session.updated":
            return [.sessionUpdated]
        case "error":
            let error = object["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? (object["message"] as? String) ?? (error?["code"] as? String) ?? ""
            return [.error(message)]
        case "response.created":
            return [.responseStarted]
        case "response.done":
            return [.responseDone, .event(.turnComplete)]
        case "input_audio_buffer.speech_started":
            // The user started speaking: the server cancels the response,
            // and playback has to stop now.
            return [.event(.interrupted)]
        case "conversation.item.input_audio_transcription.completed":
            guard let text = object["transcript"] as? String, !text.isEmpty else { return [] }
            return [.event(.inputTranscription(text))]
        case "response.output_audio.delta", "response.audio.delta":
            guard let base64 = object["delta"] as? String, let pcm = Data(base64Encoded: base64), !pcm.isEmpty else { return [] }
            return [.event(.audio(pcm, sampleRate: outputSampleRate))]
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let text = object["delta"] as? String, !text.isEmpty else { return [] }
            return [.event(.outputTranscription(text))]
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            guard let text = object["transcript"] as? String, !text.isEmpty else { return [] }
            return [.outputTranscriptDone(text)]
        case "response.function_call_arguments.done":
            guard let call = functionCall(object) else { return [] }
            return [.event(.toolCall([call]))]
        default:
            return []
        }
    }

    /// `arguments` is a JSON string; Conduit's tools take string values.
    static func functionCall(_ object: [String: Any]) -> GeminiLiveProtocol.FunctionCall? {
        guard let id = object["call_id"] as? String, !id.isEmpty,
              let name = object["name"] as? String, !name.isEmpty else { return nil }
        var arguments: [String: String] = [:]
        if let raw = object["arguments"] as? String,
           let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            for (key, value) in parsed {
                if let string = value as? String {
                    arguments[key] = string
                } else if let number = value as? NSNumber {
                    arguments[key] = number.stringValue
                }
            }
        }
        return GeminiLiveProtocol.FunctionCall(id: id, name: name, arguments: arguments)
    }
}
