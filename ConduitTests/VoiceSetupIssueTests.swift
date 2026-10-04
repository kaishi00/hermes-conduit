//
//  VoiceSetupIssueTests.swift
//  Conduit
//
//  Voice failures name what to fix and where: the cause AppState and the
//  live controllers report, the CarPlay Error title built from it (a bare
//  "Voice unavailable" read as CarPlay not working), and the phone's
//  messages.
//

import CarPlay
import XCTest
@testable import Conduit

// An extension of an existing suite rather than a new class: the hosted
// CI plan caps the classes each unit lane runs.
extension CarPlayVoiceCoordinatorTests {
    private static let setupIssueCases: [VoiceSetupIssue] = [
        .notConnected,
        .voiceOff,
        .microphoneDenied,
        .speechRecognitionDenied,
        .speechRecognitionUnsupported(locale: "xx-XX"),
        .noSpeechToText(detail: nil),
        .noTextToSpeech,
        .liveModeNotSetUp(.geminiLive),
        .liveModeNotSetUp(.gptLive),
        .liveModeNotSetUp(.grokLive),
        .notifierPluginMissing,
    ]

    // MARK: - Titles and messages

    func testCarPlayTitlesAreShortAndLongestFirst() {
        for issue in Self.setupIssueCases {
            let titles = issue.carPlayTitleVariants
            XCTAssertFalse(titles.isEmpty, "\(issue)")
            for title in titles {
                XCTAssertLessThan(title.count, 40, "\(issue): \(title)")
            }
            XCTAssertEqual(titles, titles.sorted { $0.count > $1.count }, "CarPlay picks the longest that fits")
        }
    }

    func testVoiceOffSaysWhereToTurnItOn() {
        XCTAssertEqual(VoiceSetupIssue.voiceOff.carPlayTitleVariants.first, "Voice is off: Conduit Settings > Voice")
        XCTAssertTrue(VoiceSetupIssue.voiceOff.message.contains("Settings > Voice"))
        XCTAssertTrue(VoiceSetupIssue.noTextToSpeech.message.contains("Settings > Voice"))
        XCTAssertTrue(VoiceSetupIssue.noSpeechToText(detail: nil).message.contains("Settings > Voice"))
        XCTAssertTrue(VoiceSetupIssue.microphoneDenied.message.contains("iPhone Settings > Conduit"))
    }

    func testOnlyTheErrorStateTakesTheIssueTitle() {
        XCTAssertEqual(
            CarPlayVoiceState.error.titleVariants(errorIssue: .voiceOff),
            VoiceSetupIssue.voiceOff.carPlayTitleVariants
        )
        XCTAssertEqual(CarPlayVoiceState.error.titleVariants(errorIssue: nil), CarPlayVoiceState.error.titleVariants)
        XCTAssertEqual(CarPlayVoiceState.ready.titleVariants(errorIssue: .voiceOff), ["Ready"])
    }

    func testTemplateErrorStateNamesTheIssue() {
        var controls = CarPlayVoiceControls.initial
        controls.errorIssue = .microphoneDenied
        let template = CarPlayVoiceTemplateFactory.makeTemplate(
            controls: controls,
            handlers: CarPlayVoiceActionHandlers(startListening: {}, endConversation: {})
        )
        let error = template.voiceControlStates.first { $0.identifier == CarPlayVoiceState.error.identifier }
        XCTAssertEqual(error?.titleVariants ?? [], VoiceSetupIssue.microphoneDenied.carPlayTitleVariants)
        let ready = template.voiceControlStates.first { $0.identifier == CarPlayVoiceState.ready.identifier }
        XCTAssertEqual(ready?.titleVariants ?? [], ["Ready"])
    }

    func testLiveHostIssuesFromAvailabilityAndThrownErrors() {
        XCTAssertNil(LiveVoiceHostIssue(GeminiLiveAvailability.available(model: "m")))
        XCTAssertEqual(LiveVoiceHostIssue(GeminiLiveAvailability.pluginMissing), .pluginMissing)
        XCTAssertEqual(LiveVoiceHostIssue(GeminiLiveAvailability.unavailable(reason: "no_api_key")), .notSetUp)
        XCTAssertEqual(LiveVoiceHostIssue(GPTLiveAvailability.unavailable(reason: nil)), .notSetUp)
        XCTAssertEqual(
            LiveVoiceHostIssue(error: GrokLiveClientError.unavailable(.unavailable(reason: "no sign-in"))),
            .notSetUp
        )
        XCTAssertEqual(LiveVoiceHostIssue(error: GeminiLiveTokenError.unavailable(.pluginMissing)), .pluginMissing)
        XCTAssertNil(LiveVoiceHostIssue(error: GrokLiveClientError.socketUnavailable), "not a setup problem")
    }

    // MARK: - Causes

    func testCausesInPriorityOrder() {
        let harness = makeSetupIssueHarness()
        let appState = harness.appState
        XCTAssertNil(CarPlayVoiceCoordinator.setupIssue(in: appState, mode: .classic, isMicrophoneDenied: false))
        XCTAssertEqual(
            CarPlayVoiceCoordinator.setupIssue(in: appState, mode: .classic, isMicrophoneDenied: true),
            .microphoneDenied
        )

        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: false,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )
        XCTAssertEqual(appState.voiceSetupIssue, .noTextToSpeech)

        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: false
        )
        XCTAssertEqual(appState.voiceSetupIssue, .voiceOff)
        XCTAssertEqual(appState.voiceUnavailableReason, VoiceSetupIssue.voiceOff.message)
        XCTAssertEqual(
            CarPlayVoiceCoordinator.setupIssue(in: appState, mode: .classic, isMicrophoneDenied: true),
            .voiceOff,
            "Voice off comes first: iOS never asked for the microphone"
        )
        XCTAssertNil(
            CarPlayVoiceCoordinator.setupIssue(in: appState, mode: .geminiLive, isMicrophoneDenied: false),
            "a live mode doesn't need classic Voice turned on"
        )
        XCTAssertEqual(
            CarPlayVoiceCoordinator.setupIssue(in: appState, mode: .geminiLive, isMicrophoneDenied: true),
            .microphoneDenied,
            "with no host issue, a live call names the denied microphone"
        )

        appState.isConnected = false
        XCTAssertEqual(
            CarPlayVoiceCoordinator.setupIssue(in: appState, mode: .classic, isMicrophoneDenied: true),
            .notConnected,
            "no connection explains everything else"
        )
    }

    // MARK: - CarPlay

    /// The App Store review: CarPlay opened with Voice never turned on and
    /// said only "Voice unavailable". It now names the setting.
    func testListenWithVoiceOffShowsWhereToTurnItOn() async throws {
        let harness = makeSetupIssueHarness()
        // The capability refresh reads the saved switch, so turn it off there.
        harness.defaults.set(false, forKey: "conduit.voice.enabled.v1.https://example.com.default")
        let suite = "VoiceSetupIssueSounds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = CarPlayPreferences(defaults: defaults)
        var played: [CarPlayEarcon] = []
        harness.coordinator.preferencesProvider = { preferences }
        harness.coordinator.earconPlayer = { played.append($0) }
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()
        let installsBefore = harness.spy.setRootTemplateCount

        await harness.coordinator.performStartListeningTurn(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()

        XCTAssertEqual(harness.coordinator.controls.errorIssue, .voiceOff)
        XCTAssertEqual(harness.spy.setRootTemplateCount, installsBefore + 1, "the new title came with a new template")
        let template = try XCTUnwrap(harness.spy.installedTemplates.last as? CPVoiceControlTemplate)
        let error = template.voiceControlStates.first { $0.identifier == CarPlayVoiceState.error.identifier }
        XCTAssertEqual(error?.titleVariants?.first, "Voice is off: Conduit Settings > Voice")
        XCTAssertEqual(harness.activations.last, .error)
        XCTAssertEqual(played, [.failed])
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)

        // The same cause again needs no new template.
        await harness.coordinator.performStartListeningTurn(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()
        XCTAssertEqual(harness.spy.setRootTemplateCount, installsBefore + 1)
        XCTAssertEqual(harness.activations.last, .error)
    }

    func testReplacedTemplateStillPlaysTheFailureSound() async throws {
        let harness = makeSetupIssueHarness()
        let suite = "VoiceSetupIssueSounds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = CarPlayPreferences(defaults: defaults)
        var played: [CarPlayEarcon] = []
        harness.coordinator.preferencesProvider = { preferences }
        harness.coordinator.earconPlayer = { played.append($0) }
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()
        harness.coordinator.handleControllerState(.listening)

        harness.coordinator.setupIssueProvider = { _, _ in .microphoneDenied }
        harness.coordinator.handleControllerState(.failed("mic"))
        XCTAssertEqual(played, [.failed])
        await harness.coordinator.waitForPresentation()

        XCTAssertEqual(harness.activations.last, .error)
        XCTAssertEqual(played, [.failed], "one sound for one failure")
    }

    func testUnknownFailureKeepsTheGenericTitle() async {
        let harness = makeSetupIssueHarness()
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()
        let installsBefore = harness.spy.setRootTemplateCount

        harness.coordinator.handleControllerState(.failed("socket closed"))

        XCTAssertNil(harness.coordinator.controls.errorIssue)
        XCTAssertEqual(harness.spy.setRootTemplateCount, installsBefore, "no new template for the generic title")
        XCTAssertEqual(harness.activations.last, .error)
    }

    private func makeSetupIssueHarness() -> CarPlayVoiceCoordinatorTests.Harness {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        return harness
    }
}
