import XCTest
@testable import Conduit

/// Settings › Saved Dashboards › Ask Which Dashboard at Launch (#1908): a
/// plain open waits on the dashboard list for a tap; a launch in the
/// background, or one with somewhere to go, signs in as before.
/// An extension of an existing class, so the CI test plan gains no class.
extension AppStateForegroundLifecycleTests {
    func testAskAtLaunchHoldsTheListOnScreen() async throws {
        let (appState, home, _) = makeTwoDashboardLaunch(asks: true)
        appState.phoneScreenIsAway = { false }

        appState.beginLaunchSignIn()
        XCTAssertNil(appState.connection, "Nothing signs in before a pick")
        XCTAssertTrue(appState.launchAwaitsDashboardChoice)

        appState.handleScenePhase(.active)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(appState.connection)
        XCTAssertTrue(appState.showLogin)
        XCTAssertTrue(appState.launchAwaitsDashboardChoice)
        XCTAssertEqual(appState.activeDashboardID, home.id, "The last dashboard used stays selected")
    }

    func testWithoutTheSettingTheLastDashboardSignsIn() {
        let (appState, home, _) = makeTwoDashboardLaunch(asks: false)

        appState.beginLaunchSignIn()

        XCTAssertEqual(appState.connection, savedConnection(for: home))
        XCTAssertFalse(appState.launchAwaitsDashboardChoice)
    }

    func testOneDashboardSignsInWithTheSettingOn() {
        let (appState, home, _) = makeTwoDashboardLaunch(asks: true, onlyHome: true)

        appState.beginLaunchSignIn()

        XCTAssertEqual(appState.connection, savedConnection(for: home))
        XCTAssertFalse(appState.launchAwaitsDashboardChoice)
    }

    /// The Watch, a call or a place woke Conduit: no phone screen comes,
    /// so the last dashboard signs in for what woke it.
    func testLaunchInTheBackgroundSignsInAfterTheGrace() async throws {
        let (appState, home, _) = makeTwoDashboardLaunch(asks: true)
        appState.phoneScreenIsAway = { true }

        appState.beginLaunchSignIn()
        XCTAssertNil(appState.connection)

        // The route taken, not the connection: the connect to the loopback
        // port fails soon after and may change it.
        try await waitForLaunchSignIn { appState.connectionTimeline != nil }
        XCTAssertEqual(appState.connectionTimeline?.trigger, "launch in the background, browser sign-in (saved ticket)")
        XCTAssertEqual(appState.activeDashboardID, home.id)
    }

    /// Face ID can't show off screen, so the background sign-in waits for
    /// the screen; on screen the list waits for a pick instead of asking
    /// Face ID for the last dashboard.
    func testBackgroundFaceIDWaitHoldsTheListOnScreen() async throws {
        let (appState, home, _) = makeTwoDashboardLaunch(asks: true, homeTicket: false)
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: home.normalizedURL, username: "hermes", password: "secret", requiresFaceID: true),
            dashboardID: home.id
        )
        var away = true
        appState.phoneScreenIsAway = { away }
        var unlockAsked = 0
        appState.unlockWithFaceID = {
            unlockAsked += 1
            return false
        }

        appState.beginLaunchSignIn()
        try await waitForLaunchSignIn { appState.signInWaitsForForeground }
        let askedInBackground = unlockAsked

        away = false
        appState.handleScenePhase(.active)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(unlockAsked, askedInBackground, "No Face ID for the last dashboard on screen")
        XCTAssertFalse(appState.signInWaitsForForeground)
        XCTAssertNil(appState.pendingLoginFailure)
        XCTAssertTrue(appState.showLogin)
        XCTAssertTrue(appState.launchAwaitsDashboardChoice)
    }

    /// A release while the background launch's sign-in is under way or
    /// waiting for the screen starts no second one; on screen its usual
    /// retry runs.
    func testReleaseDuringTheBackgroundSignInStartsNoSecondOne() async throws {
        let (appState, home, _) = makeTwoDashboardLaunch(asks: true, homeTicket: false)
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: home.normalizedURL, username: "hermes", password: "secret", requiresFaceID: true),
            dashboardID: home.id
        )
        var away = true
        appState.phoneScreenIsAway = { away }
        var unlockAsked = 0
        appState.unlockWithFaceID = {
            unlockAsked += 1
            return false
        }

        appState.beginLaunchSignIn()
        try await waitForLaunchSignIn { appState.signInWaitsForForeground }
        let trigger = appState.connectionTimeline?.trigger
        let askedInBackground = unlockAsked

        appState.releaseLaunchDashboardChoice(for: "a notification")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(appState.connectionTimeline?.trigger, trigger, "No second sign-in")
        XCTAssertEqual(unlockAsked, askedInBackground)
        XCTAssertFalse(appState.launchAwaitsDashboardChoice)

        away = false
        appState.handleScenePhase(.active)
        try await waitForLaunchSignIn { unlockAsked > askedInBackground }
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    /// A notification, a link, Siri, the car or the Watch needs Hermes: the
    /// last dashboard signs in for it, as without the setting.
    func testSomethingTheLaunchCameForSignsIn() {
        let (appState, home, _) = makeTwoDashboardLaunch(asks: true)
        appState.phoneScreenIsAway = { false }
        appState.beginLaunchSignIn()
        appState.handleScenePhase(.active)

        appState.releaseLaunchDashboardChoice(for: "a notification")

        XCTAssertEqual(appState.connection, savedConnection(for: home))
        XCTAssertFalse(appState.launchAwaitsDashboardChoice)
    }

    func testPickingADashboardEndsTheWait() async {
        let (appState, _, family) = makeTwoDashboardLaunch(asks: true)
        appState.phoneScreenIsAway = { false }
        appState.beginLaunchSignIn()
        appState.handleScenePhase(.active)

        await appState.switchDashboard(to: family.id)

        XCTAssertFalse(appState.launchAwaitsDashboardChoice)
        XCTAssertEqual(appState.activeDashboardID, family.id)
        // Nothing is left for a later release to sign in to.
        appState.releaseLaunchDashboardChoice(for: "a notification")
        XCTAssertEqual(appState.activeDashboardID, family.id)
    }

    // MARK: - Helpers

    private func savedConnection(for dashboard: SavedDashboard) -> HermesConnection {
        HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "ticket-\(dashboard.label)")
    }

    private func makeTwoDashboardLaunch(
        asks: Bool,
        onlyHome: Bool = false,
        homeTicket: Bool = true
    ) -> (AppState, SavedDashboard, SavedDashboard) {
        // Loopback port 1: nothing listens, so no request leaves the host.
        let home = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let family = SavedDashboard(id: UUID(), label: "Family", normalizedURL: "http://127.0.0.1:2")
        let defaults = makeScratchDefaults("AppStateLaunchDashboardChoiceTests")
        defaults.set(asks, forKey: AppState.asksWhichDashboardAtLaunchKey)
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(
                activeDashboardID: home.id,
                dashboards: onlyHome ? [home] : [home, family]
            ),
            clearSessionPresentationCache: {},
            // A failed connect would retry for real: keep the retry inert.
            reconnectScheduler: { _, _ in {} },
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.launchDashboardChoiceGrace = .milliseconds(20)
        appState.unlockWithFaceID = { false }
        if homeTicket {
            KeychainHelper.saveConnection(savedConnection(for: home), dashboardID: home.id)
        }
        KeychainHelper.saveConnection(savedConnection(for: family), dashboardID: family.id)
        return (appState, home, family)
    }

    private func waitForLaunchSignIn(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the launch sign-in")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
