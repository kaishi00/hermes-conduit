//
//  SessionCatalogLoad.swift
//  Conduit
//
//  Whether the Chats list holds the catalog of the dashboard profile on
//  screen. An empty `sessions` array alone can't say "no sessions": it is
//  also what a sign-out leaves, what a fresh sign-in shows while its first
//  catalog read is still on the wire, and what a failed read keeps. Only a
//  catalog Hermes actually answered for this dashboard and profile is "no
//  sessions" when it is empty.
//

import Foundation

/// The dashboard profile a catalog belongs to.
struct SessionCatalogOwner: Equatable {
    let dashboardID: UUID?
    let profile: String
}

enum SessionCatalogLoadPhase: Equatable {
    /// No catalog read has finished for this dashboard profile yet.
    case notLoaded
    /// Hermes answered the catalog; an empty one really is empty.
    case loaded
    /// The last read failed before any catalog arrived (the message says why).
    case failed(String)
}

struct SessionCatalogLoadState: Equatable {
    private(set) var owner: SessionCatalogOwner?
    private(set) var phase: SessionCatalogLoadPhase = .notLoaded

    /// The phase for `owner`: a state recorded for another dashboard or
    /// profile says nothing about this one.
    func phase(for owner: SessionCatalogOwner) -> SessionCatalogLoadPhase {
        self.owner == owner ? phase : .notLoaded
    }

    mutating func markLoaded(_ owner: SessionCatalogOwner) {
        self.owner = owner
        phase = .loaded
    }

    /// A failed read after a catalog already arrived keeps it: its rows
    /// stay listed and the error banner reports the failure.
    mutating func markFailed(_ message: String, owner: SessionCatalogOwner) {
        guard phase(for: owner) != .loaded else { return }
        self.owner = owner
        phase = .failed(message)
    }

    mutating func reset() {
        owner = nil
        phase = .notLoaded
    }
}

/// What the Chats list shows in place of rows.
enum SessionListPlaceholder: Equatable {
    /// Rows (or the saved offline copy) are on screen.
    case none
    /// The catalog hasn't arrived: a sign-in or connection is still reading it.
    case loading
    /// The read failed and nothing was ever listed: say so, offer Try Again.
    case failed(String)
    /// Hermes answered, and nothing matches: "No Sessions" (or the filter's
    /// own empty state).
    case empty

    static func resolve(
        hasRows: Bool,
        hasOfflineCopy: Bool,
        catalogPhase: SessionCatalogLoadPhase,
        isRefreshing: Bool
    ) -> SessionListPlaceholder {
        if hasRows || hasOfflineCopy { return .none }
        switch catalogPhase {
        case .loaded:
            return .empty
        case .failed(let message):
            return isRefreshing ? .loading : .failed(message)
        case .notLoaded:
            return .loading
        }
    }
}
