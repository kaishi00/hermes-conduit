//
//  GrokLiveProtocol.swift
//  Conduit and the Conduit Watch app
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

    /// Added to Grok Live's instructions after the shared ones. On a user's
    /// calls Grok never called start_job for requests like "check my email",
    /// which Gemini and GPT-Live hand to Hermes. Written for
    /// the model and sent verbatim (the Voice settings preview shows it as
    /// sent, like the rest of the instructions), so not localized.
    static let delegationInstructions = "\nYou can't see the user's email, messages, calendar and schedule, to-dos, health or patient portals, bank or other accounts, files or systems, and web lookups can't reach them either; their Hermes agent can. Whenever the user asks you to check, read, find, send or do anything there (\"what's on my plate today?\" included), call start_job with their request instead of saying you can't. If they only ask whether you can see it, say Hermes can check it for them. Never answer it from guesses or a web lookup, and if start_job fails, tell them plainly. Public facts anyone could look up (weather, news, sports, stock prices) aren't Hermes work: look them up with web_search or x_search on this call, never with start_job."

    /// Grok answers start_job as soon as the job exists, so a claim can wait
    /// for it (the shared instructions, built with `acknowledgesOnceStarted`,
    /// say to acknowledge only once it returns). On a user's call Grok spoke a start_job call as text and said
    /// the work was queued when nothing ran.
    static let jobClaimInstructions = "\nOn this call start_job answers as soon as Hermes has the job. Never say anything was started, queued, sent or done unless a tool's result said so; if a tool returns an error or not_started, tell the user plainly. Tools are only ever function calls: never speak a tool call, its name or its arguments."

    /// What Grok's instructions add after the shared ones: the delegation
    /// and job-claim rules, and the clock.
    static func grokInstructions(now: Date, timeZone: TimeZone) -> String {
        delegationInstructions + jobClaimInstructions + clockInstructions(now: now, timeZone: timeZone)
    }

    /// The phone's clock at the start of the call, for Grok's instructions.
    /// Grok has no clock of its own: asked the time, it searched the web
    /// and answered with the wrong zone and hour. Written for the model, so
    /// formatted in a fixed English locale, not localized.
    static func clockInstructions(now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        return "\nWhen this call started it was \(formatter.string(from: now)) in the user's time zone (\(timeZone.identifier)). Use that for the time, date and day of the week, counting on from it as the call goes; never look them up on the web."
    }

    /// xAI's own search tools, run on xAI's side during the call (#598):
    /// public lookups stay on the call instead of becoming Hermes jobs.
    static let nativeTools: [[String: Any]] = [
        ["type": "web_search"],
        ["type": "x_search"],
    ]

    /// Names xAI keeps for its own tools. A client function with one of
    /// them clashes with the native tool, and a call by one of them is
    /// xAI's to run, never Conduit's.
    static let reservedToolNames: Set<String> = ["web_search", "x_search", "browse_page", "file_search"]

    // MARK: Client → server

    /// The session's configuration: server-side turn detection (the user's
    /// speech interrupts the model), PCM audio both ways, the instructions,
    /// the voice, xAI's search tools and the function tools.
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
            "tools": nativeTools + functions.filter { !reservedToolNames.contains($0.name) }.map(functionTool),
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
    /// that back while a response is still running. `upsampler` is the
    /// connection's, so its capture is upsampled as one stream.
    static func frames(for message: LiveVoiceClientMessage, upsampler: inout GrokInputUpsampler) -> (frames: [[String: Any]], wantsResponse: Bool) {
        switch message {
        case .audio(let pcm16):
            let audio = upsampler.upsample(pcm16).base64EncodedString()
            return ([["type": "input_audio_buffer.append", "audio": audio]], false)
        case .audioStreamEnd:
            // Server turn detection ends a turn on silence, and a muted
            // microphone sends none: a short silence closes the turn now.
            upsampler.reset()
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
        case .contextNote(let text):
            // Added to the conversation with no response.create: the model
            // keeps it for the user's next turn without answering it now.
            return ([[
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": text]],
                ] as [String: Any],
            ]], false)
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
        // The interpolation below is the fixed 3:2 step from the capture rate.
        assert(inputSampleRate == GeminiLiveProtocol.inputSampleRate * 3 / 2, "Grok Live upsampling assumes 16 kHz capture and 24 kHz input")
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
        /// The function names xAI's session.updated echoes back: which of
        /// the declared tools it took, for the call's trace.
        case acceptedFunctions([String])
        /// The turn detection session.updated echoes back, for the call's
        /// trace: what the server applied, not what was asked (#1418).
        case turnDetection(String)
        /// The server's turn detector heard the user start
        /// (`speech_started`, which also interrupts the model) or stop
        /// (`speech_stopped`), for the call's trace.
        case speechStarted
        case speechStopped
        /// The user's words in one input item, whole each time, not as
        /// deltas. xAI sends drafts while the user talks, each rewriting
        /// the last, then one completed transcript per item; the session
        /// keeps only the last one. `itemID` is nil when xAI sent none.
        case inputTranscriptSnapshot(itemID: String?, text: String, stage: InputTranscriptStage)
        case event(GeminiLiveProtocol.ServerEvent)
    }

    /// How far an input transcript has got, from its event's `status`.
    enum InputTranscriptStage: Equatable {
        /// `in_progress`: a draft a later snapshot of the item replaces. A
        /// draft cut mid-phrase ends in "...", and later drafts rewrite
        /// earlier words, so one isn't an extension of the last.
        case draft
        /// `completed`: the item's final transcript, sent once, before the
        /// reply's own transcript starts.
        case completed
        /// No status: a server that sends each item's transcript once, as
        /// the Realtime protocol does.
        case unstated
    }

    /// One frame can carry at most one event; unknown types are ignored.
    static func decode(_ data: Data) -> [ServerFrame] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "session.updated":
            let session = object["session"] as? [String: Any]
            let tools = session?["tools"] as? [[String: Any]]
            let names = tools?.compactMap { $0["type"] as? String == "function" ? $0["name"] as? String : nil }
            return [.sessionUpdated, .turnDetection(turnDetectionSummary(session?["turn_detection"]))]
                + (names.map { [.acceptedFunctions($0)] } ?? [])
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
            return [.speechStarted, .event(.interrupted)]
        case "input_audio_buffer.speech_stopped":
            return [.speechStopped]
        case "conversation.item.input_audio_transcription.completed":
            guard let text = object["transcript"] as? String, !text.isEmpty else { return [] }
            let itemID = (object["item_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let stage: InputTranscriptStage
            switch object["status"] as? String {
            case "in_progress": stage = .draft
            case "completed": stage = .completed
            default: stage = .unstated
            }
            return [.inputTranscriptSnapshot(itemID: itemID, text: text, stage: stage)]
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
            // xAI runs its own search tools: their calls aren't Conduit's.
            guard let call = functionCall(object), !reservedToolNames.contains(call.name) else { return [] }
            return [.event(.toolCall([call]))]
        case "response.output_item.done":
            // The finished function_call item carries the same call: a
            // fallback for a response whose arguments event never came.
            // The session runs each call id once.
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "function_call",
                  let call = functionCall(item), !reservedToolNames.contains(call.name) else { return [] }
            return [.event(.toolCall([call]))]
        default:
            return []
        }
    }

    /// The echoed turn detection in a line: its type and the settings it
    /// states. Absent is "not stated", null is off.
    static func turnDetectionSummary(_ value: Any?) -> String {
        guard let value else { return "not stated" }
        guard let object = value as? [String: Any] else { return value is NSNull ? "off" : "not readable" }
        var parts = [(object["type"] as? String) ?? "no type"]
        let settings = [
            ("threshold", "threshold"), ("silence_duration_ms", "silence ms"),
            ("prefix_padding_ms", "prefix ms"), ("idle_timeout_ms", "idle timeout ms"),
        ]
        for (key, label) in settings {
            if let number = object[key] as? NSNumber { parts.append("\(label) \(number)") }
        }
        return parts.joined(separator: ", ")
    }

    /// `arguments` is a JSON string; Conduit's tools take string values.
    static func functionCall(_ object: [String: Any]) -> GeminiLiveProtocol.FunctionCall? {
        guard let id = object["call_id"] as? String, !id.isEmpty,
              let name = object["name"] as? String, !name.isEmpty else { return nil }
        let parsed: [String: Any]
        if let given = object["arguments"] as? [String: Any] {
            parsed = given
        } else {
            let raw = (object["arguments"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                parsed = [:]
            } else if let decoded = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
                parsed = decoded
            } else {
                // Not a JSON object: never run as a call with no arguments.
                return GeminiLiveProtocol.FunctionCall(id: id, name: name, arguments: [GeminiLiveProtocol.FunctionCall.invalidArgumentsKey: "true"])
            }
        }
        return GeminiLiveProtocol.FunctionCall(id: id, name: name, arguments: GeminiLiveProtocol.FunctionCall.stringArguments(parsed))
    }
}

/// 16 kHz capture as 24 kHz PCM16 (little-endian), by linear
/// interpolation: three output samples for every two captured, across the
/// whole stream. Capture comes in odd-sized chunks (1 024 frames at 48 kHz
/// are 341 at 16 kHz), so the position between samples and the last
/// sample carry over to the next chunk, and an output sample that needs
/// the next chunk's first sample waits for it: no chunk loses half a
/// sample or restarts the 3:2 step.
struct GrokInputUpsampler {
    /// The previous chunk's last sample.
    private var last: Int16?
    /// Where the next output sample falls, in thirds of a captured sample
    /// from `last` (from the chunk's first sample when there is none).
    private var position = 0

    /// A new stream: the call (re)connected, or its turn ended.
    mutating func reset() {
        last = nil
        position = 0
    }

    mutating func upsample(_ pcm16: Data) -> Data {
        // The step below is the fixed 3:2 from the capture rate.
        assert(GrokLiveProtocol.inputSampleRate == GeminiLiveProtocol.inputSampleRate * 3 / 2, "Grok Live upsampling assumes 16 kHz capture and 24 kHz input")
        let bytes = [UInt8](pcm16)
        let count = bytes.count / 2
        guard count > 0 else { return Data() }
        var samples = (0..<count).map { Int16(bitPattern: UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8) }
        if let last { samples.insert(last, at: 0) }
        var output = Data(capacity: (count * 3 / 2 + 1) * 2)
        var numerator = position
        while true {
            // Position in the captured stream: numerator / 3 samples in.
            let lower = numerator / 3
            let fraction = numerator % 3
            let upper = fraction == 0 ? lower : lower + 1
            guard upper < samples.count else { break }
            let a = Double(samples[lower])
            let b = Double(samples[upper])
            let value = UInt16(bitPattern: Int16(clamping: Int((a + (b - a) * Double(fraction) / 3).rounded())))
            output.append(UInt8(value & 0xFF))
            output.append(UInt8(value >> 8))
            numerator += 2
        }
        last = samples.last
        position = numerator - 3 * (samples.count - 1)
        return output
    }
}
