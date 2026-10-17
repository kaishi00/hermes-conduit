import XCTest
@testable import Conduit

/// Read-only offline chat copy (#99): what is stored, how it is protected,
/// when it is shown, when it is replaced, and that it never becomes evidence
/// for any live decision.
@MainActor
final class OfflineChatCacheTests: XCTestCase {
    // MARK: - Store

    func testRecordKeepsNewestPageOfDisplayRowsOnly() throws {
        let store = makeStore()
        let dashboard = UUID()
        var rows = (0..<130).map { index in
            ChatMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? .user : .assistant, content: "row \(index)", timestamp: "\(index)")
        }
        rows.append(ChatMessage(id: "approval", role: .approval, content: "Approve?", timestamp: "200"))
        rows.append(ChatMessage(id: "clarify", role: .clarify, content: "Which?", timestamp: "201"))
        rows.append(ChatMessage(id: "partial", role: .partial, content: "stream", timestamp: "202"))

        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "stored-a",
            title: "A",
            messages: rows,
            sessions: [session("stored-a"), session("cron-1", source: .cron)]
        )

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        let transcript = try XCTUnwrap(snapshot.transcript(for: "stored-a"))
        XCTAssertEqual(transcript.messages.count, OfflineChatCacheStore.maxMessagesPerTranscript)
        XCTAssertEqual(transcript.messages.first?.id, "m10")
        XCTAssertEqual(transcript.messages.last?.id, "m129")
        XCTAssertFalse(transcript.messages.contains { [.approval, .clarify, .partial].contains($0.role) },
                       "Interactive decision cards and streaming partials are never stored")
        XCTAssertEqual(snapshot.lastSessionID, "stored-a")
        XCTAssertEqual(snapshot.sessions.map(\.id), ["stored-a"], "Cron rows stay out of the saved session list")
    }

    /// A conversation outside the newest 60 catalog rows still gets a saved
    /// row: without it the copy would show its transcript with no sidebar row
    /// to highlight or reopen it from.
    func testRecordedConversationKeepsItsRowPastTheSessionCap() throws {
        let store = makeStore()
        let dashboard = UUID()
        let catalog = (0..<(OfflineChatCacheStore.maxSessions + 10)).map { session("s\($0)") }
        let old = "s\(OfflineChatCacheStore.maxSessions + 5)"

        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: old,
            title: "Old",
            messages: [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")],
            sessions: catalog
        )

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.sessions.count, OfflineChatCacheStore.maxSessions)
        XCTAssertEqual(snapshot.sessions.last?.id, old)
        XCTAssertEqual(snapshot.sessions.first?.id, "s0")
        XCTAssertNotNil(snapshot.transcript(for: old))
        XCTAssertTrue(snapshot.sessions.contains { $0.id == snapshot.lastSessionID })
    }

    /// CodeRabbit on #229: recording s65 then s0 must not drop s65's row —
    /// every retained transcript keeps its saved row.
    func testEveryRetainedTranscriptKeepsItsRowPastTheSessionCap() throws {
        let store = makeStore()
        let dashboard = UUID()
        let catalog = (0..<(OfflineChatCacheStore.maxSessions + 10)).map { session("s\($0)") }
        let row = [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")]

        for id in ["s65", "s62", "s0"] {
            store.record(dashboardID: dashboard, profile: "default", sessionID: id, title: id, messages: row, sessions: catalog)
        }

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.sessions.count, OfflineChatCacheStore.maxSessions)
        for transcript in snapshot.transcripts {
            XCTAssertTrue(snapshot.sessions.contains { $0.id == transcript.sessionID },
                          "\(transcript.sessionID) lost its saved row")
        }
        XCTAssertEqual(snapshot.transcripts.map(\.sessionID), ["s0", "s62", "s65"])
        // Catalog order is kept: the reserved rows sit after the newest ones.
        XCTAssertEqual(snapshot.sessions.first?.id, "s0")
        XCTAssertEqual(Array(snapshot.sessions.suffix(2).map(\.id)), ["s62", "s65"])
    }

    /// A retained transcript whose conversation the live catalog no longer
    /// lists (but the previous saved list did) keeps its saved row.
    func testRetainedTranscriptKeepsItsRowFromThePreviousSavedList() throws {
        let store = makeStore()
        let dashboard = UUID()
        let row = [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")]
        store.record(dashboardID: dashboard, profile: "default", sessionID: "gone", title: "Gone",
                     messages: row, sessions: [session("gone"), session("a")])

        store.record(dashboardID: dashboard, profile: "default", sessionID: "a", title: "A",
                     messages: row, sessions: [session("a"), session("b")])

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.transcripts.map(\.sessionID), ["a", "gone"])
        XCTAssertEqual(snapshot.sessions.map(\.id), ["a", "b", "gone"])
    }

    func testRecordedConversationPastTheCapIsResolvedFromItsAlias() throws {
        let store = makeStore()
        let dashboard = UUID()
        var catalog = (0..<(OfflineChatCacheStore.maxSessions + 2)).map { session("s\($0)") }
        catalog[OfflineChatCacheStore.maxSessions + 1] = {
            var row = session("runtime-late")
            row.storedSessionId = "stored-late"
            return row
        }()

        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: nil,
            identities: ["runtime-late"],
            title: "Late",
            messages: [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")],
            sessions: catalog
        )

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.lastSessionID, "stored-late")
        XCTAssertTrue(snapshot.sessions.contains { $0.id == "stored-late" })
    }

    func testRecentTranscriptsAreBoundedMostRecentFirst() throws {
        let store = makeStore()
        let dashboard = UUID()
        for index in 0..<(OfflineChatCacheStore.maxTranscripts + 2) {
            store.record(
                dashboardID: dashboard,
                profile: "default",
                sessionID: "s\(index)",
                title: "S\(index)",
                messages: [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")],
                sessions: []
            )
        }
        // Reopening an older one moves it to the front.
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "s3",
            title: "S3",
            messages: [ChatMessage(id: "m", role: .user, content: "again", timestamp: "2")],
            sessions: []
        )
        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.transcripts.map(\.sessionID), ["s3", "s6", "s5", "s4", "s2"])
    }

    func testScopesAreIsolatedAndDashboardRemovalOnlyWipesThatDashboard() {
        let store = makeStore()
        let first = UUID()
        let second = UUID()
        let row = [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")]
        store.record(dashboardID: first, profile: "default", sessionID: "a", title: "A", messages: row, sessions: [])
        store.record(dashboardID: first, profile: "work", sessionID: "w", title: "W", messages: row, sessions: [])
        store.record(dashboardID: second, profile: "default", sessionID: "b", title: "B", messages: row, sessions: [])

        XCTAssertEqual(store.load(dashboardID: first, profile: "work")?.lastSessionID, "w")
        XCTAssertNil(store.load(dashboardID: second, profile: "work"))

        store.removeDashboard(first)
        XCTAssertNil(store.load(dashboardID: first, profile: "default"))
        XCTAssertNil(store.load(dashboardID: first, profile: "work"))
        XCTAssertEqual(store.load(dashboardID: second, profile: "default")?.lastSessionID, "b")

        store.removeAll()
        XCTAssertNil(store.load(dashboardID: second, profile: "default"))
    }

    func testCacheFilesAreProtectedAndExcludedFromBackup() throws {
        let store = makeStore()
        let dashboard = UUID()
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "a",
            title: "A",
            messages: [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")],
            sessions: []
        )
        XCTAssertTrue(OfflineChatCacheStore.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        let file = store.fileURL(dashboardID: dashboard, profile: "default")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        // The Simulator does not implement Data Protection and reports no
        // class; on a device the written class must be at least as strong.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertTrue(
                [.complete, .completeUntilFirstUserAuthentication].contains(protection),
                "Offline chat files must be at least complete-until-first-auth protected, got \(protection)"
            )
        }
        let values = try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Presentation

    func testPresentingTheCopyNeverFeedsLiveStateOrTheViewport() throws {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        let revision = appState.chatTranscriptRevision
        let transition = appState.chatViewportTransitionGeneration
        let identity = appState.activeChatScrollSessionIdentity

        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        let presentation = try XCTUnwrap(appState.offlineChatPresentation)
        XCTAssertEqual(presentation.displayedSessionID, "stored-a")
        XCTAssertEqual(presentation.displayedMessages.map(\.id), ["u1", "a1"])
        XCTAssertEqual(appState.displayedChatTitle, "A")
        // Not evidence: nothing the live paths read changed.
        XCTAssertTrue(appState.messages.isEmpty)
        XCTAssertTrue(appState.sessions.isEmpty)
        XCTAssertNil(appState.activeSessionId)
        XCTAssertNil(appState.persistedTranscriptWindow)
        XCTAssertFalse(appState.canLoadEarlierMessagesForActiveConversation)
        // Viewport (#147/#193): no transcript revision, transition, or scroll
        // identity change — the live chat view sees a plain empty cold launch.
        XCTAssertEqual(appState.chatTranscriptRevision, revision)
        XCTAssertEqual(appState.chatViewportTransitionGeneration, transition)
        XCTAssertEqual(appState.activeChatScrollSessionIdentity, identity)
        // Read-only.
        XCTAssertFalse(appState.composerIsEnabled)
        XCTAssertEqual(appState.composerAction(hasText: true, hasAttachments: false), .unavailable)
    }

    /// A chat tapped in the saved list shows at once (its saved copy, or its
    /// title while it opens) and opens nothing until the live list lands.
    func testPickingASavedChatShowsItAtOnceWithoutOpeningIt() throws {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        seedChatList(store, dashboard: dashboard, sessions: [session("stored-a"), session("stored-b")])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        let rows = appState.listedSessions
        XCTAssertEqual(rows.map(\.id), ["stored-a", "stored-b"])

        appState.openListedSession(rows[1])
        var presentation = try XCTUnwrap(appState.offlineChatPresentation)
        XCTAssertEqual(presentation.picked?.title, "stored-b")
        XCTAssertNil(presentation.displayedSessionID, "No saved copy of that chat: its title shows while it opens")
        XCTAssertTrue(presentation.displayedMessages.isEmpty)
        XCTAssertEqual(appState.displayedChatTitle, "stored-b")

        appState.openListedSession(rows[0])
        presentation = try XCTUnwrap(appState.offlineChatPresentation)
        XCTAssertEqual(presentation.displayedMessages.map(\.id), ["u1", "a1"])
        XCTAssertEqual(appState.chatPickedFromSavedListIDForTesting, "stored-a", "The latest tap is the one that opens")
        // Nothing live moved.
        XCTAssertNil(appState.activeSessionId)
        XCTAssertTrue(appState.messages.isEmpty)
        XCTAssertTrue(appState.sessions.isEmpty)
    }

    func testAuthoritativeTranscriptReplacesTheCopyWholesale() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        let applied = appState.applyChatResume(
            SessionResumeResult(
                sessionId: "stored-a",
                messages: [ChatMessage(id: "server-1", role: .assistant, content: "Fresh", timestamp: "9")],
                snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
            )
        )

        XCTAssertTrue(applied)
        XCTAssertNil(appState.offlineChatPresentation)
        XCTAssertEqual(appState.messages.map(\.id), ["server-1"], "No cached row survives the server's answer")
    }

    func testEmptyAuthoritativeConversationAlsoReplacesTheCopy() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        _ = appState.applyChatResume(
            SessionResumeResult(
                sessionId: "stored-a",
                messages: [],
                snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
            )
        )

        XCTAssertNil(appState.offlineChatPresentation)
        XCTAssertTrue(appState.messages.isEmpty)
    }

    func testCopyIsNotShownOverALiveTranscript() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.messages = [ChatMessage(id: "live", role: .user, content: "Live", timestamp: "1")]

        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        XCTAssertNil(appState.offlineChatPresentation)
    }

    // MARK: - Sidebar

    /// With nothing saved and the list on its way, the Chats list says it's
    /// loading, not that there are no chats. A live list that came back
    /// empty is empty.
    func testChatsListSaysItIsLoadingWhileItsFirstListIsOnItsWay() async {
        XCTAssertEqual(
            SidebarOfflineLayout.visibility(showingProjects: false, displayedSessionsEmpty: true, isLoadingList: true),
            .init(liveSections: true, emptyState: false, loadingState: true)
        )
        XCTAssertEqual(
            SidebarOfflineLayout.visibility(showingProjects: false, displayedSessionsEmpty: true, isLoadingList: false),
            .init(liveSections: true, emptyState: true, loadingState: false)
        )
        XCTAssertEqual(
            SidebarOfflineLayout.visibility(showingProjects: false, displayedSessionsEmpty: false, isLoadingList: true),
            .init(liveSections: true, emptyState: false, loadingState: false)
        )
        XCTAssertEqual(
            SidebarOfflineLayout.visibility(showingProjects: true, displayedSessionsEmpty: true, isLoadingList: true),
            .init(liveSections: false, emptyState: false, loadingState: false)
        )

        let (appState, store, dashboard) = makeAppState(sessionCatalogLoader: { _ in [] })
        appState.isConnecting = true
        XCTAssertTrue(appState.isLoadingChatList)

        seedChatList(store, dashboard: dashboard, sessions: [session("stored-a")])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertFalse(appState.isLoadingChatList, "The saved rows stand in while it loads")

        await appState.loadSessions()
        XCTAssertFalse(appState.isLoadingChatList)
        XCTAssertTrue(appState.listedSessions.isEmpty)
    }

    /// A saved row's time is worked out again at launch from its instant,
    /// the way the live list formats it, so yesterday's row doesn't still
    /// show only a time. A row without a plausible instant keeps its saved
    /// label.
    func testSavedRowTimesAreWorkedOutAgainFromTheirInstants() {
        var dated = session("dated")
        dated.updatedLabel = "9:41 AM"
        dated.lastActivityAt = 1_790_000_000
        var undated = session("undated")
        undated.updatedLabel = "saved label"
        var zero = session("zero")
        zero.updatedLabel = "zero label"
        zero.lastActivityAt = 0
        var future = session("future")
        future.updatedLabel = "future label"
        future.lastActivityAt = 1_790_000_000 + 7 * 86_400
        var run = session("run", source: .cron)
        run.lastActivityAt = 1_790_000_000

        let list = SavedChatList.capture(
            sessions: [dated, undated, zero, future],
            cronSessions: [run],
            isPinned: { _ in false },
            voiceTags: [:],
            projects: [],
            supportsProjects: false
        ).relabeled(now: Date(timeIntervalSince1970: 1_790_000_000))

        let expected = MessageNormalizer.formattedSessionTimestamp(1_790_000_000)
        XCTAssertEqual(list.sessions.map(\.updatedLabel), [expected, "saved label", "zero label", "future label"])
        XCTAssertEqual(list.cronSessions.map(\.updatedLabel), [expected])
    }

    // MARK: - Unreachable server vs. sign-in

    func testUnreachableRestoreKeepsTheCopyInsteadOfSignIn() {
        for failure: ConnectionFailure in [.offline, .hostNotFound, .unreachable, .connectionRefused, .timedOut, .dashboardUnavailable] {
            let (appState, store, dashboard) = makeAppState()
            seedCopy(store, dashboard: dashboard)
            appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
            appState.showLogin = false

            XCTAssertTrue(appState.presentCredentialRestoreFailure(failure, switchGeneration: nil))

            XCTAssertFalse(appState.showLogin, "\(failure)")
            XCTAssertNotNil(appState.offlineChatPresentation, "\(failure)")
            XCTAssertEqual(appState.lastConnectionFailure, failure)
            XCTAssertFalse(appState.isConnecting)
            // Matches the saved-ticket path: recovery pending, never left
            // .synchronizing by the native-OAuth cold-launch restore.
            XCTAssertEqual(appState.turnState, .reconnecting, "\(failure)")
        }
    }

    func testAuthenticationFailureStillGoesToSignIn() {
        for failure: ConnectionFailure in [.authenticationRejected, .loginRequired, .rateLimited, .tlsUntrusted] {
            let (appState, store, dashboard) = makeAppState()
            seedCopy(store, dashboard: dashboard)
            appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
            appState.showLogin = false

            _ = appState.presentCredentialRestoreFailure(failure, switchGeneration: nil)

            XCTAssertTrue(appState.showLogin, "\(failure)")
            XCTAssertNil(
                appState.offlineChatPresentation,
                "An auth failure must not keep the copy in memory for the next sign-in (\(failure))"
            )
        }
    }

    func testSignInFromTheCopyLeavesNoCopyInMemory() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        appState.showLogin = false

        appState.signInFromOfflineChat()

        XCTAssertTrue(appState.showLogin)
        XCTAssertNil(appState.offlineChatPresentation)
        XCTAssertNotNil(store.load(dashboardID: dashboard, profile: "default"), "Files stay until a wipe boundary")
    }

    func testReadAloudIsInertOverTheCopy() throws {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        let row = try XCTUnwrap(appState.offlineChatPresentation?.displayedMessages.last)

        appState.toggleReadAloud(message: row)

        XCTAssertNil(appState.errorMessage, "Read aloud must not surface a gateway error over the saved copy")
        XCTAssertFalse(appState.messageReadAloudController.isActiveMessage(row.id))
    }

    /// Re-selecting the same server with saved (non-Face ID) credentials
    /// mirrors cold launch: the copy shows, and an unreachable server keeps
    /// it instead of sending the user to sign-in.
    func testDashboardReselectWithSavedCredentialsKeepsTheCopyWhenUnreachable() async {
        let loopback = SavedDashboard(id: UUID(), label: "Local", normalizedURL: "http://127.0.0.1:1")
        let (appState, store, _) = makeAppState(
            registry: SavedDashboardRegistry(activeDashboardID: loopback.id, dashboards: [loopback])
        )
        seedCopy(store, dashboard: loopback.id)
        // The in-memory keychain every multi-dashboard suite uses: an
        // unsigned simulator test host (CODE_SIGNING_ALLOWED=NO, as in the
        // gate and hosted CI) can't write the system keychain, so the saved
        // credentials would silently not exist and the switch would take
        // the no-credentials branch instead. Restoring the system backend
        // discards the in-memory credentials, so no separate clear is needed.
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: loopback.normalizedURL, username: "hermes", password: "unused", requiresFaceID: false),
            dashboardID: loopback.id
        )

        await appState.switchDashboard(to: loopback.id)

        XCTAssertFalse(appState.showLogin)
        XCTAssertEqual(appState.offlineChatPresentation?.displayedSessionID, "stored-a")
        XCTAssertEqual(appState.turnState, .reconnecting)
    }

    /// Account boundary: A's saved conversations must never be presented to
    /// B on the same dashboard. A's credentials are rejected (files wiped),
    /// B signs in interactively (files wiped again before connect), and a
    /// later offline cold launch finds nothing of A's.
    func testAuthFailureThenOtherAccountSignInNeverPresentsTheFirstAccountsCopy() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard) // account A

        _ = appState.presentCredentialRestoreFailure(.authenticationRejected, switchGeneration: nil)
        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"),
                     "An authentication failure wipes the dashboard's saved files")

        seedCopy(store, dashboard: dashboard) // anything left behind by A
        appState.prepareInteractiveSignIn(baseURL: "https://one.example") // account B signs in

        let (relaunched, _, _) = makeAppState(sharing: store, dashboard: dashboard)
        relaunched.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertNil(relaunched.offlineChatPresentation, "B's offline cold launch must not show A's transcript")
    }

    func testUnreachableFailureKeepsTheSavedFiles() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)

        _ = appState.presentCredentialRestoreFailure(.offline, switchGeneration: nil)

        XCTAssertNotNil(store.load(dashboardID: dashboard, profile: "default"))
    }

    func testUnreachableRestoreWithoutACopyGoesToSignIn() {
        let (appState, _, _) = makeAppState()
        appState.showLogin = false

        _ = appState.presentCredentialRestoreFailure(.offline, switchGeneration: nil)

        XCTAssertTrue(appState.showLogin)
    }

    // MARK: - Recording

    func testRecordsOnlyConnectedAuthoritativeState() throws {
        let (appState, store, dashboard) = makeAppState()
        appState.sessions = [session("stored-a")]
        appState.activeSessionId = "stored-a"
        appState.messages = [ChatMessage(id: "live", role: .user, content: "Live", timestamp: "1")]

        appState.recordOfflineChatCopy()
        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"), "Disconnected state is never recorded")

        appState.isConnected = true
        appState.recordOfflineChatCopy()
        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.transcript(for: "stored-a")?.messages.map(\.id), ["live"])
    }

    /// Servers that report a runtime `session_id` distinct from the durable
    /// stored id: the transcript must be keyed like its saved session-list
    /// row, or the sidebar shows the displayed chat as "Not saved offline".
    func testTranscriptIsKeyedLikeItsSessionRowWhenRuntimeAndStoredIdsDiffer() throws {
        let (appState, store, dashboard) = makeAppState()
        var row = session("runtime-1")
        row.storedSessionId = "stored-1"
        appState.sessions = [row]
        appState.activeSessionId = "runtime-1"
        appState.messages = [ChatMessage(id: "live", role: .user, content: "Live", timestamp: "1")]
        appState.isConnected = true

        appState.recordOfflineChatCopy()

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.sessions.map(\.id), ["stored-1"])
        XCTAssertEqual(snapshot.lastSessionID, "stored-1")
        XCTAssertNotNil(snapshot.transcript(for: "stored-1"))
        XCTAssertNil(snapshot.transcript(for: "runtime-1"))

        // Cold launch: the displayed transcript and its sidebar row agree.
        let (relaunched, _, _) = makeAppState(sharing: store, dashboard: dashboard)
        relaunched.presentOfflineChatIfAvailable(dashboardID: dashboard)
        let presentation = try XCTUnwrap(relaunched.offlineChatPresentation)
        let displayed = try XCTUnwrap(presentation.displayedSessionID)
        XCTAssertTrue(presentation.snapshot.sessions.contains { $0.id == displayed })
    }

    /// Recording while the live catalog is empty (not loaded yet) resolves
    /// the key from the saved session list's aliases, drops the transcript
    /// stored under the conversation's other id, and keeps the sidebar row
    /// matching its transcript.
    func testRecordWithEmptyCatalogKeysTranscriptByTheSavedRow() throws {
        let (appState, store, dashboard) = makeAppState()
        var row = session("runtime-1")
        row.storedSessionId = "stored-1"
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "stored-1",
            title: "One",
            messages: [ChatMessage(id: "old", role: .user, content: "Old", timestamp: "1")],
            sessions: [row]
        )
        // A transcript an earlier build stored under the runtime id.
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "runtime-1",
            title: "One",
            messages: [ChatMessage(id: "orphan", role: .user, content: "Orphan", timestamp: "1")],
            sessions: []
        )

        appState.sessions = []
        appState.activeSessionId = "runtime-1"
        appState.messages = [ChatMessage(id: "new", role: .user, content: "New", timestamp: "2")]
        appState.isConnected = true
        appState.recordOfflineChatCopy()

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.sessions.map(\.id), ["stored-1"], "An empty catalog never erases the saved list")
        XCTAssertEqual(snapshot.transcript(for: "stored-1")?.messages.map(\.id), ["new"])
        XCTAssertNil(snapshot.transcript(for: "runtime-1"), "The differently keyed transcript is dropped")
        XCTAssertEqual(snapshot.lastSessionID, "stored-1")
        XCTAssertTrue(snapshot.sessions.contains { snapshot.transcript(for: $0.id) != nil })
    }

    func testRecordWithNoResolvableDurableIdWritesNothing() {
        let (appState, store, dashboard) = makeAppState()
        appState.sessions = []
        appState.activeSessionId = "runtime-unknown"
        appState.messages = [ChatMessage(id: "live", role: .user, content: "Live", timestamp: "1")]
        appState.isConnected = true

        appState.recordOfflineChatCopy()

        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"))
    }

    func testProfileChangeDismissesTheCopy() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertNotNil(appState.offlineChatPresentation)

        appState.setActiveProfileForTesting("work")

        XCTAssertNil(appState.offlineChatPresentation, "A copy saved for one profile never shows under another")
    }

    func testBackgroundFlushRecordsTheOnScreenConversation() throws {
        let (appState, store, dashboard) = makeAppState()
        appState.connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.isConnected = true
        appState.sessions = [session("stored-a")]
        appState.activeSessionId = "stored-a"
        appState.messages = [ChatMessage(id: "live", role: .assistant, content: "Answer", timestamp: "1")]

        appState.handleScenePhase(.background)

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.lastSessionID, "stored-a")
    }

    // MARK: - Wipes

    func testSignOutWipesTheCopy() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        appState.disconnect()

        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertNil(appState.offlineChatPresentation)
    }

    func testRemovingAnInactiveDashboardWipesOnlyItsCopy() {
        let active = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let other = SavedDashboard(id: UUID(), label: "Two", normalizedURL: "https://two.example")
        let (appState, store, _) = makeAppState(
            registry: SavedDashboardRegistry(activeDashboardID: active.id, dashboards: [active, other])
        )
        seedCopy(store, dashboard: active.id)
        seedCopy(store, dashboard: other.id)

        appState.removeDashboard(other.id)

        XCTAssertNil(store.load(dashboardID: other.id, profile: "default"))
        XCTAssertNotNil(store.load(dashboardID: active.id, profile: "default"))
    }

    /// A switch to another dashboard saves the outgoing one's Chats list as
    /// it shows and keeps its saved chats for the next visit there, and lists
    /// the target's own while it answers.
    func testDashboardSwitchKeepsEachDashboardsSavedChats() async {
        useInMemoryKeychain()
        let one = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let loopback = SavedDashboard(id: UUID(), label: "Local", normalizedURL: "http://127.0.0.1:1")
        let live = [session("live-a"), session("live-b")]
        let (appState, store, _) = makeAppState(
            registry: SavedDashboardRegistry(activeDashboardID: one.id, dashboards: [one, loopback]),
            sessionCatalogLoader: { _ in live }
        )
        seedCopy(store, dashboard: one.id)
        seedCopy(store, dashboard: loopback.id)
        seedChatList(store, dashboard: loopback.id, sessions: [session("local-a")])
        // The closed port fails the restore as unreachable, which keeps
        // the target's saved chats up instead of sending it to sign-in.
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: loopback.normalizedURL, username: "hermes", password: "unused", requiresFaceID: false),
            dashboardID: loopback.id
        )
        appState.prepareChatResumeForConnection(to: one.normalizedURL, dashboardID: one.id)
        XCTAssertFalse(appState.prepareChatResumeForConnection(to: one.normalizedURL, dashboardID: one.id),
                       "Re-establishing the same server is not a switch")
        appState.connection = HermesConnection(baseUrl: one.normalizedURL, ticket: "ticket")
        appState.showLogin = false
        await appState.loadSessions()

        await appState.switchDashboard(to: loopback.id)

        XCTAssertEqual(appState.offlineChatPresentation?.dashboardID, loopback.id)
        XCTAssertTrue(appState.isShowingSavedChatList)
        XCTAssertEqual(appState.listedSessions.map(\.id), ["local-a"])
        XCTAssertNotNil(store.load(dashboardID: one.id, profile: "default"), "The outgoing dashboard's copy stays")
        XCTAssertEqual(store.loadChatList(dashboardID: one.id, profile: "default")?.sessions.map(\.id), ["live-a", "live-b"],
                       "The outgoing dashboard's list was saved as it showed")
    }

    /// Settings' Delete Saved Chats wipes every dashboard's saved chats and
    /// what of them shows. The list is saved again only from one Hermes
    /// sends after it.
    func testDeleteSavedChatsWipesEveryDashboardsSavedChats() async throws {
        let other = UUID()
        let live = [session("live-a")]
        let (appState, store, dashboard) = makeAppState(sessionCatalogLoader: { _ in live })
        seedCopy(store, dashboard: dashboard)
        seedChatList(store, dashboard: dashboard, sessions: [session("stored-a")])
        seedCopy(store, dashboard: other)
        seedChatList(store, dashboard: other, sessions: [session("other-a")])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertNotNil(appState.offlineChatPresentation)
        XCTAssertTrue(appState.isShowingSavedChatList)

        appState.deleteSavedChats()

        let copy = try XCTUnwrap(appState.offlineChatPresentation, "Before the sign-in goes through, the copy keeps the app up")
        XCTAssertNil(copy.displayedTranscript, "with nothing saved left in it")
        XCTAssertNil(appState.savedChatList)
        XCTAssertTrue(appState.listedSessions.isEmpty)
        for id in [dashboard, other] {
            XCTAssertNil(store.load(dashboardID: id, profile: "default"))
            XCTAssertNil(store.loadChatList(dashboardID: id, profile: "default"))
        }

        appState.connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.showLogin = false
        await appState.loadSessions()
        appState.deleteSavedChats()
        appState.recordSavedChatList()
        XCTAssertNil(store.loadChatList(dashboardID: dashboard, profile: "default"),
                     "The list already in memory isn't saved straight back")
        XCTAssertEqual(appState.listedSessions.map(\.id), ["live-a"], "The live list stays")

        await appState.loadSessions()
        appState.recordSavedChatList()
        let saved = try XCTUnwrap(store.loadChatList(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(saved.sessions.map(\.id), ["live-a"])
    }

    /// Delete Saved Chats while the server can't be reached keeps the app
    /// and its Retry up instead of falling back to the sign-in screen, with
    /// nothing saved left on screen.
    func testDeleteSavedChatsBeforeSignInKeepsTheAppUp() throws {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        appState.showLogin = false
        XCTAssertTrue(appState.presentCredentialRestoreFailure(.unreachable, switchGeneration: nil))
        XCTAssertNil(appState.connection)

        appState.deleteSavedChats()

        XCTAssertFalse(appState.showLogin)
        let copy = try XCTUnwrap(appState.offlineChatPresentation)
        XCTAssertNil(copy.displayedTranscript)
        XCTAssertTrue(copy.displayedMessages.isEmpty)
        XCTAssertEqual(appState.lastConnectionFailure, .unreachable)
        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"))
    }

    /// A dashboard switch starts the phone's pins over until Hermes' arrive
    /// with its list. The saved rows keep the pins they showed until then,
    /// and only until then.
    func testSavedRowsKeepTheirPinsUntilTheLiveListLands() async {
        let live = [session("pinned"), session("plain")]
        let (appState, store, dashboard) = makeAppState(sessionCatalogLoader: { _ in live })
        store.recordChatList(
            SavedChatList.capture(
                sessions: live,
                cronSessions: [],
                isPinned: { $0.id == "pinned" },
                voiceTags: [:],
                projects: [],
                supportsProjects: false
            ),
            dashboardID: dashboard,
            profile: "default"
        )
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        XCTAssertTrue(appState.isSessionPinned(session("pinned")))
        XCTAssertFalse(appState.isSessionPinned(session("plain")))

        await appState.loadSessions()

        XCTAssertFalse(appState.isSessionPinned(session("pinned")), "The live list's pins decide once it lands")
    }

    // MARK: - Saved Chats list

    func testSavedChatListKeepsTheNewestRowsAndEveryPinnedOne() {
        let chats = (0..<(SavedChatList.maxSessions + 5)).map { session("s\($0)") }
        var archived = session("archived")
        archived.isArchived = true
        let runs = (0..<(SavedChatList.maxCronSessions + 3)).map { session("cron-\($0)", source: .cron) }
        let oldPinned = "s\(SavedChatList.maxSessions + 3)"
        let oldPinnedRun = "cron-\(SavedChatList.maxCronSessions + 1)"
        let project = ProjectSummary(
            id: "project",
            title: "Project",
            isHome: false,
            sessionCount: 1,
            previewSessions: [session("s1")]
        )

        let list = SavedChatList.capture(
            sessions: [archived] + chats,
            cronSessions: runs,
            isPinned: { [oldPinned, oldPinnedRun].contains($0.id) },
            voiceTags: [
                "s0": VoiceSessionTag(kind: .call, engine: "gemini-live"),
                oldPinned: VoiceSessionTag(kind: .job, parentID: "s0", parentTitle: "s0"),
                "s\(SavedChatList.maxSessions + 4)": VoiceSessionTag(kind: .classic),
            ],
            projects: [project],
            supportsProjects: true
        )

        XCTAssertEqual(list.sessions.count, SavedChatList.maxSessions + 1)
        XCTAssertEqual(list.sessions.first?.id, "s0")
        XCTAssertEqual(list.sessions.last?.id, oldPinned, "A pinned chat past the newest rows is kept")
        XCTAssertFalse(list.sessions.contains { $0.id == "archived" })
        XCTAssertEqual(list.cronSessions.count, SavedChatList.maxCronSessions + 1)
        XCTAssertEqual(list.cronSessions.last?.id, oldPinnedRun)
        XCTAssertEqual(Set(list.voiceTags.keys), ["s0", oldPinned], "Only the saved rows' tags are kept")
        XCTAssertEqual(list.projects, [project])
        XCTAssertTrue(list.supportsProjects)
    }

    func testSavedChatListIsKeptPerScopeBesideTheTranscriptsAndWipedWithThem() throws {
        let store = makeStore()
        let first = UUID()
        let second = UUID()
        var row = session("a")
        row.storedSessionId = "stored-a"
        row.preview = "First message"
        row.isUnread = true
        row.lastActivityAt = 1_790_000_000
        let list = SavedChatList.capture(
            sessions: [row],
            cronSessions: [session("cron-1", source: .cron)],
            isPinned: { _ in false },
            voiceTags: ["a": VoiceSessionTag(kind: .call, engine: "gpt-live")],
            projects: [],
            supportsProjects: false,
            now: Date(timeIntervalSince1970: 1_790_000_000)
        )
        store.recordChatList(list, dashboardID: first, profile: "default")
        store.recordChatList(list, dashboardID: second, profile: "work")

        XCTAssertEqual(store.loadChatList(dashboardID: first, profile: "default"), list)
        XCTAssertNil(store.loadChatList(dashboardID: first, profile: "work"))
        XCTAssertNil(store.load(dashboardID: first, profile: "default"), "The list is not a saved transcript")
        let file = store.chatListFileURL(dashboardID: first, profile: "default")
        XCTAssertEqual(file.deletingLastPathComponent(), store.fileURL(dashboardID: first, profile: "default").deletingLastPathComponent())

        // Another build's format is not read.
        var other = list
        other.version = SavedChatList.formatVersion + 1
        store.recordChatList(other, dashboardID: first, profile: "default")
        XCTAssertNil(store.loadChatList(dashboardID: first, profile: "default"))

        store.recordChatList(list, dashboardID: first, profile: "default")
        store.removeDashboard(first)
        XCTAssertNil(store.loadChatList(dashboardID: first, profile: "default"))
        XCTAssertEqual(store.loadChatList(dashboardID: second, profile: "work"), list)

        store.removeAll()
        XCTAssertNil(store.loadChatList(dashboardID: second, profile: "work"))
    }

    /// A launch lists last time's rows (with their voice icons and project
    /// pages) through the live list's own accessors, while nothing a resume,
    /// route or send reads changes.
    func testLaunchListsTheSavedRowsWithoutFeedingLiveState() throws {
        let (appState, store, dashboard) = makeAppState()
        var call = session("call")
        call.preview = "Call summary"
        let project = ProjectSummary(
            id: "project",
            title: "Project",
            isHome: false,
            sessionCount: 1,
            previewSessions: [session("in-project")]
        )
        seedChatList(
            store,
            dashboard: dashboard,
            sessions: [call, session("in-project"), session("plain")],
            cronSessions: [session("cron-1", source: .cron)],
            voiceTags: ["call": VoiceSessionTag(kind: .call, engine: "gemini-live")],
            projects: [project],
            supportsProjects: true
        )

        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        XCTAssertTrue(appState.isShowingSavedChatList)
        XCTAssertEqual(appState.listedSessions.map(\.id), ["call", "in-project", "plain"])
        XCTAssertEqual(appState.listedSessions.first?.preview, "Call summary")
        XCTAssertEqual(appState.listedCronSessions.map(\.id), ["cron-1"])
        XCTAssertEqual(appState.voiceSessionTag(for: call)?.tag.kind, .call)
        XCTAssertEqual(appState.projects, [project])
        XCTAssertTrue(appState.supportsProjects)
        XCTAssertEqual(appState.knownProjectID(for: session("in-project")), "project")
        // Not evidence.
        XCTAssertTrue(appState.sessions.isEmpty)
        XCTAssertTrue(appState.cronSessions.isEmpty)
        XCTAssertTrue(appState.activeProfileSessions.isEmpty)
        XCTAssertNil(appState.activeSessionId)
    }

    /// Project pages that came from the saved list leave with it, so the
    /// sign-in screen after an auth failure, or Delete Saved Chats, doesn't
    /// keep them for whoever signs in next.
    func testProjectsFromTheSavedListLeaveWithIt() {
        let (appState, store, dashboard) = makeAppState()
        let project = ProjectSummary(id: "project", title: "Project", isHome: false, sessionCount: 1, previewSessions: [])
        seedChatList(store, dashboard: dashboard, sessions: [session("stored-a")], projects: [project], supportsProjects: true)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertEqual(appState.projects, [project])

        appState.showLogin = true

        XCTAssertTrue(appState.projects.isEmpty)
        XCTAssertFalse(appState.supportsProjects)

        appState.showLogin = false
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertEqual(appState.projects, [project])
        appState.deleteSavedChats()
        XCTAssertTrue(appState.projects.isEmpty)
        XCTAssertFalse(appState.supportsProjects)
    }

    func testLiveListReplacesTheSavedRows() async {
        let live = [session("live-a"), session("stored-a")]
        let (appState, store, dashboard) = makeAppState(sessionCatalogLoader: { _ in live })
        seedChatList(store, dashboard: dashboard, sessions: [session("stored-a"), session("gone")])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        await appState.loadSessions()

        XCTAssertNil(appState.savedChatList)
        XCTAssertFalse(appState.isShowingSavedChatList)
        XCTAssertEqual(appState.listedSessions.map(\.id), ["live-a", "stored-a"])

        // The live list is in: a later presentation (another restore) keeps it.
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertNil(appState.savedChatList)
    }

    /// The live list's newest page alone keeps the saved pinned chats it
    /// lacks under it, so an older pinned chat doesn't blink out while the
    /// rest loads; a chat the live list gains is then listed once, as live.
    func testNewestPageKeepsTheSavedPinnedChatsItLacks() throws {
        var oldPinned = session("old-pinned")
        oldPinned.storedSessionId = "old-pinned-stored"
        let saved = SavedChatListPresentation(
            dashboardID: UUID(),
            profile: "default",
            list: SavedChatList.capture(
                sessions: [session("a"), session("b-pinned"), oldPinned, session("old")],
                cronSessions: [],
                isPinned: { _ in false },
                voiceTags: [:],
                projects: [],
                supportsProjects: false
            )
        )
        let pinned: Set<String> = ["b-pinned", "old-pinned"]
        let isPinned: (SessionSummary) -> Bool = { pinned.contains($0.id) }
        let newestPage = [session("new"), session("a"), session("b-pinned")]
        XCTAssertEqual(saved.listedRows(live: newestPage).map(\.id), ["a", "b-pinned", "old-pinned", "old"],
                       "The saved rows show until a live list lands")

        let kept = try XCTUnwrap(saved.keepingPinnedRows(missingFrom: newestPage, isPinned: isPinned))
        XCTAssertFalse(kept.isShowingSavedRows)
        XCTAssertEqual(kept.keptPinnedRows?.map(\.id), ["old-pinned"])
        XCTAssertEqual(kept.listedRows(live: newestPage).map(\.id), ["new", "a", "b-pinned", "old-pinned"])
        XCTAssertEqual(
            kept.listedRows(live: newestPage + [session("old-pinned-stored")]).map(\.id),
            ["new", "a", "b-pinned", "old-pinned-stored"],
            "A kept chat the live list gained under another of its ids is listed once"
        )
        XCTAssertNil(saved.keepingPinnedRows(missingFrom: newestPage + [oldPinned], isPinned: isPinned),
                     "A page with every pinned chat keeps nothing")
    }

    /// After a dashboard switch the phone's pins start over from the newest
    /// page's alone: the saved list's own pins still keep its older pinned
    /// chats, which then count as kept rows.
    func testSavedListsOwnPinsKeepItsOlderPinnedChats() throws {
        let saved = SavedChatListPresentation(
            dashboardID: UUID(),
            profile: "default",
            list: SavedChatList.capture(
                sessions: [session("a"), session("old-pinned"), session("old")],
                cronSessions: [],
                isPinned: { $0.id == "old-pinned" },
                voiceTags: [:],
                projects: [],
                supportsProjects: false
            )
        )
        XCTAssertTrue(saved.showedAsPinned(session("old-pinned")))
        XCTAssertFalse(saved.showedAsPinned(session("a")))
        XCTAssertFalse(saved.isKeptRow(session("old-pinned")), "Nothing is kept while the saved rows show")

        let newestPage = [session("new"), session("a")]
        let kept = try XCTUnwrap(saved.keepingPinnedRows(missingFrom: newestPage, isPinned: saved.showedAsPinned))
        XCTAssertEqual(kept.keptPinnedRows?.map(\.id), ["old-pinned"])
        XCTAssertTrue(kept.isKeptRow(session("old-pinned")))
        XCTAssertFalse(kept.isKeptRow(session("a")))
        XCTAssertFalse(kept.isKeptRow(session("new")))
    }

    /// A chat tapped in the saved list before the live one lands opens once
    /// it does, instead of the chat the automatic resume would have picked.
    func testAChatPickedInTheSavedListOpensAheadOfTheAutomaticResume() async throws {
        useInMemoryKeychain()
        let live = [session("stored-a"), session("stored-b")]
        let opened = OpenedChats()
        let (appState, store, dashboard) = makeAppState(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSessionID("stored-a", for: "default")
            },
            lifecycleOperations: connectedLifecycle(catalog: { _ in live }, opened: opened)
        )
        addTeardownBlock { appState.client?.disconnect() }
        seedCopy(store, dashboard: dashboard)
        seedChatList(store, dashboard: dashboard, sessions: live)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        appState.openListedSession(appState.listedSessions[1])

        await appState.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"))
        XCTAssertFalse(opened.ids.contains("stored-a"), "The automatic resume gave way to the pick")

        await waitUntil { opened.ids.contains("stored-b") && appState.offlineChatPresentation == nil }
        XCTAssertEqual(Set(opened.ids), ["stored-b"])
        XCTAssertEqual(appState.activeSessionId, "stored-b")
        XCTAssertEqual(appState.messages.map(\.id), ["live-stored-b"])
        XCTAssertNil(appState.savedChatList)
        XCTAssertEqual(appState.listedSessions.map(\.id), ["stored-a", "stored-b"])
    }

    /// A picked chat whose open fails takes its read-only stand-in down with
    /// it, rather than leaving it up with nothing on its way.
    func testAPickedChatsStandInGoesWhenItsOpenFails() async throws {
        useInMemoryKeychain()
        // Hermes lists the picked chat under another profile.
        let live = [session("live-a"), session("elsewhere", profile: "work")]
        let opened = OpenedChats()
        let (appState, store, dashboard) = makeAppState(
            lifecycleOperations: connectedLifecycle(catalog: { _ in live }, opened: opened)
        )
        addTeardownBlock { appState.client?.disconnect() }
        seedChatList(store, dashboard: dashboard, sessions: [session("live-a"), session("elsewhere")])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        appState.openListedSession(appState.listedSessions[1])
        XCTAssertEqual(appState.offlineChatPresentation?.isPickedChat, true)

        await appState.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"))

        await waitUntil { appState.offlineChatPresentation == nil }
        XCTAssertFalse(opened.ids.contains("elsewhere"))
    }

    /// A profile switch lists the target profile's rows as they showed last
    /// time until its own list lands, and saves the outgoing profile's.
    func testProfileSwitchListsTheTargetsSavedRowsUntilItsOwnListLands() async throws {
        useInMemoryKeychain()
        let gate = ControlledSuspension()
        let defaultLive = [session("default-a"), session("default-b")]
        let workLive = [session("work-live", profile: "work")]
        let opened = OpenedChats()
        let (appState, store, dashboard) = makeAppState(
            sessionCatalogLoader: { _ in defaultLive },
            lifecycleOperations: connectedLifecycle(
                catalog: { profile in
                    guard profile == "work" else { return defaultLive }
                    await gate.suspend()
                    return workLive
                },
                opened: opened
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.showLogin = false
        addTeardownBlock { appState.client?.disconnect() }
        await appState.loadSessions()
        seedChatList(store, dashboard: dashboard, profile: "work", sessions: [session("work-saved", profile: "work")])

        let switching = Task { @MainActor in await appState.switchProfile(to: "work") }
        await gate.waitUntilSuspended()

        XCTAssertEqual(appState.activeProfile, "work")
        XCTAssertTrue(appState.isShowingSavedChatList)
        XCTAssertEqual(appState.listedSessions.map(\.id), ["work-saved"])
        XCTAssertFalse(appState.isLoadingChatList)
        let outgoing = try XCTUnwrap(store.loadChatList(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(outgoing.sessions.map(\.id), ["default-a", "default-b"], "The outgoing profile's list was saved")

        gate.resume()
        await switching.value

        XCTAssertNil(appState.savedChatList)
        XCTAssertEqual(appState.listedSessions.map(\.id), ["work-live"])
    }

    /// Only a list Hermes sent since the saved files were last wiped is
    /// saved, and never from the sign-in screen: one still in memory may be
    /// another account's.
    func testSavedListIsRecordedOnlyFromALiveListWhileSignedIn() async throws {
        let live = [session("live-a"), session("live-b")]
        let (appState, store, dashboard) = makeAppState(sessionCatalogLoader: { _ in live })
        appState.connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.showLogin = false
        appState.sessions = live

        appState.recordSavedChatList()
        XCTAssertNil(store.loadChatList(dashboardID: dashboard, profile: "default"),
                     "Rows Hermes didn't send in this process are never saved")

        await appState.loadSessions()
        appState.showLogin = true
        appState.recordSavedChatList()
        XCTAssertNil(store.loadChatList(dashboardID: dashboard, profile: "default"), "Never saved from sign-in")

        appState.showLogin = false
        appState.handleScenePhase(.background)
        let saved = try XCTUnwrap(store.loadChatList(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(saved.sessions.map(\.id), ["live-a", "live-b"])

        // A wipe (a sign-in, an auth failure) forgets that the list may be saved.
        appState.prepareInteractiveSignIn(baseURL: "https://one.example")
        appState.recordSavedChatList()
        XCTAssertNil(store.loadChatList(dashboardID: dashboard, profile: "default"))
    }

    func testDeletingAChatTakesItOutOfTheSavedList() {
        let (appState, store, dashboard) = makeAppState()
        seedChatList(store, dashboard: dashboard, sessions: [session("keep"), session("delete")])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        appState.removeSessionFromLiveCatalog(session("delete"))

        XCTAssertEqual(appState.listedSessions.map(\.id), ["keep"])
    }

    func testSavedListLeavesWithItsScope() {
        let (appState, store, dashboard) = makeAppState()
        seedChatList(store, dashboard: dashboard, sessions: [session("stored-a")])
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertTrue(appState.isShowingSavedChatList)

        appState.setActiveProfileForTesting("work")
        XCTAssertNil(appState.savedChatList, "A list saved for one profile never shows under another")
        XCTAssertTrue(appState.listedSessions.isEmpty)

        appState.setActiveProfileForTesting("default")
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertTrue(appState.isShowingSavedChatList)
        appState.disconnect()
        XCTAssertNil(appState.savedChatList)
        XCTAssertNil(store.loadChatList(dashboardID: dashboard, profile: "default"), "Sign-out wipes the saved list")
    }

    // MARK: - Helpers

    private func makeStore() -> OfflineChatCacheStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineChatCacheTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return OfflineChatCacheStore(directory: directory)
    }

    private func makeAppState(sharing store: OfflineChatCacheStore, dashboard: UUID) -> (AppState, OfflineChatCacheStore, UUID) {
        let saved = SavedDashboard(id: dashboard, label: "One", normalizedURL: "https://one.example")
        return makeAppState(
            registry: SavedDashboardRegistry(activeDashboardID: dashboard, dashboards: [saved]),
            store: store
        )
    }

    private func makeAppState(
        registry: SavedDashboardRegistry? = nil,
        store existingStore: OfflineChatCacheStore? = nil,
        configureDefaults: (UserDefaults) -> Void = { _ in },
        sessionCatalogLoader: ((Bool) async throws -> [SessionSummary])? = nil,
        lifecycleOperations: ChatResumeLifecycleOperations = .live
    ) -> (AppState, OfflineChatCacheStore, UUID) {
        let suite = "OfflineChatCacheTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        configureDefaults(defaults)
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let registry = registry ?? SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        let store = existingStore ?? makeStore()
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            sessionCatalogLoader: sessionCatalogLoader,
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            offlineChatCache: store
        )
        return (appState, store, registry.activeDashboardID ?? dashboard.id)
    }

    /// Lifecycle seams for a connect or profile switch that never leaves
    /// the process: each profile's catalog comes from `catalog`, and every
    /// chat open is recorded in `opened`.
    private func connectedLifecycle(
        catalog: @escaping @MainActor (String) async -> [SessionSummary],
        opened: OpenedChats
    ) -> ChatResumeLifecycleOperations {
        ChatResumeLifecycleOperations(
            connectClient: { _ in },
            loadCatalog: { client, _ in await catalog(client.profile ?? "default") },
            mintTicket: { _ in "profile-ticket" },
            openSession: { _, sessionID, _ in
                opened.ids.append(sessionID)
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [ChatMessage(id: "live-\(sessionID)", role: .assistant, content: "Live", timestamp: "9")],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in .unavailable },
            refreshContext: { _, _ in },
            pendingApprovals: { _, _ in [] },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {},
            loadBotRoster: {},
            botRoster: { _ in BotRosterSnapshot(bots: [], supportsBotProtocol: false) }
        )
    }

    /// Connects and switches with an in-memory keychain: the unsigned test
    /// host can't write the system one.
    private func useInMemoryKeychain() {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
    }

    /// Polls until `condition` holds, so a test waits on the state it checks
    /// rather than on a guessed number of yields.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the condition", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The Chats list a previous run saved for the scope.
    private func seedChatList(
        _ store: OfflineChatCacheStore,
        dashboard: UUID,
        profile: String = "default",
        sessions: [SessionSummary],
        cronSessions: [SessionSummary] = [],
        voiceTags: [String: VoiceSessionTag] = [:],
        projects: [ProjectSummary] = [],
        supportsProjects: Bool = false
    ) {
        store.recordChatList(
            SavedChatList.capture(
                sessions: sessions,
                cronSessions: cronSessions,
                isPinned: { _ in false },
                voiceTags: voiceTags,
                projects: projects,
                supportsProjects: supportsProjects
            ),
            dashboardID: dashboard,
            profile: profile
        )
    }

    private func seedCopy(_ store: OfflineChatCacheStore, dashboard: UUID) {
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "stored-a",
            title: "A",
            messages: [
                ChatMessage(id: "u1", role: .user, content: "Question", timestamp: "1"),
                ChatMessage(id: "a1", role: .assistant, content: "Answer", timestamp: "2"),
            ],
            sessions: [session("stored-a"), session("stored-b")]
        )
    }

    private func session(_ id: String, source: SessionSource = .chat, profile: String = "default") -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: profile,
            source: source,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}

/// The chats a test's lifecycle seams opened, in order.
@MainActor
private final class OpenedChats {
    var ids: [String] = []
}
