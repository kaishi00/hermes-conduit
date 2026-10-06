//
//  ConnectionTimelineTests.swift
//  ConduitTests
//
//  The Gateway Diagnostics launch timeline (#417). Extensions of existing
//  classes, so the CI planner gains no new class to schedule.
//

import XCTest
@testable import Conduit

extension ConnectionFailureTests {
    func testTimelineRecordsStepDurationsAndOffsets() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var timeline = ConnectionTimeline(trigger: "cold launch, password sign-in", startedAt: start)
        timeline.record("Connecting", at: start.addingTimeInterval(0.1))
        timeline.record(
            "Socket open",
            since: start.addingTimeInterval(0.1),
            at: start.addingTimeInterval(0.6)
        )

        XCTAssertEqual(timeline.events.map(\.label), ["Connecting", "Socket open (0.50 s)"])
        XCTAssertEqual(timeline.events.count, 2)
        XCTAssertEqual(timeline.events.first?.offset ?? -1, 0.1, accuracy: 0.001)
        XCTAssertEqual(timeline.events.last?.offset ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(
            timeline.report,
            """
            Conduit connection timeline: cold launch, password sign-in
            +0.10 s   Connecting
            +0.60 s   Socket open (0.50 s)
            """
        )
    }

    func testTimelineFailureNamesTheKindNeverTheServerText() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var timeline = ConnectionTimeline(trigger: "reconnect", startedAt: start)
        timeline.record(
            "Chat history",
            since: start,
            error: DashboardTicketBridgeError.http(status: 503, detail: "upstream secret.example.ts.net down"),
            at: start.addingTimeInterval(1.25)
        )
        timeline.record(
            "Socket open",
            since: start,
            error: HermesError.timeout("WebSocket connection"),
            at: start.addingTimeInterval(15)
        )

        XCTAssertEqual(timeline.events.map(\.label), [
            "Chat history failed after 1.25 s: HTTP 503",
            "Socket open failed after 15.00 s: timed out"
        ])
        XCTAssertFalse(timeline.report.contains("secret"), "Server text and hosts must never reach a pasteable report")
    }

    func testTimelineSummariesCoverBridgeAndGatewayErrors() {
        XCTAssertEqual(ConnectionTimeline.summary(of: DashboardTicketBridgeError.notReady), "dashboard page not ready")
        XCTAssertEqual(ConnectionTimeline.summary(of: DashboardTicketBridgeError.signInRequired), "sign-in required")
        XCTAssertEqual(ConnectionTimeline.summary(of: RpcError(code: 4007, message: "session not found")), "gateway error 4007")
        XCTAssertEqual(ConnectionTimeline.summary(of: URLError(.timedOut)), "network error \(URLError.Code.timedOut.rawValue)")
        XCTAssertEqual(ConnectionTimeline.summary(of: CancellationError()), "cancelled")
    }

    func testTimelineStopsRecordingAfterItsWindow() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var timeline = ConnectionTimeline(trigger: "back in the app", startedAt: start)
        timeline.record("Connection check", at: start.addingTimeInterval(1))
        timeline.record(
            "Chat list, 40 rows",
            at: start.addingTimeInterval(ConnectionTimeline.recordingWindow + 1)
        )

        XCTAssertEqual(timeline.events.map(\.label), ["Connection check"])
        XCTAssertEqual(timeline.droppedEvents, 1)
        XCTAssertTrue(timeline.report.hasSuffix("(1 later steps not recorded)"))
        XCTAssertFalse(timeline.isRecording(at: start.addingTimeInterval(ConnectionTimeline.recordingWindow + 1)))
    }

    func testTimelineCapsItsEvents() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var timeline = ConnectionTimeline(trigger: "reconnect", startedAt: start)
        for index in 0..<(ConnectionTimeline.maximumEvents + 5) {
            timeline.record("Step \(index)", at: start.addingTimeInterval(Double(index) / 100))
        }

        XCTAssertEqual(timeline.events.count, ConnectionTimeline.maximumEvents)
        XCTAssertEqual(timeline.droppedEvents, 5)
    }
}

extension DashboardTicketBridgeTests {
    func testBridgeReportsAnEndedPageProcessToTheTimeline() {
        let bridge = DashboardTicketBridge(baseURL: "https://example.com")
        var events: [String] = []
        bridge.onPageEvent = { events.append($0) }

        bridge.webViewWebContentProcessDidTerminate(bridge.webView)

        XCTAssertEqual(events, ["Dashboard page process ended"])
        bridge.invalidate()
    }
}
