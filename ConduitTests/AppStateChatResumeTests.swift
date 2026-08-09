import XCTest
@testable import Conduit

@MainActor
final class AppStateChatResumeTests: XCTestCase {
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

    func testCancelledAutomaticReconnectIgnoresLateSignInFailureAndRestoresConnectionState() async {
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
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .idle)
        gate.resume()
        await reconnect.value

        XCTAssertFalse(harness.appState.showLogin)
        XCTAssertEqual(harness.appState.connection?.ticket, "saved-ticket")
        XCTAssertTrue(harness.appState.client === originalClient)
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
    }

    func testUnchangedRefreshReleasesViewportTransitionForLaterWrites() async {
        let messages = [
            ChatMessage(id: "message-a", role: .assistant, content: "Stable", timestamp: "now")
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID in
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
            ChatScrollSnapshot(anchorMessageID: "anchor-before-refresh", followsLatest: false)
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
                openSession: { _, sessionID in
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
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) { captured }

        await harness.appState.refreshActiveSession()
        let generation = harness.appState.chatViewportTransitionGeneration
        let transcriptRevision = harness.appState.chatTranscriptRevision

        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: key,
            transitionGeneration: generation,
            transcriptRevision: transcriptRevision - 1,
            renderRevision: 7
        )
        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: key), captured)

        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: key,
            transitionGeneration: generation,
            transcriptRevision: transcriptRevision,
            renderRevision: 7
        )
        harness.appState.recordChatViewport(.latest, for: key)
        harness.appState.flushChatResumeViewport()
        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
    }

    func testOpenSessionTeardownLayoutCannotReleaseTransitionBeforeReconciliation() async {
        let gate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID in
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
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) { captured }

        let opening = Task { @MainActor in
            await harness.appState.openSession(sessionB.id)
        }
        await gate.waitUntilSuspended()
        harness.appState.chatViewportLayoutDidSettle(
            sessionKey: keyB,
            transitionGeneration: harness.appState.chatViewportTransitionGeneration,
            transcriptRevision: harness.appState.chatTranscriptRevision,
            renderRevision: 2
        )
        harness.appState.recordChatViewport(.latest, for: keyA)
        harness.appState.flushChatResumeViewport()

        XCTAssertEqual(harness.store.snapshot(for: keyA), captured)
        gate.resume()
        let opened = await opening.value
        XCTAssertTrue(opened)
    }

    func testFailedBranchReconciliationReleasesViewportTransitionForLaterWrites() async {
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, _ in throw ControlledLifecycleError.failed },
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
            ChatScrollSnapshot(anchorMessageID: "anchor-before-branch", followsLatest: false)
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
                openSession: { _, sessionID in
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
            ChatScrollSnapshot(anchorMessageID: "anchor-before-branch", followsLatest: false)
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
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) { exactAnchor }

        harness.appState.beginExplicitChatViewportTransition()
        harness.appState.activeSessionId = sessionB.id
        harness.appState.messages = []
        harness.appState.recordChatViewport(.latest, for: keyA)
        harness.appState.flushChatResumeViewport()

        XCTAssertEqual(harness.store.snapshot(for: keyA), exactAnchor)
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

    func testExplicitCancellationCancelsQueuedReconnectExecution() async {
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

        XCTAssertEqual(scheduler.cancelledCount, 1)
        XCTAssertTrue(reconnectSpy.purposes.isEmpty)
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
                    try! JSONEncoder().encode([review]),
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
        behavior: ChatResumeBehavior = .continueWhereLeftOff,
        configureDefaults: (UserDefaults) -> Void = { _ in },
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        reconnectExecutor: ChatResumeReconnectExecutor? = nil,
        lifecycleOperations: ChatResumeLifecycleOperations = .live
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
            chatResumeLifecycleOperations: lifecycleOperations
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

@MainActor
private final class CacheClearSpy {
    var count = 0
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

    var cancelledCount: Int {
        work.filter(\.isCancelled).count
    }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) -> ChatResumeReconnectCancellation {
        let item = Work(operation: operation)
        work.append(item)
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
