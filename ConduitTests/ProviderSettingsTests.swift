import XCTest
@testable import Conduit

@MainActor
final class ProviderSettingsTests: XCTestCase {
    // MARK: Reading Hermes' answers

    private let env: [String: Any] = [
        "OPENROUTER_API_KEY": [
            "category": "provider", "is_password": true, "is_set": true, "advanced": false,
            "redacted_value": "sk-or-…1234",
            "provider_profiles": [["provider": "openrouter", "provider_label": "OpenRouter", "primary": true,
                                   "url": "https://openrouter.ai/keys"]],
        ],
        "OPENROUTER_BASE_URL": [
            "category": "provider", "is_password": false, "is_set": false, "advanced": true,
            "provider": "openrouter", "provider_label": "OpenRouter",
        ],
        "OPENAI_API_KEY": [
            "category": "provider", "is_password": true, "is_set": false, "advanced": false,
            "provider_profiles": [
                ["provider": "openai", "provider_label": "OpenAI", "primary": true],
                ["provider": "openrouter", "provider_label": "OpenRouter", "primary": false],
            ],
        ],
        "TELEGRAM_BOT_TOKEN": ["category": "messaging", "is_password": true, "is_set": true],
    ]

    private func pool(_ provider: String, _ rows: [(id: String, label: String, source: String)]) -> [String: Any] {
        ["providers": [[
            "provider": provider,
            "entries": rows.enumerated().map { index, row in
                ["id": row.id, "index": index + 1, "label": row.label, "source": row.source, "auth_type": "api_key"] as [String: Any]
            },
        ]]]
    }

    func testEnvRowsBecomeProvidersWithTheirOwnVariableFirst() {
        let entries = ProviderCatalog.entries(env: env, accounts: nil, endpoints: nil)
        XCTAssertEqual(entries.map(\.id), ["openai", "openrouter"])
        let openrouter = entries[1]
        XCTAssertEqual(openrouter.name, "OpenRouter")
        XCTAssertEqual(openrouter.key?.vars, ["OPENROUTER_API_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(openrouter.key?.writeVar, "OPENROUTER_API_KEY")
        XCTAssertEqual(openrouter.key?.savedVars, ["OPENROUTER_API_KEY"])
        XCTAssertEqual(openrouter.key?.baseURLVar, "OPENROUTER_BASE_URL")
        XCTAssertEqual(openrouter.key?.signupURL, "https://openrouter.ai/keys")
        XCTAssertEqual(entries[0].status, .notConnected)
    }

    func testMainProfileKeyStates() {
        let shared = pool("openrouter", [("r1", ProviderEntry.PoolRow.sharedLabel, "manual")])
        var entries = ProviderCatalog.entries(env: env, accounts: nil, endpoints: nil, sharedPool: shared)
        XCTAssertEqual(entries.first { $0.id == "openrouter" }?.status, .sharedKey)

        // A row the pool read from the main profile's own .env reaches no
        // other profile, so the key is the main profile's only.
        let fromEnv = pool("openrouter", [("r1", "", "env:OPENROUTER_API_KEY")])
        entries = ProviderCatalog.entries(env: env, accounts: nil, endpoints: nil, sharedPool: fromEnv)
        XCTAssertEqual(entries.first { $0.id == "openrouter" }?.status, .mainProfileOnly)
        XCTAssertEqual(entries.first { $0.id == "openrouter" }?.key?.sharedRows, [])
    }

    func testOtherProfileKeyStatesFollowItsFirstPoolRow() {
        let shared = pool("openrouter", [("r2", ProviderEntry.PoolRow.sharedLabel, "manual")])
        func state(_ rows: [(id: String, label: String, source: String)]) -> ProviderEntry.Status? {
            ProviderCatalog.entries(env: env, accounts: nil, endpoints: nil, sharedPool: shared,
                                    profilePool: pool("openrouter", rows), onMainProfile: false)
                .first { $0.id == "openrouter" }?.status
        }
        XCTAssertEqual(state([("r2", ProviderEntry.PoolRow.sharedLabel, "manual")]), .sharedKey)
        XCTAssertEqual(state([("r1", ProviderEntry.PoolRow.sharedLabel, "manual")]), .oldCopy)
        XCTAssertEqual(state([("o1", ProviderEntry.PoolRow.profileLabel, "manual"), ("r2", ProviderEntry.PoolRow.sharedLabel, "manual")]), .ownKey)
        XCTAssertEqual(state([("e1", "", "env:OPENROUTER_API_KEY")]), .ownKey)
        // No rows of its own: Hermes falls back to the main pool.
        let noRows = ProviderCatalog.entries(env: env, accounts: nil, endpoints: nil, sharedPool: shared,
                                             profilePool: ["providers": []], onMainProfile: false)
        XCTAssertEqual(noRows.first { $0.id == "openrouter" }?.status, .sharedKey,
                       "with no rows of its own the profile falls back to the shared key, ahead of its .env one")
        let noRowsNoShared = ProviderCatalog.entries(env: env, accounts: nil, endpoints: nil,
                                                     profilePool: ["providers": []], onMainProfile: false)
        XCTAssertEqual(noRowsNoShared.first { $0.id == "openrouter" }?.status, .ownKey)
    }

    func testAccountsAndEndpointsJoinTheList() {
        let accounts: [String: Any] = ["providers": [
            ["id": "nous", "name": "Nous Portal", "flow": "device_code", "status": ["logged_in": true], "disconnectable": true],
            ["id": "claude-code", "name": "Claude Code", "flow": "external", "cli_command": "claude login", "status": ["logged_in": false]],
        ]]
        let endpoints: [String: Any] = ["endpoints": [
            ["id": "lab", "name": "Lab vLLM", "base_url": "http://10.0.0.5:8000/v1", "model": "qwen", "models": ["qwen", "llama"],
             "has_api_key": true, "is_current": true],
        ]]
        let entries = ProviderCatalog.entries(env: [:], accounts: accounts, endpoints: endpoints)
        XCTAssertEqual(entries.first { $0.id == "nous" }?.status, .signedIn)
        XCTAssertEqual(entries.first { $0.id == "claude-code" }?.account?.command, "claude login")
        let lab = entries.first { $0.id == ProviderEntry.endpointEntryID("lab") }
        XCTAssertEqual(lab?.status, .customEndpoint)
        XCTAssertEqual(lab?.endpoint?.models, ["qwen", "llama"])
        XCTAssertEqual(lab?.catalogNames, ["lab", "custom:lab", "Lab vLLM"])
    }

    func testKeptSummaryRoundTripsWithoutAnyKeyOrPreview() throws {
        let shared = pool("openrouter", [("r2", ProviderEntry.PoolRow.sharedLabel, "manual")])
        let entries = ProviderCatalog.entries(env: env, accounts: nil, endpoints: nil, sharedPool: shared,
                                              profilePool: shared, onMainProfile: false)
        let summary = ProviderCatalog.summary(entries)
        XCTAssertEqual(ProviderCatalog.entries(summary: summary), entries)
        let text = String(data: try JSONSerialization.data(withJSONObject: summary), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("sk-or"), "Hermes' masked preview is never kept")
        XCTAssertFalse(text.contains("redacted"))
    }

    // MARK: Writes

    func testSharingAKeyReplacesTheOldSharedRowAndClearsItsCopies() async throws {
        let requester = FakeProviderRequester()
        requester.pools["default"] = pool("openrouter", [("old", ProviderEntry.PoolRow.sharedLabel, "manual"),
                                                         ("new", ProviderEntry.PoolRow.sharedLabel, "manual")])
        requester.pools["bot"] = pool("openrouter", [("old", ProviderEntry.PoolRow.sharedLabel, "manual")])
        let service = ProviderSettingsService(requester: requester, profile: "default", profiles: { ["default", "bot"] })
        var entry = ProviderEntry(id: "openrouter", name: "OpenRouter")
        entry.key = ProviderEntry.KeyAccess(vars: ["OPENROUTER_API_KEY"], savedVars: [],
                                            sharedRows: [.init(id: "old", index: 1, label: ProviderEntry.PoolRow.sharedLabel)])

        try await service.share(key: " sk-new ", for: entry)

        let post = try XCTUnwrap(requester.calls.first { $0.method == "POST" })
        XCTAssertEqual(post.path, "/api/credentials/pool?profile=default")
        XCTAssertEqual(post.body?["api_key"] as? String, "sk-new")
        XCTAssertEqual(post.body?["label"] as? String, ProviderEntry.PoolRow.sharedLabel)
        let deletes = requester.calls.filter { $0.method == "DELETE" }.map(\.path)
        XCTAssertEqual(deletes, [
            "/api/credentials/pool/openrouter/1?profile=default",
            "/api/credentials/pool/openrouter/1?profile=bot",
        ])
        XCTAssertEqual(service.changes, 1)
    }

    func testAnOverrideRemovesTheSharedCopiesFromThatProfile() async throws {
        let requester = FakeProviderRequester()
        requester.pools["bot"] = pool("openrouter", [("shared", ProviderEntry.PoolRow.sharedLabel, "manual"),
                                                     ("mine", ProviderEntry.PoolRow.profileLabel, "manual")])
        let service = ProviderSettingsService(requester: requester, profile: "bot")
        var entry = ProviderEntry(id: "openrouter", name: "OpenRouter")
        entry.onMainProfile = false
        entry.key = ProviderEntry.KeyAccess(vars: ["OPENROUTER_API_KEY"], savedVars: [],
                                            sharedRows: [.init(id: "shared", index: 1)])

        try await service.override(key: "sk-bot", for: entry)

        let post = try XCTUnwrap(requester.calls.first { $0.method == "POST" })
        XCTAssertEqual(post.path, "/api/credentials/pool?profile=bot")
        XCTAssertEqual(post.body?["label"] as? String, ProviderEntry.PoolRow.profileLabel)
        XCTAssertEqual(requester.calls.filter { $0.method == "DELETE" }.map(\.path),
                       ["/api/credentials/pool/openrouter/1?profile=bot"])
    }

    func testUsingTheSharedKeyAgainRemovesTheProfilesOwnRowsAndVariables() async throws {
        let requester = FakeProviderRequester()
        requester.pools["bot"] = pool("openrouter", [("mine", ProviderEntry.PoolRow.profileLabel, "manual"),
                                                     ("env", "", "env:OPENROUTER_API_KEY")])
        let service = ProviderSettingsService(requester: requester, profile: "bot")
        var entry = ProviderEntry(id: "openrouter", name: "OpenRouter")
        entry.onMainProfile = false
        entry.key = ProviderEntry.KeyAccess(vars: ["OPENROUTER_API_KEY"], savedVars: ["OPENROUTER_API_KEY"],
                                            profileRows: [.init(id: "mine", index: 1), .init(id: "env", index: 2)])

        try await service.useShared(entry)

        XCTAssertEqual(requester.calls.filter { $0.method == "DELETE" }.map(\.path), [
            "/api/credentials/pool/openrouter/2?profile=bot",
            "/api/credentials/pool/openrouter/1?profile=bot",
            "/api/env?profile=bot",
        ])
    }

    func testAnOverrideAlsoRemovesAnOldCopyAheadOfIt() async throws {
        let requester = FakeProviderRequester()
        requester.pools["bot"] = pool("openrouter", [("gone", ProviderEntry.PoolRow.sharedLabel, "manual"),
                                                     ("new", ProviderEntry.PoolRow.profileLabel, "manual")])
        let service = ProviderSettingsService(requester: requester, profile: "bot")
        var entry = ProviderEntry(id: "openrouter", name: "OpenRouter")
        entry.onMainProfile = false
        entry.key = ProviderEntry.KeyAccess(vars: ["OPENROUTER_API_KEY"], savedVars: [],
                                            sharedRows: [.init(id: "current", index: 1)],
                                            profileRows: [.init(id: "gone", index: 1, label: ProviderEntry.PoolRow.sharedLabel)])
        XCTAssertEqual(entry.status, .oldCopy)

        try await service.override(key: "sk-bot", for: entry)

        XCTAssertEqual(requester.calls.filter { $0.method == "DELETE" }.map(\.path),
                       ["/api/credentials/pool/openrouter/1?profile=bot"])
    }

    func testAFailedPoolReadFailsTheReloadAndKeepsWhatWasShown() async {
        let requester = FakeProviderRequester()
        requester.envAnswer = env
        requester.pools["default"] = pool("openrouter", [("r1", ProviderEntry.PoolRow.sharedLabel, "manual")])
        let service = ProviderSettingsService(requester: requester, profile: "default")
        await service.reload()
        XCTAssertEqual(service.entry("openrouter")?.status, .sharedKey)

        requester.failures["/api/credentials/pool"] = DashboardTicketBridgeError.http(status: 500, detail: "")
        await service.reload()
        XCTAssertTrue(service.loadFailed)
        XCTAssertEqual(service.entry("openrouter")?.status, .sharedKey, "a dropped pool read doesn't show the shared key as gone")

        // A route an older Hermes doesn't have adds nothing instead.
        requester.failures = ["/api/providers/oauth": DashboardTicketBridgeError.http(status: 404, detail: "")]
        await service.reload()
        XCTAssertFalse(service.loadFailed)
        XCTAssertEqual(service.entry("openrouter")?.status, .sharedKey)
    }

    func testANewEndpointGetsAnIDFromItsName() {
        XCTAssertEqual(CustomEndpointDraft.endpointID(forName: "Lab vLLM", taken: []), "lab-vllm")
        XCTAssertEqual(CustomEndpointDraft.endpointID(forName: "Lab vLLM", taken: ["lab-vllm", "lab-vllm-2"]), "lab-vllm-3")
        XCTAssertEqual(CustomEndpointDraft.endpointID(forName: "  ", taken: []), "endpoint")
    }

    func testAKeptEndpointAddressLeavesOutItsPath() {
        XCTAssertEqual(ProviderCatalog.keptAddress("https://user:pw@host.example:8443/v1/tok123?key=x"), "https://host.example:8443")
        XCTAssertEqual(ProviderCatalog.keptAddress("not a url"), "")
    }

    // MARK: Endpoints and sign-ins

    func testAnEndpointSaveWithNoTypedKeyKeepsTheSavedOne() {
        var draft = CustomEndpointDraft(endpointID: "lab", name: "Lab", baseURL: "http://lab/v1", key: "  ", model: "qwen")
        XCTAssertNil(draft.body(forCheck: false)["api_key"], "an empty api_key would clear the saved key")
        draft.key = "sk-lab"
        XCTAssertEqual(draft.body(forCheck: false)["api_key"] as? String, "sk-lab")
        XCTAssertNil(draft.body(forCheck: true)["make_default"])
    }

    func testSignInAnswers() {
        let signIn = ProviderSignIn(answer: ["session_id": "s1", "user_code": "ABCD-1234",
                                             "verification_url": "https://example.com/device", "poll_interval": 0])
        XCTAssertEqual(signIn?.userCode, "ABCD-1234")
        XCTAssertEqual(signIn?.pollInterval, 1)
        XCTAssertNil(ProviderSignIn(answer: ["user_code": "X"]))
        XCTAssertEqual(ProviderSignIn.Outcome(answer: ["status": "approved"]), .approved)
        XCTAssertEqual(ProviderSignIn.Outcome(answer: ["status": "error", "error_message": "Nope"]), .failed("Nope"))
        XCTAssertTrue(ProviderCheck(answer: ["ok": false, "reachable": true]).blocksSave)
        XCTAssertFalse(ProviderCheck(answer: ["ok": false, "reachable": false]).blocksSave)
    }

    func testRemoveNamesTheOtherModelPicksOnTheProvider() {
        var entry = ProviderEntry(id: "openrouter", name: "OpenRouter")
        entry.key = ProviderEntry.KeyAccess(vars: ["OPENROUTER_API_KEY"], savedVars: [])
        let uses = ModelPageProviders.usage(
            of: entry,
            settings: ["delegation.provider": .text("OpenRouter")],
            fallbacks: [ProfileFallbackModel(provider: "openrouter", model: "gpt-x"),
                        ProfileFallbackModel(provider: "nous", model: "hermes")]
        )
        XCTAssertEqual(uses.count, 2)
    }
}

@MainActor
private final class FakeProviderRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    var calls: [Call] = []
    /// Each profile's credential pool answer.
    var pools: [String: [String: Any]] = [:]
    var envAnswer: [String: Any] = [:]
    /// Errors for GETs, by the path before its query.
    var failures: [String: Error] = [:]

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        calls.append(Call(path: path, method: method, body: body))
        let route = path.components(separatedBy: "?").first ?? path
        if method == "GET", let failure = failures[route] { throw failure }
        if method == "GET", route == "/api/env" { return envAnswer }
        if method == "GET", path.hasPrefix("/api/credentials/pool?") {
            let profile = path.components(separatedBy: "profile=").last ?? ""
            return pools[profile] ?? ["providers": []]
        }
        return ["ok": true]
    }
}
