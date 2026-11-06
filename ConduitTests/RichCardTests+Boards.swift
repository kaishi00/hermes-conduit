//
//  RichCardTests+Boards.swift
//  ConduitTests
//
//  Boards (Cards Hermes shows in docs/FEATURE_MAP.md): the board kinds as
//  the views read them, a board's tabs, follow-ups and Markdown, how cards
//  lay out, and checklist ticks. An extension of an existing class, so the
//  test planner needs no new entry.
//

import XCTest
@testable import Conduit

extension AppStateVoiceCapabilityTests {
    private func boardTool(_ answer: [String: Any], id: String = "t1") throws -> ToolActivity {
        let output = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: answer), encoding: .utf8))
        return ToolActivity(id: id, name: "conduit_show", input: #"{"title": "Trip"}"#, output: output, status: .complete)
    }

    private func card(_ json: [String: Any], id: Int = 0) throws -> RichCard {
        try XCTUnwrap(RichCard(normalized: json, id: id))
    }

    func testABoardKeepsItsTabsAndOnlyPlainFollowUps() throws {
        let answer: [String: Any] = [
            "ok": true, "layout": "tabs", "markdown": "## Trip",
            "cards": [
                ["type": "table", "title": "Hotels", "table": ["columns": ["Name", "Price"], "rows": [["Ahwahnee", "$600"]]]],
                ["type": "callout", "callout": ["text": "Book permits early.", "tone": "warning"]],
            ],
            "next": ["Make it cheaper", "make it cheaper", "/reset", "Ask @furina", "Use `ls`", "Add a rest day",
                     "Swap day 2 and 3", "Over a week", "One too many"],
        ]
        let board = try XCTUnwrap(RichBoard.board(for: boardTool(answer)))
        XCTAssertEqual(board.cards.map(\.kind), [.table, .callout])
        XCTAssertTrue(board.tabs)
        XCTAssertEqual(board.followUps, ["Make it cheaper", "Add a rest day", "Swap day 2 and 3", "Over a week"],
                       "commands, mentions, code and repeats are left out, then the first four")
        XCTAssertEqual(board.cards.first?.table?.rows, [["Ahwahnee", "$600"]])
        XCTAssertEqual(board.cards.last?.callout?.tone, .warning)

        var single = answer
        single["cards"] = [["type": "callout", "callout": ["text": "Book permits early."]]]
        XCTAssertFalse(try XCTUnwrap(RichBoard.board(for: boardTool(single))).tabs, "one card needs no tabs")
    }

    /// Issue 1867: the Markdown a board falls back to is card text too, so
    /// what it draws and what its copy controls paste is cleaned.
    func testABoardsMarkdownFallbackMarksHiddenCharactersAndKeepsItsLines() throws {
        let answer: [String: Any] = [
            "ok": true, "markdown": "## Fix the \u{202E}admin\u{202C} check\u{200B}\u{2060}\u{FEFF}\n\n\tok = role != 'user\u{2066}'\u{7}\n👨\u{200D}👩\u{200D}👧",
            "cards": [["type": "hologram", "hologram": ["x": 1]]],
        ]
        let board = try XCTUnwrap(RichBoard.board(for: boardTool(answer, id: "t1867")))
        XCTAssertTrue(board.cards.isEmpty)
        let markdown = try XCTUnwrap(board.markdown)
        XCTAssertEqual(markdown, "## Fix the \u{FFFD}admin\u{FFFD} check\u{FFFD}\u{FFFD}\u{FFFD}\n\n\tok = role != 'user\u{FFFD}' \n👨\u{200D}👩\u{200D}👧",
                       "a hidden one shows as a mark, a bell is a space; lines, tabs and an emoji's joiners stay")
        XCTAssertTrue(markdown.unicodeScalars.filter(RichCardSchema.isHidden).isEmpty, "copying pastes none of them")
    }

    func testABoardConduitCantFullyDrawShowsItsMarkdownInstead() throws {
        let answer: [String: Any] = [
            "ok": true, "markdown": "## Trip\n\n- Day 1: Valley",
            "cards": [
                ["type": "callout", "callout": ["text": "Bring layers."]],
                ["type": "hologram", "hologram": ["x": 1]],
            ],
        ]
        let board = try XCTUnwrap(RichBoard.board(for: boardTool(answer)))
        XCTAssertTrue(board.cards.isEmpty, "never part of a board")
        XCTAssertEqual(board.markdown, "## Trip\n\n- Day 1: Valley")
        var withNext = answer
        withNext["next"] = ["Add a day"]
        XCTAssertEqual(RichBoard.board(for: try boardTool(withNext))?.followUps, ["Add a day"], "the text keeps its follow-ups")

        let message = ChatMessage(id: "m1", role: .tool, content: "", timestamp: "2026-11-03T22:00:00Z",
                                  tool: try boardTool(answer))
        XCTAssertTrue(RichCard.hasCards(message), "the Markdown stands in the cards' place")

        var older = answer
        older["markdown"] = nil
        XCTAssertNotNil(RichBoard.board(for: try boardTool(older)), "an older plugin's answer draws what it can")
        older["cards"] = [["type": "hologram"]]
        XCTAssertNil(RichBoard.board(for: try boardTool(older)))

        // No cards given is a Markdown-only show, or Markdown Hermes puts in
        // its reply (a room, Desktop): drawing it would show it twice.
        let textOnly: [String: Any] = ["ok": false, "error": "group_room", "markdown": "**Kin Khao**", "cards": []]
        XCTAssertNil(RichBoard.board(for: try boardTool(textOnly)))
    }

    func testAFinishedRowIsReadOnceUntilItsAnswerChanges() throws {
        // Issue 1851: a row's body asks for its board on every publish.
        let memo = FinishedToolMemo<Int>(limit: 2)
        var reads = 0
        let read = { () -> Int in reads += 1; return reads }
        let tool = try boardTool(["ok": true, "cards": [["type": "callout", "callout": ["text": "Done."]]]])
        XCTAssertEqual(memo.value(for: tool, make: read), 1)
        XCTAssertEqual(memo.value(for: tool, make: read), 1, "drawn again, not read again")
        var copy = tool
        copy.output = String(decoding: Array(tool.output!.utf8), as: UTF8.self)
        XCTAssertEqual(memo.value(for: copy, make: read), 1, "the same answer read again from history")
        var changed = tool
        changed.output = tool.output!.replacingOccurrences(of: "Done.", with: "Gone.")
        XCTAssertEqual(changed.output?.utf8.count, tool.output?.utf8.count)
        XCTAssertEqual(memo.value(for: changed, make: read), 2, "same id and size, another answer")
        XCTAssertEqual(memo.value(for: tool, id: "row", make: read), 3, "kept by the row's id when given")
        XCTAssertEqual(memo.value(for: tool, make: read), 4, "its slot held the other answer")
        XCTAssertEqual(memo.value(for: tool, id: "row", make: read), 5, "past the limit the memo starts over")

        let bytes = (tool.input?.utf8.count ?? 0) + (tool.output?.utf8.count ?? 0)
        let small = FinishedToolMemo<Int>(limit: 10, byteBudget: bytes * 2)
        XCTAssertEqual(small.value(for: tool, id: "a") { 1 }, 1)
        XCTAssertEqual(small.value(for: tool, id: "b") { 2 }, 2)
        XCTAssertEqual(small.value(for: tool, id: "a") { 3 }, 1, "within its budget")
        XCTAssertEqual(small.value(for: tool, id: "c") { 4 }, 4)
        XCTAssertEqual(small.value(for: tool, id: "a") { 5 }, 5, "past its budget the memo starts over")

        let first = try XCTUnwrap(RichBoard.board(for: tool))
        let second = try XCTUnwrap(RichBoard.board(for: changed))
        XCTAssertEqual(first.cards.first?.callout?.text, "Done.")
        XCTAssertEqual(second.cards.first?.callout?.text, "Gone.", "a reused id never draws the old board")
    }

    func testFollowUpsAreOfferedOnlyUnderTheLastTurnsBoard() throws {
        let answer: [String: Any] = ["ok": true, "next": ["Add Google"],
                                     "cards": [["type": "callout", "callout": ["text": "Prices from Yahoo Finance."]]]]
        let board = ChatMessage(id: "b1", role: .tool, content: "", timestamp: "2026-11-03T22:00:00Z", tool: try boardTool(answer))
        let reply = ChatMessage(id: "a1", role: .assistant, content: "Here they are.", timestamp: "2026-11-03T22:00:01Z")
        let asked = ChatMessage(id: "u1", role: .user, content: "Compare them", timestamp: "2026-11-03T21:59:00Z")
        XCTAssertEqual(RichBoard.followUpRow(in: [asked, board, reply]), "b1")
        let next = ChatMessage(id: "u2", role: .user, content: "Add Google", timestamp: "2026-11-03T22:01:00Z")
        XCTAssertNil(RichBoard.followUpRow(in: [asked, board, reply, next]), "something was sent since")
        let plain: [String: Any] = ["ok": true, "cards": [["type": "callout", "callout": ["text": "Done."]]]]
        let later = ChatMessage(id: "b2", role: .tool, content: "", timestamp: "2026-11-03T22:00:02Z", tool: try boardTool(plain, id: "t2"))
        XCTAssertNil(RichBoard.followUpRow(in: [asked, board, later]), "only the turn's last board offers them")
    }

    @MainActor
    func testFollowUpsShowOnlyWhileASendCanGo() throws {
        let suite = "RichBoardFollowUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        var facts = ChatRowFacts()
        facts.followUpBoardRowID = "b1"
        appState.isConnected = false
        XCTAssertNil(ChatRowState(appState, facts: facts).followUpBoardRowID, "a tap couldn't send")
        appState.isConnected = true
        XCTAssertTrue(appState.composerIsEnabled)
        XCTAssertEqual(ChatRowState(appState, facts: facts).followUpBoardRowID, "b1")
    }

    func testATableSortsNumbersByValueWithBlanksLast() throws {
        let table = RichTable(columns: ["Company", "Revenue"], rows: [
            ["Acme", "$1.2M"], ["Globex", RichCardSchema.blankCell], ["Initech", "$950K"], ["Umbrella", "$3B"],
        ])
        XCTAssertTrue(table.isNumeric(1))
        XCTAssertFalse(table.isNumeric(0))
        XCTAssertEqual(table.sorted(by: 1, ascending: false).map { $0[0] }, ["Umbrella", "Acme", "Initech", "Globex"])
        XCTAssertEqual(table.sorted(by: 1, ascending: true).map { $0[0] }, ["Initech", "Acme", "Umbrella", "Globex"])
        XCTAssertEqual(table.sorted(by: 0, ascending: false).map { $0[0] }, ["Umbrella", "Initech", "Globex", "Acme"])
        XCTAssertEqual(RichTable.sortNumber("-4.5%"), -4.5)
        XCTAssertEqual(RichTable.sortNumber("1,250 kg"), 1250)
        XCTAssertNil(RichTable.sortNumber("n/a"))
        XCTAssertNil(RichTable.sortNumber("Nov 3, 2026"), "a date reads as text")
        XCTAssertNil(RichTable.sortNumber("2026-11-03"))
        XCTAssertEqual(RichTable.sortNumber("5 m"), 5)
        XCTAssertEqual(RichTable.sortNumber("€950K"), 950_000)
        XCTAssertEqual(RichTable.sortNumber("900KB"), 900_000)
        XCTAssertEqual(RichTable.sortNumber("512GB"), 512e9)
        XCTAssertEqual(RichTable.sortNumber("3TB"), 3e12)
        XCTAssertEqual(RichTable.sortNumber("$950m"), 950e6)
        XCTAssertEqual(RichTable.sortNumber("1.250,50 €"), 1250.5, "a decimal comma")
        XCTAssertEqual(RichTable.sortNumber("980,00 €"), 980)
        XCTAssertEqual(RichTable.sortNumber("1.250.000"), 1_250_000)
        XCTAssertEqual(RichTable.sortNumber("1,250,000.5"), 1_250_000.5)
        XCTAssertEqual(RichTable.sortNumber("4,5 %"), 4.5)
        XCTAssertEqual(RichTable.sortNumber("$2b"), 2e9)
        XCTAssertEqual(RichTable.sortNumber("512gb"), 512e9)
        XCTAssertEqual(RichTable.sortNumber("3tb"), 3e12)
        XCTAssertEqual(RichTable.sortNumber("3 kg"), 3)
        XCTAssertEqual(RichTable.sortNumber("-$4.5M"), -4.5e6)
        XCTAssertEqual(RichTable.sortNumber("($4.5M)"), -4.5e6)
        XCTAssertEqual(table.sorted(by: 5, ascending: true), table.rows, "a sort kept from a wider table changes nothing")
        XCTAssertFalse(table.isNumeric(5))
    }

    func testSmallCardsPairUpOnlyOnAWideWindow() throws {
        let callout = try card(["type": "callout", "callout": ["text": "Tip."]], id: 0)
        let progress = try card(["type": "progress", "progress": [["label": "Saved", "value": 1250, "goal": 5000]]], id: 1)
        let table = try card(["type": "table", "table": ["columns": ["A"], "rows": [["1"]]]], id: 2)
        let warning = try card(["type": "callout", "callout": ["text": "Closed Mondays.", "tone": "warning"]], id: 3)
        let wide = RichBoardLayout.rows([callout, progress, table, warning], wide: true)
        XCTAssertEqual(wide.map { $0.map(\.id) }, [[0, 1], [2], [3]])
        XCTAssertEqual(RichBoardLayout.rows([callout, progress], wide: false).map(\.count), [1, 1])
        XCTAssertEqual(progress.progress.first?.fraction, 0.25)
    }

    func testChecklistItemsKeepTheirGroupsInHermesOrder() throws {
        let list = try card(["type": "checklist", "checklist": [
            ["text": "Passport", "group": "Documents"], ["text": "Rain jacket", "group": "Clothes"],
            ["text": "Visa", "group": "Documents"], ["text": "Charger"],
        ]])
        let groups = RichChecklistCard.groups(list.checklist)
        XCTAssertEqual(groups.map(\.name), ["Documents", "Clothes", nil])
        XCTAssertEqual(groups.first?.items.map(\.text), ["Passport", "Visa"])
    }

    @MainActor
    func testChecklistTicksAreKeptByTheListsNameAndSurviveARelaunch() throws {
        let suite = "RichChecklistMemoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = try card(["type": "checklist", "title": "Iceland in June", "live": "Packing",
                             "checklist": [["text": "Rain jacket"], ["text": "Swimsuit"]]])
        let key = RichChecklistMemory.listKey(for: list)
        XCTAssertEqual(key, "packing", "the live name, as the plugin's list_key")
        XCTAssertEqual(RichChecklistMemory.listKey(for: try card(["type": "checklist", "title": "Moving House",
                                                                  "checklist": [["text": "Boxes"]]])), "moving house")

        let memory = RichChecklistMemory(defaults: defaults)
        memory.toggle("Swimsuit", card: list, key: key, context: nil)
        XCTAssertEqual(memory.ticked(scope: RichChecklistMemory.localScope, key: key), ["swimsuit"])
        XCTAssertEqual(RichChecklistMemory(defaults: defaults).ticked(scope: RichChecklistMemory.localScope, key: key),
                       ["swimsuit"], "kept on the phone")
        memory.toggle("swimsuit", card: list, key: key, context: nil)
        XCTAssertTrue(memory.ticked(scope: RichChecklistMemory.localScope, key: key).isEmpty, "ticks compare without case")
    }

    @MainActor
    func testAChatsChecklistTickIsSavedOnTheHostAndTheHostsTicksWin() async throws {
        let suite = "RichChecklistMemoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = try card(["type": "checklist", "title": "Packing",
                             "checklist": [["text": "Rain jacket"], ["text": "Swimsuit"]]])
        var saved: [[String: Any]] = []
        var host: [String: [String]] = ["packing": ["Rain jacket"]]
        let context = RichChecklistContext(
            scope: "work/s1", sessionIDs: ["s1", "r1"],
            read: { host },
            save: { body in
                saved.append(body)
                // The plugin applies one tick to its newest ticks.
                let change = body["change"] as? [String: Any]
                var done = Set((host["packing"] ?? []).map { $0.lowercased() })
                if let item = (change?["item"] as? String)?.lowercased() {
                    if change?["ticked"] as? Bool == true { done.insert(item) } else { done.remove(item) }
                }
                host["packing"] = (body["items"] as? [String] ?? []).filter { done.contains($0.lowercased()) }
                return host
            })
        let memory = RichChecklistMemory(defaults: defaults)
        await memory.refresh(context: context, key: "packing")
        XCTAssertEqual(memory.ticked(scope: "work/s1", key: "packing"), ["rain jacket"])

        memory.toggle("Swimsuit", card: list, key: "packing", context: context)
        for _ in 0..<50 where saved.isEmpty { await Task.yield() }
        XCTAssertEqual(saved.first?["change"] as? [String: AnyHashable], ["item": "Swimsuit", "ticked": true], "one tick at a time")
        XCTAssertEqual(saved.first?["sessions"] as? [String], ["s1", "r1"])
        XCTAssertEqual(memory.ticked(scope: "work/s1", key: "packing"), ["rain jacket", "swimsuit"])
        for _ in 0..<50 where memory.entries.values.contains(where: \.unsent) { await Task.yield() }
        XCTAssertFalse(memory.entries.values.contains(where: \.unsent), "saved on the host")

        // Two quick taps reach the host in order, the second after the first.
        memory.toggle("Swimsuit", card: list, key: "packing", context: context)
        memory.toggle("Swimsuit", card: list, key: "packing", context: context)
        for _ in 0..<100 where memory.entries.values.contains(where: \.unsent) { await Task.yield() }
        XCTAssertEqual(saved.suffix(2).map { $0["change"] as? [String: AnyHashable] },
                       [["item": "Swimsuit", "ticked": false], ["item": "Swimsuit", "ticked": true]])
        XCTAssertEqual(host["packing"], ["Rain jacket", "Swimsuit"])

        host["packing"] = []
        await memory.refresh(context: context, key: "packing")
        XCTAssertTrue(memory.ticked(scope: "work/s1", key: "packing").isEmpty, "another device unticked them")
        XCTAssertTrue(memory.ticked(scope: RichChecklistMemory.localScope, key: "packing").isEmpty, "a chat's ticks aren't the call screen's")
    }

    @MainActor
    func testARefusedChecklistSaveKeepsTheTickToSendLater() async throws {
        // #1745: after a dashboard switch the chat's saves are refused; the
        // tick stays unsent, in order, and goes when the chat is drawn on
        // its own dashboard again.
        let suite = "RichChecklistMemoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = try card(["type": "checklist", "title": "Packing",
                             "checklist": [["text": "Rain jacket"], ["text": "Swimsuit"]]])
        var refused = 0
        let elsewhere = RichChecklistContext(
            scope: "work/s1", sessionIDs: ["s1"],
            read: { refused += 1; throw DashboardTicketBridgeError.notReady },
            save: { _ in refused += 1; throw DashboardTicketBridgeError.notReady })
        let memory = RichChecklistMemory(defaults: defaults)
        memory.toggle("Swimsuit", card: list, key: "packing", context: elsewhere)
        memory.toggle("Rain jacket", card: list, key: "packing", context: elsewhere)
        for _ in 0..<50 where refused < 1 { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        let entry = try XCTUnwrap(memory.entries.values.first)
        XCTAssertTrue(entry.unsent, "not saved anywhere")
        XCTAssertEqual(entry.changes, [RichChecklistMemory.Change(item: "Swimsuit", ticked: true),
                                       RichChecklistMemory.Change(item: "Rain jacket", ticked: true)])

        var saved: [[String: AnyHashable]] = []
        let home = RichChecklistContext(
            scope: "work/s1", sessionIDs: ["s1"],
            read: { [:] },
            save: { body in
                saved.append(body["change"] as? [String: AnyHashable] ?? [:])
                return ["packing": ["Rain jacket", "Swimsuit"]]
            })
        await memory.refresh(context: home, key: "packing")
        XCTAssertEqual(saved, [["item": "Swimsuit", "ticked": true], ["item": "Rain jacket", "ticked": true]])
        XCTAssertFalse(memory.entries.values.contains(where: \.unsent))
        XCTAssertEqual(memory.ticked(scope: "work/s1", key: "packing"), ["rain jacket", "swimsuit"])
    }

    @MainActor
    func testAnUnsentTickFollowsTheChatWhenItsIdsGrow() async throws {
        let suite = "RichChecklistMemoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = try card(["type": "checklist", "title": "Packing",
                             "checklist": [["text": "Rain jacket"], ["text": "Swimsuit"]]])
        var online = false
        var saved: [[String: Any]] = []
        var host: [String: [String]] = ["packing": ["Rain jacket"]]
        func context(_ profile: String, _ ids: [String]) -> RichChecklistContext {
            RichChecklistContext(
                scope: RichChecklistContext.scope(profile: profile, sessionIDs: ids), sessionIDs: ids,
                read: { host },
                save: { body in
                    guard online else { throw URLError(.notConnectedToInternet) }
                    saved.append(body)
                    let change = body["change"] as? [String: Any]
                    var done = Set((host["packing"] ?? []).map { $0.lowercased() })
                    if let item = (change?["item"] as? String)?.lowercased() {
                        if change?["ticked"] as? Bool == true { done.insert(item) } else { done.remove(item) }
                    }
                    host["packing"] = (body["items"] as? [String] ?? []).filter { done.contains($0.lowercased()) }
                    return host
                })
        }
        let before = context("work", ["r1"])
        let memory = RichChecklistMemory(defaults: defaults)
        await memory.refresh(context: before, key: "packing")
        memory.toggle("Swimsuit", card: list, key: "packing", context: before)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(saved.isEmpty, "offline: the tick waits on the phone")
        // Another chat, and the same ids in another profile, keep their own.
        memory.toggle("Rain jacket", card: list, key: "packing", context: context("work", ["other"]))
        memory.toggle("Rain jacket", card: list, key: "packing", context: context("home", ["r1"]))
        for _ in 0..<50 { await Task.yield() }

        // The chat's durable id is confirmed: its scope grows.
        online = true
        let after = context("work", ["r1", "s1"])
        XCTAssertEqual(memory.ticked(scope: after.scope, key: "packing"), [], "not read yet")
        await memory.refresh(context: after, key: "packing")
        for _ in 0..<100 where memory.ticked(scope: after.scope, key: "packing").isEmpty
            || memory.entries.contains(where: { $0.key.hasPrefix(after.scope) && $0.value.unsent }) { await Task.yield() }
        XCTAssertEqual(saved.first?["change"] as? [String: AnyHashable], ["item": "Swimsuit", "ticked": true])
        XCTAssertEqual(saved.first?["sessions"] as? [String], ["r1", "s1"])
        XCTAssertEqual(host["packing"], ["Rain jacket", "Swimsuit"], "the tick reached the host")
        XCTAssertEqual(memory.ticked(scope: after.scope, key: "packing"), ["rain jacket", "swimsuit"], "and still shows")
        XCTAssertEqual(memory.ticked(scope: before.scope, key: "packing"), [], "nothing left under the old ids")
        XCTAssertEqual(memory.ticked(scope: context("work", ["other"]).scope, key: "packing"), ["rain jacket"])
        XCTAssertEqual(memory.ticked(scope: context("home", ["r1"]).scope, key: "packing"), ["rain jacket"])
    }

    @MainActor
    func testUnsentTicksFromTwoEarlierScopesGoInTheOrderMade() async throws {
        let suite = "RichChecklistMemoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = try card(["type": "checklist", "title": "Packing",
                             "checklist": [["text": "Rain jacket"], ["text": "Swimsuit"]]])
        var online = false
        var saved: [[String: AnyHashable]] = []
        func context(_ ids: [String]) -> RichChecklistContext {
            RichChecklistContext(
                scope: RichChecklistContext.scope(profile: "work", sessionIDs: ids), sessionIDs: ids,
                read: { [:] },
                save: { body in
                    guard online else { throw URLError(.notConnectedToInternet) }
                    saved.append(body["change"] as? [String: AnyHashable] ?? [:])
                    return [:]
                })
        }
        let memory = RichChecklistMemory(defaults: defaults)
        // The chat known by two ids not yet tied together, offline: a tick
        // under one, then the untick under the other.
        memory.toggle("Swimsuit", card: list, key: "packing", context: context(["r1"]))
        for _ in 0..<20 { await Task.yield() }
        memory.toggle("Swimsuit", card: list, key: "packing", context: context(["s1"]))
        memory.toggle("Swimsuit", card: list, key: "packing", context: context(["s1"]))
        for _ in 0..<20 { await Task.yield() }

        online = true
        let both = context(["r1", "s1"])
        await memory.refresh(context: both, key: "packing")
        XCTAssertEqual(saved, [["item": "Swimsuit", "ticked": true], ["item": "Swimsuit", "ticked": true],
                               ["item": "Swimsuit", "ticked": false]], "older ticks first, the last one made last")
        XCTAssertTrue(memory.ticked(scope: both.scope, key: "packing").isEmpty, "the last tick made shows")
        XCTAssertEqual(memory.entries.count, 1)
    }

    func testProgressNeedsAGoalAndAStopOpensInMaps() throws {
        XCTAssertNil(RichCard(normalized: ["type": "progress", "progress": [["label": "Saved", "value": 10, "goal": 0]]], id: 0))
        let saved = try XCTUnwrap(try card(["type": "progress", "progress": [
            ["label": "Saved", "value": 1250, "goal": 5000, "unit": "USD"]]]).progress.first)
        XCTAssertTrue(RichProgressCard.amount(saved).hasSuffix(" USD"))
        XCTAssertEqual(RichTimelineCard.mapsURL("Glacier Point, Yosemite")?.absoluteString,
                       "https://maps.apple.com/?q=Glacier%20Point,%20Yosemite")
    }

    func testARoomsBoardsGoUnderTheNextMessageTheirAgentPosts() throws {
        let callout: [String: Any] = ["cards": [["type": "callout", "callout": ["text": "Book early", "tone": "tip"]]],
                                      "markdown": "Book early"]
        let boards = RoomBoard.boards(["boards": [
            ["profile": "researcher", "at": 1_000, "board": callout],
            ["profile": "researcher", "at": 1_010, "board": callout],
            ["profile": "writer", "at": 1_020, "board": callout],
            ["profile": "researcher", "at": 5_000, "board": callout],
            ["profile": "nobody", "at": 1_000, "board": ["cards": [["type": "hologram"]]]],
        ]])
        XCTAssertEqual(boards.count, 4, "a board Conduit can't draw at all is left out")
        func message(_ seq: Int, _ profile: String, at: Double) -> GroupEvent {
            GroupEvent(roomID: "r", seq: seq, eventID: "e\(seq)", kind: "message.member",
                       actor: GroupActor(kind: "member", id: profile, profile: profile, displayName: nil, connectionID: nil),
                       authorityEpoch: nil, payload: ["text": .string("Here"), "thread_id": .string("main")], createdAt: at)
        }
        let events = [message(1, "researcher", at: 990), message(2, "researcher", at: 1_030), message(3, "writer", at: 1_040)]
        let placed = RoomBoard.placed(boards, in: events)
        XCTAssertNil(placed["e1"], "a message from before the board")
        XCTAssertEqual(placed["e2"]?.count, 2, "both of the turn's boards under its message")
        XCTAssertEqual(placed["e3"]?.count, 1)
        XCTAssertEqual(placed.values.map(\.count).reduce(0, +), 3, "a board whose message never came lands on none")
        XCTAssertTrue(RoomBoard.readPath(profile: "work", roomID: "room 1").hasSuffix("?profile=work&room_id=room%201"))
    }
}
