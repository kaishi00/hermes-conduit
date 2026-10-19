import Foundation
import XCTest
@testable import Conduit

/// What a build tells the push relay about itself: the bundle ID it
/// registers under and the relay it uses when Settings is blank. Both come
/// from the build, so a build under another bundle ID or with its own relay
/// works without editing source.
final class PushRelayBuildIdentityTests: XCTestCase {
    func testRegistrationPresentsTheAppsOwnBundleID() {
        XCTAssertEqual(
            PushNotificationService.registrationBundleID("io.example.conduit"),
            "io.example.conduit",
            "a build under its own bundle ID registers as that app, not as upstream's"
        )
        XCTAssertEqual(PushNotificationService.registrationBundleID("com.milim.relay"), "com.milim.relay")
        XCTAssertEqual(PushNotificationService.registrationBundleID(nil), "com.milim.relay")
        XCTAssertEqual(PushNotificationService.registrationBundleID(""), "com.milim.relay")
    }

    func testRunningAppRegistersUnderItsBundleIdentifier() throws {
        let identifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertEqual(PushNotificationService.registrationBundleID(Bundle.main.bundleIdentifier), identifier)
    }

    func testDefaultRelayComesFromTheBuildWhenItNamesAnHTTPSRelay() {
        func relay(_ value: Any?) -> String {
            let info: [String: Any] = value.map { [PushNotificationService.defaultRelayInfoKey: $0] } ?? [:]
            return PushNotificationService.buildDefaultRelayURL(info: info).absoluteString
        }
        XCTAssertEqual(relay("https://relay.example.com"), "https://relay.example.com")
        XCTAssertEqual(relay("  https://relay.example.com/push \n"), "https://relay.example.com/push")
        XCTAssertEqual(relay("HTTPS://relay.example.com"), "HTTPS://relay.example.com")
    }

    func testDefaultRelayFallsBackToUpstreamWhenTheBuildNamesNoUsableRelay() {
        let upstream = "https://push.milim.dev"
        XCTAssertEqual(PushNotificationService.buildDefaultRelayURL(info: nil).absoluteString, upstream)
        XCTAssertEqual(PushNotificationService.buildDefaultRelayURL(info: [:]).absoluteString, upstream)
        let unusable: [Any] = [
            "",
            "   ",
            // An unset build setting that was never expanded.
            "$(CONDUIT_DEFAULT_RELAY_URL)",
            "https:",
            "relay.example.com",
            // The relay receives a bearer credential: cleartext is refused,
            // even to loopback, which only Settings may choose.
            "http://relay.example.com",
            "http://localhost:8080",
            "ftp://relay.example.com",
            42,
        ]
        for value in unusable {
            XCTAssertEqual(
                PushNotificationService.buildDefaultRelayURL(
                    info: [PushNotificationService.defaultRelayInfoKey: value]
                ).absoluteString,
                upstream,
                "\(value) must not become the default relay"
            )
        }
    }

    func testAppInfoPlistCarriesTheBuildsDefaultRelay() throws {
        // The test host is the app, so its Info.plist is Bundle.main's.
        let appInfo = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNotNil(
            appInfo[PushNotificationService.defaultRelayInfoKey] as? String,
            "Info.plist passes CONDUIT_DEFAULT_RELAY_URL through, empty for upstream builds"
        )
        XCTAssertEqual(
            PushNotificationService.defaultRelayURL,
            PushNotificationService.buildDefaultRelayURL(info: Bundle.main.infoDictionary)
        )
    }
}
