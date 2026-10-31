import XCTest
@testable import Conduit

/// The rows the reader opens and closes (ChatRowDisclosure), Show thinking
/// and Settings > Chat's Thinking: per conversation, apart from the
/// scroller they tell first.
extension ChatScrollStateTests {
    private func conversation(_ sessionID: String) -> ChatScrollSessionIdentity {
        ChatScrollSessionIdentity(
            profile: "p",
            canonicalSessionID: sessionID,
            equivalentSessionIDs: [sessionID],
            isReconciling: false,
            settledRevision: 0
        )
    }

    /// Rows resumed without an id are numbered from 0 in every
    /// conversation, so an opened "0-reasoning" must not open another
    /// conversation's; another spelling of the same one keeps it.
    @MainActor
    func testOpenedRowsBelongToTheirConversation() {
        let disclosure = ChatRowDisclosure()
        var current = conversation("a")
        disclosure.currentConversation = { current }
        disclosure.willToggle("0-reasoning", to: true)
        XCTAssertTrue(disclosure.isExpanded("0-reasoning", default: false))

        current = ChatScrollSessionIdentity(
            profile: "p",
            canonicalSessionID: "a-server",
            equivalentSessionIDs: ["a", "a-server"],
            isReconciling: false,
            settledRevision: 1
        )
        XCTAssertTrue(disclosure.isExpanded("0-reasoning", default: false), "same conversation, new spelling")

        current = conversation("b")
        XCTAssertFalse(disclosure.isExpanded("0-reasoning", default: false), "another conversation")
        XCTAssertTrue(disclosure.isExpanded("0-tool-0", default: true), "defaults apply there")
    }

    /// Show thinking (a run's menu or its reply's ⋯) draws that run's
    /// hidden thoughts, open, for this conversation only; Hide folds them
    /// away again.
    @MainActor
    func testShowThinkingRevealsOneRunWhileSettingsHideIt() {
        let disclosure = ChatRowDisclosure()
        var current = conversation("a")
        disclosure.currentConversation = { current }
        var preferences = ProfileDisplayPreferences()
        preferences.showReasoning = false
        let thinking = ChatMessage(id: "r", role: .reasoning, content: "Look it up", timestamp: "now")
        let search = ChatMessage(
            id: "t", role: .tool, content: "", timestamp: "now",
            tool: ToolActivity(id: "t", name: "web_search", input: nil, output: nil, status: .complete)
        )
        let group = ChatStepGroup(members: [ChatStepGroupMember(thinking), ChatStepGroupMember(search)], isTrailing: false)
        let thought = ChatStepPlacement(group: group, index: 0)
        let tool = ChatStepPlacement(group: group, index: 1)
        func draws(_ placement: ChatStepPlacement, _ id: String) -> Bool {
            placement.drawsRow(messageID: id, preferences: preferences, isBusy: false, disclosure: disclosure)
        }
        XCTAssertFalse(draws(thought, "r"), "Settings hides the thought")
        XCTAssertTrue(draws(tool, "t"))

        disclosure.willShowThinking(in: group, true)
        XCTAssertTrue(disclosure.showsThinking(in: "r"))
        XCTAssertTrue(draws(thought, "r"))
        XCTAssertTrue(draws(tool, "t"), "the run opens, so its other rows draw too")
        XCTAssertTrue(disclosure.isExpanded("r", default: false), "the thought opens on its text")

        disclosure.willShowThinking(in: group, false)
        XCTAssertFalse(draws(thought, "r"))
        XCTAssertFalse(disclosure.isGroupExpanded("r", default: false), "the run folds back as it was")
        XCTAssertFalse(disclosure.isExpanded("r", default: false), "and so does the thought")

        // A run the reader had open stays open after Hide thinking.
        disclosure.willToggleGroup("r", to: true)
        disclosure.willShowThinking(in: group, true)
        disclosure.willShowThinking(in: group, false)
        XCTAssertTrue(disclosure.isGroupExpanded("r", default: false))
        XCTAssertFalse(disclosure.isExpanded("r", default: false))

        // Thinking set to Off: no run shows its thinking, asked for or not.
        disclosure.willShowThinking(in: group, true)
        preferences.thinkingOnRequest = false
        XCTAssertFalse(preferences.offersShowThinking)
        XCTAssertFalse(draws(thought, "r"))
        preferences.thinkingOnRequest = true

        current = conversation("b")
        XCTAssertFalse(disclosure.showsThinking(in: "r"), "another conversation starts hidden")
    }

    /// A revealed run counts the steps Settings shows, or its thoughts when
    /// Settings shows none of them, never "0 steps".
    @MainActor
    func testARevealedRunCountsTheStepsItShows() {
        let thinking = ChatMessage(id: "r", role: .reasoning, content: "Look it up", timestamp: "now")
        let search = ChatMessage(
            id: "t", role: .tool, content: "", timestamp: "now",
            tool: ToolActivity(id: "t", name: "web_search", input: nil, output: nil, status: .complete)
        )
        let group = ChatStepGroup(members: [ChatStepGroupMember(thinking), ChatStepGroupMember(search)], isTrailing: false)
        func counted(showTools: Bool) -> [String] {
            group.countedMembers(showReasoning: false, thinkingShown: true, showTools: showTools).map(\.messageID)
        }
        XCTAssertEqual(counted(showTools: true), ["t"], "the tools Settings shows, the revealed thought aside")
        XCTAssertEqual(counted(showTools: false), ["r"], "with no tools shown, the revealed thought")
        XCTAssertEqual(group.countedMembers(showReasoning: false, thinkingShown: false, showTools: true).map(\.messageID), ["t"])
    }

    /// Settings > Chat's Thinking: Show is Hermes' own switch, Conduit's key
    /// tells On request from Off, and an install with the switch off keeps
    /// its Show thinking menus.
    @MainActor
    func testThinkingChoiceReadsAndWritesTwoConfigValues() {
        XCTAssertEqual(ReasoningDisplayMode(display: [:]), .show)
        XCTAssertEqual(ReasoningDisplayMode(display: ["show_reasoning": true, "conduit_thinking_on_request": false]), .show)
        XCTAssertEqual(ReasoningDisplayMode(display: ["show_reasoning": false]), .onRequest, "off before the choice maps to On request")
        XCTAssertEqual(ReasoningDisplayMode(display: ["show_reasoning": false, "conduit_thinking_on_request": false]), .off)

        for mode in ReasoningDisplayMode.allCases {
            var display: [String: Any] = ["show_reasoning": true, "conduit_thinking_on_request": false]
            mode.write(into: &display)
            XCTAssertEqual(ReasoningDisplayMode(display: display), mode)
        }
        var display: [String: Any] = ["conduit_thinking_on_request": false]
        ReasoningDisplayMode.show.write(into: &display)
        XCTAssertEqual(display["conduit_thinking_on_request"] as? Bool, false, "Show leaves Conduit's key alone")
    }
}
