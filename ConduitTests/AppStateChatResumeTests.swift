import XCTest
@testable import Conduit

@MainActor
final class AppStateChatResumeTests: XCTestCase {
    func testStaleReconciliationCannotPublishNewerAutomaticRestoration() {
        let harness = makeHarness(behavior: .latestActivity)
        let catalog = [session("stored-b"), session("stored-a")]
        harness.appState.sessions = catalog
        harness.appState.activeSessionId = "stored-a"

        let staleToken = harness.appState.beginReconciliation()
        let staleTarget = harness.appState.selectChatResumeTarget(
            in: catalog,
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        harness.appState.activeSessionId = staleTarget?.id

        let currentToken = harness.appState.beginReconciliation()
        _ = harness.appState.selectChatResumeTarget(
            in: catalog,
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: staleTarget?.id
        )

        XCTAssertFalse(harness.appState.settleReconciliationAndPublish(staleToken))
        XCTAssertNil(harness.appState.chatResumeRestorationRequest)

        XCTAssertTrue(harness.appState.settleReconciliationAndPublish(currentToken))
        XCTAssertEqual(harness.appState.chatResumeRestorationRequest?.sessionKey.sessionID, "stored-b")
    }

    func testSecondAutomaticReturnImmediatelySupersedesPublishedGeneration() {
        let harness = makeHarness(behavior: .latestActivity)
        let catalog = [session("stored-b"), session("stored-a")]
        harness.appState.sessions = catalog
        harness.appState.activeSessionId = "stored-a"

        let firstToken = harness.appState.beginReconciliation()
        let firstTarget = harness.appState.selectChatResumeTarget(
            in: catalog,
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        harness.appState.activeSessionId = firstTarget?.id
        XCTAssertTrue(harness.appState.settleReconciliationAndPublish(firstToken))
        let firstRequest = harness.appState.chatResumeRestorationRequest!

        let secondToken = harness.appState.beginReconciliation()
        _ = harness.appState.selectChatResumeTarget(
            in: catalog,
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: firstTarget?.id
        )

        XCTAssertNil(harness.appState.chatResumeRestorationRequest)
        XCTAssertFalse(harness.coordinator.isCurrent(generation: firstRequest.generation))

        XCTAssertTrue(harness.appState.settleReconciliationAndPublish(secondToken))
        XCTAssertGreaterThan(
            harness.appState.chatResumeRestorationRequest!.generation,
            firstRequest.generation
        )
    }

    func testCatalogFailureRetainsAutomaticPurposeForRetry() {
        let harness = makeHarness(behavior: .latestActivity)
        let catalog = [session("stored-b"), session("stored-a")]

        XCTAssertEqual(
            harness.appState.beginChatResumeRecovery(purpose: .automaticReturn),
            .automaticReturn
        )
        XCTAssertEqual(
            harness.appState.planChatResumeReconnect(purpose: .preserveCurrent),
            .schedule(.automaticReturn)
        )

        let selected = harness.appState.selectChatResumeTarget(
            in: catalog,
            profile: "default",
            purpose: harness.recoverySequence.currentPurpose,
            currentSessionID: "stored-a"
        )
        XCTAssertEqual(selected?.id, "stored-b")
    }

    func testDisconnectDuringAutomaticReconnectKeepsLatestActivityPurpose() {
        let harness = makeHarness(behavior: .latestActivity)
        let catalog = [session("stored-b"), session("stored-a")]
        _ = harness.appState.beginChatResumeRecovery(purpose: .automaticReturn)

        let retryPurpose = harness.appState.chatResumePurposeForDisconnect()
        let selected = harness.appState.selectChatResumeTarget(
            in: catalog,
            profile: "default",
            purpose: retryPurpose,
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(retryPurpose, .automaticReturn)
        XCTAssertEqual(selected?.id, "stored-b")
    }

    func testAutomaticRetryReplacesQueuedPreserveCurrentRetry() {
        let harness = makeHarness()

        XCTAssertEqual(
            harness.appState.planChatResumeReconnect(purpose: .preserveCurrent),
            .schedule(.preserveCurrent)
        )
        _ = harness.appState.beginChatResumeRecovery(purpose: .automaticReturn)

        XCTAssertEqual(
            harness.appState.planChatResumeReconnect(purpose: .automaticReturn),
            .replace(.automaticReturn)
        )
        XCTAssertEqual(harness.recoverySequence.queuedReconnectPurpose, .automaticReturn)
    }

    func testCreatedFallbackRemainsFrozenAndPublishesAfterSettlement() {
        let harness = makeHarness()
        let oldKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let oldReading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
        harness.coordinator.rememberSessionID("stored-a", for: "default")
        harness.appState.recordChatViewport(oldReading, for: oldKey)
        harness.coordinator.freezeViewport()

        let token = harness.appState.beginReconciliation()
        XCTAssertNil(harness.appState.selectChatResumeTarget(
            in: [],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        ))
        harness.appState.recordChatViewport(.latest, for: oldKey)

        let created = session("stored-created")
        harness.appState.sessions = [created]
        harness.appState.activeSessionId = created.id
        _ = harness.appState.selectChatResumeTarget(
            in: [created],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: created.id
        )

        XCTAssertTrue(harness.appState.settleReconciliationAndPublish(token))
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: oldKey), oldReading)
        XCTAssertEqual(harness.appState.chatResumeRestorationRequest?.destination, .latest)
    }

    func testServerChangeClearsServerScopedResumeAndSessionCaches() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "same-session")

        XCTAssertFalse(harness.appState.prepareChatResumeForConnection(to: "https://one.example"))
        harness.coordinator.rememberSessionID("same-session", for: "default")
        harness.coordinator.recordViewport(
            ChatScrollSnapshot(anchorMessageID: "server-one-anchor", followsLatest: false),
            for: key
        )
        harness.coordinator.flush()
        harness.appState.sessions = [session("same-session")]
        harness.appState.activeSessionId = "same-session"

        XCTAssertTrue(harness.appState.prepareChatResumeForConnection(to: "https://two.example"))
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
        XCTAssertNil(harness.store.snapshot(for: key))
        XCTAssertNil(harness.appState.activeSessionId)
        XCTAssertTrue(harness.appState.sessions.isEmpty)
        XCTAssertEqual(harness.cacheClearSpy.count, 1)
    }

    func testEquivalentNormalizedServerKeepsResumeState() {
        let harness = makeHarness()
        XCTAssertFalse(harness.appState.prepareChatResumeForConnection(to: "https://one.example"))
        harness.coordinator.rememberSessionID("stored-a", for: "default")

        XCTAssertFalse(harness.appState.prepareChatResumeForConnection(to: "https://one.example/"))
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-a")
        XCTAssertEqual(harness.cacheClearSpy.count, 0)
    }

    func testLegacyDashboardIdentityGuardsFirstServerChange() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "same-session")
        harness.defaults.set("https://one.example", forKey: "conduit.dashboardURL")
        harness.coordinator.rememberSessionID("same-session", for: "default")
        harness.coordinator.recordViewport(.latest, for: key)
        harness.coordinator.flush()

        XCTAssertTrue(harness.appState.prepareChatResumeForConnection(to: "https://two.example"))
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
        XCTAssertNil(harness.store.snapshot(for: key))
    }

    func testManualRecoveryOverridesPendingAutomaticPurpose() async {
        let harness = makeHarness(behavior: .latestActivity)
        _ = harness.appState.beginChatResumeRecovery(purpose: .automaticReturn)

        await harness.appState.syncSession()

        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent)
    }

    func testAppStateRestoresDeviceLocalSessionIDPerProfile() {
        let harness = makeHarness()
        harness.store.setLastSessionID("default-session", for: "default")
        harness.store.setLastSessionID("work-session", for: "work")
        harness.defaults.set("work", forKey: "conduit.activeProfile")

        let recreated = AppState(
            defaults: harness.defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {}
        )
        XCTAssertEqual(recreated.activeSessionId, "work-session")

        recreated.restoreActiveSessionState(for: "default")
        XCTAssertEqual(recreated.activeSessionId, "default-session")
    }

    func testAcceptedBranchCancelsPendingRestoration() {
        let harness = makeHarness()
        let request = publishRestoration(in: harness)

        harness.appState.acceptChatResumeConversationReplacement(.branch)

        assertRestorationCancelled(request, in: harness)
    }

    func testAcceptedArchiveOfActiveSessionCancelsPendingRestoration() {
        let harness = makeHarness()
        let active = session("stored-a")
        let request = publishRestoration(in: harness, session: active)

        harness.appState.clearActiveSessionIfNeeded(active, replacement: .archive)

        assertRestorationCancelled(request, in: harness)
        XCTAssertNil(harness.appState.activeSessionId)
    }

    func testAcceptedDeleteOfActiveSessionCancelsPendingRestoration() {
        let harness = makeHarness()
        let active = session("stored-a")
        let request = publishRestoration(in: harness, session: active)

        harness.appState.clearActiveSessionIfNeeded(active, replacement: .delete)

        assertRestorationCancelled(request, in: harness)
        XCTAssertNil(harness.appState.activeSessionId)
    }

    private func makeHarness(
        behavior: ChatResumeBehavior = .continueWhereLeftOff
    ) -> (
        appState: AppState,
        coordinator: ChatResumeCoordinator,
        store: ChatResumeStore,
        recoverySequence: ChatResumeRecoverySequence,
        cacheClearSpy: CacheClearSpy,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "AppStateChatResumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(behavior)
        let coordinator = ChatResumeCoordinator(store: store)
        let recoverySequence = ChatResumeRecoverySequence()
        let cacheClearSpy = CacheClearSpy()
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: recoverySequence,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cacheClearSpy.count += 1 }
        )
        return (appState, coordinator, store, recoverySequence, cacheClearSpy, defaults, suite)
    }

    private func publishRestoration(
        in harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence,
            cacheClearSpy: CacheClearSpy,
            defaults: UserDefaults,
            suite: String
        ),
        session active: SessionSummary? = nil
    ) -> ChatResumeRestorationRequest {
        let active = active ?? session("stored-a")
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let token = harness.appState.beginReconciliation()
        _ = harness.appState.selectChatResumeTarget(
            in: [active],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: active.id
        )
        XCTAssertTrue(harness.appState.settleReconciliationAndPublish(token))
        return harness.appState.chatResumeRestorationRequest!
    }

    private func assertRestorationCancelled(
        _ request: ChatResumeRestorationRequest,
        in harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence,
            cacheClearSpy: CacheClearSpy,
            defaults: UserDefaults,
            suite: String
        ),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(harness.appState.chatResumeRestorationRequest, file: file, line: line)
        XCTAssertFalse(
            harness.coordinator.isCurrent(generation: request.generation),
            file: file,
            line: line
        )
    }

    private func session(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
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
}

@MainActor
private final class CacheClearSpy {
    var count = 0
}
