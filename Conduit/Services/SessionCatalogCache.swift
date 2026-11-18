//
//  SessionCatalogCache.swift
//  Conduit
//
//  The profile-scoped session catalog cache. Moved out of AppState.swift
//  (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

/// Owns the profile-scoped session catalog cache and rejects writes from a
/// load that started before a destructive cache mutation. AppState is
/// main-actor isolated, but every dashboard request can re-enter the actor
/// while it awaits WebKit, so a request must not overwrite a newer purge when
/// it resumes.
struct SessionCatalogCache {
    static let fullHistoryRefreshInterval: TimeInterval = 5 * 60

    private(set) var sessionsByKey: [String: [SessionSummary]] = [:]
    private(set) var loadedFullHistoryKeys = Set<String>()
    private(set) var fullHistoryLoadedAt: [String: Date] = [:]
    private(set) var mutationGeneration: UInt64 = 0
    /// Bumped by every committed listing, so an early chat-list answer
    /// isn't taken over a newer one another load committed meanwhile.
    private(set) var commits: UInt64 = 0
    /// The newest read (in the order reads started) whose listing each
    /// key holds, so an older read that ends later never writes over it
    /// (issue 2293).
    private(set) var committedReads: [String: ReadOrder] = [:]

    /// Where a read's listing stands among the others: by the read whose
    /// newest page it holds (`rowsFrom`), then by whether it fetched cron
    /// itself, then by the read. Reads that took one newest page
    /// (NewestCatalogPageRead, issue 2604) hold rows of the same age; of
    /// those, one that fetched cron keeps its commit over one that reused
    /// cached cron or whose cron request failed, and of two that fetched,
    /// the one that started later does (#2753 review).
    struct ReadOrder: Comparable {
        let rowsFrom: UInt64
        let freshCron: Bool
        let read: UInt64

        init(rowsFrom: UInt64, freshCron: Bool = true, read: UInt64) {
            self.rowsFrom = rowsFrom
            self.freshCron = freshCron
            self.read = read
        }

        /// A read that sent its own requests.
        init(_ read: UInt64) {
            self.init(rowsFrom: read, read: read)
        }

        static func < (lhs: ReadOrder, rhs: ReadOrder) -> Bool {
            if lhs.rowsFrom != rhs.rowsFrom { return lhs.rowsFrom < rhs.rowsFrom }
            if lhs.freshCron != rhs.freshCron { return !lhs.freshCron }
            return lhs.read < rhs.read
        }
    }

    func sessions(forKey key: String) -> [SessionSummary] {
        sessionsByKey[key] ?? []
    }

    func cachedSessions(forKey key: String) -> [SessionSummary]? {
        sessionsByKey[key]
    }

    /// Returns cached rows to merge unless the dashboard supplied a meaningful
    /// authoritative replacement. An empty response is not safe evidence that
    /// a populated catalog was deleted: it can also represent a transient,
    /// malformed, or profile-mismatched response.
    func cachedSessionsToMerge(
        remoteSessions: [SessionSummary],
        isAuthoritative: Bool,
        forKey key: String
    ) -> [SessionSummary] {
        if isAuthoritative && !remoteSessions.isEmpty {
            return []
        }
        return sessions(forKey: key)
    }

    func shouldLoadFullHistory(
        forKey key: String,
        forceRefresh: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !forceRefresh,
              loadedFullHistoryKeys.contains(key),
              let loadedAt = fullHistoryLoadedAt[key] else {
            return true
        }
        return now.timeIntervalSince(loadedAt) >= Self.fullHistoryRefreshInterval
    }

    static let maximumHistoryPages = 25

    /// Pages the dashboard list reads before it returns. A chat sync needs
    /// only the newest page to pick and resume a chat (a saved chat older
    /// than that page resumes directly), so it leaves a due full read for
    /// after the chat is ready instead of waiting on every page (#417).
    static func pageBudget(fullHistoryDue: Bool, deferringOlderPages: Bool) -> Int {
        fullHistoryDue && !deferringOlderPages ? maximumHistoryPages : 1
    }

    /// Whether a read that started after `read` already committed `key`'s
    /// listing: its rows are newer than any this read could write.
    func hasNewerCommit(than read: UInt64, forKey key: String) -> Bool {
        hasNewerCommit(than: ReadOrder(read), forKey: key)
    }

    func hasNewerCommit(than order: ReadOrder, forKey key: String) -> Bool {
        committedReads[key].map { $0 > order } ?? false
    }

    /// Commits a live and cron snapshot only when no cache mutation occurred
    /// during the load that produced it. `read` numbers the load in the
    /// order loads started; check `hasNewerCommit(than:forKey:)` first.
    @discardableResult
    mutating func commit(
        liveSessions: [SessionSummary],
        liveKey: String,
        cronSessions: [SessionSummary]?,
        cronKey: String,
        historyMarkers: [String: Date],
        at generation: UInt64,
        read: UInt64? = nil,
        order: ReadOrder? = nil
    ) -> Bool {
        guard generation == mutationGeneration else { return false }
        commits &+= 1
        if let order = order ?? read.map({ ReadOrder($0) }) {
            committedReads[liveKey] = committedReads[liveKey].map { max($0, order) } ?? order
        }
        sessionsByKey[liveKey] = liveSessions
        if let cronSessions {
            sessionsByKey[cronKey] = cronSessions
        }
        for (key, loadedAt) in historyMarkers {
            loadedFullHistoryKeys.insert(key)
            fullHistoryLoadedAt[key] = loadedAt
        }
        return true
    }

    mutating func removeAll() {
        mutationGeneration &+= 1
        sessionsByKey.removeAll()
        // Nothing newer is held, so a read in flight reads again.
        committedReads.removeAll()
        loadedFullHistoryKeys.removeAll()
        fullHistoryLoadedAt.removeAll()
    }

    mutating func removeValue(forKey key: String) {
        mutationGeneration &+= 1
        sessionsByKey.removeValue(forKey: key)
        committedReads.removeValue(forKey: key)
        loadedFullHistoryKeys.remove(key)
        fullHistoryLoadedAt.removeValue(forKey: key)
    }

    mutating func removeSession(withIDs sessionIDs: Set<String>) {
        mutationGeneration &+= 1
        for key in sessionsByKey.keys {
            sessionsByKey[key]?.removeAll { cachedSession in
                let cachedIDs = Set([cachedSession.id] + cachedSession.alternateIds)
                return !cachedIDs.isDisjoint(with: sessionIDs)
            }
        }
    }
}
