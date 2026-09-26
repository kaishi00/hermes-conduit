import AVFAudio
import XCTest
@testable import Conduit

/// Regressions for the voice "-10868" failure: audio engines kept across
/// session reconfigurations started against stale hardware formats. Every
/// rendering lifetime now starts on a fresh engine and retries once after a
/// recoverable graph failure. Driven through pure seams, so these tests never
/// touch audio hardware.
@MainActor
final class VoiceAudioEngineRecoveryTests: XCTestCase {
    private let formatNotSupported = NSError(
        domain: "com.apple.coreaudio.avfaudio",
        code: VoiceAudioEngineRecovery.formatNotSupported
    )

    // MARK: - Error classification

    func testFormatNotSupportedIsRecoverable() {
        XCTAssertEqual(VoiceAudioEngineRecovery.formatNotSupported, -10868)
        XCTAssertTrue(VoiceAudioEngineRecovery.isRecoverable(formatNotSupported))
        XCTAssertTrue(VoiceAudioEngineRecovery.isRecoverable(
            NSError(domain: NSOSStatusErrorDomain, code: VoiceAudioEngineRecovery.failedInitialization)
        ))
    }

    func testInputFormatMismatchIsRecoverable() {
        let mismatch = VoiceAudioInputFormatMismatch(hardwareSampleRate: 16_000, tapSampleRate: 48_000)
        XCTAssertTrue(VoiceAudioEngineRecovery.isRecoverable(mismatch))
    }

    func testAppLevelAndUnrelatedErrorsAreNotRetried() {
        XCTAssertFalse(VoiceAudioEngineRecovery.isRecoverable(VoiceAudioError.microphonePermissionDenied))
        XCTAssertFalse(VoiceAudioEngineRecovery.isRecoverable(
            VoiceAudioError.unavailable("The selected microphone is unavailable.")
        ))
        XCTAssertFalse(VoiceAudioEngineRecovery.isRecoverable(URLError(.timedOut)))
    }

    // MARK: - Tap format guard

    func testTapFormatMustMatchHardwareSampleRate() throws {
        let hardware = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let stale = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let live = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))

        XCTAssertFalse(
            VoiceAudioEngineRecovery.tapFormat(stale, matchesHardware: hardware),
            "a tap format left over from a previous route must be rejected before installTap raises"
        )
        XCTAssertTrue(VoiceAudioEngineRecovery.tapFormat(live, matchesHardware: hardware))
    }

    // MARK: - Fresh-start sequencing

    func testStartBuildsAFreshEngineBeforeTheFirstAttempt() throws {
        var steps: [String] = []

        try VoiceAudioEngineRecovery.startFresh(
            rebuild: { steps.append("rebuild") },
            reassert: { steps.append("reassert") },
            start: { steps.append("start") }
        )

        XCTAssertEqual(steps, ["rebuild", "start"])
    }

    func testRecoverableFailureReassertsRebuildsAndRetriesOnce() throws {
        var steps: [String] = []
        var failuresRemaining = 1

        try VoiceAudioEngineRecovery.startFresh(
            rebuild: { steps.append("rebuild") },
            reassert: { steps.append("reassert") },
            start: {
                steps.append("start")
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    throw self.formatNotSupported
                }
            }
        )

        XCTAssertEqual(steps, ["rebuild", "start", "reassert", "rebuild", "start"])
    }

    func testSecondRecoverableFailureIsRethrownWithoutAThirdAttempt() {
        var starts = 0

        XCTAssertThrowsError(
            try VoiceAudioEngineRecovery.startFresh(
                rebuild: {},
                reassert: {},
                start: {
                    starts += 1
                    throw self.formatNotSupported
                }
            )
        ) { error in
            XCTAssertEqual((error as NSError).code, VoiceAudioEngineRecovery.formatNotSupported)
        }
        XCTAssertEqual(starts, 2)
    }

    func testNonRecoverableFailureIsRethrownImmediately() {
        var steps: [String] = []

        XCTAssertThrowsError(
            try VoiceAudioEngineRecovery.startFresh(
                rebuild: { steps.append("rebuild") },
                reassert: { steps.append("reassert") },
                start: {
                    steps.append("start")
                    throw VoiceAudioError.unavailable("The selected microphone is unavailable.")
                }
            )
        )
        XCTAssertEqual(steps, ["rebuild", "start"])
    }

    func testReassertFailureAbandonsTheRetry() {
        var starts = 0

        XCTAssertThrowsError(
            try VoiceAudioEngineRecovery.startFresh(
                rebuild: {},
                reassert: { throw VoiceAudioError.unavailable("session") },
                start: {
                    starts += 1
                    throw self.formatNotSupported
                }
            )
        )
        XCTAssertEqual(starts, 1)
    }

    // MARK: - Playback drain fence

    func testStaleBufferCompletionCannotDrainTheNextStream() {
        let service = AVSpeechPlaybackService(coordinator: VoiceAudioSessionCoordinator(session: InertVoiceAudioSession()))
        let previousGeneration = service.playbackGeneration

        // stop() retires the previous stream; its player then reports its
        // unplayed buffers as completed.
        service.stop()
        XCTAssertNotEqual(service.playbackGeneration, previousGeneration)
        service.pendingBuffers = 2

        service.bufferDidDrain(generation: previousGeneration)
        XCTAssertEqual(service.pendingBuffers, 2, "a retired stream's completion must not count against the live one")

        service.bufferDidDrain(generation: service.playbackGeneration)
        XCTAssertEqual(service.pendingBuffers, 1)
    }
}

@MainActor
private final class InertVoiceAudioSession: VoiceAudioSessionControlling {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {}

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
}
