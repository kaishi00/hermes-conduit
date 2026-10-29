//
//  LoginFlowModel.swift
//  Conduit
//
//  The sign-in flow behind the sign-in screen and the Add a dashboard sheet:
//  the address first, then only what that dashboard needs (a username and
//  password, or its browser sign-in). A saved dashboard signs in from its
//  row. How a dashboard signs in is the shared DashboardSignInResolver's
//  decision, the same one Connection Setup's test and Repair make, and an
//  answer only counts for the address and token it was asked with.
//

import Foundation
import Observation
import os

/// Where a failure is shown: under the step or the dashboard it happened to.
enum LoginFailurePlace: Equatable {
    case address
    case credentials
    case dashboard(UUID)
}

/// How a dashboard signs in, from its provider discovery.
enum LoginRoute: Equatable {
    /// Username and password. `browserOffer` is set when the dashboard also
    /// offers a browser sign-in: the step's "Sign in with browser instead".
    case password(browserOffer: DashboardBrowserSignInOffer?)
    /// Safari (Hermes' native sign-in) or the dashboard's own sign-in page
    /// in the in-app browser.
    case interactive(DashboardInteractiveSignIn)

    init(_ mode: DashboardSignInMode) {
        switch mode {
        case .password: self = .password(browserOffer: nil)
        case .passwordOrBrowser(let offer): self = .password(browserOffer: offer)
        case .interactive(let signIn): self = .interactive(signIn)
        }
    }

    /// The shared decision, without typed credentials to weigh: a dashboard
    /// that takes a password gets the password step, and its browser
    /// sign-in becomes the step's alternative. A dashboard that offers both
    /// asks for its native capability only once that alternative is picked,
    /// so a failing check never hides the password or quietly turns into
    /// another sign-in. A page that isn't Hermes, or a provider list naming
    /// no sign-in, is an error, never the browser.
    static func discover(using client: any DashboardSignInTransport) async throws -> LoginRoute {
        LoginRoute(try await DashboardSignInResolver.resolve(using: client))
    }
}

/// The dashboard a sign-in step is for, once its address checked out.
struct LoginTarget {
    let baseURL: String
    let label: String
    let cloudflare: CloudflareAccessCredentials?
    /// The browser sign-in the dashboard also offers, if any.
    let browserOffer: DashboardBrowserSignInOffer?
}

/// A native single sign-on sheet to present.
struct LoginNativeOAuthRequest: Identifiable {
    let id = UUID()
    let baseURL: String
    let provider: String?
    let dashboardID: UUID
    let cloudflare: CloudflareAccessCredentials?
}

/// An in-app browser sign-in to present.
struct LoginBrowserRequest: Identifiable {
    let id = UUID()
    let baseURL: String
    let cloudflare: CloudflareAccessCredentials?
    /// The WebKit session store for this sign-in (#148): the saved
    /// dashboard's own, registered first for a new address.
    let webKitStoreID: UUID
}

/// The extra-header editor's address, captured when it is opened.
struct LoginExtraHeadersRequest: Identifiable {
    let id = UUID()
    let serverURL: String
}

/// What the Connection Setup assistant (or a later scan) fills in.
struct LoginSeed: Identifiable {
    let id = UUID()
    var address: String
    var username: String
    var password: String
    var cloudflare: LoginCloudflareState

    /// Nothing filled in.
    static var blank: LoginSeed {
        LoginSeed(address: "", username: "", password: "", cloudflare: LoginCloudflareState(isEnabled: false, clientID: "", clientSecret: ""))
    }
}

// MARK: - Address

/// Turns what was typed into the addresses to try, so the address can be
/// typed without its scheme.
enum LoginAddress {
    /// The candidates for a typed address, best first. One with a scheme is
    /// used as typed. Without one, https comes first; plain http joins only
    /// for hosts where Conduit allows it (localhost, private LAN, Tailscale),
    /// and leads for IP addresses and localhost, which are usually Hermes'
    /// own plain port.
    static func candidates(_ typed: String) -> [String] {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains("://") { return [trimmed] }
        let bare = trimmed.hasPrefix("//") ? String(trimmed.dropFirst(2)) : trimmed
        let secure = "https://" + bare
        let plain = "http://" + bare
        guard (try? ConnectionURLPolicy.normalizedBaseURL(plain)) != nil else { return [secure] }
        return prefersPlainHTTP(plain) ? [plain, secure] : [secure, plain]
    }

    private static func prefersPlainHTTP(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        if host == "localhost" || host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in !part.isEmpty && part.allSatisfy(\.isNumber) }
    }

    /// Whether a failed check is worth repeating at the next candidate. A
    /// wrong scheme fails fast (a TLS error, a refused connection, a page
    /// that isn't Hermes); a host that doesn't answer at all, a name that
    /// doesn't resolve, or no network won't answer the other scheme either.
    static func shouldTryNextCandidate(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .dnsLookupFailed,
                 .notConnectedToInternet, .cancelled, .dataNotAllowed, .internationalRoamingOff:
                return false
            default:
                return true
            }
        }
        if let authError = error as? AuthClientError, case .cloudflareServiceTokenRejected = authError {
            return false
        }
        return true
    }

    /// The address as the lists show it: the host, its port and any path.
    static func displayHost(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            return url
        }
        var shown = host
        if let port = components.port { shown += ":\(port)" }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty { shown += "/" + path }
        return shown
    }

    /// The first candidate that passes the address policy, for tools that
    /// need a whole address before the check runs (extra headers, Connection
    /// Setup). Falls back to what was typed.
    static func bestGuess(_ typed: String) -> String {
        for candidate in candidates(typed) {
            if let normalized = try? ConnectionURLPolicy.normalizedBaseURL(candidate) { return normalized }
        }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Flow

@MainActor
@Observable
final class LoginFlowModel {
    private static let logger = Logger(subsystem: "com.milim.relay", category: "login")

    // The address step. An edit makes any answer still on its way for the
    // old address (or token) stale: it is dropped, never followed.
    var address = "" {
        didSet { if address != oldValue { inputsChanged() } }
    }
    var cloudflareEnabled = false {
        didSet { if cloudflareEnabled != oldValue { inputsChanged() } }
    }
    var cloudflareClientID = "" {
        didSet { if cloudflareClientID != oldValue { inputsChanged() } }
    }
    var cloudflareClientSecret = "" {
        didSet { if cloudflareClientSecret != oldValue { inputsChanged() } }
    }
    var showsAdvanced = false

    // The sign-in step.
    var username = ""
    var password = ""
    var saveSignIn = true
    var useBiometrics = false
    private(set) var biometrics = BiometricAuth.Status(kind: nil, isAvailable: false)
    var showsCredentials = false
    private(set) var target: LoginTarget?

    // Progress and failures.
    private(set) var isWorking = false
    /// The saved dashboard whose row is signing in.
    private(set) var workingDashboardID: UUID?
    private(set) var failure: ConnectionFailurePresentation?
    private(set) var failurePlace: LoginFailurePlace?
    /// Whether the failed saved connection can be repaired, worked out when
    /// the failure arrives (the takeover itself waits for the tap).
    private(set) var savedRepairAvailable = false

    // What the screens present.
    var nativeOAuthRequest: LoginNativeOAuthRequest?
    var browserRequest: LoginBrowserRequest?
    var connectionSetupDestination: ConnectionHelpDestination?
    var connectionRepairContext: ConnectionRepairContext?
    var extraHeadersRequest: LoginExtraHeadersRequest?
    var extraHeadersRevision = 0
    var showsScanner = false
    /// A scanned sign-in code, asked about in its own sheet.
    var pendingLink: DashboardConnectLink?

    /// Runs once a sign-in has handed its session to AppState (the Add
    /// sheet closes there).
    @ObservationIgnored var onSignedIn: () -> Void = {}

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var biometricsLoaded = false
    /// The username the flow filled in itself, replaced when the next
    /// dashboard has its own.
    @ObservationIgnored private var prefilledUsername: String?
    /// Where the running action's failures belong, also for the ones AppState
    /// hands over after the session starts.
    @ObservationIgnored private var runningPlace: LoginFailurePlace?
    /// What the scanner read, handled once its sheet has closed.
    @ObservationIgnored private var scanResult: DashboardConnectLink.Scan?
    /// The flow signs in from a sign-in code: its retry signs in again
    /// rather than stopping at the sign-in step.
    @ObservationIgnored private var signsInFromLink = false
    /// Addresses a browser or single sign-on attempt saved before anyone
    /// signed in to them: the sheets need the dashboard to exist first.
    @ObservationIgnored private var unfinishedAddresses: Set<String> = []
    /// Bumped by every edit of the address or the Cloudflare token: an
    /// answer counts only while the inputs it was asked with are on screen.
    @ObservationIgnored private var inputGeneration = 0
    private let makeTransport: (String, CloudflareAccessCredentials?) -> any DashboardSignInTransport

    init(
        makeTransport: @escaping (String, CloudflareAccessCredentials?) -> any DashboardSignInTransport = {
            NativeAuthClient(baseURL: $0, cloudflareAccess: $1)
        }
    ) {
        self.makeTransport = makeTransport
    }

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    private func inputsChanged() {
        inputGeneration += 1
        // A sign-in code's credentials belong to its own dashboard: once the
        // address or the token is edited, Retry checks the address again
        // instead of sending them to whatever is typed now.
        signsInFromLink = false
    }

    // MARK: Fields

    var typedCloudflare: CloudflareAccessCredentials? {
        guard cloudflareEnabled else { return nil }
        return CloudflareAccessCredentials.from(clientID: cloudflareClientID, clientSecret: cloudflareClientSecret)
    }

    var cloudflareState: LoginCloudflareState {
        LoginCloudflareState(isEnabled: cloudflareEnabled, clientID: cloudflareClientID, clientSecret: cloudflareClientSecret)
    }

    /// The service token is switched on but a field is still empty: it
    /// would be dropped, not sent, so the address step waits for it.
    var cloudflareIncomplete: Bool {
        cloudflareEnabled && typedCloudflare == nil
    }

    var canContinue: Bool {
        LoginView.hasConnectableInput(serverURL: address) && !cloudflareIncomplete && !isWorking
    }

    var canSignIn: Bool {
        target != nil && !isWorking
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setSaveSignIn(_ saves: Bool) {
        saveSignIn = saves
        if !saves { useBiometrics = false }
    }

    /// Reads the phone's Face ID or Touch ID state. The switch starts on
    /// when the phone has one, and turns off when it goes away.
    func refreshBiometrics() {
        biometrics = BiometricAuth.status
        if !biometricsLoaded {
            biometricsLoaded = true
            useBiometrics = biometrics.isAvailable && saveSignIn
        } else if !biometrics.isAvailable {
            useBiometrics = false
        }
    }

    func apply(_ seed: LoginSeed) {
        cloudflareEnabled = seed.cloudflare.isEnabled
        cloudflareClientID = seed.cloudflare.clientID
        cloudflareClientSecret = seed.cloudflare.clientSecret
        if cloudflareEnabled { showsAdvanced = true }
        address = seed.address
        username = seed.username
        password = seed.password
        prefilledUsername = nil
        clearFailure()
    }

    /// The Connection Setup assistant's result, through the tested mapping
    /// that drops an in-memory Cloudflare token when the origin changes.
    /// A sign-in code's username and password stay with the code's own
    /// dashboard: when the assistant moved the address elsewhere, the next
    /// Sign in opens the sign-in step instead of sending them there.
    func applySetupResult(_ result: ConnectionSetupResult) {
        let oldAddress = LoginAddress.bestGuess(address)
        let handoff = LoginCloudflareHandoff.apply(result, to: oldAddress, keeping: cloudflareState)
        let leavesTheCodesDashboard = signsInFromLink
            && !LoginCloudflareHandoff.sameOrigin(oldAddress, handoff.serverURL)
        apply(LoginSeed(
            address: handoff.serverURL,
            username: leavesTheCodesDashboard ? "" : handoff.username,
            password: leavesTheCodesDashboard ? "" : handoff.password,
            cloudflare: handoff.cloudflare
        ))
    }

    func clearFailure() {
        failure = nil
        failurePlace = nil
        savedRepairAvailable = false
    }

    private func show(_ presentation: ConnectionFailurePresentation, at place: LoginFailurePlace) {
        failure = presentation
        failurePlace = place
        savedRepairAvailable = false
    }

    private func show(error: Error, at place: LoginFailurePlace) {
        // The classification only: the raw error can carry server text.
        let classified = ConnectionFailureClassifier.classify(error)
        Self.logger.error("Sign-in failed: \(String(describing: classified), privacy: .public)")
        show(.presenting(classified), at: place)
    }

    /// A failure AppState hands over (a saved sign-in that was refused, a
    /// session that didn't start). It shows under the dashboard it was for.
    func receive(_ pending: ConnectionFailurePresentation) {
        guard let appState else { return }
        let place: LoginFailurePlace
        if let runningPlace {
            place = runningPlace
        } else if let active = appState.activeDashboardID,
                  appState.savedDashboardRegistry.dashboard(with: active) != nil {
            place = .dashboard(active)
        } else {
            place = .address
        }
        failure = pending
        failurePlace = place
        savedRepairAvailable = appState.makeSavedConnectionRepairContext() != nil
    }

    func failure(at place: LoginFailurePlace) -> ConnectionFailurePresentation? {
        failurePlace == place ? failure : nil
    }

    // MARK: Retry

    func retry() async {
        switch failurePlace {
        case .address:
            if signsInFromLink {
                await signInFromLink()
            } else {
                await continueFromAddress()
            }
        case .credentials: await signIn()
        case .dashboard(let id):
            guard let dashboard = appState?.savedDashboardRegistry.dashboard(with: id) else { return }
            await open(dashboard)
        case nil: return
        }
    }

    func beginRepair() {
        connectionRepairContext = appState?.beginSavedConnectionRepair()
    }

    // MARK: A saved dashboard

    /// A row's tap: its saved sign-in when it has one (Face ID asks first
    /// when it guards it), otherwise straight to what its sign-in needs,
    /// with its username and Cloudflare token filled in.
    func open(_ dashboard: SavedDashboard) async {
        guard let appState, !isWorking else { return }
        clearFailure()
        isWorking = true
        workingDashboardID = dashboard.id
        runningPlace = .dashboard(dashboard.id)
        defer {
            isWorking = false
            workingDashboardID = nil
            runningPlace = nil
        }
        if appState.savedSignIn(for: dashboard.id).canSignInWithoutTyping {
            await appState.switchDashboard(to: dashboard.id)
            if appState.isConnected || !appState.showLogin { return }
            // A refused saved sign-in shows under its row; a dismissed Face
            // ID prompt leaves the row as it was, to ask again on the next
            // tap. A dashboard with nothing left to sign in with goes on to
            // its sign-in, and so does a Face ID one on a phone where Face
            // ID is off now: it would never ask.
            if failure != nil || appState.pendingLoginFailure != nil { return }
            let left = appState.savedSignIn(for: dashboard.id)
            if left.canSignInWithoutTyping, left != .biometric || BiometricAuth.status.isAvailable {
                return
            }
        }
        appState.lastConnectionFailure = nil
        // Its sign-in goes to the address edited for it in Settings.
        let dashboard = appState.dashboardForSignIn(dashboard.id) ?? dashboard
        let cloudflare = appState.dashboardScopedCloudflareAccess(for: dashboard.normalizedURL)
        do {
            let route = try await LoginRoute.discover(using: makeTransport(dashboard.normalizedURL, cloudflare))
            follow(route, baseURL: dashboard.normalizedURL, label: dashboard.label, cloudflare: cloudflare, place: .dashboard(dashboard.id))
        } catch is CancellationError {
            return
        } catch {
            show(error: error, at: .dashboard(dashboard.id))
        }
    }

    // MARK: The address step

    /// `opensSignInStep` false leaves a password dashboard's sign-in step
    /// closed, for a sign-in code that already carries the password.
    func continueFromAddress(opensSignInStep: Bool = true) async {
        guard let appState, !isWorking else { return }
        // A typed sign-in abandons the repair context of an earlier failed
        // saved connection: Repair is for the connection that failed.
        appState.lastConnectionFailure = nil
        let candidates = LoginAddress.candidates(address)
        guard !candidates.isEmpty else {
            show(.notice(title: AppLocalization.string("Enter a valid dashboard URL.")), at: .address)
            return
        }
        // A half-typed service token never falls back to no token, or to an
        // older one saved for this address: the keyboard's last Return
        // reaches here even when Continue is off.
        guard !cloudflareIncomplete else {
            show(.notice(title: AppLocalization.string(
                "Enter both the Cloudflare Client ID and Client Secret, or turn off the service token."
            )), at: .address)
            return
        }
        // Keep WHICH address rule failed: a malformed address and plain http
        // to a remote host are different mistakes with different fixes.
        var addresses: [String] = []
        var policyError: Error?
        for candidate in candidates {
            do {
                addresses.append(try ConnectionURLPolicy.normalizedBaseURL(candidate))
            } catch {
                policyError = policyError ?? error
            }
        }
        guard !addresses.isEmpty else {
            show(error: policyError ?? ConnectionURLPolicyError.invalidURL, at: .address)
            return
        }
        clearFailure()
        isWorking = true
        runningPlace = .address
        defer {
            isWorking = false
            runningPlace = nil
        }
        // The answer belongs to the address and token typed now: an edit
        // while it is on its way drops it, so a late answer never opens a
        // sign-in, a sheet or a saved dashboard for what is no longer typed.
        let generation = inputGeneration
        let typedCloudflare = self.typedCloudflare
        var firstError: Error?
        for baseURL in addresses {
            // A saved dashboard at this address lends its Cloudflare token
            // when none was typed.
            let cloudflare = typedCloudflare ?? appState.dashboardScopedCloudflareAccess(for: baseURL)
            do {
                let route = try await LoginRoute.discover(using: makeTransport(baseURL, cloudflare))
                guard generation == inputGeneration else { return }
                address = baseURL
                appState.rememberDashboardURL(baseURL)
                let saved = appState.savedDashboardRegistry.dashboard(atNormalizedURL: baseURL)
                follow(
                    route,
                    baseURL: baseURL,
                    label: saved?.label ?? SavedDashboardLabel.derive(from: baseURL),
                    cloudflare: cloudflare,
                    place: .address,
                    opensSignInStep: opensSignInStep
                )
                return
            } catch is CancellationError {
                return
            } catch {
                guard generation == inputGeneration else { return }
                firstError = firstError ?? error
                guard LoginAddress.shouldTryNextCandidate(after: error) else { break }
            }
        }
        if let firstError { show(error: firstError, at: .address) }
    }

    private func follow(
        _ route: LoginRoute,
        baseURL: String,
        label: String,
        cloudflare: CloudflareAccessCredentials?,
        place: LoginFailurePlace,
        opensSignInStep: Bool = true
    ) {
        switch route {
        case .password(let browserOffer):
            if let previous = target, previous.baseURL != baseURL { password = "" }
            target = LoginTarget(baseURL: baseURL, label: label, cloudflare: cloudflare, browserOffer: browserOffer)
            prefillUsername(for: baseURL)
            if opensSignInStep { showsCredentials = true }
        case .interactive(let signIn):
            open(signIn, baseURL: baseURL, cloudflare: cloudflare, place: place)
        }
    }

    private func open(
        _ signIn: DashboardInteractiveSignIn,
        baseURL: String,
        cloudflare: CloudflareAccessCredentials?,
        place: LoginFailurePlace
    ) {
        switch signIn {
        case .nativeOAuth(let provider):
            startNativeOAuth(baseURL: baseURL, provider: provider, cloudflare: cloudflare, place: place)
        case .browser:
            startBrowserSignIn(baseURL: baseURL, cloudflare: cloudflare, place: place)
        }
    }

    /// The username for the next sign-in: what was typed, else the one that
    /// last signed in to this dashboard. A password behind Face ID keeps its
    /// username to itself until Face ID opens it.
    private func prefillUsername(for baseURL: String) {
        guard let appState else { return }
        let typed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty || username == prefilledUsername else { return }
        guard let id = appState.resolveDashboardID(forURL: baseURL, registerIfMissing: false) else {
            if prefilledUsername != nil { username = "" }
            prefilledUsername = nil
            return
        }
        var remembered = appState.savedDashboardRegistry.dashboard(with: id)?.username
        if remembered?.isEmpty ?? true,
           let credentials = KeychainHelper.loadCredentials(dashboardID: id), !credentials.requiresFaceID {
            remembered = credentials.username
        }
        username = remembered ?? ""
        prefilledUsername = remembered
    }

    // MARK: The sign-in step

    func signIn() async {
        guard let appState, let target, !isWorking else { return }
        appState.lastConnectionFailure = nil
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            show(.notice(title: AppLocalization.string("Enter your dashboard username and password.")), at: .credentials)
            return
        }
        clearFailure()
        isWorking = true
        runningPlace = .credentials
        defer {
            isWorking = false
            runningPlace = nil
        }
        // What is saved is what was sent: the fields stay editable while the
        // sign-in runs, so they are read once, here.
        let username = self.username
        let password = self.password
        let saveSignIn = self.saveSignIn
        let useBiometrics = self.useBiometrics
        do {
            let client = makeTransport(target.baseURL, target.cloudflare)
            let authenticated = try await client.connect(username: username, password: password)
            if let dashboardID = appState.resolveDashboardID(forURL: target.baseURL, registerIfMissing: true) {
                if saveSignIn {
                    KeychainHelper.saveCredentials(DashboardCredentials(
                        baseURL: target.baseURL,
                        username: username,
                        password: password,
                        requiresFaceID: useBiometrics
                    ), dashboardID: dashboardID)
                } else {
                    appState.clearSavedPassword(dashboardID: dashboardID)
                }
                if let cloudflare = target.cloudflare {
                    KeychainHelper.saveCloudflareAccess(cloudflare, origin: target.baseURL, dashboardID: dashboardID)
                } else {
                    KeychainHelper.clearCloudflareAccess(dashboardID: dashboardID)
                }
                appState.rememberDashboardUsername(username, dashboardID: dashboardID)
                authenticated.commitCookies(dashboardID: dashboardID)
            }
            appState.prepareInteractiveSignIn(baseURL: target.baseURL)
            await appState.connect(with: HermesConnection(baseUrl: target.baseURL, ticket: authenticated.ticket))
            finishSignIn(at: target.baseURL)
        } catch is CancellationError {
            return
        } catch {
            show(error: error, at: .credentials)
        }
    }

    /// The sign-in step's "Sign in with browser instead". A provider that
    /// can sign in natively asks the dashboard for that capability now that
    /// it is picked, unless its provider answer advertised it: a failed
    /// check shows on the step, with the password still there, and never
    /// opens another sign-in instead.
    func signInWithBrowserInstead() async {
        guard let target, let offer = target.browserOffer, !isWorking else { return }
        clearFailure()
        if let decided = offer.decidedSignIn {
            open(decided, baseURL: target.baseURL, cloudflare: target.cloudflare, place: .credentials)
            return
        }
        isWorking = true
        runningPlace = .credentials
        defer {
            isWorking = false
            runningPlace = nil
        }
        let generation = inputGeneration
        let resolver = DashboardSignInResolver(client: makeTransport(target.baseURL, target.cloudflare))
        do {
            let signIn = try await resolver.signIn(for: offer)
            guard generation == inputGeneration, self.target?.baseURL == target.baseURL else { return }
            open(signIn, baseURL: target.baseURL, cloudflare: target.cloudflare, place: .credentials)
        } catch is CancellationError {
            return
        } catch {
            guard generation == inputGeneration, self.target?.baseURL == target.baseURL else { return }
            show(error: error, at: .credentials)
        }
    }

    // MARK: Sign-in codes

    /// The scanner read a code. Returns false when it isn't one Conduit can
    /// sign in to, so the scanner keeps looking.
    func scanned(_ text: String) -> Bool {
        let result = DashboardConnectLink.scan(text)
        if case .unreadable = result { return false }
        scanResult = result
        showsScanner = false
        return true
    }

    /// Handles the scan once the scanner has closed: a sign-in code opens
    /// its own sheet, which can't show over the scanner's.
    func scannerDismissed() {
        guard let result = scanResult else { return }
        scanResult = nil
        switch result {
        case .link(let link):
            pendingLink = link
        case .address(let scanned):
            address = scanned
            if LoginAddress.isOnlyOnHermesComputer(scanned) {
                show(Self.onlyOnHermesComputerNotice, at: .address)
                return
            }
            clearFailure()
            Task { await continueFromAddress() }
        case .unreadable:
            return
        }
    }

    /// A sign-in code naming localhost: the computer running Hermes.
    static var onlyOnHermesComputerNotice: ConnectionFailurePresentation {
        .notice(
            title: AppLocalization.string("This address only works on the computer running Hermes."),
            message: AppLocalization.string("Ask Hermes for its Tailscale or network address instead.")
        )
    }

    /// A sign-in code's Sign in: the dashboard check, then the password
    /// sign-in straight away when the code carries a username and password.
    /// A refused password opens the sign-in step to correct it.
    func signInFromLink() async {
        guard !isWorking else { return }
        signsInFromLink = true
        let hasPassword = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        target = nil
        await continueFromAddress(opensSignInStep: !hasPassword)
        guard hasPassword, failure == nil, target != nil,
              nativeOAuthRequest == nil, browserRequest == nil else { return }
        await signIn()
        if failurePlace == .credentials { showsCredentials = true }
    }

    // MARK: Browser sign-ins

    private func startNativeOAuth(
        baseURL: String,
        provider: String?,
        cloudflare: CloudflareAccessCredentials?,
        place: LoginFailurePlace
    ) {
        guard let appState else { return }
        noteUnsavedSignIn(at: baseURL)
        guard let dashboardID = appState.resolveDashboardID(forURL: baseURL, registerIfMissing: true) else {
            show(.notice(title: AppLocalization.string("Could not save this dashboard.")), at: place)
            return
        }
        if let cloudflare {
            KeychainHelper.saveCloudflareAccess(cloudflare, origin: baseURL, dashboardID: dashboardID)
        }
        browserPlace = place
        nativeOAuthRequest = LoginNativeOAuthRequest(baseURL: baseURL, provider: provider, dashboardID: dashboardID, cloudflare: cloudflare)
    }

    private func startBrowserSignIn(baseURL: String, cloudflare: CloudflareAccessCredentials?, place: LoginFailurePlace) {
        guard let appState else { return }
        // The WebKit session is the dashboard's own identified store, never
        // the default one: sibling-host cookies must not cross dashboards.
        // A new address is registered first, so the store is the one its
        // saved dashboard keeps: Sign Out, Remove Dashboard and an abandoned
        // attempt's cleanup all clear that same store.
        noteUnsavedSignIn(at: baseURL)
        guard let dashboardID = appState.resolveDashboardID(forURL: baseURL, registerIfMissing: true) else {
            show(.notice(title: AppLocalization.string("Could not save this dashboard.")), at: place)
            return
        }
        // The service token belongs to the dashboard it opens.
        if let cloudflare {
            KeychainHelper.saveCloudflareAccess(cloudflare, origin: baseURL, dashboardID: dashboardID)
        }
        browserPlace = place
        browserRequest = LoginBrowserRequest(baseURL: baseURL, cloudflare: cloudflare, webKitStoreID: dashboardID)
    }

    /// Where a browser sign-in's failure shows once its sheet reports one.
    @ObservationIgnored private var browserPlace: LoginFailurePlace = .address

    /// Remembers an address with no saved dashboard yet, before a browser or
    /// single sign-on sheet saves one for it.
    func noteUnsavedSignIn(at baseURL: String) {
        guard let appState, appState.resolveDashboardID(forURL: baseURL, registerIfMissing: false) == nil else { return }
        unfinishedAddresses.insert(baseURL)
    }

    /// A sign-in finished: its dashboard stays whatever happens to the sheet.
    private func finishSignIn(at baseURL: String) {
        if let appState, let id = appState.resolveDashboardID(forURL: baseURL, registerIfMissing: false) {
            unfinishedAddresses = unfinishedAddresses.filter {
                appState.resolveDashboardID(forURL: $0, registerIfMissing: false) != id
            }
        }
        onSignedIn()
    }

    /// Add a dashboard closed: forgets the dashboards its browser or single
    /// sign-on attempts saved when nobody signed in to them, with the
    /// Cloudflare token saved for the attempt.
    func discardUnfinishedDashboards() {
        guard let appState else { return }
        let addresses = unfinishedAddresses
        unfinishedAddresses = []
        for address in addresses {
            guard let id = appState.resolveDashboardID(forURL: address, registerIfMissing: false),
                  id != appState.activeDashboardID,
                  appState.savedSignIn(for: id) == .signInNeeded else { continue }
            appState.removeDashboard(id)
        }
    }

    func nativeOAuthSucceeded(_ result: NativeOAuthLoginResult, request: LoginNativeOAuthRequest) async {
        guard let appState else { return }
        clearFailure()
        guard await appState.connectWithNativeOAuth(result, baseURL: request.baseURL) else {
            show(.notice(
                title: AppLocalization.string("Sign-in failed."),
                message: AppLocalization.string("Please try again.")
            ), at: browserPlace)
            return
        }
        if request.cloudflare == nil {
            KeychainHelper.clearCloudflareAccess(dashboardID: request.dashboardID)
        }
        finishSignIn(at: request.baseURL)
    }

    func nativeOAuthFailed(_ error: Error) {
        Self.logger.error("Native OAuth sign-in failed: \(String(describing: type(of: error)), privacy: .public)")
        show(.notice(
            title: AppLocalization.string("Sign-in failed."),
            message: (error as? LocalizedError)?.errorDescription ?? AppLocalization.string("Please try again.")
        ), at: browserPlace)
    }

    func browserDeliveredTicket(_ ticket: String, baseURL: String) async {
        guard let appState else { return }
        browserRequest = nil
        // Browser and single sign-on logins leave no password Conduit can
        // reuse.
        if let dashboardID = appState.resolveDashboardID(forURL: baseURL, registerIfMissing: true) {
            appState.clearSavedPassword(dashboardID: dashboardID)
            KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
        }
        appState.rememberDashboardURL(baseURL)
        appState.prepareInteractiveSignIn(baseURL: baseURL)
        await appState.connect(with: HermesConnection(baseUrl: baseURL, ticket: ticket))
        finishSignIn(at: baseURL)
    }

    func browserFailed(_ classifiedFailure: ConnectionFailure, detail: String) {
        // Fixed classified copy only: the dashboard's detail text is logged
        // for diagnosis (redacted in release builds) and never shown.
        Self.logger.error(
            "Auth WebView sign-in error: \(String(describing: classifiedFailure), privacy: .public) detail: \(detail)"
        )
        // The failure shows under the step, so the sheet closes as the
        // single sign-on sheet does on an error.
        browserRequest = nil
        show(.presenting(classifiedFailure), at: browserPlace)
    }
}
