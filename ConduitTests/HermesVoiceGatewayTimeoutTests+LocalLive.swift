//
//  HermesVoiceGatewayTimeoutTests+LocalLive.swift
//  ConduitTests
//
//  Local Live: a live call through the user's own speech server, with each
//  turn the server asks for run as a Hermes chat turn. The session's wire
//  format and turn frames, the turn runner, and the mode switch.
//  Extensions of existing suites: the CI test planner was at capacity for
//  new XCTestCase classes.
//

import XCTest
@testable import Conduit

@MainActor
final class FakeLocalLiveConnection: LocalLiveConnecting {
    private(set) var requests = 0

    func socketRequest() async throws -> URLRequest {
        requests += 1
        return URLRequest(url: URL(string: "wss://example.com/api/plugins/conduit_push/local-live/socket?ticket=t-\(requests)")!)
    }
}

/// Yields on the main actor until `done` holds, for at most `limit`. A cap,
/// not a timing: it returns as soon as `done` holds.
@MainActor
private func localLiveSettle(until done: () -> Bool, limit: Duration = .seconds(10)) async {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while !done(), ContinuousClock.now < deadline { await Task.yield() }
}

// MARK: - Wire format and session

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testLocalLiveSessionUpdateLetsTheServerAnswerEachTurnWithNoTools() throws {
        let update = LocalLiveProtocol.sessionUpdate
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertNil(session["tools"], "the speech server refuses tool_choice; Hermes does the work")
        XCTAssertNil(session["instructions"])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let detection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(detection["create_response"] as? Bool, true)
        XCTAssertEqual(detection["interrupt_response"] as? Bool, true)
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24_000)
        XCTAssertEqual(((audio["output"] as? [String: Any])?["format"] as? [String: Any])?["rate"] as? Int, 24_000)
    }

    func testLocalLiveReadsOnlyThePluginsTurnFrames() throws {
        func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        XCTAssertEqual(LocalLiveProtocol.turnFrame(try data(["type": "conduit.turn", "turn_id": "t1", "text": "Hi"])), .turn(id: "t1", text: "Hi"))
        XCTAssertEqual(LocalLiveProtocol.turnFrame(try data(["type": "conduit.turn.cancel", "turn_id": "t1"])), .cancel(id: "t1"))
        XCTAssertNil(LocalLiveProtocol.turnFrame(try data(["type": "conduit.turn", "text": "no id"])))
        XCTAssertNil(LocalLiveProtocol.turnFrame(try data(["type": "response.output_audio.delta", "delta": "AAAA"])))
        // The model saying the words is not a turn frame.
        XCTAssertNil(LocalLiveProtocol.turnFrame(try data(["type": "response.output_audio_transcript.delta", "delta": "\"conduit.turn\""])))
    }

    func testLocalLiveStopsPlaybackWhenTheServerClearsOrCancelsItsAudio() throws {
        func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        for type in ["output_audio_buffer.clear", "output_audio_buffer.cleared", "response.cancel", "response.cancelled"] {
            XCTAssertTrue(LocalLiveProtocol.stopsPlayback(try data(["type": type])), type)
        }
        XCTAssertTrue(LocalLiveProtocol.stopsPlayback(try data(["type": "response.done", "response": ["status": "cancelled"]])))
        XCTAssertFalse(LocalLiveProtocol.stopsPlayback(try data(["type": "response.done", "response": ["status": "completed"]])))
        XCTAssertFalse(LocalLiveProtocol.stopsPlayback(try data(["type": "response.output_audio.delta", "delta": "AAAA"])))
        // The model saying the words doesn't stop it.
        XCTAssertFalse(LocalLiveProtocol.stopsPlayback(try data(["type": "response.output_audio_transcript.delta", "delta": "response.cancel \"cancelled\""])))
    }

    func testLocalLiveSessionStopsTheReplyWhenTheServerCutsItsAudio() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var interruptions = 0
        session.onEvent = { event in
            if case .interrupted = event { interruptions += 1 }
        }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated", "session": [String: Any]()])
        try await passLocalLiveReadiness(socket, session: session)
        // The check's own response ends first: its events aren't the call's.
        socket.deliver(["type": "response.done"])
        XCTAssertEqual(interruptions, 0)

        socket.deliver(["type": "output_audio_buffer.clear"])
        await localLiveSettle(until: { interruptions == 1 })
        socket.deliver(["type": "response.done", "response": ["status": "cancelled"]])
        await localLiveSettle(until: { interruptions == 2 })
        XCTAssertEqual(interruptions, 2)
        session.stop()
    }

    /// Local Live traces the same turn steps as Grok Live (#1418).
    func testLocalLiveSessionTracesTurnDetectionAndTheUsersTurns() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var trace: [String] = []
        session.onTrace = { trace.append($0) }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated", "session": ["turn_detection": ["type": "server_vad", "silence_duration_ms": 500]]])
        try await passLocalLiveReadiness(socket, session: session)
        socket.deliver(["type": "response.done"])

        session.send(.audio(Data(count: 3_200)))
        socket.deliver(["type": "input_audio_buffer.speech_started"])
        socket.deliver(["type": "input_audio_buffer.speech_stopped"])
        socket.deliver(["type": "response.created"])
        await localLiveSettle(until: { trace.contains("Reply started") })
        XCTAssertEqual(trace, [
            "Turn detection: server_vad, silence ms 500",
            "Speech start heard (before it: microphone loudest -96 dBFS, quietest -96 dBFS)",
            "Speech end heard after 0.0 s (no microphone audio)",
            "Reply started",
        ])
        session.stop()
    }

    func testLocalLiveSplitsLongRepliesIntoFramesThePluginTakes() {
        XCTAssertEqual(LocalLiveProtocol.deltaChunks(""), [])
        XCTAssertEqual(LocalLiveProtocol.deltaChunks("Hello."), ["Hello."])
        let long = String(repeating: "a", count: LocalLiveProtocol.maximumDeltaCharacters * 2 + 5)
        let chunks = LocalLiveProtocol.deltaChunks(long)
        XCTAssertEqual(chunks.map(\.count), [LocalLiveProtocol.maximumDeltaCharacters, LocalLiveProtocol.maximumDeltaCharacters, 5])
        XCTAssertEqual(chunks.joined(), long)

        // The plugin counts code points: a flag is two.
        let flags = String(repeating: "🇯🇵", count: LocalLiveProtocol.maximumDeltaCharacters)
        let flagChunks = LocalLiveProtocol.deltaChunks(flags)
        XCTAssertEqual(flagChunks.map(\.unicodeScalars.count), [LocalLiveProtocol.maximumDeltaCharacters, LocalLiveProtocol.maximumDeltaCharacters])
        XCTAssertEqual(flagChunks.joined(), flags)
    }

    private func makeLocalLiveSession(readinessTimeout: Duration = .seconds(3_600)) -> (LocalLiveSession, () -> [FakeGeminiLiveSocket]) {
        var sockets: [FakeGeminiLiveSocket] = []
        let session = LocalLiveSession(
            client: FakeLocalLiveConnection(),
            openSocket: { request in
                let socket = FakeGeminiLiveSocket(url: request.url!)
                sockets.append(socket)
                return socket
            },
            readinessTimeout: readinessTimeout,
            keepaliveInterval: .seconds(3_600),
            reconnectDelay: { _ in }
        )
        return (session, { sockets })
    }

    /// The words of the session's readiness check, once it went out.
    private func localLiveReadinessMarker(_ socket: FakeGeminiLiveSocket) async throws -> String {
        await localLiveSettle(until: { socket.sent.contains { $0["type"] as? String == "response.create" } })
        let check = try XCTUnwrap(socket.sent.last { $0["type"] as? String == "response.create" })
        let response = try XCTUnwrap(check["response"] as? [String: Any])
        let item = try XCTUnwrap((response["input"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap((item["content"] as? [[String: Any]])?.first)
        return try XCTUnwrap(content["text"] as? String)
    }

    /// The server's ask for the check's reply, as the plugin hands it to
    /// the call: the session is ready once it arrives.
    private func passLocalLiveReadiness(_ socket: FakeGeminiLiveSocket, session: LocalLiveSession) async throws {
        let marker = try await localLiveReadinessMarker(socket)
        socket.deliver(["type": "conduit.turn", "turn_id": "ready", "text": marker])
        await localLiveSettle(until: { session.state == .ready })
    }

    func testLocalLiveAgentFramesCarryTheCallsToolsAndAnswers() throws {
        func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let declaration = GeminiLiveProtocol.FunctionDeclaration(
            name: "start_job", description: "Start a job.",
            parameters: ["type": "OBJECT", "properties": ["instructions": ["type": "STRING"]]], behavior: .nonBlocking)
        let configure = LocalLiveProtocol.agentConfigure(.init(instructions: "Be brief.", functions: [declaration]))
        XCTAssertEqual(configure["type"] as? String, "conduit.agent")
        XCTAssertEqual(configure["instructions"] as? String, "Be brief.")
        let tool = try XCTUnwrap((configure["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["name"] as? String, "start_job")
        XCTAssertEqual((tool["parameters"] as? [String: Any])?["type"] as? String, "object", "JSON Schema types are lowercase")

        let call = LocalLiveProtocol.agentFrame(try data(["type": "conduit.tool.call", "call_id": "ll1", "name": "start_job",
                                                           "arguments": "{\"instructions\":\"check mail\"}"]))
        XCTAssertEqual(call, .toolCall(GeminiLiveProtocol.FunctionCall(id: "ll1", name: "start_job", arguments: ["instructions": "check mail"])))
        XCTAssertEqual(LocalLiveProtocol.agentFrame(try data(["type": "conduit.tool.late", "call_id": "ll1"])), .late(callID: "ll1"))
        XCTAssertNil(LocalLiveProtocol.agentFrame(try data(["type": "conduit.agent.ready", "tools": 1])))
        XCTAssertNil(LocalLiveProtocol.agentFrame(try data(["type": "conduit.turn", "turn_id": "t1", "text": "Hi"])))

        let result = LocalLiveProtocol.toolResult(callID: "ll1", result: ["status": "started"], speak: true)
        XCTAssertEqual(result["output"] as? String, "{\"status\":\"started\"}")
        XCTAssertEqual(result["speak"] as? Bool, true)
    }

    func testLocalLiveAgentModeRunsTheFastModelsToolCallsHere() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var events: [GeminiLiveProtocol.ServerEvent] = []
        session.onEvent = { events.append($0) }
        session.agentSetup = { .init(instructions: "Be brief.", functions: GeminiLiveToolBridge.declarations(webSearch: false)) }
        session.start()
        await localLiveSettle(until: { (sockets().first?.sent.count ?? 0) >= 2 })
        let socket = try XCTUnwrap(sockets().first)
        XCTAssertEqual(socket.sent.prefix(2).map { $0["type"] as? String }, ["session.update", "conduit.agent"],
                       "the plugin has the tools before the readiness check")
        XCTAssertNil((socket.sent[0]["session"] as? [String: Any])?["tools"], "the speech server never sees a tool")
        socket.deliver(["type": "session.updated"])
        try await passLocalLiveReadiness(socket, session: session)

        socket.deliver(["type": "conduit.tool.call", "call_id": "ll1", "name": "list_jobs", "arguments": "{}"])
        await localLiveSettle(until: { !events.isEmpty })
        XCTAssertEqual(events, [.toolCall([GeminiLiveProtocol.FunctionCall(id: "ll1", name: "list_jobs", arguments: [:])])])

        let before = socket.sent.count
        session.send(.toolResponse(id: "ll1", name: "list_jobs", result: ["jobs": "none"], scheduling: nil))
        session.send(.contextNote("typed in the chat"))
        await localLiveSettle(until: { socket.sent.count >= before + 2 })
        XCTAssertEqual(socket.sent[before]["type"] as? String, "conduit.tool.result")
        XCTAssertEqual(socket.sent[before]["call_id"] as? String, "ll1")
        XCTAssertEqual(socket.sent[before]["speak"] as? Bool, true)
        XCTAssertEqual(socket.sent[before + 1]["type"] as? String, "conduit.agent.note")

        // An answer the fast model stopped waiting for is said as an update.
        socket.deliver(["type": "conduit.tool.late", "call_id": "ll1"])
        await localLiveSettle(until: { socket.sent.count >= before + 4 })
        XCTAssertEqual(socket.sent.suffix(2).map { $0["type"] as? String }, ["conversation.item.create", "response.create"])
        let item = try XCTUnwrap(socket.sent[before + 2]["item"] as? [String: Any])
        let text = try XCTUnwrap(((item["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertTrue(text.contains("list_jobs") && text.contains("jobs: none"), text)
        session.stop()
    }

    func testLocalLiveSessionAnswersThePluginsTurnsOnTheSameSocket() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var turns: [String] = []
        session.onTurn = { id, text in turns.append("\(id):\(text)") }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        XCTAssertEqual(socket.sent.first?["type"] as? String, "session.update")
        XCTAssertEqual(session.state, .connecting)

        socket.deliver(["type": "session.created"])
        socket.deliver(["type": "session.updated", "session": [String: Any]()])
        try await passLocalLiveReadiness(socket, session: session)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(turns, [], "the readiness check's ask isn't a turn of the call")

        socket.deliver(["type": "conduit.turn", "turn_id": "t1", "text": "What's on today?"])
        await localLiveSettle(until: { !turns.isEmpty })
        XCTAssertEqual(turns, ["t1:What's on today?"])

        session.sendTurnDelta("t9", text: "not a turn of this call")
        session.sendTurnDelta("t1", text: "Two meetings.")
        session.sendTurnDone("t1")
        session.sendTurnDelta("t1", text: "too late")
        await localLiveSettle(until: { socket.sent.count >= 5 })
        let frames = socket.sent.dropFirst(3).map { "\($0["type"] as? String ?? ""):\($0["turn_id"] as? String ?? ""):\($0["text"] as? String ?? "")" }
        XCTAssertEqual(frames, ["conduit.turn.delta:t1:Two meetings.", "conduit.turn.done:t1:"])
        session.stop()
    }

    func testLocalLiveSessionSendsTypedTurnsForAnAnswerAndKeepsContextNotesBack() async throws {
        let (session, sockets) = makeLocalLiveSession()
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        try await passLocalLiveReadiness(socket, session: session)

        var notesSent = 0
        session.send(.contextNote("typed in the chat"), onSent: { notesSent += 1 }, onFailure: nil)
        XCTAssertEqual(notesSent, 1, "Hermes has the chat: the note is settled without going out")
        session.send(.textTurn("Remind me at five"))
        await localLiveSettle(until: { socket.sent.count >= 5 })
        XCTAssertEqual(socket.sent.dropFirst(3).map { $0["type"] as? String }, ["conversation.item.create", "response.create"])
        session.stop()
    }

    func testLocalLiveSessionTellsTheServerTheUserStoppedTheReplyAheadOfTheirAudio() async throws {
        let (session, sockets) = makeLocalLiveSession()
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        session.cancelResponse()
        socket.deliver(["type": "session.updated"])
        try await passLocalLiveReadiness(socket, session: session)
        XCTAssertFalse(socket.sent.contains { $0["type"] as? String == "response.cancel" }, "nothing goes out before the call is ready")
        // The check's answer is written after the call went ready.
        await localLiveSettle(until: { socket.sent.contains { $0["type"] as? String == "conduit.turn.done" } })

        // The Interrupt button, then the user speaking again (#1325): a
        // server that shuts its microphone while it speaks opens it first.
        let before = socket.sent.count
        session.cancelResponse()
        session.send(.audio(Data(repeating: 1, count: 640)))
        await localLiveSettle(until: { socket.sent.count >= before + 2 })
        XCTAssertEqual(socket.sent.dropFirst(before).map { $0["type"] as? String }, ["response.cancel", "input_audio_buffer.append"])
        session.stop()
        session.cancelResponse()
        XCTAssertEqual(socket.sent.count, before + 2, "a stopped call sends nothing")
    }

    func testLocalLiveSessionDropsOpenTurnsWhenItsConnectionEnds() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var dropped = 0
        var replaced = 0
        session.onTurnsDropped = { dropped += 1 }
        session.onConnectionReplaced = { replaced += 1 }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let first = try XCTUnwrap(sockets().first)
        first.deliver(["type": "session.updated"])
        try await passLocalLiveReadiness(first, session: session)
        var turns = 0
        session.onTurn = { _, _ in turns += 1 }
        first.deliver(["type": "conduit.turn", "turn_id": "t1", "text": "Hello"])
        await localLiveSettle(until: { turns == 1 })

        first.serverClose(nil)
        await localLiveSettle(until: { sockets().count == 2 && sockets()[1].sent.isEmpty == false })
        XCTAssertEqual(dropped, 1)
        let second = try XCTUnwrap(sockets().last)
        second.deliver(["type": "session.updated"])
        XCTAssertEqual(replaced, 0, "not back until the new connection passes its readiness check")
        try await passLocalLiveReadiness(second, session: session)
        await localLiveSettle(until: { replaced == 1 })
        XCTAssertEqual(replaced, 1)
        await localLiveSettle(until: { second.sent.count >= 3 })

        session.sendTurnDelta("t1", text: "for the old connection")
        await Task.yield()
        XCTAssertEqual(second.sent.count, 3, "a turn from the dropped connection can't be answered on the new one")
        session.stop()
    }

    func testLocalLiveSessionConnectsUntilTheServerAsksHermesForTheCheck() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var turns: [String] = []
        var events: [GeminiLiveProtocol.ServerEvent] = []
        session.onTurn = { id, _ in turns.append(id) }
        session.onEvent = { events.append($0) }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        let marker = try await localLiveReadinessMarker(socket)
        XCTAssertTrue(marker.hasPrefix("conduit-ready-"), marker)
        let check = try XCTUnwrap(socket.sent.last)
        XCTAssertEqual((check["response"] as? [String: Any])?["conversation"] as? String, "none",
                       "out of band: the call's conversation never holds the check")
        XCTAssertEqual(session.state, .connecting, "the server is set up but hasn't asked Hermes yet")
        var audioFailed = false
        session.send(.audio(Data(count: 320)), onSent: nil, onFailure: { audioFailed = true })
        XCTAssertTrue(audioFailed, "nothing goes to the server before it's ready")

        socket.deliver(["type": "response.created"])
        socket.deliver(["type": "conduit.turn", "turn_id": "t1", "text": marker])
        await localLiveSettle(until: { session.state == .ready })
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(turns, [])
        await localLiveSettle(until: { socket.sent.count >= 3 })
        XCTAssertEqual(socket.sent.last?["type"] as? String, "conduit.turn.done", "the check is answered with nothing")
        XCTAssertEqual(socket.sent.last?["turn_id"] as? String, "t1")

        // The check's own response finishing isn't a turn of the call.
        socket.deliver(["type": "response.output_audio_transcript.delta", "delta": "stray"])
        socket.deliver(["type": "response.done"])
        socket.deliver(["type": "response.output_audio_transcript.delta", "delta": "Hello"])
        await localLiveSettle(until: { !events.isEmpty })
        XCTAssertEqual(events, [.outputTranscription("Hello")])
        session.stop()
    }

    func testLocalLiveSessionKeepsARetriedCheckOutOfTheChatAndPlaysTheFirstReply() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var turns: [String] = []
        var events: [GeminiLiveProtocol.ServerEvent] = []
        session.onTurn = { id, _ in turns.append(id) }
        session.onEvent = { events.append($0) }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        let marker = try await localLiveReadinessMarker(socket)
        socket.deliver(["type": "conduit.turn", "turn_id": "t1", "text": marker])
        await localLiveSettle(until: { session.state == .ready })

        // The server retries the check's ask: answered with nothing again.
        socket.deliver(["type": "conduit.turn", "turn_id": "t2", "text": marker])
        await localLiveSettle(until: { socket.sent.count >= 4 })
        XCTAssertEqual(socket.sent.last?["turn_id"] as? String, "t2")
        XCTAssertEqual(turns, [])

        // The user's first turn, with the check's response.done never seen:
        // its reply still plays.
        socket.deliver(["type": "conduit.turn", "turn_id": "t3", "text": "What's on today?"])
        socket.deliver(["type": "response.output_audio_transcript.delta", "delta": "Two meetings."])
        await localLiveSettle(until: { !events.isEmpty })
        XCTAssertEqual(turns, ["t3"])
        XCTAssertEqual(events, [.outputTranscription("Two meetings.")])
        session.stop()
    }

    func testLocalLiveSessionSaysTheGreetingAsTheCheckAnswerOncePerCall() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var events: [GeminiLiveProtocol.ServerEvent] = []
        session.onEvent = { events.append($0) }
        session.greeting = { "Hello there." }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let first = try XCTUnwrap(sockets().first)
        first.deliver(["type": "session.updated"])
        try await passLocalLiveReadiness(first, session: session)
        await localLiveSettle(until: { first.sent.count >= 4 })
        let answer = first.sent.dropFirst(2).map { "\($0["type"] as? String ?? ""):\($0["text"] as? String ?? "")" }
        XCTAssertEqual(answer, ["conduit.turn.delta:Hello there.", "conduit.turn.done:"])
        // The greeting is the call's own reply: it plays.
        first.deliver(["type": "response.output_audio_transcript.delta", "delta": "Hello there."])
        await localLiveSettle(until: { !events.isEmpty })
        XCTAssertEqual(events, [.outputTranscription("Hello there.")])

        // A reconnect checks again but doesn't greet again.
        first.serverClose(nil)
        await localLiveSettle(until: { sockets().count == 2 && sockets()[1].sent.isEmpty == false })
        let second = try XCTUnwrap(sockets().last)
        second.deliver(["type": "session.updated"])
        try await passLocalLiveReadiness(second, session: session)
        await localLiveSettle(until: { second.sent.count >= 3 })
        XCTAssertEqual(second.sent.dropFirst(2).map { $0["type"] as? String }, ["conduit.turn.done"])
        session.stop()
    }

    /// The upsampler is the connection's: a dropped connection's held
    /// sample never reaches the next connection's first chunk.
    func testLocalLiveReconnectStartsTheMicrophoneStreamAfresh() async throws {
        let (session, sockets) = makeLocalLiveSession()
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let first = try XCTUnwrap(sockets().first)
        first.deliver(["type": "session.updated"])
        try await passLocalLiveReadiness(first, session: session)
        // 1, 3 go out as 1, 2; the 3 is held for the next chunk.
        session.send(.audio(Data([1, 0, 3, 0])))
        await localLiveSettle(until: { first.sent.last?["type"] as? String == "input_audio_buffer.append" })

        first.serverClose(nil)
        await localLiveSettle(until: { sockets().count == 2 && sockets()[1].sent.isEmpty == false })
        let second = try XCTUnwrap(sockets().last)
        second.deliver(["type": "session.updated"])
        try await passLocalLiveReadiness(second, session: session)
        session.send(.audio(Data([5, 0])))
        await localLiveSettle(until: { second.sent.last?["type"] as? String == "input_audio_buffer.append" })
        XCTAssertEqual(second.sent.last?["audio"] as? String, Data([5, 0]).base64EncodedString(), "Nothing held from the dropped connection")
        session.stop()
    }

    func testLocalLiveSessionFailsWhenTheServerAnswersWithoutAskingHermes() async throws {
        let (session, sockets) = makeLocalLiveSession()
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        _ = try await localLiveReadinessMarker(socket)
        // A model address that isn't this profile's plugin answers by itself.
        socket.deliver(["type": "response.created"])
        socket.deliver(["type": "response.output_audio_transcript.done", "transcript": "Conduit isn't in a Local Live call right now."])
        socket.deliver(["type": "response.done"])
        await localLiveSettle(until: { if case .failed = session.state { return true }; return false })
        XCTAssertEqual(session.state, .failed(LocalLiveProtocol.answeredWithoutHermesReason))
    }

    func testLocalLiveSessionFailsWhenTheServerNeverAsksHermes() async throws {
        let (session, sockets) = makeLocalLiveSession(readinessTimeout: .milliseconds(50))
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        _ = try await localLiveReadinessMarker(socket)
        await localLiveSettle(until: { if case .failed = session.state { return true }; return false })
        XCTAssertEqual(session.state, .failed(LocalLiveProtocol.readinessTimedOutReason))
    }

    func testLocalLiveSessionGoesReadyWhenTheServerCantTakeTheCheck() async throws {
        let (session, sockets) = makeLocalLiveSession()
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        _ = try await localLiveReadinessMarker(socket)
        socket.deliver(["type": "error", "error": ["message": "Unsupported conversation"]])
        await localLiveSettle(until: { session.state == .ready })
        XCTAssertEqual(session.state, .ready)
        session.stop()
    }

    func testLocalLiveFilesTheDefaultProfileTheWayItsKeyNamesIt() throws {
        XCTAssertEqual(LocalLiveProtocol.profileQueryItems("default"), [], "the key for the dashboard's own profile names no profile")
        XCTAssertEqual(LocalLiveProtocol.profileQueryItems(""), [])
        XCTAssertEqual(LocalLiveProtocol.profileQueryItems("work"), [URLQueryItem(name: "profile", value: "work")])
        let request = try HermesVoiceGateway.speechServerSpeechRequest(
            baseURL: "https://hermes.example", ticket: "t", profile: "default", cloudflareAccess: nil)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(items.first { $0.name == "profile" })
        XCTAssertEqual(items.first { $0.name == "mode" }?.value, "speak")
    }

    func testVoiceRoutesNameAnotherProfileAsConduitProfileWhenThePluginTakesIt() throws {
        // Hermes 0.22.3+ sends ?profile=<another profile> to that profile's
        // plugin host, which has no sockets (#1336).
        var plugin = NotifierPluginStatus()
        XCTAssertEqual(plugin.dashboardProfileParameter, "profile", "not asked yet: as before")
        plugin.state = .reported(version: "0.89.0", capabilities: ["local-live"])
        XCTAssertEqual(plugin.dashboardProfileParameter, "profile", "an older plugin keeps ?profile=")
        plugin.state = .reported(version: "0.90.0", capabilities: ["local-live", DashboardPath.dashboardProfilesCapability])
        XCTAssertEqual(plugin.dashboardProfileParameter, DashboardPath.conduitProfileParameter)

        XCTAssertEqual(DashboardPath.withProfile(LocalLiveProtocol.statusPath, profile: "work", parameter: "conduit_profile"),
                       LocalLiveProtocol.statusPath + "?conduit_profile=work")
        XCTAssertEqual(DashboardPath.withProfile(LocalLiveProtocol.statusPath, profile: "default", parameter: "conduit_profile"),
                       LocalLiveProtocol.statusPath, "the dashboard's own profile still goes without one")
        XCTAssertEqual(LocalLiveProtocol.profileQueryItems("work", parameter: "conduit_profile"),
                       [URLQueryItem(name: "conduit_profile", value: "work")])
        // Grok's and the listening socket: as before with ?profile=, and
        // without the dashboard's own profile with ?conduit_profile=.
        XCTAssertEqual(DashboardPath.socketProfileItems("default", parameter: "profile"),
                       [URLQueryItem(name: "profile", value: "default")])
        XCTAssertEqual(DashboardPath.socketProfileItems("default", parameter: "conduit_profile"), [])
        XCTAssertEqual(DashboardPath.socketProfileItems("work", parameter: "conduit_profile"),
                       [URLQueryItem(name: "conduit_profile", value: "work")])
        let speak = try HermesVoiceGateway.speechServerSpeechRequest(
            baseURL: "https://hermes.example", ticket: "t", profile: "work", profileParameter: "conduit_profile", cloudflareAccess: nil)
        let speakItems = URLComponents(url: try XCTUnwrap(speak.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(speakItems.first { $0.name == "conduit_profile" }?.value, "work")
        XCTAssertNil(speakItems.first { $0.name == "profile" })
        let listen = try HermesVoiceGateway.speechServerRequest(
            baseURL: "https://hermes.example", ticket: "t", profile: "work", profileParameter: "conduit_profile", cloudflareAccess: nil)
        let listenItems = URLComponents(url: try XCTUnwrap(listen.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(listenItems.first { $0.name == "conduit_profile" }?.value, "work")
        XCTAssertNil(listenItems.first { $0.name == "profile" })
    }

    func testLocalLiveSetupCopiesAsOneBlockForAnAgent() throws {
        let status = SpeechServerVoiceStatus(response: [
            "available": true,
            "model_path": "/api/plugins/conduit_push/local-live/v1",
            "model_name": "conduit",
            "api_key": "cll1.-.secret",
            "speech_server": ["url": "ws://10.0.0.5:8765/v1/realtime"],
        ], dashboardBaseURL: "https://hermes.example")
        let setup = try XCTUnwrap(status.agentSetupText)
        XCTAssertTrue(setup.contains("ws://10.0.0.5:8765/v1/realtime"))
        XCTAssertTrue(setup.contains("base URL: https://hermes.example/api/plugins/conduit_push/local-live/v1"))
        XCTAssertTrue(setup.contains("API key: cll1.-.secret"))
        XCTAssertTrue(setup.contains(try XCTUnwrap(status.serverFlags)))
        XCTAssertTrue(setup.contains("--num_pipelines 2"))
        XCTAssertNil(SpeechServerVoiceStatus(unavailable: "No key").agentSetupText)
    }

    func testLocalLiveSessionFailsWhenTheServerRefusesTheSetup() async throws {
        let (session, sockets) = makeLocalLiveSession()
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "error", "error": ["message": "Only 'realtime' session type is supported"]])
        await localLiveSettle(until: { if case .failed = session.state { return true }; return false })
        guard case .failed(let message) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertTrue(message.contains("Only 'realtime' session type is supported"), message)
    }
}

// MARK: - Turns

@MainActor
private final class LocalLiveTurnScript {
    var busy = false
    var chat = LocalLiveTurnRunner.Chat(runtimeID: "rt-1")
    var submission: LocalLiveTurnRunner.Submission = .started(runtimeID: "rt-1")
    var redirectResult: VoiceRedirectResult = .redirected
    var busyReadFails = false
    /// Runs while a correction is on its way to Hermes.
    var duringRedirect: (() -> Void)?
    private(set) var submitted: [String] = []
    private(set) var redirected: [String] = []
    private(set) var spoken: [String] = []
    private(set) var done: [String] = []
    private(set) var shown: [String] = []
    private(set) var approvalAnswers: [String] = []
    var hasScreen = true

    func makeRunner() -> LocalLiveTurnRunner {
        let runner = LocalLiveTurnRunner(backend: LocalLiveTurnRunner.Backend(
            resolveChat: { [unowned self] in self.chat },
            isBusy: { [unowned self] _ in
                if self.busyReadFails { throw URLError(.timedOut) }
                return self.busy
            },
            submit: { [unowned self] _, text in
                self.submitted.append(text)
                return self.submission
            },
            redirect: { [unowned self] _, text in
                self.redirected.append(text)
                self.duringRedirect?()
                return self.redirectResult
            },
            respondToApproval: { [unowned self] _, choice, _ in
                self.approvalAnswers.append(choice)
                return true
            }
        ))
        runner.onDelta = { [unowned self] id, text in self.spoken.append("\(id):\(text)") }
        runner.onDone = { [unowned self] id in self.done.append(id) }
        runner.onVisual = { [unowned self] markdown in
            self.shown.append(markdown)
            return self.hasScreen
        }
        return runner
    }
}

@MainActor
extension VoiceConversationControllerTests {
    func testLocalLiveYesAnswersTheApprovalTheReplyWaitsOn() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Clear the old logs")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        let approval = ApprovalActivity(sessionId: "rt-1", requestId: "req-1", command: "rm -rf logs/old",
                                        description: "Delete the old logs", choices: nil, allowPermanent: false,
                                        smartDenied: false, status: .pending, choice: nil, error: nil)
        runner.observe(.approval(sessionId: "rt-1", activity: approval))
        XCTAssertTrue(script.spoken.last?.contains("Delete the old logs") == true, "the call says what it asks")

        // The yes answers it: it isn't put into the paused reply or sent as a turn.
        runner.start(turnID: "t2", text: "Yes")
        await localLiveSettle(until: { !script.approvalAnswers.isEmpty })
        XCTAssertEqual(script.approvalAnswers, ["once"])
        XCTAssertEqual(script.redirected, [])
        XCTAssertEqual(script.submitted, ["Clear the old logs"])
        // The reply goes on and answers the turn that said yes.
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Done."))
        XCTAssertEqual(script.spoken.last, "t2:Done.")
    }

    func testLocalLiveTurnStreamsHermesReplyAsItIsWritten() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "  What's on today?  ")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        XCTAssertEqual(script.submitted, ["What's on today?"])

        runner.observe(.messageDelta(sessionId: "other-chat", text: "not this call's"))
        runner.observe(.messageStart(sessionId: "rt-1"))
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Two "))
        runner.observe(.messageDelta(sessionId: "rt-1", text: "meetings."))
        XCTAssertEqual(script.spoken, ["t1:Two ", "t1:meetings."])
        XCTAssertEqual(script.done, [])
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Two meetings.", reasoning: nil))
        XCTAssertEqual(script.spoken, ["t1:Two ", "t1:meetings."], "the reply isn't said twice")
        XCTAssertEqual(script.done, ["t1"])
        XCTAssertFalse(runner.isFollowingReply)
    }

    func testLocalLiveTurnLeavesNarratedActionsOutOfSpeech() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Is it done?")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        let chunks = ["Order! *sets", " down the gav", "el* The heist ", "is done, 5 * 3", " ways."]
        for chunk in chunks {
            runner.observe(.messageDelta(sessionId: "rt-1", text: chunk))
        }
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: chunks.joined(), reasoning: nil))
        // A dropped action leaves a space, which can double across deltas.
        let said = script.spoken.map { $0.replacingOccurrences(of: "t1:", with: "") }.joined()
            .replacingOccurrences(of: "  ", with: " ")
        XCTAssertEqual(said, "Order! The heist is done, 5 * 3 ways.", "the action is left out, the spaced * is said")
        XCTAssertEqual(script.done, ["t1"])
    }

    func testLocalLiveSaysHeldWordsBeforeTheCallsOwnLine() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Clear the old logs")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Let me check *the calendar for"))
        let approval = ApprovalActivity(sessionId: "rt-1", requestId: "req-1", command: "rm -rf logs/old",
                                        description: "Delete the old logs", choices: nil, allowPermanent: false,
                                        smartDenied: false, status: .pending, choice: nil, error: nil)
        runner.observe(.approval(sessionId: "rt-1", activity: approval))
        let said = script.spoken.map { $0.replacingOccurrences(of: "t1:", with: "") }.joined()
        XCTAssertTrue(said.hasPrefix("Let me check *the calendar for\n"), "an unclosed marker's words are said, not dropped")
        XCTAssertTrue(said.contains("Delete the old logs"))
    }

    func testLocalLiveTurnShowsWhatsToBeSeenAndSaysTheRest() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Weather this week?")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        let reply = "Mild all week.\n| Day | High |\n|---|---|\n| Mon | 20 |\nSee [the forecast](https://example.com/f)."
        for chunk in stride(from: 0, to: reply.count, by: 4) {
            let start = reply.index(reply.startIndex, offsetBy: chunk)
            let end = reply.index(start, offsetBy: 4, limitedBy: reply.endIndex) ?? reply.endIndex
            runner.observe(.messageDelta(sessionId: "rt-1", text: String(reply[start..<end])))
        }
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: reply, reasoning: nil))
        let said = script.spoken.map { $0.replacingOccurrences(of: "t1:", with: "") }.joined()
        XCTAssertEqual(said, "Mild all week.\nSee the forecast.\n" + LocalLiveTurnRunner.onScreenLine)
        XCTAssertEqual(script.shown, ["| Day | High |\n|---|---|\n| Mon | 20 |\n\n- [the forecast](https://example.com/f)"])
        XCTAssertEqual(script.done, ["t1"])
    }

    func testLocalLiveTurnDoesntShowWhatHermesShowedOrHasNoScreenFor() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Show me the table")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.observe(.toolStart(sessionId: "rt-1", toolName: PresentedCard.toolName, toolInput: nil))
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "It's up.\n| a |", reasoning: nil))
        XCTAssertEqual(script.shown, [], "conduit_show already put it on screen")
        XCTAssertEqual(script.spoken, ["t1:It's up.\n"])

        script.hasScreen = false
        runner.start(turnID: "t2", text: "And the code?")
        await localLiveSettle(until: { script.submitted.count == 2 })
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: "m2", content: "Here.\n```\nx = 1\n```", reasoning: nil))
        XCTAssertEqual(script.shown, ["```\nx = 1\n```"])
        XCTAssertEqual(script.spoken.last, "t2:Here.\n", "no screen took it: the call doesn't say it's there")

        script.hasScreen = true
        runner.start(turnID: "t3", text: "And now?")
        await localLiveSettle(until: { script.submitted.count == 3 })
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: "m3", content: "Now.\n| b |", reasoning: nil))
        XCTAssertEqual(Array(script.spoken.suffix(2)), ["t3:Now.\n", "t3:" + LocalLiveTurnRunner.onScreenLine],
                       "a line already ended: no extra pause")

        // A card stands for the tables, but a file the reply attached still shows.
        runner.start(turnID: "t4", text: "And the report?")
        await localLiveSettle(until: { script.submitted.count == 4 })
        runner.observe(.toolStart(sessionId: "rt-1", toolName: PresentedCard.toolName, toolInput: nil))
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: "m4", content: "It's up.\nMEDIA:/r.pdf\n| c |", reasoning: nil))
        XCTAssertEqual(script.shown.last, "MEDIA:/r.pdf")
        XCTAssertEqual(Array(script.spoken.suffix(2)), ["t4:It's up.\n", "t4:" + LocalLiveTurnRunner.onScreenLine])
        XCTAssertEqual(script.done, ["t1", "t2", "t3", "t4"])
    }

    func testSpokenVisualSplitterGivesTheSameResultHoweverTheReplyIsSplit() {
        let reply = """
        Here's the plan, or https://example.com/plan.
        https://example.com/raw
        ```swift
        let x = 1
        ```
        Inline ![chart](https://example.com/c.png) and [a link](https://example.com/l)!
        ~~~
        open fence
        """
        func split(every size: Int) -> (String, String) {
            var splitter = SpokenVisualSplitter()
            var said = ""
            var index = reply.startIndex
            while index < reply.endIndex {
                let end = reply.index(index, offsetBy: size, limitedBy: reply.endIndex) ?? reply.endIndex
                said += splitter.feed(String(reply[index..<end]))
                index = end
            }
            said += splitter.finish()
            return (said, splitter.visualMarkdown)
        }
        let whole = split(every: reply.count)
        XCTAssertEqual(whole.0, "Here's the plan, or .\nInline  and a link!\n")
        XCTAssertEqual(whole.1, """
        - https://example.com/plan
        - https://example.com/raw

        ```swift
        let x = 1
        ```

        - ![chart](https://example.com/c.png)
        - [a link](https://example.com/l)

        ~~~
        open fence
        ~~~
        """)
        // A word ending in "h" or "ht" is said whole, at once.
        var words = SpokenVisualSplitter()
        XCTAssertEqual(words.feed("Go with"), "Go with")
        XCTAssertEqual(words.feed(" light h"), " light ")
        XCTAssertEqual(words.feed("ttps://a.b ok"), " ok")
        XCTAssertEqual(words.visualMarkdown, "- https://a.b")
        // So is a word ending in "!".
        var exclaimed = SpokenVisualSplitter()
        XCTAssertEqual(exclaimed.feed("Hello!"), "Hello!")
        XCTAssertEqual(exclaimed.feed(" See !"), " See ")
        // A fence opened with a language inside a block is content, not its end.
        var nested = SpokenVisualSplitter()
        XCTAssertEqual(nested.feed("```markdown\n```bash\nls\n"), "", "ls is still inside the block")
        XCTAssertEqual(nested.feed("```\nAfter.\n"), "After.\n")
        XCTAssertEqual(nested.visualMarkdown, "```markdown\n```bash\nls\n```")

        for size in 1...9 {
            let parts = split(every: size)
            XCTAssertEqual(parts.0, whole.0, "split every \(size)")
            XCTAssertEqual(parts.1, whole.1, "split every \(size)")
        }
    }

    func testSpokenVisualSplitterLeavesFileTagsUnsaid() {
        // Ernest's Local voice call on the farm (2026-10-28): his reply was
        // a text_to_speech file tag, which the speech server read out.
        let reply = "Here's your briefing.\nMEDIA:/opt/data/cache/audio/tts_20261028_111922_603221.mp3\nSocial media: fine, and MEDIA:/tmp/b.pdf too [[audio_as_voice]]"
        func split(every size: Int) -> String {
            var splitter = SpokenVisualSplitter()
            var said = ""
            var index = reply.startIndex
            while index < reply.endIndex {
                let end = reply.index(index, offsetBy: size, limitedBy: reply.endIndex) ?? reply.endIndex
                said += splitter.feed(String(reply[index..<end]))
                index = end
            }
            return said + splitter.finish()
        }
        let whole = split(every: reply.count)
        XCTAssertFalse(whole.contains("MEDIA"), whole)
        XCTAssertFalse(whole.contains("/opt/"), whole)
        XCTAssertFalse(whole.contains("[["), whole)
        XCTAssertTrue(whole.hasPrefix("Here's your briefing.\nSocial media: fine, and"), whole)
        for size in 1...9 {
            XCTAssertEqual(split(every: size), whole, "split every \(size)")
        }
        XCTAssertEqual(SpokenMediaTagFilter.filter("MEDIA:/opt/data/cache/audio/tts_1.mp3"), "", "only a tag: nothing said")
        XCTAssertEqual(SpokenMediaTagFilter.filter("Call me Medina, not media."), "Call me Medina, not media.")
        // The files go on the call's screen, as the chat shows them.
        var splitter = SpokenVisualSplitter()
        _ = splitter.feed(reply) + splitter.finish()
        XCTAssertEqual(splitter.visualMarkdown, "MEDIA:/opt/data/cache/audio/tts_20261028_111922_603221.mp3\nMEDIA:/tmp/b.pdf")
        // A tag written as a link is said by its label, and its file goes on
        // the screen as a file, not as a link.
        splitter.reset()
        XCTAssertEqual(splitter.feed("See [the report](MEDIA:/r.pdf) now.\n") + splitter.finish(), "See the report now.\n")
        XCTAssertEqual(splitter.visualMarkdown, "MEDIA:/r.pdf")
        // A reply the call cuts off for its own line keeps its files.
        splitter.reset()
        _ = splitter.feed("Here you go.\nMEDIA:/r.pdf\nAnd then")
        splitter.dropSpeech()
        XCTAssertEqual(splitter.fileMarkdown, "MEDIA:/r.pdf")
        XCTAssertEqual(splitter.visualMarkdown, "MEDIA:/r.pdf")
        // An image of Hermes' own on its line is a file as well.
        splitter.reset()
        _ = splitter.feed("![chart](MEDIA:/tmp/a.png)\nDone.") + splitter.finish()
        XCTAssertEqual(splitter.fileMarkdown, "![chart](MEDIA:/tmp/a.png)")
        // One with words after it is said, and its file shown.
        splitter.reset()
        XCTAssertEqual(splitter.feed("![chart](MEDIA:/tmp/a.png) Here it is.\n") + splitter.finish(), "chart Here it is.\n")
        XCTAssertEqual(splitter.fileMarkdown, "MEDIA:/tmp/a.png")
        // Windows line ends read as lines, however they arrive.
        let crlf = "Here you go.\r\nMEDIA:/r.pdf\r\nDone."
        let scalars = Array(crlf.unicodeScalars)
        for size in [1, 2, scalars.count] {
            splitter.reset()
            var said = ""
            for start in stride(from: 0, to: scalars.count, by: size) {
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: scalars[start..<min(start + size, scalars.count)])
                said += splitter.feed(String(piece))
            }
            XCTAssertEqual(said + splitter.finish(), "Here you go.\nDone.", "split every \(size)")
            XCTAssertEqual(splitter.fileMarkdown, "MEDIA:/r.pdf")
        }
    }

    func testLocalLiveTurnSaysAWholeReplyThatCameWithoutDeltas() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Hi")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Hello there.", reasoning: nil))
        XCTAssertEqual(script.spoken, ["t1:Hello there."])
        XCTAssertEqual(script.done, ["t1"])
    }

    func testLocalLiveSaysWhyATurnCouldNotGoToTheChat() {
        // #1061: the chat is open in Hermes Desktop and couldn't be taken
        // over. The call says so rather than a bare failure.
        let reason = AppLocalization.string("This chat is open in Hermes Desktop. Take it over to send from here.")
        XCTAssertEqual(LocalLiveTurnRunner.spokenFailure(for: VoiceAudioError.unavailable(reason)), reason)
        XCTAssertEqual(LocalLiveTurnRunner.spokenFailure(for: VoiceThreadBusyError()), LocalLiveTurnRunner.busyLine)
        XCTAssertEqual(LocalLiveTurnRunner.spokenFailure(for: URLError(.timedOut)), LocalLiveTurnRunner.failureLine)
    }

    func testLocalLiveTurnWaitsForNoTypedTurnAndSaysTheChatIsBusy() async {
        let script = LocalLiveTurnScript()
        script.busy = true
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Hi")
        await localLiveSettle(until: { !script.done.isEmpty })
        XCTAssertEqual(script.submitted, [], "a turn already running in the chat is never steered")
        XCTAssertEqual(script.spoken, ["t1:\(LocalLiveTurnRunner.busyLine)"])
        XCTAssertEqual(script.done, ["t1"])

        // A chat whose state can't be read isn't sent to either.
        script.busy = false
        script.busyReadFails = true
        runner.start(turnID: "t2", text: "Hi")
        await localLiveSettle(until: { script.done.count == 2 })
        XCTAssertEqual(script.submitted, [])
        XCTAssertEqual(script.spoken.last, "t2:\(LocalLiveTurnRunner.failureLine)")
    }

    func testLocalLiveSaysWhatHermesDidWithWordsItDidNotStartATurnFor() async {
        let script = LocalLiveTurnScript()
        script.submission = .notStarted(message: "Queued in the chat.")
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Hi")
        await localLiveSettle(until: { !script.done.isEmpty })
        XCTAssertEqual(script.spoken, ["t1:Queued in the chat."])
        XCTAssertFalse(runner.isFollowingReply)
    }

    func testLocalLiveTurnSpokenOverHermesGoesIntoTheRunningReply() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Check my email")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Looking"))

        // The user speaks again: the plugin cancels t1 and sends t2.
        runner.cancel(turnID: "t1")
        // The talked-over reply's words still in flight aren't t2's answer.
        script.duringRedirect = { runner.observe(.messageDelta(sessionId: "rt-1", text: " through everything")) }
        runner.start(turnID: "t2", text: "only the work inbox")
        await localLiveSettle(until: { !script.redirected.isEmpty && !runner.isCorrecting })
        script.duringRedirect = nil
        XCTAssertEqual(script.spoken, ["t1:Looking"])
        XCTAssertEqual(script.redirected, ["only the work inbox"])
        XCTAssertEqual(script.submitted, ["Check my email"], "no second turn starts")

        // The marker for the cut-off words isn't the reply's end.
        runner.observe(.messageInterrupted(sessionId: "rt-1"))
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: nil, reasoning: nil))
        XCTAssertEqual(script.done, ["t2"], "an empty completion still ends the turn")

        script.redirectResult = .notRunning
        runner.start(turnID: "t3", text: "Thanks")
        await localLiveSettle(until: { script.submitted.count == 2 })
        XCTAssertEqual(script.redirected.count, 1, "nothing was running to redirect into")
        XCTAssertEqual(script.submitted.last, "Thanks")
    }

    func testLocalLiveTurnsRunOneAtATimeAndSkipOnesTheUserTalkedOver() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Check my email")
        await localLiveSettle(until: { !script.submitted.isEmpty })

        // Two turns back to back: the first was let go before it ran.
        runner.start(turnID: "t2", text: "only the work")
        runner.start(turnID: "t3", text: "only the work inbox")
        await localLiveSettle(until: { !script.redirected.isEmpty && !runner.isCorrecting })
        // t2 ran before t3 in the chain: it is settled too.
        XCTAssertEqual(script.redirected, ["only the work inbox"])
        XCTAssertEqual(script.submitted, ["Check my email"])
    }

    func testLocalLiveCancelledTurnStopsSpeakingButHermesKeepsWorking() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Plan my week")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.cancel(turnID: "t1")
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Monday…"))
        XCTAssertEqual(script.spoken, [])
        XCTAssertTrue(runner.isFollowingReply, "the reply still lands in the chat")
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Monday…", reasoning: nil))
        XCTAssertEqual(script.done, [], "the plugin already let the cancelled turn go")
        XCTAssertFalse(runner.isFollowingReply)
    }

    func testLocalLiveTurnSaysWhenHermesRanIntoAnError() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Delete the old files")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.observe(.messageError(sessionId: "other", message: "x"))
        XCTAssertEqual(script.done, [])
        runner.observe(.messageError(sessionId: "rt-1", message: "Provider timeout"))
        XCTAssertEqual(script.spoken, ["t1:\(LocalLiveTurnRunner.errorLine)"])
        XCTAssertEqual(script.done, ["t1"])

        runner.start(turnID: "t2", text: "Try again")
        await localLiveSettle(until: { script.submitted.count == 2 })
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Here's the table:\n| a |"))
        runner.observe(.messageError(sessionId: "rt-1", message: "Provider timeout"))
        XCTAssertEqual(Array(script.spoken.suffix(2)), ["t2:Here's the table:\n", "t2:\(LocalLiveTurnRunner.errorLine)"],
                       "what the broken reply still held isn't said after the call's line")
        XCTAssertEqual(script.shown, [])
    }
}

// MARK: - Mode

@MainActor
extension AppStateVoiceCapabilityTests {
    func testLocalLiveIsOneLiveModeAndOpensItsOwnSheet() async {
        let defaults = makeScratchDefaults("LocalLiveAppState")
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
        XCTAssertFalse(appState.isLocalLiveEnabled, "Off by default")
        XCTAssertNil(appState.configuredLiveVoiceEngine(profile: appState.activeProfile))

        appState.setGrokLiveEnabled(true)
        appState.setLocalLiveEnabled(true)
        XCTAssertTrue(appState.isLocalLiveEnabled)
        XCTAssertFalse(appState.isGrokLiveEnabled, "turning Local Live on turns the others off")
        XCTAssertEqual(appState.configuredLiveVoiceEngine(profile: appState.activeProfile), .localLive)
        XCTAssertNil(appState.phoneVoiceUnavailableReason, "Local Live does not need Hermes speech providers")

        let opened = await appState.openVoiceConversation(
            PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(opened)
        XCTAssertTrue(appState.showLocalLiveSheet)
        XCTAssertFalse(appState.showVoiceSheet)

        appState.setGeminiLiveEnabled(true)
        XCTAssertFalse(appState.isLocalLiveEnabled)
        XCTAssertFalse(appState.showLocalLiveSheet, "another live mode closes Local Live")
    }

    func testLocalLiveAgentModeGivesTheFastModelGrokLivesTools() {
        let defaults = makeScratchDefaults("LocalLiveAgent")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.setLocalLiveEnabled(true)
        XCTAssertFalse(appState.isLocalLiveAgent)
        XCTAssertNil(appState.localLiveAgentSetup(), "Classic's hands-free option: Hermes answers each turn")

        appState.setLocalLiveAgent(true)
        let setup = appState.localLiveAgentSetup()
        let names = setup?.functions.map(\.name) ?? []
        XCTAssertTrue(names.contains("start_job") && names.contains("list_jobs") && names.contains("cancel_job"), "\(names)")
        XCTAssertTrue(setup?.instructions.contains("call start_job") == true)
        XCTAssertEqual(appState.configuredLiveVoiceEngine(profile: appState.activeProfile), .localLive)
    }

    func testHermesSettingLocalVoiceModeMeansAgentModeAndClassicKeepsHandsFree() throws {
        let defaults = makeScratchDefaults("LocalLiveVoiceMode")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let mode = try XCTUnwrap(appState.agentSettingsCatalog.first { $0.key == "voice.mode" })

        appState.setLocalLiveEnabled(true)
        XCTAssertEqual(mode.read(), .string("classic"), "the hands-free option is part of Classic")
        mode.write(.string("classic"))
        XCTAssertTrue(appState.isLocalLiveEnabled, "choosing Classic keeps its hands-free option")

        mode.write(.string("local"))
        XCTAssertTrue(appState.isLocalLiveAgent)
        XCTAssertEqual(mode.read(), .string("local"))

        mode.write(.string("classic"))
        XCTAssertFalse(appState.isLocalLiveEnabled)
        XCTAssertEqual(mode.read(), .string("classic"))
    }

    func testLocalLivePreferenceDecodesOffFromOlderBlobs() throws {
        let old = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(old.localLiveEnabled)
        XCTAssertFalse(old.localLiveAgent, "an existing Local Live call stays one Hermes turn per utterance")
        var preferences = VoiceProfilePreferences()
        preferences.localLiveEnabled = true
        let roundTrip = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(roundTrip.localLiveEnabled)
    }
}
