//
//  DashboardTicketBridge.swift
//  Conduit
//
//  Keeps the dashboard's HttpOnly session cookie inside WebKit and mints a
//  fresh, single-use WebSocket ticket whenever Hermes needs to reconnect.
//

import Foundation
import SwiftUI
import WebKit
import Security

/// WebKit normally persists durable cookies itself, but dashboard deployments
/// often issue a session cookie. Mirror the authenticated dashboard cookies in
/// Keychain and restore them before the cold-launch bridge loads. Values stay
/// device-local and are cleared with the saved connection on explicit sign-out.
@MainActor
enum DashboardCookiePersistence {
    private struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresDate: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool
        let sameSitePolicy: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expiresDate = cookie.expiresDate
            isSecure = cookie.isSecure
            isHTTPOnly = cookie.isHTTPOnly
            sameSitePolicy = cookie.sameSitePolicy?.rawValue
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
                .secure: isSecure ? "TRUE" : "FALSE"
            ]
            if let expiresDate { properties[.expires] = expiresDate }
            if isHTTPOnly { properties[.init("HttpOnly")] = "TRUE" }
            if let sameSitePolicy { properties[.sameSitePolicy] = sameSitePolicy }
            return HTTPCookie(properties: properties)
        }
    }

    static func restore(into cookieStore: WKHTTPCookieStore) async {
        guard let data = KeychainHelper.loadDashboardCookies(),
              let saved = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return }
        for cookie in saved.compactMap(\.cookie) {
            await cookieStore.setCookie(cookie)
        }
    }

    /// URLSession and WebKit maintain separate cookie stores. Copy the native
    /// password-login session into WebKit before the bridge loads its first
    /// dashboard request, keeping the existing dashboard API path authenticated.
    static func restoreNativeCookies(into cookieStore: WKHTTPCookieStore, for baseURL: String) async {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return }
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        for cookie in cookies where cookieMatchesHost(cookie, host: host) {
            await cookieStore.setCookie(cookie)
        }
    }

    static func capture(from cookieStore: WKHTTPCookieStore, for url: URL?) async {
        guard let host = url?.host?.lowercased() else { return }
        let cookies = await cookieStore.allCookies().filter { cookie in
            cookieMatchesHost(cookie, host: host)
        }
        guard let data = try? JSONEncoder().encode(cookies.map(StoredCookie.init)) else { return }
        KeychainHelper.saveDashboardCookies(data)
    }

    private static func cookieMatchesHost(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix(".\(domain)")
    }
}

enum DashboardTicketBridgeError: LocalizedError {
    case notReady
    case signInRequired
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The dashboard session is still loading."
        case .signInRequired:
            return "Dashboard sign-in has expired."
        case .requestFailed(let message):
            return message
        }
    }
}

@MainActor
final class DashboardTicketBridge: NSObject {
    let baseURL: String
    let webView: WKWebView
    let cloudflareAccess: CloudflareAccessCredentials?

    private var isReady = false
    private var requestID = 0
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    init(baseURL: String, cloudflareAccess: CloudflareAccessCredentials? = nil) {
        self.baseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? ""
        self.cloudflareAccess = cloudflareAccess
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if let script = cloudflareAccess?.fetchInjectionUserScript, !script.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "dashboard-response")
        webView.navigationDelegate = self
        Task { [weak self] in
            guard let self else { return }
            await DashboardCookiePersistence.restore(into: self.webView.configuration.websiteDataStore.httpCookieStore)
            await DashboardCookiePersistence.restoreNativeCookies(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                for: self.baseURL
            )
            self.loadDashboardSession()
        }
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dashboard-response")
    }

    func reload() {
        isReady = false
        rejectPending(with: DashboardTicketBridgeError.notReady)
        Task { [weak self] in
            guard let self else { return }
            await DashboardCookiePersistence.restore(into: self.webView.configuration.websiteDataStore.httpCookieStore)
            await DashboardCookiePersistence.restoreNativeCookies(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                for: self.baseURL
            )
            self.loadDashboardSession()
        }
    }

    func mintTicket() async throws -> String {
        // A freshly restored session cookie can reach WebKit's cookie store a
        // moment before its network process. A first 401 is therefore not
        // enough evidence to erase the durable session and force a login.
        for attempt in 0..<3 {
            try await waitUntilReady()
            do {
                let response = try await requestJSON(path: "/api/auth/ws-ticket", method: "POST")
                guard let ticket = response["ticket"] as? String, !ticket.isEmpty else {
                    throw DashboardTicketBridgeError.requestFailed("Dashboard did not return a WebSocket ticket.")
                }
                return ticket
            } catch DashboardTicketBridgeError.signInRequired where attempt < 2 {
                reload()
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        throw DashboardTicketBridgeError.signInRequired
    }

    private func waitUntilReady() async throws {
        for _ in 0..<30 where !isReady {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard isReady else { throw DashboardTicketBridgeError.notReady }
    }

    /// Requests authenticated dashboard JSON through the same WebKit cookie
    /// jar that the sign-in flow owns. This intentionally avoids duplicating
    /// HttpOnly session handling in URLSession.
    func requestJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        for _ in 0..<30 where !isReady {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard isReady else { throw DashboardTicketBridgeError.notReady }

        requestID += 1
        let id = requestID
        let pathLiteral = try javaScriptLiteral(path)
        let methodLiteral = try javaScriptLiteral(method)
        let bodyLiteral = try body.map(javaScriptLiteral) ?? "null"
        let timeout = max(1_000, timeoutMilliseconds)
        let responseLimit = max(1_024, maxResponseBytes)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                pendingRequests[id] = continuation
                let script = """
                (async function() {
                    try {
                        const requestBody = \(bodyLiteral);
                        const controller = new AbortController();
                        const timeout = setTimeout(() => controller.abort(), \(timeout));
                        const response = await fetch(\(pathLiteral), {
                            method: \(methodLiteral),
                            credentials: 'include',
                            headers: requestBody === null
                                ? { Accept: 'application/json' }
                                : { Accept: 'application/json', 'Content-Type': 'application/json' },
                            body: requestBody === null ? undefined : JSON.stringify(requestBody),
                            signal: controller.signal
                        });
                        const declaredLength = Number(response.headers.get('content-length') || 0);
                        if (declaredLength > \(responseLimit)) throw new Error('response_too_large');
                        const text = await (async function() {
                            if (!response.body || typeof response.body.getReader !== 'function') {
                                if (!Number.isFinite(declaredLength) || declaredLength <= 0) throw new Error('bounded_response_unavailable');
                                return response.text();
                            }
                            const reader = response.body.getReader();
                            const decoder = new TextDecoder();
                            let totalBytes = 0;
                            let result = '';
                            while (true) {
                                const chunk = await reader.read();
                                if (chunk.done) {
                                    result += decoder.decode();
                                    return result;
                                }
                                totalBytes += chunk.value.byteLength;
                                if (totalBytes > \(responseLimit)) {
                                    await reader.cancel();
                                    throw new Error('response_too_large');
                                }
                                result += decoder.decode(chunk.value, { stream: true });
                            }
                        })();
                        clearTimeout(timeout);
                        let body = null;
                        try { body = text ? JSON.parse(text) : null; } catch (_) { body = text; }
                        const normalizedBody = Array.isArray(body) ? { _array: body } : (body && typeof body === 'object' ? body : { value: body });
                        window.webkit.messageHandlers['dashboard-response'].postMessage(JSON.stringify({
                            type: 'dashboard-response', id: \(id), ok: response.ok,
                            status: response.status, body: normalizedBody,
                            error: !response.ok && body && typeof body === 'object'
                                ? (body.error || body.message || body.detail) : null
                        }));
                    } catch (error) {
                        window.webkit.messageHandlers['dashboard-response'].postMessage(JSON.stringify({
                            type: 'dashboard-response', id: \(id), ok: false, status: 0, error: String(error)
                        }));
                    }
                })();
                true;
                """
                webView.evaluateJavaScript(script) { _, error in
                    guard let error, let pending = self.pendingRequests.removeValue(forKey: id) else { return }
                    pending.resume(throwing: error)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id: id)
            }
        })
    }

    private func cancelPendingRequest(id: Int) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func javaScriptLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let literal = String(data: data, encoding: .utf8) else {
            throw DashboardTicketBridgeError.requestFailed("Could not encode dashboard request.")
        }
        return literal
    }

    private func loadDashboardSession() {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)/api/status") else { return }
        var request = URLRequest(url: url)
        request = cloudflareAccess?.applying(to: request) ?? request
        webView.load(request)
    }

    private func rejectPending(with error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }
}

extension DashboardTicketBridge: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard ConnectionURLPolicy.isAllowedTransport(navigationAction.request.url) else {
            decisionHandler(.cancel)
            return
        }
        if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
            decisionHandler(.allow)
            return
        }
        guard let expectedURL = URL(string: baseURL),
              ConnectionURLPolicy.originMatches(navigationAction.request.url, expected: expectedURL) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A redirect back to /login means the HttpOnly dashboard session is no
        // longer valid; never attempt to mint a misleading gateway ticket.
        guard let expectedURL = URL(string: baseURL),
              ConnectionURLPolicy.originMatches(webView.url, expected: expectedURL) else {
            isReady = false
            rejectPending(with: DashboardTicketBridgeError.requestFailed("Dashboard navigation left the configured origin."))
            return
        }
        isReady = !(webView.url?.path.contains("/login") ?? true)
        if !isReady {
            rejectPending(with: DashboardTicketBridgeError.signInRequired)
        } else {
            Task { @MainActor in
                await DashboardCookiePersistence.capture(
                    from: webView.configuration.websiteDataStore.httpCookieStore,
                    for: expectedURL
                )
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isReady = false
        rejectPending(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isReady = false
        rejectPending(with: error)
    }
}

extension DashboardTicketBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dashboard-response", let raw = message.body as? String,
              message.frameInfo.isMainFrame,
              let expectedURL = URL(string: baseURL),
              ConnectionURLPolicy.originMatches(
                scheme: message.frameInfo.securityOrigin.protocol,
                host: message.frameInfo.securityOrigin.host,
                port: message.frameInfo.securityOrigin.port,
                expected: expectedURL
              ),
              let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["type"] as? String == "dashboard-response",
              let id = payload["id"] as? Int,
              let continuation = pendingRequests.removeValue(forKey: id) else { return }

        if payload["ok"] as? Bool == true {
            continuation.resume(returning: payload["body"] as? [String: Any] ?? [:])
            return
        }

        let status = payload["status"] as? Int ?? 0
        if status == 401 || status == 403 {
            continuation.resume(throwing: DashboardTicketBridgeError.signInRequired)
            return
        }
        let detail = payload["error"] as? String ?? "Dashboard request failed (\(status))."
        continuation.resume(throwing: DashboardTicketBridgeError.requestFailed(detail))
    }
}

/// Hosts the authenticated WebKit process in the SwiftUI hierarchy. It has no
/// visible UI; its only job is preserving the dashboard's HttpOnly session for
/// fresh WebSocket tickets after a reconnect or cold launch.
struct DashboardTicketBridgeView: UIViewRepresentable {
    let bridge: DashboardTicketBridge

    func makeUIView(context: Context) -> WKWebView {
        bridge.webView.isUserInteractionEnabled = false
        return bridge.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
