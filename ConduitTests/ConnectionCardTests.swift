//
//  ConnectionCardTests.swift
//  ConduitTests
//
//  The connect card Hermes waits on in a chat (`connection.request` /
//  `connection.update`, answered through `connection.respond`): what
//  Conduit reads from the frames, how a newer one moves the card, and what
//  it sends back.
//

import XCTest
@testable import Conduit

@MainActor
final class ConnectionCardTests: XCTestCase {
    private func object(_ json: String) throws -> [String: AnyCodable] {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        return try XCTUnwrap(value.objectValue)
    }

    private func request(seq: Int = 1, state: String = "initiated", url: String = "https://portal.example.com/connect/abc") throws -> ConnectionActivity {
        try XCTUnwrap(ConnectionActivity.from(payload: object(#"""
        {"op_id": "op1", "seq": \#(seq), "deadline_at": 1900000000, "timeout_seconds": 600, "tool_call_id": "call_1",
         "targets": [
           {"name": "gmail", "kind": "connector", "action": "connect", "state": "\#(state)", "connect_url": "\#(url)", "connection_id": "c9"},
           {"name": "github_mcp", "kind": "mcp", "action": "install", "state": "pending", "instructions": "Make a token",
            "required_env": [
              {"name": "GITHUB_TOKEN", "required": true, "secret": true, "default": "should-not-show", "prompt": "Personal access token"},
              {"name": "GITHUB_HOST", "required": false, "secret": false, "default": "github.com"}
            ]},
           {"name": "linear", "kind": "plugin", "action": "install", "state": "pending", "display": "Linear", "description": "Issues",
            "tier": "community", "scan": {"status": "warnings", "summary": "Runs a shell"}}
         ]}
        """#), sessionId: "rt-1"))
    }

    func testARequestReadsAsHermesSendsIt() throws {
        let card = try request()
        XCTAssertEqual(card.opID, "op1")
        XCTAssertEqual(card.sessionId, "rt-1")
        XCTAssertEqual(card.toolCallID, "call_1")
        XCTAssertTrue(card.isOpen)
        XCTAssertFalse(card.isDisplay)
        XCTAssertEqual(card.deadline, Date(timeIntervalSince1970: 1_900_000_000))

        let gmail = try XCTUnwrap(card.targets.first)
        XCTAssertEqual(gmail.title, "Gmail")
        XCTAssertTrue(gmail.opensPage)
        XCTAssertFalse(gmail.asksApproval)

        let github = card.targets[1]
        XCTAssertEqual(github.title, "Github MCP")
        XCTAssertTrue(github.asksApproval)
        XCTAssertEqual(github.fields.map(\.label), ["Personal access token", "GITHUB_HOST"])
        XCTAssertEqual(github.fields[0].defaultValue, "", "A secret never starts from a value Hermes sent")
        XCTAssertEqual(github.fields[1].defaultValue, "github.com")

        let linear = card.targets[2]
        XCTAssertEqual(linear.title, "Linear")
        XCTAssertEqual(linear.scanStatus, "warnings")
        XCTAssertTrue(linear.asksApproval)
    }

    func testOnlyAWebPageOpensAndOnlyAChatsOwnOperationShows() throws {
        let card = try request(url: "file:///etc/passwd")
        XCTAssertNil(card.targets[0].connectURL)
        XCTAssertFalse(card.targets[0].opensPage)
        let account = try object(#"{"op_id": "op2", "seq": 1, "owner": {"type": "account"}, "targets": []}"#)
        XCTAssertNil(ConnectionActivity.from(payload: account, sessionId: "rt-1"), "The Apps page's own sign-ins aren't a chat's card")
        let update = try object(#"{"op_id": "op3", "seq": 2, "settled": false, "owner": {"type": "session", "session_id": "rt-9"}, "targets": []}"#)
        XCTAssertEqual(ConnectionActivity.from(payload: update, sessionId: "")?.sessionId, "rt-9")
    }

    func testTheDirectoryCardListsHermesSuggestions() throws {
        let card = try XCTUnwrap(ConnectionActivity.from(payload: object(#"""
        {"op_id": "op4", "seq": 1, "deadline_at": 0, "targets": [], "display": {"suggested": ["gmail", " ", "slack"]}}
        """#), sessionId: "rt-1"))
        XCTAssertTrue(card.isDisplay)
        XCTAssertEqual(card.suggested, ["gmail", "slack"])
        XCTAssertTrue(card.unresolved, "Only Continue ends a directory card")
        XCTAssertNil(card.deadline)

        let settled = try XCTUnwrap(ConnectionActivity.from(payload: object(#"""
        {"op_id": "op4", "seq": 2, "targets": [], "settled": true, "settled_by": "continue"}
        """#), sessionId: "rt-1")?.applied(over: card))
        XCTAssertEqual(settled.suggested, ["gmail", "slack"], "A frame without display keeps the directory card")
        XCTAssertFalse(settled.isOpen)
    }

    func testANewerFrameMovesTheCardAndAnOlderOneDoesNot() throws {
        var shown = try request(seq: 3)
        shown.profile = "work"
        XCTAssertNil(try request(seq: 2).applied(over: shown), "An older frame moves no row")
        XCTAssertNil(try request(seq: 3).applied(over: shown), "The same frame again changes nothing")

        let later = try XCTUnwrap(ConnectionActivity.from(payload: object(#"""
        {"op_id": "op1", "seq": 4, "settled": false, "targets": [{"name": "gmail", "kind": "connector", "state": "initiated"}]}
        """#), sessionId: "rt-1")?.applied(over: shown))
        XCTAssertEqual(later.targets[0].connectURL, shown.targets[0].connectURL, "The page stays until Hermes makes a new one")
        XCTAssertEqual(later.targets[0].connectionID, "c9")
        XCTAssertEqual(later.profile, "work")

        let done = try XCTUnwrap(ConnectionActivity.from(payload: object(#"""
        {"op_id": "op1", "seq": 5, "settled": true, "settled_by": "all_resolved", "targets": [{"name": "gmail", "kind": "connector", "state": "connected"}]}
        """#), sessionId: "rt-1")?.applied(over: later))
        XCTAssertFalse(done.isOpen)
        XCTAssertTrue(done.targets[0].resolved)
    }

    func testAnAnswerHoldsTheButtonsUntilHermesAnswersIt() throws {
        var shown = try request(seq: 3)
        shown.status = .sending
        shown.sentAtSeq = 3
        let refused = try XCTUnwrap(ConnectionActivity.from(payload: object(#"""
        {"op_id": "op1", "seq": 3, "settled": true, "targets": []}
        """#), sessionId: "rt-1")?.applied(over: shown))
        XCTAssertEqual(refused.status, .open, "A settlement ends the wait")
        let moved = try XCTUnwrap(try request(seq: 4, state: "connected").applied(over: shown))
        XCTAssertEqual(moved.status, .open, "A newer frame answers what was sent")
        XCTAssertNil(moved.sentAtSeq)
    }

    func testAnswersCarryOnlyTypedKeys() throws {
        let card = try request()
        let github = card.targets[1]
        XCTAssertFalse(ConnectionActivity.hasRequiredValues(github.fields, in: ["GITHUB_TOKEN": "  ", "GITHUB_HOST": "github.com"]))
        XCTAssertTrue(ConnectionActivity.hasRequiredValues(github.fields, in: ["GITHUB_TOKEN": "ghp_x"]))

        let approved = ConnectionActivity.answer(name: "github_mcp", approve: true, env: ["GITHUB_TOKEN": "ghp_x", "GITHUB_HOST": ""])
        XCTAssertEqual(approved["status"] as? String, "approved")
        XCTAssertEqual(approved["env"] as? [String: String], ["GITHUB_TOKEN": "ghp_x"])
        let skipped = ConnectionActivity.answer(name: "github_mcp", approve: false, env: ["GITHUB_TOKEN": "ghp_x"])
        XCTAssertEqual(skipped["status"] as? String, "skipped")
        XCTAssertNil(skipped["env"], "A skip sends no key")
    }

    func testRowsSayWhatIsLeft() throws {
        let card = try request(state: "expired", url: "")
        XCTAssertTrue(card.targets[0].reissues, "A dead sign-in page gets a new one")
        XCTAssertFalse(card.targets[0].opensPage)
        let minting = try request(state: "pending", url: "")
        XCTAssertFalse(minting.targets[0].opensPage, "Hermes is still making the page")
        XCTAssertFalse(minting.targets[0].reissues)
    }

    func testTheEventParsesIntoTheChatsCard() throws {
        let params = try JSONDecoder().decode(AnyCodable.self, from: Data(#"""
        {"type": "connection.request", "session_id": "rt-1",
         "payload": {"op_id": "op1", "seq": 1, "deadline_at": 0, "timeout_seconds": 1, "targets": [{"name": "gmail", "kind": "connector", "action": "connect", "state": "pending"}]}}
        """#.utf8))
        guard case .connection(let sessionId, let card)? = StreamEventParser.parse(params: params) else {
            return XCTFail("connection.request opens a connect card")
        }
        XCTAssertEqual(sessionId, "rt-1")
        XCTAssertEqual(card.targets.map(\.name), ["gmail"])
    }

    func testAnOpenCardWaitsOnTheUserEverywhere() throws {
        let card = try request()
        let message = ChatMessage(id: "connection-op1", role: .connection, content: "Connect Gmail", timestamp: "1")
        var row = message
        row.connection = card
        XCTAssertTrue(AppState.hasPendingDecision(in: [row]))
        XCTAssertEqual(ChatResumeCoordinator.pendingClarifyMessageID(in: [row]), row.id, "The jump button goes to it")
        XCTAssertEqual(PendingDecisionKind(message: row), .input)
        var settled = row
        settled.connection?.settled = true
        XCTAssertFalse(AppState.hasPendingDecision(in: [settled]))
        XCTAssertNil(ChatResumeCoordinator.pendingClarifyMessageID(in: [settled]))

        let waiting = LiveTurnProgress.applying(.connection(sessionId: "rt-1", activity: card), to: HermesTurnAttributes.ContentState(phase: .tool))
        XCTAssertEqual(waiting?.phase, HermesTurnPhase.input.rawValue)
    }

    func testTheCardIsNeverKept() {
        var row = ChatMessage(id: "connection-op1", role: .connection, content: "Connect Gmail", timestamp: "1")
        row.connection = nil
        XCTAssertNil(OfflineCachedMessage(row), "Live-only: a resume brings an open card back")
    }

    func testAResumeBringsTheOpenCardBack() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "pending_connection": .object(["op_id": .string("op1"), "seq": .number(2), "targets": .array([])])
        ])
        XCTAssertEqual(snapshot.pendingConnectionPayload?["op_id"]?.stringValue, "op1")
    }

    // MARK: In a chat

    private func connectedAppState() async throws -> (AppState, ClarifyFakeSocket) {
        let defaults = makeScratchDefaults("ConnectionCardTests")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.activeSessionId = "stored-a"
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        let client = HermesClient(connection: connection, profile: "default", transportFactory: { transport })
        transport.nextSocket = { socket }
        appState.connection = connection
        appState.client = client
        let connectTask = Task { try await client.connect() }
        transport.open(socket)
        _ = try await connectTask.value
        return (appState, socket)
    }

    private func card(_ seq: Int, state: String, settled: Bool = false) throws -> ConnectionActivity {
        try XCTUnwrap(ConnectionActivity.from(payload: object(#"""
        {"op_id": "op1", "seq": \#(seq), "settled": \#(settled), "targets": [
          {"name": "github_mcp", "kind": "mcp", "action": "install", "state": "\#(state)",
           "required_env": [{"name": "GITHUB_TOKEN", "required": true, "secret": true, "default": ""}]}
        ]}
        """#), sessionId: "stored-a"))
    }

    func testTheCardShowsMovesOnAndSendsTheKeyOnce() async throws {
        let (appState, socket) = try await connectedAppState()
        appState.handleStreamEvent(.connection(sessionId: "stored-a", activity: try card(1, state: "pending")))
        let row = try XCTUnwrap(appState.messages.last)
        XCTAssertEqual(row.role, .connection)
        XCTAssertEqual(row.connection?.profile, appState.activeProfile)

        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        let answer = Task {
            await appState.respondToConnection(
                messageId: row.id,
                targets: [ConnectionActivity.answer(name: "github_mcp", approve: true, env: ["GITHUB_TOKEN": "ghp_x"])]
            )
        }
        try await sent.wait("the connection.respond request to be sent")
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any])
        XCTAssertEqual(frame["method"] as? String, "connection.respond")
        let params = try XCTUnwrap(frame["params"] as? [String: Any])
        XCTAssertEqual(params["op_id"] as? String, "op1")
        XCTAssertEqual((params["owner"] as? [String: Any])?["session_id"] as? String, "stored-a")
        let targets = try XCTUnwrap((params["result"] as? [String: Any])?["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.first?["env"] as? [String: String], ["GITHUB_TOKEN": "ghp_x"])
        XCTAssertEqual(appState.messages.last?.connection?.status, .sending)
        XCTAssertFalse(appState.messages.contains { $0.content.contains("ghp_x") }, "The key never reaches the transcript")

        let id = try XCTUnwrap(frame["id"] as? Int)
        socket.deliver(String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": ["status": "ok", "settled": true]]), as: UTF8.self))
        await answer.value

        appState.handleStreamEvent(.connection(sessionId: "stored-a", activity: try card(2, state: "connected", settled: true)))
        XCTAssertEqual(appState.messages.filter { $0.role == .connection }.count, 1, "Each frame moves the one card")
        XCTAssertEqual(appState.messages.last?.connection?.isOpen, false)
        XCTAssertEqual(appState.messages.last?.connection?.status, .open)
    }

    func testACardFromAnotherProfileNeverSends() async throws {
        let (appState, socket) = try await connectedAppState()
        appState.handleStreamEvent(.connection(sessionId: "stored-a", activity: try card(1, state: "pending")))
        let id = try XCTUnwrap(appState.messages.last?.id)
        appState.messages[appState.messages.count - 1].connection?.profile = appState.activeProfile + "-before-switch"
        let sentBefore = socket.sentTexts.count
        await appState.respondToConnection(messageId: id, continues: true)
        XCTAssertEqual(socket.sentTexts.count, sentBefore)
        XCTAssertEqual(appState.messages.last?.connection?.isOpen, false, "It stops offering anything")
    }

    func testASettledOperationNeverShownOpensNoCard() throws {
        let defaults = makeScratchDefaults("ConnectionCardTests.settled")
        let appState = AppState(defaults: defaults, loadSavedConnection: false, clearSessionPresentationCache: {},
                                sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        appState.activeSessionId = "stored-a"
        appState.handleStreamEvent(.connection(sessionId: "stored-a", activity: try card(5, state: "connected", settled: true)))
        XCTAssertFalse(appState.messages.contains { $0.role == .connection })
    }
}
