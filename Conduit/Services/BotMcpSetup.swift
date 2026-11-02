import Foundation

/// One of Hermes' bundled MCP servers (`mcp.catalog`), as the bot editor
/// offers it.
struct BotMcpCatalogEntry: Equatable, Identifiable, Codable {
    let name: String
    let description: String
    /// The keys it needs, by env var name ("GITHUB_TOKEN").
    let requires: [String]
    /// Already in the profile's config.
    let installed: Bool

    var id: String { name }
}

/// A configured server's auth (`mcp.servers.list`), without secrets.
struct BotMcpServerSummary: Equatable, Codable {
    let name: String
    let auth: String?
    let oauthTokensPresent: Bool?

    /// How it signs in is kept as `sign_in`, which the kept answers'
    /// filter doesn't take for a credential's name, as `auth` would be.
    private enum CodingKeys: String, CodingKey {
        case name, auth = "sign_in", oauthTokensPresent = "oauth_tokens_present"
    }

    /// An OAuth server with no token on Hermes: it can't connect until
    /// someone signs in.
    var needsSignIn: Bool {
        auth?.lowercased() == "oauth" && oauthTokensPresent != true
    }
}

/// What the bot editor's MCP page reads to offer the catalog and sign-ins.
struct BotMcpSetupSnapshot: Equatable {
    var catalog: [BotMcpCatalogEntry]
    var servers: [String: BotMcpServerSummary]
}

/// The copy the MCP page opens on (AppState's KeptRoute.botMcpSetup). The
/// servers go as a list: a server's name as a key could look like a
/// credential's to the kept answers' filter (`github_token`).
extension BotMcpSetupSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case catalog, servers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        catalog = try container.decode([BotMcpCatalogEntry].self, forKey: .catalog)
        let servers = try container.decode([BotMcpServerSummary].self, forKey: .servers)
        self.servers = Dictionary(servers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(catalog, forKey: .catalog)
        try container.encode(servers.values.sorted { $0.name < $1.name }, forKey: .servers)
    }
}

/// How adding a catalog server went.
enum BotMcpInstallOutcome: Equatable {
    /// Added and its test connected.
    case ready
    /// Added; it signs in with OAuth next.
    case needsSignIn
    /// Added, but its test didn't connect (the message says why).
    case addedWithProblem(String)
    /// Not added.
    case failed(String)

    var wasAdded: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// How an MCP sign-in went.
enum BotMcpSignInOutcome: Equatable {
    case signedIn
    case cancelled
    case failed(String)
}

/// The bot editor's MCP setup, as Desktop's `mcp-setup.tsx` drives it:
/// add from the catalog (`mcp.servers.add`), store its keys
/// (`mcp.servers.set_api_key`), and check it connects (`mcp.servers.test`).
/// OAuth servers sign in through a loopback on the phone whose redirect
/// Hermes finishes (`mcp.servers.oauth.*` with `client_redirect_uri`).
enum BotMcpSetup {
    /// How long a sign-in may take once Hermes has the callback.
    static let pollAttempts = 30
    /// Polls that may fail in a row before the sign-in does (Desktop's
    /// `maxPollFailures`): a dropped request isn't a refused sign-in.
    static let pollFailureLimit = 3

    static func catalog(from result: AnyCodable) -> [BotMcpCatalogEntry] {
        (payload(result)["servers"]?.arrayValue ?? []).compactMap { row in
            guard let item = row.objectValue,
                  let name = item["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return BotMcpCatalogEntry(
                name: name,
                description: item["description"]?.stringValue ?? "",
                requires: (item["requires"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty },
                installed: item["installed"]?.boolValue ?? false
            )
        }
    }

    static func servers(from result: AnyCodable) -> [BotMcpServerSummary] {
        (payload(result)["servers"]?.arrayValue ?? []).compactMap { row in
            guard let item = row.objectValue, let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
            return server(from: item, name: name)
        }
    }

    /// The server summary an `mcp.servers.add` reply carries.
    static func addedServer(from result: AnyCodable, name: String) -> BotMcpServerSummary? {
        guard let item = payload(result)["server"]?.objectValue else { return nil }
        return server(from: item, name: name)
    }

    /// The catalog entries a profile doesn't have yet, by name.
    static func offered(_ catalog: [BotMcpCatalogEntry], configured: [String]) -> [BotMcpCatalogEntry] {
        let have = Set(configured.map { $0.lowercased() })
        return catalog.filter { !have.contains($0.name.lowercased()) }
    }

    /// Whether `mcp.servers.test` connected, and its error when not.
    static func testResult(_ result: AnyCodable) -> (ok: Bool, error: String?) {
        let body = payload(result)
        let ok = body["ok"]?.boolValue ?? false
        let error = body["error"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (ok, error?.isEmpty == false ? error : nil)
    }

    /// `ok: false` with its `error_message`, as the oauth replies carry it.
    static func failure(_ result: AnyCodable) -> String? {
        let body = payload(result)
        guard body["ok"]?.boolValue == false else { return nil }
        let message = (body["error_message"]?.stringValue ?? body["error"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? AppLocalization.string("Hermes did not finish the sign-in.") : message
    }

    /// `oauth.start`'s flow id and authorization URL, once that URL sends
    /// the browser back to `redirectURI`. An older Hermes ignores the
    /// redirect and would send it to its own machine, so that one is refused.
    static func startedFlow(_ result: AnyCodable, redirectURI: String) -> (sessionID: String, authURL: URL, state: String)? {
        let body = payload(result)
        guard let sessionID = body["session_id"]?.stringValue, !sessionID.isEmpty,
              let raw = body["auth_url"]?.stringValue,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "redirect_uri" })?.value == redirectURI,
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty
        else { return nil }
        return (sessionID, url, state)
    }

    /// `oauth.callback`'s parameters from the redirect: only the keys
    /// Hermes takes, and no empty `iss` (an older Hermes refuses unknown
    /// ones).
    static func callbackParams(_ values: [String: String]) -> [String: Any] {
        var params: [String: Any] = [:]
        for key in ["code", "state", "error", "iss"] {
            if let value = values[key], !value.isEmpty { params[key] = value }
        }
        return params
    }

    /// `oauth.poll`'s status: "approved", "error" or "pending".
    static func pollStatus(_ result: AnyCodable) -> String {
        (payload(result)["status"]?.stringValue ?? "pending").lowercased()
    }

    static func pollError(_ result: AnyCodable) -> String {
        let message = (payload(result)["error_message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? AppLocalization.string("The sign-in was not approved.") : message
    }

    /// Some gateway builds wrap a reply in a second `result` (Desktop
    /// unwraps it the same way).
    static func payload(_ result: AnyCodable) -> [String: AnyCodable] {
        let object = result.objectValue ?? [:]
        if object["ok"] == nil, object["servers"] == nil, let inner = object["result"]?.objectValue {
            return inner
        }
        return object
    }

    private static func server(from item: [String: AnyCodable], name: String) -> BotMcpServerSummary {
        let auth = item["auth"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BotMcpServerSummary(
            name: name,
            auth: auth?.isEmpty == false ? auth : nil,
            oauthTokensPresent: item["oauth_tokens_present"]?.boolValue
        )
    }
}
