import XCTest
@testable import Conduit

/// One sentence for a finished run of steps (ChatStepSummaries): which run
/// is described, what the answer becomes, and how sentences are kept.
extension ChatTypographyTests {
    private func summaryStep(_ id: String, _ name: String = "terminal", running: Bool = false) -> ChatMessage {
        ChatMessage(
            id: "row-\(id)", role: .tool, content: "", timestamp: "2026-10-24T09:00:00Z",
            tool: ToolActivity(id: id, name: name, input: nil, output: nil, status: running ? .running : .complete)
        )
    }

    func testTheLastRunAfterTheUsersMessageIsDescribed() {
        let user = ChatMessage(id: "u", role: .user, content: "Find dinner", timestamp: "2026-10-24T09:00:00Z")
        let reply = ChatMessage(id: "a", role: .assistant, content: "Here you go", timestamp: "2026-10-24T09:01:00Z")
        let earlier = [summaryStep("e1"), summaryStep("e2"), summaryStep("e3")]
        let note = ChatMessage(id: "mid", role: .assistant, content: "Looking further", timestamp: "2026-10-24T09:00:30Z")
        let last = [summaryStep("c1", "web_search"), summaryStep("c2"), summaryStep("c3")]

        let run = ChatStepSummaries.lastRun(in: [user] + earlier + [note] + last + [reply])
        XCTAssertEqual(run?.map(\.id), last.map(\.id))
        // Two steps say enough on their own, and steps before the user's
        // message belong to an earlier turn.
        XCTAssertNil(ChatStepSummaries.lastRun(in: [user, summaryStep("x1"), summaryStep("x2"), reply]))
        XCTAssertNil(ChatStepSummaries.lastRun(in: earlier + [user, reply]))
        // A step still running: the turn hasn't settled.
        XCTAssertNil(ChatStepSummaries.lastRun(in: [user, summaryStep("r1"), summaryStep("r2"), summaryStep("r3", running: true)]))
    }

    func testARunIsKeyedOnlyByAnIdOfItsOwn() {
        XCTAssertEqual(ChatStepSummaries.key(toolIDs: [nil, " ", "call_8fK2mQx9LpZ"]), "call_8fK2mQx9LpZ")
        XCTAssertEqual(ChatStepSummaries.key(toolIDs: ["toolu_01AbCdEfGhIj"]), "toolu_01AbCdEfGhIj")
        // Numbered per turn, or too short: they come back in other turns.
        XCTAssertNil(ChatStepSummaries.key(toolIDs: ["functions.web_search:0", "call_8fK2mQx9LpZ"]))
        XCTAssertNil(ChatStepSummaries.key(toolIDs: ["c1"]))
        XCTAssertNil(ChatStepSummaries.key(toolIDs: []))
    }

    func testTheAnswerBecomesOneLine() {
        XCTAssertEqual(ChatStepSummaries.cleaned("  \"Compared three menus and picked two.\"\n"), "Compared three menus and picked two.")
        XCTAssertEqual(ChatStepSummaries.cleaned("\n**Read the logs**\nand more"), "Read the logs")
        XCTAssertNil(ChatStepSummaries.cleaned("error: backend is retiring"))
        XCTAssertNil(ChatStepSummaries.cleaned("   "))
        XCTAssertNil(ChatStepSummaries.cleaned(String(repeating: "word ", count: 60)))
    }

    func testTheQuestionNamesTheLanguageAndIsRecognizable() {
        let question = ChatStepSummaries.question(language: "French")
        XCTAssertTrue(question.hasPrefix(ChatStepSummaries.questionHead))
        XCTAssertTrue(question.contains("Write it in French"))
        // Any language's question is the summary's, never the user's /btw.
        XCTAssertTrue(ChatStepSummaries.isQuestion(question))
        XCTAssertTrue(ChatStepSummaries.isQuestion(ChatStepSummaries.question(language: "Japanese")))
        XCTAssertFalse(ChatStepSummaries.isQuestion("Describe in one short sentence what you just did"))
        // The whole question, not its first and last words.
        let edited = question.replacingOccurrences(of: "(at most 15 words)", with: "(at most 30 words)")
        XCTAssertFalse(ChatStepSummaries.isQuestion(edited))
        XCTAssertFalse(ChatStepSummaries.isQuestion(nil))
    }

    func testSentencesAreKeptPerProfileAndTheOldestGoFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StepSummaryTests-\(UUID().uuidString)"))
        XCTAssertFalse(ChatStepSummaries.isEnabled(defaults))
        let home = "dash.default"
        for index in 0...ChatStepSummaries.savedLimit {
            ChatStepSummaries.save("Step \(index)", for: .init(scope: home, toolID: "k\(index)"), defaults: defaults)
        }
        let saved = try XCTUnwrap(ChatStepSummaries.saved(defaults)[home])
        XCTAssertEqual(saved.count, ChatStepSummaries.savedLimit)
        XCTAssertNil(saved["k0"])
        XCTAssertEqual(saved["k\(ChatStepSummaries.savedLimit)"], "Step \(ChatStepSummaries.savedLimit)")

        // The same tool call id on another profile is another run.
        ChatStepSummaries.save("Elsewhere", for: .init(scope: "dash.work", toolID: "k1"), defaults: defaults)
        ChatStepSummaries.save("Again", for: .init(scope: home, toolID: "k1"), defaults: defaults)
        let both = ChatStepSummaries.saved(defaults)
        XCTAssertEqual(both[home]?["k1"], "Again")
        XCTAssertEqual(both["dash.work"]?["k1"], "Elsewhere")
    }
}
