import Combine
import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// PROBE ONLY (removed before merge): what an AppState publish costs an
/// open chat while the V2 Chats list sits under it, with a default
/// profile's catalog (600 chats, 2,000 cron runs). Prints PUBLISH_PROBE
/// lines; asserts only that the harness ran.
extension TranscriptPerformanceFixtureTests {
    func testPublishProbeReportsCoveredListCost() throws {
        let environment = ProcessInfo.processInfo.environment
        let config = environment["PROBE_CONFIG"] ?? "gated"
        let suiteName = "publish-probe"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let now = Date().timeIntervalSince1970
        func row(_ id: String, _ source: SessionSource, _ index: Int) -> SessionSummary {
            SessionSummary(
                id: id,
                alternateIds: [],
                title: "\(source.rawValue) \(index)",
                model: "Hermes",
                updatedLabel: "now",
                lastActivityAt: now - Double(index) * 1800,
                profile: "default",
                source: source,
                isActive: false,
                isArchived: false,
                lineageRootId: nil
            )
        }
        appState.sessions = (0..<600).map { row("chat-\($0)", $0 % 7 == 0 ? .voice : .chat, $0) }
        appState.cronSessions = (0..<2000).map { row("cron-\($0)", .cron, $0) }
        appState.messages = Self.markdownTranscript(count: 120)
        appState.activeSessionId = "chat-0"
        appState.showSidebar = false
        print("PUBLISH_PROBE setup config=\(config) chats=\(appState.sessions.count) runs=\(appState.cronSessions.count)")

        let host = UIHostingController(rootView: DormancyHarnessEnvironment.applying(
            PublishProbeCoveredChat(appState: appState, showsList: config != "nolist")
                .environmentObject(appState)
        ))
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
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
        XCTAssertTrue(PerformanceFixtureWait.eventually(pumpingLayoutOf: host.view) {
            locator = Self.publishProbeFind(ChatScrollSurfaceLocatorView.self, in: host.view)
            return locator?.surface?.scrollView != nil
        }, "the locator must find the transcript's UIScrollView")
        let scrollView = try XCTUnwrap(locator?.surface?.scrollView)
        let engine = try XCTUnwrap(locator?.engine)
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let awake = PublishProbeAwakeTime()
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            CFIndex.max
        ) { _, activity in awake.observe(activity) }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        /// Each frame's awake time, publishing every `every` frames.
        func frames(_ count: Int, delta: CGFloat, every: Int) -> (publish: [Double], other: [Double]) {
            var publish: [Double] = [], other: [Double] = []
            var index = 0
            var before = awake.mark
            var published = false
            let clock = PublishProbeClock()
            clock.tick = {
                let mark = awake.mark
                if index > 0 {
                    let ms = (mark - before) * 1000
                    if published { publish.append(ms) } else { other.append(ms) }
                }
                guard index < count else { return false }
                before = awake.mark
                published = index % every == every - 1
                if published { appState.objectWillChange.send() }
                if delta != 0 { scrollView.contentOffset.y += delta }
                index += 1
                return true
            }
            clock.run()
            return (publish, other)
        }

        func report(_ phase: String, _ result: (publish: [Double], other: [Double])) {
            func line(_ name: String, _ values: [Double]) -> String {
                let sorted = values.sorted()
                func pct(_ f: Double) -> Double {
                    sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * f).rounded()))]
                }
                return String(
                    format: "%@ n=%ld median=%.2fms p90=%.2fms max=%.2fms over8=%ld over16=%ld",
                    name, sorted.count, pct(0.5), pct(0.9), sorted.last ?? 0,
                    sorted.filter { $0 > 8.3 }.count, sorted.filter { $0 > 16.7 }.count
                )
            }
            print("PUBLISH_PROBE \(config) \(phase) " + line("publishFrames", result.publish))
            print("PUBLISH_PROBE \(config) \(phase) " + line("otherFrames", result.other))
        }

        // Warm up once, then still and scrolling, a publish every 12 frames
        // (5 a second at 60 Hz).
        _ = frames(60, delta: 0, every: 6)
        report("still", frames(360, delta: 0, every: 12))
        engine.userDragBegan()
        report("scroll-up", frames(240, delta: -12, every: 12))
        report("scroll-down", frames(240, delta: 12, every: 12))
        engine.userDragEnded()
        XCTAssertGreaterThan(scrollView.contentSize.height, 0)
    }

    private static func publishProbeFind<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = publishProbeFind(type, in: subview) { return match }
        }
        return nil
    }
}

/// The V2 Chats list with a chat pushed over it, as the shell has it.
private struct PublishProbeCoveredChat: View {
    let appState: AppState
    let showsList: Bool
    @State private var path = [1]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if showsList {
                    V2ChatsView(appState: appState).equatable()
                } else {
                    Color.clear
                }
            }
            .transformEnvironment(\.v2Shell) { $0.isRootCovered = !path.isEmpty }
            .navigationDestination(for: Int.self) { _ in
                ZStack {
                    ConduitBackdrop(drifts: true)
                    ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize)
                }
            }
        }
    }
}

private final class PublishProbeAwakeTime: @unchecked Sendable {
    private var busy: CFTimeInterval = 0
    private var wokeAt = CACurrentMediaTime()
    private var awake = true

    var mark: CFTimeInterval { busy + (awake ? CACurrentMediaTime() - wokeAt : 0) }

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

@MainActor
private final class PublishProbeClock: NSObject {
    private var finished = false
    var tick: (() -> Bool)?

    func run() {
        finished = false
        let link = CADisplayLink(target: self, selector: #selector(fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        let deadline = Date().addingTimeInterval(60)
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
