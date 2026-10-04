import XCTest
@testable import Conduit

private struct ReadAloudTestError: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

@MainActor
final class MessageReadAloudControllerTests: XCTestCase {
    private func makeController(
        playback: MockReadAloudPlayback,
        gateway: MockReadAloudGateway,
        nowPlaying: MockReadAloudNowPlaying? = nil,
        reported: @escaping (String) -> Void = { _ in }
    ) -> MessageReadAloudController {
        MessageReadAloudController(
            playback: playback,
            gateway: gateway,
            beginBackgroundActivity: { _ in {} },
            nowPlaying: nowPlaying ?? MockReadAloudNowPlaying(),
            reportError: reported
        )
    }

    func testToggleOpensOneStreamWithFullMessageText() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway()
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "The full response text.")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gateway.openCount, 1)
        XCTAssertEqual(gateway.streams.last?.appended, ["The full response text."])
        XCTAssertEqual(gateway.streams.last?.finishCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(playback.finishCount, 1)
        XCTAssertEqual(playback.drainCount, 1)
    }

    func testStreamedPCMReachesPlaybackAndEntersPlayingState() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Streaming")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))
        XCTAssertEqual(playback.startedSampleRates, [24_000])
        XCTAssertEqual(playback.enqueuedPCM.count, 1)

        gateway.streams.last?.releaseAppendForTest()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .idle)
    }

    func testEachPlaybackStartsAtTheSpeedChosenWhenTapped() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        var speed: Float = 1.5
        let controller = MessageReadAloudController(
            playback: playback,
            gateway: gateway,
            playbackRate: { speed }
        )

        controller.toggle(messageID: "message-a", content: "First")
        for _ in 0..<1_000 where controller.state != .idle { await Task.yield() }
        XCTAssertEqual(controller.state, .idle)
        speed = 2
        controller.toggle(messageID: "message-b", content: "Second")
        for _ in 0..<1_000 where playback.startedRates.count < 2 { await Task.yield() }

        XCTAssertEqual(playback.startedRates, [1.5, 2])
    }

    func testReadAloudSpeedReadsTheStoredChoice() throws {
        let suite = "MessageReadAloudControllerTests.speed"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ReadAloudSpeed.current(defaults: defaults), .normal)
        defaults.set(1.5, forKey: ReadAloudSpeed.preferenceKey)
        XCTAssertEqual(ReadAloudSpeed.current(defaults: defaults), .faster)
        defaults.set(3.0, forKey: ReadAloudSpeed.preferenceKey)
        XCTAssertEqual(ReadAloudSpeed.current(defaults: defaults), .normal, "an unknown value plays at 1x")
        XCTAssertEqual(ReadAloudSpeed.allCases.map(\.label), ["1x", "1.25x", "1.5x", "1.75x", "2x"])
    }

    func testEncodedFallbackReachesPlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsEncoded: true)
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Fallback")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(playback.encodedFrames, [Data([0x01, 0x02, 0x03])])
        XCTAssertTrue(playback.enqueuedPCM.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func testPlaybackFinishesAndDrainsBeforeReturningToIdle() async {
        let playback = MockReadAloudPlayback()
        playback.blockDrain = true
        let gateway = MockReadAloudGateway(emitsPCM: true)
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Drain")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(playback.finishCount, 1)
        XCTAssertEqual(playback.drainCount, 1)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        playback.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(playback.isPlaying)
    }

    func testTappingActiveMessageStopsPlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Playing")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        controller.toggle(messageID: "message-a", content: "Playing")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.openCount, 1, "Tapping the active message must not open a new stream")
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
        XCTAssertFalse(playback.isPlaying)
    }

    func testStartingAnotherMessageCancelsActivePlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "First")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        controller.toggle(messageID: "message-b", content: "Second")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gateway.openCount, 2)
        XCTAssertEqual(gateway.streams.first?.cancelCount, 1)
        XCTAssertEqual(gateway.streams.first?.finishCount, 0)
        XCTAssertEqual(gateway.streams.last?.appended, ["Second"])
        XCTAssertEqual(controller.state, .playing(messageID: "message-b"))

        gateway.streams.last?.releaseAppendForTest()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .idle)
    }

    func testSupersededOperationCannotClearNewerState() async {
        let playback = MockReadAloudPlayback()
        playback.blockDrain = true
        let gateway = MockReadAloudGateway(emitsPCM: true)
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "First")
        try? await Task.sleep(nanoseconds: 50_000_000)
        // A has emitted audio, finished its stream, and is now suspended in
        // the playback drain.
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))
        XCTAssertEqual(playback.drainCount, 1)

        // Starting B stops A's drain; A's late completion must not clear B.
        controller.toggle(messageID: "message-b", content: "Second")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .playing(messageID: "message-b"))
        XCTAssertEqual(gateway.openCount, 2)

        controller.stop()
        XCTAssertEqual(controller.state, .idle)
    }

    func testStopDuringStreamCreationCannotRevivePlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway()
        gateway.blocksOpen = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Slow open")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .preparing(messageID: "message-a"))

        controller.stop()
        XCTAssertEqual(controller.state, .idle)

        gateway.resumeOpenForTest()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .idle, "A late stream-open must not be adopted after a stop")
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
        XCTAssertFalse(playback.isPlaying)
    }

    func testStopDuringFinishCannotRevivePlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.blocksFinish = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Slow finish")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))
        XCTAssertEqual(gateway.streams.last?.finishCount, 1)

        controller.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
        XCTAssertEqual(playback.finishCount, 0, "The superseded operation must not finish the newer operation's playback")
        XCTAssertEqual(playback.drainCount, 0)
    }

    func testSupersededCatchCannotReleaseNewerStream() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        // A's cancel error is deferred so it lands only after B has adopted
        // its own stream — the interleaving a stale catch must survive.
        gateway.blocksCancelDelivery = true
        var reported: [String] = []
        let controller = makeController(playback: playback, gateway: gateway) { reported.append($0) }

        controller.toggle(messageID: "message-a", content: "First")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        gateway.blocksCancelDelivery = false
        controller.toggle(messageID: "message-b", content: "Second")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-b"))

        gateway.streams.first?.releaseCancelForTest()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .playing(messageID: "message-b"), "A superseded operation's catch must not disturb the newer operation")
        XCTAssertEqual(gateway.streams.first?.cancelCount, 1)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 0, "Only stop() may cancel the newer operation's stream")
        XCTAssertTrue(reported.isEmpty)

        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
    }

    func testMidStreamFailureStopsPlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        var reported: [String] = []
        let controller = makeController(playback: playback, gateway: gateway) { reported.append($0) }

        controller.toggle(messageID: "message-a", content: "Dying stream")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))
        XCTAssertTrue(playback.isPlaying)

        gateway.streams.last?.releaseAppendForTest(throwing: ReadAloudTestError(description: "Stream lost mid-response"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .failed(messageID: "message-a", message: "Stream lost mid-response"))
        XCTAssertEqual(reported, ["Stream lost mid-response"])
        XCTAssertFalse(playback.isPlaying, "A mid-stream failure must settle the audio, not leave it running under .failed")
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
    }

    func testGatewayFailureLeavesRecoverableState() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway()
        gateway.openError = ReadAloudTestError(description: "Speech provider exploded")
        var reported: [String] = []
        let controller = makeController(playback: playback, gateway: gateway) { reported.append($0) }

        controller.toggle(messageID: "message-a", content: "Broken")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .failed(messageID: "message-a", message: "Speech provider exploded"))
        XCTAssertEqual(reported, ["Speech provider exploded"])
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(gateway.streams.count, 0, "A failed open must not leave a recorded stream")

        gateway.openError = nil
        controller.toggle(messageID: "message-a", content: "Broken")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gateway.openCount, 2, "The failed message can be retried after recovery")
        XCTAssertEqual(controller.state, .idle)
    }

    func testPlaybackStartFailureSurfacesRecoverableState() async {
        let playback = MockReadAloudPlayback()
        playback.startError = ReadAloudTestError(description: "Playback engine failed")
        let gateway = MockReadAloudGateway(emitsPCM: true)
        var reported: [String] = []
        let controller = makeController(playback: playback, gateway: gateway) { reported.append($0) }

        controller.toggle(messageID: "message-a", content: "Broken audio")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .failed(messageID: "message-a", message: "Playback engine failed"))
        XCTAssertEqual(reported, ["Playback engine failed"])

        playback.startError = nil
        controller.toggle(messageID: "message-b", content: "Healthy audio")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .idle, "A different message can start after a playback failure")
    }

    func testPCMEnqueueFailureStopsAndFails() async {
        let playback = MockReadAloudPlayback()
        playback.enqueueError = ReadAloudTestError(description: "Enqueue failed")
        let gateway = MockReadAloudGateway(emitsPCM: true)
        var reported: [String] = []
        let controller = makeController(playback: playback, gateway: gateway) { reported.append($0) }

        controller.toggle(messageID: "message-a", content: "Broken queue")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .failed(messageID: "message-a", message: "Enqueue failed"))
        XCTAssertEqual(reported, ["Enqueue failed"])
        XCTAssertFalse(playback.isPlaying, "A failed enqueue must settle the engine")
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
    }

    func testEmptyContentDoesNotStartOrStopPlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "   \n\t ")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(gateway.openCount, 0)
        XCTAssertEqual(controller.state, .idle)

        controller.toggle(messageID: "message-b", content: "Real content")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-b"))

        controller.toggle(messageID: "message-c", content: "  ")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-b"), "An unreadable message must not interrupt active playback")
        XCTAssertEqual(gateway.openCount, 1)

        // Release the paused mock stream so the test doesn't end with a
        // suspended append continuation.
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
    }

    func testRepeatedStopsAreHarmless() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway()
        gateway.blocksOpen = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.stop()
        controller.stop()
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.openCount, 0)

        controller.toggle(messageID: "message-a", content: "Preparing")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .preparing(messageID: "message-a"))
        controller.stop()
        controller.stop()
        XCTAssertEqual(controller.state, .idle)

        gateway.resumeOpenForTest()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .idle)
    }

    func testTTSONlyAvailabilityDoesNotRequireTranscription() {
        let ttsOnly = VoiceCapabilitySnapshot(
            isGatewayConnected: true,
            supportsTranscription: false,
            supportsSpeech: true,
            unavailableReason: nil
        )
        XCTAssertNil(
            MessageReadAloudController.unavailableReason(isConnected: true, isVoiceEnabled: true, snapshot: ttsOnly),
            "Read aloud must work when TTS is configured even though STT is unavailable"
        )

        let noSpeech = VoiceCapabilitySnapshot(
            isGatewayConnected: true,
            supportsTranscription: true,
            supportsSpeech: false,
            unavailableReason: "no tts"
        )
        XCTAssertEqual(
            MessageReadAloudController.unavailableReason(isConnected: true, isVoiceEnabled: true, snapshot: noSpeech),
            "This Hermes profile has no ready text-to-speech provider. Set one up in Settings > Voice."
        )
        XCTAssertNotNil(MessageReadAloudController.unavailableReason(isConnected: false, isVoiceEnabled: true, snapshot: ttsOnly))
        XCTAssertNotNil(MessageReadAloudController.unavailableReason(isConnected: true, isVoiceEnabled: false, snapshot: ttsOnly))
    }

    func testSceneBackgroundKeepsActivePlaybackButRefusesNewTaps() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Background")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        // Home, lock, or Control Center: the reply keeps reading (#373).
        controller.setForegroundActive(false)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))
        XCTAssertEqual(gateway.streams.last?.cancelCount, 0)
        XCTAssertTrue(playback.isPlaying)

        controller.toggle(messageID: "message-b", content: "Refused")
        XCTAssertEqual(gateway.openCount, 1, "A new read aloud must not start while backgrounded")
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        // The playing reply can still be stopped from the background (its
        // own toggle), and foreground return admits new taps again.
        controller.toggle(messageID: "message-a", content: "Background")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)

        controller.setForegroundActive(true)
        controller.toggle(messageID: "message-b", content: "Admitted")
        XCTAssertEqual(controller.state, .preparing(messageID: "message-b"))
        controller.stop()
    }

    func testBackgroundedPlaybackFinishesNaturally() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway()
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Locked phone")
        controller.setForegroundActive(false)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.streams.last?.appended, ["Locked phone"])
        XCTAssertEqual(gateway.streams.last?.finishCount, 1)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 0)
    }

    func testBackgroundActivityIsHeldForEachOperationAndReleasedOnSettle() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway()
        var began = 0
        var ended = 0
        let controller = MessageReadAloudController(
            playback: playback,
            gateway: gateway,
            beginBackgroundActivity: { _ in
                began += 1
                return { ended += 1 }
            },
            nowPlaying: MockReadAloudNowPlaying()
        )

        controller.toggle(messageID: "message-a", content: "Natural finish")
        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, 0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(ended, 1, "A finished reply releases its background activity")

        let blocking = MockReadAloudGateway(emitsPCM: true)
        blocking.pauseAfterEmission = true
        controller.setGateway(blocking)
        controller.toggle(messageID: "message-b", content: "Stopped")
        controller.toggle(messageID: "message-c", content: "Takes over")
        XCTAssertEqual(began, 3)
        XCTAssertEqual(ended, 2, "A superseded operation releases its activity before the next one begins")
        controller.stop()
        XCTAssertEqual(ended, 3)
        controller.stop()
        XCTAssertEqual(ended, 3, "Repeated stops never end an activity twice")
    }

    func testBackgroundTimeRunningOutBeforeAudioStopsThePreparingReply() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway()
        gateway.blocksOpen = true
        var expire: (@MainActor () -> Void)?
        let controller = MessageReadAloudController(
            playback: playback,
            gateway: gateway,
            beginBackgroundActivity: { onExpiration in
                expire = onExpiration
                return {}
            },
            nowPlaying: MockReadAloudNowPlaying()
        )

        controller.toggle(messageID: "message-a", content: "Slow open")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .preparing(messageID: "message-a"))

        expire?()
        XCTAssertEqual(controller.state, .idle, "An expired activity fails closed instead of spinning forever")
        gateway.resumeOpenForTest()
    }

    func testBackgroundTimeRunningOutWhilePlayingKeepsTheReply() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        var expire: (@MainActor () -> Void)?
        let controller = MessageReadAloudController(
            playback: playback,
            gateway: gateway,
            beginBackgroundActivity: { onExpiration in
                expire = onExpiration
                return {}
            },
            nowPlaying: MockReadAloudNowPlaying()
        )

        controller.toggle(messageID: "message-a", content: "Sounding")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        expire?()
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"), "Sounding audio keeps the app alive on its own")
        controller.stop()
    }

    func testNowPlayingPauseHoldsTheReplyAndResumeContinuesIt() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let nowPlaying = MockReadAloudNowPlaying()
        let controller = makeController(playback: playback, gateway: gateway, nowPlaying: nowPlaying)

        controller.toggle(messageID: "message-a", content: "## Morning summary\nSecond line")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))
        XCTAssertEqual(nowPlaying.titles, ["Morning summary"], "Now Playing begins once, titled by the first spoken line")

        controller.pause()
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"), "A paused reply still owns the message")
        XCTAssertEqual(playback.pauseCount, 1)
        XCTAssertEqual(nowPlaying.pausedUpdates, [true])
        XCTAssertEqual(gateway.streams.last?.cancelCount, 0)

        controller.resume()
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(playback.resumeCount, 1)
        XCTAssertEqual(nowPlaying.pausedUpdates, [true, false])

        controller.stop()
        XCTAssertEqual(nowPlaying.endCount, 1)
        XCTAssertFalse(controller.isPaused)
    }

    func testRemoteCommandsDriveTheActiveReply() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let nowPlaying = MockReadAloudNowPlaying()
        let controller = makeController(playback: playback, gateway: gateway, nowPlaying: nowPlaying)

        controller.toggle(messageID: "message-a", content: "Remote")
        try? await Task.sleep(nanoseconds: 50_000_000)
        let commands = try? XCTUnwrap(nowPlaying.commands)

        _ = commands?.togglePause()
        XCTAssertTrue(controller.isPaused)
        _ = commands?.togglePause()
        XCTAssertFalse(controller.isPaused)
        _ = commands?.pause()
        _ = commands?.resume()
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(playback.pauseCount, 2)
        XCTAssertEqual(playback.resumeCount, 2)

        _ = commands?.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
        XCTAssertEqual(nowPlaying.endCount, 1)
    }

    func testPauseIsRefusedBeforeAudioPlays() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway()
        gateway.blocksOpen = true
        let nowPlaying = MockReadAloudNowPlaying()
        let controller = makeController(playback: playback, gateway: gateway, nowPlaying: nowPlaying)

        controller.toggle(messageID: "message-a", content: "Still opening")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .preparing(messageID: "message-a"))
        controller.pause()
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(playback.pauseCount, 0)
        XCTAssertTrue(nowPlaying.titles.isEmpty, "Now Playing waits for the first audio")
        controller.stop()
        gateway.resumeOpenForTest()
    }

    func testForgottenPauseStopsTheReply() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)
        controller.pausedStopDelay = .milliseconds(50)

        controller.toggle(messageID: "message-a", content: "Forgotten")
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.pause()
        XCTAssertTrue(controller.isPaused)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
    }

    func testResumedReplyIsNotStoppedByTheEarlierPauseTimer() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)
        controller.pausedStopDelay = .milliseconds(50)

        controller.toggle(messageID: "message-a", content: "Resumed")
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.pause()
        controller.resume()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))
        controller.stop()
    }

    func testStreamRestartWhilePausedReportsTheReplyPlayingAgain() async throws {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let nowPlaying = MockReadAloudNowPlaying()
        let controller = makeController(playback: playback, gateway: gateway, nowPlaying: nowPlaying)
        controller.pausedStopDelay = .milliseconds(50)

        controller.toggle(messageID: "message-a", content: "Route change")
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.pause()
        XCTAssertTrue(controller.isPaused)

        // AirPods back in the case: the service restarts the stream and the
        // next chunk plays.
        playback.simulateStreamRestartForTest()
        try XCTUnwrap(gateway.streams.last).emitPCMForTest()

        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(nowPlaying.pausedUpdates, [true, false])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"), "The paused-stop timer must not end a sounding reply")
        controller.stop()
    }

    func testResumeAfterThePlaybackServiceStoppedSettlesTheReply() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let nowPlaying = MockReadAloudNowPlaying()
        let controller = makeController(playback: playback, gateway: gateway, nowPlaying: nowPlaying)

        controller.toggle(messageID: "message-a", content: "Phone call")
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.pause()
        // An interruption stopped the service while the reply was paused.
        playback.simulateStreamRestartForTest()

        XCTAssertFalse(controller.resume())
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(playback.resumeCount, 0)
        XCTAssertEqual(nowPlaying.endCount, 1)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
    }

    func testNowPlayingTitleUsesTheFirstSpokenLineAndTruncates() {
        XCTAssertEqual(ReadAloudNowPlaying.title(for: "\n\n  Hello there  \nMore"), "Hello there")
        let long = String(repeating: "word ", count: 40)
        let title = ReadAloudNowPlaying.title(for: long)
        XCTAssertLessThanOrEqual(title.count, ReadAloudNowPlaying.maxTitleLength)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testGatewayReplacementCancelsActivePlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Replaced")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        controller.setGateway(nil)
        XCTAssertEqual(controller.state, .idle, "Clearing the gateway (disconnect) invalidates the active operation")
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)

        let replacement = MockReadAloudGateway(emitsPCM: true)
        replacement.pauseAfterEmission = true
        controller.setGateway(replacement)
        controller.toggle(messageID: "message-b", content: "Second gateway")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-b"))

        controller.setGateway(MockReadAloudGateway())
        XCTAssertEqual(controller.state, .idle, "A profile/connection change replaces the gateway and stops playback")
        XCTAssertEqual(replacement.streams.last?.cancelCount, 1)
    }
}

@MainActor
private final class MockReadAloudNowPlaying: ReadAloudNowPlayingPresenting {
    private(set) var titles: [String] = []
    private(set) var commands: ReadAloudRemoteCommands?
    private(set) var pausedUpdates: [Bool] = []
    private(set) var endCount = 0

    func begin(title: String, commands: ReadAloudRemoteCommands) {
        titles.append(title)
        self.commands = commands
    }

    func setPaused(_ paused: Bool) { pausedUpdates.append(paused) }

    func end() {
        guard commands != nil else { return }
        commands = nil
        endCount += 1
    }
}

@MainActor
private final class MockReadAloudPlayback: SpeechPlaybackService {
    private(set) var startedSampleRates: [Double] = []
    private(set) var enqueuedPCM: [(data: Data, sampleRate: Double)] = []
    private(set) var encodedFrames: [Data] = []
    private(set) var finishCount = 0
    private(set) var drainCount = 0
    private(set) var stopCount = 0
    var isPlaying = false
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    var playbackRate: Float = 1
    private(set) var startedRates: [Float] = []
    var startError: Error?
    var enqueueError: Error?
    /// When set, drain() suspends until stop() releases it — models audio
    /// that is still playing out.
    var blockDrain = false
    private var drainWaiter: CheckedContinuation<Void, Never>?

    func start(sampleRate: Double) throws {
        if let startError { throw startError }
        startedSampleRates.append(sampleRate)
        startedRates.append(playbackRate)
        isPlaying = true
    }

    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int {
        if let enqueueError { throw enqueueError }
        enqueuedPCM.append((data, sampleRate))
        isPlaying = true
        return data.count - (data.count % 2)
    }

    func playEncodedAudioData(_ data: Data) throws {
        encodedFrames.append(data)
        isPlaying = true
    }

    func finish() throws { finishCount += 1 }

    func drain() async {
        drainCount += 1
        guard blockDrain else {
            isPlaying = false
            return
        }
        await withCheckedContinuation { continuation in
            drainWaiter = continuation
        }
        drainWaiter = nil
    }

    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var isPaused = false

    func pause() -> Bool {
        guard isPlaying else { return false }
        pauseCount += 1
        isPaused = true
        return true
    }

    func resume() {
        resumeCount += 1
        isPaused = false
    }

    /// Models a route change restarting the stream mid-pause.
    func simulateStreamRestartForTest() { isPaused = false }

    func stop() {
        stopCount += 1
        isPaused = false
        isPlaying = false
        let waiter = drainWaiter
        drainWaiter = nil
        waiter?.resume()
    }
}

@MainActor
private final class MockReadAloudStream: VoiceSpeechStream {
    private(set) var appended: [String] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private let emitsPCM: Bool
    private let emitsEncoded: Bool
    private let sampleRate: Double
    private let pauseAfterEmission: Bool
    private let blocksFinish: Bool
    private let blocksCancelDelivery: Bool
    private let onStart: @MainActor (Double) throws -> Void
    private let onPCM16: @MainActor (Data, Double) throws -> Void
    private let onEncodedAudio: @MainActor (Data) throws -> Void
    private var isCancelled = false
    private var appendContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Bool, Error>?
    private var deferredCancelResumes: [() -> Void] = []

    init(
        emitsPCM: Bool,
        emitsEncoded: Bool,
        sampleRate: Double,
        pauseAfterEmission: Bool,
        blocksFinish: Bool,
        blocksCancelDelivery: Bool,
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) {
        self.emitsPCM = emitsPCM
        self.emitsEncoded = emitsEncoded
        self.sampleRate = sampleRate
        self.pauseAfterEmission = pauseAfterEmission
        self.blocksFinish = blocksFinish
        self.blocksCancelDelivery = blocksCancelDelivery
        self.onStart = onStart
        self.onPCM16 = onPCM16
        self.onEncodedAudio = onEncodedAudio
    }

    func emitPCMForTest() throws {
        try onPCM16(Data(repeating: 1, count: 8), sampleRate)
    }

    func append(_ text: String) async throws {
        appended.append(text)
        guard !isCancelled else { throw URLError(.cancelled) }
        if emitsPCM {
            try onStart(sampleRate)
            try onPCM16(Data(repeating: 1, count: 8), sampleRate)
        }
        if emitsEncoded {
            try onEncodedAudio(Data([0x01, 0x02, 0x03]))
        }
        guard pauseAfterEmission else { return }
        try await withCheckedThrowingContinuation { continuation in
            appendContinuation = continuation
            if isCancelled {
                appendContinuation = nil
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }

    func finish() async throws -> Bool {
        finishCount += 1
        guard blocksFinish else { return false }
        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            if isCancelled {
                finishContinuation = nil
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelCount += 1
        let append = appendContinuation
        appendContinuation = nil
        let finish = finishContinuation
        finishContinuation = nil
        // Deferred delivery models a superseded operation whose error lands
        // only after a newer operation has already adopted its own stream.
        guard !blocksCancelDelivery else {
            if let append { deferredCancelResumes.append { append.resume(throwing: URLError(.cancelled)) } }
            if let finish { deferredCancelResumes.append { finish.resume(throwing: URLError(.cancelled)) } }
            return
        }
        append?.resume(throwing: URLError(.cancelled))
        finish?.resume(throwing: URLError(.cancelled))
    }

    func releaseCancelForTest() {
        let deferred = deferredCancelResumes
        deferredCancelResumes.removeAll()
        deferred.forEach { $0() }
    }

    func releaseAppendForTest(throwing error: Error? = nil) {
        let continuation = appendContinuation
        appendContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

@MainActor
private final class MockReadAloudGateway: VoiceGatewayService {
    let profile: String
    let emitsPCM: Bool
    let emitsEncoded: Bool
    let sampleRate: Double
    var openError: Error?
    var blocksOpen = false
    var pauseAfterEmission = false
    var blocksFinish = false
    var blocksCancelDelivery = false
    private(set) var openCount = 0
    private(set) var streams: [MockReadAloudStream] = []
    private var openContinuation: CheckedContinuation<VoiceSpeechStream, Error>?

    init(
        profile: String = "default",
        emitsPCM: Bool = false,
        emitsEncoded: Bool = false,
        sampleRate: Double = 24_000
    ) {
        self.profile = profile
        self.emitsPCM = emitsPCM
        self.emitsEncoded = emitsEncoded
        self.sampleRate = sampleRate
    }

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        XCTFail("Read aloud must never transcribe.")
        return ""
    }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        openCount += 1
        let stream = MockReadAloudStream(
            emitsPCM: emitsPCM,
            emitsEncoded: emitsEncoded,
            sampleRate: sampleRate,
            pauseAfterEmission: pauseAfterEmission,
            blocksFinish: blocksFinish,
            blocksCancelDelivery: blocksCancelDelivery,
            onStart: onStart,
            onPCM16: onPCM16,
            onEncodedAudio: onEncodedAudio
        )
        if let openError { throw openError }
        streams.append(stream)
        guard !blocksOpen else {
            return try await withCheckedThrowingContinuation { continuation in
                openContinuation = continuation
            }
        }
        return stream
    }

    func resumeOpenForTest() {
        guard let continuation = openContinuation, let stream = streams.last else { return }
        openContinuation = nil
        continuation.resume(returning: stream)
    }
}
