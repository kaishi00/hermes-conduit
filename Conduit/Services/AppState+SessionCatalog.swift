//
//  AppState+SessionCatalog.swift
//  Conduit
//
//  Reading the session catalog: deferred catalog pages, a profile's
//  sessions, archived and cron sessions, and which profile a session
//  belongs to. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Reading the session catalog

    /// Reads the older pages a chat sync left out, after it. Quiet on
    /// failure: the drawer keeps the newest page, and the next list load
    /// tries the full read again.
    func loadDeferredCatalogPages(after client: HermesClient, profile: String, dashboardID: UUID?) {
        Task { @MainActor [weak self] in
            // A sync abandoned for another profile or dashboard leaves the
            // read to that workspace's own sync.
            guard let self, self.client === client,
                  self.activeProfile == profile,
                  self.activeDashboardID == dashboardID else { return }
            await self.loadSessions(
                forceRefresh: false,
                requiredViewportTransitionGeneration: nil,
                reportsFailure: false,
                yieldsToNewerReads: true
            )
        }
    }

    /// The dashboard endpoint is authoritative. `session.list` is only a
    /// legacy fallback because it is backed by the gateway's current runtime
    /// database and can otherwise leak or omit profile history.
    func profileCatalog(
        using client: HermesClient,
        forceRefresh: Bool = false,
        deferringOlderPages: Bool = false,
        yieldsToNewerReads: Bool = false
    ) async throws -> ProfileCatalogLoad {
        catalogReadSequence &+= 1
        let readSequence = catalogReadSequence
        if let loadCatalog = chatResumeLifecycleOperations.loadCatalog {
            return ProfileCatalogLoad(
                sessions: try await loadCatalog(client, forceRefresh),
                olderPagesDeferred: false
            )
        }
        let profile = activeProfile
        if let dashboardTicketBridge {
            do {
                let cacheKey = "\(profile):exclude"
                let cronKey = "\(profile):cron"
                let maximumCatalogRetries = 3
                var catalogRetryCount = 0
                while true {
                    let generation = sessionCatalogCache.mutationGeneration
                    let shouldLoadHistory = sessionCatalogCache.shouldLoadFullHistory(
                        forKey: cacheKey,
                        forceRefresh: forceRefresh
                    )
                    // Cron sessions come from a separate request (the main
                    // query excludes them). Decide now and send it alongside
                    // the live list rather than after it (#417): the two are
                    // independent, and every round trip counts on a slow link.
                    // The commit below still rejects the pair if the cache
                    // changed while either was in flight.
                    let reusesCachedCron = !sessionCatalogCache.shouldLoadFullHistory(
                        forKey: cronKey,
                        forceRefresh: forceRefresh
                    ) && sessionCatalogCache.cachedSessions(forKey: cronKey) != nil
                    async let cronFetch: [SessionSummary]? = reusesCachedCron
                        ? nil
                        : timedCronCatalogFetch(profile: profile, using: dashboardTicketBridge)
                    let liveStartedAt = Date()
                    let scopedResult: DashboardSessionCatalog
                    do {
                        scopedResult = try await dashboardSessions(
                            profile: profile,
                            maximumPages: SessionCatalogCache.pageBudget(
                                fullHistoryDue: shouldLoadHistory,
                                deferringOlderPages: deferringOlderPages
                            ),
                            using: dashboardTicketBridge
                        )
                    } catch {
                        noteConnectionStep("Chat list", since: liveStartedAt, error: error)
                        throw error
                    }
                    let scoped = scopedResult.sessions.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    let olderPagesDeferred = shouldLoadHistory
                        && deferringOlderPages
                        && !scopedResult.isAuthoritative
                    noteConnectionStep(
                        olderPagesDeferred
                            ? "Chat list, newest \(scoped.count) rows"
                            : "Chat list, \(scoped.count) rows",
                        since: liveStartedAt
                    )

                    let cached = sessionCatalogCache.cachedSessionsToMerge(
                        remoteSessions: scoped,
                        isAuthoritative: scopedResult.isAuthoritative,
                        forKey: cacheKey
                    ).filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    let merged = uniqueSessions(scoped + cached)

                    let fetchedCronSessions = await cronFetch
                    let cachedCronSessions = sessionCatalogCache.cachedSessions(forKey: cronKey)?.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    let publishedCronSnapshot = self.cronSessions.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    var didFetchCronSessions = false
                    let cronSessions: [SessionSummary]?
                    if reusesCachedCron, let cachedCronSessions {
                        cronSessions = cachedCronSessions
                    } else if let fetchedCronSessions {
                        cronSessions = fetchedCronSessions
                        didFetchCronSessions = true
                    } else {
                        // Keep a previous cron snapshot if one exists, but
                        // do not cache an empty result for a failed request.
                        cronSessions = nil
                    }

                    // A delete/archive/disconnect can run while either request
                    // is suspended. Never let this attempt overwrite the
                    // newer cache state; retry from the authoritative source.
                    guard profile == activeProfile,
                          self.dashboardTicketBridge === dashboardTicketBridge,
                          self.client === client else {
                        throw DashboardTicketBridgeError.notReady
                    }
                    // Up to 25 pages take a while: a read started meanwhile
                    // saw newer rows, so this one must not land after it.
                    if yieldsToNewerReads, readSequence != catalogReadSequence {
                        throw CatalogReadSuperseded()
                    }
                    // Nor does any read write over the cached rows of one
                    // that started after it and already committed: a host
                    // delete or rename that one saw would come back (issue
                    // 2293). It answers with those newer rows instead (a
                    // chat sync still picks its chat from them).
                    if sessionCatalogCache.hasNewerCommit(than: readSequence, forKey: cacheKey) {
                        return ProfileCatalogLoad(
                            sessions: sessionCatalogCache.sessions(forKey: cacheKey).filter {
                                sessionBelongsToProfile($0, profile: profile)
                            },
                            olderPagesDeferred: false
                        )
                    }

                    let combined = uniqueSessions(
                        merged + (cronSessions ?? cachedCronSessions ?? publishedCronSnapshot)
                    )
                    if !combined.isEmpty || shouldLoadHistory == false {
                        var historyMarkers: [String: Date] = [:]
                        if scopedResult.isAuthoritative && !scoped.isEmpty {
                            historyMarkers[cacheKey] = Date()
                        }
                        if didFetchCronSessions {
                            historyMarkers[cronKey] = Date()
                        }
                        guard sessionCatalogCache.commit(
                            liveSessions: combined,
                            liveKey: cacheKey,
                            cronSessions: cronSessions,
                            cronKey: cronKey,
                            historyMarkers: historyMarkers,
                            at: generation,
                            read: readSequence
                        ) else {
                            catalogRetryCount += 1
                            guard catalogRetryCount < maximumCatalogRetries else {
                                sessionCatalogLog.warning(
                                    "Dashboard catalog mutation retry budget exhausted for \(profile, privacy: .public); using gateway fallback."
                                )
                                break
                            }
                            continue
                        }
                        sessionCatalogLog.notice("Dashboard catalog for \(profile, privacy: .public): \(combined.count, privacy: .public) sessions; \(self.sourceSummary(combined), privacy: .public)")
                        // Only rows fetched just now carry the host's current
                        // pin flags; cached ones may predate a change.
                        applyHostPins(scoped + (fetchedCronSessions ?? []), profile: profile, using: dashboardTicketBridge)
                        return ProfileCatalogLoad(
                            sessions: combined,
                            // A newest page that turned out to be the whole
                            // list is authoritative and already marked loaded.
                            olderPagesDeferred: olderPagesDeferred
                        )
                    }
                    break
                }
            } catch {
                guard profile == activeProfile,
                      self.dashboardTicketBridge === dashboardTicketBridge,
                      self.client === client else {
                    throw DashboardTicketBridgeError.notReady
                }
                // The deferred read only tops up a list the dashboard already
                // gave; the gateway's list must not replace it.
                if yieldsToNewerReads { throw error }
                sessionCatalogLog.error("Dashboard history failed; using gateway fallback: \(LogRedaction.message(error), privacy: .public)")
                // Keep older dashboard installations usable; the gateway is
                // still an authoritative fallback when the history endpoint is
                // unavailable.
            }
        }
        // A retry budget or an empty page can also land here. The deferred
        // read only tops up the dashboard's list, so it never takes the
        // gateway's instead.
        if yieldsToNewerReads {
            throw CatalogReadSuperseded()
        }
        let fallbackStartedAt = Date()
        do {
            let fallbackSessions = try await client.sessions().filter {
                sessionBelongsToProfile($0, profile: profile) && $0.messageCount != 0
            }
            noteConnectionStep(
                "Chat list from the gateway, \(fallbackSessions.count) rows",
                since: fallbackStartedAt
            )
            return ProfileCatalogLoad(sessions: fallbackSessions, olderPagesDeferred: false)
        } catch {
            noteConnectionStep("Chat list from the gateway", since: fallbackStartedAt, error: error)
            throw error
        }
    }

    /// The cron half of the catalog, run concurrently with the live list,
    /// already scoped to `profile`. A failure is nil, never an empty list: the
    /// caller keeps the previous cron snapshot rather than caching "no cron
    /// runs".
    ///
    /// Both requests share one dashboard page, so they share its fate: a
    /// request that stalls the page fails the other one too, and the live list
    /// then takes the gateway fallback. They start together with the same
    /// deadline, so a cron stall can only catch a live request that is about
    /// to time out anyway.
    private func timedCronCatalogFetch(
        profile: String,
        using bridge: DashboardTicketBridge
    ) async -> [SessionSummary]? {
        let startedAt = Date()
        do {
            let sessions = try await dashboardCronSessions(profile: profile, using: bridge).filter {
                sessionBelongsToProfile($0, profile: profile)
            }
            noteConnectionStep("Cron runs, \(sessions.count) rows", since: startedAt)
            return sessions
        } catch {
            // Cancelled because the live list failed (leaving the scope
            // cancels this child) or the whole sync was abandoned. That is
            // not a cron failure, so the timeline doesn't list it as one.
            if !(error is CancellationError) && !Task.isCancelled {
                noteConnectionStep("Cron runs", since: startedAt, error: error)
            }
            return nil
        }
    }

    /// A profile-scoped request may still return rows from another profile on
    /// older dashboards. Never let an explicitly tagged foreign session enter
    /// this profile's catalog or become selectable through its socket.
    func sessionBelongsToProfile(_ session: SessionSummary, profile: String) -> Bool {
        guard let owner = session.profile,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return profilesMatch(owner, profile)
    }

    func profilesMatch(_ lhs: String, _ rhs: String) -> Bool {
        Self.profilesMatch(lhs, rhs)
    }

    nonisolated static func profilesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func dashboardSessions(
        profile: String,
        maximumPages: Int,
        using bridge: DashboardTicketBridge
    ) async throws -> DashboardSessionCatalog {
        var sessions: [SessionSummary] = []
        var isAuthoritative = false
        // Sent alongside the live list: the plugin archives a standalone
        // call when it ends, which Conduit still lists with its calls. The
        // archived pages read last time serve again (issue 2357) while
        // they're under 5 minutes old, no call was tagged since, and the
        // live list holds as many chats as then: a call archived meanwhile
        // leaves it, so its total moves and they're read again.
        let callsKey = ArchivedCallsRead.key(dashboard: activeDashboardID, profile: profile, pages: maximumPages)
        let tagCount = voiceSessionTagsByKey[voiceHistoryKey(profile: profile)]?.count ?? 0
        let kept = archivedCallsReads[callsKey].flatMap {
            $0.servesAgain(tags: tagCount, now: Date()) ? $0 : nil
        }
        let archivedRead: Task<[SessionSummary]?, Never>? = kept != nil ? nil : Task { [weak self] in
            await self?.archivedVoiceCallSessions(profile: profile, maximumPages: maximumPages, using: bridge)
        }
        defer { archivedRead?.cancel() }
        var liveTotal: Int?

        for page in 0..<maximumPages {
            let offset = page * 200
            let response = try await startupReads.read(
                profileSessionsPath(profile, offset: offset),
                through: bridge,
                fence: startupReadFence(for: bridge, chatList: true)
            )
            let batch = response["sessions"] as? [Any] ?? []
            let normalizedBatch = await dashboardOwnedSessions(batch, profile: profile)
            sessions += normalizedBatch

            let rawHasMore = response["has_more"] ?? response["hasMore"]
            let explicitHasMore = rawHasMore.map { booleanValue($0) }
            let nextOffset = Self.integerValue(response["next_offset"] ?? response["nextOffset"])
            let total = Self.integerValue(response["total"])
            if page == 0 { liveTotal = total }
            let hasExplicitTerminalSignal = explicitHasMore == false
                || (nextOffset.map { $0 <= offset } ?? false)
                || (total.map { offset + batch.count >= $0 } ?? false)
            let hasMore = !hasExplicitTerminalSignal && (
                explicitHasMore == true
                    || (nextOffset ?? 0) > offset
                    || (total.map { offset + batch.count < $0 } ?? false)
                    || batch.count == 200
            )
            if batch.isEmpty {
                // An empty page after a non-empty prefix is not proof that
                // the full catalog was read. Preserve older rows and retry a
                // complete load later instead of evicting the cached suffix.
                break
            }
            if !hasMore {
                isAuthoritative = hasExplicitTerminalSignal && !normalizedBatch.isEmpty
                break
            }
        }

        // A failed read keeps the call rows the list showed before, so the
        // live list's authority doesn't hang on this one.
        let tags = voiceSessionTagsByKey[voiceHistoryKey(profile: profile)] ?? [:]
        let listedIDs = Set(sessions.map(\.id))
        var archivedCalls: [SessionSummary]?
        if let kept, let liveTotal, kept.liveTotal == liveTotal {
            archivedCalls = kept.calls
        } else {
            if let archivedRead {
                archivedCalls = await archivedRead.value
            } else {
                // Kept, but the live list moved (or says no total): read now.
                archivedCalls = await archivedVoiceCallSessions(profile: profile, maximumPages: maximumPages, using: bridge)
            }
            if let archivedCalls, let liveTotal {
                archivedCallsReads[callsKey] = ArchivedCallsRead(
                    calls: archivedCalls, liveTotal: liveTotal, tags: tagCount, readAt: Date()
                )
            } else {
                archivedCallsReads[callsKey] = nil
            }
        }
        let calls = archivedCalls ?? (self.sessions + self.cronSessions).filter {
            var archived = $0
            archived.isArchived = true
            return Self.isArchivedVoiceChat(archived, tags: tags) && sessionBelongsToProfile($0, profile: profile)
                && !listedIDs.contains($0.id)  // used since: the live read has it fresh
        }
        return DashboardSessionCatalog(
            sessions: V2FilterSelection.mergedByRecency(sessions, calls),
            isAuthoritative: isAuthoritative
        )
    }

    /// What a saved call row ends with: the plugin ends the rows it writes.
    nonisolated static let voiceCallEndReason = "conduit_voice"

    /// A call row, a chat a Classic voice call started, or a voice job's
    /// chat, archived by the plugin when the call ended or once Hermes
    /// answered the job (#1124): Hermes Desktop's list leaves it out,
    /// Conduit keeps listing it with its calls. One the user archived, or
    /// one used since, isn't one.
    nonisolated static func isArchivedVoiceChat(_ session: SessionSummary, tags: [String: VoiceSessionTag]) -> Bool {
        guard session.isArchived, session.isAutoArchived == true else { return false }
        if session.endReason == voiceCallEndReason { return true }
        let ids = [session.id, session.storedSessionId].compactMap { $0 } + session.alternateIds
        return ids.contains { id in tags[id].map { $0.kind == .classic || $0.kind == .job } ?? false }
    }

    /// The archived pages' voice chats, as deep as the live list reads,
    /// listed as unarchived. Nil when a read failed or wasn't a listing.
    private func archivedVoiceCallSessions(
        profile: String,
        maximumPages: Int,
        using bridge: DashboardTicketBridge
    ) async -> [SessionSummary]? {
        var calls: [SessionSummary] = []
        let tags = voiceSessionTagsByKey[voiceHistoryKey(profile: profile)] ?? [:]
        do {
            for page in 0..<maximumPages {
                let response = try await bridge.requestJSON(path: archivedSessionsPath(profile, offset: page * 200))
                guard let batch = response["sessions"] as? [Any] else { return nil }
                calls += await dashboardOwnedSessions(batch, profile: profile)
                    .filter { Self.isArchivedVoiceChat($0, tags: tags) }
                    .map { session in
                        var listed = session
                        listed.isArchived = false
                        return listed
                    }
                let offset = page * 200
                let nextOffset = Self.integerValue(response["next_offset"] ?? response["nextOffset"])
                let total = Self.integerValue(response["total"])
                let done = (nextOffset.map { $0 <= offset } ?? false) || (total.map { offset + batch.count >= $0 } ?? false)
                let hasMore = !done && (booleanValue(response["has_more"] ?? response["hasMore"]) || batch.count == 200)
                if !hasMore || batch.isEmpty { break }
            }
        } catch {
            return nil
        }
        return calls
    }

    func dashboardArchivedSessions(
        profile: String,
        using bridge: DashboardTicketBridge
    ) async throws -> [SessionSummary] {
        var sessions: [SessionSummary] = []
        let tags = voiceSessionTagsByKey[voiceHistoryKey(profile: profile)] ?? [:]
        for page in 0..<SessionCatalogCache.maximumHistoryPages {
            let offset = page * 200
            let response = try await bridge.requestJSON(path: archivedSessionsPath(profile, offset: offset))
            let batch = response["sessions"] as? [Any] ?? []
            // Archived calls are listed with the chats instead.
            sessions += await dashboardOwnedSessions(batch, profile: profile)
                .filter { !Self.isArchivedVoiceChat($0, tags: tags) }

            let nextOffset = Self.integerValue(response["next_offset"] ?? response["nextOffset"])
            let total = Self.integerValue(response["total"])
            let hasMore = booleanValue(response["has_more"] ?? response["hasMore"])
                || (nextOffset ?? 0) > offset
                || (total.map { offset + batch.count < $0 } ?? false)
                || batch.count == 200
            if !hasMore || batch.isEmpty { break }
        }
        return sessions
    }

    func profileSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=exclude&order=recent&exclude_sources=\(SessionSource.chatListExcludedSources)",
            profile: profile
        )
    }

    private func archivedSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=only&order=recent&exclude_sources=\(SessionSource.chatListExcludedSources)",
            profile: profile
        )
    }

    /// Fetch cron sessions separately. The main profileSessionsPath excludes
    /// cron (and Kanban workers), so cron sessions never appear in the normal
    /// dashboard query. This dedicated path uses source=cron to populate
    /// the cron tab in the sidebar.
    private func dashboardCronSessions(
        profile: String,
        using bridge: DashboardTicketBridge
    ) async throws -> [SessionSummary] {
        let response = try await bridge.requestJSON(path: cronSessionsPath(profile, offset: 0))
        let batch = response["sessions"] as? [Any] ?? []
        return await dashboardOwnedSessions(batch, profile: profile)
    }

    /// The official profile-session endpoint always tags every row with its
    /// owning profile. Do not substitute the requested profile here: doing so
    /// can relabel a foreign or malformed aggregate row and leak it into the
    /// selected workspace. The socket fallback remains profile-scoped and may
    /// still supply its known client profile to the normalizer.
    ///
    /// A page is up to 200 rows, and converting it took up to 26 ms on main
    /// at launch, while the Chats list was scrolling: it runs off the main
    /// actor, in order, like large socket frames (`decodeInBackground`).
    private func dashboardOwnedSessions(_ batch: [Any], profile: String) async -> [SessionSummary] {
        await Self.convertDashboardPage(batch, profile: profile)
    }

    /// Nonisolated and async: runs on the generic executor, off main.
    nonisolated private static func convertDashboardPage(_ batch: [Any], profile: String) async -> [SessionSummary] {
        dashboardOwnedSessions(batch, profile: profile)
    }

    nonisolated static func dashboardOwnedSessions(_ batch: [Any], profile: String) -> [SessionSummary] {
        MessageNormalizer.normalizeSessions(
            AnyCodable.from(["sessions": batch]),
            profile: nil
        ).filter { session in
            guard let owner = session.profile else { return false }
            // Hermes Desktop's sidebar uses min_messages=1. Keep the explicit
            // client-side guard as well for older servers that ignore the
            // query parameter; malformed empty shadow rows must not leak into
            // a profile's visible catalog.
            return profilesMatch(owner, profile) && session.messageCount != 0
        }
    }

    private func cronSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=exclude&order=recent&source=cron",
            profile: profile
        )
    }

    /// Hermes Desktop requests only persisted sessions with at least one
    /// message, but keeps a first turn visible while it is still in flight and
    /// the database row has not caught up yet. Retain only that live row; idle
    /// zero-message drafts and malformed profile shadows stay hidden.
    func activeTurnCatalogSession() -> SessionSummary? {
        guard turnState.isRunning, let activeSessionId else { return nil }
        return (sessions + cronSessions).first { session in
            sessionBelongsToProfile(session, profile: activeProfile)
                && (session.id == activeSessionId || session.alternateIds.contains(activeSessionId))
        }
    }

    func uniqueSessions(_ values: [SessionSummary]) -> [SessionSummary] {
        var seen = Set<String>()
        return values.filter { session in
            seen.insert("\(session.profile ?? activeProfile):\(session.id)").inserted
        }
    }

    private func sourceSummary(_ values: [SessionSummary]) -> String {
        Dictionary(grouping: values, by: \.source)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
    }
}

/// The archived pages' calls as last read for a profile (issue 2357), with
/// what they were read under: the live list's total, and how many calls
/// were tagged.
struct ArchivedCallsRead {
    let calls: [SessionSummary]
    let liveTotal: Int
    let tags: Int
    let readAt: Date

    /// How long a read serves the catalog reads after it.
    static let lifetime: TimeInterval = SessionCatalogCache.fullHistoryRefreshInterval

    static func key(dashboard: UUID?, profile: String, pages: Int) -> String {
        "\(dashboard?.uuidString ?? "-")|\(profile.lowercased())|\(pages)"
    }

    /// Whether this read may serve again, before the live list's total is
    /// compared.
    func servesAgain(tags: Int, now: Date) -> Bool {
        self.tags == tags && now.timeIntervalSince(readAt) < Self.lifetime && now >= readAt
    }
}
