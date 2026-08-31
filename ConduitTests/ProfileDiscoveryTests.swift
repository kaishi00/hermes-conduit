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
        // Seeded before AppState init: the stored dashboard URL is where a
        // cold launch's baseline server identity is captured from.
        defaults.set("https://one.example", forKey: "conduit.dashboardURL")
        seedKnownProfiles(["default", "one-only"], activeProfile: "default")
        let gate = ProfileResponseGate()
        let appState = makeAppState(profileDiscoveryLoader: { try await gate.wait() })
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

    func testLateFailureAfterServerChangeDoesNotRepopulateProfileState() async throws {
        defaults.set("https://one.example", forKey: "conduit.dashboardURL")
        seedKnownProfiles(["default", "one-only"], activeProfile: "default")
        let gate = ProfileResponseGate()
        let appState = makeAppState(profileDiscoveryLoader: { try await gate.wait() })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        let discovery = Task { await appState.loadProfiles() }
        await gate.waitUntilEntered()

        // The failure branch carries the same commit gate: without it, a late
        // error from the old connection would "recover" by repopulating the
        // just-wiped state with the previous server-era minimum set.
        XCTAssertTrue(appState.prepareChatResumeForConnection(to: "https://two.example"))
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://two.example"))
        gate.resume(.failure(DiscoveryError.transient))
        await discovery.value

        XCTAssertTrue(appState.profiles.isEmpty)
        assertPersistedKnownProfiles(nil)
    }

    func testDegenerateEmptySuccessKeepsKnownProfiles() async throws {
        seedKnownProfiles(["default", "profile2"], activeProfile: "profile2")
        let appState = makeAppState(profileDiscoveryLoader: {
            ["profiles": []]
        })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        // A 200 whose payload lists no profiles (dashboard mid-restart,
        // partial deploy) is degraded, not authoritative: it must not shrink
        // the known set or persist a degraded cache.
        await appState.loadProfiles()

        XCTAssertEqual(appState.profiles, ["default", "profile2"])
        assertPersistedKnownProfiles(["default", "profile2"])

        // Same for a payload missing the key entirely. Seeded explicitly so
        // this half does not depend on state the first half persisted.
        seedKnownProfiles(["default", "profile2"], activeProfile: "profile2")
        let missingKeyState = makeAppState(profileDiscoveryLoader: { [:] })
        missingKeyState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        await missingKeyState.loadProfiles()

        XCTAssertEqual(missingKeyState.profiles, ["default", "profile2"])
        assertPersistedKnownProfiles(["default", "profile2"])
    }

    // MARK: - Authoritative success re-homes a deleted active profile

    func testAuthoritativeResponseRemovingActiveProfileRehomesToDefault() async throws {
        seedKnownProfiles(["default", "profile2"], activeProfile: "profile2")
        // Stale per-profile bookkeeping and catalog state belonging to the
        // deleted profile, used to probe the hard-boundary side effects.
        // Titles are stored as a UserDefaults dictionary; pins as JSON data,
        // each mirroring its production persistence representation.
        defaults.set(
            ["profile2": "old title"],
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        )
        defaults.set(
            try JSONEncoder().encode(["profile2": ["pin-1"], "default": []]),
            forKey: "conduit.pinnedSessionIdsByProfile.v1"
        )
        let appState = makeAppState(profileDiscoveryLoader: {
            ["profiles": ["profile3", "default"]]
        })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))
        appState.sessions = [
            SessionSummary(
                id: "profile2-session",
                alternateIds: [],
                title: "profile2-session",
                model: "Hermes",
                updatedLabel: "now",
                profile: "profile2",
                source: .chat,
                isActive: false,
                isArchived: false,
                lineageRootId: nil
            )
        ]
        // Stale runtime floor owned by the deleted profile; the re-home must
        // neutralize it exactly like switchProfile does.
        appState.runtime.approvalsMode = "off"
        appState.runtime.yolo = true

        await appState.loadProfiles()

        // The server's list is authoritative (profile2 was deleted
        // externally); the active profile must transition to a valid
        // fallback instead of lingering outside the visible list.
        XCTAssertEqual(appState.profiles, ["default", "profile3"])
        XCTAssertEqual(appState.activeProfile, "default")
        XCTAssertEqual(defaults.string(forKey: Self.activeProfileKey), "default")
        // Hard-boundary side effects: the deleted profile's catalog state is
        // cleared, its persisted bookkeeping is pruned so a later
        // re-creation starts fresh, and the fallback's state is restored.
        XCTAssertTrue(appState.sessions.isEmpty)
        XCTAssertEqual(appState.activeSessionTitle, "New conversation")
        // persistPinnedSessions stores JSON data, mirroring the init load.
        let persistedPins = try JSONDecoder().decode(
            [String: [String]].self,
            from: defaults.data(forKey: "conduit.pinnedSessionIdsByProfile.v1") ?? Data()
        )
        XCTAssertEqual(persistedPins, ["default": []])
        XCTAssertEqual(
            defaults.dictionary(forKey: "conduit.activeSessionTitlesByProfile.v1") as? [String: String],
            [:]
        )
        // The deleted profile's runtime approval floor and YOLO state do not
        // survive the re-home, and no stale Projects state rides along.
        XCTAssertNil(appState.runtime.approvalsMode)
        XCTAssertFalse(appState.runtime.yolo)
        XCTAssertTrue(appState.projects.isEmpty)
        XCTAssertFalse(appState.supportsProjects)
        XCTAssertFalse(appState.projectsLoading)
    }

    func testAuthoritativeResponseContainingActiveProfileKeepsItWithoutReset() async throws {
        seedKnownProfiles(["default", "profile2"], activeProfile: "profile2")
        let appState = makeAppState(profileDiscoveryLoader: {
            ["profiles": ["profile3", "default", "profile2"]]
        })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))
        // Probe for an unnecessary reset: profile-scoped catalog state
        // installed under the still-valid active profile must survive.
        appState.sessions = [
            SessionSummary(
                id: "profile2-session",
                alternateIds: [],
                title: "profile2-session",
                model: "Hermes",
                updatedLabel: "now",
                profile: "profile2",
                source: .chat,
                isActive: false,
                isArchived: false,
                lineageRootId: nil
            )
        ]

        await appState.loadProfiles()

        XCTAssertEqual(appState.profiles, ["default", "profile2", "profile3"])
        XCTAssertEqual(appState.activeProfile, "profile2")
        XCTAssertEqual(defaults.string(forKey: Self.activeProfileKey), "profile2")
        XCTAssertEqual(appState.sessions.count, 1)
    }

    func testAuthoritativeResponseDeletingNonActiveProfilePropagates() async throws {
        seedKnownProfiles(["default", "profile2"], activeProfile: "default")
        let appState = makeAppState(profileDiscoveryLoader: {
            ["profiles": ["default"]]
        })
        appState.installDashboardTicketBridgeForTesting(makeBridge("https://one.example"))

        await appState.loadProfiles()

        // Authoritative deletions still propagate; the active profile is
        // unaffected because it remains server-valid.
        XCTAssertEqual(appState.profiles, ["default"])
        XCTAssertEqual(appState.activeProfile, "default")
        assertPersistedKnownProfiles(["default"])
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
