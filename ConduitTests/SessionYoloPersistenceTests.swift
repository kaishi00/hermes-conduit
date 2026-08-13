import XCTest
@testable import Conduit

@MainActor
final class SessionYoloPersistenceTests: XCTestCase {
    func testStoredOverrideWinsOverLaterProfileApprovalSnapshotAndSurvivesRelaunch() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "canonical-session")

        let first = makeAppState(defaults: defaults, store: store)
        first.sessions = [session("canonical-session", alternateIDs: ["runtime-session"])]
        first.applyChatResume(SessionResumeResult(
            sessionId: "runtime-session",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("on")
            ])
        ))

        XCTAssertTrue(first.runtime.yolo)

        let recreatedStore = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        let relaunched = makeAppState(defaults: defaults, store: recreatedStore)
        relaunched.sessions = [session("canonical-session", alternateIDs: ["runtime-session"])]
        relaunched.applyChatResume(SessionResumeResult(
            sessionId: "runtime-session",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("on")
            ])
        ))

        XCTAssertTrue(relaunched.runtime.yolo)
    }

    func testRuntimeIDOverrideRemainsVisibleAfterCatalogProvidesCanonicalID() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "runtime-session")

        let appState = makeAppState(defaults: defaults, store: store)
        appState.sessions = [session("canonical-session", alternateIDs: ["runtime-session"])]
        appState.applyChatResume(SessionResumeResult(
            sessionId: "runtime-session",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("on")
            ])
        ))

        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "canonical-session"), true)
        XCTAssertNil(store.storedOverride(for: "default", sessionID: "runtime-session"))
    }

    func testExplicitGatewayYoloReplacesConflictingLocalOverride() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "session-a")

        let appState = makeAppState(defaults: defaults, store: store)
        appState.sessions = [session("session-a")]
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "yolo": .bool(false),
                "approvals_mode": .string("on")
            ])
        ))

        XCTAssertFalse(appState.runtime.yolo)
        XCTAssertNil(store.storedOverride(for: "default", sessionID: "session-a"))
    }

    func testServerSessionYoloWinsOverProfileApprovalFallbackWhenNoOverrideExists() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        let appState = makeAppState(defaults: defaults, store: store)
        appState.sessions = [session("session-a")]

        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "yolo": .bool(false),
                "approvals_mode": .string("off")
            ])
        ))

        XCTAssertFalse(appState.runtime.yolo)

        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("off")
            ])
        ))

        XCTAssertTrue(appState.runtime.yolo)
    }

    func testSwitchingSessionsRecomputesTheSessionSpecificOverride() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "session-a")
        let appState = makeAppState(defaults: defaults, store: store)
        appState.sessions = [session("session-a"), session("session-b")]

        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("on")
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)

        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-b",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("on")
            ])
        ))
        XCTAssertFalse(appState.runtime.yolo)

        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("on")
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)
    }

    func testSuccessfulSessionYoloChangePersistsOnlyAfterGatewaySuccess() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        let operations = ChatResumeLifecycleOperations(
            setSessionYolo: { _, _, _ in }
        )
        let appState = makeAppState(
            defaults: defaults,
            store: store,
            lifecycleOperations: operations
        )
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let enabled = await appState.setYoloMode(true)
        XCTAssertTrue(enabled)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
        XCTAssertTrue(appState.runtime.yolo)

        let disabled = await appState.setYoloMode(false)
        XCTAssertTrue(disabled)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), false)
        XCTAssertFalse(appState.runtime.yolo)
    }

    func testFailedSessionYoloChangeDoesNotPersistOrChangeRuntime() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        let operations = ChatResumeLifecycleOperations(
            setSessionYolo: { _, _, _ in throw TestError.rejected }
        )
        let appState = makeAppState(
            defaults: defaults,
            store: store,
            lifecycleOperations: operations
        )
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let enabled = await appState.setYoloMode(true)
        XCTAssertFalse(enabled)
        XCTAssertNil(store.storedOverride(for: "default", sessionID: "session-a"))
        XCTAssertFalse(appState.runtime.yolo)
    }

    private func makeAppState(
        defaults: UserDefaults,
        store: SessionYoloStore,
        lifecycleOperations: ChatResumeLifecycleOperations = ChatResumeLifecycleOperations()
    ) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            sessionYoloStore: store
        )
    }

    private func session(
        _ id: String,
        alternateIDs: [String] = [],
        profile: String = "default"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternateIDs,
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suite = "SessionYoloPersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create isolated UserDefaults suite")
        }
        return (suite, defaults)
    }
}

private enum TestError: Error {
    case rejected
}
