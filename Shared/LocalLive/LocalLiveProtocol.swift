//
//  LocalLiveProtocol.swift
//  Conduit and the Conduit Watch app
//
//  Wire format for Local Live: a live call through the user's own speech
//  server (Hugging Face speech-to-speech), relayed by the notifier's
//  `/local-live/socket`. The server speaks the OpenAI Realtime dialect Grok
//  Live's protocol already reads, so audio and server events go through
//  GrokLiveProtocol. What is Local Live's own: the session.update (no tools,
//  the server answers each turn by itself) and the turn frames the plugin
//  adds on the same socket. When the server asks its model address for an
//  answer, the plugin sends `conduit.turn`; Conduit runs it as a Hermes chat
//  turn and streams the reply back as `conduit.turn.delta`, then
//  `conduit.turn.done`. A Watch call runs the same session through the
//  host's audio bridge, where the host answers the turns itself.
//

import Foundation

enum LocalLiveProtocol {
    /// SpeechServerSpeechStream's too: one relay serves both.
    static let socketPath = "/api/plugins/conduit_push/local-live/socket"
    static let statusPath = "/api/plugins/conduit_push/local-live/status"
    /// The OpenAI Realtime PCM rate, both ways. The 16 kHz microphone
    /// stream is upsampled to it, as for Grok Live.
    static let sampleRate: Double = 24_000
    /// The host's relay closes a socket that sends nothing for 60 s; a muted
    /// or paused call sends no audio, so a ping keeps it open.
    static let keepaliveInterval: Duration = .seconds(20)
    /// What one delta carries at most, in Unicode scalars (the plugin's
    /// Python counts code points, and takes up to 8,000 a frame).
    static let maximumDeltaCharacters = 4_000

    /// How long a call waits for the server to ask Hermes for its first
    /// reply (the readiness check). A speech server that just started can
    /// take a while to warm up; the call shows connecting meanwhile.
    static let readinessTimeout: Duration = .seconds(90)

    static var pluginMissingReason: String {
        AppLocalization.string("Update the Conduit plugin on your Hermes host to use Local Live.")
    }

    static var answeredWithoutHermesReason: String {
        AppLocalization.string("Your speech server answered without asking Hermes. Check that its model address and key match Settings > Voice > Local Live, then restart it.")
    }

    static var readinessTimedOutReason: String {
        AppLocalization.string("Your speech server didn't ask Hermes for a reply. Check that it's running and that its model address and key match Settings > Voice > Local Live.")
    }

    /// The relay socket's query: the dashboard's own profile goes without
    /// one, as the status and key requests do, so the call is filed under
    /// the same profile the server's key names.
    static func profileQueryItems(_ profile: String) -> [URLQueryItem] {
        guard !profile.isEmpty, profile != "default" else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    // MARK: Client → server

    /// Server turn detection that answers on its own (the server asks the
    /// plugin, which asks Conduit) and stops speaking when the user talks.
    /// No instructions or tools: the speech server's model is Hermes.
    static var sessionUpdate: [String: Any] {
        let format: [String: Any] = ["type": "audio/pcm", "rate": Int(sampleRate)]
        let turnDetection: [String: Any] = [
            "type": "server_vad",
            "create_response": true,
            "interrupt_response": true,
        ]
        let input: [String: Any] = ["format": format, "turn_detection": turnDetection]
        let output: [String: Any] = ["format": format]
        let session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "audio": ["input": input, "output": output] as [String: Any],
        ]
        return ["type": "session.update", "session": session]
    }

    /// The plugin keeps every `conduit.` frame for itself; this one only
    /// resets the relay's idle timer.
    static let keepalive: [String: Any] = ["type": "conduit.ping"]

    /// Words no one says, sent as the readiness check's question: the
    /// server asks its model address for the reply, the plugin hands that
    /// ask to this call as a turn, and the call knows the whole path works.
    static func readinessMarker() -> String {
        "conduit-ready-" + UUID().uuidString.lowercased()
    }

    /// An out-of-band response (conversation "none") to `marker`: the server
    /// answers it from a throwaway context, so the call's conversation never
    /// holds it.
    static func readinessCheck(_ marker: String) -> [String: Any] {
        let content: [[String: Any]] = [["type": "input_text", "text": marker]]
        let item: [String: Any] = ["type": "message", "role": "user", "content": content]
        let response: [String: Any] = ["conversation": "none", "input": [item]]
        return ["type": "response.create", "response": response]
    }

    // MARK: Agent mode

    /// What a call in agent mode (Live > Local) gives the plugin's fast
    /// model: the live-model instructions and the tools Grok Live gets.
    /// The plugin runs the model; the tools run here, as they do on Grok.
    struct AgentSetup {
        let instructions: String
        let functions: [GeminiLiveProtocol.FunctionDeclaration]
    }

    /// Added after the shared live instructions in agent mode: the fast
    /// model can't reach the user's things, Hermes can, and start_job
    /// answers as soon as the job runs (as on Grok Live). Written for the
    /// model, so not localized.
    static let agentInstructions = "\nYou are a fast front for the user's Hermes agent. You can't see the user's email, messages, calendar and schedule, to-dos, health, bank or other accounts, files or systems; Hermes can. Whenever the user asks you to check, read, find, send or do anything there (\"what's on my plate today?\" included), call start_job with their request instead of saying you can't, and never answer it from guesses." + GrokLiveProtocol.jobClaimInstructions

    static func agentConfigure(_ setup: AgentSetup) -> [String: Any] {
        ["type": "conduit.agent", "instructions": setup.instructions, "tools": setup.functions.map(GrokLiveProtocol.functionTool)]
    }

    /// A tool's answer. `speak` asks for it to be said even if the fast
    /// model stopped waiting (the plugin then sends `conduit.tool.late`).
    static func toolResult(callID: String, result: [String: String], speak: Bool) -> [String: Any] {
        let output = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ["type": "conduit.tool.result", "call_id": callID, "output": output, "speak": speak]
    }

    /// Context the fast model keeps without answering (a turn typed in the
    /// attached chat).
    static func agentNote(_ text: String) -> [String: Any] {
        ["type": "conduit.agent.note", "text": text]
    }

    enum AgentFrame: Equatable {
        /// The fast model called one of the call's tools.
        case toolCall(GeminiLiveProtocol.FunctionCall)
        /// A tool's answer came after the model stopped waiting for it.
        case late(callID: String)
    }

    /// The plugin's agent-mode frame in `data`; nil for anything else.
    static func agentFrame(_ data: Data) -> AgentFrame? {
        guard data.range(of: Data("\"conduit.tool.".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "conduit.tool.call":
            return GrokLiveProtocol.functionCall(object).map(AgentFrame.toolCall)
        case "conduit.tool.late":
            guard let id = object["call_id"] as? String, !id.isEmpty else { return nil }
            return .late(callID: id)
        default:
            return nil
        }
    }

    /// What a late tool answer is said as: an update the fast model reports.
    static func lateResultText(name: String, result: [String: String]) -> String {
        let body = result.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        return "Update from \(name), which answered late:\n\(body)\nTell the user what matters from it, briefly."
    }

    static func turnDelta(turnID: String, text: String) -> [String: Any] {
        ["type": "conduit.turn.delta", "turn_id": turnID, "text": text]
    }

    static func turnDone(turnID: String) -> [String: Any] {
        ["type": "conduit.turn.done", "turn_id": turnID]
    }

    /// `text` in pieces the plugin takes whole.
    static func deltaChunks(_ text: String) -> [String] {
        let scalars = text.unicodeScalars
        guard scalars.count > maximumDeltaCharacters else { return text.isEmpty ? [] : [text] }
        var chunks: [String] = []
        var rest = Substring(text).unicodeScalars
        while !rest.isEmpty {
            chunks.append(String(rest.prefix(maximumDeltaCharacters)))
            rest = rest.dropFirst(maximumDeltaCharacters)
        }
        return chunks
    }

    // MARK: Server → client

    enum TurnFrame: Equatable {
        /// The speech server wants the reply to `text`.
        case turn(id: String, text: String)
        /// The server moved on (the user spoke again, or it gave up).
        case cancel(id: String)
    }

    /// The plugin's turn frame in `data`; nil for the speech server's own
    /// frames. Audio frames are checked without being parsed twice.
    static func turnFrame(_ data: Data) -> TurnFrame? {
        guard data.range(of: Data("\"conduit.turn".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let id = object["turn_id"] as? String, !id.isEmpty else { return nil }
        switch type {
        case "conduit.turn":
            return .turn(id: id, text: object["text"] as? String ?? "")
        case "conduit.turn.cancel":
            return .cancel(id: id)
        default:
            return nil
        }
    }

    /// Whether `data` tells the phone to stop the reply it is playing: the
    /// server cleared its output audio, cancelled the response, or ended
    /// it as cancelled. An engine that decides on its own that the caller
    /// cut in (its own turn detection, a spoken "stop") sends one of these.
    static func stopsPlayback(_ data: Data) -> Bool {
        guard data.range(of: Data("output_audio_buffer".utf8)) != nil
                || data.range(of: Data("response.cancel".utf8)) != nil
                || data.range(of: Data("\"cancelled\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return false }
        switch type {
        case "output_audio_buffer.clear", "output_audio_buffer.cleared", "response.cancel", "response.cancelled":
            return true
        case "response.done":
            return (object["response"] as? [String: Any])?["status"] as? String == "cancelled"
        default:
            return false
        }
    }

    static func encode(_ message: [String: Any]) throws -> String {
        try GrokLiveProtocol.encode(message)
    }
}
