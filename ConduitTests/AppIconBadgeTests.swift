import XCTest
@testable import Conduit

/// The app icon's number (issue 3458, AppIconBadge). An extension, so no
/// new class to plan.
extension NotificationCopyTests {
    private typealias Chat = AppIconBadge.Chat

    func testBadgeCountsEachChatOnce() {
        let known = [Chat(ids: ["s1", "stored1"], waits: false), Chat(ids: ["s2"], waits: true)]
        let delivered = [
            Chat(ids: ["stored1"], waits: false),  // the same chat as a known one
            Chat(ids: ["s3"], waits: false),
            Chat(ids: ["s3"], waits: false),  // a second reply in it
        ]
        XCTAssertEqual(AppIconBadge.count(known: known, delivered: delivered, mode: .chats), 3)
    }

    func testBadgeJoinsChatsThatShareAnyID() {
        // One delivered notification names two ids that two known rows split.
        let known = [Chat(ids: ["a"], waits: false), Chat(ids: ["b"], waits: false)]
        let delivered = [Chat(ids: ["a", "b"], waits: false)]
        XCTAssertEqual(AppIconBadge.count(known: known, delivered: delivered, mode: .chats), 1)
    }

    func testBadgeNeedsYouOnlyCountsWaits() {
        let known = [Chat(ids: ["s1"], waits: false), Chat(ids: ["s2"], waits: true)]
        let delivered = [Chat(ids: ["s3"], waits: false), Chat(ids: ["s4"], waits: true)]
        XCTAssertEqual(AppIconBadge.count(known: known, delivered: delivered, mode: .needsYou), 2)
        XCTAssertEqual(AppIconBadge.count(known: known, delivered: delivered, mode: .off), 0)
    }

    func testBadgeLeavesOutClearedNotificationsButNotAnArrivingOne() {
        let delivered = [Chat(ids: ["read-elsewhere"], waits: false), Chat(ids: ["s2"], waits: false)]
        let cleared = [["read-elsewhere"]]
        XCTAssertEqual(AppIconBadge.count(known: [], delivered: delivered, cleared: cleared, mode: .chats), 1)
        // A new reply in the chat read elsewhere is unread again.
        let arriving = Chat(ids: ["read-elsewhere"], waits: false)
        XCTAssertEqual(AppIconBadge.count(known: [], delivered: delivered, cleared: cleared, arriving: arriving, mode: .chats), 2)
        let ledger = AppIconBadge.arrived(arriving, in: AppIconBadge.Ledger(known: [], cleared: cleared))
        XCTAssertEqual(ledger.cleared, [])
    }

    func testBadgeChatFromANote() {
        let reply = AppIconBadge.chat(note: ["type": "response.ready", "session_id": "s1", "stored_session_id": "root"], mode: .chats)
        XCTAssertEqual(reply, Chat(ids: ["s1", "root"], waits: false))
        XCTAssertNil(AppIconBadge.chat(note: ["type": "response.ready", "session_id": "s1"], mode: .needsYou))
        let approval = AppIconBadge.chat(note: ["type": "approval.needed", "session_id": "s1", "room_id": "r1"], mode: .needsYou)
        XCTAssertEqual(approval, Chat(ids: ["s1", "room:r1"], waits: true))
        // Pulse, a call or a phone change isn't a chat waiting on the user.
        for type in ["pulse.brief", "call.requested", "phone.changes", "room.invite"] {
            XCTAssertNil(AppIconBadge.chat(note: ["type": type, "session_id": "s1"], mode: .chats), type)
        }
    }

    func testBadgeChatFromAPlaintextPush() {
        let userInfo: [AnyHashable: Any] = ["conduit": ["type": "input.needed", "session_id": "s9", "profile": "work"]]
        XCTAssertEqual(AppIconBadge.chat(userInfo: userInfo, mode: .chats), Chat(ids: ["s9"], waits: true))
        // A generic copy with nothing to route counts nothing.
        XCTAssertNil(AppIconBadge.chat(userInfo: [:], mode: .chats))
    }
}
