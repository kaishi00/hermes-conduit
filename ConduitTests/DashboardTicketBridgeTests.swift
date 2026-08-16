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
    ///
    /// The WKWebView navigation callbacks are not deterministic in the unit
    /// test host (a refused port may never report failure), so the reload
    /// assertion is conditional on observing a failed load; the exhaustion
    /// contract is unconditional. The reload-recovers path is covered
    /// end-to-end by the chaos-gateway verification described in the PR.
    func testColdBridgeMintTicketRetriesReloadAndSurfacesNotReady() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1", // nothing listens: load cannot succeed
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )

        // Give the initial page load a moment to terminally fail. A load
        // still in flight must NOT be reloaded (slow-link protection).
        for _ in 0..<40 where !bridge.isLoadFailed {
            try? await Task.sleep(for: .milliseconds(25))
        }

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw on a cold bridge")
        } catch DashboardTicketBridgeError.notReady {
            // expected
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }

        if bridge.isLoadFailed {
            XCTAssertGreaterThanOrEqual(bridge.reloadCount, 1)
        }
    }

    /// A bridge parked on the dashboard's login page must route minting to
    /// the signInRequired recovery: each retry reloads the page (the cookie-
    /// race recovery round 4 accidentally disabled) rather than blind-
    /// re-POSTing, exhaustion surfaces `.signInRequired` (never a misleading
    /// `.notReady`), and no ticket is ever minted against a logged-out
    /// session. The simulation persists across reloads, modeling a session
    /// that is genuinely gone — which also makes the flow deterministic
    /// regardless of when the initial page load settles.
    func testMintTicketReloadsForSimulatedLoginLanding() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.simulateLoginLandingForTesting()

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
}
