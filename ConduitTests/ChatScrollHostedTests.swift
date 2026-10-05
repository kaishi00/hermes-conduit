import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Runs the real ChatView in a window and checks the scroll view itself:
/// where the content actually sits after SwiftUI and UIKit have laid it out.
@MainActor
final class ChatScrollHostedTests: XCTestCase {
    private var window: UIWindow?
    private var host: UIViewController?
    private var appState: AppState?

    override func tearDown() {
        // Stop streaming, remove the hosted view synchronously and drain
        // until SwiftUI has torn it down, so no deferred work from this
        // suite lands in the next one (the reason the deleted follow
        // correction suite tore down the same way).
        appState?.streamingText = ""
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
        super.tearDown()
    }

    private struct Mounted {
        let appState: AppState
        let host: UIViewController
        let scrollView: UIScrollView
        let engine: ChatScrollEngine
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

    private func mount(_ messages: [ChatMessage]) throws -> Mounted {
        let suiteName = "chat-scroll-hosted"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.messages = messages

        let host = UIHostingController(
            rootView: DormancyHarnessEnvironment.applying(
                ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize)
                    .environmentObject(appState)
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        self.host = host
        self.appState = appState

        var locator: ChatScrollSurfaceLocatorView?
        XCTAssertTrue(
            PerformanceFixtureWait.eventually(pumpingLayoutOf: host.view) {
                locator = Self.find(ChatScrollSurfaceLocatorView.self, in: host.view)
                return locator?.surface?.scrollView != nil
            },
            "the locator must find the transcript's UIScrollView"
        )
        let found = try XCTUnwrap(locator)
        let scrollView = try XCTUnwrap(found.surface?.scrollView)
        let engine = try XCTUnwrap(found.engine)
        settle(host.view)
        return Mounted(appState: appState, host: host, scrollView: scrollView, engine: engine)
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// Pumps layout and the run loop long enough for lazy rows to measure.
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
        mounted.engine.userDragBegan()
        mounted.scrollView.contentOffset.y = offsetY
        mounted.engine.userDragEnded()
        settle(mounted.host.view, seconds: 0.3)
    }

    /// Screen position (relative to the viewport top) of a laid-out row.
    private func screenY(of id: String, in mounted: Mounted) -> CGFloat? {
        guard let frame = mounted.engine.rowFrame(for: id),
              let surface = mounted.engine.surface else { return nil }
        return surface.transcriptOriginY + frame.minY - mounted.scrollView.contentOffset.y
    }

    /// Records every offset and content-size change the scroll view goes
    /// through, and whether the engine made the offset change, so a failure
    /// says which side moved the transcript.
    private final class ScrollRecorder {
        struct Change {
            let time: CFTimeInterval
            let text: String
            let isOffset: Bool
            let byEngine: Bool
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
                    let byEngine = stack.contains { $0.contains("ChatScrollEngine") }
                    let writer = byEngine ? "engine" : Self.writer(in: stack)
                    // Clamped like ChatScrollSurface.maxOffsetY.
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
                        byEngine: byEngine,
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
                        byEngine: false
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
                        byEngine: false
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

        private func record(_ text: String, isOffset: Bool, byEngine: Bool, distance: CGFloat = 0) {
            changes.append(Change(
                time: CACurrentMediaTime() - start,
                text: text,
                isOffset: isOffset,
                byEngine: byEngine,
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
    /// engine's view of it, for the CI log.
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
            String(describing: mounted.engine.mode),
            TranscriptPerf.layoutMetricsChangedCalls,
            recorder.mark()
        ))
    }

    /// Rows whose real heights are far from LazyVStack's estimates: long
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
        XCTAssertTrue(mounted.engine.isFollowingLatest)
    }

    func testNewMessagesAndStreamingStayOnTheLatestMessage() throws {
        let mounted = try mount(Self.transcript(0..<120))

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<122))
        settle(mounted.host.view)
        assertAtLatest(mounted, "an appended reply is followed")

        for tick in 1...8 {
            mounted.appState.streamingText = String(
                repeating: "Streaming line \(tick) grows the live bubble. ",
                count: tick * 3
            )
            settle(mounted.host.view, seconds: 0.1)
            assertAtLatest(mounted, "streaming growth tick \(tick) is followed")
        }
    }

    func testAReaderScrolledUpIsNotMovedByNewMessages() throws {
        let mounted = try mount(Self.transcript(0..<120))
        browse(mounted, to: mounted.scrollView.contentOffset.y - 1500)
        XCTAssertEqual(mounted.engine.mode, .browsing)
        let topRow = try XCTUnwrap(mounted.engine.topVisibleMessageID)
        let before = try XCTUnwrap(screenY(of: topRow, in: mounted))

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<124))
        mounted.appState.streamingText = String(repeating: "More streamed text. ", count: 40)
        settle(mounted.host.view)

        let after = try XCTUnwrap(screenY(of: topRow, in: mounted))
        XCTAssertEqual(after, before, accuracy: 1, "the row being read stays where it was")
        XCTAssertEqual(mounted.engine.mode, .browsing)
    }

    func testLoadingEarlierMessagesKeepsTheReaderInPlace() throws {
        try loadEarlierMessages(stall: .none)
    }

    /// A busy main thread between the transcript landing and the layout
    /// that shows the prepended page.
    func testLoadingEarlierMessagesHoldsThroughAStallBeforeTheLayout() throws {
        try loadEarlierMessages(stall: .beforeLayout)
    }

    /// A busy main thread right after the first layout of the prepended page.
    func testLoadingEarlierMessagesHoldsThroughAStallAfterTheLayout() throws {
        try loadEarlierMessages(stall: .afterLayout)
    }

    private enum Stall {
        case none
        case beforeLayout
        case afterLayout
    }

    private func loadEarlierMessages(stall: Stall) throws {
        let mounted = try mount(Self.transcript(40..<120))
        browse(mounted, to: mounted.scrollView.contentOffset.y - 1200)
        let modeAfterBrowse = mounted.engine.mode
        let topRow = try XCTUnwrap(mounted.engine.topVisibleMessageID)
        let before = try XCTUnwrap(screenY(of: topRow, in: mounted))
        let recorder = ScrollRecorder(mounted.scrollView)
        let all = Self.transcript(0..<120)
        let textBefore = textViewScreenYs(mounted, messages: all)
        checkpoint("prepend before", mounted, recorder)

        mounted.engine.olderPageBackfillRequested(sessionKey: mounted.engine.renderedSessionKey)
        let armed = mounted.engine.prependAnchor
        var stalled = false
        var stallSubscription: AnyCancellable?
        var stallObservation: NSKeyValueObservation?
        let heightBefore = mounted.scrollView.contentSize.height
        switch stall {
        case .none:
            break
        case .beforeLayout:
            // The engine publishes its new rows right after the transcript
            // lands; SwiftUI lays them out in a later pass.
            stallSubscription = mounted.engine.objectWillChange.sink { _ in
                guard !stalled else { return }
                stalled = true
                print(String(format: "[ChatScrollHostedTests] stall before layout at %.3f", CACurrentMediaTime()))
                Thread.sleep(forTimeInterval: 1.0)
            }
        case .afterLayout:
            stallObservation = mounted.scrollView.observe(\.contentSize, options: [.new]) { _, change in
                guard !stalled, (change.newValue?.height ?? 0) > heightBefore + 1000 else { return }
                stalled = true
                DispatchQueue.main.async {
                    print(String(format: "[ChatScrollHostedTests] stall after layout at %.3f", CACurrentMediaTime()))
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }
        ChatViewportTrace.shared.reset()
        let mark = recorder.mark()
        let start = CACurrentMediaTime()
        print(String(format: "[ChatScrollHostedTests] prepend published at %.3f", start))
        mounted.appState.messages = all
        // The stall takes a second out of the settle; the rest still gets
        // the usual 0.6 s of layout passes.
        settle(mounted.host.view, seconds: stall == .none ? 0.6 : 1.6)
        let settleSeconds = CACurrentMediaTime() - start
        stallSubscription?.cancel()
        stallObservation?.invalidate()

        checkpoint("prepend after", mounted, recorder)
        let textAfter = textViewScreenYs(mounted, messages: all)
        let shared = textBefore.keys.filter { textAfter[$0] != nil }.sorted()
        let textMoves = shared.map { "\($0) \(Int(textBefore[$0]!))->\(Int(textAfter[$0]!))" }
        let afterY = screenY(of: topRow, in: mounted)
        print(String(
            format: "[ChatScrollHostedTests] prepend summary (%@): mode after browse %@ armed %@ stalled %@ top %@ before %.1f after %@ settle %.2fs anchor now %@ frames %@ textMoves %@ engineWrites %ld otherWrites %ld",
            String(describing: stall),
            String(describing: modeAfterBrowse),
            armed == nil ? "no" : "yes",
            stalled ? "yes" : "no",
            topRow,
            before,
            afterY.map { String(format: "%.1f", $0) } ?? "nil",
            settleSeconds,
            String(describing: mounted.engine.prependAnchor),
            framedRows(mounted, messages: all),
            textMoves.joined(separator: ", "),
            recorder.offsetChanges(since: mark).filter(\.byEngine).count,
            recorder.offsetChanges(since: mark).filter { !$0.byEngine }.count
        ))
        print("[ChatScrollHostedTests] prepend trace (\(stall)):\n\(recorder.dump(since: mark))")
        print("[ChatScrollHostedTests] prepend engine trace (\(stall)):\n\(ChatViewportTrace.shared.dump())")
        guard let after = afterY else {
            // Does a later pass report the row (a stale preference), or is
            // the reader really somewhere else?
            settle(mounted.host.view, seconds: 1.0)
            checkpoint("prepend later", mounted, recorder)
            print(String(
                format: "[ChatScrollHostedTests] prepend later: after %@ frames %@ text %@",
                screenY(of: topRow, in: mounted).map { String(format: "%.1f", $0) } ?? "nil",
                framedRows(mounted, messages: all),
                textViewScreenYs(mounted, messages: all)
                    .sorted { $0.value < $1.value }
                    .map { "\($0.key) \(Int($0.value))" }
                    .joined(separator: ", ")
            ))
            XCTFail("the reader's row \(topRow) has no frame after the prepend")
            return
        }
        XCTAssertEqual(after, before, accuracy: 2, "the prepend lands above without moving the reader")
    }

    private static func findAll<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews {
            found += findAll(type, in: subview)
        }
        return found
    }

    /// Where each message's text sits on screen (viewport-relative), read
    /// from its text view rather than the engine's row frames.
    private func textViewScreenYs(_ mounted: Mounted, messages: [ChatMessage]) -> [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        for textView in Self.findAll(UITextView.self, in: mounted.scrollView) {
            let text = textView.text ?? ""
            guard !text.isEmpty,
                  let message = messages.first(where: { text.hasPrefix(String($0.content.prefix(20))) }) else { continue }
            let y = textView.convert(CGPoint.zero, to: mounted.scrollView).y - mounted.scrollView.contentOffset.y
            result[message.id] = min(result[message.id] ?? .greatestFiniteMagnitude, y)
        }
        return result
    }

    /// The range of rows the engine has frames for.
    private func framedRows(_ mounted: Mounted, messages: [ChatMessage]) -> String {
        let framed = messages.filter { mounted.engine.rowFrame(for: $0.id) != nil }.map(\.id)
        guard let first = framed.first, let last = framed.last else { return "none" }
        return "\(framed.count) \(first)...\(last)"
    }

    func testScrollingDoesNotReevaluateTheChat() throws {
        let mounted = try mount(Self.transcript(0..<120))
        let start = mounted.scrollView.contentOffset.y
        let bodiesBefore = TranscriptPerf.chatViewBodyEvaluations

        mounted.engine.userDragBegan()
        for step in 1...20 {
            mounted.scrollView.contentOffset.y = start - CGFloat(step) * 90
            settle(mounted.host.view, seconds: 0.03)
        }
        mounted.engine.userDragEnded()
        settle(mounted.host.view, seconds: 0.3)

        // The jump-to-latest button appearing is the one expected re-run.
        XCTAssertLessThanOrEqual(TranscriptPerf.chatViewBodyEvaluations - bodiesBefore, 2)
        XCTAssertTrue(mounted.engine.showsJumpToLatest)
    }

    func testJumpToLatestReturnsToTheBottomAndFollowsAgain() throws {
        let mounted = try mount(Self.transcript(0..<120))
        // Within three viewports, so the jump animates and gets its final pin.
        browse(mounted, to: maxOffset(mounted.scrollView) - mounted.scrollView.bounds.height * 2)
        XCTAssertEqual(mounted.engine.mode, .browsing)
        mounted.engine.explicitLatestRequested(animated: true)
        XCTAssertTrue(mounted.engine.latestAnimationInFlight, "a short jump animates")
        settle(mounted.host.view, seconds: ChatScrollEngine.latestAnimationDuration + 0.2)
        mounted.engine.latestAnimationFinished()
        settle(mounted.host.view, seconds: 0.2)
        assertAtLatest(mounted, "the jump lands on the latest message")

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<121))
        settle(mounted.host.view)
        assertAtLatest(mounted, "and following resumes")
    }

    /// Eric's report: send, leave the screen alone, and when the turn
    /// completes the transcript sits past its end. Completion removes the
    /// turn's partial rows and live tail and appends one settled reply, so
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
        appState.streamingText = String(repeating: "The final answer streams in with several lines. ", count: 30)
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
        appState.streamingText = ""
        checkpoint("completion published", mounted, recorder)
        settle(mounted.host.view, seconds: 0.6)
        checkpoint("completion after", mounted, recorder)
        print("[ChatScrollHostedTests] completion trace:\n\(recorder.dump(since: mark))")
        assertAtLatest(mounted, "a completed turn leaves no empty space under it\n\(recorder.dump(since: mark))")
        XCTAssertTrue(mounted.engine.isFollowingLatest)
    }

    /// Issue #302: the transcript bounced on its own until touched. With no
    /// input and nothing new arriving, the offset must not move at all.
    func testAnIdleTranscriptHoldsStill() throws {
        let mounted = try mount(Self.uneven(0..<90))
        let recorder = ScrollRecorder(mounted.scrollView)
        mounted.appState.messages.append(contentsOf: Self.uneven(90..<93))
        mounted.appState.streamingText = String(repeating: "Streaming with ```code``` and *emphasis*. ", count: 20)
        settle(mounted.host.view)
        mounted.appState.streamingText = ""
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
}
