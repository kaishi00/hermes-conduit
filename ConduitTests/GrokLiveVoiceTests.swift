//
//  GrokLiveVoiceTests.swift
//  ConduitTests
//
//  Grok Live: the xAI realtime wire format, the session over the Hermes
//  host's relay, the bridge's immediate start_job answer and the mode
//  switch. Extensions of existing suites: the CI test planner was at
//  capacity for new XCTestCase classes when this file landed.
//

import XCTest
@testable import Conduit

@MainActor
final class FakeGrokLiveConnection: GrokLiveConnecting {
    var availabilityResult: GrokLiveAvailability = .available(model: "grok-voice-latest", voice: "eve", auth: "subscription")
    var requestError: Error?
    private(set) var requests = 0

    func availability() async throws -> GrokLiveAvailability { availabilityResult }

    func socketRequest() async throws -> URLRequest {
        if let requestError { throw requestError }
        requests += 1
        return URLRequest(url: URL(string: "wss://example.com/api/plugins/conduit_push/grok-live/socket?ticket=t-\(requests)")!)
    }
}

@MainActor
private func grokSettle(_ iterations: Int = 20) async {
    for _ in 0..<iterations { await Task.yield() }
}

/// Yields on the main actor until `done` holds, for at most `limit`. A cap,
/// not a timing: it returns as soon as `done` holds. For waits that cross
/// more awaits than a fixed number of yields covers on a loaded runner.
@MainActor
private func grokSettle(until done: () -> Bool, limit: Duration = .seconds(10)) async {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while !done(), ContinuousClock.now < deadline { await Task.yield() }
}

// MARK: - Wire format

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testGrokLiveDelegationInstructionsSendAccountWorkToStartJob() {
        let text = GrokLiveProtocol.delegationInstructions
        XCTAssertTrue(text.contains("start_job"))
        XCTAssertTrue(text.contains("email"))
        XCTAssertTrue(text.contains("if start_job fails, tell them plainly"))
    }

    func testGrokLiveClockInstructionsGiveTheLocalDateTimeAndZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // 2026-10-11 22:44 UTC: 6:44 PM on Sunday in New York (EDT).
        let now = Date(timeIntervalSince1970: 1_791_758_640)
        let text = GrokLiveProtocol.clockInstructions(now: now, timeZone: zone)
        XCTAssertTrue(text.contains("Sunday, October 11, 2026, 6:44 PM"), text)
        XCTAssertTrue(text.contains("America/New_York"))
        XCTAssertTrue(text.contains("never look them up on the web"))
    }

    func testGrokLiveSessionUpdateCarriesInstructionsVoiceAndLowercaseFunctionTools() throws {
        let update = GrokLiveProtocol.sessionUpdate(
            instructions: "be brief",
            functions: GeminiLiveToolBridge.functionDeclarations,
            voice: "eve"
        )
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        XCTAssertEqual(session["instructions"] as? String, "be brief")
        XCTAssertEqual(session["voice"] as? String, "eve")
        XCTAssertEqual((session["turn_detection"] as? [String: Any])?["type"] as? String, "server_vad")
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24_000)

        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, GeminiLiveToolBridge.functionDeclarations.count + 2)
        let startJob = try XCTUnwrap(tools.first { $0["name"] as? String == "start_job" })
        XCTAssertEqual(startJob["type"] as? String, "function")
        let parameters = try XCTUnwrap(startJob["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object", "JSON Schema types are lowercase")
        let instructions = (parameters["properties"] as? [String: Any])?["instructions"] as? [String: Any]
        XCTAssertEqual(instructions?["type"] as? String, "string")

        let noVoice = GrokLiveProtocol.sessionUpdate(instructions: "x", functions: [], voice: "")
        XCTAssertNil((noVoice["session"] as? [String: Any])?["voice"], "the host's default voice applies")
    }

    /// #598: public lookups use xAI's own search, never Hermes' web_search
    /// function under the name xAI keeps for its native tool.
    func testGrokLiveSessionUsesXAIsOwnSearchToolsAndNoClashingFunction() throws {
        let update = GrokLiveProtocol.sessionUpdate(
            instructions: "x",
            functions: GeminiLiveToolBridge.declarations(webSearch: true, memoryRecall: true),
            voice: nil
        )
        let tools = try XCTUnwrap((update["session"] as? [String: Any])?["tools"] as? [[String: Any]])
        let native = tools.filter { $0["type"] as? String != "function" }.compactMap { $0["type"] as? String }
        XCTAssertEqual(native, ["web_search", "x_search"])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains("web_search"), "a client function can't share the native tool's name")
        XCTAssertTrue(names.contains("start_job"))
        XCTAssertTrue(names.contains("recall_memory"))

        let instructions = GeminiLiveConversationController.instructions(search: .grok) + GrokLiveProtocol.delegationInstructions
        XCTAssertTrue(instructions.contains("x_search"))
        XCTAssertTrue(instructions.contains("never with start_job"))
        XCTAssertFalse(instructions.contains("call web_search. Just before"), "no Hermes lookup turn to wait for")
    }

    /// xAI runs its own search: a call by its name is never answered here.
    func testGrokLiveIgnoresCallsToXAIsOwnTools() {
        for name in ["web_search", "x_search", "browse_page"] {
            let frame = GrokLiveProtocol.decode(try! JSONSerialization.data(withJSONObject: [
                "type": "response.function_call_arguments.done",
                "call_id": "c1",
                "name": name,
                "arguments": #"{"query":"weather in San Diego"}"#,
            ]))
            XCTAssertEqual(frame, [], name)
        }
    }

    func testGrokLiveClientMessagesMapToRealtimeEvents() throws {
        // Samples 1 and 3 at 16 kHz become 1, 2, 3 at 24 kHz.
        let audio = GrokLiveProtocol.frames(for: .audio(Data([1, 0, 3, 0])))
        XCTAssertEqual(audio.frames.first?["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(audio.frames.first?["audio"] as? String, Data([1, 0, 2, 0, 3, 0]).base64EncodedString())
        XCTAssertFalse(audio.wantsResponse)
        XCTAssertEqual(GrokLiveProtocol.upsampledForInput(Data(count: 3_200)).count, 4_800, "100 ms of capture is 100 ms at 24 kHz")
        XCTAssertEqual(GrokLiveProtocol.upsampledForInput(Data([0x00, 0x80, 0xFF, 0x7F])), Data([0x00, 0x80, 0xAA, 0x2A, 0xFF, 0x7F]), "full-scale samples interpolate without overflow")
        XCTAssertEqual(GrokLiveProtocol.upsampledForInput(Data()), Data())

        let end = GrokLiveProtocol.frames(for: .audioStreamEnd)
        XCTAssertEqual(end.frames.first?["audio"] as? String, GrokLiveProtocol.silence.base64EncodedString(), "a short silence closes the turn")
        XCTAssertFalse(end.wantsResponse)

        let text = GrokLiveProtocol.frames(for: .textTurn("hello"))
        let item = try XCTUnwrap(text.frames.first?["item"] as? [String: Any])
        XCTAssertEqual(item["role"] as? String, "user")
        XCTAssertEqual((item["content"] as? [[String: Any]])?.first?["text"] as? String, "hello")
        XCTAssertTrue(text.wantsResponse)

        let answer = GrokLiveProtocol.frames(for: .toolResponse(id: "c1", name: "list_jobs", result: ["b": "2", "a": "1"], scheduling: nil))
        let output = try XCTUnwrap(answer.frames.first?["item"] as? [String: Any])
        XCTAssertEqual(output["type"] as? String, "function_call_output")
        XCTAssertEqual(output["call_id"] as? String, "c1")
        XCTAssertEqual(output["output"] as? String, #"{"a":"1","b":"2"}"#)
        XCTAssertTrue(answer.wantsResponse)
        XCTAssertFalse(GrokLiveProtocol.frames(for: .toolResponse(id: "c1", name: "start_job", result: [:], scheduling: .silent)).wantsResponse, "a silent answer is absorbed")

        let note = GrokLiveProtocol.frames(for: .contextNote("typed"))
        XCTAssertEqual(note.frames.first?["type"] as? String, "conversation.item.create")
        XCTAssertEqual(((note.frames.first?["item"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String, "typed")
        XCTAssertFalse(note.wantsResponse, "context is kept, not answered")
    }

    func testGrokLiveServerEventsDecodeToTheSharedConversationEvents() {
        func decode(_ object: [String: Any]) -> [GrokLiveProtocol.ServerFrame] {
            GrokLiveProtocol.decode(try! JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(decode(["type": "session.updated", "session": [String: Any]()]), [.sessionUpdated])
        XCTAssertEqual(decode(["type": "response.created"]), [.responseStarted])
        XCTAssertEqual(decode(["type": "response.done"]), [.responseDone, .event(.turnComplete)])
        XCTAssertEqual(decode(["type": "input_audio_buffer.speech_started"]), [.event(.interrupted)])
        XCTAssertEqual(decode(["type": "conversation.item.input_audio_transcription.completed", "item_id": "i1", "transcript": "hi"]), [.inputTranscriptSnapshot(itemID: "i1", text: "hi")])
        XCTAssertEqual(decode(["type": "conversation.item.input_audio_transcription.completed", "transcript": "hi"]), [.inputTranscriptSnapshot(itemID: nil, text: "hi")])
        XCTAssertEqual(decode(["type": "response.output_audio.delta", "delta": Data([9, 9]).base64EncodedString()]), [.event(.audio(Data([9, 9]), sampleRate: 24_000))])
        XCTAssertEqual(decode(["type": "response.output_audio_transcript.delta", "delta": "Hel"]), [.event(.outputTranscription("Hel"))])
        XCTAssertEqual(decode(["type": "response.output_audio_transcript.done", "transcript": "Hello"]), [.outputTranscriptDone("Hello")])
        XCTAssertEqual(decode(["type": "error", "error": ["message": "bad voice"]]), [.error("bad voice")])
        XCTAssertEqual(decode(["type": "rate_limits.updated"]), [], "unknown events are ignored")

        let call = decode([
            "type": "response.function_call_arguments.done",
            "call_id": "c7",
            "name": "start_job",
            "arguments": #"{"instructions":"check the server","count":3}"#,
        ])
        XCTAssertEqual(call, [.event(.toolCall([.init(id: "c7", name: "start_job", arguments: ["instructions": "check the server", "count": "3"])]))])
    }

    /// xAI's input transcripts are cumulative snapshots, not deltas: only
    /// the words a snapshot adds reach the transcript.
    func testGrokLiveInputTranscriptSnapshotsAddOnlyTheirNewWords() {
        func delta(_ previous: String, _ snapshot: String) -> String? {
            GrokLiveProtocol.inputTranscriptDelta(previous: previous, snapshot: snapshot)
        }
        XCTAssertEqual(delta("", "Can you check"), "Can you check")
        XCTAssertEqual(delta("Can you check", "Can you check my email right now?"), " my email right now?")
        XCTAssertNil(delta("Can you check my email right now?", "Can you check my email right now?"), "a repeated snapshot adds nothing")
        XCTAssertNil(delta("Can you check my email", "Can you check"), "an older, shorter snapshot adds nothing")
        XCTAssertNil(delta("Hello?", "Hello, my name is"), "a revision adds nothing: appending can't take words back")
        XCTAssertNil(delta("send mail", "send the mail"), "an interior revision never repeats words already shown")
        XCTAssertNil(delta("Hello there", "Hello, Sam"), "a revision no longer than before adds nothing")
    }

    func testGrokLiveAvailabilityParsesTheHostStatus() {
        XCTAssertEqual(
            GrokLiveClient.availability(from: ["ok": true, "available": true, "model": "grok-voice-latest", "voice": "eve", "auth": "subscription"]),
            .available(model: "grok-voice-latest", voice: "eve", auth: "subscription")
        )
        XCTAssertEqual(
            GrokLiveClient.availability(from: ["ok": true, "available": true]),
            .available(model: GrokLiveProtocol.defaultModel, voice: nil, auth: nil)
        )
        let unavailable = GrokLiveClient.availability(from: ["ok": true, "available": false, "reason": "No xAI sign-in"])
        XCTAssertEqual(unavailable, .unavailable(reason: "No xAI sign-in"))
        XCTAssertEqual(unavailable.userFacingReason, AppLocalization.string("Grok Live is not available on this Hermes server: \("No xAI sign-in")"))
        XCTAssertNil(GrokLiveAvailability.available(model: "m", voice: nil, auth: nil).userFacingReason)
    }

    func testGrokLiveSocketRequestCarriesAFreshTicketAndTheProfile() async throws {
        var tickets = 0
        var seenPath: String?
        let client = GrokLiveClient(
            profile: { "work" },
            request: { _, _, _, _ in [:] },
            mintTicket: { tickets += 1; return "ticket-\(tickets)" },
            socketRequest: { path, items in
                seenPath = path
                var components = URLComponents(string: "wss://example.com")!
                components.path = path
                components.queryItems = items
                return URLRequest(url: components.url!)
            }
        )
        let first = try await client.socketRequest()
        let second = try await client.socketRequest()
        XCTAssertEqual(seenPath, GrokLiveClient.socketPath)
        let items = URLComponents(url: try XCTUnwrap(first.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "ticket" }?.value, "ticket-1")
        XCTAssertEqual(items.first { $0.name == "profile" }?.value, "work")
        XCTAssertTrue(second.url?.absoluteString.contains("ticket-2") == true, "each socket gets its own single-use ticket")
    }

    func testGrokLiveTreatsTheRelaysUnreachableCloseAsRetryable() {
        XCTAssertFalse(GrokLiveSession.isRefusal(.init(code: 4502, reason: "The connection to xAI was lost")))
        XCTAssertTrue(GrokLiveSession.isRefusal(.init(code: 4503, reason: "no credential")))
        XCTAssertTrue(GrokLiveSession.isRefusal(.init(code: 4401, reason: "")))
        XCTAssertTrue(GrokLiveSession.isRefusal(.init(code: 403, reason: "", isHTTPStatus: true)))
        XCTAssertFalse(GrokLiveSession.isRefusal(.init(code: 502, reason: "", isHTTPStatus: true)))
        XCTAssertFalse(GrokLiveSession.isRefusal(.init(code: 1006, reason: "")))
        XCTAssertEqual(
            GrokLiveSession.refusalMessage(.init(code: 404, reason: "", isHTTPStatus: true)),
            GrokLiveAvailability.pluginMissing.userFacingReason
        )
    }
}

// MARK: - Session and tools

@MainActor
extension VoiceConversationControllerTests {
    private func makeGrokSession(
        connection: FakeGrokLiveConnection? = nil
    ) -> (GrokLiveSession, () -> [FakeGeminiLiveSocket]) {
        let connection = connection ?? FakeGrokLiveConnection()
        var sockets: [FakeGeminiLiveSocket] = []
        let session = GrokLiveSession(
            client: connection,
            instructions: "test",
            functions: GeminiLiveToolBridge.functionDeclarations,
            voice: "eve",
            openSocket: { request in
                let socket = FakeGeminiLiveSocket(url: request.url!)
                sockets.append(socket)
                return socket
            },
            reconnectDelay: { _ in }
        )
        return (session, { sockets })
    }

    func testGrokLiveSessionIsReadyOnceXAIConfirmsTheSessionUpdate() async throws {
        let (session, sockets) = makeGrokSession()
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        XCTAssertEqual(socket.sent.first?["type"] as? String, "session.update")
        XCTAssertEqual(session.state, .connecting)

        session.send(.audio(Data([1, 2])))
        await grokSettle()
        XCTAssertEqual(socket.sent.count, 1, "nothing streams before the session is set up")

        socket.deliver(["type": "session.updated", "session": [String: Any]()])
        await grokSettle()
        XCTAssertEqual(session.state, .ready)
        session.send(.audio(Data([1, 2])))
        await grokSettle()
        XCTAssertEqual(socket.sent.last?["type"] as? String, "input_audio_buffer.append")
        session.stop()
    }

    func testGrokLiveHoldsAResponseRequestUntilTheRunningResponseEnds() async throws {
        let (session, sockets) = makeGrokSession()
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()

        session.send(.textTurn("first"))
        await grokSettle()
        XCTAssertEqual(socket.sent.suffix(2).map { $0["type"] as? String }, ["conversation.item.create", "response.create"])
        socket.deliver(["type": "response.created"])
        await grokSettle()

        session.send(.textTurn("second"))
        await grokSettle()
        XCTAssertEqual(socket.sent.last?["type"] as? String, "conversation.item.create", "a response is running: the request waits")
        let creates = { socket.sent.filter { $0["type"] as? String == "response.create" }.count }
        XCTAssertEqual(creates(), 1)

        socket.deliver(["type": "response.done"])
        await grokSettle()
        XCTAssertEqual(creates(), 2, "the waiting request goes out once the response ends")
        session.stop()
    }

    /// The pattern a user reported: "Can you checkCan you check my right
    /// now?Can you check my right now?" from repeated, growing snapshots.
    func testGrokLiveSessionTurnsRepeatedTranscriptSnapshotsIntoOneLine() async throws {
        let (session, sockets) = makeGrokSession()
        var heard: [String] = []
        session.onEvent = { event in
            if case .inputTranscription(let text) = event { heard.append(text) }
        }
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()

        let event = "conversation.item.input_audio_transcription.completed"
        socket.deliver(["type": event, "item_id": "i1", "transcript": "Can you check"])
        socket.deliver(["type": event, "item_id": "i1", "transcript": "Can you check my email right now?"])
        socket.deliver(["type": event, "item_id": "i1", "transcript": "Can you check my email right now?"])
        socket.deliver(["type": event, "item_id": "i2", "transcript": "Thanks."])
        await grokSettle(until: { heard.count == 3 })
        XCTAssertEqual(heard.joined(), "Can you check my email right now?Thanks.")
        XCTAssertEqual(heard, ["Can you check", " my email right now?", "Thanks."])
        session.stop()
    }

    /// Without an item id there is no baseline: the snapshot goes through
    /// whole. More items than are remembered keeps later deltas right.
    func testGrokLiveSessionPassesIDlessSnapshotsAndBoundsRememberedItems() async throws {
        let (session, sockets) = makeGrokSession()
        var heard: [String] = []
        session.onEvent = { event in
            if case .inputTranscription(let text) = event { heard.append(text) }
        }
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()

        let event = "conversation.item.input_audio_transcription.completed"
        socket.deliver(["type": event, "transcript": "thanks"])
        socket.deliver(["type": event, "transcript": "thanks"])
        await grokSettle(until: { heard.count == 2 })
        XCTAssertEqual(heard, ["thanks", "thanks"], "a repeated short utterance with no id is kept")

        heard = []
        for number in 1...6 {
            socket.deliver(["type": event, "item_id": "i\(number)", "transcript": "Line \(number)"])
        }
        socket.deliver(["type": event, "item_id": "i6", "transcript": "Line 6 done"])
        socket.deliver(["type": event, "item_id": "i6", "transcript": "Line 6 done"])
        await grokSettle(until: { heard.count == 7 })
        await grokSettle()
        XCTAssertEqual(heard, ["Line 1", "Line 2", "Line 3", "Line 4", "Line 5", "Line 6", " done"])
        session.stop()
    }

    /// A longer revision adds nothing but becomes the baseline, so words
    /// said after it arrive without repeating the revised ones.
    func testGrokLiveSessionAddsWordsAfterARevisionWithoutRepeating() async throws {
        let (session, sockets) = makeGrokSession()
        var heard: [String] = []
        session.onEvent = { event in
            if case .inputTranscription(let text) = event { heard.append(text) }
        }
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()

        let event = "conversation.item.input_audio_transcription.completed"
        socket.deliver(["type": event, "item_id": "i1", "transcript": "send mail"])
        socket.deliver(["type": event, "item_id": "i1", "transcript": "send the mail"])
        socket.deliver(["type": event, "item_id": "i1", "transcript": "send the mail to Sam"])
        await grokSettle(until: { heard.count == 2 })
        await grokSettle()
        XCTAssertEqual(heard, ["send mail", " to Sam"])
        session.stop()
    }

    /// A shorter revision adds nothing and leaves the longest snapshot as
    /// the baseline, so growth after it never repeats words already shown.
    func testGrokLiveSessionKeepsTheLongestSnapshotAcrossARevision() async throws {
        let (session, sockets) = makeGrokSession()
        var heard: [String] = []
        session.onEvent = { event in
            if case .inputTranscription(let text) = event { heard.append(text) }
        }
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()

        let event = "conversation.item.input_audio_transcription.completed"
        socket.deliver(["type": event, "item_id": "i1", "transcript": "I like apples"])
        socket.deliver(["type": event, "item_id": "i1", "transcript": "I like grapes"])
        socket.deliver(["type": event, "item_id": "i1", "transcript": "I like apples pie"])
        socket.deliver(["type": event, "item_id": "i1", "transcript": "I like apples"])
        await grokSettle(until: { heard.joined() == "I like apples pie" })
        await grokSettle()
        XCTAssertEqual(heard.joined(), "I like apples pie")
        session.stop()
    }

    func testGrokLiveARefusedResponseRequestDoesNotBlockLaterTurns() async throws {
        let (session, sockets) = makeGrokSession()
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()
        let creates = { socket.sent.filter { $0["type"] as? String == "response.create" }.count }

        session.send(.textTurn("first"))
        await grokSettle()
        XCTAssertEqual(creates(), 1)
        socket.deliver(["type": "error", "error": ["message": "conversation already has an active response"]])
        await grokSettle()
        XCTAssertEqual(session.state, .ready, "an error after setup doesn't end the call")

        session.send(.textTurn("second"))
        await grokSettle()
        XCTAssertEqual(creates(), 2, "the refused request no longer counts as running")
        session.stop()
    }

    func testGrokLiveSetupThatNeverCompletesIsRetriedThenFails() async throws {
        var sockets: [FakeGeminiLiveSocket] = []
        let session = GrokLiveSession(
            client: FakeGrokLiveConnection(),
            instructions: "test",
            functions: [],
            openSocket: { request in
                let socket = FakeGeminiLiveSocket(url: request.url!)
                sockets.append(socket)
                return socket
            },
            setupTimeout: .zero,
            reconnectDelay: { _ in }
        )
        session.start()
        await grokSettle(until: { session.state.isFailed })
        XCTAssertEqual(session.state, .failed(AppLocalization.string("Couldn't connect to Grok Live.")))
        XCTAssertEqual(sockets.count, 1 + GrokLiveSession.maximumReconnectAttempts)
        XCTAssertTrue(sockets.allSatisfy(\.closed))
    }

    func testGrokLiveTurnQueuedBehindAResponseIsDeliveredOnlyWithItsRequest() async throws {
        let (session, sockets) = makeGrokSession()
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()
        session.send(.textTurn("first"))
        await grokSettle()
        socket.deliver(["type": "response.created"])
        await grokSettle()

        var outcome: [String] = []
        session.send(.textTurn("second"), onSent: { outcome.append("sent") }, onFailure: { outcome.append("failed") })
        await grokSettle()
        XCTAssertEqual(outcome, [], "queued behind the running response: not delivered yet")
        socket.deliver(["type": "response.done"])
        await grokSettle()
        XCTAssertEqual(outcome, [], "its request went out, but xAI hasn't started the response")
        socket.deliver(["type": "response.created"])
        await grokSettle()
        XCTAssertEqual(outcome, ["sent"])

        var lost: [String] = []
        session.send(.textTurn("third"), onSent: { lost.append("sent") }, onFailure: { lost.append("failed") })
        await grokSettle()
        socket.serverClose(nil)
        await grokSettle(until: { !lost.isEmpty })
        XCTAssertEqual(lost, ["failed"], "the connection ended before its request went out")
        session.stop()
    }

    func testGrokLiveTurnWhoseRequestXAIRefusesIsReportedFailed() async throws {
        let (session, sockets) = makeGrokSession()
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()

        var outcome: [String] = []
        session.send(.textTurn("hello"), onSent: { outcome.append("sent") }, onFailure: { outcome.append("failed") })
        await grokSettle()
        XCTAssertEqual(outcome, [])
        socket.deliver(["type": "error", "error": ["message": "conversation already has an active response"]])
        await grokSettle()
        XCTAssertEqual(outcome, ["failed"], "refused before it started: sent again later, not dropped")
        session.stop()
    }

    func testGrokLiveStalledResponseStopsHoldingLaterTurns() async throws {
        var sockets: [FakeGeminiLiveSocket] = []
        let session = GrokLiveSession(
            client: FakeGrokLiveConnection(),
            instructions: "test",
            functions: [],
            openSocket: { request in
                let socket = FakeGeminiLiveSocket(url: request.url!)
                sockets.append(socket)
                return socket
            },
            responseTimeout: .zero,
            reconnectDelay: { _ in }
        )
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets.first)
        socket.deliver(["type": "session.updated"])
        await grokSettle()
        session.send(.textTurn("first"))
        await grokSettle()
        socket.deliver(["type": "response.created"])
        await grokSettle(40)

        session.send(.textTurn("second"))
        let creates = { socket.sent.filter { $0["type"] as? String == "response.create" }.count }
        // The stall is noticed by a timer task, not within a count of yields.
        await grokSettle(until: { creates() == 2 })
        XCTAssertEqual(creates(), 2, "a response that never finished no longer holds the next one")
        session.stop()
    }

    func testGrokLiveShowsTheFinalTranscriptOnlyWhenNoDeltasCarriedIt() async throws {
        let (session, sockets) = makeGrokSession()
        var heard: [GeminiLiveProtocol.ServerEvent] = []
        session.onEvent = { heard.append($0) }
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        socket.deliver(["type": "response.created"])
        socket.deliver(["type": "response.output_audio_transcript.done", "transcript": "Whole reply"])
        socket.deliver(["type": "response.done"])
        socket.deliver(["type": "response.created"])
        socket.deliver(["type": "response.output_audio_transcript.delta", "delta": "Streamed"])
        socket.deliver(["type": "response.output_audio_transcript.done", "transcript": "Streamed"])
        socket.deliver(["type": "response.done"])
        await grokSettle(40)
        XCTAssertEqual(heard, [
            .outputTranscription("Whole reply"), .turnComplete,
            .outputTranscription("Streamed"), .turnComplete,
        ])
        session.stop()
    }

    func testGrokLiveFailsWithoutRetryWhenTheRelayRefuses() async throws {
        let (session, sockets) = makeGrokSession()
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.serverClose(.init(code: 4503, reason: "Grok Live needs xAI on the Hermes host"))
        await grokSettle(until: { session.state.isFailed })
        XCTAssertEqual(session.state, .failed(AppLocalization.string("Grok Live refused the connection: \(GeminiLiveServerClose(code: 4503, reason: "Grok Live needs xAI on the Hermes host").summary)")))
        XCTAssertEqual(sockets().count, 1)
    }

    func testGrokLiveFailsWhenXAIRejectsTheSessionSetup() async throws {
        let (session, sockets) = makeGrokSession()
        session.start()
        await grokSettle()
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "error", "error": ["message": "unknown voice"]])
        await grokSettle()
        XCTAssertEqual(session.state, .failed(AppLocalization.string("Grok Live refused the connection: \("unknown voice")")))
        XCTAssertEqual(sockets().count, 1, "a retry would send the same setup")
    }

    func testGrokLiveDroppedConversationReconnectsAsANewSession() async throws {
        let connection = FakeGrokLiveConnection()
        let (session, sockets) = makeGrokSession(connection: connection)
        var replaced = 0
        session.onConnectionReplaced = { replaced += 1 }
        session.start()
        await grokSettle()
        let first = try XCTUnwrap(sockets().first)
        first.deliver(["type": "session.updated"])
        await grokSettle()
        XCTAssertEqual(session.state, .ready)

        first.serverClose(nil)
        // The drop, the new ticket and the new setup send cross more awaits
        // than 120 yields always covered on a loaded runner.
        await grokSettle(until: { sockets().count == 2 && sockets()[1].sent.first != nil })
        XCTAssertEqual(sockets().count, 2)
        XCTAssertEqual(connection.requests, 2, "every connection gets its own ticket")
        XCTAssertEqual(session.state, .reconnecting)
        let second = try XCTUnwrap(sockets().dropFirst().first)
        XCTAssertEqual(second.sent.first?["type"] as? String, "session.update")
        second.deliver(["type": "session.updated"])
        await grokSettle(until: { session.state == .ready })
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.connectionGeneration, 1)
        XCTAssertEqual(replaced, 1, "calls opened on the old session can't be answered")
        session.stop()
    }

    func testGrokLiveBridgeAnswersStartJobAtOnceAndReportsTheOutcomeAsText() async throws {
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        let bridge = GeminiLiveToolBridge(supervisor: supervisor, holdsJobCalls: false)

        let immediate = await bridge.handle(.init(id: "c1", name: "start_job", arguments: ["instructions": "check the server"]))
        guard case .toolResponse(let id, let name, let result, let scheduling)? = immediate.first, immediate.count == 1 else {
            return XCTFail("Expected one tool response, got \(immediate)")
        }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(name, "start_job")
        XCTAssertEqual(result["status"], "started")
        XCTAssertEqual(result["job_id"], try XCTUnwrap(supervisor.jobs.first?.id).uuidString)
        XCTAssertNil(scheduling)
        XCTAssertEqual(bridge.openCallCount, 0, "no call stays open")

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        let updates = bridge.pendingUpdates()
        guard case .textWhenIdle(let text)? = updates.first, updates.count == 1 else { return XCTFail("\(updates)") }
        XCTAssertTrue(text.contains("All green."))
    }
}

// MARK: - Preferences and mode switch

@MainActor
extension ContinuousConversationPreferenceTests {
    func testGrokLiveIsOffByDefaultAndOlderPreferencesDecodeOff() throws {
        XCTAssertFalse(VoiceProfilePreferences().grokLiveEnabled)
        let legacy = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data(#"{"geminiLiveEnabled":true}"#.utf8))
        XCTAssertFalse(legacy.grokLiveEnabled)
        XCTAssertNil(legacy.grokLiveMemory)
        var enabled = VoiceProfilePreferences()
        enabled.grokLiveEnabled = true
        enabled.grokLiveMemory = true
        let roundTrip = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(roundTrip.grokLiveEnabled)
        XCTAssertEqual(roundTrip.grokLiveMemory, true)
    }
}

@MainActor
extension AppStateVoiceCapabilityTests {
    private func makeGrokAppState() -> AppState {
        let suite = "GrokLiveAppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(isGatewayConnected: true, supportsTranscription: false, supportsSpeech: false, unavailableReason: "No STT"),
            isVoiceEnabled: false,
            transcriptionMode: .hermes,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US")
        )
        return appState
    }

    func testGrokLiveIsOneLiveModeAmongThreeAndOpensItsOwnSheet() async {
        let appState = makeGrokAppState()
        XCTAssertFalse(appState.isGrokLiveEnabled, "Off by default")

        appState.setGeminiLiveEnabled(true)
        appState.setGrokLiveEnabled(true)
        XCTAssertTrue(appState.isGrokLiveEnabled)
        XCTAssertFalse(appState.isGeminiLiveEnabled, "turning Grok Live on turns the others off")
        XCTAssertFalse(appState.isGPTLiveEnabled)
        XCTAssertNil(appState.phoneVoiceUnavailableReason, "Grok Live does not need Hermes speech providers")
        XCTAssertTrue(appState.showsComposerVoiceButton)

        let opened = await appState.openVoiceConversation(
            PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(opened)
        XCTAssertTrue(appState.showGrokLiveSheet)
        XCTAssertFalse(appState.showGeminiLiveSheet)
        XCTAssertFalse(appState.showVoiceSheet)

        appState.setGPTLiveEnabled(true)
        XCTAssertFalse(appState.isGrokLiveEnabled)
        XCTAssertFalse(appState.showGrokLiveSheet, "another live mode closes Grok Live")
    }

    func testDisconnectClosesGrokLive() async {
        let appState = makeGrokAppState()
        appState.setGrokLiveEnabled(true)
        _ = await appState.openVoiceConversation(
            PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(appState.showGrokLiveSheet)
        XCTAssertTrue(appState.voiceBackgroundJobSupervisor.liveCallReadsReplies, "the call hears its jobs' replies (#599)")

        appState.disconnect()

        XCTAssertFalse(appState.showGrokLiveSheet)
        XCTAssertFalse(appState.grokLiveController.isActive)
        XCTAssertFalse(appState.voiceBackgroundJobSupervisor.liveCallReadsReplies)
    }
}
