import SwiftUI

// MARK: - Bulk action vocabulary (V3C)

/// The five V3C bulk actions. Explicit enum, no generic command framework.
enum KanbanBulkAction: Equatable {
    case move(String)
    case assign(String?)
    case priority(Int)
    case archive
    case delete
}

/// The immutable payload of a bulk action: the sorted selected task IDs and
/// the board/server stamp that authorized them, frozen SYNCHRONOUSLY at the
/// tap - the async body never re-reads the live selection or context.
struct PendingBulkOperation: Equatable, Identifiable {
    let id = UUID()
    let ids: [String]
    let context: KanbanBoardContextStamp
    let action: KanbanBulkAction
}

/// The staged value for the destructive Delete confirmation: confirmation
/// operates on THIS immutable value - never on the live selection - so a
/// selection made for board/server A can never delete tasks from B.
struct PendingBulkDelete: Equatable, Identifiable {
    let id = UUID()
    let taskIDs: [String]
    let context: KanbanBoardContextStamp
}

/// The frozen (ids, context) captured synchronously when a bulk action was
/// tapped; the move/assign/priority sheets compose their payload from it and
/// can never re-read the live selection. The stage is the SINGLE source of
/// truth for a pending action: every action entry point overwrites it, and
/// every Archive/Delete confirmation cancel/consume clears it - a stale stage
/// from an earlier flow can never leak into a later action.
struct BulkStagedSelection: Equatable {
    let ids: [String]
    let context: KanbanBoardContextStamp
}

// MARK: - Bulk stage policy (V3C correction pass)

enum KanbanBulkStagePolicy {
    /// Compose the Priority operation from the FROZEN staged selection ONLY -
    /// the Apply button can never target a stale stage from an earlier
    /// Archive/Delete flow (regression: stage A+B -> cancel -> select C+D ->
    /// stage priority -> the operation targets exactly C+D).
    static func priorityOperation(
        staged: BulkStagedSelection?,
        value: Int,
        currentStamp: KanbanBoardContextStamp?,
        isSnapshotActionable: Bool
    ) -> PendingBulkOperation? {
        guard let staged, staged.context == currentStamp, isSnapshotActionable else { return nil }
        return PendingBulkOperation(ids: staged.ids, context: staged.context, action: .priority(value))
    }
}

// MARK: - Bulk notice state (V3C correction pass)

/// Token-guarded bulk-result notice: success vs partial-failure presentation,
/// cleared when a new operation begins or the context changes, auto-hidden by
/// the caller's timer through hideIfCurrent (Nudge pattern).
struct KanbanBulkNoticeState: Equatable {
    enum Kind: Equatable {
        case success
        case warning
    }

    private(set) var token = 0
    private(set) var text: String?
    private(set) var kind: Kind = .success

    mutating func show(_ text: String, kind: Kind) -> Int {
        token += 1
        self.text = text
        self.kind = kind
        return token
    }

    mutating func hideIfCurrent(_ id: Int) {
        if token == id { text = nil }
    }

    mutating func clear() {
        token += 1
        text = nil
    }
}

// MARK: - Selection ownership (V3C)

/// Selection belongs to ONE exact loaded board/server context. The selected
/// IDs alone are not ownership: a task ID could exist on another board or
/// server.
enum KanbanBulkSelectionPolicy {
    /// The selection is usable only while its captured stamp still equals the
    /// currently actionable loaded context. Lane switches within the same
    /// board keep the stamp valid (same context) - selection may persist.
    static func isOwned(
        selectionContext: KanbanBoardContextStamp?,
        currentStamp: KanbanBoardContextStamp?,
        isSnapshotActionable: Bool
    ) -> Bool {
        guard let selectionContext, let currentStamp else { return false }
        return isSnapshotActionable && selectionContext == currentStamp
    }

    /// After any authoritative refresh, prune selected IDs that no longer
    /// exist anywhere on the loaded board (deleted/archived elsewhere).
    /// Merely switching lanes must never prune: the task still exists.
    static func prune(selected: Set<String>, aliveTaskIDs: Set<String>) -> Set<String> {
        selected.intersection(aliveTaskIDs)
    }
}

// MARK: - Partial-failure reconciliation (V3C)

/// Pure reconciliation + presentation for per-ID bulk outcomes. Missing
/// outcomes never count as success; unknown extra IDs are ignored; duplicates
/// resolve to the first outcome.
enum KanbanBulkResultPolicy {
    /// The pure per-ID reconciliation: requested IDs vs server outcomes. A
    /// requested ID with NO corresponding outcome is a failure (never
    /// success); duplicate outcomes: first wins; unexpected extra IDs are
    /// ignored; results are reported in requested order. The backend iterates
    /// independently and HTTP 200 does not imply per-task success.
    static func reconcile(
        requestedIDs: [String],
        results: [KanbanBulkTaskResult]
    ) -> KanbanBulkOperationOutcome {
        var byID: [String: KanbanBulkTaskResult] = [:]
        for result in results where !result.id.isEmpty {
            if byID[result.id] == nil {
                byID[result.id] = result
            }
        }
        var succeeded: [String] = []
        var failures: [KanbanBulkFailure] = []
        for id in requestedIDs where !id.isEmpty {
            guard let result = byID[id] else {
                failures.append(KanbanBulkFailure(id: id, reason: "Hermes returned no result for this task."))
                continue
            }
            if result.ok {
                succeeded.append(id)
            } else {
                failures.append(KanbanBulkFailure(id: id, reason: result.error ?? "Hermes refused the change."))
            }
        }
        return KanbanBulkOperationOutcome(succeededIDs: succeeded, failures: failures)
    }

    static func summary(outcome: KanbanBulkOperationOutcome) -> String {
        let updated = outcome.succeededIDs.count
        let failedCount = outcome.failures.count
        switch (updated, failedCount) {
        case (0, 0):
            return "No tasks updated"
        case (1, 0):
            return "1 task updated"
        case (0, 1):
            return "1 task failed"
        case (0, _):
            return "\(failedCount) tasks failed"
        case (1, 1):
            return "1 updated, 1 failed"
        case (1, _):
            return "1 updated, \(failedCount) failed"
        case (_, 0):
            return "\(updated) tasks updated"
        default:
            return "\(updated) updated, \(failedCount) failed"
        }
    }

    /// The selection after applying an outcome (Desktop parity): successful
    /// IDs leave the selection; failed IDs remain for retry/correction.
    static func selectionAfterApplying(
        outcome: KanbanBulkOperationOutcome,
        originalSelection: Set<String>
    ) -> Set<String> {
        let failedIDs = Set(outcome.failures.map(\.id))
        return originalSelection.intersection(failedIDs)
    }

    /// All per-ID failure reasons, for the detail disclosure (every reason is
    /// shown, not just the first).
    static func failures(from outcome: KanbanBulkOperationOutcome) -> [KanbanBulkFailure] {
        outcome.failures
    }
}

// MARK: - Bulk Move destinations (V3C)

/// Move destinations reuse the ONE lifecycle policy: the manually selectable
/// statuses (which already exclude locked review/running/scheduled), minus
/// "archived" - Archiving is the dedicated bulk action, never a Move lane.
enum KanbanBulkDestinationPolicy {
    static func moveDestinations() -> [KanbanStatusPresentation] {
        KanbanStatusPresentation.manuallySelectableStatuses.filter { $0.rawValue != "archived" }
    }
}