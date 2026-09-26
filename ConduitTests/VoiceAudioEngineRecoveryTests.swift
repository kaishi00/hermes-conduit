import AVFAudio
import XCTest
@testable import Conduit

/// Regressions for the voice "-10868" failure: audio engines kept across
/// session reconfigurations started against stale hardware formats. Every
/// rendering lifetime now starts on a fresh engine and retries once after a
/// recoverable graph failure. Driven through pure seams and a start-failing
/// engine subclass, so no test renders audio or starts a real engine.
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

    func testAppLevelAndUnrelatedErrorsAreNotRetried() {
        XCTAssertFalse(VoiceAudioEngineRecovery.isRecoverable(VoiceAudioError.microphonePermissionDenied))
        XCTAssertFalse(VoiceAudioEngineRecovery.isRecoverable(
            VoiceAudioError.unavailable("The selected microphone is unavailable.")
        ))
        XCTAssertFalse(VoiceAudioEngineRecovery.isRecoverable(URLError(.timedOut)))
    }

    // MARK: - Tap format guard

    func testStaleNodeOutputRateTapsAtTheHardwareFormat() throws {
        let hardware = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let stale = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let live = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))

        XCTAssertEqual(
            VoiceAudioEngineRecovery.tapFormat(nodeOutput: stale, hardware: hardware),
            hardware,
            "a node output rate left over from a previous route must not reach installTap"
        )
        XCTAssertNil(
            VoiceAudioEngineRecovery.tapFormat(nodeOutput: live, hardware: hardware),
            "a matching node keeps the unchanged nil-format tap"
        )
    }

    func testVoiceAudioErrorIsNotRetried() {
        XCTAssertFalse(VoiceAudioEngineRecovery.isRecoverable(VoiceAudioError.noAudioCaptured))
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

    func testCoreAudioCodeInAnotherDomainIsNotRetried() {
        XCTAssertFalse(VoiceAudioEngineRecovery.isRecoverable(
            NSError(domain: "com.example.unrelated", code: VoiceAudioEngineRecovery.formatNotSupported)
        ))
    }

    func testWrappedCoreAudioFailureIsRecoverable() {
        let wrapped = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: formatNotSupported]
        )
        XCTAssertTrue(VoiceAudioEngineRecovery.isRecoverable(wrapped))
    }

    // MARK: - Playback start recovery

    /// Service-level: engine.start is replaced by a -10868 failure, so this
    /// exercises the real rebuild/retry/settle path without rendering audio.
    func testPlaybackStartRetriesOnAFreshEngineThenSettlesCleanly() {
        let factory = CountingEngineFactory()
        let service = AVSpeechPlaybackService(
            coordinator: VoiceAudioSessionCoordinator(session: InertVoiceAudioSession()),
            makeEngine: { factory.make() }
        )
        XCTAssertEqual(factory.built, 1)

        XCTAssertThrowsError(try service.start(sampleRate: 24_000)) { error in
            XCTAssertEqual((error as NSError).code, VoiceAudioEngineRecovery.formatNotSupported)
        }
        XCTAssertEqual(factory.built, 3, "each attempt runs on its own freshly built engine")
        XCTAssertEqual(factory.startAttempts, 2, "a recoverable failure is retried exactly once")
        XCTAssertFalse(service.isPlaying)

        // The failed start left no format behind: the next chunk starts a new
        // stream instead of scheduling onto the dead player.
        XCTAssertThrowsError(try service.enqueuePCM16(Data([0, 0]), sampleRate: 24_000))
        XCTAssertEqual(factory.startAttempts, 4)
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

private final class CountingEngineFactory {
    private(set) var built = 0
    private(set) var startAttempts = 0

    func make() -> AVAudioEngine {
        built += 1
        return FormatRejectingEngine { [weak self] in self?.startAttempts += 1 }
    }
}

/// An engine whose start fails the way a stale graph does (-10868).
private final class FormatRejectingEngine: AVAudioEngine {
    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
        super.init()
    }

    override func start() throws {
        onStart()
        throw NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: VoiceAudioEngineRecovery.formatNotSupported
        )
    }
}
