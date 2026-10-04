//
//  EchoCancellingVoiceConversationAudioTests.swift
//  ConduitTests
//
//  Classic voice speaker talk-over: the echo-cancelling capture and
//  playback seams and the per-conversation choice between them and the
//  default audio. A fake engine stands in for the voice-processing
//  hardware. An extension of an existing class, so the CI test plan needs
//  no new timing entry.
//

import AVFAudio
import XCTest
@testable import Conduit

@MainActor
private final class FakeEchoEngine: EchoCancellingVoiceEngine {
    var onChunk: (@MainActor (Data) -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    var isPlaying = false
    private(set) var inputRunning = false
    private(set) var startInputCount = 0
    private(set) var stopOutputCount = 0
    private(set) var playedPCM: [Data] = []

    func startInput() throws {
        startInputCount += 1
        inputRunning = true
    }
    func stopInput() { inputRunning = false }
    func play(_ pcm: Data, sampleRate: Double) throws {
        playedPCM.append(pcm)
        isPlaying = true
    }
    func play(_ buffer: AVAudioPCMBuffer) throws { isPlaying = true }
    private(set) var discardRemainderCount = 0
    func discardRemainder() { discardRemainderCount += 1 }
    func interrupt() { isPlaying = false }
    func stopOutput() {
        stopOutputCount += 1
        isPlaying = false
    }

    /// One microphone chunk of `samples` PCM16 samples at `amplitude`.
    func speak(amplitude: Float, samples: Int = 160) {
        let value = Int16(amplitude * Float(Int16.max)).littleEndian
        let pcm = [Int16](repeating: value, count: samples).withUnsafeBytes { Data($0) }
        onChunk?(pcm)
    }
}

/// Collects capture events across the reader task.
@MainActor
private final class CaptureEventLog {
    var levels: [Float] = []
    var interruptedGeneration: UInt64?
}

extension VoiceConversationControllerTests {
    private func makeSelector(
        wantsEcho: Bool,
        capture: MockCapture? = nil,
        playback: MockPlayback? = nil
    ) -> (VoiceConversationAudioSelector, FakeEchoEngine) {
        let engine = FakeEchoEngine()
        let selector = VoiceConversationAudioSelector(
            wantsEchoCancellation: { wantsEcho },
            standardCapture: capture ?? MockCapture(permissionGranted: true),
            standardPlayback: playback ?? MockPlayback(),
            makeEchoCancelling: { engine }
        )
        return (selector, engine)
    }

    func testEchoCancellingCaptureReportsLevelsAndRecordsTheUtterance() async throws {
        let (selector, engine) = makeSelector(wantsEcho: true)
        let capture = selector.capture
        let log = CaptureEventLog()
        let collected = expectation(description: "two level events")
        collected.expectedFulfillmentCount = 2
        let reader = Task { @MainActor in
            for await event in capture.events {
                if case .level(let level, _, let generation) = event {
                    XCTAssertEqual(generation, capture.captureGeneration)
                    log.levels.append(level)
                    collected.fulfill()
                }
            }
        }
        defer { reader.cancel() }

        try capture.startListening(includePreRoll: false)
        XCTAssertTrue(selector.cancelsEcho, "the setting picked the echo-cancelling engine")
        XCTAssertTrue(engine.inputRunning)
        engine.speak(amplitude: 0.5)
        engine.speak(amplitude: 0.25)
        await fulfillment(of: [collected], timeout: 5)

        XCTAssertEqual(log.levels.count, 2)
        XCTAssertEqual(log.levels.first ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(log.levels.last ?? 0, 0.25, accuracy: 0.01)
        let audio = try capture.finishUtterance()
        XCTAssertEqual(audio.pcm16Data.count, 2 * 160 * 2)
        XCTAssertEqual(audio.sampleRate, VoiceAudioSessionConfiguration.capture.outputSampleRate)
        XCTAssertEqual(audio.wavData.count, 44 + audio.pcm16Data.count)
    }

    func testEchoCancellingCaptureKeepsPreRollForTalkOver() throws {
        let (selector, engine) = makeSelector(wantsEcho: true)
        let capture = selector.capture
        // Monitoring while Hermes speaks: frames feed pre-roll only.
        try capture.beginBargeInMonitoring()
        engine.speak(amplitude: 0.5)
        XCTAssertThrowsError(try capture.finishUtterance(), "monitoring records no utterance")

        try capture.startListening(includePreRoll: true)
        let audio = try capture.finishUtterance()
        XCTAssertEqual(audio.pcm16Data.count, 160 * 2, "the talk-over's opening words come from pre-roll")
    }

    func testEchoCancellingCapturePauseDropsFramesAndStopEndsTheChoice() throws {
        let (selector, engine) = makeSelector(wantsEcho: true)
        let capture = selector.capture
        try capture.startListening(includePreRoll: false)
        let listeningGeneration = capture.captureGeneration
        capture.pause()
        XCTAssertFalse(engine.inputRunning)
        XCTAssertNotEqual(capture.captureGeneration, listeningGeneration, "levels from before the pause are stale")
        engine.speak(amplitude: 0.5)
        XCTAssertThrowsError(try capture.finishUtterance(), "a paused microphone records nothing")

        capture.stop()
        XCTAssertFalse(selector.cancelsEcho, "the next conversation chooses again")
        XCTAssertEqual(engine.stopOutputCount, 1, "the conversation's speaker side stops with it")
    }

    func testPlaybackStopReachesEchoAudioAfterTheChoiceIsReleased() throws {
        let standardPlayback = MockPlayback()
        let (selector, engine) = makeSelector(wantsEcho: true, playback: standardPlayback)
        try selector.capture.beginBargeInMonitoring()
        _ = try selector.playback.enqueuePCM16(Data(repeating: 1, count: 8), sampleRate: 24_000)
        selector.capture.stop()
        let stopsAfterCaptureStop = engine.stopOutputCount
        // Echo audio is (still) queued while the choice is already released.
        engine.isPlaying = true

        selector.playback.stop()

        XCTAssertEqual(engine.stopOutputCount, stopsAfterCaptureStop + 1, "queued echo audio is stopped, not left to the default playback")
        XCTAssertFalse(engine.isPlaying)
    }

    func testEchoCancellingCaptureRecordsAgainAfterPauseAndResume() throws {
        let (selector, engine) = makeSelector(wantsEcho: true)
        let capture = selector.capture
        try capture.startListening(includePreRoll: false)
        capture.pause()
        try capture.resume()
        engine.speak(amplitude: 0.5)

        let audio = try capture.finishUtterance()
        XCTAssertEqual(audio.pcm16Data.count, 320, "speech after a resume belongs to the utterance")
    }

    func testEchoCancellingCaptureReportsInterruptionAgainstItsCurrentGeneration() async throws {
        let (selector, engine) = makeSelector(wantsEcho: true)
        let capture = selector.capture
        let interrupted = expectation(description: "interruption event")
        let log = CaptureEventLog()
        let reader = Task { @MainActor in
            for await event in capture.events {
                if case .interrupted(let generation) = event {
                    log.interruptedGeneration = generation
                    interrupted.fulfill()
                }
            }
        }
        defer { reader.cancel() }

        try capture.startListening(includePreRoll: false)
        engine.onInterrupted?()
        await fulfillment(of: [interrupted], timeout: 5)

        XCTAssertEqual(log.interruptedGeneration, capture.captureGeneration, "the controller accepts it as the live capture's")
    }

    func testFallbackSpeechClipFormatIsSniffedForDecoding() {
        XCTAssertEqual(EchoCancellingVoicePlayback.fileExtension(for: Data("RIFF\0\0\0\0WAVE".utf8)), "wav")
        XCTAssertEqual(EchoCancellingVoicePlayback.fileExtension(for: Data("OggS\0\u{2}".utf8)), "ogg")
        XCTAssertEqual(EchoCancellingVoicePlayback.fileExtension(for: Data("\0\0\0\u{20}ftypM4A ".utf8)), "m4a")
        XCTAssertEqual(EchoCancellingVoicePlayback.fileExtension(for: Data("ID3\u{4}".utf8)), "mp3")
        XCTAssertEqual(EchoCancellingVoicePlayback.fileExtension(for: Data([0xFF, 0xFB, 0x90])), "mp3")
    }

    func testSelectorKeepsDefaultAudioWhenTalkOverIsOff() throws {
        let standardCapture = MockCapture(permissionGranted: true)
        let standardPlayback = MockPlayback()
        let (selector, engine) = makeSelector(wantsEcho: false, capture: standardCapture, playback: standardPlayback)

        try selector.capture.startListening(includePreRoll: false)
        try selector.playback.start(sampleRate: 24_000)

        XCTAssertFalse(selector.cancelsEcho)
        XCTAssertEqual(standardCapture.startCount, 1)
        XCTAssertTrue(standardPlayback.isPlaying)
        XCTAssertEqual(engine.startInputCount, 0, "the echo-cancelling engine is never touched")
    }

    func testSelectorPlaysConversationSpeechThroughTheEchoCancellingEngine() async throws {
        let standardPlayback = MockPlayback()
        let (selector, engine) = makeSelector(wantsEcho: true, playback: standardPlayback)
        let playback = selector.playback

        // Speech outside a conversation (the provider test) stays default.
        try playback.start(sampleRate: 24_000)
        XCTAssertTrue(standardPlayback.isPlaying)
        playback.stop()

        try selector.capture.beginBargeInMonitoring()
        _ = try playback.enqueuePCM16(Data(repeating: 1, count: 8), sampleRate: 24_000)
        XCTAssertEqual(engine.playedPCM.count, 1)
        XCTAssertTrue(playback.isPlaying)
        try playback.finish()
        XCTAssertEqual(engine.discardRemainderCount, 1, "an odd PCM16 tail isn't carried into the next reply")

        engine.isPlaying = false
        await playback.drain()
        XCTAssertEqual(engine.stopOutputCount, 1, "a played-out reply gives the speaker side back")
    }

    func testControllerKeepsTheMicrophoneOpenOnTheSpeakerWhenEchoIsCancelled() async {
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let standardCapture = MockCapture(permissionGranted: true)
        let (selector, engine) = makeSelector(wantsEcho: true, capture: standardCapture)
        let controller = VoiceConversationController(
            capture: selector.capture,
            playback: selector.playback,
            gateway: gateway,
            routePolicyProvider: { selector.cancelsEcho ? .fullDuplex : .speakerSafeHalfDuplex },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        // A route change while idle classifies the open speaker before any
        // echo choice exists; the conversation must not inherit it.
        standardCapture.emit(.routeChanged)
        await drainPendingMainActorWork()
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        XCTAssertTrue(selector.cancelsEcho)
        // The utterance's audio, recorded through the fake engine.
        engine.speak(amplitude: 0.5)
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        let submitted = await controller.waitForState(.thinking)
        XCTAssertTrue(submitted, "the utterance pipeline submitted the turn")
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer."))
        let speaking = await controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the assistant reply is audible")
        // The fake engine plays once speech reaches it.
        engine.isPlaying = true

        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "echo is cancelled, so the speaker keeps the mic open")
        XCTAssertTrue(engine.inputRunning)

        let talkOver = Date()
        controller.ingestAudioLevel(0.5, at: talkOver)
        controller.ingestAudioLevel(0.5, at: talkOver.addingTimeInterval(0.31))
        await interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "talking over the reply opens the next turn")
        XCTAssertEqual(interrupts.value, 1)
    }
}
