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
    private var webViews: [WKWebView] = []

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
        webViews = []
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    /// Production attaches a dashboard's store to its bridge WKWebView before
    /// restoring cookies into it (DashboardTicketBridge). A bare store with no
    /// web view never answered setCookie on hosted CI simulators, so the live
    /// cookie tests attach one the same way.
    @discardableResult
    private func attachWebView(to store: WKWebsiteDataStore) -> WKWebsiteDataStore {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html></html>", baseURL: nil)
        webViews.append(webView)
        return store
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
        let storeA = attachWebView(to: DashboardCookiePersistence.webKitStore(for: UUID()))
        let storeB = attachWebView(to: DashboardCookiePersistence.webKitStore(for: UUID()))
        let cookie = try parentDomainCookie(value: "a-session")

        try await awaitWebKit("setCookie on A") { await storeA.httpCookieStore.setCookie(cookie) }
        // setCookie can return before the network process lists the cookie
        // (seen on a busy hosted runner), so wait until A reads it back. B
        // is checked after that, when the write has certainly landed.
        let isASession: (HTTPCookie) -> Bool = { $0.name == "session" && $0.value == "a-session" }
        let deadline = ContinuousClock.now + .seconds(10)
        var cookiesA = try await awaitWebKit("allCookies on A") { await storeA.httpCookieStore.allCookies() }
        while !cookiesA.contains(where: isASession), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            cookiesA = try await awaitWebKit("allCookies on A") { await storeA.httpCookieStore.allCookies() }
        }
        // Without A's write landing, B's empty store would prove nothing.
        guard cookiesA.contains(where: isASession) else {
            XCTFail("dashboard A never read back its own cookie")
            return
        }

        let cookiesB = try await awaitWebKit("allCookies on B") { await storeB.httpCookieStore.allCookies() }
        XCTAssertFalse(
            cookiesB.contains(where: isASession),
            "dashboard A's WebKit cookie must never appear in dashboard B's store"
        )
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
        let storeB = attachWebView(to: DashboardCookiePersistence.webKitStore(for: b))
        try await awaitWebKit("restore into B") {
            await DashboardCookiePersistence.restoreNativeCookies(
                into: storeB.httpCookieStore,
                for: self.parentHostB,
                dashboardID: b
            )
        }
        let cookiesB = try await awaitWebKit("allCookies on B") { await storeB.httpCookieStore.allCookies() }
        XCTAssertTrue(cookiesB.isEmpty, "no cross-dashboard import through the shared jar")

        // A's bridge restores its own parent-domain and host-only cookies.
        let storeA = attachWebView(to: DashboardCookiePersistence.webKitStore(for: a))
        try await awaitWebKit("restore into A") {
            await DashboardCookiePersistence.restoreNativeCookies(
                into: storeA.httpCookieStore,
                for: self.parentHostA,
                dashboardID: a
            )
        }
        let cookiesA = try await awaitWebKit("allCookies on A") { await storeA.httpCookieStore.allCookies() }
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

    /// #788: the legacy (no dashboard identity) sweep follows the same
    /// rule as the registered one. A parent-domain cookie (Domain=.example.com)
    /// is shared with sibling dashboards and never exact-matches a dashboard
    /// host, so disconnecting a.example.com must leave it alone.
    func testLegacyClearNativeCookiesSparesParentDomainCookies() throws {
        let sharedJar = HTTPCookieStorage.shared
        let sharedParent = try parentDomainCookie(value: "legacy-parent-session")
        let exactHost = try hostCookie(name: "host-residue", value: "legacy-a", domain: "a.example.com")
        sharedJar.setCookie(sharedParent)
        sharedJar.setCookie(exactHost)
        addTeardownBlock {
            sharedJar.deleteCookie(sharedParent)
            sharedJar.deleteCookie(exactHost)
        }

        DashboardCookiePersistence.clearNativeCookies(for: parentHostA)

        XCTAssertNotNil(
            sharedJar.cookies?.first { $0.value == "legacy-parent-session" },
            "a legacy disconnect must not delete a parent-domain cookie shared with sibling dashboards"
        )
        XCTAssertNil(
            sharedJar.cookies?.first { $0.value == "legacy-a" },
            "the dashboard's own exact-host cookie is still cleared"
        )
    }

    /// #788: cookies ignore ports, so two saved dashboards on one machine
    /// (192.168.1.10:9119 and :9120) are kept apart by their OWN jars, not by
    /// host. Signing one out leaves the other's session where it lives.
    func testSignOutLeavesASameHostSiblingOnAnotherPortSignedIn() throws {
        let a = track(UUID())
        let b = track(UUID())
        let dashboardA = SavedDashboard(id: a, label: "A", normalizedURL: "http://192.168.1.10:9119")
        let dashboardB = SavedDashboard(id: b, label: "B", normalizedURL: "http://192.168.1.10:9120")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: b, dashboards: [dashboardA, dashboardB]))
        let jarA = DashboardCookiePersistence.nativeCookieStorage(for: a)
        let jarB = DashboardCookiePersistence.nativeCookieStorage(for: b)
        jarA.setCookie(try hostCookie(name: "session", value: "port-a", domain: "192.168.1.10"))
        jarB.setCookie(try hostCookie(name: "session", value: "port-b", domain: "192.168.1.10"))

        appState.signOutDashboard(a)

        XCTAssertTrue((jarA.cookies ?? []).isEmpty, ":9119's own session is gone")
        XCTAssertNotNil(jarB.cookies?.first { $0.value == "port-b" }, ":9120 stays signed in")
    }

    /// #788: the legacy disconnect's default-store clear runs over WebKit IPC
    /// after the disconnect returns. A quick reconnect to another legacy
    /// dashboard on the same origin waits for it (as the bridge and sign-in
    /// page do), so the clear can never land on the new session's cookies,
    /// and the old session is still gone.
    func testLegacyReconnectWaitsForTheDisconnectsDefaultStoreClear() async throws {
        let store = attachWebView(to: WKWebsiteDataStore.default())
        let host = "conduit-788-legacy.example"
        let old = try hostCookie(name: "session", value: "old-legacy", domain: host)
        try await awaitWebKit("setCookie old") { await store.httpCookieStore.setCookie(old) }
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !awaitWebKit("allCookies", { await store.httpCookieStore.allCookies() })
            .contains(where: { $0.value == "old-legacy" }) {
            // Without the old session in the store, "cleared" proves nothing.
            guard ContinuousClock.now < deadline else { return XCTFail("the old legacy session never landed") }
            try await Task.sleep(for: .milliseconds(100))
        }

        let appState = makeAppState(registry: SavedDashboardRegistry())
        appState.connection = HermesConnection(baseUrl: "https://\(host)", ticket: "test-ticket")
        appState.disconnect()
        XCTAssertTrue(DashboardCookiePersistence.hasPendingDefaultStoreClear, "the default-store clear is ordered, not detached")

        await DashboardCookiePersistence.awaitPendingDefaultStoreClear()
        let new = try hostCookie(name: "session", value: "new-legacy", domain: host)
        try await awaitWebKit("setCookie new") { await store.httpCookieStore.setCookie(new) }
        addTeardownBlock { @MainActor in await store.httpCookieStore.deleteCookie(new) }

        XCTAssertFalse(DashboardCookiePersistence.hasPendingDefaultStoreClear)
        let cookies = try await awaitWebKit("allCookies after") { await store.httpCookieStore.allCookies() }
        XCTAssertTrue(cookies.contains { $0.value == "new-legacy" }, "the reconnect's session survives the earlier disconnect")
        XCTAssertFalse(cookies.contains { $0.value == "old-legacy" }, "the disconnected session is cleared")
    }

    /// The identified-store analog of #788: Sign Out's wipe of a dashboard's
    /// own WebKit store runs over IPC after Sign Out returns. Signing in to
    /// that dashboard again waits for it (as the bridge and sign-in page
    /// do), so the wipe can never land on the new session's cookies, and
    /// the signed-out session is still gone. A sibling's store has nothing
    /// to wait for.
    func testSignInAgainWaitsForTheSignOutsIdentifiedStoreClear() async throws {
        let a = track(UUID())
        let b = track(UUID())
        let host = "conduit-977-identified.example"
        let dashboardA = SavedDashboard(id: a, label: "A", normalizedURL: "https://\(host)")
        let dashboardB = SavedDashboard(id: b, label: "B", normalizedURL: "https://b.\(host)")
        let store = attachWebView(to: DashboardCookiePersistence.webKitStore(for: a))
        let old = try hostCookie(name: "session", value: "old-identified", domain: host)
        try await awaitWebKit("setCookie old") { await store.httpCookieStore.setCookie(old) }
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !awaitWebKit("allCookies", { await store.httpCookieStore.allCookies() })
            .contains(where: { $0.value == "old-identified" }) {
            // Without the old session in the store, "cleared" proves nothing.
            guard ContinuousClock.now < deadline else { return XCTFail("the old session never landed") }
            try await Task.sleep(for: .milliseconds(100))
        }

        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: b, dashboards: [dashboardA, dashboardB]))
        appState.signOutDashboard(a)
        XCTAssertTrue(DashboardCookiePersistence.hasPendingStoreClear(for: a), "the identified-store clear is ordered, not detached")
        XCTAssertFalse(DashboardCookiePersistence.hasPendingStoreClear(for: b), "a sibling's sign-in waits for nothing")

        await DashboardCookiePersistence.awaitPendingStoreClear(for: a)
        let new = try hostCookie(name: "session", value: "new-identified", domain: host)
        try await awaitWebKit("setCookie new") { await store.httpCookieStore.setCookie(new) }

        XCTAssertFalse(DashboardCookiePersistence.hasPendingStoreClear(for: a))
        let cookies = try await awaitWebKit("allCookies after") { await store.httpCookieStore.allCookies() }
        XCTAssertTrue(cookies.contains { $0.value == "new-identified" }, "the new sign-in's session survives the earlier Sign Out")
        XCTAssertFalse(cookies.contains { $0.value == "old-identified" }, "the signed-out session is cleared")
    }

    /// #788: the reconnect's wait is bounded. A WebKit reply that never
    /// comes must not hold the next sign-in forever.
    func testWaitingForADefaultStoreClearIsBounded() async {
        let neverAnswers = Task<Void, Never> { try? await Task.sleep(for: .seconds(600)) }
        defer { neverAnswers.cancel() }
        let started = ContinuousClock.now
        await DashboardCookiePersistence.awaitClear(neverAnswers, timeout: .milliseconds(100))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the wait gives up at its timeout")
    }

    /// A clear whose WebKit reply never comes holds the next clear of the
    /// same store only until the wait's timeout, not forever.
    func testAHungStoreClearDoesNotStopTheNextOne() async {
        let store = track(UUID())
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        DashboardCookiePersistence.scheduleStoreClear(for: store, predecessorTimeout: .milliseconds(100)) {
            for await _ in release.stream {}
        }
        var nextRan = false
        DashboardCookiePersistence.scheduleStoreClear(for: store, predecessorTimeout: .milliseconds(100)) {
            nextRan = true
        }

        await DashboardCookiePersistence.awaitPendingStoreClear(for: store, timeout: .seconds(5))

        XCTAssertTrue(nextRan, "the later clear runs after the bounded wait")
        XCTAssertFalse(DashboardCookiePersistence.hasPendingStoreClear(for: store))
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

// MARK: - Bounded WebKit cookie-store calls

/// WKHTTPCookieStore answers over IPC from WebKit's network process. On a
/// hosted CI simulator that reply has been seen never to arrive (2026-09-30:
/// testRestoreNativeCookiesOnlyImportsTheOwningDashboardJar sat for the full
/// 3-minute allowance, then xcodebuild restarted the test host). Bounding each
/// call turns such a hang into a named failure within seconds.
@MainActor
private final class WebKitCallRace {
    var finished = false
}

private struct WebKitCookieStoreTimeout: Error {}

@MainActor
private func awaitWebKit<T>(
    _ what: String,
    timeout: Duration = .seconds(20),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: @escaping @MainActor () async -> T
) async throws -> T {
    let race = WebKitCallRace()
    let result: T? = await withCheckedContinuation { continuation in
        Task { @MainActor in
            let value = await operation()
            guard !race.finished else { return }
            race.finished = true
            continuation.resume(returning: value)
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !race.finished else { return }
            race.finished = true
            continuation.resume(returning: nil)
        }
    }
    guard let result else {
        XCTFail("WebKit cookie store did not answer \(what) within \(timeout)", file: file, line: line)
        throw WebKitCookieStoreTimeout()
    }
    return result
}
