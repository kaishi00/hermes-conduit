import XCTest

@testable import Conduit

/// Bot workstreams: the Work panel's list as the plugin's `/workstreams`
/// route gives it, and a Bot Chat's work tool calls as transcript cards.
/// An extension of BotModeTests, so the test plan gains no class.
extension BotModeTests {
    private func workResponse() -> [String: Any] {
        [
            "ok": true, "policy": "strict", "bot": "Furina", "bot_chat": "botchat",
            "counts": ["working": 1, "needs_you": 1, "ready": 0, "waiting": 1],
            "work": [
                ["ref": "W1", "kind": "workstream", "status": "running", "title": "Login bug",
                 "session_id": "20261101_w1", "updated_at": 1_800_000_000.0, "closed": false,
                 "checklist": [["step": "Read the logs", "state": "done"], ["step": "Time DNS", "state": "doing"]],
                 "step": "terminal: command: dig", "uncertain": false, "actions": ["send", "stop"]],
                ["ref": "W2", "kind": "workstream", "status": "interrupted", "title": "Deploy",
                 "session_id": "20261101_w2", "error": "stopped by a restart during terminal: ./deploy.sh",
                 "uncertain": true, "actions": ["check", "continue", "stop", "send"]],
                ["ref": "A1", "kind": "ask_out", "status": "waiting", "title": "Calendar", "bot": "Nahida",
                 "actions": []],
                ["ref": "W3", "kind": "workstream", "status": "done", "title": "Disk", "closed": true,
                 "session_id": "20261101_w3", "result": "12% free", "actions": ["send"]],
                ["ref": "", "kind": "workstream"],
            ],
        ]
    }

    func testWorkPanelReadsTheBotsWork() throws {
        let snapshot = try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina"))
        XCTAssertTrue(snapshot.isOn)
        XCTAssertEqual(snapshot.botName, "Furina")
        XCTAssertEqual(snapshot.items.map(\.ref), ["W1", "W2", "A1", "W3"])
        XCTAssertEqual(snapshot.active.map(\.ref), ["W1", "W2", "A1"])
        XCTAssertEqual(snapshot.recent.map(\.ref), ["W3"])
        XCTAssertEqual(snapshot.sessionIDs, ["20261101_w1", "20261101_w2", "20261101_w3"])
        let running = snapshot.items[0]
        XCTAssertEqual(running.doing, "Time DNS")
        XCTAssertEqual(running.doneCount, 1)
        XCTAssertEqual(running.actions, [.send, .stop])
        let cutOff = snapshot.items[1]
        XCTAssertTrue(cutOff.needsYou && cutOff.isUncertain)
        XCTAssertEqual(cutOff.actions, [.check, .continue, .stop, .send])
        XCTAssertEqual(snapshot.items[2].kind, .askOut)
        XCTAssertEqual(snapshot.items[2].otherBot, "Nahida")
        XCTAssertEqual(snapshot.item(forSession: ["20261101_w2"])?.ref, "W2")
        XCTAssertNotNil(snapshot.stripText)
    }

    func testWorkPanelRefusesAnAnswerThatIsntAList() {
        XCTAssertNil(BotWorkSnapshot(response: ["ok": false], profile: "furina"))
        XCTAssertNil(BotWorkSnapshot(response: ["ok": true], profile: "furina"))
        let off = BotWorkSnapshot(response: ["ok": true, "policy": "off", "work": []], profile: "furina")
        XCTAssertEqual(off?.isOn, false)
        XCTAssertNil(off?.stripText)
    }

    @MainActor
    func testWorkStoreFindsTheWorkstreamAChatIs() throws {
        let store = BotWorkStore()
        store.set(try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina")))
        XCTAssertEqual(store.workstream(forSession: ["rt-1", "20261101_w1"])?.item.ref, "W1")
        XCTAssertEqual(store.workstream(forSession: ["20261101_w1"])?.profile, "furina")
        XCTAssertNil(store.workstream(forSession: ["other"]))
        XCTAssertTrue(store.workstreamSessionIDs.contains("20261101_w3"))
        store.clear()
        XCTAssertTrue(store.workstreamSessionIDs.isEmpty)
    }

    /// Chats, search and All profiles leave a workstream's row out by any
    /// of its ids; a refusal and a tap in flight belong to one bot.
    @MainActor
    func testWorkStoreKeepsEachBotsRowsRefusalsAndTapsApart() throws {
        let store = BotWorkStore()
        store.set(try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina")))
        func row(_ id: String, stored: String? = nil) -> SessionSummary {
            SessionSummary(id: id, storedSessionId: stored, alternateIds: [], title: "Chat", model: "Hermes",
                           updatedLabel: "now", lastActivityAt: nil, profile: "furina", source: .chat,
                           isActive: false, isArchived: false, lineageRootId: nil)
        }
        XCTAssertTrue(store.isWorkstream(row("20261101_w2")))
        XCTAssertTrue(store.isWorkstream(row("rt-9", stored: "20261101_w1")))
        XCTAssertFalse(store.isWorkstream(row("20261101_other")))

        XCTAssertTrue(store.begin("W1", profile: "furina"))
        XCTAssertFalse(store.begin("W1", profile: "furina"))
        XCTAssertTrue(store.begin("W1", profile: "nahida"))  // another bot's W1
        XCTAssertTrue(store.isActing("W1", profile: "furina"))
        store.end("W1", profile: "furina")
        XCTAssertFalse(store.isActing("W1", profile: "furina"))
        XCTAssertTrue(store.isActing("W1", profile: "nahida"))

        store.setRefusal("W1 can't continue while it's running.", profile: "furina")
        XCTAssertNotNil(store.refusal("furina"))
        XCTAssertNil(store.refusal("nahida"))

        XCTAssertTrue(store.beginReading("furina"))
        XCTAssertFalse(store.beginReading("furina"))  // the panel shares the strip's read
        store.endReading("furina")
        store.clear()
        XCTAssertNil(store.refusal("furina"))
        XCTAssertFalse(store.isWorkstream(row("20261101_w2")))
    }

    func testWorkToolCallsDrawAsWorkCards() throws {
        let started = try XCTUnwrap(BotWorkCall.parse(
            toolName: "work_start",
            input: #"{"title": "Login bug", "instructions": "Find out why"}"#,
            output: #"{"ok": true, "ref": "W3", "title": "Login bug", "link": "[Open W3](conduit://session/20261101_w3?profile=furina)"}"#
        ))
        XCTAssertEqual(started.tool, .start)
        XCTAssertEqual(started.ref, "W3")
        XCTAssertEqual(started.sessionID, "20261101_w3")
        XCTAssertEqual(started.profile, "furina")
        XCTAssertNotNil(started.title(running: false))
        // Behind Tool Search the model calls it through tool_call.
        let bridged = try XCTUnwrap(BotWorkCall.parse(
            toolName: "tool_call",
            input: #"{"name": "work_send", "arguments": {"ref": "w1", "text": "Also the logs"}}"#,
            output: nil
        ))
        XCTAssertEqual(bridged.tool, .send)
        XCTAssertEqual(bridged.ref, "W1")
        XCTAssertEqual(bridged.text, "Also the logs")
        // A refusal keeps the step's own words.
        let refused = try XCTUnwrap(BotWorkCall.parse(
            toolName: "work_stop", input: #"{"ref": "W9"}"#, output: #"{"ok": false, "error": "no_such_work"}"#
        ))
        XCTAssertNil(refused.title(running: false))
        let unread = try XCTUnwrap(BotWorkCall.parse(
            toolName: "work_stop", input: #"{"ref": "W3"}"#, output: "Tool failed: bridge closed"
        ))
        XCTAssertNil(unread.title(running: false))
        XCTAssertNil(BotWorkCall.parse(toolName: "terminal", input: #"{"command": "ls"}"#, output: nil))
        XCTAssertNil(BotWorkCall.parse(toolName: "tool_call", input: #"{"name": "terminal"}"#, output: nil))
    }
}
