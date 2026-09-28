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
        let mounted = try mount(Self.transcript(40..<120))
        browse(mounted, to: mounted.scrollView.contentOffset.y - 1200)
        let topRow = try XCTUnwrap(mounted.engine.topVisibleMessageID)
        let before = try XCTUnwrap(screenY(of: topRow, in: mounted))

        mounted.engine.olderPageBackfillRequested(sessionKey: mounted.engine.renderedSessionKey)
        mounted.appState.messages = Self.transcript(0..<120)
        settle(mounted.host.view)

        let after = try XCTUnwrap(screenY(of: topRow, in: mounted))
        XCTAssertEqual(after, before, accuracy: 2, "the prepend lands above without moving the reader")
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
}
