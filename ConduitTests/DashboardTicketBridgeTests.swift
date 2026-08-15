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
    func testColdBridgeMintTicketRetriesReloadAndSurfacesNotReady() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1", // nothing listens: page load fails fast
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw on a cold bridge")
        } catch DashboardTicketBridgeError.notReady {
            // expected
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }

        XCTAssertEqual(bridge.reloadCount, 2, "Both retries must re-attempt the page load")
    }
}
