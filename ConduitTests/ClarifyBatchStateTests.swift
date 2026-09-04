//
//  ClarifyBatchStateTests.swift
//  Conduit
//
//  End-to-end batch clarification lifecycle against a real AppState: per
//  question locking via the gateway's `remaining` list, failure isolation,
//  expiration, replay dedupe, and `pending_clarify` restore on resume.
//

import XCTest
@testable import Conduit

@MainActor
final class ClarifyBatchStateTests: XCTestCase {

    // MARK: - Fixtures

    /// The batch shape Hermes 0.21+ emits for one `clarify` invocation that
    /// asks two questions plus a free-text note.
    private func makeBatchActivity(requestId: String = "req-batch") -> ClarifyActivity {
        ClarifyActivity(
            requestId: requestId,
            questions: [
                ClarifyQuestion(
                    id: "environment",
                    question: "Which environment?",
                    choices: [ClarifyChoice(label: "staging", value: "staging"), ClarifyChoice(label: "prod", value: "prod")]
                ),
                ClarifyQuestion(
                    id: "tests",
                    question: "Which tests should run?",
                    choices: [ClarifyChoice(label: "unit", value: "unit"), ClarifyChoice(label: "ui", value: "ui")],
                    multiSelect: true
                ),
                ClarifyQuestion(id: "notes", question: "Any additional notes?", choices: [])
            ]
        )
    }

    private func makeAppState() -> (appState: AppState, cache: SessionPresentationCache) {
        let suite = "ClarifyBatchStateTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: cache
        )
        appState.activeSessionId = "stored-a"
        return (appState, cache)
    }

    private func installConnectedClient(
        _ appState: AppState,
        socket: ClarifyFakeSocket,
        transport: ClarifyFakeTransport
    ) async throws -> HermesClient {
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        let client = HermesClient(
            connection: connection,
            profile: "default",
            transportFactory: { transport }
        )
        appState.connection = connection
        appState.client = client
        let connectTask = Task { try await client.connect() }
        transport.open(socket)
        _ = try await connectTask.value
        return client
    }

    /// Runs `respondToClarify` against a connected fake socket, answers the
    /// RPC with `result`, and returns the captured request frame.
    @discardableResult
    private func respond(
        appState: AppState,
        socket: ClarifyFakeSocket,
        requestId: String,
        questionId: String?,
        answer: String,
        result: [String: Any]
    ) async throws -> [String: Any] {
        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        let task = Task {
            await appState.respondToClarify(
                requestId: requestId,
                questionId: questionId,
                answer: answer
            )
        }
        try await sent.wait("the clarify.respond request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        socket.deliver(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self))
        _ = await task.value
        return request
    }

    /// Same as `respond` but completes the RPC with a thrown error.
    private func respondFailing(
        appState: AppState,
        socket: ClarifyFakeSocket,
        requestId: String,
        questionId: String?,
        answer: String,
        error: RpcError
    ) async throws {
        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        let task = Task {
            await appState.respondToClarify(
                requestId: requestId,
                questionId: questionId,
                answer: answer
            )
        }
        try await sent.wait("the clarify.respond request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": error.code ?? -1, "message": error.message]
        ]
        socket.deliver(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self))
        _ = await task.value
    }

    private func clarifyCard(in appState: AppState, requestId: String) -> ClarifyActivity? {
        appState.messages
            .first { $0.role == .clarify && $0.clarify?.requestId == requestId }?
            .clarify
    }

    // MARK: - Per-question locking

    func testAnsweringFirstBatchQuestionLocksOnlyThatQuestion() async throws {
        let (appState, _) = makeAppState()
        defer { appState.sessionPresentationCacheForTesting?.clear() }
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: makeBatchActivity())
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        try await respond(
            appState: appState,
            socket: socket,
            requestId: "req-batch",
            questionId: "environment",
            answer: "staging",
            result: ["status": "ok", "remaining": ["tests", "notes"]]
        )

        let activity = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(activity.questions[0].status, .answered, "The answered question locks")
        XCTAssertEqual(activity.questions[0].answer, "staging")
        XCTAssertEqual(activity.questions[1].status, .pending, "The gateway's remaining list keeps other questions open")
        XCTAssertEqual(activity.questions[2].status, .pending)
        XCTAssertEqual(activity.status, .pending, "A partially answered batch must not read ANSWERED")
    }

    func testAnsweringFinalBatchQuestionCompletesRequest() async throws {
        let (appState, _) = makeAppState()
        var activity = makeBatchActivity()
        activity.questions[0].status = .answered
        activity.questions[0].answer = "staging"
        activity.questions[1].status = .answered
        activity.questions[1].answer = ClarifyQuestion.multiSelectAnswer(["unit"])
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: activity)
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        let request = try await respond(
            appState: appState,
            socket: socket,
            requestId: "req-batch",
            questionId: "notes",
            answer: "none",
            result: ["status": "ok", "remaining": []]
        )

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["request_id"] as? String, "req-batch")
        XCTAssertEqual(params["question_id"] as? String, "notes")
        XCTAssertEqual(params["answer"] as? String, "none")
        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(settled.questions.map(\.status), [.answered, .answered, .answered])
        XCTAssertEqual(settled.status, .answered, "The final answer completes the whole request")
    }

    func testAnsweredMultiSelectQuestionStoresWireAnswer() async throws {
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: makeBatchActivity())
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        try await respond(
            appState: appState,
            socket: socket,
            requestId: "req-batch",
            questionId: "tests",
            answer: ClarifyQuestion.multiSelectAnswer(["ui", "unit"]),
            result: ["status": "ok", "remaining": ["environment", "notes"]]
        )

        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(settled.questions[1].status, .answered)
        // Wire answer round-trips into display form, mapped back to labels.
        XCTAssertEqual(settled.questions[1].resolvedAnswer, "unit, ui")
    }

    // MARK: - Failure isolation

    func testFailedRespondRestoresOnlyTheRelevantQuestion() async throws {
        let (appState, _) = makeAppState()
        var activity = makeBatchActivity()
        activity.questions[0].status = .answered
        activity.questions[0].answer = "staging"
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: activity)
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        try await respondFailing(
            appState: appState,
            socket: socket,
            requestId: "req-batch",
            questionId: "tests",
            answer: ClarifyQuestion.multiSelectAnswer(["ui"]),
            error: RpcError(code: 4002, message: "unknown question_id 'tests'")
        )

        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(settled.questions[0].status, .answered, "A sibling's failed submit must not corrupt an answered question")
        XCTAssertEqual(settled.questions[0].answer, "staging")
        XCTAssertEqual(settled.questions[1].status, .error, "Only the failed question returns to an error/answerable state")
        XCTAssertEqual(settled.questions[1].error, "Hermes did not accept that answer.")
        XCTAssertEqual(settled.questions[2].status, .pending)
        XCTAssertEqual(settled.status, .pending, "The batch still needs input")
    }

    // MARK: - Expiration

    func testExpiredRespondOutcomeDoesNotAppearAnswered() async throws {
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: makeBatchActivity())
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        try await respond(
            appState: appState,
            socket: socket,
            requestId: "req-batch",
            questionId: "environment",
            answer: "staging",
            result: ["status": "expired"]
        )

        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(settled.status, .expired, "The typed expired outcome must never read as success")
        XCTAssertTrue(settled.isExpired)
        XCTAssertEqual(settled.questions[0].status, .expired)
        XCTAssertEqual(settled.questions[1].status, .expired)
    }

    func testExpired4009ErrorResponseTearsDownTheRequest() async throws {
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(id: "clarify-req-legacy", role: .clarify, content: "legacy", timestamp: "1", clarify: ClarifyActivity(requestId: "req-legacy", question: "Pick", choices: [ClarifyChoice(label: "a", value: "a")]))
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        try await respondFailing(
            appState: appState,
            socket: socket,
            requestId: "req-legacy",
            questionId: nil,
            answer: "a",
            error: RpcError(code: 4009, message: "no pending clarify request")
        )

        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-legacy"))
        XCTAssertEqual(settled.status, .expired)
        XCTAssertTrue(settled.isExpired)
        XCTAssertEqual(settled.questions[0].status, .expired)
    }

    func testClarifyExpireEventTearsDownOnlyTheMatchingRequest() async throws {
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: makeBatchActivity()),
            ChatMessage(id: "clarify-req-other", role: .clarify, content: "other", timestamp: "2", clarify: ClarifyActivity(requestId: "req-other", question: "Other?", choices: [ClarifyChoice(label: "x", value: "x")]))
        ]

        appState.handleStreamEvent(.clarifyExpire(sessionId: "stored-a", requestId: "req-batch"))

        let expired = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(expired.status, .expired, "Expired questions stop presenting answer controls")
        XCTAssertEqual(expired.questions[1].status, .expired)
        XCTAssertNotNil(expired.error, "The card explains why the controls disappeared")
        let untouched = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-other"))
        XCTAssertEqual(untouched.status, .pending, "Request identity — not question text — decides what expires")
        XCTAssertNil(untouched.error)
    }

    // MARK: - Duplicate / replay identity

    func testLegacyScalarCardAnswersAtRequestLevelWithoutQuestionID() async throws {
        // A legacy scalar card's question id is minted locally ("q0"); the
        // wire frame must keep the legacy request-level shape the gateway
        // has always accepted, never a question_id the server cannot know.
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(
                id: "clarify-req-legacy",
                role: .clarify,
                content: "Pick",
                timestamp: "1",
                clarify: ClarifyActivity(
                    requestId: "req-legacy",
                    question: "Pick",
                    choices: [ClarifyChoice(label: "a", value: "a")]
                )
            )
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        let request = try await respond(
            appState: appState,
            socket: socket,
            requestId: "req-legacy",
            questionId: "q0",
            answer: "a",
            result: ["status": "ok"]
        )

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["request_id"] as? String, "req-legacy")
        XCTAssertNil(params["question_id"], "A synthetic qid must never ride the wire")
        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-legacy"))
        XCTAssertEqual(settled.questions[0].status, .answered)
        XCTAssertEqual(settled.status, .answered)
    }

    func testGatewayBatchQIDAlwaysRidesTheWireEvenWhenQ0() async throws {
        // A REAL gateway batch can mint "q0" as its first qid — the synthetic
        // marker, not the id value, decides the wire shape.
        let (appState, _) = makeAppState()
        var activity = ClarifyActivity(
            requestId: "req-real",
            questions: [ClarifyQuestion(id: "q0", question: "Real?", choices: [ClarifyChoice(label: "x", value: "x")])]
        )
        activity.questions[0].isSyntheticID = false
        appState.messages = [
            ChatMessage(id: "clarify-req-real", role: .clarify, content: "real", timestamp: "1", clarify: activity)
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        let request = try await respond(
            appState: appState,
            socket: socket,
            requestId: "req-real",
            questionId: "q0",
            answer: "x",
            result: ["status": "ok", "remaining": []]
        )

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["question_id"] as? String, "q0", "A gateway-minted qid is addressed per question")
    }

    func testAcceptedOutcomeSettlesSiblingsTheGatewayNoLongerLists() async throws {
        // `remaining` is the gateway's authority on what is still open. A
        // sibling it no longer lists was locked by another surface; settle it
        // without claiming this device's answer text.
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: makeBatchActivity())
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        try await respond(
            appState: appState,
            socket: socket,
            requestId: "req-batch",
            questionId: "environment",
            answer: "staging",
            result: ["status": "ok", "remaining": ["notes"]]
        )

        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(settled.questions[0].status, .answered)
        XCTAssertEqual(settled.questions[0].answer, "staging")
        XCTAssertEqual(settled.questions[1].status, .answered, "Absent from remaining ⇒ locked elsewhere")
        XCTAssertNil(settled.questions[1].answer, "The locked-elsewhere row must not display this device's answer text")
        XCTAssertEqual(settled.questions[2].status, .pending, "Still listed in remaining ⇒ stays answerable")
    }

    func testAcceptedOutcomeCannotResurrectAnExpiredRequest() async throws {
        // Expire lands while the respond RPC is in flight (reconnect race);
        // the accepted response that arrives afterwards must not flip the
        // expired card back to answered.
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: makeBatchActivity())
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        let task = Task {
            await appState.respondToClarify(
                requestId: "req-batch",
                questionId: "environment",
                answer: "staging"
            )
        }
        try await sent.wait("the clarify.respond request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(request["id"] as? Int)

        // Expire arrives before the RPC response.
        appState.handleStreamEvent(.clarifyExpire(sessionId: "stored-a", requestId: "req-batch"))

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["status": "ok", "remaining": []]
        ]
        socket.deliver(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self))
        _ = await task.value

        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(settled.status, .expired, "A late accepted outcome cannot make an expired request read as answered")
        XCTAssertTrue(settled.isExpired)
    }

    func testReplayAfterExpireKeepsQuestionsExpired() {
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: makeBatchActivity())
        ]
        appState.handleStreamEvent(.clarifyExpire(sessionId: "stored-a", requestId: "req-batch"))
        appState.handleStreamEvent(.clarify(sessionId: "stored-a", activity: makeBatchActivity()))

        let settled = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(settled.status, .expired, "A replayed one-shot event must not re-arm an expired card")
        XCTAssertEqual(settled.questions[0].status, .expired)
        XCTAssertEqual(settled.questions[2].status, .expired)
    }

    func testDuplicateClarifyEventUpdatesInsteadOfDuplicating() async throws {
        let (appState, _) = makeAppState()
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: makeBatchActivity())
        ]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        try await installConnectedClient(appState, socket: socket, transport: transport)

        try await respond(
            appState: appState,
            socket: socket,
            requestId: "req-batch",
            questionId: "environment",
            answer: "staging",
            result: ["status": "ok", "remaining": ["tests", "notes"]]
        )

        // A replayed one-shot event (WS replay buffer) carries all questions
        // as pending again. It must not duplicate the card nor unlock the
        // answer the gateway already accepted.
        appState.handleStreamEvent(.clarify(sessionId: "stored-a", activity: makeBatchActivity()))

        let cards = appState.messages.filter { $0.role == .clarify && $0.clarify?.requestId == "req-batch" }
        XCTAssertEqual(cards.count, 1, "Replay data for the same request_id must not create a second card")
        XCTAssertEqual(cards.first?.clarify?.questions[0].status, .answered, "A replayed pending event must not unlock an accepted answer")
        XCTAssertEqual(cards.first?.clarify?.questions[0].answer, "staging")
        XCTAssertEqual(cards.first?.clarify?.questions[1].status, .pending)
    }

    // MARK: - Resume: pending_clarify

    func testResumeRestoresPendingClarifyBatchWithLockedAnswers() throws {
        let (appState, _) = makeAppState()
        let result = SessionResumeResult(
            sessionId: "stored-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(true),
                "pending_clarify": .object([
                    "request_id": .string("req-batch"),
                    "questions": .array([
                        .object([
                            "qid": .string("environment"),
                            "question": .string("Which environment?"),
                            "choices": .array([.string("staging"), .string("prod")]),
                            "multi_select": .bool(false)
                        ]),
                        .object([
                            "qid": .string("notes"),
                            "question": .string("Any additional notes?"),
                            "choices": .array([])
                        ])
                    ]),
                    "answers": .object(["environment": .string("staging")])
                ])
            ])
        )

        XCTAssertTrue(appState.applyChatResume(result))

        let restored = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(restored.questions.count, 2)
        XCTAssertEqual(restored.questions[0].status, .answered, "Already locked answers restore as locked")
        XCTAssertEqual(restored.questions[0].answer, "staging")
        XCTAssertEqual(restored.questions[1].status, .pending, "Remaining questions stay answerable")
        XCTAssertEqual(restored.status, .pending)
    }

    func testSessionInfoSnapshotAlsoRestoresPendingClarify() throws {
        // Some gateway generations carry pending_clarify on session.info
        // snapshots too; wherever it appears it is the same authoritative
        // restore contract.
        let (appState, _) = makeAppState()
        let snapshot = SessionRuntimeSnapshot(object: [
            "running": .bool(true),
            "pending_clarify": .object([
                "request_id": .string("req-info"),
                "questions": .array([
                    .object([
                        "qid": .string("environment"),
                        "question": .string("Which environment?"),
                        "choices": .array([.string("staging")])
                    ])
                ])
            ])
        ])

        appState.handleStreamEvent(.sessionInfo(sessionId: "stored-a", snapshot: snapshot))

        let restored = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-info"))
        XCTAssertEqual(restored.questions[0].status, .pending)
        XCTAssertEqual(restored.status, .pending)
    }

    func testResumeReplayUpdatesAnExistingPendingClarifyCardInPlace() throws {
        let (appState, _) = makeAppState()
        // A live card already present (the one-shot event fired, one answer
        // locked), then a reconnect resume reports the same pending request.
        var live = makeBatchActivity()
        live.questions[0].status = .answered
        live.questions[0].answer = "staging"
        appState.messages = [
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: live)
        ]
        let result = SessionResumeResult(
            sessionId: "stored-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(true),
                "pending_clarify": .object([
                    "request_id": .string("req-batch"),
                    "questions": .array([
                        .object([
                            "qid": .string("environment"),
                            "question": .string("Which environment?"),
                            "choices": .array([.string("staging"), .string("prod")])
                        ]),
                        .object([
                            "qid": .string("notes"),
                            "question": .string("Any additional notes?"),
                            "choices": .array([])
                        ])
                    ])
                ])
            ])
        )

        XCTAssertTrue(appState.applyChatResume(result))

        let cards = appState.messages.filter { $0.role == .clarify && $0.clarify?.requestId == "req-batch" }
        XCTAssertEqual(cards.count, 1, "A reconnect resume must update, not duplicate, the existing card")
        XCTAssertEqual(cards.first?.clarify?.questions[0].status, .answered)
        XCTAssertEqual(cards.first?.clarify?.questions[1].status, .pending)
    }

    func testRestoredSubmittingQuestionResetsWithoutUnlockingAnsweredSiblings() throws {
        // A .submitting question persisted before a crash has no knowable
        // outcome. An ambiguous resume resets only that question; answered
        // siblings stay locked.
        let (appState, cache) = makeAppState()
        var card = makeBatchActivity()
        card.questions[0].status = .answered
        card.questions[0].answer = "staging"
        card.questions[1].status = .submitting
        card.questions[1].answer = ClarifyQuestion.multiSelectAnswer(["unit"])
        cache.recordPendingDecision(
            ChatMessage(id: "clarify-req-batch", role: .clarify, content: "batch", timestamp: "1", clarify: card),
            profile: appState.activeProfile,
            sessionIDs: ["stored-a"]
        )
        let result = SessionResumeResult(
            sessionId: "stored-a",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        )

        XCTAssertTrue(appState.applyChatResume(result))

        let restored = try XCTUnwrap(clarifyCard(in: appState, requestId: "req-batch"))
        XCTAssertEqual(restored.questions[0].status, .answered, "Answered siblings survive the ambiguous resume")
        XCTAssertEqual(restored.questions[0].answer, "staging")
        XCTAssertEqual(restored.questions[1].status, .pending, "An in-flight question resets to answerable")
        XCTAssertNil(restored.questions[1].answer)
    }

    // MARK: - Model helpers

    func testMultiSelectAnswerSerializationRoundTrips() throws {
        let wire = ClarifyQuestion.multiSelectAnswer(["unit", "ui"])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String])
        XCTAssertEqual(decoded, ["unit", "ui"], "The wire form is a JSON array string, exactly what Hermes' batch parser accepts")
    }

    func testRequestStatusDerivation() {
        var activity = makeBatchActivity()
        XCTAssertEqual(activity.status, .pending)

        activity.questions[0].status = .answered
        XCTAssertEqual(activity.status, .pending, "One locked sub-question never marks the card ANSWERED")

        activity.questions[1].status = .submitting
        XCTAssertEqual(activity.status, .submitting)

        activity.questions[1].status = .answered
        activity.questions[2].status = .answered
        XCTAssertEqual(activity.status, .answered)

        activity.questions[2].status = .error
        XCTAssertEqual(activity.status, .error, "An all-errored card reads TRY AGAIN")

        activity.questions[2].status = .pending
        activity.isExpired = true
        XCTAssertEqual(activity.status, .expired, "Expiry outranks every other state")
    }
}

// MARK: - Test doubles (mirrors the HermesClientTests fakes; private to this file)

@MainActor
private final class ClarifyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal() {
        lock.lock()
        signalled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: false)
    }

    func wait(
        _ phase: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let timedOut = await withCheckedContinuation { continuation in
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            self.continuation = continuation
            lock.unlock()
            Task<Void, Never>.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .seconds(timeout))
                self.fireDeadline()
            }
        }
        if timedOut {
            XCTFail("Timed out after \(timeout)s waiting for \(phase)", file: file, line: line)
            throw ClarifyTestTimedOut(phase: phase)
        }
    }

    private func fireDeadline() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let signalled = self.signalled
        lock.unlock()
        if !signalled {
            continuation?.resume(returning: true)
        }
    }
}

private struct ClarifyTestTimedOut: Error {
    let phase: String
}

private final class ClarifyFakeSocket: HermesWebSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var sentTexts: [String] = []
    var onSend: (() -> Void)?
    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        receiveContinuation?.resume(throwing: URLError(.networkConnectionLost))
        receiveContinuation = nil
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message {
            sentTexts.append(text)
            onSend?()
        }
        completionHandler(nil)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func deliver(_ text: String) {
        receiveContinuation?.resume(returning: .string(text))
        receiveContinuation = nil
    }
}

private final class ClarifyFakeTransport: HermesWebSocketTransport {
    private var openCallbacks: [ObjectIdentifier: () -> Void] = [:]
    private var earlyOpenRequests = Set<ObjectIdentifier>()

    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket {
        let socket = ClarifyFakeSocket()
        openCallbacks[ObjectIdentifier(socket)] = { onOpen(socket) }
        if earlyOpenRequests.remove(ObjectIdentifier(socket)) != nil,
           let callback = openCallbacks.removeValue(forKey: ObjectIdentifier(socket)) {
            callback()
        }
        return socket
    }

    func invalidate() {}

    func open(_ socket: ClarifyFakeSocket) {
        let key = ObjectIdentifier(socket)
        if let callback = openCallbacks.removeValue(forKey: key) {
            callback()
        } else {
            earlyOpenRequests.insert(key)
        }
    }
}
