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

struct LoginView: View {
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
    @State private var error: String?
    /// Set only by the user's Cloudflare toggle (never by the onAppear
    /// Keychain restore), so a returning saved-token user is not scrolled
    /// away from the top of the form every time the login screen appears.
    @State private var revealCloudflareSection = false
    @FocusState private var focusedField: LoginField?

    var body: some View {
        ZStack {
            ConduitBackdrop()
                .contentShape(Rectangle())
                .onTapGesture {
                    // Tapping the backdrop (outside any field or control) clears
                    // focus so the keyboard dismisses and the Connect button is
                    // reachable. The gesture lives on the background layer — not
                    // the root — so it never competes with a text field's
                    // first-responder touch (no two-tap-to-focus regression).
                    focusedField = nil
                }

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
            guard serverUrl.isEmpty else { return }
            serverUrl = appState.lastDashboardURL
            if let access = KeychainHelper.loadCloudflareAccess(for: serverUrl) {
                cloudflareEnabled = true
                cloudflareClientID = access.clientID
                cloudflareClientSecret = access.clientSecret
            }
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
                    error = message
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

                TextField("https://hermes.example", text: $serverUrl)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
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
                    .submitLabel(LoginField.username.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                    .focused($focusedField, equals: .username)
                    .onSubmit { handleSubmit(from: .username) }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                    .id(LoginField.username)

                SecureField("Password", text: $password)
                    .textContentType(.password)
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
                    if cloudflareEnabled {
                        TextField("Cloudflare Client ID", text: $cloudflareClientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .cloudflareClientID)
                            .submitLabel(LoginField.cloudflareClientID.submitKeyboardLabel(cloudflareTokenEntryEnabled: cloudflareEnabled))
                            .onSubmit { handleSubmit(from: .cloudflareClientID) }
                            .padding(.horizontal, 14).frame(height: 50)
                            .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                            .id(LoginField.cloudflareClientID)
                        SecureField("Cloudflare Client Secret", text: $cloudflareClientSecret)
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
                if let error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.footnote)
                        Text(error)
                            .font(.footnote)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
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
                .foregroundStyle(.white)
                .disabled(serverUrl.isEmpty || username.isEmpty || password.isEmpty || isConnecting)
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
        let cleaned = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        // The return-key chain can reach submit while an earlier field was
        // skipped (e.g. tapping straight into the Cloudflare Secret); land
        // focus on the missing field instead of a raw remote 401. The
        // password value itself is sent untrimmed.
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter your dashboard username and password."
            focusedField = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .username : .password
            return
        }
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(cleaned) else {
            error = ConnectionURLPolicyError.insecureTransport.localizedDescription
            return
        }
        serverUrl = normalized
        appState.rememberDashboardURL(serverUrl)
        error = nil
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
            self.error = error.localizedDescription
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

// MARK: - Auth WebView

struct AuthWebView: UIViewRepresentable {
    let url: String
    let cloudflareAccess: CloudflareAccessCredentials?
    let onTicket: (String, String) -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let normalized = try? ConnectionURLPolicy.normalizedBaseURL(url)
        let config = WKWebViewConfiguration()
        WebViewUserAgent.apply(to: config)
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
            guard ConnectionURLPolicy.isAllowedTransport(navigationAction.request.url) else {
                decisionHandler(.cancel)
                return
            }
            // Subframes may host an identity provider, but every top-level
            // navigation must stay on the configured dashboard origin.
            if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
                decisionHandler(.allow)
                return
            }
            if !hasPinnedDashboardOrigin {
                // Passwordless/OAuth providers legitimately use a short
                // cross-origin redirect chain during sign-in. The ticket
                // message remains origin-pinned below, and navigation locks
                // to the dashboard as soon as the authenticated route loads.
                decisionHandler(.allow)
                return
            }
            guard let expectedURL,
                  ConnectionURLPolicy.originMatches(navigationAction.request.url, expected: expectedURL) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
