//
//  LoginView.swift
//  Conduit
//
//  Connect to a Hermes dashboard instance.
//  Uses an authenticated WebView approach — the dashboard issues a one-time
//  ticket that we use for the WebSocket connection.
//

import SwiftUI
import WebKit
import os

struct LoginView: View {
    private static let logger = Logger(subsystem: "com.milim.relay", category: "login")

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var serverUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saveCredentials = false
    @State private var useFaceID = false
    @State var cloudflareEnabled = false
    @State var cloudflareClientID = ""
    @State var cloudflareClientSecret = ""
    @State private var isConnecting = false
    @State private var showWebView = false
    /// The presented failure state: classified connection failures with
    /// recovery actions, or plain validation notices. The view never renders
    /// raw Foundation error strings directly.
    @State private var failure: ConnectionFailurePresentation?
    /// Non-nil presents the Connection Setup shell, pre-seeded with the
    /// classified help destination (or `.start` from the entry point).
    @State private var connectionSetupDestination: ConnectionHelpDestination?
    /// Set only by the user's Cloudflare toggle (never by the onAppear
    /// Keychain restore), so a returning saved-token user is not scrolled
    /// away from the top of the form every time the login screen appears.
    @State private var revealCloudflareSection = false
    @FocusState private var focusedField: LoginField?

    var body: some View {
        ZStack {
            // Purely decorative: the scroll content fills the screen, so
            // keyboard dismissal is owned by scroll-dismiss, the keyboard
            // Done button, and moving focus between fields.
            ConduitBackdrop()

            // The login form is a responsive scroll view inside a fixed
            // decorative layer: at compact iPhone heights with the keyboard
            // up, the focused field (including the optional Cloudflare fields
            // near the bottom) scrolls into view instead of hiding behind the
            // keyboard. minHeight keeps the centered layout when the content
            // fits and only introduces scrolling when it cannot.
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        loginContent
                            .frame(minHeight: geometry.size.height)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedField) { _, field in
                        guard let field else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(field, anchor: .center)
                        }
                    }
                    .onChange(of: revealCloudflareSection) { _, requested in
                        guard requested else { return }
                        revealCloudflareSection = false
                        // Defer one runloop turn: the CF fields this scroll
                        // targets are inserted in the same transaction, and
                        // scrolling to not-yet-installed ids would no-op.
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(LoginField.cloudflareClientID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear {
            // A classified sign-in failure from AppState (e.g. a rejected
            // saved password at launch, or requireSignIn) surfaces here once
            // and is consumed, so it cannot resurface stale in the connected
            // composer banner later.
            if let message = appState.errorMessage, !message.isEmpty {
                failure = .notice(title: "Sign-in didn’t complete", message: message)
                appState.errorMessage = nil
            }
            guard serverUrl.isEmpty else { return }
            serverUrl = appState.lastDashboardURL
            if let access = KeychainHelper.loadCloudflareAccess(for: serverUrl) {
                cloudflareEnabled = true
                cloudflareClientID = access.clientID
                cloudflareClientSecret = access.clientSecret
            }
        }
        .sheet(item: $connectionSetupDestination) { destination in
            ConnectionSetupView(initialDestination: destination)
        }
        .sheet(isPresented: $showWebView) {
            AuthWebView(
                url: serverUrl,
                cloudflareAccess: configuredCloudflareAccess,
            onTicket: { ticket, baseUrl in
                // The dashboard is solely an authentication bridge. Dismiss it
                // before connection work begins so Conduit, not the dashboard,
                // becomes the active surface as soon as we have a ticket.
                showWebView = false
                Task {
                    // OAuth and cloud dashboard logins do not provide a
                    // password credential that Conduit can safely reuse.
                    KeychainHelper.clearCredentials()
                    appState.rememberDashboardURL(baseUrl)
                    await appState.connect(with: HermesConnection(baseUrl: baseUrl, ticket: ticket))
                }
                },
                onError: { message in
                    failure = .notice(title: "Sign-in didn’t complete", message: message)
                }
            )
        }
    }

    private var loginContent: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 36)

            VStack(spacing: 14) {
                Image(loginIconAssetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.17 : 0.45), lineWidth: 1)
                    }

                VStack(spacing: 6) {
                    Text("Conduit")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("A focused home for your Hermes work")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Label("Connect a Hermes dashboard", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.conduitAccent)

                // Connection Setup entry point (visible, secondary to
                // Connect, never auto-opened). Round 1 opens the shell;
                // the guided assistant fills it in later.
                Button {
                    connectionSetupDestination = .start
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.body)
                            .foregroundStyle(.conduitAccent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Need help connecting?")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Set up your Hermes connection")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .conduitGlassSurface(cornerRadius: 14, tint: .conduitAura.opacity(0.06))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("login.connection-setup")

                TextField("https://hermes.example", text: $serverUrl)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("login.server-url")
                    .focused($focusedField, equals: .server)
                    .submitLabel(LoginField.server.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                    .onSubmit { handleSubmit(from: .server) }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                    .id(LoginField.server)

                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("login.username")
                    .submitLabel(LoginField.username.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                    .focused($focusedField, equals: .username)
                    .onSubmit { handleSubmit(from: .username) }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                    .id(LoginField.username)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("login.password")
                    .submitLabel(LoginField.password.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                    .focused($focusedField, equals: .password)
                    .onSubmit { handleSubmit(from: .password) }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                    .id(LoginField.password)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Save credentials", isOn: $saveCredentials)
                        .tint(.conduitAccent)
                        .onChange(of: saveCredentials) { _, savesCredentials in
                            if !savesCredentials { useFaceID = false }
                        }

                    Toggle("Use Face ID", isOn: $useFaceID)
                        .tint(.conduitAccent)
                        .disabled(!saveCredentials || !BiometricAuth.isFaceIDAvailable)

                    if !BiometricAuth.isFaceIDAvailable {
                        Text("Face ID is not available on this device. You can still save credentials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if saveCredentials {
                        Text(useFaceID
                            ? "Face ID, with device passcode recovery, is required on launch."
                            : "Saved credentials reconnect without a Face ID prompt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Use Cloudflare Access service token", isOn: Binding(
                        get: { cloudflareEnabled },
                        set: { enabled in
                            cloudflareEnabled = enabled
                            revealCloudflareSection = enabled
                            // Turning the section off while typing in one of
                            // its fields unmounts them mid-focus; drop focus
                            // explicitly so the keyboard never dangles.
                            if !enabled,
                               focusedField == .cloudflareClientID || focusedField == .cloudflareClientSecret {
                                focusedField = nil
                            }
                        }
                    ))
                    .tint(.conduitAccent)
                    // Stable XCUI handles: the localized label works too, but
                    // identifiers decouple the UI tests from copy changes
                    // and from Switch/CheckBox element-type ambiguity.
                    .accessibilityIdentifier("login.cloudflare-toggle")
                    if cloudflareEnabled {
                        TextField("Cloudflare Client ID", text: $cloudflareClientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("login.cloudflare-client-id")
                            .focused($focusedField, equals: .cloudflareClientID)
                            .submitLabel(LoginField.cloudflareClientID.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                            .onSubmit { handleSubmit(from: .cloudflareClientID) }
                            .padding(.horizontal, 14).frame(height: 50)
                            .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                            .id(LoginField.cloudflareClientID)
                        SecureField("Cloudflare Client Secret", text: $cloudflareClientSecret)
                            .accessibilityIdentifier("login.cloudflare-client-secret")
                            .focused($focusedField, equals: .cloudflareClientSecret)
                            .submitLabel(LoginField.cloudflareClientSecret.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                            .onSubmit { handleSubmit(from: .cloudflareClientSecret) }
                            .padding(.horizontal, 14).frame(height: 50)
                            .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                            .id(LoginField.cloudflareClientSecret)
                        Text("Used only to reach this Cloudflare-protected dashboard; the secret stays in Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
                if let failure {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.footnote)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.title)
                                    .font(.footnote.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                    .accessibilityIdentifier("login.error.title")
                                if !failure.message.isEmpty {
                                    Text(failure.message)
                                        .font(.footnote)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if failure.offersRecoveryActions {
                            HStack(spacing: 16) {
                                Button("Try Again") {
                                    Task { await connect() }
                                }
                                .disabled(isConnecting)
                                .accessibilityIdentifier("login.error.try-again")

                                if let destination = failure.helpDestination {
                                    Button("Troubleshoot Connection") {
                                        connectionSetupDestination = destination
                                    }
                                    .accessibilityIdentifier("login.error.troubleshoot")
                                }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await connect() }
                } label: {
                    Label(isConnecting ? "Connecting..." : "Connect", systemImage: "arrow.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .accessibilityIdentifier("login.connect")
                .foregroundStyle(.white)
                .disabled(!connectInputsArePresent || isConnecting)
                .conduitGlassControl(cornerRadius: 18, tint: .conduitAccent, prominent: true)
            }
            .padding(20)
            .conduitGlassSurface(cornerRadius: 28, tint: .conduitAccent.opacity(0.07))

            Text("Your credentials stay on this device when you choose to save them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
    }

    /// Trimmed-presence check so whitespace-only input is treated the same
    /// by the Connect button and by connect()'s guard.
    private var connectInputsArePresent: Bool {
        Self.hasConnectableInput(serverURL: serverUrl, username: username, password: password)
    }

    /// Static seam for the trimmed-presence rule so the validation contract
    /// is unit-testable without hosting the view.
    static func hasConnectableInput(serverURL: String, username: String, password: String) -> Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return-key behavior shared by every field: walk the focus chain
    /// (server → username → password → Cloudflare Client ID → Client Secret)
    /// and only submit when the focused field ends the chain. While the
    /// Cloudflare token entry is on, the password field hands focus to the
    /// Cloudflare Client ID instead of triggering Connect.
    private func handleSubmit(from field: LoginField) {
        if let destination = field.submitDestination(cloudflareTokenEntryEnabled: cloudflareEnabled) {
            focusedField = destination
        } else {
            Task { await connect() }
        }
    }

    @MainActor
    private func connect() async {
        // The Connect button is disabled while connecting, but Try Again and
        // the return-key chain also reach this method: never let a second
        // auth sequence run concurrently (Hermes throttles password login).
        guard !isConnecting else { return }
        let cleaned = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            // The return-key chain can reach submit without the Connect
            // button ever being enabled (e.g. a whitespace-only URL).
            // Surface the standard invalid-URL feedback instead of a silent
            // no-op.
            failure = .notice(title: "Enter a valid dashboard URL.")
            focusedField = .server
            return
        }
        // The return-key chain can reach submit while an earlier field was
        // skipped (e.g. tapping straight into the Cloudflare Secret); land
        // focus on the missing field instead of a raw remote 401. The
        // password value itself is sent untrimmed.
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failure = .notice(title: "Enter your dashboard username and password.")
            focusedField = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .username : .password
            return
        }
        // Preserve WHICH URL-policy rule failed: a malformed address and an
        // insecure remote transport are different mistakes with different
        // fixes, so they classify differently instead of collapsing into one
        // insecure-transport message.
        let normalized: String
        do {
            normalized = try ConnectionURLPolicy.normalizedBaseURL(cleaned)
        } catch {
            // Log the type-safe classification, never the raw error: its
            // associated values can carry server-provided detail text that
            // must not reach the unified log unredacted.
            Self.logger.error("Login URL normalization failed: \(String(describing: ConnectionFailureClassifier.classify(error)), privacy: .public)")
            failure = .presenting(ConnectionFailureClassifier.classify(error))
            return
        }
        serverUrl = normalized
        appState.rememberDashboardURL(serverUrl)
        failure = nil
        isConnecting = true
        defer { isConnecting = false }

        do {
            let access = configuredCloudflareAccess
            let client = NativeAuthClient(baseURL: serverUrl, cloudflareAccess: access)
            let providers = try await client.authProviders()
            guard providers.contains(where: { $0["supports_password"] as? Bool == true }) else {
                showWebView = true
                if let access { KeychainHelper.saveCloudflareAccess(access, origin: serverUrl) }
                return
            }

            let authenticatedConnection = try await client.connect(username: username, password: password)
            if saveCredentials {
                KeychainHelper.saveCredentials(DashboardCredentials(
                    baseURL: serverUrl,
                    username: username,
                    password: password,
                    requiresFaceID: useFaceID
                ))
            } else {
                KeychainHelper.clearCredentials()
            }
            if let access { KeychainHelper.saveCloudflareAccess(access, origin: serverUrl) } else { KeychainHelper.clearCloudflareAccess() }
            authenticatedConnection.commitCookies()
            await appState.connect(with: HermesConnection(baseUrl: serverUrl, ticket: authenticatedConnection.ticket))
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Login connection failed: \(String(describing: ConnectionFailureClassifier.classify(error)), privacy: .public)")
            failure = .presenting(ConnectionFailureClassifier.classify(error))
        }
    }

    var configuredCloudflareAccess: CloudflareAccessCredentials? {
        guard cloudflareEnabled else { return nil }
        return CloudflareAccessCredentials.from(clientID: cloudflareClientID, clientSecret: cloudflareClientSecret)
    }

    private var loginIconAssetName: String {
        switch appState.themePreference {
        case .light:
            return AppIconChoice.light.previewAssetName
        case .dark:
            return AppIconChoice.dark.previewAssetName
        case .system:
            return colorScheme == .dark ? AppIconChoice.dark.previewAssetName : AppIconChoice.light.previewAssetName
        }
    }
}

// MARK: - Login field focus chain

/// The login form's focusable fields, in tab order. Internal (not nested in
/// `LoginView`) so the return-key/focus-chain rules are unit-testable without
/// hosting the view.
enum LoginField: Hashable, CaseIterable {
    case server, username, password
    case cloudflareClientID, cloudflareClientSecret

    /// The field the return key should move focus to, or `nil` when return on
    /// this field submits (Connect) instead. While Cloudflare token entry is
    /// enabled, the password field hands focus to the Cloudflare Client ID
    /// rather than triggering Connect, so finishing the dashboard password
    /// can never accidentally submit half-entered Cloudflare credentials.
    func submitDestination(cloudflareTokenEntryEnabled: Bool) -> LoginField? {
        switch self {
        case .server: return .username
        case .username: return .password
        case .password: return cloudflareTokenEntryEnabled ? .cloudflareClientID : nil
        case .cloudflareClientID: return .cloudflareClientSecret
        case .cloudflareClientSecret: return nil
        }
    }

    /// Whether return on this field submits (Connect) instead of advancing
    /// focus. Exposed separately from the keyboard label so the decision
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
}

// MARK: - Auth WebView

struct AuthWebView: UIViewRepresentable {
    let url: String
    let cloudflareAccess: CloudflareAccessCredentials?
    let onTicket: (String, String) -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let normalized = try? ConnectionURLPolicy.normalizedBaseURL(url)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.add(context.coordinator, name: "ticket")
        if let normalized,
           let script = cloudflareAccess?.fetchInjectionUserScript(expectedBaseURL: normalized),
           !script.isEmpty {
            config.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        guard let normalized else {
            onError(ConnectionURLPolicyError.invalidURL.localizedDescription)
            return webView
        }
        if let request = try? Self.dashboardRequest(normalizedBaseURL: normalized, cloudflareAccess: cloudflareAccess) {
            webView.load(request)
        } else {
            onError(ConnectionURLPolicyError.invalidURL.localizedDescription)
        }
        return webView
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
        request = cloudflareAccess?.applying(to: request) ?? request
        return request
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "ticket")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

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
                  ConnectionURLPolicy.originMatches(webView.url, expected: expectedURL),
                  !(webView.url?.path.contains("/login") ?? true) else { return }
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
            webView.evaluateJavaScript(js)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
                let detail = payload["error"] as? String
                parent.onError(detail ?? "Unable to start the Hermes session\(status == 0 ? "" : " (\(status))").")
                return
            }
            // Persist the HttpOnly dashboard session before dismissing this
            // WebView. The old detached task could lose the cookie race on a
            // cold launch, so the saved one-time ticket had nothing to renew.
            let webView = authenticatedWebView
            Task { @MainActor [weak self, weak webView] in
                guard let self else { return }
                if let webView {
                    await DashboardCookiePersistence.capture(
                        from: webView.configuration.websiteDataStore.httpCookieStore,
                        for: self.expectedURL
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
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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
