import Foundation
import XCTest
@testable import Conduit

/// These tests intentionally touch `HTTPCookieStorage.shared` because the
/// production bridge consumes the shared cookie store. Fixture hosts are
/// disjoint from the loopback integration suites, and reset() (setUp/tearDown)
/// scrubs exactly the fixture domains, so parallel class execution cannot
/// cross-contaminate the jar.
final class NativeAuthClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NativeAuthURLProtocol.reset()
    }

    override func tearDown() {
        NativeAuthURLProtocol.reset()
        super.tearDown()
    }

    func testPasswordLoginCarriesReturnedSessionCookieIntoTicketRequest() async throws {
        let client = NativeAuthClient(
            baseURL: "http://192.168.1.200:9119",
            sessionConfiguration: makeSessionConfiguration()
        )

        let connection = try await client.connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "fresh-ticket")
        XCTAssertEqual(
            NativeAuthURLProtocol.requestHeader(forPath: "/api/auth/ws-ticket", name: "Cookie"),
            "hermes_session_at=test-access-token"
        )
    }

    func testNativeAuthenticationDisablesAutomaticCookieAttachment() {
        let configuration = makeSessionConfiguration()

        _ = NativeAuthClient(
            baseURL: "http://192.168.1.201:9119",
            sessionConfiguration: configuration
        )

        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testTicketRequestDoesNotFallBackToUnrelatedSharedCookie() async throws {
        let baseURL = "http://192.168.1.201:9119"
        NativeAuthURLProtocol.seedSharedCookie(
            name: "hermes_session_at",
            value: "stale-access-token",
            baseURL: baseURL
        )
        let client = NativeAuthClient(
            baseURL: baseURL,
            sessionConfiguration: makeSessionConfiguration()
        )

        do {
            _ = try await client.connect(username: "chris", password: "correct-password")
            return XCTFail("Expected the ticket request without an applicable login cookie to be rejected")
        } catch let error as AuthClientError {
            guard case .ticketFailed(let detail) = error else {
                return XCTFail("Expected ticket failure, got \(error)")
            }
            XCTAssertEqual(detail, "Unauthorized")
        }
        XCTAssertNil(
            NativeAuthURLProtocol.requestHeader(forPath: "/api/auth/ws-ticket", name: "Cookie")
        )
    }

    func testProviderDiscoveryRedirectFallsBackToWebView() async throws {
        let client = NativeAuthClient(
            baseURL: "https://redirect.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        let providers = try await client.authProviders()

        XCTAssertTrue(providers.isEmpty)
        XCTAssertEqual(NativeAuthURLProtocol.responseStatusCode(for: "redirect.example"), 302)
        XCTAssertEqual(
            NativeAuthURLProtocol.responseHeader(for: "redirect.example", name: "Location"),
            "https://tenant.cloudflareaccess.com/cdn-cgi/access/login"
        )
        XCTAssertEqual(NativeAuthURLProtocol.requestCount(for: "redirect.example"), 1)
        XCTAssertEqual(NativeAuthURLProtocol.requestCount(for: "tenant.cloudflareaccess.com"), 0)
    }

    func testProviderDiscoveryPreservesNonRedirect3xxResponses() async throws {
        let client = NativeAuthClient(
            baseURL: "https://multiple.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        do {
            _ = try await client.authProviders()
            XCTFail("Expected provider discovery to fail for a non-redirect 3xx response")
        } catch let error as AuthClientError {
            guard case .providerDiscoveryFailed(let detail) = error else {
                return XCTFail("Expected provider discovery failure, got \(error)")
            }
            XCTAssertEqual(detail, "HTTP 300")
        }
    }

    func testProviderDiscoveryParsesPasswordProvider() async throws {
        let client = NativeAuthClient(
            baseURL: "https://providers.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        let providers = try await client.authProviders()

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0]["name"] as? String, "basic")
        XCTAssertEqual(providers[0]["supports_password"] as? Bool, true)
    }

    func testProviderDiscoveryPreservesServerErrors() async throws {
        let client = NativeAuthClient(
            baseURL: "https://server-error.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        do {
            _ = try await client.authProviders()
            XCTFail("Expected provider discovery to fail for a server error")
        } catch let error as AuthClientError {
            guard case .providerDiscoveryFailed(let detail) = error else {
                return XCTFail("Expected provider discovery failure, got \(error)")
            }
            XCTAssertEqual(detail, "origin unavailable")
        }
    }

    func testProviderDiscoverySendsCloudflareAccessHeaders() async throws {
        let credentials = CloudflareAccessCredentials(
            clientID: "test-client-id",
            clientSecret: "test-client-secret"
        )
        let client = NativeAuthClient(
            baseURL: "https://headers.example",
            cloudflareAccess: credentials,
            sessionConfiguration: makeSessionConfiguration()
        )

        let providers = try await client.authProviders()

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0]["name"] as? String, "basic")
    }

    func testProviderDiscoveryUnconfiguredTokenObjectFallsBackToWebView() async throws {
        // A non-nil but empty credentials value is unconfigured: it must
        // send no Cloudflare headers and, on a Cloudflare redirect, follow
        // the normal interactive WebView fallback instead of reporting the
        // token rejected.
        let client = NativeAuthClient(
            baseURL: "https://cfreject.example",
            cloudflareAccess: CloudflareAccessCredentials(clientID: "", clientSecret: "   "),
            sessionConfiguration: makeSessionConfiguration()
        )

        let providers = try await client.authProviders()

        XCTAssertTrue(providers.isEmpty, "Unconfigured credentials must keep the WebView fallback signal")
        XCTAssertNil(
            NativeAuthURLProtocol.requestHeader(forPath: "/api/auth/providers", name: "CF-Access-Client-Id"),
            "Unconfigured credentials must send no service-token id"
        )
        XCTAssertNil(
            NativeAuthURLProtocol.requestHeader(forPath: "/api/auth/providers", name: "CF-Access-Client-Secret"),
            "Unconfigured credentials must send no service-token secret"
        )
        XCTAssertEqual(NativeAuthURLProtocol.requestCount(for: "tenant.cloudflareaccess.com"), 0)
    }

    func testProviderDiscoveryThrowsTokenRejectedWhenCloudflareRedirectsDespiteServiceToken() async throws {
        let client = NativeAuthClient(
            baseURL: "https://cfreject.example",
            cloudflareAccess: CloudflareAccessCredentials(
                clientID: "test-client-id",
                clientSecret: "super-secret-value"
            ),
            sessionConfiguration: makeSessionConfiguration()
        )

        do {
            _ = try await client.authProviders()
            XCTFail("Expected the Cloudflare redirect despite a configured token to be a typed rejection")
        } catch let error as AuthClientError {
            guard case .cloudflareServiceTokenRejected = error else {
                return XCTFail("Expected cloudflareServiceTokenRejected, got \(error)")
            }
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains("Service Auth policy"), "Diagnostic must guide the operator: \(message)")
            XCTAssertFalse(message.contains("super-secret-value"), "Diagnostic must never contain the secret")
        }
        // The rejected token must not be replayed against the Cloudflare
        // login origin: the redirect delegate cancels it before any request.
        XCTAssertEqual(NativeAuthURLProtocol.requestCount(for: "tenant.cloudflareaccess.com"), 0)
        // And the configured token still goes to the dashboard origin only.
        XCTAssertEqual(
            NativeAuthURLProtocol.requestHeader(forPath: "/api/auth/providers", name: "CF-Access-Client-Id"),
            "test-client-id"
        )
        XCTAssertEqual(
            NativeAuthURLProtocol.requestHeader(forPath: "/api/auth/providers", name: "CF-Access-Client-Secret"),
            "super-secret-value"
        )
    }

    func testProviderDiscoveryNonCloudflareRedirectWithTokenStillFallsBackToWebView() async throws {
        let client = NativeAuthClient(
            baseURL: "https://ssoedge.example",
            cloudflareAccess: CloudflareAccessCredentials(
                clientID: "test-client-id",
                clientSecret: "test-client-secret"
            ),
            sessionConfiguration: makeSessionConfiguration()
        )

        let providers = try await client.authProviders()

        // A redirect from a non-Cloudflare edge is not evidence the service
        // token was rejected; the WebView fallback must stay available.
        XCTAssertTrue(providers.isEmpty)
    }

    func testServiceTokenAppliesToLoginAndTicketRequests() async throws {
        let client = NativeAuthClient(
            baseURL: "https://cftoken.example",
            cloudflareAccess: CloudflareAccessCredentials(
                clientID: "flow-client-id",
                clientSecret: "flow-client-secret"
            ),
            sessionConfiguration: makeSessionConfiguration()
        )

        // The full shipped connect sequence: LoginView probes providers
        // first, then connects natively, then mints the ticket.
        _ = try await client.authProviders()
        let connection = try await client.connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "fresh-ticket")
        for path in ["/api/auth/providers", "/auth/password-login", "/api/auth/ws-ticket"] {
            XCTAssertEqual(
                NativeAuthURLProtocol.requestHeader(forPath: path, name: "CF-Access-Client-Id"),
                "flow-client-id",
                "\(path) must carry the service-token id"
            )
            XCTAssertEqual(
                NativeAuthURLProtocol.requestHeader(forPath: path, name: "CF-Access-Client-Secret"),
                "flow-client-secret",
                "\(path) must carry the service-token secret"
            )
        }
    }

    func testRedirectClassifierOnlyMatchesCloudflareAccessLoginOrigins() throws {
        func responseWithLocation(_ location: String?) throws -> HTTPURLResponse {
            var fields: [String: String] = [:]
            if let location { fields["Location"] = location }
            return HTTPURLResponse(
                url: URL(string: "https://dash.example/api/auth/providers")!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: fields
            )!
        }

        XCTAssertTrue(try NativeAuthClient.redirectsToCloudflareAccessLogin(
            responseWithLocation("https://tenant.cloudflareaccess.com/cdn-cgi/access/login")
        ))
        XCTAssertTrue(try NativeAuthClient.redirectsToCloudflareAccessLogin(
            responseWithLocation("https://cloudflareaccess.com/cdn-cgi/access/login")
        ))
        XCTAssertFalse(try NativeAuthClient.redirectsToCloudflareAccessLogin(
            responseWithLocation("https://evil.example/u/cloudflareaccess.com")
        ))
        XCTAssertFalse(try NativeAuthClient.redirectsToCloudflareAccessLogin(
            responseWithLocation("https://dash.example/login")
        ))
        XCTAssertFalse(try NativeAuthClient.redirectsToCloudflareAccessLogin(
            responseWithLocation(nil)
        ))
        XCTAssertFalse(try NativeAuthClient.redirectsToCloudflareAccessLogin(
            responseWithLocation("not a url")
        ))
    }

    func testHTTPLANDashboardNeverReceivesCloudflareHeadersDespiteConfiguredToken() async throws {
        // A plain-HTTP trusted-LAN dashboard with a (stale or misconfigured)
        // Cloudflare token still configured: ordinary local authentication
        // must work, and none of the native requests may carry the
        // credentials.
        let client = NativeAuthClient(
            baseURL: "http://192.168.1.202:9119",
            cloudflareAccess: CloudflareAccessCredentials(
                clientID: "lan-client-id",
                clientSecret: "lan-client-secret"
            ),
            sessionConfiguration: makeSessionConfiguration()
        )

        _ = try await client.authProviders()
        let connection = try await client.connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "lan-ticket")
        for path in ["/api/auth/providers", "/auth/password-login", "/api/auth/ws-ticket"] {
            XCTAssertNil(
                NativeAuthURLProtocol.requestHeader(forPath: path, name: "CF-Access-Client-Id"),
                "\(path) over cleartext HTTP must not carry the service-token id"
            )
            XCTAssertNil(
                NativeAuthURLProtocol.requestHeader(forPath: path, name: "CF-Access-Client-Secret"),
                "\(path) over cleartext HTTP must not carry the service-token secret"
            )
        }
    }

    func testCancelledConnectSurfacesAsCancellationError() async throws {
        let client = NativeAuthClient(
            baseURL: "https://cancel.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        let operation = Task { try await client.connect(username: "chris", password: "correct-password") }
        // Give the URLSessionTask time to start against the never-completing
        // fixture; the holder also cancels tasks installed after cancellation.
        try await Task.sleep(nanoseconds: 100_000_000)
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("Expected the cancelled connect to throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
            XCTAssertFalse(error is AuthClientError, "Cancellation must not surface as an authentication failure")
        }
    }

    func testArraySetCookieRepresentationParsesEachValueIndividually() throws {
        // Model the array-style duplicate Set-Cookie representation
        // Foundation's real transport can expose, which HTTPURLResponse's
        // public initializer cannot construct directly.
        let response = try XCTUnwrap(ArrayHeaderHTTPURLResponse(
            url: URL(string: "https://array.example/dashboard")!,
            statusCode: 200,
            fields: [
                "Content-Type": "application/json",
                "Set-Cookie": [
                    "first=one; Path=/",
                    "hermes_session_at=second; Path=/"
                ]
            ]
        ))

        let names = NativeAuthCookiePolicy.acceptedCookies(from: response).map(\.name)

        XCTAssertEqual(names, ["first", "hermes_session_at"])
    }

    func testAcceptedCookiesKeepsFoundationParserAuthorityForCombinedString() throws {
        // A single comma-joined Set-Cookie value still goes through
        // HTTPCookie's parser, including values with Expires commas.
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://array.example/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Set-Cookie": "a=1; Path=/, b=2; Path=/; Expires=Wed, 09 Jun 2100 10:18:14 GMT"
            ]
        ))

        let names = NativeAuthCookiePolicy.acceptedCookies(from: response).map(\.name)

        XCTAssertEqual(names, ["a", "b"])
    }

    func testConnectFailsDiagnosablyWhenLoginYieldsNoAcceptedCookie() async throws {
        let client = NativeAuthClient(
            baseURL: "https://cookieless.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        do {
            _ = try await client.connect(username: "chris", password: "correct-password")
            XCTFail("Expected connect to fail when no host-scoped session cookie is accepted")
        } catch let error as AuthClientError {
            guard case .ticketFailed(let detail) = error else {
                return XCTFail("Expected ticket failure, got \(error)")
            }
            XCTAssertEqual(detail, "Login succeeded but no host-scoped session cookie was accepted")
        }
    }

    func testPersistExpiredCookieDeletesOnlyMatchingCanonicalIdentity() throws {
        let storage = HTTPCookieStorage.shared
        func makeCookie(_ name: String, _ value: String, _ domain: String, _ path: String, expires: Date? = nil) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path
            ]
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }

        // Stored cookies under a fixture domain (scrubbed by reset()).
        let storedSession = makeCookie("persist_probe", "stale", "192.168.1.200", "/")
        let otherPath = makeCookie("persist_probe", "other-path", "192.168.1.200", "/other")
        let unrelated = makeCookie("persist_probe_unrelated", "keep-me", "192.168.1.200", "/")
        for cookie in [storedSession, otherPath, unrelated] {
            storage.setCookie(cookie)
        }

        // Expired parse whose domain uses the dotted canonical spelling of
        // the same host, targeting the exact stored identity.
        let expired = makeCookie(
            "persist_probe",
            "",
            ".192.168.1.200",
            "/",
            expires: Date(timeIntervalSinceNow: -60)
        )
        NativeAuthCookiePolicy.persist([expired])

        XCTAssertFalse(
            storage.cookies?.contains { $0.name == "persist_probe" && $0.path == "/" } ?? false,
            "An expired Set-Cookie must delete the stored cookie with the same canonical identity."
        )
        XCTAssertNotNil(
            storage.cookies?.first { $0.name == "persist_probe" && $0.path == "/other" },
            "Deletion must be scoped to the exact path identity."
        )
        XCTAssertNotNil(
            storage.cookies?.first { $0.name == "persist_probe_unrelated" },
            "Unrelated stored cookies must survive."
        )

        // A non-expired rotation with the same identity replaces normally.
        NativeAuthCookiePolicy.persist([makeCookie("persist_probe", "fresh", "192.168.1.200", "/")])
        XCTAssertEqual(
            storage.cookies?.first { $0.name == "persist_probe" && $0.path == "/" }?.value,
            "fresh"
        )
    }

    private func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeAuthURLProtocol.self]
        return configuration
    }
}

private final class NativeAuthURLProtocol: URLProtocol {
    private struct ResponseRecord {
        let host: String
        let statusCode: Int?
        let headers: [String: String]
    }

    private static let recordLock = NSLock()
    private static var responseRecords: [ResponseRecord] = []
    private static var requestRecords: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return [
            "192.168.1.200",
            "192.168.1.201",
            "192.168.1.202",
            "redirect.example",
            "providers.example",
            "server-error.example",
            "headers.example",
            "multiple.example",
            "tenant.cloudflareaccess.com",
            "cancel.example",
            "cookieless.example",
            "cfreject.example",
            "ssoedge.example",
            "cftoken.example"
        ].contains(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.record(request: request)
        if url.host == "cancel.example" {
            // Never completes: the cancellation test cancels the task while
            // this request is in flight.
            return
        }
        let fixture = fixture(for: request)
        Self.record(
            host: url.host ?? "",
            statusCode: fixture?.statusCode,
            headers: fixture?.headers ?? [:]
        )
        guard let fixture,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: fixture.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: fixture.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func responseStatusCode(for host: String) -> Int? {
        recordLock.lock()
        defer { recordLock.unlock() }
        return responseRecords.last(where: { $0.host == host })?.statusCode
    }

    static func responseHeader(for host: String, name: String) -> String? {
        recordLock.lock()
        defer { recordLock.unlock() }
        return responseRecords.last(where: { $0.host == host })?.headers[name]
    }

    static func requestCount(for host: String) -> Int {
        recordLock.lock()
        defer { recordLock.unlock() }
        return responseRecords.filter { $0.host == host }.count
    }

    static func requestHeader(forPath path: String, name: String) -> String? {
        recordLock.lock()
        defer { recordLock.unlock() }
        return requestRecords.last(where: { $0.url?.path == path })?.value(forHTTPHeaderField: name)
    }

    static func reset() {
        recordLock.lock()
        responseRecords.removeAll()
        requestRecords.removeAll()
        recordLock.unlock()
        let fixtureHosts = Set([
            "192.168.1.200",
            "192.168.1.201",
            "cancel.example",
            "cookieless.example"
        ])
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if fixtureHosts.contains(domain) {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    static func seedSharedCookie(name: String, value: String, baseURL: String) {
        guard let host = URL(string: baseURL)?.host,
              let cookie = HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: host,
                .path: "/"
              ]) else { return }
        HTTPCookieStorage.shared.setCookie(cookie)
    }

    private static func record(host: String, statusCode: Int?, headers: [String: String]) {
        recordLock.lock()
        responseRecords.append(ResponseRecord(host: host, statusCode: statusCode, headers: headers))
        recordLock.unlock()
    }

    private static func record(request: URLRequest) {
        recordLock.lock()
        requestRecords.append(request)
        recordLock.unlock()
    }

    private struct Fixture {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private func fixture(for request: URLRequest) -> Fixture? {
        guard let host = request.url?.host else { return nil }

        switch host {
        case "192.168.1.201":
            switch request.url?.path {
            case "/auth/password-login":
                return Fixture(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "auth_only=must-not-reach-ticket; Path=/auth; HttpOnly"
                    ],
                    body: Data(#"{"ok":true,"next":"/"}"#.utf8)
                )
            case "/api/auth/ws-ticket":
                return Fixture(
                    statusCode: 401,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"detail":"Unauthorized"}"#.utf8)
                )
            default:
                return nil
            }
        case "192.168.1.200":
            switch request.url?.path {
            case "/auth/password-login":
                return Fixture(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "hermes_session_at=test-access-token; Path=/; HttpOnly; SameSite=Lax, auth_only=must-not-leak; Path=/auth; HttpOnly"
                    ],
                    body: Data(#"{"ok":true,"next":"/"}"#.utf8)
                )
            case "/api/auth/ws-ticket":
                guard request.value(forHTTPHeaderField: "Cookie") == "hermes_session_at=test-access-token" else {
                    return Fixture(
                        statusCode: 401,
                        headers: ["Content-Type": "application/json"],
                        body: Data(#"{"detail":"Unauthorized"}"#.utf8)
                    )
                }
                return Fixture(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"ticket":"fresh-ticket"}"#.utf8)
                )
            default:
                return nil
            }
        case "192.168.1.202":
            // Plain-HTTP LAN dashboard: succeeds for ordinary Hermes auth
            // regardless of any configured Cloudflare token.
            switch request.url?.path {
            case "/api/auth/providers":
                return Fixture(statusCode: 200, headers: [:], body: providerBody())
            case "/auth/password-login":
                return Fixture(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "hermes_session_at=lan-flow-token; Path=/; HttpOnly"
                    ],
                    body: Data(#"{"ok":true,"next":"/"}"#.utf8)
                )
            case "/api/auth/ws-ticket":
                return Fixture(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"ticket":"lan-ticket"}"#.utf8)
                )
            default:
                return nil
            }
        case "redirect.example":
            return Fixture(
                statusCode: 302,
                headers: [
                    "Location": "https://tenant.cloudflareaccess.com/cdn-cgi/access/login"
                ],
                body: Data()
            )
        case "providers.example":
            return Fixture(statusCode: 200, headers: [:], body: providerBody())
        case "server-error.example":
            return Fixture(statusCode: 500, headers: [:], body: Data(#"{"error":"origin unavailable"}"#.utf8))
        case "multiple.example":
            return Fixture(statusCode: 300, headers: [:], body: Data())
        case "cookieless.example":
            switch request.url?.path {
            case "/auth/password-login":
                // Only a foreign-domain cookie: exact-host acceptance must
                // drop it, leaving the transaction with no usable cookie.
                return Fixture(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "foreign_session=unusable; Domain=cookieless-poison.invalid; Path=/"
                    ],
                    body: Data(#"{"ok":true,"next":"/"}"#.utf8)
                )
            default:
                return nil
            }
        case "headers.example":
            let hasExpectedHeaders = request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "test-client-id"
                && request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "test-client-secret"
            return hasExpectedHeaders
                ? Fixture(statusCode: 200, headers: [:], body: providerBody())
                : Fixture(statusCode: 403, headers: [:], body: Data(#"{"error":"missing Cloudflare service token"}"#.utf8))
        case "cfreject.example":
            // Cloudflare bounces the request to its Access login page even
            // though a service token was configured: the token was rejected.
            return Fixture(
                statusCode: 302,
                headers: ["Location": "https://tenant.cloudflareaccess.com/cdn-cgi/access/login"],
                body: Data()
            )
        case "ssoedge.example":
            // A non-Cloudflare edge redirect (cross-origin, so the redirect
            // delegate cancels it): not evidence of token rejection.
            return Fixture(
                statusCode: 302,
                headers: ["Location": "https://sso.example/signin"],
                body: Data()
            )
        case "cftoken.example":
            // Full native flow behind an accepting Cloudflare edge: every
            // request must carry both service-token headers or it is bounced.
            let hasToken = request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "flow-client-id"
                && request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "flow-client-secret"
            guard hasToken else {
                return Fixture(
                    statusCode: 302,
                    headers: ["Location": "https://tenant.cloudflareaccess.com/cdn-cgi/access/login"],
                    body: Data()
                )
            }
            switch request.url?.path {
            case "/api/auth/providers":
                return Fixture(statusCode: 200, headers: [:], body: providerBody())
            case "/auth/password-login":
                return Fixture(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "hermes_session_at=cf-flow-token; Path=/; HttpOnly"
                    ],
                    body: Data(#"{"ok":true,"next":"/"}"#.utf8)
                )
            case "/api/auth/ws-ticket":
                // Mirror the hardened flow: the ticket is only minted when
                // the login's host-scoped session cookie reached the request.
                guard request.value(forHTTPHeaderField: "Cookie") == "hermes_session_at=cf-flow-token" else {
                    return Fixture(
                        statusCode: 401,
                        headers: ["Content-Type": "application/json"],
                        body: Data(#"{"detail":"Unauthorized"}"#.utf8)
                    )
                }
                return Fixture(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"ticket":"fresh-ticket"}"#.utf8)
                )
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func providerBody() -> Data {
        Data(#"{"providers":[{"name":"basic","supports_password":true}]}"#.utf8)
    }
}

/// Stands in for the array-valued `allHeaderFields` that Foundation's real
/// transport can produce for duplicate Set-Cookie headers; the public
/// HTTPURLResponse initializer only accepts string values.
private final class ArrayHeaderHTTPURLResponse: HTTPURLResponse {
    private let customFields: [AnyHashable: Any]

    init?(url: URL, statusCode: Int, fields: [AnyHashable: Any]) {
        self.customFields = fields
        super.init(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var allHeaderFields: [AnyHashable: Any] {
        customFields
    }
}
