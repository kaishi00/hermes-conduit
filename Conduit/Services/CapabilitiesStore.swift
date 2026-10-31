//
//  CapabilitiesStore.swift
//  Conduit
//
//  Settings > Capabilities beyond the installed skills and toolsets that
//  AppState already loads: the official skills catalog and its installs,
//  tool call counts, a toolset's backends and keys, MCP servers (Connectors)
//  and agent plugins. One store per Capabilities page, scoped to the active
//  profile; a profile or dashboard switch drops everything it had read, and
//  a request that lands after the switch commits nothing. Each tab opens on
//  the lists it showed last time, kept on the phone, while it asks again
//  (#1533).
//

import Foundation
import Observation

enum CapabilitiesStoreError: LocalizedError, Equatable {
    case notConnected
    case timedOut
    case declined(String)
    /// A Hermes without `PUT /api/mcp/servers`, which edits servers.
    case editUnsupported
    /// Conduit moved to another profile or dashboard before a save was sent.
    case profileChanged

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
        case .profileChanged:
            return AppLocalization.string("Conduit switched to another profile, so nothing was saved.")
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
    /// The reads whose answers the tabs keep on the phone (#1533), per
    /// dashboard and profile, the plugin catalog once per dashboard.
    enum KeptRoute {
        static let officialSkills = "/api/skills/hub/official"
        /// The year's calls per tool: the usage answer's `tools` alone.
        static let toolCalls = "conduit:capability-tool-calls"
        /// The servers and the catalog as Conduit read them (their Codable
        /// copies), so a server's command arguments, which can hold a key,
        /// are never kept.
        static let servers = "/api/mcp/servers"
        static let connectorCatalog = "/api/mcp/catalog"
        /// The answer Settings keeps for the Conduit plugin's status too.
        static let plugins = AppState.KeptRoute.pluginsHub
        static let pluginCatalog = "/api/dashboard/plugins/catalog"
    }

    /// A tab's list drawn from what was kept, until Hermes answers. A
    /// catalog counts on its own: its read can fail while the list's
    /// answers, and it then stays the kept one.
    enum KeptList: Hashable {
        case officialSkills, toolCalls, connectors, connectorCatalog, plugins, pluginCatalog
    }

    /// The lists showing their kept copy: each asks Hermes again when its
    /// tab shows, and a change made to one reads it again, since the read
    /// on its way was asked before the change and no longer commits.
    private(set) var showsKept: Set<KeptList> = []

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
    /// Where the profile's answers are kept, and the dashboard's own.
    @ObservationIgnored private var answers: KeptAnswers?
    @ObservationIgnored private var dashboardAnswers: KeptAnswers?
    private(set) var profile = "default"
    /// Bumped on every profile or dashboard switch: work started before it
    /// commits nothing. An editor keeps the one it read under.
    @ObservationIgnored private(set) var generation = 0
    /// Bumped by every load of a list and every change made to it here: a
    /// load commits only if nothing newer touched its list meanwhile, so a
    /// refresh that answers late can't bring back an older list or undo a
    /// switch just flipped.
    @ObservationIgnored private var skillsEpoch = 0
    @ObservationIgnored private var connectorsEpoch = 0
    /// Bumped when a server's entry is saved: a test that started before
    /// tested the old entry.
    @ObservationIgnored private var probeEpochs: [String: Int] = [:]
    @ObservationIgnored private var pluginsEpoch = 0

    /// A connector's probe stays fresh this long, as on Desktop.
    static let probeLifetime: TimeInterval = 300
    static let actionPollInterval: Duration = .milliseconds(1_200)
    static let toolCallsPath = "/api/analytics/usage?days=365"

    /// Points the store at a bridge and profile, and draws what each tab
    /// showed last time there. Every call starts over: the screen calls it
    /// once per dashboard and profile, the first time offline too, as the
    /// kept lists show without a bridge.
    func configure(
        requester: (any DashboardJSONRequester)?,
        profile: String,
        answers: KeptAnswers? = nil,
        dashboardAnswers: KeptAnswers? = nil
    ) {
        self.requester = requester
        self.profile = profile
        self.answers = answers
        self.dashboardAnswers = dashboardAnswers
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
        showsKept = []
        showKept()
    }

    private func showKept() {
        if let kept = answers?.kept(KeptRoute.officialSkills) {
            officialSkills = Self.officialSkills(from: kept)
            showsKept.insert(.officialSkills)
        }
        if let kept = answers?.kept(KeptRoute.toolCalls) {
            toolCalls = CapabilityToolsetOrdering.toolCallCounts(from: kept)
            showsKept.insert(.toolCalls)
        }
        if let kept = Self.rows(ConnectorServer.self, under: "servers", in: answers?.kept(KeptRoute.servers)) {
            servers = kept
            showsKept.insert(.connectors)
            if let catalog = Self.rows(ConnectorCatalogEntry.self, under: "entries", in: answers?.kept(KeptRoute.connectorCatalog)) {
                connectorCatalog = catalog
                showsKept.insert(.connectorCatalog)
            }
        }
        if let kept = answers?.kept(KeptRoute.plugins) {
            plugins = AgentPluginRow.list(from: kept)
            showsKept.insert(.plugins)
            if let catalog = dashboardAnswers?.kept(KeptRoute.pluginCatalog) {
                pluginCatalog = PluginCatalogEntry.list(from: catalog)
                showsKept.insert(.pluginCatalog)
            }
        }
    }

    /// Whether requests go to `owner`'s bridge and profile. False after a
    /// switch until the Capabilities screen points the store at them, so a
    /// detail page never reads the previous dashboard or profile.
    func serves(_ owner: CapabilitySnapshotOwner) -> Bool {
        requester.map { ObjectIdentifier($0) } == owner.bridge && profile == owner.profile
    }

    // MARK: Requests

    private func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: Int = 12_000
    ) async throws -> [String: Any] {
        guard let requester else { throw CapabilitiesStoreError.notConnected }
        let send = {
            try await requester.requestJSON(
                path: path,
                method: method,
                body: body,
                timeoutMilliseconds: timeout,
                maxResponseBytes: DataURLLimits.maxJSONResponseBytes
            )
        }
        // A backend, connector or install change makes Hermes rewrite the
        // profile config: in turn with every other config save.
        guard Self.writesProfileConfig(method: method, path: path) else { return try await send() }
        return try await ProfileConfigWriteQueue.runThrowing { try await send() }
    }

    /// Writes Hermes keeps in the profile config. Keys (`/api/env`),
    /// connector tests, sign-ins and reads don't wait for config saves.
    static func writesProfileConfig(method: String, path: String) -> Bool {
        guard method != "GET" else { return false }
        let route = path.split(separator: "?").first.map(String.init) ?? path
        if route.hasSuffix("/test") || route.hasSuffix("/auth") { return false }
        return !route.hasPrefix("/api/env") && !route.hasPrefix("/api/mcp/oauth/")
    }

    /// Reads `path` and keeps what `kept` makes of its answer under
    /// `route`, for the tab to open on next time, unless an answer newer
    /// than it is kept by then (#1533).
    private func read(
        _ path: String,
        keptAs route: String,
        in answers: KeptAnswers?,
        keeping kept: (([String: Any]) -> [String: Any])? = nil
    ) async throws -> [String: Any] {
        guard let answers else { return try await request(path, timeout: 30_000) }
        var answer: [String: Any] = [:]
        _ = try await answers.keep(route, false, {
            answer = try await self.request(path, timeout: 30_000)
            return kept?(answer) ?? answer
        })
        return answer
    }

    /// Rows kept as Conduit's own JSON, under `key`. Off the main actor, as
    /// a read's `keeping` runs where the read was asked.
    nonisolated private static func keptJSON<Row: Encodable>(_ rows: [Row], under key: String) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(rows),
              let list = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return [key: list]
    }

    private static func rows<Row: Decodable>(_ type: Row.Type, under key: String, in answer: [String: Any]?) -> [Row]? {
        guard let list = answer?[key], let data = try? JSONSerialization.data(withJSONObject: list) else { return nil }
        return try? JSONDecoder().decode([Row].self, from: data)
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
        guard let response = try? await read(scoped(KeptRoute.officialSkills), keptAs: KeptRoute.officialSkills, in: answers) else { return }
        guard token == generation, epoch == skillsEpoch else { return }
        officialSkills = Self.officialSkills(from: response)
        showsKept.remove(.officialSkills)
    }

    private static func officialSkills(from response: [String: Any]) -> [OfficialSkill] {
        (response["skills"] as? [Any] ?? []).compactMap { OfficialSkill($0) }
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
        let answers = self.answers
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
            if status.succeeded {
                await keepChange(KeptRoute.officialSkills, list: "skills", field: "installed", to: true, in: answers) {
                    OfficialSkill($0)?.identifier == skill.identifier
                }
            }
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
            if showsKept.contains(.officialSkills) { await loadOfficialSkills() }
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
        guard let response = try? await read(
            scoped(Self.toolCallsPath),
            keptAs: KeptRoute.toolCalls,
            in: answers,
            keeping: { ["tools": $0["tools"] ?? [Any]()] }
        ), token == generation else { return }
        toolCalls = CapabilityToolsetOrdering.toolCallCounts(from: response)
        showsKept.remove(.toolCalls)
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
        async let serversResponse = read(scoped(KeptRoute.servers), keptAs: KeptRoute.servers, in: answers) {
            Self.keptJSON(ConnectorServer.list(from: $0).map(\.keptCopy), under: "servers")
        }
        async let catalogResponse = try? read(scoped(KeptRoute.connectorCatalog), keptAs: KeptRoute.connectorCatalog, in: answers) {
            Self.keptJSON(ConnectorCatalogEntry.list(from: $0), under: "entries")
        }
        do {
            let servers = ConnectorServer.list(from: try await serversResponse)
            let catalog = await catalogResponse
            guard token == generation, epoch == connectorsEpoch else { return }
            self.servers = servers
            // A catalog read that fails keeps the catalog shown: a kept one
            // asks again when the tab next shows.
            if let catalog {
                connectorCatalog = ConnectorCatalogEntry.list(from: catalog)
                showsKept.remove(.connectorCatalog)
            }
            connectorsError = nil
            showsKept.remove(.connectors)
            let names = Set(servers.map(\.name))
            probes = probes.filter { names.contains($0.key) }
        } catch {
            _ = await catalogResponse
            guard token == generation, epoch == connectorsEpoch else { return }
            // A read cut off under it isn't the list failing: read again next time.
            guard !(error is CancellationError) else { return }
            connectorsError = UserFacingError.message(for: error)
        }
        connectorsLoaded = true
    }

    /// Tests every server that's on and hasn't been tested lately, a few at a
    /// time: each test starts the server on the host. Only servers Hermes
    /// listed: kept ones aren't tested until it answers.
    func probeServers(force: Bool = false) async {
        guard !showsKept.contains(.connectors) else { return }
        let now = Date()
        let due = servers.filter { server in
            guard server.enabled, !probing.contains(server.name) else { return false }
            guard !force, let probe = probes[server.name] else { return true }
            return now.timeIntervalSince(probe.checkedAt) > Self.probeLifetime
        }
        var pending = due[...]
        // The list may have gone while it was still reading the servers.
        guard !Task.isCancelled else { return }
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
        let entryEpoch = probeEpochs[name, default: 0]
        probing.insert(name)
        // The test runs to its answer even when the page that asked goes
        // away (opening a server from the list cancels the list's tests):
        // the host already started the server, and an interrupted test
        // isn't the server failing (#1570).
        // The path and the dashboard are taken together, now: a switch
        // while the task starts can't send this profile's test to another.
        let path = scoped("/api/mcp/servers/\(Self.component(name))/test")
        let requester = self.requester
        let test = Task { () -> ConnectorProbe in
            guard let requester else { throw CapabilitiesStoreError.notConnected }
            return ConnectorProbe(try await requester.requestJSON(
                path: path,
                method: "POST",
                body: nil,
                timeoutMilliseconds: 60_000,
                maxResponseBytes: DataURLLimits.maxJSONResponseBytes
            ))
        }
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
        guard entryEpoch == probeEpochs[name, default: 0] else {
            // Saved while this ran: test what's there now.
            if servers.first(where: { $0.name == name })?.enabled == true { await self.probe(name) }
            return
        }
        if let probe { probes[name] = probe }
    }

    func setServerEnabled(_ name: String, enabled: Bool) async throws {
        let token = generation
        let answers = self.answers
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
            if token == generation { await readKeptServersAgain() }
            throw error
        }
        await keepChange(KeptRoute.servers, list: "servers", field: "enabled", to: enabled, in: answers) {
            $0["name"] as? String == name
        }
        guard token == generation else { return }
        let kept = Date()
        await readKeptServersAgain()
        if enabled {
            // Unless reading the kept list again just tested it.
            if (probes[name]?.checkedAt ?? .distantPast) < kept { await probe(name) }
        } else {
            probes[name] = nil
        }
    }

    /// After a change made here, a list still showing its kept copy reads
    /// the servers again, since the read on its way was asked before the
    /// change and no longer commits, and tests them once Hermes lists them.
    private func readKeptServersAgain() async {
        let token = generation
        guard showsKept.contains(.connectors) else { return }
        await loadConnectors()
        if token == generation { await probeServers() }
    }

    /// The profile's `mcp_servers` as written in config.yaml: defaults not
    /// merged and `${NAME}` references not expanded, so keys kept in .env
    /// show as their names. Read from the dashboard and profile given, so a
    /// save reads and writes the same ones.
    private static func configuredServers(
        _ requester: any DashboardJSONRequester,
        profile: String
    ) async throws -> [String: Any] {
        let config = try await requester.requestJSON(
            path: DashboardPath.withProfile("/api/config?include_defaults=false", profile: profile),
            method: "GET",
            body: nil,
            timeoutMilliseconds: 30_000,
            maxResponseBytes: DataURLLimits.maxJSONResponseBytes
        )
        return config["mcp_servers"] as? [String: Any] ?? [:]
    }

    /// One server's entry, to edit. Read in turn with config saves, so a
    /// switch flipped just before shows in it.
    func serverConfig(_ name: String) async throws -> [String: Any] {
        guard let requester else { throw CapabilitiesStoreError.notConnected }
        let profile = self.profile
        return try await ProfileConfigWriteQueue.runThrowing {
            guard let entry = try await Self.configuredServers(requester, profile: profile)[name] as? [String: Any] else {
                throw ConnectorServerEdit.Problem.gone(name)
            }
            return entry
        }
    }

    /// Saves an edited server, renamed or not. The map is read again and
    /// written back in one turn of the config queue, so a save elsewhere
    /// can't land between them and be undone, and both go to the dashboard
    /// and profile the editor opened on: after a switch nothing is written.
    /// Hermes checks the entry and says what it refused.
    func saveServer(
        original: String,
        loaded: [String: Any],
        name: String,
        entry: [String: Any],
        openedOn: Int
    ) async throws {
        let token = generation
        // The editor read its entry before this: a switch since then would
        // write that profile's entry into this one.
        guard token == openedOn else { throw CapabilitiesStoreError.profileChanged }
        guard let requester else { throw CapabilitiesStoreError.notConnected }
        let profile = self.profile
        let answers = self.answers
        try await ProfileConfigWriteQueue.runThrowing {
            guard token == self.generation else { throw CapabilitiesStoreError.profileChanged }
            let servers = try ConnectorServerEdit.replacing(
                in: try await Self.configuredServers(requester, profile: profile),
                original: original,
                loaded: loaded,
                name: name,
                entry: entry
            )
            guard token == self.generation else { throw CapabilitiesStoreError.profileChanged }
            do {
                _ = try await requester.requestJSON(
                    path: DashboardPath.withProfile("/api/mcp/servers", profile: profile),
                    method: "PUT",
                    body: DashboardPath.bodyWithProfile(["servers": servers], profile: profile),
                    timeoutMilliseconds: 30_000,
                    maxResponseBytes: DataURLLimits.maxJSONResponseBytes
                )
            } catch DashboardTicketBridgeError.http(let status, _) where status == 404 || status == 405 {
                throw CapabilitiesStoreError.editUnsupported
            }
        }
        // Hermes' answer brings the edit: a read asked before the save
        // isn't kept after it (#1533).
        answers?.noteWrite(KeptRoute.servers)
        answers?.noteWrite(KeptRoute.connectorCatalog)
        // Saved on the host; what's showing now is another profile's.
        guard token == generation else { return }
        probes[original] = nil
        probes[name] = nil
        // A test of the old entry still running is discarded and run again.
        probeEpochs[original, default: 0] &+= 1
        probeEpochs[name, default: 0] &+= 1
        let wasKept = showsKept.contains(.connectors)
        await loadConnectors()
        guard token == generation else { return }
        // Tested again in the background: the editor closes on the save. A
        // kept list Hermes' answer took the place of has its servers tested
        // now, as the tab's open would have, the saved one with them.
        if wasKept, !showsKept.contains(.connectors) {
            Task { await probeServers() }
        } else if servers.first(where: { $0.name == name })?.enabled == true {
            Task { await probe(name) }
        }
    }

    func removeServer(_ name: String) async throws {
        let token = generation
        let answers = self.answers
        _ = try await request(scoped("/api/mcp/servers/\(Self.component(name))"), method: "DELETE")
        await keepChange(KeptRoute.servers, list: "servers", in: answers) { rows in
            rows.filter { ($0 as? [String: Any])?["name"] as? String != name }
        }
        await keepChange(KeptRoute.connectorCatalog, list: "entries", field: "installed", to: false, in: answers) {
            $0["name"] as? String == name
        }
        guard token == generation else { return }
        connectorsEpoch &+= 1
        servers.removeAll { $0.name == name }
        probes[name] = nil
        if let index = connectorCatalog.firstIndex(where: { $0.name == name }) {
            connectorCatalog[index].installed = false
        }
        await readKeptServersAgain()
    }

    /// Installs a catalog server with the keys it asks for; entries Hermes
    /// clones and builds run in the background and are waited on.
    @discardableResult
    func installConnector(_ entry: ConnectorCatalogEntry, env: [String: String]) async -> Bool {
        let token = generation
        let answers = self.answers
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
            // Its row comes with Hermes' answer: a read asked before the
            // install isn't kept after it.
            answers?.noteWrite(KeptRoute.servers)
            answers?.noteWrite(KeptRoute.connectorCatalog)
            guard token == generation else { return false }
            connectorInstalls[entry.name] = nil
            let wasKept = showsKept.contains(.connectors)
            await loadConnectors()
            guard token == generation else { return true }
            if wasKept {
                // Hermes' list took the kept one's place: its servers are
                // tested now, as the tab's open would have, the new one
                // with them.
                await probeServers()
            } else {
                await probe(entry.name)
            }
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
        async let hubResponse = read(scoped(KeptRoute.plugins), keptAs: KeptRoute.plugins, in: answers)
        // The same for every profile: kept once per dashboard.
        async let catalogResponse = try? read(KeptRoute.pluginCatalog, keptAs: KeptRoute.pluginCatalog, in: dashboardAnswers)
        do {
            let plugins = AgentPluginRow.list(from: try await hubResponse)
            let catalog = await catalogResponse
            guard token == generation, epoch == pluginsEpoch else { return }
            self.plugins = plugins
            // A catalog read that fails keeps the catalog shown: a kept one
            // asks again when the tab next shows.
            if let catalog {
                pluginCatalog = PluginCatalogEntry.list(from: catalog)
                showsKept.remove(.pluginCatalog)
            }
            pluginsError = nil
            showsKept.remove(.plugins)
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
        let answers = self.answers
        pluginBusy.insert(plugin.name)
        defer { if token == generation { pluginBusy.remove(plugin.name) } }
        let response: [String: Any]
        do {
            response = try await request(
                "/api/dashboard/agent-plugins/\(Self.pluginPath(plugin.name))/\(enabled ? "enable" : "disable")",
                method: "POST",
                timeout: 60_000
            )
        } catch {
            // Refused: a list still showing its kept copy reads again, as
            // after a switch Hermes took.
            if token == generation, showsKept.contains(.plugins) { await loadPlugins() }
            throw error
        }
        let status = enabled ? "enabled" : "disabled"
        await keepChange(KeptRoute.plugins, list: "plugins", field: "runtime_status", to: status, in: answers) {
            $0["name"] as? String == plugin.name
        }
        guard token == generation else { return }
        if let index = plugins.firstIndex(where: { $0.name == plugin.name }) {
            pluginsEpoch &+= 1
            plugins[index].runtimeStatus = status
        }
        if response["restart_required"] as? Bool == true {
            pluginsNeedRestart = true
        }
        // A list still showing its kept copy reads it again, since the read
        // on its way was asked before the switch and no longer commits.
        if showsKept.contains(.plugins) { await loadPlugins() }
    }

    /// Sets `field` in the kept rows of the route's list (under `key`) that
    /// `matches`, as Hermes took a change.
    private func keepChange(
        _ route: String,
        list key: String,
        field: String,
        to value: Any,
        in answers: KeptAnswers?,
        where matches: ([String: Any]) -> Bool
    ) async {
        await keepChange(route, list: key, in: answers) { rows in
            rows.map { row -> Any in
                guard var row = row as? [String: Any], matches(row) else { return row }
                row[field] = value
                return row
            }
        }
    }

    /// Changes the kept rows of the route's list (under `key`) as Hermes
    /// took a change, and keeps the list over any read asked before it, so
    /// the tab opens on the change next time (#1533). In the answers the
    /// change was made under, the profile's or, for a list kept once per
    /// dashboard, the dashboard's, taken before it went out: a switch while
    /// it was out neither loses it nor keeps it for the profile switched to.
    private func keepChange(
        _ route: String,
        list key: String,
        in answers: KeptAnswers?,
        rows change: ([Any]) -> [Any]
    ) async {
        guard let answers else { return }
        guard var kept = answers.kept(route), let rows = kept[key] as? [Any] else {
            // Nothing kept to change: the write counts all the same.
            answers.noteWrite(route)
            return
        }
        kept[key] = change(rows)
        _ = try? await answers.keep(route, true, { [kept] in kept })
    }

    /// Marks the catalog entries `matches` picks installed or not, with no
    /// update waiting, in the kept catalog and, unless a switch came first,
    /// the one shown, as Hermes took an update or removal. The catalog hides
    /// an installed entry, so a removal whose read fails still offers the
    /// plugin again (#1533).
    private func markCatalog(
        installed: Bool,
        token: Int,
        in answers: KeptAnswers?,
        where matches: (_ name: String, _ installed: Bool) -> Bool
    ) async {
        await keepCatalog(installed: installed, in: answers, where: matches)
        guard token == generation else { return }
        pluginsEpoch &+= 1
        for index in pluginCatalog.indices where matches(pluginCatalog[index].name, pluginCatalog[index].installed) {
            pluginCatalog[index].installed = installed
            pluginCatalog[index].updateAvailable = false
        }
    }

    /// The kept catalog's side of `markCatalog`, over any catalog read asked
    /// before the change. An install changes only this one: the catalog
    /// shown keeps its entry until Hermes' answer brings the installed row.
    private func keepCatalog(
        installed: Bool,
        in answers: KeptAnswers?,
        where matches: (_ name: String, _ installed: Bool) -> Bool
    ) async {
        await keepChange(KeptRoute.pluginCatalog, list: "entries", in: answers) { rows in
            rows.map { row -> Any in
                guard var row = row as? [String: Any], let name = row["name"] as? String,
                      matches(name, row["installed"] as? Bool ?? false) else { return row }
                row["installed"] = installed
                row["update_available"] = false
                return row
            }
        }
    }

    func updatePlugin(_ plugin: AgentPluginRow, acceptCapabilities: Bool = false) async throws -> PluginUpdateOutcome {
        try requirePluginProfile()
        let token = generation
        let answers = self.answers, dashboardAnswers = self.dashboardAnswers
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
        let updated = response["unchanged"] as? Bool != true
        if updated {
            // Its new version comes with Hermes' answer: a read asked before
            // the update isn't kept after it.
            answers?.noteWrite(KeptRoute.plugins)
            await markCatalog(installed: true, token: token, in: dashboardAnswers) { name, installed in
                PluginCatalogEntry.isSource(named: name, installed: installed, of: plugin)
            }
        }
        // A profile or dashboard switch discards the answer.
        guard token == generation else { throw CancellationError() }
        guard updated else { return .upToDate }
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
        let answers = self.answers, dashboardAnswers = self.dashboardAnswers
        pluginBusy.insert(plugin.name)
        defer { if token == generation { pluginBusy.remove(plugin.name) } }
        _ = try await request(
            "/api/dashboard/agent-plugins/\(Self.pluginPath(plugin.folderName))",
            method: "DELETE",
            timeout: 60_000
        )
        // Kept without it, over any read asked before the removal.
        await keepChange(KeptRoute.plugins, list: "plugins", in: answers) { rows in
            rows.filter { ($0 as? [String: Any])?["name"] as? String != plugin.name }
        }
        await markCatalog(installed: false, token: token, in: dashboardAnswers) { name, installed in
            PluginCatalogEntry.isSource(named: name, installed: installed, of: plugin)
        }
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
        let answers = self.answers, dashboardAnswers = self.dashboardAnswers
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
        // Its row comes with Hermes' answer: a read asked before the
        // install isn't kept after it.
        answers?.noteWrite(KeptRoute.plugins)
        await keepCatalog(installed: true, in: dashboardAnswers) { name, _ in name == entry.name }
        guard token == generation else { return outcome }
        if restart { pluginsNeedRestart = true }
        await loadPlugins()
        return outcome
    }
}
