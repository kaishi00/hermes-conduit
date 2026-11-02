import XCTest
@testable import Conduit

/// Settings > Capabilities' four tabs: the orderings, groupings and decoders
/// behind Skills, Tools, Connectors and Plugins, and the store's profile
/// scoping. An extension of KanbanTests (which already covers the screen's
/// load policy) so the test plan gains no class.
extension KanbanTests {
    // MARK: Skills

    func testCapabilitySkillsSortByUseThenName() {
        let skills = [
            CapabilitySkill(name: "beta", enabled: true, usage: 2),
            CapabilitySkill(name: "Alpha", enabled: true, usage: 2),
            CapabilitySkill(name: "gamma", enabled: false, usage: 9),
            CapabilitySkill(name: "delta", enabled: true),
        ]
        XCTAssertEqual(
            CapabilitySkillOrdering.sorted(skills, mostUsedFirst: true).map(\.name),
            ["gamma", "Alpha", "beta", "delta"]
        )
        XCTAssertEqual(
            CapabilitySkillOrdering.sorted(skills, mostUsedFirst: false).map(\.name),
            ["delta", "Alpha", "beta", "gamma"]
        )
    }

    func testCapabilityOfficialSkillsLeaveOutInstalledAndMatchTags() {
        let catalog = [
            OfficialSkill(name: "pdf-tools", identifier: "official/pdf-tools", tags: ["documents"]),
            OfficialSkill(name: "arxiv", identifier: "official/arxiv", category: "research"),
            OfficialSkill(name: "maps", identifier: "official/maps", installed: true),
            OfficialSkill(name: "notes", identifier: "official/notes"),
        ]
        XCTAssertEqual(
            CapabilitySkillOrdering.available(catalog, installedNames: ["notes"], query: "").map(\.name),
            ["arxiv", "pdf-tools"]
        )
        XCTAssertEqual(
            CapabilitySkillOrdering.available(catalog, installedNames: [], query: "DOCUMENT").map(\.name),
            ["pdf-tools"]
        )
        XCTAssertNil(OfficialSkill(["identifier": "x"]))
        XCTAssertEqual(OfficialSkill(["name": "solo"])?.identifier, "solo")
        XCTAssertEqual(CapabilitySkillOrdering.prettyCategory("software_development"), "Software Development")
        XCTAssertEqual(CapabilitySkillOrdering.prettyCategory(nil), "General")
    }

    func testCapabilitySkillFrontmatterKeepsTopLevelFields() {
        let text = """
        ---
        name: arxiv
        description: "Search papers"
        version: 1.2
        metadata:
          hermes:
            tags: [research]
        ---

        # arXiv

        Use the API.
        """
        let parsed = SkillFrontmatter.parse(text)
        XCTAssertEqual(parsed.fields.map(\.key), ["name", "description", "version"])
        XCTAssertEqual(parsed.fields.map(\.value), ["arxiv", "Search papers", "1.2"])
        XCTAssertEqual(parsed.body, "# arXiv\n\nUse the API.")

        let plain = SkillFrontmatter.parse("Just a body\n")
        XCTAssertTrue(plain.fields.isEmpty)
        XCTAssertEqual(plain.body, "Just a body")
    }

    // MARK: Tools

    func testCapabilityToolsetsHidePlumbingAndSortByCalls() {
        let web = CapabilityToolset(name: "web", enabled: true, label: "🔍 Web Search", tools: ["web_search", "web_extract"])
        let terminal = CapabilityToolset(name: "terminal", enabled: true, label: "Terminal", tools: ["terminal"])
        let browser = CapabilityToolset(name: "browser_use", enabled: false, tools: ["browser_navigate"])
        let discord = CapabilityToolset(name: "discord", enabled: true, tools: ["send"])

        XCTAssertFalse(CapabilityToolsetOrdering.isVisible(discord))
        XCTAssertTrue(CapabilityToolsetOrdering.isVisible(web))
        XCTAssertEqual(CapabilityToolsetOrdering.label(web), "Web Search")
        XCTAssertEqual(CapabilityToolsetOrdering.label(browser), "Browser Use")

        let counts = CapabilityToolsetOrdering.toolCallCounts(from: [
            "tools": [
                ["tool": "web_search", "count": 3],
                ["tool": "web_extract", "count": 2],
                ["tool": "terminal", "count": 40],
                ["tool": "broken"],
            ],
        ])
        XCTAssertEqual(counts, ["web_search": 3, "web_extract": 2, "terminal": 40])
        XCTAssertEqual(CapabilityToolsetOrdering.calls(web, counts: counts), 5)
        XCTAssertEqual(
            CapabilityToolsetOrdering.sorted([web, browser, terminal], counts: counts, mostUsedFirst: true).map(\.name),
            ["terminal", "web", "browser_use"]
        )
        XCTAssertEqual(
            CapabilityToolsetOrdering.sorted([web, browser, terminal], counts: counts, mostUsedFirst: false).map(\.name),
            ["browser_use", "web", "terminal"]
        )
        XCTAssertTrue(CapabilityToolsetOrdering.matches(web, query: "extract"))
        XCTAssertFalse(CapabilityToolsetOrdering.matches(terminal, query: "extract"))
    }

    func testCapabilityToolsetConfigTellsManagedFromOwnKeyWebBackends() {
        let config = ToolsetConfig([
            "has_category": true,
            "active_search_backend": "firecrawl",
            "active_extract_backend": "firecrawl",
            "search_via_nous": true,
            "extract_via_nous": false,
            "providers": [
                [
                    "name": "Nous Subscription",
                    "managed_nous_feature": "web",
                    "web_backend": "firecrawl",
                    "capabilities": ["search", "extract"],
                    "status": "ready",
                ],
                [
                    "name": "Firecrawl",
                    "web_backend": "firecrawl",
                    "capabilities": ["search", "extract"],
                    "status": "needs_keys",
                    "env_vars": [["key": "FIRECRAWL_API_KEY", "prompt": "", "is_set": false]],
                ],
            ],
        ])
        XCTAssertEqual(config.providers.count, 2)
        let managed = config.providers[0]
        let ownKey = config.providers[1]
        XCTAssertTrue(config.serves("search", provider: managed))
        XCTAssertFalse(config.serves("search", provider: ownKey))
        XCTAssertFalse(config.serves("extract", provider: managed))
        XCTAssertTrue(config.serves("extract", provider: ownKey))
        XCTAssertEqual(ownKey.envVars.first?.prompt, "FIRECRAWL_API_KEY")

        let backends = TerminalBackendOption.list(from: [
            "backends": [
                ["name": "local", "label": "Local", "active": true, "status": "ready"],
                ["name": "docker", "label": "", "status": "needs_setup", "detail": ""],
            ],
        ])
        XCTAssertEqual(backends.map(\.label), ["Local", "docker"])
        XCTAssertNil(backends[1].detail)
    }

    // MARK: Connectors

    func testCapabilityConnectorStateReadsAuthErrorsAsSignIn() {
        let server = ConnectorServer.list(from: [
            "servers": [["name": "linear", "transport": "http", "url": "https://mcp.linear.app/sse", "enabled": true]],
        ])[0]
        XCTAssertTrue(server.canSignIn)
        XCTAssertEqual(ConnectorState.of(server, probe: nil, probing: false), .unknown)
        XCTAssertEqual(ConnectorState.of(server, probe: nil, probing: true), .checking)
        XCTAssertEqual(
            ConnectorState.of(server, probe: ConnectorProbe(["ok": true, "tools": [["name": "a"], ["name": "b"]]]), probing: false),
            .on(tools: 2)
        )
        XCTAssertEqual(ConnectorState.of(server, probe: ConnectorProbe(failure: "HTTP 401 Unauthorized"), probing: false), .needsSignIn)
        XCTAssertEqual(ConnectorState.of(server, probe: ConnectorProbe(failure: "connection refused"), probing: false), .failed("connection refused"))

        var off = server
        off.enabled = false
        XCTAssertEqual(ConnectorState.of(off, probe: ConnectorProbe(failure: "x"), probing: true), .off)

        let header = ConnectorServer.list(from: [
            "servers": [["name": "gh", "transport": "http", "url": "https://x", "auth": "header"]],
        ])[0]
        XCTAssertFalse(header.canSignIn)
        let fromPlugin = ConnectorServer.list(from: [
            "servers": [["name": "p", "transport": "http", "url": "https://x", "source": "plugin", "plugin": "acme"]],
        ])[0]
        XCTAssertEqual(fromPlugin.plugin, "acme")
        XCTAssertFalse(fromPlugin.canSignIn)
    }

    func testCapabilityConnectorGroupsPutBrokenFirstAndHideInstalledCatalog() {
        let servers = ConnectorServer.list(from: [
            "servers": [
                ["name": "zeta", "transport": "stdio", "command": "npx", "enabled": true],
                ["name": "alpha", "transport": "http", "url": "https://a", "enabled": true],
                ["name": "mid", "transport": "http", "url": "https://m", "enabled": true],
                ["name": "sleepy", "transport": "stdio", "command": "uvx", "enabled": false],
            ],
        ])
        let catalog = ConnectorCatalogEntry.list(from: [
            "entries": [
                ["name": "zeta", "description": "configured already"],
                ["name": "notion", "description": "Pages", "auth_type": "oauth"],
                ["name": "github", "description": "Repos", "installed": true],
                ["name": "brave", "description": "Search", "required_env": [["name": "BRAVE_API_KEY", "prompt": ""]]],
            ],
        ])
        let states: [String: ConnectorState] = [
            "zeta": .on(tools: 3),
            "alpha": .needsSignIn,
            "mid": .failed("boom"),
            "sleepy": .off,
        ]
        let groups = ConnectorGrouping.groups(servers: servers, catalog: catalog, states: states, query: "")
        XCTAssertEqual(groups.connected.map(\.name), ["mid", "alpha", "zeta"])
        XCTAssertEqual(groups.available.map(\.name), ["brave", "notion"])
        XCTAssertEqual(groups.off.map(\.name), ["sleepy"])
        XCTAssertEqual(catalog.first { $0.name == "brave" }?.requiredEnv.first?.prompt, "BRAVE_API_KEY")

        let searched = ConnectorGrouping.groups(servers: servers, catalog: catalog, states: states, query: "uvx")
        XCTAssertTrue(searched.connected.isEmpty)
        XCTAssertEqual(searched.off.map(\.name), ["sleepy"])
        XCTAssertTrue(searched.available.isEmpty)
    }

    // MARK: Plugins

    func testCapabilityAgentPluginsListAsDesktopDoes() {
        let plugins = AgentPluginRow.list(from: [
            "plugins": [
                ["name": "spotify", "source": "bundled", "runtime_status": "enabled"],
                ["name": "disk-cleanup", "source": "bundled", "runtime_status": "disabled"],
                ["name": "model-providers/openrouter", "source": "user"],
                ["name": "Weather", "source": "git", "runtime_status": "enabled", "can_remove": true,
                 "path": "/home/me/.hermes/plugins/hermes-weather"],
            ],
        ])
        XCTAssertEqual(plugins.map(\.name), ["disk-cleanup", "Weather"])
        let weather = plugins[1]
        XCTAssertTrue(weather.isEnabled)
        XCTAssertTrue(weather.canUpdate)
        XCTAssertEqual(weather.folderName, "hermes-weather")
        XCTAssertFalse(plugins[0].canUpdate)
        XCTAssertEqual(plugins[0].folderName, "disk-cleanup")

        let catalog = PluginCatalogEntry.list(from: [
            "entries": [
                ["name": "hermes-weather", "title": "Weather", "tier": "official", "installed": true, "update_available": true],
                ["name": "other", "installed": false],
            ],
        ])
        XCTAssertEqual(PluginCatalogEntry.entry(for: weather, in: catalog)?.name, "hermes-weather")
        XCTAssertEqual(catalog[1].displayName, "other")
        XCTAssertEqual(catalog[1].tier, "community")
        XCTAssertEqual(CapabilitiesStore.pluginPath("model-providers/open router"), "model-providers/open%20router")
    }

    // MARK: Search

    func testCapabilitySearchCountsEachTabAsItLists() {
        var sources = CapabilitySearchCounts.Sources()
        sources.skills = [
            CapabilitySkill(name: "weather-brief", enabled: true),
            CapabilitySkill(name: "notes", description: "Weather notes", enabled: false),
            CapabilitySkill(name: "maps", enabled: true),
        ]
        sources.officialSkills = [
            OfficialSkill(name: "weather-radar", identifier: "official/weather-radar"),
            OfficialSkill(name: "weather-brief", identifier: "official/weather-brief"),
        ]
        sources.toolsets = [
            CapabilityToolset(name: "weather", enabled: true),
            CapabilityToolset(name: "discord", description: "weather bot", enabled: true),
        ]
        sources.servers = ConnectorServer.list(from: [
            "servers": [["name": "weather-mcp", "transport": "http", "url": "https://w", "enabled": false]],
        ])
        sources.connectorCatalog = ConnectorCatalogEntry.list(from: [
            "entries": [["name": "notion", "description": "Pages"]],
        ])
        sources.plugins = AgentPluginRow.list(from: [
            "plugins": [["name": "Weather", "source": "git", "runtime_status": "enabled"]],
        ])
        sources.pluginCatalog = PluginCatalogEntry.list(from: [
            "entries": [
                ["name": "hermes-weather", "title": "Weather", "installed": true],
                ["name": "weather-alerts", "installed": false],
            ],
        ])

        XCTAssertEqual(CapabilitySearchCounts.counts(query: "", in: sources), [:])
        // A catalog skill already installed counts once; hidden toolsets not at all.
        XCTAssertEqual(
            CapabilitySearchCounts.counts(query: "weather", in: sources),
            [.skills: 3, .tools: 1, .connectors: 1, .plugins: 2]
        )
        XCTAssertEqual(
            CapabilitySearchCounts.counts(query: "pages", in: sources),
            [.skills: 0, .tools: 0, .connectors: 1, .plugins: 0]
        )
    }

    func testCapabilityListMemoRecomputesOnlyWhenItsInputChanges() {
        let memo = CapabilityListMemo<[String], [String]>()
        var runs = 0
        let sort: ([String]) -> [String] = { runs += 1; return $0.sorted() }
        XCTAssertEqual(memo.value(for: ["b", "a"], sort), ["a", "b"])
        XCTAssertEqual(memo.value(for: ["b", "a"], sort), ["a", "b"])
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(memo.value(for: ["c", "a"], sort), ["a", "c"])
        XCTAssertEqual(runs, 2)
    }

    func testCapabilityActionStatusNamesTheLastLogLine() {
        let failed = HermesActionStatus(["running": false, "exit_code": 1, "lines": ["Fetching…", "Error: scan blocked it", "", "=== exit 1 ==="]])
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.failureReason, "Error: scan blocked it")
        XCTAssertTrue(HermesActionStatus(["running": false, "exit_code": 0]).succeeded)
        XCTAssertFalse(HermesActionStatus(["running": true]).succeeded)
    }

    // MARK: Switches

    /// Flips one switch through `writes`, as the row does: shown at once,
    /// put back when the outcome says so.
    @MainActor
    private final class SwitchHarness {
        let writes = CapabilityToggleWrites()
        var row: Bool
        var sent: [Bool] = []
        var inFlight = 0
        var overlapped = false
        var held: [CheckedContinuation<Void, Never>] = []
        var outcomes: [Bool: CapabilityToggleWrites.Outcome] = [:]
        /// Outcomes that would show "Could not update" to the user.
        var failuresReported = 0
        /// The values kept for Capabilities to open on, in turn: AppState
        /// keeps a flip once Hermes took it.
        var kept: [Bool] = []
        private var running = 0

        init(row: Bool) { self.row = row }

        func flip(_ enabled: Bool, fails: Bool) async {
            let current = row
            row = enabled
            running += 1
            Task {
                let outcome = await writes.send("default|skill|notes", enabled: enabled, current: current) {
                    self.inFlight += 1
                    self.overlapped = self.overlapped || self.inFlight > 1
                    defer { self.inFlight -= 1 }
                    self.sent.append(enabled)
                    await withCheckedContinuation { self.held.append($0) }
                    if fails { throw URLError(.timedOut) }
                }
                if let restore = outcome.restore { row = restore }
                if outcome.error != nil { failuresReported += 1 }
                if outcome.taken { kept.append(enabled) }
                running -= 1
            }
            for _ in 0..<10 { await Task.yield() }
        }

        /// Hermes answers the newest write it holds first.
        func answerAll() async {
            while running > 0 {
                if !held.isEmpty { held.removeLast().resume() }
                await Task.yield()
            }
        }
    }

    func testCapabilitySwitchesReachHermesInOrderAndAnOldFailureDoesntUndoANewerFlip() async {
        // On (fails), off, on: Hermes ends on, and so does the row.
        let harness = SwitchHarness(row: false)
        await harness.flip(true, fails: true)
        await harness.flip(false, fails: false)
        await harness.flip(true, fails: false)
        await harness.answerAll()

        XCTAssertFalse(harness.overlapped, "one switch reaches Hermes at a time")
        XCTAssertEqual(harness.sent, [true, false, true], "in the order flipped")
        XCTAssertTrue(harness.row, "the first flip's failure came last but a newer flip replaced it")
        XCTAssertEqual(harness.kept, [false, true], "the refused flip is never kept, though a newer one replaced it")
    }

    func testAFailedCapabilitySwitchGoesBackToWhatHermesLastConfirmed() async {
        // On and off both fail: Hermes still has it off.
        let harness = SwitchHarness(row: false)
        await harness.flip(true, fails: true)
        await harness.flip(false, fails: true)
        await harness.answerAll()

        XCTAssertFalse(harness.row)
        XCTAssertEqual(harness.kept, [], "nothing Hermes refused is kept")

        // On succeeds, off fails: Hermes has it on.
        let confirmed = SwitchHarness(row: false)
        await confirmed.flip(true, fails: false)
        await confirmed.flip(false, fails: true)
        await confirmed.answerAll()

        XCTAssertTrue(confirmed.row)
        XCTAssertEqual(confirmed.kept, [true])
    }

    func testAFailedCapabilitySwitchANewerFlipReplacedSaysNothingFailed() async {
        // On fails, then off is saved: off stands, and no banner says the
        // switch couldn't be updated.
        let harness = SwitchHarness(row: false)
        await harness.flip(true, fails: true)
        await harness.flip(false, fails: false)
        await harness.answerAll()

        XCTAssertFalse(harness.row)
        XCTAssertEqual(harness.failuresReported, 0, "the newer flip decides, and it went through")

        // The newest flip failing still says so.
        let newest = SwitchHarness(row: false)
        await newest.flip(true, fails: false)
        await newest.flip(false, fails: true)
        await newest.answerAll()

        XCTAssertEqual(newest.failuresReported, 1)
    }

    // MARK: Store

    func testCapabilitiesStoreScopesReadsToTheActiveProfile() async {
        let requester = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["servers": [["name": "linear", "transport": "http", "url": "https://l", "enabled": false]]],
            "/api/mcp/catalog": ["entries": [["name": "notion"]]],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        await store.loadConnectors()

        XCTAssertEqual(Set(requester.calls.map(\.path)), ["/api/mcp/servers?profile=work", "/api/mcp/catalog?profile=work"])
        XCTAssertEqual(store.servers.map(\.name), ["linear"])
        XCTAssertEqual(store.connectorCatalog.map(\.name), ["notion"])
        XCTAssertTrue(store.connectorsLoaded)
        XCTAssertNil(store.connectorsError)

        // A switch drops what the old profile loaded.
        store.configure(requester: requester, profile: "default")
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertFalse(store.connectorsLoaded)
        requester.calls.removeAll()
        await store.loadConnectors()
        XCTAssertEqual(Set(requester.calls.map(\.path)), ["/api/mcp/servers", "/api/mcp/catalog"])
    }

    func testCapabilitiesStoreReportsReadFailuresAndPluginRestarts() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/dashboard/plugins/hub": ["plugins": [["name": "Weather", "source": "git", "runtime_status": "disabled"]]],
            "/api/dashboard/plugins/catalog": ["entries": [[String: Any]]()],
            "/api/dashboard/agent-plugins/Weather/enable": ["ok": true, "restart_required": true],
        ])
        let store = CapabilitiesStore()
        await store.loadConnectors()
        XCTAssertNotNil(store.connectorsError, "an unconfigured store has no dashboard to read")

        store.configure(requester: requester, profile: "default")
        await store.loadPlugins()
        XCTAssertEqual(store.plugins.map(\.name), ["Weather"])
        XCTAssertFalse(store.pluginsNeedRestart)

        try await store.setPluginEnabled(store.plugins[0], enabled: true)
        XCTAssertTrue(store.plugins[0].isEnabled)
        XCTAssertTrue(store.pluginsNeedRestart)
        XCTAssertEqual(requester.calls.last?.method, "POST")
        XCTAssertTrue(store.pluginBusy.isEmpty)
    }

    func testAnOlderCapabilityLoadNeverOverwritesANewerOne() async {
        let requester = CapabilityMockRequester(responses: [
            "/api/dashboard/plugins/hub": ["plugins": [["name": "Weather", "source": "git", "runtime_status": "disabled"]]],
            "/api/dashboard/plugins/catalog": ["entries": [[String: Any]]()],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        var held: CheckedContinuation<Void, Never>?
        requester.beforeAnswering = { path in
            guard path == "/api/dashboard/plugins/hub", held == nil else { return }
            await withCheckedContinuation { held = $0 }
        }

        // A refresh leaves, then a newer one reads the list after a change.
        let older = Task { await store.loadPlugins() }
        while held == nil { await Task.yield() }
        requester.responses["/api/dashboard/plugins/hub"] = ["plugins": [
            ["name": "Weather", "source": "git", "runtime_status": "enabled"],
            ["name": "Maps", "source": "git", "runtime_status": "enabled"],
        ]]
        await store.loadPlugins()
        held?.resume()
        await older.value

        XCTAssertEqual(Set(store.plugins.map(\.name)), ["Weather", "Maps"], "the older answer arrived last but is older")
        XCTAssertEqual(store.plugins.first { $0.name == "Weather" }?.isEnabled, true)
    }

    /// A catalog connector's keys go to the profile's .env, only the
    /// variables its entry declares, never its config.
    func testAConnectorKeyIsSetInTheProfileEnvOnly() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["servers": [["name": "linear", "transport": "http", "url": "https://l", "enabled": true]]],
            "/api/mcp/catalog": ["entries": [
                ["name": "linear", "description": "Issues", "auth_type": "api_key", "installed": true,
                 "required_env": [["name": "LINEAR_API_KEY", "prompt": "Linear API key", "required": true]]],
                ["name": "notion", "description": "Pages", "auth_type": "oauth"],
            ]],
            "/api/env": ["ok": true],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        await store.loadConnectors()
        let linear = try XCTUnwrap(store.connectorCatalog.first { $0.name == "linear" })
        let notion = try XCTUnwrap(store.connectorCatalog.first { $0.name == "notion" })
        let fields = try XCTUnwrap(ConnectorKeysSection.fields(linear))
        XCTAssertEqual(fields.map(\.name), ["LINEAR_API_KEY"])
        XCTAssertNil(ConnectorKeysSection.fields(notion), "an OAuth connector signs in instead")
        XCTAssertEqual(ConnectorKeysSection.values(["LINEAR_API_KEY": "  lin-key  ", "OTHER": "x"], fields: fields),
                       ["LINEAR_API_KEY": "lin-key"])
        XCTAssertTrue(ConnectorKeysSection.values(["LINEAR_API_KEY": "   "], fields: fields).isEmpty)

        requester.calls.removeAll()
        try await store.setConnectorKeys("linear", ["LINEAR_API_KEY": "lin-key", "PATH": "/tmp"])
        let writes = requester.calls.filter { $0.method != "GET" }
        XCTAssertEqual(writes.count, 1, "an undeclared variable isn't written")
        XCTAssertEqual(writes.first?.method, "PUT")
        XCTAssertEqual(writes.first?.path.hasPrefix("/api/env"), true)
        XCTAssertEqual(writes.first?.body?["key"] as? String, "LINEAR_API_KEY")
        XCTAssertEqual(writes.first?.body?["value"] as? String, "lin-key")
        XCTAssertEqual(writes.first?.body?["profile"] as? String, "work")
    }

    /// A switch to another profile between two keys stops the save: the
    /// key left isn't written to the profile switched to.
    func testAConnectorKeySaveStopsWhenTheProfileChanges() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["servers": [["name": "jira", "transport": "http", "url": "https://j", "enabled": true]]],
            "/api/mcp/catalog": ["entries": [
                ["name": "jira", "description": "Issues", "auth_type": "api_key", "installed": true,
                 "required_env": [["name": "JIRA_EMAIL", "prompt": "Email", "required": true],
                                  ["name": "JIRA_TOKEN", "prompt": "Token", "required": true]]],
            ]],
            "/api/env": ["ok": true],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        await store.loadConnectors()
        requester.calls.removeAll()
        requester.beforeAnswering = { path in
            if path == "/api/env" { store.configure(requester: requester, profile: "home") }
        }
        do {
            try await store.setConnectorKeys("jira", ["JIRA_EMAIL": "me@example.com", "JIRA_TOKEN": "tok"])
            XCTFail("the save stops at the switch")
        } catch {
            XCTAssertEqual(error as? CapabilitiesStoreError, .profileChanged)
        }
        let writes = requester.calls.filter { $0.method == "PUT" }
        XCTAssertEqual(writes.map { $0.body?["key"] as? String }, ["JIRA_EMAIL"])
        XCTAssertFalse(writes.contains { $0.body?["profile"] as? String == "home" })
    }

    /// Opening a server from the Connectors list cancels the list's tests;
    /// a test already sent still lands, and isn't shown as interrupted (#1570).
    func testAConnectorTestFinishesWhenTheListThatStartedItGoesAway() async {
        let requester = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["servers": [
                ["name": "griply", "transport": "http", "url": "https://g", "enabled": true],
                ["name": "linear", "transport": "http", "url": "https://l", "enabled": true],
            ]],
            "/api/mcp/catalog": ["entries": [[String: Any]]()],
            "/api/mcp/servers/griply/test": ["ok": true, "tools": [["name": "list_goals"]]],
            "/api/mcp/servers/linear/test": ["ok": true],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        await store.loadConnectors()
        var held: CheckedContinuation<Void, Never>?
        requester.beforeAnswering = { path in
            guard path == "/api/mcp/servers/griply/test", held == nil else { return }
            await withCheckedContinuation { held = $0 }
        }

        let list = Task { await store.probeServers() }
        while held == nil { await Task.yield() }
        list.cancel()
        held?.resume()
        await list.value
        while store.probing.contains("griply") { await Task.yield() }

        XCTAssertEqual(store.probes["griply"]?.ok, true)
        XCTAssertEqual(store.probes["griply"]?.tools.map(\.name), ["list_goals"])
    }

    /// Leaving the list while its first tests run starts no more of them.
    func testLeavingTheConnectorsListStartsNoMoreTests() async {
        let names = ["a", "b", "c", "d", "e"]
        var responses: [String: [String: Any]] = [
            "/api/mcp/servers": ["servers": names.map { ["name": $0, "transport": "http", "url": "https://\($0)", "enabled": true] }],
            "/api/mcp/catalog": ["entries": [[String: Any]]()],
        ]
        for name in names { responses["/api/mcp/servers/\(name)/test"] = ["ok": true] }
        let requester = CapabilityMockRequester(responses: responses)
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        await store.loadConnectors()
        var held: [CheckedContinuation<Void, Never>] = []
        requester.beforeAnswering = { path in
            guard path.hasSuffix("/test") else { return }
            await withCheckedContinuation { held.append($0) }
        }

        let list = Task { await store.probeServers() }
        while held.count < 3 { await Task.yield() }
        list.cancel()
        held.forEach { $0.resume() }
        await list.value

        XCTAssertEqual(requester.calls.filter { $0.path.hasSuffix("/test") }.count, 3)
        XCTAssertEqual(store.probes.count, 3)
        XCTAssertTrue(store.probing.isEmpty)
    }

    /// A test cancelled under it (the dashboard gone) isn't a failed test:
    /// nothing is recorded, so it's tested again.
    func testACancelledConnectorTestRecordsNothing() async {
        let requester = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["servers": [["name": "griply", "transport": "http", "url": "https://g", "enabled": true]]],
            "/api/mcp/catalog": ["entries": [[String: Any]]()],
        ])
        requester.failures["/api/mcp/servers/griply/test"] = CancellationError()
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        await store.loadConnectors()

        await store.probe("griply")
        XCTAssertNil(store.probes["griply"])
        XCTAssertTrue(store.probing.isEmpty)
    }

    // MARK: Editing a server (#1570)

    func testTheServerFormChangesOnlyItsFieldsAndKeepsTheRest() throws {
        var edit = ConnectorServerEdit(name: "griply", entry: [
            "url": "https://mcp.griply.app/mcp",
            "headers": ["Authorization": "Bearer ${MCP_GRIPLY_API_KEY}"],
            "timeout": 30,
        ])
        XCTAssertTrue(edit.isRemote)
        XCTAssertTrue(edit.json.contains("${MCP_GRIPLY_API_KEY}"), "a key shows as its reference")
        edit.url = "  https://mcp.griply.app/v2  "
        edit.name = "Griply"
        let saved = try edit.saved(fromJSON: false)
        XCTAssertEqual(saved.name, "Griply")
        XCTAssertEqual(saved.entry["url"] as? String, "https://mcp.griply.app/v2")
        XCTAssertEqual((saved.entry["headers"] as? [String: String])?["Authorization"], "Bearer ${MCP_GRIPLY_API_KEY}")
        XCTAssertEqual(saved.entry["timeout"] as? Int, 30)
        XCTAssertTrue(edit.renameSignsOut(auth: "oauth"))
        XCTAssertFalse(edit.renameSignsOut(auth: "header"))

        // The JSON shows the form's change, and the form what the JSON says.
        try edit.showJSON()
        XCTAssertTrue(edit.json.contains("https://mcp.griply.app/v2"))
        edit.json = #"{"url": "https://other.example/mcp", "enabled": false}"#
        try edit.showForm()
        XCTAssertEqual(edit.url, "https://other.example/mcp")
        XCTAssertEqual(try edit.saved(fromJSON: true).entry["enabled"] as? Bool, false)

        edit.url = ""
        XCTAssertThrowsError(try edit.saved(fromJSON: false)) { XCTAssertEqual($0 as? ConnectorServerEdit.Problem, .noTarget) }
        edit.name = " "
        XCTAssertThrowsError(try edit.saved(fromJSON: false)) { XCTAssertEqual($0 as? ConnectorServerEdit.Problem, .noName) }
    }

    func testServerJSONMustBeOneObjectWithAnAddressOrCommand() {
        var edit = ConnectorServerEdit(name: "files", entry: ["command": "npx", "args": ["-y", "server-filesystem"]])
        XCTAssertFalse(edit.isRemote)
        XCTAssertEqual(edit.arguments, "-y\nserver-filesystem")
        edit.arguments = "-y\n\n  server-filesystem\n/tmp  "
        XCTAssertEqual(try edit.formEntry()["args"] as? [String], ["-y", "server-filesystem", "/tmp"])

        edit.json = "{ not json"
        XCTAssertThrowsError(try edit.showForm()) { XCTAssertEqual($0 as? ConnectorServerEdit.Problem, .invalidJSON) }
        edit.json = #"["npx"]"#
        XCTAssertThrowsError(try edit.jsonEntry()) { XCTAssertEqual($0 as? ConnectorServerEdit.Problem, .notAnObject) }
        edit.json = #"{"timeout": 5}"#
        XCTAssertThrowsError(try edit.jsonEntry()) { XCTAssertEqual($0 as? ConnectorServerEdit.Problem, .noTarget) }
    }

    func testSavingAServerReplacesOnlyItInTheProfilesMap() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/config": ["mcp_servers": [
                "griply": ["url": "https://old", "headers": ["Authorization": "Bearer ${MCP_GRIPLY_API_KEY}"]],
                "linear": ["url": "https://l", "enabled": false],
            ]],
            "/api/mcp/servers": ["ok": true, "servers": [["name": "Griply", "transport": "http", "url": "https://new", "enabled": false]]],
            "/api/mcp/catalog": ["entries": [[String: Any]]()],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")

        let entry = try await store.serverConfig("griply")
        XCTAssertEqual(entry["url"] as? String, "https://old")
        XCTAssertEqual(requester.calls.last?.path, "/api/config?include_defaults=false&profile=work")

        try await store.saveServer(original: "griply", loaded: entry, name: "Griply", entry: ["url": "https://new"], openedOn: store.generation)
        let put = try XCTUnwrap(requester.calls.first { $0.method == "PUT" })
        XCTAssertEqual(put.path, "/api/mcp/servers?profile=work")
        XCTAssertEqual(put.body?["profile"] as? String, "work")
        let servers = try XCTUnwrap(put.body?["servers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["Griply", "linear"], "a rename drops the old name")
        XCTAssertEqual((servers["linear"] as? [String: Any])?["enabled"] as? Bool, false, "other servers go back as they were")
        XCTAssertEqual(store.servers.map(\.name), ["Griply"])

        do {
            try await store.saveServer(original: "Griply", loaded: entry, name: "linear", entry: ["url": "https://x"], openedOn: store.generation)
            XCTFail("a taken name is refused")
        } catch {
            XCTAssertEqual(error as? ConnectorServerEdit.Problem, .gone("Griply"), "the host's map still says griply")
        }
        do {
            try await store.saveServer(original: "griply", loaded: entry, name: "linear", entry: ["url": "https://x"], openedOn: store.generation)
            XCTFail("a taken name is refused")
        } catch {
            XCTAssertEqual(error as? ConnectorServerEdit.Problem, .nameTaken("linear"))
        }
    }

    func testTheFormFollowsAServerMovedBetweenAddressAndCommandInJSON() throws {
        var edit = ConnectorServerEdit(name: "files", entry: ["command": "npx", "args": ["-y", 3]])
        // Untouched arguments go back as they were, numbers included, and
        // an edit elsewhere keeps the number.
        XCTAssertEqual((try edit.formEntry()["args"] as? [Any])?.last as? Int, 3)
        edit.arguments = "-y\n--port\n3"
        let edited = try XCTUnwrap(try edit.formEntry()["args"] as? [Any])
        XCTAssertEqual(edited.count, 3)
        XCTAssertEqual(edited[1] as? String, "--port")
        XCTAssertEqual(edited[2] as? Int, 3)
        // An original is reused once: a second "3" is the text typed.
        edit.arguments = "-y\n3\n3"
        let twice = try XCTUnwrap(try edit.formEntry()["args"] as? [Any])
        XCTAssertEqual(twice[1] as? Int, 3)
        XCTAssertEqual(twice[2] as? String, "3")
        edit.arguments = "-y\n3"
        try edit.showJSON()
        edit.json = #"{"url": "https://files.example/mcp"}"#
        try edit.showForm()
        XCTAssertTrue(edit.isRemote)
        XCTAssertEqual(try edit.saved(fromJSON: false).entry["url"] as? String, "https://files.example/mcp")
    }

    func testEditingOneArgumentKeepsEmptyAndSpacedOnes() throws {
        var edit = ConnectorServerEdit(name: "files", entry: ["command": "npx", "args": ["--name", "", " x", "old"]])
        edit.arguments = "--name\n\n x\nnew"
        XCTAssertEqual(try edit.formEntry()["args"] as? [String], ["--name", "", " x", "new"])
    }

    func testAChangedNumberArgumentStaysANumber() throws {
        var edit = ConnectorServerEdit(name: "files", entry: ["command": "npx", "args": ["--port", 8080, true]])
        edit.arguments = "--port\n9090\nfalse"
        let args = try XCTUnwrap(try edit.formEntry()["args"] as? [Any])
        XCTAssertEqual(args[1] as? Int, 9090, "a number changed into a number stays one")
        XCTAssertEqual(args[2] as? String, "false", "a flag isn't a number: the text typed")
        edit.arguments = "--port\nauto\ntrue"
        XCTAssertEqual((try edit.formEntry()["args"] as? [Any])?[1] as? String, "auto", "a number changed into words is the words")
        // Lines moved: --verbose deleted above the port.
        edit = ConnectorServerEdit(name: "files", entry: ["command": "npx", "args": ["--verbose", "--port", 8080]])
        edit.arguments = "--port\n9090"
        let shifted = try XCTUnwrap(try edit.formEntry()["args"] as? [Any])
        XCTAssertEqual(shifted.count, 2)
        XCTAssertEqual(shifted[1] as? Int, 9090, "the number is found however the lines moved")
        // A number typed on a new line, after the number was changed into
        // words, is text: it replaced nothing.
        edit = ConnectorServerEdit(name: "files", entry: ["command": "npx", "args": ["--port", 8080]])
        edit.arguments = "--port\n--debug\n3000"
        let added = try XCTUnwrap(try edit.formEntry()["args"] as? [Any])
        XCTAssertEqual(added[1] as? String, "--debug")
        XCTAssertEqual(added[2] as? String, "3000")
        edit = ConnectorServerEdit(name: "files", entry: ["command": "npx", "args": ["--verbose", "--port", 8080]])
        // Only text that reads back as typed becomes a number.
        for typed in ["007", "1.10", "1e3", "9090.0"] {
            edit.arguments = "--port\n\(typed)"
            XCTAssertEqual((try edit.formEntry()["args"] as? [Any])?[1] as? String, typed, "\(typed) stays as typed")
        }
    }

    func testAnEditedServerShowsItsSavedEntryWhenTheListCantBeRead() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/config": ["mcp_servers": ["griply": ["url": "https://old"]]],
            "/api/mcp/servers": ["ok": true, "servers": [["name": "griply", "transport": "http", "url": "https://old", "enabled": true]]],
            "/api/mcp/catalog": ["entries": [[String: Any]]()],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        await store.loadConnectors()
        let entry = try await store.serverConfig("griply")
        requester.failures["GET /api/mcp/servers"] = DashboardTicketBridgeError.http(status: 502, detail: "Bad Gateway")
        try await store.saveServer(original: "griply", loaded: entry, name: "griply", entry: ["url": "https://new", "enabled": false], openedOn: store.generation)
        XCTAssertEqual(store.servers.map(\.name), ["griply"])
        XCTAssertEqual(store.servers.first?.url, "https://new", "not the address from before the save")
        XCTAssertEqual(store.servers.first?.enabled, false, "a server saved off isn't started by a re-test")
        XCTAssertEqual(store.servers.first?.args, [], "a remote entry has no arguments")
        XCTAssertFalse(requester.calls.contains { $0.method == "POST" && $0.path.contains("/test") })
        try await store.saveServer(original: "griply", loaded: try await store.serverConfig("griply"), name: "griply", entry: ["command": "npx", "args": ["--port", 9090]], openedOn: store.generation)
        XCTAssertEqual(store.servers.first?.args, ["--port", "9090"], "the saved row's arguments as written")
    }

    func testARenamedServerShowsWhenTheListCantBeReadAfterTheSave() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/config": ["mcp_servers": ["griply": ["url": "https://old"]]],
            "/api/mcp/servers": ["ok": true, "servers": [["name": "griply", "transport": "http", "url": "https://old", "auth": "oauth", "enabled": true]]],
            "/api/mcp/catalog": ["entries": [[String: Any]]()],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        await store.loadConnectors()
        XCTAssertEqual(store.servers.map(\.name), ["griply"])

        let entry = try await store.serverConfig("griply")
        requester.failures["GET /api/mcp/servers"] = DashboardTicketBridgeError.http(status: 502, detail: "Bad Gateway")
        try await store.saveServer(original: "griply", loaded: entry, name: "Griply", entry: ["url": "https://new"], openedOn: store.generation)
        let row = try XCTUnwrap(store.servers.first)
        XCTAssertEqual(store.servers.map(\.name), ["Griply"], "the page follows the rename instead of saying it's gone")
        XCTAssertFalse(store.connectorsError == nil, "the failed reload still says so")
        XCTAssertEqual(store.servers.filter { $0.name == "Griply" }.count, 1, "one row under the saved name")
        XCTAssertEqual(row.url, "https://new")
        XCTAssertNil(row.auth, "the saved entry has no sign-in, whatever the old row had")
        XCTAssertTrue(row.enabled)
    }

    func testAListRowShowsNumberArguments() {
        let rows = ConnectorServer.list(from: ["servers": [["name": "files", "transport": "stdio", "command": "npx", "args": ["--port", 9090, "-y"]]]])
        XCTAssertEqual(rows.first?.args, ["--port", "9090", "-y"])
        // A JSON boolean reads as a word everywhere, not 1.
        let decoded = try? JSONSerialization.jsonObject(with: Data(#"["--watch", true, 8080]"#.utf8)) as? [Any]
        let entry: [String: Any] = ["command": "npx", "args": decoded ?? []]
        XCTAssertEqual(ConnectorServer.saved(name: "files", entry: entry, replacing: nil).args, ["--watch", "true", "8080"])
        XCTAssertEqual(ConnectorServerEdit(name: "files", entry: entry).arguments, "--watch\ntrue\n8080")
        // The catalog's install sheet shows them the same way.
        let catalog = ConnectorCatalogEntry.list(from: ["entries": [["name": "files", "transport": "stdio", "command": "npx", "args": decoded ?? []]]])
        XCTAssertEqual(catalog.first?.args, ["--watch", "true", "8080"])
    }

    func testAServerSaveSendsNothingAfterAProfileSwitch() async throws {
        let config: [String: [String: Any]] = [
            "/api/config": ["mcp_servers": ["griply": ["url": "https://old"]]],
            "/api/mcp/servers": ["ok": true, "servers": [[String: Any]]()],
        ]
        let requester = CapabilityMockRequester(responses: config)
        let other = CapabilityMockRequester(responses: config)
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        requester.beforeAnswering = { path in
            if path == "/api/config" { store.configure(requester: other, profile: "default") }
        }

        do {
            try await store.saveServer(original: "griply", loaded: ["url": "https://old"], name: "griply", entry: ["url": "https://new"], openedOn: store.generation)
            XCTFail("a save after a switch writes nothing")
        } catch {
            XCTAssertEqual(error as? CapabilitiesStoreError, .profileChanged)
        }
        XCTAssertFalse(requester.calls.contains { $0.method == "PUT" })
        XCTAssertTrue(other.calls.isEmpty)
    }

    func testAServerEditorOpenedBeforeASwitchSavesNothing() async {
        let requester = CapabilityMockRequester(responses: [
            "/api/config": ["mcp_servers": ["griply": ["url": "https://old"]]],
            "/api/mcp/servers": ["ok": true],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        let opened = store.generation
        store.configure(requester: requester, profile: "default")
        do {
            try await store.saveServer(original: "griply", loaded: ["url": "https://old"], name: "griply", entry: ["url": "https://new"], openedOn: opened)
            XCTFail("the entry came from another profile")
        } catch {
            XCTAssertEqual(error as? CapabilitiesStoreError, .profileChanged)
        }
        XCTAssertTrue(requester.calls.isEmpty)
    }

    func testAServerChangedOnTheHostWhileEditingIsntOverwritten() async {
        let requester = CapabilityMockRequester(responses: [
            "/api/config": ["mcp_servers": ["griply": ["url": "https://old", "enabled": false]]],
            "/api/mcp/servers": ["ok": true],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        do {
            try await store.saveServer(
                original: "griply",
                loaded: ["url": "https://old"],
                name: "griply",
                entry: ["url": "https://new"],
                openedOn: store.generation
            )
            XCTFail("the host turned it off since the editor read it")
        } catch {
            XCTAssertEqual(error as? ConnectorServerEdit.Problem, .changedOnHost("griply"))
        }
        XCTAssertFalse(requester.calls.contains { $0.method == "PUT" })
    }

    func testATestRunningWhenTheServerIsSavedIsRunAgainOnTheSavedEntry() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["ok": true, "servers": [["name": "griply", "transport": "http", "url": "https://g", "enabled": true]]],
            "/api/mcp/catalog": ["entries": [[String: Any]]()],
            "/api/config": ["mcp_servers": ["griply": ["url": "https://old"]]],
            "/api/mcp/servers/griply/test": ["ok": false, "error": "old address"],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        await store.loadConnectors()
        var held: CheckedContinuation<Void, Never>?
        requester.beforeAnswering = { path in
            guard path == "/api/mcp/servers/griply/test", held == nil else { return }
            await withCheckedContinuation { held = $0 }
        }
        let first = Task { await store.probe("griply") }
        while held == nil { await Task.yield() }

        try await store.saveServer(
            original: "griply",
            loaded: ["url": "https://old"],
            name: "griply",
            entry: ["url": "https://new"],
            openedOn: store.generation
        )
        requester.responses["/api/mcp/servers/griply/test"] = ["ok": true]
        held?.resume()
        await first.value
        // The save's own background test may still be finishing.
        while store.probing.contains("griply") { await Task.yield() }

        XCTAssertEqual(store.probes["griply"]?.ok, true, "the old entry's answer is dropped and the saved one tested")
        XCTAssertGreaterThanOrEqual(requester.calls.filter { $0.path.hasSuffix("/test") }.count, 2)
    }

    func testAHermesWithoutTheEditRouteSaysToUpdate() async {
        let requester = CapabilityMockRequester(responses: [
            "/api/config": ["mcp_servers": ["griply": ["url": "https://old"]]],
        ])
        requester.failures["PUT /api/mcp/servers"] = DashboardTicketBridgeError.http(status: 405, detail: "Method Not Allowed")
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        do {
            try await store.saveServer(original: "griply", loaded: ["url": "https://old"], name: "griply", entry: ["url": "https://new"], openedOn: store.generation)
            XCTFail("a 405 is a Hermes without the route")
        } catch {
            XCTAssertEqual(error as? CapabilitiesStoreError, .editUnsupported)
        }
    }

    func testARefreshOnItsWayDoesntUndoASwitchFlippedMeanwhile() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/dashboard/plugins/hub": ["plugins": [["name": "Weather", "source": "git", "runtime_status": "disabled"]]],
            "/api/dashboard/plugins/catalog": ["entries": [[String: Any]]()],
            "/api/dashboard/agent-plugins/Weather/enable": ["ok": true],
            "/api/mcp/servers": ["servers": [["name": "linear", "transport": "http", "url": "https://l", "enabled": false]]],
            "/api/mcp/catalog": ["entries": [[String: Any]]()],
            "/api/mcp/servers/linear/enabled": ["ok": true],
            "/api/mcp/servers/linear/test": ["ok": true],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        await store.loadPlugins()
        await store.loadConnectors()
        var held: [CheckedContinuation<Void, Never>] = []
        var holding: Set<String> = ["/api/dashboard/plugins/hub", "/api/mcp/servers"]
        requester.beforeAnswering = { path in
            guard holding.remove(path) != nil else { return }
            await withCheckedContinuation { held.append($0) }
        }

        // Pull to refresh, then flip each switch before the refresh answers.
        let plugins = Task { await store.loadPlugins() }
        let connectors = Task { await store.loadConnectors() }
        while held.count < 2 { await Task.yield() }
        try await store.setPluginEnabled(store.plugins[0], enabled: true)
        try await store.setServerEnabled("linear", enabled: true)
        held.forEach { $0.resume() }
        await plugins.value
        _ = await connectors.value

        XCTAssertTrue(store.plugins[0].isEnabled, "the refresh read the plugin before it was turned on")
        XCTAssertEqual(store.servers.first?.enabled, true, "the refresh read the server before it was turned on")
    }

    func testCapabilitiesStoreChangesPluginsOnlyFromTheDefaultProfile() async {
        let requester = CapabilityMockRequester(responses: [
            "/api/dashboard/agent-plugins/Weather/enable": ["ok": true],
            "/api/analytics/usage": ["tools": [["tool": "terminal", "count": 4]]],
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        XCTAssertFalse(store.canManagePlugins)
        let weather = AgentPluginRow.list(from: ["plugins": [["name": "Weather", "source": "git"]]])[0]
        do {
            try await store.setPluginEnabled(weather, enabled: true)
            XCTFail("Hermes would apply it to the default profile")
        } catch {
            XCTAssertTrue(error is CapabilitiesStoreError)
        }
        XCTAssertTrue(requester.calls.isEmpty)

        // Counts already read survive a failed refresh.
        await store.loadToolCalls()
        XCTAssertEqual(store.toolCalls, ["terminal": 4])
        requester.responses["/api/analytics/usage"] = nil
        await store.loadToolCalls()
        XCTAssertEqual(store.toolCalls, ["terminal": 4])
    }

    /// Each tab opens on the lists it showed last time, kept on the phone,
    /// until Hermes answers (#1533): a read that fails keeps them up, and
    /// Hermes' answer takes their place. A server's command arguments are
    /// never kept. A change made here is kept, and one made to a kept list
    /// reads it again.
    func testEachCapabilitiesTabOpensOnWhatItShowedLastTime() async throws {
        let requester = CapabilityMockRequester(responses: [
            "/api/skills/hub/official": ["skills": [["name": "pdf", "identifier": "official/pdf"]]],
            "/api/analytics/usage": ["tools": [["tool": "terminal", "count": 4]], "daily": [["day": "2026-10-30", "sessions": 3]]],
            "/api/mcp/servers": ["servers": [[
                "name": "linear", "transport": "stdio", "command": "npx", "args": ["linear-mcp", "--token", "lin_api_x"],
                "auth": "header", "enabled": true, "env": ["LINEAR_WORKSPACE": "x"],
            ]]],
            "/api/mcp/catalog": ["entries": [["name": "notion", "auth_type": "oauth"]]],
            "/api/dashboard/plugins/hub": ["plugins": [["name": "Weather", "source": "git", "runtime_status": "disabled"]]],
            "/api/dashboard/plugins/catalog": ["entries": [["name": "maps", "tier": "official"]]],
        ])
        let kept = KeptCapabilityAnswers()
        let dashboardKept = KeptCapabilityAnswers()
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        XCTAssertTrue(store.showsKept.isEmpty, "Nothing kept yet")
        await store.loadOfficialSkills()
        await store.loadToolCalls()
        await store.loadConnectors()
        await store.loadPlugins()

        XCTAssertEqual(kept.saved[CapabilitiesStore.KeptRoute.toolCalls]?.keys.sorted(), ["tools"], "The year's counts alone")
        let keptServer = try XCTUnwrap((kept.saved[CapabilitiesStore.KeptRoute.servers]?["servers"] as? [[String: Any]])?.first)
        XCTAssertNil(keptServer["args"], "A command's arguments can hold a key")
        XCTAssertNil(keptServer["env"])
        let zap = ConnectorServer(name: "zap", transport: "http", url: "https://actions.example:8443/mcp/secret-1/sse?key=x", command: nil, auth: nil, enabled: true, plugin: nil)
        XCTAssertEqual(zap.keptCopy.url, "https://actions.example:8443", "So can an address's path and query")
        XCTAssertEqual(keptServer["sign_in"] as? String, "header", "Not under a name the kept answers take for a credential's")
        XCTAssertNotNil(dashboardKept.saved[CapabilitiesStore.KeptRoute.pluginCatalog], "The same for every profile")
        XCTAssertNil(kept.saved[CapabilitiesStore.KeptRoute.pluginCatalog])

        // The next visit opens on them before Hermes answers.
        let hermes = CapabilityMockRequester(responses: [:])
        let next = CapabilitiesStore()
        next.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        XCTAssertEqual(next.showsKept, [.officialSkills, .toolCalls, .connectors, .connectorCatalog, .plugins, .pluginCatalog])
        XCTAssertEqual(next.officialSkills.map(\.identifier), ["official/pdf"])
        XCTAssertEqual(next.toolCalls, ["terminal": 4])
        XCTAssertEqual(next.servers.map(\.name), ["linear"])
        XCTAssertEqual(next.servers.first?.auth, "header")
        XCTAssertEqual(next.servers.first?.args, [], "Hermes' answer brings them")
        XCTAssertEqual(next.connectorCatalog.first?.authType, "oauth")
        XCTAssertEqual(next.plugins.map(\.name), ["Weather"])
        XCTAssertEqual(next.pluginCatalog.map(\.name), ["maps"])
        XCTAssertTrue(hermes.calls.isEmpty)

        // Offline too, with no bridge, on the default profile.
        let offline = CapabilitiesStore()
        offline.configure(requester: nil, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        XCTAssertEqual(offline.showsKept, [.officialSkills, .toolCalls, .connectors, .connectorCatalog, .plugins, .pluginCatalog])
        XCTAssertEqual(offline.servers.map(\.name), ["linear"])

        await next.loadConnectors()
        XCTAssertNotNil(next.connectorsError)
        XCTAssertEqual(next.servers.map(\.name), ["linear"], "A read that fails keeps them up")
        XCTAssertTrue(next.showsKept.contains(.connectors))
        await next.probeServers()
        XCTAssertFalse(hermes.calls.contains { $0.path.contains("/test") }, "Kept servers are tested only once Hermes lists them")

        hermes.responses = requester.responses
        hermes.responses["/api/mcp/servers"] = ["servers": [["name": "github", "transport": "http", "url": "https://g", "enabled": true]]]
        await next.loadConnectors()
        XCTAssertEqual(next.servers.map(\.name), ["github"], "Hermes' answer takes their place")
        XCTAssertFalse(next.showsKept.contains(.connectors))

        // A switch flipped on a kept list is kept, and the list read again.
        let third = CapabilitiesStore()
        third.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        hermes.responses["/api/mcp/servers"] = ["servers": [["name": "github", "transport": "http", "url": "https://g", "enabled": false]]]
        hermes.responses["/api/mcp/servers/github/enabled"] = ["ok": true]
        hermes.calls.removeAll()
        try await third.setServerEnabled("github", enabled: false)
        XCTAssertEqual(kept.written, [CapabilitiesStore.KeptRoute.servers])
        XCTAssertTrue(hermes.calls.contains { $0.path == "/api/mcp/servers" && $0.method == "GET" }, "The kept list asks again")
        XCTAssertEqual(third.servers.first?.enabled, false)
        XCTAssertFalse(third.showsKept.contains(.connectors))

        // A plugin's switch on the rows Hermes gave is kept as Hermes took
        // it, with no read again.
        await third.loadPlugins()
        hermes.responses["/api/dashboard/agent-plugins/Weather/enable"] = ["ok": true]
        hermes.calls.removeAll()
        try await third.setPluginEnabled(third.plugins[0], enabled: true)
        let keptPlugins = kept.saved[CapabilitiesStore.KeptRoute.plugins]?["plugins"] as? [[String: Any]]
        XCTAssertEqual(keptPlugins?.first?["runtime_status"] as? String, "enabled")
        XCTAssertEqual(kept.written.last, CapabilitiesStore.KeptRoute.plugins)
        XCTAssertEqual(hermes.calls.map(\.method), ["POST"])

        // With nothing kept to change, the switch still counts as a write,
        // so a read asked before it isn't kept after it.
        kept.forget(CapabilitiesStore.KeptRoute.plugins)
        hermes.responses["/api/dashboard/agent-plugins/Weather/disable"] = ["ok": true]
        try await third.setPluginEnabled(third.plugins[0], enabled: false)
        XCTAssertNil(kept.saved[CapabilitiesStore.KeptRoute.plugins])
        XCTAssertEqual(kept.noted, [CapabilitiesStore.KeptRoute.plugins])

        // A removal Hermes took is kept, so a read after it that fails
        // doesn't bring the plugin back.
        await third.loadPlugins()
        XCTAssertEqual((kept.saved[CapabilitiesStore.KeptRoute.plugins]?["plugins"] as? [Any])?.count, 1)
        hermes.responses["/api/dashboard/plugins/hub"] = nil
        hermes.responses["/api/dashboard/agent-plugins/Weather"] = ["ok": true]
        try await third.removePlugin(third.plugins[0])
        XCTAssertEqual((kept.saved[CapabilitiesStore.KeptRoute.plugins]?["plugins"] as? [Any])?.count, 0)

        // A connector install counts as a write to the servers, so a read
        // asked before it isn't kept after it, and marks the kept catalog's
        // entry installed, so when the reads after it fail, the catalog
        // doesn't offer it again next time.
        let notion = try XCTUnwrap(third.connectorCatalog.first { $0.name == "notion" })
        hermes.responses["/api/mcp/catalog/install"] = ["ok": true]
        hermes.responses["/api/mcp/servers"] = nil
        hermes.responses["/api/mcp/catalog"] = nil
        let installed = await third.installConnector(notion, env: [:])
        XCTAssertTrue(installed)
        XCTAssertEqual(kept.noted.last, CapabilitiesStore.KeptRoute.servers)
        XCTAssertEqual(kept.written.last, CapabilitiesStore.KeptRoute.connectorCatalog)
        let reopened = CapabilitiesStore()
        reopened.configure(requester: nil, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        XCTAssertEqual(reopened.connectorCatalog.first { $0.name == "notion" }?.installed, true)
    }

    /// A kept list reads again after a switch Hermes refused, and its
    /// servers are tested once Hermes lists them, after a connector install
    /// or a server's edit too; a plugin update counts as a write, as an
    /// install does.
    func testChangesOnKeptListsReadThemAgain() async throws {
        let github: [String: Any] = ["name": "github", "transport": "http", "url": "https://g", "enabled": true]
        let hermes = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["servers": [github]],
            "/api/mcp/catalog": ["entries": [["name": "notion", "auth_type": "oauth"]]],
            "/api/dashboard/plugins/hub": ["plugins": [["name": "Weather", "source": "git", "runtime_status": "disabled"]]],
        ])
        let kept = KeptCapabilityAnswers()
        let dashboardKept = KeptCapabilityAnswers()
        let first = CapabilitiesStore()
        first.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        await first.loadConnectors()
        await first.loadPlugins()

        let store = CapabilitiesStore()
        store.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        XCTAssertEqual(store.showsKept, [.connectors, .connectorCatalog, .plugins], "No plugin catalog was kept")
        hermes.calls.removeAll()
        do {
            try await store.setPluginEnabled(store.plugins[0], enabled: true)
            XCTFail("Hermes refused the switch")
        } catch {}
        XCTAssertTrue(hermes.calls.contains { $0.path == "/api/dashboard/plugins/hub" && $0.method == "GET" }, "The kept plugins ask again")
        XCTAssertFalse(store.showsKept.contains(.plugins))

        hermes.calls.removeAll()
        do {
            try await store.setServerEnabled("github", enabled: false)
            XCTFail("Hermes refused the switch")
        } catch {}
        XCTAssertTrue(hermes.calls.contains { $0.path == "/api/mcp/servers" && $0.method == "GET" }, "The kept servers ask again")
        XCTAssertTrue(hermes.calls.contains { $0.path == "/api/mcp/servers/github/test" && $0.method == "POST" }, "and are tested once Hermes lists them")
        XCTAssertEqual(store.servers.first?.enabled, true)

        let other = CapabilitiesStore()
        other.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        XCTAssertTrue(other.showsKept.contains(.connectors))
        let notion = try XCTUnwrap(other.connectorCatalog.first { $0.name == "notion" })
        hermes.responses["/api/mcp/catalog/install"] = ["ok": true]
        hermes.responses["/api/mcp/servers"] = ["servers": [github, ["name": "notion", "transport": "http", "url": "https://n", "enabled": true]]]
        hermes.calls.removeAll()
        let installed = await other.installConnector(notion, env: [:])
        XCTAssertTrue(installed)
        XCTAssertEqual(
            hermes.calls.filter { $0.path.hasSuffix("/test") }.map(\.path).sorted(),
            ["/api/mcp/servers/github/test", "/api/mcp/servers/notion/test"],
            "Every server Hermes listed is tested, once"
        )

        hermes.responses["/api/dashboard/plugins/hub"] = nil
        hermes.responses["/api/dashboard/agent-plugins/Weather/update"] = ["ok": true]
        let outcome = try await store.updatePlugin(store.plugins[0])
        XCTAssertEqual(outcome, .updated(restartRequired: true))
        XCTAssertEqual(kept.noted.last, CapabilitiesStore.KeptRoute.plugins, "A read asked before the update isn't kept after it")

        let edited = CapabilitiesStore()
        edited.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        XCTAssertTrue(edited.showsKept.contains(.connectors))
        hermes.responses["/api/config"] = ["mcp_servers": ["github": ["url": "https://g"], "notion": ["url": "https://n"]]]
        hermes.calls.removeAll()
        try await edited.saveServer(original: "github", loaded: ["url": "https://g"], name: "github", entry: ["url": "https://g2"], openedOn: edited.generation)
        let tests = { hermes.calls.filter { $0.path.hasSuffix("/test") }.map(\.path).sorted() }
        let deadline = ContinuousClock.now + .seconds(10)
        while tests().count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(tests(), ["/api/mcp/servers/github/test", "/api/mcp/servers/notion/test"], "After an edit too, in the background")
    }

    /// A plugin's removal, update or install Hermes took is kept in the
    /// plugin catalog too (#1533): the catalog hides an installed entry, so
    /// a removal whose read fails offers the plugin again, now and next time.
    func testPluginChangesKeepTheCatalogsFlags() async throws {
        let hermes = CapabilityMockRequester(responses: [
            "/api/dashboard/plugins/hub": ["plugins": [
                ["name": "Weather", "source": "git", "runtime_status": "enabled"],
                ["name": "Maps", "source": "git", "runtime_status": "enabled"],
            ]],
            "/api/dashboard/plugins/catalog": ["entries": [
                ["name": "Weather", "installed": true],
                ["name": "Maps", "installed": true, "update_available": true],
                ["name": "Notes", "installed": false],
            ]],
        ])
        let kept = KeptCapabilityAnswers()
        let dashboardKept = KeptCapabilityAnswers()
        let store = CapabilitiesStore()
        store.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        await store.loadPlugins()
        let weather = try XCTUnwrap(store.plugins.first { $0.name == "Weather" })
        let maps = try XCTUnwrap(store.plugins.first { $0.name == "Maps" })
        let notes = try XCTUnwrap(store.pluginCatalog.first { $0.name == "Notes" })

        // Hermes takes each change, and every read after it fails.
        hermes.responses["/api/dashboard/plugins/hub"] = nil
        hermes.responses["/api/dashboard/plugins/catalog"] = nil
        hermes.responses["/api/dashboard/agent-plugins/Weather"] = ["ok": true]
        try await store.removePlugin(weather)
        XCTAssertEqual(
            CapabilityPluginFilter.catalog(store.pluginCatalog, query: "").map(\.name), ["Notes", "Weather"],
            "The removed plugin is offered again at once"
        )
        hermes.responses["/api/dashboard/agent-plugins/Maps/update"] = ["ok": true]
        _ = try await store.updatePlugin(maps)
        XCTAssertEqual(store.pluginCatalog.first { $0.name == "Maps" }?.updateAvailable, false)
        hermes.responses["/api/dashboard/agent-plugins/install"] = ["plugin_name": "Notes"]
        _ = try await store.installPlugin(notes)
        XCTAssertEqual(
            store.pluginCatalog.first { $0.name == "Notes" }?.installed, false,
            "The catalog shown keeps an installed entry until Hermes' answer brings its row"
        )
        XCTAssertEqual(dashboardKept.written.filter { $0 == CapabilitiesStore.KeptRoute.pluginCatalog }.count, 3)

        let next = CapabilitiesStore()
        next.configure(requester: nil, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        XCTAssertEqual(next.plugins.map(\.name), ["Maps"])
        XCTAssertEqual(
            CapabilityPluginFilter.catalog(next.pluginCatalog, query: "").map(\.name), ["Weather"],
            "Next time the removed plugin is offered and the installed one isn't"
        )
        XCTAssertEqual(next.pluginCatalog.first { $0.name == "Maps" }?.updateAvailable, false)
    }

    /// A catalog shown from its kept copy asks again when its tab next
    /// shows if its read fails while the list's answers, until a read of it
    /// answers (#1533).
    func testAKeptCatalogWhoseReadFailsAsksAgain() async {
        let hermes = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["servers": [["name": "github", "transport": "http", "url": "https://g", "enabled": true]]],
            "/api/mcp/catalog": ["entries": [["name": "notion", "auth_type": "oauth"]]],
            "/api/dashboard/plugins/hub": ["plugins": [["name": "Weather", "source": "git", "runtime_status": "enabled"]]],
            "/api/dashboard/plugins/catalog": ["entries": [["name": "Maps", "installed": false]]],
        ])
        let kept = KeptCapabilityAnswers()
        let dashboardKept = KeptCapabilityAnswers()
        let first = CapabilitiesStore()
        first.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        await first.loadConnectors()
        await first.loadPlugins()

        hermes.failures["/api/mcp/catalog"] = URLError(.timedOut)
        hermes.failures["/api/dashboard/plugins/catalog"] = URLError(.timedOut)
        let store = CapabilitiesStore()
        store.configure(requester: hermes, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        await store.loadConnectors()
        await store.loadPlugins()
        XCTAssertEqual(store.showsKept, [.connectorCatalog, .pluginCatalog], "The lists are Hermes' now, the catalogs still the kept ones")
        XCTAssertEqual(store.connectorCatalog.map(\.name), ["notion"])
        XCTAssertEqual(store.pluginCatalog.map(\.name), ["Maps"])

        hermes.failures = [:]
        await store.loadConnectors()
        await store.loadPlugins()
        XCTAssertTrue(store.showsKept.isEmpty, "Hermes' catalogs take the kept ones' place")
    }

    /// A change Hermes took while the profile or dashboard switched is kept
    /// for the one it was made on, never the one switched to, so that
    /// profile opens on it next time, offline too (#1533).
    func testAChangeLandingAfterASwitchIsKeptForItsOwnProfile() async throws {
        let hermes = CapabilityMockRequester(responses: [
            "/api/mcp/servers": ["servers": [
                ["name": "github", "transport": "http", "url": "https://g", "enabled": true],
                ["name": "linear", "transport": "http", "url": "https://l", "enabled": true],
            ]],
            "/api/mcp/catalog": ["entries": [["name": "github", "installed": true]]],
            "/api/dashboard/plugins/hub": ["plugins": [["name": "Weather", "source": "git", "runtime_status": "disabled"]]],
            "/api/dashboard/plugins/catalog": ["entries": [["name": "Weather", "installed": true]]],
            "/api/mcp/servers/github": ["ok": true],
            "/api/mcp/servers/linear/enabled": ["ok": true],
            "/api/dashboard/agent-plugins/Weather": ["ok": true],
        ])
        let kept = KeptCapabilityAnswers()
        let dashboardKept = KeptCapabilityAnswers()
        let work = CapabilityMockRequester(responses: [:])
        let elsewhere = KeptCapabilityAnswers()
        let store = CapabilitiesStore()
        func open(_ requester: CapabilityMockRequester?) {
            store.configure(requester: requester, profile: "default", answers: kept.answers, dashboardAnswers: dashboardKept.answers)
        }
        // Hermes answers the change once the store has switched away.
        func switching(at route: String) {
            open(hermes)
            hermes.beforeAnswering = { path in
                guard path == route else { return }
                store.configure(requester: work, profile: "work", answers: elsewhere.answers, dashboardAnswers: elsewhere.answers)
            }
        }
        open(hermes)
        await store.loadConnectors()
        await store.loadPlugins()

        switching(at: "/api/mcp/servers/github")
        try await store.removeServer("github")
        switching(at: "/api/mcp/servers/linear/enabled")
        try await store.setServerEnabled("linear", enabled: false)
        switching(at: "/api/dashboard/agent-plugins/Weather")
        try await store.removePlugin(store.plugins[0])
        XCTAssertEqual(store.profile, "work")
        XCTAssertTrue(store.servers.isEmpty && store.plugins.isEmpty, "The profile switched to shows none of it")
        XCTAssertTrue(elsewhere.saved.isEmpty && elsewhere.written.isEmpty && elsewhere.noted.isEmpty, "nor keeps any")
        XCTAssertTrue(work.calls.isEmpty)

        hermes.beforeAnswering = nil
        open(nil)
        XCTAssertEqual(store.servers.map(\.name), ["linear"])
        XCTAssertEqual(store.servers.first?.enabled, false)
        XCTAssertEqual(store.connectorCatalog.first?.installed, false)
        XCTAssertTrue(store.plugins.isEmpty)
        XCTAssertEqual(store.pluginCatalog.first?.installed, false)
    }

    /// A skill's page, a catalog skill's and a toolset's open on what they
    /// showed last time on the dashboard and profile, each page's of many,
    /// and a read that fails leaves it kept (#1533).
    func testEachCapabilityPageOpensOnWhatItShowedLastTime() async throws {
        let hermes = CapabilityMockRequester(responses: [
            "/api/skills/content": ["content": "---\nname: pdf\n---\nRead PDFs."],
            "/api/skills/hub/preview": ["skill_md": "---\nname: maps\n---\nDraw maps."],
            "/api/tools/toolsets/web/config": ["has_category": true, "providers": [[
                "name": "Firecrawl", "is_active": true, "status": "needs_keys",
                "env_vars": [["key": "FIRECRAWL_API_KEY", "prompt": "Firecrawl key", "is_set": false]],
            ]]],
            "/api/tools/terminal/backends": ["backends": [["name": "docker", "label": "Docker", "active": true, "status": "ready"]]],
        ])
        let kept = KeptCapabilityAnswers()
        let store = CapabilitiesStore()
        store.configure(requester: hermes, profile: "default", answers: kept.answers)
        _ = try await store.skillContent(name: "pdf")
        _ = try await store.skillPreview(identifier: "official/maps")
        _ = try await store.toolsetConfig(name: "web")
        _ = try await store.terminalBackends()

        XCTAssertEqual(Set(kept.saved.keys), [
            CapabilitiesStore.KeptRoute.page("/api/skills/content?name=pdf"),
            CapabilitiesStore.KeptRoute.page("/api/skills/hub/preview?identifier=official%2Fmaps"),
            CapabilitiesStore.KeptRoute.page("/api/tools/toolsets/web/config"),
            CapabilitiesStore.KeptRoute.terminalBackends,
        ])

        // The next visit opens on them before Hermes answers.
        let offline = CapabilityMockRequester(responses: [:])
        offline.failures = [
            "/api/skills/content": URLError(.notConnectedToInternet),
            "/api/tools/toolsets/web/config": URLError(.notConnectedToInternet),
        ]
        let next = CapabilitiesStore()
        next.configure(requester: offline, profile: "default", answers: kept.answers)
        XCTAssertEqual(next.keptSkillContent(name: "pdf").map(SkillFrontmatter.parse)?.body, "Read PDFs.")
        XCTAssertNil(next.keptSkillContent(name: "docx"), "Another skill's page")
        XCTAssertEqual(next.keptSkillPreview(identifier: "official/maps").map(SkillFrontmatter.parse)?.body, "Draw maps.")
        let config = try XCTUnwrap(next.keptToolsetConfig(name: "web"))
        XCTAssertEqual(config.providers.map(\.name), ["Firecrawl"])
        XCTAssertEqual(config.providers.first?.envVars.map(\.key), ["FIRECRAWL_API_KEY"])
        XCTAssertEqual(next.keptTerminalBackends()?.map(\.name), ["docker"])
        XCTAssertTrue(offline.calls.isEmpty)

        _ = try? await next.skillContent(name: "pdf")
        _ = try? await next.toolsetConfig(name: "web")
        XCTAssertNotNil(next.keptSkillContent(name: "pdf"), "A read that fails leaves it kept")
        XCTAssertNotNil(next.keptToolsetConfig(name: "web"))
    }

    /// A backend, terminal or key change Hermes took changes the page's
    /// kept answer as Hermes now holds it, so the page shows the change
    /// next time and should the read after it fail. A change that fails,
    /// or one on a page with nothing kept, makes nothing up (#1533).
    func testAPageChangeHermesTookIsKeptAsHermesHoldsIt() async throws {
        let hermes = CapabilityMockRequester(responses: [
            "/api/tools/toolsets/web/config": [
                "has_category": true,
                "active_search_backend": "firecrawl",
                "active_extract_backend": "firecrawl",
                "search_via_nous": true,
                "extract_via_nous": true,
                "providers": [
                    ["name": "Nous Subscription", "managed_nous_feature": "web", "web_backend": "firecrawl", "status": "ready"],
                    [
                        "name": "Firecrawl", "web_backend": "firecrawl", "status": "needs_keys",
                        "env_vars": [["key": "FIRECRAWL_API_KEY", "prompt": "", "is_set": false]],
                    ],
                    [
                        "name": "Tavily", "web_backend": "tavily", "status": "needs_keys",
                        "env_vars": [["key": "TAVILY_API_KEY", "prompt": "", "is_set": false]],
                    ],
                ],
            ],
            "/api/tools/toolsets/image_gen/config": ["has_category": true, "active_provider": "FAL", "providers": [
                ["name": "FAL", "is_active": true, "status": "ready"],
                ["name": "OpenAI", "is_active": false, "status": "ready"],
            ]],
            "/api/tools/terminal/backends": ["backends": [
                ["name": "local", "label": "Local", "active": true, "status": "ready"],
                ["name": "docker", "label": "Docker", "active": false, "status": "ready"],
            ]],
            "/api/tools/toolsets/web/provider": ["needs_nous_auth": false],
            "/api/tools/toolsets/image_gen/provider": [:],
            "/api/tools/toolsets/tts/provider": [:],
            "/api/tools/terminal/backend": [:],
            "/api/env": [:],
        ])
        let kept = KeptCapabilityAnswers()
        let store = CapabilitiesStore()
        store.configure(requester: hermes, profile: "default", answers: kept.answers)
        let shownWeb = try await store.toolsetConfig(name: "web")
        let shownImage = try await store.toolsetConfig(name: "image_gen")
        let shownBackends = try await store.terminalBackends()

        _ = try await store.selectProvider(toolset: "image_gen", provider: "OpenAI")
        _ = try await store.selectProvider(toolset: "web", provider: "Tavily", capability: "search")
        _ = try await store.selectProvider(toolset: "web", provider: "Firecrawl", capability: "extract")
        try await store.selectTerminalBackend("docker")
        try await store.saveKey("FIRECRAWL_API_KEY", value: "typed-key", toolset: "web")

        let image = try XCTUnwrap(store.keptToolsetConfig(name: "image_gen"))
        XCTAssertEqual(image.activeProvider, "OpenAI")
        XCTAssertEqual(image.providers.filter(\.isActive).map(\.name), ["OpenAI"])
        let web = try XCTUnwrap(store.keptToolsetConfig(name: "web"))
        let nous = try XCTUnwrap(web.providers.first { $0.name == "Nous Subscription" })
        let firecrawl = try XCTUnwrap(web.providers.first { $0.name == "Firecrawl" })
        let tavily = try XCTUnwrap(web.providers.first { $0.name == "Tavily" })
        XCTAssertTrue(web.serves("search", provider: tavily))
        XCTAssertFalse(web.serves("search", provider: nous))
        XCTAssertTrue(web.serves("extract", provider: firecrawl), "Its own key, not managed Nous on the same backend")
        XCTAssertFalse(web.serves("extract", provider: nous))
        XCTAssertEqual(firecrawl.envVars.map(\.isSet), [true])
        XCTAssertEqual(tavily.envVars.map(\.isSet), [false])
        XCTAssertEqual(store.keptTerminalBackends()?.filter(\.active).map(\.name), ["docker"])
        XCTAssertEqual(Set(kept.written), [
            CapabilitiesStore.KeptRoute.page("/api/tools/toolsets/image_gen/config"),
            CapabilitiesStore.KeptRoute.page("/api/tools/toolsets/web/config"),
            CapabilitiesStore.KeptRoute.terminalBackends,
        ])
        XCTAssertFalse(String(describing: kept.saved).contains("typed-key"), "Never the key itself")
        // The page shows each change itself, as the kept answer holds it,
        // so it shows on a page with nothing kept too.
        XCTAssertEqual(shownImage.choosing("OpenAI", capability: nil), image)
        XCTAssertEqual(
            shownWeb.choosing("Tavily", capability: "search").choosing("Firecrawl", capability: "extract")
                .settingKey("FIRECRAWL_API_KEY"),
            web
        )
        XCTAssertEqual(TerminalBackendOption.choosing("docker", in: shownBackends), store.keptTerminalBackends())

        // A change that fails keeps nothing.
        hermes.failures["PUT /api/tools/terminal/backend"] = URLError(.notConnectedToInternet)
        try? await store.selectTerminalBackend("local")
        XCTAssertEqual(store.keptTerminalBackends()?.filter(\.active).map(\.name), ["docker"])

        // A page with nothing kept isn't made up, only noted for its next read.
        _ = try await store.selectProvider(toolset: "tts", provider: "Edge")
        XCTAssertNil(store.keptToolsetConfig(name: "tts"))
        XCTAssertEqual(kept.noted, [CapabilitiesStore.KeptRoute.page("/api/tools/toolsets/tts/config")])
    }

    /// A plugins read cut off by leaving the tab says nothing failed, and
    /// the tab asks again when it next shows.
    func testACancelledPluginsReadIsNoFailure() async {
        let hermes = CapabilityMockRequester(responses: ["/api/dashboard/plugins/catalog": ["entries": [[String: Any]]()]])
        hermes.failures["/api/dashboard/plugins/hub"] = CancellationError()
        let store = CapabilitiesStore()
        store.configure(requester: hermes, profile: "default")

        await store.loadPlugins()

        XCTAssertNil(store.pluginsError)
        XCTAssertFalse(store.pluginsLoaded)
    }
}

@MainActor
private final class CapabilityMockRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        var body: [String: Any]? = nil
    }

    var responses: [String: [String: Any]]
    /// Paths ("/api/x", or "PUT /api/x" for one method) that fail with
    /// this error instead of answering.
    var failures: [String: Error] = [:]
    var calls: [Call] = []
    /// Runs before each answer, which is read when the request is made: a
    /// test can hold a request here.
    var beforeAnswering: (@MainActor (_ path: String) async -> Void)?

    init(responses: [String: [String: Any]]) {
        self.responses = responses
    }

    func requestJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        timeoutMilliseconds: Int,
        maxResponseBytes: Int
    ) async throws -> [String: Any] {
        calls.append(Call(path: path, method: method, body: body))
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let response = responses[bare]
        await beforeAnswering?(bare)
        // As the dashboard bridge does: a cancelled caller gets no answer.
        try Task.checkCancellation()
        if let failure = failures["\(method) \(bare)"] ?? failures[bare] { throw failure }
        guard let response else {
            throw URLError(.fileDoesNotExist)
        }
        return response
    }
}

/// A page's answers kept on the phone, as AppState keeps them, and the
/// routes a change made there kept.
@MainActor
private final class KeptCapabilityAnswers {
    private(set) var saved: [String: [String: Any]] = [:]
    private(set) var written: [String] = []
    /// Routes a change wrote to with nothing kept for them.
    private(set) var noted: [String] = []

    var answers: KeptAnswers {
        KeptAnswers(
            kept: { route in self.saved[route] },
            keep: { route, writes, read in
                let answer = try await read()
                self.saved[route] = answer
                if writes { self.written.append(route) }
                return answer
            },
            noteWrite: { route in self.noted.append(route) }
        )
    }

    func forget(_ route: String) {
        saved[route] = nil
    }
}
