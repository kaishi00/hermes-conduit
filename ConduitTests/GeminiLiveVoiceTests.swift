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
    private(set) var closed = false
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?

    init(url: URL) { self.url = url }

    func send(_ text: String) async throws {
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
        XCTAssertEqual(behaviors, ["start_job": "NON_BLOCKING", "list_jobs": "BLOCKING", "cancel_job": "BLOCKING"])

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
    private func makeGeminiSession(tokens: FakeGeminiLiveTokens) -> (GeminiLiveSession, () -> [FakeGeminiLiveSocket]) {
        var sockets: [FakeGeminiLiveSocket] = []
        let session = GeminiLiveSession(
            tokens: tokens,
            systemInstruction: "test",
            functions: GeminiLiveToolBridge.functionDeclarations,
            openSocket: { url in
                let socket = FakeGeminiLiveSocket(url: url)
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
            routePolicy: { route }
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
