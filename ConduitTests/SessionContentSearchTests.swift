//
//  SessionContentSearchTests.swift
//  ConduitTests
//
//  The Chats list's full-text search: Hermes' `/api/sessions/search`
//  request and response, the debounce, dropping answers for queries the
//  field has moved past, de-duplication against the list's own title
//  matches, the quiet fallback for a Hermes without the route, and the
//  snippet's match highlighting.
//

import SwiftUI
import XCTest
@testable import Conduit

/// A requester that records each path and answers per path, either at once
/// or when the test releases it (an answer that arrives late).
@MainActor
private final class StubSearchRequester {
    var paths: [String] = []
    var responses: [String: Result<[String: Any], Error>] = [:]
    var fallback: Result<[String: Any], Error> = .success(["results": []])
    /// Paths whose answer waits for `release(_:)`.
    var held: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    func request(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        if held.contains(path) {
            await withCheckedContinuation { waiting[path] = $0 }
        }
        return try (responses[path] ?? fallback).get()
    }

    func isWaiting(_ path: String) -> Bool { waiting[path] != nil }

    func release(_ path: String) {
        held.remove(path)
        waiting.removeValue(forKey: path)?.resume()
    }
}

@MainActor
final class SessionContentSearchTests: XCTestCase {
    private let scope = NSObject()

    private func context(_ stub: StubSearchRequester, profile: String = "default", scope: AnyObject? = nil) -> SessionContentSearchModel.Context {
        SessionContentSearchModel.Context(scope: scope ?? self.scope, profile: profile) { path in
            try await stub.request(path)
        }
    }

    private func path(_ query: String, profile: String = "default") -> String {
        SessionContentSearch.path(query: query, profile: profile)
    }

    private func result(_ id: String, snippet: String = "", title: String? = nil, root: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["session_id": id, "snippet": snippet, "role": "user", "source": "cli", "session_started": 1_800_000_000.0]
        if let title { row["title"] = title }
        if let root { row["lineage_root"] = root }
        return row
    }

    private func session(_ id: String, title: String? = nil, stored: String? = nil, root: String? = nil, archived: Bool = false) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: stored,
            alternateIds: [],
            title: title ?? id,
            model: "Hermes",
            updatedLabel: "",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: archived,
            lineageRootId: root
        )
    }

    /// Lets the model's debounce task start and run to its first await.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - Request

    func testPathCarriesQueryLimitAndNamedProfile() {
        XCTAssertEqual(
            SessionContentSearch.path(query: "recycling pickup", profile: "work"),
            "/api/sessions/search?q=recycling%20pickup&limit=\(SessionContentSearch.resultLimit)&exclude_sources=kanban,oneshot,tool&profile=work"
        )
        XCTAssertEqual(
            SessionContentSearch.path(query: "recycling", profile: "default"),
            "/api/sessions/search?q=recycling&limit=\(SessionContentSearch.resultLimit)&exclude_sources=kanban,oneshot,tool"
        )
    }

    func testQueriesShorterThanTwoCharactersOrWithoutWordsAreNotSearched() {
        XCTAssertNil(SessionContentSearch.searchableQuery(""))
        XCTAssertNil(SessionContentSearch.searchableQuery(" r "))
        XCTAssertNil(SessionContentSearch.searchableQuery("--"))
        XCTAssertEqual(SessionContentSearch.searchableQuery("re"), "re")
        // FTS5 syntax characters become word breaks.
        XCTAssertEqual(SessionContentSearch.searchableQuery("  \"next-door\" bins* "), "next door bins")
    }

    func testShortQueryNeverReachesHermes() async {
        let stub = StubSearchRequester()
        let model = SessionContentSearchModel(debounce: .zero)
        model.update(query: "r", context: context(stub))
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [])
        XCTAssertEqual(model.hits, [])
    }

    func testProfileInUseIsPassedAndAProfileSwitchSearchesAgain() async {
        let stub = StubSearchRequester()
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        model.update(query: "recycling", context: context(stub, profile: "work"))
        await model.waitForPendingSearch()
        model.update(query: "recycling", context: context(stub, profile: "default"))
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [path("recycling", profile: "work"), path("recycling")])
    }

    // MARK: - Response

    func testHitsParseForkAndUpstreamRowsInHermesOrder() {
        let response: [String: Any] = ["results": [
            // The fork: no title, the tip in session_id.
            result("tip-a", snippet: "the >>>recycling<<< bins", root: "root-a"),
            // Upstream: title, last_active, archived.
            ["session_id": "b", "id": "b", "title": "Bins", "snippet": "x", "last_active": 1_800_000_100, "archived": false],
            // A repeated id is one conversation.
            result("tip-a", snippet: "again"),
            // A row without an id can't be opened.
            ["snippet": "orphan"],
        ]]
        let hits = SessionContentSearch.hits(from: response, query: "recycling")
        XCTAssertEqual(hits?.map(\.sessionID), ["tip-a", "b"])
        XCTAssertEqual(hits?.first?.lineageRootID, "root-a")
        XCTAssertEqual(hits?.first?.title, "")
        XCTAssertEqual(hits?.first?.lastActive, 1_800_000_000)
        XCTAssertEqual(hits?.last?.title, "Bins")
        XCTAssertEqual(hits?.last?.lastActive, 1_800_000_100)
    }

    func testABodyThatIsNotASearchResponseHasNoHits() {
        XCTAssertNil(SessionContentSearch.hits(from: ["detail": "Not Found"], query: "x"))
        XCTAssertEqual(SessionContentSearch.hits(from: ["results": []], query: "x"), [])
    }

    /// Searching from the first keystroke, so the list never shows "no
    /// results" while the debounce runs.
    func testAQueryIsSearchingDuringItsDebounce() async {
        let stub = StubSearchRequester()
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .seconds(30))
        model.update(query: "recycling", context: context(stub))
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(stub.paths, [], "Nothing is asked before the debounce ends")
        model.update(query: "", context: context(stub))
        XCTAssertFalse(model.isSearching)
    }

    func testModelPublishesHitsForTheQuery() async {
        let stub = StubSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("s1", snippet: ">>>recycling<<< day")]])
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        model.update(query: "recycling", context: context(stub))
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits.map(\.sessionID), ["s1"])
        XCTAssertEqual(model.resultsQuery, "recycling")
        XCTAssertFalse(model.isSearching)
    }

    // MARK: - Debounce

    func testTypingFastSendsOnlyTheLastQueryAfterTheDebounce() async {
        let stub = StubSearchRequester()
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .milliseconds(80))
        let ctx = context(stub)
        for query in ["re", "rec", "recy", "recycling"] {
            model.update(query: query, context: ctx)
            await settle()
        }
        // Still inside the debounce: nothing sent yet.
        XCTAssertEqual(stub.paths, [])
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [path("recycling")])
    }

    func testTheSameQueryAgainDoesNotSearchAgain() async {
        let stub = StubSearchRequester()
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        let ctx = context(stub)
        model.update(query: "recycling", context: ctx)
        await model.waitForPendingSearch()
        // A redraw, or a trailing space the trim removes.
        model.update(query: "recycling ", context: ctx)
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [path("recycling")])
    }

    func testClearingTheFieldDropsHitsAndThePendingSearch() async {
        let stub = StubSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("s1")]])
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        model.update(query: "recycling", context: context(stub))
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits.count, 1)

        let slow = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .milliseconds(80))
        slow.update(query: "compost", context: context(stub))
        slow.update(query: "", context: context(stub))
        await slow.waitForPendingSearch()
        model.update(query: "", context: context(stub))
        XCTAssertEqual(model.hits, [])
        XCTAssertNil(model.resultsQuery)
        XCTAssertFalse(stub.paths.contains(path("compost")))
    }

    // MARK: - Stale responses

    func testALateAnswerForAQueryTheFieldMovedPastIsDropped() async {
        let stub = StubSearchRequester()
        let first = path("recycling")
        let second = path("compost")
        stub.held = [first]
        stub.responses[first] = .success(["results": [result("old")]])
        stub.responses[second] = .success(["results": [result("new")]])
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        let ctx = context(stub)

        model.update(query: "recycling", context: ctx)
        for _ in 0..<400 where !stub.isWaiting(first) { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(stub.isWaiting(first))
        XCTAssertTrue(model.isSearching)

        model.update(query: "compost", context: ctx)
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits.map(\.sessionID), ["new"])

        // The bridge doesn't cancel a sent request: its answer arrives now.
        stub.release(first)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.hits.map(\.sessionID), ["new"])
        XCTAssertEqual(model.resultsQuery, "compost")
        XCTAssertFalse(model.isSearching)
    }

    func testANewQueryClearsTheOldQuerysHitsAtOnce() async {
        let stub = StubSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("s1")]])
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .milliseconds(80))
        let ctx = context(stub)
        model.update(query: "recycling", context: ctx)
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits.count, 1)
        model.update(query: "recyclingx", context: ctx)
        XCTAssertEqual(model.hits, [], "hits for another query never sit under the new one")
        await model.waitForPendingSearch()
    }

    // MARK: - Older Hermes and errors

    func testMissingRouteIsRememberedForTheConnectionAndNeverAskedAgain() async {
        let support = SessionContentSearchSupport()
        let stub = StubSearchRequester()
        stub.fallback = .failure(DashboardTicketBridgeError.http(status: 404, detail: "Not Found"))
        let model = SessionContentSearchModel(support: support, debounce: .zero)
        let ctx = context(stub)

        model.update(query: "recycling", context: ctx)
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits, [])
        XCTAssertTrue(support.isUnsupported(scope))

        for query in ["recyclingx", "compost", "bins"] {
            model.update(query: query, context: ctx)
            await model.waitForPendingSearch()
        }
        XCTAssertEqual(stub.paths, [path("recycling")])

        // Another dashboard connection is asked again.
        let otherScope = NSObject()
        model.update(query: "bins", context: context(stub, scope: otherScope))
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [path("recycling"), path("bins")])
    }

    func testMethodNotAllowedAndNonSearchBodiesCountAsUnsupported() async {
        for answer: Result<[String: Any], Error> in [
            .failure(DashboardTicketBridgeError.http(status: 405, detail: "Method Not Allowed")),
            .success(["detail": "Session not found"]),
        ] {
            let support = SessionContentSearchSupport()
            let stub = StubSearchRequester()
            stub.fallback = answer
            let model = SessionContentSearchModel(support: support, debounce: .zero)
            model.update(query: "recycling", context: context(stub))
            await model.waitForPendingSearch()
            XCTAssertTrue(support.isUnsupported(scope))
            XCTAssertEqual(model.hits, [])
        }
    }

    func testOtherFailuresStayQuietAndTheNextQueryTriesAgain() async {
        let support = SessionContentSearchSupport()
        let stub = StubSearchRequester()
        stub.responses[path("recycling")] = .failure(DashboardTicketBridgeError.http(status: 500, detail: "Search failed"))
        stub.responses[path("compost")] = .success(["results": [result("s2")]])
        let model = SessionContentSearchModel(support: support, debounce: .zero)
        let ctx = context(stub)

        model.update(query: "recycling", context: ctx)
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits, [])
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(support.isUnsupported(scope))

        model.update(query: "compost", context: ctx)
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits.map(\.sessionID), ["s2"])
    }

    func testAFailedSearchIsSentAgainForTheSameQuery() async {
        let stub = StubSearchRequester()
        stub.responses[path("recycling")] = .failure(DashboardTicketBridgeError.http(status: 500, detail: "Search failed"))
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        let ctx = context(stub)

        model.update(query: "recycling", context: ctx)
        await model.waitForPendingSearch()
        XCTAssertEqual(model.hits, [])

        // Asked again (a redraw, or a trailing space the trim removes):
        // the failure didn't settle the query, so it goes out again.
        stub.responses[path("recycling")] = .success(["results": [result("s1")]])
        model.update(query: "recycling ", context: ctx)
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [path("recycling"), path("recycling")])
        XCTAssertEqual(model.hits.map(\.sessionID), ["s1"])
    }

    func testNoConnectionClearsAndSendsNothing() async {
        let stub = StubSearchRequester()
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        model.update(query: "recycling", context: nil)
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [])
        XCTAssertEqual(model.hits, [])
    }

    func testMissingRouteDetection() {
        XCTAssertTrue(SessionContentSearch.isUnsupported(DashboardTicketBridgeError.http(status: 404, detail: "")))
        XCTAssertTrue(SessionContentSearch.isUnsupported(DashboardTicketBridgeError.http(status: 405, detail: "")))
        XCTAssertTrue(SessionContentSearch.isUnsupported(DashboardTicketBridgeError.http(status: 410, detail: "")))
        XCTAssertFalse(SessionContentSearch.isUnsupported(DashboardTicketBridgeError.http(status: 500, detail: "")))
        XCTAssertFalse(SessionContentSearch.isUnsupported(DashboardTicketBridgeError.signInRequired))
        XCTAssertFalse(SessionContentSearch.isUnsupported(DashboardTicketBridgeError.notReady))
    }

    // MARK: - De-duplication

    private func hits(_ rows: [[String: Any]]) -> [SessionContentSearchHit] {
        SessionContentSearch.hits(from: ["results": rows], query: "recycling") ?? []
    }

    func testHitsForChatsTheListAlreadyShowsAreDropped() {
        let titled = session("s1", title: "Next Recycling Pickup Dates")
        let rows = SessionContentSearch.rows(
            hits: hits([result("s1"), result("s2", title: "Kitchen")]),
            listed: [titled],
            known: [titled, session("s2", title: "Kitchen chat")]
        )
        XCTAssertEqual(rows.map(\.openID), ["s2"])
        // A listed chat's own title wins over Hermes'.
        XCTAssertEqual(rows.first?.title, "Kitchen chat")
    }

    func testAllProfilesHitsMatchChatsOnlyInTheirOwnProfile() {
        // Two profiles hold the same chat id: the one in use lists it, the
        // other's match still shows and opens that profile's chat.
        var atlasChat = session("same", title: "Atlas chat")
        atlasChat.profile = "atlas"
        let tagged = hits([result("same")]) + hits([result("same")]).map { hit in
            var hit = hit
            hit.profile = "atlas"
            return hit
        }
        let rows = SessionContentSearch.rows(
            hits: tagged,
            listed: [session("same")],
            known: [session("same"), atlasChat],
            activeProfile: "default",
            owner: { $0.profile ?? "" }
        )
        XCTAssertEqual(rows.map(\.id), ["atlas\u{1F}same"])
        XCTAssertEqual(rows.first?.session?.profile, "atlas")
        XCTAssertEqual(rows.first?.title, "Atlas chat")
    }

    func testDuplicatesMatchThroughStoredIDsAndLineageRoots() {
        // The list holds the runtime id; Hermes answers with the stored id,
        // or with a compression tip whose root the list row carries.
        let listed = [
            session("runtime-1", stored: "stored-1"),
            session("tip-2", root: "root-2"),
        ]
        let rows = SessionContentSearch.rows(
            hits: hits([result("stored-1"), result("tip-new", root: "root-2"), result("s3")]),
            listed: listed,
            known: listed
        )
        XCTAssertEqual(rows.map(\.openID), ["s3"])
    }

    func testHitsMapOntoKnownChatsOnceEach() {
        let known = session("runtime-4", title: "Garden", stored: "stored-4")
        let rows = SessionContentSearch.rows(
            hits: hits([result("stored-4"), result("old-root-4", root: "stored-4")]),
            listed: [],
            known: [known]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.openID, "runtime-4", "a listed chat opens by its list id")
        XCTAssertEqual(rows.first?.title, "Garden")
    }

    func testUnknownChatsOpenByHermesIDAndFallBackToAnUntitledName() {
        let rows = SessionContentSearch.rows(
            hits: hits([result("far-1", title: "From last year"), result("far-2")]),
            listed: [],
            known: []
        )
        XCTAssertEqual(rows.map(\.openID), ["far-1", "far-2"])
        XCTAssertNil(rows.first?.session)
        XCTAssertEqual(rows.first?.title, "From last year")
        XCTAssertEqual(rows.last?.title, AppLocalization.string("Untitled conversation"))
    }

    func testArchivedChatsAndChatsOutsideAFilterAreLeftOut() {
        let archivedHit: [String: Any] = ["session_id": "a1", "snippet": "", "archived": true]
        let unread = session("u1")
        let read = session("r1")
        let archivedKnown = session("arch-known", archived: true)
        let rows = SessionContentSearch.rows(
            hits: hits([archivedHit, result("u1"), result("r1"), result("arch-known")]),
            listed: [],
            known: [unread, read, archivedKnown],
            allowed: [unread, archivedKnown]
        )
        XCTAssertEqual(rows.map(\.openID), ["u1"])
    }

    // MARK: - Snippet highlighting

    func testHermesMarksBecomeMatchRuns() {
        let snippet = SessionSearchSnippet.parse("...put the >>>recycling<<< out on >>>Tuesday<<<...", query: "recycling")
        XCTAssertEqual(snippet.runs, [
            .init(text: "…put the ", isMatch: false),
            .init(text: "recycling", isMatch: true),
            .init(text: " out on ", isMatch: false),
            .init(text: "Tuesday", isMatch: true),
            .init(text: "…", isMatch: false),
        ])
        XCTAssertEqual(snippet.plainText, "…put the recycling out on Tuesday…")
    }

    func testSnippetIsOneLine() {
        let snippet = SessionSearchSnippet.parse("first line\n\n  >>>recycling<<<\tday", query: "recycling")
        XCTAssertEqual(snippet.plainText, "first line recycling day")
        XCTAssertEqual(snippet.runs.filter(\.isMatch).map(\.text), ["recycling"])
    }

    func testAStrayClosingMarkNeverShowsAsText() {
        let stray = SessionSearchSnippet.parse("the recycling<<< bins >>>day<<<", query: "x")
        XCTAssertEqual(stray.plainText, "the recycling bins day")
        XCTAssertEqual(stray.runs.filter(\.isMatch).map(\.text), ["day"])
    }

    /// A `>>>` Hermes didn't close is the message's own text (a Python
    /// prompt, a quote), not the start of a match running to the end.
    func testAnUnclosedOpeningMarkIsTheMessagesOwnText() {
        let prompt = SessionSearchSnippet.parse(">>> print(recycling) done", query: "recycling")
        XCTAssertEqual(prompt.runs, [
            .init(text: ">>> print(", isMatch: false),
            .init(text: "recycling", isMatch: true),
            .init(text: ") done", isMatch: false),
        ])
        let after = SessionSearchSnippet.parse("the >>>recycling<<< bins >>> more", query: "x")
        XCTAssertEqual(after.runs, [
            .init(text: "the ", isMatch: false),
            .init(text: "recycling", isMatch: true),
            .init(text: " bins >>> more", isMatch: false),
        ])
    }

    /// A literal `>>>` ahead of a real match stays text, and the match
    /// after it is still found.
    func testALiteralOpeningMarkBeforeARealMatchStaysText() {
        let snippet = SessionSearchSnippet.parse("a >>> b >>>recycling<<< day", query: "x")
        XCTAssertEqual(snippet.runs, [
            .init(text: "a >>> b ", isMatch: false),
            .init(text: "recycling", isMatch: true),
            .init(text: " day", isMatch: false),
        ])
        let twoMatches = SessionSearchSnippet.parse(">>>one<<< >>> >>>two<<<", query: "x")
        XCTAssertEqual(twoMatches.runs.filter(\.isMatch).map(\.text), ["one", "two"])
        XCTAssertEqual(twoMatches.plainText, "one >>> two")
    }

    func testUnmarkedSnippetHighlightsTheQueryWords() {
        // A session-id hit's preview, or the LIKE fallback short CJK takes.
        let snippet = SessionSearchSnippet.parse("When is the Recycling pickup? recycling again", query: "recycling pick")
        XCTAssertEqual(snippet.runs, [
            .init(text: "When is the ", isMatch: false),
            .init(text: "Recycling", isMatch: true),
            .init(text: " ", isMatch: false),
            .init(text: "pick", isMatch: true),
            .init(text: "up? ", isMatch: false),
            .init(text: "recycling", isMatch: true),
            .init(text: " again", isMatch: false),
        ])
        XCTAssertEqual(SessionSearchSnippet.parse("回收日是周二", query: "回收").runs.first, .init(text: "回收", isMatch: true))
    }

    func testOverlappingQueryWordsHighlightOnce() {
        let snippet = SessionSearchSnippet.parse("recycling", query: "recycl cycling")
        XCTAssertEqual(snippet.plainText, "recycling")
        XCTAssertEqual(snippet.runs, [.init(text: "recycling", isMatch: true)])
    }

    func testSnippetWithoutAMatchIsPlainAndEmptyStaysEmpty() {
        XCTAssertEqual(SessionSearchSnippet.parse("Session ID: abc", query: "zzz").runs, [.init(text: "Session ID: abc", isMatch: false)])
        XCTAssertEqual(SessionSearchSnippet.parse("", query: "x").runs, [])
    }

    func testAttributedSnippetStylesOnlyTheMatch() {
        let attributed = SessionSearchSnippet.parse("the >>>recycling<<< day", query: "").attributed(matchColor: .red)
        XCTAssertEqual(String(attributed.characters), "the recycling day")
        let styled = attributed.runs.filter { $0.foregroundColor != nil }
        XCTAssertEqual(styled.count, 1)
        XCTAssertEqual(styled.first.map { String(attributed[$0.range].characters) }, "recycling")
    }

    // MARK: - All profiles

    func testAllProfilesSearchAsksEachProfileAndTagsTheirHits() async {
        let stub = StubSearchRequester()
        stub.responses[path("recycling")] = .success(["results": [result("own")]])
        stub.responses[path("recycling", profile: "atlas")] = .success(["results": [result("theirs")]])
        stub.responses[path("recycling", profile: "nova")] = .failure(URLError(.timedOut))
        let model = SessionContentSearchModel(support: SessionContentSearchSupport(), debounce: .zero)
        let context = SessionContentSearchModel.Context(
            scope: scope,
            profile: "default",
            otherProfiles: ["atlas", "nova"]
        ) { path in
            try await stub.request(path)
        }
        model.update(query: "recycling", context: context)
        await model.waitForPendingSearch()
        XCTAssertEqual(stub.paths, [path("recycling"), path("recycling", profile: "atlas"), path("recycling", profile: "nova")])
        // A profile whose search failed is left out; the others still show.
        XCTAssertEqual(model.hits.map(\.sessionID), ["own", "theirs"])
        XCTAssertEqual(model.hits.map(\.profile), [nil, "atlas"])
        XCTAssertFalse(model.isSearching)
    }
}
