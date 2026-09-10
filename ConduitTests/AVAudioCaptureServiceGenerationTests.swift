import AVFAudio
import XCTest
@testable import Conduit

/// Regressions for physical frame-generation isolation inside the capture
/// service (PR #149): the controller already rejects stale `.level` events,
/// but the stronger invariant lives here — a frame produced by an
/// invalidated tap generation must never reach conversion state, pre-roll,
/// captured audio, or level emission for a later capture. The service is
/// driven at its frame-admission seam with synthetic in-memory PCM buffers,
/// so these tests never touch audio hardware.
@MainActor
final class AVAudioCaptureServiceGenerationTests: XCTestCase {
    private var collectedEvents: [VoiceCaptureEvent] = []
    private var eventCollector: Task<Void, Never>?

    override func tearDown() {
        eventCollector?.cancel()
        eventCollector = nil
        super.tearDown()
    }

    // MARK: - Admission seam

    func testFrameAdmissionRejectsStaleGenerationAcrossStopRestart() {
        let service = AVAudioCaptureService()

        // Generation A is live: rendering expected to stay up, capture unpaused.
        service.shouldKeepEngineRunning = true
        let generationA = service.captureGeneration
        XCTAssertTrue(service.acceptsFrame(generation: generationA))

        // Teardown invalidates A; a restart re-arms B exactly the way
        // startListening/resume re-arm the live flags after a real tap
        // reinstall.
        service.stop()
        service.shouldKeepEngineRunning = true
        let generationB = service.captureGeneration
        XCTAssertNotEqual(generationA, generationB, "stop must invalidate the capture generation")

        XCTAssertFalse(
            service.acceptsFrame(generation: generationA),
            "a frame from an invalidated generation must be rejected even after a later capture is live"
        )
        XCTAssertTrue(
            service.acceptsFrame(generation: generationB),
            "the current generation is admitted while capture is live"
        )

        service.paused = true
        XCTAssertFalse(
            service.acceptsFrame(generation: generationB),
            "a paused capture admits no frames"
        )
    }

    // MARK: - Physical PCM isolation

    func testStaleGenerationFrameCannotEnterCapturedAudioAfterRestart() async throws {
        let service = AVAudioCaptureService()
        startEventCollector(service)

        // Capture A is live and recording.
        service.shouldKeepEngineRunning = true
        service.activelyRecording = true
        let generationA = service.captureGeneration

        // stop() tears A down; the restart re-arms B with fresh captured
        // audio (what startListening(includePreRoll: false) resets in
        // production).
        service.stop()
        service.shouldKeepEngineRunning = true
        service.activelyRecording = true
        service.capturedPCM = Data()
        let generationB = service.captureGeneration
        XCTAssertNotEqual(generationA, generationB)

        // A full second of loud, unmistakable audio arrives late — captured
        // by tap A while it was still installed, surfacing only after B is
        // live.
        let stale = constantBuffer(sampleRate: 48_000, frameCount: 48_000, amplitude: 0.9)
        service.consume(stale, generation: generationA)

        XCTAssertTrue(
            service.preRollPCM.isEmpty,
            "a stale generation's PCM must never enter pre-roll"
        )
        XCTAssertTrue(
            service.capturedPCM.isEmpty,
            "a stale generation's PCM must never enter captured audio"
        )

        // The live generation's frame is admitted normally: 20 ms at 48 kHz.
        let current = constantBuffer(sampleRate: 48_000, frameCount: 960, amplitude: 0.25)
        service.consume(current, generation: generationB)

        let audio = try service.finishUtterance()
        let samples = audio.pcm16Data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }
        XCTAssertGreaterThan(samples.count, 0)
        // 960 frames at 48 kHz downsample to ~320 frames at the 16 kHz capture
        // policy rate; anything approaching the stale second's size means a
        // stale frame slipped through admission.
        XCTAssertLessThan(audio.pcm16Data.count, 2_000)
        for sample in samples {
            XCTAssertEqual(
                Float(sample) / Float(Int16.max),
                0.25,
                accuracy: 0.05,
                "captured audio must contain only the admitted generation-B frame"
            )
        }
        XCTAssertEqual(
            service.preRollPCM.count,
            audio.pcm16Data.count,
            "pre-roll must hold exactly the same admitted bytes"
        )

        // Only the admitted frame may surface a level event, tagged with its
        // own generation.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(collectedEvents.count, 1, "a stale generation's frame must not emit a level event")
        guard case let .level(peak, _, generation) = collectedEvents.first else {
            return XCTFail("expected a level event from the admitted frame")
        }
        XCTAssertEqual(peak, 0.25, accuracy: 0.01)
        XCTAssertEqual(generation, generationB)
    }

    // MARK: - Helpers

    /// A mono Float32 buffer at a realistic hardware rate filled with a
    /// constant amplitude. Purely in-memory: no audio session or engine.
    private func constantBuffer(
        sampleRate: Double,
        frameCount: AVAudioFrameCount,
        amplitude: Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            buffer.floatChannelData![0][index] = amplitude
        }
        return buffer
    }

    private func startEventCollector(_ service: AVAudioCaptureService) {
        collectedEvents = []
        eventCollector = Task { [weak self] in
            for await event in service.events {
                self?.collectedEvents.append(event)
            }
        }
    }
}
