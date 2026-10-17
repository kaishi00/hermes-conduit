//
//  RichCardTests.swift
//  ConduitTests
//
//  Rich cards (Conduit/Cards): the shared schema's examples, which the
//  plugin's tests run too (hermes-conduit-notifier cards/card-vectors.json,
//  copied to Fixtures/), and how cards reach a chat and a live call. An
//  extension of an existing class, so the test planner needs no new entry.
//

import XCTest
@testable import Conduit

extension AppStateVoiceCapabilityTests {
    private func cardVectors() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle(for: AppStateVoiceCapabilityTests.self).url(forResource: "card-vectors", withExtension: "json"))
        let vectors = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(vectors["cases"] as? [[String: Any]])
    }

    func testRichCardSchemaNormalizesEverySharedExampleAsThePluginDoes() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled, "the app ships the schema")
        let cases = try cardVectors()
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for example in cases {
            let name = example["name"] as? String ?? "?"
            let output = schema.normalizeCards(example["input"])
            let expected = example["output"] as? [Any] ?? []
            XCTAssertTrue(NSArray(array: output).isEqual(to: expected), "\(name): \(output) != \(expected)")
            // Normalized cards stay as they are.
            XCTAssertTrue(NSArray(array: schema.normalizeCards(expected)).isEqual(to: expected), "\(name) isn't stable")
        }
    }

    func testRichCardLiveToolParameterIsTheSchemaInGeminisDialect() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let parameter = schema.liveToolParameter(description: "Cards.")
        XCTAssertEqual(parameter["type"] as? String, "ARRAY")
        XCTAssertEqual(parameter["maxItems"] as? Int, schema.maxCards)
        let card = try XCTUnwrap(parameter["items"] as? [String: Any])
        XCTAssertEqual(card["type"] as? String, "OBJECT")
        let places = try XCTUnwrap((card["properties"] as? [String: Any])?["places"] as? [String: Any])
        let place = try XCTUnwrap(places["items"] as? [String: Any])
        let rating = try XCTUnwrap((place["properties"] as? [String: Any])?["rating"] as? [String: Any])
        let url = try XCTUnwrap((rating["properties"] as? [String: Any])?["url"] as? [String: Any])
        XCTAssertEqual(url["type"] as? String, "STRING")
        XCTAssertNil(url["format"], "Gemini knows no uri format")
        XCTAssertEqual(rating["required"] as? [String], ["value", "source"])

        let parameters = GeminiLiveToolBridge.showOnScreenParameters(schema)
        XCTAssertEqual(parameters["required"] as? [String], ["title"], "cards alone are enough")
        XCTAssertNotNil((parameters["properties"] as? [String: Any])?["cards"])
        let withoutSchema = GeminiLiveToolBridge.showOnScreenParameters(nil)
        XCTAssertEqual(withoutSchema["required"] as? [String], ["title", "markdown"])
        XCTAssertNil((withoutSchema["properties"] as? [String: Any])?["cards"])
    }

    func testRichCardKeepsHermesFactsWithTheirSourcesOnly() throws {
        let raw: [[String: Any]] = [[
            "type": "place",
            "places": [[
                "name": "Tartine", "lat": 37.76, "lon": -122.42, "note": "Morning bun.",
                "rating": ["value": 4.6, "count": 5120, "source": "Google", "url": "https://g.test/t"] as [String: Any],
                "hours": ["text": "Open until 17:00"],
                "photo": ["url": "http://img.test/t.jpg", "source": "Yelp"],
            ] as [String: Any]],
        ]]
        let card = try XCTUnwrap(RichCard.cards(raw: raw).first)
        XCTAssertEqual(card.kind, .place)
        let place = try XCTUnwrap(card.places.first)
        XCTAssertEqual(place.rating, RichPlace.Rating(value: 4.6, count: 5120, source: "Google", url: URL(string: "https://g.test/t")))
        XCTAssertNil(place.hours, "hours without a source are left out")
        XCTAssertNil(place.photo, "only an https photo loads")
        XCTAssertEqual(place.note, "Morning bun.")
        XCTAssertEqual(place.givenCoordinate?.latitude, 37.76)
    }

    func testRichCardRouteStartsWhereTheUserIsWithoutAFrom() throws {
        let walk: [[String: Any]] = [[
            "type": "map", "places": [["name": "A"], ["name": "B"]], "route": ["to": 1, "mode": "walking"] as [String: Any],
        ]]
        let card = try XCTUnwrap(RichCard.cards(raw: walk).first)
        XCTAssertEqual(card.route, RichCard.Route(from: nil, to: 1, mode: .walking))
        let drive: [[String: Any]] = [["type": "map", "places": [["name": "A"]], "route": ["to": 0]]]
        let driving = try XCTUnwrap(RichCard.cards(raw: drive).first)
        XCTAssertEqual(driving.route?.mode, .driving)
    }

    func testRichCardsComeFromConduitShowsSavedAnswer() throws {
        let answer = #"{"ok": true, "cards": [{"type": "map", "places": [{"name": "Kin Khao", "lat": 37.78, "lon": -122.4}]}], "note": "Shown."}"#
        let tool = ToolActivity(id: "t1", name: "conduit_show", input: #"{"title": "Dinner"}"#, output: answer, status: .complete)
        XCTAssertEqual(RichCard.cards(for: tool).map(\.kind), [.map])
        XCTAssertEqual(RichCard.cards(for: tool).first?.places.map(\.name), ["Kin Khao"])

        // An answer without them falls back to the arguments, once it worked.
        let input = #"{"title": "Dinner", "cards": [{"type": "place", "places": [{"name": "Tartine"}]}]}"#
        let older = ToolActivity(id: "t2", name: "conduit_show", input: input, output: #"{"ok": true, "id": "c1"}"#, status: .complete)
        XCTAssertEqual(RichCard.cards(for: older).first?.places.map(\.name), ["Tartine"])
        let refused = ToolActivity(id: "t3", name: "conduit_show", input: input, output: #"{"ok": false, "error": "not_conduit"}"#, status: .complete)
        XCTAssertTrue(RichCard.cards(for: refused).isEmpty, "a refused call showed nothing")
        let running = ToolActivity(id: "t4", name: "conduit_show", input: input, output: nil, status: .running)
        XCTAssertTrue(RichCard.cards(for: running).isEmpty)
        let other = ToolActivity(id: "t5", name: "web_search", input: input, output: answer, status: .complete)
        XCTAssertTrue(RichCard.cards(for: other).isEmpty)
    }

    func testRichCardsReadAsPartOfTheReplyNotASteps() {
        let answer = #"{"ok": true, "cards": [{"type": "place", "places": [{"name": "Tartine"}]}]}"#
        let card = ChatMessage(id: "m1", role: .tool, content: "", timestamp: "2026-10-17T22:00:00Z",
                               tool: ToolActivity(id: "t1", name: "conduit_show", input: nil, output: answer, status: .complete))
        XCTAssertFalse(ChatStepGroup.isStep(card))
        let markdownOnly = ChatMessage(id: "m2", role: .tool, content: "", timestamp: "2026-10-17T22:00:00Z",
                                       tool: ToolActivity(id: "t2", name: "conduit_show", input: nil, output: #"{"ok": true, "id": "c"}"#, status: .complete))
        XCTAssertTrue(ChatStepGroup.isStep(markdownOnly), "a card for the call screen only stays a step")
    }

    func testLiveModelArgumentsKeepListsAsJSON() throws {
        let raw: [String: Any] = [
            "title": "Dinner", "count": 2, "cards": [["type": "place", "places": [["name": "Tartine"]]] as [String: Any]],
        ]
        let arguments = GeminiLiveProtocol.FunctionCall.stringArguments(raw)
        XCTAssertEqual(arguments["title"], "Dinner")
        XCTAssertEqual(arguments["count"], "2")
        let cards = try XCTUnwrap(arguments["cards"]?.data(using: .utf8))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: cards) as? [[String: Any]])
        XCTAssertEqual(decoded.first?["type"] as? String, "place")
    }

    func testSavedChatCallTurnsBringTheirCardsBack() throws {
        let shown: [String: Any] = [
            "role": "assistant", "text": "On screen: Tartine",
            "cards": [["type": "place", "places": [["name": "Tartine"]]] as [String: Any]],
        ]
        let response: [String: Any] = [
            "ok": true, "chat_id": "c",
            "calls": [["call_id": "call-1", "engine": "gemini-live", "turns": [["role": "user", "text": "Where's good?"] as [String: Any], shown]] as [String: Any]],
        ]
        let calls = try VoiceHistoryClient.chatCalls(from: response)
        XCTAssertEqual(calls.first?.turns.map(\.cards.count), [0, 1])
        XCTAssertEqual(calls.first?.turns.last?.cards.first?.places.first?.name, "Tartine")
    }
}
