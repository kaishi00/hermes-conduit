//
//  HermesVoiceGatewayTimeoutTests+Keepalive.swift
//  Conduit
//
//  The dashboard voice sockets' keepalive (#787): a Tailscale relay or a
//  NAT drops a quiet connection without a close, so the socket's receive
//  never fails. Pings that go unanswered are how the stream finds out.
//

import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    func testLiveTranscriptionOnADeadPathGoesToTheUploadWithoutWaitingForFinish() async {
        let socket = DeadPathSocket(answersPings: false)
        var unavailable = false
        let live = HermesLiveTranscription(
            socket: socket,
            sampleRate: 16_000,
            finishTimeout: .seconds(30),
            keepaliveInterval: .milliseconds(20),
            onPartial: { _ in },
            onUnavailable: { unavailable = true }
        )
        live.push(Data([1, 0]))

        let closed = await Self.keepaliveEventually { socket.isCancelled }
        XCTAssertTrue(closed, "a socket whose pings go unanswered must be closed")
        XCTAssertGreaterThan(socket.pingCount, 0)
        // Already resolved: finish() hands the utterance to the upload now,
        // not after its 30 s timeout.
        let started = ContinuousClock.now
        let transcript = await live.finish()
        XCTAssertNil(transcript)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        // A dead path is not a verdict on the profile's live STT.
        XCTAssertFalse(unavailable)
    }

    func testLiveTranscriptionWhosePingsAreAnsweredStaysOpen() async {
        let socket = DeadPathSocket(answersPings: true)
        var partials: [String] = []
        let live = HermesLiveTranscription(
            socket: socket,
            sampleRate: 16_000,
            keepaliveInterval: .milliseconds(20),
            onPartial: { partials.append($0) },
            onUnavailable: {}
        )
        let pinged = await Self.keepaliveEventually { socket.pingCount >= 5 }
        XCTAssertTrue(pinged, "a quiet socket must be pinged")
        XCTAssertFalse(socket.isCancelled)

        socket.deliver(.string(#"{"type":"partial","text":"still here"}"#))
        let heard = await Self.keepaliveEventually { partials == ["still here"] }
        XCTAssertTrue(heard)
        live.cancel()
    }

    func testSpeechStreamOnADeadPathBeforeAudioSpeaksTheFallback() async throws {
        let socket = DeadPathSocket(answersPings: false)
        var fallbackText: String?
        var encoded: Data?
        let stream = HermesSpeechStream(
            task: socket,
            finishIdleTimeout: .seconds(30),
            keepaliveInterval: .milliseconds(20),
            fallback: { text in
                fallbackText = text
                return Data([7])
            },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { encoded = $0 }
        )
        try await stream.append("Hello there.")

        let closed = await Self.keepaliveEventually { socket.isCancelled }
        XCTAssertTrue(closed, "a speak socket whose pings go unanswered must be closed")
        // The reply is spoken by the one-shot fallback right away, not after
        // the 30 s post-finish idle window.
        let started = ContinuousClock.now
        let streamed = try await stream.finish()
        XCTAssertFalse(streamed)
        XCTAssertEqual(fallbackText, "Hello there.")
        XCTAssertEqual(encoded, Data([7]))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testSpeechStreamOnADeadPathAfterAudioFailsAtFinishWithoutWaitingForTheIdleWindow() async throws {
        let socket = DeadPathSocket(answersPings: false)
        var chunks = 0
        let stream = HermesSpeechStream(
            task: socket,
            finishIdleTimeout: .seconds(30),
            keepaliveInterval: .milliseconds(20),
            fallback: { _ in
                XCTFail("audio already played: no fallback")
                return Data()
            },
            onStart: { _ in },
            onPCM16: { _, _ in chunks += 1 },
            onEncodedAudio: { _ in }
        )
        try await stream.append("Hello there.")
        socket.deliver(.data(Data([1, 0, 2, 0])))
        let played = await Self.keepaliveEventually { chunks == 1 }
        XCTAssertTrue(played)
        let pinged = await Self.keepaliveEventually { socket.pingCount >= 2 }
        XCTAssertTrue(pinged, "a quiet speak socket must be pinged")
        // The audio already received keeps playing: the dead path is not
        // reported mid-reply, only when the reply is finished.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(socket.isCancelled)

        let started = ContinuousClock.now
        do {
            _ = try await stream.finish()
            XCTFail("a dead speak socket after audio must fail the reply")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertTrue(socket.isCancelled)
    }

    func testSpeechStreamWhoseDoneSendHangsOnADeadPathStillSpeaksTheFallback() async throws {
        let socket = DeadPathSocket(answersPings: false, sendsHang: true)
        var fallbackText: String?
        let stream = HermesSpeechStream(
            task: socket,
            finishIdleTimeout: .seconds(30),
            keepaliveInterval: .milliseconds(20),
            fallback: { text in
                fallbackText = text
                return Data([7])
            },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )
        let appending = Task { try await stream.append("Hello there.") }
        // The text send never returns on the dead path; finish() is asked
        // for while it hangs, and its {done:true} send hangs as well.
        let started = ContinuousClock.now
        let finishing = Task { try await stream.finish() }
        let streamed = try await finishing.value
        XCTAssertFalse(streamed)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        appending.cancel()
        XCTAssertEqual(fallbackText, "Hello there.")
    }

    func testABusySocketIsNeverJudgedByItsPings() async throws {
        // Pings are never answered (the pong queues behind audio on a slow
        // path), yet frames keep arriving: the socket is alive.
        let socket = DeadPathSocket(answersPings: false)
        var chunks = 0
        let stream = HermesSpeechStream(
            task: socket,
            keepaliveInterval: .milliseconds(100),
            fallback: { _ in
                XCTFail("a busy socket must not fall back")
                return Data()
            },
            onStart: { _ in },
            onPCM16: { _, _ in chunks += 1 },
            onEncodedAudio: { _ in }
        )
        try await stream.append("A long reply.")
        // Longer than the three unanswered intervals that would close a
        // quiet socket.
        for _ in 0..<80 {
            socket.deliver(.data(Data([1, 0])))
            try await Task.sleep(for: .milliseconds(5))
        }
        let played = await Self.keepaliveEventually { chunks == 80 }
        XCTAssertTrue(played)
        XCTAssertFalse(socket.isCancelled, "a socket that keeps sending frames is alive")
        stream.cancel()
    }

    func testSpeechStreamWhosePingsAreAnsweredWaitsOutAQuietReply() async throws {
        let socket = DeadPathSocket(answersPings: true)
        let stream = HermesSpeechStream(
            task: socket,
            keepaliveInterval: .milliseconds(20),
            fallback: { _ in
                XCTFail("a live socket must not fall back")
                return Data()
            },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )
        try await stream.append("Thinking out loud.")
        let pinged = await Self.keepaliveEventually { socket.pingCount >= 5 }
        XCTAssertTrue(pinged, "a quiet speak socket must be pinged")
        XCTAssertFalse(socket.isCancelled)

        let finishing = Task { try await stream.finish() }
        let sentDone = await Self.keepaliveEventually { socket.sentTexts.last == #"{"done":true}"# }
        XCTAssertTrue(sentDone)
        socket.deliver(.data(Data([1, 0])))
        socket.deliver(.string(#"{"type":"end"}"#))
        let streamed = try await finishing.value
        XCTAssertTrue(streamed)
    }

    /// A condition wait capped at 10 s; it never stands in for a fixed
    /// settling delay.
    private static func keepaliveEventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// A voice socket on a path that may have died without a close: sends
/// succeed (the bytes only reach a buffer) or, once that buffer is full,
/// never return; receive parks until the test
/// delivers or the socket is cancelled, and pings are answered only when
/// the path is alive.
private final class DeadPathSocket: HermesSpeechSocket, @unchecked Sendable {
    private let answersPings: Bool
    private let sendsHang: Bool
    private let lock = NSLock()
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var texts: [String] = []
    private var pings = 0
    private var cancelled = false
    private var parked: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    init(answersPings: Bool, sendsHang: Bool = false) {
        self.answersPings = answersPings
        self.sendsHang = sendsHang
    }

    var pingCount: Int { lock.withLock { pings } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var sentTexts: [String] { lock.withLock { texts } }

    func deliver(_ message: URLSessionWebSocketTask.Message) {
        let waiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            if let parked {
                self.parked = nil
                return parked
            }
            queued.append(message)
            return nil
        }
        waiting?.resume(returning: message)
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock {
            if case .string(let text) = message { texts.append(text) }
        }
        // A full send buffer on a dead path: the send never completes.
        if sendsHang { try await Task.sleep(for: .seconds(3600)) }
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
        let answer: Bool = lock.withLock {
            pings += 1
            return answersPings && !cancelled
        }
        // A dead path never answers: the handler is simply never called.
        if answer { pongReceiveHandler(nil) }
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
