import SwiftUI

// MARK: - Staged triage action (V3A final pass)

/// The immutable payload of a user-initiated Triage action: the TASK identity
/// plus the board/server stamp that authorized it, both frozen SYNCHRONOUSLY
/// at the tap - never re-read after asynchronous scheduling. Decompose stages
/// this value through its confirmation so confirming an action staged for A
/// can never act on B (task navigation, board switch, or server reconfigure
/// all invalidate the stamp, and the store revalidates it as its hard
/// boundary).
struct PendingTriageAction: Equatable {
    let taskID: String
    let context: KanbanBoardContextStamp
}

extension PendingTriageAction {
    /// Synchronous capture helper: nil when the snapshot is not actionable or
    /// no loaded context exists, so the caller never schedules work on an
    /// unowned identity.
    static func capture(task: KanbanTask?, isSnapshotActionable: Bool, stamp: KanbanBoardContextStamp?) -> PendingTriageAction? {
        guard let task, let stamp, isSnapshotActionable, !task.id.isEmpty else { return nil }
        return PendingTriageAction(taskID: task.id, context: stamp)
    }
}

// MARK: - Editor completion ownership (V3A final pass)

/// Local busy-flag liveness for administrator editors (V3A final pass).
///
/// A busy flag (isSaving/isGenerating) is owned by the LOCAL operation that
/// started it, via a monotonic token - NOT by the server configuration
/// generation. A completion from a stale generation must be UI-inert for
/// server data/notices/baselines, but it must still release the busy flag it
/// owns; otherwise a sheet reconfiguring mid-flight stays permanently busy
/// (stuck interactiveDismissDisabled).
///
/// One token stream serves BOTH flags per editor; that is sound only because
/// the tap guards and .disabled states enforce mutual exclusion (a save and a
/// generation can never be concurrently in flight), so an older operation
/// never needs to release a flag a newer one would own.
struct KanbanEditorLiveness {
    private(set) var token = 0

    /// Begins a new operation and returns the token only the NEWEST operation
    /// may release the busy flag with.
    mutating func begin() -> Int {
        token += 1
        return token
    }

    func owns(_ operationID: Int) -> Bool {
        operationID == token
    }
}

/// Editor completion outcomes that preserve newer local edits (V3A final
/// pass). All rules are pure so the guarantees are deterministically testable.
enum KanbanProfileDescriptionPolicy {
    struct Snapshot: Equatable {
        let profile: String
        let description: String
        let isAuto: Bool
    }

    struct CompletionOutcome: Equatable {
        /// The server baseline after the write (the SUBMITTED value, or the
        /// generated value returned by the server).
        let baselineDescription: String
        let baselineIsAuto: Bool
        /// What the editor should display now.
        let draft: String
        /// True when the editor must remain dirty (newer local typing).
        let isDirtyAfter: Bool
        /// User-facing notice; nil = no notice.
        let notice: String?
    }

    static func isDirty(draft: String, baseline: String) -> Bool {
        draft != baseline
    }

    /// What tapping "Generate Automatically" may do given the editor state.
    enum GenerateResolution: Equatable {
        case allowed
        case requiresDiscard
    }

    static func resolveGenerate(draft: String, baseline: String) -> GenerateResolution {
        isDirty(draft: draft, baseline: baseline) ? .requiresDiscard : .allowed
    }

    /// After a confirmed discard the draft is dropped and generation is legal.
    static func discard(draft: String, baseline: String) -> String {
        baseline
    }

    /// Save completed successfully for the submitted value. The server
    /// baseline is ALWAYS the submitted value - and the draft is normalized
    /// to it only while the user has not typed anything newer since
    /// submission. Newer typing is preserved (raw, WYSIWYG) and the editor
    /// stays dirty: the newer text was never persisted.
    static func saveCompletion(submitted: String, currentRawDraft: String, currentTrimmedDraft: String) -> CompletionOutcome {
        if currentTrimmedDraft == submitted {
            return CompletionOutcome(
                baselineDescription: submitted,
                baselineIsAuto: false,
                draft: submitted,
                isDirtyAfter: false,
                notice: "Description saved."
            )
        }
        return CompletionOutcome(
            baselineDescription: submitted,
            baselineIsAuto: false,
            draft: currentRawDraft,
            isDirtyAfter: true,
            notice: "Description saved. Your newer edits are still unsaved."
        )
    }

    /// Auto-generation completed with the server's generated value. The
    /// server baseline is the generated text (persisted with
    /// description_auto=true). The draft is replaced by the generated text
    /// ONLY while the user has not typed since generation started; newer
    /// manual typing is preserved (raw, WYSIWYG), stays dirty against the
    /// generated baseline, and is never silently discarded (no automatic
    /// follow-up PATCH).
    static func generateCompletion(submittedDraft: String, currentRawDraft: String, currentTrimmedDraft: String, generated: String) -> CompletionOutcome {
        if currentTrimmedDraft == submittedDraft {
            return CompletionOutcome(
                baselineDescription: generated,
                baselineIsAuto: true,
                draft: generated,
                isDirtyAfter: false,
                notice: "Generated automatically — review recommended."
            )
        }
        return CompletionOutcome(
            baselineDescription: generated,
            baselineIsAuto: true,
            draft: currentRawDraft,
            isDirtyAfter: true,
            notice: "Hermes generated a new routing description. Your newer local edits were preserved and are still unsaved."
        )
    }
}

// MARK: - Nudge feedback ownership (V3A final pass)

/// Whether a completed dispatcher nudge may show its success feedback.
/// The captured board/server stamp must still own the loaded, actionable
/// snapshot - a /dispatch that finished on server A after the UI moved to B
/// must display nothing on B. The stamp embeds the configuration generation,
/// so stamp equality is also authoritative for server reconfigures.
enum KanbanNudgePolicy {
    static func shouldShowNotice(
        capturedStamp: KanbanBoardContextStamp,
        currentStamp: KanbanBoardContextStamp?,
        isSnapshotActionable: Bool
    ) -> Bool {
        isSnapshotActionable && currentStamp == capturedStamp
    }
}

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
