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
        guard case .messageComplete(let sessionId, let messageId, let content, let reasoning) = event else {
            return XCTFail("Expected messageComplete")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(messageId, "msg-42")
        XCTAssertEqual(content, "Final answer")
        XCTAssertEqual(reasoning, "because")
    }

    func testMessageCompleteFallsBackToIdField() {
        let event = parse(#"""
        {"type": "message.complete", "session_id": "s1", "payload": {"id": "alt-id"}}
        """#)
        guard case .messageComplete(_, let messageId, _, _) = event else {
            return XCTFail("Expected messageComplete")
        }
        XCTAssertEqual(messageId, "alt-id")
    }

    func testMessageCompleteFallsBackToRenderedField() {
        let event = parse(#"""
        {"type": "message.complete", "session_id": "s1", "payload": {"rendered": "<p>html</p>"}}
        """#)
        guard case .messageComplete(_, _, let content, _) = event else {
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
        guard case .toolStart(_, let toolName, let toolInput) = event else {
            return XCTFail("Expected toolStart")
        }
        XCTAssertEqual(toolName, "web_search")
        XCTAssertEqual(toolInput, "query=test")
    }

    func testToolStartWithInputField() {
        let event = parse(#"""
        {"type": "tool.start", "session_id": "s1", "payload": {"name": "terminal", "input": "ls -la"}}
        """#)
        guard case .toolStart(_, _, let toolInput) = event else {
            return XCTFail("Expected toolStart")
        }
        XCTAssertEqual(toolInput, "ls -la")
    }

    func testToolStartWithObjectArgs() {
        let event = parse(#"""
        {"type": "tool_call", "session_id": "s1", "payload": {"name": "terminal", "arguments": {"command": "pwd"}}}
        """#)
        guard case .toolStart(_, _, let toolInput) = event else {
            return XCTFail("Expected toolStart")
        }
        XCTAssertNotNil(toolInput)
        XCTAssertTrue(toolInput!.contains("command"))
    }

    // MARK: - tool.complete

    func testToolCompleteWithOutput() {
        let event = parse(#"""
        {"type": "tool.complete", "session_id": "s1", "payload": {"name": "terminal", "output": "done"}}
        """#)
        guard case .toolComplete(_, let toolName, let toolOutput) = event else {
            return XCTFail("Expected toolComplete")
        }
        XCTAssertEqual(toolName, "terminal")
        XCTAssertEqual(toolOutput, "done")
    }

    func testToolCompleteFallsBackToResult() {
        let event = parse(#"""
        {"type": "tool_result", "session_id": "s1", "payload": {"name": "search", "result": "found"}}
        """#)
        guard case .toolComplete(_, _, let toolOutput) = event else {
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
        guard case .clarifyExpire(let sessionId, let requestId) = event else {
            return XCTFail("Expected clarifyExpire")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(requestId, "req-7")
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

    func testReviewSummaryWithNonReviewTextReturnsNil() {
        let event = parse(#"""
        {"type": "review.summary", "session_id": "s1", "payload": {"text": "Just a normal message"}}
        """#)
        XCTAssertNil(event)
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
}
