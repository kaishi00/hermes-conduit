import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Runs the real ChatView in a window and checks the transcript's collection
/// view itself (#1533, the transcript rewrite): where the content actually
/// sits after SwiftUI, the rows' hosting controllers and UIKit have laid it
/// out.
@MainActor
final class ChatScrollHostedTests: XCTestCase {
    private var window: UIWindow?
    private var host: UIViewController?
    private var appState: AppState?
    private var savedReplyStartPreference: Any?

    override func setUp() {
        super.setUp()
        // These tests follow a reply to its end. Stopping at the start of a
        // long reply (#1256, on by default) has its own test below and in
        // TranscriptScrollerTests.
        savedReplyStartPreference = UserDefaults.standard.object(forKey: ChatReplyStartPreference.key)
        UserDefaults.standard.set(false, forKey: ChatReplyStartPreference.key)
    }

    override func tearDown() {
        // Stop streaming, remove the hosted view synchronously and drain
        // until SwiftUI has torn it down, so no deferred work from this
        // suite lands in the next one (the reason the deleted follow
        // correction suite tore down the same way).
        appState?.setStreamingTextForTesting("")
        if let window {
            window.isHidden = true
            window.rootViewController = nil
            host?.view.removeFromSuperview()
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                if let host, host.view.subviews.isEmpty { break }
            }
        }
        window = nil
        host = nil
        appState = nil
        if let savedReplyStartPreference {
            UserDefaults.standard.set(savedReplyStartPreference, forKey: ChatReplyStartPreference.key)
        } else {
            UserDefaults.standard.removeObject(forKey: ChatReplyStartPreference.key)
        }
        super.tearDown()
    }

    private struct Mounted {
        let appState: AppState
        let host: UIViewController
        let scrollView: UIScrollView
        let layout: TranscriptLayout
        let scroller: TranscriptScroller
        /// Draws the same chat at another text size.
        let setTextSize: (ChatTextSize) -> Void
    }

    private static func transcript(_ range: Range<Int>) -> [ChatMessage] {
        range.map { index in
            ChatMessage(
                id: "hosted-\(index)",
                role: index % 2 == 0 ? .user : .assistant,
                content: index % 3 == 0
                    ? "Short message \(index)."
                    : String(repeating: "Message \(index) has a few lines of ordinary prose. ", count: 4 + index % 5),
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    private func mount(_ messages: [ChatMessage], composerRests: Bool = false) throws -> Mounted {
        let suiteName = "chat-scroll-hosted"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.messages = messages

        let host = UIHostingController(
            rootView: Self.chat(appState, composerRests: composerRests, textSize: DormancyHarnessEnvironment.pinnedChatTextSize)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        self.host = host
        self.appState = appState

        var collectionView: TranscriptCollectionView?
        XCTAssertTrue(
            PerformanceFixtureWait.eventually(pumpingLayoutOf: host.view) {
                collectionView = Self.find(TranscriptCollectionView.self, in: host.view)
                return collectionView?.window != nil && (collectionView?.bounds.height ?? 0) > 0
            },
            "the chat must draw its transcript's collection view"
        )
        let found = try XCTUnwrap(collectionView)
        let controller = try XCTUnwrap(found.delegate as? TranscriptViewController)
        settle(host.view)
        return Mounted(
            appState: appState, host: host, scrollView: found, layout: controller.layout, scroller: controller.scroller,
            setTextSize: { size in host.rootView = ChatScrollHostedTests.chat(appState, composerRests: composerRests, textSize: size) }
        )
    }

    private static func chat(_ appState: AppState, composerRests: Bool, textSize: ChatTextSize) -> some View {
        DormancyHarnessEnvironment.applying(
            ChatView(chatTextSizeOverride: textSize)
                .environment(\.v2ComposerRests, composerRests)
                .environmentObject(appState)
        )
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// Pumps layout and the run loop long enough for rows to measure.
    private func settle(_ view: UIView, seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func maxOffset(_ scrollView: UIScrollView) -> CGFloat {
        max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        )
    }

    private func assertAtLatest(
        _ mounted: Mounted,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let distance = maxOffset(mounted.scrollView) - mounted.scrollView.contentOffset.y
        XCTAssertLessThanOrEqual(abs(distance), 1, "\(message) (distance \(distance))", file: file, line: line)
    }

    /// What a finger would do: begin a drag, move the content, let go.
    private func browse(_ mounted: Mounted, to offsetY: CGFloat) {
        mounted.scroller.userDragBegan()
        mounted.scrollView.contentOffset.y = offsetY
        mounted.scroller.userDragEnded()
        settle(mounted.host.view, seconds: 0.3)
    }

    /// Screen position (relative to the viewport top) of a row.
    private func screenY(of id: String, in mounted: Mounted) -> CGFloat? {
        mounted.layout.rowFrame(id).map { $0.minY - mounted.scrollView.contentOffset.y }
    }

    /// Records every offset and content-size change the scroll view goes
    /// through, and whether the scroller made the offset change, so a
    /// failure says which side moved the transcript.
    private final class ScrollRecorder {
        struct Change {
            let time: CFTimeInterval
            let text: String
            let isOffset: Bool
            let byScroller: Bool
            var distance: CGFloat = 0
        }

        private(set) var changes: [Change] = []
        private var observations: [NSKeyValueObservation] = []
        private let start = CACurrentMediaTime()

        init(_ scrollView: UIScrollView) {
            observations = [
                scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] view, change in
                    guard let self, change.oldValue != change.newValue else { return }
                    let stack = Thread.callStackSymbols
                    let byScroller = stack.contains { $0.contains("TranscriptScroller") }
                    let writer = byScroller ? "scroller" : Self.writer(in: stack)
                    // Clamped like TranscriptScrollSurface.maxOffsetY.
                    let max = Swift.max(
                        -view.adjustedContentInset.top,
                        view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height
                    )
                    self.record(
                        String(
                            format: "offset %.1f -> %.1f (max %.1f) by %@",
                            change.oldValue?.y ?? .nan, change.newValue?.y ?? .nan, max, writer
                        ),
                        isOffset: true,
                        byScroller: byScroller,
                        distance: abs((change.newValue?.y ?? 0) - (change.oldValue?.y ?? 0))
                    )
                },
                scrollView.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                    guard let self, change.oldValue != change.newValue else { return }
                    self.record(
                        String(
                            format: "bounds y %.1f h %.1f -> y %.1f h %.1f",
                            change.oldValue?.origin.y ?? .nan, change.oldValue?.height ?? .nan,
                            change.newValue?.origin.y ?? .nan, change.newValue?.height ?? .nan
                        ),
                        isOffset: false,
                        byScroller: false
                    )
                },
                scrollView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                    guard let self, change.oldValue != change.newValue else { return }
                    self.record(
                        String(
                            format: "contentSize %.1f -> %.1f",
                            change.oldValue?.height ?? .nan, change.newValue?.height ?? .nan
                        ),
                        isOffset: false,
                        byScroller: false
                    )
                },
            ]
        }

        private static func writer(in stack: [String]) -> String {
            // The first frame below the KVO machinery that is not UIKit's own
            // setter names who moved the scroll view.
            let frames = stack.dropFirst(1).filter {
                !$0.contains("NSKeyValue") && !$0.contains("Foundation")
                    && !$0.contains("ScrollRecorder") && !$0.contains("setContentOffset")
                    && !$0.contains("setBounds")
            }
            return frames.prefix(4)
                .map { frame -> String in
                    let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count > 3 else { return frame }
                    return "\(parts[1]):\(parts[3])"
                }
                .joined(separator: " < ")
        }

        private func record(_ text: String, isOffset: Bool, byScroller: Bool, distance: CGFloat = 0) {
            changes.append(Change(
                time: CACurrentMediaTime() - start,
                text: text,
                isOffset: isOffset,
                byScroller: byScroller,
                distance: distance
            ))
        }

        func mark() -> Int { changes.count }

        func offsetChanges(since mark: Int) -> [Change] {
            changes[mark...].filter(\.isOffset)
        }

        func dump(since mark: Int = 0) -> String {
            changes[mark...].map { String(format: "%7.3f %@", $0.time, $0.text) }.joined(separator: "\n")
        }

        deinit {
            observations.forEach { $0.invalidate() }
        }
    }

    /// Geometry read straight from the scroll view (no KVO), with the
    /// scroller's view of it, for the CI log.
    private func checkpoint(_ label: String, _ mounted: Mounted, _ recorder: ScrollRecorder) {
        let view = mounted.scrollView
        print(String(
            format: "[ChatScrollHostedTests] %@: offset %.1f max %.1f content %.1f bounds %.1f insets %.1f/%.1f mode %@ layoutCallbacks %ld recorded %ld",
            label,
            view.contentOffset.y,
            maxOffset(view),
            view.contentSize.height,
            view.bounds.height,
            view.adjustedContentInset.top,
            view.adjustedContentInset.bottom,
            String(describing: mounted.scroller.mode),
            TranscriptPerf.layoutMetricsChangedCalls,
            recorder.mark()
        ))
    }

    /// Rows whose real heights are far from the layout's estimates: long
    /// code blocks and lists between ordinary prose.
    private static func uneven(_ range: Range<Int>) -> [ChatMessage] {
        range.map { index in
            let content: String
            switch index % 7 {
            case 2:
                content = "```swift\n" + (0..<(30 + index % 20)).map { "let value\($0) = compute(\($0))" }
                    .joined(separator: "\n") + "\n```"
            case 5:
                content = (0..<(12 + index % 9)).map { "- Item \($0) of a long list in message \(index)" }
                    .joined(separator: "\n")
            default:
                content = String(repeating: "Message \(index) is ordinary prose. ", count: 2 + index % 6)
            }
            return ChatMessage(
                id: "uneven-\(index)",
                role: index % 2 == 0 ? .user : .assistant,
                content: content,
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    // MARK: - Tests

    func testOpensOnTheLatestMessage() throws {
        let mounted = try mount(Self.transcript(0..<120))
        XCTAssertGreaterThan(mounted.scrollView.contentSize.height, mounted.scrollView.bounds.height * 3)
        assertAtLatest(mounted, "a long chat opens on its latest message")
        XCTAssertTrue(mounted.scroller.isFollowingLatest)
    }

    func testNewMessagesAndStreamingStayOnTheLatestMessage() throws {
        let mounted = try mount(Self.transcript(0..<120))

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<122))
        settle(mounted.host.view)
        assertAtLatest(mounted, "an appended reply is followed")

        for tick in 1...8 {
            mounted.appState.setStreamingTextForTesting(String(
                repeating: "Streaming line \(tick) grows the live bubble. ",
                count: tick * 3
            ))
            settle(mounted.host.view, seconds: 0.1)
            assertAtLatest(mounted, "streaming growth tick \(tick) is followed")
        }
    }

    func testARunningReplyOpenedAgainShowsWhatWasWrittenAtOnce() throws {
        // Opening a chat whose reply is still running seeds the live bubble
        // with everything written so far. It must not be typed out again:
        // only its newest characters fade in.
        let mounted = try mount(Self.transcript(0..<40))
        let transcriptOnly = mounted.scrollView.contentSize.height
        mounted.appState.setStreamingTextForTesting(String(
            repeating: "Everything the reply wrote before the chat was opened again. ",
            count: 50
        ))
        // The first sample is taken once the bubble is laid out well past a
        // first line (the reply is about 70 lines), however long a busy
        // simulator takes to get there. Typed out, it would only be a few
        // hundred points in and keep growing.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            settle(mounted.host.view, seconds: 0.05)
        } while mounted.scrollView.contentSize.height <= transcriptOnly + 600 && Date() < deadline
        settle(mounted.host.view, seconds: 0.1)
        let shownAtOnce = mounted.scrollView.contentSize.height
        settle(mounted.host.view, seconds: 1.0)
        let shownLater = mounted.scrollView.contentSize.height
        XCTAssertLessThan(
            shownLater - shownAtOnce,
            80,
            "the written reply showed at once (\(shownAtOnce) then \(shownLater) pt)"
        )
        assertAtLatest(mounted, "the reopened reply is followed")
    }

    func testAReaderScrolledUpIsNotMovedByNewMessages() throws {
        let mounted = try mount(Self.transcript(0..<120))
        browse(mounted, to: mounted.scrollView.contentOffset.y - 1500)
        XCTAssertEqual(mounted.scroller.mode, .browsing)
        let topRow = try XCTUnwrap(mounted.scroller.topVisibleMessageID)
        let before = try XCTUnwrap(screenY(of: topRow, in: mounted))

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<124))
        mounted.appState.setStreamingTextForTesting(String(repeating: "More streamed text. ", count: 40))
        settle(mounted.host.view)

        let after = try XCTUnwrap(screenY(of: topRow, in: mounted))
        XCTAssertEqual(after, before, accuracy: 1, "the row being read stays where it was")
        XCTAssertEqual(mounted.scroller.mode, .browsing)
    }

    func testLoadingEarlierMessagesKeepsTheReaderInPlace() throws {
        try loadEarlierMessages(stall: .none)
    }

    /// A busy main thread between the transcript landing and the layout
    /// that shows the prepended page.
    func testLoadingEarlierMessagesHoldsThroughAStallBeforeTheLayout() throws {
        try loadEarlierMessages(stall: .beforeLayout)
    }

    /// A busy main thread right after the scroller moves the reader past
    /// the page, before the page's rows measure.
    func testLoadingEarlierMessagesHoldsThroughAStallAfterTheLayout() throws {
        try loadEarlierMessages(stall: .afterLayout)
    }

    private enum Stall {
        case none
        case beforeLayout
        case afterLayout
    }

    private func loadEarlierMessages(
        stall: Stall,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let mounted = try mount(Self.transcript(40..<120))
        browse(mounted, to: mounted.scrollView.contentOffset.y - 1200)
        let topRow = try XCTUnwrap(mounted.scroller.topVisibleMessageID)
        let before = try XCTUnwrap(screenY(of: topRow, in: mounted))
        let recorder = ScrollRecorder(mounted.scrollView)

        var stalled = false
        var landed = false
        var stallSubscription: AnyCancellable?
        var stallObservation: NSKeyValueObservation?
        switch stall {
        case .none:
            break
        case .beforeLayout:
            // The scroller publishes its new rows as the transcript lands;
            // the collection view lays them out in a later pass.
            stallSubscription = mounted.scroller.objectWillChange.sink { _ in
                guard !stalled, landed else { return }
                stalled = true
                Thread.sleep(forTimeInterval: 1)
            }
        case .afterLayout:
            // The first jump of more than a page is the scroller moving the
            // reader down past the prepended page.
            let offsetBefore = mounted.scrollView.contentOffset.y
            let page = mounted.scrollView.bounds.height
            stallObservation = mounted.scrollView.observe(\.contentOffset, options: [.new]) { _, change in
                guard !stalled, let offset = change.newValue, offset.y > offsetBefore + page else { return }
                stalled = true
                Thread.sleep(forTimeInterval: 1)
            }
        }
        ChatViewportTrace.shared.reset()
        landed = true
        mounted.appState.messages = Self.transcript(0..<120)
        // The stall takes a second out of the settle; the rest still gets
        // the usual layout passes.
        settle(mounted.host.view, seconds: stall == .none ? 0.6 : 1.6)
        stallSubscription?.cancel()
        stallObservation?.invalidate()

        let trace = { "offsets:\n\(recorder.dump())\nscroller:\n\(ChatViewportTrace.shared.dump())" }
        XCTAssertEqual(
            stalled, stall != .none, "the main thread stalled where the test meant it to",
            file: file, line: line
        )
        let after = try XCTUnwrap(
            screenY(of: topRow, in: mounted),
            "the reader's row \(topRow) has no frame after the prepend\n\(trace())",
            file: file, line: line
        )
        XCTAssertEqual(
            after, before, accuracy: 2, "the prepend lands above without moving the reader\n\(trace())",
            file: file, line: line
        )
    }

    func testScrollingDoesNotReevaluateTheChat() throws {
        let mounted = try mount(Self.transcript(0..<120))
        let start = mounted.scrollView.contentOffset.y
        let bodiesBefore = TranscriptPerf.chatViewBodyEvaluations

        mounted.scroller.userDragBegan()
        for step in 1...20 {
            mounted.scrollView.contentOffset.y = start - CGFloat(step) * 90
            settle(mounted.host.view, seconds: 0.03)
        }
        mounted.scroller.userDragEnded()
        settle(mounted.host.view, seconds: 0.3)
        XCTAssertTrue(mounted.scroller.chrome.inputs.showsJumpToLatest)

        // Back down to the latest message, which follows again.
        mounted.scroller.userDragBegan()
        for step in (0..<20).reversed() {
            mounted.scrollView.contentOffset.y = step == 0
                ? maxOffset(mounted.scrollView)
                : start - CGFloat(step) * 90
            settle(mounted.host.view, seconds: 0.03)
        }
        mounted.scroller.userDragEnded()
        settle(mounted.host.view, seconds: 0.3)
        XCTAssertTrue(mounted.scroller.chrome.inputs.isFollowingLatest)
        XCTAssertFalse(mounted.scroller.chrome.inputs.showsJumpToLatest)

        // Leaving and returning to the latest message, and the jump button
        // coming and going, re-render only the button: a chat re-render
        // re-ran every row, a hitch at the start of each scroll.
        XCTAssertEqual(TranscriptPerf.chatViewBodyEvaluations - bodiesBefore, 0)
    }

    func testJumpToLatestReturnsToTheBottomAndFollowsAgain() throws {
        let mounted = try mount(Self.transcript(0..<120))
        // Within three viewports, so the jump animates and gets its final pin.
        browse(mounted, to: maxOffset(mounted.scrollView) - mounted.scrollView.bounds.height * 2)
        XCTAssertEqual(mounted.scroller.mode, .browsing)
        mounted.scroller.explicitLatestRequested(animated: true)
        XCTAssertTrue(mounted.scroller.latestAnimationInFlight, "a short jump animates")
        // The scroller pins once more when the animation has landed.
        settle(mounted.host.view, seconds: TranscriptScroller.latestAnimationDuration + 0.4)
        assertAtLatest(mounted, "the jump lands on the latest message")

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<121))
        settle(mounted.host.view)
        assertAtLatest(mounted, "and following resumes")
    }

    /// Eric's report: send, leave the screen alone, and when the turn
    /// completes the transcript sits past its end. Completion removes the
    /// turn's partial rows and live rows and appends one settled reply, so
    /// the content shrinks under a pinned offset.
    func testTurnCompletionThatShrinksTheContentStaysOnTheLatestMessage() throws {
        let mounted = try mount(Self.uneven(0..<60))
        let recorder = ScrollRecorder(mounted.scrollView)
        let appState = mounted.appState

        appState.messages.append(ChatMessage(id: "turn-user", role: .user, content: "Do the thing.", timestamp: "2026-01-01T00:00:00Z"))
        settle(mounted.host.view, seconds: 0.2)
        for step in 0..<4 {
            appState.messages.append(ChatMessage(
                id: "turn-reasoning-\(step)",
                role: .reasoning,
                content: String(repeating: "Thinking about step \(step). ", count: 30),
                timestamp: "2026-01-01T00:00:00Z"
            ))
            appState.messages.append(ChatMessage(
                id: "turn-partial-\(step)",
                role: .partial,
                content: String(repeating: "Working on step \(step) of the task with plenty of detail. ", count: 12),
                timestamp: "2026-01-01T00:00:00Z"
            ))
            settle(mounted.host.view, seconds: 0.15)
        }
        appState.setStreamingTextForTesting(String(repeating: "The final answer streams in with several lines. ", count: 30))
        settle(mounted.host.view, seconds: 0.3)
        checkpoint("completion before", mounted, recorder)
        assertAtLatest(mounted, "the live turn is followed")

        let mark = recorder.mark()
        // finalizeStreamingCompletion: partials out, one settled reply in,
        // live text cleared, all in one update.
        appState.messages.removeAll { $0.role == .partial }
        appState.messages.append(ChatMessage(
            id: "turn-final",
            role: .assistant,
            content: "Done.",
            timestamp: "2026-01-01T00:00:00Z"
        ))
        appState.setStreamingTextForTesting("")
        checkpoint("completion published", mounted, recorder)
        settle(mounted.host.view, seconds: 0.6)
        checkpoint("completion after", mounted, recorder)
        print("[ChatScrollHostedTests] completion trace:\n\(recorder.dump(since: mark))")
        assertAtLatest(mounted, "a completed turn leaves no empty space under it\n\(recorder.dump(since: mark))")
        XCTAssertTrue(mounted.scroller.isFollowingLatest)
    }

    /// #1436: with Long replies on, the user's message moves to the top of
    /// the viewport once it is sent, and its reply streams into the room
    /// under it: nothing moves while it grows, nor once it outgrows the
    /// screen, where the reader is left browsing, nor when the turn
    /// completes. Each appended step row first lays out at an estimate
    /// taller than its measured height, so the content can shrink under the
    /// stop while the reply still fits (#1256, #1313).
    func testAReplyStreamsUnderTheUsersMessageAtTheTopWithoutMoving() throws {
        UserDefaults.standard.set(true, forKey: ChatReplyStartPreference.key)
        let mounted = try mount(Self.uneven(0..<60))
        let recorder = ScrollRecorder(mounted.scrollView)
        let appState = mounted.appState

        appState.messages.append(ChatMessage(id: "turn-user", role: .user, content: "Do the thing.", timestamp: "2026-01-01T00:00:00Z"))
        // The room is laid out and the message moves up, animated.
        settle(mounted.host.view, seconds: 0.8)
        checkpoint("landed", mounted, recorder)
        let rowTop = try XCTUnwrap(screenY(of: "turn-user", in: mounted), "the user's message is laid out")
        XCTAssertEqual(
            rowTop,
            mounted.scrollView.adjustedContentInset.top + TranscriptScroller.replyStartTopGap,
            accuracy: 2,
            "the sent message sits at the top\n\(recorder.dump())"
        )
        assertAtLatest(mounted, "the room makes the stop the bottom")
        XCTAssertTrue(mounted.scroller.isFollowingLatest)

        let landed = mounted.scrollView.contentOffset.y
        let mark = recorder.mark()
        for step in 0..<4 {
            appState.messages.append(ChatMessage(
                id: "turn-partial-\(step)",
                role: .partial,
                content: String(repeating: "Working on step \(step) of the task with plenty of detail. ", count: 12),
                timestamp: "2026-01-01T00:00:00Z"
            ))
            settle(mounted.host.view, seconds: 0.15)
            XCTAssertEqual(
                mounted.scrollView.contentOffset.y,
                landed,
                accuracy: 1,
                "step \(step) streams in without moving the reader\n\(recorder.dump(since: mark))"
            )
        }
        let answer = String(repeating: "The final answer streams in with several lines. ", count: 30)
        appState.setStreamingTextForTesting(answer)
        settle(mounted.host.view, seconds: 0.3)
        checkpoint("hold", mounted, recorder)

        XCTAssertEqual(mounted.scrollView.contentOffset.y, landed, accuracy: 1, "the answer doesn't move the reader\n\(recorder.dump(since: mark))")
        XCTAssertEqual(mounted.scroller.mode, .browsing, "the reader is left browsing at the stop")
        XCTAssertGreaterThan(maxOffset(mounted.scrollView) - mounted.scrollView.contentOffset.y, 40, "the reply runs on below")

        let completionMark = recorder.mark()
        appState.messages.removeAll { $0.role == .partial }
        appState.messages.append(ChatMessage(id: "turn-final", role: .assistant, content: answer, timestamp: "2026-01-01T00:00:00Z"))
        appState.setStreamingTextForTesting("")
        settle(mounted.host.view, seconds: 0.6)
        checkpoint("hold after completion", mounted, recorder)
        XCTAssertEqual(mounted.scrollView.contentOffset.y, landed, accuracy: 1, "completion leaves the reader at the stop\n\(recorder.dump(since: completionMark))")
        XCTAssertEqual(mounted.scroller.mode, .browsing)
    }

    /// A short reply ends well above the composer, in the room under the
    /// message, and the turn completing doesn't move it either.
    func testAShortReplyStaysInTheRoomUnderTheUsersMessage() throws {
        UserDefaults.standard.set(true, forKey: ChatReplyStartPreference.key)
        let mounted = try mount(Self.uneven(0..<60))
        let recorder = ScrollRecorder(mounted.scrollView)
        let appState = mounted.appState

        appState.messages.append(ChatMessage(id: "turn-user", role: .user, content: "Say hi.", timestamp: "2026-01-01T00:00:00Z"))
        settle(mounted.host.view, seconds: 0.8)
        let landed = mounted.scrollView.contentOffset.y
        let mark = recorder.mark()
        appState.setStreamingTextForTesting("Hi there.")
        settle(mounted.host.view, seconds: 0.3)
        appState.messages.append(ChatMessage(id: "turn-final", role: .assistant, content: "Hi there.", timestamp: "2026-01-01T00:00:00Z"))
        appState.setStreamingTextForTesting("")
        settle(mounted.host.view, seconds: 0.6)
        checkpoint("short reply done", mounted, recorder)
        XCTAssertEqual(mounted.scrollView.contentOffset.y, landed, accuracy: 1, "nothing moved\n\(recorder.dump(since: mark))")
        XCTAssertTrue(mounted.scroller.isFollowingLatest)
        assertAtLatest(mounted, "the room is still there, so no empty space past the bottom")
    }

    /// A finished run of steps shows as one collapsed line. Its other
    /// steps draw nothing, so they must not add the transcript's row
    /// spacing each: the reply sits one spacing below the line, not seven.
    func testACollapsedRunOfStepsSitsOneRowSpacingAboveTheReply() throws {
        let steps = (0..<7).map { index in
            ChatMessage(
                id: "step-\(index)",
                role: .tool,
                content: "",
                timestamp: "2026-01-01T00:00:0\(index)Z",
                tool: ToolActivity(id: "step-\(index)", name: "web_search", input: #"{"query": "q\#(index)"}"#, output: "ok", status: .complete)
            )
        }
        let messages = [ChatMessage(id: "ask", role: .user, content: "Look it up.", timestamp: "2026-01-01T00:00:00Z")]
            + steps
            + [ChatMessage(id: "reply", role: .assistant, content: "Here it is.", timestamp: "2026-01-01T00:00:09Z")]
        let mounted = try mount(messages)
        settle(mounted.host.view, seconds: 0.4)

        let header = try XCTUnwrap(mounted.layout.rowFrame("step-0"), "the run's line is laid out")
        let reply = try XCTUnwrap(mounted.layout.rowFrame("reply"), "the reply is laid out")
        XCTAssertGreaterThan(header.maxY - header.minY, 1, "the run shows as one line")
        XCTAssertEqual(
            reply.minY - header.maxY,
            ChatStepStyle.transcriptRowSpacing,
            accuracy: 1,
            "one row spacing between the collapsed run and the reply"
        )
    }

    /// Eric's report: opening a Thinking or tool row at the bottom of the
    /// chat jumped far down. A row growing in place (as an opening one does)
    /// after the reader taps it keeps its top where it was.
    func testOpeningARowAtTheBottomKeepsItsTopStill() throws {
        let mounted = try mount(Self.uneven(0..<60))
        let recorder = ScrollRecorder(mounted.scrollView)
        assertAtLatest(mounted, "opens on the latest message")
        let lastID = "uneven-59"
        let before = try XCTUnwrap(screenY(of: lastID, in: mounted))

        let mark = recorder.mark()
        mounted.scroller.userWillToggleRow()
        mounted.appState.messages[59] = ChatMessage(
            id: lastID,
            role: .assistant,
            content: String(repeating: "What the opened row reveals, line after line. ", count: 120),
            timestamp: "2026-01-01T00:00:00Z"
        )
        // Past the settle check, which must leave a reader this far from
        // the bottom where they are.
        settle(mounted.host.view, seconds: TranscriptScroller.disclosureSettleDelay + 0.4)
        checkpoint("opened", mounted, recorder)

        let after = try XCTUnwrap(screenY(of: lastID, in: mounted))
        XCTAssertEqual(after, before, accuracy: 1, "the tapped row stays put\n\(recorder.dump(since: mark))")
        XCTAssertEqual(mounted.scroller.mode, .browsing)
        XCTAssertTrue(mounted.scroller.showsJumpToLatest)
    }

    /// A tester's report: at the bottom of a chat, a band of empty space
    /// (~126 pt) sat between the last reply and the composer. The composer
    /// is a bar the transcript insets for, so the latest row ends one row
    /// spacing (and the stack's old 1 pt) above it, with the resting V2
    /// composer and the stacked one alike.
    func testTheLatestReplyEndsJustAboveTheRestingComposer() throws {
        try assertLatestReplyEndsJustAboveTheComposer(composerRests: true)
    }

    func testTheLatestReplyEndsJustAboveTheStackedComposer() throws {
        try assertLatestReplyEndsJustAboveTheComposer(composerRests: false)
    }

    private func assertLatestReplyEndsJustAboveTheComposer(composerRests: Bool) throws {
        let count = 40
        let mounted = try mount(Self.transcript(0..<count), composerRests: composerRests)
        // Scrolled to the very bottom, whoever placed the offset: this
        // measures the layout under the latest row, not the follow logic.
        let view = mounted.scrollView
        for _ in 0..<3 {
            view.contentOffset.y = maxOffset(view)
            settle(mounted.host.view, seconds: 0.3)
        }
        XCTAssertEqual(view.contentOffset.y, maxOffset(view), accuracy: 1, "still at the very bottom when measured")

        let last = try XCTUnwrap(mounted.layout.rowFrame("hosted-\(count - 1)"), "the latest row is laid out")
        let rowBottom = last.maxY - view.contentOffset.y
        let composerTop = view.bounds.height - view.adjustedContentInset.bottom
        if composerRests {
            XCTAssertGreaterThan(view.adjustedContentInset.bottom, 40, "the transcript insets for the resting composer")
        } else {
            XCTAssertLessThanOrEqual(view.adjustedContentInset.bottom, 1, "the stacked composer sits below the transcript")
        }
        XCTAssertLessThan(composerTop - rowBottom, 30, "no band of empty space above the composer")
        XCTAssertEqual(
            composerTop - rowBottom,
            ChatStepStyle.transcriptRowSpacing,
            accuracy: 2,
            "one row spacing between the latest reply and the composer"
        )
    }

    /// Issue #302: the transcript bounced on its own until touched. With no
    /// input and nothing new arriving, the offset must not move at all.
    func testAnIdleTranscriptHoldsStill() throws {
        let mounted = try mount(Self.uneven(0..<90))
        let recorder = ScrollRecorder(mounted.scrollView)
        mounted.appState.messages.append(contentsOf: Self.uneven(90..<93))
        mounted.appState.setStreamingTextForTesting(String(repeating: "Streaming with ```code``` and *emphasis*. ", count: 20))
        settle(mounted.host.view)
        mounted.appState.setStreamingTextForTesting("")
        mounted.appState.messages.append(contentsOf: Self.uneven(93..<94))
        settle(mounted.host.view)
        assertAtLatest(mounted, "following after the burst\n\(recorder.dump())")

        checkpoint("idle before", mounted, recorder)
        let mark = recorder.mark()
        // Layout passes keep running, as frames do on a device; nothing new
        // arrives and nothing touches the screen.
        settle(mounted.host.view, seconds: 1.5)
        checkpoint("idle after", mounted, recorder)
        // A sub-point settle is not a bounce; #302 moved 100-250 pt.
        let moves = recorder.offsetChanges(since: mark).filter { $0.distance > 1 }
        print("[ChatScrollHostedTests] idle trace:\n\(recorder.dump())")
        XCTAssertTrue(moves.isEmpty, "the transcript moved on its own:\n\(recorder.dump(since: mark))")
    }

    /// A row draws in a hosting controller of its own and inherits nothing
    /// from the chat: a change to the chat's text size reaches the rows
    /// already drawn (TranscriptView's update, TranscriptCell's
    /// updateEnvironment), so they draw, and measure, at the new size.
    func testAChangeToTheChatsTextSizeReachesTheRowsDrawn() throws {
        let messages = Self.transcript(0..<12)
        let mounted = try mount(messages)
        let id = try XCTUnwrap(messages.last?.id)
        let before = try XCTUnwrap(mounted.layout.rowFrame(id))

        mounted.setTextSize(.largest)
        settle(mounted.host.view)

        let after = try XCTUnwrap(mounted.layout.rowFrame(id))
        XCTAssertGreaterThan(
            after.maxY - after.minY,
            before.maxY - before.minY + 4,
            "the latest row, drawn before the change, must draw at the larger text"
        )
    }

    /// A row's sheet presents from the row's own hosting controller, so a
    /// cell given to another row while one is up keeps that controller
    /// aside, still in the transcript and the window, until it closes.
    func testACellGivenToAnotherRowWhileASheetIsUpKeepsTheRowUntilItCloses() throws {
        let mounted = try mount(Self.transcript(0..<120))
        let collectionView = try XCTUnwrap(mounted.scrollView as? UICollectionView)
        let controller = try XCTUnwrap(collectionView.delegate as? TranscriptViewController)
        // Every row's controller so far, the cells waiting for reuse included.
        let rows = controller.children.compactMap { $0 as? UIHostingController<TranscriptCellRoot> }
        let presenting = try XCTUnwrap(
            collectionView.visibleCells.compactMap { ($0 as? TranscriptCell)?.hosting }.first,
            "a row is on screen"
        )
        let sheet = UIViewController()
        presenting.present(sheet, animated: false)
        XCTAssertTrue(
            PerformanceFixtureWait.eventually { sheet.view.window != nil && controller.presentedViewController === sheet },
            "the row presents its sheet"
        )

        // The cells are given to the first rows.
        browse(mounted, to: -collectionView.adjustedContentInset.top)
        let parked = rows.filter { $0.view.superview?.superview as? TranscriptCell == nil }
        XCTAssertFalse(parked.isEmpty, "cells were given to other rows while the sheet was up")
        for hosting in parked {
            XCTAssertTrue(hosting.parent === controller, "a row's controller stays in the transcript while the sheet is up")
            XCTAssertNotNil(hosting.view.window, "and in the window")
        }
        for case let cell as TranscriptCell in collectionView.visibleCells {
            XCTAssertTrue(cell.hosting?.parent === controller, "the rows given the cells draw in controllers of their own")
        }
        XCTAssertTrue(presenting.parent === controller)
        XCTAssertNotNil(sheet.view.window, "the sheet stays up")

        sheet.dismiss(animated: false)
        XCTAssertTrue(
            PerformanceFixtureWait.eventually(pumpingLayoutOf: collectionView) { parked.allSatisfy { $0.parent == nil } },
            "the controllers kept aside go once the sheet closes"
        )
        XCTAssertTrue(parked.allSatisfy { $0.view.superview == nil })
    }
}
