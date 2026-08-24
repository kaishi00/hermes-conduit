import SwiftUI

// MARK: - V3D live-update view glue
//
// Pure helpers for the VIEW layer: how the board view derives its live-stream
// identity, and whether a published invalidation should wake a detail
// surface. The transport itself lives in Services/KanbanEventStream.swift.

enum KanbanLiveUpdateSupport {
    /// The live-stream identity: server identity + configuration generation +
    /// the CONCRETE loaded board slug + the Show-Archived filter (an archived
    /// toggle must restart the stream so event-driven refreshes use the NEW
    /// filter, never a stale captured one). Any change retires the current
    /// socket; the new context starts from ITS OWN authoritative watermark.
    static func streamKey(
        bridgeIdentity: ObjectIdentifier?,
        baseURL: String,
        configurationGeneration: Int,
        loadedBoardSlug: String?,
        includeArchived: Bool
    ) -> String {
        [String(describing: bridgeIdentity), baseURL, String(configurationGeneration), loadedBoardSlug ?? "-", "archived=\(includeArchived)"]
            .joined(separator: "|")
    }

    /// A published invalidation may wake a detail surface only when it was
    /// issued for the CURRENT actionable context and actually touches the
    /// displayed task.
    static func shouldRefreshDetail(
        invalidation: KanbanEventInvalidation?,
        currentStamp: KanbanBoardContextStamp?,
        isSnapshotActionable: Bool,
        displayedTaskID: String?
    ) -> Bool {
        guard let invalidation, let currentStamp, let displayedTaskID, !displayedTaskID.isEmpty else { return false }
        guard isSnapshotActionable, invalidation.context == currentStamp else { return false }
        return invalidation.taskIDs.contains(displayedTaskID)
    }

    /// The initial subscription watermark from the authoritative snapshot:
    /// nil for malformed/missing/negative values (live events unavailable;
    /// polling alone).
    static func initialWatermark(from board: KanbanBoard?) -> Int? {
        guard let value = board?.latestEventID else { return nil }
        return KanbanLiveUpdatePolicy.isValidInitialWatermark(value) ? value : nil
    }
}