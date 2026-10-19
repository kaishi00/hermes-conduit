//
//  HermesVoiceConfigurationServiceTests+AgentSettings.swift
//  Conduit
//
//  Hermes changes Conduit settings (AgentSettings.swift): what Conduit
//  shares with the plugin, how it decides each request on its own list,
//  tier and mode, and what it answers. An extension of the voice
//  configuration tests: the hosted CI plan is at its class budget.
//

import XCTest
@testable import Conduit

@MainActor
private final class FakeAgentSettings {
    var values: [String: AgentSettingValue] = [
        "voice.live.tone": .string("default"),
        "voice.gemini.memory": .bool(false),
    ]
    var writes: [(String, AgentSettingValue)] = []
    var responses: [[String: Any]] = []
    private(set) var bodies: [[String: Any]] = []
    private(set) var paths: [String] = []

    var catalog: [AgentSettingDescriptor] {
        [
            AgentSettingDescriptor(
                key: "voice.live.tone", section: "Live voice", title: "Tone", description: "How calls sound.",
                kind: .choice([(value: "default", title: "Model's own"), (value: "relaxed", title: "Relaxed")]),
                tier: .small, displayTitle: { "Tone" }, displayValue: { value in
                    if case .string(let text) = value { return text } else { return "" }
                },
                read: { [unowned self] in self.values["voice.live.tone"]! },
                write: { [unowned self] in self.values["voice.live.tone"] = $0; self.writes.append(("voice.live.tone", $0)) }
            ),
            AgentSettingDescriptor(
                key: "voice.gemini.memory", section: "Gemini Live", title: "Gemini Live memory", description: "Sends memory to Google.",
                kind: .bool, tier: .ask, displayTitle: { "Gemini Live memory" }, displayValue: AgentSettingDescriptor.onOff,
                read: { [unowned self] in self.values["voice.gemini.memory"]! },
                write: { [unowned self] in self.values["voice.gemini.memory"] = $0; self.writes.append(("voice.gemini.memory", $0)) }
            ),
        ]
    }

    var request: AgentSettingsSync.Request {
        { [unowned self] path, body in
            self.paths.append(path)
            self.bodies.append(body)
            return self.responses.isEmpty ? ["ok": true, "pending": []] : self.responses.removeFirst()
        }
    }
}

extension HermesVoiceConfigurationServiceTests {
    private func agentDefaults(mode: AgentSettingsMode? = nil) -> UserDefaults {
        let name = "AgentSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        if let mode { defaults.set(mode.rawValue, forKey: AgentSettingsMode.storageKey) }
        return defaults
    }

    private func pending(_ id: String, _ key: String, _ value: Any, from: Any) -> [String: Any] {
        ["id": id, "key": key, "value": value, "from": from, "reason": "You asked for it.", "tier": "small"]
    }

    func testAgentSettingsModeDefaultsToAskEveryTime() {
        XCTAssertEqual(AgentSettingsMode.stored(in: agentDefaults()), .ask)
    }

    func testAgentSettingsSyncSharesTheCatalogAndMode() async throws {
        let fake = FakeAgentSettings()
        let sync = AgentSettingsSync(defaults: agentDefaults(mode: .small))

        await sync.sync(scope: "h|work", profile: "work", catalog: fake.catalog, request: fake.request)

        XCTAssertEqual(fake.paths, ["/api/plugins/conduit_push/conduit-settings?profile=work"])
        let body = try XCTUnwrap(fake.bodies.first)
        XCTAssertEqual(body["mode"] as? String, "small")
        XCTAssertEqual(body["installation_id"] as? String, sync.installationID)
        let settings = try XCTUnwrap(body["settings"] as? [[String: Any]])
        XCTAssertEqual(settings.map { $0["key"] as? String }, ["voice.live.tone", "voice.gemini.memory"])
        XCTAssertEqual(settings[0]["kind"] as? String, "choice")
        XCTAssertEqual(settings[0]["tier"] as? String, "small")
        XCTAssertEqual(settings[1]["value"] as? Bool, false)
    }

    func testEveryChangeWaitsForTheUserWhenAskingEveryTime() async {
        let fake = FakeAgentSettings()
        fake.responses = [["ok": true, "pending": [pending("req-tone-1", "voice.live.tone", "relaxed", from: "default")]]]
        let sync = AgentSettingsSync(defaults: agentDefaults())

        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)

        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(sync.reviewItems(for: "h|default").map(\.id), ["req-tone-1"])
        XCTAssertEqual(sync.reviewItems(for: "h|default").first?.newValue, "relaxed")
        XCTAssertTrue(sync.reviewItems(for: "other|default").isEmpty)

        sync.resolve(sync.review, apply: true, scope: "h|default", catalog: fake.catalog)

        XCTAssertEqual(fake.values["voice.live.tone"], .string("relaxed"))
        XCTAssertTrue(sync.review.isEmpty)
        XCTAssertEqual(sync.revision, 1)
        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)
        let results = fake.bodies.last?["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["id"] as? String, "req-tone-1")
        XCTAssertEqual(results?.first?["status"] as? String, "applied")
    }

    func testSmallChangesApplyWithAnUndoAndTheRestStillAsk() async throws {
        let fake = FakeAgentSettings()
        let memory = pending("req-memory-1", "voice.gemini.memory", true, from: false)
        fake.responses = [
            ["ok": true, "pending": [pending("req-tone-1", "voice.live.tone", "relaxed", from: "default"), memory]],
            // The host took the answer; the change for the user still waits.
            ["ok": true, "pending": [memory]],
        ]
        let sync = AgentSettingsSync(defaults: agentDefaults(mode: .small))

        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)

        XCTAssertEqual(fake.values["voice.live.tone"], .string("relaxed"))
        // The phone's own tier decides, not the "small" the request claims.
        XCTAssertEqual(fake.values["voice.gemini.memory"], .bool(false))
        XCTAssertEqual(sync.review.map(\.id), ["req-memory-1"])
        let notice = try XCTUnwrap(sync.applied)
        XCTAssertEqual(notice.changes.map(\.request.id), ["req-tone-1"])
        // The applied answer went out straight away, in a second round.
        XCTAssertEqual(fake.bodies.count, 2)
        XCTAssertEqual((fake.bodies[1]["results"] as? [[String: Any]])?.first?["status"] as? String, "applied")

        sync.undo(notice, scope: "h|default", catalog: fake.catalog)

        XCTAssertEqual(fake.values["voice.live.tone"], .string("default"))
        XCTAssertNil(sync.applied)
        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)
        XCTAssertEqual((fake.bodies.last?["results"] as? [[String: Any]])?.last?["status"] as? String, "undone")
    }

    func testUndoKeepsAValueTheUserChangedAfterHermes() async throws {
        let fake = FakeAgentSettings()
        fake.responses = [["ok": true, "pending": [pending("req-tone-1", "voice.live.tone", "relaxed", from: "default")]]]
        let sync = AgentSettingsSync(defaults: agentDefaults(mode: .small))
        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)
        let notice = try XCTUnwrap(sync.applied)

        fake.values["voice.live.tone"] = .string("professional")
        sync.undo(notice, scope: "h|default", catalog: fake.catalog)

        XCTAssertEqual(fake.values["voice.live.tone"], .string("professional"))
        XCTAssertNil(sync.applied)
    }

    func testApplyKeepsAValueTheUserChangedWhileTheRequestWaited() async {
        let fake = FakeAgentSettings()
        fake.responses = [["ok": true, "pending": [pending("req-tone-1", "voice.live.tone", "relaxed", from: "default")]]]
        let sync = AgentSettingsSync(defaults: agentDefaults())
        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)

        fake.values["voice.live.tone"] = .string("professional")
        sync.resolve(sync.review, apply: true, scope: "h|default", catalog: fake.catalog)

        XCTAssertEqual(fake.values["voice.live.tone"], .string("professional"))
        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)
        XCTAssertEqual((fake.bodies.last?["results"] as? [[String: Any]])?.first?["status"] as? String, "conflict")
    }

    func testAValueTheUserChangedSinceHermesReadItIsKept() async {
        let fake = FakeAgentSettings()
        fake.values["voice.live.tone"] = .string("relaxed")
        let request = AgentSettingRequest(id: "req-tone-1", key: "voice.live.tone", value: .string("default"),
                                          from: .string("professional"), reason: "")
        let decision = AgentSettingDecision.decide(request, descriptor: fake.catalog[0], mode: .small)
        guard case .answer(let status, _) = decision else { return XCTFail("expected an answer, got \(decision)") }
        XCTAssertEqual(status, "conflict")
    }

    func testRequestsOutsideTheListOrWithBadValuesAreRefused() {
        let fake = FakeAgentSettings()
        let unknown = AgentSettingRequest(id: "req-1", key: "calls.enabled", value: .bool(true), from: .bool(false), reason: "")
        let badValue = AgentSettingRequest(id: "req-2", key: "voice.live.tone", value: .string("shouty"), from: .string("default"), reason: "")
        let wrongKind = AgentSettingRequest(id: "req-3", key: "voice.gemini.memory", value: .string("yes"), from: .bool(false), reason: "")
        let catalog = Dictionary(fake.catalog.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for request in [unknown, badValue, wrongKind] {
            XCTAssertEqual(AgentSettingDecision.decide(request, descriptor: catalog[request.key], mode: .small),
                           .answer(status: "refused", note: "Conduit doesn't let Hermes change this setting to that value."))
        }
    }

    func testOffRefusesEveryRequest() {
        let fake = FakeAgentSettings()
        let request = AgentSettingRequest(id: "req-1", key: "voice.live.tone", value: .string("relaxed"), from: .string("default"), reason: "")
        guard case .answer(let status, _) = AgentSettingDecision.decide(request, descriptor: fake.catalog[0], mode: .off) else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(status, "refused")
    }

    func testASyncForAnotherProfileDuringASyncStillRuns() async {
        let fake = FakeAgentSettings()
        let sync = AgentSettingsSync(defaults: agentDefaults())
        var activeProfile = "a"
        var held: CheckedContinuation<Void, Never>?
        let request: AgentSettingsSync.Request = { path, body in
            let answer = try await fake.request(path, body)
            if fake.paths.count == 1 { await withCheckedContinuation { held = $0 } }
            return answer
        }

        let first = Task {
            await sync.sync(scope: "h|a", profile: "a", catalog: fake.catalog,
                            isCurrent: { activeProfile == "a" }, request: request)
        }
        while held == nil { await Task.yield() }
        // The user switches profile while profile a's sync is on its way.
        activeProfile = "b"
        await sync.sync(scope: "h|b", profile: "b", catalog: fake.catalog,
                        isCurrent: { activeProfile == "b" }, request: request)
        held?.resume()
        await first.value

        XCTAssertEqual(fake.paths, [
            "/api/plugins/conduit_push/conduit-settings?profile=a",
            "/api/plugins/conduit_push/conduit-settings?profile=b",
        ], "the coalesced round syncs the profile now in use")
    }

    func testAnAnswerSyncedDuringABusySyncStillReachesHermes() async {
        let fake = FakeAgentSettings()
        let sync = AgentSettingsSync(defaults: agentDefaults())
        // Hermes lists the request until it hears the answer; the first
        // three syncs wait until the test lets them answer.
        var held: [CheckedContinuation<Void, Never>] = []
        let request: AgentSettingsSync.Request = { [self] path, body in
            fake.responses = [["ok": true, "pending": [pending("req-memory-1", "voice.gemini.memory", true, from: false)]]]
            let answer = try await fake.request(path, body)
            if fake.bodies.count <= 3 { await withCheckedContinuation { held.append($0) } }
            return answer
        }
        func waitForSync(_ count: Int) async {
            while fake.bodies.count < count || held.isEmpty { await Task.yield() }
        }
        func syncAgain() async {
            await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: request)
        }

        let first = Task { await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: request) }
        await waitForSync(1)
        await syncAgain()
        held.removeFirst().resume()
        await waitForSync(2)
        await syncAgain()
        held.removeFirst().resume()
        await waitForSync(3)
        // The user dismisses the change while the third sync is on its way.
        sync.resolve(sync.review, apply: false, scope: "h|default", catalog: fake.catalog)
        await syncAgain()
        held.removeFirst().resume()
        await first.value

        XCTAssertEqual(fake.bodies.count, 4, "the sync asked for after the answer runs")
        let results = fake.bodies.last?["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["id"] as? String, "req-memory-1")
        XCTAssertEqual(results?.first?["status"] as? String, "dismissed")
    }

    func testDismissingAChangeLeavesTheSettingAndTellsHermes() async {
        let fake = FakeAgentSettings()
        fake.responses = [["ok": true, "pending": [pending("req-memory-1", "voice.gemini.memory", true, from: false)]]]
        let sync = AgentSettingsSync(defaults: agentDefaults())
        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)

        sync.resolve(sync.review, apply: false, scope: "h|default", catalog: fake.catalog)
        await sync.sync(scope: "h|default", profile: "default", catalog: fake.catalog, request: fake.request)

        XCTAssertEqual(fake.values["voice.gemini.memory"], .bool(false))
        XCTAssertTrue(sync.review.isEmpty)
        let results = fake.bodies[1]["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["status"] as? String, "dismissed")
    }

    func testRequestsParseOnlyWhenWellFormed() {
        XCTAssertNotNil(AgentSettingRequest(json: ["id": "req-1", "key": "voice.live.tone", "value": "relaxed"]))
        XCTAssertEqual(AgentSettingRequest(json: ["id": "req-1", "key": "voice.gemini.memory", "value": true])?.value, .bool(true))
        XCTAssertNil(AgentSettingRequest(json: ["id": "req-1", "key": "voice.live.tone"]))
        XCTAssertNil(AgentSettingRequest(json: ["key": "voice.live.tone", "value": "relaxed"]))
        XCTAssertNil(AgentSettingRequest(json: ["id": "req-1", "key": "voice.live.tone", "value": 3]))
    }

    func testVoiceSettingsLinkOpensVoice() throws {
        let url = try XCTUnwrap(URL(string: "conduit://settings/voice"))
        XCTAssertEqual(ConduitAppLink(url: url), .settings(.voice))
    }
}
