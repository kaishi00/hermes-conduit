//
//  V2ReopenedConversationTests.swift
//  Conduit
//
//  #1559: the chat a V2 launch opens on after iOS ended Conduit in the
//  background. In an extension of SidebarLayoutTests, so the test planner
//  sees no new class.
//

import XCTest
@testable import Conduit

extension SidebarLayoutTests {
    func testV2KeepsOnlyAShowingChatOrBotChat() {
        XCTAssertEqual(V2ReopenedConversation.storedValue(showing: .chats, inRoom: false), "chats")
        XCTAssertEqual(V2ReopenedConversation.storedValue(showing: .bots, inRoom: false), "bots")
        // The list, Tasks or Settings showing: the launch opens on Chats.
        XCTAssertEqual(V2ReopenedConversation.storedValue(showing: nil, inRoom: false), "")
        XCTAssertEqual(V2ReopenedConversation.storedValue(showing: .tasks, inRoom: false), "")
        XCTAssertEqual(V2ReopenedConversation.storedValue(showing: .settings, inRoom: false), "")
        // A group room opens again only from its row.
        XCTAssertEqual(V2ReopenedConversation.storedValue(showing: .chats, inRoom: true), "")
    }

    func testV2ReopensTheChatOnlyWhenThereIsOneToShow() {
        // Nothing kept (a first launch, or iOS dropped it after a swipe-quit).
        XCTAssertNil(V2ReopenedConversation.tab(stored: "", lastChat: .dashboard, hasSavedCopy: true))
        // A chat in Chats: the resumed chat, or its saved copy on screen.
        XCTAssertEqual(V2ReopenedConversation.tab(stored: "chats", lastChat: .dashboard, hasSavedCopy: false), .chats)
        XCTAssertEqual(V2ReopenedConversation.tab(stored: "chats", lastChat: nil, hasSavedCopy: true), .chats)
        XCTAssertNil(V2ReopenedConversation.tab(stored: "chats", lastChat: nil, hasSavedCopy: false))
        // A Bot Chat in Bots, only while the kept chat is a Bot Chat.
        XCTAssertEqual(V2ReopenedConversation.tab(stored: "bots", lastChat: .bot, hasSavedCopy: false), .bots)
        XCTAssertNil(V2ReopenedConversation.tab(stored: "bots", lastChat: .dashboard, hasSavedCopy: true))
        XCTAssertNil(V2ReopenedConversation.tab(stored: "settings", lastChat: .dashboard, hasSavedCopy: true))
    }
}
