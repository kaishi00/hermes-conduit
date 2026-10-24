import XCTest
@testable import Conduit

/// A restored conversation the gateway authoritatively reports missing
/// (`session.resume` 4007 "session not found") must not leave a cold launch
/// on the dead read-only saved copy, retrying the same row forever. The
/// missing-saved-session recovery only ran when the saved session was ABSENT
/// from the catalog; these cover a catalog that still LISTS it (and a
/// fallback row that is just as dead). They drive AppState through its
/// chat-resume test seams only: no gateway, no network.
///
/// Ported from Marceswan/hermes-conduit (ConduitMacTests), where the fix
/// first landed for macOS only.
@MainActor
final class MissingSessionRecoveryTests: XCTestCase {
    private final class Scheduler {
        private(set) var scheduledCount = 0
        func schedule(
            after delay: TimeInterval,
            operation: @escaping @MainActor () async -> Void
        ) -> ChatResumeReconnectCancellation {
            scheduledCount += 1
            return {}
        }
    }

    private final class Requests {
        var ids: [String] = []
        /// Runs inside `session.resume`, before it answers (fence tests).
        var onOpen: (@MainActor (String) -> Void)?
        /// `session.create` seam: nil throws `notConnected`, as the real
        /// client does with no transport.
        var create: (@MainActor () async throws -> String)?
        var createCalls = 0
        var turnStateDuringCreate: [TurnState] = []
        weak var appState: AppState?
    }

    private struct Fixture {
        let appState: AppState
        let store: ChatResumeStore
        let scheduler: Scheduler
    }

    private let notFound = RpcError(code: 4007, message: "session not found")

    private func session(_ id: String, storedID: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: storedID,
            // As the catalog parser lists them: the stored id is an alias too.
            alternateIds: [storedID].compactMap { $0 }.filter { $0 != id },
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    private func resumed(_ id: String) -> SessionResumeResult {
        SessionResumeResult(
            sessionId: id,
            storedSessionId: id,
            messages: [ChatMessage(id: "\(id)-m", role: .user, content: "hi", timestamp: "1")],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        )
    }

    /// Cold launch with the saved copy up and a live client installed.
    private func makeFixture(
        saved: String,
        catalog: [SessionSummary],
        open: @escaping @MainActor (String) throws -> SessionResumeResult,
        persistedTranscript: (@MainActor (String, String, String) async -> PersistedTranscriptFetchOutcome)? = nil,
        requests: Requests
    ) -> Fixture {
        let suite = "MissingSessionRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(.continueWhereLeftOff)
        let scheduler = Scheduler()
        var operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in catalog },
            openSession: { _, id, _ in
                requests.ids.append(id)
                requests.onOpen?(id)
                return try open(id)
            },
            persistedTranscript: persistedTranscript,
            refreshContext: { _, _ in }
        )
        operations.createSession = { [unowned requests] _, _ in
            requests.createCalls += 1
            if let state = requests.appState {
                requests.turnStateDuringCreate.append(state.turnState)
            }
            guard let create = requests.create else { throw HermesError.notConnected }
            let id = try await create()
            return (sessionId: id, storedSessionId: id, profile: nil)
        }
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            reconnectScheduler: scheduler.schedule(after:operation:),
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        requests.appState = appState
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        store.setLastSessionID(saved, for: "default")

        let dashboard = UUID()
        appState.offlineChatCacheForTesting.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: saved,
            title: "Saved",
            messages: [ChatMessage(id: "c1", role: .user, content: "cached", timestamp: "1")],
            sessions: [session(saved)]
        )
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertNotNil(appState.offlineChatPresentation, "precondition: cold launch shows the saved copy")
        return Fixture(appState: appState, store: store, scheduler: scheduler)
    }

    /// The automatic resume of a cold launch.
    private func coldLaunchSync(_ f: Fixture) async {
        await f.appState.syncSession(purpose: .automaticReturn, using: nil, automaticWorkToken: nil)
    }

    // MARK: - Catalog lists the saved session but the gateway cannot resume it

    func testListedButMissingSavedSessionFallsBackToAnotherSession() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "other"])
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertEqual(f.store.lastSessionID(for: "default"), "other")
        XCTAssertNil(f.appState.offlineChatPresentation, "the live chat replaced the saved copy")
        XCTAssertNil(f.appState.errorMessage)
        XCTAssertEqual(f.appState.turnState, .idle)
        XCTAssertEqual(f.scheduler.scheduledCount, 0, "no reconnect loop after an authoritative not-found")
    }

    /// A row retired for a 4007 that resumes later (the gateway restored it,
    /// the user opened it) is alive: a later automatic return may pick it
    /// again instead of skipping it for the rest of the app run.
    func testARetiredRowThatResumesLaterIsOfferedAgain() async {
        let requests = Requests()
        var restored = false
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("other")],
            open: { id in
                if id == "gone", !restored { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )
        f.store.setBehavior(.latestActivity)

        await coldLaunchSync(f)
        XCTAssertEqual(f.appState.activeSessionId, "other")

        restored = true
        let opened = await f.appState.openSession("gone")
        XCTAssertTrue(opened)
        XCTAssertEqual(f.appState.activeSessionId, "gone")

        // Away (a dashboard switch) and back.
        f.appState.activeSessionId = nil
        requests.ids.removeAll()
        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids.first, "gone", "the newest row is no longer skipped")
        XCTAssertEqual(f.appState.activeSessionId, "gone")
    }

    /// #446: Hermes drops runtimes (a gateway restart, idle reaping) and
    /// resumes by the stored id. A listed row whose RUNTIME id answers 4007
    /// is not a dead conversation while its stored id still resumes: the
    /// conversation opens, the pointer stays, nothing is walked or created.
    func testListedSessionWhoseRuntimeIDIsGoneResumesByStoredID() async {
        let requests = Requests()
        requests.create = { "must-not-happen" }
        let f = makeFixture(
            saved: "stored-a",
            catalog: [session("runtime-old", storedID: "stored-a"), session("other")],
            open: { id in
                switch id {
                case "runtime-old":
                    throw self.notFound
                case "stored-a":
                    return SessionResumeResult(
                        sessionId: "runtime-new",
                        storedSessionId: "stored-a",
                        messages: [ChatMessage(id: "a-m", role: .user, content: "hi", timestamp: "1")],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                default:
                    return self.resumed(id)
                }
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["runtime-old", "stored-a"], "the stored id is tried once; no other row is probed")
        XCTAssertEqual(f.appState.activeSessionId, "runtime-new")
        // The pointer keeps naming this conversation. Upstream records a
        // conversation by its catalog row id (ChatSessionPersistenceIdentity
        // .canonicalID), here the runtime id; it is not retired or moved on.
        XCTAssertTrue(
            ["runtime-old", "stored-a"].contains(f.store.lastSessionID(for: "default") ?? ""),
            "the saved pointer still names this conversation"
        )
        XCTAssertEqual(requests.createCalls, 0, "no fresh chat")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertNil(f.appState.errorMessage)
        XCTAssertEqual(f.appState.turnState, .idle)
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    /// The same row with its stored id gone too is dead: the walk moves on.
    func testListedSessionWhoseRuntimeAndStoredIDsAreGoneFallsBack() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "stored-a",
            catalog: [session("runtime-old", storedID: "stored-a"), session("other")],
            open: { id in
                if id == "other" { return self.resumed(id) }
                throw self.notFound
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["runtime-old", "stored-a", "other"])
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertEqual(f.store.lastSessionID(for: "default"), "other")
        XCTAssertNil(f.appState.errorMessage)
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    func testListedButMissingOnlySessionFallsBackToFreshChat() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone")],
            open: { _ in throw self.notFound },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone"], "the dead row is not resumed again")
        XCTAssertNil(f.store.lastSessionID(for: "default"), "the dead pointer is forgotten")
        XCTAssertEqual(requests.createCalls, 1, "recovery advances to creating a fresh chat")
        XCTAssertTrue(
            f.appState.errorMessage?.hasPrefix("Failed to create session:") == true,
            "no transport in the test, so the create itself fails"
        )
        XCTAssertEqual(f.scheduler.scheduledCount, 1, "only the failed create remains retryable")
    }

    func testSavedSessionNotInCatalogWhoseFallbackIsAlsoMissingTriesNextRow() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("stale"), session("good")],
            open: { id in
                if id == "gone" || id == "stale" { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "stale", "good"])
        XCTAssertEqual(f.appState.activeSessionId, "good")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertNil(f.appState.errorMessage)
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    /// The compact resume and the dashboard history fetch run concurrently
    /// and the resume RPC is awaited first, so its 4007 throws (and sets the
    /// not-found flag) whatever the history route answers: a REST 404
    /// "Session not found" does not bypass the recovery.
    func testDashboardHistory404WithResume4007StillRecovers() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                return self.resumed(id)
            },
            persistedTranscript: { id, _, _ in
                id == "gone"
                    ? .failed(DashboardTicketBridgeError.http(status: 404, detail: "Session not found"))
                    : .unavailable
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(
            requests.ids,
            ["gone", "other", "other"],
            "the dead row once; the fallback twice (compact, then the legacy re-resume its .unavailable history asks for)"
        )
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertNil(f.appState.errorMessage)
    }

    // MARK: - Probe cap, dead-row memory, fresh-chat success

    private func deadCatalog(_ count: Int) -> [SessionSummary] {
        (0..<count).map { session("r\($0)") }
    }

    func testDeadRowWalkIsCappedThenCreatesFreshChat() async {
        let requests = Requests()
        requests.create = { "new-1" }
        let f = makeFixture(
            saved: "r0",
            catalog: deadCatalog(6),
            open: { _ in throw self.notFound },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["r0", "r1", "r2", "r3"], "the dead target plus at most 3 probes, then create")
        XCTAssertEqual(requests.createCalls, 1)
        XCTAssertEqual(
            requests.turnStateDuringCreate,
            [.synchronizing],
            "the fresh chat's create is a reconciliation: the composer and New Chat wait for it"
        )
        XCTAssertEqual(f.appState.activeSessionId, "new-1")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertNotEqual(f.store.lastSessionID(for: "default"), "r0", "the dead pointer is forgotten")
        XCTAssertEqual(f.appState.turnState, .idle)
        XCTAssertNil(f.appState.errorMessage)
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    func testRetryAfterFailedCreateDoesNotReprobeDeadRows() async {
        struct NoNetwork: Error {}
        let requests = Requests()
        requests.create = { throw NoNetwork() }
        let f = makeFixture(
            saved: "r0",
            catalog: deadCatalog(6),
            open: { _ in throw self.notFound },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["r0", "r1", "r2", "r3"])
        XCTAssertTrue(f.appState.errorMessage?.hasPrefix("Failed to create session:") == true)
        XCTAssertEqual(f.scheduler.scheduledCount, 1)
        XCTAssertEqual(f.appState.turnState, .idle)

        // The scheduled retry: same automatic purpose, pointer already forgotten.
        requests.create = { "new-2" }
        await f.appState.syncSession(purpose: .automaticReturn, using: nil, automaticWorkToken: nil)

        XCTAssertEqual(Set(requests.ids).count, requests.ids.count, "no row is probed twice: \(requests.ids)")
        XCTAssertEqual(requests.ids, ["r0", "r1", "r2", "r3", "r4", "r5"])
        XCTAssertEqual(f.appState.activeSessionId, "new-2")
    }

    func testTransientFailureAfterDeadRowDoesNotCreateAndRetries() async {
        struct Transient: Error {}
        let requests = Requests()
        requests.create = { "must-not-happen" }
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("flaky"), session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                throw Transient()
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "flaky"])
        XCTAssertEqual(requests.createCalls, 0, "a transient failure is not evidence the catalog is dead")
        XCTAssertNotEqual(f.store.lastSessionID(for: "default"), "flaky", "the transient row is not forgotten")
        XCTAssertNil(f.appState.activeSessionId)
        XCTAssertEqual(f.scheduler.scheduledCount, 1, "exactly one retry")
    }

    // MARK: - Fences

    func testClientSwitchMidWalkStopsRecovery() async {
        let requests = Requests()
        requests.create = { "must-not-happen" }
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("d1"), session("good")],
            open: { _ in throw self.notFound },
            requests: requests
        )
        requests.onOpen = { id in
            guard id == "d1" else { return }
            requests.appState?.client = HermesClient(
                connection: HermesConnection(baseUrl: "https://two.example", ticket: "t2"),
                profile: "default"
            )
        }

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "d1"], "nothing is probed or created for the replaced client")
        XCTAssertEqual(requests.createCalls, 0)
        XCTAssertEqual(f.scheduler.scheduledCount, 0, "the new client owns its own recovery")
        XCTAssertNil(f.appState.activeSessionId)
    }

    func testNewReconciliationTakingOverMidWalkStopsRecovery() async {
        let requests = Requests()
        requests.create = { "must-not-happen" }
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("d1"), session("good")],
            open: { _ in throw self.notFound },
            requests: requests
        )
        // An explicit open or New Chat begins its own reconciliation.
        requests.onOpen = { id in
            if id == "d1" { _ = requests.appState?.beginReconciliation() }
        }

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "d1"])
        XCTAssertEqual(requests.createCalls, 0)
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    // MARK: - Unchanged behavior

    /// Control: the existing recovery for a saved session the catalog omits
    /// already works with the saved copy up.
    func testSavedSessionAbsentFromCatalogRecoversWithSavedCopyUp() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["gone", "other"])
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertNil(f.appState.offlineChatPresentation)
        XCTAssertEqual(f.scheduler.scheduledCount, 0)
    }

    func testTransientResumeFailureOnListedSessionKeepsPointerAndRetries() async {
        struct Transient: Error {}
        let requests = Requests()
        let f = makeFixture(
            saved: "kept",
            catalog: [session("kept"), session("other")],
            open: { _ in throw Transient() },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["kept"])
        XCTAssertEqual(f.store.lastSessionID(for: "default"), "kept", "only an authoritative not-found retires the pointer")
        XCTAssertEqual(f.scheduler.scheduledCount, 1)
        XCTAssertNotNil(f.appState.offlineChatPresentation)
    }

    func testOtherRpcCodeOnListedSessionIsNotAuthoritativeNotFound() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "kept",
            catalog: [session("kept"), session("other")],
            open: { _ in throw RpcError(code: 4001, message: "session not found") },
            requests: requests
        )

        await coldLaunchSync(f)

        XCTAssertEqual(requests.ids, ["kept"], "only session.resume 4007 is authoritative")
        XCTAssertEqual(f.store.lastSessionID(for: "default"), "kept")
        XCTAssertEqual(f.scheduler.scheduledCount, 1)
    }

    func testOpeningAnotherSessionFromSidebarWorksWhileSavedCopyIsUp() async {
        let requests = Requests()
        let f = makeFixture(
            saved: "gone",
            catalog: [session("gone"), session("other")],
            open: { id in
                if id == "gone" { throw self.notFound }
                return self.resumed(id)
            },
            requests: requests
        )
        f.appState.isConnected = true
        f.appState.sessions = [session("gone"), session("other")]

        let opened = await f.appState.requestOpenSession("other").value

        XCTAssertTrue(opened)
        XCTAssertEqual(f.appState.activeSessionId, "other")
        XCTAssertNil(f.appState.offlineChatPresentation)
    }

    // MARK: - New Chat while the saved copy is up

    /// The saved copy does not lock New Chat out once the gateway is live:
    /// with the client connected, New Chat can still be tapped (it waits for
    /// the chat on screen to settle, then creates its own).
    func testNewChatCanBeTappedWhileSavedCopyIsUpAndConnected() throws {
        let suite = "MissingSessionRecoveryTests.newChat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(
            id: UUID(),
            label: "One",
            normalizedURL: "https://one.example"
        )
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.showLogin = false
        appState.offlineChatCacheForTesting.record(
            dashboardID: dashboard.id,
            profile: "default",
            sessionID: "saved",
            title: "Saved",
            messages: [ChatMessage(id: "c1", role: .user, content: "cached", timestamp: "1")],
            sessions: [session("saved")]
        )
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard.id)
        XCTAssertNotNil(appState.offlineChatPresentation, "precondition: the saved copy is on screen")

        let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true

        XCTAssertNotNil(appState.offlineChatPresentation)
        XCTAssertTrue(appState.canTapNewChat, "connected: the saved copy does not disable New Chat")
    }
}
