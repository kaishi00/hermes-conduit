//
//  ConnectionSetupFlow.swift
//  Conduit
//
//  The guided Connection Setup wizard's state model. Deliberately SwiftUI-free
//  so the routing rules — entry destinations, question transitions, access
//  method branches, back navigation — are unit-testable without hosting a
//  view. The view layer renders whatever step the model is on and never makes
//  routing decisions itself.
//

import Foundation

/// The answer offered on each guided readiness question.
enum ConnectionSetupAnswer: Equatable {
    case yes
    case no
    case unknown
}

/// Supported ways for this device to reach a self-hosted Hermes dashboard.
/// Deliberately a closed set: there is no public-IP/open-port path, and
/// Conduit supports self-hosted Hermes only.
enum ConnectionAccessMethod: Equatable, CaseIterable {
    case lan
    case tailscale
    case reverseProxy

    /// The wizard card's user-facing title. Single source of truth so the
    /// copy-safety tests cover the shipped strings, not local literals.
    var displayTitle: String {
        switch self {
        case .lan: return String(localized: "I’m on the same network as Hermes")
        case .tailscale: return "Tailscale"
        case .reverseProxy: return String(localized: "I already have a domain or reverse proxy")
        }
    }
}

/// One screen of the guided flow.
enum ConnectionSetupStep: Equatable {
    // The three core questions.
    case dashboard
    case credentials
    case accessMethod

    // Access-method guidance followed by real form entry.
    case lan
    case tailscale
    case reverseProxy
    case connectionDetails
    case loginCredentials
    /// Round 4: the staged connection test between credentials and Review.
    /// Review is only reachable through a current successful test.
    case connectionTest
    case review

    // Direct troubleshooting surfaces (failure-driven entries).
    case tlsTroubleshooting
    case cloudflareTroubleshooting
}

/// Copyable "Ask Hermes" prompts. Each prompt asks Hermes to keep dashboard
/// authentication enabled — enforced by `ConnectionSetupFlowTests`, which pin
/// the safety phrases and forbid exposure/port language.
enum ConnectionSetupPrompt: CaseIterable {
    case dashboardNotRunning
    case dashboardUnknown
    case credentialsMissing
    case credentialsUnknown
    case lanDetails
    case tailscaleServe
    case reverseProxyDetails

    var title: String {
        switch self {
        case .dashboardNotRunning: return String(localized: "Ask Hermes to set up the dashboard")
        case .dashboardUnknown: return String(localized: "Ask Hermes to check the dashboard")
        case .credentialsMissing: return String(localized: "Ask Hermes to set up dashboard credentials")
        case .credentialsUnknown: return String(localized: "Ask Hermes to check your dashboard sign-in")
        case .lanDetails: return String(localized: "Ask Hermes for your connection details")
        case .tailscaleServe: return String(localized: "Ask Hermes to configure Tailscale Serve")
        case .reverseProxyDetails: return String(localized: "Ask Hermes to confirm your HTTPS address")
        }
    }

    var text: String {
        switch self {
        case .dashboardNotRunning:
            return String(localized: "Please set up or start the Hermes dashboard for me. Make sure it requires authentication, and tell me which port it is using when it is ready. Do not disable authentication.")
        case .dashboardUnknown:
            return String(localized: "Please check whether the Hermes dashboard is currently running. If it is, tell me which port it uses. If it is not running, set it up or start it. Make sure dashboard authentication remains enabled.")
        case .credentialsMissing:
            return String(localized: "Please check the authentication configuration for my Hermes dashboard. If dashboard login credentials have not been configured yet, set them up securely and tell me what username and password I should use with Hermes Conduit. Do not disable authentication.")
        case .credentialsUnknown:
            return String(localized: "Does my Hermes dashboard require authentication? If so, tell me what username and password I should use with Hermes Conduit. If authentication is not configured, set it up securely. Do not disable authentication.")
        case .lanDetails:
            // LAN entry is IP-address-only today: canonical transport policy
            // admits localhost, literal private LAN addresses, and Tailscale —
            // not local hostnames. The prompt must not promise them.
            return String(localized: "Please make sure the Hermes dashboard is reachable from other devices on my local network, then tell me the machine's local IP address and the dashboard port I should use with Hermes Conduit. Keep dashboard authentication enabled.")
        case .tailscaleServe:
            return String(localized: "Please check whether the Hermes dashboard is running. Make sure Tailscale is available on this machine, then configure Tailscale Serve so I can securely access the dashboard from my iPhone or iPad. Keep dashboard authentication enabled. When it is ready, tell me the hostname/address and port I should use with Hermes Conduit.")
        case .reverseProxyDetails:
            return String(localized: "Please confirm the HTTPS URL I should use to access the Hermes dashboard through my existing reverse proxy, including any custom port or path prefix. Also confirm that dashboard authentication remains enabled.")
        }
    }
}

/// The wizard's state: a navigation path of steps plus the answers collected
/// along the way. All mutations are explicit transitions so tests can drive
/// the exact routing contract.
struct ConnectionSetupFlow: Equatable {
    private(set) var path: [ConnectionSetupStep]
    private(set) var dashboardAnswer: ConnectionSetupAnswer?
    private(set) var credentialsAnswer: ConnectionSetupAnswer?
    /// Session-only form values. Every mutation — from flow transitions or
    /// direct view bindings — bumps `draftRevision`, which is the anchor for
    /// invalidating a previous connection-test success (Round 4).
    var draft: ConnectionSetupDraft {
        didSet { draftRevision += 1 }
    }
    private(set) var draftRevision = 0
    /// Round 4: the staged connection-test state, driven by probe events.
    private(set) var testState = ConnectionSetupTestState()
    /// Generation token for test runs. Any new run, cancellation, or stale
    /// reset bumps it, so a late completion from an obsolete run can never
    /// overwrite newer state (the same race class Conduit has been burned by
    /// elsewhere).
    private(set) var testGeneration = 0
    /// The draft revision a successful test validated; nil while untested.
    private(set) var testSucceededAtRevision: Int?
    /// The login card's in-memory Cloudflare service token, inherited for the
    /// probe only. Bound to `inheritedCloudflareOriginURL`: it is applied to
    /// the test ONLY while the draft's address stays same-origin, and is
    /// never displayed, edited, or persisted by the wizard.
    private(set) var inheritedCloudflareAccess: CloudflareAccessCredentials?
    private(set) var inheritedCloudflareOriginURL: String
    private(set) var validationError: ConnectionSetupValidationError?
    private let entry: ConnectionHelpDestination
    /// Round 6 (Repair): the classified failure that surfaced at the failed
    /// connection, used only to route the entry near the likely problem.
    private let repairFailure: ConnectionFailure?
    /// The draft exactly as the wizard was seeded. The Settings
    /// current-connection entry compares against it so a tested-but-unchanged
    /// configuration can offer plain Done instead of an apply.
    private let seededDraft: ConnectionSetupDraft

    var accessMethod: ConnectionAccessMethod? { draft.accessMethod }

    /// The screen currently presented.
    var step: ConnectionSetupStep { path.last ?? .dashboard }

    var canGoBack: Bool { path.count > 1 }

    /// "Step N of 3" for the core questions; `nil` on branch and
    /// troubleshooting screens, which sit outside the numbered sequence.
    var progressLabel: String? {
        switch step {
        case .dashboard: return String(localized: "Step 1 of 3")
        case .credentials: return String(localized: "Step 2 of 3")
        case .accessMethod: return String(localized: "Step 3 of 3")
        case .lan, .tailscale, .reverseProxy, .connectionDetails, .loginCredentials, .connectionTest, .review,
             .tlsTroubleshooting, .cloudflareTroubleshooting:
            return nil
        }
    }

    init(
        entry: ConnectionHelpDestination = .start,
        draft: ConnectionSetupDraft = ConnectionSetupDraft(),
        inheritedCloudflareAccess: CloudflareAccessCredentials? = nil,
        inheritedCloudflareOriginURL: String = "",
        repairFailure: ConnectionFailure? = nil
    ) {
        self.entry = entry
        self.repairFailure = repairFailure
        self.seededDraft = draft
        self.draft = draft
        self.inheritedCloudflareAccess = inheritedCloudflareAccess
        self.inheritedCloudflareOriginURL = inheritedCloudflareOriginURL
        path = Self.initialPath(for: entry, draft: draft, repairFailure: repairFailure)
    }

    /// Failure-driven Round-1 destinations land at sensible parts of the
    /// assistant; `.tls` and `.cloudflare` stay direct troubleshooting
    /// surfaces rather than wizard questions.
    static func entryStep(for destination: ConnectionHelpDestination) -> ConnectionSetupStep {
        switch destination {
        case .start, .dashboard: return .dashboard
        case .credentials: return .credentials
        case .network: return .accessMethod
        case .tls: return .tlsTroubleshooting
        case .cloudflare: return .cloudflareTroubleshooting
        case .currentConnection: return .connectionDetails
        case .repairConnection: return .connectionDetails
        }
    }

    /// Round 6 (Repair): start near the classified problem, always with the
    /// editable address one Back-step away. Deliberately not over-optimized —
    /// the user can navigate Back and edit the address if the initial
    /// diagnosis was wrong.
    static func repairPath(for draft: ConnectionSetupDraft, failure: ConnectionFailure?) -> [ConnectionSetupStep] {
        let details: [ConnectionSetupStep] = [.connectionDetails]
        switch failure {
        case .authenticationRejected:
            return details + [.loginCredentials]
        case .cloudflareTokenRejected:
            return details + [.cloudflareTroubleshooting]
        case .tlsUntrusted, .tlsBadDate, .tlsFailure:
            return details + [.tlsTroubleshooting]
        // Transport/dashboard/address problems and a password-login throttle
        // all start at the address editor. A throttled login in particular
        // must never route toward another login.
        case .invalidAddress, .insecureTransport, .hostNotFound, .unreachable,
             .connectionRefused, .timedOut, .offline, .rateLimited,
             .dashboardUnavailable, .unexpectedServerResponse:
            return details
        // No strong diagnosis (or none retained): the seeded staged test is
        // the diagnostic.
        case .loginRequired, .sessionTicketFailure, .unknown, nil:
            return (try? draft.testConfiguration()) != nil
                ? details + [.connectionTest]
                : details
        }
    }

    /// The path a fresh wizard starts on. The Settings current-connection
    /// entry skips the first-run readiness questions entirely; its shape
    /// depends on the seed:
    ///
    /// * Both credential fields empty means credentials are simply
    ///   UNAVAILABLE to the wizard (nothing saved, or a browser-auth
    ///   connection) — it is never an authentication mode. Provider
    ///   discovery runs fine without credentials and decides the auth mode,
    ///   so the wizard opens straight on the staged test, with the details
    ///   screen kept underneath so Back reaches an editable address
    ///   ("change your connection" must not require a failure first). A
    ///   password-capable dashboard stops at the credentials-required
    ///   partial outcome; an interactive one at browser sign-in required.
    /// * A username with an empty password is a native deployment whose
    ///   password was withheld (Face ID-protected record) or forgotten: it
    ///   lands on the prefilled details/credentials screens so the user is
    ///   asked for the password instead of testing without one. The
    ///   invariant either way: no password login happens until BOTH
    ///   credentials are present.
    /// * An address that cannot even be built falls back to the details
    ///   screen, which surfaces the validation.
    static func initialPath(
        for destination: ConnectionHelpDestination,
        draft: ConnectionSetupDraft,
        repairFailure: ConnectionFailure? = nil
    ) -> [ConnectionSetupStep] {
        if destination == .repairConnection {
            return repairPath(for: draft, failure: repairFailure)
        }
        guard destination == .currentConnection else {
            return [entryStep(for: destination)]
        }
        let credentialsEmpty =
            draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard credentialsEmpty, (try? draft.testConfiguration()) != nil else {
            return [entryStep(for: destination)]
        }
        return [.connectionDetails, .connectionTest]
    }

    /// True only for the Settings current-connection entry, so the few copy
    /// distinctions that would otherwise sound wrong to an already-connected
    /// user can be made without forking the wizard's wording.
    var enteredFromCurrentConnection: Bool { entry == .currentConnection }

    /// Round 6: true for the Repair entry, which owns the context-specific
    /// final actions (Reconnect Now / Sign In to Reconnect) and never the
    /// login-form handoff or the Settings Done/apply paths.
    var isRepairingConnection: Bool { entry == .repairConnection }

    /// Round 6 (Repair): a consumed or failed reconnect attempt invalidates
    /// the staged success that produced it — a fresh explicit test is
    /// required before another reconnect. Pops Review so the test screen is
    /// showing, with the same generation rotation as any other reset, so no
    /// late event from the consumed run can resurrect it.
    mutating func invalidateTestForRepairRetry() {
        testGeneration += 1
        testState = ConnectionSetupTestState()
        testSucceededAtRevision = nil
        validationError = nil
        if step == .review {
            path.removeLast()
        }
    }

    mutating func back() {
        guard canGoBack else { return }
        path.removeLast()
        validationError = nil
    }

    /// Answering Yes moves on; No / I don't know keep the question on screen
    /// with its Ask Hermes guidance until the user confirms readiness. The
    /// recorded answer is never rewritten by the confirmation — "ready" is a
    /// navigation action, not a retroactive Yes.
    mutating func answerDashboard(_ answer: ConnectionSetupAnswer) {
        dashboardAnswer = answer
        if answer == .yes {
            advance(to: .credentials)
        }
    }

    /// The "Dashboard is ready" continuation after the No / I don't know
    /// guidance. Step-gated like `confirmCredentialsReady()` so a stray call
    /// from any other step stays a deterministic no-op.
    mutating func confirmDashboardReady() {
        guard step == .dashboard else { return }
        advance(to: .credentials)
    }

    mutating func answerCredentials(_ answer: ConnectionSetupAnswer) {
        credentialsAnswer = answer
        if answer == .yes {
            confirmCredentialsReady()
        }
    }

    /// The continuation after the credentials No / I don't know guidance.
    mutating func confirmCredentialsReady() {
        guard step == .credentials else { return }
        // Authentication recovery can reuse the current expert URL without
        // asking unrelated readiness questions or decomposing it lossily.
        if entry == .credentials && draft.usesExistingAddress {
            advance(to: .loginCredentials)
        } else {
            advance(to: .accessMethod)
        }
    }

    mutating func selectAccessMethod(_ method: ConnectionAccessMethod) {
        draft.accessMethod = method
        draft.usesExistingAddress = false
        advance(to: Self.step(for: method))
    }

    /// "I have the connection details" on a branch screen.
    mutating func confirmDetailsReady() {
        guard [.lan, .tailscale, .reverseProxy].contains(step) else { return }
        advance(to: .connectionDetails)
    }

    mutating func useExistingAddress() {
        guard step == .accessMethod,
              !draft.existingServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.usesExistingAddress = true
        advance(to: .connectionDetails)
    }

    mutating func submitDetails() {
        guard step == .connectionDetails else { return }
        do {
            _ = try ConnectionSetupAddressBuilder.build(draft)
            advance(to: .loginCredentials)
        } catch { record(error) }
    }

    mutating func submitCredentials() {
        guard step == .loginCredentials else { return }
        // The Settings current-connection and Repair entries may proceed with
        // no credentials at all: provider discovery decides the auth mode,
        // and both contexts legitimately seed without credentials (a
        // browser-auth deployment, or an active connection whose password is
        // not saved). A missing-password stop is the supported partial
        // outcome. LoginView entries keep the strict requirement; a
        // first-run user must not spend a real server's login attempt on
        // empty credentials.
        let credentialsOptional = (enteredFromCurrentConnection || isRepairingConnection)
            && draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        do {
            if credentialsOptional {
                _ = try draft.testConfiguration()
            } else {
                _ = try draft.result()
            }
            advance(to: .connectionTest)
            // A test result validated against an OLDER draft must never
            // authorize this fresh entry: edits bump the revision, so any
            // stale success (or leftover failure display) resets to untested.
            if testSucceededAtRevision != draftRevision {
                testGeneration += 1
                testState = ConnectionSetupTestState()
                testSucceededAtRevision = nil
            }
        } catch let error as ConnectionSetupValidationError {
            if error != .credentialsRequired {
                advance(to: draft.usesExistingAddress || draft.accessMethod != nil ? .connectionDetails : .accessMethod)
            }
            record(error)
        } catch { record(error) }
    }

    /// Revalidate at the handoff boundary; producing values has no side
    /// effects. Acceptance requires a connection test that validated the
    /// CURRENT draft — either fully-tested native auth, or the supported
    /// interactive sign-in outcome after successful dashboard detection. An
    /// untested configuration is never handed off.
    mutating func complete() -> ConnectionSetupResult? {
        guard step == .review, canUseSettings else { return nil }
        switch acceptedResult() {
        case .success(let result): return result
        case .failure(let error): record(error); return nil
        }
    }

    /// The result Review can hand off: the fully-validated draft, or — only
    /// when the CURRENT staged outcome is the interactive-auth terminal — the
    /// address-only configuration. Discovery, not form presence, proved how
    /// that dashboard authenticates, so there is no password to require.
    /// Every other validation failure stays a failure.
    func acceptedResult() -> Result<ConnectionSetupResult, ConnectionSetupValidationError> {
        do { return .success(try draft.result()) }
        catch {
            if (error as? ConnectionSetupValidationError) == .credentialsRequired,
               hasCurrentInteractiveAuthOutcome,
               let addressOnly = try? draft.testConfiguration() {
                return .success(addressOnly)
            }
            let validationError = error as? ConnectionSetupValidationError ?? .policy(.invalidURL)
            return .failure(validationError)
        }
    }

    /// Pure revalidation for rendering the Review card: the validated result
    /// when the draft is still complete, otherwise the typed validation error
    /// the screen must show. Never mutates the path, so a revalidation
    /// failure can never silently blank the Review content — the view renders
    /// the failure branch instead.
    func reviewState() -> Result<ConnectionSetupResult, ConnectionSetupValidationError> {
        acceptedResult()
    }

    private mutating func record(_ error: Error) {
        validationError = error as? ConnectionSetupValidationError ?? .policy(.invalidURL)
    }

    // MARK: - Round 4: staged connection test

    /// True only when every stage succeeded against the CURRENT draft. Any
    /// draft edit (address, port, scheme, username, password, access method)
    /// immediately invalidates a prior success — the revision no longer
    /// matches, so Review can no longer authorize the old result.
    var hasCurrentSuccessfulTest: Bool {
        testState.allSucceeded && testSucceededAtRevision == draftRevision
    }

    /// The same fact as `hasCurrentSuccessfulTest`, named for the auth-mode
    /// distinction the interactive outcome introduced: native password
    /// authentication fully succeeded (login + ticket) against the current
    /// draft. Never true for the interactive outcome — there, the user has
    /// not authenticated yet.
    var fullyAuthenticated: Bool { hasCurrentSuccessfulTest }

    /// The supported interactive-auth terminal outcome against the CURRENT
    /// draft: server and dashboard succeeded and authentication stopped at
    /// "browser sign-in required". Draft edits invalidate it exactly like a
    /// native success, and it is deliberately not a failure — so the
    /// recovery-plan machinery never treats it as one.
    var hasCurrentInteractiveAuthOutcome: Bool {
        testState.requiresInteractiveSignIn && testSucceededAtRevision == draftRevision
    }

    /// Review / "Use These Settings" authorization. Exactly two states
    /// qualify: fully tested native auth, or interactive sign-in required
    /// after successful dashboard detection. There is deliberately no
    /// generic "use without testing" bypass — both qualifying states have
    /// verified transport, dashboard identity, and the expected auth
    /// behavior; only the user's own auth step can remain.
    var canUseSettings: Bool {
        hasCurrentSuccessfulTest || hasCurrentInteractiveAuthOutcome
    }

    /// Round 5: the CURRENT staged test validated a configuration
    /// byte-identical to the one the wizard was seeded with, so Review can
    /// offer plain Done — there is nothing to apply. Gated to the Settings
    /// current-connection entry: the LoginView wizard must always offer its
    /// normal "Use these settings" handoff, even when the user edited
    /// nothing. Any draft edit (address, credentials, route) breaks equality
    /// exactly like it breaks the staged test's revision match.
    var testedSettingsUnchanged: Bool {
        enteredFromCurrentConnection && canUseSettings && draft == seededDraft
    }

    /// The inherited Cloudflare token, ONLY when it is same-origin with the
    /// draft's current address. A service token entered for one dashboard is
    /// never sent to a different origin during the test (Round-3 origin
    /// safety); the wizard never sends a token it cannot origin-verify.
    func cloudflareAccessForDraft() -> CloudflareAccessCredentials? {
        guard let access = inheritedCloudflareAccess, access.isConfigured else { return nil }
        let origin = inheritedCloudflareOriginURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origin.isEmpty, let result = try? draft.testConfiguration() else { return nil }
        return LoginCloudflareHandoff.sameOrigin(result.serverURL, origin) ? access : nil
    }

    /// Starts a staged test run: resets prior results and returns the new
    /// generation token, or nil when a test cannot start. Tests never queue:
    /// the wrong step or an already-running probe is a deterministic no-op
    /// (the view also disables the Test button while running).
    mutating func beginTest() -> Int? {
        guard step == .connectionTest, !testState.isRunning else { return nil }
        testGeneration += 1
        testState = ConnectionSetupTestState()
        testSucceededAtRevision = nil
        return testGeneration
    }

    /// Applies one probe event to the staged state, returning whether it was
    /// applied. Events from an obsolete generation — superseded by
    /// cancellation, a newer run, or a draft reset — are ignored, so a late
    /// completion can never overwrite newer state. A terminal event (full
    /// native success, or the interactive sign-in outcome) seals the result
    /// at the current draft revision and advances to Review. The
    /// credentials-required partial outcome also terminates the RUN but
    /// deliberately seals nothing and navigates nowhere: it authorizes
    /// nothing (`canUseSettings` stays false) and stays on the test screen
    /// with its Enter Credentials recovery.
    @discardableResult
    mutating func applyTestEvent(_ event: ConnectionSetupTestEvent, generation: Int) -> Bool {
        guard generation == testGeneration, step == .connectionTest else { return false }
        testState.apply(event)
        switch event {
        case .succeeded(.authentication), .requiresInteractiveSignIn(.authentication):
            testSucceededAtRevision = draftRevision
            advance(to: .review)
        default:
            break
        }
        return true
    }

    /// Cancels in-flight test work: any running stage resets to untested and
    /// the generation invalidates so late probe events are dropped. A
    /// completed success or failure display is left untouched — cancelling
    /// only retracts unfinished work.
    mutating func cancelTest() {
        guard testState.isRunning else { return }
        testGeneration += 1
        testState = ConnectionSetupTestState()
        testSucceededAtRevision = nil
    }

    /// Failure remediation: leave the test screen for the step that owns the
    /// failed inputs (connection details for transport/dashboard failures,
    /// credentials for authentication failures). Falls back to inserting the
    /// details step after credentials for the short auth-recovery route,
    /// which enters the wizard past the details screen. Leaving the test
    /// step also invalidates any in-flight run's generation and resets the
    /// staged state, so no leftover failure display or terminal outcome can
    /// outlive the remediation.
    mutating func editAfterFailedTest(_ target: ConnectionSetupStep) {
        guard step == .connectionTest,
              target == .connectionDetails || target == .loginCredentials else { return }
        if let index = path.lastIndex(of: target) {
            path.removeSubrange(path.index(after: index)...)
        } else if let credentialsIndex = path.lastIndex(of: .loginCredentials) {
            path.removeSubrange(path.index(after: credentialsIndex)...)
            advance(to: target)
        } else {
            advance(to: target)
        }
        validationError = nil
        testGeneration += 1
        testState = ConnectionSetupTestState()
        testSucceededAtRevision = nil
    }

    /// Continue from the test screen to Review when a current qualifying
    /// test exists (e.g. after returning Back from Review).
    mutating func continueToReview() {
        guard step == .connectionTest, canUseSettings else { return }
        advance(to: .review)
    }

    /// Topic switching on the troubleshooting surfaces (TLS ⇄ Cloudflare).
    /// Switching REPLACES the current troubleshooting step rather than
    /// pushing, so repeated flips never grow the back path; Back then exits
    /// troubleshooting toward whatever preceded it. Ignored for wizard
    /// destinations, which route through the questions.
    mutating func showTroubleshooting(_ destination: ConnectionHelpDestination) {
        guard destination == .tls || destination == .cloudflare else { return }
        let target = Self.entryStep(for: destination)
        guard target != step else { return }
        if let last = path.last, last == .tlsTroubleshooting || last == .cloudflareTroubleshooting {
            path[path.count - 1] = target
        } else {
            path.append(target)
        }
    }

    static func step(for method: ConnectionAccessMethod) -> ConnectionSetupStep {
        switch method {
        case .lan: return .lan
        case .tailscale: return .tailscale
        case .reverseProxy: return .reverseProxy
        }
    }

    private mutating func advance(to step: ConnectionSetupStep) {
        guard step != self.step else { return }
        validationError = nil
        path.append(step)
    }
}
