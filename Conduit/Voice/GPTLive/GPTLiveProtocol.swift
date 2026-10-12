//
//  GPTLiveProtocol.swift
//  Conduit
//
//  Wire format for GPT-Live on a ChatGPT subscription: the Codex
//  "frameless" realtime events, carried over the WebRTC `oai-events` data
//  channel. Audio travels as WebRTC media tracks, not as events. Pure
//  encode/decode, so every message shape is unit-testable.
//
//  The subscription session has no function tools and its instructions are
//  set by the Hermes host. The model hands work to the client with a
//  delegation; the client answers on that delegation with
//  `delegation.context.append` ("speakable" to be said aloud, "commentary"
//  for quiet progress) and adds context of its own with
//  `session.context.append`. Each appended text is at most 500 UTF-8 bytes.
//
//  GPT-Live on an API key speaks the public GPT-Live API's events instead
//  (`Dialect.api`, the same ones Hermes desktop's voice mode uses):
//  `session.input_transcript.delta` / `session.output_transcript.delta`,
//  `session.delegation.created` (which carries no text), and appends as
//  `session.commentary.append` (said aloud) or `session.thinking.append`
//  (quiet). It has no `turn.done`: `TurnAssembler` makes one when the other
//  speaker starts, a delegation comes, or the talk goes quiet.
//

import Foundation

/// Who pays for a GPT-Live call. The raw values are the host's `billing`
/// request field and its answer's `auth`. Here, not with the client, because
/// the Watch target shares this file.
enum GPTLiveBilling: String, Codable, Equatable, CaseIterable {
    /// The ChatGPT subscription the Hermes host is signed in to.
    case subscription
    /// The Hermes host's OpenAI API key, billed per minute.
    case api
}

enum GPTLiveProtocol {
    /// The data channel the events travel on (negotiated with the offer).
    static let dataChannelLabel = "oai-events"
    /// The most UTF-8 bytes one context append may carry.
    static let contextAppendMaxBytes = 500

    /// Which event set a call speaks, from the path the host billed.
    enum Dialect: Equatable {
        /// The ChatGPT subscription's Codex "frameless" events.
        case codex
        /// The public GPT-Live API (an API-key call).
        case api

        init(_ billing: GPTLiveBilling) {
            self = billing == .api ? .api : .codex
        }
    }

    // MARK: Server → client

    enum ServerEvent: Equatable {
        /// `session.started` / `session.updated`.
        case sessionStarted(id: String?)
        /// A fragment of what the user said (no timestamps).
        case inputTranscript(String)
        /// A fragment of what the model is saying.
        case outputTranscript(String)
        /// A finished turn with its whole transcript.
        case turnDone(role: String, transcript: String)
        /// The model handed work to the client. `text` is what the item
        /// carried, often empty: the request is then in the transcript.
        case delegation(id: String, text: String)
        case error(code: String?, message: String)
        case sessionClosed(reason: String?)
    }

    /// Decodes one data-channel message. Nil for anything Conduit doesn't
    /// use (or can't parse).
    static func decode(_ text: String) -> ServerEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "session.started", "session.updated":
            return .sessionStarted(id: (object["session"] as? [String: Any])?["id"] as? String)
        case "input_transcript.added":
            return transcriptText(object).map(ServerEvent.inputTranscript)
        case "output_transcript.added":
            return transcriptText(object).map(ServerEvent.outputTranscript)
        // The public API's names: no event shares a name with the Codex
        // set, so one decoder reads both.
        case "session.input_transcript.delta":
            return (object["delta"] as? String).map(ServerEvent.inputTranscript)
        case "session.output_transcript.delta":
            return (object["delta"] as? String).map(ServerEvent.outputTranscript)
        case "session.delegation.created":
            // The request itself is in the transcript, never in the event.
            guard let delegation = object["delegation"] as? [String: Any],
                  (delegation["target"] as? String ?? "client") == "client",
                  let id = delegation["id"] as? String, !id.isEmpty else { return nil }
            return .delegation(id: id, text: "")
        case "turn.done":
            guard let turn = object["turn"] as? [String: Any],
                  let role = turn["role"] as? String,
                  let transcript = turn["transcript"] as? String else { return nil }
            return .turnDone(role: role, transcript: transcript)
        case "delegation.created":
            guard let item = object["item"] as? [String: Any],
                  item["type"] as? String == "delegation",
                  item["target"] as? String == "client",
                  let id = item["id"] as? String, !id.isEmpty else { return nil }
            let text = (item["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "input_text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return .delegation(id: id, text: text)
        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? object["message"] as? String ?? ""
            return .error(code: error?["code"] as? String, message: message)
        case "session.closed":
            return .sessionClosed(reason: object["reason"] as? String)
        default:
            return nil
        }
    }

    private static func transcriptText(_ object: [String: Any]) -> String? {
        (object["item"] as? [String: Any])?["text"] as? String
    }

    // MARK: Client → server

    enum Channel: String {
        /// Said aloud (paraphrased) by the model.
        case speakable
        /// Quiet context: progress, state the model may use.
        case commentary
    }

    /// Context appends for `text`, one message per 500-byte chunk. With a
    /// delegation id they answer that delegation; without, they add to the
    /// session.
    static func contextAppendMessages(_ text: String, channel: Channel, delegationID: String? = nil, dialect: Dialect = .codex) -> [[String: Any]] {
        if dialect == .api {
            return chunks(text).map { chunk -> [String: Any] in
                [
                    "type": channel == .speakable ? "session.commentary.append" : "session.thinking.append",
                    "content": chunk,
                    // Null adds to the session rather than a delegation.
                    "delegation_id": delegationID.map { $0 as Any } ?? NSNull(),
                ]
            }
        }
        return chunks(text).map { chunk in
            var message: [String: Any] = [
                "type": delegationID == nil ? "session.context.append" : "delegation.context.append",
                "channel": channel.rawValue,
                "content": [["type": "input_text", "text": chunk]],
            ]
            if let delegationID { message["delegation_item_id"] = delegationID }
            return message
        }
    }

    static func sessionCloseMessage() -> [String: Any] { ["type": "session.close"] }

    /// Splits `text` (trimmed) into pieces of at most `limit` UTF-8 bytes,
    /// never inside a character. A single character over the limit (an
    /// extreme emoji sequence) is split between its scalars instead.
    static func chunks(_ text: String, limit: Int = contextAppendMaxBytes) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var bytes = 0
        func append(_ piece: String, size: Int) {
            if bytes + size > limit, !current.isEmpty {
                result.append(current)
                current = ""
                bytes = 0
            }
            current += piece
            bytes += size
        }
        for character in trimmed {
            let size = String(character).utf8.count
            if size <= limit {
                append(String(character), size: size)
            } else {
                for scalar in character.unicodeScalars {
                    append(String(scalar), size: String(scalar).utf8.count)
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func encode(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Turns (public API)

    /// Makes the `turn.done` the public API doesn't send: a turn ends when
    /// the other speaker starts, when the model delegates (the user's
    /// request is over), or after `quietInterval` without new words
    /// (`flush`, which the session calls on a timer). Pure, so testable.
    struct TurnAssembler {
        /// The model's turn ends after this long without new words.
        static let quietInterval: Duration = .milliseconds(1500)
        /// The user's lasts longer: people pause mid-sentence, and the model
        /// answering or delegating ends their turn first anyway.
        static let userQuietInterval: Duration = .seconds(3)

        private var role: String?
        private var text = ""

        /// Whether a turn is open (and a quiet timer should run).
        var hasOpenTurn: Bool { role != nil }

        /// How long the open turn may go quiet before it ends.
        var openTurnQuietInterval: Duration { role == "user" ? Self.userQuietInterval : Self.quietInterval }

        /// The events to hand on for `event`: a `turnDone` first when it
        /// closes the open turn, then the event itself.
        mutating func receive(_ event: ServerEvent) -> [ServerEvent] {
            switch event {
            case .inputTranscript(let fragment):
                return take(fragment, role: "user") + [event]
            case .outputTranscript(let fragment):
                return take(fragment, role: "assistant") + [event]
            case .delegation:
                guard role == "user", let done = flush() else { return [event] }
                return [done, event]
            case .sessionClosed:
                guard let done = flush() else { return [event] }
                return [done, event]
            case .turnDone:
                // A real one (should the API ever send it) ends the turn,
                // so the quiet timer never ends it a second time.
                role = nil
                text = ""
                return [event]
            default:
                return [event]
            }
        }

        /// Closes the open turn, if any.
        mutating func flush() -> ServerEvent? {
            guard let role else { return nil }
            let done = ServerEvent.turnDone(role: role, transcript: text)
            self.role = nil
            text = ""
            return done
        }

        private mutating func take(_ fragment: String, role: String) -> [ServerEvent] {
            var closed: [ServerEvent] = []
            if self.role != role, let done = flush() { closed.append(done) }
            self.role = role
            text += fragment
            return closed
        }
    }

    // MARK: Seeded history

    /// A conversation item for the session's `history` (the host passes it
    /// on as `initial_items`).
    static func historyItem(role: String, text: String) -> [String: Any] {
        [
            "type": "message",
            "role": role,
            "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]],
        ]
    }
}
