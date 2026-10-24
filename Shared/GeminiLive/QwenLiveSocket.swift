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

    init(upstream: GeminiLiveSocket, voice: String = "Tina") {
        self.upstream = upstream
        self.voice = voice
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
                try await emit(["type": "input_audio_buffer.append", "audio": bytes])
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
            let data = try await upstream.receive()
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            var mapped: [String: Any]?
            switch type {
            case "session.updated": mapped = ["setupComplete": [:]]
            case "response.created": activeResponse = true
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
                wantsResponse = false
                mapped = ["serverContent": ["interrupted": true]]
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
        }
    }

    func close() { upstream.close() }
    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        await upstream.serverClose(within: timeout)
    }
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
