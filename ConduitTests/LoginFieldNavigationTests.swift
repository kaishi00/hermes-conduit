import XCTest
@testable import Conduit

/// Unit coverage for the login form's return-key focus chain (issue #117,
/// keyboard covering the Cloudflare fields). The chain itself is what keeps
/// every field reachable one-handed on compact iPhones: each field either
/// hands focus to the next or — only at the end of the chain — submits.
final class LoginFieldNavigationTests: XCTestCase {
    func testFocusChainCoversCloudflareFieldsWhenTokenEntryEnabled() {
        var visited: [LoginField] = []
        var current: LoginField? = .server
        while let field = current {
            visited.append(field)
            current = field.submitDestination(cloudflareTokenEntryEnabled: true)
        }

        XCTAssertEqual(
            visited,
            [.server, .username, .password, .cloudflareClientID, .cloudflareClientSecret],
            "Every field, including both Cloudflare fields, must sit on the return-key focus chain"
        )
    }

    func testPasswordSubmitsDirectlyWhenTokenEntryDisabled() {
        XCTAssertNil(LoginField.password.submitDestination(cloudflareTokenEntryEnabled: false))
        XCTAssertEqual(LoginField.server.submitDestination(cloudflareTokenEntryEnabled: false), .username)
        XCTAssertEqual(LoginField.username.submitDestination(cloudflareTokenEntryEnabled: false), .password)
        XCTAssertEqual(LoginField.cloudflareClientID.submitDestination(cloudflareTokenEntryEnabled: false), .cloudflareClientSecret)
        XCTAssertNil(LoginField.cloudflareClientSecret.submitDestination(cloudflareTokenEntryEnabled: false))
    }

    func testPasswordReturnDoesNotConnectWhileEnteringCloudflareCredentials() {
        XCTAssertEqual(
            LoginField.password.submitDestination(cloudflareTokenEntryEnabled: true),
            .cloudflareClientID,
            "Return on the password field must advance to the Cloudflare Client ID, never trigger Connect"
        )
    }

    func testKeyboardReturnSubmitsOnlyAtChainEnd() {
        // SubmitLabel itself is not Equatable, so tests assert on the pure
        // decision the label derives from: submit only at the chain's end.
        for field in LoginField.allCases {
            XCTAssertEqual(
                field.submits(cloudflareTokenEntryEnabled: true),
                field.submitDestination(cloudflareTokenEntryEnabled: true) == nil,
                "\(field) submit decision must match its chain position"
            )
            XCTAssertEqual(
                field.submits(cloudflareTokenEntryEnabled: false),
                field.submitDestination(cloudflareTokenEntryEnabled: false) == nil,
                "\(field) submit decision must match its chain position"
            )
        }
        // The password field flips between submit and continue depending on
        // whether the Cloudflare token entry follows it.
        XCTAssertFalse(LoginField.password.submits(cloudflareTokenEntryEnabled: true))
        XCTAssertTrue(LoginField.password.submits(cloudflareTokenEntryEnabled: false))
        XCTAssertTrue(LoginField.cloudflareClientSecret.submits(cloudflareTokenEntryEnabled: true))
    }
}
