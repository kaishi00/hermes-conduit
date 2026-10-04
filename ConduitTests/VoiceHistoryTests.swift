//
//  VoiceHistoryTests.swift
//  Conduit
//
//  Saved live voice calls: the plugin client, the transcript recorder, the
//  outbox, the resume plan, and the Voice filters. Written as extensions of
//  an existing Voice suite: the CI test planner is at capacity for new
//  XCTestCase classes.
//

import XCTest
@testable import Conduit

@MainActor
private final class ScriptedVoiceHistoryRequests {
    var calls: [(path: String, method: String, body: [String: Any]?)] = []
    var responses: [Result<[String: Any], Error>] = []

    func request(_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any] {
        calls.append((path, method, body))
        guard !responses.isEmpty else { return ["ok": true] }
        return try responses.removeFirst().get()
    }
}

@MainActor
private final class RecorderHarness {
    var requests: [VoiceTranscriptSaveRequest] = []
    var results: [Result<VoiceTranscriptSaveResult, Error>] = []
    var titleRequests = 0
    var nextID = 1

    func makeRecorder(resuming: String? = nil) -> VoiceTranscriptRecorder {
        VoiceTranscriptRecorder(
            engine: .geminiLive,
            profile: "default",
            resumingSessionID: resuming,
            save: { [unowned self] request in
                self.requests.append(request)
                if !self.results.isEmpty { return try self.results.removeFirst().get() }
                let id = request.sessionID ?? "row-\(self.nextID)"
                if request.sessionID == nil { self.nextID += 1 }
                return VoiceTranscriptSaveResult(sessionID: id, written: (request.turns.last?.index ?? -1) + 1)
            },
            title: { [unowned self] _ in
                self.titleRequests += 1
                return "Groceries for the week"
            },
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }
}

private func entry(_ speaker: VoiceConversationTranscriptEntry.Speaker, _ text: String) -> VoiceConversationTranscriptEntry {
    VoiceConversationTranscriptEntry(speaker: speaker, text: text)
}

extension HermesVoiceGatewayTimeoutTests {
    // MARK: Plugin client

    func testVoiceHistorySaveSendsTheCallsTurnsToTheProfilesRoute() async throws {
        let script = ScriptedVoiceHistoryRequests()
        script.responses = [.success(["ok": true, "session_id": "20260930_1", "written": 2, "appended": 2, "created": true])]
        let client = VoiceHistoryClient(request: script.request)
        let turn = VoiceTranscriptTurn(index: 0, role: .user, text: "Add milk", at: Date(timeIntervalSince1970: 10))
        let result = try await client.save(
            VoiceTranscriptSaveRequest(callID: "c1", engine: .gptLive, sessionID: nil, title: "Groceries", turns: [turn]),
            profile: "coder"
        )
        XCTAssertEqual(result, VoiceTranscriptSaveResult(sessionID: "20260930_1", written: 2))
        let call = try XCTUnwrap(script.calls.first)
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, DashboardPath.withProfile(VoiceHistoryClient.sessionsPath, profile: "coder"))
        XCTAssertEqual(call.body?["call_id"] as? String, "c1")
        XCTAssertEqual(call.body?["engine"] as? String, "gpt-live")
        XCTAssertEqual(call.body?["title"] as? String, "Groceries")
        XCTAssertNil(call.body?["session_id"])
        let turns = try XCTUnwrap(call.body?["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.first?["role"] as? String, "user")
        XCTAssertEqual(turns.first?["index"] as? Int, 0)
        XCTAssertEqual(turns.first?["at"] as? Double, 10)
    }

    func testVoiceHistoryMapsThePluginsStatuses() {
        XCTAssertEqual(VoiceHistoryClient.mapped(.http(status: 404, detail: "")), .pluginMissing)
        XCTAssertEqual(VoiceHistoryClient.mapped(.http(status: 501, detail: "")), .unsupported)
        XCTAssertEqual(VoiceHistoryClient.mapped(.http(status: 409, detail: "")), .busy)
        XCTAssertEqual(VoiceHistoryClient.mapped(.http(status: 422, detail: "")), .rowUnavailable)
        XCTAssertNil(VoiceHistoryClient.mapped(.http(status: 500, detail: "")))
    }

    func testVoiceHistoryParsesTagsAndSkipsUnknownKinds() throws {
        let tags = try VoiceHistoryClient.tags(from: ["ok": true, "tags": [
            "a": ["kind": "call", "engine": "gemini-live"],
            "b": ["kind": "job", "parent_id": "a"],
            "c": ["kind": "classic"],
            "d": ["kind": "something-newer"],
            "e": "not a tag"
        ]])
        XCTAssertEqual(tags["a"], VoiceSessionTag(kind: .call, engine: "gemini-live"))
        XCTAssertEqual(tags["b"]?.category, .voiceJob)
        XCTAssertEqual(tags["c"]?.category, .voice)
        XCTAssertNil(tags["d"])
        XCTAssertNil(tags["e"])
        XCTAssertThrowsError(try VoiceHistoryClient.tags(from: ["ok": false]))
    }

    func testVoiceHistorySummaryNeedsTextAndCoveredTurns() {
        XCTAssertEqual(
            VoiceHistoryClient.summary(from: ["ok": true, "available": true, "text": "We planned meals.", "covers": 30]),
            VoiceResumeSummary(text: "We planned meals.", covers: 30)
        )
        XCTAssertNil(VoiceHistoryClient.summary(from: ["ok": true, "available": false, "text": "", "covers": 0]))
        XCTAssertNil(VoiceHistoryClient.summary(from: ["ok": true, "available": true, "text": "x", "covers": 0]))
    }

    // MARK: Recorder

    func testRecorderTakesOnlyTheSettledPrefixInOrder() {
        let recorder = RecorderHarness().makeRecorder()
        let user = entry(.user, "What's on my list?")
        let reply = entry(.assistant, "Milk and eggs.")
        let next = entry(.user, "Add bread")
        // The reply is still streaming: neither it nor anything after it is taken.
        recorder.capture([user, reply, next], unsettled: [reply.id])
        XCTAssertEqual(recorder.turns.map(\.text), ["What's on my list?"])
        recorder.capture([user, reply, next], unsettled: [])
        XCTAssertEqual(recorder.turns.map(\.text), ["What's on my list?", "Milk and eggs.", "Add bread"])
        XCTAssertEqual(recorder.turns.map(\.index), [0, 1, 2])
        // Seen entries are never taken twice.
        recorder.capture([user, reply, next], unsettled: [])
        XCTAssertEqual(recorder.turns.count, 3)
    }

    func testRecorderSavesNothingUntilTheUserSpeaks() async {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder()
        recorder.capture([entry(.assistant, "Hi, I'm here.")], unsettled: [])
        await recorder.flush()
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertNil(recorder.outboxRequest)
    }

    func testRecorderCreatesTheRowOnceThenSendsOnlyNewTurns() async {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder()
        let first = [entry(.user, "Plan dinners"), entry(.assistant, "Sure.")]
        recorder.capture(first, unsettled: [])
        await recorder.flush()
        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertNil(harness.requests[0].sessionID)
        XCTAssertEqual(harness.requests[0].title, "Groceries for the week")
        XCTAssertEqual(recorder.sessionID, "row-1")

        recorder.capture(first + [entry(.user, "Tacos on Friday")], unsettled: [])
        await recorder.flush()
        XCTAssertEqual(harness.requests.count, 2)
        XCTAssertEqual(harness.requests[1].sessionID, "row-1")
        XCTAssertNil(harness.requests[1].title)
        XCTAssertEqual(harness.requests[1].turns.map(\.index), [2])
        XCTAssertEqual(harness.requests[1].callID, harness.requests[0].callID)
        XCTAssertEqual(harness.titleRequests, 1)
        // Nothing new: no request.
        await recorder.flush()
        XCTAssertEqual(harness.requests.count, 2)
    }

    func testRecorderKeepsFailedTurnsForTheNextSaveAndTheOutbox() async {
        let harness = RecorderHarness()
        harness.results = [.failure(URLError(.notConnectedToInternet))]
        let recorder = harness.makeRecorder()
        recorder.capture([entry(.user, "Remind me"), entry(.assistant, "Okay.")], unsettled: [])
        await recorder.flush()
        XCTAssertNil(recorder.sessionID)
        XCTAssertEqual(recorder.outboxRequest?.turns.count, 2)
        await recorder.flush()
        XCTAssertEqual(harness.requests.count, 2)
        XCTAssertEqual(harness.requests[1].turns.map(\.index), [0, 1])
        XCTAssertNil(recorder.outboxRequest)
    }

    func testRecorderResavesTheCallAsANewRowWhenItsRowIsGone() async {
        let harness = RecorderHarness()
        harness.results = [.failure(VoiceHistoryError.rowUnavailable)]
        let recorder = harness.makeRecorder(resuming: "deleted-row")
        recorder.note("Voice call resumed")
        recorder.capture([entry(.user, "Where were we?")], unsettled: [])
        await recorder.flush()
        XCTAssertEqual(harness.requests.count, 2)
        XCTAssertEqual(harness.requests[0].sessionID, "deleted-row")
        XCTAssertNil(harness.requests[1].sessionID)
        XCTAssertNotEqual(harness.requests[1].callID, harness.requests[0].callID)
        XCTAssertEqual(harness.requests[1].turns.map(\.text), ["Voice call resumed", "Where were we?"])
        XCTAssertEqual(recorder.sessionID, "row-1")
    }

    func testRecorderStopsWhenTheHostCantStoreTranscripts() async {
        let harness = RecorderHarness()
        harness.results = [.failure(VoiceHistoryError.pluginMissing)]
        let recorder = harness.makeRecorder()
        recorder.capture([entry(.user, "Hello")], unsettled: [])
        await recorder.flush()
        XCTAssertTrue(recorder.isDisabled)
        recorder.capture([entry(.user, "Hello again")], unsettled: [])
        await recorder.flush()
        XCTAssertEqual(harness.requests.count, 1)
        // Kept for the outbox: the host may be updated before it gives up.
        XCTAssertEqual(recorder.outboxRequest?.turns.map(\.text), ["Hello", "Hello again"])
    }

    func testRecorderResumingAppendsToTheRowWithoutATitle() async {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder(resuming: "row-9")
        recorder.note("Voice call resumed")
        recorder.capture([entry(.user, "One more thing")], unsettled: [])
        await recorder.flush()
        XCTAssertEqual(harness.requests.first?.sessionID, "row-9")
        XCTAssertNil(harness.requests.first?.title)
        XCTAssertEqual(harness.titleRequests, 0)
        XCTAssertEqual(harness.requests.first?.turns.first?.role, .assistant)
    }

    // MARK: Outbox

    func testOutboxReplacesACallsEarlierEntryAndDropsOldOnes() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let turn = VoiceTranscriptTurn(index: 0, role: .user, text: "hi", at: now)
        func request(_ call: String, _ turns: [VoiceTranscriptTurn]) -> VoiceTranscriptSaveRequest {
            VoiceTranscriptSaveRequest(callID: call, engine: .geminiLive, sessionID: nil, title: nil, turns: turns)
        }
        var outbox = VoiceTranscriptOutbox()
        outbox.add(.init(dashboard: "d", profile: "p", request: request("c1", [turn]), queuedAt: now))
        outbox.add(.init(dashboard: "d", profile: "p", request: request("c1", [turn, turn]), queuedAt: now))
        outbox.add(.init(dashboard: "d", profile: "p", request: request("old", [turn]), queuedAt: now.addingTimeInterval(-VoiceTranscriptOutbox.maximumAge - 1)))
        XCTAssertEqual(outbox.entries.count, 2)
        XCTAssertEqual(outbox.entries.first?.request.turns.count, 2)
        outbox.prune(now: now)
        XCTAssertEqual(outbox.entries.map(\.request.callID), ["c1"])

        let defaults = UserDefaults(suiteName: "VoiceHistoryTests-\(UUID().uuidString)")!
        outbox.store(in: defaults)
        XCTAssertEqual(VoiceTranscriptOutbox.load(from: defaults), outbox)
        VoiceTranscriptOutbox().store(in: defaults)
        XCTAssertNil(defaults.data(forKey: VoiceTranscriptOutbox.storageKey))
    }

    func testOutboxKeepsACallsJobsAndReadsEntriesWithout() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let turn = VoiceTranscriptTurn(index: 0, role: .user, text: "hi", at: now)
        let request = VoiceTranscriptSaveRequest(callID: "c1", engine: .geminiLive, sessionID: nil, title: nil, turns: [turn])
        var outbox = VoiceTranscriptOutbox()
        outbox.add(.init(dashboard: "d", profile: "p", request: request, queuedAt: now))
        // Saved before entries had jobs: the field is simply absent.
        let data = try JSONEncoder().encode(outbox)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("jobSessionIDs"))
        outbox = try JSONDecoder().decode(VoiceTranscriptOutbox.self, from: data)
        XCTAssertNil(outbox.entries.first?.jobSessionIDs)

        outbox.addJobs(["j1"], toCall: "c1")
        outbox.addJobs(["j1", "j2"], toCall: "c1")
        outbox.addJobs(["j3"], toCall: "other")
        XCTAssertEqual(Set(outbox.entries.first?.jobSessionIDs ?? []), ["j1", "j2"])
        XCTAssertEqual(outbox.entries.count, 1)
    }

    // MARK: Resume

    private func resumeTurns(_ count: Int, length: Int = 10) -> [VoiceResumeTurn] {
        (0..<count).map { VoiceResumeTurn(speaker: $0.isMultiple(of: 2) ? .user : .assistant, text: "turn \($0) " + String(repeating: "x", count: length)) }
    }

    func testResumePlanKeepsShortRowsWordForWord() {
        let turns = resumeTurns(24)
        XCTAssertEqual(VoiceResumePlan.plan(turns: turns, stored: nil), .verbatim(turns))
    }

    func testResumePlanSummarizesTheOlderTurnsOfALongRow() {
        let turns = resumeTurns(40)
        guard case .needsSummary(let older, let covers, let recent) = VoiceResumePlan.plan(turns: turns, stored: nil) else {
            return XCTFail("a long row needs a summary")
        }
        XCTAssertEqual(covers, 30)
        XCTAssertEqual(older, Array(turns[..<30]))
        XCTAssertEqual(recent, Array(turns[30...]))
        // Long in characters, short in turns, counts as long too.
        let wordy = resumeTurns(8, length: 1_000)
        if case .verbatim = VoiceResumePlan.plan(turns: wordy, stored: nil) { XCTFail("6,000 characters is the cap") }
    }

    func testResumePlanReusesASummaryThatIsAFewTurnsBehind() {
        let turns = resumeTurns(40)
        let stored = VoiceResumeSummary(text: "Earlier: meal plans.", covers: 24)
        XCTAssertEqual(
            VoiceResumePlan.plan(turns: turns, stored: stored),
            .summarized(summary: "Earlier: meal plans.", recent: Array(turns[24...]))
        )
        // Too far behind, or covering turns the row no longer has: redo it.
        for stale in [VoiceResumeSummary(text: "old", covers: 10), VoiceResumeSummary(text: "odd", covers: 35)] {
            if case .summarized = VoiceResumePlan.plan(turns: turns, stored: stale) { XCTFail("\(stale.covers) must be redone") }
        }
    }

    func testResumeTurnsKeepOnlyUserAndAssistantText() {
        let rows: [Any] = [
            ["id": 1, "role": "user", "content": "Add milk"],
            ["id": 2, "role": "assistant", "content": [["type": "text", "text": "Added."]]],
            ["id": 3, "role": "tool", "tool_call_id": "t1", "content": "{\"secret\": 1}"],
            ["id": 4, "role": "assistant", "content": "   "],
            ["id": 5, "role": "system", "content": "rules"]
        ]
        XCTAssertEqual(VoiceResumePlan.turns(fromMessageRows: rows), [
            VoiceResumeTurn(speaker: .user, text: "Add milk"),
            VoiceResumeTurn(speaker: .assistant, text: "Added.")
        ])
    }

    func testResumeTurnsUnwrapEnvelopesAndDropHiddenScaffolding() {
        let rows: [Any] = [
            ["id": 1, "message": ["role": "user", "content": "Plan dinner"]],
            ["id": 2, "role": "user", "display_kind": "hidden", "content": "Compaction handoff: secret scaffolding"],
            ["id": 3, "payload": ["type": "assistant", "content": "Tacos on Friday."]]
        ]
        XCTAssertEqual(VoiceResumePlan.turns(fromMessageRows: rows), [
            VoiceResumeTurn(speaker: .user, text: "Plan dinner"),
            VoiceResumeTurn(speaker: .assistant, text: "Tacos on Friday.")
        ])
    }

    func testJobLinkRoundTripsAndStaysInsideItsLabel() throws {
        let link = ConduitAppLink.session(id: "20261003_172301_ab12cd")
        XCTAssertEqual(link.url.absoluteString, "conduit://session/20261003_172301_ab12cd")
        XCTAssertEqual(ConduitAppLink(url: link.url), link)
        XCTAssertNil(ConduitAppLink(url: try XCTUnwrap(URL(string: "https://session/abc"))))
        XCTAssertNil(ConduitAppLink(url: try XCTUnwrap(URL(string: "conduit://session/"))))
        XCTAssertNil(ConduitAppLink(url: try XCTUnwrap(URL(string: "conduit://other/abc"))))
        XCTAssertEqual(link.markdown(label: "Open [job]"), "[Open \\[job\\]](conduit://session/20261003_172301_ab12cd)")
    }

    func testJobStartedNoteLinksTheJobsStoredChat() {
        var job = VoiceBackgroundJob(id: UUID(), title: "Find a dinner recipe", instructions: "x", status: .running, startedAt: Date())
        XCTAssertEqual(AppState.voiceJobStartedNote(job), "Started a background job: Find a dinner recipe.")
        job.runtimeSessionID = "runtime-1"
        job.storedSessionID = ""
        XCTAssertEqual(AppState.voiceJobStartedNote(job), "Started a background job: Find a dinner recipe. [Open job](conduit://session/runtime-1)")
        job.storedSessionID = "stored-1"
        XCTAssertEqual(AppState.voiceJobStartedNote(job), "Started a background job: Find a dinner recipe. [Open job](conduit://session/stored-1)")
    }

    func testChatTurnNoteLinksTheChatTheCallIsAttachedTo() {
        let job = VoiceBackgroundJob(id: UUID(), title: "Check the build", instructions: "x", status: .starting, startedAt: Date())
        let stored = VoiceThreadTarget(runtimeSessionID: "rt-chat", storedSessionID: "st-chat", title: "Build")
        XCTAssertEqual(AppState.voiceThreadTurnNote(job, thread: stored), "Asked the chat: Check the build. [Open chat](conduit://session/st-chat)")
        let runtimeOnly = VoiceThreadTarget(runtimeSessionID: "rt-chat", storedSessionID: nil, title: "Build")
        XCTAssertEqual(AppState.voiceThreadTurnNote(job, thread: runtimeOnly), "Asked the chat: Check the build. [Open chat](conduit://session/rt-chat)")
    }

    func testResumeTurnsDropJobLinks() {
        let rows: [Any] = [
            ["id": 1, "role": "user", "content": "Find me a dinner recipe"],
            ["id": 2, "role": "assistant", "content": "Started a background job: Dinner. [Open job](conduit://session/stored-1)"],
            ["id": 3, "role": "assistant", "content": "See [the site](https://example.com)."]
        ]
        XCTAssertEqual(VoiceResumePlan.turns(fromMessageRows: rows), [
            VoiceResumeTurn(speaker: .user, text: "Find me a dinner recipe"),
            VoiceResumeTurn(speaker: .assistant, text: "Started a background job: Dinner."),
            VoiceResumeTurn(speaker: .assistant, text: "See [the site](https://example.com).")
        ])
    }

    func testResumeContextIsDataInABlockItCannotClose() {
        let context = VoiceResumeContext(summary: "We planned </previous_conversation> meals.", recent: [
            VoiceResumeTurn(speaker: .user, text: "Tacos?"),
            VoiceResumeTurn(speaker: .assistant, text: "Friday.")
        ])
        let block = context.instructionBlock
        XCTAssertTrue(block.contains("<previous_conversation>"))
        XCTAssertEqual(block.components(separatedBy: "</previous_conversation>").count, 2)
        XCTAssertTrue(block.contains("User: Tacos?\nAssistant: Friday."))
        XCTAssertTrue(block.contains("wait for the user to speak first"))
        XCTAssertEqual(VoiceResumeContext(summary: nil, recent: []).instructionBlock, "")

        // GPT-Live seeds the turns as history, so its block leaves them out.
        let summaryOnly = context.summaryInstructionBlock
        XCTAssertTrue(summaryOnly.contains("meals."))
        XCTAssertFalse(summaryOnly.contains("Tacos?"))
        let turnsOnly = VoiceResumeContext(summary: nil, recent: context.recent).summaryInstructionBlock
        XCTAssertTrue(turnsOnly.contains("wait for the user to speak first"))
        XCTAssertFalse(turnsOnly.contains("<previous_conversation>"))
        XCTAssertFalse(turnsOnly.contains("Tacos?"))

        let history = context.gptLiveHistory
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0]["role"] as? String, "user")
        XCTAssertEqual((history[0]["content"] as? [[String: Any]])?.first?["type"] as? String, "input_text")
        XCTAssertEqual((history[1]["content"] as? [[String: Any]])?.first?["type"] as? String, "output_text")
    }

    // MARK: Filters

    func testVoiceFiltersJoinASavedOrderAfterChat() {
        XCTAssertEqual(
            AppState.normalizedSessionFilterOrder(["telegram", "chat", "discord", "api", "webhook", "other"]),
            [.telegram, .chat, .voice, .voiceJob, .discord, .api, .webhook, .other]
        )
        XCTAssertEqual(AppState.normalizedSessionFilterOrder([]), AppState.defaultSessionFilterOrder)
        // A moved Voice filter keeps its place.
        XCTAssertEqual(
            AppState.normalizedSessionFilterOrder(["voice", "chat", "voice_job", "discord", "telegram", "api", "webhook", "other"]),
            [.voice, .chat, .voiceJob, .discord, .telegram, .api, .webhook, .other]
        )
    }
}

// MARK: - Outbox on a host that can't save yet (issue #290)

extension HermesVoiceGatewayTimeoutTests {
    func testOutboxKeepsCallsAHostCantSaveYetAndSavesThemOnceItCan() async throws {
        let suite = "VoiceOutboxBlockedHost.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set("default", forKey: "conduit.activeProfile")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        let script = ScriptedVoiceHistoryRequests()
        appState.voiceHistoryClient = VoiceHistoryClient(request: script.request)
        let dashboard = appState.activeDashboardID?.uuidString ?? "-"
        let turn = VoiceTranscriptTurn(index: 0, role: .user, text: "Add milk", at: Date())
        var outbox = VoiceTranscriptOutbox()
        outbox.add(.init(
            dashboard: dashboard, profile: appState.activeProfile,
            request: VoiceTranscriptSaveRequest(callID: "c1", engine: .gptLive, sessionID: nil, title: "Groceries", turns: [turn]),
            queuedAt: Date()
        ))
        outbox.store(in: defaults)

        script.responses = [.failure(DashboardTicketBridgeError.http(status: 404, detail: ""))]
        await appState.saveQueuedVoiceCallsNow()

        XCTAssertEqual(VoiceTranscriptOutbox.load(from: defaults).entries.map(\.request.callID), ["c1"], "the call is kept, not dropped")
        XCTAssertEqual(appState.pendingVoiceCallSaves, 1)
        XCTAssertTrue(appState.voiceCallSavesBlocked)

        script.responses = [.success(["ok": true, "session_id": "row-1", "written": 1])]
        await appState.saveQueuedVoiceCallsNow()

        XCTAssertTrue(VoiceTranscriptOutbox.load(from: defaults).entries.isEmpty)
        XCTAssertEqual(appState.pendingVoiceCallSaves, 0)
        XCTAssertFalse(appState.voiceCallSavesBlocked)
    }
}

// MARK: - Calls started from a chat

extension HermesVoiceGatewayTimeoutTests {
    private func chatLink(call: String, row: String, chat: String, stored: String? = nil, at start: Date, resumed: Bool = false, profile: String = "default") -> VoiceCallChatLink {
        VoiceCallChatLink(
            callID: call, callSessionID: row, chatRuntimeSessionID: chat, chatStoredSessionID: stored,
            chatTitle: "Build", profile: profile, startedAt: start, endedAt: start.addingTimeInterval(95), resumed: resumed
        )
    }

    func testVoiceCallMarkerLandsWhereTheCallStartedInItsOwnChatOnly() {
        let start = Date(timeIntervalSince1970: 1_000)
        let iso = ISO8601DateFormatter()
        let history = [
            ChatMessage(id: "a", role: .user, content: "before", timestamp: iso.string(from: start.addingTimeInterval(-60))),
            ChatMessage(id: "b", role: .user, content: "during", timestamp: iso.string(from: start.addingTimeInterval(30))),
        ]
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "call-row", chat: "rt-1", stored: "st-1", at: start))
        links.add(chatLink(call: "c2", row: "other-row", chat: "rt-2", at: start))
        links.add(chatLink(call: "c3", row: "call-row", chat: "rt-1", stored: "st-1", at: start, profile: "work"))

        let merged = links.merge(into: history, chatIDs: ["st-1"], openIDs: ["st-1"], profile: "default")
        XCTAssertEqual(merged.map(\.id), ["a", "voice-call-c1", "b"])
        XCTAssertEqual(merged[1].role, .system)
        XCTAssertEqual(merged[1].displayKind, VoiceCallChatLink.displayKind)
        XCTAssertEqual(links.link(markerID: "voice-call-c1")?.callSessionID, "call-row")
        // Merging again (a refresh) doesn't add a second marker.
        XCTAssertEqual(links.merge(into: merged, chatIDs: ["st-1"], openIDs: ["st-1"], profile: "default").count, 3)
        // A call later than every message goes last.
        XCTAssertEqual(links.merge(into: Array(history.prefix(1)), chatIDs: ["st-1"], openIDs: ["st-1"], profile: "default").last?.id, "voice-call-c1")
    }

    func testCallTranscriptLeadsBackToItsChatAndNeverShowsTheChatsCard() {
        let start = Date(timeIntervalSince1970: 1_000)
        let iso = ISO8601DateFormatter()
        let transcript = [
            ChatMessage(id: "t1", role: .user, content: "hello", timestamp: iso.string(from: start.addingTimeInterval(5))),
        ]
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "call-row", chat: "rt-1", stored: "st-1", at: start))

        // Opened, the call's row may carry the chat's ids too (a stale
        // runtime or reconciliation alias): it still gets the way back.
        let merged = links.merge(into: transcript, chatIDs: ["call-row", "rt-1", "st-1"], openIDs: ["call-row"], profile: "default")
        XCTAssertEqual(merged.map(\.id), ["voice-call-from-c1", "t1"])
        XCTAssertEqual(merged.first?.displayKind, VoiceCallChatLink.originDisplayKind)
        XCTAssertEqual(links.link(markerID: "voice-call-from-c1")?.chatSessionID, "st-1")
    }

    func testATranscriptNeverShowsAnotherCallFromTheSameChat() {
        let start = Date(timeIntervalSince1970: 1_000)
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "row-a", chat: "rt-1", stored: "st-1", at: start))
        links.add(chatLink(call: "c2", row: "row-b", chat: "rt-1", stored: "st-1", at: start.addingTimeInterval(60)))
        XCTAssertEqual(links.merge(into: [], chatIDs: ["row-a", "st-1"], openIDs: ["row-a"], profile: "default").map(\.id), ["voice-call-from-c1"])
        XCTAssertEqual(links.merge(into: [], chatIDs: ["st-1"], openIDs: ["st-1"], profile: "default").map(\.id), ["voice-call-c1", "voice-call-c2"])

        // Viewing the chat while its id set borrowed a call row's alias: the
        // chat keeps its cards.
        XCTAssertEqual(links.merge(into: [], chatIDs: ["st-1", "row-a"], openIDs: ["st-1"], profile: "default").map(\.id), ["voice-call-c1", "voice-call-c2"])
    }

    func testAResumedCallShowsOneStartedFromCardPerChat() {
        let start = Date(timeIntervalSince1970: 1_000)
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "call-row", chat: "rt-1", stored: "st-1", at: start))
        links.add(chatLink(call: "c2", row: "call-row", chat: "rt-1", stored: "st-1", at: start.addingTimeInterval(600), resumed: true))
        links.add(chatLink(call: "c3", row: "call-row", chat: "rt-9", at: start.addingTimeInterval(1_200), resumed: true))
        XCTAssertEqual(links.merge(into: [], chatIDs: ["call-row"], openIDs: ["call-row"], profile: "default").map(\.id), ["voice-call-from-c1", "voice-call-from-c3"])
    }

    func testAChatIsMatchedOnItsStoredIDNotAReusedRuntime() {
        let start = Date(timeIntervalSince1970: 1_000)
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "call-row", chat: "rt-1", stored: "st-1", at: start))
        links.add(chatLink(call: "c2", row: "row-2", chat: "rt-2", at: start))
        XCTAssertTrue(links.merge(into: [], chatIDs: ["rt-1", "st-other"], openIDs: ["rt-1", "st-other"], profile: "default").isEmpty, "a later session under the chat's old runtime")
        XCTAssertEqual(links.merge(into: [], chatIDs: ["rt-2"], openIDs: ["rt-2"], profile: "default").map(\.id), ["voice-call-c2"], "no stored id: the runtime names it")
    }

    func testResumeCallGoesBackToTheChatTheCallWasLastAttachedTo() {
        let start = Date(timeIntervalSince1970: 1_000)
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "call-row", chat: "rt-1", stored: "st-1", at: start))
        links.add(chatLink(call: "c2", row: "call-row", chat: "rt-9", at: start.addingTimeInterval(600), resumed: true))
        let thread = links.latest(forCall: "call-row", profile: "default")?.thread
        XCTAssertEqual(thread?.runtimeSessionID, "rt-9")
        XCTAssertNil(thread?.storedSessionID)
        XCTAssertEqual(links.latest(forCall: "call-row", profile: "default").map { $0.marker.content }, "Voice call resumed")
        XCTAssertNil(links.latest(forCall: "call-row", profile: "work"))

        // The stored id is the chat's durable identity: resume targets it.
        let first = chatLink(call: "c1", row: "call-row", chat: "rt-1", stored: "st-1", at: start).thread
        XCTAssertEqual(first.runtimeSessionID, "st-1")
        XCTAssertTrue(first.owns(sessionID: "st-1"))
    }

    func testCallMovedToANewRowKeepsOneMarkerThatOpensTheNewRow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "old-row", chat: "rt-1", at: start))
        links.add(chatLink(call: "c1", row: "new-row", chat: "rt-1", at: start))
        XCTAssertEqual(links.links.count, 1)
        XCTAssertEqual(links.link(markerID: "voice-call-c1")?.callSessionID, "new-row")
    }

    func testVoiceCallLinksRoundTripAndStayBounded() throws {
        let suite = "voice-call-links-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var links = VoiceCallChatLinks()
        for index in 0..<(VoiceCallChatLinks.maximumLinks + 5) {
            links.add(chatLink(call: "c\(index)", row: "row", chat: "rt", at: Date(timeIntervalSince1970: Double(index))))
        }
        links.store(in: defaults)
        let loaded = VoiceCallChatLinks.load(from: defaults)
        XCTAssertEqual(loaded.links.count, VoiceCallChatLinks.maximumLinks)
        XCTAssertEqual(loaded.links.first?.callID, "c5")
        XCTAssertEqual(loaded, links)
    }
}

// MARK: - A call started from a chat, saved by the outbox

extension HermesVoiceGatewayTimeoutTests {
    func testCallSavedFromTheOutboxStillGetsItsChatMarker() async throws {
        let suite = "VoiceOutboxChatLink.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set("default", forKey: "conduit.activeProfile")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        let script = ScriptedVoiceHistoryRequests()
        appState.voiceHistoryClient = VoiceHistoryClient(request: script.request)
        // Recent: the outbox drops saves older than a week before retrying.
        let start = Date().addingTimeInterval(-600)
        let attachment = VoiceCallAttachment(
            thread: VoiceThreadTarget(runtimeSessionID: "rt-chat", storedSessionID: "st-chat", title: "Build"),
            callID: "c1", startedAt: start, resumed: false, endedAt: start.addingTimeInterval(120)
        )
        var outbox = VoiceTranscriptOutbox()
        outbox.add(.init(
            dashboard: appState.activeDashboardID?.uuidString ?? "-", profile: appState.activeProfile,
            request: VoiceTranscriptSaveRequest(callID: "c1", engine: .gptLive, sessionID: nil, title: "Build call",
                                                turns: [VoiceTranscriptTurn(index: 0, role: .user, text: "Hi", at: start)]),
            queuedAt: start, chatAttachment: attachment
        ))
        outbox.store(in: defaults)
        // The attachment survives the device store.
        XCTAssertEqual(VoiceTranscriptOutbox.load(from: defaults).entries.first?.chatAttachment, attachment)

        script.responses = [.success(["ok": true, "session_id": "row-1", "written": 1])]
        await appState.saveQueuedVoiceCallsNow()

        let link = try XCTUnwrap(appState.voiceCallLink(markerID: "voice-call-c1"))
        XCTAssertEqual(link.callSessionID, "row-1")
        XCTAssertEqual(link.chatStoredSessionID, "st-chat")
        XCTAssertEqual(link.endedAt, start.addingTimeInterval(120), "the call's own end, not when the retry saved it")
        XCTAssertEqual(VoiceCallChatLinks.load(from: defaults).latest(forCall: "row-1", profile: appState.activeProfile)?.thread.runtimeSessionID, "st-chat")
    }
}
