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
        // "The one" names no choice by itself ("the one that's cheaper").
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "the one", question: question), "the one")
        XCTAssertEqual(HermesCallWaiting.pickedChoices(in: "one and three", choices: environmentQuestion(multiSelect: true).choices, multiSelect: true), [0, 2])
    }

    func testSkipLeavesOnlyAFormsQuestionBlank() {
        var question = environmentQuestion()
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "skip", question: question), "skip", "Outside a form the words go as they are")
        XCTAssertFalse(HermesCallWaiting.spokenQuestion(question).contains("skip"))
        question.mayLeaveBlank = true
        XCTAssertNil(HermesCallWaiting.answerValue(for: "Skip it, please", question: question))
        XCTAssertEqual(HermesCallWaiting.answerLabel(for: "skip", question: question), HermesCallWaiting.skippedLabel)
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "prod", question: question), "prod")
        let pass = HermesCallWaiting.Question(
            id: "q1", text: "Your kind of escape?",
            choices: [.init(label: "Beach", value: "Beach"), .init(label: "Pass", value: "Pass")],
            multiSelect: false, mayLeaveBlank: true
        )
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "pass", question: pass), "Pass", "A choice named whole is picked first")
        XCTAssertNil(HermesCallWaiting.answerValue(for: "I'll pass", question: pass), "Only named whole")
        let cushion = HermesCallWaiting.Question(
            id: "q2", text: "Which cushion?",
            choices: [.init(label: "Blank", value: "Blank"), .init(label: "Striped", value: "Striped")],
            multiSelect: false, mayLeaveBlank: true
        )
        XCTAssertNil(HermesCallWaiting.answerValue(for: "leave it blank", question: cushion), "Not the choice inside the words")
        XCTAssertEqual(HermesCallWaiting.answerLabel(for: "leave it blank", question: cushion), HermesCallWaiting.skippedLabel)
        XCTAssertEqual(HermesCallWaiting.answerValue(for: "the blank one", question: cushion), "Blank")

        XCTAssertTrue(HermesCallWaiting(item: .questions([question])).block.contains(HermesCallWaiting.mayLeaveBlankNote))
        XCTAssertEqual(WatchCallAnswer.mayLeaveBlankNote, HermesCallWaiting.mayLeaveBlankNote, "One note on the phone and the Watch")
        XCTAssertTrue(HermesCallWaiting.spokenQuestion(question).hasSuffix(" Or say skip to leave it blank."))
        let next = WatchCallAnswer.result(body: [
            "ok": true, "status": "answered", "question": 1, "answer": "left blank", "skipped": true,
            "next": ["number": 2, "question": "Total budget?", "choices": [String](), "may_leave_blank": true],
        ])
        XCTAssertTrue(next["message"]?.contains("Total budget?\n(No choices: they answer in their own words.)\n" + WatchCallAnswer.mayLeaveBlankNote) == true)
    }

    /// The same words as the plugin's test_call_waiting.py SKIPS and
    /// NOT_SKIPS: a Watch call's words are read there, the phone's here.
    func testSkipIsReadTheSameWayAsThePlugin() {
        let skips = [
            "skip", "Skip it.", "skip this one, please", "I'll pass", "leave it blank", "Leave that empty",
            "go ahead and skip it please", "Überspringen", "lass es leer", "ich passe", "sáltala", "déjalo en blanco",
            "je passe", "laisse-le vide", "lewati saja", "biarkan kosong", "salta questa domanda", "lascialo in bianco",
            "pomiń to pytanie", "pode pular", "deixa em branco", "Пропусти этот вопрос", "оставь пустым", "bunu atla",
            "boş bırak", "スキップ", "スキップでお願いします", "飛ばしてください", "空欄のままでお願いします", "跳过",
            "这个问题跳过吧", "留空", "스킵해 주세요", "비워 두세요", "이건 패스할게요", "skip to the next question",
            "Skip to the next one.", "überspringen, nächste Frage", "salta a la siguiente pregunta", "passons à la suivante",
            "lewati, lanjut ke berikutnya", "salta alla prossima domanda", "pomiń, następne pytanie", "pula pra próxima",
            "пропусти, следующий вопрос", "atla, sonraki soru", "スキップして次の質問へ", "跳过，下一题", "跳過，下一個",
            "건너뛰어, 다음 질문으로", "다음으로 넘어가",
        ]
        let notSkips = [
            "", "Toronto", "not sure yet", "next week", "don't skip it", "skip the hotel", "skip?", "blanco", "leer",
            "go ahead and skip it now please", "nicht überspringen", "no lo saltes", "不要跳过", "跳过吗", "スキップしないで",
            "건너뛰지 마세요", "the next one", "next question", "nächste Woche", "la siguiente", "次の質問", "下一个", "다음",
        ]
        for words in skips {
            XCTAssertTrue(HermesCallWaiting.isSkip(words), words)
        }
        for words in notSkips {
            XCTAssertFalse(HermesCallWaiting.isSkip(words), words)
        }
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
        // An approval Hermes didn't take (plugin 0.70.1) is never read as approved.
        let missed = WatchCallAnswer.result(body: ["ok": true, "status": "too_late",
                                                   "message": "It didn't go through: nothing was approved."])
        XCTAssertEqual(missed["status"], "not_pending")
        XCTAssertEqual(missed["message"], "It didn't go through: nothing was approved.")
        let failed = WatchCallAnswer.result(body: ["ok": true, "status": "failed", "message": "It didn't go through."])
        XCTAssertEqual(failed["status"], "failed")
        XCTAssertTrue(failed["message"]?.hasPrefix("It didn't go through.") == true)
        let unconfirmed = WatchCallAnswer.result(body: ["ok": true, "status": "unconfirmed"])
        XCTAssertEqual(unconfirmed["status"], "unconfirmed")
        XCTAssertFalse(unconfirmed["message"]?.contains("didn't go through") ?? true, "not known to have failed")
        XCTAssertNotNil(WatchCallAnswer.result(body: ["ok": false, "detail": "choice must be once or deny"])["error"])

        XCTAssertEqual(WatchCallAnswer.asksFirstLead, HermesCallWaiting.asksFirstLead, "One lead on the phone and the Watch")
        XCTAssertEqual(WatchCallAnswer.delegatedArguments("Answer: 2", userWords: "", approves: false)?["answer"] as? String, "2")
        XCTAssertEqual(WatchCallAnswer.delegatedArguments("Answer:", userWords: "the second one", approves: false)?["answer"] as? String, "the second one")
        XCTAssertNil(WatchCallAnswer.delegatedArguments("Approve: run it", userWords: "yes", approves: false), "The user taps approvals on the Watch")
        XCTAssertEqual(WatchCallAnswer.delegatedArguments("Approve: run it", userWords: "yes", approves: true)?["choice"] as? String, "once")
        XCTAssertNil(WatchCallAnswer.delegatedArguments("Deny: not now", userWords: "no", approves: false), "Nor denies them")
        XCTAssertNil(WatchCallAnswer.delegatedArguments("Check the weather", userWords: "", approves: false))
    }
}
