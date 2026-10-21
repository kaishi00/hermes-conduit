//
//  LiveVoiceProviderConsentTests.swift
//  Conduit
//
//  #827 (App Review 5.1.2(i)): no live call reaches Google, OpenAI or xAI
//  until the user has allowed that provider to hear them. An extension of
//  an existing suite: the CI test planner is at capacity for new classes.
//

import XCTest
@testable import Conduit

extension VoiceConversationControllerTests {
    private func consentDefaults() throws -> (UserDefaults, String) {
        let suite = "LiveVoiceProviderConsentTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testLiveVoiceConsentIsKeptPerProviderAndLocalLiveNeverAsks() throws {
        let (defaults, suite) = try consentDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for mode in [LiveVoiceModeName.geminiLive, .gptLive, .grokLive] {
            XCTAssertFalse(LiveVoiceProviderConsent.isGranted(mode, defaults: defaults), "\(mode) asks first")
            XCTAssertEqual(LiveVoiceProviderConsent.missing(mode, defaults: defaults), mode)
        }
        // Local Live stays with the user's own Hermes host.
        XCTAssertTrue(LiveVoiceProviderConsent.isGranted(.localLive, defaults: defaults))
        XCTAssertNil(LiveVoiceProviderConsent.missing(.localLive, defaults: defaults))

        LiveVoiceProviderConsent.setGranted(true, for: .geminiLive, defaults: defaults)
        XCTAssertTrue(LiveVoiceProviderConsent.isGranted(.geminiLive, defaults: defaults))
        XCTAssertFalse(LiveVoiceProviderConsent.isGranted(.gptLive, defaults: defaults), "switching provider asks again")
        XCTAssertFalse(LiveVoiceProviderConsent.isGranted(.grokLive, defaults: defaults))

        LiveVoiceProviderConsent.setGranted(false, for: .geminiLive, defaults: defaults)
        XCTAssertFalse(LiveVoiceProviderConsent.isGranted(.geminiLive, defaults: defaults), "taken back")
    }

    func testGeminiLiveNeverReachesTheProviderWithoutConsent() async {
        var missing: LiveVoiceModeName? = .geminiLive
        var checkedHost = 0
        let session = FakeGeminiLiveSessionControl()
        let input = FakeGeminiLiveInput()
        let supervisor = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
        let controller = GeminiLiveConversationController(
            makeSession: { session },
            availability: {
                checkedHost += 1
                return .available(model: "gemini-3.8-live")
            },
            missingConsent: { missing },
            tools: GeminiLiveToolBridge(supervisor: supervisor),
            input: input,
            output: FakeGeminiLiveOutput(),
            headsetMute: HeadsetMicrophoneMute(system: FakeSystemInputMute())
        )

        await controller.start()

        XCTAssertEqual(controller.awaitingConsent, .geminiLive)
        XCTAssertEqual(controller.phase, .failed(VoiceSetupIssue.providerConsentNeeded(.geminiLive).message))
        XCTAssertEqual(session.started, 0, "no connection to Google")
        XCTAssertEqual(checkedHost, 0, "nor a credential from the host")
        XCTAssertFalse(controller.isActive)

        // Allow, then the call screen's retry.
        missing = nil
        await controller.start()

        XCTAssertNil(controller.awaitingConsent)
        XCTAssertEqual(session.started, 1)
        XCTAssertEqual(checkedHost, 1)
        controller.stop()
    }

    func testGPTLiveNeverReachesTheProviderWithoutConsent() async {
        var missing: LiveVoiceModeName? = .gptLive
        let client = FakeGPTLiveClient()
        let session = FakeGPTLiveSessionControl()
        let supervisor = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
        let controller = GPTLiveConversationController(
            makeSession: { session },
            availability: { try await client.availability() },
            missingConsent: { missing },
            briefing: { "[rules]" },
            supervisor: supervisor,
            requestPermission: { true },
            headsetMute: HeadsetMicrophoneMute(system: FakeSystemInputMute())
        )

        await controller.start()

        XCTAssertEqual(controller.awaitingConsent, .gptLive)
        XCTAssertEqual(controller.phase, .failed(VoiceSetupIssue.providerConsentNeeded(.gptLive).message))
        XCTAssertEqual(session.started, 0, "no call to OpenAI")

        missing = nil
        await controller.start()

        XCTAssertNil(controller.awaitingConsent)
        XCTAssertEqual(session.started, 1)
        controller.stop()
    }

    func testCarPlayNamesTheMissingConsentOverTheHost() {
        let issue = VoiceSetupIssue.providerConsentNeeded(.grokLive)
        XCTAssertTrue(issue.message.contains("Grok Live"))
        XCTAssertTrue(issue.message.contains("xAI"))
        XCTAssertEqual(issue.carPlayTitleVariants.count, 2)
        XCTAssertTrue(issue.carPlayTitleVariants[0].contains("Grok Live"))
    }
}
