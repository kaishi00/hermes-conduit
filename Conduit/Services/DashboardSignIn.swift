//
//  DashboardSignIn.swift
//  Conduit
//
//  The one sign-in mode decision shared by the login card, the Connection
//  Setup test and Repair. Each surface acts on the decision in its own way
//  (sign in now, report a test outcome, reconnect), but they all classify
//  a dashboard's discovery answer here, so a given dashboard can never be a
//  password dashboard on one screen and a browser dashboard on another.
//

import Foundation

/// Why sign-in continues in the embedded browser view instead of natively.
enum DashboardBrowserSignInReason: Equatable {
    /// Discovery was answered by a redirect to a sign-in page: a sign-in
    /// service (an auth proxy or edge) in front of the dashboard owns the
    /// first step. Conduit never follows a redirect to another origin
    /// itself; a same-origin one ends on the sign-in portal's own page.
    case authProxyRedirect
    /// The dashboard names an interactive (OAuth/session) provider but does
    /// not advertise native system-browser sign-in, as older Hermes does.
    case legacyOAuth
}

/// A sign-in that takes no password. The type has no password case, so a
/// surface that opens one can never be handed a password dashboard.
enum DashboardInteractiveSignIn: Equatable {
    /// Hermes' native flow in the system browser. `provider` is pinned only
    /// when discovery named exactly one native provider; otherwise Hermes
    /// shows its own provider choice.
    case nativeOAuth(provider: String?)
    /// The dashboard's own sign-in in the embedded browser view.
    case browser(DashboardBrowserSignInReason)
}

/// The browser sign-in a password dashboard also offers, as discovery
/// alone describes it. Whether a native-capable provider continues in
/// Safari or in the browser view is the native capability check, and that
/// check runs only once the user picks this sign-in (unless the provider
/// answer already advertised `native_pkce`): a failing check then fails
/// that pick, never the password the dashboard also offers, and it never
/// quietly turns into another sign-in.
enum DashboardBrowserSignInOffer: Equatable {
    /// Providers listed without `supports_password` (Hermes before password
    /// sign-in existed): the dashboard's own sign-in page.
    case legacyOAuth
    /// A provider that signs in natively when the dashboard advertises it.
    /// `advertisedFlows` is the `auth_flows` the provider answer carried,
    /// nil when it carried none (stock Hermes advertises them only on
    /// `/api/status`, which the capability check then asks).
    case nativeCapable(provider: String?, advertisedFlows: [String]? = nil)

    /// The sign-in this offer opens when discovery alone decides it; nil
    /// when the native capability check must decide. Lets a surface open it
    /// without a busy step; `DashboardSignInResolver.signIn(for:)` agrees.
    /// Only an advertised `native_pkce` decides here: any other answer is
    /// left to the capability check, so the provider answer can open native
    /// sign-in but never, on its own, route a native-capable provider to the
    /// browser view.
    var decidedSignIn: DashboardInteractiveSignIn? {
        switch self {
        case .legacyOAuth:
            return .browser(.legacyOAuth)
        case .nativeCapable(let provider, let advertisedFlows):
            guard let advertisedFlows, HermesProviderCheck.advertisesNativeSignIn(advertisedFlows) else { return nil }
            return .nativeOAuth(provider: provider)
        }
    }
}

/// How a dashboard signs in, decided from provider discovery (and, for a
/// dashboard that signs in only through a native-capable provider, the
/// native capability check).
enum DashboardSignInMode: Equatable {
    case password
    case interactive(DashboardInteractiveSignIn)
    /// Password, or the offered browser sign-in: the user picks.
    case passwordOrBrowser(DashboardBrowserSignInOffer)
}

/// Discovery answers that name no usable sign-in. Both present as an
/// unexpected server response: Conduit cannot sign in to what it found.
enum DashboardSignInError: Error, Equatable {
    /// A 2xx answer without Hermes provider structure (another web app, a
    /// proxy's own page, malformed JSON). Never read as interactive sign-in.
    case unrecognizedServer
    /// Hermes provider structure naming no password or interactive provider,
    /// and no session token on offer either (an empty list is how a Hermes
    /// set up with only its session token answers; its status says so).
    case noSignInMethod
}

/// Turns a discovery answer into a sign-in mode. A provider answer that
/// advertises `native_pkce` in its `auth_flows` decides native sign-in;
/// otherwise the native capability lookup stays behind the one
/// `supportsNativeOAuth` seam.
struct DashboardSignInResolver {
    /// Whether the dashboard supports Hermes' native system-browser flow,
    /// when its provider answer did not advertise it.
    /// Errors are failures, never "unsupported": a broken capability answer
    /// must not quietly send a native-capable provider to the embedded
    /// browser or to password sign-in.
    let supportsNativeOAuth: () async throws -> Bool
    /// Whether the dashboard takes Hermes' session token as a sign-in. Asked
    /// only when its provider list names no password or interactive
    /// provider, which is what a Hermes set up with only that token answers
    /// (issue 2442). An error here reads as not offered: the list named no
    /// sign-in either way. Only `mode(for:)` asks
    /// it, so a resolver built with closures for `signIn(for:)` alone
    /// (Repair's choice) may leave the default; one that calls `mode(for:)`
    /// answers it, as `init(client:)` does.
    let supportsSessionToken: () async throws -> Bool

    init(
        supportsNativeOAuth: @escaping () async throws -> Bool,
        supportsSessionToken: @escaping () async throws -> Bool = { false }
    ) {
        self.supportsNativeOAuth = supportsNativeOAuth
        self.supportsSessionToken = supportsSessionToken
    }

    init(client: any DashboardSignInTransport) {
        self.init(
            supportsNativeOAuth: { try await client.supportsNativeOAuth() },
            supportsSessionToken: { try await client.supportsSessionToken() }
        )
    }

    /// Discovery plus the decision, for callers that do not stage the two.
    static func resolve(using client: any DashboardSignInTransport) async throws -> DashboardSignInMode {
        let discovery = try await client.authProviderDiscovery()
        return try await DashboardSignInResolver(client: client).mode(for: discovery)
    }

    func mode(for discovery: AuthProviderDiscoveryResult) async throws -> DashboardSignInMode {
        switch discovery {
        case .interactiveSignInRequired:
            // Nothing past the sign-in service is visible yet, so there is
            // no provider list or capability to ask about.
            return .interactive(.browser(.authProxyRedirect))
        case .unrecognized:
            throw DashboardSignInError.unrecognizedServer
        case .providers(let providers, let authFlows):
            switch (
                HermesProviderCheck.supportsPassword(providers),
                Self.browserOffer(providers, advertisedFlows: authFlows)
            ) {
            case (true, nil):
                return .password
            case (true, let offer?):
                // The capability check waits until the browser sign-in is
                // picked: the password needs nothing from it.
                return .passwordOrBrowser(offer)
            case (false, let offer?):
                return .interactive(try await signIn(for: offer))
            case (false, nil):
                // A Hermes set up with only its session token lists no
                // provider. The token is entered on the native sign-in's
                // sheet and used the way a native sign-in's tokens are.
                // A status that fails or can't be read leaves the answer
                // an empty list always had: discovery already reached the
                // server, so it is not reported as unreachable.
                guard (try? await supportsSessionToken()) == true else { throw DashboardSignInError.noSignInMethod }
                return .interactive(.nativeOAuth(provider: NativeOAuthTokenSet.sessionTokenProvider))
            }
        }
    }

    /// The sign-in an offer opens. Only a native-capable provider whose
    /// provider answer did not advertise `native_pkce` asks the dashboard
    /// anything (the capability check), and a failed check is an error,
    /// never the browser view or a password.
    func signIn(for offer: DashboardBrowserSignInOffer) async throws -> DashboardInteractiveSignIn {
        // Decided by discovery alone: the legacy offer, or an advertised
        // `native_pkce`.
        if let decided = offer.decidedSignIn { return decided }
        switch offer {
        case .legacyOAuth:
            return .browser(.legacyOAuth)
        case .nativeCapable(let provider, _):
            return try await supportsNativeOAuth() ? .nativeOAuth(provider: provider) : .browser(.legacyOAuth)
        }
    }

    /// The browser sign-in a provider list names, if any. A native-capable
    /// provider wins over providers listed the pre-password way, and carries
    /// the `auth_flows` the same answer advertised.
    static func browserOffer(
        _ providers: [[String: Any]],
        advertisedFlows: [String]? = nil
    ) -> DashboardBrowserSignInOffer? {
        if HermesProviderCheck.hasNativeOAuthProvider(providers) {
            return .nativeCapable(
                provider: HermesProviderCheck.nativeOAuthProvider(providers),
                advertisedFlows: advertisedFlows
            )
        }
        if HermesProviderCheck.hasLegacySessionProvider(providers) {
            return .legacyOAuth
        }
        return nil
    }
}

/// The requests a sign-in decision and a password sign-in make, so the
/// login coordinator can be driven by a scripted transport in tests.
/// `NativeAuthClient` is the production implementation.
protocol DashboardSignInTransport {
    func authProviderDiscovery() async throws -> AuthProviderDiscoveryResult
    func supportsNativeOAuth() async throws -> Bool
    func supportsSessionToken() async throws -> Bool
    func connect(username: String, password: String) async throws -> NativeAuthConnection
}

extension DashboardSignInTransport {
    /// Only a real dashboard is asked; a scripted transport offers none.
    func supportsSessionToken() async throws -> Bool { false }
}

extension NativeAuthClient: DashboardSignInTransport {}
