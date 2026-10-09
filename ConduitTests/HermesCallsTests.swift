//
//  HermesCallsTests.swift
//  Conduit
//
//  Hermes calls you (#449): "call me when it's done" in a live call watches
//  one job on the host at once, held while the call goes on; a job the call
//  tells loses its watch; hang-up releases the hold or, for a job that
//  ended untold, posts Conduit's own notification. Written as extensions of
//  existing suites: the CI test planner is at capacity for new classes.
//

import XCTest
@testable import Conduit

@MainActor
final class FakeHermesCallbackBackend {
    var availability: VoiceCallbackAvailability = .available
    /// Answers for the next watches, taken in turn; none left watches with
    /// a new id.
    var watchAnswers: [HermesCallWatchAnswer] = []
    var watchError: Error?
    var holdAnswers: [Int: HermesCallHoldAnswer] = [:]
    var holdError: Error?
    /// Runs as each hold reaches the host, before it answers.
    var onHold: (@MainActor (Int) -> Void)?
    private(set) var watches: [(target: VoiceCallbackTarget, hold: Int, within: Int?)] = []
    private(set) var holds: [(id: String, seconds: Int)] = []
    private(set) var cancels: [String] = []
    private(set) var notified: [(target: VoiceCallbackTarget, kind: HermesCallRequest.Kind?)] = []

    var backend: VoiceCallbackBackend {
        VoiceCallbackBackend(
            availability: { [self] in self.availability },
            watch: { [self] target, hold, within in
                self.watches.append((target, hold, within))
                if let error = self.watchError { throw error }
                guard self.watchAnswers.isEmpty else { return self.watchAnswers.removeFirst() }
                return .watching(id: "w\(self.watches.count)")
            },
            hold: { [self] id, _, seconds in
                self.holds.append((id, seconds))
                self.onHold?(seconds)
                if let error = self.holdError { throw error }
                return self.holdAnswers[seconds] ?? .watching
            },
            cancel: { [self] id, _ in self.cancels.append(id) },
            notify: { [self] target, kind in self.notified.append((target, kind)) }
        )
    }
}

@MainActor
extension VoiceConversationControllerTests {
    private func hermesCallSupervisor(
        renew: Duration = .seconds(3_600)
    ) -> (VoiceBackgroundJobSupervisor, FakeVoiceJobBackend, FakeHermesCallbackBackend) {
        let jobs = FakeVoiceJobBackend()
        let calls = FakeHermesCallbackBackend()
        let supervisor = VoiceBackgroundJobSupervisor(backend: jobs.backend, pollInterval: .seconds(3_600), callbackRenewInterval: renew)
        supervisor.callbacks = calls.backend
        return (supervisor, jobs, calls)
    }

    /// A live call whose transcript `lines` returns.
    private func beginHermesCall(_ supervisor: VoiceBackgroundJobSupervisor, lines: @escaping () -> [VoiceConversationTranscriptEntry] = { [] }) {
        supervisor.liveCallTranscript = { lines() }
        supervisor.beginLiveCall()
    }

    private func waitForHermesCalls(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func testCallMeWatchesTheNewestJobAtOnceHeldForTheCall() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = await supervisor.performVoiceCommand(.start(instructions: "find a dinner recipe"))

        XCTAssertEqual(supervisor.requestCallback(), .marked(titles: ["find a dinner recipe"], later: .none))
        await supervisor.callbackPassesSettled()

        XCTAssertEqual(calls.watches.count, 1, "Only the newest job calls")
        XCTAssertEqual(calls.watches.first?.target.sessionIDs, ["rt-2", "st-2"])
        XCTAssertEqual(calls.watches.first?.hold, VoiceBackgroundJobSupervisor.callbackHoldSeconds)
        XCTAssertNotNil(calls.watches.first?.within, "The host skips turns that ended before the request")
        XCTAssertEqual(supervisor.jobs.map(\.callsBackWhenDone), [false, true])
    }

    func testCallMeBeforeTheWorkMarksOnlyTheNextJob() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)

        XCTAssertEqual(supervisor.requestCallback(), .marked(titles: [], later: .next))
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = await supervisor.performVoiceCommand(.start(instructions: "find a dinner recipe"))
        await supervisor.callbackPassesSettled()

        XCTAssertEqual(calls.watches.map(\.target.runtimeSessionID), ["rt-1"])
        XCTAssertEqual(supervisor.jobs.map(\.callsBackWhenDone), [true, false])
    }

    func testAllJobsCallOnlyWhenAskedAndIncludeLaterWork() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = await supervisor.performVoiceCommand(.start(instructions: "find a dinner recipe"))

        XCTAssertEqual(supervisor.requestCallback(.all), .marked(titles: ["check the router", "find a dinner recipe"], later: .all))
        _ = await supervisor.performVoiceCommand(.start(instructions: "book a table"))
        await supervisor.callbackPassesSettled()

        XCTAssertEqual(Set(calls.watches.map(\.target.runtimeSessionID)), ["rt-1", "rt-2", "rt-3"])
    }

    func testCallMeForOneJobByNumberOrIdAndNeverForAnEndedOne() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = await supervisor.performVoiceCommand(.start(instructions: "find a dinner recipe"))

        XCTAssertEqual(supervisor.requestCallback(.job(number: 1)), .marked(titles: ["check the router"], later: .none))
        XCTAssertEqual(supervisor.requestCallback(.job(number: 9)), .unknownJob)
        XCTAssertEqual(supervisor.requestCallback(.jobID(UUID())), .unknownJob)
        supervisor.observe(.messageComplete(sessionId: "rt-2", messageId: nil, content: "Pasta.", reasoning: nil))
        XCTAssertEqual(supervisor.requestCallback(.job(number: 2)), .alreadyEnded(title: "find a dinner recipe"))
        await supervisor.callbackPassesSettled()

        XCTAssertEqual(calls.watches.map(\.target.runtimeSessionID), ["rt-1"])
    }

    func testCallMeWhenHermesCantCallMarksNothing() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        calls.availability = .callsOff
        XCTAssertEqual(supervisor.requestCallback(), .noCall, "Only a live call's work calls back")
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))

        XCTAssertEqual(supervisor.requestCallback(), .unavailable(.callsOff))
        await supervisor.callbackPassesSettled()
        XCTAssertTrue(calls.watches.isEmpty)
        XCTAssertFalse(supervisor.jobs.first?.callsBackWhenDone ?? true)
    }

    func testAJobToldDuringTheCallLosesItsWatch() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()
        await supervisor.callbackPassesSettled()

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All good.", reasoning: nil))
        XCTAssertNotNil(supervisor.takePendingNotice(), "The call tells it")
        await supervisor.callbackPassesSettled()
        XCTAssertEqual(calls.cancels, ["w1"])

        await supervisor.finishCallbacks()?.value
        XCTAssertTrue(calls.notified.isEmpty, "Hermes doesn't call about what the call told")
        XCTAssertTrue(calls.holds.isEmpty)
    }

    func testTheCallRenewsTheHoldAndHangUpReleasesIt() async {
        let (supervisor, _, calls) = hermesCallSupervisor(renew: .milliseconds(20))
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()

        let renewed = await waitForHermesCalls { calls.holds.contains { $0.seconds == VoiceBackgroundJobSupervisor.callbackHoldSeconds } }
        XCTAssertTrue(renewed, "The hold is renewed while the call goes on")

        await supervisor.finishCallbacks()?.value
        XCTAssertEqual(calls.holds.last?.id, "w1")
        XCTAssertEqual(calls.holds.last?.seconds, 0, "Hang-up releases the hold")
        XCTAssertTrue(calls.notified.isEmpty, "The host calls once the job is done")
        let holdsAtHangUp = calls.holds.count
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls.holds.count, holdsAtHangUp, "Nothing renews after the call")
    }

    func testHangUpNotifiesForAJobThatEndedUntold() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()
        await supervisor.callbackPassesSettled()
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All good.", reasoning: nil))

        await supervisor.finishCallbacks()?.value

        XCTAssertEqual(calls.cancels, ["w1"])
        XCTAssertEqual(calls.notified.map(\.target.runtimeSessionID), ["rt-1"])
        XCTAssertEqual(calls.notified.first?.kind, .done)
        XCTAssertNil(supervisor.takePendingNotice(), "No later conversation announces it again")
    }

    func testReleaseAfterTheHostSawTheEndNotifiesOnce() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        calls.holdAnswers[0] = .ended(.failed)
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()
        await supervisor.callbackPassesSettled()

        await supervisor.finishCallbacks()?.value

        XCTAssertEqual(calls.notified.map(\.kind), [.failed])
    }

    func testAWatchTheCallCouldntRegisterIsRegisteredUnheldAtHangUp() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        calls.watchError = URLError(.notConnectedToInternet)
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()
        await supervisor.callbackPassesSettled()
        XCTAssertEqual(calls.watches.map(\.hold), [VoiceBackgroundJobSupervisor.callbackHoldSeconds])
        XCTAssertTrue(supervisor.jobs.first?.callsBackWhenDone ?? false, "A failed try keeps the job marked")

        calls.watchError = nil
        await supervisor.finishCallbacks()?.value

        XCTAssertEqual(calls.watches.map(\.hold), [VoiceBackgroundJobSupervisor.callbackHoldSeconds, 0])
        XCTAssertTrue(calls.notified.isEmpty)
    }

    func testAHostRefusalTellsTheCallAndUnmarksTheJob() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        calls.watchError = HermesCallRefusal.unavailable(.callsOff)
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()
        await supervisor.callbackPassesSettled()

        XCTAssertFalse(supervisor.jobs.first?.callsBackWhenDone ?? true)
        XCTAssertTrue(supervisor.pendingChatContext.contains { $0.contains("won't call the user about \"check the router\"") })
        await supervisor.finishCallbacks()?.value
        XCTAssertEqual(calls.watches.count, 1, "Not tried again at hang-up")
    }

    func testTheUsersOwnWordsMarkTheJobTheyAskedFor() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        var lines = [VoiceConversationTranscriptEntry(speaker: .user, text: "Check the router and call me when it's done.")]
        beginHermesCall(supervisor) { lines }
        lines.append(VoiceConversationTranscriptEntry(speaker: .assistant, text: "On it."))
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        lines.append(VoiceConversationTranscriptEntry(speaker: .user, text: "Also find a dinner recipe."))
        _ = await supervisor.performVoiceCommand(.start(instructions: "find a dinner recipe"))
        await supervisor.callbackPassesSettled()

        XCTAssertEqual(calls.watches.map(\.target.runtimeSessionID), ["rt-1"], "The words ask once")
    }

    func testALaterCallHoldsAWatchStillWaitingAndToldItCancels() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()
        await supervisor.callbackPassesSettled()
        await supervisor.finishCallbacks()?.value
        XCTAssertEqual(calls.holds.map(\.seconds), [0])

        beginHermesCall(supervisor)
        await supervisor.callbackPassesSettled()
        XCTAssertEqual(calls.holds.map(\.seconds), [0, VoiceBackgroundJobSupervisor.callbackHoldSeconds], "Hermes never calls mid-call")

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All good.", reasoning: nil))
        XCTAssertNotNil(supervisor.takePendingNotice())
        await supervisor.callbackPassesSettled()
        XCTAssertEqual(calls.cancels, ["w1"])
    }

    func testACallThatNeverHungUpHandsItsWatchToTheNextCall() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()
        await supervisor.callbackPassesSettled()

        // The next call begins before the first one's release went out.
        beginHermesCall(supervisor)
        await supervisor.callbackPassesSettled()

        XCTAssertFalse(calls.holds.isEmpty)
        XCTAssertTrue(calls.holds.allSatisfy { $0.seconds == VoiceBackgroundJobSupervisor.callbackHoldSeconds }, "Never released between the calls")
        XCTAssertEqual(calls.watches.count, 1, "Handed over, not registered again")
        XCTAssertTrue(calls.notified.isEmpty)
    }

    func testAWatchHandedToACallThatEndsMeanwhileIsLetGo() async {
        let (supervisor, _, calls) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        _ = supervisor.requestCallback()
        await supervisor.callbackPassesSettled()

        // The next call hangs up while its hold of the watch is on its way.
        calls.onHold = { [weak supervisor] seconds in
            if seconds > 0 { supervisor?.finishCallbacks() }
        }
        beginHermesCall(supervisor)
        await supervisor.callbackPassesSettled()

        XCTAssertEqual(calls.holds.map(\.seconds), [VoiceBackgroundJobSupervisor.callbackHoldSeconds, 0], "Released, so Hermes doesn't wait the hold out")
        XCTAssertTrue(calls.notified.isEmpty)
    }

    func testAnsweringHermesCallSilencesTheJobsNotice() async {
        let (supervisor, _, _) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        _ = await supervisor.performVoiceCommand(.start(instructions: "check the router"))
        supervisor.noteCallAnswered(sessionIDs: ["st-1"])
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All good.", reasoning: nil))

        XCTAssertNil(supervisor.takePendingNotice(), "The call that was answered told it")
    }

    func testCallMeMarkersAndToolArgumentsNameTheScope() {
        XCTAssertEqual(GPTLiveDelegationBridge.callMeMarker(in: "Call me:")?.scope, .latest)
        XCTAssertEqual(GPTLiveDelegationBridge.callMeMarker(in: " call me: check the server")?.rest, "check the server")
        XCTAssertEqual(GPTLiveDelegationBridge.callMeMarker(in: "Call me about all:")?.scope, .all)
        XCTAssertEqual(GPTLiveDelegationBridge.callMeMarker(in: "Call me about job 2: done?")?.scope, .job(number: 2))
        XCTAssertNil(GPTLiveDelegationBridge.callMeMarker(in: "Call me maybe"))
        XCTAssertNil(GPTLiveDelegationBridge.callMeMarker(in: "Please call me: later"))

        let id = UUID()
        XCTAssertEqual(GeminiLiveToolBridge.callbackScope(["job_id": id.uuidString]), .jobID(id))
        XCTAssertEqual(GeminiLiveToolBridge.callbackScope(["job_id": "3"]), .job(number: 3))
        XCTAssertEqual(GeminiLiveToolBridge.callbackScope(["scope": "all"]), .all)
        XCTAssertEqual(GeminiLiveToolBridge.callbackScope([:]), .latest)
    }

    func testCallbackPhrasesInTheUsersWords() {
        XCTAssertTrue(VoiceCallbackPhrases.asksForCallback("Call me when it’s done"))
        XCTAssertTrue(VoiceCallbackPhrases.asksForCallback("ring me back once it finishes"))
        XCTAssertTrue(VoiceCallbackPhrases.asksForCallback("Give me a call when you have it"))
        XCTAssertFalse(VoiceCallbackPhrases.asksForCallback("Don't call me when it's done"))
        XCTAssertFalse(VoiceCallbackPhrases.asksForCallback("Call me Alex"))
    }

    func testCallsClientSendsHoldsAndMapsRefusals() async throws {
        var requests: [(path: String, method: String, body: [String: Any]?)] = []
        var response: [String: Any] = ["ok": true, "status": "watching", "id": "abc123"]
        let client = HermesCallsClient(request: { path, method, body in
            requests.append((path, method, body))
            return response
        })

        let answer = try await client.watch(sessionIDs: ["rt-1"], title: "Check \"it\"", profile: "fam", holdSeconds: 90, endedWithinSeconds: 5)
        XCTAssertEqual(answer, .watching(id: "abc123"))
        XCTAssertEqual(requests.last?.method, "POST")
        XCTAssertEqual(requests.last?.body?["hold_s"] as? Int, 90)
        XCTAssertEqual(requests.last?.body?["ended_within_s"] as? Int, 5)
        XCTAssertEqual(requests.last?.body?["title"] as? String, "Check 'it'")
        XCTAssertTrue(requests.last?.path.contains("profile=fam") ?? false)

        response = ["ok": true, "status": "ended", "outcome": "done"]
        let released = try await client.hold(watchID: "abc123", profile: "fam", seconds: 0)
        XCTAssertEqual(released, .ended(.done))
        XCTAssertEqual(requests.last?.method, "PUT")
        XCTAssertTrue(requests.last?.path.hasPrefix(HermesCallsClient.watchesPath + "/abc123") ?? false)
        response = ["ok": true, "status": "gone"]
        let gone = try await client.hold(watchID: "abc123", profile: "fam", seconds: 90)
        XCTAssertEqual(gone, .gone)

        XCTAssertEqual(HermesCallsClient.refusal(from: DashboardTicketBridgeError.http(status: 409, detail: "This Hermes profile isn't paired with Conduit")), .unavailable(.notPaired))
        XCTAssertEqual(HermesCallsClient.refusal(from: DashboardTicketBridgeError.http(status: 409, detail: "Calls are off for this Hermes profile")), .unavailable(.callsOff))
        XCTAssertEqual(HermesCallsClient.refusal(from: DashboardTicketBridgeError.http(status: 429, detail: "Too many jobs are already waiting to call you")), .tooMany)
        XCTAssertNil(HermesCallsClient.refusal(from: DashboardTicketBridgeError.http(status: 429, detail: "Too many call requests; try again shortly")))
        XCTAssertNil(HermesCallsClient.refusal(from: URLError(.timedOut)))
    }

    /// GPT-Live's "Call me: <work>" asks for the job that takes the work,
    /// even a running one taking it as a change; never a later job.
    func testGPTLiveCallMeWithAChangeCallsAboutTheJobThatTookIt() async {
        let (supervisor, jobs, _) = hermesCallSupervisor()
        beginHermesCall(supervisor)
        let bridge = GPTLiveDelegationBridge(supervisor: supervisor)
        _ = await bridge.handleDelegation(id: "del_1", request: "check the server")

        let changed = await bridge.handleDelegation(id: "del_2", request: "Call me: call me: make it the staging server")

        XCTAssertEqual(jobs.redirects.map(\.0), ["rt-1"], "The change went into the running job")
        let notes = changed.filter { if case .sessionContext(let text, _, _, _) = $0 { return text.hasPrefix("[Call request:") }; return false }
        XCTAssertEqual(notes.count, 1, "Asked once: \(changed)")
        XCTAssertEqual(supervisor.jobs.first?.callsBackWhenDone, true)

        _ = await bridge.handleDelegation(id: "del_3", request: "New job: find a dinner recipe")
        XCTAssertEqual(supervisor.jobs.count, 2)
        XCTAssertEqual(supervisor.jobs.last?.callsBackWhenDone, false, "Unrelated work doesn't call")
    }

    func testGPTLiveCallMeOnAHeldRequestGoesWithItOrNotAtAll() async {
        let (supervisor, _, _) = hermesCallSupervisor()
        supervisor.liveCallTranscript = { [] }
        supervisor.beginLiveCall(asksBeforeSending: true)
        let bridge = GPTLiveDelegationBridge(supervisor: supervisor)
        let held = await bridge.handleDelegation(id: "del_1", request: "Call me: book a table for Sam", userWords: "book a table for Sam")
        guard case .delegationReply("del_1", GPTLiveDelegationBridge.heldForOKText, .speakable)? = held.first else { return XCTFail("\(held)") }
        let no = await bridge.handleDelegation(id: "del_2", request: "No thanks", userWords: "No thanks")
        guard case .delegationReply("del_2", GPTLiveDelegationBridge.dropped, .commentary)? = no.first else { return XCTFail("\(no)") }

        supervisor.setAsksBeforeSending(false)
        _ = await bridge.handleDelegation(id: "del_3", request: "find a dinner recipe")
        XCTAssertEqual(supervisor.jobs.count, 1)
        XCTAssertEqual(supervisor.jobs.first?.callsBackWhenDone, false, "The declined request's call went with it")

        // OK'd, it calls.
        let (okSupervisor, _, _) = hermesCallSupervisor()
        okSupervisor.liveCallTranscript = { [] }
        okSupervisor.beginLiveCall(asksBeforeSending: true)
        let okBridge = GPTLiveDelegationBridge(supervisor: okSupervisor)
        _ = await okBridge.handleDelegation(id: "del_1", request: "Call me: book a table for Sam", userWords: "book a table for Sam")
        _ = await okBridge.handleDelegation(id: "del_2", request: "Send:", userWords: "yes please")
        XCTAssertEqual(okSupervisor.jobs.count, 1)
        XCTAssertEqual(okSupervisor.jobs.first?.callsBackWhenDone, true)
    }

    func testCallSettingsGapChoicesKeepTheCurrentValue() {
        XCTAssertEqual(HermesCallSettingsFormat.gapChoices(bounds: 30...3_600, current: 120), [30, 60, 120, 300, 600, 1_800, 3_600])
        XCTAssertEqual(HermesCallSettingsFormat.gapChoices(bounds: 60...600, current: 90), [60, 90, 120, 300, 600])
    }
}
