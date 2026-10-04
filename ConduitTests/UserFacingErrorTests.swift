//
//  UserFacingErrorTests.swift
//  Conduit
//
//  Failures read as what happened and what to do, never as raw system or
//  HTTP text ("The operation couldn't be completed", "Not Found", an RPC
//  method name).
//

import XCTest
@testable import Conduit

// An extension of an existing suite rather than a new class: the hosted
// CI plan caps the classes each unit lane runs.
extension ConnectionFailureTests {
    private struct DecodingSample: Decodable { let value: Int }

    func testSystemErrorsBecomePlainLanguage() throws {
        XCTAssertEqual(
            UserFacingError.message(for: CancellationError()),
            "That was interrupted before it finished. Try again."
        )
        let decoding = try XCTUnwrap(Result { try JSONDecoder().decode(DecodingSample.self, from: Data("{}".utf8)) }.failureValue)
        XCTAssertEqual(UserFacingError.message(for: decoding), HermesError.invalidResponse.localizedDescription)
        XCTAssertEqual(
            UserFacingError.message(for: URLError(.notConnectedToInternet)),
            ConnectionFailure.offline.userMessage
        )
        XCTAssertEqual(
            UserFacingError.message(for: NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)),
            ConnectionFailure.timedOut.userMessage
        )
        XCTAssertEqual(
            UserFacingError.message(for: URLError(.cannotLoadFromNetwork)),
            ConnectionFailure.unknown.userMessage
        )
    }

    func testConduitsOwnErrorsKeepTheirText() {
        XCTAssertEqual(UserFacingError.message(for: RpcError(code: 4002, message: "denied by policy")), "denied by policy")
    }

    func testTimeoutNeverNamesTheRPCMethod() {
        let message = HermesError.timeout("slash.exec").localizedDescription
        XCTAssertFalse(message.contains("slash.exec"))
        XCTAssertTrue(message.contains("Hermes server is running"))
    }

    func testDashboardHTTPFailures() {
        func text(_ status: Int, _ detail: String) -> String {
            DashboardTicketBridgeError.http(status: status, detail: detail).localizedDescription
        }
        // The server's own explanation is kept.
        XCTAssertEqual(text(404, "Session not found"), "Session not found")
        XCTAssertEqual(text(409, "task is not in triage"), "task is not in triage")
        XCTAssertTrue(text(500, "database is locked").contains("database is locked"))
        // Bare status phrases and fetch errors are not.
        XCTAssertEqual(text(404, "Not Found"), "Your Hermes server doesn't support this yet. Update Hermes, then try again.")
        XCTAssertEqual(text(500, "Internal Server Error"), "Hermes ran into a problem on the server. Check the Hermes logs, then try again.")
        XCTAssertEqual(text(0, "TypeError: Load failed"), "Conduit couldn't reach your Hermes dashboard. Check this device's network connection and that the dashboard is running.")
        XCTAssertEqual(text(0, "AbortError: The operation was aborted."), HermesError.timeoutMessage)
        XCTAssertEqual(text(429, "Too Many Requests"), "Hermes is busy right now. Wait a moment, then try again.")
        XCTAssertEqual(text(503, "Service Unavailable"), "Your dashboard couldn't reach Hermes. Hermes may be restarting, so try again in a moment.")
        XCTAssertTrue(text(401, "Unauthorized").contains("Sign in again"))
        XCTAssertEqual(
            text(401, DashboardTicketBridgeError.signInRefreshedDetail),
            DashboardTicketBridgeError.signInRefreshedDetail,
            "Conduit's own refresh says to try again, not to sign in"
        )
        XCTAssertEqual(text(400, "Dashboard request failed (400)."), "Hermes didn't accept this request. Updating Hermes and Conduit usually fixes this.")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
