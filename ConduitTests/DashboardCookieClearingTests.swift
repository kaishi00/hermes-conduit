import Foundation
import XCTest
@testable import Conduit

/// Tests the cookie-clearing path wired into `AppState.disconnect()` for
/// issue #20, finding #3: Disconnect must not leave a reusable dashboard
/// session in the shared Foundation cookie store.
///
/// The origin-scoping logic (`cookieMatchesHost`) is the security-relevant
/// part and is exercised here through the public `clearNativeCookies(for:)`
/// surface. The WebKit `WKHTTPCookieStore` path mirrors the same matcher but
/// requires a live WebKit process to test, so it is covered by the shared
/// matcher coverage below rather than duplicated.
final class DashboardCookieClearingTests: XCTestCase {

    // MARK: - clearNativeCookies

    /// Seeds cookies for two distinct hosts, clears only the dashboard origin,
    /// and asserts the other origin's cookies survive. A blanket wipe would
    /// fail this test.
    func testClearNativeCookiesRemovesOnlyOriginMatching() throws {
        let storage = HTTPCookieStorage.shared
        let dashboardHost = "conduit-clear-dashboard.example"
        let otherHost = "conduit-clear-other.example"

        let dashboardCookie = try XCTUnwrap(cookie(name: "session", value: "dash", domain: dashboardHost))
        let otherCookie = try XCTUnwrap(cookie(name: "session", value: "other", domain: otherHost))
        storage.setCookie(dashboardCookie)
        storage.setCookie(otherCookie)
        defer {
            storage.deleteCookie(dashboardCookie)
            storage.deleteCookie(otherCookie)
        }

        DashboardCookiePersistence.clearNativeCookies(for: "https://\(dashboardHost)")

        let remaining = storage.cookies ?? []
        XCTAssertFalse(
            remaining.contains { $0.domain.lowercased().contains(dashboardHost) },
            "Dashboard-origin cookie should have been removed by clearNativeCookies."
        )
        XCTAssertTrue(
            remaining.contains { $0.domain.lowercased().contains(otherHost) },
            "Unrelated origin's cookie must survive an origin-scoped clear."
        )
    }

    func testClearNativeCookiesDoesNotMatchSiblingSuffixHosts() throws {
        // The matcher guards against bare-suffix confusion: a cookie whose
        // domain merely contains the dashboard host as a textual substring
        // (without the dot boundary that denotes a real subdomain) must not
        // be cleared when the dashboard origin is disconnected.
        let storage = HTTPCookieStorage.shared
        let dashboardHost = "conduit-subdomain.example"
        let siblingHost = "evil-\(dashboardHost)" // shares suffix, not a subdomain

        let dashboardCookie = try XCTUnwrap(cookie(name: "session", value: "dash", domain: dashboardHost))
        let siblingCookie = try XCTUnwrap(cookie(name: "session", value: "sibling", domain: siblingHost))
        storage.setCookie(dashboardCookie)
        storage.setCookie(siblingCookie)
        defer {
            storage.deleteCookie(dashboardCookie)
            storage.deleteCookie(siblingCookie)
        }

        DashboardCookiePersistence.clearNativeCookies(for: "https://\(dashboardHost)")

        let remaining = storage.cookies ?? []
        XCTAssertTrue(
            remaining.contains { $0.domain.lowercased() == siblingHost },
            "A sibling host that shares only a textual suffix must survive clearing."
        )
    }

    func testClearNativeCookiesNoopsForUnknownOrigin() throws {
        let storage = HTTPCookieStorage.shared
        let host = "conduit-noop.example"
        let retained = try XCTUnwrap(cookie(name: "session", value: "keep", domain: host))
        storage.setCookie(retained)
        defer { storage.deleteCookie(retained) }

        DashboardCookiePersistence.clearNativeCookies(for: "https://unrelated-host.example")

        XCTAssertTrue(
            (storage.cookies ?? []).contains { $0.domain.lowercased() == host },
            "Clearing an unrelated origin must leave all other cookies intact."
        )
    }

    func testClearNativeCookiesNoopsForInvalidURL() {
        // Must not trap when given an unparseable base URL.
        DashboardCookiePersistence.clearNativeCookies(for: "not a url")
        DashboardCookiePersistence.clearNativeCookies(for: "")
    }

    // MARK: - Helpers

    private func cookie(name: String, value: String, domain: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "TRUE"
        ])
    }
}
