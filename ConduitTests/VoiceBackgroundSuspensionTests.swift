//
//  VoiceBackgroundSuspensionTests.swift
//  Conduit
//
//  Voice background behavior: lifecycle suspension (logical preservation +
//  runtime release) instead of hard teardown, and conservative foreground
//  restoration gated on profile/session/server identity.
//

import XCTest
@testable import Conduit

// MARK: - Controller-level suspension semantics

@MainActor
final class VoiceConversationLifecycleSuspensionTests: XCTestCase {
    func testSuspensionReleasesRuntimeButPreservesConversationIdentity() async {
        let (controller, capture, gateway, flags) = makeFixture()
        await driveToThinking(controller, gateway: gateway, flags: flags)
        let transcriptAfterTurn = controller.conversationTranscript

        controller.suspendRuntimeForLifecycle()

        XCTAssertEqual(controller.state, .idle, "suspension settles open, not listening")
        XCTAssertGreaterThanOrEqual(capture.stopCount, 1, "capture is released")
        XCTAssertTrue(controller.hasLiveVoiceSession, "the logical Voice session is preserved")
        XCTAssertEqual(controller.conversationTranscript, transcriptAfterTurn, "the in-sheet transcript survives suspension")
    }

    func testSuspensionWhileSpeakingStopsPlaybackAndPreservesIdentity() async {
        let (controller, capture, playback, gateway, flags) = makeFixtureWithPlayback()
        await driveToSpeaking(controller, gateway: gateway, flags: flags)
        XCTAssertTrue(playback.isPlaying)

        controller.suspendRuntimeForLifecycle()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(playback.isPlaying, "local TTS stops on suspension")
        XCTAssertGreaterThanOrEqual(capture.stopCount, 1)
        XCTAssertTrue(controller.hasLiveVoiceSession)
        XCTAssertFalse(controller.conversationTranscript.isEmpty, "assistant transcript survives suspension")
    }

    func testSuspensionPreservesExplicitUserPause() async {
        let (controller, capture, _, _) = makeFixture()
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        controller.pauseMicrophone()

        controller.suspendRuntimeForLifecycle()
        controller.setForegroundActive(true)

        XCTAssertTrue(controller.isMicrophonePaused, "an explicit user pause survives suspension")
        XCTAssertEqual(capture.startCount, 1, "restoration must not start capture")
        XCTAssertTrue(controller.hasLiveVoiceSession)
    }

    func testSuspensionRetiresInFlightTurnVoiceContinuationWithoutCancellingServerTurn() async {
        let (controller, capture, gateway, flags) = makeFixture()
        await driveToThinking(controller, gateway: gateway, flags: flags)
        XCTAssertEqual(flags.submitTexts, ["Question"], "the turn was submitted before suspension")

        controller.suspendRuntimeForLifecycle()

        XCTAssertEqual(flags.interrupts, 0, "the Hermes turn is not cancelled by suspension")
        let startsAtSuspension = capture.startCount

        // The suspended turn's terminal events belong to the retired turn:
        // they must not speak, append, or relisten.
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "late"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "late answer"))
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, startsAtSuspension, "no stale relisten after suspension")
        XCTAssertEqual(flags.speechStreamOpens, 0, "no stale TTS after suspension")
    }

    func testStopAfterSuspensionStillClosesFully() async {
        let (controller, _, _, _) = makeFixture()
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        controller.suspendRuntimeForLifecycle()
        XCTAssertTrue(controller.hasLiveVoiceSession)

        controller.stop()

        XCTAssertFalse(controller.hasLiveVoiceSession, "explicit Close tears the suspended session down")
        XCTAssertEqual(controller.state, .idle)
    }

    func testLateUtteranceTranscriptionAfterSuspensionCannotSubmit() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = GatedTranscriptionGateway(transcript: "Question")
        let flags = Flags()
        let submitAction: @MainActor (String) async -> Bool = { text in
            flags.submitTexts.append(text)
            return true
        }
        let interruptAction: @MainActor () async -> Void = {
            flags.interrupts += 1
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: GatedPlayback(),
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: submitAction,
            interrupt: interruptAction
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        // Drive the utterance into the parked transcription await.
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gateway.waitUntilTranscribing()
        XCTAssertEqual(gateway.transcriptionCount, 1, "transcription is in flight")

        controller.suspendRuntimeForLifecycle()
        gateway.releaseTranscription()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(flags.submitTexts, [], "the suspended utterance must never submit")
        XCTAssertEqual(controller.state, .idle)
    }

    func testSpeakerRouteRemainsHalfDuplexInTurnsAfterRestore() async {
        let capture = MockCapture(permissionGranted: true)
        let playback = GatedPlayback()
        let gateway = MockGateway(transcript: "Question")
        let flags = Flags()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let submitAction: @MainActor (String) async -> Bool = { _ in true }
        let interruptAction: @MainActor () async -> Void = {
            flags.interrupts += 1
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: submitAction,
            interrupt: interruptAction
        )

        await driveToSpeaking(controller, gateway: gateway, flags: flags)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)
        controller.suspendRuntimeForLifecycle()
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "suspension releases the playback-suspension state")
        controller.setForegroundActive(true)

        // A fresh turn after restoration behaves exactly like before: the
        // speaker-safe route suspends capture during TTS again.
        await driveToSpeaking(controller, gateway: gateway, flags: flags)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "route safety is unchanged after restoration")
    }

    // MARK: fixtures

    final class Flags {
        var submitTexts: [String] = []
        var interrupts = 0
        var speechStreamOpens = 0
        var playbackStopCount = 0
    }

    private func makeFixture() -> (VoiceConversationController, MockCapture, MockGateway, Flags) {
        let capture = MockCapture(permissionGranted: true)
        let playback = GatedPlayback()
        let gateway = MockGateway(transcript: "Question")
        let flags = Flags()
        let submitAction: @MainActor (String) async -> Bool = { text in
            flags.submitTexts.append(text)
            return true
        }
        let interruptAction: @MainActor () async -> Void = {
            flags.interrupts += 1
        }
        playback.onStop = { flags.playbackStopCount += 1 }
        gateway.onStreamOpen = { flags.speechStreamOpens += 1 }
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: submitAction,
            interrupt: interruptAction
        )
        return (controller, capture, gateway, flags)
    }

    private func makeFixtureWithPlayback() -> (VoiceConversationController, MockCapture, GatedPlayback, MockGateway, Flags) {
        let capture = MockCapture(permissionGranted: true)
        let playback = GatedPlayback()
        let gateway = MockGateway(transcript: "Question")
        let flags = Flags()
        let submitAction: @MainActor (String) async -> Bool = { _ in true }
        let interruptAction: @MainActor () async -> Void = {
            flags.interrupts += 1
        }
        gateway.onStreamOpen = { flags.speechStreamOpens += 1 }
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: submitAction,
            interrupt: interruptAction
        )
        return (controller, capture, playback, gateway, flags)
    }

    private func driveToThinking(
        _ controller: VoiceConversationController,
        gateway: MockGateway,
        flags: Flags
    ) async {
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(flags.submitTexts, ["Question"])
    }

    private func driveToSpeaking(
        _ controller: VoiceConversationController,
        gateway: MockGateway,
        flags: Flags
    ) async {
        await driveToThinking(controller, gateway: gateway, flags: flags)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer."))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .speaking)
    }
}

// MARK: - AppState-level suspension and restoration

@MainActor
final class AppStateVoiceSuspensionTests: XCTestCase {
    func testBackgroundWithOpenVoiceSuspendsRuntimeAndRetainsDescriptor() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        let startsBeforeBackground = harness.capture.startCount

        harness.appState.handleScenePhase(.background)

        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.profile, "default")
        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.sessionID, "session-1")
        XCTAssertTrue(harness.appState.showVoiceSheet, "suspension is not Close: the sheet intent is preserved")
        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertGreaterThanOrEqual(harness.capture.stopCount, 1, "capture is released on suspension")
        XCTAssertEqual(harness.capture.startCount, startsBeforeBackground, "suspension does not start capture")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "logical Voice session is preserved")
    }

    func testBackgroundWhileListeningFencesLateCaptureEvents() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.controller.startListening()

        harness.appState.handleScenePhase(.background)
        harness.controller.setForegroundActive(true)

        let start = Date()
        harness.capture.emit(level: 0.4, at: start)
        harness.capture.emit(level: 0.4, at: start.addingTimeInterval(0.4))
        harness.capture.emit(level: 0, at: start.addingTimeInterval(1.6))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(harness.gateway.transcriptionCount, 0, "suspended capture events must not transcribe")
        XCTAssertEqual(harness.flags.submitTexts, [])
    }

    func testBackgroundWhileSpeakingStopsPlaybackAndFencesLateCompletion() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        await harness.driveToSpeaking()
        XCTAssertTrue(harness.playback.isPlaying)
        let startsBeforeBackground = harness.capture.startCount

        harness.appState.handleScenePhase(.background)
        XCTAssertFalse(harness.playback.isPlaying, "local TTS stops on suspension")

        // The assistant completes while Conduit is away; the late completion
        // must neither speak nor relisten.
        harness.controller.receiveAssistantEvent(
            .completed(sessionID: "session-1", content: "Answer.")
        )
        harness.controller.setForegroundActive(true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(harness.capture.startCount, startsBeforeBackground, "late completion must not relisten")
        XCTAssertEqual(harness.controller.state, .idle)
    }

    func testBackgroundWhileThinkingDoesNotCancelServerTurn() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()

        harness.appState.handleScenePhase(.background)

        XCTAssertEqual(harness.flags.interrupts, 0, "suspension must not cancel the running Hermes turn")
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)
    }

    func testForegroundRestoreReinstallsGatewayWithoutStartingMic() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)
        // Simulate the gateway not surviving the suspension.
        harness.controller.setGateway(nil)
        XCTAssertFalse(harness.controller.isGatewayAttached)

        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation, "restoration consumes the descriptor")
        XCTAssertTrue(harness.appState.showVoiceSheet, "the Voice sheet is restored")
        XCTAssertTrue(harness.controller.isGatewayAttached, "the gateway is reinstalled")
        XCTAssertEqual(harness.controller.state, .idle, "restoration is open but non-listening")
        XCTAssertEqual(harness.capture.startCount, 1, "restoration never activates the microphone")
    }

    func testContinuousConversationOnStillRestoresNonListening() async {
        let harness = makeHarness()
        XCTAssertTrue(harness.appState.setContinuousConversation(true))
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)

        harness.foregroundForRestoration()

        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertEqual(harness.capture.startCount, 1, "Continuous Conversation is not permission to hot-start the mic after a lifecycle transition")
    }

    func testContinuousConversationOffRestoresNonListening() async {
        let harness = makeHarness()
        XCTAssertTrue(harness.appState.setContinuousConversation(false))
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)

        harness.foregroundForRestoration()

        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertTrue(harness.appState.showVoiceSheet)
    }

    func testExplicitCloseBeforeBackgroundPreventsRestoration() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        harness.appState.closeVoiceConversation()

        harness.appState.handleScenePhase(.background)
        XCTAssertNil(harness.appState.suspendedVoiceConversation, "a closed Voice conversation is not suspendable")

        harness.foregroundForRestoration()
        XCTAssertFalse(harness.appState.showVoiceSheet, "background/foreground must not resurrect a closed Voice session")
    }

    func testSpokenGoodbyeBeforeBackgroundPreventsRestoration() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.speakUtterance("Goodbye.")
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(harness.appState.showVoiceSheet, "the spoken End Conversation closed Voice through the Close path")
        harness.appState.handleScenePhase(.background)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)

        harness.foregroundForRestoration()
        XCTAssertFalse(harness.appState.showVoiceSheet)
    }

    func testStaleRestoreCannotReopenAfterExplicitClose() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)

        harness.foregroundForRestoration()
        XCTAssertTrue(harness.appState.showVoiceSheet)

        // Explicit Close wins over any restoration.
        harness.appState.closeVoiceConversation()
        harness.appState.handleScenePhase(.background)
        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "a stale restore must not reopen closed Voice")
    }

    func testProfileChangeWhileBackgroundedPreventsRestoration() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)

        harness.appState.setActiveProfileForTesting("beta")
        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "Voice must not be restored into a different profile")
    }

    func testServerIdentityChangePreventsRestoration() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)

        harness.appState.connection = HermesConnection(baseUrl: "https://other-server.example.com", ticket: "t")
        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "a replaced server is a destructive Voice boundary")
    }

    func testDisconnectClearsSuspension() {
        let harness = makeHarness()
        harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)

        harness.appState.disconnect()

        XCTAssertNil(harness.appState.suspendedVoiceConversation, "logout/disconnect clears suspended Voice")
        XCTAssertFalse(harness.appState.showVoiceSheet)

        harness.foregroundForRestoration()
        XCTAssertFalse(harness.appState.showVoiceSheet)
    }

    func testVoiceDisabledWhileSuspendedPreventsRestoration() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)

        await harness.appState.setVoiceEnabled(false)

        XCTAssertNil(harness.appState.suspendedVoiceConversation, "disabling Voice clears the suspended descriptor")
        harness.foregroundForRestoration()
        XCTAssertFalse(harness.appState.showVoiceSheet)
    }

    func testInvalidSuspendedSessionFailsClosedWithoutReplacementSession() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)

        // The authoritative session changed while Conduit was away.
        harness.appState.activeSessionId = "session-2"
        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "stale session identity fails closed")
        XCTAssertEqual(harness.appState.activeSessionId, "session-2", "restoration must not invent a replacement session")
    }

    func testSceneActiveWiresRestorationAndFailsClosedWhenSignedOut() {
        let harness = makeHarnessWithoutConnection()
        harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)

        harness.appState.handleScenePhase(.active)

        XCTAssertNil(harness.appState.suspendedVoiceConversation, "the .active scene path consumes the descriptor")
        XCTAssertFalse(harness.appState.showVoiceSheet, "signed-out return fails closed")
    }

    func testRestoreThenListenRunsTheFullConversation() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)

        harness.foregroundForRestoration()

        // The user taps Listen and speaks again: the same conversation continues.
        await harness.controller.resumeMicrophone()
        XCTAssertEqual(harness.controller.state, .listening)
        await harness.speakUtterance("Follow-up question", sessionArmed: true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(harness.flags.submitTexts, ["Question", "Follow-up question"])
        harness.controller.receiveAssistantEvent(.started(sessionID: "session-1"))
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-1", text: "Reply."))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(harness.controller.state, .speaking, "assistant replies are voiced for the restored conversation")
    }

    // MARK: harness

    struct Harness {
        let appState: AppState
        let controller: VoiceConversationController
        let capture: MockCapture
        let playback: GatedPlayback
        let gateway: MockGateway
        let flags: Flags

        func openVoice(session: String) {
            appState.activeSessionId = session
            appState.showVoiceSheet = true
            controller.beginVoiceTurn(sessionID: session)
        }

        /// Drives one submitted user turn end to end (listening → thinking).
        func driveToThinking() async {
            await controller.startListening()
            speakUtteranceIntoVAD("Question")
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        /// Drives the assistant reply until audible playback.
        func driveToSpeaking() async {
            controller.receiveAssistantEvent(.started(sessionID: "session-1"))
            controller.receiveAssistantEvent(.delta(sessionID: "session-1", text: "Answer."))
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        /// Speaks one utterance through the live capture. With
        /// `sessionArmed` the capture is already listening (post-restore
        /// Listen), otherwise the turn is armed first.
        func speakUtterance(_ text: String, sessionArmed: Bool = false) async {
            if !sessionArmed {
                controller.beginVoiceTurn(sessionID: appState.activeSessionId ?? "session-1")
                await controller.startListening()
            }
            speakUtteranceIntoVAD(text)
        }

        private func speakUtteranceIntoVAD(_ text: String) {
            let start = Date()
            capture.emit(level: 0.1, at: start)
            capture.emit(level: 0, at: start.addingTimeInterval(1.3))
        }

        /// Foreground return WITHOUT the reconnect task: flips the controller
        /// foreground flag and runs the synchronous restoration validation —
        /// exactly what the .active scene phase does before its transport work.
        func foregroundForRestoration() {
            controller.setForegroundActive(true)
            appState.restoreSuspendedVoiceConversationIfNeeded()
        }
    }

    final class Flags {
        var submitTexts: [String] = []
        var interrupts = 0
    }

    private func makeHarness() -> Harness {
        let suite = "AppStateVoiceSuspensionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { [defaults] in
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("default", forKey: "conduit.activeProfile")

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

        let capture = MockCapture(permissionGranted: true)
        let playback = GatedPlayback()
        let gateway = MockGateway(transcript: "Question")
        let flags = Flags()
        let submitAction: @MainActor (String) async -> Bool = { text in
            flags.submitTexts.append(text)
            return true
        }
        let interruptAction: @MainActor () async -> Void = {
            flags.interrupts += 1
        }
        let appStateRef = appState
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: submitAction,
            interrupt: interruptAction,
            onEndConversation: { [weak appStateRef] in
                appStateRef?.closeVoiceConversation()
            }
        )
        appState.voiceConversationController = controller

        return Harness(
            appState: appState,
            controller: controller,
            capture: capture,
            playback: playback,
            gateway: gateway,
            flags: flags
        )
    }

    private func makeHarnessWithoutConnection() -> Harness {
        let suite = "AppStateVoiceSuspensionTests.SignedOut.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { [defaults] in
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("default", forKey: "conduit.activeProfile")

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.isConnected = false
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

        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question")
        let appStateRef = appState
        let controller = VoiceConversationController(
            capture: capture,
            playback: GatedPlayback(),
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: { _ in true },
            interrupt: {},
            onEndConversation: { [weak appStateRef] in
                appStateRef?.closeVoiceConversation()
            }
        )
        appState.voiceConversationController = controller

        return Harness(
            appState: appState,
            controller: controller,
            capture: capture,
            playback: GatedPlayback(),
            gateway: gateway,
            flags: Flags()
        )
    }
}

/// Fail-fast requester so capability refreshes skip the network.
@MainActor
private final class ImmediateVoiceConfigRequester: VoiceConfigurationRequesting {
    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        throw URLError(.notConnectedToInternet)
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
    private(set) var stopCount = 0

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
    func stop() {
        stopCount += 1
        captureGeneration &+= 1
    }
    func emit(level: Float, at date: Date = Date()) {
        continuation?.yield(.level(level, date: date, generation: captureGeneration))
    }
}

@MainActor
private final class GatedPlayback: SpeechPlaybackService {
    var isPlaying = false
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    var onStop: (() -> Void)?
    func start(sampleRate: Double) throws { isPlaying = true }
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int { data.count - (data.count % 2) }
    func playEncodedAudioData(_ data: Data) throws { isPlaying = true }
    func finish() throws {}
    func drain() async { isPlaying = false }
    func stop() {
        isPlaying = false
        onStop?()
    }
}

@MainActor
private final class MockGateway: VoiceGatewayService {
    let profile = "default"
    let transcript: String
    var onStreamOpen: (() -> Void)?
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
        // drain that has deltas delivers the start control immediately.
        try onStart(24_000)
        onStreamOpen?()
        return StubSpeechStream()
    }
}

/// Transcription that parks until released, so a test can suspend Voice
/// while a transcription is provably in flight.
@MainActor
private final class GatedTranscriptionGateway: VoiceGatewayService {
    let profile = "default"
    let transcript: String
    private(set) var transcriptionCount = 0
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var transcribingWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(transcript: String) { self.transcript = transcript }

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        transcriptionCount += 1
        let waiters = transcribingWaiters
        transcribingWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if isReleased { return transcript }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingContinuation = continuation
                if self.isReleased || Task.isCancelled {
                    self.pendingContinuation = nil
                    continuation.resume(with: .success(self.transcript))
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.pendingContinuation else { return }
                self.pendingContinuation = nil
                continuation.resume(throwing: CancellationError())
            }
        })
    }

    func waitUntilTranscribing() async {
        if transcriptionCount > 0 { return }
        await withCheckedContinuation { transcribingWaiters.append($0) }
    }

    func releaseTranscription() {
        isReleased = true
        pendingContinuation?.resume(with: .success(transcript))
        pendingContinuation = nil
    }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        try onStart(24_000)
        return StubSpeechStream()
    }
}

@MainActor
private final class StubSpeechStream: VoiceSpeechStream {
    func append(_ text: String) async throws {}
    func finish() async throws -> Bool { false }
    func cancel() {}
}

/// Mutable route policy so tests can pin route classification
/// deterministically; production reads the live AVAudioSession route.
@MainActor
private final class RoutePolicyBox {
    var policy: VoiceBargeInRoutePolicy
    init(_ policy: VoiceBargeInRoutePolicy) { self.policy = policy }
}
