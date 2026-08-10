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
    @FocusState private var focusedField: LoginField?

    private enum LoginField {
        case server, username, password
    }

    var body: some View {
        ZStack {
            ConduitBackdrop()

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
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))

                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit { Task { await connect() } }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))

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
                        Toggle("Use Cloudflare Access service token", isOn: $cloudflareEnabled)
                            .tint(.conduitAccent)
                        if cloudflareEnabled {
                            TextField("Cloudflare Client ID", text: $cloudflareClientID)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(.horizontal, 14).frame(height: 50)
                                .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
                            SecureField("Cloudflare Client Secret", text: $cloudflareClientSecret)
                                .padding(.horizontal, 14).frame(height: 50)
                                .conduitGlassSurface(cornerRadius: 17, tint: .conduitAura.opacity(0.06))
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

    private func connect() async {
        let cleaned = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
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

            let ticket = try await client.connect(username: username, password: password)
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
            await appState.connect(with: HermesConnection(baseUrl: serverUrl, ticket: ticket))
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
        guard let normalized, let dashboardURL = URL(string: normalized) else {
            onError(ConnectionURLPolicyError.invalidURL.localizedDescription)
            return webView
        }
        let loginURL = dashboardURL.appending(path: "login")
        var request = URLRequest(url: loginURL)
        request = cloudflareAccess?.applying(to: request) ?? request
        webView.load(request)
        return webView
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
