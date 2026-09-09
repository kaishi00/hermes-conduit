import XCTest
@testable import Conduit

@MainActor
final class AppShellStateTests: XCTestCase {
    func testAdmitRejectsSupersededOpenGeneration() {
        let shell = AppShellState()
        let first = shell.beginConversationOpen(sessionID: "a", reason: .rowSelection)
        let second = shell.beginConversationOpen(sessionID: "b", reason: .rowSelection)

        XCTAssertFalse(shell.admitConversationOpen(generation: first, sessionID: "a"))
        XCTAssertEqual(shell.compactRoute, .inbox)
        XCTAssertTrue(shell.admitConversationOpen(generation: second, sessionID: "b"))
        XCTAssertEqual(shell.compactRoute, .conversation)
    }

    func testShowInboxClearsPendingOpen() {
        let shell = AppShellState()
        _ = shell.beginConversationOpen(sessionID: "a", reason: .rowSelection)
        shell.showConversationWithoutOpenRequest()
        XCTAssertEqual(shell.compactRoute, .conversation)

        shell.showInbox()
        XCTAssertEqual(shell.compactRoute, .inbox)
        XCTAssertNil(shell.pendingOpen)
        XCTAssertFalse(shell.isCreatingConversation)
    }

    func testResetListTransientStateClearsSearch() {
        let shell = AppShellState()
        shell.isConversationSearchActive = true
        shell.conversationSearchText = "hello"
        shell.resetListTransientState()
        XCTAssertFalse(shell.isConversationSearchActive)
        XCTAssertEqual(shell.conversationSearchText, "")
    }

    func testReturnSurfaceSkipsWhenAlreadyShowingInbox() {
        XCTAssertFalse(
            AppShellState.shouldPresentInboxForReturnSurface(
                persistentSidebarActive: true,
                alreadyShowingInbox: false
            )
        )
        XCTAssertFalse(
            AppShellState.shouldPresentInboxForReturnSurface(
                persistentSidebarActive: false,
                alreadyShowingInbox: true
            )
        )
        XCTAssertTrue(
            AppShellState.shouldPresentInboxForReturnSurface(
                persistentSidebarActive: false,
                alreadyShowingInbox: false
            )
        )
    }

    func testShowMessagingSetsDestinationWithoutSessionOpen() {
        let shell = AppShellState()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        shell.showMessaging(destination)
        XCTAssertEqual(shell.compactRoute, .conversation)
        XCTAssertEqual(shell.messagingDestination, destination)
        XCTAssertNil(shell.pendingOpen)
    }

    func testAdmitConversationOpenClearsMessagingDestination() {
        let shell = AppShellState()
        shell.showMessaging(MessagingDestination(conversationID: "g1", profileID: nil))
        let generation = shell.beginConversationOpen(sessionID: "session-1", reason: .rowSelection)
        XCTAssertTrue(shell.admitConversationOpen(generation: generation, sessionID: "session-1"))
        XCTAssertNil(shell.messagingDestination)
        XCTAssertEqual(shell.compactRoute, .conversation)
    }

    func testShowConversationWithoutOpenRequestClearsMessaging() {
        let shell = AppShellState()
        shell.showMessaging(MessagingDestination(conversationID: nil, profileID: "designer-id"))
        shell.showConversationWithoutOpenRequest()
        XCTAssertNil(shell.messagingDestination)
        XCTAssertEqual(shell.compactRoute, .conversation)
    }

    func testShowInboxClearsMessagingDestination() {
        let shell = AppShellState()
        shell.showMessaging(MessagingDestination(conversationID: nil, profileID: "swe-id"))
        shell.showInbox()
        XCTAssertNil(shell.messagingDestination)
        XCTAssertEqual(shell.compactRoute, .inbox)
    }

    func testRequestProfileSessionsAfterMessagingHandsOffToInbox() {
        let shell = AppShellState()
        shell.showMessaging(MessagingDestination(conversationID: nil, profileID: "swe-id"))
        shell.requestProfileSessionsAfterMessaging("swe")
        XCTAssertNil(shell.messagingDestination)
        XCTAssertEqual(shell.compactRoute, .inbox)
        XCTAssertEqual(shell.consumePendingSessionsProfile(), "swe")
        XCTAssertNil(shell.pendingSessionsProfile)
    }
}
