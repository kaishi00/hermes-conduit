import XCTest
@testable import Conduit

extension NotificationE2ETests {
    func testOptInRegistersEveryKnownProfileWithoutOpeningIt() {
        XCTAssertEqual(DeviceNotificationPairing.profiles(known: ["work", "default", "work", "research"], active: "personal",
                                                        allBots: true, supported: true),
                       ["default", "personal", "research", "work"])
    }

    func testOldHostCannotTurnAllBotsOptInIntoLegacyReplacement() {
        XCTAssertEqual(DeviceNotificationPairing.profiles(known: ["work", "default"], active: "work",
                                                        allBots: true, supported: false), [])
        XCTAssertEqual(DeviceNotificationPairing.profiles(known: ["work", "default"], active: "work",
                                                        allBots: false, supported: false), ["work"])
    }

    func testRefreshedProfilesAddTheNewBot() {
        XCTAssertEqual(DeviceNotificationPairing.profiles(known: ["default", "new-bot"], active: "default",
                                                        allBots: true, supported: true), ["default", "new-bot"])
    }

    func testStatusReadsOnlyThisInstallationOnCapableHosts() {
        XCTAssertEqual(DeviceNotificationPairing.statusPath(profile: "default", installationID: "phone & one", supported: true),
                       "/api/plugins/conduit_push/e2e?installation_id=phone%20%26%20one")
        XCTAssertEqual(DeviceNotificationPairing.statusPath(profile: "work bot", installationID: "phone", supported: true),
                       "/api/plugins/conduit_push/e2e?profile=work%20bot&installation_id=phone")
        XCTAssertEqual(DeviceNotificationPairing.statusPath(profile: "work", installationID: "phone", supported: false),
                       "/api/plugins/conduit_push/e2e?profile=work")
    }

    func testOptInIsLocalAndRememberedRegistrationDoesNotUndoRevocation() {
        let suite = "MultiDeviceNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = DeviceNotificationPairing(defaults: defaults)
        let dashboard = UUID()
        XCTAssertFalse(policy.enabled)
        policy.setEnabled(true)
        policy.remember(dashboardID: dashboard, profile: "work", installationID: "phone")
        let relaunched = DeviceNotificationPairing(defaults: defaults)
        XCTAssertTrue(relaunched.enabled)
        XCTAssertFalse(relaunched.shouldRegister(dashboardID: dashboard, profile: "work", installationID: "phone"))
        XCTAssertTrue(relaunched.shouldRegister(dashboardID: dashboard, profile: "new", installationID: "phone"))
        XCTAssertTrue(relaunched.shouldRegister(dashboardID: dashboard, profile: "work", installationID: "new-phone"))
        XCTAssertTrue(relaunched.shouldRegister(dashboardID: UUID(), profile: "work", installationID: "phone"))
        relaunched.setEnabled(true)
        XCTAssertFalse(relaunched.shouldRegister(dashboardID: dashboard, profile: "work", installationID: "phone"))
        relaunched.setEnabled(false)
        relaunched.setEnabled(true)
        XCTAssertTrue(relaunched.shouldRegister(dashboardID: dashboard, profile: "work", installationID: "phone"))
    }
}
