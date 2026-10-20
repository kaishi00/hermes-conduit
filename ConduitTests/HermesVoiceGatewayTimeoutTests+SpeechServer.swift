//
//  HermesVoiceGatewayTimeoutTests+SpeechServer.swift
//  Conduit
//
//  The user's own speech server (OpenAI Realtime, through the notifier's
//  relay): transcription-only session.update first, 24 kHz audio frames,
//  trailing silence and a commit at the end of speech, and every finished
//  segment joined into the transcript.
//

import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    func testSpeechServerAsksForTranscriptionOnlyAndJoinsFinishedSegments() async throws {
        let socket = SpeechServerSocket()
        var partials: [String] = []
        let live = SpeechServerTranscription(
            socket: socket,
            sampleRate: 16_000,
            onPartial: { partials.append($0) }
        )
        live.push(Data([1, 0, 2, 0]))
        let sentAudio = await Self.speechServerEventually { socket.sentTypes.count >= 2 }
        XCTAssertTrue(sentAudio)

        let update = try XCTUnwrap(socket.sentObjects.first)
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24_000)
        let turnDetection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(turnDetection["create_response"] as? Bool, false)

        // 2 captured samples at 16 kHz become 3 at 24 kHz.
        let append = socket.sentObjects[1]
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        let audio = try XCTUnwrap(Data(base64Encoded: append["audio"] as? String ?? ""))
        XCTAssertEqual(audio.count, 6)

        socket.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"a"}"#)
        socket.deliver(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"turn on"}"#)
        let sawPartial = await Self.speechServerEventually { partials.last == "turn on" }
        XCTAssertTrue(sawPartial)
        socket.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":" turn on the lights "}"#)
        socket.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"b"}"#)
        // The second segment is under way (its delta follows speech_started)
        // before the end of speech.
        socket.deliver(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"b","delta":"in the"}"#)
        let sawSecond = await Self.speechServerEventually { partials.last == "turn on the lights in the" }
        XCTAssertTrue(sawSecond)

        let finishing = Task { await live.finish() }
        let committed = await Self.speechServerEventually { socket.sentTypes.last == "input_audio_buffer.commit" }
        XCTAssertTrue(committed)
        socket.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"in the kitchen"}"#)
        let transcript = await finishing.value

        XCTAssertEqual(transcript, "turn on the lights in the kitchen")
        XCTAssertEqual(socket.sentTypes.suffix(2), ["input_audio_buffer.append", "input_audio_buffer.commit"])
    }

    func testSpeechServerThatHeardNothingReturnsNilAfterTheQuietGrace() async {
        let socket = SpeechServerSocket()
        let live = SpeechServerTranscription(
            socket: socket,
            sampleRate: 16_000,
            finishTimeout: .seconds(10),
            quietGrace: .milliseconds(50),
            onPartial: { _ in }
        )
        let transcript = await live.finish()
        XCTAssertNil(transcript)
    }

    func testSpeechServerErrorBecomesTheFailureReason() async {
        let socket = SpeechServerSocket()
        var failure: String?
        let live = SpeechServerTranscription(
            socket: socket,
            sampleRate: 16_000,
            finishTimeout: .milliseconds(200),
            quietGrace: .seconds(10),
            onPartial: { _ in },
            onFailure: { failure = $0 }
        )
        socket.deliver(#"{"type":"input_audio_buffer.speech_started"}"#)
        socket.deliver(#"{"type":"error","error":{"type":"server_error","message":"STT model not loaded"}}"#)
        let transcript = await live.finish()
        XCTAssertNil(transcript)
        XCTAssertEqual(failure, "Your speech server reported: STT model not loaded")
    }

    func testSpeechServerIgnoresAnEmptyCommitRefusal() async {
        let socket = SpeechServerSocket()
        var failure: String?
        let live = SpeechServerTranscription(
            socket: socket,
            sampleRate: 16_000,
            onPartial: { _ in },
            onFailure: { failure = $0 }
        )
        socket.deliver(#"{"type":"input_audio_buffer.speech_started"}"#)
        socket.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"yes"}"#)
        let finishing = Task { await live.finish() }
        socket.deliver(#"{"type":"error","error":{"type":"invalid_request_error","code":"input_audio_buffer_commit_empty","message":"Input audio buffer is empty, nothing to commit."}}"#)
        let transcript = await finishing.value
        XCTAssertEqual(transcript, "yes")
        XCTAssertNil(failure)
    }

    func testSpeechServerSplitsABacklogIntoFramesUnderTheRelayCap() async {
        let socket = SpeechServerSocket()
        let live = SpeechServerTranscription(socket: socket, sampleRate: 16_000, onPartial: { _ in })
        // 2.5 s of captured audio: three frames of at most a second each.
        live.push(Data(count: 16_000 * 2 * 5 / 2))
        let sent = await Self.speechServerEventually { socket.sentTypes.count == 4 }
        XCTAssertTrue(sent)
        for frame in socket.sentObjects.dropFirst() {
            let audio = Data(base64Encoded: frame["audio"] as? String ?? "") ?? Data()
            XCTAssertLessThanOrEqual(audio.count, 24_000 * 2)
        }
        live.cancel()
    }

    func testSpeechServerLostConnectionFailsWithAReason() async {
        let socket = SpeechServerSocket()
        var failure: String?
        let live = SpeechServerTranscription(
            socket: socket,
            sampleRate: 16_000,
            onPartial: { _ in },
            onFailure: { failure = $0 }
        )
        socket.cancel(with: .abnormalClosure, reason: nil)
        let transcript = await live.finish()
        XCTAssertNil(transcript)
        XCTAssertEqual(failure, "Lost the connection to your speech server.")
    }

    /// The server finished every segment it started, with no words, and
    /// closed during the quiet grace: nothing was heard, which is no
    /// failure.
    func testSpeechServerClosingAfterAnEmptyFinishedSegmentIsNotAFailure() async {
        let socket = SpeechServerSocket()
        var failure: String?
        let live = SpeechServerTranscription(
            socket: socket,
            sampleRate: 16_000,
            finishTimeout: .seconds(10),
            quietGrace: .seconds(5),
            onPartial: { _ in },
            onFailure: { failure = $0 }
        )
        socket.deliver(#"{"type":"input_audio_buffer.speech_started","item_id":"a"}"#)
        socket.deliver(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":""}"#)
        let finishing = Task { await live.finish() }
        let committed = await Self.speechServerEventually { socket.sentTypes.last == "input_audio_buffer.commit" }
        XCTAssertTrue(committed)
        socket.cancel(with: .abnormalClosure, reason: nil)
        let transcript = await finishing.value
        XCTAssertNil(transcript)
        XCTAssertNil(failure)
    }

    func testSpeechServerFailedSegmentClearsItsWordsFromTheScreen() async {
        let socket = SpeechServerSocket()
        var partials: [String] = []
        let live = SpeechServerTranscription(socket: socket, sampleRate: 16_000, onPartial: { partials.append($0) })
        socket.deliver(#"{"type":"input_audio_buffer.speech_started"}"#)
        socket.deliver(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"mumble"}"#)
        socket.deliver(#"{"type":"conversation.item.input_audio_transcription.failed","error":{"message":"no speech"}}"#)
        let cleared = await Self.speechServerEventually { partials == ["mumble", ""] }
        XCTAssertTrue(cleared)
        live.cancel()
    }

    func testSpeechServerFinishReturnsWhenItsTaskIsCancelled() async {
        let socket = SpeechServerSocket()
        let live = SpeechServerTranscription(
            socket: socket,
            sampleRate: 16_000,
            finishTimeout: .seconds(30),
            quietGrace: .seconds(30),
            onPartial: { _ in }
        )
        socket.deliver(#"{"type":"input_audio_buffer.speech_started"}"#)
        let finishing = Task { await live.finish() }
        let committed = await Self.speechServerEventually { socket.sentTypes.last == "input_audio_buffer.commit" }
        XCTAssertTrue(committed)
        finishing.cancel()
        let transcript = await finishing.value
        XCTAssertNil(transcript)
    }

    func testSpeechServerResamplesOtherCaptureRatesTo24kHz() {
        let second48k = Data(count: 48_000 * 2)
        XCTAssertEqual(SpeechServerTranscription.resampled(second48k, from: 48_000).count, 24_000 * 2)
        let second16k = Data(count: 16_000 * 2)
        XCTAssertEqual(SpeechServerTranscription.resampled(second16k, from: 16_000).count, 24_000 * 2)
        let same = Data([1, 0, 2, 0])
        XCTAssertEqual(SpeechServerTranscription.resampled(same, from: 24_000), same)
    }

    func testSpeechServerStatusAndTestParseTheNotifierReplies() {
        let status = SpeechServerStatus(response: [
            "ok": true, "configured": true, "available": false, "url": NSNull(),
            "has_key": true, "reason": "voice.example.com is a public address, so the speech server needs wss://.",
        ])
        XCTAssertTrue(status.configured)
        XCTAssertFalse(status.available)
        XCTAssertNil(status.url)
        XCTAssertTrue(status.hasKey)
        XCTAssertEqual(status.reason, "voice.example.com is a public address, so the speech server needs wss://.")

        let connected = SpeechServerTestResult(response: ["connected": true, "latency_ms": 42, "event": "session.created"])
        XCTAssertEqual(connected.message, "Connected. Your speech server answered in 42 ms.")
        let refused = SpeechServerTestResult(response: ["connected": false, "reason": "The speech server refused the key (HTTP 401)"])
        XCTAssertEqual(refused.message, "The speech server refused the key (HTTP 401)")
    }

    func testSpeechServerRequestUsesTheRelayPathWithTicketAndProfile() throws {
        let request = try HermesVoiceGateway.speechServerRequest(
            baseURL: "https://hermes.example.com",
            ticket: "t1",
            profile: "work",
            cloudflareAccess: nil
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/api/plugins/conduit_push/speech-server/socket")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "ticket" })?.value, "t1")
        XCTAssertEqual(items.first(where: { $0.name == "profile" })?.value, "work")
    }

    func testSpeechServerSpeechReadsEachSentenceBackInOrder() async throws {
        let socket = SpeechServerSocket()
        var started: [Double] = []
        var audio = Data()
        let stream = SpeechServerSpeechStream(
            socket: socket,
            onStart: { started.append($0) },
            onPCM16: { pcm, _ in audio.append(pcm) }
        )
        try await stream.append("Hello there. How are")
        let sentFirst = await Self.speechServerEventually { socket.sentTypes.count >= 3 }
        XCTAssertTrue(sentFirst)
        XCTAssertEqual(socket.sentTypes, ["session.update", "conversation.item.create", "response.create"])
        let session = try XCTUnwrap(socket.sentObjects[0]["session"] as? [String: Any])
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        let item = try XCTUnwrap(socket.sentObjects[1]["item"] as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Hello there.")

        // The second sentence waits for the first response to finish.
        try await stream.append(" you?")
        let finishing = Task { try await stream.finish() }
        let pcm = Data([1, 0, 2, 0]).base64EncodedString()
        socket.deliver(#"{"type":"response.output_audio_transcript.delta","delta":"Hello"}"#)
        socket.deliver(#"{"type":"response.output_audio.delta","delta":"\#(pcm)"}"#)
        socket.deliver(#"{"type":"response.output_audio_transcript.delta","delta":" there."}"#)
        socket.deliver(#"{"type":"response.done"}"#)
        let sentSecond = await Self.speechServerEventually { socket.sentTypes.count >= 5 }
        XCTAssertTrue(sentSecond)
        let second = try XCTUnwrap(socket.sentObjects[3]["item"] as? [String: Any])
        XCTAssertEqual((second["content"] as? [[String: Any]])?.first?["text"] as? String, "How are you?")
        socket.deliver(#"{"type":"response.output_audio.delta","delta":"\#(pcm)"}"#)
        socket.deliver(#"{"type":"response.output_audio_transcript.delta","delta":"how are you"}"#)
        socket.deliver(#"{"type":"response.done"}"#)

        let spoke = try await finishing.value
        XCTAssertTrue(spoke)
        XCTAssertEqual(started, [24_000])
        XCTAssertEqual(audio, Data([1, 0, 2, 0, 1, 0, 2, 0]))
    }

    func testSpeechServerSpeechDoesNotReadMarkdownMarks() async throws {
        let socket = SpeechServerSocket()
        let stream = SpeechServerSpeechStream(socket: socket, onStart: { _ in }, onPCM16: { _, _ in })
        defer { stream.cancel() }
        try await stream.append("The capital is **Québec**. More")
        let sent = await Self.speechServerEventually { socket.sentTypes.count >= 3 }
        XCTAssertTrue(sent)
        let item = try XCTUnwrap(socket.sentObjects[1]["item"] as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "The capital is Québec.")
    }

    func testSpeechServerSpeechFailsWhenTheServerAnswersInsteadOfReadingBack() async throws {
        let socket = SpeechServerSocket()
        let stream = SpeechServerSpeechStream(socket: socket, onStart: { _ in }, onPCM16: { _, _ in })
        try await stream.append("The lights are on.")
        let finishing = Task { try await stream.finish() }
        let sent = await Self.speechServerEventually { socket.sentTypes.contains("response.create") }
        XCTAssertTrue(sent)
        socket.deliver(#"{"type":"response.output_audio_transcript.delta","delta":"Sure, I can help"}"#)
        do {
            _ = try await finishing.value
            XCTFail("A server answering on its own must fail the stream")
        } catch VoiceAudioError.unavailable(let message) {
            XCTAssertTrue(message.contains("model address"))
        }
        let cancelled = await Self.speechServerEventually { socket.sentTypes.last == "response.cancel" }
        XCTAssertTrue(cancelled)
    }

    func testSpeechServerSpeechThatSendsNoAudioFails() async throws {
        let socket = SpeechServerSocket()
        let stream = SpeechServerSpeechStream(socket: socket, onStart: { _ in }, onPCM16: { _, _ in })
        try await stream.append("Hello.")
        let finishing = Task { try await stream.finish() }
        let sent = await Self.speechServerEventually { socket.sentTypes.contains("response.create") }
        XCTAssertTrue(sent)
        socket.deliver(#"{"type":"response.done"}"#)
        do {
            _ = try await finishing.value
            XCTFail("A silent response must fail so the iPhone speaks the reply")
        } catch VoiceAudioError.unavailable {}
    }

    func testSpeechServerSpeechThatEndsSilentlyBeforeFinishFails() async throws {
        let socket = SpeechServerSocket()
        let stream = SpeechServerSpeechStream(socket: socket, onStart: { _ in }, onPCM16: { _, _ in })
        // The space ends the sentence, so it goes out before finish().
        try await stream.append("Hello. ")
        let sent = await Self.speechServerEventually { socket.sentTypes.contains("response.create") }
        XCTAssertTrue(sent)
        socket.deliver(#"{"type":"response.done"}"#)
        let ended = await Self.speechServerEventually { socket.sentTypes.last == "response.cancel" }
        XCTAssertTrue(ended)
        do {
            _ = try await stream.finish()
            XCTFail("A silent response must fail so the iPhone speaks the reply")
        } catch VoiceAudioError.unavailable {}
    }

    func testSpeechServerSpeechThatReadsOnlyHalfASentenceFails() async throws {
        let socket = SpeechServerSocket()
        let stream = SpeechServerSpeechStream(socket: socket, onStart: { _ in }, onPCM16: { _, _ in })
        try await stream.append("It's 5 o'clock.")
        let finishing = Task { try await stream.finish() }
        let sent = await Self.speechServerEventually { socket.sentTypes.contains("response.create") }
        XCTAssertTrue(sent)
        let pcm = Data([1, 0]).base64EncodedString()
        socket.deliver(#"{"type":"response.output_audio.delta","delta":"\#(pcm)"}"#)
        socket.deliver(#"{"type":"response.output_audio_transcript.delta","delta":"It's 5"}"#)
        socket.deliver(#"{"type":"response.done"}"#)
        do {
            _ = try await finishing.value
            XCTFail("A half-read sentence must fail the stream")
        } catch VoiceAudioError.unavailable {}
    }

    func testSpeechServerSpeechSplitsSentencesAndComparesLoosely() {
        XCTAssertEqual(SpeechServerSpeechStream.splitSentences("One. Two").ready, "One.")
        XCTAssertEqual(SpeechServerSpeechStream.splitSentences("One. Two").rest, " Two")
        XCTAssertEqual(SpeechServerSpeechStream.splitSentences("Version 1.5 is").ready, "")
        XCTAssertEqual(SpeechServerSpeechStream.splitSentences("Line\nNext").ready, "Line\n")
        XCTAssertEqual(SpeechServerSpeechStream.splitSentences("今天很好。明天").ready, "今天很好。")
        XCTAssertEqual(SpeechServerSpeechStream.splitSentences(String(repeating: "字", count: 300)).ready.count, 280)
        XCTAssertEqual(SpeechServerVoiceStatus.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertLessThanOrEqual(SpeechServerSpeechStream.splitSentences(String(repeating: "word ", count: 400)).ready.count, 280)
        let long = String(repeating: "word ", count: 80)
        XCTAssertFalse(SpeechServerSpeechStream.splitSentences(long).ready.isEmpty)
        XCTAssertTrue(SpeechServerSpeechStream.isReadingBack("it's 5", words: "It's 5 o'clock."))
        XCTAssertTrue(SpeechServerSpeechStream.isReadingBack("", words: "Anything"))
        XCTAssertEqual(SpeechServerSpeechStream.comparable("Café"), SpeechServerSpeechStream.comparable("cafe"))
        XCTAssertEqual(SpeechServerSpeechStream.splitSentences("One. Two. Three").ready, "One.")
        XCTAssertFalse(SpeechServerSpeechStream.isReadingBack("Of course", words: "It's 5 o'clock."))
        XCTAssertFalse(SpeechServerSpeechStream.isReadingBack("It's 5 o'clock. Anything else?", words: "It's 5 o'clock."))
    }

    func testSpeechServerVoiceStatusBuildsTheModelAddressAndFlags() {
        let status = SpeechServerVoiceStatus(response: [
            "available": true, "model_path": "/api/plugins/conduit_push/local-live/v1",
            "model_name": "conduit", "api_key": "cll1.-.abc", "last_request_at": 1_700_000_000,
        ], dashboardBaseURL: "https://hermes.example.com/")
        XCTAssertEqual(status.modelAddress, "https://hermes.example.com/api/plugins/conduit_push/local-live/v1")
        XCTAssertEqual(status.lastRequestAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(
            status.serverFlags,
            "--llm_backend chat-completions --responses_api_base_url https://hermes.example.com/api/plugins/conduit_push/local-live/v1 --responses_api_api_key cll1.-.abc --model_name conduit --stream_batch_sentences 1 --num_pipelines 2"
        )
        let unavailable = SpeechServerVoiceStatus(response: ["available": false, "reason": "Set a speech server first."], dashboardBaseURL: nil)
        XCTAssertNil(unavailable.modelAddress)
        XCTAssertNil(unavailable.serverFlags)
        XCTAssertEqual(unavailable.reason, "Set a speech server first.")
        XCTAssertTrue(SpeechServerVoiceStatus.pluginMissing.pluginMissing)
    }

    func testSpeechServerSpeechRequestUsesSpeakMode() throws {
        let request = try HermesVoiceGateway.speechServerSpeechRequest(
            baseURL: "https://hermes.example.com", ticket: "t1", profile: "work", cloudflareAccess: nil)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/plugins/conduit_push/local-live/socket")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "mode" })?.value, "speak")
        XCTAssertEqual(items.first(where: { $0.name == "profile" })?.value, "work")
    }

    private static func speechServerEventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// The relay socket: records what Conduit sends and hands out whatever the
/// test delivers, parking until the next delivery.
private final class SpeechServerSocket: HermesSpeechSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var sentTexts: [String] = []
    private var cancelled = false
    private var parked: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    var sentObjects: [[String: Any]] {
        lock.withLock { sentTexts }.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    var sentTypes: [String] { sentObjects.compactMap { $0["type"] as? String } }

    func deliver(_ text: String) {
        let waiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            if let parked {
                self.parked = nil
                return parked
            }
            queued.append(.string(text))
            return nil
        }
        waiting?.resume(returning: .string(text))
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { return }
        lock.withLock { sentTexts.append(text) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let next: URLSessionWebSocketTask.Message?
            let isCancelled: Bool
            lock.lock()
            if !queued.isEmpty {
                next = queued.removeFirst()
                isCancelled = false
            } else if cancelled {
                next = nil
                isCancelled = true
            } else {
                parked = continuation
                next = nil
                isCancelled = false
            }
            lock.unlock()
            if let next {
                continuation.resume(returning: next)
            } else if isCancelled {
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pongReceiveHandler(nil)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let waiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            cancelled = true
            let waiting = parked
            parked = nil
            return waiting
        }
        waiting?.resume(throwing: URLError(.cancelled))
    }
}
