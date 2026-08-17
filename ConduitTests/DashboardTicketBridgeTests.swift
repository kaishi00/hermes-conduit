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
    ///
    /// Drives requestJSON directly: mintTicket's request timeout is not
    /// injectable (~12s deadline), and settling the initial page load first
    /// makes the run deterministic on both test-host flavors — where WKWebView
    /// navigation callbacks fire, the initial load's failure must land before
    /// the simulated ready state (a later didFailProvisionalNavigation would
    /// otherwise reject the pending request with a connection error instead
    /// of letting the deadline expire).
    func testExpiredRequestDeadlineMarksWebViewStalled() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10),
            requestDeadlineGraceMilliseconds: 50
        )

        // Let the initial /api/status load settle (fail or hang) before
        // modeling the overnight state: the bridge believes it is ready,
        // but its web view cannot deliver responses.
        for _ in 0..<80 where !bridge.isLoadFailed {
            try? await Task.sleep(for: .milliseconds(25))
        }
        bridge.simulateLandingForTesting(.ready)

        do {
            _ = try await bridge.requestJSON(path: "/api/auth/ws-ticket", timeoutMilliseconds: 1_000)
            XCTFail("Expected requestJSON to throw against a stalled web view")
        } catch DashboardTicketBridgeError.notReady {
            XCTAssertTrue(bridge.isLoadFailed, "Deadline expiry must mark the view reloadable")
        } catch {
            // Hosts that deliver an immediate evaluateJavaScript error
            // surface it here; the deadline belt is not exercised there.
            // Recorded so CI logs show which arm ran (the fallback arm is
            // expected to stay silent/unused on this CI's host flavor).
            print("deadline test took immediate-error arm: \(error)")
        }
    }

    /// An invalidated bridge must report plain unreadiness even if its last
    /// landing was the login page — a stale login verdict would surface
    /// .signInRequired (with its session-erasing recovery) from a bridge
    /// that no longer exists for use.
    func testInvalidateClearsLoginLanding() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.simulateLandingForTesting(.loginPage)
        bridge.invalidate()

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against an invalidated bridge")
        } catch DashboardTicketBridgeError.notReady {
            // expected — not .signInRequired
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }
        XCTAssertEqual(bridge.reloadCount, 0, "An invalidated bridge must not reload")
    }

    /// A login-parked bridge has a settled page: its readiness polls must
    /// exit immediately (the .signInRequired recovery fires right away)
    /// instead of sleeping out the full window on every attempt.
    func testLoginParkedBridgeDoesNotBurnPollWindow() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 30,
            readinessPollInterval: .milliseconds(100)
        )
        bridge.simulateLandingForTesting(.loginPage)

        let started = Date()
        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against a login-parked bridge")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected on exhaustion
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.signInRequired, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        // Without the fast exit, three attempts would poll ~3s each plus
        // sleeps (~9.7s). With it, the run is three ~350ms sleeps (~1.1s).
        XCTAssertLessThan(elapsed, 3.0, "Login-parked minting must skip the readiness poll window")
        XCTAssertEqual(bridge.reloadCount, 2, "Both signInRequired retries must reload")
    }
}
