import Foundation
import Network
import XCTest
@testable import Conduit

/// These suites exercise the DASHBOARD-SCOPED native cookie jar (the
/// production `commitCookies(dashboardID:)` target since #148); the jar is
/// exclusively the test dashboard's, so parallel class execution cannot
/// cross-contaminate it and no scrubbing of `HTTPCookieStorage.shared` is
/// needed.
final class NativeAuthClientIntegrationTests: XCTestCase {
    /// The dashboard identity every test in this suite commits cookies under.
    let jarDashboardID = UUID()

    /// The dashboard-owned jar the tests assert against.
    var jar: HTTPCookieStorage {
        DashboardCookiePersistence.nativeCookieStorage(for: jarDashboardID)
    }
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
        connection.commitCookies(dashboardID: jarDashboardID)
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
            (jar.cookies ?? []).contains {
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
        connection.commitCookies(dashboardID: jarDashboardID)
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

        connection.commitCookies(dashboardID: jarDashboardID)

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

        alphaConnection.commitCookies(dashboardID: jarDashboardID)
        XCTAssertTrue(hasLoopbackSession(value: "session-alpha"))
        betaConnection.commitCookies(dashboardID: jarDashboardID)
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
            guard case .ticketFailed(_, let detail) = error else {
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

        let discovery = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        ).authProviderDiscovery()

        guard case .providers(let providers, _) = discovery else {
            return XCTFail("Expected a same-origin redirect to resolve to providers, got \(discovery)")
        }
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers.first?["name"] as? String, "basic")
        XCTAssertNotNil(server.lastRequest(path: "/api/auth/providers/redirected"))
    }

    func testSameOriginRedirectToASignInPortalIsInteractiveSignIn() async throws {
        // A forward-auth gate on the dashboard's own origin: Hermes is
        // mounted under /hermes and an unauthenticated request is redirected
        // to a sign-in portal on the same origin. The delegate follows that
        // redirect (same origin), lands on the portal's page, and discovery
        // reports the interactive-auth signal, as it does for a redirect to
        // another origin, rather than an unrecognized server.
        let server = try LoopbackHTTPServer.start { request in
            if request.path == "/hermes/api/auth/providers" {
                return LoopbackHTTPResponse(
                    status: 302,
                    headers: [("Location", "/portal/sign-in?rd=%2Fhermes%2Fapi%2Fauth%2Fproviders")],
                    body: Data()
                )
            }
            if request.path.hasPrefix("/portal/sign-in") {
                return LoopbackHTTPResponse(
                    status: 200,
                    headers: [("Content-Type", "text/html")],
                    body: Data("<html>sign in</html>".utf8)
                )
            }
            return .json(status: 404, body: #"{"detail":"Not found"}"#)
        }
        defer { server.stop() }

        let discovery = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)/hermes",
            sessionConfiguration: realSessionConfiguration()
        ).authProviderDiscovery()

        XCTAssertEqual(discovery, .interactiveSignInRequired)
        XCTAssertEqual(
            server.receivedRequests.map(\.path),
            ["/hermes/api/auth/providers", "/portal/sign-in?rd=%2Fhermes%2Fapi%2Fauth%2Fproviders"],
            "The same-origin redirect is followed once and nothing else is asked"
        )
    }

    func testDirectNonHermesAnswerStaysUnrecognized() async throws {
        // The same page answered directly, without a redirect, is not a
        // sign-in signal: another web app or a proxy's own page answered.
        let server = try LoopbackHTTPServer.start { _ in
            LoopbackHTTPResponse(
                status: 200,
                headers: [("Content-Type", "text/html")],
                body: Data("<html>not hermes</html>".utf8)
            )
        }
        defer { server.stop() }

        let discovery = try await NativeAuthClient(
            baseURL: "http://127.0.0.1:\(server.port)",
            sessionConfiguration: realSessionConfiguration()
        ).authProviderDiscovery()

        XCTAssertEqual(discovery, .unrecognized)
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
        (jar.cookies ?? []).contains {
            $0.name == name
                && $0.value == value
                && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "127.0.0.1"
        }
    }

    private func hasLoopbackCookie(name: String, path: String) -> Bool {
        (jar.cookies ?? []).contains {
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
        jar.setCookie(cookie)
    }

    private func clearLoopbackCookies() {
        // The dashboard-owned jar is exclusively this test's; wipe it whole.
        for cookie in jar.cookies ?? [] {
            jar.deleteCookie(cookie)
        }
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
