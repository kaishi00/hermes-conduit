//
//  HermesClientTests+SocketTransport.swift
//  ConduitTests
//
//  The dashboard WebSocket transport against a REAL loopback upgrade
//  (`DashboardSocketFixture`): no cookie from the process-wide jar ever
//  rides an upgrade, a redirect is never followed (to another origin or
//  another path), and the refusing status comes back typed. Covers the
//  chat transport, the shared session the secondary dashboard sockets use,
//  and the external voice provider socket.
//

import Foundation
import XCTest
@testable import Conduit

extension HermesClientTests {

    /// An ambient cookie for the loopback host in the process-wide jar,
    /// which a `.default` or `URLSession.shared` socket would send.
    private func seedTransportAmbientCookie() {
        guard let cookie = seedSharedJarCookie(host: "127.0.0.1", name: "transport_ambient") else {
            return XCTFail("Could not build the synthetic cookie")
        }
        addTeardownBlock { HTTPCookieStorage.shared.deleteCookie(cookie) }
    }

    private func transportClient(_ fixture: DashboardSocketFixture, ticket: String) -> HermesClient {
        HermesClient(connection: HermesConnection(baseUrl: fixture.baseURL, ticket: ticket))
    }

    // MARK: - Chat transport

    func testChatSocketSendsNoCookieFromTheSharedJar() async throws {
        let fixture = try DashboardSocketFixture()
        defer { fixture.stop() }
        seedTransportAmbientCookie()

        let client = transportClient(fixture, ticket: "transport-ticket")
        try await client.connect()
        defer { client.disconnect() }

        XCTAssertTrue(client.isConnected, "The real 101 completed the handshake")
        let upgrade = try XCTUnwrap(fixture.upgrades.first)
        XCTAssertEqual(DashboardSocketFixture.route(of: upgrade), "/api/ws")
        XCTAssertEqual(DashboardSocketFixture.query(of: upgrade)["ticket"], "transport-ticket")
        XCTAssertNil(upgrade.headers["cookie"], "The upgrade carries no cookie of any kind")
        XCTAssertNil(upgrade.headers["authorization"])
    }

    func testChatSocketRefusesARedirectToAnotherOrigin() async throws {
        // `localhost` is another origin than `127.0.0.1`.
        let elsewhere = try LoopbackHTTPServer.start { request in .webSocketUpgrade(for: request) }
        defer { elsewhere.stop() }
        let fixture = try DashboardSocketFixture(
            upgradeStatuses: [302],
            redirectLocation: "http://localhost:\(elsewhere.port)/collect"
        )
        defer { fixture.stop() }

        let client = transportClient(fixture, ticket: "transport-ticket")
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
        XCTAssertTrue(elsewhere.receivedRequests.isEmpty, "The redirect is not followed")
        XCTAssertEqual(fixture.upgrades.count, 1)
    }

    func testChatSocketRefusesASameOriginRedirect() async throws {
        let fixture = try DashboardSocketFixture(upgradeStatuses: [307], redirectLocation: "/other/ws")
        defer { fixture.stop() }

        let client = transportClient(fixture, ticket: "transport-ticket")
        do {
            try await client.connect()
            XCTFail("A redirected upgrade must not connect")
        } catch let error as DashboardSocketHandshakeError {
            XCTAssertEqual(error, .browserSessionRequired(status: 307))
        }
        client.disconnect()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.upgrades.map(DashboardSocketFixture.route(of:)), ["/api/ws"],
                       "A path-changing redirect is not followed")
    }

    /// A 401 or 403 says nothing about an account (Hermes answers a spent
    /// ticket with 403): it stays a closed connection for the reconnect
    /// path, and it arrives at once, not at the open timeout.
    func testRefusedUpgradeStaysAPromptClosedConnection() async throws {
        let fixture = try DashboardSocketFixture(upgradeStatuses: [401, 403])
        defer { fixture.stop() }

        for status in [401, 403] {
            let client = transportClient(fixture, ticket: "spent-\(status)")
            let started = ContinuousClock.now
            do {
                try await client.connect()
                XCTFail("A \(status) must fail the connect")
            } catch HermesError.connectionClosed {
                XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "Refused at once, not timed out")
            }
            client.disconnect()
        }
        XCTAssertEqual(fixture.upgrades.count, 2)
    }

    // MARK: - Secondary dashboard sockets

    func testSharedDashboardSocketSessionIsCookieLessAndRefusesRedirects() async throws {
        let elsewhere = try LoopbackHTTPServer.start { request in .webSocketUpgrade(for: request) }
        defer { elsewhere.stop() }
        let fixture = try DashboardSocketFixture(
            upgradeStatuses: [101, 302],
            redirectLocation: "http://localhost:\(elsewhere.port)/collect"
        )
        defer { fixture.stop() }
        seedTransportAmbientCookie()

        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: fixture.baseURL,
            path: "/api/plugins/kanban/events",
            queryItems: [URLQueryItem(name: "ticket", value: "secondary-ticket")]
        )
        let opened = DashboardWebSocketSession.shared.webSocketTask(with: URLRequest(url: url))
        opened.resume()
        defer { opened.cancel(with: .goingAway, reason: nil) }
        let upgrade = try await fixture.waitForUpgrades(1).first
        XCTAssertNil(upgrade?.headers["cookie"], "The shared dashboard session sends no cookie")

        let refused = expectation(description: "the refused redirect is reported")
        let reported = LockedValue<Int?>(nil)
        let redirected = DashboardWebSocketSession.shared.webSocketTask(with: URLRequest(url: url)) { status in
            reported.set(status)
            refused.fulfill()
        }
        redirected.resume()
        await fulfillment(of: [refused], timeout: 5)
        redirected.cancel(with: .goingAway, reason: nil)
        XCTAssertEqual(reported.value, 302)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(elsewhere.receivedRequests.isEmpty, "The redirect is not followed")
    }

    // MARK: - External voice provider socket

    func testExternalVoiceSocketSendsNoCookieAndFollowsNoRedirect() async throws {
        let elsewhere = try LoopbackHTTPServer.start { request in .webSocketUpgrade(for: request) }
        defer { elsewhere.stop() }
        let fixture = try DashboardSocketFixture(
            upgradeStatuses: [101, 302],
            redirectLocation: "http://localhost:\(elsewhere.port)/collect"
        )
        defer { fixture.stop() }
        seedTransportAmbientCookie()
        let providerURL = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(fixture.server.port)/live?access_token=provider-ephemeral"))

        let socket = URLSessionGeminiLiveSocket(url: providerURL)
        defer { socket.close() }
        let upgrade = try await fixture.waitForUpgrades(1).first
        XCTAssertNil(upgrade?.headers["cookie"], "A provider socket never carries a cookie")
        XCTAssertNil(upgrade?.headers["authorization"])

        let redirected = URLSessionGeminiLiveSocket(url: providerURL)
        defer { redirected.close() }
        let close = await redirected.serverClose(within: .seconds(5))
        XCTAssertEqual(close, GeminiLiveServerClose(code: 302, reason: "", isHTTPStatus: true))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(elsewhere.receivedRequests.isEmpty, "The redirect is not followed")
    }
}

/// A value a URLSession delegate queue writes and the test reads.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
