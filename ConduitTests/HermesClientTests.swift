import XCTest
@testable import Conduit

@MainActor
final class HermesClientTests: XCTestCase {

    // MARK: - rpc() guard

    func testRPCGuardRejectsBeforeHandshake() async throws {
        // The handshake is held open (we never call transport.open), so the
        // socket is installed but `isConnected` is still false. `rpc()`'s
        // `isConnected` requirement must reject the call — the pre-fix
        // `closeCode == .invalid` check alone would have passed.
        let transport = FakeTransport()
        let socket = FakeSocket()
        let reachedResume = Gate()
        socket.onResume = { reachedResume.signal() }
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)

        let connectTask = Task { try? await client.connect() }
        try await reachedResume.wait("connect() to resume the socket (handshake pending)")  // connect() has installed + resumed the socket and is now suspended in the handshake

        do {
            try await client.healthCheck()
            XCTFail("Expected healthCheck to throw before the handshake completes")
        } catch HermesError.notConnected {
            // expected
        } catch {
            XCTFail("Expected .notConnected, got \(error)")
        }

        client.disconnect()  // resumes the suspended handshake so connect() unwinds
        try await awaitCompletion(of: connectTask, "connect() to unwind after disconnect()")
    }

    // MARK: - receive-failure teardown

    func testReceiveFailureOnOwningSocketTearsDown() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        let receivePending = Gate()
        socket.onReceivePending = { receivePending.signal() }
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        var didDisconnect = false
        client.onDisconnected = { didDisconnect = true }

        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")
        XCTAssertTrue(client.isConnected)
        try await receivePending.wait("the receive loop to suspend in socket.receive()")  // the receive loop is now suspended in socket.receive()

        socket.failReceive(URLError(.networkConnectionLost))
        await flushMainActor()       // let the catch run

        XCTAssertFalse(client.isConnected)
        XCTAssertTrue(didDisconnect)
        client.disconnect()
    }

    func testSupersededReceiveLoopDoesNotClobberNewConnection() async throws {
        let transport = FakeTransport()
        let socketA = FakeSocket()
        let aReceivePending = Gate()
        socketA.onReceivePending = { aReceivePending.signal() }
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)
        var disconnectCount = 0
        client.onDisconnected = { disconnectCount += 1 }

        let connectA = Task { try? await client.connect() }
        transport.open(socketA)
        try await awaitCompletion(of: connectA, "connect A to complete after the handshake")
        XCTAssertTrue(client.isConnected)
        try await aReceivePending.wait("socket A's receive loop to suspend in socket.receive()")  // A's receive loop is suspended in socket.receive()

        // Same-instance reconnect (the latent scenario this PR hardens):
        // connect() tears down socketA → A's receive() errors → A's late catch
        // must be a no-op, not clobber the new connection.
        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        try await awaitCompletion(of: connectB, "connect B to complete after the handshake")
        await flushMainActor()  // let A's superseded catch run

        XCTAssertTrue(socketA.cancelled, "Reconnect should cancel the superseded socket")
        XCTAssertTrue(client.isConnected, "A superseded loop must not mark the new connection disconnected")
        XCTAssertEqual(disconnectCount, 0, "A superseded loop must not fire onDisconnected")
        client.disconnect()
    }

    func testSupersededLoopDropsStaleFrame() async throws {
        // The success path of receiveLoop is identity-guarded too: a frame
        // delivered to a superseded socket must not reach handleMessage.
        let transport = FakeTransport()
        let socketA = FakeSocket()
        socketA.cancelErrorsReceive = false  // keep A's receive suspended so a stale frame can arrive after supersession
        let aReceivePending = Gate()
        socketA.onReceivePending = { aReceivePending.signal() }
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)
        var eventCount = 0
        client.onEvent = { _ in eventCount += 1 }

        let connectA = Task { try? await client.connect() }
        transport.open(socketA)
        try await awaitCompletion(of: connectA, "connect A to complete after the handshake")
        try await aReceivePending.wait("socket A's receive loop to suspend in socket.receive()")

        // Reconnect to B, then deliver a frame to the old socket A. The guard
        // must drop it (onEvent not fired for A's stale frame).
        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        try await awaitCompletion(of: connectB, "connect B to complete after the handshake")

        socketA.deliver(someEventJSON())
        await flushMainActor()

        XCTAssertEqual(eventCount, 0, "A stale frame on a superseded socket must be dropped")
        client.disconnect()
    }

    // MARK: - connect() teardown of the prior connection

    func testConnectInvalidatesPriorTransport() async throws {
        let transport = FakeTransport()
        let socketA = FakeSocket()
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)

        let connectA = Task { try? await client.connect() }
        transport.open(socketA)
        try await awaitCompletion(of: connectA, "connect A to complete after the handshake")
        XCTAssertFalse(transport.invalidated)

        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        try await awaitCompletion(of: connectB, "connect B to complete after the handshake")

        XCTAssertTrue(transport.invalidated, "Reconnect must invalidate the prior transport/session")
        XCTAssertEqual(transport.socketsMade.count, 2)
        client.disconnect()
    }

    /// The Cloudflare service token rides only secure upgrades: an HTTPS
    /// dashboard yields wss:// with both headers; a plain-HTTP LAN dashboard
    /// yields ws:// with the credentials silently omitted.
    func testCloudflareServiceTokenRidesOnlySecureWebSocketUpgrades() async throws {
        let credentials = CloudflareAccessCredentials(clientID: "ws-id", clientSecret: "ws-secret")

        let secureTransport = FakeTransport()
        let secureSocket = FakeSocket()
        secureTransport.nextSocket = { secureSocket }
        let secureClient = HermesClient(
            connection: HermesConnection(baseUrl: "https://hermes.example", ticket: "ticket"),
            cloudflareAccess: credentials,
            transportFactory: { secureTransport }
        )
        let secureConnect = Task { try? await secureClient.connect() }
        secureTransport.open(secureSocket)
        try await awaitCompletion(of: secureConnect, "the secure connect to complete")
        let secureRequest = try XCTUnwrap(secureTransport.requestsMade.first)
        XCTAssertEqual(secureRequest.url?.scheme, "wss")
        XCTAssertEqual(secureRequest.value(forHTTPHeaderField: "CF-Access-Client-Id"), "ws-id")
        XCTAssertEqual(secureRequest.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "ws-secret")
        secureClient.disconnect()

        let plainTransport = FakeTransport()
        let plainSocket = FakeSocket()
        plainTransport.nextSocket = { plainSocket }
        let plainClient = HermesClient(
            connection: HermesConnection(baseUrl: "http://192.168.1.50:9119", ticket: "ticket"),
            cloudflareAccess: credentials,
            transportFactory: { plainTransport }
        )
        let plainConnect = Task { try? await plainClient.connect() }
        plainTransport.open(plainSocket)
        try await awaitCompletion(of: plainConnect, "the plain-HTTP connect to complete")
        let plainRequest = try XCTUnwrap(plainTransport.requestsMade.first)
        XCTAssertEqual(plainRequest.url?.scheme, "ws", "Local ws:// connectivity must remain supported")
        XCTAssertNil(plainRequest.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(plainRequest.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
        plainClient.disconnect()
    }

    func testConcurrentConnectSupersedesPriorWithoutHanging() async throws {
        // A second connect() while the first is still mid-handshake must resume
        // the first's open continuation (via the teardown, mirroring disconnect),
        // so the first connect() throws instead of hanging forever.
        let transport = FakeTransport()
        let socketA = FakeSocket()
        let aResumed = Gate()
        socketA.onResume = { aResumed.signal() }
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)

        let connectA = Task { try? await client.connect() }
        try await aResumed.wait("connect A to resume its socket (handshake pending)")  // connectA has installed A and is suspended in the handshake (A is never opened)

        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        try await awaitCompletion(of: connectB, "connect B to complete after the handshake")

        // If the continuation were leaked this would time out (boundedly) and
        // fail the test instead of hanging the run.
        try await awaitCompletion(of: connectA, "superseded connect A to unwind after connect B")
        XCTAssertTrue(client.isConnected)
        client.disconnect()
    }

    // MARK: - session.resume transport bound (issue #106)

    func testProductionTransportRaisesWebSocketMessageLimit() {
        // URLSessionWebSocketTask's platform default receive limit closes the
        // socket with close code 1009 as soon as a single message exceeds it,
        // which is how resuming large sessions used to disconnect Conduit in
        // a loop. The production transport must install the explicit bounded
        // 4 MiB limit on the real socket.
        let transport = URLSessionWebSocketTransport()
        defer { transport.invalidate() }
        let request = URLRequest(url: URL(string: "wss://gateway.example/api/ws")!)
        let socket = transport.makeSocket(
            request: request,
            onOpen: { _ in },
            onCloseBeforeOpen: { _ in }
        )

        let task = socket as? URLSessionWebSocketTask
        XCTAssertNotNil(task, "The production transport must produce a URLSessionWebSocketTask")
        XCTAssertEqual(task?.maximumMessageSize, URLSessionWebSocketTransport.maximumMessageSize)
        XCTAssertEqual(URLSessionWebSocketTransport.maximumMessageSize, 4 * 1024 * 1024)
        XCTAssertNotEqual(
            URLSessionWebSocketTransport.maximumMessageSize,
            1_048_576,
            "The limit must not remain at the platform default"
        )
    }

    func testLegacyResumeUsesDedicatedTimeoutBudget() {
        // The legacy full-transcript resume carries the largest ordinary
        // payload in the app, so it gets the bounded-but-generous 60 s
        // budget; the compact resume rides the ordinary 30 s request
        // timeout (issue #106 follow-up).
        XCTAssertEqual(HermesClient.resumeTimeout(omitMessages: true), HermesClient.requestTimeout)
        XCTAssertEqual(HermesClient.requestTimeout, 30)
        XCTAssertEqual(HermesClient.resumeTimeout(omitMessages: false), HermesClient.legacyResumeTimeout)
        XCTAssertEqual(HermesClient.legacyResumeTimeout, 60)
        XCTAssertGreaterThan(HermesClient.legacyResumeTimeout, HermesClient.requestTimeout)
    }

    func testOpenSessionRequestsCompactResumeWithoutTranscriptPayload() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSession("sess-large") }
        try await sent.wait("the session.resume request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.resume")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "sess-large")
        XCTAssertEqual(
            params["omit_messages"] as? Bool,
            true,
            "The compact resume must ask the gateway to omit the persisted transcript"
        )
        XCTAssertEqual(params["cols"] as? Int, 96)
        XCTAssertEqual(params["source"] as? String, "desktop")

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "session_id": "sess-large",
                "messages": [Any](),
                "info": ["running": false]
            ]
        ]
        socket.deliver(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!)

        let result = try await awaitResult(of: openTask, "the compact session.resume response")
        XCTAssertTrue(result.messages.isEmpty, "The compact response must carry no transcript")
        XCTAssertEqual(result.sessionId, "sess-large")
        client.disconnect()
    }

    func testFindBotChatSessionSendsExactTitleLookupOnBotProfile() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let lookupTask = Task<[BotChatLookupRow], Error> { try await client.findBotChatSession(profile: "atlas") }
        try await sent.wait("the canonical-chat lookup to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.list")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["profile"] as? String, "atlas", "the lookup rides the BOT's profile")
        XCTAssertEqual(params["title"] as? String, "Bot Chat")
        XCTAssertEqual(params["include_hidden"] as? Bool, true, "canonical chats are born hidden")
        XCTAssertEqual(params["limit"] as? Int, 200)

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "sessions": [[
                    "id": "stored-1",
                    "resolved_id": "runtime-1",
                    "title": "Bot Chat",
                    "root_title": "Bot Chat"
                ]]
            ]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let rows = try await awaitResult(of: lookupTask, "the canonical-chat lookup response")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "stored-1")
        XCTAssertEqual(row.resolvedID, "runtime-1")
        XCTAssertTrue(row.isCanonicalTitle())
        client.disconnect()
    }

    func testCreateBotChatSessionSendsHiddenCanonicalCreateParams() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let createTask = Task<(sessionId: String, storedSessionId: String?), Error> {
            try await client.createBotChatSession(profile: "atlas")
        }
        try await sent.wait("the canonical chat create to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.create")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["profile"] as? String, "atlas")
        XCTAssertEqual(params["title"] as? String, "Bot Chat")
        XCTAssertEqual(params["hidden"] as? Bool, true, "the canonical chat is born hidden")
        XCTAssertEqual(
            params["follow_profile_config"] as? Bool,
            true,
            "the runtime must always follow the profile's CURRENT config"
        )
        XCTAssertEqual(params["cols"] as? Int, 96)
        XCTAssertEqual(params["source"] as? String, "desktop")

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "session_id": "runtime-new",
                "stored_session_id": "stored-new"
            ]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let created = try await awaitResult(of: createTask, "the canonical chat create response")
        XCTAssertEqual(created.sessionId, "runtime-new")
        XCTAssertEqual(created.storedSessionId, "stored-new")
        client.disconnect()
    }

    func testSetSessionTitleCarriesExplicitProfileWhenGiven() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let titleTask = Task<Void, Error> {
            try await client.setSessionTitle("runtime-new", title: "Bot Chat", profile: "atlas")
        }
        try await sent.wait("the canonical title write to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.title")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "runtime-new")
        XCTAssertEqual(params["title"] as? String, "Bot Chat")
        XCTAssertEqual(
            params["profile"] as? String, "atlas",
            "the bot title write is self-describing about the profile it addresses"
        )

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["title": "Bot Chat"]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        _ = try await titleTask.value
        client.disconnect()
    }

    func testProfileScopedResumeCarriesExplicitProfile() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> {
            try await client.openSession("runtime-1", profile: "atlas")
        }
        try await sent.wait("the profile-scoped session.resume to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.resume")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "runtime-1")
        XCTAssertEqual(
            params["profile"] as? String, "atlas",
            "a bot chat's resume must open the bot profile's state.db"
        )

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["session_id": "runtime-1", "messages": [Any]()]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        _ = try await awaitResult(of: openTask, "the profile-scoped resume response")
        client.disconnect()
    }

    func testExplicitProfileInParamsWinsOverClientScope() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport, profile: "analyst")
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let lookupTask = Task<[BotChatLookupRow], Error> { try await client.findBotChatSession(profile: "atlas") }
        try await sent.wait("the lookup to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(
            params["profile"] as? String, "atlas",
            "a caller-supplied profile is explicit intent and must beat the client's default scope"
        )

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["sessions": [Any]()]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let rows = try await awaitResult(of: lookupTask, "the lookup response")
        XCTAssertTrue(rows.isEmpty)
        client.disconnect()
    }

    func testBotRosterDecodesProfilesListEnvelope() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let rosterTask = Task<BotRosterSnapshot, Error> { try await client.botRoster() }
        try await sent.wait("the profiles.list probe to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "profiles.list")

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "bot_mode_protocol": true,
                "profiles": [[
                    "name": "atlas",
                    "display_name": "Atlas",
                    "canonical_session": [
                        "id": "stored-1",
                        "resolved_id": "runtime-1"
                    ]
                ]]
            ]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let snapshot = try await awaitResult(of: rosterTask, "the profiles.list response")
        XCTAssertTrue(snapshot.supportsBotProtocol)
        XCTAssertEqual(snapshot.bots.map(\.name), ["atlas"])
        let bot = try XCTUnwrap(snapshot.bots.first)
        XCTAssertEqual(bot.canonicalSessionID, "stored-1")
        client.disconnect()
    }

    func testSessionTitleReadIsSelfDescribingAboutProfile() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let titleTask = Task<String?, Error> {
            try await client.sessionTitle("runtime-1", profile: "atlas")
        }
        try await sent.wait("the session.title read to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.title")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "runtime-1")
        XCTAssertEqual(
            params["profile"] as? String, "atlas",
            "the bot title read is self-describing about the profile it addresses"
        )

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["title": "Bot Chat"]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let title = try await awaitResult(of: titleTask, "the session.title response")
        XCTAssertEqual(title, "Bot Chat")
        client.disconnect()
    }

    func testSessionTitleReadOmitsProfileForOrdinarySessions() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let titleTask = Task<String?, Error> {
            try await client.sessionTitle("ordinary-1")
        }
        try await sent.wait("the session.title read to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "ordinary-1")
        XCTAssertNil(
            params["profile"],
            "ordinary sessions keep the session-scoped default and carry no profile field"
        )

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["title": "Fresh"]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let title = try await awaitResult(of: titleTask, "the session.title response")
        XCTAssertEqual(title, "Fresh")
        client.disconnect()
    }

    func testOpenSessionLegacyCarriesTranscriptInResponse() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSessionLegacy("sess-full") }
        try await sent.wait("the legacy session.resume request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "sess-full")
        XCTAssertNil(params["omit_messages"], "The legacy resume must not suppress the transcript")

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "session_id": "sess-full",
                "messages": [
                    ["role": "user", "content": "Hello", "timestamp": "2026-09-01T10:00:00Z"],
                    ["role": "assistant", "content": "Hi there", "timestamp": "2026-09-01T10:00:05Z"]
                ],
                "info": ["running": false]
            ]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let result = try await awaitResult(of: openTask, "the legacy session.resume response")
        XCTAssertEqual(result.messages.map({ $0.role }), [.user, .assistant])
        XCTAssertEqual(result.messages.first?.content, "Hello")
        XCTAssertEqual(result.messages.first?.timestamp, "2026-09-01T10:00:00Z")
        client.disconnect()
    }

    func testLegacyResumeAppliesDisplayProjectionToPersistedRows() async throws {
        // REST hydration and the legacy `session.resume` transcript must
        // enforce the same Hermes display contract: synthetic rows tagged
        // with `display_kind` never become human user bubbles, and hidden
        // scaffolding disappears entirely.
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSessionLegacy("sess-display") }
        try await sent.wait("the legacy session.resume request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "session_id": "sess-display",
                "messages": [
                    ["role": "user", "content": "Ship the release.", "timestamp": "2026-09-01T10:00:00Z"],
                    [
                        "role": "user",
                        "content": "INTERNAL MODEL SCAFFOLD — do not render",
                        "display_kind": "hidden",
                        "timestamp": "2026-09-01T10:00:01Z"
                    ],
                    [
                        "role": "user",
                        "content": "[System note: Your previous turn was interrupted mid-run. Continuing.]",
                        "display_kind": "auto_continue",
                        "timestamp": "2026-09-01T10:00:02Z"
                    ],
                    [
                        "role": "user",
                        "content": "Background delegation report scaffold",
                        "display_kind": "async_delegation_complete",
                        "display_metadata": ["task_count": 2],
                        "timestamp": "2026-09-01T10:00:03Z"
                    ]
                ],
                "info": ["running": false]
            ]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let result = try await awaitResult(of: openTask, "the legacy session.resume response")
        XCTAssertEqual(result.messages.map({ $0.role }), [.user, .system, .system])
        XCTAssertEqual(
            result.messages.map { $0.content },
            ["Ship the release.", "Resumed interrupted turn", "2 background agents finished"]
        )
        client.disconnect()
    }

    // MARK: - prompt.submit outcome + session.active_list probe

    func testSendPromptReturnsTypedOutcomeFromGatewayStatus() async throws {
        // Upstream `prompt.submit` never rejects a busy session: it applies
        // the configured busy policy and reports steered/redirected/queued.
        // The client must surface that status instead of discarding it.
        for (gatewayStatus, expected) in [
            ("streaming", PromptSubmissionOutcome.accepted),
            ("steered", PromptSubmissionOutcome.steered),
            ("redirected", PromptSubmissionOutcome.redirected),
            ("queued", PromptSubmissionOutcome.queued)
        ] {
            let transport = FakeTransport()
            let socket = FakeSocket()
            transport.nextSocket = { socket }
            let client = makeClient(transport: transport)
            let connectTask = Task { try? await client.connect() }
            transport.open(socket)
            try await awaitCompletion(of: connectTask, "connect() to complete")

            let sent = Gate()
            socket.onSend = { sent.signal() }
            let submitTask = Task<PromptSubmissionOutcome, Error> {
                try await client.sendPrompt("sess-1", text: "Hello")
            }
            try await sent.wait("the prompt.submit request to be sent")

            let request = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
            )
            XCTAssertEqual(request["method"] as? String, "prompt.submit")
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["session_id"] as? String, "sess-1")

            let id = try XCTUnwrap(request["id"] as? Int)
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["status": gatewayStatus]
            ]
            socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

            let outcome = try await awaitResult(of: submitTask, "the prompt.submit response")
            XCTAssertEqual(outcome, expected)
            client.disconnect()
        }
    }

    func testActiveSessionsParsesRuntimeRegistryWithoutMutatingParams() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let probeTask = Task<[LiveSessionStatus], Error> { try await client.activeSessions() }
        try await sent.wait("the session.active_list request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.active_list")
        // The registry read is a read-only, argument-free query. Under the
        // default profile `scopeParams` collapses the empty `[:]` to nil, so
        // the wire request carries NO `params` key at all — no session id and
        // no focus/switch/resume parameters by construction.
        XCTAssertNil(
            request["params"],
            "session.active_list must be sent without session-selection or mutation parameters"
        )

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "sessions": [
                    [
                        "id": "runtime-1",
                        "session_key": "stored-1",
                        "status": "working",
                        "last_active": 100.0
                    ],
                    [
                        "id": "runtime-2",
                        "session_key": "stored-2",
                        "status": "idle"
                    ],
                    // Missing the runtime id entirely: unmatchable, dropped.
                    ["session_key": "stored-broken", "status": "idle"]
                ]
            ]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let rows = try await awaitResult(of: probeTask, "the session.active_list response")
        XCTAssertEqual(rows.count, 2, "Rows without a runtime id are dropped")
        XCTAssertEqual(rows.first?.runtimeSessionId, "runtime-1")
        XCTAssertEqual(rows.first?.storedSessionId, "stored-1")
        XCTAssertEqual(rows.first?.status, "working")
        XCTAssertTrue(rows.first?.isRunning == true)
        XCTAssertEqual(rows.last?.status, "idle")
        XCTAssertFalse(rows.last?.isRunning ?? true)
        client.disconnect()
    }

    func testActiveSessionsCarriesOnlyProfileContextForNonDefaultProfile() async throws {
        // A non-default profile adds the same gateway-context `profile` key
        // every other catalog read carries — still no session id and no
        // focus/switch/resume parameters.
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport, profile: "work")
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let probeTask = Task<[LiveSessionStatus], Error> { try await client.activeSessions() }
        try await sent.wait("the session.active_list request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.active_list")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(
            params["profile"] as? String, "work",
            "The profile key is gateway context, matching every other catalog read"
        )
        XCTAssertEqual(
            params.count, 1,
            "session.active_list must carry no session id and no focus/switch/resume parameters"
        )

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["sessions": []]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let rows = try await awaitResult(of: probeTask, "the session.active_list response")
        XCTAssertTrue(rows.isEmpty)
        client.disconnect()
    }

    // MARK: - clarify.respond

    /// Connects a client, sends the clarify.respond RPC produced by `send`,
    /// captures the outbound frame, and completes it with `result`.
    private func capturedClarifyRespond(
        result: [String: Any],
        questionId: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (request: [String: Any], outcome: HermesClient.ClarifyResponseOutcome) {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete", file: file, line: line)

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let respondTask = Task<HermesClient.ClarifyResponseOutcome, Error> {
            try await client.respondToClarification(
                requestId: "req-1",
                answer: "staging",
                questionId: questionId
            )
        }
        try await sent.wait("the clarify.respond request to be sent", file: file, line: line)

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last, file: file, line: line).utf8)) as? [String: Any],
            file: file,
            line: line
        )
        let id = try XCTUnwrap(request["id"] as? Int, file: file, line: line)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let outcome = try await awaitResult(of: respondTask, "the clarify.respond response", file: file, line: line)
        client.disconnect()
        return (request, outcome)
    }

    func testClarifyRespondForBatchQuestionSendsQuestionIDAndReportsRemaining() async throws {
        let (request, outcome) = try await capturedClarifyRespond(
            result: ["status": "ok", "remaining": ["qid-2", "qid-3"]],
            questionId: "environment"
        )
        XCTAssertEqual(request["method"] as? String, "clarify.respond")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["request_id"] as? String, "req-1")
        XCTAssertEqual(params["answer"] as? String, "staging")
        XCTAssertEqual(
            params["question_id"] as? String, "environment",
            "A batch sub-question must address its gateway qid"
        )
        XCTAssertEqual(outcome, .accepted(remaining: ["qid-2", "qid-3"]))
        XCTAssertFalse(outcome.requestCompleted, "A non-empty remaining list means the request is still open")
    }

    func testClarifyRespondLastQuestionReportsCompletion() async throws {
        let (_, outcome) = try await capturedClarifyRespond(
            result: ["status": "ok", "remaining": []],
            questionId: "notes"
        )
        XCTAssertEqual(outcome, .accepted(remaining: []))
        XCTAssertTrue(outcome.requestCompleted, "An empty remaining list completes the request")
    }

    func testClarifyRespondWithoutQuestionIDOmitsParameterForRequestLevelAnswer() async throws {
        let (request, outcome) = try await capturedClarifyRespond(
            result: ["status": "ok"],
            questionId: nil
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertNil(
            params["question_id"],
            "The legacy request-level response must not carry a question id"
        )
        XCTAssertEqual(
            outcome, .accepted(remaining: nil),
            "An omitted remaining field must stay nil — it is not an explicit empty list"
        )
        XCTAssertFalse(outcome.requestCompleted, "Omitted remaining carries no completion signal")
    }

    func testClarifyRespondExplicitEmptyRemainingIsDistinctFromOmitted() async throws {
        // `remaining: []` is the gateway's explicit completion confirmation;
        // an omitted field is silence. The outcome must model the difference.
        let (_, explicit) = try await capturedClarifyRespond(
            result: ["status": "ok", "remaining": []],
            questionId: "q0"
        )
        XCTAssertEqual(explicit, .accepted(remaining: []))
        XCTAssertTrue(explicit.requestCompleted)

        let (_, omitted) = try await capturedClarifyRespond(
            result: ["status": "ok"],
            questionId: "q0"
        )
        XCTAssertEqual(omitted, .accepted(remaining: nil))
        XCTAssertFalse(omitted.requestCompleted)
        XCTAssertNotEqual(explicit, omitted)
    }

    func testClarifyRespondExpiredStatusDoesNotReadAsSuccess() async throws {
        // The clarify bridge sets allow_expired, so a timed-out request
        // resolves as a SUCCESSFUL RPC whose status is "expired" — never
        // shown as an accepted answer.
        let (_, outcome) = try await capturedClarifyRespond(
            result: ["status": "expired"],
            questionId: "environment"
        )
        XCTAssertEqual(outcome, .expired)
        XCTAssertTrue(outcome.isExpired)
        XCTAssertFalse(outcome.requestCompleted)
    }

    // MARK: - approval.respond / pending_approval

    private func capturedApprovalRespond(
        requestId: String?,
        resultPayload: [String: Any],
        profile: String? = nil
    ) async throws -> (request: [String: Any], accepted: Bool) {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let respondTask = Task<Bool, Error> {
            try await client.respondToApproval(
                sessionId: "runtime-1",
                requestId: requestId,
                choice: "once",
                profile: profile
            )
        }
        try await sent.wait("the approval.respond request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(request["id"] as? Int)
        let payload = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": resultPayload
        ]), encoding: .utf8))
        socket.deliver(payload)
        let accepted = try await awaitResult(of: respondTask, "the approval.respond response")
        client.disconnect()
        return (request, accepted)
    }

    private func capturedApprovalRespond(
        requestId: String?,
        resolved: Int?,
        profile: String? = nil
    ) async throws -> (request: [String: Any], accepted: Bool) {
        var payload: [String: Any] = [:]
        if let resolved { payload["resolved"] = resolved }
        return try await capturedApprovalRespond(requestId: requestId, resultPayload: payload, profile: profile)
    }

    func testExactIntValueRejectsNonIntegersAndTrappingDoubles() {
        XCTAssertEqual(HermesClient.exactIntValue(.number(0)), 0)
        XCTAssertEqual(HermesClient.exactIntValue(.number(42)), 42)
        XCTAssertEqual(HermesClient.exactIntValue(.number(-10)), -10)
        XCTAssertNil(HermesClient.exactIntValue(.number(1.5)))
        XCTAssertNil(HermesClient.exactIntValue(.number(1e300)))
        XCTAssertNil(HermesClient.exactIntValue(.number(-1e300)))
        XCTAssertNil(HermesClient.exactIntValue(.number(Double.infinity)))
        XCTAssertNil(HermesClient.exactIntValue(.number(-Double.infinity)))
        XCTAssertNil(HermesClient.exactIntValue(.number(Double.nan)))
        XCTAssertNil(HermesClient.exactIntValue(.string("42")))
        XCTAssertNil(HermesClient.exactIntValue(nil))
    }

    func testApprovalRespondSendsRequestIdentityAndRejectsZeroResolved() async throws {
        let (request, accepted) = try await capturedApprovalRespond(requestId: "approval-2", resolved: 0)
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["request_id"] as? String, "approval-2")
        XCTAssertEqual(params["session_id"] as? String, "runtime-1")
        XCTAssertFalse(accepted, "A successful RPC that resolved no queue entry is a stale card")
    }

    func testApprovalRespondSendsExplicitProfile() async throws {
        let (request, accepted) = try await capturedApprovalRespond(
            requestId: "approval-profile",
            resolved: 1,
            profile: "bot-agent"
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["profile"] as? String, "bot-agent")
        XCTAssertEqual(params["request_id"] as? String, "approval-profile")
        XCTAssertEqual(params["session_id"] as? String, "runtime-1")
        XCTAssertEqual(params["choice"] as? String, "once")
        XCTAssertTrue(accepted)
    }

    func testLegacyApprovalRespondOmitsRequestIdentity() async throws {
        let (request, accepted) = try await capturedApprovalRespond(requestId: nil, resolved: 1)
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertNil(params["request_id"])
        XCTAssertTrue(accepted)
    }

    func testLegacyApprovalRespondOmittedResolvedDefaultsToTrue() async throws {
        let (_, accepted) = try await capturedApprovalRespond(requestId: nil, resolved: nil)
        XCTAssertTrue(accepted, "Omitted resolved field in legacy response defaults to true")
    }

    func testIdentifiedApprovalRespondRequiresResolvedField() async throws {
        do {
            _ = try await capturedApprovalRespond(requestId: "approval-identified", resolved: nil)
            XCTFail("Expected invalidResponse when identified approval response omits resolved field")
        } catch let error as HermesError {
            guard case .invalidResponse = error else {
                XCTFail("Expected .invalidResponse error, got \(error)")
                return
            }
        }
    }

    func testIdentifiedApprovalRespondAcceptsPositiveResolved() async throws {
        let (request, accepted) = try await capturedApprovalRespond(requestId: "approval-3", resolved: 1)
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["request_id"] as? String, "approval-3")
        XCTAssertTrue(accepted)
    }

    func testApprovalRespondRejectsMalformedAndOutOfRangeResolved() async throws {
        for rawResolved in ["1e300", "-1e300", "1.5", "\"true\"", "9223372036854775808", "-1", "-100"] {
            let transport = FakeTransport()
            let socket = FakeSocket()
            transport.nextSocket = { socket }
            let client = makeClient(transport: transport)
            let connectTask = Task { try? await client.connect() }
            transport.open(socket)
            try await awaitCompletion(of: connectTask, "connect() to complete")

            let sent = Gate()
            socket.onSend = { sent.signal() }
            let respondTask = Task<Bool, Error> {
                try await client.respondToApproval(
                    sessionId: "runtime-1",
                    requestId: "approval-malformed",
                    choice: "once"
                )
            }
            try await sent.wait("the approval.respond request to be sent")
            let request = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
            )
            let id = try XCTUnwrap(request["id"] as? Int)
            socket.deliver("""
            {"jsonrpc": "2.0", "id": \(id), "result": {"resolved": \(rawResolved)}}
            """)
            do {
                _ = try await awaitResult(of: respondTask, "the approval.respond response")
                XCTFail("Expected invalidResponse error for resolved=\(rawResolved)")
            } catch let error as HermesError {
                guard case .invalidResponse = error else {
                    XCTFail("Expected .invalidResponse error for resolved=\(rawResolved), but got \(error)")
                    continue
                }
            }
            client.disconnect()
        }
    }

    func testApprovalRespondRejectsNonObjectRoots() async throws {
        for rawResult in ["\"ok\"", "42", "true", "null", "[]", "[{\"resolved\": 1}]"] {
            let transport = FakeTransport()
            let socket = FakeSocket()
            transport.nextSocket = { socket }
            let client = makeClient(transport: transport)
            let connectTask = Task { try? await client.connect() }
            transport.open(socket)
            try await awaitCompletion(of: connectTask, "connect() to complete")

            let sent = Gate()
            socket.onSend = { sent.signal() }
            let respondTask = Task<Bool, Error> {
                try await client.respondToApproval(
                    sessionId: "runtime-1",
                    requestId: "approval-non-object",
                    choice: "once"
                )
            }
            try await sent.wait("the approval.respond request to be sent")
            let request = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
            )
            let id = try XCTUnwrap(request["id"] as? Int)
            socket.deliver("""
            {"jsonrpc": "2.0", "id": \(id), "result": \(rawResult)}
            """)
            do {
                _ = try await awaitResult(of: respondTask, "the approval.respond response")
                XCTFail("Expected invalidResponse error for non-object result=\(rawResult)")
            } catch let error as HermesError {
                guard case .invalidResponse = error else {
                    XCTFail("Expected .invalidResponse error for non-object result=\(rawResult), but got \(error)")
                    continue
                }
            }
            client.disconnect()
        }
    }

    func testResumeSnapshotParsesPendingApprovalRequestIdentity() throws {
        let snapshot = SessionRuntimeSnapshot(object: [
            "pending_approval": .object([
                "request_id": .string("approval-resume"),
                "description": .string("Run deployment?"),
                "choices": .array([.string("once"), .string("deny")])
            ])
        ])
        XCTAssertEqual(snapshot.pendingApprovalPayload?["request_id"]?.stringValue, "approval-resume")
        let activity = snapshot.pendingApprovalPayload.flatMap {
            MessageNormalizer.approvalActivity(from: $0, sessionId: "runtime-2")
        }
        XCTAssertEqual(activity?.requestId, "approval-resume")
        XCTAssertEqual(activity?.sessionId, "runtime-2")
    }

    func testPendingApprovalsUsesSessionScopeAndParsesFullQueue() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let pendingTask = Task { try await client.pendingApprovals(sessionId: "runtime-queue") }
        try await sent.wait("the approval.pending request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "approval.pending")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "runtime-queue")
        let id = try XCTUnwrap(request["id"] as? Int)
        let payload = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": ["approvals": [
                ["request_id": "approval-a", "description": "Run A?"],
                ["request_id": "approval-b", "description": "Run B?", "choices": ["once", "deny"]]
            ]]
        ]), encoding: .utf8))
        socket.deliver(payload)

        let approvals = try await awaitResult(of: pendingTask, "the approval.pending response")
        XCTAssertEqual(approvals.map(\.requestId), ["approval-a", "approval-b"])
        XCTAssertEqual(approvals.map(\.sessionId), ["runtime-queue", "runtime-queue"])
        XCTAssertEqual(HermesClient.pendingApprovalsTimeout, 3)
        client.disconnect()
    }

    func testPendingApprovalsSendsExplicitProfileInParameters() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let pendingTask = Task { try await client.pendingApprovals(sessionId: "bot-chat-1", profile: "custom-bot") }
        try await sent.wait("the approval.pending request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "approval.pending")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "bot-chat-1")
        XCTAssertEqual(params["profile"] as? String, "custom-bot")
        let id = try XCTUnwrap(request["id"] as? Int)
        let payload = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": ["approvals": []]
        ]), encoding: .utf8))
        socket.deliver(payload)

        let approvals = try await awaitResult(of: pendingTask, "the approval.pending response")
        XCTAssertTrue(approvals.isEmpty)
        client.disconnect()
    }

    private func executePendingApprovals(
        rawResult: String
    ) async throws -> [ApprovalActivity] {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let pendingTask = Task { try await client.pendingApprovals(sessionId: "runtime-queue") }
        try await sent.wait("the approval.pending request to be sent")
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(request["id"] as? Int)
        socket.deliver("""
        {"jsonrpc": "2.0", "id": \(id), "result": \(rawResult)}
        """)
        let approvals = try await awaitResult(of: pendingTask, "the approval.pending response")
        client.disconnect()
        return approvals
    }

    func testPendingApprovalsStructuralValidation() async throws {
        // Valid empty queue returns empty array
        let emptyQueue = try await executePendingApprovals(rawResult: "{\"approvals\": []}")
        XCTAssertTrue(emptyQueue.isEmpty)

        // Valid array with mixed elements tolerantly decodes valid rows
        let mixedQueue = try await executePendingApprovals(
            rawResult: "{\"approvals\": [42, \"invalid\", {\"request_id\": \"app-1\", \"description\": \"Valid item\"}, null]}"
        )
        XCTAssertEqual(mixedQueue.count, 1)
        XCTAssertEqual(mixedQueue.first?.requestId, "app-1")

        // Non-object root must throw invalidResponse
        for nonObject in ["\"ok\"", "42", "true", "null", "[]", "[{\"approvals\": []}]"] {
            do {
                _ = try await executePendingApprovals(rawResult: nonObject)
                XCTFail("Expected invalidResponse for non-object root: \(nonObject)")
            } catch let error as HermesError {
                guard case .invalidResponse = error else {
                    XCTFail("Expected .invalidResponse for \(nonObject), got \(error)")
                    continue
                }
            }
        }

        // Object missing "approvals" field must throw invalidResponse
        for missingApprovals in ["{}", "{\"other\": 123}", "{\"status\": \"ok\"}"] {
            do {
                _ = try await executePendingApprovals(rawResult: missingApprovals)
                XCTFail("Expected invalidResponse for missing approvals key: \(missingApprovals)")
            } catch let error as HermesError {
                guard case .invalidResponse = error else {
                    XCTFail("Expected .invalidResponse for \(missingApprovals), got \(error)")
                    continue
                }
            }
        }

        // Object where "approvals" is not an array (null, scalar, object) must throw invalidResponse
        for malformedApprovals in [
            "{\"approvals\": null}",
            "{\"approvals\": 42}",
            "{\"approvals\": \"none\"}",
            "{\"approvals\": true}",
            "{\"approvals\": {}}"
        ] {
            do {
                _ = try await executePendingApprovals(rawResult: malformedApprovals)
                XCTFail("Expected invalidResponse for non-array approvals: \(malformedApprovals)")
            } catch let error as HermesError {
                guard case .invalidResponse = error else {
                    XCTFail("Expected .invalidResponse for \(malformedApprovals), got \(error)")
                    continue
                }
            }
        }
    }

    // MARK: - server→client requests (Hermes #110521 / #112548)

    /// Connects a client whose receive loop is ready for the next frame.
    private func connectedClientForServerRequests(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (HermesClient, FakeSocket) {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete", file: file, line: line)
        return (client, socket)
    }

    /// Delivers `object` once the receive loop is suspended in `receive()`,
    /// so the frame cannot be lost to a not-yet-started loop.
    private func deliverFrame(
        _ object: [String: Any],
        to socket: FakeSocket,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 where !socket.isReceivePending {
            await Task.yield()
        }
        XCTAssertTrue(socket.isReceivePending, "The receive loop never suspended", file: file, line: line)
        let text = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8), file: file, line: line)
        socket.deliver(text)
        await flushMainActor()
    }

    /// Bounded wait until `socket` has sent at least `count` text frames.
    private func waitForSends(
        _ count: Int,
        on socket: FakeSocket,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 where socket.sentTexts.count < count {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(socket.sentTexts.count, count, "Expected \(count) outbound frames", file: file, line: line)
    }

    private func sentFrame(_ socket: FakeSocket, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last, file: file, line: line).utf8)) as? [String: Any],
            file: file,
            line: line
        )
    }

    func testGatewayReadyAdvertisesServerRequestsCapability() async throws {
        // Without this advertisement Hermes treats the socket as a client
        // that predates server→client requests and withdraws every approval
        // (kaishi00/hermes-conduit#239).
        let (client, socket) = try await connectedClientForServerRequests()
        let sent = Gate()
        socket.onSend = { sent.signal() }
        try await deliverFrame([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "gateway.ready", "payload": ["change_events": true]]
        ], to: socket)
        try await sent.wait("client.capabilities to be sent after gateway.ready")

        let request = try sentFrame(socket)
        XCTAssertEqual(request["method"] as? String, "client.capabilities")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["server_requests"] as? Bool, true)
        XCTAssertNotNil(request["id"] as? Int, "The advertisement is an ordinary RPC request")

        // A repeated gateway.ready on the same socket must not advertise again.
        try await deliverFrame([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "gateway.ready", "payload": [String: Any]()]
        ], to: socket)
        XCTAssertEqual(socket.sentTexts.count, 1, "client.capabilities is sent once per connection")
        client.disconnect()
    }

    func testApprovalServerRequestPresentsApprovalCardAndWritesNoReply() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        var events: [StreamEvent] = []
        client.onEvent = { events.append($0) }
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "srq-0123456789ab", "method": "approval",
            "params": [
                "session_id": "runtime-1",
                "request_id": "queue-1",
                "command": "rm -rf scratch",
                "description": "recursive delete",
                "choices": ["once", "session", "always", "deny"]
            ]
        ], to: socket)

        XCTAssertEqual(events.count, 1)
        guard case .approval(let sessionId, let activity)? = events.first else {
            return XCTFail("Expected an approval event, got \(events)")
        }
        XCTAssertEqual(sessionId, "runtime-1")
        XCTAssertEqual(
            activity.requestId, "queue-1",
            "The card must keep the approval queue id: approval.respond resolves the queue entry"
        )
        XCTAssertEqual(activity.command, "rm -rf scratch")
        XCTAssertEqual(activity.choices, ["once", "session", "always", "deny"])
        XCTAssertTrue(
            socket.sentTexts.isEmpty,
            "The approval stays open until the user answers; the gateway withdraws it once approval.respond resolves it"
        )
        client.disconnect()
    }

    func testApprovalRequestCancelIsTranslatedToTheQueueID() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        var events: [StreamEvent] = []
        client.onEvent = { events.append($0) }
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "srq-a1a1a1a1a1a1", "method": "approval",
            "params": ["session_id": "runtime-1", "request_id": "queue-1", "command": "rm -rf scratch"]
        ], to: socket)
        try await deliverFrame([
            "jsonrpc": "2.0", "method": "event",
            "params": [
                "type": "request.cancel", "session_id": "runtime-1",
                "payload": ["id": "srq-a1a1a1a1a1a1", "method": "approval", "reason": "timeout"]
            ]
        ], to: socket)

        let withdrawn = events.compactMap { event -> (String, String, String)? in
            guard case .approvalWithdrawn(let sessionId, let requestId, let reason) = event else { return nil }
            return (sessionId, requestId, reason)
        }
        XCTAssertEqual(withdrawn.count, 1)
        XCTAssertEqual(withdrawn.first?.0, "runtime-1")
        XCTAssertEqual(withdrawn.first?.1, "queue-1", "The card is keyed by the queue id, not the srq id")
        XCTAssertEqual(withdrawn.first?.2, "timeout")
        client.disconnect()
    }

    func testApprovalCancelWithoutEnvelopeSessionFallsBackToTheRequestSession() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        var events: [StreamEvent] = []
        client.onEvent = { events.append($0) }
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "srq-b2b2b2b2b2b2", "method": "approval",
            "params": ["session_id": "runtime-1", "request_id": "queue-2", "command": "rm -rf scratch"]
        ], to: socket)
        try await deliverFrame([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "request.cancel", "payload": ["id": "srq-b2b2b2b2b2b2", "method": "approval", "reason": "timeout"]]
        ], to: socket)
        let sessions = events.compactMap { event -> String? in
            guard case .approvalWithdrawn(let sessionId, _, _) = event else { return nil }
            return sessionId
        }
        XCTAssertEqual(sessions, ["runtime-1"], "An empty session id would be dropped by the active-session filter")
        client.disconnect()
    }

    func testClarifyCancelWithoutEnvelopeSessionFallsBackToTheRequestSession() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        var events: [StreamEvent] = []
        client.onEvent = { events.append($0) }
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "srq-c3c3c3c3c3c3", "method": "clarify",
            "params": ["session_id": "runtime-1", "question": "Which env?", "choices": ["a"]]
        ], to: socket)
        try await deliverFrame([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "request.cancel", "payload": ["id": "srq-c3c3c3c3c3c3", "method": "clarify", "reason": "timeout"]]
        ], to: socket)
        let expiries = events.compactMap { event -> (String, String)? in
            guard case .clarifyExpire(let sessionId, let requestId, _) = event else { return nil }
            return (sessionId, requestId)
        }
        XCTAssertEqual(expiries.count, 1)
        XCTAssertEqual(expiries.first?.0, "runtime-1", "An empty session id would be dropped by the active-session filter")
        XCTAssertEqual(expiries.first?.1, "srq-c3c3c3c3c3c3")
        client.disconnect()
    }

    func testFailedCapabilityAdvertisementRetriesOnNextGatewayReady() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        let ready: [String: Any] = [
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "gateway.ready", "payload": [String: Any]()]
        ]
        try await deliverFrame(ready, to: socket)
        await waitForSends(1, on: socket)
        let firstID = try XCTUnwrap(try sentFrame(socket)["id"] as? Int)
        try await deliverFrame([
            "jsonrpc": "2.0", "id": firstID, "error": ["code": -32603, "message": "transient"]
        ], to: socket)

        for _ in 0..<50 { await Task.yield() }  // let the failed RPC's catch clear the latch
        try await deliverFrame(ready, to: socket)
        await waitForSends(2, on: socket)
        XCTAssertEqual(socket.sentTexts.count, 2, "A failed advertisement must not latch the socket as advertised")
        XCTAssertEqual(try sentFrame(socket)["method"] as? String, "client.capabilities")
        client.disconnect()
    }

    /// Advertises and answers `client.capabilities` with `result`.
    private func advertise(
        _ socket: FakeSocket,
        result: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let before = socket.sentTexts.count
        try await deliverFrame([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "gateway.ready", "payload": [String: Any]()]
        ], to: socket, file: file, line: line)
        await waitForSends(before + 1, on: socket, file: file, line: line)
        let id = try XCTUnwrap(try sentFrame(socket, file: file, line: line)["id"] as? Int, file: file, line: line)
        try await deliverFrame(["jsonrpc": "2.0", "id": id, "result": result], to: socket, file: file, line: line)
        for _ in 0..<50 { await Task.yield() }
    }

    func testWindowOwnedRequestGetsNotShownDeclineWhenTheGatewayCountsThem() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        try await advertise(socket, result: ["server_requests": ["tour"], "declines_not_shown": true])
        let sentBefore = socket.sentTexts.count
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "srq-7070707070aa", "method": "tour",
            "params": ["session_id": "runtime-1", "action": "start"]
        ], to: socket)
        await waitForSends(sentBefore + 1, on: socket)
        let reply = try sentFrame(socket)
        XCTAssertEqual(reply["id"] as? String, "srq-7070707070aa")
        XCTAssertEqual(
            (reply["error"] as? [String: Any])?["code"] as? Int, 4404,
            "A window-owned request is declined as not shown, never settled with -32601"
        )
        client.disconnect()
    }

    func testWindowOwnedRequestStaysSilentWhenTheGatewayDoesNotCountDeclines() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        try await advertise(socket, result: ["server_requests": ["tour"]])
        let sentBefore = socket.sentTexts.count
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "srq-7070707070bb", "method": "preview.read",
            "params": ["session_id": "runtime-1"]
        ], to: socket)
        XCTAssertEqual(
            socket.sentTexts.count, sentBefore,
            "Any error would settle the request there and take it from a Desktop window"
        )
        client.disconnect()
    }

    func testEventFrameCarryingAnIDIsStillAnEvent() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        var events: [StreamEvent] = []
        client.onEvent = { events.append($0) }
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "evt-1", "method": "event",
            "params": ["type": "message.start", "session_id": "runtime-1"]
        ], to: socket)
        guard case .messageStart(let sessionId)? = events.first else {
            return XCTFail("Expected the event to be delivered, got \(events)")
        }
        XCTAssertEqual(sessionId, "runtime-1")
        XCTAssertTrue(socket.sentTexts.isEmpty, "An event is never answered")
        client.disconnect()
    }

    func testResumeDeclinesReplayedRequestsItCannotPresent() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSession("runtime-1") }
        try await sent.wait("the session.resume request to be sent")
        let id = try XCTUnwrap(try sentFrame(socket)["id"] as? Int)
        try await deliverFrame([
            "jsonrpc": "2.0", "id": id,
            "result": [
                "session_id": "runtime-1", "running": true, "messages": [Any](), "info": [String: Any](),
                "open_requests": [
                    ["id": "srq-dec1dec1dec1", "method": "vault.code", "params": ["session_id": "runtime-1"]]
                ]
            ]
        ], to: socket)
        _ = try await awaitResult(of: openTask, "the session.resume response")
        await waitForSends(2, on: socket)
        let reply = try sentFrame(socket)
        XCTAssertEqual(reply["id"] as? String, "srq-dec1dec1dec1")
        XCTAssertEqual(
            (reply["error"] as? [String: Any])?["code"] as? Int, -32601,
            "A replayed request with no UI here must fail fast, like the live frame"
        )
        client.disconnect()
    }

    func testSingleClarifyServerRequestIsAnsweredWithResponseFrame() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        var events: [StreamEvent] = []
        client.onEvent = { events.append($0) }
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "srq-aaaaaaaaaaaa", "method": "clarify",
            "params": ["session_id": "runtime-1", "question": "Which env?", "choices": ["staging", "prod"]]
        ], to: socket)
        guard case .clarify(let sessionId, let activity)? = events.first else {
            return XCTFail("Expected a clarify event, got \(events)")
        }
        XCTAssertEqual(sessionId, "runtime-1")
        XCTAssertEqual(activity.requestId, "srq-aaaaaaaaaaaa", "The card is keyed by the server request id")
        XCTAssertEqual(activity.questions.count, 1)

        let outcome = try await client.respondToClarification(
            requestId: "srq-aaaaaaaaaaaa",
            answer: "staging",
            questionId: nil
        )
        XCTAssertEqual(outcome, .accepted(remaining: nil))
        let reply = try sentFrame(socket)
        XCTAssertEqual(reply["id"] as? String, "srq-aaaaaaaaaaaa")
        XCTAssertNil(reply["method"], "A response frame never carries a method")
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["answer"] as? String, "staging")
        client.disconnect()
    }

    func testBatchClarifyServerRequestLocksEachQuestion() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        let sent = Gate()
        socket.onSend = { sent.signal() }
        let respondTask = Task<HermesClient.ClarifyResponseOutcome, Error> {
            try await client.respondToClarification(
                requestId: "srq-bbbbbbbbbbbb",
                answer: "unit",
                questionId: "tests"
            )
        }
        try await sent.wait("the clarify.lock request to be sent")
        let request = try sentFrame(socket)
        XCTAssertEqual(request["method"] as? String, "clarify.lock")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["request_id"] as? String, "srq-bbbbbbbbbbbb")
        XCTAssertEqual(params["question_id"] as? String, "tests")
        XCTAssertEqual(params["answer"] as? String, "unit")

        let id = try XCTUnwrap(request["id"] as? Int)
        try await deliverFrame(["jsonrpc": "2.0", "id": id, "result": ["status": "ok", "remaining": []]], to: socket)
        let outcome = try await awaitResult(of: respondTask, "the clarify.lock response")
        XCTAssertEqual(outcome, .accepted(remaining: []))
        client.disconnect()
    }

    func testUnsupportedServerRequestIsDeclinedWithMethodNotFound() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        var events: [StreamEvent] = []
        client.onEvent = { events.append($0) }
        let sent = Gate()
        socket.onSend = { sent.signal() }
        try await deliverFrame([
            "jsonrpc": "2.0", "id": "srq-cccccccccccc", "method": "sudo",
            "params": ["session_id": "runtime-1", "command": "sudo ls"]
        ], to: socket)
        try await sent.wait("the decline to be sent")

        let reply = try sentFrame(socket)
        XCTAssertEqual(reply["id"] as? String, "srq-cccccccccccc")
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
        XCTAssertTrue(events.isEmpty)
        client.disconnect()
    }

    func testServerRequestDoesNotSettlePendingRPCWithCollidingID() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        let sent = Gate()
        socket.onSend = { sent.signal() }
        let respondTask = Task<Bool, Error> {
            try await client.respondToApproval(sessionId: "runtime-1", requestId: "queue-1", choice: "once")
        }
        try await sent.wait("the approval.respond request to be sent")
        let id = try XCTUnwrap(try sentFrame(socket)["id"] as? Int)

        // A request frame reusing the pending integer id must be treated as a
        // request (declined here), never as that RPC's response.
        try await deliverFrame([
            "jsonrpc": "2.0", "id": id, "method": "vault.code", "params": ["session_id": "runtime-1"]
        ], to: socket)
        XCTAssertEqual(socket.sentTexts.count, 2, "The colliding request is declined")

        try await deliverFrame(["jsonrpc": "2.0", "id": id, "result": ["resolved": 1]], to: socket)
        let accepted = try await awaitResult(of: respondTask, "the real approval.respond response")
        XCTAssertTrue(accepted)
        client.disconnect()
    }

    func testResumeRestoresClarifyFromOpenRequests() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSession("runtime-1") }
        try await sent.wait("the session.resume request to be sent")
        let id = try XCTUnwrap(try sentFrame(socket)["id"] as? Int)
        try await deliverFrame([
            "jsonrpc": "2.0", "id": id,
            "result": [
                "session_id": "runtime-1",
                "running": true,
                "messages": [Any](),
                "info": [String: Any](),
                "open_requests": [[
                    "id": "srq-dddddddddddd",
                    "method": "clarify",
                    "params": [
                        "session_id": "runtime-1",
                        "questions": [
                            ["qid": "environment", "question": "Which environment?", "choices": ["staging"], "multi_select": false],
                            ["qid": "tests", "question": "Which tests?", "choices": ["unit", "ui"], "multi_select": true]
                        ],
                        "answers": ["environment": "staging"]
                    ]
                ]]
            ]
        ], to: socket)
        let result = try await awaitResult(of: openTask, "the session.resume response")
        let pending = try XCTUnwrap(result.snapshot.pendingClarify, "open_requests must restore the clarify card")
        XCTAssertEqual(pending.requestId, "srq-dddddddddddd")
        XCTAssertEqual(pending.questions.count, 2)
        XCTAssertEqual(pending.questions[0].status, .answered, "Answers locked before the reconnect stay locked")
        XCTAssertEqual(pending.questions[1].status, .pending)
        XCTAssertTrue(client.isServerRequestID("srq-dddddddddddd"))
        XCTAssertTrue(result.snapshot.additionalPendingClarifies.isEmpty)
        client.disconnect()
    }

    func testResumeKeepsAnOpenClarifyWhenPendingClarifyIsAlsoPresent() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSession("runtime-1") }
        try await sent.wait("the session.resume request to be sent")
        let id = try XCTUnwrap(try sentFrame(socket)["id"] as? Int)
        try await deliverFrame([
            "jsonrpc": "2.0", "id": id,
            "result": [
                "session_id": "runtime-1", "running": true, "messages": [Any](), "info": [String: Any](),
                "pending_clarify": ["request_id": "req-legacy", "question": "Legacy?", "choices": ["x"]],
                "open_requests": [
                    ["id": "srq-c4c4c4c4c4c4", "method": "clarify",
                     "params": ["session_id": "runtime-1", "question": "Open?", "choices": ["y"]]]
                ]
            ]
        ], to: socket)
        let result = try await awaitResult(of: openTask, "the session.resume response")
        XCTAssertEqual(result.snapshot.pendingClarify?.requestId, "req-legacy")
        XCTAssertEqual(
            result.snapshot.additionalPendingClarifies.map(\.requestId), ["srq-c4c4c4c4c4c4"],
            "An open clarify must not be dropped because pending_clarify was already taken"
        )
        client.disconnect()
    }

    func testResumeRestoresEveryOpenClarify() async throws {
        let (client, socket) = try await connectedClientForServerRequests()
        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSession("runtime-1") }
        try await sent.wait("the session.resume request to be sent")
        let id = try XCTUnwrap(try sentFrame(socket)["id"] as? Int)
        try await deliverFrame([
            "jsonrpc": "2.0", "id": id,
            "result": [
                "session_id": "runtime-1", "running": true, "messages": [Any](), "info": [String: Any](),
                "open_requests": [
                    ["id": "srq-c1c1c1c1c1c1", "method": "clarify",
                     "params": ["session_id": "runtime-1", "question": "First?", "choices": ["a"]]],
                    ["id": "srq-c2c2c2c2c2c2", "method": "clarify",
                     "params": ["session_id": "runtime-1", "question": "Second?", "choices": ["b"]]]
                ]
            ]
        ], to: socket)
        let result = try await awaitResult(of: openTask, "the session.resume response")
        XCTAssertEqual(result.snapshot.pendingClarify?.requestId, "srq-c1c1c1c1c1c1", "The oldest rides pendingClarify")
        XCTAssertEqual(result.snapshot.additionalPendingClarifies.map(\.requestId), ["srq-c2c2c2c2c2c2"])
        client.disconnect()
    }

    func testIsServerRequestIDRecognisesOnlyServerRequestIDs() async throws {
        let (client, _) = try await connectedClientForServerRequests()
        XCTAssertFalse(client.isServerRequestID("req-1"))
        XCTAssertTrue(client.isServerRequestID("srq-eeeeeeeeeeee"))
        client.disconnect()
    }

    // MARK: - pending_clarify restore

    func testResumeSnapshotParsesPendingClarifyBatchWithLockedAnswers() throws {
        let snapshot = SessionRuntimeSnapshot(object: [
            "running": .bool(true),
            "pending_clarify": .object([
                "request_id": .string("req-batch"),
                "questions": .array([
                    .object(["qid": .string("environment"), "question": .string("Which environment?"), "choices": .array([.string("staging")]), "multi_select": .bool(false)]),
                    .object(["qid": .string("tests"), "question": .string("Which tests?"), "choices": .array([.string("unit"), .string("ui")]), "multi_select": .bool(true)])
                ]),
                "answers": .object(["environment": .string("staging")])
            ])
        ])
        let pending = try XCTUnwrap(snapshot.pendingClarify)
        XCTAssertEqual(pending.requestId, "req-batch")
        XCTAssertEqual(pending.questions.count, 2)
        XCTAssertEqual(pending.questions[0].status, .answered, "The answer Hermes reports locked must restore as locked")
        XCTAssertEqual(pending.questions[0].answer, "staging")
        XCTAssertEqual(pending.questions[1].status, .pending, "Unanswered questions stay answerable")
    }

    func testResumeSnapshotWithoutPendingClarifyParsesNil() {
        let snapshot = SessionRuntimeSnapshot(object: ["running": .bool(false)])
        XCTAssertNil(snapshot.pendingClarify)
    }

    // MARK: - session.compress

    func testSessionCompressTimeoutPinsDedicatedBudget() {
        // The budget must exceed the gateway's 630s compute-host compress
        // wait cap (_COMPUTE_HOST_COMPRESS_WAIT_CAP_SECS): the gateway answers
        // `status: "pending"` after the cap, so a smaller budget reports a
        // false client timeout while the host is still compressing (#97948).
        XCTAssertEqual(HermesClient.sessionCompressTimeout, 660)
        XCTAssertGreaterThan(HermesClient.sessionCompressTimeout, HermesClient.requestTimeout)
    }

    func testCompressSessionSendsDedicatedRPCAndAdoptsResponse() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let compressTask = Task<SessionCompressResult, Error> {
            try await client.compressSession(sessionId: "sess-c")
        }
        try await sent.wait("the session.compress request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.compress")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "sess-c")
        XCTAssertNil(params["focus_topic"], "A missing focus topic must be omitted, not sent as an empty string")

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "status": "compressed",
                "removed": 9,
                "summary": [
                    "headline": "Compressed 13 → 4 messages",
                    "token_line": "~12,000 → ~3,100 tokens"
                ],
                "messages": [
                    ["role": "user", "content": "Summary carrier", "timestamp": "2026-09-13T08:00:00Z"],
                    ["role": "assistant", "content": "Tail answer", "timestamp": "2026-09-13T08:00:05Z"]
                ]
            ]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let result = try await awaitResult(of: compressTask, "the session.compress response")
        XCTAssertEqual(result.status, .compressed)
        XCTAssertFalse(result.isAborted)
        XCTAssertFalse(result.lockHeld)
        XCTAssertEqual(result.removed, 9)
        XCTAssertTrue(result.hasMessagesPayload)
        XCTAssertEqual(result.messages.map { $0.role }, [.user, .assistant])
        XCTAssertEqual(result.summaryHeadline, "Compressed 13 → 4 messages")
        client.disconnect()
    }

    func testCompressSessionSendsFocusTopicWhenProvided() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let compressTask = Task<SessionCompressResult, Error> {
            try await client.compressSession(sessionId: "sess-c", focusTopic: "  auth refactor  ")
        }
        try await sent.wait("the session.compress request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["focus_topic"] as? String, "auth refactor", "The focus topic ships trimmed, like upstream Desktop")

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["status": "pending", "message": "compression still running in the background"]
        ]
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))

        let result = try await awaitResult(of: compressTask, "the pending session.compress response")
        XCTAssertTrue(result.isPending)
        XCTAssertEqual(result.message, "compression still running in the background")
        XCTAssertFalse(result.hasMessagesPayload)
        client.disconnect()
    }

    func testSessionCompressResultDistinguishesUpstreamShapes() {
        // Compute-host pending: the bounded gateway wait expired, the host is
        // still compressing — a success-shaped protocol answer, not an error.
        let pending = SessionCompressResult(from: .object([
            "status": .string("pending"),
            "message": .string("compression still running in the background; the transcript will refresh when it finishes")
        ]))
        XCTAssertTrue(pending.isPending)
        XCTAssertNotNil(pending.message)
        XCTAssertFalse(pending.hasMessagesPayload)
        XCTAssertFalse(pending.isAborted)

        // Concurrent compression holds the lock: no `status`, never an error.
        let lockHeld = SessionCompressResult(from: .object([
            "compressed": .bool(false),
            "lock_held": .bool(true),
            "message": .string("compression already running")
        ]))
        XCTAssertTrue(lockHeld.lockHeld)
        XCTAssertNil(lockHeld.status)
        XCTAssertEqual(lockHeld.message, "compression already running")

        // In-process abort: nothing changed, transcript must not be replaced.
        let aborted = SessionCompressResult(from: .object([
            "status": .string("aborted"),
            "summary": .object(["headline": .string("compression aborted"), "aborted": .bool(true)])
        ]))
        XCTAssertTrue(aborted.isAborted)
        XCTAssertEqual(aborted.summaryHeadline, "compression aborted")

        // Compute-host results can carry the abort flag inside `summary`
        // while `status` still reads "compressed".
        let summaryAborted = SessionCompressResult(from: .object([
            "status": .string("compressed"),
            "summary": .object(["aborted": .bool(true)])
        ]))
        XCTAssertTrue(summaryAborted.isAborted)

        // An absent `messages` payload is distinct from an empty one.
        let absent = SessionCompressResult(from: .object(["status": .string("compressed"), "removed": .number(3)]))
        XCTAssertFalse(absent.hasMessagesPayload)
        XCTAssertTrue(absent.messages.isEmpty)
        XCTAssertEqual(absent.removed, 3)

        // Lock-held responses carry no status and must not read as pending.
        XCTAssertFalse(lockHeld.isPending)
    }

    func testCompressSessionTimeoutSurfacesAsTimeoutOfTheCompressMethod() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let compressTask = Task<SessionCompressResult, Error> {
            try await client.compressSession(sessionId: "sess-slow", timeout: 0.2)
        }
        do {
            _ = try await awaitResult(of: compressTask, "the compress timeout")
            XCTFail("Expected compressSession to time out without a response")
        } catch HermesError.timeout(let method) {
            XCTAssertEqual(method, "session.compress")
        } catch {
            XCTFail("Expected HermesError.timeout, got \(error)")
        }
        client.disconnect()
    }

    func testSessionCompressResultRejectsOutOfRangeAndInexactRemoved() {
        // `Int(Double)` traps outside the Int64 range — `removed` is
        // gateway-authored, so an out-of-range payload must degrade to nil,
        // never crash the client.
        let outOfRange = SessionCompressResult(from: .object([
            "status": .string("compressed"),
            "removed": .number(1e300)
        ]))
        XCTAssertNil(outOfRange.removed)

        let justOverMax = SessionCompressResult(from: .object([
            "removed": .number(9_223_372_036_854_775_808.0) // 2^63 exactly
        ]))
        XCTAssertNil(justOverMax.removed)

        // Non-integer doubles are rejected too: only exact whole values
        // convert.
        let nonInteger = SessionCompressResult(from: .object([
            "removed": .number(2.5)
        ]))
        XCTAssertNil(nonInteger.removed)

        // Exact in-range values still convert, including both Int64 edges:
        // -2^63 converts to Int.min, and the largest admitted Double
        // (2^63 − 1024, the spacing at that magnitude) converts to
        // Int.max − 1023.
        let whole = SessionCompressResult(from: .object(["removed": .number(9)]))
        XCTAssertEqual(whole.removed, 9)
        let minBound = SessionCompressResult(from: .object([
            "removed": .number(-9_223_372_036_854_775_808.0) // -2^63 == Int.min
        ]))
        XCTAssertEqual(minBound.removed, Int.min)
        let maxEdge = SessionCompressResult(from: .object([
            "removed": .number(9_223_372_036_854_775_808.0 - 1024.0)
        ]))
        XCTAssertEqual(maxEdge.removed, Int.max - 1023)
    }

    func testSessionNotFoundErrorClassification() {
        // The gateway answers session-scoped RPCs for a reaped runtime with
        // _err(4001, "session not found") (tui_gateway/server.py).
        XCTAssertTrue(HermesClient.isSessionNotFoundError(
            RpcError(code: 4001, message: "session not found")
        ))
        XCTAssertTrue(HermesClient.isSessionNotFoundError(
            RpcError(code: nil, message: "Session Not Found: runtime-a")
        ))

        // NOT in the class: busy rejections, timeouts, connection loss,
        // compression failures — stale-runtime recovery must never fire for
        // these.
        XCTAssertFalse(HermesClient.isSessionNotFoundError(
            RpcError(code: 4009, message: "session busy — /interrupt the current turn before /compress")
        ))
        XCTAssertFalse(HermesClient.isSessionNotFoundError(
            HermesError.timeout("session.compress")
        ))
        XCTAssertFalse(HermesClient.isSessionNotFoundError(HermesError.connectionClosed))
        XCTAssertFalse(HermesClient.isSessionNotFoundError(
            RpcError(code: 5005, message: "compression failed: provider exploded")
        ))
    }

    func testMissingRPCMethodClassificationMirrorsUpstream() {
        // The gateway answers unknown methods with JSON-RPC -32601
        // ("unknown method: …", tui_gateway/server.py).
        XCTAssertTrue(HermesClient.isMissingRPCMethod(
            RpcError(code: -32601, message: "unknown method: session.compress")
        ))
        XCTAssertTrue(HermesClient.isMissingRPCMethod(
            RpcError(code: nil, message: "Method not found: session.compress")
        ))
        XCTAssertTrue(HermesClient.isMissingRPCMethod(
            NSError(domain: "test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "no such method: session.compress"])
        ))

        // NOT in the class: a timeout (compression is legitimately slow),
        // busy rejections, compression failures, transport loss.
        XCTAssertFalse(HermesClient.isMissingRPCMethod(
            HermesError.timeout("session.compress")
        ))
        XCTAssertFalse(HermesClient.isMissingRPCMethod(
            RpcError(code: 4009, message: "session busy — /interrupt the current turn before /compress")
        ))
        XCTAssertFalse(HermesClient.isMissingRPCMethod(
            RpcError(code: 5005, message: "compression failed: provider exploded")
        ))
        XCTAssertFalse(HermesClient.isMissingRPCMethod(HermesError.connectionClosed))
        XCTAssertFalse(HermesClient.isMissingRPCMethod(HermesError.notConnected))
    }

    // MARK: - Helpers

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    /// Bounded wait for a spawned throwing task, returning its result. The
    /// Task-side counterpart of `Gate.wait`: a wedged phase fails the
    /// test naming `phase` instead of suspending forever.
    private func awaitResult<T>(
        of task: Task<T, Error>,
        _ phase: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> T {
        let finished = Gate()
        let box = ResultBox<T>()
        let watcher = Task<Void, Never>.detached(priority: .userInitiated) {
            do {
                box.value = .success(try await task.value)
            } catch {
                box.value = .failure(error)
            }
            finished.signal()
        }
        defer { watcher.cancel() }
        try await finished.wait(phase, timeout: timeout, file: file, line: line)
        guard let stored = box.value else {
            XCTFail("Expected a result for \(phase)", file: file, line: line)
            throw TestSyncTimedOut(phase: phase)
        }
        return try stored.get()
    }

    private func makeClient(transport: FakeTransport, profile: String? = nil) -> HermesClient {
        HermesClient(
            connection: HermesConnection(baseUrl: "https://test.example", ticket: "ticket"),
            profile: profile,
            transportFactory: { transport }
        )
    }

    private func flushMainActor() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// Bounded wait for a spawned task to finish — the task-side counterpart
    /// of `Gate.wait`. A `connect()` that never unwinds fails the test naming
    /// `phase` instead of suspending forever on `task.value`. If the deadline
    /// fires, the watcher is left leaked on `task.value` by design: checked
    /// continuations ignore cancellation, and the test process is on its way
    /// to a failure report anyway.
    private func awaitCompletion<T>(
        of task: Task<T, Never>,
        _ phase: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let finished = Gate()
        let watcher = Task<Void, Never>.detached(priority: .userInitiated) {
            _ = await task.value
            finished.signal()
        }
        defer { watcher.cancel() }
        try await finished.wait(phase, timeout: timeout, file: file, line: line)
    }

    /// A gateway stream-event frame (`message.start`) that StreamEventParser
    /// accepts, so `deliver` genuinely exercises the receive success path —
    /// without the identity guard this would fire `onEvent`.
    private func someEventJSON() -> String {
        """
        {"method":"event","params":{"type":"message.start","session_id":"sess-1"}}
        """
    }
}

// MARK: - Test doubles

/// Single-use gate that survives a `signal()` arriving before `wait()` (the
/// flag is sticky). `wait` is bounded: XCTest has no per-test timeout for
/// async tests, so a missed signal would suspend the test forever and wedge
/// xcodebuild until the CI job-level kill. A missed signal must instead fail
/// the test naming the phase it was waiting for.
///
/// NSLock rather than MainActor confinement because the deadline timer runs
/// detached from any actor; whoever takes the continuation under the lock
/// resumes it exactly once, which makes the signal/timeout race safe.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    /// Resumed with `true` when the deadline wins the race.
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

            // Detached so the deadline fires even if the actor the awaited
            // work runs on never gets scheduled again.
            Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.fireDeadline()
            }
        }
        if timedOut {
            XCTFail("Timed out after \(timeout)s waiting for \(phase)", file: file, line: line)
            throw TestSyncTimedOut(phase: phase)
        }
    }

    /// Deadline half of the signal/timeout race. Whoever takes the
    /// continuation under the lock resumes it; the loser sees nil, making the
    /// race exactly-once. Synchronous (no awaits) so the NSLock critical
    /// sections stay out of async contexts.
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

/// Thrown by the bounded wait helpers after the failure has been recorded;
/// aborts the test method so a wedged phase does not cascade into misleading
/// downstream assertion failures.
private struct TestSyncTimedOut: Error {
    let phase: String
}

/// Controllable HermesWebSocket. `receive()` suspends until the test delivers a
/// message or fails it; `cancel()` mimics URLSession by recording the close
/// code and erroring the in-flight receive (real cancellation surfaces as a
/// receive error).
private final class FakeSocket: HermesWebSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var cancelled = false
    private(set) var resumed = false
    var onResume: (() -> Void)?
    var onReceivePending: (() -> Void)?
    private(set) var sentTexts: [String] = []
    /// Signalled after each outbound text frame so tests can await the
    /// JSON-RPC request before answering it.
    var onSend: (() -> Void)?

    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    func resume() {
        resumed = true
        onResume?()
    }

    /// Whether `cancel()` errors the in-flight `receive()` (true mirrors
    /// URLSession). Tests that need a frame to arrive on a cancelled socket
    /// set this false.
    var cancelErrorsReceive = true

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        cancelled = true
        if cancelErrorsReceive { failReceive(URLError(.networkConnectionLost)) }
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
            onReceivePending?()
        }
    }

    /// True while the receive loop is suspended waiting for a frame.
    var isReceivePending: Bool { receiveContinuation != nil }

    // Test hooks
    func deliver(_ text: String) {
        receiveContinuation?.resume(returning: .string(text))
        receiveContinuation = nil
    }

    func failReceive(_ error: Error) {
        receiveContinuation?.resume(throwing: error)
        receiveContinuation = nil
    }
}

/// Records `invalidate()` and completes the handshake deterministically.
/// `open(_:)` is safe to call before `makeSocket` has registered the socket
/// (e.g. right after spawning `Task { connect() }`): the request is buffered
/// and fired once the socket exists, so the handshake never races the scheduler.
private final class FakeTransport: HermesWebSocketTransport {
    private(set) var invalidated = false
    private(set) var socketsMade: [FakeSocket] = []
    /// Every upgrade request handed to `makeSocket`, in order — used by the
    /// Cloudflare HTTPS/WSS-only header tests.
    private(set) var requestsMade: [URLRequest] = []
    var nextSocket: (() -> FakeSocket)?
    private var openCallbacks: [ObjectIdentifier: () -> Void] = [:]
    private var earlyOpenRequests = Set<ObjectIdentifier>()

    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket {
        requestsMade.append(request)
        let socket = nextSocket?() ?? FakeSocket()
        socketsMade.append(socket)
        let key = ObjectIdentifier(socket)
        openCallbacks[key] = { onOpen(socket) }
        if earlyOpenRequests.remove(key) != nil, let callback = openCallbacks.removeValue(forKey: key) {
            callback()
        }
        return socket
    }

    func invalidate() {
        invalidated = true
    }

    /// Fire the handshake-open callback for a socket this transport has or will
    /// produce. Buffering makes this independent of Task scheduling order.
    func open(_ socket: FakeSocket) {
        let key = ObjectIdentifier(socket)
        if let callback = openCallbacks.removeValue(forKey: key) {
            callback()
        } else {
            earlyOpenRequests.insert(key)
        }
    }
}
