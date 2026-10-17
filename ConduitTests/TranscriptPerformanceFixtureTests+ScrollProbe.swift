import XCTest
import SwiftUI
import UIKit
@testable import Conduit

/// Diagnostic probe: scrolls the real ChatView through a long, mixed
/// transcript one display frame at a time and reports the main-thread work
/// each frame did. Prints `SCROLL_PROBE` lines; asserts only that the
/// harness ran.
extension TranscriptPerformanceFixtureTests {

    private struct ProbeCounters {
        var bubble = 0
        var markdown = 0
        var markdownFresh = 0
        var markdownRepeat = 0
        var textUpdate = 0
        var textRebuild = 0
        var textKit = 0
        var rowFrames = 0
        var layoutMetrics = 0
        var chatBody = 0
        var composerBody = 0

        @MainActor static func read() -> ProbeCounters {
            ProbeCounters(
                bubble: TranscriptPerf.settledMessageBubbleBodyEvaluations,
                markdown: TranscriptPerf.settledMarkdownTextBodyEvaluations,
                markdownFresh: TranscriptPerf.settledMarkdownFreshMountEvaluations,
                markdownRepeat: TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations,
                textUpdate: TranscriptPerf.selectableTextViewUpdateCalls,
                textRebuild: TranscriptPerf.selectableTextViewTextRebuilds,
                textKit: TranscriptPerf.textKitMeasurementCalls,
                rowFrames: TranscriptPerf.rowFramePreferenceUpdates,
                layoutMetrics: TranscriptPerf.layoutMetricsChangedCalls,
                chatBody: TranscriptPerf.chatViewBodyEvaluations,
                composerBody: TranscriptPerf.composerBarBodyEvaluations
            )
        }

        static func - (lhs: ProbeCounters, rhs: ProbeCounters) -> ProbeCounters {
            ProbeCounters(
                bubble: lhs.bubble - rhs.bubble,
                markdown: lhs.markdown - rhs.markdown,
                markdownFresh: lhs.markdownFresh - rhs.markdownFresh,
                markdownRepeat: lhs.markdownRepeat - rhs.markdownRepeat,
                textUpdate: lhs.textUpdate - rhs.textUpdate,
                textRebuild: lhs.textRebuild - rhs.textRebuild,
                textKit: lhs.textKit - rhs.textKit,
                rowFrames: lhs.rowFrames - rhs.rowFrames,
                layoutMetrics: lhs.layoutMetrics - rhs.layoutMetrics,
                chatBody: lhs.chatBody - rhs.chatBody,
                composerBody: lhs.composerBody - rhs.composerBody
            )
        }

        static func + (lhs: ProbeCounters, rhs: ProbeCounters) -> ProbeCounters {
            ProbeCounters(
                bubble: lhs.bubble + rhs.bubble,
                markdown: lhs.markdown + rhs.markdown,
                markdownFresh: lhs.markdownFresh + rhs.markdownFresh,
                markdownRepeat: lhs.markdownRepeat + rhs.markdownRepeat,
                textUpdate: lhs.textUpdate + rhs.textUpdate,
                textRebuild: lhs.textRebuild + rhs.textRebuild,
                textKit: lhs.textKit + rhs.textKit,
                rowFrames: lhs.rowFrames + rhs.rowFrames,
                layoutMetrics: lhs.layoutMetrics + rhs.layoutMetrics,
                chatBody: lhs.chatBody + rhs.chatBody,
                composerBody: lhs.composerBody + rhs.composerBody
            )
        }

        var summary: String {
            "bubble=\(bubble) md=\(markdown) mdFresh=\(markdownFresh) mdRepeat=\(markdownRepeat) "
                + "textUpd=\(textUpdate) textRebuild=\(textRebuild) textKit=\(textKit) "
                + "rowFrames=\(rowFrames) layout=\(layoutMetrics) chatBody=\(chatBody) composer=\(composerBody)"
        }
    }

    private struct ProbeFrame {
        let index: Int
        let milliseconds: Double
        let counters: ProbeCounters
        let offsetError: CGFloat
        let contentHeightChange: CGFloat
        let mountedRows: Int
    }

    /// Turns the way a working chat looks: a question, thinking, two tool
    /// calls and a Markdown answer, with a long answer every fifth turn.
    private static func probeTranscript(turns: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let stamp = "2026-01-01T00:00:00Z"
        for turn in 0..<turns {
            messages.append(ChatMessage(
                id: "probe-\(turn)-user",
                role: .user,
                content: turn % 3 == 0
                    ? "Quick one: what changed in turn \(turn)?"
                    : "Can you look at the logs from run \(turn) and tell me why the import step slowed down? It used to take a few seconds.",
                timestamp: stamp
            ))
            messages.append(ChatMessage(
                id: "probe-\(turn)-thinking",
                role: .reasoning,
                content: String(repeating: "Checking what the logs for run \(turn) say before answering. ", count: 3),
                timestamp: stamp
            ))
            for call in 0..<2 {
                messages.append(ChatMessage(
                    id: "probe-\(turn)-tool-\(call)",
                    role: .tool,
                    content: "",
                    timestamp: stamp,
                    tool: ToolActivity(
                        id: "call-\(turn)-\(call)",
                        name: call == 0 ? "terminal" : "read_file",
                        input: call == 0 ? "grep -n import logs/run-\(turn).log" : "logs/run-\(turn).log",
                        output: String(repeating: "line \(turn): import step took 4.2 s\n", count: 6),
                        status: .complete,
                        duration: 1.4
                    )
                ))
            }
            messages.append(ChatMessage(
                id: "probe-\(turn)-answer",
                role: .assistant,
                content: turn % 5 == 0 ? longAnswer(turn) : shortAnswer(turn),
                timestamp: stamp
            ))
        }
        return messages
    }

    private static func shortAnswer(_ turn: Int) -> String {
        """
        The import step in run \(turn) slowed down because the **cache was cold**: the first \
        pass re-read every file. Later runs were back to `2.1 s`.

        - The cache directory was cleared by the cleanup job.
        - The next run rebuilt it, which took longer.
        - Nothing in the code changed.
        """
    }

    private static func longAnswer(_ turn: Int) -> String {
        """
        ## What happened in run \(turn)

        Here's the timeline from the logs, with the slow part marked. The import step reads each \
        source file, hashes it and compares the hash with the cache, so a cold cache means every \
        file is parsed again.

        | Step | Before | Run \(turn) |
        | --- | --- | --- |
        | Fetch | 0.8 s | 0.9 s |
        | Import | 2.1 s | 4.2 s |
        | Index | 1.3 s | 1.2 s |

        ```swift
        func importAll(_ files: [URL]) async throws {
            for file in files where try await cache.isStale(file) {
                try await importer.parse(file)
            }
        }
        ```

        > The cleanup job removed the cache at 03:00, an hour before run \(turn).

        1. Keep the cache out of the cleanup job's folder.
        2. Warm it after cleanup instead of during the next run.
        3. Add a log line when the cache is rebuilt, so this is easy to spot next time.

        That should bring the import step back to about two seconds.
        """
    }

    private static func probeFind<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = probeFind(type, in: subview) { return match }
        }
        return nil
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
        return sorted[index]
    }

    private static func report(_ phase: String, _ frames: [ProbeFrame]) {
        let times = frames.map(\.milliseconds).sorted()
        let total = frames.reduce(ProbeCounters()) { $0 + $1.counters }
        let over8 = frames.filter { $0.milliseconds > 8.3 }.count
        let over16 = frames.filter { $0.milliseconds > 16.7 }.count
        let jumps = frames.filter { abs($0.offsetError) > 0.5 }
        let resized = frames.filter { abs($0.contentHeightChange) > 0.5 }
        let chatBodyFrames = frames.filter { $0.counters.chatBody > 0 }.count
        print(String(
            format: "SCROLL_PROBE %@ frames=%ld median=%.2fms p90=%.2fms p99=%.2fms max=%.2fms over8=%ld over16=%ld",
            phase, frames.count,
            percentile(times, 0.5), percentile(times, 0.9), percentile(times, 0.99), times.last ?? 0,
            over8, over16
        ))
        print("SCROLL_PROBE \(phase) totals \(total.summary)")
        print("SCROLL_PROBE \(phase) chatBodyFrames=\(chatBodyFrames) offsetJumps=\(jumps.count) contentResizes=\(resized.count) mountedRows(last)=\(frames.last?.mountedRows ?? 0)")
        for jump in jumps.prefix(5) {
            print(String(format: "SCROLL_PROBE %@ jump frame=%ld error=%.1fpt heightChange=%.1fpt", phase, jump.index, jump.offsetError, jump.contentHeightChange))
        }
        for frame in frames.sorted(by: { $0.milliseconds > $1.milliseconds }).prefix(8) {
            print(String(format: "SCROLL_PROBE %@ slow frame=%ld %.2fms heightChange=%.1fpt ", phase, frame.index, frame.milliseconds, frame.contentHeightChange)
                + frame.counters.summary)
        }
    }

    func testScrollProbeReportsWorkPerFrame() throws {
        let suiteName = "transcript-scroll-probe"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.messages = Self.probeTranscript(turns: 60)

        let host = UIHostingController(rootView: DormancyHarnessEnvironment.applying(
            ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize)
                .environmentObject(appState)
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        var locator: ChatScrollSurfaceLocatorView?
        XCTAssertTrue(
            PerformanceFixtureWait.eventually(pumpingLayoutOf: host.view) {
                locator = Self.probeFind(ChatScrollSurfaceLocatorView.self, in: host.view)
                return locator?.surface?.scrollView != nil
            },
            "the locator must find the transcript's UIScrollView"
        )
        let scrollView = try XCTUnwrap(locator?.surface?.scrollView)
        let engine = try XCTUnwrap(locator?.engine)
        XCTAssertTrue(
            PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2, pumpingLayoutOf: host.view),
            "the transcript never settled"
        )
        print(String(
            format: "SCROLL_PROBE setup rows=%ld contentHeight=%.0f offset=%.0f viewport=%.0f",
            appState.messages.count, scrollView.contentSize.height, scrollView.contentOffset.y, scrollView.bounds.height
        ))

        // One display frame: the finger moves the content, then the frame's
        // layout and render commit run, then whatever the main queue holds.
        func frame(_ index: Int, to offsetY: CGFloat) -> ProbeFrame {
            let before = ProbeCounters.read()
            let heightBefore = scrollView.contentSize.height
            let start = CACurrentMediaTime()
            scrollView.contentOffset.y = offsetY
            host.view.layoutIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date())
            let elapsed = (CACurrentMediaTime() - start) * 1000
            return ProbeFrame(
                index: index,
                milliseconds: elapsed,
                counters: ProbeCounters.read() - before,
                offsetError: scrollView.contentOffset.y - offsetY,
                contentHeightChange: scrollView.contentSize.height - heightBefore,
                mountedRows: Self.mountedRowEstimate(in: scrollView)
            )
        }

        let step: CGFloat = 24
        let distance = min(9000, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        let steps = Int(distance / step)

        // Up from the latest message into rows never shown before.
        engine.userDragBegan()
        var upFrames: [ProbeFrame] = []
        var offset = scrollView.contentOffset.y
        for index in 0..<steps {
            offset -= step
            upFrames.append(frame(index, to: offset))
            offset = scrollView.contentOffset.y
        }
        engine.userDragEnded()
        Self.report("up-new-rows", upFrames)

        // Back down over the same rows.
        engine.userDragBegan()
        var downFrames: [ProbeFrame] = []
        for index in 0..<steps {
            offset += step
            downFrames.append(frame(index, to: offset))
            offset = scrollView.contentOffset.y
        }
        engine.userDragEnded()
        Self.report("down-seen-rows", downFrames)

        // Up again over rows that have been shown once.
        engine.userDragBegan()
        var againFrames: [ProbeFrame] = []
        for index in 0..<steps {
            offset -= step
            againFrames.append(frame(index, to: offset))
            offset = scrollView.contentOffset.y
        }
        engine.userDragEnded()
        Self.report("up-seen-rows", againFrames)

        // Still: no finger, nothing streaming.
        var idleFrames: [ProbeFrame] = []
        for index in 0..<120 {
            let before = ProbeCounters.read()
            let start = CACurrentMediaTime()
            host.view.layoutIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
            idleFrames.append(ProbeFrame(
                index: index,
                milliseconds: (CACurrentMediaTime() - start) * 1000,
                counters: ProbeCounters.read() - before,
                offsetError: 0,
                contentHeightChange: 0,
                mountedRows: Self.mountedRowEstimate(in: scrollView)
            ))
        }
        Self.report("idle", idleFrames)

        XCTAssertGreaterThan(upFrames.count, 0, "the probe scrolled")
    }

    /// Text views on screen, a stand-in for how many rows LazyVStack keeps.
    private static func mountedRowEstimate(in scrollView: UIScrollView) -> Int {
        var count = 0
        func walk(_ view: UIView) {
            if view is UITextView { count += 1 }
            view.subviews.forEach(walk)
        }
        walk(scrollView)
        return count
    }
}
