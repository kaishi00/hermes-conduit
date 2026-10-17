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
}
