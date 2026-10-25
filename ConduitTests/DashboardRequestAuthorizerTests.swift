//
//  DashboardRequestAuthorizerTests.swift
//  ConduitTests
//
//  The selected dashboard's request authorization: its session cookies go
//  only to its own origin and base path, never to another saved dashboard
//  (even on the same origin), an identity provider or an external service;
//  a cookie-mode upgrade carries the dashboard's own session cookies a
//  browser would send to that address, and a native-mode upgrade carries
//  none, and the grant's bearer to that address only. Synthetic hosts only.
//

import Foundation
import XCTest
@testable import Conduit

@MainActor
final class DashboardRequestAuthorizerTests: XCTestCase {
    private var backend: InMemoryKeychainBackend!

    override func setUp() {
        super.setUp()
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
    }

    override func tearDown() {
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        super.tearDown()
    }

    private func cookieAuthorizer(
        _ baseURL: String,
        others: [String] = []
    ) -> DashboardRequestAuthorizer {
        DashboardRequestAuthorizer(
            baseURL: baseURL,
            dashboardID: UUID(),
            cloudflareAccess: nil,
            nativeSession: nil,
            otherDashboardURLs: { others }
        )
    }

    private func nativeAuthorizer(
        _ baseURL: String,
        access: String = "access-selected",
        tokens: NativeOAuthTokenSet? = nil,
        others: [String] = []
    ) -> DashboardRequestAuthorizer {
        let id = UUID()
        let session = NativeOAuthSession(
            tokens: tokens ?? DashboardSocketFixture.tokens(access: access),
            dashboardID: id,
            client: NativeOAuthAPIClient(baseURL: baseURL)
        )
        let authorizer = DashboardRequestAuthorizer(
            baseURL: baseURL,
            dashboardID: id,
            cloudflareAccess: nil,
            nativeSession: session,
            otherDashboardURLs: { others }
        )
        addTeardownBlock { @MainActor in authorizer.invalidate() }
        return authorizer
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - Origin gate

    func testSecureWebSocketMatchesItsHTTPSDashboardOnly() {
        let authorizer = cookieAuthorizer("https://dashboard.example.test")
        XCTAssertTrue(authorizer.covers(url("wss://dashboard.example.test/api/ws?ticket=t")))
        XCTAssertTrue(authorizer.covers(url("wss://DASHBOARD.example.test:443/api/ws")), "Host case and the default port are the same origin")
        XCTAssertFalse(authorizer.covers(url("ws://dashboard.example.test/api/ws")), "Cleartext is another origin")
        XCTAssertFalse(authorizer.covers(url("wss://dashboard.example.test:8443/api/ws")), "Another port is another origin")
        XCTAssertFalse(authorizer.covers(url("wss://sibling.example.test/api/ws")), "A sibling host under the same parent domain")
        XCTAssertFalse(authorizer.covers(url("wss://example.test/api/ws")), "The parent domain")
        XCTAssertFalse(authorizer.covers(url("https://sso.example.test/authorize")), "An identity provider")
        XCTAssertFalse(authorizer.covers(url("wss://voice-provider.example.test/live")), "An external voice provider")
        XCTAssertFalse(authorizer.covers(url("wss://user:pass@dashboard.example.test/api/ws")), "Userinfo is refused")
        XCTAssertFalse(authorizer.covers(url("ftp://dashboard.example.test/api/ws")))
    }

    func testPlainLoopbackWebSocketMatchesItsHTTPDashboard() {
        let authorizer = cookieAuthorizer("http://127.0.0.1:9119")
        XCTAssertTrue(authorizer.covers(url("ws://127.0.0.1:9119/api/ws")))
        XCTAssertFalse(authorizer.covers(url("wss://127.0.0.1:9119/api/ws")))
        XCTAssertFalse(authorizer.covers(url("ws://localhost:9119/api/ws")), "localhost is another origin than 127.0.0.1")
    }

    func testBasePathIsRespectedOnSegmentBoundaries() {
        let authorizer = cookieAuthorizer("https://dashboard.example.test/team/hermes/")
        XCTAssertTrue(authorizer.covers(url("wss://dashboard.example.test/team/hermes/api/ws")))
        XCTAssertTrue(authorizer.covers(url("wss://dashboard.example.test/team/hermes")))
        XCTAssertFalse(authorizer.covers(url("wss://dashboard.example.test/api/ws")), "Outside the base path")
        XCTAssertFalse(authorizer.covers(url("wss://dashboard.example.test/team/hermes-other/api/ws")), "A prefix that is not a segment")
    }

    func testAnotherSavedDashboardUnderTheSameOriginIsNeverCovered() {
        let authorizer = cookieAuthorizer(
            "https://dashboard.example.test",
            others: ["https://dashboard.example.test/team", "https://elsewhere.example.test"]
        )
        XCTAssertTrue(authorizer.covers(url("wss://dashboard.example.test/api/ws")))
        XCTAssertFalse(authorizer.covers(url("wss://dashboard.example.test/team/api/ws")),
                       "The more specific saved dashboard owns its own base path")
        XCTAssertTrue(authorizer.covers(url("wss://dashboard.example.test/teammate/api/ws")))

        // The sibling's own authorizer covers its path, and not the root's.
        let sibling = cookieAuthorizer("https://dashboard.example.test/team", others: ["https://dashboard.example.test"])
        XCTAssertTrue(sibling.covers(url("wss://dashboard.example.test/team/api/ws")))
        XCTAssertFalse(sibling.covers(url("wss://dashboard.example.test/api/ws")))
    }

    func testAppStateBuildsTheAuthorizerWithTheOtherSavedDashboards() throws {
        let root = SavedDashboard(id: UUID(), label: "Root", normalizedURL: "https://dashboard.example.test")
        let team = SavedDashboard(id: UUID(), label: "Team", normalizedURL: "https://dashboard.example.test/team")
        let defaults = makeScratchDefaults("DashboardRequestAuthorizerTests")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: root.id, dashboards: [root, team]),
            clearSessionPresentationCache: {}
        )
        appState.prepareDashboardBridge(for: root.normalizedURL)
        let bridge = try XCTUnwrap(appState.dashboardTicketBridge)
        defer { bridge.invalidate() }
        XCTAssertEqual(bridge.requestAuthorizer.dashboardID, root.id)
        XCTAssertTrue(bridge.requestAuthorizer.covers(url("wss://dashboard.example.test/api/ws")))
        XCTAssertFalse(bridge.requestAuthorizer.covers(url("wss://dashboard.example.test/team/api/ws")))
    }

    // MARK: - Native upgrades

    func testNativeUpgradeKeepsItsTicketAndProxyHeadersAndCarriesTheBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        let authorizer = nativeAuthorizer(fixture.baseURL)
        var asked = 0
        authorizer.cookieUpgradeCookies = { asked += 1; return [] }

        let ticket = try await authorizer.mintTicket()
        var request = URLRequest(url: try ConnectionURLPolicy.webSocketURL(
            baseURL: fixture.baseURL,
            path: "/api/ws",
            queryItems: [URLQueryItem(name: "ticket", value: ticket)]
        ))
        request.setValue("ambient=1", forHTTPHeaderField: "Cookie")
        request.setValue("kept", forHTTPHeaderField: "X-Proxy-Header")

        let authorized = try await authorizer.authorizeUpgrade(request)

        XCTAssertEqual(fixture.mintCount, 1, "The ticket is minted with the native grant")
        XCTAssertEqual(authorized.url, request.url)
        XCTAssertNil(authorized.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "X-Proxy-Header"), "kept")
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer access-selected")
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), fixture.authorizationThatMinted(ticket),
                       "The upgrade presents the bearer that minted its ticket")
        XCTAssertEqual(asked, 0, "A native sign-in has no session cookies to send")
    }

    func testNativeUpgradeBearerReplacesAnAuthorizationHeaderAlreadyThere() async throws {
        let authorizer = nativeAuthorizer("https://dashboard.example.test")
        var request = URLRequest(url: url("wss://dashboard.example.test/api/ws?ticket=t"))
        request.setValue("Basic c3RhbGU=", forHTTPHeaderField: "Authorization")
        let authorized = try await authorizer.authorizeUpgrade(request)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer access-selected")
    }

    func testNativeUpgradeToAnotherAddressCarriesNoBearer() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        // An expired grant: an upgrade the bearer went to would refresh it.
        let expired = NativeOAuthTokenSet(
            accessToken: "access-selected",
            refreshToken: "refresh-selected",
            expiresAt: Date().timeIntervalSince1970 - 5,
            provider: "self-hosted",
            userID: "fixture-user"
        )
        let authorizer = nativeAuthorizer(
            "\(fixture.baseURL)/team",
            tokens: expired,
            others: ["\(fixture.baseURL)/team/ops"]
        )
        let port = fixture.server.port
        for address in [
            "ws://localhost:\(port)/team/api/ws?ticket=t",
            "wss://127.0.0.1:\(port)/team/api/ws?ticket=t",
            "ws://127.0.0.1:\(port + 1)/team/api/ws?ticket=t",
            "ws://127.0.0.1:\(port)/api/ws?ticket=t",
            "ws://127.0.0.1:\(port)/teammate/api/ws?ticket=t",
            "ws://127.0.0.1:\(port)/team/ops/api/ws?ticket=t",
            "wss://sso.example.test/authorize",
            "wss://voice-provider.example.test/live",
        ] {
            let authorized = try await authorizer.authorizeUpgrade(URLRequest(url: url(address)))
            XCTAssertNil(authorized.value(forHTTPHeaderField: "Authorization"), address)
            XCTAssertNil(authorized.value(forHTTPHeaderField: "Cookie"), address)
        }
        XCTAssertTrue(fixture.refreshes.isEmpty, "Nothing was refreshed for an address the bearer does not go to")

        let own = try await authorizer.authorizeUpgrade(URLRequest(url: url("\(fixture.baseURL)/team/api/ws?ticket=t")))
        XCTAssertEqual(own.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access-renewed")
    }

    func testNativeUpgradeOverCleartextToASecureDashboardCarriesNoBearer() async throws {
        let authorizer = nativeAuthorizer("https://dashboard.example.test")
        let secure = try await authorizer.authorizeUpgrade(URLRequest(url: url("wss://dashboard.example.test/api/ws?ticket=t")))
        XCTAssertEqual(secure.value(forHTTPHeaderField: "Authorization"), "Bearer access-selected")
        let cleartext = try await authorizer.authorizeUpgrade(URLRequest(url: url("ws://dashboard.example.test/api/ws?ticket=t")))
        XCTAssertNil(cleartext.value(forHTTPHeaderField: "Authorization"), "ws:// is another origin than an https dashboard")
    }

    func testNativeUpgradeRefreshesAnExpiredBearerFirst() async throws {
        let fixture = try DashboardSocketFixture(refreshedAccessToken: "access-renewed")
        defer { fixture.stop() }
        let expired = NativeOAuthTokenSet(
            accessToken: "access-expired",
            refreshToken: "refresh-expired",
            expiresAt: Date().timeIntervalSince1970 - 5,
            provider: "self-hosted",
            userID: "fixture-user"
        )
        let authorizer = nativeAuthorizer(fixture.baseURL, tokens: expired)

        let request = URLRequest(url: try ConnectionURLPolicy.webSocketURL(
            baseURL: fixture.baseURL,
            path: "/api/ws",
            queryItems: [URLQueryItem(name: "ticket", value: "t")]
        ))
        let authorized = try await authorizer.authorizeUpgrade(request)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer access-renewed")
        XCTAssertEqual(fixture.refreshes.count, 1)

        // The renewed token is fresh: the next upgrade refreshes nothing.
        let again = try await authorizer.authorizeUpgrade(request)
        XCTAssertEqual(again.value(forHTTPHeaderField: "Authorization"), "Bearer access-renewed")
        XCTAssertEqual(fixture.refreshes.count, 1)
    }

    func testNativeUpgradeKeepsAnUnexpiredBearerThatMintedItsTicket() async throws {
        // Within REST's early-refresh margin but not expired: the ticket was
        // just minted with this token, so the upgrade presents the same one.
        let fixture = try DashboardSocketFixture(refreshedAccessToken: "access-renewed")
        defer { fixture.stop() }
        let ticket = "fixture-minted-elsewhere"
        let closeToExpiry = NativeOAuthTokenSet(
            accessToken: "access-current",
            refreshToken: "refresh-current",
            expiresAt: Date().timeIntervalSince1970 + 30,
            provider: "self-hosted",
            userID: "fixture-user"
        )
        let authorizer = nativeAuthorizer(fixture.baseURL, tokens: closeToExpiry)
        let request = URLRequest(url: try ConnectionURLPolicy.webSocketURL(
            baseURL: fixture.baseURL,
            path: "/api/ws",
            queryItems: [URLQueryItem(name: "ticket", value: ticket)]
        ))
        let authorized = try await authorizer.authorizeUpgrade(request)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer access-current")
        XCTAssertTrue(fixture.refreshes.isEmpty)
    }

    func testNativeUpgradeWhoseRefreshIsRefusedThrowsAndCarriesNothing() async throws {
        let server = try LoopbackHTTPServer.start { _ in .status(401) }
        defer { server.stop() }
        let baseURL = "http://127.0.0.1:\(server.port)"
        let expired = NativeOAuthTokenSet(
            accessToken: "access-expired",
            refreshToken: "refresh-refused",
            expiresAt: Date().timeIntervalSince1970 - 5,
            provider: "self-hosted",
            userID: "fixture-user"
        )
        let authorizer = nativeAuthorizer(baseURL, tokens: expired)
        do {
            let authorized = try await authorizer.authorizeUpgrade(URLRequest(url: url("ws://127.0.0.1:\(server.port)/api/ws?ticket=t")))
            XCTFail("A refused refresh must not authorize the upgrade, got \(String(describing: authorized.allHTTPHeaderFields?.keys))")
        } catch DashboardTicketBridgeError.signInRequired {
            // Expected: sign-in is required, as for a REST request.
        }
        XCTAssertFalse(server.receivedRequests.contains { $0.headers["upgrade"] != nil }, "No upgrade was attempted")
    }

    private func cookie(
        _ name: String,
        domain: String,
        path: String = "/",
        secure: Bool = true,
        expires: Date? = nil
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: "\(name)-value", .domain: domain, .path: path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testCookieModeKeepsTheTicketAndProxyHeadersAndAddsNoBearer() async throws {
        let authorizer = cookieAuthorizer("https://dashboard.example.test")
        var request = URLRequest(url: url("wss://dashboard.example.test/api/ws?ticket=cookie-ticket"))
        request.setValue("value", forHTTPHeaderField: "CF-Access-Client-Id")
        let authorized = try await authorizer.authorizeUpgrade(request)
        XCTAssertEqual(authorized.url, request.url)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "CF-Access-Client-Id"), "value")
        XCTAssertNil(authorized.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(authorized.value(forHTTPHeaderField: "Cookie"))
    }

    /// An auth proxy in front of the dashboard (here a parent-domain,
    /// Secure, oauth2-proxy-style session) admits the upgrade only with its
    /// cookie: the socket carries what the dashboard's page would send.
    func testCookieModeUpgradeCarriesTheDashboardsProxySessionCookie() async throws {
        let authorizer = cookieAuthorizer("https://dashboard.example.test")
        authorizer.cookieUpgradeCookies = { [self] in
            [
                cookie("_proxy_session", domain: ".example.test"),
                cookie("dashboard_session", domain: "dashboard.example.test"),
                cookie("sibling_only", domain: "other.example.test"),
                cookie("expired", domain: "dashboard.example.test", expires: Date(timeIntervalSinceNow: -60)),
                cookie("elsewhere", domain: "dashboard.example.test", path: "/other"),
            ]
        }
        var request = URLRequest(url: url("wss://dashboard.example.test/api/ws?ticket=cookie-ticket"))
        request.setValue("stale=1", forHTTPHeaderField: "Cookie")
        let authorized = try await authorizer.authorizeUpgrade(request)
        let sent = Set((authorized.value(forHTTPHeaderField: "Cookie") ?? "").components(separatedBy: "; "))
        XCTAssertEqual(sent, ["_proxy_session=_proxy_session-value", "dashboard_session=dashboard_session-value"])
        XCTAssertEqual(authorized.url, request.url)
    }

    func testCookieModeSendsNoCookieToAnotherAddress() async throws {
        let authorizer = cookieAuthorizer("https://dashboard.example.test/team", others: ["https://dashboard.example.test/team/ops"])
        var asked = 0
        authorizer.cookieUpgradeCookies = { [self] in
            asked += 1
            return [cookie("_proxy_session", domain: ".example.test")]
        }
        for address in [
            "wss://other.example.test/api/ws?ticket=t",
            "wss://dashboard.example.test/api/ws?ticket=t",
            "wss://dashboard.example.test/team/ops/api/ws?ticket=t",
        ] {
            var request = URLRequest(url: url(address))
            request.setValue("stale=1", forHTTPHeaderField: "Cookie")
            let authorized = try await authorizer.authorizeUpgrade(request)
            XCTAssertNil(authorized.value(forHTTPHeaderField: "Cookie"), address)
        }
        XCTAssertEqual(asked, 0)
    }

    func testSecureCookieGoesOnlyOverASecureScheme() {
        let secure = cookie("s", domain: "127.0.0.1")
        let plain = cookie("p", domain: "127.0.0.1", secure: false)
        XCTAssertEqual(DashboardRequestAuthorizer.cookieHeader(for: [secure, plain], url: url("ws://127.0.0.1:9119/api/ws")), "p=p-value")
        XCTAssertNil(DashboardRequestAuthorizer.cookieHeader(for: [secure], url: url("http://127.0.0.1:9119/api/ws")))
        XCTAssertNotNil(DashboardRequestAuthorizer.cookieHeader(for: [secure], url: url("wss://127.0.0.1/api/ws")))
    }

    func testHostOnlyCookieIsNotSentToASubdomain() {
        let hostOnly = cookie("h", domain: "example.test")
        XCTAssertNil(DashboardRequestAuthorizer.cookieHeader(for: [hostOnly], url: url("wss://dashboard.example.test/api/ws")))
        XCTAssertNil(DashboardRequestAuthorizer.cookieHeader(
            for: [cookie("d", domain: ".example.test")], url: url("wss://badexample.test/api/ws")))
    }

    /// A request made without the dashboard's page (the ticket CarPlay asks
    /// for with the phone locked) carries the auth proxy's parent-domain
    /// session, as the page and the socket upgrade do. Without it the proxy
    /// redirected the ticket request to sign-in and CarPlay never connected.
    func testRequestWithoutThePageCarriesTheProxySessionSetForTheParentDomain() {
        let cookies = [
            cookie("_oauth2_proxy", domain: ".example.test"),
            cookie("dashboard_session", domain: "dashboard.example.test"),
            cookie("sibling_only", domain: "other.example.test"),
            cookie("parent_host_only", domain: "example.test"),
            cookie("lookalike", domain: ".badexample.test"),
        ]
        let header = NativeAuthCookiePolicy.headerFields(
            for: cookies, url: url("https://dashboard.example.test/api/auth/ws-ticket"))["Cookie"] ?? ""
        XCTAssertEqual(
            Set(header.components(separatedBy: "; ")),
            ["_oauth2_proxy=_oauth2_proxy-value", "dashboard_session=dashboard_session-value"]
        )
        // The parent domain itself takes its Domain cookie and its own
        // host-only one, not a subdomain's.
        let parentHeader = NativeAuthCookiePolicy.headerFields(
            for: cookies, url: url("https://example.test/api/auth/ws-ticket"))["Cookie"] ?? ""
        XCTAssertEqual(
            Set(parentHeader.components(separatedBy: "; ")),
            ["_oauth2_proxy=_oauth2_proxy-value", "parent_host_only=parent_host_only-value"]
        )
    }

    func testInvalidatedAuthorizerAuthorizesNothing() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        let authorizer = nativeAuthorizer(fixture.baseURL)
        authorizer.invalidate()
        XCTAssertNil(authorizer.nativeSession)
        do {
            _ = try await authorizer.authorizeUpgrade(URLRequest(url: url("\(fixture.baseURL)/api/ws")))
            XCTFail("An invalidated authorizer must refuse")
        } catch DashboardTicketBridgeError.notReady {
            // Expected.
        }
        XCTAssertEqual(fixture.mintCount, 0)
    }
}
