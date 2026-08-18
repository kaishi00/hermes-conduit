import XCTest
@testable import Conduit

@MainActor
final class ChatTitleScrollTests: XCTestCase {
    func testTitleScrollRequestIsMonotonicAndObservableForRepeatedTaps() {
        let appState = AppState(loadSavedConnection: false)
        let initial = appState.chatScrollToTopRequest

        appState.requestChatScrollToTop()
        appState.requestChatScrollToTop()

        XCTAssertEqual(appState.chatScrollToTopRequest, initial &+ 2)
    }

    func testTopAnchorIsScopedToTheActiveChatSession() {
        let sessionA = ChatScrollSessionKey(profile: "default", sessionID: "session-a")
        let sessionB = ChatScrollSessionKey(profile: "default", sessionID: "session-b")

        let anchorA = ChatTitleScrollAnchor.id(for: sessionA)
        let repeatedAnchorA = ChatTitleScrollAnchor.id(for: sessionA)
        let anchorB = ChatTitleScrollAnchor.id(for: sessionB)

        XCTAssertEqual(anchorA, repeatedAnchorA)
        XCTAssertNotEqual(anchorA, anchorB)
    }

    func testSyntheticTopAnchorPersistsAsFirstMessageTarget() {
        let messages = [
            ChatMessage(id: "first", role: .user, content: "Hello", timestamp: "1"),
            ChatMessage(id: "second", role: .assistant, content: "Hi", timestamp: "2")
        ]
        let targets = ChatMessageScrollTargets.make(for: messages)
        let topAnchor = "chat-top-default-session-a"

        let snapshot = ChatTitleScrollViewportSnapshot.make(
            followsLatest: false,
            topVisibleID: topAnchor,
            topAnchorID: topAnchor,
            targets: targets
        )

        XCTAssertEqual(snapshot?.anchorMessageID, targets[0].semanticID)
        XCTAssertEqual(snapshot?.anchorMetadata, targets[0].restorationMetadata)
        XCTAssertEqual(snapshot?.anchorSourceMessageID, "first")
        XCTAssertNotEqual(snapshot?.anchorMessageID, topAnchor)
    }
}
