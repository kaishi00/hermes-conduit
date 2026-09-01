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
}
