import XCTest
import Combine
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
        var appPublishes = 0
        var enginePublishes = 0

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
                composerBody: TranscriptPerf.composerBarBodyEvaluations,
                appPublishes: ProbePublishTrace.appPublishes,
                enginePublishes: ProbePublishTrace.enginePublishes
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
                composerBody: lhs.composerBody - rhs.composerBody,
                appPublishes: lhs.appPublishes - rhs.appPublishes,
                enginePublishes: lhs.enginePublishes - rhs.enginePublishes
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
                composerBody: lhs.composerBody + rhs.composerBody,
                appPublishes: lhs.appPublishes + rhs.appPublishes,
                enginePublishes: lhs.enginePublishes + rhs.enginePublishes
            )
        }

        var summary: String {
            "bubble=\(bubble) md=\(markdown) mdFresh=\(markdownFresh) mdRepeat=\(markdownRepeat) "
                + "textUpd=\(textUpdate) textRebuild=\(textRebuild) textKit=\(textKit) "
                + "rowFrames=\(rowFrames) layout=\(layoutMetrics) chatBody=\(chatBody) composer=\(composerBody) "
                + "appPub=\(appPublishes) enginePub=\(enginePublishes)"
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
        let textFrames = frames.filter { $0.counters.textRebuild > 0 }.map(\.milliseconds).sorted(by: >)
        print(String(
            format: "SCROLL_PROBE %@ sum=%.0fms textFrames=%ld textFrameSum=%.0fms worst=%@",
            phase, frames.reduce(0) { $0 + $1.milliseconds }, textFrames.count, textFrames.reduce(0, +),
            textFrames.prefix(10).map { String(format: "%.0f", $0) }.joined(separator: ",")
        ))
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
        MarkdownProseRun.probeTurnsOff = ProcessInfo.processInfo.environment["PROBE_JOINS"] == "0"
        defer { MarkdownProseRun.probeTurnsOff = false }
        print("SCROLL_PROBE setup joins=\(MarkdownProseRun.probeTurnsOff ? "off" : "on")")
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
        // Who publishes while the finger moves: every AppState publish
        // re-evaluates each row that observes it.
        let appSink = appState.objectWillChange.sink { _ in
            MainActor.assumeIsolated { ProbePublishTrace.recordAppPublish() }
        }
        let engineSink = engine.objectWillChange.sink { _ in
            MainActor.assumeIsolated { ProbePublishTrace.enginePublishes += 1 }
        }
        defer {
            appSink.cancel()
            engineSink.cancel()
            ProbePublishTrace.printStacks()
        }
        print(String(
            format: "SCROLL_PROBE setup rows=%ld contentHeight=%.0f offset=%.0f viewport=%.0f",
            appState.messages.count, scrollView.contentSize.height, scrollView.contentOffset.y, scrollView.bounds.height
        ))
        print("SCROLL_PROBE setup " + Self.mountedSpan(in: scrollView))

        // Who resized the content or moved the offset inside a frame.
        final class ProbeLayoutLog {
            var frame = -1
            var sizes: [(frame: Int, line: String)] = []
            var moves: [String] = []
        }
        let layoutLog = ProbeLayoutLog()
        func describeMode() -> String {
            "mode=\(engine.mode) dragging=\(engine.isDragging)"
        }
        let layoutObservations = [
            scrollView.observe(\.contentSize, options: [.old, .new]) { view, change in
                MainActor.assumeIsolated {
                    layoutLog.sizes.append((layoutLog.frame, String(
                        format: "size %.0f -> %.0f offset=%.0f bottomDistance=%.0f ",
                        change.oldValue?.height ?? -1, change.newValue?.height ?? -1, view.contentOffset.y,
                        view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom - view.contentOffset.y
                    ) + describeMode()))
                }
            },
            scrollView.observe(\.contentOffset, options: [.old, .new]) { view, change in
                guard let old = change.oldValue?.y, let new = change.newValue?.y, abs(new - old) > 100 else { return }
                MainActor.assumeIsolated {
                    let stack = Thread.callStackSymbols.dropFirst(2).prefix(24).compactMap { symbol -> String? in
                        let parts = symbol.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                        guard parts.count == 4 else { return nil }
                        return String(parts[1]) + " " + String(parts[3].prefix(110))
                    }
                    layoutLog.moves.append(String(
                        format: "frame=%ld offset %.0f -> %.0f size=%.0f ", layoutLog.frame, old, new, view.contentSize.height
                    ) + describeMode() + "\n" + stack.map { "SCROLL_PROBE trace   " + $0 }.joined(separator: "\n"))
                }
            }
        ]
        defer { layoutObservations.forEach { $0.invalidate() } }
        func reportLayout(_ phase: String, _ frames: [ProbeFrame]) {
            let jumpFrames = Set(frames.filter { abs($0.offsetError) > 0.5 }.map(\.index))
            let near = layoutLog.sizes.filter { size in jumpFrames.contains { abs($0 - size.frame) <= 1 } }
            print("SCROLL_PROBE trace \(phase) sizeChanges=\(layoutLog.sizes.count) bigMoves=\(layoutLog.moves.count)")
            for size in near.prefix(30) {
                print("SCROLL_PROBE trace \(phase) frame=\(size.frame) \(size.line)")
            }
            for move in layoutLog.moves.prefix(4) {
                print("SCROLL_PROBE trace \(phase) " + move)
            }
            layoutLog.sizes = []
            layoutLog.moves = []
        }

        // One display frame: the finger moves the content, then the frame's
        // layout and render commit run, then whatever the main queue holds.
        func frame(_ index: Int, to offsetY: CGFloat) -> ProbeFrame {
            layoutLog.frame = index
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
        reportLayout("up-new-rows", upFrames)
        print("SCROLL_PROBE up-new-rows end " + Self.mountedSpan(in: scrollView))

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
        reportLayout("down-seen-rows", downFrames)
        print("SCROLL_PROBE down-seen-rows end " + Self.mountedSpan(in: scrollView))

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
        reportLayout("up-seen-rows", againFrames)
        print("SCROLL_PROBE up-seen-rows end " + Self.mountedSpan(in: scrollView))

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
        print("SCROLL_PROBE idle end " + Self.mountedSpan(in: scrollView))

        XCTAssertGreaterThan(upFrames.count, 0, "the probe scrolled")
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values.sorted(), 0.5)
    }

    /// One row type at a time: what mounting it and taking it down again
    /// costs, the work a row pays each time LazyVStack brings it back into
    /// view. The first pass mounts fresh text views; later passes get them
    /// from the reuse pool.
    func testScrollProbeReportsMountCostByRow() throws {
        let suiteName = "transcript-scroll-probe-mount"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let transcript = Self.probeTranscript(turns: 2)
        let rows: [(String, ChatMessage)] = [
            ("user", transcript[0]),
            ("long-answer", transcript[4]),
            ("short-answer", transcript[9]),
        ]

        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        func commit() {
            host.view.layoutIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date())
        }

        for (name, message) in rows {
            var mounts: [Double] = []
            var unmounts: [Double] = []
            var counters = ProbeCounters()
            var textViews = 0
            for pass in 0..<12 {
                let before = ProbeCounters.read()
                let start = CACurrentMediaTime()
                host.rootView = AnyView(DormancyHarnessEnvironment.applying(
                    VStack(spacing: 0) {
                        MessageBubble(message: message, gatewayResolver: nil)
                    }
                    .padding(.horizontal, 18)
                    .id("\(name)-\(pass)")
                    .environmentObject(appState)
                ))
                commit()
                mounts.append((CACurrentMediaTime() - start) * 1000)
                counters = ProbeCounters.read() - before
                textViews = Self.mountedRowEstimate(in: host.view)

                let downStart = CACurrentMediaTime()
                host.rootView = AnyView(EmptyView())
                commit()
                unmounts.append((CACurrentMediaTime() - downStart) * 1000)
            }
            print(String(
                format: "SCROLL_PROBE mount %@ first=%.2fms median=%.2fms unmount=%.2fms textViews=%ld ",
                name, mounts[0], Self.median(Array(mounts.dropFirst())), Self.median(Array(unmounts.dropFirst())),
                textViews
            ) + counters.summary)
        }

        // The same 20 blocks a long answer mounts, on their own: UIKit text
        // views step by step, then SwiftUI Text for comparison.
        let blocks: [NSAttributedString] = (0..<20).map { index in
            NSAttributedString(
                string: index % 4 == 0
                    ? "Import \(index)"
                    : "The import step reads each source file, hashes it and compares the hash with the cache \(index).",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
            )
        }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        host.view.addSubview(container)
        var plain = [String: [Double]]()
        var coordinated = [String: [Double]]()
        for _ in 0..<8 {
            var start = CACurrentMediaTime()
            let textViews = blocks.map { _ in SelectableTextView.makeTextView() }
            plain["create", default: []].append((CACurrentMediaTime() - start) * 1000)

            start = CACurrentMediaTime()
            for (textView, text) in zip(textViews, blocks) { textView.attributedText = text }
            plain["text", default: []].append((CACurrentMediaTime() - start) * 1000)

            start = CACurrentMediaTime()
            let heights = textViews.map { SelectableTextView.measuredWrappingHeight(of: $0, at: 366) }
            plain["measure", default: []].append((CACurrentMediaTime() - start) * 1000)

            start = CACurrentMediaTime()
            var y: CGFloat = 0
            for (textView, height) in zip(textViews, heights) {
                textView.frame = CGRect(x: 18, y: y, width: 366, height: height)
                y += height
                container.addSubview(textView)
            }
            container.layoutIfNeeded()
            CATransaction.flush()
            plain["draw", default: []].append((CACurrentMediaTime() - start) * 1000)

            start = CACurrentMediaTime()
            textViews.forEach { $0.removeFromSuperview() }
            CATransaction.flush()
            plain["remove", default: []].append((CACurrentMediaTime() - start) * 1000)

            let selection = MarkdownSelectionCoordinator()
            start = CACurrentMediaTime()
            let hostViews = blocks.enumerated().map { index, text in
                let view = SelectableTextView(
                    attributedText: text,
                    selectionCoordinator: selection,
                    selectionSegment: MarkdownSelectionSegmentDescriptor(id: "block-\(index)", order: index, separatorBefore: "\n")
                )
                return view.makeUIViewForTests(coordinator: view.makeCoordinator())
            }
            coordinated["make", default: []].append((CACurrentMediaTime() - start) * 1000)

            start = CACurrentMediaTime()
            y = 0
            for hostView in hostViews {
                hostView.frame = CGRect(x: 18, y: y, width: 366, height: 44)
                y += 44
                container.addSubview(hostView)
            }
            container.layoutIfNeeded()
            CATransaction.flush()
            coordinated["draw", default: []].append((CACurrentMediaTime() - start) * 1000)
            hostViews.forEach { $0.removeFromSuperview() }
            CATransaction.flush()
        }
        container.removeFromSuperview()
        for key in ["create", "text", "measure", "draw", "remove"] {
            print(String(format: "SCROLL_PROBE uikit20 plain %@ first=%.2fms median=%.2fms", key, plain[key]![0], Self.median(Array(plain[key]!.dropFirst()))))
        }
        for key in ["make", "draw"] {
            print(String(format: "SCROLL_PROBE uikit20 coordinated %@ first=%.2fms median=%.2fms", key, coordinated[key]![0], Self.median(Array(coordinated[key]!.dropFirst()))))
        }

        // Foundation's Markdown parser plus the UIKit bridge, per fragment.
        var parses: [Double] = []
        for _ in 0..<8 {
            let start = CACurrentMediaTime()
            for block in blocks {
                _ = SelectableTextView.bridge(
                    InlineMarkdownContent.attributed(source: "**Step** " + block.string, references: .empty),
                    defaultFont: .preferredFont(forTextStyle: .body),
                    defaultColor: .label,
                    linkColor: .link
                )
            }
            parses.append((CACurrentMediaTime() - start) * 1000)
        }
        print(String(format: "SCROLL_PROBE parse20 first=%.2fms median=%.2fms", parses[0], Self.median(Array(parses.dropFirst()))))

        // A view that draws its own content, the size of a long answer.
        var drawnOverlays: [Double] = []
        for _ in 0..<8 {
            let start = CACurrentMediaTime()
            let overlay = ProbeDrawnView(frame: CGRect(x: 0, y: 0, width: 366, height: 1200))
            container.addSubview(overlay)
            host.view.addSubview(container)
            CATransaction.flush()
            overlay.removeFromSuperview()
            container.removeFromSuperview()
            drawnOverlays.append((CACurrentMediaTime() - start) * 1000)
        }
        print(String(format: "SCROLL_PROBE drawnOverlay366x1200 first=%.2fms median=%.2fms", drawnOverlays[0], Self.median(Array(drawnOverlays.dropFirst()))))

        var swiftUIMounts: [Double] = []
        let attributed = blocks.map { (try? AttributedString($0, including: \.uiKit)) ?? AttributedString($0.string) }
        for pass in 0..<8 {
            let start = CACurrentMediaTime()
            host.rootView = AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(attributed.indices, id: \.self) { index in
                        Text(attributed[index]).lineSpacing(4)
                    }
                }
                .padding(.horizontal, 18)
                .id("text-\(pass)")
            )
            commit()
            swiftUIMounts.append((CACurrentMediaTime() - start) * 1000)
            host.rootView = AnyView(EmptyView())
            commit()
        }
        print(String(format: "SCROLL_PROBE swiftui20 Text mount first=%.2fms median=%.2fms", swiftUIMounts[0], Self.median(Array(swiftUIMounts.dropFirst()))))
    }

    /// What 20 Markdown blocks cost as different kinds of text view:
    /// TextKit 2 (today) vs TextKit 1, one view per block vs one view for
    /// all of them, fresh views vs views reused from a pool, and UILabel.
    func testScrollProbeComparesTextViewKinds() throws {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = UIView(frame: window.bounds)
        host.view.addSubview(container)
        defer {
            container.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        func blocks(_ suffix: String) -> [NSAttributedString] {
            (0..<20).map { index in
                NSAttributedString(
                    string: index % 4 == 0
                        ? "Import \(index)\(suffix)"
                        : "The import step reads each source file, hashes it and compares the hash with the cache \(index)\(suffix).",
                    attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
                )
            }
        }
        func joined(_ parts: [NSAttributedString]) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for (index, part) in parts.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "\n\n")) }
                result.append(part)
            }
            return result
        }
        let even = blocks("")
        let odd = blocks(" again")

        func textView(textKit1: Bool, selectable: Bool = true) -> UITextView {
            let view = UITextView(usingTextLayoutManager: !textKit1)
            view.isEditable = false
            view.isSelectable = selectable
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            return view
        }
        /// The text view inside a host view, pinned with constraints the
        /// way SelectableTextViewHostView does today, or framed by hand.
        func hosted(constraints: Bool, textKit1: Bool = false) -> UIView {
            let child = textView(textKit1: textKit1)
            let hostView: UIView = constraints ? UIView() : ProbeFramingHostView()
            hostView.addSubview(child)
            if constraints {
                child.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    child.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
                    child.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
                    child.topAnchor.constraint(equalTo: hostView.topAnchor),
                    child.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
                ])
            }
            return hostView
        }
        func label() -> UILabel {
            let view = UILabel()
            view.numberOfLines = 0
            return view
        }

        struct Kind {
            let name: String
            let joined: Bool
            let reused: Bool
            let make: () -> UIView
        }
        let kinds: [Kind] = [
            Kind(name: "tk2", joined: false, reused: false) { textView(textKit1: false) },
            Kind(name: "tk1", joined: false, reused: false) { textView(textKit1: true) },
            Kind(name: "tk2-unselectable", joined: false, reused: false) { textView(textKit1: false, selectable: false) },
            Kind(name: "tk2-reused", joined: false, reused: true) { textView(textKit1: false) },
            Kind(name: "tk1-reused", joined: false, reused: true) { textView(textKit1: true) },
            Kind(name: "tk2-joined", joined: true, reused: false) { textView(textKit1: false) },
            Kind(name: "tk1-joined", joined: true, reused: false) { textView(textKit1: true) },
            Kind(name: "tk2-constraint-host", joined: false, reused: false) { hosted(constraints: true) },
            Kind(name: "tk2-frame-host", joined: false, reused: false) { hosted(constraints: false) },
            Kind(name: "tk1-constraint-host", joined: false, reused: false) { hosted(constraints: true, textKit1: true) },
            Kind(name: "tk1-frame-host", joined: false, reused: false) { hosted(constraints: false, textKit1: true) },
            Kind(name: "label", joined: false, reused: false) { label() },
        ]

        for kind in kinds {
            var phases = [String: [Double]]()
            var pool: [UIView] = []
            for pass in 0..<10 {
                let parts = pass % 2 == 0 ? even : odd
                let texts = kind.joined ? [joined(parts)] : parts

                var start = CACurrentMediaTime()
                let views: [UIView]
                if kind.reused, pool.count == texts.count {
                    views = pool
                } else {
                    views = texts.map { _ in kind.make() }
                }
                phases["create", default: []].append((CACurrentMediaTime() - start) * 1000)

                start = CACurrentMediaTime()
                for (view, text) in zip(views, texts) {
                    if let view = (view as? UITextView) ?? (view.subviews.first as? UITextView) {
                        view.attributedText = text
                    } else if let view = view as? UILabel {
                        view.attributedText = text
                    }
                }
                phases["text", default: []].append((CACurrentMediaTime() - start) * 1000)

                start = CACurrentMediaTime()
                let heights = views.map { view -> CGFloat in
                    let measured: UIView = (view.subviews.first as? UITextView) ?? view
                    return ceil(measured.sizeThatFits(CGSize(width: 366, height: CGFloat.greatestFiniteMagnitude)).height)
                }
                phases["measure", default: []].append((CACurrentMediaTime() - start) * 1000)

                start = CACurrentMediaTime()
                var y: CGFloat = 0
                for (view, height) in zip(views, heights) {
                    view.frame = CGRect(x: 18, y: y, width: 366, height: height)
                    y += height + 8
                    container.addSubview(view)
                }
                container.layoutIfNeeded()
                CATransaction.flush()
                phases["draw", default: []].append((CACurrentMediaTime() - start) * 1000)

                start = CACurrentMediaTime()
                views.forEach { $0.removeFromSuperview() }
                CATransaction.flush()
                phases["remove", default: []].append((CACurrentMediaTime() - start) * 1000)

                if kind.reused { pool = views }
            }
            // The first pass pays one-time setup; a reused pool also pays
            // its creation there.
            let medians = ["create", "text", "measure", "draw", "remove"].map { key in
                (key, Self.median(Array((phases[key] ?? []).dropFirst())))
            }
            let total = medians.reduce(0.0) { $0 + $1.1 }
            print("SCROLL_PROBE kinds \(kind.name) total=\(Self.ms(total)) "
                + medians.map { "\($0.0)=\(Self.ms($0.1))" }.joined(separator: " "))
        }
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%.2fms", value)
    }

    /// Where the mounted text views sit in content coordinates, to tell a
    /// scroll that mounted nothing from rows that were already there.
    private static func mountedSpan(in scrollView: UIScrollView) -> String {
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var count = 0
        func walk(_ view: UIView) {
            if view is UITextView, view.window != nil {
                let frame = view.convert(view.bounds, to: scrollView)
                minY = min(minY, frame.minY)
                maxY = max(maxY, frame.maxY)
                count += 1
            }
            view.subviews.forEach(walk)
        }
        walk(scrollView)
        return String(
            format: "offset=%.0f visible=%.0f..%.0f textViews=%ld textViewSpan=%.0f..%.0f",
            scrollView.contentOffset.y, scrollView.contentOffset.y, scrollView.contentOffset.y + scrollView.bounds.height,
            count, count > 0 ? minY : 0, count > 0 ? maxY : 0
        )
    }

    /// Text views on screen, a stand-in for how many rows LazyVStack keeps.
    private static func mountedRowEstimate(in scrollView: UIView) -> Int {
        var count = 0
        func walk(_ view: UIView) {
            if view is UITextView { count += 1 }
            view.subviews.forEach(walk)
        }
        walk(scrollView)
        return count
    }
}

@MainActor
private enum ProbePublishTrace {
    static var appPublishes = 0
    static var enginePublishes = 0
    private static var stacks: [[UInt]: Int] = [:]
    private static var order: [[UInt]] = []

    /// Counts each AppState publish and keeps the distinct call stacks
    /// that caused them, so the log names the property that published.
    /// Only return addresses are taken inside a frame; they are turned
    /// into names when printed, so the trace adds little to frame times.
    static func recordAppPublish() {
        appPublishes += 1
        let key = Thread.callStackReturnAddresses.dropFirst(2).prefix(16).map(\.uintValue)
        if stacks[key] == nil { order.append(key) }
        stacks[key, default: 0] += 1
    }

    static func printStacks() {
        for key in order.prefix(12) {
            let names = key.map { address -> String in
                var info = Dl_info()
                guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
                      let symbol = info.dli_sname else { return String(format: "0x%lx", address) }
                return String(cString: symbol)
            }
            print("SCROLL_PROBE appPublish count=\(stacks[key] ?? 0)")
            names.forEach { print("SCROLL_PROBE stack   \($0)") }
        }
    }
}

private final class ProbeFramingHostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
    }
}

private final class ProbeDrawnView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {}
}
