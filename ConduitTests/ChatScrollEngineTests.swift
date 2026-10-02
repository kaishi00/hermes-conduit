import XCTest
@testable import Conduit

/// Stands in for the transcript's UIScrollView. Like UIKit, a programmatic
/// offset change is not clamped and reports back as a scroll.
@MainActor
private final class FakeChatScrollSurface: ChatScrollSurface {
    weak var engine: ChatScrollEngine?
    var contentOffsetY: CGFloat = 0
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    var isTracking = false
    var isDecelerating = false
    var transcriptOriginY: CGFloat = 18
    private(set) var sets: [(y: CGFloat, animated: Bool)] = []

    init(contentHeight: CGFloat = 4000, viewportHeight: CGFloat = 800) {
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
    }

    func setContentOffsetY(_ y: CGFloat, animated: Bool) {
        sets.append((y, animated))
        contentOffsetY = y
        engine?.surfaceScrolled()
    }

    /// Content grew or shrank (new rows, streaming, lazy measurement).
    func layOut(contentHeight: CGFloat) {
        self.contentHeight = contentHeight
        engine?.surfaceLayoutChanged()
    }

    /// The user moved the content with a finger, then let go.
    func userScroll(to y: CGFloat) {
        isTracking = true
        engine?.userDragBegan()
        contentOffsetY = y
        engine?.surfaceScrolled()
        isTracking = false
        engine?.userDragEnded()
    }
}

@MainActor
final class ChatScrollEngineTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var events: [ChatScrollEngineEvent] = []
    /// Every engine a test makes, alive until the test ends. The fake
    /// surface holds its engine weakly (as the real one does), so a test that
    /// keeps only the surface would otherwise talk to a freed engine and
    /// pass without testing anything.
    private var engines: [ChatScrollEngine] = []

    private let keyA = ChatScrollSessionKey(profile: "p", sessionID: "a")
    private let keyB = ChatScrollSessionKey(profile: "p", sessionID: "b")

    override func setUp() {
        super.setUp()
        clock = 100
        events = []
        engines = []
    }

    private func identity(_ sessionID: String) -> ChatScrollSessionIdentity {
        ChatScrollSessionIdentity(
            profile: "p",
            canonicalSessionID: sessionID,
            equivalentSessionIDs: [sessionID],
            isReconciling: false,
            settledRevision: 0
        )
    }

    private static func messages(_ range: Range<Int>) -> [ChatMessage] {
        range.map { index in
            ChatMessage(
                id: "m\(index)",
                role: index % 2 == 0 ? .user : .assistant,
                content: "Message \(index)",
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    /// An engine showing session "a" with ten messages, attached to a
    /// surface that has already laid them out.
    private func makeEngine(
        surface providedSurface: FakeChatScrollSurface? = nil
    ) -> (ChatScrollEngine, FakeChatScrollSurface) {
        let surface = providedSurface ?? FakeChatScrollSurface()
        let engine = ChatScrollEngine(now: { [unowned self] in self.clock })
        engines.append(engine)
        engine.onEvent = { [unowned self] event in self.events.append(event) }
        surface.engine = engine
        engine.renderedSessionChanged(
            to: keyA,
            identity: identity("a"),
            viaNotification: false,
            viewportTransitionGeneration: 1
        )
        engine.transcriptChanged(
            messages: Self.messages(0..<10),
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true
        )
        engine.attach(surface)
        return (engine, surface)
    }

    // MARK: - Following

    func testFollowingPinsToBottomInTheSameLayoutPass() {
        let (engine, surface) = makeEngine()
        XCTAssertEqual(surface.contentOffsetY, 3200, "attaching lands on the latest message")

        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 3800)
        XCTAssertTrue(surface.sets.allSatisfy { !$0.animated }, "following never animates")
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertFalse(engine.showsJumpToLatest)
    }

    func testFollowingPinsWhenTheViewportShrinks() {
        let (_, surface) = makeEngine()
        surface.viewportHeight = 500 // keyboard up
        surface.layOut(contentHeight: 4000)
        XCTAssertEqual(surface.contentOffsetY, 3500)
    }

    func testFollowingRepairsAnOvershootWhenContentShrinks() {
        let (_, surface) = makeEngine()
        surface.layOut(contentHeight: 3700)
        XCTAssertEqual(surface.contentOffsetY, 2900, "no empty space left under the last message")
    }

    /// SwiftUI can write its previous offset back after the pass that
    /// pinned a shrink, leaving empty space under the last message.
    func testFollowingPinsAnOffsetWrittenPastTheBottom() {
        let (engine, surface) = makeEngine()
        surface.contentHeight = 3700
        surface.contentOffsetY = 3200
        engine.surfaceScrolled()
        XCTAssertEqual(surface.contentOffsetY, 2900)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testFollowingLeavesARubberBandPastTheBottomToTheFinger() {
        let (engine, surface) = makeEngine()
        surface.isTracking = true
        surface.contentOffsetY = 3300
        engine.surfaceScrolled()
        XCTAssertEqual(surface.contentOffsetY, 3300)
    }

    func testFollowingDoesNotFightAFingerOnTheScreen() {
        let (_, surface) = makeEngine()
        surface.isTracking = true
        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    // MARK: - Browsing

    func testDraggingAwayStopsFollowingAndNewContentLeavesTheReaderAlone() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(engine.showsJumpToLatest)

        surface.layOut(contentHeight: 4800)
        XCTAssertEqual(surface.contentOffsetY, 1000, "rows arriving below never move the reader")
        XCTAssertTrue(events.contains(.flushPersistence))
    }

    func testScrollingBackNearTheBottomResumesFollowing() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        surface.userScroll(to: 3170)
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertFalse(engine.showsJumpToLatest)

        surface.layOut(contentHeight: 4400)
        XCTAssertEqual(surface.contentOffsetY, 3600)
    }

    func testDecelerationThatReachesTheBottomResumesFollowing() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        surface.isDecelerating = true
        surface.contentOffsetY = 3190
        engine.surfaceScrolled()
        XCTAssertTrue(engine.isFollowingLatest)

        surface.layOut(contentHeight: 4400)
        XCTAssertEqual(surface.contentOffsetY, 3190, "no pin while the deceleration is still running")
        surface.isDecelerating = false
        surface.layOut(contentHeight: 4500)
        XCTAssertEqual(surface.contentOffsetY, 3700)
    }

    func testAFlickAwayThatEndsNearTheBottomStopsFollowingOnceItLeaves() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3180)
        XCTAssertTrue(engine.isFollowingLatest, "let go within the relatch distance")

        surface.isDecelerating = true
        surface.contentOffsetY = 3150
        engine.surfaceScrolled()
        XCTAssertEqual(engine.mode, .browsing, "momentum carried the reader away")
        surface.contentOffsetY = 2600
        engine.surfaceScrolled()
        surface.isDecelerating = false

        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 2600, "new content does not pull the reader back")
    }

    func testMomentumAwayNeverRelatches() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3100)
        XCTAssertEqual(engine.mode, .browsing)
        surface.isDecelerating = true
        surface.contentOffsetY = 3090
        engine.surfaceScrolled()
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testTopVisibleRowIsTrackedAndPersistedWhileBrowsing() throws {
        let (engine, surface) = makeEngine()
        engine.rowFramesChanged([
            "m3": ChatScrollRowFrame(minY: 880, maxY: 1080, order: 3),
            "m4": ChatScrollRowFrame(minY: 1098, maxY: 1400, order: 4),
            "m5": ChatScrollRowFrame(minY: 1418, maxY: 1700, order: 5),
        ])
        events = []
        surface.userScroll(to: 1100)
        XCTAssertEqual(engine.topVisibleMessageID, "m4")
        XCTAssertTrue(events.contains(.persistSnapshot(keyA)))

        let snapshot = try XCTUnwrap(engine.renderedViewportSnapshot()?.snapshot)
        XCTAssertFalse(snapshot.followsLatest)
        XCTAssertEqual(snapshot.anchorSourceMessageID, "m4")
    }

    // MARK: - Load earlier

    func testPrependKeepsTheReaderOnTheSameRow() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 500)
        engine.olderPageBackfillRequested(sessionKey: keyA)

        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 1100, "offset grows by exactly the prepended height")

        // Estimated heights of the new rows settle a moment later.
        clock += 0.2
        surface.layOut(contentHeight: 4550)
        XCTAssertEqual(surface.contentOffsetY, 1050)

        // After the hold, a later change is ordinary browsing again.
        clock += 1
        surface.layOut(contentHeight: 4700)
        XCTAssertEqual(surface.contentOffsetY, 1050)
        XCTAssertNil(engine.prependAnchor)
    }

    /// SwiftUI can lay the prepended page out (content-size KVO) before its
    /// onChange delivers the new transcript: the anchor must still hold.
    func testPrependHoldsWhenLayoutArrivesBeforeTheTranscript() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 500)
        engine.olderPageBackfillRequested(sessionKey: keyA)

        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 500, "nothing to hold before the prepend is known")
        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertEqual(surface.contentOffsetY, 1100, "the landing itself restores the distance from the bottom")

        clock += 0.2
        surface.layOut(contentHeight: 4550)
        XCTAssertEqual(surface.contentOffsetY, 1050)
    }

    /// The bottom distance counts estimated heights of rows below the
    /// reader; once the reader's row reports a believable frame it wins,
    /// but a provisional frame far from the estimate never moves the reader.
    func testPrependRefinesToTheReadersRowButIgnoresProvisionalFrames() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 500)
        // m2 is the top visible row, 10 pt below the viewport top.
        engine.rowFramesChanged(["m2": ChatScrollRowFrame(minY: 492, maxY: 700, order: 2)])
        engine.olderPageBackfillRequested(sessionKey: keyA)

        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 1100, "bottom distance first")

        // A provisional frame more than a viewport off is ignored. It stays
        // inside the scrollable range (target 2508 < max 3800), so the
        // distance check rejects it, not clamping.
        engine.rowFramesChanged(["m2": ChatScrollRowFrame(minY: 2500, maxY: 2700, order: 7)])
        XCTAssertEqual(surface.contentOffsetY, 1100)

        // The settled frame: the rows below were estimated 40 pt too tall.
        engine.rowFramesChanged(["m2": ChatScrollRowFrame(minY: 1052, maxY: 1260, order: 7)])
        XCTAssertEqual(surface.contentOffsetY, 1060, "the reader's row is back where it was")
    }

    func testPrependAnchorWaitsForTheActualPrepend() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 500)
        engine.olderPageBackfillRequested(sessionKey: keyA)

        // A streamed reply lands first: front row unchanged.
        engine.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.layOut(contentHeight: 4300)
        XCTAssertEqual(surface.contentOffsetY, 500)
        XCTAssertNotNil(engine.prependAnchor)
        XCTAssertNil(engine.prependAnchor?.landedAt)

        engine.prependAnchorDischarged(matching: keyA)
        XCTAssertNil(engine.prependAnchor)
    }

    func testPrependWhileFollowingNeedsNoAnchor() {
        let (engine, surface) = makeEngine()
        engine.olderPageBackfillRequested(sessionKey: keyA)
        XCTAssertNil(engine.prependAnchor)

        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 3800)
    }

    // MARK: - Session switches

    func testSessionSwitchLandsOnLatestWithoutAnimation() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)

        engine.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3200)

        engine.transcriptChanged(
            messages: Self.messages(100..<140),
            transcriptRevision: 3,
            viewportTransitionGeneration: 2,
            activeSessionKey: keyB
        )
        surface.layOut(contentHeight: 9000)
        XCTAssertEqual(surface.contentOffsetY, 8200)
        XCTAssertTrue(surface.sets.allSatisfy { !$0.animated })
    }

    func testEquivalentSessionSpellingIsNotASwitch() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        let aliasIdentity = ChatScrollSessionIdentity(
            profile: "p",
            canonicalSessionID: "a",
            equivalentSessionIDs: ["a", "runtime-a"],
            isReconciling: false,
            settledRevision: 1
        )
        engine.renderedSessionChanged(
            to: ChatScrollSessionKey(profile: "p", sessionID: "runtime-a"),
            identity: aliasIdentity,
            viaNotification: false,
            viewportTransitionGeneration: 1
        )
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertEqual(surface.contentOffsetY, 1000)
    }

    func testNotificationOpeningCancelsRestorationAndFollows() {
        let (engine, surface) = makeEngine()
        engine.restorationRequested(
            ChatResumeRestorationRequest(generation: 4, sessionKey: keyA, destination: .latest)
        )
        XCTAssertEqual(engine.mode, .restoring)

        engine.notificationHandoffBegan()
        XCTAssertNil(engine.restoration)
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertTrue(events.contains(.cancelAutomaticRestoration))

        surface.layOut(contentHeight: 6000)
        engine.notificationHandoffFinished()
        XCTAssertEqual(surface.contentOffsetY, 5200)
    }

    // MARK: - Explicit commands

    func testJumpToLatestAnimatesOnlyAShortDistance() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 2400)
        engine.explicitLatestRequested(animated: true)
        XCTAssertEqual(surface.sets.last?.animated, true)

        surface.userScroll(to: 0)
        clock += 1
        engine.explicitLatestRequested(animated: true)
        XCTAssertEqual(surface.sets.last?.animated, false, "a long jump snaps instead of sweeping")
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    func testAnimatedJumpIsNotInterruptedAndGetsAFinalPin() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 2400)
        engine.explicitLatestRequested(animated: true)
        let setsAfterJump = surface.sets.count

        surface.layOut(contentHeight: 4200)
        XCTAssertEqual(surface.sets.count, setsAfterJump, "no pin mid-animation")

        clock += ChatScrollEngine.latestAnimationDuration
        engine.latestAnimationFinished()
        XCTAssertEqual(surface.contentOffsetY, 3400)
        XCTAssertEqual(surface.sets.last?.animated, false)
    }

    func testSendFromFarAwayLandsOnLatest() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 100)
        engine.explicitLatestRequested(animated: false)
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertTrue(events.contains(.cancelAutomaticRestoration))
    }

    func testTitleTapGoesToTheTop() {
        let (engine, surface) = makeEngine()
        surface.insetTop = 60
        engine.explicitTopRequested()
        XCTAssertEqual(surface.contentOffsetY, -60)
        XCTAssertEqual(engine.mode, .browsing)

        surface.layOut(contentHeight: 4500)
        XCTAssertEqual(surface.contentOffsetY, -60)
    }

    func testTitleTapOnAShortChatKeepsFollowing() {
        let (engine, surface) = makeEngine(surface: FakeChatScrollSurface(contentHeight: 600))
        engine.explicitTopRequested()
        XCTAssertTrue(engine.isFollowingLatest)
    }

    // MARK: - Restoration

    private func anchorRequest(
        _ engine: ChatScrollEngine,
        row index: Int,
        generation: UInt64 = 9
    ) -> ChatResumeRestorationRequest {
        let target = engine.targets[index]
        return ChatResumeRestorationRequest(
            generation: generation,
            sessionKey: keyA,
            destination: .snapshot(
                ChatScrollSnapshot(
                    anchorMessageID: target.semanticID,
                    followsLatest: false,
                    anchorMetadata: target.restorationMetadata,
                    anchorSourceMessageID: target.id
                )
            )
        )
    }

    func testRestorationPlacesTheSavedRowAtTheTop() {
        let (engine, surface) = makeEngine()
        surface.insetTop = 50
        engine.rowFramesChanged(["m5": ChatScrollRowFrame(minY: 1000, maxY: 1200, order: 5)])
        engine.restorationRequested(anchorRequest(engine, row: 5))

        XCTAssertTrue(engine.restorationTick(transcriptRevision: 1))
        XCTAssertEqual(surface.contentOffsetY, 968, "origin 18 + row 1000 - inset 50")

        XCTAssertFalse(engine.restorationTick(transcriptRevision: 1))
        XCTAssertEqual(events.last, .completeRestoration(generation: 9))
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertEqual(engine.topVisibleMessageID, "m5")

        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 968, "restored position is not followed away")
    }

    func testRestorationRevealsARowThatIsNotLaidOutYet() {
        let (engine, surface) = makeEngine()
        engine.restorationRequested(anchorRequest(engine, row: 5))

        XCTAssertTrue(engine.restorationTick(transcriptRevision: 1))
        XCTAssertEqual(events.last, .revealRow(id: "m5"))
        let revealCount = { self.events.filter { $0 == .revealRow(id: "m5") }.count }
        for _ in 0..<3 { engine.restorationTick(transcriptRevision: 1) }
        XCTAssertEqual(revealCount(), 1, "reveals are spaced out")

        engine.rowFramesChanged(["m5": ChatScrollRowFrame(minY: 1000, maxY: 1200, order: 5)])
        engine.restorationTick(transcriptRevision: 1)
        XCTAssertEqual(surface.contentOffsetY, 1018)
        XCTAssertFalse(engine.restorationTick(transcriptRevision: 1))
    }

    func testRestorationWaitsForTheRenderedTranscript() {
        let (engine, surface) = makeEngine()
        engine.rowFramesChanged(["m5": ChatScrollRowFrame(minY: 1000, maxY: 1200, order: 5)])
        engine.restorationRequested(anchorRequest(engine, row: 5))
        XCTAssertTrue(engine.restorationTick(transcriptRevision: 2))
        XCTAssertEqual(surface.contentOffsetY, 3200, "nothing moves until revision 2 is rendered")
    }

    func testRestorationToLatestCompletesFollowing() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 100)
        engine.restorationRequested(
            ChatResumeRestorationRequest(generation: 3, sessionKey: keyA, destination: .latest)
        )
        XCTAssertFalse(engine.restorationTick(transcriptRevision: 1))
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertTrue(events.contains(.completeRestoration(generation: 3)))
    }

    func testDisappearingEndsAnInstalledRestoration() {
        let (engine, _) = makeEngine()
        engine.restorationRequested(anchorRequest(engine, row: 5))
        XCTAssertEqual(engine.mode, .restoring)
        engine.viewDisappeared()
        XCTAssertNil(engine.restoration)
        XCTAssertNotEqual(engine.mode, .restoring)
    }

    func testRestorationWaitsOutTheBackgroundWithoutSpendingItsBudget() {
        let (engine, surface) = makeEngine()
        surface.insetTop = 50
        engine.rowFramesChanged(["m5": ChatScrollRowFrame(minY: 1000, maxY: 1200, order: 5)])
        engine.restorationRequested(anchorRequest(engine, row: 5))
        engine.setPaused(true)
        for _ in 0..<(ChatScrollEngine.maximumRestorationChecks * 2) {
            XCTAssertTrue(engine.restorationTick(transcriptRevision: 1))
        }
        XCTAssertFalse(events.contains(.abandonRestoration(generation: 9)))
        XCTAssertFalse(engine.showsJumpToLatest, "no jump button while restoring")

        engine.setPaused(false)
        XCTAssertTrue(engine.restorationTick(transcriptRevision: 1))
        XCTAssertFalse(engine.restorationTick(transcriptRevision: 1))
        XCTAssertEqual(surface.contentOffsetY, 968)
        XCTAssertEqual(events.last, .completeRestoration(generation: 9))
    }

    func testJumpToLatestDoesNotTakeTheScrollViewFromAFinger() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        surface.isTracking = true
        engine.explicitLatestRequested(animated: false)
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testAReplacementRestorationPublishesItsGeneration() {
        let (engine, _) = makeEngine()
        engine.restorationRequested(anchorRequest(engine, row: 5))
        let replacement = ChatResumeRestorationRequest(generation: 12, sessionKey: keyA, destination: .latest)
        engine.restorationRequested(replacement)
        XCTAssertEqual(engine.mode, .restoring)
        XCTAssertEqual(engine.renderInputs.renderedScrollScope?.restorationGeneration, 12)
    }

    func testRestorationForAnotherConversationIsAbandoned() {
        let (engine, _) = makeEngine()
        engine.restorationRequested(
            ChatResumeRestorationRequest(generation: 5, sessionKey: keyB, destination: .latest)
        )
        XCTAssertNil(engine.restoration)
        XCTAssertEqual(events.last, .abandonRestoration(generation: 5))
    }

    func testRestorationGivesUpAfterItsBudget() {
        let (engine, _) = makeEngine()
        engine.restorationRequested(anchorRequest(engine, row: 5))
        var ticks = 0
        while engine.restorationTick(transcriptRevision: 1) { ticks += 1 }
        XCTAssertEqual(ticks, ChatScrollEngine.maximumRestorationChecks)
        XCTAssertEqual(events.last, .abandonRestoration(generation: 9))
    }

    func testADragCancelsRestoration() {
        let (engine, surface) = makeEngine()
        engine.restorationRequested(anchorRequest(engine, row: 5))
        surface.userScroll(to: 1500)
        XCTAssertNil(engine.restoration)
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(events.contains(.cancelAutomaticRestoration))
    }

    // MARK: - Background

    func testPausedEngineLeavesTheOffsetAloneAndCatchesUpOnReturn() {
        let (engine, surface) = makeEngine()
        engine.setPaused(true)
        surface.layOut(contentHeight: 5000)
        XCTAssertEqual(surface.contentOffsetY, 3200)

        engine.setPaused(false)
        XCTAssertEqual(surface.contentOffsetY, 4200)
    }

    func testJumpToLatestInTheBackgroundWaitsForTheForeground() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        engine.setPaused(true)
        events.removeAll()
        engine.explicitLatestRequested(animated: false)
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertFalse(events.contains(.revealLatest))
        XCTAssertTrue(engine.isFollowingLatest)

        engine.setPaused(false)
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    func testASessionSwitchInTheBackgroundDoesNotScroll() {
        let (engine, surface) = makeEngine()
        engine.setPaused(true)
        let setsBefore = surface.sets.count
        events.removeAll()
        engine.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertEqual(surface.sets.count, setsBefore)
        XCTAssertFalse(events.contains(.revealLatest))

        surface.layOut(contentHeight: 5000)
        engine.setPaused(false)
        XCTAssertEqual(surface.contentOffsetY, 4200, "returning pins the new conversation")
    }

    func testRenderInputsFromUIKitCallbacksPublishOnTheNextTurn() {
        let (engine, surface) = makeEngine()
        XCTAssertFalse(engine.renderInputs.showsJumpToLatest)

        surface.userScroll(to: 1000)
        XCTAssertTrue(engine.showsJumpToLatest)
        XCTAssertFalse(
            engine.renderInputs.showsJumpToLatest,
            "a change made inside a UIKit callback must not publish during the SwiftUI update"
        )

        let published = expectation(description: "published on the next main-queue turn")
        DispatchQueue.main.async { published.fulfill() }
        wait(for: [published], timeout: 1)
        XCTAssertTrue(engine.renderInputs.showsJumpToLatest)
        XCTAssertFalse(engine.renderInputs.isFollowingLatest)

        engine.explicitLatestRequested(animated: false)
        XCTAssertTrue(engine.renderInputs.isFollowingLatest, "a SwiftUI-driven command publishes directly")
    }

    func testReduceMotionSnapsTheJumpToLatest() {
        let engine = ChatScrollEngine(now: { [unowned self] in self.clock }, prefersReducedMotion: { true })
        let surface = FakeChatScrollSurface()
        surface.engine = engine
        engine.attach(surface)
        surface.userScroll(to: 2400)
        engine.explicitLatestRequested(animated: true)
        XCTAssertEqual(surface.sets.last?.animated, false)
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    func testSessionSwitchForgetsThePreviousRowFrames() {
        let (engine, _) = makeEngine()
        engine.rowFramesChanged(["m5": ChatScrollRowFrame(minY: 1000, maxY: 1200, order: 5)])
        engine.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertNil(engine.rowFrame(for: "m5"))
    }
}
