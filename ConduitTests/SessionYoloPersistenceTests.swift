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

    // MARK: - Global floor vs. manual toggle paths

    // The /yolo slash command routes through toggleYolo → setYoloMode. Under
    // the global floor that write is a server-side no-op, and persisting the
    // override would silently resurface when the profile mode changes, so
    // nothing must be sent and the floor must stay visible.
    func testToggleYoloUnderGlobalOffSendsNothingAndKeepsFloor() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = YoloSetCallRecorder()
        let operations = ChatResumeLifecycleOperations(
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("off")
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)

        await appState.toggleYolo()

        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertTrue(recorder.invocations.isEmpty)
        XCTAssertNil(store.storedOverride(for: "default", sessionID: "session-a"))
    }

    // applyRuntime derives the floor from the last-known approvalsMode, so a
    // resume snapshot that omits approvals_mode must not let the re-assert
    // proceed under an "off" floor it cannot see in the snapshot alone.
    func testReassertUsesLastKnownApprovalModeWhenSnapshotOmitsIt() async {
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
                        "yolo": .bool(true)
                        // approvals_mode deliberately omitted
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(false, for: "default", sessionID: "session-a")
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // Prime the last-known profile mode before the resume.
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("off")
            ])
        ))

        await appState.syncSession()

        // The last-known floor still governs the indicator and suppresses the
        // moot re-assert even though the resume snapshot omitted the mode.
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertTrue(recorder.invocations.isEmpty)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), false)
    }

    // A snapshot that carries no approval signal at all (older gateways /
    // partial projections) must not flip the indicator off; keep the
    // last-known value instead.
    func testSnapshotOmittingAllApprovalSignalsKeepsLastKnownYolo() {
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
                "yolo": .bool(true)
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)

        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false)
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)
    }

    // A known non-off mode with the approval signals omitted entirely from a
    // later snapshot is unknown, not a disagreement: the last-known indicator
    // value must survive instead of flickering to "approvals on".
    func testSnapshotOmittingApprovalSignalsKeepsLastKnownYoloUnderKnownNonOffMode() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        let appState = makeAppState(defaults: defaults, store: store)
        appState.sessions = [session("session-a")]

        // Prime a known non-off mode plus an on session flag.
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "yolo": .bool(true),
                "approvals_mode": .string("manual")
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)

        // A partial projection omitting both signals must keep the last value.
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false)
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(appState.runtime.approvalsMode, "manual")

        // A snapshot that itself reports a non-off mode with no session flag
        // still resolves to approvals-required.
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("manual")
            ])
        ))
        XCTAssertFalse(appState.runtime.yolo)
    }

    // A resume snapshot that omits the session-level yolo is unknown, not a
    // disagreement: the re-assert must not fire on every resume for gateways
    // that omit the field.
    func testResumeSkipsReassertWhenSnapshotOmitsSessionYolo() async {
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
                        "approvals_mode": .string("manual")
                        // yolo deliberately omitted
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

        // The stored override still governs the indicator, but no config.set
        // churn is sent for a value the server never reported.
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertTrue(recorder.invocations.isEmpty)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
    }

    // A buffered live session.info that predates the resume must not re-impose
    // a stale profile approval mode over the fresh resume snapshot's mode.
    func testBufferedSessionInfoCannotReimposeStaleApprovalMode() async {
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
                        "approvals_mode": .string("manual")
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

        // Stale buffered push claiming the profile was globally off.
        appState.handleStreamEvent(.sessionInfo(
            sessionId: "session-a",
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("off")
            ])
        ))

        openGate.resume()
        await resume.value

        // The fresh resume's manual mode is authoritative; the stale floor
        // must not engage.
        XCTAssertEqual(appState.runtime.approvalsMode, "manual")
        XCTAssertFalse(appState.runtime.yolo)
    }

    // A user YOLO write that completed while the resume RPC was in flight
    // already pushed the server; the recovery re-assert must not fire on top
    // of it.
    func testResumeSkipsReassertWhenUserToggledDuringResume() async {
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
                        "approvals_mode": .string("manual")
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
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
        await openGate.waitUntilSuspended()

        // The user toggles YOLO on while the resume is suspended; the write
        // completes (and bumps the write revision) before the resume returns.
        let enabled = await appState.setYoloMode(true)
        XCTAssertTrue(enabled)

        openGate.resume()
        await resume.value

        // Only the user's write fired; the snapshot's stale false did not
        // trigger a duplicate re-assert.
        XCTAssertEqual(recorder.invocations.count, 1)
        XCTAssertEqual(recorder.invocations.first?.enabled, true)
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), true)
    }

    // A user write still awaiting its RPC has not reached the store; the
    // re-assert must not read the pre-toggle override and race the user's
    // write with a stale value.
    func testResumeSkipsReassertWhileUserWriteIsInFlight() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let writeGate = SessionYoloResumeGate()
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
            setSessionYolo: { _, sessionID, enabled in
                await writeGate.suspend()
                recorder.record(sessionID, enabled)
            }
        )
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        // The pre-toggle override the store still holds while the write is
        // in flight.
        store.setOverride(true, for: "default", sessionID: "session-a")
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("session-a")]
        appState.activeSessionId = "session-a"
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        appState.applyChatResume(SessionResumeResult(
            sessionId: "session-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "yolo": .bool(true),
                "approvals_mode": .string("manual")
            ])
        ))
        XCTAssertTrue(appState.runtime.yolo)

        // Start the user's toggle-off; its RPC suspends inside the stub, so
        // the store still holds the old true override.
        let toggle = Task { @MainActor in
            await appState.setYoloMode(false)
        }
        await writeGate.waitUntilSuspended()

        // The resume settles while the user's write is in flight. Its
        // snapshot disagrees with the OLD override, so only the in-flight
        // guard can stop the re-assert from racing the user's write with a
        // stale true.
        await appState.syncSession()
        XCTAssertTrue(recorder.invocations.isEmpty)

        writeGate.resume()
        await toggle.value

        XCTAssertEqual(recorder.invocations.count, 1)
        XCTAssertEqual(recorder.invocations.first?.enabled, false)
        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), false)
        XCTAssertFalse(appState.runtime.yolo)
    }

    // The buffered-mode anchoring is independent of the per-session YOLO write
    // gate: even when the user toggled during the resume
    // (reconcileExplicitYolo == false), a stale buffered event must not
    // re-impose an outdated floor over the fresh resume's mode.
    func testBufferedSessionInfoCannotReimposeStaleApprovalModeWhenUserToggledDuringResume() async {
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
                        "approvals_mode": .string("manual")
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { _, sessionID, enabled in recorder.record(sessionID, enabled) }
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

        // The user toggles YOLO on during the resume (bumps the write revision,
        // so reconcileExplicitYolo will be false)...
        let enabled = await appState.setYoloMode(true)
        XCTAssertTrue(enabled)

        // ...and a stale buffered push claims the profile was globally off.
        appState.handleStreamEvent(.sessionInfo(
            sessionId: "session-a",
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(false),
                "approvals_mode": .string("off")
            ])
        ))

        openGate.resume()
        await resume.value

        // The fresh resume's manual mode stays authoritative; the stale floor
        // must not engage, and the recovery re-assert stays skipped because
        // the user's write is newer.
        XCTAssertEqual(appState.runtime.approvalsMode, "manual")
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertEqual(recorder.invocations.count, 1)
        XCTAssertEqual(recorder.invocations.first?.enabled, true)
    }

    // MARK: - Profile-switch in-flight bookkeeping ownership

    /// Installs the connection/client state profile switching requires.
    private func installSwitchableConnection(on appState: AppState) {
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.showLogin = false
    }

    private func switchLifecycleOperations(
        setSessionYolo: (@MainActor @Sendable (HermesClient, String, Bool) async throws -> Void)?
    ) -> ChatResumeLifecycleOperations {
        ChatResumeLifecycleOperations(
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
            setSessionYolo: setSessionYolo,
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )
    }

    private func formatKeys(_ keys: Set<ChatScrollSessionKey>) -> Set<String> {
        Set(keys.map { $0.profile + "|" + $0.sessionID })
    }

    /// THE leak: a YOLO write suspended under profile A while the app
    /// switches to B must clean its A-profile ownership keys even though
    /// activeProfile is B by the time cleanup runs - and must leave
    /// profile B's (empty) namespace untouched. Runtime vs persisted ids
    /// are diverged so BOTH originating keys prove cleanup.
    func testProfileSwitchDuringSuspendedYoloWriteCleansOriginatingKeys() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        // The user already has a persisted override; the toggle under test
        // flips it back off at the gateway.
        store.setOverride(true, for: "default", sessionID: "persisted-a")
        let gate = SessionYoloResumeGate()
        let operations = switchLifecycleOperations(setSessionYolo: { _, _, _ in
            await gate.suspend()
        })
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("persisted-a", alternateIDs: ["runtime-a"])]
        appState.activeSessionId = "runtime-a"
        appState.runtime.approvalsMode = "on"
        installSwitchableConnection(on: appState)

        let operation = Task { await appState.setYoloMode(false) }
        await gate.waitUntilSuspended()
        XCTAssertFalse(
            appState.inFlightSessionYoloWriteKeysForTesting.isEmpty,
            "the suspended write should hold its ownership keys"
        )

        await appState.switchProfile(to: "work")
        XCTAssertEqual(appState.activeProfile, "work")

        gate.resume()
        await operation.value

        XCTAssertEqual(
            formatKeys(appState.inFlightSessionYoloWriteKeysForTesting),
            Set(),
            "originating-profile in-flight keys must be removed after the op settles"
        )
        XCTAssertNil(store.storedOverride(for: "work", sessionID: "persisted-a"))
        XCTAssertNil(store.storedOverride(for: "work", sessionID: "runtime-a"))
    }

    /// After the toggle settles (even failed/stale), returning to the
    /// originating profile+session and resuming must still re-assert the
    /// persisted override - stale in-flight keys must not suppress it.
    func testReassertionNotSuppressedAfterProfileRoundTrip() async {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")
        store.setOverride(true, for: "default", sessionID: "persisted-a")
        let recorder = YoloSetCallRecorder()
        let gate = SessionYoloResumeGate()
        var suspendedOnce = false
        let operations = ChatResumeLifecycleOperations(
            connectClient: { _ in },
            loadCatalog: { client, _ in
                (client.profile ?? "default") == "work" ? [] : [self.session("persisted-a", alternateIDs: ["runtime-a"])]
            },
            mintTicket: { _ in "profile-ticket" },
            openSession: { _, sessionID in
                // Resume snapshots always report the gateway's forgotten
                // flag; they never park - only the toggle RPC does.
                recorder.record(sessionID, false)
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(false),
                        "yolo": .bool(false)
                    ])
                )
            },
            refreshContext: { _, _ in },
            setSessionYolo: { client, sessionID, enabled in
                if !suspendedOnce {
                    suspendedOnce = true
                    await gate.suspend()
                }
                recorder.record(sessionID, enabled)
            },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )
        let appState = makeAppState(defaults: defaults, store: store, lifecycleOperations: operations)
        appState.sessions = [session("persisted-a", alternateIDs: ["runtime-a"])]
        appState.activeSessionId = "runtime-a"
        appState.runtime.approvalsMode = "on"
        installSwitchableConnection(on: appState)

        // 1. Park the user's off-toggle under profile A.
        let operation = Task { await appState.setYoloMode(false) }
        await gate.waitUntilSuspended()

        // 2. Switch to work while it is parked; resume; the stale guard must
        //    suppress any state mutation for B.
        await appState.switchProfile(to: "work")
        XCTAssertEqual(appState.activeProfile, "work")
        gate.resume()
        await operation.value
        XCTAssertTrue(appState.inFlightSessionYoloWriteKeysForTesting.isEmpty)
        XCTAssertFalse(recorder.invocations.contains { $0.enabled == true })

        // 3. Return to default. The return-switch resumes persisted-a with a
        //    yolo=false snapshot - reconcileExplicitYolo becomes true and the
        //    re-assert must fire against the stored true override.
        await appState.switchProfile(to: "default")
        XCTAssertEqual(appState.activeProfile, "default")

        // The re-assert routes through whichever session ID the current
        // reconciliation used; ownership (not routing) is this test's scope.
        let reasserted = recorder.invocations.contains { call in
            call.enabled == true
        }
        XCTAssertTrue(
            reasserted,
            "the persisted override must be re-asserted after returning; got \(recorder.invocations)"
        )
        XCTAssertTrue(appState.runtime.yolo)
        XCTAssertTrue(appState.inFlightSessionYoloWriteKeysForTesting.isEmpty)
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
