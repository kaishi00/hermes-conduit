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

    func testOtherSavedConversationsOpenInsideTheCopyOnly() throws {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "stored-b",
            title: "B",
            messages: [ChatMessage(id: "b1", role: .user, content: "Other", timestamp: "3")],
            sessions: [session("stored-a"), session("stored-b"), session("stored-c")]
        )
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertEqual(appState.offlineChatPresentation?.displayedSessionID, "stored-b")

        appState.showOfflineCachedSession("stored-a")
        XCTAssertEqual(appState.offlineChatPresentation?.displayedMessages.map(\.id), ["u1", "a1"])
        appState.showOfflineCachedSession("stored-c")
        XCTAssertEqual(appState.offlineChatPresentation?.displayedSessionID, "stored-a",
                       "A session with no saved transcript cannot be opened offline")
        XCTAssertNil(appState.activeSessionId)
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

    /// The saved section never hides the live catalog: in the owed-bootstrap
    /// window the live list is published while the copy is still up, and both
    /// render (saved above live). The empty state only shows with neither.
    func testSidebarShowsSavedSectionAlongsideTheLiveCatalog() {
        let withCopyAndLive = SidebarOfflineLayout.visibility(
            showingProjects: false, hasOfflineCopy: true, displayedSessionsEmpty: false
        )
        XCTAssertEqual(withCopyAndLive, .init(savedSection: true, liveSections: true, emptyState: false))

        let copyOnly = SidebarOfflineLayout.visibility(
            showingProjects: false, hasOfflineCopy: true, displayedSessionsEmpty: true
        )
        XCTAssertEqual(copyOnly, .init(savedSection: true, liveSections: true, emptyState: false))

        let liveOnly = SidebarOfflineLayout.visibility(
            showingProjects: false, hasOfflineCopy: false, displayedSessionsEmpty: false
        )
        XCTAssertEqual(liveOnly, .init(savedSection: false, liveSections: true, emptyState: false))

        let neither = SidebarOfflineLayout.visibility(
            showingProjects: false, hasOfflineCopy: false, displayedSessionsEmpty: true
        )
        XCTAssertEqual(neither, .init(savedSection: false, liveSections: true, emptyState: true))

        let projects = SidebarOfflineLayout.visibility(
            showingProjects: true, hasOfflineCopy: true, displayedSessionsEmpty: false
        )
        XCTAssertEqual(projects, .init(savedSection: false, liveSections: false, emptyState: false))
    }

    func testSavedRowTimeFallsBackToTheSavedLabelForImplausibleInstants() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func row(_ instant: TimeInterval?) -> OfflineCachedSession {
            OfflineCachedSession(id: "a", title: "A", updatedLabel: "saved label", lastActivityAt: instant, source: .chat)
        }
        XCTAssertEqual(row(nil).displayUpdatedLabel(now: now), "saved label")
        XCTAssertEqual(row(1e12).displayUpdatedLabel(now: now), "saved label")
        XCTAssertEqual(row(-5).displayUpdatedLabel(now: now), "saved label")
        XCTAssertEqual(row(.infinity).displayUpdatedLabel(now: now), "saved label")
        XCTAssertNotEqual(row(now.timeIntervalSince1970 - 3600).displayUpdatedLabel(now: now), "saved label")
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
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: loopback.normalizedURL, username: "hermes", password: "unused", requiresFaceID: false),
            dashboardID: loopback.id
        )
        addTeardownBlock { KeychainHelper.clearCredentials(dashboardID: loopback.id) }

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

    func testServerSwitchWipesEveryCopy() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        _ = appState.prepareChatResumeForConnection(to: "https://one.example", dashboardID: nil)
        XCTAssertNotNil(store.load(dashboardID: dashboard, profile: "default"),
                        "Re-establishing the same server is not a switch")

        _ = appState.prepareChatResumeForConnection(to: "https://two.example", dashboardID: nil)

        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"))
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
        store existingStore: OfflineChatCacheStore? = nil
    ) -> (AppState, OfflineChatCacheStore, UUID) {
        let suite = "OfflineChatCacheTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let registry = registry ?? SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        let store = existingStore ?? makeStore()
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            offlineChatCache: store
        )
        return (appState, store, registry.activeDashboardID ?? dashboard.id)
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

    private func session(_ id: String, source: SessionSource = .chat) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: source,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}
