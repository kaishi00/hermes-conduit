//
//  V2ReopenedConversationTests.swift
//  Conduit
//
//  #1559: where a V2 launch opens after iOS ended Conduit in the
//  background. In an extension of SidebarLayoutTests, so the test planner
//  sees no new class.
//

import XCTest
@testable import Conduit

extension SidebarLayoutTests {
    private func reopenProject(_ id: String) -> ProjectSummary {
        ProjectSummary(id: id, title: id, isHome: false, sessionCount: 0, previewSessions: [])
    }

    private func reopenLaunch(
        _ stored: String,
        lastChat: SessionReference.Kind? = .dashboard,
        hasSavedCopy: Bool = false,
        projects: [ProjectSummary] = [],
        showsPulse: Bool = true
    ) -> V2ReopenedConversation.Launch? {
        V2ReopenedConversation.launch(stored: stored, lastChat: lastChat, hasSavedCopy: hasSavedCopy, projects: projects, showsPulse: showsPulse)
    }

    func testV2KeepsNothingWhileNoChatShows() {
        // The list, a project's page, Tasks or Settings showing: the launch opens on Chats.
        XCTAssertEqual(V2ReopenedConversation.record(showing: nil, path: [.conversation], roomID: nil), "")
        XCTAssertEqual(V2ReopenedConversation.record(showing: .chats, path: [], roomID: nil), "")
        XCTAssertEqual(V2ReopenedConversation.record(showing: .chats, path: [.project(reopenProject("p"))], roomID: nil), "")
        XCTAssertEqual(V2ReopenedConversation.record(showing: .settings, path: [.conversation], roomID: nil), "")
    }

    func testV2ReopensTheChatWithThePagesUnderIt() {
        let project = reopenProject("p1")
        let stored = V2ReopenedConversation.record(showing: .chats, path: [.project(project), .pulse, .conversation], roomID: nil)
        XCTAssertEqual(
            reopenLaunch(stored, projects: [project]),
            .init(tab: .chats, path: [.project(project), .pulse, .conversation])
        )
        // A project this profile no longer lists, or Pulse no longer showing, is left out.
        XCTAssertEqual(reopenLaunch(stored, projects: [], showsPulse: false), .init(tab: .chats, path: [.conversation]))
        // A chat in Chats needs a chat to resume or a saved copy on screen.
        XCTAssertEqual(reopenLaunch(stored, lastChat: nil, hasSavedCopy: true, projects: [project])?.tab, .chats)
        XCTAssertNil(reopenLaunch(stored, lastChat: nil, hasSavedCopy: false))
        // Nothing kept (a first launch, or iOS dropped it after a swipe-quit), or garbage.
        XCTAssertNil(reopenLaunch(""))
        XCTAssertNil(reopenLaunch("chats"))
    }

    func testV2ReopensABotChatOnlyWhenTheKeptChatIsOne() {
        let stored = V2ReopenedConversation.record(showing: .bots, path: [.conversation], roomID: nil)
        XCTAssertEqual(reopenLaunch(stored, lastChat: .bot), .init(tab: .bots, path: [.conversation]))
        XCTAssertNil(reopenLaunch(stored, lastChat: .dashboard, hasSavedCopy: true))
    }

    func testV2ReopensAGroupRoomOnceConnected() {
        // The room's screen isn't in the path: it's pushed as the room opens.
        let stored = V2ReopenedConversation.record(showing: .bots, path: [.conversation], roomID: "room-1")
        XCTAssertEqual(reopenLaunch(stored, lastChat: nil), .init(tab: .bots, path: [], roomID: "room-1"))
    }
}
