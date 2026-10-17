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
        print("SCROLL_PROBE \(phase) over16 at " + frames.filter { $0.milliseconds > 16.7 }.prefix(60).map {
            String(format: "%ld:%.0f%@", $0.index, $0.milliseconds, $0.counters.textRebuild > 0 ? "t\($0.counters.textRebuild)" : "")
        }.joined(separator: " "))
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
        let environment = ProcessInfo.processInfo.environment
        ChatView.probeKeepsTextViews = environment["PROBE_TEXT_VIEWS"] == "1"
        defer { ChatView.probeKeepsTextViews = false }
        let backdrop = environment["PROBE_NO_BACKDROP"] != "1"
        print("SCROLL_PROBE setup profiled=\(environment["PROBE_MARKER"] == nil ? "no" : "yes") textViews=\(ChatView.probeKeepsTextViews ? "always" : "on touch") backdrop=\(backdrop ? "drifting" : "none")")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.messages = Self.probeTranscript(turns: 60)

        // The chat as the app shows it (RootView): over the drifting
        // backdrop, in a navigation stack.
        let host = UIHostingController(rootView: DormancyHarnessEnvironment.applying(
            NavigationStack {
                ZStack {
                    if backdrop { ConduitBackdrop(drifts: true) }
                    ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize)
                }
            }
            .environmentObject(appState)
        ))
        // On screen in the app's scene: a window outside any scene is laid
        // out but never drawn, and rows scrolled into it never get their
        // views. The app's own windows (sign-in, with its own drifting
        // backdrop) hide meanwhile.
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has a window scene"
        )
        let appWindows = scene.windows.filter { !$0.isHidden }
        appWindows.forEach { $0.isHidden = true }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            appWindows.forEach { $0.isHidden = false }
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
        print("SCROLL_PROBE setup view " + Self.viewReport(scrollView: scrollView, engine: engine, messages: appState.messages))

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

        // Frames run the way the app runs them: a display link moves the
        // content one step, and everything the main run loop then does until
        // the next tick (SwiftUI's update, new rows' views going in, layout,
        // drawing, the commit) is that frame's work, read as the time the run
        // loop spends awake. Driving layout by hand left SwiftUI's own pass
        // out: new rows were laid out but their views never went in.
        let clock = ProbeFrameClock()
        let awakeTime = ProbeAwakeTime()
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            CFIndex.max
        ) { _, activity in
            awakeTime.observe(activity)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        // Where the slowest frames' time went: the main thread's stack,
        // sampled from another thread and tagged with the frame.
        let sampler = environment["PROBE_STACKS"] == "1" ? ProbeStackSampler() : nil
        sampler?.start()

        /// Moves the content `delta` points on each of `steps` display
        /// frames and returns each frame's work.
        func scrollFrames(phase: Int, steps: Int, delta: CGFloat) -> [ProbeFrame] {
            var frames: [ProbeFrame] = []
            var index = 0
            var markBefore = awakeTime.mark
            var countersBefore = ProbeCounters.read()
            var heightBefore = scrollView.contentSize.height
            var target = scrollView.contentOffset.y
            clock.tick = {
                let mark = awakeTime.mark
                sampler?.tag = -1
                if index > 0 {
                    frames.append(ProbeFrame(
                        index: index - 1,
                        milliseconds: (mark - markBefore) * 1000,
                        counters: ProbeCounters.read() - countersBefore,
                        offsetError: scrollView.contentOffset.y - target,
                        contentHeightChange: scrollView.contentSize.height - heightBefore,
                        mountedRows: Self.mountedRowEstimate(in: scrollView)
                    ))
                }
                guard index < steps else {
                    sampler?.tag = -1
                    return false
                }
                countersBefore = ProbeCounters.read()
                heightBefore = scrollView.contentSize.height
                target = scrollView.contentOffset.y + delta
                layoutLog.frame = index
                // The bookkeeping above stays out of the next frame.
                markBefore = awakeTime.mark
                sampler?.tag = phase < 2 ? phase * ProbeStackSampler.phaseStride + index : -1
                if delta != 0 { scrollView.contentOffset.y = target }
                index += 1
                return true
            }
            // Samples walk the stack up to this frame.
            var anchor = 0
            withUnsafeMutablePointer(to: &anchor) { sampler?.stackLimit = UInt(bitPattern: $0) }
            clock.run()
            return frames
        }

        // A sampler: say the chat is ready, then scroll once it has
        // started (it writes the go file).
        if let marker = environment["PROBE_MARKER"] {
            FileManager.default.createFile(atPath: marker + ".ready", contents: Data())
            let deadline = Date().addingTimeInterval(180)
            while !FileManager.default.fileExists(atPath: marker + ".go"), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }

        let step: CGFloat = 24
        let distance = min(9000, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        let steps = Int(distance / step)

        // Up from the latest message into rows never shown before.
        engine.userDragBegan()
        let upFrames = scrollFrames(phase: 0, steps: steps, delta: -step)
        engine.userDragEnded()
        Self.report("up-new-rows", upFrames)
        reportLayout("up-new-rows", upFrames)
        print("SCROLL_PROBE up-new-rows end " + Self.mountedSpan(in: scrollView))
        print("SCROLL_PROBE up-new-rows view " + Self.viewReport(scrollView: scrollView, engine: engine, messages: appState.messages))

        // Back down over the same rows.
        engine.userDragBegan()
        let downFrames = scrollFrames(phase: 1, steps: steps, delta: step)
        engine.userDragEnded()
        Self.report("down-seen-rows", downFrames)
        reportLayout("down-seen-rows", downFrames)
        print("SCROLL_PROBE down-seen-rows end " + Self.mountedSpan(in: scrollView))
        print("SCROLL_PROBE down-seen-rows view " + Self.viewReport(scrollView: scrollView, engine: engine, messages: appState.messages))

        // Up again over rows that have been shown once.
        engine.userDragBegan()
        let againFrames = scrollFrames(phase: 2, steps: steps, delta: -step)
        engine.userDragEnded()
        Self.report("up-seen-rows", againFrames)
        reportLayout("up-seen-rows", againFrames)
        print("SCROLL_PROBE up-seen-rows end " + Self.mountedSpan(in: scrollView))
        print("SCROLL_PROBE up-seen-rows view " + Self.viewReport(scrollView: scrollView, engine: engine, messages: appState.messages))

        // Still: no finger, nothing streaming.
        let idleFrames = scrollFrames(phase: 3, steps: 120, delta: 0)
        Self.report("idle", idleFrames)
        print("SCROLL_PROBE idle end " + Self.mountedSpan(in: scrollView))
        print("SCROLL_PROBE idle view " + Self.viewReport(scrollView: scrollView, engine: engine, messages: appState.messages))

        if let sampler {
            sampler.stop()
            sampler.printReport(phases: [
                (name: "up-new-rows", frames: upFrames.map { (index: $0.index, milliseconds: $0.milliseconds) }, slowest: 6),
                (name: "down-seen-rows", frames: downFrames.map { (index: $0.index, milliseconds: $0.milliseconds) }, slowest: 3),
            ])
        }

        // Hold while the sampler writes its report.
        if let marker = environment["PROBE_MARKER"] {
            FileManager.default.createFile(atPath: marker, contents: Data())
            let release = marker + ".release"
            let deadline = Date().addingTimeInterval(600)
            while !FileManager.default.fileExists(atPath: release), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
        }

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

    /// What the viewport shows: the rows the stack reports laid out (their
    /// frames, in transcript order), the text hosts inside the viewport, and
    /// the share of its pixels that differ from the background, near zero
    /// when the rows scrolled into view draw nothing.
    private static func viewReport(scrollView: UIScrollView, engine: ChatScrollEngine, messages: [ChatMessage]) -> String {
        let top = scrollView.contentOffset.y
        let bottom = top + scrollView.bounds.height
        let laidOut = messages.compactMap { message in engine.rowFrame(for: message.id).map { (message.id, $0) } }
        let orders = laidOut.map { $0.1.order }
        let inView = laidOut.filter { $0.1.maxY > top && $0.1.minY < bottom }
        var hostsInView = 0
        func walk(_ view: UIView) {
            if view is SelectableTextViewHostView, view.window != nil {
                let frame = view.convert(view.bounds, to: scrollView)
                if frame.maxY > top, frame.minY < bottom { hostsInView += 1 }
            }
            view.subviews.forEach(walk)
        }
        walk(scrollView)
        return String(
            format: "laidOut=%ld orders=%ld..%ld rowsInView=%ld [%@] top=%@ hostsInView=%ld ink=%.3f",
            laidOut.count, orders.min() ?? -1, orders.max() ?? -1, inView.count,
            inView.prefix(6).map { String(format: "%@@%.0f", String($0.0.suffix(14)), $0.1.minY) }.joined(separator: " "),
            engine.topVisibleMessageID ?? "nil", hostsInView, viewportInk(of: scrollView)
        )
    }

    /// The share of the viewport's middle (clear of the bars and the
    /// composer) that sits on a sharp edge, as text's strokes do and the
    /// backdrop's soft glows don't: near zero when the rows scrolled into
    /// view draw nothing. Negative when it can't be read.
    private static func viewportInk(of scrollView: UIScrollView) -> Double {
        guard let window = scrollView.window else { return -1 }
        let frame = scrollView.convert(scrollView.bounds, to: window).intersection(window.bounds)
        let rect = frame.insetBy(dx: 0, dy: frame.height * 0.2)
        guard rect.width >= 1, rect.height >= 1 else { return -2 }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            window.drawHierarchy(
                in: CGRect(origin: CGPoint(x: -rect.minX, y: -rect.minY), size: window.bounds.size),
                afterScreenUpdates: true
            )
        }
        // Read back as 8-bit RGB, whatever format the renderer picked.
        guard let cgImage = image.cgImage else { return -3 }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width > 1, height > 0 else { return -4 }
        var edges = 0
        for y in 0..<height {
            let row = y * width * 4
            for x in 1..<width {
                let left = row + (x - 1) * 4
                let pixel = left + 4
                if abs(Int(pixels[pixel]) - Int(pixels[left])) > 40
                    || abs(Int(pixels[pixel + 1]) - Int(pixels[left + 1])) > 40
                    || abs(Int(pixels[pixel + 2]) - Int(pixels[left + 2])) > 40 {
                    edges += 1
                }
            }
        }
        return Double(edges) / Double(width * height)
    }

    /// Where the mounted text views sit in content coordinates, to tell a
    /// scroll that mounted nothing from rows that were already there.
    private static func mountedSpan(in scrollView: UIScrollView) -> String {
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var count = 0
        var hosts: [String] = []
        func walk(_ view: UIView) {
            if let host = view as? SelectableTextViewHostView, view.window != nil {
                let frame = view.convert(view.bounds, to: scrollView)
                minY = min(minY, frame.minY)
                maxY = max(maxY, frame.maxY)
                count += 1
                hosts.append(String(
                    format: "%.0f+%.0f%@ %@",
                    frame.minY, frame.height, host.textView == nil ? "" : "(tv)",
                    String(host.displayedText.prefix(18)).replacingOccurrences(of: "\n", with: " ")
                ))
            }
            view.subviews.forEach(walk)
        }
        walk(scrollView)
        return String(
            format: "offset=%.0f visible=%.0f..%.0f textViews=%ld textViewSpan=%.0f..%.0f",
            scrollView.contentOffset.y, scrollView.contentOffset.y, scrollView.contentOffset.y + scrollView.bounds.height,
            count, count > 0 ? minY : 0, count > 0 ? maxY : 0
        ) + " hosts=[" + hosts.joined(separator: " | ") + "]"
    }

    /// Text views on screen, a stand-in for how many rows LazyVStack keeps.
    private static func mountedRowEstimate(in scrollView: UIView) -> Int {
        var count = 0
        func walk(_ view: UIView) {
            if view is SelectableTextViewHostView { count += 1 }
            view.subviews.forEach(walk)
        }
        walk(scrollView)
        return count
    }
}

/// The main run loop's awake time, stamped by an observer that runs after
/// every other one at each wake and sleep. Not actor-isolated: it runs twice
/// a frame, where an actor check would add to what it measures.
private final class ProbeAwakeTime: @unchecked Sendable {
    private var busy: CFTimeInterval = 0
    private var wokeAt = CACurrentMediaTime()
    private var awake = true

    /// Awake time so far, counting the stretch the loop is awake in now.
    var mark: CFTimeInterval {
        busy + (awake ? CACurrentMediaTime() - wokeAt : 0)
    }

    func observe(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity.rawValue == CFRunLoopActivity.afterWaiting.rawValue {
            wokeAt = now
            awake = true
        } else if awake {
            busy += now - wokeAt
            awake = false
        }
    }
}

/// Ticks the probe once per display frame, as a display link ticks the app.
@MainActor
private final class ProbeFrameClock: NSObject {
    private var finished = false
    /// Called once per display frame; returns false to stop.
    var tick: (() -> Bool)?

    /// Ticks until `tick` returns false (or two minutes pass).
    func run() {
        finished = false
        let link = CADisplayLink(target: self, selector: #selector(fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        let deadline = Date().addingTimeInterval(120)
        while !finished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        link.invalidate()
    }

    @objc private func fire(_ link: CADisplayLink) {
        if tick?() != true {
            finished = true
            link.invalidate()
        }
    }
}

/// Samples the main thread's stack from a thread of its own about once a
/// millisecond, each sample tagged with the frame the probe is in, so the
/// slowest frames can say where their time went (macOS `sample` at that
/// rate slowed frames to seconds). Memory is allocated up front: the main
/// thread is suspended while its stack is read, and an allocation then
/// could wait on a lock it holds.
private final class ProbeStackSampler: @unchecked Sendable {
    /// A tag is `phase * phaseStride + frame`.
    static let phaseStride = 100_000
    private static let maxDepth = 192
    private static let capacity = 30_000
    /// ARM_THREAD_STATE64_COUNT: x0-x28, fp, lr, sp, pc, cpsr and pad.
    private static let stateWords = 68

    private let target: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let state = UnsafeMutablePointer<natural_t>.allocate(capacity: ProbeStackSampler.stateWords)
    private let addresses = UnsafeMutablePointer<UInt>.allocate(capacity: ProbeStackSampler.capacity * ProbeStackSampler.maxDepth)
    private let depths = UnsafeMutablePointer<Int>.allocate(capacity: ProbeStackSampler.capacity)
    private let tags = UnsafeMutablePointer<Int>.allocate(capacity: ProbeStackSampler.capacity)
    /// 0: the current tag, 1: running, 2: samples taken, 3: the stack
    /// address a walk stops at.
    private let shared = UnsafeMutablePointer<Int>.allocate(capacity: 4)
    private let done = DispatchSemaphore(value: 0)

    /// Made on the main thread.
    init() {
        let main = pthread_main_thread_np()
        target = pthread_mach_thread_np(main)
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(main))
        shared[0] = -1
        shared[1] = 0
        shared[2] = 0
        shared[3] = 0
    }

    deinit {
        state.deallocate()
        addresses.deallocate()
        depths.deallocate()
        tags.deallocate()
        shared.deallocate()
    }

    /// The frame samples count toward; negative leaves them out.
    var tag: Int {
        get { shared[0] }
        set { shared[0] = newValue }
    }

    /// An address in the frame the probe's frame loop is called from: a
    /// walk stops there, so a sample holds only the loop's own frames.
    var stackLimit: UInt {
        get { UInt(bitPattern: shared[3]) }
        set { shared[3] = Int(bitPattern: newValue) }
    }

    func start() {
        shared[1] = 1
        let thread = Thread { [self] in
            while shared[1] != 0 {
                usleep(1000)
                let tag = shared[0]
                if tag >= 0, shared[2] < Self.capacity {
                    sample(tag: tag)
                }
            }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        shared[1] = 0
        done.wait()
    }

    private func sample(tag: Int) {
        #if arch(arm64)
        guard thread_suspend(target) == KERN_SUCCESS else { return }
        var count = mach_msg_type_number_t(Self.stateWords)
        if thread_get_state(target, thread_state_flavor_t(ARM_THREAD_STATE64), state, &count) == KERN_SUCCESS {
            let words = UnsafeRawPointer(state)
            let index = shared[2]
            let base = addresses + index * Self.maxDepth
            let linkRegister = UInt(words.loadUnaligned(fromByteOffset: 30 * 8, as: UInt64.self))
            base[0] = UInt(words.loadUnaligned(fromByteOffset: 32 * 8, as: UInt64.self))
            base[1] = linkRegister
            var depth = 2
            var framePointer = UInt(words.loadUnaligned(fromByteOffset: 29 * 8, as: UInt64.self))
            let limit = shared[3] == 0 ? stackHigh : min(stackHigh, UInt(bitPattern: shared[3]))
            while depth < Self.maxDepth, framePointer >= stackLow, framePointer + 16 <= limit,
                  framePointer & 7 == 0,
                  let record = UnsafePointer<UInt>(bitPattern: framePointer) {
                let returnAddress = record[1]
                if returnAddress == 0 { break }
                // A function that set up its frame saved the link register
                // there too: don't count its caller twice.
                if !(depth == 2 && returnAddress == linkRegister) {
                    base[depth] = returnAddress
                    depth += 1
                }
                let next = record[0]
                if next <= framePointer { break }
                framePointer = next
            }
            depths[index] = depth
            tags[index] = tag
            shared[2] = index + 1
        }
        thread_resume(target)
        #endif
    }

    private final class Node {
        var count = 0
        var children: [String: Node] = [:]
    }

    /// For each phase: what its frames' time went to, then its slowest
    /// frames one by one, as call trees.
    func printReport(phases: [(name: String, frames: [(index: Int, milliseconds: Double)], slowest: Int)]) {
        var names: [UInt: String] = [:]
        func name(_ address: UInt) -> String {
            if let known = names[address] { return known }
            var info = Dl_info()
            var result = String(format: "0x%lx", address)
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "" } ?? ""
                let symbol = info.dli_sname.map { Self.demangled(String(cString: $0)) } ?? "?"
                result = symbol + " [" + image.replacingOccurrences(of: ".dylib", with: "") + "]"
            }
            names[address] = result
            return result
        }
        // Each sample's frames outermost first, from the frame loop down;
        // samples where the run loop sleeps until its next event are idle.
        var stacks: [Int: [[String]]] = [:]
        var idle = 0
        for sample in 0..<shared[2] {
            let base = addresses + sample * Self.maxDepth
            var frames: [String] = []
            for depth in (0..<depths[sample]).reversed() {
                // Return addresses point past their call: look up the call.
                frames.append(name(depth == 0 ? base[depth] : base[depth] &- 1))
            }
            if frames.contains(where: { $0.hasPrefix("__CFRunLoopServiceMachPort") }) {
                idle += 1
                continue
            }
            if let loop = frames.lastIndex(where: { $0.contains("ProbeFrameClock.run") }) {
                frames.removeFirst(loop + 1)
            }
            stacks[tags[sample], default: []].append(frames)
        }
        print("SCROLL_PROBE stacks samples=\(shared[2]) idle=\(idle) names=\(names.count)")

        func printTree(_ samples: [[String]], title: String, cutoff: Double, maxLines: Int) {
            let root = Node()
            for frames in samples {
                root.count += 1
                var node = root
                for frame in frames {
                    let child = node.children[frame] ?? Node()
                    node.children[frame] = child
                    child.count += 1
                    node = child
                }
            }
            print("SCROLL_PROBE stacks " + title + " busySamples=\(root.count)")
            guard root.count > 0 else { return }
            var lines = 0
            func walk(_ node: Node, depth: Int) {
                for (frame, child) in node.children.sorted(by: { $0.value.count > $1.value.count }) {
                    guard Double(child.count) >= cutoff * Double(root.count), lines < maxLines else { continue }
                    var chain = [Self.short(frame)]
                    var current = child
                    while chain.count < 4,
                          let next = current.children.max(by: { $0.value.count < $1.value.count }),
                          Double(next.value.count) >= 0.9 * Double(current.count) {
                        chain.append(Self.short(next.key))
                        current = next.value
                    }
                    lines += 1
                    print("SCROLL_PROBE stacks " + String(repeating: ". ", count: depth)
                        + String(format: "%.0f%% ", 100 * Double(child.count) / Double(root.count))
                        + chain.joined(separator: " > "))
                    walk(current, depth: depth + 1)
                }
            }
            walk(root, depth: 0)
        }

        for (number, phase) in phases.enumerated() {
            let base = number * Self.phaseStride
            let all = phase.frames.flatMap { stacks[base + $0.index] ?? [] }
            printTree(all, title: "\(phase.name) all frames", cutoff: 0.03, maxLines: 26)
            for frame in phase.frames.sorted(by: { $0.milliseconds > $1.milliseconds }).prefix(phase.slowest) {
                printTree(
                    stacks[base + frame.index] ?? [],
                    title: String(format: "%@ frame=%ld %.1fms", phase.name, frame.index, frame.milliseconds),
                    cutoff: 0.07,
                    maxLines: 16
                )
            }
        }
    }

    private static func short(_ name: String) -> String {
        name.count <= 90 ? name : String(name.prefix(89)) + "…"
    }

    private static func demangled(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$S") else { return symbol }
        return symbol.withCString { pointer in
            guard let result = probeSwiftDemangle(pointer, UInt(strlen(pointer)), nil, nil, 0) else { return symbol }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

@_silgen_name("swift_demangle")
private func probeSwiftDemangle(
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?

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
