//
//  VoiceConversationControllerTests+LiveTranscription.swift
//  Conduit
//
//  Hermes' live speech-to-text (stt.streaming): the controller opens it when
//  speech starts, feeds it the recording, shows its partial words, and uses
//  its final transcript instead of uploading the recording. Without a final
//  transcript the upload still runs.
//

import XCTest
@testable import Conduit

extension VoiceConversationControllerTests {
    func testLiveTranscriptReplacesTheUploadAndShowsWordsWhileSpeaking() async {
        let capture = MockCapture(permissionGranted: true)
        capture.recordedPCM16 = Data([1, 0, 2, 0])
        let gateway = LiveTranscriptionGatewayStub(finalText: "Live words")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        await gateway.pushes.waitUntil(1, timeout: 10)
        XCTAssertEqual(gateway.session?.pushed, [Data([1, 0, 2, 0])])

        gateway.onPartial?("Live")
        XCTAssertEqual(controller.liveTranscript, "Live")

        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["Live words"])
        XCTAssertEqual(gateway.base.transcriptionCount, 0)
        XCTAssertEqual(gateway.session?.finishCount, 1)
        XCTAssertEqual(controller.liveTranscript, "")
    }

    func testRecordingIsUploadedWhenTheLiveTranscriptIsMissing() async {
        let capture = MockCapture(permissionGranted: true)
        capture.recordedPCM16 = Data([1, 0])
        let gateway = LiveTranscriptionGatewayStub(finalText: nil, transcript: "Uploaded words")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        await gateway.pushes.waitUntil(1, timeout: 10)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["Uploaded words"])
        XCTAssertEqual(gateway.base.transcriptionCount, 1)
    }

    func testFailedOpenIsNotRetriedWithinTheSameWindow() async {
        let capture = MockCapture(permissionGranted: true)
        capture.recordedPCM16 = Data([1, 0])
        let gateway = LiveTranscriptionGatewayStub(finalText: nil, transcript: "Uploaded words")
        gateway.opensSession = false
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        await gateway.opens.waitUntil(1, timeout: 10)
        controller.ingestAudioLevel(0.1, at: start.addingTimeInterval(0.1))
        controller.ingestAudioLevel(0.1, at: start.addingTimeInterval(0.2))
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.5))
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(gateway.openCount, 1)
        XCTAssertEqual(submitted.texts, ["Uploaded words"])
    }

    func testOnDeviceTranscriptionNeverOpensLiveTranscription() async {
        let capture = MockCapture(permissionGranted: true)
        capture.recordedPCM16 = Data([1, 0])
        let gateway = LiveTranscriptionGatewayStub(finalText: "Live words")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            deviceTranscriber: MockDeviceTranscriber(transcript: "Apple transcript"),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        var preferences = VoiceProfilePreferences()
        preferences.transcriptionMode = .appleOnDevice
        controller.setProfilePreferences(preferences)
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["Apple transcript"])
        XCTAssertEqual(gateway.openCount, 0)
    }
}

@MainActor
private final class LiveTranscriptionGatewayStub: VoiceGatewayService, VoiceLiveTranscriptionGateway {
    let base: MockGateway
    let finalText: String?
    /// False mimics a failed open (no ticket): nil, and nothing to stream.
    var opensSession = true
    let pushes = AwaitableCounter()
    let opens = AwaitableCounter()
    private(set) var openCount = 0
    private(set) var session: MockLiveTranscription?
    private(set) var onPartial: (@MainActor (String) -> Void)?

    init(finalText: String?, transcript: String = "Uploaded") {
        base = MockGateway(transcript: transcript)
        self.finalText = finalText
    }

    var profile: String { base.profile }

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        try await base.transcribe(audio)
    }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        try await base.openSpeechStream(onStart: onStart, onPCM16: onPCM16, onEncodedAudio: onEncodedAudio)
    }

    func openLiveTranscription(
        sampleRate: Double,
        onPartial: @escaping @MainActor (String) -> Void,
        onUnavailable: @escaping @MainActor () -> Void
    ) async -> VoiceLiveTranscription? {
        openCount += 1
        opens.increment()
        guard opensSession else { return nil }
        self.onPartial = onPartial
        let session = MockLiveTranscription(finalText: finalText, pushes: pushes)
        self.session = session
        return session
    }
}

@MainActor
private final class MockLiveTranscription: VoiceLiveTranscription {
    let finalText: String?
    let pushes: AwaitableCounter
    private(set) var pushed: [Data] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init(finalText: String?, pushes: AwaitableCounter) {
        self.finalText = finalText
        self.pushes = pushes
    }

    func push(_ pcm16: Data) {
        pushed.append(pcm16)
        pushes.increment()
    }

    func finish() async -> String? {
        finishCount += 1
        return finalText
    }

    func cancel() { cancelCount += 1 }
}
