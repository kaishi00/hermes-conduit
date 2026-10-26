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

    func testV2SplitHiddenListKeepsOneColumn() {
        // #1164: the list hidden, a wide window keeps one column (the chat's
        // readable column scales on its own, #1320).
        for width: CGFloat in [806, 1032, 1376] {
            XCTAssertTrue(V2SplitLayout.isSplit(width: width, showsList: true), "\(width) pt splits with the list shown.")
            XCTAssertFalse(V2SplitLayout.isSplit(width: width, showsList: false), "\(width) pt keeps one column with the list hidden.")
        }
        // Showing the list never splits a narrow window.
        XCTAssertFalse(V2SplitLayout.isSplit(width: 805, showsList: true))
        XCTAssertTrue(V2ChatListPreference.defaultValue, "The list shows beside the chat unless the user hides it.")
    }

    func testV2SplitListLeavesVoiceToTheChatBesideIt() {
        let project = ProjectSummary(id: "p1", title: "Trips", isHome: false, sessionCount: 0, previewSessions: [])
        // A chat beside the list has its own voice button by the composer.
        XCTAssertTrue(V2SplitLayout.hasChatVoiceBeside(split: true, path: [.conversation], inRoom: false))
        XCTAssertTrue(V2SplitLayout.hasChatVoiceBeside(split: true, path: [.project(project), .conversation], inRoom: false))
        // No chat shown, a group room (no voice button), or one column
        // (the bar is down under a chat): the list keeps its voice.
        XCTAssertFalse(V2SplitLayout.hasChatVoiceBeside(split: true, path: [], inRoom: false))
        XCTAssertFalse(V2SplitLayout.hasChatVoiceBeside(split: true, path: [.project(project)], inRoom: false))
        XCTAssertFalse(V2SplitLayout.hasChatVoiceBeside(split: true, path: [.conversation], inRoom: true))
        XCTAssertFalse(V2SplitLayout.hasChatVoiceBeside(split: false, path: [.conversation], inRoom: false))
    }

    func testV2TabBarSitsUnderTheListColumnOnly() {
        XCTAssertTrue(V2SplitLayout.tabBarUnderList(split: true, tab: .chats))
        XCTAssertTrue(V2SplitLayout.tabBarUnderList(split: true, tab: .bots))
        // Settings opens beside the Chats list.
        XCTAssertTrue(V2SplitLayout.settingsBesideList(split: true))
        XCTAssertTrue(V2SplitLayout.tabBarUnderList(split: true, tab: .settings))
        // No list column: Tasks, or the list hidden (one column).
        XCTAssertFalse(V2SplitLayout.tabBarUnderList(split: true, tab: .tasks))
        XCTAssertFalse(V2SplitLayout.settingsBesideList(split: false))
        XCTAssertFalse(V2SplitLayout.tabBarUnderList(split: false, tab: .settings))
        XCTAssertFalse(V2SplitLayout.tabBarUnderList(split: false, tab: .chats))
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

    func testChatColumnWidensWithTheWindowUpToItsCap() {
        // A phone, and an iPad beside the list, keep the 760 pt column.
        for width: CGFloat in [375, 760, 1001, 1056] {
            XCTAssertEqual(ReadableWidth.chat(available: width), ReadableWidth.chat, "\(width) pt keeps 760 pt.")
        }
        // A wider window widens it with the window.
        XCTAssertEqual(ReadableWidth.chat(available: 1057), 761)
        XCTAssertEqual(ReadableWidth.chat(available: 1376), 990)
        XCTAssertGreaterThan(ReadableWidth.chat(available: 1300), ReadableWidth.chat(available: 1200))
        // A maximized window stops at the cap.
        for width: CGFloat in [1445, 1800, 3000] {
            XCTAssertEqual(ReadableWidth.chat(available: width), ReadableWidth.chatMax, "\(width) pt stops at the cap.")
        }
        XCTAssertEqual(ReadableWidth.margin(available: 1800, maxWidth: ReadableWidth.chat(available: 1800)), 380)
    }
}
