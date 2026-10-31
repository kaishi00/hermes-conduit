//
//  CapabilityCatalogModels.swift
//  Conduit
//
//  What Settings > Capabilities reads beyond the installed skills and
//  toolsets (Models.swift): the official skills catalog, tool call counts,
//  a toolset's providers, MCP servers and their catalog (Connectors), and
//  agent plugins and their catalog. Shapes follow Hermes' dashboard routes,
//  the same ones Hermes Desktop's Capabilities page reads.
//

import Foundation

// MARK: - Skills

/// A skill in Hermes' official optional-skills catalog
/// (`GET /api/skills/hub/official`).
struct OfficialSkill: Identifiable, Equatable {
    var id: String { identifier }
    let name: String
    let identifier: String
    var description: String
    var category: String
    var tags: [String]
    var installed: Bool

    init?(_ value: Any) {
        guard let dict = value as? [String: Any],
              let name = dict["name"] as? String, !name.isEmpty else { return nil }
        let identifier = (dict["identifier"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        self.name = name
        self.identifier = identifier
        description = dict["description"] as? String ?? ""
        category = (dict["category"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "general"
        tags = (dict["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        installed = dict["installed"] as? Bool ?? false
    }

    init(name: String, identifier: String, description: String = "", category: String = "general", tags: [String] = [], installed: Bool = false) {
        self.name = name
        self.identifier = identifier
        self.description = description
        self.category = category
        self.tags = tags
        self.installed = installed
    }
}

enum CapabilitySkillOrdering {
    /// Hermes Desktop's order: the most used first (or least, flipped), then
    /// by name.
    static func sorted(_ skills: [CapabilitySkill], mostUsedFirst: Bool) -> [CapabilitySkill] {
        skills.sorted { lhs, rhs in
            let lhsUsage = lhs.usage ?? 0
            let rhsUsage = rhs.usage ?? 0
            if lhsUsage != rhsUsage {
                return mostUsedFirst ? lhsUsage > rhsUsage : lhsUsage < rhsUsage
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func matches(_ skill: CapabilitySkill, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return skill.name.localizedCaseInsensitiveContains(query)
            || skill.description?.localizedCaseInsensitiveContains(query) == true
            || skill.category?.localizedCaseInsensitiveContains(query) == true
    }

    /// Catalog rows not installed yet, A-Z. A row whose name is already
    /// installed (from another source) is left out too.
    static func available(_ catalog: [OfficialSkill], installedNames: Set<String>, query: String) -> [OfficialSkill] {
        catalog
            .filter { !$0.installed && !installedNames.contains($0.name) }
            .filter { entry in
                guard !query.isEmpty else { return true }
                return entry.name.localizedCaseInsensitiveContains(query)
                    || entry.description.localizedCaseInsensitiveContains(query)
                    || entry.category.localizedCaseInsensitiveContains(query)
                    || entry.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `software_development` reads "Software Development".
    static func prettyCategory(_ category: String?) -> String {
        let raw = (category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = (raw.isEmpty ? "general" : raw)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// A SKILL.md split into its frontmatter fields and its body.
struct SkillFrontmatter: Equatable {
    struct Field: Equatable {
        let key: String
        let value: String
    }

    var fields: [Field]
    var body: String

    /// Top-level `key: value` lines between the opening `---` fences, as
    /// Desktop's skill pane reads them; nested lines stay out of the grid.
    static func parse(_ text: String) -> SkillFrontmatter {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return SkillFrontmatter(fields: [], body: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields: [Field] = []
        for line in lines[1..<close] {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields.append(Field(key: key, value: value))
        }
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillFrontmatter(fields: fields, body: body)
    }
}

// MARK: - Tools

enum CapabilityToolsetOrdering {
    /// Toolsets Hermes Desktop leaves off its Tools tab: platform plumbing
    /// rather than tools a person turns on.
    static let hidden: Set<String> = ["discord", "discord_admin", "yuanbao", "context_engine", "moa"]

    static func isVisible(_ toolset: CapabilityToolset) -> Bool {
        !hidden.contains(toolset.name)
    }

    /// The label without a leading emoji, or the name when Hermes sends none.
    static func label(_ toolset: CapabilityToolset) -> String {
        let raw = toolset.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return toolset.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return strippedLabel(raw) ?? raw
    }

    /// A toolset title without its leading emoji (an older Hermes keeps it
    /// in the dashboard's label). Nil when nothing else is left. Also names
    /// a step's tool (`ToolCatalog`).
    static func strippedLabel(_ label: String?) -> String? {
        let raw = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stripped = String(raw.drop { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.generalCategory == .otherSymbol }
                || character.unicodeScalars.allSatisfy { $0.properties.isVariationSelector || $0 == "\u{200D}" }
                || character.isWhitespace
        })
        return stripped.isEmpty ? nil : stripped
    }

    /// Calls of every tool in the set.
    static func calls(_ toolset: CapabilityToolset, counts: [String: Int]) -> Int {
        (toolset.tools ?? []).reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    static func matches(_ toolset: CapabilityToolset, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return toolset.name.localizedCaseInsensitiveContains(query)
            || label(toolset).localizedCaseInsensitiveContains(query)
            || toolset.description?.localizedCaseInsensitiveContains(query) == true
            || (toolset.tools ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// The most called first (or least, flipped), then by label.
    static func sorted(_ toolsets: [CapabilityToolset], counts: [String: Int], mostUsedFirst: Bool) -> [CapabilityToolset] {
        toolsets.sorted { lhs, rhs in
            let lhsCalls = calls(lhs, counts: counts)
            let rhsCalls = calls(rhs, counts: counts)
            if lhsCalls != rhsCalls {
                return mostUsedFirst ? lhsCalls > rhsCalls : lhsCalls < rhsCalls
            }
            return label(lhs).localizedCaseInsensitiveCompare(label(rhs)) == .orderedAscending
        }
    }

    /// Per-tool call counts from `GET /api/analytics/usage` (`tools`).
    static func toolCallCounts(from response: [String: Any]) -> [String: Int] {
        let rows = response["tools"] as? [Any] ?? []
        var counts: [String: Int] = [:]
        for row in rows {
            guard let dict = row as? [String: Any],
                  let tool = dict["tool"] as? String,
                  let count = dict["count"] as? Int else { continue }
            counts[tool, default: 0] += count
        }
        return counts
    }
}

/// A toolset's backends and the keys each needs
/// (`GET /api/tools/toolsets/{name}/config`).
struct ToolsetConfig: Equatable {
    struct EnvVar: Equatable, Identifiable {
        var id: String { key }
        let key: String
        var prompt: String
        var url: String?
        var isSet: Bool
    }

    struct Provider: Equatable, Identifiable {
        var id: String { name }
        let name: String
        var badge: String
        var tag: String
        var envVars: [EnvVar]
        var managedNousFeature: String?
        var isActive: Bool
        /// ready, needs_setup, needs_auth or needs_keys.
        var status: String
        /// The web toolset's backend key and the capabilities (search,
        /// extract) it can serve.
        var webBackend: String?
        var capabilities: [String]
    }

    var hasCategory: Bool
    var providers: [Provider]
    var activeProvider: String?
    var activeSearchBackend: String?
    var activeExtractBackend: String?
    var searchViaNous: Bool
    var extractViaNous: Bool

    init(_ dict: [String: Any]) {
        hasCategory = dict["has_category"] as? Bool ?? false
        activeProvider = dict["active_provider"] as? String
        activeSearchBackend = dict["active_search_backend"] as? String
        activeExtractBackend = dict["active_extract_backend"] as? String
        searchViaNous = dict["search_via_nous"] as? Bool ?? false
        extractViaNous = dict["extract_via_nous"] as? Bool ?? false
        providers = (dict["providers"] as? [Any] ?? []).compactMap { value in
            guard let row = value as? [String: Any], let name = row["name"] as? String else { return nil }
            let envVars: [EnvVar] = (row["env_vars"] as? [Any] ?? []).compactMap { value in
                guard let env = value as? [String: Any], let key = env["key"] as? String else { return nil }
                return EnvVar(
                    key: key,
                    prompt: (env["prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key,
                    url: env["url"] as? String,
                    isSet: env["is_set"] as? Bool ?? false
                )
            }
            return Provider(
                name: name,
                badge: row["badge"] as? String ?? "",
                tag: row["tag"] as? String ?? "",
                envVars: envVars,
                managedNousFeature: row["managed_nous_feature"] as? String,
                isActive: row["is_active"] as? Bool ?? false,
                status: row["status"] as? String ?? "",
                webBackend: row["web_backend"] as? String,
                capabilities: (row["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []
            )
        }
    }

    /// A config answer as Hermes holds it once `provider` is the toolset's
    /// backend (for the web toolset, the backend of `capability`): what a
    /// kept page shows until Hermes answers again.
    static func choosing(_ provider: String, capability: String?, in answer: [String: Any]) -> [String: Any] {
        guard let rows = answer["providers"] as? [Any] else { return answer }
        var answer = answer
        if let capability {
            let row = rows.lazy.compactMap { $0 as? [String: Any] }.first { $0["name"] as? String == provider }
            guard let row, let backend = row["web_backend"] as? String else { return answer }
            // As `serves` tells managed Nous from an own key.
            let viaNous = row["managed_nous_feature"] is String
            switch capability {
            case "search":
                answer["active_search_backend"] = backend
                answer["search_via_nous"] = viaNous
            case "extract":
                answer["active_extract_backend"] = backend
                answer["extract_via_nous"] = viaNous
            default:
                break
            }
        } else {
            answer["active_provider"] = provider
            answer["providers"] = rows.map { value -> Any in
                guard var row = value as? [String: Any] else { return value }
                row["is_active"] = row["name"] as? String == provider
                return row
            }
        }
        return answer
    }

    /// A config answer as Hermes holds it once `key` is saved: set wherever
    /// a backend asks for it.
    static func settingKey(_ key: String, in answer: [String: Any]) -> [String: Any] {
        guard let rows = answer["providers"] as? [Any] else { return answer }
        var answer = answer
        answer["providers"] = rows.map { value -> Any in
            guard var row = value as? [String: Any], let envVars = row["env_vars"] as? [Any] else { return value }
            row["env_vars"] = envVars.map { value -> Any in
                guard var env = value as? [String: Any], env["key"] as? String == key else { return value }
                env["is_set"] = true
                return env
            }
            return row
        }
        return answer
    }

    /// The config as `choosing(_:capability:in:)` makes its answer: what
    /// the page shows once Hermes took the change, kept or not.
    func choosing(_ provider: String, capability: String?) -> ToolsetConfig {
        var config = self
        if let capability {
            guard let row = providers.first(where: { $0.name == provider }), let backend = row.webBackend else { return self }
            let viaNous = row.managedNousFeature != nil
            switch capability {
            case "search":
                config.activeSearchBackend = backend
                config.searchViaNous = viaNous
            case "extract":
                config.activeExtractBackend = backend
                config.extractViaNous = viaNous
            default:
                break
            }
        } else {
            config.activeProvider = provider
            for index in config.providers.indices {
                config.providers[index].isActive = config.providers[index].name == provider
            }
        }
        return config
    }

    /// The config as `settingKey(_:in:)` makes its answer.
    func settingKey(_ key: String) -> ToolsetConfig {
        var config = self
        for provider in config.providers.indices {
            for env in config.providers[provider].envVars.indices where config.providers[provider].envVars[env].key == key {
                config.providers[provider].envVars[env].isSet = true
            }
        }
        return config
    }

    /// Whether `provider` is the one a web search (or extract) call uses
    /// now. Managed Nous and own-key Firecrawl share a backend name, so the
    /// Nous flag tells them apart.
    func serves(_ capability: String, provider: Provider) -> Bool {
        guard let backend = provider.webBackend else { return false }
        switch capability {
        case "search":
            return backend == activeSearchBackend && (provider.managedNousFeature != nil) == searchViaNous
        case "extract":
            return backend == activeExtractBackend && (provider.managedNousFeature != nil) == extractViaNous
        default:
            return false
        }
    }
}

/// Where the terminal tool runs (`GET /api/tools/terminal/backends`).
struct TerminalBackendOption: Equatable, Identifiable {
    var id: String { name }
    let name: String
    var label: String
    var description: String
    var active: Bool
    /// ready, needs_setup or unavailable.
    var status: String
    var detail: String?

    /// A backends answer as Hermes holds it once the terminal runs on
    /// `backend`: what a kept page shows until Hermes answers again.
    static func choosing(_ backend: String, in answer: [String: Any]) -> [String: Any] {
        guard let rows = answer["backends"] as? [Any] else { return answer }
        var answer = answer
        answer["backends"] = rows.map { value -> Any in
            guard var row = value as? [String: Any] else { return value }
            row["active"] = row["name"] as? String == backend
            return row
        }
        return answer
    }

    /// The backends as `choosing(_:in:)` makes their answer.
    static func choosing(_ backend: String, in options: [TerminalBackendOption]) -> [TerminalBackendOption] {
        options.map { option in
            var option = option
            option.active = option.name == backend
            return option
        }
    }

    static func list(from response: [String: Any]) -> [TerminalBackendOption] {
        (response["backends"] as? [Any] ?? []).compactMap { value in
            guard let row = value as? [String: Any], let name = row["name"] as? String else { return nil }
            return TerminalBackendOption(
                name: name,
                label: (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                description: row["description"] as? String ?? "",
                active: row["active"] as? Bool ?? false,
                status: row["status"] as? String ?? "",
                detail: (row["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}

// MARK: - Connectors (MCP servers)

/// An MCP server in the profile's config (`GET /api/mcp/servers`).
struct ConnectorServer: Equatable, Identifiable, Codable {
    var id: String { name }
    let name: String
    /// http, stdio or unknown.
    var transport: String
    var url: String?
    var command: String?
    var args: [String] = []
    /// oauth, header, or nil.
    var auth: String?
    var enabled: Bool
    /// A plugin's server: shown, never changed from here (Hermes answers 409).
    var plugin: String?

    /// The copy kept on the phone (#1533) leaves out the command's
    /// arguments, which can hold a key, and keeps how the server signs in
    /// under a name the kept answers' filter doesn't take for a
    /// credential's.
    private enum CodingKeys: String, CodingKey {
        case name, transport, url, command, enabled, plugin
        case auth = "sign_in"
    }

    var isFromPlugin: Bool { plugin != nil }

    /// The copy kept on the phone: its address cut to scheme, host and
    /// port, as its path or query can hold a key (`/sse/<token>`), as its
    /// command's arguments can. Hermes' answer brings the rest.
    var keptCopy: ConnectorServer {
        var copy = self
        copy.url = url.flatMap(Self.origin)
        return copy
    }

    static func origin(of address: String) -> String? {
        guard var parts = URLComponents(string: address), parts.host != nil else { return nil }
        parts.user = nil
        parts.password = nil
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string
    }

    /// OAuth sign-in applies to a URL server that doesn't send its own
    /// Authorization header, as Hermes' `/auth` route requires.
    var canSignIn: Bool { transport == "http" && url != nil && auth != "header" && !isFromPlugin }

    static func list(from response: [String: Any]) -> [ConnectorServer] {
        (response["servers"] as? [Any] ?? []).compactMap { value in
            guard let row = value as? [String: Any], let name = row["name"] as? String else { return nil }
            let plugin = (row["source"] as? String) == "plugin" ? ((row["plugin"] as? String) ?? "") : nil
            return ConnectorServer(
                name: name,
                transport: row["transport"] as? String ?? "unknown",
                url: (row["url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                command: (row["command"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                args: (row["args"] as? [Any])?.compactMap { $0 as? String } ?? [],
                auth: (row["auth"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                enabled: row["enabled"] as? Bool ?? true,
                plugin: plugin
            )
        }
    }
}

/// An entry of Hermes' MCP catalog (`GET /api/mcp/catalog`). Kept on the
/// phone as Conduit's own JSON (#1533), whose `authType` the kept answers'
/// filter keeps, as it wouldn't Hermes' `auth_type`. Its command and
/// arguments are kept too: they're the catalog's template, the same on
/// every Hermes, and the keys an install asks for (`requiredEnv`) go to
/// Hermes in the install's body, never into them.
struct ConnectorCatalogEntry: Equatable, Identifiable, Codable {
    struct EnvField: Equatable, Identifiable, Codable {
        var id: String { name }
        let name: String
        var prompt: String
        var required: Bool
    }

    var id: String { name }
    let name: String
    var description: String
    var transport: String
    /// none, api_key or oauth.
    var authType: String
    var requiredEnv: [EnvField]
    var url: String?
    var command: String?
    var args: [String]
    var needsInstall: Bool
    var installed: Bool

    static func list(from response: [String: Any]) -> [ConnectorCatalogEntry] {
        (response["entries"] as? [Any] ?? []).compactMap { value in
            guard let row = value as? [String: Any], let name = row["name"] as? String else { return nil }
            let env: [EnvField] = (row["required_env"] as? [Any] ?? []).compactMap { value in
                guard let field = value as? [String: Any], let name = field["name"] as? String else { return nil }
                return EnvField(
                    name: name,
                    prompt: (field["prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                    required: field["required"] as? Bool ?? true
                )
            }
            return ConnectorCatalogEntry(
                name: name,
                description: row["description"] as? String ?? "",
                transport: row["transport"] as? String ?? "",
                authType: row["auth_type"] as? String ?? "none",
                requiredEnv: env,
                url: (row["url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                command: (row["command"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                args: (row["args"] as? [Any])?.compactMap { $0 as? String } ?? [],
                needsInstall: row["needs_install"] as? Bool ?? false,
                installed: row["installed"] as? Bool ?? false
            )
        }
    }
}

/// What a test connection to a server found
/// (`POST /api/mcp/servers/{name}/test`).
struct ConnectorProbe: Equatable {
    struct Tool: Equatable, Identifiable {
        var id: String { name }
        let name: String
        var description: String
    }

    var ok: Bool
    var error: String?
    var tools: [Tool]
    var checkedAt: Date

    init(_ dict: [String: Any], checkedAt: Date = Date()) {
        ok = dict["ok"] as? Bool ?? false
        error = (dict["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        tools = (dict["tools"] as? [Any] ?? []).compactMap { value in
            guard let row = value as? [String: Any], let name = row["name"] as? String else { return nil }
            return Tool(name: name, description: row["description"] as? String ?? "")
        }
        self.checkedAt = checkedAt
    }

    init(failure: String, checkedAt: Date = Date()) {
        ok = false
        error = failure
        tools = []
        self.checkedAt = checkedAt
    }
}

/// A server's state on the Connectors list, as Hermes Desktop words it.
enum ConnectorState: Equatable {
    case off
    case checking
    case unknown
    case on(tools: Int)
    case needsSignIn
    case failed(String)

    /// An auth-shaped probe error means a sign-in, not a broken server.
    static func of(_ server: ConnectorServer, probe: ConnectorProbe?, probing: Bool) -> ConnectorState {
        guard server.enabled else { return .off }
        if probing { return .checking }
        guard let probe else { return .unknown }
        if probe.ok { return .on(tools: probe.tools.count) }
        let error = probe.error ?? ""
        if error.range(of: "401|unauthori[sz]ed|forbidden|invalid token|authentication|oauth", options: [.regularExpression, .caseInsensitive]) != nil {
            return .needsSignIn
        }
        return .failed(error)
    }
}

enum ConnectorGrouping {
    struct Groups: Equatable {
        var connected: [ConnectorServer]
        var available: [ConnectorCatalogEntry]
        var off: [ConnectorServer]
    }

    /// Connected (any server that's on, broken ones first), Available
    /// (catalog entries this profile hasn't installed), Turned off.
    static func groups(
        servers: [ConnectorServer],
        catalog: [ConnectorCatalogEntry],
        states: [String: ConnectorState],
        query: String
    ) -> Groups {
        func matches(_ text: String...) -> Bool {
            query.isEmpty || text.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        func rank(_ server: ConnectorServer) -> Int {
            switch states[server.name] ?? .unknown {
            case .failed: return 0
            case .needsSignIn: return 1
            case .unknown: return 2
            case .checking: return 3
            case .on: return 4
            case .off: return 5
            }
        }
        let byName: (ConnectorServer, ConnectorServer) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let visible = servers.filter { matches($0.name, $0.url ?? "", $0.command ?? "", $0.plugin ?? "") }
        let configured = Set(servers.map(\.name))
        return Groups(
            connected: visible.filter(\.enabled).sorted { rank($0) != rank($1) ? rank($0) < rank($1) : byName($0, $1) },
            available: catalog
                .filter { !$0.installed && !configured.contains($0.name) && matches($0.name, $0.description) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            off: visible.filter { !$0.enabled }.sorted(by: byName)
        )
    }
}

// MARK: - Plugins

/// An agent plugin installed for the profile (`GET /api/dashboard/plugins/hub`).
struct AgentPluginRow: Equatable, Identifiable {
    var id: String { name }
    let name: String
    var version: String?
    var description: String
    /// bundled, user, git, project or entrypoint.
    var source: String
    /// enabled, disabled or inactive.
    var runtimeStatus: String
    var canRemove: Bool
    var canUpdateGit: Bool
    /// The plugin's folder; its last component is the name Hermes' update
    /// and remove routes look the plugin up by.
    var path: String?
    var authRequired: Bool
    var authCommand: String?

    var isEnabled: Bool { runtimeStatus == "enabled" }

    /// The folder name the update and remove routes take.
    var folderName: String {
        guard let path, let last = path.split(separator: "/").last, !last.isEmpty else { return name }
        return String(last)
    }

    /// User-installed plugins (from Git or the catalog) can be updated.
    var canUpdate: Bool { canUpdateGit || canRemove }

    /// Hermes Desktop's filter: bundled plugins stay out except the two a
    /// person turns on themselves, and provider/platform plumbing stays out.
    static let listedBundled: Set<String> = ["disk-cleanup", "security-guidance"]
    static let hiddenPrefixes = ["dashboard_auth/", "model-providers/", "platforms/"]

    var isListed: Bool {
        if Self.hiddenPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
        return source != "bundled" || Self.listedBundled.contains(name)
    }

    static func list(from response: [String: Any]) -> [AgentPluginRow] {
        (response["plugins"] as? [Any] ?? []).compactMap { value in
            guard let row = value as? [String: Any], let name = row["name"] as? String else { return nil }
            return AgentPluginRow(
                name: name,
                version: (row["version"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                description: row["description"] as? String ?? "",
                source: row["source"] as? String ?? "",
                runtimeStatus: row["runtime_status"] as? String ?? "inactive",
                canRemove: row["can_remove"] as? Bool ?? false,
                canUpdateGit: row["can_update_git"] as? Bool ?? false,
                path: row["path"] as? String,
                authRequired: row["auth_required"] as? Bool ?? false,
                authCommand: (row["auth_command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        .filter(\.isListed)
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// An entry of Hermes' curated plugin catalog
/// (`GET /api/dashboard/plugins/catalog`).
struct PluginCatalogEntry: Equatable, Identifiable {
    var id: String { name }
    let name: String
    var title: String?
    var description: String
    /// official or community.
    var tier: String
    var capabilitySummary: String
    var installed: Bool
    var updateAvailable: Bool

    var displayName: String { title ?? name }

    static func list(from response: [String: Any]) -> [PluginCatalogEntry] {
        (response["entries"] as? [Any] ?? []).compactMap { value in
            guard let row = value as? [String: Any], let name = row["name"] as? String else { return nil }
            return PluginCatalogEntry(
                name: name,
                title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                description: row["description"] as? String ?? "",
                tier: row["tier"] as? String ?? "community",
                capabilitySummary: row["capability_summary"] as? String ?? "",
                installed: row["installed"] as? Bool ?? false,
                updateAvailable: row["update_available"] as? Bool ?? false
            )
        }
    }

    /// The catalog entry an installed plugin came from, matched by name or
    /// folder (the catalog name is often the repository's, not the
    /// manifest's).
    static func entry(for plugin: AgentPluginRow, in catalog: [PluginCatalogEntry]) -> PluginCatalogEntry? {
        catalog.first { isSource(named: $0.name, installed: $0.installed, of: plugin) }
    }

    /// Whether an entry, by its name and installed flag, is the one an
    /// installed plugin came from (`entry(for:in:)`'s rule).
    static func isSource(named name: String, installed: Bool, of plugin: AgentPluginRow) -> Bool {
        installed && (name == plugin.name || name == plugin.folderName)
    }
}

/// The Plugins tab's rows for a search, shared with the other tabs' match
/// counts.
enum CapabilityPluginFilter {
    static func installed(_ plugins: [AgentPluginRow], query: String) -> [AgentPluginRow] {
        plugins.filter { plugin in
            query.isEmpty
                || plugin.name.localizedCaseInsensitiveContains(query)
                || plugin.description.localizedCaseInsensitiveContains(query)
        }
    }

    /// Not installed yet, official entries first, then A-Z.
    static func catalog(_ catalog: [PluginCatalogEntry], query: String) -> [PluginCatalogEntry] {
        catalog
            .filter { !$0.installed }
            .filter { entry in
                query.isEmpty
                    || entry.displayName.localizedCaseInsensitiveContains(query)
                    || entry.description.localizedCaseInsensitiveContains(query)
            }
            .sorted { lhs, rhs in
                if (lhs.tier == "official") != (rhs.tier == "official") { return lhs.tier == "official" }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }
}

/// How many rows a search finds on each Capabilities tab, so the search
/// covers all four: the other tabs' finds show under the tab picker.
enum CapabilitySearchCounts {
    struct Sources: Equatable {
        var skills: [CapabilitySkill] = []
        var officialSkills: [OfficialSkill] = []
        var toolsets: [CapabilityToolset] = []
        var servers: [ConnectorServer] = []
        var connectorCatalog: [ConnectorCatalogEntry] = []
        var plugins: [AgentPluginRow] = []
        var pluginCatalog: [PluginCatalogEntry] = []
    }

    /// Each tab's matches, as that tab lists them. Empty for no query.
    static func counts(query: String, in sources: Sources) -> [CapabilitiesTab: Int] {
        guard !query.isEmpty else { return [:] }
        let skills = sources.skills.filter { CapabilitySkillOrdering.matches($0, query: query) }.count
            + CapabilitySkillOrdering.available(
                sources.officialSkills,
                installedNames: Set(sources.skills.map(\.name)),
                query: query
            ).count
        let tools = sources.toolsets.filter {
            CapabilityToolsetOrdering.isVisible($0) && CapabilityToolsetOrdering.matches($0, query: query)
        }.count
        let groups = ConnectorGrouping.groups(
            servers: sources.servers,
            catalog: sources.connectorCatalog,
            states: [:],
            query: query
        )
        let connectors = groups.connected.count + groups.available.count + groups.off.count
        let plugins = CapabilityPluginFilter.installed(sources.plugins, query: query).count
            + CapabilityPluginFilter.catalog(sources.pluginCatalog, query: query).count
        return [.skills: skills, .tools: tools, .connectors: connectors, .plugins: plugins]
    }
}

// MARK: - Background actions

/// Hermes runs installs as background CLI actions; their status is polled
/// at `GET /api/actions/{name}/status`.
struct HermesActionStatus: Equatable {
    var running: Bool
    var exitCode: Int?
    var lines: [String]

    init(_ dict: [String: Any]) {
        running = dict["running"] as? Bool ?? false
        exitCode = dict["exit_code"] as? Int
        lines = (dict["lines"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    var succeeded: Bool { !running && exitCode == 0 }

    /// The last meaningful line of the log, shown when the action failed.
    var failureReason: String? {
        lines.reversed()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("===") }
    }
}

enum CapabilityInstallState: Equatable {
    case running
    case failed(String)
}

// MARK: - Editing a server

/// One MCP server's entry in the profile's `mcp_servers` (config.yaml), being
/// edited (#1570). The form's fields and the JSON are two views of the same
/// entry: the form changes only the name, address, command and arguments,
/// and every other key (headers, env, tools, timeouts) is kept as written.
/// Keys Hermes saved for the server stay in .env; the entry holds only their
/// `${NAME}` references, since the config is read without expanding them.
struct ConnectorServerEdit {
    enum Problem: LocalizedError, Equatable {
        case noName
        case nameTaken(String)
        case noTarget
        case notAnObject
        case invalidJSON
        case gone(String)
        case changedOnHost(String)

        var message: String {
            switch self {
            case .noName: return AppLocalization.string("Give the server a name.")
            case .nameTaken(let name): return AppLocalization.string("Another server is already called \(name).")
            case .noTarget: return AppLocalization.string("Give the server an address or a command.")
            case .notAnObject: return AppLocalization.string("Write the server as one JSON object, such as {\"url\": \"https://…\"}.")
            case .invalidJSON: return AppLocalization.string("That isn't valid JSON.")
            case .gone(let name): return AppLocalization.string("\(name) isn't in this profile's config anymore.")
            case .changedOnHost(let name): return AppLocalization.string("\(name) changed on your host while you were editing. Close this and edit it again.")
            }
        }

        var errorDescription: String? { message }
    }

    let originalName: String
    /// The entry as it was read, to tell whether the host changed it since.
    let loaded: [String: Any]
    var name: String
    var url: String
    var command: String
    /// One argument per line.
    var arguments: String
    var json: String
    /// A server reached by address, rather than a command the host runs.
    private(set) var isRemote: Bool
    private var entry: [String: Any]
    /// The arguments as the form last showed them: untouched, the entry's
    /// own (numbers stay numbers).
    private var shownArguments: String

    init(name: String, entry: [String: Any]) {
        originalName = name
        loaded = entry
        self.name = name
        self.entry = entry
        isRemote = Self.reachedByAddress(entry)
        url = entry["url"] as? String ?? ""
        command = entry["command"] as? String ?? ""
        arguments = Self.argumentLines(entry)
        shownArguments = arguments
        json = Self.pretty(entry)
    }

    private static func reachedByAddress(_ entry: [String: Any]) -> Bool {
        entry["url"] != nil || entry["command"] == nil
    }

    private static func argumentLines(_ entry: [String: Any]) -> String {
        (entry["args"] as? [Any] ?? []).map { "\($0)" }.joined(separator: "\n")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The entry with the form's fields written in, every other key kept.
    func formEntry() throws -> [String: Any] {
        var next = entry
        if isRemote {
            let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { throw Problem.noTarget }
            next["url"] = address
        } else {
            let program = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !program.isEmpty else { throw Problem.noTarget }
            next["command"] = program
            guard arguments != shownArguments else { return next }
            // A line left exactly as it was keeps its own value (a number
            // stays a number, an empty or spaced argument stays as it is),
            // each original used once; a changed or new line is the text
            // typed, trimmed, and a blank new line is dropped.
            var unused = entry["args"] as? [Any] ?? []
            var args: [Any] = []
            for line in arguments.components(separatedBy: .newlines) {
                if let match = unused.firstIndex(where: { "\($0)" == line }) {
                    args.append(unused.remove(at: match))
                    continue
                }
                let typed = line.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty { args.append(typed) }
            }
            if args.isEmpty && entry["args"] == nil {
                next.removeValue(forKey: "args")
            } else {
                next["args"] = args
            }
        }
        return next
    }

    /// The JSON as an entry: one object with an address or a command.
    func jsonEntry() throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw Problem.invalidJSON
        }
        guard let object = parsed as? [String: Any] else { throw Problem.notAnObject }
        let hasURL = !((object["url"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let hasCommand = !((object["command"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        guard hasURL || hasCommand else { throw Problem.noTarget }
        return object
    }

    /// Moving from the form to the JSON: the JSON shows the form's changes.
    mutating func showJSON() throws {
        let next = try formEntry()
        entry = next
        json = Self.pretty(next)
    }

    /// Moving from the JSON to the form: the form shows what the JSON says.
    mutating func showForm() throws {
        let next = try jsonEntry()
        entry = next
        // The JSON may have moved it between an address and a command.
        isRemote = Self.reachedByAddress(next)
        url = next["url"] as? String ?? ""
        command = next["command"] as? String ?? ""
        arguments = Self.argumentLines(next)
        shownArguments = arguments
        json = Self.pretty(next)
    }

    /// Re-indents the JSON, when it parses.
    mutating func formatJSON() throws {
        json = Self.pretty(try jsonEntry())
    }

    /// The name and entry to save, from the form or the JSON.
    func saved(fromJSON: Bool) throws -> (name: String, entry: [String: Any]) {
        guard !trimmedName.isEmpty else { throw Problem.noName }
        return (trimmedName, fromJSON ? try jsonEntry() : try formEntry())
    }

    /// Whether saving signs an OAuth server out: Hermes keeps its tokens
    /// under the server's name.
    func renameSignsOut(auth: String?) -> Bool {
        auth == "oauth" && trimmedName != originalName && !trimmedName.isEmpty
    }

    /// The whole `mcp_servers` map with `original` replaced by `name`'s
    /// entry, read fresh just before saving: Hermes replaces the map as a
    /// whole (`PUT /api/mcp/servers`), so every other server goes back as
    /// it was on the host.
    static func replacing(
        in servers: [String: Any],
        original: String,
        loaded: [String: Any],
        name: String,
        entry: [String: Any]
    ) throws -> [String: Any] {
        guard let current = servers[original] as? [String: Any] else { throw Problem.gone(original) }
        // Written back whole, so a change the host made meanwhile would be
        // undone: refused instead.
        guard pretty(current) == pretty(loaded) else { throw Problem.changedOnHost(original) }
        if name != original, servers[name] != nil { throw Problem.nameTaken(name) }
        var next = servers
        next.removeValue(forKey: original)
        next[name] = entry
        return next
    }

    static func pretty(_ entry: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(
                withJSONObject: entry,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
