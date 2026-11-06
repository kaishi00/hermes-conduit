import UIKit
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

    /// A resolved workstream is shown in Hermes so Desktop's links open it
    /// (notifier #540), so the Chats list leaves it out by the plugin's
    /// list, including once that list is read after the Chats list was.
    @MainActor
    func testAResolvedWorkstreamStaysOutOfTheChatsList() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        func row(_ id: String) -> SessionSummary {
            SessionSummary(id: id, storedSessionId: nil, alternateIds: [], title: "Chat", model: "Hermes",
                           updatedLabel: "now", lastActivityAt: nil, profile: nil, source: .chat,
                           isActive: false, isArchived: false, lineageRootId: nil)
        }
        appState.sessions = [row("20261031_old"), row("plain")]
        XCTAssertEqual(appState.activeProfileSessions.map(\.id), ["20261031_old", "plain"])
        var response = workResponse()
        response["workstream_sessions"] = ["20261101_w1", "20261031_old"]
        appState.botWork.set(try XCTUnwrap(BotWorkSnapshot(response: response, profile: "furina")))
        XCTAssertEqual(appState.activeProfileSessions.map(\.id), ["plain"])
    }

    /// A workstream's chat, left out of every list, is never the chat
    /// Conduit opens on by itself, though it's the newest (#1755): Jump to
    /// latest activity, and Continue with nothing saved, pick the newest
    /// listed chat. One the user had open is still resumed by Continue.
    @MainActor
    func testTheChatConduitResumesIsNeverAnUnlistedWorkstream() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(.latestActivity)
        let coordinator = ChatResumeCoordinator(store: store)
        let appState = AppState(defaults: defaults, chatResumeCoordinator: coordinator,
                                loadSavedConnection: false)
        let now = Date().timeIntervalSince1970
        func row(_ id: String, stored: String? = nil, alternates: [String] = [], lineageRoot: String? = nil,
                 at: TimeInterval) -> SessionSummary {
            SessionSummary(id: id, storedSessionId: stored, alternateIds: alternates, title: "Chat", model: "Hermes",
                           updatedLabel: "now", lastActivityAt: at, profile: nil, source: .chat,
                           isActive: false, isArchived: false, lineageRootId: lineageRoot)
        }
        // The resolved workstream was re-keyed: only its stored id is listed.
        let catalog = [row("runtime-w1", stored: "20261101_w1", at: now), row("plain", at: now - 600)]
        func pick() -> String? {
            appState.selectChatResumeTarget(in: catalog, profile: "default", purpose: .automaticReturn,
                                            currentSessionID: nil)?.id
        }
        // Before the bot's work is read nothing names it, so it is the newest.
        XCTAssertEqual(pick(), "runtime-w1")

        var response = workResponse()
        response["workstream_sessions"] = ["20261101_w1"]
        appState.botWork.set(try XCTUnwrap(BotWorkSnapshot(response: response, profile: "furina")))
        XCTAssertEqual(pick(), "plain")
        XCTAssertEqual(
            appState.selectChatResumeTarget(in: catalog, profile: "default", purpose: .preserveCurrent,
                                            currentSessionID: nil)?.id,
            "plain"
        )

        coordinator.setBehavior(.continueWhereLeftOff)
        XCTAssertEqual(pick(), "plain")
        coordinator.rememberSession(.dashboard(profile: "default", sessionID: "runtime-w1"), for: "default")
        XCTAssertEqual(pick(), "runtime-w1")

        // A row linked to the workstream only by an alternate id, or only by
        // its lineage root (a compacted workstream's tip), is one too.
        let tips = [row("tip-a", alternates: ["20261101_w1"], at: now + 60),
                    row("tip-b", lineageRoot: "20261101_w1", at: now + 30),
                    row("plain", at: now - 600)]
        XCTAssertEqual(appState.selectChatResumeTarget(in: tips, profile: "default", purpose: .automaticReturn,
                                                       currentSessionID: nil)?.id, "plain")

        // With only workstreams listed there's no chat to pick: a new one starts.
        coordinator.setBehavior(.latestActivity)
        XCTAssertNil(appState.selectChatResumeTarget(in: [catalog[0]], profile: "default",
                                                     purpose: .automaticReturn, currentSessionID: nil))
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
        // Desktop's reference after each link (notifier: workstreams open in
        // Hermes Desktop from it) is left out with the link.
        let desktop = try XCTUnwrap(BotWorkLinks.split(
            "W12 is waiting on you ([Open W12](conduit://session/20261103_w12?profile=furina) @session:furina/20261103_w12)."))
        XCTAssertEqual(desktop.text, "W12 is waiting on you.")
        XCTAssertEqual(desktop.links.map(\.sessionID), ["20261103_w12"])
        // Without a work link, a reference stays a chat link (HermesSessionReference).
        XCTAssertNil(BotWorkLinks.split("Open it here: @session:20261103_w12"))
        // Only the one right after a work link goes: one in code, or another
        // chat's, stays as written.
        let other = try XCTUnwrap(BotWorkLinks.split(
            "Join with `hermes open @session:furina/w12`, see @session:old1 or [Open W3](conduit://session/c)"))
        XCTAssertEqual(other.text, "Join with `hermes open @session:furina/w12`, see @session:old1 or")
        // Another session's reference right after a work link, or one after
        // an ordinary chat link, stays too.
        let unrelated = try XCTUnwrap(BotWorkLinks.split(
            "See [an earlier chat](conduit://session/old) @session:old and [Open W3](conduit://session/c) @session:furina/other"))
        XCTAssertEqual(unrelated.text,
                       "See [an earlier chat](conduit://session/old) @session:old and @session:furina/other")
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
        var toggled = BotWorkSettings(policy: .off)
        toggled.isOnSetting = true
        XCTAssertEqual(toggled.policy, .lookups)  // back on with the default
        var strict = BotWorkSettings(policy: .strict)
        strict.isOnSetting = true
        XCTAssertEqual(strict.policy, .strict)  // a policy already on stays
        strict.isOnSetting = false
        XCTAssertEqual(strict.policy, .off)
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

    /// The room being started is named in its bar: what was typed, trimmed,
    /// or the bots' names when nothing was. A retry with the same name and
    /// bots sends the same id (the gateway dedups it); a change, or a room
    /// started over, gets a fresh one. Pruning keeps the name.
    func testARoomBeingStartedIsNamedInItsBarAndRetriesWithItsID() {
        var build = BotRoomBuild()
        build.add(["hermes", "furina"])
        XCTAssertEqual(build.roomName(suggested: "Hermes and Furina"), "Hermes and Furina")
        build.name = "   "
        XCTAssertEqual(build.roomName(suggested: " Hermes and Furina "), "Hermes and Furina")
        build.name = "  Trip planning "
        XCTAssertEqual(build.roomName(suggested: "Hermes and Furina"), "Trip planning")
        let inputs = GroupCreateAttempt.Inputs(name: "Trip planning", members: ["hermes", "furina"])
        let first = build.attempt(inputs)
        XCTAssertEqual(build.attempt(inputs), first)
        let renamed = build.attempt(GroupCreateAttempt.Inputs(name: "Trips", members: ["hermes", "furina"]))
        XCTAssertNotEqual(renamed, first)
        XCTAssertEqual(build.pruned(visible: ["hermes", "furina"]).name, "  Trip planning ")
        build.clear()
        XCTAssertTrue(build.name.isEmpty)
        XCTAssertNotEqual(build.roomID, renamed)
    }

    /// A face flying into the room being started lands where the room's
    /// icon draws it: the first two side by side, three in a triangle, and
    /// a fourth or later sinking into the middle, as the icon shows three.
    func testAFaceJoiningANewRoomLandsWhereTheIconDrawsIt() {
        let rect = CGRect(x: 100, y: 200, width: 60, height: 60)
        let alone = NewRoomPortrait.slot(index: 0, count: 1, in: rect)
        XCTAssertEqual(alone.center, CGPoint(x: 130, y: 230))
        XCTAssertEqual(alone.diameter, 60, accuracy: 0.001)
        let second = NewRoomPortrait.slot(index: 1, count: 2, in: rect)
        XCTAssertEqual(second.center.x, 130 + 60 * 0.17, accuracy: 0.001)
        XCTAssertEqual(second.diameter, 60 * 0.64, accuracy: 0.001)
        let top = NewRoomPortrait.slot(index: 0, count: 3, in: rect)
        XCTAssertEqual(top.center.y, 230 - 60 * 0.22, accuracy: 0.001)
        let fourth = NewRoomPortrait.slot(index: 3, count: 4, in: rect)
        XCTAssertEqual(fourth.center, CGPoint(x: 130, y: 230))
        XCTAssertLessThan(fourth.diameter, top.diameter)
    }

    /// The room Hermes makes from a room being started stays out of the grid
    /// while the room being started stands in for it, and takes its place
    /// only once Hermes lists it; other rooms always show.
    func testAMadeRoomWaitsForItsPlaceThenTakesIt() {
        let before: Set<String> = ["trip", "dinner"]
        XCTAssertTrue(NewRoomLanding.shows("trip", before: before, starting: true))
        XCTAssertFalse(NewRoomLanding.shows("made", before: before, starting: true), "the tile stands in for it")
        XCTAssertTrue(NewRoomLanding.shows("made", before: before, starting: false), "the tile has gone")
        XCTAssertTrue(NewRoomLanding.shows("made", before: nil, starting: true), "Create wasn't tapped")
        XCTAssertEqual(NewRoomLanding.landing(made: "made", listed: ["trip", "made"]), "made")
        XCTAssertNil(NewRoomLanding.landing(made: "made", listed: ["trip", "other"]), "not listed yet: no slide")
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
        // The shell pushes before the open lands, while the chat open
        // before is still the active one (build 248).
        XCTAssertEqual(arm.source(open: "atlas", now: now), "Furina", "pushed before it lands")
        XCTAssertNil(arm.source(open: "furina", now: now.addingTimeInterval(BotZoomArm.window + 1)), "stale")
        arm.pushed(open: "atlas", now: now.addingTimeInterval(0.5))
        XCTAssertEqual(arm.source(open: "atlas", now: now.addingTimeInterval(1)), "Furina", "not landed yet")
        arm.opened("furina")
        XCTAssertEqual(arm.source(open: "furina", now: now.addingTimeInterval(60)), "Furina", "Back shrinks it home")
        XCTAssertNil(arm.source(open: "atlas", now: now.addingTimeInterval(61)), "another chat opened in its place")
        arm.left()
        XCTAssertNil(arm.source(open: "furina", now: now))
        // A failed open drops only its own arm.
        arm.tap("Atlas", now: now)
        arm.openFailed("Furina")
        XCTAssertEqual(arm.source(open: "atlas", now: now), "Atlas")
        arm.openFailed("Atlas")
        XCTAssertNil(arm.source(open: "atlas", now: now))
        // Another bot's chat landing first: the push carried that one.
        arm.tap("Atlas", now: now)
        arm.pushed(open: "furina", now: now)
        arm.opened("rei")
        XCTAssertNil(arm.source(open: "rei", now: now))
        arm.left()
        // A push whose open then fails zooms no more.
        arm.tap("Atlas", now: now)
        arm.pushed(open: "furina", now: now)
        arm.openFailed("Atlas")
        XCTAssertNil(arm.source(open: "furina", now: now))
        arm.left()
        // A push with a stale arm zooms nothing, then or later.
        arm.tap("Atlas", now: now)
        arm.pushed(open: "atlas", now: now.addingTimeInterval(BotZoomArm.window + 1))
        XCTAssertNil(arm.source(open: "atlas", now: now))
    }

    /// A room's portrait arms the zoom by its own key, apart from any bot's
    /// name: its screen grows out of the room, also over a Bot Chat still
    /// named open under it, and the bot's chat after it zooms no more.
    func testARoomsPortraitZoomsItsOwnScreen() {
        let now = Date()
        let room = BotZoomArm.roomKey("trip")
        XCTAssertNotEqual(room, "trip", "never a bot's name")
        var arm = BotZoomArm()
        arm.tap(room, now: now)
        // The room shows before its push, so it has landed by then.
        arm.pushed(open: room, now: now.addingTimeInterval(0.2))
        XCTAssertEqual(arm.source(open: room, now: now.addingTimeInterval(60)), room, "Back shrinks it home")
        XCTAssertNil(arm.source(open: "furina", now: now.addingTimeInterval(60)), "the Bot Chat under it")
        arm.left()
        // A room whose open failed zooms nothing.
        arm.tap(room, now: now)
        arm.openFailed(room)
        XCTAssertNil(arm.source(open: room, now: now))
    }

    /// A ring takes the bot's glow color (picked or drawn from its photo),
    /// else its Hermes color, else its name's hue (build 248); a group
    /// room's name and bubble take the same (build 254).
    @MainActor
    func testABotsRingTakesItsGlowColorFirst() {
        func bot(_ color: String?) -> BotProfile {
            BotProfile(name: "raiden", botTitle: nil, displayName: "Raiden", profileDescription: "", model: nil,
                       provider: nil, hasAvatar: true, isPinned: false, isHiddenByMeta: false,
                       appearanceColor: color, canonicalSession: nil, lastActive: nil, lastPreview: nil)
        }
        let glow = ProfileGlowRGB(red: 0.5, green: 0.2, blue: 0.8)
        XCTAssertEqual(AppState.botColor(bot("#00ff00"), glow: glow), glow.color, "the glow wins")
        XCTAssertEqual(AppState.botColor(bot("#00ff00"), glow: nil), BotAvatarView.color(for: "#00ff00", name: "raiden"))
        XCTAssertEqual(AppState.botColor(bot(nil), glow: nil), BotAvatarView.color(for: nil, name: "raiden"), "the name's hue")
        // A group room names and tints the bot in the same color as its
        // ring, not its Hermes color under a picked or photo glow.
        XCTAssertEqual(
            AppState.groupMemberColor(bot: bot("#00ff00"), name: "Raiden", glows: ["raiden": glow]), glow.color
        )
        XCTAssertEqual(
            AppState.groupMemberColor(bot: bot("#00ff00"), name: "Raiden", glows: [:]),
            BotAvatarView.color(for: "#00ff00", name: "raiden")
        )
        XCTAssertEqual(
            AppState.groupMemberColor(bot: nil, name: "Guest", glows: ["raiden": glow]),
            BotAvatarView.color(for: nil, name: "Guest"), "a member with no bot: its name's hue"
        )
    }

    /// A workstream opened from its Bot Chat shows in the same pushed
    /// screen: it slides in from the trailing edge, and Back to the Bot
    /// Chat slides that in from the leading one. Any other change of chat
    /// just shows (Eric 2026-11-03).
    func testABotChatAndItsWorkstreamsSlideLikeAPushAndAPop() {
        typealias Shown = BotChatSwap.Shown
        let botChat = Shown(botChat: "furina", workstreamOf: nil)
        let workstream = Shown(botChat: nil, workstreamOf: "Furina")
        XCTAssertEqual(BotChatSwap.direction(from: botChat, to: workstream), .forward)
        XCTAssertEqual(BotChatSwap.direction(from: workstream, to: botChat), .back)
        XCTAssertEqual(BotChatSwap.direction(from: workstream, to: workstream), .forward, "a workstream's link to another")
        XCTAssertNil(BotChatSwap.direction(from: workstream, to: Shown(botChat: "atlas")), "another bot's chat")
        XCTAssertNil(BotChatSwap.direction(from: Shown(), to: workstream), "from a plain session")
        XCTAssertNil(BotChatSwap.direction(from: botChat, to: Shown()), "to a plain session")
        XCTAssertTrue(BotChatSwap.isBackSwipe(CGSize(width: 120, height: 30)))
        XCTAssertFalse(BotChatSwap.isBackSwipe(CGSize(width: 60, height: 0)), "too short")
        XCTAssertFalse(BotChatSwap.isBackSwipe(CGSize(width: 120, height: 100)), "mostly down")
        XCTAssertFalse(BotChatSwap.isBackSwipe(CGSize(width: -120, height: 0)), "the other way")
    }

    /// A workstream's screen holds back the zoom's own dismissals by their
    /// UIKit names, so a slow swipe can't pop past its Bot Chat to Bots Home.
    func testTheBackSwipeGateKnowsTheZoomsDismissals() {
        for name in ["LeadingEdgePan", "SwipeDown", "Pinch"] {
            XCTAssertTrue(SystemBackSwipeGate.isZoomDismissal("com.apple.UIKit.ZoomInteractiveDismiss" + name), name)
        }
        XCTAssertFalse(SystemBackSwipeGate.isZoomDismissal(nil))
        XCTAssertFalse(SystemBackSwipeGate.isZoomDismissal("UINavigationController.edgeSwipe"))
    }

    /// The gate turns the page's back swipes off while blocked and back on
    /// as it clears, leaving one that was already off as it was.
    @MainActor
    func testTheBackSwipeGateTurnsOnOnlyWhatItTurnedOff() {
        let root = UIViewController()
        let page = UIViewController()
        let navigation = UINavigationController()
        navigation.setViewControllers([root, page], animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        XCTAssertNotNil(page.view.window)

        let zoom = UIPanGestureRecognizer()
        zoom.name = SystemBackSwipeGate.zoomDismissalPrefix + "LeadingEdgePan"
        let alreadyOff = UIPanGestureRecognizer()
        alreadyOff.name = SystemBackSwipeGate.zoomDismissalPrefix + "SwipeDown"
        alreadyOff.isEnabled = false
        let other = UIPanGestureRecognizer()
        [zoom, alreadyOff, other].forEach(page.view.addGestureRecognizer)

        let gate = SystemBackSwipeGate.GateView()
        page.view.addSubview(gate)
        gate.blocked = true
        XCTAssertFalse(zoom.isEnabled)
        XCTAssertFalse(alreadyOff.isEnabled)
        XCTAssertTrue(other.isEnabled, "only the system's back swipes")
        XCTAssertEqual(navigation.interactivePopGestureRecognizer?.isEnabled, false)

        gate.blocked = false
        XCTAssertTrue(zoom.isEnabled)
        XCTAssertFalse(alreadyOff.isEnabled, "it was off before the gate")
        XCTAssertEqual(navigation.interactivePopGestureRecognizer?.isEnabled, true)

        gate.blocked = true
        gate.removeFromSuperview()
        XCTAssertTrue(zoom.isEnabled, "a gate that leaves the screen lets go")
    }

    /// A gate that comes on before its page is in the stack (a workstream
    /// opened with its push) keeps looking, and holds the swipes once it is.
    @MainActor
    func testTheBackSwipeGateWaitsForItsPageToBePushed() {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let page = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        // On screen, but not yet the stack's.
        window.addSubview(page.view)

        let zoom = UIPanGestureRecognizer()
        zoom.name = SystemBackSwipeGate.zoomDismissalPrefix + "SwipeDown"
        page.view.addGestureRecognizer(zoom)
        let gate = SystemBackSwipeGate.GateView()
        page.view.addSubview(gate)
        gate.blocked = true
        XCTAssertTrue(zoom.isEnabled, "no page in a stack yet")

        let held = expectation(description: "held once it's the stack's")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            navigation.addChild(page)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !zoom.isEnabled { held.fulfill() }
            }
        }
        wait(for: [held], timeout: 2)
        gate.blocked = false
        XCTAssertTrue(zoom.isEnabled)
    }

    /// A zoom dismissal let go that left the list's hidden bar over a chat
    /// brings the chat's bar back once the swipe ends; once another screen
    /// is on top, the keeper leaves the bar alone (Eric 2026-11-06: a room
    /// lost its top menus).
    @MainActor
    func testTheBarKeeperShowsTheChatsBarAgainAfterALetGoSwipeOnlyWhileItsOnTop() {
        let root = UIViewController()
        let page = UIViewController()
        let navigation = UINavigationController()
        navigation.setViewControllers([root, page], animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let swipeDown = UIPanGestureRecognizer()
        swipeDown.name = SystemBackSwipeGate.zoomDismissalPrefix + "SwipeDown"
        page.view.addGestureRecognizer(swipeDown)
        let keeper = NavigationBarKeeper.KeeperView()
        page.view.addSubview(keeper)
        XCTAssertTrue(keeper.page === page)
        XCTAssertTrue(keeper.watches(swipeDown), "the zoom's swipe down, by its name")

        // The swipe let go, the list's hidden bar left over the chat.
        navigation.setNavigationBarHidden(true, animated: false)
        keeper.swipeEnded()
        let shown = expectation(description: "the chat's bar is back")
        func poll(_ triesLeft: Int) {
            if !navigation.isNavigationBarHidden { return shown.fulfill() }
            guard triesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll(triesLeft - 1) }
        }
        poll(50)
        wait(for: [shown], timeout: 2)

        // iOS 27: the zoom leaves the bar faded out rather than hidden.
        navigation.navigationBar.alpha = 0
        keeper.restoreBar()
        XCTAssertEqual(navigation.navigationBar.alpha, 1)

        // Another screen on top: its bar is its own.
        navigation.pushViewController(UIViewController(), animated: false)
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.navigationBar.alpha = 0
        keeper.restoreBar()
        XCTAssertTrue(navigation.isNavigationBarHidden, "another screen's bar is its own")
        XCTAssertEqual(navigation.navigationBar.alpha, 0)
        keeper.removeFromSuperview()
    }

    /// A zoom's dismissal takes the page out of its stack while it runs, so
    /// the page has no stack when the finger lifts; the keeper still finds
    /// it, waits for the page to be put back and shows its faded bar again
    /// (iOS 27.2 simulator: the bar stayed at alpha 0 after every let-go
    /// swipe until the keeper kept the stack).
    @MainActor
    func testTheBarKeeperWaitsForAPageTheZoomTookOutOfTheStack() {
        let root = UIViewController()
        let page = UIViewController()
        let navigation = UINavigationController()
        navigation.setViewControllers([root, page], animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let keeper = NavigationBarKeeper.KeeperView()
        page.view.addSubview(keeper)

        // The finger lifts while the page is out of the stack.
        navigation.setViewControllers([root], animated: false)
        XCTAssertNil(page.navigationController)
        navigation.navigationBar.alpha = 0
        keeper.swipeEnded()
        // The let-go dismissal puts it back, its bar still faded out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            navigation.setViewControllers([root, page], animated: false)
            navigation.navigationBar.alpha = 0
        }
        let shown = expectation(description: "the chat's bar is back")
        func poll(_ triesLeft: Int) {
            if navigation.topViewController === page, navigation.navigationBar.alpha == 1 { return shown.fulfill() }
            guard triesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll(triesLeft - 1) }
        }
        poll(75)
        wait(for: [shown], timeout: 3)
        keeper.removeFromSuperview()
    }

    /// Bots Home's voice button lists the shown bots to call, the one that
    /// talked last first, ties in roster order (Eric 2026-11-03).
    func testBotsHomesVoiceButtonListsTheBotUsedLastFirst() {
        func bot(_ name: String, _ lastActive: Double?, hidden: Bool = false) -> BotProfile {
            BotProfile(name: name, botTitle: nil, displayName: name, profileDescription: "", model: nil,
                       provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: hidden,
                       appearanceColor: nil, canonicalSession: nil, lastActive: lastActive, lastPreview: nil)
        }
        let roster = [bot("atlas", 10), bot("rei", nil), bot("furina", 30), bot("kai", 50, hidden: true), bot("nia", nil)]
        XCTAssertEqual(V2VoiceButton.botsToCall(roster).map(\.name), ["furina", "atlas", "rei", "nia"])
    }

    /// Bots Home's Group Chats probe and the roster ask again on their own
    /// after a failure, four times at most, so their notice clears once
    /// Hermes answers (Eric 2026-11-04).
    @MainActor
    func testANoticesReadAsksAgainFourTimesThenStops() async {
        XCTAssertEqual((0..<5).map(TransientReadRetry.delay(after:)), [2, 4, 8, 16, nil])
        var retry = TransientReadRetry()
        for _ in 0..<6 { retry.schedule {} }
        XCTAssertEqual(retry.attempts, 4, "no fifth try")
        retry.succeeded()
        XCTAssertEqual(retry.attempts, 0, "an answer starts the delays again")
    }

    /// A dragged portrait carries a marked name, so text dragged in from
    /// another app is never taken for a bot.
    func testABotDragCarriesAMarkedName() {
        XCTAssertEqual(BotDragPayload.botName(from: BotDragPayload.payload(for: "furina")), "furina")
        XCTAssertNil(BotDragPayload.botName(from: "furina"))
        XCTAssertNil(BotDragPayload.botName(from: BotDragPayload.prefix))
    }

    /// A room's tile carries its marked id, which no bot portrait takes for
    /// a bot, nor a room's tile a bot's for a room.
    func testARoomDragCarriesAMarkedIDThatNoBotTakes() {
        let payload = RoomDragPayload.payload(for: "room-1")
        XCTAssertEqual(RoomDragPayload.roomID(from: payload), "room-1")
        XCTAssertNil(BotDragPayload.botName(from: payload))
        XCTAssertNil(RoomDragPayload.roomID(from: BotDragPayload.payload(for: "furina")))
        XCTAssertNil(RoomDragPayload.roomID(from: RoomDragPayload.prefix))
    }

    /// The group chats keep the person's order by room id, saved apart from
    /// the bots' and synced as `groups.order`; a room it doesn't name yet
    /// (one just made) comes first, where Hermes lists it, and ids match
    /// exactly.
    @MainActor
    func testTheGroupChatsOrderIsSavedAndSyncedApartFromTheBots() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let slot = appState.groupRoomOrderSlot
        XCTAssertEqual(slot.key, "groups.order")
        XCTAssertNil(slot.read())
        appState.moveGroupRoom("b", before: "a", shown: ["a", "b", "c"])
        XCTAssertEqual(slot.read() as? [String], ["b", "a", "c"])
        XCTAssertEqual(defaults.stringArray(forKey: BotOrder.roomStorageKey), ["b", "a", "c"])
        XCTAssertTrue(appState.botOrder.isEmpty, "the bots' order is its own")
        appState.moveGroupRooms(fromOffsets: IndexSet(integer: 2), toOffset: 0, shown: ["b", "a", "c"])
        XCTAssertEqual(appState.groupRoomOrder.names, ["c", "b", "a"])
        XCTAssertEqual(appState.groupRoomOrder.arrange(["a", "new", "b", "c"], name: { $0 }), ["new", "c", "b", "a"])
        // A drag after a room was made keeps it where it shows.
        appState.moveGroupRoom("a", before: "c", shown: ["new", "c", "b", "a"])
        XCTAssertEqual(appState.groupRoomOrder.names, ["new", "a", "c", "b"])
        // Room ids are case-sensitive: "A" is another room.
        XCTAssertEqual(BotOrder(names: ["a", "A"], kind: .rooms).names, ["a", "A"])
        XCTAssertEqual(BotOrder(names: ["a", "A"]).names, ["a"], "bots match in any case")
        slot.write(nil)
        XCTAssertTrue(appState.groupRoomOrder.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: BotOrder.roomStorageKey))
    }

    /// A room's tile dropped on another takes its place: carried on, it goes
    /// after the one it lands on (two rooms swap); carried back, before it.
    /// The room in hand clears with its drag.
    @MainActor
    func testARoomDroppedOnAnotherTakesItsPlace() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let rooms = ["a", "b", "c", "d"]
        func drop(_ moved: String, onto target: String?) {
            appState.dropGroupRoom(moved, onto: target, shown: appState.groupRoomOrder.arrange(rooms, name: { $0 }))
        }
        drop("a", onto: "b")
        XCTAssertEqual(appState.groupRoomOrder.names, ["b", "a", "c", "d"], "onto its right neighbour: they swap")
        drop("b", onto: "a")
        XCTAssertEqual(appState.groupRoomOrder.names, ["a", "b", "c", "d"])
        drop("a", onto: "c")
        XCTAssertEqual(appState.groupRoomOrder.names, ["b", "c", "a", "d"])
        drop("d", onto: "b")
        XCTAssertEqual(appState.groupRoomOrder.names, ["d", "b", "c", "a"])
        drop("d", onto: nil)
        XCTAssertEqual(appState.groupRoomOrder.names, ["b", "c", "a", "d"])
        drop("a", onto: "a")
        XCTAssertEqual(appState.groupRoomOrder.names, ["b", "c", "a", "d"])

        RoomDragPayload.lifted = nil
        XCTAssertNil(RoomDragPayload.lifted)
        autoreleasepool {
            let provider = RoomDragPayload.lift("r")
            XCTAssertEqual(RoomDragPayload.lifted, "r")
            XCTAssertTrue(RoomDragPayload.isLive)
            withExtendedLifetime(provider) {}
        }
        // The system may let go of the item mid-drag: the room stays in
        // hand a while, so the drag keeps showing a move, not a +.
        XCTAssertEqual(RoomDragPayload.lifted, "r")
        // ...but a drop reads its own text then, so a foreign one never
        // borrows the room.
        XCTAssertFalse(RoomDragPayload.isLive)
        XCTAssertNil(RoomDragPayload.lifted(at: Date().addingTimeInterval(BotDragPayload.liftedGrace + 1)),
                     "a drag that's gone leaves no room in hand")
        // Seen 2 s on, it's still in hand a second past its first expiry.
        let roomLifted = Date()
        RoomDragPayload.seen(at: roomLifted.addingTimeInterval(2))
        XCTAssertEqual(RoomDragPayload.lifted(at: roomLifted.addingTimeInterval(BotDragPayload.liftedGrace + 1)), "r")
        RoomDragPayload.lifted = nil
        autoreleasepool {
            let provider = BotDragPayload.lift("Ayaka")
            withExtendedLifetime(provider) {}
        }
        XCTAssertEqual(BotDragPayload.lifted, "Ayaka")
        XCTAssertFalse(BotDragPayload.isLive)
        XCTAssertNil(BotDragPayload.lifted(at: Date().addingTimeInterval(BotDragPayload.liftedGrace + 1)))
        // A drop target seeing it in hand keeps it there past the grace.
        let botLifted = Date()
        BotDragPayload.seen(at: botLifted.addingTimeInterval(2))
        XCTAssertEqual(BotDragPayload.lifted(at: botLifted.addingTimeInterval(BotDragPayload.liftedGrace + 1)), "Ayaka")
        BotDragPayload.lifted = nil
    }

    /// A bot dropped on another takes its place, as a room does (bots match
    /// in any case), and a merge needs the bot held still over the face or
    /// just above or beside it: carried across it, or in the gap to the next
    /// cell or on its name, the drop only moves.
    @MainActor
    func testABotDroppedOnAnotherTakesItsPlaceAndMergesOnlyHeldStill() throws {
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.dropBot("Ayaka", onto: "furina", shown: ["ayaka", "Furina", "Yelan"])
        XCTAssertEqual(appState.botOrder.names, ["Furina", "Ayaka", "Yelan"], "onto its right neighbour: they swap")
        XCTAssertLessThan(BotDragPayload.slideDwell, BotDragPayload.mergeDwell, "a bot slides into place before it could swell for a room")
        // Pinned bots show first: carried on, a bot goes after its target in
        // the order itself, so two pinned neighbours still swap.
        let pinnedFirst = BotOrder(names: ["Tighnari", "Ayaka", "Bennett"], kind: .bots)
            .dropping("Ayaka", onto: "Bennett", shown: ["Ayaka", "Bennett", "Tighnari"])
        XCTAssertEqual(pinnedFirst.names, ["Tighnari", "Bennett", "Ayaka"])
        appState.dropBot("Yelan", onto: "Furina", shown: ["Furina", "Ayaka", "Yelan"])
        XCTAssertEqual(appState.botOrder.names, ["Yelan", "Furina", "Ayaka"])

        let face = CGRect(x: 10, y: 0, width: 80, height: 80)
        let zone = BotDragPayload.mergeZone(face: face)
        XCTAssertTrue(zone.contains(CGPoint(x: 50, y: 40)))
        XCTAssertTrue(zone.contains(CGPoint(x: 12, y: 40)), "the face's rim starts a room")
        XCTAssertTrue(zone.contains(CGPoint(x: 0, y: 40)), "so does a hold just beside it")
        XCTAssertTrue(zone.contains(CGPoint(x: 50, y: -10)), "or just above it")
        XCTAssertFalse(zone.contains(CGPoint(x: -10, y: 40)), "the gap to the next cell moves")
        XCTAssertFalse(zone.contains(CGPoint(x: 50, y: 85)), "the name under it moves")

        // A drop's location reads in the cell's space whichever space it
        // comes in.
        let cell = CGRect(x: 200, y: 300, width: 110, height: 150)
        var seen = false
        XCTAssertEqual(BotDragPayload.cellPoint(CGPoint(x: 50, y: 40), cellInWindow: cell, windowSpace: &seen), CGPoint(x: 50, y: 40))
        XCTAssertEqual(BotDragPayload.cellPoint(CGPoint(x: 250, y: 340), cellInWindow: cell, windowSpace: &seen), CGPoint(x: 50, y: 40))
        XCTAssertEqual(BotDragPayload.cellPoint(CGPoint(x: 50, y: 40), cellInWindow: .zero, windowSpace: &seen), CGPoint(x: 50, y: 40))

        // A first-row cell near the window's corner: a window point over its
        // face also fits the cell's own bounds. Taken as documented until a
        // point outside them shows the window's space, then read that way.
        let corner = CGRect(x: 16, y: 125, width: 110, height: 160)
        var windowSpace = false
        XCTAssertEqual(BotDragPayload.cellPoint(CGPoint(x: 60, y: 140), cellInWindow: corner, windowSpace: &windowSpace), CGPoint(x: 60, y: 140))
        XCTAssertFalse(windowSpace)
        XCTAssertEqual(BotDragPayload.cellPoint(CGPoint(x: 60, y: 200), cellInWindow: corner, windowSpace: &windowSpace), CGPoint(x: 44, y: 75))
        XCTAssertTrue(windowSpace)
        XCTAssertEqual(BotDragPayload.cellPoint(CGPoint(x: 60, y: 140), cellInWindow: corner, windowSpace: &windowSpace), CGPoint(x: 44, y: 15))
        // A point outside the cell's window frame is left alone.
        XCTAssertEqual(BotDragPayload.cellPoint(CGPoint(x: 5, y: 5), cellInWindow: corner, windowSpace: &windowSpace), CGPoint(x: 5, y: 5))
        XCTAssertTrue(BotDragPayload.staysStill(CGPoint(x: 55, y: 45), from: CGPoint(x: 50, y: 40)))
        XCTAssertFalse(BotDragPayload.staysStill(CGPoint(x: 70, y: 40), from: CGPoint(x: 50, y: 40)))
    }

    /// Group Settings from a room's tile shows once that room is open and
    /// its settings are read, and not for another room or long after.
    func testGroupSettingsFromATileWaitsForItsRoomBriefly() {
        let now = Date()
        let request = GroupSettingsRequest(roomID: "r", at: now)
        XCTAssertTrue(request.shows(openRoomID: "r", canEdit: true, now: now.addingTimeInterval(2)))
        XCTAssertFalse(request.shows(openRoomID: "r", canEdit: false, now: now), "settings not read yet")
        XCTAssertFalse(request.shows(openRoomID: "other", canEdit: true, now: now))
        XCTAssertFalse(request.shows(openRoomID: "r", canEdit: true,
                                     now: now.addingTimeInterval(GroupSettingsRequest.lifetime + 1)))
    }

    /// A drop ends the hover before it lands, so a face that was swollen a
    /// moment before still starts a room (Eric 2026-11-04: it never did).
    func testADropJustAfterTheFaceSwelledStillStartsARoom() {
        let now = Date()
        XCTAssertTrue(BotDragPayload.dropMerges(mergeReady: true, endedAt: nil, now: now))
        XCTAssertTrue(BotDragPayload.dropMerges(mergeReady: false, endedAt: now.addingTimeInterval(-0.2), now: now))
        XCTAssertFalse(BotDragPayload.dropMerges(mergeReady: false, endedAt: now.addingTimeInterval(-2), now: now),
                       "a hover that ended a while ago moves")
        XCTAssertFalse(BotDragPayload.dropMerges(mergeReady: false, endedAt: nil, now: now), "never swollen: moves")
        // After a slide into its place, a drop only acts to start a room.
        XCTAssertFalse(BotDragPayload.dropActs(placed: true, merges: false), "slid here: a plain drop doesn't move it back")
        XCTAssertTrue(BotDragPayload.dropActs(placed: true, merges: true), "slid here, then held still: the room starts")
        XCTAssertTrue(BotDragPayload.dropActs(placed: false, merges: false))
    }

    /// Pinned bots come first, each group in the person's order, so Pin
    /// does something once the bots have been dragged into an order
    /// (Eric 2026-11-04).
    @MainActor
    func testPinnedBotsComeFirstInThePersonsOrder() throws {
        func bot(_ name: String, pinned: Bool = false) -> BotProfile {
            BotProfile(name: name, botTitle: nil, displayName: name, profileDescription: "", model: nil,
                       provider: nil, hasAvatar: false, isPinned: pinned, isHiddenByMeta: false,
                       appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil)
        }
        let suite = "BotWorkstreamsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.setBotOrder(BotOrder(names: ["atlas", "furina", "nahida", "raiden"]))
        let roster = [bot("raiden", pinned: true), bot("nahida"), bot("furina", pinned: true), bot("atlas")]
        XCTAssertEqual(appState.orderedBots(roster).map(\.name), ["furina", "raiden", "atlas", "nahida"])
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

        // So does a room Bots Home opens, with no Bot Chat under it.
        let room = BotZoomArm.roomKey("trip")
        appState.beginOpeningBotChat(room)
        XCTAssertEqual(V2Tab.conversationTab(selected: .bots, isBotsChat: appState.placesConversationAsBotChat), .bots)
        appState.botChatOpeningPlaced()
        appState.endOpeningBotChat(room)
        XCTAssertNil(appState.botChatOpening)
    }

    /// A portrait's status: what needs the user first, then what's
    /// working, else nothing, and nothing while work is off.
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
        XCTAssertEqual(BotPortraitStatus.idle.title, "")
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

/// Bot Screen: the host's screen status and lease as Hermes gives them, who
/// drives the bot's screen as the plugin keeps it, and the keys the type bar
/// sends.
extension BotModeTests {
    private func screenStatus(_ fields: [String: Any]) throws -> BotScreenStatus {
        let object = try XCTUnwrap(AnyCodable(jsonObject: fields).objectValue)
        return try XCTUnwrap(BotScreenStatus(object))
    }

    func testBotScreenStatusReadsHermesFields() throws {
        let status = try screenStatus([
            "supported": true, "installed": false, "missing": ["xvfb", "xfce4"], "running": false,
            "geometry": "1280x800", "install_command": "sudo apt-get install -y xvfb xfce4",
            "profile": "furina", "profile_key": "abc",
            "lease": ["holder": "human", "viewer_hash": "0123456789ab", "epoch": 3],
            "image_switch": ["current_image": "python:3.12", "target_image": "hermes-desktop"],
        ])
        XCTAssertTrue(status.isSupported)
        XCTAssertFalse(status.isInstalled)
        XCTAssertEqual(status.missing, ["xvfb", "xfce4"])
        XCTAssertEqual(status.installCommand, "sudo apt-get install -y xvfb xfce4")
        XCTAssertEqual(status.aspectRatio, 1.6, accuracy: 0.001)
        XCTAssertEqual(status.imageSwitch, .init(current: "python:3.12", target: "hermes-desktop"))
        XCTAssertTrue(status.lease.isHuman)
        XCTAssertEqual(status.lease.epoch, 3)
        XCTAssertTrue(status.lease.isHeld(byViewerHash: "0123456789ab"))
        XCTAssertFalse(status.lease.isHeld(byViewerHash: "ffffffffffff"))
        XCTAssertFalse(status.lease.isHeld(byViewerHash: nil))
        // No "supported" field: not a status at all.
        XCTAssertNil(BotScreenStatus(try XCTUnwrap(AnyCodable(jsonObject: ["running": true]).objectValue)))
    }

    func testBotScreenLeaseDefaultsToTheBot() throws {
        let status = try screenStatus(["supported": false, "geometry": "wide"])
        XCTAssertFalse(status.isSupported)
        XCTAssertFalse(status.lease.isHuman)
        XCTAssertEqual(status.aspectRatio, 1.6, accuracy: 0.001)
    }

    func testBotScreenViewerHashMatchesHermes() {
        // hashlib.sha256(b"viewer-1").hexdigest()[:12]
        XCTAssertEqual(BotScreenLease.hash(ofViewer: "viewer-1"), "63a9e8a8c2d8")
    }

    func testBotScreenUseKeepsNowApartFromLast() throws {
        let use = try XCTUnwrap(BotScreenUse([
            "controlling": NSNull(),
            "last": ["session_id": "w1", "kind": "workstream", "ref": "W1", "title": "Login bug", "at": 1_800_000_000.0],
            "waiting": [["session_id": "w2", "ref": "W2"], ["session_id": "chat"]],
        ]))
        XCTAssertNil(use.controlling)
        XCTAssertEqual(use.last?.ref, "W1")
        XCTAssertEqual(use.last?.at, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(use.waitingRefs, ["W2"])
        XCTAssertEqual(BotScreenUse.name(of: try XCTUnwrap(use.last)), "W1")
        XCTAssertNil(BotScreenUse(nil))
    }

    func testBotScreenKeysyms() {
        XCTAssertEqual(BotScreenKey.keysym(for: "a"), 0x61)
        XCTAssertEqual(BotScreenKey.keysym(for: "é"), 0xE9)
        XCTAssertEqual(BotScreenKey.keysym(for: "€"), 0x0100_20AC)
        XCTAssertEqual(BotScreenKey.keysym(for: "\n"), 0xFF0D)
        XCTAssertEqual(BotScreenKey.escape.keysym, 0xFF1B)
    }

    func testWorkRowReadsItsScreenAndAScreenAskNeedsYou() throws {
        let response: [String: Any] = [
            "ok": true, "policy": "strict", "bot": "Furina",
            "counts": ["working": 0, "needs_you": 1, "ready": 0],
            "screen": ["controlling": ["session_id": "w2", "kind": "workstream", "ref": "W2", "since": 1_800_000_000.0]],
            "work": [
                ["ref": "W1", "kind": "workstream", "status": "ready", "title": "Sign in", "session_id": "w1",
                 "screen": "", "screen_used_at": 1_800_000_000.0, "screen_ask": "Sign in to GitHub",
                 "actions": ["send"]],
                ["ref": "W2", "kind": "workstream", "status": "running", "title": "Book", "session_id": "w2",
                 "screen": "controlling", "screen_used_at": 1_800_000_100.0, "actions": ["send", "stop"]],
            ],
        ]
        let snapshot = try XCTUnwrap(BotWorkSnapshot(response: response, profile: "furina"))
        XCTAssertEqual(snapshot.screen?.controlling?.ref, "W2")
        let asking = snapshot.items[0]
        XCTAssertEqual(asking.screenAsk, "Sign in to GitHub")
        XCTAssertTrue(asking.needsYou)
        XCTAssertEqual(asking.screen, "")
        XCTAssertNotNil(asking.screenUsedAt)
        XCTAssertEqual(snapshot.items[1].screen, "controlling")
        XCTAssertFalse(snapshot.items[1].needsYou)
        // Told to carry on: its ask goes, and so does its "needs you".
        var row: [String: Any] = try XCTUnwrap((response["work"] as? [[String: Any]])?.first)
        row["status"] = "running"
        row["screen_ask"] = ""
        let moved = snapshot.replacing(try XCTUnwrap(BotWorkItem(row: row)))
        XCTAssertEqual(moved.needsYouCount, 0)
        XCTAssertEqual(moved.workingCount, 1)
        // A done row still asking stays in Active, where its count points.
        var done = try XCTUnwrap((response["work"] as? [[String: Any]])?.first)
        done["status"] = "done"
        let doneAsking = try XCTUnwrap(BotWorkItem(row: done))
        XCTAssertTrue(doneAsking.isActive)
        XCTAssertTrue(doneAsking.needsYou)
    }
}
