import Foundation
import XCTest
@testable import Conduit

/// Tests that StreamEventParser correctly translates raw gateway JSON-RPC
/// stream events into typed StreamEvent values. This is the gateway-to-app
/// boundary — every chat message, tool call, and reasoning delta flows
/// through this parser.
final class StreamEventParserTests: XCTestCase {

    // MARK: - Helpers

    /// Build an AnyCodable from a JSON string, simulating what
    /// HermesClient.handleMessage feeds into the parser.
    private func parse(_ json: String) -> StreamEvent? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Invalid JSON: \(json)")
            return nil
        }
        return StreamEventParser.parse(params: AnyCodable.from(obj))
    }

    // MARK: - message.start

    func testMessageStart() {
        let event = parse(#"""
        {"type": "message.start", "session_id": "sess-123"}
        """#)
        guard case .messageStart(let sessionId) = event else {
            return XCTFail("Expected messageStart, got \(String(describing: event))")
        }
        XCTAssertEqual(sessionId, "sess-123")
    }

    // MARK: - message.delta

    func testMessageDeltaWithPayloadText() {
        let event = parse(#"""
        {"type": "message.delta", "session_id": "s1", "payload": {"text": "Hello"}}
        """#)
        guard case .messageDelta(let sessionId, let text) = event else {
            return XCTFail("Expected messageDelta")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(text, "Hello")
    }

    func testMessageDeltaWithTopLevelText() {
        let event = parse(#"""
        {"type": "message.delta", "session_id": "s1", "text": "World"}
        """#)
        guard case .messageDelta(_, let text) = event else {
            return XCTFail("Expected messageDelta")
        }
        XCTAssertEqual(text, "World")
    }

    func testMessageDeltaWithEmptyTextReturnsNil() {
        let event = parse(#"""
        {"type": "message.delta", "session_id": "s1", "payload": {"text": ""}}
        """#)
        XCTAssertNil(event, "Empty delta should not produce an event")
    }

    // MARK: - reasoning.delta

    func testReasoningDeltaPrefersReasoningField() {
        let event = parse(#"""
        {"type": "reasoning.delta", "session_id": "s1", "payload": {"reasoning": "thinking..."}}
        """#)
        guard case .reasoningDelta(_, let text) = event else {
            return XCTFail("Expected reasoningDelta")
        }
        XCTAssertEqual(text, "thinking...")
    }

    func testReasoningDeltaFallsBackToReasoningContent() {
        let event = parse(#"""
        {"type": "reasoning.delta", "session_id": "s1", "payload": {"reasoning_content": "deep thoughts"}}
        """#)
        guard case .reasoningDelta(_, let text) = event else {
            return XCTFail("Expected reasoningDelta")
        }
        XCTAssertEqual(text, "deep thoughts")
    }

    func testReasoningDeltaFallsBackToTopLevelText() {
        let event = parse(#"""
        {"type": "message.reasoning", "session_id": "s1", "text": "top-level thought"}
        """#)
        guard case .reasoningDelta(_, let text) = event else {
            return XCTFail("Expected reasoningDelta")
        }
        XCTAssertEqual(text, "top-level thought")
    }

    func testReasoningDeltaEmptyReturnsNil() {
        let event = parse(#"""
        {"type": "reasoning.delta", "session_id": "s1", "payload": {}}
        """#)
        XCTAssertNil(event)
    }

    // MARK: - message.complete

    func testMessageCompleteWithAllFields() {
        let event = parse(#"""
        {"type": "message.complete", "session_id": "s1", "payload": {"message_id": "msg-42", "content": "Final answer", "reasoning": "because"}}
        """#)
        guard case .messageComplete(let sessionId, let messageId, let content, let reasoning, _) = event else {
            return XCTFail("Expected messageComplete")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(messageId, "msg-42")
        XCTAssertEqual(content, "Final answer")
        XCTAssertEqual(reasoning, "because")
    }

    /// `response_previewed` / `response_reused` say the final text is one an
    /// interim already delivered.
    func testMessageCompleteReadsAlreadyShownFlags() {
        for (flags, expected) in [
            ("", false),
            (#", "response_previewed": true"#, true),
            (#", "response_reused": true"#, true),
            (#", "response_previewed": false, "response_reused": false"#, false),
        ] {
            let event = parse(#"""
            {"type": "message.complete", "session_id": "s1", "payload": {"text": "Done"\#(flags)}}
            """#)
            guard case .messageComplete(_, _, let content, _, let alreadyShown) = event else {
                return XCTFail("Expected messageComplete for \(flags)")
            }
            XCTAssertEqual(content, "Done")
            XCTAssertEqual(alreadyShown, expected, flags)
        }
    }

    // MARK: - message.interim

    func testMessageInterimCarriesAlreadyStreamed() {
        guard case .messageInterim(let sessionId, let text, let streamed) = parse(#"""
        {"type": "message.interim", "session_id": "s1", "payload": {"text": "Checking the logs.", "already_streamed": true}}
        """#) else { return XCTFail("Expected messageInterim") }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(text, "Checking the logs.")
        XCTAssertTrue(streamed)

        guard case .messageInterim(_, _, let unstreamed) = parse(#"""
        {"type": "message.interim", "session_id": "s1", "payload": {"text": "Commentary", "already_streamed": false}}
        """#) else { return XCTFail("Expected messageInterim") }
        XCTAssertFalse(unstreamed)
    }

    func testEmptyMessageInterimIsIgnored() {
        XCTAssertNil(parse(#"""
        {"type": "message.interim", "session_id": "s1", "payload": {"text": "  ", "already_streamed": false}}
        """#))
    }

    func testMessageCompleteFallsBackToIdField() {
        let event = parse(#"""
        {"type": "message.complete", "session_id": "s1", "payload": {"id": "alt-id"}}
        """#)
        guard case .messageComplete(_, let messageId, _, _, _) = event else {
            return XCTFail("Expected messageComplete")
        }
        XCTAssertEqual(messageId, "alt-id")
    }

    func testMessageCompleteFallsBackToRenderedField() {
        let event = parse(#"""
        {"type": "message.complete", "session_id": "s1", "payload": {"rendered": "<p>html</p>"}}
        """#)
        guard case .messageComplete(_, _, let content, _, _) = event else {
            return XCTFail("Expected messageComplete")
        }
        XCTAssertEqual(content, "<p>html</p>")
    }

    // MARK: - error

    func testErrorWithMessage() {
        let event = parse(#"""
        {"type": "error", "session_id": "s1", "payload": {"message": "Rate limited"}}
        """#)
        guard case .messageError(_, let message) = event else {
            return XCTFail("Expected messageError")
        }
        XCTAssertEqual(message, "Rate limited")
    }

    func testErrorWithoutMessageUsesDefault() {
        let event = parse(#"""
        {"type": "error", "session_id": "s1", "payload": {}}
        """#)
        guard case .messageError(_, let message) = event else {
            return XCTFail("Expected messageError")
        }
        XCTAssertEqual(message, "Hermes reported an error.")
    }

    // MARK: - session.busy

    func testSessionBusyTrue() {
        let event = parse(#"""
        {"type": "session.busy", "session_id": "s1", "payload": {"busy": true}}
        """#)
        guard case .sessionBusy(_, let busy) = event else {
            return XCTFail("Expected sessionBusy")
        }
        XCTAssertTrue(busy)
    }

    func testSessionBusyDefaultsFalse() {
        let event = parse(#"""
        {"type": "session.busy", "session_id": "s1", "payload": {}}
        """#)
        guard case .sessionBusy(_, let busy) = event else {
            return XCTFail("Expected sessionBusy")
        }
        XCTAssertFalse(busy)
    }

    // MARK: - session.title

    func testSessionTitleValid() {
        let event = parse(#"""
        {"type": "session.title", "session_id": "runtime-1", "payload": {"session_id": "stored-1", "title": "My Chat"}}
        """#)
        guard case .sessionTitle(let runtimeId, let storedId, let title) = event else {
            return XCTFail("Expected sessionTitle")
        }
        XCTAssertEqual(runtimeId, "runtime-1")
        XCTAssertEqual(storedId, "stored-1")
        XCTAssertEqual(title, "My Chat")
    }

    func testSessionTitleEmptySessionIdReturnsNil() {
        let event = parse(#"""
        {"type": "session.title", "session_id": "s1", "payload": {"session_id": "", "title": "X"}}
        """#)
        XCTAssertNil(event)
    }

    func testSessionTitleWhitespaceTrimmed() {
        let event = parse(#"""
        {"type": "session.title", "session_id": "s1", "payload": {"session_id": "s2", "title": "  Spaced  "}}
        """#)
        guard case .sessionTitle(_, _, let title) = event else {
            return XCTFail("Expected sessionTitle")
        }
        XCTAssertEqual(title, "Spaced")
    }

    // MARK: - tool.start

    func testToolStartWithArgsText() {
        let event = parse(#"""
        {"type": "tool.start", "session_id": "s1", "payload": {"name": "web_search", "args_text": "query=test"}}
        """#)
        guard case .toolStart(_, let toolName, let toolInput, _) = event else {
            return XCTFail("Expected toolStart")
        }
        XCTAssertEqual(toolName, "web_search")
        XCTAssertEqual(toolInput, "query=test")
    }

    func testToolStartWithInputField() {
        let event = parse(#"""
        {"type": "tool.start", "session_id": "s1", "payload": {"name": "terminal", "input": "ls -la"}}
        """#)
        guard case .toolStart(_, _, let toolInput, _) = event else {
            return XCTFail("Expected toolStart")
        }
        XCTAssertEqual(toolInput, "ls -la")
    }

    func testToolStartWithObjectArgs() {
        let event = parse(#"""
        {"type": "tool_call", "session_id": "s1", "payload": {"name": "terminal", "arguments": {"command": "pwd"}}}
        """#)
        guard case .toolStart(_, _, let toolInput, _) = event else {
            return XCTFail("Expected toolStart")
        }
        XCTAssertNotNil(toolInput)
        XCTAssertTrue(toolInput!.contains("command"))
    }

    func testToolLifecycleParsesTrimmedStableToolID() {
        let start = parse(#"""
        {"type": "tool.start", "session_id": "s1", "payload": {"tool_id": " tool-1 ", "name": "terminal"}}
        """#)
        guard case .toolStart(_, _, _, let startID) = start else {
            return XCTFail("Expected toolStart")
        }
        XCTAssertEqual(startID, "tool-1")

        let completion = parse(#"""
        {"type": "tool.complete", "session_id": "s1", "payload": {"tool_id": "tool-1", "name": "terminal", "result": "done"}}
        """#)
        guard case .toolComplete(_, _, _, let completionID) = completion else {
            return XCTFail("Expected toolComplete")
        }
        XCTAssertEqual(completionID, "tool-1")
    }

    func testToolLifecycleMissingOrBlankToolIDRemainsNil() {
        let event = parse(#"""
        {"type": "tool.start", "session_id": "s1", "payload": {"tool_id": "  ", "name": "terminal"}}
        """#)
        guard case .toolStart(_, _, _, let toolID) = event else {
            return XCTFail("Expected toolStart")
        }
        XCTAssertNil(toolID)
    }

    // MARK: - tool.complete

    func testToolCompleteWithOutput() {
        let event = parse(#"""
        {"type": "tool.complete", "session_id": "s1", "payload": {"name": "terminal", "output": "done"}}
        """#)
        guard case .toolComplete(_, let toolName, let toolOutput, _) = event else {
            return XCTFail("Expected toolComplete")
        }
        XCTAssertEqual(toolName, "terminal")
        XCTAssertEqual(toolOutput, "done")
    }

    func testToolCompleteFallsBackToResult() {
        let event = parse(#"""
        {"type": "tool_result", "session_id": "s1", "payload": {"name": "search", "result": "found"}}
        """#)
        guard case .toolComplete(_, _, let toolOutput, _) = event else {
            return XCTFail("Expected toolComplete")
        }
        XCTAssertEqual(toolOutput, "found")
    }

    // MARK: - context.update

    func testContextUpdate() {
        let event = parse(#"""
        {"type": "context.update", "session_id": "s1", "payload": {"context_percent": 45.5, "context_used": 1000, "context_max": 2000}}
        """#)
        guard case .contextUpdate(_, let percent, let used, let max) = event else {
            return XCTFail("Expected contextUpdate")
        }
        XCTAssertEqual(percent, 45.5)
        XCTAssertEqual(used, 1000)
        XCTAssertEqual(max, 2000)
    }

    func testContextUpdateDefaultsToZero() {
        let event = parse(#"""
        {"type": "context.update", "session_id": "s1", "payload": {}}
        """#)
        guard case .contextUpdate(_, let percent, let used, let max) = event else {
            return XCTFail("Expected contextUpdate")
        }
        XCTAssertEqual(percent, 0.0)
        XCTAssertEqual(used, 0)
        XCTAssertEqual(max, 0)
    }

    // MARK: - background.complete / btw.complete

    func testSideAgentCompletions() {
        guard case .sideAgentComplete(let sessionId, let kind, let taskId, let text, let question) = parse(#"""
        {"type": "btw.complete", "session_id": "s1", "payload": {"task_id": "btw_1a2b3c", "question": "what did we decide?", "text": "Ship on Friday."}}
        """#) else { return XCTFail("Expected sideAgentComplete") }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(kind, .btw)
        XCTAssertEqual(taskId, "btw_1a2b3c")
        XCTAssertEqual(text, "Ship on Friday.")
        XCTAssertEqual(question, "what did we decide?")

        guard case .sideAgentComplete(_, let bgKind, let bgTask, let bgText, let bgQuestion) = parse(#"""
        {"type": "background.complete", "session_id": "s1", "payload": {"task_id": "bg_4d5e6f", "text": "error: boom"}}
        """#) else { return XCTFail("Expected sideAgentComplete") }
        XCTAssertEqual(bgKind, .background)
        XCTAssertEqual(bgTask, "bg_4d5e6f")
        XCTAssertEqual(bgText, "error: boom")
        XCTAssertNil(bgQuestion)

        XCTAssertNil(parse(#"""
        {"type": "btw.complete", "session_id": "s1", "payload": {"task_id": "btw_1", "text": "  "}}
        """#))
    }

    // MARK: - session.usage

    /// Hermes pushes live usage as `session.usage` once a second during a
    /// turn, with the context fields nested under `payload.usage`.
    func testSessionUsageMapsNestedContextFields() {
        let event = parse(#"""
        {"type": "session.usage", "session_id": "s1", "payload": {"usage": {"model": "m", "input": 900, "output": 40, "context_used": 45000, "context_max": 100000, "context_percent": 45, "context_source": "provider_usage"}}}
        """#)
        guard case .contextUpdate(let sessionId, let percent, let used, let max) = event else {
            return XCTFail("Expected contextUpdate, got \(String(describing: event))")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(percent, 45)
        XCTAssertEqual(used, 45000)
        XCTAssertEqual(max, 100000)
    }

    /// Hermes omits the context fields while the window is unknown (no
    /// compressor yet, or nothing sent): that must not zero the meter.
    func testSessionUsageWithoutContextFieldsIsIgnored() {
        XCTAssertNil(parse(#"""
        {"type": "session.usage", "session_id": "s1", "payload": {"usage": {"model": "m", "input": 0, "output": 0, "calls": 0}}}
        """#))
        XCTAssertNil(parse(#"""
        {"type": "session.usage", "session_id": "s1", "payload": {"usage": {"context_used": 10, "context_max": 0, "context_percent": 0}}}
        """#))
    }

    /// Hermes' `context_percent` is 0-100, so a session at 1% of a large
    /// window must read 1%, not a full meter.
    @MainActor
    func testSessionUsageAtOnePercentDoesNotFillTheMeter() throws {
        let suite = "StreamEventParserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        let event = try XCTUnwrap(parse(#"""
        {"type": "session.usage", "session_id": "s1", "payload": {"usage": {"context_used": 10000, "context_max": 1000000, "context_percent": 1}}}
        """#))

        state.handleStreamEvent(event)

        XCTAssertEqual(state.runtime.contextUsed, 10000)
        XCTAssertEqual(state.runtime.contextMax, 1_000_000)
        XCTAssertEqual(state.runtime.contextPercent, 1, accuracy: 0.001)
    }

    // MARK: - cwd.update

    func testCwdUpdate() {
        let event = parse(#"""
        {"type": "cwd.update", "session_id": "s1", "payload": {"cwd": "/home/user/project"}}
        """#)
        guard case .cwdUpdate(_, let cwd) = event else {
            return XCTFail("Expected cwdUpdate")
        }
        XCTAssertEqual(cwd, "/home/user/project")
    }

    // MARK: - model.update

    func testModelUpdate() {
        let event = parse(#"""
        {"type": "model.update", "session_id": "s1", "payload": {"model": "gpt-4", "provider": "openai"}}
        """#)
        guard case .modelUpdate(_, let model, let provider) = event else {
            return XCTFail("Expected modelUpdate")
        }
        XCTAssertEqual(model, "gpt-4")
        XCTAssertEqual(provider, "openai")
    }

    // MARK: - interrupted

    func testMessageInterrupted() {
        let event = parse(#"""
        {"type": "message.interrupted", "session_id": "s1"}
        """#)
        if case .messageInterrupted(let sessionId) = event {
            XCTAssertEqual(sessionId, "s1")
        } else {
            XCTFail("Expected messageInterrupted")
        }
    }

    func testSessionInterrupted() {
        let event = parse(#"""
        {"type": "session.interrupted", "session_id": "s1"}
        """#)
        if case .messageInterrupted = event {} else {
            XCTFail("Expected messageInterrupted for session.interrupted")
        }
    }

    // MARK: - session.info

    func testSessionInfoWithRunningSnapshot() {
        let event = parse(#"""
        {"type": "session.info", "session_id": "s1", "payload": {"running": true, "model": "test-model"}}
        """#)
        guard case .sessionInfo(let sessionId, let snapshot) = event else {
            return XCTFail("Expected sessionInfo")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(snapshot.running, true)
        XCTAssertEqual(snapshot.model, "test-model")
    }

    func testSessionInfoWithEmptyPayload() {
        let event = parse(#"""
        {"type": "session.info", "session_id": "s1", "payload": {}}
        """#)
        guard case .sessionInfo(_, let snapshot) = event else {
            return XCTFail("Expected sessionInfo")
        }
        XCTAssertNil(snapshot.running)
    }

    // MARK: - subagent events

    func testSubagentSpawn() {
        let event = parse(#"""
        {"type": "subagent.spawn", "session_id": "s1", "payload": {"id": "agent-1", "goal": "Fix the bug", "task_count": 3}}
        """#)
        guard case .delegateAgent(_, let activity) = event else {
            return XCTFail("Expected delegateAgent")
        }
        XCTAssertEqual(activity.id, "agent-1")
        XCTAssertEqual(activity.goal, "Fix the bug")
        XCTAssertEqual(activity.status, .queued)
        XCTAssertEqual(activity.taskCount, 3)
    }

    func testSubagentComplete() {
        let event = parse(#"""
        {"type": "subagent.complete", "session_id": "s1", "payload": {"id": "agent-1", "summary": "Done"}}
        """#)
        guard case .delegateAgent(_, let activity) = event else {
            return XCTFail("Expected delegateAgent")
        }
        XCTAssertEqual(activity.status, .completed)
        XCTAssertEqual(activity.summary, "Done")
    }

    func testSubagentFail() {
        let event = parse(#"""
        {"type": "subagent.fail", "session_id": "s1", "payload": {"id": "agent-1"}}
        """#)
        guard case .delegateAgent(_, let activity) = event else {
            return XCTFail("Expected delegateAgent")
        }
        XCTAssertEqual(activity.status, .failed)
    }

    /// #492: Hermes names the agent `subagent_id` on every event, so its
    /// start, tool and complete events land on one card that ends Completed.
    func testSubagentEventsShareHermesSubagentID() {
        let frames = [
            #"{"type": "subagent.start", "session_id": "s1", "payload": {"goal": "Check requests", "task_count": 1, "task_index": 0, "subagent_id": "sa-0-abc", "model": "m1", "text": "Check requests"}}"#,
            #"{"type": "subagent.tool", "session_id": "s1", "payload": {"goal": "Check requests", "task_count": 1, "task_index": 0, "subagent_id": "sa-0-abc", "tool_name": "skill_view", "text": "SKILL.md"}}"#,
            #"{"type": "subagent.complete", "session_id": "s1", "payload": {"goal": "Check requests", "task_count": 1, "task_index": 0, "subagent_id": "sa-0-abc", "status": "completed", "summary": "Both approved"}}"#,
        ]
        let activities: [DelegateAgentActivity] = frames.compactMap {
            guard case .delegateAgent(_, let activity) = parse($0) else { return nil }
            return activity
        }
        XCTAssertEqual(activities.count, 3)
        XCTAssertEqual(Set(activities.map(\.id)), ["sa-0-abc"])
        XCTAssertTrue(activities.allSatisfy(\.hasGatewayID))
        XCTAssertEqual(activities[1].currentTool, "skill_view")

        let card = activities.dropFirst().reduce(activities[0]) { $0.merged(with: $1) }
        XCTAssertEqual(card.status, .completed)
        XCTAssertNil(card.currentTool)
        XCTAssertEqual(card.model, "m1")
        XCTAssertEqual(card.summary, "Both approved")
        XCTAssertEqual(card.stream.map(\.text), ["Check requests", "SKILL.md", "Both approved"])
    }

    func testSubagentWithoutIDKeysOnGoalAndSlot() {
        let first = parse(#"{"type": "subagent.tool", "session_id": "s1", "payload": {"goal": "Research", "task_index": 1, "text": "web_search"}}"#)
        let second = parse(#"{"type": "subagent.progress", "session_id": "s1", "payload": {"goal": "Research", "task_index": 1, "text": "2 tools"}}"#)
        guard case .delegateAgent(_, let a) = first, case .delegateAgent(_, let b) = second else {
            return XCTFail("Expected delegateAgent")
        }
        XCTAssertEqual(a.id, b.id)
        XCTAssertFalse(a.hasGatewayID)

        let otherChat = parse(#"{"type": "subagent.tool", "session_id": "s2", "payload": {"goal": "Research", "task_index": 1, "text": "web_search"}}"#)
        guard case .delegateAgent(_, let c) = otherChat else { return XCTFail("Expected delegateAgent") }
        XCTAssertNotEqual(a.id, c.id)
    }

    func testSubagentWithDelegationIDKeysWithoutGoal() {
        let first = parse(#"{"type": "subagent.start", "session_id": "s1", "payload": {"delegation_id": "d1", "task_index": 2, "goal": "Research"}}"#)
        let second = parse(#"{"type": "subagent.tool", "session_id": "s1", "payload": {"delegation_id": "d1", "task_index": 2, "goal": ""}}"#)
        guard case .delegateAgent(_, let a) = first, case .delegateAgent(_, let b) = second else {
            return XCTFail("Expected delegateAgent")
        }
        XCTAssertEqual(a.id, b.id)
    }

    func testEmptySubagentIDIsNotAGatewayID() {
        let event = parse(#"{"type": "subagent.tool", "session_id": "s1", "payload": {"subagent_id": "", "goal": "Research", "task_index": 0}}"#)
        guard case .delegateAgent(_, let activity) = event else { return XCTFail("Expected delegateAgent") }
        XCTAssertFalse(activity.hasGatewayID)
        XCTAssertFalse(activity.id.isEmpty)
    }

    func testSubagentErrorAndTimeoutAreFailures() {
        for status in ["error", "timeout"] {
            let event = parse(#"{"type": "subagent.complete", "session_id": "s1", "payload": {"subagent_id": "a", "goal": "g", "status": "\#(status)"}}"#)
            guard case .delegateAgent(_, let activity) = event else {
                return XCTFail("Expected delegateAgent")
            }
            XCTAssertEqual(activity.status, .failed, status)
        }
    }

    func testSubagentCompleteWithUnknownStatusEnds() {
        let event = parse(#"{"type": "subagent.complete", "session_id": "s1", "payload": {"subagent_id": "a", "goal": "g", "status": "cancelled"}}"#)
        guard case .delegateAgent(_, let activity) = event else { return XCTFail("Expected delegateAgent") }
        XCTAssertEqual(activity.status, .completed)

        let failed = parse(#"{"type": "subagent.fail", "session_id": "s1", "payload": {"subagent_id": "a", "goal": "g", "status": "cancelled"}}"#)
        guard case .delegateAgent(_, let failedActivity) = failed else { return XCTFail("Expected delegateAgent") }
        XCTAssertEqual(failedActivity.status, .failed)
    }

    func testSubagentWithoutAnyKeyStillSharesACard() {
        let first = parse(#"{"type": "subagent.tool", "session_id": "s1", "payload": {"text": "a"}}"#)
        let second = parse(#"{"type": "subagent.tool", "session_id": "s1", "payload": {"text": "b", "model": ""}}"#)
        guard case .delegateAgent(_, let a) = first, case .delegateAgent(_, let b) = second else {
            return XCTFail("Expected delegateAgent")
        }
        XCTAssertEqual(a.id, b.id)
        XCTAssertNil(b.model)
    }

    func testFirstReportedEndWins() {
        let done = DelegateAgentActivity(id: "a", goal: "g", status: .completed, taskCount: 1, taskIndex: 0, stream: [])
        let lateFail = DelegateAgentActivity(id: "a", goal: "g", status: .failed, taskCount: 1, taskIndex: 0, stream: [])
        XCTAssertEqual(done.merged(with: lateFail).status, .completed)
        XCTAssertEqual(lateFail.merged(with: done).status, .failed)

        let running = DelegateAgentActivity(id: "a", goal: "g", status: .running, taskCount: 1, taskIndex: 0, stream: [])
        let lateSpawn = DelegateAgentActivity(id: "a", goal: "g", status: .queued, taskCount: 1, taskIndex: 0, stream: [])
        XCTAssertEqual(running.merged(with: lateSpawn).status, .running)
    }

    func testFinishedSubagentStaysFinishedOnLateProgress() {
        let done = DelegateAgentActivity(id: "a", goal: "g", status: .completed, taskCount: 1, taskIndex: 0, stream: [])
        let late = DelegateAgentActivity(id: "a", goal: "", status: .running, taskCount: 1, taskIndex: 0, currentTool: "terminal", stream: [])
        let merged = done.merged(with: late)
        XCTAssertEqual(merged.status, .completed)
        XCTAssertNil(merged.currentTool)
        XCTAssertEqual(merged.goal, "g")
    }

    func testRosterFinishesAgentsHermesNoLongerRuns() {
        let old = Date(timeIntervalSince1970: 100)
        let cutoff = Date(timeIntervalSince1970: 200)
        func agent(_ id: String, session: String = "s1", gatewayID: Bool = true, at date: Date = old) -> DelegateAgentActivity {
            DelegateAgentActivity(id: id, goal: id, status: .running, taskCount: 1, taskIndex: 0, stream: [],
                                  hasGatewayID: gatewayID, sessionId: session, updatedAt: date)
        }
        let agents = [
            agent("ended"),
            agent("live"),
            agent("other-session", session: "s2"),
            agent("legacy", gatewayID: false),
            agent("fresh", at: Date(timeIntervalSince1970: 300)),
        ]
        var queued = agent("queued")
        queued.status = .queued
        let result = DelegateAgentActivity.reconciled(agents + [queued], sessionId: "s1", liveIDs: ["live"], changedBefore: cutoff)
        XCTAssertEqual(result.map(\.status), [.completed, .running, .running, .running, .running, .queued])
    }

    // MARK: - clarify.request

    func testClarifyWithStringChoices() {
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"request_id": "req-1", "question": "Which env?", "choices": ["staging", "prod"]}}
        """#)
        guard case .clarify(let sessionId, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(activity.requestId, "req-1")
        XCTAssertEqual(activity.questions.count, 1)
        XCTAssertEqual(activity.questions[0].id, "q0")
        XCTAssertEqual(activity.questions[0].question, "Which env?")
        XCTAssertEqual(activity.questions[0].choices.map(\.value), ["staging", "prod"])
        XCTAssertFalse(activity.questions[0].multiSelect)
        XCTAssertEqual(activity.status, .pending)
    }

    func testClarifyWithObjectChoices() {
        let event = parse(#"""
        {"type": "clarify", "session_id": "s1", "payload": {"requestId": "req-2", "prompt": "Pick one", "options": [{"label": "Current", "value": "current"}]}}
        """#)
        guard case .clarify(_, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertEqual(activity.questions[0].choices, [ClarifyChoice(label: "Current", value: "current")])
    }

    func testClarifyBatchQuestionsParseInGatewayOrder() {
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"request_id": "req-1", "questions": [
            {"qid": "environment", "question": "Which environment?", "choices": ["staging", "prod"], "multi_select": false},
            {"qid": "tests", "question": "Which tests should run?", "choices": ["unit", "integration", "ui"], "multi_select": true},
            {"qid": "notes", "question": "Any additional notes?", "choices": []}
        ]}}
        """#)
        guard case .clarify(_, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertEqual(activity.requestId, "req-1")
        XCTAssertEqual(activity.questions.map(\.id), ["environment", "tests", "notes"], "The gateway qid is the question identity")
        XCTAssertEqual(activity.questions.map(\.question), [
            "Which environment?",
            "Which tests should run?",
            "Any additional notes?"
        ])
        XCTAssertEqual(activity.questions[0].choices.map(\.value), ["staging", "prod"])
        XCTAssertFalse(activity.questions[0].multiSelect)
        XCTAssertTrue(activity.questions[1].multiSelect, "multi_select must survive normalization")
        XCTAssertTrue(activity.questions[2].choices.isEmpty, "A choice-less question is a free-text question")
        XCTAssertFalse(activity.questions[2].multiSelect, "multi_select without choices degrades like the gateway does")
    }

    func testClarifyBatchWithSingleQuestionPreservesQID() {
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"request_id": "req-1", "questions": [{"qid": "only", "question": "One?", "choices": ["a"]}]}}
        """#)
        guard case .clarify(_, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertEqual(activity.questions.map(\.id), ["only"], "A real batch qid is never replaced by a synthetic id")
    }

    func testClarifyBatchObjectChoicesRemainCompatible() {
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"request_id": "req-1", "questions": [{"qid": "q", "question": "Pick", "choices": [{"label": "Current", "value": "current"}]}]}}
        """#)
        guard case .clarify(_, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertEqual(activity.questions[0].choices, [ClarifyChoice(label: "Current", value: "current")])
    }

    func testClarifyBatchDropsMalformedQuestionsButKeepsAnswerableOnes() {
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"request_id": "req-1", "questions": [
            {"question": "No qid, unanswerable per question", "choices": ["a"]},
            {"qid": "ok", "question": "Valid", "choices": ["a", "b"]},
            {"qid": "empty", "question": "   ", "choices": ["a"]}
        ]}}
        """#)
        guard case .clarify(_, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertEqual(activity.questions.map(\.id), ["ok"], "Malformed siblings are dropped deliberately; answerable ones survive")
    }

    func testClarifyBatchFailsWithoutAnyAnswerableQuestion() {
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"request_id": "req-1", "questions": [{"qid": "empty", "question": "", "choices": []}]}}
        """#)
        XCTAssertNil(event)
    }

    func testClarifyBatchDeduplicatesRepeatedQIDs() {
        // Repeated qids would violate Identifiable in the card's ForEach and
        // make per-question answers ambiguous; keep the first occurrence.
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"request_id": "req-1", "questions": [
            {"qid": "dup", "question": "First", "choices": ["a"]},
            {"qid": "dup", "question": "Second", "choices": ["b"]},
            {"qid": "ok", "question": "Valid", "choices": ["c"]}
        ]}}
        """#)
        guard case .clarify(_, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertEqual(activity.questions.map(\.id), ["dup", "ok"])
        XCTAssertEqual(activity.questions[0].question, "First")
    }

    func testClarifyBatchWithMissingRequestIDReturnsNil() {
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"questions": [{"qid": "a", "question": "Q?", "choices": ["x"]}]}}
        """#)
        XCTAssertNil(event)
    }

    func testClarifyLegacyScalarQuestionStillParsesWithoutTopLevelQuestions() {
        // A batch payload shape must not depend on a legacy top-level
        // question being present.
        let event = parse(#"""
        {"type": "clarify", "session_id": "s1", "payload": {"request_id": "req-1", "question": "Which env?", "choices": ["staging"]}}
        """#)
        guard case .clarify(_, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertEqual(activity.questions.count, 1)
        XCTAssertEqual(activity.questions[0].question, "Which env?")
    }

    func testClarifyLegacyScalarMultiSelectParses() {
        let event = parse(#"""
        {"type": "clarify.request", "session_id": "s1", "payload": {"request_id": "req-1", "question": "Which tests?", "choices": ["unit", "ui"], "multi_select": true}}
        """#)
        guard case .clarify(_, let activity) = event else {
            return XCTFail("Expected clarify")
        }
        XCTAssertTrue(activity.questions[0].multiSelect)
    }

    // MARK: - clarify.expire

    func testClarifyExpireParsesRequestID() {
        let event = parse(#"""
        {"type": "clarify.expire", "session_id": "s1", "payload": {"request_id": "req-7"}}
        """#)
        guard case .clarifyExpire(let sessionId, let requestId, let reason) = event else {
            return XCTFail("Expected clarifyExpire")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(requestId, "req-7")
        XCTAssertNil(reason, "The legacy event carries no reason (it is always a timeout)")
    }

    func testRequestCancelForClarifyExpiresTheServerRequestCard() {
        let event = parse(#"""
        {"type": "request.cancel", "session_id": "s1", "payload": {"id": "srq-0123456789ab", "method": "clarify", "reason": "timeout"}}
        """#)
        guard case .clarifyExpire(let sessionId, let requestId, let reason) = event else {
            return XCTFail("Expected clarifyExpire")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(requestId, "srq-0123456789ab")
        XCTAssertEqual(reason, "timeout")
    }

    func testRequestCancelWithoutReasonIsNotATimeout() {
        let event = parse(#"""
        {"type": "request.cancel", "session_id": "s1", "payload": {"id": "srq-0123456789ab", "method": "clarify"}}
        """#)
        guard case .clarifyExpire(_, _, let reason) = event else {
            return XCTFail("Expected clarifyExpire")
        }
        XCTAssertEqual(reason, "", "Only the legacy clarify.expire (nil) or an explicit timeout reads as timed out")
    }

    func testRequestCancelResolvedDoesNotExpireClarify() {
        let event = parse(#"""
        {"type": "request.cancel", "session_id": "s1", "payload": {"id": "srq-0123456789ab", "method": "clarify", "reason": "resolved"}}
        """#)
        XCTAssertNil(event, "An answered request must never read as timed out")
    }

    func testRequestCancelForMaskedPromptExpiresIt() {
        let event = parse(#"""
        {"type": "request.cancel", "session_id": "s1", "payload": {"id": "srq-0123456789ab", "method": "sudo", "reason": "timeout"}}
        """#)
        guard case .inputPromptExpire(let sessionId, let requestId, let reason) = event else {
            return XCTFail("Expected inputPromptExpire")
        }
        XCTAssertEqual(reason, "timeout")
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(requestId, "srq-0123456789ab")
    }

    func testRequestCancelResolvedStillReachesAMaskedPrompt() {
        let event = parse(#"""
        {"type": "request.cancel", "session_id": "s1", "payload": {"id": "srq-0123456789ab", "method": "secret", "reason": "resolved"}}
        """#)
        guard case .inputPromptExpire(_, _, let reason) = event else {
            return XCTFail("Another surface answering a prompt must still reach its card")
        }
        XCTAssertEqual(reason, "resolved")
    }

    func testRequestCancelForApprovalIsIgnored() {
        // Approval cards are keyed by the queue id, not the server request id.
        let event = parse(#"""
        {"type": "request.cancel", "session_id": "s1", "payload": {"id": "srq-0123456789ab", "method": "approval", "reason": "resolved"}}
        """#)
        XCTAssertNil(event)
    }

    func testClarifyExpireWithoutRequestIDReturnsNil() {
        let event = parse(#"""
        {"type": "clarify.expire", "session_id": "s1", "payload": {}}
        """#)
        XCTAssertNil(event)
    }

    func testClarifyMissingRequestIdReturnsNil() {
        let event = parse(#"""
        {"type": "clarify", "session_id": "s1", "payload": {"question": "No ID"}}
        """#)
        XCTAssertNil(event)
    }

    func testClarifyMissingQuestionReturnsNil() {
        let event = parse(#"""
        {"type": "clarify", "session_id": "s1", "payload": {"request_id": "req-1"}}
        """#)
        XCTAssertNil(event)
    }

    // MARK: - approval.request

    func testApprovalRequestWithCommand() {
        let event = parse(#"""
        {"type": "approval.request", "session_id": "s1", "payload": {"command": "rm -rf /tmp", "description": "Clean up", "choices": ["once", "deny"]}}
        """#)
        guard case .approval(let sessionId, let activity) = event else {
            return XCTFail("Expected approval")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(activity.command, "rm -rf /tmp")
        XCTAssertEqual(activity.description, "Clean up")
        XCTAssertEqual(activity.choices, ["once", "deny"])
    }

    func testApprovalRequestWithFallbackDescription() {
        let event = parse(#"""
        {"type": "approval.request", "session_id": "s1", "payload": {}}
        """#)
        guard case .approval(_, let activity) = event else {
            return XCTFail("Expected approval")
        }
        XCTAssertEqual(activity.description, "Approval required")
        XCTAssertNil(activity.choices)
    }

    // MARK: - review.summary

    func testReviewSummaryWithSelfImprovementText() {
        let event = parse(#"""
        {"type": "review.summary", "session_id": "s1", "payload": {"text": "💾 Self-improvement review: ➕ Memory: added preference"}}
        """#)
        guard case .reviewSummary(_, let activity) = event else {
            return XCTFail("Expected reviewSummary")
        }
        XCTAssertNotNil(activity.summary)
        XCTAssertNotNil(activity.details)
    }

    /// Hermes Desktop renders every `review.summary` as a memory-write row,
    /// whatever its prose; Conduit mirrors it, dropping the leading glyph.
    func testReviewSummaryWithoutReviewPrefixStillSurfaces() {
        let event = parse(#"""
        {"type": "review.summary", "session_id": "s1", "payload": {"text": "💾 Memory updated"}}
        """#)
        guard case .reviewSummary(_, let activity) = event else {
            return XCTFail("Expected reviewSummary")
        }
        XCTAssertEqual(activity.summary, "Memory updated")
        XCTAssertNil(activity.details)
    }

    func testReviewSummaryWithEmptyTextReturnsNil() {
        let event = parse(#"""
        {"type": "review.summary", "session_id": "s1", "payload": {"text": "  💾  "}}
        """#)
        XCTAssertNil(event)
    }

    // MARK: - another client's changes (#1026)

    func testUserMessageFromAnotherClient() {
        guard case .userMessage(let sessionId, let rowId, let text, let origin) = parse(#"""
        {"type": "user.message", "session_id": "s1", "payload": {"text": "Sent from the TUI", "row_id": 9010, "origin": "Windows", "busy": false}}
        """#) else {
            return XCTFail("Expected userMessage")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(rowId, 9010)
        XCTAssertEqual(text, "Sent from the TUI")
        XCTAssertEqual(origin, "Windows")

        guard case .userMessage(_, let noRow, _, let noOrigin) = parse(#"""
        {"type": "user.message", "session_id": "s1", "payload": {"text": "Hi", "row_id": null}}
        """#) else {
            return XCTFail("A row id isn't required")
        }
        XCTAssertNil(noRow)
        XCTAssertNil(noOrigin)
    }

    func testUserMessageWithoutTextOrSessionIsDropped() {
        XCTAssertNil(parse(#"{"type": "user.message", "session_id": "s1", "payload": {"text": "  "}}"#))
        XCTAssertNil(parse(#"{"type": "user.message", "payload": {"text": "Hi"}}"#))
    }

    func testSessionsChanged() {
        guard case .sessionsChanged = parse(#"{"type": "sessions.changed", "session_id": "", "payload": {}}"#) else {
            return XCTFail("Expected sessionsChanged")
        }
        guard case .sessionsChanged = parse(#"{"type": "sessions.changed"}"#) else {
            return XCTFail("Session-less and payload-less")
        }
    }

    // MARK: - unknown events

    func testUnknownEventBecomesUnparsed() {
        let event = parse(#"""
        {"type": "some.future.event", "session_id": "s1", "payload": {"custom": "data"}}
        """#)
        guard case .unparsed(let payload) = event else {
            return XCTFail("Expected unparsed")
        }
        XCTAssertNotNil(payload["type"])
    }

    // MARK: - edge cases

    func testNonObjectParamsReturnsNil() {
        let event = StreamEventParser.parse(params: .string("not an object"))
        XCTAssertNil(event)
    }

    func testMissingTypeDefaultsToUnparsed() {
        let event = parse(#"""
        {"session_id": "s1", "payload": {}}
        """#)
        if case .unparsed = event {} else {
            XCTFail("Missing type should produce unparsed")
        }
    }

    // MARK: - status.update

    func testStatusUpdateCompactingParses() {
        let event = parse(#"""
        {"type": "status.update", "session_id": "s1", "payload": {"kind": "compacting", "text": "Summarizing…"}}
        """#)
        guard case .statusUpdate(let sessionId, let kind, let text) = event else {
            return XCTFail("Expected statusUpdate, got \(String(describing: event))")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(kind, .compacting)
        XCTAssertEqual(text, "Summarizing…")
    }

    func testStatusUpdateCompactedParses() {
        let event = parse(#"""
        {"type": "status.update", "session_id": "s1", "payload": {"kind": "compacted", "text": "✓ Context compression complete"}}
        """#)
        guard case .statusUpdate(let sessionId, let kind, let text) = event else {
            return XCTFail("Expected statusUpdate, got \(String(describing: event))")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(kind, .compacted)
        XCTAssertEqual(text, "✓ Context compression complete")
    }

    func testStatusUpdateWithoutSessionIDIsRejected() {
        let event = parse(#"""
        {"type": "status.update", "session_id": "", "payload": {"kind": "compacted"}}
        """#)
        XCTAssertNil(event, "A session-less status edge must not drive conversation-scoped state")
    }

    func testStatusUpdateUnrelatedKindsNeverMasqueradeAsCompaction() {
        // The in-process manual compression path emits `compressing` and bare
        // `status` kinds; drivers use arbitrary strings. None of them may
        // parse as a compaction edge — they stay typed as `.other`.
        for rawKind in ["compressing", "status", "ready", "lifecycle"] {
            let event = parse(#"""
            {"type": "status.update", "session_id": "s1", "payload": {"kind": "\#(rawKind)"}}
            """#)
            guard case .statusUpdate(_, let kind, let text) = event else {
                return XCTFail("Expected statusUpdate for kind \(rawKind)")
            }
            XCTAssertNotEqual(kind, .compacting, rawKind)
            XCTAssertNotEqual(kind, .compacted, rawKind)
            XCTAssertEqual(kind, .other(rawKind), rawKind)
            XCTAssertNil(text, rawKind)
        }
    }
}
