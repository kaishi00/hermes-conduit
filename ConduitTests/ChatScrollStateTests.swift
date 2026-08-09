import XCTest
@testable import Conduit

final class ChatScrollStateTests: XCTestCase {
    func testSnapshotsAreIsolatedBySession() {
        var store = ChatScrollStateStore()
        store.save(
            ChatScrollSnapshot(anchorMessageID: "a-3", followsLatest: false),
            for: "session-a"
        )
        store.save(
            ChatScrollSnapshot(anchorMessageID: "b-1", followsLatest: false),
            for: "session-b"
        )

        XCTAssertEqual(store.snapshot(for: "session-a")?.anchorMessageID, "a-3")
        XCTAssertEqual(store.snapshot(for: "session-b")?.anchorMessageID, "b-1")
    }

    func testRestorationKeepsAnchorWhenMessageStillExists() {
        var store = ChatScrollStateStore()
        let expected = ChatScrollSnapshot(anchorMessageID: "message-4", followsLatest: false)
        store.save(expected, for: "session")

        XCTAssertEqual(
            store.restoration(
                for: "session",
                availableMessageIDs: ["message-3", "message-4", "message-5"]
            ),
            expected
        )
    }

    func testRestorationFallsBackToLatestWhenAnchorDisappears() {
        var store = ChatScrollStateStore()
        store.save(
            ChatScrollSnapshot(anchorMessageID: "deleted", followsLatest: false),
            for: "session"
        )

        XCTAssertEqual(
            store.restoration(for: "session", availableMessageIDs: ["message-1"]),
            .latest
        )
    }

    func testLatestSnapshotRemainsLatestRegardlessOfAvailableMessages() {
        var store = ChatScrollStateStore()
        store.save(ChatScrollSnapshot.latest, for: "session")

        XCTAssertEqual(
            store.restoration(for: "session", availableMessageIDs: []),
            .latest
        )
    }

    func testSessionKeysAreTrimmedForSaveAndLookup() {
        var store = ChatScrollStateStore()
        let expected = ChatScrollSnapshot(anchorMessageID: "message-1", followsLatest: false)
        store.save(expected, for: "  session  ")

        XCTAssertEqual(store.snapshot(for: "session"), expected)
        XCTAssertEqual(store.snapshot(for: "\n session \t"), expected)
    }

    func testWhitespaceOnlySessionKeysAreIgnored() {
        var store = ChatScrollStateStore()
        store.save(ChatScrollSnapshot.latest, for: " \n\t ")

        XCTAssertNil(store.snapshot(for: " \n\t "))
    }
}
