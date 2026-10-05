//
//  ClarifyHistoryRecordTests.swift
//  Conduit
//
//  A finished clarify tool row from persisted history reads back as its
//  answered card instead of the raw tool call (#394).
//

import XCTest
@testable import Conduit

extension ClarifyBatchStateTests {

    private func clarifyHistoryRow(input: String?, output: String?, status: ToolActivity.Status = .complete) -> ToolActivity {
        ToolActivity(id: "call_1", name: "clarify", input: input, output: output, status: status)
    }

    func testHistoryClarifyRowReadsBackAsAnsweredCard() throws {
        // The exact row from #394: current Hermes result shape.
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Which do you like better: Reddit or X?", "choices": ["Reddit", "X"]}]}"#,
            output: #"{"responses": [{"question": "Which do you like better: Reddit or X?", "choices_offered": ["Reddit", "X"], "status": "answered", "user_response": "Reddit"}], "outcome": "submitted"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.requestId, "history-call_1")
        XCTAssertEqual(record.status, .answered)
        XCTAssertNil(record.error)
        XCTAssertEqual(record.questions.count, 1)
        XCTAssertEqual(record.questions[0].question, "Which do you like better: Reddit or X?")
        XCTAssertEqual(record.questions[0].choices.map(\.value), ["Reddit", "X"])
        XCTAssertEqual(record.questions[0].resolvedAnswer, "Reddit")
    }

    func testHistoryClarifyRowReadsTheSingleQuestionResultShape() throws {
        let tool = ToolActivity(
            id: nil,
            name: "clarify",
            input: #"{"question": "Which environment?", "choices": ["staging", "prod"]}"#,
            output: #"{"question": "Which environment?", "choices_offered": ["staging", "prod"], "user_response": "prod"}"#,
            status: .complete
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-7"))

        XCTAssertEqual(record.requestId, "history-row-7")
        XCTAssertEqual(record.status, .answered)
        XCTAssertEqual(record.questions[0].resolvedAnswer, "prod")
    }

    func testHistoryClarifyRowShowsMultiSelectAnswersInChoiceOrder() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Which tests should run?", "choices": ["unit", "ui", "lint"], "multi_select": true}]}"#,
            output: #"{"responses": [{"question": "Which tests should run?", "choices_offered": ["unit", "ui", "lint"], "status": "answered", "user_response": ["lint", "unit"]}], "outcome": "submitted"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertTrue(record.questions[0].multiSelect)
        XCTAssertEqual(record.questions[0].resolvedAnswer, "unit, lint")
    }

    func testHistoryClarifyRowThatTimedOutReadsAsExpired() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#,
            output: #"{"responses": [{"question": "Ship it?", "choices_offered": ["Yes", "No"], "status": "unanswered", "user_response": null}], "outcome": "timed_out"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.status, .expired)
        XCTAssertTrue(record.isExpired)
        XCTAssertNil(record.questions[0].answer)
        XCTAssertEqual(
            record.error,
            AppLocalization.string("This question is no longer active — Hermes timed it out and continued.")
        )
    }

    func testHistoryClarifyBatchKeepsEachQuestionsOwnState() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Which environment?", "choices": ["staging", "prod"]}, {"question": "Any notes?"}, {"question": "Notify the team?", "choices": ["Yes", "No"]}]}"#,
            output: #"{"responses": [{"question": "Which environment?", "choices_offered": ["staging", "prod"], "status": "answered", "user_response": "staging"}, {"question": "Any notes?", "choices_offered": null, "status": "skipped", "user_response": null}, {"question": "Notify the team?", "choices_offered": ["Yes", "No"], "status": "unanswered", "user_response": null}], "outcome": "cancelled"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.questions.map(\.status), [.answered, .answered, .expired])
        XCTAssertEqual(record.questions[0].resolvedAnswer, "staging")
        XCTAssertEqual(record.questions[1].resolvedAnswer, AppLocalization.string("Skipped"))
        XCTAssertEqual(record.status, .expired)
        XCTAssertEqual(record.error, AppLocalization.string("These questions are no longer active."))
    }

    func testHistoryClarifyRowReadsTheNotifierPushAnswerShape() throws {
        // The notifier's push answer has no status or outcome fields.
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Pick one", "choices": ["a", "b"]}]}"#,
            output: #"{"responses": [{"question": "Pick one", "choices_offered": ["a", "b"], "user_response": "b"}]}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.status, .answered)
        XCTAssertEqual(record.questions[0].resolvedAnswer, "b")
    }

    func testHistoryClarifyRowReadsAMultiSelectAnswerInItsWireStringForm() throws {
        let tool = clarifyHistoryRow(
            input: #"{"questions": [{"question": "Which tests should run?", "choices": ["unit", "ui", "lint"], "multi_select": true}]}"#,
            output: #"{"responses": [{"question": "Which tests should run?", "choices_offered": ["unit", "ui", "lint"], "status": "answered", "user_response": "[\"lint\", \"unit\"]"}], "outcome": "submitted"}"#
        )

        let record = try XCTUnwrap(ClarifyActivity.historyRecord(for: tool, rowID: "row-1"))

        XCTAssertEqual(record.questions[0].resolvedAnswer, "unit, lint")
    }

    func testHistoryClarifyRowWithAnUnfamiliarResultKeepsTheToolCard() {
        let question = #"{"questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#
        // A row status this build doesn't know.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(
                input: question,
                output: #"{"responses": [{"question": "Ship it?", "choices_offered": ["Yes", "No"], "status": "deferred", "user_response": null}], "outcome": "submitted"}"#
            ),
            rowID: "row-1"
        ))
        // Answered, but with no answer to show.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(
                input: question,
                output: #"{"responses": [{"question": "Ship it?", "choices_offered": ["Yes", "No"], "status": "answered", "user_response": null}], "outcome": "submitted"}"#
            ),
            rowID: "row-1"
        ))
    }

    func testClarifyRowsWithoutAReadableResultKeepTheToolCard() {
        let question = #"{"questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#
        // Still waiting on the user.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(input: question, output: nil, status: .running), rowID: "row-1"))
        // A compact resume row: an argument preview and no result.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(input: "Ship it?", output: nil), rowID: "row-1"))
        // The tool refused the call.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(input: question, output: #"{"error": "questions must be a non-empty array"}"#), rowID: "row-1"))
        // Not JSON.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: clarifyHistoryRow(input: question, output: "done"), rowID: "row-1"))
        // Another tool with a clarify-like result.
        XCTAssertNil(ClarifyActivity.historyRecord(
            for: ToolActivity(id: "call_2", name: "terminal", input: nil,
                              output: #"{"question": "Ship it?", "user_response": "Yes"}"#, status: .complete),
            rowID: "row-2"))
    }
}
