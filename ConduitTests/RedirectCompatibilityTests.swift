import XCTest
@testable import Conduit

/// Interrupt sends `session.redirect`; a Hermes without it must fall back to
/// `session.interrupt` + `prompt.submit` instead of showing an error.
final class RedirectCompatibilityTests: XCTestCase {
    func testTuiGatewayUnknownMethodFallsBack() {
        // tui_gateway/server.py: _err(rid, -32601, f"unknown method: {method}")
        XCTAssertTrue(AppState.isUnsupportedRedirect(code: -32601, message: "unknown method: session.redirect"))
        XCTAssertTrue(AppState.isUnsupportedRedirect(code: nil, message: "unknown method: session.redirect"))
    }

    func testKnownUnsupportedShapesStillFallBack() {
        XCTAssertTrue(AppState.isUnsupportedRedirect(code: 4010, message: "anything"))
        XCTAssertTrue(AppState.isUnsupportedRedirect(code: nil, message: "Method not found"))
        XCTAssertTrue(AppState.isUnsupportedRedirect(code: nil, message: "this gateway does not support active-turn redirect"))
    }

    func testOtherFailuresAreNotTreatedAsUnsupported() {
        XCTAssertFalse(AppState.isUnsupportedRedirect(code: 4040, message: "session not found"))
        XCTAssertFalse(AppState.isUnsupportedRedirect(code: -32603, message: "internal error"))
    }
}
