//
//  AppStatePendingLoginFailureTests.swift
//  Conduit
//
//  Regression coverage for the typed AppState → LoginView sign-in failure
//  handoff. The old contract wrote a formatted string into
//  `errorMessage`, which nothing on the login screen rendered and which the
//  connected composer banner could later resurface stale. The handoff is now
//  a typed `pendingLoginFailure` presentation, consumed once by LoginView.
//

import XCTest
@testable import Conduit

@MainActor
final class AppStatePendingLoginFailureTests: XCTestCase {
    // MARK: - Harness

    private func makeAppState() -> AppState {
        let suite = "AppStatePendingLoginFailureTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(
            defaults: defaults,
            loadSavedConnection: false
        )
    }

    // MARK: - requireSignIn typed handoff

    func testRequireSignInHandsOffTypedPendingFailureInsteadOfStringError() {
        let appState = makeAppState()

        appState.requireSignIn(message: "Hermes rejected the saved session.")

        XCTAssertTrue(appState.showLogin, "requireSignIn must land on the login screen")
        XCTAssertEqual(
            appState.pendingLoginFailure?.title,
            "Sign-in didn’t complete",
            "The requireSignIn handoff must arrive as a typed presentation, not a bare string"
        )
        XCTAssertEqual(appState.pendingLoginFailure?.message, "Hermes rejected the saved session.")
        XCTAssertNil(appState.pendingLoginFailure?.helpDestination)
        XCTAssertFalse(appState.pendingLoginFailure?.offersRecoveryActions ?? true)
        XCTAssertNil(
            appState.errorMessage,
            "Login-bound failures must not leak into the connected composer banner"
        )
    }

    func testPendingLoginFailureCarriesFullClassifiedPresentation() {
        // The typed handoff preserves title/actions/destination — the round-1
        // string handoff discarded all of that on the restore path.
        let appState = makeAppState()
        appState.pendingLoginFailure = .presenting(.authenticationRejected)

        XCTAssertEqual(appState.pendingLoginFailure?.title, "Login failed")
        XCTAssertEqual(appState.pendingLoginFailure?.helpDestination, .credentials)
        XCTAssertTrue(appState.pendingLoginFailure?.offersRecoveryActions ?? false)
    }

    func testPendingLoginFailureStartsNilSoStaleFailuresCannotResurface() {
        // A fresh login appearance must not inherit an older failure.
        XCTAssertNil(makeAppState().pendingLoginFailure)
    }
}
