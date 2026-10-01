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
        let socket = FakeSpeechSocket()
        socket.pendingPCM = [Data(count: 4)]
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
}

// MARK: - Speech stream test doubles

/// A speak-stream socket whose handshake was refused: every send fails, and
/// receive delivers any queued PCM, then parks until the socket is cancelled.
@MainActor
private final class FakeSpeechSocket: HermesSpeechSocket {
    var pendingPCM: [Data] = []
    private(set) var sendCount = 0
    private(set) var cancelCount = 0
    private var parked: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var cancelled = false

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sendCount += 1
        throw URLError(.badServerResponse)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !pendingPCM.isEmpty { return .data(pendingPCM.removeFirst()) }
        if cancelled { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { parked = $0 }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCount += 1
        cancelled = true
        parked?.resume(throwing: URLError(.cancelled))
        parked = nil
    }
}

@MainActor
private final class SpeechStreamRecorder {
    var fallbackText: String?
    var encodedAudio: Data?
    var receivedPCM = false

    func makeStream(socket: FakeSpeechSocket) -> HermesSpeechStream {
        HermesSpeechStream(
            task: socket,
            fallback: { [weak self] text in
                self?.fallbackText = text
                return Data([1, 2, 3])
            },
            onStart: { _ in },
            onPCM16: { [weak self] _, _ in self?.receivedPCM = true },
            onEncodedAudio: { [weak self] data in self?.encodedAudio = data }
        )
    }
}
