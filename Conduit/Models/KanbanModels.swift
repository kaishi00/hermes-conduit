import Foundation

// MARK: - Defensive JSON helpers

private extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func decodeLossyInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }
}

// MARK: - Board and task models

struct KanbanTaskWarnings: Codable, Equatable {
    var count: Int = 0
    var highestSeverity: String?

    enum CodingKeys: String, CodingKey {
        case count
        case highestSeverity = "highest_severity"
    }
}

struct KanbanLinkCounts: Codable, Equatable {
    var parents: Int = 0
    var children: Int = 0
}

struct KanbanProgress: Codable, Equatable {
    var done: Int = 0
    var total: Int = 0
}

struct KanbanDiagnosticAction: Codable, Equatable {
    var kind: String
    var label: String
    var payload: [String: AnyCodable]?
    var suggested: Bool?
}

struct KanbanDiagnostic: Codable, Equatable {
    var kind: String
    var severity: String
    var title: String
    var detail: String
    var actions: [KanbanDiagnosticAction]
    var count: Int
    var lastSeenAt: Int?
    var data: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case kind, severity, title, detail, actions, count, data
        case lastSeenAt = "last_seen_at"
    }
}

/// The small, UI-facing slice of a Kanban task returned by the backend.
/// Unknown backend fields are intentionally ignored so schema additions remain safe.
struct KanbanTask: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var body: String?
    var status: String
    var assignee: String?
    var priority: Int?
    var tenant: String?
    var createdAt: Int?
    var latestSummary: String?
    var commentCount: Int?
    var linkCounts: KanbanLinkCounts?
    var progress: KanbanProgress?
    var warnings: KanbanTaskWarnings?
    var startedAt: Int?
    var workerPid: Int?
    var lastHeartbeatAt: Int?

    // Detail-only fields. Keeping them on the same value type lets the board
    // and drawer share one decoder while preserving the backend's flat shape.
    var result: String?
    var createdBy: String?
    var modelOverride: String?
    var providerOverride: String?
    var reasoningEffort: String?
    var completedAt: Int?
    var lastFailureError: String?
    var workspaceKind: String?
    var workspacePath: String?
    var branchName: String?
    var consecutiveFailures: Int?
    var diagnostics: [KanbanDiagnostic]?

    enum CodingKeys: String, CodingKey {
        case id, title, body, status, assignee, priority, tenant
        case createdAt = "created_at"
        case latestSummary = "latest_summary"
        case commentCount = "comment_count"
        case linkCounts = "link_counts"
        case progress, warnings
        case startedAt = "started_at"
        case workerPid = "worker_pid"
        case lastHeartbeatAt = "last_heartbeat_at"
        case result
        case createdBy = "created_by"
        case modelOverride = "model_override"
        case providerOverride = "provider_override"
        case reasoningEffort = "reasoning_effort"
        case completedAt = "completed_at"
        case lastFailureError = "last_failure_error"
        case workspaceKind = "workspace_kind"
        case workspacePath = "workspace_path"
        case branchName = "branch_name"
        case consecutiveFailures = "consecutive_failures"
        case diagnostics
    }

    init(
        id: String,
        title: String,
        body: String? = nil,
        status: String,
        assignee: String? = nil,
        priority: Int? = nil,
        tenant: String? = nil,
        createdAt: Int? = nil,
        latestSummary: String? = nil,
        commentCount: Int? = nil,
        linkCounts: KanbanLinkCounts? = nil,
        progress: KanbanProgress? = nil,
        warnings: KanbanTaskWarnings? = nil,
        startedAt: Int? = nil,
        workerPid: Int? = nil,
        lastHeartbeatAt: Int? = nil,
        result: String? = nil,
        createdBy: String? = nil,
        modelOverride: String? = nil,
        providerOverride: String? = nil,
        reasoningEffort: String? = nil,
        completedAt: Int? = nil,
        lastFailureError: String? = nil,
        workspaceKind: String? = nil,
        workspacePath: String? = nil,
        branchName: String? = nil,
        consecutiveFailures: Int? = nil,
        diagnostics: [KanbanDiagnostic]? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.tenant = tenant
        self.createdAt = createdAt
        self.latestSummary = latestSummary
        self.commentCount = commentCount
        self.linkCounts = linkCounts
        self.progress = progress
        self.warnings = warnings
        self.startedAt = startedAt
        self.workerPid = workerPid
        self.lastHeartbeatAt = lastHeartbeatAt
        self.result = result
        self.createdBy = createdBy
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
        self.reasoningEffort = reasoningEffort
        self.completedAt = completedAt
        self.lastFailureError = lastFailureError
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.branchName = branchName
        self.consecutiveFailures = consecutiveFailures
        self.diagnostics = diagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? "Untitled task"
        body = try? container.decodeIfPresent(String.self, forKey: .body)
        status = (try? container.decode(String.self, forKey: .status)) ?? "todo"
        assignee = try? container.decodeIfPresent(String.self, forKey: .assignee)
        priority = container.decodeLossyInt(forKey: .priority)
        tenant = try? container.decodeIfPresent(String.self, forKey: .tenant)
        createdAt = container.decodeLossyInt(forKey: .createdAt)
        latestSummary = try? container.decodeIfPresent(String.self, forKey: .latestSummary)
        commentCount = container.decodeLossyInt(forKey: .commentCount)
        linkCounts = try? container.decodeIfPresent(KanbanLinkCounts.self, forKey: .linkCounts)
        progress = try? container.decodeIfPresent(KanbanProgress.self, forKey: .progress)
        warnings = try? container.decodeIfPresent(KanbanTaskWarnings.self, forKey: .warnings)
        startedAt = container.decodeLossyInt(forKey: .startedAt)
        workerPid = container.decodeLossyInt(forKey: .workerPid)
        lastHeartbeatAt = container.decodeLossyInt(forKey: .lastHeartbeatAt)
        result = try? container.decodeIfPresent(String.self, forKey: .result)
        createdBy = try? container.decodeIfPresent(String.self, forKey: .createdBy)
        modelOverride = try? container.decodeIfPresent(String.self, forKey: .modelOverride)
        providerOverride = try? container.decodeIfPresent(String.self, forKey: .providerOverride)
        reasoningEffort = try? container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        completedAt = container.decodeLossyInt(forKey: .completedAt)
        lastFailureError = try? container.decodeIfPresent(String.self, forKey: .lastFailureError)
        workspaceKind = try? container.decodeIfPresent(String.self, forKey: .workspaceKind)
        workspacePath = try? container.decodeIfPresent(String.self, forKey: .workspacePath)
        branchName = try? container.decodeIfPresent(String.self, forKey: .branchName)
        consecutiveFailures = container.decodeLossyInt(forKey: .consecutiveFailures)
        diagnostics = try? container.decodeIfPresent([KanbanDiagnostic].self, forKey: .diagnostics)
    }
}

struct KanbanColumn: Codable, Equatable, Identifiable {
    var name: String
    var tasks: [KanbanTask]
    var id: String { name }

    init(name: String, tasks: [KanbanTask] = []) {
        self.name = name
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "unknown"
        tasks = (try? container.decode([KanbanTask].self, forKey: .tasks)) ?? []
    }
}

struct KanbanBoard: Codable, Equatable {
    var columns: [KanbanColumn]
    var tenants: [String]
    var assignees: [String]
    var latestEventID: Int?
    var now: Int?

    enum CodingKeys: String, CodingKey {
        case columns, tenants, assignees
        case latestEventID = "latest_event_id"
        case now
    }

    init(columns: [KanbanColumn], tenants: [String] = [], assignees: [String] = [], latestEventID: Int? = nil, now: Int? = nil) {
        self.columns = columns
        self.tenants = tenants
        self.assignees = assignees
        self.latestEventID = latestEventID
        self.now = now
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = (try? container.decode([KanbanColumn].self, forKey: .columns)) ?? []
        tenants = (try? container.decode([String].self, forKey: .tenants)) ?? []
        assignees = (try? container.decode([String].self, forKey: .assignees)) ?? []
        latestEventID = container.decodeLossyInt(forKey: .latestEventID)
        now = container.decodeLossyInt(forKey: .now)
    }
}

struct KanbanBoardMetadata: Codable, Identifiable, Equatable {
    let slug: String
    var name: String?
    var description: String?
    var isCurrent: Bool?
    var total: Int?
    var defaultWorkdir: String?
    var defaultWorkspaceKind: String?
    var projectID: String?
    var projectName: String?

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, name, description
        case isCurrent = "is_current"
        case total
        case defaultWorkdir = "default_workdir"
        case defaultWorkspaceKind = "default_workspace_kind"
        case projectID = "project_id"
        case projectName = "project_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = container.decodeLossyString(forKey: .slug) ?? "default"
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        isCurrent = try? container.decodeIfPresent(Bool.self, forKey: .isCurrent)
        total = container.decodeLossyInt(forKey: .total)
        defaultWorkdir = try? container.decodeIfPresent(String.self, forKey: .defaultWorkdir)
        defaultWorkspaceKind = try? container.decodeIfPresent(String.self, forKey: .defaultWorkspaceKind)
        projectID = try? container.decodeIfPresent(String.self, forKey: .projectID)
        projectName = try? container.decodeIfPresent(String.self, forKey: .projectName)
    }

    init(slug: String, name: String? = nil, description: String? = nil, isCurrent: Bool? = nil, total: Int? = nil, defaultWorkdir: String? = nil, defaultWorkspaceKind: String? = nil, projectID: String? = nil, projectName: String? = nil) {
        self.slug = slug
        self.name = name
        self.description = description
        self.isCurrent = isCurrent
        self.total = total
        self.defaultWorkdir = defaultWorkdir
        self.defaultWorkspaceKind = defaultWorkspaceKind
        self.projectID = projectID
        self.projectName = projectName
    }
}

struct KanbanBoardsResponse: Codable, Equatable {
    var boards: [KanbanBoardMetadata]
    var current: String

    init(boards: [KanbanBoardMetadata] = [], current: String = "default") {
        self.boards = boards
        self.current = current
    }
}

// MARK: - Detail collections

struct KanbanComment: Codable, Identifiable, Equatable {
    let id: String
    var taskID: String?
    var author: String
    var body: String
    var createdAt: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case author, body
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id) ?? UUID().uuidString
        taskID = try? container.decodeIfPresent(String.self, forKey: .taskID)
        author = (try? container.decode(String.self, forKey: .author)) ?? "Hermes"
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        createdAt = container.decodeLossyInt(forKey: .createdAt)
    }
}

struct KanbanEvent: Codable, Identifiable, Equatable {
    let id: String
    var taskID: String?
    var kind: String
    var payload: AnyCodable?
    var createdAt: Int?
    var runID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case kind, payload
        case createdAt = "created_at"
        case runID = "run_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id) ?? UUID().uuidString
        taskID = try? container.decodeIfPresent(String.self, forKey: .taskID)
        kind = (try? container.decode(String.self, forKey: .kind)) ?? "event"
        payload = try? container.decodeIfPresent(AnyCodable.self, forKey: .payload)
        createdAt = container.decodeLossyInt(forKey: .createdAt)
        runID = container.decodeLossyString(forKey: .runID)
    }
}

struct KanbanAttachment: Codable, Identifiable, Equatable {
    let id: String
    var taskID: String?
    var filename: String
    var contentType: String?
    var size: Int?
    var uploadedBy: String?
    var createdAt: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case filename
        case contentType = "content_type"
        case size
        case uploadedBy = "uploaded_by"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id) ?? UUID().uuidString
        taskID = try? container.decodeIfPresent(String.self, forKey: .taskID)
        filename = (try? container.decode(String.self, forKey: .filename)) ?? "Attachment"
        contentType = try? container.decodeIfPresent(String.self, forKey: .contentType)
        size = container.decodeLossyInt(forKey: .size)
        uploadedBy = try? container.decodeIfPresent(String.self, forKey: .uploadedBy)
        createdAt = container.decodeLossyInt(forKey: .createdAt)
    }
}

struct KanbanRun: Codable, Identifiable, Equatable {
    let id: String
    var taskID: String?
    var profile: String?
    var stepKey: String?
    var status: String
    var outcome: String?
    var summary: String?
    var error: String?
    var metadata: AnyCodable?
    var workerPID: Int?
    var startedAt: Int?
    var endedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case profile
        case stepKey = "step_key"
        case status, outcome, summary, error, metadata
        case workerPID = "worker_pid"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id) ?? UUID().uuidString
        taskID = container.decodeLossyString(forKey: .taskID)
        profile = try? container.decodeIfPresent(String.self, forKey: .profile)
        stepKey = try? container.decodeIfPresent(String.self, forKey: .stepKey)
        status = (try? container.decode(String.self, forKey: .status)) ?? "unknown"
        outcome = try? container.decodeIfPresent(String.self, forKey: .outcome)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        metadata = try? container.decodeIfPresent(AnyCodable.self, forKey: .metadata)
        workerPID = container.decodeLossyInt(forKey: .workerPID)
        startedAt = container.decodeLossyInt(forKey: .startedAt)
        endedAt = container.decodeLossyInt(forKey: .endedAt)
    }
}

struct KanbanTaskDetail: Codable, Equatable {
    var task: KanbanTask
    var comments: [KanbanComment]
    var events: [KanbanEvent]
    var attachments: [KanbanAttachment]
    var links: KanbanTaskLinks
    var childResults: [KanbanChildResult]
    var runs: [KanbanRun]

    init(task: KanbanTask, comments: [KanbanComment] = [], events: [KanbanEvent] = [], attachments: [KanbanAttachment] = [], links: KanbanTaskLinks = KanbanTaskLinks(), childResults: [KanbanChildResult] = [], runs: [KanbanRun] = []) {
        self.task = task
        self.comments = comments
        self.events = events
        self.attachments = attachments
        self.links = links
        self.childResults = childResults
        self.runs = runs
    }

    enum CodingKeys: String, CodingKey {
        case task, comments, events, attachments, links
        case childResults = "child_results"
        case runs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = (try? container.decode(KanbanTask.self, forKey: .task)) ?? KanbanTask(id: "", title: "Untitled task", status: "todo")
        comments = (try? container.decode([KanbanComment].self, forKey: .comments)) ?? []
        events = (try? container.decode([KanbanEvent].self, forKey: .events)) ?? []
        attachments = (try? container.decode([KanbanAttachment].self, forKey: .attachments)) ?? []
        links = (try? container.decode(KanbanTaskLinks.self, forKey: .links)) ?? KanbanTaskLinks()
        childResults = (try? container.decode([KanbanChildResult].self, forKey: .childResults)) ?? []
        runs = (try? container.decode([KanbanRun].self, forKey: .runs)) ?? []
    }
}

struct KanbanTaskLinks: Codable, Equatable {
    var parents: [String]
    var children: [String]
    init(parents: [String] = [], children: [String] = []) {
        self.parents = parents
        self.children = children
    }
}

struct KanbanChildResult: Codable, Equatable, Identifiable {
    let id: String
    var title: String?
    var status: String?
    var latestSummary: String?
    var result: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case latestSummary = "latest_summary"
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id) ?? UUID().uuidString
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        latestSummary = try? container.decodeIfPresent(String.self, forKey: .latestSummary)
        result = try? container.decodeIfPresent(String.self, forKey: .result)
    }
}

// MARK: - Auxiliary board data

struct KanbanProfile: Codable, Identifiable, Equatable {
    var name: String
    var isDefault: Bool
    var description: String
    var descriptionAuto: Bool
    var model: String?
    var provider: String?
    var skillCount: Int?
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "is_default"
        case description
        case descriptionAuto = "description_auto"
        case model, provider
        case skillCount = "skill_count"
    }
}

struct KanbanProject: Codable, Identifiable, Equatable {
    var id: String
    var slug: String
    var name: String
    var primaryPath: String?
    var icon: String?
    var color: String?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, icon, color
        case primaryPath = "primary_path"
    }
}

struct KanbanOrchestrationSettings: Codable, Equatable {
    var orchestratorProfile: String
    var defaultAssignee: String
    var autoDecompose: Bool
    var autoPromoteChildren: Bool?
    var resolvedOrchestratorProfile: String
    var resolvedDefaultAssignee: String

    enum CodingKeys: String, CodingKey {
        case orchestratorProfile = "orchestrator_profile"
        case defaultAssignee = "default_assignee"
        case autoDecompose = "auto_decompose"
        case autoPromoteChildren = "auto_promote_children"
        case resolvedOrchestratorProfile = "resolved_orchestrator_profile"
        case resolvedDefaultAssignee = "resolved_default_assignee"
    }
}

struct KanbanTaskEstimate: Codable, Equatable {
    var ok: Bool
    var reason: String?
    var estimatedTokens: Int?
    var complexity: String?
    var rationale: String?
    var model: String?

    enum CodingKeys: String, CodingKey {
        case ok, reason
        case estimatedTokens = "est_tokens"
        case complexity, rationale, model
    }
}

struct KanbanWorkerLog: Codable, Equatable {
    var exists: Bool
    var sizeBytes: Int
    var content: String
    var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case exists
        case sizeBytes = "size_bytes"
        case content, truncated
    }
}

// MARK: - Request bodies

struct KanbanCreateTaskRequest: Encodable, Equatable {
    var title: String
    var body: String?
    var assignee: String?
    var tenant: String?
    var priority: Int
    var workspaceKind: String
    var workspacePath: String?
    var parents: [String]
    var triage: Bool
    var idempotencyKey: String?
    var maxRuntimeSeconds: Int?
    var skills: [String]?
    var goalMode: Bool
    var goalMaxTurns: Int?
    var modelOverride: String?
    var providerOverride: String?
    var reasoningEffort: String?
    var projectID: String?

    enum CodingKeys: String, CodingKey {
        case title, body, assignee, tenant, priority
        case workspaceKind = "workspace_kind"
        case workspacePath = "workspace_path"
        case parents, triage
        case idempotencyKey = "idempotency_key"
        case maxRuntimeSeconds = "max_runtime_seconds"
        case skills
        case goalMode = "goal_mode"
        case goalMaxTurns = "goal_max_turns"
        case modelOverride = "model_override"
        case providerOverride = "provider_override"
        case reasoningEffort = "reasoning_effort"
        case projectID = "project_id"
    }

    init(title: String, body: String? = nil, assignee: String? = nil, tenant: String? = nil, priority: Int = 0, workspaceKind: String = "scratch", workspacePath: String? = nil, parents: [String] = [], triage: Bool = false, idempotencyKey: String? = nil, maxRuntimeSeconds: Int? = nil, skills: [String]? = nil, goalMode: Bool = false, goalMaxTurns: Int? = nil, modelOverride: String? = nil, providerOverride: String? = nil, reasoningEffort: String? = nil, projectID: String? = nil) {
        self.title = title
        self.body = body
        self.assignee = assignee
        self.tenant = tenant
        self.priority = priority
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.parents = parents
        self.triage = triage
        self.idempotencyKey = idempotencyKey
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.skills = skills
        self.goalMode = goalMode
        self.goalMaxTurns = goalMaxTurns
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
        self.reasoningEffort = reasoningEffort
        self.projectID = projectID
    }
}

struct KanbanTaskPatch: Encodable, Equatable {
    var status: String?
    var assignee: String?
    var priority: Int?
    var title: String?
    var body: String?
    var result: String?
    var blockReason: String?
    var summary: String?
    var metadata: [String: AnyCodable]?
    var modelOverride: String?
    var providerOverride: String?
    var clearModelOverride: Bool
    var reasoningEffort: String?
    var clearReasoningEffort: Bool

    enum CodingKeys: String, CodingKey {
        case status, assignee, priority, title, body, result
        case blockReason = "block_reason"
        case summary, metadata
        case modelOverride = "model_override"
        case providerOverride = "provider_override"
        case clearModelOverride = "clear_model_override"
        case reasoningEffort = "reasoning_effort"
        case clearReasoningEffort = "clear_reasoning_effort"
    }

    init(status: String? = nil, assignee: String? = nil, priority: Int? = nil, title: String? = nil, body: String? = nil, result: String? = nil, blockReason: String? = nil, summary: String? = nil, metadata: [String: AnyCodable]? = nil, modelOverride: String? = nil, providerOverride: String? = nil, clearModelOverride: Bool = false, reasoningEffort: String? = nil, clearReasoningEffort: Bool = false) {
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.title = title
        self.body = body
        self.result = result
        self.blockReason = blockReason
        self.summary = summary
        self.metadata = metadata
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
        self.clearModelOverride = clearModelOverride
        self.reasoningEffort = reasoningEffort
        self.clearReasoningEffort = clearReasoningEffort
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(assignee, forKey: .assignee)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(blockReason, forKey: .blockReason)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(modelOverride, forKey: .modelOverride)
        try container.encodeIfPresent(providerOverride, forKey: .providerOverride)
        if clearModelOverride { try container.encode(true, forKey: .clearModelOverride) }
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        if clearReasoningEffort { try container.encode(true, forKey: .clearReasoningEffort) }
    }

    var isEmpty: Bool {
        status == nil && assignee == nil && priority == nil && title == nil && body == nil && result == nil && blockReason == nil && summary == nil && metadata == nil && modelOverride == nil && providerOverride == nil && !clearModelOverride && reasoningEffort == nil && !clearReasoningEffort
    }
}

struct KanbanCommentRequest: Encodable {
    var author: String
    var body: String
}

struct KanbanReassignRequest: Encodable {
    var profile: String?
    var reclaimFirst: Bool
    var reason: String?
    enum CodingKeys: String, CodingKey {
        case profile
        case reclaimFirst = "reclaim_first"
        case reason
    }
}

struct KanbanReclaimRequest: Encodable {
    var reason: String?
}

struct KanbanCreateTaskResponse: Codable, Equatable {
    var task: KanbanTask?
    var warning: String?
}

struct KanbanMutationResponse: Codable, Equatable {
    var ok: Bool?
    var deleted: Bool?
    var taskID: String?
    enum CodingKeys: String, CodingKey {
        case ok, deleted
        case taskID = "task_id"
    }
}

struct KanbanProfilesResponse: Codable, Equatable { var profiles: [KanbanProfile] }
struct KanbanProjectsResponse: Codable, Equatable { var projects: [KanbanProject] }
