import XCTest
@testable import Conduit

/// Picking up a draft shared from another app (#812): which chat it opens,
/// what lands in the composer, and that nothing is sent. Part of
/// ShareDraftTests (one class keeps the planner's lanes within their
/// batch policy); `root` is that class's scratch folder.
extension ShareDraftTests {
    private var home: SavedDashboard {
        SavedDashboard(id: UUID(uuidString: "00000000-0000-0000-0000-0000000081a1")!, label: "Home", normalizedURL: "https://home.example")
    }
    private var work: SavedDashboard {
        SavedDashboard(id: UUID(uuidString: "00000000-0000-0000-0000-0000000081a2")!, label: "Work", normalizedURL: "https://work.example")
    }

    private var inbox: ShareDraftInbox { ShareDraftInbox(directory: root.appendingPathComponent("ShareInbox")) }

    /// Connected to `active`, its catalog settled, new chats created as
    /// `created`.
    @MainActor
    private func makeAppState(active: SavedDashboard, dashboards: [SavedDashboard], created: String? = "shared-new") throws -> AppState {
        let defaults = makeScratchDefaults("ShareDraftTests")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: active.id, dashboards: dashboards),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.shareDraftInboxOverride = inbox
        appState.shareDraftSettingsDefaultsOverride = defaults
        if let created {
            appState.widgetSessionCreatorOverride = { _, _ in (created, created, "default") }
        } else {
            struct CreateRefused: Error {}
            appState.widgetSessionCreatorOverride = { _, _ in throw CreateRefused() }
        }
        appState.widgetSettledCatalogOwner = WidgetWorkspaceID(dashboardID: active.id, profile: "default")
        // On screen before it connects, as the widget launch tests do: the
        // inbox is empty, so this picks nothing up.
        _ = appState.handleScenePhase(.active)
        appState.showLogin = false
        let connection = HermesConnection(baseUrl: active.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        return appState
    }

    @MainActor
    @discardableResult
    private func share(
        workspace: WidgetWorkspaceID?,
        target: ShareDraftTarget = .newChat,
        text: String = "Read this: https://example.com/a",
        file: Data? = Data("hello".utf8),
        createdAt: Date = Date()
    ) throws -> ShareDraftEnvelope {
        let staging = try inbox.beginStaging()
        var attachments: [ShareDraftAttachment] = []
        if let file {
            try file.write(to: staging.url.appendingPathComponent("1.txt"))
            attachments = [ShareDraftAttachment(storedName: "1.txt", displayName: "notes.txt", typeIdentifier: "public.plain-text", byteCount: Int64(file.count))]
        }
        let envelope = ShareDraftEnvelope(createdAt: createdAt, workspace: workspace, target: target, text: text, attachments: attachments)
        try inbox.commit(envelope, from: staging)
        return envelope
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, _ message: String) async -> Bool {
        for _ in 0..<20_000 {
            if condition() { return true }
            await Task.yield()
        }
        XCTFail(message)
        return false
    }

    @MainActor
    private func waitForDelivery(_ appState: AppState) async -> Bool {
        await waitUntil({
            appState.sharedDraftLaunch == nil && !appState.isDeliveringSharedDraft
                && !appState.widgetLaunchCoordinator.hasPendingRequest
        }, "the shared draft was not delivered")
    }

    // MARK: -

    @MainActor
    func testSharedDraftForANewChatOpensOneWithTheDraftInItsComposer() async throws {
        let appState = try makeAppState(active: home, dashboards: [home])
        let envelope = try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"))
        appState.pickUpSharedDrafts()
        XCTAssertEqual(appState.sharedDraftLaunch?.envelopeID, envelope.id)

        guard await waitForDelivery(appState) else { return }

        XCTAssertEqual(appState.activeSessionId, "shared-new")
        let request = try XCTUnwrap(appState.composerRestoreRequests.last)
        XCTAssertEqual(request.dashboardID, home.id)
        XCTAssertEqual(request.key, appState.composerDraftKeyOnScreen)
        XCTAssertEqual(request.draft.text, envelope.text)
        XCTAssertEqual(request.draft.attachments.map(\.name), ["notes.txt"])
        XCTAssertFalse(request.focuses)
        let staged = try XCTUnwrap(URL(string: try XCTUnwrap(request.draft.attachments.first).uri))
        XCTAssertEqual(try Data(contentsOf: staged), Data("hello".utf8), "the file moved into the composer's staging folder")
        XCTAssertFalse(staged.path.hasPrefix(root.path))
        XCTAssertEqual(appState.composerNotice, AppLocalization.string("Shared from another app. Review it, then send it."))
        XCTAssertNotEqual(appState.errorMessage, AppLocalization.string("Conduit couldn't open the chat you picked, so the shared draft is in this one."))
        XCTAssertTrue(appState.messages.isEmpty, "nothing is sent")
        XCTAssertNil(appState.pendingComposerSend, "nothing waits to be sent either")
        XCTAssertEqual(request.sharedDraftID, envelope.id)
        XCTAssertEqual(inbox.pending().map(\.envelope.id), [envelope.id], "kept until the composer has it")
        appState.pickUpSharedDrafts()
        XCTAssertNil(appState.sharedDraftLaunch, "a draft already on its way to the composer isn't opened again")
        appState.consumeComposerRestoreRequest(request.id)
        XCTAssertTrue(inbox.pending().isEmpty, "the draft left the inbox")
        try? FileManager.default.removeItem(at: staged)
    }

    @MainActor
    func testAChatThatCantOpenLeavesTheDraftInTheChatOnScreenAndSaysSo() async throws {
        let appState = try makeAppState(active: home, dashboards: [home], created: nil)
        appState.activeSessionId = "open-chat"
        try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"), file: nil)
        appState.pickUpSharedDrafts()

        guard await waitForDelivery(appState) else { return }

        XCTAssertEqual(appState.activeSessionId, "open-chat")
        XCTAssertEqual(appState.composerRestoreRequests.last?.draft.text, "Read this: https://example.com/a")
        XCTAssertEqual(appState.composerRestoreRequests.last?.key, appState.composerDraftKeyOnScreen)
        XCTAssertEqual(
            appState.errorMessage,
            AppLocalization.string("Conduit couldn't open the chat you picked, so the shared draft is in this one."),
            "the share's own words, not the widget's"
        )
        appState.consumeComposerRestoreRequest(try XCTUnwrap(appState.composerRestoreRequests.last).id)
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    @MainActor
    func testADraftWithoutADashboardAsksWhenThereAreSeveral() async throws {
        let appState = try makeAppState(active: home, dashboards: [home, work])
        let envelope = try share(workspace: nil)

        appState.pickUpSharedDrafts()

        let choice = try XCTUnwrap(appState.sharedDraftChoice)
        XCTAssertEqual(choice.id, envelope.id)
        XCTAssertEqual(choice.dashboards.map(\.id), [home.id, work.id])
        XCTAssertNil(appState.sharedDraftLaunch, "nothing opens until the user picks")

        // Put off, it isn't asked about again until Conduit next comes up,
        // and it isn't lost.
        appState.postponeSharedDraftChoice(choice)
        appState.pickUpSharedDrafts()
        XCTAssertNil(appState.sharedDraftChoice)
        _ = appState.handleScenePhase(.active)
        XCTAssertEqual(appState.sharedDraftChoice?.id, envelope.id)

        appState.discardSharedDraft(try XCTUnwrap(appState.sharedDraftChoice))
        XCTAssertNil(appState.sharedDraftChoice)
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    @MainActor
    func testAPostponedDraftDoesNotHoldUpTheNextOne() throws {
        let appState = try makeAppState(active: home, dashboards: [home, work])
        try share(workspace: nil, createdAt: Date().addingTimeInterval(-60))
        let next = try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"))
        appState.pickUpSharedDrafts()
        appState.postponeSharedDraftChoice(try XCTUnwrap(appState.sharedDraftChoice))
        appState.pickUpSharedDrafts()
        XCTAssertEqual(appState.sharedDraftLaunch?.envelopeID, next.id)
    }

    @MainActor
    func testANewerLaunchLeavesTheDraftForNextTime() throws {
        let appState = try makeAppState(active: home, dashboards: [home])
        appState.isConnected = false
        appState.isConnecting = true
        let envelope = try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"))
        appState.pickUpSharedDrafts()
        XCTAssertEqual(appState.sharedDraftLaunch?.envelopeID, envelope.id)

        // A widget tap while the chat was opening.
        let widget = try XCTUnwrap(WidgetLaunchLink(action: .open, workspace: nil, reference: nil))
        XCTAssertTrue(appState.routeWidgetLaunchURL(widget.url))

        XCTAssertNil(appState.sharedDraftLaunch)
        XCTAssertFalse(appState.isDeliveringSharedDraft)
        XCTAssertFalse(appState.sharedDraftLaunchOwnsFinish, "the widget's own finish keeps its words")
        XCTAssertTrue(appState.composerRestoreRequests.isEmpty, "not put in a chat it wasn't for")
        XCTAssertEqual(inbox.pending().map(\.envelope.id), [envelope.id])
    }

    @MainActor
    func testDraftsWaitOnTheSignInScreenAndOpenOnceSignedIn() async throws {
        let appState = try makeAppState(active: home, dashboards: [home])
        appState.showLogin = true
        let envelope = try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"))
        appState.pickUpSharedDrafts()
        XCTAssertNil(appState.sharedDraftLaunch)

        appState.showLogin = false

        guard await waitUntil({ appState.sharedDraftLaunch != nil || !appState.composerRestoreRequests.isEmpty }, "signing in didn't pick the draft up") else { return }
        XCTAssertEqual(appState.sharedDraftLaunch?.envelopeID ?? appState.composerRestoreRequests.last?.sharedDraftID, envelope.id)
    }

    @MainActor
    func testDraftsWaitWhileACallIsOn() throws {
        let appState = try makeAppState(active: home, dashboards: [home])
        appState.showVoiceSheet = true
        try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"))
        appState.pickUpSharedDrafts()
        XCTAssertNil(appState.sharedDraftLaunch)
        XCTAssertEqual(inbox.pending().count, 1)
    }

    @MainActor
    func testDisconnectingDiscardsTheDashboardsDrafts() throws {
        let appState = try makeAppState(active: home, dashboards: [home, work])
        appState.isConnected = false
        appState.isConnecting = true
        try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"))
        let other = try share(workspace: WidgetWorkspaceID(dashboardID: work.id, profile: "default"))
        appState.pickUpSharedDrafts()
        XCTAssertNotNil(appState.sharedDraftLaunch)

        appState.disconnect()

        XCTAssertNil(appState.sharedDraftLaunch)
        XCTAssertTrue(appState.composerRestoreRequests.isEmpty)
        XCTAssertEqual(inbox.pending().map(\.envelope.id), [other.id])
    }

    @MainActor
    func testPickingTheDashboardStartsANewChatThere() async throws {
        let appState = try makeAppState(active: home, dashboards: [home, work])
        let envelope = try share(workspace: nil)
        appState.pickUpSharedDrafts()
        let choice = try XCTUnwrap(appState.sharedDraftChoice)
        // The alert can clear the choice as it closes, before the action runs.
        appState.postponeSharedDraftChoice(choice)

        appState.chooseDashboardForSharedDraft(home.id, for: choice)

        XCTAssertEqual(appState.sharedDraftLaunch?.envelopeID, envelope.id)
        XCTAssertEqual(appState.sharedDraftLaunch?.link.action, .newChat)
        XCTAssertEqual(appState.sharedDraftLaunch?.link.workspace, WidgetWorkspaceID(dashboardID: home.id, profile: "default"))
    }

    @MainActor
    func testADraftWithoutADashboardGoesToTheOnlyOne() throws {
        let appState = try makeAppState(active: home, dashboards: [home])
        try share(workspace: nil)
        appState.pickUpSharedDrafts()
        XCTAssertNil(appState.sharedDraftChoice)
        XCTAssertEqual(appState.sharedDraftLaunch?.link.action, .newChat)
        XCTAssertEqual(appState.sharedDraftLaunch?.link.workspace?.dashboardID, home.id)
    }

    @MainActor
    func testADraftForAChatResumesThatChatInItsWorkspace() throws {
        let appState = try makeAppState(active: home, dashboards: [home, work])
        let workspace = WidgetWorkspaceID(dashboardID: work.id, profile: "research")
        let reference = WidgetConversationReference(kind: .dashboard, scopeProfile: "research", botName: nil, botLabel: nil, sessionID: "chat-9", isUnverified: false)
        try share(workspace: workspace, target: .conversation(reference))

        appState.pickUpSharedDrafts()

        let link = try XCTUnwrap(appState.sharedDraftLaunch?.link)
        XCTAssertEqual(link.action, .resume)
        XCTAssertEqual(link.workspace, workspace)
        XCTAssertEqual(link.reference?.sessionID, "chat-9")
    }

    @MainActor
    func testADraftForARemovedDashboardStartsANewChatWhereTheUserSays() throws {
        let appState = try makeAppState(active: home, dashboards: [home, work])
        let gone = WidgetWorkspaceID(dashboardID: UUID(), profile: "default")
        let reference = WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil, botLabel: nil, sessionID: "chat-1", isUnverified: false)
        try share(workspace: gone, target: .conversation(reference))
        appState.pickUpSharedDrafts()
        let choice = try XCTUnwrap(appState.sharedDraftChoice)
        appState.chooseDashboardForSharedDraft(work.id, for: choice)
        XCTAssertEqual(appState.sharedDraftLaunch?.link.action, .newChat, "the chat belonged to the removed dashboard")
    }

    @MainActor
    func testExpiredDraftsAreDroppedUnopened() throws {
        let appState = try makeAppState(active: home, dashboards: [home])
        try share(workspace: nil, createdAt: Date().addingTimeInterval(-ShareDraftLimits.lifetime - 60))
        appState.pickUpSharedDrafts()
        XCTAssertNil(appState.sharedDraftLaunch)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path).isEmpty)
    }

    @MainActor
    func testSignedOutOfEveryDashboardDraftsWait() throws {
        let appState = try makeAppState(active: home, dashboards: [])
        try share(workspace: nil)
        appState.pickUpSharedDrafts()
        XCTAssertNil(appState.sharedDraftLaunch)
        XCTAssertNil(appState.sharedDraftChoice)
        XCTAssertEqual(inbox.pending().count, 1)
    }

    @MainActor
    func testSigningOutOfADashboardDiscardsItsDrafts() throws {
        let appState = try makeAppState(active: home, dashboards: [home, work])
        try share(workspace: WidgetWorkspaceID(dashboardID: work.id, profile: "default"))
        let kept = try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"))

        appState.signOutDashboard(work.id)

        XCTAssertEqual(inbox.pending().map(\.envelope.id), [kept.id])
    }

    @MainActor
    func testGoingToTheBackgroundKeepsADraftWhoseChatWasOpening() throws {
        let appState = try makeAppState(active: home, dashboards: [home])
        appState.isConnected = false
        appState.isConnecting = true
        let envelope = try share(workspace: WidgetWorkspaceID(dashboardID: home.id, profile: "default"))
        appState.pickUpSharedDrafts()
        XCTAssertEqual(appState.sharedDraftLaunch?.envelopeID, envelope.id)

        _ = appState.handleScenePhase(.background)

        XCTAssertNil(appState.sharedDraftLaunch)
        XCTAssertFalse(appState.isDeliveringSharedDraft)
        XCTAssertTrue(appState.composerRestoreRequests.isEmpty)
        XCTAssertEqual(inbox.pending().map(\.envelope.id), [envelope.id], "picked up next time")
    }

    @MainActor
    func testTheComposerLimitIsPublishedWhenConduitComesUp() throws {
        let appState = try makeAppState(active: home, dashboards: [home])
        let defaults = try XCTUnwrap(appState.shareDraftSettingsDefaultsOverride)
        XCTAssertEqual(ShareDraftSettings.composerLimit(from: defaults), AttachmentSizeLimit.clampedMegabytes(
            UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey)
        ))
    }
}
