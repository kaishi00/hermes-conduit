//
//  VoiceConversationControllerTests.swift
//  Conduit
//
//  Synchronization convention: the controller's asynchronous work (utterance
//  task, speech drain, barge-in task, capture-event pump) is observed through
//  explicit signals from the shared doubles in VoiceTestSupport.swift —
//  `SubmitSpy.waitUntilSubmitted`, `MockGateway.waitUntil*`,
//  `MockCapture.waitUntilStartCount`, `waitForState`/`waitForMicrophoneLevel`
//  @Published waits, and the parked-operation gates (`InterruptParkingGate`,
//  `GatedTranscriptionGateway`, `MockPlayback.drainGate`). No test waits on a
//  fixed settling window; timeouts exist only as deadlock guards.
//

import XCTest
@testable import Conduit

@MainActor
final class VoiceConversationControllerTests: XCTestCase {
    func testFloatMicrophoneSamplesEncodeAsLittleEndianPCM16() {
        let input: [Float] = [-1, -0.5, 0, 0.5, 1, .nan]
        let encoded = input.withUnsafeBufferPointer { buffer in
            VoicePCMEncoding.encode(buffer.baseAddress!, count: buffer.count)
        }
        let samples = encoded.data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }

        XCTAssertEqual(samples, [-32_768, -16_384, 0, 16_384, 32_767, 0])
        XCTAssertEqual(encoded.peak, 1)
    }

    func testOlderVoicePreferencesDefaultToHermesTranscription() throws {
        let data = try XCTUnwrap(#"{"outputMuted":false,"continuousConversation":true,"continueWakeConversation":false,"spokenStopPhrases":["stop"]}"#.data(using: .utf8))
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)

        XCTAssertEqual(preferences.resolvedTranscriptionMode, .hermes)
    }

    func testStartsListeningOnlyAfterPermission() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )

        await controller.startListening()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(capture.didStart)
    }

    func testResumeFromInitialIdleStartsFirstCapture() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )

        await controller.resumeMicrophone()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testPermissionDenialDoesNotStartCapture() async {
        let capture = MockCapture(permissionGranted: false)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )

        await controller.startListening()

        XCTAssertEqual(controller.state, .failed("Microphone access is required for voice conversations."))
        XCTAssertFalse(capture.didStart)
    }

    func testTranscriptionTestReportsMicrophonePermissionFailure() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: false),
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.runTranscriptionTest(duration: 0)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Microphone access is required for voice conversations.")
    }

    func testTranscriptionTestReportsCaptureStartFailureBeforeProviderCall() async {
        let capture = MockCapture(
            permissionGranted: true,
            startError: VoiceAudioError.unavailable("Microphone capture could not start.")
        )
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.runTranscriptionTest(duration: 0)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Microphone capture could not start.")
        XCTAssertEqual(gateway.transcriptionCount, 0)
    }

    func testTranscriptionTestReturnsCapturedTranscript() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: MockGateway(transcript: "Captured locally"),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.runTranscriptionTest(duration: 0)

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.message, "Transcribed: Captured locally")
    }

    func testOnDevicePermissionPreparationReportsSpeechDenial() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            deviceTranscriber: MockDeviceTranscriber(transcript: "", permissionGranted: false),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.requestOnDeviceTranscriptionPermissions()

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Speech Recognition permission is required for on-device transcription.")
    }

    func testOnDevicePermissionPreparationReportsMicrophoneDenial() async {
        let deviceTranscriber = MockDeviceTranscriber(transcript: "", permissionGranted: true)
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: false),
            playback: MockPlayback(),
            deviceTranscriber: deviceTranscriber,
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.requestOnDeviceTranscriptionPermissions()

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Microphone access is required for voice conversations.")
        XCTAssertEqual(deviceTranscriber.permissionRequestCount, 0, "Speech permission should not be requested after microphone denial")
    }

    func testOnDevicePermissionPreparationSucceedsWhenBothGranted() async {
        let deviceTranscriber = MockDeviceTranscriber(transcript: "", permissionGranted: true)
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            deviceTranscriber: deviceTranscriber,
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.requestOnDeviceTranscriptionPermissions()

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.message, "On-device speech recognition is ready.")
        XCTAssertEqual(deviceTranscriber.permissionRequestCount, 1, "Speech permission should be requested exactly once")
    }

    func testAppleSpeechAvailabilityCanAttemptRecognition() {
        let ready = AppleSpeechRecognitionAvailability.ready(localeIdentifier: "en_US")
        XCTAssertTrue(ready.canAttemptRecognition)

        let permissionRequired = AppleSpeechRecognitionAvailability.permissionRequired(localeIdentifier: "en_US")
        XCTAssertTrue(permissionRequired.canAttemptRecognition)

        let permissionDenied = AppleSpeechRecognitionAvailability.permissionDenied
        XCTAssertFalse(permissionDenied.canAttemptRecognition)

        let unsupported = AppleSpeechRecognitionAvailability.unsupported(localeIdentifier: "en_US")
        XCTAssertFalse(unsupported.canAttemptRecognition)
    }

    func testTrailingSilenceTranscribesThenSubmitsThroughAuthoritativeSeam() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Hello Hermes")
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
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["Hello Hermes"])
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertTrue(capture.didBeginMonitoring)
        XCTAssertEqual(controller.conversationTranscript.map(\.speaker), [.user])
        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["Hello Hermes"])
    }

    func testAppleOnDeviceModeBypassesHermesTranscription() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Hermes transcript")
        let deviceTranscriber = MockDeviceTranscriber(transcript: "Apple transcript")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            deviceTranscriber: deviceTranscriber,
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
        XCTAssertEqual(deviceTranscriber.transcriptionCount, 1)
        XCTAssertEqual(gateway.transcriptionCount, 0)
    }

    func testBargeInRequiresSustainedSpeech() async {
        let capture = MockCapture(permissionGranted: true)
        let interrupts = AwaitableCounter()
        let gateway = MockGateway(transcript: "Question")
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        XCTAssertEqual(controller.state, .thinking)
        let bargeInStart = Date()
        controller.ingestAudioLevel(0.1, at: bargeInStart)
        controller.ingestAudioLevel(0.1, at: bargeInStart.addingTimeInterval(0.31))
        await interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)

        XCTAssertEqual(interrupts.value, 1)
        XCTAssertEqual(controller.lastBargeInState, .thinking)
        XCTAssertTrue(relistened, "barge-in reopens listening")
        XCTAssertEqual(controller.state, .listening)
    }

    func testVoiceDefaultsMirrorHermesDesktopVAD() {
        let configuration = VoiceConversationController.Configuration()
        // Barge-in keeps the conservative fixed threshold (issue #130).
        XCTAssertEqual(configuration.bargeInActivityThreshold, 0.075)
        XCTAssertEqual(configuration.trailingSilence, 1.25)
        XCTAssertEqual(configuration.idleSilence, 12)
        XCTAssertEqual(configuration.maximumUtterance, 60)
        XCTAssertEqual(configuration.bargeInDuration, 0.3)
        // The adaptive listening detector's ceiling can never exceed the
        // conservative barge-in threshold.
        XCTAssertEqual(
            configuration.speechDetector.maximumSpeechStartThreshold,
            configuration.bargeInActivityThreshold
        )
    }

    func testAssistantDeltasStayInOnePersistentSpeechStream() async {
        let gateway = MockGateway()
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "One "))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "turn."))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "One turn."))
        await gateway.waitUntilSpeechAppended(2)

        XCTAssertEqual(gateway.stream?.appended, ["One ", "turn."])
        XCTAssertEqual(gateway.openCount, 1)
    }

    func testStopDuringTranscriptionCannotSubmitOrRestartCapture() async {
        let capture = MockCapture(permissionGranted: true)
        // Transcription parks on the gate, so .transcribing is provably live
        // without a wall-clock window.
        let gateway = GatedTranscriptionGateway(transcript: "late")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        await gateway.waitUntilTranscribing()
        controller.stop()
        gateway.releaseTranscription()
        await drainPendingMainActorWork()

        XCTAssertTrue(submitted.texts.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testUnrelatedAssistantSessionIsIgnored() async {
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.receiveAssistantEvent(.delta(sessionID: "typed-session", text: "Do not speak"))
        controller.receiveAssistantEvent(.completed(sessionID: "typed-session", content: "Do not speak"))
        await drainPendingMainActorWork()

        XCTAssertEqual(gateway.openCount, 0)
        XCTAssertEqual(controller.state, .thinking)
    }

    func testContinuousConversationRearmsAssistantOwnershipForSecondTurn() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "next turn")
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        let first = Date()
        controller.ingestAudioLevel(0.1, at: first)
        controller.ingestAudioLevel(0, at: first.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "First."))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "First."))
        // Continuous ON relistens after the drained turn; the fresh listening
        // window must be open before the next utterance is spoken into VAD.
        await capture.waitUntilStartCount(2)

        let second = Date()
        controller.ingestAudioLevel(0.1, at: second)
        controller.ingestAudioLevel(0, at: second.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionCount(2)
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Second."))
        await gateway.waitUntilSpeechAppended(2)

        XCTAssertEqual(gateway.openCount, 2)
        XCTAssertEqual(gateway.stream?.appended, ["Second."])
    }

    func testAdmittedRuntimeRebindKeepsAssistantVoiceFlowing() async {
        // Hermes events carry runtime routing ids. When a resume rebinds the
        // conversation's runtime mid-turn, the new id is a confirmed alias —
        // the assistant's voice must keep flowing instead of being dropped
        // by raw equality with the captured id.
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()

        controller.receiveAssistantEvent(.delta(sessionID: "voice-session", text: "Hello "))
        // The admitted rebind: the reconciled conversation positively
        // contains the turn's captured id.
        controller.extendAssistantSessionIDs(
            ["runtime-rebound"],
            ofConversationContaining: ["stored-a", "voice-session"]
        )
        controller.receiveAssistantEvent(.delta(sessionID: "runtime-rebound", text: "world."))
        controller.receiveAssistantEvent(.delta(sessionID: "unrelated", text: " no"))
        await gateway.waitUntilSpeechAppended(2)

        XCTAssertEqual(gateway.stream?.appended, ["Hello ", "world."])
    }

    func testVoiceAliasExtensionIgnoresADifferentConversation() async {
        // A reconcile belonging to conversation B while the voice turn is
        // live on conversation A must never inject B's runtime into A's
        // ownership: without the positive overlap guard, B's assistant
        // stream would be spoken into A's turn.
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()

        // The reconciled conversation's accepted set is disjoint from the
        // turn's captured id — the extension must be refused.
        controller.extendAssistantSessionIDs(
            ["runtime-of-b"],
            ofConversationContaining: ["stored-b", "runtime-of-b"]
        )
        controller.receiveAssistantEvent(.delta(sessionID: "runtime-of-b", text: " no"))
        await drainPendingMainActorWork()

        XCTAssertTrue(
            gateway.stream?.appended.isEmpty ?? true,
            "Another conversation's runtime must never gain this turn's speech"
        )
    }

    func testVoiceAliasExtensionWithoutActiveTurnDoesNotLeakIntoNextTurn() async {
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        // No beginVoiceTurn: the extension is a no-op and a later turn
        // captures only its own id.
        controller.extendAssistantSessionIDs(
            ["runtime-rebound"],
            ofConversationContaining: ["runtime-rebound"]
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.receiveAssistantEvent(.delta(sessionID: "runtime-rebound", text: " no"))
        await drainPendingMainActorWork()

        XCTAssertTrue(
            gateway.stream?.appended.isEmpty ?? true,
            "A stale alias extension must not give the next turn's events speech"
        )
    }

    func testAudioInterruptionDuringTranscriptionCannotGhostSubmit() async {
        let capture = MockCapture(permissionGranted: true)
        // Transcription parks on the gate, so the interruption is delivered
        // while the transcription is provably in flight.
        let gateway = GatedTranscriptionGateway(transcript: "late")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscribing()
        capture.emit(.interrupted(generation: capture.captureGeneration))
        let failed = await controller.waitForFailedState()
        // The parked transcription was already consumed by cancellation.
        gateway.releaseTranscription()
        XCTAssertTrue(failed, "the interruption must fail the session")

        XCTAssertTrue(submitted.texts.isEmpty)
        XCTAssertEqual(controller.state, .failed("Audio was interrupted."))
    }

    func testIdleSilencePausesWithoutFailingVoiceSession() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )
        await controller.startListening()
        controller.ingestAudioLevel(0, at: Date().addingTimeInterval(12.1))

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.isMicrophonePaused)
        XCTAssertTrue(capture.didPause)
    }

    func testMutedAssistantStillBuildsAuthoritativeConversationTranscript() async {
        let gateway = MockGateway(transcript: "User words")
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.setOutputMuted(true)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Partial"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Authoritative answer"))
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.conversationTranscript.map(\.speaker), [.user, .assistant])
        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["User words", "Authoritative answer"])
        XCTAssertEqual(gateway.openCount, 0)
    }

    func testEmptyAssistantCompletionDoesNotEraseDeltasOrAddBlankEntry() async {
        let gateway = MockGateway(transcript: "Question")
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.setOutputMuted(true)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Keep this"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: ""))
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["Question", "Keep this"])
    }

    func testConversationTranscriptPersistsUntilNextBeginVoiceTurn() async {
        let gateway = MockGateway(transcript: "Keep me")
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "first")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.stop()

        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["Keep me"])
        controller.beginVoiceTurn(sessionID: "second")
        XCTAssertTrue(controller.conversationTranscript.isEmpty)
    }

    func testMicrophonePausePreservesConversationStateAcrossListeningThinkingSpeakingAndMuted() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Hello", startsPlaybackOnOpen: true)
        // Full-duplex route: this test pins pause/resume symmetry. The
        // speaker-safe behavior during playback has dedicated coverage in
        // VoiceSpeakerSafeBargeInTests.
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        controller.pauseMicrophone()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.isMicrophonePaused)
        await controller.resumeMicrophone()
        XCTAssertEqual(controller.state, .listening)

        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        XCTAssertEqual(controller.state, .thinking)
        controller.pauseMicrophone()
        await controller.resumeMicrophone()
        XCTAssertEqual(controller.state, .thinking)

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Speaking"))
        let speaking = await controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "playback started for the assistant turn")
        XCTAssertEqual(controller.state, .speaking)
        controller.pauseMicrophone()
        await controller.resumeMicrophone()
        XCTAssertEqual(controller.state, .speaking)

        controller.setOutputMuted(true)
        XCTAssertEqual(controller.state, .muted)
        controller.pauseMicrophone()
        await controller.resumeMicrophone()
        XCTAssertEqual(controller.state, .muted)
        XCTAssertFalse(controller.isMicrophonePaused)
        XCTAssertEqual(capture.resumeCount, 4)
    }

    func testNewAssistantStartTransactionallyReplacesCancelledSpeechDrain() async {
        let gateway = MockGateway(transcript: "User turn", blocksFirstStreamAppend: true)
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Old partial"))
        // The append is counted as it is handed to the (parking) stream.
        await gateway.waitUntilSpeechAppended(1)
        XCTAssertEqual(gateway.openCount, 1)

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Replacement"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Replacement complete"))
        // Continuous ON relistens only after the replacement drain finished.
        let replaced = await controller.waitForState(.listening)
        XCTAssertTrue(replaced, "the replacement drain completed and relistened")

        XCTAssertEqual(gateway.openCount, 2)
        XCTAssertEqual(gateway.streams.first?.cancelCount, 1)
        XCTAssertEqual(gateway.streams.last?.appended, ["Replacement"])
        XCTAssertEqual(gateway.streams.last?.finishCount, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.conversationTranscript.last?.text, "Replacement complete")
    }

    func testStaleCancelledAssistantFailureAfterBargeInCannotFailNextVoiceTurn() async {
        let capture = MockCapture(permissionGranted: true)
        let interrupts = AwaitableCounter()
        let gateway = MockGateway(transcript: "Next turn")
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        let first = Date()
        controller.ingestAudioLevel(0.1, at: first)
        controller.ingestAudioLevel(0, at: first.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.receiveAssistantEvent(.started(sessionID: "session"))

        let bargeIn = Date()
        controller.ingestAudioLevel(0.1, at: bargeIn)
        controller.ingestAudioLevel(0.1, at: bargeIn.addingTimeInterval(0.31))
        await interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "barge-in reopened listening")
        XCTAssertEqual(controller.state, .listening)

        let second = Date()
        controller.ingestAudioLevel(0.1, at: second)
        controller.ingestAudioLevel(0, at: second.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionCount(2)
        XCTAssertEqual(controller.state, .thinking)

        controller.receiveAssistantEvent(.failed(sessionID: "session", message: "Cancelled."))

        XCTAssertEqual(controller.state, .thinking)
    }

    func testResumeAfterPauseResetsSpeechTimingSoStaleSilenceCannotFinishUtterance() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question")
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )

        await controller.startListening()
        let speechStart = Date()
        controller.ingestAudioLevel(0.5, at: speechStart)
        controller.pauseMicrophone()
        await controller.resumeMicrophone()

        // The pre-pause speech timestamp is stale by more than the trailing
        // silence window. Resume is a fresh listening window, so a silent
        // level event right after resume must not finish an utterance.
        let resumeDate = Date()
        controller.ingestAudioLevel(0.0, at: resumeDate.addingTimeInterval(10))
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.finishUtteranceCount, 0)

        // A fresh utterance still finishes normally on trailing silence.
        controller.ingestAudioLevel(0.5, at: resumeDate.addingTimeInterval(2))
        controller.ingestAudioLevel(0.0, at: resumeDate.addingTimeInterval(3.3))
        await gateway.waitUntilTranscriptionStarted()

        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(capture.finishUtteranceCount, 1)
    }

    func testSpeechTestClaimsStandalonePlaybackOwnership() async {
        let playback = MockPlayback()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: playback,
            gateway: MockGateway(deliversPCM: true),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.runSpeechTest(text: "test")

        XCTAssertTrue(result.passed)
        XCTAssertEqual(playback.intentAtLastStart, .standalonePlayback)
    }

    /// A stream that connects but delivers no usable audio must not pass the
    /// provider test: socket success alone says nothing about whether the
    /// configured TTS provider actually speaks.
    func testSpeechTestFailsWhenStreamDeliversNoAudio() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: MockGateway(startsPlaybackOnOpen: true),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.runSpeechTest(text: "test")

        XCTAssertFalse(result.passed)
    }

    /// The success contract: meaningful speech data reached playback.
    func testSpeechTestSucceedsWhenPCMIsDelivered() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: MockGateway(deliversPCM: true),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.runSpeechTest(text: "test")

        XCTAssertTrue(result.passed)
    }

    /// The whole-file fallback route counts as delivered speech: a provider
    /// that cannot stream still passes the test when its encoded audio
    /// actually reaches playback.
    func testSpeechTestSucceedsWhenEncodedAudioIsDelivered() async {
        let playback = MockPlayback()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: playback,
            gateway: MockGateway(deliversEncodedAudio: true),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.runSpeechTest(text: "test")

        XCTAssertTrue(result.passed)
        XCTAssertEqual(playback.intentAtLastStart, .standalonePlayback)
    }

    /// A PCM callback whose payload the playback service cannot accept
    /// (an unaligned single byte schedules zero bytes) is NOT delivered
    /// speech: the test must fail instead of passing on a fired callback.
    func testSpeechTestFailsWhenOnlyUnalignedPCMIsDelivered() async {
        let playback = MockPlayback()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: playback,
            gateway: MockGateway(deliversPartialPCM: true),
            submit: { _ in true },
            interrupt: { true }
        )

        let result = await controller.runSpeechTest(text: "test")

        XCTAssertFalse(result.passed)
    }

    func testConversationSpeechClaimsConversationPlaybackOwnership() async {
        let playback = MockPlayback()
        let gateway = MockGateway(startsPlaybackOnOpen: true)
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: playback,
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "One turn."))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "One turn."))
        await gateway.waitUntilSpeechStreamOpened(1)

        XCTAssertEqual(playback.intentAtLastStart, .conversationPlayback)
    }

    // MARK: - Issue #130: adaptive listening VAD + live input meter

    func testQuietSpeechBelowLegacyThresholdSubmitsTurn() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Quiet words")
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

        // Ambient floor (detector warmup), then quiet speech whose peaks
        // never reach the legacy fixed threshold, then trailing silence.
        let start = Date()
        let samples: [(Float, TimeInterval)] = [
            (0.003, 0.00), (0.004, 0.03), (0.003, 0.06), (0.003, 0.09),
            (0.018, 0.12), (0.026, 0.17), (0.034, 0.22), (0.028, 0.27),
            (0.004, 1.60), (0.003, 1.65)
        ]
        for (level, offset) in samples {
            controller.ingestAudioLevel(level, at: start.addingTimeInterval(offset))
        }
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["Quiet words"], "quiet-but-valid speech must not get stuck in Listening")
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(capture.finishUtteranceCount, 1)
        // The completed utterance resets the visible meter.
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001)
    }

    func testSteadyAmbientNoiseDoesNotCreateTurns() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "phantom")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        await controller.startListening()

        // Constant room noise around 0.015 for two seconds: well above the
        // absolute floor minimum, never a meaningful speech rise. The VAD
        // classification is synchronous in ingestAudioLevel, so the negative
        // result is exact without any settling window.
        let start = Date()
        for index in 0..<80 {
            controller.ingestAudioLevel(0.015, at: start.addingTimeInterval(Double(index) * 0.025))
        }

        XCTAssertTrue(submitted.texts.isEmpty, "ambient noise alone must never become a user turn")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.finishUtteranceCount, 0)
    }

    func testLouderRoomAdaptsAndStillRecognizesRelativeSpeechRise() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Louder words")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        await controller.startListening()

        // A louder room: the adaptive threshold rises with the observed
        // floor, then a clear relative rise still counts as speech even
        // though it stays below the legacy fixed threshold.
        let start = Date()
        for index in 0..<40 {
            controller.ingestAudioLevel(0.02, at: start.addingTimeInterval(Double(index) * 0.025))
        }
        controller.ingestAudioLevel(0.065, at: start.addingTimeInterval(1.1))
        controller.ingestAudioLevel(0.07, at: start.addingTimeInterval(1.15))
        controller.ingestAudioLevel(0.02, at: start.addingTimeInterval(2.6))
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["Louder words"], "the detector must adapt upward with the room")
        XCTAssertEqual(controller.state, .thinking)
    }

    func testRouteChangeMidListeningRelearnsNoiseFloor() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "After route change")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )
        await controller.startListening()

        // Old microphone: establish a loud floor.
        let start = Date()
        for index in 0..<40 {
            controller.ingestAudioLevel(0.03, at: start.addingTimeInterval(Double(index) * 0.025))
        }

        // A different microphone arrives mid-listening: the floor must
        // re-learn instead of keeping the old room's estimate. The route
        // change rides the capture-event pump, so drain it before the new
        // samples to pin the ordering (detector reset BEFORE the new speech).
        capture.emit(.routeChanged)
        await drainPendingMainActorWork()

        // New microphone's quiet speech: recognized against the re-learned
        // floor, then trailing silence finishes and submits the turn.
        let speech = start.addingTimeInterval(2.0)
        let samples: [(Float, TimeInterval)] = [
            (0.003, 0.00), (0.004, 0.03), (0.003, 0.06), (0.003, 0.09),
            (0.018, 0.12), (0.026, 0.17), (0.034, 0.22), (0.028, 0.27),
            (0.004, 1.60)
        ]
        for (level, offset) in samples {
            controller.ingestAudioLevel(level, at: speech.addingTimeInterval(offset))
        }
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["After route change"], "a route change must re-learn the noise floor for the new microphone")
        XCTAssertEqual(controller.state, .thinking)
    }

    func testCaptureLevelPublishesMicrophoneLevelDuringListening() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )
        await controller.startListening()

        capture.emit(level: 0.034)
        let published = await controller.waitForMicrophoneLevel { abs($0 - 0.034) < 0.0001 }

        XCTAssertTrue(published, "raw capture level must reach the published meter")
        XCTAssertEqual(controller.microphoneLevel, 0.034, accuracy: 0.0001, "raw capture level must reach the published meter")
    }

    func testProviderTestShowsLevelWithoutConversationalVAD() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Should not submit")
        let submitted = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { await submitted.submit($0) },
            interrupt: { true }
        )

        let testTask = Task { await controller.runTranscriptionTest(duration: 2) }
        let recording = await controller.waitForState(.listening)
        XCTAssertTrue(recording, "the ASR test is recording")
        capture.emit(level: 0.4)
        let firstPublished = await controller.waitForMicrophoneLevel { abs($0 - 0.4) < 0.0001 }
        XCTAssertTrue(firstPublished)
        // Level publication is meter-resolution (~50 ms event-date throttle):
        // a future-dated sample is deterministic on any scheduler speed.
        capture.emit(level: 0.5, at: Date().addingTimeInterval(0.2))
        let secondPublished = await controller.waitForMicrophoneLevel { abs($0 - 0.5) < 0.0001 }
        XCTAssertTrue(secondPublished, "provider tests still receive visible microphone-level updates")
        XCTAssertEqual(controller.microphoneLevel, 0.5, accuracy: 0.0001, "provider tests still receive visible microphone-level updates")

        let result = await testTask.value
        XCTAssertTrue(result.passed)
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001, "provider-test completion resets the meter")
        XCTAssertTrue(submitted.texts.isEmpty, "conversational VAD must not run during a provider test")
    }

    func testLevelEventsDoNotRepublishMeterWhileTranscribing() async {
        let capture = MockCapture(permissionGranted: true)
        // Holding the gateway transcription open keeps .transcribing active
        // for as long as the test needs: the gate is observed while it is
        // the live state, not after the flow has moved on.
        let gateway = GatedTranscriptionGateway(transcript: "held")
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        await controller.startListening()
        let generation = capture.captureGeneration

        // Live listening publishes the meter.
        capture.emit(level: 0.4)
        let publishedWhileListening = await controller.waitForMicrophoneLevel { abs($0 - 0.4) < 0.0001 }
        XCTAssertTrue(publishedWhileListening)
        XCTAssertEqual(controller.microphoneLevel, 0.4, accuracy: 0.0001)

        // Speech onset then a future-dated trailing-silence gap finishes the
        // utterance and moves the controller into .transcribing, where the
        // transcription parks on the gated gateway.
        let start = Date()
        let samples: [(Float, TimeInterval)] = [
            (0.003, 0.00), (0.003, 0.03), (0.004, 0.06), (0.004, 0.09),
            (0.018, 0.12), (0.026, 0.17), (0.034, 0.22),
            (0.004, 1.60), (0.003, 1.65)
        ]
        for (level, offset) in samples {
            controller.ingestAudioLevel(level, at: start.addingTimeInterval(offset))
        }
        let reachedTranscribing = await controller.waitForState(.transcribing)
        XCTAssertTrue(
            reachedTranscribing,
            "the utterance must reach transcription while the gateway holds it open"
        )
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001, "the completed utterance resets the meter")

        // A same-generation level surfacing mid-transcription must be
        // ignored: the meter stays reset.
        capture.emit(.level(0.7, date: Date(), generation: generation))
        await drainPendingMainActorWork()
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001, "transcribing must not republish the mic meter")

        // Let the held transcription finish, and pin that the gate is
        // narrow: publication must resume once the state leaves
        // .transcribing (barge-in monitoring windows depend on it).
        gateway.releaseTranscription()
        let reachedThinking = await controller.waitForState(.thinking)
        XCTAssertTrue(reachedThinking, "the held transcription must complete into .thinking")
        capture.emit(level: 0.4)
        let resumedPublishing = await controller.waitForMicrophoneLevel { abs($0 - 0.4) < 0.0001 }
        XCTAssertTrue(resumedPublishing, "the meter must resume publishing once transcription ends")
        XCTAssertEqual(
            controller.microphoneLevel,
            0.4,
            accuracy: 0.0001,
            "the meter must resume publishing once transcription ends"
        )
    }

    func testProviderTestLevelEventsDoNotRepublishMeterWhileTranscribing() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = GatedTranscriptionGateway(transcript: "held")
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )

        let testTask = Task { await controller.runTranscriptionTest(duration: 0.5) }
        let reachedRecording = await controller.waitForState(.listening)
        XCTAssertTrue(reachedRecording, "the ASR test must be recording")
        capture.emit(level: 0.4)
        let publishedWhileRecording = await controller.waitForMicrophoneLevel { abs($0 - 0.4) < 0.0001 }
        XCTAssertTrue(publishedWhileRecording, "Record ASR recording still publishes the meter")
        XCTAssertEqual(controller.microphoneLevel, 0.4, accuracy: 0.0001, "Record ASR recording still publishes the meter")

        // The recording window elapses into the held transcription.
        let reachedProviderTranscribing = await controller.waitForState(.transcribing)
        XCTAssertTrue(reachedProviderTranscribing)
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001, "entering transcription resets the meter")
        capture.emit(.level(0.8, date: Date(), generation: capture.captureGeneration))
        await drainPendingMainActorWork()
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001, "provider transcription must not republish the mic meter")

        // The parked transcription completes on release.
        gateway.releaseTranscription()
        let result = await testTask.value
        XCTAssertTrue(result.passed)
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001)
    }

    func testStaleCaptureLevelEventsDoNotCrossCaptureGenerations() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "fresh")
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        await controller.startListening()
        let generationA = capture.captureGeneration

        // Capture A produces a level event; the meter follows it.
        capture.emit(level: 0.4)
        let publishedA = await controller.waitForMicrophoneLevel { abs($0 - 0.4) < 0.0001 }
        XCTAssertTrue(publishedA)
        XCTAssertEqual(controller.microphoneLevel, 0.4, accuracy: 0.0001)

        // Capture A is torn down (stop): its generation is invalidated.
        controller.stop()
        XCTAssertNotEqual(capture.captureGeneration, generationA, "stop must invalidate the capture generation")

        // Capture B starts; a delayed frame from generation A arrives after
        // the teardown and must be rejected.
        await controller.startListening()
        let generationB = capture.captureGeneration
        XCTAssertNotEqual(generationA, generationB)
        capture.emit(.level(0.9, date: Date(), generation: generationA))
        await drainPendingMainActorWork()
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001, "a stale generation's level must not update the meter")
        XCTAssertEqual(controller.state, .listening)

        // The live generation's events are accepted normally.
        capture.emit(level: 0.3)
        let publishedB = await controller.waitForMicrophoneLevel { abs($0 - 0.3) < 0.0001 }
        XCTAssertTrue(publishedB, "the live generation's events update the meter")
        XCTAssertEqual(controller.microphoneLevel, 0.3, accuracy: 0.0001, "the live generation's events update the meter")
        XCTAssertEqual(controller.state, .listening)
    }

    func testSpeechTestRouteChangeDoesNotLeakSuspensionState() async {
        let capture = MockCapture(permissionGranted: true)
        let playback = MockPlayback()
        let gateway = MockGateway(transcript: "test", startsPlaybackOnOpen: true, deliversPCM: true)
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let gate = InterruptParkingGate()
        playback.drainGate = gate
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { true }
        )

        let testTask = Task { await controller.runSpeechTest(text: "hello") }
        // Deterministic mid-playback park: drain() holds the test task while
        // state is .speaking.
        await gate.waitUntilEntered()
        XCTAssertEqual(controller.state, .speaking, "the TTS provider test is mid-playback")

        // A route change during a provider test must not pollute the
        // speaker-safe suspension state: the TTS test owns the session and
        // no conversational capture is live.
        capture.emit(.routeChanged)
        await drainPendingMainActorWork()
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "route changes during provider tests must not suspend capture")

        gate.release()
        let result = await testTask.value
        XCTAssertTrue(result.passed)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "suspension state must not outlive the provider test")
    }

    func testMicrophoneLevelResetsAcrossLifecycleBoundaries() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { true }
        )
        await controller.startListening()
        capture.emit(level: 0.4)
        let publishedBeforePause = await controller.waitForMicrophoneLevel { abs($0 - 0.4) < 0.0001 }
        XCTAssertTrue(publishedBeforePause)
        XCTAssertEqual(controller.microphoneLevel, 0.4, accuracy: 0.0001)

        // Explicit pause.
        controller.pauseMicrophone()
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001)

        // Audio interruption.
        await controller.startListening()
        capture.emit(level: 0.4)
        let republished = await controller.waitForMicrophoneLevel { abs($0 - 0.4) < 0.0001 }
        XCTAssertTrue(republished)
        capture.emit(.interrupted(generation: capture.captureGeneration))
        let failed = await controller.waitForFailedState()
        XCTAssertTrue(failed, "the interruption failed the session")
        XCTAssertEqual(controller.state, .failed("Audio was interrupted."))
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001)

        // Session stop.
        await controller.startListening()
        capture.emit(level: 0.4)
        let publishedBeforeStop = await controller.waitForMicrophoneLevel { abs($0 - 0.4) < 0.0001 }
        XCTAssertTrue(publishedBeforeStop)
        controller.stop()
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001)
    }
}

/// Speaker feedback-loop regressions: on routes whose output can feed the
/// device microphone (built-in speaker/receiver), the assistant's own TTS
/// must never become a new user turn. Capture is suspended during playback
/// and the mic control becomes Interrupt; isolated headset routes keep the
/// existing live barge-in.
@MainActor
final class VoiceSpeakerSafeBargeInTests: XCTestCase {
    func testSpeakerRouteAssistantPlaybackCannotBargeInOnItself() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Why is the kanji cursed", startsPlaybackOnOpen: true)
        let submitted = SubmitSpy()
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { await submitted.submit($0) },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "speaker-safe routes suspend capture while Hermes speaks")
        XCTAssertTrue(capture.didPause)

        // The speaker's own TTS leaks back into the microphone: sustained
        // level above the voice activity threshold for longer than the
        // barge-in duration. ingestAudioLevel is synchronous, and the
        // suspended-capture gate rejects barge-in scheduling inline.
        let leakStart = Date()
        controller.ingestAudioLevel(0.5, at: leakStart)
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.31))
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.62))

        XCTAssertEqual(interrupts.value, 0, "assistant TTS must never schedule a barge-in on a speaker route")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(gateway.transcriptionCount, 1, "only the user's real utterance may be transcribed")
        XCTAssertEqual(capture.finishUtteranceCount, 1, "suspended capture must not record a second (assistant) utterance")
        XCTAssertEqual(submitted.texts.count, 1, "no new user turn may be submitted from speaker leakage")
    }

    func testSpeakerRouteResumesFreshListeningAfterPlaybackCompletes() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Why is the kanji cursed", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertEqual(capture.startCount, 1)
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Chorus line answer."))
        let resumed = await controller.waitForState(.listening)
        XCTAssertTrue(resumed, "listening resumes after the drained playback")

        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2, "listening resumes with a fresh capture window after playback")
        XCTAssertEqual(capture.lastStartIncludePreRoll, false, "the post-playback window must not reuse speaker-contaminated pre-roll")
        XCTAssertEqual(interrupts.value, 0)
    }

    func testInterruptOnSpeakerRouteStopsPlaybackAndStartsFreshListening() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Why is the kanji cursed", startsPlaybackOnOpen: true)
        let playback = MockPlayback()
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)
        XCTAssertTrue(playback.isPlaying)

        await controller.interruptAssistantPlayback()

        XCTAssertEqual(interrupts.value, 1, "Interrupt retires the assistant turn through the authoritative interruption path")
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(gateway.streams.first?.cancelCount, 1, "the in-flight speech stream is retired")
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertEqual(capture.lastStartIncludePreRoll, false, "no speaker-contaminated pre-roll may be requested")
        XCTAssertEqual(capture.finishUtteranceCount, 1, "no additional (assistant) utterance may be recorded")

        // The retired turn's late completion must stay retired: the guard in
        // receiveAssistantEvent rejects it synchronously.
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Late tail"))
        await drainPendingMainActorWork()
        XCTAssertEqual(gateway.openCount, 1, "a retired turn must not reopen speech")
        XCTAssertEqual(controller.state, .listening)
    }

    func testHeadsetRouteKeepsLiveBargeInDuringPlayback() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "isolated headset routes keep live capture")
        XCTAssertEqual(capture.pauseCount, 0)

        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        await interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "barge-in reopened listening")

        XCTAssertEqual(interrupts.value, 1, "genuine headset barge-in still interrupts playback")
        XCTAssertEqual(controller.lastBargeInState, .speaking)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.lastStartIncludePreRoll, true, "genuine headset barge-in keeps pre-roll")
    }

    func testPlaybackSuspensionResetsMicrophoneLevel() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        // Ambient audio still reaches the published meter while Hermes is
        // only thinking (capture live, barge-in monitoring armed).
        capture.emit(level: 0.02)
        let publishedWhileThinking = await controller.waitForMicrophoneLevel { abs($0 - 0.02) < 0.0001 }
        XCTAssertTrue(publishedWhileThinking)
        XCTAssertEqual(controller.microphoneLevel, 0.02, accuracy: 0.0001)
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer."))
        let suspended = await controller.waitForPlaybackCaptureSuspension(true)
        XCTAssertTrue(suspended, "speaker-safe suspension engaged for playback")

        XCTAssertTrue(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(controller.microphoneLevel, 0, accuracy: 0.0001, "speaker-safe suspension must zero the visible meter")
    }

    func testBargeInKeepsConservativeThresholdIndependentOfAdaptiveListening() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertEqual(controller.state, .speaking)

        // Levels the adaptive listening detector would accept as speech,
        // but below the conservative barge-in threshold: ambient chatter
        // must not interrupt Hermes on a headset. Barge-in classification is
        // synchronous in ingestAudioLevel.
        let chatter = Date()
        controller.ingestAudioLevel(0.02, at: chatter)
        controller.ingestAudioLevel(0.03, at: chatter.addingTimeInterval(0.16))
        controller.ingestAudioLevel(0.03, at: chatter.addingTimeInterval(0.32))
        XCTAssertEqual(interrupts.value, 0, "sub-threshold levels must not trigger barge-in")
        XCTAssertEqual(controller.state, .speaking)

        // Sustained input over the unchanged barge-in threshold still does.
        let bargeInStart = Date()
        controller.ingestAudioLevel(0.1, at: bargeInStart)
        controller.ingestAudioLevel(0.1, at: bargeInStart.addingTimeInterval(0.31))
        await interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "barge-in reopened listening")
        XCTAssertEqual(interrupts.value, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.lastStartIncludePreRoll, true)
    }

    func testUserPauseRemainsAuthoritativeAcrossAutomaticSuspension() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.pauseMicrophone()
        XCTAssertTrue(controller.isMicrophonePaused)

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer while paused."))
        let suspended = await controller.waitForPlaybackCaptureSuspension(true)
        XCTAssertTrue(suspended, "playback on a speaker route still records the automatic suspension")

        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "playback on a speaker route still records the automatic suspension")
        XCTAssertTrue(controller.isMicrophonePaused, "the automatic suspension must not clear the user's pause")
        XCTAssertEqual(controller.state, .speaking)

        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Answer."))
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "the drained turn settles with the continuous-ON relisten")

        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertTrue(controller.isMicrophonePaused, "Hermes finishing playback must not auto-resume a user pause")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.resumeCount, 0, "resume must never be driven by the playback lifecycle")
        XCTAssertEqual(interrupts.value, 0)
    }

    func testMutedOutputNeverSuspendsCaptureAndKeepsBargeIn() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        controller.setOutputMuted(true)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Silenced answer."))
        await drainPendingMainActorWork()

        // Existing mute semantics: muting during .thinking keeps .thinking;
        // the muted label only replaces an in-flight .speaking. Either way
        // nothing audible plays, so capture must never suspend.
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "no audible playback means no suspension")
        XCTAssertEqual(capture.pauseCount, 0)
        XCTAssertEqual(gateway.openCount, 0, "muted output never opens a speech stream")

        // With nothing audible playing, the user can still barge in.
        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        await interrupts.waitUntil(1)
        XCTAssertEqual(interrupts.value, 1)
    }

    func testMutingDuringPlaybackEndsSuspensionAndRestoresMonitoring() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        controller.setOutputMuted(true)

        XCTAssertEqual(controller.state, .muted)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "muting stops the audible playback that justified suspension")
        XCTAssertEqual(capture.resumeCount, 1, "capture becomes live again for monitoring")

        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        await interrupts.waitUntil(1)
        XCTAssertEqual(interrupts.value, 1, "with output muted nothing audible plays, so barge-in stays live")
    }

    func testRouteChangeOntoSpeakerDuringPlaybackSuspendsCaptureImmediately() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(capture.pauseCount, 0)

        // AirPods disconnect mid-utterance: the route becomes the built-in
        // speaker.
        policy.policy = .speakerSafeHalfDuplex
        capture.emit(.routeChanged)
        let suspended = await controller.waitForPlaybackCaptureSuspension(true)
        XCTAssertTrue(suspended, "moving onto an open speaker mid-utterance must suspend capture")

        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "moving onto an open speaker mid-utterance must suspend capture")
        XCTAssertEqual(capture.pauseCount, 1)

        let leakStart = Date()
        controller.ingestAudioLevel(0.5, at: leakStart)
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.31))
        XCTAssertEqual(interrupts.value, 0, "no acoustic barge-in may survive a transition onto an open speaker")
        XCTAssertEqual(controller.state, .speaking)
    }

    func testRouteChangeOntoHeadsetDuringPlaybackStaysConservativeUntilBoundary() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        policy.policy = .fullDuplex
        capture.emit(.routeChanged)
        await drainPendingMainActorWork()
        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "mid-utterance upgrade to full duplex stays conservative until the next playback boundary")

        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Done."))
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "the drained turn reopened listening at the playback boundary")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
    }

    func testResumeDuringSuspensionActsAsInterrupt() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let playback = MockPlayback()
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        // On a speaker-safe route there is no listening during playback: a
        // listen request means interrupt.
        await controller.resumeMicrophone()

        XCTAssertEqual(interrupts.value, 1)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(controller.state, .listening)
    }

    func testPauseDuringActiveSuspensionKeepsSuspensionSafetyFlag() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        // Explicit user intent takes over the presentation (the sheet shows
        // the paused state), but it must not discard the speaker-safety
        // fact: a later listen during audible playback has to stay on the
        // interrupt path.
        controller.pauseMicrophone()

        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "explicit pause must not discard the speaker-safety fact")
        XCTAssertTrue(controller.isMicrophonePaused)
        XCTAssertEqual(interrupts.value, 0)

        // Listening again while playback is still audible interrupts rather
        // than resuming a live microphone over Hermes' voice.
        await controller.resumeMicrophone()

        XCTAssertEqual(interrupts.value, 1)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertFalse(controller.isMicrophonePaused)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.resumeCount, 0, "capture must never resume live over audible playback")
    }

    func testInterruptAcrossSessionTeardownCannotResurrectCapture() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let playback = MockPlayback()
        let gate = InterruptParkingGate()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { await gate.waitInInterrupt(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(capture.startCount, 1)

        // The user taps Interrupt; the Hermes interruption parks mid-flight.
        let interruptTask = Task { await controller.interruptAssistantPlayback() }
        await gate.waitUntilEntered()
        XCTAssertEqual(gate.count, 1, "the interruption is parked in flight")

        // While it is parked, the user closes the Voice sheet: stop() tears
        // the session down and advances the generation.
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.hasLiveVoiceSession)

        // The stale continuation must not resurrect the voice session.
        gate.release()
        await interruptTask.value

        XCTAssertEqual(controller.state, .idle, "stale Interrupt work must stay idle after teardown")
        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(capture.startCount, 1, "stale Interrupt must not reopen capture")
        // Belt-and-braces only: the load-bearing guarantee above is
        // startCount == 1; this reads the original window's recorded value.
        XCTAssertEqual(capture.lastStartIncludePreRoll, false)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertFalse(playback.isPlaying)
    }

    func testInterruptParkedAcrossStopAndReopenCannotClobberNewSession() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let gate = InterruptParkingGate()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { await gate.waitInInterrupt(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        let interruptTask = Task { await controller.interruptAssistantPlayback() }
        await gate.waitUntilEntered()
        XCTAssertEqual(gate.count, 1)

        // Sheet closed (stop), then reopened: a NEW session goes live before
        // the stale Interrupt continuation resumes.
        controller.stop()
        controller.beginVoiceTurn(sessionID: "session-2")
        await controller.startListening()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2)

        gate.release()
        await interruptTask.value

        XCTAssertEqual(controller.state, .listening, "the new session owns the state machine")
        XCTAssertEqual(capture.startCount, 2, "stale Interrupt must not stack a second capture start onto the new session")
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
    }

    func testBargeInOverlappingPlaybackSuspensionCannotReopenCapture() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let gate = InterruptParkingGate()
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { await gate.waitInInterrupt(); return true }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertEqual(controller.state, .speaking)

        // Genuine headset barge-in whose interruption is in flight.
        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        await gate.waitUntilEntered()
        XCTAssertEqual(gate.count, 1, "the barge-in interruption is parked mid-flight")

        // While it is parked, the route becomes an open speaker: suspension
        // engages and cancels the parked barge-in task.
        policy.policy = .speakerSafeHalfDuplex
        capture.emit(.routeChanged)
        let suspended = await controller.waitForPlaybackCaptureSuspension(true)
        XCTAssertTrue(suspended)

        gate.release()
        // The released barge-in task was cancelled by the suspension: it
        // must neither reopen capture nor request pre-roll. Drain the
        // released work before the negative assertions.
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(capture.startCount, 1, "the stale barge-in must not reopen capture")
        XCTAssertEqual(capture.lastStartIncludePreRoll, false, "no barge-in restart may request speaker-contaminated pre-roll")
        XCTAssertEqual(capture.resumeCount, 0)
    }

    /// listening → user utterance → submit → .thinking → assistant .started
    /// + .delta: the gateway opens its speech stream, playback starts, and
    /// the controller settles in .speaking.
    private static func driveToSpeaking(
        _ controller: VoiceConversationController,
        gateway: MockGateway,
        sessionID: String = "session"
    ) async {
        controller.beginVoiceTurn(sessionID: sessionID)
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        XCTAssertEqual(controller.state, .thinking)
        controller.receiveAssistantEvent(.started(sessionID: sessionID))
        controller.receiveAssistantEvent(.delta(sessionID: sessionID, text: "From a cursed kanji to a full chibi chorus line."))
        let speaking = await controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the assistant reply is audible")
    }
}

/// `continuousConversation` gates ONLY conversation continuation after a
/// completed assistant turn. Safety/recovery restarts (empty transcript,
/// spoken stop, barge-in, manual Interrupt, speech-stream cancellation after
/// the assistant finished) always re-listen; this suite pins both sides.
@MainActor
final class ContinuousConversationPreferenceTests: XCTestCase {
    func testContinuousConversationDefaultsToTrue() {
        XCTAssertTrue(VoiceProfilePreferences().continuousConversation)
    }

    func testOlderPreferenceBlobWithoutFieldDecodesAsContinuousOn() throws {
        let data = try XCTUnwrap(
            #"{"outputMuted":false,"continueWakeConversation":false,"spokenStopPhrases":["stop"]}"#
                .data(using: .utf8)
        )
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)
        XCTAssertTrue(preferences.continuousConversation)
    }

    func testContinuousOnPreservesPostAssistantAutomaticRelisten() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let controller = makeController(capture: capture, gateway: gateway, continuous: true)

        await Self.driveToAssistantCompletion(controller, gateway: gateway)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "continuous ON relistens after the drained turn")

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2, "continuous ON restarts capture after TTS")
        XCTAssertTrue(controller.hasLiveVoiceSession)
        XCTAssertFalse(controller.isMicrophonePaused)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
    }

    func testContinuousOffDoesNotAutomaticRelistenAfterAssistantCompletion() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { true }
        )
        controller.setProfilePreferences(Self.preferences(continuous: false))

        await Self.driveToAssistantCompletion(controller, gateway: gateway)
        let settled = await controller.waitForState(.idle)
        XCTAssertTrue(settled, "continuous OFF settles the session open without relistening")

        XCTAssertEqual(controller.state, .idle, "settled open session must not claim Listening")
        XCTAssertEqual(capture.startCount, 1, "continuous OFF must not reopen capture after TTS")
        XCTAssertTrue(capture.didPause, "settle must pause full-duplex capture so the mic tap is not left live")
        XCTAssertTrue(controller.hasLiveVoiceSession, "the voice session stays open")
        XCTAssertFalse(controller.isMicrophonePaused, "settling is not a user pause")
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
    }

    func testContinuousOffMuteDuringAssistantStillSettlesWithoutRelisten() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { true }
        )
        controller.setProfilePreferences(Self.preferences(continuous: false))

        await Self.driveToSpeaking(controller, gateway: gateway)
        controller.setOutputMuted(true)
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Answer."))
        let settled = await controller.waitForState(.idle)
        XCTAssertTrue(settled, "the muted turn settles without relistening")

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertTrue(capture.didPause)
        XCTAssertTrue(controller.hasLiveVoiceSession)

        // Unmute from the settled idle session must not claim a listening turn.
        controller.setOutputMuted(false)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testContinuousOffUserCanExplicitlyStartAnotherListeningTurn() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let controller = makeController(capture: capture, gateway: gateway, continuous: false)

        await Self.driveToAssistantCompletion(controller, gateway: gateway)
        let settled = await controller.waitForState(.idle)
        XCTAssertTrue(settled)
        XCTAssertEqual(capture.startCount, 1)

        await controller.resumeMicrophone()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertTrue(controller.hasLiveVoiceSession)
    }

    func testContinuousOffKeepsEmptyTranscriptListening() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "")
        let controller = makeController(capture: capture, gateway: gateway, continuous: false)
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        // An empty transcript re-opens the same listening window without
        // submitting.
        await capture.waitUntilStartCount(2)

        XCTAssertEqual(controller.state, .listening, "empty transcript stays in the current listening engagement")
        XCTAssertEqual(capture.startCount, 2)
    }

    func testContinuousOffKeepsSpokenStopPhraseRelisten() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Stop")
        let interrupts = AwaitableCounter()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        controller.setProfilePreferences(Self.preferences(continuous: false))
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "spoken stop reopened listening")

        XCTAssertEqual(interrupts.value, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertTrue(controller.hasLiveVoiceSession)
    }

    func testContinuousOffKeepsSpeakerSafeInterruptRecovery() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        controller.setProfilePreferences(Self.preferences(continuous: false))

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        await controller.interruptAssistantPlayback()

        XCTAssertEqual(interrupts.value, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
    }

    func testContinuousOffKeepsHeadsetBargeInRecovery() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        controller.setProfilePreferences(Self.preferences(continuous: false))

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertEqual(controller.state, .speaking)

        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        await interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "barge-in reopened listening")

        XCTAssertEqual(interrupts.value, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.lastStartIncludePreRoll, true)
    }

    func testContinuousOffSpeakerRouteStillSuspendsCaptureDuringTTS() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let interrupts = AwaitableCounter()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts.increment(); return true }
        )
        controller.setProfilePreferences(Self.preferences(continuous: false))

        await Self.driveToSpeaking(controller, gateway: gateway)

        XCTAssertTrue(controller.isPlaybackCaptureSuspended)
        let leakStart = Date()
        controller.ingestAudioLevel(0.5, at: leakStart)
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.31))
        XCTAssertEqual(interrupts.value, 0, "route safety is independent of continuousConversation")
        XCTAssertEqual(controller.state, .speaking)
    }

    func testProfilePreferenceChangeSwitchesContinuationBehavior() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let controller = makeController(capture: capture, gateway: gateway, continuous: true)

        await Self.driveToAssistantCompletion(controller, gateway: gateway)
        let relistenedFirst = await controller.waitForState(.listening)
        XCTAssertTrue(relistenedFirst)
        XCTAssertEqual(controller.state, .listening)
        let startsAfterON = capture.startCount
        XCTAssertEqual(startsAfterON, 2)

        controller.stop()
        controller.setProfilePreferences(Self.preferences(continuous: false))
        await Self.driveToAssistantCompletion(controller, gateway: gateway)
        let settledSecond = await controller.waitForState(.idle)
        XCTAssertTrue(settledSecond)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, startsAfterON + 1, "OFF only performs the first listen of the turn")

        controller.stop()
        controller.setProfilePreferences(Self.preferences(continuous: true))
        await Self.driveToAssistantCompletion(controller, gateway: gateway)
        let relistenedThird = await controller.waitForState(.listening)
        XCTAssertTrue(relistenedThird)
        XCTAssertEqual(controller.state, .listening)
    }

    func testUserPauseRemainsAuthoritativeWithContinuousOn() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let controller = makeController(capture: capture, gateway: gateway, continuous: true)

        await Self.driveToSpeaking(controller, gateway: gateway)
        controller.pauseMicrophone()
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Done."))
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "the drained turn relistens under the user's pause")

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.isMicrophonePaused)
        XCTAssertEqual(capture.resumeCount, 0)
    }

    func testUserPauseThenListenAfterContinuousOffResumeTurn() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let controller = makeController(capture: capture, gateway: gateway, continuous: false)

        await Self.driveToSpeaking(controller, gateway: gateway)
        controller.pauseMicrophone()
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Done."))
        let settled = await controller.waitForState(.idle)
        XCTAssertTrue(settled)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.isMicrophonePaused)
        XCTAssertEqual(capture.startCount, 1)

        await controller.resumeMicrophone()

        XCTAssertFalse(controller.isMicrophonePaused)
        XCTAssertEqual(controller.state, .listening)
    }

    func testGenerationFenceBlocksLateCompletionAfterStopWithContinuousOff() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let playback = MockPlayback()
        let gate = InterruptParkingGate()
        playback.drainGate = gate
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.setProfilePreferences(Self.preferences(continuous: false))

        await Self.driveToSpeaking(controller, gateway: gateway)
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Answer."))
        await gate.waitUntilEntered()

        let startsBeforeStop = capture.startCount
        controller.stop()
        gate.release()
        // The stale drain task was cancelled by stop(): it must not reopen
        // capture. Drain the released work before the negative assertions.
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, startsBeforeStop, "stale drain completion must not reopen capture")
        XCTAssertFalse(controller.hasLiveVoiceSession)
    }

    private func makeController(
        capture: MockCapture,
        gateway: MockGateway,
        continuous: Bool
    ) -> VoiceConversationController {
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: { true }
        )
        controller.setProfilePreferences(Self.preferences(continuous: continuous))
        return controller
    }

    private static func preferences(continuous: Bool) -> VoiceProfilePreferences {
        var preferences = VoiceProfilePreferences()
        preferences.continuousConversation = continuous
        return preferences
    }

    private static func driveToSpeaking(
        _ controller: VoiceConversationController,
        gateway: MockGateway,
        sessionID: String = "session"
    ) async {
        controller.beginVoiceTurn(sessionID: sessionID)
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        XCTAssertEqual(controller.state, .thinking)
        controller.receiveAssistantEvent(.started(sessionID: sessionID))
        controller.receiveAssistantEvent(.delta(sessionID: sessionID, text: "Answer."))
        let speaking = await controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the assistant reply is audible")
        XCTAssertEqual(controller.state, .speaking)
    }

    /// listening → transcription → submission → assistant speech → completed.
    /// The caller decides what the settled post-turn state should be
    /// (continuous ON relistens, OFF settles idle) and awaits it.
    private static func driveToAssistantCompletion(
        _ controller: VoiceConversationController,
        gateway: MockGateway,
        sessionID: String = "session"
    ) async {
        await driveToSpeaking(controller, gateway: gateway, sessionID: sessionID)
        controller.receiveAssistantEvent(.completed(sessionID: sessionID, content: "Answer."))
    }
}
