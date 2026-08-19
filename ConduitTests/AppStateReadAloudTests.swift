//
//  AppStateReadAloudTests.swift
//  Conduit
//
//  AppState-level regression coverage for audio ownership between the two
//  playback owners: the voice conversation controller and the manual read
//  aloud controller. Each owns a separate playback instance over the same
//  AVSpeech infrastructure, so AppState enforces mutual exclusion in both
//  directions — these tests pin that contract at the integration level
//  rather than in the isolated controller unit tests.
//

import XCTest
@testable import Conduit

@MainActor
final class AppStateReadAloudTests: XCTestCase {
    func testStartingReadAloudStopsInFlightSpeechTest() async {
        let harness = makeHarness(snapshot: ttsOnlySnapshot)
        let messageA = ChatMessage(id: "msg-a", role: .assistant, content: "Response A", timestamp: "1")

        // The user started the Settings TTS test and navigated away while it
        // was still speaking: the voice controller's own playback instance
        // is live.
        let speechTest = Task {
            await harness.voiceController.runSpeechTest(
                text: "Conduit voice is ready for this profile."
            )
        }
        await awaitUntil("the speech test to start speaking") {
            harness.voiceController.state == .speaking
        }
        XCTAssertTrue(harness.voicePlayback.isPlaying)

        // The user taps Read Aloud on an assistant response.
        harness.appState.toggleReadAloud(message: messageA)

        // Synchronous at the call site: the voice controller is fully stopped
        // before the manual playback task has even started.
        XCTAssertFalse(harness.voicePlayback.isPlaying)
        XCTAssertEqual(harness.voiceController.state, .idle)
        XCTAssertEqual(harness.readAloudController.state, .preparing(messageID: "msg-a"))

        await awaitUntil("read aloud to reach playing") {
            harness.readAloudController.state == .playing(messageID: "msg-a")
        }
        XCTAssertTrue(harness.readAloudPlayback.isPlaying)
        XCTAssertEqual(harness.voiceGateway.streams[0].cancelCount, 1)

        // The interrupted test settles as a failure, never a success.
        let result = await speechTest.value
        XCTAssertFalse(result.passed, "A cancelled speech test must not report success")

        harness.readAloudController.stop()
    }

    func testStoppingActiveReadAloudDoesNotResetVoiceController() async {
        let harness = makeHarness(snapshot: ttsOnlySnapshot)
        let messageA = ChatMessage(id: "msg-a", role: .assistant, content: "Response A", timestamp: "1")

        harness.appState.toggleReadAloud(message: messageA)
        await awaitUntil("read aloud to reach playing") {
            harness.readAloudController.state == .playing(messageID: "msg-a")
        }
        // The start path already stopped the (idle) voice controller once;
        // the stop-only path must add no further reset.
        let voiceStopsAfterStart = harness.voicePlayback.stopCount
        XCTAssertGreaterThanOrEqual(voiceStopsAfterStart, 1)
        let voiceStateAfterStart = harness.voiceController.state

        harness.appState.toggleReadAloud(message: messageA)

        XCTAssertEqual(harness.readAloudController.state, .idle)
        XCTAssertFalse(harness.readAloudPlayback.isPlaying)
        XCTAssertEqual(harness.voicePlayback.stopCount, voiceStopsAfterStart)
        XCTAssertEqual(harness.voiceController.state, voiceStateAfterStart)
    }

    func testReadAloudTakeoverBetweenMessagesStillWorks() async {
        let harness = makeHarness(snapshot: ttsOnlySnapshot)
        let messageA = ChatMessage(id: "msg-a", role: .assistant, content: "Response A", timestamp: "1")
        let messageB = ChatMessage(id: "msg-b", role: .assistant, content: "Response B", timestamp: "2")

        harness.appState.toggleReadAloud(message: messageA)
        await awaitUntil("read aloud to play message A") {
            harness.readAloudController.state == .playing(messageID: "msg-a")
        }
        XCTAssertEqual(harness.readAloudGateway.openCount, 1)

        harness.appState.toggleReadAloud(message: messageB)
        await awaitUntil("read aloud to play message B") {
            harness.readAloudController.state == .playing(messageID: "msg-b")
        }

        XCTAssertEqual(harness.readAloudGateway.openCount, 2)
        XCTAssertEqual(harness.readAloudGateway.streams[0].cancelCount, 1)
        XCTAssertTrue(harness.readAloudPlayback.isPlaying)

        harness.readAloudController.stop()
    }

    func testTTSOnlyAvailabilityIsIndependentOfTranscription() {
        let harness = makeHarness(snapshot: ttsOnlySnapshot)

        // TTS without any STT capability is exactly the case read aloud must
        // support.
        XCTAssertNil(harness.appState.readAloudUnavailableReason)

        let sttOnly = VoiceCapabilitySnapshot(
            isGatewayConnected: true,
            supportsTranscription: true,
            supportsSpeech: false,
            unavailableReason: "no TTS provider configured"
        )
        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: harness.bridge,
            snapshot: sttOnly,
            isVoiceEnabled: true
        )
        XCTAssertEqual(
            harness.appState.readAloudUnavailableReason,
            "This Hermes profile has no ready text-to-speech provider."
        )

        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: harness.bridge,
            snapshot: ttsOnlySnapshot,
            isVoiceEnabled: false
        )
        XCTAssertEqual(
            harness.appState.readAloudUnavailableReason,
            "Enable voice for this profile in Settings."
        )

        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: harness.bridge,
            snapshot: ttsOnlySnapshot,
            isVoiceEnabled: true
        )
        harness.appState.isConnected = false
        XCTAssertEqual(
            harness.appState.readAloudUnavailableReason,
            "Connect to Hermes before reading responses aloud."
        )
    }

    private var ttsOnlySnapshot: VoiceCapabilitySnapshot {
        VoiceCapabilitySnapshot(
            isGatewayConnected: true,
            supportsTranscription: false,
            supportsSpeech: true,
            unavailableReason: nil
        )
    }

    private func makeHarness(snapshot: VoiceCapabilitySnapshot) -> Harness {
        let suite = "AppStateReadAloudTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true

        let voicePlayback = MockVoicePlayback()
        let voiceGateway = MockVoiceGateway(pausesAfterEmission: true)
        let voiceController = VoiceConversationController(
            capture: MockVoiceCapture(),
            playback: voicePlayback,
            deviceTranscriber: MockVoiceTranscriber(),
            gateway: voiceGateway,
            submit: { _ in false },
            interrupt: {}
        )
        appState.voiceConversationController = voiceController

        let readAloudPlayback = MockVoicePlayback()
        let readAloudGateway = MockVoiceGateway(pausesAfterEmission: true)
        let readAloudController = MessageReadAloudController(
            playback: readAloudPlayback,
            gateway: readAloudGateway,
            reportError: { _ in }
        )
        appState.messageReadAloudController = readAloudController

        let bridge = DashboardTicketBridge(baseURL: "https://example.com")
        appState.installVoiceCapabilityStateForTesting(
            bridge: bridge,
            snapshot: snapshot,
            isVoiceEnabled: true
        )

        return Harness(
            appState: appState,
            bridge: bridge,
            voiceController: voiceController,
            voicePlayback: voicePlayback,
            voiceGateway: voiceGateway,
            readAloudController: readAloudController,
            readAloudPlayback: readAloudPlayback,
            readAloudGateway: readAloudGateway
        )
    }

    private func awaitUntil(
        _ description: String,
        timeout: TimeInterval = 2.0,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct Harness {
    let appState: AppState
    let bridge: DashboardTicketBridge
    let voiceController: VoiceConversationController
    let voicePlayback: MockVoicePlayback
    let voiceGateway: MockVoiceGateway
    let readAloudController: MessageReadAloudController
    let readAloudPlayback: MockVoicePlayback
    let readAloudGateway: MockVoiceGateway
}

@MainActor
private final class MockVoiceCapture: AudioCaptureService {
    let events: AsyncStream<VoiceCaptureEvent>

    init() {
        events = AsyncStream { _ in }
    }

    func requestPermission() async -> Bool { true }
    func startListening(includePreRoll: Bool) throws {}
    func beginBargeInMonitoring() throws {}
    func pause() {}
    func resume() throws {}
    func finishUtterance() throws -> VoiceCapturedAudio {
        VoiceCapturedAudio(wavData: Data(), pcm16Data: Data(), sampleRate: 16_000, duration: 0)
    }
    func stop() {}
}

@MainActor
private final class MockVoicePlayback: SpeechPlaybackService {
    var isPlaying = false
    private(set) var stopCount = 0

    func start(sampleRate: Double) throws { isPlaying = true }
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int { data.count / 2 }
    func playEncodedAudioData(_ data: Data) throws { isPlaying = true }
    func finish() throws {}
    func drain() async { isPlaying = false }
    func stop() {
        isPlaying = false
        stopCount += 1
    }
}

@MainActor
private final class MockVoiceTranscriber: DeviceSpeechTranscriptionService {
    func requestPermission() async -> Bool { true }
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String { "transcript" }
    func cancel() {}
}

@MainActor
private final class MockVoiceGateway: VoiceGatewayService {
    let profile = "default"
    private(set) var openCount = 0
    private(set) var streams: [MockVoiceStream] = []
    private let pausesAfterEmission: Bool

    init(pausesAfterEmission: Bool) { self.pausesAfterEmission = pausesAfterEmission }

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String { "transcript" }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        openCount += 1
        let stream = MockVoiceStream(pausesAfterEmission: pausesAfterEmission)
        streams.append(stream)
        try onStart(24_000)
        try onPCM16(Data(repeating: 1, count: 8), 24_000)
        return stream
    }
}

@MainActor
private final class MockVoiceStream: VoiceSpeechStream {
    private(set) var appended: [String] = []
    private(set) var cancelCount = 0
    private let pausesAfterEmission: Bool
    private var appendContinuation: CheckedContinuation<Void, Error>?
    private var isCancelled = false

    init(pausesAfterEmission: Bool) { self.pausesAfterEmission = pausesAfterEmission }

    func append(_ text: String) async throws {
        appended.append(text)
        guard pausesAfterEmission else { return }
        if isCancelled { throw URLError(.cancelled) }
        try await withCheckedThrowingContinuation { continuation in
            appendContinuation = continuation
            if isCancelled {
                appendContinuation = nil
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }

    func finish() async throws -> Bool { true }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelCount += 1
        let continuation = appendContinuation
        appendContinuation = nil
        continuation?.resume(throwing: URLError(.cancelled))
    }
}
