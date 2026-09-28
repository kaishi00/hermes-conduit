//
//  GeminiLiveVoiceTests.swift
//  Conduit
//
//  Gemini Live voice mode: wire format, Hermes-hosted token client, the
//  resumable session, the background-job tool bridge, and the controller's
//  "never talk over the user" rules. Written as extensions of existing
//  Voice suites: the CI test planner is at capacity for new XCTestCase
//  classes.
//

import XCTest
@testable import Conduit

// MARK: - Fakes

@MainActor
final class FakeGeminiLiveTokens: GeminiLiveTokenProviding {
    var availabilityResult: Result<GeminiLiveAvailability, Error> = .success(.available(model: "gemini-3.8-live"))
    var tokenError: Error?
    private(set) var issued = 0

    func availability() async throws -> GeminiLiveAvailability { try availabilityResult.get() }

    func freshToken() async throws -> GeminiLiveToken {
        if let tokenError { throw tokenError }
        issued += 1
        return GeminiLiveToken(
            token: "tok-\(issued)",
            expiresAt: nil,
            newSessionExpiresAt: nil,
            model: "gemini-3.8-live",
            webSocketURL: URL(string: "wss://generativelanguage.googleapis.com/ws/live")!
        )
    }
}

@MainActor
final class FakeGeminiLiveSocket: GeminiLiveSocket {
    let url: URL
    private(set) var sent: [[String: Any]] = []
    /// Every send, including ones a refused upgrade threw on.
    private(set) var attempted: [[String: Any]] = []
    private(set) var closed = false
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?

    /// Set to make the WebSocket upgrade fail the way URLSession reports it:
    /// the first send throws and the refusal is readable afterwards.
    var upgradeRefusal: GeminiLiveServerClose?

    init(url: URL) { self.url = url }

    func send(_ text: String) async throws {
        attempted.append((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:])
        if let upgradeRefusal {
            recordedClose = upgradeRefusal
            throw URLError(.badServerResponse)
        }
        sent.append((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:])
    }

    func receive() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { throw URLError(.networkConnectionLost) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func deliver(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
        }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: URLError(.cancelled))
        waiter = nil
    }

    private var recordedClose: GeminiLiveServerClose?

    /// The server ends the connection; `close` nil is a plain drop. Like
    /// URLSession, the close is reported only after `receive()` has failed.
    func serverClose(_ close: GeminiLiveServerClose?) {
        closed = true
        waiter?.resume(throwing: URLError(.networkConnectionLost))
        waiter = nil
        guard let close else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.recordedClose = close
        }
    }

    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        for _ in 0..<(timeout == .zero ? 1 : 50) {
            if let recordedClose { return recordedClose }
            await Task.yield()
        }
        return recordedClose
    }
}

@MainActor
final class FakeGeminiLiveSessionControl: GeminiLiveSessionControlling {
    var onEvent: (@MainActor (GeminiLiveProtocol.ServerEvent) -> Void)?
    var onStateChange: (@MainActor (GeminiLiveSession.State) -> Void)?
    var onConnectionReplaced: (@MainActor () -> Void)?
    var isReady = false
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var sent: [[String: Any]] = []

    func start() { started += 1 }
    func stop() { stopped += 1; isReady = false }
    /// When set, sends are recorded but reported as failed.
    var failSends = false

    func send(_ message: [String: Any], onFailure: (@MainActor () -> Void)?) {
        sent.append(message)
        if failSends { onFailure?() }
    }

    func becomeReady() {
        isReady = true
        onStateChange?(.ready)
    }

    var textTurns: [String] {
        sent.compactMap { message in
            ((((message["clientContent"] as? [String: Any])?["turns"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        }
    }
}

@MainActor
final class FakeGeminiLiveInput: GeminiLiveAudioInput {
    var onChunk: (@MainActor (Data) -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    private(set) var starts = 0
    var permission = true
    private(set) var running = false
    func requestPermission() async -> Bool { permission }
    func start() throws { running = true; starts += 1 }
    func stop() { running = false }
}

@MainActor
final class FakeGeminiLiveOutput: GeminiLiveAudioOutput {
    var isPlaying = false
    private(set) var played = 0
    private(set) var interrupts = 0
    func play(_ pcm: Data, sampleRate: Double) throws { played += 1; isPlaying = true }
    func interrupt() { interrupts += 1; isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
private func settle(_ iterations: Int = 20) async {
    for _ in 0..<iterations { await Task.yield() }
}

// MARK: - Wire format and token client

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testGeminiLiveSetupRequestsAudioResumptionCompressionAndInterruptingSpeech() throws {
        let setup = GeminiLiveProtocol.setupMessage(
            model: "gemini-3.8-live",
            systemInstruction: "Be brief.",
            functions: GeminiLiveToolBridge.functionDeclarations,
            resumptionHandle: "handle-1"
        )["setup"] as? [String: Any]
        let body = try XCTUnwrap(setup)
        XCTAssertEqual(body["model"] as? String, "models/gemini-3.8-live")
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["responseModalities"] as? [String], ["AUDIO"])
        XCTAssertEqual((body["sessionResumption"] as? [String: Any])?["handle"] as? String, "handle-1")
        XCTAssertNotNil((body["contextWindowCompression"] as? [String: Any])?["slidingWindow"])
        XCTAssertEqual((body["realtimeInputConfig"] as? [String: Any])?["activityHandling"] as? String, "START_OF_ACTIVITY_INTERRUPTS")
        let declarations = try XCTUnwrap(((body["tools"] as? [[String: Any]])?.first)?["functionDeclarations"] as? [[String: Any]])
        let behaviors = Dictionary(uniqueKeysWithValues: declarations.map { ($0["name"] as! String, $0["behavior"] as! String) })
        // Quick web lookups (weather, news) go to Gemini's own Search, not a Hermes job.
        XCTAssertTrue((body["tools"] as? [[String: Any]])?.contains { $0["googleSearch"] != nil } == true)
        XCTAssertEqual(behaviors, ["start_job": "NON_BLOCKING", "list_jobs": "BLOCKING", "cancel_job": "BLOCKING", "end_conversation": "BLOCKING"])

        // A first connection opts in to resumption without a handle.
        let fresh = GeminiLiveProtocol.setupMessage(systemInstruction: "", functions: [], resumptionHandle: nil)["setup"] as? [String: Any]
        XCTAssertEqual((fresh?["sessionResumption"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual(fresh?["model"] as? String, GeminiLiveProtocol.model)
    }

    func testGeminiLiveToolResponseCarriesSchedulingInsideTheResponse() {
        let message = GeminiLiveProtocol.toolResponseMessage(id: "c1", name: "start_job", result: ["result": "done"], scheduling: .whenIdle)
        let response = ((message["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first
        XCTAssertEqual(response?["id"] as? String, "c1")
        XCTAssertEqual((response?["response"] as? [String: Any])?["scheduling"] as? String, "WHEN_IDLE")
        XCTAssertEqual(response?["scheduling"] as? String, "WHEN_IDLE")
        XCTAssertEqual((response?["response"] as? [String: Any])?["result"] as? String, "done")

        let audio = GeminiLiveProtocol.audioMessage(pcm16: Data([1, 2]))
        XCTAssertEqual(((audio["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])?["mimeType"] as? String, "audio/pcm;rate=16000")
    }

    func testGeminiLiveDecodesEveryServerEventItActsOn() throws {
        let pcm = Data([0, 1, 2, 3])
        let frame: [String: Any] = [
            "serverContent": [
                "modelTurn": ["parts": [["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": pcm.base64EncodedString()]]]],
                "inputTranscription": ["text": "hi"],
                "outputTranscription": ["text": "hello"],
                "turnComplete": true,
            ],
        ]
        XCTAssertEqual(
            GeminiLiveProtocol.decode(try JSONSerialization.data(withJSONObject: frame)),
            [.audio(pcm, sampleRate: 24_000), .inputTranscription("hi"), .outputTranscription("hello"), .turnComplete]
        )
        func decode(_ object: [String: Any]) throws -> [GeminiLiveProtocol.ServerEvent] {
            GeminiLiveProtocol.decode(try JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(try decode(["serverContent": ["interrupted": true]]), [.interrupted])
        XCTAssertEqual(
            try decode(["toolCall": ["functionCalls": [["id": "c1", "name": "start_job", "args": ["instructions": "check the server"]]]]]),
            [.toolCall([.init(id: "c1", name: "start_job", arguments: ["instructions": "check the server"])])]
        )
        XCTAssertEqual(try decode(["toolCallCancellation": ["ids": ["c1"]]]), [.toolCallCancellation(["c1"])])
        XCTAssertEqual(try decode(["goAway": ["timeLeft": "10s"]]), [.goAway(timeLeft: 10)])
        XCTAssertEqual(try decode(["goAway": ["timeLeft": ["seconds": 5, "nanos": 500_000_000]]]), [.goAway(timeLeft: 5.5)])
        XCTAssertEqual(try decode(["sessionResumptionUpdate": ["newHandle": "h2", "resumable": true]]), [.resumptionUpdate(handle: "h2", resumable: true)])
        XCTAssertEqual(try decode(["setupComplete": [String: Any]()]), [.setupComplete])
    }

    func testGeminiLiveTokenClientParsesStatusAndTokensAndNeverFallsBackSilently() async throws {
        XCTAssertEqual(
            GeminiLiveTokenClient.availability(from: ["ok": true, "available": true, "model": "gemini-3.8-live"]),
            .available(model: "gemini-3.8-live")
        )
        XCTAssertEqual(
            GeminiLiveTokenClient.availability(from: ["ok": true, "available": false, "reason": "GEMINI_API_KEY is not set"]),
            .unavailable(reason: "GEMINI_API_KEY is not set")
        )

        let token = try GeminiLiveTokenClient.token(from: [
            "ok": true, "token": "abc", "model": "gemini-3.8-live",
            "expires_at": "2026-09-27T13:00:00Z", "new_session_expires_at": "2026-09-27T12:41:00.500Z",
            "websocket_url": "wss://generativelanguage.googleapis.com/ws/live?alt=json",
        ])
        let items = URLComponents(url: token.connectURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "access_token" }?.value, "abc")
        XCTAssertEqual(items.first { $0.name == "alt" }?.value, "json")
        XCTAssertNotNil(token.expiresAt)
        XCTAssertNotNil(token.newSessionExpiresAt)
        XCTAssertThrowsError(try GeminiLiveTokenClient.token(from: ["ok": true, "token": "abc", "websocket_url": "ws://insecure"]))
        XCTAssertThrowsError(try GeminiLiveTokenClient.token(from: ["ok": false, "reason": "no key"])) { error in
            XCTAssertEqual(error as? GeminiLiveTokenError, .unavailable(.unavailable(reason: "no key")))
        }

        // Requests are scoped to the active profile like /api/audio/*, so the
        // host reads that profile's key.
        var paths: [String] = []
        var profile = "default"
        let scoped = GeminiLiveTokenClient(profile: { profile }, request: { path, _, _ in
            paths.append(path)
            return ["ok": true, "available": true, "model": "gemini-3.8-live"]
        })
        _ = try await scoped.availability()
        profile = "work"
        _ = try await scoped.availability()
        XCTAssertEqual(paths, [GeminiLiveTokenClient.statusPath, GeminiLiveTokenClient.statusPath + "?profile=work"])

        // The plugin not being installed is reported, never papered over.
        let missing = GeminiLiveTokenClient(request: { _, _, _ in throw DashboardTicketBridgeError.http(status: 404, detail: "Not Found") })
        let status = try await missing.availability()
        XCTAssertEqual(status, .pluginMissing)
        XCTAssertNotNil(status.userFacingReason)
        do {
            _ = try await missing.freshToken()
            XCTFail("A missing plugin must not produce a token")
        } catch {
            XCTAssertEqual(error as? GeminiLiveTokenError, .unavailable(.pluginMissing))
        }
    }
}

// MARK: - Session, tools, controller

@MainActor
extension VoiceConversationControllerTests {
    private func makeGeminiSession(
        tokens: FakeGeminiLiveTokens,
        upgradeRefusal: GeminiLiveServerClose? = nil
    ) -> (GeminiLiveSession, () -> [FakeGeminiLiveSocket]) {
        var sockets: [FakeGeminiLiveSocket] = []
        let session = GeminiLiveSession(
            tokens: tokens,
            systemInstruction: "test",
            functions: GeminiLiveToolBridge.functionDeclarations,
            openSocket: { url in
                let socket = FakeGeminiLiveSocket(url: url)
                socket.upgradeRefusal = upgradeRefusal
                sockets.append(socket)
                return socket
            },
            reconnectDelay: { _ in }
        )
        return (session, { sockets })
    }

    func testGeminiLiveSessionSendsSetupWithAFreshTokenAndStreamsOnlyWhenReady() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await settle()
        let socket = try XCTUnwrap(sockets().first)
        XCTAssertEqual(URLComponents(url: socket.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "access_token" }?.value, "tok-1")
        XCTAssertNotNil(socket.sent.first?["setup"])

        session.send(GeminiLiveProtocol.audioMessage(pcm16: Data([1, 2])))
        await settle()
        XCTAssertEqual(socket.sent.count, 1, "Audio before setupComplete is dropped")

        socket.deliver(["setupComplete": [String: Any]()])
        await settle()
        XCTAssertEqual(session.state, .ready)
        session.send(GeminiLiveProtocol.audioMessage(pcm16: Data([1, 2])))
        await settle()
        XCTAssertEqual(socket.sent.count, 2)
        session.stop()
    }

    func testGeminiLiveGoAwayResumesOnANewConnectionWithAFreshTokenAndHandle() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        var replaced = 0
        session.onConnectionReplaced = { replaced += 1 }
        session.start()
        await settle()
        let first = try XCTUnwrap(sockets().first)
        first.deliver(["setupComplete": [String: Any]()])
        first.deliver(["sessionResumptionUpdate": ["newHandle": "h-1", "resumable": true]])
        first.deliver(["sessionResumptionUpdate": ["newHandle": "h-unusable", "resumable": false]])
        first.deliver(["goAway": ["timeLeft": "5s"]])
        await settle(40)

        XCTAssertEqual(sockets().count, 2)
        XCTAssertEqual(tokens.issued, 2, "Every connection gets its own single-use token")
        let second = sockets()[1]
        let setup = second.sent.first?["setup"] as? [String: Any]
        XCTAssertEqual((setup?["sessionResumption"] as? [String: Any])?["handle"] as? String, "h-1")
        XCTAssertFalse(first.closed, "The old connection serves until the new one is ready")

        second.deliver(["setupComplete": [String: Any]()])
        await settle()
        XCTAssertTrue(first.closed)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(replaced, 1)
        session.stop()
    }

    func testGeminiLiveSetupRefusedByGoogleFailsWithItsReasonInsteadOfLooping() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await settle()
        try XCTUnwrap(sockets().first).serverClose(.init(code: 1008, reason: "models/gemini-3.8-live is not found"))
        await settle(80)

        XCTAssertEqual(session.state, .failed(AppLocalization.string("Gemini Live refused the connection: \("models/gemini-3.8-live is not found")")))
        XCTAssertEqual(sockets().count, 1, "a refused setup is not retried")
        XCTAssertEqual(tokens.issued, 1)
    }

    private func searches(_ socket: FakeGeminiLiveSocket) -> Bool {
        let setup = socket.attempted.first?["setup"] as? [String: Any]
        let tools = setup?["tools"] as? [[String: Any]] ?? []
        return tools.contains { $0["googleSearch"] != nil }
    }

    private var spentQuota: GeminiLiveServerClose {
        GeminiLiveServerClose(code: 1011, reason: "You exceeded your current quota, please check your plan and billing details.")
    }

    func testGeminiLiveQuotaRefusedUpgradeRetriesOnceWithoutGoogleSearch() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens, upgradeRefusal: spentQuota)
        session.start()
        await settle(120)

        XCTAssertEqual(sockets().count, 2)
        XCTAssertTrue(searches(try XCTUnwrap(sockets().first)))
        XCTAssertFalse(searches(try XCTUnwrap(sockets().last)))
        XCTAssertEqual(session.state, .failed(AppLocalization.string("Gemini Live refused the connection: \(spentQuota.summary)")))
    }

    func testGeminiLiveQuotaSpentMidConversationReconnectsWithoutGoogleSearch() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await settle()
        try XCTUnwrap(sockets().first).deliver(["setupComplete": [String: Any]()])
        await settle()
        XCTAssertEqual(session.state, .ready)

        try XCTUnwrap(sockets().first).serverClose(spentQuota)
        await settle(80)
        XCTAssertEqual(sockets().count, 2)
        XCTAssertFalse(searches(try XCTUnwrap(sockets().last)))
        try XCTUnwrap(sockets().last).deliver(["setupComplete": [String: Any]()])
        await settle()
        XCTAssertEqual(session.state, .ready)
    }

    func testGeminiLiveQuotaRefusedSetupConnectsWithoutGoogleSearch() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await settle()
        try XCTUnwrap(sockets().first).serverClose(spentQuota)
        await settle(80)
        XCTAssertEqual(sockets().count, 2)
        try XCTUnwrap(sockets().last).deliver(["setupComplete": [String: Any]()])
        await settle()
        XCTAssertEqual(session.state, .ready)
    }

    func testGeminiLiveNonQuotaRefusalOnALiveConnectionReconnects() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await settle()
        try XCTUnwrap(sockets().first).deliver(["setupComplete": [String: Any]()])
        await settle()

        try XCTUnwrap(sockets().first).serverClose(.init(code: 1007, reason: "Invalid frame"))
        await settle(80)
        XCTAssertEqual(sockets().count, 2, "a live connection reconnects with resumption")
        XCTAssertTrue(searches(try XCTUnwrap(sockets().last)), "only a spent quota drops Search")
        try XCTUnwrap(sockets().last).deliver(["setupComplete": [String: Any]()])
        await settle()
        XCTAssertEqual(session.state, .ready)
    }

    func testGeminiLiveQuotaRefusalRetriesOnceWithoutGoogleSearch() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await settle()
        let quota = spentQuota
        XCTAssertTrue(searches(try XCTUnwrap(sockets().first)))

        try XCTUnwrap(sockets().first).serverClose(quota)
        await settle(80)
        XCTAssertEqual(sockets().count, 2, "Search's own quota doesn't end the conversation")
        XCTAssertFalse(searches(try XCTUnwrap(sockets().last)))
        if case .failed = session.state { XCTFail("the retry without Search should still be connecting") }

        try XCTUnwrap(sockets().last).serverClose(quota)
        await settle(80)
        XCTAssertEqual(session.state, .failed(AppLocalization.string("Gemini Live refused the connection: \(quota.summary)")))
        XCTAssertEqual(sockets().count, 2, "without Search a quota refusal is final")
    }

    func testGeminiLiveBenignClosesBeforeSetupRetryAndNameTheLastReason() async {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await driveUntilFailed(session) { sockets().last?.serverClose(.init(code: 1001, reason: "going away")) }

        XCTAssertEqual(session.state, .failed(AppLocalization.string("Couldn't connect to Gemini Live: \("going away")")))
        XCTAssertEqual(sockets().count, 1 + GeminiLiveSession.maximumReconnectAttempts)
    }

    func testGeminiLiveDropsBeforeSetupCountTowardTheRetryLimit() async {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await driveUntilFailed(session) { sockets().last?.serverClose(nil) }

        XCTAssertEqual(session.state, .failed(AppLocalization.string("Couldn't connect to Gemini Live.")))
        XCTAssertEqual(sockets().count, 1 + GeminiLiveSession.maximumReconnectAttempts)
    }

    func testGeminiLiveCloseCodesSplitRefusalsFromRetryableCloses() {
        for code in [1003, 1007, 1008, 4003] {
            XCTAssertTrue(GeminiLiveServerClose(code: code, reason: "").isRefusal, "\(code)")
        }
        for code in [1000, 1001, 1005, 1006, 1011] {
            XCTAssertFalse(GeminiLiveServerClose(code: code, reason: "").isRefusal, "\(code)")
        }
        let quota = GeminiLiveServerClose(code: 1011, reason: "You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits.")
        XCTAssertTrue(quota.isRefusal, "retrying an exhausted quota only spends more of it")
        XCTAssertEqual(quota.summary, "You exceeded your current quota, please check your plan and billing details.")
        XCTAssertFalse(GeminiLiveServerClose(code: 1011, reason: "Internal error").isRefusal)
        XCTAssertTrue(GeminiLiveServerClose(code: 403, reason: "", isHTTPStatus: true).isRefusal)
        XCTAssertFalse(GeminiLiveServerClose(code: 429, reason: "", isHTTPStatus: true).isRefusal, "a bare rate limit retries")
        XCTAssertTrue(GeminiLiveServerClose(code: 1011, reason: "RESOURCE_EXHAUSTED").isRefusal)
        XCTAssertTrue(GeminiLiveServerClose(code: 1011, reason: "RESOURCE  EXHAUSTED").isQuotaExhausted)
        XCTAssertTrue(GeminiLiveServerClose(code: 1011, reason: "Resource has been exhausted (e.g. check quota).").isQuotaExhausted)
        XCTAssertEqual(GeminiLiveServerClose(code: 1008, reason: "Error: " + String(repeating: "x", count: 400)).summary.count, 301, "no cut at an early space")
        XCTAssertFalse(GeminiLiveServerClose(code: 1011, reason: "Rate limit exceeded. Your quota will reset in 30s.").isRefusal, "a passing throttle retries")
        XCTAssertEqual(GeminiLiveServerClose(code: 1008, reason: "For more information, see the setup docs").summary, "For more information, see the setup docs")
        let long = GeminiLiveServerClose(code: 1008, reason: String(repeating: "word ", count: 100))
        XCTAssertTrue(long.summary.hasSuffix("word…"), "cut on a word boundary")
        XCTAssertLessThanOrEqual(long.summary.count, 301)
        XCTAssertEqual(GeminiLiveServerClose(code: 1008, reason: String(repeating: "x", count: 400)).summary.count, 301)
        XCTAssertFalse(GeminiLiveServerClose(code: 503, reason: "", isHTTPStatus: true).isRefusal)
        XCTAssertEqual(GeminiLiveServerClose(code: 403, reason: "", isHTTPStatus: true).summary, "HTTP 403")
        XCTAssertEqual(GeminiLiveServerClose(code: 1008, reason: "").summary, AppLocalization.string("close code \(String(1008))"))
    }

    /// Closes each new connection before setup until the session gives up.
    private func driveUntilFailed(_ session: GeminiLiveSession, close: () -> Void) async {
        for _ in 0..<10 {
            await settle(80)
            if case .failed = session.state { return }
            close()
        }
    }

    func testGeminiLiveRefusedUpgradeFailsOnTheFirstAttempt() async {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(
            tokens: tokens,
            upgradeRefusal: .init(code: 403, reason: "", isHTTPStatus: true)
        )
        session.start()
        await settle(80)

        XCTAssertEqual(session.state, .failed(AppLocalization.string("Gemini Live refused the connection: \("HTTP 403")")))
        XCTAssertEqual(sockets().count, 1)
    }

    func testGeminiLiveSessionFailsWithoutRetryWhenTheHostCannotServeIt() async {
        let tokens = FakeGeminiLiveTokens()
        tokens.tokenError = GeminiLiveTokenError.unavailable(.pluginMissing)
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        session.start()
        await settle()
        guard case .failed = session.state else { return XCTFail("Expected failed, got \(session.state)") }
        XCTAssertTrue(sockets().isEmpty)
    }

    private func makeJobs() -> (VoiceBackgroundJobSupervisor, FakeVoiceJobBackend, GeminiLiveToolBridge) {
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        return (supervisor, fake, GeminiLiveToolBridge(supervisor: supervisor))
    }

    func testGeminiLiveStartJobHoldsTheCallAndAnswersItWhenIdleOnceTheJobFinishes() async {
        let (supervisor, fake, bridge) = makeJobs()
        let immediate = await bridge.handle(.init(id: "c1", name: "start_job", arguments: ["instructions": "check the server"]))
        XCTAssertEqual(immediate, [], "A running job keeps its NON_BLOCKING call open")
        XCTAssertEqual(fake.submissions.count, 1)
        XCTAssertEqual(bridge.openCallCount, 1)
        XCTAssertEqual(bridge.pendingUpdates(), [], "Nothing is narrated while the job runs")

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        let updates = bridge.pendingUpdates()
        guard case .toolResponse(let id, let name, let result, let scheduling)? = updates.first, updates.count == 1 else {
            return XCTFail("Expected one tool response, got \(updates)")
        }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(name, "start_job")
        XCTAssertEqual(result["status"], "finished")
        XCTAssertEqual(result["result"], "All green.")
        XCTAssertEqual(scheduling, .whenIdle)
        XCTAssertNil(supervisor.takePendingNotice(), "The result is announced once, on the call")
    }

    func testGeminiLiveCancelJobSettlesOpenCallsSilentlyAndListReportsJobs() async throws {
        let (supervisor, fake, bridge) = makeJobs()
        _ = await bridge.handle(.init(id: "c1", name: "start_job", arguments: ["instructions": "long task"]))
        let list = await bridge.handle(.init(id: "c2", name: "list_jobs", arguments: [:]))
        guard case .toolResponse(_, _, let listed, let listScheduling)? = list.first else { return XCTFail("\(list)") }
        XCTAssertNil(listScheduling, "list_jobs is a BLOCKING answer")
        XCTAssertTrue(listed["job_1"]?.contains("status=running") == true)

        let jobID = try XCTUnwrap(supervisor.jobs.first?.id)
        let cancelled = await bridge.handle(.init(id: "c3", name: "cancel_job", arguments: ["job_id": jobID.uuidString]))
        XCTAssertEqual(fake.cancelled, ["rt-1"])
        XCTAssertEqual(cancelled.count, 2)
        guard case .toolResponse(let settledID, _, let settled, let settledScheduling) = cancelled[1] else { return XCTFail("\(cancelled)") }
        XCTAssertEqual(settledID, "c1")
        XCTAssertEqual(settled["status"], "cancelled")
        XCTAssertEqual(settledScheduling, .silent, "The user just heard the cancel confirmed")
    }

    func testGeminiLiveResultOfAJobWhoseCallWasLostArrivesAsAnIdleTextUpdate() async {
        let (supervisor, _, bridge) = makeJobs()
        _ = await bridge.handle(.init(id: "c1", name: "start_job", arguments: ["instructions": "check the server"]))
        bridge.connectionReplaced()
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        let updates = bridge.pendingUpdates()
        guard case .textWhenIdle(let text)? = updates.first, updates.count == 1 else { return XCTFail("\(updates)") }
        XCTAssertTrue(text.contains("All green."))
    }

    private func makeGeminiController(
        tokens providedTokens: FakeGeminiLiveTokens? = nil,
        route: VoiceBargeInRoutePolicy = .fullDuplex,
        endPhrases: [String] = [],
        clock: @escaping () -> Date
    ) -> (GeminiLiveConversationController, FakeGeminiLiveSessionControl, FakeGeminiLiveInput, FakeGeminiLiveOutput, VoiceBackgroundJobSupervisor) {
        let tokens = providedTokens ?? FakeGeminiLiveTokens()
        let session = FakeGeminiLiveSessionControl()
        let input = FakeGeminiLiveInput()
        let output = FakeGeminiLiveOutput()
        let supervisor = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
        let controller = GeminiLiveConversationController(
            makeSession: { session },
            availability: { try await tokens.availability() },
            tools: GeminiLiveToolBridge(supervisor: supervisor),
            input: input,
            output: output,
            now: clock,
            routePolicy: { route },
            endConversationPhrases: { endPhrases }
        )
        return (controller, session, input, output, supervisor)
    }

    func testGeminiLiveUnavailableHostFailsWithTheReasonAndNeverConnects() async {
        let tokens = FakeGeminiLiveTokens()
        tokens.availabilityResult = .success(.pluginMissing)
        let (controller, session, input, _, _) = makeGeminiController(tokens: tokens, clock: Date.init)
        await controller.start()
        XCTAssertEqual(controller.phase, .failed(GeminiLiveAvailability.pluginMissing.userFacingReason!))
        XCTAssertEqual(session.started, 0)
        XCTAssertFalse(input.running)
    }

    func testGeminiLiveNeverTalksOverTheUser() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let (controller, session, input, output, supervisor) = makeGeminiController(clock: { current })
        await controller.start()
        session.becomeReady()
        XCTAssertTrue(input.running)
        XCTAssertEqual(controller.phase, .listening)

        // The model speaks; the user starts talking: playback stops at once.
        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        XCTAssertEqual(controller.phase, .speaking)
        session.onEvent?(.interrupted)
        XCTAssertEqual(output.interrupts, 1)
        XCTAssertFalse(output.isPlaying)

        // A job update that becomes pending while the user is talking waits.
        session.onEvent?(.inputTranscription("so what I was saying"))
        _ = await supervisor.startJob(instructions: "check the server")
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        controller.deliverPendingJobUpdates()
        controller.flushPendingTextIfIdle()
        XCTAssertTrue(session.textTurns.isEmpty, "Nothing is sent while the user is speaking")
        XCTAssertEqual(controller.pendingTextTurnCountForTesting, 1)

        // Still quiet period right after the model's turn.
        current += GeminiLiveConversationController.userQuietInterval + 0.5
        session.onEvent?(.turnComplete)
        controller.flushPendingTextIfIdle()
        XCTAssertTrue(session.textTurns.isEmpty)

        current += GeminiLiveConversationController.modelQuietInterval + 0.5
        controller.flushPendingTextIfIdle()
        XCTAssertEqual(session.textTurns.count, 1)
        XCTAssertTrue(session.textTurns[0].contains("All green."))
        controller.stop()
        XCTAssertFalse(input.running)
        XCTAssertEqual(session.stopped, 1)
    }

    func testGeminiLiveMuteStopsTheMicrophoneAndEndsTheUsersTurn() async {
        let (controller, session, input, _, _) = makeGeminiController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        input.onChunk?(Data([1, 2]))
        XCTAssertEqual(session.sent.count, 1)

        controller.setMicrophoneMuted(true)
        XCTAssertFalse(input.running)
        XCTAssertEqual((session.sent.last?["realtimeInput"] as? [String: Any])?["audioStreamEnd"] as? Bool, true)
        input.onChunk?(Data([1, 2]))
        XCTAssertEqual(session.sent.count, 2, "Muted audio is never sent")
        controller.stop()
    }
}

// MARK: - Preference

@MainActor
extension ContinuousConversationPreferenceTests {
    func testGeminiLiveIsOffByDefaultAndOlderPreferencesDecodeOff() throws {
        XCTAssertFalse(VoiceProfilePreferences().geminiLiveEnabled)
        let legacy = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data(#"{"outputMuted":true}"#.utf8))
        XCTAssertFalse(legacy.geminiLiveEnabled)
        var enabled = VoiceProfilePreferences()
        enabled.geminiLiveEnabled = true
        let roundTrip = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(roundTrip.geminiLiveEnabled)
    }
}

// MARK: - AppState mode switch

@MainActor
extension AppStateVoiceCapabilityTests {
    private func makeGeminiAppState() -> AppState {
        let suite = "GeminiLiveAppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        // Hermes' own speech pipeline is unavailable on this profile.
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(isGatewayConnected: true, supportsTranscription: false, supportsSpeech: false, unavailableReason: "No STT"),
            isVoiceEnabled: false,
            transcriptionMode: .hermes,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US")
        )
        return appState
    }

    func testGeminiLiveModeOpensItsOwnSheetInsteadOfTheClassicConversation() async {
        let appState = makeGeminiAppState()
        XCTAssertFalse(appState.isGeminiLiveEnabled, "Off by default")
        XCTAssertFalse(appState.canStartVoiceConversation)

        appState.setGeminiLiveEnabled(true)
        XCTAssertNil(appState.phoneVoiceUnavailableReason, "Gemini Live does not need Hermes speech providers")
        XCTAssertTrue(appState.canStartPhoneVoiceConversation)
        XCTAssertNotNil(appState.voiceUnavailableReason, "Classic-only surfaces (CarPlay, restore) keep the classic checks")
        XCTAssertFalse(appState.canStartVoiceConversation)
        XCTAssertTrue(appState.showsComposerVoiceButton)

        let opened = await appState.openVoiceConversation(
            PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(opened)
        XCTAssertTrue(appState.showGeminiLiveSheet)
        XCTAssertFalse(appState.showVoiceSheet, "The two voice modes never run at once")

        appState.setGeminiLiveEnabled(false)
        XCTAssertFalse(appState.showGeminiLiveSheet, "Turning the mode off closes it")
    }

    func testDisconnectClosesGeminiLive() async {
        let appState = makeGeminiAppState()
        appState.setGeminiLiveEnabled(true)
        _ = await appState.openVoiceConversation(
            PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(appState.showGeminiLiveSheet)

        appState.disconnect()

        XCTAssertFalse(appState.showGeminiLiveSheet)
        XCTAssertFalse(appState.geminiLiveController.isActive)
    }
}

// MARK: - Speaker echo, acknowledgement, voice-job model

@MainActor
extension VoiceConversationControllerTests {
    func testGeminiLiveHoldsTheMicOnTheSpeakerWhileItTalksButNotOnAHeadset() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let (controller, session, input, output, _) = makeGeminiController(route: .speakerSafeHalfDuplex, clock: { current })
        await controller.start()
        session.becomeReady()
        input.onChunk?(Data([1]))
        XCTAssertEqual(session.sent.count, 1, "The mic streams while nobody is speaking")

        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        input.onChunk?(Data([1]))
        XCTAssertEqual(session.sent.count, 1, "The speaker's own voice must never reach Gemini as barge-in")

        // Turn over, playback drained: the echo tail still holds the mic briefly.
        session.onEvent?(.turnComplete)
        output.isPlaying = false
        _ = controller.isMicrophoneGatedForSpeaker
        current += GeminiLiveConversationController.speakerEchoTail / 2
        input.onChunk?(Data([1]))
        XCTAssertEqual(session.sent.count, 1)
        current += GeminiLiveConversationController.speakerEchoTail
        input.onChunk?(Data([1]))
        XCTAssertEqual(session.sent.count, 2)

        // Interrupt is how the user cuts in on the speaker.
        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        controller.interruptSpeaking()
        XCTAssertFalse(output.isPlaying)
        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        XCTAssertFalse(output.isPlaying, "The rest of an interrupted turn is dropped")
        input.onChunk?(Data([1]))
        XCTAssertEqual(session.sent.count, 3)
        controller.stop()
    }

    func testGeminiLiveHeadsetStaysFullDuplex() async {
        let (controller, session, input, _, _) = makeGeminiController(route: .fullDuplex, clock: Date.init)
        await controller.start()
        session.becomeReady()
        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        input.onChunk?(Data([1]))
        XCTAssertEqual(session.sent.count, 1, "With a headset the user can barge in by voice")
        controller.stop()
    }

    func testGeminiLivePromptsAnAcknowledgementOnlyWhenTheModelStayedSilent() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let (controller, session, _, _, _) = makeGeminiController(clock: { current })
        await controller.start()
        session.becomeReady()

        let calledAt = current
        current += 5
        controller.acknowledgeIfSilent(since: calledAt)
        XCTAssertEqual(session.textTurns, [GeminiLiveConversationController.acknowledgementPrompt])

        // The model spoke after the call: no prompt.
        session.onEvent?(.turnComplete)
        let secondCall = current
        current += 0.2
        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        session.onEvent?(.turnComplete)
        current += 5
        controller.acknowledgeIfSilent(since: secondCall)
        XCTAssertEqual(session.textTurns.count, 1)

        // The model acknowledged before calling, right after the user's
        // request: no second prompt.
        session.onEvent?(.inputTranscription("What's on my calendar?"))
        let requestedAt = current
        current += 0.5
        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        session.onEvent?(.turnComplete)
        current += 5
        controller.acknowledgeIfSilent(since: requestedAt)
        XCTAssertEqual(session.textTurns.count, 1)
        controller.stop()
    }

    func testGeminiLiveKeepsATextUpdateWhoseSendFailed() async {
        let (controller, session, _, _, _) = makeGeminiController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        session.failSends = true

        controller.acknowledgeIfSilent(since: .distantPast)

        XCTAssertEqual(session.textTurns, [GeminiLiveConversationController.acknowledgementPrompt], "the send was attempted")
        XCTAssertEqual(controller.pendingTextTurnCountForTesting, 1, "and the update waits for the next connection")
        controller.stop()
    }

    func testGeminiLiveOutgoingAnswersOnlyItsOwnCall() {
        let response = GeminiLiveToolBridge.Outgoing.toolResponse(id: "c2", name: "start_job", result: [:], scheduling: .whenIdle)
        XCTAssertTrue(response.answers("c2"))
        XCTAssertFalse(response.answers("c1"), "another job settling in the same batch is not this call's answer")
        XCTAssertFalse(GeminiLiveToolBridge.Outgoing.textWhenIdle("x").answers("c1"))
    }

    func testVoiceJobsUseTheirOwnModelAndReasoningWhenChosen() {
        var preferences = VoiceProfilePreferences()
        let fallback = preferences.voiceJobSessionOptions(runtimeModel: "big-model", runtimeProvider: "anthropic")
        XCTAssertEqual(fallback.model, "big-model")
        XCTAssertEqual(fallback.provider, "anthropic")
        XCTAssertNil(fallback.reasoningEffort)

        preferences.voiceJobReasoningEffort = "low"
        XCTAssertEqual(preferences.voiceJobSessionOptions(runtimeModel: "big-model", runtimeProvider: "anthropic").reasoningEffort, "low")

        preferences.voiceJobModel = "fast-model"
        preferences.voiceJobProvider = "openrouter"
        let chosen = preferences.voiceJobSessionOptions(runtimeModel: "big-model", runtimeProvider: "anthropic")
        XCTAssertEqual(chosen.model, "fast-model")
        XCTAssertEqual(chosen.provider, "openrouter")
        XCTAssertEqual(chosen.reasoningEffort, "low")

        let decoded = try? JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded?.voiceJobModel, "fast-model")
        XCTAssertEqual(decoded?.voiceJobReasoningEffort, "low")
        XCTAssertEqual(VoiceJobModelSettingsSection.parse(VoiceJobModelSettingsSection.tag(provider: "openrouter", model: "a/b")).model, "a/b")
    }
}

// MARK: - Review round: delivery only on a live connection, races

@MainActor
extension VoiceConversationControllerTests {
    func testGeminiLiveNeverSettlesAJobWhileTheConnectionCannotSendIt() async {
        let (controller, session, _, _, supervisor) = makeGeminiController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        session.onEvent?(.toolCall([.init(id: "c1", name: "start_job", arguments: ["instructions": "check the server"])]))
        await settle(40)
        XCTAssertEqual(supervisor.jobs.count, 1)

        // The job finishes while the connection is being replaced.
        session.isReady = false
        session.onStateChange?(.reconnecting)
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        controller.deliverPendingJobUpdates()
        XCTAssertTrue(session.sent.isEmpty, "Nothing can go out while reconnecting")
        XCTAssertFalse(supervisor.jobs[0].outcomeDelivered, "The outcome must not be marked delivered unsent")

        // Back on a (same-connection) ready session: answered on the call.
        session.becomeReady()
        let response = session.sent.compactMap { ($0["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]] }.first?.first
        XCTAssertEqual(response?["id"] as? String, "c1")
        XCTAssertEqual((response?["response"] as? [String: Any])?["result"] as? String, "All green.")
        XCTAssertTrue(supervisor.jobs[0].outcomeDelivered)
        controller.stop()
    }

    func testGeminiLiveKeepsAJobResultWhoseToolResponseFailedToSend() async {
        let (controller, session, _, _, supervisor) = makeGeminiController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        session.onEvent?(.toolCall([.init(id: "c1", name: "start_job", arguments: ["instructions": "check the server"])]))
        await settle(40)
        XCTAssertEqual(supervisor.jobs.count, 1)

        session.failSends = true
        let before = controller.pendingTextTurnCountForTesting
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        controller.deliverPendingJobUpdates()
        XCTAssertEqual(controller.pendingTextTurnCountForTesting, before + 1, "the result waits as a text update")
        controller.stop()
    }

    func testGeminiLiveResumeDropsOldCallsBeforeAnnouncingReady() async throws {
        let tokens = FakeGeminiLiveTokens()
        let (session, sockets) = makeGeminiSession(tokens: tokens)
        var events: [String] = []
        session.onConnectionReplaced = { events.append("replaced") }
        session.onStateChange = { if $0 == .ready { events.append("ready") } }
        session.start()
        await settle()
        try XCTUnwrap(sockets().first).deliver(["setupComplete": [String: Any]()])
        await settle()
        sockets()[0].deliver(["goAway": ["timeLeft": "5s"]])
        await settle(40)
        sockets()[1].deliver(["setupComplete": [String: Any]()])
        await settle()
        XCTAssertEqual(events, ["ready", "replaced", "ready"])
        session.stop()
    }

    func testGeminiLiveWithdrawnWhileStartingIsNotAnsweredOnTheCall() async {
        let fake = FakeVoiceJobBackend()
        fake.parksCreate = true
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        let bridge = GeminiLiveToolBridge(supervisor: supervisor)
        let handling = Task { await bridge.handle(.init(id: "c1", name: "start_job", arguments: ["instructions": "long task"])) }
        await fake.createParked.waitUntil(1)
        bridge.cancelCalls(["c1"])
        fake.releaseCreate()
        let immediate = await handling.value
        XCTAssertEqual(immediate, [])
        XCTAssertEqual(bridge.openCallCount, 0, "A withdrawn call is never answered later")

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Done.", reasoning: nil))
        guard case .textWhenIdle(let text)? = bridge.pendingUpdates().first else { return XCTFail("Expected a text update") }
        XCTAssertTrue(text.contains("Done."))
    }

    func testGeminiLiveJobThatSettlesWhileStartingIsAnsweredWithItsResult() async {
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        fake.onSubmit = { id in
            supervisor.observe(.messageComplete(sessionId: id, messageId: nil, content: "Quick answer.", reasoning: nil))
        }
        let bridge = GeminiLiveToolBridge(supervisor: supervisor)
        let outgoing = await bridge.handle(.init(id: "c1", name: "start_job", arguments: ["instructions": "quick one"]))
        guard case .toolResponse(let id, _, let result, let scheduling)? = outgoing.first else { return XCTFail("\(outgoing)") }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(result["result"], "Quick answer.")
        XCTAssertEqual(scheduling, .whenIdle)
    }

    func testGeminiLiveFailedStartIsToldNotSilenced() async {
        let fake = FakeVoiceJobBackend()
        fake.createError = URLError(.notConnectedToInternet)
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        let bridge = GeminiLiveToolBridge(supervisor: supervisor)
        let outgoing = await bridge.handle(.init(id: "c1", name: "start_job", arguments: ["instructions": "anything"]))
        guard case .toolResponse(_, _, let result, let scheduling)? = outgoing.first else { return XCTFail("\(outgoing)") }
        XCTAssertEqual(result["status"], "failed")
        XCTAssertEqual(scheduling, .whenIdle, "The model must be able to tell the user the start failed")
    }

    func testGeminiLiveRestartsTheMicAfterAnAudioInterruption() async {
        let (controller, session, input, _, _) = makeGeminiController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        XCTAssertEqual(input.starts, 1)
        input.stop()
        input.onInterrupted?()
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(input.running, "Capture comes back after the interruption")
        XCTAssertEqual(input.starts, 2)
        controller.stop()
    }
}

// MARK: - Web lookups

@MainActor
final class FakeGeminiLiveWebSearch: GeminiLiveWebSearching {
    var results: [GeminiLiveWebResult] = []
    var error: Error?
    private(set) var queries: [String] = []

    func webSearch(query: String) async throws -> [GeminiLiveWebResult] {
        queries.append(query)
        if let error { throw error }
        return results
    }
}

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testGeminiLiveSearchModeResolvesAutomaticToHermesOnlyWhenTheHostHasSearch() {
        XCTAssertEqual(GeminiLiveSearchMode.automatic.resolved(hermesAvailable: true), .hermes)
        XCTAssertEqual(GeminiLiveSearchMode.automatic.resolved(hermesAvailable: false), .google)
        XCTAssertEqual(GeminiLiveSearchMode.hermes.resolved(hermesAvailable: false), .hermes)
        XCTAssertEqual(GeminiLiveSearchMode.google.resolved(hermesAvailable: true), .google)
        XCTAssertEqual(GeminiLiveSearchMode.off.resolved(hermesAvailable: true), GeminiLiveSearchSource.none)
    }

    func testGeminiLiveSearchPreferenceDecodesMissingOrUnknownModesAsAutomatic() throws {
        let missing = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data(#"{"geminiLiveEnabled":true}"#.utf8))
        XCTAssertNil(missing.geminiLiveSearch)
        XCTAssertTrue(missing.geminiLiveEnabled)
        let unknown = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data(#"{"geminiLiveEnabled":true,"geminiLiveSearch":"bing"}"#.utf8))
        XCTAssertNil(unknown.geminiLiveSearch, "a newer build's mode must not fail the whole blob")
        XCTAssertTrue(unknown.geminiLiveEnabled)
        var preferences = VoiceProfilePreferences()
        preferences.geminiLiveSearch = .hermes
        let roundTrip = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(roundTrip.geminiLiveSearch, .hermes)
    }

    func testGeminiLiveHermesSearchDeclaresABlockingWebSearchInsteadOfGoogleSearch() throws {
        let declarations = GeminiLiveToolBridge.declarations(webSearch: true)
        let setup = try XCTUnwrap(GeminiLiveProtocol.setupMessage(
            systemInstruction: GeminiLiveConversationController.instructions(search: .hermes),
            functions: declarations,
            googleSearch: false,
            resumptionHandle: nil
        )["setup"] as? [String: Any])
        let tools = try XCTUnwrap(setup["tools"] as? [[String: Any]])
        XCTAssertFalse(tools.contains { $0["googleSearch"] != nil })
        let functions = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(functions.first { $0["name"] as? String == "web_search" }?["behavior"] as? String, "BLOCKING")
        XCTAssertFalse(GeminiLiveToolBridge.declarations(webSearch: false).contains { $0.name == "web_search" })
        XCTAssertTrue(GeminiLiveConversationController.instructions(search: .hermes).contains("web_search"))
        XCTAssertTrue(GeminiLiveConversationController.instructions(search: .google).contains("Google Search"))
        XCTAssertFalse(GeminiLiveConversationController.instructions(search: .none).contains("Google Search"))
    }

    func testGeminiLiveSessionWithoutGoogleSearchNeverAsksForIt() async throws {
        let tokens = FakeGeminiLiveTokens()
        var sockets: [FakeGeminiLiveSocket] = []
        let session = GeminiLiveSession(
            tokens: tokens,
            systemInstruction: "test",
            functions: GeminiLiveToolBridge.declarations(webSearch: true),
            googleSearch: false,
            openSocket: { url in
                let socket = FakeGeminiLiveSocket(url: url)
                sockets.append(socket)
                return socket
            },
            reconnectDelay: { _ in }
        )
        session.start()
        await settle()
        let setup = try XCTUnwrap(sockets.first?.sent.first?["setup"] as? [String: Any])
        XCTAssertFalse((setup["tools"] as? [[String: Any]] ?? []).contains { $0["googleSearch"] != nil })

        // With no Search to drop, a spent quota is final.
        try XCTUnwrap(sockets.first).serverClose(.init(code: 1011, reason: "You exceeded your current quota, please check your plan and billing details."))
        await settle(80)
        XCTAssertEqual(sockets.count, 1)
        guard case .failed = session.state else { return XCTFail("Expected failed, got \(session.state)") }
    }

    func testGeminiLiveWebSearchAnswersFromTheHostsResults() async {
        let (supervisor, backend) = makeJobsForSearch()
        defer { withExtendedLifetime(backend) {} }
        let search = FakeGeminiLiveWebSearch()
        search.results = [
            GeminiLiveWebResult(title: "Toronto weather", url: "https://example.com/w", snippet: "Sunny, 21°C"),
            GeminiLiveWebResult(title: "Forecast", url: "https://example.com/f", snippet: "Rain tomorrow"),
        ]
        let bridge = GeminiLiveToolBridge(supervisor: supervisor, webSearch: search)

        let answer = await bridge.handle(.init(id: "s1", name: "web_search", arguments: ["query": "  weather in Toronto "]))

        XCTAssertEqual(search.queries, ["weather in Toronto"])
        XCTAssertEqual(answer, [.toolResponse(
            id: "s1",
            name: "web_search",
            result: ["results": "1. Toronto weather: Sunny, 21°C (https://example.com/w)\n2. Forecast: Rain tomorrow (https://example.com/f)"],
            scheduling: nil
        )])
    }

    func testGeminiLiveWebSearchReportsFailuresToTheModel() async {
        let (supervisor, backend) = makeJobsForSearch()
        defer { withExtendedLifetime(backend) {} }
        let search = FakeGeminiLiveWebSearch()
        search.error = DashboardTicketBridgeError.requestFailed("No web search provider configured.")
        let bridge = GeminiLiveToolBridge(supervisor: supervisor, webSearch: search)

        let failed = await bridge.handle(.init(id: "s1", name: "web_search", arguments: ["query": "news"]))
        guard case .toolResponse(_, _, let result, let scheduling) = failed.first else { return XCTFail("Expected a response") }
        XCTAssertNotNil(result["error"])
        XCTAssertNil(scheduling)

        let empty = await bridge.handle(.init(id: "s2", name: "web_search", arguments: [:]))
        XCTAssertEqual(empty, [.toolResponse(id: "s2", name: "web_search", result: ["error": "query is required"], scheduling: nil)])
        XCTAssertEqual(search.queries, ["news"])

        let unwired = await GeminiLiveToolBridge(supervisor: supervisor).handle(.init(id: "s3", name: "web_search", arguments: ["query": "news"]))
        XCTAssertEqual(unwired, [.toolResponse(id: "s3", name: "web_search", result: ["error": "web search is not available"], scheduling: nil)])
    }

    func testGeminiLiveWebSearchClientParsesResultsAndRequestsTheProfilesBackend() async throws {
        var requests: [(String, String, [String: Any]?)] = []
        let client = GeminiLiveTokenClient(profile: { "work" }, request: { path, method, body in
            requests.append((path, method, body))
            if path.contains("/web-search/status") { return ["ok": true, "available": true, "backend": "searxng"] }
            return ["ok": true, "query": "news", "results": [
                ["title": "A", "url": "https://a.example", "snippet": "first"],
                ["title": "no url"],
            ]]
        })

        let available = await client.webSearchAvailable()
        let results = try await client.webSearch(query: "news")

        XCTAssertTrue(available)
        XCTAssertEqual(results, [GeminiLiveWebResult(title: "A", url: "https://a.example", snippet: "first")])
        XCTAssertEqual(requests.map(\.1), ["GET", "POST"])
        XCTAssertTrue(requests.allSatisfy { $0.0.contains("profile=work") })
        XCTAssertEqual(requests.last?.2?["query"] as? String, "news")

        XCTAssertThrowsError(try GeminiLiveTokenClient.webResults(from: ["ok": false, "detail": "No web search provider configured."])) { error in
            XCTAssertEqual(error.localizedDescription, "No web search provider configured.")
        }

        let older = GeminiLiveTokenClient(request: { _, _, _ in throw DashboardTicketBridgeError.http(status: 404, detail: "") })
        let olderAvailable = await older.webSearchAvailable()
        XCTAssertFalse(olderAvailable, "a plugin without the route means no Hermes search")
    }

    private func makeJobsForSearch() -> (VoiceBackgroundJobSupervisor, FakeVoiceJobBackend) {
        let fake = FakeVoiceJobBackend()
        return (VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600)), fake)
    }
}

// MARK: - Transcript joins and voice

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testGeminiLiveTranscriptJoinRestoresTheSpaceGeminiDropsBetweenChunks() {
        let join = GeminiLiveConversationController.joinTranscriptChunk
        XCTAssertEqual(join("Could you", "please"), "Could you please")
        XCTAssertEqual(join("It was", "released"), "It was released")
        XCTAssertEqual(join("It's in", "Chesapeake"), "It's in Chesapeake")
        XCTAssertEqual(join("Sure.", "Here"), "Sure. Here")
        // Chunks that already carry their space are left alone.
        XCTAssertEqual(join("Could you", " please"), "Could you please")
        XCTAssertEqual(join("Could you ", "please"), "Could you please")
        // Punctuation and contractions attach to the word before them.
        XCTAssertEqual(join("those tools", "."), "those tools.")
        XCTAssertEqual(join("that", "'s"), "that's")
        XCTAssertEqual(join("version 3.", "5"), "version 3.5")
        // Scripts written without spaces are joined as they are.
        XCTAssertEqual(join("今天", "天气"), "今天天气")
        XCTAssertEqual(join("", "Hello"), "Hello")
    }

    func testGeminiLiveSetupSendsTheChosenVoiceAndOmitsItForTheDefault() throws {
        let chosen = try XCTUnwrap(GeminiLiveProtocol.setupMessage(
            systemInstruction: "", functions: [], voice: "Kore", resumptionHandle: nil
        )["setup"] as? [String: Any])
        let config = try XCTUnwrap(chosen["generationConfig"] as? [String: Any])
        let speech = try XCTUnwrap(config["speechConfig"] as? [String: Any])
        let voice = try XCTUnwrap(speech["voiceConfig"] as? [String: Any])
        let prebuilt = try XCTUnwrap(voice["prebuiltVoiceConfig"] as? [String: Any])
        XCTAssertEqual(prebuilt["voiceName"] as? String, "Kore")
        XCTAssertEqual(config["responseModalities"] as? [String], ["AUDIO"])

        let standard = try XCTUnwrap(GeminiLiveProtocol.setupMessage(
            systemInstruction: "", functions: [], resumptionHandle: nil
        )["setup"] as? [String: Any])
        XCTAssertNil((standard["generationConfig"] as? [String: Any])?["speechConfig"])
    }

    func testGeminiLiveVoicePreferenceRoundTripsAndDefaultsToGemini() throws {
        let missing = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data(#"{"geminiLiveEnabled":true}"#.utf8))
        XCTAssertNil(missing.geminiLiveVoice)
        var preferences = VoiceProfilePreferences()
        preferences.geminiLiveVoice = "Puck"
        let roundTrip = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(roundTrip.geminiLiveVoice, "Puck")
        XCTAssertEqual(Set(GeminiLiveVoice.all.map(\.name)).count, GeminiLiveVoice.all.count)
    }
}

// MARK: - Hands-free end

/// Counts onEndConversation calls (a main-actor closure is Sendable, so it
/// can't mutate a captured local).
@MainActor
private final class EndCounter {
    var count = 0
}

@MainActor
extension VoiceConversationControllerTests {
    func testGeminiLiveEndConversationCallClosesAfterTheGoodbyePlays() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let (controller, session, input, output, _) = makeGeminiController(clock: { current })
        let closed = EndCounter()
        controller.onEndConversation = { closed.count += 1 }
        await controller.start()
        session.becomeReady()

        // The model says goodbye, then calls end_conversation.
        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        session.onEvent?(.toolCall([.init(id: "e1", name: "end_conversation", arguments: [:])]))
        await settle(40)
        XCTAssertTrue(controller.isEnding)
        XCTAssertFalse(input.running, "the microphone closes as soon as the end is asked for")
        XCTAssertTrue(session.sent.isEmpty, "the call is left unanswered so no new turn starts")

        // Still playing the goodbye: nothing closes yet.
        current += GeminiLiveConversationController.endGrace + 0.5
        XCTAssertFalse(controller.finishEndIfDrained())
        XCTAssertEqual(closed.count, 0)

        // The goodbye finishes: the conversation closes.
        session.onEvent?(.turnComplete)
        output.isPlaying = false
        XCTAssertTrue(controller.finishEndIfDrained())
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(session.stopped, 1)
    }

    func testGeminiLiveEndClosesAfterTheTimeoutEvenIfTheModelKeepsTalking() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let (controller, session, _, _, _) = makeGeminiController(clock: { current })
        let closed = EndCounter()
        controller.onEndConversation = { closed.count += 1 }
        await controller.start()
        session.becomeReady()
        session.onEvent?(.audio(Data([0, 0]), sampleRate: 24_000))
        controller.requestEnd()
        current += GeminiLiveConversationController.endTimeout + 0.1
        XCTAssertTrue(controller.finishEndIfDrained())
        XCTAssertEqual(closed.count, 1)
    }

    func testGeminiLiveUsersGoodbyePhraseEndsTheConversation() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let (controller, session, input, _, _) = makeGeminiController(endPhrases: ["goodbye", "that's all"], clock: { current })
        let closed = EndCounter()
        controller.onEndConversation = { closed.count += 1 }
        await controller.start()
        session.becomeReady()

        // Not an end phrase on its own: the conversation carries on.
        session.onEvent?(.inputTranscription("goodbye to the old server"))
        session.onEvent?(.outputTranscription("Got it."))
        session.onEvent?(.turnComplete)
        XCTAssertFalse(controller.isEnding)

        // The whole utterance is an end phrase: the model's reply closes it.
        session.onEvent?(.inputTranscription("That's all."))
        XCTAssertFalse(controller.isEnding, "the utterance may still be going")
        session.onEvent?(.outputTranscription("Bye!"))
        XCTAssertTrue(controller.isEnding)
        XCTAssertFalse(input.running)
        session.onEvent?(.turnComplete)
        current += GeminiLiveConversationController.endGrace + 0.1
        XCTAssertTrue(controller.finishEndIfDrained())
        XCTAssertEqual(closed.count, 1)
    }

    func testGeminiLiveEndingHoldsJobUpdatesAndKeepsTheMicrophoneClosed() async {
        let (controller, session, input, _, supervisor) = makeGeminiController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        _ = await supervisor.startJob(instructions: "check the server")
        controller.requestEnd()
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        controller.deliverPendingJobUpdates()
        XCTAssertEqual(controller.pendingTextTurnCountForTesting, 0)
        XCTAssertFalse(supervisor.jobs[0].outcomeDelivered, "the result stays pending for Hermes to report")
        controller.setMicrophoneMuted(true)
        controller.setMicrophoneMuted(false)
        XCTAssertFalse(input.running)
        controller.stop()
    }
}

// MARK: - CarPlay

@MainActor
extension VoiceConversationControllerTests {
    func testCarPlayShowsTheGeminiLivePhase() {
        XCTAssertEqual(CarPlayVoiceState.map(GeminiLiveConversationController.Phase.idle), .ready)
        XCTAssertEqual(CarPlayVoiceState.map(GeminiLiveConversationController.Phase.connecting), .processing)
        XCTAssertEqual(CarPlayVoiceState.map(GeminiLiveConversationController.Phase.reconnecting), .processing)
        XCTAssertEqual(CarPlayVoiceState.map(GeminiLiveConversationController.Phase.listening), .listening)
        XCTAssertEqual(CarPlayVoiceState.map(GeminiLiveConversationController.Phase.speaking), .responding)
        XCTAssertEqual(CarPlayVoiceState.map(GeminiLiveConversationController.Phase.failed("x")), .error)
    }

    func testCarPlayListenStartsInterruptsOrLeavesGeminiLiveAlone() {
        XCTAssertEqual(CarPlayGeminiLiveListenAction.forPhase(.idle), .start)
        XCTAssertEqual(CarPlayGeminiLiveListenAction.forPhase(.failed("x")), .start)
        XCTAssertEqual(CarPlayGeminiLiveListenAction.forPhase(.speaking), .interrupt)
        XCTAssertEqual(CarPlayGeminiLiveListenAction.forPhase(.listening), .nothing)
        XCTAssertEqual(CarPlayGeminiLiveListenAction.forPhase(.connecting), .nothing)
    }
}
