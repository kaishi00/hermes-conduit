import Foundation

enum ConnectionURLPolicyError: LocalizedError, Equatable {
    case invalidURL
    case insecureTransport

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid dashboard URL."
        case .insecureTransport:
            return "Remote dashboards must use HTTPS; HTTP is allowed only for local networks (localhost, private LAN, and Tailscale)."
        }
    }
}

enum ConnectionURLPolicy {
    static func isAllowedTransport(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil else { return false }
        return scheme == "https" || (scheme == "http" && isInsecureTransportAllowed(host))
    }

    static func normalizedBaseURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.url != nil else {
            throw ConnectionURLPolicyError.invalidURL
        }

        guard scheme == "https" || scheme == "http" else {
            throw ConnectionURLPolicyError.invalidURL
        }
        if scheme == "http" && !isInsecureTransportAllowed(host) {
            throw ConnectionURLPolicyError.insecureTransport
        }

        var normalized = trimmed
        while normalized.count > scheme.count + 3, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    static func webSocketURL(
        baseURL: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let normalized = try normalizedBaseURL(baseURL)
        guard var components = URLComponents(string: normalized),
              let baseScheme = components.scheme?.lowercased() else {
            throw ConnectionURLPolicyError.invalidURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = [basePath, routePath].filter { !$0.isEmpty }.joined(separator: "/")
        components.scheme = baseScheme == "https" ? "wss" : "ws"
        components.path = "/\(joinedPath)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil
        guard let url = components.url else { throw ConnectionURLPolicyError.invalidURL }
        return url
    }

    static func originMatches(_ url: URL?, expected: URL?) -> Bool {
        guard let url,
              let expected,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let expectedScheme = expected.scheme?.lowercased(),
              let expectedHost = expected.host?.lowercased() else {
            return false
        }
        return originMatches(
            scheme: scheme,
            host: host,
            port: url.port,
            expectedScheme: expectedScheme,
            expectedHost: expectedHost,
            expectedPort: expected.port
        )
    }

    static func originMatches(
        scheme: String,
        host: String,
        port: Int,
        expected: URL?
    ) -> Bool {
        guard let expected,
              let expectedScheme = expected.scheme?.lowercased(),
              let expectedHost = expected.host?.lowercased() else {
            return false
        }
        return originMatches(
            scheme: scheme,
            host: host,
            port: port,
            expectedScheme: expectedScheme,
            expectedHost: expectedHost,
            expectedPort: expected.port
        )
    }

    private static func originMatches(
        scheme: String,
        host: String,
        port: Int?,
        expectedScheme: String,
        expectedHost: String,
        expectedPort: Int?
    ) -> Bool {
        guard scheme.lowercased() == expectedScheme,
              host.lowercased() == expectedHost else { return false }
        return effectivePort(scheme: scheme, port: port) == effectivePort(scheme: expectedScheme, port: expectedPort)
    }

    private static func effectivePort(scheme: String, port: Int?) -> Int? {
        // WKSecurityOrigin may report port 0 for default-port connections.
        // Treat 0 the same as nil so the default scheme port is used.
        if let port, port > 0 { return port }
        switch scheme.lowercased() {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    private static func isInsecureTransportAllowed(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return isLoopbackHost(host) || isPrivateLANHost(host) || isTailscaleHost(host)
    }

    private static func isLoopbackHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func isTailscaleHost(_ value: String) -> Bool {
        let host = value.lowercased()
        // Tailscale MagicDNS: <machine>.ts.net
        if host.hasSuffix(".ts.net") { return true }
        // Tailscale CGNAT range: 100.64.0.0/10 (100.64.0.0 – 100.127.255.255)
        // Require a well-formed IPv4 address to prevent label-based bypasses
        // like 100.64.attacker.example being accepted.
        guard let octets = ipv4Octets(host) else { return false }
        return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127
    }

    private static func isPrivateLANHost(_ value: String) -> Bool {
        guard let octets = ipv4Octets(value) else { return false }
        switch octets[0] {
        case 10:
            return true
        case 172:
            return (16...31).contains(octets[1])
        case 192:
            return octets[1] == 168
        default:
            return false
        }
    }

    private static func ipv4Octets(_ value: String) -> [Int]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}
