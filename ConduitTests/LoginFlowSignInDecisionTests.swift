//
//  LoginFlowSignInDecisionTests.swift
//  Conduit
//
//  The sign-in screen's address step on the shared sign-in decision: the
//  address alone reaches discovery, only a password decision opens the
//  sign-in step, a dashboard offering a browser sign-in beside its password
//  asks for native capability only once that sign-in is picked, and an
//  answer only counts for the address and Cloudflare token it was asked
//  with. Wire-level cases drive the real NativeAuthClient through a
//  URLProtocol fixture; fencing cases use a scripted transport whose answer
//  arrives after the edit, the way a response already in flight would.
//

import XCTest
@testable import Conduit

@MainActor
final class LoginFlowSignInDecisionTests: XCTestCase {
    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var avatarsRoot: URL!
    /// The flow holds its AppState weakly: the tests keep theirs alive.
    private var appStates: [AppState] = []

    override func setUp() {
        super.setUp()
        defaultsSuite = "LoginFlowSignInDecisionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        avatarsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoginFlowSignInDecisionTests.\(UUID().uuidString)", isDirectory: true)
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        LoginFlowDiscoveryURLProtocol.reset()
    }

    override func tearDown() {
        LoginFlowDiscoveryURLProtocol.reset()
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: avatarsRoot)
        appStates = []
        super.tearDown()
    }

    private func makeAppState() -> AppState {
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: defaults,
                avatarsRoot: avatarsRoot,
                legacyAvatarDirectories: [avatarsRoot]
            )
        )
        appStates.append(appState)
        return appState
    }

    /// A flow on the real client, answered by the URLProtocol fixture.
    private func makeWireFlow() -> (LoginFlowModel, AppState) {
        let flow = LoginFlowModel(makeTransport: { baseURL, access in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LoginFlowDiscoveryURLProtocol.self]
            return NativeAuthClient(baseURL: baseURL, cloudflareAccess: access, sessionConfiguration: configuration)
        })
        let appState = makeAppState()
        flow.attach(appState)
        return (flow, appState)
    }

    // MARK: - Discovery outcomes

    func testAddressOnlyContinueOpensTheSignInStepWithoutAPasswordRequest() async {
        let (flow, _) = makeWireFlow()
        let host = "flow-password.example.test"
        flow.address = "https://\(host)"

        await flow.continueFromAddress()

        XCTAssertTrue(flow.showsCredentials, "A password decision opens the sign-in step")
        XCTAssertEqual(flow.target?.baseURL, "https://\(host)")
        XCTAssertNil(flow.target?.browserOffer)
        XCTAssertNil(flow.failure)
        XCTAssertEqual(LoginFlowDiscoveryURLProtocol.requestCount(host: host, path: "/api/auth/providers"), 1)
        XCTAssertEqual(LoginFlowDiscoveryURLProtocol.requestCount(host: host, path: "/auth/password-login"), 0)
        XCTAssertEqual(LoginFlowDiscoveryURLProtocol.requestCount(host: host, path: "/api/status"), 0)
    }

    func testAMixedDashboardOffersItsBrowserSignInWithoutAskingForCapabilityFirst() async {
        let (flow, _) = makeWireFlow()
        let host = "flow-mixed.example.test"
        flow.address = "https://\(host)"

        await flow.continueFromAddress()

        XCTAssertTrue(flow.showsCredentials)
        XCTAssertEqual(flow.target?.browserOffer, .nativeCapable(provider: "self-hosted"))
        XCTAssertEqual(
            LoginFlowDiscoveryURLProtocol.requestCount(host: host, path: "/api/status"), 0,
            "The password needs nothing from the capability check, so it waits for the browser pick"
        )
    }

    func testPickingTheBrowserSignInChecksCapabilityThenOpensSafari() async {
        let (flow, _) = makeWireFlow()
        let host = "flow-mixed.example.test"
        flow.address = "https://\(host)"
        await flow.continueFromAddress()

        await flow.signInWithBrowserInstead()

        XCTAssertEqual(flow.nativeOAuthRequest?.baseURL, "https://\(host)")
        XCTAssertEqual(flow.nativeOAuthRequest?.provider, "self-hosted")
        XCTAssertNil(flow.browserRequest)
        XCTAssertEqual(LoginFlowDiscoveryURLProtocol.requestCount(host: host, path: "/api/status"), 1)
    }

    func testPickingTheBrowserSignInOpensSafariAtOnceWhenTheProviderAnswerAdvertisedIt() async {
        // Behind an auth edge `/api/status` needs a bearer; the provider
        // answer's `auth_flows` already name native sign-in.
        let (flow, _) = makeWireFlow()
        let host = "flow-mixed-edge.example.test"
        flow.address = "https://\(host)"
        await flow.continueFromAddress()
        XCTAssertTrue(flow.showsCredentials)

        await flow.signInWithBrowserInstead()

        XCTAssertEqual(flow.nativeOAuthRequest?.baseURL, "https://\(host)")
        XCTAssertEqual(flow.nativeOAuthRequest?.provider, "self-hosted")
        XCTAssertNil(flow.browserRequest)
        XCTAssertNil(flow.failure)
        XCTAssertEqual(LoginFlowDiscoveryURLProtocol.requestCount(host: host, path: "/api/status"), 0)
    }

    func testAFailedCapabilityCheckFailsOnlyTheBrowserPickAndKeepsThePassword() async {
        let (flow, _) = makeWireFlow()
        let host = "flow-mixed-status-5xx.example.test"
        flow.address = "https://\(host)"
        await flow.continueFromAddress()
        XCTAssertTrue(flow.showsCredentials, "A broken capability answer never hides the password")

        await flow.signInWithBrowserInstead()

        XCTAssertEqual(flow.failure(at: .credentials)?.classifiedFailure, .dashboardUnavailable)
        XCTAssertNil(flow.nativeOAuthRequest, "Nothing falls back to Safari")
        XCTAssertNil(flow.browserRequest, "Nothing falls back to the browser view")
        XCTAssertNotNil(flow.target, "The password sign-in is still there")
        XCTAssertEqual(LoginFlowDiscoveryURLProtocol.requestCount(host: host, path: "/auth/password-login"), 0)
    }

    func testAPrePasswordProviderListOpensTheDashboardsOwnSignInPage() async {
        let (flow, _) = makeWireFlow()
        flow.address = "https://flow-prepassword.example.test"

        await flow.continueFromAddress()

        XCTAssertEqual(flow.browserRequest?.baseURL, "https://flow-prepassword.example.test")
        XCTAssertNil(flow.nativeOAuthRequest)
        XCTAssertFalse(flow.showsCredentials)
    }

    func testAPageThatIsNotHermesIsAnErrorNeverTheBrowser() async {
        for host in ["flow-foreign.example.test", "flow-empty.example.test"] {
            let (flow, _) = makeWireFlow()
            flow.address = "https://\(host)"

            await flow.continueFromAddress()

            XCTAssertEqual(flow.failure(at: .address)?.classifiedFailure, .unexpectedServerResponse, host)
            XCTAssertNil(flow.browserRequest, host)
            XCTAssertNil(flow.nativeOAuthRequest, host)
            XCTAssertFalse(flow.showsCredentials, host)
        }
    }

    // MARK: - Cloudflare service token

    /// A token switched on with a field left empty would be dropped, not
    /// sent: Continue stays off, and the keyboard's submit gets a notice
    /// instead of a sign-in without the token.
    func testAnIncompleteServiceTokenStopsAtTheAddressInsteadOfSigningInWithoutIt() async {
        let transport = RecordingTransport(unreachable: [])
        var asked: [CloudflareAccessCredentials?] = []
        let flow = LoginFlowModel(makeTransport: { baseURL, access in
            asked.append(access)
            return transport.client(for: baseURL)
        })
        flow.attach(makeAppState())
        flow.address = "https://half-token.example.test"
        flow.cloudflareEnabled = true
        flow.cloudflareClientID = "client-id"
        flow.cloudflareClientSecret = ""

        XCTAssertFalse(flow.canContinue, "Continue waits for the secret")
        await flow.continueFromAddress()

        XCTAssertTrue(asked.isEmpty, "Nothing is asked without the requested token")
        XCTAssertNotNil(flow.failure(at: .address), "The address step says what is missing")
        XCTAssertNil(flow.target)
        XCTAssertNil(flow.browserRequest)
        XCTAssertNil(flow.nativeOAuthRequest)
        XCTAssertFalse(flow.showsCredentials)

        flow.cloudflareClientSecret = "client-secret"
        XCTAssertTrue(flow.canContinue)
        await flow.continueFromAddress()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first??.clientID, "client-id", "The completed token is the one sent")
    }

    /// The same half-typed token on a saved dashboard's address never
    /// borrows that dashboard's older token.
    func testAnIncompleteServiceTokenNeverFallsBackToTheSavedOne() async throws {
        let transport = RecordingTransport(unreachable: [])
        var asked: [CloudflareAccessCredentials?] = []
        let flow = LoginFlowModel(makeTransport: { baseURL, access in
            asked.append(access)
            return transport.client(for: baseURL)
        })
        let appState = makeAppState()
        flow.attach(appState)
        let baseURL = "https://saved-token.example.test"
        let dashboardID = try XCTUnwrap(appState.resolveDashboardID(forURL: baseURL, registerIfMissing: true))
        KeychainHelper.saveCloudflareAccess(
            try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "old-id", clientSecret: "old-secret")),
            origin: baseURL,
            dashboardID: dashboardID
        )
        flow.address = baseURL
        flow.cloudflareEnabled = true
        flow.cloudflareClientID = ""
        flow.cloudflareClientSecret = "new-secret"

        await flow.continueFromAddress()

        XCTAssertTrue(asked.isEmpty, "The saved token is not used in place of the typed one")
        XCTAssertNotNil(flow.failure(at: .address))
        XCTAssertNil(flow.target)
    }

    // MARK: - Browser sign-in session store

    /// A new address's browser sign-in uses the WebKit store of the
    /// dashboard it saves, so Sign Out, Remove Dashboard and the abandoned
    /// attempt's cleanup clear the store that holds its cookies.
    func testANewAddresssBrowserSignInUsesItsSavedDashboardsWebKitStore() async throws {
        let (flow, appState) = makeWireFlow()
        let baseURL = "https://flow-prepassword.example.test"
        flow.address = baseURL

        await flow.continueFromAddress()

        let request = try XCTUnwrap(flow.browserRequest)
        let dashboardID = appState.resolveDashboardID(forURL: baseURL, registerIfMissing: false)
        XCTAssertNotNil(dashboardID, "The new address has its saved dashboard before the sheet opens")
        XCTAssertEqual(request.webKitStoreID, dashboardID)

        flow.discardUnfinishedDashboards()
        XCTAssertNil(
            appState.resolveDashboardID(forURL: baseURL, registerIfMissing: false),
            "Nobody signed in: the attempt's dashboard, and with it its store, is forgotten"
        )
    }

    func testANewAddresssBrowserSignInWithAServiceTokenUsesTheSameStoreItsTokenIsSavedTo() async throws {
        let (flow, appState) = makeWireFlow()
        let baseURL = "https://flow-prepassword.example.test"
        flow.address = baseURL
        flow.cloudflareEnabled = true
        flow.cloudflareClientID = "client-id"
        flow.cloudflareClientSecret = "client-secret"

        await flow.continueFromAddress()

        let request = try XCTUnwrap(flow.browserRequest)
        let dashboardID = try XCTUnwrap(appState.resolveDashboardID(forURL: baseURL, registerIfMissing: false))
        XCTAssertEqual(request.webKitStoreID, dashboardID)
        XCTAssertEqual(KeychainHelper.loadCloudflareAccess(dashboardID: dashboardID, for: baseURL)?.clientID, "client-id")
    }

    // MARK: - Fencing

    func testEditingTheAddressWhileDiscoveryRunsDropsTheLateAnswer() async {
        let transport = HeldDiscoveryTransport(answer: .providers([["name": "basic", "supports_password": true]]))
        let flow = LoginFlowModel(makeTransport: { _, _ in transport })
        flow.attach(makeAppState())
        flow.address = "https://first.example.test"

        let running = Task { await flow.continueFromAddress() }
        await transport.waitUntilAsked()
        flow.address = "https://second.example.test"
        transport.answer()
        await running.value

        XCTAssertFalse(flow.showsCredentials, "The answer was for the address that is no longer typed")
        XCTAssertNil(flow.target)
        XCTAssertNil(flow.failure)
        XCTAssertEqual(flow.address, "https://second.example.test", "The edit stays as typed")
        XCTAssertFalse(flow.isWorking)
    }

    func testChangingTheCloudflareTokenWhileDiscoveryRunsDropsTheLateAnswer() async {
        let transport = HeldDiscoveryTransport(answer: .interactiveSignInRequired)
        let flow = LoginFlowModel(makeTransport: { _, _ in transport })
        let appState = makeAppState()
        flow.attach(appState)
        flow.address = "https://proxied.example.test"

        let running = Task { await flow.continueFromAddress() }
        await transport.waitUntilAsked()
        flow.cloudflareEnabled = true
        flow.cloudflareClientID = "late-id"
        transport.answer()
        await running.value

        XCTAssertNil(flow.browserRequest, "A decision made without the token opens nothing")
        XCTAssertNil(
            appState.resolveDashboardID(forURL: "https://proxied.example.test", registerIfMissing: false),
            "Nothing was saved for the abandoned answer"
        )
    }

    func testAnUneditedAnswerStillOpensItsSignIn() async {
        let transport = HeldDiscoveryTransport(answer: .interactiveSignInRequired)
        let flow = LoginFlowModel(makeTransport: { _, _ in transport })
        flow.attach(makeAppState())
        flow.address = "proxied.example.test"

        let running = Task { await flow.continueFromAddress() }
        await transport.waitUntilAsked()
        transport.answer()
        await running.value

        XCTAssertEqual(flow.browserRequest?.baseURL, "https://proxied.example.test")
        XCTAssertEqual(flow.address, "https://proxied.example.test", "The checked address replaces what was typed")
    }

    // MARK: - Sign-in codes

    /// A scanned code's password belongs to the code's dashboard. When its
    /// address check fails and the address is then edited, Retry checks the
    /// new address and never sends the code's password there.
    func testEditingTheAddressAfterACodesFailedCheckNeverSendsItsPasswordElsewhere() async {
        let transport = RecordingTransport(unreachable: ["https://code.example.test"])
        let flow = LoginFlowModel(makeTransport: { baseURL, _ in transport.client(for: baseURL) })
        flow.attach(makeAppState())
        flow.address = "https://code.example.test"
        flow.username = "code-user"
        flow.password = "code-fixture"

        await flow.signInFromLink()
        XCTAssertEqual(flow.failurePlace, .address, "The code's dashboard didn't answer")

        flow.address = "https://other.example.test"
        await flow.retry()

        XCTAssertEqual(transport.signIns, [], "No password went to the edited address")
        XCTAssertTrue(flow.showsCredentials, "The edited address gets its own sign-in step")
    }
}

// MARK: - Scripted transport

/// Discovery that answers only once the test says so.
private final class HeldDiscoveryTransport: DashboardSignInTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let result: AuthProviderDiscoveryResult
    private var asked = false
    private var released = false
    private var askedWaiters: [CheckedContinuation<Void, Never>] = []
    private var answerWaiters: [CheckedContinuation<Void, Never>] = []

    init(answer: AuthProviderDiscoveryResult) {
        result = answer
    }

    func waitUntilAsked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if asked {
                lock.unlock()
                continuation.resume()
            } else {
                askedWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func answer() {
        lock.lock()
        released = true
        let waiters = answerWaiters
        answerWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func authProviderDiscovery() async throws -> AuthProviderDiscoveryResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            asked = true
            let waiting = askedWaiters
            askedWaiters = []
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                answerWaiters.append(continuation)
                lock.unlock()
            }
            waiting.forEach { $0.resume() }
        }
        return result
    }

    func supportsNativeOAuth() async throws -> Bool { true }

    func connect(username: String, password: String) async throws -> NativeAuthConnection {
        throw AuthClientError.loginFailed(status: 401, detail: "scripted")
    }
}

// MARK: - URLProtocol fixture (hosts disjoint from the other suites)

private final class LoginFlowDiscoveryURLProtocol: URLProtocol {
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
        request.url?.host?.hasPrefix("flow-") == true
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
        let basic = #"{"name":"basic","supports_password":true}"#
        let oidc = #"{"name":"self-hosted","display_name":"Self-Hosted OIDC","supports_password":false}"#
        switch (host, path) {
        case ("flow-password.example.test", "/api/auth/providers"):
            return (200, json, "{\"providers\":[\(basic)]}")
        case ("flow-mixed.example.test", "/api/auth/providers"),
             ("flow-mixed-status-5xx.example.test", "/api/auth/providers"):
            return (200, json, "{\"providers\":[\(basic),\(oidc)]}")
        case ("flow-mixed-edge.example.test", "/api/auth/providers"):
            return (200, json, "{\"providers\":[\(basic),\(oidc)],\"auth_flows\":[\"cookie\",\"native_pkce\"]}")
        case ("flow-mixed-edge.example.test", _):
            return (401, json, #"{"detail":"Unauthorized"}"#)
        case ("flow-mixed.example.test", "/api/status"):
            return (200, json, #"{"auth_flows":["cookie","native_pkce"]}"#)
        case ("flow-mixed-status-5xx.example.test", "/api/status"):
            return (503, json, #"{"detail":"unavailable"}"#)
        case ("flow-prepassword.example.test", "/api/auth/providers"):
            return (200, json, #"{"providers":[{"name":"nous","display_name":"Nous Research"}]}"#)
        case ("flow-foreign.example.test", _):
            return (200, ["Content-Type": "text/html"], "<html>not hermes</html>")
        case ("flow-empty.example.test", "/api/auth/providers"):
            return (200, json, #"{"providers":[]}"#)
        default:
            return nil
        }
    }
}

/// Discovery per address (unreachable ones fail), recording every
/// password sign-in by address.
private final class RecordingTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let unreachable: Set<String>
    private var recorded: [String] = []

    init(unreachable: Set<String>) {
        self.unreachable = unreachable
    }

    var signIns: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func client(for baseURL: String) -> any DashboardSignInTransport {
        Client(baseURL: baseURL, owner: self)
    }

    fileprivate func record(_ baseURL: String) {
        lock.lock()
        recorded.append(baseURL)
        lock.unlock()
    }

    private struct Client: DashboardSignInTransport {
        let baseURL: String
        let owner: RecordingTransport

        func authProviderDiscovery() async throws -> AuthProviderDiscoveryResult {
            if owner.unreachable.contains(baseURL) { throw URLError(.cannotFindHost) }
            return .providers([["name": "basic", "supports_password": true]])
        }

        func supportsNativeOAuth() async throws -> Bool { false }

        func connect(username: String, password: String) async throws -> NativeAuthConnection {
            owner.record(baseURL)
            throw AuthClientError.loginFailed(status: 401, detail: "scripted")
        }
    }
}
