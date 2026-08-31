import WebKit
import XCTest
@testable import Conduit

/// Live-WKWebView regression coverage for the subframe navigation boundary
/// (issue #117). WebKit consults the navigation delegate for the
/// `about:blank` / `about:srcdoc` subframe documents Cloudflare's Turnstile
/// WebView requirements call for, and cancelling those navigations
/// suppresses the documents (verified empirically: a cancelled srcdoc
/// subframe never instantiates its document). These tests pin that the
/// shipped subframe policy — `ConnectionURLPolicy.isAllowedWebViewSubframe
/// Transport`, shared by the auth WebView and the ticket bridge — allows
/// them through a real engine, while custom-scheme subframes stay denied.
///
/// The probe page's MAIN frame is always allowed: loadHTMLString presents
/// an about:blank main navigation, and the real delegates' main-frame rules
/// (HTTPS/dashboard-origin pinning) are covered exhaustively by
/// `AuthWebViewNavigationPolicyTests` against the pure policy.
@MainActor
final class TurnstileSubframeBoundaryTests: XCTestCase {
    private final class BoundaryDelegate: NSObject, WKNavigationDelegate {
        /// (url, isMainFrame, allowed) for every consulted navigation.
        private(set) var decisions: [(url: String, isMainFrame: Bool, allowed: Bool)] = []

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let allowed: Bool
            if isMainFrame {
                // The probe page itself; the shipped main-frame policy is
                // pure and covered by AuthWebViewNavigationPolicyTests.
                allowed = true
            } else {
                allowed = ConnectionURLPolicy.isAllowedWebViewSubframeTransport(
                    navigationAction.request.url
                )
            }
            decisions.append((navigationAction.request.url?.absoluteString ?? "nil", isMainFrame, allowed))
            decisionHandler(allowed ? .allow : .cancel)
        }

        func subframeDecision(for urlSubstring: String) -> (url: String, isMainFrame: Bool, allowed: Bool)? {
            decisions.first { !$0.isMainFrame && $0.url.contains(urlSubstring) }
        }
    }

    func testTurnstileSubframeDocumentsLoadAndCustomSchemesStayDenied() async throws {
        let delegate = BoundaryDelegate()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            """
            <!DOCTYPE html><html><body>
            <iframe id="blank" src="about:blank"></iframe>
            <iframe id="doc" srcdoc="<p>turnstile</p>"></iframe>
            <iframe id="custom" src="conduit-boundary-probe://attacker"></iframe>
            </body></html>
            """,
            baseURL: nil
        )

        // Settle until the srcdoc document instantiates or the budget is
        // exhausted (local subframe loads settle in well under a second).
        var srcdocBody = ""
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            srcdocBody = (try? await webView.evaluateJavaScript(
                "var f=document.getElementById('doc'); f && f.contentDocument ? f.contentDocument.body.innerHTML : 'NO-DOC'"
            )) as? String ?? "EVAL-FAIL"
            if srcdocBody.contains("turnstile") { break }
        }

        // The Turnstile-required documents must actually load: the shipped
        // subframe policy allowed them and WebKit instantiated the document.
        if srcdocBody != "<p>turnstile</p>" {
            XCTFail("srcdoc body='\(srcdocBody)'; decisions=\(delegate.decisions)")
        }

        let blankDecision = try XCTUnwrap(
            delegate.subframeDecision(for: "about:blank"),
            "WebKit never consulted the delegate for the about:blank subframe; decisions=\(delegate.decisions)"
        )
        XCTAssertTrue(blankDecision.allowed, "about:blank subframes must be allowed for Turnstile; decisions=\(delegate.decisions)")
        let srcdocDecision = try XCTUnwrap(
            delegate.subframeDecision(for: "about:srcdoc"),
            "WebKit never consulted the delegate for the about:srcdoc subframe; decisions=\(delegate.decisions)"
        )
        XCTAssertTrue(srcdocDecision.allowed, "about:srcdoc subframes must be allowed for Turnstile; decisions=\(delegate.decisions)")

        // Arbitrary non-HTTP(S) subframe schemes must remain denied. WebKit
        // consulted the delegate for this frame in every observed run; if a
        // future WebKit skips it entirely, this fails loudly rather than
        // silently dropping the denial claim.
        let customDecision = try XCTUnwrap(
            delegate.subframeDecision(for: "conduit-boundary-probe://"),
            "WebKit never consulted the delegate for the custom-scheme subframe; decisions=\(delegate.decisions)"
        )
        XCTAssertFalse(customDecision.allowed, "Custom-scheme subframes must stay denied")
    }
}
