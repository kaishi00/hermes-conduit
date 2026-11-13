import XCTest
@testable import Conduit

final class SessionCatalogCacheTests: XCTestCase {
    func testRejectsStaleCommitAfterSessionRemoval() {
        var cache = SessionCatalogCache()
        let deleted = session(id: "deleted-session", title: "Deleted")
        let loadGeneration = cache.mutationGeneration

        XCTAssertTrue(
            cache.commit(
                liveSessions: [deleted],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": Date(timeIntervalSince1970: 100)],
                at: loadGeneration
            )
        )

        cache.removeSession(withIDs: [deleted.id])

        XCTAssertFalse(
            cache.commit(
                liveSessions: [deleted],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": Date(timeIntervalSince1970: 100)],
                at: loadGeneration
            )
        )
        XCTAssertTrue(cache.sessions(forKey: "default:exclude").isEmpty)
    }

    /// A read that started later and committed first keeps its rows: the
    /// older one is told so before it writes, and a purge forgets it, so a
    /// read in flight then reads again (issue 2293).
    func testANewerCommittedReadIsNotOverwrittenByAnOlderOne() {
        var cache = SessionCatalogCache()
        let generation = cache.mutationGeneration
        XCTAssertFalse(cache.hasNewerCommit(than: 1, forKey: "default:exclude"))
        XCTAssertTrue(cache.commit(
            liveSessions: [session(id: "renamed", title: "New name")], liveKey: "default:exclude",
            cronSessions: nil, cronKey: "default:cron",
            historyMarkers: [:], at: generation, read: 2
        ))
        XCTAssertTrue(cache.hasNewerCommit(than: 1, forKey: "default:exclude"), "the older read yields")
        XCTAssertFalse(cache.hasNewerCommit(than: 2, forKey: "default:exclude"))
        XCTAssertFalse(cache.hasNewerCommit(than: 3, forKey: "default:exclude"))
        XCTAssertFalse(cache.hasNewerCommit(than: 1, forKey: "analyst:exclude"), "per profile")

        cache.removeAll()
        XCTAssertFalse(cache.hasNewerCommit(than: 1, forKey: "default:exclude"), "a purge holds nothing newer")
    }

    /// What a connection's early chat-list read is fenced on: a removal
    /// moves the generation, a committed listing moves the commit count,
    /// and a refused commit moves neither.
    func testRemovalsAndCommittedListingsMoveTheStartupFence() {
        var cache = SessionCatalogCache()
        let start = (cache.mutationGeneration, cache.commits)
        let listed = session(id: "listed", title: "Listed")

        XCTAssertTrue(cache.commit(
            liveSessions: [listed], liveKey: "default:exclude",
            cronSessions: nil, cronKey: "default:cron",
            historyMarkers: [:], at: start.0
        ))
        XCTAssertEqual(cache.commits, start.1 &+ 1)

        cache.removeSession(withIDs: [listed.id])
        XCTAssertNotEqual(cache.mutationGeneration, start.0)

        XCTAssertFalse(cache.commit(
            liveSessions: [listed], liveKey: "default:exclude",
            cronSessions: nil, cronKey: "default:cron",
            historyMarkers: [:], at: start.0
        ))
        XCTAssertEqual(cache.commits, start.1 &+ 1, "a refused commit isn't a listing")

        let generation = cache.mutationGeneration
        cache.removeValue(forKey: "default:exclude")
        XCTAssertNotEqual(cache.mutationGeneration, generation)
        let afterValue = cache.mutationGeneration
        cache.removeAll()
        XCTAssertNotEqual(cache.mutationGeneration, afterValue)
    }

    func testRemoveSessionPurgesMatchingAlternateID() {
        var cache = SessionCatalogCache()
        let session = session(
            id: "runtime-id",
            alternateIds: ["stored-id"],
            title: "Conversation"
        )
        let generation = cache.mutationGeneration

        XCTAssertTrue(
            cache.commit(
                liveSessions: [session],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": Date(timeIntervalSince1970: 100)],
                at: generation
            )
        )

        cache.removeSession(withIDs: ["stored-id"])

        XCTAssertTrue(cache.sessions(forKey: "default:exclude").isEmpty)
    }

    func testRemoveAllClearsCatalogAndHistoryMarker() {
        var cache = SessionCatalogCache()
        let session = session(id: "stored-id", title: "Conversation")

        XCTAssertTrue(
            cache.commit(
                liveSessions: [session],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": Date(timeIntervalSince1970: 100)],
                at: cache.mutationGeneration
            )
        )

        cache.removeAll()

        XCTAssertTrue(cache.sessions(forKey: "default:exclude").isEmpty)
        XCTAssertTrue(cache.loadedFullHistoryKeys.isEmpty)
        XCTAssertTrue(cache.fullHistoryLoadedAt.isEmpty)
    }

    func testAuthoritativeCommitEvictsSessionOmittedByRemoteCatalog() {
        var cache = SessionCatalogCache()
        let retained = session(id: "retained-id", title: "Retained")
        let deletedRemotely = session(id: "deleted-id", title: "Deleted remotely")

        XCTAssertTrue(
            cache.commit(
                liveSessions: [retained, deletedRemotely],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": Date(timeIntervalSince1970: 100)],
                at: cache.mutationGeneration
            )
        )
        XCTAssertTrue(
            cache.commit(
                liveSessions: [retained],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": Date(timeIntervalSince1970: 200)],
                at: cache.mutationGeneration
            )
        )

        XCTAssertEqual(cache.sessions(forKey: "default:exclude"), [retained])
    }

    func testEmptyRemoteCatalogPreservesCachedRowsForLiveMerge() {
        var cache = SessionCatalogCache()
        let cached = session(id: "cached-id", title: "Cached")

        XCTAssertTrue(
            cache.commit(
                liveSessions: [cached],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": Date(timeIntervalSince1970: 100)],
                at: cache.mutationGeneration
            )
        )

        XCTAssertEqual(
            cache.cachedSessionsToMerge(
                remoteSessions: [],
                isAuthoritative: true,
                forKey: "default:exclude"
            ),
            [cached]
        )
    }

    func testFailedCronFetchDoesNotPoisonTheCronCache() {
        var cache = SessionCatalogCache()
        let live = session(id: "live-id", title: "Live")

        XCTAssertTrue(
            cache.commit(
                liveSessions: [live],
                liveKey: "default:exclude",
                cronSessions: nil,
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": Date(timeIntervalSince1970: 100)],
                at: cache.mutationGeneration
            )
        )

        XCTAssertNil(cache.cachedSessions(forKey: "default:cron"))
        XCTAssertEqual(cache.sessions(forKey: "default:exclude"), [live])
    }

    func testFullHistoryRefreshesAfterCacheLifetime() {
        var cache = SessionCatalogCache()
        let loadedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            cache.commit(
                liveSessions: [session(id: "stored-id", title: "Conversation")],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: ["default:exclude": loadedAt],
                at: cache.mutationGeneration
            )
        )

        XCTAssertFalse(
            cache.shouldLoadFullHistory(
                forKey: "default:exclude",
                forceRefresh: false,
                now: loadedAt.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            cache.shouldLoadFullHistory(
                forKey: "default:exclude",
                forceRefresh: false,
                now: loadedAt.addingTimeInterval(SessionCatalogCache.fullHistoryRefreshInterval + 1)
            )
        )
    }

    func testChatSyncReadsOnlyTheNewestPageWhenAFullReadIsDue() {
        XCTAssertEqual(
            SessionCatalogCache.pageBudget(fullHistoryDue: true, deferringOlderPages: true),
            1
        )
        XCTAssertEqual(
            SessionCatalogCache.pageBudget(fullHistoryDue: true, deferringOlderPages: false),
            SessionCatalogCache.maximumHistoryPages
        )
        XCTAssertEqual(
            SessionCatalogCache.pageBudget(fullHistoryDue: false, deferringOlderPages: false),
            1
        )
        XCTAssertEqual(
            SessionCatalogCache.pageBudget(fullHistoryDue: false, deferringOlderPages: true),
            1
        )
    }

    func testNewestPageAloneLeavesTheFullReadDue() {
        var cache = SessionCatalogCache()
        let loadedAt = Date(timeIntervalSince1970: 100)

        // A non-terminal newest page commits without a history marker.
        XCTAssertTrue(
            cache.commit(
                liveSessions: [session(id: "newest", title: "Newest")],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                historyMarkers: [:],
                at: cache.mutationGeneration
            )
        )

        XCTAssertTrue(
            cache.shouldLoadFullHistory(
                forKey: "default:exclude",
                forceRefresh: false,
                now: loadedAt
            )
        )
    }

    func testCronHistoryRefreshesAfterCacheLifetime() {
        var cache = SessionCatalogCache()
        let loadedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            cache.commit(
                liveSessions: [],
                liveKey: "default:exclude",
                cronSessions: [session(id: "cron-id", title: "Cron")],
                cronKey: "default:cron",
                historyMarkers: ["default:cron": loadedAt],
                at: cache.mutationGeneration
            )
        )

        XCTAssertFalse(
            cache.shouldLoadFullHistory(
                forKey: "default:cron",
                forceRefresh: false,
                now: loadedAt.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            cache.shouldLoadFullHistory(
                forKey: "default:cron",
                forceRefresh: false,
                now: loadedAt.addingTimeInterval(SessionCatalogCache.fullHistoryRefreshInterval + 1)
            )
        )
    }

    private func session(
        id: String,
        alternateIds: [String] = [],
        title: String
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternateIds,
            title: title,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    /// Deleting or archiving a chat drops the kept call archives that list
    /// it and keeps the rest, other profiles' included (issue 2375).
    @MainActor
    func testDeletingAChatDropsOnlyTheKeptCallArchivesThatListIt() throws {
        let suite = "ArchivedCallsDelete.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.archivedCallsReads = [
            "default": ArchivedCallsRead(calls: [session(id: "call-1", alternateIds: ["stored-call-1"], title: "Call")],
                                         liveTotal: 4, tags: 1, readAt: Date()),
            "work": ArchivedCallsRead(calls: [session(id: "call-2", title: "Other call")], liveTotal: 2, tags: 1, readAt: Date())
        ]

        appState.removeSessionFromLiveCatalog(session(id: "stored-call-1", title: "Call"))

        XCTAssertEqual(Set(appState.archivedCallsReads.keys), ["work"])
    }

    /// The archived calls read for a catalog read serve the next ones
    /// while fresh and no call was tagged since (issue 2357); the live
    /// list's total is compared once it's read.
    func testArchivedCallsServeAgainOnlyWhileFreshAndUntagged() {
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)
        let read = ArchivedCallsRead(calls: [], liveTotal: 40, tags: 3, readAt: readAt)
        XCTAssertTrue(read.servesAgain(tags: 3, now: readAt.addingTimeInterval(60)))
        XCTAssertFalse(read.servesAgain(tags: 4, now: readAt.addingTimeInterval(60)), "a call tagged since")
        XCTAssertFalse(read.servesAgain(tags: 3, now: readAt.addingTimeInterval(ArchivedCallsRead.lifetime)), "too old")
        XCTAssertFalse(read.servesAgain(tags: 3, now: readAt.addingTimeInterval(-1)), "a clock set back")
        XCTAssertNotEqual(ArchivedCallsRead.key(dashboard: nil, profile: "Work", pages: 1),
                          ArchivedCallsRead.key(dashboard: nil, profile: "work", pages: 25),
                          "a full-history read keeps its own")
    }
}
