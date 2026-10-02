import XCTest
@testable import Conduit

/// Chat takeover (#304). An extension, not a new class: the hosted CI
/// planner budgets batches per class.
extension HermesClientTests {
    func testRefusalDetailsNameTheStoredSessionAndOwner() {
        let message = "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\nDetails: session 20261002_abc opened by desktop 12m ago."
        let details = ChatTakeoverState.details(fromRefusal: message)
        XCTAssertEqual(details.sessionID, "20261002_abc")
        XCTAssertEqual(details.surface, "desktop")
    }

    func testRefusalDetailsWithoutAnAge() {
        let details = ChatTakeoverState.details(fromRefusal: "Details: session s1 opened by cli.")
        XCTAssertEqual(details.sessionID, "s1")
        XCTAssertEqual(details.surface, "cli")
    }

    func testRefusalWithoutDetails() {
        let details = ChatTakeoverState.details(fromRefusal: "This chat is open in another Hermes window/terminal.")
        XCTAssertNil(details.sessionID)
        XCTAssertNil(details.surface)
    }

    func testOwnerNames() {
        XCTAssertEqual(ChatTakeoverState.ownerName("desktop"), "Hermes Desktop")
        XCTAssertEqual(ChatTakeoverState.ownerName("tui"), "a Hermes terminal")
        XCTAssertEqual(ChatTakeoverState.ownerName(nil), "another Hermes window")
    }

    func testRpcErrorDecodesTheRefusalReason() throws {
        let json = #"{"code": 4090, "message": "This chat is open elsewhere", "data": {"reason": "SESSION_NOT_OWNED"}}"#
        let error = try JSONDecoder().decode(RpcError.self, from: Data(json.utf8))
        XCTAssertEqual(error.code, 4090)
        XCTAssertEqual(error.reason, "SESSION_NOT_OWNED")
        XCTAssertTrue(error.isSessionNotOwned)
    }

    func testRpcErrorWithoutDataHasNoReason() throws {
        let json = #"{"code": 4009, "message": "session busy"}"#
        let error = try JSONDecoder().decode(RpcError.self, from: Data(json.utf8))
        XCTAssertNil(error.reason)
        XCTAssertFalse(error.isSessionNotOwned)
    }

    func testRpcErrorIgnoresNonObjectData() throws {
        let json = #"{"code": 4090, "message": "capacity", "data": "MAX_CONCURRENT_SESSIONS"}"#
        let error = try JSONDecoder().decode(RpcError.self, from: Data(json.utf8))
        XCTAssertNil(error.reason)
    }

    func testOutcomes() throws {
        XCTAssertEqual(try ChatTakeoverClient.outcome(from: ["ok": true, "status": "taken_over", "surface": "desktop"]), .ready)
        XCTAssertEqual(try ChatTakeoverClient.outcome(from: ["ok": true, "status": "free"]), .ready)
        XCTAssertEqual(try ChatTakeoverClient.outcome(from: ["ok": true, "status": "busy"]), .busy)
        XCTAssertEqual(try ChatTakeoverClient.outcome(from: ["ok": true, "status": "same_host"]), .sameHost)
        XCTAssertThrowsError(try ChatTakeoverClient.outcome(from: ["ok": true, "status": "later"]))
        XCTAssertThrowsError(try ChatTakeoverClient.outcome(from: ["status": "free"]))
    }

    func testHTTPErrorsMapToPluginState() {
        XCTAssertEqual(ChatTakeoverClient.mapped(.http(status: 404, detail: "")), .pluginMissing)
        XCTAssertEqual(ChatTakeoverClient.mapped(.http(status: 501, detail: "")), .unsupported)
        XCTAssertNil(ChatTakeoverClient.mapped(.http(status: 503, detail: "")))
        XCTAssertNil(ChatTakeoverClient.mapped(.notReady))
    }

    func testClientPostsAtMostFourIdsToTheProfilesRoute() async throws {
        var seen: (path: String, method: String, body: [String: Any]?)?
        let client = ChatTakeoverClient(request: { path, method, body in
            seen = (path, method, body)
            return ["ok": true, "status": "busy"]
        })
        let outcome = try await client.takeOver(sessionIDs: ["a", "b", "c", "d", "e"], profile: "work")
        XCTAssertEqual(outcome, .busy)
        XCTAssertEqual(seen?.path, "/api/plugins/conduit_push/sessions/takeover?profile=work")
        XCTAssertEqual(seen?.method, "POST")
        XCTAssertEqual(seen?.body?["session_ids"] as? [String], ["a", "b", "c", "d"])
    }

    func testClientMapsAMissingPlugin() async {
        let client = ChatTakeoverClient(request: { _, _, _ in
            throw DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
        })
        do {
            _ = try await client.takeOver(sessionIDs: ["a"], profile: "default")
            XCTFail("expected pluginMissing")
        } catch {
            XCTAssertEqual(error as? ChatTakeoverError, .pluginMissing)
        }
    }

    func testOnlyTransientTakeoverFailuresAreRetried() {
        XCTAssertTrue(AppState.isTransientChatTakeoverFailure(DashboardTicketBridgeError.notReady))
        XCTAssertTrue(AppState.isTransientChatTakeoverFailure(DashboardTicketBridgeError.http(status: 503, detail: "")))
        XCTAssertTrue(AppState.isTransientChatTakeoverFailure(DashboardTicketBridgeError.http(status: 0, detail: "")))
        XCTAssertTrue(AppState.isTransientChatTakeoverFailure(URLError(.timedOut)))
        XCTAssertFalse(AppState.isTransientChatTakeoverFailure(DashboardTicketBridgeError.http(status: 501, detail: "")))
        XCTAssertFalse(AppState.isTransientChatTakeoverFailure(DashboardTicketBridgeError.http(status: 400, detail: "")))
        XCTAssertFalse(AppState.isTransientChatTakeoverFailure(ChatTakeoverError.pluginMissing))
    }

    private func takeoverState(_ text: String = "hello") -> ChatTakeoverState {
        ChatTakeoverState(sessionID: "s1", sessionIDs: ["s1"], surface: "desktop", refusedText: text, phase: .waiting)
    }

    func testTakeoverPollsWhileTheOwnerIsReplying() async {
        var replies: [[String: Any]] = [["ok": true, "status": "busy"], ["ok": true, "status": "busy"], ["ok": true, "status": "taken_over"]]
        var calls = 0
        let client = ChatTakeoverClient(request: { _, _, _ in
            calls += 1
            return replies.removeFirst()
        })
        let phase = await AppState.runChatTakeover(client: client, state: takeoverState(), profile: "default", pollInterval: .zero)
        XCTAssertEqual(phase, .ready)
        XCTAssertEqual(calls, 3)
    }

    func testTakeoverGivesUpAfterRepeatedTransientFailures() async {
        var calls = 0
        let client = ChatTakeoverClient(request: { _, _, _ in
            calls += 1
            throw DashboardTicketBridgeError.http(status: 503, detail: "")
        })
        let phase = await AppState.runChatTakeover(client: client, state: takeoverState(), profile: "default", pollInterval: .zero)
        guard case .failed = phase else { return XCTFail("expected failed, got \(String(describing: phase))") }
        XCTAssertEqual(calls, AppState.chatTakeoverTransientRetryLimit)
    }

    func testTakeoverWithoutThePluginIsUnavailableNotRetryable() async {
        let client = ChatTakeoverClient(request: { _, _, _ in
            throw DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
        })
        let phase = await AppState.runChatTakeover(client: client, state: takeoverState(), profile: "default", pollInterval: .zero)
        guard case .unavailable = phase else { return XCTFail("expected unavailable, got \(String(describing: phase))") }
    }

    func testTakeoverHeldByAnotherConduitIsHeldHere() async {
        let client = ChatTakeoverClient(request: { _, _, _ in ["ok": true, "status": "same_host"] })
        let phase = await AppState.runChatTakeover(client: client, state: takeoverState(), profile: "default", pollInterval: .zero)
        XCTAssertEqual(phase, .heldHere)
    }

    func testOnlyTheRefusedMessageIsResent() {
        let state = takeoverState("  hello\n")
        XCTAssertTrue(state.isRefusedMessage("hello"))
        XCTAssertFalse(state.isRefusedMessage("something else"))
        XCTAssertFalse(takeoverState("").isRefusedMessage(""))
    }
}
