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
}

enum SessionSource: String, Codable, CaseIterable {
    case chat
    case discord
    case telegram
    case api
    case webhook
    case cron
    case other

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .discord: return "Discord"
        case .telegram: return "Telegram"
        case .api: return "API"
        case .webhook: return "Webhook"
        case .cron: return "Cron"
        case .other: return "Other"
        }
    }

    var iconName: String {
        switch self {
        case .chat: return "bubble.left.fill"
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
        case .discord: return .purple
        case .telegram: return .cyan
        case .api: return .green
        case .webhook: return .orange
        case .cron: return .pink
        case .other: return .gray
        }
    }
}

struct Attachment: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var uri: String
    var mimeType: String?
    var kind: Kind

    enum Kind: String, Codable {
        case image
        case document
    }
}

struct ToolActivity: Codable, Equatable {
    var id: String?
    var name: String
    var input: String?
    var output: String?
    var status: Status

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
        case questions
        case isExpired
        case error
        // Legacy single-question shape.
        case question, choices, status, answer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        isExpired = try container.decodeIfPresent(Bool.self, forKey: .isExpired) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
        if let questions = try? container.decode([ClarifyQuestion].self, forKey: .questions), !questions.isEmpty {
            self.questions = questions
            return
        }
        // Migration: presentation caches written by older builds stored the
        // legacy single-question fields. Decode what is still usable instead
        // of failing the whole cache load; a degenerate empty-text record
        // yields an empty question list rather than a phantom question.
        let question = (try? container.decode(String.self, forKey: .question)) ?? ""
        let choices = (try? container.decode([ClarifyChoice].self, forKey: .choices)) ?? []
        let status = (try? container.decode(ClarifyQuestion.Status.self, forKey: .status)) ?? .pending
        let answer = try? container.decode(String.self, forKey: .answer)
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

/// A session-scoped command decision requested by Hermes while a turn is
/// paused. Hermes uses the session as the request identity, so there is no
/// separate request ID to send back with `approval.respond`.
struct ApprovalActivity: Codable, Equatable {
    var sessionId: String
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
        case error
    }
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
    var attachments: [Attachment]?
    var code: String?
    /// Canonical Hermes `display_kind` when the persisted row arrived with
    /// explicit synthetic-timeline projection (`model_switch`, `auto_continue`,
    /// …). Nil for ordinary rows. Normalization already reduced the row to its
    /// final display role/content; this only lets the timeline UI style the
    /// notice without re-deriving it from text.
    let displayKind: String?

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
        attachments: [Attachment]? = nil,
        code: String? = nil,
        displayKind: String? = nil
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
        self.attachments = attachments
        self.code = code
        self.displayKind = displayKind
    }
}

struct WorkspaceEntry: Identifiable, Equatable {
    var name: String
    var path: String
    var isDirectory: Bool

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

        var label: String { rawValue.capitalized }
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
}

// MARK: - Session

struct SessionSummary: Identifiable, Equatable {
    let id: String
    /// The durable database identity used by `session.resume`. Hermes stream
    /// events and notifications may carry the live runtime identity instead.
    var storedSessionId: String? = nil
    var alternateIds: [String]
    var title: String
    var model: String
    var updatedLabel: String
    var profile: String?
    var source: SessionSource
    var isActive: Bool
    var isArchived: Bool
    var messageCount: Int? = nil
    var lineageRootId: String?
}

/// A server-owned workspace from Hermes' `projects.*` capability. Projects are
/// profile-scoped and define session membership by their folders; Conduit only
/// presents that authoritative grouping and never tries to infer it locally.
struct ProjectSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var primaryPath: String?
    var icon: String?
    var colorHex: String?
    var isHome: Bool
    var sessionCount: Int
    var previewSessions: [SessionSummary]
}

struct ProjectSessionLane: Identifiable, Equatable {
    let id: String
    var title: String
    var sessions: [SessionSummary]
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
}

struct CronSchedule: Codable {
    var display: String?
    var expr: String?
    var kind: String?
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
            // Attachments do not have steering semantics. With no typed text,
            // keep Stop available even if an attachment was drafted earlier.
            guard hasText else { return .stop }
            return busyInputMode == .interrupt ? .interrupt : .steer
        }
    }
}

enum ComposerAction: Equatable {
    case unavailable
    case send
    case stop
    case steer
    case interrupt
}

/// Profile-scoped Hermes setting (`display.busy_input_mode`).
enum BusyInputMode: String, CaseIterable, Codable, Identifiable {
    case steer
    case interrupt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steer: return "Steer"
        case .interrupt: return "Interrupt"
        }
    }

    static func fromGatewayValue(_ value: String?) -> BusyInputMode {
        value?.lowercased() == BusyInputMode.interrupt.rawValue ? .interrupt : .steer
    }
}

/// Display preferences are owned by the active Hermes profile, not this
/// device. Keeping them together ensures chat and Settings render the same
/// source of truth after a profile switch or reconnect.
struct ProfileDisplayPreferences: Equatable {
    var showReasoning = true
    var showToolProgress = true
    var expandToolsByDefault = false
}

enum DisplayPreferenceKey: CaseIterable, Identifiable {
    case reasoning
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

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var textValue: String? {
        switch self {
        case .text(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
}

struct ProfileModelDefaults: Equatable {
    var providers: [ProviderInfo]
    var model: String
    var provider: String
    var reasoning: String
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
    let id = UUID()
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
