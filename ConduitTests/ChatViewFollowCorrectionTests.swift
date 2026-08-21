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
//  real preference pipeline) and assert the integrated bound: one
//  content-growth event yields at most a couple of coalesced corrections —
//  never one scrollTo per geometry callback — and settled layout churn
//  yields none.
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

    private var followCorrectionsDue: Int {
        traceCount { $0.hasPrefix("follow correction due") }
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

    // MARK: Tests

    /// One content-growth event (a settled response doubling in height)
    /// generates many geometry preference callbacks; the integrated bound
    /// is a couple of coalesced corrections, never a scrollTo series.
    func testOneGrowthEventProducesBoundedFollowCorrections() throws {
        let appState = try makeAppState()
        appState.messages = [tallMessage(id: "m1", tables: 6)]
        let host = mountChat(appState: appState)
        pump(host, 2)
        ChatViewportTrace.shared.reset()

        // ONE growth event.
        var messages = appState.messages
        messages[0] = tallMessage(id: "m1", tables: 12)
        appState.messages = messages
        pump(host, 3)

        // The coalescing invariant: corrections track DISTINCT content
        // bottoms (growth settlements), never geometry callbacks — a
        // bounded handful for one growth event, not a per-callback storm.
        XCTAssertLessThanOrEqual(
            followCorrectionsDue, 4,
            "one growth event must not schedule an unbounded series of corrections"
        )
        XCTAssertLessThanOrEqual(
            nonAnimatedBottomScrolls, 4,
            "one growth event must not produce a scrollTo storm"
        )

        // Settled layout churn (relayout without content change): the
        // feedback loop must be dead — no corrections, no bottom scrolls.
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
    }

    /// Repeated streaming growth: every cycle is followed (the tail stays
    /// pinned) while the correction count stays proportional to growth
    /// events, never to geometry callbacks.
    func testStreamingGrowthStaysCoalescedPerCycle() throws {
        let appState = try makeAppState()
        appState.messages = [tallMessage(id: "m1", tables: 4)]
        appState.streamingText = "Streaming begins."
        let host = mountChat(appState: appState)
        pump(host, 2)
        ChatViewportTrace.shared.reset()

        for tick in 1...8 {
            ChatViewportTrace.shared.reset()
            appState.streamingText += "\n\nDelta \(tick): "
                + MarkdownShowcaseFixtures.alignedTable(section: tick, rows: 8, columns: 3)
            pump(host, 2)
            XCTAssertLessThanOrEqual(
                followCorrectionsDue, 2,
                "cycle \(tick): at most one outstanding correction cycle per growth event"
            )
        }
        XCTAssertLessThanOrEqual(
            nonAnimatedBottomScrolls, 2,
            "the final cycle stays bounded"
        )
    }
}
