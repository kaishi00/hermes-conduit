//
//  VoiceBackgroundJobTests.swift
//  Conduit
//
//  Voice background jobs (issue #163, phase 1): spoken job commands, the
//  job supervisor's ledger, and the Voice controller's hand-back of finished
//  jobs. Written as extensions of existing Voice suites: the CI test planner
//  is at capacity for new XCTestCase classes.
//

import XCTest
@testable import Conduit

// MARK: - Spoken command parsing

@MainActor
extension VoiceSpokenCommandMatchingTests {
    func testBackgroundJobStartPrefixCarriesTheTaskWithOriginalCasing() {
        XCTAssertEqual(
            VoiceBackgroundJobCommands.parse("Background job, check why my server went down."),
            .start(instructions: "check why my server went down")
        )
        XCTAssertEqual(
            VoiceBackgroundJobCommands.parse("Start a background job: Review PR 12"),
            .start(instructions: "Review PR 12")
        )
        XCTAssertEqual(
            VoiceBackgroundJobCommands.parse("run in the background summarize today's email"),
            .start(instructions: "summarize today's email")
        )
    }

    func testBackgroundJobChineseStartPrefixNeedsNoSeparator() {
        XCTAssertEqual(VoiceBackgroundJobCommands.parse("后台任务检查服务器"), .start(instructions: "检查服务器"))
        XCTAssertEqual(VoiceBackgroundJobCommands.parse("后台任务，检查服务器。"), .start(instructions: "检查服务器"))
    }

    func testBackgroundJobStatusAndCancelMatchWholeUtterancesOnly() {
        XCTAssertEqual(VoiceBackgroundJobCommands.parse("Job status."), .status)
        XCTAssertEqual(VoiceBackgroundJobCommands.parse("background jobs"), .status)
        XCTAssertEqual(VoiceBackgroundJobCommands.parse("后台任务状态"), .status)
        XCTAssertEqual(VoiceBackgroundJobCommands.parse("Cancel background jobs!"), .cancelAll)
        XCTAssertEqual(VoiceBackgroundJobCommands.parse("取消后台任务"), .cancelAll)
        XCTAssertNil(VoiceBackgroundJobCommands.parse("what is the job status of the build"))
    }

    func testOrdinarySentencesNeverStartBackgroundJobs() {
        XCTAssertNil(VoiceBackgroundJobCommands.parse("background job"), "a prefix with no task is not a command")
        XCTAssertNil(VoiceBackgroundJobCommands.parse("background jobsite cleanup"), "Latin prefixes need a word boundary")
        XCTAssertNil(VoiceBackgroundJobCommands.parse("tell me about background jobs in iOS"))
        XCTAssertNil(VoiceBackgroundJobCommands.parse("what's in the background of this photo"))
        XCTAssertNil(VoiceBackgroundJobCommands.parse("   "))
    }
}

// MARK: - Supervisor

@MainActor
final class FakeVoiceJobBackend {
    var createError: Error?
    var submitError: Error?
    var cancelError: Error?
    /// When true, the next createSession parks until `releaseCreate()`.
    var parksCreate = false
    let createParked = AwaitableCounter()
    /// Runs inside submit, so a test can deliver events mid-submission.
    var onSubmit: (@MainActor (_ sessionID: String) -> Void)?
    private var parkedCreate: CheckedContinuation<Void, Never>?
    var liveRows: [LiveSessionStatus] = []
    private(set) var created = 0
    /// The profile each createSession was asked for (nil: the active one).
    private(set) var createdProfiles: [String?] = []
    /// The profile each liveSessions read was scoped to.
    private(set) var polledProfiles: [String?] = []
    /// Spoken names the fake resolves; anything else is unknown.
    var profileTargets: [String: VoiceJobProfileTarget] = [:]
    /// Profiles whose liveSessions read throws.
    var failingLiveProfiles: Set<String> = []
    private(set) var titles: [(String, String)] = []
    private(set) var submissions: [(String, String)] = []
    private(set) var cancelled: [String] = []
    /// The attached chat: whether a turn runs there, what was sent to it,
    /// and its latest reply.
    var threadBusy = false
    var threadSubmitError: Error?
    var threadReply: String?
    /// The runtime the chat resumes onto; nil keeps the target's own.
    var threadRuntime: String?
    var onThreadSubmit: (@MainActor () -> Void)?
    private(set) var threadSubmissions: [(String, String)] = []

    /// Strong captures: tests routinely discard the fake (`let (supervisor, _)
    /// = makeSupervisor()`), and the supervisor's backend must keep it alive
    /// (an unowned capture crashed every such test). The fake holds nothing
    /// back, so there is no cycle.
    var backend: VoiceBackgroundJobBackend {
        VoiceBackgroundJobBackend(
            createSession: { [self] profile in
                self.createdProfiles.append(profile)
                if let error = self.createError { throw error }
                if self.parksCreate {
                    self.parksCreate = false
                    await withCheckedContinuation { continuation in
                        self.parkedCreate = continuation
                        self.createParked.increment()
                    }
                }
                self.created += 1
                return ("rt-\(self.created)", "st-\(self.created)")
            },
            setTitle: { [self] id, title in self.titles.append((id, title)) },
            submit: { [self] id, text in
                self.submissions.append((id, text))
                self.onSubmit?(id)
                if let error = self.submitError { throw error }
            },
            cancel: { [self] id in
                if let cancelError = self.cancelError { throw cancelError }
                self.cancelled.append(id)
            },
            liveSessions: { [self] profile in
                self.polledProfiles.append(profile)
                if let profile, self.failingLiveProfiles.contains(profile) { throw URLError(.timedOut) }
                return self.liveRows
            },
            resolveProfile: { [self] name in self.profileTargets[name.lowercased()] ?? .unknown },
            threadIsBusy: { [self] _ in self.threadBusy },
            resolveThreadRuntime: { [self] thread in self.threadRuntime ?? thread.runtimeSessionID },
            submitThreadTurn: { [self] _, runtimeID, text in
                self.threadSubmissions.append((runtimeID, text))
                self.onThreadSubmit?()
                if let error = self.threadSubmitError { throw error }
                return runtimeID
            },
            latestThreadReply: { [self] _ in self.threadReply }
        )
    }

    func releaseCreate() {
        let continuation = parkedCreate
        parkedCreate = nil
        continuation?.resume()
    }
}

@MainActor
extension VoiceConversationControllerTests {
    private func makeSupervisor() -> (VoiceBackgroundJobSupervisor, FakeVoiceJobBackend) {
        let fake = FakeVoiceJobBackend()
        // A long poll interval keeps the liveness fallback out of the way;
        // tests drive it explicitly through pollOnce().
        return (VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600)), fake)
    }

    func testStartingAJobCreatesATitledSessionAndSubmitsTheTask() async {
        let (supervisor, fake) = makeSupervisor()
        var createdIDs: [String] = []
        supervisor.onJobSessionCreated = { createdIDs = $0 }

        let reply = await supervisor.performVoiceCommand(.start(instructions: "check why my server went down"))

        XCTAssertTrue(reply.contains("check why my server went down"), "the confirmation names the job")
        XCTAssertEqual(createdIDs, ["rt-1", "st-1"])
        XCTAssertEqual(fake.titles.map(\.1), ["check why my server went down"])
        XCTAssertEqual(fake.submissions.count, 1)
        XCTAssertEqual(fake.submissions.first?.0, "rt-1")
        XCTAssertTrue(fake.submissions.first?.1.hasSuffix("check why my server went down") == true)
        XCTAssertEqual(supervisor.jobs.map(\.status), [.running])
        XCTAssertNil(supervisor.takePendingNotice(), "a running job has nothing to hand back")
    }

    func testLeadingProfileNameRoutesTheJobToThatProfile() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["fam": .other("fam")]

        let reply = await supervisor.performVoiceCommand(.start(instructions: "for Fam, check the router"))

        XCTAssertEqual(fake.createdProfiles, ["fam"])
        XCTAssertEqual(supervisor.jobs.first?.profile, "fam")
        XCTAssertEqual(supervisor.jobs.first?.title, "check the router", "the target is not part of the task")
        XCTAssertTrue(fake.submissions.first?.1.hasSuffix("check the router") == true)
        XCTAssertTrue(reply.contains("Fam"), "the confirmation names the profile as it was said")
    }

    func testToBeforeAVerbNeverNamesAProfile() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["check": .other("check")]

        _ = await supervisor.performVoiceCommand(.start(instructions: "to check the router"))

        XCTAssertEqual(fake.createdProfiles, [nil])
        XCTAssertEqual(supervisor.jobs.first?.instructions, "to check the router")
    }

    func testOrdinaryLeadingWordsStayPartOfTheTask() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["fam": .other("fam")]

        _ = await supervisor.performVoiceCommand(.start(instructions: "for the report, check last week's numbers"))

        XCTAssertEqual(fake.createdProfiles, [nil])
        XCTAssertNil(supervisor.jobs.first?.profile)
        XCTAssertEqual(supervisor.jobs.first?.instructions, "for the report, check last week's numbers")
    }

    func testNamingTheActiveProfileRunsTheJobHere() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["default": .active]

        _ = await supervisor.startJob(instructions: "check the server", profile: "Default")

        XCTAssertEqual(fake.createdProfiles, [nil])
        XCTAssertNil(supervisor.jobs.first?.profile)
    }

    func testALeadingActiveProfileNameIsDroppedFromTheTask() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["default": .active, "fam": .other("fam")]

        _ = await supervisor.performVoiceCommand(.start(instructions: "for Default, check the router"))
        _ = await supervisor.startJob(instructions: "for Fam, check the lights", profile: "fam")

        XCTAssertEqual(fake.createdProfiles, [nil, "fam"])
        XCTAssertEqual(supervisor.jobs.map(\.instructions), ["check the router", "check the lights"])
    }

    func testAnUnknownNamedProfileStartsNothing() async {
        let (supervisor, fake) = makeSupervisor()

        let reply = await supervisor.startJob(instructions: "check the server", profile: "Nobody")

        XCTAssertTrue(fake.createdProfiles.isEmpty)
        XCTAssertTrue(supervisor.jobs.isEmpty)
        XCTAssertTrue(reply.contains("Nobody"))
    }

    func testLivenessPollReadsEachJobsOwnProfile() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["fam": .other("fam")]
        _ = await supervisor.startJob(instructions: "check the server")
        _ = await supervisor.startJob(instructions: "check the router", profile: "fam")

        await supervisor.pollOnce()

        XCTAssertEqual(Set(fake.polledProfiles.map { $0 ?? "-" }), ["-", "fam"])
        XCTAssertEqual(fake.polledProfiles.count, 2)
    }

    func testOneProfilesFailedReadStillJudgesTheOthers() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["fam": .other("fam")]
        _ = await supervisor.startJob(instructions: "check the router", profile: "fam")
        _ = await supervisor.startJob(instructions: "check the server")
        fake.failingLiveProfiles = ["fam"]

        // The active profile lists nothing twice: its job settles.
        await supervisor.pollOnce()
        await supervisor.pollOnce()

        XCTAssertEqual(supervisor.jobs.first { $0.profile == nil }?.status, .finished)
        XCTAssertEqual(supervisor.jobs.first { $0.profile == "fam" }?.status, .running, "no read is not absence")
    }

    func testAnotherProfilesJobIsNeverSettledByAbsence() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["fam": .other("fam")]
        _ = await supervisor.startJob(instructions: "check the router", profile: "fam")

        await supervisor.pollOnce()
        await supervisor.pollOnce()
        await supervisor.pollOnce()

        XCTAssertEqual(supervisor.jobs.first?.status, .running, "a registry that never listed it can't prove it ended")

        // Once that profile's registry has listed the job, its absence counts.
        fake.liveRows = [LiveSessionStatus(runtimeSessionId: "rt-1", storedSessionId: "st-1", status: "working")]
        await supervisor.pollOnce()
        fake.liveRows = []
        await supervisor.pollOnce()
        await supervisor.pollOnce()

        XCTAssertEqual(supervisor.jobs.first?.status, .finished)
    }

    func testAMismatchedLeadingTargetStaysInTheTask() async {
        let (supervisor, fake) = makeSupervisor()
        fake.profileTargets = ["fam": .other("fam"), "work": .other("work")]

        _ = await supervisor.startJob(instructions: "for Work, check the lights", profile: "fam")

        XCTAssertEqual(fake.createdProfiles, ["fam"])
        XCTAssertEqual(supervisor.jobs.first?.instructions, "for Work, check the lights")
    }

    func testFinishedJobIsHandedBackOnceWithItsResult() async {
        let (supervisor, _) = makeSupervisor()
        var pendingSignals = 0
        supervisor.onNoticePending = { pendingSignals += 1 }
        _ = await supervisor.startJob(instructions: "review the PR")

        supervisor.observe(.messageComplete(sessionId: "other", messageId: nil, content: "not ours", reasoning: nil))
        XCTAssertEqual(supervisor.jobs.first?.status, .running, "events for other sessions are ignored")
        supervisor.observe(.messageComplete(sessionId: "st-1", messageId: nil, content: "Looks good.", reasoning: nil))

        XCTAssertEqual(supervisor.jobs.first?.status, .finished, "the stored id also identifies the job")
        XCTAssertEqual(pendingSignals, 1)
        guard case .submit(let prompt, let fallback)? = supervisor.takePendingNotice() else {
            return XCTFail("a finished job with a result is handed to the voice session")
        }
        XCTAssertTrue(prompt.contains("review the PR"))
        XCTAssertTrue(prompt.contains("Looks good."))
        XCTAssertTrue(fallback.contains("review the PR"))
        XCTAssertNil(supervisor.takePendingNotice(), "each outcome is delivered once")
    }

    func testApprovalAnnouncesNeedsInputOncePerEpisode() async {
        let (supervisor, _) = makeSupervisor()
        _ = await supervisor.startJob(instructions: "clean the logs")
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
        guard case .speak(let text)? = supervisor.takePendingNotice() else { return XCTFail("needs-input is spoken") }
        XCTAssertTrue(text.contains("clean the logs"))
        XCTAssertNil(supervisor.takePendingNotice())

        supervisor.observe(.toolStart(sessionId: "rt-1", toolName: "terminal", toolInput: nil))
        XCTAssertEqual(supervisor.jobs.first?.status, .running, "activity after the answer resumes the job")
        supervisor.observe(.approval(sessionId: "rt-1", activity: approval))
        XCTAssertNotNil(supervisor.takePendingNotice(), "a new approval is a new episode")
    }

    func testActiveJobLimitRefusesWithoutCreatingASession() async {
        let (supervisor, fake) = makeSupervisor()
        for index in 0..<VoiceBackgroundJobSupervisor.maximumActiveJobs {
            _ = await supervisor.startJob(instructions: "job \(index)")
        }
        let reply = await supervisor.startJob(instructions: "one too many")

        XCTAssertEqual(fake.created, VoiceBackgroundJobSupervisor.maximumActiveJobs)
        XCTAssertTrue(reply.contains("\(VoiceBackgroundJobSupervisor.maximumActiveJobs)"))
        XCTAssertEqual(supervisor.jobs.count, VoiceBackgroundJobSupervisor.maximumActiveJobs)
    }

    func testCancelAllInterruptsEveryActiveJobWithoutAnnouncingIt() async {
        let (supervisor, fake) = makeSupervisor()
        _ = await supervisor.startJob(instructions: "first")
        _ = await supervisor.startJob(instructions: "second")

        let reply = await supervisor.performVoiceCommand(.cancelAll)

        XCTAssertTrue(reply.contains("2"), "the reply counts the cancelled jobs")
        XCTAssertEqual(fake.cancelled, ["rt-1", "rt-2"])
        XCTAssertEqual(supervisor.jobs.map(\.status), [.cancelled, .cancelled])
        supervisor.observe(.messageInterrupted(sessionId: "rt-1"))
        XCTAssertNil(supervisor.takePendingNotice(), "the user already heard the cancellation")
        let again = await supervisor.cancelAll()
        XCTAssertEqual(again, AppLocalization.string("There are no background jobs to cancel."))
    }

    func testAFailedHermesCancelIsReportedAndTheJobStaysSupervised() async throws {
        let (supervisor, fake) = makeSupervisor()
        _ = await supervisor.startJob(instructions: "first")
        let jobID = try XCTUnwrap(supervisor.jobs.first?.id)
        fake.cancelError = HermesError.notConnected

        let reply = await supervisor.cancel(jobID: jobID)

        XCTAssertEqual(reply?.hasPrefix("Couldn't cancel"), true, reply ?? "nil")
        XCTAssertTrue(supervisor.jobs.first?.status.isActive == true, "a job Hermes didn't stop stays active")
        XCTAssertFalse(supervisor.jobs.first?.outcomeDelivered ?? true)
        let all = await supervisor.cancelAll()
        XCTAssertFalse(all.contains("Cancelled"), all)
    }

    func testFailedStartIsReportedInlineOnly() async {
        let (supervisor, fake) = makeSupervisor()
        fake.createError = HermesError.notConnected

        let reply = await supervisor.startJob(instructions: "anything")

        XCTAssertEqual(reply, AppLocalization.string("Couldn't start the background job."))
        XCTAssertEqual(supervisor.activeJobCount, 0)
        XCTAssertNil(supervisor.takePendingNotice(), "the failure was already spoken as the reply")
    }

    func testLivenessPollSettlesAJobWhoseCompletionEventWasMissed() async {
        let (supervisor, fake) = makeSupervisor()
        _ = await supervisor.startJob(instructions: "still going")
        _ = await supervisor.startJob(instructions: "gone quiet")
        fake.liveRows = [LiveSessionStatus(runtimeSessionId: "rt-1", storedSessionId: "st-1", status: "working")]

        await supervisor.pollOnce()
        XCTAssertEqual(supervisor.jobs.map(\.status), [.running, .running], "one missing row can be transient")
        XCTAssertNil(supervisor.takePendingNotice())
        await supervisor.pollOnce()

        XCTAssertEqual(supervisor.jobs.map(\.status), [.running, .finished], "a second miss settles the job")
        guard case .speak(let text)? = supervisor.takePendingNotice() else {
            return XCTFail("a finished job without a captured result points the user at its chat")
        }
        XCTAssertTrue(text.contains("gone quiet"))
    }

    func testTurnFailingDuringSubmitIsReportedAsAFailedStart() async {
        let (supervisor, fake) = makeSupervisor()
        fake.onSubmit = { id in supervisor.observe(.messageError(sessionId: id, message: "model unavailable")) }

        let reply = await supervisor.startJob(instructions: "doomed")

        XCTAssertEqual(reply, AppLocalization.string("Couldn't start the background job."))
        XCTAssertNil(supervisor.takePendingNotice(), "the failure was the reply; it is not announced twice")
    }

    func testFailedSubmitInterruptsTheCreatedSession() async {
        let (supervisor, fake) = makeSupervisor()
        fake.submitError = HermesError.timeout("prompt.submit")

        let reply = await supervisor.startJob(instructions: "lost ack")

        XCTAssertEqual(reply, AppLocalization.string("Couldn't start the background job."))
        XCTAssertEqual(fake.cancelled, ["rt-1"], "a turn Hermes may have accepted is interrupted, not left unmonitored")
        XCTAssertNil(supervisor.takePendingNotice())
    }

    func testActivityBetweenMissedPollsKeepsTheJobRunning() async {
        let (supervisor, _) = makeSupervisor()
        _ = await supervisor.startJob(instructions: "long task")

        await supervisor.pollOnce()
        supervisor.observe(.toolStart(sessionId: "rt-1", toolName: "terminal", toolInput: nil))
        await supervisor.pollOnce()

        XCTAssertEqual(supervisor.jobs.map(\.status), [.running], "misses separated by activity are not consecutive")
    }

    func testIdleRegistryRowSettlesAJobOnTheFirstPoll() async {
        let (supervisor, fake) = makeSupervisor()
        _ = await supervisor.startJob(instructions: "done already")
        fake.liveRows = [LiveSessionStatus(runtimeSessionId: "rt-1", storedSessionId: "st-1", status: "idle")]

        await supervisor.pollOnce()

        XCTAssertEqual(supervisor.jobs.map(\.status), [.finished])
    }

    func testCancelDuringSessionCreationNeverSubmitsTheJob() async {
        let (supervisor, fake) = makeSupervisor()
        fake.parksCreate = true
        let start = Task { await supervisor.startJob(instructions: "slow start") }
        await fake.createParked.waitUntil(1)

        _ = await supervisor.cancelAll()
        fake.releaseCreate()
        let reply = await start.value

        XCTAssertTrue(fake.submissions.isEmpty, "a job the user cancelled must never be submitted")
        XCTAssertEqual(fake.cancelled, ["rt-1"], "the session Hermes already created is interrupted")
        XCTAssertEqual(supervisor.jobs.map(\.status), [.cancelled])
        XCTAssertTrue(reply.contains("slow start"))
        XCTAssertNil(supervisor.takePendingNotice())
    }

    func testResetDuringSessionCreationInterruptsTheCreatedSession() async {
        let (supervisor, fake) = makeSupervisor()
        fake.parksCreate = true
        let start = Task { await supervisor.startJob(instructions: "old server") }
        await fake.createParked.waitUntil(1)

        supervisor.reset()
        fake.releaseCreate()
        _ = await start.value

        XCTAssertTrue(fake.submissions.isEmpty)
        XCTAssertEqual(fake.cancelled, ["rt-1"])
        XCTAssertTrue(supervisor.jobs.isEmpty)
    }

    func testSettledJobsArePrunedOnceAnnounced() async {
        let (supervisor, _) = makeSupervisor()
        let total = VoiceBackgroundJobSupervisor.maximumSettledJobs + 3
        for index in 1...total {
            _ = await supervisor.startJob(instructions: "job \(index)")
            supervisor.observe(.messageComplete(sessionId: "rt-\(index)", messageId: nil, content: "ok", reasoning: nil))
            XCTAssertNotNil(supervisor.takePendingNotice())
        }

        XCTAssertEqual(supervisor.jobs.count, VoiceBackgroundJobSupervisor.maximumSettledJobs)
        XCTAssertEqual(supervisor.jobs.last?.title, "job \(total)", "the most recent jobs are kept")
    }

    func testQueuedNoticeKeepsItsJobUntilSentOrHandedBack() async {
        let (supervisor, _) = makeSupervisor()
        _ = await supervisor.startJob(instructions: "queued job")
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "ok", reasoning: nil))
        let queued = supervisor.takePendingNoticeForJob()
        XCTAssertNotNil(queued)

        // A backlog of announced jobs would normally prune the oldest.
        let total = VoiceBackgroundJobSupervisor.maximumSettledJobs + 2
        for index in 2...total {
            _ = await supervisor.startJob(instructions: "job \(index)")
            supervisor.observe(.messageComplete(sessionId: "rt-\(index)", messageId: nil, content: "ok", reasoning: nil))
            XCTAssertNotNil(supervisor.takePendingNotice())
        }
        XCTAssertEqual(supervisor.jobs.first?.title, "queued job", "a notice not yet spoken keeps its job")

        // Handed back unspoken: the outcome is pending again.
        supervisor.returnUndeliveredNotice(jobID: queued!.jobID)
        XCTAssertNotNil(supervisor.takePendingNotice())

        XCTAssertEqual(supervisor.jobs.count, VoiceBackgroundJobSupervisor.maximumSettledJobs)
    }

    func testQueuedNoticeJobIsReleasedOnlyOnceItsSendIsConfirmed() async {
        let (supervisor, _) = makeSupervisor()
        let total = VoiceBackgroundJobSupervisor.maximumSettledJobs + 1
        var held: UUID?
        for index in 1...total {
            _ = await supervisor.startJob(instructions: "job \(index)")
            supervisor.observe(.messageComplete(sessionId: "rt-\(index)", messageId: nil, content: "ok", reasoning: nil))
            if index == 1 {
                held = supervisor.takePendingNoticeForJob()?.jobID
            } else {
                XCTAssertNotNil(supervisor.takePendingNotice())
            }
        }
        XCTAssertEqual(supervisor.jobs.first?.id, held, "still sending: the job stays")

        supervisor.noticeSent(jobID: held!)
        XCTAssertFalse(supervisor.jobs.contains { $0.id == held }, "sent: pruned like any announced job")
        XCTAssertEqual(supervisor.jobs.count, VoiceBackgroundJobSupervisor.maximumSettledJobs)
    }

    func testResetForgetsJobsAndIgnoresTheirLateEvents() async {
        let (supervisor, _) = makeSupervisor()
        _ = await supervisor.startJob(instructions: "old server work")
        supervisor.reset()
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "done", reasoning: nil))

        XCTAssertTrue(supervisor.jobs.isEmpty)
        XCTAssertNil(supervisor.takePendingNotice())
        XCTAssertEqual(supervisor.statusSummary(), AppLocalization.string("No background jobs are running."))
    }

    func testJobTitlesAreCutAtAWordBoundary() {
        let long = String(repeating: "word ", count: 30)
        let title = VoiceBackgroundJobSupervisor.title(for: long)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, VoiceBackgroundJobSupervisor.maximumTitleCharacters + 1)
        XCTAssertEqual(VoiceBackgroundJobSupervisor.title(for: "  short\n task "), "short task")
    }
}

// MARK: - Turns in the attached chat

@MainActor
extension VoiceConversationControllerTests {
    private func makeThreadSupervisor() -> (VoiceBackgroundJobSupervisor, FakeVoiceJobBackend) {
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(
            backend: fake.backend,
            pollInterval: .seconds(3_600),
            threadWaitInterval: .milliseconds(5)
        )
        supervisor.liveThread = VoiceThreadTarget(runtimeSessionID: "rt-chat", storedSessionID: "st-chat", title: "Build")
        return (supervisor, fake)
    }

    @discardableResult
    private func waitFor(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if condition() { return true }
        XCTFail("Timed out waiting for the condition", file: file, line: line)
        return false
    }

    func testAThreadTurnIsTheChatsNextTurnNotANewSession() async {
        let (supervisor, fake) = makeThreadSupervisor()

        let sent = supervisor.startThreadTurn(request: "check the build")
        await waitFor { !fake.threadSubmissions.isEmpty }

        XCTAssertNotNil(sent.jobID)
        XCTAssertEqual(fake.created, 0, "no session is created")
        XCTAssertEqual(fake.threadSubmissions.first?.0, "rt-chat")
        XCTAssertEqual(fake.threadSubmissions.first?.1, "(voice) check the build")
        XCTAssertEqual(supervisor.jobs.first?.status, .running)

        supervisor.observe(.messageComplete(sessionId: "st-chat", messageId: nil, content: "Build is green.", reasoning: nil))

        XCTAssertEqual(supervisor.jobs.first?.status, .finished)
        guard case .submit(let prompt, _)? = supervisor.takePendingNotice() else {
            return XCTFail("the reply goes back to the call")
        }
        XCTAssertTrue(prompt.contains("Hermes replied in the chat"))
        XCTAssertTrue(prompt.contains("Build is green."))
    }

    func testAThreadTurnWaitsForATypedTurnAndIgnoresItsEvents() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadBusy = true

        _ = supervisor.startThreadTurn(request: "and the tests?")
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(fake.threadSubmissions.isEmpty, "never steers or interrupts the typed turn")

        supervisor.observe(.messageComplete(sessionId: "rt-chat", messageId: nil, content: "typed answer", reasoning: nil))
        XCTAssertEqual(supervisor.jobs.first?.status, .starting, "the typed turn's reply isn't the voice turn's")

        fake.threadBusy = false
        await waitFor { !fake.threadSubmissions.isEmpty }
        XCTAssertEqual(fake.threadSubmissions.count, 1)
    }

    func testThreadTurnsGoOutOneAtATimeAndTooManyAreRefused() async {
        let (supervisor, fake) = makeThreadSupervisor()
        for index in 1...VoiceBackgroundJobSupervisor.maximumThreadTurns {
            XCTAssertNotNil(supervisor.startThreadTurn(request: "request \(index)").jobID)
        }
        let refused = supervisor.startThreadTurn(request: "one more")
        XCTAssertNil(refused.jobID)
        XCTAssertNotNil(refused.refusal)

        await waitFor { !fake.threadSubmissions.isEmpty }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fake.threadSubmissions.map(\.1), ["(voice) request 1"])

        supervisor.observe(.messageComplete(sessionId: "rt-chat", messageId: nil, content: "one", reasoning: nil))
        await waitFor { fake.threadSubmissions.count == 2 }
        XCTAssertEqual(fake.threadSubmissions.map(\.1), ["(voice) request 1", "(voice) request 2"])
    }

    func testEndingTheCallDropsTurnsStillWaiting() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadBusy = true
        _ = supervisor.startThreadTurn(request: "later")

        supervisor.detachLiveThread()
        fake.threadBusy = false
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(fake.threadSubmissions.isEmpty)
        XCTAssertEqual(supervisor.jobs.first?.status, .cancelled)
        XCTAssertNil(supervisor.takePendingNotice(), "nobody is on the call to tell")
        XCTAssertNil(supervisor.startThreadTurn(request: "after").jobID, "no chat to send to")
    }

    func testASentTurnOutlivesTheCallWithoutBeingAnnounced() async {
        let (supervisor, fake) = makeThreadSupervisor()
        _ = supervisor.startThreadTurn(request: "deploy")
        await waitFor { !fake.threadSubmissions.isEmpty }

        supervisor.detachLiveThread()
        supervisor.observe(.messageComplete(sessionId: "rt-chat", messageId: nil, content: "Deployed.", reasoning: nil))

        XCTAssertEqual(supervisor.jobs.first?.status, .finished, "it kept running in the chat")
        XCTAssertNil(supervisor.takePendingNotice(), "a later call doesn't bring it up")
    }

    func testAFailedThreadSubmitIsReported() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadSubmitError = URLError(.notConnectedToInternet)

        _ = supervisor.startThreadTurn(request: "check")
        await waitFor { supervisor.jobs.first?.status.isActive == false }

        guard case .failed? = supervisor.jobs.first?.status else {
            return XCTFail("\(String(describing: supervisor.jobs.first?.status))")
        }
    }

    func testThreadTurnsArentBackgroundJobs() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadBusy = true
        _ = supervisor.startThreadTurn(request: "check")

        XCTAssertEqual(supervisor.activeJobCount, 0)
        XCTAssertTrue(supervisor.backgroundJobs.isEmpty)
        XCTAssertEqual(supervisor.statusSummary(), AppLocalization.string("No background jobs are running."))
        let cancelled = await supervisor.cancelAll()
        XCTAssertEqual(cancelled, AppLocalization.string("There are no background jobs to cancel."))
        XCTAssertEqual(supervisor.jobs.first?.status, .starting)
        supervisor.detachLiveThread()
    }

    func testTheLastReplyIsReadWithoutANewTurn() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadReply = "Here is the full report."

        let reply = await supervisor.lastThreadReply()

        XCTAssertEqual(reply, "Here is the full report.")
        XCTAssertTrue(fake.threadSubmissions.isEmpty)
        XCTAssertTrue(supervisor.jobs.isEmpty)
    }

    func testGeminiAskThreadAnswersWithTheChatsReply() async {
        let (supervisor, fake) = makeThreadSupervisor()
        let bridge = GeminiLiveToolBridge(supervisor: supervisor)

        let immediate = await bridge.handle(GeminiLiveProtocol.FunctionCall(id: "call_1", name: "ask_thread", arguments: ["request": "summarize"]))
        XCTAssertEqual(immediate, [], "the call stays open while Hermes works")
        await waitFor { !fake.threadSubmissions.isEmpty }

        supervisor.observe(.messageComplete(sessionId: "rt-chat", messageId: nil, content: "Summary.", reasoning: nil))
        let updates = bridge.pendingUpdates()
        guard case .toolResponse(let id, let name, let result, _)? = updates.first, updates.count == 1 else {
            return XCTFail("\(updates)")
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "ask_thread")
        XCTAssertEqual(result["result"], "Summary.")
    }

    func testThreadToolsAreOfferedOnlyWhenAttached() {
        let plain = GeminiLiveToolBridge.declarations(webSearch: false).map(\.name)
        let attached = GeminiLiveToolBridge.declarations(webSearch: false, thread: true).map(\.name)
        XCTAssertFalse(plain.contains("ask_thread"))
        XCTAssertTrue(attached.contains("ask_thread"))
        XCTAssertTrue(attached.contains("read_last_reply"))
        XCTAssertTrue(attached.contains("start_job"), "background work stays available")
    }

    func testGPTLiveDelegationGoesToTheAttachedChatUnlessItAsksForBackgroundWork() async {
        let (supervisor, fake) = makeThreadSupervisor()
        let bridge = GPTLiveDelegationBridge(supervisor: supervisor)

        let immediate = await bridge.handleDelegation(id: "del_1", request: "what failed in the build?")
        guard case .delegationReply(_, _, .commentary)? = immediate.first else {
            return XCTFail("\(immediate)")
        }
        await waitFor { !fake.threadSubmissions.isEmpty }
        XCTAssertEqual(fake.created, 0)

        _ = await bridge.handleDelegation(id: "del_2", request: "research flights in the background")
        XCTAssertEqual(fake.created, 1, "background work is still a job")

        fake.threadReply = "The last reply."
        let read = await bridge.handleDelegation(id: "del_3", request: "Read the last reply word for word")
        guard case .delegationReply("del_3", let text, .speakable)? = read.first else {
            return XCTFail("\(read)")
        }
        XCTAssertTrue(text.contains("The last reply."))
        XCTAssertEqual(fake.threadSubmissions.count, 1, "reading the last reply asks Hermes nothing")
    }

    func testThreadRoutingPhrases() {
        XCTAssertTrue(VoiceThreadRouting.wantsBackgroundJob("Run this in the background: check prices"))
        XCTAssertFalse(VoiceThreadRouting.wantsBackgroundJob("what's the background of this issue"))
        XCTAssertTrue(VoiceThreadRouting.wantsLastReply("Read me Hermes' last reply"))
        XCTAssertTrue(VoiceThreadRouting.wantsLastReply("repeat the full reply"))
        XCTAssertFalse(VoiceThreadRouting.wantsLastReply("fix the bug from the last reply"))
        XCTAssertFalse(VoiceThreadRouting.wantsBackgroundJob("summarize the new chat feature"))
        XCTAssertFalse(VoiceThreadRouting.wantsBackgroundJob("rename this as a job title"))
        XCTAssertTrue(VoiceThreadRouting.wantsBackgroundJob("look into it in a new chat"))
        XCTAssertFalse(VoiceThreadRouting.wantsLastReply("what was the last reply in the thread about"),
                       "\"read\" inside \"thread\" isn't a request to read")
    }

    func testATurnOwnsTheResumedRuntimesEventsFromTheStart() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadRuntime = "rt-resumed"
        // The reply lands while the send is still returning.
        fake.onThreadSubmit = {
            supervisor.observe(.messageComplete(sessionId: "rt-resumed", messageId: nil, content: "Done.", reasoning: nil))
        }

        _ = supervisor.startThreadTurn(request: "check")
        await waitFor { supervisor.jobs.first?.status.isActive == false }

        XCTAssertEqual(supervisor.jobs.first?.status, .finished)
        XCTAssertEqual(supervisor.jobs.first?.result, "Done.")
    }

    func testATurnLeftRunningInAnotherChatDoesntHoldANewCall() async {
        let (supervisor, fake) = makeThreadSupervisor()
        _ = supervisor.startThreadTurn(request: "deploy")
        await waitFor { fake.threadSubmissions.count == 1 }
        supervisor.detachLiveThread()

        supervisor.liveThread = VoiceThreadTarget(runtimeSessionID: "rt-other", storedSessionID: "st-other", title: "Other")
        _ = supervisor.startThreadTurn(request: "status")
        await waitFor { fake.threadSubmissions.count == 2 }

        XCTAssertEqual(fake.threadSubmissions.last?.0, "rt-other")
        supervisor.detachLiveThread()
    }

    func testATypedTurnThatStartsDuringTheSendIsWaitedFor() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadSubmitError = VoiceThreadBusyError()

        _ = supervisor.startThreadTurn(request: "check")
        await waitFor { fake.threadSubmissions.count >= 1 }
        XCTAssertEqual(supervisor.jobs.first?.status, .starting, "back in line, not failed")

        fake.threadSubmitError = nil
        await waitFor { supervisor.jobs.first?.status == .running }
        XCTAssertEqual(supervisor.jobs.first?.threadTurnSubmitted, true)
        supervisor.detachLiveThread()
    }

    func testAThreadTurnSettledByThePollStillBringsBackTheChatsReply() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadReply = "Build is green."
        _ = supervisor.startThreadTurn(request: "check the build")
        await waitFor { supervisor.jobs.first?.status == .running }

        // The completion event never arrived; the runtime is gone.
        await supervisor.pollOnce()
        await supervisor.pollOnce()

        XCTAssertEqual(supervisor.jobs.first?.status, .finished)
        XCTAssertEqual(supervisor.jobs.first?.result, "Build is green.")
        guard case .submit(let prompt, _)? = supervisor.takePendingNotice() else {
            return XCTFail("the reply goes back to the call")
        }
        XCTAssertTrue(prompt.contains("Build is green."))
    }

    func testTurnsLeftRunningInAnotherChatDontCountAgainstANewCall() async {
        let (supervisor, fake) = makeThreadSupervisor()
        supervisor.detachLiveThread()
        // Earlier calls each left a sent turn running in their own chat.
        for index in 1...VoiceBackgroundJobSupervisor.maximumThreadTurns {
            supervisor.liveThread = VoiceThreadTarget(runtimeSessionID: "rt-\(index)", storedSessionID: nil, title: "Chat \(index)")
            _ = supervisor.startThreadTurn(request: "request \(index)")
            await waitFor { fake.threadSubmissions.count == index }
            supervisor.detachLiveThread()
        }
        XCTAssertEqual(supervisor.jobs.filter { $0.status.isActive }.count, VoiceBackgroundJobSupervisor.maximumThreadTurns)

        supervisor.liveThread = VoiceThreadTarget(runtimeSessionID: "rt-new", storedSessionID: nil, title: "New")
        XCTAssertNotNil(supervisor.startThreadTurn(request: "status").jobID)
        supervisor.detachLiveThread()
    }

    func testTheLastReplyFallbackNeverReadsAnotherChatsReply() async {
        let (supervisor, _) = makeThreadSupervisor()
        _ = supervisor.startThreadTurn(request: "check")
        guard await waitFor({ supervisor.jobs.first?.status == .running }) else { return }
        supervisor.observe(.messageComplete(sessionId: "rt-chat", messageId: nil, content: "Chat A's reply.", reasoning: nil))
        supervisor.detachLiveThread()

        supervisor.liveThread = VoiceThreadTarget(runtimeSessionID: "rt-empty", storedSessionID: nil, title: "Empty")
        let reply = await supervisor.lastThreadReply()

        XCTAssertNil(reply)
        supervisor.detachLiveThread()
    }

    func testATurnLeftByAnEndedCallYieldsToTheNewCallsTurn() async {
        let (supervisor, fake) = makeThreadSupervisor()
        _ = supervisor.startThreadTurn(request: "old")
        guard await waitFor({ supervisor.jobs.first?.status == .running }) else { return }
        supervisor.detachLiveThread()

        // A new call in the same chat; the old turn has finished meanwhile
        // but its completion never arrived.
        supervisor.liveThread = VoiceThreadTarget(runtimeSessionID: "rt-chat", storedSessionID: "st-chat", title: "Build")
        fake.threadBusy = false
        let new = supervisor.startThreadTurn(request: "new")
        // The old turn still holds the chat's queue until it settles.
        supervisor.observe(.messageComplete(sessionId: "rt-chat", messageId: nil, content: "old reply", reasoning: nil))
        guard await waitFor({ fake.threadSubmissions.count == 2 }) else { return }

        supervisor.observe(.messageComplete(sessionId: "rt-chat", messageId: nil, content: "new reply", reasoning: nil))
        let newJob = supervisor.jobs.first { $0.id == new.jobID }
        XCTAssertEqual(newJob?.result, "new reply")
        XCTAssertFalse(supervisor.backgroundJobs.contains { $0.id == new.jobID }, "a thread turn isn't listed as a job")
        XCTAssertEqual(supervisor.activeJobCount, 0)
        let fallback = await supervisor.lastThreadReply()
        XCTAssertEqual(fallback, "new reply", "the ended call's turn is never read back")
        supervisor.detachLiveThread()
    }

    func testHangingUpDuringASendThatFindsTheChatBusyDropsTheRequest() async {
        let (supervisor, fake) = makeThreadSupervisor()
        fake.threadSubmitError = VoiceThreadBusyError()
        fake.onThreadSubmit = { supervisor.detachLiveThread() }

        _ = supervisor.startThreadTurn(request: "later")
        guard await waitFor({ supervisor.jobs.first?.status == .cancelled }) else { return }
        fake.threadSubmitError = nil
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(fake.threadSubmissions.count, 1, "never sent again after the call ended")
        XCTAssertNil(supervisor.takePendingNotice())
    }

    func testTheLatestAssistantReplyIsReadFromSavedRows() {
        let rows: [Any] = [
            ["role": "user", "content": "check the build"],
            ["role": "assistant", "content": "Earlier answer."],
            ["role": "user", "content": "and now?"],
            ["role": "assistant", "content": "Build is green."],
        ]
        XCTAssertEqual(AppState.latestAssistantReply(inMessageRows: rows), "Build is green.")
        XCTAssertNil(AppState.latestAssistantReply(inMessageRows: [["role": "user", "content": "hi"]]))
    }
}

// MARK: - Voice controller integration

@MainActor
final class FakeVoiceBackgroundJobs: VoiceBackgroundJobHandling {
    var reply = "Started a background job."
    var pending: [VoiceBackgroundJobNotice] = []
    private(set) var commands: [VoiceBackgroundJobCommand] = []
    private(set) var takeCount = 0

    func performVoiceCommand(_ command: VoiceBackgroundJobCommand) async -> String {
        commands.append(command)
        return reply
    }

    func takePendingNotice() -> VoiceBackgroundJobNotice? {
        takeCount += 1
        return pending.isEmpty ? nil : pending.removeFirst()
    }
}

@MainActor
extension VoiceConversationControllerTests {
    private func makeJobController(
        transcript: String = "test",
        jobs: FakeVoiceBackgroundJobs?,
        submitResult: Bool = true
    ) -> (VoiceConversationController, MockCapture, MockGateway, SubmitSpy) {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: transcript, startsPlaybackOnOpen: true)
        let spy = SubmitSpy()
        let submitAction: @MainActor (String) async -> Bool = { text in
            _ = await spy.submit(text)
            return submitResult
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: submitAction,
            interrupt: { true },
            backgroundJobs: jobs
        )
        return (controller, capture, gateway, spy)
    }

    private func speakOneUtterance(_ controller: VoiceConversationController) async {
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
    }

    func testSpokenBackgroundJobIsConsumedLocallyAndConfirmedAloud() async {
        let jobs = FakeVoiceBackgroundJobs()
        let (controller, capture, gateway, spy) = makeJobController(
            transcript: "Background job, check the server.", jobs: jobs
        )

        await speakOneUtterance(controller)
        await gateway.waitUntilSpeechAppended(1)
        await capture.waitUntilStartCount(2)

        XCTAssertEqual(jobs.commands, [.start(instructions: "check the server")])
        XCTAssertEqual(spy.texts, [], "the command never reaches the voice session")
        XCTAssertEqual(gateway.stream?.appended, ["Started a background job."])
        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["Background job, check the server.", "Started a background job."])
        let listening = await controller.waitForState(.listening)
        XCTAssertTrue(listening, "the conversation keeps flowing after the confirmation")
    }

    func testWithoutTheJobSeamTheSameUtteranceIsAnOrdinaryTurn() async {
        let (controller, _, _, spy) = makeJobController(transcript: "Background job, check the server.", jobs: nil)

        await speakOneUtterance(controller)
        await spy.waitUntilSubmitted(1)

        XCTAssertEqual(spy.texts, ["Background job, check the server."])
    }

    func testFinishedJobHandBackIsSubmittedInAQuietListeningWindowAndSpoken() async {
        let jobs = FakeVoiceBackgroundJobs()
        jobs.pending = [.submit(prompt: "HAND-BACK", fallback: "Open it in Conduit.")]
        let (controller, capture, gateway, spy) = makeJobController(jobs: jobs)

        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        await spy.waitUntilSubmitted(1)

        XCTAssertEqual(spy.texts, ["HAND-BACK"])
        XCTAssertEqual(controller.state, .thinking)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "The server is fine."))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "The server is fine."))
        await gateway.waitUntilSpeechAppended(1)
        await capture.waitUntilStartCount(2)

        XCTAssertEqual(gateway.stream?.appended, ["The server is fine."], "the hand-back reply is spoken like any turn")
    }

    func testFailedHandBackSubmissionSpeaksTheFallback() async {
        let jobs = FakeVoiceBackgroundJobs()
        jobs.pending = [.submit(prompt: "HAND-BACK", fallback: "Open it in Conduit.")]
        let (controller, _, gateway, spy) = makeJobController(jobs: jobs, submitResult: false)

        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        await spy.waitUntilSubmitted(1)
        await gateway.waitUntilSpeechAppended(1)

        XCTAssertEqual(gateway.stream?.appended, ["Open it in Conduit."])
    }

    func testSilentHandBackIsReleasedWithTheFallback() async {
        let jobs = FakeVoiceBackgroundJobs()
        jobs.pending = [.submit(prompt: "HAND-BACK", fallback: "Open it in Conduit.")]
        let (controller, capture, gateway, spy) = makeJobController(jobs: jobs)
        controller.backgroundHandBackStartTimeout = .milliseconds(50)

        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        await spy.waitUntilSubmitted(1)
        await gateway.waitUntilSpeechAppended(1)
        await capture.waitUntilStartCount(2)

        XCTAssertEqual(gateway.stream?.appended, ["Open it in Conduit."])
        let listening = await controller.waitForState(.listening)
        XCTAssertTrue(listening, "later job updates are no longer blocked")
        // A reply that turns up after the release stays unowned.
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Late."))
        XCTAssertEqual(gateway.stream?.appended, ["Open it in Conduit."])
    }

    func testStartedHandBackReplyIsNeverReleasedByTheWatchdog() async {
        let jobs = FakeVoiceBackgroundJobs()
        jobs.pending = [.submit(prompt: "HAND-BACK", fallback: "Open it in Conduit.")]
        let (controller, _, _, spy) = makeJobController(jobs: jobs)
        controller.backgroundHandBackStartTimeout = .milliseconds(50)

        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        await spy.waitUntilSubmitted(1)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.state, .thinking, "a reply that began keeps ownership")
        XCTAssertFalse(controller.conversationTranscript.map(\.text).contains("Open it in Conduit."))
    }

    func testHandBackWaitsWhileATurnIsInFlight() async {
        let jobs = FakeVoiceBackgroundJobs()
        let (controller, _, _, spy) = makeJobController(transcript: "What's the weather?", jobs: jobs)

        await speakOneUtterance(controller)
        await spy.waitUntilSubmitted(1)
        XCTAssertEqual(controller.state, .thinking)
        jobs.pending = [.speak("Job finished.")]
        let takesBefore = jobs.takeCount

        controller.deliverPendingBackgroundJobNoticeIfIdle()

        XCTAssertEqual(jobs.takeCount, takesBefore, "nothing is taken while the user's own turn is pending")
        XCTAssertEqual(jobs.pending, [.speak("Job finished.")])
    }
}
