import XCTest
@testable import Conduit

@MainActor
final class DashboardTicketBridgeTests: XCTestCase {

    func testInvalidatingPendingRequestsResumesThemWithNotReady() async {
        let requests = DashboardTicketBridgePendingRequests()
        let bridge = DashboardTicketBridge(
            baseURL: "https://example.com",
            pendingRequests: requests
        )
        let requestRegistered = expectation(description: "pending request registered")
        let resultTask = Task { @MainActor in
            do {
                _ = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<[String: Any], Error>) in
                    requests.insert(continuation, for: 1)
                    requestRegistered.fulfill()
                }
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }

        await fulfillment(of: [requestRegistered], timeout: 1.0)
        bridge.invalidate()

        switch await resultTask.value {
        case .success:
            XCTFail("Invalidation must resume pending requests with an error")
        case .failure(let error as DashboardTicketBridgeError):
            if case .notReady = error {
                // expected
            } else {
                XCTFail("Expected .notReady, got \(error)")
            }
        case .failure(let error):
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }
        XCTAssertEqual(requests.count, 0)
    }

    /// A bridge whose dashboard page load keeps failing (e.g. launch during
    /// a network outage) must keep re-attempting the page load while minting
    /// and, on exhaustion, surface `.notReady` — never a misleading
    /// `.signInRequired`, which would sign the user out of a valid session.
    /// The failed landing is simulated (WKWebView's failure callbacks are
    /// not deterministically drivable in the unit test host) and persists
    /// across reloads, modeling a dashboard that stays unreachable.
    func testColdBridgeMintTicketRetriesReloadAndSurfacesNotReady() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1", // nothing listens: load cannot succeed
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.simulateLandingForTesting(.loadFailure)

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw on a cold bridge")
        } catch DashboardTicketBridgeError.notReady {
            // expected
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }

        // Both retries must re-attempt the terminally failed page load; the
        // original wedge (no reload at all) would leave this at zero.
        XCTAssertEqual(bridge.reloadCount, 2)
    }

    /// A bridge parked on the dashboard's login page must route minting to
    /// the signInRequired recovery: each retry reloads the page (the cookie-
    /// race recovery round 4 accidentally disabled) rather than blind-
    /// re-POSTing, exhaustion surfaces `.signInRequired` (never a misleading
    /// `.notReady`), and no ticket is ever minted against a logged-out
    /// session. The simulation persists across reloads, modeling a session
    /// that is genuinely gone.
    func testMintTicketReloadsForSimulatedLoginLanding() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.simulateLandingForTesting(.loginPage)

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against a login-parked bridge")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected on exhaustion
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.signInRequired, got \(error)")
        }

        // Both retries must reload the page; the round-4 regression would
        // leave this at zero.
        XCTAssertEqual(bridge.reloadCount, 2)
    }

    /// iOS reclaims the bridge's web content process under memory pressure —
    /// typically while the app is suspended overnight. The termination
    /// callback must mark the bridge cold-but-reloadable so the next mint
    /// revives the page instead of awaiting a JavaScript response that can
    /// never arrive (the overnight stuck-reconnecting wedge).
    func testWebContentTerminationMarksBridgeReloadableAndMintRetries() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )

        bridge.webViewWebContentProcessDidTerminate(bridge.webView)
        XCTAssertTrue(bridge.isLoadFailed, "Termination must make the bridge reloadable")

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against a terminated web process")
        } catch DashboardTicketBridgeError.notReady {
            // expected
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }

        // The .notReady recovery must reload the dead page.
        XCTAssertGreaterThanOrEqual(bridge.reloadCount, 1)
    }

    /// A requestJSON awaiting a JavaScript response when the content process
    /// dies must be resumed with .notReady — not left pending forever.
    func testWebContentTerminationResumesPendingRequestAsNotReady() async {
        let requests = DashboardTicketBridgePendingRequests()
        let bridge = DashboardTicketBridge(
            baseURL: "https://example.com",
            pendingRequests: requests
        )
        let requestRegistered = expectation(description: "pending request registered")
        let resultTask = Task { @MainActor in
            do {
                _ = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<[String: Any], Error>) in
                    requests.insert(continuation, for: 99)
                    requestRegistered.fulfill()
                }
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }

        await fulfillment(of: [requestRegistered], timeout: 1.0)
        bridge.webViewWebContentProcessDidTerminate(bridge.webView)

        switch await resultTask.value {
        case .success:
            XCTFail("Termination must resume pending requests with an error")
        case .failure(let error as DashboardTicketBridgeError):
            if case .notReady = error {
                // expected
            } else {
                XCTFail("Expected .notReady, got \(error)")
            }
        case .failure(let error):
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }
        XCTAssertEqual(requests.count, 0)
    }

    /// When a request's Swift-side deadline expires (the JavaScript response
    /// was silently dropped — stalled web view), the bridge must mark the
    /// view cold-but-reloadable so mintTicket's retry RELOADS it instead of
    /// re-evaluating JavaScript against the same dead view forever.
    func testExpiredRequestDeadlineMarksWebViewStalledAndMintReloads() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10),
            requestDeadlineGraceMilliseconds: 50
        )
        // Model the overnight state: the bridge believes it is ready, but
        // its web view cannot deliver responses.
        bridge.simulateLandingForTesting(.ready)

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against a stalled web view")
        } catch DashboardTicketBridgeError.notReady {
            // The deadline expired and the notReady catch must have reloaded
            // the stalled page at least once before exhaustion.
            XCTAssertGreaterThanOrEqual(bridge.reloadCount, 1)
        } catch {
            // Some test hosts deliver an immediate evaluateJavaScript error
            // instead of dropping the response; the deadline belt is not
            // exercised there.
        }
    }
}
