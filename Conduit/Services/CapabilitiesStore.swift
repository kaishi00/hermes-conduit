//
//  CapabilitiesStore.swift
//  Conduit
//
//  Settings > Capabilities beyond the installed skills and toolsets that
//  AppState already loads: the official skills catalog and its installs,
//  tool call counts, a toolset's backends and keys, MCP servers (Connectors)
//  and agent plugins. One store per Capabilities page, scoped to the active
//  profile; a profile or dashboard switch drops everything it had read, and
//  a request that lands after the switch commits nothing.
//

import Foundation
import Observation

enum CapabilitiesStoreError: LocalizedError, Equatable {
    case notConnected
    case timedOut
    case declined(String)
    /// A Hermes without `PUT /api/mcp/servers`, which edits servers.
    case editUnsupported

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return AppLocalization.string("Connect to a Hermes dashboard to load capabilities.")
        case .timedOut:
            return AppLocalization.string("Hermes is still working on it. Check again in a moment.")
        case .declined(let reason):
            return reason
        case .editUnsupported:
            return AppLocalization.string("This Hermes can't change servers yet. Update Hermes and try again.")
        }
    }
}

/// How a plugin update went.
enum PluginUpdateOutcome: Equatable {
    case updated(restartRequired: Bool)
    case upToDate
    /// The new catalog pin asks for more than the installed one; nothing
    /// changed until the person accepts these lines.
    case needsConsent(lines: [String])
}

/// What a plugin install left to do.
struct PluginInstallOutcome: Equatable {
    var name: String
    var missingEnv: [String]
    var restartRequired: Bool
}

@MainActor
@Observable
final class CapabilitiesStore {
    // Skills
    private(set) var officialSkills: [OfficialSkill] = []
    private(set) var skillInstalls: [String: CapabilityInstallState] = [:]

    // Tools
    /// Tool name -> calls over the last year; nil until read.
    private(set) var toolCalls: [String: Int]?

    // Connectors
    private(set) var servers: [ConnectorServer] = []
    private(set) var connectorCatalog: [ConnectorCatalogEntry] = []
    private(set) var connectorsLoaded = false
    private(set) var connectorsError: String?
    private(set) var probes: [String: ConnectorProbe] = [:]
    private(set) var probing: Set<String> = []
    private(set) var connectorInstalls: [String: CapabilityInstallState] = [:]

    // Plugins
    private(set) var plugins: [AgentPluginRow] = []
    private(set) var pluginCatalog: [PluginCatalogEntry] = []
    private(set) var pluginsLoaded = false
    private(set) var pluginsError: String?
    private(set) var pluginBusy: Set<String> = []
    /// A plugin change Hermes applies only after a gateway restart.
    var pluginsNeedRestart = false

    @ObservationIgnored private weak var requester: (any DashboardJSONRequester)?
    private(set) var profile = "default"
    /// Bumped on every profile or dashboard switch: work started before it
    /// commits nothing.
    @ObservationIgnored private var generation = 0
    /// Bumped by every load of a list and every change made to it here: a
    /// load commits only if nothing newer touched its list meanwhile, so a
    /// refresh that answers late can't bring back an older list or undo a
    /// switch just flipped.
    @ObservationIgnored private var skillsEpoch = 0
    @ObservationIgnored private var connectorsEpoch = 0
    @ObservationIgnored private var pluginsEpoch = 0

    /// A connector's probe stays fresh this long, as on Desktop.
    static let probeLifetime: TimeInterval = 300
    static let actionPollInterval: Duration = .milliseconds(1_200)

    func configure(requester: (any DashboardJSONRequester)?, profile: String) {
        guard !Self.same(requester, self.requester) || profile != self.profile else { return }
        self.requester = requester
        self.profile = profile
        generation &+= 1
        officialSkills = []
        skillInstalls = [:]
        toolCalls = nil
        servers = []
        connectorCatalog = []
        connectorsLoaded = false
        connectorsError = nil
        probes = [:]
        probing = []
        connectorInstalls = [:]
        plugins = []
        pluginCatalog = []
        pluginsLoaded = false
        pluginsError = nil
        pluginBusy = []
        pluginsNeedRestart = false
    }

    /// Whether requests go to `owner`'s bridge and profile. False after a
    /// switch until the Capabilities screen points the store at them, so a
    /// detail page never reads the previous dashboard or profile.
    func serves(_ owner: CapabilitySnapshotOwner) -> Bool {
        requester.map { ObjectIdentifier($0) } == owner.bridge && profile == owner.profile
    }

    private static func same(_ lhs: (any DashboardJSONRequester)?, _ rhs: (any DashboardJSONRequester)?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
        default: return false
        }
    }

    // MARK: Requests

    private func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: Int = 12_000
    ) async throws -> [String: Any] {
        // A backend, connector or install change makes Hermes rewrite the
        // profile config: in turn with every other config save.
        guard Self.writesProfileConfig(method: method, path: path) else {
            return try await unqueuedRequest(path, method: method, body: body, timeout: timeout)
        }
        return try await ProfileConfigWriteQueue.runThrowing {
            try await self.unqueuedRequest(path, method: method, body: body, timeout: timeout)
        }
    }

    /// A request that doesn't wait for config saves: for reads, and for a
    /// read and write already running in the queue together.
    private func unqueuedRequest(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: Int = 12_000
    ) async throws -> [String: Any] {
        guard let requester else { throw CapabilitiesStoreError.notConnected }
        return try await requester.requestJSON(
            path: path,
            method: method,
            body: body,
            timeoutMilliseconds: timeout,
            maxResponseBytes: DataURLLimits.maxJSONResponseBytes
        )
    }

    /// Writes Hermes keeps in the profile config. Keys (`/api/env`),
    /// connector tests, sign-ins and reads don't wait for config saves.
    static func writesProfileConfig(method: String, path: String) -> Bool {
        guard method != "GET" else { return false }
        let route = path.split(separator: "?").first.map(String.init) ?? path
        if route.hasSuffix("/test") || route.hasSuffix("/auth") { return false }
        return !route.hasPrefix("/api/env") && !route.hasPrefix("/api/mcp/oauth/")
    }

    private func scoped(_ path: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    private func scopedBody(_ body: [String: Any]) -> [String: Any] {
        DashboardPath.bodyWithProfile(body, profile: profile)
    }

    /// One path segment or query value, percent-encoded.
    static func component(_ value: String) -> String {
        DashboardPath.encodedQueryComponent(value) ?? value
    }

    /// A plugin key may hold `/` (Hermes' routes take it as a path), so each
    /// segment is encoded on its own.
    static func pluginPath(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: true).map { component(String($0)) }.joined(separator: "/")
    }

    /// Polls a background action until it stops. A few failed polls in a row
    /// (the dashboard busy installing) are retried; a profile switch ends it.
    private func waitForAction(_ name: String, token: Int, limit: TimeInterval = 900) async throws -> HermesActionStatus {
        let deadline = Date().addingTimeInterval(limit)
        var failures = 0
        while true {
            try await Task.sleep(for: Self.actionPollInterval)
            guard token == generation else { throw CancellationError() }
            do {
                let status = HermesActionStatus(try await request("/api/actions/\(Self.component(name))/status?lines=200"))
                failures = 0
                if !status.running { return status }
            } catch {
                failures += 1
                if failures >= 4 { throw error }
            }
            if Date() > deadline { throw CapabilitiesStoreError.timedOut }
        }
    }

    // MARK: Skills

    func loadOfficialSkills() async {
        let token = generation
        skillsEpoch &+= 1
        let epoch = skillsEpoch
        guard let response = try? await request(scoped("/api/skills/hub/official"), timeout: 30_000) else { return }
        guard token == generation, epoch == skillsEpoch else { return }
        officialSkills = (response["skills"] as? [Any] ?? []).compactMap { OfficialSkill($0) }
    }

    /// A skill's SKILL.md, frontmatter included.
    func skillContent(name: String) async throws -> String {
        let response = try await request(scoped("/api/skills/content?name=\(Self.component(name))"))
        return response["content"] as? String ?? ""
    }

    /// A catalog skill's SKILL.md before it's installed.
    func skillPreview(identifier: String) async throws -> String {
        let response = try await request(
            scoped("/api/skills/hub/preview?identifier=\(Self.component(identifier))"),
            timeout: 45_000
        )
        return response["skill_md"] as? String ?? ""
    }

    /// Installs a catalog skill (Hermes runs `hermes skills install` in the
    /// background) and waits for it. True once it's installed.
    @discardableResult
    func installSkill(_ skill: OfficialSkill) async -> Bool {
        let token = generation
        skillInstalls[skill.identifier] = .running
        do {
            let started = try await request(
                scoped("/api/skills/hub/install"),
                method: "POST",
                body: scopedBody(["identifier": skill.identifier]),
                timeout: 45_000
            )
            guard let action = started["name"] as? String else {
                throw CapabilitiesStoreError.declined(AppLocalization.string("Hermes didn't start the install."))
            }
            let status = try await waitForAction(action, token: token)
            guard token == generation else { return false }
            guard status.succeeded else {
                skillInstalls[skill.identifier] = .failed(status.failureReason ?? AppLocalization.string("The install didn't finish."))
                return false
            }
            skillInstalls[skill.identifier] = nil
            if let index = officialSkills.firstIndex(where: { $0.identifier == skill.identifier }) {
                skillsEpoch &+= 1
                officialSkills[index].installed = true
            }
            return true
        } catch {
            guard token == generation, !(error is CancellationError) else { return false }
            skillInstalls[skill.identifier] = .failed(UserFacingError.message(for: error))
            return false
        }
    }

    // MARK: Tools

    /// Per-tool calls over a year, which orders the Tools list. A failed
    /// read keeps the counts already read (none at first, so the list falls
    /// back to A-Z and the next visit asks again).
    func loadToolCalls() async {
        let token = generation
        guard let response = try? await request(scoped("/api/analytics/usage?days=365"), timeout: 30_000),
              token == generation else { return }
        toolCalls = CapabilityToolsetOrdering.toolCallCounts(from: response)
    }

    func toolsetConfig(name: String) async throws -> ToolsetConfig {
        ToolsetConfig(try await request(scoped("/api/tools/toolsets/\(Self.component(name))/config"), timeout: 30_000))
    }

    /// Makes `provider` the toolset's backend (for the web toolset, for one
    /// capability). True when Hermes says it still needs a Nous sign-in.
    func selectProvider(toolset: String, provider: String, capability: String? = nil) async throws -> Bool {
        var body: [String: Any] = ["provider": provider]
        if let capability { body["capability"] = capability }
        let response = try await request(
            scoped("/api/tools/toolsets/\(Self.component(toolset))/provider"),
            method: "PUT",
            body: scopedBody(body)
        )
        return response["needs_nous_auth"] as? Bool ?? false
    }

    func terminalBackends() async throws -> [TerminalBackendOption] {
        TerminalBackendOption.list(from: try await request(scoped("/api/tools/terminal/backends"), timeout: 30_000))
    }

    func selectTerminalBackend(_ backend: String) async throws {
        _ = try await request(
            scoped("/api/tools/terminal/backend"),
            method: "PUT",
            body: scopedBody(["backend": backend])
        )
    }

    /// Saves an API key to the profile's `.env`. Conduit never reads keys back.
    func saveKey(_ key: String, value: String) async throws {
        _ = try await request(
            scoped("/api/env"),
            method: "PUT",
            body: scopedBody(["key": key, "value": value])
        )
    }

    // MARK: Connectors

    func loadConnectors() async {
        let token = generation
        connectorsEpoch &+= 1
        let epoch = connectorsEpoch
        async let serversResponse = request(scoped("/api/mcp/servers"), timeout: 30_000)
        async let catalogResponse = try? request(scoped("/api/mcp/catalog"), timeout: 30_000)
        do {
            let servers = ConnectorServer.list(from: try await serversResponse)
            let catalog = await catalogResponse.map(ConnectorCatalogEntry.list) ?? connectorCatalog
            guard token == generation, epoch == connectorsEpoch else { return }
            self.servers = servers
            connectorCatalog = catalog
            connectorsError = nil
            let names = Set(servers.map(\.name))
            probes = probes.filter { names.contains($0.key) }
        } catch {
            _ = await catalogResponse
            guard token == generation, epoch == connectorsEpoch else { return }
            connectorsError = UserFacingError.message(for: error)
        }
        connectorsLoaded = true
    }

    /// Tests every server that's on and hasn't been tested lately, a few at a
    /// time: each test starts the server on the host.
    func probeServers(force: Bool = false) async {
        let now = Date()
        let due = servers.filter { server in
            guard server.enabled, !probing.contains(server.name) else { return false }
            guard !force, let probe = probes[server.name] else { return true }
            return now.timeIntervalSince(probe.checkedAt) > Self.probeLifetime
        }
        var pending = due[...]
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                guard let next = pending.popFirst() else { break }
                group.addTask { await self.probe(next.name) }
            }
            while await group.next() != nil {
                // Leaving the list starts no more tests; the ones running
                // finish (see probe).
                if !Task.isCancelled, let next = pending.popFirst() {
                    group.addTask { await self.probe(next.name) }
                }
            }
        }
    }

    func probe(_ name: String) async {
        // Each test starts the server on the host: one at a time.
        guard !probing.contains(name) else { return }
        let token = generation
        probing.insert(name)
        // The test runs to its answer even when the page that asked goes
        // away (opening a server from the list cancels the list's tests):
        // the host already started the server, and an interrupted test
        // isn't the server failing (#1570).
        let path = scoped("/api/mcp/servers/\(Self.component(name))/test")
        let test = Task { ConnectorProbe(try await self.request(path, method: "POST", timeout: 60_000)) }
        let probe: ConnectorProbe?
        do {
            probe = try await test.value
        } catch is CancellationError {
            // Cancelled under the test (the dashboard went away): no result,
            // so it's tested again next time rather than shown as failed.
            probe = nil
        } catch {
            probe = ConnectorProbe(failure: UserFacingError.message(for: error))
        }
        guard token == generation else { return }
        probing.remove(name)
        if let probe { probes[name] = probe }
    }

    func setServerEnabled(_ name: String, enabled: Bool) async throws {
        let token = generation
        guard let index = servers.firstIndex(where: { $0.name == name }) else { return }
        connectorsEpoch &+= 1
        servers[index].enabled = enabled
        do {
            _ = try await request(
                scoped("/api/mcp/servers/\(Self.component(name))/enabled"),
                method: "PUT",
                body: scopedBody(["enabled": enabled])
            )
        } catch {
            if token == generation, let index = servers.firstIndex(where: { $0.name == name }) {
                connectorsEpoch &+= 1
                servers[index].enabled = !enabled
            }
            throw error
        }
        guard token == generation else { return }
        if enabled {
            await probe(name)
        } else {
            probes[name] = nil
        }
    }

    /// The profile's `mcp_servers` as written in config.yaml: defaults not
    /// merged and `${NAME}` references not expanded, so keys kept in .env
    /// show as their names.
    private func configuredServers() async throws -> [String: Any] {
        let config = try await unqueuedRequest(scoped("/api/config?include_defaults=false"), timeout: 30_000)
        return config["mcp_servers"] as? [String: Any] ?? [:]
    }

    /// One server's entry, to edit.
    func serverConfig(_ name: String) async throws -> [String: Any] {
        guard let entry = try await configuredServers()[name] as? [String: Any] else {
            throw ConnectorServerEdit.Problem.gone(name)
        }
        return entry
    }

    /// Saves an edited server, renamed or not. The map is read again and
    /// written back in one turn of the config queue, so a save elsewhere
    /// can't land between them and be undone. Hermes checks the entry and
    /// says what it refused.
    func saveServer(original: String, name: String, entry: [String: Any]) async throws {
        let token = generation
        try await ProfileConfigWriteQueue.runThrowing {
            guard token == self.generation else { throw CancellationError() }
            let servers = try ConnectorServerEdit.replacing(
                in: try await self.configuredServers(),
                original: original,
                name: name,
                entry: entry
            )
            do {
                _ = try await self.unqueuedRequest(
                    self.scoped("/api/mcp/servers"),
                    method: "PUT",
                    body: self.scopedBody(["servers": servers]),
                    timeout: 30_000
                )
            } catch DashboardTicketBridgeError.http(let status, _) where status == 404 || status == 405 {
                throw CapabilitiesStoreError.editUnsupported
            }
        }
        guard token == generation else { return }
        probes[original] = nil
        probes[name] = nil
        await loadConnectors()
        // Tested again in the background: the editor closes on the save.
        if servers.first(where: { $0.name == name })?.enabled == true {
            Task { await probe(name) }
        }
    }

    func removeServer(_ name: String) async throws {
        let token = generation
        _ = try await request(scoped("/api/mcp/servers/\(Self.component(name))"), method: "DELETE")
        guard token == generation else { return }
        connectorsEpoch &+= 1
        servers.removeAll { $0.name == name }
        probes[name] = nil
        if let index = connectorCatalog.firstIndex(where: { $0.name == name }) {
            connectorCatalog[index].installed = false
        }
    }

    /// Installs a catalog server with the keys it asks for; entries Hermes
    /// clones and builds run in the background and are waited on.
    @discardableResult
    func installConnector(_ entry: ConnectorCatalogEntry, env: [String: String]) async -> Bool {
        let token = generation
        connectorInstalls[entry.name] = .running
        do {
            let response = try await request(
                scoped("/api/mcp/catalog/install"),
                method: "POST",
                body: scopedBody(["name": entry.name, "env": env, "enable": true]),
                timeout: 60_000
            )
            if response["background"] as? Bool == true, let action = response["action"] as? String {
                let status = try await waitForAction(action, token: token)
                guard status.succeeded else {
                    guard token == generation else { return false }
                    connectorInstalls[entry.name] = .failed(status.failureReason ?? AppLocalization.string("The install didn't finish."))
                    return false
                }
            }
            guard token == generation else { return false }
            connectorInstalls[entry.name] = nil
            await loadConnectors()
            await probe(entry.name)
            return true
        } catch {
            guard token == generation, !(error is CancellationError) else { return false }
            connectorInstalls[entry.name] = .failed(UserFacingError.message(for: error))
            return false
        }
    }

    func clearConnectorInstallFailure(_ name: String) {
        if case .failed = connectorInstalls[name] { connectorInstalls[name] = nil }
    }

    /// Starts a server's OAuth sign-in; the person finishes it in the
    /// browser at the returned address.
    func startSignIn(_ name: String) async throws -> (flowID: String, url: URL) {
        let response = try await request(
            scoped("/api/mcp/servers/\(Self.component(name))/auth"),
            method: "POST",
            timeout: 45_000
        )
        if let error = response["error"] as? String, !error.isEmpty {
            throw CapabilitiesStoreError.declined(error)
        }
        guard let flowID = response["flow_id"] as? String,
              let address = response["authorization_url"] as? String,
              let url = URL(string: address) else {
            throw CapabilitiesStoreError.declined(AppLocalization.string("Hermes didn't return a sign-in page."))
        }
        return (flowID, url)
    }

    /// starting, authorization_required, approved or error.
    func signInStatus(_ flowID: String) async throws -> (status: String, error: String?) {
        let response = try await request("/api/mcp/oauth/flows/\(Self.component(flowID))")
        return (response["status"] as? String ?? "", (response["error"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    func cancelSignIn(_ flowID: String) async {
        _ = try? await request("/api/mcp/oauth/flows/\(Self.component(flowID))", method: "DELETE")
    }

    // MARK: Plugins

    func loadPlugins() async {
        let token = generation
        pluginsEpoch &+= 1
        let epoch = pluginsEpoch
        async let hubResponse = request(scoped("/api/dashboard/plugins/hub"), timeout: 30_000)
        async let catalogResponse = try? request("/api/dashboard/plugins/catalog", timeout: 30_000)
        do {
            let plugins = AgentPluginRow.list(from: try await hubResponse)
            let catalog = await catalogResponse.map(PluginCatalogEntry.list) ?? pluginCatalog
            guard token == generation, epoch == pluginsEpoch else { return }
            self.plugins = plugins
            pluginCatalog = catalog
            pluginsError = nil
        } catch {
            _ = await catalogResponse
            guard token == generation, epoch == pluginsEpoch else { return }
            pluginsError = UserFacingError.message(for: error)
        }
        pluginsLoaded = true
    }

    /// Hermes' plugin routes act on the dashboard's own (default) profile
    /// whatever profile asks, so other profiles only read.
    var canManagePlugins: Bool { profile == "default" }

    private func requirePluginProfile() throws {
        guard canManagePlugins else {
            throw CapabilitiesStoreError.declined(
                AppLocalization.string("Hermes installs plugins for the host's default profile. Switch to it to change them.")
            )
        }
    }

    /// Turns a plugin on or off. Turning one on loads it live when the
    /// gateway answers; turning one off always waits for a restart.
    func setPluginEnabled(_ plugin: AgentPluginRow, enabled: Bool) async throws {
        try requirePluginProfile()
        let token = generation
        pluginBusy.insert(plugin.name)
        defer { if token == generation { pluginBusy.remove(plugin.name) } }
        let response = try await request(
            "/api/dashboard/agent-plugins/\(Self.pluginPath(plugin.name))/\(enabled ? "enable" : "disable")",
            method: "POST",
            timeout: 60_000
        )
        guard token == generation else { return }
        if let index = plugins.firstIndex(where: { $0.name == plugin.name }) {
            pluginsEpoch &+= 1
            plugins[index].runtimeStatus = enabled ? "enabled" : "disabled"
        }
        if response["restart_required"] as? Bool == true {
            pluginsNeedRestart = true
        }
    }

    func updatePlugin(_ plugin: AgentPluginRow, acceptCapabilities: Bool = false) async throws -> PluginUpdateOutcome {
        try requirePluginProfile()
        let token = generation
        pluginBusy.insert(plugin.name)
        defer { if token == generation { pluginBusy.remove(plugin.name) } }
        let response = try await request(
            "/api/dashboard/agent-plugins/\(Self.pluginPath(plugin.folderName))/update",
            method: "POST",
            body: acceptCapabilities ? ["accept_capabilities": true] : [:],
            timeout: 180_000
        )
        if response["consent_required"] as? Bool == true {
            let lines = (response["delta_lines"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .needsConsent(lines: lines.isEmpty ? [response["error"] as? String ?? ""].filter { !$0.isEmpty } : lines)
        }
        // A profile or dashboard switch discards the answer.
        guard token == generation else { throw CancellationError() }
        if response["unchanged"] as? Bool == true {
            return .upToDate
        }
        // A git pull reports no activation: the gateway loads the new code on
        // its next start.
        let restart = response["restart_required"] as? Bool ?? true
        if restart { pluginsNeedRestart = true }
        await loadPlugins()
        return .updated(restartRequired: restart)
    }

    func removePlugin(_ plugin: AgentPluginRow) async throws {
        try requirePluginProfile()
        let token = generation
        pluginBusy.insert(plugin.name)
        defer { if token == generation { pluginBusy.remove(plugin.name) } }
        _ = try await request(
            "/api/dashboard/agent-plugins/\(Self.pluginPath(plugin.folderName))",
            method: "DELETE",
            timeout: 60_000
        )
        guard token == generation else { return }
        pluginsEpoch &+= 1
        plugins.removeAll { $0.name == plugin.name }
        // Hermes can't unload a plugin while the gateway runs.
        pluginsNeedRestart = true
        await loadPlugins()
    }

    func installPlugin(_ entry: PluginCatalogEntry) async throws -> PluginInstallOutcome {
        try requirePluginProfile()
        let token = generation
        pluginBusy.insert(entry.name)
        defer { if token == generation { pluginBusy.remove(entry.name) } }
        let response = try await request(
            "/api/dashboard/agent-plugins/install",
            method: "POST",
            body: ["identifier": "", "catalog_name": entry.name, "enable": true],
            timeout: 180_000
        )
        let missing = (response["missing_env"] as? [Any])?.compactMap { value -> String? in
            if let name = value as? String { return name }
            return (value as? [String: Any])?["name"] as? String
        } ?? []
        let restart = response["restart_required"] as? Bool ?? false
        let outcome = PluginInstallOutcome(
            name: response["plugin_name"] as? String ?? entry.displayName,
            missingEnv: missing,
            restartRequired: restart
        )
        guard token == generation else { return outcome }
        if restart { pluginsNeedRestart = true }
        await loadPlugins()
        return outcome
    }
}
