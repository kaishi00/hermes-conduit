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
