import XCTest
@testable import Conduit

/// The key the chat view's rows are watched by changes with every write
/// the rows are read from, so the rows themselves aren't compared.
@MainActor
extension ChatScrollStateTests {

    func testTheRowsRevisionMovesWithEveryWriteTheRowsAreReadFrom() {
        let chat = ChatState()
        let start = chat.rowsRevision
        chat.messages = [ChatMessage(id: "m1", role: .user, content: "hi", timestamp: "2026-01-01T00:00:00Z")]
        XCTAssertNotEqual(chat.rowsRevision, start)
        let afterMessages = chat.rowsRevision
        chat.offlineChatPresentation = nil
        XCTAssertNotEqual(chat.rowsRevision, afterMessages, "the saved copy is read too")
    }

    func testAppStatesRowsKeyChangesWithTheRows() throws {
        let suite = "rows-key-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let start = appState.chatRowsOnScreenKey
        XCTAssertEqual(appState.chatRowsOnScreenKey, start, "unchanged rows, unchanged key")
        appState.messages = [ChatMessage(id: "m1", role: .user, content: "hi", timestamp: "2026-01-01T00:00:00Z")]
        let afterMessages = appState.chatRowsOnScreenKey
        XCTAssertNotEqual(afterMessages, start)
        appState.offlineChatPresentation = nil
        XCTAssertNotEqual(appState.chatRowsOnScreenKey, afterMessages)
    }
}
