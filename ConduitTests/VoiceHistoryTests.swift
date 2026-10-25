//
//  VoiceHistoryTests.swift
//  Conduit
//
//  Saved live voice calls: the plugin client, the transcript recorder, the
//  outbox, the resume plan, and the Voice filters. Written as extensions of
//  an existing Voice suite: the CI test planner was at capacity for new
//  XCTestCase classes when this file landed (its sharded plan carries new
//  classes again — SessionNestingModelTests is its own suite).
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

    func makeRecorder(resuming: String? = nil, continuing: VoiceTranscriptRecorder? = nil) -> VoiceTranscriptRecorder {
        VoiceTranscriptRecorder(
            engine: .geminiLive,
            profile: "default",
            resumingSessionID: resuming,
            continuing: continuing,
            save: { [unowned self] request in
                self.requests.append(request)
                if !self.results.isEmpty { return try self.results.removeFirst().get() }
                let written = (request.turns.last?.index ?? -1) + 1
                if request.sessionID == nil, let chatID = request.chatID {
                    return VoiceTranscriptSaveResult(sessionID: nil, written: written, chatID: chatID)
                }
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

    func testVoiceHistorySaveGoesInPartsTheHostTakes() async throws {
        // The plugin takes at most 500 turns and 1 MiB per save
        // (plugin_api VOICE_MAX_TURNS, VOICE_MAX_BODY_BYTES).
        let turns = (0..<1_201).map {
            VoiceTranscriptTurn(index: $0, role: $0 % 2 == 0 ? .user : .assistant, text: "Turn \($0)", at: Date(timeIntervalSince1970: 10))
        }
        let script = ScriptedVoiceHistoryRequests()
        script.responses = [
            .success(["ok": true, "session_id": "row-1", "written": 500]),
            .success(["ok": true, "session_id": "row-1", "written": 1_000]),
            .success(["ok": true, "session_id": "row-1", "written": 1_201]),
        ]
        let client = VoiceHistoryClient(request: script.request)
        let result = try await client.save(
            VoiceTranscriptSaveRequest(callID: "c1", engine: .gptLive, sessionID: nil, title: "Long call", turns: turns),
            profile: "default"
        )
        XCTAssertEqual(result, VoiceTranscriptSaveResult(sessionID: "row-1", written: 1_201))
        XCTAssertEqual(script.calls.count, 3)
        let sent = script.calls.map { ($0.body?["turns"] as? [[String: Any]] ?? []).compactMap { $0["index"] as? Int } }
        XCTAssertEqual(sent.map(\.count), [500, 500, 201])
        XCTAssertEqual(sent.flatMap { $0 }, Array(0..<1_201))
        XCTAssertEqual(script.calls.map { $0.body?["call_id"] as? String }, ["c1", "c1", "c1"])
        // The first save makes the row; the rest append to it.
        XCTAssertEqual(script.calls.map { $0.body?["session_id"] as? String }, [nil, "row-1", "row-1"])
        XCTAssertEqual(script.calls.first?.body?["title"] as? String, "Long call")

        // A call kept with a chat goes to the chat each time.
        let chat = ScriptedVoiceHistoryRequests()
        chat.responses = [
            .success(["ok": true, "chat_id": "chat-1", "written": 500]),
            .success(["ok": true, "chat_id": "chat-1", "written": 600]),
        ]
        let chatResult = try await VoiceHistoryClient(request: chat.request).save(
            VoiceTranscriptSaveRequest(callID: "c2", engine: .gptLive, sessionID: nil, title: nil,
                                       turns: Array(turns.prefix(600)), chatID: "chat-1", chatProfile: "coder"),
            profile: "default"
        )
        XCTAssertEqual(chatResult, VoiceTranscriptSaveResult(sessionID: nil, written: 600, chatID: "chat-1"))
        XCTAssertEqual(chat.calls.map { $0.body?["chat_id"] as? String }, ["chat-1", "chat-1"])
        XCTAssertEqual(chat.calls.map(\.path), Array(repeating: DashboardPath.withProfile(VoiceHistoryClient.sessionsPath, profile: "coder"), count: 2))

        // A plugin that makes a row for the chat's first part: the rest
        // append to that row in the chat's profile, where it is.
        let rowed = ScriptedVoiceHistoryRequests()
        rowed.responses = [
            .success(["ok": true, "session_id": "row-9", "written": 500]),
            .success(["ok": true, "session_id": "row-9", "written": 600]),
        ]
        _ = try await VoiceHistoryClient(request: rowed.request).save(
            VoiceTranscriptSaveRequest(callID: "c5", engine: .gptLive, sessionID: nil, title: nil,
                                       turns: Array(turns.prefix(600)), chatID: "chat-1", chatProfile: "coder"),
            profile: "default"
        )
        XCTAssertEqual(rowed.calls.map { $0.body?["session_id"] as? String }, [nil, "row-9"])
        XCTAssertEqual(rowed.calls.map(\.path), Array(repeating: DashboardPath.withProfile(VoiceHistoryClient.sessionsPath, profile: "coder"), count: 2))

        // Long turns: every body stays under 1 MiB.
        let long = (0..<40).map {
            VoiceTranscriptTurn(index: $0, role: .assistant, text: String(repeating: "é", count: 16_000), at: Date(timeIntervalSince1970: 10))
        }
        let sized = ScriptedVoiceHistoryRequests()
        sized.responses = (1...40).map { .success(["ok": true, "session_id": "row-2", "written": $0]) }
        _ = try await VoiceHistoryClient(request: sized.request).save(
            VoiceTranscriptSaveRequest(callID: "c3", engine: .gptLive, sessionID: "row-2", title: nil, turns: long),
            profile: "default"
        )
        XCTAssertGreaterThan(sized.calls.count, 1)
        for call in sized.calls {
            let bytes = try JSONSerialization.data(withJSONObject: try XCTUnwrap(call.body)).count
            XCTAssertLessThan(bytes, 1024 * 1024)
        }
        XCTAssertEqual(sized.calls.flatMap { ($0.body?["turns"] as? [[String: Any]] ?? []).compactMap { $0["index"] as? Int } }, Array(0..<40))

        // A part the host refuses fails the save: retried, the host skips
        // the turns it already has.
        let failing = ScriptedVoiceHistoryRequests()
        failing.responses = [
            .success(["ok": true, "session_id": "row-3", "written": 500]),
            .failure(DashboardTicketBridgeError.http(status: 503, detail: "busy")),
        ]
        do {
            _ = try await VoiceHistoryClient(request: failing.request).save(
                VoiceTranscriptSaveRequest(callID: "c4", engine: .gptLive, sessionID: nil, title: "Long call", turns: turns),
                profile: "default"
            )
            XCTFail("A refused part fails the save")
        } catch {}
        XCTAssertEqual(failing.calls.count, 2)
    }

    func testRecorderClipsAScreenTurnToWhatTheHostKeeps() throws {
        let recorder = RecorderHarness().makeRecorder()
        let markdown = "Here's the script:\n\n```swift\n" + String(repeating: "let value = 42\n", count: 1_300)
        let card = VoiceScreenCard(id: UUID(), title: "Script", markdown: markdown,
                                   callAnchor: VoiceJobCallAnchor(callID: UUID(), transcriptIndex: 0), shownAt: Date())
        recorder.screen(card)
        let text = try XCTUnwrap(recorder.turns.last?.text)
        // plugin_api VOICE_MAX_TURN_CHARS
        XCTAssertLessThanOrEqual(text.count, 16_000)
        XCTAssertTrue(text.hasPrefix("Script\n\nHere's the script:"))
        XCTAssertTrue(text.hasSuffix("\n```"), "The cut closes the code block it left open")

        // The cut counts code points, as the plugin does: 9,000 "é" written
        // as "e" plus a combining accent are 18,000 code points.
        let accents = String(repeating: "e\u{0301}", count: 9_000)
        let clipped = VoiceTranscriptRecorder.clipped(accents)
        XCTAssertLessThanOrEqual(clipped.unicodeScalars.count, VoiceTranscriptRecorder.maxTurnCharacters)
        XCTAssertTrue(accents.hasPrefix(clipped))
        // One character longer than the limit on its own is cut too.
        let one = "e" + String(repeating: "\u{0301}", count: 20_000)
        XCTAssertLessThanOrEqual(VoiceTranscriptRecorder.clipped(one).unicodeScalars.count, VoiceTranscriptRecorder.maxTurnCharacters)
        XCTAssertEqual(VoiceTranscriptRecorder.clipped("Short"), "Short")
        // A long fence left open gets a closer as long, still within the
        // limit; a ``` line inside it doesn't close it.
        let fence = String(repeating: "`", count: 30)
        let nested = VoiceTranscriptRecorder.clipped(fence + "md\n```\n" + String(repeating: "z\n", count: 9_000))
        XCTAssertLessThanOrEqual(nested.unicodeScalars.count, VoiceTranscriptRecorder.maxTurnCharacters)
        XCTAssertTrue(nested.hasSuffix("\n" + fence))

        // Spoken lines are as they were.
        recorder.note("Short line")
        XCTAssertEqual(recorder.turns.last?.text, "Short line")
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

    func testRecorderLeavesOutTheLinesTheEngineKeptFromItsLastCall() {
        let recorder = RecorderHarness().makeRecorder()
        // The engine clears its transcript when the call starts, which can be
        // after the recording's first capture.
        let stale = [entry(.user, "Plan the trip"), entry(.assistant, "Lisbon in May.")]
        recorder.ignore(stale)
        recorder.capture(stale, unsettled: [])
        XCTAssertTrue(recorder.turns.isEmpty)
        recorder.capture([entry(.user, "Add milk")], unsettled: [])
        XCTAssertEqual(recorder.turns.map(\.text), ["Add milk"])
        XCTAssertEqual(recorder.turns.map(\.index), [0])
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

    func testSavedWatchCallNotesEachJobWhereItStarted() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let turns: [WatchVoiceWire.DirectTurn] = [
            .init(role: .user, text: "Check the build", at: start),
            .init(role: .assistant, text: "On it.", at: start.addingTimeInterval(2)),
            .init(role: .user, text: "Thanks", at: start.addingTimeInterval(30)),
        ]
        let jobs: [WatchVoiceWire.DirectJob] = [
            .init(jobID: "j1", title: "Check the build", sessionID: "s1", startedAt: start.addingTimeInterval(1)),
            .init(jobID: "j2", title: "Late one", sessionID: nil, startedAt: start.addingTimeInterval(60)),
        ]
        let saved = AppState.watchCallTurns(turns, jobs: jobs)
        XCTAssertEqual(saved.map(\.text), [
            "Check the build",
            "Started a background job: Check the build. [Open job](conduit://session/s1)",
            "On it.",
            "Thanks",
            "Started a background job: Late one.",
        ])
        XCTAssertEqual(saved.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(saved[1].role, .assistant)
    }

    func testWatchJobLogKeepsEachJobOnceAndLearnsItsChat() {
        var log = WatchVoiceWire.DirectJobLog()
        log.started(jobID: "j1", title: "")
        log.heard(jobID: "j1", title: "Check the build", sessionID: "s1")
        log.heard(jobID: "j1", title: "Other", sessionID: nil)
        log.heard(jobID: "j2", title: "Heard first in news", sessionID: "")
        XCTAssertEqual(log.jobs.map(\.jobID), ["j1", "j2"])
        XCTAssertEqual(log.jobs.map(\.title), ["Check the build", "Heard first in news"])
        XCTAssertEqual(log.jobs.map(\.sessionID), ["s1", nil])
    }

    func testChatTurnNoteLinksTheChatTheCallIsAttachedTo() {
        let job = VoiceBackgroundJob(id: UUID(), title: "Check the build", instructions: "x", status: .starting, startedAt: Date())
        let stored = VoiceThreadTarget(runtimeSessionID: "rt-chat", storedSessionID: "st-chat", title: "Build")
        XCTAssertEqual(AppState.voiceThreadTurnNote(job, thread: stored), "Asked the chat: Check the build. [Open chat](conduit://session/st-chat)")
        let runtimeOnly = VoiceThreadTarget(runtimeSessionID: "rt-chat", storedSessionID: nil, title: "Build")
        XCTAssertEqual(AppState.voiceThreadTurnNote(job, thread: runtimeOnly), "Asked the chat: Check the build. [Open chat](conduit://session/rt-chat)")
    }

    /// The call screen's chat name opens the same chat as the note (#698).
    func testTheAttachedChatLinkPrefersItsStoredIDAndABotsProfile() {
        XCTAssertEqual(VoiceThreadTarget(runtimeSessionID: "rt", storedSessionID: "st", title: "A").appLink, .session(id: "st"))
        XCTAssertEqual(VoiceThreadTarget(runtimeSessionID: "rt", storedSessionID: "", title: "A").appLink, .session(id: "rt"))
        XCTAssertNil(VoiceThreadTarget(runtimeSessionID: "", storedSessionID: nil, title: "A").appLink)
        XCTAssertEqual(VoiceThreadTarget(runtimeSessionID: "rt", storedSessionID: "st", title: "Fam", profile: "fam").appLink, .bot(profile: "fam"))
        XCTAssertEqual(VoiceThreadTarget(runtimeSessionID: "rt", storedSessionID: nil, title: "A", profile: "").appLink, .session(id: "rt"))
    }

    func testABotChatIsLinkedThroughItsBot() throws {
        let link = ConduitAppLink.bot(profile: "fam")
        XCTAssertEqual(link.url.absoluteString, "conduit://bot/fam")
        XCTAssertEqual(ConduitAppLink(url: link.url), link)
        XCTAssertNil(ConduitAppLink(url: try XCTUnwrap(URL(string: "conduit://bot/"))))
        // Its id only opens on the bot's profile, so the note names the bot.
        let job = VoiceBackgroundJob(id: UUID(), title: "Check the build", instructions: "x", status: .starting, startedAt: Date())
        let bot = VoiceThreadTarget(runtimeSessionID: "rt-bot", storedSessionID: "st-bot", title: "Fam", profile: "fam")
        XCTAssertEqual(AppState.voiceThreadTurnNote(job, thread: bot), "Asked the chat: Check the build. [Open chat](conduit://bot/fam)")
    }

    @MainActor
    func testABotLinkFindsItsBotExactlyFirstThenIgnoringCase() {
        func bot(_ name: String) -> BotProfile {
            BotProfile(
                name: name, botTitle: nil, displayName: "", profileDescription: "", model: nil, provider: nil,
                hasAvatar: false, isPinned: false, isHiddenByMeta: false, appearanceColor: nil,
                canonicalSession: nil, lastActive: nil, lastPreview: nil
            )
        }
        var renamed = bot("nova")
        renamed.previousNames = ["atlas-old", "atlas", "shared-old"]
        var other = bot("vega")
        other.previousNames = ["shared-old"]
        let roster = [bot("Fam"), bot("fam"), bot("atlas"), renamed, other]
        XCTAssertEqual(AppState.linkedBot(named: "fam", in: roster)?.name, "fam")
        XCTAssertEqual(AppState.linkedBot(named: "Atlas", in: roster)?.name, "atlas", "a live name outranks another bot's old one")
        XCTAssertEqual(AppState.linkedBot(named: "atlas-old", in: roster)?.name, "nova", "a link made before a rename")
        XCTAssertEqual(AppState.linkedBot(named: "Atlas-Old", in: roster)?.name, "nova")
        XCTAssertNil(AppState.linkedBot(named: "shared-old", in: roster), "an old name two bots had opens neither")
        XCTAssertNil(AppState.linkedBot(named: "orion", in: roster))
    }

    @MainActor
    func testABotLinkOnlySaysTheChatIsGoneWhenTheRosterWasRead() async throws {
        XCTAssertEqual(AppState.missingLinkedBotMessage(for: .available), AppLocalization.string("That chat is no longer available."))
        XCTAssertEqual(AppState.missingLinkedBotMessage(for: .failed(message: "Could not refresh bots.")), "Could not refresh bots.")
        XCTAssertEqual(AppState.missingLinkedBotMessage(for: .gatewayUnsupported), AppLocalization.string("Update Hermes to use Bot Mode."))
        XCTAssertEqual(AppState.missingLinkedBotMessage(for: .loading), AppLocalization.string("Could not load bots."))
        XCTAssertEqual(AppState.missingLinkedBotMessage(for: .idle), AppLocalization.string("Could not load bots."))

        // Offline, the link asks for a connection instead.
        let defaults = makeScratchDefaults("VoiceBotLinkOffline")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        XCTAssertFalse(appState.isConnected)
        appState.openAppLink(.bot(profile: "fam"))
        for _ in 0..<100 where appState.errorMessage == nil {
            await Task.yield()
        }
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("Connect to Hermes to chat with bots."))
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
            [.telegram, .chat, .voice, .voiceJob, .discord, .api, .webhook, .cron, .other]
        )
        XCTAssertEqual(AppState.normalizedSessionFilterOrder([]), AppState.defaultSessionFilterOrder)
        // A moved Voice filter keeps its place.
        XCTAssertEqual(
            AppState.normalizedSessionFilterOrder(["voice", "chat", "voice_job", "discord", "telegram", "api", "webhook", "other"]),
            [.voice, .chat, .voiceJob, .discord, .telegram, .api, .webhook, .cron, .other]
        )
    }
}

// MARK: - Outbox on a host that can't save yet (issue #290)

extension HermesVoiceGatewayTimeoutTests {
    func testOutboxKeepsCallsAHostCantSaveYetAndSavesThemOnceItCan() async throws {
        let defaults = makeScratchDefaults("VoiceOutboxBlockedHost")
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

// MARK: - A call the host refuses doesn't hold up the rest

extension HermesVoiceGatewayTimeoutTests {
    func testRefusedLocalLiveCallIsKeptAndTheCallsBehindItStillSave() async throws {
        let defaults = makeScratchDefaults("VoiceOutboxRefusedCall")
        defaults.set("default", forKey: "conduit.activeProfile")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        let script = ScriptedVoiceHistoryRequests()
        appState.voiceHistoryClient = VoiceHistoryClient(request: script.request)
        let dashboard = appState.activeDashboardID?.uuidString ?? "-"
        let turn = VoiceTranscriptTurn(index: 0, role: .user, text: "Hi", at: Date())
        var outbox = VoiceTranscriptOutbox()
        for (id, engine) in [("local", VoiceCallEngine.localLive), ("gemini", .geminiLive)] {
            outbox.add(.init(
                dashboard: dashboard, profile: appState.activeProfile,
                request: VoiceTranscriptSaveRequest(callID: id, engine: engine, sessionID: nil, title: "Call", turns: [turn]),
                queuedAt: Date()
            ))
        }
        outbox.store(in: defaults)

        // A plugin before 0.44.1 refuses the local-live engine.
        script.responses = [
            .failure(DashboardTicketBridgeError.http(status: 400, detail: "engine is missing or invalid")),
            .success(["ok": true, "session_id": "row-1", "written": 1])
        ]
        await appState.saveQueuedVoiceCallsNow()

        XCTAssertEqual(script.calls.count, 2, "the refused call doesn't stop the one behind it")
        XCTAssertEqual(VoiceTranscriptOutbox.load(from: defaults).entries.map(\.request.callID), ["local"], "the refused call is kept")
        XCTAssertEqual(appState.pendingVoiceCallSaves, 1)
        XCTAssertTrue(appState.voiceCallSavesBlocked, "Voice settings asks for a plugin update")
        let result = try XCTUnwrap(appState.voiceCallSaveNowResult, "Save Now says what happened")
        XCTAssertTrue(result.contains("engine is missing or invalid"), result)

        // Once the plugin takes it, the card clears with nothing left to say.
        script.responses = [.success(["ok": true, "session_id": "row-2", "written": 1])]
        await appState.saveQueuedVoiceCallsNow()
        XCTAssertTrue(VoiceTranscriptOutbox.load(from: defaults).entries.isEmpty)
        XCTAssertFalse(appState.voiceCallSavesBlocked)
        XCTAssertNil(appState.voiceCallSaveNowResult)
    }

    func testSaveNowSaysWhyNothingSavedWhenHermesFails() async throws {
        let defaults = makeScratchDefaults("VoiceOutboxSaveNowFailure")
        defaults.set("default", forKey: "conduit.activeProfile")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        let script = ScriptedVoiceHistoryRequests()
        appState.voiceHistoryClient = VoiceHistoryClient(request: script.request)
        var outbox = VoiceTranscriptOutbox()
        outbox.add(.init(
            dashboard: appState.activeDashboardID?.uuidString ?? "-", profile: appState.activeProfile,
            request: VoiceTranscriptSaveRequest(callID: "c1", engine: .gptLive, sessionID: nil, title: "Call",
                                                turns: [VoiceTranscriptTurn(index: 0, role: .user, text: "Hi", at: Date())]),
            queuedAt: Date()
        ))
        outbox.store(in: defaults)

        script.responses = [.failure(DashboardTicketBridgeError.http(status: 500, detail: ""))]
        await appState.saveQueuedVoiceCallsNow()

        XCTAssertEqual(appState.pendingVoiceCallSaves, 1)
        XCTAssertFalse(appState.voiceCallSavesBlocked, "a server error isn't a missing plugin")
        let result = try XCTUnwrap(appState.voiceCallSaveNowResult)
        XCTAssertTrue(result.contains("500"), result)
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

    @MainActor
    func testTheOpenSessionsOwnIDsNeverPullInARowSharingAnAlias() {
        func row(_ id: String, stored: String? = nil, alternates: [String] = []) -> SessionSummary {
            SessionSummary(
                id: id, storedSessionId: stored, alternateIds: alternates, title: id, model: "Hermes",
                updatedLabel: "now", profile: "default", source: .chat, isActive: false, isArchived: false,
                lineageRootId: nil
            )
        }
        let rows = [row("rt-1", stored: "st-1"), row("call-row", alternates: ["rt-1"])]
        let chatOwn = AppState.ownSessionIDs(for: "rt-1", in: rows)
        XCTAssertEqual(chatOwn, ["rt-1", "st-1"])
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "call-row", chat: "rt-1", stored: "st-1", at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(links.merge(into: [], chatIDs: ["rt-1", "st-1", "call-row"], openIDs: chatOwn, profile: "default").map(\.id), ["voice-call-c1"])
        XCTAssertEqual(AppState.ownSessionIDs(for: "call-row", in: rows), ["call-row"])
    }

    @MainActor
    func testANewChatShowsNoCardsFromTheChatOpenBeforeIt() {
        func row(_ id: String, stored: String? = nil, alternates: [String] = []) -> SessionSummary {
            SessionSummary(
                id: id, storedSessionId: stored, alternateIds: alternates, title: id, model: "Hermes",
                updatedLabel: "now", profile: "default", source: .chat, isActive: false, isArchived: false,
                lineageRootId: nil
            )
        }
        // A new chat's row is keyed by its stored id; its create recorded
        // the runtime's durable id.
        let rows = [row("st-new", alternates: ["rt-new"]), row("rt-old", stored: "st-old")]
        let own = AppState.ownSessionIDs(for: ["rt-new", "st-new"], in: rows)
        XCTAssertEqual(own, ["rt-new", "st-new"])
        var links = VoiceCallChatLinks()
        let start = Date(timeIntervalSince1970: 1_000)
        links.add(chatLink(call: "c1", row: "call-1", chat: "rt-old", stored: "st-old", at: start))
        links.add(chatLink(call: "c2", row: "call-2", chat: "rt-old", stored: "st-old", at: start.addingTimeInterval(60), resumed: true))
        links.add(chatLink(call: "c3", row: "call-3", chat: "rt-new", stored: "st-new", at: start.addingTimeInterval(120)))
        XCTAssertEqual(links.merge(into: [], chatIDs: own, openIDs: own, profile: "default").map(\.id), ["voice-call-c3"])
        // A row is never found through its alternate ids.
        XCTAssertEqual(AppState.ownSessionIDs(for: ["rt-new"], in: rows), ["rt-new"])
    }

    @MainActor
    func testANewChatsOwnIDsLeaveOutTheChatItWasStartedFrom() throws {
        func row(_ id: String, stored: String? = nil, alternates: [String] = []) -> SessionSummary {
            SessionSummary(
                id: id, storedSessionId: stored, alternateIds: alternates, title: id, model: "Hermes",
                updatedLabel: "now", profile: "default", source: .chat, isActive: false, isArchived: false,
                lineageRootId: nil
            )
        }
        let defaults = makeScratchDefaults("VoiceChatOwnIDs")
        defaults.set("default", forKey: "conduit.activeProfile")
        let index = ConversationIdentityIndex()
        let appState = AppState(defaults: defaults, loadSavedConnection: false, conversationIdentityIndex: index)
        appState.sessions = [row("rt-old", stored: "st-old")]
        appState.activeSessionId = "rt-old"

        // New chat: the reconciliation still names the chat open before it.
        _ = appState.beginReconciliation()
        appState.activeSessionId = "rt-new"
        index.recordAuthoritative(runtimeID: "rt-new", durableID: "st-new", profile: "default", source: .create)
        appState.sessions = [row("st-new", alternates: ["rt-new"]), row("rt-old", stored: "st-old")]

        XCTAssertTrue(appState.activeChatScrollSessionIdentity.contains("rt-old"), "the scroll identity keeps the previous chat")
        XCTAssertEqual(appState.chatOwnSessionIDsForTesting("rt-new"), ["rt-new", "st-new"])
        // Reopened later under another runtime, the index still names it.
        index.recordAuthoritative(runtimeID: "rt-new-2", durableID: "st-new", profile: "default", source: .resume)
        XCTAssertEqual(appState.chatOwnSessionIDsForTesting("rt-new-2"), ["rt-new-2", "st-new"])

        // A Bot Chat reads its mapping under the bot's profile first, and
        // falls back to one recorded under the dashboard's.
        appState.noteBotChatSessionForTesting("rt-bot", profile: "fam")
        index.recordAuthoritative(runtimeID: "rt-bot", durableID: "st-bot", profile: "default", source: .create)
        XCTAssertEqual(appState.chatOwnSessionIDsForTesting("rt-bot"), ["rt-bot", "st-bot"])
        index.recordAuthoritative(runtimeID: "rt-bot", durableID: "st-fam", profile: "fam", source: .resume)
        XCTAssertEqual(appState.chatOwnSessionIDsForTesting("rt-bot"), ["rt-bot", "st-fam"])
    }

    func testACallCardKeepsItsBotChatsProfile() throws {
        var link = chatLink(call: "c1", row: "call-row", chat: "rt-bot", stored: "st-bot", at: Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(link.thread.profile)
        // Cards saved before Bot Chats could take a call still decode.
        XCTAssertEqual(try JSONDecoder().decode(VoiceCallChatLink.self, from: JSONEncoder().encode(link)), link)
        link.chatProfile = "fam"
        XCTAssertEqual(link.thread.profile, "fam")
        XCTAssertEqual(link.thread.storedSessionID, "st-bot")
        XCTAssertEqual(try JSONDecoder().decode(VoiceCallChatLink.self, from: JSONEncoder().encode(link)), link)
    }

    func testAResumedCallShowsOneStartedFromCardPerChat() {
        let start = Date(timeIntervalSince1970: 1_000)
        var links = VoiceCallChatLinks()
        links.add(chatLink(call: "c1", row: "call-row", chat: "rt-1", stored: "st-1", at: start))
        links.add(chatLink(call: "c2", row: "call-row", chat: "rt-1", stored: "st-1", at: start.addingTimeInterval(600), resumed: true))
        links.add(chatLink(call: "c3", row: "call-row", chat: "rt-9", at: start.addingTimeInterval(1_200), resumed: true))
        XCTAssertEqual(links.merge(into: [], chatIDs: ["call-row"], openIDs: ["call-row"], profile: "default").map(\.id), ["voice-call-from-c1", "voice-call-from-c3"])


        // The chat had no stored id yet at the first start.
        var early = VoiceCallChatLinks()
        early.add(chatLink(call: "e1", row: "row-e", chat: "rt-1", at: start))
        early.add(chatLink(call: "e2", row: "row-e", chat: "rt-1", stored: "st-1", at: start.addingTimeInterval(600), resumed: true))
        XCTAssertEqual(early.merge(into: [], chatIDs: ["row-e"], openIDs: ["row-e"], profile: "default").map(\.id), ["voice-call-from-e1"])
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
        let defaults = makeScratchDefaults("VoiceOutboxChatLink")
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
        XCTAssertEqual(appState.voiceCallChatLinksRevision, 1, "the drawer re-arms its nest reveal when a link lands")
    }
}

extension HermesVoiceGatewayTimeoutTests {
    private func linkRow(_ id: String, stored: String? = nil, alternates: [String] = []) -> SessionSummary {
        SessionSummary(
            id: id, storedSessionId: stored, alternateIds: alternates, title: id, model: "Hermes",
            updatedLabel: "now", profile: "default", source: .chat, isActive: false, isArchived: false,
            lineageRootId: nil
        )
    }

    func testALinkToAnEndedRuntimeOpensTheStoredSessionLearnedForIt() {
        var aliases = VoiceSessionAliases()
        XCTAssertTrue(aliases.learn(runtimeID: "rt-job", storedID: "st-job"))
        XCTAssertFalse(aliases.learn(runtimeID: "rt-job", storedID: "st-job"), "already known")
        XCTAssertFalse(aliases.learn(runtimeID: "same", storedID: "same"))

        // The runtime is gone from the list; the job's row is listed by its stored id.
        XCTAssertEqual(AppState.linkedSessionTarget("rt-job", rows: [linkRow("st-job")], aliases: aliases), "st-job")
        // The row is listed under a new runtime that carries the stored id.
        XCTAssertEqual(AppState.linkedSessionTarget("rt-job", rows: [linkRow("rt-new", stored: "st-job")], aliases: aliases), "rt-new")
        // Not listed at all: still the stored id, never the dead runtime.
        XCTAssertEqual(AppState.linkedSessionTarget("rt-job", rows: [], aliases: aliases), "st-job")
        // A stored id in the link opens its row.
        XCTAssertEqual(AppState.linkedSessionTarget("st-job", rows: [linkRow("rt-new", stored: "st-job")], aliases: VoiceSessionAliases()), "rt-new")
        XCTAssertNil(AppState.linkedSessionTarget("rt-unknown", rows: [linkRow("st-job")], aliases: aliases))
    }

    func testSessionAliasesPersistAndStayBounded() {
        let suite = "VoiceSessionAliases-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var aliases = VoiceSessionAliases()
        for index in 0...(VoiceSessionAliases.maximumAliases) {
            aliases.learn(runtimeID: "rt-\(index)", storedID: "st-\(index)")
        }
        aliases.store(in: defaults)
        let loaded = VoiceSessionAliases.load(from: defaults)
        XCTAssertEqual(loaded.pairs.count, VoiceSessionAliases.maximumAliases)
        XCTAssertNil(loaded.storedID(forRuntime: "rt-0"))
        XCTAssertEqual(loaded.storedID(forRuntime: "rt-\(VoiceSessionAliases.maximumAliases)"), "st-\(VoiceSessionAliases.maximumAliases)")
    }
}

// MARK: - Calls kept with their chat (#556)

extension HermesVoiceGatewayTimeoutTests {
    func testVoiceHistorySaveSendsTheChatOnlyWhenTheCallHasNoRow() async throws {
        let script = ScriptedVoiceHistoryRequests()
        script.responses = [
            .success(["ok": true, "session_id": NSNull(), "chat_id": "st-chat", "written": 1]),
            .success(["ok": true, "session_id": "row-1", "written": 1]),
        ]
        let client = VoiceHistoryClient(request: script.request)
        let turn = VoiceTranscriptTurn(index: 0, role: .user, text: "Add milk", at: Date(timeIntervalSince1970: 10))
        let kept = try await client.save(
            VoiceTranscriptSaveRequest(callID: "c1", engine: .gptLive, sessionID: nil, title: nil, turns: [turn], chatID: "st-chat"),
            profile: "default"
        )
        XCTAssertEqual(kept, VoiceTranscriptSaveResult(sessionID: nil, written: 1, chatID: "st-chat"))
        XCTAssertEqual(script.calls[0].body?["chat_id"] as? String, "st-chat")
        _ = try await client.save(
            VoiceTranscriptSaveRequest(callID: "c1", engine: .gptLive, sessionID: "row-1", title: nil, turns: [turn], chatID: "st-chat"),
            profile: "default"
        )
        XCTAssertNil(script.calls[1].body?["chat_id"], "a call with a row appends to it")
        // A plugin that predates chat calls makes a row: the result says so.
        XCTAssertEqual(
            try VoiceHistoryClient.saveResult(from: ["ok": true, "session_id": "row-2", "chat_id": "st-chat", "written": 1]),
            VoiceTranscriptSaveResult(sessionID: "row-2", written: 1)
        )
    }

    func testABotChatsCallIsKeptWithItInTheBotsProfile() async throws {
        let script = ScriptedVoiceHistoryRequests()
        script.responses = [
            .success(["ok": true, "session_id": NSNull(), "chat_id": "st-bot", "written": 1]),
            .success(["ok": true, "session_id": "row-1", "written": 1]),
        ]
        let client = VoiceHistoryClient(request: script.request)
        let turn = VoiceTranscriptTurn(index: 0, role: .user, text: "Hi", at: Date(timeIntervalSince1970: 10))
        _ = try await client.save(
            VoiceTranscriptSaveRequest(callID: "c1", engine: .geminiLive, sessionID: nil, title: nil, turns: [turn], chatID: "st-bot", chatProfile: "coder"),
            profile: "default"
        )
        XCTAssertEqual(script.calls[0].path, DashboardPath.withProfile(VoiceHistoryClient.sessionsPath, profile: "coder"),
                       "saved where the Bot Chat lives")
        _ = try await client.save(
            VoiceTranscriptSaveRequest(callID: "c2", engine: .geminiLive, sessionID: "row-1", title: nil, turns: [turn], chatID: nil, chatProfile: "coder"),
            profile: "default"
        )
        XCTAssertEqual(script.calls[1].path, DashboardPath.withProfile(VoiceHistoryClient.sessionsPath, profile: "default"),
                       "a call with a row of its own stays on the call's profile")

        let bot = VoiceThreadTarget(runtimeSessionID: "rt", storedSessionID: "st-bot", title: "Coder", profile: "coder")
        XCTAssertEqual(AppState.voiceCallChatProfile(for: bot, profile: "default"), "coder")
        XCTAssertNil(AppState.voiceCallChatProfile(for: bot, profile: "coder"))
        XCTAssertNil(AppState.voiceCallChatProfile(
            for: VoiceThreadTarget(runtimeSessionID: "rt", storedSessionID: "st", title: "Chat"), profile: "default"))
    }

    func testARecorderKeepsItsBotChatsProfileOnEverySave() async {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder()
        recorder.chatID = "st-bot"
        recorder.chatProfile = "coder"
        let said = [entry(.user, "Hello"), entry(.assistant, "Hi")]
        recorder.capture(said, unsettled: [])
        await recorder.flush()
        XCTAssertEqual(harness.requests.first?.chatProfile, "coder")
        recorder.capture(said + [entry(.user, "Bye")], unsettled: [])
        XCTAssertEqual(recorder.outboxRequest?.chatProfile, "coder")
    }

    func testABotChatsCallMadeIntoARowKeepsSavingToTheBotsProfile() async {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder()
        recorder.chatID = "st-bot"
        recorder.chatProfile = "coder"
        // A plugin that predates chat calls makes a row of it, in the bot's profile.
        harness.results = [.success(VoiceTranscriptSaveResult(sessionID: "row-1", written: 1))]
        let hello = entry(.user, "Hello")
        recorder.capture([hello], unsettled: [])
        await recorder.flush()
        XCTAssertNil(harness.requests[0].rowProfile, "the first save goes by the chat's profile")
        XCTAssertEqual(recorder.rowProfile, "coder")

        let bye = entry(.user, "Bye")
        recorder.capture([hello, bye], unsettled: [])
        XCTAssertEqual(recorder.outboxRequest?.rowProfile, "coder")
        await recorder.flush()
        XCTAssertEqual(harness.requests[1].sessionID, "row-1")
        XCTAssertEqual(harness.requests[1].rowProfile, "coder")
        XCTAssertEqual(recorder.savedCallReplay?.rowProfile, "coder")

        // A reconnect goes on in the same row.
        let reconnect = harness.makeRecorder(continuing: recorder)
        let more = entry(.user, "One more")
        reconnect.capture([more], unsettled: [])
        await reconnect.flush()
        XCTAssertEqual(harness.requests[2].sessionID, "row-1")
        XCTAssertEqual(harness.requests[2].rowProfile, "coder")

        // The row is gone: the call is kept with its chat again.
        harness.results = [.failure(VoiceHistoryError.rowUnavailable)]
        reconnect.capture([more, entry(.user, "Last")], unsettled: [])
        await reconnect.flush()
        XCTAssertNil(reconnect.rowProfile)
        XCTAssertNil(harness.requests.last?.sessionID)
        XCTAssertNil(harness.requests.last?.rowProfile)
        XCTAssertEqual(harness.requests.last?.chatProfile, "coder")
    }

    func testABotChatsCallMadeIntoARowIsSavedThereFromTheOutbox() async throws {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder()
        recorder.chatID = "st-bot"
        recorder.chatProfile = "coder"
        // A plugin that predates chat calls makes a row of it, in the bot's profile.
        harness.results = [.success(VoiceTranscriptSaveResult(sessionID: "row-1", written: 1))]
        let hello = entry(.user, "Hello")
        recorder.capture([hello], unsettled: [])
        await recorder.flush()
        XCTAssertEqual(harness.requests.first?.chatProfile, "coder")
        recorder.capture([hello, entry(.user, "Bye")], unsettled: [])
        let request = try XCTUnwrap(recorder.outboxRequest)
        XCTAssertEqual(request.sessionID, "row-1")

        let defaults = makeScratchDefaults("VoiceOutboxBotChatRow")
        defaults.set("default", forKey: "conduit.activeProfile")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        let script = ScriptedVoiceHistoryRequests()
        appState.voiceHistoryClient = VoiceHistoryClient(request: script.request)
        var outbox = VoiceTranscriptOutbox()
        outbox.add(.init(
            dashboard: appState.activeDashboardID?.uuidString ?? "-", profile: appState.activeProfile,
            request: request, queuedAt: Date()
        ))
        outbox.store(in: defaults)

        script.responses = [.success(["ok": true, "session_id": "row-1", "written": 2])]
        await appState.saveQueuedVoiceCallsNow()

        XCTAssertEqual(script.calls.first?.path, DashboardPath.withProfile(VoiceHistoryClient.sessionsPath, profile: "coder"),
                       "appended to the row where it was made, not on the call's profile")
        XCTAssertEqual(script.calls.first?.body?["session_id"] as? String, "row-1")
        XCTAssertTrue(VoiceTranscriptOutbox.load(from: defaults).entries.isEmpty)
    }

    func testVoiceHistoryReadsAChatsCalls() async throws {
        let script = ScriptedVoiceHistoryRequests()
        script.responses = [.success(["ok": true, "chat_id": "st chat", "calls": [
            ["call_id": "c1", "engine": "gpt-live", "turns": [
                ["role": "user", "text": "What's on today?", "at": 10],
                ["role": "assistant", "text": " ", "at": 11],
                ["role": "assistant", "text": "Two meetings.", "at": 12],
                ["role": "tool", "text": "{\"ok\": true}", "at": 13],
            ]],
            ["engine": "gpt-live", "turns": []],
        ]])]
        let client = VoiceHistoryClient(request: script.request)
        let calls = try await client.chatCalls(chatID: "st chat", profile: "coder")
        XCTAssertEqual(calls.map(\.callID), ["c1"])
        XCTAssertEqual(calls.first?.turns.map(\.speaker), [.user, .assistant])
        XCTAssertEqual(calls.first?.turns.map(\.text), ["What's on today?", "Two meetings."], "only spoken turns")
        XCTAssertEqual(calls.first?.engine, .gptLive)
        XCTAssertEqual(script.calls.first?.method, "GET")
        XCTAssertEqual(
            script.calls.first?.path,
            DashboardPath.withProfile("\(VoiceHistoryClient.chatCallsPath)?chat_id=st%20chat", profile: "coder")
        )
        XCTAssertThrowsError(try VoiceHistoryClient.chatCalls(from: ["ok": false]))

        // A card reads just its own call.
        script.responses = [.success(["ok": true, "chat_id": "st chat", "calls": []])]
        _ = try await client.chatCalls(chatID: "st chat", callID: "c1", profile: "coder")
        XCTAssertEqual(
            script.calls.last?.path,
            DashboardPath.withProfile("\(VoiceHistoryClient.chatCallsPath)?chat_id=st%20chat&call_id=c1", profile: "coder")
        )
    }

    func testRecorderKeepsAnAttachedCallWithItsChatWithoutATitle() async {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder()
        recorder.chatID = "st-chat"
        let said = [entry(.user, "Call me when it's done"), entry(.assistant, "Will do.")]
        recorder.capture(said, unsettled: [])
        await recorder.flush()
        XCTAssertEqual(harness.requests.first?.chatID, "st-chat")
        XCTAssertNil(harness.requests.first?.sessionID)
        XCTAssertEqual(harness.titleRequests, 0, "no model call for a title")
        XCTAssertTrue(recorder.savedWithChat)
        XCTAssertNil(recorder.sessionID)
        XCTAssertNil(recorder.outboxRequest)

        recorder.capture(said + [entry(.user, "Thanks")], unsettled: [])
        XCTAssertEqual(recorder.outboxRequest?.chatID, "st-chat")
        await recorder.flush()
        XCTAssertEqual(harness.requests.last?.turns.map(\.index), [2])
        XCTAssertEqual(harness.requests.last?.chatID, "st-chat")
    }

    func testRecorderSavesTheWholeCallOnItsOwnWhenItsChatIsGone() async {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder()
        recorder.chatID = "st-chat"
        let one = entry(.user, "One")
        recorder.capture([one], unsettled: [])
        await recorder.flush()
        harness.results = [.failure(VoiceHistoryError.rowUnavailable)]
        recorder.capture([one, entry(.user, "Two")], unsettled: [])
        await recorder.flush()
        let retry = harness.requests.last
        XCTAssertNil(retry?.chatID)
        XCTAssertNil(retry?.sessionID)
        XCTAssertEqual(retry?.turns.map(\.text), ["One", "Two"])
        XCTAssertNotEqual(retry?.callID, harness.requests.first?.callID)
        XCTAssertEqual(recorder.sessionID, "row-1")
        XCTAssertFalse(recorder.savedWithChat)
    }

    func testAReconnectGoesOnAsTheSameCall() async {
        let harness = RecorderHarness()
        let first = harness.makeRecorder()
        first.chatID = "st-chat"
        first.capture([entry(.user, "Is the build done?"), entry(.assistant, "Not yet.")], unsettled: [])
        await first.flush()
        first.jobSessionIDs = ["job-1"]

        let second = harness.makeRecorder(continuing: first)
        XCTAssertTrue(first.handedOver)
        XCTAssertEqual(second.callID, first.callID)
        XCTAssertEqual(second.chatID, "st-chat")
        XCTAssertTrue(second.savedWithChat)
        XCTAssertEqual(second.jobSessionIDs, ["job-1"])
        second.note("Voice call resumed")
        second.capture([entry(.user, "Back again")], unsettled: [])
        await second.flush()
        XCTAssertEqual(harness.requests.last?.callID, first.callID)
        XCTAssertEqual(harness.requests.last?.turns.map(\.index), [2, 3])
        XCTAssertEqual(harness.requests.last?.chatID, "st-chat")
    }

    func testAReconnectResendsWhatTheEarlierSaveDidntConfirm() async {
        let harness = RecorderHarness()
        harness.results = [.failure(URLError(.notConnectedToInternet))]
        let first = harness.makeRecorder()
        first.chatID = "st-chat"
        first.capture([entry(.user, "Hello")], unsettled: [])
        await first.flush()
        let second = harness.makeRecorder(continuing: first)
        second.capture([entry(.user, "Still there?")], unsettled: [])
        XCTAssertEqual(second.outboxRequest?.turns.map(\.text), ["Hello", "Still there?"])
        XCTAssertEqual(second.outboxRequest?.callID, first.callID)
        let sent = harness.requests.count
        await first.flush()
        XCTAssertEqual(harness.requests.count, sent, "a handed-over recorder saves nothing more")
    }

    func testOnlyTheSameChatSoonAfterContinuesACall() {
        let ended = Date(timeIntervalSince1970: 1_000)
        func continues(_ chat: String?, profile: String = "default", after gap: TimeInterval) -> Bool {
            AppState.continuesChatCall(
                lastChatID: "st-chat", lastProfile: "default", endedAt: ended,
                chatID: chat, profile: profile, now: ended.addingTimeInterval(gap)
            )
        }
        XCTAssertTrue(continues("st-chat", after: 5))
        XCTAssertTrue(continues("st-chat", after: AppState.chatCallReconnectWindow))
        XCTAssertFalse(continues("st-chat", after: AppState.chatCallReconnectWindow + 1))
        XCTAssertFalse(continues("st-other", after: 5))
        XCTAssertFalse(continues(nil, after: 5))
        XCTAssertFalse(continues("st-chat", profile: "work", after: 5))
    }

    func testAReconnectIsSeededWithTheCallSoFar() {
        let at = Date(timeIntervalSince1970: 10)
        let turns = [
            VoiceTranscriptTurn(index: 0, role: .user, text: "Open the [report](conduit://session/abc)", at: at),
            VoiceTranscriptTurn(index: 1, role: .assistant, text: "Opened.", at: at),
        ]
        let context = VoiceResumeContext.continuing(turns)
        XCTAssertNil(context.summary)
        XCTAssertEqual(context.recent.map(\.speaker), [.user, .assistant])
        XCTAssertFalse(context.recent[0].text.contains("conduit://"))
        let long = (0..<40).map { VoiceTranscriptTurn(index: $0, role: $0 % 2 == 0 ? .user : .assistant, text: "Turn \($0)", at: at) }
        XCTAssertEqual(VoiceResumeContext.continuing(long).recent.count, VoiceResumePlan.recentTurnCount)
    }

    func testACallKeptWithItsChatShowsItsCardAndNeverOwnsTheChat() {
        let start = Date(timeIntervalSince1970: 1_000)
        var links = VoiceCallChatLinks()
        let kept = VoiceCallChatLink(
            callID: "c1", callSessionID: "", chatRuntimeSessionID: "rt-1", chatStoredSessionID: "st-1",
            chatTitle: "Daily brief", profile: "default", startedAt: start, endedAt: start.addingTimeInterval(60), resumed: false
        )
        links.add(kept)
        XCTAssertTrue(kept.storedWithChat)
        // The chat shows the call's card, not a "Started from" card.
        XCTAssertEqual(links.merge(into: [], chatIDs: ["st-1"], openIDs: ["st-1", ""], profile: "default").map(\.id), ["voice-call-c1"])
        // Nothing nests under the call: it has no row.
        XCTAssertNil(links.chatKey(forCallIDs: ["", "st-1"], profile: "default"))
    }
}

// MARK: - Cards a live model showed

extension HermesVoiceGatewayTimeoutTests {
    func testRecorderKeepsWhatTheLiveModelShowedWithItsCards() throws {
        let harness = RecorderHarness()
        let recorder = harness.makeRecorder()
        let normalized: [[String: Any]] = [["type": "place", "places": [["name": "Tartine"]]]]
        let card = VoiceScreenCard(
            id: UUID(), title: "Breakfast", markdown: "", callAnchor: VoiceJobCallAnchor(callID: UUID(), transcriptIndex: 0),
            shownAt: Date(), cards: RichCard.cards(normalized), cardsJSON: try JSONSerialization.data(withJSONObject: normalized)
        )
        recorder.screen(card)
        let turn = try XCTUnwrap(recorder.turns.last)
        XCTAssertEqual(turn.role, .assistant)
        XCTAssertEqual(turn.text, "Breakfast")
        let sent = try XCTUnwrap(turn.payload["cards"] as? [[String: Any]])
        XCTAssertEqual((sent.first?["places"] as? [[String: Any]])?.first?["name"] as? String, "Tartine")

        let table = VoiceScreenCard(id: UUID(), title: "Forecast", markdown: "| Day | High |", callAnchor: card.callAnchor, shownAt: Date())
        recorder.screen(table)
        XCTAssertEqual(recorder.turns.last?.text, "Forecast\n\n| Day | High |")
        XCTAssertNil(recorder.turns.last?.payload["cards"], "Markdown alone sends no cards")

        // The outbox keeps turns as Codable: the cards survive it.
        let decoded = try JSONDecoder().decode(VoiceTranscriptTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(decoded, turn)
    }
}
