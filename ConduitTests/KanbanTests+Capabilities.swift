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
    }

    func testAFailedCapabilitySwitchGoesBackToWhatHermesLastConfirmed() async {
        // On and off both fail: Hermes still has it off.
        let harness = SwitchHarness(row: false)
        await harness.flip(true, fails: true)
        await harness.flip(false, fails: true)
        await harness.answerAll()

        XCTAssertFalse(harness.row)

        // On succeeds, off fails: Hermes has it on.
        let confirmed = SwitchHarness(row: false)
        await confirmed.flip(true, fails: false)
        await confirmed.flip(false, fails: true)
        await confirmed.answerAll()

        XCTAssertTrue(confirmed.row)
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
        await connectors.value

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
}

@MainActor
private final class CapabilityMockRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
    }

    var responses: [String: [String: Any]]
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
        calls.append(Call(path: path, method: method))
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let response = responses[bare]
        await beforeAnswering?(bare)
        guard let response else {
            throw URLError(.fileDoesNotExist)
        }
        return response
    }
}
