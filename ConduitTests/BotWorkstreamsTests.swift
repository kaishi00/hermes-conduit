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

    /// A workstream's worktree branch, for the user to merge.
    func testAWorkstreamsWorktreeBranchIsShown() throws {
        let branched = try XCTUnwrap(BotWorkItem(row: ["ref": "W3", "kind": "workstream", "status": "done",
                                                        "branch": " hermes-subagent/subagent-work-default-w3-ab12 "]))
        XCTAssertEqual(branched.branch, "hermes-subagent/subagent-work-default-w3-ab12")
        XCTAssertEqual(try XCTUnwrap(BotWorkItem(row: ["ref": "W4", "kind": "workstream"])).branch, "")
    }

    /// A voice call's job is marked as the call's; anything else is the bot's own.
    func testACallsJobIsMarkedAsTheCalls() throws {
        let job = try XCTUnwrap(BotWorkItem(row: ["ref": "W5", "kind": "workstream", "status": "running",
                                                   "from_call": "watch"]))
        XCTAssertEqual(job.fromCall, "watch")
        XCTAssertEqual(try XCTUnwrap(BotWorkItem(row: ["ref": "W6", "kind": "workstream", "from_call": "car"])).fromCall, "")
        XCTAssertEqual(try XCTUnwrap(BotWorkItem(row: ["ref": "W7", "kind": "workstream"])).fromCall, "")
        // A Bot Chat call's own workstream: the app row's `call` (the tool row's `started_in_call`).
        let own = try XCTUnwrap(BotWorkItem(row: ["ref": "W8", "kind": "workstream", "status": "running", "call": "phone"]))
        XCTAssertEqual(own.startedInCall, "phone")
        XCTAssertEqual(own.fromCall, "")
        // Its chat stays a Voice Jobs chat, not a workstream's.
        var response = workResponse()
        var rows = response["work"] as? [[String: Any]] ?? []
        rows[0]["from_call"] = "phone"
        response["work"] = rows
        let snapshot = try XCTUnwrap(BotWorkSnapshot(response: response, profile: "furina"))
        let session = try XCTUnwrap(rows[0]["session_id"] as? String)
        XCTAssertNil(snapshot.item(forSession: [session]))
        // And it stays in the Chats list and search.
        XCTAssertFalse(snapshot.sessionIDs.contains(session))
    }

    /// A dropped adopt goes once more, and not after a switch to another dashboard.
    @MainActor
    func testADroppedAdoptIsSentOnceMoreOnItsOwnDashboard() async {
        struct Dropped: Error {}
        var failures = 0
        var sent = await AppState.adoptOnce(stillCurrent: { true }, send: { throw Dropped() }, wait: {},
                                            failed: { _, _ in failures += 1 })
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(failures, 2)
        sent = await AppState.adoptOnce(stillCurrent: { true }, send: {}, wait: {}, failed: { _, _ in })
        XCTAssertEqual(sent, 1)
        var current = true
        sent = await AppState.adoptOnce(stillCurrent: { current }, send: { throw Dropped() },
                                        wait: { current = false }, failed: { _, _ in })
        XCTAssertEqual(sent, 1, "switched dashboards before the retry")
        let here = UUID()
        XCTAssertTrue(AppState.sameDashboard(madeOn: here, now: here, appAlive: true))
        XCTAssertFalse(AppState.sameDashboard(madeOn: here, now: UUID(), appAlive: true), "another dashboard")
        XCTAssertFalse(AppState.sameDashboard(madeOn: here, now: nil, appAlive: true), "no dashboard")
        XCTAssertFalse(AppState.sameDashboard(madeOn: here, now: here, appAlive: false), "the app is gone")
    }

    /// A call's job is sent to its bot's registry only where the plugin keeps bot work.
    func testACallsJobIsKeptOnlyWhereThePluginKeepsBotWork() {
        let keeps = NotifierPluginStatus(state: .reported(version: "0.130.0", capabilities: [BotWorkstreamsClient.adoptCapability]))
        let older = NotifierPluginStatus(state: .reported(version: "0.120.0", capabilities: ["work"]))
        XCTAssertEqual(AppState.voiceJobAdoptVia(plugin: keeps, sessionID: "s1", fromWatch: false), "phone")
        XCTAssertEqual(AppState.voiceJobAdoptVia(plugin: keeps, sessionID: "s1", fromWatch: true), "watch")
        XCTAssertNil(AppState.voiceJobAdoptVia(plugin: keeps, sessionID: "", fromWatch: false))
        XCTAssertNil(AppState.voiceJobAdoptVia(plugin: older, sessionID: "s1", fromWatch: false))
        XCTAssertNil(AppState.voiceJobAdoptVia(plugin: NotifierPluginStatus(state: .unknown), sessionID: "s1", fromWatch: false))
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

    /// The workstreams a Bot Chat reply names become links to their chats
    /// (Eric 2026-11-03): only refs the work list has, never in code, a
    /// link's text, a path or a longer word.
    func testWorkRefsABotChatReplyNamesBecomeLinks() {
        let chats: (String) -> URL? = { ref in
            ["W50": "a", "W51": "b"][ref].map { URL(string: "conduit://session/\($0)?profile=furina")! }
        }
        XCTAssertEqual(
            BotWorkLinks.linkingNamedRefs("The lookups were in **W50** and W51, not W9.", chats: chats),
            "The lookups were in **[W50](conduit://session/a?profile=furina)** and "
                + "[W51](conduit://session/b?profile=furina), not W9.")
        let untouched = "Run `echo W50` in /tmp/W50, see [W50](conduit://session/a) or XW50 and W500."
        XCTAssertEqual(BotWorkLinks.linkingNamedRefs(untouched, chats: chats), untouched)
        // Inside a link, its address, a bare URL or a file name: still as written.
        let links = "See [the W50 notes](https://x.dev/a), [docs](https://x.dev/search?q=W50), "
            + "https://x.dev/?ref=W51 <https://x.dev/W50> and W50.txt."
        XCTAssertEqual(BotWorkLinks.linkingNamedRefs(links, chats: chats), links)
        // A sentence that ends on one still links it.
        XCTAssertEqual(BotWorkLinks.linkingNamedRefs("It was W51.", chats: chats),
                       "It was [W51](conduit://session/b?profile=furina).")
        XCTAssertTrue(BotWorkLinks.mayNameWork("Done in W3."))
        XCTAssertFalse(BotWorkLinks.mayNameWork("Nothing running. Weather is fine."))
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

    // Edit Bot > Work (M3)

    func testWorkSettingsReadAsThePluginGivesThem() throws {
        let settings = try XCTUnwrap(BotWorkSettings(response: [
            "ok": true, "policy": "lookups", "max_running": 3, "max_running_limit": 6, "after_restart": "ask",
            "workstream_approvals": "off", "chat_approvals": "smart", "unavailable": "",
        ]))
        XCTAssertEqual(settings.policy, .lookups)
        XCTAssertEqual(settings.maxRunning, 3)
        XCTAssertEqual(settings.afterRestart, .ask)
        XCTAssertEqual(settings.approvals, .off)
        XCTAssertEqual(settings.chatApprovals, "smart")
        XCTAssertNil(settings.unavailable)
        XCTAssertTrue(settings.isOn)
        // Out of range from an older plugin: held to what the page can show.
        let clamped = try XCTUnwrap(BotWorkSettings(response: ["ok": true, "policy": "off", "max_running": 9,
                                                              "max_running_limit": 6, "unavailable": "plugin host"]))
        XCTAssertEqual(clamped.maxRunning, 6)
        XCTAssertFalse(clamped.isOn)
        XCTAssertEqual(clamped.approvals, .chats)
        XCTAssertEqual(clamped.unavailable, "plugin host")
        XCTAssertNil(BotWorkSettings(response: ["ok": true, "policy": "maybe", "max_running": 2]))
        XCTAssertNil(BotWorkSettings(response: ["ok": false, "policy": "strict", "max_running": 2]))
    }

    func testAWorkSettingsChangeSendsOnlyWhatChanged() {
        let old = BotWorkSettings()
        XCTAssertEqual(old.policy, .lookups)  // the plugin's default (Eric 2026-11-03)
        XCTAssertTrue(old.change(from: old).isEmpty)
        var new = old
        new.approvals = .ask
        new.maxRunning = 4
        let change = new.change(from: old)
        XCTAssertEqual(change["workstream_approvals"] as? String, "ask")
        XCTAssertEqual(change["max_running"] as? Int, 4)
        XCTAssertEqual(change.count, 2)
    }

    /// Edit Bot > Work's Workstream Model (Eric 2026-11-03): read from the
    /// plugin, sent as a pick, and null going back to the Bot Chat's own.
    func testTheWorkstreamModelIsReadAndSent() throws {
        let read = try XCTUnwrap(BotWorkSettings(response: [
            "ok": true, "policy": "strict", "max_running": 2,
            "workstream_model": ["model": "claude-sonnet-5-5", "provider": "anthropic"],
        ]))
        XCTAssertEqual(read.workstreamModel, BotWorkSettings.Model(model: "claude-sonnet-5-5", provider: "anthropic"))
        XCTAssertNil(try XCTUnwrap(BotWorkSettings(response: [
            "ok": true, "policy": "strict", "max_running": 2, "workstream_model": NSNull(),
        ])).workstreamModel)
        XCTAssertNil(try XCTUnwrap(BotWorkSettings(response: [
            "ok": true, "policy": "strict", "max_running": 2, "workstream_model": ["model": " "],
        ])).workstreamModel)
        let own = BotWorkSettings()
        var picked = own
        picked.workstreamModel = BotWorkSettings.Model(model: "gpt-5.5")
        let sent = try XCTUnwrap(picked.change(from: own)["workstream_model"] as? [String: Any])
        XCTAssertEqual(sent as? [String: String], ["model": "gpt-5.5"])
        XCTAssertTrue(own.change(from: picked)["workstream_model"] is NSNull)
        XCTAssertEqual(own.change(from: picked).count, 1)
    }

    func testTheApprovalsCaptionSaysWhenHermesWontAsk() {
        var settings = BotWorkSettings(approvals: .ask, chatApprovals: "manual")
        let asks = BotWorkSettingsView.approvalsCaption(settings, botName: "Furina")
        XCTAssertTrue(asks.contains("Furina"))
        settings.chatApprovals = "off"
        let off = BotWorkSettingsView.approvalsCaption(settings, botName: "Furina")
        XCTAssertNotEqual(asks, off)
        XCTAssertTrue(off.contains("Hermes"))
        let sameAsChats = BotWorkSettingsView.approvalsCaption(
            BotWorkSettings(approvals: .chats, chatApprovals: "off"), botName: "Furina")
        XCTAssertNotEqual(sameAsChats, BotWorkSettingsView.approvalsCaption(
            BotWorkSettings(approvals: .chats, chatApprovals: "manual"), botName: "Furina"))
    }

    /// Bots Home (Eric 2026-11-03, layout A): Bots is the first tab and
    /// the old Chats tab is Sessions.
    func testBotsComeFirstAndChatsIsSessions() {
        XCTAssertEqual(V2Tab.destinations, [.bots, .chats, .tasks, .settings])
        XCTAssertEqual(V2Tab.chats.title, AppLocalization.string("Sessions"))
    }

    /// Bots Home's order: unset, Hermes' order; a drop moves a bot before
    /// another; a bot the order doesn't name goes at the end, and a hidden
    /// one keeps its place.
    func testTheBotOrderMovesADroppedBotAndKeepsNewOnesLast() {
        let hermes = ["hermes", "furina", "nahida", "atlas"]
        var order = BotOrder()
        XCTAssertEqual(order.arrange(hermes, name: { $0 }), hermes)
        order = order.moving("atlas", before: "furina", shown: hermes)
        XCTAssertEqual(order.arrange(hermes, name: { $0 }), ["hermes", "atlas", "furina", "nahida"])
        // A new bot, and the order saved before it, put it last.
        XCTAssertEqual(order.arrange(["scout"] + hermes, name: { $0 }), ["hermes", "atlas", "furina", "nahida", "scout"])
        // Dropped past the last portrait: the end.
        order = order.moving("hermes", before: nil, shown: ["hermes", "atlas", "furina", "nahida"])
        XCTAssertEqual(order.names, ["atlas", "furina", "nahida", "hermes"])
        // Furina hidden (not shown): Reorder Bots' moves keep her place.
        order = order.moving(fromOffsets: IndexSet(integer: 2), toOffset: 0, shown: ["atlas", "nahida", "hermes"])
        XCTAssertEqual(order.names, ["hermes", "furina", "atlas", "nahida"])
        // Names match whatever their case; a bot dropped on itself stays.
        XCTAssertEqual(order.moving("HERMES", before: "hermes", shown: order.names), order)
        XCTAssertEqual(BotOrder(names: ["a", "A", "", "b"]).names, ["a", "b"])
    }

    /// The bots' order syncs as `bots.order`: an unset order sends nothing,
    /// a set one sends its names, and one from another device is saved.
    @MainActor
    func testTheBotOrderSyncsAsItsNames() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let slot = appState.botOrderSlot
        XCTAssertEqual(slot.key, "bots.order")
        XCTAssertNil(slot.read())
        appState.moveBot("atlas", before: "hermes", shown: ["hermes", "atlas"])
        XCTAssertEqual(slot.read() as? [String], ["atlas", "hermes"])
        slot.write(["furina", "atlas"])
        XCTAssertEqual(appState.botOrder.names, ["furina", "atlas"])
        XCTAssertEqual(defaults.stringArray(forKey: BotOrder.storageKey), ["furina", "atlas"])
        slot.write(nil)
        XCTAssertTrue(appState.botOrder.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: BotOrder.storageKey))
    }

    /// A room being started: bots join once, whatever their case, all or
    /// none up to six; a full room takes no one new; a bot hidden or
    /// deleted meanwhile leaves it.
    func testARoomBeingStartedHoldsSixAndDropsWhatLeaves() {
        var build = BotRoomBuild()
        XCTAssertTrue(build.isEmpty)
        XCTAssertTrue(build.add(["hermes", "furina"]))
        XCTAssertTrue(build.add(["FURINA", "atlas"]))
        XCTAssertEqual(build.names, ["hermes", "furina", "atlas"])
        XCTAssertTrue(build.add(["nahida", "scout", "zed"]))
        XCTAssertTrue(build.isFull)
        // Full: a merge bringing anyone new doesn't fit, one of members does.
        XCTAssertFalse(build.fits(["hermes", "kai"]))
        XCTAssertFalse(build.add(["kai"]))
        XCTAssertTrue(build.fits(["hermes", "atlas"]))
        // Five in, a merge of two new ones doesn't fit, all or none.
        build.remove("ZED")
        XCTAssertFalse(build.add(["kai", "lumi"]))
        XCTAssertEqual(build.names.count, 5)
        XCTAssertEqual(build.pruned(visible: ["Atlas", "hermes", "kai"]).names, ["hermes", "atlas"])
        build.clear()
        XCTAssertTrue(build.isEmpty)
    }

    /// A Bot Chat zooms out of its portrait only when that portrait was
    /// just tapped: the push takes the arm and keeps it while the chat is
    /// in the stack; a stale or failed tap, another bot's chat, or an open
    /// with nothing tapped (a notification, a widget) pushes as usual.
    func testOnlyATappedPortraitsChatZoomsOutOfIt() {
        let now = Date()
        var arm = BotZoomArm()
        XCTAssertNil(arm.source(open: "furina", now: now), "a notification or widget opened it")
        arm.tap("Furina", now: now)
        XCTAssertEqual(arm.source(open: "furina", now: now), "Furina", "the portrait's own id")
        XCTAssertNil(arm.source(open: "atlas", now: now))
        XCTAssertNil(arm.source(open: "furina", now: now.addingTimeInterval(BotZoomArm.window + 1)), "stale")
        arm.pushed(open: "furina", now: now.addingTimeInterval(0.5))
        XCTAssertEqual(arm.source(open: "furina", now: now.addingTimeInterval(60)), "Furina", "Back shrinks it home")
        arm.left()
        XCTAssertNil(arm.source(open: "furina", now: now))
        // A failed open drops only its own arm.
        arm.tap("Atlas", now: now)
        arm.openFailed("Furina")
        XCTAssertEqual(arm.source(open: "atlas", now: now), "Atlas")
        arm.openFailed("Atlas")
        XCTAssertNil(arm.source(open: "atlas", now: now))
        // A push with a stale arm zooms nothing, then or later.
        arm.tap("Atlas", now: now)
        arm.pushed(open: "atlas", now: now.addingTimeInterval(BotZoomArm.window + 1))
        XCTAssertNil(arm.source(open: "atlas", now: now))
    }

    /// A dragged portrait carries a marked name, so text dragged in from
    /// another app is never taken for a bot.
    func testABotDragCarriesAMarkedName() {
        XCTAssertEqual(BotDragPayload.botName(from: BotDragPayload.payload(for: "furina")), "furina")
        XCTAssertNil(BotDragPayload.botName(from: "furina"))
        XCTAssertNil(BotDragPayload.botName(from: BotDragPayload.prefix))
    }

    /// Bots is the launch tab: a plain session opened over it still lands
    /// in Sessions, and only a bot's own chats stay in Bots.
    func testAPlainSessionOpenedOverBotsLandsInSessions() {
        XCTAssertEqual(V2Tab.conversationTab(selected: .bots, isBotsChat: false), .chats)
        XCTAssertEqual(V2Tab.conversationTab(selected: .bots, isBotsChat: true), .bots)
        XCTAssertEqual(V2Tab.conversationTab(selected: .chats, isBotsChat: true), .chats)
        XCTAssertEqual(V2Tab.conversationTab(selected: .tasks, isBotsChat: false), .chats)
        // From Pulse or Artifacts pushed in Bots: Back goes to that page.
        XCTAssertEqual(V2Tab.conversationTab(selected: .bots, isBotsChat: false, fromBotsPage: true), .bots)
        XCTAssertEqual(V2Tab.conversationTab(selected: .chats, isBotsChat: false, fromBotsPage: true), .chats)
    }

    /// A Bot Chat opened from a list of bots (a portrait, the overview's
    /// Chat, a row) says so before the list closes: the shell routes the
    /// chat then, before it lands, whatever chat was open before.
    @MainActor
    func testABotChatOpeningFromBotsSaysSoUntilItsOpenEnds() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.showSidebar = true
        appState.beginOpeningBotChat("chef")
        XCTAssertEqual(appState.botChatOpening, "chef")
        XCTAssertFalse(appState.showSidebar)
        // A newer open of another bot keeps its own mark.
        appState.beginOpeningBotChat("coach")
        appState.endOpeningBotChat("chef")
        XCTAssertEqual(appState.botChatOpening, "coach")
        appState.endOpeningBotChat("coach")
        XCTAssertNil(appState.botChatOpening)

        // The shell places the coming Bot Chat in Bots (nothing was open
        // before), and once placed, a plain session goes to Sessions.
        XCTAssertFalse(appState.placesConversationAsBotChat)
        appState.beginOpeningBotChat("chef")
        XCTAssertTrue(appState.placesConversationAsBotChat)
        XCTAssertEqual(V2Tab.conversationTab(selected: .bots, isBotsChat: appState.placesConversationAsBotChat), .bots)
        appState.botChatOpeningPlaced()
        XCTAssertFalse(appState.placesConversationAsBotChat)
        appState.endOpeningBotChat("chef")
        XCTAssertNil(appState.botChatOpening)
    }

    /// A portrait's Overview pill: what needs the user first, then what's
    /// working, else just Overview, and Overview while work is off.
    func testThePortraitPillSaysWhatNeedsYouFirst() throws {
        let both = try XCTUnwrap(BotWorkSnapshot(response: workResponse(), profile: "furina"))
        XCTAssertEqual(BotPortraitStatus.of(both), .needsYou(1))
        var working = workResponse()
        working["counts"] = ["working": 2, "needs_you": 0, "ready": 0]
        XCTAssertEqual(BotPortraitStatus.of(BotWorkSnapshot(response: working, profile: "furina")), .working(2))
        var quiet = workResponse()
        quiet["counts"] = ["working": 0, "needs_you": 0, "ready": 1]
        // Nothing going on but its unanswered ask of Nahida.
        XCTAssertEqual(BotPortraitStatus.of(BotWorkSnapshot(response: quiet, profile: "furina")), .waitingOn("Nahida"))
        quiet["work"] = [] as [[String: Any]]
        XCTAssertEqual(BotPortraitStatus.of(BotWorkSnapshot(response: quiet, profile: "furina")), .idle)
        var off = workResponse()
        off["policy"] = "off"
        XCTAssertEqual(BotPortraitStatus.of(BotWorkSnapshot(response: off, profile: "furina")), .idle)
        XCTAssertEqual(BotPortraitStatus.of(nil), .idle)
        // Talking in a room: after its own work, before waiting on a bot,
        // and without the plugin's workstreams too.
        XCTAssertEqual(BotPortraitStatus.of(nil, talkingIn: ["Trip"]), .inRooms(["Trip"]))
        XCTAssertEqual(BotPortraitStatus.of(BotWorkSnapshot(response: working, profile: "furina"), talkingIn: ["Trip"]),
                       .working(2))
        quiet["work"] = workResponse()["work"]
        XCTAssertEqual(BotPortraitStatus.of(BotWorkSnapshot(response: quiet, profile: "furina"), talkingIn: ["Trip", "Ops"]),
                       .inRooms(["Trip", "Ops"]))
        XCTAssertEqual(BotPortraitStatus.idle.title, AppLocalization.string("Overview"))
    }

    /// Hand-offs between bots: answering another bot's ask comes before its
    /// own work, and an unanswered ask of its own shows when nothing else
    /// does; a closed or answered one shows nothing.
    func testThePortraitSaysWhoItHelpsAndWhoItWaitsOn() throws {
        var response = workResponse()
        response["counts"] = ["working": 1, "needs_you": 0, "ready": 0, "waiting": 1]
        var rows = response["work"] as? [[String: Any]] ?? []
        rows.append(["ref": "A2", "kind": "ask_in", "status": "running", "title": "Trip", "bot": "Hermes"])
        response["work"] = rows
        let helping = BotPortraitStatus.of(BotWorkSnapshot(response: response, profile: "furina"))
        XCTAssertEqual(helping, .helping("Hermes"))
        XCTAssertTrue(helping.title.contains("Hermes"), helping.title)
        // No ask in and no work of its own: waiting on Nahida (A1).
        rows = rows.filter { $0["ref"] as? String != "A2" }
        rows.append(["ref": "A3", "kind": "ask_in", "status": "done", "title": "Old", "bot": "Hermes"])
        response["work"] = rows
        response["counts"] = ["working": 0, "needs_you": 0, "ready": 0, "waiting": 1]
        let waiting = BotPortraitStatus.of(BotWorkSnapshot(response: response, profile: "furina"))
        XCTAssertEqual(waiting, .waitingOn("Nahida"))
        XCTAssertEqual(waiting.otherBot, "Nahida")
        // Its own work comes before waiting.
        response["counts"] = ["working": 2, "needs_you": 0, "ready": 0, "waiting": 1]
        XCTAssertEqual(BotPortraitStatus.of(BotWorkSnapshot(response: response, profile: "furina")), .working(2))
    }
}
