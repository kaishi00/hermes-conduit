//
//  ClarifyLegacyDecodeTests.swift
//  Conduit
//
//  Decoding of persisted clarify cards: records written by older builds
//  (camelCase `requestId`, scalar question fields) must still load, and the
//  current batch shape must survive an encode/decode round trip unchanged.
//

import XCTest
@testable import Conduit

final class ClarifyLegacyDecodeTests: XCTestCase {
    private func decode(_ json: String) throws -> ClarifyActivity {
        try JSONDecoder().decode(ClarifyActivity.self, from: Data(json.utf8))
    }

    func testLegacyScalarRecordMigratesIntoOneSyntheticQuestion() throws {
        let activity = try decode("""
        {"requestId":"r1","question":"Pick","choices":[],"status":"answered","answer":"A","error":"x"}
        """)

        XCTAssertEqual(activity.requestId, "r1")
        XCTAssertEqual(activity.questions.count, 1)
        let question = try XCTUnwrap(activity.questions.first)
        XCTAssertEqual(question.id, "q0")
        XCTAssertTrue(question.isSyntheticID)
        XCTAssertEqual(question.question, "Pick")
        XCTAssertEqual(question.status, .answered)
        XCTAssertEqual(question.answer, "A")
        XCTAssertEqual(activity.error, "x")
        XCTAssertEqual(activity.status, .answered)
    }

    func testCurrentRequestIDKeyWinsOverTheLegacyOne() throws {
        let activity = try decode("""
        {"request_id":"current","requestId":"legacy","question":"Pick","choices":[]}
        """)

        XCTAssertEqual(activity.requestId, "current")
    }

    func testLegacyRecordWithEmptyQuestionLoadsExpiredNotPending() throws {
        let activity = try decode("""
        {"requestId":"r1","question":"","choices":[],"status":"pending"}
        """)

        XCTAssertTrue(activity.questions.isEmpty)
        XCTAssertEqual(activity.status, .expired)
        XCTAssertFalse(activity.needsAnswer)
        XCTAssertFalse(activity.hasPendingDecision)
    }

    func testCurrentShapeRecordRoundTripsUnchanged() throws {
        let original = ClarifyActivity(
            requestId: "r2",
            questions: [
                ClarifyQuestion(
                    id: "qa",
                    question: "Which one?",
                    choices: [ClarifyChoice(label: "Left", value: "left")],
                    multiSelect: true,
                    status: .error,
                    answer: nil,
                    error: "timed out",
                    isSyntheticID: false
                ),
                ClarifyQuestion(
                    id: "qb",
                    question: "Why?",
                    choices: [],
                    multiSelect: false,
                    status: .answered,
                    answer: "because",
                    isSyntheticID: false
                ),
            ],
            isExpired: false,
            error: "request error"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClarifyActivity.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
