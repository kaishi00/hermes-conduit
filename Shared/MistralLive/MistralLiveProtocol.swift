//
//  MistralLiveProtocol.swift
//  Conduit
//
//  Wire format for a Mistral voice agent: the events the agent's LiveKit
//  room carries, the function calls it makes back to this app, and the
//  session the Hermes host asks Mistral for.
//
//  Mistral runs the conversation (Voxtral listens, a text model answers,
//  Voxtral speaks); Conduit joins the room for audio and answers the
//  agent's function calls with Hermes work, as GPT-Live's delegations do.
//  Nothing here talks to the network: every shape is unit-testable.
//
//  Events arrive as JSON on the room's `voice_agent.events` data channel.
//  A transcript segment is cumulative: a segment with an id already seen
//  replaces that line rather than adding to it.
//
//  Function calls arrive over LiveKit RPC, method `mistral.function_tool`,
//  with `{name, arguments}` and a string answer that is the tool's result.
//

import Foundation

enum MistralLiveProtocol {
    /// The data channel the agent's events arrive on.
    static let eventsTopic = "voice_agent.events"
    /// The RPC method the agent calls tools through.
    static let functionToolMethod = "mistral.function_tool"
    /// The agent's audio in both directions: 16-bit mono PCM, 48 kHz.
    static let audioSampleRate: Double = 48_000
    static let defaultLLMModel = "mistral-small-latest"
    static let defaultSTTModel = "voxtral-mini-transcribe-realtime-3"
    static let defaultTTSModel = "voxtral-mini-tts-3-0"

    // MARK: - Events (agent → app)

    enum Role: String, Equatable {
        case user
        case assistant
    }

    enum Event: Equatable {
        /// A line of the transcript. `final` false is still being written;
        /// a segment with an id already seen replaces it.
        case transcript(id: String, role: Role, content: String, final: Bool)
        case toolCallStarted(id: String, name: String)
        /// `status` is "done", "error" or "cancelled".
        case toolCallEnded(id: String, name: String, arguments: String?, result: String?, status: String?)
        /// "listening", "thinking", "speaking", and Mistral's others.
        case agentState(String)
        case sessionUpdated
        case error(message: String, fatal: Bool, code: String?)
        /// An event this build doesn't read, kept for the trace.
        case unknown(type: String?)
    }

    /// Decodes one data-channel message. Nil when it isn't JSON.
    static func decode(_ text: String) -> Event? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "transcription.segment":
            guard let id = object["id"] as? String,
                  let content = object["content"] as? String else { return .unknown(type: type) }
            let role = Role(rawValue: object["role"] as? String ?? "") ?? .assistant
            return .transcript(id: id, role: role, content: content, final: object["final"] as? Bool ?? false)
        case "tool_call.started":
            guard let id = object["id"] as? String, let name = object["name"] as? String else { return .unknown(type: type) }
            return .toolCallStarted(id: id, name: name)
        case "tool_call.ended":
            guard let id = object["id"] as? String, let name = object["name"] as? String else { return .unknown(type: type) }
            return .toolCallEnded(id: id,
                                  name: name,
                                  arguments: string(object["arguments"]),
                                  result: string(object["result"]),
                                  status: object["status"] as? String)
        case "agent.state.changed":
            guard let state = object["state"] as? String else { return .unknown(type: type) }
            return .agentState(state)
        case "session.updated":
            return .sessionUpdated
        case "error":
            let message = (object["message"] as? String) ?? ""
            return .error(message: message,
                          fatal: object["fatal"] as? Bool ?? false,
                          code: object["code"] as? String)
        default:
            return .unknown(type: type)
        }
    }

    // MARK: - Function calls (agent → app, over RPC)

    struct FunctionCall: Equatable {
        let name: String
        /// The arguments as JSON text, always an object: `{}` when the call
        /// carried none, or gave them already encoded.
        let arguments: String
    }

    /// Decodes the RPC payload `{name, arguments}`. Arguments may be an
    /// object or a string carrying one, so both are normalized here.
    static func functionCall(from data: Data) -> FunctionCall? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty else { return nil }
        return FunctionCall(name: name, arguments: object["arguments"].map(argumentsJSON) ?? "{}")
    }

    /// The answer to a function call: a JSON object as text, which is what
    /// the agent reads as the tool's result.
    static func result(_ fields: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// A failure the agent can read and say out loud.
    static func failure(_ message: String) -> String {
        result(["ok": false, "error": message])
    }

    // MARK: - Session (app → Hermes host)

    /// What Conduit asks its Hermes host for. The host holds the Mistral key
    /// and builds the API request, so no credential reaches the phone.
    ///
    /// `agentID` runs a saved agent (as built in Mistral Studio), with any
    /// field here overriding it for this session only; without one the host
    /// sends this configuration as the session's own.
    struct SessionRequest: Equatable {
        var agentID: String? = nil
        var agentVersion: Int? = nil
        var instructions: String? = nil
        var welcomeMessage: String? = nil
        var voiceID: String? = nil
        var llmModel: String? = nil
        var sttModel: String? = nil
        var ttsModel: String? = nil
        /// The profile whose Mistral key and settings the host uses.
        var profile: String? = nil

        var payload: [String: Any] {
            var body: [String: Any] = [:]
            if let agentID, !agentID.isEmpty { body["agent_id"] = agentID }
            if let agentVersion { body["agent_version"] = agentVersion }
            if let instructions, !instructions.isEmpty { body["instructions"] = instructions }
            if let welcomeMessage { body["welcome_message"] = welcomeMessage }
            if let voiceID, !voiceID.isEmpty { body["voice_id"] = voiceID }
            if let llmModel, !llmModel.isEmpty { body["llm_model"] = llmModel }
            if let sttModel, !sttModel.isEmpty { body["stt_model"] = sttModel }
            if let ttsModel, !ttsModel.isEmpty { body["tts_model"] = ttsModel }
            if let profile, !profile.isEmpty { body["profile"] = profile }
            return body
        }
    }

    /// The host's answer: the room to join and the session to close.
    struct SessionAnswer: Equatable {
        let sessionID: String
        let serverURL: String
        let participantToken: String
        /// When Mistral ends the session on its own, if the host said.
        var expiresAt: Date? = nil
        /// The agent's voice, as the host resolved it (a saved agent's may
        /// differ from what was asked for).
        var voiceID: String? = nil

        static func parse(_ raw: [String: Any]) -> SessionAnswer? {
            guard let id = raw["session_id"] as? String, !id.isEmpty,
                  let url = (raw["server_url"] as? String).flatMap(URL.init(string:)),
                  url.scheme == "wss",
                  let token = raw["participant_token"] as? String, !token.isEmpty else { return nil }
            let expires = (raw["expires_at"] as? String).flatMap(ISO8601DateFormatter().date(from:))
                ?? (raw["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return SessionAnswer(sessionID: id,
                                 serverURL: url.absoluteString,
                                 participantToken: token,
                                 expiresAt: expires,
                                 voiceID: (raw["voice_id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    // MARK: - Helpers

    /// Arguments as JSON text: a string is kept if it already carries JSON,
    /// and wrapped as one value otherwise.
    private static func argumentsJSON(_ raw: Any) -> String {
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return trimmed }
            return result(["value": text])
        }
        if JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    /// A field that may arrive as text or as a JSON value.
    private static func string(_ raw: Any?) -> String? {
        switch raw {
        case let text as String:
            return text.isEmpty ? nil : text
        case .some(let other) where !(other is NSNull):
            guard JSONSerialization.isValidJSONObject(other),
                  let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }
}
