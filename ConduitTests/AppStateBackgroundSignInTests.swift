import XCTest
import Security
@testable import Conduit

/// A sign-in that came up while Conduit was off the phone screen (a call
/// from Hermes or the Apple Watch launched it, or only CarPlay shows it)
/// runs the saved sign-in again once Conduit is on screen, instead of
/// leaving the user signed out.
/// An extension of an existing class, so the CI test plan gains no class.
extension AppStateForegroundLifecycleTests {
    func testSignInRaisedInBackgroundRetriesSavedSignInOnScreen() async throws {
        let (appState, _) = installFaceIDDashboard(savedTicket: nil)
        var inBackground = true
        appState.phoneScreenIsAway = { inBackground }
        var unlockAsked = false
        appState.unlockWithFaceID = {
            unlockAsked = true
            return false
        }

        appState.showLogin = true
        XCTAssertTrue(appState.signInWaitsForForeground)
        appState.pendingLoginFailure = .notice(title: "Sign-in didn’t complete", message: "background")

        inBackground = false
        appState.handleScenePhase(.background)
        appState.handleScenePhase(.active)

        // The retry ran: the background attempt's failure is gone, and the
        // saved password's restore started.
        XCTAssertNil(appState.pendingLoginFailure)
        XCTAssertFalse(appState.signInWaitsForForeground)
        try await waitUntil { unlockAsked }
    }

    /// Off screen, a switch to a dashboard with nothing saved shows sign-in
    /// too: on screen there is nothing to retry, and its explanation stays.
    func testNothingSavedOnScreenKeepsTheSignInExplanation() {
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let appState = makeSignedOutAppState(
            registry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        )
        var away = true
        appState.phoneScreenIsAway = { away }
        let failure = ConnectionFailurePresentation.notice(title: "Sign-in didn’t complete", message: "switched")
        appState.showLogin = true
        appState.pendingLoginFailure = failure

        away = false
        appState.handleScenePhase(.background)
        appState.handleScenePhase(.active)

        XCTAssertEqual(appState.pendingLoginFailure, failure)
        XCTAssertTrue(appState.showLogin)
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    func testSignInRaisedOnScreenDoesNotRetry() {
        let appState = makeSignedOutAppState()
        appState.phoneScreenIsAway = { false }

        appState.showLogin = true
        XCTAssertFalse(appState.signInWaitsForForeground)
        let failure = ConnectionFailurePresentation.notice(title: "Sign-in didn’t complete", message: "on screen")
        appState.pendingLoginFailure = failure

        appState.handleScenePhase(.background)
        appState.handleScenePhase(.active)

        XCTAssertEqual(appState.pendingLoginFailure, failure)
    }

    func testSignedInAgainInBackgroundStopsWaiting() {
        let appState = makeSignedOutAppState()
        appState.phoneScreenIsAway = { true }

        appState.showLogin = true
        XCTAssertTrue(appState.signInWaitsForForeground)
        appState.showLogin = false
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    /// A call from Hermes that wakes a closed Conduit, phone unlocked, Face
    /// ID dashboard: Face ID can't show, so the saved session connects
    /// instead of the sign-in screen (Eric's choice, 2026-10-11).
    func testFaceIDDashboardInBackgroundConnectsWithSavedSession() async throws {
        let (appState, _) = installFaceIDDashboard(savedTicket: "saved-ticket")
        appState.phoneScreenIsAway = { true }

        appState.loadSavedConnection()
        // The route taken, not the connection: the connect to the loopback
        // port fails soon after and may change it.
        let steps: @MainActor () -> [String] = {
            appState.connectionTimeline?.events.map(\.label) ?? []
        }
        try await waitUntil {
            steps().contains("Saved session (Face ID can't show off screen)") || appState.signInWaitsForForeground
        }

        XCTAssertTrue(steps().contains("Saved session (Face ID can't show off screen)"))
        XCTAssertFalse(steps().contains { $0.hasPrefix("Password sign-in") }, "The password stays behind Face ID")
    }

    /// No saved session to fall back on: sign-in waits for the screen.
    func testFaceIDDashboardInBackgroundWithoutSavedSessionWaitsForTheScreen() async throws {
        let (appState, _) = installFaceIDDashboard(savedTicket: nil)
        appState.phoneScreenIsAway = { true }

        appState.loadSavedConnection()
        try await waitUntil { appState.connection != nil || appState.signInWaitsForForeground }

        XCTAssertNil(appState.connection)
        XCTAssertTrue(appState.showLogin)
        XCTAssertTrue(appState.signInWaitsForForeground)
    }

    /// On screen, a refused Face ID still goes to sign-in: the saved session
    /// never stands in for it there.
    func testFaceIDRefusedOnScreenStillGoesToSignIn() async throws {
        let (appState, _) = installFaceIDDashboard(savedTicket: "saved-ticket")
        appState.phoneScreenIsAway = { false }
        var unlockAsked = false
        appState.unlockWithFaceID = {
            unlockAsked = true
            return false
        }

        appState.loadSavedConnection()
        try await waitUntil { unlockAsked }
        await Task.yield()

        XCTAssertNil(appState.connection)
        XCTAssertTrue(appState.showLogin)
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    /// A renewal refused off screen keeps the saved session for the retry
    /// on screen; refused on screen, it is retired as before.
    func testForcedSignInOffScreenKeepsTheSavedSession() {
        let (appState, dashboard) = installFaceIDDashboard(savedTicket: "saved-ticket")
        appState.phoneScreenIsAway = { true }

        appState.requireSignIn(message: "refused")

        XCTAssertTrue(appState.showLogin)
        XCTAssertTrue(appState.signInWaitsForForeground)
        XCTAssertNotNil(KeychainHelper.loadConnection(dashboardID: dashboard.id))
    }

    func testForcedSignInOnScreenRetiresTheSavedSession() {
        let (appState, dashboard) = installFaceIDDashboard(savedTicket: "saved-ticket")
        appState.phoneScreenIsAway = { false }

        appState.requireSignIn(message: "refused")

        XCTAssertTrue(appState.showLogin)
        XCTAssertFalse(appState.signInWaitsForForeground)
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: dashboard.id))
    }

    /// The retry really runs the saved sign-in: a dashboard with a saved
    /// session takes it once Conduit is on screen.
    func testRetryOnScreenTakesTheSavedSession() {
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let appState = makeSignedOutAppState(
            registry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        )
        let saved = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "saved-ticket")
        var away = true
        appState.phoneScreenIsAway = { away }
        appState.showLogin = true
        KeychainHelper.saveConnection(saved, dashboardID: dashboard.id)

        away = false
        appState.handleScenePhase(.background)
        appState.handleScenePhase(.active)

        XCTAssertEqual(appState.connection, saved)
        XCTAssertFalse(appState.showLogin)
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    /// A saved password is readable after the first unlock, so a call on a
    /// locked phone can sign in again; one saved by an earlier build (only
    /// while unlocked) moves the first time it is read.
    func testSavedPasswordIsReadableAfterFirstUnlock() throws {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        let credentials = DashboardCredentials(
            baseURL: "https://hermes.example", username: "hermes", password: "secret", requiresFaceID: true
        )

        let saved = UUID()
        KeychainHelper.saveCredentials(credentials, dashboardID: saved)
        let savedAccount = KeychainHelper.scopedAccount("hermes-conduit.credentials.v1", dashboardID: saved)
        XCTAssertEqual(backend.accessibility(ofAccount: savedAccount), afterFirstUnlock)

        let earlier = UUID()
        let earlierAccount = KeychainHelper.scopedAccount("hermes-conduit.credentials.v1", dashboardID: earlier)
        _ = backend.add([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.milim.conduit",
            kSecAttrAccount as String: earlierAccount,
            kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ])
        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: earlier), credentials)
        XCTAssertEqual(backend.accessibility(ofAccount: earlierAccount), afterFirstUnlock)
    }

    /// On a locked phone only a dashboard's own password can be written and
    /// read; the record from before saved dashboards stays readable only
    /// while unlocked.
    func testOnlyTheDashboardsOwnPasswordIsWrittenOnALockedPhone() {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let credentials = DashboardCredentials(
            baseURL: "https://hermes.example", username: "hermes", password: "secret", requiresFaceID: false
        )
        let dashboardID = UUID()
        backend.phoneLocked = true

        KeychainHelper.saveCredentials(credentials)
        KeychainHelper.saveCredentials(credentials, dashboardID: dashboardID)
        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: dashboardID), credentials)

        backend.phoneLocked = false
        XCTAssertNil(KeychainHelper.loadCredentials())
        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: dashboardID), credentials)
    }

    /// Launched before the first unlock after a restart, the saved
    /// dashboards were unreadable: the retry on screen reads them again.
    func testRetryOnScreenReadsSavedDashboardsAgain() {
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let appState = makeSignedOutAppState(prepare: { defaults in
            ProfileAppearanceStore(defaults: defaults).saveDefaultName("Ada", dashboardID: dashboard.id)
        })
        XCTAssertEqual(appState.defaultProfileName, ProfileAppearanceStore.defaultName)
        SavedDashboardRegistryStore.save(SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]))
        var away = true
        appState.phoneScreenIsAway = { away }
        appState.showLogin = true

        away = false
        appState.handleScenePhase(.background)
        appState.handleScenePhase(.active)

        XCTAssertEqual(appState.activeDashboardID, dashboard.id)
        XCTAssertEqual(appState.defaultProfileName, "Ada", "The dashboard's own presentation loads with it")
        XCTAssertTrue(appState.showLogin, "Nothing saved to sign in with")
    }

    /// An upgrade that ran on a locked phone left the old password unread:
    /// the retry on screen hands it to the dashboard and signs in with it.
    func testRetryOnScreenAdoptsThePasswordALockedUpgradeLeft() {
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let appState = makeSignedOutAppState(
            registry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        )
        let credentials = DashboardCredentials(
            baseURL: dashboard.normalizedURL, username: "hermes", password: "secret", requiresFaceID: false
        )
        KeychainHelper.saveCredentials(credentials)
        var away = true
        appState.phoneScreenIsAway = { away }
        appState.showLogin = true

        away = false
        appState.handleScenePhase(.background)
        appState.handleScenePhase(.active)

        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: dashboard.id), credentials)
        XCTAssertNil(KeychainHelper.loadCredentials())
        XCTAssertEqual(appState.connectionTimeline?.trigger, "retry on screen, password sign-in")
    }

    private func installFaceIDDashboard(savedTicket: String?) -> (AppState, SavedDashboard) {
        // Loopback port 1: nothing listens, so no request leaves the host.
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        // Made first: it puts the in-memory Keychain in place.
        let appState = makeSignedOutAppState(
            registry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        )
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: dashboard.normalizedURL, username: "hermes", password: "secret", requiresFaceID: true),
            dashboardID: dashboard.id
        )
        if let savedTicket {
            KeychainHelper.saveConnection(
                HermesConnection(baseUrl: dashboard.normalizedURL, ticket: savedTicket),
                dashboardID: dashboard.id
            )
        }
        appState.unlockWithFaceID = { false }
        return (appState, dashboard)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the restore")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSignedOutAppState(
        registry: SavedDashboardRegistry = SavedDashboardRegistry(),
        prepare: @MainActor (UserDefaults) -> Void = { _ in }
    ) -> AppState {
        let defaults = makeScratchDefaults("AppStateBackgroundSignInTests")
        prepare(defaults)
        // An unsigned simulator test host can't write the system keychain,
        // and a signed one must never hand a retry the developer's own
        // dashboards.
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            // A failed connect would retry for real: keep the retry inert.
            reconnectScheduler: { _, _ in {} },
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }
}
