//
//  ChatViewFollowCorrectionTests.swift
//  Conduit
//
//  Hosted-ChatView regression for the scene-update watchdog crash
//  (0x8BADF00D, main thread inside ScrollViewCommitMutation under
//  GraphHost.flushTransactions): rich content whose intrinsic height
//  settles repeatedly used to drive
//
//      geometry preference change
//          → layoutMetricsChanged (one per preference callback)
//          → synchronous scrollTo(bottom) inside the layout pass
//          → ScrollViewCommitMutation → more geometry changes → scrollTo …
//
//  The pure ChatViewportControllerTests cover the coalescing state machine;
//  these tests host the REAL ChatView (real ScrollViewReader, real scrollTo,
//  real preference pipeline) and assert the integrated behavior with BOTH
//  bounds: growth while following produces a POSITIVE, bounded number of
//  corrections/scrolls (a broken zero-correction implementation must fail),
//  and settled layout churn produces exactly zero.
//

import SwiftUI
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class ChatViewFollowCorrectionTests: XCTestCase {
    private var testWindow: UIWindow?

    override func tearDown() {
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        RunLoop.current.run(until: Date())
        testWindow = nil
        ChatViewportTrace.shared.reset()
        super.tearDown()
    }

    // MARK: Harness

    private func makeAppState() throws -> AppState {
        let suiteName = "chat-follow-correction-fixture"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "test UserDefaults suite must initialize"
        )
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    private func mountChat(appState: AppState) -> UIHostingController<AnyView> {
        let host = UIHostingController(
            rootView: AnyView(ChatView().environmentObject(appState))
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        testWindow = window
        pump(host)
        return host
    }

    /// Forces a layout pass and lets scheduled MainActor work (the coalesced
    /// follow corrections) run, exactly like a live turn of the run loop.
    private func pump(_ host: UIHostingController<AnyView>, _ times: Int = 1) {
        for _ in 0..<times {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func traceCount(where matches: (String) -> Bool) -> Int {
        ChatViewportTrace.shared.entries.map(\.text).filter(matches).count
    }

    /// Bottom scrolls executed by the coalesced correction path (the
    /// transcript reassert and retries log animated=true).
    private var nonAnimatedBottomScrolls: Int {
        traceCount { $0.hasPrefix("scroll bottom(") && $0.contains("animated=false") }
    }

    /// ALL bottom scroll executions, any animation flag — the honest
    /// "did following actually happen" signal for settled-transcript
    /// growth, where the animated transcript reassert owns the first
    /// scroll and the correction may legitimately defer to it.
    private var allBottomScrolls: Int {
        traceCount { $0.hasPrefix("scroll bottom(") }
    }

    private var followCorrectionsDue: Int {
        traceCount { $0.hasPrefix("follow correction due") }
    }

    /// Proves the trace instrumentation is live before any counter is used
    /// as evidence: the transcript reassert after a settled-content change
    /// must have logged a scroll line.
    private func assertTraceInstrumentationActive() {
        XCTAssertGreaterThan(
            allBottomScrolls, 0,
            "trace instrumentation must record the mount-time follow; counters are meaningless otherwise"
        )
    }

    private func tallMessage(id: String, tables: Int) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            content: (0..<tables).map { table in
                "Intro paragraph for table \(table).\n\n"
                    + MarkdownShowcaseFixtures.alignedTable(section: table, rows: 14, columns: 4)
            }.joined(separator: "\n\n"),
            timestamp: "2026-01-01T00:00:00Z"
        )
    }

    /// Pumps until the layout has genuinely settled - no follow
    /// corrections for several consecutive turns - within a bounded budget.
    /// Rich content mounts progressively over multiple turns; corrections
    /// during that window are legitimate following, not churn. The initial
    /// real-time settle expires any armed animated retry (150 ms) and the
    /// follow-correction re-arm interval (100 ms) so their landings are not
    /// mistaken for churn.
    private func drainUntilSettled(_ host: UIHostingController<AnyView>, maxPumps: Int = 40) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        var quietTurns = 0
        for _ in 0..<maxPumps {
            ChatViewportTrace.shared.reset()
            pump(host, 1)
            if followCorrectionsDue == 0 {
                quietTurns += 1
                if quietTurns >= 4 { return }
            } else {
                quietTurns = 0
            }
        }
    }

    // MARK: Tests

    /// One content-growth event (a settled response doubling in height)
    /// generates many geometry preference callbacks. The integrated
    /// invariants, BOTH directions:
    ///   - following HAPPENED: at least one bottom scroll executed;
    ///   - coalescing HELD: a bounded handful of corrections, never a
    ///     per-geometry-callback storm;
    ///   - settled layout churn afterwards: exactly zero corrections and
    ///     zero scrolls.
    func testOneGrowthEventProducesBoundedPositiveFollowCorrections() throws {
        let appState = try makeAppState()
        appState.messages = [tallMessage(id: "m1", tables: 6)]
        let host = mountChat(appState: appState)
        pump(host, 2)

        // ONE growth event.
        var messages = appState.messages
        messages[0] = tallMessage(id: "m1", tables: 12)
        appState.messages = messages
        pump(host, 3)

        // Instrumentation sanity: the growth's transcript reassert must be
        // visible in the trace, proving the counters below are live.
        assertTraceInstrumentationActive()

        // Positive bound: following actually happened for the growth.
        XCTAssertGreaterThan(
            allBottomScrolls, 0,
            "content growth while following must execute at least one bottom scroll"
        )

        // Coalescing bound: corrections track DISTINCT content bottoms
        // (growth settlements), never geometry callbacks.
        XCTAssertLessThanOrEqual(
            followCorrectionsDue, 4,
            "one growth event must not schedule an unbounded series of corrections"
        )
        XCTAssertLessThanOrEqual(
            nonAnimatedBottomScrolls, 4,
            "one growth event must not produce a scrollTo storm"
        )

        // Let the growth fully settle (progressive rich-block mounting,
        // armed animated retry expiry) BEFORE measuring churn.
        drainUntilSettled(host)

        // Settled layout churn (relayout without content change): the
        // feedback loop must be dead — EXACTLY zero, not "few".
        ChatViewportTrace.shared.reset()
        pump(host, 5)
        XCTAssertEqual(
            followCorrectionsDue, 0,
            "settled layout churn schedules no corrections"
        )
        XCTAssertEqual(
            nonAnimatedBottomScrolls, 0,
            "settled layout churn scrolls nowhere"
        )
        XCTAssertEqual(
            allBottomScrolls, 0,
            "settled layout churn produces no scrolls of any kind"
        )
    }

    /// Repeated STREAMING growth exercises the pure coalesced-correction
    /// path (no transcript change, so no animated reassert owns the
    /// follow). StreamingText reveals characters at a paced rate (~18 per
    /// 30 Hz tick), so each cycle gives the reveal real wall time; the
    /// assertions then cover BOTH directions over the whole window:
    /// following HAPPENED (positive counts) and stayed PROPORTIONAL TO
    /// CONTENT GROWTH — a couple of corrections per growth cycle, never
    /// the per-geometry-callback storm the watchdog crashed on.
    func testStreamingGrowthProducesPositiveCoalescedCorrections() throws {
        let appState = try makeAppState()
        appState.messages = [tallMessage(id: "m1", tables: 4)]
        appState.streamingText = "Streaming begins."
        let host = mountChat(appState: appState)
        pump(host, 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        drainUntilSettled(host)
        ChatViewportTrace.shared.reset()

        let windowStart = CFAbsoluteTimeGetCurrent()
        for tick in 1...8 {
            appState.streamingText += "\n\nDelta \(tick): "
                + MarkdownShowcaseFixtures.alignedTable(section: tick, rows: 8, columns: 3)
            // Real time for the paced reveal to advance the bubble height
            // past the regrowth tolerance, exactly like live streaming.
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            pump(host, 1)
        }
        let windowDuration = CFAbsoluteTimeGetCurrent() - windowStart

        // Positive bound: streaming growth IS followed through the
        // coalesced-correction path — a zero-correction implementation
        // (broken scheduling, broken onChange drain) fails here.
        XCTAssertGreaterThan(
            followCorrectionsDue, 0,
            "streaming growth must produce follow corrections"
        )
        XCTAssertGreaterThan(
            nonAnimatedBottomScrolls, 0,
            "the streaming follow must execute at least one bottom scroll"
        )
        // Coalescing bound, principled: the reveal grows the content
        // CONTINUOUSLY for the whole window, so the correction rate is
        // capped by the re-arm interval (~10/s) — an order of magnitude
        // under the per-geometry-callback storm the watchdog crashed on
        // (hundreds per second inside a single layout pass).
        let rateBudget = Int(windowDuration / 0.09) + 4
        XCTAssertLessThanOrEqual(
            followCorrectionsDue, rateBudget,
            "corrections must be rate-bounded by the re-arm interval, not callbacks"
        )
        XCTAssertLessThanOrEqual(
            nonAnimatedBottomScrolls, rateBudget,
            "scrolls must be rate-bounded by the re-arm interval, not callbacks"
        )

        // And once the stream settles: exactly zero churn.
        drainUntilSettled(host)
        ChatViewportTrace.shared.reset()
        pump(host, 5)
        XCTAssertEqual(followCorrectionsDue, 0, "settled stream schedules no corrections")
        XCTAssertEqual(allBottomScrolls, 0, "settled stream scrolls nowhere")
    }
}
