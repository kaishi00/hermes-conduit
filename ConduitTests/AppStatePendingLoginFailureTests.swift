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
        // signInRequired covers both an expired WebKit session and no usable
        // sign-in session at all, so the copy must stay neutral — never the
        // unknown "Couldn't connect" degradation, never a raw error string,
        // and no expiration claim either way.
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

    /// On screen a required sign-in ends the dashboard's Lock Screen turns,
    /// all of them without the plugin and those the relay can't end by push
    /// with it; off screen it keeps them.
    func testASignInEndsTheLockScreenTurnsNothingElseCanEnd() {
        let reported = NotifierPluginStatus.State.reported(version: "0.46.0", capabilities: [])
        XCTAssertEqual(AppState.signInEndsLockScreenTurns(screenAway: false, plugin: reported), .endNotOnRelay, "The plugin still ends by push those the relay took")
        XCTAssertEqual(AppState.signInEndsLockScreenTurns(screenAway: false, plugin: .predatesCapabilities), .endAll, "No plugin to push the end")
        XCTAssertEqual(AppState.signInEndsLockScreenTurns(screenAway: false, plugin: .unknown), .endAll)
        XCTAssertEqual(AppState.signInEndsLockScreenTurns(screenAway: true, plugin: .predatesCapabilities), .keepAll, "Off screen the refusal is retried on screen")
        XCTAssertEqual(AppState.signInEndsLockScreenTurns(screenAway: true, plugin: reported), .keepAll)

        XCTAssertEqual(AppState.SignInLockScreenTurnsEnd.endNotOnRelay.keepingThoseOnRelay, true)
        XCTAssertEqual(AppState.SignInLockScreenTurnsEnd.endAll.keepingThoseOnRelay, false)
        XCTAssertNil(AppState.SignInLockScreenTurnsEnd.keepAll.keepingThoseOnRelay)
    }

    /// The sign-in screen hands the dashboard's turns to
    /// `liveTurnActivitiesEndDashboard` only on screen.
    func testARequiredSignInOnScreenEndsTheLockScreenTurns() {
        for away in [false, true] {
            let appState = makeAppState()
            appState.phoneScreenIsAway = { away }
            var ends: [Bool] = []
            appState.liveTurnActivitiesEndDashboard = { _, keepingThoseOnRelay in ends.append(keepingThoseOnRelay) }
            appState.requireSignIn(message: "Your dashboard session ended.")
            XCTAssertEqual(ends, away ? [] : [false], "No plugin reported: all of them end, on screen only")
        }
    }

    /// A refused saved sign-in at launch presents sign-in without
    /// `requireSignIn`, and ends the dashboard's turns the same way.
    func testARefusedSavedSignInEndsTheLockScreenTurns() {
        for away in [false, true] {
            let appState = makeAppState()
            appState.phoneScreenIsAway = { away }
            var ends: [Bool] = []
            appState.liveTurnActivitiesEndDashboard = { _, keepingThoseOnRelay in ends.append(keepingThoseOnRelay) }
            XCTAssertTrue(appState.presentCredentialRestoreFailure(.authenticationRejected, switchGeneration: nil))
            XCTAssertTrue(appState.showLogin)
            XCTAssertEqual(ends, away ? [] : [false], "No plugin reported: all of them end, on screen only")
        }
    }

    func testEveryLiveRegistrySnapshotSettlesTheLockScreenTurns() {
        let appState = makeAppState()
        var snapshots: [(Set<String>, String)] = []
        appState.liveTurnActivitiesRegistrySnapshot = { ids, profile, _ in
            snapshots.append((ids, profile))
            return false
        }
        appState.recordActiveListEvidence([
            LiveSessionStatus(runtimeSessionId: "rt", storedSessionId: "stored", status: "working"),
            LiveSessionStatus(runtimeSessionId: "done", storedSessionId: "done-stored", status: "idle"),
        ], profile: "work")
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.0, ["rt", "stored"])
        XCTAssertEqual(snapshots.first?.1, "work", "Settled against the snapshot's own profile")
        XCTAssertFalse(appState.liveTurnRegistryRecheckPending)
    }

    /// A chat just seen absent gets one more registry read, chat list or
    /// not; a second absence meanwhile shares it.
    func testAChatJustSeenAbsentGetsOneMoreRegistryRead() {
        let appState = makeAppState()
        var reads = 0
        appState.liveTurnActivitiesRegistrySnapshot = { _, _, _ in
            reads += 1
            return true
        }
        appState.recordActiveListEvidence([], profile: "default")
        XCTAssertTrue(appState.liveTurnRegistryRecheckPending)
        appState.recordActiveListEvidence([], profile: "default")
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(appState.liveTurnRegistryRecheckPending)
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
