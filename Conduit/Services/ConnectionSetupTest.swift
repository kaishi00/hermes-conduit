//
//  ConnectionSetupTest.swift
//  Conduit
//
//  Round 4 of the Connection Setup assistant: a staged connection test that
//  runs before the user accepts the wizard's settings. The state model is
//  SwiftUI-free and reducer-driven so stage transitions, invalidation, and
//  stale-result handling are unit-testable without hosting a view.
//
//  The probe ORCHESTRATES the production authentication machinery — it never
//  reimplements URL construction, request bodies, Cloudflare headers, or
//  status classification. Stage 1 (transport) and stage 2 (Hermes dashboard
//  confirmation) ride on the same provider-discovery request the normal
//  login flow performs first; stage 3 is the full native connect (password
//  login + ws-ticket mint) for password-capable dashboards WITH present
//  credentials. The sign-in mode comes from the shared
//  `DashboardSignInResolver`, the same decision the login card and Repair
//  make. Several dashboards legitimately stop before stage 3's login: one
//  that signs in through a browser (an unauthenticated redirect to a sign-in
//  service, an OAuth provider with or without native_pkce) ends in the
//  supported `requiresInteractiveSignIn` outcome; one offering password AND
//  browser sign-in without credentials to test ends in `requiresSignInChoice`;
//  and a password dashboard whose tested configuration carries no usable
//  credentials ends in the supported `requiresCredentials` partial outcome —
//  credential absence is not an authentication mode, and an empty-credential
//  login is never sent. The probe commits nothing: no cookie store write, no
//  Keychain, no AppState mutation, no websocket, no screen changes. A
//  successful native test RETURNS the validated transaction memory-only
//  (Round 6): Repair mode may promote it to an explicit reconnect, and the
//  transaction's cookies reach the shared store only when that reconnect
//  commits them.
//

import Foundation
import os

/// The sequential stages of a setup connection test. One source of truth for
/// ordering, copy, and accessibility state.
enum ConnectionSetupTestStage: Equatable, CaseIterable, Identifiable {
    case server
    case dashboard
    case authentication

    var id: Self { self }

    /// The stable objective label: what pending and failed rows show, and
    /// what success confirms. Used for VoiceOver too, so a row's meaning
    /// never depends on icon or color alone.
    var objectiveLabel: String {
        switch self {
        case .server: return AppLocalization.string("Dashboard reachable")
        case .dashboard: return AppLocalization.string("Hermes dashboard found")
        case .authentication: return AppLocalization.string("Authentication")
        }
    }

    /// The in-progress phrase for the row currently being checked.
    var runningLabel: String {
        switch self {
        case .server: return AppLocalization.string("Checking server…")
        case .dashboard: return AppLocalization.string("Checking dashboard…")
        case .authentication: return AppLocalization.string("Authenticating…")
        }
    }

    /// The confirmation phrase for a passed stage.
    var successLabel: String {
        switch self {
        case .server: return AppLocalization.string("Dashboard reachable")
        case .dashboard: return AppLocalization.string("Hermes dashboard found")
        case .authentication: return AppLocalization.string("Login successful")
        }
    }

    /// Stable identifier fragment (UI-test handles), not user-facing.
    var identifierName: String {
        switch self {
        case .server: return "server"
        case .dashboard: return "dashboard"
        case .authentication: return "authentication"
        }
    }
}

/// Per-stage result of the staged test.
enum ConnectionSetupStageState: Equatable {
    case pending
    case running
    case succeeded
    /// The dashboard answered, but authentication must continue
    /// interactively in the browser after the handoff. A supported terminal
    /// outcome — explicitly NOT a success (the user has not authenticated)
    /// and NOT a failure (nothing went wrong). Carries the sign-in the
    /// shared decision chose, which is what Repair's Sign In to Reconnect
    /// opens for this result.
    case requiresInteractiveSignIn(DashboardInteractiveSignIn)
    /// The dashboard is a native password dashboard, but the test
    /// configuration carries no usable credentials to test it with. A
    /// supported partial outcome: transport and dashboard identity are
    /// proven, no login attempt was made, and the user can enter
    /// credentials to finish the test. Explicitly NOT a success, NOT a
    /// failure, and NOT an authentication mode — credential availability is
    /// a property of the seed, never of the dashboard.
    case requiresCredentials
    /// The dashboard offers both password sign-in and a browser sign-in, and
    /// the test had no credentials to try. A supported terminal outcome like
    /// `requiresInteractiveSignIn`: the user picks a method on the login
    /// screen, or enters credentials to test the password method now.
    /// Carries the browser sign-in on offer.
    case requiresSignInChoice(DashboardBrowserSignInOffer)
    case failed(ConnectionFailure)

    /// VoiceOver state word, so success/failure is never communicated by
    /// icon or color alone.
    var accessibilityState: String {
        switch self {
        case .pending: return AppLocalization.string("waiting")
        case .running: return AppLocalization.string("checking")
        case .succeeded: return AppLocalization.string("passed")
        case .requiresInteractiveSignIn: return AppLocalization.string("browser sign-in required")
        case .requiresCredentials: return AppLocalization.string("credentials required")
        case .requiresSignInChoice: return AppLocalization.string("choice of sign-in method")
        case .failed: return AppLocalization.string("failed")
        }
    }
}

/// One probe progress report, applied to `ConnectionSetupTestState` by the
/// flow model. Carries the classified failure, never raw errors or server
/// response text.
enum ConnectionSetupTestEvent: Equatable {
    case started(ConnectionSetupTestStage)
    case succeeded(ConnectionSetupTestStage)
    /// Terminal supported outcome: the dashboard requires interactive sign-in
    /// in the appropriate approved surface. Emitted once, at the
    /// authentication stage, after server and dashboard have succeeded. No
    /// password login, ticket mint, or WebView follows inside the probe.
    case requiresInteractiveSignIn(ConnectionSetupTestStage, DashboardInteractiveSignIn)
    /// Terminal partial outcome: the dashboard is a native password
    /// dashboard but the tested configuration carries no usable credentials.
    /// Emitted once, at the authentication stage, after server and dashboard
    /// have succeeded — INSTEAD of any login attempt. No password login and
    /// no ticket mint follow; an empty-credential login is never sent.
    case requiresCredentials(ConnectionSetupTestStage)
    /// Terminal outcome: the dashboard offers password and browser sign-in
    /// and the tested configuration carries no credentials. Emitted once, at
    /// the authentication stage; no login attempt, ticket mint, or WebView
    /// follows inside the probe.
    case requiresSignInChoice(ConnectionSetupTestStage, DashboardBrowserSignInOffer)
    case failed(ConnectionSetupTestStage, ConnectionFailure)
}

/// The staged test's state: one source of truth for all three stages.
/// Prior successes stay successful when a later stage fails; untouched
/// future stages stay pending. SwiftUI never infers any of this from button
/// titles or local booleans.
struct ConnectionSetupTestState: Equatable {
    var server = ConnectionSetupStageState.pending
    var dashboard = ConnectionSetupStageState.pending
    var authentication = ConnectionSetupStageState.pending

    /// The completion announcement (one per run, not per stage transition).
    static var readyMessage: String { AppLocalization.string("This connection is ready to use.") }

    /// The interactive-auth completion announcement and Review copy. The
    /// user has NOT authenticated: the message says what happens next
    /// instead of claiming success. Never may this state render "Login
    /// successful".
    static var interactiveReadyMessage: String {
        AppLocalization.string("This dashboard uses browser-based sign-in. Conduit will open the sign-in page after you return to the login screen.")
    }

    /// The credentials-required partial outcome's copy: server and dashboard
    /// passed, but testing native login needs the user's credentials first.
    /// Names the dashboard's auth mode (learned from provider discovery) and
    /// asks for the missing secret — never a success, failure, or
    /// "connection ready" claim.
    static var credentialsRequiredMessage: String {
        AppLocalization.string("This dashboard uses username and password sign-in. Enter your credentials to finish testing the connection.")
    }

    /// Round 6 (Repair): the interactive-auth message in the Repair context,
    /// where the next step is signing in over the existing AuthWebView —
    /// not returning to the login screen.
    static var repairInteractiveMessage: String {
        AppLocalization.string("This dashboard uses browser-based sign-in. Sign in now to reconnect to it.")
    }

    /// The sign-in-choice outcome's copy: both methods work, neither has
    /// been tried. Never a success claim.
    static var signInChoiceMessage: String {
        AppLocalization.string("This dashboard offers more than one way to sign in. Choose one on the login screen, or enter your username and password to test them now.")
    }

    /// The sign-in-choice message in the Repair context.
    static var repairSignInChoiceMessage: String {
        AppLocalization.string("This dashboard offers more than one way to sign in. Sign in now to reconnect, or enter your username and password to test them first.")
    }

    /// The one VoiceOver announcement for a run's terminal event, in the
    /// copy the screen shows for it: Repair's own wording where Review
    /// shows it (Repair has no login screen to go back to). Nil for the
    /// stage transitions in between, which stay quiet.
    static func completionAnnouncement(for event: ConnectionSetupTestEvent, repairing: Bool) -> String? {
        switch event {
        case .succeeded(.authentication):
            return readyMessage
        case .requiresInteractiveSignIn(.authentication, _):
            return repairing ? repairInteractiveMessage : interactiveReadyMessage
        case .requiresCredentials(.authentication):
            return credentialsRequiredMessage
        case .requiresSignInChoice(.authentication, _):
            return repairing ? repairSignInChoiceMessage : signInChoiceMessage
        case .failed(_, let failure):
            return failure.userTitle
        default:
            return nil
        }
    }

    subscript(stage: ConnectionSetupTestStage) -> ConnectionSetupStageState {
        get {
            switch stage {
            case .server: return server
            case .dashboard: return dashboard
            case .authentication: return authentication
            }
        }
        set {
            switch stage {
            case .server: server = newValue
            case .dashboard: dashboard = newValue
            case .authentication: authentication = newValue
            }
        }
    }

    /// Pure reducer: folds one probe event into the state. Stage progress is
    /// monotonic within a run — a terminal stage never reverts — so
    /// out-of-order or duplicate events degrade gracefully instead of
    /// corrupting the list.
    mutating func apply(_ event: ConnectionSetupTestEvent) {
        switch event {
        case .started(let stage):
            guard self[stage] == .pending else { return }
            self[stage] = .running
        case .succeeded(let stage):
            guard self[stage] == .running else { return }
            self[stage] = .succeeded
        case .requiresInteractiveSignIn(let stage, let signIn):
            guard self[stage] == .pending || self[stage] == .running else { return }
            self[stage] = .requiresInteractiveSignIn(signIn)
        case .requiresCredentials(let stage):
            guard self[stage] == .pending || self[stage] == .running else { return }
            self[stage] = .requiresCredentials
        case .requiresSignInChoice(let stage, let offer):
            guard self[stage] == .pending || self[stage] == .running else { return }
            self[stage] = .requiresSignInChoice(offer)
        case .failed(let stage, let failure):
            guard self[stage] == .pending || self[stage] == .running else { return }
            self[stage] = .failed(failure)
        }
    }

    var allSucceeded: Bool {
        ConnectionSetupTestStage.allCases.allSatisfy { self[$0] == .succeeded }
    }

    var isRunning: Bool {
        ConnectionSetupTestStage.allCases.contains { self[$0] == .running }
    }

    /// The staged test ended in the supported interactive-auth outcome:
    /// server and dashboard succeeded, and authentication stopped at
    /// "browser sign-in required" — never a success, never a failure.
    var requiresInteractiveSignIn: Bool {
        interactiveSignIn != nil
    }

    /// The sign-in the interactive outcome names, when the test ended in it.
    var interactiveSignIn: DashboardInteractiveSignIn? {
        guard server == .succeeded, dashboard == .succeeded,
              case .requiresInteractiveSignIn(let signIn) = authentication else { return nil }
        return signIn
    }

    /// The staged test ended in the supported credentials-required partial
    /// outcome: server and dashboard succeeded, and authentication stopped
    /// before any login attempt because the tested configuration carries no
    /// usable credentials. Never a success, never a failure, and never an
    /// authentication mode — discovery decides that, not credential absence.
    var requiresCredentials: Bool {
        server == .succeeded
            && dashboard == .succeeded
            && authentication == .requiresCredentials
    }

    /// The staged test ended in the sign-in-choice outcome: server and
    /// dashboard succeeded, and the dashboard offers password and browser
    /// sign-in with no credentials tested.
    var requiresSignInChoice: Bool {
        browserSignInOffer != nil
    }

    /// The browser sign-in the sign-in-choice outcome offers, when the test
    /// ended in it.
    var browserSignInOffer: DashboardBrowserSignInOffer? {
        guard server == .succeeded, dashboard == .succeeded,
              case .requiresSignInChoice(let offer) = authentication else { return nil }
        return offer
    }

    /// The first failed stage in run order, if any.
    var failedStage: ConnectionSetupTestStage? {
        ConnectionSetupTestStage.allCases.first { stage in
            if case .failed = self[stage] { return true }
            return false
        }
    }

    /// The classified failure of `failedStage`.
    var failedFailure: ConnectionFailure? {
        guard let stage = failedStage, case .failed(let failure) = self[stage] else { return nil }
        return failure
    }

    /// The visible row label for a stage in its current state.
    func rowLabel(for stage: ConnectionSetupTestStage) -> String {
        switch self[stage] {
        case .running: return stage.runningLabel
        case .succeeded: return stage.successLabel
        case .requiresInteractiveSignIn: return AppLocalization.string("Browser sign-in required")
        case .requiresCredentials: return AppLocalization.string("Credentials required")
        case .requiresSignInChoice: return AppLocalization.string("Choose how to sign in")
        case .pending, .failed: return stage.objectiveLabel
        }
    }

    /// The complete VoiceOver label for a stage row.
    func accessibilityLabel(for stage: ConnectionSetupTestStage) -> String {
        "\(stage.objectiveLabel), \(self[stage].accessibilityState)"
    }
}

/// What the wizard offers after a failed stage: the step that owns the
/// failed inputs, and whether an immediate retry may be offered. Pure so the
/// recovery policy is unit-testable — in particular, rate limiting is a
/// password-login throttle and must never invite an immediate retry.
struct ConnectionSetupTestRecoveryPlan: Equatable {
    let remediationStep: ConnectionSetupStep
    let remediationLabel: String
    let offersRetry: Bool

    static func plan(
        for stage: ConnectionSetupTestStage,
        failure: ConnectionFailure
    ) -> ConnectionSetupTestRecoveryPlan {
        switch stage {
        case .server, .dashboard:
            return ConnectionSetupTestRecoveryPlan(
                remediationStep: .connectionDetails,
                remediationLabel: AppLocalization.string("Edit Connection Details"),
                offersRetry: failure != .rateLimited
            )
        case .authentication:
            // Retry is never the primary action after rejected credentials:
            // blind retries feed the rate limiter. Edit comes first.
            return ConnectionSetupTestRecoveryPlan(
                remediationStep: .loginCredentials,
                remediationLabel: AppLocalization.string("Edit Credentials"),
                offersRetry: failure != .rateLimited
            )
        }
    }
}

/// Performs the staged connection test. MainActor-isolated so progress
/// events apply to the flow model synchronously and in order, exactly like
/// every other wizard state mutation.
@MainActor
protocol ConnectionSetupTesting {
    /// Runs the staged test, reporting progress through `onEvent`. A
    /// successful NATIVE test also returns the validated transaction —
    /// memory only, nothing committed — which Repair mode may promote into
    /// an explicit reconnect candidate. Every diagnostic outcome returns
    /// nil, and testing never commits cookies, writes Keychain, or touches
    /// AppState.
    @discardableResult
    func runTest(
        result: ConnectionSetupResult,
        cloudflareAccess: CloudflareAccessCredentials?,
        onEvent: @escaping (ConnectionSetupTestEvent) -> Void
    ) async -> ConnectionSetupTestAcquisition?
}

/// Memory-only validated native authentication transaction from a
/// successful staged test. The probe commits nothing itself:
/// `commitCookies()` happens only when an explicit reconnect later promotes
/// this acquisition into the active connection.
struct ConnectionSetupTestAcquisition: CustomStringConvertible, CustomDebugStringConvertible {
    let configuration: ConnectionSetupResult
    let nativeConnection: NativeAuthConnection

    // Redacted: the transaction carries a ticket and cookies.
    var description: String { "ConnectionSetupTestAcquisition(redacted)" }
    var debugDescription: String { description }
}

/// The production probe. Reuses `NativeAuthClient` unchanged for every
/// request — including its redirect policy, Cloudflare header application,
/// transport policy, and status classification via
/// `ConnectionFailureClassifier`. A password-capable dashboard with present
/// credentials sees exactly one discovery request, one password-login
/// attempt, and one ticket mint. A password-capable dashboard without
/// present credentials — and an interactive-auth dashboard — sees exactly
/// one discovery request and nothing else, plus the native capability
/// check when discovery names a native-capable provider and no password.
struct ConnectionSetupProbe: ConnectionSetupTesting {
    private static let logger = Logger(subsystem: "com.milim.relay", category: "connection-setup-test")

    /// Test-only seam: routes the real client through a URLProtocol stub.
    /// Production callers leave this nil.
    var sessionConfiguration: URLSessionConfiguration?

    func runTest(
        result: ConnectionSetupResult,
        cloudflareAccess: CloudflareAccessCredentials?,
        onEvent: @escaping (ConnectionSetupTestEvent) -> Void
    ) async -> ConnectionSetupTestAcquisition? {
        let client = NativeAuthClient(
            baseURL: result.serverURL,
            cloudflareAccess: cloudflareAccess,
            sessionConfiguration: sessionConfiguration
        )

        // Stages 1 and 2 share one request — the same provider discovery the
        // login flow performs first. A transport error proves nothing about
        // the server and fails at the server stage; a typed discovery answer
        // means an HTTP response DID arrive, so transport is proven and the
        // failure belongs to the dashboard stage.
        onEvent(.started(.server))
        let discovery: AuthProviderDiscoveryResult
        do {
            discovery = try await client.authProviderDiscovery()
        } catch {
            guard !Self.wasCancelled(error) else { return nil }
            if let authError = error as? AuthClientError {
                if case .invalidURL = authError {
                    Self.reportFailure(.server, ConnectionFailureClassifier.classify(authError), to: onEvent)
                    return nil
                }
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                Self.reportFailure(.dashboard, ConnectionFailureClassifier.classify(authError), to: onEvent)
                return nil
            }
            Self.reportFailure(.server, ConnectionFailureClassifier.classify(error), to: onEvent)
            return nil
        }
        onEvent(.succeeded(.server))

        // Stage 2: the discovery answer must identify a Hermes dashboard
        // and a sign-in mode, decided by the same resolver the login card
        // and Repair use. An arbitrary website answering 200, a provider
        // list naming no usable sign-in, and a failed native capability
        // check for a dashboard that offers nothing else all fail here —
        // never a quiet downgrade to another mode.
        onEvent(.started(.dashboard))
        let mode: DashboardSignInMode
        do {
            mode = try await DashboardSignInResolver(client: client).mode(for: discovery)
        } catch {
            guard !Self.wasCancelled(error) else { return nil }
            Self.reportFailure(.dashboard, ConnectionFailureClassifier.classify(error), to: onEvent)
            return nil
        }
        switch mode {
        case .interactive(let signIn):
            // The dashboard signs in through a browser: Hermes' native
            // system-browser flow, a sign-in service in front of it, or an
            // older Hermes' own sign-in page. The probe has verified
            // everything it can and reports the supported terminal outcome.
            // It stays side-effect-free: no native login attempt, no ticket
            // mint, no WebView, no cookie/Keychain writes. The actual sign-in
            // happens over the approved interactive surface, never inside
            // the probe.
            onEvent(.succeeded(.dashboard))
            onEvent(.started(.authentication))
            onEvent(.requiresInteractiveSignIn(.authentication, signIn))
            return nil
        case .passwordOrBrowser(let offer):
            // Password and browser sign-in both work. Credentials in the
            // tested configuration mean the user signs in with a password:
            // test that, without the native capability check the password
            // never needed. Without them, the choice itself is the outcome.
            guard result.hasUsableCredentials else {
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.requiresSignInChoice(.authentication, offer))
                return nil
            }
        case .password:
            break
        }
        onEvent(.succeeded(.dashboard))

        // Stage 3: the full native credential proof — password login plus
        // the ws-ticket mint that proves the session is actually usable.
        // This is the exact milestone normal login requires before it would
        // commit cookies. The transaction is RETURNED memory-only, never
        // committed: the test persists nothing and connects nothing.
        //
        // A password-capable dashboard WITHOUT present credentials stops
        // here at the supported credentials-required outcome. Credential
        // absence is not an authentication mode — it only means the seed
        // could not supply the secret — and an empty-credential login would
        // be a real, rate-limited authentication attempt against a
        // connection that may already be known to work.
        onEvent(.started(.authentication))
        guard result.hasUsableCredentials else {
            onEvent(.requiresCredentials(.authentication))
            return nil
        }
        do {
            let authenticatedConnection = try await client.connect(username: result.username, password: result.password)
            onEvent(.succeeded(.authentication))
            return ConnectionSetupTestAcquisition(
                configuration: result,
                nativeConnection: authenticatedConnection
            )
        } catch {
            guard !Self.wasCancelled(error) else { return nil }
            Self.reportFailure(.authentication, ConnectionFailureClassifier.classify(error), to: onEvent)
            return nil
        }
    }

    private static func reportFailure(
        _ stage: ConnectionSetupTestStage,
        _ failure: ConnectionFailure,
        to onEvent: (ConnectionSetupTestEvent) -> Void
    ) {
        // The classification is a semantic enum — safe at public privacy;
        // credentials, tickets, and response bodies are never logged.
        logger.error("Connection test failed at \(stage.objectiveLabel, privacy: .public): \(String(describing: failure), privacy: .public)")
        onEvent(.failed(stage, failure))
    }

    private static func wasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

#if DEBUG
/// UI-test-only probe stub: deterministic staged outcomes selected by the
/// `-CONNECTION_SETUP_TEST_RESULT` launch argument, so UI tests never depend
/// on a real Hermes server. Compiled out of release builds; production code
/// never references it.
struct ConnectionSetupTestProbeStub: ConnectionSetupTesting {
    enum Script: String {
        case success
        case interactiveSignInRequired = "auth:interactiveSignInRequired"
        case credentialsRequired = "auth:credentialsRequired"
        /// A password dashboard tested discovery-first: credentials
        /// required until the tested configuration carries them, then
        /// success.
        case password = "auth:password"
        case signInChoice = "auth:signInChoice"
        case serverHostNotFound = "server:hostNotFound"
        case dashboardUnexpected = "dashboard:unexpectedServerResponse"
        case authRejected = "auth:authenticationRejected"
        case authRateLimited = "auth:rateLimited"

        func run(_ result: ConnectionSetupResult, _ onEvent: (ConnectionSetupTestEvent) -> Void) {
            switch self {
            case .success:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.succeeded(.authentication))
            case .interactiveSignInRequired:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                // Deterministic and offline: nothing the stub decides needs
                // a capability check if Sign In to Reconnect opens it.
                onEvent(.requiresInteractiveSignIn(.authentication, .browser(.authProxyRedirect)))
            case .credentialsRequired:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.requiresCredentials(.authentication))
            case .password:
                guard result.hasUsableCredentials else {
                    return Self.credentialsRequired.run(result, onEvent)
                }
                Self.success.run(result, onEvent)
            case .signInChoice:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.requiresSignInChoice(.authentication, .legacyOAuth))
            case .serverHostNotFound:
                onEvent(.started(.server))
                onEvent(.failed(.server, .hostNotFound))
            case .dashboardUnexpected:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.failed(.dashboard, .unexpectedServerResponse))
            case .authRejected where !result.hasUsableCredentials,
                 .authRateLimited where !result.hasUsableCredentials:
                // A real probe never sends a login without credentials:
                // discovery stops at Credentials required first.
                Self.credentialsRequired.run(result, onEvent)
            case .authRejected:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.failed(.authentication, .authenticationRejected))
            case .authRateLimited:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.failed(.authentication, .rateLimited))
            }
        }

        static func fromLaunchArguments() -> ConnectionSetupTestProbeStub? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-CONNECTION_SETUP_TEST_RESULT"),
                  index + 1 < arguments.count,
                  let script = Script(rawValue: arguments[index + 1]) else { return nil }
            return ConnectionSetupTestProbeStub(script: script)
        }
    }

    let script: Script

    static func fromLaunchArguments() -> ConnectionSetupTestProbeStub? {
        Script.fromLaunchArguments()
    }

    func runTest(
        result: ConnectionSetupResult,
        cloudflareAccess: CloudflareAccessCredentials?,
        onEvent: @escaping (ConnectionSetupTestEvent) -> Void
    ) async -> ConnectionSetupTestAcquisition? {
        script.run(result, onEvent)
        // The stub's transaction is built through the DEBUG factory (inert
        // empty cookie set). Repair UI tests script the ACTIVATION outcome
        // separately (`-CONDUIT_REPAIR_ACTIVATION`), so this transaction is
        // never committed by the stub itself.
        guard script == .success || (script == .password && result.hasUsableCredentials) else { return nil }
        return ConnectionSetupTestAcquisition(
            configuration: result,
            nativeConnection: .debugStub(ticket: "connection-setup-stub-ticket")
        )
    }
}
#endif
