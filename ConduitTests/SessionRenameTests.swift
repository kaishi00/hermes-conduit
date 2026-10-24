import XCTest
@testable import Conduit

@MainActor
final class SessionRenameTests: XCTestCase {
    private enum TestError: LocalizedError {
        case rejected

        var errorDescription: String? { "Gateway rejected rename" }
    }

    func testInvalidAndUnchangedTitlesDoNotIssueRequests() async throws {
        let session = makeSession(title: "Existing")
        var requestCount = 0
        let operations = SessionRenameOperation.Operations(
            renameRuntime: { _, _ in requestCount += 1 },
            renameStored: { _, _ in requestCount += 1 }
        )

        for title in ["", "   \n", "Existing", "  Existing  "] {
            let result = try await SessionRenameOperation.perform(
                session: session,
                activeSessionID: "runtime-id",
                title: title,
                operations: operations
            )
            XCTAssertNil(result)
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testActiveSessionUsesRuntimeRPC() async throws {
        let session = makeSession()
        var runtimeRequest: (String, String)?
        var storedRequest: (String, String)?

        let result = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "runtime-id",
            title: "  Renamed  ",
            operations: .init(
                renameRuntime: { runtimeRequest = ($0, $1) },
                renameStored: { storedRequest = ($0, $1) }
            )
        )

        XCTAssertEqual(runtimeRequest?.0, "runtime-id")
        XCTAssertEqual(runtimeRequest?.1, "Renamed")
        XCTAssertNil(storedRequest)
        XCTAssertEqual(result?.title, "Renamed")
    }

    func testInactiveSessionUsesStoredSessionPATCH() async throws {
        let session = makeSession()
        var runtimeRequest: (String, String)?
        var storedRequest: (String, String)?

        _ = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "another-session",
            title: "Renamed",
            operations: .init(
                renameRuntime: { runtimeRequest = ($0, $1) },
                renameStored: { storedRequest = ($0, $1) }
            )
        )

        XCTAssertNil(runtimeRequest)
        XCTAssertEqual(storedRequest?.0, "stored-id")
        XCTAssertEqual(storedRequest?.1, "Renamed")
    }

    func testRotatedActiveRuntimeOutsideRowIDsRenamesDurableTarget() async throws {
        // A runtime rotation the row has not caught up with (activeSessionID
        // is the confirmed new runtime, the stale row still lists only the
        // old one) must not fire the runtime RPC at an unverified id: the
        // rename targets the row's durable id instead.
        let session = makeSession()
        var runtimeRequest: (String, String)?
        var storedRequest: (String, String)?

        _ = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "runtime-new",
            title: "Renamed",
            operations: .init(
                renameRuntime: { runtimeRequest = ($0, $1) },
                renameStored: { storedRequest = ($0, $1) }
            )
        )

        XCTAssertNil(runtimeRequest, "runtime-new is not positively tied to this row")
        XCTAssertEqual(storedRequest?.0, "stored-id", "The durable id is the safe rename target")
        XCTAssertEqual(storedRequest?.1, "Renamed")
    }

    func testFailedRuntimeRPCFallsBackToStoredSessionPATCH() async throws {
        let session = makeSession()
        var storedRequest: (String, String)?

        let result = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "runtime-id",
            title: "Renamed",
            operations: .init(
                renameRuntime: { _, _ in throw TestError.rejected },
                renameStored: { storedRequest = ($0, $1) }
            )
        )

        XCTAssertEqual(storedRequest?.0, "stored-id")
        XCTAssertEqual(storedRequest?.1, "Renamed")
        XCTAssertEqual(result?.title, "Renamed")
    }

    func testSuccessfulRenameUpdatesEveryIdentityProjection() async throws {
        let session = makeSession()
        let operationResult = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "runtime-id",
            title: "Renamed",
            operations: .init(
                renameRuntime: { sessionID, _ in
                    XCTAssertEqual(sessionID, "runtime-id")
                },
                renameStored: { _, _ in XCTFail("Active rename must use the runtime RPC") }
            )
        )
        let result = try XCTUnwrap(operationResult)

        let storedEntry = result.updating(session)
        let runtimeEntry = result.updating(makeSession(
            id: "runtime-id",
            alternateIDs: ["stored-id"],
            title: "Old runtime title"
        ))
        let archivedEntry = result.updating(makeSession(
            id: "archived-id",
            alternateIDs: ["runtime-id"],
            title: "Old archived title"
        ))
        let unrelatedEntry = result.updating(makeSession(id: "unrelated", alternateIDs: []))

        XCTAssertEqual(storedEntry.title, "Renamed")
        XCTAssertEqual(runtimeEntry.title, "Renamed")
        XCTAssertEqual(archivedEntry.title, "Renamed")
        XCTAssertTrue(result.matches(sessionID: "runtime-id"), "The active title must receive the rename")
        XCTAssertEqual(unrelatedEntry.title, "Original")
    }

    func testContextChangeDoesNotFallBackToStoredSession() async {
        var storedRequestCount = 0

        do {
            _ = try await SessionRenameOperation.perform(
                session: makeSession(),
                activeSessionID: "runtime-id",
                title: "Renamed",
                operations: .init(
                    renameRuntime: { _, _ in throw SessionRenameOperation.ContextChanged() },
                    renameStored: { _, _ in storedRequestCount += 1 }
                )
            )
            XCTFail("Expected the context change to terminate the rename")
        } catch is SessionRenameOperation.ContextChanged {
            // Expected: a stale client or profile must not mutate stored state.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(storedRequestCount, 0)
    }

    func testInactiveRenameSurvivesAppStateCatalogRefresh() async {
        var remoteCatalog: [SessionSummary] = []
        var forcedRefresh = false
        let appState = AppState(
            loadSavedConnection: false,
            sessionRenameOperations: .init(
                renameRuntime: { _, _ in XCTFail("Inactive rename must not use the runtime RPC") },
                renameStored: { sessionID, title in
                    remoteCatalog = remoteCatalog.map { session in
                        guard session.id == sessionID else { return session }
                        var updated = session
                        updated.title = title
                        return updated
                    }
                }
            ),
            sessionCatalogLoader: { forceRefresh in
                forcedRefresh = forceRefresh
                return remoteCatalog
            }
        )
        let target = makeSession(profile: appState.activeProfile)
        let active = makeSession(
            id: "active-id",
            alternateIDs: [],
            title: "Active",
            profile: appState.activeProfile
        )
        remoteCatalog = [target, active]
        appState.sessions = remoteCatalog
        appState.activeSessionId = active.id

        let didRename = await appState.renameSession(target, to: "Renamed")
        XCTAssertTrue(didRename)
        XCTAssertEqual(appState.sessions.first { $0.id == target.id }?.title, "Renamed")

        await appState.refreshSessionCatalog()

        XCTAssertTrue(forcedRefresh)
        XCTAssertEqual(appState.sessions.first { $0.id == target.id }?.title, "Renamed")
        XCTAssertEqual(appState.sessions.first { $0.id == active.id }?.title, "Active")
    }

    func testTerminalFailurePreservesAppStateAndSurfacesExistingError() async {
        let appState = AppState(
            loadSavedConnection: false,
            sessionRenameOperations: .init(
                renameRuntime: { _, _ in throw TestError.rejected },
                renameStored: { _, _ in throw TestError.rejected }
            )
        )
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]
        appState.activeSessionId = "runtime-id"
        let previousActiveTitle = appState.activeSessionTitle

        let didRename = await appState.renameSession(session, to: "Renamed")

        XCTAssertFalse(didRename)
        XCTAssertEqual(appState.sessions.map(\.title), ["Original"])
        XCTAssertEqual(appState.activeSessionTitle, previousActiveTitle)
        XCTAssertEqual(
            appState.pinSyncNotice?.message,
            "Could not rename this conversation: Gateway rejected rename"
        )
    }

    // Archive and delete failures show over the Chats list and the open chat:
    // `errorMessage` only shows while the composer is locked, so a refused
    // change looked like the tap did nothing.

    func testRefusedArchiveKeepsTheChatAndSaysWhy() async {
        let appState = AppState(loadSavedConnection: false)
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]
        appState.widgetSessionMutationRequestOverride = { _, method, _ in
            if method == "GET" { return ["runtime_revision": 3, "runtime_generation": 1] }
            throw DashboardTicketBridgeError.http(status: 403, detail: "permission_denied")
        }

        let archived = await appState.archiveSession(session)

        XCTAssertFalse(archived)
        XCTAssertEqual(appState.sessions.map(\.id), [session.id])
        XCTAssertEqual(
            appState.pinSyncNotice?.message,
            "Could not archive this conversation: Hermes only lets the computer it runs on change this older chat. Change it there instead."
        )
    }

    func testRefusedDeleteKeepsTheChatAndSaysWhy() async {
        let appState = AppState(loadSavedConnection: false)
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]
        var deletePath: String?
        appState.widgetSessionMutationRequestOverride = { path, method, _ in
            if method == "GET" { return ["runtime_revision": 3, "runtime_generation": 1] }
            deletePath = path
            throw DashboardTicketBridgeError.http(status: 403, detail: "permission_denied")
        }

        let deleted = await appState.deleteSession(session)

        XCTAssertFalse(deleted)
        XCTAssertEqual(appState.sessions.map(\.id), [session.id])
        XCTAssertTrue(deletePath?.contains("expected_generation=1") == true)
        XCTAssertEqual(
            appState.pinSyncNotice?.message,
            "Could not delete this conversation: Hermes only lets the computer it runs on change this older chat. Change it there instead."
        )
    }

    func testDeleteRemovesTheChatWhenHermesTakesIt() async {
        let appState = AppState(loadSavedConnection: false)
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]
        appState.widgetSessionMutationRequestOverride = { _, method, _ in
            method == "GET" ? ["runtime_revision": 3, "runtime_generation": 1] : ["ok": true]
        }

        let deleted = await appState.deleteSession(session)

        XCTAssertTrue(deleted)
        XCTAssertTrue(appState.sessions.isEmpty)
        XCTAssertNil(appState.pinSyncNotice)
    }

    func testDeleteDuringAnotherChangeSaysToWait() async {
        let appState = AppState(loadSavedConnection: false)
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]
        var release: CheckedContinuation<Void, Never>?
        appState.widgetSessionMutationRequestOverride = { _, method, _ in
            if method == "GET" { return ["runtime_revision": 3, "runtime_generation": 1] }
            await withCheckedContinuation { release = $0 }
            return ["ok": true]
        }

        let archive = Task { await appState.archiveSession(session) }
        let deadline = Date().addingTimeInterval(5)
        while !appState.isSessionMutationInFlight(session) || release == nil {
            guard Date() < deadline else { return XCTFail("The archive never reached Hermes") }
            await Task.yield()
        }
        let deleted = await appState.deleteSession(session)

        XCTAssertFalse(deleted)
        XCTAssertEqual(
            appState.pinSyncNotice?.message,
            "Wait for the current conversation change to finish, then try again."
        )
        release?.resume()
        let archived = await archive.value
        XCTAssertTrue(archived)
    }

    func testArchiveWithoutHermesSaysToReconnect() async {
        let appState = AppState(loadSavedConnection: false)
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]

        let archived = await appState.archiveSession(session)

        XCTAssertFalse(archived)
        XCTAssertEqual(appState.pinSyncNotice?.message, "Reconnect to Hermes to change this conversation.")
    }

    func testTransportCancellationRemainsAUserVisibleFailure() async {
        do {
            _ = try await SessionRenameOperation.perform(
                session: makeSession(),
                activeSessionID: nil,
                title: "Renamed",
                operations: .init(
                    renameRuntime: nil,
                    renameStored: { _, _ in throw CancellationError() }
                )
            )
            XCTFail("Expected transport cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertTrue(SessionRenameOperation.failureMessage(error).hasPrefix(
                "Could not rename this conversation:"
            ))
        }
    }

    func testManualRenameCancelsAndInvalidatesPendingTitleRecovery() async {
        let tracker = SessionTitleRecoveryTracker()
        let key = "research|stored-id"
        let keys: Set = [key]
        let token = UUID()
        var title = "Original"
        var recoveryFinished = false

        let recovery = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                // Cancellation resumes the recovery so it can observe its stale token.
            }
            if tracker.isCurrent(token, for: key) {
                title = "Automatic title"
            }
            recoveryFinished = true
        }
        tracker.register(recovery, token: token, for: key)
        tracker.suppress(keys)

        await tracker.cancel(keys)
        title = "Manual title"

        XCTAssertTrue(recoveryFinished, "Manual rename must await pending recovery termination")
        XCTAssertFalse(tracker.isCurrent(token, for: key))
        XCTAssertEqual(title, "Manual title")
        XCTAssertTrue(tracker.isSuppressed(key))

        tracker.unsuppress(keys)
        XCTAssertFalse(tracker.isSuppressed(key))
    }

    func testStaleRecoveryCompletionCannotRemoveReplacementTask() async {
        let tracker = SessionTitleRecoveryTracker()
        let key = "research|stored-id"
        let staleToken = UUID()
        let currentToken = UUID()
        let staleTask = Task<Void, Never> {}

        tracker.register(staleTask, token: staleToken, for: key)
        tracker.cancel(key)

        let currentTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        tracker.register(currentTask, token: currentToken, for: key)
        tracker.finish(staleToken, for: key)

        XCTAssertTrue(tracker.hasTask(for: key))
        XCTAssertTrue(tracker.isCurrent(currentToken, for: key))

        await tracker.cancel([key])
    }

    // Archiving or deleting the open chat leaves an empty canvas with a
    // live composer. A message sent there starts a new chat and goes
    // into it; it used to be dropped without a word.

    func testAMessageSentAfterArchivingTheOpenChatStartsANewChat() async {
        var prompts: [(sessionID: String, text: String)] = []
        let appState = makeConnectedAppState { sessionID, text in prompts.append((sessionID, text)) }
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]
        appState.activeSessionId = session.id

        let archived = await appState.archiveSession(session)

        XCTAssertTrue(archived)
        XCTAssertNil(appState.activeSessionId)
        XCTAssertEqual(appState.composerChatOnScreen, .none)
        XCTAssertEqual(appState.composerAction(hasText: true, hasAttachments: false), .send)

        let sent = await appState.submitComposer(text: "hi")

        XCTAssertTrue(sent, "The message goes into a new chat")
        XCTAssertEqual(appState.activeSessionId, "created-runtime")
        XCTAssertEqual(prompts.map(\.sessionID), ["created-runtime"])
        XCTAssertEqual(prompts.map(\.text), ["hi"])
        XCTAssertTrue(appState.messages.contains { $0.role == .user && $0.content == "hi" })
        XCTAssertNil(appState.errorMessage)
    }

    func testASlashCommandOnTheEmptyCanvasStartsNoChat() async {
        var created = 0
        let appState = makeConnectedAppState { _, _ in }
        appState.widgetSessionCreatorOverride = { _, _ in
            created += 1
            return ("created-runtime", "created-stored", "default")
        }
        XCTAssertNil(appState.activeSessionId)

        _ = await appState.submitComposer(text: "/help")

        XCTAssertEqual(created, 0, "A slash command runs as before, without a chat")
    }

    func testAMessageThatCantStartAChatSaysWhyAndIsKept() async {
        struct CreateRefused: Error {}
        var prompts = 0
        let appState = makeConnectedAppState { _, _ in prompts += 1 }
        appState.widgetSessionCreatorOverride = { _, _ in throw CreateRefused() }
        XCTAssertNil(appState.activeSessionId)

        let sent = await appState.submitComposer(text: "hi")

        // False: the composer puts the text back (ComposerBar).
        XCTAssertFalse(sent)
        XCTAssertNil(appState.activeSessionId)
        XCTAssertEqual(prompts, 0)
        XCTAssertNotNil(appState.errorMessage, "A send that goes nowhere says why")
        XCTAssertFalse(appState.isStartingNewChat, "a failed start leaves New Chat and the next send free")
    }

    func testAMessageWhoseChatDidntStartNeverGoesIntoAChatOpenedMeanwhile() async {
        struct CreateRefused: Error {}
        var prompts: [String] = []
        let appState = makeConnectedAppState { sessionID, _ in prompts.append(sessionID) }
        let other = makeSession(id: "other-stored", alternateIDs: [], profile: appState.activeProfile)
        appState.sessions = [other]
        appState.widgetSessionCreatorOverride = { _, _ in
            // The user opens another chat while Hermes creates this one.
            appState.activeSessionId = other.id
            throw CreateRefused()
        }

        let sent = await appState.submitComposer(text: "hi")

        XCTAssertFalse(sent, "The composer keeps the message")
        XCTAssertTrue(prompts.isEmpty, "Never sent into the chat opened meanwhile: \(prompts)")
    }

    func testAMessageSentDisconnectedSaysToConnectOverAnOlderMessage() async {
        var created = 0
        let appState = makeConnectedAppState { _, _ in }
        appState.widgetSessionCreatorOverride = { _, _ in
            created += 1
            return ("created-runtime", "created-stored", "default")
        }
        appState.isConnected = false
        appState.errorMessage = "An older, unrelated failure."

        let sent = await appState.submitComposer(text: "hi")

        XCTAssertFalse(sent)
        XCTAssertEqual(created, 0)
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("Connect to Hermes to start a conversation."))
        XCTAssertFalse(appState.isStartingNewChat)
    }

    func testAMessageSentWhileConnectedButNotReadyIsNotToldToConnect() async {
        var created = 0
        let appState = makeConnectedAppState { _, _ in }
        appState.widgetSessionCreatorOverride = { _, _ in
            created += 1
            return ("created-runtime", "created-stored", "default")
        }
        // Connected, with a reconnect under way: no chat can start yet,
        // but the connection isn't what the user has to fix.
        appState.isConnecting = true

        let sent = await appState.submitComposer(text: "hi")

        XCTAssertFalse(sent)
        XCTAssertEqual(created, 0)
        XCTAssertNotEqual(appState.errorMessage, AppLocalization.string("Connect to Hermes to start a conversation."))
    }

    private func makeConnectedAppState(
        onPrompt: @escaping @MainActor (String, String) -> Void
    ) -> AppState {
        let suite = "ArchiveThenSendTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, sessionID, text in
                    onPrompt(sessionID, text)
                    return .accepted
                }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.widgetSessionMutationRequestOverride = { _, method, _ in
            method == "GET" ? ["runtime_revision": 3, "runtime_generation": 1] : ["ok": true]
        }
        appState.widgetSessionCreatorOverride = { _, _ in ("created-runtime", "created-stored", "default") }
        return appState
    }

    private func makeSession(
        id: String = "stored-id",
        alternateIDs: [String] = ["runtime-id"],
        title: String = "Original",
        profile: String? = "default"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternateIDs,
            title: title,
            model: "test-model",
            updatedLabel: "now",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false
        )
    }
}
