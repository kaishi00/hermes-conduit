//
//  SessionCatalogLoadTests.swift
//  Conduit
//
//  Right after a browser sign-in, Chats said "No Sessions / Sessions will
//  appear here once created" on a dashboard with hundreds of sessions, until
//  a pull to refresh. Sign-out empties the catalog, and the sign-in's first
//  read takes a few seconds (the dashboard page, then the catalog pages):
//  the list read that empty array as "no sessions". The list now says
//  "No Sessions" only for a catalog Hermes answered for this dashboard
//  profile; until then it is loading, and a failed or refused read says it
//  failed, with Try Again.
//

import XCTest
@testable import Conduit

@MainActor
final class SessionCatalogLoadTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionCatalogLoadTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func row(_ id: String, profile: String) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "",
            lastActivityAt: Date().timeIntervalSince1970,
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            messageCount: 3,
            isUnread: nil,
            readWatermark: nil,
            lineageRootId: nil
        )
    }

    private enum CatalogAnswer {
        case rows([String])
        case failure(Error)
    }

    private func makeAppState(answer: @escaping () -> CatalogAnswer, loads: @escaping () -> Void = {}) -> AppState {
        var appState: AppState!
        appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionCatalogLoader: { _ in
                loads()
                switch answer() {
                case .rows(let ids):
                    return ids.map { self.row($0, profile: appState.activeProfile) }
                case .failure(let error):
                    throw error
                }
            }
        )
        appState.isConnected = true
        return appState
    }

    private func placeholder(_ appState: AppState) -> SessionListPlaceholder {
        SessionListPlaceholder.resolve(
            hasRows: !appState.sessions.isEmpty,
            hasOfflineCopy: appState.offlineChatPresentation != nil,
            catalogPhase: appState.sessionCatalogPhase,
            isRefreshing: appState.isRefreshingSessionCatalog
        )
    }

    // MARK: - Policy

    func testOnlyAnAnsweredCatalogIsEmpty() {
        XCTAssertEqual(SessionListPlaceholder.resolve(hasRows: false, hasOfflineCopy: false, catalogPhase: .notLoaded, isRefreshing: false), .loading)
        XCTAssertEqual(SessionListPlaceholder.resolve(hasRows: false, hasOfflineCopy: false, catalogPhase: .loaded, isRefreshing: false), .empty)
        XCTAssertEqual(SessionListPlaceholder.resolve(hasRows: false, hasOfflineCopy: false, catalogPhase: .failed("Sign in again."), isRefreshing: false), .failed("Sign in again."))
        // Try Again in flight: loading, not the old failure.
        XCTAssertEqual(SessionListPlaceholder.resolve(hasRows: false, hasOfflineCopy: false, catalogPhase: .failed("x"), isRefreshing: true), .loading)
        // Rows, or the saved offline copy, need no placeholder.
        for phase: SessionCatalogLoadPhase in [.notLoaded, .loaded, .failed("x")] {
            XCTAssertEqual(SessionListPlaceholder.resolve(hasRows: true, hasOfflineCopy: false, catalogPhase: phase, isRefreshing: false), .none)
            XCTAssertEqual(SessionListPlaceholder.resolve(hasRows: false, hasOfflineCopy: true, catalogPhase: phase, isRefreshing: false), .none)
            // Listed rows a search or filter matched none of: that list is
            // empty, never loading.
            XCTAssertEqual(SessionListPlaceholder.resolve(hasRows: false, hasOfflineCopy: false, catalogPhase: phase, isRefreshing: false, filteredOutRows: true), .empty)
        }
    }

    /// A read cancelled under it says nothing about the catalog: still
    /// loading, never "Couldn't Load Chats".
    func testACancelledReadIsNotAFailure() async {
        let appState = makeAppState(answer: { .failure(CancellationError()) })
        await appState.loadSessions()
        XCTAssertEqual(appState.sessionCatalogPhase, .notLoaded)
        XCTAssertEqual(placeholder(appState), .loading)
    }

    func testLoadStateBelongsToOneDashboardProfile() {
        let dashboard = UUID()
        let owner = SessionCatalogOwner(dashboardID: dashboard, profile: "default")
        var state = SessionCatalogLoadState()
        XCTAssertEqual(state.phase(for: owner), .notLoaded)
        state.markFailed("Sign in again.", owner: owner)
        XCTAssertEqual(state.phase(for: owner), .failed("Sign in again."))
        state.markLoaded(owner)
        XCTAssertEqual(state.phase(for: owner), .loaded)
        // A later failed refresh keeps the catalog that arrived.
        state.markFailed("Timed out.", owner: owner)
        XCTAssertEqual(state.phase(for: owner), .loaded)
        // Another profile, or another dashboard, has loaded nothing yet.
        XCTAssertEqual(state.phase(for: SessionCatalogOwner(dashboardID: dashboard, profile: "work")), .notLoaded)
        XCTAssertEqual(state.phase(for: SessionCatalogOwner(dashboardID: UUID(), profile: "default")), .notLoaded)
        state.reset()
        XCTAssertEqual(state.phase(for: owner), .notLoaded)
    }

    // MARK: - AppState

    /// The sign-in's list before its first read lands: loading, not
    /// "No Sessions".
    func testAConnectedListWithoutItsCatalogIsLoadingNotEmpty() {
        let appState = makeAppState(answer: { .rows([]) })
        XCTAssertTrue(appState.sessions.isEmpty)
        XCTAssertEqual(appState.sessionCatalogPhase, .notLoaded)
        XCTAssertEqual(placeholder(appState), .loading)
    }

    func testARefusedReadSaysItFailedNotNoSessions() async {
        let appState = makeAppState(answer: { .failure(DashboardTicketBridgeError.signInRequired) })
        await appState.loadSessions()
        XCTAssertTrue(appState.sessions.isEmpty)
        guard case .failed(let message) = placeholder(appState) else {
            return XCTFail("expected the failure, got \(placeholder(appState))")
        }
        XCTAssertEqual(message, UserFacingError.message(for: DashboardTicketBridgeError.signInRequired))
    }

    func testANotReadyBridgeSaysItFailedNotNoSessions() async {
        let appState = makeAppState(answer: { .failure(DashboardTicketBridgeError.notReady) })
        await appState.loadSessions()
        guard case .failed = placeholder(appState) else {
            return XCTFail("expected the failure, got \(placeholder(appState))")
        }
    }

    func testAnAnsweredEmptyCatalogIsNoSessions() async {
        let appState = makeAppState(answer: { .rows([]) })
        await appState.loadSessions()
        XCTAssertEqual(appState.sessionCatalogPhase, .loaded)
        XCTAssertEqual(placeholder(appState), .empty)
    }

    /// Try Again after a refused read lists the sessions.
    func testTryAgainAfterAFailureListsTheSessions() async {
        var answer = CatalogAnswer.failure(DashboardTicketBridgeError.signInRequired)
        let appState = makeAppState(answer: { answer })
        await appState.loadSessions()
        guard case .failed = placeholder(appState) else { return XCTFail("expected the failure") }
        answer = .rows(["a", "b", "c"])
        await appState.refreshSessionCatalog()
        XCTAssertEqual(appState.sessions.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(appState.sessionCatalogPhase, .loaded)
        XCTAssertEqual(placeholder(appState), .none)
    }

    /// A refresh that fails after the catalog arrived keeps its rows.
    func testAFailedRefreshKeepsTheListedCatalog() async {
        var answer = CatalogAnswer.rows(["a"])
        let appState = makeAppState(answer: { answer })
        await appState.loadSessions()
        answer = .failure(DashboardTicketBridgeError.notReady)
        await appState.refreshSessionCatalog()
        XCTAssertEqual(appState.sessions.map(\.id), ["a"])
        XCTAssertEqual(appState.sessionCatalogPhase, .loaded)
    }

    /// The list's own first read once connected: it runs when no catalog
    /// has arrived, once, and never again after one has.
    func testTheListLoadsItsCatalogOnceTheConnectionIsUp() async {
        var loads = 0
        let appState = makeAppState(answer: { .rows(["a", "b"]) }, loads: { loads += 1 })
        appState.isConnected = false
        await appState.loadSessionCatalogIfNeeded()
        XCTAssertEqual(loads, 0, "no read before the connection is up")

        appState.isConnected = true
        await appState.loadSessionCatalogIfNeeded()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(appState.sessions.map(\.id), ["a", "b"])

        await appState.loadSessionCatalogIfNeeded()
        XCTAssertEqual(loads, 1, "a loaded catalog is not read again")
    }

    /// Two views that start the first read together share one read.
    func testTwoFirstReadsAtOnceShareOneRead() async {
        var loads = 0
        var release: CheckedContinuation<Void, Never>?
        var appState: AppState!
        appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionCatalogLoader: { _ in
                loads += 1
                await withCheckedContinuation { release = $0 }
                return [self.row("a", profile: appState.activeProfile)]
            }
        )
        appState.isConnected = true

        async let first: Void = appState.loadSessionCatalogIfNeeded()
        async let second: Void = appState.loadSessionCatalogIfNeeded()
        while release == nil { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        release?.resume()
        _ = await (first, second)

        XCTAssertEqual(loads, 1, "the second caller waited for the first read")
        XCTAssertEqual(appState.sessions.map(\.id), ["a"])
        XCTAssertEqual(appState.sessionCatalogPhase, .loaded)
    }

    /// Two list reads overlap and the older one answers last: the list
    /// keeps the newer answer. Before, the older answer replaced it and a
    /// chat started meanwhile left the list until the next read (#786).
    func testAnOlderListReadThatAnswersLastKeepsTheNewerList() async {
        var reads: [CheckedContinuation<[String], Never>] = []
        var appState: AppState!
        appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionCatalogLoader: { _ in
                let ids = await withCheckedContinuation { reads.append($0) }
                return ids.map { self.row($0, profile: appState.activeProfile) }
            }
        )
        appState.isConnected = true

        async let older: Void = appState.loadSessions()
        while reads.count < 1 { await Task.yield() }
        async let newer: Void = appState.loadSessions()
        while reads.count < 2 { await Task.yield() }
        // The newer read saw the chat started in between and answers first.
        reads[1].resume(returning: ["a", "new"])
        await newer
        XCTAssertEqual(appState.sessions.map(\.id), ["a", "new"])
        reads[0].resume(returning: ["a"])
        await older

        XCTAssertEqual(appState.sessions.map(\.id), ["a", "new"], "the older answer arrived last but is older")
    }

    /// An older read that fails after a newer one listed puts up no
    /// banner: the list shown is current.
    func testAnOlderListReadThatFailsLastSaysNothing() async {
        var reads: [CheckedContinuation<[String], Error>] = []
        var appState: AppState!
        appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionCatalogLoader: { _ in
                let ids = try await withCheckedThrowingContinuation { reads.append($0) }
                return ids.map { self.row($0, profile: appState.activeProfile) }
            }
        )
        appState.isConnected = true

        async let older: Void = appState.loadSessions()
        while reads.count < 1 { await Task.yield() }
        async let newer: Void = appState.loadSessions()
        while reads.count < 2 { await Task.yield() }
        reads[1].resume(returning: ["a"])
        await newer
        reads[0].resume(throwing: URLError(.timedOut))
        await older

        XCTAssertEqual(appState.sessions.map(\.id), ["a"])
        XCTAssertNil(appState.errorMessage)
    }

    /// A newer read that fails leaves the list to the older read still on
    /// its way: that answer is still the freshest one.
    func testAnOlderListReadStillLandsWhenTheNewerOneFails() async {
        var reads: [CheckedContinuation<[String], Error>] = []
        var appState: AppState!
        appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionCatalogLoader: { _ in
                let ids = try await withCheckedThrowingContinuation { reads.append($0) }
                return ids.map { self.row($0, profile: appState.activeProfile) }
            }
        )
        appState.isConnected = true

        async let older: Void = appState.loadSessions()
        while reads.count < 1 { await Task.yield() }
        async let newer: Void = appState.loadSessions()
        while reads.count < 2 { await Task.yield() }
        reads[1].resume(throwing: URLError(.timedOut))
        await newer
        reads[0].resume(returning: ["a"])
        await older

        XCTAssertEqual(appState.sessions.map(\.id), ["a"])
    }

    /// A failed first read stays failed (with Try Again) instead of the
    /// list retrying on its own in a loop.
    func testAFailedFirstReadIsNotRetriedAutomatically() async {
        var loads = 0
        let appState = makeAppState(answer: { .failure(DashboardTicketBridgeError.signInRequired) }, loads: { loads += 1 })
        await appState.loadSessionCatalogIfNeeded()
        await appState.loadSessionCatalogIfNeeded()
        XCTAssertEqual(loads, 1)
        guard case .failed = placeholder(appState) else { return XCTFail("expected the failure") }
    }

    /// Sign out, then sign in again: the new sign-in's list is loading until
    /// its own catalog arrives, never the signed-out "No Sessions".
    func testSignOutForgetsTheCatalogSoTheNextSignInLoadsFirst() async {
        var answer = CatalogAnswer.rows([])
        let appState = makeAppState(answer: { answer })
        await appState.loadSessions()
        XCTAssertEqual(placeholder(appState), .empty)

        appState.disconnect()
        XCTAssertEqual(appState.sessionCatalogPhase, .notLoaded)

        // Signed in again: connected, the first read not back yet.
        appState.isConnected = true
        XCTAssertEqual(placeholder(appState), .loading)
        answer = .rows(["a", "b", "c"])
        await appState.loadSessionCatalogIfNeeded()
        XCTAssertEqual(appState.sessions.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(placeholder(appState), .none)
    }

    // MARK: - The connect's own catalog sync

    private func makeSyncingAppState(loadCatalog: @escaping @MainActor (HermesClient, Bool) async throws -> [SessionSummary]) -> AppState {
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: loadCatalog,
                openSession: { _, id, _ in
                    SessionResumeResult(sessionId: id, storedSessionId: id, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
                },
                refreshContext: { _, _ in },
                pendingApprovals: { _, _ in [] }
            )
        )
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://hermes.example.test", ticket: "ticket"),
            profile: "default"
        )
        appState.isConnected = true
        return appState
    }

    /// The sign-in's sync publishes the catalog: the list is loaded.
    func testTheConnectSyncMarksItsCatalogLoaded() async {
        var appState: AppState!
        appState = makeSyncingAppState { _, _ in [self.row("a", profile: appState.activeProfile)] }
        appState.activeSessionId = "a"
        XCTAssertEqual(placeholder(appState), .loading)
        await appState.syncSession()
        XCTAssertEqual(appState.sessions.map(\.id), ["a"])
        XCTAssertEqual(appState.sessionCatalogPhase, .loaded)
    }

    /// A connect sync whose catalog answers after a newer list read landed
    /// keeps the newer list, and still resumes its chat.
    func testAnOlderSyncReadThatAnswersLastKeepsTheNewerList() async {
        var reads: [CheckedContinuation<[String], Never>] = []
        var appState: AppState!
        appState = makeSyncingAppState { _, _ in
            let ids = await withCheckedContinuation { reads.append($0) }
            return ids.map { self.row($0, profile: appState.activeProfile) }
        }
        appState.activeSessionId = "a"

        async let sync: Void = appState.syncSession()
        while reads.count < 1 { await Task.yield() }
        async let newer: Void = appState.loadSessions()
        while reads.count < 2 { await Task.yield() }
        reads[1].resume(returning: ["a", "new"])
        await newer
        reads[0].resume(returning: ["a"])
        await sync

        XCTAssertEqual(appState.sessions.map(\.id), ["a", "new"], "the sync's answer arrived last but is older")
        XCTAssertEqual(appState.activeSessionId, "a")
        XCTAssertEqual(appState.sessionCatalogPhase, .loaded)
    }

    /// A connect sync whose catalog read fails after a newer list read
    /// listed puts up no banner: the list shown is current.
    func testAnOlderSyncReadThatFailsLastSaysNothing() async {
        var reads: [CheckedContinuation<[String], Error>] = []
        var appState: AppState!
        appState = makeSyncingAppState { _, _ in
            let ids = try await withCheckedThrowingContinuation { reads.append($0) }
            return ids.map { self.row($0, profile: appState.activeProfile) }
        }
        appState.activeSessionId = "a"

        async let sync: Void = appState.syncSession()
        while reads.count < 1 { await Task.yield() }
        async let newer: Void = appState.loadSessions()
        while reads.count < 2 { await Task.yield() }
        reads[1].resume(returning: ["a", "new"])
        await newer
        reads[0].resume(throwing: URLError(.timedOut))
        await sync

        XCTAssertEqual(appState.sessions.map(\.id), ["a", "new"])
        XCTAssertNil(appState.errorMessage)
        XCTAssertEqual(appState.sessionCatalogPhase, .loaded)
    }

    /// A sync whose catalog read is refused leaves the failure, not
    /// "No Sessions".
    func testARefusedConnectSyncSaysItFailed() async {
        let appState = makeSyncingAppState { _, _ in throw DashboardTicketBridgeError.signInRequired }
        appState.activeSessionId = "a"
        await appState.syncSession()
        XCTAssertTrue(appState.sessions.isEmpty)
        guard case .failed = placeholder(appState) else {
            return XCTFail("expected the failure, got \(placeholder(appState))")
        }
    }

    /// A connect sync whose catalog read was cancelled under it says
    /// nothing about the catalog, like a cancelled list read: no banner,
    /// still loading, never "Couldn't Load Chats".
    func testACancelledConnectSyncReadIsNotAFailure() async {
        for cancellation: Error in [URLError(.cancelled), CancellationError()] {
            let appState = makeSyncingAppState { _, _ in throw cancellation }
            appState.activeSessionId = "a"
            await appState.syncSession()
            XCTAssertNil(appState.errorMessage, "\(cancellation)")
            XCTAssertEqual(appState.sessionCatalogPhase, .notLoaded, "\(cancellation)")
            XCTAssertEqual(placeholder(appState), .loading, "\(cancellation)")
            // Nothing retries it: the composer isn't left reconnecting.
            XCTAssertTrue(appState.turnState.acceptsComposerActions, "\(cancellation): \(appState.turnState)")
        }
    }

    /// A reply running when the sync's read is cancelled is still running:
    /// the cancelled read says nothing about it.
    func testACancelledSyncReadLeavesARunningReplyRunning() async {
        let appState = makeSyncingAppState { _, _ in throw CancellationError() }
        appState.activeSessionId = "a"
        appState.handleStreamEvent(.sessionBusy(sessionId: "a", busy: true))
        XCTAssertEqual(appState.turnState, .running)
        await appState.syncSession()
        XCTAssertEqual(appState.turnState, .running)
    }
}
