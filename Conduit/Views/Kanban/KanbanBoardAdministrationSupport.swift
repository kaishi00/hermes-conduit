import SwiftUI

// MARK: - Board slug policy (V3B)

/// Slug derivation + validation mirroring upstream exactly:
/// - Desktop derives the slug from the board name via
///   name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
///   (apps/desktop board-switcher.tsx NewBoardDialog).
/// - Backend accepts ^[a-z0-9][a-z0-9\-_]{0,63}$ after normalization
///   (kanban_db._normalize_board_slug); malformed slugs -> HTTP 400.
enum KanbanBoardSlugPolicy {
    static func derivedSlug(from name: String) -> String {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var slug = ""
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            let isAlnum = (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isAlnum {
                if pendingDash, !slug.isEmpty {
                    slug.append("-")
                }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return slug
    }

    /// Backend-compatible (kanban_db._BOARD_SLUG_RE):
    /// ^[a-z0-9][a-z0-9\-_]{0,63}$ - lowercase alphanumeric START, then
    /// lowercase alphanumerics / hyphens / underscores, max 64 chars.
    static func isValid(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 64 else { return false }
        let restAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard let first = slug.first, restAllowed.contains(first),
              !(first == "-" || first == "_") else { return false }
        for character in slug.dropFirst() {
            guard character.isASCII, restAllowed.contains(character) else { return false }
        }
        return true
    }
}

// MARK: - Board PATCH tri-state builder (V3B)

/// Editor draft for Board Settings / New Board. The PATCH builder maps
/// baseline-vs-draft to the upstream tri-state exactly:
/// nil = omit (leave unchanged), "" = clear, value = set.
struct KanbanBoardEditorDraft: Equatable {
    var name: String
    var description: String
    /// nil = No Project ("" on the wire when clearing).
    var projectID: String?
    var workspace: KanbanDefaultWorkspaceChoice
}

/// How the board's default workspace is represented.
enum KanbanDefaultWorkspaceChoice: Equatable, Hashable {
    /// Follow the selected project's primary repo (upstream mirrors it into
    /// default_workdir whenever project_id is sent without default_workdir).
    case projectDefault
    /// No workdir (scratch); "" clears the field.
    case none
    /// Explicit directory path.
    case custom(String)
}

enum KanbanBoardPatchPolicy {
    /// Primary repo path of a project, used to decide whether the board's
    /// workdir is already "following" its project (a re-mirror no-op).
    static func primaryPath(of projectID: String?, projects: [KanbanProject]) -> String? {
        guard let projectID, !projectID.isEmpty else { return nil }
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        let path = (project.primaryPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// PATCH built from server baseline vs submitted draft. Every wire value
    /// is decided explicitly - a missing Swift optional can never turn into a
    /// JSON clear, and a pure name edit never touches project/workdir.
    static func patch(
        baseline: KanbanBoardMetadata,
        draft: KanbanBoardEditorDraft,
        projects: [KanbanProject]
    ) -> KanbanUpdateBoardPatch {
        var patch = KanbanUpdateBoardPatch()
        let baselineName = baseline.name ?? ""
        let baselineDescription = baseline.description ?? ""
        let baselineProject: String? = (baseline.projectID ?? "").isEmpty ? nil : baseline.projectID
        let baselineWorkdir: String? = (baseline.defaultWorkdir ?? "").isEmpty ? nil : baseline.defaultWorkdir

        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != baselineName { patch.name = trimmedName }
        if draft.description != baselineDescription { patch.description = draft.description }

        let draftProject: String? = (draft.projectID ?? "").isEmpty ? nil : draft.projectID
        let projectChanged = draftProject != baselineProject
        if projectChanged {
            patch.projectID = draftProject ?? ""
        }

        switch draft.workspace {
        case .projectDefault:
            // Project Default (only offered when a project is selected):
            // the workdir must follow the project's primary repo.
            // - project changed -> the project write alone re-mirrors;
            // - project unchanged but the workdir DRIFTED from the project's
            //   primary repo -> re-sending the SAME project id re-mirrors;
            // - workdir already == the project's primary repo -> no-op.
            // default_workdir is always omitted on this branch.
            if !projectChanged, let draftProject {
                let primary = primaryPath(of: draftProject, projects: projects)
                if baselineWorkdir != primary {
                    patch.projectID = draftProject
                }
            }
        case .none:
            // None / Scratch: clear any existing workdir explicitly.
            if baselineWorkdir != nil {
                patch.defaultWorkdir = ""
            }
        case .custom(let path):
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath != (baselineWorkdir ?? "") {
                patch.defaultWorkdir = trimmedPath
            }
        }
        return patch
    }

    /// Create-time request. switch is ALWAYS false. With a selected project,
    /// upstream mirrors the project repo into default_workdir unless an
    /// explicit path is given - so .none with a project resolves to the
    /// mirror upstream (documented; the create UI hides .none once a project
    /// is picked).
    static func createRequest(
        slug: String,
        name: String,
        description: String,
        projectID: String?,
        workspace: KanbanDefaultWorkspaceChoice
    ) -> KanbanCreateBoardRequest {
        var request = KanbanCreateBoardRequest(
            slug: slug,
            name: name.isEmpty ? nil : name,
            description: description.isEmpty ? nil : description,
            projectID: (projectID ?? "").isEmpty ? nil : projectID,
            switchRequested: false
        )
        switch workspace {
        case .projectDefault:
            break // server mirrors when project set
        case .none:
            request.defaultWorkdir = nil
        case .custom(let path):
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            request.defaultWorkdir = trimmed.isEmpty ? nil : trimmed
        }
        return request
    }
}

// MARK: - Client-side filters (V3B)

/// Client-side task predicate matching upstream Desktop (board.tsx): search
/// over title/body/id, tenant exact equality, assignee exact equality, AND
/// composition. Conduit additionally keeps its existing useful matches
/// (latest summary, assignee) in the search set. Filters never mutate the
/// authoritative board - visible columns are derived from it.
enum KanbanBoardFilterPolicy {
    static func matchesSearch(_ task: KanbanTask, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return task.title.lowercased().contains(q)
            || (task.body ?? "").lowercased().contains(q)
            || task.id.lowercased().contains(q)
            || (task.latestSummary ?? "").lowercased().contains(q)
            || (task.assignee ?? "").lowercased().contains(q)
    }

    static func matchesAssignee(_ task: KanbanTask, _ assignee: String?) -> Bool {
        guard let assignee, !assignee.isEmpty else { return true }
        // Exact equality with the TASK's own assignee - never the resolved
        // default fallback (an unassigned Ready task is not "coder").
        return task.assignee == assignee
    }

    static func matchesTenant(_ task: KanbanTask, _ tenant: String?) -> Bool {
        guard let tenant, !tenant.isEmpty else { return true }
        return task.tenant == tenant
    }

    static func matches(task: KanbanTask, search: String, assignee: String?, tenant: String?) -> Bool {
        matchesSearch(task, search)
            && matchesAssignee(task, assignee)
            && matchesTenant(task, tenant)
    }

    /// A filter referencing a profile/tenant absent from the newly loaded
    /// board must fail harmlessly instead of making the board look empty
    /// forever: resolve to nil (all) when the roster no longer contains it.
    static func validatedFilter(_ value: String?, available: [String]) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return available.contains(value) ? value : nil
    }

    /// The visible (derived) column set: authoritative ordered columns with
    /// each column's tasks filtered. Never mutates the authoritative board.
    static func visibleColumns(
        board: KanbanBoard,
        search: String,
        assignee: String?,
        tenant: String?
    ) -> [KanbanColumn] {
        let resolvedAssignee = validatedFilter(assignee, available: board.assignees)
        let resolvedTenant = validatedFilter(tenant, available: board.tenants)
        let q = search
        let hasCriteria = !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || resolvedAssignee != nil || resolvedTenant != nil
        let columns = KanbanStatusPresentation.orderedColumns(board.columns)
        guard hasCriteria else { return columns }
        return columns.map { column in
            KanbanColumn(
                name: column.name,
                tasks: column.tasks.filter {
                    matches(task: $0, search: q, assignee: resolvedAssignee, tenant: resolvedTenant)
                }
            )
        }
    }
}

// MARK: - Running grouped by profile (V3B)

/// Sub-groups the Running lane by the task's OWN assignee, with an
/// "unassigned" fallback for tasks lacking one - exactly upstream's
/// key = task.assignee || UNASSIGNED_LANE (board.tsx:378) with groups sorted
/// by key (localeCompare; case-insensitive-equivalent ordering here). Applies
/// ONLY to the running lane and ONLY after all filters.
enum KanbanRunningGroupPolicy {
    struct Group: Equatable, Identifiable {
        let key: String
        let displayName: String
        let tasks: [KanbanTask]
        var id: String { key }
    }

    static let unassignedKey = "unassigned"

    static func shouldApply(lane: String, enabled: Bool) -> Bool {
        lane == "running" && enabled
    }

    static func group(_ tasks: [KanbanTask]) -> [Group] {
        var buckets: [String: [KanbanTask]] = [:]
        for task in tasks {
            let key = task.assignee ?? unassignedKey
            buckets[key, default: []].append(task)
        }
        // Deterministic: case-insensitive primary, raw tie-break so equal
        // spellings ("Coder" vs "coder") still sort stable.
        let orderedKeys = buckets.keys.sorted { lhs, rhs in
            let order = lhs.localizedCaseInsensitiveCompare(rhs)
            return order == .orderedAscending || (order == .orderedSame && lhs < rhs)
        }
        return orderedKeys.map { key in
            Group(
                key: key,
                displayName: key == unassignedKey ? "Unassigned" : key,
                tasks: buckets[key] ?? []
            )
        }
    }
}

// MARK: - Staged board archive (V3B)

/// A staged Archive confirmation: the concrete target board slug + display
/// name plus the board/server stamp that authorized it, captured BY VALUE at
/// stage time. The store revalidates the stamp at its mutation boundary (same
/// pattern as card Delete / triage actions): a confirmation staged for
/// server A / board X can never archive a same-named board on server B.
struct PendingBoardArchive: Equatable {
    let slug: String
    let displayName: String
    let stamp: KanbanBoardContextStamp
}

// MARK: - Admin messaging (V3B)

enum KanbanBoardAdminMessage {
    /// POST /boards is idempotent and carries NO created flag upstream; the
    /// only honest client-side distinction is whether the slug was already in
    /// the authoritative pre-POST board list. Never fabricate more than that.
    static func createOutcomeMessage(knewSlugBeforeRequest: Bool, name: String) -> String {
        if knewSlugBeforeRequest {
            return "Board \"\(name)\" already exists — opened it."
        }
        return "Board \"\(name)\" created and selected."
    }

    static func archiveRefreshFailureMessage(_ detail: String) -> String {
        "The board was archived, but the board list could not be refreshed. " + detail
    }
}
