//
//  HermesClientTests+DashboardSockets.swift
//  ConduitTests
//
//  Every dashboard socket factory against a REAL loopback WebSocket upgrade
//  (`DashboardSocketFixture`): the assertions read the handshake request
//  the server actually received, not a mock that echoes what was asked
//  for. Chat, Kanban live events, the dashboard speak and transcribe
//  streams and the Grok relay carry the selected dashboard's fresh ticket
//  and, for a native sign-in, its bearer and no cookie, whatever the shared
//  jar holds; a redirect is refused, so neither the ticket nor the bearer
//  follows it; external voice sockets carry nothing of the dashboard's.
//

import Foundation
import XCTest
@testable import Conduit

extension HermesClientTests {

    // MARK: - Fixture plumbing

    /// A native-mode dashboard at `baseURL`: an in-memory Keychain holding
    /// its grant and a bridge built for it. Undone at teardown.
    private func nativeDashboard(
        at baseURL: String,
        access: String,
        id: UUID = UUID()
    ) -> (bridge: DashboardTicketBridge, id: UUID) {
        useInMemoryKeychain()
        KeychainHelper.saveNativeOAuthTokens(DashboardSocketFixture.tokens(access: access), dashboardID: id)
        let bridge = DashboardTicketBridge(baseURL: baseURL, dashboardID: id)
        addTeardownBlock { @MainActor in bridge.invalidate() }
        XCTAssertTrue(bridge.usesNativeOAuth)
        return (bridge, id)
    }

    private func useInMemoryKeychain() {
        guard !(KeychainHelper.backend is InMemoryKeychainBackend) else { return }
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock {
            KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        }
    }

    /// An ambient cookie for the loopback host in the process-wide jar: the
    /// sockets' former `URLSession.shared` / `.default` sessions would have
    /// sent it.
    private func seedAmbientCookie() {
        guard let cookie = seedSharedJarCookie(host: "127.0.0.1") else {
            return XCTFail("Could not build the synthetic cookie")
        }
        addTeardownBlock { HTTPCookieStorage.shared.deleteCookie(cookie) }
    }

    private func assertDashboardUpgrade(
        _ upgrade: LoopbackHTTPRequest?,
        route: String,
        ticket: String,
        bearer: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let upgrade else { return XCTFail("No upgrade reached the server", file: file, line: line) }
        XCTAssertEqual(DashboardSocketFixture.route(of: upgrade), route, file: file, line: line)
        XCTAssertEqual(DashboardSocketFixture.query(of: upgrade)["ticket"], ticket, file: file, line: line)
        XCTAssertEqual(upgrade.headers["authorization"], bearer.map { "Bearer \($0)" }, file: file, line: line)
        XCTAssertNil(upgrade.headers["cookie"], "A dashboard upgrade never carries a cookie", file: file, line: line)
    }

    // MARK: - Native sign-in: every socket factory

    func testChatUpgradeCarriesItsTicketAndBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-chat")
        seedAmbientCookie()

        let ticket = try await dashboard.bridge.mintTicket()
        let client = HermesClient(
            connection: HermesConnection(baseUrl: fixture.baseURL, ticket: ticket),
            requestAuthorizer: dashboard.bridge.requestAuthorizer
        )
        try await client.connect()
        defer { client.disconnect() }

        XCTAssertTrue(client.isConnected, "The real 101 completed the handshake")
        let upgrade = fixture.upgrades.first
        assertDashboardUpgrade(upgrade, route: "/api/ws", ticket: ticket, bearer: "access-chat")
        XCTAssertEqual(upgrade?.headers["x-conduit-client"], "conduit")
        XCTAssertEqual(upgrade?.headers["authorization"], fixture.authorizationThatMinted(ticket),
                       "The upgrade presents the bearer that minted its ticket")
        XCTAssertEqual(fixture.upgrades.count, 1)
    }

    func testKanbanEventUpgradeCarriesItsTicketAndBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-kanban")
        seedAmbientCookie()

        let ticket = try await dashboard.bridge.mintTicket()
        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: fixture.baseURL,
            path: "/api/plugins/kanban/events",
            queryItems: [
                URLQueryItem(name: "ticket", value: ticket),
                URLQueryItem(name: "board", value: "default"),
                URLQueryItem(name: "since", value: "7"),
            ]
        )
        let socket = try await URLSessionKanbanEventSocket.open(url: url, authorizer: dashboard.bridge.requestAuthorizer)
        defer { socket.cancel() }

        let upgrade = try await fixture.waitForUpgrades(1).first
        assertDashboardUpgrade(upgrade, route: "/api/plugins/kanban/events", ticket: ticket, bearer: "access-kanban")
        XCTAssertEqual(upgrade.map(DashboardSocketFixture.query(of:))?["board"], "default")
        XCTAssertEqual(upgrade.map(DashboardSocketFixture.query(of:))?["since"], "7")
    }

    func testDashboardSpeakStreamUpgradeCarriesItsTicketAndBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-speak")
        seedAmbientCookie()

        let gateway = HermesVoiceGateway(bridge: dashboard.bridge, baseURL: fixture.baseURL, profile: "work")
        let stream = try await gateway.openSpeechStream(onStart: { _ in }, onPCM16: { _, _ in }, onEncodedAudio: { _ in })
        defer { stream.cancel() }

        let upgrade = try await fixture.waitForUpgrades(1).first
        XCTAssertEqual(fixture.mintCount, 1, "One fresh ticket for the one socket")
        assertDashboardUpgrade(upgrade, route: "/api/audio/speak-stream", ticket: "fixture-ticket-1", bearer: "access-speak")
        XCTAssertEqual(upgrade.map(DashboardSocketFixture.query(of:))?["profile"], "work")
    }

    func testDashboardTranscribeStreamUpgradeCarriesItsTicketAndBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-transcribe")
        seedAmbientCookie()

        let gateway = HermesVoiceGateway(bridge: dashboard.bridge, baseURL: fixture.baseURL, profile: "default")
        let transcription = await gateway.openLiveTranscription(sampleRate: 16_000, onPartial: { _ in }, onUnavailable: {})
        XCTAssertNotNil(transcription)
        defer { transcription?.cancel() }

        let upgrade = try await fixture.waitForUpgrades(1).first
        assertDashboardUpgrade(upgrade, route: "/api/audio/transcribe-stream", ticket: "fixture-ticket-1", bearer: "access-transcribe")
    }

    /// The speech-server relay's speak socket: its ticket, no cookie from
    /// the shared jar, on the dashboard socket session.
    func testSpeechServerSpeakUpgradeCarriesItsTicketAndBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-relay-speak")
        seedAmbientCookie()

        let gateway = HermesVoiceGateway(bridge: dashboard.bridge, baseURL: fixture.baseURL, profile: "work")
        let stream = try await gateway.openSpeechServerSpeech(onStart: { _ in }, onPCM16: { _, _ in })
        defer { stream.cancel() }

        let upgrade = try await fixture.waitForUpgrades(1).first
        assertDashboardUpgrade(upgrade, route: SpeechServerSpeechStream.socketPath, ticket: "fixture-ticket-1", bearer: "access-relay-speak")
        XCTAssertEqual(upgrade.map(DashboardSocketFixture.query(of:))?["mode"], "speak")
    }

    /// The speech-server relay's transcription socket, the same way.
    func testSpeechServerTranscriptionUpgradeCarriesItsTicketAndBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-relay-transcribe")
        seedAmbientCookie()

        let gateway = HermesVoiceGateway(bridge: dashboard.bridge, baseURL: fixture.baseURL, profile: "default")
        let transcription = await gateway.openSpeechServerTranscription(sampleRate: 16_000, onPartial: { _ in }, onFailure: { _ in })
        XCTAssertNotNil(transcription)
        defer { transcription?.cancel() }

        let upgrade = try await fixture.waitForUpgrades(1).first
        assertDashboardUpgrade(upgrade, route: SpeechServerTranscription.socketPath, ticket: "fixture-ticket-1", bearer: "access-relay-transcribe")
    }

    /// Neither relay socket follows a redirect: the ticket and the proxy
    /// headers never reach where `Location` points.
    func testSpeechServerRelaySocketsRefuseRedirects() async throws {
        let elsewhere = try LoopbackHTTPServer.start { request in .webSocketUpgrade(for: request) }
        defer { elsewhere.stop() }
        let fixture = try DashboardSocketFixture(
            upgradeStatuses: [302, 302],
            redirectLocation: "http://localhost:\(elsewhere.port)/collect"
        )
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-relay-redirect")

        let gateway = HermesVoiceGateway(bridge: dashboard.bridge, baseURL: fixture.baseURL, profile: "default")
        let stream = try await gateway.openSpeechServerSpeech(onStart: { _ in }, onPCM16: { _, _ in })
        defer { stream.cancel() }
        let transcription = await gateway.openSpeechServerTranscription(sampleRate: 16_000, onPartial: { _ in }, onFailure: { _ in })
        defer { transcription?.cancel() }

        _ = try await fixture.waitForUpgrades(2)
        // Give a followed redirect every chance to arrive before asserting
        // that none did.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(elsewhere.receivedRequests.isEmpty, "No relay socket follows the redirect")
        XCTAssertEqual(fixture.upgrades.count, 2)
    }

    func testGrokRelayUpgradeFromAppStateCarriesItsTicketAndBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        useInMemoryKeychain()
        seedAmbientCookie()
        let id = UUID()
        KeychainHelper.saveNativeOAuthTokens(DashboardSocketFixture.tokens(access: "access-grok"), dashboardID: id)
        let defaults = makeScratchDefaults("HermesClientTests.grok")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(
                activeDashboardID: id,
                dashboards: [SavedDashboard(id: id, label: "Relay", normalizedURL: fixture.baseURL)]
            ),
            clearSessionPresentationCache: {}
        )
        appState.prepareDashboardBridge(for: fixture.baseURL)
        let bridge = try XCTUnwrap(appState.dashboardTicketBridge)
        addTeardownBlock { @MainActor in bridge.invalidate() }
        XCTAssertTrue(bridge.usesNativeOAuth)
        appState.connection = HermesConnection(baseUrl: fixture.baseURL, ticket: "")

        // The production relay request (GrokLiveClient through AppState's
        // closures), opened on the production relay socket.
        let request = try await appState.grokLiveClient.socketRequest()
        let socket = URLSessionGeminiLiveSocket(request: request)
        defer { socket.close() }

        let upgrade = try await fixture.waitForUpgrades(1).first
        assertDashboardUpgrade(upgrade, route: GrokLiveClient.socketPath, ticket: "fixture-ticket-1", bearer: "access-grok")
    }

    /// Local Live's relay behind an auth proxy (cookie mode): its upgrade
    /// carries the dashboard's own session cookie, like Grok's relay and
    /// the chat socket, so the proxy admits it.
    func testLocalLiveUpgradeFromAppStateCarriesTheDashboardsSessionCookie() async throws {
        useInMemoryKeychain()
        let base = "http://127.0.0.1:9"
        let id = UUID()
        let defaults = makeScratchDefaults("HermesClientTests.localLive")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(
                activeDashboardID: id,
                dashboards: [SavedDashboard(id: id, label: "Proxy", normalizedURL: base)]
            ),
            clearSessionPresentationCache: {}
        )
        appState.prepareDashboardBridge(for: base)
        let bridge = try XCTUnwrap(appState.dashboardTicketBridge)
        addTeardownBlock { @MainActor in bridge.invalidate() }
        XCTAssertFalse(bridge.usesNativeOAuth)
        let session = try XCTUnwrap(HTTPCookie(properties: [
            .name: "_proxy_session", .value: "proxy-value", .domain: "127.0.0.1", .path: "/",
        ]))
        bridge.requestAuthorizer.cookieTicketMinter = { "cookie-ticket" }
        bridge.requestAuthorizer.cookieUpgradeCookies = { [session] }
        appState.connection = HermesConnection(baseUrl: base, ticket: "")

        let request = try await appState.localLiveClient.socketRequest()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "_proxy_session=proxy-value")
        XCTAssertEqual(request.url?.path, LocalLiveProtocol.socketPath)
    }

    // MARK: - External voice providers

    /// Gemini's socket goes to the provider address the host hands out
    /// (here the very host the native dashboard lives on, with an ambient
    /// cookie in the jar): it carries the provider URL's own token and
    /// nothing of the dashboard's.
    func testExternalVoiceSocketCarriesNoBearerAndNoCookie() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        _ = nativeDashboard(at: fixture.baseURL, access: "access-not-for-providers")
        seedAmbientCookie()

        let providerURL = try XCTUnwrap(URL(string:
            "ws://127.0.0.1:\(fixture.server.port)/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?access_token=provider-ephemeral"
        ))
        let socket = URLSessionGeminiLiveSocket(url: providerURL)
        defer { socket.close() }

        let upgrade = try await fixture.waitForUpgrades(1).first
        XCTAssertEqual(upgrade.map(DashboardSocketFixture.query(of:))?["access_token"], "provider-ephemeral")
        XCTAssertNil(upgrade?.headers["authorization"], "A provider socket never carries the dashboard's bearer")
        XCTAssertNil(upgrade?.headers["cookie"], "A provider socket never carries a cookie")
        XCTAssertEqual(fixture.mintCount, 0, "No dashboard ticket is minted for a provider socket")
    }

    // MARK: - Redirects are never followed

    func testCrossOriginRedirectOnUpgradeIsRefusedAndNothingFollows() async throws {
        // `localhost` is another origin than `127.0.0.1`.
        let elsewhere = try LoopbackHTTPServer.start { request in .webSocketUpgrade(for: request) }
        defer { elsewhere.stop() }
        let fixture = try DashboardSocketFixture(
            upgradeStatuses: [302],
            redirectLocation: "http://localhost:\(elsewhere.port)/collect?ticket=leaked"
        )
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-redirect")

        let ticket = try await dashboard.bridge.mintTicket()
        let client = HermesClient(
            connection: HermesConnection(baseUrl: fixture.baseURL, ticket: ticket),
            requestAuthorizer: dashboard.bridge.requestAuthorizer
        )
        do {
            try await client.connect()
            XCTFail("A redirected upgrade must not connect")
        } catch let error as DashboardSocketHandshakeError {
            XCTAssertEqual(error, .browserSessionRequired(status: 302))
        }
        client.disconnect()

        // Give a follow-up request every chance to arrive before asserting
        // that none did.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(elsewhere.receivedRequests.isEmpty,
                      "Neither the ticket nor the bearer follows a redirect to another origin")
        XCTAssertEqual(fixture.upgrades.count, 1, "The redirect is not retried either")
        assertDashboardUpgrade(fixture.upgrades.first, route: "/api/ws", ticket: ticket, bearer: "access-redirect")
        XCTAssertEqual(fixture.refreshes.count, 0)
        XCTAssertNotNil(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboard.id), "A redirect is not a sign-out")
    }

    func testSecondarySocketRefusesRedirectToo() async throws {
        let elsewhere = try LoopbackHTTPServer.start { request in .webSocketUpgrade(for: request) }
        defer { elsewhere.stop() }
        let fixture = try DashboardSocketFixture(
            upgradeStatuses: [302],
            redirectLocation: "http://localhost:\(elsewhere.port)/collect"
        )
        defer { fixture.stop() }
        let dashboard = nativeDashboard(at: fixture.baseURL, access: "access-kanban-redirect")

        let ticket = try await dashboard.bridge.mintTicket()
        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: fixture.baseURL,
            path: "/api/plugins/kanban/events",
            queryItems: [URLQueryItem(name: "ticket", value: ticket)]
        )
        let socket = try await URLSessionKanbanEventSocket.open(url: url, authorizer: dashboard.bridge.requestAuthorizer)
        // Bounded: a followed redirect would open a socket that never
        // speaks, and an unbounded receive would hang instead of failing.
        let outcome: String = await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                do {
                    _ = try await socket.receive()
                    return "frame"
                } catch {
                    return "refused"
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return "still open"
            }
            let first = await group.next() ?? "still open"
            group.cancelAll()
            socket.cancel()
            return first
        }
        XCTAssertEqual(outcome, "refused", "The upgrade fails at the refused redirect")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(elsewhere.receivedRequests.isEmpty)
        XCTAssertEqual(fixture.upgrades.count, 1)
    }

    // MARK: - Cookie mode

    func testCookieModeUpgradeWithoutSessionCookiesCarriesOnlyItsTicket() async throws {
        let fixture = try DashboardSocketFixture(upgradeStatuses: [101, 403])
        defer { fixture.stop() }
        useInMemoryKeychain()
        seedAmbientCookie()
        let bridge = DashboardTicketBridge(baseURL: fixture.baseURL, dashboardID: UUID())
        defer { bridge.invalidate() }
        XCTAssertFalse(bridge.usesNativeOAuth)

        let client = HermesClient(
            connection: HermesConnection(baseUrl: fixture.baseURL, ticket: "cookie-mode-ticket"),
            requestAuthorizer: bridge.requestAuthorizer
        )
        try await client.connect()
        client.disconnect()
        assertDashboardUpgrade(fixture.upgrades.first, route: "/api/ws", ticket: "cookie-mode-ticket", bearer: nil)
        XCTAssertEqual(fixture.mintCount, 0)

        // A refused cookie-mode upgrade says nothing about an account.
        let refused = HermesClient(
            connection: HermesConnection(baseUrl: fixture.baseURL, ticket: "cookie-mode-ticket-2"),
            requestAuthorizer: bridge.requestAuthorizer
        )
        do {
            try await refused.connect()
            XCTFail("A 403 must fail the connect")
        } catch HermesError.connectionClosed {
            // Unchanged: a closed connection, retried by the reconnect path.
        }
        refused.disconnect()
    }
}
