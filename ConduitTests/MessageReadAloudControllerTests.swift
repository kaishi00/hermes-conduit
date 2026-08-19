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
        reported: @escaping (String) -> Void = { _ in }
    ) -> MessageReadAloudController {
        MessageReadAloudController(playback: playback, gateway: gateway, reportError: reported)
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
            "This Hermes profile has no ready text-to-speech provider."
        )
        XCTAssertNotNil(MessageReadAloudController.unavailableReason(isConnected: false, isVoiceEnabled: true, snapshot: ttsOnly))
        XCTAssertNotNil(MessageReadAloudController.unavailableReason(isConnected: true, isVoiceEnabled: false, snapshot: ttsOnly))
    }

    func testSceneBackgroundCancelsActivePlayback() async {
        let playback = MockReadAloudPlayback()
        let gateway = MockReadAloudGateway(emitsPCM: true)
        gateway.pauseAfterEmission = true
        let controller = makeController(playback: playback, gateway: gateway)

        controller.toggle(messageID: "message-a", content: "Background")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .playing(messageID: "message-a"))

        controller.setForegroundActive(false)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.streams.last?.cancelCount, 1)
        XCTAssertFalse(playback.isPlaying)

        controller.toggle(messageID: "message-b", content: "Refused")
        XCTAssertEqual(gateway.openCount, 1, "Read aloud must not start while backgrounded")
        XCTAssertEqual(controller.state, .idle)

        controller.setForegroundActive(true)
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
private final class MockReadAloudPlayback: SpeechPlaybackService {
    private(set) var startedSampleRates: [Double] = []
    private(set) var enqueuedPCM: [(data: Data, sampleRate: Double)] = []
    private(set) var encodedFrames: [Data] = []
    private(set) var finishCount = 0
    private(set) var drainCount = 0
    private(set) var stopCount = 0
    var isPlaying = false
    var startError: Error?
    var enqueueError: Error?
    /// When set, drain() suspends until stop() releases it — models audio
    /// that is still playing out.
    var blockDrain = false
    private var drainWaiter: CheckedContinuation<Void, Never>?

    func start(sampleRate: Double) throws {
        if let startError { throw startError }
        startedSampleRates.append(sampleRate)
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

    func stop() {
        stopCount += 1
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
        streams.append(stream)
        if let openError { throw openError }
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
