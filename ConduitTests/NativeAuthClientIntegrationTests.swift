import Foundation
import Network
import XCTest
@testable import Conduit

/// These suites intentionally exercise `HTTPCookieStorage.shared` because the
/// production bridge consumes the shared cookie store. Fixture domains are
/// disjoint from other test classes (loopback hosts here) and setUp/tearDown
/// scrub exactly those domains, so parallel class execution cannot
/// cross-contaminate the jar.
final class NativeAuthClientIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearLoopbackCookies()
    }

    override func tearDown() {
        clearLoopbackCookies()
        super.tearDown()
    }

    func testRealTransportSendsOnlyCurrentLoginCookiesAndPersistsTicketRotation() async throws {
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/auth/password-login":
                return .json(
                    status: 200,
                    headers: [
                        ("Set-Cookie", "hermes_session_at=fresh-access; Path=/; HttpOnly; SameSite=Lax"),
                        ("Set-Cookie", "auth_only=must-not-reach-ticket; Path=/auth; HttpOnly"),
                        ("Set-Cookie", "secure_only=must-not-cross-http; Path=/; Secure; HttpOnly"),
                        ("Set-Cookie", "expired=must-not-survive; Path=/; Expires=Wed, 09 Jun 2000 10:18:14 GMT"),
                        ("Set-Cookie", "foreign=must-not-cross-domain; Domain=conduit-auth-poison.invalid; Path=/")
                    ],
                    body: #"{"ok":true,"next":"/"}"#
                )
            case "/api/auth/ws-ticket":
                guard request.headers["cookie"] == "hermes_session_at=fresh-access" else {
                    return .json(status: 401, body: #"{"detail":"Unauthorized"}"#)
                }
                return .json(
                    status: 200,
                    headers: [
                        ("Set-Cookie", "hermes_session_at=rotated-access; Path=/; HttpOnly; SameSite=Lax")
                    ],
                    body: #"{"ticket":"real-stack-ticket"}"#
                )
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        let baseURL = "http://127.0.0.1:\(server.port)"
        seedLoopbackCookie(name: "hermes_session_at", value: "stale-access")

        let connection = try await NativeAuthClient(
            baseURL: baseURL,
            sessionConfiguration: realSessionConfiguration()
        ).connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "real-stack-ticket")
        XCTAssertEqual(
            server.lastRequest(path: "/api/auth/ws-ticket")?.headers["cookie"],
            "hermes_session_at=fresh-access"
        )
        XCTAssertFalse(
            hasLoopbackSession(value: "rotated-access"),
            "A valid but uncommitted transaction must not publish its cookies."
        )
        connection.commitCookies()
        XCTAssertTrue(
            hasLoopbackSession(value: "rotated-access"),
            "The accepted ticket response rotation must be committed for the WebKit bridge."
        )
        XCTAssertFalse(
            hasLoopbackCookie(name: "secure_only", value: "must-not-cross-http"),
            "A Secure cookie set over plain HTTP must never be published."
        )
        XCTAssertFalse(
            hasLoopbackCookie(name: "expired", value: "must-not-survive"),
            "An expired cookie must never be published."
        )
        XCTAssertFalse(
            (HTTPCookieStorage.shared.cookies ?? []).contains {
                $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "conduit-auth-poison.invalid"
            },
            "A response must not publish a cookie for an unrelated domain."
        )
    }

    func testRealTransportCarriesSessionCookieSetOnSameOriginLoginRedirect() async throws {
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/auth/password-login":
                return LoopbackHTTPResponse(
                    status: 302,
                    headers: [
                        ("Location", "/auth/password-complete"),
                        ("Set-Cookie", "hermes_session_at=redirect-access; Path=/; HttpOnly; SameSite=Lax")
                    ],
                    body: Data()
                )
            case "/auth/password-complete":
                guard request.headers["cookie"] == "hermes_session_at=redirect-access" else {
                    return .json(status: 401, body: #"{"detail":"Redirect cookie missing"}"#)
                }
                return .json(status: 200, body: #"{"ok":true,"next":"/"}"#)
            case "/api/auth/ws-ticket":
                guard request.headers["cookie"] == "hermes_session_at=redirect-access" else {
                    return .json(status: 401, body: #"{"detail":"Unauthorized"}"#)
                }
                return .json(status: 200, body: #"{"ticket":"redirect-ticket"}"#)
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        let connection = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        ).connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "redirect-ticket")
        XCTAssertEqual(
            server.lastRequest(path: "/api/auth/ws-ticket")?.headers["cookie"],
            "hermes_session_at=redirect-access"
        )
    }

    func testPathPrefixedBaseURLCarriesSessionCookieThroughRedirectAndTicket() async throws {
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/hermes/auth/password-login":
                return LoopbackHTTPResponse(
                    status: 302,
                    headers: [
                        ("Location", "/hermes/auth/password-complete"),
                        ("Set-Cookie", "hermes_session_at=prefix-redirect-access; Path=/; HttpOnly; SameSite=Lax")
                    ],
                    body: Data()
                )
            case "/hermes/auth/password-complete":
                guard request.headers["cookie"] == "hermes_session_at=prefix-redirect-access" else {
                    return .json(status: 401, body: #"{"detail":"Redirect cookie missing"}"#)
                }
                return .json(status: 200, body: #"{"ok":true,"next":"/"}"#)
            case "/hermes/api/auth/ws-ticket":
                guard request.headers["cookie"] == "hermes_session_at=prefix-redirect-access" else {
                    return .json(status: 401, body: #"{"detail":"Unauthorized"}"#)
                }
                return .json(status: 200, body: #"{"ticket":"prefix-ticket"}"#)
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        // A stale cookie that would match every request must never stand in
        // for the current transaction's cookie.
        seedLoopbackCookie(name: "hermes_session_at", value: "stale-prefix-access")

        let connection = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)/hermes",
            sessionConfiguration: realSessionConfiguration()
        ).connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "prefix-ticket")
        XCTAssertEqual(
            server.lastRequest(path: "/hermes/auth/password-complete")?.headers["cookie"],
            "hermes_session_at=prefix-redirect-access",
            "The redirect landing must receive the login cookie even with URLSession cookie handling disabled."
        )
        XCTAssertEqual(
            server.lastRequest(path: "/hermes/api/auth/ws-ticket")?.headers["cookie"],
            "hermes_session_at=prefix-redirect-access",
            "The ticket request must carry exactly the current transaction's cookie, not the stale shared one."
        )
        XCTAssertFalse(
            hasLoopbackSession(value: "prefix-redirect-access"),
            "A valid but uncommitted transaction must not publish its cookies."
        )
        connection.commitCookies()
        XCTAssertTrue(
            hasLoopbackSession(value: "prefix-redirect-access"),
            "The accepted transaction's cookie must be committed."
        )
        XCTAssertFalse(
            hasLoopbackSession(value: "stale-prefix-access"),
            "Committing the new session must supersede the stale shared cookie."
        )
    }

    func testCookiePathBoundaryRejectsNaivePrefixMatch() async throws {
        // A cookie scoped to Path=/api/auth/ws must NOT apply to
        // /api/auth/ws-ticket: the character after the cookie path is "-",
        // not "/". A naive hasPrefix matcher would leak it.
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/auth/password-login":
                return .json(
                    status: 200,
                    headers: [("Set-Cookie", "hermes_session_at=ws-scoped; Path=/api/auth/ws")],
                    body: #"{"ok":true,"next":"/"}"#
                )
            case "/api/auth/ws-ticket":
                if request.headers["cookie"] != nil {
                    return .json(status: 500, body: #"{"detail":"boundary check leaked a cookie"}"#)
                }
                return .json(status: 200, body: #"{"ticket":"boundary-ticket"}"#)
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        let connection = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        ).connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "boundary-ticket")
        XCTAssertNil(
            server.lastRequest(path: "/api/auth/ws-ticket")?.headers["cookie"],
            "A Path=/api/auth/ws cookie must not reach /api/auth/ws-ticket."
        )
    }

    func testParentCookiePathAppliesToDeeperTicketPath() async throws {
        // Path=/api is a legitimate parent of /api/auth/ws-ticket and must
        // still apply.
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/auth/password-login":
                return .json(
                    status: 200,
                    headers: [("Set-Cookie", "hermes_session_at=api-scoped; Path=/api")],
                    body: #"{"ok":true,"next":"/"}"#
                )
            case "/api/auth/ws-ticket":
                guard request.headers["cookie"] == "hermes_session_at=api-scoped" else {
                    return .json(status: 401, body: #"{"detail":"Unauthorized"}"#)
                }
                return .json(status: 200, body: #"{"ticket":"parent-path-ticket"}"#)
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        let connection = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        ).connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "parent-path-ticket")
        XCTAssertEqual(
            server.lastRequest(path: "/api/auth/ws-ticket")?.headers["cookie"],
            "hermes_session_at=api-scoped"
        )
    }

    func testCommitHonorsExpiredCookieDeletionForMatchingIdentity() async throws {
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/auth/password-login":
                return .json(
                    status: 200,
                    headers: [("Set-Cookie", "hermes_session_at=identity-flow-access; Path=/; HttpOnly")],
                    body: #"{"ok":true,"next":"/"}"#
                )
            case "/api/auth/ws-ticket":
                guard request.headers["cookie"] == "hermes_session_at=identity-flow-access" else {
                    return .json(status: 401, body: #"{"detail":"Unauthorized"}"#)
                }
                // The ticket response retires the session cookie with an
                // expired Set-Cookie for the exact login identity.
                return .json(
                    status: 200,
                    headers: [
                        ("Set-Cookie", "hermes_session_at=; Path=/; Expires=Wed, 09 Jun 2000 10:18:14 GMT")
                    ],
                    body: #"{"ticket":"identity-flow-ticket"}"#
                )
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        // Jar before authentication: a stale session with the exact identity
        // the expired response targets, a same-name cookie under a different
        // path, and an unrelated cookie.
        seedLoopbackCookie(name: "hermes_session_at", value: "stale-session")
        seedLoopbackCookie(name: "hermes_session_at", value: "other-path", path: "/other")
        seedLoopbackCookie(name: "unrelated_cookie", value: "keep-me")

        let connection = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        ).connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "identity-flow-ticket")
        XCTAssertTrue(
            hasLoopbackCookie(name: "hermes_session_at", value: "stale-session"),
            "Nothing may be published or deleted before commitCookies()."
        )

        connection.commitCookies()

        XCTAssertFalse(
            hasLoopbackCookie(name: "hermes_session_at", value: "stale-session"),
            "The expired rotation must delete the stored cookie with the same identity."
        )
        XCTAssertFalse(
            hasLoopbackCookie(name: "hermes_session_at", value: ""),
            "The expired replacement itself must not be stored."
        )
        XCTAssertFalse(
            hasLoopbackCookie(name: "hermes_session_at", path: "/"),
            "Deletion, not rotation: no cookie may remain at the retired identity."
        )
        XCTAssertTrue(
            hasLoopbackCookie(name: "hermes_session_at", value: "other-path"),
            "Deletion must be scoped to the exact path identity."
        )
        XCTAssertTrue(
            hasLoopbackCookie(name: "unrelated_cookie", value: "keep-me"),
            "Unrelated cookies must survive."
        )
    }

    func testConcurrentRedirectedLoginsCannotExchangeSessionCookies() async throws {
        let loginBarrier = TwoRequestBarrier()
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/auth/password-login":
                let username = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["username"] as? String
                guard let username else {
                    return .json(status: 400, body: #"{"detail":"Missing username"}"#)
                }
                guard loginBarrier.arriveAndWait(timeout: 5) else {
                    return .json(status: 500, body: #"{"detail":"Login overlap timed out"}"#)
                }
                return LoopbackHTTPResponse(
                    status: 302,
                    headers: [
                        ("Location", "/auth/password-complete"),
                        ("Set-Cookie", "hermes_session_at=session-\(username); Path=/; HttpOnly; SameSite=Lax")
                    ],
                    body: Data()
                )
            case "/auth/password-complete":
                guard [
                    "hermes_session_at=session-alpha",
                    "hermes_session_at=session-beta"
                ].contains(request.headers["cookie"] ?? "") else {
                    return .json(status: 401, body: #"{"detail":"Redirect cookie missing"}"#)
                }
                return .json(status: 200, body: #"{"ok":true,"next":"/"}"#)
            case "/api/auth/ws-ticket":
                switch request.headers["cookie"] {
                case "hermes_session_at=session-alpha":
                    return .json(status: 200, body: #"{"ticket":"ticket-alpha"}"#)
                case "hermes_session_at=session-beta":
                    return .json(status: 200, body: #"{"ticket":"ticket-beta"}"#)
                default:
                    return .json(status: 401, body: #"{"detail":"Unauthorized"}"#)
                }
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        let client = NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        )
        async let alpha = client.connect(username: "alpha", password: "password-a")
        async let beta = client.connect(username: "beta", password: "password-b")

        let (alphaConnection, betaConnection) = try await (alpha, beta)

        XCTAssertEqual(alphaConnection.ticket, "ticket-alpha")
        XCTAssertEqual(betaConnection.ticket, "ticket-beta")
        XCTAssertFalse(hasLoopbackSession(value: "session-alpha"))
        XCTAssertFalse(hasLoopbackSession(value: "session-beta"))

        alphaConnection.commitCookies()
        XCTAssertTrue(hasLoopbackSession(value: "session-alpha"))
        betaConnection.commitCookies()
        XCTAssertTrue(hasLoopbackSession(value: "session-beta"))
        XCTAssertFalse(hasLoopbackSession(value: "session-alpha"))
    }

    func testInvalidTicketBodyDoesNotPublishLoginOrRotationCookies() async throws {
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/auth/password-login":
                return .json(
                    status: 200,
                    headers: [
                        ("Set-Cookie", "hermes_session_at=uncommitted-login; Path=/; HttpOnly")
                    ],
                    body: #"{"ok":true,"next":"/"}"#
                )
            case "/api/auth/ws-ticket":
                return .json(
                    status: 200,
                    headers: [
                        ("Set-Cookie", "hermes_session_at=uncommitted-rotation; Path=/; HttpOnly")
                    ],
                    body: #"{"ok":true}"#
                )
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        do {
            _ = try await NativeAuthClient(
                baseURL: "http://127.0.0.1:\(server.port)",
                sessionConfiguration: realSessionConfiguration()
            ).connect(username: "chris", password: "correct-password")
            return XCTFail("Expected a ticket response without a ticket to fail")
        } catch let error as AuthClientError {
            guard case .ticketFailed(let detail) = error else {
                return XCTFail("Expected ticket failure, got \(error)")
            }
            XCTAssertEqual(detail, "No ticket in response")
        }

        XCTAssertFalse(hasLoopbackSession(value: "uncommitted-login"))
        XCTAssertFalse(hasLoopbackSession(value: "uncommitted-rotation"))
    }

    func testRedirectAndFinalCookieRotationUseOneCanonicalIdentity() async throws {
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/auth/password-login":
                return LoopbackHTTPResponse(
                    status: 302,
                    headers: [
                        ("Location", "/auth/password-complete"),
                        ("Set-Cookie", "hermes_session_at=redirect-old; Domain=localhost; Path=/; HttpOnly")
                    ],
                    body: Data()
                )
            case "/auth/password-complete":
                guard request.headers["cookie"] == "hermes_session_at=redirect-old" else {
                    return .json(status: 401, body: #"{"detail":"Redirect cookie missing"}"#)
                }
                return .json(
                    status: 200,
                    headers: [
                        ("Set-Cookie", "hermes_session_at=final-new; Path=/; HttpOnly")
                    ],
                    body: #"{"ok":true,"next":"/"}"#
                )
            case "/api/auth/ws-ticket":
                guard request.headers["cookie"] == "hermes_session_at=final-new" else {
                    return .json(status: 401, body: #"{"detail":"Duplicate or stale cookie"}"#)
                }
                return .json(status: 200, body: #"{"ticket":"canonical-ticket"}"#)
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        let connection = try await NativeAuthClient(
            baseURL: "http://localhost:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        ).connect(username: "chris", password: "correct-password")

        XCTAssertEqual(connection.ticket, "canonical-ticket")
        XCTAssertEqual(
            server.lastRequest(path: "/api/auth/ws-ticket")?.headers["cookie"],
            "hermes_session_at=final-new"
        )
    }

    func testProviderDiscoveryFollowsAllowedSameOriginRedirect() async throws {
        // Pins pre-existing semantics: an allowed same-origin redirect on
        // /api/auth/providers is consumed by the real URLSession stack, and
        // provider discovery parses the final landing response. This is the
        // behavior PR #109 was (incorrectly) claimed to have changed.
        let server = try LoopbackHTTPServer.start { request in
            switch request.path {
            case "/api/auth/providers":
                return LoopbackHTTPResponse(
                    status: 302,
                    headers: [("Location", "/api/auth/providers/redirected")],
                    body: Data()
                )
            case "/api/auth/providers/redirected":
                return .json(
                    status: 200,
                    body: #"{"providers":[{"name":"basic","supports_password":true}]}"#
                )
            default:
                return .json(status: 404, body: #"{"detail":"Not found"}"#)
            }
        }
        defer { server.stop() }

        let providers = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        ).authProviders()

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers.first?["name"] as? String, "basic")
        XCTAssertNotNil(server.lastRequest(path: "/api/auth/providers/redirected"))
    }

    private func realSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }

    private func hasLoopbackSession(value: String) -> Bool {
        hasLoopbackCookie(name: "hermes_session_at", value: value)
    }

    private func hasLoopbackCookie(name: String, value: String) -> Bool {
        (HTTPCookieStorage.shared.cookies ?? []).contains {
            $0.name == name
                && $0.value == value
                && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "127.0.0.1"
        }
    }

    private func hasLoopbackCookie(name: String, path: String) -> Bool {
        (HTTPCookieStorage.shared.cookies ?? []).contains {
            $0.name == name
                && $0.path == path
                && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "127.0.0.1"
        }
    }

    private func seedLoopbackCookie(name: String, value: String, path: String = "/") {
        guard let cookie = HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: "127.0.0.1",
            .path: path
        ]) else {
            return XCTFail("Could not create loopback fixture cookie")
        }
        HTTPCookieStorage.shared.setCookie(cookie)
    }

    private func clearLoopbackCookies() {
        let fixtureDomains = Set(["127.0.0.1", "localhost", "conduit-auth-poison.invalid"])
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if fixtureDomains.contains(domain) {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }
}

private struct LoopbackHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct LoopbackHTTPResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data

    static func json(
        status: Int,
        headers: [(String, String)] = [],
        body: String
    ) -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json")] + headers,
            body: Data(body.utf8)
        )
    }
}

private final class TwoRequestBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrivals = 0

    func arriveAndWait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        arrivals += 1
        if arrivals >= 2 {
            condition.broadcast()
            condition.unlock()
            return true
        }
        while arrivals < 2 {
            if !condition.wait(until: deadline) {
                condition.unlock()
                return false
            }
        }
        condition.unlock()
        return true
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (LoopbackHTTPRequest) -> LoopbackHTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "conduit.native-auth.loopback",
        attributes: .concurrent
    )
    private let handler: Handler
    private let lock = NSLock()
    private var requests: [LoopbackHTTPRequest] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private init(listener: NWListener, handler: @escaping Handler) {
        self.listener = listener
        self.handler = handler
    }

    static func start(handler: @escaping Handler) throws -> LoopbackHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = LoopbackHTTPServer(listener: listener, handler: handler)
        try server.startAndWaitUntilReady()
        return server
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let activeConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in activeConnections {
            connection.cancel()
        }
    }

    func lastRequest(path: String) -> LoopbackHTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last(where: { $0.path == path })
    }

    private func startAndWaitUntilReady() throws {
        let ready = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                stateLock.lock()
                startError = error
                stateLock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw NSError(
                domain: "LoopbackHTTPServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out starting loopback HTTP server"]
            )
        }
        stateLock.lock()
        let error = startError
        stateLock.unlock()
        if let error {
            listener.cancel()
            throw error
        }
        guard port != 0 else {
            listener.cancel()
            throw NSError(
                domain: "LoopbackHTTPServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Loopback HTTP server did not receive a port"]
            )
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if let request = Self.parseRequest(from: accumulated) {
                lock.lock()
                requests.append(request)
                lock.unlock()
                send(handler(request), on: connection)
                return
            }
            if error != nil || isComplete {
                remove(connection)
                connection.cancel()
                return
            }
            receive(on: connection, buffer: accumulated)
        }
    }

    private func send(_ response: LoopbackHTTPResponse, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 302: reason = "Found"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        default: reason = "Response"
        }
        var header = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for (name, value) in response.headers {
            header += "\(name): \(value)\r\n"
        }
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.remove(connection)
            connection.cancel()
        })
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private static func parseRequest(from data: Data) -> LoopbackHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return LoopbackHTTPRequest(
            method: parts[0],
            path: parts[1],
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}
