import XCTest
@testable import Conduit

/// The V2 thinking and tool rows: what a step is called, what it was about,
/// and which tool the working line names.
extension ChatTypographyTests {
    func testStepStylesUseTheLiveActivityCategories() {
        XCTAssertEqual(ChatStepStyle(toolName: "web_search").category, .web)
        XCTAssertEqual(ChatStepStyle(toolName: "terminal").category, .terminal)
        XCTAssertEqual(ChatStepStyle(toolName: "browser_navigate").category, .browser)
        XCTAssertEqual(ChatStepStyle(toolName: "something_new").category, .tool)
    }

    func testPhoneToolsKeepOneCategoryButTheirOwnIcons() {
        let calendar = ChatStepStyle(toolName: "conduit_calendar")
        let health = ChatStepStyle(toolName: "conduit_health")
        XCTAssertEqual(calendar.category, .phone)
        XCTAssertEqual(health.category, .phone)
        XCTAssertEqual(calendar.symbol, "calendar")
        XCTAssertEqual(health.symbol, "heart")
        XCTAssertEqual(ChatStepStyle(toolName: "conduit_unknown").symbol, "iphone")
    }

    func testEveryCategoryHasRunningAndDoneWords() {
        for category in HermesToolCategory.allCases {
            XCTAssertFalse(HermesTurnCopy.toolKey(category).isEmpty)
            XCTAssertFalse(AppLocalization.string(ChatStepStyle.doneKey(category), language: .source).isEmpty)
        }
    }

    func testStepSubjectPrefersTheSearchCommandOrPage() {
        XCTAssertEqual(ChatStepSubject.line(from: #"{"max_results": "5", "query": "dinner downtown"}"#), "dinner downtown")
        XCTAssertEqual(ChatStepSubject.line(from: #"{"command": "git status\nls"}"#), "git status ls")
        XCTAssertEqual(ChatStepSubject.line(from: #"{"zeta": "last", "alpha": "first"}"#), "first")
        XCTAssertEqual(ChatStepSubject.line(from: "plain text\nsecond line"), "plain text second line")
        XCTAssertNil(ChatStepSubject.line(from: "   "))
        XCTAssertNil(ChatStepSubject.line(from: #"{"count": 3}"#))
        XCTAssertNil(ChatStepSubject.line(from: nil))
        // A huge input isn't parsed: its start is shown as one line.
        let huge = #"{"query": "x", "blob": ""# + String(repeating: "a", count: ChatStepSubject.parseLimit) + #""}"#
        XCTAssertEqual(ChatStepSubject.line(from: huge)?.hasPrefix(#"{"query""#), true)
        XCTAssertLessThanOrEqual(ChatStepSubject.line(from: huge)?.count ?? 0, 200)
    }

    @MainActor
    func testWorkingLineNamesOnlyTheTurnsRunningTool() {
        func tool(_ id: String, _ name: String, _ status: ToolActivity.Status) -> ChatMessage {
            ChatMessage(
                id: id, role: .tool, content: "", timestamp: "now",
                tool: ToolActivity(id: id, name: name, input: nil, output: nil, status: status)
            )
        }
        let user = ChatMessage(id: "u", role: .user, content: "Hi", timestamp: "now")
        let earlier = tool("t0", "terminal", .running)

        XCTAssertEqual(
            ChatView.runningToolName(in: [user, tool("t1", "web_search", .complete), tool("t2", "conduit_calendar", .running)]),
            "conduit_calendar"
        )
        XCTAssertNil(ChatView.runningToolName(in: [user, tool("t1", "web_search", .complete)]))
        // A stuck row from an earlier turn isn't this turn's step.
        XCTAssertNil(ChatView.runningToolName(in: [earlier, user]))
    }
}
