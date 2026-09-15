//
//  VoiceBackgroundSuspensionTests.swift
//  Conduit
//
//  Voice background behavior: lifecycle suspension (logical preservation +
//  runtime release) instead of hard teardown, and conservative foreground
//  restoration gated on profile/session/server identity.
//
//  Synchronization convention: asynchronous controller/AppState work is
//  observed through the explicit signals in VoiceTestSupport.swift
//  (`SubmitSpy.waitUntilSubmitted`, `MockGateway.waitUntil*`,
//  `ControlledSuspension.waitUntilSuspended`,
//  `GatedTranscriptionGateway.waitUntilTranscribing`,
//  `InterruptParkingGate.waitUntilEntered`, `waitForState`/`waitForMicrophoneLevel`
//  @Published waits). No test waits on a fixed settling window; negative
//  assertions drain pending MainActor work instead.
//

import XCTest
@testable import Conduit

// MARK: - Controller-level suspension semantics

@MainActor
final class VoiceConversationLifecycleSuspensionTests: XCTestCase {
    func testSuspensionReleasesRuntimeButPreservesConversationIdentity() async {
        let (controller, capture, gateway, spy, flags) = makeFixture()
        await driveToThinking(controller, gateway: gateway, spy: spy)
        let transcriptAfterTurn = controller.conversationTranscript

        controller.suspendRuntimeForLifecycle()

        XCTAssertEqual(controller.state, .idle, "suspension settles open, not listening")
        XCTAssertGreaterThanOrEqual(capture.stopCount, 1, "capture is released")
        XCTAssertTrue(controller.hasLiveVoiceSession, "the logical Voice session is preserved")
        XCTAssertEqual(controller.conversationTranscript, transcriptAfterTurn, "the in-sheet transcript survives suspension")
    }

    func testSuspensionWhileSpeakingStopsPlaybackAndPreservesIdentity() async {
        let (controller, capture, playback, gateway, spy, flags) = makeFixture()
        await driveToSpeaking(controller, gateway: gateway, spy: spy)
        XCTAssertTrue(playback.isPlaying)

        controller.suspendRuntimeForLifecycle()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(playback.isPlaying, "local TTS stops on suspension")
        XCTAssertGreaterThanOrEqual(capture.stopCount, 1)
        XCTAssertTrue(controller.hasLiveVoiceSession)
        XCTAssertFalse(controller.conversationTranscript.isEmpty, "assistant transcript survives suspension")
    }

    func testSuspensionPreservesExplicitUserPause() async {
        let (controller, capture, gateway, spy, flags) = makeFixture()
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        controller.pauseMicrophone()

        controller.suspendRuntimeForLifecycle()
        controller.setForegroundActive(true)

        XCTAssertTrue(controller.isMicrophonePaused, "an explicit user pause survives suspension")
        XCTAssertEqual(capture.startCount, 1, "restoration must not start capture")
        XCTAssertTrue(controller.hasLiveVoiceSession)

        // The user's Listen tap on the restored sheet unpauses and genuinely
        // recaptures.
        await controller.resumeMicrophone()
        XCTAssertFalse(controller.isMicrophonePaused)
        XCTAssertEqual(capture.resumeCount, 1, "Listen after a restored pause reacquires capture")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertFalse(controller.isRuntimeSuspended, "the suspended-runtime gate ends with the recapture")

        // The recaptured microphone must actually hear: level events flow
        // through the gate into the meter and VAD.
        let firstHeard = Date()
        capture.emit(level: 0.5, at: firstHeard)
        let heard = await controller.waitForMicrophoneLevel { $0 > 0 }
        XCTAssertTrue(heard, "the recaptured microphone hears speech")
        XCTAssertGreaterThan(controller.microphoneLevel, 0, "the recaptured microphone hears speech")

        // …and the heard speech completes a full utterance: transcription
        // then submission.
        capture.emit(level: 0.5, at: firstHeard.addingTimeInterval(0.4))
        capture.emit(level: 0, at: firstHeard.addingTimeInterval(1.8))
        await gateway.waitUntilTranscriptionStarted()
        await spy.waitUntilSubmitted(1)
        XCTAssertEqual(gateway.transcriptionCount, 1, "the utterance reaches transcription")
        XCTAssertEqual(spy.texts, ["Question"], "and reaches submission")
        XCTAssertEqual(controller.state, .thinking)
    }

    func testSuspensionRetiresInFlightTurnVoiceContinuationWithoutCancellingServerTurn() async {
        let (controller, capture, gateway, spy, flags) = makeFixture()
        await driveToThinking(controller, gateway: gateway, spy: spy)
        XCTAssertEqual(spy.texts, ["Question"], "the turn was submitted before suspension")

        controller.suspendRuntimeForLifecycle()

        XCTAssertEqual(flags.interrupts.value, 0, "the Hermes turn is not cancelled by suspension")
        let startsAtSuspension = capture.startCount

        // The suspended turn's terminal events belong to the retired turn:
        // they must not speak, append, or relisten.
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "late"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "late answer"))
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, startsAtSuspension, "no stale relisten after suspension")
        XCTAssertEqual(gateway.openCount, 0, "no stale TTS after suspension")
    }

    func testNextSubmitAfterSuspensionCancelsOrphanedTurnAndContinues() async {
        let (controller, capture, gateway, spy, flags) = makeFixture()
        await driveToThinking(controller, gateway: gateway, spy: spy)
        controller.suspendRuntimeForLifecycle()
        controller.setForegroundActive(true)

        // The user taps Listen and speaks again: the orphaned pre-suspension
        // turn is cancelled through the interrupt seam before the new
        // submission arms, so its late events can never alias onto the new
        // turn's ownership.
        await controller.resumeMicrophone()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await flags.interrupts.waitUntil(1)
        await spy.waitUntilSubmitted(2)

        XCTAssertEqual(flags.interrupts.value, 1, "the orphaned turn is cancelled by the next user submission")
        XCTAssertEqual(spy.texts, ["Question", "Question"], "the new turn submits normally")

        // The orphan's cancellation terminal arrives before the new turn
        // starts; it must not fail or settle the new turn.
        controller.receiveAssistantEvent(.interrupted(sessionID: "session"))
        XCTAssertEqual(controller.state, .thinking)
    }

    func testOrphanSurvivesConsecutiveSuspensions() async {
        let (controller, capture, gateway, spy, flags) = makeFixture()
        await driveToThinking(controller, gateway: gateway, spy: spy)

        // background → foreground → background: the second suspension must
        // not forget the orphan recorded by the first (the awaiting state it
        // would read from was already cleared).
        controller.suspendRuntimeForLifecycle()
        controller.setForegroundActive(true)
        controller.suspendRuntimeForLifecycle()
        controller.setForegroundActive(true)

        await controller.resumeMicrophone()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await flags.interrupts.waitUntil(1)
        await spy.waitUntilSubmitted(2)

        XCTAssertEqual(flags.interrupts.value, 1, "the orphan survives a background/foreground/background cycle")
        XCTAssertEqual(spy.texts, ["Question", "Question"])
    }

    func testOrphanProtectionSurvivesSupersededCancelAwait() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question")
        let spy = SubmitSpy()
        let flags = Flags()
        let gate = InterruptParkingGate()
        let submitAction: @MainActor (String) async -> Bool = { spy.submit($0) }
        let interruptAction: @MainActor () async -> Bool = {
            flags.interrupts.increment()
            await gate.waitInInterrupt()
            return true
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: submitAction,
            interrupt: interruptAction
        )
        await driveToThinking(controller, gateway: gateway, spy: spy)
        controller.suspendRuntimeForLifecycle()
        controller.setForegroundActive(true)

        // First post-restore submission enters the orphan-cancel interrupt
        // and parks mid-await.
        await controller.resumeMicrophone()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await gate.waitUntilEntered()

        // A new suspension supersedes the parked cancel: the utterance task
        // dies, and the sticky orphan flag must survive it.
        controller.suspendRuntimeForLifecycle()
        gate.release()
        await drainPendingMainActorWork()
        XCTAssertEqual(spy.texts, ["Question"], "the superseded submission never reached Hermes")

        controller.setForegroundActive(true)
        await controller.resumeMicrophone()
        let secondStart = Date()
        controller.ingestAudioLevel(0.1, at: secondStart)
        controller.ingestAudioLevel(0, at: secondStart.addingTimeInterval(1.3))
        await flags.interrupts.waitUntil(2)
        await spy.waitUntilSubmitted(2)

        XCTAssertEqual(flags.interrupts.value, 2, "the next submission still cancels the orphan")
        XCTAssertEqual(spy.texts, ["Question", "Question"], "and then submits normally")
    }

    func testFailedOrphanCancellationRetainsFlagAndBlocksSubmissionUntilRetry() async {
        let (controller, capture, gateway, spy, flags) = makeFixture()
        await driveToThinking(controller, gateway: gateway, spy: spy)
        controller.suspendRuntimeForLifecycle()
        controller.setForegroundActive(true)

        // The orphan cancellation FAILS: the flag stays armed and the new
        // utterance is never submitted.
        flags.interruptSucceeds = false
        await controller.resumeMicrophone()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await flags.interrupts.waitUntil(1)
        let failed = await controller.waitForFailedState()
        XCTAssertTrue(failed, "the failed orphan cancellation failed the session")

        XCTAssertEqual(flags.interrupts.value, 1)
        XCTAssertEqual(gateway.transcriptionCount, 2, "the retry utterance was heard again…")
        XCTAssertEqual(spy.texts, ["Question"], "…but never submitted while the orphan stands")
        XCTAssertEqual(controller.state, .failed("Hermes could not cancel the previous response."))

        // A later successful retry clears the orphan and submits normally.
        flags.interruptSucceeds = true
        await controller.resumeMicrophone()
        let retryStart = Date()
        controller.ingestAudioLevel(0.1, at: retryStart)
        controller.ingestAudioLevel(0, at: retryStart.addingTimeInterval(1.3))
        await flags.interrupts.waitUntil(2)
        await spy.waitUntilSubmitted(2)

        XCTAssertEqual(flags.interrupts.value, 2, "the retry cancels the orphan again")
        XCTAssertEqual(spy.texts, ["Question", "Question"], "the retry submits normally")
        XCTAssertEqual(controller.state, .thinking)
    }

    func testStopAfterSuspensionStillClosesFully() async {
        let (controller, _, _, _, _) = makeFixture()
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
        let spy = SubmitSpy()
        let flags = Flags()
        let submitAction: @MainActor (String) async -> Bool = { spy.submit($0) }
        let interruptAction: @MainActor () async -> Bool = {
            flags.interrupts.increment()
            return flags.interruptSucceeds
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
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
        await drainPendingMainActorWork()

        XCTAssertEqual(spy.texts, [], "the suspended utterance must never submit")
        XCTAssertEqual(controller.state, .idle)
    }

    func testSpeakerRouteRemainsHalfDuplexInTurnsAfterRestore() async {
        let capture = MockCapture(permissionGranted: true)
        let playback = MockPlayback()
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let spy = SubmitSpy()
        let flags = Flags()
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let submitAction: @MainActor (String) async -> Bool = { spy.submit($0) }
        let interruptAction: @MainActor () async -> Bool = {
            flags.interrupts.increment()
            return flags.interruptSucceeds
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: submitAction,
            interrupt: interruptAction
        )

        await driveToSpeaking(controller, gateway: gateway, spy: spy)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)
        controller.suspendRuntimeForLifecycle()
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "suspension releases the playback-suspension state")
        controller.setForegroundActive(true)

        // A fresh turn after restoration behaves exactly like before: the
        // speaker-safe route suspends capture during TTS again.
        await driveToSpeaking(controller, gateway: gateway, spy: spy, submissions: 2)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "route safety is unchanged after restoration")
    }

    // MARK: fixtures

    @MainActor
    final class Flags {
        let interrupts = AwaitableCounter()
        let endConversations = AwaitableCounter()
        /// Toggle per phase: a failed orphan cancellation must retain the
        /// orphan flag and block the new submission.
        var interruptSucceeds = true
    }

    private func makeFixture() -> (VoiceConversationController, MockCapture, MockPlayback, MockGateway, SubmitSpy, Flags) {
        let capture = MockCapture(permissionGranted: true)
        let playback = MockPlayback()
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let spy = SubmitSpy()
        let flags = Flags()
        let submitAction: @MainActor (String) async -> Bool = { spy.submit($0) }
        let interruptAction: @MainActor () async -> Bool = {
            flags.interrupts.increment()
            return flags.interruptSucceeds
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: submitAction,
            interrupt: interruptAction
        )
        return (controller, capture, playback, gateway, spy, flags)
    }

    private func driveToThinking(
        _ controller: VoiceConversationController,
        gateway: MockGateway,
        spy: SubmitSpy,
        submissions: Int = 1
    ) async {
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await spy.waitUntilSubmitted(submissions)
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(spy.texts.last, "Question")
    }

    private func driveToSpeaking(
        _ controller: VoiceConversationController,
        gateway: MockGateway,
        spy: SubmitSpy,
        submissions: Int = 1
    ) async {
        await driveToThinking(controller, gateway: gateway, spy: spy, submissions: submissions)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer."))
        let speaking = await controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the assistant reply is audible")
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
        harness.controller.setOutputMuted(true)
        let startsBeforeBackground = harness.capture.startCount

        harness.appState.handleScenePhase(.background)

        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.profile, "default")
        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.sessionID, "session-1")
        XCTAssertTrue(harness.appState.showVoiceSheet, "suspension is not Close: the sheet intent is preserved")
        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertTrue(harness.controller.isRuntimeSuspended, "suspended runtime state is explicit")
        XCTAssertGreaterThanOrEqual(harness.capture.stopCount, 1, "capture is released on suspension")
        XCTAssertEqual(harness.capture.startCount, startsBeforeBackground, "suspension does not start capture")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "logical Voice session is preserved")
        XCTAssertTrue(harness.controller.isOutputMuted, "an explicit mute survives suspension")
        XCTAssertFalse(
            harness.appState.consumeVoiceSheetAutoListen(),
            "suspension disarms the fresh-open auto-listen intent"
        )
    }

    func testSuspendedRuntimeRejectsCaptureEventsExplicitly() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.appState.handleScenePhase(.background)
        harness.controller.setForegroundActive(true)

        // Capture events arriving against suspended runtime state are
        // rejected before the meter — hasLiveVoiceSession is logical
        // ownership, not a claim that capture is live. Drain the pump so
        // both events are provably processed before the negative assertions.
        let start = Date()
        harness.capture.emit(level: 0.5, at: start)
        harness.capture.emit(level: 0.5, at: start.addingTimeInterval(0.4))
        await drainPendingMainActorWork()

        XCTAssertEqual(harness.controller.microphoneLevel, 0, "no meter publication while suspended")
        XCTAssertEqual(harness.gateway.transcriptionCount, 0)
    }

    func testTransientInactiveDipLeavesVoiceUntouched() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        let stopsBeforeDip = harness.capture.stopCount

        harness.appState.handleScenePhase(.inactive)

        // The .active reconciliation task is cancelled before assertions so
        // no production reconnect work escapes the test.
        let scene = harness.appState.handleScenePhase(.active)
        scene?.cancel()

        XCTAssertNil(harness.appState.suspendedVoiceConversation, "a transient dip records no descriptor")
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertEqual(harness.controller.state, .thinking, "the in-flight turn keeps flowing through a dip")
        XCTAssertEqual(harness.capture.stopCount, stopsBeforeDip, "no runtime teardown on a transient dip")
        XCTAssertTrue(
            harness.appState.consumeVoiceSheetAutoListen() == false && !harness.controller.isRuntimeSuspended,
            "the dip neither suspends the runtime nor touches the auto-listen intent"
        )

        let secondScene = harness.appState.handleScenePhase(.active)
        secondScene?.cancel()

        XCTAssertEqual(harness.controller.state, .thinking, "the turn continues after the dip")
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
    }

    func testListeningSurvivesTransientInactiveDip() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        XCTAssertEqual(harness.controller.state, .listening)

        harness.appState.handleScenePhase(.inactive)
        let scene = harness.appState.handleScenePhase(.active)
        scene?.cancel()

        XCTAssertEqual(harness.controller.state, .listening, "an already-listening dip does not tear the listen down")
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
    }

    func testPermissionPromptStyleDipDoesNotLoseInitialListen() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        // A fresh open arms the sheet's one-shot auto-listen (the microphone
        // permission prompt then dips the scene before it can fire).
        harness.appState.voiceSheetShouldAutoListen = true
        await harness.controller.startListening()

        harness.appState.handleScenePhase(.inactive)
        // Cancel the reconciliation task so no production reconnect work
        // escapes the test (there is no descriptor to restore here).
        let scene = harness.appState.handleScenePhase(.active)
        scene?.cancel()

        XCTAssertTrue(
            harness.appState.consumeVoiceSheetAutoListen(),
            "the user's initial Voice-open action must survive a permission-prompt dip"
        )
        XCTAssertEqual(harness.controller.state, .listening)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
    }

    func testSpeechCapabilityLossWhileSuspendedFailsClosed() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)

        // Speech is gone by the time Conduit returns (fresh opens are
        // rejected for the same reason).
        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: false,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )
        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "capability loss while suspended fails closed")
    }

    func testRuntimeRebindOfSameDurableConversationRestores() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)

        // Foreground reconciliation legitimately rebinds the runtime id; the
        // session catalog records both ids as one durable conversation.
        harness.appState.sessions = [SessionSummary(
            id: "session-2",
            alternateIds: ["session-1"],
            title: "Rebound",
            model: "m",
            updatedLabel: "",
            profile: "default",
            source: .chat,
            isActive: true,
            isArchived: false
        )]
        harness.appState.activeSessionId = "session-2"
        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertTrue(harness.appState.showVoiceSheet, "a legitimate rebind of the same durable conversation restores")
    }

    func testProfileFallbackAdoptionEndsSuspendedVoiceAndPersistsMuteUnderOutgoingProfile() throws {
        let harness = makeHarness()
        let defaults = harness.defaults
        let outgoingKey = "conduit.voice.preferences.v1.https://example.com.default"
        var seed = VoiceProfilePreferences()
        seed.outputMuted = false
        if let data = try? JSONEncoder().encode(seed) {
            defaults.set(data, forKey: outgoingKey)
        }
        harness.openVoice(session: "session-1")
        harness.controller.setOutputMuted(true)
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)

        // The real destructive profile path (profile discovery proved the
        // active profile no longer exists).
        harness.appState.adoptAuthoritativeFallbackProfile("fallback")

        XCTAssertNil(harness.appState.suspendedVoiceConversation, "the fallback re-home ends the suspension")
        XCTAssertFalse(harness.appState.showVoiceSheet)
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
        let outgoingData = try XCTUnwrap(defaults.data(forKey: outgoingKey))
        let outgoing = try JSONDecoder().decode(VoiceProfilePreferences.self, from: outgoingData)
        XCTAssertTrue(outgoing.outputMuted, "the outgoing mute is persisted under the OUTGOING profile")
        harness.foregroundForRestoration()
        XCTAssertFalse(harness.appState.showVoiceSheet, "nothing restores into the fallback profile")
    }

    func testCrossProfileFailClosedRestoreDoesNotWriteMute() async throws {
        let harness = makeHarness()
        let defaults = harness.defaults
        let betaKey = "conduit.voice.preferences.v1.https://example.com.beta"
        var beta = VoiceProfilePreferences()
        beta.outputMuted = false
        if let data = try? JSONEncoder().encode(beta) {
            defaults.set(data, forKey: betaKey)
        }
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.controller.setOutputMuted(true)
        harness.appState.handleScenePhase(.background)

        // The active profile changed by some path outside the suspension.
        harness.appState.setActiveProfileForTesting("beta")
        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "cross-profile staleness fails closed")
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
        let loadedBetaData = try XCTUnwrap(defaults.data(forKey: betaKey))
        let loadedBeta = try JSONDecoder().decode(VoiceProfilePreferences.self, from: loadedBetaData)
        XCTAssertFalse(
            loadedBeta.outputMuted,
            "the fail-closed teardown must not write the stale profile's mute into beta's preferences"
        )
    }

    func testRestorationWaitsForForegroundReconciliationAndAuthFailureFailsClosed() async {
        let mintGate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            mintTicket: { _ in
                await mintGate.suspend()
                throw DashboardTicketBridgeError.signInRequired
            }
        ))
        // A dead socket: the foreground reconciliation must reconnect first.
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "stale-ticket"),
            profile: "default"
        )
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)

        let scene = harness.appState.handleScenePhase(.active)
        await mintGate.waitUntilSuspended()
        XCTAssertNotNil(
            harness.appState.suspendedVoiceConversation,
            "restoration must not run before reconciliation completes"
        )
        XCTAssertTrue(harness.appState.showVoiceSheet)

        // The reconnect fails with a sign-in requirement: never restore
        // against stale pre-background state.
        mintGate.resume()
        await scene?.value

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "reconnect/auth failure fails closed")
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
    }

    func testVoiceSheetAutoListenIsConsumedExactlyOnce() {
        let harness = makeHarness()
        XCTAssertFalse(harness.appState.consumeVoiceSheetAutoListen())
        harness.appState.voiceSheetShouldAutoListen = true
        XCTAssertTrue(harness.appState.consumeVoiceSheetAutoListen())
        XCTAssertFalse(harness.appState.consumeVoiceSheetAutoListen(), "the intent is consumed exactly once")
    }

    func testInactiveThenBackgroundThenActiveRestoresExactlyOnce() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()

        harness.appState.handleScenePhase(.inactive)
        XCTAssertNil(harness.appState.suspendedVoiceConversation, "the dip alone records nothing")
        harness.appState.handleScenePhase(.background)
        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.sessionID, "session-1")

        harness.foregroundForRestoration()

        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertNil(harness.appState.suspendedVoiceConversation, "restoration consumes the descriptor exactly once")
        XCTAssertEqual(harness.controller.state, .idle)
    }

    func testCapabilityLossWhileSuspendedFailsClosed() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)

        // The transcription provider is gone by the time Conduit returns.
        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: false,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )
        harness.foregroundForRestoration()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "capability loss while suspended fails closed")
    }

    func testBackgroundWhileListeningFencesLateCaptureEvents() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.controller.startListening()

        harness.appState.handleScenePhase(.background)
        harness.controller.setForegroundActive(true)

        // Drain the pump so the suspended-runtime rejection of all three
        // events is provably processed before the negative assertions.
        let start = Date()
        harness.capture.emit(level: 0.4, at: start)
        harness.capture.emit(level: 0.4, at: start.addingTimeInterval(0.4))
        harness.capture.emit(level: 0, at: start.addingTimeInterval(1.6))
        await drainPendingMainActorWork()

        XCTAssertEqual(harness.gateway.transcriptionCount, 0, "suspended capture events must not transcribe")
        XCTAssertEqual(harness.spy.texts, [])
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
        // is rejected synchronously (no assistant turn is awaited) and must
        // neither speak nor relisten.
        harness.controller.receiveAssistantEvent(
            .completed(sessionID: "session-1", content: "Answer.")
        )
        harness.controller.setForegroundActive(true)
        await drainPendingMainActorWork()

        XCTAssertEqual(harness.capture.startCount, startsBeforeBackground, "late completion must not relisten")
        XCTAssertEqual(harness.controller.state, .idle)
    }

    func testBackgroundWhileThinkingDoesNotCancelServerTurn() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()

        harness.appState.handleScenePhase(.background)

        XCTAssertEqual(harness.flags.interrupts.value, 0, "suspension must not cancel the running Hermes turn")
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
        await harness.flags.endConversations.waitUntil(1)

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

    func testCaptureInterruptionWhileSuspendedDoesNotDestroyLogicalSession() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)
        XCTAssertTrue(harness.controller.isRuntimeSuspended)

        // A stale interruption from the RELEASED runtime arrives while the
        // logical Voice session is dormant: it must not clear ownership,
        // orphan bookkeeping, or restoration eligibility. Drain the pump so
        // the rejection is provably processed before the negative assertions.
        harness.capture.emitInterrupted()
        await drainPendingMainActorWork()

        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "logical ownership survives the stale interruption")
        XCTAssertTrue(harness.controller.isRuntimeSuspended)
        XCTAssertEqual(harness.controller.state, .idle, "the session is dormant, not failed")
        XCTAssertFalse(harness.controller.conversationTranscript.isEmpty, "the preserved transcript survives")
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation, "restoration eligibility survives")

        // Foreground restore still succeeds afterwards.
        harness.foregroundForRestoration()
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
    }

    func testLiveMuteSurvivesCapabilityRefreshAndRestore() async {
        let harness = makeHarness(requesterMode: .fullSupport)
        harness.defaults.set(true, forKey: "conduit.voice.enabled.v1.https://example.com.default")
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        // The in-session Mute control changes only the live controller state.
        harness.controller.setOutputMuted(true)
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)

        // The real restoration path: capability refresh through the gateway
        // answer, currency re-check, then restore.
        await harness.appState.refreshCapabilitiesAndRestoreSuspendedVoice(isCurrent: { true })

        XCTAssertTrue(harness.appState.voiceCapabilitySnapshot.supportsSpeech, "the refresh resolved a capable snapshot")
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertTrue(harness.appState.showVoiceSheet, "restoration succeeds")
        XCTAssertTrue(harness.controller.isOutputMuted, "the live mute wins over the reloaded persisted blob")
        // The restored sheet is open but not listening: the runtime gate
        // stays armed until the user taps Listen.
        XCTAssertTrue(harness.controller.isRuntimeSuspended)
    }

    func testLiveUnmuteWinsOverPersistedMuteAcrossRefreshAndRestore() async {
        let harness = makeHarness(requesterMode: .fullSupport)
        harness.defaults.set(true, forKey: "conduit.voice.enabled.v1.https://example.com.default")
        // Persisted blob says muted; the live session unmutes.
        var persisted = VoiceProfilePreferences()
        persisted.outputMuted = true
        harness.defaults.set(
            try! JSONEncoder().encode(persisted),
            forKey: "conduit.voice.preferences.v1.https://example.com.default"
        )
        await harness.openVoice(session: "session-1")
        harness.controller.setProfilePreferences(persisted)
        harness.controller.setOutputMuted(false)
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)

        await harness.appState.refreshCapabilitiesAndRestoreSuspendedVoice(isCurrent: { true })

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertFalse(
            harness.controller.isOutputMuted,
            "the live value, not whichever persisted value happens to exist, wins"
        )
    }

    func testStaleCapturedMuteDoesNotLeakAcrossProfileOnRestore() async {
        let harness = makeHarness()
        let betaKey = "conduit.voice.preferences.v1.https://example.com.beta"
        var beta = VoiceProfilePreferences()
        beta.outputMuted = false
        harness.defaults.set(try! JSONEncoder().encode(beta), forKey: betaKey)
        await harness.openVoice(session: "session-1")
        harness.controller.setOutputMuted(true)
        harness.appState.handleScenePhase(.background)

        // The active profile changed by some path outside the suspension.
        harness.appState.setActiveProfileForTesting("beta")
        await harness.appState.refreshCapabilitiesAndRestoreSuspendedVoice(isCurrent: { true })

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "cross-profile staleness fails closed")
        let loadedBeta = try! JSONDecoder().decode(
            VoiceProfilePreferences.self,
            from: harness.defaults.data(forKey: betaKey)!
        )
        XCTAssertFalse(
            loadedBeta.outputMuted,
            "the preserved mute is never reapplied to a different profile's blob"
        )
    }

    func testSupersededRefreshDoesNotRestoreOrReapplyMute() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        harness.controller.setOutputMuted(true)
        harness.appState.handleScenePhase(.background)

        await harness.appState.refreshCapabilitiesAndRestoreSuspendedVoice(isCurrent: { false })

        XCTAssertNotNil(harness.appState.suspendedVoiceConversation, "a superseded attempt leaves the descriptor")
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertTrue(harness.controller.isOutputMuted)
    }

    func testVoiceStillRestoresWhenAutomaticWorkInvalidatedDuringReconnect() async {
        let connectGate = ControlledSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in await connectGate.suspend() },
                loadCatalog: { _, _ in [] },
                mintTicket: { _ in "fresh-ticket" }
            ),
            requesterMode: .fullSupport
        )
        harness.defaults.set(
            true,
            forKey: "conduit.voice.enabled.v1.https://example.com.default"
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "stale-ticket"),
            profile: "default"
        )
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)

        let scene = harness.appState.handleScenePhase(.active)
        await connectGate.waitUntilSuspended()

        // The composer/viewport invalidates the automatic chat-resume work
        // while the reconnect runs.
        harness.appState.noteComposerUserEdit()
        connectGate.resume()
        await scene?.value

        XCTAssertNil(harness.appState.suspendedVoiceConversation, "the descriptor is consumed by the authoritative tail")
        XCTAssertTrue(harness.appState.showVoiceSheet, "Voice still restores after preserve-current reconnect")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(harness.controller.state, .idle, "restoration stays non-listening")
    }

    func testCapabilityRefreshBeforeRestoreFailsClosedWhenSupportIsGone() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        XCTAssertTrue(harness.appState.voiceCapabilitySnapshot.supportsSpeech, "pre-background the snapshot is capable")
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)

        // The post-reconciliation capability refresh consults the server
        // again (the harness requester resolves to no voice support) and
        // restoration fails closed on the refreshed answer instead of the
        // stale pre-background snapshot.
        await harness.appState.refreshCapabilitiesAndRestoreSuspendedVoice(isCurrent: { true })

        XCTAssertFalse(harness.appState.voiceCapabilitySnapshot.supportsSpeech, "the refresh replaced the stale snapshot")
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "restoration fails closed instead of reopening from stale state")
    }

    func testSupersededReconciliationAttemptLeavesDescriptorForSuccessor() async {
        let mintGate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            mintTicket: { _ in
                await mintGate.suspend()
                throw DashboardTicketBridgeError.signInRequired
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "stale-ticket"),
            profile: "default"
        )
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)

        // Attempt A parks mid-reconnect.
        let first = harness.appState.handleScenePhase(.active)
        await mintGate.waitUntilSuspended()

        // A newer .background boundary supersedes attempt A and RE-ARMS the
        // descriptor (it does not clear it).
        harness.appState.handleScenePhase(.background)
        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.sessionID, "session-1")

        // Attempt A finishes while superseded: it must NOT consume the
        // descriptor against pre-reconciliation state.
        mintGate.resume()
        await first?.value
        XCTAssertEqual(
            harness.appState.suspendedVoiceConversation?.sessionID, "session-1",
            "a superseded attempt must leave the descriptor for its successor"
        )

        // The successor restores normally.
        harness.foregroundForRestoration()
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
    }

    func testSignedOutActiveDefersRestorationInsteadOfConsuming() {
        let harness = makeHarnessWithoutConnection()
        harness.openVoice(session: "session-1")
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)

        // Signed out, the scene task never reconciles; restoration is
        // deferred, NOT consumed against stale pre-background state.
        harness.appState.handleScenePhase(.active)
        XCTAssertNotNil(
            harness.appState.suspendedVoiceConversation,
            "the descriptor survives a reconciliation-less signed-out return"
        )

        // A later explicit restoration attempt still fails closed.
        harness.foregroundForRestoration()
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.showVoiceSheet, "signed-out restoration fails closed")
    }

    func testRestoreThenListenRunsTheFullConversation() async {
        let harness = makeHarness()
        await harness.openVoice(session: "session-1")
        await harness.driveToThinking()
        harness.appState.handleScenePhase(.background)

        harness.foregroundForRestoration()

        // Production reinstalls a gateway built from the current bridge;
        // the mock gateway stands in for it so the conversation runs
        // without network.
        harness.controller.setGateway(harness.gateway)

        // The user taps Listen and speaks again: the same conversation continues.
        await harness.controller.resumeMicrophone()
        XCTAssertEqual(harness.controller.state, .listening)
        await harness.speakUtterance("Follow-up question", sessionArmed: true)
        await harness.spy.waitUntilSubmitted(2)

        XCTAssertEqual(harness.spy.texts, ["Question", "Follow-up question"])
        harness.controller.receiveAssistantEvent(.started(sessionID: "session-1"))
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-1", text: "Reply."))
        let speaking = await harness.controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "assistant replies are voiced for the restored conversation")
        XCTAssertEqual(harness.controller.state, .speaking, "assistant replies are voiced for the restored conversation")
    }

    // MARK: harness

    @MainActor
    private struct Harness {
        let appState: AppState
        let controller: VoiceConversationController
        let capture: MockCapture
        let playback: MockPlayback
        let gateway: MockGateway
        let spy: SubmitSpy
        let flags: Flags
        let defaults: UserDefaults

        func openVoice(session: String) {
            appState.activeSessionId = session
            appState.showVoiceSheet = true
            controller.beginVoiceTurn(sessionID: session)
            appState.voiceControllerSessionProfile = appState.activeProfile
        }

        /// Drives one submitted user turn end to end (listening → thinking):
        /// the submission of the transcript is the completion signal.
        func driveToThinking() async {
            await controller.startListening()
            speakUtteranceIntoVAD("Question")
            await spy.waitUntilSubmitted(1)
        }

        /// Drives the assistant reply until audible playback.
        func driveToSpeaking() async {
            controller.receiveAssistantEvent(.started(sessionID: "session-1"))
            controller.receiveAssistantEvent(.delta(sessionID: "session-1", text: "Answer."))
            let speaking = await controller.waitForState(.speaking)
            XCTAssertTrue(speaking, "the assistant reply is audible")
        }

        /// Speaks one utterance through the live capture. With
        /// `sessionArmed` the capture is already listening (post-restore
        /// Listen), otherwise the turn is armed first. The mock recognizer
        /// returns the spoken text, matching per-phase utterance pinning.
        func speakUtterance(_ text: String, sessionArmed: Bool = false) async {
            gateway.transcript = text
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

    @MainActor
    final class Flags {
        let interrupts = AwaitableCounter()
        let endConversations = AwaitableCounter()
        var interruptSucceeds = true
    }

    private func makeHarness(
        lifecycleOperations: ChatResumeLifecycleOperations = .live,
        requesterMode: ImmediateVoiceConfigRequester.Mode = .failing
    ) -> Harness {
        let suite = "AppStateVoiceSuspensionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { [defaults] in
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("default", forKey: "conduit.activeProfile")

        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: lifecycleOperations
        )
        appState.voiceCapabilityRequesterForTesting = ImmediateVoiceConfigRequester(mode: requesterMode)
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

        let capture = MockCapture(permissionGranted: true)
        let playback = MockPlayback()
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let spy = SubmitSpy()
        let flags = Flags()
        let submitAction: @MainActor (String) async -> Bool = { spy.submit($0) }
        let interruptAction: @MainActor () async -> Bool = {
            flags.interrupts.increment()
            return flags.interruptSucceeds
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
                flags.endConversations.increment()
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
            spy: spy,
            flags: flags,
            defaults: defaults
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
        let spy = SubmitSpy()
        let appStateRef = appState
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: { spy.submit($0) },
            interrupt: { true },
            onEndConversation: { [weak appStateRef] in
                appStateRef?.closeVoiceConversation()
            }
        )
        appState.voiceConversationController = controller

        return Harness(
            appState: appState,
            controller: controller,
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            spy: spy,
            flags: Flags(),
            defaults: defaults
        )
    }
}
