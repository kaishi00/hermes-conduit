import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The comparisons the types with a synthesized `==` keep (#2672): each
/// field the old hand-written `==` skipped is wrapped in @EqualityIgnored,
/// each it compared by instance in @IdentityEquatable or
/// @OptionalIdentityEquatable (Conduit/Services/EquatableWrappers.swift).
/// An extension of an existing class, so the CI planner's class inventory
/// is unchanged.
extension TranscriptLayoutTests {
    func testEqualityWrappersSkipOrCompareByInstance() {
        XCTAssertEqual(EqualityIgnored(wrappedValue: 1), EqualityIgnored(wrappedValue: 2))
        XCTAssertEqual(EqualityIgnored(wrappedValue: 1).hashValue, EqualityIgnored(wrappedValue: 2).hashValue)
        let one = NSObject(), other = NSObject()
        XCTAssertEqual(IdentityEquatable(wrappedValue: one), IdentityEquatable(wrappedValue: one))
        XCTAssertNotEqual(IdentityEquatable(wrappedValue: one), IdentityEquatable(wrappedValue: other))
        XCTAssertEqual(OptionalIdentityEquatable<NSObject>(wrappedValue: nil), OptionalIdentityEquatable(wrappedValue: nil))
        XCTAssertNotEqual(OptionalIdentityEquatable(wrappedValue: one), OptionalIdentityEquatable(wrappedValue: nil))
    }

    func testBackgroundChatsCompareByStateAndIdsNotTitle() {
        let state = ChatState()
        func chat(title: String = "A", isBotChat: Bool = false, ids: Set<String> = ["s1"], state: ChatState) -> BackgroundChat {
            BackgroundChat(sessionIDs: ids, durableSessionID: "d", title: title, dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                           profile: "p", isBotChat: isBotChat, state: state, leftAt: Date(timeIntervalSince1970: 1))
        }
        XCTAssertEqual(chat(title: "A", isBotChat: false, state: state), chat(title: "B", isBotChat: true, state: state))
        XCTAssertNotEqual(chat(state: state), chat(ids: ["s2"], state: state))
        XCTAssertNotEqual(chat(state: state), chat(state: ChatState()))
    }

    func testIdKeyedValuesStayEqualOnlyToThemselves() {
        let notice = AgentSettingsAppliedNotice(changes: [])
        XCTAssertEqual(notice, notice)
        XCTAssertNotEqual(AgentSettingsAppliedNotice(changes: []), AgentSettingsAppliedNotice(changes: []))
        let reveal = WorkspaceReveal(path: "/a", line: 1)
        var moved = reveal
        moved.line = 2
        XCTAssertEqual(reveal, moved, "a reveal is equal by id")
        XCTAssertNotEqual(WorkspaceReveal(path: "/a", line: 1), WorkspaceReveal(path: "/a", line: 1))
        XCTAssertNotEqual(AttachmentDropRequest(owner: "o", providers: []), AttachmentDropRequest(owner: "o", providers: []))
    }

    func testValuesComparedByWhatTheySay() {
        XCTAssertEqual(ProfileFallbackModel(provider: "p", model: "m"), ProfileFallbackModel(provider: "p", model: "m"))
        XCTAssertNotEqual(ProfileFallbackModel(provider: "p", model: "m"), ProfileFallbackModel(provider: "p", model: "n"))
        let link = RoomLinkURL("conduit://link/abcd")
        XCTAssertNotNil(link)
        XCTAssertEqual(link, RoomLinkURL("conduit://link/abcd"))
        XCTAssertNotEqual(link, RoomLinkURL("conduit://link/abce"))
        let box = PluginSettings.JSONBox(["b": 1, "a": [true]])
        let same = PluginSettings.JSONBox(["a": [true], "b": 1])
        XCTAssertEqual(box, same)
        XCTAssertEqual(box.hashValue, same.hashValue)
        XCTAssertNotEqual(box, PluginSettings.JSONBox(["a": [false], "b": 1]))
        XCTAssertEqual(CustomAccentColor(hex: "#336699"), CustomAccentColor(hex: "#336699"))
        XCTAssertEqual(CustomAccentColor(hex: "#336699")?.hashValue, CustomAccentColor(hex: "#336699")?.hashValue)
        XCTAssertNotEqual(CustomAccentColor(hex: "#336699"), CustomAccentColor(hex: "#336698"))
    }

    func testActionsCompareByOwnerOrReply() {
        let owner = NSObject(), other = NSObject()
        XCTAssertEqual(ChatQuoteAction(owner: owner) { _ in }, ChatQuoteAction(owner: owner, isAvailable: { false }) { _ in })
        XCTAssertNotEqual(ChatQuoteAction(owner: owner) { _ in }, ChatQuoteAction(owner: other) { _ in })
        XCTAssertEqual(QuotedReplyJumpAction(owner: owner) { _, _ in true }, QuotedReplyJumpAction(owner: owner) { _, _ in false })
        XCTAssertNotEqual(QuotedReplyJumpAction(owner: owner) { _, _ in true }, QuotedReplyJumpAction(owner: other) { _, _ in true })
        XCTAssertEqual(ChatPinReplyAction(messageID: "m", isPinned: { true }, toggle: {}),
                       ChatPinReplyAction(messageID: "m", isPinned: { false }, toggle: {}))
        XCTAssertNotEqual(ChatPinReplyAction(messageID: "m", isPinned: { true }, toggle: {}),
                          ChatPinReplyAction(messageID: "n", isPinned: { true }, toggle: {}))
        var context = V2ShellContext()
        context.pickProfile = { _ in }
        XCTAssertEqual(context, V2ShellContext(), "closures never count")
        context.isSplit.toggle()
        XCTAssertNotEqual(context, V2ShellContext())
    }

    func testAgentIdentityComparesTheBotPictureByInstance() {
        let picture = UIImage()
        let face = ConversationAgentIdentity.BotFace(name: "Bot", colorString: nil, image: picture)
        let identity = ConversationAgentIdentity(name: "Bot", photoURL: nil, botFace: face)
        XCTAssertEqual(identity, ConversationAgentIdentity(name: "Bot", photoURL: nil, botFace: face))
        let otherPicture = ConversationAgentIdentity.BotFace(name: "Bot", colorString: nil, image: UIImage())
        XCTAssertNotEqual(identity, ConversationAgentIdentity(name: "Bot", photoURL: nil, botFace: otherPicture))
        XCTAssertNotEqual(identity, ConversationAgentIdentity(name: "Bot", photoURL: nil, botFace: face, profile: "p"))
    }

    func testScreenGatesCompareTheAppStateByInstance() throws {
        let suiteName = "equality-screen-gates"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let one = AppState(defaults: defaults, loadSavedConnection: false)
        let other = AppState(defaults: defaults, loadSavedConnection: false)
        XCTAssertEqual(ComposerBarGate(appState: one), ComposerBarGate(appState: one))
        XCTAssertNotEqual(ComposerBarGate(appState: one), ComposerBarGate(appState: other))
        XCTAssertEqual(V2ChatsViewGate(appState: one), V2ChatsViewGate(appState: one))
        XCTAssertNotEqual(V2ChatsViewGate(appState: one), V2ChatsViewGate(appState: other))
        XCTAssertEqual(V2TasksViewGate(appState: one), V2TasksViewGate(appState: one))
        XCTAssertNotEqual(V2TasksViewGate(appState: one), V2TasksViewGate(appState: other))
    }
}
