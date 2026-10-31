import Combine
import XCTest
@testable import Conduit

/// Stands in for the transcript's collection view: rows stacked from the
/// top of the content, each with a frame, as the layout gives every row
/// one. Like UIKit, an offset set is not clamped and reports back as a
/// scroll before it returns. Row changes, and the room the scroller asks
/// for, take effect at the next pass (`layOut`).
@MainActor
private final class FakeTranscriptSurface: TranscriptScrollSurface {
    weak var scroller: TranscriptScroller?
    var contentOffsetY: CGFloat = 0
    private(set) var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 800
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    var isTracking = false
    var isDecelerating = false
    private(set) var reservedContentHeight: CGFloat = 0
    /// The room the scroller asked for last, laid out at the next pass.
    private(set) var askedReserve: CGFloat = 0
    var sets: [(y: CGFloat, animated: Bool)] = []
    /// The rows in transcript order, with their heights.
    private var transcript: [(id: String, height: CGFloat)]
    private var frames: [TranscriptRowFrame] = []

    init(ids: [String] = (0..<10).map { "m\($0)" }, rowHeight: CGFloat = 400) {
        transcript = ids.map { ($0, rowHeight) }
        stack()
    }

    func setContentOffsetY(_ y: CGFloat, animated: Bool) {
        sets.append((y, animated))
        contentOffsetY = y
        scroller?.surfaceScrolled()
    }

    func frame(ofRow id: String) -> TranscriptRowFrame? {
        frames.first { $0.id == id }
    }

    func rows(crossing band: ClosedRange<CGFloat>) -> [TranscriptRowFrame] {
        frames.filter { $0.maxY > band.lowerBound && $0.minY < band.upperBound }
    }

    func reserveContentHeight(_ height: CGFloat) {
        askedReserve = height
    }

    /// The layout's pass: the rows stacked, the content at least the room
    /// asked for, and the scroller's callback inside it.
    func layOut() {
        stack()
        scroller?.layoutChanged()
    }

    /// A bar above or below the transcript changed height (the composer,
    /// Predictive's chips, the keyboard): the insets change in a pass of
    /// their own.
    func insetsChanged() {
        scroller?.layoutChanged()
    }

    /// The user moved the content with a finger, then let go.
    func userScroll(to y: CGFloat) {
        isTracking = true
        scroller?.userDragBegan()
        contentOffsetY = y
        scroller?.surfaceScrolled()
        isTracking = false
        scroller?.userDragEnded()
    }

    /// A fling moved the content to `y`, and is still moving.
    func fling(to y: CGFloat) {
        isDecelerating = true
        contentOffsetY = y
        scroller?.surfaceScrolled()
    }

    /// The fling came to rest (scrollViewDidEndDecelerating).
    func flingRests() {
        isDecelerating = false
        scroller?.surfaceScrolled()
    }

    func contains(_ id: String) -> Bool {
        transcript.contains { $0.id == id }
    }

    func setHeight(_ id: String, _ height: CGFloat) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return XCTFail("no row \(id)") }
        transcript[index].height = height
    }

    func append(_ id: String, height: CGFloat) {
        transcript.append((id, height))
    }

    func insert(_ ids: [String], height: CGFloat, at index: Int) {
        transcript.insert(contentsOf: ids.map { ($0, height) }, at: index)
    }

    func remove(_ id: String) {
        transcript.removeAll { $0.id == id }
    }

    /// The row becomes another (a reply streaming in settling into the
    /// chat's own row), in the same place.
    func replace(_ id: String, with newID: String, height: CGFloat? = nil) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return XCTFail("no row \(id)") }
        transcript[index] = (newID, height ?? transcript[index].height)
    }

    func replaceAll(_ ids: [String], height: CGFloat) {
        transcript = ids.map { ($0, height) }
    }

    /// Where the row's top sits under the visible top.
    func top(of id: String) -> CGFloat? {
        frame(ofRow: id).map { $0.minY - contentOffsetY - insetTop }
    }

    private func stack() {
        var y: CGFloat = 0
        frames = transcript.map { row in
            defer { y += row.height }
            return TranscriptRowFrame(id: row.id, minY: y, maxY: y + row.height)
        }
        reservedContentHeight = askedReserve
        contentHeight = max(y, reservedContentHeight)
    }
}

/// TranscriptScroller's rules, ported rule by rule from the tests of the
/// lazy stack's scroll engine it replaced (#1533, the transcript rewrite).
/// The rules that existed only for the lazy stack (rows without frames,
/// SwiftUI's own offset writes, cards announcing their height) have no
/// port: every row has a frame here.
@MainActor
final class TranscriptScrollerTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var events: [TranscriptScrollerEvent] = []
    /// Every scroller a test makes, alive until the test ends. The fake
    /// surface holds its scroller weakly (as the real one does), so a test
    /// that keeps only the surface would otherwise talk to a freed scroller
    /// and pass without testing anything.
    private var scrollers: [TranscriptScroller] = []
    /// Work the scroller scheduled for later, run by the test when it
    /// chooses.
    private var scheduled: [(delay: TimeInterval, body: @MainActor () -> Void)] = []

    private let keyA = ChatScrollSessionKey(profile: "p", sessionID: "a")
    private let keyB = ChatScrollSessionKey(profile: "p", sessionID: "b")

    override func setUp() {
        super.setUp()
        clock = 100
        events = []
        scrollers = []
        scheduled = []
    }

    /// Runs the main run loop until every block already on the main queue
    /// has run: the queue is FIFO, so a marker queued now runs after them.
    private func drainMainQueue() {
        let drained = expectation(description: "earlier main-queue blocks ran")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 10)
    }

    private func runScheduled() {
        let bodies = scheduled
        scheduled = []
        bodies.forEach { $0.body() }
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

    private static func ids(_ range: Range<Int>) -> [String] {
        range.map { "m\($0)" }
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

    /// A scroller showing session "a" with ten messages, m0...m9, 400 pt
    /// each on a surface 800 pt tall: attached, it's at the end, 3200.
    private func makeScroller(
        surface providedSurface: FakeTranscriptSurface? = nil,
        reducedMotion: Bool = false,
        attached: Bool = true
    ) -> (TranscriptScroller, FakeTranscriptSurface) {
        let surface = providedSurface ?? FakeTranscriptSurface()
        let scroller = TranscriptScroller(
            now: { [unowned self] in self.clock },
            prefersReducedMotion: { reducedMotion },
            schedule: { [unowned self] delay, body in self.scheduled.append((delay, body)) }
        )
        scrollers.append(scroller)
        scroller.onEvent = { [unowned self] event in self.events.append(event) }
        surface.scroller = scroller
        scroller.renderedSessionChanged(
            to: keyA,
            identity: identity("a"),
            viaNotification: false,
            viewportTransitionGeneration: 1
        )
        scroller.transcriptChanged(
            messages: Self.messages(0..<10),
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true
        )
        if attached { scroller.attach(surface) }
        return (scroller, surface)
    }

    // MARK: - Following

    func testFollowingPinsToTheEndInTheSameLayoutPass() {
        let (scroller, surface) = makeScroller()
        XCTAssertEqual(surface.contentOffsetY, 3200, "attaching lands on the latest message")

        surface.setHeight("m9", 1000)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3800)
        XCTAssertTrue(surface.sets.allSatisfy { !$0.animated }, "following never animates")
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertFalse(scroller.showsJumpToLatest)
    }

    func testFollowingPinsWhenTheViewportShrinks() {
        let (_, surface) = makeScroller()
        surface.viewportHeight = 500
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3500)
    }

    /// Predictive's chips appearing over the composer grow only the bottom
    /// inset (iOS 26's safe-area bar).
    func testFollowingPinsWhenTheBottomBarGrows() {
        let (scroller, surface) = makeScroller()
        surface.insetBottom = 52
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3252, "the reply's end stays above the chips")
        surface.insetBottom = 104
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3304)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testABottomBarGrowingLeavesABrowsingReaderAlone() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        surface.insetBottom = 52
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    func testFollowingPinsWhenTheBottomBarShrinks() {
        let (scroller, surface) = makeScroller()
        surface.insetBottom = 52
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3252)
        surface.insetBottom = 0
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3200, "no empty space left where the chips were")
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    /// A reader just above the end, browsing, when the bar shrinks under
    /// them: past the new end, but they didn't scroll there.
    func testABottomBarShrinkingLeavesABrowsingReaderBrowsing() {
        let surface = FakeTranscriptSurface()
        surface.insetBottom = 120
        let (scroller, _) = makeScroller(surface: surface)
        XCTAssertEqual(surface.contentOffsetY, 3320)
        surface.userScroll(to: 3250)
        XCTAssertEqual(scroller.mode, .browsing)
        surface.insetBottom = 0
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3200, "moved up to the new end: no empty space under the last message")
        XCTAssertEqual(scroller.mode, .browsing)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3200, "and the next pass leaves them there")
        XCTAssertEqual(scroller.mode, .browsing)
    }

    /// A browsing reader 70 pt above the end drags while the bar shrinks
    /// 120 pt: letting go past the new end is the bar's doing, so they are
    /// moved up to it and stay browsing.
    func testABottomBarShrinkingUnderADragLeavesTheReaderBrowsing() {
        let surface = FakeTranscriptSurface()
        surface.insetBottom = 120
        let (scroller, _) = makeScroller(surface: surface)
        surface.userScroll(to: 3250)
        XCTAssertEqual(scroller.mode, .browsing)
        surface.isTracking = true
        scroller.userDragBegan()
        surface.insetBottom = 0
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3250, "a finger owns the offset")
        surface.isTracking = false
        scroller.userDragEnded()
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    /// A following reader nudges the chat a little while the chips appear:
    /// letting go, they follow again, at the end above the chips.
    func testAFollowingReaderDraggingWhileTheBarGrowsFollowsAgain() {
        let (scroller, surface) = makeScroller()
        surface.isTracking = true
        scroller.userDragBegan()
        surface.contentOffsetY = 3190
        scroller.surfaceScrolled()
        surface.insetBottom = 52
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3190, "a finger owns the offset")
        surface.isTracking = false
        scroller.userDragEnded()
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    /// A following reader who scrolls well away while the chips appear stays
    /// where they went.
    func testAFollowingReaderScrollingAwayWhileTheBarGrowsStaysBrowsing() {
        let (scroller, surface) = makeScroller()
        surface.isTracking = true
        scroller.userDragBegan()
        surface.contentOffsetY = 1000
        scroller.surfaceScrolled()
        surface.insetBottom = 52
        surface.insetsChanged()
        surface.isTracking = false
        scroller.userDragEnded()
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertEqual(surface.contentOffsetY, 1000)
    }

    /// Just past the near-bottom distance once the chips are counted, but
    /// within it as the chat was when the finger came down: follows again.
    func testAFollowingReaderIsMeasuredAgainstTheBarAtDragStart() {
        let (scroller, surface) = makeScroller()
        surface.isTracking = true
        scroller.userDragBegan()
        surface.contentOffsetY = 3170
        scroller.surfaceScrolled()
        surface.insetBottom = 52
        surface.insetsChanged()
        surface.isTracking = false
        scroller.userDragEnded()
        XCTAssertTrue(scroller.isFollowingLatest, "30 pt from the end it had; 82 pt from the new one")
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    /// A browsing reader who drags back near the end while the chips appear
    /// follows again, the same as with no bar change.
    func testABrowsingReaderDraggingBackNearTheEndWhileTheBarGrowsFollows() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        surface.isTracking = true
        scroller.userDragBegan()
        surface.contentOffsetY = 3180
        scroller.surfaceScrolled()
        surface.insetBottom = 52
        surface.insetsChanged()
        surface.isTracking = false
        scroller.userDragEnded()
        XCTAssertTrue(scroller.isFollowingLatest, "20 pt from the end it had")
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    /// A finger resting on the chat (no scroll) when the chips appear: the
    /// pin waits, and the lift takes it.
    func testABottomBarChangeUnderAFingerPinsWhenItLifts() {
        let (scroller, surface) = makeScroller()
        surface.isTracking = true
        surface.insetBottom = 52
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3200, "a finger owns the offset")
        surface.isTracking = false
        scroller.userDragEnded()
        XCTAssertEqual(surface.contentOffsetY, 3252)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    /// Chips appearing during a fling: the end they leave is taken once the
    /// fling rests.
    func testABottomBarChangeDuringAFlingPinsOnceItRests() {
        let (_, surface) = makeScroller()
        surface.isDecelerating = true
        surface.insetBottom = 52
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3200, "momentum owns the offset")
        surface.flingRests()
        XCTAssertEqual(surface.contentOffsetY, 3252)
    }

    func testFollowingRepairsAnOvershootWhenContentShrinks() {
        let (_, surface) = makeScroller()
        surface.setHeight("m9", 100)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2900, "no empty space left under the last message")
    }

    /// UIKit never clamps the offset on its own: one left past the end
    /// (written by something else) is put back at once.
    func testFollowingPinsAnOffsetLeftPastTheEnd() {
        let (scroller, surface) = makeScroller()
        surface.contentOffsetY = 3300
        scroller.surfaceScrolled()
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testFollowingLeavesARubberBandPastTheEndToTheFinger() {
        let (scroller, surface) = makeScroller()
        surface.isTracking = true
        surface.contentOffsetY = 3300
        scroller.surfaceScrolled()
        XCTAssertEqual(surface.contentOffsetY, 3300)
    }

    func testFollowingDoesNotFightAFingerOnTheScreen() {
        let (_, surface) = makeScroller()
        surface.isTracking = true
        surface.setHeight("m9", 1000)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    // MARK: - Opening and closing rows

    /// Eric's report: opening a Thinking or tool row at the end of the chat
    /// jumped far down. Following pinned the content's new end, so the
    /// tapped header went off the top and the end of the row showed.
    func testOpeningARowAtTheEndKeepsTheTappedRowStill() {
        let (scroller, surface) = makeScroller()
        let tappedTop = surface.top(of: "m9")
        scroller.userWillToggleRow("m9")
        surface.setHeight("m9", 1000)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3200, "the row the reader tapped stays where it was")
        XCTAssertEqual(surface.top(of: "m9"), tappedTop)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertTrue(scroller.showsJumpToLatest)

        runScheduled()
        XCTAssertEqual(scroller.mode, .browsing, "the reader is reading what they opened")
        surface.append("m10", height: 400)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3200, "new rows below do not pull them away")
    }

    func testOpeningAShortRowAtTheEndFollowsAgainOnceItHasOpened() {
        let (scroller, surface) = makeScroller()
        scroller.userWillToggleRow("m9")
        surface.setHeight("m9", 430)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3200)

        runScheduled()
        XCTAssertTrue(scroller.isFollowingLatest, "still at the end, so still following")
        XCTAssertEqual(surface.contentOffsetY, 3230)
        surface.setHeight("m9", 800)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3600)
    }

    func testOnlyTheLatestToggleSettles() {
        let (scroller, surface) = makeScroller()
        scroller.userWillToggleRow("m9")
        scroller.userWillToggleRow("m9")
        surface.setHeight("m9", 420)
        surface.layOut()
        runScheduled()
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.sets.filter { $0.y == 3220 }.count, 1, "one settle, one pin")
    }

    /// A command after a toggle drops its settle: a reader the command left
    /// browsing stays browsing, even once rows under them shrink to within
    /// the near-bottom distance.
    func testACommandAfterAToggleCancelsItsSettle() {
        let (scroller, surface) = makeScroller()
        scroller.userWillToggleRow("m9")
        surface.setHeight("m9", 430)
        surface.layOut()
        scroller.explicitMessageRequested(id: "m7")
        XCTAssertEqual(surface.contentOffsetY, 2800)
        surface.setHeight("m9", 20)
        surface.layOut()
        XCTAssertEqual(surface.distanceFromBottom, 20)

        runScheduled()
        XCTAssertEqual(scroller.mode, .browsing, "the row the reader asked for is not undone by a pin")
        XCTAssertEqual(surface.contentOffsetY, 2800)
    }

    /// The reader taps a row whose top is above the screen (a long tool
    /// card's header just under the bar): it opens downward and stays
    /// still, rather than the first row starting on screen.
    func testOpeningARowThatStartsAboveTheScreenKeepsItStill() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 2100)
        scroller.userWillToggleRow("m5")
        surface.setHeight("m5", 1000)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2100)
        XCTAssertEqual(surface.top(of: "m5"), -100)
    }

    func testClosingARowAtTheEndLeavesNoEmptySpace() {
        let (scroller, surface) = makeScroller()
        scroller.userWillToggleRow("m8")
        surface.setHeight("m8", 100)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2900, "the shorter content sits on the end")
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testAToggleUnderAFingerChangesNothing() {
        let (scroller, surface) = makeScroller()
        surface.isTracking = true
        scroller.userWillToggleRow("m9")
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertTrue(scheduled.isEmpty)
    }

    // MARK: - Browsing

    /// A reader just above the end whose content shrinks (a row closing, a
    /// turn's live rows settling) is left over empty space that UIKit never
    /// closes on its own.
    func testABrowsingReaderLeftPastTheEndReturnsToTheLatestMessage() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 3000)
        XCTAssertEqual(scroller.mode, .browsing)
        surface.setHeight("m8", 200)
        surface.setHeight("m9", 100)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2700)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testDraggingAwayStopsFollowingAndNewRowsLeaveTheReaderAlone() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertTrue(scroller.showsJumpToLatest)

        surface.append("m10", height: 800)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 1000, "rows arriving below never move the reader")
        XCTAssertTrue(events.contains(.flushPersistence))
    }

    func testAPendingQuestionArrivingDoesNotMoveABrowsingReader() {
        let (scroller, surface) = makeScroller()
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

        scroller.transcriptChanged(
            messages: Self.messages(0..<10) + [pendingQuestion],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.append("clarify-pending", height: 300)
        surface.layOut()

        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertTrue(scroller.showsJumpToLatest)
    }

    func testScrollingBackNearTheEndResumesFollowing() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        surface.userScroll(to: 3170)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertFalse(scroller.showsJumpToLatest)

        surface.setHeight("m9", 800)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3600)
    }

    func testAFlingThatReachesTheEndResumesFollowing() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        surface.fling(to: 3190)
        XCTAssertTrue(scroller.isFollowingLatest)

        surface.setHeight("m9", 800)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3190, "no pin while the fling still moves")
        surface.isDecelerating = false
        surface.setHeight("m9", 900)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3700)
    }

    func testAFlickAwayThatEndsNearTheEndStopsFollowingOnceItLeaves() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 3180)
        XCTAssertTrue(scroller.isFollowingLatest, "let go within the relatch distance")

        surface.fling(to: 3150)
        XCTAssertEqual(scroller.mode, .browsing, "momentum carried the reader away")
        surface.fling(to: 2600)
        surface.flingRests()

        surface.setHeight("m9", 1000)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2600, "new rows do not pull the reader back")
    }

    /// Dragged past the end and let go: the bounce carries the reader back
    /// up, away from the end, and never relatches while it moves; at rest
    /// at the end they follow.
    func testMomentumAwayFromTheEndNeverRelatchesWhileItMoves() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        surface.isTracking = true
        scroller.userDragBegan()
        surface.contentOffsetY = 3250
        scroller.surfaceScrolled()
        surface.isTracking = false
        surface.isDecelerating = true
        scroller.userDragEnded()

        surface.fling(to: 3230)
        XCTAssertEqual(scroller.mode, .browsing)
        surface.fling(to: 3200)
        XCTAssertEqual(scroller.mode, .browsing)
        surface.flingRests()
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testTheTopRowOnScreenIsTrackedAndSavedWhileBrowsing() throws {
        let (scroller, surface) = makeScroller()
        events = []
        surface.userScroll(to: 1100)
        XCTAssertEqual(scroller.topVisibleMessageID, "m2")
        XCTAssertTrue(events.contains(.persistSnapshot(keyA)))

        let snapshot = try XCTUnwrap(scroller.renderedViewportSnapshot()?.snapshot)
        XCTAssertFalse(snapshot.followsLatest)
        XCTAssertEqual(snapshot.anchorSourceMessageID, "m2")
    }

    // MARK: - Rows changing height (cards, pictures, Load earlier)

    /// A reader browsing at 2000, with m5 at the visible top.
    private func browsingReader() -> (TranscriptScroller, FakeTranscriptSurface) {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 2000)
        XCTAssertEqual(scroller.mode, .browsing)
        surface.sets = []
        return (scroller, surface)
    }

    func testARowGrowingAboveTheReaderMovesThemByAsMuchInItsPass() {
        let (scroller, surface) = browsingReader()
        surface.setHeight("m2", 627)
        XCTAssertEqual(surface.contentOffsetY, 2000, "the offset moves in the layout pass, not before it")
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2227)
        XCTAssertEqual(surface.sets.map(\.animated), [false])
        XCTAssertEqual(surface.top(of: "m5"), 0)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    func testARowOnScreenGrowsBelowWhatTheReaderLooksAt() {
        let (_, surface) = browsingReader()
        surface.setHeight("m5", 627)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    /// A picture loading at the top of a tall row whose top is above the
    /// screen: the first row starting on screen stays still.
    func testARowGrowingAcrossTheTopKeepsTheFirstRowOnScreenStill() {
        let (_, surface) = makeScroller()
        surface.userScroll(to: 2100)
        surface.setHeight("m5", 627)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2327)
        XCTAssertEqual(surface.top(of: "m6"), 300)
    }

    func testARowShrinkingAboveTheReaderMovesThemUpButNotPastTheTop() {
        let (_, surface) = makeScroller()
        surface.userScroll(to: 100)
        surface.setHeight("m0", 173)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 0, "held at the top")
    }

    func testARowGrowingAboveAReaderNearTheEndKeepsThemBrowsing() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 3100)
        XCTAssertEqual(scroller.mode, .browsing, "100 pt from the end")
        surface.setHeight("m2", 627)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3327)
        XCTAssertEqual(scroller.mode, .browsing, "still 100 pt from the end")
    }

    /// Rows under the reader shrink as much as one above them grows: the
    /// end is above where their row would put them, so they're at the
    /// latest message, following it.
    func testAGrowthWithNoRoomLeftTakesTheReaderToTheEndAndTheyFollow() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 3100)
        surface.setHeight("m2", 627)
        surface.setHeight("m9", 100)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3127)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    /// 60 pt above the end, a row above grows 10 pt as the last one shrinks
    /// 30: keeping the reader's row puts them 30 pt short of the end, near
    /// enough to follow again, and the pass ends at the end.
    func testAKeepThatLeavesTheReaderFollowingEndsThePassAtTheEnd() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 3140)
        XCTAssertEqual(scroller.mode, .browsing, "60 pt from the end")
        surface.sets = []
        surface.setHeight("m2", 410)
        surface.setHeight("m9", 370)
        surface.layOut()
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.sets.map(\.y), [3150, 3180], "the row kept, then the end")
        XCTAssertEqual(surface.sets.map(\.animated), [false, false])
        XCTAssertEqual(surface.distanceFromBottom, 0)
    }

    func testARowGrowingAboveTheReaderWhileRowsBelowShrinkStillMovesThem() {
        let (_, surface) = browsingReader()
        surface.setHeight("m2", 627)
        surface.setHeight("m9", 100)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2227)
    }

    /// A picture or a card measuring during a fling: the offset moves in
    /// that pass and the fling goes on from there, so what's under it
    /// stays put.
    func testARowGrowingAboveTheReaderDuringAFlingMovesThemAtOnce() {
        let (scroller, surface) = browsingReader()
        surface.isDecelerating = true
        surface.setHeight("m2", 627)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2227)
        XCTAssertEqual(surface.sets.map(\.animated), [false])
        XCTAssertEqual(scroller.mode, .browsing)
    }

    func testARowGrowingAboveTheReaderUnderAFingerMovesThemAtOnce() {
        let (_, surface) = browsingReader()
        surface.isTracking = true
        surface.setHeight("m2", 627)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2227, "the row under the finger stays under it")
    }

    func testTwoRowsGrowingAboveTheReaderInOnePassAddUp() {
        let (_, surface) = browsingReader()
        surface.setHeight("m1", 500)
        surface.setHeight("m2", 527)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2227)
    }

    func testRowsGrowingInSeparatePassesMoveTheReaderEachTime() {
        let (_, surface) = browsingReader()
        surface.setHeight("m1", 500)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2100)
        surface.setHeight("m2", 527)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2227)
    }

    func testGrowthBelowTheReaderNeverMovesThem() {
        let (_, surface) = browsingReader()
        surface.setHeight("m8", 627)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    /// Load earlier: the page lands above the reader, and the pass that
    /// lays it out moves the offset by its height, then by what its
    /// estimates were off as its rows measure. No hold, no time limit.
    func testEarlierMessagesKeepTheReaderOnTheSameRow() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 500)
        scroller.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.insert(Self.ids(-5..<0), height: 120, at: 0)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 1100, "the offset grows by exactly the page's height")

        surface.setHeight("m-1", 70)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 1050)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    /// The page can be laid out before its transcript reaches the
    /// scroller: the reader's row holds in that pass all the same.
    func testEarlierMessagesLaidOutBeforeTheirTranscriptKeepTheRow() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 500)
        surface.insert(Self.ids(-5..<0), height: 120, at: 0)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 1100)
        scroller.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertEqual(surface.contentOffsetY, 1100)
    }

    /// A reader at the top, the Load earlier row above their message: the
    /// page lands between the two, and the reader stays on their message,
    /// not on the row they tapped, which stays first.
    func testEarlierMessagesUnderTheLoadEarlierRowKeepTheReaderOnTheirMessage() {
        let surface = FakeTranscriptSurface(ids: [TranscriptRow.loadEarlierID] + Self.ids(0..<10))
        surface.setHeight(TranscriptRow.loadEarlierID, 44)
        surface.layOut()
        let (scroller, _) = makeScroller(surface: surface)
        surface.userScroll(to: 0)
        XCTAssertEqual(scroller.mode, .browsing)
        scroller.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.insert(Self.ids(-5..<0), height: 120, at: 1)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 600, "the offset grows by exactly the page's height")
        XCTAssertEqual(surface.top(of: "m0"), 44)
    }

    func testEarlierMessagesWhileFollowingStayAtTheEnd() {
        let (scroller, surface) = makeScroller()
        scroller.transcriptChanged(
            messages: Self.messages(-5..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        surface.insert(Self.ids(-5..<0), height: 120, at: 0)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3800)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testARowGrowingAboveTheReaderAsEarlierMessagesLandMovesThemByBoth() {
        let (_, surface) = browsingReader()
        surface.insert(Self.ids(-5..<0), height: 120, at: 0)
        surface.setHeight("m2", 627)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2827)
    }

    /// The reader's row goes (a send waiting on screen becoming the chat's
    /// own row): the next row of their place stands in, and stays still.
    func testWhenTheReadersRowGoesTheNextOneStandsIn() {
        let (_, surface) = makeScroller()
        surface.userScroll(to: 500)
        XCTAssertEqual(surface.top(of: "m3"), 700)
        surface.remove("m2")
        surface.layOut()
        XCTAssertEqual(surface.top(of: "m3"), 700)
        XCTAssertEqual(surface.contentOffsetY, 100)
    }

    /// A reply filling the screen settles into the chat's own row, under a
    /// new id: the row above it stands in, so nothing moves.
    func testAReplyFillingTheScreenSettlingIntoItsRowMovesNothing() {
        let surface = FakeTranscriptSurface()
        surface.append("m10", height: 80)
        surface.append("streaming", height: 2000)
        surface.layOut()
        let (scroller, _) = makeScroller(surface: surface)
        surface.userScroll(to: 4500)
        XCTAssertEqual(scroller.mode, .browsing)
        surface.replace("streaming", with: "m11", height: 1990)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 4500)
        XCTAssertEqual(surface.top(of: "m10"), -500)
    }

    // MARK: - Session switches

    func testASessionSwitchLandsOnTheLatestMessageWithoutAnimation() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)

        scroller.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3200)

        scroller.transcriptChanged(
            messages: Self.messages(100..<140),
            transcriptRevision: 3,
            viewportTransitionGeneration: 2,
            activeSessionKey: keyB
        )
        surface.replaceAll(Self.ids(100..<140), height: 225)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 8200)
        XCTAssertTrue(surface.sets.allSatisfy { !$0.animated })
    }

    func testAnEquivalentSessionSpellingIsNotASwitch() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        let aliasIdentity = ChatScrollSessionIdentity(
            profile: "p",
            canonicalSessionID: "a",
            equivalentSessionIDs: ["a", "runtime-a"],
            isReconciling: false,
            settledRevision: 1
        )
        scroller.renderedSessionChanged(
            to: ChatScrollSessionKey(profile: "p", sessionID: "runtime-a"),
            identity: aliasIdentity,
            viaNotification: false,
            viewportTransitionGeneration: 1
        )
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertEqual(surface.contentOffsetY, 1000)
    }

    func testASessionSwitchForgetsTheReadersRow() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        XCTAssertNotNil(scroller.anchor)
        XCTAssertEqual(scroller.topVisibleMessageID, "m2")
        scroller.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertNil(scroller.anchor)
        XCTAssertNil(scroller.topVisibleMessageID)
    }

    func testANotificationOpeningCancelsRestorationAndFollows() {
        let (scroller, surface) = makeScroller()
        scroller.restorationRequested(
            ChatResumeRestorationRequest(generation: 4, sessionKey: keyA, destination: .latest),
            transcriptRevision: 2
        )
        XCTAssertEqual(scroller.mode, .restoring)

        scroller.notificationHandoffBegan()
        XCTAssertNil(scroller.restoration)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertTrue(events.contains(.cancelAutomaticRestoration))

        surface.setHeight("m9", 2400)
        surface.layOut()
        scroller.notificationHandoffFinished()
        XCTAssertEqual(surface.contentOffsetY, 5200)
    }

    // MARK: - Explicit commands

    func testTheJumpToLatestAnimatesOnlyAShortDistance() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 2400)
        scroller.explicitLatestRequested(animated: true)
        XCTAssertEqual(surface.sets.last?.animated, true)

        surface.userScroll(to: 0)
        clock += 1
        scroller.explicitLatestRequested(animated: true)
        XCTAssertEqual(surface.sets.last?.animated, false, "a long jump snaps instead of sweeping")
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    func testAnAnimatedJumpIsNotInterruptedAndGetsAFinalPin() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 2400)
        scroller.explicitLatestRequested(animated: true)
        let setsAfterJump = surface.sets.count

        surface.setHeight("m9", 600)
        surface.layOut()
        XCTAssertEqual(surface.sets.count, setsAfterJump, "no pin mid-animation")

        clock += TranscriptScroller.latestAnimationDuration
        runScheduled()
        XCTAssertEqual(surface.contentOffsetY, 3400)
        XCTAssertEqual(surface.sets.last?.animated, false)
    }

    func testASendFromFarAwayLandsOnTheLatestMessage() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 100)
        scroller.explicitLatestRequested(animated: false)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertTrue(events.contains(.cancelAutomaticRestoration))
    }

    func testATitleTapGoesToTheTop() {
        let (scroller, surface) = makeScroller()
        surface.insetTop = 60
        scroller.explicitTopRequested()
        XCTAssertEqual(surface.contentOffsetY, -60)
        XCTAssertEqual(scroller.mode, .browsing)

        surface.setHeight("m9", 900)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, -60)
    }

    func testATitleTapOnAShortChatKeepsFollowing() {
        // Kept here: the scroller holds its surface weakly.
        let surface = FakeTranscriptSurface(rowHeight: 60)
        let (scroller, _) = makeScroller(surface: surface)
        scroller.explicitTopRequested()
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 0)
    }

    func testAJumpToLatestDoesNotTakeTheTranscriptFromAFinger() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        surface.isTracking = true
        scroller.explicitLatestRequested(animated: false)
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    /// The answerable question's row: at the top, browsing there, so later
    /// rows don't move it.
    func testAMessageRequestPutsItsRowAtTheTopWhileBrowsing() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        scroller.explicitMessageRequested(id: "m5")
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertEqual(scroller.topVisibleMessageID, "m5")

        surface.append("m10", height: 400)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 2000, "later rows don't move it")
    }

    func testAMessageRequestDoesNotOverrideAFingerOnTheScreen() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        surface.isTracking = true
        scroller.explicitMessageRequested(id: "m5")
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    // MARK: - Restoration

    private func anchorRequest(
        _ scroller: TranscriptScroller,
        row index: Int,
        generation: UInt64 = 9
    ) -> ChatResumeRestorationRequest {
        let target = scroller.targets[index]
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
        _ scroller: TranscriptScroller,
        row index: Int,
        fallbackRow fallbackIndex: Int,
        generation: UInt64 = 9
    ) -> ChatResumeRestorationRequest {
        let target = scroller.targets[index]
        let fallback = scroller.targets[fallbackIndex]
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

    /// Every row has a frame, so a saved place is made as soon as it's
    /// asked for: no ticks, no reveal.
    func testRestorationPlacesTheSavedRowAtTheTopAtOnce() {
        let (scroller, surface) = makeScroller()
        surface.insetTop = 50
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 1)
        XCTAssertEqual(surface.contentOffsetY, 1950, "row 2000 - inset 50")
        XCTAssertNil(scroller.restoration)
        XCTAssertEqual(events.last, .completeRestoration(generation: 9))
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertEqual(scroller.topVisibleMessageID, "m5")

        surface.setHeight("m9", 1000)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 1950, "the restored place is not followed away")
    }

    func testRestorationNearTheEndFollows() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        scroller.restorationRequested(anchorRequest(scroller, row: 9), transcriptRevision: 1)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertEqual(scroller.topVisibleMessageID, "m9")
    }

    func testAPendingQuestionOverridesTheSavedPlace() {
        let (scroller, surface) = makeScroller()
        surface.insetTop = 50
        scroller.transcriptChanged(
            messages: messagesWithClarify(status: .pending),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        scroller.restorationRequested(pendingClarifyRequest(scroller, row: 5, fallbackRow: 2), transcriptRevision: 2)
        XCTAssertEqual(surface.contentOffsetY, 1950, "the pending question takes priority over m2")
        XCTAssertNil(scroller.restoration)
        XCTAssertEqual(scroller.topVisibleMessageID, "m5")
    }

    func testAnAnsweredQuestionFallsBackToTheSavedPlace() {
        let (scroller, surface) = makeScroller()
        surface.insetTop = 50
        scroller.transcriptChanged(
            messages: messagesWithClarify(status: .pending),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        // Asked for with the next transcript: it waits for those rows.
        scroller.restorationRequested(pendingClarifyRequest(scroller, row: 5, fallbackRow: 2), transcriptRevision: 3)
        XCTAssertEqual(scroller.mode, .restoring)

        scroller.transcriptChanged(
            messages: messagesWithClarify(status: .answered, answer: "yes"),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )
        XCTAssertEqual(surface.contentOffsetY, 750, "a resolved card doesn't replace the saved place")
        XCTAssertEqual(scroller.topVisibleMessageID, "m2")
    }

    func testAMissingQuestionFallsBackToTheSavedPlace() {
        let (scroller, surface) = makeScroller()
        let fallback = scroller.targets[2]
        scroller.restorationRequested(
            ChatResumeRestorationRequest(
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
            ),
            transcriptRevision: 1
        )
        XCTAssertEqual(surface.contentOffsetY, 800, "m2 remains the fallback")
        XCTAssertEqual(scroller.topVisibleMessageID, "m2")
    }

    /// The transcript can name rows the layout hasn't drawn yet: the place
    /// waits for the pass that draws its row.
    func testRestorationWaitsForItsRowToBeDrawn() {
        let (scroller, surface) = makeScroller()
        scroller.transcriptChanged(
            messages: Self.messages(0..<14),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        scroller.restorationRequested(anchorRequest(scroller, row: 10), transcriptRevision: 2)
        XCTAssertEqual(scroller.mode, .restoring, "m10 has no frame yet")

        for id in Self.ids(10..<14) { surface.append(id, height: 400) }
        surface.layOut()
        XCTAssertNil(scroller.restoration)
        XCTAssertEqual(surface.contentOffsetY, 4000)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertEqual(events.last, .completeRestoration(generation: 9))
    }

    func testRestorationWaitsForTheRenderedTranscript() {
        let (scroller, surface) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        XCTAssertEqual(surface.contentOffsetY, 3200, "nothing moves until revision 2 is drawn")
        XCTAssertEqual(scroller.mode, .restoring)

        scroller.transcriptChanged(
            messages: Self.messages(0..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertEqual(surface.contentOffsetY, 2000)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    func testRestorationToTheLatestMessageCompletesFollowing() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 100)
        scroller.restorationRequested(
            ChatResumeRestorationRequest(generation: 3, sessionKey: keyA, destination: .latest),
            transcriptRevision: 1
        )
        XCTAssertNil(scroller.restoration)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 3200)
        XCTAssertTrue(events.contains(.completeRestoration(generation: 3)))
    }

    func testDisappearingEndsAWaitingRestoration() {
        let (scroller, _) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        XCTAssertEqual(scroller.mode, .restoring)
        scroller.viewDisappeared()
        XCTAssertNil(scroller.restoration)
        XCTAssertNotEqual(scroller.mode, .restoring)
    }

    /// The deadline doesn't count time in the background: a pause disarms
    /// it, so the timer that came due there does nothing when it runs on
    /// the return before the scroller hears of it, and the place is made
    /// on the return.
    func testRestorationWaitsOutTheBackground() {
        let (scroller, surface) = makeScroller()
        surface.insetTop = 50
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        scroller.setPaused(true)
        scroller.transcriptChanged(
            messages: Self.messages(0..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        clock += 60
        XCTAssertEqual(scheduled.map(\.delay), [TranscriptScroller.restorationDeadline])
        runScheduled()
        XCTAssertFalse(events.contains(.abandonRestoration(generation: 9)))
        XCTAssertFalse(scroller.showsJumpToLatest, "no jump button while restoring")
        XCTAssertEqual(scroller.mode, .restoring)

        scroller.setPaused(false)
        XCTAssertEqual(surface.contentOffsetY, 1950)
        XCTAssertEqual(events.last, .completeRestoration(generation: 9))
    }

    /// The return arms only the foreground time the place has left.
    func testTheRestorationDeadlineCountsOnlyForegroundTime() {
        let (scroller, _) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        clock += 0.5
        scroller.setPaused(true)
        clock += 60
        runScheduled()
        XCTAssertEqual(scroller.mode, .restoring, "the deadline that came due in the background does nothing")

        scroller.setPaused(false)
        XCTAssertEqual(scheduled.map(\.delay), [TranscriptScroller.restorationDeadline - 0.5])
        runScheduled()
        XCTAssertNil(scroller.restoration)
        XCTAssertEqual(events.last, .abandonRestoration(generation: 9))
    }

    func testAMissingMessageRequestDoesNotCancelRestoration() {
        let (scroller, _) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        events = []
        scroller.explicitMessageRequested(id: "not-in-transcript")
        XCTAssertEqual(scroller.mode, .restoring)
        XCTAssertFalse(events.contains(.cancelAutomaticRestoration))
    }

    func testAValidMessageRequestCancelsRestoration() {
        let (scroller, surface) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        events = []
        scroller.explicitMessageRequested(id: "m3")
        XCTAssertNil(scroller.restoration)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertTrue(events.contains(.cancelAutomaticRestoration))
        XCTAssertEqual(surface.contentOffsetY, 1200)
    }

    func testAMessageRequestWhilePausedDoesNotCancelRestoration() {
        let (scroller, _) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        scroller.setPaused(true)
        events = []
        scroller.explicitMessageRequested(id: "m5")
        XCTAssertEqual(scroller.mode, .restoring)
        XCTAssertFalse(events.contains(.cancelAutomaticRestoration))
    }

    func testAReplacementRestorationPublishesItsGeneration() {
        let (scroller, _) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        scroller.restorationRequested(
            ChatResumeRestorationRequest(generation: 12, sessionKey: keyA, destination: .latest),
            transcriptRevision: 2
        )
        XCTAssertEqual(scroller.mode, .restoring)
        XCTAssertEqual(scroller.renderInputs.renderedScrollScope?.restorationGeneration, 12)
    }

    func testRestorationForAnotherConversationIsAbandoned() {
        let (scroller, _) = makeScroller()
        scroller.restorationRequested(
            ChatResumeRestorationRequest(generation: 5, sessionKey: keyB, destination: .latest),
            transcriptRevision: 1
        )
        XCTAssertNil(scroller.restoration)
        XCTAssertEqual(events.last, .abandonRestoration(generation: 5))
    }

    func testRestorationGivesUpAtItsDeadline() {
        let (scroller, _) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        XCTAssertEqual(scheduled.map(\.delay), [TranscriptScroller.restorationDeadline])
        runScheduled()
        XCTAssertNil(scroller.restoration)
        XCTAssertEqual(events.last, .abandonRestoration(generation: 9))
        XCTAssertTrue(scroller.isFollowingLatest, "left at the end, following")
    }

    func testOnlyTheLatestRestorationsDeadlineActs() {
        let (scroller, _) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        scroller.restorationRequested(anchorRequest(scroller, row: 6, generation: 10), transcriptRevision: 2)
        scheduled.removeFirst().body()
        XCTAssertEqual(scroller.restoration?.request.generation, 10, "the first request's deadline is stale")
        runScheduled()
        XCTAssertEqual(events.last, .abandonRestoration(generation: 10))
    }

    func testADragCancelsRestoration() {
        let (scroller, surface) = makeScroller()
        scroller.restorationRequested(anchorRequest(scroller, row: 5), transcriptRevision: 2)
        surface.userScroll(to: 1500)
        XCTAssertNil(scroller.restoration)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertTrue(events.contains(.cancelAutomaticRestoration))
    }

    // MARK: - Background

    func testAPausedScrollerLeavesTheOffsetAloneAndCatchesUpOnReturn() {
        let (scroller, surface) = makeScroller()
        scroller.setPaused(true)
        surface.setHeight("m9", 1400)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3200)

        scroller.setPaused(false)
        XCTAssertEqual(surface.contentOffsetY, 4200)
    }

    func testAJumpToLatestInTheBackgroundWaitsForTheForeground() {
        let (scroller, surface) = makeScroller()
        surface.userScroll(to: 1000)
        scroller.setPaused(true)
        scroller.explicitLatestRequested(animated: false)
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertTrue(scroller.isFollowingLatest)

        scroller.setPaused(false)
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    func testASessionSwitchInTheBackgroundDoesNotScroll() {
        let (scroller, surface) = makeScroller()
        scroller.setPaused(true)
        let setsBefore = surface.sets.count
        scroller.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertEqual(surface.sets.count, setsBefore)

        surface.setHeight("m9", 1400)
        surface.layOut()
        scroller.setPaused(false)
        XCTAssertEqual(surface.contentOffsetY, 4200, "returning pins the new conversation")
    }

    func testChromeInputsFromUIKitCallbacksPublishOnTheNextTurn() {
        let (scroller, surface) = makeScroller()
        XCTAssertFalse(scroller.chrome.inputs.showsJumpToLatest)

        surface.userScroll(to: 1000)
        XCTAssertTrue(scroller.showsJumpToLatest)
        XCTAssertFalse(
            scroller.chrome.inputs.showsJumpToLatest,
            "a change made inside a UIKit callback must not publish during the SwiftUI update"
        )

        drainMainQueue()
        XCTAssertTrue(scroller.chrome.inputs.showsJumpToLatest)
        XCTAssertFalse(scroller.chrome.inputs.isFollowingLatest)

        scroller.explicitLatestRequested(animated: false)
        XCTAssertTrue(scroller.chrome.inputs.isFollowingLatest, "a command from SwiftUI publishes directly")
    }

    func testTrackedMessageVisibilityPublishesOnlyAtTheViewportsEdges() {
        let (scroller, surface) = makeScroller()
        scroller.trackMessageVisibility(of: "m5")
        XCTAssertEqual(scroller.chrome.inputs.visibilityTrackedMessageID, "m5")
        XCTAssertTrue(scroller.chrome.inputs.isVisibilityTrackedMessageOffscreen)

        surface.userScroll(to: 1900)
        drainMainQueue()
        XCTAssertFalse(scroller.chrome.inputs.isVisibilityTrackedMessageOffscreen)

        var sent = 0
        let watch = scroller.chrome.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }
        surface.userScroll(to: 1950)
        drainMainQueue()
        XCTAssertEqual(sent, 0, "a scroll that leaves the row on screen publishes nothing")

        surface.userScroll(to: 100)
        drainMainQueue()
        XCTAssertTrue(scroller.chrome.inputs.isVisibilityTrackedMessageOffscreen)

        scroller.trackMessageVisibility(of: nil)
        XCTAssertNil(scroller.chrome.inputs.visibilityTrackedMessageID)
        XCTAssertFalse(scroller.chrome.inputs.isVisibilityTrackedMessageOffscreen)
    }

    func testReduceMotionSnapsTheJumpToLatest() {
        let (scroller, surface) = makeScroller(reducedMotion: true)
        surface.userScroll(to: 2400)
        scroller.explicitLatestRequested(animated: true)
        XCTAssertEqual(surface.sets.last?.animated, false)
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    /// Each offset the scroller writes is in the recorder with the rule
    /// that asked for it, and so is each change of mode.
    func testTheRecorderNamesTheRuleBehindEachWrite() {
        ChatViewportTrace.shared.reset()
        let (_, surface) = makeScroller()
        surface.userScroll(to: 2000)
        surface.setHeight("m2", 627)
        surface.layOut()
        let lines = ChatViewportTrace.shared.entries.map(\.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("write pin: 0.0 -> 3200.0") }, "\(lines)")
        XCTAssertTrue(lines.contains("mode following -> browsing"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("write keep row: 2000.0 -> 2227.0") }, "\(lines)")
    }

    // MARK: - Long replies stop at their start (#365)

    /// Session "a" at its end with the hold switched on, after a send of
    /// m10: the message is laid out at 4000...4080, so the hold stops at
    /// 3963, the message 37 pt below the viewport's top, and the room under
    /// it makes the content at least 3963 + 800 = 4763 tall. Nothing moves
    /// before the room is laid out: the reader is at the end, 3280.
    private func sendIntoHold(reducedMotion: Bool = false) -> (TranscriptScroller, FakeTranscriptSurface) {
        let (scroller, surface) = makeScroller(reducedMotion: reducedMotion)
        scroller.holdsRepliesAtStart = { true }
        scroller.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        scroller.explicitLatestRequested(animated: false, armsReplyHold: true)
        surface.append("m10", height: 80)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3280, "nothing moves before the room is laid out")
        XCTAssertTrue(scroller.replyHoldArmed)
        XCTAssertEqual(scroller.replyRoomHeight, 4763)
        XCTAssertEqual(surface.askedReserve, 4763)
        return (scroller, surface)
    }

    /// The reply under the sent message, `height` tall so far, laid out
    /// with the room the scroller asked for.
    private func streamReply(_ surface: FakeTranscriptSurface, _ height: CGFloat) {
        if surface.contains("streaming") {
            surface.setHeight("streaming", height)
        } else {
            surface.append("streaming", height: height)
        }
        surface.layOut()
    }

    /// The landing's animation has had its time.
    private func finishLandingAnimation() {
        clock += TranscriptScroller.latestAnimationDuration + 0.1
        runScheduled()
    }

    /// The offsets the scroller wrote never went up: the hold is a stop.
    private func assertNeverMovedUp(_ surface: FakeTranscriptSurface, file: StaticString = #filePath, line: UInt = #line) {
        let offsets = surface.sets.map(\.y)
        XCTAssertEqual(offsets, offsets.sorted(), "an offset went up", file: file, line: line)
    }

    /// #1436: the sent message moves to the top once its room is laid out,
    /// in one animated move, and the reply streams into the room under it
    /// without moving anything; once it outgrows the screen the reader is
    /// left browsing at the same place.
    func testASentMessageMovesToTheTopAndALongReplyStopsThere() {
        let (scroller, surface) = sendIntoHold()
        surface.sets = []
        surface.layOut()
        XCTAssertEqual(surface.sets.map(\.y), [3963])
        XCTAssertEqual(surface.sets.map(\.animated), [true], "the move to the top animates")
        XCTAssertTrue(scroller.isFollowingLatest)
        finishLandingAnimation()
        XCTAssertEqual(surface.sets.count, 1)
        // The reply fills the room: nothing moves.
        streamReply(surface, 600)
        streamReply(surface, 683)
        XCTAssertEqual(surface.sets.count, 1)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertFalse(scroller.showsJumpToLatest)
        // It runs past the screen: still nothing moves, and the reader is
        // left browsing at the stop.
        streamReply(surface, 700)
        XCTAssertTrue(scroller.isFollowingLatest, "within the near-bottom distance it is still following")
        streamReply(surface, 1100)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertTrue(scroller.showsJumpToLatest)
        XCTAssertTrue(scroller.replyHoldArmed, "armed until the reader is below the reply's start")
        streamReply(surface, 2000)
        XCTAssertEqual(surface.contentOffsetY, 3963)
        XCTAssertEqual(surface.sets.count, 1)
    }

    func testWithReduceMotionTheSentMessageSnapsToTheTop() {
        let (_, surface) = sendIntoHold(reducedMotion: true)
        surface.sets = []
        surface.layOut()
        XCTAssertEqual(surface.sets.map(\.y), [3963])
        XCTAssertEqual(surface.sets.map(\.animated), [false])
    }

    /// Long replies switched off while the room is there: it goes at once,
    /// and following goes to the end.
    func testSwitchingLongRepliesOffTakesTheRoomAway() {
        let (scroller, surface) = sendIntoHold()
        surface.layOut()
        finishLandingAnimation()
        scroller.holdsRepliesAtStart = { false }
        scroller.replyStartPreferenceChanged()
        XCTAssertEqual(scroller.replyRoomHeight, 0)
        XCTAssertEqual(surface.askedReserve, 0, "asked for at once")
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3280)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    /// The room lags a pass behind a bar changing height (a keyboard
    /// opening, then closing): the reader stays at the stop instead of
    /// going down to the end and back.
    func testTheRoomLaggingBehindAKeyboardLeavesTheReaderAtTheStop() {
        let (scroller, surface) = sendIntoHold()
        surface.layOut()
        finishLandingAnimation()
        surface.sets = []
        surface.insetBottom = 300
        surface.insetsChanged()
        XCTAssertEqual(scroller.replyRoomHeight, 4463)
        surface.layOut()
        XCTAssertEqual(surface.contentHeight, 4463)
        surface.insetBottom = 0
        surface.insetsChanged()
        XCTAssertEqual(surface.contentOffsetY, 3963, "content shorter than the room for a pass")
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3963)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    /// Chips appearing under a reply that fits in its room leave the
    /// message at the top: the room shrinks for them.
    func testABottomBarGrowingUnderTheRoomLeavesTheMessageAtTheTop() {
        let (scroller, surface) = sendIntoHold()
        surface.layOut()
        finishLandingAnimation()
        surface.sets = []
        surface.insetBottom = 52
        surface.insetsChanged()
        XCTAssertEqual(scroller.replyRoomHeight, 4711)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3963)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertTrue(surface.sets.isEmpty)
    }

    /// The next send lands in the room the last reply left: nothing moves
    /// until the new message's own room is laid out.
    func testTheNextSendKeepsTheRoomUntilItsMessageIsLaidOut() {
        let (scroller, surface) = sendIntoHold()
        surface.layOut()
        finishLandingAnimation()
        streamReply(surface, 100)
        surface.replace("streaming", with: "m11")
        scroller.transcriptChanged(
            messages: Self.messages(0..<13),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )
        scroller.explicitLatestRequested(animated: false, armsReplyHold: true)
        XCTAssertEqual(scroller.replyRoomHeight, 4763, "the last reply's room stays")
        surface.sets = []
        surface.append("m12", height: 80)
        surface.layOut()
        XCTAssertTrue(surface.sets.isEmpty, "nothing moves before its room is laid out")
        XCTAssertEqual(scroller.replyRoomHeight, 4943)
        surface.layOut()
        XCTAssertEqual(surface.sets.map(\.y), [4143])
        XCTAssertEqual(surface.sets.map(\.animated), [true])
    }

    /// The send can reach the scroller before the sent message does. A
    /// reader at the last reply's stop goes to the end for the send, not to
    /// that stop, and the new message moves to the top once it has a frame
    /// and room.
    func testASendFromTheLastStopBeforeItsMessageArrivesLandsTheNewMessage() {
        let (scroller, surface) = sendIntoHold()
        streamReply(surface, 1120)
        XCTAssertEqual(surface.contentOffsetY, 3963)
        XCTAssertEqual(scroller.mode, .browsing)
        scroller.explicitLatestRequested(animated: false, armsReplyHold: true)
        XCTAssertEqual(surface.contentOffsetY, 4400)
        XCTAssertTrue(scroller.isFollowingLatest)
        surface.replace("streaming", with: "m11")
        scroller.transcriptChanged(
            messages: Self.messages(0..<13),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )
        surface.append("m12", height: 80)
        surface.layOut()
        XCTAssertEqual(scroller.replyRoomHeight, 5963)
        surface.sets = []
        surface.layOut()
        XCTAssertEqual(surface.sets.map(\.y), [5163])
        XCTAssertEqual(surface.sets.map(\.animated), [true])
    }

    func testClearingTheTranscriptDisarmsTheHoldAndItsRoom() {
        let (scroller, surface) = sendIntoHold()
        scroller.transcriptChanged(messages: [], transcriptRevision: 3, viewportTransitionGeneration: 1)
        XCTAssertFalse(scroller.replyHoldArmed)
        XCTAssertEqual(scroller.replyRoomHeight, 0)
        XCTAssertEqual(surface.askedReserve, 0)
    }

    /// A message taller than a third of the screen stops with its last
    /// third showing, so the reply still has the screen under it.
    func testATallMessageStopsWithItsLastThirdShowing() {
        let (scroller, surface) = makeScroller()
        scroller.holdsRepliesAtStart = { true }
        scroller.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        scroller.explicitLatestRequested(animated: false, armsReplyHold: true)
        surface.append("m10", height: 600)
        surface.layOut()
        streamReply(surface, 1400)
        // 4600 - 800 / 3
        XCTAssertEqual(surface.contentOffsetY, 4333.33, accuracy: 0.01)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    func testDisarmingTheHoldTakesTheRoomAway() {
        let (scroller, surface) = sendIntoHold()
        scroller.explicitLatestRequested(animated: false)
        XCTAssertEqual(scroller.replyRoomHeight, 0)
        XCTAssertEqual(surface.askedReserve, 0, "asked for at once from a command")
    }

    func testABigChunkStopsAtTheReplyStartWithoutGoingPastIt() {
        let (scroller, surface) = sendIntoHold()
        surface.sets = []
        // One layout pass carries the reply well past a screen.
        streamReply(surface, 1120)
        XCTAssertEqual(surface.contentOffsetY, 3963)
        XCTAssertEqual(scroller.mode, .browsing)
        assertNeverMovedUp(surface)
    }

    func testWithTheSettingOffAReplyIsFollowedToItsEnd() {
        let (scroller, surface) = sendIntoHold()
        scroller.holdsRepliesAtStart = { false }
        streamReply(surface, 1920)
        XCTAssertEqual(surface.contentOffsetY, 5200)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testTheJumpToLatestGoesPastTheHoldAndFollowsTheEnd() {
        let (scroller, surface) = sendIntoHold()
        streamReply(surface, 1120)
        XCTAssertEqual(surface.contentOffsetY, 3963)
        scroller.explicitLatestRequested(animated: false)
        XCTAssertEqual(surface.contentOffsetY, 4400)
        streamReply(surface, 1920)
        XCTAssertEqual(surface.contentOffsetY, 5200)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testAReaderBackAtTheEndFollowsTheRestOfTheReply() {
        let (scroller, surface) = sendIntoHold()
        streamReply(surface, 1120)
        XCTAssertEqual(surface.contentOffsetY, 3963)
        // Read down to the end while it still streams: following again, to
        // the end this time.
        surface.userScroll(to: 4400)
        XCTAssertTrue(scroller.isFollowingLatest)
        surface.sets = []
        streamReply(surface, 1920)
        XCTAssertEqual(surface.contentOffsetY, 5200)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertFalse(scroller.replyHoldArmed)
        assertNeverMovedUp(surface)
    }

    func testATurnStartedElsewhereStopsAtItsStartToo() {
        let (scroller, surface) = makeScroller()
        scroller.holdsRepliesAtStart = { true }
        // Another device sent m10; no send here.
        scroller.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(scroller.replyHoldArmed)
        surface.append("m10", height: 80)
        surface.layOut()
        streamReply(surface, 1120)
        XCTAssertEqual(surface.contentOffsetY, 3963)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    func testOpeningAChatDoesNotArmTheHold() {
        let (scroller, surface) = makeScroller()
        scroller.holdsRepliesAtStart = { true }
        XCTAssertFalse(scroller.replyHoldArmed)
        surface.setHeight("m9", 1400)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 4200)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    /// A chat opened on its saved rows: Hermes' rows taking over are its
    /// first sync, so a turn started elsewhere since it was saved doesn't
    /// arm the hold, as when it opened on no rows (#1533). A turn after
    /// that does.
    func testHermesRowsAfterSavedOnesDoNotArmTheHold() {
        let (scroller, surface) = makeScroller()
        scroller.holdsRepliesAtStart = { true }
        scroller.transcriptChanged(
            messages: Self.messages(0..<10),
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true,
            isProvisional: true
        )
        scroller.transcriptChanged(
            messages: Self.messages(0..<12),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertFalse(scroller.replyHoldArmed)

        scroller.transcriptChanged(
            messages: Self.messages(0..<13),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(scroller.replyHoldArmed)
        withExtendedLifetime(surface) {}
    }

    /// Saved rows that matched Hermes' leave without the rows drawn
    /// changing, and the view tells the scroller with the same rows: the
    /// next turn, one started elsewhere included, arms the hold (#1550
    /// review).
    func testSavedRowsThatMatchedHermesLeaveAndTheNextTurnArmsTheHold() {
        let (scroller, surface) = makeScroller()
        scroller.holdsRepliesAtStart = { true }
        scroller.transcriptChanged(
            messages: Self.messages(0..<10),
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true,
            isProvisional: true
        )
        scroller.transcriptChanged(
            messages: Self.messages(0..<10),
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )

        scroller.transcriptChanged(
            messages: Self.messages(0..<11),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(scroller.replyHoldArmed)
        withExtendedLifetime(surface) {}
    }

    func testTheTitleTapDisarmsTheHold() {
        let (scroller, _) = sendIntoHold()
        scroller.explicitTopRequested()
        XCTAssertFalse(scroller.replyHoldArmed)
    }

    func testASessionSwitchDisarmsTheHold() {
        let (scroller, _) = sendIntoHold()
        scroller.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertFalse(scroller.replyHoldArmed)
    }

    // MARK: - An unread chat opens at its latest reply (#365)

    /// Session "a" opened unread: its last turn is m8, a short message at
    /// 3200...3280, and m9, a reply of 1600 under it. The end is 4080; the
    /// hold stops at 3163.
    private func makeUnreadScroller(attached: Bool = true) -> (TranscriptScroller, FakeTranscriptSurface) {
        let surface = FakeTranscriptSurface()
        surface.setHeight("m8", 80)
        surface.setHeight("m9", 1600)
        surface.layOut()
        let (scroller, _) = makeScroller(surface: surface, attached: attached)
        scroller.holdsRepliesAtStart = { true }
        return (scroller, surface)
    }

    func testAnUnreadReplyLandsWhereTheHoldStops() {
        let (scroller, surface) = makeUnreadScroller()
        XCTAssertEqual(surface.contentOffsetY, 4080)
        scroller.replyStartLandingRequested()
        XCTAssertEqual(scheduled.count, 1, "on the next turn")
        runScheduled()
        XCTAssertEqual(surface.contentOffsetY, 3163)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertTrue(scroller.replyHoldArmed)
        // The notification's handoff ends after the landing: it stays.
        scroller.notificationHandoffFinished()
        XCTAssertEqual(surface.contentOffsetY, 3163)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    /// An unread chat opened at its reply has no room under it: the reply
    /// is already there.
    func testAnUnreadLandingMakesNoRoom() {
        let (scroller, surface) = makeUnreadScroller()
        scroller.replyStartLandingRequested()
        runScheduled()
        XCTAssertEqual(scroller.replyRoomHeight, 0)
        XCTAssertEqual(surface.askedReserve, 0)
        XCTAssertEqual(surface.contentOffsetY, 3163)
    }

    func testAShortUnreadReplyStaysAtTheEnd() {
        let surface = FakeTranscriptSurface()
        surface.setHeight("m8", 80)
        surface.setHeight("m9", 300)
        surface.layOut()
        let (scroller, _) = makeScroller(surface: surface)
        scroller.holdsRepliesAtStart = { true }
        scroller.replyStartLandingRequested()
        runScheduled()
        XCTAssertEqual(surface.contentOffsetY, 2780)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertTrue(scroller.replyHoldArmed, "the reply may still be running")
    }

    func testAReaderWhoScrolledBeforeTheLandingKeepsTheirPlace() {
        let (scroller, surface) = makeUnreadScroller()
        scroller.replyStartLandingRequested()
        surface.userScroll(to: 1000)
        runScheduled()
        XCTAssertEqual(surface.contentOffsetY, 1000)
        XCTAssertFalse(scroller.replyHoldArmed)
    }

    func testALandingSwitchedOffBeforeItRunsDoesNothing() {
        let (scroller, surface) = makeUnreadScroller()
        var on = true
        scroller.holdsRepliesAtStart = { on }
        scroller.replyStartLandingRequested()
        on = false
        runScheduled()
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 4080)
    }

    func testALeftChatForgetsItsLanding() {
        let (scroller, surface) = makeUnreadScroller()
        scroller.replyStartLandingRequested()
        runScheduled()
        XCTAssertEqual(surface.contentOffsetY, 3163)
        scroller.viewDisappeared()
        // A later notification for this chat takes it to the end again.
        scroller.notificationHandoffBegan()
        scroller.notificationHandoffFinished()
        XCTAssertEqual(surface.contentOffsetY, 4080)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testALeftChatKeepsAnArmedHold() {
        let (scroller, surface) = sendIntoHold()
        scroller.viewDisappeared()
        XCTAssertTrue(scroller.replyHoldArmed)
        // Back with the reply still running: it stops at its start.
        streamReply(surface, 1120)
        XCTAssertEqual(surface.contentOffsetY, 3963)
    }

    func testALandingBeforeTheTranscriptIsAttachedLandsWhenItIs() {
        let (scroller, surface) = makeUnreadScroller(attached: false)
        scroller.replyStartLandingRequested()
        runScheduled()
        XCTAssertEqual(surface.contentOffsetY, 0, "nothing to land on yet")
        scroller.attach(surface)
        XCTAssertEqual(surface.contentOffsetY, 3163)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    func testABackgroundedLandingLandsOnResume() {
        let (scroller, surface) = makeUnreadScroller()
        scroller.setPaused(true)
        scroller.replyStartLandingRequested()
        runScheduled()
        XCTAssertEqual(surface.contentOffsetY, 4080)
        scroller.setPaused(false)
        XCTAssertEqual(surface.contentOffsetY, 3163)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    func testANotificationOpenGoesPastAnArmedHold() {
        let (scroller, surface) = sendIntoHold()
        scroller.notificationHandoffBegan()
        XCTAssertFalse(scroller.replyHoldArmed)
        streamReply(surface, 1120)
        XCTAssertEqual(surface.contentOffsetY, 4400)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    func testTheLandingWaitsForTheSetting() {
        let (scroller, surface) = makeScroller()
        scroller.replyStartLandingRequested()
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertEqual(surface.contentOffsetY, 3200)
    }

    /// An unread chat left mid-turn asks for its landing as it opens, from
    /// its saved rows, and the view can hand the scroller that request
    /// before the switch the same open made: the switch keeps it (#1533).
    func testASwitchKeepsTheLandingItsOwnOpenAskedFor() {
        let (scroller, surface) = makeScroller()
        scroller.holdsRepliesAtStart = { true }
        scroller.replyStartLandingRequested(viewportTransitionGeneration: 2)
        scroller.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        scroller.transcriptChanged(
            messages: Self.messages(10..<20),
            transcriptRevision: 2,
            viewportTransitionGeneration: 2,
            isInitialSync: true
        )
        surface.replaceAll(Self.ids(10..<20), height: 400)
        surface.setHeight("m18", 80)
        surface.setHeight("m19", 1600)
        surface.layOut()
        runScheduled()
        XCTAssertEqual(surface.contentOffsetY, 3163, "it lands at the start of b's reply")
        XCTAssertEqual(scroller.mode, .browsing)
    }

    /// A landing an earlier open asked for doesn't follow the reader into
    /// the next chat they open before it ran.
    func testASwitchDropsALandingAnEarlierOpenAskedFor() {
        let (scroller, surface) = makeScroller()
        scroller.holdsRepliesAtStart = { true }
        scroller.replyStartLandingRequested(viewportTransitionGeneration: 1)
        scroller.renderedSessionChanged(
            to: keyB,
            identity: identity("b"),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        scroller.transcriptChanged(
            messages: Self.messages(10..<20),
            transcriptRevision: 2,
            viewportTransitionGeneration: 2,
            isInitialSync: true
        )
        surface.replaceAll(Self.ids(10..<20), height: 400)
        surface.setHeight("m18", 80)
        surface.setHeight("m19", 1600)
        surface.layOut()
        runScheduled()
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertEqual(surface.contentOffsetY, 4080)
    }

    // MARK: - Group rooms (#1533)

    private static func eventIDs(_ range: Range<Int>) -> Set<String> {
        Set(range.map { "e\($0)" })
    }

    /// A group room's scroller, as GroupChatView sets it up: no session,
    /// ten events e0...e9 400 pt each on a surface 800 pt tall, told as the
    /// room's rows box tells it, with long replies stopping at their start.
    /// Attached, it's at the end, 3200.
    private func makeRoomScroller() -> (TranscriptScroller, FakeTranscriptSurface) {
        let surface = FakeTranscriptSurface(ids: (0..<10).map { "e\($0)" })
        let scroller = TranscriptScroller(
            now: { [unowned self] in self.clock },
            prefersReducedMotion: { false },
            schedule: { [unowned self] delay, body in self.scheduled.append((delay, body)) }
        )
        scrollers.append(scroller)
        surface.scroller = scroller
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<10), replyStart: nil)
        scroller.holdsRepliesAtStart = { true }
        scroller.attach(surface)
        XCTAssertEqual(surface.contentOffsetY, 3200)
        return (scroller, surface)
    }

    /// A member's message longer than the screen stops at its start, 37 pt
    /// under the top, and the reader is left browsing there: rows after it
    /// don't move them.
    func testARoomStopsAtTheStartOfALongNewMemberMessage() {
        let (scroller, surface) = makeRoomScroller()
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<11), replyStart: "e10")
        XCTAssertTrue(scroller.replyHoldArmed, "armed before the message is laid out")
        surface.append("e10", height: 1600)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3963)
        XCTAssertEqual(scroller.mode, .browsing)
        XCTAssertTrue(scroller.showsJumpToLatest)
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<12), replyStart: nil)
        surface.append("e11", height: 400)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3963)
    }

    /// One that fits is followed to its end; measured taller than its
    /// guess, it stops at its start then.
    func testAShortNewMemberMessageIsFollowedUntilItMeasuresLonger() {
        let (scroller, surface) = makeRoomScroller()
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<11), replyStart: "e10")
        surface.append("e10", height: 300)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3500)
        XCTAssertTrue(scroller.isFollowingLatest)
        surface.setHeight("e10", 1600)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3963)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    /// After a message that fit, a member starting its turn (or a caption)
    /// is followed to the end, as the room did before: it isn't a message
    /// running past the screen.
    func testAMemberStartingItsTurnAfterAShortMessageIsFollowed() {
        let (scroller, surface) = makeRoomScroller()
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<11), replyStart: "e10")
        surface.append("e10", height: 750)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3950)
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<11), replyStart: nil)
        XCTAssertFalse(scroller.replyHoldArmed)
        surface.append(GroupRoomTranscript.respondingID, height: 78)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 4028)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    /// The next member's message stops at its own start.
    func testALaterMemberMessageStopsAtItsOwnStart() {
        let (scroller, surface) = makeRoomScroller()
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<11), replyStart: "e10")
        surface.append("e10", height: 200)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3400)
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<12), replyStart: "e11")
        surface.append("e11", height: 1600)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 4163)
        XCTAssertEqual(scroller.mode, .browsing)
    }

    /// A reader scrolled up stays where they are; back at the end, they
    /// follow it.
    func testABrowsingReaderIsNotMovedByANewMemberMessage() {
        let (scroller, surface) = makeRoomScroller()
        surface.userScroll(to: 1000)
        XCTAssertEqual(scroller.mode, .browsing)
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<11), replyStart: "e10")
        XCTAssertFalse(scroller.replyHoldArmed)
        surface.append("e10", height: 1600)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 1000)
        surface.userScroll(to: 4800)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    /// The jump button and a send go past the stop to the end, and the
    /// user's own message is followed.
    func testTheJumpAndASendGoPastARoomsStop() {
        let (scroller, surface) = makeRoomScroller()
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<11), replyStart: "e10")
        surface.append("e10", height: 1600)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 3963)
        scroller.explicitLatestRequested(animated: false)
        XCTAssertEqual(surface.contentOffsetY, 4800)
        XCTAssertTrue(scroller.isFollowingLatest)
        XCTAssertFalse(scroller.replyHoldArmed)
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<12), replyStart: nil)
        surface.append("e11", height: 100)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 4900)
    }

    func testWithTheSettingOffARoomFollowsAMemberMessageToItsEnd() {
        let (scroller, surface) = makeRoomScroller()
        scroller.holdsRepliesAtStart = { false }
        scroller.roomTranscriptChanged(eventIDs: Self.eventIDs(0..<11), replyStart: "e10")
        XCTAssertFalse(scroller.replyHoldArmed)
        surface.append("e10", height: 1600)
        surface.layOut()
        XCTAssertEqual(surface.contentOffsetY, 4800)
        XCTAssertTrue(scroller.isFollowingLatest)
    }

    /// A "Replying to" card's tap: the message it quoted at the top, the
    /// room browsing there. Only the room's events are taken to.
    func testARoomTakesTheReaderToAQuotedMessage() {
        let (scroller, surface) = makeRoomScroller()
        scroller.explicitMessageRequested(id: "e3")
        XCTAssertEqual(surface.contentOffsetY, 1200)
        XCTAssertEqual(scroller.mode, .browsing)
        surface.append(GroupRoomTranscript.respondingID, height: 78)
        surface.layOut()
        scroller.explicitMessageRequested(id: GroupRoomTranscript.respondingID)
        XCTAssertEqual(surface.contentOffsetY, 1200)
    }
}
