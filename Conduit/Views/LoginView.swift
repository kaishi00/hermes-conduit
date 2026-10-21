//
//  LoginView.swift
//  Conduit
//
//  The sign-in screen: the saved dashboards, or the address of the first
//  one (Views/Login). The browser sign-in's WebView lives here too: the
//  dashboard issues a one-time ticket used for the WebSocket connection.
//

import SwiftUI
import WebKit

struct LoginView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @StateObject private var flow = LoginFlowModel()
    /// Non-nil presents Add a dashboard, filled in from the seed.
    @State private var addDashboard: LoginSeed?
    /// The Connection Setup assistant answered on the dashboards list, which
    /// has no address field: Add a dashboard opens with it once the
    /// assistant has closed.
    @State private var setupSeed: LoginSeed?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop(drifts: true)
                if appState.savedDashboardRegistry.dashboards.isEmpty {
                    LoginAddressStep(flow: flow, context: .firstLaunch)
                } else {
                    LoginDashboardsScreen(flow: flow) {
                        addDashboard = .blank
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // On the stack's root, not on either screen: the first sign-in
            // registers its dashboard, which swaps the first-launch screen for
            // the list underneath this page.
            .navigationDestination(isPresented: $flow.showsCredentials) {
                LoginCredentialsPage(flow: flow)
            }
        }
        .modifier(LoginFlowPresentations(
            flow: flow,
            onSetupResult: { result in
                if appState.savedDashboardRegistry.dashboards.isEmpty {
                    flow.applySetupResult(result)
                } else {
                    let handoff = LoginCloudflareHandoff.apply(result, to: "", keeping: flow.cloudflareState)
                    setupSeed = LoginSeed(
                        address: handoff.serverURL,
                        username: handoff.username,
                        password: handoff.password,
                        cloudflare: handoff.cloudflare
                    )
                }
            },
            onSetupDismissed: {
                guard let setupSeed else { return }
                self.setupSeed = nil
                addDashboard = setupSeed
            }
        ))
        .sheet(item: $addDashboard) { seed in
            AddDashboardSheet(seed: seed)
                .environmentObject(appState)
        }
        .onAppear { flow.attach(appState) }
        .onReceive(appState.$pendingLoginFailure) { pending in
            // Typed handoff from AppState (a refused saved password,
            // requireSignIn). @Published replays the current value to this
            // subscriber on mount, so it lands whether the failure came
            // first or the screen did. Consumed once.
            guard let pending else { return }
            flow.attach(appState)
            flow.receive(pending)
            appState.pendingLoginFailure = nil
        }
    }

    /// URL-only gate: provider discovery decides whether credentials are
    /// required. OAuth-only dashboards must not need dummy username/password.
    static func hasConnectableInput(serverURL: String) -> Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Setup handoff Cloudflare state

/// The login card's in-memory Cloudflare service-token fields, as a plain
/// value so the setup-wizard handoff decision is unit-testable without
/// hosting the view.
struct LoginCloudflareState: Equatable {
    var isEnabled: Bool
    var clientID: String
    var clientSecret: String
}

enum LoginCloudflareHandoff {
    /// Decides the in-memory Cloudflare token state after the setup wizard
    /// hands back a dashboard address. A retained service token is bound to
    /// the origin it was entered for; when the handoff moves the dashboard to
    /// a different origin (scheme, host, or effective port — path-only
    /// changes are same-origin, per `ConnectionURLPolicy`), the token must
    /// never be silently sent there, so the in-memory state clears. The
    /// persisted Keychain token stays origin-scoped and is deliberately
    /// untouched by this decision.
    static func state(from oldServerURL: String, to newServerURL: String,
                      keeping current: LoginCloudflareState) -> LoginCloudflareState {
        if sameOrigin(oldServerURL, newServerURL) { return current }
        return LoginCloudflareState(isEnabled: false, clientID: "", clientSecret: "")
    }

    static func sameOrigin(_ oldServerURL: String, _ newServerURL: String) -> Bool {
        ConnectionURLPolicy.originMatches(
            URL(string: oldServerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            expected: URL(string: newServerURL.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    /// The complete login-field mapping for a wizard handoff, so the view's
    /// completion closure stays a single tested call and a refactor cannot
    /// silently drop the origin check while still assigning the new address.
    static func apply(_ result: ConnectionSetupResult, to oldServerURL: String,
                      keeping cloudflare: LoginCloudflareState)
        -> (serverURL: String, username: String, password: String, cloudflare: LoginCloudflareState) {
        (
            result.serverURL,
            result.username,
            result.password,
            state(from: oldServerURL, to: result.serverURL, keeping: cloudflare)
        )
    }
}

// MARK: - Login field focus chain

/// The sign-in fields, in return-key order. Two chains: the address step's
/// (the address, then the Cloudflare token when it is on) and the sign-in
/// step's (username, then password). Internal, not nested in a view, so the
/// rules are unit-testable without hosting one.
enum LoginField: Hashable, CaseIterable {
    case server, username, password
    case cloudflareClientID, cloudflareClientSecret

    /// The field the return key moves focus to, or `nil` when return on this
    /// field submits (Continue, Sign in). While the Cloudflare token entry
    /// is on, the address hands focus to the Client ID, so a half-entered
    /// token is never sent.
    func submitDestination(cloudflareTokenEntryEnabled: Bool) -> LoginField? {
        switch self {
        case .server: return cloudflareTokenEntryEnabled ? .cloudflareClientID : nil
        case .username: return .password
        case .password: return nil
        case .cloudflareClientID: return .cloudflareClientSecret
        case .cloudflareClientSecret: return nil
        }
    }

    /// Whether return on this field submits instead of advancing focus. Exposed separately from the keyboard label so the decision
    /// stays unit-testable (SubmitLabel is not Equatable).
    func submits(cloudflareTokenEntryEnabled: Bool) -> Bool {
        submitDestination(cloudflareTokenEntryEnabled: cloudflareTokenEntryEnabled) == nil
    }

    func submitKeyboardLabel(cloudflareTokenEntryEnabled: Bool) -> SubmitLabel {
        submits(cloudflareTokenEntryEnabled: cloudflareTokenEntryEnabled) ? .go : .next
    }
}

// MARK: - Auth WebView navigation policy

/// The authentication WebView's navigation boundary, extracted so the rules
/// are unit-testable without hosting a WKWebView.
///
/// Main frames follow the strict dashboard policy: allowed transport only,
/// unpinned sign-in may traverse the legitimate Cloudflare/IdP redirect
/// chain, and once the dashboard origin pins, top-level navigation cannot
/// escape it. Subframes additionally accept the `about:blank` /
/// `about:srcdoc` documents Cloudflare's Turnstile WebView requirements
/// name. Those documents inherit the parent page's origin, so script inside
/// them could attempt a top-level navigation — but any such attempt
/// re-enters this policy as a MAIN frame navigation, so the allowance never
/// moves the main-frame dashboard-origin boundary.
enum AuthWebViewNavigationPolicy {
    enum Decision: Equatable {
        case allow
        case cancel
    }

    static func decide(
        url: URL?,
        isMainFrame: Bool,
        hasPinnedDashboardOrigin: Bool,
        expectedDashboardURL: URL?
    ) -> Decision {
        if !isMainFrame {
            return ConnectionURLPolicy.isAllowedWebViewSubframeTransport(url) ? .allow : .cancel
        }
        guard ConnectionURLPolicy.isAllowedTransport(url) else { return .cancel }
        if !hasPinnedDashboardOrigin {
            // Passwordless/OAuth providers legitimately use a short
            // cross-origin redirect chain during sign-in. The ticket
            // message remains origin-pinned below, and navigation locks
            // to the dashboard as soon as the authenticated route loads.
            return .allow
        }
        guard let expectedDashboardURL,
              ConnectionURLPolicy.originMatches(url, expected: expectedDashboardURL) else {
            return .cancel
        }
        return .allow
    }

    /// Whether a finished page is the dashboard past its sign-in, where the
    /// session cookie can mint a ticket: on the dashboard's origin and not a
    /// sign-in page there (Hermes' /login, or an auth proxy's own page such
    /// as oauth2-proxy's /oauth2/sign_in), which the user hasn't got past.
    static func isSignedInDashboardPage(_ url: URL?, expectedDashboardURL: URL?) -> Bool {
        guard let url, let expectedDashboardURL,
              ConnectionURLPolicy.originMatches(url, expected: expectedDashboardURL) else { return false }
        return !DashboardSignInRedirect.isSignInPath(url.path)
    }
}

// MARK: - Auth WebView

struct AuthWebView: UIViewRepresentable {
    let url: String
    let cloudflareAccess: CloudflareAccessCredentials?
    /// Resolves the saved dashboard being signed into AT CAPTURE TIME (on
    /// successful sign-in), so the cookie mirror is written to that
    /// dashboard's scoped record. A closure, not a value: resolving during
    /// view construction would register a dashboard for every render of the
    /// login card, and the binding belongs to the commit moment. Nil
    /// (callers without a registry context, e.g. tests) captures nothing —
    /// no identity, no durable mirror.
    var dashboardIDProvider: (() -> UUID?)? = nil
    /// The dashboard-owned WebKit session store identifier for this sign-in.
    /// Non-nil means the WebView runs inside `WKWebsiteDataStore(
    /// forIdentifier:)` for that identity — never the shared default store —
    /// so sign-in cookies are isolated per dashboard from the first request.
    /// Nil (legacy/test construction) keeps the default store.
    var websiteDataStoreIdentifier: UUID? = nil
    let onTicket: (String, String) -> Void
    /// Classified failure + raw diagnostic detail. The dashboard controls the
    /// detail text (e.g. `payload["error"]`), so it is never rendered — the
    /// login card shows only the fixed copy for the classification.
    let onError: (ConnectionFailure, String) -> Void
    /// The page asked for a passkey, which iOS refuses in this WebView
    /// (AuthWebPasskeyDetector). Nil installs no detector.
    var passkeyRequested: (() -> Void)? = nil

    /// Runs `action` each time the page asks for a passkey.
    func onPasskeyRequest(_ action: @escaping () -> Void) -> AuthWebView {
        var copy = self
        copy.passkeyRequested = action
        return copy
    }

    func makeUIView(context: Context) -> WKWebView {
        let normalized = try? ConnectionURLPolicy.normalizedBaseURL(url)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = DashboardCookiePersistence.webKitStore(for: websiteDataStoreIdentifier)
        config.userContentController.add(context.coordinator, contentWorld: DashboardScriptWorld.world, name: "ticket")
        if passkeyRequested != nil {
            AuthWebPasskeyDetector.install(into: config.userContentController, handler: context.coordinator)
        }
        if let normalized {
            DashboardScriptWorld.installProxyHeaderScripts(
                into: config.userContentController,
                cloudflareAccess: cloudflareAccess,
                normalizedBaseURL: normalized
            )
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        guard let normalized else {
            Self.reportConstructionFailure(onError, detail: AppLocalization.string("dashboard URL failed normalization in AuthWebView"))
            return webView
        }
        if let request = try? Self.dashboardRequest(normalizedBaseURL: normalized, cloudflareAccess: cloudflareAccess) {
            if websiteDataStoreIdentifier == nil, DashboardCookiePersistence.hasPendingDefaultStoreClear {
                // The default store's last disconnect is still clearing; a
                // session minted before it lands would be deleted (#788).
                Task { @MainActor [weak webView] in
                    await DashboardCookiePersistence.awaitPendingDefaultStoreClear()
                    webView?.load(request)
                }
            } else {
                webView.load(request)
            }
        } else {
            Self.reportConstructionFailure(onError, detail: AppLocalization.string("dashboard sign-in request construction failed"))
        }
        return webView
    }

    /// Construction-time failures cannot synchronously mutate the owning
    /// view's state: makeUIView runs inside SwiftUI's representable update
    /// pass, and an immediate onError would write LoginView @State mid-render.
    /// Report on the next main-runloop turn instead. Static with an injected
    /// callback so the deferral contract stays unit-testable.
    static func reportConstructionFailure(
        _ onError: @escaping (ConnectionFailure, String) -> Void,
        detail: String,
        failure: ConnectionFailure = .invalidAddress
    ) {
        DispatchQueue.main.async {
            onError(failure, detail)
        }
    }

    /// The dashboard sign-in request the WebView boots with. Extracted so the
    /// service-token header placement on the initial request stays covered by
    /// unit tests without hosting a WKWebView.
    static func dashboardRequest(
        normalizedBaseURL: String,
        cloudflareAccess: CloudflareAccessCredentials?
    ) throws -> URLRequest {
        guard let dashboardURL = URL(string: normalizedBaseURL) else {
            throw ConnectionURLPolicyError.invalidURL
        }
        let loginURL = dashboardURL.appending(path: "login")
        var request = URLRequest(url: loginURL)
        request = request.applyingProxyHeaders(cloudflare: cloudflareAccess)
        return request
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(
            forName: "ticket",
            contentWorld: DashboardScriptWorld.world
        )
        // Unconditional on purpose: removing a handler that was never added
        // is a no-op, so this doesn't have to repeat makeUIView's condition.
        AuthWebPasskeyDetector.uninstall(from: uiView.configuration.userContentController)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: AuthWebView
        private var hasDeliveredTicket = false
        private var hasPinnedDashboardOrigin = false
        private weak var authenticatedWebView: WKWebView?

        init(parent: AuthWebView) {
            self.parent = parent
        }

        private var expectedURL: URL? {
            guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(parent.url) else { return nil }
            return URL(string: normalized)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Match the React Native bridge: the dashboard owns the sign-in
            // flow, then a non-login route can use its HttpOnly session cookie
            // to mint a one-time WebSocket ticket.
            guard let expectedURL,
                  AuthWebViewNavigationPolicy.isSignedInDashboardPage(webView.url, expectedDashboardURL: expectedURL) else { return }
            hasPinnedDashboardOrigin = true
            authenticatedWebView = webView
            let js = """
            (async function() {
                try {
                    const response = await fetch('/api/auth/ws-ticket', {
                        method: 'POST',
                        credentials: 'include'
                    });
                    const body = await response.json().catch(() => ({}));
                    window.webkit.messageHandlers.ticket.postMessage(JSON.stringify({
                        type: 'hermes-ticket',
                        status: response.status,
                        ticket: body.ticket || null
                    }));
                } catch (error) {
                    window.webkit.messageHandlers.ticket.postMessage(JSON.stringify({
                        type: 'hermes-ticket',
                        status: 0,
                        error: String(error)
                    }));
                }
            })();
            true;
            """
            webView.evaluateJavaScript(js, in: nil, in: DashboardScriptWorld.world, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if AuthWebPasskeyDetector.isPasskeyRequest(name: message.name, worldName: message.world.name, body: message.body) {
                parent.passkeyRequested?()
                return
            }
            guard message.name == "ticket", let rawMessage = message.body as? String,
                  message.frameInfo.isMainFrame,
                  let expectedURL,
                  ConnectionURLPolicy.originMatches(
                    scheme: message.frameInfo.securityOrigin.protocol,
                    host: message.frameInfo.securityOrigin.host,
                    port: message.frameInfo.securityOrigin.port,
                    expected: expectedURL
                  ),
                  let data = rawMessage.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["type"] as? String == "hermes-ticket" else { return }

            let status = payload["status"] as? Int ?? 0
            guard status != 401 else { return } // The dashboard is still showing its sign-in route.
            guard let ticket = payload["ticket"] as? String, !ticket.isEmpty else {
                // The classification is Conduit's, never the payload's: a
                // completed dashboard sign-in that fails to mint a ticket is
                // a session-ticket failure regardless of what the payload
                // says. Payload text is carried as diagnostic detail only.
                let detail = payload["error"] as? String
                    ?? AppLocalization.string("Unable to start the Hermes session\(status == 0 ? "" : " (\(status))")")
                parent.onError(.sessionTicketFailure, detail)
                return
            }
            // Persist the HttpOnly dashboard session before dismissing this
            // WebView. The old detached task could lose the cookie race on a
            // cold launch, so the saved one-time ticket had nothing to renew.
            let webView = authenticatedWebView
            Task { @MainActor [weak self, weak webView] in
                guard let self else { return }
                if let webView, let dashboardID = parent.dashboardIDProvider?() {
                    await DashboardCookiePersistence.capture(
                        from: webView.configuration.websiteDataStore.httpCookieStore,
                        for: self.expectedURL,
                        dashboardID: dashboardID
                    )
                }
                self.deliver(ticket: ticket)
            }
        }

        private func deliver(ticket: String) {
            let cleanedTicket = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hasDeliveredTicket, !cleanedTicket.isEmpty,
                  let baseURL = try? ConnectionURLPolicy.normalizedBaseURL(parent.url) else { return }
            hasDeliveredTicket = true
            parent.onTicket(cleanedTicket, baseURL)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // A nil targetFrame is treated as main-frame, matching the
            // historical policy for the initial navigation.
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            switch AuthWebViewNavigationPolicy.decide(
                url: navigationAction.request.url,
                isMainFrame: isMainFrame,
                hasPinnedDashboardOrigin: hasPinnedDashboardOrigin,
                expectedDashboardURL: expectedURL
            ) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - Browser sign-in sheet

/// The browser sign-in as a sheet: the dashboard's page under a bar with
/// Cancel, so closing it doesn't depend on the swipe down (hard to find,
/// and harder with VoiceOver or Switch Control). Cancel does what the swipe
/// does: the sheet's presentation state clears and the screen underneath
/// stays as it was.
struct AuthWebSignInSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let webView: AuthWebView
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            webView
                .explainingPasskeys()
                .navigationTitle(Text("Sign in"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppLocalization.string("Cancel")) { dismiss() }
                            .accessibilityIdentifier("login.browser-sign-in.cancel")
                    }
                }
        }
    }
}

extension AuthWebView {
    /// The sign-in page as its sheet's content, with the passkey notice and
    /// a Cancel button.
    func asSignInSheet() -> AuthWebSignInSheet {
        AuthWebSignInSheet(webView: self)
    }
}
