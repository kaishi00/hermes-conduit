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

    func testTopScrollRetryRequiresCurrentRequestAndOwnerToken() {
        var ownership = ChatScrollOwnerState()
        let token = ownership.claimTop(request: 5)

        XCTAssertEqual(
            ownership.topRetryAnchor(
                for: token,
                currentRequest: 5,
                currentAnchor: "chat-top-default-session-a",
                isCancelled: false
            ),
            "chat-top-default-session-a"
        )

        XCTAssertNil(
            ownership.topRetryAnchor(
                for: token,
                currentRequest: 6,
                currentAnchor: "chat-top-default-session-a",
                isCancelled: false
            )
        )
        XCTAssertNil(
            ownership.topRetryAnchor(
                for: token,
                currentRequest: 5,
                currentAnchor: "chat-top-default-session-b",
                isCancelled: true
            )
        )
    }

    func testExplicitTopOwnerSurvivesHandoffReadinessAndUsesCurrentAnchor() {
        var ownership = ChatScrollOwnerState()
        _ = ownership.claimLatest()
        let topToken = ownership.claimTop(request: 7)

        XCTAssertEqual(
            ownership.topRetryAnchor(
                for: topToken,
                currentRequest: 7,
                currentAnchor: "chat-top-default-canonical-session",
                isCancelled: false
            ),
            "chat-top-default-canonical-session"
        )
        XCTAssertEqual(
            ownership.handoffCompletionAction(
                currentTopRequest: 7,
                currentTopAnchor: "chat-top-default-canonical-session",
                shouldFollowLatest: true
            ),
            .top(anchorID: "chat-top-default-canonical-session")
        )
    }

    func testTopRetryIsSupersededByLaterOwnerGeneration() {
        var userDragOwnership = ChatScrollOwnerState()
        let userDragTop = userDragOwnership.claimTop(request: 1)
        userDragOwnership.invalidateForUserDrag()
        XCTAssertNil(
            userDragOwnership.topRetryAnchor(
                for: userDragTop,
                currentRequest: 1,
                currentAnchor: "chat-top-default-session-a",
                isCancelled: false
            )
        )

        var latestOwnership = ChatScrollOwnerState()
        let latestTop = latestOwnership.claimTop(request: 1)
        _ = latestOwnership.claimLatest()
        XCTAssertNil(
            latestOwnership.topRetryAnchor(
                for: latestTop,
                currentRequest: 1,
                currentAnchor: "chat-top-default-session-a",
                isCancelled: false
            )
        )

        var sessionOwnership = ChatScrollOwnerState()
        let sessionTop = sessionOwnership.claimTop(request: 1)
        sessionOwnership.invalidateForSessionTransition()
        XCTAssertNil(
            sessionOwnership.topRetryAnchor(
                for: sessionTop,
                currentRequest: 1,
                currentAnchor: "chat-top-default-session-b",
                isCancelled: false
            )
        )

        var newerTopOwnership = ChatScrollOwnerState()
        let staleTop = newerTopOwnership.claimTop(request: 1)
        let currentTop = newerTopOwnership.claimTop(request: 2)
        XCTAssertNil(
            newerTopOwnership.topRetryAnchor(
                for: staleTop,
                currentRequest: 2,
                currentAnchor: "chat-top-default-session-a",
                isCancelled: false
            )
        )
        XCTAssertEqual(
            newerTopOwnership.topRetryAnchor(
                for: currentTop,
                currentRequest: 2,
                currentAnchor: "chat-top-default-session-a",
                isCancelled: false
            ),
            "chat-top-default-session-a"
        )
    }

    func testHandoffFallsBackToExistingLatestPolicyWithoutExplicitTopOwner() {
        var ownership = ChatScrollOwnerState()
        _ = ownership.claimLatest()

        XCTAssertEqual(
            ownership.handoffCompletionAction(
                currentTopRequest: 0,
                currentTopAnchor: "chat-top-default-session-a",
                shouldFollowLatest: true
            ),
            .latest
        )
        XCTAssertEqual(
            ownership.handoffCompletionAction(
                currentTopRequest: 0,
                currentTopAnchor: "chat-top-default-session-a",
                shouldFollowLatest: false
            ),
            .none
        )
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
