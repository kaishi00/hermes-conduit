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

    /// Commits a live and cron snapshot only when no cache mutation occurred
    /// during the load that produced it.
    @discardableResult
    mutating func commit(
        liveSessions: [SessionSummary],
        liveKey: String,
        cronSessions: [SessionSummary]?,
        cronKey: String,
        historyMarkers: [String: Date],
        at generation: UInt64
    ) -> Bool {
        guard generation == mutationGeneration else { return false }
        commits &+= 1
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
        loadedFullHistoryKeys.removeAll()
        fullHistoryLoadedAt.removeAll()
    }

    mutating func removeValue(forKey key: String) {
        mutationGeneration &+= 1
        sessionsByKey.removeValue(forKey: key)
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
