import SwiftUI
import UIKit

// MARK: - Short task ID

/// Upstream `shortId` (apps/desktop/src/plugins/kanban/ui.tsx): strips the `t_`
/// prefix and keeps six characters so cards/chips stay compact.
enum KanbanShortID {
    static func of(_ id: String?) -> String {
        let value = id ?? ""
        let stripped = value.hasPrefix("t_") ? String(value.dropFirst(2)) : value
        return String(stripped.prefix(6))
    }
}

// MARK: - Clipboard

/// Single seam for Kanban copy actions so every use gets the same pasteboard
/// handling plus a VoiceOver announcement, instead of scattering raw
/// `UIPasteboard.general` calls through views.
@MainActor
enum KanbanClipboard {
    static func copy(_ text: String, announcement: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }
}

// MARK: - Lane resolution policy

/// One canonical answer to "which lane does the UI consider active?".
///
/// The iPhone board shows a chip selector over a vertical card list; before the
/// user taps a chip nothing is stored in `selectedLane`, yet a lane IS visibly
/// resolved for display. Every consumer (visible column, New Task initial
/// status, lane-level UI state) must ask THIS policy instead of reading the
/// raw selection, or the global + button would silently fall back to Todo
/// while Triage is on screen.
enum KanbanLanePolicy {
    /// The lane the board actually presents: an explicit selection that still
    /// exists on the snapshot, else the first unlocked lane, else the first
    /// lane at all (a fully locked snapshot still deserves a visible lane).
    static func effectiveSelectedLane(selected: String?, columns: [KanbanColumn]) -> String? {
        guard !columns.isEmpty else { return nil }
        if let selected, !selected.isEmpty, columns.contains(where: { $0.name == selected }) {
            return selected
        }
        return columns.first(where: { !KanbanStatusPresentation.isLockedDestination($0.name) })?.name
            ?? columns.first?.name
    }

    /// Creation target derived from the effective visible lane. Locked lanes
    /// are never valid creation targets (upstream gives them no add button);
    /// they collapse to the backend's default unlocked landing lane.
    static func newTaskInitialStatus(effectiveLane: String?) -> String {
        guard let effectiveLane, KanbanStatusPresentation.canCreateTask(in: effectiveLane) else {
            return "todo"
        }
        return effectiveLane
    }
}

// MARK: - Model / provider / reasoning override

/// A detached per-task worker override. `nil` means "inherit the assigned
/// profile's own setting" — exactly upstream's empty-string sentinel in
/// apps/desktop/src/plugins/kanban/model-override.tsx, without mutating any
/// live chat/session model state.
struct TaskModelOverride: Equatable {
    var provider: String?
    var model: String?
    var reasoningEffort: String?

    /// Backend-valid effort values (`hermes_constants.VALID_REASONING_EFFORTS`
    /// plus "none", which is a real VALUE meaning thinking off — not a clear).
    static let validReasoningEfforts: [String] = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
    ]

    var isInherited: Bool {
        (model ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && (provider ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && (reasoningEffort ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    init(provider: String? = nil, model: String? = nil, reasoningEffort: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    /// Reads the server's per-task fields back into an override value.
    init(task: KanbanTask) {
        self.init(
            provider: task.providerOverride,
            model: task.modelOverride,
            reasoningEffort: task.reasoningEffort
        )
    }

    /// `provider: model · Effort`, or the inherit copy when unset (mirrors
    /// upstream `overrideLabel`).
    func label(inheritCopy: String) -> String {
        if isInherited { return inheritCopy }
        let modelName = model?.trimmingCharacters(in: .whitespaces) ?? ""
        let providerName = provider?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = modelName.isEmpty
            ? inheritCopy
            : (providerName.isEmpty ? modelName : "\(providerName): \(modelName)")
        if let effort = reasoningEffort?.trimmingCharacters(in: .whitespaces), !effort.isEmpty {
            return base + " · " + effortCapitalized(effort)
        }
        return base
    }

    private func effortCapitalized(_ value: String) -> String {
        value == "xhigh" ? AppLocalization.string("Extra High") : value.capitalized
    }

    /// Create-time serialization (upstream `overrideCreateFields`): omit
    /// untouched fields entirely so backend defaults apply; a provider is only
    /// meaningful alongside a model.
    func applyToCreateRequest(_ request: inout KanbanCreateTaskRequest) {
        let modelName = model?.trimmingCharacters(in: .whitespaces)
        let providerName = provider?.trimmingCharacters(in: .whitespaces)
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespaces)
        if let modelName, !modelName.isEmpty {
            request.modelOverride = modelName
            if let providerName, !providerName.isEmpty {
                request.providerOverride = providerName
            }
        }
        if let effort, !effort.isEmpty {
            request.reasoningEffort = effort
        }
    }

    /// Edit-time serialization against the task's CURRENT server values
    /// (upstream `overridePatch`): explicit clear flags exist because a missing
    /// PATCH field means "not sent", not "set to NULL".
    static func patch(from current: KanbanTask, to next: TaskModelOverride) -> KanbanTaskPatch {
        var patch = KanbanTaskPatch()
        let nextModel = next.model?.trimmingCharacters(in: .whitespaces)
        let nextProvider = next.provider?.trimmingCharacters(in: .whitespaces)
        let nextEffort = next.reasoningEffort?.trimmingCharacters(in: .whitespaces)

        let currentHasModelOverride = (current.modelOverride ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
            || (current.providerOverride ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false

        if let nextModel, !nextModel.isEmpty {
            patch.modelOverride = nextModel
            // Desktop parity: provider_override is sent ONLY when explicitly
            // chosen (blank is omitted, never sent as ""), because the
            // explicit clear flag is what resets both fields upstream.
            if let nextProvider, !nextProvider.isEmpty {
                patch.providerOverride = nextProvider
            }
        } else if currentHasModelOverride {
            patch.clearModelOverride = true
        }

        if let nextEffort, !nextEffort.isEmpty {
            patch.reasoningEffort = nextEffort
        } else if !(current.reasoningEffort ?? "").isEmpty {
            patch.clearReasoningEffort = true
        }
        return patch
    }
}

// MARK: - Workspace kinds

/// Upstream `WORKSPACE_KINDS` / backend `VALID_WORKSPACE_KINDS`:
/// scratch | worktree | dir.
enum KanbanWorkspaceKind: String, CaseIterable, Identifiable {
    case scratch
    case worktree
    case dir

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scratch: return AppLocalization.string("Scratch")
        case .worktree: return AppLocalization.string("Worktree")
        case .dir: return AppLocalization.string("Directory")
        }
    }

    /// A user path override is only meaningful for worktree/dir tasks
    /// (desktop hides the field for scratch and never sends it).
    var allowsPathOverride: Bool { self != .scratch }

    /// Board metadata → initial editor value. The backend's own fallback when
    /// no board default exists is scratch (`_default_workspace_kind`).
    static func initialKind(boardDefault: String?) -> KanbanWorkspaceKind {
        guard let raw = boardDefault?.trimmingCharacters(in: .whitespaces).lowercased(),
              let kind = KanbanWorkspaceKind(rawValue: raw) else {
            return .scratch
        }
        return kind
    }
}

// MARK: - Assignee selection

/// Assignment semantics mirrored from Desktop's New Task dialog:
/// - `.inheritDefault` sends the orchestration-resolved default assignee
///   (never a silent nil) — title-only creates must RUN.
/// - `.profile(name)` pins one roster profile.
/// - `.parked` OMITS the assignee field entirely (backend nil = unassigned;
///   desktop labels this "unassigned (parked — won't run)"). There is no
///   separate Conduit meaning for these values.
enum KanbanAssigneeSelection: Equatable, Hashable {
    case inheritDefault
    case profile(String)
    case parked

    /// The wire value for POST /tasks.
    func requestValue(resolvedDefaultAssignee: String) -> String? {
        switch self {
        case .inheritDefault:
            let resolved = resolvedDefaultAssignee.trimmingCharacters(in: .whitespaces)
            return resolved.isEmpty ? "default" : resolved
        case .profile(let name):
            return name
        case .parked:
            return nil
        }
    }

    // NOTE: there is deliberately no "reassign value" accessor here. The
    // reassign ENDPOINT treats nil/"" as UNASSIGN (upstream ReassignBody),
    // which is NOT interchangeable with the create-time Default resolution.
    // Mixing those semantics could silently park a task; reassignment takes
    // an explicit profile name or an explicit unassign, nothing else.
}

// MARK: - Composer draft

/// Detached form state for the mobile task composer. Nothing here touches the
/// live session model or store until Create is tapped.
struct KanbanComposerDraft: Equatable {
    var title = ""
    var body = ""
    var priority = 0
    var assignee: KanbanAssigneeSelection = .inheritDefault
    var workspaceKind: KanbanWorkspaceKind = .scratch
    var workspacePath = ""
    var skills: [String] = []
    var parents: [String] = []
    var goalMode = false
    var goalMaxTurns: Int?
    var modelOverride = TaskModelOverride()

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum KanbanDraftValidationError: LocalizedError, Equatable {
    case emptyTitle
    case invalidWorkspacePath(KanbanWorkspaceKind)
    case invalidReasoningEffort(String)
    case invalidSkill(String)
    case duplicateParent(String)
    case invalidGoalMaxTurns(Int)

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return AppLocalization.string("A title is required.")
        case .invalidWorkspacePath:
            // Only scratch tasks refuse a path (allowsPathOverride), so the
            // sentence names the kinds that take one instead of inserting a
            // translated kind name. The payload stays for Equatable.
            return AppLocalization.string("A workspace path can only be set for Worktree and Directory tasks. Hermes scratch tasks resolve their own directory.")
        case .invalidReasoningEffort(let value):
            return AppLocalization.string("\"\(value)\" is not a valid reasoning effort for a Hermes worker.")
        case .invalidSkill(let skill):
            return AppLocalization.string("\"\(skill)\" is not a usable skill name.")
        case .duplicateParent(let id):
            return AppLocalization.string("Task \(id) is already listed as a parent.")
        case .invalidGoalMaxTurns(let turns):
            return AppLocalization.string("Goal Mode max turns must be at least 1 (got \(String(turns))).")
        }
    }
}

/// The single validation layer for task creation. Views render state; this
/// type decides whether a draft may become a request.
enum KanbanComposerValidator {
    /// Trims/dedupes skills while preserving order. Skill names must survive
    /// verbatim (they are matched against Hermes' installed skills), so only
    /// surrounding whitespace is removed and exact duplicates collapse.
    static func sanitizedSkills(_ skills: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in skills {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    static func sanitizedParents(_ parents: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in parents {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    static func validate(_ draft: KanbanComposerDraft) throws {
        guard !draft.trimmedTitle.isEmpty else { throw KanbanDraftValidationError.emptyTitle }

        // Scratch resolves its own directory upstream; a path there is an
        // invalid combination the backend would ignore or misread.
        let path = draft.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.workspaceKind.allowsPathOverride && !path.isEmpty {
            throw KanbanDraftValidationError.invalidWorkspacePath(draft.workspaceKind)
        }

        if let effort = draft.modelOverride.reasoningEffort?.trimmingCharacters(in: .whitespaces),
           !effort.isEmpty,
           !TaskModelOverride.validReasoningEfforts.contains(effort) {
            throw KanbanDraftValidationError.invalidReasoningEffort(effort)
        }

        // Blank/duplicate skill entries are dropped by sanitization (upstream
        // splits a comma list and filters empties), so there is nothing to
        // reject per-skill here; makeRequest serializes exactly what this
        // validation accepts via the same sanitizer.

        // Duplicate parent check runs against the RAW draft values so a view
        // bug cannot silently collapse two intended dependencies into one.
        let rawParents = draft.parents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if rawParents.count != Set(rawParents).count {
            let duplicated = rawParents.first(where: { candidate in
                rawParents.filter { $0 == candidate }.count > 1
            })
            if let duplicated {
                throw KanbanDraftValidationError.duplicateParent(duplicated)
            }
        }

        if draft.goalMode, let turns = draft.goalMaxTurns, turns < 1 {
            throw KanbanDraftValidationError.invalidGoalMaxTurns(turns)
        }
    }

    /// Builds the POST /tasks body from a validated draft. `triage` is left
    /// false here: the store owns the guarded create+move transaction keyed on
    /// the requested lane.
    static func makeRequest(
        from draft: KanbanComposerDraft,
        resolvedDefaultAssignee: String
    ) throws -> KanbanCreateTaskRequest {
        try validate(draft)

        // Sanitize exactly once and reuse the results so validation and wire
        // serialization can never disagree about what was accepted.
        let skills = sanitizedSkills(draft.skills)
        let parents = sanitizedParents(draft.parents)

        let bodyText = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = draft.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = KanbanCreateTaskRequest(
            title: draft.trimmedTitle,
            // Trimmed for the wire (upstream sends body.trim() || undefined).
            body: bodyText.isEmpty ? nil : bodyText,
            assignee: draft.assignee.requestValue(resolvedDefaultAssignee: resolvedDefaultAssignee),
            priority: max(0, draft.priority),
            workspaceKind: draft.workspaceKind.rawValue,
            workspacePath: draft.workspaceKind.allowsPathOverride && !path.isEmpty ? path : nil,
            parents: parents,
            triage: false,
            skills: skills.isEmpty ? nil : skills,
            goalMode: draft.goalMode,
            // Goal turns only travel when Goal Mode is on (upstream leaves the
            // field nil otherwise).
            goalMaxTurns: draft.goalMode ? draft.goalMaxTurns : nil
        )
        draft.modelOverride.applyToCreateRequest(&request)
        return request
    }
}

// MARK: - Activity event presentation

/// Ports upstream `eventText` (drawer.tsx): known backend event kinds become
/// operator-readable rows with the payload folded into a detail line; unknown
/// kinds degrade to `kind words` plus compact key=value detail so future
/// backend events still say something instead of rendering opaque JSON.
enum KanbanActivityFormatter {
    struct Row: Equatable {
        let label: String
        let detail: String?
    }

    static func row(for event: KanbanEvent) -> Row {
        let payload = event.payload?.objectValue ?? [:]
        let string = { (key: String) -> String? in
            guard let value = payload[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        let status = { (key: String) -> String? in
            guard let raw = string(key) else { return nil }
            return KanbanStatusPresentation.forStatus(raw).displayName
        }

        switch event.kind {
        case "created":
            var parts: [String] = []
            if let s = status("status") { parts.append("as \(s)") }
            if let a = string("assignee") { parts.append("for \(a)") }
            return Row(label: AppLocalization.string("Task created"), detail: parts.isEmpty ? nil : parts.joined(separator: " "))
        case "status":
            let reason = string("reason")
            let detail: String?
            if reason == "parent_reopened" {
                detail = AppLocalization.string("parent \(string("parent") ?? "") reopened")
            } else {
                detail = reason
            }
            return Row(label: AppLocalization.string("Moved to \(status("status") ?? "?")"), detail: detail)
        case "assigned":
            if let assignee = string("assignee") {
                return Row(label: AppLocalization.string("Assigned to \(assignee)"), detail: nil)
            }
            return Row(label: AppLocalization.string("Unassigned"), detail: nil)
        case "commented":
            return Row(label: AppLocalization.string("Comment from \(string("author") ?? AppLocalization.string("someone"))"), detail: nil)
        case "claimed":
            return Row(
                label: string("source_status") == "review" ? AppLocalization.string("Claimed from review") : AppLocalization.string("Claimed by worker"),
                detail: nil
            )
        case "spawned":
            let pid = payload["pid"]?.intValue
            return Row(label: AppLocalization.string("Worker started"), detail: pid.map { AppLocalization.string("pid \(String($0))") })
        case "completed":
            return Row(label: AppLocalization.string("Completed"), detail: nil)
        case "blocked":
            return Row(label: AppLocalization.string("Blocked"), detail: string("reason"))
        case "unblocked":
            return Row(label: AppLocalization.string("Unblocked → \(status("status") ?? "")"), detail: nil)
        case "reclaimed":
            return Row(label: AppLocalization.string("Reclaimed"), detail: string("reason"))
        case "specified":
            return Row(label: AppLocalization.string("Fleshed out by triage specifier"), detail: nil)
        case "promoted":
            return Row(label: AppLocalization.string("Promoted"), detail: nil)
        case "scheduled":
            return Row(label: AppLocalization.string("Scheduled"), detail: string("reason"))
        case "archived":
            return Row(label: AppLocalization.string("Archived"), detail: nil)
        case "reprioritized":
            let priority = payload["priority"]?.intValue
            return Row(label: AppLocalization.string("Priority set to \(priority.map(String.init) ?? "?")"), detail: nil)
        case "edited":
            return Row(label: AppLocalization.string("Details edited"), detail: nil)
        default:
            // Compact key=value detail over SCALAR payload entries only;
            // nested objects/arrays stay out of the row.
            let scalars = payload.compactMap { key, value -> String? in
                switch value {
                case .string(let s): return "\(key)=\(s)"
                case .number(let n):
                    if let exact = Int(exactly: n) { return "\(key)=\(exact)" }
                    return "\(key)=\(n)"
                case .bool(let b): return "\(key)=\(b)"
                case .null, .array, .object: return nil
                }
            }
            .sorted()
            .joined(separator: " ")
            let label = event.kind.replacingOccurrences(of: "_", with: " ").capitalized
            return Row(label: label, detail: scalars.isEmpty ? nil : scalars)
        }
    }
}

// MARK: - Run presentation

/// Shared run-row classification (upstream drawer runs list).
enum KanbanRunPresentation {
    static let failedOutcomes: [String] = ["crashed", "failed", "timed_out", "gave_up"]

    static func isFailed(_ run: KanbanRun) -> Bool {
        failedOutcomes.contains(run.outcome ?? run.status)
    }

    static func durationText(start: Int?, end: Int?, locale: Locale = AppLocalization.formattingLocale) -> String? {
        guard let start, let end, end >= start, start > 0 else { return nil }
        return KanbanCompactDuration.text(seconds: end - start, locale: locale)
    }

    static func outcomeLabel(_ run: KanbanRun) -> String {
        (run.outcome ?? run.status).replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Card liveness

/// Card machine-activity state (upstream `arcState`): running workers tick,
/// running workers whose heartbeat died go stale (>120s), queued states show
/// who is attached.
enum KanbanCardLiveness {
    enum State: Equatable {
        case running
        case stale
        case queued
    }

    /// Seconds without a heartbeat before a running worker reads as stale
    /// (upstream ui.tsx uses 120s).
    static let staleHeartbeatSeconds = 120

    static func state(for task: KanbanTask, now: Date = Date()) -> State? {
        if task.status == "running" {
            if let heartbeat = task.lastHeartbeatAt,
               now.timeIntervalSince1970 - Double(heartbeat) > Double(staleHeartbeatSeconds) {
                return .stale
            }
            return .running
        }
        let queued = task.status == "triage"
            || task.status == "review"
            || (task.status == "ready" && task.assignee != nil && !task.assignee!.isEmpty)
        return queued ? .queued : nil
    }

    static func elapsedText(startedAt: Int?, now: Date = Date()) -> String? {
        guard let startedAt, startedAt > 0 else { return nil }
        return KanbanCompactDuration.text(seconds: max(0, Int(now.timeIntervalSince1970) - startedAt))
    }
}

/// A run or worker age in its largest whole unit ("30s", "2m", "1h", "3d"
/// in English), abbreviated the way the UI's language writes units.
enum KanbanCompactDuration {
    static func text(seconds: Int, locale: Locale = AppLocalization.formattingLocale) -> String {
        let steps: [(size: Int, unit: NSCalendar.Unit)] = [
            (86_400, .day), (3_600, .hour), (60, .minute), (1, .second),
        ]
        let step = steps.first { seconds >= $0.size } ?? steps[steps.count - 1]
        // Whole units only: the formatter would round 1h 59m up to "2h".
        let whole = seconds / step.size * step.size
        return formatter(locale: locale, unit: step.unit).string(from: TimeInterval(whole)) ?? "\(whole / step.size)"
    }

    /// Card and run rows ask on every render, so each locale and unit
    /// keeps its formatter. NSCache is safe from any thread.
    private static let formatters = NSCache<NSString, DateComponentsFormatter>()

    private static func formatter(locale: Locale, unit: NSCalendar.Unit) -> DateComponentsFormatter {
        let key = "\(locale.identifier)|\(unit.rawValue)" as NSString
        if let cached = formatters.object(forKey: key) { return cached }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = unit
        formatters.setObject(formatter, forKey: key)
        return formatter
    }
}
