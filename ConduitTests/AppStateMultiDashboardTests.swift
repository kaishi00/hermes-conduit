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
