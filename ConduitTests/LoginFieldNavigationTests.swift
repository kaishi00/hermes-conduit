import XCTest
@testable import Conduit

/// Unit coverage for the sign-in steps' return-key focus chains (issue #117,
/// keyboard covering the Cloudflare fields) and for addresses typed without
/// a scheme. The chains are what keep every field reachable one-handed on
/// compact iPhones: each field either hands focus to the next or — only at
/// the end of its chain — submits.
final class LoginFieldNavigationTests: XCTestCase {
    private func chain(from start: LoginField, cloudflareTokenEntryEnabled: Bool) -> [LoginField] {
        var visited: [LoginField] = []
        var current: LoginField? = start
        while let field = current {
            visited.append(field)
            current = field.submitDestination(cloudflareTokenEntryEnabled: cloudflareTokenEntryEnabled)
        }
        return visited
    }

    func testAddressStepChainCoversCloudflareFieldsWhenTokenEntryEnabled() {
        XCTAssertEqual(
            chain(from: .server, cloudflareTokenEntryEnabled: true),
            [.server, .cloudflareClientID, .cloudflareClientSecret],
            "Both Cloudflare fields must sit on the address step's return-key chain"
        )
    }

    func testAddressSubmitsDirectlyWhenTokenEntryDisabled() {
        XCTAssertEqual(chain(from: .server, cloudflareTokenEntryEnabled: false), [.server])
        XCTAssertEqual(LoginField.cloudflareClientID.submitDestination(cloudflareTokenEntryEnabled: false), .cloudflareClientSecret)
        XCTAssertNil(LoginField.cloudflareClientSecret.submitDestination(cloudflareTokenEntryEnabled: false))
    }

    func testSignInStepChainIsUsernameThenPassword() {
        XCTAssertEqual(chain(from: .username, cloudflareTokenEntryEnabled: false), [.username, .password])
        // The Cloudflare token is on the address step: it never follows the
        // password.
        XCTAssertEqual(chain(from: .username, cloudflareTokenEntryEnabled: true), [.username, .password])
    }

    func testAddressReturnDoesNotContinueWhileEnteringCloudflareCredentials() {
        XCTAssertEqual(
            LoginField.server.submitDestination(cloudflareTokenEntryEnabled: true),
            .cloudflareClientID,
            "Return on the address must advance to the Cloudflare Client ID, never trigger Continue"
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
        // The address flips between submit and continue depending on whether
        // the Cloudflare token entry follows it.
        XCTAssertFalse(LoginField.server.submits(cloudflareTokenEntryEnabled: true))
        XCTAssertTrue(LoginField.server.submits(cloudflareTokenEntryEnabled: false))
        XCTAssertTrue(LoginField.password.submits(cloudflareTokenEntryEnabled: true))
        XCTAssertTrue(LoginField.cloudflareClientSecret.submits(cloudflareTokenEntryEnabled: true))
    }

    func testURLAloneEnablesProviderDiscovery() {
        XCTAssertFalse(LoginView.hasConnectableInput(serverURL: "   "))
        XCTAssertTrue(LoginView.hasConnectableInput(serverURL: "https://hermes.example"))
        XCTAssertTrue(LoginView.hasConnectableInput(serverURL: " https://hermes.example "))
        XCTAssertTrue(LoginView.hasConnectableInput(serverURL: "mac.tailnet.ts.net:9119"))
    }

    // MARK: - Addresses without a scheme

    func testAddressWithSchemeIsTriedAsTyped() {
        XCTAssertEqual(LoginAddress.candidates(" https://hermes.example/ "), ["https://hermes.example/"])
        XCTAssertEqual(LoginAddress.candidates("http://192.168.1.28:9119"), ["http://192.168.1.28:9119"])
        // Plain http to a remote host stays one candidate, so the address
        // policy reports it as insecure rather than quietly trying https.
        XCTAssertEqual(LoginAddress.candidates("http://203.0.113.10:9119"), ["http://203.0.113.10:9119"])
        XCTAssertEqual(LoginAddress.candidates("   "), [])
    }

    func testRemoteHostWithoutSchemeTriesOnlyHTTPS() {
        XCTAssertEqual(LoginAddress.candidates("hermes.example.com"), ["https://hermes.example.com"])
        XCTAssertEqual(LoginAddress.candidates("203.0.113.10:9119"), ["https://203.0.113.10:9119"])
    }

    func testTailscaleNameTriesHTTPSThenHTTP() {
        XCTAssertEqual(
            LoginAddress.candidates("mac.tailnet.ts.net:9119"),
            ["https://mac.tailnet.ts.net:9119", "http://mac.tailnet.ts.net:9119"]
        )
    }

    func testLocalAddressesTryHTTPFirst() {
        XCTAssertEqual(
            LoginAddress.candidates("192.168.1.28:9119"),
            ["http://192.168.1.28:9119", "https://192.168.1.28:9119"]
        )
        XCTAssertEqual(
            LoginAddress.candidates("100.101.102.103:9119"),
            ["http://100.101.102.103:9119", "https://100.101.102.103:9119"]
        )
        XCTAssertEqual(
            LoginAddress.candidates("localhost:9119"),
            ["http://localhost:9119", "https://localhost:9119"]
        )
    }

    func testMalformedAddressHasNoValidCandidate() {
        for typed in ["ftp://hermes.example", "https://", "https://user:pass@hermes.example"] {
            XCTAssertTrue(
                LoginAddress.candidates(typed).allSatisfy { (try? ConnectionURLPolicy.normalizedBaseURL($0)) == nil },
                "\(typed) must fail the address policy"
            )
        }
    }

    func testOnlyAWrongSchemeMovesToTheNextCandidate() {
        XCTAssertTrue(LoginAddress.shouldTryNextCandidate(after: URLError(.secureConnectionFailed)))
        XCTAssertTrue(LoginAddress.shouldTryNextCandidate(after: URLError(.cannotConnectToHost)))
        XCTAssertTrue(LoginAddress.shouldTryNextCandidate(after: AuthClientError.providerDiscoveryFailed(status: 400, detail: "")))
        XCTAssertFalse(LoginAddress.shouldTryNextCandidate(after: URLError(.timedOut)))
        // Both schemes look up the same name.
        XCTAssertFalse(LoginAddress.shouldTryNextCandidate(after: URLError(.cannotFindHost)))
        XCTAssertFalse(LoginAddress.shouldTryNextCandidate(after: URLError(.dnsLookupFailed)))
        XCTAssertFalse(LoginAddress.shouldTryNextCandidate(after: URLError(.notConnectedToInternet)))
        XCTAssertFalse(LoginAddress.shouldTryNextCandidate(after: CancellationError()))
        XCTAssertFalse(LoginAddress.shouldTryNextCandidate(after: AuthClientError.cloudflareServiceTokenRejected))
    }

    func testListsShowTheAddressWithoutItsScheme() {
        XCTAssertEqual(LoginAddress.displayHost("http://mac.tailnet.ts.net:9119"), "mac.tailnet.ts.net:9119")
        XCTAssertEqual(LoginAddress.displayHost("https://hermes.example/team"), "hermes.example/team")
        XCTAssertEqual(LoginAddress.bestGuess("192.168.1.28:9119"), "http://192.168.1.28:9119")
        XCTAssertEqual(LoginAddress.bestGuess("hermes.example"), "https://hermes.example")
    }
}
