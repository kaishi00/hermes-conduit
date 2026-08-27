import XCTest
@testable import Conduit

/// Deterministic regressions for profile-switch YOLO bookkeeping.
/// Self-contained by design so shared-file churn cannot eat coverage:
/// every suspended-toggle ownership case lives here next to the DEBUG
/// in-flight key inspector. Parking uses a long cooperative sleep that
/// ends via task cancellation - no wall-clock races.
@MainActor
final class YoloProfileSwitchBookkeepingTests: XCTestCase {

    private func makeDefaults() -> (String, UserDefaults) {
        let suite = "YoloProfileSwitchBookkeepingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return (suite, defaults)
    }

    private func makeAppState(
        defaults: UserDefaults,
        store: SessionYoloStore,
        lifecycleOperations: ChatResumeLifecycleOperations
    ) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            sessionYoloStore: store
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

    private func installSwitchableConnection(on appState: AppState) {
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.showLogin = false
    }

    /// Behavior kinds for the stubbed per-session write RPC.
    private enum StubbedRPC {
        case succeedImmediately
        case parkUntilCancelled
        case recordAndSucceed
    }

    private final class YoloSetCallRecorder {
        private(set) var invocations: [(sessionID: String, enabled: Bool)] = []

        func record(_ sessionID: String, _ enabled: Bool) {
            invocations.append((sessionID, enabled))
        }
    }

    private func switchLifecycleOperations(
        rpc: StubbedRPC,
        recorder: YoloSetCallRecorder
    ) -> ChatResumeLifecycleOperations {
        let behavior = rpc
        return ChatResumeLifecycleOperations(
            connectClient: { _ in },
            loadCatalog: { _, _ in [] },
            mintTicket: { _ in "profile-ticket" },
            openSession: { _, sessionID in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { client, sessionID, enabled in
                switch behavior {
                case .recordAndSucceed:
                    recorder.record(sessionID, enabled)
                case .succeedImmediately:
                    break
                case .parkUntilCancelled:
                    try await Task.sleep(for: .seconds(3600))
                }
            },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )
    }

    private func spinUntilKeysRegistered(_ appState: AppState) async {
        var spins = 0
        while appState.inFlightSessionYoloWriteKeysForTesting.isEmpty && spins < 500 {
            spins += 1
            await Task.yield()
        }
    }

    /// THE reported bug: a toggle parked under profile A survives a switch
    /// to profile B; when it settles via cancellation its cleanup must
    /// remove BOTH originating A-keys even though activeProfile is B.
    func testLeakedOwnershipKeysAcrossSuccessfulSwitchAreCleaned() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "persisted-a")
        let operations = switchLifecycleOperations(
            rpc: .parkUntilCancelled,
            recorder: YoloSetCallRecorder()
        )
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("persisted-a", alternateIDs: ["runtime-a"])]
        appState.activeSessionId = "runtime-a"
        appState.runtime.approvalsMode = "on"
        installSwitchableConnection(on: appState)

        let operation = Task { await appState.setYoloMode(false) }
        await spinUntilKeysRegistered(appState)
        XCTAssertFalse(
            appState.inFlightSessionYoloWriteKeysForTesting.isEmpty,
            "the suspended write should hold its ownership keys"
        )

        await appState.switchProfile(to: "work")
        XCTAssertEqual(appState.activeProfile, "work")

        // Cancelling the parked RPC delivers CancellationError through the
        // stub - exercising the thrown/cancelled cleanup path deterministically.
        operation.cancel()
        await operation.value

        XCTAssertTrue(
            appState.inFlightSessionYoloWriteKeysForTesting.isEmpty,
            "originating-profile ownership must not leak across the switch"
        )
        XCTAssertNil(store.storedOverride(for: "work", sessionID: "runtime-a"))
        XCTAssertNil(store.storedOverride(for: "work", sessionID: "persisted-a"))
    }

    /// Duplicate id strings collapse to a single underlying RPC that still
    /// cleans up completely.
    func testDuplicateIdStringsSendSingleRPCAndCleanUp() async {
        let recorder = YoloSetCallRecorder()
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        let operations = switchLifecycleOperations(rpc: .recordAndSucceed, recorder: recorder)
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("stored-a")]
        appState.activeSessionId = "stored-a"
        appState.runtime.approvalsMode = "on"
        installSwitchableConnection(on: appState)

        let enabled = await appState.setYoloMode(true)
        XCTAssertTrue(enabled)
        XCTAssertEqual(recorder.invocations.count, 1)
        XCTAssertTrue(appState.inFlightSessionYoloWriteKeysForTesting.isEmpty)
    }

    /// Single-alias success keeps the historic behavior: override lands,
    /// bookkeeping clears, indicator updates.
    func testSingleAliasSuccessUpdatesOverrideAndClearsBookkeeping() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        let operations = switchLifecycleOperations(rpc: .succeedImmediately, recorder: YoloSetCallRecorder())
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("stored-a")]
        appState.activeSessionId = "stored-a"
        appState.runtime.approvalsMode = "on"
        installSwitchableConnection(on: appState)

        let outcome = await appState.setYoloMode(true)
        XCTAssertTrue(outcome)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "stored-a"), true)
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertTrue(appState.inFlightSessionYoloWriteKeysForTesting.isEmpty)
    }
}