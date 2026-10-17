//
//  DashboardSignInAgreementTests.swift
//  Conduit
//
//  Login, Connection Setup and Repair must make the same decision for the
//  same discovery answer. Each fixture runs through all three consumers —
//  the sign-in screen's route (picking the browser sign-in when a password
//  dashboard also offers one), the staged-test probe, and Repair's Sign In
//  to Reconnect acting on that test's result — and their outcomes are
//  compared. The auth-proxy
//  redirects and the fresh first run also run over real loopback transport,
//  so the redirect delegate itself proves nothing reaches the sign-in
//  service and no password request is sent.
//

import XCTest
@testable import Conduit

@MainActor
final class DashboardSignInAgreementTests: XCTestCase {
    /// The decision, in full.
    private enum Kind: Equatable {
        case password
        /// Opens this sign-in directly.
        case interactive(DashboardInteractiveSignIn)
        /// Password, or the offered browser sign-in, whose pick ends in
        /// `pick`.
        case choice(offer: DashboardBrowserSignInOffer, pick: Pick)
        case failure(ConnectionFailure)

        /// What the staged test reports for it.
        var setupOutcome: SetupOutcome {
            switch self {
            case .password: return .password
            case .interactive(let signIn): return .interactive(signIn)
            case .choice(let offer, _): return .choice(offer)
            case .failure(let failure): return .failure(failure)
            }
        }

        /// What Repair's Sign In to Reconnect does with that test result.
        var repairOutcome: RepairOutcome {
            switch self {
            case .password: return .opensNothing
            case .interactive(let signIn), .choice(_, pick: .opens(let signIn)): return .opens(signIn)
            case .choice(_, pick: .fails(let failure)), .failure(let failure): return .failure(failure)
            }
        }
    }

    /// Picking a choosing dashboard's browser sign-in: the native capability
    /// check runs only then.
    private enum Pick: Equatable {
        case opens(DashboardInteractiveSignIn)
        case fails(ConnectionFailure)
    }

    /// The staged test's terminal outcome.
    private enum SetupOutcome: Equatable {
        case password
        case interactive(DashboardInteractiveSignIn)
        case choice(DashboardBrowserSignInOffer)
        case failure(ConnectionFailure)
    }

    /// What Sign In to Reconnect opens for the staged test's result, or the
    /// failure Repair shows.
    private enum RepairOutcome: Equatable {
        case opens(DashboardInteractiveSignIn)
        /// A password outcome: Repair reconnects through its tested
        /// candidate, never a browser.
        case opensNothing
        case failure(ConnectionFailure)
    }

    private struct Fixture {
        let host: String
        let kind: Kind
    }

    private static let fixtures: [Fixture] = [
        Fixture(host: "agree-password.example.test", kind: .password),
        Fixture(host: "agree-native.example.test", kind: .interactive(.nativeOAuth(provider: "self-hosted"))),
        Fixture(host: "agree-legacy.example.test", kind: .interactive(.browser(.legacyOAuth))),
        Fixture(host: "agree-prepassword.example.test", kind: .interactive(.browser(.legacyOAuth))),
        Fixture(host: "agree-proxy.example.test", kind: .interactive(.browser(.authProxyRedirect))),
        Fixture(host: "agree-mixed-native.example.test", kind: .choice(
            offer: .nativeCapable(provider: "self-hosted"), pick: .opens(.nativeOAuth(provider: "self-hosted"))
        )),
        Fixture(host: "agree-mixed-legacy.example.test", kind: .choice(
            offer: .nativeCapable(provider: "self-hosted"), pick: .opens(.browser(.legacyOAuth))
        )),
        Fixture(host: "agree-mixed-prepassword.example.test", kind: .choice(
            offer: .legacyOAuth, pick: .opens(.browser(.legacyOAuth))
        )),
        // The case the surfaces used to disagree on: a password plus a
        // native-capable provider whose capability check fails. Every
        // surface offers the password; only picking the browser sign-in
        // fails, and nothing falls back on its own.
        Fixture(host: "agree-mixed-status-5xx.example.test", kind: .choice(
            offer: .nativeCapable(provider: "self-hosted"), pick: .fails(.dashboardUnavailable)
        )),
        Fixture(host: "agree-status-malformed.example.test", kind: .failure(.unexpectedServerResponse)),
        Fixture(host: "agree-status-5xx.example.test", kind: .failure(.dashboardUnavailable)),
        Fixture(host: "agree-unrecognized.example.test", kind: .failure(.unexpectedServerResponse)),
        Fixture(host: "agree-empty.example.test", kind: .failure(.unexpectedServerResponse)),
        Fixture(host: "agree-discovery-5xx.example.test", kind: .failure(.dashboardUnavailable))
    ]

    override func setUp() {
        super.setUp()
        AgreementURLProtocol.reset()
    }

    override func tearDown() {
        AgreementURLProtocol.reset()
        super.tearDown()
    }

    private static func stubbedSession() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgreementURLProtocol.self]
        return configuration
    }

    private static func realSession() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return configuration
    }

    // MARK: - One answer, one decision

    func testLoginSetupAndRepairAgreeForEveryDiscoveryAnswer() async {
        for fixture in Self.fixtures {
            let baseURL = "https://\(fixture.host)"
            let login = await loginOutcome(baseURL, session: Self.stubbedSession())
            let setup = await setupOutcome(baseURL, session: Self.stubbedSession())
            let repair = await repairOutcome(baseURL, session: Self.stubbedSession())

            XCTAssertEqual(login, fixture.kind, "Login, \(fixture.host)")
            XCTAssertEqual(setup, fixture.kind.setupOutcome, "Setup, \(fixture.host)")
            XCTAssertEqual(repair, fixture.kind.repairOutcome, "Repair, \(fixture.host)")
            XCTAssertEqual(
                AgreementURLProtocol.requestCount(host: fixture.host, path: "/auth/password-login"), 0,
                "\(fixture.host): no surface sends a password before one is entered"
            )
        }
    }

    // MARK: - Real transport

    func testAuthProxyRedirectIsBrowserSignInEverywhereAndNeverFollowed() async throws {
        // An auth-proxy-shaped answer: an edge in front of the dashboard
        // redirects every unauthenticated request to a sign-in service on
        // another origin. 127.0.0.1 and localhost are different origins, so
        // the real redirect delegate decides here, not a stub.
        let signInService = try LoopbackHTTPServer.start { _ in
            .json(status: 200, body: #"{"page":"sign-in"}"#)
        }
        defer { signInService.stop() }
        let signInOrigin = "http://localhost:\(signInService.port)"
        let dashboard = try LoopbackHTTPServer.start { _ in
            LoopbackHTTPResponse(
                status: 302,
                headers: [
                    ("Location", "\(signInOrigin)/oauth2/start?rd=%2Fapi%2Fauth%2Fproviders"),
                    ("Set-Cookie", "proxy_csrf=fixture; Path=/; HttpOnly")
                ],
                body: Data()
            )
        }
        defer { dashboard.stop() }
        let baseURL = "http://127.0.0.1:\(dashboard.port)"
        let access = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "agreement-client", clientSecret: "agreement-secret"))

        let login = await loginOutcome(baseURL, access: access, session: Self.realSession())
        XCTAssertEqual(login, .interactive(.browser(.authProxyRedirect)))
        let setup = await setupOutcome(baseURL, access: access, session: Self.realSession())
        XCTAssertEqual(setup, .interactive(.browser(.authProxyRedirect)))
        let repair = await repairOutcome(baseURL, access: access, session: Self.realSession())
        XCTAssertEqual(repair, .opens(.browser(.authProxyRedirect)))

        XCTAssertTrue(signInService.receivedRequests.isEmpty, "Conduit never follows the redirect to the sign-in service")
        let requests = dashboard.receivedRequests
        XCTAssertEqual(
            requests.map(\.path), Array(repeating: "/api/auth/providers", count: 3),
            "One discovery request per surface: no capability check, no password, no ticket"
        )
        for request in requests {
            XCTAssertNil(request.headers["cookie"], "Discovery carries no session cookie")
            XCTAssertNil(request.headers["authorization"], "Discovery carries no bearer")
            XCTAssertNil(request.headers["cf-access-client-id"], "A configured service token never travels over cleartext")
            XCTAssertNil(request.headers["cf-access-client-secret"])
        }
    }

    func testSameOriginSignInPortalIsBrowserSignInEverywhere() async throws {
        // A sign-in portal on the dashboard's own origin (a forward-auth gate
        // in front of Hermes mounted under /hermes): the real delegate follows
        // the same-origin redirect and lands on the portal's page. Every
        // surface opens the browser view for it, none calls it an unexpected
        // server, and none asks for capability or sends a password.
        let dashboard = try LoopbackHTTPServer.start { request in
            if request.path == "/hermes/api/auth/providers" {
                return LoopbackHTTPResponse(
                    status: 302,
                    headers: [("Location", "/portal/sign-in")],
                    body: Data()
                )
            }
            if request.path == "/portal/sign-in" {
                return LoopbackHTTPResponse(
                    status: 200,
                    headers: [("Content-Type", "text/html")],
                    body: Data("<html>sign in</html>".utf8)
                )
            }
            return .json(status: 404, body: #"{"detail":"Not found"}"#)
        }
        defer { dashboard.stop() }
        let baseURL = "http://127.0.0.1:\(dashboard.port)/hermes"

        let login = await loginOutcome(baseURL, session: Self.realSession())
        XCTAssertEqual(login, .interactive(.browser(.authProxyRedirect)))
        let setup = await setupOutcome(baseURL, session: Self.realSession())
        XCTAssertEqual(setup, .interactive(.browser(.authProxyRedirect)))
        let repair = await repairOutcome(baseURL, session: Self.realSession())
        XCTAssertEqual(repair, .opens(.browser(.authProxyRedirect)))

        XCTAssertEqual(
            dashboard.receivedRequests.map(\.path),
            Array(repeating: ["/hermes/api/auth/providers", "/portal/sign-in"], count: 3).flatMap { $0 },
            "One discovery and its same-origin redirect per surface: no capability check, no password"
        )
    }

    func testFreshFirstRunReachesDiscoveryOverRealTransportWithZeroPasswordRequests() async throws {
        let dashboard = try LoopbackHTTPServer.start { request in
            request.path == "/api/auth/providers"
                ? .json(status: 200, body: #"{"providers":[{"name":"basic","supports_password":true}]}"#)
                : .json(status: 404, body: #"{"detail":"Not found"}"#)
        }
        defer { dashboard.stop() }

        // Setup: the first-run wizard reaches the test with only an address.
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        flow.selectAccessMethod(.lan)
        flow.confirmDetailsReady()
        flow.draft.lan.host = "127.0.0.1"
        flow.draft.lan.port = String(dashboard.port)
        flow.submitDetails()
        XCTAssertEqual(flow.step, .connectionTest, "No credentials step before discovery")
        let generation = try XCTUnwrap(flow.beginTest())
        let configuration = try flow.draft.testConfiguration()
        var events: [ConnectionSetupTestEvent] = []
        _ = await ConnectionSetupProbe(sessionConfiguration: Self.realSession()).runTest(
            result: configuration,
            cloudflareAccess: nil,
            onEvent: { events.append($0) }
        )
        for event in events {
            flow.applyTestEvent(event, generation: generation)
        }
        XCTAssertTrue(flow.testState.requiresCredentials, "Discovery proved a password dashboard; only now are credentials asked for")

        // Login: Continue with only the address opens the sign-in step.
        let login = await loginOutcome(configuration.serverURL, session: Self.realSession())
        XCTAssertEqual(login, .password)

        XCTAssertEqual(dashboard.receivedRequests.map(\.path), ["/api/auth/providers", "/api/auth/providers"])
        XCTAssertNil(dashboard.lastRequest(path: "/auth/password-login"), "Zero password requests")
    }

    // MARK: - Surfaces

    /// The sign-in screen's decision (`LoginRoute`), then, for a password
    /// dashboard that also offers a browser sign-in, that sign-in picked the
    /// way "Sign in with browser instead" picks it.
    private func loginOutcome(
        _ baseURL: String,
        access: CloudflareAccessCredentials? = nil,
        session: URLSessionConfiguration
    ) async -> Kind {
        let client = NativeAuthClient(baseURL: baseURL, cloudflareAccess: access, sessionConfiguration: session)
        let route: LoginRoute
        do {
            route = try await LoginRoute.discover(using: client)
        } catch {
            return .failure(ConnectionFailureClassifier.classify(error))
        }
        switch route {
        case .password(nil):
            return .password
        case .password(let offer?):
            do {
                let picked = try await DashboardSignInResolver(client: client).signIn(for: offer)
                return .choice(offer: offer, pick: .opens(picked))
            } catch {
                return .choice(offer: offer, pick: .fails(ConnectionFailureClassifier.classify(error)))
            }
        case .interactive(let signIn):
            return .interactive(signIn)
        }
    }

    private func setupOutcome(
        _ baseURL: String,
        access: CloudflareAccessCredentials? = nil,
        session: URLSessionConfiguration
    ) async -> SetupOutcome {
        var events: [ConnectionSetupTestEvent] = []
        _ = await ConnectionSetupProbe(sessionConfiguration: session).runTest(
            result: ConnectionSetupResult(serverURL: baseURL, username: "", password: ""),
            cloudflareAccess: access,
            onEvent: { events.append($0) }
        )
        switch events.last {
        case .requiresCredentials(.authentication): return .password
        case .requiresInteractiveSignIn(.authentication, let signIn): return .interactive(signIn)
        case .requiresSignInChoice(.authentication, let offer): return .choice(offer)
        case .failed(_, let failure): return .failure(failure)
        default: return .failure(.unknown)
        }
    }

    /// Repair runs the same staged test, then Sign In to Reconnect opens
    /// what that test decided: no second discovery.
    private func repairOutcome(
        _ baseURL: String,
        access: CloudflareAccessCredentials? = nil,
        session: URLSessionConfiguration
    ) async -> RepairOutcome {
        var state = ConnectionSetupTestState()
        _ = await ConnectionSetupProbe(sessionConfiguration: session).runTest(
            result: ConnectionSetupResult(serverURL: baseURL, username: "", password: ""),
            cloudflareAccess: access,
            onEvent: { state.apply($0) }
        )
        if let failure = state.failedFailure {
            return .failure(failure)
        }
        let resolver = DashboardSignInResolver(client: NativeAuthClient(
            baseURL: baseURL,
            cloudflareAccess: access,
            sessionConfiguration: session
        ))
        do {
            guard let opened = try await ConnectionRepairSignIn.signIn(for: state, resolver: resolver) else {
                return .opensNothing
            }
            return .opens(opened)
        } catch {
            return .failure(ConnectionFailureClassifier.classify(error))
        }
    }
}

// MARK: - URLProtocol fixture (hosts disjoint from the other suites)

private final class AgreementURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        requests.removeAll()
        lock.unlock()
    }

    static func requestCount(host: String, path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.url?.host == host && $0.url?.path == path }.count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasPrefix("agree-") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()
        guard let (status, headers, body) = Self.fixture(host: host, path: url.path),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func fixture(host: String, path: String) -> (Int, [String: String], String)? {
        let json = ["Content-Type": "application/json"]
        let html = ["Content-Type": "text/html"]
        let oidc = #"{"name":"self-hosted","display_name":"Self-Hosted OIDC","supports_password":false}"#
        let basic = #"{"name":"basic","supports_password":true}"#
        let prePassword = #"{"name":"nous","display_name":"Nous Research"}"#
        let native = #"{"auth_flows":["cookie","native_pkce"]}"#
        let legacyStatus = #"{"status":"ok"}"#
        let name = host.replacingOccurrences(of: ".example.test", with: "")
        switch (name, path) {
        case ("agree-password", "/api/auth/providers"):
            return (200, json, "{\"providers\":[\(basic)]}")
        case ("agree-native", "/api/auth/providers"), ("agree-legacy", "/api/auth/providers"),
             ("agree-status-malformed", "/api/auth/providers"), ("agree-status-5xx", "/api/auth/providers"):
            return (200, json, "{\"providers\":[\(oidc)]}")
        case ("agree-mixed-native", "/api/auth/providers"), ("agree-mixed-legacy", "/api/auth/providers"),
             ("agree-mixed-status-5xx", "/api/auth/providers"):
            return (200, json, "{\"providers\":[\(basic),\(oidc)]}")
        case ("agree-prepassword", "/api/auth/providers"):
            return (200, json, "{\"providers\":[\(prePassword)]}")
        case ("agree-mixed-prepassword", "/api/auth/providers"):
            return (200, json, "{\"providers\":[\(basic),\(prePassword)]}")
        case ("agree-native", "/api/status"), ("agree-mixed-native", "/api/status"):
            return (200, json, native)
        case ("agree-legacy", "/api/status"), ("agree-mixed-legacy", "/api/status"):
            return (200, json, legacyStatus)
        case ("agree-status-malformed", "/api/status"):
            return (200, html, "<html>status</html>")
        case ("agree-status-5xx", "/api/status"), ("agree-mixed-status-5xx", "/api/status"),
             ("agree-discovery-5xx", "/api/auth/providers"):
            return (503, json, #"{"detail":"unavailable"}"#)
        case ("agree-proxy", _):
            // A URLProtocol 302 delivered as a response is final: URLSession
            // never asks the redirect delegate about it. That the redirect
            // is never followed is proven over real transport by
            // testAuthProxyRedirectIsBrowserSignInEverywhereAndNeverFollowed.
            return (302, ["Location": "https://idp.agree-proxy-signin.example.test/authorize"], "")
        case ("agree-unrecognized", _):
            return (200, html, "<html>not hermes</html>")
        case ("agree-empty", "/api/auth/providers"):
            return (200, json, #"{"providers":[]}"#)
        default:
            return nil
        }
    }
}
