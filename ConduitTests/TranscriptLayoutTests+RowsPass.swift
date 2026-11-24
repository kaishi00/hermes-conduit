import XCTest
@testable import Conduit

/// What the transcript builds of the rows it's handed: nothing under a Bot
/// Chat's cover, and not the chat left's rows again under the new
/// conversation, whose own rows then draw in full.
extension TranscriptLayoutTests {
    private var oldRows: [TranscriptRow] { [TranscriptRow(id: "m1", kind: .thinking), TranscriptRow(id: "m2", kind: .thinking)] }
    private var newRows: [TranscriptRow] { [TranscriptRow(id: "n1", kind: .thinking)] }

    func testRowsUnderACoverAreHeldAndTheComingChatsDrawInFull() {
        var pass = TranscriptRowsPass()
        XCTAssertEqual(pass.update(rows: oldRows, conversation: "old", holds: true).action, .hold)
        XCTAssertEqual(pass.update(rows: oldRows, conversation: "old", holds: true).action, .hold)
        // The coming chat opens: its first pass still carries the old rows.
        let carried = pass.update(rows: oldRows, conversation: "new", holds: false)
        XCTAssertEqual(carried.action, .keepCarried)
        XCTAssertTrue(carried.conversationChanged)
        XCTAssertTrue(pass.showsRowsOfChatLeft)
        XCTAssertEqual(pass.update(rows: oldRows, conversation: "new", holds: false).action, .keepCarried)
        let own = pass.update(rows: newRows, conversation: "new", holds: false)
        XCTAssertEqual(own.action, .apply(redrawingAll: true))
        XCTAssertFalse(own.conversationChanged)
        XCTAssertFalse(pass.showsRowsOfChatLeft)
        XCTAssertEqual(pass.update(rows: newRows, conversation: "new", holds: false).action, .apply(redrawingAll: false))
    }

    func testAChangeWhileHeldIsToldOnTheFirstPassDrawn() {
        var pass = TranscriptRowsPass()
        _ = pass.update(rows: oldRows, conversation: "old", holds: true)
        _ = pass.update(rows: oldRows, conversation: "new", holds: true)
        let drawn = pass.update(rows: newRows, conversation: "new", holds: false)
        XCTAssertEqual(drawn.action, .apply(redrawingAll: true))
        XCTAssertTrue(drawn.conversationChanged)
    }

    func testAnOpenThatFailsDrawsTheChatOpenBefore() {
        var pass = TranscriptRowsPass()
        _ = pass.update(rows: oldRows, conversation: "old", holds: true)
        let back = pass.update(rows: oldRows, conversation: "old", holds: false)
        XCTAssertEqual(back.action, .apply(redrawingAll: false))
        XCTAssertFalse(back.conversationChanged)
    }

    func testAChatChangedOnScreenKeepsItsRowsUntilTheNewOnesCome() {
        var pass = TranscriptRowsPass()
        XCTAssertEqual(pass.update(rows: oldRows, conversation: "old", holds: false).action, .apply(redrawingAll: false))
        let carried = pass.update(rows: oldRows, conversation: "new", holds: false)
        XCTAssertEqual(carried.action, .keepCarried, "the chat left's rows aren't built again")
        XCTAssertTrue(carried.conversationChanged)
        // A welcome is the new chat's own: it draws.
        let welcome = [TranscriptRow(id: TranscriptRow.emptyID, kind: .empty)]
        XCTAssertEqual(pass.update(rows: welcome, conversation: "new", holds: false).action, .apply(redrawingAll: true))
        // A chat left with no rows of its own carries nothing to skip.
        XCTAssertEqual(pass.update(rows: welcome, conversation: "other", holds: false).action, .apply(redrawingAll: true))
    }
}
