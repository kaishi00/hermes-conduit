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

    private func makeAppState(
        snapshot: VoiceCapabilitySnapshot,
        transcriptionMode: VoiceTranscriptionMode = .hermes,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability = .ready(localeIdentifier: "en-US")
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
            isVoiceEnabled: true,
            transcriptionMode: transcriptionMode,
            appleSpeechAvailability: appleSpeechAvailability
        )
        return appState
    }
}
