//
//  AppStateDecisionFenceTests.swift
//  Conduit
//
//  Regression coverage for stale-client fencing on native Hermes decision
//  responses: an approval/clarify respond that was sent through HermesClient
//  A may complete on A after client B has become authoritative (the wire
//  mutation already reached A — that is fine), but its continuation must not
//  mutate AppState. Client identity is the fence, deliberately, so identical
//  profile/session/message ids across two connections cannot leak state.
//
//  The fake socket/transport (shared with ClarifyBatchStateTests) parks the
//  real RPC between send and response, making "operation in flight across a
//  client replacement" deterministic without sleeps.
//

import XCTest
@testable import Conduit

@MainActor
final class AppStateDecisionFenceTests: XCTestCase {

    // MARK: - Fixtures

    private func approvalFixture(
        id: String = "approval-msg",
        status: ApprovalActivity.Status = .pending,
        requestId: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .approval,
            content: "Run the deploy?",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "default",
                requestId: requestId,
                command: "deploy",
                description: "Run the deploy?",
                choices: nil,
                allowPermanent: false,
                smartDenied: false,
                status: status,
                choice: nil,
                error: nil
            )
        )
    }

    private func clarifyFixture(requestId: String = "req-gw") -> ChatMessage {
        ChatMessage(
            id: "clarify-\(requestId)",
            role: .clarify,
            content: "clarify",
            timestamp: "2",
            clarify: ClarifyActivity(
                requestId: requestId,
                questions: [
                    ClarifyQuestion(
                        id: "environment",
                        question: "Which environment?",
                        choices: [ClarifyChoice(label: "staging", value: "staging"), ClarifyChoice(label: "prod", value: "prod")]
                    )
                ]
            )
        )
    }

    private func makeAppState(
        chatResumeLifecycleOperations: ChatResumeLifecycleOperations = .live,
        cache: SessionPresentationCache? = nil
    ) -> AppState {
        let suite = "AppStateDecisionFenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let presentationCache = cache ?? SessionPresentationCache(defaults: defaults)
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: chatResumeLifecycleOperations,
            sessionPresentationCache: presentationCache
        )
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
        transport.nextSocket = { socket }
        appState.connection = connection
        appState.client = client
        let connectTask = Task { try await client.connect() }
        transport.open(socket)
        _ = try await connectTask.value
        return client
    }

    /// An unconnected client instance: never opens a socket, so it is inert
    /// by construction, but it is a DIFFERENT HermesClient object — exactly
    /// what the ownership fence must discriminate.
    private func makeReplacementClient(baseURL: String) -> HermesClient {
        HermesClient(
            connection: HermesConnection(baseUrl: baseURL, ticket: "replaced"),
            profile: "default"
        )
    }

    // MARK: - Park/release helpers

    private struct ParkedRPC {
        let task: Task<Void, Never>
        let rpcID: Int
    }

    private func parkApprovalRespond(
        appState: AppState,
        socket: ClarifyFakeSocket,
        choice: String = "approve"
    ) async throws -> ParkedRPC {
        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        socket.refusesApprovalPendingBeforeRespond = true
        let task = Task {
            await appState.respondToApproval(messageId: "approval-msg", choice: choice)
        }
        try await sent.wait("the approval.respond request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        return ParkedRPC(task: task, rpcID: try XCTUnwrap(request["id"] as? Int))
    }

    private func parkClarifyRespond(
        appState: AppState,
        socket: ClarifyFakeSocket,
        requestId: String = "req-gw"
    ) async throws -> ParkedRPC {
        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        let task = Task {
            await appState.respondToClarify(requestId: requestId, questionId: "environment", answer: "staging")
        }
        try await sent.wait("the clarify.respond request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        return ParkedRPC(task: task, rpcID: try XCTUnwrap(request["id"] as? Int))
    }

    private func deliverResult(_ socket: ClarifyFakeSocket, rpcID: Int, result: [String: Any]) {
        socket.deliver(String(
            decoding: try! JSONSerialization.data(
                withJSONObject: ["jsonrpc": "2.0", "id": rpcID, "result": result]
            ),
            as: UTF8.self
        ))
    }

    private func deliverError(_ socket: ClarifyFakeSocket, rpcID: Int, code: Int, message: String) {
        socket.deliver(String(
            decoding: try! JSONSerialization.data(
                withJSONObject: ["jsonrpc": "2.0", "id": rpcID, "error": ["code": code, "message": message]]
            ),
            as: UTF8.self
        ))
    }

    private func rpcID(_ text: String) throws -> Int {
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(request["id"] as? Int)
    }

    private func prepareActiveSession(_ appState: AppState, id: String = "runtime-queue") {
        appState.sessions = [SessionSummary(
            id: id,
            alternateIds: [],
            title: "Queue",
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: true,
            isArchived: false,
            lineageRootId: nil
        )]
        appState.activeSessionId = id
    }

    func testPendingApprovalRefreshAddsQueuedCardsWithoutResettingSubmission() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        let initial = approvalFixture(id: "approval-a-msg", status: .pending, requestId: "approval-a")
        appState.messages = [initial]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        // Begin in-flight approval submission
        let sentRespond = Gate()
        socket.onSend = { sentRespond.signal() }
        let respondTask = Task {
            await appState.respondToApproval(messageId: "approval-a-msg", choice: "once")
        }
        try await sentRespond.wait("the approval.respond request to be sent")
        let respondRpcID = try rpcID(try XCTUnwrap(socket.sentTexts.last))

        // A queue refresh arrives while submission is actively in flight
        let sentRefresh = Gate()
        socket.onSend = { sentRefresh.signal() }
        let refresh = appState.schedulePendingApprovalsRefresh(sessionId: "runtime-queue", using: client)
        try await sentRefresh.wait("the pending approval request to be sent")
        let refreshRpcID = try rpcID(try XCTUnwrap(socket.sentTexts.last))
        deliverResult(socket, rpcID: refreshRpcID, result: ["approvals": [
            ["request_id": "approval-a", "description": "Run A?"],
            ["request_id": "approval-b", "description": "Run B?"]
        ]])
        await refresh.value

        XCTAssertEqual(appState.messages.count, 2)
        let first = try XCTUnwrap(appState.messages.first(where: { $0.approval?.requestId == "approval-a" })?.approval)
        XCTAssertEqual(first.status, .submitting, "Live in-memory submission must not be reset by queue refresh")
        XCTAssertEqual(first.choice, "once")
        XCTAssertEqual(appState.messages.last?.approval?.requestId, "approval-b")

        // Settle the live submission
        deliverResult(socket, rpcID: respondRpcID, result: ["resolved": 1])
        await respondTask.value
        XCTAssertEqual(appState.messages.first(where: { $0.approval?.requestId == "approval-a" })?.approval?.status, .approved)
    }

    func testAuthoritativeQueueRefreshResetsRestoredSubmittingCardToPending() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        // Simulated restored card from disk: status .submitting, but no live RPC token
        var restored = approvalFixture(id: "approval-b-msg", status: .submitting, requestId: "approval-b")
        restored.approval?.sessionId = "runtime-queue"
        restored.approval?.choice = "once"
        appState.messages = [restored]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let refresh = appState.schedulePendingApprovalsRefresh(sessionId: "runtime-queue", using: client)
        try await sent.wait("the pending approval request to be sent")
        let id = try rpcID(try XCTUnwrap(socket.sentTexts.last))
        deliverResult(socket, rpcID: id, result: ["approvals": [
            ["request_id": "approval-a", "description": "Run A?"],
            ["request_id": "approval-b", "description": "Run B?"]
        ]])
        await refresh.value

        XCTAssertEqual(appState.messages.count, 2)
        let cardB = try XCTUnwrap(appState.messages.first(where: { $0.approval?.requestId == "approval-b" })?.approval)
        XCTAssertEqual(cardB.status, .pending, "Dead restored submitting card must be reset to pending on authoritative queue refresh")
        XCTAssertNil(cardB.choice, "Choice should be reset so user can interact again")
        let cardA = try XCTUnwrap(appState.messages.first(where: { $0.approval?.requestId == "approval-a" })?.approval)
        XCTAssertEqual(cardA.status, .pending)
    }

    func testAuthoritativeQueueRefreshRetiresStaleRestoredApprovalCard() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        // Simulated restored card from disk for approval-b which the server resolved before reconnect
        var restored = approvalFixture(id: "approval-b-msg", status: .submitting, requestId: "approval-b")
        restored.approval?.sessionId = "runtime-queue"
        restored.approval?.choice = "once"
        appState.messages = [restored]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let refresh = appState.schedulePendingApprovalsRefresh(sessionId: "runtime-queue", using: client)
        try await sent.wait("the pending approval request to be sent")
        let id = try rpcID(try XCTUnwrap(socket.sentTexts.last))
        // Server's authoritative queue only returns approval-a; approval-b was resolved
        deliverResult(socket, rpcID: id, result: ["approvals": [
            ["request_id": "approval-a", "description": "Run A?"]
        ]])
        await refresh.value

        XCTAssertEqual(appState.messages.count, 1)
        XCTAssertEqual(appState.messages[0].approval?.requestId, "approval-a")
        XCTAssertFalse(appState.messages.contains(where: { $0.approval?.requestId == "approval-b" }), "Stale restored approval absent from authoritative queue must be retired")
    }

    func testOlderPendingApprovalRefreshCannotPopulateAfterNewerGeneration() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let sent1 = Gate()
        socket.onSend = { sent1.signal() }
        let olderRefresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client
        )
        try await sent1.wait("the first refresh request to be sent")

        let sent2 = Gate()
        socket.onSend = { sent2.signal() }
        let newerRefresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client
        )
        try await sent2.wait("the second refresh request to be sent")

        let oldID = try rpcID(socket.sentTexts[0])
        let newID = try rpcID(socket.sentTexts[1])
        deliverResult(socket, rpcID: newID, result: ["approvals": [
            ["request_id": "approval-new", "description": "New?"]
        ]])
        await newerRefresh.value
        deliverResult(socket, rpcID: oldID, result: ["approvals": [
            ["request_id": "approval-old", "description": "Old?"]
        ]])
        await olderRefresh.value

        XCTAssertEqual(appState.messages.compactMap { $0.approval?.requestId }, ["approval-new"])
    }

    func testPendingApprovalRefreshCannotPopulateReplacementClient() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let refresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client
        )
        try await sent.wait("the refresh request to be sent")
        let id = try rpcID(try XCTUnwrap(socket.sentTexts.last))
        appState.client = makeReplacementClient(baseURL: "https://two.example")
        deliverResult(socket, rpcID: id, result: ["approvals": [
            ["request_id": "approval-stale", "description": "Stale?"]
        ]])
        await refresh.value

        XCTAssertTrue(appState.messages.isEmpty)
    }

    func testSuccessfulApprovalResponseRefreshesAndRevealsNextQueuedRequest() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        appState.messages = [approvalFixture(requestId: "approval-a")]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        deliverResult(socket, rpcID: parked.rpcID, result: ["resolved": 1])
        await parked.task.value
        for _ in 0..<1_000 where socket.sentTexts.count < 2 { await Task.yield() }
        let pendingID = try rpcID(socket.sentTexts[1])
        deliverResult(socket, rpcID: pendingID, result: ["approvals": [
            ["request_id": "approval-b", "description": "Run B?"]
        ]])
        for _ in 0..<1_000 where appState.messages.count < 2 { await Task.yield() }

        XCTAssertEqual(appState.messages.first?.approval?.status, .approved)
        XCTAssertEqual(appState.messages.last?.approval?.requestId, "approval-b")
        XCTAssertEqual(appState.messages.last?.approval?.status, .pending)
    }

    // MARK: - Stale approval completions

    func testApprovalCompletionCannotMutateReplacementRequestWithSameMessageID() async throws {
        let appState = makeAppState()
        appState.messages = [approvalFixture(requestId: "request-a")]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        appState.messages = [approvalFixture(requestId: "request-b")]
        deliverResult(socket, rpcID: parked.rpcID, result: ["resolved": 1])
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.requestId, "request-b")
        XCTAssertEqual(card.status, .pending)
        XCTAssertNil(card.choice)
    }

    func testStaleApprovalSuccessCannotMutateReplacedClientState() async throws {
        let appState = makeAppState()
        appState.messages = [approvalFixture()]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)

        // Client B becomes authoritative and rebuilds its own decision state
        // under IDENTICAL ids (profile "default", session "default", message
        // "approval-msg"): only client identity may discriminate ownership.
        appState.client = makeReplacementClient(baseURL: "https://two.example")
        appState.messages = [approvalFixture()]

        deliverResult(socket, rpcID: parked.rpcID, result: [:])
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .pending, "A stale approval success must not mark B's card approved")
        XCTAssertNil(card.choice)
        XCTAssertNil(card.error)
        XCTAssertNil(appState.errorMessage)
    }

    func testStaleApprovalFailureCannotMutateReplacedClientState() async throws {
        let appState = makeAppState()
        appState.messages = [approvalFixture()]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)

        appState.client = makeReplacementClient(baseURL: "https://two.example")
        appState.messages = [approvalFixture()]

        deliverError(socket, rpcID: parked.rpcID, code: 4002, message: "unknown session")
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .pending, "A stale approval failure must not mark B's card errored")
        XCTAssertNil(card.choice)
        XCTAssertNil(card.error)
        XCTAssertNil(appState.errorMessage, "A stale failure must not surface a user-facing banner on B")
    }

    // MARK: - Stale native clarify completions

    func testStaleClarifySuccessCannotMutateReplacedClientState() async throws {
        let appState = makeAppState()
        appState.messages = [clarifyFixture()]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkClarifyRespond(appState: appState, socket: socket)

        appState.client = makeReplacementClient(baseURL: "https://two.example")
        appState.messages = [clarifyFixture()]

        deliverResult(socket, rpcID: parked.rpcID, result: ["status": "ok", "remaining": []])
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.clarify)
        XCTAssertEqual(card.questions[0].status, .pending, "A stale clarify success must not answer B's question")
        XCTAssertNil(card.questions[0].answer)
        XCTAssertEqual(card.status, .pending)
    }

    func testStaleClarifyFailureCannotMutateReplacedClientState() async throws {
        let appState = makeAppState()
        appState.messages = [clarifyFixture()]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkClarifyRespond(appState: appState, socket: socket)

        appState.client = makeReplacementClient(baseURL: "https://two.example")
        appState.messages = [clarifyFixture()]

        deliverError(socket, rpcID: parked.rpcID, code: 4002, message: "unknown question_id")
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.clarify)
        XCTAssertEqual(card.questions[0].status, .pending, "A stale clarify failure must not error B's question")
        XCTAssertNil(card.questions[0].error)
        XCTAssertNil(appState.errorMessage)
    }

    // MARK: - Same-client controls: existing behavior unchanged

    func testSameClientApprovalSuccessStillCommits() async throws {
        let appState = makeAppState()
        appState.messages = [approvalFixture()]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket, choice: "approve")
        deliverResult(socket, rpcID: parked.rpcID, result: [:])
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .approved)
        XCTAssertEqual(card.choice, "approve")
    }

    func testSameClientApprovalDenyStillRejects() async throws {
        let appState = makeAppState()
        appState.messages = [approvalFixture()]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket, choice: "deny")
        deliverResult(socket, rpcID: parked.rpcID, result: [:])
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .rejected)
        XCTAssertEqual(card.choice, "deny")
    }

    func testRequestIdentifiedApprovalWithZeroResolvedExpires() async throws {
        let appState = makeAppState()
        appState.messages = [approvalFixture(requestId: "stale-request")]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        deliverResult(socket, rpcID: parked.rpcID, result: ["resolved": 0])
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .expired)
        XCTAssertNil(card.choice)
        XCTAssertNotNil(card.error)
        XCTAssertFalse(SessionPresentationCache.isPendingDecision(card.status))
    }

    func testSameClientApprovalFailureStillReportsOnError() async throws {
        let appState = makeAppState()
        appState.messages = [approvalFixture()]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        deliverError(socket, rpcID: parked.rpcID, code: 4002, message: "denied by policy")
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .error)
        XCTAssertEqual(card.error, "Hermes did not accept that decision.")
        XCTAssertEqual(appState.errorMessage, "denied by policy")
    }

    func testLegacySubmissionIgnoresStaleAuthoritativeApprovalUntilFreshPendingRead() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        appState.messages = [approvalFixture()]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        let originalMessageID = appState.messages[0].id
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        appState.handleStreamEvent(.sessionInfo(
            sessionId: "runtime-queue",
            snapshot: SessionRuntimeSnapshot(object: [
                "pending_approval": .object([
                    "request_id": .string("approval-next"),
                    "description": .string("Run next?")
                ])
            ])
        ))

        // Finding 3: Identified approval must coexist rather than being dropped
        XCTAssertEqual(appState.messages.count, 2)
        XCTAssertEqual(appState.messages[0].id, originalMessageID)
        XCTAssertEqual(appState.messages[0].approval?.status, .submitting)
        XCTAssertEqual(appState.messages[1].approval?.requestId, "approval-next")
        XCTAssertEqual(appState.messages[1].approval?.status, .pending)

        deliverResult(socket, rpcID: parked.rpcID, result: ["resolved": 1])
        await parked.task.value

        XCTAssertEqual(appState.messages.first?.id, originalMessageID)
        XCTAssertEqual(appState.messages.first?.approval?.status, .approved)
        XCTAssertEqual(appState.messages.last?.approval?.requestId, "approval-next")
        XCTAssertEqual(appState.messages.last?.approval?.status, .pending)

        for _ in 0..<1_000 where socket.sentTexts.count < 2 { await Task.yield() }
        let freshRefresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client
        )
        for _ in 0..<1_000 where socket.sentTexts.count < 3 { await Task.yield() }
        let pendingID = try rpcID(socket.sentTexts[2])
        deliverResult(socket, rpcID: pendingID, result: ["approvals": [
            ["request_id": "approval-next", "description": "Run next?"]
        ]])
        await freshRefresh.value

        XCTAssertEqual(appState.messages.count, 2)
        XCTAssertEqual(appState.messages.first?.approval?.status, .approved)
        XCTAssertEqual(appState.messages.last?.approval?.requestId, "approval-next")
        XCTAssertEqual(appState.messages.last?.approval?.status, .pending)
    }

    func testLegacySubmissionFailureDoesNotReplayStaleIdentifiedApproval() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        appState.messages = [approvalFixture()]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        let originalMessageID = appState.messages[0].id
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        appState.handleStreamEvent(.approval(
            sessionId: "runtime-queue",
            activity: ApprovalActivity(
                sessionId: "runtime-queue",
                requestId: "approval-stale",
                command: "stale command",
                description: "Stale approval?",
                choices: nil,
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        ))

        deliverError(socket, rpcID: parked.rpcID, code: 4002, message: "denied by policy")
        await parked.task.value

        // Legacy approval fails, identified card coexists as pending
        XCTAssertEqual(appState.messages.count, 2)
        XCTAssertEqual(appState.messages[0].id, originalMessageID)
        XCTAssertEqual(appState.messages[0].approval?.status, .error)
        XCTAssertNil(appState.messages[0].approval?.requestId)
        XCTAssertEqual(appState.messages[1].approval?.requestId, "approval-stale")
        XCTAssertEqual(appState.messages[1].approval?.status, .pending)
    }

    func testLegacySubmissionFailureFreshPendingSnapshotReplacesErrorWithoutDuplicate() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        appState.messages = [approvalFixture()]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        deliverError(socket, rpcID: parked.rpcID, code: 4002, message: "temporary failure")
        await parked.task.value
        for _ in 0..<1_000 where socket.sentTexts.count < 2 { await Task.yield() }
        let refresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client,
            replacingLegacyErrorMessageID: "approval-msg"
        )
        for _ in 0..<1_000 where socket.sentTexts.count < 3 { await Task.yield() }
        let pendingID = try rpcID(socket.sentTexts[2])
        deliverResult(socket, rpcID: pendingID, result: ["approvals": [
            ["request_id": "approval-a", "description": "Run A?"],
            ["request_id": "approval-b", "description": "Run B?"]
        ]])
        await refresh.value

        XCTAssertEqual(
            Set(appState.messages.compactMap { $0.approval?.requestId }),
            Set(["approval-a", "approval-b"])
        )
        XCTAssertFalse(appState.messages.contains { $0.approval?.requestId == nil })
        XCTAssertTrue(appState.messages.allSatisfy { $0.approval?.status == .pending })
    }

    func testLegacySubmissionFailurePendingRefreshFailureRetainsRetryableError() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        appState.messages = [approvalFixture()]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        deliverError(socket, rpcID: parked.rpcID, code: 4002, message: "temporary failure")
        await parked.task.value
        for _ in 0..<1_000 where socket.sentTexts.count < 2 { await Task.yield() }
        let refresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client,
            replacingLegacyErrorMessageID: "approval-msg"
        )
        for _ in 0..<1_000 where socket.sentTexts.count < 3 { await Task.yield() }
        deliverError(socket, rpcID: try rpcID(socket.sentTexts[2]), code: -32601, message: "method unavailable")
        await refresh.value

        let emptyRefresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client,
            replacingLegacyErrorMessageID: "approval-msg"
        )
        for _ in 0..<1_000 where socket.sentTexts.count < 4 { await Task.yield() }
        deliverResult(socket, rpcID: try rpcID(socket.sentTexts[3]), result: ["approvals": []])
        await emptyRefresh.value

        XCTAssertEqual(appState.messages.count, 1)
        XCTAssertEqual(appState.messages[0].approval?.status, .error)
        XCTAssertNil(appState.messages[0].approval?.requestId)
    }

    func testLegacyFailureReplacementRefreshCannotPopulateReplacementClient() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        appState.messages = [approvalFixture()]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        deliverError(socket, rpcID: parked.rpcID, code: 4002, message: "temporary failure")
        await parked.task.value
        for _ in 0..<1_000 where socket.sentTexts.count < 2 { await Task.yield() }
        let refresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client,
            replacingLegacyErrorMessageID: "approval-msg"
        )
        for _ in 0..<1_000 where socket.sentTexts.count < 3 { await Task.yield() }
        appState.client = makeReplacementClient(baseURL: "https://replacement.example")
        deliverResult(socket, rpcID: try rpcID(socket.sentTexts[2]), result: ["approvals": [
            ["request_id": "approval-new", "description": "New?"]
        ]])
        await refresh.value

        XCTAssertEqual(appState.messages.count, 1)
        XCTAssertEqual(appState.messages[0].approval?.status, .error)
        XCTAssertNil(appState.messages[0].approval?.requestId)
    }

    func testExpiredLegacySubmissionRefreshesQueuedIdentifiedApproval() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        appState.messages = [approvalFixture()]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkApprovalRespond(appState: appState, socket: socket)
        deliverError(socket, rpcID: parked.rpcID, code: 4009, message: "no pending approval request")
        await parked.task.value
        for _ in 0..<1_000 where socket.sentTexts.count < 2 { await Task.yield() }
        let refresh = appState.schedulePendingApprovalsRefresh(
            sessionId: "runtime-queue",
            using: client
        )
        for _ in 0..<1_000 where socket.sentTexts.count < 3 { await Task.yield() }
        deliverResult(socket, rpcID: try rpcID(socket.sentTexts[2]), result: ["approvals": [
            ["request_id": "approval-next", "description": "Run next?"]
        ]])
        await refresh.value

        XCTAssertEqual(appState.messages.first?.approval?.status, .expired)
        XCTAssertEqual(appState.messages.last?.approval?.requestId, "approval-next")
        XCTAssertEqual(appState.messages.last?.approval?.status, .pending)
    }

    func testSameClientClarifySuccessStillCommits() async throws {
        let appState = makeAppState()
        appState.messages = [clarifyFixture()]
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let parked = try await parkClarifyRespond(appState: appState, socket: socket)
        deliverResult(socket, rpcID: parked.rpcID, result: ["status": "ok", "remaining": []])
        await parked.task.value

        let card = try XCTUnwrap(appState.messages.first?.clarify)
        XCTAssertEqual(card.questions[0].status, .answered)
        XCTAssertEqual(card.questions[0].answer, "staging")
        XCTAssertEqual(card.status, .answered, "A fully answered single-question request completes")
    }

    // MARK: - A → B → A (ABA)

    func testOriginalOperationStaysStaleAfterABAReconnect() async throws {
        let appState = makeAppState()
        appState.messages = [approvalFixture()]
        let transportA1 = ClarifyFakeTransport()
        let socketA1 = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socketA1, transport: transportA1)

        let parked = try await parkApprovalRespond(appState: appState, socket: socketA1)

        // A → B → A: the "A" that comes back is a NEW HermesClient instance
        // even though the server URL matches the original. Pointer identity
        // must reject the A1 continuation — URL equality must not revive it.
        appState.client = makeReplacementClient(baseURL: "https://two.example")
        let transportA2 = ClarifyFakeTransport()
        let socketA2 = ClarifyFakeSocket()
        let clientA2 = try await installConnectedClient(appState, socket: socketA2, transport: transportA2)
        appState.messages = [approvalFixture()]

        deliverResult(socketA1, rpcID: parked.rpcID, result: [:])
        await parked.task.value

        XCTAssertTrue(appState.client === clientA2, "A2 remains authoritative")
        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .pending, "The A1 completion must stay stale across the ABA reconnect")
        XCTAssertNil(card.choice)
    }

    // MARK: - Relay clarify control (B3 out of scope, path must keep working)

    func testRelayClarifyStillRoutesWithoutHermesClient() async {
        // A relay-prefixed request is owned by the relay registration, not by
        // the HermesClient: with NO client at all it must still take the
        // relay branch (and fail with the relay's own error, never the
        // gateway-unavailable error the client-owned branch would produce).
        // The registration clear is global state — save/restore around it so
        // the test stays hermetic for other suites.
        let priorRegistration = KeychainHelper.loadPushRegistration()
        KeychainHelper.clearPushRegistration()
        addTeardownBlock {
            if let priorRegistration {
                KeychainHelper.savePushRegistration(priorRegistration)
            }
        }
        let appState = makeAppState()
        let requestId = PendingDecisionPayload.relayRequestPrefix + "abc"
        appState.messages = [clarifyFixture(requestId: requestId)]
        appState.client = nil

        await appState.respondToClarify(requestId: requestId, questionId: "environment", answer: "staging")

        let card = appState.messages.first?.clarify
        XCTAssertEqual(card?.questions[0].status, .error, "The relay attempt runs and reports its own outcome")
        XCTAssertNotEqual(
            card?.questions[0].error,
            "Gateway connection is unavailable.",
            "The relay branch must be reachable without any HermesClient"
        )
    }

    // MARK: - Legacy Approval Submitting & Bot Chat Recovery

    func testAuthoritativeLegacyApprovalReplayDuringSubmissionPreservesSubmittingState() async throws {
        let appState = makeAppState()
        let legacyApproval = approvalFixture(status: .pending, requestId: nil)
        appState.messages = [legacyApproval]
        appState.activeSessionId = "default"

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        // User submits decision -> status becomes .submitting
        let parked = try await parkApprovalRespond(appState: appState, socket: socket, choice: "approve")
        XCTAssertEqual(appState.messages.first?.approval?.status, .submitting)
        XCTAssertEqual(appState.messages.count, 1)

        // Authoritative legacy replay arrives while approval.respond is still in flight
        let authoritativeLegacy = ApprovalActivity(
            sessionId: "default",
            requestId: nil,
            command: "deploy",
            description: "Run the deploy?",
            choices: nil,
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        appState.handleStreamEvent(.approval(sessionId: "default", activity: authoritativeLegacy))

        // Card must NOT be re-armed to .pending, must not duplicate
        XCTAssertEqual(appState.messages.count, 1, "Must not create a duplicate card")
        let inFlightCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(inFlightCard.status, .submitting, "Authoritative replay must not overwrite in-flight .submitting status")
        XCTAssertEqual(inFlightCard.choice, "approve", "User's pending choice must be retained")

        // Now deliver response from gateway
        deliverResult(socket, rpcID: parked.rpcID, result: ["resolved": 1])
        await parked.task.value

        // Settle into .approved
        let settledCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(settledCard.status, .approved)
        XCTAssertEqual(settledCard.choice, "approve")
    }

    func testAuthoritativeIdentifiedApprovalReplayDuringSubmissionPreservesSubmittingState() async throws {
        let appState = makeAppState()
        let identifiedApproval = approvalFixture(status: .pending, requestId: "req-identified-1")
        appState.messages = [identifiedApproval]
        appState.activeSessionId = "default"

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        // User submits decision -> status becomes .submitting
        let parked = try await parkApprovalRespond(appState: appState, socket: socket, choice: "approve")
        XCTAssertEqual(appState.messages.first?.approval?.status, .submitting)
        XCTAssertEqual(appState.messages.count, 1)

        // Authoritative replay arrives via sessionInfo snapshot while approval.respond is still in flight
        let snapshot = SessionRuntimeSnapshot(object: [
            "pending_approval": .object([
                "request_id": .string("req-identified-1"),
                "command": .string("deploy"),
                "description": .string("Updated deploy description?")
            ])
        ])
        appState.handleStreamEvent(.sessionInfo(sessionId: "default", snapshot: snapshot))

        // Card must NOT be downgraded to .pending, must not duplicate, choice retained
        XCTAssertEqual(appState.messages.count, 1, "Must not create a duplicate card")
        let inFlightCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(inFlightCard.status, .submitting, "Authoritative replay must not overwrite in-flight .submitting status")
        XCTAssertEqual(inFlightCard.choice, "approve", "User's pending choice must be retained")

        // Now deliver response from gateway
        deliverResult(socket, rpcID: parked.rpcID, result: ["resolved": 1])
        await parked.task.value

        // Settle into .approved
        let settledCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(settledCard.status, .approved)
        XCTAssertEqual(settledCard.choice, "approve")
    }

    func testAuthoritativeReplayDoesNotDowngradeTerminalApprovalStates() {
        let testCases: [(ApprovalActivity.Status, String?)] = [
            (.approved, "approve"),
            (.rejected, "deny"),
            (.expired, nil)
        ]

        for (status, choice) in testCases {
            let appState = makeAppState()
            appState.activeSessionId = "default"
            let terminalApproval = ChatMessage(
                id: "approval-term-\(status)",
                role: .approval,
                content: "Run the deploy?",
                timestamp: "1",
                approval: ApprovalActivity(
                    sessionId: "default",
                    requestId: "req-terminal-1",
                    command: "deploy",
                    description: "Run the deploy?",
                    choices: nil,
                    allowPermanent: false,
                    smartDenied: false,
                    status: status,
                    choice: choice,
                    error: status == .expired ? "Expired" : nil
                )
            )
            appState.messages = [terminalApproval]

            // Authoritative replay arrives with .pending payload
            let snapshot = SessionRuntimeSnapshot(object: [
                "pending_approval": .object([
                    "request_id": .string("req-terminal-1"),
                    "command": .string("deploy"),
                    "description": .string("Replayed description")
                ])
            ])
            appState.handleStreamEvent(.sessionInfo(sessionId: "default", snapshot: snapshot))

            XCTAssertEqual(appState.messages.count, 1)
            let result = appState.messages.first?.approval
            XCTAssertEqual(result?.status, status, "Terminal state \(status) must not be downgraded to .pending")
            XCTAssertEqual(result?.choice, choice)
        }
    }

    func testMultipleIdentifiedApprovalsCoexistAndDoNotInterfere() async throws {
        let appState = makeAppState()
        let card1 = ChatMessage(
            id: "approval-1",
            role: .approval,
            content: "Deploy 1?",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "default",
                requestId: "req-1",
                command: "deploy1",
                description: "Deploy 1?",
                choices: nil,
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        let card2 = ChatMessage(
            id: "approval-2",
            role: .approval,
            content: "Deploy 2?",
            timestamp: "2",
            approval: ApprovalActivity(
                sessionId: "default",
                requestId: "req-2",
                command: "deploy2",
                description: "Deploy 2?",
                choices: nil,
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        appState.messages = [card1, card2]
        appState.activeSessionId = "default"

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        // Submit card1
        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        let task = Task {
            await appState.respondToApproval(messageId: "approval-1", choice: "once")
        }
        try await sent.wait("approval.respond for card1")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let rpcID = try XCTUnwrap(request["id"] as? Int)

        XCTAssertEqual(appState.messages.first(where: { $0.id == "approval-1" })?.approval?.status, .submitting)
        XCTAssertEqual(appState.messages.first(where: { $0.id == "approval-2" })?.approval?.status, .pending)

        // Authoritative update arrives for req-2
        let snapshot = SessionRuntimeSnapshot(object: [
            "pending_approval": .object([
                "request_id": .string("req-2"),
                "command": .string("deploy2"),
                "description": .string("Deploy 2 updated?")
            ])
        ])
        appState.handleStreamEvent(.sessionInfo(sessionId: "default", snapshot: snapshot))

        // req-1 still submitting, req-2 updated
        XCTAssertEqual(appState.messages.count, 2)
        XCTAssertEqual(appState.messages.first(where: { $0.id == "approval-1" })?.approval?.status, .submitting)
        let updatedCard2 = try XCTUnwrap(appState.messages.first(where: { $0.id == "approval-2" })?.approval)
        XCTAssertEqual(updatedCard2.status, .pending)
        XCTAssertEqual(updatedCard2.description, "Deploy 2 updated?")

        // Settle req-1
        deliverResult(socket, rpcID: rpcID, result: ["resolved": 1])
        await task.value
        XCTAssertEqual(appState.messages.first(where: { $0.id == "approval-1" })?.approval?.status, .approved)
    }

    func testSequentialLegacyApprovalsDoNotSwallowSubsequentApprovals() {
        for terminalStatus in [ApprovalActivity.Status.approved, .rejected, .expired] {
            let appState = makeAppState()
            appState.activeSessionId = "default"
            let terminalApproval = ChatMessage(
                id: "approval-legacy-prior-\(terminalStatus)",
                role: .approval,
                content: "First command approval",
                timestamp: "1",
                approval: ApprovalActivity(
                    sessionId: "default",
                    requestId: nil,
                    command: "make build",
                    description: "First command approval",
                    choices: ["approve", "deny"],
                    allowPermanent: false,
                    smartDenied: false,
                    status: terminalStatus,
                    choice: terminalStatus == .approved ? "approve" : (terminalStatus == .rejected ? "deny" : nil),
                    error: terminalStatus == .expired ? "Expired" : nil
                )
            )
            appState.messages = [terminalApproval]

            // Subsequent legacy approval arrives for a new command in the same session
            let nextLegacyApproval = ApprovalActivity(
                sessionId: "default",
                requestId: nil,
                command: "make test",
                description: "Second command approval",
                choices: ["approve", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
            appState.handleStreamEvent(.approval(sessionId: "default", activity: nextLegacyApproval))

            // The terminal legacy card must NOT swallow the new approval
            XCTAssertEqual(appState.messages.count, 2, "A new legacy approval must append after a terminal legacy card")
            XCTAssertEqual(appState.messages[0].approval?.status, terminalStatus)
            XCTAssertEqual(appState.messages[0].approval?.command, "make build")
            XCTAssertEqual(appState.messages[1].approval?.status, .pending)
            XCTAssertEqual(appState.messages[1].approval?.command, "make test")
            XCTAssertEqual(appState.messages[1].approval?.description, "Second command approval")
        }
    }

    func testAuthoritativeReplayResetsRestoredSubmittingCardWhenNoLiveSubmission() throws {
        // Test both identified and legacy restored cards
        let testCases: [(name: String, requestId: String?)] = [
            ("identified", "req-restored-1"),
            ("legacy", nil)
        ]
        for testCase in testCases {
            let appState = makeAppState()
            appState.activeSessionId = "default"
            // Simulate a card that was persisted as .submitting before an app restart
            let restoredCard = ChatMessage(
                id: "approval-\(testCase.name)",
                role: .approval,
                content: "Deploy command",
                timestamp: "1",
                approval: ApprovalActivity(
                    sessionId: "default",
                    requestId: testCase.requestId,
                    command: "deploy",
                    description: "Deploy command",
                    choices: ["approve", "deny"],
                    allowPermanent: false,
                    smartDenied: false,
                    status: .submitting,
                    choice: "approve",
                    error: nil
                )
            )
            appState.messages = [restoredCard]

            // Authoritative replay arrives from gateway with .pending
            if let reqId = testCase.requestId {
                let snapshot = SessionRuntimeSnapshot(object: [
                    "pending_approval": .object([
                        "request_id": .string(reqId),
                        "command": .string("deploy"),
                        "description": .string("Deploy command")
                    ])
                ])
                appState.handleStreamEvent(.sessionInfo(sessionId: "default", snapshot: snapshot))
            } else {
                let snapshot = SessionRuntimeSnapshot(object: [
                    "pending_approval": .object([
                        "command": .string("deploy"),
                        "description": .string("Deploy command")
                    ])
                ])
                appState.handleStreamEvent(.sessionInfo(sessionId: "default", snapshot: snapshot))
            }

            XCTAssertEqual(appState.messages.count, 1)
            let updated = try XCTUnwrap(appState.messages.first?.approval)
            XCTAssertEqual(updated.status, .pending, "Authoritative replay must reset a restored .submitting card with no live RPC token")
            XCTAssertNil(updated.choice, "Pending choice should be cleared so user can interact again")
        }
    }

    func testLegacySubmittingDoesNotDropQueuedIdentifiedApproval() async throws {
        let appState = makeAppState()
        let legacyApproval = approvalFixture(status: .pending, requestId: nil)
        appState.messages = [legacyApproval]
        appState.activeSessionId = "default"

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        // Legacy card begins submitting
        let parked = try await parkApprovalRespond(appState: appState, socket: socket, choice: "approve")
        XCTAssertEqual(appState.messages.first?.approval?.status, .submitting)
        XCTAssertEqual(appState.messages.count, 1)

        // While legacy is submitting, an unrelated identified approval arrives via stream event
        let identifiedApproval = ApprovalActivity(
            sessionId: "default",
            requestId: "req-identified-queued",
            command: "delete-db",
            description: "Delete the database?",
            choices: ["approve", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        appState.handleStreamEvent(.approval(sessionId: "default", activity: identifiedApproval))

        // Both cards must coexist: legacy submitting is not dropped, identified pending is appended
        XCTAssertEqual(appState.messages.count, 2, "Identified approval must not be dropped while legacy is submitting")
        let legacyCard = try XCTUnwrap(appState.messages.first(where: { $0.approval?.requestId == nil })?.approval)
        XCTAssertEqual(legacyCard.status, .submitting)
        let identifiedCard = try XCTUnwrap(appState.messages.first(where: { $0.approval?.requestId == "req-identified-queued" })?.approval)
        XCTAssertEqual(identifiedCard.status, .pending)

        // Settle legacy card
        deliverResult(socket, rpcID: parked.rpcID, result: ["resolved": 1])
        await parked.task.value
        XCTAssertEqual(appState.messages.first(where: { $0.approval?.requestId == nil })?.approval?.status, .approved)
        XCTAssertEqual(appState.messages.first(where: { $0.approval?.requestId == "req-identified-queued" })?.approval?.status, .pending)
    }

    func testBotChatApprovalEvictionAndRecoveryUnderBotProfileNamespace() async throws {
        let suite = "testBotChatApproval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cache = SessionPresentationCache(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: cache
        )
        let botSessionID = "bot-session-approval"
        let botProfile = "bot-profile-approval"
        let dashboardProfile = "dashboard-main"

        appState.setActiveProfileForTesting(dashboardProfile)
        appState.activeSessionId = botSessionID
        appState.noteBotChatSessionForTesting(botSessionID, profile: botProfile)

        // 1. Record a legacy pending approval in Bot Chat
        let legacyApproval = ApprovalActivity(
            sessionId: botSessionID,
            requestId: nil,
            command: "restart_bot",
            description: "Restart bot service?",
            choices: nil,
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        let legacyMessage = ChatMessage(
            id: "legacy-msg",
            role: .approval,
            content: "Restart bot service?",
            timestamp: "1",
            approval: legacyApproval
        )
        cache.recordPendingDecision(legacyMessage, profile: botProfile, sessionIDs: [botSessionID])

        // Verify stored under botProfile, NOT dashboardProfile
        let botStoredKeys = cache.storedPendingDecisionKeys(profile: botProfile, sessionIDs: [botSessionID])
        let dashboardStoredKeys = cache.storedPendingDecisionKeys(profile: dashboardProfile, sessionIDs: [botSessionID])
        XCTAssertTrue(botStoredKeys.contains("approval:\(botSessionID)"), "Approval must be stored under the bot presentation profile")
        XCTAssertTrue(dashboardStoredKeys.isEmpty, "Dashboard profile must have no pending approval entry")

        // 2. Authoritative approval refresh/eviction occurs with an identified approval
        let resumeResult = SessionResumeResult(
            sessionId: botSessionID,
            messages: [],
            snapshot: SessionRuntimeSnapshot(
                object: [
                    "running": .bool(true),
                    "pending_approval": .object([
                        "request_id": .string("req-identified-1"),
                        "command": .string("restart_bot"),
                        "description": .string("Restart bot service?")
                    ])
                ]
            )
        )
        _ = appState.applyChatResume(resumeResult)

        // 3. Verify the correct Bot Chat cache entry is removed
        let updatedBotKeys = cache.storedPendingDecisionKeys(profile: botProfile, sessionIDs: [botSessionID])
        XCTAssertFalse(updatedBotKeys.contains("approval:\(botSessionID)"), "The legacy approval under botProfile must be evicted")

        // 4. Simulate another resume without pending approvals: no stale legacy approval can reappear
        let resumeClean = SessionResumeResult(
            sessionId: botSessionID,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        )
        _ = appState.applyChatResume(resumeClean)
        XCTAssertFalse(appState.messages.contains(where: { $0.approval?.requestId == nil && $0.approval?.status == .pending }), "Stale legacy approval must not reappear after eviction")
    }

    func testDelayedPendingApprovalsRefreshFencedAgainstProfileSwitch() async throws {
        let botSessionID = "bot-session-fenced"
        let botProfile = "bot-profile-fenced"
        let dashboardProfile = "dashboard-main"

        let gate = ClarifyGate()
        var refreshInvoked = false
        let lifecycleOps = ChatResumeLifecycleOperations(
            connectClient: { _ in },
            loadCatalog: { _, _ in [] },
            openSession: { _, _, _ in SessionResumeResult(sessionId: botSessionID, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])) },
            pendingApprovals: { _, _ in
                gate.signal()
                try? await Task.sleep(nanoseconds: 50_000_000)
                refreshInvoked = true
                return [
                    ApprovalActivity(
                        sessionId: botSessionID,
                        requestId: "delayed-req",
                        command: "test",
                        description: "Delayed approval",
                        choices: nil,
                        allowPermanent: false,
                        smartDenied: false,
                        status: .pending,
                        choice: nil,
                        error: nil
                    )
                ]
            }
        )

        let appState = makeAppState(chatResumeLifecycleOperations: lifecycleOps)
        appState.setActiveProfileForTesting(dashboardProfile)
        appState.activeSessionId = botSessionID
        appState.noteBotChatSessionForTesting(botSessionID, profile: botProfile)

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let refreshTask = appState.schedulePendingApprovalsRefresh(sessionId: botSessionID, using: client)
        try await gate.wait("pendingApprovals to be called")

        // Switch active session / presentation profile before refresh completes
        appState.activeSessionId = "other-session"

        await refreshTask.value
        XCTAssertTrue(refreshInvoked)
        XCTAssertFalse(appState.messages.contains { $0.approval?.requestId == "delayed-req" }, "Delayed approval must not land in an abandoned or switched session")
    }

    func testApprovalArrivingDuringPendingApprovalsRPCSurvivesRetirement() async throws {
        let gate = ClarifyGate()
        let resumeGate = ClarifyGate()
        let lifecycleOps = ChatResumeLifecycleOperations(
            pendingApprovals: { _, _ in
                gate.signal()
                try await resumeGate.wait("resume after new approval arrives")
                return [
                    ApprovalActivity(
                        sessionId: "default",
                        requestId: "req-a",
                        command: "deploy",
                        description: "Deploy A",
                        choices: nil,
                        allowPermanent: false,
                        smartDenied: false,
                        status: .pending,
                        choice: nil,
                        error: nil
                    )
                ]
            }
        )
        let appState = makeAppState(chatResumeLifecycleOperations: lifecycleOps)
        appState.activeSessionId = "default"
        let cardA = approvalFixture(id: "msg-a", status: .pending, requestId: "req-a")
        appState.messages = [cardA]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let refreshTask = appState.schedulePendingApprovalsRefresh(sessionId: "default", using: client)
        try await gate.wait("pendingApprovals to start")

        // Approval B arrives via stream event while pendingApprovals RPC is in flight
        let cardB = ApprovalActivity(
            sessionId: "default",
            requestId: "req-b",
            command: "migrate",
            description: "Migrate B",
            choices: nil,
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        appState.handleStreamEvent(.approval(sessionId: "default", activity: cardB))
        XCTAssertEqual(appState.messages.count, 2)

        // Allow pendingApprovals to return queue containing only A
        resumeGate.signal()
        await refreshTask.value

        // Card B must NOT be retired because it was not in the pre-fetch snapshot
        XCTAssertEqual(appState.messages.count, 2)
        XCTAssertTrue(appState.messages.contains { $0.approval?.requestId == "req-a" })
        XCTAssertTrue(appState.messages.contains { $0.approval?.requestId == "req-b" })
    }

    func testPreExistingStaleApprovalRetiresWhenOmittedFromPendingApprovalsRPC() async throws {
        let lifecycleOps = ChatResumeLifecycleOperations(
            pendingApprovals: { _, _ in
                return [
                    ApprovalActivity(
                        sessionId: "default",
                        requestId: "req-a",
                        command: "deploy",
                        description: "Deploy A",
                        choices: nil,
                        allowPermanent: false,
                        smartDenied: false,
                        status: .pending,
                        choice: nil,
                        error: nil
                    )
                ]
            }
        )
        let appState = makeAppState(chatResumeLifecycleOperations: lifecycleOps)
        appState.activeSessionId = "default"
        let cardA = approvalFixture(id: "msg-a", status: .pending, requestId: "req-a")
        let cardB = approvalFixture(id: "msg-b", status: .pending, requestId: "req-b")
        appState.messages = [cardA, cardB]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let refreshTask = appState.schedulePendingApprovalsRefresh(sessionId: "default", using: client)
        await refreshTask.value

        // Card B was pre-existing and omitted from authoritative queue -> retired
        XCTAssertEqual(appState.messages.count, 1)
        XCTAssertEqual(appState.messages.first?.approval?.requestId, "req-a")
    }

    func testLiveSubmissionProtectedFromRetirementDuringPendingApprovalsRPC() async throws {
        let appState = makeAppState(chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
            pendingApprovals: { _, _ in
                return []
            }
        ))
        let card = approvalFixture(id: "approval-msg", status: .pending, requestId: "req-submitting")
        appState.messages = [card]
        appState.activeSessionId = "default"

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        // Card begins live submission (parked)
        let parked = try await parkApprovalRespond(appState: appState, socket: socket, choice: "once")
        XCTAssertEqual(appState.messages.first?.approval?.status, .submitting)

        // Queue refresh returns empty queue while submission is in-flight
        let client = try XCTUnwrap(appState.client)
        let refreshTask = appState.schedulePendingApprovalsRefresh(sessionId: "default", using: client)
        await refreshTask.value

        // Card must NOT be retired because of active in-process live submission
        XCTAssertEqual(appState.messages.count, 1)
        XCTAssertEqual(appState.messages.first?.approval?.status, .submitting)

        // Complete the submission
        deliverResult(socket, rpcID: parked.rpcID, result: ["resolved": 1])
        await parked.task.value
        XCTAssertEqual(appState.messages.first?.approval?.status, .approved)
    }

    func testBotChatPendingApprovalsQueriesBotPresentationProfile() async throws {
        let botSessionID = "bot-session-profile-test"
        let botProfile = "bot-custom-profile"
        let dashboardProfile = "dashboard-main"

        var queriedProfile: String? = nil
        let lifecycleOps = ChatResumeLifecycleOperations(
            pendingApprovalsWithProfile: { _, _, profile in
                queriedProfile = profile
                return []
            }
        )

        let appState = makeAppState(chatResumeLifecycleOperations: lifecycleOps)
        appState.setActiveProfileForTesting(dashboardProfile)
        appState.activeSessionId = botSessionID
        appState.noteBotChatSessionForTesting(botSessionID, profile: botProfile)

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        let refreshTask = appState.schedulePendingApprovalsRefresh(sessionId: botSessionID, using: client)
        await refreshTask.value

        XCTAssertEqual(queriedProfile, botProfile, "Bot Chat pending approvals refresh must use the bot's presentation profile")
    }

    func testBotChatApprovalRespondUsesBotPresentationProfile() async throws {
        let botSessionID = "bot-session-approval-test"
        let botProfile = "bot-custom-profile"
        let dashboardProfile = "dashboard-main"

        var passedProfile: String? = nil
        var passedSessionId: String? = nil
        var passedRequestId: String? = nil
        var passedChoice: String? = nil

        let lifecycleOps = ChatResumeLifecycleOperations(
            respondToApproval: { _, sessionId, requestId, choice, profile in
                passedSessionId = sessionId
                passedRequestId = requestId
                passedChoice = choice
                passedProfile = profile
                return true
            }
        )

        let appState = makeAppState(chatResumeLifecycleOperations: lifecycleOps)
        appState.setActiveProfileForTesting(dashboardProfile)
        appState.activeSessionId = botSessionID
        appState.noteBotChatSessionForTesting(botSessionID, profile: botProfile)

        let card = ChatMessage(
            id: "approval-msg",
            role: .approval,
            content: "Please approve",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: botSessionID,
                requestId: "req-bot-1",
                command: "bot_action",
                description: "Run bot action?",
                choices: ["approve", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        appState.messages = [card]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        await appState.respondToApproval(messageId: "approval-msg", choice: "approve")

        XCTAssertEqual(passedSessionId, botSessionID)
        XCTAssertEqual(passedRequestId, "req-bot-1")
        XCTAssertEqual(passedChoice, "approve")
        XCTAssertEqual(passedProfile, botProfile, "Bot Chat approval respond must use the bot's presentation profile")
    }

    func testBotChatApprovalRespondSendsBotProfileOverWire() async throws {
        let botSessionID = "bot-session-wire-test"
        let botProfile = "bot-custom-profile"
        let dashboardProfile = "dashboard-main"

        let appState = makeAppState()
        appState.setActiveProfileForTesting(dashboardProfile)
        appState.activeSessionId = botSessionID
        appState.noteBotChatSessionForTesting(botSessionID, profile: botProfile)

        let card = ChatMessage(
            id: "approval-msg-wire",
            role: .approval,
            content: "Please approve",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: botSessionID,
                requestId: "req-wire-1",
                command: "wire_action",
                description: "Run bot action?",
                choices: ["approve", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        appState.messages = [card]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }

        let respondTask = Task {
            await appState.respondToApproval(messageId: "approval-msg-wire", choice: "approve")
        }
        try await sent.wait("approval.respond to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["profile"] as? String, botProfile)
        XCTAssertEqual(params["session_id"] as? String, botSessionID)
        XCTAssertEqual(params["request_id"] as? String, "req-wire-1")
        XCTAssertEqual(params["choice"] as? String, "approve")

        let rpcID = try XCTUnwrap(request["id"] as? Int)
        deliverResult(socket, rpcID: rpcID, result: ["resolved": 1])
        await respondTask.value

        XCTAssertEqual(appState.messages.first?.approval?.status, .approved)
    }

    // MARK: - Live Legacy Submission & Error State Precedence Tests

    func testLiveLegacySubmissionSurvivesAuthoritativeResumeOmission() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState, id: "legacy-session")
        let card = ChatMessage(
            id: "legacy-msg",
            role: .approval,
            content: "Run legacy deploy?",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "legacy-session",
                requestId: nil,
                command: "deploy",
                description: "Run legacy deploy?",
                choices: ["once", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        appState.messages = [card]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        // Begin submission via respondToApproval so liveApprovalSubmissions contains .legacy("legacy-session")
        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        socket.refusesApprovalPendingBeforeRespond = true
        let respondTask = Task {
            await appState.respondToApproval(messageId: "legacy-msg", choice: "once")
        }
        try await sent.wait("the approval.respond request to be sent")

        // Card is now .submitting with choice "once" and live token in flight
        let submittingCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(submittingCard.status, .submitting)
        XCTAssertEqual(submittingCard.choice, "once")

        // Authoritative resume arrives while RPC is still in flight; snapshot has running == false and omits legacy approval
        let resumeResult = SessionResumeResult(
            sessionId: "legacy-session",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        )
        _ = appState.applyChatResume(resumeResult)

        // A must remain .submitting with choice "once" because live submission token protects it
        let afterResumeCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(afterResumeCard.status, .submitting, "Live in-flight legacy submission must not be reset to .pending by resume")
        XCTAssertEqual(afterResumeCard.choice, "once")

        // Complete the RPC
        let rpcID = try rpcID(try XCTUnwrap(socket.sentTexts.last))
        deliverResult(socket, rpcID: rpcID, result: ["resolved": 1])
        await respondTask.value

        let finalCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(finalCard.status, .approved)
    }

    func testRestoredLegacySubmissionWithoutLiveTokenResetsToPendingOnResumeOmission() throws {
        let suite = "AppStateDecisionFenceTests.RestoredLegacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cache = SessionPresentationCache(defaults: defaults)
        let appState = makeAppState(cache: cache)
        prepareActiveSession(appState, id: "restored-legacy-session")
        let card = ChatMessage(
            id: "restored-legacy-msg",
            role: .approval,
            content: "Run legacy deploy?",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "restored-legacy-session",
                requestId: nil,
                command: "deploy",
                description: "Run legacy deploy?",
                choices: ["once", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .submitting,
                choice: "once",
                error: "previous error"
            )
        )
        cache.recordPendingDecision(
            card,
            profile: "default",
            sessionIDs: ["restored-legacy-session"]
        )
        appState.messages = [card]

        // No live token exists (restored from disk after process restart)
        // Resume occurs and omits approval
        let resumeResult = SessionResumeResult(
            sessionId: "restored-legacy-session",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        )
        _ = appState.applyChatResume(resumeResult)

        let afterResumeCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(afterResumeCard.status, .pending, "Restored legacy .submitting card without live token must reset to .pending")
        XCTAssertNil(afterResumeCard.choice, "Reset card must clear choice")
        XCTAssertNil(afterResumeCard.error, "Reset card must clear error")
    }

    func testIdentifiedLiveSubmissionSurvivesAuthoritativeResumeOmission() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState, id: "identified-session")
        let card = ChatMessage(
            id: "identified-msg",
            role: .approval,
            content: "Run identified deploy?",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "identified-session",
                requestId: "req-live-1",
                command: "deploy",
                description: "Run identified deploy?",
                choices: ["once", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        appState.messages = [card]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        // Begin submission via respondToApproval so liveApprovalSubmissions contains .identified("req-live-1")
        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        let respondTask = Task {
            await appState.respondToApproval(messageId: "identified-msg", choice: "once")
        }
        try await sent.wait("the approval.respond request to be sent")

        let submittingCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(submittingCard.status, .submitting)
        XCTAssertEqual(submittingCard.choice, "once")

        // Authoritative resume arrives while RPC is in flight, omitting req-live-1
        let resumeResult = SessionResumeResult(
            sessionId: "identified-session",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        )
        _ = appState.applyChatResume(resumeResult)

        let afterResumeCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(afterResumeCard.status, .submitting, "Live in-flight identified submission must survive resume")
        XCTAssertEqual(afterResumeCard.choice, "once")

        let rpcID = try rpcID(try XCTUnwrap(socket.sentTexts.last))
        deliverResult(socket, rpcID: rpcID, result: ["resolved": 1])
        await respondTask.value

        let finalCard = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(finalCard.status, .approved)
    }

    func testSameLegacyRequestReplayPreservesError() throws {
        let appState = makeAppState()
        prepareActiveSession(appState, id: "sess-error-replay")
        let existing = ChatMessage(
            id: "card-1",
            role: .approval,
            content: "Deploy command A",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "sess-error-replay",
                requestId: nil,
                command: "cmd_a",
                description: "Deploy command A",
                choices: ["allow", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .error,
                choice: "allow",
                error: "Network failed"
            )
        )
        appState.messages = [existing]

        // Replay of same legacy request
        let replayedActivity = ApprovalActivity(
            sessionId: "sess-error-replay",
            requestId: nil,
            command: "cmd_a",
            description: "Deploy command A",
            choices: ["allow", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        appState.handleStreamEvent(.approval(sessionId: "sess-error-replay", activity: replayedActivity))

        XCTAssertEqual(appState.messages.count, 1)
        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .error, "Replaying the same legacy request must preserve local .error")
        XCTAssertEqual(card.error, "Network failed")
        XCTAssertEqual(card.choice, "allow")
        XCTAssertEqual(card.command, "cmd_a")
    }

    func testDifferentLegacyRequestReplacesStaleError() throws {
        let appState = makeAppState()
        prepareActiveSession(appState, id: "sess-error-replace")
        let existing = ChatMessage(
            id: "card-1",
            role: .approval,
            content: "Deploy command A",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "sess-error-replace",
                requestId: nil,
                command: "cmd_a",
                description: "Deploy command A",
                choices: ["allow", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .error,
                choice: "allow",
                error: "Network failed"
            )
        )
        appState.messages = [existing]

        // Different legacy request arrives in the same session
        let newActivity = ApprovalActivity(
            sessionId: "sess-error-replace",
            requestId: nil,
            command: "cmd_b",
            description: "Deploy command B",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        appState.handleStreamEvent(.approval(sessionId: "sess-error-replace", activity: newActivity))

        XCTAssertEqual(appState.messages.count, 1, "Must not append a second retryable legacy card")
        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .pending, "Different legacy request must replace stale .error with fresh .pending")
        XCTAssertNil(card.choice, "Stale choice must be cleared")
        XCTAssertNil(card.error, "Stale error must be cleared")
        XCTAssertEqual(card.command, "cmd_b")
        XCTAssertEqual(card.description, "Deploy command B")
        XCTAssertEqual(card.choices, ["once", "deny"])
    }

    func testIdentifiedApprovalReplayPreservesError() throws {
        let appState = makeAppState()
        prepareActiveSession(appState, id: "sess-identified-error")
        let existing = ChatMessage(
            id: "card-identified-1",
            role: .approval,
            content: "Deploy X",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "sess-identified-error",
                requestId: "req-err-1",
                command: "cmd_x",
                description: "Deploy X",
                choices: ["once", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .error,
                choice: "once",
                error: "Timeout"
            )
        )
        appState.messages = [existing]

        // Stream replay of same identified approval
        let replayedActivity = ApprovalActivity(
            sessionId: "sess-identified-error",
            requestId: "req-err-1",
            command: "cmd_x",
            description: "Deploy X",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        appState.handleStreamEvent(.approval(sessionId: "sess-identified-error", activity: replayedActivity))

        XCTAssertEqual(appState.messages.count, 1)
        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.status, .error, "Identified approval replay must preserve local .error")
        XCTAssertEqual(card.error, "Timeout")
        XCTAssertEqual(card.choice, "once")
    }

    func testSequentialLegacyTerminalCardDoesNotSwallowSubsequentLegacyApproval() throws {
        let appState = makeAppState()
        prepareActiveSession(appState, id: "sess-terminal-seq")
        let terminalCard = ChatMessage(
            id: "card-terminal-1",
            role: .approval,
            content: "Deploy command A",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: "sess-terminal-seq",
                requestId: nil,
                command: "cmd_a",
                description: "Deploy command A",
                choices: ["allow", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .approved,
                choice: "allow",
                error: nil
            )
        )
        appState.messages = [terminalCard]

        // Subsequent legacy request arrives
        let nextActivity = ApprovalActivity(
            sessionId: "sess-terminal-seq",
            requestId: nil,
            command: "cmd_b",
            description: "Deploy command B",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        appState.handleStreamEvent(.approval(sessionId: "sess-terminal-seq", activity: nextActivity))

        XCTAssertEqual(appState.messages.count, 2, "A terminal legacy card must not swallow a subsequent legacy approval")
        let first = try XCTUnwrap(appState.messages[0].approval)
        XCTAssertEqual(first.status, .approved)
        XCTAssertEqual(first.command, "cmd_a")

        let second = try XCTUnwrap(appState.messages[1].approval)
        XCTAssertEqual(second.status, .pending)
        XCTAssertEqual(second.command, "cmd_b")
        XCTAssertNil(second.choice)
        XCTAssertNil(second.error)
    }

    func testApprovalRespondSuccessRefreshesApprovalSessionNotActiveSession() async throws {
        let approvalSessionID = "session-A"
        let activeSessionID = "session-B"
        let approvalProfile = "profile-for-A"
        let defaultProfile = "default-profile"

        var refreshedSessionID: String? = nil
        var refreshedProfile: String? = nil
        let gate = Gate()

        let lifecycleOps = ChatResumeLifecycleOperations(
            pendingApprovalsWithProfile: { _, sessionId, profile in
                refreshedSessionID = sessionId
                refreshedProfile = profile
                gate.signal()
                return []
            },
            respondToApproval: { _, sessionId, requestId, choice, profile in
                return true
            }
        )

        let appState = makeAppState(chatResumeLifecycleOperations: lifecycleOps)
        appState.setActiveProfileForTesting(defaultProfile)
        appState.activeSessionId = activeSessionID
        appState.noteBotChatSessionForTesting(approvalSessionID, profile: approvalProfile)

        let card = ChatMessage(
            id: "msg-approval-A",
            role: .approval,
            content: "Approve action",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: approvalSessionID,
                requestId: "req-A-1",
                command: "cmd_a",
                description: "Approve action",
                choices: ["allow", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        appState.messages = [card]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        await appState.respondToApproval(messageId: "msg-approval-A", choice: "allow")
        try await gate.wait("pending approvals refresh")

        XCTAssertEqual(
            refreshedSessionID, approvalSessionID,
            "Follow-up queue refresh after approval response must target the card's session, not activeSessionId"
        )
        XCTAssertEqual(
            refreshedProfile, approvalProfile,
            "Follow-up queue refresh must use the approval session's presentation profile"
        )
        XCTAssertEqual(appState.messages.first?.approval?.status, .approved)
    }

    func testLegacyApprovalRespondErrorRefreshesApprovalSessionWithReplacementID() async throws {
        let approvalSessionID = "session-A"
        let activeSessionID = "session-B"
        let approvalProfile = "profile-for-A"
        let defaultProfile = "default-profile"

        var refreshedSessionID: String? = nil
        var refreshedProfile: String? = nil
        let gate = Gate()

        let freshIdentifiedApproval = ApprovalActivity(
            sessionId: approvalSessionID,
            requestId: "req-fresh-1",
            command: "cmd_fresh",
            description: "Fresh command",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )

        // A gateway without approval.pending until the answer, so the card
        // is answered by session; the refresh after it reads the queue.
        var responded = false
        let lifecycleOps = ChatResumeLifecycleOperations(
            pendingApprovalsWithProfile: { _, sessionId, profile in
                guard responded else { throw RpcError(code: -32601, message: "unknown method: approval.pending") }
                refreshedSessionID = sessionId
                refreshedProfile = profile
                gate.signal()
                return [freshIdentifiedApproval]
            },
            respondToApproval: { _, sessionId, requestId, choice, profile in
                responded = true
                throw HermesError.invalidResponse
            }
        )

        let appState = makeAppState(chatResumeLifecycleOperations: lifecycleOps)
        appState.setActiveProfileForTesting(defaultProfile)
        appState.activeSessionId = activeSessionID
        appState.noteBotChatSessionForTesting(approvalSessionID, profile: approvalProfile)

        let card = ChatMessage(
            id: "msg-legacy-A",
            role: .approval,
            content: "Legacy action",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: approvalSessionID,
                requestId: nil,
                command: "cmd_legacy",
                description: "Legacy action",
                choices: ["allow", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        appState.messages = [card]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        await appState.respondToApproval(messageId: "msg-legacy-A", choice: "allow")
        try await gate.wait("pending approvals refresh")

        XCTAssertEqual(
            refreshedSessionID, approvalSessionID,
            "Legacy error follow-up refresh must target the approval card's session, not activeSessionId"
        )
        XCTAssertEqual(
            refreshedProfile, approvalProfile,
            "Legacy error follow-up refresh must use the approval session's presentation profile"
        )
        XCTAssertEqual(appState.messages.count, 1)
        XCTAssertEqual(appState.messages.first?.approval?.requestId, "req-fresh-1")
    }

    func testLegacyApprovalRespondExpiredRefreshesApprovalSession() async throws {
        let approvalSessionID = "session-A"
        let activeSessionID = "session-B"
        let approvalProfile = "profile-for-A"
        let defaultProfile = "default-profile"

        var refreshedSessionID: String? = nil
        var refreshedProfile: String? = nil
        let gate = Gate()

        // A gateway without approval.pending until the answer, so the card
        // is answered by session; the refresh after it reads the queue.
        var responded = false
        let lifecycleOps = ChatResumeLifecycleOperations(
            pendingApprovalsWithProfile: { _, sessionId, profile in
                guard responded else { throw RpcError(code: -32601, message: "unknown method: approval.pending") }
                refreshedSessionID = sessionId
                refreshedProfile = profile
                gate.signal()
                return []
            },
            respondToApproval: { _, sessionId, requestId, choice, profile in
                responded = true
                throw RpcError(code: 4009, message: "no pending approval request")
            }
        )

        let appState = makeAppState(chatResumeLifecycleOperations: lifecycleOps)
        appState.setActiveProfileForTesting(defaultProfile)
        appState.activeSessionId = activeSessionID
        appState.noteBotChatSessionForTesting(approvalSessionID, profile: approvalProfile)

        let card = ChatMessage(
            id: "msg-legacy-expired",
            role: .approval,
            content: "Legacy action",
            timestamp: "1",
            approval: ApprovalActivity(
                sessionId: approvalSessionID,
                requestId: nil,
                command: "cmd_legacy",
                description: "Legacy action",
                choices: ["allow", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        appState.messages = [card]

        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        _ = try await installConnectedClient(appState, socket: socket, transport: transport)

        await appState.respondToApproval(messageId: "msg-legacy-expired", choice: "allow")
        try await gate.wait("pending approvals refresh")

        XCTAssertEqual(
            refreshedSessionID, approvalSessionID,
            "Legacy expired follow-up refresh must target the approval card's session, not activeSessionId"
        )
        XCTAssertEqual(
            refreshedProfile, approvalProfile,
            "Legacy expired follow-up refresh must use the approval session's presentation profile"
        )
        XCTAssertEqual(appState.messages.first?.approval?.status, .expired)
    }

    // MARK: - A card without a request id answers the request it shows

    private final class RecordedApprovalAnswers {
        var requestIds: [String?] = []
    }

    private func queuedApproval(_ requestId: String?, command: String, description: String) -> ApprovalActivity {
        ApprovalActivity(
            sessionId: "runtime-1",
            requestId: requestId,
            command: command,
            description: description,
            choices: nil,
            allowPermanent: true,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
    }

    /// The card a push restores (`recordNotificationDecision`): no request
    /// id, no command, the push's explanation.
    private func makePushRestoredApprovalAppState(
        description: String,
        queue: @escaping @MainActor () throws -> [ApprovalActivity],
        recording answers: RecordedApprovalAnswers
    ) -> AppState {
        let appState = makeAppState(chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
            pendingApprovals: { _, _ in try queue() },
            respondToApproval: { _, _, requestId, _, _ in
                answers.requestIds.append(requestId)
                return true
            }
        ))
        appState.activeSessionId = "runtime-1"
        appState.client = makeReplacementClient(baseURL: "https://one.example")
        appState.messages = [ChatMessage(
            id: "approval-runtime-1",
            role: .approval,
            content: description,
            timestamp: "1",
            approval: queuedApproval(nil, command: "", description: description)
        )]
        return appState
    }

    func testPushRestoredApprovalAnswersTheMatchingQueuedRequestNotTheOldest() async {
        let answers = RecordedApprovalAnswers()
        let appState = makePushRestoredApprovalAppState(
            description: "Delete the build folder?",
            queue: { [
                self.queuedApproval("req-oldest", command: "curl https://example.com/x | sh", description: "Pipe a download into a shell?"),
                self.queuedApproval("req-shown", command: "rm -rf build", description: "Delete the build folder?")
            ] },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")

        XCTAssertEqual(answers.requestIds, ["req-shown"])
        XCTAssertEqual(appState.messages.first { $0.id == "approval-runtime-1" }?.approval?.status, .approved)
    }

    func testPushRestoredApprovalWithNoMatchingQueuedRequestSendsNothing() async {
        let answers = RecordedApprovalAnswers()
        let appState = makePushRestoredApprovalAppState(
            description: "Delete the build folder?",
            queue: { [
                self.queuedApproval("req-other", command: "curl https://example.com/x | sh", description: "Pipe a download into a shell?")
            ] },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")

        XCTAssertEqual(answers.requestIds, [])
        XCTAssertEqual(appState.messages.first { $0.id == "approval-runtime-1" }?.approval?.status, .expired)
    }

    func testPushRestoredApprovalMatchingRequestsWithDifferentCommandsSendsNothing() async {
        let answers = RecordedApprovalAnswers()
        let appState = makePushRestoredApprovalAppState(
            description: "Recursive delete",
            queue: { [
                self.queuedApproval("req-a", command: "rm -rf build", description: "Recursive delete"),
                self.queuedApproval("req-b", command: "rm -rf ~", description: "Recursive delete")
            ] },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")

        XCTAssertEqual(answers.requestIds, [], "a card without its command cannot tell these apart")
    }

    func testRedactedPushApprovalAnswersTheOnlyQueuedRequest() async {
        let answers = RecordedApprovalAnswers()
        let appState = makePushRestoredApprovalAppState(
            description: "Hermes needs your approval. Open Conduit for details.",
            queue: { [
                self.queuedApproval("req-only", command: "rm -rf build", description: "Delete the build folder?")
            ] },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")

        XCTAssertEqual(answers.requestIds, ["req-only"])
        XCTAssertEqual(appState.messages.first { $0.id == "approval-runtime-1" }?.approval?.status, .approved)
    }

    func testRedactedPushApprovalWithTwoQueuedSendsNothingAndRefreshes() async {
        let answers = RecordedApprovalAnswers()
        var queueReads = 0
        let appState = makePushRestoredApprovalAppState(
            description: "Hermes needs your approval. Open Conduit for details.",
            queue: {
                queueReads += 1
                return [
                    self.queuedApproval("req-a", command: "rm -rf build", description: "Delete the build folder?"),
                    self.queuedApproval("req-b", command: "make test", description: "Run the tests?")
                ]
            },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")
        for _ in 0..<1_000 where queueReads < 2 { await Task.yield() }

        XCTAssertEqual(answers.requestIds, [], "a redacted card cannot tell two queued requests apart")
        XCTAssertGreaterThanOrEqual(queueReads, 2, "the queue's own cards are fetched to replace it")
        XCTAssertNotEqual(appState.messages.first { $0.id == "approval-runtime-1" }?.approval?.status, .approved)
    }

    func testClippedPushDescriptionMatchesItsFullQueuedRequest() async {
        let answers = RecordedApprovalAnswers()
        // The notifier collapses whitespace and cuts at 500 code points.
        let full = "Run the migration script?\n\n" + String(repeating: "Step detail. ", count: 60)
        let pushed = String(full.split(whereSeparator: \.isWhitespace).joined(separator: " ").unicodeScalars.prefix(500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appState = makePushRestoredApprovalAppState(
            description: pushed,
            queue: { [
                self.queuedApproval("req-other", command: "make test", description: "Run the tests?"),
                self.queuedApproval("req-full", command: "./migrate.sh", description: full)
            ] },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")

        XCTAssertEqual(answers.requestIds, ["req-full"])
    }

    func testLegacyApprovalOnGatewayWithoutRequestIdsStillAnswersBySession() async {
        let answers = RecordedApprovalAnswers()
        let appState = makePushRestoredApprovalAppState(
            description: "Delete the build folder?",
            queue: { [
                self.queuedApproval(nil, command: "rm -rf build", description: "Delete the build folder?")
            ] },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "deny")

        XCTAssertEqual(answers.requestIds, [nil])
        XCTAssertEqual(appState.messages.first { $0.id == "approval-runtime-1" }?.approval?.status, .rejected)
    }

    func testLegacyApprovalOnGatewayWithoutApprovalPendingStillAnswersBySession() async {
        let answers = RecordedApprovalAnswers()
        let appState = makePushRestoredApprovalAppState(
            description: "Delete the build folder?",
            queue: { throw RpcError(code: -32601, message: "unknown method: approval.pending") },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")

        XCTAssertEqual(answers.requestIds, [nil])
        XCTAssertEqual(appState.messages.first { $0.id == "approval-runtime-1" }?.approval?.status, .approved)
    }

    /// The card's runtime is gone (a reaped runtime, or a chat another
    /// device re-opened): Hermes answers "session not found", so nothing is
    /// waiting on this card any more. That is "no longer active", not a
    /// decision Hermes refused.
    func testLegacyApprovalWhoseSessionIsGoneIsNoLongerActive() async {
        let answers = RecordedApprovalAnswers()
        let appState = makePushRestoredApprovalAppState(
            description: "Delete the build folder?",
            queue: { throw RpcError(code: 4001, message: "session not found") },
            recording: answers
        )

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")

        let card = appState.messages.first { $0.id == "approval-runtime-1" }?.approval
        XCTAssertEqual(answers.requestIds, [], "nothing is sent to a session that is gone")
        XCTAssertEqual(card?.status, .expired)
        XCTAssertEqual(card?.error, AppLocalization.string("This approval is no longer active."))
    }

    func testIdentifiedApprovalWhoseSessionIsGoneIsNoLongerActive() async {
        let appState = makeAppState(chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
            respondToApproval: { _, _, _, _, _ in
                throw RpcError(code: 4001, message: "session not found")
            }
        ))
        appState.activeSessionId = "runtime-1"
        appState.client = makeReplacementClient(baseURL: "https://one.example")
        appState.messages = [ChatMessage(
            id: "approval-runtime-1",
            role: .approval,
            content: "Delete the build folder?",
            timestamp: "1",
            approval: queuedApproval("req-1", command: "rm -rf build", description: "Delete the build folder?")
        )]

        await appState.respondToApproval(messageId: "approval-runtime-1", choice: "once")

        let card = appState.messages.first { $0.id == "approval-runtime-1" }?.approval
        XCTAssertEqual(card?.status, .expired)
        XCTAssertEqual(card?.error, AppLocalization.string("This approval is no longer active."))
        XCTAssertNil(appState.errorMessage, "an approval that ended is not an error banner")
    }

    // MARK: - Answering what the card showed

    /// A legacy (request-less) card is updated in place when Hermes
    /// announces the next command, so a tap made on the old content must
    /// not answer the new one.
    private final class RecordedApprovalResponses {
        var choices: [String] = []
    }

    private func shownApproval(requestId: String? = nil) -> ApprovalActivity {
        ApprovalActivity(
            sessionId: "runtime-1",
            requestId: requestId,
            command: "ls ~/Downloads",
            description: "List the downloads?",
            choices: nil,
            allowPermanent: true,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
    }

    private func makeShownApprovalAppState(
        _ approval: ApprovalActivity,
        recording responses: RecordedApprovalResponses
    ) -> AppState {
        let appState = makeAppState(chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
            // The gateway still queues the card's request; a legacy card's
            // queue names no request ids, so it is answered by session.
            pendingApprovals: { _, _ in [approval] },
            respondToApproval: { _, _, _, choice, _ in
                responses.choices.append(choice)
                return true
            }
        ))
        appState.activeSessionId = approval.sessionId
        appState.client = makeReplacementClient(baseURL: "https://one.example")
        appState.messages = [ChatMessage(
            id: "approval-shown",
            role: .approval,
            content: approval.description,
            timestamp: "1",
            approval: approval
        )]
        return appState
    }

    func testLegacyCardReplacedByNextCommandIsNotAnsweredWithTheOldTap() async {
        let responses = RecordedApprovalResponses()
        let shown = shownApproval()
        let appState = makeShownApprovalAppState(shown, recording: responses)
        appState.messages[0].approval?.command = "rm -rf ~"
        appState.messages[0].approval?.description = "Delete the home folder?"

        await appState.respondToApproval(messageId: "approval-shown", choice: "always", shown: shown)

        XCTAssertEqual(responses.choices, [], "a tap on the old command must not answer the new one")
        XCTAssertEqual(appState.messages.first?.approval?.status, .pending)
        XCTAssertNil(appState.messages.first?.approval?.choice)
    }

    func testApprovalWhoseOfferedChoicesChangedIsNotAnswered() async {
        let responses = RecordedApprovalResponses()
        let shown = shownApproval(requestId: "req-shown")
        let appState = makeShownApprovalAppState(shown, recording: responses)
        appState.messages[0].approval?.allowPermanent = false

        await appState.respondToApproval(messageId: "approval-shown", choice: "always", shown: shown)

        XCTAssertEqual(responses.choices, [])
        XCTAssertEqual(appState.messages.first?.approval?.status, .pending)
    }

    func testUnchangedApprovalIsAnswered() async {
        let responses = RecordedApprovalResponses()
        let shown = shownApproval(requestId: "req-shown")
        let appState = makeShownApprovalAppState(shown, recording: responses)

        await appState.respondToApproval(messageId: "approval-shown", choice: "once", shown: shown)

        XCTAssertEqual(responses.choices, ["once"])
        XCTAssertEqual(appState.messages.first?.approval?.status, .approved)
    }

    func testRetryAfterErrorAndDurableSessionMoveIsStillAnswered() async {
        let responses = RecordedApprovalResponses()
        let shown = shownApproval()
        let appState = makeShownApprovalAppState(shown, recording: responses)
        // Progress and the hidden session identity are not the question.
        appState.messages[0].approval?.status = .error
        appState.messages[0].approval?.error = "Hermes did not accept that decision."
        appState.messages[0].approval?.sessionId = "durable-1"

        await appState.respondToApproval(messageId: "approval-shown", choice: "deny", shown: shown)

        XCTAssertEqual(responses.choices, ["deny"])
        XCTAssertEqual(appState.messages.first?.approval?.status, .rejected)
    }

    /// A legacy card the next command replaces while the queue is read is
    /// not answered: a session-queue answer would go to the new command.
    func testLegacyCardReplacedWhileTheQueueIsReadSendsNothing() async {
        let responses = RecordedApprovalResponses()
        let shown = shownApproval()
        weak var weakState: AppState?
        let appState = makeAppState(chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
            pendingApprovals: { _, _ in
                weakState?.messages[0].approval?.command = "rm -rf ~"
                weakState?.messages[0].approval?.description = "Delete the home folder?"
                return [shown]
            },
            respondToApproval: { _, _, _, choice, _ in
                responses.choices.append(choice)
                return true
            }
        ))
        weakState = appState
        installShownApproval(shown, in: appState)

        await appState.respondToApproval(messageId: "approval-shown", choice: "once", shown: shown)

        XCTAssertEqual(responses.choices, [], "the tap on the old command must not answer the new one")
        XCTAssertEqual(appState.messages.first?.approval?.status, .pending)
        XCTAssertNil(appState.messages.first?.approval?.choice)
    }

    /// A legacy card the next command replaces while its answer is in
    /// flight does not show that answer: the card now asks something else.
    func testLegacyCardReplacedWhileItsAnswerIsInFlightIsNotStampedWithIt() async {
        let shown = shownApproval()
        weak var weakState: AppState?
        let appState = makeAppState(chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
            pendingApprovals: { _, _ in [shown] },
            respondToApproval: { _, _, _, _, _ in
                weakState?.messages[0].approval?.command = "rm -rf ~"
                weakState?.messages[0].approval?.description = "Delete the home folder?"
                return true
            }
        ))
        weakState = appState
        installShownApproval(shown, in: appState)

        await appState.respondToApproval(messageId: "approval-shown", choice: "once", shown: shown)

        let card = appState.messages.first?.approval
        XCTAssertEqual(card?.command, "rm -rf ~")
        XCTAssertEqual(card?.status, .pending, "the new command is still unanswered")
        XCTAssertNil(card?.choice)
        XCTAssertNil(card?.error)
    }

    private func installShownApproval(_ approval: ApprovalActivity, in appState: AppState) {
        appState.activeSessionId = approval.sessionId
        appState.client = makeReplacementClient(baseURL: "https://one.example")
        appState.messages = [ChatMessage(
            id: "approval-shown",
            role: .approval,
            content: approval.description,
            timestamp: "1",
            approval: approval
        )]
    }
}

private final class Gate: @unchecked Sendable {
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
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.lock.lock()
                guard !self.signalled, let c = self.continuation else {
                    self.lock.unlock()
                    return
                }
                self.continuation = nil
                self.lock.unlock()
                c.resume(returning: true)
            }
        }
        if timedOut {
            XCTFail("Timed out waiting for \(phase)", file: file, line: line)
        }
    }
}
