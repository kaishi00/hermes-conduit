//
//  SavedDashboardRegistryTests.swift
//  Conduit
//
//  Coverage for the multi-dashboard identity layer (#148): registry shape,
//  label derivation, the migration decision function, and the end-to-end
//  legacy migration through the real Keychain (idempotent, retryable,
//  crash-safe ordering, and strict cross-dashboard isolation).
//
//  The migration end-to-end tests share the LEGACY global Keychain records,
//  so every test seeds what it needs and tearDown wipes both the registry
//  record and everything the test created. Scoped records use per-test UUIDs
//  and can never collide.
//

import XCTest
@testable import Conduit

@MainActor
final class SavedDashboardRegistryTests: XCTestCase {

    private var backend: InMemoryKeychainBackend!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var createdDashboardIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        defaultsSuite = "SavedDashboardRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        addTeardownBlock { [weak self] in
            self?.defaults.removePersistentDomain(forName: self?.defaultsSuite ?? "")
        }
        KeychainHelper.clearDashboardRegistry()
        KeychainHelper.clearConnection()
        KeychainHelper.clearCredentials()
        KeychainHelper.clearCloudflareAccess()
        createdDashboardIDs = []
    }

    override func tearDown() {
        for id in createdDashboardIDs {
            KeychainHelper.clearConnection(dashboardID: id)
            KeychainHelper.clearCredentials(dashboardID: id)
            KeychainHelper.clearCloudflareAccess(dashboardID: id)
            KeychainHelper.clearDashboardCookies(dashboardID: id)
        }
        KeychainHelper.clearDashboardRegistry()
        KeychainHelper.clearConnection()
        KeychainHelper.clearCredentials()
        KeychainHelper.clearCloudflareAccess()
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        super.tearDown()
    }

    private func track(_ id: UUID) -> UUID {
        createdDashboardIDs.append(id)
        return id
    }

    private let legacyURL = "https://mac.tailnet.ts.net"
    private let legacyCredentials = DashboardCredentials(
        baseURL: "https://mac.tailnet.ts.net",
        username: "hermes",
        password: "s3cret",
        requiresFaceID: true
    )

    // MARK: - Registry shape

    func testRegistryRoundTripsThroughKeychain() throws {
        let id = UUID()
        let registry = SavedDashboardRegistry(
            activeDashboardID: id,
            dashboards: [SavedDashboard(id: id, label: "Mac", normalizedURL: legacyURL)]
        )
        SavedDashboardRegistryStore.save(registry)
        let loaded = try XCTUnwrap(SavedDashboardRegistryStore.load())
        XCTAssertEqual(loaded, registry)
    }

    func testDashboardLookupByIDAndURL() {
        let a = SavedDashboard(id: UUID(), label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let b = SavedDashboard(id: UUID(), label: "VPS", normalizedURL: "https://hermes.example.com")
        let registry = SavedDashboardRegistry(activeDashboardID: a.id, dashboards: [a, b])
        XCTAssertEqual(registry.dashboard(with: a.id)?.label, "Mac")
        XCTAssertEqual(registry.dashboardID(atNormalizedURL: "https://hermes.example.com"), b.id)
        XCTAssertNil(registry.dashboardID(atNormalizedURL: "https://unknown.example.com"))
    }

    // MARK: - Label derivation

    func testLabelDerivationFromDNSHost() {
        XCTAssertEqual(SavedDashboardLabel.derive(from: "https://mac.tailnet.ts.net"), "Mac")
        XCTAssertEqual(SavedDashboardLabel.derive(from: "https://hermes.example.com/path"), "Hermes")
    }

    func testLabelDerivationFromIPLiteralKeepsFullAddress() {
        XCTAssertEqual(SavedDashboardLabel.derive(from: "http://192.168.1.5:8080"), "192.168.1.5")
    }

    func testLabelDerivationFromIPv6LiteralKeepsFullAddress() {
        XCTAssertEqual(SavedDashboardLabel.derive(from: "http://[2001:db8::1]:8080"), "2001:db8::1")
    }

    func testLabelDerivationDisambiguatesDuplicates() {
        let labels = SavedDashboardLabel.derive(
            from: "https://mac.tailnet.ts.net",
            existingLabels: ["Mac"]
        )
        XCTAssertEqual(labels, "Mac 2")
    }

    // MARK: - Migration decision (pure)

    private func fullLegacyState() -> LegacyDashboardState {
        LegacyDashboardState(
            connection: HermesConnection(baseUrl: legacyURL, ticket: "ticket-1"),
            credentials: legacyCredentials,
            cookieMirror: Data("cookies".utf8),
            cloudflare: CloudflareAccessKeychainRecord(clientID: "cid", clientSecret: "csecret", origin: legacyURL),
            rememberedDashboardURL: legacyURL
        )
    }

    func testMigrationOutcomeForFullLegacyState() throws {
        let outcome = SavedDashboardMigration.outcome(
            legacy: fullLegacyState(),
            existingRegistry: nil,
            storedServerIdentity: legacyURL,
            normalizedLegacyURL: legacyURL
        )
        guard case .migrated(let plan) = outcome else {
            return XCTFail("Expected .migrated, got \(outcome)")
        }
        XCTAssertTrue(plan.writesConnection)
        XCTAssertTrue(plan.writesCredentials)
        XCTAssertTrue(plan.writesCookies)
        XCTAssertTrue(plan.writesCloudflare)
        XCTAssertTrue(plan.relabelsServerIdentity)
        XCTAssertTrue(plan.retiresLegacy)
        XCTAssertEqual(plan.normalizedURL, legacyURL)
        XCTAssertEqual(plan.label, "Mac")
    }

    func testMigrationOutcomeSkipsIdentityRelabelForOtherServer() {
        let outcome = SavedDashboardMigration.outcome(
            legacy: fullLegacyState(),
            existingRegistry: nil,
            // Last used a DIFFERENT server: the legacy identity must survive.
            storedServerIdentity: "https://other.example.com",
            normalizedLegacyURL: legacyURL
        )
        guard case .migrated(let plan) = outcome else {
            return XCTFail("Expected .migrated, got \(outcome)")
        }
        XCTAssertFalse(plan.relabelsServerIdentity)
    }

    func testMigrationOutcomeAlreadyMigratedWhenRegistryExists() {
        let registry = SavedDashboardRegistry()
        let outcome = SavedDashboardMigration.outcome(
            legacy: fullLegacyState(),
            existingRegistry: registry,
            storedServerIdentity: legacyURL,
            normalizedLegacyURL: legacyURL
        )
        XCTAssertEqual(outcome, .alreadyMigrated(retireLegacy: true))
    }

    func testMigrationOutcomeCleanInstallWhenNoLegacyState() {
        let outcome = SavedDashboardMigration.outcome(
            legacy: LegacyDashboardState(),
            existingRegistry: nil,
            storedServerIdentity: nil,
            normalizedLegacyURL: nil
        )
        XCTAssertEqual(outcome, .cleanInstall)
    }

    func testMigrationOutcomePartialLegacyStateDerivesURLFromCredentials() throws {
        let partial = LegacyDashboardState(
            connection: nil,
            credentials: legacyCredentials,
            cookieMirror: nil,
            cloudflare: nil,
            rememberedDashboardURL: nil
        )
        let outcome = SavedDashboardMigration.outcome(
            legacy: partial,
            existingRegistry: nil,
            storedServerIdentity: nil,
            normalizedLegacyURL: nil
        )
        guard case .migrated(let plan) = outcome else {
            return XCTFail("Expected .migrated, got \(outcome)")
        }
        XCTAssertFalse(plan.writesConnection)
        XCTAssertTrue(plan.writesCredentials)
        XCTAssertFalse(plan.writesCookies)
        XCTAssertFalse(plan.writesCloudflare)
        XCTAssertEqual(plan.normalizedURL, legacyURL)
    }

    // MARK: - End-to-end migration (real Keychain)

    func testFullLegacyMigrationWritesScopedRecordsBeforeRegistryAndRetiresLegacy() throws {
        KeychainHelper.saveConnection(HermesConnection(baseUrl: legacyURL, ticket: "ticket-1"))
        KeychainHelper.saveCredentials(legacyCredentials)
        KeychainHelper.saveDashboardCookies(Data("cookies".utf8))
        KeychainHelper.saveCloudflareAccess(
            CloudflareAccessCredentials.from(clientID: "cid", clientSecret: "csecret")!,
            origin: legacyURL
        )
        defaults.set(legacyURL, forKey: "conduit.dashboardURL")
        defaults.set(legacyURL, forKey: AppState.chatResumeServerIdentityKey)
        addTeardownBlock { [defaults] in defaults.removeObject(forKey: "conduit.dashboardURL") }

        let registry = SavedDashboardMigrator.loadRegistry(defaults: defaults)

        let id = try XCTUnwrap(registry.activeDashboardID)
        track(id)
        XCTAssertEqual(registry.dashboards.count, 1)
        XCTAssertEqual(registry.dashboards[0].normalizedURL, legacyURL)
        XCTAssertEqual(registry.dashboards[0].label, "Mac")

        // Every legacy record migrated into the scoped layout.
        let connection = try XCTUnwrap(KeychainHelper.loadConnection(dashboardID: id))
        XCTAssertEqual(connection, HermesConnection(baseUrl: legacyURL, ticket: "ticket-1"))
        let credentials = try XCTUnwrap(KeychainHelper.loadCredentials(dashboardID: id))
        XCTAssertEqual(credentials, legacyCredentials)
        XCTAssertNotNil(KeychainHelper.loadDashboardCookies(dashboardID: id))
        let access = try XCTUnwrap(KeychainHelper.loadCloudflareAccess(dashboardID: id, for: legacyURL))
        XCTAssertEqual(access.clientID, "cid")

        // Legacy records retired only after the registry committed.
        XCTAssertNil(KeychainHelper.loadConnection())
        XCTAssertNil(KeychainHelper.loadCredentials())
        XCTAssertNil(KeychainHelper.loadDashboardCookies())
        XCTAssertNil(KeychainHelper.loadCloudflareAccess())

        // The identity was relabeled so the upgrade triggers no teardown.
        XCTAssertEqual(
            defaults.string(forKey: AppState.chatResumeServerIdentityKey),
            id.uuidString
        )
    }

    func testMigrationIsIdempotent() throws {
        KeychainHelper.saveConnection(HermesConnection(baseUrl: legacyURL, ticket: "ticket-1"))
        let first = SavedDashboardMigrator.loadRegistry()
        let firstID = try XCTUnwrap(first.activeDashboardID)
        track(firstID)

        let second = SavedDashboardMigrator.loadRegistry()
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.dashboards.count, 1)
    }

    func testMigrationRetriesAfterInterruption() throws {
        // Simulate a migration that died after the scoped writes but before
        // the registry committed: CONFLICTING scoped records exist (from the
        // partial run), the legacy records still exist, and no registry does.
        // The retry must rebuild from the LEGACY records — legacy remained
        // authoritative at every crash point — and overwrite the stale
        // scoped writes.
        KeychainHelper.saveConnection(HermesConnection(baseUrl: legacyURL, ticket: "legacy-authoritative"))
        KeychainHelper.saveCredentials(legacyCredentials)
        let orphanScopedID = track(UUID())
        KeychainHelper.saveConnection(
            HermesConnection(baseUrl: legacyURL, ticket: "scoped-partial-run"),
            dashboardID: orphanScopedID
        )

        let registry = SavedDashboardMigrator.loadRegistry(defaults: defaults)
        let id = try XCTUnwrap(registry.activeDashboardID)
        track(id)
        XCTAssertNotEqual(id, orphanScopedID, "the interrupted run's scoped identity is not reused")
        XCTAssertEqual(
            try XCTUnwrap(KeychainHelper.loadConnection(dashboardID: id)).ticket,
            "legacy-authoritative",
            "the retry rebuilds from legacy, which stayed authoritative until the registry committed"
        )
        XCTAssertEqual(registry.dashboards[0].normalizedURL, legacyURL)
        // The committed registry is the new authority; the legacy records are
        // retired behind it.
        XCTAssertNil(KeychainHelper.loadConnection())
    }

    func testLazyRetirementHonorsInjectedDefaults() throws {
        // Registry already present + legacy records still around (a migration
        // that died before retirement): loading with the SAME injected
        // defaults retires the legacy records.
        KeychainHelper.saveConnection(HermesConnection(baseUrl: legacyURL, ticket: "leftover"))
        let existing = SavedDashboardRegistry(activeDashboardID: nil, dashboards: [])
        SavedDashboardRegistryStore.save(existing)

        let registry = SavedDashboardMigrator.loadRegistry(defaults: defaults)
        XCTAssertEqual(registry, existing)
        XCTAssertNil(KeychainHelper.loadConnection(), "lazy retirement removes the legacy leftovers")
    }

    func testCleanInstallProducesEmptyRegistryWithoutLegacy() throws {
        let registry = SavedDashboardMigrator.loadRegistry(defaults: defaults)
        XCTAssertTrue(registry.dashboards.isEmpty)
        XCTAssertNil(registry.activeDashboardID)
        // Repeated loads are stable and never resurrect dashboards.
        XCTAssertEqual(SavedDashboardMigrator.loadRegistry(), registry)
    }

    func testBrowserAuthLegacyStateMigratesConnectionAndCookiesOnly() throws {
        // Browser-auth dashboards have a saved ticket + cookie mirror but no
        // password credentials.
        KeychainHelper.saveConnection(HermesConnection(baseUrl: legacyURL, ticket: "web-ticket"))
        KeychainHelper.saveDashboardCookies(Data("web-cookies".utf8))

        let registry = SavedDashboardMigrator.loadRegistry(defaults: defaults)
        let id = try XCTUnwrap(registry.activeDashboardID)
        track(id)
        XCTAssertNil(KeychainHelper.loadCredentials(dashboardID: id))
        XCTAssertEqual(try XCTUnwrap(KeychainHelper.loadConnection(dashboardID: id)).ticket, "web-ticket")
        XCTAssertNotNil(KeychainHelper.loadDashboardCookies(dashboardID: id))
    }

    // MARK: - Cross-dashboard isolation (scoped records)

    func testScopedRecordsAreIsolatedBetweenDashboards() throws {
        let a = track(UUID())
        let b = track(UUID())
        KeychainHelper.saveCredentials(legacyCredentials, dashboardID: a)
        KeychainHelper.saveConnection(HermesConnection(baseUrl: legacyURL, ticket: "a-ticket"), dashboardID: a)
        KeychainHelper.saveCloudflareAccess(
            CloudflareAccessCredentials.from(clientID: "a-id", clientSecret: "a-secret")!,
            origin: legacyURL,
            dashboardID: a
        )
        KeychainHelper.saveDashboardCookies(Data("a-cookies".utf8), dashboardID: a)

        // B reads nothing of A's.
        XCTAssertNil(KeychainHelper.loadCredentials(dashboardID: b))
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: b))
        XCTAssertNil(KeychainHelper.loadCloudflareAccess(dashboardID: b, for: legacyURL))
        XCTAssertNil(KeychainHelper.loadDashboardCookies(dashboardID: b))

        // Clearing B never touches A.
        KeychainHelper.clearCredentials(dashboardID: b)
        KeychainHelper.clearConnection(dashboardID: b)
        KeychainHelper.clearCloudflareAccess(dashboardID: b)
        KeychainHelper.clearDashboardCookies(dashboardID: b)
        XCTAssertNotNil(KeychainHelper.loadCredentials(dashboardID: a))
        XCTAssertEqual(try XCTUnwrap(KeychainHelper.loadConnection(dashboardID: a)).ticket, "a-ticket")
        XCTAssertEqual(try XCTUnwrap(KeychainHelper.loadCloudflareAccess(dashboardID: a, for: legacyURL)).clientID, "a-id")
        XCTAssertNotNil(KeychainHelper.loadDashboardCookies(dashboardID: a))
    }

    func testScopedCloudflareAccessStillFailsClosedOnOriginMismatch() throws {
        let a = track(UUID())
        KeychainHelper.saveCloudflareAccess(
            CloudflareAccessCredentials.from(clientID: "cid", clientSecret: "csecret")!,
            origin: "https://mac.tailnet.ts.net",
            dashboardID: a
        )
        // A token saved for one gateway never satisfies a different host.
        XCTAssertNil(KeychainHelper.loadCloudflareAccess(dashboardID: a, for: "https://other.example.com"))
        XCTAssertNotNil(KeychainHelper.loadCloudflareAccess(dashboardID: a, for: "https://mac.tailnet.ts.net"))
    }

    func testLegacyReaderRetirementKeepsPushRegistration() {
        let registration = Data("push-registration".utf8)
        KeychainHelper.savePushRegistration(registration)
        defer { KeychainHelper.clearPushRegistration() }

        LegacyDashboardReader.retireLegacy()

        XCTAssertEqual(KeychainHelper.loadPushRegistration(), registration)
    }
}
