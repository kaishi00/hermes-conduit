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
//  credentials. Two dashboards legitimately stop before stage 3's login: one
//  that answers discovery with an unauthenticated redirect to a sign-in page
//  ends in the supported `requiresInteractiveSignIn` outcome, and a
//  password-capable dashboard whose tested configuration carries no usable
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
        case .server: return String(localized: "Dashboard reachable")
        case .dashboard: return String(localized: "Hermes dashboard found")
        case .authentication: return "Authentication"
        }
    }

    /// The in-progress phrase for the row currently being checked.
    var runningLabel: String {
        switch self {
        case .server: return String(localized: "Checking server…")
        case .dashboard: return String(localized: "Checking dashboard…")
        case .authentication: return "Authenticating…"
        }
    }

    /// The confirmation phrase for a passed stage.
    var successLabel: String {
        switch self {
        case .server: return String(localized: "Dashboard reachable")
        case .dashboard: return String(localized: "Hermes dashboard found")
        case .authentication: return String(localized: "Login successful")
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
    /// and NOT a failure (nothing went wrong).
    case requiresInteractiveSignIn
    /// The dashboard is a native password dashboard, but the test
    /// configuration carries no usable credentials to test it with. A
    /// supported partial outcome: transport and dashboard identity are
    /// proven, no login attempt was made, and the user can enter
    /// credentials to finish the test. Explicitly NOT a success, NOT a
    /// failure, and NOT an authentication mode — credential availability is
    /// a property of the seed, never of the dashboard.
    case requiresCredentials
    case failed(ConnectionFailure)

    /// VoiceOver state word, so success/failure is never communicated by
    /// icon or color alone.
    var accessibilityState: String {
        switch self {
        case .pending: return "waiting"
        case .running: return "checking"
        case .succeeded: return "passed"
        case .requiresInteractiveSignIn: return String(localized: "browser sign-in required")
        case .requiresCredentials: return String(localized: "credentials required")
        case .failed: return "failed"
        }
    }
}

/// One probe progress report, applied to `ConnectionSetupTestState` by the
/// flow model. Carries the classified failure, never raw errors or server
/// response text.
enum ConnectionSetupTestEvent: Equatable {
    case started(ConnectionSetupTestStage)
    case succeeded(ConnectionSetupTestStage)
    /// Terminal supported outcome: the dashboard requires interactive
    /// (browser) sign-in. Emitted once, at the authentication stage, after
    /// server and dashboard have succeeded. No password login, ticket mint,
    /// or WebView follows inside the probe.
    case requiresInteractiveSignIn(ConnectionSetupTestStage)
    /// Terminal partial outcome: the dashboard is a native password
    /// dashboard but the tested configuration carries no usable credentials.
    /// Emitted once, at the authentication stage, after server and dashboard
    /// have succeeded — INSTEAD of any login attempt. No password login and
    /// no ticket mint follow; an empty-credential login is never sent.
    case requiresCredentials(ConnectionSetupTestStage)
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
    static let readyMessage = "This connection is ready to use."

    /// The interactive-auth completion announcement and Review copy. The
    /// user has NOT authenticated: the message says what happens next
    /// instead of claiming success. Never may this state render "Login
    /// successful".
    static let interactiveReadyMessage = "This dashboard uses browser-based sign-in. "
        + "Conduit will open the sign-in page after you return to the login screen."

    /// The credentials-required partial outcome's copy: server and dashboard
    /// passed, but testing native login needs the user's credentials first.
    /// Names the dashboard's auth mode (learned from provider discovery) and
    /// asks for the missing secret — never a success, failure, or
    /// "connection ready" claim.
    static let credentialsRequiredMessage = "This dashboard uses username and password sign-in. "
        + "Enter your credentials to finish testing the connection."

    /// Round 6 (Repair): the interactive-auth message in the Repair context,
    /// where the next step is signing in over the existing AuthWebView —
    /// not returning to the login screen.
    static let repairInteractiveMessage = "This dashboard uses browser-based sign-in. "
        + "Sign in now to reconnect to it."

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
        case .requiresInteractiveSignIn(let stage):
            guard self[stage] == .pending || self[stage] == .running else { return }
            self[stage] = .requiresInteractiveSignIn
        case .requiresCredentials(let stage):
            guard self[stage] == .pending || self[stage] == .running else { return }
            self[stage] = .requiresCredentials
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
        server == .succeeded
            && dashboard == .succeeded
            && authentication == .requiresInteractiveSignIn
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
        case .requiresInteractiveSignIn: return String(localized: "Browser sign-in required")
        case .requiresCredentials: return String(localized: "Credentials required")
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
                remediationLabel: String(localized: "Edit Connection Details"),
                offersRetry: failure != .rateLimited
            )
        case .authentication:
            // Retry is never the primary action after rejected credentials:
            // blind retries feed the rate limiter. Edit comes first.
            return ConnectionSetupTestRecoveryPlan(
                remediationStep: .loginCredentials,
                remediationLabel: String(localized: "Edit Credentials"),
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
/// one discovery request and nothing else.
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
        // with the authentication shape the probe can exercise. An arbitrary
        // website answering 200 (unrecognized body) and a recognizable
        // provider answer with no password provider are both NOT Hermes
        // password dashboards — and neither is the interactive-auth signal,
        // which only the redirect classification above may produce.
        onEvent(.started(.dashboard))
        switch discovery {
        case .interactiveSignInRequired:
            // The dashboard requires interactive (browser) sign-in. The
            // probe has verified everything it can — transport and dashboard
            // identity plus the expected auth behavior — and reports the
            // supported terminal outcome. It stays side-effect-free: no
            // native login attempt, no ticket mint, no WebView, no
            // cookie/Keychain writes. The actual sign-in happens over the
            // existing AuthWebView, never inside the probe.
            onEvent(.succeeded(.dashboard))
            onEvent(.started(.authentication))
            onEvent(.requiresInteractiveSignIn(.authentication))
            return nil
        case .unrecognized:
            Self.reportFailure(.dashboard, .unexpectedServerResponse, to: onEvent)
            return nil
        case .providers(let providers):
            guard HermesProviderCheck.supportsPassword(providers) else {
                Self.reportFailure(.dashboard, .unexpectedServerResponse, to: onEvent)
                return nil
            }
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
        case serverHostNotFound = "server:hostNotFound"
        case dashboardUnexpected = "dashboard:unexpectedServerResponse"
        case authRejected = "auth:authenticationRejected"
        case authRateLimited = "auth:rateLimited"

        func run(_ onEvent: (ConnectionSetupTestEvent) -> Void) {
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
                onEvent(.requiresInteractiveSignIn(.authentication))
            case .credentialsRequired:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.requiresCredentials(.authentication))
            case .serverHostNotFound:
                onEvent(.started(.server))
                onEvent(.failed(.server, .hostNotFound))
            case .dashboardUnexpected:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.failed(.dashboard, .unexpectedServerResponse))
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
        script.run(onEvent)
        // The stub's transaction is built through the DEBUG factory (inert
        // empty cookie set). Repair UI tests script the ACTIVATION outcome
        // separately (`-CONDUIT_REPAIR_ACTIVATION`), so this transaction is
        // never committed by the stub itself.
        guard script == .success else { return nil }
        return ConnectionSetupTestAcquisition(
            configuration: result,
            nativeConnection: .debugStub(ticket: "connection-setup-stub-ticket")
        )
    }
}
#endif
