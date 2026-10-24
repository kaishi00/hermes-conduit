import Foundation
import WebKit
import XCTest
@testable import Conduit

/// A cold launch puts the Keychain mirror back into WebKit's store only where
/// WebKit lacks the cookie. An auth proxy refreshes its session cookie (and
/// rotates the identity provider's refresh token with it) on ordinary
/// requests; writing an older mirrored copy over WebKit's newer one replays a
/// spent refresh token, which ends the session. Synthetic hosts only.
@MainActor
final class DashboardCookieRestoreTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, expiresIn: TimeInterval?, domain: String = ".example.test") -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
        ]
        if let expiresIn { properties[.expires] = Date(timeIntervalSinceNow: expiresIn) }
        return HTTPCookie(properties: properties)!
    }

    /// A dashboard on plain http (a LAN address) sets cookies without
    /// Secure. The Keychain mirror must give them back that way, or the
    /// socket upgrade over ws:// leaves them out and an auth proxy in front
    /// refuses it.
    func testMirroredCookiesKeepTheirSecureFlag() throws {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let id = UUID()
        let saved: [[String: Any]] = [
            ["name": "_proxy", "value": "plain", "domain": "127.0.0.1", "path": "/", "isSecure": false, "isHTTPOnly": true],
            ["name": "tls_only", "value": "secure", "domain": "127.0.0.1", "path": "/", "isSecure": true, "isHTTPOnly": true],
        ]
        KeychainHelper.saveDashboardCookies(try JSONSerialization.data(withJSONObject: saved), dashboardID: id)

        let restored = Dictionary(uniqueKeysWithValues: DashboardCookiePersistence.mirroredCookies(dashboardID: id).map { ($0.name, $0) })
        XCTAssertEqual(restored["_proxy"]?.isSecure, false)
        XCTAssertEqual(restored["tls_only"]?.isSecure, true)
        let header = DashboardRequestAuthorizer.cookieHeader(
            for: Array(restored.values),
            url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9119/api/ws"))
        )
        XCTAssertEqual(header, "_proxy=plain")
    }

    func testOlderSavedCopyNeverReplacesTheLiveCookie() {
        let live = cookie("_proxy", "refreshed", expiresIn: 8 * 3600)
        let saved = cookie("_proxy", "stale", expiresIn: 7 * 3600)
        XCTAssertFalse(DashboardCookiePersistence.shouldRestore(saved, over: live))
    }

    func testSavedCopyFillsAGapWhileUnexpired() {
        XCTAssertTrue(DashboardCookiePersistence.shouldRestore(cookie("_proxy", "v", expiresIn: 3600), over: nil))
        XCTAssertFalse(DashboardCookiePersistence.shouldRestore(cookie("_proxy", "v", expiresIn: -60), over: nil))
        XCTAssertTrue(DashboardCookiePersistence.shouldRestore(cookie("session", "v", expiresIn: nil), over: nil))
    }

    func testLongerLivedSavedCopyStillWins() {
        let live = cookie("_proxy", "short", expiresIn: 60)
        let saved = cookie("_proxy", "long", expiresIn: 3600)
        XCTAssertTrue(DashboardCookiePersistence.shouldRestore(saved, over: live))
    }

    func testIdentityIgnoresTheDomainsLeadingDotAndCase() {
        XCTAssertEqual(
            DashboardCookiePersistence.cookieIdentity(cookie("a", "1", expiresIn: 60, domain: ".Example.test")),
            DashboardCookiePersistence.cookieIdentity(cookie("a", "2", expiresIn: 60, domain: "example.test"))
        )
    }

    /// The live path: WebKit holds the refreshed cookie; restoring the
    /// older mirror leaves it, and a cookie WebKit lacks is added.
    func testRestoreKeepsWebKitsNewerCookieAndFillsGaps() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        await store.setCookie(cookie("_proxy", "refreshed", expiresIn: 8 * 3600))
        await DashboardCookiePersistence.restore(
            [cookie("_proxy", "stale", expiresIn: 7 * 3600), cookie("other", "added", expiresIn: 3600)],
            into: store
        )
        let byName = Dictionary(uniqueKeysWithValues: await store.allCookies().map { ($0.name, $0.value) })
        XCTAssertEqual(byName["_proxy"], "refreshed")
        XCTAssertEqual(byName["other"], "added")
        withExtendedLifetime(webView) {}
    }

    /// A Sign Out that invalidates the bridge while its restore is out:
    /// nothing the restore had still to write goes into the store, so the
    /// store clear scheduled behind the invalidation has the last word.
    func testRestoreStopsWritingOnceItsBridgeIsInvalidated() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        var invalidated = false
        var writes = 0
        await DashboardCookiePersistence.restore(
            [cookie("first", "1", expiresIn: 3600), cookie("second", "2", expiresIn: 3600)],
            into: store,
            shouldContinue: {
                // Invalidated after the first write went in.
                defer { writes += 1; if writes == 1 { invalidated = true } }
                return !invalidated
            }
        )
        let stored = await store.allCookies()
        let names = Set(stored.map(\.name))
        XCTAssertTrue(names.contains("first"))
        XCTAssertFalse(names.contains("second"), "no saved cookie goes in after the invalidation")

        await DashboardCookiePersistence.restore([cookie("third", "3", expiresIn: 3600)], into: store, shouldContinue: { false })
        let after = await store.allCookies()
        XCTAssertFalse(after.contains { $0.name == "third" })
        withExtendedLifetime(webView) {}
    }
}
