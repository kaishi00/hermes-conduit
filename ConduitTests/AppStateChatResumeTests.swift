import Combine
import XCTest
@testable import Conduit

@MainActor
final class AppStateChatResumeTests: XCTestCase {
    func testResumeHydratesApprovalsQueuedBehindSnapshotHead() async {
        let pending: (String) -> ApprovalActivity = { requestID in
            ApprovalActivity(
                sessionId: "runtime-queue",
                requestId: requestID,
                command: "deploy \(requestID)",
                description: "Run \(requestID)?",
                choices: ["once", "deny"],
                allowPermanent: true,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        }
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("stored-queue", alternateIDs: ["runtime-queue"])] },
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-queue",
                    storedSessionId: "stored-queue",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: [
                        "running": .bool(true),
                        "pending_approval": .object([
                            "request_id": .string("approval-a"),
                            "description": .string("Run approval-a?")
                        ])
                    ])
                )
            },
            refreshContext: { _, _ in },
            pendingApprovals: { _, sessionID in
                XCTAssertEqual(sessionID, "runtime-queue")
                return [pending("approval-a"), pending("approval-b")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [session("stored-queue", alternateIDs: ["runtime-queue"])]
        harness.appState.activeSessionId = "stored-queue"

        await harness.appState.syncSession()
        for _ in 0..<1_000 where harness.appState.messages.compactMap({ $0.approval }).count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(
            harness.appState.messages.compactMap { $0.approval?.requestId },
            ["approval-a", "approval-b"]
        )
    }

    func testColdRelaunchResumesDurableSavedSessionWhenCatalogTemporarilyOmitsIt() async {
        var initialRequests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [] },
            openSession: { _, sessionID, _ in
                initialRequests.append(sessionID)
                return SessionResumeResult(
                    sessionId: "runtime-a",
                    storedSessionId: "stored-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // This is the pre-persistence state after session.create: only the
        // runtime ID is known locally. The next admitted resume establishes
        // Hermes's durable stored ID.
        harness.appState.activeSessionId = "runtime-a"

        await harness.appState.syncSession()

        XCTAssertEqual(initialRequests, ["runtime-a"])
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-a")

        var relaunchedRequests: [String] = []
        let restoredStore = ChatResumeStore(defaults: harness.defaults)
        let restoredState = AppState(
            defaults: harness.defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: restoredStore),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-older")] },
                openSession: { _, sessionID, _ in
                    relaunchedRequests.append(sessionID)
                    return SessionResumeResult(
                        sessionId: "runtime-a-relaunched",
                        storedSessionId: "stored-a",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: harness.defaults)
        )
        restoredState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        XCTAssertEqual(restoredState.activeSessionId, "stored-a")
        await restoredState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            relaunchedRequests,
            ["stored-a"],
            "A partial cold-start catalog must not redirect restoration to an unrelated row"
        )
        XCTAssertEqual(restoredState.activeSessionId, "runtime-a-relaunched")
        XCTAssertEqual(restoredStore.lastSessionID(for: "default"), "stored-a")
    }

    func testPreserveCurrentUsesEstablishedStoredIdentityWhenCatalogLosesRuntimeAlias() async {
        var requests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated"), self.session("stored-a")] },
            openSession: { _, id, _ in
                requests.append(id)
                return SessionResumeResult(sessionId: "runtime-a", messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        harness.appState.activeSessionId = "runtime-a"

        await harness.appState.syncSession()

        XCTAssertEqual(requests, ["stored-a"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a")
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-a")
    }

    func testPreserveCurrentResumesSelectedConversationWhenCatalogIsEmpty() async {
        var requests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [] },
            openSession: { _, id, _ in
                requests.append(id)
                return SessionResumeResult(sessionId: id, messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.activeSessionId = "selected"

        await harness.appState.syncSession()

        XCTAssertEqual(requests, ["selected"])
        XCTAssertEqual(harness.appState.activeSessionId, "selected")
    }

    func testPreserveCurrentWithoutCurrentIdentityResumesNewestChatInsteadOfCreating() async {
        // Review finding 1: with no established current conversation there is
        // nothing to preserve, so the historical newest-chat selection must
        // apply — preserve-current must not silently become session.create.
        var requests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("stored-newest"), self.session("stored-older")] },
            openSession: { _, id, _ in
                requests.append(id)
                return SessionResumeResult(sessionId: id, messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession()

        XCTAssertEqual(requests, ["stored-newest"], "Newest-chat fallback must survive, not fall through to create")
        XCTAssertEqual(harness.appState.activeSessionId, "stored-newest")
    }

    func testFreshResumeRestoresInFlightToolAndReconcilesItsCompletion() {
        let suite = "AppStateChatResumeTests.inFlightTool.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let active = session("stored-a")
        let sourceCache = SessionPresentationCache(defaults: defaults)
        let source = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: sourceCache
        )
        source.sessions = [active]
        source.activeSessionId = active.id

        source.handleStreamEvent(.toolStart(
            sessionId: active.id,
            toolName: "read_file",
            toolInput: "README.md",
            toolID: "call-reopen"
        ))

        // Simulate terminate/relaunch with a new AppState and cache object
        // backed by the same durable defaults store. Hermes has not committed
        // a transcript row yet, but it still reports an active turn.
        let resumed = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        XCTAssertTrue(resumed.applyChatResume(SessionResumeResult(
            sessionId: active.id,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
        )))
        XCTAssertEqual(resumed.messages.count, 1)
        XCTAssertEqual(resumed.messages[0].tool?.name, "read_file")
        XCTAssertEqual(resumed.messages[0].tool?.input, "README.md")
        XCTAssertEqual(resumed.messages[0].tool?.id, "call-reopen")
        XCTAssertEqual(resumed.messages[0].tool?.status, .running)

        // The resumed gateway can replay its start event; it must not append
        // a second card for the persisted tool identity.
        resumed.handleStreamEvent(.toolStart(
            sessionId: active.id,
            toolName: "read_file",
            toolInput: "README.md",
            toolID: "call-reopen"
        ))
        XCTAssertEqual(resumed.messages.count, 1)

        // The result event must update that restored card in place rather
        // than append a second completed tool row.
        resumed.handleStreamEvent(.toolComplete(
            sessionId: active.id,
            toolName: "read_file",
            toolOutput: "contents",
            toolID: "call-reopen"
        ))
        XCTAssertEqual(resumed.messages.count, 1)
        XCTAssertEqual(resumed.messages[0].tool?.status, .complete)
        XCTAssertEqual(resumed.messages[0].tool?.output, "contents")

        // Once complete, the transient record is gone; a later authoritative
        // resume uses Hermes' committed row without reviving a running twin.
        let settled = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let committed = ChatMessage(
            id: "server-tool",
            role: .tool,
            content: "",
            timestamp: "1",
            tool: ToolActivity(
                id: nil,
                name: "read_file",
                input: "README.md",
                output: "contents",
                status: .complete
            )
        )
        XCTAssertTrue(settled.applyChatResume(SessionResumeResult(
            sessionId: active.id,
            messages: [committed],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        )))
        XCTAssertEqual(settled.messages.count, 1)
        XCTAssertEqual(settled.messages[0].tool?.status, .complete)
    }

    func testPristineCanvasWithEmptyCatalogStillAttemptsSessionCreate() async {
        // The other half of the no-current-identity boundary: an empty
        // catalog with no current identity keeps the preexisting
        // session.create behavior. The open seam must never fire.
        var requests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [] },
            openSession: { _, id, _ in
                requests.append(id)
                return SessionResumeResult(sessionId: id, messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        installComposerClient(in: harness)
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession()

        XCTAssertTrue(requests.isEmpty, "No conversation exists to resume; the create path is the historical behavior")
        XCTAssertNil(harness.appState.activeSessionId)
        XCTAssertEqual(harness.appState.turnState, .idle)
        // The create path itself ran (and failed on the unconnected test
        // client) — proving the empty-catalog/no-identity boundary really
        // reaches session.create rather than silently doing nothing.
        XCTAssertTrue(
            harness.appState.errorMessage?.hasPrefix("Failed to create session:") == true,
            "Expected the create path's failure, got: \(harness.appState.errorMessage ?? "nil")"
        )
    }

    func testPreserveCurrentRecoveryBuffersStreamEventsForForgottenRuntimeAlias() async {
        // Invariant: while preserve-current recovery awaits session.resume,
        // stream events addressed to any previously confirmed runtime alias
        // stay associated with this reconciliation. The refreshed catalog
        // omitted runtime-a, but the alias set was captured BEFORE the
        // replacement — so the delta is buffered, replayed after the
        // transcript replacement, and neither lost nor erased.
        let openGate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated"), self.session("stored-a")] },
            openSession: { _, _, _ in
                await openGate.suspend()
                return SessionResumeResult(sessionId: "runtime-a", messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.sessions = [self.session("stored-a", alternateIDs: ["runtime-a"])]
        harness.appState.activeSessionId = "runtime-a"

        let sync = Task { @MainActor in
            await harness.appState.syncSession()
        }
        await openGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: "runtime-a", text: "Live recovery text")
        )
        openGate.resume()
        await sync.value
        // Pump the main actor so the replayed delta's scheduled streaming
        // publish lands before the assertion.
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false

        XCTAssertEqual(
            harness.appState.streamingText, "Live recovery text",
            "An event for a confirmed alias must survive the resume window, not be erased by transcript replacement"
        )
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a")
    }

    func testContradictoryResumeIsRejectedWithoutMutatingSelectedConversation() async {
        // Selected durable stored-a; the resume explicitly says stored-b.
        // The claim is rejected before transcript, identity, navigation, or
        // persistence state is touched.
        var requests: [String] = []
        let existingMessage = ChatMessage(id: "m1", role: .user, content: "Keep me", timestamp: "1")
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated"), self.session("stored-a")] },
            openSession: { _, id, _ in
                requests.append(id)
                return SessionResumeResult(
                    sessionId: "runtime-b",
                    storedSessionId: "stored-b",
                    messages: [ChatMessage(id: "foreign", role: .assistant, content: "Foreign", timestamp: "2")],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.sessions = [self.session("stored-a", alternateIDs: ["runtime-a"])]
        harness.appState.activeSessionId = "runtime-a"
        harness.appState.messages = [existingMessage]
        harness.store.setLastSessionID("stored-a", for: "default")

        await harness.appState.syncSession()

        XCTAssertEqual(requests, ["stored-a"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a", "A contradictory resume must not navigate")
        XCTAssertEqual(harness.appState.messages, [existingMessage], "The selected transcript stays intact")
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a")
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-a", "The resume store keeps the selected durable id")
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertNotNil(harness.appState.errorMessage, "The rejection is surfaced, not silent")
    }

    func testResumeRuntimeOwnedByAnotherCatalogConversationIsRejected() async {
        // The returned runtime id positively belongs to stored-b in the
        // refreshed catalog: reject the rebind even without an explicit
        // durable claim.
        var requests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [
                self.session("unrelated"),
                self.session("stored-a"),
                self.session("stored-b", alternateIDs: ["runtime-b"])
            ] },
            openSession: { _, id, _ in
                requests.append(id)
                return SessionResumeResult(sessionId: "runtime-b", messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.sessions = [self.session("stored-a", alternateIDs: ["runtime-a"])]
        harness.appState.activeSessionId = "runtime-a"
        harness.store.setLastSessionID("stored-a", for: "default")

        await harness.appState.syncSession()

        XCTAssertEqual(requests, ["stored-a"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a", "A foreign runtime id must not rebind the selection")
        XCTAssertEqual(harness.appState.messages, [])
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a")
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-a")
    }

    func testLegitimateRuntimeRotationRebindsWithoutNavigation() async {
        // Hermes legitimately rotated stored-a: runtime-old → runtime-new.
        // The rebind updates routing identity; the selected conversation
        // stays stored-a and future addressing uses runtime-new.
        var requests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated"), self.session("stored-a")] },
            openSession: { _, id, _ in
                requests.append(id)
                return SessionResumeResult(
                    sessionId: id == "stored-a" ? "runtime-new" : id,
                    storedSessionId: id == "stored-a" ? "stored-a" : nil,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.sessions = [self.session("stored-a", alternateIDs: ["runtime-old"])]
        harness.appState.activeSessionId = "runtime-old"
        harness.store.setLastSessionID("stored-a", for: "default")

        await harness.appState.syncSession()

        XCTAssertEqual(requests, ["stored-a"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-new", "The runtime routing id follows the rotation")
        XCTAssertEqual(
            harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a",
            "Rotation must not look like navigation to another conversation"
        )
        XCTAssertTrue(
            harness.appState.activeChatScrollSessionIdentity.areEquivalent("runtime-old", "runtime-new"),
            "Old and new runtime ids are positively confirmed aliases of the same conversation"
        )
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-a")
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testRuntimeOnlyConversationEstablishesDurableKeyFromResume() async {
        // A runtime-only conversation (no catalog row, no established
        // durable id) whose resume response names its stored key: the key is
        // established as the durable identity — routing adoption, not
        // navigation.
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated")] },
            openSession: { _, id, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-solo",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.activeSessionId = "runtime-solo"

        await harness.appState.syncSession()

        XCTAssertEqual(harness.appState.activeSessionId, "runtime-solo")
        XCTAssertEqual(
            harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-solo",
            "The response's stored key becomes the durable identity"
        )
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-solo")
        XCTAssertTrue(
            harness.appState.activeChatScrollSessionIdentity.areEquivalent("runtime-solo", "stored-solo")
        )
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testTargetResumeKeepsBufferedEventsForAliasDroppedFromRefreshedRow() async {
        // The refreshed catalog still contains the selected row (matched via
        // the durable id) but dropped its runtime alias: the target branch
        // must keep the pre-captured alias accepted so in-flight events for
        // it stay buffered and survive the transcript replacement.
        let openGate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated"), self.session("stored-a")] },
            openSession: { _, _, _ in
                await openGate.suspend()
                return SessionResumeResult(sessionId: "runtime-a", messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.sessions = [self.session("stored-a", alternateIDs: ["runtime-a"])]
        harness.appState.activeSessionId = "stored-a"

        let sync = Task { @MainActor in
            await harness.appState.syncSession()
        }
        await openGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: "runtime-a", text: "Alias survives")
        )
        openGate.resume()
        await sync.value
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false

        XCTAssertEqual(harness.appState.streamingText, "Alias survives")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a")
    }

    func testAutomaticReturnRejectionDoesNotScheduleReconnect() async {
        // A rejected identity is deterministic; automatic-return recovery
        // must not treat it as a retryable failure and loop on the same
        // contradiction.
        let scheduler = ControlledReconnectScheduler()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-a")] },
                openSession: { _, _, _ in
                    SessionResumeResult(
                        sessionId: "runtime-b",
                        storedSessionId: "stored-b",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.store.setLastSessionID("stored-a", for: "default")

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(scheduler.scheduledCount, 0, "A contradictory resume is not a reconnect candidate")
        XCTAssertNotNil(harness.appState.errorMessage)
        XCTAssertNil(harness.appState.activeSessionId, "No navigation happened")
    }

    func testAutomaticReturnRetiresDeletedMissingSavedSessionAndOpensNewestFallback() async {
        let scheduler = ControlledReconnectScheduler()
        var requests: [String] = []
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    [self.session("stored-newest"), self.session("stored-older")]
                },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    if sessionID == "stored-deleted" {
                        throw RpcError(code: 4007, message: "Session not found")
                    }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        harness.store.setLastSessionID("stored-deleted", for: "default")

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(requests, ["stored-deleted", "stored-newest"])
        XCTAssertEqual(harness.appState.activeSessionId, "stored-newest")
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-newest")
        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testAutomaticReturnKeepsMissingSavedSessionAndRetriesTransientResumeFailure() async {
        let scheduler = ControlledReconnectScheduler()
        var requests: [String] = []
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-fallback")] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    throw ControlledLifecycleError.failed
                }
            )
        )
        installComposerClient(in: harness)
        harness.store.setLastSessionID("stored-temporarily-unavailable", for: "default")

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(requests, ["stored-temporarily-unavailable"])
        XCTAssertEqual(
            harness.store.lastSessionID(for: "default"),
            "stored-temporarily-unavailable"
        )
        XCTAssertEqual(scheduler.scheduledCount, 1)
    }

    func testAutomaticReturnDeletedMissingSavedSessionWithEmptyCatalogFallsBackToCreate() async {
        let scheduler = ControlledReconnectScheduler()
        var requests: [String] = []
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    throw RpcError(code: 4007, message: "Session not found")
                }
            )
        )
        installComposerClient(in: harness)
        harness.store.setLastSessionID("stored-deleted", for: "default")

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(requests, ["stored-deleted"])
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
        XCTAssertNil(harness.appState.activeSessionId)
        XCTAssertTrue(
            harness.appState.errorMessage?.hasPrefix("Failed to create session:") == true,
            "The definitive deletion should advance to the ordinary empty-catalog create path"
        )
        XCTAssertEqual(scheduler.scheduledCount, 1, "Only the failed create remains retryable")
    }

    func testTranscriptRpc4007DoesNotRetireMissingSavedSession() async {
        let scheduler = ControlledReconnectScheduler()
        var requests: [String] = []
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-fallback")] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        storedSessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    .failed(RpcError(code: 4007, message: "Transcript route failure"))
                }
            )
        )
        installComposerClient(in: harness)
        harness.store.setLastSessionID("stored-still-present", for: "default")

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(requests, ["stored-still-present"])
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-still-present")
        XCTAssertNil(harness.appState.activeSessionId)
        XCTAssertEqual(scheduler.scheduledCount, 1)
    }

    func testStaleDeletedSessionFailureCannotRetireSavedSelectionOrOpenFallback() async {
        let gate = ControlledSuspension()
        var requests: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-fallback")] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    await gate.suspend()
                    throw RpcError(code: 4007, message: "Session not found")
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.store.setLastSessionID("stored-deleted", for: "default")
        let automaticWork = harness.appState.beginAutomaticChatResumeWork()

        let synchronization = Task { @MainActor in
            await harness.appState.syncSession(
                purpose: .automaticReturn,
                using: nil,
                automaticWorkToken: automaticWork
            )
        }
        await gate.waitUntilSuspended()
        harness.appState.cancelChatResumeRestoration()
        gate.resume()
        await synchronization.value

        XCTAssertEqual(requests, ["stored-deleted"])
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-deleted")
        XCTAssertNil(harness.appState.activeSessionId)
    }

    func testDeletedActiveSessionIsNotResurrectedByPreserveCurrentRecovery() async {
        // Explicit destructive navigation cleared the active identity
        // (clearActiveSessionIfNeeded semantics). Preserve-current recovery
        // has nothing to resurrect: it selects the newest remaining chat and
        // never revisits the deleted conversation.
        var requests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("stored-remaining")] },
            openSession: { _, id, _ in
                requests.append(id)
                return SessionResumeResult(sessionId: id, messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"), profile: "default")
        harness.appState.sessions = [self.session("stored-remaining")]
        harness.appState.activeSessionId = nil
        harness.store.setLastSessionID("stored-deleted", for: "default")

        await harness.appState.syncSession()

        XCTAssertEqual(requests, ["stored-remaining"], "The deleted conversation is not resurrected")
        XCTAssertFalse(requests.contains("stored-deleted"))
        XCTAssertEqual(harness.appState.activeSessionId, "stored-remaining")
    }

    func testRuntimeToDurableEstablishmentMigratesScrollPersistence() async {
        // A runtime-only conversation's first durable-establishing resume
        // moves the canonical key from runtime-solo to stored-solo. The
        // stored-solo id has NO catalog row yet — the persistence migration
        // must still happen, because the admitted durable id is positive
        // identity evidence and the store's lookup is exact-keyed.
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated")] },
            openSession: { _, id, _ in
                SessionResumeResult(sessionId: id, storedSessionId: "stored-solo", messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in }
        ))
        installComposerClient(in: harness)
        let soloKey = ChatScrollSessionKey(profile: "default", sessionID: "runtime-solo")
        let soloSnapshot = ChatScrollSnapshot(anchorMessageID: "anchor-solo", followsLatest: false)
        harness.coordinator.recordViewport(soloSnapshot, for: soloKey)
        let otherKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-other")
        let otherSnapshot = ChatScrollSnapshot(anchorMessageID: "anchor-other", followsLatest: false)
        harness.coordinator.recordViewport(otherSnapshot, for: otherKey)
        harness.coordinator.flush()

        harness.appState.activeSessionId = "runtime-solo"
        await harness.appState.syncSession()

        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-solo")
        XCTAssertEqual(
            harness.store.snapshot(for: ChatScrollSessionKey(profile: "default", sessionID: "stored-solo")),
            soloSnapshot,
            "The runtime-keyed viewport snapshot follows the established durable key"
        )
        XCTAssertNil(harness.store.snapshot(for: soloKey), "The old runtime key entry is migrated, not copied")
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-solo")
        XCTAssertEqual(harness.store.snapshot(for: otherKey), otherSnapshot, "Unrelated session persistence is untouched")
    }

    func testRuntimeToDurableEstablishmentMigratesScrollPersistenceThroughRotation() async {
        // Same establishment, with the runtime id rotating at the same time:
        // runtime-solo → runtime-new while stored-solo is established. The
        // previously selected runtime key is positive evidence (accepted
        // alias), so its persistence migrates to the new durable key.
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated")] },
            openSession: { _, id, _ in
                SessionResumeResult(
                    sessionId: id == "runtime-solo" ? "runtime-new" : id,
                    storedSessionId: id == "runtime-solo" ? "stored-solo" : nil,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        installComposerClient(in: harness)
        let soloKey = ChatScrollSessionKey(profile: "default", sessionID: "runtime-solo")
        let soloSnapshot = ChatScrollSnapshot(anchorMessageID: "anchor-solo", followsLatest: false)
        harness.coordinator.recordViewport(soloSnapshot, for: soloKey)
        harness.coordinator.flush()

        harness.appState.activeSessionId = "runtime-solo"
        await harness.appState.syncSession()

        XCTAssertEqual(harness.appState.activeSessionId, "runtime-new", "The runtime id follows the rotation")
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-solo")
        XCTAssertTrue(
            harness.appState.activeChatScrollSessionIdentity.areEquivalent("runtime-solo", "stored-solo")
        )
        XCTAssertEqual(
            harness.store.snapshot(for: ChatScrollSessionKey(profile: "default", sessionID: "stored-solo")),
            soloSnapshot,
            "The pre-rotation runtime-keyed snapshot is available under the durable key"
        )
        XCTAssertNil(harness.store.snapshot(for: soloKey))
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "stored-solo")
    }

    func testComposerExactSessionIDMatchStillRequiresDurableIdentity() async {
        // Exact routing-string equality cannot bypass the durable fence: the
        // catalog can re-attribute the same runtime string to a different
        // conversation (discovery state), and a context captured before that
        // must not keep sending rights into the re-attributed conversation.
        var sends: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("stored-b", alternateIDs: ["shared-runtime"])] },
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "shared-runtime", messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, id, _ in sends.append(id); return .accepted }
        ))
        installComposerClient(in: harness)
        harness.appState.sessions = [self.session("stored-a", alternateIDs: ["shared-runtime"])]
        harness.appState.activeSessionId = "shared-runtime"
        let staleContext = harness.appState.composerSubmissionContext()

        // Discovery re-attribution: the refreshed catalog resolves the
        // shared runtime id under stored-b. The resume identity gate admits
        // it (the runtime string is a confirmed alias), so only the durable
        // fence can tell the captured context apart.
        await harness.appState.syncSession()
        XCTAssertEqual(
            harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-b",
            "Setup: the catalog re-attribution took effect"
        )

        let staleSubmitted = await harness.appState.submitComposer(text: "Stale", context: staleContext)

        XCTAssertFalse(
            staleSubmitted,
            "Exact-ID equality with a re-attributed durable identity must be rejected"
        )
        XCTAssertTrue(sends.isEmpty, "The stale context must not reach the gateway")

        let freshContext = harness.appState.composerSubmissionContext()
        let freshSubmitted = await harness.appState.submitComposer(text: "Fresh", context: freshContext)

        XCTAssertTrue(freshSubmitted, "A fresh context on the re-attributed conversation sends normally")
        XCTAssertEqual(sends, ["shared-runtime"])
    }

    func testComposerExactMatchSurvivesRowLessDurableEstablishment() async {
        // Catalog silence is not separation: a context captured on a
        // runtime-only conversation (durable falls back to the runtime
        // string) stays owned across the first durable-establishing resume —
        // the new durable key has no catalog row yet, so there is no
        // positive re-attribution evidence to fail the fence on.
        var sends: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated")] },
            openSession: { _, id, _ in
                SessionResumeResult(sessionId: id, storedSessionId: "stored-solo", messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, id, _ in sends.append(id); return .accepted }
        ))
        installComposerClient(in: harness)
        harness.appState.activeSessionId = "runtime-solo"
        let context = harness.appState.composerSubmissionContext()

        await harness.appState.syncSession()
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-solo")

        let submitted = await harness.appState.submitComposer(text: "Established", context: context)

        XCTAssertTrue(submitted, "A row-less durable establishment must not orphan an owned submission")
        XCTAssertEqual(sends, ["runtime-solo"])
    }

    func testSupersededBranchWaitingForTitleCannotMutateNewerSession() async {
        let titleGate = ControlledSuspension()
        let newerMessages = [
            ChatMessage(id: "newer", role: .assistant, content: "Newer session", timestamp: "3")
        ]
        let staleCatalog = session("stale-catalog")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [staleCatalog] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: newerMessages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                branchSession: { _, _, _, _, _ in
                    (sessionId: "branch-runtime", storedSessionId: "branch-stored", profile: "default")
                },
                setSessionTitle: { _, _, _ in
                    await titleGate.suspend()
                },
                refreshContext: { _, _ in }
            )
        )
        let parent = session("stored-a")
        let newer = session("stored-c")
        let newerKey = ChatScrollSessionKey(profile: "default", sessionID: newer.id)
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [parent, newer]
        harness.appState.activeSessionId = parent.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1"),
            ChatMessage(id: "assistant", role: .assistant, content: "Answer", timestamp: "2")
        ]

        let branch = Task { @MainActor in
            await harness.appState.branchFromAssistantMessage("assistant")
        }
        await titleGate.waitUntilSuspended()

        let openedNewer = await harness.appState.openSession(newer.id)
        XCTAssertTrue(openedNewer)
        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: newerKey,
            transitionGeneration: harness.appState.chatViewportTransitionGeneration,
            transcriptRevision: harness.appState.chatTranscriptRevision,
            renderRevision: 1,
            receivedScopedPreference: true
        )

        titleGate.resume()
        await branch.value

        XCTAssertEqual(harness.appState.activeSessionId, newer.id)
        XCTAssertEqual(harness.appState.activeSessionTitle, newer.title)
        XCTAssertEqual(harness.appState.messages, newerMessages)
        XCTAssertEqual(harness.appState.sessions.map(\.id), [parent.id, newer.id])
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)

        harness.appState.recordChatViewport(.latest, for: newerKey)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: newerKey), .latest)
    }

    func testRapidExplicitSessionSwitchingSettlesTheLatestSession() async {
        let sessionIDs = (1...8).map { "stored-\($0)" }
        let gates = SessionOpenGates(sessionIDs: sessionIDs)
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    await gates.suspend(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [ChatMessage(
                            id: "message-\(sessionID)",
                            role: .assistant,
                            content: sessionID,
                            timestamp: sessionID
                        )],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = sessionIDs.map { session($0) }
        harness.appState.activeSessionId = sessionIDs[0]

        let tasks = sessionIDs.dropFirst().map { sessionID in
            Task { @MainActor in
                await harness.appState.openSession(sessionID)
            }
        }
        for sessionID in sessionIDs.dropFirst() {
            await gates.waitUntilSuspended(sessionID)
        }

        for sessionID in sessionIDs.dropFirst().reversed() {
            gates.resume(sessionID)
        }
        for task in tasks {
            _ = await task.value
        }

        XCTAssertEqual(harness.appState.activeSessionId, sessionIDs.last)
        XCTAssertEqual(harness.appState.messages.map(\.content), [sessionIDs.last ?? ""])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
    }

    func testResumeDedupNormalizesPersistedBoundaryBeforeReplayingBufferedDelta() async {
        let openGate = ControlledSuspension()
        let active = session("stored-a")
        let persistedText = "Let me find the transcript."
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    await openGate.suspend()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "persisted-assistant",
                                role: .assistant,
                                content: persistedText,
                                timestamp: "1"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(
                            object: [:],
                            inflight: .object([
                                "assistant": .string("\(persistedText) I found it.")
                            ])
                        )
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(
                id: "persisted-assistant",
                role: .assistant,
                content: persistedText,
                timestamp: "1"
            )
        ]
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: persistedText)
        )

        let refresh = Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await openGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: " I found it.")
        )
        openGate.resume()
        await refresh.value

        // Force the authoritative streaming buffer into the published test
        // projection so a wrongly replayed buffered delta is observable.
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.streamingText, "I found it.")
    }

    func testResumeDedupPreservesNoMarkerCollisionWithoutBoundaryText() async {
        let openGate = ControlledSuspension()
        let active = session("stored-a")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    await openGate.suspend()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: [:],
                            inflight: .object([
                                "assistant": .string("xyz")
                            ])
                        )
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        let refresh = Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await openGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: "xyz more")
        )
        openGate.resume()
        await refresh.value

        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.streamingText, "xyzxyz more")
    }

    func testResumeDedupHandlesBoundaryLagWithInterleavedToolEvent() async {
        let openGate = ControlledSuspension()
        let active = session("stored-a")
        let persistedText = "The quick brown"
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    await openGate.suspend()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "persisted-assistant",
                                role: .assistant,
                                content: persistedText,
                                timestamp: "1"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(
                            object: [:],
                            inflight: .object([
                                "assistant": .string("The quick brown fox")
                            ])
                        )
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(
                id: "persisted-assistant",
                role: .assistant,
                content: persistedText,
                timestamp: "1"
            )
        ]
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: "The quick")
        )

        let refresh = Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await openGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: " brown fox jumps")
        )
        harness.appState.handleStreamEvent(
            .toolStart(sessionId: active.id, toolName: "Bash", toolInput: "ls", toolID: "buffered-tool")
        )
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: " now")
        )
        openGate.resume()
        await refresh.value

        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        let partials = harness.appState.messages.filter { $0.role == .partial }
        let toolIndex = harness.appState.messages.firstIndex { $0.role == .tool }
        let partialIndex = harness.appState.messages.firstIndex { $0.role == .partial }
        XCTAssertEqual(partials.map(\.content), ["fox jumps"])
        XCTAssertEqual(toolIndex, partialIndex.map { $0 + 1 })
        XCTAssertEqual(harness.appState.streamingText, " now")
    }

    func testResumeDedupDropsSuffixAlignedGapAfterTranscriptAdvances() async {
        let openGate = ControlledSuspension()
        let active = session("stored-a")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    await openGate.suspend()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "persisted-assistant",
                                role: .assistant,
                                content: "AB",
                                timestamp: "1"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(
                            object: [:],
                            inflight: .object([
                                "assistant": .string("ABC")
                            ])
                        )
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: "A")
        )

        let refresh = Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await openGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: "C")
        )
        openGate.resume()
        await refresh.value

        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.streamingText, "C")
    }

    func testResumeDedupKeepsOnlyNewTextWhenBufferedWindowStraddlesCoverage() async {
        let openGate = ControlledSuspension()
        let active = session("stored-a")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    await openGate.suspend()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "persisted-assistant",
                                role: .assistant,
                                content: "AB",
                                timestamp: "1"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(
                            object: [:],
                            inflight: .object([
                                "assistant": .string("ABCD")
                            ])
                        )
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.handleStreamEvent(
            .toolStart(sessionId: active.id, toolName: "Bash", toolInput: "ls")
        )
        let olderToolID = harness.appState.messages.last?.id
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: "A")
        )

        let refresh = Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await openGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: "CDE")
        )
        harness.appState.handleStreamEvent(
            .toolStart(sessionId: active.id, toolName: "Bash", toolInput: "ls", toolID: "buffered-tool")
        )
        openGate.resume()
        await refresh.value

        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        let partials = harness.appState.messages.filter { $0.role == .partial }
        let olderToolIndex = harness.appState.messages.firstIndex { $0.id == olderToolID }
        let replayedToolIndex = harness.appState.messages.lastIndex { $0.role == .tool }
        let partialIndex = harness.appState.messages.firstIndex { $0.role == .partial }
        XCTAssertEqual(partials.map(\.content), ["CDE"])
        XCTAssertEqual(harness.appState.messages.filter { $0.role == .tool }.count, 2)
        guard let replayedToolIndex else {
            return XCTFail("Expected the buffered tool call to survive reconciliation")
        }
        XCTAssertEqual(harness.appState.messages[replayedToolIndex].tool?.id, "buffered-tool")
        XCTAssertTrue(
            olderToolIndex.map { index in partialIndex.map { index < $0 } ?? false } ?? false,
            "The older identical running call must be preserved ahead of the buffered text"
        )
        XCTAssertEqual(Optional(replayedToolIndex), partialIndex.map { $0 + 1 })
    }

    func testResumeDedupAcceptsAlternateSessionIDForBufferedDelta() async {
        let openGate = ControlledSuspension()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let persistedText = "Let me find the transcript."
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, _, _ in
                    await openGate.suspend()
                    return SessionResumeResult(
                        sessionId: "runtime-a",
                        messages: [
                            ChatMessage(
                                id: "persisted-assistant",
                                role: .assistant,
                                content: persistedText,
                                timestamp: "1"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(
                            object: [:],
                            inflight: .object([
                                "assistant": .string("\(persistedText) I found it.")
                            ])
                        )
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(
                id: "persisted-assistant",
                role: .assistant,
                content: persistedText,
                timestamp: "1"
            )
        ]
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: active.id, text: persistedText)
        )

        let refresh = Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await openGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: "runtime-a", text: " I found it.")
        )
        openGate.resume()
        await refresh.value

        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.streamingText, "I found it.")
    }

    func testResumeDoesNotUsePreviousSessionBoundaryForNewSessionDelta() async {
        let contextGate = ControlledSuspension()
        let previous = session("stored-old")
        let resumedSessionID = "runtime-new"
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [previous] },
                openSession: { _, _, _ in
                    return SessionResumeResult(
                        sessionId: resumedSessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: [:],
                            inflight: .object([
                                "assistant": .string("Okay next")
                            ])
                        )
                    )
                },
                refreshContext: { _, _ in await contextGate.suspend() }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [previous]
        harness.appState.activeSessionId = previous.id
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: previous.id, text: "Okay")
        )

        let refresh = Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await contextGate.waitUntilSuspended()
        harness.appState.handleStreamEvent(
            .messageDelta(sessionId: resumedSessionID, text: " next")
        )
        contextGate.resume()
        await refresh.value

        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.streamingText, "Okay next next")
    }

    func testCancelledExplicitSessionSwitchDoesNotLeaveSynchronizationStuck() async {
        let openGate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    await openGate.suspend()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a"), session("stored-b")]
        harness.appState.activeSessionId = "stored-a"

        let task = Task { @MainActor in
            await harness.appState.openSession("stored-b")
        }
        await openGate.waitUntilSuspended()
        task.cancel()
        openGate.resume()
        _ = await task.value

        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
    }

    func testRequestingAnotherSessionCancelsThePreviousOpen() async {
        let firstGate = ControlledSuspension()
        let secondGate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    if sessionID == "stored-b" {
                        await firstGate.suspend()
                    } else {
                        await secondGate.suspend()
                    }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a"), session("stored-b"), session("stored-c")]
        harness.appState.activeSessionId = "stored-a"

        let firstTask = harness.appState.requestOpenSession("stored-b")
        await firstGate.waitUntilSuspended()
        let secondTask = harness.appState.requestOpenSession("stored-c")
        await secondGate.waitUntilSuspended()

        XCTAssertTrue(firstTask.isCancelled)
        firstGate.resume()
        secondGate.resume()
        _ = await firstTask.value
        let secondOpened = await secondTask.value
        XCTAssertTrue(secondOpened)

        XCTAssertEqual(harness.appState.activeSessionId, "stored-c")
        XCTAssertEqual(harness.appState.turnState, .idle)
    }

    func testOlderNotificationCleanupCannotClearNewerNotificationBusyState() async {
        let firstCatalogGate = ControlledSuspension()
        let secondCatalogGate = ControlledSuspension()
        var catalogLoadCount = 0
        let firstMessages = [
            ChatMessage(id: "b", role: .assistant, content: "First", timestamp: "1")
        ]
        let secondMessages = [
            ChatMessage(id: "c", role: .assistant, content: "Second", timestamp: "2")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogLoadCount += 1
                    if catalogLoadCount == 1 {
                        await firstCatalogGate.suspend()
                        return [self.session("stored-b")]
                    }
                    await secondCatalogGate.suspend()
                    return [self.session("stored-c")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: sessionID == "stored-c" ? secondMessages : firstMessages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let firstNotification = Task { @MainActor in
            await harness.appState.openNotificationTarget(
                ConduitNotificationTarget(profile: nil, sessionId: "stored-b", type: nil)
            )
        }
        await firstCatalogGate.waitUntilSuspended()

        let secondNotification = Task { @MainActor in
            await harness.appState.openNotificationTarget(
                ConduitNotificationTarget(profile: nil, sessionId: "stored-c", type: nil)
            )
        }
        await secondCatalogGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isOpeningNotificationSession)

        firstCatalogGate.resume()
        let openedFirstNotification = await firstNotification.value
        XCTAssertFalse(openedFirstNotification)
        XCTAssertTrue(harness.appState.isOpeningNotificationSession)

        secondCatalogGate.resume()
        let openedSecondNotification = await secondNotification.value
        XCTAssertTrue(openedSecondNotification)
        XCTAssertFalse(harness.appState.isOpeningNotificationSession)
        XCTAssertEqual(harness.appState.activeSessionId, "stored-c")
        XCTAssertEqual(harness.appState.messages, secondMessages)
    }

    func testFailedNotificationOpenReleasesNotificationBusyState() async {
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in throw ControlledLifecycleError.failed }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: nil, sessionId: "stored-a", type: "response_ready")
        )

        XCTAssertFalse(opened)
        XCTAssertFalse(harness.appState.isOpeningNotificationSession)
    }

    func testNotificationDecisionSurvivesOpenWhenNotifiedSessionIsActive() async {
        // The warm-resume case: the tapped notification targets the session
        // that is already active. The push-recorded card lives only in the
        // presentation cache, while the pre-resume flush inside openSession
        // rebuilds the cache entry from the in-memory transcript — which has
        // never seen the card. The flush must preserve store-only pending
        // decisions or the merge finds nothing and the card never appears.
        let cacheSuite = "conduit.tests.notification-decision-open-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let transcript = [
            ChatMessage(id: "a1", role: .assistant, content: "Prior turn text", timestamp: "1")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-a")] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: transcript,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: cache
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = transcript

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "stored-a",
                type: "approval.needed",
                decision: .approval(
                    sessionKey: "stored-a",
                    description: "Run a dangerous shell command",
                    choices: ["once", "deny"]
                )
            )
        )

        XCTAssertTrue(opened)
        let restoredCard = harness.appState.messages.first { $0.role == .approval }
        XCTAssertEqual(restoredCard?.approval?.sessionId, "stored-a")
        XCTAssertEqual(restoredCard?.approval?.status, .pending, "The push-delivered card must survive the open and render answerable")
    }

    func testNotificationClarifyDecisionSurvivesOpenAndRendersAnswerable() async {
        let cacheSuite = "conduit.tests.notification-clarify-open-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let transcript = [
            ChatMessage(id: "a1", role: .assistant, content: "Prior turn text", timestamp: "1")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-a")] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: transcript,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: cache
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = transcript

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "stored-a",
                type: "input.needed",
                decision: .clarify(
                    requestId: "conduit-push-abc123",
                    question: "Which color?",
                    choices: ["Red", "Blue"]
                )
            )
        )

        XCTAssertTrue(opened)
        let restoredCard = harness.appState.messages.first { $0.role == .clarify }
        XCTAssertEqual(restoredCard?.clarify?.requestId, "conduit-push-abc123")
        XCTAssertEqual(restoredCard?.clarify?.status, .pending, "A relay-delivered clarify must render as a normal answerable card")
        XCTAssertEqual(restoredCard?.clarify?.questions.first?.choices.map(\.label), ["Red", "Blue"])
    }

    func testPushedBatchClarifyDecisionRendersOneCardWithAllQuestions() async throws {
        // A pushed batch decision must produce the SAME batch card model as a
        // native clarify — one ClarifyCard, every question present, relay
        // routing by the conduit-push- id prefix.
        let cacheSuite = "conduit.tests.notification-clarify-batch-open-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-a")] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: cache
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "stored-a",
                type: "input.needed",
                decision: .clarifyBatch(
                    requestId: "conduit-push-batch9",
                    questions: [
                        ClarifyQuestion(id: "environment", question: "Which environment?", choices: [
                            ClarifyChoice(label: "staging", value: "staging"),
                            ClarifyChoice(label: "prod", value: "prod")
                        ]),
                        ClarifyQuestion(id: "tests", question: "Which tests?", choices: [
                            ClarifyChoice(label: "unit", value: "unit"),
                            ClarifyChoice(label: "ui", value: "ui")
                        ], multiSelect: true)
                    ]
                )
            )
        )

        XCTAssertTrue(opened)
        let cards = harness.appState.messages.filter { $0.role == .clarify }
        XCTAssertEqual(cards.count, 1, "One pushed batch decision renders exactly one card")
        let card = try XCTUnwrap(cards.first?.clarify)
        XCTAssertEqual(card.requestId, "conduit-push-batch9")
        XCTAssertEqual(card.questions.count, 2, "No reduction to the first question")
        XCTAssertEqual(card.questions.map(\.id), ["environment", "tests"])
        XCTAssertTrue(card.questions[1].multiSelect)
        XCTAssertTrue(card.requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix), "Answers must route through the relay transport")
        XCTAssertEqual(card.status, .pending)
    }

    func testLiveClarifyEventSupersedesPushDeliveredCardForSameQuestion() async {
        let harness = makeHarness()
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = [
            ChatMessage(
                id: "clarify-conduit-push-abc123",
                role: .clarify,
                content: "Which color?",
                timestamp: "1",
                clarify: ClarifyActivity(
                    requestId: "conduit-push-abc123",
                    question: "Which color?",
                    choices: [ClarifyChoice(label: "Red", value: "Red")],
                    status: .pending,
                    answer: nil,
                    error: nil
                )
            )
        ]

        harness.appState.handleStreamEvent(
            .clarify(
                sessionId: "stored-a",
                activity: ClarifyActivity(
                    requestId: "gateway-rid-1",
                    questions: [
                        ClarifyQuestion(
                            id: "q0",
                            question: "Which color?",
                            choices: [ClarifyChoice(label: "Red", value: "Red")]
                        )
                    ]
                )
            )
        )

        let clarifyCards = harness.appState.messages.filter { $0.role == .clarify }
        XCTAssertEqual(clarifyCards.count, 1, "The still-pending push card must be superseded by the live event")
        XCTAssertEqual(clarifyCards.first?.clarify?.requestId, "gateway-rid-1")
    }

    func testLiveClarifyEventSupersedeMatchesNormalizedQuestion() async {
        // The push question is flattened plugin-side while the live event
        // carries the gateway's text; formatting drift (whitespace, case)
        // must not defeat the supersede and render two answerable cards.
        let harness = makeHarness()
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = [
            ChatMessage(
                id: "clarify-conduit-push-abc123",
                role: .clarify,
                content: "  Which Color?  ",
                timestamp: "1",
                clarify: ClarifyActivity(
                    requestId: "conduit-push-abc123",
                    question: "  Which Color?  ",
                    choices: [ClarifyChoice(label: "Red", value: "Red")],
                    status: .pending,
                    answer: nil,
                    error: nil
                )
            )
        ]

        harness.appState.handleStreamEvent(
            .clarify(
                sessionId: "stored-a",
                activity: ClarifyActivity(
                    requestId: "gateway-rid-1",
                    questions: [
                        ClarifyQuestion(id: "q0", question: "which color?", choices: [ClarifyChoice(label: "Red", value: "Red")])
                    ]
                )
            )
        )

        let clarifyCards = harness.appState.messages.filter { $0.role == .clarify }
        XCTAssertEqual(clarifyCards.count, 1, "Formatting drift must not defeat the supersede")
        XCTAssertEqual(clarifyCards.first?.clarify?.requestId, "gateway-rid-1")
    }

    func testLiveClarifyEventEvictsSupersededPushCardFromCache() async {
        // The supersede must evict the push card from the presentation cache,
        // not just the in-memory transcript: the flush re-appends still-pending
        // stored cards, and the ids can never dedupe (gateway vs plugin-minted),
        // so an in-memory-only removal would resurface as a duplicate
        // answerable card after the next cold-start resume.
        let cacheSuite = "conduit.tests.clarify-supersede-cache-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let harness = makeHarness(sessionPresentationCache: cache)
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = [
            ChatMessage(
                id: "clarify-conduit-push-abc123",
                role: .clarify,
                content: "Which color?",
                timestamp: "1",
                clarify: ClarifyActivity(
                    requestId: "conduit-push-abc123",
                    question: "Which color?",
                    choices: [ClarifyChoice(label: "Red", value: "Red")],
                    status: .pending,
                    answer: nil,
                    error: nil
                )
            )
        ]
        cache.recordPendingDecision(
            harness.appState.messages[0],
            profile: harness.appState.activeProfile,
            sessionIDs: ["stored-a"]
        )

        harness.appState.handleStreamEvent(
            .clarify(
                sessionId: "stored-a",
                activity: ClarifyActivity(
                    requestId: "gateway-rid-1",
                    questions: [
                        ClarifyQuestion(id: "q0", question: "Which color?", choices: [ClarifyChoice(label: "Red", value: "Red")])
                    ]
                )
            )
        )

        XCTAssertEqual(harness.appState.messages.filter { $0.role == .clarify }.count, 1)
        let restored = cache.merge(
            [],
            profile: harness.appState.activeProfile,
            sessionIDs: ["stored-a"],
            includePendingClarifications: true
        )
        XCTAssertFalse(
            restored.contains { $0.clarify?.requestId == "conduit-push-abc123" },
            "The superseded push card must not resurface from the cache after a cold restart"
        )
    }

    func testLiveClarifyEventPreservesAnsweredPushCardHistory() async {
        let harness = makeHarness()
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = [
            ChatMessage(
                id: "clarify-conduit-push-abc123",
                role: .clarify,
                content: "Which color?",
                timestamp: "1",
                clarify: ClarifyActivity(
                    requestId: "conduit-push-abc123",
                    question: "Which color?",
                    choices: [ClarifyChoice(label: "Red", value: "Red")],
                    status: .answered,
                    answer: "Red",
                    error: nil
                )
            )
        ]

        harness.appState.handleStreamEvent(
            .clarify(
                sessionId: "stored-a",
                activity: ClarifyActivity(
                    requestId: "gateway-rid-2",
                    questions: [
                        ClarifyQuestion(id: "q0", question: "Which color?", choices: [ClarifyChoice(label: "Red", value: "Red")])
                    ]
                )
            )
        )

        // Resolved history stays: an earlier answered card is not deleted by a
        // later clarify with identical text.
        let clarifyCards = harness.appState.messages.filter { $0.role == .clarify }
        XCTAssertEqual(clarifyCards.count, 2)
        XCTAssertTrue(clarifyCards.contains { $0.clarify?.status == .answered && $0.clarify?.questions.first?.answer == "Red" })
        XCTAssertTrue(clarifyCards.contains { $0.clarify?.requestId == "gateway-rid-2" })
    }

    func testRelayClarifyAnswerRoutedWithoutGatewayClient() async {
        // Answering a relay-delivered clarify must not require the gateway
        // client: the relay answer needs only the relay registration, and a
        // push just-resumed session is exactly when the gateway client may
        // still be nil. (Unpaired in tests, so the relay call surfaces its
        // own error rather than the gateway-unavailable one.)
        //
        // Isolated presentation cache: respondToClarify flushes the card, and
        // since errored clarifies count as unresolved decisions, a shared
        // cache would leak this card into later tests' resume merges.
        let cacheSuite = "conduit.tests.relay-clarify-no-client-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let harness = makeHarness(sessionPresentationCache: cache)
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = [
            ChatMessage(
                id: "clarify-conduit-push-abc123",
                role: .clarify,
                content: "Which color?",
                timestamp: "1",
                clarify: ClarifyActivity(
                    requestId: "conduit-push-abc123",
                    question: "Which color?",
                    choices: [ClarifyChoice(label: "Red", value: "Red")],
                    status: .pending,
                    answer: nil,
                    error: nil
                )
            )
        ]
        harness.appState.client = nil

        await harness.appState.respondToClarify(requestId: "conduit-push-abc123", answer: "Red")

        let card = harness.appState.messages.first { $0.role == .clarify }
        XCTAssertEqual(card?.clarify?.status, .error)
        XCTAssertEqual(
            card?.clarify?.questions.first?.error,
            "This device is not paired with a push relay.",
            "The relay path must run before the gateway-client guard and surface relay errors"
        )
    }

    func testNotificationDecisionWithMismatchedSessionKeyIsNotRecorded() async {
        let cacheSuite = "conduit.tests.notification-decision-mismatch-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let transcript = [
            ChatMessage(id: "a1", role: .assistant, content: "Prior turn text", timestamp: "1")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-a")] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: transcript,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: cache
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = transcript

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "stored-a",
                type: "approval.needed",
                decision: .approval(
                    sessionKey: "some-other-session",
                    description: "Not this session's approval",
                    choices: ["once", "deny"]
                )
            )
        )

        XCTAssertTrue(opened)
        XCTAssertFalse(
            harness.appState.messages.contains { $0.role == .approval },
            "A decision whose session key does not match the routed session must not be recorded"
        )
    }

    func testStaleSameTokenSyncCannotSettleNewerOpeningReconciliation() async {
        let staleCatalogGate = ControlledSuspension()
        let newerOpenGate = ControlledSuspension()
        var catalogLoadCount = 0
        let currentMessages = [
            ChatMessage(id: "current", role: .assistant, content: "Current", timestamp: "2")
        ]
        let harness = makeHarness(
            behavior: .latestActivity,
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogLoadCount += 1
                    if catalogLoadCount == 1 {
                        await staleCatalogGate.suspend()
                        return [self.session("stored-stale")]
                    }
                    return [self.session("stored-current")]
                },
                openSession: { _, sessionID, _ in
                    if sessionID == "stored-current" {
                        await newerOpenGate.suspend()
                    }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: currentMessages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        let automaticWork = harness.appState.beginAutomaticChatResumeWork()
        let reconciliation = harness.appState.beginReconciliation()

        let staleSync = Task { @MainActor in
            await harness.appState.syncSession(
                purpose: .automaticReturn,
                using: reconciliation,
                automaticWorkToken: automaticWork
            )
        }
        await staleCatalogGate.waitUntilSuspended()

        let newerSync = Task { @MainActor in
            await harness.appState.syncSession(
                purpose: .automaticReturn,
                using: reconciliation,
                automaticWorkToken: automaticWork
            )
        }
        await newerOpenGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        harness.appState.handleStreamEvent(
            .contextUpdate(sessionId: "stored-current", percent: 42, used: 42, max: 100)
        )
        XCTAssertNotEqual(harness.appState.runtime.contextUsed, 42)

        staleCatalogGate.resume()
        await staleSync.value

        XCTAssertTrue(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        XCTAssertEqual(harness.appState.activeSessionId, "stored-a")
        XCTAssertNotEqual(harness.appState.runtime.contextUsed, 42)

        newerOpenGate.resume()
        await newerSync.value

        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        XCTAssertEqual(harness.appState.activeSessionId, "stored-current")
        XCTAssertEqual(harness.appState.messages, currentMessages)
        XCTAssertEqual(harness.appState.runtime.contextUsed, 42)
    }

    func testCancellingSceneReconnectTaskWhileMintingIgnoresLateSignInFailure() async {
        let mintGate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in
                    await mintGate.suspend()
                    throw DashboardTicketBridgeError.signInRequired
                }
            )
        )
        let savedConnection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "saved-ticket"
        )
        let originalClient = HermesClient(connection: savedConnection, profile: "default")
        harness.appState.connection = savedConnection
        harness.appState.client = originalClient
        harness.appState.showLogin = false

        let sceneReconnect = harness.appState.handleScenePhase(.active)
        await mintGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isConnecting)

        harness.appState.handleScenePhase(.background)
        mintGate.resume()
        await sceneReconnect?.value

        XCTAssertFalse(harness.appState.showLogin)
        XCTAssertEqual(harness.appState.connection, savedConnection)
        XCTAssertTrue(harness.appState.client === originalClient)
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .idle)
    }

    func testSameEpochAutomaticSyncAttemptCannotOverwriteNewerAttempt() async {
        let staleCatalogGate = ControlledSuspension()
        var catalogLoadCount = 0
        let staleMessages = [
            ChatMessage(id: "stale", role: .assistant, content: "Stale", timestamp: "1")
        ]
        let currentMessages = [
            ChatMessage(id: "current", role: .assistant, content: "Current", timestamp: "2")
        ]
        let harness = makeHarness(
            behavior: .latestActivity,
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogLoadCount += 1
                    if catalogLoadCount == 1 {
                        await staleCatalogGate.suspend()
                        return [self.session("stored-stale")]
                    }
                    return [self.session("stored-current")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: sessionID == "stored-current" ? currentMessages : staleMessages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        let automaticWork = harness.appState.beginAutomaticChatResumeWork()
        let reconciliation = harness.appState.beginReconciliation()

        let staleSync = Task { @MainActor in
            await harness.appState.syncSession(
                purpose: .automaticReturn,
                using: reconciliation,
                automaticWorkToken: automaticWork
            )
        }
        await staleCatalogGate.waitUntilSuspended()

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: reconciliation,
            automaticWorkToken: automaticWork
        )
        XCTAssertEqual(harness.appState.activeSessionId, "stored-current")
        XCTAssertEqual(harness.appState.messages, currentMessages)

        staleCatalogGate.resume()
        await staleSync.value

        XCTAssertEqual(harness.appState.sessions.map(\.id), ["stored-current"])
        XCTAssertEqual(harness.appState.activeSessionId, "stored-current")
        XCTAssertEqual(harness.appState.messages, currentMessages)
    }

    func testAuthoritativeEmptyTranscriptSettlesFromScopedRevisionZeroLayout() async {
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        let keyA = ChatScrollSessionKey(profile: "default", sessionID: sessionA.id)
        let keyB = ChatScrollSessionKey(profile: "default", sessionID: sessionB.id)
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(
                sessionKey: keyA,
                snapshot: ChatScrollSnapshot(anchorMessageID: "old-anchor", followsLatest: false)
            )
        }

        let openedEmptySession = await harness.appState.openSession(sessionB.id)
        XCTAssertTrue(openedEmptySession)
        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: keyB,
            transitionGeneration: harness.appState.chatViewportTransitionGeneration,
            transcriptRevision: harness.appState.chatTranscriptRevision,
            renderRevision: 0,
            receivedScopedPreference: true
        )
        harness.appState.recordChatViewport(.latest, for: keyB)
        harness.appState.flushChatResumeViewport()

        XCTAssertEqual(harness.store.snapshot(for: keyB), .latest)
    }

    func testPostAuthoritativeTranscriptMutationAdvancesExpectedLayoutRevision() async {
        let appReference = WeakAppStateReference()
        let oldMessages = [
            ChatMessage(id: "old", role: .assistant, content: "Old", timestamp: "1")
        ]
        let authoritativeMessages = [
            ChatMessage(id: "new", role: .assistant, content: "New", timestamp: "2")
        ]
        let lateMessage = ChatMessage(
            id: "late",
            role: .assistant,
            content: "Late authoritative event",
            timestamp: "3"
        )
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: authoritativeMessages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in
                    appReference.value?.messages.append(lateMessage)
                }
            )
        )
        appReference.value = harness.appState
        let active = session("stored-a")
        let key = ChatScrollSessionKey(profile: "default", sessionID: active.id)
        let captured = ChatScrollSnapshot(anchorMessageID: "old-anchor", followsLatest: false)
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = oldMessages
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(sessionKey: key, snapshot: captured)
        }

        await harness.appState.refreshActiveSession()
        let generation = harness.appState.chatViewportTransitionGeneration
        let currentRevision = harness.appState.chatTranscriptRevision
        XCTAssertEqual(harness.appState.messages, authoritativeMessages + [lateMessage])

        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: key,
            transitionGeneration: generation,
            transcriptRevision: currentRevision - 1,
            renderRevision: 8,
            receivedScopedPreference: true
        )
        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: key), captured)

        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: key,
            transitionGeneration: generation,
            transcriptRevision: currentRevision,
            renderRevision: 9,
            receivedScopedPreference: true
        )
        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
    }

    func testStaleNotificationContinuationCannotSupersedeNewerSessionTransition() async {
        let notificationCatalogGate = ControlledSuspension()
        let messagesB = [
            ChatMessage(id: "b", role: .assistant, content: "B", timestamp: "1")
        ]
        let messagesC = [
            ChatMessage(id: "c", role: .assistant, content: "C", timestamp: "2")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    await notificationCatalogGate.suspend()
                    return [self.session("stored-b")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: sessionID == "stored-c" ? messagesC : messagesB,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let sessionA = session("stored-a")
        let sessionC = session("stored-c")
        let keyC = ChatScrollSessionKey(profile: "default", sessionID: sessionC.id)
        let connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.connection = connection
        harness.appState.client = HermesClient(
            connection: connection,
            profile: "default"
        )
        harness.appState.sessions = [sessionA, sessionC]
        harness.appState.activeSessionId = sessionA.id

        let notification = Task { @MainActor in
            await harness.appState.openNotificationTarget(
                ConduitNotificationTarget(profile: nil, sessionId: "stored-b", type: nil)
            )
        }
        await notificationCatalogGate.waitUntilSuspended()

        let openedNewerSession = await harness.appState.openSession(sessionC.id)
        XCTAssertTrue(openedNewerSession)
        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: keyC,
            transitionGeneration: harness.appState.chatViewportTransitionGeneration,
            transcriptRevision: harness.appState.chatTranscriptRevision,
            renderRevision: 4,
            receivedScopedPreference: true
        )
        notificationCatalogGate.resume()
        let openedNotification = await notification.value
        XCTAssertFalse(openedNotification)

        XCTAssertEqual(harness.appState.activeSessionId, sessionC.id)
        XCTAssertEqual(harness.appState.messages, messagesC)
        XCTAssertEqual(harness.appState.sessions.map(\.id), [sessionA.id, sessionC.id])
    }

    func testNotificationWithExplicitDurableIdentityOpensDurableConversationWithoutCatalog() async {
        // A payload that carries both identities must route by the durable
        // id without needing the catalog to rediscover it — a stale or empty
        // catalog may never block explicit identity.
        var requests: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    return SessionResumeResult(
                        sessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "runtime-a",
                durableSessionID: "stored-a",
                type: nil
            )
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(requests, ["stored-a"], "The explicit durable id is the resume target")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a")
    }

    func testRuntimeOnlyNotificationUsesConfirmedIndexAliasWhenCatalogOmitsRuntime() async {
        // Older payload (runtime id only), and the refreshed catalog does not
        // contain runtime-a. The confirmed runtime→durable mapping recorded
        // by an earlier admitted resume must still route to stored-a.
        var requests: [String] = []
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-a",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    return SessionResumeResult(
                        sessionId: "runtime-a",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            conversationIdentityIndex: index
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: nil, sessionId: "runtime-a", type: nil)
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(requests, ["stored-a"], "The confirmed alias routes without the catalog")
    }

    func testUnknownRuntimeNotificationDoesNotReinterpretAsDurableConversation() async {
        // A runtime id with no positive durable evidence resumes ITSELF.
        // It must never fall through to another catalog row — there is no
        // newest-chat, ordering, or similarity fallback in notification
        // routing.
        var requests: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-z")] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: nil, sessionId: "runtime-unknown", type: nil)
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(requests, ["runtime-unknown"], "Only the named id may be resumed")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-unknown")
    }

    func testNotificationOpenCommitsAdmittedRuntimeDurableEvidenceToSharedIndex() async {
        // After a notification open establishes the runtime→durable mapping,
        // the shared index answers later lookups even when the catalog then
        // omits the runtime alias.
        let index = ConversationIdentityIndex()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-a")] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: "runtime-new",
                        storedSessionId: "stored-a",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            conversationIdentityIndex: index
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: nil, sessionId: "runtime-new", type: nil)
        )
        XCTAssertTrue(opened)

        // Catalog row stored-a carries no runtime-new alias; only the
        // admitted resume result could have established the mapping.
        harness.appState.sessions = [self.session("stored-a")]
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-new", profile: "default"),
            "stored-a",
            "The admitted resume must commit its evidence to the shared index"
        )
        // A different profile must not see it.
        XCTAssertNil(index.durableID(forRuntime: "runtime-new", profile: "work"))
    }

    func testServerChangeClearsIdentityIndexAndSessionScopedOverrides() async {
        // Server A and server B both know profile "default" with the same
        // session strings. Nothing confirmed against A may answer lookups
        // after the connection moves to B.
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-a",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        let yoloDefaultsSuite = "AppStateChatResumeTests.yolo.\(UUID().uuidString)"
        guard let yoloDefaults = UserDefaults(suiteName: yoloDefaultsSuite) else {
            XCTFail("Could not create yolo defaults suite")
            return
        }
        addTeardownBlock { yoloDefaults.removePersistentDomain(forName: yoloDefaultsSuite) }
        let yoloStore = SessionYoloStore(defaults: yoloDefaults)
        yoloStore.setOverride(true, for: "default", sessionID: "stored-a")

        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("stored-a", alternateIDs: ["runtime-a"])] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: "runtime-a",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            conversationIdentityIndex: index,
            sessionYoloStore: yoloStore
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [self.session("stored-a", alternateIDs: ["runtime-a"])]
        harness.appState.activeSessionId = "runtime-a"
        harness.store.setLastSessionID("stored-a", for: "default")
        harness.defaults.set("https://a.example", forKey: "conduit.chatResumeServerIdentity.v1")

        let changed = harness.appState.prepareChatResumeForConnection(to: "https://b.example")
        XCTAssertTrue(changed)

        XCTAssertNil(
            index.durableID(forRuntime: "runtime-a", profile: "default"),
            "Identity evidence from server A must not survive the server change"
        )
        XCTAssertNil(
            yoloStore.storedOverride(for: "default", sessionID: "stored-a"),
            "Session-scoped overrides must not leak between servers"
        )
        XCTAssertNil(harness.appState.activeSessionId)
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
    }

    func testDeleteRevokesIdentityIndexMappingsAndPersistedConversationState() async {
        // Explicit deletion revokes identity: the index mapping, the scroll
        // snapshot, the last-selected pointer, and the cached presentation
        // (with any pending card) must all go.
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-a",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        let cacheSuite = "conduit.tests.identity-delete-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create cache defaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        cache.recordPendingDecision(
            ChatMessage(
                id: "approval-stored-a",
                role: .approval,
                content: "Approve?",
                timestamp: "1",
                approval: ApprovalActivity(
                    sessionId: "stored-a",
                    command: "",
                    description: "Approve?",
                    choices: ["once", "deny"],
                    allowPermanent: false,
                    smartDenied: false,
                    status: .pending,
                    choice: nil,
                    error: nil
                )
            ),
            profile: "default",
            sessionIDs: ["stored-a", "runtime-a"]
        )
        let harness = makeHarness(
            sessionPresentationCache: cache,
            conversationIdentityIndex: index
        )
        harness.coordinator.rememberSessionID("stored-a", for: "default")
        harness.store.save(
            ChatScrollSnapshot(anchorMessageID: "anchor", followsLatest: false),
            for: ChatScrollSessionKey(profile: "default", sessionID: "stored-a"),
            at: Date()
        )

        harness.appState.revokeDeletedConversationIdentity(
            sessionIDs: ["stored-a", "runtime-a"],
            profile: "default"
        )

        XCTAssertNil(
            index.durableID(forRuntime: "runtime-a", profile: "default"),
            "A deleted conversation's aliases must not route anything afterward"
        )
        XCTAssertNil(
            harness.store.snapshot(for: ChatScrollSessionKey(profile: "default", sessionID: "stored-a")),
            "The deleted conversation's scroll snapshot is removed"
        )
        XCTAssertNil(
            harness.store.lastSessionID(for: "default"),
            "The deleted conversation cannot stay the last-selected conversation"
        )
        let remainingCards = cache.merge(
            [ChatMessage(id: "probe", role: .assistant, content: "Probe", timestamp: "")],
            profile: "default",
            sessionIDs: ["stored-a"],
            includePendingApprovals: true
        )
        XCTAssertNil(
            remainingCards.first?.approval,
            "The deleted conversation's cached pending card is removed"
        )
    }

    func testAdmittedResumeRebindsStaleIndexMappingToSelectedConversation() async {
        // The exact split-brain repro: the index holds a historical
        // runtime-x → stored-b mapping, the catalog temporarily omits
        // runtime-x, and resume(stored-a) is admitted returning runtime-x
        // with no stored id (legacy rebind). The app adopted runtime-x for
        // stored-a — the index must agree afterwards, never keep stored-b.
        var requests: [String] = []
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-b",
            profile: "default",
            source: .resume
        )
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    return SessionResumeResult(
                        sessionId: "runtime-x",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            ),
            conversationIdentityIndex: index
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.activeSessionId = "stored-a"

        await harness.appState.syncSession()

        XCTAssertEqual(requests, ["stored-a"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-x")
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-x", profile: "default"),
            "stored-a",
            "After an admitted resume the index and the selected conversation must agree"
        )
    }

    func testStaleDualIdentityNotificationIsRejectedWithoutPoisoningIndex() async {
        // Live truth: runtime-x belongs to stored-b (authoritative registry
        // + catalog). A stale push claims runtime-x + stored-a. The routing
        // attempt follows the payload, resume/admission rejects the
        // contradiction, the open fails — the index still says runtime-x
        // → stored-b, and NEITHER durable conversation's presentation cache
        // is touched by the rejected promotion attempt.
        var requests: [String] = []
        let index = ConversationIdentityIndex()
        index.recordAuthoritative(
            runtimeID: "runtime-x",
            durableID: "stored-b",
            profile: "default",
            source: .activeList
        )
        let cacheSuite = "conduit.tests.promotion-rejected-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create cache defaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let transcriptA = [
            ChatMessage(id: "a-row", role: .assistant, content: "A presentation", timestamp: "a-ts")
        ]
        let transcriptB = [
            ChatMessage(id: "b-row", role: .assistant, content: "B presentation", timestamp: "b-ts")
        ]
        cache.save(transcriptA, profile: "default", sessionIDs: ["stored-a"])
        cache.save(transcriptB, profile: "default", sessionIDs: ["stored-b"])
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [
                    self.session("stored-b", storedID: "stored-b", alternateIDs: ["runtime-x"])
                ] },
                openSession: { _, sessionID, _ in
                    requests.append(sessionID)
                    return SessionResumeResult(
                        sessionId: "runtime-x",
                        storedSessionId: "stored-b",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: cache,
            conversationIdentityIndex: index
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "runtime-x",
                durableSessionID: "stored-a",
                type: "approval.needed",
                decision: .approval(
                    sessionKey: "runtime-x",
                    description: "Stale push approval",
                    choices: ["once", "deny"]
                )
            )
        )

        XCTAssertFalse(opened, "The payload's stale durable claim contradicts live truth and must fail")
        XCTAssertEqual(requests, ["stored-a"], "The attempt followed the payload's explicit durable id")
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-x", profile: "default"),
            "stored-b",
            "The rejected navigation must not poison the authoritative mapping"
        )
        XCTAssertEqual(
            harness.appState.activeSessionId, "stored-a",
            "The rejected open does not navigate to stored-b (foreign durable ownership)"
        )
        XCTAssertNotEqual(
            harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-b",
            "The rejected claim must not re-home the scroll canonical onto stored-b"
        )
        // Neither durable conversation inherited anything from the rejected
        // promotion attempt: stored-a's and stored-b's cached presentation
        // are exactly what they were, with no pending card injected.
        XCTAssertTrue(
            cache.merge(transcriptA, profile: "default", sessionIDs: ["stored-a"], includePendingApprovals: true)
                .filter { $0.role == .approval }.isEmpty,
            "The claimed durable (stored-a) must not gain the rejected card"
        )
        XCTAssertEqual(
            cache.merge(transcriptB, profile: "default", sessionIDs: ["stored-b"], includePendingApprovals: true)
                .first?.timestamp,
            "b-ts",
            "stored-b's durable presentation is unchanged"
        )
        XCTAssertTrue(
            cache.storedPendingDecisionKeys(profile: "default", sessionIDs: ["stored-a", "stored-b"]).isEmpty,
            "No pending decision from the rejected push lives under either durable key"
        )
    }

    func testRejectedPushResidueCannotPromoteIntoTrueOwnerOnLaterOpen() async {
        // The rejection-eviction invariant, extended: the rejected push's
        // card was pre-recorded under runtime-x. A LATER legitimate open of
        // stored-b (runtime-x's true owner) must not promote that stale card
        // into stored-b — the rejection evicted it.
        let index = ConversationIdentityIndex()
        index.recordAuthoritative(
            runtimeID: "runtime-x",
            durableID: "stored-b",
            profile: "default",
            source: .activeList
        )
        let cacheSuite = "conduit.tests.promotion-eviction-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create cache defaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        cache.save(
            [ChatMessage(id: "b-row", role: .assistant, content: "B transcript", timestamp: "b-ts")],
            profile: "default",
            sessionIDs: ["stored-b"]
        )
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [
                    self.session("stored-b", storedID: "stored-b", alternateIDs: ["runtime-x"])
                ] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: "runtime-x",
                        storedSessionId: "stored-b",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: cache,
            conversationIdentityIndex: index
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        // 1. The stale push is rejected by identity admission.
        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "runtime-x",
                durableSessionID: "stored-a",
                type: "approval.needed",
                decision: .approval(
                    sessionKey: "runtime-x",
                    description: "Stale push approval",
                    choices: ["once", "deny"]
                )
            )
        )
        XCTAssertFalse(opened)

        // 2. A later legitimate open of the true owner (stored-b) must not
        // surface the rejected card.
        let openedOwner = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedOwner)
        XCTAssertTrue(
            harness.appState.messages.filter { $0.role == .approval }.isEmpty,
            "The rejected push's card must not surface in the true owner's transcript"
        )
        XCTAssertTrue(
            cache.storedPendingDecisionKeys(profile: "default", sessionIDs: ["stored-b"]).isEmpty,
            "And it must not have been promoted into stored-b's durable cache"
        )
    }

    func testActiveListEvidenceIsRecordedAndRemainsObservational() {
        // The live registry feeds the index (authoritative), and unrelated
        // rows never change the selected conversation: recording is
        // observational only.
        let index = ConversationIdentityIndex()
        let harness = makeHarness(conversationIdentityIndex: index)
        harness.appState.sessions = [self.session("kept-selected")]
        harness.appState.activeSessionId = "kept-selected"

        harness.appState.recordActiveListEvidence(
            [
                LiveSessionStatus(
                    runtimeSessionId: "runtime-x",
                    storedSessionId: "stored-a",
                    status: "working"
                ),
                LiveSessionStatus(
                    runtimeSessionId: "runtime-unrelated",
                    storedSessionId: "stored-unrelated",
                    status: "idle"
                ),
            ],
            profile: "default"
        )

        XCTAssertEqual(index.durableID(forRuntime: "runtime-x", profile: "default"), "stored-a")
        XCTAssertEqual(index.durableID(forRuntime: "runtime-unrelated", profile: "default"), "stored-unrelated")
        XCTAssertEqual(
            harness.appState.activeSessionId, "kept-selected",
            "Registry rows must never navigate or reselect"
        )
        // Foreign-profile isolation at the same boundary.
        index.recordAuthoritative(
            runtimeID: "runtime-x",
            durableID: "stored-work",
            profile: "work",
            source: .activeList
        )
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-x", profile: "default"),
            "stored-a",
            "Another profile's registry rows cannot reattribute this profile's runtime"
        )
    }

    func testConfirmedAliasNotificationDecisionSurvivesRotatedRuntimePromotion() async {
        // The promotion case: a confirmedAlias notification carries a pending
        // approval under runtime-old; the resume of stored-a is admitted and
        // returns a ROTATED runtime (runtime-new) that was never in the
        // accepted set. The pre-open card (cached under runtime-old) must be
        // promoted into the durable conversation and answer there, the
        // runtime keys must be retired, and the index must keep both runtimes
        // pointing at stored-a.
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-old",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        let cacheSuite = "conduit.tests.promotion-rotated-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create cache defaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: "runtime-new",
                        storedSessionId: "stored-a",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: cache,
            conversationIdentityIndex: index
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "runtime-old",
                type: "approval.needed",
                decision: .approval(
                    sessionKey: "runtime-old",
                    description: "Push approval",
                    choices: ["once", "deny"]
                )
            )
        )

        XCTAssertTrue(opened)
        let card = harness.appState.messages.first { $0.role == .approval }
        XCTAssertEqual(card?.approval?.description, "Push approval", "The push card is restored into the transcript")
        XCTAssertEqual(
            card?.approval?.sessionId, "stored-a",
            "The promoted card answers against the durable session"
        )
        XCTAssertEqual(
            harness.appState.activeSessionId, "runtime-new",
            "The admitted rotated runtime is the live selection"
        )
        // Durable cache: the card lives under stored-a; neither runtime key
        // remains an independent presentation owner.
        XCTAssertEqual(
            cache.storedPendingDecisionKeys(profile: "default", sessionIDs: ["stored-a"]),
            ["approval:stored-a"]
        )
        XCTAssertTrue(cache.storedPendingDecisionKeys(profile: "default", sessionIDs: ["runtime-old"]).isEmpty)
        XCTAssertTrue(cache.storedPendingDecisionKeys(profile: "default", sessionIDs: ["runtime-new"]).isEmpty)
        // Identity: both runtimes belong to stored-a.
        XCTAssertEqual(index.durableID(forRuntime: "runtime-old", profile: "default"), "stored-a")
        XCTAssertEqual(index.durableID(forRuntime: "runtime-new", profile: "default"), "stored-a")
    }

    func testExistingDurableCacheGainsNotificationApprovalUnderDurableKey() async {
        // The durable record already holds presentation when the
        // notification arrives. The open must keep the existing durable
        // presentation, promote the fresh pending approval into the durable
        // key, route it to stored-a, retire the runtime key, and never
        // duplicate the card.
        let cacheSuite = "conduit.tests.promotion-existing-\(UUID().uuidString)"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create cache defaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: cacheDefaults)
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let durableTranscript = [
            ChatMessage(id: "d1", role: .assistant, content: "Existing durable row", timestamp: "durable-ts")
        ]
        cache.save(durableTranscript, profile: "default", sessionIDs: ["stored-a"])
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    // A real resume of stored-a returns the conversation's
                    // own rows (Hermes compact shape: no cached timestamps).
                    SessionResumeResult(
                        sessionId: "runtime-x",
                        storedSessionId: "stored-a",
                        messages: [
                            ChatMessage(id: "d1", role: .assistant, content: "Existing durable row", timestamp: "")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: cache,
            conversationIdentityIndex: index
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")

        let opened = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: nil,
                sessionId: "runtime-x",
                type: "approval.needed",
                decision: .approval(
                    sessionKey: "runtime-x",
                    description: "Newest approval",
                    choices: ["once", "deny"]
                )
            )
        )

        XCTAssertTrue(opened)
        // Existing durable presentation survives: the resumed row is
        // enriched from the durable key (had consolidation dropped or
        // replaced it, the timestamp would be lost).
        XCTAssertEqual(
            harness.appState.messages.first(where: { $0.id == "d1" })?.timestamp, "durable-ts",
            "Existing durable presentation survives the promotion"
        )
        let cards = harness.appState.messages.filter { $0.role == .approval }
        XCTAssertEqual(cards.count, 1, "Exactly one pending card")
        XCTAssertEqual(cards.first?.approval?.sessionId, "stored-a", "The card routes to the durable session")
        XCTAssertEqual(
            cache.storedPendingDecisionKeys(profile: "default", sessionIDs: ["stored-a"]),
            ["approval:stored-a"]
        )
        XCTAssertTrue(
            cache.storedPendingDecisionKeys(profile: "default", sessionIDs: ["runtime-x"]).isEmpty,
            "The runtime-x cache key is retired"
        )
    }

    func testCancelledAutomaticSyncRestoresComposerStateAfterCatalogReturns() async {
        let gate = ControlledSuspension()
        let catalog = [session("stored-b"), session("stored-a")]
        let harness = makeHarness(
            behavior: .latestActivity,
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    await gate.suspend()
                    return catalog
                }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = catalog
        harness.appState.activeSessionId = "stored-a"
        let automaticWork = harness.appState.beginAutomaticChatResumeWork()

        let sync = Task { @MainActor in
            await harness.appState.syncSession(
                purpose: .automaticReturn,
                using: nil,
                automaticWorkToken: automaticWork
            )
        }
        await gate.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .synchronizing)

        harness.appState.cancelChatResumeRestoration()
        XCTAssertEqual(harness.appState.turnState, .idle)
        gate.resume()
        await sync.value

        XCTAssertEqual(harness.appState.activeSessionId, "stored-a")
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertNil(harness.appState.chatResumeRestorationRequest)
    }

    func testStaleAutomaticSyncCleanupDoesNotOverwriteNewerSyncState() async {
        let firstGate = ControlledSuspension()
        let secondGate = ControlledSuspension()
        var loadCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    loadCount += 1
                    if loadCount == 1 {
                        await firstGate.suspend()
                    } else {
                        await secondGate.suspend()
                    }
                    return []
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let automaticWork = harness.appState.beginAutomaticChatResumeWork()

        let first = Task { @MainActor in
            await harness.appState.syncSession(
                purpose: .automaticReturn,
                using: nil,
                automaticWorkToken: automaticWork
            )
        }
        await firstGate.waitUntilSuspended()
        let second = Task { @MainActor in
            await harness.appState.syncSession(
                purpose: .automaticReturn,
                using: nil,
                automaticWorkToken: automaticWork
            )
        }
        await secondGate.waitUntilSuspended()

        firstGate.resume()
        await first.value
        XCTAssertEqual(harness.appState.turnState, .synchronizing)

        harness.appState.cancelChatResumeRestoration()
        XCTAssertEqual(harness.appState.turnState, .idle)
        secondGate.resume()
        await second.value
    }

    func testViewportCancellationLetsReconnectFinishWithAuthoritativeSignInFailure() async {
        let gate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in
                    await gate.suspend()
                    throw DashboardTicketBridgeError.signInRequired
                }
            )
        )
        let savedConnection = HermesConnection(baseUrl: "https://one.example", ticket: "saved-ticket")
        let originalClient = HermesClient(connection: savedConnection, profile: "default")
        harness.appState.connection = savedConnection
        harness.appState.client = originalClient
        harness.appState.showLogin = false

        let reconnect = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await gate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .reconnecting)

        harness.appState.cancelChatResumeRestoration()
        XCTAssertTrue(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        gate.resume()
        await reconnect.value

        XCTAssertTrue(harness.appState.showLogin)
        XCTAssertNil(harness.appState.connection)
        XCTAssertNil(harness.appState.client)
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
    }

    func testViewportCancellationDuringInitialConnectHandsOffToOnePreserveCurrentRetry() async {
        let connectGate = ControlledSuspension()
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in
                reconnectSpy.purposes.append(purpose)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in
                    await connectGate.suspend()
                    throw ControlledLifecycleError.failed
                }
            )
        )
        let connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "initial-ticket"
        )

        let connect = Task { @MainActor in
            await harness.appState.connect(with: connection)
        }
        await connectGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isConnecting)

        harness.appState.cancelChatResumeRestoration()
        XCTAssertTrue(harness.appState.isConnecting)

        connectGate.resume()
        await connect.value
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .reconnecting)

        await scheduler.runAll()
        XCTAssertEqual(scheduler.cancelledCount, 0)
        XCTAssertEqual(reconnectSpy.purposes, [.preserveCurrent])
    }

    func testBehaviorChangeDuringReconnectHandsOffToOnePreserveCurrentRetry() async {
        let connectGate = ControlledSuspension()
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in
                reconnectSpy.purposes.append(purpose)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in
                    await connectGate.suspend()
                    throw ControlledLifecycleError.failed
                },
                mintTicket: { _ in "refreshed-ticket" }
            )
        )
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "saved-ticket"
        )
        harness.appState.activeSessionId = "stored-visible"

        let reconnect = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await connectGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .reconnecting)

        harness.appState.setChatResumeBehavior(.latestActivity)
        XCTAssertTrue(harness.appState.isConnecting)

        connectGate.resume()
        await reconnect.value
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .reconnecting)

        await scheduler.runAll()
        XCTAssertEqual(scheduler.cancelledCount, 0)
        XCTAssertEqual(reconnectSpy.purposes, [.preserveCurrent])
    }

    func testFailedAutomaticReconnectRetriesWithoutStickyAutomaticSelection() async {
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in reconnectSpy.purposes.append(purpose) },
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in throw ControlledLifecycleError.failed },
                mintTicket: { _ in "refreshed-ticket" }
            )
        )
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "saved-ticket"
        )
        let visible = session("stored-visible")
        harness.appState.sessions = [visible]
        harness.appState.activeSessionId = visible.id

        await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        await scheduler.runAll()

        XCTAssertEqual(reconnectSpy.purposes, [.preserveCurrent])
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent)
        XCTAssertEqual(harness.appState.activeSessionId, visible.id)
    }

    func testFailedColdAutomaticReconnectRetainsSavedSessionPurpose() async {
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in reconnectSpy.purposes.append(purpose) },
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in throw ControlledLifecycleError.failed },
                mintTicket: { _ in "refreshed-ticket" }
            )
        )
        harness.coordinator.rememberSessionID("stored-saved", for: "default")
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "saved-ticket"
        )

        await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        await scheduler.runAll()

        XCTAssertEqual(reconnectSpy.purposes, [.automaticReturn])
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .automaticReturn)
    }

    func testViewportCancellationDuringInitialConnectHandsOffToPreserveCurrentSynchronization() async {
        let catalogGate = ControlledSuspension()
        let scheduler = ControlledReconnectScheduler()
        let active = session("stored-a")
        let restoredMessages = [
            ChatMessage(id: "restored", role: .assistant, content: "Restored", timestamp: "1")
        ]
        var catalogLoadCount = 0
        var openedSessionIDs: [String] = []
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in
                    catalogLoadCount += 1
                    if catalogLoadCount == 1 {
                        await catalogGate.suspend()
                    }
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    openedSessionIDs.append(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: restoredMessages,
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        harness.coordinator.rememberSessionID(active.id, for: "default")
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "initial-ticket"
        )

        let connecting = Task { @MainActor in
            await harness.appState.connect(with: connection)
        }
        await catalogGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertEqual(harness.appState.turnState, .synchronizing)

        harness.appState.cancelChatResumeRestoration()
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .synchronizing)
        catalogGate.resume()
        await connecting.value

        XCTAssertEqual(catalogLoadCount, 2)
        // The dashboard bridge created by connect() is cold, so the resume
        // begins compact (omit_messages). A bridge that never becomes ready
        // inside its bounded readiness poll must NOT escalate to the legacy
        // full-transcript resume: the bounded history failure surfaces
        // (turnState .reconnecting) and the bounded request retries through
        // reconnect recovery instead — never a giant WebSocket transcript.
        // The viewport-cancellation handoff under test is unchanged by that
        // outcome.
        XCTAssertEqual(openedSessionIDs, [active.id])
        XCTAssertEqual(harness.appState.activeSessionId, active.id)
        XCTAssertTrue(harness.appState.messages.isEmpty)
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        XCTAssertFalse(harness.appState.composerIsEnabled)
        XCTAssertNil(harness.appState.chatResumeRestorationRequest)
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    func testBehaviorChangeDuringReconnectHandsOffToPreserveCurrentSynchronization() async {
        let openGate = ControlledSuspension()
        let scheduler = ControlledReconnectScheduler()
        let active = session("stored-a")
        let restoredMessages = [
            ChatMessage(id: "restored", role: .assistant, content: "Restored", timestamp: "1")
        ]
        var catalogLoadCount = 0
        var openCount = 0
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in
                    catalogLoadCount += 1
                    return [active]
                },
                mintTicket: { _ in "refreshed-ticket" },
                openSession: { _, sessionID, _ in
                    openCount += 1
                    if openCount == 1 {
                        await openGate.suspend()
                    }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: restoredMessages,
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        let savedConnection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "saved-ticket"
        )
        harness.appState.connection = savedConnection
        harness.appState.client = HermesClient(connection: savedConnection, profile: "default")
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        let reconnecting = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await openGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertEqual(harness.appState.turnState, .synchronizing)

        harness.appState.setChatResumeBehavior(.latestActivity)
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        openGate.resume()
        await reconnecting.value

        XCTAssertEqual(catalogLoadCount, 2)
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(harness.appState.connection?.ticket, "refreshed-ticket")
        XCTAssertEqual(harness.appState.activeSessionId, active.id)
        XCTAssertEqual(harness.appState.messages, restoredMessages)
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertNil(harness.appState.chatResumeRestorationRequest)
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    func testProfileSwitchRejectsSuccessfulStaleAutomaticReconnectMint() async {
        await assertProfileSwitchCancelsStaleReconnectMint(outcome: .success)
    }

    func testProfileSwitchRejectsStaleAutomaticReconnectSignInFailure() async {
        await assertProfileSwitchCancelsStaleReconnectMint(outcome: .signInRequired)
    }

    func testUnchangedRefreshReleasesViewportTransitionForLaterWrites() async {
        let messages = [
            ChatMessage(id: "message-a", role: .assistant, content: "Stable", timestamp: "now")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: messages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let active = session("stored-a")
        let key = ChatScrollSessionKey(profile: "default", sessionID: active.id)
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = messages
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(
                sessionKey: key,
                snapshot: ChatScrollSnapshot(
                    anchorMessageID: "anchor-before-refresh",
                    followsLatest: false
                )
            )
        }

        await harness.appState.refreshActiveSession()
        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()

        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
    }

    func testChangedRefreshReleasesOnlyForMatchingLayoutRevision() async {
        let oldMessages = [
            ChatMessage(id: "old", role: .assistant, content: "Old", timestamp: "1")
        ]
        let newMessages = [
            ChatMessage(id: "new", role: .assistant, content: "New", timestamp: "2")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: newMessages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let active = session("stored-a")
        let key = ChatScrollSessionKey(profile: "default", sessionID: active.id)
        let captured = ChatScrollSnapshot(anchorMessageID: "old-anchor", followsLatest: false)
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = oldMessages
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(sessionKey: key, snapshot: captured)
        }

        await harness.appState.refreshActiveSession()
        let generation = harness.appState.chatViewportTransitionGeneration
        let transcriptRevision = harness.appState.chatTranscriptRevision

        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: key,
            transitionGeneration: generation,
            transcriptRevision: transcriptRevision - 1,
            renderRevision: 7,
            receivedScopedPreference: true
        )
        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: key), captured)

        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: key,
            transitionGeneration: generation,
            transcriptRevision: transcriptRevision,
            renderRevision: 7,
            receivedScopedPreference: true
        )
        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
    }

    func testOpenSessionTeardownLayoutCannotReleaseTransitionBeforeReconciliation() async {
        let gate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    await gate.suspend()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(id: "new", role: .assistant, content: "New", timestamp: "2")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        let keyA = ChatScrollSessionKey(profile: "default", sessionID: sessionA.id)
        let keyB = ChatScrollSessionKey(profile: "default", sessionID: sessionB.id)
        let captured = ChatScrollSnapshot(anchorMessageID: "exact-a-anchor", followsLatest: false)
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id
        harness.appState.messages = [
            ChatMessage(id: "old", role: .assistant, content: "Old", timestamp: "1")
        ]
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(sessionKey: keyA, snapshot: captured)
        }

        let opening = Task { @MainActor in
            await harness.appState.openSession(sessionB.id)
        }
        await gate.waitUntilSuspended()
        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: keyB,
            transitionGeneration: harness.appState.chatViewportTransitionGeneration,
            transcriptRevision: harness.appState.chatTranscriptRevision,
            renderRevision: 2,
            receivedScopedPreference: true
        )
        harness.appState.recordChatViewport(.latest, for: keyA)
        harness.appState.flushChatResumeViewport()

        XCTAssertEqual(harness.store.snapshot(for: keyA), captured)
        XCTAssertNil(harness.store.snapshot(for: keyB))
        gate.resume()
        let opened = await opening.value
        XCTAssertTrue(opened)
    }

    func testFailedBranchReconciliationReleasesViewportTransitionForLaterWrites() async {
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, _, _ in throw ControlledLifecycleError.failed },
                branchSession: { _, _, _, _, _ in
                    (sessionId: "branch-runtime", storedSessionId: "branch-stored", profile: "default")
                },
                setSessionTitle: { _, _, _ in }
            )
        )
        let parent = session("stored-a")
        let key = ChatScrollSessionKey(profile: "default", sessionID: parent.id)
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [parent]
        harness.appState.activeSessionId = parent.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1"),
            ChatMessage(id: "assistant", role: .assistant, content: "Answer", timestamp: "2")
        ]
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(
                sessionKey: key,
                snapshot: ChatScrollSnapshot(
                    anchorMessageID: "anchor-before-branch",
                    followsLatest: false
                )
            )
        }

        await harness.appState.branchFromAssistantMessage("assistant")
        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()

        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
    }

    func testSupersededBranchCannotKeepNewerRefreshTransitionFrozen() async {
        let branchGate = ControlledSuspension()
        let parentMessages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1"),
            ChatMessage(id: "assistant", role: .assistant, content: "Answer", timestamp: "2")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    if sessionID == "branch-runtime" {
                        await branchGate.suspend()
                    }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: parentMessages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                branchSession: { _, _, _, _, _ in
                    (sessionId: "branch-runtime", storedSessionId: "branch-stored", profile: "default")
                },
                setSessionTitle: { _, _, _ in },
                refreshContext: { _, _ in }
            )
        )
        let parent = session("stored-a")
        let key = ChatScrollSessionKey(profile: "default", sessionID: parent.id)
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [parent]
        harness.appState.activeSessionId = parent.id
        harness.appState.messages = parentMessages
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(
                sessionKey: key,
                snapshot: ChatScrollSnapshot(
                    anchorMessageID: "anchor-before-branch",
                    followsLatest: false
                )
            )
        }

        let branch = Task { @MainActor in
            await harness.appState.branchFromAssistantMessage("assistant")
        }
        await branchGate.waitUntilSuspended()
        await harness.appState.refreshActiveSession()
        branchGate.resume()
        await branch.value

        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
        XCTAssertEqual(harness.appState.activeSessionId, parent.id)
        XCTAssertEqual(harness.appState.messages, parentMessages)
    }

    func testExplicitCancellationWhileAutomaticSyncWaitsBeforeSelectionPreventsRevival() async {
        let harness = makeHarness(behavior: .latestActivity)
        let gate = ControlledSuspension()
        let catalog = [session("stored-b"), session("stored-a")]
        harness.appState.sessions = catalog
        harness.appState.activeSessionId = "stored-a"
        let automaticWork = harness.appState.beginAutomaticChatResumeWork()

        let selection = Task { @MainActor in
            await gate.suspend()
            return harness.appState.selectChatResumeTarget(
                in: catalog,
                profile: "default",
                purpose: .automaticReturn,
                currentSessionID: "stored-a",
                automaticWorkToken: automaticWork
            )
        }
        await gate.waitUntilSuspended()

        harness.appState.cancelChatResumeRestoration()
        gate.resume()
        let selected = await selection.value

        XCTAssertNil(selected)
        XCTAssertEqual(harness.appState.activeSessionId, "stored-a")
        XCTAssertNil(harness.appState.chatResumeRestorationRequest)
    }

    func testExplicitCancellationDuringAutomaticReconciliationPreventsTranscriptReplacementAndPublication() async {
        let harness = makeHarness(behavior: .latestActivity)
        let gate = ControlledSuspension()
        let catalog = [session("stored-b"), session("stored-a")]
        let originalMessages = [
            ChatMessage(id: "a-message", role: .assistant, content: "Session A", timestamp: "now")
        ]
        harness.appState.sessions = catalog
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = originalMessages
        let automaticWork = harness.appState.beginAutomaticChatResumeWork()
        let reconciliation = harness.appState.beginReconciliation()
        XCTAssertEqual(
            harness.appState.selectChatResumeTarget(
                in: catalog,
                profile: "default",
                purpose: .automaticReturn,
                currentSessionID: "stored-a",
                automaticWorkToken: automaticWork
            )?.id,
            "stored-b"
        )
        let replacement = SessionResumeResult(
            sessionId: "stored-b",
            messages: [
                ChatMessage(id: "b-message", role: .assistant, content: "Session B", timestamp: "later")
            ],
            snapshot: SessionRuntimeSnapshot(object: [:])
        )

        let result = Task { @MainActor in
            await gate.suspend()
            let replaced = harness.appState.applyChatResume(
                replacement,
                automaticWorkToken: automaticWork
            )
            let published = harness.appState.settleReconciliationAndPublish(
                reconciliation,
                automaticWorkToken: automaticWork
            )
            return (replaced, published)
        }
        await gate.waitUntilSuspended()

        harness.appState.cancelChatResumeRestoration()
        gate.resume()
        let outcome = await result.value

        XCTAssertFalse(outcome.0)
        XCTAssertFalse(outcome.1)
        XCTAssertEqual(harness.appState.activeSessionId, "stored-a")
        XCTAssertEqual(harness.appState.messages, originalMessages)
        XCTAssertNil(harness.appState.chatResumeRestorationRequest)
    }

    func testPreTransitionCapturePreservesOldAnchorAgainstLateTeardownGeometry() {
        let harness = makeHarness()
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        let keyA = ChatScrollSessionKey(profile: "default", sessionID: sessionA.id)
        let exactAnchor = ChatScrollSnapshot(
            anchorMessageID: "chat-message-exact-anchor-0",
            followsLatest: false,
            anchorMetadata: ChatScrollAnchorMetadata(fingerprint: "exact-anchor", duplicateCount: 1),
            anchorSourceMessageID: "source-a"
        )
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(sessionKey: keyA, snapshot: exactAnchor)
        }

        harness.appState.beginExplicitChatViewportTransition()
        harness.appState.activeSessionId = sessionB.id
        harness.appState.messages = []
        harness.appState.recordChatViewport(.latest, for: keyA)
        harness.appState.flushChatResumeViewport()

        XCTAssertEqual(harness.store.snapshot(for: keyA), exactAnchor)
    }

    func testPreTransitionCaptureUsesRenderedKeyDuringModelOverlap() {
        let harness = makeHarness()
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        let keyA = ChatScrollSessionKey(profile: "default", sessionID: sessionA.id)
        let keyB = ChatScrollSessionKey(profile: "default", sessionID: sessionB.id)
        let renderedSnapshot = ChatScrollSnapshot(
            anchorMessageID: "rendered-a-anchor",
            followsLatest: false
        )
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(sessionKey: keyA, snapshot: renderedSnapshot)
        }

        harness.appState.activeSessionId = sessionB.id
        harness.appState.beginExplicitChatViewportTransition()
        harness.appState.flushChatResumeViewport()

        XCTAssertEqual(harness.store.snapshot(for: keyA), renderedSnapshot)
        XCTAssertNil(harness.store.snapshot(for: keyB))
    }

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

    func testSecondAutomaticReturnImmediatelySupersedesPublishedGeneration() throws {
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
        let firstRequest = try XCTUnwrap(harness.appState.chatResumeRestorationRequest)

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
            try XCTUnwrap(harness.appState.chatResumeRestorationRequest).generation,
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

    func testSuccessfulSettlementCancelsQueuedReconnectExecution() async {
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in
                reconnectSpy.purposes.append(purpose)
            }
        )
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.scheduleReconnect(purpose: .automaticReturn)
        let token = harness.appState.beginReconciliation()

        XCTAssertTrue(harness.appState.settleReconciliationAndPublish(token))
        await scheduler.runAll()

        XCTAssertEqual(scheduler.cancelledCount, 1)
        XCTAssertTrue(reconnectSpy.purposes.isEmpty)
    }

    func testViewportCancellationPreservesQueuedReconnectAsPreserveCurrent() async {
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in
                reconnectSpy.purposes.append(purpose)
            }
        )
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.scheduleReconnect(purpose: .automaticReturn)

        harness.appState.cancelChatResumeRestoration()
        await scheduler.runAll()

        XCTAssertEqual(scheduler.cancelledCount, 0)
        XCTAssertEqual(reconnectSpy.purposes, [.preserveCurrent])
    }

    func testPublicReconnectOverridesPendingAutomaticIntent() async {
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            behavior: .latestActivity,
            reconnectExecutor: { purpose in
                reconnectSpy.purposes.append(purpose)
            }
        )
        _ = harness.appState.beginChatResumeRecovery(purpose: .automaticReturn)

        await harness.appState.reconnect()

        XCTAssertEqual(reconnectSpy.purposes, [.preserveCurrent])
    }

    func testBackgroundedSceneDropsScheduledReconnectExecution() async {
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in
                reconnectSpy.purposes.append(purpose)
            }
        )
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )

        // A socket drop while the scene is backgrounded must not run the
        // reconnect cycle: the churn it causes can starve the scene-update
        // watchdog (0x8BADF00D). No timer is armed at all, and
        // handleScenePhase(.active) re-establishes the transport on return.
        harness.appState.handleScenePhase(.background)
        harness.appState.scheduleReconnect(purpose: .automaticReturn)
        await scheduler.runAll()

        XCTAssertTrue(reconnectSpy.purposes.isEmpty)
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    func testCanceledReconnectTimerDoesNotAdvanceBackoff() async {
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in
                reconnectSpy.purposes.append(purpose)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in throw DashboardTicketBridgeError.notReady }
            )
        )
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )

        // Socket drops while active: a timer is armed at the first backoff
        // step (2^0 = 1s).
        harness.appState.scheduleReconnect()
        XCTAssertEqual(scheduler.delays, [1.0])

        // The user backgrounds before the timer fires; the armed timer is
        // canceled by the scene transition rather than executed.
        harness.appState.handleScenePhase(.background)

        // Reconnecting later must still start from the first backoff step:
        // a canceled cycle was not a gateway failure.
        harness.appState.handleScenePhase(.active)
        harness.appState.scheduleReconnect()
        XCTAssertEqual(scheduler.delays, [1.0, 1.0])
    }

    func testBackgroundingMidMintAbortsInFlightReconnect() async {
        let mintGate = ControlledSuspension()
        let connectCount = ConnectCount()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in
                    connectCount.value += 1
                },
                mintTicket: { _ in
                    await mintGate.suspend()
                    return "fresh-ticket"
                }
            )
        )
        let savedConnection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "saved-ticket"
        )
        let originalClient = HermesClient(connection: savedConnection, profile: "default")
        harness.appState.connection = savedConnection
        harness.appState.client = originalClient

        // The reconnect cycle is already past its starting gate and suspended
        // while minting a fresh ticket when the scene goes to the background.
        let reconnectTask = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .preserveCurrent)
        }
        await mintGate.waitUntilSuspended()
        harness.appState.handleScenePhase(.background)
        mintGate.resume()
        await reconnectTask.value

        // The cycle must abort at its post-mint continuation checkpoint
        // instead of connecting and publishing state while backgrounded.
        XCTAssertEqual(connectCount.value, 0)
        XCTAssertTrue(harness.appState.client === originalClient)
    }

    func testSceneActivationRestoresReconnectExecution() async {
        let scheduler = ControlledReconnectScheduler()
        let reconnectSpy = ReconnectExecutionSpy()
        let connectCount = ConnectCount()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in
                reconnectSpy.purposes.append(purpose)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in
                    // Isolation tripwire: if the scene task's recovery
                    // attempt ever reaches a connection path (e.g. a future
                    // harness change makes minting succeed), the
                    // connectCount assertion below fails rather than letting
                    // the test touch a live connection.
                    connectCount.value += 1
                },
                mintTicket: { _ in throw DashboardTicketBridgeError.notReady }
            )
        )
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )

        harness.appState.handleScenePhase(.background)
        harness.appState.scheduleReconnect(purpose: .automaticReturn)
        await scheduler.runAll()
        XCTAssertTrue(reconnectSpy.purposes.isEmpty)

        // Returning to the foreground re-enables reconnect execution; the
        // scene task's own recovery attempt stays on the controlled
        // scheduler and must not reach the executor unscheduled.
        harness.appState.handleScenePhase(.active)
        await harness.appState.reconnect()

        XCTAssertEqual(reconnectSpy.purposes, [.preserveCurrent])
        XCTAssertEqual(connectCount.value, 0)
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

    func testMissingSavedSessionDirectSyncRestoresSavedViewport() async throws {
        var requests: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [] },
            openSession: { _, sessionID, _ in
                requests.append(sessionID)
                return SessionResumeResult(
                    sessionId: sessionID,
                    storedSessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-missing")
        let saved = ChatScrollSnapshot(anchorMessageID: "saved-anchor", followsLatest: false)
        harness.coordinator.rememberSessionID("stored-missing", for: "default")
        harness.coordinator.recordViewport(saved, for: key)
        harness.coordinator.flush()
        installComposerClient(in: harness)

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(requests, ["stored-missing"])
        XCTAssertEqual(
            try XCTUnwrap(harness.appState.chatResumeRestorationRequest).destination,
            .snapshot(saved)
        )
        XCTAssertEqual(harness.store.snapshot(for: key), saved)
    }

    func testLegacySameServerLoginOrderingPreservesServerScopedState() throws {
        let reviewData = try JSONEncoder().encode([serverScopedReviewSentinel()])
        let knownProfiles = ["default", "sentinel-profile"]
        let harness = makeHarness(
            behavior: .latestActivity,
            configureDefaults: { defaults in
                defaults.set("HTTPS://One.Example:443/", forKey: "conduit.dashboardURL")
                defaults.set(reviewData, forKey: "conduit.reviewSummaryCache.v1")
                defaults.set(knownProfiles, forKey: "conduit.knownProfiles.v1")
            }
        )
        let key = ChatScrollSessionKey(profile: "default", sessionID: "sentinel-session")
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: "sentinel-anchor",
            followsLatest: false
        )
        harness.coordinator.rememberSessionID("sentinel-session", for: "default")
        harness.coordinator.recordViewport(snapshot, for: key)
        harness.coordinator.flush()

        harness.appState.rememberDashboardURL("https://one.example")

        XCTAssertFalse(harness.appState.prepareChatResumeForConnection(to: "https://one.example"))
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "sentinel-session")
        XCTAssertEqual(harness.store.snapshot(for: key), snapshot)
        XCTAssertEqual(harness.defaults.data(forKey: "conduit.reviewSummaryCache.v1"), reviewData)
        XCTAssertEqual(harness.defaults.stringArray(forKey: "conduit.knownProfiles.v1"), knownProfiles)
        XCTAssertEqual(harness.cacheClearSpy.count, 0)
        XCTAssertEqual(harness.appState.chatResumeBehavior, .latestActivity)
    }

    func testFirstConnectionWithoutPersistedIdentityPreservesServerScopedState() throws {
        let reviewData = try JSONEncoder().encode([serverScopedReviewSentinel()])
        let knownProfiles = ["default", "sentinel-profile"]
        let harness = makeHarness(
            behavior: .latestActivity,
            configureDefaults: { defaults in
                defaults.set(reviewData, forKey: "conduit.reviewSummaryCache.v1")
                defaults.set(knownProfiles, forKey: "conduit.knownProfiles.v1")
            }
        )
        let key = ChatScrollSessionKey(profile: "default", sessionID: "sentinel-session")
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: "sentinel-anchor",
            followsLatest: false
        )
        XCTAssertNil(harness.defaults.string(forKey: "conduit.chatResumeServerIdentity.v1"))
        XCTAssertNil(harness.defaults.string(forKey: "conduit.dashboardURL"))
        harness.coordinator.rememberSessionID("sentinel-session", for: "default")
        harness.coordinator.recordViewport(snapshot, for: key)
        harness.coordinator.flush()

        harness.appState.rememberDashboardURL("https://first.example")

        XCTAssertFalse(harness.appState.prepareChatResumeForConnection(to: "https://first.example"))
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "sentinel-session")
        XCTAssertEqual(harness.store.snapshot(for: key), snapshot)
        XCTAssertEqual(harness.defaults.data(forKey: "conduit.reviewSummaryCache.v1"), reviewData)
        XCTAssertEqual(harness.defaults.stringArray(forKey: "conduit.knownProfiles.v1"), knownProfiles)
        XCTAssertEqual(harness.cacheClearSpy.count, 0)
        XCTAssertEqual(harness.appState.chatResumeBehavior, .latestActivity)
    }

    func testLegacyDashboardIdentityCapturedBeforeLoginOverwritesURL() {
        let harness = makeHarness(
            behavior: .latestActivity,
            configureDefaults: { defaults in
                defaults.set("https://one.example", forKey: "conduit.dashboardURL")
            }
        )
        let key = ChatScrollSessionKey(profile: "default", sessionID: "same-session")
        harness.coordinator.rememberSessionID("same-session", for: "default")
        harness.coordinator.recordViewport(.latest, for: key)
        harness.coordinator.flush()
        harness.appState.rememberDashboardURL("https://two.example")

        XCTAssertTrue(harness.appState.prepareChatResumeForConnection(to: "https://two.example"))
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
        XCTAssertNil(harness.store.snapshot(for: key))
        XCTAssertEqual(harness.appState.chatResumeBehavior, .latestActivity)
    }

    func testServerChangeClearsReviewAndKnownProfileCachesButPreservesBehavior() throws {
        let review = ReviewSummaryRecord(
            id: "old-review",
            profile: "default",
            sessionId: "same-session",
            timestamp: "2026-08-09T12:00:00Z",
            activity: ReviewActivity(
                summary: "Old server review",
                details: ["Old server detail"],
                fullSessionId: "same-child"
            )
        )
        let harness = makeHarness(
            behavior: .latestActivity,
            configureDefaults: { defaults in
                defaults.set("https://one.example", forKey: "conduit.chatResumeServerIdentity.v1")
                defaults.set(
                    (try? JSONEncoder().encode([review])) ?? Data(),
                    forKey: "conduit.reviewSummaryCache.v1"
                )
                defaults.set(
                    ["default", "old-profile"],
                    forKey: "conduit.knownProfiles.v1"
                )
            }
        )
        harness.appState.rememberDashboardURL("https://two.example")

        XCTAssertTrue(harness.appState.prepareChatResumeForConnection(to: "https://two.example"))
        XCTAssertNil(harness.defaults.data(forKey: "conduit.reviewSummaryCache.v1"))
        XCTAssertNil(harness.defaults.stringArray(forKey: "conduit.knownProfiles.v1"))
        XCTAssertEqual(harness.appState.chatResumeBehavior, .latestActivity)
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

    func testCanonicalIdentityRefreshMigratesRuntimePersistenceBeforeColdRestore() {
        let harness = makeHarness()
        let runtimeKey = ChatScrollSessionKey(profile: "default", sessionID: "runtime-a")
        let canonicalKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: "runtime-anchor",
            followsLatest: false,
            anchorMetadata: .init(fingerprint: "runtime-fingerprint", duplicateCount: 2),
            anchorSourceMessageID: "runtime-source"
        )
        harness.store.setLastSessionID(runtimeKey.sessionID, for: runtimeKey.profile)
        harness.store.save(snapshot, for: runtimeKey, at: Date(timeIntervalSince1970: 100))
        harness.store.flush()

        let migrationStore = ChatResumeStore(defaults: harness.defaults)
        let migrationState = AppState(
            defaults: harness.defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: migrationStore),
            loadSavedConnection: false,
            clearSessionPresentationCache: {}
        )
        XCTAssertEqual(migrationState.activeSessionId, runtimeKey.sessionID)

        let canonicalSession = session(
            canonicalKey.sessionID,
            alternateIDs: [runtimeKey.sessionID]
        )
        migrationState.sessions = [canonicalSession]

        let restoredStore = ChatResumeStore(defaults: harness.defaults)
        let restoredCoordinator = ChatResumeCoordinator(store: restoredStore)
        let restoredState = AppState(
            defaults: harness.defaults,
            chatResumeCoordinator: restoredCoordinator,
            loadSavedConnection: false,
            clearSessionPresentationCache: {}
        )
        XCTAssertEqual(restoredState.activeSessionId, canonicalKey.sessionID)
        XCTAssertNil(restoredStore.snapshot(for: runtimeKey))
        XCTAssertEqual(restoredStore.snapshot(for: canonicalKey), snapshot)

        restoredState.sessions = [canonicalSession]
        let token = restoredState.beginReconciliation()
        let selected = restoredState.selectChatResumeTarget(
            in: [canonicalSession],
            profile: canonicalKey.profile,
            purpose: .automaticReturn,
            currentSessionID: restoredState.activeSessionId
        )
        XCTAssertEqual(selected?.id, canonicalKey.sessionID)
        XCTAssertTrue(restoredState.settleReconciliationAndPublish(token))
        XCTAssertEqual(restoredState.chatResumeRestorationRequest?.sessionKey, canonicalKey)
        XCTAssertEqual(restoredState.chatResumeRestorationRequest?.destination, .snapshot(snapshot))
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

    func testAcceptedSendInvalidatesRestorationBeforePromptRPCResumes() async {
        let rpcGate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    await rpcGate.suspend()
                    return .accepted
                }
            )
        )
        let request = publishRestoration(in: harness)
        installComposerClient(in: harness)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Hello")
        }
        await rpcGate.waitUntilSuspended()

        assertRestorationCancelled(request, in: harness)
        rpcGate.resume()
        let submitted = await submission.value
        XCTAssertTrue(submitted)
    }

    func testStaleComposerSubmissionFailureDoesNotRecoverOrMutateNewSession() async {
        let rpcGate = ControlledSuspension()
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        var loadCatalogCount = 0
        var openSessionCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    loadCatalogCount += 1
                    return [destination]
                },
                openSession: { _, sessionID, _ in
                    openSessionCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    await rpcGate.suspend()
                    throw ControlledLifecycleError.failed
                }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = origin.id
        let originContext = harness.appState.composerSubmissionContext()

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(
                text: "origin message",
                context: originContext
            )
        }
        await rpcGate.waitUntilSuspended()

        harness.appState.activeSessionId = destination.id
        harness.appState.errorMessage = "destination state"

        rpcGate.resume()
        let submitted = await submission.value

        XCTAssertFalse(submitted)
        XCTAssertEqual(harness.appState.errorMessage, "destination state")
        XCTAssertEqual(loadCatalogCount, 0)
        XCTAssertEqual(openSessionCount, 0)
    }

    func testStaleComposerSteerFailureDoesNotRecoverOrMutateNewSession() async {
        let rpcGate = ControlledSuspension()
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        var loadCatalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    loadCatalogCount += 1
                    return [destination]
                },
                refreshContext: { _, _ in },
                steer: { _, _, _ in
                    await rpcGate.suspend()
                    throw ControlledLifecycleError.failed
                }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = origin.id
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: origin.id, busy: true))
        let originContext = harness.appState.composerSubmissionContext()

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(
                text: "origin steer",
                context: originContext
            )
        }
        await rpcGate.waitUntilSuspended()

        harness.appState.activeSessionId = destination.id
        harness.appState.errorMessage = "destination state"

        rpcGate.resume()
        let submitted = await submission.value

        XCTAssertFalse(submitted)
        XCTAssertEqual(harness.appState.errorMessage, "destination state")
        XCTAssertEqual(loadCatalogCount, 0)
    }

    func testStaleSlashOutputDoesNotAppendToNewSession() async {
        let rpcGate = ControlledSuspension()
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                executeSlash: { _, _, _ in
                    await rpcGate.suspend()
                    return .object([
                        "type": .string("exec"),
                        "output": .string("origin output")
                    ])
                }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = origin.id
        let originContext = harness.appState.composerSubmissionContext()

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(
                text: "/status",
                context: originContext
            )
        }
        await rpcGate.waitUntilSuspended()

        harness.appState.activeSessionId = destination.id
        harness.appState.messages = []

        rpcGate.resume()
        let submitted = await submission.value

        XCTAssertTrue(submitted)
        XCTAssertTrue(harness.appState.messages.isEmpty)
    }

    func testAcceptedComposerSendRemainsSuccessfulAfterSessionHandoff() async {
        let rpcGate = ControlledSuspension()
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    await rpcGate.suspend()
                    return .accepted
                }
            )
        )
        installComposerClient(in: harness)
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = origin.id
        let originContext = harness.appState.composerSubmissionContext()

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(
                text: "accepted origin message",
                context: originContext
            )
        }
        await rpcGate.waitUntilSuspended()

        harness.appState.activeSessionId = destination.id
        harness.appState.messages = []
        harness.appState.errorMessage = "destination state"

        rpcGate.resume()
        let submitted = await submission.value

        XCTAssertTrue(submitted)
        XCTAssertEqual(harness.appState.errorMessage, "destination state")
        XCTAssertTrue(harness.appState.messages.isEmpty)
    }

    func testRedirectRecoveryRefreshesContextAfterRuntimeSessionRotation() async {
        let origin = session("stored-origin", alternateIDs: ["runtime-origin"])
        var redirectCalls = 0
        var openedSessionIDs: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [origin] },
                openSession: { _, sessionID, _ in
                    openedSessionIDs.append(sessionID)
                    return SessionResumeResult(
                        sessionId: "runtime-recovered",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                refreshContext: { _, _ in },
                redirect: { _, sessionID, _ in
                    redirectCalls += 1
                    if redirectCalls == 1 {
                        throw RpcError(code: 404, message: "session not found")
                    }
                    XCTAssertEqual(sessionID, "runtime-recovered")
                    return .redirected
                },
                setBusyInputMode: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        let changedMode = await harness.appState.setBusyInputMode(.interrupt)
        XCTAssertTrue(changedMode)
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = "runtime-origin"
        harness.appState.handleStreamEvent(
            .sessionBusy(sessionId: "runtime-origin", busy: true)
        )
        XCTAssertEqual(harness.appState.turnState, .running)

        let submitted = await harness.appState.submitComposer(text: "Retry this")

        XCTAssertTrue(submitted)
        XCTAssertEqual(redirectCalls, 2)
        XCTAssertEqual(openedSessionIDs, ["stored-origin"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-recovered")
    }

    func testRedirectResumesAfterRuntimeRotationCompletesWhileRPCIsSuspended() async {
        let redirectGate = ControlledSuspension()
        let contextGate = ControlledSuspension()
        let origin = session("stored-origin", alternateIDs: ["runtime-origin"])
        var redirectCalls = 0
        var contextRefreshes = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [origin] },
                openSession: { _, _, _ in
                    SessionResumeResult(
                        sessionId: "runtime-recovered",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                refreshContext: { _, _ in
                    contextRefreshes += 1
                    if contextRefreshes == 1 {
                        await contextGate.suspend()
                    }
                },
                redirect: { _, sessionID, _ in
                    redirectCalls += 1
                    if redirectCalls == 1 {
                        await redirectGate.suspend()
                        throw RpcError(code: 404, message: "session not found")
                    }
                    XCTAssertEqual(sessionID, "runtime-recovered")
                    return .redirected
                },
                setBusyInputMode: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        let changedMode = await harness.appState.setBusyInputMode(.interrupt)
        XCTAssertTrue(changedMode)
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = "runtime-origin"
        harness.appState.handleStreamEvent(
            .sessionBusy(sessionId: "runtime-origin", busy: true)
        )

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Retry this")
        }
        await redirectGate.waitUntilSuspended()

        let synchronization = Task { @MainActor in
            await harness.appState.syncSession()
        }
        await contextGate.waitUntilSuspended()
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-recovered")
        contextGate.resume()
        await synchronization.value

        redirectGate.resume()
        let submitted = await submission.value
        XCTAssertTrue(submitted)
        XCTAssertEqual(redirectCalls, 2)
    }

    func testAcceptedSteerInvalidatesRestorationBeforeSteerRPCResumes() async {
        let rpcGate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                steer: { _, _, _ in await rpcGate.suspend() }
            )
        )
        let active = session("stored-a")
        let request = publishRestoration(in: harness, session: active)
        installComposerClient(in: harness)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Adjust course")
        }
        await rpcGate.waitUntilSuspended()

        assertRestorationCancelled(request, in: harness)
        rpcGate.resume()
        let submitted = await submission.value
        XCTAssertTrue(submitted)
    }

    func testAcceptedRedirectOutcomesInvalidateRestorationBeforeRedirectRPCResumes() async {
        for outcome in [SessionRedirectOutcome.redirected, .queued] {
            let rpcGate = ControlledSuspension()
            let harness = makeHarness(
                lifecycleOperations: ChatResumeLifecycleOperations(
                    redirect: { _, _, _ in
                        await rpcGate.suspend()
                        return outcome
                    },
                    setBusyInputMode: { _, _ in }
                )
            )
            let active = session("stored-a")
            installComposerClient(in: harness)
            let changedMode = await harness.appState.setBusyInputMode(.interrupt)
            XCTAssertTrue(changedMode)
            let request = publishRestoration(in: harness, session: active)
            harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

            let submission = Task { @MainActor in
                await harness.appState.submitComposer(text: "Replace this")
            }
            await rpcGate.waitUntilSuspended()

            assertRestorationCancelled(request, in: harness)
            rpcGate.resume()
            let submitted = await submission.value
            XCTAssertTrue(submitted)
        }
    }

    func testAcceptedSlashCommandInvalidatesRestorationBeforeSlashRPCResumes() async {
        let rpcGate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                executeSlash: { _, _, _ in
                    await rpcGate.suspend()
                    return .object(["type": .string("exec")])
                }
            )
        )
        let request = publishRestoration(in: harness)
        installComposerClient(in: harness)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "/status")
        }
        await rpcGate.waitUntilSuspended()

        assertRestorationCancelled(request, in: harness)
        rpcGate.resume()
        let submitted = await submission.value
        XCTAssertTrue(submitted)
    }

    func testLegacyInterruptAndSendKeepsRestorationInvalidAcrossBothRPCs() async {
        let interruptGate = ControlledSuspension()
        let sendGate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    await sendGate.suspend()
                    return .accepted
                },
                redirect: { _, _, _ in
                    throw RpcError(
                        code: 4010,
                        message: "Gateway does not support active-turn redirect"
                    )
                },
                interrupt: { _, _ in await interruptGate.suspend() },
                setBusyInputMode: { _, _ in }
            )
        )
        let active = session("stored-a")
        installComposerClient(in: harness)
        let changedMode = await harness.appState.setBusyInputMode(.interrupt)
        XCTAssertTrue(changedMode)
        let request = publishRestoration(in: harness, session: active)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Use the legacy path")
        }
        await interruptGate.waitUntilSuspended()
        assertRestorationCancelled(request, in: harness)

        interruptGate.resume()
        await sendGate.waitUntilSuspended()
        assertRestorationCancelled(request, in: harness)

        sendGate.resume()
        let submitted = await submission.value
        XCTAssertTrue(submitted)
    }

    func testLegacyInterruptAndSendRefreshesRuntimeAliasDuringInterrupt() async {
        let interruptGate = ControlledSuspension()
        let contextGate = ControlledSuspension()
        let origin = session("stored-origin", alternateIDs: ["runtime-origin"])
        var interruptSessionIDs: [String] = []
        var sendSessionIDs: [String] = []
        var contextRefreshes = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [origin] },
                openSession: { _, _, _ in
                    SessionResumeResult(
                        sessionId: "runtime-recovered",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                refreshContext: { _, _ in
                    contextRefreshes += 1
                    if contextRefreshes == 1 {
                        await contextGate.suspend()
                    }
                },
                sendPrompt: { _, sessionID, _ in
                    sendSessionIDs.append(sessionID)
                    return .accepted
                },
                redirect: { _, _, _ in
                    throw RpcError(
                        code: 4010,
                        message: "Gateway does not support active-turn redirect"
                    )
                },
                interrupt: { _, sessionID in
                    interruptSessionIDs.append(sessionID)
                    await interruptGate.suspend()
                },
                setBusyInputMode: { _, _ in }
            )
        )
        installComposerClient(in: harness)
        let changedMode = await harness.appState.setBusyInputMode(.interrupt)
        XCTAssertTrue(changedMode)
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = "runtime-origin"
        harness.appState.handleStreamEvent(
            .sessionBusy(sessionId: "runtime-origin", busy: true)
        )

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Use legacy retry")
        }
        await interruptGate.waitUntilSuspended()

        let synchronization = Task { @MainActor in
            await harness.appState.syncSession()
        }
        await contextGate.waitUntilSuspended()
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-recovered")
        contextGate.resume()
        await synchronization.value

        interruptGate.resume()
        let submitted = await submission.value
        XCTAssertTrue(submitted)
        XCTAssertEqual(interruptSessionIDs, ["runtime-origin"])
        XCTAssertEqual(sendSessionIDs, ["runtime-recovered"])
    }

    func testRejectedBusyAttachmentPreservesPendingRestoration() async {
        let harness = makeHarness()
        let active = session("stored-a")
        let request = publishRestoration(in: harness, session: active)
        installComposerClient(in: harness)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        let attachment = Attachment(
            id: "notes",
            name: "notes.txt",
            uri: "file:///tmp/notes.txt",
            mimeType: "text/plain",
            kind: .document
        )

        let submitted = await harness.appState.submitComposer(
            text: "Not accepted yet",
            attachments: [attachment]
        )

        XCTAssertFalse(submitted)
        XCTAssertEqual(harness.appState.chatResumeRestorationRequest, request)
        XCTAssertTrue(harness.coordinator.isCurrent(generation: request.generation))
    }

    private func assertProfileSwitchCancelsStaleReconnectMint(
        outcome: StaleReconnectMintOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let staleMintGate = ControlledSuspension()
        let scheduler = ControlledReconnectScheduler()
        let defaultSession = session("default-session")
        let workSession = session("work-session", profile: "work")
        let defaultKey = ChatScrollSessionKey(
            profile: "default",
            sessionID: defaultSession.id
        )
        let workKey = ChatScrollSessionKey(profile: "work", sessionID: workSession.id)
        let capturedDefaultViewport = ChatScrollSnapshot(
            anchorMessageID: "default-anchor",
            followsLatest: false
        )
        let workMessages = [
            ChatMessage(id: "work-message", role: .assistant, content: "Work", timestamp: "2")
        ]
        var mintCount = 0
        var connectedProfiles: [String] = []
        var catalogProfiles: [String] = []
        var openedProfiles: [String] = []
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { client in
                    connectedProfiles.append(client.profile ?? "default")
                },
                loadCatalog: { client, _ in
                    let profile = client.profile ?? "default"
                    catalogProfiles.append(profile)
                    return profile == "work" ? [workSession] : [defaultSession]
                },
                mintTicket: { _ in
                    mintCount += 1
                    if mintCount == 1 {
                        await staleMintGate.suspend()
                        switch outcome {
                        case .success:
                            return "stale-ticket"
                        case .signInRequired:
                            throw DashboardTicketBridgeError.signInRequired
                        }
                    }
                    return "profile-ticket"
                },
                openSession: { client, sessionID, _ in
                    let profile = client.profile ?? "default"
                    openedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: profile == "work" ? workMessages : [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        let savedConnection = HermesConnection(
            baseUrl: "https://127.0.0.1:1",
            ticket: "saved-ticket"
        )
        let originalClient = HermesClient(connection: savedConnection, profile: "default")
        harness.coordinator.rememberSessionID(defaultSession.id, for: "default")
        harness.coordinator.rememberSessionID(workSession.id, for: "work")
        harness.appState.connection = savedConnection
        harness.appState.client = originalClient
        harness.appState.isConnected = true
        harness.appState.showLogin = false
        harness.appState.errorMessage = nil
        harness.appState.sessions = [defaultSession]
        harness.appState.activeSessionId = defaultSession.id
        harness.appState.messages = [
            ChatMessage(
                id: "default-message",
                role: .assistant,
                content: "Default",
                timestamp: "1"
            )
        ]
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(
                sessionKey: defaultKey,
                snapshot: capturedDefaultViewport
            )
        }

        let staleReconnect = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await staleMintGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.isConnecting, file: file, line: line)
        XCTAssertEqual(harness.appState.turnState, .reconnecting, file: file, line: line)

        await harness.appState.switchProfile(to: "work")

        let transitionGeneration = harness.appState.chatViewportTransitionGeneration
        let switchedConnection = harness.appState.connection
        let switchedClient = harness.appState.client
        XCTAssertEqual(harness.appState.activeProfile, "work", file: file, line: line)
        XCTAssertEqual(switchedConnection?.ticket, "profile-ticket", file: file, line: line)
        XCTAssertEqual(switchedClient?.profile, "work", file: file, line: line)
        XCTAssertEqual(harness.appState.activeSessionId, workSession.id, file: file, line: line)
        XCTAssertEqual(harness.appState.messages, workMessages, file: file, line: line)
        XCTAssertTrue(harness.appState.isConnected, file: file, line: line)
        XCTAssertFalse(harness.appState.isConnecting, file: file, line: line)
        XCTAssertEqual(harness.appState.turnState, .idle, file: file, line: line)
        XCTAssertTrue(harness.appState.composerIsEnabled, file: file, line: line)
        XCTAssertFalse(harness.appState.showLogin, file: file, line: line)
        XCTAssertNil(harness.appState.errorMessage, file: file, line: line)
        XCTAssertEqual(harness.store.snapshot(for: defaultKey), capturedDefaultViewport, file: file, line: line)

        harness.appState.recordChatViewport(.latest, for: workKey)
        harness.appState.flushChatResumeViewport()
        XCTAssertNil(harness.store.snapshot(for: workKey), file: file, line: line)

        staleMintGate.resume()
        await staleReconnect.value

        XCTAssertEqual(mintCount, 2, file: file, line: line)
        XCTAssertEqual(connectedProfiles, ["work"], file: file, line: line)
        XCTAssertEqual(catalogProfiles, ["work"], file: file, line: line)
        XCTAssertEqual(openedProfiles, ["work"], file: file, line: line)
        XCTAssertEqual(harness.appState.activeProfile, "work", file: file, line: line)
        XCTAssertEqual(harness.appState.connection, switchedConnection, file: file, line: line)
        XCTAssertTrue(harness.appState.client === switchedClient, file: file, line: line)
        XCTAssertEqual(harness.appState.activeSessionId, workSession.id, file: file, line: line)
        XCTAssertEqual(harness.appState.messages, workMessages, file: file, line: line)
        XCTAssertTrue(harness.appState.isConnected, file: file, line: line)
        XCTAssertFalse(harness.appState.isConnecting, file: file, line: line)
        XCTAssertEqual(harness.appState.turnState, .idle, file: file, line: line)
        XCTAssertTrue(harness.appState.composerIsEnabled, file: file, line: line)
        XCTAssertFalse(harness.appState.showLogin, file: file, line: line)
        XCTAssertNil(harness.appState.errorMessage, file: file, line: line)
        XCTAssertNil(harness.appState.chatResumeRestorationRequest, file: file, line: line)
        XCTAssertEqual(harness.appState.chatViewportTransitionGeneration, transitionGeneration, file: file, line: line)
        XCTAssertEqual(harness.store.snapshot(for: defaultKey), capturedDefaultViewport, file: file, line: line)
        XCTAssertNil(harness.store.snapshot(for: workKey), file: file, line: line)
        XCTAssertEqual(scheduler.scheduledCount, 0, file: file, line: line)

        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: workKey,
            transitionGeneration: transitionGeneration,
            transcriptRevision: harness.appState.chatTranscriptRevision,
            renderRevision: 1,
            receivedScopedPreference: true
        )
        harness.appState.recordChatViewport(.latest, for: workKey)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: workKey), .latest, file: file, line: line)
    }

    /// Integration coverage for the production merge call shape: the
    /// reconciliation path merges the resume result through
    /// [resolvedId, requestedId]. Both aliases resolving to one logical
    /// cached snapshot must enrich each gateway row exactly once with the
    /// freshest metadata - never stale duplicated candidates.
    func testReconciliationMergeDeduplicatesRequestedAndResolvedAliases() async {
        let cacheSuite = "conduit.tests.alias-dedup-reconciliation-" + UUID().uuidString
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let clock = DeterministicClock()
        let cache = SessionPresentationCache(defaults: cacheDefaults, now: { clock.currentValue() })
        defer {
            cache.clear()
            cacheDefaults.removePersistentDomain(forName: cacheSuite)
        }
        let harness = makeHarness(sessionPresentationCache: cache)

        // An older generation saved long ago under the REQUESTED id...
        let staleGeneration = (1...5).map { index in
            ChatMessage(
                id: "gen-row-" + String(index),
                role: .assistant,
                content: "Reconciled digest " + String(index),
                timestamp: "stale-" + String(index)
            )
        }
        cache.save(staleGeneration, profile: "default", sessionIDs: ["stored-a"])
        clock.advance()
        // ...and the live writes kept the RESOLVED id current.
        let freshGeneration = (1...5).map { index in
            ChatMessage(
                id: "gen-row-" + String(index),
                role: .assistant,
                content: "Reconciled digest " + String(index),
                timestamp: "fresh-" + String(index)
            )
        }
        cache.save(freshGeneration, profile: "default", sessionIDs: ["runtime-a"])

        // Publish a reconciliation whose requested session is stored-a; the
        // gateway then resumes it under the resolved runtime id.
        let active = session("stored-a")
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        _ = publishRestoration(in: harness, session: active)

        let resumeResult = SessionResumeResult(
            sessionId: "runtime-a",
            messages: (1...5).map { index in
                ChatMessage(id: "gw-" + String(index), role: .assistant, content: "Reconciled digest " + String(index), timestamp: "")
            },
            snapshot: SessionRuntimeSnapshot(object: [:])
        )

        XCTAssertTrue(harness.appState.applyChatResume(resumeResult))

        XCTAssertEqual(
            harness.appState.messages.map { $0.timestamp },
            ["fresh-1", "fresh-2", "fresh-3", "fresh-4", "fresh-5"]
        )
    }

    // MARK: - Composer user-edit ownership

    /// The reported race: while an automatic-return reconnect is suspended
    /// mid-flight, the user starts typing into the visible conversation. The
    /// composer edit must strip the reconnect's session-selection authority:
    /// the transport recovery continues, but as `.preserveCurrent`, resuming
    /// the visible session instead of the resume policy's saved (older) one.
    func testComposerUserEditDuringSuspendedReconnectPreservesVisibleSession() async {
        await assertComposerEditStopsAutomaticSessionSelection(
            behavior: .continueWhereLeftOff,
            userEditsDuringReconnect: true
        )
    }

    func testComposerUserEditDuringSuspendedLatestActivityReconnectPreservesVisibleSession() async {
        await assertComposerEditStopsAutomaticSessionSelection(
            behavior: .latestActivity,
            userEditsDuringReconnect: true
        )
    }

    /// Control for the race above: with no composer interaction, the same
    /// foreground fallback must still restore according to the configured
    /// resume behavior — Continue Where I Left Off restores the saved older
    /// session, and Jump to Latest Activity restores the newest catalog row.
    func testSuspendedReconnectWithoutComposerInteractionStillRestoresSavedSession() async {
        await assertComposerEditStopsAutomaticSessionSelection(
            behavior: .continueWhereLeftOff,
            userEditsDuringReconnect: false
        )
    }

    func testSuspendedLatestActivityReconnectWithoutComposerInteractionStillRestoresNewest() async {
        await assertComposerEditStopsAutomaticSessionSelection(
            behavior: .latestActivity,
            userEditsDuringReconnect: false
        )
    }

    /// A queued automatic-return retry must not survive a composer edit: the
    /// armed timer re-reads its purpose when it fires, and the cancellation
    /// demotes the queue to `.preserveCurrent`.
    func testComposerUserEditDemotesArmedAutomaticReturnReconnect() async {
        let scheduler = ControlledReconnectScheduler()
        let spy = ReconnectExecutionSpy()
        let harness = makeHarness(
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in
                spy.purposes.append(purpose)
            }
        )
        installComposerClient(in: harness)

        harness.appState.scheduleReconnect(purpose: .automaticReturn)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        harness.appState.noteComposerUserEdit()
        await scheduler.runAll()

        XCTAssertEqual(
            spy.purposes, [.preserveCurrent],
            "The armed automatic retry must fire as .preserveCurrent after a composer edit"
        )
    }

    /// Per-keystroke calls must be free in steady state: the composer fires
    /// this signal on every genuine edit, and with nothing automatic
    /// outstanding it may not publish any state (the restoration request and
    /// recovery sequence are @Published-adjacent view inputs).
    func testComposerUserEditWithoutOutstandingAutomaticWorkPublishesNothing() async {
        let harness = makeHarness()
        installComposerClient(in: harness)
        let visible = session("stored-a")
        harness.appState.sessions = [visible]
        harness.appState.activeSessionId = visible.id
        var publishedCount = 0
        let observer = harness.appState.objectWillChange.sink { _ in
            publishedCount += 1
        }
        defer { observer.cancel() }

        harness.appState.noteComposerUserEdit()
        harness.appState.noteComposerUserEdit()

        XCTAssertEqual(publishedCount, 0)
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent)
        XCTAssertNil(harness.appState.chatResumeRestorationRequest)
    }

    /// The first edit in an outstanding window cancels once; later edits in
    /// the same automatic-work generation are latched no-ops. Otherwise every
    /// keystroke of the reported scenario (typing while the foreground
    /// health check hangs) would re-write the @Published restoration request
    /// and re-render ChatView. The reconnect here is parked for the whole
    /// window, so the composer edit is the only state changer.
    func testComposerUserEditLatchesUntilNextAutomaticWorkGeneration() async {
        let mintGate = ControlledSuspension()
        let visible = session("stored-a")
        let savedOlder = session("stored-b")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in [savedOlder, visible] },
                mintTicket: { _ in
                    await mintGate.suspend()
                    return "fresh-ticket"
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        harness.coordinator.rememberSessionID(savedOlder.id, for: "default")
        let savedConnection = HermesConnection(
            baseUrl: "https://127.0.0.1:1",
            ticket: "saved-ticket"
        )
        harness.appState.connection = savedConnection
        harness.appState.client = HermesClient(connection: savedConnection, profile: "default")
        harness.appState.sessions = [savedOlder, visible]
        harness.appState.activeSessionId = visible.id

        let reconnect = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await mintGate.waitUntilSuspended()

        var publishedCount = 0
        let observer = harness.appState.objectWillChange.sink { _ in
            publishedCount += 1
        }
        defer { observer.cancel() }

        harness.appState.noteComposerUserEdit()
        harness.appState.noteComposerUserEdit()
        harness.appState.noteComposerUserEdit()

        XCTAssertEqual(
            publishedCount, 1,
            "Exactly one cancellation may land per automatic-work generation"
        )

        mintGate.resume()
        await reconnect.value
    }

    /// The published-restoration-request guard arm: an edit while a
    /// restoration request awaits consumption must cancel it.
    func testComposerUserEditCancelsPublishedRestorationRequest() async {
        let harness = makeHarness()
        installComposerClient(in: harness)
        let request = publishRestoration(in: harness)

        harness.appState.noteComposerUserEdit()

        assertRestorationCancelled(request, in: harness)
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent)
    }

    /// The in-flight sync leg: an edit while an `.automaticReturn` sync is
    /// suspended on its catalog fetch must stop it from selecting a session
    /// — every post-fetch checkpoint is token-guarded, so the sync settles
    /// without resuming anything.
    func testComposerUserEditDuringInFlightAutomaticReturnSyncDoesNotSelectSession() async {
        let catalogGate = ControlledSuspension()
        let visible = session("stored-a")
        let savedOlder = session("stored-b")
        var openedSessionIDs: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    await catalogGate.suspend()
                    return [savedOlder, visible]
                },
                openSession: { _, sessionID, _ in
                    openedSessionIDs.append(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        harness.coordinator.rememberSessionID(savedOlder.id, for: "default")
        installComposerClient(in: harness)
        harness.appState.sessions = [savedOlder, visible]
        harness.appState.activeSessionId = visible.id
        let automaticWork = harness.appState.beginAutomaticChatResumeWork()

        let sync = Task { @MainActor in
            await harness.appState.syncSession(
                purpose: .automaticReturn,
                using: nil,
                automaticWorkToken: automaticWork
            )
        }
        await catalogGate.waitUntilSuspended()

        harness.appState.noteComposerUserEdit()

        catalogGate.resume()
        await sync.value

        XCTAssertEqual(
            harness.appState.activeSessionId, visible.id,
            "The invalidated sync must not select the saved session"
        )
        XCTAssertEqual(openedSessionIDs, [], "No session may be resumed after the edit")
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent)
    }

    private func assertComposerEditStopsAutomaticSessionSelection(
        behavior: ChatResumeBehavior,
        userEditsDuringReconnect: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let mintGate = ControlledSuspension()
        let visible = session("stored-a")
        // The session the resume policy would pick for an automatic return:
        // the saved Continue-Where-I-Left-Off pointer, or the newest catalog
        // chat row for Jump to Latest Activity. Either way it is NOT the
        // session the user is currently editing.
        let automaticReturnTarget = session("stored-b")
        var openedSessionIDs: [String] = []
        let harness = makeHarness(
            behavior: behavior,
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in [automaticReturnTarget, visible] },
                mintTicket: { _ in
                    await mintGate.suspend()
                    return "fresh-ticket"
                },
                openSession: { _, sessionID, _ in
                    openedSessionIDs.append(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        harness.coordinator.rememberSessionID(automaticReturnTarget.id, for: "default")
        let savedConnection = HermesConnection(
            baseUrl: "https://127.0.0.1:1",
            ticket: "saved-ticket"
        )
        harness.appState.connection = savedConnection
        harness.appState.client = HermesClient(connection: savedConnection, profile: "default")
        harness.appState.sessions = [automaticReturnTarget, visible]
        harness.appState.activeSessionId = visible.id

        // The foreground fallback path: transport was judged unhealthy and
        // the automatic-return reconnect is now suspended at its ticket
        // mint — the controllable async boundary.
        let reconnect = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await mintGate.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .reconnecting, file: file, line: line)

        if userEditsDuringReconnect {
            harness.appState.noteComposerUserEdit()
        }

        mintGate.resume()
        await reconnect.value

        let expectedSession = userEditsDuringReconnect ? visible : automaticReturnTarget
        XCTAssertEqual(
            harness.appState.activeSessionId, expectedSession.id,
            file: file, line: line
        )
        XCTAssertEqual(openedSessionIDs, [expectedSession.id], file: file, line: line)
        if userEditsDuringReconnect {
            XCTAssertEqual(
                harness.recoverySequence.currentPurpose, .preserveCurrent,
                "The in-flight reconnect must hand off to .preserveCurrent after a composer edit",
                file: file, line: line
            )
        }
        XCTAssertTrue(harness.appState.isConnected, file: file, line: line)
        XCTAssertFalse(harness.appState.isConnecting, file: file, line: line)
        XCTAssertEqual(harness.appState.turnState, .idle, file: file, line: line)
    }

    private func makeHarness(
        behavior: ChatResumeBehavior = .continueWhereLeftOff,
        configureDefaults: (UserDefaults) -> Void = { _ in },
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        reconnectExecutor: ChatResumeReconnectExecutor? = nil,
        lifecycleOperations: ChatResumeLifecycleOperations = .live,
        sessionPresentationCache: SessionPresentationCache? = nil,
        conversationIdentityIndex: ConversationIdentityIndex? = nil,
        sessionYoloStore: SessionYoloStore? = nil
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
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        configureDefaults(defaults)
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
            clearSessionPresentationCache: { cacheClearSpy.count += 1 },
            reconnectScheduler: reconnectScheduler,
            reconnectExecutor: reconnectExecutor,
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: sessionPresentationCache
                ?? SessionPresentationCache(defaults: defaults),
            sessionYoloStore: sessionYoloStore,
            conversationIdentityIndex: conversationIdentityIndex
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
        guard let request = harness.appState.chatResumeRestorationRequest else {
            XCTFail("Expected restoration request to be published")
            return ChatResumeRestorationRequest(generation: 0, sessionKey: .init(profile: "", sessionID: ""), destination: .latest)
        }
        return request
    }

    private func installComposerClient(
        in harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence,
            cacheClearSpy: CacheClearSpy,
            defaults: UserDefaults,
            suite: String
        )
    ) {
        let connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
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

    private func session(
        _ id: String,
        storedID: String? = nil,
        alternateIDs: [String] = [],
        profile: String = "default"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: storedID,
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

    private func serverScopedReviewSentinel() -> ReviewSummaryRecord {
        ReviewSummaryRecord(
            id: "sentinel-review",
            profile: "default",
            sessionId: "sentinel-session",
            timestamp: "2026-08-09T12:00:00Z",
            activity: ReviewActivity(
                summary: "Sentinel review",
                details: ["Sentinel detail"],
                fullSessionId: "sentinel-child"
            )
        )
    }
}

private enum ControlledLifecycleError: Error {
    case failed
}

private enum StaleReconnectMintOutcome {
    case success
    case signInRequired
}

@MainActor
private final class CacheClearSpy {
    var count = 0
}

@MainActor
private final class WeakAppStateReference {
    weak var value: AppState?
}

@MainActor
private final class ControlledReconnectScheduler {
    private final class Work {
        let operation: @MainActor () async -> Void
        var isCancelled = false

        init(operation: @escaping @MainActor () async -> Void) {
            self.operation = operation
        }
    }

    private var work: [Work] = []
    private(set) var delays: [TimeInterval] = []

    var cancelledCount: Int {
        work.filter(\.isCancelled).count
    }

    var scheduledCount: Int {
        work.count
    }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) -> ChatResumeReconnectCancellation {
        let item = Work(operation: operation)
        work.append(item)
        delays.append(delay)
        return {
            item.isCancelled = true
        }
    }

    func runAll() async {
        for item in work where !item.isCancelled {
            await item.operation()
        }
    }
}

@MainActor
private final class ReconnectExecutionSpy {
    var purposes: [ChatResumeSyncPurpose] = []
}

private final class ConnectCount {
    var value = 0
}

@MainActor
private final class ControlledSuspension {
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

@MainActor
private final class SessionOpenGates {
    private var gates: [String: ControlledSuspension]

    init(sessionIDs: [String]) {
        gates = Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0, ControlledSuspension()) })
    }

    func suspend(_ sessionID: String) async {
        await gates[sessionID]?.suspend()
    }

    func waitUntilSuspended(_ sessionID: String) async {
        await gates[sessionID]?.waitUntilSuspended()
    }

    func resume(_ sessionID: String) {
        gates[sessionID]?.resume()
    }
}
