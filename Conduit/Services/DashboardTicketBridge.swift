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

    static func capture(
        from cookieStore: WKHTTPCookieStore,
        for url: URL?,
        shouldPersist: (() -> Bool)? = nil
    ) async {
        guard let host = url?.host?.lowercased() else { return }
        let cookies = await cookieStore.allCookies().filter { cookie in
            cookieMatchesHost(cookie, host: host)
        }
        // The cookie-store await above can straddle an invalidation or
        // disconnect; only the moment of the keychain write decides whether
        // the durable mirror survives, so consult the guard here.
        if let shouldPersist, !shouldPersist() { return }
        guard let data = try? JSONEncoder().encode(cookies.map(StoredCookie.init)) else { return }
        KeychainHelper.saveDashboardCookies(data)
    }

    /// Removes dashboard-origin cookies from a WebKit cookie store. Disconnect
    /// must not leave a reusable HttpOnly session behind in the persistent
    /// default data store; clearing only the origin-matching cookies keeps any
    /// unrelated cookies intact.
    static func clear(from cookieStore: WKHTTPCookieStore, for url: URL?) async {
        guard let host = url?.host?.lowercased() else { return }
        for cookie in await cookieStore.allCookies() where cookieMatchesHost(cookie, host: host) {
            await cookieStore.deleteCookie(cookie)
        }
    }

    /// Removes dashboard-origin cookies from the shared Foundation cookie
    /// store. The native password-login flow authenticates through
    /// `HTTPCookieStorage.shared`; without this, its session cookie outlives
    /// Disconnect and can satisfy a later silent resume. `HTTPCookieStorage`
    /// is thread-safe, so this is `nonisolated` to stay callable from any
    /// context (including tests) without requiring main-actor isolation.
    nonisolated static func clearNativeCookies(for baseURL: String) {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookieMatchesHost(cookie, host: host) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    nonisolated private static func cookieMatchesHost(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix(".\(domain)")
    }
}

enum DashboardTicketBridgeError: LocalizedError {
    case notReady
    case signInRequired
    /// Local/dashboard-message failures that never produced an HTTP status
    /// (request encoding, ticket-mint details). HTTP failures travel as
    /// `.http(status:detail:)` instead.
    case requestFailed(String)
    /// Non-auth HTTP failure carrying the gateway's status code, so callers
    /// can recognize structural gaps (404/410 — e.g. a gateway without the
    /// session-messages endpoint) and transient trouble (429/5xx/408, status
    /// 0) and fall back deliberately instead of treating them like unrelated
    /// server errors.
    case http(status: Int, detail: String)
    /// The response exceeded the client's safe response bound
    /// (`DataURLLimits.maxJSONResponseBytes`) before it could be parsed.
    /// Distinguished from generic status-0 failures so callers can react to
    /// a known-oversized history response without retrying the same giant
    /// transcript over another transport.
    case oversizedResponse(limit: Int)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The dashboard session is still loading."
        case .signInRequired:
            return "Dashboard sign-in has expired."
        case .requestFailed(let message):
            return message
        case .http(_, let detail):
            return detail
        case .oversizedResponse:
            // Generic bridge-level copy: this error is raised for ANY
            // dashboard response that exceeds the safe bound (workspace-file
            // reads, catalogs, history), not exclusively transcripts.
            // Transcript-specific messaging is mapped in the transcript
            // layer, which knows whether the request was a legacy one-shot
            // or a bounded current-Hermes page.
            return "This response is too large to load safely."
        }
    }
}

/// WKUserContentController retains its script message handlers strongly, so
/// registering the bridge directly forms a cycle (bridge → webView →
/// configuration → userContentController → bridge) that `deinit` can never
/// break — every replaced bridge would keep a WebKit content process alive
/// for the app's lifetime. The proxy holds the bridge weakly instead.
///
/// WebKit delivers `userContentController(_:didReceive:)` on the main thread,
/// and the proxied bridge is `@MainActor`; marking the proxy `@MainActor` too
/// makes that isolation contract explicit so the forward into the bridge needs
/// no implicit cross-actor hop and stays correct under Swift 6 strict
/// concurrency.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class DashboardTicketBridgePendingRequests {
    typealias Continuation = CheckedContinuation<[String: Any], Error>

    private var storage: [Int: Continuation] = [:]

    var count: Int { storage.count }

    func insert(_ continuation: Continuation, for id: Int) {
        storage[id] = continuation
    }

    func removeValue(for id: Int) -> Continuation? {
        storage.removeValue(forKey: id)
    }

    func rejectAll(with error: Error) {
        let pending = storage
        storage.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }
}

@MainActor
final class DashboardTicketBridge: NSObject {
    let baseURL: String
    let webView: WKWebView
    let cloudflareAccess: CloudflareAccessCredentials?

    private var isReady = false
    /// Whether the current dashboard page load has terminally failed (as
    /// opposed to still being in flight on a slow link). Retry logic only
    /// reloads a failed load — restarting an in-progress one would abort a
    /// load that may be about to finish on a degraded connection.
    /// Readable for tests; written only by the navigation callbacks.
    private(set) var isLoadFailed = false
    /// Whether the dashboard redirected the bridge to its login page — the
    /// session is genuinely absent, which callers must hear as
    /// `.signInRequired` rather than as unreadiness.
    private var didLandOnLogin = false
    /// Test-only landing state, re-asserted by every page load so tests can
    /// model a dashboard that keeps producing the same landing regardless of
    /// when WKWebView's nondeterministic callbacks arrive.
    private var simulatedLanding: SimulatedLanding?

    enum SimulatedLanding {
        case ready
        case loginPage
        case loadFailure
    }
    private var isInvalidated = false
    private var requestID = 0
    /// Identity of the current dashboard navigation, used to ignore failure
    /// callbacks for loads a reload has already replaced. `staleNavigations`
    /// covers the window between a reload and its new load: failures for
    /// superseded navigations must not fail the fresh state.
    private var currentNavigation: WKNavigation?
    private var staleNavigations: Set<WKNavigation> = []
    private let pendingRequests: DashboardTicketBridgePendingRequests
    private let requestDeadlineGraceMilliseconds: Int
    /// Swift-side deadlines for in-flight `requestJSON` continuations. The
    /// JavaScript timeout only fires inside a live web view; if the content
    /// process is gone (or a response message is dropped), nothing but these
    /// deadlines resumes the continuation — without them a single lost
    /// response hangs ticket minting, and therefore reconnecting, forever.
    private var requestDeadlines: [Int: Task<Void, Never>] = [:]
    private let readinessPollAttempts: Int
    private let readinessPollInterval: Duration
    /// Number of times `reload()` re-attempted the dashboard page load, from
    /// any caller (mint retries and AppState's sign-in recovery alike).
    /// Diagnostic/test counter for the cold-bridge recovery path.
    private(set) var reloadCount = 0

    init(
        baseURL: String,
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        pendingRequests: DashboardTicketBridgePendingRequests = DashboardTicketBridgePendingRequests(),
        readinessPollAttempts: Int = 30,
        readinessPollInterval: Duration = .milliseconds(100),
        requestDeadlineGraceMilliseconds: Int = 3_000
    ) {
        let normalizedBaseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? ""
        self.baseURL = normalizedBaseURL
        self.cloudflareAccess = cloudflareAccess
        self.pendingRequests = pendingRequests
        // A negative count would build an invalid Range in the polling loops.
        self.readinessPollAttempts = max(0, readinessPollAttempts)
        self.readinessPollInterval = readinessPollInterval
        self.requestDeadlineGraceMilliseconds = max(0, requestDeadlineGraceMilliseconds)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if let script = cloudflareAccess?.fetchInjectionUserScript(expectedBaseURL: normalizedBaseURL), !script.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: "dashboard-response")
        webView.navigationDelegate = self
        Task { [weak self] in
            guard let self else { return }
            await DashboardCookiePersistence.restore(into: self.webView.configuration.websiteDataStore.httpCookieStore)
            await DashboardCookiePersistence.restoreNativeCookies(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                for: self.baseURL
            )
            guard !self.isInvalidated else { return }
            self.loadDashboardSession()
        }
    }

    deinit {
        // Stored-property access and Task.cancel() are safe from nonisolated
        // deinit; cancelling here stops deadline tasks from outliving the
        // bridge they were created to guard.
        for deadline in requestDeadlines.values { deadline.cancel() }
        requestDeadlines.removeAll()
        pendingRequests.rejectAll(with: DashboardTicketBridgeError.notReady)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dashboard-response")
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        isReady = false
        // A torn-down bridge must report plain unreadiness: leaving a stale
        // login verdict would surface .signInRequired (with its session
        // recovery) from an invalidated instance.
        didLandOnLogin = false
        rejectPending(with: DashboardTicketBridgeError.notReady)
    }

    func reload() {
        guard !isInvalidated else { return }
        reloadCount += 1
        isReady = false
        // Supersede the old navigation immediately: its late failure
        // callbacks must not fail the fresh state during the window before
        // the new load starts.
        if let old = currentNavigation {
            staleNavigations.insert(old)
        }
        currentNavigation = nil
        // Reset the landing verdicts synchronously: leaving them set until
        // the async load task runs lets the next retry observe a stale
        // failure/login verdict and reload AGAIN, aborting the load that
        // was just started. Clearing the login verdict here is safe because
        // a deliberate reload supersedes it — the fresh landing
        // re-establishes (or clears) it via didFinish. Without this, a
        // cookie restore slower than the 350ms retry sleep made the login
        // fast-exit burn every attempt against the stale verdict and
        // escalate straight to sign-out. (Test simulations re-assert their
        // landing so it persists across reloads deterministically.)
        isLoadFailed = false
        didLandOnLogin = false
        applySimulatedLanding()
        rejectPending(with: DashboardTicketBridgeError.notReady)
        Task { [weak self] in
            guard let self else { return }
            await DashboardCookiePersistence.restore(into: self.webView.configuration.websiteDataStore.httpCookieStore)
            await DashboardCookiePersistence.restoreNativeCookies(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                for: self.baseURL
            )
            guard !self.isInvalidated else { return }
            self.loadDashboardSession()
        }
    }

    /// Re-asserts the test-simulated landing state; a no-op in production.
    private func applySimulatedLanding() {
        switch simulatedLanding {
        case .ready:
            isReady = true
        case .loginPage:
            didLandOnLogin = true
        case .loadFailure:
            isLoadFailed = true
        case nil:
            break
        }
    }

    func mintTicket() async throws -> String {
        // Retry twice on the two recoverable failures, then let the final
        // attempt's error propagate to the caller unchanged:
        //  - signInRequired: a freshly restored session cookie can reach
        //    WebKit's cookie store a moment before its network process, so a
        //    first 401 is not enough evidence to erase the durable session
        //    and force a login. Reload unconditionally so the cookie store
        //    settles, then re-attempt.
        //  - notReady: the dashboard page has not produced a ready session.
        //    Only a terminally failed load is reloaded — on a degraded link a
        //    load can still be in flight when the readiness poll times out,
        //    and restarting it would abort a navigation that may be about to
        //    finish, so keep polling the same load instead.
        for attempt in 0..<3 {
            do {
                try await waitUntilReady()
                let response = try await requestJSON(path: "/api/auth/ws-ticket", method: "POST")
                guard let ticket = response["ticket"] as? String, !ticket.isEmpty else {
                    throw DashboardTicketBridgeError.requestFailed("Dashboard did not return a WebSocket ticket.")
                }
                return ticket
            } catch DashboardTicketBridgeError.signInRequired where attempt < 2 {
                reload()
                try await Task.sleep(for: .milliseconds(350))
            } catch DashboardTicketBridgeError.notReady where attempt < 2 {
                // A silently hung load is eventually failed by the system
                // request timeout and becomes reloadable.
                if isLoadFailed {
                    reload()
                }
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        // Unreachable in practice: on the final attempt neither catch
        // pattern matches, so that attempt's error has already propagated.
        // Present only to satisfy definite-exit checking.
        throw DashboardTicketBridgeError.notReady
    }

    private func waitUntilReady() async throws {
        // Stop polling as soon as the navigation terminally fails or the
        // page has settled on the login screen: neither can become ready
        // without a reload or sign-in, so sleeping out the window would
        // just delay the recovery.
        for _ in 0..<readinessPollAttempts where !isReady && !isInvalidated && !isLoadFailed && !didLandOnLogin {
            try await Task.sleep(for: readinessPollInterval)
        }
        guard !isInvalidated, isReady else {
            // A bridge parked on the login page is signed out, not loading:
            // surface the expiry so callers run their sign-in recovery
            // instead of polling an already-settled page. An invalidated
            // bridge always reports plain unreadiness — a late navigation
            // callback must not resurrect sign-in state on a torn-down
            // instance.
            throw isInvalidated || !didLandOnLogin
                ? DashboardTicketBridgeError.notReady
                : DashboardTicketBridgeError.signInRequired
        }
    }

    /// Requests authenticated dashboard JSON through the same WebKit cookie
    /// jar that the sign-in flow owns. This intentionally avoids duplicating
    /// HttpOnly session handling in URLSession.
    ///
    /// Error contract: unusable page states (foreign-origin landing, stalled
    /// engine) surface as `.notReady` so callers flow into the reload
    /// recovery; an origin-matching login landing surfaces as
    /// `.signInRequired`. Direct callers should not expect `.requestFailed`
    /// for these states.
    func requestJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        for _ in 0..<readinessPollAttempts where !isReady && !isInvalidated && !isLoadFailed && !didLandOnLogin {
            try await Task.sleep(for: readinessPollInterval)
        }
        guard !isInvalidated, isReady else {
            // Mirror waitUntilReady(): a login-parked or terminally failed
            // bridge is settled, not loading, for non-mint callers too, and
            // an invalidated bridge always reports plain unreadiness.
            throw isInvalidated || !didLandOnLogin
                ? DashboardTicketBridgeError.notReady
                : DashboardTicketBridgeError.signInRequired
        }

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

                pendingRequests.insert(continuation, for: id)
                // Swift-side deadline: the JavaScript AbortController above
                // only runs inside a live web view. If the content process
                // is gone or a response message is dropped, this is the only
                // thing that resumes the continuation — convert the silent
                // hang into a failure the reconnect loop can retry through
                // the reload path.
                // A live page answers before this fires (its own 12s abort
                // posts a response message), so expiry means the view is
                // stalled and the request marks it for reload below.
                let deadlineDelayMilliseconds = deadlineDelay(afterMilliseconds: timeout)
                requestDeadlines[id] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(deadlineDelayMilliseconds))
                    guard !Task.isCancelled else { return }
                    // .notReady (not .requestFailed) so the failure funnels
                    // into mintTicket's internal reload-retry instead of
                    // surfacing past it — a timed-out JavaScript response is
                    // almost always a dead or stalled web view, i.e. exactly
                    // the state reloading revives.
                    self?.failPendingRequest(
                        id: id,
                        with: DashboardTicketBridgeError.notReady,
                        markingWebViewStalled: true
                    )
                }
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
                webView.evaluateJavaScript(script) { [weak self] _, error in
                    guard let self else { return }
                    guard let error else { return }
                    // The injected IIFE funnels every JS-level failure into
                    // the message channel, so a completion error means the
                    // engine never ran the script — a dead or stalled view.
                    // Always route it onto the typed stall path (which
                    // reloads the page and flushes sibling requests) instead
                    // of letting an untyped NSError escape past mintTicket's
                    // retry funnel. A request whose continuation was already
                    // resumed (e.g. by reload) no-ops here.
                    self.failPendingRequest(
                        id: id,
                        with: DashboardTicketBridgeError.notReady,
                        markingWebViewStalled: true
                    )
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id: id)
            }
        })
    }

    /// Cancels the Swift-side deadline and resumes the pending request, if
    /// any, with `error`. All failure-side resume paths funnel through here
    /// so the deadline task can never fire on an already-resumed request.
    private func failPendingRequest(
        id: Int,
        with error: Error,
        markingWebViewStalled: Bool = false
    ) {
        requestDeadlines.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingRequests.removeValue(for: id) else { return }
        if markingWebViewStalled {
            // Only reached when the request deadline expired or the JS
            // engine never ran the script: a live page answers before that
            // (its in-JS abort posts a response), so this proves the view
            // is stalled. Mark it cold-but-reloadable so mintTicket's next
            // attempt reloads instead of retrying evaluateJavaScript
            // against the same dead view.
            isReady = false
            isLoadFailed = true
            didLandOnLogin = false
        }
        continuation.resume(throwing: error)
        if markingWebViewStalled {
            // The view is proven stalled; every other in-flight request into
            // it would hang until its own deadline. Fail them now into the
            // same reload recovery.
            rejectPending(with: DashboardTicketBridgeError.notReady)
        }
    }

    /// Deadline delay with an overflow-safe grace addition.
    private func deadlineDelay(afterMilliseconds timeout: Int) -> Int {
        let grace = requestDeadlineGraceMilliseconds
        return min(timeout, Int.max - grace) + grace
    }

    private func cancelPendingRequest(id: Int) {
        failPendingRequest(id: id, with: CancellationError())
    }

    private func javaScriptLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let literal = String(data: data, encoding: .utf8) else {
            throw DashboardTicketBridgeError.requestFailed("Could not encode dashboard request.")
        }
        return literal
    }

    /// Test hook: put the bridge into the state a given landing produces
    /// and keep producing it across reloads (login page or terminally
    /// failed load). WKWebView's URL and failure callbacks are not
    /// deterministically drivable in the unit test host, so tests model the
    /// landing state instead.
    func simulateLandingForTesting(_ landing: SimulatedLanding) {
        simulatedLanding = landing
        switch landing {
        case .ready:
            isReady = true
            isLoadFailed = false
            didLandOnLogin = false
        case .loginPage:
            isReady = false
            isLoadFailed = false
            didLandOnLogin = true
        case .loadFailure:
            isReady = false
            isLoadFailed = true
            didLandOnLogin = false
        }
    }

    private func loadDashboardSession() {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)/api/status") else { return }
        var request = URLRequest(url: url)
        request = cloudflareAccess?.applying(to: request) ?? request
        // The fresh load's landing is unknown until its navigation callback;
        // a stale verdict must not leak into its poll window. Reset the
        // verdicts explicitly (nil simulatedLanding in production), then
        // re-assert any test simulation on purpose. Readiness also flips
        // off defensively: any caller reaching here with a stale ready flag
        // must not serve requests against a page that is about to change.
        isReady = false
        isLoadFailed = false
        didLandOnLogin = false
        applySimulatedLanding()
        currentNavigation = webView.load(request)
    }

    private func rejectPending(with error: Error) {
        for deadline in requestDeadlines.values { deadline.cancel() }
        requestDeadlines.removeAll()
        pendingRequests.rejectAll(with: error)
    }
}

extension DashboardTicketBridge: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Subframe check must come BEFORE the main-frame transport guard:
        // Turnstile's WebView requirements call for about:blank and
        // about:srcdoc subframe documents, which plain HTTP(S) transport
        // rules would reject. The allowance is confined to subframes —
        // a top-level navigation attempt from such a document re-enters
        // this delegate as a MAIN frame and still must match the dashboard
        // origin below.
        if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
            decisionHandler(
                ConnectionURLPolicy.isAllowedWebViewSubframeTransport(navigationAction.request.url)
                    ? .allow : .cancel
            )
            return
        }
        guard ConnectionURLPolicy.isAllowedTransport(navigationAction.request.url) else {
            decisionHandler(.cancel)
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
        // Reject finishes for navigations a reload has already superseded:
        // a late didFinish(A) while the fresh load B is in flight would
        // otherwise process A's landing over B's pending state AND clear
        // B's identity, disarming the failure-suppression guards below.
        if let navigation, staleNavigations.remove(navigation) != nil {
            return
        }
        if let currentNavigation, let navigation, navigation !== currentNavigation {
            return
        }
        // The tracked load has resolved; identity-based suppression ends
        // here (page-initiated navigations after a finish process normally).
        currentNavigation = nil
        // A landing with no URL at all is unknown, not "signed out" — treat
        // it as reloadable rather than guessing a login redirect.
        guard let landedURL = webView.url,
              let expectedURL = URL(string: baseURL),
              ConnectionURLPolicy.originMatches(landedURL, expected: expectedURL) else {
            isReady = false
            // A settled foreign-origin or unknown-URL landing (e.g. an SSO
            // redirect that slipped past the navigation policy, or an error
            // document) is unusable, not still loading — mark it failed so
            // mint retries reload back to the dashboard origin. Reject with
            // .notReady (not .requestFailed) so in-flight mints flow into
            // that same reload recovery. The login verdict is deliberately
            // untouched: only an origin-matching landing can change it.
            isLoadFailed = true
            rejectPending(with: DashboardTicketBridgeError.notReady)
            return
        }
        isLoadFailed = false
        // A redirect back to /login means the HttpOnly dashboard session is
        // no longer valid; never attempt to mint a misleading gateway ticket.
        let landedOnLogin = landedURL.path.contains("/login")
        isReady = !landedOnLogin
        didLandOnLogin = landedOnLogin
        if landedOnLogin {
            rejectPending(with: DashboardTicketBridgeError.signInRequired)
        } else if !isInvalidated {
            // Late cookie capture after disconnect must not resurrect the
            // durable mirror AppState just cleared: the write guard runs at
            // the moment of the keychain save, after the cookie-store await.
            Task { @MainActor in
                await DashboardCookiePersistence.capture(
                    from: webView.configuration.websiteDataStore.httpCookieStore,
                    for: expectedURL,
                    shouldPersist: { [weak self] in
                        guard let self else { return false }
                        return !self.isInvalidated
                    }
                )
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // A failure for a navigation a reload has already replaced (or that
        // finished) must not fail the fresh load; remove-on-match keeps the
        // stale set from retaining superseded navigations. A nil identity on
        // either side processes the callback — failures without navigation
        // context still carry real signal.
        if let navigation, staleNavigations.remove(navigation) != nil { return }
        if let currentNavigation, let navigation, navigation !== currentNavigation { return }
        isReady = false
        isLoadFailed = true
        rejectPending(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let navigation, staleNavigations.remove(navigation) != nil { return }
        if let currentNavigation, let navigation, navigation !== currentNavigation { return }
        isReady = false
        isLoadFailed = true
        rejectPending(with: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reclaims the web content process under memory pressure —
        // typically while the app is suspended overnight. From that moment
        // the in-memory isReady flag is stale: evaluateJavaScript gets no
        // usable page, and without this callback nothing ever reloads it,
        // so the next ticket mint (and therefore every reconnect) hangs
        // until the user force-quits the app. Treat the bridge as cold but
        // reloadable: pending requests resume into the retry paths, and
        // mintTicket's .notReady recovery revives the page.
        isReady = false
        isLoadFailed = true
        didLandOnLogin = false
        currentNavigation = nil
        rejectPending(with: DashboardTicketBridgeError.notReady)
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
              let continuation = pendingRequests.removeValue(for: id) else { return }
        requestDeadlines.removeValue(forKey: id)?.cancel()

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
        // The injected fetch throws exactly one sentinel for a response that
        // outgrew the safe bound (content-length or streamed bytes). It
        // arrives here as a status-0 failure like every other JS-level
        // error, but it is a known-oversized response, not transport
        // trouble — give callers the typed condition so an oversized
        // history read is never mistaken for a retryable network failure.
        if status == 0, detail.contains("response_too_large") {
            continuation.resume(throwing: DashboardTicketBridgeError.oversizedResponse(
                limit: DataURLLimits.maxJSONResponseBytes
            ))
            return
        }
        continuation.resume(throwing: DashboardTicketBridgeError.http(status: status, detail: detail))
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
