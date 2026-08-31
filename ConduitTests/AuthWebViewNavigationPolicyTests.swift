import Foundation
import XCTest
@testable import Conduit

/// Boundary coverage for the authentication WebView's navigation policy
/// (issue #117). Main-frame rules preserve the dashboard-origin boundary —
/// unpinned sign-in may traverse the legitimate Cloudflare/IdP redirect
/// chain, pinned navigation cannot escape the dashboard origin. Subframes
/// additionally accept the `about:blank` / `about:srcdoc` documents
/// Cloudflare's Turnstile WebView requirements name; the tests below pin
/// that this allowance cannot be escalated to a main-frame escape or to
/// arbitrary schemes.
final class AuthWebViewNavigationPolicyTests: XCTestCase {
    private let dashboard = URL(string: "https://hermes.example")!

    private func decide(
        _ url: URL?,
        mainFrame: Bool,
        pinned: Bool = false,
        expected: URL? = nil
    ) -> AuthWebViewNavigationPolicy.Decision {
        AuthWebViewNavigationPolicy.decide(
            url: url,
            isMainFrame: mainFrame,
            hasPinnedDashboardOrigin: pinned,
            expectedDashboardURL: expected ?? dashboard
        )
    }

    // MARK: - Subframes (Turnstile / identity-provider operation)

    func testSubframeAboutBlankAndSrcdocAreAllowedForTurnstile() throws {
        XCTAssertEqual(
            decide(URL(string: "about:blank"), mainFrame: false),
            .allow,
            "Turnstile's WebView requirements call for about:blank subframe documents"
        )
        XCTAssertEqual(
            decide(URL(string: "about:srcdoc"), mainFrame: false),
            .allow,
            "Turnstile's WebView requirements call for about:srcdoc subframe documents"
        )
    }

    func testSubframeHTTPSRemainsAllowedForIdentityProvidersAndChallenges() {
        XCTAssertEqual(decide(URL(string: "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/b/orchestrate/encrypted/v1"), mainFrame: false), .allow)
        XCTAssertEqual(decide(URL(string: "https://accounts.google.com/o/oauth2/auth"), mainFrame: false), .allow)
    }

    func testSubframeArbitrarySchemesAndAboutVariantsRemainDenied() {
        XCTAssertEqual(decide(URL(string: "about:config"), mainFrame: false), .cancel)
        XCTAssertEqual(decide(URL(string: "ftp://challenges.cloudflare.com/x"), mainFrame: false), .cancel)
        XCTAssertEqual(decide(URL(string: "conduit-probe://attacker"), mainFrame: false), .cancel)
        XCTAssertEqual(decide(URL(string: "data:text/html,<script>alert(1)</script>"), mainFrame: false), .cancel)
        XCTAssertEqual(decide(nil, mainFrame: false), .cancel)
    }

    func testSubframeAllowanceIsIndependentOfDashboardPin() {
        // Turnstile documents must keep loading inside authenticated
        // dashboard pages too; the pin only governs MAIN frames.
        XCTAssertEqual(decide(URL(string: "about:blank"), mainFrame: false, pinned: true), .allow)
        XCTAssertEqual(decide(URL(string: "about:srcdoc"), mainFrame: false, pinned: true), .allow)
    }

    // MARK: - Main frames before origin pinning

    func testUnpinnedMainFrameHTTPSAuthChainRemainsAllowed() {
        XCTAssertEqual(decide(URL(string: "https://hermes.example/login"), mainFrame: true), .allow)
        XCTAssertEqual(decide(URL(string: "https://tenant.cloudflareaccess.com/cdn-cgi/access/login/hermes.example"), mainFrame: true), .allow)
        XCTAssertEqual(decide(URL(string: "https://accounts.google.com/o/oauth2/auth"), mainFrame: true), .allow)
    }

    func testUnpinnedMainFrameInsecureAndMalformedTransportsRemainBlocked() {
        XCTAssertEqual(decide(URL(string: "http://untrusted.example/login"), mainFrame: true), .cancel)
        XCTAssertEqual(decide(URL(string: "https://user:pass@hermes.example/login"), mainFrame: true), .cancel)
        XCTAssertEqual(decide(URL(string: "about:blank"), mainFrame: true), .cancel, "about: allowance is subframe-only")
        XCTAssertEqual(decide(URL(string: "about:srcdoc"), mainFrame: true), .cancel, "about: allowance is subframe-only")
        XCTAssertEqual(decide(nil, mainFrame: true), .cancel)
    }

    func testUnpinnedMainFrameLocalHTTPRemainsAllowed() {
        // Existing rule: HTTP only for loopback/private LAN/Tailscale hosts.
        XCTAssertEqual(decide(URL(string: "http://192.168.1.200:9119/login"), mainFrame: true), .allow)
    }

    // MARK: - Main frames after origin pinning

    func testPinnedMainFrameStaysBoundToDashboardOrigin() {
        XCTAssertEqual(decide(URL(string: "https://hermes.example/api/status"), mainFrame: true, pinned: true), .allow)
        XCTAssertEqual(decide(URL(string: "https://hermes.example/login"), mainFrame: true, pinned: true), .allow)
        XCTAssertEqual(decide(URL(string: "https://tenant.cloudflareaccess.com/cdn-cgi/access/login"), mainFrame: true, pinned: true), .cancel)
        XCTAssertEqual(decide(URL(string: "https://accounts.google.com/signin"), mainFrame: true, pinned: true), .cancel)
        XCTAssertEqual(decide(URL(string: "https://hermes.example.evil.example/login"), mainFrame: true, pinned: true), .cancel)
    }

    func testPinnedMainFrameCannotEscapeViaAboutDocuments() {
        XCTAssertEqual(
            decide(URL(string: "about:blank"), mainFrame: true, pinned: true),
            .cancel,
            "The Turnstile subframe allowance must not open a main-frame escape hatch"
        )
        XCTAssertEqual(decide(URL(string: "about:srcdoc"), mainFrame: true, pinned: true), .cancel)
    }

    func testPinnedMainFrameWithUnknownExpectedOriginFailsClosed() {
        // Call the policy directly: the test helper's default substitutes
        // the dashboard origin, and this case must exercise a genuinely
        // absent expectation.
        XCTAssertEqual(
            AuthWebViewNavigationPolicy.decide(
                url: URL(string: "https://hermes.example/login"),
                isMainFrame: true,
                hasPinnedDashboardOrigin: true,
                expectedDashboardURL: nil
            ),
            .cancel
        )
    }

    // MARK: - Subframe transport helper (shared with DashboardTicketBridge)

    func testSubframeTransportHelperClassification() {
        XCTAssertTrue(ConnectionURLPolicy.isAllowedWebViewSubframeTransport(URL(string: "about:blank")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedWebViewSubframeTransport(URL(string: "about:srcdoc")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedWebViewSubframeTransport(URL(string: "https://challenges.cloudflare.com/x")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedWebViewSubframeTransport(URL(string: "about:other")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedWebViewSubframeTransport(URL(string: "conduit-probe://attacker")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedWebViewSubframeTransport(nil))
        // Case-insensitivity of the about: document tail.
        XCTAssertTrue(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "ABOUT:BLANK")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "https://blank.example")))
        // The classifier is an exact-tail match and fails closed on every
        // near-miss; these pins keep a future parser refactor from silently
        // loosening the contract.
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "about://blank")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "about:blank?x=1")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "about:blank#frag")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "about:blank/extra")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "about:blank.evil.example")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "about:srcdoc.evil.example")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "about:%62lank")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "https://hermes.example/?about:blank")))
        XCTAssertFalse(ConnectionURLPolicy.isTurnstileRequiredSubframeDocument(URL(string: "xabout:blank")))
    }
}
