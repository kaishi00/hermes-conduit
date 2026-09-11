//
//  AppStateContinuousConversationPreferenceTests.swift
//  Conduit
//
//  Persistence and profile scoping for VoiceProfilePreferences.continuousConversation.
//

import XCTest
@testable import Conduit

@MainActor
final class AppStateContinuousConversationPreferenceTests: XCTestCase {
    func testSetContinuousConversationPersistsWithoutClobberingUnrelatedFields() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        var seed = VoiceProfilePreferences()
        seed.outputMuted = true
        seed.continuousConversation = true
        seed.continueWakeConversation = true
        seed.spokenStopPhrases = ["halt", "quiet"]
        seed.transcriptionMode = .appleOnDevice
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        appState.setContinuousConversation(false)

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertFalse(loaded.continuousConversation)
        XCTAssertTrue(loaded.outputMuted)
        XCTAssertTrue(loaded.continueWakeConversation)
        XCTAssertEqual(loaded.spokenStopPhrases, ["halt", "quiet"])
        XCTAssertEqual(loaded.resolvedTranscriptionMode, .appleOnDevice)
        XCTAssertFalse(appState.continuousConversationEnabled)
    }

    func testSetContinuousConversationIsProfileScoped() throws {
        let (appState, defaults, suite) = makeAppState(profile: "alpha")
        defer { defaults.removePersistentDomain(forName: suite) }

        var alpha = VoiceProfilePreferences()
        alpha.continuousConversation = true
        alpha.spokenStopPhrases = ["alpha-stop"]
        savePreferences(alpha, defaults: defaults, profile: "alpha", gateway: "https://example.com")

        var beta = VoiceProfilePreferences()
        beta.continuousConversation = false
        beta.spokenStopPhrases = ["beta-stop"]
        savePreferences(beta, defaults: defaults, profile: "beta", gateway: "https://example.com")

        XCTAssertEqual(appState.activeProfile, "alpha")
        appState.setContinuousConversation(false)

        let loadedAlpha = try loadPreferences(defaults: defaults, profile: "alpha", gateway: "https://example.com")
        let loadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertFalse(loadedAlpha.continuousConversation)
        XCTAssertEqual(loadedAlpha.spokenStopPhrases, ["alpha-stop"])
        XCTAssertFalse(loadedBeta.continuousConversation)
        XCTAssertEqual(loadedBeta.spokenStopPhrases, ["beta-stop"])

        // Switching the active profile identity and writing again must not
        // leak into the previous profile's blob.
        appState.setActiveProfileForTesting("beta")
        appState.setContinuousConversation(true)
        let reloadedAlpha = try loadPreferences(defaults: defaults, profile: "alpha", gateway: "https://example.com")
        let reloadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertFalse(reloadedAlpha.continuousConversation)
        XCTAssertTrue(reloadedBeta.continuousConversation)
    }

    func testRefreshVoiceCapabilitiesLoadsProfileContinuousConversation() async throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        var seed = VoiceProfilePreferences()
        seed.continuousConversation = false
        seed.spokenStopPhrases = ["keep"]
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        await appState.refreshVoiceCapabilities()

        XCTAssertFalse(appState.continuousConversationEnabled)
        XCTAssertFalse(appState.voiceConversationController.isContinuousConversationEnabled)
    }

    func testSetContinuousConversationPreservesLiveMuteOverStalePersistedUnmuted() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        // Persisted blob still says unmuted (mute is written on sheet close).
        var seed = VoiceProfilePreferences()
        seed.outputMuted = false
        seed.continuousConversation = true
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        // Live Voice session muted in memory only.
        appState.voiceConversationController.beginVoiceTurn(sessionID: "live-session")
        appState.voiceConversationController.setOutputMuted(true)
        XCTAssertTrue(appState.voiceConversationController.hasLiveVoiceSession)
        XCTAssertTrue(appState.voiceConversationController.isOutputMuted)

        XCTAssertTrue(appState.setContinuousConversation(false))

        XCTAssertTrue(appState.voiceConversationController.isOutputMuted, "toggling continuous conversation must not unmute a live session")
        XCTAssertFalse(appState.continuousConversationEnabled)
        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertTrue(loaded.outputMuted, "live mute is persisted so the reapplied blob cannot regress")
        XCTAssertFalse(loaded.continuousConversation)
    }

    func testSetContinuousConversationDoesNotCopyStaleControllerMuteWithoutLiveSession() throws {
        let (appState, defaults, suite) = makeAppState(profile: "beta")
        defer { defaults.removePersistentDomain(forName: suite) }

        var alpha = VoiceProfilePreferences()
        alpha.outputMuted = true
        alpha.continuousConversation = true
        savePreferences(alpha, defaults: defaults, profile: "alpha", gateway: "https://example.com")

        var beta = VoiceProfilePreferences()
        beta.outputMuted = false
        beta.continuousConversation = true
        savePreferences(beta, defaults: defaults, profile: "beta", gateway: "https://example.com")

        // Controller still holds profile A's mute after a profile switch
        // before refreshVoiceCapabilities has resynced it. No live session.
        appState.voiceConversationController.setProfilePreferences(alpha)
        appState.voiceConversationController.setOutputMuted(true)
        XCTAssertFalse(appState.voiceConversationController.hasLiveVoiceSession)
        XCTAssertEqual(appState.activeProfile, "beta")

        XCTAssertTrue(appState.setContinuousConversation(false))

        let loadedAlpha = try loadPreferences(defaults: defaults, profile: "alpha", gateway: "https://example.com")
        let loadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertTrue(loadedAlpha.continuousConversation)
        XCTAssertTrue(loadedAlpha.outputMuted)
        XCTAssertFalse(loadedBeta.outputMuted, "stale controller mute from profile A must not overwrite B's persisted unmuted value")
        XCTAssertFalse(loadedBeta.continuousConversation)
        XCTAssertFalse(appState.voiceConversationController.isContinuousConversationEnabled)
    }

    func testSetContinuousConversationFailsWhenDisconnected() {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }
        appState.isConnected = false

        XCTAssertFalse(appState.setContinuousConversation(false))
        XCTAssertTrue(appState.continuousConversationEnabled, "failed write must not flip the published flag")
        XCTAssertTrue(appState.voiceConversationController.isContinuousConversationEnabled, "controller keeps the previous preference")
    }

    private func makeAppState(profile: String) -> (AppState, UserDefaults, String) {
        let suite = "AppStateContinuousConversationPreferenceTests.\(UUID().uuidString)"
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
