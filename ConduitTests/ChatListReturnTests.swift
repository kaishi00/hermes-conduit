//
//  ChatListReturnTests.swift
//  Conduit
//
//  Going Back from a chat to the Chats list. Hermes pushes no catalog
//  changes, so the list reads the catalog again on the way back (RootView
//  calls refreshCatalogAfterLeavingChat when the chat is covered): a
//  conversation started from the compose button shows up once its first
//  turn is stored, without a pull to refresh. The chat just read there
//  doesn't come back with an unread dot for the turn the user watched.
//

import XCTest
@testable import Conduit

@MainActor
final class ChatListReturnTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ChatListReturnTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func row(
        _ id: String,
        profile: String,
        count: Int,
        lastActivityAt: TimeInterval,
        unread: Bool? = nil,
        watermark: Double? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "",
            lastActivityAt: lastActivityAt,
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            messageCount: count,
            isUnread: unread,
            readWatermark: watermark,
            lineageRootId: nil
        )
    }

    private func makeAppState(catalog: @escaping () -> [SessionSummary], loads: @escaping () -> Void = {}) -> AppState {
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionCatalogLoader: { _ in
                loads()
                return catalog()
            }
        )
        appState.isConnected = true
        return appState
    }

    /// What Back does: the chat is covered (AppState), and RootView asks
    /// the list to read the catalog again.
    private func goBack(_ appState: AppState) {
        appState.showSidebar = true
        appState.refreshCatalogAfterLeavingChat()
    }

    /// A bridge to a synthetic host that never sends: no page, no cookies.
    private func offlineBridge() -> DashboardTicketBridge {
        let bridge = DashboardTicketBridge(baseURL: "https://hermes.test")
        bridge.webViewCanRun = { false }
        return bridge
    }

    func testBackListsAConversationStartedInTheChat() async {
        let now = Date().timeIntervalSince1970
        var remote: [SessionSummary] = []
        let appState = makeAppState(catalog: { remote })
        let profile = appState.activeProfile
        let older = row("older", profile: profile, count: 4, lastActivityAt: now - 3_600)
        remote = [older]
        appState.sessions = [older]
        // The new chat is on screen; Hermes lists it once its first turn
        // is stored.
        appState.activeSessionId = "new-chat"
        remote = [row("new-chat", profile: profile, count: 2, lastActivityAt: now - 1), older]

        goBack(appState)
        await appState.leaveCatalogRefreshTask?.value

        XCTAssertEqual(appState.activeProfileSessions.map(\.id), ["new-chat", "older"])
        XCTAssertFalse(appState.isSessionUnread(appState.activeProfileSessions[0]))
    }

    func testBackReadsTheCatalogOnlyWhileConnected() async {
        var loadCount = 0
        let appState = makeAppState(catalog: { [] }, loads: { loadCount += 1 })
        appState.isConnected = false
        appState.activeSessionId = "chat"

        goBack(appState)

        XCTAssertNil(appState.leaveCatalogRefreshTask)
        XCTAssertEqual(loadCount, 0)
    }

    func testAReturnDuringARefreshAsksForOneMore() async {
        var loadCount = 0
        var appState: AppState!
        appState = makeAppState(catalog: { [] }, loads: {
            loadCount += 1
            // Two more returns while the first read is out: one more read.
            if loadCount == 1 {
                appState.refreshCatalogAfterLeavingChat()
                appState.refreshCatalogAfterLeavingChat()
            }
        })

        appState.refreshCatalogAfterLeavingChat()
        // Asked again before the read started: that read covers it.
        appState.refreshCatalogAfterLeavingChat()
        await appState.leaveCatalogRefreshTask?.value

        XCTAssertEqual(loadCount, 2)
        XCTAssertNil(appState.leaveCatalogRefreshTask)
    }

    /// The reported dot: an older chat, opened and read (its watermark set),
    /// gets a turn while on screen. Hermes then flags it unread because the
    /// turn postdates the watermark, and its count grew past what this
    /// device had seen. Back counts both as read and clears the flag.
    func testBackKeepsTheChatJustReadFreeOfAnUnreadDot() async {
        let now = Date().timeIntervalSince1970
        var remote: [SessionSummary] = []
        let appState = makeAppState(catalog: { remote })
        // Clearing Hermes' flag goes through the dashboard bridge; the
        // synthetic host never answers, and the write is recorded first.
        appState.installDashboardTicketBridgeForTesting(offlineBridge())
        let profile = appState.activeProfile
        let watermark = now - 120
        let read = row("older", profile: profile, count: 4, lastActivityAt: now - 600, unread: false, watermark: watermark)
        remote = [read]
        appState.sessions = [read]
        appState.activeSessionId = "older"

        // A turn runs while the chat is on screen, then the user goes Back.
        let afterTurn = row("older", profile: profile, count: 6, lastActivityAt: now - 1, unread: true, watermark: watermark)
        remote = [afterTurn]
        goBack(appState)
        await appState.leaveCatalogRefreshTask?.value

        let listed = appState.activeProfileSessions.first { $0.id == "older" }
        XCTAssertEqual(listed?.messageCount, 6)
        XCTAssertFalse(appState.isSessionUnread(afterTurn))
        XCTAssertFalse(appState.chatReadState.lastWriteAttempts.isEmpty, "Hermes' flag is cleared, not just hidden")
    }

    /// A mark someone made on purpose (Mark as Unread, here or on Desktop)
    /// is never cleared by the return.
    func testBackLeavesAnExplicitMarkAlone() async {
        let now = Date().timeIntervalSince1970
        var remote: [SessionSummary] = []
        let appState = makeAppState(catalog: { remote })
        appState.installDashboardTicketBridgeForTesting(offlineBridge())
        let profile = appState.activeProfile
        let read = row("read", profile: profile, count: 3, lastActivityAt: now - 600)
        remote = [read]
        appState.sessions = [read]
        appState.activeSessionId = "read"

        // Desktop marks it unread (watermark 0) while it is open here.
        remote = [row("read", profile: profile, count: 3, lastActivityAt: now - 600, unread: true, watermark: 0)]
        goBack(appState)
        await appState.leaveCatalogRefreshTask?.value

        XCTAssertTrue(appState.isSessionUnread(remote[0]))
        XCTAssertTrue(appState.chatReadState.lastWriteAttempts.isEmpty)
    }
}
