import XCTest
@testable import Conduit

/// The plugin's history page (#1525): what Conduit asks for, and that what it
/// puts together is Hermes' page row for row.
final class HistoryPageTests: XCTestCase {
    func testTheBodyCarriesTheTailQuery() throws {
        let body = try XCTUnwrap(HistoryPage.body(
            sessionId: "s1",
            query: PersistedTranscriptPagination.tailQuery(offset: 0),
            known: ["a", "b"]
        ))
        XCTAssertEqual(body["session_id"] as? String, "s1")
        XCTAssertEqual(body["limit"] as? Int, PersistedTranscriptPagination.pageSize)
        XCTAssertEqual(body["offset"] as? Int, 0)
        XCTAssertEqual(body["order"] as? String, "latest")
        XCTAssertEqual(body["include_compacted"] as? Bool, true)
        XCTAssertEqual(body["inline_images"] as? Bool, false)
        XCTAssertEqual(body["known"] as? [String], ["a", "b"])
    }

    func testTheLegacyReadGoesToHermesRoute() {
        XCTAssertNil(HistoryPage.body(sessionId: "s1", query: PersistedTranscriptPagination.legacyQuery, known: []))
    }

    func testHeldRowsGoBackInPlace() throws {
        let response: [String: Any] = [
            "session_id": "stored-s1",
            "messages": [["conduit_known": "a"], ["id": 3, "content": "new"] as [String: Any]],
            "row_digests": ["a", "c"],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2] as [String: Any],
        ]
        let held: [String: Any] = ["a": ["id": 1, "content": "old"] as [String: Any]]
        let rebuilt = try XCTUnwrap(HistoryPage.rebuild(response, held: held, sessionID: "s1"))
        let rows = try XCTUnwrap(rebuilt.page["messages"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? Int }, [1, 3])
        XCTAssertNil(rebuilt.page["row_digests"], "The page reads as Hermes' answer")
        XCTAssertEqual(rebuilt.page["session_id"] as? String, "stored-s1")
        XCTAssertNotNil(rebuilt.page["pagination"])
        XCTAssertEqual(rebuilt.kept.digests, ["a", "c"])
        XCTAssertEqual(rebuilt.kept.sessionID, "s1")
    }

    func testAFingerprintThePhoneDoesNotHoldReadsHermesRoute() {
        let response: [String: Any] = ["messages": [["conduit_known": "z"]], "row_digests": ["z"]]
        XCTAssertNil(HistoryPage.rebuild(response, held: [:], sessionID: "s1"))
        let mismatched: [String: Any] = ["messages": [["id": 1]], "row_digests": []]
        XCTAssertNil(HistoryPage.rebuild(mismatched, held: [:], sessionID: "s1"))
    }

    func testOnlyTheRouteRefusingReadsHermesRouteInstead() {
        XCTAssertTrue(HistoryPage.readsHermesRouteInstead(after: DashboardTicketBridgeError.http(status: 404, detail: "")))
        XCTAssertTrue(HistoryPage.readsHermesRouteInstead(after: DashboardTicketBridgeError.http(status: 501, detail: "")))
        XCTAssertTrue(HistoryPage.readsHermesRouteInstead(after: DashboardTicketBridgeError.http(status: 500, detail: "")))
        XCTAssertFalse(HistoryPage.readsHermesRouteInstead(after: DashboardTicketBridgeError.http(status: 0, detail: "")))
        XCTAssertFalse(HistoryPage.readsHermesRouteInstead(after: DashboardTicketBridgeError.http(status: 504, detail: "")))
        XCTAssertFalse(HistoryPage.readsHermesRouteInstead(after: DashboardTicketBridgeError.notReady))
    }

    func testOnlyAHostThatCantServeTheRouteIsLeftForTheRun() {
        XCTAssertTrue(HistoryPage.isRefusedForScope(DashboardTicketBridgeError.http(status: 501, detail: "")))
        XCTAssertFalse(HistoryPage.isRefusedForScope(DashboardTicketBridgeError.http(status: 403, detail: "")),
                       "An auth proxy's 403 for a lapsed sign-in isn't the route refusing")
        XCTAssertFalse(HistoryPage.isRefusedForScope(DashboardTicketBridgeError.http(status: 404, detail: "")),
                       "Hermes' own missing chat passes through as a 404")
        XCTAssertFalse(HistoryPage.isRefusedForScope(DashboardTicketBridgeError.http(status: 0, detail: "")))
    }
}
