import Foundation

/// What a conversation is doing right now, from the gateway's live registry
/// (`session.active_list`), for the chat list's Working / Needs input
/// filters (#454). Hermes Desktop builds its filters from the same rows.
enum SessionLiveStatus: Equatable {
    /// A turn is running.
    case working
    /// A clarify question or approval is waiting on the user.
    case needsInput
}

struct SessionLiveStatusIndex: Equatable {
    /// Every id a live row is known under (runtime and stored) → status.
    private(set) var statusByID: [String: SessionLiveStatus] = [:]

    init() {}

    /// Builds the index from one authoritative `session.active_list`
    /// snapshot. "starting" and "idle" rows are not busy (same rule as
    /// `LiveSessionStatus.isRunning`).
    init(rows: [LiveSessionStatus]) {
        for row in rows {
            let status: SessionLiveStatus
            switch row.status {
            case "waiting": status = .needsInput
            case "working": status = .working
            default: continue
            }
            for id in [row.runtimeSessionId, row.storedSessionId] where !id.isEmpty {
                // needs-input outranks working when two rows share an id.
                if statusByID[id] != .needsInput { statusByID[id] = status }
            }
        }
    }

    func status(for session: SessionSummary) -> SessionLiveStatus? {
        let ids = [session.id, session.storedSessionId, session.lineageRootId].compactMap { $0 } + session.alternateIds
        var found: SessionLiveStatus?
        for id in ids {
            switch statusByID[id] {
            case .needsInput?: return .needsInput
            case .working?: found = .working
            case nil: continue
            }
        }
        return found
    }
}
