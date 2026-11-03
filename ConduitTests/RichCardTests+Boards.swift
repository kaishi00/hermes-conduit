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

    func testProgressNeedsAGoalAndAStopOpensInMaps() throws {
        XCTAssertNil(RichCard(normalized: ["type": "progress", "progress": [["label": "Saved", "value": 10, "goal": 0]]], id: 0))
        let saved = try XCTUnwrap(try card(["type": "progress", "progress": [
            ["label": "Saved", "value": 1250, "goal": 5000, "unit": "USD"]]]).progress.first)
        XCTAssertTrue(RichProgressCard.amount(saved).hasSuffix(" USD"))
        XCTAssertEqual(RichTimelineCard.mapsURL("Glacier Point, Yosemite")?.absoluteString,
                       "https://maps.apple.com/?q=Glacier%20Point,%20Yosemite")
    }
}
