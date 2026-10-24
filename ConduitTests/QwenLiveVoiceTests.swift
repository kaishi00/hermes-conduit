import XCTest
@testable import Conduit

@MainActor
private final class QwenTestSocket: GeminiLiveSocket {
    var frames: [[String: Any]] = []
    var sent: [[String: Any]] = []
    func send(_ text: String) async throws {
        sent.append(try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }
    func receive() async throws -> Data {
        guard !frames.isEmpty else { throw QwenLiveError.invalidFrame }
        return try JSONSerialization.data(withJSONObject: frames.removeFirst())
    }
    func close() {}
}

@MainActor
private final class QwenTestTokens: GeminiLiveTokenProviding {
    let directProvider: DirectLiveProvider = .qwen
    let value = GeminiLiveToken(token: "st-test", expiresAt: nil, newSessionExpiresAt: nil,
        model: "qwen3.8-omni-flash-realtime",
        webSocketURL: URL(string: "wss://workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime")!, provider: .qwen)
    func availability() async throws -> GeminiLiveAvailability { .available(model: value.model) }
    func freshToken() async throws -> GeminiLiveToken { value }
}

// Keep these in the existing direct-session CI lane.
extension HermesVoiceGatewayTimeoutTests {
    @MainActor
    func testQwenUsesInjectedSocketFactoryWithAuthorizationHeader() async throws {
        var captured: URLRequest?
        let session = GeminiLiveSession(tokens: QwenTestTokens(), systemInstruction: "Test", functions: [],
            openSocket: { request in
                captured = request
                return FakeGeminiLiveSocket(url: request.url!)
            })
        defer { session.stop() }
        session.start()
        let deadline = ContinuousClock.now + .seconds(2)
        while captured == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer st-test")
        XCTAssertFalse(request.url!.absoluteString.contains("access_token"))
    }

    @MainActor
    func testQwenFailureMessagesAndWireIdentityDoNotFallBackToGemini() throws {
        let missing = GeminiLiveAvailability.unavailable(reason: "no_api_key")
        XCTAssertEqual(missing.userFacingReason(for: .qwen), AppLocalization.string("Add a DashScope API key on your Hermes server."))
        let close = GeminiLiveServerClose(code: 401, reason: "refused", isHTTPStatus: true)
        XCTAssertEqual(GeminiLiveSession.refusalMessage(close, provider: .qwen),
            AppLocalization.string("Qwen Live refused the connection: \(close.summary)"))
        var wire = WatchVoiceWire.DirectToken(QwenTestTokens().value)
        XCTAssertEqual(wire.provider, .qwen)
        XCTAssertEqual(wire.geminiToken?.effectiveProvider, .qwen)
        wire.model = ""
        XCTAssertNil(wire.geminiToken)
        wire.model = "gemini-test"
        XCTAssertNil(wire.geminiToken)
    }

    @MainActor
    func testQwenIsAnIndependentPickerAndHistoryIdentity() {
        XCTAssertEqual(VoiceModeChoice(engine: .qwenLive), .qwen)
        XCTAssertEqual(VoiceModeChoice(engine: .geminiLive), .gemini)
        XCTAssertEqual(VoiceCallEngine.qwenLive.rawValue, "qwen-live")
        XCTAssertEqual(VoiceCallEngine.watchBridge("qwen-live"), .qwenLive)
        XCTAssertNotEqual(LiveVoiceProviderConsent.key(for: .qwenLive), LiveVoiceProviderConsent.key(for: .geminiLive))
    }

    func testQwenPreferencesDoNotOverwriteGeminiPreferences() throws {
        var preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(preferences.qwenLiveEnabled)
        preferences.geminiLiveVoice = "Kore"
        preferences.geminiLiveMemory = true
        preferences.qwenLiveVoice = "Tina"
        preferences.qwenLiveMemory = false
        let decoded = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.geminiLiveVoice, "Kore")
        XCTAssertEqual(decoded.qwenLiveVoice, "Tina")
        XCTAssertEqual(decoded.geminiLiveMemory, true)
        XCTAssertEqual(decoded.qwenLiveMemory, false)
    }

    @MainActor
    func testEachDirectProviderUsesItsOwnCredentialRoutes() async throws {
        for provider in [DirectLiveProvider.gemini, .qwen] {
            var paths: [String] = []
            let client = GeminiLiveTokenClient(profile: { "work" }, provider: { provider }, request: { path, _, _, _ in
                paths.append(path)
                if path.contains("/status") { return ["ok": true, "available": true, "model": provider == .qwen ? "qwen-test" : "gemini-test"] }
                return ["ok": true, "model": provider == .qwen ? "qwen-test" : "gemini-test",
                        "token": provider == .qwen ? "st-test" : "google-test",
                        "websocket_url": provider == .qwen ? "wss://workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime" : "wss://generativelanguage.googleapis.com/ws/live"]
            })
            _ = try await client.availability()
            _ = try await client.freshToken()
            let prefix = "/api/plugins/conduit_push/" + (provider == .qwen ? "qwen-live" : "gemini-live")
            XCTAssertEqual(paths, [prefix + "/status?profile=work", prefix + "/token?profile=work"])
        }
    }

    func testWatchStartCarriesExplicitProvider() throws {
        let qwen = WatchVoiceWire.Message.directStart(callID: 9, version: WatchVoiceWire.version, provider: .qwen)
        let gemini = WatchVoiceWire.Message.directStart(callID: 9, version: WatchVoiceWire.version)
        XCTAssertNotEqual(qwen, gemini)
        XCTAssertEqual(WatchVoiceWire.decode(WatchVoiceWire.encode(qwen)), qwen)
        XCTAssertEqual(WatchVoiceWire.decode(WatchVoiceWire.encode(gemini)), gemini)
    }

    @MainActor
    func testQwenVoiceDefaultsForMissingOrBlankNames() {
        var token = GeminiLiveToken(token: "st-test", expiresAt: nil, newSessionExpiresAt: nil,
            model: "qwen3.8-omni-flash-realtime",
            webSocketURL: URL(string: "wss://workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime")!)
        let voices: [String?] = [nil, "", " \n\t"]
        for voice in voices {
            token.voice = voice
            XCTAssertEqual(token.qwenVoice, "Tina")
        }
        token.voice = "Serena"
        XCTAssertEqual(token.qwenVoice, "Serena")
    }

    @MainActor
    func testPreQwenWatchIsRefusedBeforeReceivingCredentials() {
        let broker = WatchDirectBroker(link: WatchVoiceLink.shared)
        var reply: WatchVoiceWire.Message?
        broker.handle(.directStart(callID: 71, version: 2), reply: { reply = WatchVoiceWire.decode($0) })
        guard case .callRefused(let id, let reason)? = reply else { return XCTFail("Old Watch must be refused") }
        XCTAssertEqual(id, 71)
        XCTAssertEqual(reason, WatchVoiceStartFailure.versionMismatch)
    }

    @MainActor
    func testGoogleOnlyConsentDoesNotAuthorizeQwen() throws {
        let name = "qwen-consent-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "conduit.liveVoiceProviderConsent.gemini-live")
        XCTAssertTrue(LiveVoiceProviderConsent.isGranted(.geminiLive, defaults: defaults))
        XCTAssertFalse(LiveVoiceProviderConsent.isGranted(.qwenLive, defaults: defaults))
        LiveVoiceProviderConsent.setGranted(true, for: .qwenLive, defaults: defaults)
        XCTAssertTrue(LiveVoiceProviderConsent.isGranted(.qwenLive, defaults: defaults))
        LiveVoiceProviderConsent.setGranted(false, for: .qwenLive, defaults: defaults)
        XCTAssertTrue(LiveVoiceProviderConsent.isGranted(.geminiLive, defaults: defaults))
    }

    @MainActor
    func testQwenCredentialSurvivesWatchWireWithoutPermanentKey() throws {
        let token = GeminiLiveToken(token: "st-watch", expiresAt: nil, newSessionExpiresAt: nil,
            model: "qwen3.8-omni-flash-realtime",
            webSocketURL: URL(string: "wss://workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime")!, voice: "Tina")
        let wire = WatchVoiceWire.DirectToken(token)
        let encoded = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(WatchVoiceWire.DirectToken.self, from: encoded)
        XCTAssertEqual(decoded.geminiToken, token)
    }

    @MainActor
    func testQwenCredentialUsesBearerAndNeverURLQuery() throws {
        let token = GeminiLiveToken(token: "st-test", expiresAt: nil, newSessionExpiresAt: nil,
            model: "qwen3.8-omni-flash-realtime",
            webSocketURL: URL(string: "wss://workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen3.8-omni-flash-realtime")!)
        let request = try QwenLiveSocket.request(token: token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer st-test")
        XCTAssertFalse(token.connectURL.absoluteString.contains("st-test"))
        let bad = GeminiLiveToken(token: "st-test", expiresAt: nil, newSessionExpiresAt: nil,
            model: token.model, webSocketURL: URL(string: "wss://evil.example/api-ws/v1/realtime")!)
        XCTAssertThrowsError(try QwenLiveSocket.request(token: bad))
    }

    @MainActor
    func testQwenSetupConvertsToolsAndDoesNotSendGoogleSettings() throws {
        let setup = GeminiLiveProtocol.setupMessage(systemInstruction: "Use Hermes.", functions: [
            .init(name: "start_job", description: "Work", parameters: ["type": "OBJECT", "properties": [
                "request": ["type": "STRING"]]], behavior: .nonBlocking),
        ], resumptionHandle: "google-only-handle")
        let update = QwenLiveSocket.sessionUpdate(setup: setup["setup"] as! [String: Any], voice: "Tina")
        let session = update["session"] as! [String: Any]
        let function = (session["tools"] as! [[String: Any]])[0]["function"] as! [String: Any]
        let parameters = function["parameters"] as! [String: Any]
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertNil(function["behavior"])
        XCTAssertNil(session["enable_search"])
        XCTAssertNil(session["sessionResumption"])
        XCTAssertEqual((session["input_audio_transcription"] as? [String: String])?["model"], "qwen3-asr-flash-realtime")
    }

    @MainActor
    func testQwenAudioAndInterruptDecodeThroughSharedSession() async throws {
        let fake = QwenTestSocket()
        let audio = Data([1, 2, 3, 4])
        fake.frames = [["type": "session.updated"], ["type": "response.audio.delta", "delta": audio.base64EncodedString()],
                       ["type": "input_audio_buffer.speech_started"],
                       ["type": "conversation.item.input_audio_transcription.completed", "transcript": "你好"]]
        let socket = QwenLiveSocket(upstream: fake)
        let setup = GeminiLiveProtocol.decode(try await socket.receive())
        let output = GeminiLiveProtocol.decode(try await socket.receive())
        let interruption = GeminiLiveProtocol.decode(try await socket.receive())
        let transcript = GeminiLiveProtocol.decode(try await socket.receive())
        XCTAssertEqual(setup, [.setupComplete])
        XCTAssertEqual(output, [.audio(audio, sampleRate: 24000)])
        XCTAssertEqual(interruption, [.interrupted])
        XCTAssertEqual(transcript, [.inputTranscription("你好")])
        try await socket.send(GeminiLiveProtocol.encode(GeminiLiveProtocol.audioMessage(pcm16: audio)))
        XCTAssertEqual(fake.sent.last?["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(fake.sent.last?["audio"] as? String, audio.base64EncodedString())
    }

    @MainActor
    func testQwenToolOutputWaitsForResponseToFinish() async throws {
        let fake = QwenTestSocket()
        fake.frames = [["type": "response.created"],
            ["type": "response.output_item.added", "item": ["type": "function_call", "call_id": "c1", "name": "start_job"]],
            ["type": "response.function_call_arguments.done", "call_id": "c1", "arguments": "{\"request\":\"check mail\"}"],
            ["type": "response.done"]]
        let socket = QwenLiveSocket(upstream: fake)
        let calls = GeminiLiveProtocol.decode(try await socket.receive())
        guard let first = calls.first, case .toolCall(let functions) = first else { return XCTFail("Missing tool call") }
        XCTAssertEqual(functions.first?.name, "start_job")
        try await socket.send(GeminiLiveProtocol.encode(GeminiLiveProtocol.toolResponseMessage(
            id: "c1", name: "start_job", result: ["status": "started"], scheduling: .whenIdle)))
        XCTAssertEqual(fake.sent.count, 1)
        XCTAssertEqual((fake.sent[0]["item"] as? [String: Any])?["type"] as? String, "function_call_output")
        _ = try await socket.receive()
        XCTAssertEqual(fake.sent.last?["type"] as? String, "response.create")
    }

    @MainActor
    func testQwenContextNoteDoesNotStartResponseAndErrorIsVisible() async throws {
        let fake = QwenTestSocket()
        let socket = QwenLiveSocket(upstream: fake)
        try await socket.send(GeminiLiveProtocol.encode(GeminiLiveProtocol.contextNoteMessage("Job is running")))
        XCTAssertEqual(fake.sent.count, 1)
        fake.frames = [["type": "error", "error": ["message": "sensitive provider body"]]]
        do {
            _ = try await socket.receive()
            XCTFail("Provider error was swallowed")
        } catch {
            XCTAssertTrue(error is QwenLiveError)
            XCTAssertFalse(error.localizedDescription.contains("sensitive provider body"))
        }
    }

    @MainActor
    func testQwenParallelToolsWaitForAllResults() async throws {
        let fake = QwenTestSocket()
        fake.frames = [
            ["type": "response.created"],
            ["type": "response.output_item.added", "item": ["type": "function_call", "call_id": "a", "name": "list_jobs"]],
            ["type": "response.output_item.added", "item": ["type": "function_call", "call_id": "b", "name": "start_job"]],
            ["type": "response.function_call_arguments.done", "call_id": "a", "arguments": "{}"],
            ["type": "response.function_call_arguments.done", "call_id": "b", "arguments": "{}"],
            ["type": "response.done"],
        ]
        let socket = QwenLiveSocket(upstream: fake)
        for _ in 0..<3 { _ = try await socket.receive() }
        try await socket.send(GeminiLiveProtocol.encode(GeminiLiveProtocol.toolResponseMessage(
            id: "a", name: "list_jobs", result: [:], scheduling: .whenIdle)))
        XCTAssertEqual(fake.sent.count, 1)
        try await socket.send(GeminiLiveProtocol.encode(GeminiLiveProtocol.toolResponseMessage(
            id: "b", name: "start_job", result: [:], scheduling: .whenIdle)))
        XCTAssertEqual(fake.sent.count, 3)
        XCTAssertEqual(fake.sent.last?["type"] as? String, "response.create")
    }

    @MainActor
    func testQwenUndeliveredToolsDoNotBlockLaterTextTurns() async throws {
        for status in ["cancelled", "incomplete", "completed"] {
            let fake = QwenTestSocket()
            fake.frames = [
                ["type": "response.created"],
                ["type": "response.output_item.added", "item": ["type": "function_call", "call_id": "abandoned", "name": "start_job"]],
                ["type": "response.done", "response": ["status": status]],
            ]
            let socket = QwenLiveSocket(upstream: fake)
            let done = GeminiLiveProtocol.decode(try await socket.receive())
            XCTAssertEqual(done, [.turnComplete])
            try await socket.send(GeminiLiveProtocol.encode(GeminiLiveProtocol.textTurnMessage("The job is done")))
            XCTAssertEqual(fake.sent.compactMap { $0["type"] as? String },
                           ["conversation.item.create", "response.create"], status)
        }
    }

    @MainActor
    func testQwenResponseDoneRetainsDeliveredToolWaiters() async throws {
        let fake = QwenTestSocket()
        fake.frames = [
            ["type": "response.created"],
            ["type": "response.output_item.added", "item": ["type": "function_call", "call_id": "delivered", "name": "list_jobs"]],
            ["type": "response.function_call_arguments.done", "call_id": "delivered", "arguments": "{}"],
            ["type": "response.output_item.added", "item": ["type": "function_call", "call_id": "abandoned", "name": "start_job"]],
            ["type": "response.done", "response": ["status": "cancelled"]],
        ]
        let socket = QwenLiveSocket(upstream: fake)
        _ = try await socket.receive() // Delivered call is still awaiting its result.
        _ = try await socket.receive() // Undelivered call is discarded at response.done.
        try await socket.send(GeminiLiveProtocol.encode(GeminiLiveProtocol.textTurnMessage("An update")))
        XCTAssertEqual(fake.sent.count, 1, "Delivered call must still block response.create")
        try await socket.send(GeminiLiveProtocol.encode(GeminiLiveProtocol.toolResponseMessage(
            id: "delivered", name: "list_jobs", result: ["status": "done"], scheduling: .whenIdle)))
        XCTAssertEqual(fake.sent.compactMap { $0["type"] as? String },
                       ["conversation.item.create", "conversation.item.create", "response.create"])
    }
}
