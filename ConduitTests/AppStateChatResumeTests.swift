import XCTest
@testable import Conduit

@MainActor
final class AppStateChatResumeTests: XCTestCase {
    func testSupersededBranchWaitingForTitleCannotMutateNewerSession() async {
        let titleGate = ControlledSuspension()
        let newerMessages = [
            ChatMessage(id: "newer", role: .assistant, content: "Newer session", timestamp: "3")
        ]
        let staleCatalog = session("stale-catalog")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [staleCatalog] },
                openSession: { _, sessionID in
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
                openSession: { _, sessionID in
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
                openSession: { _, sessionID in
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
                openSession: { _, sessionID in
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
                openSession: { _, sessionID in
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
                openSession: { _, sessionID in
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
                openSession: { _, sessionID in
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
        harness.appState.connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.client = HermesClient(
            connection: harness.appState.connection!,
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
                sendPrompt: { _, _, _ in await rpcGate.suspend() }
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
                sendPrompt: { _, _, _ in await sendGate.suspend() },
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
