//
//  DashboardSessionIsolationTests.swift
//  Conduit
//
//  Live-store isolation regression coverage for #148: two dashboards that
//  share a parent domain (a.example.com / b.example.com with
//  Domain=.example.com cookies) can never see each other's WebKit or native
//  session state, sign-out clears the correct dashboard-owned session even
//  without a live connection, and stale restore/renewal flows write nothing.
//

import XCTest
import WebKit
@testable import Conduit

@MainActor
final class DashboardSessionIsolationTests: XCTestCase {

    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var backend: InMemoryKeychainBackend!
    private var createdDashboardIDs: [UUID] = []

    private let parentHostA = "https://a.example.com"
    private let parentHostB = "https://b.example.com"

    override func setUp() {
        super.setUp()
        defaultsSuite = "DashboardSessionIsolationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        createdDashboardIDs = []
    }

    override func tearDown() {
        for id in createdDashboardIDs {
            KeychainHelper.clearConnection(dashboardID: id)
            KeychainHelper.clearCredentials(dashboardID: id)
            KeychainHelper.clearCloudflareAccess(dashboardID: id)
            KeychainHelper.clearDashboardCookies(dashboardID: id)
        }
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func track(_ id: UUID) -> UUID {
        createdDashboardIDs.append(id)
        return id
    }

    private func makeAppState(registry: SavedDashboardRegistry) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    private func dashboard(_ label: String, _ url: String) -> SavedDashboard {
        SavedDashboard(id: UUID(), label: label, normalizedURL: url)
    }

    private func parentDomainCookie(value: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name: "session",
            .value: value,
            .domain: ".example.com",
            .path: "/",
        ]))
    }

    private func hostCookie(name: String, value: String, domain: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ]))
    }

    // MARK: - WebKit store identity

    func testWebKitStoresAreDistinctPerDashboardAndDefaultForNil() {
        let a = DashboardCookiePersistence.webKitStore(for: UUID())
        let b = DashboardCookiePersistence.webKitStore(for: UUID())
        XCTAssertFalse(a === b, "two dashboards never share a WebKit store")
        XCTAssertTrue(DashboardCookiePersistence.webKitStore(for: nil) === WKWebsiteDataStore.default())
        // The system caches identified stores: the same identifier resolves
        // to the same store instance, so bridge, sign-in WebView, and
        // cleanup share one context per dashboard.
        let id = UUID()
        XCTAssertTrue(DashboardCookiePersistence.webKitStore(for: id) === DashboardCookiePersistence.webKitStore(for: id))
    }

    func testWebKitCookieIsolationBetweenSiblingDashboards() async throws {
        let storeA = DashboardCookiePersistence.webKitStore(for: UUID())
        let storeB = DashboardCookiePersistence.webKitStore(for: UUID())
        let cookie = try parentDomainCookie(value: "a-session")

        await storeA.httpCookieStore.setCookie(cookie)
        // Give WebKit a beat to settle the write.
        try await Task.sleep(for: .milliseconds(50))

        let cookiesB = await storeB.httpCookieStore.allCookies()
        XCTAssertFalse(
            cookiesB.contains { $0.name == "session" && $0.value == "a-session" },
            "dashboard A's WebKit cookie must never appear in dashboard B's store"
        )
        let cookiesA = await storeA.httpCookieStore.allCookies()
        XCTAssertTrue(cookiesA.contains { $0.name == "session" && $0.value == "a-session" })
    }

    // MARK: - Native jar ownership

    func testNativeCookieJarsAreOwnedPerDashboard() throws {
        let a = track(UUID())
        let b = track(UUID())
        let jarA = DashboardCookiePersistence.nativeCookieStorage(for: a)
        let jarB = DashboardCookiePersistence.nativeCookieStorage(for: b)
        XCTAssertFalse(jarA === jarB, "two dashboards never share a native cookie jar")

        let cookie = try parentDomainCookie(value: "native-a")
        jarA.setCookie(cookie)

        XCTAssertEqual(jarB.cookies?.count ?? -1, 0, "B's jar must not contain A's cookies")
        XCTAssertTrue((jarA.cookies ?? []).contains { $0.value == "native-a" })

        // commitCookies lands in the OWNER's jar.
        NativeAuthCookiePolicy.persist([cookie], dashboardID: a)
        XCTAssertTrue((jarA.cookies ?? []).contains { $0.value == "native-a" })
    }

    func testRestoreNativeCookiesOnlyImportsTheOwningDashboardJar() async throws {
        let a = track(UUID())
        let b = track(UUID())
        let jarA = DashboardCookiePersistence.nativeCookieStorage(for: a)
        jarA.setCookie(try parentDomainCookie(value: "a-login"))
        jarA.setCookie(try hostCookie(name: "host-only", value: "a-host", domain: "a.example.com"))

        // B's bridge restores from B's (empty) jar: the parent-domain cookie
        // a.example.com holds for .example.com must NOT be imported.
        let storeB = DashboardCookiePersistence.webKitStore(for: b)
        await DashboardCookiePersistence.restoreNativeCookies(
            into: storeB.httpCookieStore,
            for: parentHostB,
            dashboardID: b
        )
        let cookiesB = await storeB.httpCookieStore.allCookies()
        XCTAssertTrue(cookiesB.isEmpty, "no cross-dashboard import through the shared jar")

        // A's bridge restores its own parent-domain and host-only cookies.
        let storeA = DashboardCookiePersistence.webKitStore(for: a)
        await DashboardCookiePersistence.restoreNativeCookies(
            into: storeA.httpCookieStore,
            for: parentHostA,
            dashboardID: a
        )
        let cookiesA = await storeA.httpCookieStore.allCookies()
        XCTAssertTrue(cookiesA.contains { $0.value == "a-login" })
        XCTAssertTrue(cookiesA.contains { $0.value == "a-host" })
    }

    func testClearNativeCookiesSparesSiblingParentDomainCookies() throws {
        let a = track(UUID())
        let b = track(UUID())
        let sharedParent = try parentDomainCookie(value: "parent-session")
        let sharedJar = HTTPCookieStorage.shared
        sharedJar.setCookie(sharedParent)

        // Sign out A: its own jar is wiped; the shared jar loses only
        // EXACT-host a.example.com cookies — never the parent-domain cookie
        // that belongs to the sibling dashboards.
        DashboardCookiePersistence.clearNativeCookies(dashboardID: a, baseURL: parentHostA)

        XCTAssertNotNil(
            sharedJar.cookies?.first { $0.value == "parent-session" },
            "a parent-domain cookie shared with sibling dashboards survives one dashboard's sign-out"
        )
        sharedJar.deleteCookie(sharedParent)
    }

    // MARK: - Sign-out clearing without a live connection

    func testSignOutSelectedButDisconnectedDashboardClearsItsOwnedSession() throws {
        let a = track(UUID())
        let saved = SavedDashboard(id: a, label: "A", normalizedURL: parentHostA)
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: a, dashboards: [saved]))
        // No live connection: connection == nil, isConnected == false. The
        // dashboard still owns web session state from an earlier session.
        let jar = DashboardCookiePersistence.nativeCookieStorage(for: a)
        jar.setCookie(try parentDomainCookie(value: "stale-a"))
        let sharedJar = HTTPCookieStorage.shared
        let exactHost = try hostCookie(name: "host-residue", value: "residue-a", domain: "a.example.com")
        sharedJar.setCookie(exactHost)
        addTeardownBlock { sharedJar.deleteCookie(exactHost) }

        appState.signOutDashboard(a)

        XCTAssertTrue((jar.cookies ?? []).isEmpty, "the dashboard's own native jar is wiped")
        XCTAssertNil(sharedJar.cookies?.first { $0.value == "residue-a" }, "exact-host residue in the shared jar is cleaned")
        XCTAssertNil(sharedJar.cookies?.first { $0.value == "stale-a" }, "an owned parent-domain cookie leaves with its owner")
        // Metadata survives sign-out; the registry is untouched.
        XCTAssertEqual(appState.activeDashboardID, a)
        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: a))
    }

    // MARK: - Stale restore failure fencing

    func testStaleRestoreFailureWritesNothing() {
        let appState = makeAppState(registry: SavedDashboardRegistry())
        appState.showLogin = false
        let failure = ConnectionFailureClassifier.classify(AuthClientError.loginFailed(status: 401, detail: "no"))

        let staleGeneration = appState.dashboardSwitchGenerationForTesting() &+ 1
        let wrote = appState.presentCredentialRestoreFailure(failure, switchGeneration: staleGeneration)

        XCTAssertFalse(wrote, "a superseded restore failure writes nothing")
        XCTAssertFalse(appState.showLogin)
        XCTAssertNil(appState.pendingLoginFailure)
        XCTAssertNil(appState.lastConnectionFailure)

        // A current-generation failure presents normally.
        let currentGeneration = appState.dashboardSwitchGenerationForTesting()
        let wroteCurrent = appState.presentCredentialRestoreFailure(failure, switchGeneration: currentGeneration)
        XCTAssertTrue(wroteCurrent)
        XCTAssertTrue(appState.showLogin)
        XCTAssertNotNil(appState.pendingLoginFailure)
        XCTAssertNotNil(appState.lastConnectionFailure)
    }

    // MARK: - Stale ticket renewal fencing

    func testStaleTicketRenewalDoesNotInstallAcrossDashboardSwitch() async {
        let a = track(UUID())
        let b = track(UUID())
        let savedA = SavedDashboard(id: a, label: "A", normalizedURL: parentHostA)
        let savedB = SavedDashboard(id: b, label: "B", normalizedURL: parentHostB)
        // A live session on A whose renewal will be parked mid-flight.
        let originalConnection = HermesConnection(baseUrl: parentHostA, ticket: "a-original")

        // The mint hook parks until the test releases it: a real suspension
        // point inside the renewal, not a sleep race. A plain continuation
        // gate — XCTest's fulfillment(of:) must not be awaited from two
        // places concurrently.
        let mintStarted = expectation(description: "mint started")
        let gateLock = NSLock()
        var releaseGate: CheckedContinuation<String, Never>?
        let lifecycle = ChatResumeLifecycleOperations(
            mintTicket: { _ in
                mintStarted.fulfill()
                return await withCheckedContinuation { continuation in
                    gateLock.lock()
                    releaseGate = continuation
                    gateLock.unlock()
                }
            }
        )
        let appStateWithMint = AppState(
            defaults: defaults,
            chatResumeCoordinator: nil,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: a, dashboards: [savedA, savedB]),
            clearSessionPresentationCache: {},
            reconnectExecutor: nil,
            chatResumeLifecycleOperations: lifecycle,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appStateWithMint.connection = originalConnection
        defaults.set(a.uuidString, forKey: AppState.chatResumeServerIdentityKey)

        let renewal = Task { await appStateWithMint.reconnectForRetry(purpose: .preserveCurrent) }
        await fulfillment(of: [mintStarted], timeout: 5)

        // Switch to B while A's renewal is suspended at the mint.
        await appStateWithMint.switchDashboard(to: b)
        gateLock.lock()
        releaseGate?.resume(returning: "")
        gateLock.unlock()
        await renewal.value

        // B owns the flow: the stale A ticket installed nothing, B's auth is
        // untouched, and A's saved record still holds the ORIGINAL ticket.
        XCTAssertEqual(appStateWithMint.activeDashboardID, b)
        XCTAssertNil(appStateWithMint.connection, "the stale renewal must not install its connection")
        XCTAssertFalse(appStateWithMint.isConnected)
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: a), "A's scoped record was never overwritten by the stale ticket")
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: b), "B's scoped record was never touched by A's renewal")
        XCTAssertNil(appStateWithMint.dashboardTicketBridge, "the switch's retirement holds; the stale renewal did not rebuild a bridge")
    }
}
