//
//  VoiceSpokenControlTests.swift
//  Conduit
//
//  Configurable spoken Voice controls: Stop phrases (existing semantics,
//  now editable) and End Conversation phrases (new category that closes the
//  Voice session through the existing Close teardown path).
//

import XCTest
@testable import Conduit

// MARK: - Matching and canonicalization

@MainActor
final class VoiceSpokenCommandMatchingTests: XCTestCase {
    func testDefaultStopPhrasesRemainUnchanged() {
        XCTAssertEqual(VoiceSpokenCommands.defaultStopPhrases, ["stop", "stop talking", "be quiet"])
        XCTAssertEqual(VoiceProfilePreferences().spokenStopPhrases, ["stop", "stop talking", "be quiet"])
    }

    func testDefaultEndConversationPhrases() {
        XCTAssertEqual(
            VoiceSpokenCommands.defaultEndConversationPhrases,
            ["goodbye", "bye", "end conversation", "that's all"]
        )
        XCTAssertEqual(VoiceProfilePreferences().spokenEndConversationPhrases, ["goodbye", "bye", "end conversation", "that's all"])
    }

    func testOlderPreferenceBlobWithoutEndConversationFieldDecodesWithDefaults() throws {
        let data = try XCTUnwrap(
            #"{"outputMuted":true,"continueWakeConversation":false,"spokenStopPhrases":["stop"]}"#
                .data(using: .utf8)
        )
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)

        XCTAssertEqual(preferences.spokenEndConversationPhrases, ["goodbye", "bye", "end conversation", "that's all"])
        XCTAssertEqual(preferences.spokenStopPhrases, ["stop"])
        XCTAssertTrue(preferences.outputMuted)
        XCTAssertTrue(preferences.continuousConversation, "absent continuousConversation still decodes as ON")
        XCTAssertEqual(preferences.resolvedTranscriptionMode, .hermes)
    }

    func testUtteranceCasePunctuationAndWhitespaceNormalizeToMatch() {
        let phrases = ["goodbye"]
        XCTAssertTrue(VoiceSpokenCommands.matches("Goodbye.", phrases: phrases))
        XCTAssertTrue(VoiceSpokenCommands.matches(" GOODBYE ", phrases: phrases))
        XCTAssertTrue(VoiceSpokenCommands.matches("goodbye", phrases: phrases))
        XCTAssertTrue(VoiceSpokenCommands.matches("Goodbye!!!", phrases: phrases))
    }

    func testConfiguredPhrasesAreNormalizedBeforeMatching() {
        let phrases = ["  Goodbye!  ", "BYE"]
        XCTAssertTrue(VoiceSpokenCommands.matches("Goodbye.", phrases: phrases))
        XCTAssertTrue(VoiceSpokenCommands.matches("bye", phrases: phrases))
    }

    func testApostropheVariantsMatchAcrossUtteranceAndPhrase() {
        // The default phrase uses U+0027; ASR often emits U+2019.
        XCTAssertTrue(VoiceSpokenCommands.matches("that's all", phrases: ["that's all"]))
        XCTAssertTrue(VoiceSpokenCommands.matches("that’s all", phrases: ["that's all"]))
        XCTAssertTrue(VoiceSpokenCommands.matches("that's all.", phrases: ["that’s all"]))
        XCTAssertTrue(VoiceSpokenCommands.matches("That’s All!", phrases: ["  that's all  "]))
        XCTAssertFalse(VoiceSpokenCommands.matches("that's all folks", phrases: ["that's all"]))
    }

    func testSubstringUtterancesNeverMatch() {
        XCTAssertTrue(VoiceSpokenCommands.matches("goodbye", phrases: ["goodbye"]))
        XCTAssertFalse(VoiceSpokenCommands.matches("I said goodbye to them", phrases: ["goodbye"]))
        XCTAssertFalse(
            VoiceSpokenCommands.matches("can you stop talking about that", phrases: ["stop", "stop talking"])
        )
    }

    func testEmptyCanonicalUtteranceNeverMatches() {
        XCTAssertFalse(VoiceSpokenCommands.matches("...", phrases: ["!!!"]))
        XCTAssertFalse(VoiceSpokenCommands.matches("   ", phrases: ["stop"]))
    }

    func testCanonicalizedPhraseListTrimsDropsBlanksAndDedupesCaseInsensitively() {
        let canonical = VoiceSpokenCommands.canonicalizedPhraseList(
            ["  Stop ", "", "STOP", "be quiet", "   ", "stop!"]
        )
        XCTAssertEqual(canonical, ["Stop", "be quiet"])
    }

    func testCanonicalizedPhraseListProducesPairwiseDistinctEntries() {
        // The phrase-list editor renders rows with value identity, so the
        // seeded representation must never contain duplicate raw strings —
        // including when it seeds from a legacy blob written before
        // canonicalization existed.
        let canonical = VoiceSpokenCommands.canonicalizedPhraseList(
            ["Stop", "stop", "STOP ", "be quiet", "be quiet.", "", "  ", "halt!"]
        )
        // Display form is the first occurrence, whitespace-trimmed only;
        // "halt!" still matches "halt" at runtime via canonicalization.
        XCTAssertEqual(canonical, ["Stop", "be quiet", "halt!"])
        XCTAssertEqual(Set(canonical).count, canonical.count)
    }

    func testEmptyListDisablesMatchingEntirely() {
        XCTAssertFalse(VoiceSpokenCommands.matches("stop", phrases: []))
        XCTAssertFalse(VoiceSpokenCommands.matches("goodbye", phrases: []))
    }
}

// MARK: - Controller runtime behavior

@MainActor
final class VoiceConversationSpokenEndCommandTests: XCTestCase {
    func testEndConversationPhraseIsConsumedAndClosesThroughClosePath() async {
        let (controller, capture, gateway, flags) = makeController(transcript: "Goodbye.")
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))
        await driveUtterance(controller)

        XCTAssertEqual(flags.endConversationCount, 1, "the Close teardown seam must be requested exactly once")
        XCTAssertEqual(gateway.transcriptionCount, 1)
        XCTAssertEqual(flags.submitTexts, [], "the command must never be submitted to Hermes")
        XCTAssertEqual(flags.interrupts, 1, "an active Hermes turn is cancelled through the same seam as Stop")
        XCTAssertFalse(controller.hasLiveVoiceSession, "the voice session must be fully closed")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1, "closing must not relisten")
        XCTAssertTrue(controller.conversationTranscript.isEmpty, "locally consumed commands create no transcript entry")
    }

    func testEndConversationFallbackStopsControllerWithoutCloseSeam() async {
        let (controller, capture, _, flags) = makeController(transcript: "goodbye", wiresCloseSeam: false)
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))
        await driveUtterance(controller)

        XCTAssertEqual(flags.endConversationCount, 0)
        XCTAssertFalse(controller.hasLiveVoiceSession, "without a Close seam the controller must still stop itself")
        XCTAssertEqual(capture.startCount, 1)
    }

    func testEndConversationClosesWithContinuousConversationOn() async {
        let (controller, capture, _, flags) = makeController(transcript: "goodbye")
        var preferences = preferences(endConversation: ["goodbye"])
        preferences.continuousConversation = true
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(controller.hasLiveVoiceSession, "continuous ON must not resurrect the session")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(flags.endConversationCount, 1)
    }

    func testEndConversationClosesWithContinuousConversationOff() async {
        let (controller, capture, _, flags) = makeController(transcript: "goodbye")
        var preferences = preferences(endConversation: ["goodbye"])
        preferences.continuousConversation = false
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(flags.endConversationCount, 1)
    }

    func testConflictPrecedenceEndConversationWinsOverStop() async {
        let (controller, capture, _, flags) = makeController(transcript: "stop")
        var preferences = preferences(endConversation: ["stop"])
        preferences.spokenStopPhrases = ["stop"]
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)

        XCTAssertEqual(flags.endConversationCount, 1, "the stronger action must be deterministic")
        XCTAssertFalse(controller.hasLiveVoiceSession, "end must close, not stop-and-relisten")
        XCTAssertEqual(flags.interrupts, 1)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testConfiguredStopPhraseIsConsumedInterruptsAndRelistensEvenWithContinuousOff() async {
        let (controller, capture, gateway, flags) = makeController(transcript: "Halt.")
        var preferences = preferences(endConversation: ["goodbye"])
        preferences.spokenStopPhrases = [" halt "]
        preferences.continuousConversation = false
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)

        XCTAssertEqual(gateway.transcriptionCount, 1)
        XCTAssertEqual(flags.submitTexts, [])
        XCTAssertEqual(flags.interrupts, 1)
        XCTAssertEqual(controller.state, .listening, "Stop remains a recovery restart even with continuous OFF")
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertTrue(controller.hasLiveVoiceSession)
        XCTAssertEqual(
            controller.conversationTranscript.last?.speaker, .user,
            "existing Stop transcript semantics are preserved"
        )
    }

    func testHeadsetBargeInThenGoodbyeEndsSessionWithoutStaleRelisten() async {
        let (controller, capture, gateway, flags) = makeController(
            transcript: "Question",
            routePolicy: .fullDuplex
        )
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))

        await driveToSpeaking(controller)
        gateway.transcript = "goodbye"
        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .listening, "full-duplex barge-in must reopen listening first")
        let startsAfterBargeIn = capture.startCount

        await driveUtterance(controller, silentFinish: true)

        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(flags.interrupts, 2, "one barge-in interruption plus one End Conversation interruption")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(capture.startCount, startsAfterBargeIn, "no stale relisten after the session closed")
    }

    func testSpeakerSafeRouteStaysHalfDuplexDuringTTSWithCommandPhrasesConfigured() async {
        let (controller, capture, gateway, flags) = makeController(
            transcript: "Question",
            routePolicy: .speakerSafeHalfDuplex
        )
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))

        await driveToSpeaking(controller)
        gateway.transcript = "goodbye"
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        let leakStart = Date()
        controller.ingestAudioLevel(0.5, at: leakStart)
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.31))
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.62))
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(controller.state, .speaking, "half-duplex playback must not open a command window")
        XCTAssertEqual(flags.endConversationCount, 0, "commands are recognized only on the transcription path")
        XCTAssertEqual(flags.interrupts, 0)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testSpeakerSafeManualInterruptThenGoodbyeEndsSession() async {
        let (controller, capture, gateway, flags) = makeController(
            transcript: "Question",
            routePolicy: .speakerSafeHalfDuplex
        )
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))

        await driveToSpeaking(controller)
        gateway.transcript = "goodbye"
        await controller.interruptAssistantPlayback()
        XCTAssertEqual(controller.state, .listening)

        await driveUtterance(controller, silentFinish: true)

        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(flags.interrupts, 2, "manual Interrupt plus End Conversation interruption")
        XCTAssertEqual(flags.endConversationCount, 1)
    }

    func testUserPauseSuppressesSpokenCommandRecognition() async {
        let (controller, capture, gateway, flags) = makeController(transcript: "goodbye")
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        controller.pauseMicrophone()

        let start = Date()
        capture.emit(level: 0.4, at: start)
        capture.emit(level: 0.4, at: start.addingTimeInterval(0.4))
        capture.emit(level: 0, at: start.addingTimeInterval(1.4))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(gateway.transcriptionCount, 0, "no transcription while the user paused the microphone")
        XCTAssertEqual(flags.endConversationCount, 0)
        XCTAssertEqual(flags.submitTexts, [])
        XCTAssertTrue(controller.isMicrophonePaused)
        XCTAssertTrue(controller.hasLiveVoiceSession)
    }

    func testLateAssistantEventsAfterSpokenEndCannotRestartCaptureOrPlayback() async {
        let (controller, capture, _, flags) = makeController(transcript: "goodbye")
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))
        await driveUtterance(controller)
        XCTAssertEqual(flags.endConversationCount, 1)
        let startsAtClose = capture.startCount

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "late answer"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "late answer"))
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, startsAtClose, "stale events must not reopen capture")
    }

    func testEmptyPhraseListsSubmitUtterancesNormally() async {
        let (controller, _, _, flags) = makeController(transcript: "goodbye")
        var preferences = preferences(endConversation: [])
        preferences.spokenStopPhrases = []
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)

        XCTAssertEqual(flags.endConversationCount, 0)
        XCTAssertEqual(flags.submitTexts, ["goodbye"], "with both lists empty nothing is consumed locally")
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertTrue(controller.hasLiveVoiceSession)
    }

    // MARK: fixtures

    final class Flags {
        var submitTexts: [String] = []
        var interrupts = 0
        var endConversationCount = 0
    }

    /// Weak holder so the Close-seam closure (mirroring AppState
    /// closeVoiceConversation) can reach the controller after init.
    private final class ControllerBox {
        weak var controller: VoiceConversationController?
    }

    private func makeController(
        transcript: String,
        routePolicy: VoiceBargeInRoutePolicy? = nil,
        wiresCloseSeam: Bool = true
    ) -> (VoiceConversationController, MockCapture, MockGateway, Flags) {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: transcript)
        let flags = Flags()
        let box = ControllerBox()
        // Explicitly typed locals: the combined init expression otherwise
        // blows up the Swift type checker (multiline + ternary closures).
        let routeProvider: (@MainActor () -> VoiceBargeInRoutePolicy)?
        if let routePolicy {
            routeProvider = { routePolicy }
        } else {
            routeProvider = nil
        }
        let submitAction: @MainActor (String) async -> Bool = { text in
            flags.submitTexts.append(text)
            return true
        }
        let interruptAction: @MainActor () async -> Void = {
            // The End Conversation teardown cancels the utterance task that
            // called it; the Hermes interrupt must still run in an
            // uncancelled task (HermesClient.rpc throws CancellationError
            // for cancelled work, which would leave the turn alive).
            XCTAssertFalse(Task.isCancelled)
            flags.interrupts += 1
        }
        let endAction: (@MainActor () -> Void)?
        if wiresCloseSeam {
            endAction = {
                flags.endConversationCount += 1
                box.controller?.endVoiceSession()
            }
        } else {
            endAction = nil
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: routeProvider,
            submit: submitAction,
            interrupt: interruptAction,
            onEndConversation: endAction
        )
        box.controller = controller
        return (controller, capture, gateway, flags)
    }

    private func preferences(endConversation: [String]) -> VoiceProfilePreferences {
        var preferences = VoiceProfilePreferences()
        preferences.spokenEndConversationPhrases = endConversation
        return preferences
    }

    /// Drives one complete listening → transcription cycle through the VAD
    /// finish path (the same deterministic pattern the existing suites use).
    /// `silentFinish` skips arming a fresh turn for callers whose capture is
    /// already live (post barge-in / manual Interrupt).
    private func driveUtterance(_ controller: VoiceConversationController, silentFinish: Bool = false) async {
        if !silentFinish {
            controller.beginVoiceTurn(sessionID: "session")
            await controller.startListening()
        }
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    private func driveToSpeaking(_ controller: VoiceConversationController) async {
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(controller.state, .thinking)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer."))
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(controller.state, .speaking)
    }
}

// MARK: - Mocks (file-local copies of the established voice doubles)

@MainActor
private final class MockCapture: AudioCaptureService {
    let events: AsyncStream<VoiceCaptureEvent>
    var captureGeneration: UInt64 = 0
    private var continuation: AsyncStream<VoiceCaptureEvent>.Continuation?
    private let permissionGranted: Bool
    private(set) var startCount = 0

    init(permissionGranted: Bool) {
        self.permissionGranted = permissionGranted
        var captured: AsyncStream<VoiceCaptureEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured
    }
    func requestPermission() async -> Bool { permissionGranted }
    func startListening(includePreRoll: Bool) throws {
        startCount += 1
        captureGeneration &+= 1
    }
    func beginBargeInMonitoring() throws {}
    func pause() { captureGeneration &+= 1 }
    func resume() throws { captureGeneration &+= 1 }
    func finishUtterance() throws -> VoiceCapturedAudio {
        VoiceCapturedAudio(wavData: Data([1]), pcm16Data: Data([1, 0]), sampleRate: 16_000, duration: 0.01)
    }
    func stop() { captureGeneration &+= 1 }
    func emit(level: Float, at date: Date = Date()) {
        continuation?.yield(.level(level, date: date, generation: captureGeneration))
    }
}

@MainActor
private final class MockPlayback: SpeechPlaybackService {
    var isPlaying = false
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    func start(sampleRate: Double) throws { isPlaying = true }
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int { data.count - (data.count % 2) }
    func playEncodedAudioData(_ data: Data) throws { isPlaying = true }
    func finish() throws {}
    func drain() async { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
private final class MockGateway: VoiceGatewayService {
    let profile = "default"
    /// Mutable so multi-phase tests can use a normal utterance to drive the
    /// assistant turn and a command utterance for the phase under test.
    var transcript: String
    private(set) var transcriptionCount = 0
    init(transcript: String) { self.transcript = transcript }
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        transcriptionCount += 1
        return transcript
    }
    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        // Mirror the production streaming provider: opening a stream for a
        // drain that has deltas delivers the start control immediately, so
        // playback state and playback-capture policy engage deterministically.
        try onStart(24_000)
        return MockSpeechStream()
    }
}

@MainActor
private final class MockSpeechStream: VoiceSpeechStream {
    func append(_ text: String) async throws {}
    func finish() async throws -> Bool { false }
    func cancel() {}
}

// MARK: - AppState persistence

@MainActor
final class AppStateVoiceSpokenPhraseTests: XCTestCase {
    func testSetSpokenStopPhrasesPersistsWithoutClobberingUnrelatedFields() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        var seed = VoiceProfilePreferences()
        seed.outputMuted = true
        seed.continuousConversation = false
        seed.continueWakeConversation = true
        seed.spokenStopPhrases = ["halt"]
        seed.spokenEndConversationPhrases = ["bye"]
        seed.transcriptionMode = .appleOnDevice
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        appState.setSpokenStopPhrases(["Halt", " stop ", "HALT", "  "])

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertEqual(loaded.spokenStopPhrases, ["Halt", "stop"], "entries canonicalize: trimmed, de-duplicated, blanks dropped")
        XCTAssertEqual(loaded.spokenEndConversationPhrases, ["bye"], "the other list must be untouched")
        XCTAssertTrue(loaded.outputMuted)
        XCTAssertFalse(loaded.continuousConversation)
        XCTAssertTrue(loaded.continueWakeConversation)
        XCTAssertEqual(loaded.resolvedTranscriptionMode, .appleOnDevice)
        XCTAssertEqual(
            appState.voiceConversationController.activePreferences.spokenStopPhrases, ["Halt", "stop"],
            "the live controller is reapplied"
        )
    }

    func testSetSpokenEndConversationPhrasesPersistsWithoutClobberingUnrelatedFields() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        var seed = VoiceProfilePreferences()
        seed.outputMuted = false
        seed.spokenStopPhrases = ["stop"]
        seed.spokenEndConversationPhrases = ["goodbye"]
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        appState.setSpokenEndConversationPhrases(["See ya", " goodbye ", "SEE YA", ""])

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertEqual(loaded.spokenEndConversationPhrases, ["See ya", "goodbye"])
        XCTAssertEqual(loaded.spokenStopPhrases, ["stop"])
        XCTAssertFalse(loaded.outputMuted)
        XCTAssertTrue(loaded.continuousConversation)
    }

    func testSpokenPhraseEditsAreProfileScoped() throws {
        let (appState, defaults, suite) = makeAppState(profile: "alpha")
        defer { defaults.removePersistentDomain(forName: suite) }

        var alpha = VoiceProfilePreferences()
        alpha.spokenStopPhrases = ["alpha-stop"]
        alpha.spokenEndConversationPhrases = ["alpha-bye"]
        savePreferences(alpha, defaults: defaults, profile: "alpha", gateway: "https://example.com")

        var beta = VoiceProfilePreferences()
        beta.spokenStopPhrases = ["beta-stop"]
        beta.spokenEndConversationPhrases = ["beta-bye"]
        savePreferences(beta, defaults: defaults, profile: "beta", gateway: "https://example.com")

        XCTAssertEqual(appState.activeProfile, "alpha")
        appState.setSpokenStopPhrases(["new-alpha-stop"])
        appState.setSpokenEndConversationPhrases(["new-alpha-bye"])

        let loadedAlpha = try loadPreferences(defaults: defaults, profile: "alpha", gateway: "https://example.com")
        XCTAssertEqual(loadedAlpha.spokenStopPhrases, ["new-alpha-stop"])
        XCTAssertEqual(loadedAlpha.spokenEndConversationPhrases, ["new-alpha-bye"])
        let loadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertEqual(loadedBeta.spokenStopPhrases, ["beta-stop"])
        XCTAssertEqual(loadedBeta.spokenEndConversationPhrases, ["beta-bye"])

        appState.setActiveProfileForTesting("beta")
        appState.setSpokenStopPhrases(["new-beta-stop"])
        let reloadedAlpha = try loadPreferences(defaults: defaults, profile: "alpha", gateway: "https://example.com")
        let reloadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertEqual(reloadedAlpha.spokenStopPhrases, ["new-alpha-stop"])
        XCTAssertEqual(reloadedBeta.spokenStopPhrases, ["new-beta-stop"])
    }

    func testPhraseEditPreservesLiveMuteOnlyWithLiveSession() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        var seed = VoiceProfilePreferences()
        seed.outputMuted = false
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        // Live Voice session muted in memory only (PR #159 semantics).
        appState.voiceConversationController.beginVoiceTurn(sessionID: "live-session")
        appState.voiceConversationController.setOutputMuted(true)

        appState.setSpokenStopPhrases(["quiet"])

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertTrue(loaded.outputMuted, "live mute must be persisted so the reapplied blob cannot regress")
        XCTAssertEqual(loaded.spokenStopPhrases, ["quiet"])
    }

    func testPhraseEditDoesNotCopyStaleControllerMuteWithoutLiveSession() throws {
        let (appState, defaults, suite) = makeAppState(profile: "beta")
        defer { defaults.removePersistentDomain(forName: suite) }

        var alpha = VoiceProfilePreferences()
        alpha.outputMuted = true
        savePreferences(alpha, defaults: defaults, profile: "alpha", gateway: "https://example.com")
        var beta = VoiceProfilePreferences()
        beta.outputMuted = false
        savePreferences(beta, defaults: defaults, profile: "beta", gateway: "https://example.com")

        // Controller still holds profile A's mute after a profile switch
        // before refreshVoiceCapabilities resyncs. No live session.
        appState.voiceConversationController.setProfilePreferences(alpha)
        appState.voiceConversationController.setOutputMuted(true)
        XCTAssertFalse(appState.voiceConversationController.hasLiveVoiceSession)
        XCTAssertEqual(appState.activeProfile, "beta")

        appState.setSpokenStopPhrases(["beta-quiet"])

        let loadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertEqual(loadedBeta.spokenStopPhrases, ["beta-quiet"])
        XCTAssertFalse(loadedBeta.outputMuted, "stale controller mute must not overwrite B's persisted value")
    }

    func testSpokenPhraseEditsDoNotPersistWhileDisconnected() {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }
        appState.connection = nil
        appState.isConnected = false

        appState.setSpokenStopPhrases(["quiet"])
        appState.setSpokenEndConversationPhrases(["bye"])

        XCTAssertNil(
            defaults.data(forKey: "conduit.voice.preferences.v1.disconnected.default"),
            "disconnected phrase edits must not write the orphaned gateway namespace"
        )
    }

    func testEmptyEndConversationListRoundTripsAsEmpty() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        appState.setSpokenEndConversationPhrases([])

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertEqual(
            loaded.spokenEndConversationPhrases, [],
            "an intentionally emptied list must not silently grow the defaults back"
        )
    }

    // MARK: fixtures

    private func makeAppState(profile: String) -> (AppState, UserDefaults, String) {
        let suite = "AppStateVoiceSpokenPhraseTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        defaults.set(profile, forKey: "conduit.activeProfile")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )
        appState.voiceCapabilityRequesterForTesting = ImmediateVoiceConfigRequester()
        return (appState, defaults, suite)
    }

    private func preferencesKey(profile: String, gateway: String) -> String {
        "conduit.voice.preferences.v1.\(gateway.lowercased()).\(profile)"
    }

    private func savePreferences(
        _ preferences: VoiceProfilePreferences,
        defaults: UserDefaults,
        profile: String,
        gateway: String
    ) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: preferencesKey(profile: profile, gateway: gateway))
    }

    private func loadPreferences(
        defaults: UserDefaults,
        profile: String,
        gateway: String
    ) throws -> VoiceProfilePreferences {
        let data = try XCTUnwrap(defaults.data(forKey: preferencesKey(profile: profile, gateway: gateway)))
        return try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)
    }
}

/// Fail-fast requester so refreshVoiceCapabilities skips the network without
/// waiting on dashboard timeouts; preference loading still runs.
@MainActor
private final class ImmediateVoiceConfigRequester: VoiceConfigurationRequesting {
    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        throw URLError(.notConnectedToInternet)
    }
}
