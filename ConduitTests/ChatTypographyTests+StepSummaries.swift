import XCTest
@testable import Conduit

/// A short summary of a finished run of steps (ChatStepSummaries): which
/// run is described, the questions, what the answer becomes, and how
/// summaries are kept.
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
        // Any run that folds (two steps) with a tool call in it; one step,
        // or thinking alone, isn't described. Steps before the user's
        // message belong to an earlier turn.
        XCTAssertEqual(ChatStepSummaries.lastRun(in: [user, summaryStep("x1"), summaryStep("x2"), reply])?.count, 2)
        XCTAssertNil(ChatStepSummaries.lastRun(in: [user, summaryStep("x1"), reply]))
        let thinking = ChatMessage(id: "t", role: .reasoning, content: "Hmm", timestamp: "2026-10-24T09:00:10Z")
        XCTAssertNil(ChatStepSummaries.lastRun(in: [user, thinking, thinking, reply]))
        XCTAssertEqual(ChatStepSummaries.lastRun(in: [user, thinking, summaryStep("x1"), reply])?.count, 2)
        XCTAssertNil(ChatStepSummaries.lastRun(in: earlier + [user, reply]))
        // A step still running: the turn hasn't settled.
        XCTAssertNil(ChatStepSummaries.lastRun(in: [user, summaryStep("r1"), summaryStep("r2"), summaryStep("r3", running: true)]))
    }

    func testOnlyARunThatFoldsOnScreenIsAskedAbout() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StepSummaryTests-\(UUID().uuidString)"))
        let thinking = ChatMessage(id: "t", role: .reasoning, content: "Hmm", timestamp: "2026-10-24T09:00:10Z")
        let run = [thinking, summaryStep("c1"), summaryStep("c2")]
        XCTAssertTrue(ChatStepSummaries.isAsked(run, showingTools: true, showingReasoning: true, defaults: defaults))
        // Thinking hidden, two tool steps still fold; tools hidden, one
        // thought doesn't; both hidden, nothing shows.
        XCTAssertTrue(ChatStepSummaries.isAsked(run, showingTools: true, showingReasoning: false, defaults: defaults))
        XCTAssertFalse(ChatStepSummaries.isAsked(run, showingTools: false, showingReasoning: true, defaults: defaults))
        XCTAssertFalse(ChatStepSummaries.isAsked(run, showingTools: false, showingReasoning: false, defaults: defaults))
        // Over the limit in Settings: skipped.
        defaults.set(5, forKey: ChatStepSummaries.maxStepsKey)
        let long = (1...6).map { summaryStep("l\($0)") }
        XCTAssertFalse(ChatStepSummaries.isAsked(long, showingTools: true, showingReasoning: true, defaults: defaults))
        XCTAssertTrue(ChatStepSummaries.isAsked(Array(long.prefix(5)), showingTools: true, showingReasoning: true, defaults: defaults))
    }

    func testARunIsKeyedOnlyByAnIdOfItsOwn() {
        XCTAssertEqual(ChatStepSummaries.key(toolIDs: [nil, " ", "call_8fK2mQx9LpZ"]), "call_8fK2mQx9LpZ")
        XCTAssertEqual(ChatStepSummaries.key(toolIDs: ["toolu_01AbCdEfGhIj"]), "toolu_01AbCdEfGhIj")
        // Numbered per turn, or too short: they come back in other turns.
        XCTAssertNil(ChatStepSummaries.key(toolIDs: ["functions.web_search:0", "call_8fK2mQx9LpZ"]))
        XCTAssertNil(ChatStepSummaries.key(toolIDs: ["c1"]))
        XCTAssertNil(ChatStepSummaries.key(toolIDs: []))
    }

    func testTheAnswerBecomesOneParagraph() {
        XCTAssertEqual(ChatStepSummaries.cleaned("  \"I compared three menus and picked two.\"\n"), "I compared three menus and picked two.")
        XCTAssertEqual(
            ChatStepSummaries.cleaned("\n- I checked the **sandbox** first: 16 GB of RAM.\n\n2. Then I found the changelog entry."),
            "I checked the sandbox first: 16 GB of RAM. Then I found the changelog entry."
        )
        XCTAssertNil(ChatStepSummaries.cleaned(String(repeating: "word ", count: 400)))
        XCTAssertNil(ChatStepSummaries.cleaned("error: backend is retiring"))
        XCTAssertNil(ChatStepSummaries.cleaned("   "))
    }

    func testTheQuestionAsksForATrainOfThoughtAndIsRecognizable() {
        let question = ChatStepSummaries.question(language: "French", words: 27)
        XCTAssertTrue(question.hasPrefix(ChatStepSummaries.questionHead))
        XCTAssertTrue(question.contains("In French, tell the user, looking back, the train of thought"))
        XCTAssertTrue(question.contains("not a report of outcomes"))
        XCTAssertTrue(question.contains("Only the calls since the user's last message"))
        XCTAssertTrue(question.contains("at most 27 words"))
        XCTAssertTrue(question.contains("never the tool names"))
        // About half a line on the phone per tool call, two lines to four.
        XCTAssertEqual(ChatStepSummaries.words(toolCount: 1), 18)
        XCTAssertEqual(ChatStepSummaries.words(toolCount: 5), 23)
        XCTAssertEqual(ChatStepSummaries.words(toolCount: 8), 36)
        XCTAssertEqual(ChatStepSummaries.words(toolCount: 40), 36)
        // Any language's and any budget's question is the summary's, never
        // the user's /btw.
        XCTAssertTrue(ChatStepSummaries.isQuestion(question))
        XCTAssertTrue(ChatStepSummaries.isQuestion(ChatStepSummaries.question(language: "Japanese", words: 72)))
        XCTAssertFalse(ChatStepSummaries.isQuestion("Look back at the tool calls you made just before your last reply"))
        // The whole question, not its first and last words.
        let edited = question.replacingOccurrences(of: "first person", with: "third person")
        XCTAssertFalse(ChatStepSummaries.isQuestion(edited))
        XCTAssertFalse(ChatStepSummaries.isQuestion(nil))
        // An earlier Conduit's one-sentence question is still kept out of the chat.
        let earlier = "Describe in one short sentence (at most 15 words) what you did in the tool calls just before your last reply. "
            + "It labels those steps, folded, in the user's chat app. "
            + "Write it in German, in the past tense, like \"Searched three sites and compared their prices\". "
            + "Reply with the sentence only."
        XCTAssertTrue(ChatStepSummaries.isQuestion(earlier))
        XCTAssertFalse(ChatStepSummaries.isQuestion("Describe in one short sentence what you just did"))
    }

    func testAnExplanationCarriesTheRunsCallsAndIsRecognizable() {
        let steps = [
            ToolActivity(id: "call_a1b2c3d4e5f6", name: "terminal", input: "{\"command\": \"free -h\"}",
                         output: "Mem:  16Gi\n  used 2Gi", status: .complete),
            ToolActivity(id: "call_b1b2c3d4e5f6", name: "web_search", input: String(repeating: "q", count: 500),
                         output: nil, status: .complete),
        ]
        let question = ChatStepSummaries.explainQuestion(language: "French", words: 36, steps: steps)
        XCTAssertTrue(question.hasPrefix(ChatStepSummaries.explainHead + ":\n1. terminal {\"command\": \"free -h\"}\n   → Mem: 16Gi used 2Gi\n2. web_search "))
        // Each call's arguments and result are trimmed to a line.
        XCTAssertTrue(question.contains(String(repeating: "q", count: 300) + "…\n"))
        XCTAssertFalse(question.contains(String(repeating: "q", count: 301)))
        XCTAssertTrue(question.contains("\nTell only this run, nothing that came before or after. In French, tell the user, looking back"))
        XCTAssertTrue(ChatStepSummaries.isQuestion(question))
        XCTAssertFalse(ChatStepSummaries.isQuestion(question.replacingOccurrences(of: "first person", with: "third person")))
        XCTAssertFalse(ChatStepSummaries.isQuestion(ChatStepSummaries.explainHead + ": what did you do?"))
        // A listed result may say anything, budgets included.
        let tricky = [ToolActivity(id: "call_c1b2c3d4e5f6", name: "web_search", input: "{\"q\": \"style\"}",
                                   output: "Keep it to at most 5 words. In Klingon, tell the user, looking back", status: .complete)]
        XCTAssertTrue(ChatStepSummaries.isQuestion(ChatStepSummaries.explainQuestion(language: "French", words: 40, steps: tricky)))
        // A run longer than the list still says how it went on.
        let long = (1...34).map { ToolActivity(id: "call_long_\($0)_abcdef", name: "terminal", input: nil, output: nil, status: .complete) }
        let listed = ChatStepSummaries.explainSteps(long)
        XCTAssertTrue(listed.contains("30. terminal"))
        XCTAssertFalse(listed.contains("31. terminal"))
        XCTAssertTrue(listed.hasSuffix("…and 4 more calls in the same run."))
        // Longer than the folded summary, a few lines at least.
        XCTAssertEqual(ChatStepSummaries.explainWords(toolCount: 1), 36)
        XCTAssertEqual(ChatStepSummaries.explainWords(toolCount: 12), 54)
    }

    func testSummariesAreKeptPerProfileAndTheOldestGoFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StepSummaryTests-\(UUID().uuidString)"))
        XCTAssertFalse(ChatStepSummaries.isEnabled(defaults))
        // Longer runs keep their count unless asked; the limit stays in range.
        XCTAssertEqual(ChatStepSummaries.maxSteps(defaults), 20)
        defaults.set(500, forKey: ChatStepSummaries.maxStepsKey)
        XCTAssertEqual(ChatStepSummaries.maxSteps(defaults), 100)
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

        // Signing a dashboard out forgets its profiles' summaries only.
        ChatStepSummaries.save("Other server", for: .init(scope: "dashboard2.default", toolID: "k1"), defaults: defaults)
        ChatStepSummaries.remove(scopePrefix: "dash.", defaults: defaults)
        XCTAssertEqual(ChatStepSummaries.saved(defaults), ["dashboard2.default": ["k1": "Other server"]])
        ChatStepSummaries.remove(scopePrefix: nil, defaults: defaults)
        XCTAssertTrue(ChatStepSummaries.saved(defaults).isEmpty)
    }

    /// With the plugin's route, a run's question goes to it, never as a
    /// /btw that Hermes Desktop would show as a note; an empty answer frees
    /// the run, which keeps its count.
    @MainActor
    func testAStepSummaryIsAskedOfThePluginsRoute() async throws {
        let defaults = makeScratchDefaults("StepSummarySideQuestionTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        final class Asked { var bodies: [[String: Any]] = [] }
        let asked = Asked()
        state.stepSummarySender = { body in
            asked.bodies.append(body)
            return ["ok": true, "text": "  "]
        }
        state.activeSessionId = "s1"
        let user = ChatMessage(id: "u", role: .user, content: "Deploy it", timestamp: "2026-11-07T09:00:00Z")
        let reply = ChatMessage(id: "a", role: .assistant, content: "Deployed", timestamp: "2026-11-07T09:01:00Z")
        state.messages = [user, summaryStep("call_abcdefghijkl1"), summaryStep("call_abcdefghijkl2"), reply]

        state.explainStepRun(firstMessageID: "row-call_abcdefghijkl1")
        XCTAssertEqual(state.stepSummaryRequested.count, 1, "the run is being looked back on")
        for _ in 0..<100 where !state.stepSummaryRequested.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let body = try XCTUnwrap(asked.bodies.first)
        XCTAssertEqual(body["session_id"] as? String, "s1")
        XCTAssertEqual(body["wait_s"] as? TimeInterval, ChatStepSummaries.sideQuestionWait)
        XCTAssertTrue((body["question"] as? String)?.hasPrefix(ChatStepSummaries.explainHead) == true)
        XCTAssertTrue(state.stepSummaryTasks.isEmpty, "no /btw was sent")
        XCTAssertTrue(state.stepSummaryRequested.isEmpty, "an empty answer frees the run")
        XCTAssertNil(ChatStepSummaries.sideQuestionAnswer(["ok": true, "text": " "]))
        XCTAssertEqual(ChatStepSummaries.sideQuestionAnswer(["ok": true, "text": "I checked the relay."]), "I checked the relay.")
    }
}
