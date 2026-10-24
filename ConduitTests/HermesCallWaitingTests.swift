//
//  HermesCallWaitingTests.swift
//  Conduit
//
//  A call from Hermes about a question or an approval
//  (designs/hermes-call-clarify.md): the model is briefed with the choices
//  and what Hermes wrote, a spoken pick maps to the choice a tap would
//  send, and the Apple Watch answers through the host (WatchCallAnswer).
//  Written as an extension of an existing suite: the CI test planner
//  times suites, not their tests.
//

import XCTest
@testable import Conduit

@MainActor
extension VoiceConversationControllerTests {
    private func environmentQuestion(multiSelect: Bool = false) -> HermesCallWaiting.Question {
        HermesCallWaiting.Question(
            id: "q0",
            text: "Which environment?",
            choices: [
                .init(label: "staging (Recommended)", value: "staging (Recommended)"),
                .init(label: "prod", value: "prod"),
                .init(label: "a fresh sandbox", value: "a fresh sandbox"),
            ],
            multiSelect: multiSelect
        )
    }

    func testACallFromHermesIsBriefedWithTheChoicesAndWhatHermesWrote() {
        let waiting = HermesCallWaiting(
            item: .questions([environmentQuestion(), HermesCallWaiting.Question(id: "q1", text: "Anything else?", choices: [], multiSelect: false)]),
            leadUp: "The deploy is ready. I need to know where it goes."
        )
        let opening = HermesCallOpening(kind: .question, title: nil, result: nil, reason: "Which environment?")
        let block = opening.instructionBlock(delegation: false, waiting: waiting)
        XCTAssertTrue(block.contains("Question 1 (they pick one): Which environment?\n1. staging (Recommended)\n2. prod"))
        XCTAssertTrue(block.contains("(No choices: they answer in their own words.)"))
        XCTAssertTrue(block.contains("<hermes_wrote_before_asking>\nThe deploy is ready."))
        XCTAssertTrue(block.contains("call answer_question with the number of their choice"))
        XCTAssertTrue(block.contains("Before I choose:"))
        XCTAssertTrue(opening.instructionBlock(delegation: true, waiting: waiting).contains("delegate \"Answer:\" followed by the number"))
    }

    func testASpokenPickSendsWhatATapWould() {
        let question = environmentQuestion()
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "the recommended one", question: question), "staging (Recommended)")
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "the second one", question: question), "prod")
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "option 3", question: question), "a fresh sandbox")
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "Prod", question: question), "prod")
        XCTAssertEqual(HermesCallWaiting.answerLabel(for: "two", question: question), "prod")
        // Words that point at no single choice go to Hermes as they are.
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "not the recommended one", question: question), "not the recommended one")
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "1 and 2", question: question), "1 and 2")
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "7", question: question), "7")
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "Before I choose: what does prod change?", question: question),
                       "Before I choose: what does prod change?")
        XCTAssertEqual(HermesCallWaiting.pickedChoices(in: "one and three", choices: environmentQuestion(multiSelect: true).choices, multiSelect: true), [0, 2])
    }

    func testTheHostsCopyBriefsAWatchCallThatCanAnswer() throws {
        let waiting = try XCTUnwrap(HermesCallWaiting(host: [
            "kind": "question",
            "questions": [
                ["number": 1, "question": "Which environment?", "choices": ["staging (Recommended)", "prod"], "multi_select": false, "answered": true],
                ["number": 2, "question": "Which tests?", "choices": ["unit", "ui"], "multi_select": true, "answered": false],
            ],
        ]))
        XCTAssertEqual(waiting.openQuestion?.text, "Which tests?")
        XCTAssertNil(HermesCallWaiting(host: ["kind": "question", "questions": [["question": "Done?", "answered": true]]]))
        XCTAssertNil(HermesCallWaiting(host: ["kind": "approval", "description": "Deploy", "answered": true]))
        let approval = try XCTUnwrap(HermesCallWaiting(host: ["kind": "approval", "description": "Delete the cache", "command": "rm -rf build"]))
        XCTAssertTrue(approval.block.contains("Command: rm -rf build\nWhy: Delete the cache"))
        // Classic and the Watch's Local Live say it and ask for a yes or no.
        let approvalCall = HermesCallOpening(kind: .approval, title: nil, result: nil, reason: "Delete the cache")
        XCTAssertTrue(approvalCall.spokenBrief(waiting: approval).hasSuffix("Delete the cache. Say yes to allow it once, or no."))

        let opening = HermesCallOpening(kind: .question, title: nil, result: nil, reason: "Which tests?", sessionIDs: ["st-1"])
        let watch = opening.instructionBlock(delegation: false, canAnswer: true, waiting: waiting)
        XCTAssertTrue(watch.contains("call answer_question"))
        XCTAssertFalse(watch.contains("on their iPhone"))
        XCTAssertEqual(opening.watchOpeningTurn(canAnswer: true), opening.openingTurn)
        XCTAssertEqual(opening.watchOpeningTurn(canAnswer: false), opening.watchOpeningTurn)
        let declared = GeminiLiveToolBridge.watchDeclarations(webSearch: false, memoryRecall: false, answers: .question).map(\.name)
        XCTAssertTrue(declared.contains("answer_question"))
        XCTAssertFalse(GeminiLiveToolBridge.watchDeclarations(webSearch: false, memoryRecall: false).map(\.name).contains("answer_question"))
    }

    func testTheWatchSendsTheAnswerAndReadsTheNextQuestion() {
        XCTAssertTrue(WatchCallAnswer.answersCall("answer_question", jobApprovalsWaiting: true))
        XCTAssertTrue(WatchCallAnswer.answersCall("answer_approval", jobApprovalsWaiting: false))
        XCTAssertFalse(WatchCallAnswer.answersCall("answer_approval", jobApprovalsWaiting: true), "A job's approval on the Watch")
        XCTAssertEqual(WatchCallAnswer.arguments(name: "answer_question", arguments: ["answer": " 2 "])?["answer"] as? String, "2")
        XCTAssertNil(WatchCallAnswer.arguments(name: "answer_approval", arguments: ["choice": "always"]))

        let next = WatchCallAnswer.result(body: [
            "ok": true, "status": "answered", "question": 1, "answer": "staging",
            "next": ["number": 2, "question": "Which tests?", "choices": ["unit", "ui"], "multi_select": true],
        ])
        XCTAssertEqual(next["choice"], "staging")
        XCTAssertTrue(next["message"]?.contains("Question (they may pick several): Which tests?\n1. unit\n2. ui") == true)
        XCTAssertEqual(WatchCallAnswer.result(body: ["ok": true, "status": "answered", "choice": "deny"])["status"], "denied")
        XCTAssertNotNil(WatchCallAnswer.result(body: ["ok": true, "status": "refused", "message": "Too long"])["error"])
        XCTAssertEqual(WatchCallAnswer.result(body: ["ok": true, "status": "not_waiting"])["status"], "not_pending")
        XCTAssertNotNil(WatchCallAnswer.result(body: ["ok": false, "detail": "choice must be once or deny"])["error"])

        XCTAssertEqual(WatchCallAnswer.delegatedArguments("Answer: 2", userWords: "", approves: false)?["answer"] as? String, "2")
        XCTAssertEqual(WatchCallAnswer.delegatedArguments("Answer:", userWords: "the second one", approves: false)?["answer"] as? String, "the second one")
        XCTAssertNil(WatchCallAnswer.delegatedArguments("Approve: run it", userWords: "yes", approves: false), "The user taps approvals on the Watch")
        XCTAssertEqual(WatchCallAnswer.delegatedArguments("Approve: run it", userWords: "yes", approves: true)?["choice"] as? String, "once")
        XCTAssertNil(WatchCallAnswer.delegatedArguments("Deny: not now", userWords: "no", approves: false), "Nor denies them")
        XCTAssertNil(WatchCallAnswer.delegatedArguments("Check the weather", userWords: "", approves: false))
    }
}
