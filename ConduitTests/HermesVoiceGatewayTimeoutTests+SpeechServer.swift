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
