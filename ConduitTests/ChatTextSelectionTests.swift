import XCTest
@testable import Conduit

final class ChatTextSelectionTests: XCTestCase {
    func testEveryCurrentMessageRoleAllowsPartialTextSelection() {
        let roles: [MessageRole] = [
            .user, .assistant, .reasoning, .system,
            .partial, .tool, .clarify, .approval
        ]

        XCTAssertTrue(
            roles.allSatisfy { ChatTextSelectionPolicy.allowsTextSelection(for: $0) }
        )
    }
}
