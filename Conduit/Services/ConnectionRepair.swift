//
//  ConnectionRepair.swift
//  Conduit
//
//  Round 6: the explicit Repair Connection flow's value types and its
//  activation boundary. Repair reuses the Connection Setup wizard, probe,
//  failure taxonomy, and the authoritative AppState connection path; this
//  file only owns the small set of types that let a validated test result
//  become an explicit reconnect WITHOUT widening access to secrets.
//
//  Security shape: a validated native transaction (ticket + transaction
//  cookies) lives only inside ConnectionRepairCandidate — memory only,
//  never logged, never persisted, never Equatable, absent from every debug
//  description. It is invalidated by draft edits, newer test runs,
//  cancellation, dismissal, and consumption; the wizard checks the same
//  revision/generation that produced the staged success before use.
//

import Foundation

/// The seed for a Repair Connection launch: the configuration that actually
/// failed, plus everything safely available about it at the failure site.
/// Built by AppState (or the login screen for a failed saved-credential
/// reconnect); never reconstructed from strings.
struct ConnectionRepairContext: Equatable, Identifiable {
    let id = UUID()
    /// The failed dashboard configuration, expert URL preserved exactly.
    let draft: ConnectionSetupDraft
    /// The origin-matched Cloudflare Access service token, inherited for the
    /// probe only under the existing same-origin rules.
    let cloudflareAccess: CloudflareAccessCredentials?
    let cloudflareOriginURL: String
    /// The classified failure that surfaced, when one was retained. Routes
    /// the wizard's entry near the likely problem; never parsed from a
    /// user-facing string.
    let failure: ConnectionFailure?
}

/// Memory-only validated native authentication transaction produced by a
/// successful staged test in Repair mode. Bound to the flow revision and
/// generation that produced the staged success so a stale candidate can
/// never reconnect a newer edited draft.
struct ConnectionRepairCandidate: CustomStringConvertible, CustomDebugStringConvertible {
    let configuration: ConnectionSetupResult
    let nativeConnection: NativeAuthConnection
    let validatedRevision: Int
    let generation: Int

    /// The candidate is usable only while the flow still shows the staged
    /// success at exactly the revision and generation that produced it.
    /// Draft edits, newer runs, and cancellation all break one of the three.
    func isCurrent(
        hasCurrentSuccessfulTest: Bool,
        testGeneration: Int,
        testSucceededAtRevision: Int?
    ) -> Bool {
        hasCurrentSuccessfulTest
            && generation == testGeneration
            && validatedRevision == testSucceededAtRevision
    }

    // Intentionally non-Equatable, and redacted against accidental
    // interpolation or dump: the value carries an authenticated transaction
    // (ticket + transaction cookies) and a password-bearing configuration.
    var description: String { "ConnectionRepairCandidate(redacted)" }
    var debugDescription: String { description }
}

/// The wizard's handoff on an explicit final Repair action. Reconnect Now
/// and Sign In to Reconnect are the only connection-changing actions in
/// Repair mode, and both are user-initiated.
enum ConnectionRepairHandoff: CustomStringConvertible, CustomDebugStringConvertible {
    /// A validated native transaction from the staged test (Reconnect Now).
    case native(ConnectionRepairCandidate)
    /// A browser sign-in completed over the existing AuthWebView
    /// (Sign In to Reconnect).
    case browserSignIn(ticket: String, baseURL: String, configuration: ConnectionSetupResult)
    /// A Hermes-native OAuth transaction completed in the approved external
    /// browser surface. The newly issued grant is already durable so a
    /// transient first ticket failure can be retried; AppState makes the
    /// connection-mode transition atomic and restores prior auth on failure.
    case nativeOAuth(result: NativeOAuthLoginResult, baseURL: String, configuration: ConnectionSetupResult)

    // Redacted: the password and OAuth cases carry authenticated transactions,
    // while the browser case carries a raw ticket.
    var description: String { "ConnectionRepairHandoff(redacted)" }
    var debugDescription: String { description }
}

/// Round 6: the Repair review's action model, built by ConnectionSetupView
/// when the wizard runs in Repair mode. The view evaluates candidate
/// currency; the form only renders states and forwards taps.
struct ConnectionSetupRepairReview {
    /// The staged test ended in an interactive sign-in outcome — the final
    /// action is Sign In to Reconnect, not Reconnect Now. The view selects
    /// native OAuth or the legacy browser bridge from fresh discovery.
    let isInteractive: Bool
    /// A validated native transaction exists and is still current. Reconnect
    /// Now requires it; a consumed candidate forces a fresh test.
    let isCandidateAvailable: Bool
    /// The classified failure of the last explicit activation attempt.
    let activationFailure: ConnectionFailure?
    let isActivating: Bool
    let reconnectNow: () -> Void
    let signInToReconnect: () -> Void
    let testAgain: () -> Void
}

/// The result of an explicit repair activation. Session identity questions
/// (preserved vs. absent on the replacement endpoint) are owned by the
/// existing `.preserveCurrent` sync machinery, not by this outcome.
enum ConnectionRepairActivationOutcome: Equatable {
    case activated
    case failed(ConnectionFailure)
}

/// The activation boundary for Repair mode. Production wraps the
/// authoritative AppState connection path; DEBUG UI tests script
/// deterministic outcomes so no test touches a real websocket.
@MainActor
protocol ConnectionRepairActivating: AnyObject {
    func activate(_ handoff: ConnectionRepairHandoff) async -> ConnectionRepairActivationOutcome
}

/// Production activation. `performConnectionRepair` revokes outstanding
/// automatic recovery authority, commits the validated transaction's
/// cookies, connects through the standard path with `.preserveCurrent`
/// session semantics, and persists the tested configuration only after
/// activation succeeds.
@MainActor
final class AppStateConnectionRepairActivator: ConnectionRepairActivating {
    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func activate(_ handoff: ConnectionRepairHandoff) async -> ConnectionRepairActivationOutcome {
        #if DEBUG
        if let scripted = Self.scriptedActivationOutcome() { return scripted }
        #endif
        return await appState.performConnectionRepair(handoff)
    }

    #if DEBUG
    /// UI-test-only scripted outcome (`-CONDUIT_REPAIR_ACTIVATION success`
    /// or `transportFailure`). Scripted activations are fully inert: no
    /// cookies, no AppState connection, no persistence.
    private static func scriptedActivationOutcome() -> ConnectionRepairActivationOutcome? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CONDUIT_REPAIR_ACTIVATION"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1] == "transportFailure"
            ? .failed(.connectionRefused)
            : .activated
    }
    #endif
}
