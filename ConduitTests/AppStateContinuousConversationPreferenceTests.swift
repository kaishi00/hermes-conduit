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
