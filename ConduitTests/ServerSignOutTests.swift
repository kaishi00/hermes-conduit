//
//  ServerSignOutTests.swift
//  ConduitTests
//
//  Sign Out and Remove Dashboard end the sign-in on the Hermes server (#889):
//  the refresh token goes to Hermes' POST /auth/logout as its session cookie,
//  stays in a "revoke pending" record until Hermes answers, and is retried
//  until then or until it is past its lifetime. Synthetic hosts only.
//

import Foundation
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class ServerSignOutTests: XCTestCase {
    private let baseURL = "https://hermes.example.test"

    private func grant(refresh: String = "refresh-native") -> NativeOAuthTokenSet {
        NativeOAuthTokenSet(accessToken: "access", refreshToken: refresh, expiresAt: 4_000_000_000, provider: "self-hosted", userID: "user")
    }

    private func cookie(_ name: String, _ value: String, domain: String = "hermes.example.test") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"])!
    }

    // MARK: - Which tokens

    func testTheNativeGrantAndTheCookieSessionAreBothRevokedOnce() {
        let tokens = ServerSignOut.refreshTokens(
            native: grant(),
            cookies: [
                cookie("__Host-hermes_session_rt", "refresh-cookie"),
                cookie("hermes_session_rt", "refresh-native"), // the same token again
                cookie("hermes_session_at", "access-cookie"),
                cookie("hermes_session_rt", "someone-elses", domain: "other.example.test"),
            ],
            baseURL: baseURL
        )
        XCTAssertEqual(tokens, ["refresh-native", "refresh-cookie"])
    }

    func testNoSignInHasNothingToRevoke() {
        XCTAssertEqual(ServerSignOut.refreshTokens(native: nil, cookies: [], baseURL: baseURL), [])
    }

    func testATokenThatCannotTravelAsACookieIsNotSent() {
        XCTAssertFalse(ServerSignOut.isSendable("a;b"))
        XCTAssertFalse(ServerSignOut.isSendable("a b"))
        XCTAssertFalse(ServerSignOut.isSendable(""))
        XCTAssertTrue(ServerSignOut.isSendable("1//0gAbc-_.~+/="))
    }

    // MARK: - The request

    func testTheRequestIsHermesLogoutWithTheRefreshCookie() throws {
        let headers = CustomHeaderStore(load: { [:] }, persist: { _ in })
        let request = try XCTUnwrap(ServerSignOut.request(
            baseURL: "\(baseURL)/hermes/",
            refreshToken: "refresh-native",
            cloudflare: CloudflareAccessCredentials(clientID: "id", clientSecret: "secret"),
            headers: headers
        ))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "\(baseURL)/hermes/auth/logout")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "hermes_session_rt=refresh-native")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The access token is already gone")
    }

    // MARK: - Hermes' answer

    func testHermesRedirectToItsOwnSignInPageEndsIt() throws {
        let url = try XCTUnwrap(URL(string: "\(baseURL)/hermes/auth/logout"))
        XCTAssertEqual(ServerSignOut.outcome(status: 302, location: "/hermes/login", requestURL: url), .ended)
        XCTAssertEqual(ServerSignOut.outcome(status: 302, location: "\(baseURL)/hermes/login", requestURL: url), .ended)
        XCTAssertEqual(ServerSignOut.outcome(status: 200, location: nil, requestURL: url), .ended)
        XCTAssertEqual(ServerSignOut.outcome(status: 404, location: nil, requestURL: url), .ended, "No logout route: nothing more to do")
    }

    func testAnAuthEdgeOrAServerErrorIsTriedAgain() throws {
        let url = try XCTUnwrap(URL(string: "\(baseURL)/auth/logout"))
        XCTAssertEqual(ServerSignOut.outcome(status: 302, location: "https://sso.example.test/authorize", requestURL: url), .retryLater)
        XCTAssertEqual(ServerSignOut.outcome(status: 302, location: "/oauth2/start?rd=%2F", requestURL: url), .retryLater)
        XCTAssertEqual(ServerSignOut.outcome(status: 302, location: nil, requestURL: url), .retryLater)
        XCTAssertEqual(ServerSignOut.outcome(status: 403, location: nil, requestURL: url), .retryLater)
        XCTAssertEqual(ServerSignOut.outcome(status: 503, location: nil, requestURL: url), .retryLater)
    }

    // MARK: - The queue

    private final class Harness {
        var stored: [PendingServerSignOut] = []
        var sent: [URLRequest] = []
        var answer: (status: Int, location: String?)? = (302, "/login")
        var now = Date(timeIntervalSince1970: 2_000_000_000)
    }

    private func makeQueue(_ harness: Harness) -> ServerSignOutQueue {
        ServerSignOutQueue(
            send: { request in
                harness.sent.append(request)
                return harness.answer
            },
            now: { harness.now },
            load: { harness.stored },
            save: { harness.stored = $0 }
        )
    }

    func testSignOutSendsAndForgetsTheTokenOnceHermesAnswers() async {
        let harness = Harness()
        let queue = makeQueue(harness)

        queue.signOut(dashboardID: UUID(), baseURL: baseURL, refreshTokens: ["refresh-native"], cloudflare: nil)
        await queue.retryPending().value

        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.sent.first?.value(forHTTPHeaderField: "Cookie"), "hermes_session_rt=refresh-native")
        XCTAssertTrue(harness.stored.isEmpty, "Revoked: nothing kept")
    }

    func testOfflineKeepsTheTokenPendingAndALaterTryEndsIt() async {
        let harness = Harness()
        harness.answer = nil
        let queue = makeQueue(harness)

        queue.signOut(dashboardID: UUID(), baseURL: baseURL, refreshTokens: ["refresh-native"], cloudflare: nil)
        await queue.retryPending().value
        XCTAssertEqual(harness.stored.map(\.refreshToken), ["refresh-native"], "Kept, marked pending")

        harness.answer = (302, "/login")
        await queue.retryPending().value
        XCTAssertEqual(harness.sent.count, 2)
        XCTAssertTrue(harness.stored.isEmpty)
    }

    func testAnOfflineTryKeepsTheHeadersBuiltAtSignOut() async {
        let harness = Harness()
        harness.answer = nil
        let queue = makeQueue(harness)

        queue.signOut(
            dashboardID: UUID(),
            baseURL: baseURL,
            refreshTokens: ["refresh-native"],
            cloudflare: CloudflareAccessCredentials(clientID: "id", clientSecret: "secret")
        )
        await queue.retryPending().value
        harness.answer = (302, "/login")
        await queue.retryPending().value

        XCTAssertEqual(harness.sent.map { $0.value(forHTTPHeaderField: "CF-Access-Client-Id") }, ["id", "id"])
        XCTAssertTrue(harness.stored.isEmpty)
    }

    func testAnEdgeThatKeepsTurningTheRequestAwayIsGivenUpOn() async {
        let harness = Harness()
        harness.answer = (403, nil)
        let queue = makeQueue(harness)

        queue.signOut(dashboardID: UUID(), baseURL: baseURL, refreshTokens: ["refresh-native"], cloudflare: nil)
        await queue.retryPending().value
        XCTAssertEqual(harness.stored.first?.refusals, 1)

        for _ in 1..<ServerSignOut.maximumRefusals {
            await queue.retryPending().value
        }
        XCTAssertEqual(harness.sent.count, ServerSignOut.maximumRefusals)
        XCTAssertTrue(harness.stored.isEmpty, "The edge won't pass it")
    }

    func testAServerErrorIsNotCountedAsARefusal() async {
        let harness = Harness()
        harness.answer = (503, nil)
        let queue = makeQueue(harness)

        queue.signOut(dashboardID: UUID(), baseURL: baseURL, refreshTokens: ["refresh-native"], cloudflare: nil)
        await queue.retryPending().value

        XCTAssertEqual(harness.stored.first?.refusals, 0)
    }

    func testATokenPastItsLifetimeIsDroppedWithoutSending() async {
        let harness = Harness()
        harness.stored = [PendingServerSignOut(
            id: UUID(), dashboardID: UUID(), baseURL: baseURL, refreshToken: "old",
            signedOutAt: harness.now.addingTimeInterval(-ServerSignOut.pendingLifetime - 1)
        )]
        let queue = makeQueue(harness)

        await queue.retryPending().value

        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertTrue(harness.stored.isEmpty)
    }

    func testPendingRecordsSurviveInTheKeychain() {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let entry = PendingServerSignOut(id: UUID(), dashboardID: UUID(), baseURL: baseURL, refreshToken: "r", signedOutAt: Date(timeIntervalSince1970: 1))

        KeychainHelper.savePendingServerSignOuts([entry])
        XCTAssertEqual(KeychainHelper.loadPendingServerSignOuts(), [entry])
        KeychainHelper.savePendingServerSignOuts([])
        XCTAssertEqual(KeychainHelper.loadPendingServerSignOuts(), [])
    }

    // MARK: - Sign Out and Remove Dashboard

    private func makeAppState(_ registry: SavedDashboardRegistry, defaults: UserDefaults, scratch: URL) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            profileAppearanceStore: ProfileAppearanceStore(
                defaults: defaults,
                avatarsRoot: scratch.appendingPathComponent("profile-avatars", isDirectory: true),
                legacyAvatarDirectories: []
            )
        )
    }

    private func withAppState(_ body: (AppState, SavedDashboard, SavedDashboard, Harness) async throws -> Void) async rethrows {
        let suite = "ServerSignOutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        defer {
            KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: scratch)
        }
        let mac = SavedDashboard(id: UUID(), label: "Mac", normalizedURL: "https://mac.example.test")
        let vps = SavedDashboard(id: UUID(), label: "VPS", normalizedURL: baseURL)
        let appState = makeAppState(
            SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]),
            defaults: defaults,
            scratch: scratch
        )
        let harness = Harness()
        appState.serverSignOutQueue = makeQueue(harness)
        try await body(appState, mac, vps, harness)
    }

    func testSigningOutAnotherDashboardEndsItsServerSignIn() async {
        await withAppState { appState, _, vps, harness in
            KeychainHelper.saveNativeOAuthTokens(grant(), dashboardID: vps.id)

            appState.signOutDashboard(vps.id)
            await appState.serverSignOutQueue.retryPending().value

            XCTAssertNil(KeychainHelper.loadNativeOAuthTokens(dashboardID: vps.id), "The access token goes at once")
            XCTAssertEqual(harness.sent.map(\.url?.absoluteString), ["\(baseURL)/auth/logout"])
            XCTAssertEqual(harness.sent.first?.value(forHTTPHeaderField: "Cookie"), "hermes_session_rt=refresh-native")
        }
    }

    func testRemovingTheActiveDashboardEndsItsServerSignIn() async {
        await withAppState { appState, mac, _, harness in
            KeychainHelper.saveNativeOAuthTokens(grant(refresh: "refresh-mac"), dashboardID: mac.id)
            KeychainHelper.saveCloudflareAccess(
                CloudflareAccessCredentials(clientID: "id", clientSecret: "secret"),
                origin: mac.normalizedURL,
                dashboardID: mac.id
            )

            appState.removeDashboard(mac.id)
            await appState.serverSignOutQueue.retryPending().value

            XCTAssertEqual(harness.sent.map(\.url?.absoluteString), ["https://mac.example.test/auth/logout"])
            XCTAssertEqual(harness.sent.first?.value(forHTTPHeaderField: "Cookie"), "hermes_session_rt=refresh-mac")
            XCTAssertEqual(
                harness.sent.first?.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id",
                "Built before Remove Dashboard deletes the Cloudflare token"
            )
        }
    }

    func testSigningOutWithoutAServerSignInSendsNothing() async {
        await withAppState { appState, _, vps, harness in
            appState.signOutDashboard(vps.id)
            await appState.serverSignOutQueue.retryPending().value
            XCTAssertTrue(harness.sent.isEmpty)
        }
    }
}
