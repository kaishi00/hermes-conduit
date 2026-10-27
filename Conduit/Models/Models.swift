//
//  Models.swift
//  Conduit
//
//  Data models matching the Hermes gateway JSON-RPC protocol.
//  Ported from TypeScript types but using Swift idioms (Codable, enums, structs).
//

import Foundation
import SwiftUI

// MARK: - Core Types

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case reasoning
    case system
    case partial
    case tool
    case clarify
    case approval
    /// A private-input prompt from a Hermes server→client request: sudo
    /// password, skill/setup secret, password-manager unlock, a website's
    /// login or its one-time code.
    case inputPrompt
}

enum SessionSource: String, Codable, CaseIterable {
    case chat
    /// Saved live voice calls and chats classic Voice started. Never a
    /// Hermes source: Conduit files tagged rows here (see VoiceSessionTag).
    case voice
    /// Background jobs a voice conversation started (tagged, as above).
    case voiceJob = "voice_job"
    case discord
    case telegram
    case api
    case webhook
    case cron
    case other

    var label: String {
        switch self {
        case .chat: return AppLocalization.string("Chat")
        case .voice: return AppLocalization.string("Voice")
        case .voiceJob: return AppLocalization.string("Voice Jobs")
        case .discord: return "Discord"
        case .telegram: return "Telegram"
        case .api: return "API"
        case .webhook: return AppLocalization.string("Webhook")
        case .cron: return AppLocalization.string("Cron")
        case .other: return AppLocalization.string("Other")
        }
    }

    var iconName: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .voice: return "waveform"
        case .voiceJob: return "bolt.horizontal.circle.fill"
        case .discord: return "person.2.fill"
        case .telegram: return "paperplane.fill"
        case .api: return "globe"
        case .webhook: return "link"
        case .cron: return "clock.fill"
        case .other: return "questionmark.folder"
        }
    }

    var color: Color {
        switch self {
        case .chat: return .blue
        case .voice: return .teal
        case .voiceJob: return .indigo
        case .discord: return .purple
        case .telegram: return .cyan
        case .api: return .green
        case .webhook: return .orange
        case .cron: return .pink
        case .other: return .gray
        }
    }
}

extension SessionSource {
    /// Hermes' source for a Kanban worker's transcript. Hermes refuses to
    /// reopen one as a chat (`session.resume` 4132): the board runs it, and
    /// the task's Worker Log shows it.
    static let hermesKanbanSource = "kanban"

    /// `exclude_sources` for the chat lists: cron runs have a list of their
    /// own, and Kanban workers stay on the board, as Hermes Desktop's sidebar
    /// leaves them out.
    static let chatListExcludedSources = "cron,\(hermesKanbanSource)"
}

struct Attachment: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var uri: String
    var mimeType: String?
    var kind: Kind
    /// A picture Hermes also stored inside the message itself. Chats load
    /// without those copies (#652); this says where to fetch one when its
    /// file is gone from the server.
    var inlineImage: InlineImageRef? = nil
    /// What Hermes' vision saw in a picture, from history saved before
    /// Hermes kept the picture's reference instead (#887). Shown on a long
    /// press and read by VoiceOver.
    var imageDescription: String? = nil

    enum Kind: String, Codable {
        case image
        case video
        case document
    }
}

/// One picture stored inside a persisted Hermes message: the row's durable
/// id, the picture's place among the row's pictures, and the session and
/// profile whose database holds the row.
struct InlineImageRef: Codable, Equatable, Hashable {
    let sessionId: String
    let profile: String
    let rowId: Int
    let index: Int
}

/// The session and profile a page of persisted rows was read from, so the
/// pictures inside those rows can be fetched again later.
struct TranscriptImageScope: Equatable {
    let sessionId: String
    let profile: String
}

struct ToolActivity: Codable, Equatable {
    var id: String?
    var name: String
    var input: String?
    var output: String?
    var status: Status
    /// How long the call took, in seconds, when Conduit saw it start and
    /// finish or Hermes' history times both ends. Nil when unknown.
    var duration: TimeInterval? = nil

    enum Status: String, Codable {
        case running
        case complete
    }
}

struct ReviewActivity: Codable, Equatable {
    var summary: String
    var details: [String]?
    /// Some Hermes versions include the private maintenance transcript as a
    /// child session. When supplied, Conduit can open it directly.
    var fullSessionId: String?
}

struct ReviewSummaryRecord: Codable, Identifiable, Equatable {
    var id: String
    var profile: String
    var sessionId: String
    var timestamp: String
    var activity: ReviewActivity
}

struct ClarifyChoice: Codable, Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { value }
}

/// One question inside a clarification request. Current Hermes gateways send
/// batches (`clarify.request { questions: [...] }`) where each entry carries a
/// gateway-minted `qid`; the legacy scalar payload normalizes into a batch of
/// exactly one of these. `id` is the wire identity — it is what
/// `clarify.respond { question_id }` keys per-question answers by.
struct ClarifyQuestion: Codable, Equatable, Identifiable {
    var id: String
    var question: String
    var choices: [ClarifyChoice]
    var multiSelect: Bool
    var status: Status
    /// The accepted answer exactly as it travels the wire. Multi-select
    /// answers are a JSON array string of chosen values; `ClarifyQuestion`
    /// exposes them through `resolvedAnswer` for display.
    var answer: String?
    var error: String?
    /// True when `id` was minted locally for a legacy scalar payload rather
    /// than supplied by the gateway. Synthetic ids must never ride the wire
    /// as `question_id` — the server has no such qid, and a real gateway
    /// batch can also mint q0-style ids, so the flag (not the id value) is
    /// what routes legacy answers through the request-level respond shape.
    var isSyntheticID: Bool

    enum Status: String, Codable {
        case pending
        case submitting
        case answered
        case error
        case expired
    }

    enum CodingKeys: String, CodingKey {
        case id, question, choices, status, answer, error, isSyntheticID
        case multiSelect = "multi_select"
    }

    /// True when the question offers no choices and expects typed text.
    var isFreeText: Bool { choices.isEmpty }

    /// Whether this question can accept an answer or retry.
    var isAnswerable: Bool { status == .pending || status == .error }

    /// Left blank: a form's field the user didn't fill in, which Hermes
    /// reads as skipped. Its answer is empty, where one answered on another
    /// device has none.
    var isSkipped: Bool { status == .answered && answer?.isEmpty == true }

    init(
        id: String,
        question: String,
        choices: [ClarifyChoice],
        multiSelect: Bool = false,
        status: Status = .pending,
        answer: String? = nil,
        error: String? = nil,
        isSyntheticID: Bool = false
    ) {
        self.id = id
        self.question = question
        self.choices = choices
        self.multiSelect = multiSelect
        self.status = status
        self.answer = answer
        self.error = error
        self.isSyntheticID = isSyntheticID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        question = try container.decode(String.self, forKey: .question)
        choices = try container.decode([ClarifyChoice].self, forKey: .choices)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .pending
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        isSyntheticID = try container.decodeIfPresent(Bool.self, forKey: .isSyntheticID) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(question, forKey: .question)
        try container.encode(choices, forKey: .choices)
        if multiSelect { try container.encode(true, forKey: .multiSelect) }
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(answer, forKey: .answer)
        try container.encodeIfPresent(error, forKey: .error)
        if isSyntheticID { try container.encode(true, forKey: .isSyntheticID) }
    }

    /// The accepted answer in display form. A multi-select wire answer is a
    /// JSON array of chosen values, rendered back in gateway choice order —
    /// restored answers from any surface then always read consistently.
    var resolvedAnswer: String? {
        guard let answer, !answer.isEmpty else { return nil }
        guard multiSelect,
              let data = answer.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return answer
        }
        let selected = Set(values)
        var labels = choices.filter { selected.contains($0.value) }.map(\.label)
        for value in values where !choices.contains(where: { $0.value == value }) {
            // Values that matched no offered choice keep their wire order.
            labels.append(value)
        }
        return labels.joined(separator: ", ")
    }

    /// Serializes a multi-select submission into the wire form Hermes' batch
    /// answer parser accepts (a JSON array string of the chosen values).
    static func multiSelectAnswer(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A form field's answer from what the user filled in: the picked
    /// choice, or the typed text; a multi-select's picks in choice order,
    /// with any typed text after them. Empty when the field was left blank.
    func formAnswer(picked: Set<String>, typed: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = choices.map(\.value).filter { picked.contains($0) }
        guard multiSelect else { return values.first ?? typed }
        let all = typed.isEmpty ? values : values + [typed]
        return all.isEmpty ? "" : Self.multiSelectAnswer(all)
    }
}

/// A clarification request: the gateway's `clarify.request`, normalized into
/// one batch-capable model for both the current `questions[]` protocol and
/// the legacy scalar shape (which becomes a one-question batch). Answering is
/// per question (`clarify.respond { question_id }`); `status` summarizes the
/// request for headers, persistence pruning, and supersede logic.
struct ClarifyActivity: Codable, Equatable {
    var requestId: String
    var questions: [ClarifyQuestion]
    /// Set when the gateway expired the request (`clarify.expire` or an
    /// expired `clarify.respond` outcome). A late answer can never make an
    /// expired request appear successfully answered.
    var isExpired: Bool
    var error: String?

    enum Status: String, Codable {
        case pending
        case submitting
        case answered
        case error
        case expired
    }

    init(
        requestId: String,
        questions: [ClarifyQuestion],
        isExpired: Bool = false,
        error: String? = nil
    ) {
        self.requestId = requestId
        self.questions = questions
        self.isExpired = isExpired
        self.error = error
    }

    /// Convenience for single-question producers (the push-relay payload and
    /// tests) that normalizes into a one-question batch. The locally minted
    /// "q0" identity is marked synthetic: it must never ride the wire as
    /// `question_id`, because the gateway has no such qid.
    init(
        requestId: String,
        question: String,
        choices: [ClarifyChoice],
        multiSelect: Bool = false,
        status: ClarifyQuestion.Status = .pending,
        answer: String? = nil,
        error: String? = nil
    ) {
        self.init(
            requestId: requestId,
            questions: [
                ClarifyQuestion(
                    id: "q0",
                    question: question,
                    choices: choices,
                    multiSelect: multiSelect,
                    status: status,
                    answer: answer,
                    error: error,
                    isSyntheticID: true
                )
            ],
            error: nil
        )
    }

    /// Request-level status, derived so a partially answered batch stays
    /// presentable: one locked sub-question never marks the card ANSWERED,
    /// and a question that still needs input outranks one that errored. A
    /// per-question expired state derives expired even if the flag was lost
    /// (e.g. a legacy cache migration) — an expired question must never
    /// re-open as answerable.
    var status: Status {
        if isExpired || questions.contains(where: { $0.status == .expired }) { return .expired }
        let statuses = questions.map(\.status)
        if statuses.contains(.submitting) { return .submitting }
        if !statuses.isEmpty && statuses.allSatisfy({ $0 == .answered }) { return .answered }
        if statuses.contains(.pending) { return .pending }
        if statuses.contains(.error) { return .error }
        return .pending
    }

    /// Whether any question is currently answerable. Request-level expiry
    /// suppresses every sibling, while an expired sibling does not suppress
    /// active questions in the same batch.
    var needsAnswer: Bool {
        !isExpired && questions.contains(where: \.isAnswerable)
    }

    /// Whether the card is unresolved for persistence/pruning. Submitting
    /// questions are not answerable yet, but must survive until their result
    /// is known (or resume resets them to pending).
    var hasPendingDecision: Bool {
        !isExpired && questions.contains { $0.isAnswerable || $0.status == .submitting }
    }

    /// The card's user-facing state. A partially active batch can have an
    /// expired sibling while another question still accepts an answer.
    var presentationStatus: Status {
        guard status == .expired, hasPendingDecision else { return status }
        if questions.contains(where: { $0.status == .submitting }) { return .submitting }
        if questions.contains(where: { $0.status == .pending }) { return .pending }
        if questions.contains(where: { $0.status == .error }) { return .error }
        return .expired
    }

    /// Several questions, at least one typed: shown as a form whose fields
    /// are sent together, any of them left blank. A question on its own,
    /// or a batch of choices only, keeps the card that answers each one.
    var isForm: Bool {
        questions.count > 1 && questions.contains(where: \.isFreeText)
    }

    /// Visible question text for the transcript row: the joined question
    /// texts, identical to the legacy scalar text for one-question batches.
    var displayQuestion: String {
        questions.map(\.question).joined(separator: "\n")
    }

    /// Correlation text for superseding a pending push-delivered card. The
    /// notifier reduces a batch to its first question, so that is what a live
    /// gateway event must match against.
    var correlationQuestion: String {
        questions.first?.question ?? ""
    }

    // MARK: Codable (with legacy-shape migration)

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case legacyRequestId = "requestId"
        case questions
        case isExpired
        case error
        // Legacy single-question shape.
        case question, choices, status, answer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let currentID = try container.decodeIfPresent(String.self, forKey: .requestId) {
            requestId = currentID
        } else {
            requestId = try container.decode(String.self, forKey: .legacyRequestId)
        }
        isExpired = try container.decodeIfPresent(Bool.self, forKey: .isExpired) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
        if let questions = try? container.decode([ClarifyQuestion].self, forKey: .questions), !questions.isEmpty {
            self.questions = questions
            return
        }
        // Migration: presentation caches written by older builds stored the
        // legacy single-question fields. Decode what is still usable instead
        // of failing the whole cache load; a degenerate empty-text record
        // yields an empty question list rather than a phantom question, and
        // is expired because a card with nothing to answer would otherwise
        // derive pending and render an inert "needs your input" prompt.
        let question = (try? container.decode(String.self, forKey: .question)) ?? ""
        let choices = (try? container.decode([ClarifyChoice].self, forKey: .choices)) ?? []
        let status = (try? container.decode(ClarifyQuestion.Status.self, forKey: .status)) ?? .pending
        let answer = try? container.decode(String.self, forKey: .answer)
        if question.isEmpty { isExpired = true }
        questions = question.isEmpty
            ? []
            : [
                ClarifyQuestion(
                    id: "q0",
                    question: question,
                    choices: choices,
                    multiSelect: false,
                    status: status,
                    answer: answer,
                    isSyntheticID: true
                )
            ]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(questions, forKey: .questions)
        try container.encode(isExpired, forKey: .isExpired)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// A command decision requested by Hermes while a turn is paused. Current
/// gateways identify each queued approval with `request_id`; older gateways
/// omit it and retain session-scoped FIFO behavior.
struct ApprovalActivity: Codable, Equatable {
    var sessionId: String
    var requestId: String? = nil
    var command: String
    var description: String
    var choices: [String]?
    var allowPermanent: Bool
    var smartDenied: Bool
    var status: Status
    var choice: String?
    var error: String?

    enum Status: String, Codable {
        case pending
        case submitting
        case approved
        case rejected
        case expired
        case error
    }

    /// Whether this card still asks what `shown` asked: the same request,
    /// command, explanation and offered choices. A legacy (request-less)
    /// card is updated in place when Hermes announces the next command, so
    /// a tap must only answer the card the person actually read. Status,
    /// the chosen answer and the error are progress, not the question; the
    /// session id is not shown and moves to the durable id on its own.
    func asksSameAs(_ shown: ApprovalActivity) -> Bool {
        requestId == shown.requestId
            && command == shown.command
            && description == shown.description
            && choices == shown.choices
            && allowPermanent == shown.allowPermanent
            && smartDenied == shown.smartDenied
    }
}

/// One private-input prompt Hermes asks through a server→client request
/// (`tui_gateway/contracts/server_requests.py`): `sudo`, `secret`,
/// `vault.unlock_prompt`, `vault.save_login` (a website's login, answered
/// as JSON `{identifier, password}`) or `vault.code` (a website's one-time
/// code), each answered with `{value}` ('' = skip).
///
/// Deliberately NOT Codable: the card is live-only (a resume re-announces
/// it from `open_requests`), so it can never reach the presentation or
/// offline caches. The value the user types never enters this model — it
/// lives in the card's view state and goes straight onto the socket.
struct InputPromptActivity: Equatable {
    enum Kind: String, Equatable {
        case sudo
        case secret
        case vaultUnlock = "vault.unlock_prompt"
        case vaultSaveLogin = "vault.save_login"
        case vaultCode = "vault.code"
    }

    enum Status: Equatable {
        case pending
        case submitting
        case submitted
        case skipped
        case expired
        case error
    }

    /// The server request id (`srq-…`) the answer is addressed to.
    let requestId: String
    let sessionId: String
    let kind: Kind
    /// sudo: the (server-redacted) command that needs the password.
    var command: String = ""
    /// secret: the env var the value is stored under, and Hermes' prompt.
    var envVar: String = ""
    var prompt: String = ""
    /// vault.unlock_prompt: the password manager's name.
    var displayName: String = ""
    /// vault.save_login: the sign-in page's origin (`https://host`), which
    /// the login is saved for.
    var origin: String = ""
    /// vault.save_login and vault.code: the site, by host.
    var site: String = ""
    var status: Status = .pending
    var error: String?
    /// The profile whose chat showed the card (AppState sets it), so an
    /// answer typed after a profile switch never goes out on the new
    /// profile's connection. Empty until shown.
    var profile: String = ""

    /// Parses a server request (live frame or `open_requests` entry).
    /// Returns nil for any other method, a request without a session, or
    /// a login request without the origin it is saved for.
    static func from(requestId: String, method: String, params: [String: AnyCodable]) -> InputPromptActivity? {
        guard let kind = Kind(rawValue: method), !requestId.isEmpty else { return nil }
        let sessionId = params["session_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionId.isEmpty else { return nil }
        func text(_ key: String) -> String {
            params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var activity = InputPromptActivity(requestId: requestId, sessionId: sessionId, kind: kind)
        switch kind {
        case .sudo:
            activity.command = text("command")
        case .secret:
            activity.envVar = text("env_var")
            activity.prompt = text("prompt")
        case .vaultUnlock:
            activity.displayName = text("display_name").isEmpty ? text("backend") : text("display_name")
        case .vaultSaveLogin:
            // A login is bound to the origin it is saved for; without one
            // the card could not say which site gets it. The title names
            // the origin's own host, so it can never name another site.
            activity.origin = text("origin")
            guard !activity.origin.isEmpty else { return nil }
            activity.site = URL(string: activity.origin)?.host ?? activity.origin
        case .vaultCode:
            activity.site = text("site")
        }
        return activity
    }

    /// Every input-prompt entry of a resume's `open_requests`, oldest first
    /// as the gateway lists them.
    static func pending(inOpenRequests openRequests: AnyCodable?) -> [InputPromptActivity] {
        (openRequests?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let id = object["id"]?.stringValue,
                  let method = object["method"]?.stringValue else { return nil }
            return from(requestId: id, method: method, params: object["params"]?.objectValue ?? [:])
        }
    }

    /// Transcript text for the card row. Never contains the answer.
    var title: String {
        switch kind {
        case .sudo:
            return AppLocalization.string("Hermes needs your sudo password")
        case .secret:
            return prompt.isEmpty ? AppLocalization.string("Hermes needs a secret value") : prompt
        case .vaultUnlock:
            return displayName.isEmpty
                ? AppLocalization.string("Unlock your password manager")
                : AppLocalization.string("Unlock \(displayName)")
        case .vaultSaveLogin:
            return AppLocalization.string("Save your \(site) login?")
        case .vaultCode:
            return site.isEmpty
                ? AppLocalization.string("Verification code")
                : AppLocalization.string("Verification code for \(site)")
        }
    }

    /// The `vault.save_login` answer: the JSON Hermes hands to its vault
    /// store. Nil when either part is missing, which is not an answer
    /// (Hermes reads that as declined). A password of spaces alone is
    /// missing too, as on the other cards; one containing spaces goes as
    /// typed.
    static func loginAnswer(identifier: String, password: String) -> String? {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? JSONSerialization.data(
                  withJSONObject: ["identifier": identifier, "password": password],
                  options: [.sortedKeys]
              ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The `vault.code` answer: the code as typed, without the spaces and
    /// dashes a site groups it with ("123 456"), as Hermes types it.
    static func codeAnswer(_ typed: String) -> String {
        typed.filter { !$0.isWhitespace && $0 != "-" }
    }

    var isAnswerable: Bool { status == .pending || status == .error }
}

// MARK: - ChatMessage

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: MessageRole
    var content: String
    var rawContent: String?
    var timestamp: String
    var author: String?
    var reasoning: String?
    var tool: ToolActivity?
    var review: ReviewActivity?
    var clarify: ClarifyActivity?
    var approval: ApprovalActivity?
    var inputPrompt: InputPromptActivity?
    var attachments: [Attachment]?
    var code: String?
    /// Canonical Hermes `display_kind` when the persisted row arrived with
    /// explicit synthetic-timeline projection (`model_switch`, `auto_continue`,
    /// …). Nil for ordinary rows. Normalization already reduced the row to its
    /// final display role/content; this only lets the timeline UI style the
    /// notice without re-deriving it from text.
    var displayKind: String?
    /// Hermes' durable `messages.id` for this row (`row_id` on a resume row,
    /// the numeric `id` on a REST transcript row). It is how a reaction
    /// addresses the message. Nil for a live row that hasn't been reloaded
    /// yet and for rows Conduit split off (reasoning, tool calls).
    var rowId: Int?
    /// Tapback reactions persisted on the row, at most one per author.
    var reactions: [MessageReaction]
    /// How long a thinking step took, in seconds, when Conduit watched it
    /// stream (tool calls keep theirs on `tool`). Nil when unknown.
    var stepDuration: TimeInterval? = nil

    // Non-codable because it contains closures in some uses; serialization
    // is handled by the gateway, not by us. We construct these from RPC results.

    init(
        id: String,
        role: MessageRole,
        content: String,
        rawContent: String? = nil,
        timestamp: String,
        author: String? = nil,
        reasoning: String? = nil,
        tool: ToolActivity? = nil,
        review: ReviewActivity? = nil,
        clarify: ClarifyActivity? = nil,
        approval: ApprovalActivity? = nil,
        inputPrompt: InputPromptActivity? = nil,
        attachments: [Attachment]? = nil,
        code: String? = nil,
        displayKind: String? = nil,
        rowId: Int? = nil,
        reactions: [MessageReaction] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.rawContent = rawContent
        self.timestamp = timestamp
        self.author = author
        self.reasoning = reasoning
        self.tool = tool
        self.review = review
        self.clarify = clarify
        self.approval = approval
        self.inputPrompt = inputPrompt
        self.attachments = attachments
        self.code = code
        self.displayKind = displayKind
        self.rowId = rowId
        self.reactions = reactions
    }

    /// Hermes' `display_kind` for a mid-turn steer row, also used for the
    /// local row Conduit shows the moment a steer is accepted (issue #337).
    static let steerDisplayKind = "steer"

    /// A user message delivered into a running turn with Steer.
    var isSteer: Bool {
        role == .user && displayKind == Self.steerDisplayKind
    }
}

// MARK: - Reactions

/// One emoji reaction on a message (Hermes `MessageReaction`, persisted in
/// the row's `display_metadata.reactions`). Tapback rules: one reaction per
/// author, the same emoji again retracts it, a different one replaces it.
struct MessageReaction: Codable, Equatable, Hashable {
    static let userAuthor = "user"
    static let agentAuthor = "agent"

    /// The six reactions the picker offers, in order.
    static let tapbacks = ["👍", "👎", "❤️", "😂", "😮", "😢"]

    let emoji: String
    let author: String
    var at: Double?

    var isFromUser: Bool { author == Self.userAuthor }

    /// The reaction list after `author` picks `emoji` (nil clears), applying
    /// the same Tapback rules as Hermes' `set_message_reaction`, so the
    /// optimistic paint matches what the server will return.
    static func applying(
        _ emoji: String?,
        author: String,
        to reactions: [MessageReaction],
        at time: Double = Date().timeIntervalSince1970
    ) -> [MessageReaction] {
        let previous = reactions.first { $0.author == author }
        var result = reactions.filter { $0.author != author }
        if let emoji, !emoji.isEmpty, previous?.emoji != emoji {
            result.append(MessageReaction(emoji: emoji, author: author, at: time))
        }
        return result
    }
}

struct WorkspaceEntry: Identifiable, Equatable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    /// A file's size; nil for a folder, and where the listing has none
    /// (Hermes' own folder listing).
    var size: Int64? = nil
    var modified: Date? = nil

    var id: String { path }
}

struct WorkspaceFilePreview: Equatable {
    var binary: Bool
    var byteSize: Int
    var language: String
    var mimeType: String
    var text: String
    var truncated: Bool
}

struct GatewayConnector: Identifiable, Equatable {
    var id: String
    var name: String
    var state: String
    var error: String?
    var configured: Bool?
    var enabled: Bool?
}

struct GatewayDiagnostics: Equatable {
    var gatewayRunning: Bool
    var gatewayState: String?
    var version: String?
    var pid: Int?
    var connectors: [GatewayConnector]
    var logs: [String]
    var error: String?
}

struct DelegateAgentActivity: Identifiable, Equatable {
    enum Status: String, Equatable {
        case queued, running, completed, failed, interrupted

        var label: String {
            switch self {
            case .queued: return AppLocalization.string("Queued")
            case .running: return AppLocalization.string("Running")
            case .completed: return AppLocalization.string("Completed")
            case .failed: return AppLocalization.string("Failed")
            case .interrupted: return AppLocalization.string("Interrupted")
            }
        }
        var isActive: Bool { self == .queued || self == .running }
    }

    struct StreamLine: Identifiable, Equatable {
        enum Kind: String, Equatable { case progress, summary, thinking, tool }

        var id = UUID()
        var kind: Kind
        var text: String
        var isError: Bool
    }

    var id: String
    var goal: String
    var model: String?
    var status: Status
    var taskCount: Int
    var taskIndex: Int
    var currentTool: String?
    var summary: String?
    var stream: [StreamLine]
    /// True when `id` is Hermes' own `subagent_id`, so `subagent.list` can
    /// confirm whether the agent is still running (#492).
    var hasGatewayID = false
    /// The live session whose events reported this agent.
    var sessionId = ""
    var updatedAt = Date()

    /// Folds a later event for the same agent into the card: blank fields
    /// keep what earlier events said, and a finished agent stays finished
    /// when a late progress event (which carries no status) arrives.
    func merged(with update: DelegateAgentActivity) -> DelegateAgentActivity {
        var merged = update
        if merged.goal.isEmpty { merged.goal = goal }
        merged.model = update.model ?? model
        // The first end an agent reports is its end.
        if !status.isActive { merged.status = status }
        // A late spawn event doesn't send a running agent back to the queue.
        if status == .running && update.status == .queued { merged.status = .running }
        // A finished agent is no longer in any tool.
        merged.currentTool = merged.status.isActive ? update.currentTool ?? currentTool : nil
        merged.summary = update.summary ?? summary
        merged.hasGatewayID = hasGatewayID || update.hasGatewayID
        if merged.sessionId.isEmpty { merged.sessionId = sessionId }
        merged.stream = Array((stream + update.stream).suffix(20))
        return merged
    }

    /// Agents a gateway roster no longer lists have ended; their
    /// `subagent.complete` was missed (app suspended, socket reconnect).
    /// Only running cards from `sessionId` with a gateway id and no event
    /// since `cutoff` are touched. Hermes lists an agent once it starts,
    /// so queued cards are left alone.
    static func reconciled(
        _ agents: [DelegateAgentActivity],
        sessionId: String,
        liveIDs: Set<String>,
        changedBefore cutoff: Date
    ) -> [DelegateAgentActivity] {
        agents.map { agent in
            guard agent.status == .running,
                  agent.hasGatewayID,
                  agent.sessionId == sessionId,
                  agent.updatedAt < cutoff,
                  !liveIDs.contains(agent.id) else { return agent }
            var ended = agent
            ended.status = .completed
            ended.currentTool = nil
            return ended
        }
    }
}

// MARK: - Session

struct SessionSummary: Identifiable, Equatable, Codable {
    let id: String
    /// The durable database identity used by `session.resume`. Hermes stream
    /// events and notifications may carry the live runtime identity instead.
    var storedSessionId: String? = nil
    var alternateIds: [String]
    var title: String
    var model: String
    var updatedLabel: String
    /// The row's activity instant in epoch seconds, when the listing carried a
    /// machine-readable one (`updatedLabel` is a FORMATTED string and cannot
    /// order anything). Restoration's "latest" fallback reads this instead of
    /// list position, which merges cached rows behind live ones and prepends a
    /// retained active-turn row.
    var lastActivityAt: TimeInterval? = nil
    var profile: String?
    var source: SessionSource
    var isActive: Bool
    var isArchived: Bool
    var messageCount: Int? = nil
    /// Hermes' shared read flag (`unread` on dashboard rows, #454): activity
    /// postdates the `last_read_at` watermark. Nil when the listing didn't
    /// carry it (the `session.list` RPC, older gateways).
    var isUnread: Bool? = nil
    /// Hermes' `last_read_at` watermark (epoch seconds). 0 means someone
    /// explicitly marked the chat unread; nil means never tracked.
    var readWatermark: Double? = nil
    /// Hermes' shared pin flag (`pinned` on dashboard rows, #555), which
    /// Desktop pins with too. Nil when the listing didn't carry it (the
    /// `session.list` RPC, hosts older than the flag).
    var isPinned: Bool? = nil
    var lineageRootId: String?
    /// Hermes' `auto_archived` stamp: the row was archived by a sweep, not
    /// by someone, and comes back by itself once it's used again. Nil when
    /// the listing didn't carry it.
    var isAutoArchived: Bool? = nil
    /// Hermes' `end_reason` for an ended row, when the listing carried one.
    var endReason: String? = nil
    /// The listing's one-line `preview` (the opening message), when the row
    /// carried one apart from its title. The V2 session list's second line.
    var preview: String? = nil
}

/// A server-owned workspace from Hermes' `projects.*` capability. Projects are
/// profile-scoped and define session membership by their folders; Conduit only
/// presents that authoritative grouping and never tries to infer it locally.
struct ProjectSummary: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    var primaryPath: String?
    var icon: String?
    var colorHex: String?
    var isHome: Bool
    /// A repo Hermes discovered on its own rather than a project someone
    /// created; it has no projects.db row, so it cannot be renamed or deleted.
    var isAuto: Bool = false
    var sessionCount: Int
    var previewSessions: [SessionSummary]
}

struct ProjectSessionLane: Identifiable, Equatable {
    let id: String
    var title: String
    var sessions: [SessionSummary]
    /// The folder the lane's sessions ran in (a worktree or the repo), when
    /// Hermes names one apart from the label.
    var path: String? = nil
}

struct ProjectSessionDetail: Identifiable, Equatable {
    let id: String
    var title: String
    var lanes: [ProjectSessionLane]
}

// MARK: - Cron

struct CronJob: Codable, Identifiable {
    var deliver: String?
    var enabled: Bool
    var id: String
    var lastError: String?
    var lastRunAt: String?
    var name: String?
    var nextRunAt: String?
    var noAgent: Bool?
    var prompt: String?
    var schedule: CronSchedule?
    var scheduleDisplay: String?
    var script: String?
    var state: String?

    enum CodingKeys: String, CodingKey {
        case deliver, enabled, id, name, prompt, script, state
        case lastError = "last_error"
        case lastRunAt = "last_run_at"
        case nextRunAt = "next_run_at"
        case noAgent = "no_agent"
        case schedule
        case scheduleDisplay = "schedule_display"
    }

    var displayName: String { name ?? id }

    /// The `state` Hermes gives a one-shot job once it has run.
    static let completedState = "completed"

    /// A finished one-shot job will not run again on its own, even if the
    /// record still reads enabled.
    var isFinished: Bool { state?.lowercased() == Self.completedState }

    /// Whether the job will run on its own: enabled and not finished.
    var isActive: Bool { enabled && !isFinished }

    /// The Cron row's badge: Finished, Active or Paused.
    var statusLabel: String {
        if isFinished { return AppLocalization.string("Finished") }
        return isActive ? AppLocalization.string("Active") : AppLocalization.string("Paused")
    }
}

/// A Cron job action; the raw value is the dashboard API path segment.
enum CronJobAction: String {
    case pause, resume, trigger
}

/// Hermes' parsed schedule: `cron` carries `expr`, `interval` its
/// `minutes`, `once` its `run_at`; `display` is Hermes' own wording (for a
/// cron job, the expression itself).
struct CronSchedule: Codable {
    var display: String?
    var expr: String?
    var kind: String?
    var minutes: Int?
    var runAt: String?

    enum CodingKeys: String, CodingKey {
        case display, expr, kind, minutes
        case runAt = "run_at"
    }

    init(display: String? = nil, expr: String? = nil, kind: String? = nil, minutes: Int? = nil, runAt: String? = nil) {
        self.display = display
        self.expr = expr
        self.kind = kind
        self.minutes = minutes
        self.runAt = runAt
    }

    /// Lenient: a field of an unexpected type is dropped rather than
    /// dropping the whole job from the list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        display = try? container.decodeIfPresent(String.self, forKey: .display)
        expr = try? container.decodeIfPresent(String.self, forKey: .expr)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        minutes = (try? container.decodeIfPresent(Int.self, forKey: .minutes))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .minutes)).flatMap { Int(exactly: $0.rounded()) }
        runAt = try? container.decodeIfPresent(String.self, forKey: .runAt)
    }
}

struct CronRun: Codable, Identifiable {
    var id: String
    var lastActive: Int?
    var model: String?
    var preview: String?
    var profile: String?
    var startedAt: Int?
    var title: String?

    enum CodingKeys: String, CodingKey {
        case id, model, preview, profile
        case lastActive = "last_active"
        case startedAt = "started_at"
        case title
    }
}

// MARK: - Connection

struct HermesConnection: Codable, Equatable {
    var baseUrl: String
    var ticket: String
}

// MARK: - Turn and composer state

/// The composer is driven by the gateway's authoritative session state, not by
/// the last locally received stream event. This is what makes a foreground,
/// reconnect, or relaunch safe while a turn is in flight.
enum TurnState: Equatable {
    case synchronizing
    case idle
    case running
    case reconnecting
    case unsupportedGateway

    var acceptsComposerActions: Bool {
        self == .idle || self == .running
    }

    var isRunning: Bool {
        self == .running
    }

    static func fromGatewayRunning(_ running: Bool?) -> TurnState {
        guard let running else { return .unsupportedGateway }
        return running ? .running : .idle
    }

    func composerAction(hasText: Bool, hasAttachments: Bool, busyInputMode: BusyInputMode) -> ComposerAction {
        switch self {
        case .synchronizing, .reconnecting, .unsupportedGateway:
            return .unavailable
        case .idle:
            return hasText || hasAttachments ? .send : .unavailable
        case .running:
            // Attachments go only as Queue (#1146): Hermes' steer takes
            // text alone, and a busy prompt.submit carrying staged images
            // always queues them as their own turn, whatever the mode.
            if hasAttachments { return .queue }
            guard hasText else { return .stop }
            return busyInputMode.composerAction
        }
    }
}

enum ComposerAction: Equatable {
    case unavailable
    case send
    case stop
    case steer
    case interrupt
    /// Waits as the next message until the running turn finishes.
    case queue
}

/// What a long-press on the composer's action button offers for this
/// message only; a plain tap keeps the action it shows (#816, #817, #842,
/// #962).
enum ComposerSendChoice: String, CaseIterable, Identifiable {
    case steer
    case interrupt
    case queue
    /// `/background`: a separate agent takes the message.
    case background
    /// `/btw`: a side question over a snapshot of the chat.
    case btw

    var id: String { rawValue }

    /// The busy mode this choice stands for, if it is one.
    var busyInputMode: BusyInputMode? {
        switch self {
        case .steer: return .steer
        case .interrupt: return .interrupt
        case .queue: return .queue
        case .background, .btw: return nil
        }
    }

    var title: String {
        switch self {
        case .steer, .interrupt, .queue: return busyInputMode?.title ?? ""
        case .background: return AppLocalization.string("Background")
        case .btw: return AppLocalization.string("Side question")
        }
    }

    var symbol: String {
        switch self {
        case .steer, .interrupt, .queue: return busyInputMode?.symbol ?? ""
        case .background: return "square.stack.3d.up"
        case .btw: return "bubble.left.and.text.bubble.right"
        }
    }

    /// The slash command a side-agent choice sends the message as.
    var slashCommand: String? {
        switch self {
        case .background: return "background"
        case .btw: return "btw"
        case .steer, .interrupt, .queue: return nil
        }
    }

    /// The other ways to send a typed message, in menu order. While Hermes
    /// works: the busy modes the tap doesn't use, then the side agents.
    /// While idle: the side agents. None for attachments (only Queue takes
    /// them, and the tap already does) or a slash command (it runs as
    /// typed).
    static func choices(for action: ComposerAction, hasAttachments: Bool, isSlashCommand: Bool) -> [ComposerSendChoice] {
        guard !hasAttachments, !isSlashCommand else { return [] }
        switch action {
        case .send:
            return [.background, .btw]
        case .steer, .interrupt, .queue:
            let busyModes: [ComposerSendChoice] = [.steer, .queue, .interrupt]
            return busyModes.filter { $0.busyInputMode?.composerAction != action } + [.background, .btw]
        case .stop, .unavailable:
            return []
        }
    }
}

/// Profile-scoped Hermes setting (`display.busy_input_mode`).
enum BusyInputMode: String, CaseIterable, Codable, Identifiable {
    case steer
    case interrupt
    /// The message waits and goes as the next turn once the running one
    /// finishes (#842). Held on the phone, so it works on any Hermes.
    case queue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steer: return AppLocalization.string("Steer")
        case .interrupt: return AppLocalization.string("Interrupt")
        case .queue: return AppLocalization.string("Queue")
        }
    }

    /// The composer action a typed message takes in this mode.
    var composerAction: ComposerAction {
        switch self {
        case .steer: return .steer
        case .interrupt: return .interrupt
        case .queue: return .queue
        }
    }

    /// The composer button and settings glyph for this mode (issue #337).
    /// Steer avoids the branching arrow, which reads as "fork"/"branch
    /// session"; Interrupt avoids the U-turn arrow, which reads as "undo".
    var symbol: String {
        switch self {
        case .steer: return "steeringwheel"
        case .interrupt: return "hand.raised.fill"
        case .queue: return "text.line.last.and.arrowtriangle.forward"
        }
    }

    /// Unset or unknown is interrupt, as Hermes reads it.
    static func fromGatewayValue(_ value: String?) -> BusyInputMode {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case BusyInputMode.steer.rawValue: return .steer
        case BusyInputMode.queue.rawValue: return .queue
        default: return .interrupt
        }
    }
}

/// Display preferences are owned by the active Hermes profile, not this
/// device. Keeping them together ensures chat and Settings render the same
/// source of truth after a profile switch or reconnect.
struct ProfileDisplayPreferences: Equatable, Codable {
    var showReasoning = true
    /// `display.conduit_thinking_on_request` isn't false: with thinking
    /// hidden, a run's menu and its reply's ⋯ still offer Show thinking
    /// (ReasoningDisplayMode).
    var thinkingOnRequest = true
    var showToolProgress = true
    var expandToolsByDefault = false
    /// `display.memory_notifications` isn't "off": the self-improvement
    /// review rows draw, the ones a chat already has included.
    var showReviews = true

    /// Hermes' reading of `display.memory_notifications`: a YAML bool is
    /// on or off, anything else but "off" (unset, "default", "verbose")
    /// shows them.
    static func showsReviews(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        guard let string = value as? String else { return true }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "off"
    }

    var reasoningMode: ReasoningDisplayMode {
        ReasoningDisplayMode(showReasoning: showReasoning, onRequest: thinkingOnRequest)
    }

    /// Thinking is hidden and Show thinking is offered.
    var offersShowThinking: Bool { reasoningMode == .onRequest }
}

/// The Thinking choice in Settings > Chat. Hermes' own `display.show_reasoning`
/// stays a switch other clients read too, so Show is that switch on, and
/// Conduit's `display.conduit_thinking_on_request` tells On request from Off
/// while it is off. Unset reads as On request, so an install that had the
/// switch off keeps its Show thinking menus.
enum ReasoningDisplayMode: String, CaseIterable {
    case show
    case onRequest = "on_request"
    case off

    /// The settings row's own key: no config value of that name is kept.
    static let settingKey = "conduit.reasoning_display"
    static let onRequestConfigKey = "conduit_thinking_on_request"

    init(showReasoning: Bool, onRequest: Bool) {
        self = showReasoning ? .show : (onRequest ? .onRequest : .off)
    }

    /// Read from the profile's `display` block, Hermes' defaults applied.
    init(display: [String: Any]) {
        self.init(
            showReasoning: display["show_reasoning"] as? Bool ?? true,
            onRequest: display[Self.onRequestConfigKey] as? Bool ?? true
        )
    }

    /// Written into the `display` block. Show leaves Conduit's own key as
    /// it is, so turning Show off again goes back to the last of the two.
    func write(into display: inout [String: Any]) {
        display["show_reasoning"] = self == .show
        if self != .show { display[Self.onRequestConfigKey] = self == .onRequest }
    }
}

enum DisplayPreferenceKey: CaseIterable, Identifiable {
    case toolProgress
    case expandTools

    var id: Self { self }
}

/// The small set of value types used by Hermes' profile configuration. The
/// settings UI intentionally keeps this distinct from arbitrary dashboard JSON
/// so local controls stay type-safe while AppState owns serialization.
enum ProfileSettingValue: Equatable {
    case bool(Bool)
    case text(String)
    case number(Double)
    /// A list of plain strings, such as `command_allowlist`.
    case list([String])

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var textValue: String? {
        switch self {
        case .text(let value): return value
        case .number(let value): return Self.numberText(value)
        case .bool(let value): return value ? "true" : "false"
        case .list(let value): return value.joined(separator: "\n")
        }
    }

    var listValue: [String]? {
        if case .list(let value) = self { return value }
        return nil
    }

    /// Whole numbers read "300", not "300.0": most Hermes number settings
    /// are counts, seconds, or characters.
    static func numberText(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// What someone typed in a number field. The decimal pad shows a comma in
    /// locales like fr-CA, so "0,8" reads as 0.8 as well as "0.8"; spaces
    /// around the number are ignored. "nan" and "inf" (or an overflow) are
    /// refused: the config goes out as JSON, which has neither, and
    /// JSONSerialization raises on them.
    static func parseNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Double?
        if let plain = Double(trimmed) {
            value = plain
        } else {
            guard !trimmed.contains("."), trimmed.filter({ $0 == "," }).count == 1 else { return nil }
            value = Double(trimmed.replacingOccurrences(of: ",", with: "."))
        }
        guard let value, value.isFinite else { return nil }
        return value
    }
}

/// The gateway's `GET /api/config/schema`: every config key it knows, by dot
/// path, with its type and any fixed choices. Hermes Desktop builds its
/// settings pages from it; Conduit uses it to hide settings an older Hermes
/// doesn't have and to fill in choices Hermes discovers at runtime.
struct ProfileConfigSchema: Equatable {
    struct Field: Equatable {
        /// "boolean", "number", "string", "list", "object" or "select".
        var type: String
        var options: [String] = []
    }

    var fields: [String: Field] = [:]

    var isEmpty: Bool { fields.isEmpty }

    init(fields: [String: Field] = [:]) {
        self.fields = fields
    }

    init(json: [String: Any]) {
        let raw = json["fields"] as? [String: Any] ?? [:]
        var fields: [String: Field] = [:]
        for (key, value) in raw {
            guard let entry = value as? [String: Any] else { continue }
            let options = (entry["options"] as? [Any] ?? []).compactMap { $0 as? String }
            fields[key] = Field(type: entry["type"] as? String ?? "string", options: options)
        }
        self.fields = fields
    }

    subscript(key: String) -> Field? { fields[key] }
}

/// One `fallback_providers` entry: the model Hermes tries when the default
/// fails. Entries can carry hand-written routing (`base_url`, `key_env`,
/// `api_mode`…); `extras` keeps it so a save never drops it.
struct ProfileFallbackModel: Equatable, Identifiable {
    let id = UUID()
    var provider: String
    var model: String
    var extras: [String: AnyCodable] = [:]

    static func == (lhs: ProfileFallbackModel, rhs: ProfileFallbackModel) -> Bool {
        lhs.provider == rhs.provider && lhs.model == rhs.model && lhs.extras == rhs.extras
    }

    /// Reads the raw config value: a list of `{provider, model, …}` objects,
    /// or legacy "provider/model" strings.
    static func list(from value: Any?) -> [ProfileFallbackModel] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            if let object = item as? [String: Any] {
                var extras = object.mapValues(AnyCodable.init(jsonObject:))
                extras["provider"] = nil
                extras["model"] = nil
                return ProfileFallbackModel(
                    provider: object["provider"] as? String ?? "",
                    model: object["model"] as? String ?? "",
                    extras: extras
                )
            }
            if let text = item as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                guard let slash = trimmed.firstIndex(of: "/"), slash != trimmed.startIndex else {
                    return ProfileFallbackModel(provider: "", model: trimmed)
                }
                return ProfileFallbackModel(
                    provider: String(trimmed[..<slash]),
                    model: String(trimmed[trimmed.index(after: slash)...])
                )
            }
            return nil
        }
    }

    var jsonObject: [String: Any] {
        var object = extras.mapValues(\.anyValue)
        object["provider"] = provider
        object["model"] = model
        return object
    }

    var isComplete: Bool {
        !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ProfileModelDefaults: Equatable {
    var providers: [ProviderInfo]
    var model: String
    var provider: String
    var reasoning: String

    /// The picker selection for the saved default. The saved provider can be
    /// spelled differently from the row slug (display name, `custom:<key>`,
    /// or `auto`), so match like Hermes Desktop and then fall back to the row
    /// Hermes marks current or the only row listing the saved model. A saved
    /// default no row vouches for is shown as saved, never swapped for the
    /// first row: Desktop keeps it the same way, and Save would otherwise pin
    /// the first provider's first model. The first row is used only when
    /// nothing is saved. A saved model missing from its row's list is kept.
    var selection: (provider: String, model: String) {
        if let row = providers.first(where: { $0.matches(provider) })
            ?? providers.first(where: \.isCurrent)
            ?? uniqueRow(listing: model) {
            return (row.name, model.isEmpty ? row.models.first?.id ?? "" : model)
        }
        guard ProviderInfo.normalized(provider).isEmpty, ProviderInfo.normalized(model).isEmpty, let row = providers.first else { return (provider, model) }
        return (row.name, row.models.first?.id ?? "")
    }

    /// The delegate picker selection for saved `delegation.provider` and
    /// `delegation.model`. Empty values mean "inherit from the chat" and stay
    /// empty; Hermes accepts a model with an inherited provider, so the model
    /// is kept even then. A saved provider resolves to its row like
    /// `selection`, and an unknown provider or unlisted model is kept as
    /// saved rather than replaced by the first catalog entry.
    func delegateSelection(provider savedProvider: String, model savedModel: String) -> (provider: String, model: String) {
        guard !ProviderInfo.normalized(savedProvider).isEmpty else { return ("", savedModel) }
        let row = providers.first(where: { $0.matches(savedProvider) })
        return (row?.name ?? savedProvider, savedModel)
    }

    /// Whether the saved main model offers Ultrafast, which Hermes' config
    /// schema leaves out of the Fast mode choices (Desktop adds it the same
    /// way, from the catalog row's capabilities).
    var mainModelOffersUltrafast: Bool {
        let (rowName, model) = selection
        return providers.first { $0.matches(rowName) }?.offersUltrafast(model) ?? false
    }

    private func uniqueRow(listing model: String) -> ProviderInfo? {
        guard !model.isEmpty else { return nil }
        let rows = providers.filter { $0.models.contains(where: { $0.id == model }) }
        return rows.count == 1 ? rows[0] : nil
    }
}

/// Device-local model picker filtering. It mirrors the React client's
/// preference store and deliberately does not change Hermes configuration.
struct ModelVisibility: Codable, Equatable {
    var hiddenProviders: [String] = []
    var hiddenModels: [String] = []
}

struct ProfileConfigOptions: Equatable {
    var personalities: [String] = []
    var memoryProviders: [String] = []
    var contextEngines: [String] = ["default", "custom"]
}

// MARK: - Theme

enum ThemePreference: String, Codable {
    case dark, light, system

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

// MARK: - Runtime State

struct RuntimeState: Equatable {
    var connected: Bool = false
    var contextPercent: Double = 0
    var contextUsed: Int = 0
    var contextMax: Int = 0
    var cwd: String = ""
    var fast: Bool = false
    /// The tier behind `fast`: "priority", "ultrafast", "auto", "cold", or
    /// empty for normal. Empty on gateways that only report `fast`.
    var serviceTier: String = ""
    var model: String = ""
    var provider: String = ""
    var reasoningEffort: String = ""
    /// Last-known profile-wide approval mode ("manual", "smart", "off").
    /// When "off", Hermes auto-approves globally and no per-session YOLO toggle
    /// can require approvals; the indicator reflects that effective state.
    var approvalsMode: String? = nil
    var yolo: Bool = false
}

// MARK: - Capabilities

struct CapabilitySkill: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var description: String?
    var category: String?
    var enabled: Bool
    var provenance: String?
    var usage: Int?
}

struct CapabilityToolset: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var description: String?
    var enabled: Bool
    var configured: Bool?
    var label: String?
    var tools: [String]?
}

// MARK: - Slash Commands

struct SlashCommand: Identifiable, Equatable {
    /// Stable identity: the protocol name. Descriptions are re-resolved per
    /// App Language, so a UUID minted at construction would make every
    /// language change look like a full list replacement to ForEach.
    var id: String { name }
    let name: String
    var aliases: [String] = []
    var description: String
    var category: String?
    var argsHint: String?
}

struct CapabilityMcpServer: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var enabled: Bool
    var command: String?
    var url: String?
    var transport: String?
    var args: [String]?
    var tools: [String]?
}
