import XCTest
@testable import Conduit

/// Switching voice mode from a call screen: saved as Settings saves it, and
/// the call starts again in the new mode, in the same chat.
@MainActor
extension AppStateVoiceCapabilityTests {
    private func makeModeSwitchAppState() -> AppState {
        let suite = "VoiceModeSwitch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(isGatewayConnected: true, supportsTranscription: false, supportsSpeech: false, unavailableReason: "No STT"),
            isVoiceEnabled: false,
            transcriptionMode: .hermes,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US")
        )
        return appState
    }

    private func installModeSwitchFakeGPTLive(in appState: AppState) -> (GPTLiveConversationController, FakeGPTLiveSessionControl) {
        let session = FakeGPTLiveSessionControl()
        let client = FakeGPTLiveClient()
        let controller = GPTLiveConversationController(
            makeSession: { session },
            availability: { try await client.availability() },
            briefing: { "[rules]" },
            supervisor: appState.voiceBackgroundJobSupervisor,
            requestPermission: { true }
        )
        _ = appState.gptLiveController
        appState.gptLiveController = controller
        return (controller, session)
    }

    @discardableResult
    private func installModeSwitchFakeGeminiLive(in appState: AppState) -> FakeGeminiLiveSessionControl {
        let session = FakeGeminiLiveSessionControl()
        let tokens = FakeGeminiLiveTokens()
        let controller = GeminiLiveConversationController(
            makeSession: { session },
            availability: { try await tokens.availability() },
            tools: GeminiLiveToolBridge(supervisor: appState.voiceBackgroundJobSupervisor),
            input: FakeGeminiLiveInput(),
            output: FakeGeminiLiveOutput(),
            routePolicy: { .fullDuplex }
        )
        _ = appState.geminiLiveController
        appState.geminiLiveController = controller
        return session
    }

    func testVoiceModeChoiceNamesEachEngine() {
        for choice in VoiceModeChoice.allCases {
            XCTAssertEqual(VoiceModeChoice(engine: choice.engine), choice)
        }
        XCTAssertNil(VoiceModeChoice.classic.engine)
        XCTAssertEqual(VoiceModeChoice(engine: .localLive, localAgent: false), .classic,
                       "Local Live outside agent mode is Classic's hands-free option, as Settings lists it")
    }

    func testAHandsFreeLocalCallCanMoveToClassic() {
        let appState = makeModeSwitchAppState()
        appState.setLocalLiveEnabled(true)
        appState.setLocalLiveAgent(false)

        let handsFree = appState.voiceModeSwitch(for: .localLive)
        XCTAssertEqual(handsFree.current, .classic, "listed as Settings lists it")
        XCTAssertTrue(handsFree.moves(to: .classic), "the call isn't classic voice yet")

        let classic = appState.voiceModeSwitch(for: nil)
        XCTAssertFalse(classic.moves(to: .classic), "a classic call stays as it is")
        XCTAssertTrue(classic.moves(to: .gpt))
    }

    func testApplyingAVoiceModeSavesItAsSettingsDoes() {
        let appState = makeModeSwitchAppState()

        appState.applyVoiceMode(.gpt)
        XCTAssertEqual(appState.configuredLiveVoiceEngine(profile: appState.activeProfile), .gptLive)

        appState.applyVoiceMode(.gemini)
        XCTAssertTrue(appState.isGeminiLiveEnabled)
        XCTAssertFalse(appState.isGPTLiveEnabled, "one live mode per profile")

        appState.applyVoiceMode(.local)
        XCTAssertTrue(appState.isLocalLiveEnabled)
        XCTAssertTrue(appState.isLocalLiveAgent, "Local is agent mode, as Settings picks it")
        XCTAssertFalse(appState.isGeminiLiveEnabled)

        appState.applyVoiceMode(.classic)
        XCTAssertNil(appState.configuredLiveVoiceEngine(profile: appState.activeProfile))
    }

    func testSwitchingACallsModeStartsTheNewModeInTheSameChat() async {
        let appState = makeModeSwitchAppState()
        appState.setGPTLiveEnabled(true)
        let (gptController, gptSession) = installModeSwitchFakeGPTLive(in: appState)
        installModeSwitchFakeGeminiLive(in: appState)
        let thread = VoiceThreadTarget(runtimeSessionID: "runtime-1", storedSessionID: "stored-1", title: "Marketing")
        appState.voiceBackgroundJobSupervisor.attachLiveThread(thread)
        appState.showGPTLiveSheet = true
        await gptController.start()
        gptSession.becomeReady()
        XCTAssertTrue(gptController.isActive)
        XCTAssertEqual(appState.voiceModeSwitch(for: .gptLive).current, .gpt)

        await appState.switchVoiceMode(to: .gemini)

        XCTAssertFalse(gptController.isActive, "the GPT-Live call hangs up")
        XCTAssertFalse(appState.showGPTLiveSheet)
        XCTAssertTrue(appState.showGeminiLiveSheet, "the new mode's call screen opens")
        XCTAssertTrue(appState.isGeminiLiveEnabled, "saved as the profile's mode")
        XCTAssertFalse(appState.isGPTLiveEnabled)
        XCTAssertEqual(appState.voiceBackgroundJobSupervisor.liveThread, thread, "the new call works in the same chat")

        // The old screen's dismissal lands after the new one is up: it
        // must not let go of the new call's chat.
        appState.liveVoiceSheetDismissed(.gptLive)
        XCTAssertEqual(appState.voiceBackgroundJobSupervisor.liveThread, thread)
        XCTAssertTrue(appState.showGeminiLiveSheet)
        XCTAssertNil(appState.minimisedLiveVoice)

        appState.closeGeminiLiveConversation()
    }

    func testSwitchingWhileDisconnectedSavesTheModeAndSaysWhyNothingStarted() async {
        let appState = makeModeSwitchAppState()
        appState.isConnected = false

        await appState.switchVoiceMode(to: .grok)

        XCTAssertTrue(appState.isGrokLiveEnabled, "the pick is still saved")
        XCTAssertFalse(appState.showGrokLiveSheet)
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("Reconnect to Hermes to start voice."))
    }

    /// Waits until `condition` holds, failing after a few seconds.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testTheOldScreensDismissalDoesNotTouchANewCallOnTheSameEngine() async {
        // A hands-free Local Live call moving to Local restarts the same
        // engine; GPT-Live stands in for it here, with fakes.
        let appState = makeModeSwitchAppState()
        appState.setGPTLiveEnabled(true)
        let (gptController, gptSession) = installModeSwitchFakeGPTLive(in: appState)
        let thread = VoiceThreadTarget(runtimeSessionID: "runtime-2", storedSessionID: "stored-2", title: "Trip")
        appState.voiceBackgroundJobSupervisor.attachLiveThread(thread)
        appState.showGPTLiveSheet = true
        await gptController.start()
        gptSession.becomeReady()

        let switching = Task { await appState.switchVoiceMode(to: .gpt) }
        await waitUntil { appState.voiceModeSwitchDismissing == .gptLive }
        // The old screen's dismissal lands while the switch waits for it.
        appState.liveVoiceSheetDismissed(.gptLive)
        await switching.value

        XCTAssertNil(appState.voiceModeSwitchDismissing)
        XCTAssertTrue(appState.showGPTLiveSheet, "the new call's screen is up")
        XCTAssertNil(appState.minimisedLiveVoice, "and not minimised by the old one going")
        XCTAssertEqual(appState.voiceBackgroundJobSupervisor.liveThread, thread)

        appState.closeGPTLiveConversation()
    }
}
