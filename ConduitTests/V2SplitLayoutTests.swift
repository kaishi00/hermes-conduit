//
//  V2SplitLayoutTests.swift
//  Conduit
//
//  V2's wide-window layout: when Chats and Bots split into a list and the
//  open chat, how the list's stack maps onto the tab's path, and the
//  readable-width margins. In an extension of SidebarLayoutTests, so the
//  test planner sees no new class.
//

import SwiftUI
import XCTest
@testable import Conduit

extension SidebarLayoutTests {
    func testV2SplitFollowsWindowWidthNotDevice() {
        // iPhone, an unfolded iPhone Duo (about 669 pt), iPad mini portrait.
        for width: CGFloat in [375, 440, 669, 744, 805] {
            XCTAssertFalse(V2SplitLayout.isSplit(width: width), "\(width) pt keeps one column.")
        }
        // The threshold itself, iPad Air and Pro portrait, landscape.
        for width: CGFloat in [806, 820, 834, 1032, 1180, 1376] {
            XCTAssertTrue(V2SplitLayout.isSplit(width: width), "\(width) pt splits.")
        }
    }

    func testV2SplitListStackLeavesOutTheConversation() {
        let project = ProjectSummary(id: "p1", title: "Trips", isHome: false, sessionCount: 0, previewSessions: [])
        XCTAssertEqual(V2SplitLayout.listRoutes([.conversation]), [])
        XCTAssertEqual(V2SplitLayout.listRoutes([.project(project), .conversation]), [.project(project)])
        XCTAssertEqual(V2SplitLayout.listRoutes([.artifacts]), [.artifacts])
    }

    func testV2SplitListPushKeepsTheConversationLast() {
        let project = ProjectSummary(id: "p1", title: "Trips", isHome: false, sessionCount: 0, previewSessions: [])
        // A page pushed in the list column while a chat is open.
        XCTAssertEqual(
            V2SplitLayout.tabRoutes(listing: [.project(project)], keepsConversation: true),
            [.project(project), .conversation]
        )
        // Popped back to the list: the chat stays open beside it.
        XCTAssertEqual(V2SplitLayout.tabRoutes(listing: [], keepsConversation: true), [.conversation])
        // No chat open: the list's pages only.
        XCTAssertEqual(V2SplitLayout.tabRoutes(listing: [.artifacts], keepsConversation: false), [.artifacts])
    }

    func testReadableWidthMarginCentersAndNeverGoesNegative() {
        XCTAssertEqual(ReadableWidth.margin(available: 400, maxWidth: ReadableWidth.chat), 0)
        XCTAssertEqual(ReadableWidth.margin(available: 760, maxWidth: 760), 0)
        XCTAssertEqual(ReadableWidth.margin(available: 1000, maxWidth: 760), 120)
        XCTAssertEqual(ReadableWidth.margin(available: 1001, maxWidth: 760), 120)
    }
}
