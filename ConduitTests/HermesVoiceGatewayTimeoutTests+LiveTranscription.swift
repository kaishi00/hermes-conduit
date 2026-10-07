//
//  HermesVoiceGatewayTimeoutTests+LiveTranscription.swift
//  Conduit
//
//  The transcribe-stream wire (Hermes #133853): sample rate first, PCM16
//  frames, then eos; partial frames while speaking, one final at the end.
//  An error before any words means the profile has no live STT.
//

import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    func testLiveTranscriptionSendsTheWireInOrderAndReturnsTheFinalTranscript() async {
        let socket = LiveTranscriptionSocket()
        var partials: [String] = []
        var unavailable = false
        let live = HermesLiveTranscription(
            socket: socket,
            sampleRate: 16_000,
            onPartial: { partials.append($0) },
            onUnavailable: { unavailable = true }
        )
        live.push(Data([1, 0, 2, 0]))
        socket.deliver(.string(#"{"type":"partial","text":" hello "}"#))
        let receivedPartial = await Self.eventually { partials == ["hello"] }
        XCTAssertTrue(receivedPartial)

        let finishing = Task { await live.finish() }
        let sentEnd = await Self.eventually { socket.sent.last == .text(#"{"eos":true}"#) }
        XCTAssertTrue(sentEnd)
        socket.deliver(.string(#"{"type":"final","transcript":" hello world ","provider":"openai"}"#))
        let transcript = await finishing.value

        XCTAssertEqual(transcript, "hello world")
        XCTAssertEqual(socket.sent, [
            .text(#"{"sample_rate":16000}"#),
            .binary(Data([1, 0, 2, 0])),
            .text(#"{"eos":true}"#)
        ])
        XCTAssertFalse(unavailable)
    }

    func testLiveTranscriptionErrorBeforeAnyWordsMarksItUnavailable() async {
        let socket = LiveTranscriptionSocket()
        var unavailable = false
        let live = HermesLiveTranscription(
            socket: socket,
            sampleRate: 16_000,
            onPartial: { _ in },
            onUnavailable: { unavailable = true }
        )
        socket.deliver(.string(#"{"type":"error","message":"no live STT for the configured provider"}"#))
        let reported = await Self.eventually { unavailable }
        XCTAssertTrue(reported)
        let transcript = await live.finish()
        XCTAssertNil(transcript)
    }

    func testEmptyFinalFallsBackToTheUploadWithoutMarkingUnavailable() async {
        let socket = LiveTranscriptionSocket()
        var unavailable = false
        let live = HermesLiveTranscription(
            socket: socket,
            sampleRate: 16_000,
            onPartial: { _ in },
            onUnavailable: { unavailable = true }
        )
        let finishing = Task { await live.finish() }
        let sentEnd = await Self.eventually { socket.sent.last == .text(#"{"eos":true}"#) }
        XCTAssertTrue(sentEnd)
        socket.deliver(.string(#"{"type":"final","transcript":"  ","provider":"openai"}"#))
        let transcript = await finishing.value

        XCTAssertNil(transcript)
        XCTAssertFalse(unavailable)
    }

    func testLiveTranscriptionGivesUpAfterTheFinishTimeout() async {
        let socket = LiveTranscriptionSocket()
        let live = HermesLiveTranscription(
            socket: socket,
            sampleRate: 16_000,
            finishTimeout: .milliseconds(50),
            onPartial: { _ in },
            onUnavailable: {}
        )
        let transcript = await live.finish()
        XCTAssertNil(transcript)
    }

    func testCancelDoesNotMarkLiveTranscriptionUnavailable() async {
        let socket = LiveTranscriptionSocket()
        var unavailable = false
        let live = HermesLiveTranscription(
            socket: socket,
            sampleRate: 16_000,
            onPartial: { _ in },
            onUnavailable: { unavailable = true }
        )
        live.cancel()
        let transcript = await live.finish()
        XCTAssertNil(transcript)
        XCTAssertFalse(unavailable)
    }

    func testLiveTranscriptionRequestTargetsTheTranscribeStreamSocket() throws {
        let request = try HermesVoiceGateway.liveTranscriptionRequest(
            baseURL: "https://hermes.example.com",
            ticket: "t1",
            profile: "work",
            cloudflareAccess: nil
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/api/audio/transcribe-stream")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "ticket" }?.value, "t1")
        XCTAssertEqual(items.first { $0.name == "profile" }?.value, "work")
    }

    /// A condition wait capped at 10 s; it never stands in for a fixed
    /// settling delay.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// A transcribe-stream socket: records what Conduit sends and hands out
/// whatever the test delivers, parking until the next delivery.
private final class LiveTranscriptionSocket: HermesSpeechSocket, @unchecked Sendable {
    enum Sent: Equatable {
        case text(String)
        case binary(Data)
    }

    private let lock = NSLock()
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var sentMessages: [Sent] = []
    private var cancelled = false
    private var parked: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    var sent: [Sent] { lock.withLock { sentMessages } }

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
        let recorded: Sent?
        switch message {
        case .string(let text): recorded = .text(text)
        case .data(let data): recorded = .binary(data)
        @unknown default: recorded = nil
        }
        lock.withLock {
            if let recorded { sentMessages.append(recorded) }
        }
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
