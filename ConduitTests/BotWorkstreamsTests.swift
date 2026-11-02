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

    /// A Stop moves the strip's counts at once, before the next read.
    func testAReplacedRowMovesTheCounts() throws {
        let snapshot = try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina"))
        let stopped = try XCTUnwrap(BotWorkItem(row: ["ref": "W1", "kind": "workstream", "status": "stopped",
                                                      "session_id": "20261101_w1", "actions": ["continue", "send"]]))
        let after = snapshot.replacing(stopped)
        XCTAssertEqual(after.workingCount, 0)
        XCTAssertEqual(after.needsYouCount, 1)
        XCTAssertEqual(after.items.first?.status, "stopped")
        XCTAssertEqual(snapshot.replacing(try XCTUnwrap(BotWorkItem(row: ["ref": "W9", "kind": "workstream"]))), snapshot)
    }

    /// Pin, Resolve and Reopen: what the plugin offers, and the list as
    /// each leaves it before the next read.
    func testFilingWorkMovesItBetweenTheLists() throws {
        var response = workResponse()
        response["resolved_count"] = 4
        response["workstream_sessions"] = ["20261101_w1", "20261031_old"]
        var rows = response["work"] as? [[String: Any]] ?? []
        rows[0]["pinned"] = true
        rows[0]["manage"] = ["unpin"]
        response["work"] = rows
        let snapshot = try XCTUnwrap(BotWorkSnapshot(response: response, profile: "furina"))
        XCTAssertEqual(snapshot.pinned.map(\.ref), ["W1"])
        XCTAssertEqual(snapshot.active.map(\.ref), ["W2", "A1"])
        XCTAssertEqual(snapshot.items[0].manage, [.unpin])
        XCTAssertEqual(snapshot.resolvedCount, 4)
        // A resolved workstream's chat stays out of the chat lists.
        XCTAssertTrue(snapshot.sessionIDs.contains("20261031_old"))

        let resolved = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W2", "kind": "workstream", "status": "interrupted", "closed": true,
            "closed_at": 1_800_000_100.0, "resolved_by": "user", "manage": ["reopen"],
        ]))
        let after = snapshot.replacing(resolved)
        XCTAssertFalse(after.items.contains { $0.ref == "W2" })
        XCTAssertEqual(after.needsYouCount, 0)
        XCTAssertEqual(after.resolvedCount, 5)
        XCTAssertEqual(resolved.resolvedBy, "user")
        XCTAssertEqual(resolved.closedAt, Date(timeIntervalSince1970: 1_800_000_100))
        // Resolved before it finished: it reads as resolved, not as needing you.
        XCTAssertTrue(resolved.isResolvedUnfinished)
        XCTAssertEqual(resolved.statusText, AppLocalization.string("Resolved"))

        let reopened = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W2", "kind": "workstream", "status": "interrupted", "session_id": "20261101_w2",
            "manage": ["pin", "resolve"], "actions": ["continue", "stop", "send"],
        ]))
        let back = after.reopening(reopened)
        XCTAssertEqual(back.items.first?.ref, "W2")
        XCTAssertEqual(back.needsYouCount, 1)
        XCTAssertEqual(back.resolvedCount, 4)
    }

    /// A pin moves a row to Pinned; with only resolved work left the
    /// title line still opens the panel; a reopen leaves the Resolved list.
    @MainActor
    func testPinnedAndResolvedWorkStayReachable() throws {
        let snapshot = try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina"))
        let pinned = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W2", "kind": "workstream", "status": "interrupted", "pinned": true,
            "session_id": "20261101_w2", "manage": ["unpin", "resolve"],
        ]))
        let after = snapshot.replacing(pinned)
        XCTAssertEqual(after.pinned.map(\.ref), ["W2"])
        XCTAssertFalse(after.active.contains { $0.ref == "W2" })

        let onlyResolved = try XCTUnwrap(BotWorkSnapshot(
            response: ["ok": true, "policy": "strict", "work": [], "resolved_count": 2], profile: "furina"))
        XCTAssertNotNil(onlyResolved.stripText)

        let store = BotWorkStore()
        let resolved = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W3", "kind": "workstream", "status": "done", "closed": true, "closed_at": 1_800_000_000.0,
            "resolved_by": "bot", "session_id": "20261101_w3", "manage": ["reopen"],
        ]))
        XCTAssertFalse(resolved.needsYou)
        store.setResolvedList(BotWorkStore.ResolvedList(items: [resolved]), profile: "furina")
        XCTAssertEqual(store.workstream(forSession: ["20261101_w3"])?.item.ref, "W3")
        let reopened = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W3", "kind": "workstream", "status": "done", "session_id": "20261101_w3", "manage": ["pin", "resolve"],
        ]))
        store.fileResolved(reopened, profile: "furina")
        XCTAssertEqual(store.resolvedList("furina")?.items, [])
        // Resolved with no Resolved list read yet: its chat still knows it.
        let fresh = BotWorkStore()
        fresh.fileResolved(resolved, profile: "furina")
        XCTAssertEqual(fresh.workstream(forSession: ["20261101_w3"])?.item.ref, "W3")
        XCTAssertEqual(fresh.resolvedList("furina")?.more, true)  // the rest pages in after it
    }

    func testAWorkstreamsBriefReadsAsItsTask() throws {
        let text = "You're working on a task for Hermes, who coordinates the user's work in their Bot Chat. "
            + "This chat is that workstream (W45: Disk).\n\nThe user's message that Hermes is answering now, as "
            + "they wrote it (this is the user speaking; Hermes's own words are Hermes's):\n«Check how much disk "
            + "is free»\n\nTask:\nRun `df -h /` and return the Avail value.\nBefore a step that can't be undone "
            + "(deleting, sending), only the user's own words count."
        let brief = try XCTUnwrap(WorkstreamBrief.parse(text))
        XCTAssertEqual(brief.bot, "Hermes")
        XCTAssertEqual(brief.task, "Run `df -h /` and return the Avail value.")
        XCTAssertEqual(brief.userWords, "Check how much disk is free")
        XCTAssertNil(WorkstreamBrief.parse("Run df -h / please.\n\nTask:\nNothing"))
        XCTAssertNil(WorkstreamBrief.parse("You're working on a task for Hermes, who coordinates it."))
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

    /// Lists already shown hear when a workstream becomes known, and only then.
    @MainActor
    func testWorkStoreSaysWhenItsWorkstreamsChange() throws {
        let store = BotWorkStore()
        var changes = 0
        store.onWorkstreamsChanged = { changes += 1 }
        let snapshot = try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina"))
        store.set(snapshot)
        XCTAssertEqual(changes, 1)
        store.setRefusal("No.", profile: "furina")
        XCTAssertEqual(changes, 1)
        store.clear()
        XCTAssertEqual(changes, 2)
    }

    /// A workstream that becomes known after All profiles listed it leaves
    /// the list at once, without waiting for All's next read.
    @MainActor
    func testAWorkstreamReadLaterLeavesAllProfiles() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        func row(_ id: String) -> SessionSummary {
            SessionSummary(id: id, storedSessionId: nil, alternateIds: [], title: "Chat", model: "Hermes",
                           updatedLabel: "now", lastActivityAt: nil, profile: "furina", source: .chat,
                           isActive: false, isArchived: false, lineageRootId: nil)
        }
        appState.allProfilesCatalog = AllProfilesCatalog(dashboardID: nil, sessions: [row("20261101_w1"), row("plain")],
                                                         isLoaded: true)
        appState.botWork.set(try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina")))
        XCTAssertEqual(appState.allProfilesCatalog.sessions.map(\.id), ["plain"])
    }

    /// A refused action clears the last refusal, shows its own at once and
    /// frees its buttons, without waiting for the list to be read again.
    @MainActor
    func testARefusedActionShowsItsRefusalAndFreesItsButtons() async throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let snapshot = try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina"))
        appState.botWork.set(snapshot)
        appState.botWork.setRefusal("An older refusal.", profile: "furina")
        let item = try XCTUnwrap(snapshot.items.first { $0.ref == "W1" })
        // No dashboard yet, so the request fails as one that can't reach the bot.
        let done = await appState.actOnWorkstream(item, profile: "furina", action: .stop)
        XCTAssertFalse(done)
        XCTAssertEqual(appState.botWork.refusal("furina"),
                       AppLocalization.string("Couldn't reach this bot's work. Try again in a moment."))
        XCTAssertFalse(appState.botWork.isActing("W1", profile: "furina"))
    }

    /// A running workstream's chat has no bar: the composer's Stop stops it
    /// through the plugin, since its turn isn't on this chat's socket.
    @MainActor
    func testTheComposersStopStopsAnOpenWorkstream() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.botWork.set(try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina")))
        appState.activeSessionId = "20261101_w1"
        XCTAssertEqual(appState.workstreamStoppedByComposer?.item.ref, "W1")
        appState.activeSessionId = "20261101_w3"  // done: nothing to stop
        XCTAssertNil(appState.workstreamStoppedByComposer)
        appState.activeSessionId = "20261101_other"
        XCTAssertNil(appState.workstreamStoppedByComposer)
    }

    /// A "Needs you" card's approval comes from the plugin, named by its
    /// request; a row without one (or with a requestless one) offers none.
    func testANeedsYouCardReadsItsApprovalFromThePlugin() throws {
        let asked = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W46", "kind": "workstream", "status": "needs_you", "session_id": "20261101_w46",
            "actions": ["send", "stop"],
            "approval": ["request_id": "appr-2", "command": "rm -f /tmp/conduit-approval-test.txt",
                         "description": "delete a file"],
        ]))
        XCTAssertEqual(asked.approval, BotWorkItem.Approval(requestID: "appr-2",
                                                            command: "rm -f /tmp/conduit-approval-test.txt",
                                                            description: "delete a file"))
        XCTAssertEqual(asked.actions, [.send, .stop])  // approve and deny aren't controls
        let requestless = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W47", "kind": "workstream", "status": "needs_you", "approval": ["command": "rm x"],
        ]))
        XCTAssertNil(requestless.approval)
        // A command the plugin cut, or an empty one, is denied only.
        let cut = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W48", "kind": "workstream", "status": "needs_you",
            "approval": ["request_id": "appr-3", "command": "x…", "description": "", "approvable": false],
        ]))
        XCTAssertEqual(cut.approval?.isApprovable, false)
        let empty = try XCTUnwrap(BotWorkItem(row: [
            "ref": "W49", "kind": "workstream", "status": "needs_you",
            "approval": ["request_id": "appr-4", "command": " \n", "approvable": true],
        ]))
        XCTAssertEqual(empty.approval?.isApprovable, false)
        XCTAssertEqual(asked.approval?.isApprovable, true)
    }

    /// A Bot Chat reply's links to its work become cards under it; other
    /// links stay in its words.
    func testWorkLinksInABotChatReplyBecomeCards() throws {
        let text = "Started W46 to create and delete the file. [Open W46](conduit://session/20261101_w46?profile=furina) "
            + "See [the docs](https://example.com) too."
        let split = try XCTUnwrap(BotWorkLinks.split(text))
        XCTAssertEqual(split.text, "Started W46 to create and delete the file. See [the docs](https://example.com) too.")
        XCTAssertEqual(split.links.map(\.ref), ["W46"])
        XCTAssertEqual(split.links.first?.sessionID, "20261101_w46")
        XCTAssertEqual(split.links.first?.profile, "furina")
        let two = try XCTUnwrap(BotWorkLinks.split(
            "W1 is done ([Open W1](conduit://session/a)), W2 too [W2](conduit://session/b)."))
        XCTAssertEqual(two.text, "W1 is done, W2 too.")
        XCTAssertEqual(two.links.map(\.ref), ["W1", "W2"])
        XCTAssertNil(BotWorkLinks.split("Open [the file](conduit://file?path=/tmp/x)"))
        XCTAssertNil(BotWorkLinks.split("No links here."))
        // Only the link's own place changes: code elsewhere stays as written.
        let code = try XCTUnwrap(BotWorkLinks.split("Run `ls -a .` then f() , see [Open W3](conduit://session/c)"))
        XCTAssertEqual(code.text, "Run `ls -a .` then f() , see")
    }

    /// A read asked for after an action, while one was under way, makes
    /// that read go again once, and only once.
    @MainActor
    func testAReadAfterAnActionGoesAgainOnce() {
        let store = BotWorkStore()
        XCTAssertTrue(store.beginReading("furina"))
        XCTAssertFalse(store.takeReadAgain("furina"))
        store.readAgain("furina")
        XCTAssertTrue(store.takeReadAgain("furina"))
        XCTAssertFalse(store.takeReadAgain("furina"))
        store.endReading("furina")
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

        store.setRefusal("W1 can't continue while it's running.", profile: "furina", ref: "W1")
        XCTAssertNotNil(store.refusal("furina"))  // the panel shows it
        XCTAssertNotNil(store.refusal("furina", ref: "W1"))  // and W1's bar
        XCTAssertNil(store.refusal("furina", ref: "W2"))  // never W2's
        XCTAssertNil(store.refusal("nahida"))

        let mark = store.mark("furina")
        store.noteAction("nahida")
        XCTAssertTrue(store.isCurrent(mark, profile: "furina"))  // another bot's action
        store.noteAction("furina")
        XCTAssertFalse(store.isCurrent(mark, profile: "furina"))  // read before this bot's action
        let beforeSwitch = store.mark("nahida")
        store.clear()
        XCTAssertFalse(store.isCurrent(beforeSwitch, profile: "nahida"))  // read before a server change
        store.set(try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina")))
        store.setRefusal("W1 can't continue while it's running.", profile: "furina")

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
        let wrapped = try XCTUnwrap(BotWorkCall.parse(
            toolName: "work_stop", input: #"{"ref": "W3"}"#, output: #"{"output": "W3 is not running"}"#
        ))
        XCTAssertNil(wrapped.title(running: false))
        XCTAssertNil(BotWorkCall.parse(toolName: "terminal", input: #"{"command": "ls"}"#, output: nil))
        XCTAssertNil(BotWorkCall.parse(toolName: "tool_call", input: #"{"name": "terminal"}"#, output: nil))
    }
}
