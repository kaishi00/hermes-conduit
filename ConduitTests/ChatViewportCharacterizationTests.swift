import XCTest
@testable import Conduit

/// Phase-0 characterization of the CURRENT viewport decision pipeline.
/// Each test documents the composed decision for one spec repro scenario.
/// These are expected to be REPLACED by ChatViewportControllerTests in the
/// rewrite (plan Task 7) — they exist to capture today's behavior first.
final class ChatViewportCharacterizationTests: XCTestCase {

    private func assistant(_ id: String, _ content: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: content, timestamp: "2026-01-01T00:00:00Z")
    }

    // Scenario: long growing response, untouched. Today every streamingText
    // delta issues an unconditional bottom scroll while following — the
    // network-delta coupling the rewrite removes (spec: follow rendered
    // layout growth instead).
    func testCharacterizeStreamingDeltaFollowWhileFollowing() {
        var followsLatest = true
        let hasPendingRestoration = false
        // mirrors ChatView.onChange(of: streamingText)
        func streamingDeltaScrolls() -> Bool {
            followsLatest && !hasPendingRestoration // -> proxy.scrollTo(bottom)
        }
        for _ in 0..<30 {
            XCTAssertTrue(streamingDeltaScrolls())
        }
        followsLatest = false
        XCTAssertFalse(streamingDeltaScrolls())
    }

    // Scenario: drag upward during stream. Deliberate drag disables follow
    // immediately; geometry ticks while finger-down must not re-latch.
    func testCharacterizeDragDuringStreamDisablesFollowAndGeometryCannotRelatch() {
        // beginChatDragIfNeeded sets followsLatest = false on the first
        // deliberate drag callback (minimumDistance: 3).
        var followsLatest = false
        let isDragging = true
        // mirrors relatchFollowsLatestIfSettled() on a layout tick
        XCTAssertFalse(ChatFollowLatestRelatchPolicy.shouldRelatch(
            isNearBottom: true,
            hasPendingRestoration: false,
            hasNotificationHandoff: false,
            isDragging: isDragging
        ))
        XCTAssertTrue(!followsLatest)
        // even after the finger lifts far from the bottom, no relatch
        XCTAssertFalse(ChatFollowLatestRelatchPolicy.shouldRelatch(
            isNearBottom: false,
            hasPendingRestoration: false,
            hasNotificationHandoff: false,
            isDragging: false
        ))
    }

    // Scenario: transcript-size change during an active drag must not
    // re-enable follow (reference: ChatScrollStateTests pins this too; the
    // ledger scenario list is complete in one file).
    func testCharacterizeTranscriptTransitionKeepsFollowDisabledForActiveDrag() {
        XCTAssertFalse(
            ChatFollowLatestRelatchPolicy.shouldFollowLatestAfterTransition(isDragging: true)
        )
    }

    // Scenario: messages change while following (no restoration/handoff)
    // reasserts latest — today via claimLatest + animated scroll + 150ms
    // delayed retry validated against the owner token.
    func testCharacterizeMessageChangeReassertsLatestOnlyWhenFollowing() {
        let update: ChatMessageScrollTargetCacheUpdate = .renderingChanged
        XCTAssertTrue(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update,
            followsLatest: true,
            hasPendingRestoration: false,
            hasNotificationHandoff: false
        ))
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update,
            followsLatest: false,
            hasPendingRestoration: false,
            hasNotificationHandoff: false
        ))
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: .unchanged,
            followsLatest: true,
            hasPendingRestoration: false,
            hasNotificationHandoff: false
        ))
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update,
            followsLatest: true,
            hasPendingRestoration: true,
            hasNotificationHandoff: false
        ))
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update,
            followsLatest: true,
            hasPendingRestoration: false,
            hasNotificationHandoff: true
        ))
    }

    // Scenario: rendering-only message-ID replacement while following
    // reasserts latest; while browsing it must not move the viewport.
    func testCharacterizeRenderingOnlyReplacementRespectsBrowsing() {
        var cache = ChatMessageScrollTargetCache()
        cache.update(for: [assistant("a", "hello")])
        let rotated = [
            ChatMessage(
                id: "a2",
                role: .assistant,
                content: "hello",
                timestamp: "2026-01-01T00:00:00Z"
            )
        ]
        let update = cache.update(for: rotated)
        XCTAssertEqual(update, .renderingChanged)
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update,
            followsLatest: false,
            hasPendingRestoration: false,
            hasNotificationHandoff: false
        ))
        XCTAssertTrue(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update,
            followsLatest: true,
            hasPendingRestoration: false,
            hasNotificationHandoff: false
        ))
    }

    // Scenario: title-to-top during stream. Explicit top claims ownership;
    // streamed deltas must not yank back while top owner is active.
    // DOCUMENTED GAP: the "top owner suppresses geometry relatch away from
    // bottom" guard lives in the view (relatchFollowsLatestIfSettled), NOT in
    // any pure policy — which is exactly the bug class this rewrite fixes.
    // The controller tests testLayoutTickNearBottomWhileBrowsingRelatchesWithoutScrolling
    // and testLayoutTickNearBottomReturnsExplicitTopToFollowingLatest close
    // this gap; this characterization pins only what is pure today.
    func testCharacterizeTitleTopOwnerSurvivesUntilNearBottomOrNewerClaim() {
        var owner = ChatScrollOwnerState()
        let request = 3
        _ = owner.claimTop(request: request)
        XCTAssertTrue(owner.hasActiveTopOwner(currentRequest: request))
        // a newer top request supersedes the old owner's retry
        _ = owner.claimTop(request: 4)
        XCTAssertFalse(owner.hasActiveTopOwner(currentRequest: request))
        XCTAssertTrue(owner.hasActiveTopOwner(currentRequest: 4))
        // relatch near the bottom is allowed by the pure policy...
        XCTAssertTrue(ChatFollowLatestRelatchPolicy.shouldRelatch(
            isNearBottom: true,
            hasPendingRestoration: false,
            hasNotificationHandoff: false,
            isDragging: false
        ))
        // ...but the view's top-owner branch requires near-bottom first and
        // then claims latest — untestable here (see gap note above).
        _ = owner.claimLatest()
        XCTAssertFalse(owner.hasActiveTopOwner(currentRequest: 4))
    }

    // Scenario: notification handoff completion picks top owner if claimed
    // during handoff, else latest-if-following, else none.
    func testCharacterizeHandoffCompletionActions() {
        var owner = ChatScrollOwnerState()
        XCTAssertEqual(
            owner.handoffCompletionAction(
                currentTopRequest: 0,
                currentTopAnchor: "t",
                shouldFollowLatest: true
            ),
            .latest
        )
        XCTAssertEqual(
            owner.handoffCompletionAction(
                currentTopRequest: 0,
                currentTopAnchor: "t",
                shouldFollowLatest: false
            ),
            .none
        )
        _ = owner.claimTop(request: 5)
        XCTAssertEqual(
            owner.handoffCompletionAction(
                currentTopRequest: 5,
                currentTopAnchor: "chat-top-p-s",
                shouldFollowLatest: false
            ),
            .top(anchorID: "chat-top-p-s")
        )
    }

    // Scenario: streaming completion (isBusy false) scrolls only while
    // following and not restoring. The condition lives inline in the view's
    // onChange — characterize its truth table directly.
    func testCharacterizeBusyEndScrollConditionTruthTable() {
        func scrolls(followsLatest: Bool, hasPendingRestoration: Bool) -> Bool {
            followsLatest && !hasPendingRestoration
        }
        XCTAssertTrue(scrolls(followsLatest: true, hasPendingRestoration: false))
        XCTAssertFalse(scrolls(followsLatest: false, hasPendingRestoration: false))
        XCTAssertFalse(scrolls(followsLatest: true, hasPendingRestoration: true))
        XCTAssertFalse(scrolls(followsLatest: false, hasPendingRestoration: true))
    }

    // Scenario: session switch adopts follow-latest unless dragging.
    func testCharacterizeSessionSwitchFollowDecision() {
        XCTAssertTrue(
            ChatFollowLatestRelatchPolicy.shouldFollowLatestAfterTransition(isDragging: false)
        )
        XCTAssertFalse(
            ChatFollowLatestRelatchPolicy.shouldFollowLatestAfterTransition(isDragging: true)
        )
    }

    // Scenario: the latest retry validates against the owner token — a
    // superseded owner (drag, newer claim, session transition) must not
    // fire its delayed retry.
    func testCharacterizeLatestRetryYieldsToNewerOwner() {
        var owner = ChatScrollOwnerState()
        let token = owner.claimLatest()
        owner.invalidateForUserDrag()
        XCTAssertNil(owner.latestRetryAnchor(
            for: token,
            currentAnchor: "chat-latest-p-s",
            followsLatest: false,
            hasPendingRestoration: false,
            isCancelled: false
        ))
        let token2 = owner.claimLatest()
        XCTAssertEqual(
            owner.latestRetryAnchor(
                for: token2,
                currentAnchor: "chat-latest-p-s",
                followsLatest: true,
                hasPendingRestoration: false,
                isCancelled: false
            ),
            "chat-latest-p-s"
        )
        XCTAssertNil(owner.latestRetryAnchor(
            for: token2,
            currentAnchor: "chat-latest-p-s",
            followsLatest: true,
            hasPendingRestoration: true,
            isCancelled: false
        ))
    }
}
