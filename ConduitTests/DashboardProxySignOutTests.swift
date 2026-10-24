//
//  DashboardProxySignOutTests.swift
//  ConduitTests
//
//  A dashboard behind an oauth2-proxy-style edge whose session died: the
//  proxy answers every dashboard request with a redirect to its own sign-in
//  host and then to the identity provider. The hidden dashboard page, the
//  requests sent without it and the socket upgrade all hear that as sign-in
//  required (as Hermes' own /login landing), never as a network failure the
//  reconnect loop retries forever; the page never walks the redirect chain;
//  the app says the sign-in expired and offers Sign In Again on the sign-in
//  screen, from Reconnect, and in Settings › Connection Setup. Synthetic hosts
//  only (dashboard.example.test, sso.example.test, loopback servers).
//

import Foundation
import WebKit
import XCTest
@testable import Conduit

@MainActor
final class DashboardProxySignOutTests: XCTestCase {
    private let dashboardURL = URL(string: "https://dashboard.example.test")!

    // MARK: - The shared sign-in decision

    func testAnotherOriginIsSignIn() {
        for target in [
            "https://sso.example.test/authorize?client_id=hermes",
            "https://auth.example.test/oauth2/start?rd=%2F",
            "http://dashboard.example.test/api/status", // another scheme is another origin
            "https://dashboard.example.test:8443/api/status", // and another port
        ] {
            XCTAssertTrue(DashboardSignInRedirect.isSignIn(URL(string: target), forDashboard: dashboardURL), target)
        }
    }

    func testASignInPageOnTheDashboardsOwnOriginIsSignIn() {
        for target in [
            "https://dashboard.example.test/login",
            "https://dashboard.example.test/login?next=/chat",
            "https://dashboard.example.test/oauth2/start?rd=%2Fapi%2Fstatus",
            "https://dashboard.example.test/oauth2/sign_in",
            "https://dashboard.example.test/hermes/signin",
            "https://dashboard.example.test/hermes/login",
        ] {
            XCTAssertTrue(DashboardSignInRedirect.isSignIn(URL(string: target), forDashboard: dashboardURL), target)
        }
    }

    func testAnOrdinaryPageOnTheDashboardsOwnOriginIsNotSignIn() {
        for target in [
            "https://dashboard.example.test/api/status",
            "https://dashboard.example.test/api/status/",
            "https://dashboard.example.test/chat",
            "https://dashboard.example.test/oauth2/callback-docs",
            "https://dashboard.example.test/docs/login-guide",
            "https://dashboard.example.test/api/login-history",
            "https://dashboard.example.test/",
        ] {
            XCTAssertFalse(DashboardSignInRedirect.isSignIn(URL(string: target), forDashboard: dashboardURL), target)
        }
        XCTAssertFalse(DashboardSignInRedirect.isSignIn(nil, forDashboard: dashboardURL), "no address is not evidence")
        XCTAssertFalse(DashboardSignInRedirect.isSignIn(URL(string: "about:blank"), forDashboard: dashboardURL))
    }

    /// A dashboard saved on http behind an edge that forces TLS: the same
    /// host on https is the dashboard moving, not a sign-in, for the page,
    /// the background requests and the socket alike.
    func testTheSameHostMovingToHttpsIsSignInOnlyOnASignInPage() throws {
        let plain = try XCTUnwrap(URL(string: "http://dashboard.example.test:9119"))
        XCTAssertFalse(DashboardSignInRedirect.isSignIn(URL(string: "https://dashboard.example.test/"), forDashboard: plain))
        XCTAssertFalse(DashboardSignInRedirect.isSignIn(URL(string: "https://Dashboard.example.test/sessions"), forDashboard: plain))
        XCTAssertTrue(DashboardSignInRedirect.isSignIn(URL(string: "https://dashboard.example.test/login"), forDashboard: plain))
        XCTAssertTrue(DashboardSignInRedirect.isSignIn(URL(string: "https://sso.example.test/"), forDashboard: plain),
                      "Another host on https is still another origin")
        XCTAssertTrue(DashboardSignInRedirect.isSignIn(URL(string: "http://dashboard.example.test/"), forDashboard: dashboardURL),
                      "https moving down to http is never the same dashboard")
        XCTAssertFalse(DashboardSignInRedirect.redirectIsSignIn(
            location: "https://dashboard.example.test/api/sessions",
            from: try XCTUnwrap(URL(string: "http://dashboard.example.test:9119/api/sessions")),
            forDashboard: plain
        ))
    }

    func testARedirectLocationResolvesLikeABrowserBeforeItIsJudged() throws {
        let request = try XCTUnwrap(URL(string: "https://dashboard.example.test/api/sessions"))
        XCTAssertTrue(DashboardSignInRedirect.redirectIsSignIn(
            location: "/oauth2/start?rd=%2Fapi%2Fsessions", from: request, forDashboard: dashboardURL
        ))
        XCTAssertTrue(DashboardSignInRedirect.redirectIsSignIn(
            location: "https://sso.example.test/authorize", from: request, forDashboard: dashboardURL
        ))
        XCTAssertFalse(DashboardSignInRedirect.redirectIsSignIn(
            location: "/api/sessions/", from: request, forDashboard: dashboardURL
        ), "a same-origin redirect to an ordinary page is not sign-in")
        XCTAssertFalse(DashboardSignInRedirect.redirectIsSignIn(location: nil, from: request, forDashboard: dashboardURL))
        XCTAssertFalse(DashboardSignInRedirect.redirectIsSignIn(location: "  ", from: request, forDashboard: dashboardURL))
    }

    func testTheBackgroundSessionNeverFollowsAProxySignInRedirect() throws {
        let original = URLRequest(url: try XCTUnwrap(URL(string: "https://dashboard.example.test/api/sessions")))
        let toStart = URLRequest(url: try XCTUnwrap(URL(string: "https://dashboard.example.test/oauth2/start?rd=%2F")))
        XCTAssertNil(DashboardBackgroundSession.redirect(from: original, to: toStart))
        let toPage = URLRequest(url: try XCTUnwrap(URL(string: "https://dashboard.example.test/api/sessions/")))
        XCTAssertNotNil(DashboardBackgroundSession.redirect(from: original, to: toPage))
    }

    // MARK: - The hidden dashboard page

    private func makeBridge(_ baseURL: String = "https://dashboard.example.test") -> DashboardTicketBridge {
        let bridge = DashboardTicketBridge(
            baseURL: baseURL,
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.webViewCanRun = { true }
        addTeardownBlock { @MainActor in bridge.invalidate() }
        return bridge
    }

    func testARedirectToAnotherOriginIsCancelledAndSettlesOnSignIn() async {
        let bridge = makeBridge()

        XCTAssertEqual(
            bridge.mainFrameNavigationPolicy(for: URL(string: "https://sso.example.test/authorize?client_id=hermes")),
            .cancel,
            "The hidden page never follows the proxy to the identity provider"
        )
        XCTAssertTrue(bridge.requiresSignIn)
        XCTAssertFalse(bridge.isLoadFailed, "A sign-in redirect is not a failed load")
        XCTAssertEqual(bridge.cancelledSignInNavigationCount, 1)

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions")
            XCTFail("A page sent to sign in cannot run requests")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }
    }

    func testTheCancelledLoadsFailureCallbackKeepsTheSignInVerdict() {
        let bridge = makeBridge()
        _ = bridge.mainFrameNavigationPolicy(for: URL(string: "https://auth.example.test/oauth2/start"))

        // WebKit reports the navigation the policy cancelled as interrupted.
        bridge.webView(
            bridge.webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: "WebKitErrorDomain", code: 102)
        )

        XCTAssertTrue(bridge.requiresSignIn, "The cancellation is not a network failure")
        XCTAssertFalse(bridge.isLoadFailed)
    }

    func testALandingOnAnotherOriginIsSignIn() async {
        let bridge = makeBridge()

        XCTAssertFalse(bridge.processLanding(at: URL(string: "https://sso.example.test/authorize")))

        XCTAssertTrue(bridge.requiresSignIn)
        XCTAssertFalse(bridge.isLoadFailed, "Before, this was a failed load the reconnect loop reloaded forever")
        do {
            _ = try await bridge.requestJSON(path: "/api/auth/ws-ticket", method: "POST")
            XCTFail("No ticket is minted against a signed-out page")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }
    }

    func testALandingOnTheProxysOwnSignInPageIsSignIn() {
        let bridge = makeBridge()
        XCTAssertFalse(bridge.processLanding(at: URL(string: "https://dashboard.example.test/oauth2/sign_in")))
        XCTAssertTrue(bridge.requiresSignIn)
    }

    func testASameOriginLandingOnAnOrdinaryPageIsReady() {
        let bridge = makeBridge()

        XCTAssertEqual(bridge.mainFrameNavigationPolicy(for: URL(string: "https://dashboard.example.test/api/status")), .allow)
        XCTAssertEqual(bridge.mainFrameNavigationPolicy(for: URL(string: "https://dashboard.example.test/api/status/")), .allow)
        XCTAssertTrue(bridge.processLanding(at: URL(string: "https://dashboard.example.test/api/status/")))

        XCTAssertTrue(bridge.isReady)
        XCTAssertFalse(bridge.requiresSignIn)
        XCTAssertFalse(bridge.isLoadFailed)
        XCTAssertEqual(bridge.cancelledSignInNavigationCount, 0)
    }

    func testAReadyLandingClearsAnEarlierSignInVerdict() {
        let bridge = makeBridge()
        bridge.processLanding(at: URL(string: "https://sso.example.test/authorize"))
        XCTAssertTrue(bridge.requiresSignIn)

        // The user signed in again; the page's next load reaches the dashboard.
        bridge.processLanding(at: URL(string: "https://dashboard.example.test/api/status"))

        XCTAssertFalse(bridge.requiresSignIn)
        XCTAssertTrue(bridge.isReady)
    }

    func testAnUnknownLandingStaysAReloadableFailureNotSignIn() {
        let bridge = makeBridge()
        bridge.processLanding(at: nil)
        XCTAssertFalse(bridge.requiresSignIn)
        XCTAssertTrue(bridge.isLoadFailed)
    }

    func testAnInvalidatedBridgeNeverSettlesOnSignIn() {
        let bridge = makeBridge()
        bridge.invalidate()
        _ = bridge.mainFrameNavigationPolicy(for: URL(string: "https://sso.example.test/authorize"))
        XCTAssertFalse(bridge.requiresSignIn)
    }

    // MARK: - The real hidden page against a redirecting proxy

    /// WebKit itself, against loopback servers: the dashboard's page is
    /// redirected to another origin (localhost vs 127.0.0.1) that would send
    /// it straight back, a redirect loop. The page never follows the
    /// redirect, the mint hears sign-in required, and the page stops loading
    /// once the bounded retries are spent.
    func testARealRedirectLoopToAnotherOriginIsCancelledAndHeardAsSignIn() async throws {
        let dashboardPort = LockedPort()
        let identityProvider = try LoopbackHTTPServer.start { _ in
            .redirect(to: "http://127.0.0.1:\(dashboardPort.value)/api/status")
        }
        defer { identityProvider.stop() }
        let providerPort = identityProvider.port
        let dashboard = try LoopbackHTTPServer.start { request in
            if request.path.hasPrefix("/api/status") {
                return .redirect(to: "http://localhost:\(providerPort)/oauth2/start?rd=%2Fapi%2Fstatus")
            }
            return .json(status: 404, body: #"{"detail":"Not Found"}"#)
        }
        defer { dashboard.stop() }
        dashboardPort.value = dashboard.port
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:\(dashboard.port)",
            dashboardID: UUID(),
            readinessPollAttempts: 100,
            readinessPollInterval: .milliseconds(100)
        )
        bridge.webViewCanRun = { true }
        defer { bridge.invalidate() }

        do {
            _ = try await bridge.mintTicket()
            XCTFail("A page the proxy sends to sign in mints no ticket")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }

        XCTAssertTrue(bridge.requiresSignIn)
        XCTAssertTrue(identityProvider.receivedRequests.isEmpty, "The redirect to another origin is never followed")
        let loads = dashboard.receivedRequests.filter { $0.path.hasPrefix("/api/status") }.count
        XCTAssertGreaterThanOrEqual(loads, 1)
        XCTAssertLessThanOrEqual(loads, 3, "The first load and the two retries' reloads, no more")
        XCTAssertGreaterThanOrEqual(bridge.cancelledSignInNavigationCount, 1)

        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(
            dashboard.receivedRequests.filter { $0.path.hasPrefix("/api/status") }.count, loads,
            "The page does not keep loading on its own"
        )
    }

    /// The same real page, redirected within the dashboard to an ordinary
    /// page: ready, and the ticket is minted.
    func testARealSameOriginRedirectToAnOrdinaryPageMintsATicket() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
            switch (request.method, path) {
            case ("GET", "/api/status"):
                return .redirect(to: "/api/status/")
            case ("GET", "/api/status/"):
                return .json(status: 200, body: #"{"version":"fixture"}"#)
            case ("POST", "/api/auth/ws-ticket"):
                return .json(status: 200, body: #"{"ticket":"page-ticket"}"#)
            default:
                return .json(status: 404, body: #"{"detail":"Not Found"}"#)
            }
        }
        defer { dashboard.stop() }
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:\(dashboard.port)",
            dashboardID: UUID(),
            readinessPollAttempts: 100,
            readinessPollInterval: .milliseconds(100)
        )
        bridge.webViewCanRun = { true }
        defer { bridge.invalidate() }

        let ticket = try await bridge.mintTicket()

        XCTAssertEqual(ticket, "page-ticket")
        XCTAssertFalse(bridge.requiresSignIn)
        XCTAssertEqual(bridge.cancelledSignInNavigationCount, 0)
    }

    // MARK: - The ready page's own requests

    /// The live case: the page loaded while the proxy still had a session,
    /// then the proxy lost it (a session-store migration signed everyone
    /// out). The page's ticket request is answered with a redirect to the
    /// proxy's sign-in host, another origin. Followed, that failed like a
    /// network error ("Load failed", status 0); it is sign-in required, and
    /// the sign-in host is never contacted.
    func testAReadyPagesTicketRequestRedirectedToAnotherOriginIsSignIn() async throws {
        let identityProvider = try LoopbackHTTPServer.start { _ in
            .json(status: 200, body: #"{"ticket":"never"}"#)
        }
        defer { identityProvider.stop() }
        let dashboard = try signedOutTicketProxy(signInHostPort: identityProvider.port)
        defer { dashboard.stop() }
        let bridge = try await readyPageBridge(port: dashboard.port)

        do {
            _ = try await bridge.mintTicket()
            XCTFail("A ticket request the proxy sends to sign in mints no ticket")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }

        XCTAssertTrue(identityProvider.receivedRequests.isEmpty, "The sign-in host is never contacted")
        let tickets = dashboard.receivedRequests.filter { $0.path.hasPrefix("/api/auth/ws-ticket") }
        let posts = tickets.filter { $0.method == "POST" }.count
        XCTAssertGreaterThanOrEqual(posts, 1)
        XCTAssertLessThanOrEqual(posts, 3, "One request per bounded attempt")
        XCTAssertEqual(tickets.count - posts, posts, "Each refused redirect is probed once, with a GET")
    }

    func testAReadyPagesRequestRedirectedToTheProxysOwnSignInPageIsSignIn() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
            switch path {
            case "/api/status":
                return .json(status: 200, body: #"{"version":"fixture"}"#)
            case "/oauth2/sign_in":
                return LoopbackHTTPResponse(
                    status: 200,
                    headers: [("Content-Type", "text/html")],
                    body: Data("<html>Sign in</html>".utf8)
                )
            default:
                return .redirect(to: "/oauth2/sign_in?rd=%2Fapi%2Fsessions")
            }
        }
        defer { dashboard.stop() }
        let bridge = try await readyPageBridge(port: dashboard.port)

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions")
            XCTFail("The proxy's sign-in page is not the dashboard's answer")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }
    }

    /// Hermes answers a request it won't serve to someone signed in (a
    /// sensitive path, a file it can't write) with 403 and its reason in
    /// `detail`. That is Hermes' answer, shown as it gave it: signing in
    /// again can't change it. A proxy's own 403 page carries no such reason
    /// and is still sign-in required.
    func testAReadyPagesHermesRefusalIsNotSignIn() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
            switch path {
            case "/api/status":
                return .json(status: 200, body: #"{"version":"fixture"}"#)
            case "/api/files/write":
                return .json(status: 403, body: #"{"detail":"File is not writable"}"#)
            default:
                return LoopbackHTTPResponse(
                    status: 403,
                    headers: [("Content-Type", "text/html")],
                    body: Data("<html>Forbidden</html>".utf8)
                )
            }
        }
        defer { dashboard.stop() }
        let bridge = try await readyPageBridge(port: dashboard.port)

        do {
            _ = try await bridge.requestJSON(path: "/api/files/write", method: "POST", body: ["content": "x"])
            XCTFail("A refused write is not a success")
        } catch DashboardTicketBridgeError.http(let status, let detail) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(detail, "File is not writable")
            XCTAssertEqual(DashboardTicketBridgeError.describe(status: status, detail: detail), "File is not writable")
        } catch {
            XCTFail("Expected Hermes' refusal, got \(error)")
        }
        XCTAssertFalse(bridge.requiresSignIn)

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions")
            XCTFail("The proxy's 403 page is not the dashboard's answer")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }
    }

    func testAReadyPagesRequestFollowsASameOriginRedirectToAnOrdinaryPage() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
            switch (request.method, path) {
            case ("GET", "/api/status"):
                return .json(status: 200, body: #"{"version":"fixture"}"#)
            case ("POST", "/api/auth/ws-ticket"):
                return .redirect(status: 307, to: "/api/auth/ws-ticket/")
            case ("POST", "/api/auth/ws-ticket/"):
                return .json(status: 200, body: #"{"ticket":"followed-ticket"}"#)
            default:
                return .json(status: 404, body: #"{"detail":"Not Found"}"#)
            }
        }
        defer { dashboard.stop() }
        let bridge = try await readyPageBridge(port: dashboard.port)

        let ticket = try await bridge.mintTicket()

        XCTAssertEqual(ticket, "followed-ticket")
        XCTAssertEqual(
            dashboard.receivedRequests.filter { $0.path == "/api/auth/ws-ticket" }.count, 1,
            "A request that is answered is sent once"
        )
    }

    /// A write redirected within the dashboard (307 keeps the method and
    /// body) reaches its target once, with its body.
    func testAReadyPagesWriteFollowsASameOriginRedirectOnceWithItsBody() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            switch (request.method, request.path) {
            case ("POST", "/api/sessions/s1/title"):
                return .redirect(status: 307, to: "/api/sessions/s1/title/")
            case ("POST", "/api/sessions/s1/title/"):
                return .json(status: 200, body: #"{"ok":true}"#)
            default:
                return .json(status: 200, body: #"{"version":"fixture"}"#)
            }
        }
        defer { dashboard.stop() }
        let bridge = try await readyPageBridge(port: dashboard.port)

        let response = try await bridge.requestJSON(
            path: "/api/sessions/s1/title", method: "POST", body: ["title": "Renamed"]
        )

        XCTAssertEqual(response["ok"] as? Bool, true)
        let writes = dashboard.receivedRequests.filter { $0.path.hasPrefix("/api/sessions/s1/title") }
        XCTAssertEqual(writes.map(\.path), ["/api/sessions/s1/title", "/api/sessions/s1/title/"])
        let body = try XCTUnwrap(writes.last?.body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["title": "Renamed"])
    }

    /// A dashboard the phone can't reach is still a network failure, not a
    /// sign-out.
    func testAReadyPagesRequestThatCannotReachTheDashboardIsStillANetworkError() async throws {
        let dashboard = try LoopbackHTTPServer.start { _ in
            .json(status: 200, body: #"{"version":"fixture"}"#)
        }
        let bridge = try await readyPageBridge(port: dashboard.port)
        dashboard.stop()

        do {
            _ = try await bridge.mintTicket()
            XCTFail("An unreachable dashboard mints no ticket")
        } catch DashboardTicketBridgeError.http(let status, let detail) {
            XCTAssertEqual(status, 0)
            XCTAssertTrue(
                DashboardTicketBridgeError.describe(status: status, detail: detail).contains("couldn't reach"),
                detail
            )
        } catch {
            XCTFail("Expected a status-0 network failure, got \(error)")
        }
    }

    /// End to end with the real page: the reconnect says the sign-in
    /// expired and stops, instead of "couldn't reach your Hermes dashboard"
    /// and a reconnect every 5 seconds.
    func testAReconnectWhoseTicketRequestIsSentToSignInStopsReconnecting() async throws {
        let identityProvider = try LoopbackHTTPServer.start { _ in .status(200) }
        defer { identityProvider.stop() }
        let dashboard = try signedOutTicketProxy(signInHostPort: identityProvider.port)
        defer { dashboard.stop() }
        let bridge = try await readyPageBridge(port: dashboard.port)
        let reconnects = ReconnectLedger()
        let appState = try makeAppState(
            dashboardAddress: bridge.baseURL,
            mintTicket: { _ in try await bridge.mintTicket() },
            reconnects: reconnects
        )
        appState.connection = HermesConnection(baseUrl: bridge.baseURL, ticket: "spent")
        appState.showLogin = false

        await appState.reconnect()

        XCTAssertTrue(appState.showLogin)
        XCTAssertEqual(appState.pendingLoginFailure, .signInExpired)
        XCTAssertEqual(appState.lastConnectionFailure, .loginRequired)
        XCTAssertNil(appState.errorMessage)
        XCTAssertNil(appState.connection)
        XCTAssertTrue(reconnects.scheduledDelays.isEmpty, "No reconnect is scheduled")
        // A sanity check on the page itself: nothing it runs keeps asking.
        let tickets = ticketRequests(dashboard)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(ticketRequests(dashboard), tickets, "Nothing keeps asking for a ticket")
        XCTAssertTrue(identityProvider.receivedRequests.isEmpty)
    }

    func testAReconnectThatCannotReachTheDashboardStillRetries() async throws {
        let dashboard = try LoopbackHTTPServer.start { _ in
            .json(status: 200, body: #"{"version":"fixture"}"#)
        }
        let bridge = try await readyPageBridge(port: dashboard.port)
        dashboard.stop()
        let reconnects = ReconnectLedger()
        let appState = try makeAppState(
            dashboardAddress: bridge.baseURL,
            mintTicket: { _ in try await bridge.mintTicket() },
            reconnects: reconnects
        )
        appState.connection = HermesConnection(baseUrl: bridge.baseURL, ticket: "spent")
        appState.showLogin = false

        await appState.reconnect()

        XCTAssertFalse(appState.showLogin)
        XCTAssertNil(appState.pendingLoginFailure)
        XCTAssertTrue(appState.errorMessage?.contains("couldn't reach") == true, appState.errorMessage ?? "nil")
        XCTAssertEqual(reconnects.scheduledDelays.count, 1)
    }

    /// A proxy whose session is gone for the ticket route only: the page
    /// itself loads, and the ticket request is sent to the sign-in host.
    private func signedOutTicketProxy(signInHostPort: UInt16) throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer.start { request in
            if request.path.hasPrefix("/api/auth/ws-ticket") {
                return .redirect(to: "http://localhost:\(signInHostPort)/oauth2/start?rd=%2Fapi%2Fauth%2Fws-ticket")
            }
            return .json(status: 200, body: #"{"version":"fixture"}"#)
        }
    }

    private func ticketRequests(_ server: LoopbackHTTPServer) -> Int {
        server.receivedRequests.filter { $0.path.hasPrefix("/api/auth/ws-ticket") }.count
    }

    /// A real hidden page on the loopback dashboard, loaded and ready. The
    /// generous readiness window covers a cold simulator's first WebKit
    /// process; a ready page stops the wait at once.
    private func readyPageBridge(port: UInt16) async throws -> DashboardTicketBridge {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:\(port)",
            dashboardID: UUID(),
            readinessPollAttempts: 300,
            readinessPollInterval: .milliseconds(100)
        )
        bridge.webViewCanRun = { true }
        addTeardownBlock { @MainActor in bridge.invalidate() }
        for attempt in 0..<3 {
            do {
                _ = try await bridge.requestJSON(path: "/api/status")
                break
            } catch DashboardTicketBridgeError.notReady where attempt < 2 {
                // A cold load that failed outright: load it again.
                if bridge.isLoadFailed { bridge.reload() }
            }
        }
        XCTAssertTrue(bridge.isReady)
        return bridge
    }

    // MARK: - Requests sent without the page

    func testABackgroundRequestRedirectedToAnotherOriginIsSignIn() async throws {
        let dashboard = try LoopbackHTTPServer.start { _ in
            .redirect(to: "https://sso.example.test/authorize?client_id=hermes")
        }
        defer { dashboard.stop() }
        let bridge = try backgroundBridge(port: dashboard.port)

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions")
            XCTFail("A redirect to the identity provider is not an answer")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }
    }

    func testABackgroundRequestRedirectedToTheProxysStartIsSignIn() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            request.path.hasPrefix("/oauth2/")
                ? .redirect(to: "https://sso.example.test/authorize")
                : .redirect(to: "/oauth2/start?rd=%2Fapi%2Fsessions")
        }
        defer { dashboard.stop() }
        let bridge = try backgroundBridge(port: dashboard.port)

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions")
            XCTFail("A redirect to the proxy's sign-in is not an answer")
        } catch DashboardTicketBridgeError.signInRequired {
            XCTAssertFalse(
                dashboard.receivedRequests.contains { $0.path.hasPrefix("/oauth2/") },
                "The proxy's sign-in redirect is not followed with the dashboard's cookies"
            )
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }
    }

    func testABackgroundRequestFollowsASameOriginRedirectToAnOrdinaryPage() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            request.path == "/api/sessions"
                ? .redirect(to: "/api/sessions/")
                : .json(status: 200, body: #"{"sessions":[]}"#)
        }
        defer { dashboard.stop() }
        let bridge = try backgroundBridge(port: dashboard.port)

        let response = try await bridge.requestJSON(path: "/api/sessions")

        XCTAssertNotNil(response["sessions"])
    }

    /// The same refusal, heard by a request sent without the page.
    func testABackgroundRequestHermesRefusalIsNotSignIn() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            request.path.hasPrefix("/api/files/")
                ? .json(status: 403, body: #"{"detail":"Access to sensitive files is not allowed"}"#)
                : LoopbackHTTPResponse(
                    status: 403,
                    headers: [("Content-Type", "text/html")],
                    body: Data("<html>Forbidden</html>".utf8)
                )
        }
        defer { dashboard.stop() }
        let bridge = try backgroundBridge(port: dashboard.port)

        do {
            _ = try await bridge.requestJSON(path: "/api/files/read?path=%2Froot%2F.env")
            XCTFail("A refused file is not a file")
        } catch DashboardTicketBridgeError.http(let status, let detail) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(detail, "Access to sensitive files is not allowed")
        } catch {
            XCTFail("Expected Hermes' refusal, got \(error)")
        }

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions")
            XCTFail("The proxy's 403 page is not the dashboard's answer")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected
        } catch {
            XCTFail("Expected .signInRequired, got \(error)")
        }
    }

    private func backgroundBridge(port: UInt16) throws -> DashboardTicketBridge {
        let bridge = DashboardTicketBridge(baseURL: "http://127.0.0.1:\(port)", dashboardID: UUID())
        bridge.webViewCanRun = { false }
        bridge.backgroundIssuedCookies = [try XCTUnwrap(HTTPCookie(properties: [
            .name: "_oauth2_proxy", .value: "expired-session", .domain: "127.0.0.1", .path: "/",
        ]))]
        addTeardownBlock { @MainActor in bridge.invalidate() }
        return bridge
    }

    // MARK: - What the app shows

    private func makeAppState(
        dashboardAddress: String? = nil,
        realSocket: Bool = false,
        mintTicket: @escaping @MainActor (String) async throws -> String,
        reconnects: ReconnectLedger? = nil
    ) throws -> AppState {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        addTeardownBlock {
            KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        }
        let suite = "DashboardProxySignOutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(
            id: UUID(),
            label: "Proxied",
            normalizedURL: dashboardAddress ?? dashboardURL.absoluteString
        )
        // A real socket opens through HermesClient; otherwise every
        // connection opens at once.
        let connectClient: (@MainActor (HermesClient) async throws -> Void)? = realSocket ? nil : { _ in }
        let lifecycle = ChatResumeLifecycleOperations(
            connectClient: connectClient,
            loadCatalog: { _, _ in [] },
            mintTicket: mintTicket,
            openSession: { _, id, _ in
                SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {},
            loadBotRoster: {}
        )
        let scheduler: ChatResumeReconnectScheduler? = reconnects.map { ledger in
            { delay, _ in
                ledger.scheduledDelays.append(delay)
                return {}
            }
        }
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: nil,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            reconnectScheduler: scheduler,
            reconnectExecutor: nil,
            chatResumeLifecycleOperations: lifecycle,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.phoneScreenIsAway = { false }
        addTeardownBlock { @MainActor in appState.dashboardTicketBridge?.invalidate() }
        return appState
    }

    @MainActor
    final class ReconnectLedger {
        var scheduledDelays: [TimeInterval] = []
    }

    /// The live case: Chats in offline mode, Settings › Connection says
    /// Disconnected. The reconnect's ticket mint now hears sign-in required
    /// from the page, so the app leaves the shell for the login card, which
    /// says the sign-in expired, and stops reconnecting.
    func testAReconnectTheDashboardSendsToSignInShowsSignInExpired() async throws {
        let reconnects = ReconnectLedger()
        var mints = 0
        let appState = try makeAppState(mintTicket: { _ in
            mints += 1
            throw DashboardTicketBridgeError.signInRequired
        }, reconnects: reconnects)
        appState.connection = HermesConnection(baseUrl: dashboardURL.absoluteString, ticket: "spent")
        appState.showLogin = false

        await appState.reconnect()

        XCTAssertEqual(mints, 1)
        XCTAssertTrue(appState.showLogin, "The login card replaces Chats and Settings")
        XCTAssertEqual(appState.pendingLoginFailure, .signInExpired)
        XCTAssertEqual(appState.pendingLoginFailure?.title, "Your dashboard sign-in expired")
        XCTAssertEqual(appState.lastConnectionFailure, .loginRequired)
        XCTAssertFalse(appState.isConnected)
        XCTAssertFalse(appState.isConnecting)
        XCTAssertNil(appState.connection)
        XCTAssertNil(appState.offlineChatPresentation, "No offline mode in front of the sign-in")
        XCTAssertTrue(reconnects.scheduledDelays.isEmpty, "Sign-in required stops automatic reconnects")
    }

    /// Before the fix the page's off-origin landing surfaced as `.notReady`:
    /// a network-style failure, offline mode and an endless reconnect loop.
    func testANotReadyBridgeStillRetriesAndNeverClaimsASignOut() async throws {
        let reconnects = ReconnectLedger()
        let appState = try makeAppState(mintTicket: { _ in
            throw DashboardTicketBridgeError.notReady
        }, reconnects: reconnects)
        appState.connection = HermesConnection(baseUrl: dashboardURL.absoluteString, ticket: "spent")
        appState.showLogin = false

        await appState.reconnect()

        XCTAssertFalse(appState.showLogin)
        XCTAssertNil(appState.pendingLoginFailure)
        XCTAssertEqual(reconnects.scheduledDelays.count, 1)
    }

    /// Reconnect from Settings › Connection while the dashboard has already
    /// said sign-in is required opens sign-in instead of a reconnect the
    /// dashboard would only refuse again (which looked like nothing).
    func testReconnectWhileSignInIsRequiredOpensSignIn() async throws {
        var mints = 0
        let appState = try makeAppState(mintTicket: { _ in
            mints += 1
            return "never-used"
        })
        appState.connection = HermesConnection(baseUrl: dashboardURL.absoluteString, ticket: "spent")
        appState.showLogin = false
        appState.lastConnectionFailure = .loginRequired
        XCTAssertTrue(appState.signInRequiredForReconnect)
        // An app sign-in's grant, kept when the refused socket stopped
        // recovery, survives the tap too.
        let id = try XCTUnwrap(appState.activeDashboardID)
        KeychainHelper.saveNativeOAuthTokens(DashboardSocketFixture.tokens(access: "kept"), dashboardID: id)

        await appState.reconnect()

        XCTAssertEqual(mints, 0, "No reconnect the dashboard would refuse")
        XCTAssertTrue(appState.showLogin)
        XCTAssertEqual(appState.pendingLoginFailure, .signInExpired)
        XCTAssertNotNil(KeychainHelper.loadNativeOAuthTokens(dashboardID: id), "Reconnect never deletes the native grant")
    }

    func testReconnectAfterAnOrdinaryFailureStillReconnects() async throws {
        var mints = 0
        let appState = try makeAppState(mintTicket: { _ in
            mints += 1
            return "fresh"
        })
        appState.connection = HermesConnection(baseUrl: dashboardURL.absoluteString, ticket: "spent")
        appState.showLogin = false
        appState.lastConnectionFailure = .timedOut
        XCTAssertFalse(appState.signInRequiredForReconnect)

        await appState.reconnect()

        XCTAssertEqual(mints, 1)
        XCTAssertFalse(appState.showLogin)
    }

    /// A socket upgrade the proxy redirects says the same thing.
    func testARedirectedSocketUpgradeShowsSignInExpired() async throws {
        let fixture = try DashboardSocketFixture(
            upgradeStatuses: [302],
            redirectLocation: "https://sso.example.test/authorize"
        )
        defer { fixture.stop() }
        let reconnects = ReconnectLedger()
        let appState = try makeAppState(
            dashboardAddress: fixture.baseURL,
            realSocket: true,
            mintTicket: { _ in "fresh" },
            reconnects: reconnects
        )

        await appState.connect(with: HermesConnection(baseUrl: fixture.baseURL, ticket: "fixture-ticket"))

        XCTAssertTrue(appState.showLogin)
        XCTAssertEqual(appState.pendingLoginFailure, .signInExpired)
        XCTAssertEqual(appState.lastConnectionFailure, .loginRequired)
        XCTAssertTrue(reconnects.scheduledDelays.isEmpty)
    }

    /// After the user signs in again in the browser, the next connection
    /// reloads the page that had settled on sign-in, so its ticket is minted
    /// with the new session, without a relaunch.
    func testTheNextConnectionReloadsAPageParkedOnSignIn() throws {
        let appState = try makeAppState(mintTicket: { _ in "fresh" })
        appState.prepareDashboardBridge(for: dashboardURL.absoluteString)
        let bridge = try XCTUnwrap(appState.dashboardTicketBridge)
        bridge.processLanding(at: URL(string: "https://sso.example.test/authorize"))
        let reloadsBefore = bridge.reloadCount

        appState.prepareDashboardBridge(for: dashboardURL.absoluteString)

        XCTAssertTrue(appState.dashboardTicketBridge === bridge, "The same dashboard keeps its page")
        XCTAssertEqual(bridge.reloadCount, reloadsBefore + 1)
        XCTAssertFalse(bridge.requiresSignIn, "The reload starts over")
    }

    func testTheNextConnectionLeavesAReadyPageAlone() throws {
        let appState = try makeAppState(mintTicket: { _ in "fresh" })
        appState.prepareDashboardBridge(for: dashboardURL.absoluteString)
        let bridge = try XCTUnwrap(appState.dashboardTicketBridge)
        bridge.processLanding(at: URL(string: "https://dashboard.example.test/api/status"))
        let reloadsBefore = bridge.reloadCount

        appState.prepareDashboardBridge(for: dashboardURL.absoluteString)

        XCTAssertEqual(bridge.reloadCount, reloadsBefore)
    }

    // MARK: - The sign-in screen

    func testSignInExpiredAsksToSignInAgain() {
        let expired = ConnectionFailurePresentation.signInExpired
        XCTAssertTrue(expired.asksToSignInAgain, "The failure card's retry reads Sign In Again")
        XCTAssertTrue(expired.offersRecoveryActions)
        XCTAssertEqual(expired.classifiedFailure, .loginRequired)
        XCTAssertFalse(ConnectionFailurePresentation.presenting(.timedOut).asksToSignInAgain)
        XCTAssertFalse(ConnectionFailurePresentation.presenting(.authenticationRejected).asksToSignInAgain,
                       "A refused password is fixed by typing it again, not by a browser sign-in")
    }

    /// Sign In Again on the signed-out dashboard's row retries that row:
    /// discovery of the auth-proxied dashboard opens its browser sign-in at
    /// once.
    func testSignInAgainOpensTheBrowserSignInForAnAuthProxiedDashboard() async throws {
        let appState = try makeAppState(mintTicket: { _ in "unused" })
        let flow = LoginFlowModel(makeTransport: { _, _ in ProxiedDashboardTransport() })
        flow.attach(appState)
        let id = try XCTUnwrap(appState.activeDashboardID)
        flow.receive(.signInExpired)
        XCTAssertEqual(flow.failure(at: .dashboard(id)), .signInExpired, "The expired notice shows under its dashboard")

        await flow.retry()

        XCTAssertEqual(flow.browserRequest?.baseURL, "https://dashboard.example.test")
        XCTAssertNil(flow.failure, "The sign-in replaces the expired notice")
    }

    // MARK: - Settings › Connection Setup

    private func interactiveSettingsFlow(address: String = "https://dashboard.example.test") throws -> ConnectionSetupFlow {
        var flow = ConnectionSetupFlow(entry: .currentConnection, draft: ConnectionSetupDraft(existingServerURL: address))
        let generation = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents.dropLast(2) {
            XCTAssertTrue(flow.applyTestEvent(event, generation: generation))
        }
        XCTAssertTrue(flow.applyTestEvent(.started(.authentication), generation: generation))
        XCTAssertTrue(flow.applyTestEvent(.requiresInteractiveSignIn(.authentication, .browser(.authProxyRedirect)), generation: generation))
        XCTAssertEqual(flow.step, .review)
        return flow
    }

    func testSettingsSetupOffersSignInAgainForTheActiveDashboardsBrowserSignIn() throws {
        let flow = try interactiveSettingsFlow()
        XCTAssertTrue(ConnectionSetupSettingsReview.offersSignInAgain(
            for: flow,
            activeDashboardURL: "https://dashboard.example.test/"
        ))
        XCTAssertFalse(ConnectionSetupSettingsReview.offersSignInAgain(
            for: flow,
            activeDashboardURL: "https://other.example.test"
        ), "Another dashboard signs in from the login card, not from Settings")
    }

    func testSettingsSetupDoesNotOfferSignInAgainForAPasswordTestOrTheLoginWizard() throws {
        var passwordFlow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: "https://dashboard.example.test", username: "eric", password: "synthetic")
        )
        passwordFlow.submitDetails()
        passwordFlow.submitCredentials()
        StagedTestDriver.runSuccessfulTest(on: &passwordFlow)
        XCTAssertEqual(passwordFlow.step, .review)
        XCTAssertFalse(ConnectionSetupSettingsReview.offersSignInAgain(
            for: passwordFlow,
            activeDashboardURL: "https://dashboard.example.test"
        ))

        let loginFlow = ConnectionSetupFlow(entry: .start, draft: ConnectionSetupDraft(existingServerURL: "https://dashboard.example.test"))
        XCTAssertFalse(ConnectionSetupSettingsReview.offersSignInAgain(
            for: loginFlow,
            activeDashboardURL: "https://dashboard.example.test"
        ))
    }

    func testSettingsSetupNeverClaimsADisconnectedSessionStaysConnected() {
        XCTAssertFalse(ConnectionSetupSettingsReview.applyNote(connected: false).contains("stays connected"))
        XCTAssertTrue(ConnectionSetupSettingsReview.applyNote(connected: true).contains("stays connected"))
        let disconnected = ConnectionSetupSettingsReview.signInAgainMessage(connected: false)
        XCTAssertFalse(disconnected.contains("login screen"), "There is no login screen to return to")
        XCTAssertTrue(disconnected.contains("Sign in again"))
    }
}

/// The port the dashboard server gets, read by a server started before it.
private final class LockedPort: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16 = 0
    var value: UInt16 {
        get { lock.lock(); defer { lock.unlock() }; return port }
        set { lock.lock(); port = newValue; lock.unlock() }
    }
}

/// Discovery of a dashboard behind a sign-in service: the providers request
/// is redirected, which is the interactive-auth signal.
private struct ProxiedDashboardTransport: DashboardSignInTransport {
    func authProviderDiscovery() async throws -> AuthProviderDiscoveryResult { .interactiveSignInRequired }
    func supportsNativeOAuth() async throws -> Bool { false }
    func connect(username: String, password: String) async throws -> NativeAuthConnection {
        throw AuthClientError.loginFailed(status: 401, detail: "not a password dashboard")
    }
}
