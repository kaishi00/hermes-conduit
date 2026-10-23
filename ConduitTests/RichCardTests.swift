//
//  RichCardTests.swift
//  ConduitTests
//
//  Rich cards (Conduit/Cards): the shared schema's examples, which the
//  plugin's tests run too (hermes-conduit-notifier cards/card-vectors.json,
//  copied to Fixtures/), and how cards reach a chat and a live call. An
//  extension of an existing class, so the test planner needs no new entry.
//

import MapKit
import UserNotifications
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

    func testACyclingRouteIsDrawnAndOpenedAsCycling() {
        // Not walking's time and line under the bicycle, and Maps opens on its bike directions.
        XCTAssertEqual(RichPlaceLookup.transportType(.cycling), .cycling)
        XCTAssertEqual(RichPlaceLookup.directionsMode(.cycling), MKLaunchOptionsDirectionsModeCycling)
        XCTAssertEqual(MapsNavigator.directionsMode(.cycling), MKLaunchOptionsDirectionsModeCycling)
        XCTAssertEqual(RichPlaceLookup.transportType(.walking), .walking)
        XCTAssertEqual(MapsNavigator.directionsMode(.walking), MKLaunchOptionsDirectionsModeWalking)
    }

    func testRichInformationCardsReadTheirOwnParts() throws {
        let stat: [String: Any] = ["label": "Steps", "value": "8,412", "change": "+12%", "trend": "up", "tone": "good", "spark": [1, 2, 3]]
        let series: [[String: Any]] = [["name": "Sales", "values": [5, 9.5]], ["values": [1]]]
        let chart: [String: Any] = ["kind": "bar", "unit": "USD", "labels": ["Mon", "Tue"], "series": series]
        let now: [String: Any] = ["temp": 18.5, "condition": "partly_cloudy"]
        let day: [String: Any] = ["day": "Tue", "low": 12, "high": 21, "condition": "rain", "precip": 60]
        let weather: [String: Any] = ["unit": "C", "now": now, "days": [day]]
        let steps: [[String: Any]] = [["text": "Boil water."], ["text": "Simmer.", "timer": 390]]
        let raw: [[String: Any]] = [
            ["type": "stats", "title": "Today", "source": ["name": "Health", "url": "https://h.test/s"], "stats": [stat]],
            ["type": "chart", "chart": chart],
            ["type": "weather", "source": ["name": "Open-Meteo"], "weather": weather],
            ["type": "steps", "needs": ["2 eggs"], "steps": steps],
        ]
        let cards = RichCard.cards(raw: raw)
        XCTAssertEqual(cards.map(\.kind), [.stats, .chart, .weather, .steps])
        XCTAssertEqual(cards[0].source, RichCardSource(json: ["name": "Health", "url": "https://h.test/s"]))
        XCTAssertEqual(cards[0].stats.first?.trend, .up)
        XCTAssertEqual(cards[0].stats.first?.spark, [1, 2, 3])
        XCTAssertEqual(cards[1].chart?.series.map(\.values), [[5, 9.5]], "a series that misses labels is left out")
        XCTAssertEqual(cards[2].weather?.now?.condition, .partlyCloudy)
        XCTAssertEqual(cards[2].weather?.days.first?.precip, 60)
        XCTAssertEqual(cards[3].needs, ["2 eggs"])
        XCTAssertEqual(cards[3].steps.map(\.timer), [nil, 390])
        XCTAssertTrue(cards.allSatisfy(\.places.isEmpty))

        let clear: [String: Any] = ["unit": "C", "now": ["temp": 18, "condition": "clear"] as [String: Any]]
        let unsourced: [[String: Any]] = [["type": "weather", "weather": clear]]
        XCTAssertTrue(RichCard.cards(raw: unsourced).isEmpty, "a forecast needs its source")
        let options: [[String: Any]] = [["name": "A", "recommended": true], ["name": "B", "recommended": true]]
        let comparison: [[String: Any]] = [["type": "comparison", "options": options]]
        XCTAssertEqual(RichCard.cards(raw: comparison).first?.options.map(\.recommended), [true, false])
    }

    func testRichMediaContactAndStatusCardsReadTheirOwnParts() throws {
        let photo: [String: Any] = ["kind": "image", "url": "https://p.test/a.jpg", "title": "Bridge"]
        let clip: [String: Any] = ["kind": "audio", "url": "https://p.test/a.mp3", "duration": 185, "artwork": "https://p.test/c.jpg"]
        let person: [String: Any] = ["name": "Ada Lovelace", "phone": "+44 (20) 7946-0958", "email": "ada@example.org"]
        let milestones: [[String: Any]] = [["label": "Ordered", "done": true], ["label": "Delivered"]]
        let status: [String: Any] = ["state": "On its way", "phase": "active", "progress": 0.6, "milestones": milestones]
        let raw: [[String: Any]] = [
            ["type": "media", "source": ["name": "Wikimedia"], "media": [photo, clip]],
            ["type": "contact", "people": [person, ["name": "No Number", "phone": "call me", "email": "nope"]]],
            ["type": "status", "live": "order", "status": status],
            ["type": "status", "live": "order", "status": ["state": "Twice in one set"]],
        ]
        let cards = RichCard.cards(raw: raw)
        XCTAssertEqual(cards.map(\.kind), [.media, .contact, .status, .status])
        XCTAssertEqual(cards[0].media.map(\.kind), [.image, .audio])
        XCTAssertEqual(cards[0].media[1].duration, 185)
        XCTAssertEqual(cards[1].people[0].dialable, "+442079460958")
        XCTAssertNil(cards[1].people[1].phone, "a phone that isn't one is left out")
        XCTAssertNil(cards[1].people[1].email)
        XCTAssertEqual(cards[2].status?.progress, 0.6)
        XCTAssertEqual(cards[2].status?.milestones.map(\.done), [true, false])
        XCTAssertEqual(cards.map(\.live), [nil, nil, "order", nil],
                       "a live name stays on the first card of a set that has it")

        let unsourced: [[String: Any]] = [["type": "media", "media": [photo]]]
        XCTAssertTrue(RichCard.cards(raw: unsourced).isEmpty, "media needs its source")

        var known = PhonePerson(id: "1", name: "Augusta Ada King", relation: "Friend")
        known.phones = [.init(number: "020 7946 0958", label: nil)]
        XCTAssertEqual(cards[1].people[0].match(in: [known])?.relation, "Friend", "the same number is the same person")
        let byName = PhonePerson(id: "2", name: "ada lovelace")
        XCTAssertEqual(cards[1].people[1].match(in: [byName]), nil)
        XCTAssertEqual(RichPerson(json: ["name": "Ada Lovelace"])?.match(in: [byName])?.id, "2")
    }

    func testAContactsTextToSendNeedsTheirPhone() throws {
        let raw: [[String: Any]] = [["type": "contact", "people": [
            ["name": "Mei", "detail": "Wife", "phone": "+86 139 6261 8677", "message": "Landed safe"],
            ["name": "Bo", "email": "bo@example.com", "message": "Running late"],
            ["name": "Cy", "phone": "+1 415 555 0100", "message": ""],
        ]]]
        let people = try XCTUnwrap(RichCard.cards(raw: raw).first).people
        XCTAssertEqual(people.map(\.message), ["Landed safe", nil, nil], "a text needs a number to go to")
        XCTAssertEqual(people[0].dialable, "+8613962618677")
        XCTAssertNil(RichPerson(json: ["name": "Di", "message": "Hi"])?.message)
    }

    func testAnEmailActionOnlyAddressesTheEmail() throws {
        XCTAssertEqual(RichPerson.mailtoURL("first.last+tag@example.co.uk")?.absoluteString,
                       "mailto:first.last+tag@example.co.uk")
        // Whatever the schema lets through, the tail of an address never becomes mailto: headers.
        let crafted = try XCTUnwrap(RichPerson.mailtoURL("bo@example.com?cc=eve%40evil.example&subject=Hi#more"))
        XCTAssertNil(crafted.query, "no cc, subject or body")
        XCTAssertNil(crafted.fragment)
        XCTAssertEqual(crafted.scheme, "mailto")
    }

    func testADoneStatusShowsAndReadsAsComplete() throws {
        // The bar and VoiceOver read the same value: a done card is full whatever progress it was last given.
        let done = try XCTUnwrap(RichStatus(json: ["state": "Delivered", "phase": "done", "progress": 0.4]))
        XCTAssertEqual(done.shownProgress, 1)
        let active = try XCTUnwrap(RichStatus(json: ["state": "On its way", "phase": "active", "progress": 0.4]))
        XCTAssertEqual(active.shownProgress, 0.4)
        XCTAssertNil(RichStatus(json: ["state": "Delivered", "phase": "done"])?.shownProgress, "no bar without a progress")
    }

    func testAChatShowsALiveCardOnlyWhereItWasLastUpdated() {
        func show(_ id: String, _ state: String) -> ChatMessage {
            let answer = #"{"ok": true, "cards": [{"type": "status", "live": "order", "status": {"state": "\#(state)"}}]}"#
            let tool = ToolActivity(id: id, name: "conduit_show", input: "{}", output: answer, status: .complete)
            return ChatMessage(id: id, role: .tool, content: "", timestamp: "", tool: tool)
        }
        let messages = [show("a", "Preparing"), ChatMessage(id: "b", role: .assistant, content: "Ok.", timestamp: ""), show("c", "On its way")]
        let latest = RichCard.latestLiveRows(messages)
        XCTAssertEqual(latest, ["order": "c"])
        let first = RichCard.cards(for: messages[0].tool!)
        XCTAssertTrue(RichCard.current(first, row: "a", latestLiveRows: latest).isEmpty, "updated below")
        XCTAssertEqual(RichCard.current(RichCard.cards(for: messages[2].tool!), row: "c", latestLiveRows: latest).count, 1)
    }

    func testRichStepsKeepTheirTicksByContent() {
        let defaults = UserDefaults(suiteName: "RichStepsMemoryTests")!
        defaults.removePersistentDomain(forName: "RichStepsMemoryTests")
        let steps: [[String: Any]] = [["text": "Boil water."], ["text": "Simmer."]]
        let raw: [[String: Any]] = [["type": "steps", "title": "Eggs", "steps": steps]]
        let card = RichCard.cards(raw: raw)[0]
        let key = RichStepsMemory.key(for: card)
        XCTAssertEqual(key, RichStepsMemory.key(for: RichCard.cards(raw: raw)[0]), "the same steps get the same key")
        let other: [[String: Any]] = [["type": "steps", "title": "Eggs", "needs": ["Eggs"], "steps": steps]]
        XCTAssertNotEqual(key, RichStepsMemory.key(for: RichCard.cards(raw: other)[0]), "different needs, different card")
        let memory = RichStepsMemory(defaults: defaults)
        memory.toggle(key, 2)
        XCTAssertTrue(memory.isDone(key, 2))
        XCTAssertTrue(RichStepsMemory(defaults: defaults).isDone(key, 2), "ticks are kept")
        memory.toggle(key, 2)
        XCTAssertFalse(memory.isDone(key, 2))
    }

    func testAStoppedStepTimerDoesNotScheduleItsNotification() async throws {
        let defaults = UserDefaults(suiteName: "RichStepsTimerTests")!
        defaults.removePersistentDomain(forName: "RichStepsTimerTests")
        // Each start waits at the settings call, and (when held) inside the add,
        // until the test lets it on. `pending` is what the notification center keeps.
        var asks: [CheckedContinuation<Bool, Never>] = []
        var adds: [CheckedContinuation<Void, Never>] = []
        var holdAdds = false
        var added: [String] = []
        var pending: [String: TimeInterval] = [:]
        let notifier = RichStepsMemory.Notifier(
            allowed: { await withCheckedContinuation { asks.append($0) } },
            add: { request in
                added.append(request.identifier)
                if holdAdds { await withCheckedContinuation { adds.append($0) } }
                pending[request.identifier] = (request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
            },
            remove: { $0.forEach { pending.removeValue(forKey: $0) } })
        let memory = RichStepsMemory(defaults: defaults, notifier: notifier)
        func id(_ number: Int) -> String { "\(RichStepsMemory.notificationPrefix)k-\(number)" }

        // Stopped while asking for permission.
        let first = memory.startTimer("k", 1, seconds: 60, text: "Simmer.", title: nil)
        try await until({ asks.count == 1 }, "asking")
        memory.stopTimer("k", 1)
        asks.removeFirst().resume(returning: true)
        await first.value
        XCTAssertEqual(added, [], "stopped before the notification was added")

        // Start, stop and start again while asking: only the timer that runs gets one.
        let stale = memory.startTimer("k", 2, seconds: 60, text: "Rest.", title: nil)
        try await until({ asks.count == 1 }, "asking")
        memory.stopTimer("k", 2)
        let running = memory.startTimer("k", 2, seconds: 60, text: "Rest.", title: nil)
        try await until({ asks.count == 2 }, "asking again")
        asks.removeFirst().resume(returning: true)
        await stale.value
        XCTAssertEqual(added, [], "the stopped start adds nothing")
        asks.removeFirst().resume(returning: true)
        await running.value
        XCTAssertEqual(added.count, 1, "the running timer is scheduled")
        XCTAssertNotNil(pending[id(2)])
        XCTAssertNotNil(memory.timerEnd("k", 2))
        memory.stopTimer("k", 2)
        XCTAssertNil(pending[id(2)])

        // Stopped while the add is in flight: the request is taken back.
        holdAdds = true
        let stopped = memory.startTimer("k", 3, seconds: 60, text: "Chill.", title: nil)
        try await until({ asks.count == 1 }, "asking")
        asks.removeFirst().resume(returning: true)
        try await until({ adds.count == 1 }, "adding")
        memory.stopTimer("k", 3)
        adds.removeFirst().resume()
        await stopped.value
        XCTAssertNil(pending[id(3)], "a stopped timer's request doesn't stay")

        // Stopped and started again while the first add is in flight: the old
        // request lands first and is taken back; the new timer's request stays.
        let old = memory.startTimer("k", 4, seconds: 60, text: "Bake.", title: nil)
        try await until({ asks.count == 1 }, "asking")
        asks.removeFirst().resume(returning: true)
        try await until({ adds.count == 1 }, "adding")
        memory.stopTimer("k", 4)
        holdAdds = false
        let restarted = memory.startTimer("k", 4, seconds: 90, text: "Bake.", title: nil)
        try await until({ asks.count == 1 }, "asking again")
        asks.removeFirst().resume(returning: true)
        adds.removeFirst().resume()
        await old.value
        await restarted.value
        XCTAssertEqual(pending[id(4)], 90, "the restarted timer's notification is the one scheduled")
        memory.stopTimer("k", 4)
    }

    func testAStoppedStepTimerWhoseAddFailsLeavesNotificationsOn() async throws {
        let defaults = UserDefaults(suiteName: "RichStepsTimerFailureTests")!
        defaults.removePersistentDomain(forName: "RichStepsTimerFailureTests")
        var adds: [CheckedContinuation<Void, Never>] = []
        struct Refused: Error {}
        let notifier = RichStepsMemory.Notifier(
            allowed: { true },
            add: { _ in
                await withCheckedContinuation { adds.append($0) }
                throw Refused()
            },
            remove: { _ in })
        let memory = RichStepsMemory(defaults: defaults, notifier: notifier)

        // Stopped while its add is in flight, then the add fails: that timer
        // isn't running, so its failure doesn't say notifications are off.
        let stopped = memory.startTimer("k", 1, seconds: 60, text: "Simmer.", title: nil)
        try await until({ adds.count == 1 }, "adding")
        memory.stopTimer("k", 1)
        adds.removeFirst().resume()
        await stopped.value
        XCTAssertFalse(memory.notificationsOff, "a stopped timer's failed add")
        XCTAssertTrue(memory.scheduling.isEmpty, "a finished scheduling task isn't kept")

        // The running timer's failed add still does.
        let running = memory.startTimer("k", 2, seconds: 60, text: "Rest.", title: nil)
        try await until({ adds.count == 1 }, "adding")
        adds.removeFirst().resume()
        await running.value
        XCTAssertTrue(memory.notificationsOff, "the running timer's failed add")
        XCTAssertTrue(memory.scheduling.isEmpty)
        memory.stopTimer("k", 2)
    }

    /// Yields until `ready`; on a timeout, fails the test and stops it, instead of
    /// letting it go on to trap on a continuation that never came.
    private func until(_ ready: () -> Bool, _ what: String,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        var turns = 0
        while !ready(), turns < 10_000 { await Task.yield(); turns += 1 }
        guard ready() else {
            XCTFail("Timed out \(what)", file: file, line: line)
            throw CancellationError()
        }
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

    /// A live card shown again later in a saved call replaces the earlier
    /// one there, as it does in a typed chat; the cards shown beside it stay.
    func testSavedChatCallShowsOnlyTheLatestOfALiveCard() throws {
        func shown(_ state: String, sibling: Bool = false) -> [String: Any] {
            var cards: [[String: Any]] = [["type": "status", "live": "order", "status": ["state": state]]]
            if sibling { cards.append(["type": "place", "places": [["name": "Tartine"]]]) }
            return ["role": "assistant", "text": "Order: \(state)", "cards": cards]
        }
        let response: [String: Any] = [
            "ok": true, "chat_id": "c",
            "calls": [["call_id": "call-1", "engine": "gpt-live", "turns": [
                ["role": "user", "text": "Where's my order?"] as [String: Any],
                shown("Packed", sibling: true), shown("Shipped"), shown("Delivered"),
            ]] as [String: Any]],
        ]
        let call = try XCTUnwrap(try VoiceHistoryClient.chatCalls(from: response).first)

        let drawn = call.turns.map { call.currentCards(for: $0) }
        XCTAssertEqual(drawn.map(\.count), [0, 1, 0, 1])
        XCTAssertEqual(drawn[1].first?.places.first?.name, "Tartine", "the sibling stays")
        XCTAssertEqual(drawn[3].first?.live, "order")
        XCTAssertEqual(call.turns.map(\.cards.count), [0, 2, 1, 1], "the saved record is unchanged")
    }
}
