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

    // The Hermes gateway holds the per-session YOLO flag in memory only and
    // forgets it on resume, so a resume snapshot's `yolo` is the reverted
    // profile default rather than an authoritative value. The local override
    // must survive a conflicting resume snapshot (AppState re-asserts it).
    func testExplicitGatewayYoloDoesNotReplaceConflictingLocalOverride() {
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

        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
    }

    // With no per-session override, the snapshot's `yolo` wins while the
    // profile approval mode is not "off"; once the profile is "off", the global
    // floor forces auto-approve regardless of the snapshot.
    func testNoOverrideFallsBackToSnapshotThenGlobalFloor() {
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
                "approvals_mode": .string("manual")
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

    func testStaleLiveSessionInfoCannotClearJustPersistedOverride() async {
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

        appState.handleStreamEvent(.sessionInfo(
            sessionId: "session-a",
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "yolo": .bool(false),
                "approvals_mode": .string("on")
            ])
        ))

        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
    }

    func testStaleResumeSnapshotCannotClearJustPersistedOverride() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let openGate = SessionYoloResumeGate()
        let operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("session-a")] },
            openSession: { _, sessionID in
                await openGate.suspend()
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "yolo": .bool(false),
                        "approvals_mode": .string("on")
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, _, _ in }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
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

        let resume = Task { @MainActor in
            await appState.syncSession()
        }
        await openGate.waitUntilSuspended()

        let enabled = await appState.setYoloMode(true)
        XCTAssertTrue(enabled)

        openGate.resume()
        await resume.value

        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
    }

    // A buffered live `session.info` that predates a resume must not overwrite
    // the retained per-session override. The override survives the stale
    // buffered event, and AppState re-asserts it once the resume settles.
    func testBufferedSessionInfoDoesNotOverwriteRetainedOverride() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let openGate = SessionYoloResumeGate()
        let recorder = YoloSetCallRecorder()
        let operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("session-a")] },
            openSession: { _, sessionID in
                await openGate.suspend()
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "yolo": .bool(false),
                        "approvals_mode": .string("on")
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "session-a")
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

        let resume = Task { @MainActor in
            await appState.syncSession()
        }
        await openGate.waitUntilSuspended()

        appState.handleStreamEvent(.sessionInfo(
            sessionId: "session-a",
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "yolo": .bool(true),
                "approvals_mode": .string("on")
            ])
        ))

        openGate.resume()
        await resume.value

        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
        XCTAssertEqual(recorder.invocations.count, 1)
        XCTAssertEqual(recorder.invocations.first?.enabled, true)
    }

    func testBufferedConflictingSessionInfoPreservesNonYoloRuntimeFields() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let openGate = SessionYoloResumeGate()
        let operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("session-a")] },
            openSession: { _, sessionID in
                await openGate.suspend()
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "model": .string("resume-model"),
                        "provider": .string("resume-provider"),
                        "context_percent": .number(10),
                        "yolo": .bool(false)
                    ])
                )
            },
            refreshContext: { _, _ in }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
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

        let resume = Task { @MainActor in
            await appState.syncSession()
        }
        await openGate.waitUntilSuspended()

        appState.handleStreamEvent(.sessionInfo(
            sessionId: "session-a",
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(true),
                "model": .string("buffered-model"),
                "provider": .string("buffered-provider"),
                "context_percent": .number(42),
                "yolo": .bool(true)
            ])
        ))

        openGate.resume()
        await resume.value

        XCTAssertFalse(appState.runtime.yolo)
        XCTAssertEqual(appState.runtime.model, "buffered-model")
        XCTAssertEqual(appState.runtime.provider, "buffered-provider")
        XCTAssertEqual(appState.runtime.contextPercent, 42)
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

    // MARK: - Global approval floor (approvals.mode == "off")

    func testGlobalApprovalOffForcesIndicatorYoloDespiteSessionOverrideOff() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(false, for: "default", sessionID: "session-a")

        let appState = makeAppState(defaults: defaults, store: store)
        appState.sessions = [session("session-a")]
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "yolo": .bool(true),
                "approvals_mode": .string("off")
            ])
        ))

        // Hermes auto-approves globally under approvals.mode == "off"; the
        // indicator must reflect that effective state, not the stale override.
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(appState.runtime.approvalsMode, "off")
        // The override is retained so it applies again if the profile changes.
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), false)
    }

    func testApprovalModeChangeOffThenManualRestoresOverrideEffect() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(false, for: "default", sessionID: "session-a")

        let appState = makeAppState(defaults: defaults, store: store)
        appState.sessions = [session("session-a")]
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("off")
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)

        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("manual")
            ])
        ))
        // Floor gone; the retained per-session override (off) takes effect.
        XCTAssertFalse(appState.runtime.yolo)
    }

    // MARK: - Resume re-assertion (gateway forgets the in-memory session flag)

    func testResumeReassertsSessionYoloWhenGatewayForgot() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = YoloSetCallRecorder()
        let operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("session-a")] },
            openSession: { _, sessionID in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "yolo": .bool(false),
                        "approvals_mode": .string("manual")
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "session-a")
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await appState.syncSession()

        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
        XCTAssertEqual(recorder.invocations.count, 1)
        XCTAssertEqual(recorder.invocations.first?.enabled, true)
    }

    func testResumeSkipsReassertWhenServerAlreadyAgrees() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = YoloSetCallRecorder()
        let operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("session-a")] },
            openSession: { _, sessionID in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "yolo": .bool(true),
                        "approvals_mode": .string("manual")
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "session-a")
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await appState.syncSession()

        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
        // The server already reports the override value; no re-assert needed.
        XCTAssertTrue(recorder.invocations.isEmpty)
    }

    func testResumeSkipsReassertUnderGlobalOff() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = YoloSetCallRecorder()
        let operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("session-a")] },
            openSession: { _, sessionID in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "yolo": .bool(true),
                        "approvals_mode": .string("off")
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "session-a")
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await appState.syncSession()

        // Global floor forces auto-approve; per-session re-assert is moot.
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
        XCTAssertTrue(recorder.invocations.isEmpty)
    }

    func testResumeReassertFailureIsNonFatal() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("session-a")] },
            openSession: { _, sessionID in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "yolo": .bool(false),
                        "approvals_mode": .string("manual")
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, _, _ in throw TestError.rejected }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "session-a")
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await appState.syncSession()

        // The re-assert failed, but the resume still settled and the local
        // override continues to govern the indicator.
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
    }

    // A profile or client switch during the suspending context refresh makes
    // the reconciliation stale. The recovery write must abort: re-asserting
    // through the old client could otherwise apply the wrong profile's
    // override to the old profile's session.
    func testResumeSkipsReassertWhenClientIsReplacedDuringContextRefresh() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let refreshGate = SessionYoloResumeGate()
        let recorder = YoloSetCallRecorder()
        let operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("session-a")] },
            openSession: { _, sessionID in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "yolo": .bool(false),
                        "approvals_mode": .string("manual")
                    ])
                )
            },
            refreshContext: { _, _ in await refreshGate.suspend() },
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "session-a")
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let resume = Task { @MainActor in
            await appState.syncSession()
        }
        await refreshGate.waitUntilSuspended()

        // Simulate a reconnect replacing the client while the context refresh
        // is suspended; the in-flight reconciliation becomes stale.
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://two.example", ticket: "ticket"),
            profile: "default"
        )

        refreshGate.resume()
        await resume.value

        XCTAssertTrue(recorder.invocations.isEmpty)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
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

@MainActor
private final class SessionYoloResumeGate {
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

private final class YoloSetCallRecorder {
    private(set) var invocations: [(sessionID: String, enabled: Bool)] = []

    func record(_ sessionID: String, _ enabled: Bool) {
        invocations.append((sessionID, enabled))
    }
}
