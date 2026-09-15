import Foundation
import Network
import XCTest
@testable import Conduit

private final class NativeOAuthURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else { throw URLError(.badURL) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class NativeOAuthTests: XCTestCase {
    private var backend: InMemoryKeychainBackend!

    override func setUp() {
        super.setUp()
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        NativeOAuthURLProtocolStub.handler = nil
    }

    override func tearDown() {
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        NativeOAuthURLProtocolStub.handler = nil
        backend = nil
        super.tearDown()
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        XCTAssertEqual(
            NativeOAuthFlow.pkceChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testGeneratedPKCEUsesRequiredVerifierLengthAndS256() throws {
        let pair = try NativeOAuthFlow.generatePKCE()
        XCTAssertEqual(pair.verifier.count, 43)
        XCTAssertEqual(pair.challenge, NativeOAuthFlow.pkceChallenge(verifier: pair.verifier))
        XCTAssertFalse(pair.challenge.contains("="))
    }

    func testAuthorizeURLPreservesPathPrefixAndEncodesBrokerParameters() throws {
        let url = try NativeOAuthFlow.authorizeURL(
            baseURL: "https://hermes.example/team/hermes/",
            challenge: "challenge-value",
            redirectURI: "http://127.0.0.1:49152/callback",
            state: "state-value",
            provider: "google"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(components.path, "/team/hermes/auth/native/authorize")
        XCTAssertEqual(try XCTUnwrap(values["code_challenge"]), "challenge-value")
        XCTAssertEqual(try XCTUnwrap(values["code_challenge_method"]), "S256")
        XCTAssertEqual(try XCTUnwrap(values["redirect_uri"]), "http://127.0.0.1:49152/callback")
        XCTAssertEqual(try XCTUnwrap(values["state"]), "state-value")
        XCTAssertEqual(try XCTUnwrap(values["provider"]), "google")
    }

    func testAuthorizeURLOmitsProviderForServerChooser() throws {
        let url = try NativeOAuthFlow.authorizeURL(
            baseURL: "https://hermes.example",
            challenge: "challenge",
            redirectURI: "http://127.0.0.1:49152/callback",
            state: "state"
        )
        XCTAssertFalse(try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            .contains { $0.name == "provider" })
    }

    func testCallbackRequiresExactPathMatchingStateAndCode() throws {
        XCTAssertEqual(
            try NativeOAuthFlow.callbackCode(
                requestTarget: "/callback?code=one-time-code&state=expected",
                expectedState: "expected",
                expectedPort: 49152
            ),
            "one-time-code"
        )
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/other?code=one-time-code&state=expected",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .callbackMalformed) }
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?code=one-time-code&state=attacker",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .stateMismatch) }
    }

    func testCallbackRejectsProviderErrorMissingCodeAndDuplicateState() {
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?error=access_denied&state=expected",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .callbackRejected) }
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?state=expected",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .callbackMalformed) }
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?code=value&state=expected&state=attacker",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .callbackMalformed) }
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?error=access_denied&state=attacker",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .stateMismatch) }
    }

    func testTokenResponseDecodesAndRefreshBoundaryIsEarly() throws {
        let data = Data(#"{"access_token":"access","refresh_token":"refresh","expires_at":2000,"provider":"google","user_id":"luc"}"#.utf8)
        let tokens = try JSONDecoder().decode(NativeOAuthTokenSet.self, from: data)
        XCTAssertEqual(tokens.accessToken, "access")
        XCTAssertEqual(tokens.refreshToken, "refresh")
        XCTAssertEqual(tokens.provider, "google")
        XCTAssertFalse(tokens.needsRefresh(now: Date(timeIntervalSince1970: 1939)))
        XCTAssertTrue(tokens.needsRefresh(now: Date(timeIntervalSince1970: 1940)))
    }

    func testNativeTokenKeychainRecordsAreDashboardScopedAndClearIndependently() {
        let a = UUID()
        let b = UUID()
        let tokensA = NativeOAuthTokenSet(accessToken: "a", refreshToken: "ra", expiresAt: 2_000, provider: "google", userID: "a-user")
        let tokensB = NativeOAuthTokenSet(accessToken: "b", refreshToken: "rb", expiresAt: 3_000, provider: "google", userID: "b-user")
        KeychainHelper.saveNativeOAuthTokens(tokensA, dashboardID: a)
        KeychainHelper.saveNativeOAuthTokens(tokensB, dashboardID: b)

        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: a), tokensA)
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: b), tokensB)
        KeychainHelper.clearNativeOAuthTokens(dashboardID: a)
        XCTAssertNil(KeychainHelper.loadNativeOAuthTokens(dashboardID: a))
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: b), tokensB)
    }

    func testCommittingPasswordCookiesMakesCookieAuthenticationAuthoritative() {
        let dashboardID = UUID()
        KeychainHelper.saveNativeOAuthTokens(
            NativeOAuthTokenSet(
                accessToken: "stale-access",
                refreshToken: "stale-refresh",
                expiresAt: 3_000,
                provider: "google",
                userID: "user"
            ),
            dashboardID: dashboardID
        )

        NativeAuthConnection.debugStub(ticket: "password-ticket").commitCookies(dashboardID: dashboardID)

        XCTAssertNil(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID))
    }

    func testProviderClassificationSupportsOAuthOnlyAndMixedDashboards() {
        let password: [String: Any] = ["name": "basic", "supports_password": true, "supports_session": true]
        let google: [String: Any] = ["name": "google", "supports_password": false, "supports_session": true]
        XCTAssertTrue(HermesProviderCheck.hasNativeOAuthProvider([google]))
        XCTAssertEqual(HermesProviderCheck.nativeOAuthProvider([google]), "google")
        XCTAssertTrue(HermesProviderCheck.supportsPassword([password, google]))
        XCTAssertTrue(HermesProviderCheck.hasNativeOAuthProvider([password, google]))
    }

    func testProviderClassificationUsesHermesSessionProviderEndpointContract() {
        // Hermes' `/api/auth/providers` lists session providers and currently
        // emits no `supports_session` key. A non-password entry is therefore
        // an interactive OAuth provider, not an ambiguous legacy provider.
        let google: [String: Any] = ["name": "google", "supports_password": false]
        XCTAssertTrue(HermesProviderCheck.hasNativeOAuthProvider([google]))
        XCTAssertEqual(HermesProviderCheck.nativeOAuthProvider([google]), "google")
    }

    func testProviderClassificationRequiresExplicitNonPasswordSignal() {
        let ambiguous: [String: Any] = ["name": "legacy"]
        let disabled: [String: Any] = ["name": "disabled", "supports_password": false, "supports_session": false]
        XCTAssertFalse(HermesProviderCheck.hasNativeOAuthProvider([ambiguous, disabled]))
        XCTAssertNil(HermesProviderCheck.nativeOAuthProvider([ambiguous, disabled]))
    }

    func testHTTPRequestAccumulatorHandlesSplitHeadersAndEnforcesBound() throws {
        var accumulator = NativeOAuthHTTPRequestAccumulator(maximumBytes: 128)
        XCTAssertFalse(try accumulator.append(Data("GET /callback?code=abc".utf8)))
        XCTAssertFalse(try accumulator.append(Data("&state=expected HTTP/1.1\r\nHost:".utf8)))
        XCTAssertTrue(try accumulator.append(Data(" 127.0.0.1\r\n\r\n".utf8)))
        XCTAssertTrue(String(data: accumulator.data, encoding: .utf8)?.contains("code=abc") == true)

        var oversized = NativeOAuthHTTPRequestAccumulator(maximumBytes: 3)
        XCTAssertThrowsError(try oversized.append(Data("four".utf8))) {
            XCTAssertEqual($0 as? NativeOAuthHTTPReadError, .tooLarge)
        }
    }

    func testCancellationDuringListenerStartupPreservesCancellation() async {
        let server = NativeOAuthLoopbackServer(expectedState: "expected")
        // Both operations serialize on the server queue, making this a
        // deterministic cancellation-before-readiness test rather than a
        // race against Network.framework's listener startup.
        server.stop()
        do {
            _ = try await server.start(timeout: 5)
            XCTFail("Cancellation before readiness must not look like success")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testLoopbackStopCancelsClientWithWithheldHeaders() async throws {
        let server = NativeOAuthLoopbackServer(expectedState: "expected")
        let port = try await server.start(timeout: 5)
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)),
            using: .tcp
        )
        let ready = expectation(description: "loopback client ready")
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "NativeOAuthTests.partial-client"))
        await fulfillment(of: [ready], timeout: 2)
        connection.send(
            content: Data("GET /callback?code=incomplete HTTP/1.1\r\nHost:".utf8),
            completion: .contentProcessed { _ in }
        )

        for _ in 0..<20 {
            if await server.debugActiveConnectionCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let activeBeforeStop = await server.debugActiveConnectionCount()
        XCTAssertEqual(activeBeforeStop, 1)

        server.stop()
        do {
            _ = try await server.waitForCallback()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let activeAfterStop = await server.debugActiveConnectionCount()
        XCTAssertEqual(activeAfterStop, 0)
        connection.cancel()
    }

    func testMultipleOAuthProvidersDelegateChoiceToHermes() {
        let google: [String: Any] = ["name": "google", "supports_password": false]
        let oidc: [String: Any] = ["name": "corporate", "supports_password": false]
        XCTAssertTrue(HermesProviderCheck.hasNativeOAuthProvider([google, oidc]))
        XCTAssertNil(HermesProviderCheck.nativeOAuthProvider([google, oidc]))
    }

    private func makeClient() -> NativeOAuthAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeOAuthURLProtocolStub.self]
        return NativeOAuthAPIClient(baseURL: "https://hermes.example", sessionConfiguration: configuration)
    }

    private func tokens(access: String = "old-access", expiresAt: TimeInterval = 4_000_000_000) -> NativeOAuthTokenSet {
        NativeOAuthTokenSet(
            accessToken: access,
            refreshToken: "refresh-token",
            expiresAt: expiresAt,
            provider: "google",
            userID: "user"
        )
    }

    @MainActor
    func testBridgeAuthModeReflectsDashboardScopedTokens() {
        let dashboardID = UUID()
        KeychainHelper.saveNativeOAuthTokens(tokens(), dashboardID: dashboardID)
        let bearerBridge = DashboardTicketBridge(baseURL: "https://hermes.example", dashboardID: dashboardID)
        XCTAssertTrue(bearerBridge.usesNativeOAuth)
        bearerBridge.invalidate()

        KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
        let cookieBridge = DashboardTicketBridge(baseURL: "https://hermes.example", dashboardID: dashboardID)
        XCTAssertFalse(cookieBridge.usesNativeOAuth)
        cookieBridge.invalidate()
    }

    @MainActor
    func testInvalidatedSessionCannotTouchReplacementTokens() async {
        let dashboardID = UUID()
        let session = NativeOAuthSession(tokens: tokens(), dashboardID: dashboardID, client: makeClient())
        session.invalidate()
        let replacement = tokens(access: "replacement-access")
        KeychainHelper.saveNativeOAuthTokens(replacement, dashboardID: dashboardID)

        do {
            _ = try await session.requestJSON(path: "/api/status")
            XCTFail("An invalidated session must not perform transport work")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID), replacement)
    }

    @MainActor
    func testBearerResponseStopsAtConfiguredByteLimitWithoutContentLength() async {
        NativeOAuthURLProtocolStub.handler = { _ in
            (200, ["payload": String(repeating: "x", count: 128)])
        }
        let session = NativeOAuthSession(tokens: tokens(), dashboardID: UUID(), client: makeClient())

        do {
            _ = try await session.requestJSON(path: "/api/status", maxResponseBytes: 32)
            XCTFail("An oversized streamed response must be rejected")
        } catch DashboardTicketBridgeError.oversizedResponse(let limit) {
            XCTAssertEqual(limit, 32)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        session.invalidate()
    }

    @MainActor
    func test401RefreshesAndReplaysSafeRequestOnce() async throws {
        let dashboardID = UUID()
        let initial = tokens()
        var apiCalls = 0
        var refreshCalls = 0
        NativeOAuthURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/auth/native/refresh":
                refreshCalls += 1
                return (200, [
                    "access_token": "new-access", "refresh_token": "new-refresh",
                    "expires_at": 4_000_000_100, "provider": "google", "user_id": "user",
                ])
            case "/api/status":
                apiCalls += 1
                if apiCalls == 1 { return (401, ["detail": "expired"]) }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
                return (200, ["ok": true])
            default:
                throw URLError(.badURL)
            }
        }
        let session = NativeOAuthSession(tokens: initial, dashboardID: dashboardID, client: makeClient())

        let response = try await session.requestJSON(path: "/api/status")

        XCTAssertTrue(session.matchesStoredTokens(try XCTUnwrap(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID))))
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(apiCalls, 2)
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID)?.accessToken, "new-access")
        session.invalidate()
    }

    @MainActor
    func testConcurrentRejectedRefreshCallersBothRequireSignIn() async {
        let id = UUID()
        let expired = tokens(expiresAt: 1)
        KeychainHelper.saveNativeOAuthTokens(expired, dashboardID: id)
        let refreshStarted = expectation(description: "refresh is in flight")
        let releaseRefresh = DispatchSemaphore(value: 0)
        NativeOAuthURLProtocolStub.handler = { _ in
            refreshStarted.fulfill()
            guard releaseRefresh.wait(timeout: .now() + 5) == .success else {
                throw URLError(.timedOut)
            }
            return (401, ["detail": "rejected"])
        }
        let session = NativeOAuthSession(tokens: expired, dashboardID: id, client: makeClient())
        func request() async -> Bool {
            do {
                _ = try await session.requestJSON(path: "/api/status")
                return false
            } catch DashboardTicketBridgeError.signInRequired {
                return true
            } catch {
                return false
            }
        }
        let first = Task { await request() }
        await fulfillment(of: [refreshStarted], timeout: 2)
        let waiterStarted = expectation(description: "second caller joined")
        let second = Task { @MainActor in
            waiterStarted.fulfill()
            return await request()
        }
        // The main-actor waiter reaches its suspension before this test can
        // resume and release the deliberately pending refresh response.
        await fulfillment(of: [waiterStarted], timeout: 2)
        releaseRefresh.signal()
        let outcomes = await (first.value, second.value)
        XCTAssertTrue(outcomes.0)
        XCTAssertTrue(outcomes.1)
        XCTAssertTrue(KeychainHelper.loadNativeOAuthTokens(dashboardID: id) == nil)
        session.invalidate()
    }

    @MainActor
    func test401RefreshDoesNotReplayMutation() async throws {
        let dashboardID = UUID()
        var mutationCalls = 0
        NativeOAuthURLProtocolStub.handler = { request in
            if request.url?.path == "/auth/native/refresh" {
                return (200, [
                    "access_token": "new-access", "refresh_token": "new-refresh",
                    "expires_at": 4_000_000_100, "provider": "google", "user_id": "user",
                ])
            }
            mutationCalls += 1
            return (401, ["detail": "expired"])
        }
        let session = NativeOAuthSession(tokens: tokens(), dashboardID: dashboardID, client: makeClient())

        do {
            _ = try await session.requestJSON(path: "/api/mutate", method: "POST", body: ["value": 1])
            XCTFail("A non-idempotent request must require an explicit retry")
        } catch DashboardTicketBridgeError.http(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(mutationCalls, 1)
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID)?.accessToken, "new-access")
        session.invalidate()
    }

    @MainActor
    func testRejectedRefreshClearsOnlyThisDashboardTokens() async throws {
        let dashboardID = UUID()
        let otherID = UUID()
        let expired = tokens(expiresAt: 1)
        KeychainHelper.saveNativeOAuthTokens(expired, dashboardID: dashboardID)
        KeychainHelper.saveNativeOAuthTokens(tokens(access: "other"), dashboardID: otherID)
        NativeOAuthURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/native/refresh")
            return (401, ["error": "session_expired"])
        }
        let session = NativeOAuthSession(tokens: expired, dashboardID: dashboardID, client: makeClient())

        do {
            _ = try await session.requestJSON(path: "/api/status")
            XCTFail("Rejected refresh must require sign-in")
        } catch DashboardTicketBridgeError.signInRequired {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID))
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: otherID)?.accessToken, "other")
        session.invalidate()
    }

    @MainActor
    func testPermission403DoesNotRefreshOrClearTokens() async throws {
        let dashboardID = UUID()
        let initial = tokens()
        KeychainHelper.saveNativeOAuthTokens(initial, dashboardID: dashboardID)
        var calls = 0
        NativeOAuthURLProtocolStub.handler = { _ in
            calls += 1
            return (403, ["detail": "forbidden"])
        }
        let session = NativeOAuthSession(tokens: initial, dashboardID: dashboardID, client: makeClient())

        do {
            _ = try await session.requestJSON(path: "/api/admin")
            XCTFail("A permission failure must propagate")
        } catch DashboardTicketBridgeError.http(let status, _) {
            XCTAssertEqual(status, 403)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID), initial)
        session.invalidate()
    }
}

@MainActor
final class NativeOAuthPresentationTaskTests: XCTestCase {
    private func result() -> NativeOAuthLoginResult {
        NativeOAuthLoginResult(
            tokens: NativeOAuthTokenSet(accessToken: "test-access", refreshToken: "test-refresh",
                                       expiresAt: 0, provider: "test", userID: "test"),
            ticket: "test-ticket", previousTokens: nil
        )
    }

    func testRepeatedPresentationUpdatesDoNotRestartSignIn() async {
        let owner = NativeOAuthPresentationTask()
        let completed = expectation(description: "one sign-in completed")
        var starts = 0
        for _ in 0..<3 {
            owner.start(operation: {
                starts += 1
                await Task.yield()
                return self.result()
            }, onSuccess: { _ in completed.fulfill() }, onError: { _ in XCTFail("Unexpected failure") })
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(starts, 1)
    }

    func testDismantlingCancelsTheWaitingLoopbackOperation() async {
        let owner = NativeOAuthPresentationTask()
        let server = NativeOAuthLoopbackServer(expectedState: "test-state")
        let listening = expectation(description: "listener ready")
        let cancelled = expectation(description: "listener wait cancelled")
        owner.start(operation: {
            _ = try await server.start()
            listening.fulfill()
            do {
                _ = try await server.waitForCallback()
                XCTFail("Unexpected callback")
                return self.result()
            } catch is CancellationError {
                cancelled.fulfill()
                throw CancellationError()
            }
        }, onSuccess: { _ in XCTFail("Cancelled flow must not succeed") },
           onError: { _ in XCTFail("Cancellation must not display an error") })
        await fulfillment(of: [listening], timeout: 2)
        owner.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testCancellationSuppressesLateCompletion() async {
        let owner = NativeOAuthPresentationTask()
        let started = expectation(description: "operation started")
        let returned = expectation(description: "operation returned after cancellation")
        var continuation: CheckedContinuation<Void, Never>?
        var delivered = false
        owner.start(operation: {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
            returned.fulfill()
            return self.result()
        }, onSuccess: { _ in delivered = true }, onError: { _ in delivered = true })
        await fulfillment(of: [started], timeout: 2)
        owner.cancel()
        continuation?.resume()
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()
        XCTAssertFalse(delivered)
    }
}
