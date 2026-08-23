import SwiftUI

// MARK: - Triage eligibility

/// Triage action eligibility (V3A). The backend gates BOTH Specify and
/// Decompose on `status == 'triage'` (kanban_specify.py / kanban_decompose.py:
/// "task is not in triage" is the only status refusal), so the mobile UI must
/// never offer these actions on any other lane — no generic card-level
/// exposure anywhere.
enum KanbanTriagePolicy {
    static func isEligible(status: String) -> Bool {
        status == "triage"
    }

    static func isEligible(task: KanbanTask?) -> Bool {
        task.map { isEligible(status: $0.status) } ?? false
    }
}

// MARK: - Orchestration display semantics (configured vs resolved)

/// Presentation rules for the orchestration settings sheet (V3A §3).
///
/// The backend distinguishes the CONFIGURED value (`"`"` = unset/Default) from
/// the RESOLVED effective value (active default profile). The UI must show
/// both honestly — e.g. `Default (coder)` — instead of implying that `coder`
/// was explicitly persisted.
enum KanbanOrchestrationDisplay {
    /// Picker option label for the Default row of a profile selector.
    /// `configured` is the wire value ("" = unset); `resolved` is the
    /// effective profile named by the backend.
    static func defaultOptionLabel(configured: String, resolved: String) -> String {
        if resolved.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Default"
        }
        return "Default (\(resolved.trimmingCharacters(in: .whitespaces)))"
    }

    /// Footer copy for a profile selector: describes what Default resolves to,
    /// or confirms an explicit pinned profile.
    static func resolveFootnote(configured: String, resolved: String) -> String {
        let resolvedName = resolved.trimmingCharacters(in: .whitespaces)
        let configuredName = configured.trimmingCharacters(in: .whitespaces)
        if configuredName.isEmpty {
            if resolvedName.isEmpty {
                return "Default inherits the active Hermes profile."
            }
            return "Default resolves to \(resolvedName)."
        }
        return "Pinned to \(configuredName)."
    }
}

// MARK: - Profile description editor ownership

/// Dirty-state ownership for the profile routing description editor (V3A §4).
///
/// Generating a description persists text server-side immediately (describe-
/// auto with overwrite:true). Therefore the editor MUST NOT let generation
/// silently clobber an unsaved manual draft: the user has to explicitly
/// discard it first. All rules are pure so the guarantee is testable without
/// UI timing.
enum KanbanProfileDescriptionPolicy {
    struct Snapshot: Equatable {
        let profile: String
        let description: String
        let isAuto: Bool
    }

    static func isDirty(draft: String, baseline: String) -> Bool {
        draft != baseline
    }

    /// What tapping "Generate Automatically" may do given the editor state.
    enum GenerateResolution: Equatable {
        /// No unsaved draft: generate immediately.
        case allowed
        /// An unsaved manual draft exists: generation must not proceed until
        /// the user explicitly discards the draft.
        case requiresDiscard
    }

    static func resolveGenerate(draft: String, baseline: String) -> GenerateResolution {
        isDirty(draft: draft, baseline: baseline) ? .requiresDiscard : .allowed
    }

    /// After a confirmed discard the draft is dropped and generation is legal.
    static func discard(draft: String, baseline: String) -> String {
        baseline
    }
}

// MARK: - Triage action flows

/// Confirmation + result-presentation rules for the Triage Actions section
/// (V3A §6–8). Decompose may create and assign multiple dependent tasks, so
/// it MUST be gated behind an explicit confirmation; the wording mirrors the
/// upstream contract (children created, assigned to profiles, root kept).
enum KanbanTriageActionsPolicy {
    /// A user tap on "Decompose" resolves to a confirmation request, never
    /// directly to the mutation.
    enum DecomposeRequest: Equatable {
        case none
        case confirm
    }

    static func decomposeTap() -> DecomposeRequest {
        .confirm
    }

    /// The confirmation dialog copy (title + message).
    static let decomposeConfirmationTitle = "Decompose this task?"
    static let decomposeConfirmationMessage = "Hermes may create and assign multiple dependent tasks."

    /// Success notice after a completed decompose, built from the backend's
    /// own `fanout` / `child_ids` counts — real product semantics, never
    /// fabricated diagnostics.
    static func successNotice(fanout: Bool, childCount: Int) -> String? {
        if fanout {
            return "Decomposed into \(childCount) task" + (childCount == 1 ? "" : "s")
        }
        // Decompose's single-task fallback (backend fanout=false == a
        // spec-style promotion; distinct from a plain Specify).
        return "Decomposed (single task, no fan-out)"
    }

    /// Partial-success notice when the mutation reached the server but the
    /// authoritative refresh afterwards failed: the failure belongs to the
    /// REFRESH, never to the action itself. storeRefreshError is the board
    /// banner the store recorded for a failed reload (nil = refresh fine).
    static func successNoticeWithRefreshFailure(base: String, storeRefreshError: String?) -> String {
        guard let storeRefreshError,
              !storeRefreshError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return "\(base), but the board could not be refreshed. \(storeRefreshError)"
    }
}
