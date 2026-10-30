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
    var sets: [(y: CGFloat, animated: Bool)] = []

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

/// A card drawn in a web page (HTMLPreviewBlock, MarkupBlock) as the engine
/// sees it: its frame in the stack, how much taller than that frame its
/// measured height is, and how often it took it.
@MainActor
private final class FakeMeasuredCard: ChatScrollMeasuredCard {
    var stackFrame: CGRect?
    var pendingGrowth: CGFloat
    var heightsTaken = 0

    init(delta: CGFloat, minY: CGFloat, height: CGFloat = 280) {
        stackFrame = CGRect(x: 0, y: minY, width: 300, height: height)
        pendingGrowth = delta
    }

    func takeMeasuredHeight() {
        heightsTaken += 1
    }

    /// The layout that lands the growth: the card's frame has it, so
    /// nothing is pending.
    func lands() {
        stackFrame?.size.height += pendingGrowth
        pendingGrowth = 0
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
    /// Work the engine scheduled for later, run by the test when it chooses.
    private var scheduled: [@MainActor () -> Void] = []

    private let keyA = ChatScrollSessionKey(profile: "p", sessionID: "a")
    private let keyB = ChatScrollSessionKey(profile: "p", sessionID: "b")

    override func setUp() {
        super.setUp()
        clock = 100
        events = []
        engines = []
        scheduled = []
    }

    /// Runs the main run loop until every block already on the main queue
    /// has run: the queue is FIFO, so a marker queued now runs after them.
    /// The 10s is a cap, not a timing; a fixed 50ms window could expire on a
    /// loaded runner before the queue was serviced at all.
    private func drainMainQueue() {
        let drained = expectation(description: "earlier main-queue blocks ran")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 10)
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
        surface providedSurface: FakeChatScrollSurface? = nil,
        reducedMotion: Bool = false
    ) -> (ChatScrollEngine, FakeChatScrollSurface) {
        let surface = providedSurface ?? FakeChatScrollSurface()
        let engine = ChatScrollEngine(
            now: { [unowned self] in self.clock },
            prefersReducedMotion: { reducedMotion },
            schedule: { [unowned self] _, body in self.scheduled.append(body) }
        )
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

    // MARK: - Blank viewport (#887)

    /// A turn settled into an eleventh message while following; the
    /// viewport (stack 3182...3982) is at the bottom.
    private func settleTurn(
        frames: [String: ChatScrollRowFrame],
        liveTail: Bool = false,
        liveFrames: [String: ChatScrollRowFrame] = [:]
    ) -> (ChatScrollEngine, FakeChatScrollSurface) {
        // The engine holds its surface weakly, so the caller keeps it.
        let (engine, surface) = makeEngine()
        engine.liveTailShowing = { liveTail }
        engine.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1,
            isInitialSync: false
        )
        engine.rowFramesChanged(frames)
        engine.liveRowFramesChanged(liveFrames)
        events = []
        scheduled.forEach { $0() }
        return (engine, surface)
    }

    func testABlankViewportWithTheLatestRowUnlaidRebuildsTheScrollView() {
        let (_, surface) = settleTurn(frames: ["m3": ChatScrollRowFrame(minY: 900, maxY: 1100, order: 3)])
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
        withExtendedLifetime(surface) {}
    }

    /// Eric's #887: the reply was laid out just above the screen and nothing
    /// was drawn below it.
    func testABlankViewportUnderTheLatestRowRebuildsTheScrollView() {
        let (_, surface) = settleTurn(frames: ["m10": ChatScrollRowFrame(minY: 2000, maxY: 3150, order: 10)])
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
        withExtendedLifetime(surface) {}
    }

    func testLiveRowsUnderTheLatestRowAreNotABlankViewport() {
        let (_, surface) = settleTurn(
            frames: ["m10": ChatScrollRowFrame(minY: 2000, maxY: 3150, order: 10)],
            liveTail: true,
            liveFrames: ["streaming": ChatScrollRowFrame(minY: 3162, maxY: 3900, order: .max)]
        )
        XCTAssertFalse(events.contains(.rebuildTranscript))
        withExtendedLifetime(surface) {}
    }

    /// A long reply streaming at the bottom leaves the rows above it unlaid.
    func testLiveRowsUnderAnUnlaidLatestRowAreNotABlankViewport() {
        let (_, surface) = settleTurn(
            frames: ["m3": ChatScrollRowFrame(minY: 900, maxY: 1100, order: 3)],
            liveTail: true,
            liveFrames: ["streaming": ChatScrollRowFrame(minY: 1200, maxY: 3990, order: .max)]
        )
        XCTAssertFalse(events.contains(.rebuildTranscript))
        withExtendedLifetime(surface) {}
    }

    /// #1358: the lazy stack dropped the live rows too while Hermes worked.
    func testUnlaidLiveRowsUnderTheLatestRowAreABlankViewport() {
        let (_, surface) = settleTurn(
            frames: ["m10": ChatScrollRowFrame(minY: 2000, maxY: 3150, order: 10)],
            liveTail: true
        )
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
        withExtendedLifetime(surface) {}
    }

    /// #1358: a turn streaming into its live rows changes no settled
    /// transcript, so its layout passes check.
    func testALayoutPassDuringALiveTurnFindsABlankViewport() {
        let (engine, surface) = makeEngine()
        // Nothing laid out, live rows included.
        engine.liveTailShowing = { true }
        events = []
        scheduled = []
        surface.layOut(contentHeight: 4100)
        surface.layOut(contentHeight: 4200)
        XCTAssertEqual(scheduled.count, 1, "one check at a time")
        scheduled.removeFirst()()
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)

        // The rebuild's own follow-up check, then no rebuild for a while: a
        // rebuild that didn't help isn't redone on every streamed line, but
        // gets one more try once the interval is over.
        scheduled.forEach { $0() }
        scheduled = []
        events = []
        clock += 1
        surface.layOut(contentHeight: 4300)
        scheduled.removeFirst()()
        XCTAssertFalse(events.contains(.rebuildTranscript))
        XCTAssertEqual(scheduled.count, 1, "a retry once the interval is over")
        surface.layOut(contentHeight: 4400)
        XCTAssertEqual(scheduled.count, 1, "still one check at a time")
        clock += ChatScrollEngine.liveBlankViewportRebuildInterval
        scheduled.removeFirst()()
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
    }

    /// A fling moving the content puts the check off, not away.
    func testABlankCheckDuringAFlingWaitsForItToStop() {
        let (engine, surface) = makeEngine()
        engine.liveTailShowing = { true }
        events = []
        scheduled = []
        surface.layOut(contentHeight: 4100)
        surface.isDecelerating = true
        scheduled.removeFirst()()
        XCTAssertFalse(events.contains(.rebuildTranscript))
        XCTAssertEqual(scheduled.count, 1, "checked again after the fling")
        surface.isDecelerating = false
        scheduled.removeFirst()()
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
    }

    /// A stack that dropped its rows may change no size: the live rows'
    /// frames going away checks.
    func testLiveRowsLosingTheirFramesChecksForABlankViewport() {
        let (engine, surface) = makeEngine()
        engine.liveTailShowing = { true }
        engine.liveRowFramesChanged(["streaming": ChatScrollRowFrame(minY: 3200, maxY: 3980, order: .max)])
        events = []
        scheduled = []
        engine.liveRowFramesChanged([:])
        scheduled.forEach { $0() }
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
        withExtendedLifetime(surface) {}
    }

    func testALiveRowLosingItsFrameChecksForABlankViewport() {
        let (engine, surface) = makeEngine()
        engine.liveTailShowing = { true }
        engine.liveRowFramesChanged([
            "thinking": ChatScrollRowFrame(minY: 2000, maxY: 2400, order: .max),
            "streaming": ChatScrollRowFrame(minY: 3200, maxY: 3980, order: .max),
        ])
        events = []
        scheduled = []
        engine.liveRowFramesChanged(["thinking": ChatScrollRowFrame(minY: 2000, maxY: 2400, order: .max)])
        scheduled.forEach { $0() }
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
        withExtendedLifetime(surface) {}
    }

    /// Settled changes share the interval.
    func testASettledChangeSoonAfterARebuildWaitsOutTheInterval() {
        let (engine, surface) = settleTurn(frames: ["m3": ChatScrollRowFrame(minY: 900, maxY: 1100, order: 3)])
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
        scheduled = []
        events = []
        clock += 0.5
        engine.transcriptChanged(
            messages: Self.messages(0..<12),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1,
            isInitialSync: false
        )
        var due = scheduled
        scheduled = []
        due.forEach { $0() }
        XCTAssertFalse(events.contains(.rebuildTranscript))
        XCTAssertFalse(scheduled.isEmpty, "a retry once the interval is over")
        clock += ChatScrollEngine.liveBlankViewportRebuildInterval
        due = scheduled
        scheduled = []
        due.forEach { $0() }
        XCTAssertEqual(events.filter { $0 == .rebuildTranscript }.count, 1)
        withExtendedLifetime(surface) {}
    }

    func testALayoutPassDuringALiveTurnShowingItsRowsDoesNotRebuild() {
        let (engine, surface) = makeEngine()
        engine.liveTailShowing = { true }
        events = []
        scheduled = []
        surface.layOut(contentHeight: 4100)
        engine.liveRowFramesChanged(["streaming": ChatScrollRowFrame(minY: 3500, maxY: 4070, order: .max)])
        scheduled.forEach { $0() }
        XCTAssertFalse(events.contains(.rebuildTranscript))
    }

    func testALayoutPassWithNoLiveTurnDoesNotCheck() {
        let (_, surface) = makeEngine()
        scheduled = []
        surface.layOut(contentHeight: 4100)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testARowOnScreenIsNotABlankViewport() {
        let (_, surface) = settleTurn(frames: ["m10": ChatScrollRowFrame(minY: 3000, maxY: 3700, order: 10)])
        XCTAssertFalse(events.contains(.rebuildTranscript))
        withExtendedLifetime(surface) {}
    }

    func testASessionSwitchCancelsAPendingBlankCheck() {
        let (engine, surface) = makeEngine()
        engine.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1,
            isInitialSync: false
        )
        engine.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        events = []
        scheduled.forEach { $0() }
        XCTAssertFalse(events.contains(.rebuildTranscript))
        withExtendedLifetime(surface) {}
    }

    func testABrowsingReaderIsNotRebuiltUnder() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        XCTAssertEqual(engine.mode, .browsing)
        engine.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1,
            isInitialSync: false
        )
        engine.rowFramesChanged([:])
        events = []
        scheduled.forEach { $0() }
        XCTAssertFalse(events.contains(.rebuildTranscript))
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

    /// Predictive's chips appearing over the composer grow only the bottom
    /// inset (iOS 26's safe-area bar), with no layout pass the surface sees.
    func testFollowingPinsWhenTheBottomBarGrows() {
        let (engine, surface) = makeEngine()
        scheduled.removeAll()
        surface.insetBottom = 52
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3252, "the reply's end stays above the chips")

        // The inset lands after the bar's own layout: the later check pins it.
        surface.insetBottom = 104
        scheduled.forEach { $0() }
        XCTAssertEqual(surface.contentOffsetY, 3304)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testABottomBarGrowingLeavesABrowsingReaderAlone() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        scheduled.removeAll()
        surface.insetBottom = 52
        engine.bottomBarResized()
        scheduled.forEach { $0() }
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testFollowingPinsWhenTheBottomBarShrinks() {
        let (engine, surface) = makeEngine()
        surface.insetBottom = 52
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3252)
        surface.insetBottom = 0
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3200, "no empty space left where the chips were")
        XCTAssertTrue(engine.isFollowingLatest)
    }

    /// A reader just above the bottom, browsing, when the bar shrinks under
    /// them: past the new bottom, but they didn't scroll there.
    func testABottomBarShrinkingLeavesABrowsingReaderBrowsing() {
        let surface = FakeChatScrollSurface()
        surface.insetBottom = 120
        let (engine, _) = makeEngine(surface: surface)
        XCTAssertEqual(surface.contentOffsetY, 3320)
        surface.userScroll(to: 3250)
        XCTAssertEqual(engine.mode, .browsing)
        surface.insetBottom = 0
        engine.bottomBarResized()
        scheduled.forEach { $0() }
        XCTAssertEqual(surface.contentOffsetY, 3200, "moved up to the new bottom: no empty space under the last message")
        XCTAssertEqual(engine.mode, .browsing)
    }

    /// The same shrink reaching the engine first through a layout pass (the
    /// locator laid out with the new inset) still leaves the reader browsing.
    func testABottomBarShrinkingInALayoutPassLeavesABrowsingReaderBrowsing() {
        let surface = FakeChatScrollSurface()
        surface.insetBottom = 120
        let (engine, _) = makeEngine(surface: surface)
        surface.userScroll(to: 3250)
        XCTAssertEqual(engine.mode, .browsing)
        surface.insetBottom = 0
        engine.surfaceLayoutChanged()
        XCTAssertEqual(surface.contentOffsetY, 3200, "moved up to the new bottom")
        XCTAssertEqual(engine.mode, .browsing)
        engine.bottomBarResized()
        scheduled.forEach { $0() }
        XCTAssertEqual(engine.mode, .browsing)
    }

    /// A browsing reader 70 pt above the bottom drags while the bar shrinks
    /// 120 pt: letting go past the new bottom is the bar's doing, so they
    /// are moved up to it and stay browsing.
    func testABottomBarShrinkingUnderADragLeavesTheReaderBrowsing() {
        let surface = FakeChatScrollSurface()
        surface.insetBottom = 120
        let (engine, _) = makeEngine(surface: surface)
        surface.userScroll(to: 3250)
        XCTAssertEqual(engine.mode, .browsing)
        surface.isTracking = true
        engine.userDragBegan()
        surface.insetBottom = 0
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3250, "a finger owns the offset")
        surface.isTracking = false
        engine.userDragEnded()
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertEqual(engine.mode, .browsing)
    }

    /// A following reader nudges the chat a little while the chips appear:
    /// letting go, they follow again, pinned above the chips.
    func testAFollowingReaderDraggingWhileTheBarGrowsFollowsAgain() {
        let (engine, surface) = makeEngine()
        XCTAssertTrue(engine.isFollowingLatest)
        surface.isTracking = true
        engine.userDragBegan()
        surface.contentOffsetY = 3190
        engine.surfaceScrolled()
        surface.insetBottom = 52
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3190, "a finger owns the offset")
        surface.isTracking = false
        engine.userDragEnded()
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    /// A following reader who scrolls well away while the chips appear stays
    /// where they went.
    func testAFollowingReaderScrollingAwayWhileTheBarGrowsStaysBrowsing() {
        let (engine, surface) = makeEngine()
        surface.isTracking = true
        engine.userDragBegan()
        surface.contentOffsetY = 1000
        engine.surfaceScrolled()
        surface.insetBottom = 52
        engine.bottomBarResized()
        surface.isTracking = false
        engine.userDragEnded()
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertEqual(surface.contentOffsetY, 1000)
    }

    /// Just past the near-bottom distance once the chips are counted, but
    /// within it as the chat was when the finger came down: follows again.
    func testAFollowingReaderIsMeasuredAgainstTheBarAtDragStart() {
        let (engine, surface) = makeEngine()
        surface.isTracking = true
        engine.userDragBegan()
        surface.contentOffsetY = 3170
        engine.surfaceScrolled()
        surface.insetBottom = 52
        engine.bottomBarResized()
        surface.isTracking = false
        engine.userDragEnded()
        XCTAssertTrue(engine.isFollowingLatest, "30 pt from the bottom it had; 82 pt from the new one")
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    /// A browsing reader who drags back near the bottom while the chips
    /// appear follows again, the same as with no bar change.
    func testABrowsingReaderDraggingBackNearTheBottomWhileTheBarGrowsFollows() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        XCTAssertEqual(engine.mode, .browsing)
        surface.isTracking = true
        engine.userDragBegan()
        surface.contentOffsetY = 3180
        engine.surfaceScrolled()
        surface.insetBottom = 52
        engine.bottomBarResized()
        surface.isTracking = false
        engine.userDragEnded()
        XCTAssertTrue(engine.isFollowingLatest, "20 pt from the bottom it had")
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    /// The inset went back to a value a bar check saw before, by an
    /// ordinary layout in between: the next bar change is still taken.
    func testABottomBarBackAtAnEarlierInsetStillPins() {
        let (engine, surface) = makeEngine()
        surface.insetBottom = 52
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3252)
        surface.insetBottom = 0
        surface.layOut(contentHeight: 4000)
        XCTAssertEqual(surface.contentOffsetY, 3200)
        surface.insetBottom = 52
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    /// A finger resting on the chat (no scroll) when the chips appear: the
    /// pin waits, and the lift takes it.
    func testABottomBarChangeUnderAFingerPinsWhenItLifts() {
        let (engine, surface) = makeEngine()
        surface.isTracking = true
        surface.insetBottom = 52
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3200, "a finger owns the offset")
        surface.isTracking = false
        engine.userDragEnded()
        XCTAssertEqual(surface.contentOffsetY, 3252)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    /// Chips appearing during a fling that outlasts the retries: the checks
    /// go on until it stops, then the missed inset is taken.
    func testABottomBarChangeDuringAFlingPinsOnceItStops() {
        let (engine, surface) = makeEngine()
        scheduled.removeAll()
        surface.isDecelerating = true
        surface.insetBottom = 52
        engine.bottomBarResized()
        for _ in 0..<5 {
            XCTAssertEqual(scheduled.count, 1, "a check still waits while the fling moves")
            scheduled.removeFirst()()
        }
        XCTAssertEqual(surface.contentOffsetY, 3200, "momentum owns the offset")
        surface.isDecelerating = false
        scheduled.removeFirst()()
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    /// The inset can land after the bar's layout: the checks go on for a few
    /// main-queue turns, one waiting at a time.
    func testBottomBarChecksRetryAFewTurns() {
        let (engine, surface) = makeEngine()
        scheduled.removeAll()
        engine.bottomBarResized()
        var turns = 0
        while !scheduled.isEmpty, turns < 10 {
            let next = scheduled.removeFirst()
            turns += 1
            if turns == 3 { surface.insetBottom = 52 }
            next()
        }
        XCTAssertEqual(turns, ChatScrollEngine.bottomBarCheckDelays.count)
        XCTAssertEqual(surface.contentOffsetY, 3252, "the inset that landed on the last turn is taken")
    }

    func testBottomBarChangesWaitOnOneLaterCheck() {
        let (engine, surface) = makeEngine()
        scheduled.removeAll()
        for inset in [20, 40, 60] as [CGFloat] {
            surface.insetBottom = inset
            engine.bottomBarResized()
        }
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeAll()
        engine.bottomBarResized()
        XCTAssertEqual(scheduled.count, 0, "the chain still waits until its check has run")
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

    func testPastTheBottomCorrectionsCannotLoopWithAnotherWriter() {
        let (engine, surface) = makeEngine()
        surface.contentHeight = 3700
        surface.sets.removeAll()
        // A writer that puts its own offset back after every pin, all within
        // one main-queue turn: one inline correction, no recursion.
        for _ in 0..<10 {
            surface.contentOffsetY = 3200
            engine.surfaceScrolled()
        }
        XCTAssertEqual(surface.sets.count, 1)

        // Once the turn is over, the deferred check leaves it on the bottom.
        drainMainQueue()
        XCTAssertEqual(surface.contentOffsetY, 2900)
        XCTAssertEqual(surface.sets.count, 2)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testATitleTapCancelsAPendingPastTheBottomCheck() {
        let (engine, surface) = makeEngine()
        surface.contentHeight = 3700
        surface.contentOffsetY = 3200
        engine.surfaceScrolled()
        engine.explicitTopRequested()
        XCTAssertEqual(surface.contentOffsetY, surface.minOffsetY)

        drainMainQueue()
        XCTAssertEqual(surface.contentOffsetY, surface.minOffsetY, "the reader asked for the top")
        XCTAssertEqual(engine.mode, .browsing)
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

    // MARK: - Opening and closing rows

    /// Eric's report: opening a Thinking or tool row at the bottom of the
    /// chat jumped far down. Following pinned the content's new bottom, so
    /// the tapped header went off the top and the end of the row showed.
    func testOpeningARowAtTheBottomKeepsTheTappedRowStill() {
        let (engine, surface) = makeEngine()
        XCTAssertEqual(surface.contentOffsetY, 3200)

        engine.userWillToggleRow()
        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 3200, "the row the reader tapped stays where it was")
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(engine.showsJumpToLatest)

        scheduled.forEach { $0() }
        XCTAssertEqual(engine.mode, .browsing, "the reader is reading what they opened")
        surface.layOut(contentHeight: 5000)
        XCTAssertEqual(surface.contentOffsetY, 3200, "new rows below do not pull them away")
    }

    func testOpeningAShortRowAtTheBottomFollowsAgainOnceItHasOpened() {
        let (engine, surface) = makeEngine()
        engine.userWillToggleRow()
        surface.layOut(contentHeight: 4030)
        XCTAssertEqual(surface.contentOffsetY, 3200)

        scheduled.forEach { $0() }
        XCTAssertTrue(engine.isFollowingLatest, "still at the bottom, so still following")
        XCTAssertEqual(surface.contentOffsetY, 3230)
        surface.layOut(contentHeight: 4400)
        XCTAssertEqual(surface.contentOffsetY, 3600)
    }

    func testOnlyTheLatestToggleSettles() {
        let (engine, surface) = makeEngine()
        engine.userWillToggleRow()
        engine.userWillToggleRow()
        surface.layOut(contentHeight: 4020)
        scheduled.forEach { $0() }
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertEqual(surface.sets.filter { $0.y == 3220 }.count, 1, "one settle, one pin")
    }

    func testACommandAfterAToggleCancelsItsSettle() {
        let (engine, surface) = makeEngine()
        engine.userWillToggleRow()
        surface.layOut(contentHeight: 4030)
        engine.explicitMessageRequested(id: "m9")
        XCTAssertEqual(events.last, .revealRow(id: "m9"))

        scheduled.forEach { $0() }
        XCTAssertEqual(engine.mode, .browsing, "the row the reader asked for is not undone by a pin")
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    /// Rows resumed without an id are numbered from 0 in every
    /// conversation, so an opened "0-reasoning" must not open another
    /// conversation's; another spelling of the same one keeps it.
    func testOpenedRowsBelongToTheirConversation() {
        let disclosure = ChatRowDisclosure()
        var current = identity("a")
        disclosure.currentConversation = { current }
        disclosure.willToggle("0-reasoning", to: true)
        XCTAssertTrue(disclosure.isExpanded("0-reasoning", default: false))

        current = ChatScrollSessionIdentity(
            profile: "p",
            canonicalSessionID: "a-server",
            equivalentSessionIDs: ["a", "a-server"],
            isReconciling: false,
            settledRevision: 1
        )
        XCTAssertTrue(disclosure.isExpanded("0-reasoning", default: false), "same conversation, new spelling")

        current = identity("b")
        XCTAssertFalse(disclosure.isExpanded("0-reasoning", default: false), "another conversation")
        XCTAssertTrue(disclosure.isExpanded("0-tool-0", default: true), "defaults apply there")
    }

    /// Show thinking (a run's menu or its reply's ⋯) draws that run's
    /// hidden thoughts, open, for this conversation only; Hide folds them
    /// away again.
    func testShowThinkingRevealsOneRunWhileSettingsHideIt() {
        let disclosure = ChatRowDisclosure()
        var current = identity("a")
        disclosure.currentConversation = { current }
        var preferences = ProfileDisplayPreferences()
        preferences.showReasoning = false
        let thinking = ChatMessage(id: "r", role: .reasoning, content: "Look it up", timestamp: "now")
        let search = ChatMessage(
            id: "t", role: .tool, content: "", timestamp: "now",
            tool: ToolActivity(id: "t", name: "web_search", input: nil, output: nil, status: .complete)
        )
        let group = ChatStepGroup(members: [ChatStepGroupMember(thinking), ChatStepGroupMember(search)], isTrailing: false)
        let thought = ChatStepPlacement(group: group, index: 0)
        let tool = ChatStepPlacement(group: group, index: 1)
        func draws(_ placement: ChatStepPlacement, _ id: String) -> Bool {
            placement.drawsRow(messageID: id, preferences: preferences, isBusy: false, disclosure: disclosure)
        }
        XCTAssertFalse(draws(thought, "r"), "Settings hides the thought")
        XCTAssertTrue(draws(tool, "t"))

        disclosure.willShowThinking(in: group, true)
        XCTAssertTrue(disclosure.showsThinking(in: "r"))
        XCTAssertTrue(draws(thought, "r"))
        XCTAssertTrue(draws(tool, "t"), "the run opens, so its other rows draw too")
        XCTAssertTrue(disclosure.isExpanded("r", default: false), "the thought opens on its text")

        disclosure.willShowThinking(in: group, false)
        XCTAssertFalse(draws(thought, "r"))
        XCTAssertFalse(disclosure.isGroupExpanded("r", default: false), "the run folds back as it was")
        XCTAssertFalse(disclosure.isExpanded("r", default: false), "and so does the thought")

        // A run the reader had open stays open after Hide thinking.
        disclosure.willToggleGroup("r", to: true)
        disclosure.willShowThinking(in: group, true)
        disclosure.willShowThinking(in: group, false)
        XCTAssertTrue(disclosure.isGroupExpanded("r", default: false))
        XCTAssertFalse(disclosure.isExpanded("r", default: false))

        // Thinking set to Off: no run shows its thinking, asked for or not.
        disclosure.willShowThinking(in: group, true)
        preferences.thinkingOnRequest = false
        XCTAssertFalse(preferences.offersShowThinking)
        XCTAssertFalse(draws(thought, "r"))
        preferences.thinkingOnRequest = true

        current = identity("b")
        XCTAssertFalse(disclosure.showsThinking(in: "r"), "another conversation starts hidden")
    }

    /// A revealed run counts the steps Settings shows, or its thoughts when
    /// Settings shows none of them, never "0 steps".
    func testARevealedRunCountsTheStepsItShows() {
        let thinking = ChatMessage(id: "r", role: .reasoning, content: "Look it up", timestamp: "now")
        let search = ChatMessage(
            id: "t", role: .tool, content: "", timestamp: "now",
            tool: ToolActivity(id: "t", name: "web_search", input: nil, output: nil, status: .complete)
        )
        let group = ChatStepGroup(members: [ChatStepGroupMember(thinking), ChatStepGroupMember(search)], isTrailing: false)
        func counted(showTools: Bool) -> [String] {
            group.countedMembers(showReasoning: false, thinkingShown: true, showTools: showTools).map(\.messageID)
        }
        XCTAssertEqual(counted(showTools: true), ["t"], "the tools Settings shows, the revealed thought aside")
        XCTAssertEqual(counted(showTools: false), ["r"], "with no tools shown, the revealed thought")
        XCTAssertEqual(group.countedMembers(showReasoning: false, thinkingShown: false, showTools: true).map(\.messageID), ["t"])
    }

    /// Settings > Chat's Thinking: Show is Hermes' own switch, Conduit's key
    /// tells On request from Off, and an install with the switch off keeps
    /// its Show thinking menus.
    func testThinkingChoiceReadsAndWritesTwoConfigValues() {
        XCTAssertEqual(ReasoningDisplayMode(display: [:]), .show)
        XCTAssertEqual(ReasoningDisplayMode(display: ["show_reasoning": true, "conduit_thinking_on_request": false]), .show)
        XCTAssertEqual(ReasoningDisplayMode(display: ["show_reasoning": false]), .onRequest, "off before the choice maps to On request")
        XCTAssertEqual(ReasoningDisplayMode(display: ["show_reasoning": false, "conduit_thinking_on_request": false]), .off)

        for mode in ReasoningDisplayMode.allCases {
            var display: [String: Any] = ["show_reasoning": true, "conduit_thinking_on_request": false]
            mode.write(into: &display)
            XCTAssertEqual(ReasoningDisplayMode(display: display), mode)
        }
        var display: [String: Any] = ["conduit_thinking_on_request": false]
        ReasoningDisplayMode.show.write(into: &display)
        XCTAssertEqual(display["conduit_thinking_on_request"] as? Bool, false, "Show leaves Conduit's key alone")
    }

    func testClosingARowAtTheBottomLeavesNoEmptySpace() {
        let (engine, surface) = makeEngine()
        engine.userWillToggleRow()
        surface.layOut(contentHeight: 3600)
        XCTAssertEqual(surface.contentOffsetY, 2800, "the shorter content sits on the bottom")
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testAToggleUnderAFingerChangesNothing() {
        let (engine, surface) = makeEngine()
        surface.isTracking = true
        engine.userWillToggleRow()
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertTrue(scheduled.isEmpty)
    }

    // MARK: - Browsing

    /// A reader just above the bottom whose content shrinks (a row closing,
    /// a turn's live rows settling) is left over empty space that UIKit
    /// never closes on its own.
    func testABrowsingReaderLeftPastTheBottomReturnsToTheLatestMessage() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3000)
        XCTAssertEqual(engine.mode, .browsing)

        surface.layOut(contentHeight: 3500)
        XCTAssertEqual(surface.contentOffsetY, 2700)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testDraggingAwayStopsFollowingAndNewContentLeavesTheReaderAlone() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(engine.showsJumpToLatest)

        surface.layOut(contentHeight: 4800)
        XCTAssertEqual(surface.contentOffsetY, 1000, "rows arriving below never move the reader")
        XCTAssertTrue(events.contains(.flushPersistence))
    }

    func testAppendingPendingClarifyDoesNotAutoScrollWhileBrowsing() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        let pendingQuestion = ChatMessage(
            id: "clarify-pending",
            role: .clarify,
            content: "Continue?",
            timestamp: "2026-01-01T00:00:00Z",
            clarify: ClarifyActivity(
                requestId: "request-1",
                question: "Continue?",
                choices: [],
                status: .pending
            )
        )

        engine.transcriptChanged(
            messages: Self.messages(0..<10) + [pendingQuestion],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )

        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(engine.showsJumpToLatest)
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

        // No row frame ever confirms the reader's place here, so the hold
        // gives up at its limit; a later change is ordinary browsing again.
        clock += ChatScrollEngine.prependSettleLimit
        surface.layOut(contentHeight: 4700)
        XCTAssertEqual(surface.contentOffsetY, 1050)
        XCTAssertNil(engine.prependAnchor)
    }

    /// A busy main thread can put the layout of the prepended page, and
    /// SwiftUI's own offset write after it, seconds after the landing.
    func testPrependHoldsThroughALateLayout() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 500)
        engine.olderPageBackfillRequested(sessionKey: keyA)

        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        clock += 2
        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 1100)

        // SwiftUI writes its own offset in a later pass.
        clock += 1
        surface.contentOffsetY = 300
        engine.surfaceScrolled()
        XCTAssertEqual(surface.contentOffsetY, 1100, "the reader is put back")
        XCTAssertNotNil(engine.prependAnchor)
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

    /// The estimate can leave the reader's top row just off screen, where it
    /// reports no frame; any row that was on screen refines the position.
    func testPrependRefinesThroughALowerRowWhenTheTopRowHasNoFrame() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 500)
        engine.rowFramesChanged([
            "m2": ChatScrollRowFrame(minY: 492, maxY: 700, order: 2),
            "m3": ChatScrollRowFrame(minY: 700, maxY: 900, order: 3),
        ])
        engine.olderPageBackfillRequested(sessionKey: keyA)

        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 1100)

        engine.rowFramesChanged(["m3": ChatScrollRowFrame(minY: 1260, maxY: 1460, order: 8)])
        XCTAssertEqual(surface.contentOffsetY, 1060, "m3 is back where it was, and m2 above it")
    }

    /// Once the reader's row is in place by its own frame, the hold lasts
    /// `prependHoldDuration` more, for heights still settling.
    func testPrependHoldEndsShortlyAfterTheReadersRowIsInPlace() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 500)
        engine.rowFramesChanged(["m2": ChatScrollRowFrame(minY: 492, maxY: 700, order: 2)])
        engine.olderPageBackfillRequested(sessionKey: keyA)

        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.layOut(contentHeight: 4600)
        XCTAssertNil(engine.prependAnchor?.settledAt, "the bottom-distance estimate alone confirms nothing")

        engine.rowFramesChanged(["m2": ChatScrollRowFrame(minY: 1052, maxY: 1260, order: 7)])
        XCTAssertEqual(surface.contentOffsetY, 1060)
        XCTAssertEqual(engine.prependAnchor?.settledAt, clock, "confirmed once the correction lands")

        // Within the tail the hold still answers another writer, and the
        // tail starts again from that correction.
        clock += 0.4
        surface.contentOffsetY = 300
        engine.surfaceScrolled()
        XCTAssertEqual(surface.contentOffsetY, 1060)
        XCTAssertEqual(engine.prependAnchor?.settledAt, clock)

        clock += ChatScrollEngine.prependHoldDuration + 0.1
        surface.layOut(contentHeight: 4700)
        XCTAssertNil(engine.prependAnchor)
        XCTAssertEqual(surface.contentOffsetY, 1060, "a later change is ordinary browsing again")
    }

    /// A confirmation that comes late still gets its tail past the limit
    /// that bounds an unconfirmed hold, and a correction in that tail
    /// restarts it, but nothing outlives the limit plus one tail.
    func testPrependHoldKeepsALateConfirmationsTailUpToItsCeiling() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 500)
        engine.rowFramesChanged(["m2": ChatScrollRowFrame(minY: 492, maxY: 700, order: 2)])
        engine.olderPageBackfillRequested(sessionKey: keyA)

        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.layOut(contentHeight: 4600)
        XCTAssertEqual(surface.contentOffsetY, 1100)

        // The reader's row reports its new frame late.
        clock += ChatScrollEngine.prependSettleLimit - 0.4
        engine.rowFramesChanged(["m2": ChatScrollRowFrame(minY: 1052, maxY: 1260, order: 7)])
        XCTAssertEqual(surface.contentOffsetY, 1060)
        XCTAssertEqual(engine.prependAnchor?.settledAt, clock)

        // Past the limit, within the tail: another writer is undone, and so
        // is its follow-up write.
        clock += 0.5
        surface.contentOffsetY = 300
        engine.surfaceScrolled()
        XCTAssertEqual(surface.contentOffsetY, 1060)
        clock += 0.3
        surface.contentOffsetY = 2000
        engine.surfaceScrolled()
        XCTAssertEqual(surface.contentOffsetY, 1060)

        // Past the limit plus one tail the hold is over.
        clock += 0.3
        surface.contentOffsetY = 2000
        engine.surfaceScrolled()
        XCTAssertNil(engine.prependAnchor)
        XCTAssertEqual(surface.contentOffsetY, 2000)
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

    private func messagesWithClarify(
        status: ClarifyQuestion.Status,
        answer: String? = nil
    ) -> [ChatMessage] {
        var messages = Self.messages(0..<10)
        messages[5] = ChatMessage(
            id: "m5",
            role: .clarify,
            content: "Continue?",
            timestamp: "2026-01-01T00:00:00Z",
            clarify: ClarifyActivity(
                requestId: "request-m5",
                question: "Continue?",
                choices: [],
                status: status,
                answer: answer
            )
        )
        return messages
    }

    private func pendingClarifyRequest(
        _ engine: ChatScrollEngine,
        row index: Int,
        fallbackRow fallbackIndex: Int,
        generation: UInt64 = 9
    ) -> ChatResumeRestorationRequest {
        let target = engine.targets[index]
        let fallback = engine.targets[fallbackIndex]
        return ChatResumeRestorationRequest(
            generation: generation,
            sessionKey: keyA,
            destination: .pendingClarify(
                messageID: target.id,
                fallbackSnapshot: ChatScrollSnapshot(
                    anchorMessageID: fallback.semanticID,
                    followsLatest: false,
                    anchorMetadata: fallback.restorationMetadata,
                    anchorSourceMessageID: fallback.id
                )
            )
        )
    }

    func testPendingClarifyRestorationOverridesSavedViewport() {
        let (engine, surface) = makeEngine()
        surface.insetTop = 50
        engine.transcriptChanged(
            messages: messagesWithClarify(status: .pending),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        engine.rowFramesChanged([
            "m2": ChatScrollRowFrame(minY: 300, maxY: 400, order: 2),
            "m5": ChatScrollRowFrame(minY: 1000, maxY: 1200, order: 5)
        ])
        engine.restorationRequested(pendingClarifyRequest(engine, row: 5, fallbackRow: 2))

        XCTAssertTrue(engine.restorationTick(transcriptRevision: 2))
        XCTAssertEqual(surface.contentOffsetY, 968, "the pending question takes priority over m2")
        XCTAssertFalse(engine.restorationTick(transcriptRevision: 2))
        XCTAssertEqual(engine.topVisibleMessageID, "m5")
    }

    func testAnsweredPendingClarifyFallsBackToSavedViewportBeforePlacement() {
        let (engine, surface) = makeEngine()
        surface.insetTop = 50
        engine.transcriptChanged(
            messages: messagesWithClarify(status: .pending),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        engine.rowFramesChanged([
            "m2": ChatScrollRowFrame(minY: 300, maxY: 400, order: 2),
            "m5": ChatScrollRowFrame(minY: 1000, maxY: 1200, order: 5)
        ])
        engine.restorationRequested(pendingClarifyRequest(engine, row: 5, fallbackRow: 2))

        engine.transcriptChanged(
            messages: messagesWithClarify(status: .answered, answer: "yes"),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )

        XCTAssertTrue(engine.restorationTick(transcriptRevision: 3))
        XCTAssertEqual(surface.contentOffsetY, 268, "a resolved card should not replace the saved viewport")
        XCTAssertFalse(engine.restorationTick(transcriptRevision: 3))
        XCTAssertEqual(engine.topVisibleMessageID, "m2")
    }

    func testMissingPendingClarifyFallsBackToSavedViewport() {
        let (engine, surface) = makeEngine()
        engine.rowFramesChanged([
            "m2": ChatScrollRowFrame(minY: 300, maxY: 400, order: 2)
        ])
        let fallback = engine.targets[2]
        engine.restorationRequested(ChatResumeRestorationRequest(
            generation: 10,
            sessionKey: keyA,
            destination: .pendingClarify(
                messageID: "missing-question",
                fallbackSnapshot: ChatScrollSnapshot(
                    anchorMessageID: fallback.semanticID,
                    followsLatest: false,
                    anchorMetadata: fallback.restorationMetadata,
                    anchorSourceMessageID: fallback.id
                )
            )
        ))

        XCTAssertTrue(engine.restorationTick(transcriptRevision: 1))
        XCTAssertEqual(surface.contentOffsetY, 318, "m2 remains the fallback anchor")
        XCTAssertFalse(engine.restorationTick(transcriptRevision: 1))
        XCTAssertEqual(engine.topVisibleMessageID, "m2")
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

    func testExplicitMessageRequestRevealsTheExactRowWhileBrowsing() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        events = []

        engine.explicitMessageRequested(id: "m5")

        XCTAssertTrue(events.contains(.revealRow(id: "m5")))
        XCTAssertEqual(surface.contentOffsetY, 1000, "the view routes the row reveal; the engine does not jump to latest")
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testExplicitMessageRequestDoesNotOverrideAFingerOnTheScreen() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 1000)
        surface.isTracking = true
        events = []

        engine.explicitMessageRequested(id: "m5")

        XCTAssertFalse(events.contains(.revealRow(id: "m5")))
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testMissingExplicitMessageDoesNotCancelRestoration() {
        let (engine, _) = makeEngine()
        engine.restorationRequested(anchorRequest(engine, row: 5))
        events = []

        engine.explicitMessageRequested(id: "not-in-transcript")

        XCTAssertEqual(engine.mode, .restoring)
        XCTAssertFalse(events.contains(.cancelAutomaticRestoration))
        XCTAssertFalse(events.contains(.revealRow(id: "not-in-transcript")))
    }

    func testValidExplicitMessageCancelsRestorationAndRevealsTheRow() {
        let (engine, _) = makeEngine()
        engine.restorationRequested(anchorRequest(engine, row: 5))
        events = []

        engine.explicitMessageRequested(id: "m5")

        XCTAssertNil(engine.restoration)
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(events.contains(.cancelAutomaticRestoration))
        XCTAssertTrue(events.contains(.revealRow(id: "m5")))
    }

    func testExplicitMessageRequestWhilePausedDoesNotCancelRestoration() {
        let (engine, _) = makeEngine()
        engine.restorationRequested(anchorRequest(engine, row: 5))
        engine.setPaused(true)
        events = []

        engine.explicitMessageRequested(id: "m5")

        XCTAssertEqual(engine.mode, .restoring)
        XCTAssertFalse(events.contains(.cancelAutomaticRestoration))
        XCTAssertFalse(events.contains(.revealRow(id: "m5")))
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

    // MARK: - Cards taking their measured height (#1238)

    /// A reader browsing at 2000: the viewport covers stack 1982...2782.
    private func browsingReader() -> (ChatScrollEngine, FakeChatScrollSurface) {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 2000)
        XCTAssertEqual(engine.mode, .browsing)
        surface.sets = []
        return (engine, surface)
    }

    private func runScheduled() {
        let blocks = scheduled
        scheduled = []
        blocks.forEach { $0() }
    }

    func testACardAboveTheReaderTakesItsHeightWithoutMovingThem() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        XCTAssertEqual(card.heightsTaken, 1, "at rest the card takes its height at once")
        XCTAssertEqual(surface.contentOffsetY, 2000, "the offset moves in the layout pass, not before it")

        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2227, "the pass that lands the growth moves the reader by it")
        XCTAssertEqual(surface.sets.map { $0.animated }, [false])
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testACardOnScreenGrowsBelowWhatTheReaderLooksAt() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 2100)
        engine.cardMeasured(card)
        XCTAssertEqual(card.heightsTaken, 1)
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    func testACardShrinkingAboveTheReaderMovesThemUpButNotPastTheTop() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 100)
        let card = FakeMeasuredCard(delta: -227, minY: 10)
        engine.cardMeasured(card)
        card.lands()
        surface.layOut(contentHeight: 3773)
        XCTAssertEqual(surface.contentOffsetY, 0, "clamped at the top")
    }

    func testACardGrowingAboveAReaderNearTheEndTakesTheRestWithTheContentSize() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3100)
        XCTAssertEqual(engine.mode, .browsing, "100 pt from the end")
        surface.sets = []
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // Its frame reports before the content size: the move goes as far
        // as the content's old end.
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertEqual(engine.mode, .browsing, "that end isn't the pass's yet")
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.sets.map { $0.y }, [3200, 3327], "the rest, with the pass's content size")
        XCTAssertTrue(engine.cardShifts.isEmpty)
        runScheduled()
        XCTAssertEqual(engine.mode, .browsing, "still 100 pt from the end")
        XCTAssertEqual(surface.contentOffsetY, 3327)
    }

    func testACardGrowingAboveAReaderNearTheEndNeverRelatchesThemOnAStaleEnd() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 2940)
        XCTAssertEqual(engine.mode, .browsing, "260 pt from the end")
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // Moved by 227 before the content grows, the reader ends 33 pt from
        // its old end, close enough to relatch following.
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.contentOffsetY, 3167)
        XCTAssertEqual(engine.mode, .browsing)
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 3167)
        runScheduled()
        XCTAssertEqual(engine.mode, .browsing, "260 pt from the pass's end")
    }

    func testAGrowthNearTheEndLandsWholeAfterAnEarlierPassGrewTheContent() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3100)
        surface.sets = []
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // A reply streaming below lays out a pass before the one that lands
        // the card.
        surface.layOut(contentHeight: 4001)
        XCTAssertTrue(surface.sets.isEmpty)
        // That one reports the card's frame before its content size.
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.contentOffsetY, 3201, "as far as the end as it stands")
        surface.layOut(contentHeight: 4228)
        XCTAssertEqual(surface.sets.map { $0.y }, [3201, 3327], "the whole growth, once the room comes")
        XCTAssertTrue(engine.cardShifts.isEmpty)
        runScheduled()
        XCTAssertEqual(engine.mode, .browsing, "101 pt from the end")
    }

    func testAGrowthWhosePassLeavesTheContentSizeUnchangedStillLands() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 2960)
        surface.sets = []
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // Rows below fold by as much as the card grows: the content size
        // stays, so the pass reports only the card's frame.
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.sets.map { $0.y }, [3187])
        XCTAssertTrue(engine.cardShifts.isEmpty)
        XCTAssertEqual(engine.mode, .browsing)
        runScheduled()
        XCTAssertEqual(engine.mode, .following, "13 pt from the end, they follow again")
        XCTAssertEqual(surface.contentOffsetY, 3187)
    }

    func testAGrowthWithNoRoomLeftTakesTheReaderToTheEndAndTheyFollow() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3100)
        surface.sets = []
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // Rows below fold by as much as the card grows: the reader's rows
        // can't stay where they were, and the end is as far as they go.
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.sets.map { $0.y }, [3200])
        XCTAssertEqual(engine.mode, .browsing)
        runScheduled()
        XCTAssertEqual(engine.mode, .following)
        surface.layOut(contentHeight: 4050)
        XCTAssertEqual(surface.contentOffsetY, 3250, "a reply streaming in later is followed")
    }

    func testACardGrowingAboveTheReaderWhileRowsBelowShrinkStillMovesThem() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        card.lands()
        // The same pass folds a finished turn's steps below the reader: the
        // content shrank, though the card above them grew.
        surface.layOut(contentHeight: 3927)
        XCTAssertEqual(surface.contentOffsetY, 2227)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAGrowthAboveAReaderNearTheEndLandsWhileRowsBelowShrink() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3100)
        XCTAssertEqual(engine.mode, .browsing, "100 pt from the end")
        surface.sets = []
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // Its frame reports first: the move goes as far as the old end.
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.sets.map { $0.y }, [3200])
        // The same pass folds a finished turn's steps below the reader: the
        // content grew by less than the card did.
        surface.layOut(contentHeight: 4147)
        XCTAssertEqual(surface.sets.map { $0.y }, [3200, 3327], "moved by the card's growth")
        XCTAssertTrue(engine.cardShifts.isEmpty)
        XCTAssertEqual(engine.mode, .browsing)
        runScheduled()
        XCTAssertEqual(engine.mode, .following, "left 20 pt from the end, they follow again")
        XCTAssertEqual(surface.contentOffsetY, 3327)
    }

    func testAGrowthWhoseFrameReportsAfterAContentSizeThatShrankBelowStillLands() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3100)
        surface.sets = []
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // The pass reports the content size first, grown by less than the
        // card because rows below folded, then the card's frame.
        surface.layOut(contentHeight: 4147)
        XCTAssertTrue(surface.sets.isEmpty)
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.sets.map { $0.y }, [3327])
        XCTAssertTrue(engine.cardShifts.isEmpty)
        XCTAssertEqual(engine.mode, .browsing)
        runScheduled()
        XCTAssertEqual(engine.mode, .following, "20 pt from the end")
    }

    func testACardShrinkingAboveTheReaderWhileAReplyStreamsBelowMovesThemUp() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: -100, minY: 1000)
        engine.cardMeasured(card)
        card.lands()
        // The same pass lays out more of a reply below the reader: the
        // content grew, though the card above them shrank.
        surface.layOut(contentHeight: 4200)
        XCTAssertEqual(surface.contentOffsetY, 1900, "moved up by the card's shrink")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAGrowthNearTheEndAndAShrinkAfterItInTheSamePassAddUp() {
        let (engine, surface) = makeEngine()
        surface.userScroll(to: 3100)
        XCTAssertEqual(engine.mode, .browsing, "100 pt from the end")
        surface.sets = []
        let growing = FakeMeasuredCard(delta: 227, minY: 1000)
        let shrinking = FakeMeasuredCard(delta: -150, minY: 1500)
        engine.cardMeasured(growing)
        engine.cardMeasured(shrinking)
        // One pass lands both, their frames reported before the content
        // size. The growth goes as far as the content's old end and owes
        // the rest, which the shrink after it more than takes back.
        growing.lands()
        engine.cardFrameChanged(growing)
        shrinking.lands()
        engine.cardFrameChanged(shrinking)
        XCTAssertEqual(surface.sets.map { $0.y }, [3200, 3177])
        XCTAssertTrue(engine.cardShifts.isEmpty)
        surface.layOut(contentHeight: 4077)
        XCTAssertEqual(surface.contentOffsetY, 3177, "moved by both")
        runScheduled()
        XCTAssertEqual(engine.mode, .browsing, "still 100 pt from the end")
    }

    func testCardsMeasuredDuringAFlingWaitForItToRest() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        let above = FakeMeasuredCard(delta: 227, minY: 1000)
        let below = FakeMeasuredCard(delta: 100, minY: 3000)
        engine.cardMeasured(above)
        engine.cardMeasured(below)
        XCTAssertEqual(above.heightsTaken + below.heightsTaken, 0, "no height changes under a fling")

        // The check after a tick finds the fling still running.
        runScheduled()
        XCTAssertEqual(above.heightsTaken, 0)

        // The last tick can still report the deceleration; the check after
        // it finds the rest.
        surface.contentOffsetY = 1800
        engine.surfaceScrolled()
        XCTAssertFalse(scheduled.isEmpty)
        surface.isDecelerating = false
        runScheduled()
        XCTAssertEqual(above.heightsTaken, 1)
        XCTAssertEqual(below.heightsTaken, 1)

        above.lands()
        below.lands()
        surface.layOut(contentHeight: 4327)
        XCTAssertEqual(surface.contentOffsetY, 2027, "moved by the card above the reader only")
    }

    func testACardMeasuredUnderAFingerWaitsForTheLift() {
        let (engine, surface) = browsingReader()
        surface.isTracking = true
        engine.userDragBegan()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        XCTAssertEqual(card.heightsTaken, 0)
        surface.contentOffsetY = 1950
        engine.surfaceScrolled()
        surface.isTracking = false
        engine.userDragEnded()
        XCTAssertEqual(card.heightsTaken, 0, "not inside the gesture callback")
        runScheduled()
        XCTAssertEqual(card.heightsTaken, 1)

        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2177)
    }

    func testFollowingTakesACardsHeightAtOnceAndPinsAsBefore() {
        let (engine, surface) = makeEngine()
        XCTAssertTrue(engine.isFollowingLatest)
        let card = FakeMeasuredCard(delta: 300, minY: 100)
        engine.cardMeasured(card)
        XCTAssertEqual(card.heightsTaken, 1)
        XCTAssertTrue(engine.cardShifts.isEmpty)
        card.lands()
        surface.layOut(contentHeight: 4300)
        XCTAssertEqual(surface.contentOffsetY, 3500, "the pin, with nothing added to it")
    }

    func testAJumpToTheTopDropsAGrowthStillWaiting() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        engine.explicitTopRequested()
        XCTAssertEqual(surface.contentOffsetY, 0)
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 0, "the growth was owed to the place the reader left")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAJumpToAMessageDropsAGrowthStillWaiting() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        engine.explicitMessageRequested(id: "m5")
        XCTAssertTrue(engine.cardShifts.isEmpty, "the growth was owed to the place the reader leaves")
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2000, "the jump places the reader, not the card")
    }

    func testADragDropsAnAnnouncedGrowth() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        surface.userScroll(to: 1500)
        surface.sets = []
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 1500, "the reader took over")
        XCTAssertTrue(surface.sets.isEmpty)
    }

    func testAnAnnouncedGrowthWaitsForTheLayoutThatLandsIt() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // An inset change re-lays out before the growth lands.
        surface.layOut(contentHeight: 4000)
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertFalse(engine.cardShifts.isEmpty)
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2227)
    }

    func testAnAnnouncedGrowthThatNeverLandsIsDropped() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        clock += ChatScrollEngine.cardGrowthDeadline + 0.1
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testTwoCardsAboveTheReaderAddUp() {
        let (engine, surface) = browsingReader()
        let first = FakeMeasuredCard(delta: 227, minY: 1000)
        let second = FakeMeasuredCard(delta: 381, minY: 1500)
        engine.cardMeasured(first)
        engine.cardMeasured(second)
        first.lands()
        second.lands()
        surface.layOut(contentHeight: 4608)
        XCTAssertEqual(surface.contentOffsetY, 2608)
    }

    func testTwoCardsLandingInSeparatePassesMoveTheReaderTwice() {
        let (engine, surface) = browsingReader()
        let first = FakeMeasuredCard(delta: 227, minY: 1000)
        let second = FakeMeasuredCard(delta: 381, minY: 1500)
        engine.cardMeasured(first)
        engine.cardMeasured(second)
        first.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2227, "the first card's growth; the second still waits")
        second.lands()
        surface.layOut(contentHeight: 4608)
        XCTAssertEqual(surface.contentOffsetY, 2608)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testACardReportingTwiceBeforeALayoutMovesTheReaderOnce() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // Its page reports again before the layout lands the first height:
        // 381 taller than its frame, still at 280.
        card.pendingGrowth = 381
        engine.cardMeasured(card)
        XCTAssertEqual(card.heightsTaken, 2)
        XCTAssertEqual(engine.cardShifts.count, 1, "one shift, from the card's height before the first")
        card.lands()
        surface.layOut(contentHeight: 4381)
        XCTAssertEqual(surface.contentOffsetY, 2381, "the card grew by 381 once")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testACardReportingBackToItsHeightBeforeALayoutMovesNobody() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        card.pendingGrowth = 0
        engine.cardMeasured(card)
        XCTAssertTrue(engine.cardShifts.isEmpty, "the card keeps its height")
        // A reply streaming in below the reader.
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    func testACardReportingAgainAfterItsGrowthLandedMovesTheReaderAgain() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2227)
        card.pendingGrowth = 154
        engine.cardMeasured(card)
        card.lands()
        surface.layOut(contentHeight: 4381)
        XCTAssertEqual(surface.contentOffsetY, 2381, "the second growth, from the height the first landed")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testGrowthBelowTheReaderNeverPassesForACardAboveThem() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        // A reply streaming in grows the content below the reader first.
        surface.layOut(contentHeight: 4300)
        XCTAssertEqual(surface.contentOffsetY, 2000, "nothing above the reader has grown")
        XCTAssertTrue(surface.sets.isEmpty)
        card.lands()
        surface.layOut(contentHeight: 4527)
        XCTAssertEqual(surface.contentOffsetY, 2227, "the card's own growth, once it lands")
    }

    func testACardWhoseFrameReportsAfterTheContentSizeStillMovesTheReader() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2000, "the content grew; the card hasn't reported its frame yet")
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.contentOffsetY, 2227)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testACardNotLaidOutYetTakesItsHeightPlainly() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        card.stackFrame = nil
        engine.cardMeasured(card)
        XCTAssertEqual(card.heightsTaken, 1)
        XCTAssertTrue(engine.cardShifts.isEmpty)
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2000)
    }

    func testTheReaderMovesByWhatTheCardGrewNotWhatItAnnounced() {
        let (engine, surface) = browsingReader()
        let card = FakeMeasuredCard(delta: 200, minY: 1000, height: 44)
        engine.cardMeasured(card)
        // A picture's height comes from its layout: 190, not the 200 it
        // was expected to take.
        card.stackFrame?.size.height = 234
        surface.layOut(contentHeight: 4190)
        XCTAssertEqual(surface.contentOffsetY, 2190)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testCardsWaitingWhenTheChatLeavesTakeTheirHeights() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        XCTAssertEqual(card.heightsTaken, 0)
        engine.viewDisappeared()
        XCTAssertEqual(card.heightsTaken, 1, "kept with the view, it doesn't wait for a rest that never comes")
        XCTAssertTrue(engine.cardShifts.isEmpty, "nobody to keep still")
    }

    func testACardGoneBeforeItsGrowthLandsIsDropped() {
        let (engine, surface) = browsingReader()
        var card: FakeMeasuredCard? = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card!)
        // Its row left the lazy stack before the pass that would land it.
        card = nil
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testACardGoneBeforeTheFlingRestsIsSkipped() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        var card: FakeMeasuredCard? = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card!)
        // Its row left the lazy stack.
        card = nil
        surface.isDecelerating = false
        runScheduled()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 1900, "nothing announced for a card that is gone")
    }

    func testASessionSwitchForgetsTheWaitingCards() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        surface.isDecelerating = false
        engine.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        runScheduled()
        XCTAssertEqual(card.heightsTaken, 0)
    }

    func testACardMeasuredInTheBackgroundKeepsItsRoomUntilTheAppIsBack() {
        let (engine, surface) = browsingReader()
        engine.setPaused(true)
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        runScheduled()
        XCTAssertEqual(card.heightsTaken, 0, "the background leaves the offset alone, so the card waits")

        engine.setPaused(false)
        XCTAssertEqual(card.heightsTaken, 0, "it takes its height at the rest check")
        runScheduled()
        XCTAssertEqual(card.heightsTaken, 1)
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2227, "moved by the growth above them")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testACardAboveTheReaderWhileEarlierMessagesLoadStillMovesThem() {
        let (engine, surface) = browsingReader()
        engine.olderPageBackfillRequested(sessionKey: keyA)
        XCTAssertNotNil(engine.prependAnchor)
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2227, "a request still loading holds nothing yet")
        // Nothing came back: there is no hold to put the reader back.
        engine.prependAnchorDischarged(matching: keyA)
        XCTAssertNil(engine.prependAnchor)
        XCTAssertEqual(surface.contentOffsetY, 2227)
    }

    func testALandedPageOfEarlierMessagesTakesOverAGrowthStillWaiting() {
        let (engine, surface) = browsingReader()
        engine.olderPageBackfillRequested(sessionKey: keyA)
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        // The page and the card's growth land in one pass, the card's
        // frame reported after the content size.
        surface.layOut(contentHeight: 4827)
        XCTAssertEqual(surface.contentOffsetY, 2827, "the hold keeps the reader's distance from the bottom")
        card.lands()
        engine.cardFrameChanged(card)
        XCTAssertEqual(surface.contentOffsetY, 2827, "the hold has the card's growth in it already")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testACardAboveTheReaderOnceAPageOfEarlierMessagesStopsHoldingMovesThem() {
        let (engine, surface) = browsingReader()
        engine.olderPageBackfillRequested(sessionKey: keyA)
        engine.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertNotNil(engine.prependAnchor?.landedAt)
        // Its hold lapses with no layout or scroll to clear it.
        clock += ChatScrollEngine.prependSettleLimit + ChatScrollEngine.prependHoldDuration + 0.1
        let card = FakeMeasuredCard(delta: 227, minY: 1000)
        engine.cardMeasured(card)
        XCTAssertEqual(engine.cardShifts.count, 1, "nothing holds the reader's rows any more")
        card.lands()
        surface.layOut(contentHeight: 4227)
        XCTAssertEqual(surface.contentOffsetY, 2227, "moved by the growth above them")
        XCTAssertNil(engine.prependAnchor)
    }

    // MARK: - Pictures and failures arriving in their rows (#1238)

    func testAPictureArrivingAboveTheReaderWaitsForTheFlingAndMovesThemWithIt() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        let arrival = ChatRowArrival()
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 44)
        var shown = 0
        arrival.arrive(rowHeight: 244, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 0, "the loading line stays under the fling")

        surface.isDecelerating = false
        runScheduled()
        XCTAssertEqual(shown, 1)
        // The row grows with the picture in it, its frame reported before
        // the content size.
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 244)
        XCTAssertEqual(surface.contentOffsetY, 2100, "moved by the row's growth")
        surface.layOut(contentHeight: 4200)
        XCTAssertEqual(surface.contentOffsetY, 2100, "once")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAPictureArrivingTwiceBeforeALayoutMovesTheReaderOnce() {
        let (engine, surface) = browsingReader()
        let arrival = ChatRowArrival()
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 44)
        var shown = 0
        arrival.arrive(rowHeight: 244, engine: engine) { shown += 1 }
        // Another arrives before the row is laid out with the first.
        arrival.arrive(rowHeight: 344, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 2)
        XCTAssertEqual(engine.cardShifts.count, 1, "one shift, from the row's height before the first")
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 344)
        surface.layOut(contentHeight: 4300)
        XCTAssertEqual(surface.contentOffsetY, 2300, "the row grew by 300 once")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAPictureArrivingTwiceDuringAFlingMovesTheReaderOnceItRests() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        let arrival = ChatRowArrival()
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 44)
        var shown = 0
        arrival.arrive(rowHeight: 244, engine: engine) { shown += 1 }
        // Its row left and came back under the same fling, and the picture
        // arrived again from memory.
        arrival.rowDisappeared()
        arrival.arrive(rowHeight: 244, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 0)

        surface.isDecelerating = false
        runScheduled()
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(engine.cardShifts.count, 1, "its growth waits for the layout")
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 244)
        XCTAssertEqual(surface.contentOffsetY, 2100, "moved by the row's growth")
        surface.layOut(contentHeight: 4200)
        XCTAssertEqual(surface.contentOffsetY, 2100, "once")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAPictureWhoseRowLeftTheScreenIsDropped() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        let arrival = ChatRowArrival()
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 44)
        var shown = 0
        arrival.arrive(rowHeight: 244, engine: engine) { shown += 1 }
        arrival.rowDisappeared()
        surface.isDecelerating = false
        runScheduled()
        XCTAssertEqual(shown, 0, "the row's task loads it again when the row is back")
        surface.layOut(contentHeight: 4200)
        XCTAssertEqual(surface.contentOffsetY, 1900, "nothing announced")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAPictureWhoseRowAlreadyHoldsItsSizeShowsAtOnce() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        let arrival = ChatRowArrival()
        // Its placeholder took the picture's remembered size.
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 244)
        var shown = 0
        arrival.arrive(rowHeight: 244, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 1, "nothing will move")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testARowLaidOutWithItsLoadingLineTakesAPictureFromMemoryOnlyThroughItsArrival() {
        let (engine, surface) = browsingReader()
        let arrival = ChatRowArrival()
        XCTAssertTrue(arrival.holds(244), "on the row's first frame, what memory holds shows at once")
        // Laid out with its loading line before another row of the same
        // picture showed it.
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 44)
        XCTAssertFalse(arrival.holds(244), "the row keeps its loading line")
        XCTAssertTrue(arrival.holds(44.3), "what keeps the row's height may show")
        var shown = 0
        arrival.arrive(rowHeight: 244, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(engine.cardShifts.count, 1, "announced above the reader like a load")
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 244)
        XCTAssertEqual(surface.contentOffsetY, 2200, "moved by the row's growth")
        XCTAssertTrue(arrival.holds(244))
    }

    func testAPictureOutsideAChatShowsAtOnce() {
        let arrival = ChatRowArrival()
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 44)
        var shown = 0
        arrival.arrive(rowHeight: 244, engine: nil) { shown += 1 }
        XCTAssertEqual(shown, 1)
        arrival.arrive(rowHeight: nil, engine: nil) { shown += 1 }
        XCTAssertEqual(shown, 2, "and so does a failure")
    }

    func testAFailureAboveTheReaderWaitsForTheFlingAndMovesThemByWhatItsLayoutTook() {
        let (engine, surface) = browsingReader()
        surface.isDecelerating = true
        surface.contentOffsetY = 1900
        engine.surfaceScrolled()
        let arrival = ChatRowArrival()
        // A placeholder at the picture's remembered size.
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 244)
        var shown = 0
        arrival.arrive(rowHeight: nil, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 0, "the placeholder stays under the fling")

        surface.isDecelerating = false
        runScheduled()
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(engine.cardShifts.count, 1, "announced, though only its layout knows by how much")
        // Its label laid out, 202 shorter.
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 42)
        XCTAssertEqual(surface.contentOffsetY, 1698, "moved by what the row took")
        surface.layOut(contentHeight: 3798)
        XCTAssertEqual(surface.contentOffsetY, 1698, "once")
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAFailureKeepingTheRowsHeightMovesNobody() {
        let (engine, surface) = browsingReader()
        let arrival = ChatRowArrival()
        arrival.stackFrame = CGRect(x: 0, y: 1000, width: 300, height: 44)
        var shown = 0
        arrival.arrive(rowHeight: nil, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 1, "at rest it shows at once")
        // Its label took the loading line's height; a reply streams in below.
        surface.layOut(contentHeight: 4100)
        XCTAssertEqual(surface.contentOffsetY, 2000)
        clock += ChatScrollEngine.cardGrowthDeadline + 0.1
        surface.layOut(contentHeight: 4200)
        XCTAssertTrue(engine.cardShifts.isEmpty, "the shift lapses")
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    func testAFailureOnScreenShowsAtOnceWithNothingAnnounced() {
        let (engine, _) = browsingReader()
        let arrival = ChatRowArrival()
        arrival.stackFrame = CGRect(x: 0, y: 2100, width: 300, height: 244)
        var shown = 0
        arrival.arrive(rowHeight: nil, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAFailureInARowNotLaidOutYetShowsAtOnce() {
        let (engine, _) = browsingReader()
        let arrival = ChatRowArrival()
        var shown = 0
        arrival.arrive(rowHeight: nil, engine: engine) { shown += 1 }
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(engine.cardShifts.isEmpty)
    }

    func testAReplyPictureFitsTheRowsWidthUpToItsCeiling() {
        XCTAssertEqual(ChatRowArrival.fittedHeight(of: CGSize(width: 1200, height: 800), inWidth: 300, maxHeight: 360), 200)
        XCTAssertEqual(ChatRowArrival.fittedHeight(of: CGSize(width: 100, height: 1000), inWidth: 300, maxHeight: 360), 360)
        XCTAssertEqual(
            ChatRowArrival.fittedHeight(of: CGSize(width: 1200, height: 800), inWidth: 0, maxHeight: 360), 0,
            "a row without a width yet has no growth to announce"
        )
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

    func testChromeInputsFromUIKitCallbacksPublishOnTheNextTurn() {
        let (engine, surface) = makeEngine()
        XCTAssertFalse(engine.chrome.inputs.showsJumpToLatest)

        surface.userScroll(to: 1000)
        XCTAssertTrue(engine.showsJumpToLatest)
        XCTAssertFalse(
            engine.chrome.inputs.showsJumpToLatest,
            "a change made inside a UIKit callback must not publish during the SwiftUI update"
        )

        drainMainQueue()
        XCTAssertTrue(engine.chrome.inputs.showsJumpToLatest)
        XCTAssertFalse(engine.chrome.inputs.isFollowingLatest)

        engine.explicitLatestRequested(animated: false)
        XCTAssertTrue(engine.chrome.inputs.isFollowingLatest, "a SwiftUI-driven command publishes directly")
    }

    func testTrackedMessageVisibilityPublishesOnlyAtViewportTransitions() {
        let (engine, surface) = makeEngine()
        engine.trackMessageVisibility(of: "m5")
        XCTAssertEqual(engine.chrome.inputs.visibilityTrackedMessageID, "m5")
        XCTAssertTrue(engine.chrome.inputs.isVisibilityTrackedMessageOffscreen)

        engine.rowFramesChanged(["m5": ChatScrollRowFrame(minY: 3200, maxY: 3300, order: 5)])
        drainMainQueue()
        XCTAssertFalse(engine.chrome.inputs.isVisibilityTrackedMessageOffscreen)

        surface.userScroll(to: 100)
        drainMainQueue()
        XCTAssertTrue(engine.chrome.inputs.isVisibilityTrackedMessageOffscreen)

        engine.rowFramesChanged(["m5": ChatScrollRowFrame(minY: 200, maxY: 400, order: 5)])
        drainMainQueue()
        XCTAssertFalse(engine.chrome.inputs.isVisibilityTrackedMessageOffscreen)

        engine.trackMessageVisibility(of: nil)
        XCTAssertNil(engine.chrome.inputs.visibilityTrackedMessageID)
        XCTAssertFalse(engine.chrome.inputs.isVisibilityTrackedMessageOffscreen)
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

    // MARK: - Long replies stop at their start (#365)

    /// Session "a" at its end with the hold switched on, after a send of
    /// m10: the user's message is laid out at stack 3500...3580 (content
    /// 3518...3598), so the hold stops at 3481, the message 37 pt below the
    /// viewport's top, and the room under it makes the content at least
    /// 3481 + 800 = 4281 tall.
    private func sendIntoHold(reducedMotion: Bool = false) -> (ChatScrollEngine, FakeChatScrollSurface) {
        let (engine, surface) = makeEngine(reducedMotion: reducedMotion)
        engine.holdsRepliesAtStart = { true }
        XCTAssertEqual(surface.contentOffsetY, 3200)
        engine.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        engine.explicitLatestRequested(animated: false, armsReplyHold: true)
        surface.layOut(contentHeight: 4200)
        engine.rowFramesChanged(["m10": ChatScrollRowFrame(minY: 3500, maxY: 3580, order: 10)])
        XCTAssertEqual(surface.contentOffsetY, 3400, "nothing moves before the room is laid out")
        XCTAssertTrue(engine.replyHoldArmed)
        XCTAssertEqual(engine.replyRoomMinContentHeight, 4281)
        return (engine, surface)
    }

    /// What SwiftUI lays out: the reply's own content, or the room the
    /// engine asks for if that is taller.
    private func layOutWithRoom(_ engine: ChatScrollEngine, _ surface: FakeChatScrollSurface, reply height: CGFloat) {
        surface.layOut(contentHeight: max(height, engine.replyRoomMinContentHeight))
    }

    /// The landing's animation has had its time.
    private func finishLandingAnimation() {
        clock += ChatScrollEngine.latestAnimationDuration + 0.1
        let bodies = scheduled
        scheduled = []
        bodies.forEach { $0() }
    }

    /// The offsets the engine wrote never went up: the hold is a stop.
    private func assertNeverMovedUp(_ surface: FakeChatScrollSurface, file: StaticString = #filePath, line: UInt = #line) {
        let offsets = surface.sets.map(\.y)
        XCTAssertEqual(offsets, offsets.sorted(), "an offset went up", file: file, line: line)
    }

    /// #1436: the sent message moves to the top once its room is laid out,
    /// in one animated move, and the reply streams into the room under it
    /// without moving anything; once it outgrows the screen the reader is
    /// left browsing at the same place.
    func testASentMessageMovesToTheTopAndALongReplyStopsThere() {
        let (engine, surface) = sendIntoHold()
        surface.sets = []
        layOutWithRoom(engine, surface, reply: 4200)
        XCTAssertEqual(surface.sets.map(\.y), [3481])
        XCTAssertEqual(surface.sets.map(\.animated), [true], "the move to the top animates")
        XCTAssertTrue(engine.isFollowingLatest)
        finishLandingAnimation()
        XCTAssertEqual(surface.sets.count, 1)
        // The reply fills the room: nothing moves.
        layOutWithRoom(engine, surface, reply: 4250)
        layOutWithRoom(engine, surface, reply: 4281)
        XCTAssertEqual(surface.sets.count, 1)
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertFalse(engine.showsJumpToLatest)
        // It runs past the screen: still nothing moves, and the reader is
        // left browsing at the stop.
        layOutWithRoom(engine, surface, reply: 4300)
        XCTAssertTrue(engine.isFollowingLatest, "within the near-bottom distance it is still following")
        layOutWithRoom(engine, surface, reply: 4700)
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(engine.showsJumpToLatest)
        XCTAssertTrue(engine.replyHoldArmed, "armed until the reader is below the reply's start")
        layOutWithRoom(engine, surface, reply: 6000)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        XCTAssertEqual(surface.sets.count, 1)
    }

    func testWithReduceMotionTheSentMessageSnapsToTheTop() {
        let (engine, surface) = sendIntoHold(reducedMotion: true)
        surface.sets = []
        layOutWithRoom(engine, surface, reply: 4200)
        XCTAssertEqual(surface.sets.map(\.y), [3481])
        XCTAssertEqual(surface.sets.map(\.animated), [false])
    }

    /// Long replies switched off while the room is there: it goes at once,
    /// and following goes to the end.
    func testSwitchingLongRepliesOffTakesTheRoomAway() {
        let (engine, surface) = sendIntoHold()
        layOutWithRoom(engine, surface, reply: 4200)
        finishLandingAnimation()
        engine.holdsRepliesAtStart = { false }
        engine.replyStartPreferenceChanged()
        XCTAssertEqual(engine.replyRoomMinContentHeight, 0)
        XCTAssertEqual(engine.replyRoom.minContentHeight, 0)
        surface.layOut(contentHeight: 4200)
        XCTAssertEqual(surface.contentOffsetY, 3400)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    /// The room lags a pass behind content that got shorter (a row
    /// shrinking, a keyboard closing): the reader stays at the stop instead
    /// of going down to the bottom and back.
    func testContentShorterThanTheRoomForAPassLeavesTheReaderAtTheStop() {
        let (engine, surface) = sendIntoHold()
        layOutWithRoom(engine, surface, reply: 4200)
        finishLandingAnimation()
        surface.sets = []
        surface.layOut(contentHeight: 4230)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        // A keyboard opening grows the bottom inset before the room shrinks
        // for it: still the stop, still following.
        surface.layOut(contentHeight: 4281)
        surface.insetBottom = 300
        engine.bottomBarResized()
        XCTAssertEqual(surface.contentOffsetY, 3481)
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertEqual(engine.replyRoomMinContentHeight, 3981)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    /// The next send lands in the room the last reply left: nothing moves
    /// until the new message's frame is in and its own room laid out.
    func testTheNextSendKeepsTheRoomUntilItsMessageIsLaidOut() {
        let (engine, surface) = sendIntoHold()
        layOutWithRoom(engine, surface, reply: 4200)
        finishLandingAnimation()
        engine.transcriptChanged(
            messages: Self.messages(0..<13),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )
        engine.explicitLatestRequested(animated: false, armsReplyHold: true)
        XCTAssertEqual(engine.replyRoomMinContentHeight, 4281, "the last reply's room stays")
        surface.sets = []
        // m12 lands below the reply, inside the room.
        layOutWithRoom(engine, surface, reply: 4260)
        XCTAssertTrue(surface.sets.isEmpty)
        engine.rowFramesChanged([
            "m10": ChatScrollRowFrame(minY: 3500, maxY: 3580, order: 10),
            "m12": ChatScrollRowFrame(minY: 4100, maxY: 4180, order: 12),
        ])
        XCTAssertEqual(engine.replyRoomMinContentHeight, 4881)
        XCTAssertTrue(surface.sets.isEmpty, "nothing moves before its room is laid out")
        layOutWithRoom(engine, surface, reply: 4260)
        XCTAssertEqual(surface.sets.map(\.y), [4081])
        XCTAssertEqual(surface.sets.map(\.animated), [true])
    }

    /// The send pulse can reach the engine before the sent message does.
    /// A reader at the last reply's stop goes to the end for the send, not
    /// to that stop, and the new message moves to the top once it has a
    /// frame and room.
    func testASendFromTheLastStopBeforeItsMessageArrivesLandsTheNewMessage() {
        let (engine, surface) = sendIntoHold()
        surface.layOut(contentHeight: 5200)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        XCTAssertEqual(engine.mode, .browsing)
        engine.explicitLatestRequested(animated: false, armsReplyHold: true)
        XCTAssertEqual(surface.contentOffsetY, 4400)
        XCTAssertTrue(engine.isFollowingLatest)
        engine.transcriptChanged(
            messages: Self.messages(0..<13),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )
        surface.layOut(contentHeight: 5300)
        engine.rowFramesChanged(["m12": ChatScrollRowFrame(minY: 5000, maxY: 5080, order: 12)])
        XCTAssertEqual(engine.replyRoomMinContentHeight, 5781)
        surface.sets = []
        layOutWithRoom(engine, surface, reply: 5300)
        XCTAssertEqual(surface.sets.map(\.y), [4981])
        XCTAssertEqual(surface.sets.map(\.animated), [true])
    }

    func testClearingTheTranscriptDisarmsTheHoldAndItsRoom() {
        let (engine, _) = sendIntoHold()
        engine.transcriptChanged(messages: [], transcriptRevision: 3, viewportTransitionGeneration: 1)
        XCTAssertFalse(engine.replyHoldArmed)
        XCTAssertEqual(engine.replyRoomMinContentHeight, 0)
    }

    /// A message taller than a third of the screen stops with its last
    /// third showing, so the reply still has the screen under it.
    func testATallMessageStopsWithItsLastThirdShowing() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        engine.explicitLatestRequested(animated: false, armsReplyHold: true)
        surface.layOut(contentHeight: 4400)
        engine.rowFramesChanged(["m10": ChatScrollRowFrame(minY: 3500, maxY: 4100, order: 10)])
        // 18 + 4100 - 800 / 3
        surface.layOut(contentHeight: 6000)
        XCTAssertEqual(surface.contentOffsetY, 3851.33, accuracy: 0.01)
        XCTAssertEqual(engine.mode, .browsing)
    }

    /// An unread chat opened at its reply has no room under it: the reply is
    /// already there.
    func testAnUnreadLandingMakesNoRoom() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.rowFramesChanged(["m8": ChatScrollRowFrame(minY: 3600, maxY: 3680, order: 8)])
        engine.replyStartLandingRequested()
        scheduled.forEach { $0() }
        XCTAssertEqual(engine.replyRoomMinContentHeight, 0)
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    func testDisarmingTheHoldTakesTheRoomAway() {
        let (engine, _) = sendIntoHold()
        engine.explicitLatestRequested(animated: false)
        XCTAssertEqual(engine.replyRoomMinContentHeight, 0)
        XCTAssertEqual(engine.replyRoom.minContentHeight, 0, "published at once from a command")
    }

    /// Chips appearing under a reply that fits in its room leave the
    /// message at the top: the room shrinks for them.
    func testABottomBarGrowingUnderTheRoomLeavesTheMessageAtTheTop() {
        let (engine, surface) = sendIntoHold()
        layOutWithRoom(engine, surface, reply: 4200)
        finishLandingAnimation()
        surface.sets = []
        surface.insetBottom = 52
        engine.bottomBarResized()
        XCTAssertEqual(engine.replyRoomMinContentHeight, 4229)
        layOutWithRoom(engine, surface, reply: 4200)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    /// Nightly 2026-10-26 (hosted): a newly appended row's estimate put the
    /// max past the stop, its measured height shrank the content under it,
    /// and SwiftUI clamped the reader back to the bottom, following again.
    /// The next growth stops at the reply's start again, not at the end.
    func testAStopUndoneByAShrinkingEstimateStopsAgain() {
        let (engine, surface) = sendIntoHold()
        surface.sets = []
        surface.layOut(contentHeight: 4700)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        XCTAssertEqual(engine.mode, .browsing)
        // Measured: the reply still fits. SwiftUI clamps to the new bottom.
        surface.layOut(contentHeight: 4250)
        surface.contentOffsetY = 3450
        engine.surfaceScrolled()
        XCTAssertEqual(engine.mode, .following)
        // The reply grows past the screen for real.
        surface.layOut(contentHeight: 4700)
        XCTAssertEqual(surface.contentOffsetY, 3481, "stops at the reply's start again")
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testABigChunkStopsAtTheReplyStartWithoutGoingPastIt() {
        let (engine, surface) = sendIntoHold()
        surface.sets = []
        // One layout pass carries the reply well past a screen.
        surface.layOut(contentHeight: 5200)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        XCTAssertEqual(engine.mode, .browsing)
        assertNeverMovedUp(surface)
    }

    func testWithTheSettingOffAReplyIsFollowedToItsEnd() {
        let (engine, surface) = sendIntoHold()
        engine.holdsRepliesAtStart = { false }
        surface.layOut(contentHeight: 6000)
        XCTAssertEqual(surface.contentOffsetY, 5200)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testTheJumpToLatestGoesPastTheHoldAndFollowsTheEnd() {
        let (engine, surface) = sendIntoHold()
        surface.layOut(contentHeight: 5200)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        engine.explicitLatestRequested(animated: false)
        XCTAssertEqual(surface.contentOffsetY, 4400)
        surface.layOut(contentHeight: 6000)
        XCTAssertEqual(surface.contentOffsetY, 5200)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testAReaderBackAtTheEndFollowsTheRestOfTheReply() {
        let (engine, surface) = sendIntoHold()
        surface.layOut(contentHeight: 5200)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        // Read down to the end while it still streams: following again,
        // to the end this time.
        surface.userScroll(to: 4400)
        XCTAssertTrue(engine.isFollowingLatest)
        surface.sets = []
        surface.layOut(contentHeight: 6000)
        XCTAssertEqual(surface.contentOffsetY, 5200)
        XCTAssertTrue(engine.isFollowingLatest)
        assertNeverMovedUp(surface)
    }

    func testATurnStartedElsewhereStopsAtItsStartToo() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        // Another device sent m10; no send here.
        engine.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(engine.replyHoldArmed)
        surface.layOut(contentHeight: 4200)
        engine.rowFramesChanged(["m10": ChatScrollRowFrame(minY: 3500, maxY: 3580, order: 10)])
        surface.layOut(contentHeight: 5200)
        XCTAssertEqual(surface.contentOffsetY, 3481)
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testOpeningAChatDoesNotArmTheHold() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        XCTAssertFalse(engine.replyHoldArmed)
        engine.rowFramesChanged(["m8": ChatScrollRowFrame(minY: 3000, maxY: 3080, order: 8)])
        surface.layOut(contentHeight: 5000)
        XCTAssertEqual(surface.contentOffsetY, 4200)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    /// A chat opened on its saved rows: Hermes' rows taking over are its
    /// first sync, so a turn started elsewhere since it was saved doesn't
    /// arm the hold, as when it opened on no rows (#1533). A turn after
    /// that does.
    func testHermesRowsAfterSavedOnesDoNotArmTheHold() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.transcriptChanged(
            messages: Self.messages(0..<10),
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true,
            isProvisional: true
        )
        engine.transcriptChanged(
            messages: Self.messages(0..<12),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertFalse(engine.replyHoldArmed)

        engine.transcriptChanged(
            messages: Self.messages(0..<13),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(engine.replyHoldArmed)
        withExtendedLifetime(surface) {}
    }

    func testAUserMessageNotLaidOutYetFollowsAsBefore() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        engine.explicitLatestRequested(animated: false, armsReplyHold: true)
        surface.layOut(contentHeight: 5200)
        XCTAssertEqual(surface.contentOffsetY, 4400)
        // Its frame arrives with the reader already below it: no move up.
        engine.rowFramesChanged(["m10": ChatScrollRowFrame(minY: 3500, maxY: 3580, order: 10)])
        surface.sets = []
        surface.layOut(contentHeight: 6000)
        XCTAssertEqual(surface.contentOffsetY, 5200)
        XCTAssertFalse(engine.replyHoldArmed)
        assertNeverMovedUp(surface)
    }

    func testTheTitleTapDisarmsTheHold() {
        let (engine, _) = sendIntoHold()
        engine.explicitTopRequested()
        XCTAssertFalse(engine.replyHoldArmed)
    }

    func testASessionSwitchDisarmsTheHold() {
        let (engine, _) = sendIntoHold()
        engine.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertFalse(engine.replyHoldArmed)
    }

    // MARK: - An unread chat opens at its latest reply (#365)

    func testAnUnreadReplyOffScreenLandsAtItsFirstRow() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        events = []
        engine.replyStartLandingRequested()
        XCTAssertEqual(scheduled.count, 1)
        scheduled.forEach { $0() }
        XCTAssertEqual(events.last, .revealRow(id: "m9"))
        XCTAssertEqual(engine.mode, .browsing)
        XCTAssertTrue(engine.replyHoldArmed)
        withExtendedLifetime(surface) {}
    }

    func testAnUnreadReplyLaidOutLandsWhereTheHoldStops() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.rowFramesChanged(["m8": ChatScrollRowFrame(minY: 2500, maxY: 2580, order: 8)])
        engine.replyStartLandingRequested()
        scheduled.forEach { $0() }
        XCTAssertEqual(surface.contentOffsetY, 2481)
        XCTAssertEqual(engine.mode, .browsing)
        // The notification's handoff ends after the landing: it stays.
        engine.notificationHandoffFinished()
        XCTAssertEqual(surface.contentOffsetY, 2481)
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testAShortUnreadReplyStaysAtTheEnd() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.rowFramesChanged(["m8": ChatScrollRowFrame(minY: 3600, maxY: 3680, order: 8)])
        engine.replyStartLandingRequested()
        scheduled.forEach { $0() }
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertTrue(engine.replyHoldArmed, "the reply may still be running")
    }

    func testAReaderWhoScrolledBeforeTheLandingKeepsTheirPlace() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.replyStartLandingRequested()
        surface.userScroll(to: 1000)
        events = []
        scheduled.forEach { $0() }
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertFalse(events.contains { if case .revealRow = $0 { return true }; return false })
    }

    func testALandingSwitchedOffBeforeItRunsDoesNothing() {
        let (engine, surface) = makeEngine()
        var on = true
        engine.holdsRepliesAtStart = { on }
        engine.replyStartLandingRequested()
        on = false
        events = []
        scheduled.forEach { $0() }
        XCTAssertTrue(engine.isFollowingLatest)
        XCTAssertFalse(events.contains { if case .revealRow = $0 { return true }; return false })
        withExtendedLifetime(surface) {}
    }

    func testALeftChatForgetsItsLanding() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.rowFramesChanged(["m8": ChatScrollRowFrame(minY: 2500, maxY: 2580, order: 8)])
        engine.replyStartLandingRequested()
        scheduled.forEach { $0() }
        XCTAssertEqual(surface.contentOffsetY, 2481)
        engine.viewDisappeared()
        // A later notification for this chat takes it to the end again.
        engine.notificationHandoffBegan()
        engine.notificationHandoffFinished()
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testALeftChatKeepsAnArmedHold() {
        let (engine, surface) = sendIntoHold()
        engine.viewDisappeared()
        XCTAssertTrue(engine.replyHoldArmed)
        // Back with the reply still running: it stops at its start.
        surface.layOut(contentHeight: 5200)
        XCTAssertEqual(surface.contentOffsetY, 3481)
    }

    func testALandingBeforeTheScrollViewIsFoundLandsWhenItIs() {
        let surface = FakeChatScrollSurface()
        let engine = ChatScrollEngine(
            now: { [unowned self] in self.clock },
            schedule: { [unowned self] _, body in self.scheduled.append(body) }
        )
        engines.append(engine)
        engine.onEvent = { [unowned self] event in self.events.append(event) }
        engine.holdsRepliesAtStart = { true }
        surface.engine = engine
        engine.renderedSessionChanged(to: keyA, identity: identity("a"), viaNotification: false, viewportTransitionGeneration: 1)
        engine.transcriptChanged(messages: Self.messages(0..<10), transcriptRevision: 1, viewportTransitionGeneration: 1, isInitialSync: true)
        engine.replyStartLandingRequested()
        scheduled.forEach { $0() }
        events = []
        engine.attach(surface)
        XCTAssertEqual(events.last, .revealRow(id: "m9"))
        XCTAssertEqual(engine.mode, .browsing)
    }

    func testABackgroundedLandingLandsOnResume() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.setPaused(true)
        engine.replyStartLandingRequested()
        events = []
        scheduled.forEach { $0() }
        XCTAssertFalse(events.contains { if case .revealRow = $0 { return true }; return false })
        engine.setPaused(false)
        XCTAssertEqual(events.last, .revealRow(id: "m9"))
        XCTAssertEqual(engine.mode, .browsing)
        withExtendedLifetime(surface) {}
    }

    func testANotificationOpenGoesPastAnArmedHold() {
        let (engine, surface) = sendIntoHold()
        engine.notificationHandoffBegan()
        XCTAssertFalse(engine.replyHoldArmed)
        surface.layOut(contentHeight: 5200)
        XCTAssertEqual(surface.contentOffsetY, 4400)
        XCTAssertTrue(engine.isFollowingLatest)
    }

    func testTheLandingWaitsForTheSetting() {
        let (engine, surface) = makeEngine()
        engine.replyStartLandingRequested()
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    /// An unread chat left mid-turn asks for its landing as it opens, from
    /// its saved rows, and the view can hand the engine that request before
    /// the switch the same open made: the switch keeps it (#1533).
    func testASwitchKeepsTheLandingItsOwnOpenAskedFor() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        events = []
        engine.replyStartLandingRequested(viewportTransitionGeneration: 2)
        engine.renderedSessionChanged(to: keyB, identity: identity("b"), viaNotification: false, viewportTransitionGeneration: 2)
        engine.transcriptChanged(
            messages: Self.messages(10..<20),
            transcriptRevision: 2,
            viewportTransitionGeneration: 2,
            isInitialSync: true
        )
        runScheduled()
        XCTAssertTrue(events.contains(.revealRow(id: "m19")), "It lands at the start of b's reply")
        XCTAssertEqual(engine.mode, .browsing)
        withExtendedLifetime(surface) {}
    }

    /// A landing an earlier open asked for doesn't follow the reader into
    /// the next chat they open before it ran.
    func testASwitchDropsALandingAnEarlierOpenAskedFor() {
        let (engine, surface) = makeEngine()
        engine.holdsRepliesAtStart = { true }
        engine.replyStartLandingRequested(viewportTransitionGeneration: 1)
        engine.renderedSessionChanged(to: keyB, identity: identity("b"), viaNotification: false, viewportTransitionGeneration: 2)
        engine.transcriptChanged(
            messages: Self.messages(10..<20),
            transcriptRevision: 2,
            viewportTransitionGeneration: 2,
            isInitialSync: true
        )
        events = []
        runScheduled()
        XCTAssertFalse(events.contains { if case .revealRow = $0 { return true }; return false })
        XCTAssertTrue(engine.isFollowingLatest)
        withExtendedLifetime(surface) {}
    }
}
