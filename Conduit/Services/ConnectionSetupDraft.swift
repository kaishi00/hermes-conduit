import Foundation

struct ConnectionSetupEndpoint: Equatable {
    var host = ""
    var port = ""
}

enum ConnectionSetupScheme: String, CaseIterable {
    case http, https
}

/// Session-only form values. Each route keeps its own inputs across Back;
/// selecting a route never consumes another route's stale fields.
struct ConnectionSetupDraft: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var accessMethod: ConnectionAccessMethod?
    var lan = ConnectionSetupEndpoint()
    var tailscale = ConnectionSetupEndpoint()
    var tailscaleScheme: ConnectionSetupScheme?
    var reverseProxyURL = ""
    var existingServerURL: String
    var usesExistingAddress: Bool
    var username: String
    var password: String

    init(existingServerURL: String = "", username: String = "", password: String = "") {
        self.existingServerURL = existingServerURL
        self.usesExistingAddress = !existingServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.username = username
        self.password = password
    }

    var methodTitle: String {
        if usesExistingAddress { return String(localized: "Current dashboard address") }
        switch accessMethod {
        case .lan: return String(localized: "Same network")
        case .tailscale: return "Tailscale"
        case .reverseProxy: return String(localized: "Existing HTTPS domain")
        case nil: return String(localized: "Choose a connection method")
        }
    }

    func result() throws -> ConnectionSetupResult {
        let address = try ConnectionSetupAddressBuilder.build(self)
        let result = ConnectionSetupResult(serverURL: address,
                                           username: username,
                                           password: password)
        guard result.hasUsableCredentials else {
            throw ConnectionSetupValidationError.credentialsRequired
        }
        return result
    }

    /// The staged connection test's target: the built address plus whatever
    /// credentials are present, without requiring them. Provider discovery —
    /// not form presence — decides whether a password applies, and an
    /// interactive-auth dashboard legitimately has none to type. Review
    /// acceptance is still strict: a credential-less draft can only complete
    /// through the interactive-auth outcome (`ConnectionSetupFlow.acceptedResult`).
    func testConfiguration() throws -> ConnectionSetupResult {
        let address = try ConnectionSetupAddressBuilder.build(self)
        return ConnectionSetupResult(serverURL: address,
                                     username: username,
                                     password: password)
    }

    // Do not let ordinary diagnostic interpolation disclose credentials or
    // an unvalidated pasted URL (which could itself contain credentials).
    var description: String { "ConnectionSetupDraft(redacted)" }
    var debugDescription: String { description }
}

struct ConnectionSetupResult: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let serverURL: String
    let username: String
    let password: String

    /// Presence-only credential check with the SAME semantic requirement as
    /// `ConnectionSetupDraft.result()`: a native password login needs both a
    /// non-empty username and a non-empty password. Presence only — the
    /// values themselves are never trimmed or rewritten. Used by the staged
    /// probe to stop at the credentials-required outcome instead of sending
    /// an empty-credential login attempt.
    var hasUsableCredentials: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var description: String { "ConnectionSetupResult(redacted)" }
    var debugDescription: String { description }
}

enum ConnectionSetupValidationError: Error, Equatable {
    case methodRequired, invalidHost, invalidPort, httpsRequired, schemeRequired, credentialsRequired
    case policy(ConnectionURLPolicyError)

    var message: String {
        switch self {
        case .methodRequired: return "Choose how this device will reach Hermes."
        case .invalidHost: return "Enter a valid host or IP address."
        case .invalidPort: return "Enter a port between 1 and 65535."
        case .httpsRequired: return "Enter the full HTTPS dashboard address."
        case .schemeRequired: return "Choose HTTP or HTTPS to match the address Hermes supplied."
        case .credentialsRequired: return "Enter your Hermes dashboard username and password."
        case .policy(let error): return error.errorDescription ?? "Enter a valid dashboard URL."
        }
    }
}

/// Constructs addresses without DNS or network I/O. Transport authorization
/// always belongs to ConnectionURLPolicy, including for preserved expert URLs.
enum ConnectionSetupAddressBuilder {
    static func build(_ draft: ConnectionSetupDraft) throws -> String {
        if draft.usesExistingAddress {
            return try fullURL(draft.existingServerURL, requireHTTPS: false)
        }
        switch draft.accessMethod {
        case .lan:
            return try endpoint(draft.lan, scheme: .http, portRequired: true)
        case .tailscale:
            let host = trimmed(draft.tailscale.host)
            let scheme: ConnectionSetupScheme
            if isServeHostname(host) {
                scheme = .https
            } else {
                // Validate the host before asking for a scheme for blank or
                // malformed input. Raw IPs never silently become HTTPS.
                try validateHost(host)
                guard let selected = draft.tailscaleScheme else {
                    throw ConnectionSetupValidationError.schemeRequired
                }
                scheme = selected
            }
            return try endpoint(draft.tailscale, scheme: scheme, portRequired: false)
        case .reverseProxy:
            return try fullURL(draft.reverseProxyURL, requireHTTPS: true)
        case nil:
            throw ConnectionSetupValidationError.methodRequired
        }
    }

    static func isServeHostname(_ host: String) -> Bool {
        trimmed(host).lowercased().hasSuffix(".ts.net")
    }

    private static func endpoint(_ input: ConnectionSetupEndpoint, scheme: ConnectionSetupScheme,
                                 portRequired: Bool) throws -> String {
        let host = trimmed(input.host)
        try validateHost(host)
        let port = try validatedPort(input.port, required: portRequired)
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        guard let address = components.url?.absoluteString else {
            throw ConnectionSetupValidationError.invalidHost
        }
        return try permitted(address)
    }

    private static func fullURL(_ input: String, requireHTTPS: Bool) throws -> String {
        let address = trimmed(input)
        guard let components = URLComponents(string: address), let host = components.host,
              !host.isEmpty else {
            throw requireHTTPS ? ConnectionSetupValidationError.httpsRequired : .policy(.invalidURL)
        }
        if requireHTTPS && components.scheme?.lowercased() != "https" {
            throw ConnectionSetupValidationError.httpsRequired
        }
        // Retain the original URL instead of round-tripping its path through
        // URLComponents: percent-encoded paths and custom ports must survive.
        if let port = components.port, !(1...65535).contains(port) {
            throw ConnectionSetupValidationError.invalidPort
        }
        return try permitted(address)
    }

    private static func permitted(_ address: String) throws -> String {
        do { return try ConnectionURLPolicy.normalizedBaseURL(address) }
        catch let error as ConnectionURLPolicyError { throw ConnectionSetupValidationError.policy(error) }
        catch { throw ConnectionSetupValidationError.policy(.invalidURL) }
    }

    private static func validatedPort(_ input: String, required: Bool) throws -> Int? {
        let value = trimmed(input)
        if value.isEmpty && !required { return nil }
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(value), (1...65535).contains(port) else {
            throw ConnectionSetupValidationError.invalidPort
        }
        return port
    }

    private static func validateHost(_ host: String) throws {
        // This is syntax checking only; no DNS resolution or trust inference.
        // Note: bracketed IPv6 literals are NOT accepted here — Foundation's
        // URL parser strips the brackets from `url.host`, so the equality
        // probe below can never match a bracketed literal and such input
        // falls through to label validation, which rejects the brackets.
        if host.hasPrefix("["), host.hasSuffix("]"),
           let url = URL(string: "http://\(host)"), url.host == host {
            return
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let valid = !host.isEmpty && host.utf8.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 }
        }
        guard valid else { throw ConnectionSetupValidationError.invalidHost }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            guard labels.count == 4, labels.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
                throw ConnectionSetupValidationError.invalidHost
            }
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
