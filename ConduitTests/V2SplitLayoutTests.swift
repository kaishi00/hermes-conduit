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

    func testDraggedColumnWidthsKeepToTheirBoundsAndTheWindow() {
        // #1487: the list's column shows the user's width on a window with
        // room for it and the chat's least width beside it.
        let list = V2SplitLayout.listWidths
        XCTAssertEqual(V2SplitLayout.ListColumn(window: 1440, stored: 500).width, 500)
        // A smaller window gives the list what's left beside the chat.
        XCTAssertEqual(V2SplitLayout.ListColumn(window: 900, stored: 500).width, 900 - V2SplitLayout.minimumChatWidth - 1)
        // Never below the standard width the tab bar needs, nor past its
        // most, nor anything but the standard width for an unreadable value.
        XCTAssertEqual(V2SplitLayout.ListColumn(window: 806, stored: 500).width, V2SplitLayout.listWidth)
        XCTAssertEqual(V2SplitLayout.ListColumn(window: 1440, stored: 100).width, V2SplitLayout.listWidth)
        XCTAssertEqual(V2SplitLayout.ListColumn(window: 2560, stored: 5000).width, list.maximum)
        XCTAssertEqual(list.resolved(.nan, window: 1440, keeping: V2SplitLayout.minimumChatWidth), list.standard)
        // A widened list never takes the split away: the window splits at
        // the standard width whatever the user's.
        XCTAssertTrue(V2SplitLayout.isSplit(width: 806))

        // A drag adds the pointer's travel to where it began, within the
        // bounds and the room the window has now.
        XCTAssertEqual(list.dragged(from: 375, by: 60, room: 1000), 435)
        XCTAssertEqual(list.dragged(from: 375, by: -60, room: 1000), list.minimum)
        XCTAssertEqual(list.dragged(from: 375, by: 400, room: 1000), list.maximum)
        XCTAssertEqual(list.dragged(from: 375, by: 100, room: 420), 420)
        XCTAssertEqual(list.dragged(from: 375, by: 100, room: 200), list.minimum)

        // Artifacts beside the chat shows at its standard width's window,
        // as before, and can then be dragged narrower or wider.
        let panel = ChatSidePanel.widths
        XCTAssertFalse(ChatSidePanel.fits(width: V2SplitLayout.minimumChatWidth + panel.standard))
        XCTAssertTrue(ChatSidePanel.fits(width: V2SplitLayout.minimumChatWidth + panel.standard + 1))
        XCTAssertLessThan(panel.minimum, panel.standard)
        XCTAssertEqual(panel.resolved(300, window: 1440, keeping: V2SplitLayout.minimumChatWidth), 300)
        XCTAssertEqual(panel.resolved(700, window: 1000, keeping: V2SplitLayout.minimumChatWidth), 1000 - V2SplitLayout.minimumChatWidth - 1)

        // With Artifacts open, a widened list leaves the chat room for the
        // panel: on an iPad Air in landscape (1180 pt), a list dragged to
        // its most still leaves a chat the panel fits beside.
        let besidePanel = V2SplitLayout.ListColumn(window: 1180, stored: Double(list.maximum), keepsSidePanel: true)
        XCTAssertTrue(ChatSidePanel.fits(width: 1180 - besidePanel.width - 1))
        XCTAssertTrue(ChatSidePanel.fits(width: 1180 - besidePanel.room - 1))
        XCTAssertEqual(V2SplitLayout.ListColumn(window: 1180, stored: Double(list.maximum)).width, list.maximum)
        // On a window with no room for both, the list keeps its least width.
        XCTAssertEqual(V2SplitLayout.ListColumn(window: 900, stored: 500, keepsSidePanel: true).width, list.minimum)
        // A drag under way lays the list out at the dragged width.
        XCTAssertEqual(V2SplitLayout.ListColumn(window: 1440, stored: 400, dragged: 450).width, 450)

        // The drawer shell's persistent sidebar drags the same way, from
        // the width it turns persistent at.
        let sidebar = SidebarLayoutMetrics.persistentSidebarWidths
        XCTAssertEqual(sidebar.standard, SidebarLayoutMetrics.persistentSidebarWidth)
        XCTAssertEqual(sidebar.resolved(460, window: SidebarLayoutMetrics.minimumPersistentLayoutWidth, keeping: SidebarLayoutMetrics.minimumChatWidth), sidebar.minimum)

        // Each is its own setting on the device.
        XCTAssertEqual(Set([list.key, panel.key, sidebar.key]).count, 3)
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
            XCTAssertEqual(ReadableWidth.textSteps(column: ReadableWidth.chat(available: width), base: ReadableWidth.chat), 0, "\(width) pt keeps the size.")
        }
        // Each step once the column holds as many words a line at it.
        XCTAssertEqual(ReadableWidth.textSteps(column: 850, base: ReadableWidth.chat), 1)
        XCTAssertEqual(ReadableWidth.textSteps(column: 938, base: ReadableWidth.chat), 1)
        XCTAssertEqual(ReadableWidth.textSteps(column: 939, base: ReadableWidth.chat), 2)
        // An iPad's whole window with the list hidden, and a maximized Mac.
        XCTAssertEqual(ReadableWidth.textSteps(column: ReadableWidth.chat(available: 1376), base: ReadableWidth.chat), 2)
        XCTAssertEqual(ReadableWidth.textSteps(column: ReadableWidth.chat(available: 1800), base: ReadableWidth.chat), 3)
        // From the system's size: never past the largest standard size, and
        // none at an accessibility size.
        XCTAssertEqual(ReadableWidth.textSteps(column: 1040, base: ReadableWidth.chat, from: .large), 3)
        XCTAssertEqual(ReadableWidth.textSteps(column: 1040, base: ReadableWidth.chat, from: .xxLarge), 1)
        XCTAssertEqual(ReadableWidth.textSteps(column: 1040, base: ReadableWidth.chat, from: .xxxLarge), 0)
        XCTAssertEqual(ReadableWidth.textSteps(column: 1040, base: ReadableWidth.chat, from: .accessibility1), 0)
    }

    func testSettingsColumnWidensAndStepsItsText() {
        // A sheet, and an iPad's window beside nothing wider, keep 720 pt.
        for width: CGFloat in [375, 720, 1000] {
            XCTAssertEqual(ReadableWidth.settings(available: width), ReadableWidth.settings, "\(width) pt keeps 720 pt.")
            XCTAssertEqual(ReadableWidth.textSteps(column: ReadableWidth.settings(available: width), base: ReadableWidth.settings), 0)
        }
        XCTAssertEqual(ReadableWidth.settings(available: 1200), 864)
        XCTAssertEqual(ReadableWidth.textSteps(column: 864, base: ReadableWidth.settings), 1)
        // A maximized window stops at the cap, three steps up.
        XCTAssertEqual(ReadableWidth.settings(available: 1800), ReadableWidth.settingsMax)
        XCTAssertEqual(ReadableWidth.textSteps(column: ReadableWidth.settingsMax, base: ReadableWidth.settings), 3)
    }

    func testColumnsSetTheirTextForTheirContent() {
        // A maximized chat steps its own text and its transcript, and is
        // the base for the cards inside it.
        let chat = ReadableWidth.columnText(column: ReadableWidth.chatMax, base: ReadableWidth.chat, scalesChatText: true, size: .large)
        XCTAssertEqual(chat.size, .xxxLarge)
        XCTAssertEqual(chat.chatSteps, 3)
        XCTAssertEqual(chat.base, .large)
        // Settings steps its own text; no transcript takes the steps.
        let settings = ReadableWidth.columnText(column: ReadableWidth.settingsMax, base: ReadableWidth.settings, scalesChatText: false, size: .large)
        XCTAssertEqual(settings.size, .xxxLarge)
        XCTAssertEqual(settings.chatSteps, 0)
        XCTAssertEqual(settings.base, .large)
        // A fixed column (a call, a list alone) changes nothing and is no base.
        let fixed = ReadableWidth.columnText(column: 2000, base: nil, scalesChatText: false, size: .large)
        XCTAssertEqual(fixed.size, .large)
        XCTAssertEqual(fixed.chatSteps, 0)
        XCTAssertNil(fixed.base)
        // An accessibility size stays as the user set it.
        let accessible = ReadableWidth.columnText(column: ReadableWidth.chatMax, base: ReadableWidth.chat, scalesChatText: true, size: .accessibility2)
        XCTAssertEqual(accessible.size, .accessibility2)
        XCTAssertEqual(accessible.chatSteps, 0)
        XCTAssertEqual(accessible.base, .accessibility2)
    }

    func testWideColumnStepsScaleTranscriptFonts() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let base = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        // Two steps from the default size: body text grows as 17 pt to 21.
        let stepped = ChatTextAppearance(size: .default).widened(steps: 2, from: .large)
        XCTAssertEqual(stepped.widthScale, 21.0 / 17, accuracy: 0.0001)
        // By point size, not by resolving at the larger Dynamic Type size,
        // which an iPad app on a Mac ignores (#1393 did nothing there).
        XCTAssertEqual(ChatTypography.font(for: .body, appearance: stepped, compatibleWith: traits).pointSize, base.pointSize * 21 / 17, accuracy: 0.001)
        let heading = UIFont.preferredFont(forTextStyle: .title2, compatibleWith: traits).pointSize
        XCTAssertEqual(ChatTypography.font(for: .heading(level: 1), appearance: stepped, compatibleWith: traits).pointSize, heading * 21 / 17, accuracy: 0.001)
        // A view whose environment the column already stepped up resolves
        // at the system's size and isn't stepped twice.
        XCTAssertEqual(
            ChatTypography.font(for: .body, appearance: stepped, environmentCategory: .extraExtraLarge).pointSize,
            base.pointSize * 21 / 17,
            accuracy: 0.001
        )
        // The user's chat text size still multiplies.
        let larger = ChatTextAppearance(size: .larger).widened(steps: 2, from: .large)
        XCTAssertEqual(
            ChatTypography.font(for: .body, appearance: larger, compatibleWith: traits).pointSize,
            base.pointSize * 21 / 17 * ChatTextSize.larger.scale,
            accuracy: 0.001
        )
        // The column and its transcript step through the same sizes, and
        // body text's sizes are iOS's.
        XCTAssertEqual(ChatTypography.standardDynamicTypeSizes, ChatTypography.standardCategories.map { DynamicTypeSize($0) })
        XCTAssertEqual(
            ChatTypography.standardBodySizes,
            ChatTypography.standardCategories.map { UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: $0)).pointSize }
        )
        // Steps stop at the largest standard size; accessibility sizes stay.
        XCTAssertEqual(ChatTypography.widthScale(steps: 3, from: .xxLarge), 23.0 / 21, accuracy: 0.0001)
        XCTAssertEqual(ChatTypography.widthScale(steps: 2, from: .xxxLarge), 1)
        XCTAssertEqual(ChatTypography.widthScale(steps: 2, from: .accessibility2), 1)
        XCTAssertEqual(ReadableWidth.chatTextGrowth, [19.0 / 17, 21.0 / 17, 23.0 / 17])
        XCTAssertEqual(ChatTextAppearance(size: .default).widened(steps: 2, from: .accessibility2), ChatTextAppearance(size: .default))
        XCTAssertEqual(ChatTypography.lowered(.extraExtraLarge, by: 2), .large)
        XCTAssertEqual(ChatTypography.lowered(.accessibilityMedium, by: 2), .accessibilityMedium)
        // In-column cards' UIKit text: nothing added where the system sizes
        // text as iOS does, or outside a stepped column; where it draws
        // every size alike (a Mac), the growth iOS would give from the
        // column's base, the transcript's widthScale, never a shrink.
        let mac = [CGFloat](repeating: 17, count: 7)
        XCTAssertEqual(ChatTypography.missingGrowth(at: .extraExtraExtraLarge, from: .large), 1)
        XCTAssertEqual(ChatTypography.missingGrowth(at: .extraExtraExtraLarge, from: nil, drawn: mac), 1)
        XCTAssertEqual(ChatTypography.missingGrowth(at: .small, from: .small, drawn: mac), 1)
        XCTAssertEqual(ChatTypography.missingGrowth(at: .accessibilityLarge, from: .large, drawn: mac), 1)
        // There, transcript and cards both land on iOS's size for the
        // stepped size, whatever the base: the transcript resolves at the
        // system's 17 pt and grows by widthScale, the cards resolve at the
        // stepped size (17 pt too) and grow by missingGrowth.
        for (base, steps, expected) in [(DynamicTypeSize.large, 3, CGFloat(23)), (.xxLarge, 1, 23), (.medium, 1, 17), (.xLarge, 1, 21)] {
            let stepped = ChatTypography.standardCategories[ChatTypography.standardDynamicTypeSizes.firstIndex(of: base)! + steps]
            XCTAssertEqual(17 * ChatTypography.widthScale(steps: steps, from: base, drawn: mac), expected, accuracy: 0.001, "\(base) + \(steps)")
            XCTAssertEqual(17 * ChatTypography.missingGrowth(at: stepped, from: base, drawn: mac), expected, accuracy: 0.001, "\(base) + \(steps)")
        }
        XCTAssertEqual(
            UIFont.preferredFont(forTextStyle: .subheadline, in: .extraExtraExtraLarge, from: .large).pointSize,
            UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)).pointSize,
            accuracy: 0.001
        )
        // Caches tell the steps apart; no steps keeps today's keys.
        XCTAssertEqual(ChatTextAppearance(size: .default).cacheIdentity, ChatTextSize.default.cacheIdentity)
        XCTAssertNotEqual(stepped.cacheIdentity, ChatTextAppearance(size: .default).cacheIdentity)
        XCTAssertNotEqual(stepped.cacheIdentity, ChatTextAppearance(size: .default).widened(steps: 2, from: .xLarge).cacheIdentity)
        XCTAssertEqual(ChatTypography.dimension(10, appearance: stepped), 10 * 21 / 17, accuracy: 0.001)
    }

    /// Profiles tapped while a switch runs: the last tap goes once it ends,
    /// and a tap on where it landed (or no tap) starts nothing.
    func testV2ProfileTappedDuringASwitchGoesOnceItEnds() {
        let dashboard = UUID()
        var pick = V2QueuedProfilePick()
        XCTAssertNil(pick.take(landedOn: "work", dashboardID: dashboard), "No tap, no further switch.")

        pick.tap("home", dashboardID: dashboard)
        pick.tap("lab", dashboardID: dashboard)
        XCTAssertEqual(pick.take(landedOn: "work", dashboardID: dashboard), "lab", "The last tap wins.")
        XCTAssertNil(pick.take(landedOn: "lab", dashboardID: dashboard), "Taken once.")

        pick.tap("work", dashboardID: dashboard)
        XCTAssertNil(pick.take(landedOn: "work", dashboardID: dashboard), "A tap on where the switch lands starts nothing.")

        pick.tap("lab", dashboardID: dashboard)
        XCTAssertNil(pick.take(landedOn: "work", dashboardID: UUID()), "A tap on another dashboard is dropped.")
        XCTAssertNil(pick.take(landedOn: "work", dashboardID: dashboard), "Dropped, not kept for later.")
    }
}
