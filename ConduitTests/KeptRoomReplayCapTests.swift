//
//  KeptRoomReplayCapTests.swift
//  Conduit
//
//  Every room opened in a run kept its whole event window (up to 400
//  events) in memory until it left the room list (issue 1969). The kept
//  replays are now capped like Bot Chats' kept copies, never dropping a
//  room whose send is still parked.
//

import XCTest
@testable import Conduit

@MainActor
final class KeptRoomReplayCapTests: XCTestCase {
    func testNothingGoesUpToTheCap() {
        let order = (0..<AppState.maxKeptRoomReplays).map { "room\($0)" }
        XCTAssertEqual(AppState.keptRoomReplaysToDrop(order: order, pinned: []), [])
    }

    func testTheRoomLeftLongestAgoGoesPastTheCap() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(AppState.keptRoomReplaysToDrop(order: order, pinned: [], limit: 2), ["a", "b"])
    }

    func testARoomWithAParkedSendStays() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(AppState.keptRoomReplaysToDrop(order: order, pinned: ["a"], limit: 2), ["b", "c"])
        // Only the room just left is unpinned: it is the one that goes.
        XCTAssertEqual(AppState.keptRoomReplaysToDrop(order: order, pinned: ["a", "b", "c"], limit: 2), ["d"])
    }
}
