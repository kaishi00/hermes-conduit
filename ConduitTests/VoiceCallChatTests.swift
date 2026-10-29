//
//  VoiceCallChatTests.swift
//  ConduitTests
//
//  An unattached live call keeps its requests in the chat its first one
//  made (#1250).
//

import XCTest
@testable import Conduit

@MainActor
extension VoiceConversationControllerTests {
    /// An unattached live call: no chat until its first ordinary job.
    private func makeUnattachedCall() -> (VoiceBackgroundJobSupervisor, FakeVoiceJobBackend) {
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(
            backend: fake.backend,
            pollInterval: .seconds(3_600),
            threadWaitInterval: .milliseconds(5)
        )
        supervisor.liveCallTranscript = { [] }
        supervisor.beginLiveCall()
        return (supervisor, fake)
    }

    private func waitForCallChat(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if condition() { return true }
        XCTFail("Timed out waiting for the condition", file: file, line: line)
        return false
    }

    func testAnUnattachedCallsFirstOrdinaryJobBecomesTheCallsChat() async {
        let (supervisor, fake) = makeUnattachedCall()
        var adopted: [VoiceThreadTarget] = []
        supervisor.onCallChatAdopted = { adopted.append($0) }

        _ = await supervisor.startJob(instructions: "plan the trip to Lisbon", joinsCall: true)

        XCTAssertEqual(fake.created, 1)
        XCTAssertEqual(supervisor.liveThread?.runtimeSessionID, "rt-1")
        XCTAssertEqual(supervisor.liveThread?.storedSessionID, "st-1")
        XCTAssertEqual(supervisor.liveThread?.title, "plan the trip to Lisbon")
        XCTAssertEqual(adopted.map(\.runtimeSessionID), ["rt-1"])
        XCTAssertEqual(supervisor.callChatJobID, supervisor.jobs.first?.id)

        // The next request is that chat's next turn, once the job is done.
        fake.threadBusy = true
        let next = supervisor.startThreadTurn(request: "and book the hotel")
        XCTAssertNotNil(next.jobID)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(fake.threadSubmissions.isEmpty, "it waits for the job running in the chat")
        fake.threadBusy = false
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Here's the plan.", reasoning: nil))
        XCTAssertEqual(supervisor.jobs.first?.status, .finished)
        guard await waitForCallChat({ !fake.threadSubmissions.isEmpty }) else { return }
        XCTAssertEqual(fake.threadSubmissions.first?.0, "rt-1")
        XCTAssertEqual(fake.threadSubmissions.first?.1, "(voice) and book the hotel")
        XCTAssertEqual(fake.created, 1, "no second session")

        // The turn's own reply is the turn's, not the finished job's.
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Booked.", reasoning: nil))
        XCTAssertEqual(supervisor.jobs.last?.status, .finished)
        XCTAssertEqual(supervisor.jobs.last?.result, "Booked.")
        XCTAssertEqual(supervisor.jobs.first?.result, "Here's the plan.")
    }

    func testOnlyOrdinaryWorkInARunningUnattachedCallMakesTheCallsChat() async {
        // Background, quick or another profile's work: still a job of its own.
        let (supervisor, fake) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "research flights in the background")
        XCTAssertNil(supervisor.liveThread)
        fake.profileTargets = ["fam": .other("fam")]
        _ = await supervisor.startJob(instructions: "check the lights", profile: "fam", joinsCall: true)
        XCTAssertNil(supervisor.liveThread, "another profile's job is never the call's chat")

        // Classic and other callers outside a live call never attach.
        let fakeClassic = FakeVoiceJobBackend()
        let classic = VoiceBackgroundJobSupervisor(backend: fakeClassic.backend, pollInterval: .seconds(3_600))
        _ = await classic.startJob(instructions: "check the server", joinsCall: true)
        XCTAssertNil(classic.liveThread)

        // A failed start leaves the call unattached.
        let (failing, failingFake) = makeUnattachedCall()
        failingFake.submitError = URLError(.notConnectedToInternet)
        _ = await failing.startJob(instructions: "check the server", joinsCall: true)
        XCTAssertNil(failing.liveThread)

        // A call attached to a chat keeps it.
        let (attached, _) = makeUnattachedCall()
        let chat = VoiceThreadTarget(runtimeSessionID: "rt-chat", storedSessionID: "st-chat", title: "Build")
        attached.attachLiveThread(chat)
        _ = await attached.startJob(instructions: "check the server", joinsCall: true)
        XCTAssertEqual(attached.liveThread, chat)

        // Hanging up lets go of it.
        let (ended, _) = makeUnattachedCall()
        _ = await ended.startJob(instructions: "check the server", joinsCall: true)
        XCTAssertNotNil(ended.liveThread)
        ended.detachLiveThread()
        XCTAssertNil(ended.liveThread)
        XCTAssertNil(ended.callChatJobID)
    }

    func testHangingUpLetsGoOfTheCallsChatRequest() async {
        // Still running at hang-up: its reply is the chat's, never a later
        // call's notice, and the chat's events aren't its any more.
        let (supervisor, _) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        supervisor.detachLiveThread()
        XCTAssertEqual(supervisor.jobs.first?.isDetachedThreadTurn, true)
        XCTAssertEqual(supervisor.jobs.first?.status, .running, "a request Hermes took isn't cancelled")
        XCTAssertTrue(supervisor.listedJobs.isEmpty, "a later call doesn't list it")
        XCTAssertNil(supervisor.backgroundJob(numbered: 1), "nor reach it by number")

        supervisor.beginLiveCall()
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Plan.", reasoning: nil))
        XCTAssertNil(supervisor.takePendingNotice(), "a later call doesn't hear it")
    }

    func testAReplayedReplyOfTheCallsChatRequestIsNotTypedContext() async {
        let (supervisor, fake) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Plan.", reasoning: nil))
        _ = supervisor.takePendingNotice()
        fake.threadPrompt = "plan the trip"

        // A reconnect replays it.
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Plan.", reasoning: nil))

        XCTAssertNil(supervisor.takePendingChatContext())
    }

    func testALateReplyOfThePollSettledCallsChatRequestIsNotTheNextTurns() async {
        let (supervisor, fake) = makeUnattachedCall()
        supervisor.liveCallReadsReplies = true
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        fake.threadBusy = true
        let next = supervisor.startThreadTurn(request: "and book the hotel")
        XCTAssertNotNil(next.jobID)
        // The first request's completion is missed: the poll settles it.
        fake.threadReply = "Plan."
        await supervisor.pollOnce()
        fake.threadBusy = false
        await supervisor.pollOnce()
        XCTAssertEqual(supervisor.jobs.first?.status, .finished)
        guard await waitForCallChat({ !fake.threadSubmissions.isEmpty }) else { return }

        // A reconnect replays that completion after the next turn is sent.
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Plan.", reasoning: nil))
        XCTAssertEqual(supervisor.jobs.first(where: { $0.id == next.jobID })?.status.isActive, true, "the old reply isn't the new turn's")

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: "m2", content: "Booked.", reasoning: nil))
        XCTAssertEqual(supervisor.jobs.first(where: { $0.id == next.jobID })?.result, "Booked.")
    }

    func testCancellingTheCallsChatRequestLetsTheNextTurnGoIn() async {
        let (supervisor, fake) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        guard let first = supervisor.jobs.first?.id else { return XCTFail("no job") }
        XCTAssertNotNil(supervisor.startThreadTurn(request: "and book the hotel").jobID)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fake.threadSubmissions.isEmpty, "it waits for the first request")

        _ = await supervisor.cancel(jobID: first)

        guard await waitForCallChat({ !fake.threadSubmissions.isEmpty }) else { return }
        XCTAssertEqual(fake.threadSubmissions.first?.0, "rt-1")
    }

    func testAReplayedReplyWithNoIdOfTheCallsChatRequestIsNotTheNextTurns() async {
        let (supervisor, fake) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Plan.", reasoning: nil))
        let next = supervisor.startThreadTurn(request: "and book the hotel")
        guard await waitForCallChat({ !fake.threadSubmissions.isEmpty }) else { return }

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Plan.", reasoning: nil))
        XCTAssertEqual(supervisor.jobs.first(where: { $0.id == next.jobID })?.status.isActive, true)
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Booked.", reasoning: nil))
        XCTAssertEqual(supervisor.jobs.first(where: { $0.id == next.jobID })?.result, "Booked.")
    }

    func testAFirstRequestLeftRunningAtHangUpDoesNotCountAgainstTheNextCall() async {
        let (supervisor, _) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        XCTAssertEqual(supervisor.activeJobCount, 1)
        supervisor.detachLiveThread()
        XCTAssertEqual(supervisor.activeJobCount, 0)
    }

    func testANewRequestWaitsOnTheCallsChatRequestsQuestion() async {
        let (supervisor, fake) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "clean the logs", joinsCall: true)
        let approval = ApprovalActivity(
            sessionId: "rt-1",
            command: "rm -rf /var/log/old",
            description: "Delete old logs",
            choices: nil,
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        supervisor.observe(.approval(sessionId: "rt-1", activity: approval))
        XCTAssertEqual(supervisor.jobs.first?.status, .needsInput)

        let next = supervisor.startThreadTurn(request: "and the caches")
        XCTAssertNil(next.jobID, "Hermes is paused in the chat until the user answers")
        XCTAssertTrue(fake.threadSubmissions.isEmpty)
    }

    func testTheCallsChatRequestCountsAsOneOfTheChatsThree() async {
        let (supervisor, fake) = makeUnattachedCall()
        fake.threadBusy = true
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        XCTAssertNotNil(supervisor.startThreadTurn(request: "and book the hotel").jobID)
        XCTAssertNotNil(supervisor.startThreadTurn(request: "and the car").jobID)
        let fourth = supervisor.startThreadTurn(request: "and the dinner")
        XCTAssertNil(fourth.jobID, "three in flight with the first request")
        XCTAssertNotNil(fourth.refusal)
    }

    func testTheCallsChatRequestsResultIsToldAsTheChatsReply() async {
        let (supervisor, _) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Here's the plan.", reasoning: nil))
        guard case .submit(let prompt, _)? = supervisor.takePendingNotice() else { return XCTFail("the result is handed back") }
        XCTAssertTrue(prompt.hasPrefix("[Hermes replied in the chat."))
    }

    func testARequestSaidWhileTheCallsChatIsMadeJoinsThatChat() async {
        let (supervisor, fake) = makeUnattachedCall()
        fake.parksCreate = true
        var firstID: UUID?
        let first = Task { await supervisor.startJob(instructions: "plan the trip", joinsCall: true) { firstID = $0 } }
        await fake.createParked.waitUntil(1)
        XCTAssertNotNil(firstID)
        var secondID: UUID?
        let second = Task { await supervisor.startJob(instructions: "and book the hotel", joinsCall: true) { secondID = $0 } }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(secondID, "it waits for the chat being made")
        fake.releaseCreate()
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(fake.created, 1, "one chat for both")
        XCTAssertEqual(supervisor.liveThread?.runtimeSessionID, "rt-1")
        XCTAssertEqual(supervisor.jobs.first { $0.id == secondID }?.isThreadTurn, true, "the second is the chat's next turn")
    }

    func testAFirstJobThatFinishesStartingAfterTheHangUpAttachesNothing() async {
        let (supervisor, fake) = makeUnattachedCall()
        fake.parksCreate = true
        var firstID: UUID?
        let first = Task { await supervisor.startJob(instructions: "plan the trip", joinsCall: true) { firstID = $0 } }
        await fake.createParked.waitUntil(1)
        XCTAssertNotNil(firstID)
        supervisor.detachLiveThread()
        fake.releaseCreate()
        _ = await first.value
        XCTAssertNil(supervisor.liveThread)
        XCTAssertNil(supervisor.callChatJobID)
        XCTAssertTrue(supervisor.listedJobs.isEmpty, "the ended call's first request isn't the next call's job")

        // The next call makes its own chat.
        supervisor.beginLiveCall()
        _ = await supervisor.startJob(instructions: "check the server", joinsCall: true)
        XCTAssertEqual(supervisor.liveThread?.runtimeSessionID, "rt-2")
    }

    func testARequestWaitingForTheCallsChatAtHangUpIsLetGo() async {
        let (supervisor, fake) = makeUnattachedCall()
        fake.parksCreate = true
        let first = Task { await supervisor.startJob(instructions: "plan the trip", joinsCall: true) }
        await fake.createParked.waitUntil(1)
        let second = Task { await supervisor.startJob(instructions: "and book the hotel", joinsCall: true) }
        try? await Task.sleep(for: .milliseconds(20))
        supervisor.detachLiveThread()
        fake.releaseCreate()
        _ = await first.value
        let reply = await second.value

        XCTAssertEqual(reply, "The call ended before Hermes took this request.")
        XCTAssertEqual(fake.created, 1, "nothing of the ended call starts after it")
    }

    func testTheCallsChatJobTakesFollowUpsWhileItRuns() async {
        let (supervisor, _) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        let jobID = supervisor.jobs.first?.id
        XCTAssertEqual(supervisor.threadFollowUpTarget(), jobID)

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Done.", reasoning: nil))
        XCTAssertNil(supervisor.threadFollowUpTarget(), "a finished job takes no follow-up")
    }

    func testATurnTypedInTheCallsChatAfterItsJobReachesTheCall() async {
        let (supervisor, fake) = makeUnattachedCall()
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Plan.", reasoning: nil))
        _ = supervisor.takePendingNotice()
        fake.threadPrompt = "make it three days"

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: "m2", content: "Three days it is.", reasoning: nil))

        XCTAssertTrue(supervisor.takePendingChatContext()?.contains("Three days it is.") == true)
        XCTAssertEqual(supervisor.jobs.first?.result, "Plan.", "the settled job keeps its own result")
    }

    func testTheCallsChatLearnsItsStoredIDWithItsJob() async {
        let (supervisor, fake) = makeUnattachedCall()
        fake.storedIDs = false
        var adopted: [VoiceThreadTarget] = []
        supervisor.onCallChatAdopted = { adopted.append($0) }
        _ = await supervisor.startJob(instructions: "plan the trip", joinsCall: true)
        XCTAssertNil(supervisor.liveThread?.storedSessionID)

        fake.liveRows = [LiveSessionStatus(runtimeSessionId: "rt-1", storedSessionId: "st-late", status: "working")]
        await supervisor.pollOnce()

        XCTAssertEqual(supervisor.liveThread?.storedSessionID, "st-late")
        XCTAssertEqual(adopted.map(\.storedSessionID), [nil, "st-late"])
    }

    func testGeminiStartJobInAnUnattachedCallGoesToTheChatOfTheFirst() async {
        let (supervisor, fake) = makeUnattachedCall()
        let bridge = GeminiLiveToolBridge(supervisor: supervisor)

        _ = await bridge.handle(GeminiLiveProtocol.FunctionCall(id: "call_1", name: "start_job", arguments: ["instructions": "plan the trip"]))
        XCTAssertEqual(supervisor.liveThread?.runtimeSessionID, "rt-1")
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Plan.", reasoning: nil))
        _ = bridge.pendingUpdates()

        _ = await bridge.handle(GeminiLiveProtocol.FunctionCall(id: "call_2", name: "start_job", arguments: ["instructions": "and book the hotel"]))
        guard await waitForCallChat({ !fake.threadSubmissions.isEmpty }) else { return }
        XCTAssertEqual(fake.threadSubmissions.first?.0, "rt-1")
        XCTAssertEqual(fake.created, 1)

        // Asked-for background work still runs apart.
        _ = await bridge.handle(GeminiLiveProtocol.FunctionCall(id: "call_3", name: "start_job", arguments: ["instructions": "research flights in the background"]))
        XCTAssertEqual(fake.created, 2)
        XCTAssertEqual(supervisor.liveThread?.runtimeSessionID, "rt-1")
    }

    func testGeminiBackgroundWorkFirstLeavesTheCallUnattached() async {
        let (supervisor, fake) = makeUnattachedCall()
        let bridge = GeminiLiveToolBridge(supervisor: supervisor)

        _ = await bridge.handle(GeminiLiveProtocol.FunctionCall(id: "call_1", name: "start_job", arguments: ["instructions": "Quick: what's on my calendar"]))
        XCTAssertNil(supervisor.liveThread, "quick work runs apart")
        _ = await bridge.handle(GeminiLiveProtocol.FunctionCall(id: "call_2", name: "start_job", arguments: ["instructions": "plan the trip"]))
        XCTAssertEqual(supervisor.liveThread?.runtimeSessionID, "rt-2", "the first ordinary request makes the chat")
        XCTAssertEqual(fake.created, 2)
    }

    func testGPTLiveDelegationsInAnUnattachedCallGoToTheChatOfTheFirst() async {
        let (supervisor, fake) = makeUnattachedCall()
        let bridge = GPTLiveDelegationBridge(supervisor: supervisor)

        _ = await bridge.handleDelegation(id: "del_1", request: "plan the trip")
        XCTAssertEqual(supervisor.liveThread?.runtimeSessionID, "rt-1")

        // While it runs, a correction goes into it, as into the only job (#472).
        _ = await bridge.handleDelegation(id: "del_2", request: "make it Porto", userWords: "wait, make it Porto")
        XCTAssertEqual(fake.redirects.first?.0, "rt-1")
        XCTAssertEqual(fake.created, 1)

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Plan.", reasoning: nil))
        _ = await bridge.handleDelegation(id: "del_3", request: "book the hotel", userWords: "book the hotel")
        guard await waitForCallChat({ !fake.threadSubmissions.isEmpty }) else { return }
        XCTAssertEqual(fake.threadSubmissions.first?.0, "rt-1")
        XCTAssertEqual(fake.created, 1, "no second session")

        _ = await bridge.handleDelegation(id: "del_4", request: "research flights in the background")
        XCTAssertEqual(fake.created, 2, "asked-for background work still runs apart")
    }

    // MARK: Watch calls the iPhone runs jobs for

    func testAWatchRequestSaidWhileTheFirstStartsJoinsItsChat() async {
        let fake = FakeVoiceJobBackend()
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base)
        fake.parksCreate = true
        let first = Task { await watch.startJob(instructions: "plan the trip", profile: nil, joinsCall: true, onJobCreated: nil) }
        await fake.createParked.waitUntil(1)
        let second = Task { await watch.startJob(instructions: "and book the hotel", profile: nil, joinsCall: true, onJobCreated: nil) }
        try? await Task.sleep(for: .milliseconds(20))
        fake.releaseCreate()
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(fake.created, 1, "the second waits for the first's chat")
        XCTAssertEqual(watch.callChat?.runtimeSessionID, "rt-1")
    }

    func testAReplayedReplyOfAWatchCallsEarlierRequestIsNotTheNextOnes() async {
        let fake = FakeVoiceJobBackend()
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base)
        _ = await watch.startJob(instructions: "plan the trip", profile: nil, joinsCall: true, onJobCreated: nil)
        base.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Plan.", reasoning: nil))
        _ = await watch.startJob(instructions: "and book the hotel", profile: nil, joinsCall: true, onJobCreated: nil)
        guard await waitForCallChat({ base.jobs.last?.status == .running }) else { return }

        base.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Plan.", reasoning: nil))
        XCTAssertEqual(base.jobs.last?.status, .running, "the replay isn't the hotel's reply")
        base.observe(.messageComplete(sessionId: "rt-1", messageId: "m2", content: "Booked.", reasoning: nil))
        XCTAssertEqual(base.jobs.map(\.result), ["Plan.", "Booked."])
    }

    func testAReplayedIdlessReplyOfAWatchCallsFirstRequestIsNotTheNextOnes() async {
        let fake = FakeVoiceJobBackend()
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base)
        _ = await watch.startJob(instructions: "plan the trip", profile: nil, joinsCall: true, onJobCreated: nil)
        base.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Plan.", reasoning: nil))
        _ = await watch.startJob(instructions: "and book the hotel", profile: nil, joinsCall: true, onJobCreated: nil)
        guard await waitForCallChat({ base.jobs.last?.status == .running }) else { return }

        base.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Plan.", reasoning: nil))
        XCTAssertEqual(base.jobs.last?.status, .running, "the replay isn't the hotel's reply")
        base.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Booked.", reasoning: nil))
        XCTAssertEqual(base.jobs.map(\.result), ["Plan.", "Booked."])
    }

    func testAWatchCallsLaterOrdinaryJobsRunInTheChatItsFirstMade() async {
        let fake = FakeVoiceJobBackend()
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base)

        _ = await watch.startJob(instructions: "plan the trip", profile: nil, joinsCall: true, onJobCreated: nil)
        XCTAssertEqual(watch.callChat?.runtimeSessionID, "rt-1")
        XCTAssertNil(base.liveThread, "the phone has no call to attach")

        // While the first runs, the next waits its turn in the same chat.
        _ = await watch.startJob(instructions: "and book the hotel", profile: nil, joinsCall: true, onJobCreated: nil)
        XCTAssertEqual(fake.created, 1)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fake.submissions.count, 1)
        XCTAssertEqual(base.jobs.last?.status, .starting)

        base.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Plan.", reasoning: nil))
        guard await waitForCallChat({ fake.submissions.count == 2 }) else { return }
        XCTAssertEqual(fake.submissions.last?.0, "rt-1")
        XCTAssertTrue(fake.submissions.last?.1.hasSuffix("and book the hotel") == true)
        guard await waitForCallChat({ base.jobs.last?.status == .running }) else { return }
        base.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Booked.", reasoning: nil))
        XCTAssertEqual(base.jobs.map(\.result), ["Plan.", "Booked."])

        // Work kept apart still gets a chat of its own.
        _ = await watch.startJob(instructions: "research flights in the background", profile: nil, joinsCall: false, onJobCreated: nil)
        XCTAssertEqual(fake.created, 2)
        XCTAssertEqual(watch.callChat?.runtimeSessionID, "rt-1")
    }

    func testCancellingAJobWaitingForTheCallsChatLeavesTheRunningOneAlone() async {
        let fake = FakeVoiceJobBackend()
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base)
        _ = await watch.startJob(instructions: "plan the trip", profile: nil, joinsCall: true, onJobCreated: nil)
        _ = await watch.startJob(instructions: "and book the hotel", profile: nil, joinsCall: true, onJobCreated: nil)
        guard let waiting = base.jobs.last?.id else { return XCTFail("no job") }

        _ = await base.cancel(jobID: waiting)

        XCTAssertTrue(fake.cancelled.isEmpty, "the first request keeps running")
        XCTAssertEqual(base.jobs.first?.status, .running)
        base.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Plan.", reasoning: nil))
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fake.submissions.count, 1, "the cancelled request never goes in")
    }
}
