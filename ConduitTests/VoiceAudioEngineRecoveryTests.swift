import AVFAudio
import XCTest
@testable import Conduit

/// Regressions for the voice "-10868" failure: audio engines kept across
/// session reconfigurations started against stale hardware formats. Every
/// rendering lifetime now starts on a fresh engine and retries once after a
/// recoverable graph failure. Driven through pure seams and a start-failing
/// engine subclass, so no test renders audio or starts a real engine.
///
/// Hosted as an extension of an existing voice-audio test class rather than a
/// new XCTestCase: the CI planner's per-job batch policy is at capacity, and
/// one more planned class fails plan validation.
extension VoiceAudioSessionCoordinatorTests {
    private var formatNotSupported: NSError {
        NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: VoiceAudioEngineRecovery.formatNotSupported
        )
    }

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
        let unpopulated = AVAudioFormat()
        XCTAssertNil(
            VoiceAudioEngineRecovery.tapFormat(nodeOutput: unpopulated, hardware: hardware),
            "an unpopulated node output is not treated as a stale-rate mismatch"
        )
    }

    func testEmptyInputFormatIsRecoverable() {
        XCTAssertTrue(VoiceAudioEngineRecovery.isRecoverable(VoiceAudioInputFormatUnavailable()))
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

    // MARK: - Capture engine recovery (fake capture graph)

    private func makeCaptureService(_ factory: FakeCaptureEngineFactory) -> AVAudioCaptureService {
        AVAudioCaptureService(
            coordinator: VoiceAudioSessionCoordinator(session: InertVoiceAudioSession()),
            makeEngine: { factory.make() }
        )
    }

    func testCaptureBuildsAFreshEngineForEveryStart() throws {
        let factory = FakeCaptureEngineFactory()
        let service = makeCaptureService(factory)
        XCTAssertEqual(factory.engines.count, 1, "init builds the placeholder engine")

        try service.startListening()
        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertTrue(factory.engines[1].isRunning)

        service.pause()
        try service.resume()
        XCTAssertEqual(factory.engines.count, 3, "resume starts a new rendering lifetime on a new engine")
        XCTAssertFalse(factory.engines[1].isRunning, "the previous engine was stopped")
        XCTAssertTrue(factory.engines[2].isRunning)
        service.stop()
    }

    func testCaptureTapsAtTheHardwareFormatWhenTheNodeRateIsStale() throws {
        let factory = FakeCaptureEngineFactory()
        factory.hardware = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        factory.nodeOutput = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let service = makeCaptureService(factory)

        try service.startListening()

        let engine = try XCTUnwrap(factory.engines.last)
        XCTAssertEqual(engine.installedTapFormats.count, 1)
        XCTAssertEqual(engine.installedTapFormats.first ?? nil, factory.hardware)
        service.stop()
    }

    func testCaptureKeepsTheNilFormatTapWhenRatesMatch() throws {
        let factory = FakeCaptureEngineFactory()
        let service = makeCaptureService(factory)

        try service.startListening()

        let engine = try XCTUnwrap(factory.engines.last)
        XCTAssertEqual(engine.installedTapFormats.count, 1)
        XCTAssertNil(engine.installedTapFormats.first ?? nil)
        service.stop()
    }

    func testCaptureRetriesAGraphFailureOnceOnAFreshEngine() throws {
        let factory = FakeCaptureEngineFactory()
        factory.startFailures = [formatNotSupported]
        let service = makeCaptureService(factory)

        try service.startListening()

        XCTAssertEqual(factory.engines.count, 3, "init, the failed attempt, and the retry")
        XCTAssertFalse(factory.engines[1].isRunning)
        XCTAssertTrue(factory.engines[2].isRunning)
        XCTAssertTrue(service.shouldKeepEngineRunning)
        service.stop()
    }

    func testCaptureFailsCleanlyWhenTheRetryAlsoFails() {
        let factory = FakeCaptureEngineFactory()
        factory.startFailures = [formatNotSupported, formatNotSupported]
        let service = makeCaptureService(factory)

        XCTAssertThrowsError(try service.startListening()) { error in
            XCTAssertEqual((error as NSError).code, VoiceAudioEngineRecovery.formatNotSupported)
        }
        XCTAssertEqual(factory.engines.count, 3, "exactly one retry")
        XCTAssertFalse(service.shouldKeepEngineRunning)
        XCTAssertTrue(factory.engines.allSatisfy { !$0.isRunning && !$0.hasTap })
    }

    func testCaptureRetriesAnEmptyHardwareFormatThenReportsUnavailable() {
        let factory = FakeCaptureEngineFactory()
        factory.hardware = AVAudioFormat()
        let service = makeCaptureService(factory)

        XCTAssertThrowsError(try service.startListening()) { error in
            XCTAssertTrue(error is VoiceAudioInputFormatUnavailable)
        }
        XCTAssertEqual(factory.engines.count, 3, "an empty format gets one retry on a fresh engine")
        XCTAssertTrue(factory.engines.allSatisfy { $0.installedTapFormats.isEmpty }, "no tap is installed without a hardware format")
    }

    func testCaptureDoesNotRetryANonGraphFailure() {
        let factory = FakeCaptureEngineFactory()
        factory.startFailures = [URLError(.unknown)]
        let service = makeCaptureService(factory)

        XCTAssertThrowsError(try service.startListening())
        XCTAssertEqual(factory.engines.count, 2)
    }

    // MARK: - Playback drain watchdog

    func testDrainSettlesWhenRenderingDiesWithoutANotification() async {
        let service = AVSpeechPlaybackService(coordinator: VoiceAudioSessionCoordinator(session: InertVoiceAudioSession()))
        // A buffer is outstanding but its completion will never fire: the
        // engine stopped without posting anything the service observes.
        service.pendingBuffers = 1
        service.drainWatchdogGrace = 0.05

        await service.drain()

        XCTAssertEqual(service.pendingBuffers, 0, "the watchdog settled the stream through stop()")
        XCTAssertFalse(service.isPlaying)
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

/// Builds fake capture graphs that share one configuration, and records every
/// engine it built so tests can inspect each rendering lifetime.
private final class FakeCaptureEngineFactory {
    var hardware = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var nodeOutput: AVAudioFormat?
    /// Errors thrown by successive start() calls across all engines.
    var startFailures: [Error] = []
    private(set) var engines: [FakeCaptureEngine] = []

    func make() -> VoiceCaptureEngine {
        let engine = FakeCaptureEngine(factory: self)
        engines.append(engine)
        return engine
    }

    fileprivate func nextStartFailure() -> Error? {
        startFailures.isEmpty ? nil : startFailures.removeFirst()
    }
}

private final class FakeCaptureEngine: VoiceCaptureEngine {
    private unowned let factory: FakeCaptureEngineFactory
    private(set) var isRunning = false
    private(set) var hasTap = false
    private(set) var installedTapFormats: [AVAudioFormat?] = []

    init(factory: FakeCaptureEngineFactory) { self.factory = factory }

    var hardwareInputFormat: AVAudioFormat { factory.hardware }
    var inputNodeOutputFormat: AVAudioFormat { factory.nodeOutput ?? factory.hardware }

    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        installedTapFormats.append(format)
        hasTap = true
    }

    func removeInputTap() { hasTap = false }
    func prepare() {}

    func start() throws {
        if let failure = factory.nextStartFailure() { throw failure }
        isRunning = true
    }

    func stop() { isRunning = false }
}
