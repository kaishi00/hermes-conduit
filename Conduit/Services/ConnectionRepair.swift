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

    /// The address the repair connects to.
    var baseURL: String {
        switch self {
        case .native(let candidate): return candidate.configuration.serverURL
        case .browserSignIn(_, let baseURL, _), .nativeOAuth(_, let baseURL, _): return baseURL
        }
    }
}

/// What Repair's Sign In to Reconnect opens: the sign-in the current staged
/// test decided through the shared `DashboardSignInResolver`, never a second
/// discovery that could disagree with it.
enum ConnectionRepairSignIn {
    /// The tested interactive outcome's sign-in, or, for the sign-in-choice
    /// outcome, its browser sign-in, whose native capability check runs now
    /// that it is picked (unless the tested provider answer advertised
    /// `native_pkce`). A failed check is an error: never the browser view or
    /// a password instead. Nil when the test ended in neither outcome.
    static func signIn(
        for testState: ConnectionSetupTestState,
        resolver: DashboardSignInResolver
    ) async throws -> DashboardInteractiveSignIn? {
        if let signIn = testState.interactiveSignIn {
            return signIn
        }
        if let offer = testState.browserSignInOffer {
            return try await resolver.signIn(for: offer)
        }
        return nil
    }

    /// Whether Sign In to Reconnect (and Settings' Sign In Again) can open a
    /// native sign-in, so the Private sign-in page switch does something
    /// there: the tested sign-in is native, or a choice's sign-in that the
    /// capability check may still send to Safari. A sign-in the test
    /// already decided is the embedded browser never reads the switch.
    static func mayOpenNativeSignIn(for testState: ConnectionSetupTestState) -> Bool {
        if let signIn = testState.interactiveSignIn {
            if case .nativeOAuth = signIn { return true }
            return false
        }
        if let offer = testState.browserSignInOffer {
            guard let decided = offer.decidedSignIn else { return true }
            if case .nativeOAuth = decided { return true }
            return false
        }
        return false
    }
}

/// One Sign In to Reconnect resolution, bound to the draft revision and test
/// generation it started from (the `ConnectionRepairCandidate.isCurrent`
/// idiom). A choice's capability check runs while the wizard stays
/// interactive, so its answer opens a sign-in only if the user has not
/// edited the draft or started another test in the meantime.
struct ConnectionRepairSignInRequest {
    let configuration: ConnectionSetupResult
    let revision: Int
    let generation: Int

    func isCurrent(in flow: ConnectionSetupFlow) -> Bool {
        flow.draftRevision == revision
            && flow.testGeneration == generation
            && flow.hasCurrentInteractiveAuthOutcome
    }
}

/// Round 6: the Repair review's action model, built by ConnectionSetupView
/// when the wizard runs in Repair mode. The view evaluates candidate
/// currency; the form only renders states and forwards taps.
struct ConnectionSetupRepairReview {
    /// The staged test ended in an interactive sign-in outcome (or a choice
    /// that includes one) — the final action is Sign In to Reconnect, not
    /// Reconnect Now, which opens the sign-in that test decided
    /// (`ConnectionRepairSignIn`).
    let isInteractive: Bool
    /// The dashboard also offers password sign-in (the sign-in-choice
    /// outcome): Enter Credentials leads to a password test instead.
    let offersPasswordSignIn: Bool
    /// A validated native transaction exists and is still current. Reconnect
    /// Now requires it; a consumed candidate forces a fresh test.
    let isCandidateAvailable: Bool
    /// The classified failure of the last explicit activation attempt.
    let activationFailure: ConnectionFailure?
    let isActivating: Bool
    let reconnectNow: () -> Void
    let signInToReconnect: () -> Void
    let enterCredentials: () -> Void
    let testAgain: () -> Void
    /// Sign In to Reconnect can open a native sign-in
    /// (`ConnectionRepairSignIn.mayOpenNativeSignIn`), so the Private
    /// sign-in page switch shows above it.
    var showsPrivateSignInSwitch = false
}

/// The result of an explicit repair activation. Session identity questions
/// (preserved vs. absent on the replacement endpoint) are owned by the
/// existing `.preserveCurrent` sync machinery, not by this outcome.
enum ConnectionRepairActivationOutcome: Equatable {
    case activated
    case failed(ConnectionFailure)
    /// The address is another saved dashboard's. Nothing was connected or
    /// written: a repair would replace that dashboard's own sign-in, so the
    /// user switches to it instead (#995, Eric 2026-10-24).
    case addressBelongsToDashboard(id: UUID, label: String)
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

/// Settings › Connection Setup's Review for the dashboard Conduit is set up
/// for. When the staged test finds that this dashboard signs in through a
/// browser (or offers it), the next step is signing in, right there: Sign
/// In Again opens the sign-in the test decided, the way Repair's Sign In to
/// Reconnect does, and the copy never claims a session that isn't there.
/// Built by ConnectionSetupView; the form only renders it.
struct ConnectionSetupSettingsReview {
    /// Whether Conduit is connected to Hermes right now.
    let isSessionConnected: Bool
    /// The tested address is the active dashboard's and the test ended in
    /// browser sign-in (or a choice offering it).
    let offersSignInAgain: Bool
    let isSigningIn: Bool
    /// The classified failure of the last Sign In Again.
    let signInFailure: ConnectionFailure?
    let signInAgain: () -> Void
    /// Sign In Again can open a native sign-in, so the Private sign-in
    /// page switch shows above it.
    var showsPrivateSignInSwitch = false

    /// Sign In Again applies to the dashboard Conduit is set up for only:
    /// another address signs in from the login card, never as a side
    /// effect of Settings.
    static func offersSignInAgain(for flow: ConnectionSetupFlow, activeDashboardURL: String?) -> Bool {
        guard flow.enteredFromCurrentConnection,
              flow.hasCurrentInteractiveAuthOutcome,
              let activeDashboardURL,
              let active = try? ConnectionURLPolicy.normalizedBaseURL(activeDashboardURL),
              let tested = try? flow.draft.testConfiguration().serverURL else { return false }
        return (try? ConnectionURLPolicy.normalizedBaseURL(tested)) == active
    }

    /// The Review headline when Sign In Again is offered.
    static func signInAgainMessage(connected: Bool) -> String {
        connected
            ? AppLocalization.string("This dashboard uses browser-based sign-in. Sign in again here if Conduit stops connecting to it.")
            : AppLocalization.string("This dashboard uses browser-based sign-in, and Conduit isn’t signed in to it right now. Sign in again to reconnect.")
    }

    /// What Use these settings / Done does with the current session. Only a
    /// connected session "stays connected".
    static func applyNote(connected: Bool) -> String {
        connected
            ? AppLocalization.string("Applying saves these settings for your next reconnect. Your current session stays connected.")
            : AppLocalization.string("Applying saves these settings for your next reconnect. Conduit isn’t connected to this dashboard right now.")
    }
}
