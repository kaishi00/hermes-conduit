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
        status: ApprovalActivity.Status = .pending,
        requestId: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: "approval-msg",
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

    private func makeAppState() -> AppState {
        let suite = "AppStateDecisionFenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let cache = SessionPresentationCache(defaults: defaults)
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: cache
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
        appState.messages = [approvalFixture(status: .submitting, requestId: "approval-a")]
        appState.messages[0].approval?.sessionId = "runtime-queue"
        appState.messages[0].approval?.choice = "once"
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        appState.schedulePendingApprovalsRefresh(sessionId: "runtime-queue", using: client)
        for _ in 0..<1_000 where socket.sentTexts.isEmpty { await Task.yield() }
        let id = try rpcID(try XCTUnwrap(socket.sentTexts.last))
        deliverResult(socket, rpcID: id, result: ["approvals": [
            ["request_id": "approval-a", "description": "Run A?"],
            ["request_id": "approval-b", "description": "Run B?"]
        ]])
        for _ in 0..<1_000 where appState.messages.count < 2 { await Task.yield() }

        XCTAssertEqual(appState.messages.count, 2)
        let first = try XCTUnwrap(appState.messages.first(where: { $0.approval?.requestId == "approval-a" })?.approval)
        XCTAssertEqual(first.status, .submitting)
        XCTAssertEqual(first.choice, "once")
        XCTAssertEqual(appState.messages.last?.approval?.requestId, "approval-b")
    }

    func testOlderPendingApprovalRefreshCannotPopulateAfterNewerGeneration() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        appState.schedulePendingApprovalsRefresh(sessionId: "runtime-queue", using: client)
        for _ in 0..<1_000 where socket.sentTexts.count < 1 { await Task.yield() }
        appState.schedulePendingApprovalsRefresh(sessionId: "runtime-queue", using: client)
        for _ in 0..<1_000 where socket.sentTexts.count < 2 { await Task.yield() }
        let oldID = try rpcID(socket.sentTexts[0])
        let newID = try rpcID(socket.sentTexts[1])
        deliverResult(socket, rpcID: newID, result: ["approvals": [
            ["request_id": "approval-new", "description": "New?"]
        ]])
        for _ in 0..<1_000 where appState.messages.isEmpty { await Task.yield() }
        deliverResult(socket, rpcID: oldID, result: ["approvals": [
            ["request_id": "approval-old", "description": "Old?"]
        ]])
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(appState.messages.compactMap { $0.approval?.requestId }, ["approval-new"])
    }

    func testPendingApprovalRefreshCannotPopulateReplacementClient() async throws {
        let appState = makeAppState()
        prepareActiveSession(appState)
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        let client = try await installConnectedClient(appState, socket: socket, transport: transport)

        appState.schedulePendingApprovalsRefresh(sessionId: "runtime-queue", using: client)
        for _ in 0..<1_000 where socket.sentTexts.isEmpty { await Task.yield() }
        let id = try rpcID(try XCTUnwrap(socket.sentTexts.last))
        appState.client = makeReplacementClient(baseURL: "https://two.example")
        deliverResult(socket, rpcID: id, result: ["approvals": [
            ["request_id": "approval-stale", "description": "Stale?"]
        ]])
        await Task.yield()
        await Task.yield()

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
}
