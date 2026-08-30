import XCTest
@testable import Conduit

/// Regression coverage for the disappearing-profile bug: a transient
/// `/api/profiles` failure must never shrink the visible profile list or
/// overwrite the persisted known-profile cache, and a late response from a
/// replaced connection must not commit stale profile state.
@MainActor
final class ProfileDiscoveryTests: XCTestCase {

    private static let knownProfilesKey = "conduit.knownProfiles.v1"
    private static let activeProfileKey = "conduit.activeProfile"

    private enum DiscoveryError: Error {
        case transient
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ProfileDiscoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAppState(
        profileDiscoveryLoader: (@MainActor () async throws -> [String: Any])? = nil
    ) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            profileDiscoveryLoader: profileDiscoveryLoader
        )
    }

    private func makeBridge(_ baseURL: String) -> DashboardTicketBridge {
        DashboardTicketBridge(
            baseURL: baseURL,
            pendingRequests: DashboardTicketBridgePendingRequests(),
            readinessPollAttempts: 0,
            readinessPollInterval: .milliseconds(1)
        )
    }

    private func seedKnownProfiles(_ knownProfiles: [String]?, activeProfile: String) {
        if let knownProfiles {
            defaults.set(knownProfiles, forKey: Self.knownProfilesKey)
        }
        defaults.set(activeProfile, forKey: Self.activeProfileKey)
    }

    private func assertPersistedKnownProfiles(
        _ expected: [String]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            defaults.stringArray(forKey: Self.knownProfilesKey),
            expected,
            file: file,
            line: line
        )
    }

    // MARK: - Initialization hydration

    func testInitHydratesProfilesFromPersistedKnownProfileCache() {
        seedKnownProfiles(["default", "profile2"], activeProfile: "profile2")

        let appState = makeAppState()

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
    }

    func testInitHydrationReaddsDefaultToDegradedLegacyCache() {
        // A pre-fix build could persist a degraded one-entry cache; hydration
        // must heal it with the `default` invariant instead of trusting it.
        seedKnownProfiles(["profile2"], activeProfile: "profile2")

        let appState = makeAppState()

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
    }

    // MARK: - Discovery failure must never shrink the known set

    func testDiscoveryFailurePreservesCompleteCacheWhenActiveIsSecondProfile() async throws {
        seedKnownProfiles(["default", "profile2"], activeProfile: "profile2")
        let appState = makeAppState(profileDiscoveryLoader: { throw DiscoveryError.transient })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        await appState.loadProfiles()

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
        assertPersistedKnownProfiles(["default", "profile2"])
    }

    func testDiscoveryFailurePreservesCompleteCacheWhenActiveIsDefault() async throws {
        seedKnownProfiles(["default", "profile2"], activeProfile: "default")
        let appState = makeAppState(profileDiscoveryLoader: { throw DiscoveryError.transient })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        await appState.loadProfiles()

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
        assertPersistedKnownProfiles(["default", "profile2"])
    }

    func testDiscoveryFailureWithoutCachePresentsMinimumSetAndLaterSuccessConverges() async throws {
        seedKnownProfiles(nil, activeProfile: "profile2")
        let appState = makeAppState(profileDiscoveryLoader: { throw DiscoveryError.transient })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        await appState.loadProfiles()

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
        assertPersistedKnownProfiles(["default", "profile2"])

        // The fallback must not corrupt future discovery: the next successful
        // refresh still establishes the server's list without a re-login.
        let recoveredState = makeAppState(profileDiscoveryLoader: {
            ["profiles": ["profile2", "default", "profile3"]]
        })
        recoveredState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        await recoveredState.loadProfiles()

        XCTAssertEqual(recoveredState.profiles, ["default", "profile2", "profile3"])
        assertPersistedKnownProfiles(["default", "profile2", "profile3"])
    }

    // MARK: - Successful discovery

    func testDiscoverySuccessRefreshesVisibleListAndPersistedCache() async throws {
        seedKnownProfiles(["default"], activeProfile: "default")
        let appState = makeAppState(profileDiscoveryLoader: {
            ["profiles": ["profile2", "default"]]
        })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        await appState.loadProfiles()

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
        assertPersistedKnownProfiles(["default", "profile2"])
    }

    func testTransientFailureThenSuccessConvergesWithoutRelogin() async throws {
        seedKnownProfiles(["default", "profile2"], activeProfile: "profile2")
        var shouldFail = true
        let appState = makeAppState(profileDiscoveryLoader: {
            if shouldFail { throw DiscoveryError.transient }
            return ["profiles": ["profile2", "default"]]
        })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        await appState.loadProfiles()
        XCTAssertEqual(appState.profiles, ["default", "profile2"])

        shouldFail = false
        await appState.loadProfiles()

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
        assertPersistedKnownProfiles(["default", "profile2"])
    }

    // MARK: - Stale responses from replaced connections

    func testLateResponseFromReplacedBridgeDoesNotCommit() async throws {
        seedKnownProfiles(["default", "profile2"], activeProfile: "profile2")
        let gate = ProfileResponseGate()
        let appState = makeAppState(profileDiscoveryLoader: { try await gate.wait() })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        let discovery = Task { await appState.loadProfiles() }
        await gate.waitUntilEntered()

        // The connection is replaced (server change / re-login) while the old
        // request is still in flight; its late success must be discarded.
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://two.example"))
        gate.resume(.success(["profiles": ["default", "profile2", "stale-only"]]))
        await discovery.value

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
        assertPersistedKnownProfiles(["default", "profile2"])
    }

    func testLateResponseAfterServerChangeDoesNotRepopulateProfileState() async throws {
        defaults.set("https://one.example", forKey: "conduit.dashboardURL")
        seedKnownProfiles(["default", "one-only"], activeProfile: "default")
        let gate = ProfileResponseGate()
        let appState = makeAppState(profileDiscoveryLoader: { try await gate.wait() })
        appState.rememberDashboardURL("https://one.example")
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        let discovery = Task { await appState.loadProfiles() }
        await gate.waitUntilEntered()

        // Reconnecting to a different Hermes server wipes the server-scoped
        // profile state and swaps the dashboard bridge; the old server's late
        // response must not repopulate either.
        XCTAssertTrue(appState.prepareChatResumeForConnection(to: "https://two.example"))
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://two.example"))
        gate.resume(.success(["profiles": ["default", "one-only"]]))
        await discovery.value

        XCTAssertTrue(appState.profiles.isEmpty)
        assertPersistedKnownProfiles(nil)
    }
}

/// Result-carrying suspension gate for driving `loadProfiles()` through a
/// controlled response window. All access is MainActor-confined, matching the
/// AppState and test isolation.
@MainActor
private final class ProfileResponseGate {
    private var responseContinuation: CheckedContinuation<[String: Any], Error>?
    private var heldResponse: Result<[String: Any], Error>?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var enterCount = 0

    func wait() async throws -> [String: Any] {
        enterCount += 1
        let waiters = enteredContinuations
        enteredContinuations = []
        waiters.forEach { $0.resume() }
        if let heldResponse {
            return try heldResponse.get()
        }
        return try await withCheckedThrowingContinuation { responseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard enterCount == 0 else { return }
        await withCheckedContinuation { enteredContinuations.append($0) }
    }

    func resume(_ result: Result<[String: Any], Error>) {
        if let continuation = responseContinuation {
            responseContinuation = nil
            continuation.resume(with: result)
        } else {
            heldResponse = result
        }
    }
}
