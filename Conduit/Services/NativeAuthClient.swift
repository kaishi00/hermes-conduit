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
    /// `status` is the HTTP status the dashboard answered with, or `nil` when
    /// no HTTP response arrived. Carried on the error (rather than folded
    /// into `detail`) so failure classification is code-based: 401/403 at the
    /// password stage mean rejected credentials, while 5xx does not.
    case loginFailed(status: Int?, detail: String)
    case ticketFailed(status: Int?, detail: String)
    case providerDiscoveryFailed(status: Int?, detail: String)
    /// A configured Cloudflare Access service token did not satisfy the
    /// edge: provider discovery was still answered with a redirect to the
    /// Cloudflare Access login page. Distinct from `.loginFailed`/`.ticketFailed`
    /// so the UI can point at the token configuration instead of silently
    /// dropping the user into interactive Cloudflare sign-in.
    case cloudflareServiceTokenRejected

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid dashboard URL."
        case .loginFailed(let status, _):
            // Never expose a bare "HTTP 401" as the credential-rejection
            // message; other statuses keep the status for diagnosis (the
            // presentation layer owns user-facing copy). 429 must not read
            // as a credentials problem wherever this string surfaces.
            if status == 429 {
                return "Too many login attempts. Try again shortly."
            }
            guard let status else {
                // No HTTP response arrived; the credentials were never
                // evaluated and must not be blamed.
                return "Login failed: no response from the dashboard."
            }
            if !(401...403).contains(status) {
                return "Login failed: HTTP \(status)"
            }
            return "Login failed. Check your dashboard credentials and try again."
        case .ticketFailed(_, let detail):
            return "Could not start the Hermes session: \(detail)"
        case .providerDiscoveryFailed(_, let detail):
            return "Could not check dashboard sign-in options: \(detail)"
        case .cloudflareServiceTokenRejected:
            return "Cloudflare Access did not accept the configured service token. "
                + "Verify the Client ID / Secret and that the token is allowed by a "
                + String(localized: "Service Auth policy for this Access application, or turn off ")
                + "\"Use Cloudflare Access service token\" to sign in interactively."
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

#if DEBUG
extension NativeAuthConnection {
    /// Test/UI-test construction only: an in-memory transaction with an
    /// empty (inert) cookie set, for repair-flow seams that script a
    /// validated test without a real login. Never shipped.
    static func debugStub(ticket: String) -> NativeAuthConnection {
        NativeAuthConnection(ticket: ticket, cookies: [])
    }
}
#endif

/// What provider discovery learned about a dashboard's sign-in modes. The
/// two zero-provider shapes are deliberately different outcomes: an
/// unauthenticated redirect to a sign-in page is the NORMAL interactive-auth
/// signal, while a 2xx answer without recognizable Hermes provider structure
/// is an unexpected server response. Collapsing them back into "an empty
/// provider list" would re-create the ambiguity that made browser-auth
/// deployments unclassifiable.
enum AuthProviderDiscoveryResult {
    /// The dashboard answered `/api/auth/providers` with recognizable Hermes
    /// provider JSON. The array may be empty (a valid Hermes answer meaning
    /// "no providers configured") or name non-password providers only.
    case providers([[String: Any]])
    /// Discovery was answered by a redirect to a sign-in page — the expected
    /// unauthenticated behavior of a dashboard/edge that routes to
    /// interactive (browser) authentication.
    case interactiveSignInRequired
    /// A 2xx response arrived, but it carries no recognizable Hermes
    /// auth/provider structure: malformed JSON, a JSON object without a
    /// `providers` array, or arbitrary web content.
    case unrecognized
}

extension AuthProviderDiscoveryResult: Equatable {
    /// Provider arrays are dictionaries of JSON values, so structural
    /// equality goes through NSArray/NSDictionary's recursive isEqual. This
    /// conformance exists for tests and the typed switch above; production
    /// code never compares provider arrays for equality.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.interactiveSignInRequired, .interactiveSignInRequired),
             (.unrecognized, .unrecognized):
            return true
        case (.providers(let lhsProviders), .providers(let rhsProviders)):
            return (lhsProviders as NSArray).isEqual(to: rhsProviders)
        default:
            return false
        }
    }
}

/// The single definition of "this dashboard offers password login", shared by
/// the normal login flow and the Connection Setup probe so the compatibility
/// check can never drift between them.
enum HermesProviderCheck {
    static func supportsPassword(_ providers: [[String: Any]]) -> Bool {
        providers.contains { $0["supports_password"] as? Bool == true }
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
        // Every Cookie header is built from this login's captured cookies:
        // never let URLSession auto-accept response cookies into a jar or
        // send from one. The shared jar is written only by
        // NativeAuthConnection.commitCookies().
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.httpShouldSetCookies = false
        // Endpoint identity is derived from the normalized base URL because
        // deployments may mount the gateway under a path prefix
        // (https://example.com/hermes → /hermes/auth/password-login).
        let redirectDelegate = SecureRedirectDelegate(
            passwordLoginURL: try? Self.endpointURL(baseURL: self.baseURL, path: "/auth/password-login")
        )
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func authProviderDiscovery() async throws -> AuthProviderDiscoveryResult {
        let request = try request(path: "/api/auth/providers")
        let result = try await perform(request)
        guard let http = result.response as? HTTPURLResponse else {
            throw AuthClientError.providerDiscoveryFailed(status: nil, detail: String(localized: "No response"))
        }
        switch http.statusCode {
        case 301, 302, 303, 307, 308:
            // A redirect response without a Location header cannot drive a
            // browser login — it is a broken server response, not an auth
            // mode. Classify it as discovery failure like any other
            // non-Hermes answer.
            guard http.value(forHTTPHeaderField: "Location") != nil else {
                throw AuthClientError.providerDiscoveryFailed(
                    status: http.statusCode,
                    detail: String(localized: "Redirect without Location")
                )
            }
            // The SecureRedirectDelegate cancels cross-origin redirects, so
            // a 3xx final response here is the edge bouncing us to its
            // sign-in page. Without a configured token that is the expected
            // interactive-auth signal. With an actually configured service
            // token it means Cloudflare rejected that token — say so instead
            // of presenting the same login page that should have been
            // bypassed. Match `applying(to:)`'s configuration state: a
            // non-nil but empty credentials value sends no headers and must
            // fall back too.
            if cloudflareAccess?.isConfigured == true,
               Self.redirectsToCloudflareAccessLogin(http) {
                throw AuthClientError.cloudflareServiceTokenRejected
            }
            return .interactiveSignInRequired
        default:
            break
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.providerDiscoveryFailed(
                status: http.statusCode,
                detail: parseError(result.data) ?? "HTTP \(http.statusCode)"
            )
        }

        // A 2xx answer only means "Hermes providers" when the body carries
        // the provider array. An empty array is a valid Hermes answer; a
        // body without the array (arbitrary web content, malformed JSON) is
        // an unrecognized server response and must never read as the
        // interactive-auth signal.
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            return .unrecognized
        }
        guard let providers = json["providers"] as? [[String: Any]] else {
            return .unrecognized
        }
        return .providers(providers)
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
            throw AuthClientError.loginFailed(status: nil, detail: String(localized: "No response"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.loginFailed(
                status: http.statusCode,
                detail: parseError(result.data) ?? "HTTP \(http.statusCode)"
            )
        }
        guard http.url != nil else {
            throw AuthClientError.loginFailed(status: http.statusCode, detail: String(localized: "Response URL missing"))
        }

        // Redirect responses may set the session before the final JSON landing.
        // The delegate captures those headers per URLSession task, and the final
        // response is appended last so a later rotation wins by cookie identity.
        return NativeAuthCookiePolicy.merged(
            result.redirectCookies + NativeAuthCookiePolicy.acceptedCookies(from: http)
        )
    }

    func mintWsTicket(authenticatedCookies: [HTTPCookie]) async throws -> NativeAuthConnection {
        let ticketURL = try endpointURL(path: "/api/auth/ws-ticket")
        var request = request(url: ticketURL)
        request.httpMethod = "POST"

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
            throw AuthClientError.ticketFailed(status: nil, detail: String(localized: "No response"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthClientError.ticketFailed(
                status: http.statusCode,
                detail: parseError(result.data) ?? "HTTP \(http.statusCode)"
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let ticket = json["ticket"] as? String,
              !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AuthClientError.ticketFailed(status: http.statusCode, detail: String(localized: "No ticket in response"))
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
        guard !authenticatedCookies.isEmpty else {
            // Exact-host acceptance drops domain-scoped and foreign cookies.
            // Fail here so an operator sees why, instead of an
            // indistinguishable ticket 401 downstream.
            throw AuthClientError.ticketFailed(
                status: nil,
                detail: String(localized: "Login succeeded but no host-scoped session cookie was accepted")
            )
        }
        return try await mintWsTicket(authenticatedCookies: authenticatedCookies)
    }

    private func request(path: String) throws -> URLRequest {
        request(url: try endpointURL(path: path))
    }

    private func request(url: URL) -> URLRequest {
        cloudflareAccess?.applying(to: URLRequest(url: url)) ?? URLRequest(url: url)
    }

    private func endpointURL(path: String) throws -> URL {
        try Self.endpointURL(baseURL: baseURL, path: path)
    }

    private static func endpointURL(baseURL: String, path: String) throws -> URL {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)\(path)") else {
            throw AuthClientError.invalidURL
        }
        return url
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
                        // Cancelling the wrapping Swift task cancels the
                        // URLSessionTask, which reports URLError(.cancelled).
                        // Callers branch on CancellationError to stay silent,
                        // so restore that taxonomy without touching other
                        // transport errors.
                        if let urlError = error as? URLError, urlError.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
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

    /// True when the redirect's `Location` lands on a Cloudflare Access
    /// login origin (`*.cloudflareaccess.com`). Only such redirects may
    /// classify a configured token as rejected; redirects from other edges
    /// or from the dashboard itself keep the existing WebView fallback.
    /// A relative `Location` always resolves against the dashboard's own
    /// origin (and same-origin redirects are followed by the delegate, never
    /// reaching this classifier), so absolute-URL parsing alone is exact.
    static func redirectsToCloudflareAccessLogin(_ response: HTTPURLResponse) -> Bool {
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location),
              let host = url.host?.lowercased() else { return false }
        return host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com")
    }

    private func parseError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["detail"] as? String ?? json["error"] as? String ?? json["message"] as? String
    }
}

/// Cookie capture/publication policy for native authentication. Internal so
/// the test target can exercise header-representation handling directly.
enum NativeAuthCookiePolicy {
    static func acceptedCookies(from response: HTTPURLResponse) -> [HTTPCookie] {
        guard let responseURL = response.url else { return [] }
        // Duplicate Set-Cookie headers are collected in response order and
        // parsed individually: Foundation has exposed duplicate header values
        // as arrays on some runtimes, and comma-joining would corrupt
        // Expires dates. HTTPCookie remains the authority for cookie syntax,
        // including Expires commas.
        var setCookieValues: [String] = []
        for entry in response.allHeaderFields {
            guard let name = (entry.key as? String)?.lowercased(),
                  name == "set-cookie" else { continue }
            appendSetCookieValues(entry.value, to: &setCookieValues)
        }
        let cookies = setCookieValues.flatMap {
            HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": $0], for: responseURL)
        }
        return cookies.filter { accepts($0, from: responseURL) }
    }

    private static func appendSetCookieValues(_ value: Any, to result: inout [String]) {
        switch value {
        case let string as String:
            if !string.isEmpty { result.append(string) }
        case let strings as [String]:
            for string in strings where !string.isEmpty {
                result.append(string)
            }
        case let nested as [Any]:
            for item in nested {
                appendSetCookieValues(item, to: &result)
            }
        default:
            let description = String(describing: value)
            if !description.isEmpty { result.append(description) }
        }
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
        let now = Date()
        for cookie in cookies {
            guard let expires = cookie.expiresDate, expires <= now else {
                HTTPCookieStorage.shared.setCookie(cookie)
                continue
            }
            // An expired Set-Cookie is the server retiring that cookie
            // identity. Delete the matching stored cookies (name + canonical
            // domain + path) without inserting the expired parse itself, so
            // a committed transaction fully determines the shared state.
            let identity = CookieIdentity(cookie)
            for storedCookie in HTTPCookieStorage.shared.cookies ?? []
                where CookieIdentity(storedCookie) == identity {
                HTTPCookieStorage.shared.deleteCookie(storedCookie)
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
    /// The configured password-login endpoint, including any base-URL path
    /// prefix (https://example.com/hermes → /hermes/auth/password-login).
    private let passwordLoginURL: URL?

    init(passwordLoginURL: URL?) {
        self.passwordLoginURL = passwordLoginURL
        super.init()
    }

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
        guard isPasswordLoginTask(task) else {
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

    /// Compares the task's original request against the exact configured
    /// endpoint. A fixed absolute path comparison would miss deployments
    /// mounted under a base-URL path prefix.
    private func isPasswordLoginTask(_ task: URLSessionTask) -> Bool {
        guard let expected = passwordLoginURL,
              let original = task.originalRequest?.url else { return false }
        return original.path == expected.path
            && ConnectionURLPolicy.originMatches(original, expected: expected)
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
