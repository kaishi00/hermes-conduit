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

    /// One variable two providers read as their own key, and one a third
    /// provider only borrows.
    private let heldEnv: [String: Any] = [
        "SHARED_API_KEY": [
            "category": "provider", "is_password": true, "is_set": true,
            "provider_profiles": [["provider": "alpha", "provider_label": "Alpha", "primary": true],
                                  ["provider": "beta", "provider_label": "Beta", "primary": true],
                                  ["provider": "gamma", "provider_label": "Gamma", "primary": false]],
        ],
        "ALPHA_API_KEY": [
            "category": "provider", "is_password": true, "is_set": true,
            "provider_profiles": [["provider": "alpha", "provider_label": "Alpha", "primary": true]],
        ],
    ]

    func testAVariableAnotherProviderAlsoOwnsIsNeverRemovedForOne() async throws {
        let entries = ProviderCatalog.entries(env: heldEnv, accounts: nil, endpoints: nil)
        let alpha = try XCTUnwrap(entries.first { $0.id == "alpha" })
        XCTAssertEqual(alpha.key?.heldVars, ["SHARED_API_KEY"])
        XCTAssertEqual(alpha.key?.removableVars, ["ALPHA_API_KEY"])
        XCTAssertEqual(entries.first { $0.id == "beta" }?.key?.removableVars, [])
        XCTAssertEqual(entries.first { $0.id == "gamma" }?.key?.borrowedOnly, true)

        // Sharing on the main profile replaces only alpha's own variable.
        let requester = FakeProviderRequester()
        let service = ProviderSettingsService(requester: requester, profile: "default", profiles: { ["default"] })
        try await service.share(key: "sk-alpha", for: alpha)
        var removed = requester.calls.filter { $0.method == "DELETE" }.compactMap { $0.body?["key"] as? String }
        XCTAssertEqual(removed, ["ALPHA_API_KEY"])

        // Going back to the shared key on another profile keeps it too,
        // and the pool row read from it.
        var onBot = alpha
        onBot.key?.profileRows = [.init(id: "e1", index: 1, label: "", source: "env:SHARED_API_KEY"),
                                  .init(id: "e2", index: 2, label: "", source: "env:ALPHA_API_KEY")]
        let botRequester = FakeProviderRequester()
        botRequester.pools["bot"] = pool("alpha", [("e1", "", "env:SHARED_API_KEY"), ("e2", "", "env:ALPHA_API_KEY")])
        let bot = ProviderSettingsService(requester: botRequester, profile: "bot")
        try await bot.useShared(onBot)
        let deletes = botRequester.calls.filter { $0.method == "DELETE" }
        XCTAssertEqual(deletes.map(\.path).filter { $0.hasPrefix("/api/credentials") }, ["/api/credentials/pool/alpha/2?profile=bot"])
        removed = deletes.compactMap { $0.body?["key"] as? String }
        XCTAssertEqual(removed, ["ALPHA_API_KEY"])

        // A key of its own, or one shared from there, leaves that row too.
        for write in ["override", "share"] {
            let requester = FakeProviderRequester()
            requester.pools["bot"] = pool("alpha", [("e1", "", "env:SHARED_API_KEY"), ("e2", "", "env:ALPHA_API_KEY")])
            let service = ProviderSettingsService(requester: requester, profile: "bot", profiles: { ["default", "bot"] })
            if write == "override" { try await service.override(key: "sk-bot", for: onBot) }
            else { try await service.share(key: "sk-all", for: onBot) }
            let rows = requester.calls.filter { $0.method == "DELETE" && $0.path.hasPrefix("/api/credentials") }.map(\.path)
            XCTAssertEqual(rows, ["/api/credentials/pool/alpha/2?profile=bot"], write)
        }
    }

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
        XCTAssertEqual(openrouter.key?.vars, ["OPENROUTER_API_KEY"], "another provider's variable it can read isn't its key")
        XCTAssertEqual(openrouter.key?.writeVar, "OPENROUTER_API_KEY")
        XCTAssertEqual(openrouter.key?.savedVars, ["OPENROUTER_API_KEY"])
        XCTAssertEqual(openrouter.key?.baseURLVar, "OPENROUTER_BASE_URL")
        XCTAssertEqual(openrouter.key?.signupURL, "https://openrouter.ai/keys")
        XCTAssertEqual(entries[0].status, .notConnected)
    }

    func testAnotherProvidersKeyIsNeverCountedOrRemovedForThisOne() {
        var withOpenAI = env
        var openAI = env["OPENAI_API_KEY"] as! [String: Any]
        openAI["is_set"] = true
        withOpenAI["OPENAI_API_KEY"] = openAI
        var openrouterUnset = env["OPENROUTER_API_KEY"] as! [String: Any]
        openrouterUnset["is_set"] = false
        withOpenAI["OPENROUTER_API_KEY"] = openrouterUnset
        let entries = ProviderCatalog.entries(env: withOpenAI, accounts: nil, endpoints: nil)
        let openrouter = entries.first { $0.id == "openrouter" }
        XCTAssertEqual(openrouter?.status, .notConnected)
        XCTAssertEqual(openrouter?.key?.savedVars, [])
        XCTAssertEqual(entries.first { $0.id == "openai" }?.status, .mainProfileOnly)

        // A provider that only borrows a variable still takes a key, but
        // isn't checked under it (Hermes would try it on the other provider).
        let borrowedOnly: [String: Any] = ["SHARED_API_KEY": [
            "category": "provider", "is_password": true, "is_set": true,
            "provider_profiles": [["provider": "lab", "provider_label": "Lab", "primary": false]],
        ]]
        let lab = ProviderCatalog.entries(env: borrowedOnly, accounts: nil, endpoints: nil).first
        XCTAssertEqual(lab?.key?.vars, ["SHARED_API_KEY"])
        XCTAssertEqual(lab?.key?.savedVars, [])
        XCTAssertEqual(lab?.key?.borrowedOnly, true)
        XCTAssertEqual(entries.first { $0.id == "openrouter" }?.key?.borrowedOnly, false)
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
        XCTAssertEqual(lab?.catalogNames, ["lab", "custom:lab"], "never its display name, which a built-in can share")
    }

    func testKeptSummaryRoundTripsWithoutAnyKeyOrPreview() throws {
        let shared = pool("openrouter", [("r2", ProviderEntry.PoolRow.sharedLabel, "manual")])
        let entries = ProviderCatalog.entries(env: env, accounts: nil, endpoints: nil, sharedPool: shared,
                                              profilePool: shared, onMainProfile: false)
        let summary = ProviderCatalog.summary(entries)
        XCTAssertEqual(ProviderCatalog.entries(summary: summary), entries)
        let held = ProviderCatalog.entries(env: heldEnv, accounts: nil, endpoints: nil)
        XCTAssertEqual(ProviderCatalog.entries(summary: ProviderCatalog.summary(held)), held,
                       "borrowed-only and held variables survive the kept summary")
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

    func testSharingSaysSoWhenACopyCouldNotBeRemoved() async throws {
        let requester = FakeProviderRequester()
        requester.pools["default"] = pool("openrouter", [("old", ProviderEntry.PoolRow.sharedLabel, "manual"),
                                                         ("new", ProviderEntry.PoolRow.sharedLabel, "manual")])
        requester.failingPools = ["bot"]
        let service = ProviderSettingsService(requester: requester, profile: "default", profiles: { ["default", "bot", "work"] })
        var entry = ProviderEntry(id: "openrouter", name: "OpenRouter")
        entry.key = ProviderEntry.KeyAccess(vars: ["OPENROUTER_API_KEY"], savedVars: [],
                                            sharedRows: [.init(id: "old", index: 1, label: ProviderEntry.PoolRow.sharedLabel)])

        let cleaned = try await service.share(key: "sk-new", for: entry)

        XCTAssertFalse(cleaned, "the key is saved, but a profile may still use the old copy")
        XCTAssertTrue(requester.calls.contains { $0.method == "GET" && $0.path.hasSuffix("profile=work") },
                      "one profile's failure doesn't stop the others")
        XCTAssertEqual(service.changes, 1)
    }

    func testRemovingTheMainProfilesKeyGoesPastAVariableAlreadyGone() async throws {
        let requester = FakeProviderRequester()
        requester.envDeleteFailures = ["OPENROUTER_API_KEY": DashboardTicketBridgeError.http(status: 404, detail: "")]
        let service = ProviderSettingsService(requester: requester, profile: "default")

        try await service.remove(variables: ["OPENROUTER_API_KEY", "OPENROUTER_KEY_2"])

        let deleted = requester.calls.filter { $0.method == "DELETE" }.compactMap { $0.body?["key"] as? String }
        XCTAssertEqual(deleted, ["OPENROUTER_API_KEY", "OPENROUTER_KEY_2"])
        XCTAssertEqual(service.changes, 1)
    }

    func testClearingABaseURLOverrideRemovesItsVariable() async throws {
        let requester = FakeProviderRequester()
        let service = ProviderSettingsService(requester: requester, profile: "bot")

        try await service.remove(variables: ["OPENROUTER_BASE_URL"])

        let delete = try XCTUnwrap(requester.calls.first { $0.method == "DELETE" })
        XCTAssertEqual(delete.path, "/api/env?profile=bot")
        XCTAssertEqual(delete.body?["key"] as? String, "OPENROUTER_BASE_URL")
        XCTAssertEqual(delete.body?["profile"] as? String, "bot")
    }

    func testSharingFromAnotherProfileClearsWhatComesAheadOfItThere() async throws {
        let requester = FakeProviderRequester()
        requester.pools["bot"] = pool("openrouter", [("stale", ProviderEntry.PoolRow.sharedLabel, "manual")])
        let service = ProviderSettingsService(requester: requester, profile: "bot")
        var entry = ProviderEntry(id: "openrouter", name: "OpenRouter")
        entry.onMainProfile = false
        entry.key = ProviderEntry.KeyAccess(vars: ["OPENROUTER_API_KEY"], savedVars: [],
                                            profileRows: [.init(id: "stale", index: 1, label: ProviderEntry.PoolRow.sharedLabel)])
        XCTAssertEqual(entry.status, .oldCopy)

        try await service.share(key: "sk-new", for: entry)

        XCTAssertEqual(requester.calls.filter { $0.method == "DELETE" }.map(\.path),
                       ["/api/credentials/pool/openrouter/1?profile=bot"])
    }

    func testSharingOnTheMainProfileReplacesItsOwnEnvKey() async throws {
        let requester = FakeProviderRequester()
        let service = ProviderSettingsService(requester: requester, profile: "default")
        var entry = ProviderEntry(id: "openrouter", name: "OpenRouter")
        entry.key = ProviderEntry.KeyAccess(vars: ["OPENROUTER_API_KEY"], savedVars: ["OPENROUTER_API_KEY"])
        XCTAssertEqual(entry.status, .mainProfileOnly)

        let cleaned = try await service.share(key: "sk-new", for: entry)

        XCTAssertTrue(cleaned)
        let delete = try XCTUnwrap(requester.calls.first { $0.method == "DELETE" })
        XCTAssertEqual(delete.path, "/api/env")
        XCTAssertEqual(delete.body?["key"] as? String, "OPENROUTER_API_KEY")
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

    func testANewEndpointStaysClearOfTheCatalogsProviders() {
        let service = ProviderSettingsService(requester: FakeProviderRequester(), profile: "default")
        service.reserve(catalog: [
            ProviderInfo(name: "openai-codex", models: [], displayName: "OpenAI", aliases: ["codex"]),
            ProviderInfo(name: "custom:lab", models: []),
        ])
        XCTAssertEqual(service.newEndpointID(forName: "OpenAI"), "openai-2", "OpenAI is a built-in's display name")
        XCTAssertEqual(service.newEndpointID(forName: "Codex"), "codex-2")
        XCTAssertEqual(service.newEndpointID(forName: "Lab"), "lab-2", "custom:lab is an endpoint already")
        XCTAssertEqual(service.newEndpointID(forName: "Lab vLLM"), "lab-vllm")
        XCTAssertTrue(service.catalogReserved)
        XCTAssertFalse(ProviderSettingsService(requester: FakeProviderRequester(), profile: "default").catalogReserved,
                       "a new endpoint waits for the catalog")
    }

    func testEditingTheDefaultEndpointKeepsItTheDefault() {
        let endpoint = ProviderEntry.EndpointAccess(endpointID: "lab", baseURL: "http://lab/v1", model: "qwen", models: ["qwen"],
                                                    apiMode: "", keySaved: true, isCurrent: true)
        let draft = CustomEndpointDraft(editing: "Lab", endpoint: endpoint)
        XCTAssertEqual(draft.endpointID, "lab")
        XCTAssertEqual(draft.body(forCheck: false)["make_default"] as? Bool, true)
        let other = CustomEndpointDraft(editing: "Lab", endpoint: .init(endpointID: "lab", baseURL: "", model: "", models: [],
                                                                        apiMode: "", keySaved: false, isCurrent: false))
        XCTAssertEqual(other.body(forCheck: false)["make_default"] as? Bool, false)
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
    /// Profiles whose credential pool can't be read.
    var failingPools: Set<String> = []
    /// Errors for `.env` removals, by variable.
    var envDeleteFailures: [String: Error] = [:]

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        calls.append(Call(path: path, method: method, body: body))
        let route = path.components(separatedBy: "?").first ?? path
        if method == "GET", let failure = failures[route] { throw failure }
        if method == "GET", route == "/api/env" { return envAnswer }
        if method == "GET", path.hasPrefix("/api/credentials/pool?") {
            let profile = path.components(separatedBy: "profile=").last ?? ""
            if failingPools.contains(profile) { throw DashboardTicketBridgeError.http(status: 500, detail: "") }
            return pools[profile] ?? ["providers": []]
        }
        if method == "DELETE", route == "/api/env", let key = body?["key"] as? String, let failure = envDeleteFailures[key] {
            throw failure
        }
        return ["ok": true]
    }
}
