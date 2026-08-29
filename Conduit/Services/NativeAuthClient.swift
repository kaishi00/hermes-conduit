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

/// A fully validated native authentication transaction. Cookies remain private
/// to the transaction until its caller accepts the ticket and commits them.
struct NativeAuthConnection {
    let ticket: String
    fileprivate let cookies: [HTTPCookie]

    /// Publishes this successful transaction for DashboardTicketBridge/WebKit.
    /// Calling this more than once is harmless; callers should commit only the
    /// connection they are about to make active.
    func commitCookies() {
        NativeAuthCookiePolicy.persist(cookies)
    }
}

/// URLSession-based Hermes dashboard authentication. Automatic URLSession
/// cookie handling is disabled: each login transaction captures its own
/// response cookies, scopes them to the exact ticket URL, and returns them for
/// explicit commit only after a valid ticket has been received.
struct NativeAuthClient {
    let baseURL: String
    let cloudflareAccess: CloudflareAccessCredentials?
    private let session: URLSession
    private let redirectDelegate: SecureRedirectDelegate

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
        // Every Cookie header is built from this login's captured cookies.
        // Automatic handling would let a stale shared-jar cookie authenticate
        // when the current login returned no cookie applicable to the route.
        configuration.httpShouldSetCookies = false
        let redirectDelegate = SecureRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func authProviders() async throws -> [[String: Any]] {
        let request = try request(path: "/api/auth/providers")
        let result = try await perform(request)
        guard let http = result.response as? HTTPURLResponse else {
            throw AuthClientError.providerDiscoveryFailed("No response")
        }
        switch http.statusCode {
        case 301, 302, 303, 307, 308:
            return []
        default:
            break
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.providerDiscoveryFailed(parseError(result.data) ?? "HTTP \(http.statusCode)")
        }

        if let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] {
            return json["providers"] as? [[String: Any]] ?? []
        }
        return []
    }

    func login(username: String, password: String) async throws -> [HTTPCookie] {
        var request = try request(path: "/auth/password-login")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "basic",
            "username": username,
            "password": password
        ])

        let result = try await perform(request)
        guard let http = result.response as? HTTPURLResponse else {
            throw AuthClientError.loginFailed("No response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.loginFailed(parseError(result.data) ?? "HTTP \(http.statusCode)")
        }
        guard http.url != nil else {
            throw AuthClientError.loginFailed("Response URL missing")
        }

        // Redirect responses may set the session before the final JSON landing.
        // The delegate captures those headers per URLSession task, and the final
        // response is appended last so a later rotation wins by cookie identity.
        return NativeAuthCookiePolicy.merged(
            result.redirectCookies + NativeAuthCookiePolicy.acceptedCookies(from: http)
        )
    }

    func mintWsTicket(authenticatedCookies: [HTTPCookie]) async throws -> NativeAuthConnection {
        var request = try request(path: "/api/auth/ws-ticket")
        request.httpMethod = "POST"
        guard let ticketURL = request.url else {
            throw AuthClientError.invalidURL
        }

        // Scope only this login's cookies. No shared-jar read occurs here, so a
        // stale or concurrent session can never replace an empty/missing match.
        for (name, value) in NativeAuthCookiePolicy.headerFields(
            for: authenticatedCookies,
            url: ticketURL
        ) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let result = try await perform(request)
        guard let http = result.response as? HTTPURLResponse else {
            throw AuthClientError.ticketFailed("No response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.ticketFailed(parseError(result.data) ?? "HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let ticket = json["ticket"] as? String,
              !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AuthClientError.ticketFailed("No ticket in response")
        }

        // A deployment may rotate its session while minting the ticket. Keep
        // that rotation transaction-local; the caller commits it only when this
        // ticket is accepted as the active connection.
        let committedCookies = NativeAuthCookiePolicy.merged(
            authenticatedCookies
                + result.redirectCookies
                + NativeAuthCookiePolicy.acceptedCookies(from: http)
        )
        return NativeAuthConnection(ticket: ticket, cookies: committedCookies)
    }

    func connect(username: String, password: String) async throws -> NativeAuthConnection {
        let authenticatedCookies = try await login(username: username, password: password)
        return try await mintWsTicket(authenticatedCookies: authenticatedCookies)
    }

    private func request(path: String) throws -> URLRequest {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)\(path)") else {
            throw AuthClientError.invalidURL
        }
        return cloudflareAccess?.applying(to: URLRequest(url: url)) ?? URLRequest(url: url)
    }

    private func perform(_ request: URLRequest) async throws -> NativeAuthHTTPResult {
        let holder = URLSessionTaskHolder()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    let redirectCookies = redirectDelegate.takeCookies(
                        for: holder.taskIdentifier
                    )
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    continuation.resume(returning: NativeAuthHTTPResult(
                        data: data,
                        response: response,
                        redirectCookies: redirectCookies
                    ))
                }
                holder.install(task)
                task.resume()
            }
        }, onCancel: {
            holder.cancel()
        })
    }

    private func parseError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["detail"] as? String ?? json["error"] as? String ?? json["message"] as? String
    }
}

private enum NativeAuthCookiePolicy {
    static func acceptedCookies(from response: HTTPURLResponse) -> [HTTPCookie] {
        guard let responseURL = response.url else { return [] }
        // HTTPURLResponse exposes duplicate response headers in its canonical
        // combined form. Foundation's parser handles multiple Set-Cookie lines,
        // including Expires commas; the real-transport tests pin that behavior.
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String else { return }
            result[name] = String(describing: entry.value)
        }
        return HTTPCookie.cookies(
            withResponseHeaderFields: fields,
            for: responseURL
        ).filter { accepts($0, from: responseURL) }
    }

    static func merged(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var order: [CookieIdentity] = []
        var latest: [CookieIdentity: HTTPCookie] = [:]
        for cookie in cookies {
            let identity = CookieIdentity(cookie)
            if latest[identity] == nil {
                order.append(identity)
            }
            latest[identity] = cookie
        }
        return order.compactMap { latest[$0] }
    }

    static func headerFields(for cookies: [HTTPCookie], url: URL) -> [String: String] {
        HTTPCookie.requestHeaderFields(with: applicableCookies(cookies, to: url))
    }

    static func persist(_ cookies: [HTTPCookie]) {
        for cookie in cookies {
            if let expires = cookie.expiresDate, expires <= Date() {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            } else {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    private static func accepts(_ cookie: HTTPCookie, from responseURL: URL) -> Bool {
        guard let responseHost = responseURL.host?.lowercased() else { return false }
        let canonicalDomain = canonicalDomain(cookie.domain)

        // Hermes dashboard cookies are host-scoped. Requiring the response host
        // exactly prevents a malicious/compromised dashboard from injecting a
        // cookie for a parent, sibling, public-suffix, or unrelated origin.
        guard canonicalDomain == responseHost else { return false }
        if cookie.isSecure && responseURL.scheme?.lowercased() != "https" {
            return false
        }
        if cookie.name.hasPrefix("__Host-") {
            guard cookie.isSecure,
                  cookie.path == "/",
                  !cookie.domain.hasPrefix(".") else { return false }
        } else if cookie.name.hasPrefix("__Secure-") && !cookie.isSecure {
            return false
        }
        return true
    }

    private static func applicableCookies(_ cookies: [HTTPCookie], to url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isSecureRequest = url.scheme?.lowercased() == "https"
        let now = Date()

        return cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && !isSecureRequest { return false }
            guard canonicalDomain(cookie.domain) == host else { return false }

            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            guard requestPath.hasPrefix(cookiePath) else { return false }
            if requestPath.count == cookiePath.count || cookiePath.hasSuffix("/") {
                return true
            }
            let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
            return requestPath[boundary] == "/"
        }.sorted { lhs, rhs in
            lhs.path.count > rhs.path.count
        }
    }

    private static func canonicalDomain(_ domain: String) -> String {
        domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

private struct CookieIdentity: Hashable {
    let name: String
    let domain: String
    let path: String

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        path = cookie.path.isEmpty ? "/" : cookie.path
    }
}

private struct NativeAuthHTTPResult {
    let data: Data
    let response: URLResponse
    let redirectCookies: [HTTPCookie]
}

private final class URLSessionTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancellationRequested = false

    var taskIdentifier: Int? {
        lock.lock()
        defer { lock.unlock() }
        return task?.taskIdentifier
    }

    func install(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var cookiesByTask: [Int: [HTTPCookie]] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        recordCookies(from: response, taskIdentifier: task.taskIdentifier)
        guard let source = response.url ?? task.currentRequest?.url,
              let destination = request.url,
              ConnectionURLPolicy.isAllowedTransport(destination),
              ConnectionURLPolicy.originMatches(destination, expected: source) else {
            completionHandler(nil)
            return
        }

        // URLSession cookie handling is disabled, so a password-login landing
        // receives only this task's accepted redirect cookies. Other request
        // types retain their original explicit headers unchanged.
        guard task.originalRequest?.url?.path == "/auth/password-login" else {
            completionHandler(request)
            return
        }
        var redirectedRequest = request
        let taskCookies = accumulatedCookies(for: task.taskIdentifier)
        for (name, value) in NativeAuthCookiePolicy.headerFields(
            for: taskCookies,
            url: destination
        ) {
            redirectedRequest.setValue(value, forHTTPHeaderField: name)
        }
        completionHandler(redirectedRequest)
    }

    func takeCookies(for taskIdentifier: Int?) -> [HTTPCookie] {
        guard let taskIdentifier else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return cookiesByTask.removeValue(forKey: taskIdentifier) ?? []
    }

    private func accumulatedCookies(for taskIdentifier: Int) -> [HTTPCookie] {
        lock.lock()
        defer { lock.unlock() }
        return NativeAuthCookiePolicy.merged(cookiesByTask[taskIdentifier] ?? [])
    }

    private func recordCookies(from response: HTTPURLResponse, taskIdentifier: Int) {
        let cookies = NativeAuthCookiePolicy.acceptedCookies(from: response)
        guard !cookies.isEmpty else { return }
        lock.lock()
        cookiesByTask[taskIdentifier, default: []].append(contentsOf: cookies)
        lock.unlock()
    }
}
