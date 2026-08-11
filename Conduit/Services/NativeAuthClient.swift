//
//  NativeAuthClient.swift
//  Conduit
//
//  Native REST authentication for password-enabled Hermes dashboards.
//

import Foundation

struct DashboardCredentials: Codable, Equatable {
    let baseURL: String
    let username: String
    let password: String
    /// Face ID is an optional gate for a saved credential, not a requirement
    /// for credential persistence itself.
    let requiresFaceID: Bool
}

enum AuthClientError: LocalizedError {
    case invalidURL
    case loginFailed(String)
    case ticketFailed(String)
    case providerDiscoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid dashboard URL."
        case .loginFailed(let detail):
            return "Login failed: \(detail)"
        case .ticketFailed(let detail):
            return "Could not get session ticket: \(detail)"
        case .providerDiscoveryFailed(let detail):
            return "Could not check dashboard sign-in options: \(detail)"
        }
    }
}

/// URLSession-based Hermes dashboard authentication. Its session uses the
/// shared cookie storage so the authenticated cookie can be copied into
/// DashboardTicketBridge's WebKit cookie store after sign-in.
struct NativeAuthClient {
    let baseURL: String
    let cloudflareAccess: CloudflareAccessCredentials?
    private let session: URLSession

    init(
        baseURL: String,
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.baseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.cloudflareAccess = cloudflareAccess
        let configuration = sessionConfiguration ?? URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        self.session = URLSession(configuration: configuration, delegate: SecureRedirectDelegate(), delegateQueue: nil)
    }

    func authProviders() async throws -> [[String: Any]] {
        let request = try request(path: "/api/auth/providers")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthClientError.providerDiscoveryFailed("No response")
        }
        switch http.statusCode {
        case 301, 302, 303, 307, 308:
            return []
        default:
            break
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.providerDiscoveryFailed(parseError(data) ?? "HTTP \(http.statusCode)")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json["providers"] as? [[String: Any]] ?? []
        }
        return []
    }

    func login(username: String, password: String) async throws {
        var request = try request(path: "/auth/password-login")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "basic",
            "username": username,
            "password": password
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthClientError.loginFailed("No response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.loginFailed(parseError(data) ?? "HTTP \(http.statusCode)")
        }
    }

    func mintWsTicket() async throws -> String {
        var request = try request(path: "/api/auth/ws-ticket")
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthClientError.ticketFailed("No response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.ticketFailed(parseError(data) ?? "HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = json["ticket"] as? String,
              !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AuthClientError.ticketFailed("No ticket in response")
        }
        return ticket
    }

    func connect(username: String, password: String) async throws -> String {
        try await login(username: username, password: password)
        return try await mintWsTicket()
    }

    private func request(path: String) throws -> URLRequest {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)\(path)") else {
            throw AuthClientError.invalidURL
        }
        return cloudflareAccess?.applying(to: URLRequest(url: url)) ?? URLRequest(url: url)
    }

    private func parseError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["detail"] as? String ?? json["error"] as? String ?? json["message"] as? String
    }
}

private final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let source = response.url ?? task.currentRequest?.url,
              let destination = request.url,
              ConnectionURLPolicy.isAllowedTransport(destination),
              ConnectionURLPolicy.originMatches(destination, expected: source) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
