//
//  ConnectionActivity.swift
//  Conduit
//
//  The card Hermes opens in a chat when the model connects something
//  (`manage_connections` / `manage_catalog`): an app to sign in to through
//  Nous Portal, an MCP server to set up with its keys, a catalog plugin or
//  skill to install, or the apps directory with Hermes' suggestions.
//  Hermes runs the operation and waits on the card: `connection.request`
//  opens it, each change comes as `connection.update` with the whole
//  snapshot, and the card answers through `connection.respond`. As Hermes
//  Desktop's connector, MCP setup and catalog install cards.
//
//  Deliberately not Codable: the card is live-only, and a resume brings an
//  open one back from `pending_connection`. A key the user types for an
//  MCP server lives in the card's view state and goes once onto the socket.
//

import Foundation

struct ConnectionActivity: Equatable {
    /// One key an MCP install still needs (`required_env`).
    struct Field: Equatable, Identifiable {
        let name: String
        let required: Bool
        let secret: Bool
        /// A plain field's starting value. Never a secret's.
        let defaultValue: String
        let prompt: String?

        var id: String { name }
        var label: String { prompt ?? name }
    }

    struct Target: Equatable, Identifiable {
        enum Kind: String, Equatable {
            /// An app through Nous Portal: signed in on its own page.
            case connector
            /// An MCP server: set up with the keys it asks for, then maybe
            /// signed in on its own page.
            case mcp
            /// A catalog plugin or skill: installed on approval.
            case plugin
            case skill
        }

        enum State: String, Equatable {
            case pending
            /// Waiting on the browser: the page to open is minted.
            case initiated
            case connected
            case skipped
            case failed
            case expired
            case notConnected = "not_connected"
        }

        let name: String
        let kind: Kind
        /// authorize, connect, enable, install or reconnect.
        let action: String
        let state: State
        let detail: String?
        let instructions: String?
        /// The page to open, a web address only.
        let connectURL: URL?
        let connectionID: String?
        let alias: String?
        let fields: [Field]
        let displayName: String?
        let summary: String?
        /// A catalog item's tier (official, verified, community) and the
        /// catalog's security scan of it, shown as they come.
        let tier: String?
        let scanStatus: String?
        let scanSummary: String?
        /// Signed in, but Hermes couldn't list its tools.
        let discoveryError: String?
        let alreadyInstalled: Bool

        var id: String { name }

        var title: String {
            if let displayName { return displayName }
            return HostedApps.title(name)
        }

        /// Nothing more for the user to do on this row.
        var resolved: Bool { state == .connected || state == .skipped }

        /// An app's page to open: Connect.
        var opensPage: Bool {
            (state == .pending || state == .initiated) && connectURL != nil
                && (kind == .connector || kind == .mcp)
        }

        /// An app sign-in whose page went dead: Hermes mints a new one
        /// (`connectors.connect` with `reconnect`).
        var reissues: Bool {
            kind == .connector && (state == .failed || state == .expired)
        }

        /// An install or setup the user approves or skips, with the keys
        /// it asks for. A failed one is the same answer again. A pending
        /// sign-in is Hermes still minting its page.
        var asksApproval: Bool {
            guard kind != .connector, state == .pending || state == .failed || state == .expired else { return false }
            return !(state == .pending && action == "authorize")
        }
    }

    enum Status: Equatable {
        case open
        /// An answer on its way: the buttons wait for Hermes' next frame.
        case sending
        case error
    }

    let opID: String
    let sessionId: String
    /// Hermes' write counter: a frame with a lower one is older.
    let seq: Int
    let deadline: Date?
    let toolCallID: String?
    var targets: [Target]
    /// The apps directory card (`display`): no targets, these apps first.
    let suggested: [String]?
    var settled: Bool
    /// all_resolved, continue, deadline or interrupt.
    var settledBy: String?
    var status: Status = .open
    var error: String?
    /// The seq the last answer went out at; a newer frame answers it.
    var sentAtSeq: Int?
    /// The profile whose chat showed the card (AppState sets it), so an
    /// answer after a profile switch never goes out on the new profile's
    /// connection. Empty until shown.
    var profile: String = ""

    var isDisplay: Bool { suggested != nil }
    var isOpen: Bool { !settled }
    /// Waiting on the user, not on an answer already sent.
    var needsUser: Bool { isOpen && status != .sending }
    var unresolved: Bool { isDisplay || targets.contains { !$0.resolved } }

    /// The card's row text in the transcript (what a copy or a search
    /// reads). Never a key.
    static func transcriptLine(_ card: ConnectionActivity) -> String {
        if card.isDisplay { return AppLocalization.string("Hermes suggests apps to connect") }
        let names = card.targets.map(\.title)
        guard !names.isEmpty else { return AppLocalization.string("Connect apps") }
        return AppLocalization.string("Connect \(names.formatted(.list(type: .and)))")
    }

    /// A `connection.request` or `connection.update` payload, or a resume's
    /// `pending_connection`. `sessionId` is the chat's runtime session;
    /// an update names its own in `owner`.
    static func from(payload: [String: AnyCodable], sessionId: String) -> ConnectionActivity? {
        guard let opID = HostedApps.text(payload["op_id"]?.stringValue ?? "") else { return nil }
        let owner = payload["owner"]?.objectValue
        if let type = owner?["type"]?.stringValue, type != "session" { return nil }
        let session = owner?["session_id"]?.stringValue.flatMap(HostedApps.text) ?? sessionId
        guard !session.isEmpty else { return nil }
        let targets = (payload["targets"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap(target) }
        let display = payload["display"]?.objectValue
        let suggested = display.map { object in
            (object["suggested"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(HostedApps.text) }
        }
        let deadline = payload["deadline_at"]?.doubleValue.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        let settled = payload["settled"]?.boolValue ?? (payload["settled_at"]?.doubleValue != nil)
        return ConnectionActivity(
            opID: opID,
            sessionId: session,
            seq: payload["seq"]?.intValue ?? 0,
            deadline: deadline,
            toolCallID: payload["tool_call_id"]?.stringValue.flatMap(HostedApps.text),
            targets: targets,
            suggested: suggested,
            settled: settled,
            settledBy: payload["settled_by"]?.stringValue.flatMap(HostedApps.text)
        )
    }

    private static func target(_ object: [String: AnyCodable]) -> Target? {
        guard let name = object["name"]?.stringValue.flatMap(HostedApps.text) else { return nil }
        let fields: [Field] = (object["required_env"]?.arrayValue ?? []).compactMap { value in
            guard let field = value.objectValue, let name = field["name"]?.stringValue.flatMap(HostedApps.text) else { return nil }
            let secret = field["secret"]?.boolValue ?? (field["type"]?.stringValue == "secret")
            return Field(
                name: name,
                required: field["required"]?.boolValue ?? false,
                secret: secret,
                defaultValue: secret ? "" : (field["default"]?.stringValue ?? ""),
                prompt: field["prompt"]?.stringValue.flatMap(HostedApps.text)
            )
        }
        let scan = object["scan"]?.objectValue
        return Target(
            name: name,
            kind: object["kind"]?.stringValue.flatMap(Target.Kind.init(rawValue:)) ?? .connector,
            action: object["action"]?.stringValue ?? "connect",
            state: object["state"]?.stringValue.flatMap(Target.State.init(rawValue:)) ?? .pending,
            detail: object["detail"]?.stringValue.flatMap(HostedApps.text),
            instructions: object["instructions"]?.stringValue.flatMap(HostedApps.text),
            connectURL: object["connect_url"]?.stringValue.flatMap(HostedApps.webURL),
            connectionID: object["connection_id"]?.stringValue.flatMap(HostedApps.text),
            alias: object["alias"]?.stringValue.flatMap(HostedApps.text),
            fields: fields,
            displayName: object["display"]?.stringValue.flatMap(HostedApps.text),
            summary: object["description"]?.stringValue.flatMap(HostedApps.text),
            tier: object["tier"]?.stringValue.flatMap(HostedApps.text),
            scanStatus: scan?["status"]?.stringValue.flatMap(HostedApps.text),
            scanSummary: scan?["summary"]?.stringValue.flatMap(HostedApps.text),
            discoveryError: object["discovery_error"]?.stringValue.flatMap(HostedApps.text),
            alreadyInstalled: object["already_installed"]?.boolValue ?? false
        )
    }

    /// This frame over the card already shown: an older one changes
    /// nothing, and the card keeps what it holds of its own (an answer on
    /// its way, the profile, a page a later frame left out).
    func applied(over existing: ConnectionActivity) -> ConnectionActivity? {
        guard opID == existing.opID, seq >= existing.seq else { return nil }
        guard seq > existing.seq || settled != existing.settled || targets != existing.targets else { return nil }
        var next = self
        next.profile = existing.profile
        next.targets = targets.map { target in
            guard target.connectURL == nil, target.state == .initiated,
                  let held = existing.targets.first(where: { $0.name == target.name }),
                  held.state == .initiated, let url = held.connectURL else { return target }
            return Target(
                name: target.name, kind: target.kind, action: target.action, state: target.state,
                detail: target.detail, instructions: target.instructions, connectURL: url,
                connectionID: target.connectionID ?? held.connectionID, alias: target.alias,
                fields: target.fields, displayName: target.displayName, summary: target.summary,
                tier: target.tier, scanStatus: target.scanStatus, scanSummary: target.scanSummary,
                discoveryError: target.discoveryError, alreadyInstalled: target.alreadyInstalled
            )
        }
        // A newer frame answers what was sent; until then the buttons wait.
        if let sent = existing.sentAtSeq, seq <= sent, !settled {
            next.status = existing.status
            next.sentAtSeq = sent
        }
        return next
    }

    /// One row's answer: approved with the keys the user typed (only the
    /// ones with a value), or skipped.
    static func answer(name: String, approve: Bool, env: [String: String] = [:]) -> [String: Any] {
        var row: [String: Any] = ["name": name, "status": approve ? "approved" : "skipped"]
        let values = env.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if approve, !values.isEmpty { row["env"] = values }
        return row
    }

    /// Whether the keys a setup asks for are all there: every required
    /// one has a value.
    static func hasRequiredValues(_ fields: [Field], in env: [String: String]) -> Bool {
        fields.allSatisfy { field in
            !field.required || !(env[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
