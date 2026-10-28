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

    func testV2ListColumnKeepsLiveRowsBesideTheChat() {
        // #1353: the list, or a project's page, beside a chat still shows
        // its rows, so their Running keeps following the live registry.
        let project = ProjectSummary(id: "p1", title: "Trips", isHome: false, sessionCount: 0, previewSessions: [])
        XCTAssertTrue(V2SplitLayout.showsChatRows(split: true, path: [.conversation]))
        XCTAssertTrue(V2SplitLayout.showsChatRows(split: true, path: [.project(project), .conversation]))
        XCTAssertTrue(V2SplitLayout.showsChatRows(split: false, path: [.project(project)]))
        XCTAssertTrue(V2SplitLayout.showsChatRows(split: false, path: []))
        // One column, a chat covers the list; Artifacts shows no chat rows.
        XCTAssertFalse(V2SplitLayout.showsChatRows(split: false, path: [.conversation]))
        XCTAssertFalse(V2SplitLayout.showsChatRows(split: false, path: [.project(project), .conversation]))
        XCTAssertFalse(V2SplitLayout.showsChatRows(split: true, path: [.artifacts, .conversation]))
    }

    func testV2SplitListMarksWhatShowsBesideIt() {
        // #1363: the chat beside the list, or a group room in its place
        // (the open chat stays set under a room, so its row isn't marked).
        XCTAssertEqual(V2SplitLayout.openBeside(chatBeside: true, roomID: nil), .chat)
        XCTAssertEqual(V2SplitLayout.openBeside(chatBeside: true, roomID: "r1"), .room("r1"))
        // The placeholder, or Settings in the chat's column.
        XCTAssertEqual(V2SplitLayout.openBeside(chatBeside: false, roomID: nil), .nothing)
        XCTAssertEqual(V2SplitLayout.openBeside(chatBeside: false, roomID: "r1"), .nothing)

        // Beside the list, only the open chat's row is highlighted.
        XCTAssertEqual(V2RowSelection.chat(isActive: true, beside: .chat), .open)
        XCTAssertEqual(V2RowSelection.chat(isActive: false, beside: .chat), .none)
        XCTAssertEqual(V2RowSelection.chat(isActive: true, beside: .room("r1")), .none)
        XCTAssertEqual(V2RowSelection.chat(isActive: true, beside: .nothing), .none)
        XCTAssertEqual(V2RowSelection.room("r1", beside: .room("r1")), .open)
        XCTAssertEqual(V2RowSelection.room("r2", beside: .room("r1")), .none)
        XCTAssertEqual(V2RowSelection.room("r1", beside: .chat), .none)
        // One column (a phone, or the list hidden) keeps the faint shade
        // Chats rows always had, and a bot's row keeps none.
        XCTAssertEqual(V2RowSelection.chat(isActive: true, beside: nil), .faint)
        XCTAssertEqual(V2RowSelection.chat(isActive: false, beside: nil), .none)
        XCTAssertEqual(V2RowSelection.chat(isActive: true, beside: nil, faintAlone: false), .none)
        XCTAssertEqual(V2RowSelection.chat(isActive: true, beside: .chat, faintAlone: false), .open)
        XCTAssertEqual(V2RowSelection.room("r1", beside: nil), .none)
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

    func testChatTextStepsUpWithTheColumn() {
        // A phone, and an iPad beside the list, keep the system's size.
        for width: CGFloat in [375, 1001, 1056, 1180] {
            XCTAssertEqual(ReadableWidth.chatTextSteps(column: ReadableWidth.chat(available: width)), 0, "\(width) pt keeps the size.")
        }
        // Each step once the column holds as many words a line at it.
        XCTAssertEqual(ReadableWidth.chatTextSteps(column: 850), 1)
        XCTAssertEqual(ReadableWidth.chatTextSteps(column: 938), 1)
        XCTAssertEqual(ReadableWidth.chatTextSteps(column: 939), 2)
        // An iPad's whole window with the list hidden, and a maximized Mac.
        XCTAssertEqual(ReadableWidth.chatTextSteps(column: ReadableWidth.chat(available: 1376)), 2)
        XCTAssertEqual(ReadableWidth.chatTextSteps(column: ReadableWidth.chat(available: 1800)), 3)
    }

    func testWideColumnStepsResolveTranscriptFontsAtTheLargerSize() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let stepped = ChatTextAppearance(size: .default).widened(steps: 2, category: .extraExtraLarge)
        let expected = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraLarge))
        XCTAssertEqual(ChatTypography.font(for: .body, appearance: stepped, compatibleWith: traits).pointSize, expected.pointSize, accuracy: 0.001)
        // A view whose environment the column already stepped up isn't
        // stepped twice.
        XCTAssertEqual(
            ChatTypography.font(for: .body, appearance: stepped, environmentCategory: .extraExtraLarge).pointSize,
            expected.pointSize,
            accuracy: 0.001
        )
        // The user's chat text size still multiplies.
        let larger = ChatTextAppearance(size: .larger).widened(steps: 2, category: .extraExtraLarge)
        XCTAssertEqual(
            ChatTypography.font(for: .body, appearance: larger, compatibleWith: traits).pointSize,
            expected.pointSize * ChatTextSize.larger.scale,
            accuracy: 0.001
        )
        // The column and its transcript step through the same sizes.
        XCTAssertEqual(ChatTypography.standardDynamicTypeSizes, ChatTypography.standardCategories.map { DynamicTypeSize($0) })
        // Steps stop at the largest standard size; accessibility sizes stay.
        XCTAssertEqual(ChatTypography.boosted(.extraExtraLarge, by: 3), .extraExtraExtraLarge)
        XCTAssertEqual(ChatTypography.boosted(.accessibilityMedium, by: 2), .accessibilityMedium)
        // Caches tell the steps apart; no steps keeps today's keys.
        XCTAssertEqual(ChatTextAppearance(size: .default).cacheIdentity, ChatTextSize.default.cacheIdentity)
        XCTAssertNotEqual(stepped.cacheIdentity, ChatTextAppearance(size: .default).cacheIdentity)
        XCTAssertEqual(ChatTypography.widthRatio(stepped), expected.pointSize / UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize, accuracy: 0.001)
        XCTAssertEqual(ChatTypography.widthRatio(ChatTextAppearance(size: .default)), 1)
        // Without given traits, transcript fonts resolve at the column's size.
        XCTAssertEqual(ChatTypography.font(for: .body, appearance: stepped).pointSize, expected.pointSize, accuracy: 0.001)
    }

    /// Profiles tapped while a switch runs: the last tap goes once it ends,
    /// and a tap on where it landed (or no tap) starts nothing.
    func testV2ProfileTappedDuringASwitchGoesOnceItEnds() {
        var pick = V2QueuedProfilePick()
        XCTAssertNil(pick.take(landedOn: "work"), "No tap, no further switch.")

        pick.tap("home")
        pick.tap("lab")
        XCTAssertEqual(pick.take(landedOn: "work"), "lab", "The last tap wins.")
        XCTAssertNil(pick.take(landedOn: "lab"), "Taken once.")

        pick.tap("work")
        XCTAssertNil(pick.take(landedOn: "work"), "A tap on where the switch lands starts nothing.")
    }
}
