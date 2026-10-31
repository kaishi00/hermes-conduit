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

import UIKit
import UserNotifications
import XCTest
@testable import Conduit

@MainActor
final class AppStateMultiDashboardTests: XCTestCase {

    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var backend: InMemoryKeychainBackend!
    private var createdDashboardIDs: [UUID] = []
    private var avatarsRoot: URL!
    private var legacyAvatarsDirectory: URL!

    override func setUp() {
        super.setUp()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateMultiDashboardTests.\(UUID().uuidString)", isDirectory: true)
        avatarsRoot = scratch.appendingPathComponent("profile-avatars", isDirectory: true)
        legacyAvatarsDirectory = scratch.appendingPathComponent("ProfileAvatars", isDirectory: true)
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
        try? FileManager.default.removeItem(at: avatarsRoot.deletingLastPathComponent())
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
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            profileAppearanceStore: makeAppearanceStore()
        )
    }

    private func makeAppearanceStore() -> ProfileAppearanceStore {
        ProfileAppearanceStore(
            defaults: defaults,
            avatarsRoot: avatarsRoot,
            legacyAvatarDirectories: [avatarsRoot, legacyAvatarsDirectory]
        )
    }

    private func photoData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()!
    }

    private func dashboard(_ label: String, _ url: String) -> SavedDashboard {
        SavedDashboard(id: UUID(), label: label, normalizedURL: url)
    }

    // MARK: - Busy mode on a profile switch

    /// A profile switched to shows the busy mode it last had on this
    /// dashboard at once, before Hermes is asked again (#1443), and Hermes'
    /// own default when it never had one here.
    func testAProfileSwitchedToShowsItsLastBusyModeAtOnce() {
        let appState = makeAppState(registry: SavedDashboardRegistry())
        defaults.set("server-a", forKey: AppState.chatResumeServerIdentityKey)
        defaults.set(BusyInputMode.queue.rawValue, forKey: "\(AppState.busyInputModeCachePrefix)server-a|work")
        defaults.set(BusyInputMode.steer.rawValue, forKey: "\(AppState.busyInputModeCachePrefix)server-b|home")

        appState.setActiveProfileForTesting("work")
        XCTAssertEqual(appState.busyInputMode, .queue)

        appState.setActiveProfileForTesting("home")
        XCTAssertEqual(appState.busyInputMode, .interrupt, "another server's cache is not this one's")
    }

    // MARK: - Agent settings scope

    func testAgentSettingsScopeTellsApartDashboardsWhosePathsDifferInCase() {
        let upper = dashboard("Tenant", "https://hermes.example/Tenant")
        let lower = dashboard("tenant", "https://hermes.example/tenant")
        let registry = SavedDashboardRegistry(activeDashboardID: upper.id, dashboards: [upper, lower])
        let onUpper = makeAppState(registry: registry)
        onUpper.connection = HermesConnection(baseUrl: upper.normalizedURL, ticket: "ticket")
        var lowerRegistry = registry
        lowerRegistry.activeDashboardID = lower.id
        let onLower = makeAppState(registry: lowerRegistry)
        onLower.connection = HermesConnection(baseUrl: lower.normalizedURL, ticket: "ticket")

        // Answers waiting to be sent are kept by this scope: one dashboard's
        // must never go to (and be cleared by) the other.
        XCTAssertNotNil(onUpper.agentSettingsScope)
        XCTAssertNotEqual(onUpper.agentSettingsScope, onLower.agentSettingsScope)
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

    // MARK: - Add a dashboard closed without signing in

    func testClosingAddForgetsTheDashboardAnUnfinishedSignInSaved() throws {
        let appState = makeAppState(registry: SavedDashboardRegistry())
        let flow = LoginFlowModel()
        flow.attach(appState)
        let url = "https://new.example.com"
        flow.noteUnsavedSignIn(at: url)
        // The single sign-on sheet saves the dashboard and its token as it opens.
        let id = track(try XCTUnwrap(appState.resolveDashboardID(forURL: url, registerIfMissing: true)))
        let token = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "cf-id", clientSecret: "cf-secret"))
        KeychainHelper.saveCloudflareAccess(token, origin: url, dashboardID: id)

        flow.discardUnfinishedDashboards()

        XCTAssertNil(appState.savedDashboardRegistry.dashboard(with: id))
        XCTAssertNil(KeychainHelper.loadCloudflareAccess(dashboardID: id, for: url))
    }

    func testClosingAddKeepsDashboardsSavedBeforeOrSignedIn() throws {
        let appState = makeAppState(registry: SavedDashboardRegistry())
        let savedURL = "https://saved.example.com"
        let saved = track(try XCTUnwrap(appState.resolveDashboardID(forURL: savedURL, registerIfMissing: true)))
        let flow = LoginFlowModel()
        flow.attach(appState)
        flow.noteUnsavedSignIn(at: savedURL)
        let signedInURL = "https://signed-in.example.com"
        flow.noteUnsavedSignIn(at: signedInURL)
        let signedIn = track(try XCTUnwrap(appState.resolveDashboardID(forURL: signedInURL, registerIfMissing: true)))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: signedInURL, username: "eric", password: "p", requiresFaceID: false),
            dashboardID: signedIn
        )

        flow.discardUnfinishedDashboards()

        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: saved))
        XCTAssertNotNil(appState.savedDashboardRegistry.dashboard(with: signedIn))
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

    // MARK: - An address edited in Settings

    /// What the Settings Connection page does when its tested setup is applied.
    @discardableResult
    private func applyFromSettings(
        _ result: ConnectionSetupResult,
        to appState: AppState,
        currentURL: String
    ) -> ConnectionSetupApplication {
        let plan = ConnectionSetupApplication.plan(
            result: result,
            currentDashboardURL: currentURL,
            savedCredentials: appState.savedCredentialsForDashboard(at: currentURL),
            savedCloudflareAccess: appState.dashboardScopedCloudflareAccess(for: currentURL)
        )
        plan.perform(appState: appState)
        return plan
    }

    func testAnEditedAddressKeepsItsDashboardAndWaitsForTheNextReconnect() {
        let home = dashboard("Home", "https://old.example.test")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home]))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: home.normalizedURL, username: "eric", password: "old", requiresFaceID: false),
            dashboardID: home.id
        )
        KeychainHelper.saveConnection(HermesConnection(baseUrl: home.normalizedURL, ticket: "live"), dashboardID: home.id)
        appState.isConnected = true

        applyFromSettings(
            ConnectionSetupResult(serverURL: "https://new.example.test", username: "eric", password: "next"),
            to: appState,
            currentURL: home.normalizedURL
        )

        XCTAssertEqual(appState.savedDashboardRegistry.dashboards.map(\.id), [home.id], "No second dashboard")
        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: home.id)?.password, "next")
        // The session in use keeps its address and saved ticket.
        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: home.id)?.normalizedURL, home.normalizedURL)
        XCTAssertNotNil(KeychainHelper.loadConnection(dashboardID: home.id))
    }

    func testTheNextLaunchMovesTheDashboardWithItsCloudflareToken() {
        let home = dashboard("Home", "https://hermes.example.test/old")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home]))
        KeychainHelper.saveConnection(HermesConnection(baseUrl: home.normalizedURL, ticket: "old"), dashboardID: home.id)
        let access = CloudflareAccessCredentials(clientID: "id", clientSecret: "secret")
        KeychainHelper.saveCloudflareAccess(access, origin: home.normalizedURL, dashboardID: home.id)

        applyFromSettings(
            ConnectionSetupResult(serverURL: "https://hermes.example.test/new", username: "", password: ""),
            to: appState,
            currentURL: home.normalizedURL
        )
        // The token still opens the address in use until the move.
        XCTAssertEqual(KeychainHelper.loadCloudflareAccess(dashboardID: home.id, for: home.normalizedURL), access)

        // The next launch reads the move back from the saved registry.
        let relaunched = makeAppState(registry: SavedDashboardRegistryStore.load() ?? SavedDashboardRegistry())
        relaunched.loadSavedConnection()

        XCTAssertEqual(relaunched.savedDashboardRegistry.dashboards.map(\.id), [home.id])
        XCTAssertEqual(relaunched.savedDashboardRegistry.dashboard(with: home.id)?.normalizedURL, "https://hermes.example.test/new")
        XCTAssertEqual(KeychainHelper.loadCloudflareAccess(dashboardID: home.id, for: "https://hermes.example.test/new"), access)
        // The old address's ticket can't reconnect at the new one.
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: home.id))
        XCTAssertTrue(relaunched.showLogin)
        XCTAssertEqual(relaunched.lastDashboardURL, "https://hermes.example.test/new")
    }

    func testSwitchingBackMovesTheDashboardAndForgetsThePasswordForTheOldAddress() async {
        let home = dashboard("Home", "http://127.0.0.1:1")
        let work = dashboard("Work", "https://work.example.test")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home, work]))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: home.normalizedURL, username: "eric", password: "old", requiresFaceID: false),
            dashboardID: home.id
        )

        applyFromSettings(
            ConnectionSetupResult(serverURL: "http://127.0.0.1:2", username: "", password: ""),
            to: appState,
            currentURL: home.normalizedURL
        )
        appState.selectDashboardTarget(work.id)
        await appState.switchDashboard(to: home.id)

        XCTAssertEqual(appState.activeDashboardID, home.id)
        XCTAssertEqual(appState.savedDashboardRegistry.dashboards.map(\.id), [home.id, work.id])
        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: home.id)?.normalizedURL, "http://127.0.0.1:2")
        // The setup applied had no password: the old address's one is not
        // sent to the new address.
        XCTAssertNil(KeychainHelper.loadCredentials(dashboardID: home.id))
        XCTAssertTrue(appState.showLogin)
        XCTAssertEqual(appState.lastDashboardURL, "http://127.0.0.1:2")
    }

    func testAReconnectAtTheEditedAddressIsTheSameDashboard() {
        let home = dashboard("Home", "https://old.example.test")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home]))

        applyFromSettings(
            ConnectionSetupResult(serverURL: "https://new.example.test", username: "", password: ""),
            to: appState,
            currentURL: home.normalizedURL
        )

        XCTAssertEqual(appState.adoptDashboard(forNormalizedURL: "https://new.example.test"), home.id)
        XCTAssertEqual(appState.savedDashboardRegistry.dashboards.map(\.id), [home.id])
        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: home.id)?.normalizedURL, "https://new.example.test")
    }

    func testAddingADashboardAtTheEditedAddressLeavesTheOldOneWhereItIs() {
        let home = dashboard("Home", "https://old.example.test")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home]))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: home.normalizedURL, username: "eric", password: "old", requiresFaceID: false),
            dashboardID: home.id
        )
        appState.isConnected = true

        applyFromSettings(
            ConnectionSetupResult(serverURL: "https://new.example.test", username: "eric", password: "next"),
            to: appState,
            currentURL: home.normalizedURL
        )
        // Add a dashboard, while Home is in use.
        let added = appState.resolveDashboardID(forURL: "https://new.example.test", registerIfMissing: true)

        XCTAssertNotNil(added)
        XCTAssertNotEqual(added, home.id)
        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: home.id)?.normalizedURL, home.normalizedURL)
        XCTAssertEqual(appState.activeDashboardID, home.id)
        // The password saved for the move would send Home's next sign-in to
        // the added dashboard.
        XCTAssertNotEqual(KeychainHelper.loadCredentials(dashboardID: home.id)?.baseURL, "https://new.example.test")
    }

    func testASignInWriteAtTheEditedAddressMovesTheSelectedDashboard() {
        let home = dashboard("Home", "https://old.example.test")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home]))
        KeychainHelper.saveConnection(HermesConnection(baseUrl: home.normalizedURL, ticket: "old"), dashboardID: home.id)

        applyFromSettings(
            ConnectionSetupResult(serverURL: "https://new.example.test", username: "", password: ""),
            to: appState,
            currentURL: home.normalizedURL
        )
        // A Cloudflare token or browser grant saved before connecting there
        // (Home is selected, not in use).
        let target = appState.resolveDashboardID(forURL: "https://new.example.test", registerIfMissing: true)

        XCTAssertEqual(target, home.id)
        XCTAssertEqual(appState.savedDashboardRegistry.dashboards.map(\.id), [home.id], "No second dashboard")
        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: home.id)?.normalizedURL, "https://new.example.test")
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: home.id))
        XCTAssertEqual(appState.adoptDashboard(forNormalizedURL: "https://new.example.test"), home.id)
    }

    func testCancellingAnEditedAddressForgetsThePasswordSavedForIt() {
        let home = dashboard("Home", "https://old.example.test")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home]))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: home.normalizedURL, username: "eric", password: "old", requiresFaceID: false),
            dashboardID: home.id
        )
        appState.isConnected = true

        applyFromSettings(
            ConnectionSetupResult(serverURL: "https://new.example.test", username: "eric", password: "next"),
            to: appState,
            currentURL: home.normalizedURL
        )
        // Re-applying the address in use, with nothing typed, cancels it.
        applyFromSettings(
            ConnectionSetupResult(serverURL: home.normalizedURL, username: "", password: ""),
            to: appState,
            currentURL: home.normalizedURL
        )

        XCTAssertNil(appState.savedDashboardRegistry.dashboard(with: home.id)?.pendingURL)
        // Its next sign-in can't reach the cancelled address as a second
        // dashboard.
        XCTAssertNotEqual(KeychainHelper.loadCredentials(dashboardID: home.id)?.baseURL, "https://new.example.test")
        let relaunched = makeAppState(registry: SavedDashboardRegistryStore.load() ?? SavedDashboardRegistry())
        relaunched.loadSavedConnection()
        XCTAssertEqual(relaunched.savedDashboardRegistry.dashboards.map(\.id), [home.id])
        XCTAssertEqual(relaunched.savedDashboardRegistry.dashboard(with: home.id)?.normalizedURL, home.normalizedURL)
    }

    func testAnEditedAddressThatIsAnotherSavedDashboardChangesNothing() {
        let home = dashboard("Home", "https://old.example.test")
        let vps = dashboard("VPS", "https://vps.example.test")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home, vps]))
        let homeCredentials = DashboardCredentials(baseURL: home.normalizedURL, username: "eric", password: "old", requiresFaceID: false)
        let vpsCredentials = DashboardCredentials(baseURL: vps.normalizedURL, username: "ops", password: "vps", requiresFaceID: false)
        KeychainHelper.saveCredentials(homeCredentials, dashboardID: home.id)
        KeychainHelper.saveCredentials(vpsCredentials, dashboardID: vps.id)
        let registryBefore = appState.savedDashboardRegistry

        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: vps.normalizedURL, username: "eric", password: "next"),
            currentDashboardURL: home.normalizedURL,
            savedCredentials: appState.savedCredentialsForDashboard(at: home.normalizedURL),
            savedCloudflareAccess: appState.dashboardScopedCloudflareAccess(for: home.normalizedURL)
        )

        // Settings says which dashboard has that address.
        XCTAssertEqual(plan.perform(appState: appState), .addressBelongsToDashboard(label: "VPS"))
        XCTAssertEqual(appState.savedDashboardRegistry, registryBefore)
        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: home.id), homeCredentials)
        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: vps.id), vpsCredentials)
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

    func testSignOutKeepsTheUsernameAndCloudflareTokenForTheNextSignIn() throws {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))
        let token = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "cf-id", clientSecret: "cf-secret"))
        for entry in [mac, vps] {
            KeychainHelper.saveCredentials(
                DashboardCredentials(baseURL: entry.normalizedURL, username: "eric-\(entry.label)", password: "p", requiresFaceID: false),
                dashboardID: entry.id
            )
            KeychainHelper.saveCloudflareAccess(token, origin: entry.normalizedURL, dashboardID: entry.id)
        }

        // The active dashboard takes the full disconnect; the other the
        // scoped sign-out.
        appState.signOutDashboard(mac.id)
        appState.signOutDashboard(vps.id)

        for entry in [mac, vps] {
            // The password is gone; the username and the Cloudflare token
            // stay for the next sign-in.
            XCTAssertNil(KeychainHelper.loadCredentials(dashboardID: entry.id))
            XCTAssertEqual(appState.savedSignIn(for: entry.id), .signInNeeded)
            XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: entry.id)?.username, "eric-\(entry.label)")
            XCTAssertEqual(KeychainHelper.loadCloudflareAccess(dashboardID: entry.id, for: entry.normalizedURL), token)
        }
        XCTAssertEqual(SavedDashboardRegistryStore.load()?.dashboard(with: mac.id)?.username, "eric-Mac")
    }

    func testRemoveDashboardDeletesItsCloudflareToken() throws {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))
        let token = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "cf-id", clientSecret: "cf-secret"))
        for entry in [mac, vps] {
            KeychainHelper.saveCloudflareAccess(token, origin: entry.normalizedURL, dashboardID: entry.id)
        }

        appState.removeDashboard(vps.id)
        XCTAssertNil(KeychainHelper.loadCloudflareAccess(dashboardID: vps.id, for: vps.normalizedURL))
        XCTAssertEqual(KeychainHelper.loadCloudflareAccess(dashboardID: mac.id, for: mac.normalizedURL), token)

        appState.removeDashboard(mac.id)
        XCTAssertNil(KeychainHelper.loadCloudflareAccess(dashboardID: mac.id, for: mac.normalizedURL))
    }

    func testSavedSignInNamesWhatEachDashboardCanSignInWith() {
        let home = dashboard("Home", "https://home.example")
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let review = dashboard("Review", "https://review.example.com")
        let fresh = dashboard("Fresh", "https://fresh.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: home.id, dashboards: [home, mac, review, fresh]))
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: home.normalizedURL, username: "u", password: "p", requiresFaceID: true),
            dashboardID: home.id
        )
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: mac.normalizedURL, username: "u", password: "p", requiresFaceID: false),
            dashboardID: mac.id
        )
        KeychainHelper.saveConnection(HermesConnection(baseUrl: review.normalizedURL, ticket: "t"), dashboardID: review.id)

        XCTAssertEqual(appState.savedSignIn(for: home.id), .biometric)
        XCTAssertEqual(appState.savedSignIn(for: mac.id), .password)
        XCTAssertEqual(appState.savedSignIn(for: review.id), .session)
        XCTAssertEqual(appState.savedSignIn(for: fresh.id), .signInNeeded)
        XCTAssertFalse(SavedSignInKind.signInNeeded.canSignInWithoutTyping)
        XCTAssertTrue(SavedSignInKind.session.canSignInWithoutTyping)
    }

    func testASignInRemembersItsUsernameAndABlankOneNeverReplacesIt() {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac]))

        appState.rememberDashboardUsername("  eric ", dashboardID: mac.id)
        appState.rememberDashboardUsername("   ", dashboardID: mac.id)
        // An unknown dashboard is ignored.
        appState.rememberDashboardUsername("someone", dashboardID: UUID())

        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: mac.id)?.username, "eric")
        XCTAssertEqual(appState.savedDashboardRegistry.dashboards.count, 1)
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

    func testRemovingADashboardDropsExtraHeadersOnlyWhenNoOtherDashboardSharesTheOrigin() {
        let active = dashboard("Active", "https://shared.example/two")
        let sibling = dashboard("Sibling", "https://shared.example/one")
        let solo = dashboard("Solo", "https://solo.example")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: active.id, dashboards: [active, sibling, solo]))
        addTeardownBlock {
            CustomHeaderStore.shared.removeHeaders(forServerURL: "https://shared.example")
            CustomHeaderStore.shared.removeHeaders(forServerURL: "https://solo.example")
        }
        CustomHeaderStore.shared.setHeaders([CustomHeader(name: "X-Shared", value: "s")], forServerURL: sibling.normalizedURL)
        CustomHeaderStore.shared.setHeaders([CustomHeader(name: "X-Solo", value: "o")], forServerURL: solo.normalizedURL)

        appState.removeDashboard(sibling.id)
        appState.removeDashboard(solo.id)

        // The active dashboard still reaches the shared origin, so its
        // headers stay; nothing else uses the solo origin, so they go.
        XCTAssertEqual(CustomHeaderStore.shared.headers(forServerURL: active.normalizedURL).map(\.name), ["X-Shared"])
        XCTAssertTrue(CustomHeaderStore.shared.headers(forServerURL: solo.normalizedURL).isEmpty)
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

    // MARK: - Native OAuth grants on switch

    private func makeAppState(
        registry: SavedDashboardRegistry,
        mintTicket: @escaping @MainActor (String) async throws -> String
    ) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(mintTicket: mintTicket),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            profileAppearanceStore: makeAppearanceStore()
        )
    }

    private func grant() -> NativeOAuthTokenSet {
        NativeOAuthTokenSet(accessToken: "access", refreshToken: "refresh", expiresAt: 4_000_000_000, provider: "self-hosted", userID: "user")
    }

    /// A dashboard whose only saved sign-in is its OAuth grant (the saved
    /// session was cleared, or the first ticket never arrived) mints a
    /// ticket from that grant on a switch, the way cold launch does,
    /// instead of opening a sign-in it doesn't need.
    func testSwitchToAGrantOnlyDashboardMintsATicketFromTheGrant() async {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        var minted: [String] = []
        let appState = makeAppState(
            registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]),
            mintTicket: { baseURL in
                minted.append(baseURL)
                throw DashboardTicketBridgeError.signInRequired
            }
        )
        KeychainHelper.saveNativeOAuthTokens(grant(), dashboardID: track(vps.id))

        await appState.switchDashboard(to: vps.id)

        XCTAssertEqual(minted, [vps.normalizedURL], "The switch asks the grant for a ticket")
        XCTAssertEqual(appState.activeDashboardID, vps.id)
        XCTAssertTrue(appState.showLogin, "A refused grant ends at sign-in")
        XCTAssertNotNil(appState.pendingLoginFailure, "...saying why")
    }

    /// The sign-in screen's row for that dashboard: a tap reaches the grant
    /// and, when it is refused, shows why. It never does nothing.
    func testTappingAGrantOnlyDashboardRowIsNeverADeadTap() async {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        var minted = 0
        let appState = makeAppState(
            registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]),
            mintTicket: { _ in
                minted += 1
                throw DashboardTicketBridgeError.signInRequired
            }
        )
        KeychainHelper.saveNativeOAuthTokens(grant(), dashboardID: track(vps.id))
        XCTAssertEqual(appState.savedSignIn(for: vps.id), .session)
        let flow = LoginFlowModel()
        flow.attach(appState)

        await flow.open(vps)
        await flow.open(vps)

        XCTAssertEqual(minted, 2, "Every tap tries the grant")
        XCTAssertNotNil(appState.pendingLoginFailure, "The refusal is shown under the row")
    }

    /// A widget launch that expires while the ticket is minted stops before
    /// connecting and is settled on sign-in, as the other saved sign-ins are.
    func testAnExpiredWidgetLaunchStopsAGrantSwitchBeforeConnecting() async {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let vps = dashboard("VPS", "https://hermes.example.com")
        var leaseIsCurrent = true
        let appState = makeAppState(
            registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]),
            mintTicket: { _ in
                leaseIsCurrent = false
                return "ticket"
            }
        )
        KeychainHelper.saveNativeOAuthTokens(grant(), dashboardID: track(vps.id))

        await appState.switchDashboard(to: vps.id, widgetLease: WidgetLaunchLease(isCurrent: { leaseIsCurrent }))

        XCTAssertNil(appState.connection, "Nothing connects for an expired launch")
        XCTAssertFalse(appState.isConnecting)
        XCTAssertTrue(appState.showLogin)
        XCTAssertNotNil(KeychainHelper.loadNativeOAuthTokens(dashboardID: vps.id), "The grant stays for the next try")
    }

    // MARK: - Dashboard-scoped profile presentation (profile bleed)

    func testDefaultProfileNameAndPhotoDoNotFollowADashboardSwitch() throws {
        // Every Hermes server has a "default" profile. The label and photo
        // chosen for it on the primary dashboard must not appear on another.
        let primary = dashboard("Primary", "https://mac.tailnet.ts.net")
        let review = dashboard("Review", "https://review.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: primary.id, dashboards: [primary, review]))
        appState.saveDefaultProfileName("Atlas")
        try appState.saveProfileAvatarOnDevice(photoData(), for: "default")
        XCTAssertEqual(appState.profileDisplayName("default"), "Atlas")
        XCTAssertNotNil(appState.profileAvatarURL(for: "default"))

        appState.selectDashboardTarget(review.id)

        XCTAssertEqual(appState.defaultProfileName, ProfileAppearanceStore.defaultName)
        XCTAssertEqual(appState.profileDisplayName("default"), ProfileAppearanceStore.defaultName)
        XCTAssertNil(appState.profileAvatarURL(for: "default"))

        appState.saveDefaultProfileName("Reviewer")
        appState.selectDashboardTarget(primary.id)

        XCTAssertEqual(appState.defaultProfileName, "Atlas")
        XCTAssertNotNil(appState.profileAvatarURL(for: "default"))
        // A fresh launch reads the same per-dashboard state back.
        let relaunched = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: review.id, dashboards: [primary, review]))
        XCTAssertEqual(relaunched.defaultProfileName, "Reviewer")
        XCTAssertNil(relaunched.profileAvatarURL(for: "default"))
    }

    func testLegacyGlobalAppearanceIsAdoptedByTheFirstDashboardOnly() throws {
        let primary = dashboard("Primary", "https://mac.tailnet.ts.net")
        let review = dashboard("Review", "https://review.example.com")
        defaults.set("Atlas", forKey: ProfileAppearanceStore.legacyDefaultNameKey)
        try FileManager.default.createDirectory(at: avatarsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyAvatarsDirectory, withIntermediateDirectories: true)
        try photoData().write(to: avatarsRoot.appendingPathComponent(ProfileAppearanceStore.fileName(for: "default")))
        try photoData().write(to: legacyAvatarsDirectory.appendingPathComponent(ProfileAppearanceStore.fileName(for: "coder")))

        // Upgrade launch while the second dashboard is selected: the legacy
        // values still belong to the first one.
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: review.id, dashboards: [primary, review]))

        XCTAssertEqual(appState.defaultProfileName, ProfileAppearanceStore.defaultName)
        XCTAssertTrue(appState.profileAvatarURLs.isEmpty)
        XCTAssertNil(defaults.object(forKey: ProfileAppearanceStore.legacyDefaultNameKey))

        appState.selectDashboardTarget(primary.id)

        XCTAssertEqual(appState.defaultProfileName, "Atlas")
        XCTAssertEqual(Set(appState.profileAvatarURLs.keys), ["default", "coder"])
        // Loose legacy files were moved, so later loads cannot rediscover
        // them for another dashboard.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: avatarsRoot.appendingPathComponent(ProfileAppearanceStore.fileName(for: "default")).path
        ))
    }

    func testHiddenModelsAreRememberedPerDashboard() {
        let primary = dashboard("Primary", "https://mac.tailnet.ts.net")
        let review = dashboard("Review", "https://review.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: primary.id, dashboards: [primary, review]))
        appState.saveModelVisibility(ModelVisibility(hiddenProviders: ["openrouter"], hiddenModels: []))

        appState.selectDashboardTarget(review.id)
        XCTAssertEqual(appState.modelVisibility, ModelVisibility())

        appState.selectDashboardTarget(primary.id)
        XCTAssertEqual(appState.modelVisibility.hiddenProviders, ["openrouter"])
    }

    func testSwitchLandsOnTheTargetDashboardsOwnProfile() async {
        let primary = dashboard("Primary", "https://mac.tailnet.ts.net")
        let review = dashboard("Review", "https://review.example.com")
        defaults.set("work", forKey: "conduit.activeProfile")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: primary.id, dashboards: [primary, review]))
        appState.prepareChatResumeForConnection(to: primary.normalizedURL, dashboardID: primary.id)
        XCTAssertEqual(appState.activeProfile, "work")

        await appState.switchDashboard(to: review.id)

        // The review server was never used with "work": it starts on default.
        XCTAssertEqual(appState.activeDashboardID, review.id)
        XCTAssertEqual(appState.activeProfile, "default")
        XCTAssertEqual(defaults.string(forKey: "conduit.activeProfile"), "default")

        await appState.switchDashboard(to: primary.id)

        XCTAssertEqual(appState.activeProfile, "work")
    }

    func testRemovingADashboardDropsItsAppearance() throws {
        let primary = dashboard("Primary", "https://mac.tailnet.ts.net")
        let review = dashboard("Review", "https://review.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: review.id, dashboards: [primary, review]))
        appState.saveDefaultProfileName("Reviewer")
        try appState.saveProfileAvatarOnDevice(photoData(), for: "default")

        appState.removeDashboard(review.id)

        let store = makeAppearanceStore()
        XCTAssertEqual(store.loadDefaultName(dashboardID: review.id), ProfileAppearanceStore.defaultName)
        XCTAssertTrue(store.loadAvatarURLs(dashboardID: review.id).isEmpty)
    }

    // MARK: - Photos from Hermes

    func testMirroredPhotoKeepsHermesBytesAndIsScopedToItsDashboard() throws {
        let primary = UUID()
        let review = UUID()
        let store = makeAppearanceStore()
        let png = photoData()

        let saved = try store.saveMirroredAvatar(png, for: "coder", dashboardID: primary)
        let url = saved.url
        XCTAssertTrue(saved.changed)
        XCTAssertFalse(try store.saveMirroredAvatar(png, for: "coder", dashboardID: primary).changed, "the same bytes are not rewritten")

        XCTAssertEqual(try Data(contentsOf: url), png, "the Hermes bytes are kept as they are, transparency included")
        XCTAssertTrue(store.isMirrored("coder", dashboardID: primary))
        XCTAssertFalse(store.isMirrored("coder", dashboardID: review))
        XCTAssertEqual(store.loadAvatarURLs(dashboardID: primary)["coder"], url)
        XCTAssertThrowsError(try store.saveMirroredAvatar(Data("not an image".utf8), for: "coder", dashboardID: primary))
        XCTAssertEqual(try Data(contentsOf: url), png, "an unreadable answer leaves the copy alone")
    }

    func testDevicePhotoAndRemovalClearTheMirrorMark() throws {
        let primary = UUID()
        let store = makeAppearanceStore()
        _ = try store.saveMirroredAvatar(photoData(), for: "default", dashboardID: primary)

        _ = try store.saveAvatar(photoData(), for: "default", dashboardID: primary)
        XCTAssertFalse(store.isMirrored("default", dashboardID: primary), "a device pick is not a Hermes copy")
        XCTAssertNotNil(store.avatarData(for: "default", dashboardID: primary))

        _ = try store.saveMirroredAvatar(photoData(), for: "default", dashboardID: primary)
        store.removeAvatar(for: "default", dashboardID: primary)
        XCTAssertFalse(store.isMirrored("default", dashboardID: primary))
        XCTAssertNil(store.avatarData(for: "default", dashboardID: primary))

        _ = try store.saveMirroredAvatar(photoData(), for: "default", dashboardID: primary)
        store.removeAll(dashboardID: primary)
        XCTAssertFalse(store.isMirrored("default", dashboardID: primary))
    }

    func testRosterSyncFetchesUploadsOrDropsByWhereThePhotoCameFrom() {
        // Hermes has a picture: it wins, whatever is on the device.
        XCTAssertEqual(ProfileAvatarSyncAction.action(hermesHasAvatar: true, hasPhotoOnDevice: false, photoIsMirror: false), .fetch)
        XCTAssertEqual(ProfileAvatarSyncAction.action(hermesHasAvatar: true, hasPhotoOnDevice: true, photoIsMirror: false), .fetch)
        XCTAssertEqual(ProfileAvatarSyncAction.action(hermesHasAvatar: true, hasPhotoOnDevice: true, photoIsMirror: true), .fetch)
        // A photo picked here before photos moved to Hermes carries over.
        XCTAssertEqual(ProfileAvatarSyncAction.action(hermesHasAvatar: false, hasPhotoOnDevice: true, photoIsMirror: false), .upload)
        // A copy of a picture removed elsewhere goes.
        XCTAssertEqual(ProfileAvatarSyncAction.action(hermesHasAvatar: false, hasPhotoOnDevice: true, photoIsMirror: true), .dropMirror)
        XCTAssertEqual(ProfileAvatarSyncAction.action(hermesHasAvatar: false, hasPhotoOnDevice: false, photoIsMirror: false), .keep)
    }

    // MARK: - Avatar images

    private func photoData(_ color: UIColor, side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    private func averageColor(of image: UIImage) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage)
        // CoreGraphics owns the one-pixel buffer, so no pointer outlives its array.
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    func testAvatarImagesAreDownsampledAndFollowSavesAndRemoval() throws {
        let store = makeAppearanceStore()
        let dashboardID = UUID()
        let url = try store.saveAvatar(photoData(.red, side: 1_200), for: "default", dashboardID: dashboardID)

        let first = try XCTUnwrap(ProfileAvatarImageCache.image(at: url))
        let firstImage = try XCTUnwrap(first.cgImage)
        XCTAssertLessThanOrEqual(CGFloat(max(firstImage.width, firstImage.height)), ProfileAvatarImageCache.maxPixelSize)
        XCTAssertTrue(ProfileAvatarImageCache.image(at: url) === first, "a second read comes from the cache")
        XCTAssertGreaterThan(try averageColor(of: first).red, 0.8)

        // A new photo is written to the same file name.
        let replacedURL = try store.saveAvatar(photoData(.blue, side: 600), for: "default", dashboardID: dashboardID)
        XCTAssertEqual(replacedURL, url)
        let replaced = try XCTUnwrap(ProfileAvatarImageCache.image(at: url))
        XCTAssertGreaterThan(try averageColor(of: replaced).blue, 0.8)
        XCTAssertLessThan(try averageColor(of: replaced).red, 0.2)

        store.removeAvatar(for: "default", dashboardID: dashboardID)
        XCTAssertNil(ProfileAvatarImageCache.image(at: url))

        // A photo saved where a read had failed is read again.
        _ = try store.saveAvatar(photoData(.green, side: 300), for: "default", dashboardID: dashboardID)
        let restored = try XCTUnwrap(ProfileAvatarImageCache.image(at: url))
        XCTAssertGreaterThan(try averageColor(of: restored).green, 0.6)
    }
}

// MARK: - Finish setting up

extension AppStateMultiDashboardTests {
    func testANewDashboardOffersFinishSetupUntilItEnds() {
        let appState = makeAppState(registry: SavedDashboardRegistry())
        let id = track(appState.adoptDashboard(forNormalizedURL: "https://mac.tailnet.ts.net"))
        XCTAssertEqual(appState.dashboardsFinishingSetup, [id])
        // Only a connected dashboard shows the card.
        XCTAssertFalse(appState.showsFinishSetup)
        appState.isConnected = true
        XCTAssertTrue(appState.showsFinishSetup)

        appState.endFinishSetup()
        XCTAssertTrue(appState.dashboardsFinishingSetup.isEmpty)
        XCTAssertFalse(appState.showsFinishSetup)
        // Connecting again doesn't bring it back.
        _ = appState.adoptDashboard(forNormalizedURL: "https://mac.tailnet.ts.net")
        XCTAssertTrue(appState.dashboardsFinishingSetup.isEmpty)
    }

    func testDashboardsSavedBeforeAreNotOfferedFinishSetup() {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac]))
        _ = appState.adoptDashboard(forNormalizedURL: mac.normalizedURL)
        XCTAssertTrue(appState.dashboardsFinishingSetup.isEmpty)
    }

    func testRemovingADashboardForgetsItsFinishSetup() throws {
        let mac = dashboard("Mac", "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac]))
        let added = track(try XCTUnwrap(appState.resolveDashboardID(forURL: "https://hermes.example.com", registerIfMissing: true)))
        XCTAssertEqual(appState.dashboardsFinishingSetup, [added])

        appState.removeDashboard(added)
        XCTAssertTrue(appState.dashboardsFinishingSetup.isEmpty)
    }

    func testFinishSetupPluginStepFollowsTheHostsReport() {
        let current = NotifierPluginStatus.recommendedVersion
        let running = NotifierPluginStatus.Runtime(loadedVersion: current, restartNeeded: false, bootID: nil)
        let reported = NotifierPluginStatus.State.reported(version: current, capabilities: Set(NotifierPluginStatus.usedCapabilities))
        XCTAssertEqual(FinishSetupStatus.plugin(NotifierPluginStatus(state: .unknown), updating: false), .unknown)
        XCTAssertEqual(FinishSetupStatus.plugin(NotifierPluginStatus(state: .predatesCapabilities), updating: false), .install)
        XCTAssertEqual(FinishSetupStatus.plugin(NotifierPluginStatus(state: .predatesCapabilities), updating: true), .updating)
        var listedOld = NotifierPluginStatus(state: .predatesCapabilities)
        listedOld.hostCopy = .old
        XCTAssertEqual(FinishSetupStatus.plugin(listedOld, updating: false), .update)
        listedOld.hostCopy = .missing
        XCTAssertEqual(FinishSetupStatus.plugin(listedOld, updating: false), .install)
        listedOld.hostCopy = nil
        XCTAssertEqual(FinishSetupStatus.plugin(listedOld, updating: false), .install)
        // On the host but not running: no Install for a copy Hermes already has.
        listedOld.hostCopy = .notServed
        XCTAssertEqual(FinishSetupStatus.plugin(listedOld, updating: false), .notRunning)
        XCTAssertEqual(FinishSetupStatus.plugin(listedOld, updating: true), .updating)
        XCTAssertEqual(FinishSetupStatus.plugin(NotifierPluginStatus(state: reported, runtime: running), updating: false), .done)
        XCTAssertEqual(
            FinishSetupStatus.plugin(NotifierPluginStatus(
                state: .reported(version: "0.10.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
            ), updating: false),
            .update
        )
        var waiting = running
        waiting.restartNeeded = true
        XCTAssertEqual(FinishSetupStatus.plugin(NotifierPluginStatus(state: reported, runtime: waiting), updating: false), .restart)
    }

    func testFinishSetupNotificationsStepNeedsIOSPermissionToo() {
        XCTAssertEqual(FinishSetupStatus.notifications(enabled: false, authorization: .notDetermined), .off)
        XCTAssertEqual(FinishSetupStatus.notifications(enabled: true, authorization: .authorized), .done)
        XCTAssertEqual(FinishSetupStatus.notifications(enabled: true, authorization: .provisional), .done)
        // Registered but iOS not asked (a reinstall keeps the registration).
        XCTAssertEqual(FinishSetupStatus.notifications(enabled: true, authorization: .notDetermined), .off)
        XCTAssertEqual(FinishSetupStatus.notifications(enabled: true, authorization: .denied), .denied)
        XCTAssertEqual(FinishSetupStatus.notifications(enabled: false, authorization: .denied), .denied)

        XCTAssertTrue(FinishSetupStatus(plugin: .done, notifications: .done, voiceReady: true).isComplete)
        XCTAssertFalse(FinishSetupStatus(plugin: .unknown, notifications: .done, voiceReady: true).isComplete)
        XCTAssertFalse(FinishSetupStatus(plugin: .done, notifications: .off, voiceReady: true).isComplete)
        XCTAssertFalse(FinishSetupStatus(plugin: .done, notifications: .done, voiceReady: false).isComplete)
    }
}

// MARK: - Answers from the dashboard switched away from

extension AppStateMultiDashboardTests {

    private final class Finished {
        var value = false
    }

    /// Connected to Mac through a bridge whose requests the test answers;
    /// VPS is the dashboard switched to (authless, so nothing connects).
    private func heldSwitchFixture() -> (appState: AppState, held: HeldDashboardRequests, vps: SavedDashboard) {
        let mac = dashboard("Mac", "https://mac-\(UUID().uuidString.lowercased()).invalid")
        let vps = dashboard("VPS", "https://vps-\(UUID().uuidString.lowercased()).invalid")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps]))
        let held = HeldDashboardRequests(baseURL: mac.normalizedURL, dashboardID: mac.id)
        appState.installDashboardTicketBridgeForTesting(held.bridge)
        addTeardownBlock { @MainActor in held.releaseAll() }
        return (appState, held, vps)
    }

    private func macSession(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: nil,
            alternateIds: [],
            title: "On the Mac",
            model: "m",
            updatedLabel: "",
            profile: nil,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    /// A model save whose /api/model/set landed before a profile switch on
    /// the same dashboard still writes that profile's config: Hermes already
    /// uses the new model there, and the defaults must say so. The catalog
    /// and the model's info are read again after, so the copies kept for the
    /// Model page follow the save (#1533).
    func testAModelSaveLandedBeforeAProfileSwitchStillWritesItsProfileConfig() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let save = Task { await appState.setProfileMainModel(provider: "p", model: "m", reasoning: "low") }
        try await held.waitForRequests(1)       // /api/model/set
        appState.setActiveProfileForTesting("work")
        try await held.answer()                 // the model change landed
        try await held.waitForRequests(2)       // the captured profile's config read
        try await held.answer(["model": ["default": "old"]])
        try await held.waitForRequests(3)       // ... and its write
        try await held.answer()
        let saved = await save.value
        try await held.waitForRequests(4)       // the catalog
        try await held.answer()
        try await held.waitForRequests(5)       // the model's info
        try await held.answer()

        XCTAssertTrue(saved)
        XCTAssertEqual(held.sent.map(\.method), ["POST", "GET", "PUT", "GET", "GET"])
        XCTAssertEqual(held.sent.suffix(2).map(\.path), ["/api/model/options", "/api/model/info"])
        XCTAssertTrue(held.sent.allSatisfy { !$0.path.contains("work") }, "every request is the captured profile's")
        XCTAssertNil(appState.errorMessage)
    }

    func testAnArchiveAnsweredAfterASwitchChangesNothingOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let archive = Task { await appState.archiveSession(self.macSession("mac-1")) }
        try await held.answer()             // the mutation snapshot read
        try await held.waitForRequests(2)   // the archive itself

        await appState.switchDashboard(to: vps.id)
        try await held.answer()             // the Mac archived it, after the switch
        let archived = await archive.value

        XCTAssertFalse(archived)
        XCTAssertTrue(appState.archivedSessions.isEmpty, "the Mac's chat never lands in the VPS's Archived list")
        XCTAssertNil(appState.pinSyncNotice, "nothing about the Mac's chat is said over the VPS")
    }

    func testADeleteAnsweredAfterASwitchSaysNothingOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        let store = appState.offlineChatCacheForTesting
        store.record(
            dashboardID: mac,
            profile: appState.activeProfile,
            sessionID: "mac-1",
            title: "On the Mac",
            messages: [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")],
            sessions: [macSession("mac-1")]
        )
        let delete = Task { await appState.deleteSession(self.macSession("mac-1")) }
        try await held.answer()
        try await held.waitForRequests(2)

        await appState.switchDashboard(to: vps.id)
        try await held.answer()
        let deleted = await delete.value

        XCTAssertFalse(deleted, "the delete's result belongs to the Mac, not the dashboard now showing")
        XCTAssertNil(appState.pinSyncNotice)
        XCTAssertNil(store.loadTranscript("mac-1", dashboardID: mac, profile: "default"), "the Mac's saved copy of the deleted chat still goes (#1040)")
        XCTAssertNil(store.load(dashboardID: mac, profile: "default")?.lastSessionID)
    }

    func testArchivedConversationsAnsweredAfterASwitchAreNotShownOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let load = Task { await appState.loadArchivedSessions() }
        try await held.waitForRequests(1)

        await appState.switchDashboard(to: vps.id)
        try await held.answer(["sessions": [
            ["id": "mac-archived", "title": "On the Mac", "message_count": 3, "profile": "default"],
        ]])
        await load.value

        XCTAssertTrue(appState.archivedSessions.isEmpty)
        XCTAssertNil(appState.errorMessage)
    }

    /// Tool cards saved off is the kept choice at once, so the open chat and
    /// its offline copy draw without them before the config is read again.
    func testSavingToolCardsKeepsTheNewChoice() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let save = Task { await appState.setProfileSetting("display.tool_progress", value: .text("off")) }
        try await held.answer(["display": [String: Any]()])   // the config read
        try await held.answer()                                  // the write
        let saved = await save.value

        XCTAssertTrue(saved)
        XCTAssertFalse(appState.displayPreferences.showToolProgress)
    }

    /// A settings save queued behind one that outlives a switch is never
    /// sent to the dashboard switched to, which has its own profile of the
    /// same name.
    func testAQueuedProfileSettingsSaveNeverReachesTheDashboardSwitchedTo() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let first = Task { await appState.setProfileSetting("display.skin", value: .text("ares")) }
        try await held.waitForRequests(1)   // the first save's config read
        let secondFinished = Finished()
        let second = Task {
            let saved = await appState.setProfileSetting("display.compact", value: .bool(true))
            secondFinished.value = true
            return saved
        }
        for _ in 0..<5 { await Task.yield() }

        await appState.switchDashboard(to: vps.id)
        let vpsRequests = HeldDashboardRequests(baseURL: vps.normalizedURL, dashboardID: vps.id)
        appState.installDashboardTicketBridgeForTesting(vpsRequests.bridge)   // the VPS connects
        try await held.answer(["display": [String: Any]()])   // the Mac's read lands late
        _ = await first.value
        for _ in 0..<500 where !secondFinished.value && vpsRequests.sent.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(
            vpsRequests.sent.isEmpty,
            "the Mac's queued save was sent to the VPS: \(vpsRequests.sent.map(\.path))"
        )
        vpsRequests.releaseAll()
        let saved = await second.value
        XCTAssertFalse(saved)
    }

    /// The fallback saver is fenced like its sibling savers: a save that
    /// fails on the Mac after a switch says nothing over the VPS.
    func testAFallbackModelsSaveFailingAfterASwitchSaysNothingOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let save = Task {
            await appState.setProfileFallbackModels([ProfileFallbackModel(provider: "openrouter", model: "m")])
        }
        try await held.waitForRequests(1)   // the save's config read

        await appState.switchDashboard(to: vps.id)
        try await held.answer(["error": "boom"], status: 500)   // the Mac fails it, after the switch
        let saved = await save.value

        XCTAssertFalse(saved)
        XCTAssertNil(appState.errorMessage, "the Mac's failed save isn't reported over the VPS")
    }

    func testProfileSettingsFailingToLoadAfterASwitchSayNothingOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let load = Task { await appState.loadProfileSettings(keys: ["display.skin"]) }
        try await held.waitForRequests(1)

        await appState.switchDashboard(to: vps.id)
        try await held.answer(["error": "boom"], status: 500)
        let settings = await load.value

        XCTAssertTrue(settings.isEmpty)
        XCTAssertNil(appState.errorMessage, "the Mac's failed read isn't reported over the VPS")
    }

    func testFallbackModelsFailingToLoadAfterASwitchSayNothingOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let load = Task { await appState.loadProfileFallbackModels() }
        try await held.waitForRequests(1)

        await appState.switchDashboard(to: vps.id)
        try await held.answer(["error": "boom"], status: 500)
        let models = await load.value

        XCTAssertNil(models)
        XCTAssertNil(appState.errorMessage, "the Mac's failed read isn't reported over the VPS")
    }

    func testModelDefaultsFailingToLoadAfterASwitchSayNothingOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let load = Task { await appState.loadProfileModelDefaults() }
        try await held.waitForRequests(3)   // options, info and config, read together

        await appState.switchDashboard(to: vps.id)
        for _ in 0..<3 {
            try await held.answer(["error": "boom"], status: 500)
        }
        let modelDefaults = await load.value

        XCTAssertNil(modelDefaults)
        XCTAssertNil(appState.errorMessage, "the Mac's failed read isn't reported over the VPS")
    }

    /// A switch invalidates the Mac's bridge, so its listing in flight
    /// fails; that failure isn't reported over the VPS's folder.
    func testAWorkspaceListingFailingAfterASwitchSaysNothingOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let explorer = WorkspaceExplorer()
        explorer.attach(appState)
        let open = Task { await explorer.open(root: "/w/mac", profile: appState.activeProfile) }
        try await held.waitForRequests(1)

        await appState.switchDashboard(to: vps.id)
        try await held.answer(["error": "boom"], status: 500)
        await open.value

        XCTAssertNil(explorer.error, "the Mac's failed listing isn't reported over the VPS")
        XCTAssertTrue(explorer.entries.isEmpty, "nor its listing")
    }

    func testADisplayPreferenceSaveFailingAfterASwitchSaysNothingOnTheNewDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let save = Task { await appState.setDisplayPreference(.expandTools, enabled: true) }
        try await held.waitForRequests(1)   // the save's config read

        await appState.switchDashboard(to: vps.id)
        try await held.answer(["error": "boom"], status: 500)
        let saved = await save.value

        XCTAssertFalse(saved)
        XCTAssertNil(appState.errorMessage, "the Mac's failed save isn't reported over the VPS")
    }

    func testAVoiceCallTranscriptOpenOnTheOldDashboardIsClosedBySwitching() async {
        let (appState, _, vps) = heldSwitchFixture()
        appState.chatCallTranscript = VoiceChatCall(callID: "mac-call", turns: [])

        await appState.switchDashboard(to: vps.id)

        XCTAssertNil(appState.chatCallTranscript, "the Mac's call transcript doesn't stay up over the VPS")
    }

    /// Picking another file while one loads: only the latest pick's answer
    /// (or failure) shows, and it is the one that ends the loading state.
    func testOnlyTheLatestWorkspaceFilePickShows() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let explorer = WorkspaceExplorer()
        explorer.attach(appState)
        func file(_ name: String) -> WorkspaceEntry {
            WorkspaceEntry(name: name, path: "/w/\(name)", isDirectory: false)
        }
        let first = Task { await explorer.view(file("a.txt")) }
        try await held.waitForRequests(1)
        let second = Task { await explorer.view(file("b.txt")) }
        try await held.waitForRequests(2)

        try await held.answer(["text": "a's text"])
        await first.value
        XCTAssertNil(explorer.preview, "a.txt's text never shows under b.txt")
        XCTAssertTrue(explorer.previewLoading, "b.txt is still loading")

        try await held.answer(["text": "b's text"])
        await second.value
        XCTAssertEqual(explorer.viewed?.path, "/w/b.txt")
        XCTAssertEqual(explorer.preview?.text, "b's text")
        XCTAssertFalse(explorer.previewLoading)

        let third = Task { await explorer.view(file("c.txt")) }
        try await held.waitForRequests(3)
        let fourth = Task { await explorer.view(file("d.txt")) }
        try await held.waitForRequests(4)
        try await held.answer(["error": "gone"], status: 500)
        await third.value
        XCTAssertNil(explorer.previewError, "c.txt's failure isn't shown for d.txt")
        try await held.answer(["text": "d's text"])
        await fourth.value
        XCTAssertEqual(explorer.preview?.text, "d's text")
    }
}

// MARK: - Voice-call history stays with its dashboard

extension AppStateMultiDashboardTests {

    /// Switching selects the next dashboard before it closes the live
    /// call, so the closing save must not take the selection's id.
    func testACallLiveDuringASwitchIsKeptForTheDashboardItWasOn() async throws {
        let (appState, _, vps) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID).uuidString
        defaults.set(mac, forKey: AppState.chatResumeServerIdentityKey)
        appState.beginVoiceCallRecordingForTesting(engine: .geminiLive, turns: [
            VoiceConversationTranscriptEntry(speaker: .user, text: "Add milk to the list"),
            VoiceConversationTranscriptEntry(speaker: .assistant, text: "Added."),
        ])

        await appState.switchDashboard(to: vps.id)
        XCTAssertEqual(VoiceTranscriptOutbox.load(from: defaults).entries.map(\.dashboard), [mac])

        // The closing save can't reach the Mac now; what it puts back is
        // still the Mac's, never sent to the VPS when it connects.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(VoiceTranscriptOutbox.load(from: defaults).entries.map(\.dashboard), [mac])
    }

    /// A checkpoint with nothing new since the last writes nothing, so a
    /// quiet call doesn't rewrite the outbox every 15 seconds (#1002).
    func testAQuietCallCheckpointLeavesTheOutboxAlone() throws {
        let (appState, _, _) = heldSwitchFixture()
        appState.beginVoiceCallRecordingForTesting(engine: .geminiLive, turns: [
            VoiceConversationTranscriptEntry(speaker: .user, text: "Add milk to the list"),
        ])
        appState.checkpointVoiceCallForTesting()
        XCTAssertEqual(VoiceTranscriptOutbox.load(from: defaults).entries.first?.request.turns.count, 1)

        defaults.removeObject(forKey: VoiceTranscriptOutbox.storageKey)
        appState.checkpointVoiceCallForTesting()
        XCTAssertNil(defaults.data(forKey: VoiceTranscriptOutbox.storageKey), "Nothing new, nothing written")

        appState.checkpointVoiceCallForTesting(adding: [VoiceConversationTranscriptEntry(speaker: .assistant, text: "Added.")])
        XCTAssertEqual(VoiceTranscriptOutbox.load(from: defaults).entries.first?.request.turns.count, 2, "A new turn is written")
    }

    /// A call's jobs are tagged one request at a time; a switch while one
    /// is in flight stops the rest instead of sending them to the next
    /// dashboard's profile of the same name.
    func testQueuedVoiceTagsAreNeverSentToTheDashboardSwitchedTo() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID).uuidString
        var outbox = VoiceTranscriptOutbox()
        outbox.add(.init(
            dashboard: mac, profile: appState.activeProfile,
            request: VoiceTranscriptSaveRequest(
                callID: "c1", engine: .gptLive, sessionID: nil, title: "Call",
                turns: [VoiceTranscriptTurn(index: 0, role: .user, text: "Start two jobs", at: Date())]
            ),
            queuedAt: Date(),
            jobSessionIDs: ["job-1", "job-2"]
        ))
        outbox.store(in: defaults)

        let save = Task { await appState.saveQueuedVoiceCallsNow() }
        try await held.answer(["ok": true, "session_id": "row-1", "written": 1])   // the call saves on the Mac
        await save.value
        try await held.waitForRequests(2)   // the first job's tag

        await appState.switchDashboard(to: vps.id)
        let vpsRequests = HeldDashboardRequests(baseURL: vps.normalizedURL, dashboardID: vps.id)
        appState.installDashboardTicketBridgeForTesting(vpsRequests.bridge)   // the VPS connects
        addTeardownBlock { @MainActor in vpsRequests.releaseAll() }
        try await held.answer()   // the Mac's answer lands after the switch
        for _ in 0..<100 where vpsRequests.sent.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(vpsRequests.sent.isEmpty, "the Mac's tags were sent to the VPS: \(vpsRequests.sent.map(\.path))")
    }

    /// A reconnect to the same dashboard (a new bridge) isn't a switch: the
    /// rest of the call's job tags still go, since tags aren't retried.
    func testQueuedVoiceTagsGoOnAfterAReconnectToTheSameDashboard() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        var outbox = VoiceTranscriptOutbox()
        outbox.add(.init(
            dashboard: mac.uuidString, profile: appState.activeProfile,
            request: VoiceTranscriptSaveRequest(
                callID: "c1", engine: .gptLive, sessionID: nil, title: "Call",
                turns: [VoiceTranscriptTurn(index: 0, role: .user, text: "Start two jobs", at: Date())]
            ),
            queuedAt: Date(),
            jobSessionIDs: ["job-1", "job-2"]
        ))
        outbox.store(in: defaults)

        let save = Task { await appState.saveQueuedVoiceCallsNow() }
        try await held.answer(["ok": true, "session_id": "row-1", "written": 1])
        await save.value
        try await held.waitForRequests(2)   // the first job's tag

        let reconnected = HeldDashboardRequests(baseURL: held.bridge.baseURL, dashboardID: mac)
        appState.installDashboardTicketBridgeForTesting(reconnected.bridge)   // the Mac reconnects
        addTeardownBlock { @MainActor in reconnected.releaseAll() }
        try await held.answer()   // the first tag's answer lands after it
        try await reconnected.waitForRequests(1)

        XCTAssertEqual(reconnected.sent.map(\.path), ["/api/plugins/conduit_push/voice/tags"], "the second job's tag still goes to the Mac")
    }

    /// A switch that lands right after the closing save: the jobs' tags and
    /// the chat link can't go to the Mac now, so the call stays queued for
    /// it, and the Mac's next save run files them.
    func testACallSavedJustBeforeASwitchStillFilesItsJobsLater() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        appState.beginVoiceCallRecordingForTesting(engine: .geminiLive, turns: [
            VoiceConversationTranscriptEntry(speaker: .user, text: "Look into the logs"),
            VoiceConversationTranscriptEntry(speaker: .assistant, text: "On it."),
        ], jobs: ["job-1"])

        appState.closeGeminiLiveConversation()
        try await held.waitForRequests(1)   // the closing save
        appState.selectDashboardTarget(vps.id)   // the switch lands before the save's answer is applied
        try await held.answer(["ok": true, "session_id": "row-1", "written": 2])
        func queued() -> [VoiceTranscriptOutbox.Entry] {
            VoiceTranscriptOutbox.load(from: defaults).entries.filter { $0.request.sessionID == "row-1" }
        }
        for _ in 0..<100 where queued().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queued().map(\.dashboard), [mac.uuidString], "kept for the Mac")
        XCTAssertEqual(queued().first?.jobSessionIDs, ["job-1"])
        XCTAssertEqual(held.sent.count, 1, "nothing more went out after the switch")

        // Back on the Mac: the save is a replay the host skips, then the job is filed.
        appState.selectDashboardTarget(mac)
        let save = Task { await appState.saveQueuedVoiceCallsNow() }
        try await held.waitForRequests(2)
        try await held.answer(["ok": true, "session_id": "row-1", "written": 2])
        await save.value
        try await held.waitForRequests(3)
        XCTAssertEqual(held.sent.map(\.path).last, "/api/plugins/conduit_push/voice/tags")
        XCTAssertTrue(VoiceTranscriptOutbox.load(from: defaults).entries.isEmpty)
    }
}

// MARK: - Kept settings answers (#1533)

extension AppStateMultiDashboardTests {
    /// A settings page's read is kept for the dashboard and profile that
    /// answered, so the page opens on it next time; another profile's or
    /// dashboard's pages don't.
    func testSettingsAnswersAreKeptForTheDashboardAndProfileThatAnswered() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        XCTAssertNil(appState.keptProfileSettings(keys: ["display.skin"]), "Nothing kept yet")
        let load = Task { await appState.loadProfileSettings(keys: ["display.skin"]) }
        try await held.waitForRequests(1)
        try await held.answer(["display": ["skin": "ares"]])
        let settings = await load.value

        XCTAssertEqual(settings["display.skin"], .text("ares"))
        XCTAssertEqual(appState.keptProfileSettings(keys: ["display.skin"])?["display.skin"], .text("ares"))
        appState.setActiveProfileForTesting("work")
        XCTAssertNil(appState.keptProfileSettings(keys: ["display.skin"]), "Another profile's pages")
        appState.setActiveProfileForTesting("default")
        await appState.switchDashboard(to: vps.id)
        XCTAssertNil(appState.keptProfileSettings(keys: ["display.skin"]), "Another dashboard's pages")
    }

    /// A read that lands after a switch is kept for neither dashboard.
    func testASettingsReadLandingAfterASwitchIsNotKept() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        let load = Task { await appState.loadProfileSettings(keys: ["display.skin"]) }
        try await held.waitForRequests(1)

        await appState.switchDashboard(to: vps.id)
        try await held.answer(["display": ["skin": "ares"]])
        _ = await load.value

        let store = appState.offlineChatCacheForTesting
        XCTAssertNil(store.keptAnswer(AppState.KeptRoute.config, dashboardID: mac, profile: "default"))
        XCTAssertNil(appState.keptProfileSettings(keys: ["display.skin"]))
    }

    /// Delete Saved Chats takes the settings pages' kept answers, and a
    /// read it overtook keeps nothing: the page shows Hermes' answer, and
    /// nothing comes back on the phone.
    func testDeleteSavedChatsTakesTheKeptSettingsAnswers() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let first = Task { await appState.loadProfileSettings(keys: ["display.skin"]) }
        try await held.waitForRequests(1)
        try await held.answer(["display": ["skin": "ares"]])
        _ = await first.value
        XCTAssertNotNil(appState.keptProfileSettings(keys: ["display.skin"]))

        appState.deleteSavedChats()
        XCTAssertNil(appState.keptProfileSettings(keys: ["display.skin"]), "Deleted with the saved chats")

        let second = Task { await appState.loadProfileSettings(keys: ["display.skin"]) }
        try await held.waitForRequests(2)
        appState.deleteSavedChats()
        try await held.answer(["display": ["skin": "slate"]])
        let settings = await second.value
        XCTAssertEqual(settings["display.skin"], .text("slate"), "The page shows Hermes' answer")
        XCTAssertNil(appState.keptProfileSettings(keys: ["display.skin"]), "but a read the delete overtook keeps nothing")
    }

    /// Delegation's pause holds every profile on a Hermes, so every
    /// profile's page opens on the value any of them last read; another
    /// dashboard's doesn't.
    func testDelegationsKeptPauseIsTheDashboards() async throws {
        let (appState, _, vps) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        appState.offlineChatCacheForTesting.recordAnswer(
            ["paused": true],
            route: AppState.KeptRoute.delegationStatus,
            dashboardID: mac,
            profile: AppState.KeptRoute.everyProfile
        )

        XCTAssertEqual(appState.keptDelegationPaused(), true)
        appState.setActiveProfileForTesting("work")
        XCTAssertEqual(appState.keptDelegationPaused(), true, "Another profile's page opens on it")
        await appState.switchDashboard(to: vps.id)
        XCTAssertNil(appState.keptDelegationPaused(), "Another dashboard's page doesn't")
    }

    /// A config save is what the settings pages open on next, without
    /// another read.
    func testAConfigSaveIsWhatTheSettingsPagesOpenOnNext() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let save = Task { await appState.setProfileSetting("display.skin", value: .text("slate")) }
        try await held.waitForRequests(1)       // the config read
        try await held.answer(["display": ["skin": "ares"], "agent": ["max_turns": 90]])
        try await held.waitForRequests(2)       // ... and its write
        try await held.answer()
        let saved = await save.value

        XCTAssertTrue(saved)
        let kept = try XCTUnwrap(appState.keptProfileSettings(keys: ["display.skin", "agent.max_turns"]))
        XCTAssertEqual(kept["display.skin"], .text("slate"))
        XCTAssertEqual(kept["agent.max_turns"], .number(90))
    }

    /// A read asked before the phone wrote what it answers with, a forget
    /// or a save, never puts its older answer back over the write; one
    /// asked after it does replace it.
    func testAReadAskedBeforeAWriteNeverPutsItsAnswerBack() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let client = appState.pulseClient
        let items: [String: Any] = ["items": [
            ["id": 1, "text": "Call Ann", "kind": "commitment"], ["id": 2, "text": "Book the flights", "kind": "commitment"],
        ]]
        let first = Task { try await client.memory() }
        try await held.waitForRequests(1)
        try await held.answer(items)
        _ = try await first.value

        let older = Task { try await client.memory() }
        try await held.waitForRequests(2)
        await appState.forgetKeptPulseMemoryItem(id: 1)
        try await held.answer(items)
        _ = try await older.value
        XCTAssertEqual(appState.keptPulseMemory()?.map(\.text), ["Book the flights"], "Asked before the forget")

        // A settings page's read, asked before a save, answers after it.
        let load = Task { await appState.loadProfileSettings(keys: ["display.skin"]) }
        try await held.waitForRequests(3)
        let save = Task { await appState.setProfileSetting("display.skin", value: .text("slate")) }
        try await held.waitForRequests(4)       // the save's config read
        try await held.answer(["display": ["skin": "ares"]], at: 1)
        try await held.waitForRequests(5)       // ... and its write
        try await held.answer(at: 1)
        let saved = await save.value
        XCTAssertTrue(saved)
        try await held.answer(["display": ["skin": "ares"]])
        let shown = await load.value
        XCTAssertEqual(shown["display.skin"], .text("ares"), "The page shows its read's answer")
        XCTAssertEqual(appState.keptProfileSettings(keys: ["display.skin"])?["display.skin"], .text("slate"), "but the save stays kept")

        let after = Task { await appState.loadProfileSettings(keys: ["display.skin"]) }
        try await held.waitForRequests(6)
        try await held.answer(["display": ["skin": "mono"]])
        _ = await after.value
        XCTAssertEqual(appState.keptProfileSettings(keys: ["display.skin"])?["display.skin"], .text("mono"), "Asked after the save")
    }

    /// A write that leaves nothing to keep, a forget with no list kept or a
    /// memory provider's save with no config kept, still outranks a read
    /// asked before it: that read's answer isn't kept after it.
    func testAWriteWithNothingKeptStillOutranksAnOlderRead() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let older = Task { try await appState.pulseClient.memory() }
        try await held.waitForRequests(1)
        await appState.forgetKeptPulseMemoryItem(id: 1)
        try await held.answer(["items": [["id": 1, "text": "Call Ann", "kind": "commitment"]]])
        _ = try await older.value
        XCTAssertNil(appState.keptPulseMemory(), "Asked before the forget")

        let load = Task { await appState.loadProfileSettings(keys: ["memory.provider"]) }
        try await held.waitForRequests(2)
        let save = Task { await appState.setProfileSetting("memory.provider", value: .text("honcho")) }
        try await held.waitForRequests(3)       // the plugin providers' write
        try await held.answer(at: 1)
        let saved = await save.value
        XCTAssertTrue(saved)
        try await held.answer(["memory": ["provider": "builtin"]])
        _ = await load.value
        XCTAssertNil(appState.keptProfileSettings(keys: ["memory.provider"]), "Asked before the save")
    }

    /// A Voice replies model save outranks a read of the slots asked
    /// before it, which keeps nothing when it answers after the save; the
    /// read the save asks for keeps the slot saved.
    func testAVoiceReplyModelSaveOutranksAnOlderRead() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let fast = VoiceReplyModelSetting(provider: "openrouter", model: "fast/model", reasoningEffort: "none")
        let older = Task { try await appState.loadVoiceReplyModel() }
        try await held.waitForRequests(1)
        let save = Task { await appState.setVoiceReplyModel(fast) }
        try await held.waitForRequests(2)       // the save
        try await held.answer(at: 1)
        let refusal = await save.value
        XCTAssertNil(refusal)
        try await held.waitForRequests(3)       // the read it asks for
        try await held.answer(["tasks": [["task": "voice_chat", "provider": "auto", "model": ""]]])
        _ = try await older.value
        XCTAssertNil(appState.keptVoiceReplyModel(), "Asked before the save")

        try await held.answer(["tasks": [["task": "voice_chat", "provider": "openrouter", "model": "fast/model", "reasoning_effort": "none"]]])
        for _ in 0..<1_000 where appState.keptVoiceReplyModel() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(appState.keptVoiceReplyModel(), fast, "Asked after it")
    }

    /// Pulse is one per host: its state is kept once per dashboard, from a
    /// read or a change that answers with it (a notification's Quiet for
    /// today too), and What Pulse remembers' list beside it, without what
    /// Pulse forgot; an estimate isn't a state. Settings > Pulse opens on them in any profile, and
    /// another dashboard's opens on nothing.
    func testPulsesStateAndMemoryAreKeptOncePerDashboard() async throws {
        let (appState, held, vps) = heldSwitchFixture()
        let client = appState.pulseClient
        XCTAssertNil(appState.keptPulseState(), "Nothing kept yet")

        let read = Task { try await client.state() }
        try await held.waitForRequests(1)
        try await held.answer(["enabled": true, "memory": true, "memory_tokens": 1200])
        _ = try await read.value
        XCTAssertEqual(appState.keptPulseState()?.enabled, true)
        XCTAssertEqual(appState.keptPulseState()?.memoryTokens, 1200, "A count of tokens is no credential")

        let change = Task { try await client.update(["enabled": false]) }
        try await held.waitForRequests(2)
        try await held.answer(["enabled": false])
        _ = try await change.value
        XCTAssertEqual(appState.keptPulseState()?.enabled, false, "A change answers with the state it made")

        let estimate = Task { try? await client.estimate(days: 30) }
        try await held.waitForRequests(3)
        try await held.answer(["estimate": ["days": 30, "chats": 4, "tokens": 900, "days_needed": 1]])
        _ = await estimate.value
        XCTAssertEqual(appState.keptPulseState()?.enabled, false, "An estimate isn't a state")

        let memory = Task { try await client.memory() }
        try await held.waitForRequests(4)
        try await held.answer(["items": [
            ["id": 1, "text": "Call Ann", "kind": "commitment"], ["id": 2, "text": "Book the flights", "kind": "commitment"],
        ]])
        _ = try await memory.value
        XCTAssertEqual(appState.keptPulseMemory()?.map(\.text), ["Call Ann", "Book the flights"])
        await appState.forgetKeptPulseMemoryItem(id: 1)
        XCTAssertEqual(appState.keptPulseMemory()?.map(\.text), ["Book the flights"], "A forgotten item leaves the kept list")

        // Quiet for today from a Pulse notification is kept as the page's own steps are.
        let here = PulseQuietTarget(dashboardID: appState.activeDashboardID?.uuidString, gatewayID: nil)
        let quiet = Task { await appState.quietPulseForToday(here, switching: false, wait: .zero) }
        try await held.waitForRequests(5)
        try await held.answer(["enabled": false, "quiet_until": 1800000000])
        let quieted = await quiet.value
        XCTAssertTrue(quieted)
        XCTAssertEqual(appState.keptPulseState()?.quietUntil, Date(timeIntervalSince1970: 1800000000))

        appState.setActiveProfileForTesting("work")
        XCTAssertEqual(appState.keptPulseState()?.enabled, false, "Another profile's page opens on it")
        await appState.switchDashboard(to: vps.id)
        XCTAssertNil(appState.keptPulseState(), "Another dashboard's page doesn't")
        XCTAssertNil(appState.keptPulseMemory())
    }

    /// Voice settings keep Hermes' config and speech toolsets for the
    /// dashboard and profile that answered, and Local's fast model without
    /// the speech server's key, never `/api/env`, and open on them next
    /// time, as the agent pages open on the same config; another profile's
    /// or dashboard's page opens on nothing.
    func testVoiceSettingsOpenOnTheirKeptAnswers() async throws {
        let (appState, _, vps) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true], "tts": ["provider": "edge"]],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": [["name": "Microsoft Edge TTS", "tts_provider": "edge", "status": "ready", "is_active": true]]],
            "/api/env": ["ELEVENLABS_API_KEY": ["is_set": true, "redacted_value": "sk_...wxyz"]],
            SpeechServerSpeechStream.statusPath: [
                "available": true, "model_path": "/api/plugins/conduit_push/local-live/v1", "api_key": "sk-local-1",
                "front_model": ["configured": true, "available": true, "base_url": "http://box:8080/v1", "model": "qwen3-4b"],
            ],
        ]
        let page = HermesVoiceConfigurationService(requester: requester, profile: "default", answers: appState.voiceSettingsAnswers(profile: "default"))
        XCTAssertFalse(page.snapshot.capability.isGatewayConnected, "Nothing kept yet")
        await page.reload()
        _ = await page.speechServerVoiceStatus()

        let next = HermesVoiceConfigurationService(requester: requester, profile: "default", answers: appState.voiceSettingsAnswers(profile: "default"))
        XCTAssertTrue(next.snapshot.capability.supportsSpeech, "Opens on what Hermes said")
        XCTAssertFalse(next.snapshot.environmentLoaded)
        XCTAssertNil(appState.offlineChatCacheForTesting.keptAnswer("/api/env", dashboardID: mac, profile: "default"), "Never kept")
        XCTAssertEqual(appState.keptProfileSettings(keys: ["tts.provider"])?["tts.provider"], .text("edge"), "The agent pages' config")
        XCTAssertEqual(next.lastFrontModel?.model, "qwen3-4b")
        let keptVoice = appState.offlineChatCacheForTesting.keptAnswer(SpeechServerSpeechStream.statusPath, dashboardID: mac, profile: "default")
        XCTAssertNotNil(keptVoice)
        XCTAssertNil(keptVoice?["api_key"], "The speech server's key isn't kept")
        let work = HermesVoiceConfigurationService(requester: requester, profile: "work", answers: appState.voiceSettingsAnswers(profile: "work"))
        XCTAssertFalse(work.snapshot.capability.isGatewayConnected, "Another profile's page")
        await appState.switchDashboard(to: vps.id)
        let vpsPage = HermesVoiceConfigurationService(requester: requester, profile: "default", answers: appState.voiceSettingsAnswers(profile: "default"))
        XCTAssertFalse(vpsPage.snapshot.capability.isGatewayConnected, "Another dashboard's page")
    }

    /// Voice settings' voice reply model opens on the slot Hermes gave
    /// last, and the Voice and Pulse model pickers on the models Usage's
    /// read keeps too; a read that fails keeps the slot, and an answer
    /// without it says this Hermes has none (#1533).
    func testTheVoiceModelSectionsOpenOnTheirKeptAnswers() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        XCTAssertNil(appState.keptVoiceReplyModel(), "Nothing kept yet")
        let setting = VoiceReplyModelSetting(provider: "openrouter", model: "fast/model", reasoningEffort: "none")

        let load = Task { try await appState.loadVoiceReplyModel() }
        try await held.waitForRequests(1)
        try await held.answer(["tasks": [["task": "voice_chat", "provider": "openrouter", "model": "fast/model", "reasoning_effort": "none"]]])
        let answered = try await load.value
        XCTAssertEqual(answered, setting)
        XCTAssertEqual(appState.keptVoiceReplyModel(), setting)

        let failing = Task { try await appState.loadVoiceReplyModel() }
        try await held.waitForRequests(2)
        try await held.answer(["error": "boom"], status: 500)
        do {
            _ = try await failing.value
            XCTFail("A read Hermes didn't answer throws")
        } catch {}
        XCTAssertEqual(appState.keptVoiceReplyModel(), setting, "A read that fails keeps it")

        let withoutSlot = Task { try await appState.loadVoiceReplyModel() }
        try await held.waitForRequests(3)
        try await held.answer(["tasks": [["task": "vision"]]])
        let none = try await withoutSlot.value
        XCTAssertNil(none)
        XCTAssertNil(appState.keptVoiceReplyModel(), "This Hermes has no voice reply slot")
        XCTAssertEqual(held.sent.map(\.path), Array(repeating: AppState.KeptRoute.modelAuxiliary, count: 3))

        appState.offlineChatCacheForTesting.recordAnswer(
            ["providers": [["slug": "openrouter", "name": "OpenRouter", "models": [["id": "fast/model"]]]]],
            route: AppState.KeptRoute.providerQuotas, dashboardID: mac, profile: "default"
        )
        XCTAssertEqual(appState.keptModelProviders().map(\.name), ["openrouter"])
        XCTAssertEqual(appState.keptModelProviders().first?.models.map(\.id), ["fast/model"])
        appState.setActiveProfileForTesting("work")
        XCTAssertTrue(appState.keptModelProviders().isEmpty, "Another profile's models")
    }

    /// A live voice mode's status line on Voice settings opens on what its
    /// last check said, GPT-Live's per billing (the one its check asked
    /// about), for the dashboard and profile that checked; a check from a
    /// dashboard left keeps nothing.
    func testTheLiveVoiceStatusLinesOpenOnTheirLastCheck() async throws {
        let (appState, _, vps) = heldSwitchFixture()
        let grok = LiveVoiceStatusLine(text: "Available (grok-4, via SuperGrok)", isAvailable: true)
        XCTAssertNil(appState.keptLiveVoiceStatus(.grokLive), "Nothing kept yet")
        appState.liveVoiceStatusKeeper(.grokLive)(grok)
        XCTAssertEqual(appState.keptLiveVoiceStatus(.grokLive), grok)
        XCTAssertNil(appState.keptLiveVoiceStatus(.geminiLive), "Another mode's")

        // The billing switched to API while a subscription check was out.
        let keepGPT = appState.gptLiveStatusKeeper()
        appState.setGPTLiveBilling(.api)
        keepGPT(LiveVoiceStatusLine(text: "Available (gpt-realtime)", isAvailable: true), .subscription)
        XCTAssertNil(appState.keptLiveVoiceStatus(.gptLive), "The other billing's")
        appState.setGPTLiveBilling(.subscription)
        XCTAssertEqual(appState.keptLiveVoiceStatus(.gptLive)?.text, "Available (gpt-realtime)")

        appState.setActiveProfileForTesting("work")
        XCTAssertNil(appState.keptLiveVoiceStatus(.grokLive), "Another profile's")
        appState.setActiveProfileForTesting("default")
        let left = appState.liveVoiceStatusKeeper(.grokLive)
        await appState.switchDashboard(to: vps.id)
        left(LiveVoiceStatusLine(text: "Grok Live isn't set up", isAvailable: false))
        XCTAssertNil(appState.keptLiveVoiceStatus(.grokLive), "Another dashboard's page")
    }

    /// A models read that fails keeps no split beside the period's new
    /// numbers: Usage opens on the usage route's own rows, as it showed
    /// them, never on an older split and its cost.
    func testAUsageLoadWhoseModelsReadFailsKeepsNoOlderSplit() async throws {
        let (appState, held, _) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        let modelsRoute = UsageReport.route(UsageReport.modelsPath, days: 30)
        appState.offlineChatCacheForTesting.recordAnswer(
            ["models": [["model": "old-model", "input_tokens": 5]]], route: modelsRoute, dashboardID: mac, profile: "default"
        )
        appState.isConnected = true

        let load = Task { try await appState.loadUsageReport(days: 30) }
        try await held.waitForRequests(1)
        try await held.answer(["totals": ["total_input": 1200], "by_model": [["model": "new-model", "input_tokens": 1200]], "period_days": 30])
        try await held.waitForRequests(2)
        try await held.answer(["error": "boom"], status: 500)
        let report = try await load.value

        XCTAssertEqual(held.sent.map(\.path), [UsageReport.usagePath, UsageReport.modelsPath])
        XCTAssertEqual(report.models.map(\.model), ["new-model"])
        XCTAssertEqual(appState.keptUsageReport(days: 30)?.models.map(\.model), ["new-model"], "Opens on what it showed")
    }

    /// Usage opens on each period's numbers as the active profile last read
    /// them, and the quota beside them; another period or profile opens on
    /// its own, or on nothing.
    func testUsageOpensOnThePeriodsKeptNumbers() throws {
        let (appState, _, _) = heldSwitchFixture()
        let mac = try XCTUnwrap(appState.activeDashboardID)
        let store = appState.offlineChatCacheForTesting
        store.recordAnswer(
            [
                "totals": ["total_input": 1200, "total_output": 300, "total_sessions": 2],
                "daily": [["day": "2026-10-30", "input_tokens": 1000, "output_tokens": 200]],
                "period_days": 30,
            ],
            route: UsageReport.route(UsageReport.usagePath, days: 30), dashboardID: mac, profile: "default"
        )
        store.recordAnswer(
            ["providers": [["slug": "openai", "name": "OpenAI", "usage": ["windows": [["label": "5h", "used_percent": 40]]]]]],
            route: AppState.KeptRoute.providerQuotas, dashboardID: mac, profile: "default"
        )

        let report = try XCTUnwrap(appState.keptUsageReport(days: 30))
        XCTAssertEqual(report.totals.input, 1200)
        XCTAssertEqual(report.daily.first?.usage.input, 1000, "A day's token counts are numbers, kept")
        XCTAssertNil(appState.keptUsageReport(days: 7), "Another period")
        XCTAssertEqual(appState.keptProviderQuotas()?.map(\.slug), ["openai"])
        appState.setActiveProfileForTesting("work")
        XCTAssertNil(appState.keptUsageReport(days: 30), "Another profile")
        XCTAssertNil(appState.keptProviderQuotas())
    }
}
