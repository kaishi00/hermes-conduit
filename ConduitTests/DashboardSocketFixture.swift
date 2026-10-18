//
//  DashboardSocketFixture.swift
//  ConduitTests
//
//  A dashboard on a real loopback HTTP server, for tests that must see the
//  ACTUAL WebSocket handshake a socket factory sends: it mints single-use
//  tickets (remembering the bearer each was minted with), refreshes native
//  grants, and answers upgrades from a script (101 by default, with a
//  genuine `Sec-WebSocket-Accept`). Synthetic values only.
//

import Foundation
import XCTest
@testable import Conduit

final class DashboardSocketFixture: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var ticketCount = 0
        var bearerByTicket: [String: String] = [:]
        var upgradeStatuses: [Int]
        var redirectLocation: String
        var refreshedAccessToken: String
        let ticketPrefix: String

        init(upgradeStatuses: [Int], redirectLocation: String, refreshedAccessToken: String, ticketPrefix: String) {
            self.upgradeStatuses = upgradeStatuses
            self.redirectLocation = redirectLocation
            self.refreshedAccessToken = refreshedAccessToken
            self.ticketPrefix = ticketPrefix
        }

        func respond(to request: LoopbackHTTPRequest) -> LoopbackHTTPResponse {
            let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
            if request.headers["upgrade"]?.lowercased() == "websocket" {
                lock.lock()
                let status = upgradeStatuses.isEmpty ? 101 : upgradeStatuses.removeFirst()
                let location = redirectLocation
                lock.unlock()
                switch status {
                case 101: return .webSocketUpgrade(for: request)
                case 300...399: return .redirect(status: status, to: location)
                default: return .status(status)
                }
            }
            switch (request.method, path) {
            case (_, let route) where route.hasSuffix("/api/auth/ws-ticket"):
                lock.lock()
                ticketCount += 1
                let ticket = "\(ticketPrefix)-\(ticketCount)"
                bearerByTicket[ticket] = request.headers["authorization"]
                lock.unlock()
                return .json(status: 200, body: #"{"ticket":"\#(ticket)"}"#)
            case (_, let route) where route.hasSuffix("/auth/native/refresh"):
                lock.lock()
                let access = refreshedAccessToken
                lock.unlock()
                return .json(status: 200, body: """
                {"access_token":"\(access)","refresh_token":"\(access)-refresh","expires_at":4000000000,"provider":"self-hosted","user_id":"fixture-user"}
                """)
            default:
                return .json(status: 404, body: #"{"detail":"Not Found"}"#)
            }
        }
    }

    let server: LoopbackHTTPServer
    private let state: State
    /// `http://127.0.0.1:<port>` plus `basePath`.
    let baseURL: String

    init(
        upgradeStatuses: [Int] = [],
        redirectLocation: String = "/signin",
        refreshedAccessToken: String = "fixture-access-renewed",
        ticketPrefix: String = "fixture-ticket",
        basePath: String = ""
    ) throws {
        let state = State(
            upgradeStatuses: upgradeStatuses,
            redirectLocation: redirectLocation,
            refreshedAccessToken: refreshedAccessToken,
            ticketPrefix: ticketPrefix
        )
        self.state = state
        server = try LoopbackHTTPServer.start { request in state.respond(to: request) }
        baseURL = "http://127.0.0.1:\(server.port)\(basePath)"
    }

    func stop() { server.stop() }

    /// Every WebSocket upgrade the server received, in order.
    var upgrades: [LoopbackHTTPRequest] {
        server.receivedRequests.filter { $0.headers["upgrade"]?.lowercased() == "websocket" }
    }

    var mintCount: Int {
        server.receivedRequests.filter { $0.path.hasSuffix("/api/auth/ws-ticket") }.count
    }

    var refreshes: [LoopbackHTTPRequest] {
        server.receivedRequests.filter { $0.path.hasSuffix("/auth/native/refresh") }
    }

    /// The Authorization header the server saw when it minted `ticket`.
    func authorizationThatMinted(_ ticket: String) -> String? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.bearerByTicket[ticket]
    }

    /// Waits (bounded) until the server has received `count` upgrades.
    func waitForUpgrades(_ count: Int, timeout: Duration = .seconds(5)) async throws -> [LoopbackHTTPRequest] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while upgrades.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let received = upgrades
        XCTAssertGreaterThanOrEqual(received.count, count, "Timed out waiting for \(count) WebSocket upgrade(s)")
        return received
    }

    static func query(of request: LoopbackHTTPRequest) -> [String: String] {
        let items = URLComponents(string: "http://fixture.invalid\(request.path)")?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    static func route(of request: LoopbackHTTPRequest) -> String {
        request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
    }

    static func tokens(access: String, refresh: String? = nil) -> NativeOAuthTokenSet {
        NativeOAuthTokenSet(
            accessToken: access,
            refreshToken: refresh ?? "\(access)-refresh",
            expiresAt: 4_000_000_000,
            provider: "self-hosted",
            userID: "fixture-user"
        )
    }
}

/// A synthetic cookie in the process-wide jar for `host`: a socket session
/// that consulted `HTTPCookieStorage.shared` would send it.
@discardableResult
func seedSharedJarCookie(host: String, name: String = "ambient_session") -> HTTPCookie? {
    let cookie = HTTPCookie(properties: [
        .name: name,
        .value: "synthetic-ambient-cookie",
        .domain: host,
        .path: "/",
    ])
    if let cookie { HTTPCookieStorage.shared.setCookie(cookie) }
    return cookie
}
