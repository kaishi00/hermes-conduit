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
            "Allow Speech Recognition in iOS Settings to use on-device transcription."
        )
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

    // MARK: - Shared mic/send trailing slot (#194)

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
