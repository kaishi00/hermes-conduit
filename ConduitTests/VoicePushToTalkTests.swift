//
//  VoicePushToTalkTests.swift
//  Conduit
//
//  Push to talk in Classic voice (#886): hold to speak, release to send.
//  An extension of an existing class, so the test planner has no new class
//  to estimate.
//

import XCTest
@testable import Conduit

@MainActor
extension ContinuousConversationPreferenceTests {
    func testOlderPreferenceBlobDecodesPushToTalkOff() throws {
        let data = try XCTUnwrap(#"{"outputMuted":false,"continuousConversation":true}"#.data(using: .utf8))
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)
        XCTAssertNil(preferences.pushToTalk)
    }

    func testPushToTalkSilenceNeverEndsAHeldTurnAndReleaseSends() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Let me think about that")
        let submitted = SubmitSpy()
        let controller = makePushToTalkController(capture: capture, gateway: gateway, submitted: submitted)

        await controller.beginPushToTalk()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.isPushToTalkHeld)
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        // A pause well past the trailing silence, then past idle silence.
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(3))
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(13))
        await drainPendingMainActorWork()
        XCTAssertEqual(controller.state, .listening, "silence never ends a held turn")
        XCTAssertEqual(gateway.transcriptionCount, 0)
        XCTAssertFalse(controller.isMicrophonePaused)

        controller.endPushToTalk(send: true)
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["Let me think about that"])
        XCTAssertFalse(controller.isPushToTalkHeld)
    }

    func testPushToTalkSlideAwayCancelsWithoutSending() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Never mind")
        let submitted = SubmitSpy()
        let controller = makePushToTalkController(capture: capture, gateway: gateway, submitted: submitted)

        await controller.beginPushToTalk()
        controller.ingestAudioLevel(0.1, at: Date())
        controller.endPushToTalk(send: false)
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(gateway.transcriptionCount, 0, "a cancelled turn is never transcribed")
        XCTAssertEqual(submitted.count, 0)
        XCTAssertTrue(capture.didPause, "the microphone stops until the next press")
        XCTAssertTrue(controller.hasLiveVoiceSession, "the conversation stays open")
    }

    func testPushToTalkTapIsTooShortToSend() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Hi")
        let submitted = SubmitSpy()
        let controller = makePushToTalkController(
            capture: capture, gateway: gateway, submitted: submitted, minimumHold: 0.3
        )

        await controller.beginPushToTalk()
        controller.endPushToTalk(send: true)
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(submitted.count, 0)
    }

    func testPushToTalkOpeningTheVoiceScreenWaitsForAPress() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = makePushToTalkController(capture: capture, gateway: MockGateway(), submitted: SubmitSpy())

        await controller.startListening()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 0, "only a press opens the microphone")
    }

    func testPushToTalkDoesNotListenAgainAfterAReply() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let submitted = SubmitSpy()
        let controller = makePushToTalkController(
            capture: capture, gateway: gateway, submitted: submitted, continuous: true
        )

        await pushToTalkToSpeaking(controller, submitted: submitted)
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Answer."))
        let settled = await controller.waitForState(.idle)

        XCTAssertTrue(settled, "the next turn waits for a press, even with Continuous Conversation on")
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertFalse(controller.isMicrophonePaused, "waiting for a press is not a user pause")
    }

    func testPushToTalkPressWhileHermesSpeaksStopsTheReplyAndListens() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let submitted = SubmitSpy()
        let interrupts = AwaitableCounter()
        let controller = makePushToTalkController(
            capture: capture, gateway: gateway, submitted: submitted, interrupts: interrupts
        )
        await pushToTalkToSpeaking(controller, submitted: submitted)

        await controller.beginPushToTalk()

        XCTAssertEqual(interrupts.value, 1, "the running reply is cancelled")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.isPushToTalkHeld)
        XCTAssertEqual(capture.startCount, 2)
    }

    func testPushToTalkSpeechOverAReplyDoesNotTalkOverIt() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let submitted = SubmitSpy()
        let interrupts = AwaitableCounter()
        let controller = makePushToTalkController(
            capture: capture, gateway: gateway, submitted: submitted, interrupts: interrupts
        )
        await pushToTalkToSpeaking(controller, submitted: submitted)

        let speech = Date()
        controller.ingestAudioLevel(0.5, at: speech)
        controller.ingestAudioLevel(0.5, at: speech.addingTimeInterval(0.31))
        controller.ingestAudioLevel(0.5, at: speech.addingTimeInterval(0.62))
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.state, .speaking, "only a press interrupts")
        XCTAssertEqual(interrupts.value, 0)
        XCTAssertNil(controller.lastBargeInState)
    }

    func testPushToTalkPressWhileHermesThinksSteersTheTurn() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question")
        let submitted = SubmitSpy()
        let steers = SubmitSpy()
        let controller = makePushToTalkController(
            capture: capture, gateway: gateway, submitted: submitted, steers: steers
        )
        await pushToTalkTurn(controller, submitted: submitted, count: 1)
        controller.receiveAssistantEvent(.started(sessionID: "session"))

        gateway.transcript = "Use the staging server"
        await controller.beginPushToTalk()
        XCTAssertTrue(controller.isSteeringTurn)
        XCTAssertEqual(controller.state, .listening)
        controller.ingestAudioLevel(0.1, at: Date())
        controller.endPushToTalk(send: true)
        await steers.waitUntilSubmitted(1)
        let thinking = await controller.waitForState(.thinking)

        XCTAssertTrue(thinking, "back to waiting on the same turn")
        XCTAssertEqual(steers.texts, ["Use the staging server"])
        XCTAssertEqual(submitted.texts, ["Question"], "a steer is not a new turn")
    }

    func testPushToTalkAnApprovalIsSaidThenAPressAnswersIt() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let submitted = SubmitSpy()
        let steers = SubmitSpy()
        let interrupts = AwaitableCounter()
        let controller = makePushToTalkController(
            capture: capture, gateway: gateway, submitted: submitted, steers: steers, interrupts: interrupts
        )
        await pushToTalkTurn(controller, submitted: submitted, count: 1)
        controller.receiveAssistantEvent(.started(sessionID: "session"))

        controller.noteApprovalWaiting(sessionID: "session", request: "req-1",
                                       line: "Hermes needs your OK to go on: delete the logs.",
                                       stillWaiting: { true })
        await gateway.waitUntilSpeechStreamOpened(1)
        let thinking = await controller.waitForState(.thinking)
        XCTAssertTrue(thinking, "push to talk waits for a press to answer")
        XCTAssertFalse(controller.isSteeringTurn)

        gateway.transcript = "Yes"
        await controller.beginPushToTalk()
        XCTAssertTrue(controller.isSteeringTurn)
        controller.ingestAudioLevel(0.1, at: Date())
        controller.endPushToTalk(send: true)
        await steers.waitUntilSubmitted(1)

        XCTAssertEqual(steers.texts, ["Yes"])
        XCTAssertEqual(interrupts.value, 0, "the turn waiting on the approval goes on")
    }

    func testPushToTalkStaysHandsFreeWhereTheButtonIsNotShown() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "From the car")
        let submitted = SubmitSpy()
        let controller = makePushToTalkController(
            capture: capture, gateway: gateway, submitted: submitted, surfaceAvailable: false
        )

        XCTAssertFalse(controller.isPushToTalkActive)
        await controller.startListening()
        XCTAssertEqual(controller.state, .listening)
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["From the car"], "a pause ends the turn, as without push to talk")
    }

    func testVoiceOverSendIsNotHeldToTheMinimumHold() async {
        let capture = MockCapture(permissionGranted: true)
        let submitted = SubmitSpy()
        let controller = makePushToTalkController(
            capture: capture, gateway: MockGateway(transcript: "Quick one"), submitted: submitted, minimumHold: 0.3
        )

        await controller.beginPushToTalk()
        controller.ingestAudioLevel(0.1, at: Date())
        controller.endPushToTalk(send: true, minimumHold: false)
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["Quick one"], "a second double-tap is a deliberate send")
    }

    func testPushToTalkReleaseBeforeTheWindowOpensLeavesNothingListening() async {
        let capture = MockCapture(permissionGranted: true)
        let submitted = SubmitSpy()
        let controller = makePushToTalkController(capture: capture, gateway: MockGateway(), submitted: submitted)

        // The button's press returns at once; the release can land before
        // the window opens.
        XCTAssertTrue(controller.pressPushToTalk())
        controller.endPushToTalk(send: true)
        await drainPendingMainActorWork()

        XCTAssertEqual(controller.state, .idle, "no window is left open with no finger down")
        XCTAssertFalse(controller.isPushToTalkHeld)
        XCTAssertEqual(submitted.count, 0)
    }

    func testPushToTalkLengthCapSendsAndTheHoldEndsWithTheFinger() async {
        let capture = MockCapture(permissionGranted: true)
        let submitted = SubmitSpy()
        let controller = makePushToTalkController(
            capture: capture, gateway: MockGateway(transcript: "A long story"), submitted: submitted
        )

        await controller.beginPushToTalk()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0.1, at: start.addingTimeInterval(181))
        await submitted.waitUntilSubmitted(1)

        XCTAssertEqual(submitted.texts, ["A long story"])
        XCTAssertTrue(controller.isPushToTalkHeld, "still held until the finger lifts")
        controller.endPushToTalk(send: true)
        XCTAssertFalse(controller.isPushToTalkHeld)
        XCTAssertEqual(submitted.count, 1, "the release after the cap sends nothing more")
    }

    func testPushToTalkPressWhileHermesWorksWithNothingToSteerWaits() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question")
        let submitted = SubmitSpy()
        // No steer seam: a press while Hermes works has nothing to do.
        let controller = makePushToTalkController(capture: capture, gateway: gateway, submitted: submitted)
        await pushToTalkTurn(controller, submitted: submitted, count: 1)

        XCTAssertFalse(controller.canPushToTalkNow)
        XCTAssertFalse(controller.pressPushToTalk())
        XCTAssertFalse(controller.isPushToTalkHeld)
        XCTAssertEqual(controller.state, .thinking)
    }

    // MARK: Helpers

    private func makePushToTalkController(
        capture: MockCapture,
        gateway: MockGateway,
        submitted: SubmitSpy,
        steers: SubmitSpy? = nil,
        interrupts: AwaitableCounter? = nil,
        continuous: Bool = true,
        minimumHold: TimeInterval = 0,
        surfaceAvailable: Bool = true
    ) -> VoiceConversationController {
        var configuration = VoiceConversationController.Configuration()
        configuration.pushToTalkMinimumHold = minimumHold
        let policy = RoutePolicyBox(.fullDuplex)
        var steer: (@MainActor (String) async -> VoiceSteerOutcome)?
        if let steers {
            steer = { text in await steers.submit(text) ? .steered : .failed }
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            configuration: configuration,
            routePolicyProvider: { policy.policy },
            submit: { await submitted.submit($0) },
            interrupt: { interrupts?.increment(); return true },
            steer: steer,
            pushToTalkSurfaceAvailable: { surfaceAvailable }
        )
        var preferences = VoiceProfilePreferences()
        preferences.continuousConversation = continuous
        preferences.pushToTalk = true
        controller.setProfilePreferences(preferences)
        controller.beginVoiceTurn(sessionID: "session")
        return controller
    }

    /// Press, a word, release: the turn is submitted and Hermes works on it.
    private func pushToTalkTurn(_ controller: VoiceConversationController, submitted: SubmitSpy, count: Int) async {
        await controller.beginPushToTalk()
        controller.ingestAudioLevel(0.1, at: Date())
        controller.endPushToTalk(send: true)
        await submitted.waitUntilSubmitted(count)
        await drainPendingMainActorWork()
        let thinking = await controller.waitForState(.thinking)
        XCTAssertTrue(thinking)
    }

    private func pushToTalkToSpeaking(_ controller: VoiceConversationController, submitted: SubmitSpy) async {
        await pushToTalkTurn(controller, submitted: submitted, count: 1)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer."))
        let speaking = await controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the reply is audible")
    }
}
