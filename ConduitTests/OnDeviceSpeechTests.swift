//
//  OnDeviceSpeechTests.swift
//  Conduit
//
//  Classic voice replies spoken on this iPhone, and the fallback from a
//  failing Hermes voice. An extension of the gateway tests: the hosted CI
//  plan is at its class budget, and these cover the same speech streams.
//

import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    // MARK: - Who speaks

    func testUnsetSpeechOutputSpeaksOnThisIPhoneUnlessHermesHasItsOwnVoice() {
        func snapshot(_ provider: String, ready: Bool) -> VoiceCapabilitySnapshot {
            VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: ready,
                unavailableReason: nil,
                selectedTTSProvider: provider
            )
        }

        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: snapshot("edge", ready: true)), .onDevice)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: snapshot("Edge", ready: true)), .onDevice)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: snapshot("elevenlabs", ready: false)), .onDevice)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: .unavailable), .onDevice)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: snapshot("openai", ready: true)), .hermes)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: .hermes, snapshot: snapshot("edge", ready: true)), .hermes)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: .onDevice, snapshot: snapshot("openai", ready: true)), .onDevice)
    }

    func testSpeechOutputChoiceSurvivesAndUnknownOnesReadAsAutomatic() throws {
        var preferences = VoiceProfilePreferences()
        preferences.speechOutput = .hermes
        let saved = try JSONDecoder().decode(
            VoiceProfilePreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        XCTAssertEqual(saved.speechOutput, .hermes)

        let newer = try JSONDecoder().decode(
            VoiceProfilePreferences.self,
            from: Data(#"{"speechOutput":"somethingNew","continuousConversation":false}"#.utf8)
        )
        XCTAssertNil(newer.speechOutput)
        XCTAssertFalse(newer.continuousConversation)
    }

    // MARK: - Speaking on this iPhone

    func testSentencesStartSpeakingWhileTheReplyStreams() {
        var text = "Hello there. The value is 3.5 now"
        XCTAssertEqual(OnDeviceSpeechStream.takeCompleteSentences(from: &text), "Hello there.")
        XCTAssertEqual(text, " The value is 3.5 now")

        var unfinished = "Still going"
        XCTAssertNil(OnDeviceSpeechStream.takeCompleteSentences(from: &unfinished))
        XCTAssertEqual(unfinished, "Still going")

        var chinese = "你好。今天"
        XCTAssertEqual(OnDeviceSpeechStream.takeCompleteSentences(from: &chinese), "你好。")
        XCTAssertEqual(chinese, "今天")
    }

    func testOnDeviceStreamSpeaksEverySentenceInOrderThenFinishes() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        var started: [Double] = []
        var played: [Data] = []
        let stream = OnDeviceSpeechStream(
            synthesizer: synthesizer,
            fallbackLanguage: "en",
            onStart: { started.append($0) },
            onPCM16: { data, _ in played.append(data) }
        )

        try await stream.append("First sentence. Sec")
        XCTAssertEqual(synthesizer.spoken, ["First sentence."])
        try await stream.append("ond one")
        let finishing = Task { try await stream.finish() }
        await Task.yield()
        synthesizer.finishCurrent(audio: Data([1, 0]))
        await waitUntil { synthesizer.spoken.count == 2 }
        XCTAssertEqual(synthesizer.spoken, ["First sentence.", "Second one"])
        synthesizer.finishCurrent(audio: Data([2, 0]))

        let streamedPCM = try await finishing.value
        XCTAssertTrue(streamedPCM)
        XCTAssertEqual(started, [22_050])
        XCTAssertEqual(played, [Data([1, 0]), Data([2, 0])])
    }

    func testOnDeviceStreamDoesNotReadMarkdownMarks() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let stream = OnDeviceSpeechStream(
            synthesizer: synthesizer,
            fallbackLanguage: "fr",
            onStart: { _ in },
            onPCM16: { _, _ in }
        )

        try await stream.append("La capitale est **Québec**. Le `code` et 5 ** 3")
        XCTAssertEqual(synthesizer.spoken, ["La capitale est Québec."])
        let finishing = Task { try await stream.finish() }
        await Task.yield()
        synthesizer.finishCurrent(audio: Data([1, 0]))
        await waitUntil { synthesizer.spoken.count == 2 }
        // A spaced mark is the text's own ("5 ** 3").
        XCTAssertEqual(synthesizer.spoken.last, "Le code et 5 ** 3")
        synthesizer.finishCurrent(audio: Data([2, 0]))
        _ = try await finishing.value
    }

    func testCancellingTheOnDeviceStreamStopsSpeech() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let stream = OnDeviceSpeechStream(
            synthesizer: synthesizer,
            fallbackLanguage: "en",
            onStart: { _ in },
            onPCM16: { _, _ in }
        )
        try await stream.append("Hello. ")
        stream.cancel()

        XCTAssertEqual(synthesizer.stopCount, 1)
        do {
            try await stream.append("More. ")
            XCTFail("a cancelled stream takes no more text")
        } catch is CancellationError {}
    }

    // MARK: - Falling back from Hermes

    func testHermesFailureBeforeAudioIsSpokenOnThisIPhone() async throws {
        let hermes = ScriptedSpeechStream(finishError: DashboardTicketBridgeError.requestFailed("Edge 403"))
        let onDevice = ScriptedSpeechStream()
        var fellBack = false
        let stream = try await FallbackSpeechStream.open(
            hermes: { _, _, _ in hermes },
            onDevice: { _, _ in onDevice },
            onFallback: { _ in fellBack = true },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )

        try await stream.append("Hello ")
        try await stream.append("there.")
        let streamedPCM = try await stream.finish()

        XCTAssertTrue(fellBack)
        XCTAssertTrue(streamedPCM)
        XCTAssertEqual(onDevice.appended.joined(), "Hello there.")
        XCTAssertTrue(onDevice.finished)
    }

    func testHermesThatCannotOpenIsSpokenOnThisIPhone() async throws {
        let onDevice = ScriptedSpeechStream()
        let stream = try await FallbackSpeechStream.open(
            hermes: { _, _, _ in throw DashboardTicketBridgeError.requestFailed("no ticket") },
            onDevice: { _, _ in onDevice },
            onFallback: { _ in },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )

        try await stream.append("Hi.")
        _ = try await stream.finish()

        XCTAssertEqual(onDevice.appended, ["Hi."])
    }

    func testHermesFailureAfterAudioStartedIsNotReplayed() async throws {
        let hermes = ScriptedSpeechStream(finishError: DashboardTicketBridgeError.requestFailed("dropped"))
        let onDevice = ScriptedSpeechStream()
        let stream = try await FallbackSpeechStream.open(
            hermes: { onStart, onPCM16, _ in
                hermes.onFinish = {
                    try onStart(24_000)
                    try onPCM16(Data([0, 0]), 24_000)
                }
                return hermes
            },
            onDevice: { _, _ in onDevice },
            onFallback: { _ in XCTFail("audio already played") },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )

        try await stream.append("Hello.")
        do {
            _ = try await stream.finish()
            XCTFail("the Hermes failure is the caller's once audio played")
        } catch {}
        XCTAssertTrue(onDevice.appended.isEmpty)
    }

    func testGatewaySpeaksOnThisIPhoneWhenChosen() async throws {
        let onDevice = ScriptedSpeechStream()
        let gateway = HermesVoiceGateway(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            baseURL: "https://example.com",
            profile: "default",
            speechOutput: { .onDevice },
            makeOnDeviceSpeech: { _, _ in onDevice }
        )

        let stream = try await gateway.openSpeechStream(onStart: { _ in }, onPCM16: { _, _ in }, onEncodedAudio: { _ in })

        XCTAssertTrue(stream === onDevice)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }
}

@MainActor
private final class FakeSpeechSynthesizer: OnDeviceSpeechSynthesizing {
    var spoken: [String] = []
    var stopCount = 0
    private var onAudio: (@MainActor (Data, Double) -> Void)?
    private var onDone: (@MainActor () -> Void)?

    func speak(
        _ text: String,
        language: String?,
        onAudio: @escaping @MainActor (Data, Double) -> Void,
        onDone: @escaping @MainActor () -> Void
    ) {
        spoken.append(text)
        self.onAudio = onAudio
        self.onDone = onDone
    }

    func stop() {
        stopCount += 1
        onAudio = nil
        onDone = nil
    }

    func finishCurrent(audio: Data) {
        let done = onDone
        onAudio?(audio, 22_050)
        onAudio = nil
        onDone = nil
        done?()
    }
}

@MainActor
private final class ScriptedSpeechStream: VoiceSpeechStream {
    var appended: [String] = []
    var finished = false
    var cancelled = false
    var onFinish: (@MainActor () throws -> Void)?
    private let finishError: Error?

    init(finishError: Error? = nil) {
        self.finishError = finishError
    }

    func append(_ text: String) async throws {
        appended.append(text)
    }

    func finish() async throws -> Bool {
        try onFinish?()
        if let finishError { throw finishError }
        finished = true
        return true
    }

    func cancel() {
        cancelled = true
    }
}
