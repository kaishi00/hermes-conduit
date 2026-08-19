import XCTest
@testable import Conduit

@MainActor
final class ChatReturnSurfaceTests: XCTestCase {
    func testDefaultConversationPreferenceIssuesNoReturnSurfaceRequest() {
        let harness = makeHarness()

        XCTAssertEqual(harness.appState.chatReturnSurface, .conversation)
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)

        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 0)
        XCTAssertFalse(harness.appState.showSidebar)
    }

    func testSessionsPreferenceOnColdLaunchRequestsDrawer() {
        let harness = makeHarness(surface: .sessions)

        // Cold launch reads the persisted preference, and MainView's
        // first-appearance task issues the one-shot request.
        XCTAssertEqual(harness.appState.chatReturnSurface, .sessions)
        harness.appState.requestPreferredReturnSurface()

        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 1)
    }

    func testSessionsPreferenceOnBackgroundToActiveRequestsDrawer() {
        let harness = makeHarness(surface: .sessions)
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )

        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)

        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 1)
    }

    func testBackgroundToActiveWhileSignedOutDoesNotLeakIntoNextSignIn() {
        let harness = makeHarness(surface: .sessions)

        // A background → active cycle on the login screen must consume the
        // arming without issuing: signing back in is not a qualifying return.
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 0)

        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 0)

        // The next genuine authenticated return does request the drawer.
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 1)
    }

    func testColdLaunchRequestFiresOnlyOncePerProcess() {
        let harness = makeHarness(surface: .sessions)

        harness.appState.requestPreferredReturnSurfaceForColdLaunch()
        harness.appState.requestPreferredReturnSurfaceForColdLaunch()

        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 1)
    }

    func testInactiveToActiveAloneDoesNotRequestDrawer() {
        let harness = makeHarness(surface: .sessions)

        harness.appState.handleScenePhase(.inactive)
        harness.appState.handleScenePhase(.active)
        // A second inactive → active cycle (Control Center twice) still
        // must not count as reopening the app.
        harness.appState.handleScenePhase(.inactive)
        harness.appState.handleScenePhase(.active)

        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 0)
    }

    func testSessionsWithContinueBehaviorStillRestoresSavedSessionUnderneath() {
        let harness = makeHarness(behavior: .continueWhereLeftOff, surface: .sessions)
        let saved = session("stored-saved")
        let other = session("stored-other")
        harness.coordinator.rememberSessionID(saved.id, for: "default")
        harness.appState.sessions = [other, saved]
        // Continue-where-left-off returns into the remembered session.
        harness.appState.activeSessionId = saved.id

        let token = harness.appState.beginReconciliation()
        let target = harness.appState.selectChatResumeTarget(
            in: [other, saved],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: saved.id
        )
        XCTAssertTrue(harness.appState.settleReconciliationAndPublish(token))
        XCTAssertEqual(target?.id, saved.id)
        XCTAssertEqual(
            harness.appState.chatResumeRestorationRequest?.sessionKey.sessionID,
            saved.id
        )

        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 1)
    }

    func testSessionsWithLatestActivityStillResolvesLatestChatUnderneath() {
        let harness = makeHarness(behavior: .latestActivity, surface: .sessions)
        let olderChat = session("stored-old-chat")
        let newestChat = session("stored-new-chat")
        let cronEntry = session("stored-cron", source: .cron)
        // Latest-activity ignores the remembered ID and picks the first chat
        // entry of the automatic-return catalog, which is newest-first.
        harness.coordinator.rememberSessionID(olderChat.id, for: "default")
        harness.appState.sessions = [newestChat, cronEntry, olderChat]
        harness.appState.activeSessionId = newestChat.id

        let token = harness.appState.beginReconciliation()
        let target = harness.appState.selectChatResumeTarget(
            in: [newestChat, cronEntry, olderChat],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: newestChat.id
        )
        XCTAssertTrue(harness.appState.settleReconciliationAndPublish(token))
        XCTAssertEqual(target?.id, newestChat.id)
        XCTAssertEqual(
            harness.appState.chatResumeRestorationRequest?.sessionKey.sessionID,
            newestChat.id
        )

        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 1)
    }

    func testNotificationOpenSuppressesPreferredReturnSurfaceRequest() async {
        let catalogGate = ReturnSurfaceSuspension()
        let harness = makeHarness(
            surface: .sessions,
            reconnectScheduler: ReturnSurfaceReconnectScheduler().schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    await catalogGate.suspend()
                    return [self.session("stored-a")]
                },
                mintTicket: { _ in throw ReturnSurfaceTestError.mintUnavailable },
                openSession: { _, sessionID in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(id: "m", role: .assistant, content: "Hi", timestamp: "1")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let notificationTask = Task { @MainActor in
            await harness.appState.openNotificationTarget(
                ConduitNotificationTarget(profile: nil, sessionId: "stored-a", type: nil)
            )
        }
        await catalogGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isOpeningNotificationSession)

        // The user returns to the foreground while the notification open is
        // in flight: explicit navigation wins, no drawer request is issued.
        harness.appState.handleScenePhase(.background)
        let sceneTask = harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 0)

        catalogGate.resume()
        let opened = await notificationTask.value
        XCTAssertTrue(opened)
        XCTAssertFalse(harness.appState.isOpeningNotificationSession)
        _ = await sceneTask?.value
    }

    func testActiveModalSheetsSuppressReturnSurfaceRequest() {
        let harness = makeHarness(surface: .sessions)
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )

        harness.appState.showModelPicker = true
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 0)

        harness.appState.showModelPicker = false
        harness.appState.isSettingsSheetPresented = true
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 0)

        // Once no modal owns the surface, the next qualifying return asks again.
        harness.appState.isSettingsSheetPresented = false
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 1)
    }

    func testSelectingSessionFromDrawerUsesNormalOpenFlowAndStaysClosed() async {
        let harness = makeHarness(
            surface: .sessions,
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(id: "m", role: .assistant, content: "Hi", timestamp: "1")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        let target = session("stored-a")
        harness.appState.sessions = [target]
        harness.appState.activeSessionId = target.id
        harness.appState.showSidebar = true

        // Mirrors the SidebarView row action: the drawer dismisses itself
        // (existing view behavior), then the existing explicit session-open
        // flow runs and must not re-open the drawer.
        harness.appState.showSidebar = false
        let opened = await harness.appState.requestOpenSession(target.id).value

        XCTAssertTrue(opened)
        XCTAssertFalse(harness.appState.showSidebar)
        XCTAssertEqual(harness.appState.activeSessionId, target.id)
    }

    func testChangingReturnSurfaceSettingDoesNotImmediatelyPresentDrawer() {
        let harness = makeHarness()

        harness.appState.setChatReturnSurface(.sessions)

        XCTAssertEqual(harness.appState.chatReturnSurface, .sessions)
        XCTAssertEqual(harness.appState.preferredReturnSurfaceRequest, 0)
        XCTAssertFalse(harness.appState.showSidebar)
        XCTAssertEqual(
            harness.defaults.string(forKey: AppState.chatReturnSurfaceKey),
            ChatReturnSurface.sessions.rawValue
        )
    }

    func testReturnSurfacePreferencePersistsAcrossAppStateInstances() {
        let harness = makeHarness(surface: .sessions)

        harness.appState.setChatReturnSurface(.conversation)
        let reloaded = AppState(
            defaults: harness.defaults,
            loadSavedConnection: false
        )
        XCTAssertEqual(reloaded.chatReturnSurface, .conversation)

        reloaded.setChatReturnSurface(.sessions)
        XCTAssertEqual(
            harness.defaults.string(forKey: AppState.chatReturnSurfaceKey),
            ChatReturnSurface.sessions.rawValue
        )
    }

    func testInvalidPersistedReturnSurfaceFallsBackToConversation() {
        let harness = makeHarness(configureDefaults: { defaults in
            defaults.set("gibberish", forKey: AppState.chatReturnSurfaceKey)
        })

        XCTAssertEqual(harness.appState.chatReturnSurface, .conversation)
    }

    func testSettingsSnapshotCarriesReturnSurface() {
        let harness = makeHarness(surface: .sessions)

        let snapshot = harness.appState.makeSettingsSnapshot()

        XCTAssertEqual(snapshot.chatReturnSurface, .sessions)
        XCTAssertEqual(snapshot.chatResumeBehavior, .continueWhereLeftOff)
    }

    func testReturnSurfacePreferenceDoesNotTouchResumeStoreSchema() {
        let harness = makeHarness(surface: .sessions)
        // The store persists its initial payload at init; the preference
        // must leave that payload byte-for-byte untouched.
        let payloadBefore = harness.defaults.data(forKey: ChatResumeStore.defaultStorageKey)

        harness.appState.setChatReturnSurface(.conversation)

        XCTAssertEqual(
            harness.defaults.data(forKey: ChatResumeStore.defaultStorageKey),
            payloadBefore
        )
    }
}

@MainActor
private final class ReturnSurfaceReconnectScheduler {
    private final class Work {
        let operation: @MainActor () async -> Void
        init(operation: @escaping @MainActor () async -> Void) {
            self.operation = operation
        }
    }

    private var work: [Work] = []

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) -> ChatResumeReconnectCancellation {
        let item = Work(operation: operation)
        work.append(item)
        return {}
    }
}

private enum ReturnSurfaceTestError: Error {
    case mintUnavailable
}

@MainActor
private final class ReturnSurfaceSuspension {
    private var suspension: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspension = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard suspension == nil else { return }
        await withCheckedContinuation { continuation in
            observer = continuation
        }
    }

    func resume() {
        suspension?.resume()
        suspension = nil
    }
}

private extension ChatReturnSurfaceTests {
    func makeHarness(
        behavior: ChatResumeBehavior = .continueWhereLeftOff,
        surface: ChatReturnSurface = .conversation,
        configureDefaults: (UserDefaults) -> Void = { _ in },
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        lifecycleOperations: ChatResumeLifecycleOperations = .live
    ) -> (
        appState: AppState,
        coordinator: ChatResumeCoordinator,
        store: ChatResumeStore,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "ChatReturnSurfaceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        configureDefaults(defaults)
        if surface != .conversation {
            defaults.set(surface.rawValue, forKey: AppState.chatReturnSurfaceKey)
        }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(behavior)
        let coordinator = ChatResumeCoordinator(store: store)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            reconnectScheduler: reconnectScheduler
                ?? ReturnSurfaceReconnectScheduler().schedule(after:operation:),
            chatResumeLifecycleOperations: lifecycleOperations
        )
        return (appState, coordinator, store, defaults, suite)
    }

    func session(
        _ id: String,
        source: SessionSource = .chat
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: source,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}
