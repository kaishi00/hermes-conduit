//
//  ReplySpeedsTests.swift
//  ConduitTests
//
//  Show reply speed: the plugin's `GET /sessions/reply-speeds` answer, and
//  which reply's row shows which speed.
//

import XCTest
@testable import Conduit

final class ReplySpeedsTests: XCTestCase {
    func testSavedRepliesGoByRowAndTheNewestUnsavedTurnStandsApart() {
        let speeds = ReplySpeeds(chatID: "chat", response: ["replies": [
            ["row_id": 12, "tokens_per_s": 48.6] as [String: Any],
            ["row_id": NSNull(), "tokens_per_s": 9.0] as [String: Any],  // an older turn whose reply never saved
            ["row_id": true, "tokens_per_s": 30.0] as [String: Any],     // a Bool is no row id
            ["row_id": 20, "tokens_per_s": -1] as [String: Any],         // nor a speed below zero
            ["row_id": NSNull(), "tokens_per_s": 61.2] as [String: Any],
        ]])
        XCTAssertEqual(speeds.byRow, [12: 48.6])
        XCTAssertEqual(speeds.unsaved, 61.2)
    }

    func testTheRowShowsItsOwnSpeedAndOnlyTheNewestStreamedReplyTakesTheUnsavedOne() {
        var state = ChatRowState()
        state.replySpeeds = [7: 42]
        state.unsavedReplySpeed = 55
        state.latestAssistantMessageID = "live"
        let saved = ChatMessage(id: "7", role: .assistant, content: "Saved", timestamp: "t1", rowId: 7)
        let live = ChatMessage(id: "live", role: .assistant, content: "Streamed", timestamp: "t2")
        let older = ChatMessage(id: "old", role: .assistant, content: "Older", timestamp: "t0")
        let unmeasured = ChatMessage(id: "9", role: .assistant, content: "Before the plugin", timestamp: "t3", rowId: 9)
        XCTAssertEqual(state.replySpeed(for: saved), 42)
        XCTAssertEqual(state.replySpeed(for: live), 55)
        XCTAssertNil(state.replySpeed(for: older))
        XCTAssertNil(state.replySpeed(for: unmeasured))
        state.isBusy = true
        XCTAssertNil(state.replySpeed(for: live), "a turn still running hasn't been measured")
    }

    func testTheLabelKeepsADecimalOnlyUnderTen() {
        XCTAssertEqual(ReplySpeeds.number(41.6), 42.0.formatted(.number.precision(.fractionLength(0))))
        XCTAssertEqual(ReplySpeeds.number(4.46), 4.5.formatted(.number.precision(.fractionLength(1))))
    }

    func testTheRouteNamesTheChat() {
        XCTAssertEqual(ReplySpeeds.route(sessionID: "20261127_abc"), "/api/plugins/conduit_push/sessions/reply-speeds?session_id=20261127_abc")
    }
}
