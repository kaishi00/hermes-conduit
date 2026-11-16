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

    func testAMessageNeverGoesIntoAChatAnotherCreationOpenedMeanwhile() async {
        var prompts: [String] = []
        let appState = makeConnectedAppState { sessionID, _ in prompts.append(sessionID) }
        var creations = 0
        appState.widgetSessionCreatorOverride = { _, _ in
            creations += 1
            if creations == 1 {
                // A voice action or a screen question creates its own chat
                // while Hermes creates the composer's.
                await appState.createNewSession()
                return ("composer-runtime", "composer-stored", "default")
            }
            return ("voice-runtime", "voice-stored", "default")
        }

        let sent = await appState.submitComposer(text: "hi")

        XCTAssertEqual(creations, 2)
        XCTAssertEqual(appState.activeSessionId, "voice-runtime", "The newer creation keeps the screen")
        XCTAssertFalse(sent, "The composer keeps the message")
        XCTAssertTrue(prompts.isEmpty, "Never sent into the other creation's chat: \(prompts)")
        XCTAssertFalse(appState.isStartingNewChat)
    }

    func testAHermesWatchPromptNeverLandsInAChatAnotherCreationOpenedMeanwhile() async {
        let appState = makeConnectedAppState { _, _ in }
        var creations = 0
        appState.widgetSessionCreatorOverride = { _, _ in
            creations += 1
            if creations == 1 {
                await appState.createNewSession()
                return ("watch-runtime", "watch-stored", "default")
            }
            return ("voice-runtime", "voice-stored", "default")
        }

        await appState.startHermesWatch(for: "the porch light")

        XCTAssertEqual(creations, 2)
        XCTAssertEqual(appState.activeSessionId, "voice-runtime")
        XCTAssertNil(appState.composerPrefillDraftKey, "No prompt put into the other creation's chat")
        XCTAssertNotNil(appState.errorMessage, "The watch chat that didn't start says so")
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

    // MARK: - New Chat leaves a chat mid-reply (all-live stage 2)

    /// New Chat while the open chat's turn runs with no words yet (just
    /// sent, or a tool step) follows that chat's reply, as an open or a
    /// profile switch does, though the turn reads synchronizing by the time
    /// the new chat is adopted. A New Chat that starts nothing lets go of it.
    func testANewChatFollowsARunningTurnWithNoWordsYet() async {
        let appState = makeConnectedAppState { _, _ in }
        appState.savedDashboardRegistry.activeDashboardID = UUID()
        appState.sessions = [makeSession(id: "a", alternateIDs: [], title: "Story")]
        var createFails = true
        guard let creator = appState.widgetSessionCreatorOverride else {
            return XCTFail("The harness creates chats through the override")
        }
        appState.widgetSessionCreatorOverride = { client, cwd in
            if createFails { throw URLError(.notConnectedToInternet) }
            return try await creator(client, cwd)
        }
        appState.setActiveSessionState(id: "a")
        appState.messages = [ChatMessage(id: "u1", role: .user, content: "Tell me a story", timestamp: "1")]
        appState.turnState = .running

        await appState.createNewSession()
        XCTAssertEqual(appState.activeSessionId, "a")
        XCTAssertTrue(appState.backgroundChats.isEmpty, "No chat started: the one on screen isn't left")

        appState.turnState = .running
        createFails = false
        let created = await appState.createNewSession()
        XCTAssertEqual(created, "created-runtime")
        XCTAssertEqual(appState.backgroundChats.first?.sessionIDs.contains("a"), true)
        appState.handleStreamEvent(.messageDelta(sessionId: "a", text: "Once upon a time"))
        XCTAssertEqual(appState.backgroundChats.first?.rows.last?.content, "Once upon a time")
        XCTAssertFalse(appState.messages.contains { $0.content == "Once upon a time" },
                       "The new chat never takes the left chat's words")
    }

    /// Words the left chat streams while New Chat's create is out stay in
    /// its followed copy, under its own title: the create's adoption
    /// doesn't follow it again from the screen's rows, which stopped at the
    /// tap (issue 2523). A repeated completion for the reply finalizes its
    /// row in place rather than adding a twin (issue 2511).
    func testWordsStreamedDuringANewChatsCreateStayInTheFollowedCopy() async throws {
        let appState = makeConnectedAppState { _, _ in }
        appState.savedDashboardRegistry.activeDashboardID = UUID()
        appState.sessions = [makeSession(id: "a", alternateIDs: [], title: "Story")]
        guard let creator = appState.widgetSessionCreatorOverride else {
            return XCTFail("The harness creates chats through the override")
        }
        var waiting: CheckedContinuation<Void, Never>?
        appState.widgetSessionCreatorOverride = { client, cwd in
            await withCheckedContinuation { waiting = $0 }
            return try await creator(client, cwd)
        }
        appState.setActiveSessionState(id: "a", title: "Story")
        appState.messages = [ChatMessage(id: "u1", role: .user, content: "Tell me a story", timestamp: "1")]
        appState.turnState = .running
        appState.handleStreamEvent(.messageDelta(sessionId: "a", text: "Once upon"))

        let create = Task { await appState.createNewSession() }
        for _ in 0..<2000 where waiting == nil { await Task.yield() }
        guard let barrier = waiting else {
            create.cancel()
            return XCTFail("The create reaches Hermes")
        }
        appState.handleStreamEvent(.messageDelta(sessionId: "a", text: " a time"))
        barrier.resume()
        let created = await create.value
        XCTAssertEqual(created, "created-runtime")

        let followed = try XCTUnwrap(appState.followedChat(answering: ["a"]))
        XCTAssertEqual(followed.title, "Story")
        XCTAssertEqual(followed.rows.last?.content, "Once upon a time")

        appState.handleStreamEvent(.messageComplete(sessionId: "a", messageId: "r1", content: "Once upon a time.", reasoning: nil))
        appState.handleStreamEvent(.messageComplete(sessionId: "a", messageId: "r1", content: "Once upon a time, the end.", reasoning: nil))
        let finished = try XCTUnwrap(appState.followedChat(answering: ["a"]))
        XCTAssertEqual(finished.rows.map(\.content), ["Tell me a story", "Once upon a time, the end."])
    }

    /// Two New Chats that overlap (a widget's beside the button's) and
    /// start nothing: the first to finish keeps the follow, since the other
    /// still leaves the chat, and the last lets go of it, though it followed
    /// nothing itself (the turn already read synchronizing).
    func testOverlappingNewChatsThatStartNothingLetGoOfTheFollowTogether() async {
        let appState = makeConnectedAppState { _, _ in }
        appState.savedDashboardRegistry.activeDashboardID = UUID()
        appState.sessions = [makeSession(id: "a", alternateIDs: [], title: "Story")]
        var waiting: [CheckedContinuation<Void, Never>] = []
        appState.widgetSessionCreatorOverride = { _, _ in
            await withCheckedContinuation { waiting.append($0) }
            throw URLError(.notConnectedToInternet)
        }
        appState.setActiveSessionState(id: "a")
        appState.messages = [ChatMessage(id: "u1", role: .user, content: "Tell me a story", timestamp: "1")]
        appState.turnState = .running

        func waitForCreations(_ count: Int) async {
            for _ in 0..<2000 where waiting.count < count { await Task.yield() }
            XCTAssertEqual(waiting.count, count, "Both creations reach Hermes")
        }
        let first = Task { await appState.createNewSession() }
        await waitForCreations(1)
        let second = Task { await appState.createNewSession() }
        await waitForCreations(2)
        guard waiting.count == 2 else { return }
        XCTAssertEqual(appState.backgroundChats.count, 1)

        waiting[0].resume()
        _ = await first.value
        XCTAssertEqual(appState.backgroundChats.count, 1, "Another New Chat still leaves it")
        waiting[1].resume()
        _ = await second.value
        XCTAssertEqual(appState.activeSessionId, "a")
        XCTAssertTrue(appState.backgroundChats.isEmpty, "No chat started: the one on screen isn't left")
    }

    /// A lone New Chat that fails while a followed chat's open is still
    /// landing (the turn reads synchronizing, the copy on screen) leaves the
    /// follow alone: the open still relies on it if it fails or is overtaken.
    func testAFailedNewChatDuringAnOpenKeepsTheFollow() async {
        let appState = makeConnectedAppState { _, _ in }
        appState.savedDashboardRegistry.activeDashboardID = UUID()
        appState.sessions = [makeSession(id: "a", alternateIDs: [], title: "Story"), makeSession(id: "b", alternateIDs: [], title: "Other")]
        appState.widgetSessionCreatorOverride = { _, _ in throw URLError(.notConnectedToInternet) }
        appState.setActiveSessionState(id: "a")
        appState.messages = [ChatMessage(id: "u1", role: .user, content: "Tell me a story", timestamp: "1")]
        appState.turnState = .running
        appState.handleStreamEvent(.messageDelta(sessionId: "a", text: "Once upon"))
        appState.setActiveSessionState(id: "b")
        appState.messages = []
        appState.clearStreamingText()
        appState.turnState = .idle
        guard let followed = appState.followedChat(answering: ["a"]) else {
            return XCTFail("Chat a is followed once left mid-reply")
        }

        // Opening a again: its copy shows while the open lands.
        appState.setActiveSessionState(id: "a")
        appState.messages = []
        XCTAssertTrue(appState.presentBackgroundChat(followed, openedAs: "a"))
        appState.turnState = .synchronizing

        await appState.createNewSession()
        XCTAssertEqual(appState.activeSessionId, "a")
        XCTAssertNotNil(appState.followedChat(answering: ["a"]), "The open still landing keeps its follow")
    }

    /// Issue 2505: two overlapping New Chats that both fail while a
    /// followed chat's open is still landing leave the follow alone, since
    /// neither of them followed it: the open still relies on it.
    func testOverlappingFailedNewChatsDuringAnOpenKeepTheFollow() async {
        let appState = makeConnectedAppState { _, _ in }
        appState.savedDashboardRegistry.activeDashboardID = UUID()
        appState.sessions = [makeSession(id: "a", alternateIDs: [], title: "Story"), makeSession(id: "b", alternateIDs: [], title: "Other")]
        var waiting: [CheckedContinuation<Void, Never>] = []
        appState.widgetSessionCreatorOverride = { _, _ in
            await withCheckedContinuation { waiting.append($0) }
            throw URLError(.notConnectedToInternet)
        }
        appState.setActiveSessionState(id: "a")
        appState.messages = [ChatMessage(id: "u1", role: .user, content: "Tell me a story", timestamp: "1")]
        appState.turnState = .running
        appState.handleStreamEvent(.messageDelta(sessionId: "a", text: "Once upon"))
        appState.setActiveSessionState(id: "b")
        appState.messages = []
        appState.clearStreamingText()
        appState.turnState = .idle
        guard let followed = appState.followedChat(answering: ["a"]) else {
            return XCTFail("Chat a is followed once left mid-reply")
        }
        appState.setActiveSessionState(id: "a")
        appState.messages = []
        XCTAssertTrue(appState.presentBackgroundChat(followed, openedAs: "a"))
        appState.turnState = .synchronizing

        func waitForCreations(_ count: Int) async {
            for _ in 0..<2000 where waiting.count < count { await Task.yield() }
            XCTAssertEqual(waiting.count, count, "Both creations reach Hermes")
        }
        let first = Task { await appState.createNewSession() }
        await waitForCreations(1)
        let second = Task { await appState.createNewSession() }
        await waitForCreations(2)
        guard waiting.count == 2 else { return }
        waiting[0].resume()
        _ = await first.value
        waiting[1].resume()
        _ = await second.value

        XCTAssertEqual(appState.activeSessionId, "a")
        XCTAssertNotNil(appState.followedChat(answering: ["a"]), "The open still landing keeps its follow")
    }

    /// Issue 2577: a New Chat tapped again during the first one's create
    /// keeps the copy the first one followed, which took words the screen
    /// never got, rather than a second snapshot of the screen.
    func testASecondNewChatDuringACreateKeepsTheFollowedCopy() async {
        let appState = makeConnectedAppState { _, _ in }
        appState.savedDashboardRegistry.activeDashboardID = UUID()
        appState.sessions = [makeSession(id: "a", alternateIDs: [], title: "Story")]
        var waiting: [CheckedContinuation<Void, Never>] = []
        appState.widgetSessionCreatorOverride = { _, _ in
            await withCheckedContinuation { waiting.append($0) }
            throw URLError(.notConnectedToInternet)
        }
        appState.setActiveSessionState(id: "a")
        appState.messages = [ChatMessage(id: "u1", role: .user, content: "Tell me a story", timestamp: "1")]
        appState.turnState = .running
        appState.handleStreamEvent(.messageDelta(sessionId: "a", text: "Once upon"))

        func waitForCreations(_ count: Int) async {
            for _ in 0..<2000 where waiting.count < count { await Task.yield() }
            XCTAssertEqual(waiting.count, count, "Both creations reach Hermes")
        }
        let first = Task { await appState.createNewSession() }
        await waitForCreations(1)
        guard let followed = appState.followedChat(answering: ["a"]) else {
            waiting.forEach { $0.resume() }
            return XCTFail("The first New Chat follows the chat it leaves")
        }
        // Words only the followed copy took after the first create began.
        followed.state.streamingBuffer += " a time"
        let second = Task { await appState.createNewSession() }
        await waitForCreations(2)
        XCTAssertEqual(appState.followedChat(answering: ["a"])?.state.streamingBuffer, "Once upon a time",
                       "The second New Chat keeps the copy the first one followed")
        waiting.forEach { $0.resume() }
        _ = await first.value
        _ = await second.value
    }

    /// A New Chat that fails after the user reopened the chat it left (its
    /// followed copy on screen while that open lands) leaves the follow to
    /// the open, which still relies on it.
    func testAFailedNewChatLeavesTheFollowToAReopenDuringItsCreate() async {
        let appState = makeConnectedAppState { _, _ in }
        appState.savedDashboardRegistry.activeDashboardID = UUID()
        appState.sessions = [makeSession(id: "a", alternateIDs: [], title: "Story")]
        var waiting: [CheckedContinuation<Void, Never>] = []
        appState.widgetSessionCreatorOverride = { _, _ in
            await withCheckedContinuation { waiting.append($0) }
            throw URLError(.notConnectedToInternet)
        }
        appState.setActiveSessionState(id: "a")
        appState.messages = [ChatMessage(id: "u1", role: .user, content: "Tell me a story", timestamp: "1")]
        appState.turnState = .running
        appState.handleStreamEvent(.messageDelta(sessionId: "a", text: "Once upon"))

        let create = Task { await appState.createNewSession() }
        for _ in 0..<2000 where waiting.isEmpty { await Task.yield() }
        guard let followed = appState.followedChat(answering: ["a"]) else {
            waiting.forEach { $0.resume() }
            return XCTFail("The New Chat follows the chat it leaves")
        }
        // Reopened during the create: its copy shows while that open lands.
        appState.setActiveSessionState(id: "a")
        appState.messages = []
        XCTAssertTrue(appState.presentBackgroundChat(followed, openedAs: "a"))
        waiting.forEach { $0.resume() }
        _ = await create.value

        XCTAssertEqual(appState.activeSessionId, "a")
        XCTAssertNotNil(appState.followedChat(answering: ["a"]), "The reopen still landing keeps the copy the run followed")
    }

    /// #2612's review: a New Chat's reconcile takes no rebound id routed
    /// for the chat it leaves.
    func testANewChatTakesNoReboundIDRoutedForTheChatItLeaves() async {
        let appState = makeConnectedAppState { _, _ in }
        appState.sessions = [makeSession(id: "a", alternateIDs: [], title: "Story")]
        var waiting: [CheckedContinuation<Void, Never>] = []
        let (creating, createStarted) = AsyncStream<Void>.makeStream()
        appState.widgetSessionCreatorOverride = { _, _ in
            createStarted.yield(())
            await withCheckedContinuation { waiting.append($0) }
            throw URLError(.notConnectedToInternet)
        }
        appState.setActiveSessionState(id: "a")
        appState.reconciliation = AppState.Reconciliation(
            token: UUID(), requestedSessionId: "a", acceptedSessionIDs: ["a", "rt-a"], reboundSessionIDs: ["rt-a": "a"],
            movedOnSessionIDs: ["rt-b"]
        )

        let create = Task { await appState.createNewSession() }
        // The create's own signal that it's under way (issue 2619).
        for await _ in creating { break }
        XCTAssertEqual(appState.reconciliation?.reboundSessionIDs, [:], "Chat a's rebound id stays with chat a")
        XCTAssertEqual(appState.reconciliation?.movedOnSessionIDs, [], "…and turns away none chat a's open let go")
        XCTAssertFalse(waiting.isEmpty, "The create is under way")
        waiting.forEach { $0.resume() }
        _ = await create.value
    }

    // MARK: - A new chat in the list (issue 1454)

    func testANewChatStaysListedWhileOpenUntilHermesListsIt() async {
        let other = makeSession(id: "other-stored", alternateIDs: [], title: "Older chat")
        var catalog = [other]
        let appState = makeConnectedAppState(catalog: { catalog }) { _, _ in }

        let created = await appState.createNewSession()
        XCTAssertEqual(created, "created-runtime")
        // Hermes lists a chat once its first message is stored: a read
        // before then keeps the open chat's row instead of dropping it.
        await appState.loadSessions()
        XCTAssertEqual(appState.sessions.map(\.id), ["created-stored", "other-stored"])
        XCTAssertTrue(appState.isOpenChatRow(appState.sessions[0]), "marked open beside the chat, though open by its runtime id")
        XCTAssertFalse(appState.isOpenChatRow(other))

        // Listed by Hermes: its own row, title and all, takes over.
        catalog = [makeSession(id: "created-stored", alternateIDs: [], title: "Trip plans"), other]
        await appState.loadSessions()
        XCTAssertEqual(appState.sessions.map(\.title), ["Trip plans", "Older chat"])
        XCTAssertNil(appState.newChatAwaitingListing)
        XCTAssertTrue(appState.isOpenChatRow(appState.sessions[0]), "Hermes' row, under the stored id the create confirmed")
    }

    func testANewChatLeftEmptyLeavesTheList() async {
        let other = makeSession(id: "other-stored", alternateIDs: [], title: "Older chat")
        let appState = makeConnectedAppState(catalog: { [other] }) { _, _ in }

        await appState.createNewSession()
        appState.activeSessionId = other.id
        await appState.loadSessions()

        XCTAssertEqual(appState.sessions.map(\.id), ["other-stored"], "Hermes has no row for a chat left empty")
        XCTAssertNil(appState.newChatAwaitingListing)
    }

    /// Hermes keeps no row for a chat until its first message, so a Hermes
    /// before v0.22.0 that dropped the runtime of an empty new chat answers
    /// "session not found" for it forever (an App Store review, 2026-11-02):
    /// a refresh puts a fresh chat in its place instead of an error.
    func testAnEmptyNewChatHermesLostIsReplacedOnRefresh() async {
        var lost: Set<String> = []
        var created = 0
        let appState = makeLostChatAppState(lost: { lost }, onCreate: { created += 1 }) { _, _ in }

        let first = await appState.createNewSession()
        XCTAssertEqual(first, "created-runtime-1")
        lost = ["created-runtime-1", "created-stored-1"]
        await appState.refreshActiveSession()

        XCTAssertEqual(created, 2)
        XCTAssertEqual(appState.activeSessionId, "created-runtime-2")
        XCTAssertNil(appState.errorMessage, "nothing was said in it, so nothing to report")
        XCTAssertEqual(appState.turnState, .idle)
        XCTAssertEqual(appState.sessions.map(\.id), ["created-stored-2"], "the lost chat's row goes")
        // A draft typed in the lost chat is the fresh chat's (the composer
        // moves it on the switch, as from New Chat to the chat it made).
        let lostDraft = ComposerBar.composerDraftKey(for: "created-runtime-1", profile: "default")
        let freshDraft = ComposerBar.composerDraftKey(for: "created-runtime-2", profile: "default")
        XCTAssertTrue(appState.composerDraftKeysAreSameChat(lostDraft, freshDraft))
        XCTAssertTrue(appState.composerDraftKeysAreSameChat(freshDraft, lostDraft))
    }

    /// The chat a sync opens when there is nothing to resume is made here
    /// and empty too: the same dead end, the same fresh chat, still not
    /// listed before Hermes lists it.
    func testTheEmptyChatASyncOpenedIsReplacedToo() async {
        var lost: Set<String> = []
        var created = 0
        let appState = makeLostChatAppState(lost: { lost }, onCreate: { created += 1 }) { _, _ in }

        await appState.syncSession()
        XCTAssertEqual(appState.activeSessionId, "created-runtime-1")
        XCTAssertNil(appState.newChatAwaitingListing)
        lost = ["created-runtime-1", "created-stored-1"]
        await appState.refreshActiveSession()

        XCTAssertEqual(created, 2)
        XCTAssertEqual(appState.activeSessionId, "created-runtime-2")
        XCTAssertNil(appState.errorMessage)
        XCTAssertNil(appState.newChatAwaitingListing, "waits for Hermes, as the chat it replaces did")
    }

    /// A New Chat started in a folder is replaced in that folder, and its
    /// row stays listed beside the chat until Hermes lists it, as the lost
    /// one's did.
    func testALostEmptyNewChatInAFolderIsReplacedInThatFolder() async {
        var lost: Set<String> = []
        var folders: [String?] = []
        let appState = makeLostChatAppState(lost: { lost }, onCreateIn: { folders.append($0) }) { _, _ in }

        await appState.createNewSession(cwd: "/repo/app")
        XCTAssertEqual(appState.newChatAwaitingListing?.cwd, "/repo/app")
        lost = ["created-runtime-1", "created-stored-1"]
        await appState.refreshActiveSession()

        XCTAssertEqual(folders, ["/repo/app", "/repo/app"])
        XCTAssertEqual(appState.activeSessionId, "created-runtime-2")
        XCTAssertEqual(appState.newChatAwaitingListing?.cwd, "/repo/app")
        XCTAssertEqual(appState.newChatAwaitingListing?.ids, ["created-runtime-2", "created-stored-2"])
        XCTAssertEqual(appState.sessions.map(\.id), ["created-stored-2"])
        XCTAssertNil(appState.errorMessage)
    }

    func testTheFirstMessageIntoALostEmptyNewChatGoesIntoAFreshOne() async {
        var lost: Set<String> = []
        var prompts: [(String, String)] = []
        let appState = makeLostChatAppState(lost: { lost }) { prompts.append(($0, $1)) }

        await appState.createNewSession()
        lost = ["created-runtime-1", "created-stored-1"]
        let sent = await appState.sendMessage("hello")

        XCTAssertTrue(sent)
        XCTAssertEqual(prompts.map(\.0), ["created-runtime-2"])
        XCTAssertEqual(prompts.map(\.1), ["hello"])
        XCTAssertEqual(appState.activeSessionId, "created-runtime-2")
        XCTAssertEqual(appState.messages.filter { $0.role == .user }.map(\.content), ["hello"], "one bubble, in the new chat")
        XCTAssertNil(appState.errorMessage)
    }

    /// Queue is a first message too: it goes into the fresh chat, still as
    /// Queue.
    func testAQueuedFirstMessageIntoALostEmptyNewChatGoesIntoAFreshOne() async {
        var lost: Set<String> = []
        var queuedPrompts: [(String, String)] = []
        var prompts: [String] = []
        let appState = makeLostChatAppState(
            lost: { lost },
            onQueuedPrompt: { queuedPrompts.append(($0, $1)) }
        ) { session, _ in prompts.append(session) }

        await appState.createNewSession()
        lost = ["created-runtime-1", "created-stored-1"]
        let sent = await appState.sendMessage("later", queued: true)

        XCTAssertTrue(sent)
        XCTAssertEqual(queuedPrompts.map(\.0), ["created-runtime-2"])
        XCTAssertEqual(queuedPrompts.map(\.1), ["later"])
        XCTAssertEqual(prompts, [])
        XCTAssertEqual(appState.activeSessionId, "created-runtime-2")
        XCTAssertNil(appState.errorMessage)
    }

    /// What an action left waiting on the empty chat (a screenshot, a
    /// prompt for the composer, its focus) waits on the fresh chat instead.
    func testWhatWaitsOnALostEmptyNewChatWaitsOnTheFreshOne() async {
        var lost: Set<String> = []
        var prompts: [String] = []
        let appState = makeLostChatAppState(lost: { lost }) { session, _ in prompts.append(session) }
        let shot = Attachment(id: UUID().uuidString, name: "screen.png", uri: "file:///tmp/screen.png", mimeType: "image/png", kind: .image)

        await appState.createNewSession()
        appState.pendingScreenshots = [PendingScreenshot(sessionID: "created-runtime-1", attachment: shot, dashboardID: appState.activeDashboardID)]
        appState.prefillComposer("What is on my screen?")
        appState.requestComposerFocus(on: "created-runtime-1")
        appState.pendingComposerSend = PendingComposerSend(
            draftText: "typed while it reconnected",
            replyReference: nil,
            dashboardID: appState.activeDashboardID ?? UUID(),
            profile: "default",
            sessionIDs: ["created-runtime-1", "created-stored-1"],
            draftSessionID: "created-stored-1",
            isNewChat: false,
            title: ""
        )
        lost = ["created-runtime-1", "created-stored-1"]
        await appState.refreshActiveSession()

        XCTAssertEqual(appState.activeSessionId, "created-runtime-2")
        XCTAssertEqual(appState.pendingScreenshots.map(\.sessionID), ["created-runtime-2"])
        XCTAssertEqual(appState.pendingScreenshots.map(\.attachment), [shot])
        XCTAssertEqual(appState.composerPrefillDraftKey, ComposerBar.composerDraftKey(for: "created-runtime-2", profile: "default"))
        XCTAssertEqual(appState.composerPrefillText, "What is on my screen?")
        XCTAssertEqual(appState.composerFocusRequest?.sessionID, "created-runtime-2")
        // The waiting message is the fresh chat's: still waiting on it, or
        // already sent there, never into the lost one.
        XCTAssertFalse(prompts.contains("created-runtime-1"))
        if let pending = appState.pendingComposerSend {
            XCTAssertEqual(pending.draftSessionID, "created-stored-2")
            XCTAssertEqual(pending.sessionIDs, ["created-runtime-2", "created-stored-2"])
        } else {
            XCTAssertEqual(prompts, ["created-runtime-2"])
        }
    }

    func testAFirstMessageWithAFileIntoALostEmptyNewChatIsStagedInTheFreshOne() async {
        var lost: Set<String> = []
        var uploads: [String] = []
        var prompts: [(String, String)] = []
        let appState = makeLostChatAppState(lost: { lost }, onUpload: { uploads.append($0) }) { prompts.append(($0, $1)) }
        let notes = Attachment(id: UUID().uuidString, name: "notes.txt", uri: "file:///tmp/notes.txt", mimeType: "text/plain", kind: .document)

        await appState.createNewSession()
        lost = ["created-runtime-1", "created-stored-1"]
        let sent = await appState.sendMessage("read this", attachments: [notes])

        XCTAssertTrue(sent)
        XCTAssertEqual(uploads, ["created-runtime-2"], "staged once, in the fresh chat")
        XCTAssertEqual(prompts.map(\.0), ["created-runtime-2"])
        XCTAssertTrue(prompts.first?.1.contains("/uploads/notes.txt") == true)
        XCTAssertEqual(appState.messages.filter { $0.role == .user }.first?.attachments?.map(\.name), ["notes.txt"])
    }

    func testAnEmptyNewChatLeftAndReopenedIsNotReplaced() async {
        var lost: Set<String> = []
        var created = 0
        let appState = makeLostChatAppState(lost: { lost }, onCreate: { created += 1 }) { _, _ in }

        await appState.createNewSession()
        appState.activeSessionId = "other-chat"
        appState.activeSessionId = "created-runtime-1"
        lost = ["created-runtime-1", "created-stored-1"]
        await appState.refreshActiveSession()

        XCTAssertEqual(created, 1, "only the chat New Chat made, still open since")
        XCTAssertNotNil(appState.errorMessage)
    }

    func testAFailedFreshChatKeepsTheFirstMessagesWords() async {
        var lost: Set<String> = []
        var createFails = false
        var created = 0
        var attempts = 0
        let appState = makeLostChatAppState(
            lost: { lost },
            onCreate: { created += 1 },
            onCreateAttempt: { attempts += 1 },
            createFails: { createFails }
        ) { _, _ in }

        await appState.createNewSession()
        lost = ["created-runtime-1", "created-stored-1"]
        createFails = true
        let sent = await appState.sendMessage("hello")

        XCTAssertFalse(sent)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(attempts, 2, "New Chat's create, then one try at a fresh chat, not one per retry")
        XCTAssertTrue(appState.messages.contains { $0.role == .user && $0.content == "hello" }, "the words stay, as for any failed send")
        XCTAssertNotNil(appState.errorMessage)
    }

    /// A slash command's answer (/btw's among them) is the user's, and
    /// Hermes keeps no copy: the chat isn't empty, so it stays with its
    /// error.
    func testANewChatWithASlashAnswerIsNotReplaced() async {
        var lost: Set<String> = []
        var created = 0
        let appState = makeLostChatAppState(lost: { lost }, onCreate: { created += 1 }) { _, _ in }

        await appState.createNewSession()
        appState.messages.append(ChatMessage(id: "slash-answer", role: .system, content: "The answer", timestamp: "2026-11-04T11:00:00Z"))
        lost = ["created-runtime-1", "created-stored-1"]
        await appState.refreshActiveSession()

        XCTAssertEqual(created, 1)
        XCTAssertEqual(appState.activeSessionId, "created-runtime-1")
        XCTAssertTrue(appState.messages.contains { $0.id == "slash-answer" })
    }

    func testANewChatWithMessagesIsNeverReplaced() async {
        var lost: Set<String> = []
        var created = 0
        let appState = makeLostChatAppState(lost: { lost }, onCreate: { created += 1 }) { _, _ in }

        await appState.createNewSession()
        let sent = await appState.sendMessage("hello")
        XCTAssertTrue(sent)
        lost = ["created-runtime-1", "created-stored-1"]
        await appState.refreshActiveSession()

        XCTAssertEqual(created, 1, "a chat with something in it is the user's: its error shows")
        XCTAssertEqual(appState.activeSessionId, "created-runtime-1")
        XCTAssertNotNil(appState.errorMessage)
    }

    func testANewChatBelongsToTheProjectItStartedIn() {
        let awaiting = NewChatAwaitingListing(ids: ["rt", "st"], profile: "default", cwd: "/repo/app/")
        let project = ProjectSummary(id: "p", title: "App", primaryPath: "/repo/app", isHome: false, sessionCount: 0, previewSessions: [])
        let other = ProjectSummary(id: "q", title: "Web", primaryPath: "/repo/web", isHome: false, sessionCount: 0, previewSessions: [])
        let home = ProjectSummary(id: "home", title: "Home", primaryPath: nil, isHome: true, sessionCount: 0, previewSessions: [])
        XCTAssertTrue(awaiting.isIn(project))
        XCTAssertFalse(awaiting.isIn(other))
        XCTAssertFalse(awaiting.isIn(home))
        let plain = NewChatAwaitingListing(ids: ["rt"], profile: "default", cwd: nil)
        XCTAssertTrue(plain.isIn(home), "a plain chat lands in Home")
        XCTAssertFalse(plain.isIn(project))
        XCTAssertTrue(awaiting.matches(makeSession(id: "st", alternateIDs: [])))
        XCTAssertTrue(awaiting.matches(makeSession(id: "lineage-tip", alternateIDs: ["rt"])))
        XCTAssertFalse(awaiting.matches(makeSession(id: "other", alternateIDs: [])))
    }

    func testANewChatGoesOnTopOfItsFoldersLaneOnAProjectPage() {
        let created = makeSession(id: "st", alternateIDs: ["rt"], title: "New conversation")
        let older = makeSession(id: "older", alternateIDs: [], title: "Older")
        let worktree = ProjectSessionLane(id: "wt", title: "voice-v2", sessions: [older], path: "/repo/app/.worktrees/voice-v2")
        let root = ProjectSessionLane(id: "root", title: "app", sessions: [older], path: "/repo/app")
        let awaiting = NewChatAwaitingListing(ids: ["rt", "st"], profile: "default", cwd: "/repo/app")

        let placed = awaiting.lanes([worktree, root], with: created, newLaneID: "p-new")
        XCTAssertEqual(placed.map(\.id), ["wt", "root"])
        XCTAssertEqual(placed[0].sessions.map(\.id), ["older"], "never under a worktree's lane")
        XCTAssertEqual(placed[1].sessions.map(\.id), ["st", "older"])

        // A lane Hermes names by its folder alone (no separate path).
        let labelled = ProjectSessionLane(id: "label", title: "/repo/app/", sessions: [older])
        XCTAssertEqual(awaiting.lanes([labelled], with: created, newLaneID: "p-new")[0].sessions.map(\.id), ["st", "older"])

        // No lane is its folder: a Recent lane on top.
        let recent = awaiting.lanes([worktree], with: created, newLaneID: "p-new")
        XCTAssertEqual(recent.map(\.id), ["p-new", "wt"])
        XCTAssertEqual(recent[0].sessions.map(\.id), ["st"])

        // A plain chat on Home's page.
        let plain = NewChatAwaitingListing(ids: ["rt", "st"], profile: "default", cwd: nil)
        XCTAssertEqual(plain.lanes([root], with: created, newLaneID: "home-new").map(\.id), ["home-new", "root"])

        // Listed by Hermes, by any of its ids: shown once.
        let listed = ProjectSessionLane(id: "root", title: "app", sessions: [makeSession(id: "lineage", alternateIDs: ["st"])], path: "/repo/app")
        XCTAssertEqual(awaiting.lanes([listed], with: created, newLaneID: "p-new"), [listed])
    }

    private func makeConnectedAppState(
        catalog: @escaping @MainActor () -> [SessionSummary] = { [] },
        onPrompt: @escaping @MainActor (String, String) -> Void
    ) -> AppState {
        let defaults = makeScratchDefaults("ArchiveThenSendTests")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in catalog() },
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

    /// Each create makes `created-runtime-N`/`created-stored-N`; a resume or
    /// a send to an id in `lost` answers as Hermes does for a dropped,
    /// never-saved chat.
    private func makeLostChatAppState(
        lost: @escaping @MainActor () -> Set<String>,
        onCreate: @escaping @MainActor () -> Void = {},
        onCreateIn: @escaping @MainActor (String?) -> Void = { _ in },
        onCreateAttempt: @escaping @MainActor () -> Void = {},
        createFails: @escaping @MainActor () -> Bool = { false },
        onUpload: @escaping @MainActor (String) -> Void = { _ in },
        onQueuedPrompt: @escaping @MainActor (String, String) -> Void = { _, _ in },
        onPrompt: @escaping @MainActor (String, String) -> Void
    ) -> AppState {
        let defaults = makeScratchDefaults("LostEmptyNewChatTests")
        var operations = ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSession: { _, sessionID, _ in
                    if lost().contains(sessionID) { throw RpcError(code: 4007, message: "session not found") }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, sessionID, text in
                    if lost().contains(sessionID) { throw RpcError(code: 4001, message: "session not found") }
                    onPrompt(sessionID, text)
                    return .accepted
                }
            )
        operations.sendQueuedPrompt = { _, sessionID, text in
            if lost().contains(sessionID) { throw RpcError(code: 4001, message: "session not found") }
            onQueuedPrompt(sessionID, text)
            return .accepted
        }
        operations.uploadAttachment = { _, sessionID, attachment in
            if lost().contains(sessionID) { throw RpcError(code: 4001, message: "session not found") }
            onUpload(sessionID)
            return "/uploads/\(attachment.name)"
        }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        var count = 0
        appState.widgetSessionCreatorOverride = { _, cwd in
            onCreateAttempt()
            if createFails() { throw URLError(.notConnectedToInternet) }
            count += 1
            onCreate()
            onCreateIn(cwd)
            return ("created-runtime-\(count)", "created-stored-\(count)", "default")
        }
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
