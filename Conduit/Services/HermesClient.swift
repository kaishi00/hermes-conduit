//
//  HermesClient.swift
//  Conduit
//
//  JSON-RPC over WebSocket client for the Hermes gateway.
//
//  ARCHITECTURE NOTE:
//  This client is deliberately thin — it only handles WebSocket transport
//  and JSON-RPC request/response correlation. ALL session state, busy state,
//  and reconnection logic lives in AppState.swift's syncSession().
//
//  The client reports stream events via onEvent callback and disconnects
//  via onDisconnected callback. AppState decides what to do with them.
//
//  LESSONS FROM RN BUILDS 17-30:
//  - `session.resume.running` and `session.info.running` are authoritative
//    turn state. Missing `running` means the gateway is too old for safe chat
//    controls.
//  - Use resumed.messages from session.resume RPC, including any in-flight
//    transcript state, rather than deriving liveness from message roles.
//    Since the compact resume (issue #106) the default openSession suppresses
//    that transcript (omit_messages) and AppState hydrates the persisted rows
//    over REST; openSessionLegacy is the variant whose response still carries
//    the messages.
//  - Do NOT merge gateway RPC session.list into the UI list — it reads from
//    the main DB containing ALL profiles. Use profile-scoped endpoint only.
//

import Foundation
import Combine
import os
import UniformTypeIdentifiers

// MARK: - JSON-RPC Types

private struct JsonRpcRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

/// A JSON-RPC `id` as it appears on an inbound frame. Responses to this
/// client's own requests echo its integer ids; server→client requests
/// (`tui_gateway/server_requests.py`) carry string ids (`srq-<hex>`), so a
/// string id must decode instead of dropping the whole frame.
private enum JsonRpcID: Decodable, Equatable, Sendable {
    case int(Int)
    case string(String)
    /// Any other scalar (JSON-RPC forbids them): decoded so the rest of the
    /// frame is not lost. It never matches a request of ours and is never
    /// answered (requests need a string id).
    case other

    /// From a `JSONSerialization` value. Nil for an absent or null id, as
    /// the Decodable path reads it.
    init?(jsonObject value: Any?) {
        guard let value, !(value is NSNull) else { return nil }
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber where !AnyCodable.isBoolean(number):
            let int = number.intValue
            self = Double(int) == number.doubleValue ? .int(int) : .other
        default:
            self = .other
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .other
        }
    }

    /// The id exactly as it must be echoed back in a response frame.
    var wireValue: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        case .other: return NSNull()
        }
    }
}

/// First-caller-wins latch for racing a completion handler against a
/// deadline; exactly one side resumes the continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private struct JsonRpcResponse: Decodable, Sendable {
    let id: JsonRpcID?
    let result: AnyCodable?
    let error: RpcError?
    let method: String?
    let params: AnyCodable?

    /// Reads an inbound frame with `JSONSerialization`. `JSONDecoder` finds
    /// each `AnyCodable` value's type by trying to decode it as every type
    /// in turn, and on the main actor that cost a frame's worth of time for
    /// a large tool result, even one from a chat in the background. Nil for
    /// anything the Decodable path would refuse.
    init?(frame data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var method: String?
        if let value = object["method"], !(value is NSNull) {
            guard let string = value as? String else { return nil }
            method = string
        }
        var error: RpcError?
        if let value = object["error"], !(value is NSNull) {
            guard let fields = value as? [String: Any],
                  let parsed = RpcError(jsonObject: fields) else { return nil }
            error = parsed
        }
        self.id = JsonRpcID(jsonObject: object["id"])
        self.result = AnyCodable(optionalJSONObject: object["result"])
        self.error = error
        self.method = method
        self.params = AnyCodable(optionalJSONObject: object["params"])
    }
}

/// An inbound frame, read and (for a stream event) parsed in one place, so
/// a large one can be done off the main actor. Immutable once built, and
/// handed to the main actor once.
///
/// `@unchecked` holds only while everything reachable from `StreamEvent` is
/// an immutable value, and while `StreamEventParser.parse` and what it calls
/// touch no shared mutable state (no shared formatters or caches, nothing
/// main-actor bound): it runs off the main actor for large frames.
private struct DecodedFrame: @unchecked Sendable {
    let response: JsonRpcResponse?
    /// The parsed stream event, for an `event` notification.
    let event: StreamEvent?
    let byteCount: Int

    init(_ data: Data) {
        let response = JsonRpcResponse(frame: data)
        self.response = response
        if response?.method == "event", let params = response?.params {
            event = StreamEventParser.parse(params: params)
        } else {
            event = nil
        }
        byteCount = data.count
    }
}

struct RpcError: Decodable, Error, LocalizedError, Sendable {
    let code: Int?
    let message: String
    /// Machine-readable refusal reason from the error's `data.reason`
    /// (Hermes' contract; the message is for people), e.g.
    /// `SESSION_NOT_OWNED` on a `prompt.submit` 4090.
    var reason: String? = nil
    /// Hermes' one-line explanation from `data.detail`, e.g. what to use
    /// instead of a command `slash.exec` refuses.
    var detail: String? = nil

    var errorDescription: String? { message }

    /// Hermes refused the send because another live surface (Hermes
    /// Desktop, a terminal) owns this chat.
    var isSessionNotOwned: Bool { reason == "SESSION_NOT_OWNED" }

    /// Hermes' contract check refused a key this gateway doesn't know
    /// (`4000 invalid params for <method>: <key>: Extra inputs are not
    /// permitted`). Nothing ran, so the request is safe to resend without it.
    func refusesUnknownParam(_ key: String) -> Bool {
        code == 4000 && message.contains("invalid params") && message.contains(key)
    }
}

extension RpcError {
    private enum CodingKeys: String, CodingKey { case code, message, data }

    /// From a `JSONSerialization` object, refusing what `init(from:)` does.
    fileprivate init?(jsonObject object: [String: Any]) {
        guard let message = object["message"] as? String else { return nil }
        var code: Int?
        if let value = object["code"], !(value is NSNull) {
            guard let number = value as? NSNumber, !AnyCodable.isBoolean(number),
                  Double(number.intValue) == number.doubleValue else { return nil }
            code = number.intValue
        }
        let data = AnyCodable(optionalJSONObject: object["data"])
        self.init(
            code: code,
            message: message,
            reason: data?.objectValue?["reason"]?.stringValue,
            detail: data?.objectValue?["detail"]?.stringValue
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try? container.decodeIfPresent(AnyCodable.self, forKey: .data)
        self.init(
            code: try container.decodeIfPresent(Int.self, forKey: .code),
            message: try container.decode(String.self, forKey: .message),
            reason: data?.objectValue?["reason"]?.stringValue,
            detail: data?.objectValue?["detail"]?.stringValue
        )
    }
}

// Type-erased Codable for dynamic JSON
enum AnyCodable: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Each miss below throws and builds an error, so the common kinds go
        // first. JSONDecoder never reads a number or a bool as a string, or
        // the reverse, so the order doesn't change any value.
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self = .object(v)
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self = .array(v)
        } else {
            self = .null
        }
    }

    /// From a `JSONSerialization` value.
    init(jsonObject value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = Self.isBoolean(number) ? .bool(number.boolValue) : .number(number.doubleValue)
        case let object as [String: Any]:
            self = .object(object.mapValues(AnyCodable.init(jsonObject:)))
        case let array as [Any]:
            self = .array(array.map(AnyCodable.init(jsonObject:)))
        default:
            self = .null
        }
    }

    /// Nil for an absent or null value, as `decodeIfPresent` reads it.
    init?(optionalJSONObject value: Any?) {
        guard let value, !(value is NSNull) else { return nil }
        self.init(jsonObject: value)
    }

    /// `JSONSerialization` hands back true and false as NSNumber too.
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .number(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Renders any AnyCodable type as a display string, not just raw strings.
    /// Tool input/output from the gateway often arrives as JSON objects/arrays.
    var descriptiveStringValue: String? {
        switch self {
        case .string(let s): return s
        case .null: return nil
        case .bool(let b): return String(b)
        case .number(let n): return String(n)
        case .array, .object:
            // Serialize complex types to pretty JSON
            if let data = try? JSONEncoder().encode(self),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return nil
        }
    }

    /// The number truncated toward zero, or nil when it isn't one or lies
    /// outside `Int`'s range: `Int(Double)` traps on NaN, infinity and
    /// out-of-range values, and gateway payloads can carry any JSON number.
    var intValue: Int? {
        guard case .number(let n) = self,
              n.isFinite,
              n >= -9_223_372_036_854_775_808.0, // Int.min == -2^63, exact as Double
              n < 9_223_372_036_854_775_808.0    // 2^63 itself already overflows
        else { return nil }
        return Int(n)
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [AnyCodable]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: AnyCodable]? {
        if case .object(let o) = self { return o }
        return nil
    }

    // Deep conversion to native Swift types
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        }
    }
}

// MARK: - Stream Events

/// Which row a `message.react` call addresses.
enum MessageReactionTarget: Equatable {
    case row(Int)
    /// The newest persisted row of this role (`"assistant"` or `"user"`).
    case newest(role: String)
}

struct MessageReactionResult: Equatable {
    let rowId: Int
    let reactions: [MessageReaction]
}

enum StreamEvent {
    case messageStart(sessionId: String)
    case messageDelta(sessionId: String, text: String)
    case reasoningDelta(sessionId: String, text: String)
    /// `alreadyShown`: Hermes says the final text is one this turn already
    /// delivered as `message.interim` (`response_previewed` /
    /// `response_reused`), so it adds no new text.
    case messageComplete(sessionId: String, messageId: String?, content: String?, reasoning: String?, alreadyShown: Bool = false)
    /// `message.interim`: assistant commentary (text beside tool calls, or an
    /// answer before a verification nudge) sealed as its own row.
    /// `alreadyStreamed` means its text already arrived as deltas.
    case messageInterim(sessionId: String, text: String, alreadyStreamed: Bool)
    /// The agent reacted to a message (its `react_to_message` tool). The
    /// reaction is already persisted; this only paints it now. `role` names
    /// the reacted row's role so a live row with no `rowId` yet can match.
    case messageReaction(sessionId: String, rowId: Int, reactions: [MessageReaction], role: String)
    case messageError(sessionId: String, message: String)
    /// `user.message`: a user message another client sent in the session,
    /// already stored as `rowId`.
    case userMessage(sessionId: String, rowId: Int?, text: String, origin: String?)
    /// `sessions.changed`: the stored session list moved (state.db), from
    /// any process: a turn run in the TUI or on another device, a rename,
    /// a deletion. Carries nothing; the catalog says what moved.
    case sessionsChanged
    case messageInterrupted(sessionId: String)
    case sessionBusy(sessionId: String, busy: Bool)
    case sessionInfo(sessionId: String, snapshot: SessionRuntimeSnapshot)
    case sessionTitle(runtimeSessionId: String, storedSessionId: String, title: String)
    case toolStart(sessionId: String, toolName: String, toolInput: String?, toolID: String? = nil)
    case toolComplete(sessionId: String, toolName: String, toolOutput: String?, toolID: String? = nil)
    case reviewSummary(sessionId: String, activity: ReviewActivity)
    /// The complete normalized clarification — batch structure intact. The
    /// parser must not flatten `questions[]` back into scalar fields, or a
    /// parsed batch would be discarded at the AppState boundary.
    case clarify(sessionId: String, activity: ClarifyActivity)
    /// `clarify.expire { request_id }` (legacy, always a timeout) or a
    /// `request.cancel` for a clarify server request, carrying its `reason`
    /// (`timeout`, `interrupted`, `shutdown`, `session_closed`).
    case clarifyExpire(sessionId: String, requestId: String, reason: String? = nil)
    case approval(sessionId: String, activity: ApprovalActivity)
    /// A `sudo` / `secret` / `vault.*` input server request.
    case inputPrompt(sessionId: String, activity: InputPromptActivity)
    /// `request.cancel` for one of those: the gateway withdrew it, with its
    /// `reason` (`timeout`, `interrupted`, `shutdown`, `session_closed`).
    case inputPromptExpire(sessionId: String, requestId: String, reason: String? = nil)
    /// `request.cancel` for an approval server request, translated to the
    /// approval queue id the card is keyed by. `resolved` means a choice was
    /// committed — by this device or another surface.
    case approvalWithdrawn(sessionId: String, requestId: String, reason: String)
    case contextUpdate(sessionId: String, percent: Double, used: Int, max: Int)
    case cwdUpdate(sessionId: String, cwd: String)
    case modelUpdate(sessionId: String, model: String, provider: String)
    case agentCount(sessionId: String, count: Int)
    case delegateAgent(sessionId: String, activity: DelegateAgentActivity)
    /// `status.update` — gateway lifecycle status for a session. Compaction
    /// edges drive the compression spinner/state; unrelated kinds are typed
    /// as `.other` so they can never masquerade as compaction events.
    case statusUpdate(sessionId: String, kind: StatusUpdateKind, text: String?)
    /// `background.complete` / `btw.complete`: a side agent's answer (or
    /// `error: …`), on the session that started it.
    case sideAgentComplete(sessionId: String, kind: SideAgentKind, taskId: String, text: String, question: String?)
    case unparsed(payload: [String: Any])
}

/// Hermes' side agents. Each starts with its own RPC, which answers with a
/// task id at once; the answer comes later as its completion event.
enum SideAgentKind: Equatable {
    /// `/background`: a separate agent runs the prompt.
    case background
    /// `/btw`: a side question answered over a snapshot of the chat,
    /// leaving the conversation itself untouched.
    case btw

    var method: String { self == .btw ? "prompt.btw" : "prompt.background" }
}

/// `status.update` `payload.kind` values Hermes emits on the compression
/// lifecycle (verified against `tui_gateway/server.py::_status_update`):
/// `compacting` is active server-side compaction (auto-compaction progress
/// re-tagged from the generic "lifecycle" kind), and `compacted` is the
/// terminal completion edge (e.g. the compute-host late ack). The in-process
/// manual path uses unrelated kinds (`compressing`, then a bare `status`),
/// which land in `.other` together with every driver-specific string.
enum StatusUpdateKind: Equatable {
    case compacting
    case compacted
    case other(String)
}

/// Runtime fields returned by `session.resume` and `session.info`.
/// `running` is optional only so the client can identify an outdated gateway
/// and refuse to offer unreliable stop/steer controls.
struct SessionRuntimeSnapshot {
    let running: Bool?
    let status: String?
    let model: String?
    let provider: String?
    let cwd: String?
    let contextPercent: Double?
    let contextUsed: Int?
    let contextMax: Int?
    let activeAgents: Int?
    let reasoningEffort: String?
    let fast: Bool?
    /// The session's next-turn tier (`service_tier`), so Ultrafast reads
    /// apart from Fast.
    let serviceTier: String?
    /// Per-session approval bypass. This overrides the profile default while
    /// the conversation is active without changing `approvals.mode` itself.
    let yolo: Bool?
    let approvalsMode: String?
    let inflight: AnyCodable?
    let queued: AnyCodable?
    /// Authoritative still-pending clarification carried by `session.resume`
    /// (`pending_clarify`) — the same payload as the one-shot `clarify.request`
    /// plus any answers locked before the client detached. The one-shot event
    /// is not sufficient for restore: it may have fired while the app was
    /// backgrounded or disconnected.
    let pendingClarify: ClarifyActivity?
    /// Further unanswered clarify server requests from `open_requests`
    /// (after the oldest, which rides `pendingClarify`).
    let additionalPendingClarifies: [ClarifyActivity]
    /// Raw authoritative approval still blocking the session. AppState adds
    /// the enclosing runtime session id when normalizing the card.
    let pendingApprovalPayload: [String: AnyCodable]?
    /// Unanswered sudo / secret / vault requests re-announced by
    /// `session.resume` (`open_requests`), oldest first. Upstream never puts
    /// `open_requests` in `session.info`, so a live snapshot parses none.
    let pendingInputPrompts: [InputPromptActivity]
    /// The agent's plan (Hermes 0.21+ `todo_state`), worked out by the
    /// gateway from the whole stored history; nil when the chat has none.
    let todoState: AgentPlan?

    /// `session.resume` may include an in-flight or queued projection that is
    /// newer than the persisted database transcript. Keep that projection for
    /// a live turn; the REST transcript is otherwise the richer history view.
    var hasLiveProjection: Bool {
        [inflight, queued].contains { value in
            guard let value else { return false }
            // Mirror JavaScript's `Boolean(resumed.inflight || resumed.queued)`
            // check in Desktop. In particular, `queued: false` must not hide
            // the durable timestamped transcript.
            switch value {
            case .null:
                return false
            case .bool(let flag):
                return flag
            case .number(let number):
                return number != 0 && !number.isNaN
            case .string(let text):
                return !text.isEmpty
            case .array, .object:
                return true
            }
        }
    }

    /// The in-flight projection holds text that has not reached state.db yet.
    /// A resumed live turn needs this prefix before it accepts new token deltas.
    var inflightAssistantText: String {
        guard let object = inflight?.objectValue else { return "" }
        return ["assistant", "text", "content"]
            .compactMap { object[$0]?.stringValue }
            .first { !$0.isEmpty } ?? ""
    }

    init(
        object: [String: AnyCodable],
        inflight: AnyCodable? = nil,
        queued: AnyCodable? = nil
    ) {
        running = object["running"]?.boolValue
        status = object["status"]?.stringValue
        model = object["model"]?.stringValue
        provider = object["provider"]?.stringValue
        cwd = object["cwd"]?.stringValue
        contextPercent = object["context_percent"]?.doubleValue
        contextUsed = object["context_used"]?.intValue
        contextMax = object["context_max"]?.intValue
        activeAgents = object["active_agents"]?.intValue ?? object["active_subagents"]?.intValue
        reasoningEffort = object["reasoning_effort"]?.stringValue
            ?? object["reasoning"]?.stringValue
        fast = object["fast"]?.boolValue
            ?? object["fast_mode"]?.boolValue
        serviceTier = object["service_tier"]?.stringValue
        yolo = object["yolo"]?.boolValue
        approvalsMode = object["approvals_mode"]?.stringValue
            ?? object["approval_mode"]?.stringValue
            ?? object["approvals"]?.objectValue?["mode"]?.stringValue
        pendingClarify = object["pending_clarify"]?.objectValue
            .flatMap { MessageNormalizer.pendingClarifyActivity(from: $0) }
        additionalPendingClarifies = (object["open_clarifies"]?.arrayValue ?? []).compactMap {
            $0.objectValue.flatMap { MessageNormalizer.pendingClarifyActivity(from: $0) }
        }
        pendingApprovalPayload = object["pending_approval"]?.objectValue
        pendingInputPrompts = InputPromptActivity.pending(inOpenRequests: object["open_requests"])
        todoState = (object["todo_state"]?.anyValue as? [String: Any]).flatMap { AgentPlan(snapshot: $0) }
        self.inflight = inflight
        self.queued = queued
    }
}

struct SessionResumeResult {
    let sessionId: String
    /// The durable stored-session key the response names, parsed from
    /// `stored_session_id` / `session_key` when the gateway provides one.
    /// Deliberately separate from `sessionId`: a returned runtime id alone is
    /// never proof of durable conversation identity.
    var storedSessionId: String? = nil
    let messages: [ChatMessage]
    let snapshot: SessionRuntimeSnapshot
}

/// Typed result of `session.compress` — the dedicated manual-compression RPC
/// the TUI and Hermes Desktop use for `/compress`. Shapes verified against
/// upstream `tui_gateway`:
/// - in-process compression (`_compress_live`): `status` of `"compressed"` or
///   `"aborted"`, `removed`, a `summary` object, and `messages` — the
///   post-compress history in the same shape `session.resume` returns;
/// - compute-host compression (`_compress_via_compute_host`): the host's
///   result forwarded verbatim (same fields), or `status: "pending"` when the
///   gateway's bounded wait expired while the host is still compressing;
/// - a concurrent compression already holding the lock:
///   `lock_held: true` with a human-readable `message` and no `status`.
/// The user turns `/undo` and `/retry` can rewind to, oldest first, and the
/// session fences the rewind presents.
struct SessionRewindSnapshot: Equatable {
    struct Turn: Equatable {
        /// The durable `messages.id` a rewind names.
        let rowID: Int
        /// The turn's text; nil when it held more than text (a picture or
        /// a file), which `/retry` can't send again as typed.
        let text: String?
    }

    let turns: [Turn]
    let revision: Int?
    let generation: Int?

    init(turns: [Turn], revision: Int?, generation: Int?) {
        self.turns = turns
        self.revision = revision
        self.generation = generation
    }

    init(resume object: [String: AnyCodable]) {
        turns = (object["messages"]?.arrayValue ?? []).compactMap { Self.userTurn($0.objectValue ?? [:]) }
        revision = HermesClient.exactIntValue(object["revision"])
        generation = HermesClient.exactIntValue(object["execution_generation"])
    }

    /// Hermes' `_user_turns`: a live user row with a durable id, typed by a
    /// person (a /steer counts), never a compaction carrier or a row a
    /// compression archived.
    private static func userTurn(_ row: [String: AnyCodable]) -> Turn? {
        guard row["role"]?.stringValue == "user",
              let rowID = HermesClient.exactIntValue(row["row_id"]),
              row["archived"]?.boolValue != true,
              row["_compressed_summary"]?.boolValue != true else { return nil }
        switch row["display_kind"] {
        case nil, .null?, .string("")?, .string("steer")?: break
        default: return nil
        }
        return Turn(rowID: rowID, text: text(of: row["content"]))
    }

    /// A text turn's words; nil when a part isn't text.
    static func text(of content: AnyCodable?) -> String? {
        switch content {
        case .string(let text)?:
            return text
        case .array(let parts)? where !parts.isEmpty:
            var words: [String] = []
            for part in parts {
                guard let object = part.objectValue,
                      object["type"]?.stringValue == "text",
                      let text = object["text"]?.stringValue else { return nil }
                words.append(text)
            }
            return words.joined(separator: "\n")
        default:
            return nil
        }
    }
}

/// Hermes' answer to a rewind: how many rows it took back, and the user
/// turn it rewound to.
struct SessionRewindReceipt: Equatable {
    let rewoundCount: Int
    /// The rewound turn's text; nil when it held more than text.
    let text: String?

    init(rewoundCount: Int, text: String?) {
        self.rewoundCount = rewoundCount
        self.text = text
    }

    init(result: AnyCodable) {
        let object = result.objectValue ?? [:]
        // Only `nothing` means nothing was taken back; an applied rewind
        // without its count still took back the target.
        let nothing = object["status"]?.stringValue == "nothing"
        rewoundCount = nothing ? 0 : (HermesClient.exactIntValue(object["rewound_count"]) ?? 1)
        text = SessionRewindSnapshot.text(of: object["target_message"]?.objectValue?["content"])
    }
}

struct SessionCompressResult {
    enum Status: Equatable {
        case compressed
        case pending
        case aborted
    }

    let status: Status?
    let lockHeld: Bool
    let message: String?
    let removed: Int?
    let messages: [ChatMessage]
    /// Distinguishes "gateway returned no transcript" from "returned an empty
    /// one" — an absent `messages` payload must never clear the transcript.
    let hasMessagesPayload: Bool
    let summaryHeadline: String?
    let summaryTokenLine: String?
    let summaryNote: String?
    /// `summary.aborted`. The compute-host result can carry the abort flag
    /// inside `summary` alone, so abort detection checks both fields.
    let summaryAborted: Bool
    /// Compute-host results carry the host's rendered feedback under
    /// `host_ack.output`; rendered when the response has no summary lines
    /// (upstream Desktop falls back to it before the removed-count text).
    let hostOutput: String?

    var isPending: Bool { status == .pending }
    var isAborted: Bool { status == .aborted || summaryAborted }

    /// Non-trapping exact `Int` extraction. Delegates to `HermesClient.exactIntValue`.
    private static func exactIntValue(_ value: AnyCodable?) -> Int? {
        HermesClient.exactIntValue(value)
    }

    init(from result: AnyCodable) {
        let object = result.objectValue ?? [:]
        switch object["status"]?.stringValue?.lowercased() {
        case "pending": status = .pending
        case "aborted": status = .aborted
        case "compressed": status = .compressed
        default: status = nil
        }
        lockHeld = object["lock_held"]?.boolValue == true
        message = object["message"]?.stringValue
        removed = Self.exactIntValue(object["removed"])
        hasMessagesPayload = object["messages"]?.arrayValue != nil
        messages = MessageNormalizer.normalizeMessages(object["messages"]?.arrayValue ?? [])
        let summary = object["summary"]?.objectValue ?? [:]
        summaryHeadline = summary["headline"]?.stringValue
        summaryTokenLine = summary["token_line"]?.stringValue
        summaryNote = summary["note"]?.stringValue
        summaryAborted = summary["aborted"]?.boolValue == true
        hostOutput = object["host_ack"]?.objectValue?["output"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SessionBranchMessage {
    let role: MessageRole
    let content: String
}

/// The end of a delegate agent's live transcript, from `subagent.tail`.
/// `available` is false before the agent has written anything and after it
/// ends.
struct SubagentTail: Equatable {
    var available: Bool
    var text: String
    var truncated: Bool
}

/// Typed result of `prompt.submit`, derived from the gateway's actual
/// response `status` field (verified against upstream `tui_gateway`):
/// `streaming` for a new turn, `steered`/`redirected`/`queued` when the
/// gateway applied its busy-input policy to a mid-turn submission. The busy
/// outcomes are NOT failures — Hermes accepted the text — but they prove the
/// session was RUNNING when the prompt landed, so a caller that believed the
/// session idle must adopt the authoritative busy state.
enum PromptSubmissionOutcome: Equatable {
    /// `{"status": "streaming"}` — the gateway started a new turn.
    case accepted
    /// `{"status": "steered"}` — injected into the live turn.
    case steered
    /// `{"status": "redirected"}` — live-turn correction accepted.
    case redirected
    /// `{"status": "queued"}` — held for the next turn.
    case queued

    var isBusySubmission: Bool { self != .accepted }

    init(gatewayStatus: String?) {
        switch gatewayStatus?.lowercased() {
        case "steered": self = .steered
        case "redirected": self = .redirected
        case "queued": self = .queued
        // "streaming" and any unrecognized success shape: the RPC envelope
        // succeeded, so the submission was accepted. Older gateways may omit
        // the status field; never invent a failure from a missing field.
        default: self = .accepted
        }
    }
}

/// One row of `session.active_list` — the gateway's authoritative in-memory
/// runtime registry. Reading it does not resume, focus, or otherwise mutate a
/// session (upstream contract), which makes it the only safe liveness probe
/// for a healthy foreground transition.
struct LiveSessionStatus: Equatable {
    /// The registry's runtime id for this live session.
    let runtimeSessionId: String
    /// The durable stored session key the runtime was resumed/created from.
    let storedSessionId: String
    /// Upstream `_session_live_status`: "working" | "waiting" | "starting" | "idle".
    let status: String
    let lastActive: TimeInterval?
    /// How many rows the runtime's history holds. It moves when a turn ends,
    /// whichever device ran it.
    let messageCount: Int?
    /// The running turn's reply so far, else its prompt (or the last row's
    /// text when idle): whitespace-collapsed, at most 160 characters.
    let preview: String?

    /// Authoritative committed-busy state. Upstream `_session_live_status`
    /// reports "working" while the turn thread runs and "waiting" while a
    /// decision is pending. "starting" is deliberately excluded: it means
    /// `agent_build_started` with the ready event unset, which
    /// `_schedule_agent_build` also arms for PLAIN session.create /
    /// cold-resume pre-warm with no prompt involved — and because the
    /// starting check precedes the running check it can transiently mask a
    /// committed running turn during the submit→agent-ready window. Hermes
    /// Desktop likewise treats only working/waiting as busy. A "starting"
    /// row is runtime-present, liveness-inconclusive; the typed
    /// `prompt.submit` outcome is the authority for busy-input semantics.
    var isRunning: Bool { status == "working" || status == "waiting" }

    init(
        runtimeSessionId: String,
        storedSessionId: String,
        status: String,
        lastActive: TimeInterval? = nil,
        messageCount: Int? = nil,
        preview: String? = nil
    ) {
        self.runtimeSessionId = runtimeSessionId
        self.storedSessionId = storedSessionId
        self.status = status
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.preview = preview
    }

    init?(from object: [String: AnyCodable]) {
        guard let runtimeId = object["id"]?.stringValue, !runtimeId.isEmpty else {
            return nil
        }
        self.init(
            runtimeSessionId: runtimeId,
            storedSessionId: object["session_key"]?.stringValue ?? "",
            status: object["status"]?.stringValue ?? "idle",
            lastActive: object["last_active"]?.doubleValue,
            messageCount: HermesClient.exactIntValue(object["message_count"]),
            preview: object["preview"]?.stringValue
        )
    }
}

/// Result of the newer active-turn correction RPC. `queued` is still a
/// successful delivery: Hermes accepted the correction while the agent was
/// in its short turn-build window and will run it next.
enum SessionRedirectOutcome: Equatable {
    case redirected
    case queued
    case rejected

    init(gatewayStatus: String?) {
        switch gatewayStatus?.lowercased() {
        case "redirected": self = .redirected
        case "queued": self = .queued
        default: self = .rejected
        }
    }
}

// MARK: - Pending Request

private struct PendingRequest {
    let continuation: CheckedContinuation<AnyCodable, Error>
    let timer: Timer?
}

// MARK: - WebSocket seam

/// The slice of `URLSessionWebSocketTask` that `HermesClient` depends on, so
/// the client can be driven against a fake transport in tests without a real
/// network. `AnyObject`-bound so the `===` identity checks (which tell a
/// superseded receive loop apart from the current socket) keep working on the
/// existential type.
protocol HermesWebSocket: AnyObject {
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: HermesWebSocket {}

/// Produces sockets for a `HermesClient` and owns the underlying session.
/// `makeSocket` wires the handshake callbacks (`onOpen` / `onCloseBeforeOpen`,
/// mirroring `URLSessionWebSocketDelegate`); `invalidate` tears the session
/// down. The production impl is a faithful extraction of the client's former
/// inline `URLSession` logic; tests supply a fake. All methods are invoked from
/// `HermesClient` on the MainActor; the protocol is left nonisolated so the
/// `URLSessionWebSocketTransport` default doesn't force closure-isolation hoops.
protocol HermesWebSocketTransport: AnyObject {
    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket

    func invalidate()

    /// The HTTP status that refused `socket`'s upgrade (a refused redirect's
    /// 3xx, or a final non-101 answer); nil when there was none.
    func handshakeStatus(for socket: any HermesWebSocket) -> Int?

    /// Where a refused redirect of `socket`'s upgrade pointed; nil when it
    /// wasn't redirected.
    func refusedRedirectTarget(for socket: any HermesWebSocket) -> URL?
}

extension HermesWebSocketTransport {
    func handshakeStatus(for socket: any HermesWebSocket) -> Int? { nil }
    func refusedRedirectTarget(for socket: any HermesWebSocket) -> URL? { nil }
}

/// Production transport: one `URLSession` per socket, delegate-driven
/// handshake. The session is ephemeral and cookie-less: the upgrade carries
/// only what the request builder put on it (the ticket, proxy headers and,
/// in native mode, the dashboard's bearer), and a redirect is never
/// followed.
final class URLSessionWebSocketTransport: HermesWebSocketTransport {
    /// Explicit incoming-message bound for the production socket. URLSession's
    /// own default (1 MiB) closes the connection with close code 1009 as soon
    /// as a single WebSocket message exceeds it, which is how resuming a large
    /// session — one huge `session.resume` frame — used to kill Conduit's
    /// connection in a reconnect loop (issue #106). The compact resume keeps
    /// transcript-sized payloads off the socket, but other frames can still
    /// be large (Hermes sends a tool's whole result in `tool.complete`): a
    /// bot that sent videos made 4 MiB too small, and the socket closed with
    /// 1009 after each of its replies. 64 MiB takes those while staying
    /// bounded.
    static let maximumMessageSize = 64 * 1024 * 1024

    private var session: URLSession?
    private var delegate: DashboardWebSocketDelegate?
    /// The refused upgrade's status, handed over as the socket ends before
    /// opening: the delegate forgets its own record at that moment, and
    /// `handshakeStatus(for:)` is read later, on the main actor.
    private let refusalLock = NSLock()
    private var refusedStatus: Int?
    private var refusedTarget: URL?

    /// URLSession only confirms the WebSocket handshake through its delegate.
    /// The client must not issue session RPCs or paint a green indicator
    /// before `onOpen`, otherwise a just-opened socket can race its first
    /// `session.resume`. A refused upgrade ends in `onCloseBeforeOpen` at
    /// once, with its status readable through `handshakeStatus(for:)`.
    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket {
        let delegate = DashboardWebSocketDelegate()
        let session = URLSession(
            configuration: DashboardWebSocketSessionPolicy.configuration(waitsForConnectivity: true),
            delegate: delegate,
            delegateQueue: nil
        )
        self.session = session
        self.delegate = delegate
        refusalLock.lock()
        refusedStatus = nil
        refusedTarget = nil
        refusalLock.unlock()
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        delegate.register(task, handlers: .init(
            onOpen: { [weak task] in if let task { onOpen(task) } },
            onEndBeforeOpen: { [weak self, weak task] status, target in
                if let self, let status {
                    self.refusalLock.lock()
                    self.refusedStatus = status
                    self.refusedTarget = target
                    self.refusalLock.unlock()
                }
                if let task { onCloseBeforeOpen(task) }
            }
        ))
        return task
    }

    func invalidate() {
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }

    func handshakeStatus(for socket: any HermesWebSocket) -> Int? {
        guard let task = socket as? URLSessionWebSocketTask else { return nil }
        if let status = delegate?.handshakeStatus(of: task) { return status }
        // The last socket made here: a recorded refusal is this socket's.
        refusalLock.lock()
        defer { refusalLock.unlock() }
        return refusedStatus
    }

    func refusedRedirectTarget(for socket: any HermesWebSocket) -> URL? {
        guard socket is URLSessionWebSocketTask else { return nil }
        refusalLock.lock()
        defer { refusalLock.unlock() }
        return refusedTarget
    }
}

// MARK: - HermesClient

@MainActor
final class HermesClient: ObservableObject {

    private let logger = Logger(subsystem: "com.milim.relay", category: "HermesClient")

    // Published state for SwiftUI views
    @Published private(set) var isConnected = false

    // Non-published internal state
    private var socket: (any HermesWebSocket)?
    private var transport: (any HermesWebSocketTransport)?
    private let transportFactory: @MainActor () -> any HermesWebSocketTransport
    private var requestId = 0
    private var pending = [Int: PendingRequest]()
    /// Server→client request ids this client has presented and not yet
    /// answered (or seen withdrawn). Not cleared by `connect()`, but AppState
    /// builds a fresh client per reconnect, so in practice this is rebuilt
    /// from `session.resume`'s `open_requests` (same ids) on each connection.
    private var openServerRequestIDs = Set<String>()
    /// Approval server request id (`srq-…`) → the approval queue
    /// `request_id` its card is keyed by (and the session the request named),
    /// so `request.cancel` can reach it. Rebuilt like `openServerRequestIDs`.
    private var approvalQueueIDs = [String: (queueID: String, sessionId: String)]()
    /// Clarify / input-prompt server request id → the session the request
    /// named, the fallback for a `request.cancel` whose envelope omits
    /// `session_id`.
    private var clarifySessions = [String: String]()
    /// The socket `client.capabilities` was sent on, so a repeated
    /// `gateway.ready` does not advertise twice on one connection.
    private weak var advertisedSocket: AnyObject?
    /// `client.capabilities` → `declines_not_shown`: the gateway counts a
    /// 4404 "not shown here" as one client declining a window-owned request
    /// rather than as its answer.
    private var backendCountsDeclines = false
    /// True between sending `client.capabilities` and its reply, while
    /// `backendCountsDeclines` is not yet known.
    private var capabilityReplyPending = false
    /// Window-owned request ids that arrived while `capabilityReplyPending`:
    /// declined (or not) once the reply says whether declines are counted.
    private var deferredWindowOwnedDeclines: [String] = []
    private var closedIntentionally = false
    private var receiveTask: Task<Void, Never>?
    private var socketHasOpened = false
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openTimeoutTask: Task<Void, Never>?
    /// Keepalive: a `ping` after `keepaliveInterval` without any frame from
    /// the gateway. Tailscale relays, carrier NATs and proxies drop idle
    /// connections without a close, so a quiet socket can be dead for
    /// minutes before the next send finds out. The ping keeps the path warm
    /// and finds a dead one while nobody is waiting on it.
    // nonisolated(unsafe): deinit cancels it; cancel() is thread-safe.
    nonisolated(unsafe) private var keepaliveTask: Task<Void, Never>?
    private var lastInboundAt = Date()
    /// Requests with a large frame (a picture going up) the socket is still
    /// writing, until the write finishes or the request's own budget ends.
    /// One can take a minute on a slow link, and a ping queued behind it
    /// can't be answered before it's through (#1265).
    private var requestsBeingWritten: Set<Int> = []
    /// A frame this size or larger counts as being written until the socket
    /// says it's through; a smaller one goes out at once.
    static let largeFrameBytes = 256 * 1024
    private var isProbing = false
    private let keepaliveInterval: TimeInterval?
    private let backgroundKeepaliveInterval: TimeInterval?
    /// Off screen (audio keeps Conduit running): the longer quiet interval.
    private var keepaliveBackgrounded = false
    private let keepalivePingTimeout: TimeInterval
    private let monitorsPath: Bool
    /// Bumped by every connect(): a connect suspended while its upgrade is
    /// authorized must not install a socket after a newer one began.
    private var connectGeneration: UInt64 = 0

    let connection: HermesConnection
    let profile: String?
    let cloudflareAccess: CloudflareAccessCredentials?
    /// The selected dashboard's upgrade authorization: in cookie mode the
    /// dashboard's own session cookies for this address. Nil keeps the
    /// upgrade to the connection's ticket and proxy headers (tests, legacy
    /// callers).
    let requestAuthorizer: (any DashboardUpgradeAuthorizing)?

    // Callback for stream events (set by AppState)
    var onEvent: ((StreamEvent) -> Void)?
    var onDisconnected: (() -> Void)?

    static let requestTimeout: TimeInterval = 30
    /// An upload's budget: two minutes, or about 1 s for every 64 KB of
    /// request (about 0.5 Mbit/s) if that is longer, the rate a group room's
    /// upload allows, so a large file on a slow link isn't cut off (#1265).
    static let minimumUploadTimeout: TimeInterval = 120
    static func uploadTimeout(forPayloadCharacters count: Int) -> TimeInterval {
        max(minimumUploadTimeout, TimeInterval(count) / 64_000)
    }
    static let promptSubmitTimeout: TimeInterval = 180 // 3 minutes
    static let titleGenerationTimeout: TimeInterval = 90
    /// The legacy full-transcript resume is the RPC most likely to carry the
    /// largest payload over the slowest connections (issue #106 follow-up),
    /// so it gets a bounded-but-generous budget instead of the ordinary
    /// request timeout.
    static let legacyResumeTimeout: TimeInterval = 60
    /// Budget for the `session.active_list` liveness probe. It sits on
    /// latency-sensitive paths — the foreground refresh and the pre-send
    /// stale-idle correction — so a stalled gateway must fail it fast instead
    /// of holding the composer for the generic request timeout. 8s matches
    /// the old `session.list` health-check budget; a timed-out probe takes
    /// the same fallback paths as any other probe failure.
    static let livenessProbeTimeout: TimeInterval = 8
    /// Budget for the foreground `ping` (`healthCheck`). See there.
    static let pingTimeout: TimeInterval = 5
    /// Quiet time before a keepalive `ping` (PollCadence explains the 30 s
    /// against Hermes' own 20 s socket ping and a proxy's 60 s idle limit).
    static let defaultKeepaliveInterval: TimeInterval = PollCadence.keepaliveForeground
    /// The same while Conduit is off screen and audio keeps it running.
    static let defaultBackgroundKeepaliveInterval: TimeInterval = PollCadence.keepaliveBackground
    /// A keepalive ping waits longer than the foreground one: nobody is
    /// waiting on it, and a relayed path can be slow without being dead.
    static let keepalivePingTimeout: TimeInterval = 10
    /// Dedicated budget for `session.compress`. Manual compression is
    /// LLM-bound and routinely outlives the generic request timeout on large
    /// sessions, while the gateway keeps compressing after the client gives
    /// up. Its compute-host wait alone runs for up to
    /// `compression.context_total_ceiling_seconds + 30s`, capped at 630s
    /// (upstream `tui_gateway/compute_host_bridge.py`
    /// `_COMPUTE_HOST_COMPRESS_WAIT_CAP_SECS`), and then answers
    /// `status: "pending"` rather than an error — so this budget must sit
    /// above that cap or the client reports a false timeout while the host is
    /// still compressing (upstream #97948; Hermes Desktop parity:
    /// `SESSION_COMPRESS_TIMEOUT_MS = 660_000`).
    static let sessionCompressTimeout: TimeInterval = 660
    /// Approval queue hydration is optional recovery context. It must never
    /// hold foreground restoration behind the ordinary RPC timeout.
    static let pendingApprovalsTimeout: TimeInterval = 3

    /// Non-trapping exact `Int` extraction. `Int(Double)` traps outside the
    /// Int64 range, and numeric fields can be gateway-authored — a hostile or buggy
    /// payload must degrade to invalid response or unknown, never crash the client.
    /// Non-integer doubles, NaN, infinity, and out-of-range numbers are rejected:
    /// only exact whole values convert.
    nonisolated static func exactIntValue(_ value: AnyCodable?) -> Int? {
        guard case .number(let n)? = value else { return nil }
        guard n.isFinite,
              n >= -9_223_372_036_854_775_808.0, // Int.min == -2^63, exact as Double
              n < 9_223_372_036_854_775_808.0,   // 2^63 itself already overflows
              n == n.rounded(.towardZero) else {
            return nil
        }
        return Int(n)
    }

    init(
        connection: HermesConnection,
        profile: String? = nil,
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        requestAuthorizer: (any DashboardUpgradeAuthorizing)? = nil,
        transportFactory: @escaping @MainActor () -> any HermesWebSocketTransport = { URLSessionWebSocketTransport() },
        keepaliveInterval: TimeInterval? = HermesClient.defaultKeepaliveInterval,
        backgroundKeepaliveInterval: TimeInterval? = HermesClient.defaultBackgroundKeepaliveInterval,
        keepalivePingTimeout: TimeInterval = HermesClient.keepalivePingTimeout,
        monitorsPath: Bool = true
    ) {
        self.monitorsPath = monitorsPath
        self.keepaliveInterval = keepaliveInterval
        // Never shorter than the foreground interval (tests pass short ones).
        self.backgroundKeepaliveInterval = keepaliveInterval.map { max($0, backgroundKeepaliveInterval ?? $0) }
        self.keepalivePingTimeout = keepalivePingTimeout
        self.connection = connection
        self.profile = profile
        self.cloudflareAccess = cloudflareAccess
        self.requestAuthorizer = requestAuthorizer
        self.transportFactory = transportFactory
    }

    deinit {
        keepaliveTask?.cancel()
    }

    // MARK: - Connection

    func connect() async throws {
        // Tear down any prior connection in full before installing a new one —
        // this mirrors disconnect()'s cleanup. Cancelling the receive task alone
        // is not enough: URLSessionWebSocketTask.receive() does not honor
        // cooperative cancellation, so a superseded loop stays alive until its
        // socket actually errors; cancelling the socket + invalidating the
        // session forces that error, after which the loop's identity guard
        // no-ops its late catch. Resuming the open continuation and failing
        // pending RPCs here also covers the case where the new connect() throws
        // before its own waitForSocketOpen (e.g. invalid URL) — without it the
        // prior connect() would hang forever and its RPCs would wait out their
        // own timers. (AppState makes a fresh HermesClient per reconnect and
        // disconnects the old one first, so this is defense-in-depth against an
        // intra-instance reconnect — which no caller does today.)
        receiveTask?.cancel()
        receiveTask = nil
        stopKeepalive()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        transport?.invalidate()
        transport = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: HermesError.connectionClosed)
        openContinuation = nil
        isConnected = false
        failAllPendingRequests(with: HermesError.connectionClosed)
        // Per-connection capability state. The open-request bookkeeping is
        // not cleared here; AppState builds a fresh client per reconnect, so
        // it is rebuilt from `session.resume` on that client.
        advertisedSocket = nil
        backendCountsDeclines = false
        capabilityReplyPending = false
        deferredWindowOwnedDeclines = []

        closedIntentionally = false
        socketHasOpened = false
        connectGeneration &+= 1
        let generation = connectGeneration

        let request = try await upgradeRequest(ticket: connection.ticket, generation: generation)
        let socket = try await openSocket(with: request, generation: generation)
        isConnected = true
        logger.notice("WebSocket handshake completed")

        // Start listening for messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(on: socket)
        }
        startKeepalive(for: socket)
    }

    /// Hands this client's open socket to `successor`, a client for another
    /// profile on the same dashboard, instead of closing it. The socket
    /// isn't tied to a profile (every request names its own), so a profile
    /// switch skips a new ticket and socket, two seconds and more on a slow
    /// path (#1442). This client ends as if disconnected: its requests still
    /// waiting fail, and frames still coming reach only `successor`, whose
    /// request ids carry on from this client's so a late answer to one of
    /// this client's requests matches nothing there. False, with nothing
    /// changed, when there's no open socket to hand on.
    @discardableResult
    func handOffSocket(to successor: HermesClient) -> Bool {
        guard canHandOffSocket, let socket,
              successor !== self, successor.socket == nil,
              successor.connection.baseUrl == connection.baseUrl else { return false }
        closedIntentionally = true
        stopKeepalive()
        failAllPendingRequests(with: HermesError.connectionClosed)
        self.socket = nil
        isConnected = false
        socketSuccessor = successor
        successor.adoptSocket(socket, transport: transport, from: self)
        transport = nil
        // Not cancelled: the receive it runs brings the socket's next frame
        // to the successor, and a later disconnect() must not end it as a drop.
        receiveTask = nil
        return true
    }

    /// Whether `handOffSocket` would hand the socket on: it's open, no large
    /// frame is still being written (the successor's pings would wait
    /// behind it and close the socket, #1265), and the gateway has answered
    /// this socket's `client.capabilities` (its reply would come to a
    /// client that never asked, and the successor wouldn't advertise again).
    var canHandOffSocket: Bool {
        socket != nil && isConnected && socketHasOpened && !closedIntentionally
            && requestsBeingWritten.isEmpty && !capabilityReplyPending
    }

    private func adoptSocket(
        _ socket: any HermesWebSocket,
        transport: (any HermesWebSocketTransport)?,
        from predecessor: HermesClient
    ) {
        self.socket = socket
        self.transport = transport
        requestId = max(requestId, predecessor.requestId)
        connectGeneration &+= 1
        socketHasOpened = true
        closedIntentionally = false
        // The gateway already has this socket's capabilities.
        advertisedSocket = predecessor.advertisedSocket
        backendCountsDeclines = predecessor.backendCountsDeclines
        // Server requests still open on the socket come here, so a later
        // request.cancel still withdraws their cards.
        openServerRequestIDs.formUnion(predecessor.openServerRequestIDs)
        approvalQueueIDs.merge(predecessor.approvalQueueIDs) { mine, _ in mine }
        clarifySessions.merge(predecessor.clarifySessions) { mine, _ in mine }
        isConnected = true
        startKeepalive(for: socket)
        // A receive already waiting on the socket (URLSession's can't be
        // called off) brings its frame here, and this client reads on from
        // it; a second receive could take a frame out of turn.
        if predecessor.isReceiving || predecessor.awaitsHandedOnFrame {
            awaitsHandedOnFrame = true
        } else {
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(on: socket)
            }
        }
    }

    /// The client this one handed its socket to. Held while this client's
    /// last receive waits, so its frame always finds the client holding
    /// the socket, however many switches ago it was handed on.
    private var socketSuccessor: HermesClient?
    /// Set while a predecessor's receive is still waiting on this client's
    /// socket: its frame comes here, then this client reads on.
    private var awaitsHandedOnFrame = false
    /// A receive loop is running: its receive may be waiting on the socket.
    private var isReceiving = false

    /// The successor, let go once this client's last receive has ended.
    private func takeSocketSuccessor() -> HermesClient? {
        defer { socketSuccessor = nil }
        return socketSuccessor
    }

    /// A frame read on `socket` by a client it was handed on from: the
    /// client holding it now handles it and reads on.
    private func receiveHandedOn(_ frame: DecodedFrame, on socket: any HermesWebSocket) {
        guard self.socket === socket else {
            socketSuccessor?.receiveHandedOn(frame, on: socket)
            return
        }
        guard awaitsHandedOnFrame else { return }
        awaitsHandedOnFrame = false
        lastInboundAt = Date()
        handleMessage(frame)
        guard self.socket === socket else { return }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(on: socket)
        }
    }

    /// The receive a predecessor still had waiting on `socket` failed.
    private func receiveFailedHandedOn(on socket: any HermesWebSocket) {
        guard self.socket === socket else {
            socketSuccessor?.receiveFailedHandedOn(on: socket)
            return
        }
        awaitsHandedOnFrame = false
        receiveFailed(on: socket)
    }

    /// The `/api/ws` upgrade for `ticket`: proxy headers first, then what
    /// the selected dashboard's authorizer adds (its own session cookies, or
    /// a native sign-in's bearer).
    private func upgradeRequest(ticket: String, generation: UInt64) async throws -> URLRequest {
        let url: URL
        do {
            url = try ConnectionURLPolicy.webSocketURL(
                baseURL: connection.baseUrl,
                path: "/api/ws",
                queryItems: [URLQueryItem(name: "ticket", value: ticket)]
            )
        } catch {
            throw HermesError.invalidUrl
        }
        var request = URLRequest(url: url)
        request = request.applyingProxyHeaders(cloudflare: cloudflareAccess)
        // Lets the notifier plugin tell Conduit's opens from Desktop's (#454).
        request.setValue("conduit", forHTTPHeaderField: "X-Conduit-Client")
        guard let requestAuthorizer else { return request }
        let authorized = try await requestAuthorizer.authorizeUpgrade(request)
        try ensureCurrentConnect(generation)
        return authorized
    }

    private func ensureCurrentConnect(_ generation: UInt64) throws {
        guard generation == connectGeneration, !closedIntentionally else {
            throw HermesError.connectionClosed
        }
    }

    private func openSocket(with request: URLRequest, generation: UInt64) async throws -> any HermesWebSocket {
        try ensureCurrentConnect(generation)
        let transport = transportFactory()
        self.transport = transport
        let socket = transport.makeSocket(
            request: request,
            onOpen: { [weak self] socket in Task { @MainActor in self?.didOpen(socket) } },
            onCloseBeforeOpen: { [weak self] socket in Task { @MainActor in self?.didClose(socket) } }
        )
        self.socket = socket
        socket.resume()
        try await waitForSocketOpen(socket)
        return socket
    }

    // MARK: - Keepalive

    /// Conduit went off screen (true) or came back (false). Off screen the
    /// socket only stays open while audio keeps the app running, and
    /// nothing on screen waits on it: the keepalive pings less often.
    func setKeepaliveBackgrounded(_ backgrounded: Bool) {
        guard backgrounded != keepaliveBackgrounded else { return }
        keepaliveBackgrounded = backgrounded
        if let socket, keepaliveTask != nil { startKeepaliveLoop(for: socket) }
    }

    private var currentKeepaliveInterval: TimeInterval? {
        keepaliveBackgrounded ? backgroundKeepaliveInterval : keepaliveInterval
    }

    private func startKeepalive(for socket: any HermesWebSocket) {
        stopKeepalive()
        guard let interval = keepaliveInterval, interval > 0 else { return }
        lastInboundAt = Date()
        startKeepaliveLoop(for: socket)
    }

    /// The network path changed and is usable (AppState hears it from the
    /// app's one path monitor). A change (Wi-Fi to cellular, the VPN tunnel
    /// coming back) usually leaves the old TCP connection dead: check it at
    /// once instead of at the next quiet interval.
    func networkPathChanged() {
        guard monitorsPath, keepaliveTask != nil, let socket else { return }
        Task { @MainActor [weak self] in await self?.probe(socket) }
    }

    /// Sleeps until the socket has been quiet for the interval, then pings.
    /// Any frame from the gateway pushes the deadline back, so a busy socket
    /// is never pinged and a quiet one wakes once per interval.
    private func startKeepaliveLoop(for socket: any HermesWebSocket) {
        keepaliveTask?.cancel()
        guard let interval = currentKeepaliveInterval, interval > 0 else { return }
        // Spelled out though Task inherits it here: the loop reads socket
        // state, which lives on the main actor.
        // `self` is weak across the sleeps: a released client ends the loop
        // instead of living until the next deadline.
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let remaining = self?.keepaliveQuietTimeLeft(on: socket, interval: interval) else { return }
                if remaining > 0 {
                    // A little past the deadline, so a wake a hair early
                    // doesn't sleep a second time.
                    try? await Task.sleep(for: .seconds(remaining + 0.05))
                    continue
                }
                guard !Task.isCancelled,
                      let stillQuiet = await self?.keepaliveProbe(socket, interval: interval) else { return }
                // A probe already under way returns without a ping: wait an
                // interval rather than spin.
                if stillQuiet { try? await Task.sleep(for: .seconds(interval)) }
            }
        }
    }

    /// How long until the socket has been quiet for `interval`, or nil once
    /// it is no longer this client's socket.
    private func keepaliveQuietTimeLeft(on socket: any HermesWebSocket, interval: TimeInterval) -> TimeInterval? {
        guard self.socket === socket else { return nil }
        // A frame still being written: a ping would wait behind it and look
        // lost, closing the socket under the upload. Look again later.
        if !requestsBeingWritten.isEmpty { return interval }
        return interval - Date().timeIntervalSince(lastInboundAt)
    }

    /// Pings a quiet socket. An answered ping stamps `lastInboundAt`; a lost
    /// one closes the socket, which ends the loop. Returns whether the socket
    /// is still quiet, or nil once it is no longer this client's.
    private func keepaliveProbe(_ socket: any HermesWebSocket, interval: TimeInterval) async -> Bool? {
        guard self.socket === socket else { return nil }
        await probe(socket)
        return Date().timeIntervalSince(lastInboundAt) >= interval
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// Pings the gateway, once more if the first goes unanswered, and closes
    /// the socket when neither does. Closing fails the receive loop, which
    /// reports the disconnect so AppState reconnects as for any other drop.
    private func probe(_ socket: any HermesWebSocket) async {
        guard !isProbing, self.socket === socket, !closedIntentionally else { return }
        // Behind a large frame still being written the pings can't be
        // answered in time (#1265). A path change that really killed the
        // connection fails the write itself, and the request's own budget
        // answers for the socket meanwhile.
        guard requestsBeingWritten.isEmpty else { return }
        isProbing = true
        defer { isProbing = false }
        let probeStarted = Date()
        for _ in 0..<2 {
            do {
                try await ping(timeout: keepalivePingTimeout)
                return
            } catch HermesError.connectionClosed, HermesError.notConnected {
                return
            } catch {
                guard self.socket === socket, !closedIntentionally else { return }
                // Any frame since the probe began proves the socket alive.
                if lastInboundAt > probeStarted { return }
            }
        }
        guard self.socket === socket, !closedIntentionally, requestsBeingWritten.isEmpty else { return }
        logger.error("Keepalive ping unanswered twice; closing the socket")
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func waitForSocketOpen(_ socket: any HermesWebSocket) async throws {
        // The prior continuation (if any) is already resumed by connect()'s
        // teardown before we reach here, so just install this one.
        try await withCheckedThrowingContinuation { continuation in
            openContinuation = continuation
            openTimeoutTask?.cancel()
            openTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.failSocketOpen(socket, error: HermesError.timeout(AppLocalization.string("WebSocket connection")))
            }
        }
    }

    private func didOpen(_ socket: any HermesWebSocket) {
        guard self.socket === socket, !socketHasOpened else { return }
        socketHasOpened = true
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume()
        openContinuation = nil
    }

    private func didClose(_ socket: any HermesWebSocket) {
        guard self.socket === socket, !socketHasOpened else { return }
        // A refused upgrade says why through its status and, for a redirect
        // (never followed), where it pointed: a sign-in wants a browser
        // session. Anything else stays a closed connection for the
        // reconnect path.
        let refusal = DashboardSocketHandshakeError.failure(
            status: transport?.handshakeStatus(for: socket),
            redirectTarget: transport?.refusedRedirectTarget(for: socket),
            dashboardURL: connection.baseUrl
        )
        failSocketOpen(socket, error: refusal ?? HermesError.connectionClosed)
    }

    private func failSocketOpen(_ socket: any HermesWebSocket, error: Error) {
        guard self.socket === socket else { return }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        socket.cancel(with: .goingAway, reason: nil)
        self.socket = nil
        transport?.invalidate()
        transport = nil
        isConnected = false
        openContinuation?.resume(throwing: error)
        openContinuation = nil
    }

    private func receiveLoop(on socket: any HermesWebSocket) async {
        guard self.socket === socket else { return }
        isReceiving = true
        defer { isReceiving = false }

        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                // A reconnect replaces `self.socket`; if this loop has been
                // superseded, drop the frame rather than dispatch it —
                // `handleMessage` has no identity check of its own and could
                // otherwise fire `onEvent`/resolve pending RPCs for the new
                // connection. Same guard the catch uses below. A socket
                // handed to another profile's client goes on there, frame
                // and all.
                guard self.socket === socket else {
                    if let next = takeSocketSuccessor(), let data = Self.frameData(message) {
                        next.receiveHandedOn(await Self.decodeInBackground(data), on: socket)
                    }
                    break
                }
                lastInboundAt = Date()
                guard let data = Self.frameData(message) else { continue }
                let frame: DecodedFrame
                if data.count >= Self.backgroundDecodeThreshold {
                    // A big frame (a resume, a history page, a tool's
                    // output, often from a chat in the background) is read
                    // off the main actor so it can't stall a scroll. The
                    // loop waits for it, so frames still apply in order.
                    frame = await Self.decodeInBackground(data)
                    guard self.socket === socket else {
                        takeSocketSuccessor()?.receiveHandedOn(frame, on: socket)
                        break
                    }
                } else {
                    frame = DecodedFrame(data)
                }
                handleMessage(frame)
            } catch {
                // Socket closed or errored
                logger.error("WebSocket receive failed: \(LogRedaction.message(error), privacy: .public)")
                // Only tear down if this loop still owns the current socket.
                // A reconnect replaces `self.socket` and spawns a new loop; an
                // unguarded late catch from the superseded loop would mark the
                // healthy new connection disconnected and fail its in-flight
                // RPCs. didOpen/didClose/failSocketOpen guard the same way.
                // A socket handed on fails for the client holding it.
                guard self.socket === socket else {
                    takeSocketSuccessor()?.receiveFailedHandedOn(on: socket)
                    break
                }
                receiveFailed(on: socket)
                break
            }
        }
    }

    nonisolated private static func frameData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let bytes): return bytes
        case .string(let text): return Data(text.utf8)
        @unknown default: return nil
        }
    }

    private func receiveFailed(on socket: any HermesWebSocket) {
        guard self.socket === socket else { return }
        isConnected = false
        stopKeepalive()
        // No response can ever arrive on a dead socket; failing the
        // in-flight requests here keeps awaiting UI from hanging for
        // the remainder of each request's timeout.
        failAllPendingRequests(with: HermesError.connectionClosed)
        // Drop the dead socket: its `closeCode` stays `.invalid` after
        // a receive error, so leaving it installed would let `rpc`
        // re-issue against it and hang until its own timeout.
        self.socket = nil
        if !closedIntentionally {
            onDisconnected?()
        }
    }

    /// Frames this size or larger are decoded off the main actor. Stream
    /// deltas and RPC acks are far smaller and stay on the fast path.
    static let backgroundDecodeThreshold = 16 * 1024

    nonisolated private static func decodeInBackground(_ data: Data) async -> DecodedFrame {
        DecodedFrame(data)
    }

    private func handleMessage(_ frame: DecodedFrame) {
        guard let json = frame.response else {
            logger.error("Dropped undecodable inbound WebSocket frame (\(frame.byteCount) bytes)")
            return
        }

        // Server→client request: carries both `method` and `id`. It must be
        // routed before response matching — it is not an answer to any of
        // this client's requests, and an integer id could otherwise collide
        // with (and wrongly settle) one of them.
        if let method = json.method, method != "event", let requestID = json.id {
            // Hermes mints string ids only (like the reference client, any
            // other id is ignored — never answered, never matched to a
            // pending RPC of ours).
            guard case .string = requestID else {
                logger.debug("Ignored server request \(method, privacy: .public) with a non-string id")
                return
            }
            handleServerRequest(id: requestID, method: method, params: json.params?.objectValue ?? [:])
            return
        }

        // Handle RPC response (has id, no method)
        if json.method == nil, let requestID = json.id {
            guard case .int(let id) = requestID,
                  let pending = pending.removeValue(forKey: id) else {
                logger.debug("Received unmatched RPC response id \(String(describing: requestID.wireValue), privacy: .public)")
                return
            }
            logger.notice("Received RPC response id \(id)")
            pending.timer?.invalidate()
            if let error = json.error {
                pending.continuation.resume(throwing: error)
            } else {
                pending.continuation.resume(returning: json.result ?? .null)
            }
            return
        }

        // Handle stream event notification
        if json.method == "event", let params = json.params {
            let eventObject = params.objectValue
            switch eventObject?["type"]?.stringValue {
            case "gateway.ready":
                advertiseClientCapabilities()
            case "request.cancel":
                // Bookkeeping only: the request is closed whatever the
                // reason. What the card shows is decided by the event.
                let payload = eventObject?["payload"]?.objectValue
                if let id = payload?["id"]?.stringValue {
                    openServerRequestIDs.remove(id)
                    if let session = clarifySessions.removeValue(forKey: id),
                       (eventObject?["session_id"]?.stringValue ?? "").isEmpty,
                       var patched = eventObject {
                        patched["session_id"] = .string(session)
                        handleStreamEvent(params: .object(patched))
                        return
                    }
                    if let approval = approvalQueueIDs.removeValue(forKey: id) {
                        let envelopeSession = eventObject?["session_id"]?.stringValue ?? ""
                        onEvent?(.approvalWithdrawn(
                            sessionId: envelopeSession.isEmpty ? approval.sessionId : envelopeSession,
                            requestId: approval.queueID,
                            reason: payload?["reason"]?.stringValue ?? ""
                        ))
                    }
                }
            default:
                break
            }
            if let event = frame.event {
                onEvent?(event)
            }
        } else {
            logger.debug("Received non-event WebSocket notification without an RPC id")
        }
    }

    // MARK: - Server→client requests

    /// Tells the gateway, once per connection, that this client answers
    /// server→client JSON-RPC requests. Hermes (#112548) never sends an
    /// approval / clarify / sudo / secret request to a WebSocket client that
    /// has not said so: it withdraws the approval ("the attached client
    /// cannot answer approval requests") and the command is blocked. Sent on
    /// `gateway.ready`, which the gateway writes first on every new socket.
    /// A gateway that predates server requests answers -32601; ignored.
    ///
    /// Ordering: nothing waits for this before `session.resume`, and nothing
    /// needs to. The gateway computes a resume's `open_requests` whatever the
    /// client advertised, and those replays arrive in the resume response.
    /// The capability only gates *new* live requests, and it goes out on the
    /// first frame of the connection, like the reference `json-rpc-channel`.
    private func advertiseClientCapabilities() {
        guard let socket = self.socket, advertisedSocket !== socket else { return }
        advertisedSocket = socket
        capabilityReplyPending = true
        Task { @MainActor [weak self] in
            guard let self, self.socket === socket else { return }
            do {
                let result = try await self.rpc("client.capabilities", params: ["server_requests": true], scoped: false)
                guard self.socket === socket else { return }
                self.backendCountsDeclines = result.objectValue?["declines_not_shown"]?.boolValue == true
                self.logger.notice("Advertised server_requests capability")
            } catch {
                self.logger.notice("client.capabilities not accepted: \(LogRedaction.message(error), privacy: .public)")
                // Let a later gateway.ready on this socket try again.
                if self.advertisedSocket === socket { self.advertisedSocket = nil }
            }
            guard self.socket === socket else { return }
            self.capabilityReplyPending = false
            let deferred = self.deferredWindowOwnedDeclines
            self.deferredWindowOwnedDeclines = []
            if self.backendCountsDeclines {
                for id in deferred {
                    self.writeServerRequestReply(id: .string(id), error: (Self.notShownCode, "no Conduit window shows this session"))
                }
            }
        }
    }

    /// One inbound server→client request (`tui_gateway/server_requests.py`).
    ///
    /// - `approval` becomes the existing approval card. Its params carry the
    ///   approval queue's own `request_id`, and the card still answers through
    ///   `approval.respond`: resolving the queue entry makes the gateway
    ///   withdraw this request itself (`request.cancel`, reason `resolved`),
    ///   so no response frame is written for it.
    /// - `clarify` becomes the existing clarify card keyed by the server
    ///   request id; `respondToClarification` answers it with a response
    ///   frame (single question) or `clarify.lock` (batch questions).
    /// - `sudo`, `secret`, `vault.unlock_prompt`, `vault.save_login` and
    ///   `vault.code` become an input card; `respondToInputPrompt` answers
    ///   `{value}` ('' = skip).
    /// - Everything else (desktop-only bridges) has no UI here and is
    ///   declined, so the tool fails fast instead of waiting out its
    ///   deadline.
    private func handleServerRequest(id: JsonRpcID, method: String, params: [String: AnyCodable]) {
        guard case .string(let requestID) = id, !requestID.isEmpty else { return }
        let sessionId = params["session_id"]?.stringValue ?? ""
        logger.notice("Received server request \(method, privacy: .public) id \(requestID, privacy: .public)")
        switch method {
        case "approval":
            guard let activity = MessageNormalizer.approvalActivity(from: params, sessionId: sessionId) else {
                writeServerRequestReply(id: id, error: (Self.invalidParamsCode, "approval request without a session"))
                return
            }
            openServerRequestIDs.insert(requestID)
            if let queueID = activity.requestId {
                approvalQueueIDs[requestID] = (queueID, sessionId)
            }
            onEvent?(.approval(sessionId: sessionId, activity: activity))
        case "clarify":
            guard let activity = MessageNormalizer.pendingClarifyActivity(
                from: Self.clarifyPayload(serverRequestID: requestID, params: params)
            ) else {
                writeServerRequestReply(id: id, error: (Self.invalidParamsCode, "clarify request without a question"))
                return
            }
            openServerRequestIDs.insert(requestID)
            clarifySessions[requestID] = sessionId
            onEvent?(.clarify(sessionId: sessionId, activity: activity))
        case _ where InputPromptActivity.Kind(rawValue: method) != nil:
            guard let activity = InputPromptActivity.from(requestId: requestID, method: method, params: params) else {
                writeServerRequestReply(id: id, error: (Self.invalidParamsCode, "\(method) request without the fields its card needs"))
                return
            }
            openServerRequestIDs.insert(requestID)
            clarifySessions[requestID] = sessionId
            onEvent?(.inputPrompt(sessionId: sessionId, activity: activity))
        default:
            declineServerRequest(id: id, method: method)
        }
    }

    /// Methods this client presents (anything else is declined).
    static func handlesServerRequest(_ method: String) -> Bool {
        method == "clarify" || method == "approval" || InputPromptActivity.Kind(rawValue: method) != nil
    }

    /// Requests only the Hermes Desktop window showing the session can
    /// answer (`server_requests.py`, "window-owned bridges").
    static let windowOwnedServerRequests: Set<String> = [
        "preview.read", "preview.act", "terminal.read", "window.read", "tour"
    ]

    /// Declines a request this client has no UI for, so the tool fails fast
    /// instead of waiting out its deadline. A window-owned request gets the
    /// 4404 "not shown here" decline, which settles only once every attached
    /// client declined — a -32601 would settle it at once and take it away
    /// from a Desktop window on the same session. A gateway that does not
    /// count declines would settle on any error, so there it gets none
    /// (reference: `apps/shared/src/json-rpc-channel.ts`).
    private func declineServerRequest(id: JsonRpcID, method: String) {
        if Self.windowOwnedServerRequests.contains(method) {
            guard backendCountsDeclines else {
                // Until the capability reply says whether declines are
                // counted, hold the decline rather than drop it.
                if capabilityReplyPending, case .string(let requestID) = id {
                    deferredWindowOwnedDeclines.append(requestID)
                }
                return
            }
            writeServerRequestReply(id: id, error: (Self.notShownCode, "no Conduit window shows this session"))
        } else {
            writeServerRequestReply(id: id, error: (Self.methodNotFoundCode, "no handler for server request: \(method)"))
        }
    }

    /// The legacy `clarify.request` payload shape for a `clarify` server
    /// request: its params, keyed by the server request id (which the
    /// response frame and `clarify.lock` both address).
    static func clarifyPayload(serverRequestID: String, params: [String: AnyCodable]) -> [String: AnyCodable] {
        var payload = params
        payload["request_id"] = .string(serverRequestID)
        return payload
    }

    /// Whether `requestId` names a server→client request rather than a
    /// legacy `clarify.request` id. Hermes mints `srq-<hex>` ids; the prefix
    /// check covers a card restored before this connection saw the request.
    func isServerRequestID(_ requestId: String) -> Bool {
        openServerRequestIDs.contains(requestId) || requestId.hasPrefix("srq-")
    }

    /// Every `clarify` entry of a resume's `open_requests`, oldest first, as
    /// legacy clarify payloads (locked batch answers ride `answers`).
    static func openClarifyPayloads(in openRequests: AnyCodable?) -> [[String: AnyCodable]] {
        (openRequests?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  object["method"]?.stringValue == "clarify",
                  let id = object["id"]?.stringValue, !id.isEmpty else { return nil }
            return clarifyPayload(serverRequestID: id, params: object["params"]?.objectValue ?? [:])
        }
    }

    static func openRequestIDs(in openRequests: AnyCodable?) -> [String] {
        (openRequests?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let method = object["method"]?.stringValue,
                  method == "clarify" || method == "approval"
                      || InputPromptActivity.Kind(rawValue: method) != nil,
                  let id = object["id"]?.stringValue, !id.isEmpty else { return nil }
            return id
        }
    }

    static let methodNotFoundCode = -32601
    static let notShownCode = 4404
    static let invalidParamsCode = -32602

    private func serverRequestReplyText(id: JsonRpcID, result: [String: Any]?, error: (code: Int, message: String)?) -> String? {
        var frame: [String: Any] = ["jsonrpc": "2.0", "id": id.wireValue]
        if let error {
            frame["error"] = ["code": error.code, "message": error.message]
        } else {
            frame["result"] = result ?? [:]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fire-and-forget reply (used for declines): the gateway withdraws the
    /// request itself if the frame is lost with the socket.
    private func writeServerRequestReply(id: JsonRpcID, error: (code: Int, message: String)) {
        guard let socket, socket.closeCode == .invalid, isConnected,
              let text = serverRequestReplyText(id: id, result: nil, error: error) else { return }
        socket.send(.string(text)) { [weak self] sendError in
            if let sendError {
                self?.logger.error("Server request reply failed: \(LogRedaction.message(sendError), privacy: .public)")
            }
        }
    }

    /// Answers an open server request with `result`. Throws when the frame
    /// cannot be written so the card can offer a retry; the gateway sends no
    /// acknowledgement for a response frame.
    private func sendServerRequestResult(id requestID: String, result: [String: Any]) async throws {
        guard let socket, socket.closeCode == .invalid, isConnected else {
            throw HermesError.notConnected
        }
        guard let text = serverRequestReplyText(id: .string(requestID), result: result, error: nil) else {
            throw HermesError.invalidResponse
        }
        // Bounded like rpc(): a send completion that never fires must not
        // leave the card submitting forever.
        let once = ResumeOnce()
        let deadline = Self.requestTimeout
        var deadlineTask: Task<Void, Never>?
        defer { deadlineTask?.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            deadlineTask = Task {
                try? await Task.sleep(for: .seconds(deadline))
                guard !Task.isCancelled, once.claim() else { return }
                continuation.resume(throwing: HermesError.timeout("server request reply"))
            }
            socket.send(.string(text)) { error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        openServerRequestIDs.remove(requestID)
    }

    private func handleStreamEvent(params: AnyCodable) {
        if let event = StreamEventParser.parse(params: params) {
            onEvent?(event)
        }
    }

    func disconnect() {
        closedIntentionally = true
        stopKeepalive()
        receiveTask?.cancel()
        receiveTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: HermesError.connectionClosed)
        openContinuation = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        transport?.invalidate()
        transport = nil
        isConnected = false
        failAllPendingRequests(with: HermesError.connectionClosed)
    }

    private func failAllPendingRequests(with error: Error) {
        // The socket is gone, and its frames with it.
        requestsBeingWritten.removeAll()
        for (_, request) in pending {
            request.timer?.invalidate()
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    // MARK: - RPC

    private func rpc(
        _ method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval = requestTimeout,
        scoped: Bool = true
    ) async throws -> AnyCodable {
        // Require both a live socket and a completed handshake. A receive
        // error leaves the socket installed with `closeCode == .invalid`, so
        // closeCode alone would let an RPC ride a dead socket to its timeout.
        guard let socket, socket.closeCode == .invalid, isConnected else {
            throw HermesError.notConnected
        }

        let id = incrementRequestId()
        let scopedParams = scoped ? scopeParams(params) : (params?.isEmpty == false ? params : nil)
        let encodedParams = scopedParams?.mapValues { AnyCodable.from($0) }

        let request = JsonRpcRequest(id: id, method: method, params: encodedParams)
        let body = try JSONEncoder().encode(request)
        logger.notice("Sending RPC id \(id) method \(method, privacy: .public)")

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // Timeout
                let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.requestsBeingWritten.remove(id)
                        if let pending = self?.pending.removeValue(forKey: id) {
                            pending.continuation.resume(throwing: HermesError.timeout(method))
                        }
                    }
                }

                pending[id] = PendingRequest(continuation: continuation, timer: timer)

                // Hermes' established React Native client uses WebSocket text
                // frames (`socket.send(JSON.stringify(...))`). The gateway accepts
                // the connection but does not dispatch binary JSON-RPC frames.
                let text = String(decoding: body, as: UTF8.self)
                let isLarge = body.count >= Self.largeFrameBytes
                if isLarge { requestsBeingWritten.insert(id) }
                socket.send(.string(text)) { [weak self] error in
                    if isLarge { Task { @MainActor in self?.requestsBeingWritten.remove(id) } }
                    if let error {
                        self?.logger.error("RPC send failed for \(method, privacy: .public): \(LogRedaction.message(error), privacy: .public)")
                        Task { @MainActor in
                            if let pending = self?.pending.removeValue(forKey: id) {
                                pending.timer?.invalidate()
                                pending.continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id: id)
            }
        })
    }

    private func cancelPendingRequest(id: Int) {
        // A cancelled request's frame may still be going out: it stays in
        // `requestsBeingWritten` until the socket says the write is through,
        // or at most an upload's minimum budget, as its own timer is gone.
        if requestsBeingWritten.contains(id) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.minimumUploadTimeout))
                self?.requestsBeingWritten.remove(id)
            }
        }
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timer?.invalidate()
        pending.continuation.resume(throwing: CancellationError())
    }

    private func incrementRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func scopeParams(_ params: [String: Any]?) -> [String: Any]? {
        var params = params ?? [:]
        // The client's profile is the DEFAULT scope; a caller-supplied
        // `profile` is explicit intent (Bot Mode addresses another profile's
        // registry) and always wins.
        if params["profile"] == nil, let profile, profile != "default" {
            params["profile"] = profile
        }
        return params.isEmpty ? nil : params
    }

    // MARK: - API Methods

    /// Matches the React Native transport: the default profile uses no
    /// parameters, while every other profile carries its gateway context even
    /// though `session.list` itself has no explicit arguments.
    func sessions() async throws -> [SessionSummary] {
        let result = try await rpc("session.list", params: nil)
        return MessageNormalizer.normalizeSessions(result, profile: profile)
    }

    // MARK: - Bot Mode

    /// THE Bot Mode capability call. A gateway old enough to lack the method
    /// has no Bot Mode; callers classify the thrown error with
    /// `isMissingRPCMethod`. Rows carry `canonical_session`, `last_session`,
    /// `ui_meta['hermes-bots']`, and `has_avatar`. The listing is
    /// gateway-wide (`list_profiles()`), so it is sent UNSCOPED: the
    /// dashboard profile context must never shrink the roster.
    func botRoster() async throws -> BotRosterSnapshot {
        let result = try await rpc("profiles.list", params: nil, scoped: false)
        guard let snapshot = BotRosterDecoder.decode(result) else {
            throw HermesError.invalidResponse
        }
        return snapshot
    }

    /// The bot's canonical-chat registry lookup: the profile's session titled
    /// exactly "Bot Chat", window-free, hidden rows included — the gateway
    /// answers the indexed exact-title scan with at most one row. Explicit
    /// `profile` routing is the identity contract; `scopeParams` never
    /// overrides a caller-supplied profile.
    func findBotChatSession(profile: String) async throws -> [BotChatLookupRow] {
        let result = try await rpc("session.list", params: [
            "profile": profile,
            "title": BotMode.canonicalChatTitle,
            "limit": BotMode.lookupSessionLimit,
            "include_hidden": true
        ])
        guard let rows = BotChatLookupDecoder.decode(result) else {
            throw HermesError.invalidResponse
        }
        return rows
    }

    /// Creates the bot's ONE forever chat: born hidden, titled "Bot Chat",
    /// and always following the profile's CURRENT model/provider config.
    /// Older gateways ignore the unknown `hidden`/`follow_profile_config`
    /// params (upstream behavior). The stored row is lazy until the eager
    /// `session.title` write lands.
    func createBotChatSession(profile: String) async throws -> (sessionId: String, storedSessionId: String?) {
        let result = try await rpc("session.create", params: [
            "cols": 96,
            "source": "desktop",
            "profile": profile,
            "title": BotMode.canonicalChatTitle,
            "hidden": true,
            "follow_profile_config": true
        ])
        let object = result.objectValue ?? [:]
        let sessionId = object["session_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionId.isEmpty else { throw HermesError.invalidResponse }
        let stored = ["stored_session_id", "storedSessionId", "session_key"]
            .compactMap { object[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return (sessionId, stored)
    }

    // MARK: - Bot management
    //
    // Every `profiles.*` write addresses its profile through `name` and is
    // sent UNSCOPED, like `profiles.list`: the dashboard's own profile
    // context must never redirect a write meant for another bot.

    /// `profiles.create` with `BotCreateRequest.params`. A cloning create
    /// copies the source's config, so it can take longer than a fresh one.
    @discardableResult
    func createBotProfile(params: [String: Any]) async throws -> AnyCodable {
        try await rpc("profiles.create", params: params, timeout: 60, scoped: false)
    }

    /// `setup.runtime_check` for one profile: whether its sessions can reach
    /// a model. Nil when the gateway lacks the method.
    func botRuntimeCheck(profile: String) async -> AnyCodable? {
        try? await rpc("setup.runtime_check", params: ["profile": profile], timeout: 30, scoped: false)
    }

    /// `image.generate` probe: whether Hermes has an image backend set up.
    /// Nil when it didn't say (an older gateway without the method).
    func imageGenerationAvailable() async -> Bool? {
        let result = try? await rpc(
            "image.generate",
            params: PictureGeneration.probeParams,
            timeout: PictureGeneration.probeTimeoutSeconds,
            scoped: false
        )
        return PictureGeneration.isAvailable(probe: result)
    }

    /// `image.generate`: one square picture from `prompt`.
    func generateImage(prompt: String) async throws -> AnyCodable {
        try await rpc(
            "image.generate",
            params: PictureGeneration.params(prompt: prompt),
            timeout: PictureGeneration.timeoutSeconds,
            scoped: false
        )
    }

    /// `mcp.catalog` for a profile: Hermes' bundled MCP servers, with the
    /// keys each needs. Like the `profiles.*` writes, the bot is named in
    /// `profile`, never taken from the dashboard's own scope.
    func botMcpCatalog(profile: String) async throws -> [BotMcpCatalogEntry] {
        let result = try await rpc("mcp.catalog", params: ["profile": profile], scoped: false)
        return BotMcpSetup.catalog(from: result)
    }

    /// `mcp.servers.list` for a profile: its servers' auth, secrets redacted.
    func botMcpServers(profile: String) async throws -> [BotMcpServerSummary] {
        let result = try await rpc("mcp.servers.list", params: ["profile": profile], scoped: false)
        return BotMcpSetup.servers(from: result)
    }

    /// `mcp.servers.add` from a catalog preset.
    func addBotMcpServer(profile: String, name: String, preset: String) async throws -> AnyCodable {
        try await ProfileConfigWriteQueue.runThrowing { [self] in
            try await rpc(
                "mcp.servers.add",
                params: ["profile": profile, "name": name, "preset": preset],
                timeout: 60,
                scoped: false
            )
        }
    }

    /// `mcp.servers.set_api_key`: Hermes keeps the value in the profile's
    /// .env; the config only references it.
    func setBotMcpKey(profile: String, name: String, envVar: String, value: String) async throws {
        _ = try await rpc(
            "mcp.servers.set_api_key",
            params: ["profile": profile, "name": name, "env_var": envVar, "value": value],
            scoped: false
        )
    }

    /// `mcp.servers.test`: connect, list tools, disconnect. A cold `npx`
    /// server can take a while.
    func testBotMcpServer(profile: String, name: String) async throws -> AnyCodable {
        try await rpc("mcp.servers.test", params: ["profile": profile, "name": name], timeout: 120, scoped: false)
    }

    /// `mcp.servers.oauth.<action>` (start, poll, callback, cancel).
    func botMcpOAuth(_ action: String, params: [String: Any]) async throws -> AnyCodable {
        try await rpc("mcp.servers.oauth.\(action)", params: params, timeout: 60, scoped: false)
    }

    /// `profiles.describe`: the editor snapshot (description, SOUL.md, the
    /// profile's own model pin, and its skills, toolsets and MCP servers).
    func describeBotProfile(name: String) async throws -> BotProfileDetails {
        let result = try await rpc("profiles.describe", params: ["name": name], scoped: false)
        guard let object = result.objectValue else { throw HermesError.invalidResponse }
        let model = object["model"]?.objectValue ?? [:]
        return BotProfileDetails(
            description: object["description"]?.stringValue ?? "",
            soul: object["soul"]?.stringValue ?? "",
            provider: model["provider"]?.stringValue ?? "",
            model: model["default"]?.stringValue ?? "",
            capabilities: BotCapabilities(describe: object)
        )
    }

    /// `profiles.configure` model pin. `confirmed` resends a pick the
    /// gateway first answered with `confirm_required`.
    func configureBotModel(name: String, provider: String, model: String, confirmed: Bool) async throws -> AnyCodable {
        var params: [String: Any] = ["name": name, "provider": provider, "model": model]
        if confirmed { params["confirm_expensive_model"] = true }
        // A profile config write: it waits its turn with Settings' saves.
        return try await ProfileConfigWriteQueue.runThrowing { [self] in
            try await rpc("profiles.configure", params: params, scoped: false)
        }
    }

    /// `profiles.configure`. Sections are independent; the answer's
    /// `applied` reports each. `expectedMetaRevision` turns the ui_meta
    /// write into a compare-and-swap against the roster snapshot it was
    /// built from. `sections` carries `BotCapabilities.configureParams`.
    func configureBotProfile(
        name: String,
        botMeta: [String: Any]? = nil,
        expectedMetaRevision: Int? = nil,
        description: String? = nil,
        soul: String? = nil,
        sections: [String: Any] = [:]
    ) async throws -> AnyCodable {
        var params: [String: Any] = sections.merging(["name": name]) { _, new in new }
        if let botMeta {
            params["ui_meta"] = [BotManagement.uiMetaKey: botMeta]
            if let expectedMetaRevision {
                params["ui_meta_expected_revisions"] = [BotManagement.uiMetaKey: expectedMetaRevision]
            }
        }
        if let description { params["description"] = description }
        if let soul { params["soul"] = soul }
        return try await ProfileConfigWriteQueue.runThrowing { [self] in
            try await rpc("profiles.configure", params: params, scoped: false)
        }
    }

    /// `profiles.get_asset` for the bot's avatar. Nil when it has none.
    func botAvatar(name: String) async throws -> Data? {
        let result = try await rpc("profiles.get_asset", params: [
            "name": name,
            "asset": BotManagement.avatarAsset
        ], scoped: false)
        return BotAvatarImage.imageData(fromGetAssetResult: result)
    }

    /// `profiles.set_asset`: stores the avatar PNG, or clears it when nil.
    func setBotAvatar(name: String, png: Data?) async throws {
        var params: [String: Any] = ["name": name, "asset": BotManagement.avatarAsset]
        if let png {
            params["data"] = BotAvatarImage.dataURL(png: png)
        } else {
            params["clear"] = true
        }
        _ = try await rpc("profiles.set_asset", params: params, scoped: false)
    }


    /// Projects are a newer, optional gateway capability. Unlike the ordinary
    /// session catalog, membership comes from Hermes' server-side project tree
    /// so every Hermes client sees the same organization.
    func projects() async throws -> [ProjectSummary] {
        let result = try await rpc("projects.tree", params: ["preview_limit": 3])
        return MessageNormalizer.normalizeProjects(result, profile: profile)
    }

    func projectSessions(_ projectId: String) async throws -> ProjectSessionDetail? {
        let result = try await rpc("projects.project_sessions", params: ["project_id": projectId])
        return MessageNormalizer.normalizeProjectSessions(result, profile: profile)
    }

    func createProject(name: String, folders: [String]) async throws -> ProjectSummary? {
        let result = try await rpc("projects.create", params: [
            "name": name,
            "folders": folders,
            "primary_path": folders.first ?? "",
            "use": true
        ])
        guard let project = result.objectValue?["project"] else { return nil }
        return MessageNormalizer.normalizeProject(project, profile: profile)
    }

    func renameProject(_ projectId: String, name: String) async throws {
        _ = try await rpc("projects.update", params: ["id": projectId, "name": name])
    }

    /// Removes the project record and its folder list from projects.db. The
    /// folders, files and conversations themselves are left untouched.
    func deleteProject(_ projectId: String) async throws {
        _ = try await rpc("projects.delete", params: ["id": projectId])
    }

    /// Re-homes a stored session's workspace into `cwd`, the same RPC Hermes
    /// Desktop's "Move to project" uses. Project membership follows the
    /// session's folder, so moving the folder is moving the session; the
    /// gateway also re-anchors a live agent bound to the row. Returns the
    /// folder the gateway actually stored.
    @discardableResult
    func moveSessionWorkspace(_ sessionKey: String, cwd: String) async throws -> String {
        let result = try await rpc("session.workspace.move", params: [
            "session_key": sessionKey,
            "cwd": cwd
        ])
        let moved = result.objectValue?["cwd"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return moved.isEmpty ? cwd : moved
    }

    /// Is this socket still alive? Asked when Conduit comes back to the
    /// foreground with a socket iOS may have killed while it slept (#417).
    ///
    /// `ping` is Hermes' cheapest probe, answered on the WebSocket reader
    /// thread even while every agent is mid-turn (upstream
    /// `tui_gateway/contracts/liveness.py`), so it gets a shorter budget than
    /// the `session.list` it replaces, which builds a whole session list:
    /// the 5 s Hermes Desktop gives the same probe. Unscoped, like
    /// `profiles.list`, because it takes no arguments at all.
    ///
    /// A gateway that predates `ping` answers "method not found". That reply
    /// travelled over this socket, so it proves the socket alive exactly as a
    /// pong would; Hermes Desktop reads it the same way.
    ///
    /// While a request's frame is still being written (a picture going up),
    /// the ping would wait behind it past its budget and drop a working
    /// socket: that request's own budget answers for the socket instead
    /// (#1265).
    /// How long the gateway has sent nothing on this socket.
    var quietInterval: TimeInterval { Date().timeIntervalSince(lastInboundAt) }

    /// One ping for a socket that may have died unseen while iOS held
    /// Conduit suspended (#1362): one that doesn't answer is closed, as the
    /// keepalive closes one, so the ordinary reconnect takes over. It waits
    /// as long as a keepalive ping, since off screen a relayed path can be
    /// slow without being dead. True when it answered, or anything else came
    /// from the gateway meanwhile; skipped, as `healthCheck` is, while a
    /// large frame is still being written.
    func checkLiveness() async -> Bool {
        guard let socket, isConnected else { return false }
        guard requestsBeingWritten.isEmpty else { return true }
        let started = Date()
        do {
            try await ping(timeout: keepalivePingTimeout)
            return true
        } catch {
            // A cancelled check says nothing about the socket.
            if error is CancellationError || Task.isCancelled { return true }
            guard self.socket === socket, !closedIntentionally else { return false }
            if lastInboundAt > started { return true }
            logger.error("Liveness ping unanswered; closing the socket")
            socket.cancel(with: .goingAway, reason: nil)
            return false
        }
    }

    func healthCheck() async throws {
        guard requestsBeingWritten.isEmpty else {
            logger.notice("Connection check skipped: a large frame is still being written")
            return
        }
        try await ping(timeout: Self.pingTimeout)
    }

    private func ping(timeout: TimeInterval) async throws {
        do {
            _ = try await rpc("ping", params: nil, timeout: timeout, scoped: false)
        } catch let error where Self.isMissingRPCMethod(error) {
            return
        }
    }

    /// Resumes a session with the compact projection: `omit_messages` asks
    /// the gateway to suppress the persisted transcript copy in the response
    /// (`messages: []`) because the caller hydrates it through the
    /// authenticated REST history route, exactly like Hermes Desktop. Older
    /// gateways read `session.resume` params loosely and simply ignore the
    /// unknown flag, degrading to the historical full response. AppState owns
    /// the REST hydration and falls back to `openSessionLegacy` when no
    /// usable history source exists.
    func openSession(_ sessionId: String, profile: String? = nil) async throws -> SessionResumeResult {
        try await resumeSession(sessionId, omitMessages: true, profile: profile)
    }

    /// Resume variant that carries the persisted transcript inside the RPC
    /// response. Used when compact resume cannot be hydrated (missing bridge,
    /// a gateway without the history endpoint, or history rows that resolved
    /// to a foreign session). Its response is the largest ordinary payload in
    /// the app, so it uses the dedicated `legacyResumeTimeout`.
    func openSessionLegacy(_ sessionId: String, profile: String? = nil) async throws -> SessionResumeResult {
        try await resumeSession(sessionId, omitMessages: false, profile: profile)
    }

    /// Compact responses are tiny, so they ride the ordinary request budget;
    /// the legacy transcript response gets the generous bounded budget.
    static func resumeTimeout(omitMessages: Bool) -> TimeInterval {
        omitMessages ? requestTimeout : legacyResumeTimeout
    }

    private func resumeSession(
        _ sessionId: String,
        omitMessages: Bool,
        profile: String? = nil
    ) async throws -> SessionResumeResult {
        let object = try await resumeSessionObject(sessionId, omitMessages: omitMessages, profile: profile)
        return resumeResult(from: object, sessionId: sessionId)
    }

    /// The `session.resume` response, with its open requests taken in.
    private func resumeSessionObject(
        _ sessionId: String,
        omitMessages: Bool,
        profile: String? = nil
    ) async throws -> [String: AnyCodable] {
        var params: [String: Any] = [
            "session_id": sessionId,
            "cols": 96,
            "source": "desktop"
        ]
        if omitMessages {
            params["omit_messages"] = true
        } else {
            // The transcript without the copy of every picture stored in
            // it (#652); a gateway without the flag ignores it.
            params["inline_images"] = false
        }
        // A bot chat lives in the bot profile's state.db; the gateway's
        // `session.resume` reads the `profile` param to open that store
        // (`_profile_home(params.profile)`). Without it the resume lands on
        // the dashboard profile and cannot see the session.
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        let result = try await rpc(
            "session.resume",
            params: params,
            timeout: Self.resumeTimeout(omitMessages: omitMessages)
        )
        let object = result.objectValue ?? [:]
        for id in Self.openRequestIDs(in: object["open_requests"]) {
            openServerRequestIDs.insert(id)
        }
        // Anything replayed that this client cannot present is declined
        // exactly like the live frame, or it would stall the agent until its
        // deadline after every reconnect.
        for entry in object["open_requests"]?.arrayValue ?? [] {
            guard let request = entry.objectValue,
                  let method = request["method"]?.stringValue,
                  !Self.handlesServerRequest(method),
                  let id = request["id"]?.stringValue, !id.isEmpty else { continue }
            declineServerRequest(id: .string(id), method: method)
        }
        // An input request no card can show (no session, or a login with
        // no origin) is refused as the live frame is, not left to wait.
        var refusedInputIDs: Set<String> = []
        for entry in object["open_requests"]?.arrayValue ?? [] {
            guard let request = entry.objectValue,
                  let method = request["method"]?.stringValue,
                  InputPromptActivity.Kind(rawValue: method) != nil,
                  let id = request["id"]?.stringValue, !id.isEmpty,
                  InputPromptActivity.from(
                      requestId: id, method: method, params: request["params"]?.objectValue ?? [:]
                  ) == nil else { continue }
            openServerRequestIDs.remove(id)
            refusedInputIDs.insert(id)
            writeServerRequestReply(id: .string(id), error: (Self.invalidParamsCode, "\(method) request without the fields its card needs"))
        }
        for entry in object["open_requests"]?.arrayValue ?? [] {
            guard let request = entry.objectValue,
                  request["method"]?.stringValue == "approval",
                  let id = request["id"]?.stringValue,
                  let params = request["params"]?.objectValue,
                  let queueID = params["request_id"]?.stringValue,
                  !queueID.isEmpty else { continue }
            approvalQueueIDs[id] = (queueID, params["session_id"]?.stringValue ?? "")
        }
        for entry in object["open_requests"]?.arrayValue ?? [] {
            guard let request = entry.objectValue,
                  let method = request["method"]?.stringValue,
                  method == "clarify" || InputPromptActivity.Kind(rawValue: method) != nil,
                  let id = request["id"]?.stringValue, !refusedInputIDs.contains(id),
                  let session = request["params"]?.objectValue?["session_id"]?.stringValue else { continue }
            clarifySessions[id] = session
        }
        return object
    }

    private func resumeResult(from object: [String: AnyCodable], sessionId: String) -> SessionResumeResult {
        let resolvedId = object["session_id"]?.stringValue ?? sessionId
        // The durable stored key is parsed separately from the runtime id and
        // stays nil when the gateway omits it (legacy gateways). Callers must
        // not treat the runtime `session_id` as durable identity evidence.
        let storedId = ["stored_session_id", "storedSessionId", "session_key"]
            .compactMap { object[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let messages = MessageNormalizer.normalizeMessages(
            object["messages"]?.arrayValue ?? []
        )
        var snapshotObject = object["info"]?.objectValue ?? [:]
        // The resume response owns the liveness fields. Keep `info` for the
        // rest of the runtime metadata, but let top-level values win.
        for key in ["running", "status"] {
            if let value = object[key] {
                snapshotObject[key] = value
            }
        }
        // Pending decisions and the plan ride the resume response top level.
        // Hoist them so the snapshot parser sees the same contract as
        // session.info.
        for key in ["pending_clarify", "pending_approval", "todo_state"] {
            if let value = object[key] {
                snapshotObject[key] = value
            }
        }
        // Current Hermes no longer sends `pending_clarify`: an unanswered
        // clarify is a server→client request, re-announced in
        // `open_requests` under its original id. Feed it through the same
        // authoritative restore path (locked batch answers ride `answers`).
        let openClarifies = Self.openClarifyPayloads(in: object["open_requests"])
        // The oldest rides `pending_clarify` only when the resume did not
        // already carry one; every other open clarify rides `open_clarifies`.
        if snapshotObject["pending_clarify"] == nil, let oldest = openClarifies.first {
            snapshotObject["pending_clarify"] = .object(oldest)
            if openClarifies.count > 1 {
                snapshotObject["open_clarifies"] = .array(openClarifies.dropFirst().map { .object($0) })
            }
        } else if !openClarifies.isEmpty {
            snapshotObject["open_clarifies"] = .array(openClarifies.map { .object($0) })
        }
        if let openRequests = object["open_requests"] {
            snapshotObject["open_requests"] = openRequests
        }
        return SessionResumeResult(
            sessionId: resolvedId,
            storedSessionId: storedId,
            messages: messages,
            snapshot: SessionRuntimeSnapshot(
                object: snapshotObject,
                inflight: object["inflight"],
                queued: object["queued"]
            )
        )
    }

    func busyInputMode() async throws -> BusyInputMode {
        let result = try await rpc("config.set", params: ["key": "busy", "value": "status"])
        let value = result.objectValue?["value"]?.stringValue?.lowercased()
        return BusyInputMode.fromGatewayValue(value)
    }

    func setBusyInputMode(_ mode: BusyInputMode) async throws {
        // Saved in the profile config, so it queues with the other saves.
        _ = try await ProfileConfigWriteQueue.runThrowing { [self] in
            try await rpc("config.set", params: ["key": "busy", "value": mode.rawValue])
        }
    }

    /// `inProfile` creates the session in another profile on the same
    /// gateway (a voice job addressed to a bot); nil uses the client's own.
    func createSession(model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil, fast: Bool? = nil, cwd: String? = nil, inProfile: String? = nil) async throws -> (sessionId: String, storedSessionId: String?, profile: String?) {
        var params: [String: Any] = [
            "cols": 96,
            "source": "desktop"
        ]
        // Keep this explicit instead of relying solely on the generic RPC
        // scope. Hermes Desktop does the same: a global gateway can otherwise
        // create an unscoped session in its launch/default profile.
        if let profile = inProfile ?? profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        if let model {
            params["model"] = model
            if let provider { params["provider"] = provider }
        }
        if let reasoningEffort { params["reasoning_effort"] = reasoningEffort }
        if let fast, fast { params["fast"] = true }
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { params["cwd"] = cwd }
        let result = try await rpc("session.create", params: params)
        let object = result.objectValue ?? [:]
        let sid = object["session_id"]?.stringValue ?? ""
        let stored = object["stored_session_id"]?.stringValue
        let profile = object["profile"]?.stringValue ?? object["profile_id"]?.stringValue
        return (sid, stored, profile)
    }

    /// Creates a historical fork rather than a blank conversation. Hermes
    /// preserves the supplied prefix, then lets the new session continue from
    /// the selected assistant response.
    func branchSession(
        parentSessionId: String,
        messages: [SessionBranchMessage],
        title: String,
        cwd: String?
    ) async throws -> (sessionId: String, storedSessionId: String?, profile: String?) {
        var params: [String: Any] = [
            "cols": 96,
            "source": "desktop",
            "parent_session_id": parentSessionId,
            "title": title,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        if let cwd, !cwd.isEmpty { params["cwd"] = cwd }
        let result = try await rpc("session.create", params: params)
        let object = result.objectValue ?? [:]
        let sessionId = object["session_id"]?.stringValue ?? ""
        guard !sessionId.isEmpty else { throw HermesError.invalidResponse }
        return (
            sessionId,
            object["stored_session_id"]?.stringValue,
            object["profile"]?.stringValue ?? object["profile_id"]?.stringValue
        )
    }

    func setSessionTitle(_ sessionId: String, title: String, profile: String? = nil) async throws {
        var params: [String: Any] = [
            "session_id": sessionId,
            "title": title
        ]
        // The gateway's `session.title` is session-scoped (the db comes from
        // the resolved session's own profile home), so this param is inert
        // on the wire — it is carried to keep the bot chat's RPCs uniformly
        // self-describing about the profile they address.
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        _ = try await rpc("session.title", params: params)
    }

    /// Reads the gateway's current title without guessing from the local
    /// catalog. This is particularly important for profile-scoped sessions,
    /// whose title can be updated asynchronously by Hermes.
    func sessionTitle(_ sessionId: String, profile: String? = nil) async throws -> String? {
        var params: [String: Any] = ["session_id": sessionId]
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        let result = try await rpc("session.title", params: params)
        let title = result.objectValue?["title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false) ? title : nil
    }

    /// A stateless one-shot request on the profile's `task` backend (no
    /// session lends its model, nothing is added to any history). Used for
    /// saved voice calls' titles and resume summaries.
    func oneshot(
        task: String,
        instructions: String,
        input: String,
        profile: String?,
        maxTokens: Int = 500
    ) async throws -> String? {
        var params: [String: Any] = [
            "task": task,
            "instructions": instructions,
            "input": input,
            "max_tokens": maxTokens,
            "temperature": 0.3
        ]
        if let profile, !profile.isEmpty { params["profile"] = profile }
        let result = try await rpc("llm.oneshot", params: params, timeout: Self.titleGenerationTimeout)
        let text = result.objectValue?["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    /// Hermes' one-shot endpoint uses the configured title-capable model but
    /// does not add a message to the conversation history.
    func generateSessionTitle(
        _ sessionId: String,
        userMessage: String,
        assistantMessage: String,
        language: String? = nil
    ) async throws -> String? {
        let requestedLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let languageInstruction = requestedLanguage.isEmpty
            ? "Write the title in the same language the user is writing in."
            : "Write the title in \(requestedLanguage)."
        let userSnippet = String(userMessage.prefix(500))
        let assistantSnippet = String(assistantMessage.prefix(500))
        let result = try await rpc("llm.oneshot", params: [
            "session_id": sessionId,
            "task": "title_generation",
            "instructions": "Generate a short, descriptive title (3-7 words) for a conversation that starts with the following exchange. The title should capture the main topic or intent. \(languageInstruction) Return ONLY the title text, nothing else. No quotes, no punctuation at the end, no prefixes.",
            "input": "User: \(userSnippet)\n\nAssistant: \(assistantSnippet)",
            "max_tokens": 500,
            "temperature": 0.3
        ], timeout: Self.titleGenerationTimeout)
        return result.objectValue?["text"]?.stringValue
    }

    /// The gateway's answer is meaningful and must not be discarded: an idle
    /// session returns `{"status": "streaming"}`, while a busy session never
    /// rejects — it applies the configured busy policy and reports
    /// `steered`/`redirected`/`queued`. A lost RPC acknowledgement (timeout,
    /// socket death after the bytes reached Hermes) leaves the turn running
    /// server-side; upstream's own clients recover that case by querying the
    /// authoritative session state instead of blindly re-submitting.
    ///
    /// `surface` names where the turn came from (`voice-live` for a spoken
    /// turn). Hermes adds its spoken-reply note to the model input only, so
    /// the persisted user row stays what the user said; older gateways
    /// ignore the key.
    ///
    /// `voiceTurn` marks a spoken voice-conversation turn, which Hermes runs
    /// on its `auxiliary.voice_chat` model (reasoning off by default). A
    /// gateway from before that slot refuses the unknown key with `4000`
    /// before anything runs, so the turn is resent once without it and the
    /// key is dropped for this client from then on.
    /// `queued` is Queue (#842): with a turn running, Hermes keeps the
    /// message as the next turn, on its side, instead of steering or
    /// interrupting with it. A gateway that refuses the key is never sent
    /// the message without it, which would steer or interrupt instead.
    func sendPrompt(
        _ sessionId: String,
        text: String,
        surface: String? = nil,
        voiceTurn: Bool = false,
        queued: Bool = false,
        hidden: Bool = false
    ) async throws -> PromptSubmissionOutcome {
        var params: [String: Any] = [
            "session_id": sessionId,
            "text": text
        ]
        if let surface { params["surface"] = surface }
        // Seen by the model, never shown as the user's (Predictive follow-ups).
        if hidden {
            guard !gatewayRefusesHiddenPrompts else { throw HiddenPromptUnsupportedError() }
            params["display_kind"] = "hidden"
        }
        let marksVoiceTurn = voiceTurn && !gatewayRefusesVoiceTurn
        if marksVoiceTurn { params["voice_turn"] = true }
        if queued {
            guard !gatewayRefusesQueued else { throw QueueUnsupportedError() }
            params["queued"] = true
        }
        let result: AnyCodable
        do {
            result = try await rpc("prompt.submit", params: params, timeout: Self.promptSubmitTimeout)
        } catch let error as RpcError where marksVoiceTurn && error.refusesUnknownParam("voice_turn") {
            gatewayRefusesVoiceTurn = true
            params.removeValue(forKey: "voice_turn")
            result = try await rpc("prompt.submit", params: params, timeout: Self.promptSubmitTimeout)
        } catch let error as RpcError where queued && error.refusesUnknownParam("queued") {
            gatewayRefusesQueued = true
            throw QueueUnsupportedError()
        } catch let error as RpcError where hidden && error.refusesUnknownParam("display_kind") {
            // Never resent without it: that would show Conduit's nudge as
            // the user's own message.
            gatewayRefusesHiddenPrompts = true
            throw HiddenPromptUnsupportedError()
        }
        return PromptSubmissionOutcome(
            gatewayStatus: result.objectValue?["status"]?.stringValue
        )
    }

    /// Set once this gateway refused `prompt.submit`'s `voice_turn` key
    /// (a Hermes from before `auxiliary.voice_chat`).
    private var gatewayRefusesVoiceTurn = false

    /// Set once this gateway refused `prompt.submit`'s `queued` key.
    /// Internal so tests can stand in for that refusal.
    var gatewayRefusesQueued = false

    /// This gateway is known to refuse Queue.
    var refusesQueuedPrompts: Bool { gatewayRefusesQueued }

    /// Set once this gateway refused `prompt.submit`'s `display_kind`, so
    /// Predictive follow-ups stop asking on it. Internal so tests can stand
    /// in for that refusal.
    var gatewayRefusesHiddenPrompts = false

    /// A hidden prompt on a Hermes without `display_kind`.
    struct HiddenPromptUnsupportedError: Error {}

    /// Queue on a Hermes without `prompt.submit`'s `queued` key.
    struct QueueUnsupportedError: LocalizedError {
        var errorDescription: String? {
            AppLocalization.string("This Hermes can't queue messages. Update Hermes, or touch and hold send to steer or interrupt instead.")
        }

        /// Attachments have no steer or interrupt to fall back on.
        static var attachmentsMessage: String {
            AppLocalization.string("This Hermes can't queue attachments. Update Hermes, or send them once the reply has finished.")
        }
    }

    /// Read-only liveness probe against the gateway's in-memory runtime
    /// registry (`session.active_list`). Unlike `session.resume` this does not
    /// switch, rebind, or mutate the session, and it is authoritative about
    /// absence: a runtime that has ended (turn complete + transport gone, or
    /// a gateway restart) is no longer listed. The empty parameter map is
    /// load-bearing: `scopeParams` collapses it to an argument-free request
    /// under the default profile (non-default profiles add only the gateway
    /// `profile` context). Older gateways without the method throw `RpcError`;
    /// callers degrade to resume-based recovery.
    func activeSessions(inProfile: String? = nil) async throws -> [LiveSessionStatus] {
        // An explicit profile reads another profile's registry (a voice job
        // running on a bot); the client's own scope still applies otherwise.
        let result = try await rpc(
            "session.active_list",
            params: inProfile.map { ["profile": $0] as [String: Any] } ?? [:],
            timeout: Self.livenessProbeTimeout
        )
        let rows = result.objectValue?["sessions"]?.arrayValue ?? []
        return rows.compactMap { LiveSessionStatus(from: $0.objectValue ?? [:]) }
    }

    func steer(_ sessionId: String, text: String) async throws {
        let result = try await rpc("session.steer", params: [
            "session_id": sessionId,
            "text": text
        ])
        if result.objectValue?["status"]?.stringValue == "rejected" {
            throw HermesError.steerRejected
        }
    }

    func redirect(_ sessionId: String, text: String) async throws -> SessionRedirectOutcome {
        let result = try await rpc("session.redirect", params: [
            "session_id": sessionId,
            "text": text
        ])
        return SessionRedirectOutcome(gatewayStatus: result.objectValue?["status"]?.stringValue)
    }

    func cancel(_ sessionId: String) async throws {
        _ = try await rpc("session.interrupt", params: [
            "session_id": sessionId
        ])
    }

    /// Outcome of `clarify.respond`. Batch questions report the gateway's
    /// authoritative `remaining` list so the caller can tell a per-question
    /// lock from full completion; `expired` is a successful RPC whose status
    /// says the request timed out server-side (the clarify bridge sets
    /// `allow_expired`, so a late answer never errors) and must not read as
    /// success. `remaining` keeps the wire's presence semantics: an explicit
    /// empty list confirms completion, while an omitted field (older or
    /// minimal gateways) carries no sibling information at all.
    enum ClarifyResponseOutcome: Equatable {
        case accepted(remaining: [String]?)
        case expired

        var isExpired: Bool { self == .expired }

        /// True only on an explicit `remaining: []` — the gateway's own
        /// confirmation that every question is resolved. An omitted
        /// remaining field must never be inferred as completion.
        var requestCompleted: Bool {
            switch self {
            case .accepted(let remaining): return remaining?.isEmpty == true
            case .expired: return false
            }
        }
    }

    /// Answers one clarification. Batch questions pass their gateway `qid` as
    /// `questionId` for the per-question lock (`{"status": "ok",
    /// "remaining": [...]}`). Omitting `questionId` keeps the legacy
    /// request-level response — still required for push-relay cards, request
    /// cancellation, and harmless for single-question gateways, which ignore
    /// the extra parameter.
    func respondToClarification(
        requestId: String,
        answer: String,
        questionId: String? = nil
    ) async throws -> ClarifyResponseOutcome {
        if isServerRequestID(requestId) {
            return try await respondToClarifyServerRequest(
                requestId: requestId,
                answer: answer,
                questionId: questionId
            )
        }
        var params: [String: Any] = [
            "request_id": requestId,
            "answer": answer
        ]
        if let questionId, !questionId.isEmpty {
            params["question_id"] = questionId
        }
        let result = try await rpc("clarify.respond", params: params)
        let status = result.objectValue?["status"]?.stringValue?.lowercased()
        if status == "expired" {
            return .expired
        }
        // Presence matters: `remaining` omitted and `remaining: []` are
        // different protocol states.
        let remaining: [String]? = result.objectValue?["remaining"]?.arrayValue.map {
            $0.compactMap(\.stringValue)
        }
        return .accepted(remaining: remaining)
    }

    /// Answers a `clarify` server request (Hermes #110521). A batch
    /// question locks through `clarify.lock`, whose reply has the same
    /// `{status, remaining}` shape as the legacy `clarify.respond`; the last
    /// lock resolves the request server-side. A single question is answered
    /// with the response frame itself — `{answer}` under the request's id —
    /// which the gateway never acknowledges, so the outcome carries no
    /// `remaining` list.
    private func respondToClarifyServerRequest(
        requestId: String,
        answer: String,
        questionId: String?
    ) async throws -> ClarifyResponseOutcome {
        guard let questionId, !questionId.isEmpty else {
            try await sendServerRequestResult(id: requestId, result: ["answer": answer])
            clarifySessions.removeValue(forKey: requestId)
            return .accepted(remaining: nil)
        }
        let result = try await rpc(
            "clarify.lock",
            params: ["request_id": requestId, "question_id": questionId, "answer": answer]
        )
        let status = result.objectValue?["status"]?.stringValue?.lowercased()
        if status == "expired" {
            openServerRequestIDs.remove(requestId)
            clarifySessions.removeValue(forKey: requestId)
            return .expired
        }
        let remaining: [String]? = result.objectValue?["remaining"]?.arrayValue.map {
            $0.compactMap(\.stringValue)
        }
        if remaining?.isEmpty == true {
            openServerRequestIDs.remove(requestId)
            clarifySessions.removeValue(forKey: requestId)
        }
        return .accepted(remaining: remaining)
    }

    /// `message.react`: sets, replaces or (same emoji, or nil) retracts the
    /// user's reaction. The row is named by its durable `row_id`; a live row
    /// that hasn't been reloaded yet names `newest_role` instead and Hermes
    /// resolves the newest row of that role. The reaction needs no turn of
    /// its own: Hermes tells the agent about it with the next message.
    func reactToMessage(
        sessionId: String,
        target: MessageReactionTarget,
        emoji: String?
    ) async throws -> MessageReactionResult {
        var params: [String: Any] = [
            "session_id": sessionId,
            "author": MessageReaction.userAuthor
        ]
        // An explicit null clears the reaction.
        params["emoji"] = emoji.map { $0 as Any } ?? NSNull()
        switch target {
        case .row(let rowId):
            params["row_id"] = rowId
        case .newest(let role):
            params["newest_role"] = role
        }
        let result = try await rpc("message.react", params: params)
        let object = result.objectValue ?? [:]
        guard let rowId = Self.exactIntValue(object["row_id"]), rowId > 0 else {
            throw HermesError.invalidResponse
        }
        return MessageReactionResult(
            rowId: rowId,
            reactions: MessageNormalizer.messageReactions(from: object["reactions"])
        )
    }

    /// Answers a sudo / secret / vault server request. `value` is
    /// sent once and never retained; an empty string tells Hermes the user
    /// skipped (the tool then proceeds without the value).
    func respondToInputPrompt(requestId: String, value: String) async throws {
        try await sendServerRequestResult(id: requestId, result: ["value": value])
        clarifySessions.removeValue(forKey: requestId)
    }

    func respondToApproval(
        sessionId: String,
        requestId: String? = nil,
        choice: String,
        profile: String? = nil
    ) async throws -> Bool {
        var params: [String: Any] = [
            "choice": choice,
            "session_id": sessionId
        ]
        let trimmedRequestId = requestId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRequestId = trimmedRequestId?.isEmpty == false
        if let trimmedRequestId, hasRequestId {
            params["request_id"] = trimmedRequestId
        }
        if let profile, !profile.isEmpty {
            params["profile"] = profile
        }
        let result = try await rpc("approval.respond", params: params)
        // Current Hermes reports the number of queue entries resolved. Older
        // gateways omitted the field after a successful response to legacy
        // requestless approval calls.
        guard let object = result.objectValue else {
            throw HermesError.invalidResponse
        }
        guard let rawResolved = object["resolved"] else {
            if hasRequestId {
                throw HermesError.invalidResponse
            }
            return true
        }
        guard let resolved = Self.exactIntValue(rawResolved), resolved >= 0 else {
            throw HermesError.invalidResponse
        }
        if let trimmedRequestId, hasRequestId {
            // Settled here; the gateway's `resolved` cancel would only find
            // a card that is no longer pending.
            approvalQueueIDs = approvalQueueIDs.filter { $0.value.queueID != trimmedRequestId }
        }
        return resolved > 0
    }

    /// Returns every unresolved approval for one live Hermes session. Current
    /// Hermes scopes this method through `session_id`; bind payloads to that
    /// requested identity rather than trusting optional fields inside a row.
    func pendingApprovals(sessionId: String, profile: String? = nil) async throws -> [ApprovalActivity] {
        var params: [String: Any] = ["session_id": sessionId]
        if let profile, !profile.isEmpty {
            params["profile"] = profile
        }
        let result = try await rpc(
            "approval.pending",
            params: params,
            timeout: Self.pendingApprovalsTimeout
        )
        guard let object = result.objectValue,
              let approvalsValue = object["approvals"],
              let array = approvalsValue.arrayValue else {
            throw HermesError.invalidResponse
        }
        return array.compactMap { value in
            guard let payload = value.objectValue else { return nil }
            return MessageNormalizer.approvalActivity(from: payload, sessionId: sessionId)
        }
    }

    /// The `subagent_id`s Hermes still has running for one live session.
    func liveSubagentIDs(sessionId: String) async throws -> Set<String> {
        let result = try await rpc("subagent.list", params: ["session_id": sessionId])
        guard let rows = result.objectValue?["subagents"]?.arrayValue else {
            throw HermesError.invalidResponse
        }
        let ids = rows.compactMap { row in
            row.objectValue?["subagent_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        // A row without an id could be any running agent: trust none of it.
        guard ids.count == rows.count else { throw HermesError.invalidResponse }
        return Set(ids)
    }

    /// Queues `text` into one running delegate agent (`subagent.steer`).
    /// Hermes hands it over at the agent's next tool step; false when Hermes
    /// rejected it because the agent isn't running for this session.
    func steerSubagent(sessionId: String, subagentId: String, text: String) async throws -> Bool {
        let result = try await rpc("subagent.steer", params: [
            "session_id": sessionId,
            "subagent_id": subagentId,
            "text": text
        ])
        switch result.objectValue?["status"]?.stringValue {
        case "queued": return true
        case "rejected": return false
        // Only an explicit rejection may end the card.
        default: throw HermesError.invalidResponse
        }
    }

    /// Stops one running delegate agent (`subagent.interrupt`). False when
    /// Hermes no longer has that agent running for this session.
    func interruptSubagent(sessionId: String, subagentId: String) async throws -> Bool {
        let result = try await rpc("subagent.interrupt", params: [
            "session_id": sessionId,
            "subagent_id": subagentId
        ])
        // A reply without `found` must not end a card that may still run.
        guard let found = result.objectValue?["found"]?.boolValue else { throw HermesError.invalidResponse }
        return found
    }

    /// The end of one delegate agent's live transcript (`subagent.tail`,
    /// at most 16 KB).
    func tailSubagent(sessionId: String, subagentId: String) async throws -> SubagentTail {
        let result = try await rpc("subagent.tail", params: [
            "session_id": sessionId,
            "subagent_id": subagentId
        ])
        guard let object = result.objectValue else { throw HermesError.invalidResponse }
        return SubagentTail(
            available: object["available"]?.boolValue ?? false,
            text: object["text"]?.stringValue ?? "",
            truncated: object["truncated"]?.boolValue ?? false
        )
    }

    /// Whether Hermes is holding new delegate agents (`delegation.status`).
    /// The pause covers the whole Hermes, not one profile.
    func delegationPaused() async throws -> Bool {
        let result = try await rpc("delegation.status")
        guard let paused = result.objectValue?["paused"]?.boolValue else { throw HermesError.invalidResponse }
        return paused
    }

    /// Holds or releases new delegate agents (`delegation.pause`); agents
    /// already running keep going. Returns the state Hermes reports.
    func setDelegationPaused(_ paused: Bool) async throws -> Bool {
        let result = try await rpc("delegation.pause", params: ["paused": paused])
        guard let state = result.objectValue?["paused"]?.boolValue else { throw HermesError.invalidResponse }
        return state
    }

    func modelOptions(sessionId: String? = nil) async throws -> (model: String?, provider: String?, providers: [ProviderInfo]?) {
        var params: [String: Any] = ["explicit_only": true]
        if let sessionId { params["session_id"] = sessionId }
        let result = try await rpc("model.options", params: params)
        let obj = result.objectValue ?? [:]
        let model = obj["model"]?.stringValue
        let provider = obj["provider"]?.stringValue
        let providers = (obj["providers"]?.arrayValue ?? []).compactMap { ProviderInfo(from: $0) }
        return (model, provider, providers)
    }

    /// Settings > Usage's quota (#813): `model.options` rows carry each
    /// signed-in provider's subscription windows and rate limit from Hermes'
    /// cache, and asking starts Hermes' background refresh of that cache.
    func providerQuotas() async throws -> [ProviderQuota] {
        let result = try await rpc("model.options", params: ["explicit_only": true])
        return ProviderQuota.list(from: result.anyValue as? [String: Any] ?? [:])
    }

    /// The gateway can answer without switching: a guarded pick (expensive
    /// model, data-training tier, or a switch that abandons a large cached
    /// context) comes back as `confirm_required` and nothing is applied until
    /// the client repeats the call with `confirm_expensive_model`.
    func setModel(_ sessionId: String, model: String, provider: String, confirmed: Bool = false) async throws -> ModelSwitchOutcome {
        var params: [String: Any] = [
            "key": "model",
            "session_id": sessionId,
            "value": "\(model) --provider \(provider) --session"
        ]
        if confirmed { params["confirm_expensive_model"] = true }
        let result = try await rpc("config.set", params: params)
        return ModelSwitchOutcome(from: result, requestedModel: model)
    }

    func setReasoning(_ sessionId: String, effort: String) async throws {
        _ = try await rpc("config.set", params: [
            "key": "reasoning",
            "session_id": sessionId,
            "value": effort
        ])
    }

    /// Session-scoped `/fast`. A gateway older than Ultrafast refuses
    /// "ultrafast" as an unknown word.
    func setSpeed(_ sessionId: String, speed: ModelSpeed) async throws {
        _ = try await rpc("config.set", params: [
            "key": "fast",
            "session_id": sessionId,
            "value": speed.rawValue
        ])
    }

    /// Session-only approval bypass, matching Desktop and the TUI's Shift+Tab.
    /// The persistent profile default is managed separately through Settings.
    func setSessionYolo(_ sessionId: String, enabled: Bool) async throws {
        _ = try await rpc("config.set", params: [
            "key": "yolo",
            "session_id": sessionId,
            "value": enabled ? "1" : "0"
        ])
    }

    func contextBreakdown(_ sessionId: String) async throws -> ContextBreakdown {
        let result = try await rpc("session.context_breakdown", params: [
            "session_id": sessionId
        ])
        return ContextBreakdown(from: result)
    }

    // MARK: - Slash Commands

    func commandsCatalog(sessionId: String? = nil) async throws -> AnyCodable {
        var params: [String: Any] = [:]
        if let sessionId { params["session_id"] = sessionId }
        return try await rpc("commands.catalog", params: params.isEmpty ? nil : params)
    }

    func executeSlash(sessionId: String, command: String) async throws -> AnyCodable {
        // Strip leading slashes so callers can pass "/clear" or "clear"
        let cleaned = command.replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        return try await rpc("slash.exec", params: [
            "session_id": sessionId,
            "command": cleaned
        ])
    }

    /// Starts a side agent (`prompt.background` / `prompt.btw`) and
    /// returns its task id.
    func startSideAgent(_ kind: SideAgentKind, sessionId: String, text: String) async throws -> String? {
        let result = try await rpc(kind.method, params: [
            "session_id": sessionId,
            "text": text
        ])
        return result.objectValue?["task_id"]?.stringValue
    }

    /// The background processes this chat started (Hermes' `/stop`).
    /// Returns how many stopped.
    func stopProcesses(sessionId: String) async throws -> Int {
        let result = try await rpc("process.stop", params: ["session_id": sessionId])
        return result.objectValue?["killed"]?.intValue ?? 0
    }

    /// What `/undo` and `/retry` rewind from: the session's user turns and
    /// the fences a rewind must present, read from one `session.resume`
    /// like Hermes' own clients do. `profile` opens a bot chat's store, as
    /// for any resume.
    func rewindSnapshot(sessionId: String, profile: String? = nil) async throws -> SessionRewindSnapshot {
        let object = try await resumeSessionObject(sessionId, omitMessages: false, profile: profile)
        return SessionRewindSnapshot(resume: object)
    }

    /// Hermes' `session.mutate` rewind: archives the user turn
    /// `targetMessageID` and everything after it. The gateway refuses a
    /// running session (`session_busy`) and a moved one
    /// (`revision_conflict`, `stale_generation`).
    func rewindSession(
        sessionId: String,
        targetMessageID: Int,
        snapshot: SessionRewindSnapshot,
        profile: String? = nil
    ) async throws -> SessionRewindReceipt {
        var params: [String: Any] = [
            "session_id": sessionId,
            "request_id": UUID().uuidString.lowercased(),
            "operation": "rewind",
            "payload": ["target_message_id": targetMessageID]
        ]
        if let revision = snapshot.revision { params["expected_revision"] = revision }
        if let generation = snapshot.generation { params["expected_generation"] = generation }
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        let result = try await rpc("session.mutate", params: params)
        return SessionRewindReceipt(result: result)
    }

    func dispatchCommand(sessionId: String, name: String, arg: String) async throws -> AnyCodable {
        return try await rpc("command.dispatch", params: [
            "session_id": sessionId,
            "name": name,
            "arg": arg
        ])
    }

    /// Dedicated manual-compression RPC (`session.compress`) — the same path
    /// the TUI and Hermes Desktop use for `/compress`. It must NOT go through
    /// `slash.exec`: compressing a large session legitimately outlives the
    /// generic request timeout, which surfaces as a failure while the gateway
    /// is still compressing (upstream #44456). `focusTopic` mirrors Desktop: it is
    /// omitted entirely when empty rather than sent as an empty string.
    func compressSession(
        sessionId: String,
        focusTopic: String? = nil,
        timeout: TimeInterval = sessionCompressTimeout
    ) async throws -> SessionCompressResult {
        var params: [String: Any] = ["session_id": sessionId]
        let trimmedTopic = focusTopic?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTopic, !trimmedTopic.isEmpty {
            params["focus_topic"] = trimmedTopic
        }
        let result = try await rpc("session.compress", params: params, timeout: timeout)
        return SessionCompressResult(from: result)
    }

    /// Whether `error` means "this gateway predates the RPC method". Upstream
    /// answers unknown methods with the JSON-RPC `-32601` "unknown method"
    /// error (`tui_gateway/server.py`), and Hermes Desktop treats the same
    /// message family (`method not found` / `-32601` / `unknown method` /
    /// `no such method`, `apps/desktop/src/lib/gateway-rpc.ts`) as the
    /// legacy-gateway signal. Timeouts, busy rejections, connection failures,
    /// and compression errors are deliberately NOT in this class — a slow RPC
    /// must never be retried as a missing one.
    static func isMissingRPCMethod(_ error: Error) -> Bool {
        let message: String
        if let rpcError = error as? RpcError {
            if rpcError.code == -32601 { return true }
            message = rpcError.message
        } else {
            message = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
        return matchesMissingMethodPattern(message)
    }

    private static func matchesMissingMethodPattern(_ message: String) -> Bool {
        // Plain substring checks over Desktop's regex — the pattern is a
        // compile-constant, so NSRegularExpression buys nothing here.
        let lowered = message.lowercased()
        return lowered.contains("method not found")
            || lowered.contains("-32601")
            || lowered.contains("unknown method")
            || lowered.contains("no such method")
    }

    /// Whether `error` means "the runtime session id is gone" — the gateway
    /// answers session-scoped RPCs for a reaped/detached runtime with
    /// `_err(4001, "session not found")` (`tui_gateway/server.py::_sess_nowait`),
    /// and the client is expected to recover by resuming the STORED session
    /// id. Hermes Desktop classifies the same condition by the
    /// `/session not found/i` message. Timeouts, busy rejections, connection
    /// loss, and compression failures are never in this class.
    static func isSessionNotFoundError(_ error: Error) -> Bool {
        if let rpcError = error as? RpcError {
            if rpcError.code == 4001 { return true }
            return rpcError.message.lowercased().contains("session not found")
        }
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        return message.lowercased().contains("session not found")
    }

    /// Whether `error` means the hosted room is gone/tombstoned: `groups.*`
    /// answers the room-error envelope (4112 "room not found" / 4114) unless
    /// the caller opted into disbanded rooms. The room's driver keeps
    /// running server-side; a client surface showing the room must close.
    static func isRoomNotFoundError(_ error: Error) -> Bool {
        if let rpcError = error as? RpcError {
            if rpcError.code == 4112 || rpcError.code == 4114 { return true }
            return rpcError.message.lowercased().contains("hosted room not found")
        }
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        return message.lowercased().contains("hosted room not found")
    }

    // MARK: - Attachments

    func attachImage(_ sessionId: String, base64: String, filename: String) async throws -> String? {
        let result = try await rpc("image.attach_bytes", params: [
            "session_id": sessionId,
            "content_base64": base64,
            "filename": filename
        ], timeout: Self.uploadTimeout(forPayloadCharacters: base64.utf8.count))
        return result.objectValue?["path"]?.stringValue
    }

    /// Takes back an image staged with `attachImage` before any prompt
    /// used it.
    func detachImage(_ sessionId: String, path: String) async throws {
        _ = try await rpc("image.detach", params: [
            "session_id": sessionId,
            "path": path
        ])
    }

    /// Stages any non-image file (PDFs included) in the session's
    /// attachments folder, the way Hermes Desktop sends files. Returns the
    /// `@file:` reference the prompt must carry: without it the agent is
    /// never told the file is there.
    func attachFile(_ sessionId: String, dataUrl: String, name: String, path: String = "") async throws -> String? {
        let result = try await rpc("file.attach", params: [
            "session_id": sessionId,
            "data_url": dataUrl,
            "name": name,
            "path": path
        ], timeout: Self.uploadTimeout(forPayloadCharacters: dataUrl.utf8.count))
        return Self.fileAttachmentReference(from: result)
    }

    /// The `@file:` reference from a `file.attach` reply: its `ref_text`,
    /// else one built from the staged path (a reply without `ref_text`).
    static func fileAttachmentReference(from result: AnyCodable) -> String? {
        let object = result.objectValue
        if let reference = object?["ref_text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           reference.hasPrefix("@file:"), reference.count > "@file:".count {
            return reference
        }
        let path = [object?["ref_path"], object?["path"]]
            .compactMap { $0?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let path else { return nil }
        return "@file:\(formatReferenceValue(path))"
    }

    /// Quotes a reference value that holds whitespace, brackets or quotes so
    /// Hermes reads it back whole (its `format_reference_value`).
    nonisolated static func formatReferenceValue(_ value: String) -> String {
        guard value.rangeOfCharacter(from: referenceValueQuotingCharacters) != nil else { return value }
        for quote in ["`", "\"", "'"] where !value.contains(quote) {
            return "\(quote)\(value)\(quote)"
        }
        return value
    }

    nonisolated private static let referenceValueQuotingCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "()[]{}<>\"'`"))

    // MARK: - Cron

    func listCronJobs() async throws -> [CronJob] {
        let result = try await rpc("cron.list")
        let arr = result.objectValue?["jobs"]?.arrayValue ?? result.arrayValue ?? []
        return arr.compactMap { try? JSONDecoder().decode(CronJob.self, from: JSONSerialization.data(withJSONObject: $0.anyValue)) }
    }

    func cronRuns() async throws -> [CronRun] {
        let result = try await rpc("cron.runs")
        let arr = result.objectValue?["runs"]?.arrayValue ?? result.arrayValue ?? []
        return arr.compactMap { try? JSONDecoder().decode(CronRun.self, from: JSONSerialization.data(withJSONObject: $0.anyValue)) }
    }

    // MARK: - Group Chats

    /// THE Group Chat capability call (`groups.capabilities`). A gateway old
    /// enough to lack the method has no hosted rooms; callers classify the
    /// thrown error with `isMissingRPCMethod`. Like the bot roster, rooms are
    /// gateway-wide, so every `groups.*` call below is sent UNSCOPED — the
    /// contract's optional `profile` param is multiplexed-gateway routing,
    /// and the dashboard profile context must never shrink the room catalog.
    func groupsCapabilities() async throws -> GroupCapabilities {
        let result = try await rpc("groups.capabilities", params: nil, scoped: false)
        guard let capabilities = GroupCapabilitiesDecoder.decode(result) else {
            throw HermesError.invalidResponse
        }
        return capabilities
    }

    /// Rooms hosted by the current gateway, most recently changed first.
    func groupsList(
        includeDisbanded: Bool = false,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> (rooms: [GroupRoom], nextOffset: Int?) {
        var params: [String: Any] = ["include_disbanded": includeDisbanded]
        if let limit { params["limit"] = limit }
        if let offset { params["offset"] = offset }
        let result = try await rpc("groups.list", params: params, scoped: false)
        guard let object = result.objectValue, let rows = object["rooms"]?.arrayValue else {
            throw HermesError.invalidResponse
        }
        return (rows.compactMap { GroupDecoders.room($0) }, Self.exactIntValue(object["next_offset"]))
    }

    /// Create a hosted room on the current gateway. `roomID` is the CLIENT-
    /// MINTED room identity AND idempotency key (the contract's mandatory
    /// field; the gateway's validator accepts ^[A-Za-z0-9][A-Za-z0-9._:-]*$
    /// up to 128 chars — a UUID fits). `members` carries this client's
    /// proposed roster rows (`member_id`/`profile`/`handle`/`display_name`
    /// for local bots); the gateway re-validates the frozen 2–6 roster and
    /// refuses ambiguous, duplicated, or reserved handles.
    func groupsCreate(roomID: String, name: String, members: [[String: Any]]) async throws -> GroupRoom {
        let result = try await rpc(
            "groups.create",
            params: ["room_id": roomID, "name": name, "members": members],
            scoped: false
        )
        guard let room = GroupDecoders.room(result.objectValue?["room"]) else {
            throw HermesError.invalidResponse
        }
        return room
    }

    /// One room's replay cursor, authority state, and live driver status.
    /// Tombstoned rooms are OPTED INTO by default: a poller must be able to
    /// OBSERVE a disband (`disbanded_at` set) to close its surface — with
    /// the default `false` the gateway answers "room not found" instead of
    /// the tombstone.
    func groupsState(roomID: String, includeDisbanded: Bool = true)
        async throws -> (room: GroupRoom, driverStatus: GroupDriverStatus?) {
        let result = try await rpc(
            "groups.state",
            params: ["room_id": roomID, "include_disbanded": includeDisbanded],
            scoped: false
        )
        guard let room = GroupDecoders.room(result.objectValue?["room"]) else {
            throw HermesError.invalidResponse
        }
        return (room, GroupDecoders.driverStatus(result.objectValue?["driver_status"]))
    }

    /// Append one inert `message.user` event. IDEMPOTENT: `eventID` is the
    /// client retry key — a retry after an ambiguous failure MUST reuse the
    /// same id; the gateway maps it to the server-owned `user:<sha256>` id,
    /// so the second send deduplicates instead of posting a twin. The actor
    /// is server-owned; the payload is exactly `{text, thread_id}`.
    func groupsSend(roomID: String, eventID: String, text: String, threadID: String)
        async throws -> GroupSendResult {
        let result = try await rpc(
            "groups.send",
            params: [
                "room_id": roomID,
                "event_id": eventID,
                "payload": ["text": text, "thread_id": threadID],
            ],
            scoped: false
        )
        guard let object = result.objectValue,
              let event = GroupDecoders.event(object["event"]) else {
            throw HermesError.invalidResponse
        }
        return GroupSendResult(
            event: event,
            accepted: object["accepted"]?.boolValue ?? true,
            driverStarted: object["driver_started"]?.boolValue ?? false
        )
    }

    /// One monotonic room-log delta after `sinceSeq`, bounded by the page
    /// limit (the gateway's own `max_log_limit` is the hard ceiling).
    func groupsLog(
        roomID: String,
        sinceSeq: Int,
        limit: Int? = nil,
        includeDisbanded: Bool = false
    ) async throws -> GroupLogPage {
        var params: [String: Any] = [
            "room_id": roomID,
            "since_seq": sinceSeq,
            "include_disbanded": includeDisbanded,
        ]
        if let limit { params["limit"] = limit }
        let result = try await rpc("groups.log", params: params, scoped: false)
        guard let page = GroupDecoders.logPage(result) else { throw HermesError.invalidResponse }
        return page
    }

    /// Permanently tombstone a hosted room. The gateway stops the room's
    /// work and revokes peer routes before writing the tombstone.
    func groupsDisband(roomID: String) async throws {
        _ = try await rpc("groups.disband", params: ["room_id": roomID], scoped: false)
    }

    /// Durably cancel queued or running work for one room. Only offered
    /// when `groupsCapabilities` advertised the method.
    func groupsStop(roomID: String) async throws -> Int {
        let result = try await rpc("groups.stop", params: ["room_id": roomID], scoped: false)
        return Self.exactIntValue(result.objectValue?["cancelled"]) ?? 0
    }

    /// Answer one member's pending approval (`groups.approve`). Every field
    /// comes from the `pending_actions` row: the gateway resolves only the
    /// exact request it is still holding and refuses a stale one. Only
    /// offered when `groupsCapabilities` advertised the method.
    ///
    /// Returns false when the gateway answered but resolved nothing: a local
    /// member's `result` is its `approval.respond` answer, whose `resolved`
    /// count is 0 once the request settled elsewhere. A peer member's receipt
    /// carries no count and counts as delivered.
    func groupsApprove(roomID: String, approval: GroupPendingApproval, choice: String) async throws -> Bool {
        let result = try await rpc(
            "groups.approve",
            params: [
                "room_id": roomID,
                "member_id": approval.memberID,
                "task_id": approval.taskID,
                "execution_generation": approval.executionGeneration,
                "choice": choice,
                "request_id": approval.requestID,
            ],
            scoped: false
        )
        guard let receipt = result.objectValue?["result"]?.objectValue,
              let resolved = receipt["resolved"] else { return true }
        return (Self.exactIntValue(resolved) ?? 1) > 0
    }

    // delegateAgentActivity moved to StreamEventParser
}

// MARK: - Supporting Types

struct ProviderInfo: Equatable {
    let name: String
    let models: [ModelInfo]
    /// Display name and alternate spellings Hermes accepts for this row. A
    /// saved `model.provider` can use any of them (e.g. `custom:<key>` for a
    /// row whose slug is the bare key), so matching on `name` alone misses it.
    var displayName: String? = nil
    var aliases: [String] = []
    /// Hermes marks the row backing the configured main model.
    var isCurrent = false
    /// Per-model speed support from the row's `capabilities`, keyed by
    /// model id. Empty on gateways that don't send it.
    var speedCapabilities: [String: ModelSpeedCapability] = [:]

    /// Whether `model` offers Ultrafast on this route and account. Nil when
    /// the row says nothing about the model.
    func offersUltrafast(_ model: String) -> Bool? {
        let wanted = Self.normalized(model)
        let caps = speedCapabilities[model]
            ?? speedCapabilities.first { Self.normalized($0.key) == wanted }?.value
        return caps.map(\.ultrafast)
    }

    /// True when `provider` names this row by slug, display name or alias,
    /// mirroring Hermes Desktop's `catalogProviderMatches`.
    func matches(_ provider: String) -> Bool {
        let wanted = Self.normalized(provider)
        guard !wanted.isEmpty else { return false }
        return ([name, displayName ?? ""] + aliases).contains { Self.normalized($0) == wanted }
    }

    /// Picker label: the catalog's display name, else the slug.
    var title: String {
        let display = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return display.isEmpty ? name : display
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The gateway's answer to `config.set model`.
struct ModelSwitchOutcome: Equatable {
    /// The model Hermes resolved the pick to (aliases expand).
    let model: String
    /// Nothing was switched; the user must confirm `confirmMessage` first.
    let confirmRequired: Bool
    let confirmMessage: String
    /// The session is mid-turn; the switch applies when the next turn starts.
    let deferred: Bool

    init(model: String, confirmRequired: Bool = false, confirmMessage: String = "", deferred: Bool = false) {
        self.model = model
        self.confirmRequired = confirmRequired
        self.confirmMessage = confirmMessage
        self.deferred = deferred
    }

    init(from result: AnyCodable, requestedModel: String) {
        let object = result.objectValue ?? [:]
        // Hermes reports the resolved model name, but a gateway that echoes
        // the raw request would hand back "<model> --provider <p> --session";
        // keep only the model part so the flags never reach `runtime.model`.
        let rawValue = object["value"]?.stringValue ?? ""
        let value = (rawValue.range(of: " --").map { String(rawValue[..<$0.lowerBound]) } ?? rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `warning` is Hermes' legacy alias for `confirm_message`.
        let message = [object["confirm_message"]?.stringValue, object["warning"]?.stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        self.init(
            model: value.isEmpty ? requestedModel : value,
            confirmRequired: object["confirm_required"]?.boolValue ?? false,
            confirmMessage: message,
            deferred: object["deferred"]?.boolValue ?? false
        )
    }
}

struct ModelSpeedCapability: Equatable {
    var fast: Bool
    /// Hermes sets it only when `ultrafast_offered` passes, which on the
    /// ChatGPT route reads the account's own Codex catalog.
    var ultrafast: Bool
}

struct ModelInfo: Equatable {
    let id: String
    let label: String?
    let reasoningCapable: Bool
}

extension ProviderInfo {
    init?(from codable: AnyCodable) {
        let object = codable.objectValue ?? [:]
        guard let name = object["slug"]?.stringValue ?? object["id"]?.stringValue ?? object["name"]?.stringValue,
              !name.isEmpty else { return nil }
        self.name = name
        self.displayName = object["name"]?.stringValue
        self.aliases = (object["aliases"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.isCurrent = object["is_current"]?.boolValue ?? false
        self.speedCapabilities = (object["capabilities"]?.objectValue ?? [:]).reduce(into: [:]) { result, entry in
            guard let caps = entry.value.objectValue else { return }
            result[entry.key] = ModelSpeedCapability(
                fast: caps["fast"]?.boolValue ?? false,
                ultrafast: caps["ultrafast"]?.boolValue ?? false
            )
        }
        self.models = (object["models"]?.arrayValue ?? []).compactMap { model in
            if let id = model.stringValue, !id.isEmpty {
                return ModelInfo(id: id, label: nil, reasoningCapable: false)
            }
            let item = model.objectValue ?? [:]
            guard let id = item["id"]?.stringValue ?? item["model"]?.stringValue ?? item["name"]?.stringValue,
                  !id.isEmpty else { return nil }
            return ModelInfo(
                id: id,
                label: item["label"]?.stringValue,
                reasoningCapable: item["reasoning"]?.boolValue ?? false
            )
        }
    }

}

struct ContextBreakdown {
    var categories: [(id: String, label: String, tokens: Int, color: String)]
    var contextMax: Int
    var contextPercent: Double
    var contextUsed: Int
    var estimatedTotal: Int
    var model: String?

    init(from codable: AnyCodable) {
        let obj = codable.objectValue ?? [:]
        self.categories = (obj["categories"]?.arrayValue ?? []).compactMap { cat in
            guard let id = cat.objectValue?["id"]?.stringValue,
                  let label = cat.objectValue?["label"]?.stringValue else { return nil }
            return (
                id: id,
                label: label,
                tokens: cat.objectValue?["tokens"]?.intValue ?? 0,
                color: cat.objectValue?["color"]?.stringValue ?? "amber"
            )
        }
        self.contextMax = obj["context_max"]?.intValue ?? 0
        self.contextPercent = obj["context_percent"]?.doubleValue ?? 0
        self.contextUsed = obj["context_used"]?.intValue ?? 0
        self.estimatedTotal = obj["estimated_total"]?.intValue ?? 0
        self.model = obj["model"]?.stringValue
    }

    /// Hermes versions have reported `context_percent` both as a 0...1
    /// fraction and a 0...100 percentage. Prefer the actual token totals when
    /// available so the composer ring has one stable representation.
    var resolvedUsed: Int {
        if contextUsed > 0 { return contextUsed }
        if estimatedTotal > 0 { return estimatedTotal }
        return categories.reduce(0) { $0 + $1.tokens }
    }

    var resolvedPercent: Double {
        // Match the desktop client's live gauge. Token arithmetic is useful
        // only for older gateways that omit the explicit usage value; several
        // context engines count categories differently from the active window.
        if contextPercent > 0 { return normalizedPercent(contextPercent) }
        if contextMax > 0, resolvedUsed > 0 {
            return min(max((Double(resolvedUsed) / Double(contextMax)) * 100, 0), 100)
        }
        return 0
    }
}

private func normalizedPercent(_ value: Double) -> Double {
    let percent = (0...1).contains(value) ? value * 100 : value
    return min(max(percent, 0), 100)
}

// Alias for backward compatibility
extension ContextBreakdown {
    var contextCount: Int {
        get { contextUsed }
        set { contextUsed = newValue }
    }
}

enum HermesError: Error, LocalizedError {
    case invalidUrl
    case invalidResponse
    case notConnected
    case connectionClosed
    case timeout(String)
    case steerRejected

    var errorDescription: String? {
        switch self {
        // Read by people who may not run servers: say what happened and
        // what to do, never an RPC method name.
        case .invalidUrl:
            return AppLocalization.string("The dashboard address isn't valid. Check it in Settings > Connection.")
        case .invalidResponse:
            return AppLocalization.string("Hermes sent a reply Conduit didn't understand. Updating Hermes and Conduit usually fixes this.")
        case .notConnected:
            return AppLocalization.string("Conduit isn't connected to Hermes right now. It reconnects on its own, so try again in a moment.")
        case .connectionClosed:
            return AppLocalization.string("The connection to Hermes dropped. Conduit reconnects on its own, so try again in a moment.")
        case .timeout:
            return Self.timeoutMessage
        case .steerRejected: return AppLocalization.string("Hermes could not steer the active response.")
        }
    }

    /// What any request to Hermes that ran out of time tells people.
    static var timeoutMessage: String {
        AppLocalization.string("Hermes didn't answer in time. Check that your Hermes server is running, then try again.")
    }
}

// MARK: - AnyCodable.from helper

extension AnyCodable {
    static func from(_ value: Any) -> AnyCodable {
        if value is NSNull { return .null }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? Int { return .number(Double(v)) }
        if let v = value as? Double { return .number(v) }
        if let v = value as? String { return .string(v) }
        if let v = value as? [Any] { return .array(v.map { AnyCodable.from($0) }) }
        if let v = value as? [String: Any] { return .object(v.mapValues { AnyCodable.from($0) }) }
        return .null
    }
}

// MARK: - Message Normalization

/// Hermes' persisted display-projection contract. Some model-facing records —
/// model switches, personality pivots, auto-continuations, background-agent
/// completions, internal wake notices — are persisted as `role=user` rows so
/// strict OpenAI-compatible providers accept them mid-history, while
/// `display_kind` tells clients they are not human-authored messages and
/// `display_content` overrides the physical `content` with the text that
/// should actually be visible. The recognized values mirror Hermes Desktop's
/// transcript hydration; an unrecognized value is deliberately given no
/// display semantics so a future kind can never delete or reinterpret an
/// ordinary visible row.
private enum HermesDisplayKind: String {
    case hidden
    case modelSwitch = "model_switch"
    case personalitySwitch = "personality_switch"
    case autoContinue = "auto_continue"
    case asyncDelegationComplete = "async_delegation_complete"
    case processComplete = "process_complete"
    case internalNotification = "internal_notification"
}

enum MessageNormalizer {

    static func normalizeProjects(_ payload: AnyCodable, profile: String?) -> [ProjectSummary] {
        let records = payload.objectValue?["projects"]?.arrayValue ?? payload.arrayValue ?? []
        return records.compactMap { normalizeProject($0, profile: profile) }
    }

    static func normalizeProject(_ item: AnyCodable, profile: String?) -> ProjectSummary? {
        let object = item.objectValue ?? [:]
        let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { return nil }
        let title = firstNonEmptyString([
            object["label"], object["name"], object["title"]
        ]) ?? AppLocalization.string("Untitled project")
        let previews = object["preview_sessions"]?.arrayValue
            ?? object["previewSessions"]?.arrayValue
            ?? []
        let isHome = object["isNoProject"]?.boolValue ?? object["is_no_project"]?.boolValue ?? false
        // Only projects created in Hermes have a projects.db row, and their ids
        // are `p_<hex>`. When a gateway omits the flag, any non-Home id without
        // that prefix is treated as auto, so rename and delete fail closed.
        let isAuto = object["isAuto"]?.boolValue
            ?? object["is_auto"]?.boolValue
            ?? (!isHome && !id.hasPrefix("p_"))
        let folderPath = firstNonEmptyString(
            object["folders"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue }.map(AnyCodable.string) ?? []
        )
        // `projects.tree` emits the project's `primary_path` as `path`, which
        // is null for an explicit project that never had one assigned or
        // whose primary folder was removed. The tree still seeds every
        // declared folder as a repo node, so anchor new conversations at the
        // first repo root, as Hermes Desktop does. Home is excluded from this
        // fallback only: a repo node there must not turn detached sessions
        // into folder-anchored ones.
        let repoPath = isHome ? nil : firstNonEmptyString(
            object["repos"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue }.map(AnyCodable.string) ?? []
        )
        let previewSessions = normalizeSessions(.array(previews), profile: profile)
        let count = object["session_count"]?.intValue
            ?? object["sessionCount"]?.intValue
            ?? object["session_count"]?.stringValue.flatMap(Int.init)
            ?? previewSessions.count
        return ProjectSummary(
            id: id,
            title: title,
            primaryPath: firstNonEmptyString([object["path"], object["primary_path"], object["primaryPath"]])
                ?? folderPath
                ?? repoPath,
            icon: object["icon"]?.stringValue,
            colorHex: object["color"]?.stringValue,
            isHome: isHome,
            isAuto: isAuto,
            sessionCount: count,
            previewSessions: previewSessions
        )
    }

    static func normalizeProjectSessions(_ payload: AnyCodable, profile: String?) -> ProjectSessionDetail? {
        guard let project = payload.objectValue?["project"]?.objectValue else { return nil }
        let id = project["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { return nil }
        let title = firstNonEmptyString([project["label"], project["name"], project["title"]]) ?? AppLocalization.string("Project")
        let repos = project["repos"]?.arrayValue ?? []
        let multipleRepos = repos.count > 1
        var lanes: [ProjectSessionLane] = []

        for repo in repos {
            let repoObject = repo.objectValue ?? [:]
            let repoLabel = firstNonEmptyString([repoObject["label"], repoObject["path"]]) ?? AppLocalization.string("Workspace")
            for group in repoObject["groups"]?.arrayValue ?? [] {
                let groupObject = group.objectValue ?? [:]
                let groupID = groupObject["id"]?.stringValue ?? UUID().uuidString
                let groupLabel = firstNonEmptyString([groupObject["label"], groupObject["path"]]) ?? AppLocalization.string("Sessions")
                let groupPath = firstNonEmptyString([groupObject["path"], groupObject["cwd"]])
                let sessions = normalizeSessions(.array(groupObject["sessions"]?.arrayValue ?? []), profile: profile)
                guard !sessions.isEmpty else { continue }
                lanes.append(ProjectSessionLane(
                    id: groupID,
                    title: multipleRepos ? "\(repoLabel) · \(groupLabel)" : groupLabel,
                    sessions: sessions,
                    path: groupPath == groupLabel ? nil : groupPath
                ))
            }
        }

        if lanes.isEmpty {
            let previews = project["preview_sessions"]?.arrayValue ?? project["previewSessions"]?.arrayValue ?? []
            let sessions = normalizeSessions(.array(previews), profile: profile)
            if !sessions.isEmpty {
                lanes = [ProjectSessionLane(id: "\(id)-recent", title: AppLocalization.string("Recent"), sessions: sessions)]
            }
        }
        return ProjectSessionDetail(id: id, title: title, lanes: lanes)
    }

    static func normalizeSessions(_ payload: AnyCodable, profile: String?) -> [SessionSummary] {
        let records: [AnyCodable]
        if let arr = payload.arrayValue {
            records = arr
        } else if let sessions = payload.objectValue?["sessions"]?.arrayValue {
            records = sessions
        } else {
            records = []
        }

        // Kanban workers' transcripts aren't chats (SessionSource.hermesKanbanSource):
        // every list built here leaves them out, whatever the server filtered
        // (the `session.list` fallback, project lanes and previews included).
        let chats = records.filter {
            $0.objectValue?["source"]?.stringValue?.lowercased() != SessionSource.hermesKanbanSource
        }
        return chats.enumerated().map { index, item in
            let obj = item.objectValue ?? [:]
            let runtimeSessionId = obj["session_id"]?.stringValue
            let id = runtimeSessionId ?? obj["id"]?.stringValue ?? String(index)
            let explicitStoredSessionId = ["stored_session_id", "storedSessionId"]
                .compactMap { obj[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let storedSessionId = explicitStoredSessionId ?? {
                // The legacy catalog shape exposes the durable ID as `id`
                // alongside a separate runtime `session_id`. A lone `id` is
                // ambiguous, so do not label it as a verified stored ID.
                guard runtimeSessionId != nil else { return nil }
                return obj["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }()

            // Collect alternate IDs
            let altKeys = ["session_id", "id", "stored_session_id", "runtime_session_id", "session_key"]
            let altIds = Set(altKeys.compactMap { obj[$0]?.stringValue }.filter { $0 != id && !$0.isEmpty })

            let explicitProfile = [
                "profile", "profile_name", "profileName", "profile_id", "profileId"
            ]
                .compactMap { obj[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let messageCount = ["message_count", "messageCount"].compactMap { key -> Int? in
                if let count = obj[key]?.intValue {
                    return count
                }
                if let count = obj[key]?.stringValue {
                    return Int(count)
                }
                return nil
            }.first

            return SessionSummary(
                id: id,
                storedSessionId: storedSessionId,
                alternateIds: Array(altIds),
                title: obj["title"]?.stringValue ?? obj["preview"]?.stringValue ?? AppLocalization.string("Untitled conversation"),
                model: obj["model"]?.stringValue ?? "Hermes",
                updatedLabel: sessionUpdatedLabel(in: obj),
                lastActivityAt: sessionActivityTimestamp(in: obj),
                profile: explicitProfile ?? profile,
                source: classifySource(obj),
                isActive: false,
                isArchived: obj["archived"]?.boolValue ?? false,
                messageCount: messageCount,
                isUnread: obj["unread"]?.boolValue,
                readWatermark: obj["last_read_at"]?.doubleValue,
                isPinned: obj["pinned"]?.boolValue,
                lineageRootId: obj["_lineage_root_id"]?.stringValue,
                // SQLite's 0/1: Hermes turns only `archived` and `pinned` into booleans.
                isAutoArchived: obj["auto_archived"].flatMap { $0.boolValue ?? $0.intValue.map { $0 != 0 } },
                endReason: obj["end_reason"]?.stringValue,
                preview: Self.sessionListPreview(in: obj)
            )
        }
    }

    /// A row's `preview`, kept only when the row also has a title: an
    /// untitled row already shows its preview as the title.
    static func sessionListPreview(in obj: [String: AnyCodable]) -> String? {
        guard let title = obj["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let preview = obj["preview"]?.stringValue?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty,
              preview != title else { return nil }
        return preview
    }

    /// The ordering instant for a session row, so restoration can rank
    /// conversations by ACTUAL activity instead of list position. It reads the
    /// same key list `sessionUpdatedLabel` walks, and deliberately DIVERGES
    /// from it on one point: that function falls through to a weaker field
    /// when a value cannot be formatted, while this returns nil, because an
    /// instant taken from a different field than the one the gateway reported
    /// ranks a row by a moment it does not describe. Units are normalized to
    /// epoch seconds (s/ms/µs/ns).
    ///
    /// The FIRST field the gateway reports is authoritative activity: when it
    /// is present but carries no machine-readable instant (a localized date
    /// string, a placeholder, a non-scalar), the row has NO ordering evidence
    /// and this returns nil. Scanning weaker fields would substitute a
    /// DIFFERENT instant for the one the gateway chose — a wrong-but-plausible
    /// value ranks a row it does not describe, which is worse than ranking it
    /// behind every dated row. Only a MISSING or null field falls through to
    /// the next key.
    static func sessionActivityTimestamp(in object: [String: AnyCodable]) -> TimeInterval? {
        for key in sessionActivityKeys {
            guard let value = object[key], value != .null else { continue }
            switch value {
            case .number(let timestamp):
                return normalizedSessionTimestamp(timestamp)
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timestamp = Double(trimmed) else { return nil }
                return normalizedSessionTimestamp(timestamp)
            default:
                return nil
            }
        }
        return nil
    }

    /// A positive, finite epoch instant in SECONDS from whatever unit the
    /// gateway reported. Gateways differ (and some have changed over time):
    /// seconds are ~1.7e9, milliseconds ~1.7e12, microseconds ~1.7e15,
    /// nanoseconds ~1.7e18. No real instant exceeds ~4e10 seconds (year 3300),
    /// so scaling anything larger down by 1000 until it fits reads every unit
    /// correctly — while a single divide (the old rule) left µs/ns payloads
    /// ranking "newest" forever.
    private static func normalizedSessionTimestamp(_ timestamp: Double) -> TimeInterval? {
        guard timestamp.isFinite else { return nil }
        var seconds = timestamp
        while seconds > 40_000_000_000 {
            seconds /= 1_000
        }
        guard seconds > 0 else { return nil }
        return seconds
    }

    private static let sessionActivityKeys = [
        "last_active", "lastActive", "updated_at", "updatedAt", "updated",
        "last_message_at", "lastMessageAt", "latest_message_at", "latestMessageAt",
        "modified_at", "modifiedAt", "created_at", "createdAt", "timestamp", "time"
    ]

    private static func sessionUpdatedLabel(in object: [String: AnyCodable]) -> String {
        let keys = sessionActivityKeys

        for key in keys {
            guard let value = object[key], value != .null else { continue }
            switch value {
            case .number(let timestamp):
                return formattedSessionTimestamp(timestamp)
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let timestamp = Double(trimmed) {
                    return formattedSessionTimestamp(timestamp)
                }
                return trimmed
            default:
                continue
            }
        }
        return "recently"
    }

    /// A row's time as the session list shows it: the time alone today,
    /// else the day and time. The saved chat list re-runs it at launch, so
    /// a row saved yesterday doesn't still read as today's.
    static func formattedSessionTimestamp(_ timestamp: Double) -> String {
        // The SAME unit normalization the ordering instant uses: a µs/ns
        // payload must not display one date and rank by another.
        guard let seconds = normalizedSessionTimestamp(timestamp) else {
            return String(timestamp)
        }
        let date = Date(timeIntervalSince1970: seconds)
        guard date.timeIntervalSince1970 > 0 else { return String(timestamp) }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func classifySource(_ obj: [String: AnyCodable]) -> SessionSource {
        // CRITICAL: classify BEFORE the chat whitelist (build 18 fix).
        // discord/telegram/webhook/api are NOT in the chat whitelist, so if we
        // test them against it, everything falls through to 'other'.

        let directSources = ["source", "origin", "platform"].compactMap { obj[$0]?.stringValue?.lowercased() }.filter { !$0.isEmpty }
        let handoffSource = (obj["handoff_platform"]?.stringValue ?? "").lowercased()

        // Check for cron metadata
        let hasCronMeta = ["cron_job_id", "cron_run_id", "scheduled_job_id", "schedule_id"].contains { obj[$0] != nil && obj[$0] != .null }
        let sessionId = (obj["session_id"]?.stringValue ?? obj["id"]?.stringValue ?? "").lowercased()
        let hasCronSessionId = sessionId.range(of: #"^(?:session[_:-])?cron[_:-]"#, options: .regularExpression) != nil
        let allReported = directSources + (handoffSource.isEmpty ? [] : [handoffSource])
        if hasCronMeta || hasCronSessionId || allReported.contains(where: {
            $0 == "cron" || $0 == "scheduled" || $0 == "scheduler" || $0.hasPrefix("cron:") || $0.hasPrefix("cron_") || $0.hasPrefix("scheduled:")
        }) {
            return .cron
        }

        // Classify external sources (RETURN IMMEDIATELY — do not fall through)
        func classify(_ source: String) -> SessionSource? {
            switch source {
            case "discord": return .discord
            case "telegram": return .telegram
            case "webhook": return .webhook
            case "api", "api-server", "api_server", "server": return .api
            default: return nil
            }
        }

        if let classified = directSources.compactMap(classify).first ?? classify(handoffSource) {
            return classified
        }

        let fallback = directSources.first ?? handoffSource
        let chatSources = ["", "desktop", "gateway", "tui", "chat", "web", "dashboard", "mobile", "cli", "local", "default", "unknown"]
        if chatSources.contains(fallback) { return .chat }
        return .other
    }

    /// `imageScope` names the session and profile the rows were read from,
    /// so pictures stored inside them can be fetched again (#652).
    static func normalizeMessages(
        _ payload: [AnyCodable],
        imageScope: TranscriptImageScope? = nil
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var callsById = [String: ChatMessage]()

        for (index, item) in payload.enumerated() {
            let envelope = item.objectValue ?? [:]
            // Session history can wrap the actual persisted message in a
            // `message`, `payload`, or (when it is itself a message) `data`
            // object. Do not merge an arbitrary `data` field from a stored
            // tool result: those fields are often the tool's own payload.
            let dataMessage = envelope["data"]?.objectValue.flatMap { data -> [String: AnyCodable]? in
                (data["role"] != nil || data["type"] != nil) ? data : nil
            }
            let nested = envelope["message"]?.objectValue
                ?? envelope["payload"]?.objectValue
                ?? dataMessage
                ?? [:]
            let obj = envelope.merging(nested) { _, nestedValue in nestedValue }

            // Hermes' display projection is resolved before any content work.
            // A hidden row is pure model-facing scaffolding (compaction
            // handoffs, interrupted-turn checkpoints) that can be
            // multi-megabyte, so it is dropped before Markdown, compaction
            // scans, reasoning extraction, or tool interpretation — and
            // regardless of its physical role.
            let displayKind = HermesDisplayKind(
                rawValue: (obj["display_kind"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if displayKind == .hidden { continue }

            let rawRole = (obj["role"]?.stringValue ?? obj["type"]?.stringValue ?? "").lowercased()
            let isToolResult = rawRole == "tool" || rawRole.contains("tool_result") || rawRole.contains("tool-result")
            // A mid-turn steer is persisted as its own `role=user` row typed
            // `display_kind: "steer"`, its text wrapped in Hermes'
            // out-of-band marker. It stays a user row (it IS the user's
            // words, and ordering evidence keeps counting it as a user
            // boundary); only the model-facing marker is removed and the
            // row is tagged so the transcript renders it as a steer.
            let isSteerRow = !isToolResult
                && rawRole == "user"
                && (obj["display_kind"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == ChatMessage.steerDisplayKind
            var role: MessageRole
            switch rawRole {
            case "user": role = .user
            case "system": role = .system
            case "reasoning", "thinking": role = .reasoning
            default: role = isToolResult ? .tool : .assistant
            }
            // The persisted `/messages` endpoint exposes SQLite message IDs as
            // numbers, whereas `session.resume` often has no stable message
            // identifier at all. Preserve either form so both sources retain
            // a deterministic row identity.
            let id = obj["id"]?.stringValue
                ?? obj["id"]?.descriptiveStringValue
                ?? obj["message_id"]?.stringValue
                ?? obj["message_id"]?.descriptiveStringValue
                ?? String(index)

            // `display_content` replaces the physical payload for
            // conversational rows. Tool results keep their legacy handling:
            // upstream only ever projects conversational rows, and a tool
            // output that merely contains display-like fields must not be
            // rewritten. The `??` keeps the physical carrier un-extracted
            // whenever a projection exists.
            let projectedContent = isToolResult ? nil : projectedDisplayContent(in: obj)
            let extractedContent = isToolResult
                ? extractToolOutput(obj)
                : projectedContent ?? extractContent(obj["content"] ?? obj["text"] ?? .null)
            // Compaction bookkeeping is removed before role/system/runtime
            // normalization so no summary text — standalone or merged onto a
            // real prompt — can reach a ChatMessage and the renderer.
            //
            // With an explicit display projection the physical carrier is
            // never scanned and the projected text is never re-judged: the
            // legacy delimiter search, the `_compressed_summary` flag, and
            // the summary-prefix guard cannot discard authentic
            // `display_content` (ordering matters here — the compatibility
            // filters are only for rows lacking display metadata).
            let rawContent: String?
            if let projected = projectedContent {
                rawContent = projected
            } else {
                rawContent = visibleContentRemovingCompaction(
                    from: obj,
                    content: extractedContent,
                    isToolResult: isToolResult
                )
            }
            guard var rawContent else {
                continue
            }
            if isSteerRow {
                rawContent = steerText(fromMarker: rawContent)
            }
            let modelChange = modelChangeActivity(fromText: rawContent)
            let systemNotice = systemNoticeText(fromText: rawContent)
            // A known synthetic display kind never renders as a human turn,
            // even when its persisted role is `user` and its text matches no
            // legacy marker. Unknown kinds keep ordinary normalization.
            if modelChange != nil || systemNotice != nil || (displayKind != nil && !isToolResult) {
                role = .system
            }
            let rowId = durableRowId(in: obj)
            let userContent: (content: String, rawContent: String?, attachments: [Attachment]?) = role == .user
                ? splitUserAttachmentReferences(rawContent, messageId: id, rowId: rowId, imageScope: imageScope)
                : (content: rawContent, rawContent: nil, attachments: nil)
            let content: String
            if let displayKind, !isToolResult {
                // `displayKind` is non-nil here only for the known synthetic
                // timeline kinds: hidden rows were already dropped and
                // unknown values fail raw-value decoding above.
                content = timelineNoticeContent(
                    for: displayKind,
                    projected: projectedContent,
                    metadata: obj["display_metadata"],
                    modelChange: modelChange,
                    systemNotice: systemNotice,
                    rawVisible: rawContent
                )
            } else {
                content = modelChange.map {
                    "[Model has been changed to \($0.provider)/\($0.model)]"
                } ?? systemNotice ?? userContent.content
            }

            let reasoning = role == .assistant ? extractContent(obj["reasoning"] ?? obj["reasoning_content"] ?? .null) : nil
            // This deliberately follows Desktop's persisted-transcript parser:
            // only an assistant row with an actual array of tool calls creates
            // call cards. Treating an object-shaped `tool_calls` field as an
            // invocation turns incidental metadata into a duplicate "Tool"
            // card, often at the end of a later assistant reply.
            let tools = role == .assistant ? extractToolCalls(obj) : []

            if isToolResult {
                let callId = firstNonEmptyString([
                    obj["tool_call_id"], obj["call_id"], obj["tool_use_id"]
                ]) ?? ""
                let name = extractToolName(obj)
                // An ID is authoritative. Desktop falls back to tool name only
                // for legacy rows which genuinely have no call ID; using a
                // name fallback after an ID mismatch can attach an old call's
                // result to every later response.
                let match: ChatMessage?
                if !callId.isEmpty {
                    match = callsById[callId]
                } else if let name, !name.isEmpty {
                    match = messages.reversed().first { candidate in
                        guard let tool = candidate.tool else { return false }
                        return tool.name == name && (tool.output?.isEmpty != false)
                    }
                } else {
                    match = nil
                }
                if let match {
                    var updated = match
                    // A `tool_call` wrapper whose envelope didn't say which
                    // tool it ran takes the name its result was saved under.
                    if !callId.isEmpty, ToolSearchBridge.isWrapper(match.tool?.name),
                       ToolSearchBridge.isConcrete(name), let name {
                        updated.tool?.name = name
                    }
                    updated.tool?.output = content.isEmpty ? (match.tool?.output ?? "") : content
                    updated.tool?.status = .complete
                    updated.tool?.duration = toolDuration(in: obj)
                        ?? ChatStepTiming.elapsed(from: match.timestamp, to: extractTimestamp(obj))
                    if let idx = messages.firstIndex(where: { $0.id == match.id }) {
                        messages[idx] = updated
                        if !callId.isEmpty { callsById[callId] = updated }
                    }
                } else if let name = name as String?, !name.isEmpty {
                    // `session.resume` exposes a compact tool row with a
                    // context preview but deliberately omits its raw output.
                    // Preserve that as input instead of mislabeling it as an
                    // output after a reload.
                    let preview = content.isEmpty ? extractToolContext(obj) : nil
                    // Its compact row names Tool Search's wrapper, with the
                    // wrapper's envelope as `args`.
                    let shownName = ToolSearchBridge.isWrapper(name)
                        ? ToolSearchBridge.underlyingCall((obj["args"] ?? obj["arguments"])?.anyValue)?.name ?? name
                        : name
                    let m = ChatMessage(
                        id: id, role: .tool, content: "", timestamp: extractTimestamp(obj),
                        author: extractAuthor(obj), reasoning: nil,
                        tool: ToolActivity(
                            id: callId.isEmpty ? nil : callId,
                            name: shownName,
                            input: preview,
                            output: content.isEmpty ? nil : content,
                            status: .complete
                        )
                    )
                    messages.append(m)
                }
                continue
            }

            if let reasoning, !reasoning.isEmpty, !isDuplicateReasoning(reasoning, content) {
                messages.append(ChatMessage(
                    id: "\(id)-reasoning",
                    role: .reasoning,
                    content: reasoning,
                    timestamp: extractTimestamp(obj),
                    author: extractAuthor(obj)
                ))
            }

            // Timeline-projected rows are never self-improvement reviews, and
            // skipping detection also keeps their physical carrier
            // un-extracted.
            let review = role == .system && displayKind == nil
                ? reviewActivity(from: obj, eventSessionId: nil)
                : nil
            let base = ChatMessage(
                id: id,
                role: role,
                content: content,
                rawContent: modelChange == nil && systemNotice == nil ? userContent.rawContent : rawContent,
                timestamp: extractTimestamp(obj),
                author: extractAuthor(obj),
                reasoning: nil,
                review: review,
                attachments: userContent.attachments,
                displayKind: displayKind?.rawValue
                    ?? (isSteerRow && role == .user ? ChatMessage.steerDisplayKind : nil),
                rowId: rowId,
                reactions: messageReactions(fromMetadata: obj["display_metadata"])
            )

            // External session history occasionally includes a role-less
            // metadata envelope after the last real message. It normalizes to
            // `.assistant` with no text or tool calls; rendering that record
            // creates a phantom agent header with only its timestamp/actions.
            // Keep intentionally empty user rows (they can carry a locally
            // cached image attachment) and tool-only assistant rows, but omit
            // an assistant row that has no visible content of its own.
            if !content.isEmpty || (role != .assistant && tools.isEmpty) {
                messages.append(base)
            }

            for (toolIndex, tool) in tools.enumerated() {
                let callRow = ChatMessage(
                    id: "\(id)-tool-\(toolIndex)", role: .tool, content: "",
                    timestamp: base.timestamp, author: base.author, tool: tool
                )
                messages.append(callRow)
                if let toolId = tool.id { callsById[toolId] = callRow }
            }
        }

        return collapseDuplicateInterruptCorrections(in: messages)
    }

    /// `display_content` is the authoritative visible payload whenever the
    /// field exists — including an explicit empty string, JSON null, or an
    /// odd scalar, all of which resolve to authoritative empty text rather
    /// than a fallback. Field presence is the authority boundary: once the
    /// field exists, the physical carrier must never resurface, because a
    /// malformed projection falling back to physical content could expose
    /// model-facing internal rows. Nil return therefore means exactly
    /// "field absent".
    private static func projectedDisplayContent(in obj: [String: AnyCodable]) -> String? {
        guard let value = obj["display_content"] else { return nil }
        return extractContent(value)
    }

    /// `display_metadata` may arrive as a JSON object (current servers) or as
    /// unparsed JSON text (older backends). Anything malformed degrades to
    /// nil so a bad sidecar can never fail session normalization.
    private static func displayMetadataObject(_ value: AnyCodable?) -> [String: AnyCodable]? {
        guard let value else { return nil }
        if let object = value.objectValue { return object }
        guard let text = value.stringValue,
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return nil
        }
        return object.mapValues { AnyCodable.from($0) }
    }

    /// The durable `messages.id` a reaction addresses. A gateway resume row
    /// names it `row_id`; a REST transcript row carries it as its numeric
    /// `id` (a string `id` is some other identity, never a row address).
    static func durableRowId(in obj: [String: AnyCodable]) -> Int? {
        let rowId = HermesClient.exactIntValue(obj["row_id"])
            ?? HermesClient.exactIntValue(obj["id"])
        guard let rowId, rowId > 0 else { return nil }
        return rowId
    }

    /// Reactions persisted under `display_metadata.reactions`. Entries
    /// without an emoji or an author are skipped; anything malformed reads
    /// as none.
    static func messageReactions(fromMetadata metadata: AnyCodable?) -> [MessageReaction] {
        messageReactions(from: displayMetadataObject(metadata)?["reactions"])
    }

    /// A `MessageReaction` list as Hermes sends it (`message.react` result,
    /// `message.reaction` event, stored metadata).
    static func messageReactions(from value: AnyCodable?) -> [MessageReaction] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let emoji = object["emoji"]?.stringValue?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !emoji.isEmpty else { return nil }
            guard let author = object["author"]?.stringValue?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !author.isEmpty else { return nil }
            return MessageReaction(emoji: emoji, author: author, at: object["at"]?.doubleValue)
        }
    }

    /// The one-line title Hermes stamps on a background completion's
    /// `display_metadata.display_text` (Desktop's `timelineDisplayText`).
    /// Blank or non-string values degrade to nil.
    private static func timelineDisplayText(metadata: AnyCodable?) -> String? {
        guard let text = displayMetadataObject(metadata)?["display_text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Upstream persists `task_count` on `async_delegation_complete` rows so
    /// clients can phrase the completion notice. The count goes through
    /// `doubleValue` + `Int(exactly:)` so non-representable numbers (1e100,
    /// NaN, fractional) degrade to the generic notice instead of trapping
    /// normalization — malformed metadata must never fail hydration.
    private static func delegationTaskCount(metadata: AnyCodable?) -> Int? {
        guard let count = displayMetadataObject(metadata)?["task_count"]?.doubleValue,
              let taskCount = Int(exactly: count),
              taskCount > 0 else { return nil }
        return taskCount
    }

    private static func delegationCompleteNotice(metadata: AnyCodable?) -> String {
        guard let taskCount = delegationTaskCount(metadata: metadata) else {
            return AppLocalization.string("Background agent work finished")
        }
        return AppLocalization.string("\(taskCount) background agents finished")
    }

    /// Final visible text for a row Hermes tags with a known synthetic
    /// display kind. These rows are timeline events — Hermes Desktop renders
    /// canned labels for them — so the physical scaffold text is never shown
    /// unless an explicit `display_content` projection supplies better copy.
    private static func timelineNoticeContent(
        for kind: HermesDisplayKind,
        projected: String?,
        metadata: AnyCodable?,
        modelChange: (model: String, provider: String)?,
        systemNotice: String?,
        rawVisible: String
    ) -> String {
        // `projected` is non-nil only when the `display_content` field
        // exists, and its value — including an explicit empty string — is
        // authoritative: trimming an empty projection back into absence
        // would fall through to canned labels or the physical carrier,
        // which must never resurface.
        switch kind {
        case .hidden:
            // Defense in depth: hidden rows are dropped before content work.
            // Never echo the physical carrier if that invariant ever breaks.
            return AppLocalization.string("Hidden system event")
        case .modelSwitch:
            // An explicit projection outranks the marker-derived card text;
            // without one, the persisted marker matches Conduit's existing
            // model-change card detection and keeps that presentation. A
            // marker the card regex cannot parse is still model scaffold, so
            // it degrades to the canned label rather than rendering raw.
            if let projected {
                return projected
            }
            if let modelChange {
                return "[Model has been changed to \(modelChange.provider)/\(modelChange.model)]"
            }
            return AppLocalization.string("Model changed")
        case .personalitySwitch:
            // The physical marker embeds the full persona prompt; surface a
            // canned label instead, like Hermes Desktop does.
            return projected ?? AppLocalization.string("Personality changed")
        case .autoContinue:
            return projected ?? AppLocalization.string("Resumed interrupted turn")
        case .asyncDelegationComplete:
            // The localized count notice outranks Hermes' English
            // `display_text`; the title covers rows that carry no usable count.
            if let projected { return projected }
            if delegationTaskCount(metadata: metadata) == nil,
               let title = timelineDisplayText(metadata: metadata) {
                return title
            }
            return delegationCompleteNotice(metadata: metadata)
        case .processComplete:
            // A background-process completion is a self-injected turn whose
            // physical text is the whole `[IMPORTANT: …]` output wall written
            // for the model. Hermes stamps a compact title in
            // `display_text`; the canned label covers rows without one.
            return projected
                ?? timelineDisplayText(metadata: metadata)
                ?? AppLocalization.string("Background process finished")
        case .internalNotification:
            // The row content is the operational notice itself (wake events,
            // background completions); show it as a system notice. An
            // explicit projection — including an empty one — is authoritative
            // and rendered verbatim; the canned label is only for rows that
            // have no projection at all, and the `[System: …]` strip applies
            // only to that no-projection fallback.
            if let projected {
                return projected
            }
            let visible = systemNotice ?? rawVisible
            return visible.isEmpty ? AppLocalization.string("System notification") : visible
        }
    }

    static func modelChangeActivity(fromText text: String) -> (model: String, provider: String)? {
        let pattern = #"^\s*\[?System:\s*The active model for this chat has changed to\s+(\S+)\s+via provider\s+(.+?)(?:\.\s+From this point forward\b|\.?\]\s*$|$)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let modelRange = Range(match.range(at: 1), in: text),
              let providerRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        let model = String(text[modelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = String(text[providerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !provider.isEmpty else { return nil }
        return (model, provider)
    }

    /// Hermes persists runtime instructions as transcript messages. They are
    /// not user prompts and should never inherit the outgoing user bubble.
    static func systemNoticeText(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "[System:"
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            var body = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix("]") {
                body.removeLast()
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return body.isEmpty ? nil : body
        }
        if isUserCorrectionInterruptionNotice(trimmed) {
            return AppLocalization.string("Response interrupted by a user correction.")
        }
        return nil
    }

    /// Hermes wraps a delivered steer as
    /// `[OUT-OF-BAND USER MESSAGE — …]\n<text>\n[/OUT-OF-BAND USER MESSAGE]`
    /// so the model trusts it. Returns the user's own text; anything that
    /// does not carry the marker is returned trimmed but otherwise as is.
    static func steerText(fromMarker text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let opener = "[OUT-OF-BAND USER MESSAGE"
        let closer = "[/OUT-OF-BAND USER MESSAGE]"
        // The header ends at its own `]` on the first line; never scan into
        // the user's text, which may contain brackets.
        let headerLine = body.prefix(while: { $0 != "\n" })
        if body.hasPrefix(opener), let end = headerLine.firstIndex(of: "]") {
            body = String(body[body.index(after: end)...])
        }
        if body.hasSuffix(closer) {
            body = String(body.dropLast(closer.count))
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isUserCorrectionInterruptionNotice(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("[This response was interrupted by a user correction.]") == .orderedSame
    }

    /// Hermes persists context-compaction summaries as ordinary transcript
    /// records — usually under a conversational role, and sometimes appended
    /// to a row that still holds the genuine user prompt. They are
    /// model-context bookkeeping, not chat messages, and can be large enough
    /// to stall the Markdown pipeline when mistaken for a visible bubble.
    /// Returns the content that should remain visible, or nil when the whole
    /// record is compaction bookkeeping and must not produce a ChatMessage.
    /// Tool-result rows bypass the filter: compaction artifacts only ride
    /// conversational roles, while a tool's own output may legitimately print
    /// the delimiter text.
    private static func visibleContentRemovingCompaction(
        from obj: [String: AnyCodable],
        content: String,
        isToolResult: Bool
    ) -> String? {
        if isToolResult { return content }

        // Standalone summaries announce themselves within the first bytes.
        // Dropping them here skips the merged-delimiter search, which would
        // otherwise walk a potentially multi-megabyte payload end-to-end.
        if hasCompactionSummaryPrefix(content) { return nil }

        if let range = content.range(of: compactionSummaryDelimiter) {
            // Merged row: the genuine prompt sits before the delimiter behind
            // an optional wrapper header; the summary suffix is never shown.
            // The flag does not preempt this branch — it marks the record as
            // carrying a summary, not as lacking a genuine prompt.
            var visible = String(content[..<range.lowerBound])
            // Strip the wrapper only as a leading header — a copy the user
            // quoted mid-message belongs to their message.
            if visible.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix(priorContextWrapperHeader),
                let wrapperRange = visible.range(of: priorContextWrapperHeader) {
                visible.removeSubrange(wrapperRange)
            }
            let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
            // After a second compaction the retained prefix can itself be an
            // older summary rather than a genuine prompt.
            guard !trimmed.isEmpty, !hasCompactionSummaryPrefix(trimmed) else { return nil }
            return trimmed
        }

        let flaggedAsSummary = obj["_compressed_summary"]?.boolValue == true
            || obj["metadata"]?.objectValue?["_compressed_summary"]?.boolValue == true
        // Flagged with no merged form is pure bookkeeping.
        return flaggedAsSummary ? nil : content
    }

    private static let compactionSummaryDelimiter =
        "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"

    private static let priorContextWrapperHeader =
        "[PRIOR CONTEXT — for reference only; not a new message]"

    /// Hermes emits multiple generations of compaction headers, and the
    /// reload path can drop the `_compressed_summary` flag while keeping the
    /// recognizable text. Match case-insensitively like the other Hermes
    /// bracketed notices, anchored at the start of the content so ordinary
    /// discussion of "context compaction" is never mistaken for a summary.
    /// Classification reads only a bounded head: leading whitespace is
    /// skipped by index and only the next 32 characters are compared, so a
    /// multi-megabyte summary is never copied or tail-scanned to classify it.
    static func hasCompactionSummaryPrefix(_ content: String) -> Bool {
        var headStart = content.startIndex
        while headStart < content.endIndex, content[headStart].isWhitespace {
            headStart = content.index(after: headStart)
        }
        let head = content[headStart...].prefix(32).lowercased()
        return head.hasPrefix("[context compaction")
            || head.hasPrefix("[context summary]:")
            || head.hasPrefix("[recent summary (")
    }

    /// Normalizes the gateway's native clarification event into one
    /// batch-capable activity. Current Hermes sends
    /// `clarify.request { questions: [{qid, question, choices, multi_select}] }`;
    /// older shapes send one scalar `question`. The scalar form normalizes
    /// into a one-question batch so the rest of the app never branches on the
    /// wire generation. Returns nil for payloads with no request id or no
    /// answerable question — deliberately dropped, never half-presented.
    static func clarifyActivity(from payload: [String: AnyCodable]) -> ClarifyActivity? {
        let requestIDCandidates = ["request_id", "requestId", "id"]
            .compactMap { payload[$0]?.stringValue }
        let requestId = requestIDCandidates
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requestId.isEmpty else { return nil }

        if let rawQuestions = payload["questions"]?.arrayValue, !rawQuestions.isEmpty {
            // Preserve gateway order; drop duplicate qids — questions key the
            // UI (Identifiable ForEach) and per-question respond, so a repeat
            // qid would crash the render and make answers ambiguous.
            var questions: [ClarifyQuestion] = []
            for entry in rawQuestions {
                guard let question = clarifyQuestion(from: entry.objectValue ?? [:]) else { continue }
                if !questions.contains(where: { $0.id == question.id }) {
                    questions.append(question)
                }
            }
            if !questions.isEmpty {
                return ClarifyActivity(requestId: requestId, questions: questions)
            }
            // A `questions[]` payload where nothing survived parsing falls
            // through to the scalar shape so a hypothetical hybrid payload
            // still presents; otherwise it drops below.
        }

        // Legacy scalar shape (also the single-question form current gateways
        // still emit — it keeps the exact pre-batch payload).
        guard let question = scalarClarifyText(in: payload), !question.isEmpty else {
            return nil
        }
        let choices = clarifyChoices(from: payload)
        let multiSelect = payload["multi_select"]?.boolValue == true && !choices.isEmpty
        return ClarifyActivity(
            requestId: requestId,
            questions: [
                ClarifyQuestion(
                    id: "q0",
                    question: question,
                    choices: choices,
                    multiSelect: multiSelect,
                    // Locally minted UI identity: it must never ride the
                    // wire as question_id (real gateway batches also use
                    // q0-style ids, so the flag — not the value — decides).
                    isSyntheticID: true
                )
            ]
        )
    }

    /// One batch question. The gateway `qid` is the identity and is preserved
    /// verbatim — it is what per-question `clarify.respond` keys on. A qid-less
    /// entry has no per-question protocol address (an absent `question_id`
    /// would cancel the whole request server-side) and a question with no text
    /// is unanswerable; both are rejected deliberately.
    private static func clarifyQuestion(from object: [String: AnyCodable]) -> ClarifyQuestion? {
        let text = scalarClarifyText(in: object) ?? ""
        guard !text.isEmpty else { return nil }
        // Explicit [String] annotation: the inline literal plus a multiline
        // closure body otherwise confuses the type-checker into the wrong
        // Dictionary subscript overload.
        let qidKeys: [String] = ["qid", "question_id", "id"]
        let qidCandidates = qidKeys.compactMap { key -> String? in
            object[key]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        guard let qid = qidCandidates.first else { return nil }
        let choices = clarifyChoices(from: object)
        let multiSelect = object["multi_select"]?.boolValue == true && !choices.isEmpty
        return ClarifyQuestion(id: qid, question: text, choices: choices, multiSelect: multiSelect)
    }

    private static func scalarClarifyText(in object: [String: AnyCodable]) -> String? {
        ["question", "prompt", "text"]
            .compactMap { key in object[key].map { extractContent($0) } }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Choices accept the native string form plus the older label/value object
    /// integration; duplicates by value are dropped.
    private static func clarifyChoices(from object: [String: AnyCodable]) -> [ClarifyChoice] {
        let rawChoices = object["choices"]?.arrayValue ?? object["options"]?.arrayValue ?? []
        let choices = rawChoices.compactMap { choice -> ClarifyChoice? in
            if let text = choice.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return ClarifyChoice(label: text, value: text)
            }
            guard let choice = choice.objectValue else { return nil }
            let labelCandidates = ["label", "title", "text", "name", "value"]
                .compactMap { key in choice[key].map { extractContent($0) } }
            let label = labelCandidates
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let valueCandidates = ["value", "answer", "id"]
                .compactMap { key in choice[key].map { extractContent($0) } }
            let value = valueCandidates
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? label
            guard !label.isEmpty, !value.isEmpty else { return nil }
            return ClarifyChoice(label: label, value: value)
        }
        return choices.reduce(into: [ClarifyChoice]()) { result, choice in
            if !result.contains(where: { $0.value == choice.value }) { result.append(choice) }
        }
    }

    /// Reconstructs a clarification from the gateway's authoritative
    /// `pending_clarify` snapshot (`session.resume`): the same payload as the
    /// one-shot `clarify.request`, plus the answers locked before the client
    /// detached, keyed by `qid`. Locked answers are accepted in either wire
    /// form — the array string the app sends, or a real JSON array echo. A
    /// qid locked with null or an empty answer was left blank (skipped).
    static func pendingClarifyActivity(from payload: [String: AnyCodable]) -> ClarifyActivity? {
        guard var activity = clarifyActivity(from: payload) else { return nil }
        let answers = payload["answers"]?.objectValue ?? [:]
        guard !answers.isEmpty else { return activity }
        for index in activity.questions.indices {
            guard let raw = answers[activity.questions[index].id] else { continue }
            let answer: String?
            if raw == .null {
                answer = ""
            } else if let text = raw.stringValue {
                answer = text
            } else if let values = raw.arrayValue?.compactMap(\.stringValue) {
                answer = ClarifyQuestion.multiSelectAnswer(values)
            } else {
                answer = nil
            }
            guard let answer else { continue }
            activity.questions[index].status = .answered
            activity.questions[index].answer = answer
        }
        return activity
    }

    /// Normalizes Hermes' session-scoped command approval event. The current
    /// gateway sends `approval.request { command, description, choices }` and
    /// waits for `approval.respond { choice, session_id }` before continuing.
    static func approvalActivity(
        from payload: [String: AnyCodable],
        sessionId: String
    ) -> ApprovalActivity? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }
        let requestId = ["request_id", "requestId"]
            .compactMap { payload[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        let command = ["command", "code", "text"]
            .compactMap { payload[$0]?.stringValue }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = ["description", "message", "prompt"]
            .compactMap { payload[$0]?.stringValue }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? AppLocalization.string("Approval required")
        let choices = payload["choices"]?.arrayValue?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniqueChoices = choices.map { values in
            values.reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        }

        return ApprovalActivity(
            sessionId: normalizedSessionId,
            requestId: requestId,
            command: command,
            description: description,
            choices: uniqueChoices?.isEmpty == true ? nil : uniqueChoices,
            allowPermanent: payload["allow_permanent"]?.boolValue != false,
            smartDenied: payload["smart_denied"]?.boolValue == true,
            status: .pending
        )
    }

    private static func collapseDuplicateInterruptCorrections(in messages: [ChatMessage]) -> [ChatMessage] {
        var collapsed: [ChatMessage] = []
        for message in messages {
            guard message.role == .user,
                  let interruption = collapsed.last,
                  interruption.role == .system,
                  isUserCorrectionInterruptionNotice(interruption.rawContent ?? interruption.content),
                  let previousUser = collapsed.dropLast().last(where: { $0.role == .user }),
                  previousUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    == message.content.trimmingCharacters(in: .whitespacesAndNewlines) else {
                collapsed.append(message)
                continue
            }

            // Redirect persists the correction in Hermes itself. If it is an
            // exact repeat of the interrupted prompt, one visible bubble is
            // enough; retain the interruption marker and original user row.
        }
        return collapsed
    }

    /// A user prompt's visible text once `@image:` tokens, leading `@file:`
    /// references and Hermes' attached-context footer are projected out —
    /// what a persisted user row's `content` holds.
    static func visibleUserText(_ source: String) -> String {
        splitUserAttachmentReferences(source, messageId: "").content
    }

    /// A persisted user prompt as its bubble shows it: images (`@image:`
    /// tokens) and staged files (leading `@file:` lines, how Conduit and
    /// Desktop send them) become attachments, and the context Hermes
    /// expanded for the model below the typed text is dropped. The original
    /// prompt is retained for replay/branch operations.
    private static func splitUserAttachmentReferences(
        _ source: String,
        messageId: String,
        rowId: Int? = nil,
        imageScope: TranscriptImageScope? = nil
    ) -> (content: String, rawContent: String?, attachments: [Attachment]?) {
        let images = splitUserImageReferences(
            source,
            messageId: messageId,
            rowId: rowId,
            imageScope: imageScope
        )
        let files = splitLeadingFileReferences(
            removingContextFooter(images.content),
            messageId: messageId
        )
        guard files.content != images.content else { return images }
        let attachments = files.attachments + (images.attachments ?? [])
        // Without Hermes' picture stand-ins, which a branch must not replay.
        return (files.content, images.rawContent ?? source, attachments.isEmpty ? nil : attachments)
    }

    /// Hermes appends what it expanded for `@file:`/`@url:` references below
    /// the typed text ("--- Context Warnings ---", "--- Attached Context ---").
    /// That is for the model; like Desktop, the bubble shows only the text.
    /// Hermes only adds the footer to a prompt holding a reference, so a
    /// heading typed in a message without one stays.
    static func removingContextFooter(_ text: String) -> String {
        guard let footer = text.range(
            of: #"(?:^|\n)--- (?:Context Warnings|Attached Context) ---[ \t]*(?:\r?\n|$)"#,
            options: .regularExpression
        ) else { return text }
        let visible = String(text[..<footer.lowerBound])
        // Hermes' reference shapes (`context_references.REFERENCE_PATTERN`
        // and its plugin fallback): `@diff`, `@staged`, or `@kind:value`.
        guard visible.range(
            of: #"(?<![\w/])@(?:diff\b|staged\b|[A-Za-z][A-Za-z0-9_-]*:\S)"#,
            options: .regularExpression
        ) != nil else { return text }
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One whole line holding one `@file:` reference, its value quoted the
    /// way Hermes quotes one (`format_reference_value`) or bare.
    private static let fileReferenceLine = try? NSRegularExpression(
        pattern: #"^@file:(?:`([^`\r\n]+)`|"([^"\r\n]+)"|'([^'\r\n]+)'|(\S+))$"#
    )

    /// The run of `@file:` lines a prompt opens with becomes document
    /// attachments; a reference typed inside the text stays where it is.
    static func splitLeadingFileReferences(
        _ text: String,
        messageId: String
    ) -> (content: String, attachments: [Attachment]) {
        guard let expression = fileReferenceLine else { return (text, []) }
        var lines = text.components(separatedBy: "\n")
        var paths: [String] = []
        while let first = lines.first {
            let line = first.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range) else { break }
            var path: String?
            for group in 1..<match.numberOfRanges {
                if let valueRange = Range(match.range(at: group), in: line) {
                    path = String(line[valueRange])
                    break
                }
            }
            guard let path, !path.isEmpty else { break }
            paths.append(path)
            lines.removeFirst()
        }
        guard !paths.isEmpty else { return (text, []) }
        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = paths.enumerated().map { index, path in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let type = url.pathExtension.isEmpty ? nil : UTType(filenameExtension: url.pathExtension)
            return Attachment(
                id: "\(messageId)-gateway-file-\(index)",
                name: name.isEmpty ? AppLocalization.string("Attached file") : name,
                uri: path,
                mimeType: AttachmentTypePolicy.mimeType(for: type),
                kind: AttachmentTypePolicy.kind(for: type)
            )
        }
        return (content, attachments)
    }

    /// `@image:` tokens, quoted the way Hermes quotes one
    /// (`format_reference_value`) or bare.
    private static let imageReferencePattern = try? NSRegularExpression(
        pattern: #"@image:(?:`([^`\r\n]+)`|"([^"\r\n]+)"|'([^'\r\n]+)'|([^\s]+))"#
    )

    /// The gateway's note for a picture that came in through a chat
    /// platform or a bot (`agent/image_routing.py`).
    private static let imageHintPattern = try? NSRegularExpression(
        pattern: #"\[Image attached at: ([^\n\]]+)\]"#
    )

    /// The caption the gateway writes when a picture arrives without one.
    private static let defaultImageCaption = "What do you see in this image?"

    /// What Hermes saved in place of a picture before hermes-agent d0f5ef7041
    /// (v0.21): the model-only description vision wrote for it, then where
    /// the file is. tui_gateway (`_enrich_with_attached_images`) and the
    /// chat platform gateway (`_enrich_message_with_vision`) word it
    /// differently, and each has a wording for a failed analysis. Group 1 is
    /// the description when there is one, the last group the path.
    private static let visionEnrichmentPatterns: [NSRegularExpression] = [
        #"\[The user attached an image:\r?\n(.*?)\]\r?\n\[You can examine it with vision_analyze using image_url: ([^\]\r\n]+)\]"#,
        #"\[The user attached an image but analysis failed\.\]\r?\n\[You can examine it with vision_analyze using image_url: ([^\]\r\n]+)\]"#,
        #"\[The user sent an image~ Here's what I can see:\r?\n(.*?)\]\r?\n\[If you need a closer look, use vision_analyze with image_url: (\S+) ~\]"#,
        #"\[The user sent an image but [^\[\]]*? with vision_analyze using image_url: ([^\]\r\n]+)\]"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.dotMatchesLineSeparators]) }

    /// What Hermes puts in place of each picture it leaves out of a
    /// transcript read with `inline_images=false` (#652).
    static let inlineImageMarker = "[image]"

    private static let inlineImagePartTypes: Set<String> = ["image_url", "input_image", "image"]

    /// A content part carrying a picture (OpenAI `image_url`/`input_image`,
    /// Anthropic or MCP `image`), as opposed to some other object whose
    /// `type` happens to say image.
    static func isInlineImagePart(_ part: [String: AnyCodable]) -> Bool {
        guard let type = part["type"]?.stringValue, inlineImagePartTypes.contains(type) else { return false }
        return ["image_url", "image", "source", "data", "file_id"].contains { part[$0] != nil }
    }

    /// Splits Hermes' trailing picture stand-ins off a persisted prompt.
    /// Hermes appends one line per picture after the text, so only a
    /// trailing run counts and a typed "[image]" inside the text stays. A
    /// bare `data:image/…` line (a gateway that writes pictures out as text)
    /// counts as one too and is never shown.
    static func trailingInlineImageMarkers(_ text: String) -> (text: String, count: Int) {
        guard text.contains(inlineImageMarker) || text.contains("data:image/") else { return (text, 0) }
        var lines = text.components(separatedBy: "\n")
        var count = 0
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                lines.removeLast()
            } else if line == inlineImageMarker
                        || (line.hasPrefix("data:image/") && line.contains(";base64,") && !line.contains(" ")) {
                lines.removeLast()
                count += 1
            } else {
                break
            }
        }
        guard count > 0 else { return (text, 0) }
        return (lines.joined(separator: "\n"), count)
    }

    /// The pictures stored inside persisted row `rowId`, in order, as data
    /// URLs (nil for one that is not a data URL). `rows` comes from a read
    /// that keeps pictures inline.
    static func inlineImageDataURLs(inRows rows: [Any], rowId: Int) -> [String?] {
        for raw in rows {
            guard let envelope = AnyCodable.from(raw).objectValue else { continue }
            let nested = envelope["message"]?.objectValue ?? envelope["payload"]?.objectValue ?? [:]
            let obj = envelope.merging(nested) { _, nestedValue in nestedValue }
            guard durableRowId(in: obj) == rowId else { continue }
            var urls: [String?] = []
            for part in obj["content"]?.arrayValue ?? [] {
                guard let object = part.objectValue, isInlineImagePart(object) else { continue }
                urls.append(inlineImageDataURL(in: object))
            }
            return urls
        }
        return []
    }

    private static func inlineImageDataURL(in part: [String: AnyCodable]) -> String? {
        let url = part["image_url"]?.objectValue?["url"]?.stringValue
            ?? part["image_url"]?.stringValue
            ?? part["url"]?.stringValue
        if let url {
            return url.lowercased().hasPrefix("data:image/") ? url : nil
        }
        // Anthropic `source` block, or an MCP image (`data` + `mimeType`).
        let source = part["source"]?.objectValue
        let media = source?["media_type"]?.stringValue ?? part["mimeType"]?.stringValue ?? part["media_type"]?.stringValue
        let data = source?["data"]?.stringValue ?? part["data"]?.stringValue
        guard let media, media.lowercased().hasPrefix("image/"), let data, !data.isEmpty else { return nil }
        return "data:\(media);base64,\(data)"
    }

    /// Desktop persists uploaded images as `@image:/gateway/path/file.ext`
    /// tokens in the user prompt, and the gateway notes a picture that came
    /// in through a chat platform as `[Image attached at: /path]`. Both
    /// become Conduit's regular attachments so resumed cross-client sessions
    /// keep their previews.
    ///
    /// A persisted row (`rowId`) also ends with one `[image]` stand-in per
    /// picture Hermes stored inside it (#652). Each pairs, in order, with
    /// the picture the prompt names a file for, as its fallback when that
    /// file is gone, or becomes an attachment of its own. The prompt is
    /// retained, without the stand-ins, for replay/branch operations.
    private static func splitUserImageReferences(
        _ source: String,
        messageId: String,
        rowId: Int? = nil,
        imageScope: TranscriptImageScope? = nil
    ) -> (content: String, rawContent: String?, attachments: [Attachment]?) {
        let markers = rowId == nil ? (text: source, count: 0) : trailingInlineImageMarkers(source)
        let body = markers.text
        let fullRange = NSRange(body.startIndex..<body.endIndex, in: body)

        var references: [(range: NSRange, path: String, description: String?)] = []
        var foundHint = false
        for expression in visionEnrichmentPatterns {
            for match in expression.matches(in: body, range: fullRange) {
                guard let pathRange = Range(match.range(at: match.numberOfRanges - 1), in: body) else { continue }
                let path = String(body[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                var description: String?
                if match.numberOfRanges > 2, let range = Range(match.range(at: 1), in: body) {
                    let text = String(body[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    description = text.isEmpty ? nil : text
                }
                references.append((match.range, path, description))
            }
        }
        for (expression, isHint) in [(imageReferencePattern, false), (imageHintPattern, true)] {
            guard let expression else { continue }
            for match in expression.matches(in: body, range: fullRange) {
                for group in 1..<match.numberOfRanges {
                    let range = match.range(at: group)
                    guard range.location != NSNotFound,
                          let swiftRange = Range(range, in: body) else { continue }
                    let path = String(body[swiftRange])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty {
                        references.append((match.range, path, nil))
                        foundHint = foundHint || isHint
                    }
                    break
                }
            }
        }
        guard !references.isEmpty || markers.count > 0 else { return (source, nil, nil) }
        references.sort { $0.range.location < $1.range.location }

        var visibleContent = body
        for reference in references.reversed() {
            guard let range = Range(reference.range, in: visibleContent) else { continue }
            visibleContent.removeSubrange(range)
        }
        visibleContent = visibleContent
            .replacingOccurrences(
                of: #"[ \t]+\r?\n"#,
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?:\r?\n){3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if foundHint, visibleContent == defaultImageCaption {
            visibleContent = ""
        }

        // One picture named twice (its description and an `@image:` token)
        // is one attachment, carrying the description.
        var pictures: [(path: String, description: String?)] = []
        for reference in references {
            if let index = pictures.firstIndex(where: { $0.path == reference.path }) {
                pictures[index].description = pictures[index].description ?? reference.description
            } else {
                pictures.append((reference.path, reference.description))
            }
        }
        let paths = pictures.map(\.path)
        let attachments = (0..<max(paths.count, markers.count)).map { index -> Attachment in
            let path = index < paths.count ? paths[index] : nil
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            var inlineImage: InlineImageRef?
            if index < markers.count, let rowId, let imageScope {
                inlineImage = InlineImageRef(
                    sessionId: imageScope.sessionId,
                    profile: imageScope.profile,
                    rowId: rowId,
                    index: index
                )
            }
            return Attachment(
                id: "\(messageId)-gateway-image-\(index)",
                name: name.isEmpty ? AppLocalization.string("Attached image") : name,
                uri: path ?? "",
                mimeType: path.flatMap { imageMimeType(for: $0) },
                kind: .image,
                inlineImage: inlineImage,
                imageDescription: index < pictures.count ? pictures[index].description : nil
            )
        }
        return (visibleContent, body, attachments)
    }

    private static func imageMimeType(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        default: return nil
        }
    }

    /// `allowUnprefixedSummary` is for the `review.summary` STREAM event only:
    /// like Hermes Desktop, any non-empty summary there is a memory write
    /// worth a row. Persisted system rows keep requiring the
    /// "💾 Self-improvement review:" prose, or every `[System: …]` notice
    /// would render as a review card.
    static func reviewActivity(
        from payload: [String: AnyCodable],
        eventSessionId: String?,
        allowUnprefixedSummary: Bool = false
    ) -> ReviewActivity? {
        let text = extractContent(payload["text"] ?? payload["content"] ?? .null)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let activity = reviewActivity(fromText: text)
            ?? (allowUnprefixedSummary ? plainReviewActivity(fromText: text) : nil) else {
            return nil
        }

        var details = activity.details ?? []
        for key in ["details", "transcript", "messages", "output"] {
            guard let value = payload[key], value != .null else { continue }
            if key == "details", let values = value.arrayValue {
                details += values.map(extractContent).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            } else {
                let valueText = extractContent(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !valueText.isEmpty { details.append(valueText) }
            }
        }
        let fullSessionId = ["review_session_id", "reviewSessionId", "child_session_id", "childSessionId", "maintenance_session_id"]
            .compactMap { payload[$0]?.stringValue }
            .first { !$0.isEmpty && $0 != eventSessionId }
        let uniqueDetails = details.reduce(into: [String]()) { result, detail in
            if !result.contains(detail) { result.append(detail) }
        }
        return ReviewActivity(
            summary: activity.summary,
            details: uniqueDetails.isEmpty ? nil : uniqueDetails,
            fullSessionId: fullSessionId
        )
    }

    private static func plainReviewActivity(fromText text: String) -> ReviewActivity? {
        // Desktop strips the leading glyph (the row draws its own).
        let summary = String(text.drop { !$0.isLetter && !$0.isNumber })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        return ReviewActivity(summary: summary, details: nil, fullSessionId: nil)
    }

    static func reviewActivity(fromText text: String) -> ReviewActivity? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "💾 Self-improvement review:"
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let parts = body.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let details = parts.filter { part in ["➕", "✏️", "➖"].contains { part.contains($0) } }
        guard !details.isEmpty else { return ReviewActivity(summary: body, details: nil, fullSessionId: nil) }
        let labels = Set(details.compactMap { detail -> String? in
            let lower = detail.lowercased()
            if lower.hasPrefix("user profile") { return AppLocalization.string("User profile") }
            if lower.hasPrefix("memory") { return AppLocalization.string("Memory") }
            if lower.hasPrefix("skill") { return AppLocalization.string("Skill") }
            return nil
        })
        let summary: String
        if labels.count == 1, let label = labels.first { summary = AppLocalization.string("\(label) updated") }
        else if labels.count > 1 { summary = AppLocalization.string("Memory and skills updated") }
        else { summary = AppLocalization.string("Self-improvement updates saved") }
        return ReviewActivity(summary: summary, details: details, fullSessionId: nil)
    }

    private static func extractContent(_ value: AnyCodable) -> String {
        switch value {
        case .null: return ""
        case .string(let s): return s
        case .array(let arr): return arr.map { extractContent($0) }.joined()
        case .object(let obj):
            if let text = obj["text"] { return extractContent(text) }
            if let content = obj["content"] { return extractContent(content) }
            // A picture stored inside the message: the same stand-in Hermes
            // writes for it with `inline_images=false`, never its base64 as
            // JSON text.
            if isInlineImagePart(obj) { return "\n" + inlineImageMarker }
            if let data = try? JSONSerialization.data(withJSONObject: obj.mapValues { $0.anyValue }, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return ""
        default: return ""
        }
    }

    private static func extractToolOutput(_ obj: [String: AnyCodable]) -> String {
        let keys = ["result", "output", "tool_result", "response", "data", "stdout", "content", "text"]
        var parts: [String] = []
        for key in keys {
            if let val = obj[key], val != .null {
                let text = extractContent(val)
                if !text.isEmpty { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func extractToolContext(_ obj: [String: AnyCodable]) -> String? {
        guard let context = obj["context"] else { return nil }
        let value = extractContent(context).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func extractToolCalls(_ obj: [String: AnyCodable]) -> [ToolActivity] {
        let calls = obj["tool_calls"]?.arrayValue
            ?? obj["tools"]?.arrayValue
            ?? []
        return calls.map { call in
            let cobj = call.objectValue ?? [:]
            let fn = cobj["function"]?.objectValue ?? cobj
            let input = cobj["input"]?.objectValue ?? [:]
            let output = extractToolOutput(cobj)
            let name = firstNonEmptyString([
                cobj["name"], cobj["tool_name"], fn["name"], input["name"]
            ]) ?? AppLocalization.string("Tool")
            let arguments: String? = {
                let raw = fn["arguments"] ?? cobj["input"] ?? cobj["arguments"] ?? cobj["args"] ?? cobj["command"] ?? cobj["code"] ?? .null
                let s = raw.descriptiveStringValue ?? extractContent(raw)
                return s.isEmpty ? nil : s
            }()
            // A deferred tool's call is saved as Tool Search's `tool_call`
            // wrapper: show the tool it ran, as the live events do.
            let bridged = ToolSearchBridge.isWrapper(name) ? ToolSearchBridge.underlyingCall(arguments) : nil
            return ToolActivity(
                id: firstNonEmptyString([cobj["id"], cobj["tool_call_id"], cobj["call_id"]]),
                name: bridged?.name ?? name,
                input: bridged == nil ? arguments : bridged?.arguments,
                output: output.isEmpty ? nil : output,
                status: .complete
            )
        }
    }

    private static func extractToolName(_ obj: [String: AnyCodable]) -> String? {
        let tool = obj["tool"]?.objectValue ?? [:]
        let function = obj["function"]?.objectValue ?? [:]
        let input = obj["input"]?.objectValue ?? [:]
        return firstNonEmptyString([
            obj["tool_name"], obj["name"], function["name"], tool["name"], input["name"]
        ])
    }

    private static func firstNonEmptyString(_ values: [AnyCodable?]) -> String? {
        for value in values {
            guard let text = value?.stringValue ?? value?.descriptiveStringValue else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func extractAuthor(_ obj: [String: AnyCodable]) -> String? {
        let meta = obj["metadata"]?.objectValue ?? [:]
        let candidates = [obj["profile"], obj["profile_name"], obj["author"], obj["sender"], obj["agent_name"], obj["agent"], meta["profile"], meta["profile_name"], meta["author"]]
        for candidate in candidates {
            if let s = candidate?.stringValue, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        return nil
    }

    private static func extractTimestamp(_ obj: [String: AnyCodable]) -> String {
        let meta = obj["metadata"]?.objectValue ?? obj["meta"]?.objectValue ?? [:]
        let candidates = [
            obj["timestamp"], obj["timestamp_ms"], obj["timestampMs"], obj["created_at"], obj["createdAt"], obj["created"], obj["created_ms"], obj["createdMs"], obj["time"], obj["ts"], obj["date"], obj["datetime"],
            obj["updated_at"], obj["updatedAt"], obj["sent_at"], obj["sentAt"], obj["last_active"], obj["lastActive"],
            meta["timestamp"], meta["timestamp_ms"], meta["timestampMs"], meta["created_at"], meta["createdAt"], meta["created"], meta["created_ms"], meta["createdMs"], meta["time"], meta["ts"], meta["date"], meta["datetime"],
            meta["updated_at"], meta["updatedAt"], meta["sent_at"], meta["sentAt"], meta["last_active"], meta["lastActive"]
        ]
        for candidate in candidates {
            if candidate == nil || candidate == .null { continue }
            if let s = candidate?.stringValue { return s }
            if let n = candidate?.doubleValue { return String(n) }
        }
        return ""
    }

    /// A tool result's own timing, when Hermes sends one: seconds in
    /// `duration` or `elapsed`, milliseconds in `duration_ms`.
    private static func toolDuration(in obj: [String: AnyCodable]) -> TimeInterval? {
        let meta = obj["metadata"]?.objectValue ?? obj["meta"]?.objectValue ?? [:]
        for source in [obj, meta] {
            if let ms = source["duration_ms"]?.doubleValue, ms >= 0 { return ms / 1_000 }
            if let seconds = (source["duration"] ?? source["elapsed"])?.doubleValue, seconds >= 0 { return seconds }
        }
        return nil
    }

    private static func isDuplicateReasoning(_ reasoning: String, _ content: String) -> Bool {
        let normR = reasoning.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).joined()
        let normC = content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).joined()
        guard !normR.isEmpty, !normC.isEmpty else { return false }
        if normR == normC { return true }
        let shortest = min(normR.count, normC.count)
        return shortest >= 80 && (normR.hasPrefix(normC) || normC.hasPrefix(normR))
    }
}
