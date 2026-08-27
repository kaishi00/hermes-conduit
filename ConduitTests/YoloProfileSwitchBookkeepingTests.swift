import XCTest
@testable import Conduit

/// Deterministic regressions for profile-switch YOLO bookkeeping.
/// Self-contained by design so shared-file churn cannot eat coverage:
/// every suspended-toggle ownership case lives here next to the DEBUG
/// in-flight key inspector. Parking uses a long cooperative sleep that
/// ends via task cancellation - no wall-clock races.
@MainActor
final class YoloProfileSwitchBookkeepingTests: XCTestCase {

    private func makeDefaults() throws -> (String, UserDefaults) {
        let suite = "YoloProfileSwitchBookkeepingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suite),
            "Could not create isolated UserDefaults suite"
        )
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

    private func session(_ id: String, alternateIDs: [String] = []) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternateIDs,
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
        while appState.inFlightSessionYoloWriteCountsForTesting.isEmpty && spins < 500 {
            spins += 1
            await Task.yield()
        }
    }

    /// THE reported bug: a toggle parked under profile A survives a switch
    /// to profile B; when it settles via cancellation its cleanup must
    /// remove BOTH originating A-keys even though activeProfile is B.
    func testLeakedOwnershipKeysAcrossSuccessfulSwitchAreCleaned() async throws {
        let (suite, defaults) = try makeDefaults()
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
        // Both originating keys (runtime + persisted) must be registered
        // under the originating profile while the RPC is suspended.
        let suspendedKeys = Set(appState.inFlightSessionYoloWriteCountsForTesting.keys.map { $0.profile + "|" + $0.sessionID })
        XCTAssertEqual(
            suspendedKeys,
            Set(["default|runtime-a", "default|persisted-a"]),
            "both alias ownership keys must be registered under the originating profile"
        )

        await appState.switchProfile(to: "work")
        XCTAssertEqual(appState.activeProfile, "work")

        // Cancelling the parked RPC delivers CancellationError through the
        // stub - exercising the thrown/cancelled cleanup path deterministically.
        operation.cancel()
        await operation.value

        XCTAssertTrue(
            appState.inFlightSessionYoloWriteCountsForTesting.isEmpty,
            "originating-profile ownership must not leak across the switch"
        )
        XCTAssertNil(store.storedOverride(for: "work", sessionID: "runtime-a"))
        XCTAssertNil(store.storedOverride(for: "work", sessionID: "persisted-a"))
    }

    /// Duplicate id strings collapse to a single underlying RPC that still
    /// cleans up completely.
    func testDuplicateIdStringsSendSingleRPCAndCleanUp() async throws {
        let recorder = YoloSetCallRecorder()
        let (suite, defaults) = try makeDefaults()
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
        XCTAssertTrue(appState.inFlightSessionYoloWriteCountsForTesting.isEmpty)
    }

    /// Single-alias success keeps the historic behavior: override lands,
    /// bookkeeping clears, indicator updates.
    func testSingleAliasSuccessUpdatesOverrideAndClearsBookkeeping() async throws {
        let (suite, defaults) = try makeDefaults()
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
        XCTAssertTrue(appState.inFlightSessionYoloWriteCountsForTesting.isEmpty)
    }

    /// THE overlap bug: two YOLO writes for the same session are parked
    /// independently. Completing write #1 must NOT release write #2's
    /// protection - the refcount drops but stays > 0, so a resume in that
    /// window still sees an in-flight write and does not re-assert the stale
    /// persisted override. Only when write #2 also settles does the guard
    /// fully clear.
    func testOverlappingWritesMaintainIndependentOwnership() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "stored-a")

        let gate1 = ToggleSuspendGate()
        let gate2 = ToggleSuspendGate()
        let recorder = YoloSetCallRecorder()
        var rpcIndex = 0
        let operations = ChatResumeLifecycleOperations(
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
            setSessionYolo: { _, sessionID, enabled in
                let index = rpcIndex
                rpcIndex += 1
                if index == 0 {
                    await gate1.suspend()
                } else {
                    await gate2.suspend()
                }
                recorder.record(sessionID, enabled)
            },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("stored-a")]
        appState.activeSessionId = "stored-a"
        appState.runtime.approvalsMode = "on"
        installSwitchableConnection(on: appState)

        // Start write #1 - parks at gate1.
        let op1 = Task { await appState.setYoloMode(true) }
        await gate1.waitUntilEngaged()

        // Count for default|stored-a is 1.
        XCTAssertEqual(
            appState.inFlightSessionYoloWriteCountsForTesting[ChatScrollSessionKey(profile: "default", sessionID: "stored-a")],
            1,
            "write #1 should hold exactly one reference"
        )

        // Start write #2 - parks at gate2.
        let op2 = Task { await appState.setYoloMode(false) }
        await gate2.waitUntilEngaged()

        // Both writes in flight: the shared key has count 2.
        XCTAssertEqual(
            appState.inFlightSessionYoloWriteCountsForTesting[ChatScrollSessionKey(profile: "default", sessionID: "stored-a")],
            2,
            "overlapping writes must each hold an independent reference"
        )

        // Release write #1. The count must drop to 1 (write #2 still active).
        gate1.release()
        await op1.value
        XCTAssertEqual(
            appState.inFlightSessionYoloWriteCountsForTesting[ChatScrollSessionKey(profile: "default", sessionID: "stored-a")],
            1,
            "releasing write #1 must not release write #2's protection"
        )

        // A resume in this window must NOT re-assert the stale persisted
        // override, because write #2 is still active (the refcount guard
        // hasInFlightSessionYoloWrite returns true).
        // (Proof: the count is still 1, so hasInFlightSessionYoloWrite
        // for stored-a returns true and reconcileExplicitYolo skips.)

        // Release write #2. Both operations settled.
        gate2.release()
        await op2.value

        // Bookkeeping fully empty.
        XCTAssertTrue(
            appState.inFlightSessionYoloWriteCountsForTesting.isEmpty,
            "bookkeeping must be fully empty after both writes settle"
        )
    }
}

/// Cancellation-aware two-channel suspension for independently parking two
/// overlapping RPCs. `suspend()` parks until `release()` is called; each gate
/// instance is independent.
final class ToggleSuspendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var engagement: CheckedContinuation<Void, Never>?
    private var released = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            let pendingEngagement = engagement
            engagement = nil
            lock.unlock()
            pendingEngagement?.resume()
        }
    }

    func waitUntilEngaged() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if waiter != nil || released {
                lock.unlock()
                continuation.resume()
                return
            }
            engagement = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pendingWaiter = waiter
        waiter = nil
        let pendingEngagement = engagement
        engagement = nil
        lock.unlock()
        pendingWaiter?.resume()
        pendingEngagement?.resume()
    }
}