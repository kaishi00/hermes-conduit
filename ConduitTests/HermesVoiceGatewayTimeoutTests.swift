//
//  HermesVoiceGatewayTimeoutTests.swift
//  Conduit
//
//  Pins the transcription request timeout policy against the upstream Hermes
//  Desktop constants: every request gets at least the 180s floor, scales with
//  the audio payload, and clamps at the 600s cap. The old fixed 90s ceiling
//  truncated legitimate remote-provider transcriptions.
//

import XCTest
@testable import Conduit

@MainActor
final class HermesVoiceGatewayTimeoutTests: XCTestCase {
    func testPolicyMatchesUpstreamDesktopConstants() {
        XCTAssertEqual(HermesVoiceGateway.transcriptionMinimumRequestTimeoutMilliseconds, 180_000)
        XCTAssertEqual(HermesVoiceGateway.transcriptionMaximumRequestTimeoutMilliseconds, 600_000)
        XCTAssertEqual(HermesVoiceGateway.transcriptionTimeoutMillisecondsPerDataURLCharacter, 0.1)
    }

    func testShortRecordingsGetAtLeastTheNewMinimum() {
        // A typical 10s clip (16kHz mono 16-bit ≈ 320KB → ~427k base64
        // characters) would budget ~43s from the payload alone, but the 180s
        // floor governs — well past the old 90s ceiling.
        XCTAssertEqual(HermesVoiceGateway.transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: 0), 180_000)
        XCTAssertEqual(HermesVoiceGateway.transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: 427_000), 180_000)
    }

    func testLargeRecordingsScaleUpward() {
        // ~4M characters ≈ 3MB of audio → ~400s of budget: above the floor,
        // below the cap. A band assertion keeps this free of float-ceil noise.
        let scaled = HermesVoiceGateway.transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: 4_000_000)
        XCTAssertTrue((400_000...400_100).contains(scaled), "Expected ~400s, got \(scaled)")

        // Scaling is monotonic once above the floor.
        let smaller = HermesVoiceGateway.transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: 2_000_000)
        XCTAssertGreaterThan(scaled, smaller)
        XCTAssertGreaterThanOrEqual(smaller, 180_000)
    }

    func testVeryLargeRecordingsAreBoundedByTheMaximum() {
        XCTAssertEqual(
            HermesVoiceGateway.transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: 1_000_000_000),
            600_000
        )
        // No request is ever unbounded, and the conversion never traps.
        XCTAssertEqual(
            HermesVoiceGateway.transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: Int.max),
            600_000
        )
        XCTAssertLessThanOrEqual(
            HermesVoiceGateway.transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: Int.max / 2),
            600_000
        )
    }

    func testCapturedAudioDataURLFeedsThePolicy() {
        let audio = VoiceCapturedAudio(wavData: Data(repeating: 0, count: 48), pcm16Data: Data(), sampleRate: 16_000, duration: 5)
        XCTAssertEqual(
            HermesVoiceGateway.transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: audio.dataURL.count),
            180_000
        )
    }

    // MARK: - Speech stream request
    //
    // The speak-stream upgrade must carry the Cloudflare Access service-token
    // headers, or Access refuses the handshake whenever no CF_Authorization
    // cookie happens to be cached.

    private var speechStreamCredentials: CloudflareAccessCredentials {
        CloudflareAccessCredentials(clientID: "test-client-id", clientSecret: "test-client-secret")
    }

    func testSecureSpeechStreamCarriesCloudflareAccessHeaders() throws {
        let request = try HermesVoiceGateway.speechStreamRequest(
            baseURL: "https://hermes.example/",
            ticket: "abc",
            profile: "default",
            cloudflareAccess: speechStreamCredentials
        )
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/api/audio/speak-stream")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "ticket" }?.value, "abc")
        XCTAssertEqual(query.first { $0.name == "profile" }?.value, "default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "test-client-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "test-client-secret")
    }

    func testSpeechStreamWithoutCloudflareAccessHasNoAccessHeaders() throws {
        let request = try HermesVoiceGateway.speechStreamRequest(
            baseURL: "https://hermes.example",
            ticket: "abc",
            profile: "default",
            cloudflareAccess: nil
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }

    func testCleartextSpeechStreamNeverCarriesTheServiceToken() throws {
        let request = try HermesVoiceGateway.speechStreamRequest(
            baseURL: "http://192.168.1.20:9119",
            ticket: "abc",
            profile: "default",
            cloudflareAccess: speechStreamCredentials
        )
        XCTAssertEqual(request.url?.scheme, "ws")
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }

    // MARK: - Speech stream fallback
    //
    // A refused speak-stream handshake surfaces as a failed send. Before any
    // audio has arrived that must switch to the one-shot fallback instead of
    // failing the spoken reply.

    func testSendFailureBeforeAudioPlaysTheFallback() async throws {
        let socket = FakeSpeechSocket()
        let recorder = SpeechStreamRecorder()
        let stream = recorder.makeStream(socket: socket)

        try await stream.append("Hello ")
        try await stream.append("world")
        let streamed = try await stream.finish()

        XCTAssertFalse(streamed)
        XCTAssertEqual(recorder.fallbackText, "Hello world")
        XCTAssertEqual(recorder.encodedAudio, Data([1, 2, 3]))
        XCTAssertEqual(socket.sendCount, 1, "after the failed send the text is held for the fallback")
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
    }

    func testSendFailureAfterAudioStillFails() async throws {
        let socket = FakeSpeechSocket(pendingPCM: [Data(count: 4)])
        let recorder = SpeechStreamRecorder()
        let stream = recorder.makeStream(socket: socket)

        for _ in 0..<1_000 where !recorder.receivedPCM { await Task.yield() }
        XCTAssertTrue(recorder.receivedPCM)

        do {
            try await stream.append("more")
            XCTFail("a send failure after audio arrived must surface")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertNil(recorder.fallbackText)
        stream.cancel()
    }

    func testAppendAfterClientCancelThrowsCancellation() async {
        let socket = FakeSpeechSocket()
        let recorder = SpeechStreamRecorder()
        let stream = recorder.makeStream(socket: socket)

        stream.cancel()
        do {
            try await stream.append("late")
            XCTFail("append after cancel must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(socket.sendCount, 0)
        XCTAssertNil(recorder.fallbackText)
    }

    // MARK: - Finish idle timeout (#303)
    //
    // Read Aloud sends a whole reply and finishes at once, so a long reply is
    // synthesized entirely after finish(). The timeout is an idle window that
    // every frame re-arms, never a total deadline.

    func testLongStreamPastTheIdleWindowCompletes() async throws {
        let socket = ScriptedSpeechSocket()
        let recorder = SpeechStreamRecorder()
        let stream = recorder.makeStream(socket: socket, finishIdleTimeout: .seconds(1))

        try await stream.append("A long reply")
        let feeder = Task {
            // ~1.6s of frames, each gap a tenth of the 1s window.
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(100))
                socket.deliver(.data(Data(count: 4)))
            }
            socket.deliver(.string(#"{"type":"end"}"#))
        }
        let streamed = try await stream.finish()
        await feeder.value

        XCTAssertTrue(streamed)
        XCTAssertEqual(recorder.pcmChunks, 16)
    }

    func testStreamSilentForTheIdleWindowTimesOut() async throws {
        let socket = ScriptedSpeechSocket()
        let recorder = SpeechStreamRecorder()
        let stream = recorder.makeStream(socket: socket, finishIdleTimeout: .milliseconds(200))

        try await stream.append("Hello")
        socket.deliver(.data(Data(count: 4)))
        for _ in 0..<1_000 where !recorder.receivedPCM { await Task.yield() }
        XCTAssertTrue(recorder.receivedPCM)

        do {
            _ = try await stream.finish()
            XCTFail("a stream that goes silent after audio must time out")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        stream.cancel()
    }
}

// MARK: - Speech stream test doubles

/// A speak-stream socket whose handshake was refused: every send fails, and
/// receive delivers any queued PCM, then parks until the socket is cancelled.
/// Nonisolated like `HermesSpeechSocket` (its synchronous `cancel` must be),
/// so its state is lock-guarded.
private final class FakeSpeechSocket: HermesSpeechSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedPCM: [Data]
    private var sends = 0
    private var cancels = 0
    private var cancelled = false
    private var parked: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    init(pendingPCM: [Data] = []) {
        queuedPCM = pendingPCM
    }

    var sendCount: Int { lock.withLock { sends } }
    var cancelCount: Int { lock.withLock { cancels } }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { sends += 1 }
        throw URLError(.badServerResponse)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let next: Data? = lock.withLock { queuedPCM.isEmpty ? nil : queuedPCM.removeFirst() }
        if let next { return .data(next) }
        return try await withCheckedThrowingContinuation { continuation in
            let alreadyCancelled: Bool = lock.withLock {
                if cancelled { return true }
                parked = continuation
                return false
            }
            if alreadyCancelled { continuation.resume(throwing: URLError(.cancelled)) }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let waiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            cancels += 1
            cancelled = true
            let waiting = parked
            parked = nil
            return waiting
        }
        waiting?.resume(throwing: URLError(.cancelled))
    }
}

private enum ScriptedReceive {
    case message(URLSessionWebSocketTask.Message)
    case cancelled
    case park
}

/// A healthy speak-stream socket: sends succeed, and receive hands out
/// whatever the test delivers, in order, parking until the next delivery.
private final class ScriptedSpeechSocket: HermesSpeechSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var cancelled = false
    private var parked: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

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

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let next: ScriptedReceive = lock.withLock {
                if !queued.isEmpty { return .message(queued.removeFirst()) }
                if cancelled { return .cancelled }
                parked = continuation
                return .park
            }
            switch next {
            case .message(let message): continuation.resume(returning: message)
            case .cancelled: continuation.resume(throwing: URLError(.cancelled))
            case .park: break
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

@MainActor
private final class SpeechStreamRecorder {
    var fallbackText: String?
    var encodedAudio: Data?
    var receivedPCM = false
    var pcmChunks = 0

    func makeStream(socket: any HermesSpeechSocket, finishIdleTimeout: Duration = .seconds(20)) -> HermesSpeechStream {
        HermesSpeechStream(
            task: socket,
            finishIdleTimeout: finishIdleTimeout,
            fallback: { [weak self] text in
                self?.fallbackText = text
                return Data([1, 2, 3])
            },
            onStart: { _ in },
            onPCM16: { [weak self] _, _ in
                self?.receivedPCM = true
                self?.pcmChunks += 1
            },
            onEncodedAudio: { [weak self] data in self?.encodedAudio = data }
        )
    }
}
