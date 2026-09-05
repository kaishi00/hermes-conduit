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
        XCTAssertEqual(appState.pendingLoginFailure?.offersRecoveryActions, false)
        XCTAssertNil(
            appState.errorMessage,
            "Login-bound failures must not leak into the connected composer banner"
        )
    }

    func testConnectPolicyFailureHandsOffTypedPendingFailure() async {
        // The AppState.connect URL-policy guard is the third login-bound
        // handoff site: a connection attempt whose base URL fails policy must
        // land on the login card as a typed classified presentation — never
        // as a raw string in errorMessage.
        let appState = makeAppState()

        await appState.connect(with: HermesConnection(baseUrl: "not a dashboard url", ticket: "ticket"))

        XCTAssertTrue(appState.showLogin)
        XCTAssertFalse(appState.isConnected)
        XCTAssertFalse(appState.isConnecting)
        XCTAssertEqual(appState.pendingLoginFailure?.title, "Check the dashboard address")
        XCTAssertEqual(appState.pendingLoginFailure?.helpDestination, .start)
        XCTAssertNil(appState.errorMessage)
    }

    // MARK: - Silent-renewal sign-in handoff

    func testSilentRenewal429ClassifiesAsRateLimitedWithoutRawErrorDescription() {
        let reauthError = AuthClientError.loginFailed(
            status: 429,
            detail: "Too many login attempts. Try again shortly."
        )
        let presentation = AppState.silentRenewalSignInFailure(
            reauthError: reauthError,
            bridgeError: DashboardTicketBridgeError.signInRequired
        )
        XCTAssertEqual(presentation.title, "Too many login attempts")
        XCTAssertEqual(
            presentation.message,
            "Hermes temporarily blocked additional login attempts. Wait about a minute before trying again."
        )
        XCTAssertNotEqual(
            presentation.message, reauthError.errorDescription,
            "A reconnect 429 must not surface raw AuthClientError.errorDescription"
        )
        XCTAssertEqual(presentation.offersRecoveryActions, false)
        XCTAssertNil(presentation.helpDestination)
    }

    func testSilentRenewal401And503DoNotSurfaceRawErrorDescription() {
        // 401 during silent re-auth: the password was already known-good at
        // some point, but the endpoint rejection is still the best
        // explanation — presented as classified copy, never the raw string.
        let rejection = AuthClientError.loginFailed(status: 401, detail: "HTTP 401")
        let rejectedPresentation = AppState.silentRenewalSignInFailure(
            reauthError: rejection,
            bridgeError: DashboardTicketBridgeError.signInRequired
        )
        XCTAssertEqual(rejectedPresentation.title, "Login failed")
        XCTAssertEqual(
            rejectedPresentation.message,
            "Hermes rejected that username or password. Check your dashboard credentials and try again."
        )
        XCTAssertNotEqual(rejectedPresentation.message, rejection.errorDescription)

        // 503: server outage, distinct copy, raw "Login failed: HTTP 503"
        // must never reach the card.
        let outage = AuthClientError.loginFailed(status: 503, detail: "HTTP 503")
        let outagePresentation = AppState.silentRenewalSignInFailure(
            reauthError: outage,
            bridgeError: DashboardTicketBridgeError.signInRequired
        )
        XCTAssertEqual(outagePresentation.title, "Dashboard unavailable")
        XCTAssertNotEqual(outagePresentation.message, outage.errorDescription)
        XCTAssertFalse(outagePresentation.message.contains("HTTP 503"))
    }

    func testSilentRenewalWithoutReauthAttemptClassifiesBridgeSignInRequiredAsLoginRequired() {
        // No saved credentials → no re-auth attempt: the bare bridge
        // signInRequired means the WebKit session expired. That must read as
        // sign-in-required copy — never the unknown "Couldn't connect"
        // degradation, and never a raw error string.
        let presentation = AppState.silentRenewalSignInFailure(
            reauthError: nil,
            bridgeError: DashboardTicketBridgeError.signInRequired
        )
        XCTAssertEqual(presentation.title, "Sign-in required")
        XCTAssertEqual(
            presentation.message,
            "Conduit needs you to sign in to the dashboard to reconnect."
        )
        XCTAssertNil(presentation.helpDestination)
    }

    func testSilentRenewalOfflineReauthClassifiesAsOfflineWithNetworkHelp() {
        // Reconnect during a Wi-Fi blip: the most visible non-HTTP reauth
        // scenario gets the offline presentation, not unknown.
        let presentation = AppState.silentRenewalSignInFailure(
            reauthError: URLError(.notConnectedToInternet),
            bridgeError: DashboardTicketBridgeError.signInRequired
        )
        XCTAssertEqual(presentation.title, "No network connection")
        XCTAssertEqual(presentation.helpDestination, .network)
        XCTAssertTrue(presentation.offersRecoveryActions)
    }

    func testRequireSignInFailureOverloadPreservesFullPresentation() {
        // The failure overload must carry the presentation through untouched
        // (title, actions, destination) — unlike the message overload, which
        // wraps hand-written strings in a generic notice.
        let appState = makeAppState()
        let presentation = AppState.silentRenewalSignInFailure(
            reauthError: AuthClientError.loginFailed(status: 429, detail: "Too many login attempts"),
            bridgeError: DashboardTicketBridgeError.signInRequired
        )

        appState.requireSignIn(failure: presentation)

        XCTAssertTrue(appState.showLogin)
        XCTAssertEqual(appState.pendingLoginFailure, presentation)
        XCTAssertNil(appState.errorMessage)
    }

    func testRequireSignInMessageOverloadWrapsHumanAuthoredStringsAsNotice() {
        let appState = makeAppState()
        appState.requireSignIn(message: "Your dashboard session ended.")

        XCTAssertEqual(appState.pendingLoginFailure?.title, "Sign-in didn’t complete")
        XCTAssertEqual(appState.pendingLoginFailure?.message, "Your dashboard session ended.")
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
