import Foundation

/// Qwen's direct WebSocket, exposed through the shared direct-call session.
/// The adapter runs on the device. No audio or permanent key goes to a relay.
@MainActor
final class QwenLiveSocket: GeminiLiveSocket {
    private let upstream: GeminiLiveSocket
    private let voice: String
    private var activeResponse = false
    private var wantsResponse = false
    private var pendingTools: Set<String> = []
    private var toolNames: [String: String] = [:]
    private var deliveredTools: Set<String> = []
    /// Qwen takes a picture only after some audio: its image buffer is
    /// committed with the audio buffer.
    private var hasSentAudio = false
    /// Privacy-safe steps for the call's trace: the turn detection Qwen
    /// applied and when it heard the user start and stop, with microphone
    /// levels (#1418), never what anyone said.
    private let onTrace: (@MainActor (String) -> Void)?
    private var turnTrace = LiveTurnTrace()

    init(upstream: GeminiLiveSocket, voice: String = "Tina", onTrace: (@MainActor (String) -> Void)? = nil) {
        self.upstream = upstream
        self.voice = voice
        self.onTrace = onTrace
    }

    static func request(token: GeminiLiveToken) throws -> URLRequest {
        guard let host = token.webSocketURL.host?.lowercased(),
              token.webSocketURL.scheme == "wss",
              host.hasSuffix(".cn-beijing.maas.aliyuncs.com") || host.hasSuffix(".ap-southeast-1.maas.aliyuncs.com"),
              token.webSocketURL.path == "/api-ws/v1/realtime",
              token.token.hasPrefix("st-") else { throw QwenLiveError.invalidCredential }
        var request = URLRequest(url: token.webSocketURL)
        request.setValue("Bearer " + token.token, forHTTPHeaderField: "Authorization")
        return request
    }

    private func emit(_ frame: [String: Any]) async throws {
        var event = frame
        event["event_id"] = UUID().uuidString
        try await upstream.send(GeminiLiveProtocol.encode(event))
    }

    private func respond() async throws {
        wantsResponse = true
        try await flushResponse()
    }

    private func flushResponse() async throws {
        guard wantsResponse, !activeResponse, pendingTools.isEmpty else { return }
        wantsResponse = false
        activeResponse = true
        try await emit(["type": "response.create"])
    }

    func send(_ text: String) async throws {
        guard let data = text.data(using: .utf8),
              let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QwenLiveError.invalidFrame
        }
        if let setup = frame["setup"] as? [String: Any] {
            try await emit(Self.sessionUpdate(setup: setup, voice: voice))
        } else if let input = frame["realtimeInput"] as? [String: Any] {
            if let audio = input["audio"] as? [String: Any], let bytes = audio["data"] as? String {
                hasSentAudio = true
                try await emit(["type": "input_audio_buffer.append", "audio": bytes])
                if let onTrace, let pcm16 = Data(base64Encoded: bytes), let step = turnTrace.add(pcm16) { onTrace(step) }
            }
            if let video = input["video"] as? [String: Any], let image = video["data"] as? String {
                // A still photo (the call screen's Camera). It rides with the
                // user's next words, committed with the audio buffer; a
                // moment of silence first if no audio went yet, since Qwen
                // takes a picture only after some.
                // https://www.alibabacloud.com/help/en/model-studio/client-events
                if !hasSentAudio {
                    hasSentAudio = true
                    try await emit(["type": "input_audio_buffer.append", "audio": Data(repeating: 0, count: 3200).base64EncodedString()])
                }
                try await emit(["type": "input_image_buffer.append", "image": image])
            }
            if input["audioStreamEnd"] as? Bool == true {
                // End a muted utterance through VAD, without a second commit.
                try await emit(["type": "input_audio_buffer.append", "audio": Data(repeating: 0, count: 32000).base64EncodedString()])
            }
        } else if let content = frame["clientContent"] as? [String: Any] {
            for turn in content["turns"] as? [[String: Any]] ?? [] {
                let parts = turn["parts"] as? [[String: Any]] ?? []
                let words = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                guard !words.isEmpty else { continue }
                try await emit(["type": "conversation.item.create", "item": [
                    "type": "message", "role": "user", "content": [["type": "input_text", "text": words]],
                ]])
            }
            if content["turnComplete"] as? Bool == true { try await respond() }
        } else if let responses = (frame["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]] {
            var shouldRespond = false
            for response in responses {
                guard let id = response["id"] as? String else { continue }
                var output = response["response"] as? [String: Any] ?? [:]
                let scheduling = response["scheduling"] as? String ?? output["scheduling"] as? String
                if scheduling != GeminiLiveProtocol.Scheduling.silent.rawValue { shouldRespond = true }
                output.removeValue(forKey: "scheduling")
                try await emit(["type": "conversation.item.create", "item": [
                    "type": "function_call_output", "call_id": id,
                    "output": try GeminiLiveProtocol.encode(output),
                ]])
                pendingTools.remove(id)
                toolNames.removeValue(forKey: id)
                deliveredTools.remove(id)
            }
            if shouldRespond { try await respond() } else { try await flushResponse() }
        }
    }

    /// A microphone chunk goes out as Qwen's append frame, built off the
    /// main actor on the network socket (issue 1959); `encode`'s Gemini
    /// frame isn't needed, since Qwen takes the same base64 audio.
    func sendAudio(_ pcm16: Data, encode: @escaping @Sendable (Data) throws -> String) async throws {
        hasSentAudio = true
        try await upstream.sendAudio(pcm16) { pcm16 in
            try GeminiLiveProtocol.encode([
                "type": "input_audio_buffer.append",
                "audio": pcm16.base64EncodedString(),
                "event_id": UUID().uuidString,
            ])
        }
        if let onTrace, let step = turnTrace.add(pcm16) { onTrace(step) }
    }

    static func sessionUpdate(setup: [String: Any], voice: String) -> [String: Any] {
        let parts = (setup["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let declarations = (setup["tools"] as? [[String: Any]] ?? []).flatMap {
            $0["functionDeclarations"] as? [[String: Any]] ?? []
        }
        // Qwen native search cannot be enabled alongside function tools.
        // Hermes web_search remains available as an ordinary function.
        let tools: [[String: Any]] = declarations.map { declaration in
            ["type": "function", "function": ["name": declaration["name"] ?? "",
             "description": declaration["description"] ?? "", "parameters": GrokLiveProtocol.jsonSchema(declaration["parameters"] ?? [:])]]
        }
        return ["type": "session.update", "session": [
            "modalities": ["text", "audio"],
            "instructions": parts.compactMap { $0["text"] as? String }.joined(separator: "\n"),
            "audio": ["input": ["format": ["type": "pcm", "sample_rate": 16000]],
                      "output": ["format": ["type": "pcm", "sample_rate": 24000], "voice": voice]],
            // The Omni Realtime client-events contract fixes this model value.
            // https://help.aliyun.com/en/model-studio/client-events
            "input_audio_transcription": ["model": "qwen3-asr-flash-realtime"],
            "turn_detection": ["type": "server_vad", "threshold": 0.5, "silence_duration_ms": 800],
            "tools": tools,
        ]]
    }

    func receive() async throws -> Data {
        while true {
            if let mapped = try await map(try await upstream.receive()) { return mapped }
        }
    }

    /// The model's speech, the frames that come many a second, is mapped
    /// and decoded off the main actor on the network socket (issue 1959);
    /// every other event changes this adapter's state, so it is mapped here.
    func receive<T: Sendable>(decoding decode: @escaping @Sendable (Data) -> T) async throws -> T {
        while true {
            let inbound = try await upstream.receive(decoding: { data -> QwenInbound<T> in
                if let speech = QwenLiveSocket.mappedSpeech(data) { return .decoded(decode(speech)) }
                return .event(data)
            })
            switch inbound {
            case .decoded(let value):
                return value
            case .event(let data):
                if let mapped = try await map(data) { return decode(mapped) }
            }
        }
    }

    /// A `response.audio.delta` as the Gemini frame the session reads;
    /// nil for any other event.
    nonisolated static func mappedSpeech(_ data: Data) -> Data? {
        guard data.range(of: Data("response.audio.delta".utf8)) != nil,
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["type"] as? String == "response.audio.delta",
              let audio = event["delta"] as? String else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "serverContent": ["modelTurn": ["parts": [["inlineData": [
                "mimeType": "audio/pcm;rate=24000", "data": audio,
            ]]]]],
        ])
    }

    /// One Qwen event as the Gemini frame the session reads, nil for one
    /// it doesn't need.
    private func map(_ data: Data) async throws -> Data? {
        do {
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { return nil }
            var mapped: [String: Any]?
            switch type {
            case "session.updated":
                onTrace?("Turn detection: \(GrokLiveProtocol.turnDetectionSummary((event["session"] as? [String: Any])?["turn_detection"]))")
                mapped = ["setupComplete": [:]]
            case "response.created":
                onTrace?("Reply started")
                activeResponse = true
            case "response.audio.delta":
                if let audio = event["delta"] as? String {
                    mapped = ["serverContent": ["modelTurn": ["parts": [["inlineData": [
                        "mimeType": "audio/pcm;rate=24000", "data": audio,
                    ]]]]]]
                }
            case "response.audio_transcript.delta", "response.text.delta":
                if let delta = event["delta"] as? String {
                    mapped = ["serverContent": ["outputTranscription": ["text": delta]]]
                }
            case "conversation.item.input_audio_transcription.completed":
                if let transcript = event["transcript"] as? String {
                    mapped = ["serverContent": ["inputTranscription": ["text": transcript]]]
                }
            case "input_audio_buffer.speech_started":
                if let onTrace { onTrace(turnTrace.speechStarted()) }
                wantsResponse = false
                mapped = ["serverContent": ["interrupted": true]]
            case "input_audio_buffer.speech_stopped":
                if let onTrace { onTrace(turnTrace.speechStopped()) }
            case "response.output_item.added":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call",
                   let id = item["call_id"] as? String, let name = item["name"] as? String {
                    toolNames[id] = name
                    pendingTools.insert(id)
                }
            case "response.function_call_arguments.done":
                if let id = event["call_id"] as? String, !deliveredTools.contains(id),
                   let name = event["name"] as? String ?? toolNames[id] {
                    let args = (event["arguments"] as? String)?.data(using: .utf8) ?? Data("{}".utf8)
                    let object = try JSONSerialization.jsonObject(with: args) as? [String: Any] ?? [:]
                    pendingTools.insert(id)
                    deliveredTools.insert(id)
                    mapped = ["toolCall": ["functionCalls": [["id": id, "name": name, "args": object]]]]
                }
            case "response.done":
                activeResponse = false
                // Cancelled responses can end before a call's arguments
                // arrive. No controller can answer an undelivered call.
                pendingTools.formIntersection(deliveredTools)
                toolNames = toolNames.filter { deliveredTools.contains($0.key) }
                if let response = event["response"] as? [String: Any], response["status"] as? String == "failed" {
                    throw QwenLiveError.providerFailure
                }
                mapped = ["serverContent": ["turnComplete": true]]
                try await flushResponse()
            case "error": throw QwenLiveError.providerFailure
            default: break
            }
            if let mapped { return try JSONSerialization.data(withJSONObject: mapped) }
            return nil
        }
    }

    func close() { upstream.close() }
    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        await upstream.serverClose(within: timeout)
    }
}

/// One upstream frame: the model's speech already decoded, or an event
/// for the adapter to map.
private enum QwenInbound<T: Sendable>: Sendable {
    case decoded(T)
    case event(Data)
}

enum QwenLiveError: LocalizedError {
    case invalidCredential, invalidFrame, providerFailure
    var errorDescription: String? {
        switch self {
        case .invalidCredential: return AppLocalization.string("Invalid Qwen Live credential.")
        case .invalidFrame: return AppLocalization.string("Invalid Qwen Live event.")
        case .providerFailure: return AppLocalization.string("Qwen Live request failed. Check the model, workspace and quota.")
        }
    }
}
