//
//  AppStateVoiceCapabilityTests.swift
//  Conduit
//
//  AppState-level voice capability gating: Hermes transcription availability
//  follows the profile config and the live transcription attempt — never the
//  provider picker's readiness metadata — while the Apple on-device route
//  stays gated only by its own permission/availability checks.
//

import XCTest
@testable import Conduit
import Metal

@MainActor
final class AppStateVoiceCapabilityTests: XCTestCase {
    /// The Reddit reproduction at the AppState layer: with the selected
    /// OpenAI provider ready (and the parser keeping the Nous Subscription
    /// row's needs_auth state on its own row), the composer mic stays usable.
    func testReadySelectedTranscriptionKeepsVoiceConversationAvailable() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            )
        )

        XCTAssertNil(appState.voiceUnavailableReason)
        XCTAssertTrue(appState.canStartVoiceConversation)
    }

    func testDisabledHermesTranscriptionStillBlocksVoiceConversation() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: false,
                supportsSpeech: true,
                unavailableReason: "Speech-to-text is disabled for this Hermes profile."
            )
        )

        XCTAssertEqual(appState.voiceUnavailableReason, "Speech-to-text is disabled for this Hermes profile.")
        XCTAssertFalse(appState.canStartVoiceConversation)
    }

    /// The Apple on-device route must not consult Hermes provider readiness:
    /// a profile with no ready Hermes STT still allows on-device dictation.
    func testAppleOnDeviceModeDoesNotConsultHermesTranscriptionReadiness() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: false,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            transcriptionMode: .appleOnDevice,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US")
        )

        XCTAssertNil(appState.voiceUnavailableReason)
        XCTAssertTrue(appState.canStartVoiceConversation)
    }

    /// Independence cuts both ways: the Apple route is still gated by its own
    /// Speech Recognition permission state, not by Hermes metadata.
    func testAppleOnDeviceModeStillHonorsItsOwnPermissionGate() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            transcriptionMode: .appleOnDevice,
            appleSpeechAvailability: .permissionDenied
        )

        XCTAssertEqual(
            appState.voiceUnavailableReason,
            "Allow Speech Recognition for Conduit in iPhone Settings > Conduit, or choose another speech-to-text option in Settings > Voice."
        )
        XCTAssertEqual(appState.voiceSetupIssue, .speechRecognitionDenied)
    }

    /// Uncertainty on the Apple route (permission not yet granted) does not
    /// block the mic — only an outright denial or unsupported locale does.
    func testApplePermissionRequiredDoesNotBlockVoiceConversation() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: false,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            transcriptionMode: .appleOnDevice,
            appleSpeechAvailability: .permissionRequired(localeIdentifier: "en-US")
        )

        XCTAssertNil(appState.voiceUnavailableReason)
        XCTAssertTrue(appState.canStartVoiceConversation)
    }

    /// Build-146 regression guard. Voice settings is a foreground screen that
    /// presents no Voice sheet, so the *capture* gate is closed there while
    /// the app-foreground gate must stay open: selecting "On this iPhone"
    /// asks iOS for permissions, and the settings-launched provider tests run
    /// capture — all legitimate with the app on screen. Reading the capture
    /// gate for those silently refused the selection (no mode change, no
    /// surfaced error), which is the regression this pins.
    func testVoiceSettingsSurfaceStateKeepsTheApplicationForegroundGateOpen() {
        let appState = makeReadyAppState()

        // Leave and re-enter the foreground — the transition that republishes
        // both gates — with the phone Voice sheet closed throughout: exactly
        // the state Voice settings is in.
        _ = appState.handleScenePhase(.background)
        XCTAssertFalse(appState.voiceConversationController.isApplicationForegroundGateOpen)
        let foreground = appState.handleScenePhase(.active)
        // The gate publication is synchronous; the reconciliation task it
        // also starts is not what this test covers.
        foreground?.cancel()

        XCTAssertFalse(appState.hasActiveVoiceSurface, "No Voice surface presents while the user is in Voice settings")
        XCTAssertTrue(appState.hasForegroundApplicationSurface)
        XCTAssertTrue(appState.voiceConversationController.isApplicationForegroundGateOpen)
    }

    /// The gate that must still close: iOS presents permission alerts only
    /// for a foreground app.
    func testBackgroundingClosesTheApplicationForegroundGate() {
        let appState = makeReadyAppState()
        appState.reassertVoiceSurfaceGate()

        _ = appState.handleScenePhase(.background)

        XCTAssertFalse(appState.voiceConversationController.isApplicationForegroundGateOpen)
    }

    /// CarPlay is the other app-foreground surface: presenting it keeps the
    /// gate open with the phone locked, and losing it closes the gate again.
    func testCarPlaySurfaceDrivesTheApplicationForegroundGateWhileThePhoneIsBackgrounded() {
        let appState = makeReadyAppState()
        _ = appState.handleScenePhase(.background)

        appState.setCarPlayVoiceSurfaceActive(true)
        XCTAssertTrue(appState.voiceConversationController.isApplicationForegroundGateOpen)

        appState.setCarPlayVoiceSurfaceActive(false)
        XCTAssertFalse(appState.voiceConversationController.isApplicationForegroundGateOpen)
    }

    /// An overlay dip must leave the Voice gates exactly as they were. The
    /// first-run microphone alert drives `.inactive` while `startListening`
    /// awaits its permission; republishing there would close the app gate the
    /// listen's `isCurrent` checks are fenced on, so every grant would kill
    /// the listen it was granted for. This pins the deliberate absence of a
    /// publication at `.inactive`, which nothing else observes.
    ///
    /// Only the published app gate is observable here (the capture gate has no
    /// seam); the computed surface properties read false during the dip by
    /// design, because they are consulted only at `.active` and `.background`,
    /// where they are re-published.
    func testOverlayDipLeavesThePublishedVoiceGatesUntouched() {
        let appState = makeReadyAppState()
        appState.showVoiceSheet = true
        appState.reassertVoiceSurfaceGate()
        XCTAssertTrue(appState.voiceConversationController.isApplicationForegroundGateOpen)

        _ = appState.handleScenePhase(.inactive)

        XCTAssertTrue(
            appState.voiceConversationController.isApplicationForegroundGateOpen,
            "an overlay dip must not close the app-foreground gate"
        )
    }

    /// Attaching a presentation to a live Voice conversation must republish the
    /// app-foreground gate, not only the capture gate. This is the healing path
    /// a CarPlay-only session relies on when it hands the conversation back to a
    /// phone whose gate a previous boundary left closed: without it, the next
    /// Listen or provider test is treated as backgrounded work and discarded —
    /// the stale-gate failure this PR fixed, one layer down.
    func testAttachingToALiveVoiceConversationReopensTheApplicationForegroundGate() {
        let appState = makeReadyAppState()
        appState.voiceConversationController.beginVoiceTurn(sessionID: "session-1")
        XCTAssertTrue(appState.voiceConversationController.hasLiveVoiceSession)
        appState.voiceConversationController.setApplicationForegroundActive(false)
        XCTAssertFalse(appState.voiceConversationController.isApplicationForegroundGateOpen)

        let attached = appState.attachToLiveVoiceConversation()

        XCTAssertTrue(attached, "the bridge and voice capability state are installed, so the gateway attaches")
        XCTAssertTrue(
            appState.voiceConversationController.isApplicationForegroundGateOpen,
            "attaching a presentation means the app is on screen"
        )
    }

    /// The attachment is only for a live conversation: without one the call is a
    /// no-op and must not silently reopen a gate on its own (that would make the
    /// foreground fact claimable from a non-presenting surface).
    func testAttachingWithoutALiveConversationLeavesTheGateClosed() {
        let appState = makeReadyAppState()
        appState.voiceConversationController.setApplicationForegroundActive(false)

        let attached = appState.attachToLiveVoiceConversation()

        XCTAssertFalse(attached)
        XCTAssertFalse(appState.voiceConversationController.isApplicationForegroundGateOpen)
    }

    private func makeReadyAppState() -> AppState {
        makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            )
        )
    }

    // MARK: - Composer voice button visibility (#194)

    func testComposerHidesVoiceButtonWhenVoiceWasNeverEnabled() {
        let appState = makeAppState(snapshot: readySnapshot, isVoiceEnabled: false)

        XCTAssertFalse(appState.showsComposerVoiceButton)
    }

    func testComposerShowsVoiceButtonOnceVoiceIsEnabled() async {
        let appState = makeAppState(snapshot: readySnapshot, isVoiceEnabled: false)
        let didEnable = await appState.setVoiceEnabled(true)
        XCTAssertTrue(didEnable)

        XCTAssertTrue(appState.showsComposerVoiceButton)
    }

    /// Enabled voice with a broken provider keeps the (disabled) button, so
    /// the user can still see something needs fixing.
    func testComposerKeepsVoiceButtonWhenEnabledVoiceIsUnavailable() async {
        let appState = makeAppState(snapshot: readySnapshot, isVoiceEnabled: false)
        _ = await appState.setVoiceEnabled(true)
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: .unavailable,
            isVoiceEnabled: true
        )

        XCTAssertFalse(appState.canStartVoiceConversation)
        XCTAssertTrue(appState.showsComposerVoiceButton)
    }

    /// A reconnect resets `isVoiceEnabled` before capabilities reload; the
    /// persisted preference keeps the button from blinking out meanwhile.
    func testPersistedVoicePreferenceKeepsButtonThroughReconnectReset() async {
        let appState = makeAppState(snapshot: readySnapshot, isVoiceEnabled: false)
        _ = await appState.setVoiceEnabled(true)

        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: .unavailable,
            isVoiceEnabled: false
        )

        XCTAssertTrue(appState.showsComposerVoiceButton)
    }

    /// Switching away from a voice-enabled profile must not leak its state
    /// while `isVoiceEnabled` still holds the previous profile's value.
    func testSwitchingToNeverEnabledProfileHidesVoiceButton() async {
        let appState = makeAppState(snapshot: readySnapshot, isVoiceEnabled: false)
        _ = await appState.setVoiceEnabled(true)

        appState.setActiveProfileForTesting("other-profile")

        XCTAssertTrue(appState.isVoiceEnabled)
        XCTAssertFalse(appState.showsComposerVoiceButton)
    }

    func testDisablingVoiceHidesComposerVoiceButton() async {
        let appState = makeAppState(snapshot: readySnapshot, isVoiceEnabled: false)
        _ = await appState.setVoiceEnabled(true)
        _ = await appState.setVoiceEnabled(false)

        XCTAssertFalse(appState.showsComposerVoiceButton)
    }

    // MARK: - Shared voice/send trailing slot (#194, #335)

    func testEmptyIdleComposerOffersVoiceInTheTrailingSlot() {
        XCTAssertEqual(
            ComposerBar.trailingControl(action: .unavailable, showsVoiceButton: true),
            .voice
        )
    }

    func testEmptyComposerWithoutVoiceKeepsTheActionButton() {
        XCTAssertEqual(
            ComposerBar.trailingControl(action: .unavailable, showsVoiceButton: false),
            .action
        )
    }

    /// Dictation has its own button (#335): once dictated words make the
    /// draft sendable, Send takes the slot even while still listening.
    func testSendableDraftTakesTheSlotFromVoice() {
        XCTAssertEqual(ComposerBar.trailingControl(action: .send, showsVoiceButton: true), .action)
    }

    func testDictatedTextGoesAfterTheDraftAndReplacesOnlyItsOwnSpan() {
        XCTAssertEqual(ComposerDictation.draft(before: "", dictated: "hello there"), "hello there")
        XCTAssertEqual(ComposerDictation.draft(before: "Note:", dictated: "buy milk"), "Note: buy milk")
        XCTAssertEqual(ComposerDictation.draft(before: "Note: ", dictated: " buy milk "), "Note: buy milk")
        XCTAssertEqual(ComposerDictation.draft(before: "Note:", dictated: "  "), "Note:", "nothing heard leaves the draft alone")
        // Each partial result rewrites the dictated span, never the draft.
        let prefix = "Draft"
        let partial = ComposerDictation.draft(before: prefix, dictated: "buy")
        let final = ComposerDictation.draft(before: prefix, dictated: "Buy milk.")
        XCTAssertEqual(partial, "Draft buy")
        XCTAssertEqual(final, "Draft Buy milk.")
    }

    func testADictationKeepsWhatWasSaidBeforeAPause() {
        // The recognizer closes the utterance at a pause and starts the next
        // one from empty (#333).
        var transcript = DictationTranscript()
        transcript.receive("So I'm now", endsUtterance: false)
        transcript.receive("So I'm now dictating something", endsUtterance: false)
        transcript.receive("So I'm now dictating something.", endsUtterance: true)
        transcript.receive("And", endsUtterance: false)
        XCTAssertEqual(transcript.text, "So I'm now dictating something. And")
        transcript.receive("And then I'm gonna continue", endsUtterance: false)
        XCTAssertEqual(transcript.text, "So I'm now dictating something. And then I'm gonna continue")
        transcript.receive("So I'm now dictating something. And then I'm gonna continue.", endsUtterance: false)
        XCTAssertEqual(transcript.text, "So I'm now dictating something. And then I'm gonna continue.",
                       "a final result holding the whole text replaces it rather than doubling it")

        var repeated = DictationTranscript()
        repeated.receive("I agree.", endsUtterance: true)
        repeated.receive("I", endsUtterance: false)
        repeated.receive("I think so too", endsUtterance: false)
        XCTAssertEqual(repeated.text, "I agree. I think so too", "a new utterance may start with the same word")

        var sameStart = DictationTranscript()
        sameStart.receive("Yes please.", endsUtterance: true)
        sameStart.receive("Yes I'd like that", endsUtterance: false)
        XCTAssertEqual(sameStart.text, "Yes please. Yes I'd like that",
                       "repeating only half of a closed utterance starts a new one")

        // A restart the recognizer didn't mark is still caught when it drops
        // most of the words and the first one.
        var unmarked = DictationTranscript()
        unmarked.receive("Buy milk and eggs today", endsUtterance: false)
        unmarked.receive("Also", endsUtterance: false)
        XCTAssertEqual(unmarked.text, "Buy milk and eggs today Also")
    }

    func testADictationRevisionReplacesTheWordsItRevises() {
        var transcript = DictationTranscript()
        transcript.receive("I scream", endsUtterance: false)
        transcript.receive("Ice cream please", endsUtterance: false)
        XCTAssertEqual(transcript.text, "Ice cream please", "a short revision is not a new utterance")

        transcript.receive("Ice cream, please.", endsUtterance: true)
        transcript.receive("Ice cream, please. Two scoops", endsUtterance: false)
        XCTAssertEqual(transcript.text, "Ice cream, please. Two scoops",
                       "a recognizer that keeps the whole text after a pause is not doubled")

        var lastWord = DictationTranscript()
        lastWord.receive("Meet me at the station", endsUtterance: false)
        lastWord.receive("Meet me at the stadium", endsUtterance: false)
        XCTAssertEqual(lastWord.text, "Meet me at the stadium")
    }

    func testACallFromANewEmptyChatIsNotAttachedToIt() {
        XCTAssertFalse(AppState.attachesLiveVoiceCall(chatHasMessages: false, turnState: .idle),
                       "an empty chat has nothing to continue")
        XCTAssertTrue(AppState.attachesLiveVoiceCall(chatHasMessages: true, turnState: .idle))
        XCTAssertTrue(AppState.attachesLiveVoiceCall(chatHasMessages: false, turnState: .synchronizing),
                      "a chat still loading may have history")
        XCTAssertTrue(AppState.attachesLiveVoiceCall(chatHasMessages: false, turnState: .running),
                      "its first message is on its way")
        XCTAssertFalse(AppState.attachesLiveVoiceCall(chatHasMessages: false, turnState: .reconnecting),
                       "reconnecting doesn't give an empty chat anything to continue")
    }

    func testTheQuickHintCountsEachAttachedCallOnce() {
        var count = 0
        var counted: Set<String> = []
        XCTAssertTrue(LiveVoiceQuickHint.shows(threadID: "a", shownCount: &count, counted: &counted))
        XCTAssertTrue(LiveVoiceQuickHint.shows(threadID: "a", shownCount: &count, counted: &counted),
                      "bringing the same call back shows it again")
        XCTAssertEqual(count, 1, "and doesn't count again")
        XCTAssertTrue(LiveVoiceQuickHint.shows(threadID: "b", shownCount: &count, counted: &counted))
        XCTAssertTrue(LiveVoiceQuickHint.shows(threadID: "a", shownCount: &count, counted: &counted))
        XCTAssertEqual(count, 2, "a chat counted earlier, between others, isn't counted again")
        XCTAssertTrue(LiveVoiceQuickHint.shows(threadID: "c", shownCount: &count, counted: &counted))
        XCTAssertFalse(LiveVoiceQuickHint.shows(threadID: "d", shownCount: &count, counted: &counted),
                       "three chats, then it's done")
        XCTAssertEqual(count, 3)
        var nextLaunch: Set<String> = []
        XCTAssertFalse(LiveVoiceQuickHint.shows(threadID: "a", shownCount: &count, counted: &nextLaunch),
                       "after a relaunch a spent hint stays hidden for every chat")
    }

    func testTheLiveCallSheetShowsEachEnginesPhase() {
        XCTAssertEqual(GeminiLiveVoiceSheet.callPhase(.idle, microphoneMuted: false), .idle)
        XCTAssertEqual(GeminiLiveVoiceSheet.callPhase(.reconnecting, microphoneMuted: false), .connecting,
                       "a reconnect looks like connecting")
        XCTAssertEqual(GeminiLiveVoiceSheet.callPhase(.listening, microphoneMuted: true), .muted)
        XCTAssertEqual(GeminiLiveVoiceSheet.callPhase(.speaking, microphoneMuted: true), .speaking,
                       "the assistant still speaks with your mic muted")
        XCTAssertEqual(GeminiLiveVoiceSheet.callPhase(.failed("x"), microphoneMuted: false), .failed)
        XCTAssertEqual(GPTLiveVoiceSheet.callPhase(.connecting, microphoneMuted: false), .connecting)
        XCTAssertEqual(GPTLiveVoiceSheet.callPhase(.listening, microphoneMuted: false), .listening)
        XCTAssertEqual(GPTLiveVoiceSheet.callPhase(.ending, microphoneMuted: false), .ending)
    }

    func testTheLiveCallOrbOnlyMovesWhileTheCallIsLive() {
        XCTAssertEqual(LiveVoiceOrb.motion(for: .muted).amplitude, 0)
        XCTAssertEqual(LiveVoiceOrb.motion(for: .failed).amplitude, 0)
        XCTAssertEqual(LiveVoiceOrb.motion(for: .idle).amplitude, 0)
        XCTAssertGreaterThan(LiveVoiceOrb.motion(for: .speaking).speed, LiveVoiceOrb.motion(for: .listening).speed,
                             "speaking pulses faster than listening")
    }

    func testTheLiquidOrbLightsUpWhileTheCallIsLiveAndSwellsWhenItSpeaks() {
        XCTAssertEqual(LiveVoiceOrb.liquidLook(for: .listening), .init(state: .listening, speech: 0))
        XCTAssertEqual(LiveVoiceOrb.liquidLook(for: .connecting).state, .listening)
        XCTAssertEqual(LiveVoiceOrb.liquidLook(for: .speaking), .init(state: .speaking, speech: 1))
        for phase in [LiveVoiceCallPhase.idle, .muted, .ending, .failed] {
            XCTAssertEqual(LiveVoiceOrb.liquidLook(for: phase), .init(state: .idle, speech: 0), "\(phase)")
        }
    }

    func testTheLiquidOrbSpeechSwellIsSilentAtZeroAndStaysInRange() {
        XCTAssertEqual(LiquidOrbAudio.speech(intensity: 0, at: 12.3), LiquidOrbAudio())
        var untouched: [Float] = Array(repeating: 0.5, count: 136)
        LiquidOrbAudio().apply(to: &untouched)
        LiquidOrbAudio().applyPulse(to: &untouched)
        XCTAssertEqual(untouched, Array(repeating: 0.5, count: 136), "silence leaves the preset alone")

        for time in stride(from: 0.0, through: 6.0, by: 0.37) {
            let bands = LiquidOrbAudio.speech(intensity: 1, at: time)
            for level in [bands.low, bands.mid, bands.high, bands.all] {
                XCTAssertGreaterThanOrEqual(level, 0)
                XCTAssertLessThanOrEqual(level, 1)
            }
            var values: [Float] = Array(repeating: 0.5, count: 136)
            bands.apply(to: &values)
            XCTAssertGreaterThanOrEqual(values[3], 0.5, "speech never slows the orb")
            XCTAssertLessThanOrEqual(values[6], 7, "warp stays under its ceiling")
        }
        var speaking: [Float] = Array(repeating: 0.5, count: 136)
        LiquidOrbAudio(all: 0.5).apply(to: &speaking)
        XCTAssertGreaterThan(speaking[3], 0.5, "speech speeds the orb up")
        LiquidOrbAudio(all: 1).applyPulse(to: &speaking)
        XCTAssertEqual(speaking[4], 0.54, accuracy: 0.0001, "the sphere swells 8% at full speech")
    }

    func testTheLiquidOrbShaderCompilesWhereMetalExists() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device on this simulator")
        }
        XCTAssertNotNil(LiquidOrbPipeline.shared, "LiquidOrb.metal builds into the app's default library")
    }

    func testTheLiveCallCaptionsAreTheLastTwoLines() {
        XCTAssertTrue(LiveVoiceCallSheet.captionLines(from: []).isEmpty)
        let lines = ["one", "two", "three"].enumerated().map {
            VoiceConversationTranscriptEntry(speaker: $0.offset.isMultiple(of: 2) ? .user : .assistant, text: $0.element)
        }
        XCTAssertEqual(LiveVoiceCallSheet.captionLines(from: lines).map(\.text), ["two", "three"])
        XCTAssertEqual(LiveVoiceCallSheet.captionLines(from: Array(lines.prefix(1))).map(\.text), ["one"])
    }

    func testTheFullEditorTellsDictationFromTyping() {
        let dictated = ComposerDictation.draft(before: "Note:", dictated: "buy milk")
        XCTAssertFalse(ComposerDictation.isTyping(dictated, dictationWrote: dictated), "dictation's own write keeps it going")
        XCTAssertTrue(ComposerDictation.isTyping(dictated + "s", dictationWrote: dictated), "a keystroke after it is typing")
        XCTAssertTrue(ComposerDictation.isTyping("Note:", dictationWrote: nil), "no dictation yet: every change is typing")
    }

    func testTheDictateButtonStartsStopsAndCallsOffAStart() {
        XCTAssertEqual(ComposerDictation.tap(isCapturing: false, isStarting: false, canDictate: true), .start)
        XCTAssertEqual(
            ComposerDictation.tap(isCapturing: false, isStarting: false, canDictate: false),
            .nothing,
            "no dictation while Voice has the microphone"
        )
        XCTAssertEqual(ComposerDictation.tap(isCapturing: true, isStarting: false, canDictate: true), .stop)
        XCTAssertEqual(
            ComposerDictation.tap(isCapturing: true, isStarting: false, canDictate: false),
            .stop,
            "a running dictation can always be stopped"
        )
        XCTAssertEqual(
            ComposerDictation.tap(isCapturing: false, isStarting: true, canDictate: true),
            .cancelStart,
            "a second tap before the microphone came up calls it off"
        )
    }

    func testADictationCancelledBeforeItsStartRunsNeverStarts() async throws {
        let dictation = ComposerDictationService()
        var finished = false
        let token = try XCTUnwrap(dictation.reserveStart())
        dictation.onFinish = { _ in finished = true }
        XCTAssertNil(dictation.reserveStart(), "one start at a time")

        // The composer went away before the start task ran.
        dictation.cancel()
        try await dictation.start(token: token)

        XCTAssertFalse(dictation.isDictating)
        XCTAssertFalse(dictation.isStarting)
        XCTAssertNil(dictation.onFinish, "callbacks don't outlive a cancelled start")
        XCTAssertFalse(finished)
        XCTAssertNotNil(dictation.reserveStart(), "a later tap can start again")
        dictation.cancel()
    }

    func testVoiceInUseFollowsAnOpenVoiceSheet() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VoiceInUse.\(UUID().uuidString)"))
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        XCTAssertFalse(appState.isVoiceInUse)
        appState.showVoiceSheet = true
        XCTAssertTrue(appState.isVoiceInUse, "dictation never competes with Voice for the microphone")
    }

    /// A sendable draft or a live turn always owns the slot, so Send, Stop,
    /// Steer and Interrupt are never hidden behind the mic.
    func testSendableOrRunningStatesTakeTheTrailingSlot() {
        for action in [ComposerAction.send, .stop, .steer, .interrupt] {
            XCTAssertEqual(
                ComposerBar.trailingControl(action: action, showsVoiceButton: true),
                .action,
                "\(action) must not be replaced by the mic"
            )
        }
    }

    private var readySnapshot: VoiceCapabilitySnapshot {
        VoiceCapabilitySnapshot(
            isGatewayConnected: true,
            supportsTranscription: true,
            supportsSpeech: true,
            unavailableReason: nil
        )
    }

    private func makeAppState(
        snapshot: VoiceCapabilitySnapshot,
        transcriptionMode: VoiceTranscriptionMode = .hermes,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability = .ready(localeIdentifier: "en-US"),
        isVoiceEnabled: Bool = true
    ) -> AppState {
        let suite = "AppStateVoiceCapabilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: snapshot,
            isVoiceEnabled: isVoiceEnabled,
            transcriptionMode: transcriptionMode,
            appleSpeechAvailability: appleSpeechAvailability
        )
        return appState
    }
}
