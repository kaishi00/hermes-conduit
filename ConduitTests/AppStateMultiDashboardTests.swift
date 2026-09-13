//
//  AppStateMultiDashboardTests.swift
//  Conduit
//
//  Multi-dashboard switching semantics (#148): adoption, the dashboard-UUID
//  server-change identity, scoped sign-out/remove, and the collision rule
//  that a dashboard's identity is its UUID — never its URL. Auth isolation
//  between dashboards is covered by SavedDashboardRegistryTests; here the
//  focus is AppState behavior.
//

import XCTest
@testable import Conduit

@MainActor
final class AppStateMultiDashboardTests: XCTestCase {

    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var backend: InMemoryKeychainBackend!
    private var createdDashboardIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        defaultsSuite = "AppStateMultiDashboardTests.\(UUID().uuidString)"
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

    // MARK: - Adoption

    func testAdoptDashboardRegistersAndActivatesNewDashboard() {
        let appState = makeAppState(registry: SavedDashboardRegistry())
        let url = "https://mac.tailnet.ts.net"
        let id = appState.adoptDashboard(forNormalizedURL: url)
        track(id)
        XCTAssertEqual(appState.activeDashboardID, id)
        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: id)?.normalizedURL, url)
        // Persisted, not just in-memory.
        let persisted = SavedDashboardRegistryStore.load()
        XCTAssertEqual(persisted?.activeDashboardID, id)
    }

    func testAdoptDashboardResolvesExistingByURLWithoutDuplicates() {
        let existing = dashboard("Mac", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(
            activeDashboardID: existing.id,
            dashboards: [existing]
        ))
        let id = appState.adoptDashboard(forNormalizedURL: "https://mac.tailnet.ts.net")
        XCTAssertEqual(id, existing.id)
        XCTAssertEqual(appState.savedDashboardRegistry.dashboards.count, 1)
    }

    func testAdoptDashboardRelabelsLegacyURLIdentityForSameServer() {
        let url = "https://mac.tailnet.ts.net"
        defaults.set(url, forKey: AppState.chatResumeServerIdentityKey)
        let appState = makeAppState(registry: SavedDashboardRegistry())
        let id = appState.adoptDashboard(forNormalizedURL: url)
        track(id)
        XCTAssertEqual(
            defaults.string(forKey: AppState.chatResumeServerIdentityKey),
            id.uuidString
        )
    }

    func testAdoptDashboardDoesNotRelabelIdentityOfAnotherServer() {
        let appState = makeAppState(registry: SavedDashboardRegistry())
        defaults.set("https://other.example.com", forKey: AppState.chatResumeServerIdentityKey)
        let id = appState.adoptDashboard(forNormalizedURL: "https://mac.tailnet.ts.net")
        track(id)
        XCTAssertEqual(
            defaults.string(forKey: AppState.chatResumeServerIdentityKey),
            "https://other.example.com"
        )
    }

    // MARK: - Server-change identity (the boundary)

    func testSameDashboardUUIDIsNotAServerSwitch() {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac]))
        let first = appState.prepareChatResumeForConnection(to: mac.normalizedURL, dashboardID: mac.id)
        XCTAssertFalse(first)
        // A reconnect with the same UUID is still not a switch.
        let second = appState.prepareChatResumeForConnection(to: mac.normalizedURL, dashboardID: mac.id)
        XCTAssertFalse(second)
    }

    func testDashboardUUIDChangeIsAServerSwitchEvenWithMatchingURLs() {
        // The collision case: two dashboards that resolve to the same
        // address spelling must still be treated as different servers — the
        // UUID, not the URL, is the identity.
        let a = dashboard("Mac", "https://mac.tailnet.ts.net")
        let b = dashboard("Mac2", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: a.id, dashboards: [a, b]))
        defaults.set(a.id.uuidString, forKey: AppState.chatResumeServerIdentityKey)
        XCTAssertTrue(appState.prepareChatResumeForConnection(to: b.normalizedURL, dashboardID: b.id))
        XCTAssertEqual(
            defaults.string(forKey: AppState.chatResumeServerIdentityKey),
            b.id.uuidString
        )
    }

    func testSwitchBackToFirstDashboardRetiresSecondIdentity() {
        // A -> B -> A: the second A connection is a NEW generation, never a
        // continuation of the first.
        let a = dashboard("Mac", "https://mac.tailnet.ts.net")
        let b = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: a.id, dashboards: [a, b]))
        XCTAssertFalse(appState.prepareChatResumeForConnection(to: a.normalizedURL, dashboardID: a.id))
        XCTAssertTrue(appState.prepareChatResumeForConnection(to: b.normalizedURL, dashboardID: b.id))
        XCTAssertTrue(appState.prepareChatResumeForConnection(to: a.normalizedURL, dashboardID: a.id))
    }

    func testDashboardIdentityNeverCollidesWithURLOfAnotherServer() {
        // A dashboard UUID and a URL-shaped identity are disjoint: switching
        // between dashboard-scoped and URL-scoped connections is a server
        // change in both directions.
        let a = dashboard("Mac", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: a.id, dashboards: [a]))
        defaults.set(a.id.uuidString, forKey: AppState.chatResumeServerIdentityKey)
        XCTAssertTrue(appState.prepareChatResumeForConnection(to: "https://other.example.com", dashboardID: nil))
        XCTAssertTrue(appState.prepareChatResumeForConnection(to: a.normalizedURL, dashboardID: a.id))
    }

    func testUnparseableURLWithoutDashboardIdentityIsRejectedWithoutWrites() {
        let appState = makeAppState(registry: SavedDashboardRegistry())
        defaults.set("https://previous.example.com", forKey: AppState.chatResumeServerIdentityKey)
        XCTAssertFalse(appState.prepareChatResumeForConnection(to: "not a url", dashboardID: nil))
        XCTAssertEqual(
            defaults.string(forKey: AppState.chatResumeServerIdentityKey),
            "https://previous.example.com"
        )
    }

    // MARK: - Switching

    func testSwitchToDashboardWithoutAuthSelectsTargetAndPresentsSignIn() async {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))

        await appState.switchDashboard(to: vps.id)

        // The target is selected BEFORE connecting, so a failed switch leaves
        // it selected; no other dashboard is auto-connected.
        XCTAssertEqual(appState.activeDashboardID, vps.id)
        XCTAssertTrue(appState.showLogin)
        XCTAssertNil(appState.connection)
        // Still saved.
        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: mac.id))
        // The sign-in seeds the target's own address.
        XCTAssertEqual(appState.lastDashboardURL, vps.normalizedURL)
    }

    func testSwitchToUnknownDashboardIsInert() async {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac]))
        appState.showLogin = false

        await appState.switchDashboard(to: UUID())

        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertFalse(appState.showLogin)
    }

    func testSwitchToAlreadyActiveConnectedDashboardIsNoOp() async {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac]))
        appState.isConnected = true
        appState.showLogin = false

        await appState.switchDashboard(to: mac.id)

        XCTAssertFalse(appState.showLogin)
        XCTAssertEqual(appState.activeDashboardID, mac.id)
    }

    func testSwitchWithSavedCredentialsRestoresThroughCredentialPath() async {
        // A dashboard with scoped reusable credentials signs in WITHOUT the
        // login card: the credential restore path runs. The auth itself
        // cannot succeed against a closed loopback port, and the failure
        // falls back to the login surface — but the target stayed selected
        // and the login card is seeded with the dashboard's own address.
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let loopback = dashboard("Local", "http://127.0.0.1:1")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, loopback]))
        KeychainHelper.saveCredentials(
            DashboardCredentials(
                baseURL: "http://127.0.0.1:1",
                username: "hermes",
                password: "unused",
                requiresFaceID: false
            ),
            dashboardID: loopback.id
        )

        await appState.switchDashboard(to: loopback.id)

        XCTAssertEqual(appState.activeDashboardID, loopback.id)
        XCTAssertNotNil(appState.lastConnectionFailure)
        XCTAssertTrue(appState.showLogin)
        XCTAssertEqual(appState.lastDashboardURL, loopback.normalizedURL)
    }

    // MARK: - Sign out / remove scoping

    func testSignOutActiveDashboardClearsOnlyItsScopedRecords() throws {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: mac.normalizedURL, username: "u", password: "p", requiresFaceID: false),
            dashboardID: mac.id
        )
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: vps.normalizedURL, username: "u2", password: "p2", requiresFaceID: false),
            dashboardID: vps.id
        )

        appState.signOutDashboard(mac.id)

        // The active dashboard's auth is gone...
        XCTAssertNil(KeychainHelper.loadCredentials(dashboardID: mac.id))
        // ...its metadata stays saved and selected...
        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: mac.id))
        // ...and the other dashboard is untouched.
        XCTAssertNotNil(try XCTUnwrap(KeychainHelper.loadCredentials(dashboardID: vps.id)))
        XCTAssertFalse(appState.isConnected)
        XCTAssertTrue(appState.showLogin)
    }

    func testSignOutInactiveDashboardClearsOnlyThatDashboard() throws {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: vps.normalizedURL, username: "u", password: "p", requiresFaceID: false),
            dashboardID: vps.id
        )

        appState.signOutDashboard(vps.id)

        XCTAssertNil(KeychainHelper.loadCredentials(dashboardID: vps.id))
        // Metadata stays; the active dashboard is unaffected.
        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: vps.id))
        XCTAssertEqual(appState.activeDashboardID, mac.id)
    }

    func testRemoveActiveDashboardLeavesDisconnectedWithoutAutoConnect() throws {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))
        KeychainHelper.saveConnection(HermesConnection(baseUrl: mac.normalizedURL, ticket: "t"), dashboardID: mac.id)

        appState.removeDashboard(mac.id)

        // The dashboard is gone along with its secure state...
        XCTAssertNil(appState.savedDashboardRegistry.dashboard(with: mac.id))
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: mac.id))
        XCTAssertNil(appState.activeDashboardID)
        // ...Conduit is disconnected with the selection/add flow, and the
        // other saved dashboard is NOT auto-connected.
        XCTAssertTrue(appState.showLogin)
        XCTAssertFalse(appState.isConnected)
        XCTAssertNil(appState.connection)
        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: vps.id))
    }

    func testRemoveInactiveDashboardNeverTouchesActiveOrOthers() throws {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let desktop = dashboard("Desktop", "https://192.168.1.5:8080")
        let appState = makeAppState(registry: SavedDashboardRegistry(
            activeDashboardID: mac.id,
            dashboards: [mac, vps, desktop]
        ))
        KeychainHelper.saveConnection(HermesConnection(baseUrl: vps.normalizedURL, ticket: "vps-t"), dashboardID: vps.id)

        appState.removeDashboard(vps.id)

        XCTAssertNil(appState.savedDashboardRegistry.dashboard(with: vps.id))
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: vps.id))
        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: desktop.id))
        XCTAssertEqual(appState.savedDashboardRegistry.dashboards.count, 2)
    }

    // MARK: - Selection persistence

    func testSelectDashboardTargetPersistsAcrossRegistryReloads() {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))

        appState.selectDashboardTarget(vps.id)

        XCTAssertEqual(SavedDashboardRegistryStore.load()?.activeDashboardID, vps.id)
    }
}

// MARK: - Switch retirement (review hardening)

extension AppStateMultiDashboardTests {

    func testSwitchToAuthlessDashboardRetiresOutgoingConnectionRuntime() async {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))
        // A live-looking outgoing session, exactly as a real connection
        // leaves it: the stored server identity names the outgoing dashboard
        // and its scoped connection record exists.
        defaults.set(mac.id.uuidString, forKey: AppState.chatResumeServerIdentityKey)
        KeychainHelper.saveConnection(HermesConnection(baseUrl: mac.normalizedURL, ticket: "mac-ticket"), dashboardID: mac.id)
        appState.isConnected = true
        appState.isConnecting = false
        appState.sessions = [SessionSummary(
            id: "runtime-1",
            storedSessionId: nil,
            alternateIds: [],
            title: "t",
            model: "m",
            updatedLabel: "",
            profile: nil,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )]

        await appState.switchDashboard(to: vps.id)

        // The outgoing dashboard's runtime is retired, not left streaming
        // behind the new target's sign-in surface...
        XCTAssertFalse(appState.isConnected)
        XCTAssertNil(appState.connection)
        XCTAssertTrue(appState.sessions.isEmpty, "the outgoing server's session catalog is retired at the switch boundary")
        // ...the target is selected and presents its sign-in...
        XCTAssertEqual(appState.activeDashboardID, vps.id)
        XCTAssertTrue(appState.showLogin)
        // ...and the outgoing dashboard stays saved with its auth intact.
        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: mac.id))
        XCTAssertNotNil(KeychainHelper.loadConnection(dashboardID: mac.id))
    }

    func testFailedCredentialSwitchDoesNotBlockLaterSelection() async {
        // Switch to a credential dashboard whose auth fails (closed loopback
        // port), then switch to an authless dashboard: the later selection
        // wins, the failure surface belongs to it, and no connection is
        // installed. This is the sequential shape of the rapid-switch rule;
        // the in-flight overlap is fenced by the switch-generation guard in
        // restoreSavedCredentials/restoreSavedConnection.
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let loopback = dashboard("Local", "http://127.0.0.1:1")
        let desktop = dashboard("Desktop", "https://192.168.1.5:8080")
        let appState = makeAppState(registry: SavedDashboardRegistry(
            activeDashboardID: mac.id,
            dashboards: [mac, loopback, desktop]
        ))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: "http://127.0.0.1:1", username: "u", password: "p", requiresFaceID: false),
            dashboardID: loopback.id
        )

        await appState.switchDashboard(to: loopback.id)
        XCTAssertEqual(appState.activeDashboardID, loopback.id)
        XCTAssertTrue(appState.showLogin)

        await appState.switchDashboard(to: desktop.id)

        XCTAssertEqual(appState.activeDashboardID, desktop.id)
        XCTAssertTrue(appState.showLogin)
        XCTAssertNil(appState.connection)
        XCTAssertFalse(appState.isConnected)
        // All three dashboards remain saved.
        XCTAssertEqual(appState.savedDashboardRegistry.dashboards.count, 3)
    }
}
