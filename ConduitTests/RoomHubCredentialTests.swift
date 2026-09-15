//
//  RoomHubCredentialTests.swift
//  Conduit
//
//  Credential isolation for the ANVIL Room read seam: the Hub bearer token
//  is a dashboard-scoped Keychain record, never a generic bucket. Two
//  dashboards holding tokens for two Hub deployments must be unable to
//  read, overwrite, or clear each other's credential.
//

import Foundation
import XCTest
@testable import Conduit

final class RoomHubCredentialTests: XCTestCase {
    private var backend: InMemoryKeychainBackend!

    override func setUp() {
        super.setUp()
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
    }

    override func tearDown() {
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        super.tearDown()
    }

    func testSaveLoadRoundTripWithinDashboard() {
        let dashboard = UUID()
        let credential = RoomHubCredential(hubBaseURL: "https://hub.test", token: "token-a")

        KeychainHelper.saveRoomHubCredential(credential, dashboardID: dashboard)

        XCTAssertEqual(KeychainHelper.loadRoomHubCredential(dashboardID: dashboard), credential)
    }

    func testCredentialCannotLeakAcrossDashboards() {
        let dashboardA = UUID()
        let dashboardB = UUID()
        KeychainHelper.saveRoomHubCredential(
            RoomHubCredential(hubBaseURL: "https://hub-a.test", token: "token-a"),
            dashboardID: dashboardA
        )
        KeychainHelper.saveRoomHubCredential(
            RoomHubCredential(hubBaseURL: "https://hub-b.test", token: "token-b"),
            dashboardID: dashboardB
        )

        XCTAssertEqual(
            KeychainHelper.loadRoomHubCredential(dashboardID: dashboardA)?.token,
            "token-a"
        )
        XCTAssertEqual(
            KeychainHelper.loadRoomHubCredential(dashboardID: dashboardB)?.token,
            "token-b",
            "Dashboard B must never read dashboard A's token"
        )
    }

    func testClearingOneDashboardLeavesTheOtherUntouched() {
        let dashboardA = UUID()
        let dashboardB = UUID()
        KeychainHelper.saveRoomHubCredential(
            RoomHubCredential(hubBaseURL: "https://hub-a.test", token: "token-a"),
            dashboardID: dashboardA
        )
        KeychainHelper.saveRoomHubCredential(
            RoomHubCredential(hubBaseURL: "https://hub-b.test", token: "token-b"),
            dashboardID: dashboardB
        )

        KeychainHelper.clearRoomHubCredential(dashboardID: dashboardA)

        XCTAssertNil(KeychainHelper.loadRoomHubCredential(dashboardID: dashboardA))
        XCTAssertEqual(
            KeychainHelper.loadRoomHubCredential(dashboardID: dashboardB)?.token,
            "token-b",
            "Clearing dashboard A's credential must not reach dashboard B"
        )
    }

    func testOverwriteReplacesOnlyTheSameDashboardsRecord() {
        let dashboardA = UUID()
        let dashboardB = UUID()
        KeychainHelper.saveRoomHubCredential(
            RoomHubCredential(hubBaseURL: "https://hub-a.test", token: "old"),
            dashboardID: dashboardA
        )
        KeychainHelper.saveRoomHubCredential(
            RoomHubCredential(hubBaseURL: "https://hub-b.test", token: "token-b"),
            dashboardID: dashboardB
        )

        KeychainHelper.saveRoomHubCredential(
            RoomHubCredential(hubBaseURL: "https://hub-a2.test", token: "new"),
            dashboardID: dashboardA
        )

        XCTAssertEqual(
            KeychainHelper.loadRoomHubCredential(dashboardID: dashboardA),
            RoomHubCredential(hubBaseURL: "https://hub-a2.test", token: "new")
        )
        XCTAssertEqual(
            KeychainHelper.loadRoomHubCredential(dashboardID: dashboardB)?.token,
            "token-b"
        )
    }

    @MainActor
    func testForDashboardBuildsClientFromScopedRecordsOnly() throws {
        let dashboardA = UUID()
        let dashboardB = UUID()
        KeychainHelper.saveRoomHubCredential(
            RoomHubCredential(hubBaseURL: "https://hub-a.test", token: "token-a"),
            dashboardID: dashboardA
        )

        let clientA = try RoomProjectionClient.forDashboard(dashboardA)
        XCTAssertEqual(clientA.credential.token, "token-a")
        XCTAssertEqual(clientA.credential.hubBaseURL, "https://hub-a.test")

        XCTAssertThrowsError(try RoomProjectionClient.forDashboard(dashboardB)) { error in
            guard case RoomProjectionError.missingCredential = error else {
                return XCTFail("Dashboard B must see missingCredential, got \(error)")
            }
        }
    }
}
