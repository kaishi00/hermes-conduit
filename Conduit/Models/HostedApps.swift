//
//  HostedApps.swift
//  Conduit
//
//  Settings > Capabilities > Connectors > Apps: the apps Hermes reaches
//  through Nous Portal's hosted connectors (Gmail, Slack, Notion...), the
//  Connectors page's hosted half in Hermes Desktop. Hermes and the Portal
//  hold every sign-in; the phone sees the catalog, which apps are
//  connected, each account's name and the tool switches, and opens the
//  app's own sign-in page in Safari.
//

import Foundation

/// One app in the hosted catalog (`connectors.catalog`).
struct HostedAppCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    let slug: String
    let name: String
    let description: String
    let category: String
    /// The vendor's mark as the catalog gives it, when it gives one.
    let logo: String?

    var id: String { slug }

    init(slug: String, name: String, description: String = "", category: String = "", logo: String? = nil) {
        self.slug = slug
        self.name = name
        self.description = description
        self.category = category
        self.logo = logo
    }

    init?(object: [String: AnyCodable]) {
        guard let slug = object["slug"]?.stringValue, !slug.isEmpty else { return nil }
        self.init(
            slug: slug,
            name: object["name"]?.stringValue.flatMap(HostedApps.text) ?? HostedApps.title(slug),
            description: object["description"]?.stringValue ?? "",
            category: object["category"]?.stringValue ?? "",
            logo: object["logo_url"]?.stringValue.flatMap(HostedApps.text)
        )
    }
}

/// One app's connection on this profile (`connectors.list`, owner account).
struct HostedAppStatus: Codable, Equatable, Sendable {
    let connector: String
    let enabled: Bool
    let connected: Bool
    let connectionStatus: String?
    let statusReason: String?
    let gatewayDisabledTools: [String]

    init(connector: String, enabled: Bool = true, connected: Bool, connectionStatus: String? = nil, statusReason: String? = nil, gatewayDisabledTools: [String] = []) {
        self.connector = connector
        self.enabled = enabled
        self.connected = connected
        self.connectionStatus = connectionStatus
        self.statusReason = statusReason
        self.gatewayDisabledTools = gatewayDisabledTools
    }

    init?(object: [String: AnyCodable]) {
        guard let connector = object["connector"]?.stringValue, !connector.isEmpty else { return nil }
        self.init(
            connector: connector,
            enabled: object["enabled"]?.boolValue ?? true,
            connected: object["connected"]?.boolValue ?? false,
            connectionStatus: object["connection_status"]?.stringValue,
            statusReason: object["status_reason"]?.stringValue.flatMap(HostedApps.text),
            gatewayDisabledTools: object["gateway_disabled_tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }
}

/// One signed-in account of an app (`connectors.accounts`). The label is
/// the vendor's (often the email); the alias is the name the user gave it.
struct HostedAppAccount: Codable, Equatable, Identifiable, Sendable {
    let connectionID: String
    let connector: String
    let status: String
    let statusReason: String?
    let label: String
    let alias: String?
    let active: Bool
    /// Replaced by a reconnect: kept by the Portal for the record only.
    let retired: Bool
    let createdAt: String

    var id: String { connectionID }
    /// What the account is called: its name, else the vendor's label.
    var name: String { alias.flatMap(HostedApps.text) ?? label }

    init(connectionID: String, connector: String, status: String = "active", statusReason: String? = nil, label: String, alias: String? = nil, active: Bool = true, retired: Bool = false, createdAt: String = "") {
        self.connectionID = connectionID
        self.connector = connector
        self.status = status
        self.statusReason = statusReason
        self.label = label
        self.alias = alias
        self.active = active
        self.retired = retired
        self.createdAt = createdAt
    }

    init?(object: [String: AnyCodable]) {
        guard let id = object["connection_id"]?.stringValue, !id.isEmpty,
              let connector = object["connector"]?.stringValue, !connector.isEmpty else { return nil }
        self.init(
            connectionID: id,
            connector: connector,
            status: object["status"]?.stringValue ?? "active",
            statusReason: object["status_reason"]?.stringValue.flatMap(HostedApps.text),
            label: object["label"]?.stringValue ?? connector,
            alias: object["alias"]?.stringValue,
            active: object["active"]?.boolValue ?? false,
            retired: object["disabled"]?.boolValue ?? false,
            createdAt: object["created_at"]?.stringValue ?? ""
        )
    }
}

/// The rules over which apps and tools Hermes may use
/// (`connectors.policy.get`): the member's own layer, which the switches
/// change, under any the organization or a role set, which they can't.
struct HostedAppPolicy: Codable, Equatable, Sendable {
    struct Rules: Codable, Equatable, Sendable {
        let revision: String
        /// Only these apps are allowed; nil allows every app.
        let allowed: [String]?
        let denied: [String]
        /// Per app, the tools turned off.
        let tools: [String: [String]]
        let enabledTags: [String]
        let disabledTags: [String]

        init(revision: String, allowed: [String]? = nil, denied: [String] = [], tools: [String: [String]] = [:], enabledTags: [String] = [], disabledTags: [String] = []) {
            self.revision = revision
            self.allowed = allowed
            self.denied = denied
            self.tools = tools
            self.enabledTags = enabledTags
            self.disabledTags = disabledTags
        }

        init?(layer: [String: AnyCodable]) {
            guard let body = layer["body"]?.objectValue, let mode = body["mode"]?.stringValue else { return nil }
            let revision = layer["revision"]?.stringValue ?? ""
            let tools = (body["tools"]?.objectValue ?? [:]).mapValues { $0.arrayValue?.compactMap(\.stringValue) ?? [] }
            let tags = body["tags"]?.objectValue
            let enabledTags = tags?["enable"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let disabledTags = tags?["disable"]?.arrayValue?.compactMap(\.stringValue) ?? []
            switch mode {
            case "unrestricted":
                self.init(revision: revision)
            case "deny-all":
                self.init(revision: revision, allowed: [])
            case "allow":
                self.init(revision: revision, allowed: body["connectors"]?.arrayValue?.compactMap(\.stringValue) ?? [], tools: tools, enabledTags: enabledTags, disabledTags: disabledTags)
            case "deny":
                self.init(revision: revision, denied: body["disabled_connectors"]?.arrayValue?.compactMap(\.stringValue) ?? [], tools: tools, enabledTags: enabledTags, disabledTags: disabledTags)
            default:
                return nil
            }
        }

        func allows(_ slug: String) -> Bool {
            (allowed.map { $0.contains(slug) } ?? true) && !denied.contains(slug)
        }
    }

    let member: Rules?
    let others: [Rules]

    init(member: Rules?, others: [Rules] = []) {
        self.member = member
        self.others = others
    }

    /// Nil when a layer can't be read (a mode Conduit doesn't know): the
    /// rules then count as not read, never as a layer that isn't there,
    /// which would show an app the organization turned off as on (issue
    /// 1998).
    init?(object: [String: AnyCodable]) {
        guard let layers = object["layers"]?.arrayValue else { return nil }
        var member: Rules?
        var others: [Rules] = []
        for entry in layers {
            guard let layer = entry.objectValue, let rules = Rules(layer: layer) else { return nil }
            if layer["kind"]?.stringValue == "member" {
                member = member ?? rules
            } else {
                others.append(rules)
            }
        }
        self.init(member: member, others: others)
    }

    /// The revision a change is sent against; nil when the member has no
    /// layer of their own, so the rules can only be read.
    var revision: String? { member?.revision }

    func memberEnables(_ slug: String) -> Bool { member?.allows(slug) ?? true }
    func organizationLocks(_ slug: String) -> Bool { others.contains { !$0.allows(slug) } }
    func memberDisabledTools(_ slug: String) -> [String] { member?.tools[slug] ?? [] }

    /// The app's tools the organization or a role turned off, by name or
    /// by tag, which the member's switches can't turn on.
    func organizationLockedTools(_ slug: String, tools: [HostedAppTool]) -> Set<String> {
        var locked = Set<String>()
        for rules in others {
            locked.formUnion(rules.tools[slug] ?? [])
            for tool in tools {
                let hints = Set(tool.hints)
                let offByTag = rules.disabledTags.contains { hints.contains($0) }
                let missingEveryOnTag = !rules.enabledTags.isEmpty && !rules.enabledTags.contains { hints.contains($0) }
                if offByTag || missingEveryOnTag { locked.insert(tool.slug) }
            }
        }
        return locked
    }
}

/// One of an app's tools (`connectors.tools`).
struct HostedAppTool: Equatable, Identifiable, Sendable {
    enum Facet: String, Sendable {
        case read, write, destructive, unclassified
    }

    let slug: String
    let name: String
    let description: String
    let facet: Facet
    let hints: [String]
    let deprecated: Bool

    var id: String { slug }

    init(slug: String, name: String, description: String = "", facet: Facet = .unclassified, hints: [String] = [], deprecated: Bool = false) {
        self.slug = slug
        self.name = name
        self.description = description
        self.facet = facet
        self.hints = hints
        self.deprecated = deprecated
    }

    init?(object: [String: AnyCodable]) {
        guard let slug = object["slug"]?.stringValue, !slug.isEmpty else { return nil }
        self.init(
            slug: slug,
            name: object["name"]?.stringValue.flatMap(HostedApps.text) ?? slug,
            description: object["description"]?.stringValue ?? "",
            facet: object["facet"]?.stringValue.flatMap(Facet.init(rawValue:)) ?? .unclassified,
            hints: object["hints"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            deprecated: object["deprecated"]?.boolValue ?? false
        )
    }
}

/// A sign-in Hermes opened for an app (`connectors.connect`,
/// `connectors.operation.status`): the page to open and how far it got.
struct HostedAppOperation: Equatable, Sendable {
    struct Target: Equatable, Sendable {
        let name: String
        /// pending, initiated (waiting on the browser), connected, skipped,
        /// failed, expired or not_connected.
        let state: String
        let connectURL: URL?
        let connectionID: String?
        let detail: String?

        var connected: Bool { state == "connected" }
        /// Nothing waits on a browser: the same request mints a new page.
        var retryable: Bool { state == "failed" || state == "expired" }
    }

    let id: String
    let seq: Int
    let settled: Bool
    let targets: [Target]

    init(id: String, seq: Int = 0, settled: Bool = false, targets: [Target]) {
        self.id = id
        self.seq = seq
        self.settled = settled
        self.targets = targets
    }

    init?(object: [String: AnyCodable]) {
        guard let id = object["op_id"]?.stringValue, !id.isEmpty else { return nil }
        let targets: [Target] = (object["targets"]?.arrayValue ?? []).compactMap { value in
            guard let target = value.objectValue, let name = target["name"]?.stringValue else { return nil }
            return Target(
                name: name,
                state: target["state"]?.stringValue ?? "pending",
                connectURL: target["connect_url"]?.stringValue.flatMap(HostedApps.webURL),
                connectionID: target["connection_id"]?.stringValue.flatMap(HostedApps.text),
                detail: target["detail"]?.stringValue.flatMap(HostedApps.text)
            )
        }
        self.init(
            id: id,
            seq: object["seq"]?.intValue ?? 0,
            settled: object["settled"]?.boolValue ?? false,
            targets: targets
        )
    }

    func target(_ slug: String) -> Target? { targets.first { $0.name == slug } }

    /// A later status keeps the page an earlier one gave: Hermes sends it
    /// once, with the start, until it mints a new one.
    func carryingLink(from earlier: HostedAppOperation) -> HostedAppOperation {
        HostedAppOperation(id: id, seq: seq, settled: settled, targets: targets.map { target in
            guard target.connectURL == nil, let held = earlier.target(target.name),
                  !(target.state == "initiated" && held.state != "initiated") else { return target }
            return Target(name: target.name, state: target.state, connectURL: held.connectURL,
                          connectionID: target.connectionID ?? held.connectionID, detail: target.detail)
        })
    }
}

/// What the Apps section shows: the catalog, each app's connection and
/// accounts, and the rules, as Hermes gave them. Kept so the section opens
/// on it (Screens that open on their last answer); it holds no sign-in.
struct HostedAppsSnapshot: Codable, Equatable, Sendable {
    /// Hosted apps are on for this Hermes and account.
    var available: Bool
    var catalog: [HostedAppCatalogEntry]
    var statuses: [HostedAppStatus]
    var accounts: [HostedAppAccount]
    /// Nil until the rules could be read (no Nous account yet).
    var policy: HostedAppPolicy?
    /// Hermes couldn't give the rules: the switches only read, and the
    /// section says so and offers to read them again, as Desktop does.
    /// Nil when they were read, or there are none yet.
    var rulesFailed: Bool?

    static let unavailable = HostedAppsSnapshot(available: false, catalog: [], statuses: [], accounts: [], policy: nil)

    /// Every app in the catalog or connected, joined as Hermes Desktop
    /// joins them: the catalog's name, the account that speaks for it
    /// (active first, then newest), and the rules.
    var apps: [HostedApp] {
        var slugs = catalog.map(\.slug)
        for status in statuses where !slugs.contains(status.connector) { slugs.append(status.connector) }
        return slugs.map(app)
    }

    func app(_ slug: String) -> HostedApp {
        let entry = catalog.first { $0.slug == slug }
        let status = statuses.first { $0.connector == slug }
        let mine = accounts
            .filter { $0.connector == slug && !$0.retired }
            .sorted { ($0.active ? 0 : 1, $1.createdAt) < ($1.active ? 0 : 1, $0.createdAt) }
        let account = mine.first
        let disabledTools = policy.map { $0.memberDisabledTools(slug) } ?? status?.gatewayDisabledTools ?? []
        let connected = account != nil || status?.connected == true
        let enabled = (policy?.memberEnables(slug) ?? true) && status?.enabled != false
        let state: HostedApp.State
        if policy?.organizationLocks(slug) == true {
            state = .offByOrganization
        } else if !enabled {
            state = .off
        } else if !connected {
            state = .available
        } else {
            state = HostedApp.State(status: account?.status ?? status?.connectionStatus ?? "active")
        }
        return HostedApp(
            slug: slug,
            title: entry?.name ?? HostedApps.title(slug),
            description: entry?.description ?? "",
            category: entry?.category ?? "",
            logo: HostedApps.logoURL(slug: slug, catalogLogo: entry?.logo),
            state: state,
            connected: connected,
            accounts: mine,
            disabledTools: disabledTools,
            statusReason: account?.statusReason ?? status?.statusReason
        )
    }
}

/// One app as the section shows it.
struct HostedApp: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case connected, expired, broken, connecting, available, off, offByOrganization, unknown

        /// An account's (or the list's) connection status, as Desktop maps it.
        init(status: String) {
            switch status {
            case "active": self = .connected
            case "expired", "inactive", "revoked": self = .expired
            case "failed": self = .broken
            case "pending": self = .connecting
            default: self = .unknown
            }
        }
    }

    let slug: String
    let title: String
    let description: String
    let category: String
    let logo: URL?
    let state: State
    /// An account exists, whatever its state: the app is the user's.
    let connected: Bool
    let accounts: [HostedAppAccount]
    let disabledTools: [String]
    let statusReason: String?

    var id: String { slug }
    /// Listed under Your apps rather than only in the directory.
    var isYours: Bool { connected || state == .off }
    var needsReconnect: Bool { state == .expired || state == .broken }
}

enum HostedApps {
    /// The Portal's account name format (`ConnectorAlias`).
    static func isValidAccountName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
    }

    /// Why `name` can't name an account among the app's, or nil.
    static func accountNameProblem(_ name: String, among accounts: [HostedAppAccount], renaming id: String? = nil) -> String? {
        guard isValidAccountName(name) else {
            return AppLocalization.string("Use lowercase letters, digits and dashes, up to 32, starting with a letter or digit.", table: .bots)
        }
        if accounts.contains(where: { $0.alias == name && $0.connectionID != id }) {
            return AppLocalization.string("Another account of this app already has that name.", table: .bots)
        }
        return nil
    }

    /// The app's mark: the catalog's when it gives a web address, else the
    /// vendor logo Hermes Desktop draws for the slug.
    static func logoURL(slug: String, catalogLogo: String?) -> URL? {
        if let catalogLogo, let url = webURL(catalogLogo), url.scheme == "https" { return url }
        guard let escaped = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { return nil }
        return URL(string: "https://logos.composio.dev/api/\(escaped)")
    }

    /// A name for a slug the catalog doesn't list: `google_calendar` reads
    /// Google Calendar.
    static func title(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\bMcp\b"#, with: "MCP", options: .regularExpression)
    }

    static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}
