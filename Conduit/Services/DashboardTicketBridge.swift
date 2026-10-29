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
///
/// Live session state is DASHBOARD-OWNED, not global (#148): each dashboard
/// gets its own `WKWebsiteDataStore(forIdentifier:)` (iOS 17) and its own
/// `HTTPCookieStorage` instance for native (URLSession) login cookies. Two
/// dashboards that share a parent domain (a.example.com / b.example.com with
/// Domain=.example.com cookies) therefore can never see each other's live
/// cookies — neither through WebKit nor through the suffix-matched
/// `HTTPCookieStorage.shared` reads this layer used before.
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
            ]
            // Present at all means Secure (HTTPCookie reads "FALSE" as set),
            // so a plain-http dashboard's cookie must leave the key out.
            if isSecure { properties[.secure] = "TRUE" }
            if let expiresDate { properties[.expires] = expiresDate }
            if isHTTPOnly { properties[.init("HttpOnly")] = "TRUE" }
            if let sameSitePolicy { properties[.sameSitePolicy] = sameSitePolicy }
            return HTTPCookie(properties: properties)
        }
    }

    static func restore(
        into cookieStore: WKHTTPCookieStore,
        dashboardID: UUID? = nil,
        shouldContinue: @MainActor () -> Bool = { true }
    ) async {
        await restore(mirroredCookies(dashboardID: dashboardID), into: cookieStore, shouldContinue: shouldContinue)
    }

    /// Puts `cookies` into WebKit's store only where it lacks them. WebKit's
    /// identified store persists on its own, and a session it holds may be
    /// newer than the copy saved here: an auth proxy (oauth2-proxy) refreshes
    /// its cookie every few minutes and rotates the identity provider's
    /// refresh token with it. Writing an older copy back on a cold launch
    /// would replay a spent refresh token, which the provider answers with
    /// invalid_grant and the proxy with a cleared session: signed out.
    ///
    /// `shouldContinue` is asked before each write, after the store read:
    /// a Sign Out that invalidates the bridge while the read is out has its
    /// clear scheduled behind it, and no saved cookie may go in after that.
    static func restore(
        _ cookies: [HTTPCookie],
        into cookieStore: WKHTTPCookieStore,
        shouldContinue: @MainActor () -> Bool = { true }
    ) async {
        guard !cookies.isEmpty else { return }
        var live: [String: HTTPCookie] = [:]
        for cookie in await cookieStore.allCookies() {
            live[cookieIdentity(cookie)] = cookie
        }
        let now = Date()
        for cookie in cookies where shouldRestore(cookie, over: live[cookieIdentity(cookie)], now: now) {
            guard shouldContinue() else { return }
            await cookieStore.setCookie(cookie)
        }
    }

    /// A saved cookie replaces WebKit's copy only when it lasts longer, and
    /// fills a gap only while it is unexpired. A cookie without an expiry (a
    /// session cookie) counts as lasting until the process ends.
    nonisolated static func shouldRestore(_ saved: HTTPCookie, over live: HTTPCookie?, now: Date = Date()) -> Bool {
        if let expires = saved.expiresDate, expires <= now { return false }
        guard let live else { return true }
        return (saved.expiresDate ?? .distantFuture) > (live.expiresDate ?? .distantFuture)
    }

    /// Name, canonical domain and path: what makes two cookies the same one.
    nonisolated static func cookieIdentity(_ cookie: HTTPCookie) -> String {
        [
            cookie.name,
            cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            cookie.path.isEmpty ? "/" : cookie.path,
        ].joined(separator: "\u{0}")
    }

    /// The dashboard's cookies as last mirrored to the Keychain. Readable
    /// with the phone locked, unlike the saved password.
    static func mirroredCookies(dashboardID: UUID?) -> [HTTPCookie] {
        // Dashboard-scoped mirror first (#148); the legacy global record is
        // only consulted when the caller has no dashboard identity (tests).
        let data: Data?
        if let dashboardID {
            data = KeychainHelper.loadDashboardCookies(dashboardID: dashboardID)
        } else {
            data = KeychainHelper.loadDashboardCookies()
        }
        guard let data,
              let saved = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return [] }
        return saved.compactMap(\.cookie)
    }

    /// The dashboard-owned WebKit session store. `WKWebsiteDataStore` caches
    /// instances per identifier, so every caller for one dashboard — bridge,
    /// sign-in WebView, cleanup — shares the same context, and no other
    /// dashboard can ever read it. A nil dashboard (legacy/test construction)
    /// falls back to the default store.
    static func webKitStore(for dashboardID: UUID?) -> WKWebsiteDataStore {
        guard let dashboardID else { return .default() }
        return WKWebsiteDataStore(forIdentifier: dashboardID)
    }

    /// Clears a dashboard's identified WebKit session entirely. Call from
    /// Sign Out / Remove Dashboard.
    ///
    /// `WKWebsiteDataStore.remove(forIdentifier:)` segfaults inside WebKit's
    /// run-loop dispatch on current simulator hosts, so the session is
    /// cleared by wiping the identified store's cookie store instead — the
    /// same stable primitive the origin-scoped cleanup uses. The store is
    /// exclusively this dashboard's, so a full wipe is the correct scope and
    /// no other dashboard's session can ever be touched.
    ///
    /// Sign Out and Remove schedule it with `scheduleWebKitSessionClear`, so
    /// a sign-in or bridge for the same dashboard waits for it first.
    static func clearWebKitSession(for dashboardID: UUID) async {
        removeNativeCookieStorage(for: dashboardID)
        let store = WKWebsiteDataStore(forIdentifier: dashboardID)
        let cookies = await store.httpCookieStore.allCookies()
        for cookie in cookies {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }

    private nonisolated(unsafe) static var nativeCookieStorages: [UUID: HTTPCookieStorage] = [:]
    private static let nativeCookieStorageLock = NSLock()

    /// Every mutation of `nativeCookieStorages` goes through the lock: the
    /// jar factory runs `nonisolated` (native login commits can arrive from
    /// any executor), so cleanup from the MainActor must take the same lock.
    private nonisolated static func removeNativeCookieStorage(for dashboardID: UUID) {
        nativeCookieStorageLock.lock()
        defer { nativeCookieStorageLock.unlock() }
        nativeCookieStorages.removeValue(forKey: dashboardID)
    }

    /// The dashboard-owned native cookie jar for URLSession-based password
    /// logins. Instances created here are never persisted to disk and are
    /// never shared between dashboards; the durable record for this state is
    /// the dashboard's scoped Keychain mirror. A nil dashboard (legacy/test
    /// construction) falls back to the shared jar. Thread-safe by lock, so
    /// both the MainActor bridge path and the nonisolated cleanup path can
    /// use it.
    nonisolated static func nativeCookieStorage(for dashboardID: UUID?) -> HTTPCookieStorage {
        guard let dashboardID else { return .shared }
        nativeCookieStorageLock.lock()
        defer { nativeCookieStorageLock.unlock() }
        if let storage = nativeCookieStorages[dashboardID] { return storage }
        // A bare HTTPCookieStorage() does not retain cookies on every OS
        // version; the ephemeral configuration's private storage is the
        // supported way to hold an independent in-memory jar. It is never
        // persisted and never shared with another dashboard (or with
        // URLSession.shared).
        let configuration = URLSessionConfiguration.ephemeral
        let storage = configuration.httpCookieStorage ?? HTTPCookieStorage()
        nativeCookieStorages[dashboardID] = storage
        return storage
    }

    /// URLSession and WebKit maintain separate cookie stores. Copy the
    /// dashboard's OWN native password-login session into WebKit before the
    /// bridge loads its first dashboard request, keeping the existing
    /// dashboard API path authenticated. Only the dashboard's owned jar is
    /// consulted — never `HTTPCookieStorage.shared` — so another dashboard's
    /// parent-domain cookies cannot be imported here.
    static func restoreNativeCookies(
        into cookieStore: WKHTTPCookieStore,
        for baseURL: String,
        dashboardID: UUID? = nil,
        shouldContinue: @MainActor () -> Bool = { true }
    ) async {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return }
        let cookies = nativeCookieStorage(for: dashboardID).cookies ?? []
        await restore(cookies.filter { cookieMatchesHost($0, host: host) }, into: cookieStore, shouldContinue: shouldContinue)
    }

    static func capture(
        from cookieStore: WKHTTPCookieStore,
        for url: URL?,
        shouldPersist: (() -> Bool)? = nil,
        dashboardID: UUID
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
        KeychainHelper.saveDashboardCookies(data, dashboardID: dashboardID)
    }

    /// Removes dashboard-origin cookies from a WebKit cookie store. Disconnect
    /// must not leave a reusable HttpOnly session behind in the persistent
    /// default data store; clearing only the cookies whose domain is exactly
    /// the dashboard host keeps unrelated cookies intact, and leaves a
    /// parent-domain cookie shared with a sibling dashboard alone (#788).
    static func clear(from cookieStore: WKHTTPCookieStore, for url: URL?) async {
        guard let host = url?.host?.lowercased() else { return }
        for cookie in await cookieStore.allCookies() where cookieExactlyMatchesHost(cookie, host: host) {
            await cookieStore.deleteCookie(cookie)
        }
    }

    /// The store clears still running, keyed by the store they clear: a
    /// dashboard's identified store, or nil for the default store a legacy
    /// disconnect clears. WebKit answers over IPC, so a clear outlives the
    /// Sign Out or disconnect that started it; a bridge or sign-in page on
    /// the same store waits for it first (`awaitPendingStoreClear`), or the
    /// late clear could delete the new session's cookies (#788). That holds
    /// within the 10 s bound only: a clear whose WebKit reply takes longer
    /// is no longer waited for (and once a later clear of the store
    /// finishes, no longer recorded here), so its reply can still delete a
    /// session signed in after it. Sign-in not hanging on a WebKit reply
    /// that never comes is worth that rare risk.
    private static var pendingStoreClears: [UUID?: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private static var storeClearGeneration: UInt64 = 0

    /// Runs `clear` after any clear of the same store already running, and
    /// records it until it is done. The wait for the earlier clear is
    /// bounded like `awaitPendingStoreClear`: one WebKit reply that never
    /// comes must not stop every later clear of the store.
    static func scheduleStoreClear(
        for dashboardID: UUID?,
        predecessorTimeout: Duration = .seconds(10),
        _ clear: @escaping @MainActor () async -> Void
    ) {
        storeClearGeneration &+= 1
        let generation = storeClearGeneration
        let previous = pendingStoreClears[dashboardID]?.task
        let task = Task { @MainActor in
            if let previous { await awaitClear(previous, timeout: predecessorTimeout) }
            await clear()
            if pendingStoreClears[dashboardID]?.generation == generation {
                pendingStoreClears[dashboardID] = nil
            }
        }
        pendingStoreClears[dashboardID] = (generation, task)
    }

    /// Clears the dashboard's cookies from the default WebKit store, after any
    /// clear already running.
    static func clearDefaultStore(for url: URL) {
        scheduleStoreClear(for: nil) {
            await clear(from: WKWebsiteDataStore.default().httpCookieStore, for: url)
        }
    }

    /// Clears a dashboard's identified WebKit session, after any clear of it
    /// already running. Sign Out and Remove use this, not a detached
    /// `clearWebKitSession`, so signing in to the same dashboard again
    /// cannot have its new session deleted by the old one's clear.
    static func scheduleWebKitSessionClear(for dashboardID: UUID) {
        scheduleStoreClear(for: dashboardID) {
            await clearWebKitSession(for: dashboardID)
        }
    }

    static func hasPendingStoreClear(for dashboardID: UUID?) -> Bool {
        pendingStoreClears[dashboardID] != nil
    }

    static var hasPendingDefaultStoreClear: Bool { hasPendingStoreClear(for: nil) }

    /// Waits for a running clear of the store `dashboardID` uses (the
    /// default store for nil). Bounded: a WebKit reply that never comes must
    /// not hold the next sign-in forever.
    static func awaitPendingStoreClear(for dashboardID: UUID?, timeout: Duration = .seconds(10)) async {
        guard let task = pendingStoreClears[dashboardID]?.task else { return }
        await awaitClear(task, timeout: timeout)
    }

    static func awaitPendingDefaultStoreClear(timeout: Duration = .seconds(10)) async {
        await awaitPendingStoreClear(for: nil, timeout: timeout)
    }

    /// Waits for `task` or `timeout`, whichever comes first. Neither waiter
    /// is a structured child: a task group would join the clear's waiter,
    /// which cancellation cannot stop, and so wait for WebKit anyway.
    static func awaitClear(_ task: Task<Void, Never>, timeout: Duration) async {
        final class Once { var resumed = false }
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @MainActor () -> Void = {
                guard !once.resumed else { return }
                once.resumed = true
                continuation.resume()
            }
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish()
            }
            Task { @MainActor in
                await task.value
                deadline.cancel()
                finish()
            }
        }
    }

    /// Removes the dashboard's ENTIRE owned native cookie jar (sign-out /
    /// removal), and — for residue the dashboard era may have left in the
    /// shared jar — deletes only cookies whose canonical domain EXACTLY
    /// matches the dashboard host. Parent-domain cookies (Domain=.example.com
    /// shared with a sibling dashboard) never exact-match, so cleaning one
    /// dashboard can never retire a sibling's shared-domain cookie.
    /// `HTTPCookieStorage` is thread-safe, so this stays `nonisolated` to
    /// remain callable from any context (including tests).
    nonisolated static func clearNativeCookies(dashboardID: UUID, baseURL: String) {
        let jar = nativeCookieStorage(for: dashboardID)
        for cookie in jar.cookies ?? [] {
            jar.deleteCookie(cookie)
        }
        clearSharedJarCookies(for: baseURL)
    }

    /// Cleanup for callers without a dashboard identity (pre-#148 shapes and
    /// tests): the same exact-host rule as the registered path, so a
    /// parent-domain cookie shared with a sibling survives (#788).
    nonisolated static func clearNativeCookies(for baseURL: String) {
        clearSharedJarCookies(for: baseURL)
    }

    nonisolated private static func clearSharedJarCookies(for baseURL: String) {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookieExactlyMatchesHost(cookie, host: host) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    /// Clearing matches the canonical domain exactly: a parent-domain cookie
    /// (Domain=.example.com) is shared with every sibling under it, so it
    /// never belongs to one dashboard alone.
    nonisolated private static func cookieExactlyMatchesHost(_ cookie: HTTPCookie, host: String) -> Bool {
        cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
    }


    /// Which cookies apply to `host` (its own and its parent domains'): for
    /// reading only. Clearing uses `cookieExactlyMatchesHost`.
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
    /// The old dashboard accepted the request, but the answer landed after a
    /// dashboard switch: it is not applied to the dashboard now showing.
    /// Only what the phone keeps for the old dashboard may follow it.
    case answeredAfterSwitch

    var errorDescription: String? {
        switch self {
        case .notReady, .answeredAfterSwitch:
            return AppLocalization.string("Conduit is still connecting to your dashboard. Try again in a moment.")
        case .signInRequired:
            return AppLocalization.string("Dashboard sign-in has expired. Sign in again to continue.")
        case .requestFailed(let message):
            return message
        case .http(let status, let detail):
            return Self.describe(status: status, detail: detail)
        case .oversizedResponse:
            // Generic bridge-level copy: this error is raised for ANY
            // dashboard response that exceeds the safe bound (workspace-file
            // reads, catalogs, history), not exclusively transcripts.
            // Transcript-specific messaging is mapped in the transcript
            // layer, which knows whether the request was a legacy one-shot
            // or a bounded current-Hermes page.
            return AppLocalization.string("This response is too large to load safely.")
        }
    }

    /// The dashboard answered but handed back no session ticket.
    static var noSessionTicketDetail: String {
        AppLocalization.string("The dashboard didn't let Conduit start a session. Try again.")
    }

    /// Conduit's own 401 after it refreshed the sign-in for a request it
    /// won't replay: the fix is to try again, not to sign in.
    static var signInRefreshedDetail: String {
        AppLocalization.string("Your dashboard sign-in was refreshed. Try that again.")
    }

    /// What a failed dashboard request means for the person using Conduit.
    /// The server's own explanation is kept when it says something (a
    /// FastAPI `detail` like "Session not found"); bare status phrases and
    /// browser fetch errors become what happened and what to do.
    static func describe(status: Int, detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMeaningful = !trimmed.isEmpty
            && !genericDetails.contains(trimmed.lowercased())
            && trimmed != AppLocalization.string("Dashboard request failed (\(String(status))).")
        switch status {
        case 0:
            let lowered = trimmed.lowercased()
            if lowered.contains("abort") || lowered.contains("timeout") || lowered.contains("timed out") {
                return HermesError.timeoutMessage
            }
            return AppLocalization.string("Conduit couldn't reach your Hermes dashboard. Check this device's network connection and that the dashboard is running.")
        case 403 where trimmed.range(of: "profile_mismatch", options: .caseInsensitive) != nil:
            return AppLocalization.string("Hermes says this chat belongs to another profile. Switch to that profile, then try again.")
        case 403 where SessionMutationIdentity.isRefusalDetail(trimmed):
            return AppLocalization.string("Hermes only lets the computer it runs on change this older chat. Change it there instead.")
        case 403 where isMeaningful:
            // Hermes' own refusal to someone signed in (a sensitive path, a
            // file it can't write): its reason says what to do.
            return trimmed
        case 401, 403:
            if trimmed == signInRefreshedDetail { return trimmed }
            return AppLocalization.string("Hermes turned this down because the dashboard sign-in expired or doesn't allow it. Sign in again, then try once more.")
        case 404, 405, 501:
            if isMeaningful, status == 404 { return trimmed }
            return AppLocalization.string("Your Hermes server doesn't support this yet. Update Hermes, then try again.")
        case 408, 504, 524:
            return HermesError.timeoutMessage
        case 409 where (SessionMutationIdentity.retryableConflicts + ["session_busy"]).contains(where: { trimmed.localizedCaseInsensitiveContains($0) }):
            // A session write that still conflicted after its one retry.
            return AppLocalization.string("Hermes is busy right now. Wait a moment, then try again.")
        case 429:
            if isMeaningful { return trimmed }
            return AppLocalization.string("Hermes is busy right now. Wait a moment, then try again.")
        case 502, 503, 520...523:
            return AppLocalization.string("Your dashboard couldn't reach Hermes. Hermes may be restarting, so try again in a moment.")
        case 500...599:
            if isMeaningful {
                return AppLocalization.string("Hermes ran into a problem: \(trimmed). Check the Hermes logs, then try again.")
            }
            return AppLocalization.string("Hermes ran into a problem on the server. Check the Hermes logs, then try again.")
        default:
            if isMeaningful { return trimmed }
            return AppLocalization.string("Hermes didn't accept this request. Updating Hermes and Conduit usually fixes this.")
        }
    }

    /// Whether a dashboard request's failure means its sign-in is gone.
    /// Hermes turns a signed-out request away with 401. Its 403 refuses
    /// someone signed in (a sensitive path, a file it can't write, a chat
    /// this sign-in may not change) and gives the reason as a JSON `detail`:
    /// signing in again can't change that. An auth proxy in front of Hermes
    /// answers 403 with its own page and no such reason, which still does.
    static func meansSignIn(status: Int, hermesDetail: String?) -> Bool {
        status == 401 || (status == 403 && hermesDetail == nil)
    }

    /// Default HTTP reason phrases and browser fetch errors, which say
    /// nothing a person can act on.
    private static let genericDetails: Set<String> = [
        "not found", "method not allowed", "bad request", "internal server error",
        "internal error", "service unavailable", "bad gateway", "gateway timeout",
        "request timeout", "too many requests", "forbidden", "unauthorized",
        "failed to fetch", "load failed", "typeerror: load failed",
        "typeerror: failed to fetch", "networkerror when attempting to fetch resource.",
    ]
}

/// The isolated JavaScript world that holds the dashboard's proxy headers
/// (the Cloudflare Access service token and any custom headers) and every
/// script Conduit itself runs in a dashboard WebView. The dashboard page's
/// own scripts run in the page world, which shares the DOM but not
/// JavaScript globals with this one: they can't read the header values,
/// re-wrap the `fetch` that attaches them, or post to Conduit's message
/// handlers. The page's own requests carry the session cookies the first
/// native, header-bearing navigation earned, as its scripts and styles
/// always did.
@MainActor
enum DashboardScriptWorld {
    static let world = WKContentWorld.world(name: "ConduitDashboard")

    /// Adds the header-attaching document-start scripts for this dashboard
    /// to the isolated world. Cleartext dashboards get none.
    static func installProxyHeaderScripts(
        into controller: WKUserContentController,
        cloudflareAccess: CloudflareAccessCredentials?,
        normalizedBaseURL: String,
        headerStore: CustomHeaderStore = .shared
    ) {
        let scripts = [
            cloudflareAccess?.fetchInjectionUserScript(expectedBaseURL: normalizedBaseURL) ?? "",
            headerStore.fetchInjectionUserScript(expectedBaseURL: normalizedBaseURL),
        ]
        for script in scripts where !script.isEmpty {
            controller.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
            )
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

    func rejectAll(with error: Error, except kept: Set<Int> = []) {
        let pending = storage.filter { !kept.contains($0.key) }
        storage = storage.filter { kept.contains($0.key) }
        pending.values.forEach { $0.resume(throwing: error) }
    }
}

/// Re-mirrors a dashboard's cookies whenever WebKit's store changes, so the
/// Keychain copy a cold launch restores is the session's latest one. An auth
/// proxy refreshes its cookie on ordinary requests long after the page load
/// that used to be the only capture.
@MainActor
final class DashboardCookieMirrorObserver: NSObject, WKHTTPCookieStoreObserver {
    private weak var bridge: DashboardTicketBridge?
    private var pending: Task<Void, Never>?

    init(bridge: DashboardTicketBridge) {
        self.bridge = bridge
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        // A refresh can touch several cookies at once: mirror once, after
        // the burst.
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            await self?.bridge?.mirrorCookies()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

@MainActor
final class DashboardTicketBridge: NSObject {
    let baseURL: String
    let webView: WKWebView
    let cloudflareAccess: CloudflareAccessCredentials?
    /// The extra proxy headers baked into this bridge's page script at
    /// construction. AppState rebuilds the bridge when the saved set changes.
    let extraHeaders: [CustomHeader]
    /// The saved dashboard this bridge authenticates against, when one
    /// exists — decides which dashboard's scoped cookie mirror is restored
    /// into the WebKit store on load.
    let dashboardID: UUID?
    /// What authorizes this dashboard's requests: in native mode it holds
    /// the bearer-backed session for Hermes' native PKCE flow, and every
    /// dashboard WebSocket upgrade is authorized through it. The bridge
    /// keeps one interface for callers while cookie/password mode stays
    /// intact.
    let requestAuthorizer: DashboardRequestAuthorizer
    /// Read-only outside the bridge (file downloads sign with it too).
    var nativeOAuthSession: NativeOAuthSession? { requestAuthorizer.nativeSession }
    /// AppState includes the authentication transport in its bridge-reuse
    /// identity. A same-URL login that changes cookie ↔ bearer mode must
    /// replace this bridge rather than retaining its in-memory session.
    var usesNativeOAuth: Bool { nativeOAuthSession != nil }

    /// A same-mode bridge is reusable only while its live grant still matches
    /// storage. Internal refresh updates the live grant as well as storage;
    /// when that save fails, the Keychain copy it couldn't overwrite still
    /// counts as matching, so the bridge keeps the rotated live grant rather
    /// than being rebuilt from the retired one.
    func matchesNativeOAuthTokens(_ tokens: NativeOAuthTokenSet?) -> Bool {
        guard let tokens else { return nativeOAuthSession == nil }
        return nativeOAuthSession?.matchesStoredTokens(tokens) == true
    }


    /// Whether the dashboard page is loaded and can run requests.
    /// Readable for tests; written only by the bridge.
    private(set) var isReady = false
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
    /// Whether the dashboard page settled on sign-in: Hermes' /login, an
    /// auth proxy's sign-in page, or a redirect off the dashboard's origin
    /// (the proxy's sign-in host, the identity provider). Requests answer
    /// `.signInRequired` until a reload finds a session.
    var requiresSignIn: Bool { didLandOnLogin && !isInvalidated }
    /// Main-frame navigations the bridge stopped because they went to
    /// sign-in. Diagnostic/test counter: each is one redirect the hidden
    /// page did not follow.
    private(set) var cancelledSignInNavigationCount = 0
    /// Test-only landing state, re-asserted by every page load so tests can
    /// model a dashboard that keeps producing the same landing regardless of
    /// when WKWebView's nondeterministic callbacks arrive.
    private var simulatedLanding: SimulatedLanding?

    enum SimulatedLanding {
        case ready
        case loginPage
        case loadFailure
    }
    private(set) var isInvalidated = false
    private var cookieMirrorObserver: DashboardCookieMirrorObserver?
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
    /// Page requests that change something on the dashboard. A switch
    /// leaves them waiting for their answer (or deadline), so the caller
    /// learns whether the old dashboard accepted the change.
    private var pendingWriteIDs: Set<Int> = []
    private let readinessPollAttempts: Int
    private let readinessPollInterval: Duration
    /// Number of times `reload()` re-attempted the dashboard page load, from
    /// any caller (mint retries and AppState's sign-in recovery alike).
    /// Diagnostic/test counter for the cold-bridge recovery path.
    private(set) var reloadCount = 0
    /// Whether the hidden dashboard page can run requests. WebKit suspends
    /// a page whose window is off screen, so while the phone app is in the
    /// background (driving with CarPlay, a locked phone) requests go out
    /// natively with the page's cookies instead (#378). Test seam.
    var webViewCanRun: @MainActor () -> Bool = { PhoneScenePresence.isInForeground }
    /// Cookies the dashboard set on requests sent without the page, newest
    /// last, so a rotated session cookie is the one sent next.
    var backgroundIssuedCookies: [HTTPCookie] = []
    /// Sends a request without the page in place of URLSession. Test seam.
    var loadWithoutPageForTesting: (@MainActor (URLRequest) async throws -> (Data, URLResponse))?
    /// Observes the hidden page's load lifecycle for AppState's connection
    /// timeline (#417). Every request waits on this page, so when it becomes
    /// ready is the first thing a slow launch needs to show.
    var onPageEvent: (@MainActor (String) -> Void)?

    init(
        baseURL: String,
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        dashboardID: UUID? = nil,
        requestAuthorizer: DashboardRequestAuthorizer? = nil,
        pendingRequests: DashboardTicketBridgePendingRequests = DashboardTicketBridgePendingRequests(),
        readinessPollAttempts: Int = 30,
        readinessPollInterval: Duration = .milliseconds(100),
        requestDeadlineGraceMilliseconds: Int = 3_000
    ) {
        let normalizedBaseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? ""
        self.baseURL = normalizedBaseURL
        self.cloudflareAccess = cloudflareAccess
        self.extraHeaders = CustomHeaderPolicy.sendable(CustomHeaderStore.shared.headers(forServerURL: normalizedBaseURL))
        let resolvedDashboardID = dashboardID ?? SavedDashboardRegistryStore.load()?.dashboardID(atNormalizedURL: normalizedBaseURL)
        self.dashboardID = resolvedDashboardID
        // AppState builds the authorizer with the other saved dashboards in
        // view; one built for another address, dashboard or token is never
        // adopted.
        if let requestAuthorizer,
           !requestAuthorizer.isInvalidated,
           requestAuthorizer.baseURL == normalizedBaseURL,
           requestAuthorizer.dashboardID == resolvedDashboardID,
           requestAuthorizer.cloudflareAccess == cloudflareAccess {
            self.requestAuthorizer = requestAuthorizer
        } else {
            self.requestAuthorizer = .forDashboard(
                baseURL: normalizedBaseURL,
                dashboardID: resolvedDashboardID,
                cloudflareAccess: cloudflareAccess
            )
        }
        self.pendingRequests = pendingRequests
        // A negative count would build an invalid Range in the polling loops.
        self.readinessPollAttempts = max(0, readinessPollAttempts)
        self.readinessPollInterval = readinessPollInterval
        self.requestDeadlineGraceMilliseconds = max(0, requestDeadlineGraceMilliseconds)
        let configuration = WKWebViewConfiguration()
        // The bridge lives inside the dashboard's OWN WebKit session store:
        // another dashboard's WebView (or the default store) can never read
        // these cookies, and sibling-host parent-domain cookies cannot leak
        // in. Nil dashboards (legacy/test construction) keep the default
        // store.
        configuration.websiteDataStore = DashboardCookiePersistence.webKitStore(for: self.dashboardID)
        DashboardScriptWorld.installProxyHeaderScripts(
            into: configuration.userContentController,
            cloudflareAccess: cloudflareAccess,
            normalizedBaseURL: normalizedBaseURL
        )
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(
            WeakScriptMessageHandler(self),
            contentWorld: DashboardScriptWorld.world,
            name: "dashboard-response"
        )
        webView.navigationDelegate = self
        self.requestAuthorizer.cookieTicketMinter = { [weak self] in
            guard let self else { throw DashboardTicketBridgeError.notReady }
            return try await self.mintCookieTicket()
        }
        self.requestAuthorizer.cookieUpgradeCookies = { [weak self] in
            await self?.cookiesForRequestsWithoutPage() ?? []
        }
        if nativeOAuthSession == nil, self.dashboardID != nil {
            let observer = DashboardCookieMirrorObserver(bridge: self)
            webView.configuration.websiteDataStore.httpCookieStore.add(observer)
            cookieMirrorObserver = observer
        }
        if nativeOAuthSession != nil {
            isReady = true
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The Sign Out or disconnect before this bridge may still be
            // clearing its store (#788).
            await DashboardCookiePersistence.awaitPendingStoreClear(for: self.dashboardID)
            // Invalidated meanwhile (a Sign Out clearing this store): no
            // cookies go back in.
            guard !self.isInvalidated else { return }
            // Each write checks again: an invalidation while a restore's
            // store read is out must not see the cookie written back.
            await DashboardCookiePersistence.restore(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                dashboardID: self.dashboardID,
                shouldContinue: { [weak self] in self?.isInvalidated == false }
            )
            await DashboardCookiePersistence.restoreNativeCookies(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                for: self.baseURL,
                dashboardID: self.dashboardID,
                shouldContinue: { [weak self] in self?.isInvalidated == false }
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
        // The bridge registers exactly one handler; removing them all keeps
        // this nonisolated deinit off the main-actor `DashboardScriptWorld`.
        // WebKit is main-thread only, and the last release that runs this
        // deinit can come from any thread: off the main thread, the removal
        // waits for it.
        let webView = webView
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                webView.configuration.userContentController.removeAllScriptMessageHandlers()
            }
        } else {
            Task { @MainActor in
                webView.configuration.userContentController.removeAllScriptMessageHandlers()
            }
        }
    }

    /// Saves the dashboard's current WebKit cookies as its Keychain mirror.
    /// Never after invalidation: a disconnect that cleared the mirror must
    /// not see it written back.
    func mirrorCookies() async {
        guard !isInvalidated, let dashboardID, let url = URL(string: baseURL) else { return }
        await DashboardCookiePersistence.capture(
            from: webView.configuration.websiteDataStore.httpCookieStore,
            for: url,
            shouldPersist: { [weak self] in
                guard let self else { return false }
                return !self.isInvalidated
            },
            dashboardID: dashboardID
        )
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        isReady = false
        requestAuthorizer.invalidate()
        if let cookieMirrorObserver {
            cookieMirrorObserver.cancel()
            webView.configuration.websiteDataStore.httpCookieStore.remove(cookieMirrorObserver)
            self.cookieMirrorObserver = nil
        }
        // A torn-down bridge must report plain unreadiness: leaving a stale
        // login verdict would surface .signInRequired (with its session
        // recovery) from an invalidated instance.
        didLandOnLogin = false
        rejectPending(with: DashboardTicketBridgeError.notReady, keepingWrites: true)
    }

    func reload() {
        guard !isInvalidated else { return }
        if nativeOAuthSession != nil {
            isReady = true
            isLoadFailed = false
            didLandOnLogin = false
            return
        }
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
            // The Sign Out or disconnect before this bridge may still be
            // clearing its store (#788).
            await DashboardCookiePersistence.awaitPendingStoreClear(for: self.dashboardID)
            // Invalidated meanwhile (a Sign Out clearing this store): no
            // cookies go back in.
            guard !self.isInvalidated else { return }
            // Each write checks again: an invalidation while a restore's
            // store read is out must not see the cookie written back.
            await DashboardCookiePersistence.restore(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                dashboardID: self.dashboardID,
                shouldContinue: { [weak self] in self?.isInvalidated == false }
            )
            await DashboardCookiePersistence.restoreNativeCookies(
                into: self.webView.configuration.websiteDataStore.httpCookieStore,
                for: self.baseURL,
                dashboardID: self.dashboardID,
                shouldContinue: { [weak self] in self?.isInvalidated == false }
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

    /// A fresh single-use WebSocket ticket. In native mode the authorizer
    /// mints it with the access token and remembers which bearer must go
    /// with it on the upgrade.
    func mintTicket() async throws -> String {
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        return try await requestAuthorizer.mintTicket()
    }

    /// Cookie mode's ticket: through the dashboard page, or natively with the
    /// page's cookies while the page cannot run.
    private func mintCookieTicket() async throws -> String {
        if !webViewCanRun() {
            let response = try await requestJSONWithoutPage(path: "/api/auth/ws-ticket", method: "POST")
            guard let ticket = response["ticket"] as? String, !ticket.isEmpty else {
                throw DashboardTicketBridgeError.requestFailed(DashboardTicketBridgeError.noSessionTicketDetail)
            }
            return ticket
        }
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
                    throw DashboardTicketBridgeError.requestFailed(DashboardTicketBridgeError.noSessionTicketDetail)
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
    /// Error contract: unusable page states (a failed or URL-less landing,
    /// a stalled engine) surface as `.notReady` so callers flow into the
    /// reload recovery; a sign-in landing or redirect (Hermes' /login, an
    /// auth proxy's sign-in page, any other origin), of the page or of the
    /// request itself, surfaces as `.signInRequired`. Direct callers should
    /// not expect `.requestFailed` for these states.
    func requestJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        if let nativeOAuthSession {
            guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
            return try await nativeOAuthSession.requestJSON(
                path: path,
                method: method,
                body: body,
                timeoutMilliseconds: timeoutMilliseconds,
                maxResponseBytes: maxResponseBytes
            )
        }
        if !webViewCanRun() {
            return try await requestJSONWithoutPage(
                path: path,
                method: method,
                body: body,
                timeoutMilliseconds: timeoutMilliseconds,
                maxResponseBytes: maxResponseBytes
            )
        }
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
        if method.uppercased() != "GET" { pendingWriteIDs.insert(id) }
        defer { pendingWriteIDs.remove(id) }

        let response: [String: Any]
        do {
            response = try await withTaskCancellationHandler(operation: {
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
                        let redirectedTo = null;
                        try {
                            const requestBody = \(bodyLiteral);
                            const controller = new AbortController();
                            const timeout = setTimeout(() => controller.abort(), \(timeout));
                            const send = (options) => fetch(\(pathLiteral), Object.assign({
                                method: \(methodLiteral),
                                credentials: 'include',
                                headers: requestBody === null
                                    ? { Accept: 'application/json' }
                                    : { Accept: 'application/json', 'Content-Type': 'application/json' },
                                body: requestBody === null ? undefined : JSON.stringify(requestBody),
                                signal: controller.signal
                            }, options));
                            // Redirects are followed only within the dashboard's
                            // origin: the browser refuses a hop to another origin
                            // (an auth proxy's sign-in host) before sending
                            // anything there, and fails it like a network error.
                            // So a failure is probed once, side-effect free (GET,
                            // no body, redirect not followed): an opaque redirect
                            // means the request was sent off the dashboard, which
                            // is sign-in. Anything else keeps the first error.
                            let response;
                            try {
                                response = await send({ redirect: 'follow', mode: 'same-origin' });
                            } catch (error) {
                                if (controller.signal.aborted) throw error;
                                let probe = null;
                                try {
                                    probe = await send({
                                        method: 'GET', body: undefined,
                                        headers: { Accept: 'application/json' },
                                        redirect: 'manual', cache: 'no-store'
                                    });
                                } catch (_) {}
                                if (!probe || probe.type !== 'opaqueredirect') throw error;
                                clearTimeout(timeout);
                                window.webkit.messageHandlers['dashboard-response'].postMessage(JSON.stringify({
                                    type: 'dashboard-response', id: \(id), ok: false, status: 0,
                                    signInRedirect: true, error: String(error)
                                }));
                                return;
                            }
                            if (response.redirected) redirectedTo = response.url;
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
                                status: response.status, body: normalizedBody, redirectedTo: redirectedTo,
                                error: !response.ok && body && typeof body === 'object'
                                    ? (body.error || body.message || body.detail) : null
                            }));
                        } catch (error) {
                            window.webkit.messageHandlers['dashboard-response'].postMessage(JSON.stringify({
                                type: 'dashboard-response', id: \(id), ok: false, status: 0,
                                redirectedTo: redirectedTo, error: String(error)
                            }));
                        }
                    })();
                    true;
                    """
                    // Runs in the isolated world, where the header scripts
                    // attach the proxy headers to this fetch.
                    webView.evaluateJavaScript(script, in: nil, in: DashboardScriptWorld.world) { [weak self] result in
                        guard let self else { return }
                        guard case .failure = result else { return }
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
        } catch where isInvalidated && !(error is CancellationError) {
            // A write's failure (or deadline) after a switch: nothing the old
            // dashboard did reaches the dashboard now showing.
            throw DashboardTicketBridgeError.notReady
        }
        // An answer already on its way when the bridge was invalidated (a
        // dashboard switch) is the old dashboard's: its caller would apply
        // it to the dashboard now showing. The request only returns when
        // the dashboard accepted it.
        guard !isInvalidated else { throw DashboardTicketBridgeError.answeredAfterSwitch }
        return response
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
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("Could not encode dashboard request."))
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
        guard nativeOAuthSession == nil else {
            isReady = !isInvalidated
            return
        }
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)/api/status") else { return }
        var request = URLRequest(url: url)
        request = request.applyingProxyHeaders(cloudflare: cloudflareAccess)
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
        onPageEvent?("Dashboard page loading")
    }

    private func rejectPending(with error: Error, keepingWrites: Bool = false) {
        let kept = keepingWrites ? pendingWriteIDs : []
        for (id, deadline) in requestDeadlines where !kept.contains(id) {
            deadline.cancel()
            requestDeadlines.removeValue(forKey: id)
        }
        pendingRequests.rejectAll(with: error, except: kept)
    }
}

extension DashboardTicketBridge: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
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
        decisionHandler(mainFrameNavigationPolicy(for: navigationAction.request.url))
    }

    /// The hidden page's decision for a main-frame navigation (a load, or a
    /// redirect the load received). The page only ever loads the dashboard,
    /// so a navigation to sign-in (another origin, or a sign-in page on this
    /// one) is the dashboard saying the session is gone: it is cancelled
    /// rather than followed, so the page never walks the auth proxy's
    /// redirect chain, and the bridge settles on sign-in required, as a
    /// landing on /login does. Internal so tests can drive it: WKWebView's
    /// navigation callbacks are not deterministic in the unit test host.
    func mainFrameNavigationPolicy(for url: URL?) -> WKNavigationActionPolicy {
        guard let expectedURL = URL(string: baseURL) else { return .cancel }
        if DashboardSignInRedirect.isSignIn(url, forDashboard: expectedURL) {
            cancelledSignInNavigationCount += 1
            settleOnSignIn(event: "Dashboard page redirected to sign-in")
            return .cancel
        }
        guard ConnectionURLPolicy.isAllowedTransport(url),
              ConnectionURLPolicy.originMatches(url, expected: expectedURL) else {
            return .cancel
        }
        return .allow
    }

    /// The page reached (or was sent to) sign-in: nothing it loads can mint
    /// a ticket until a reload finds a session. An invalidated bridge keeps
    /// reporting plain unreadiness.
    private func settleOnSignIn(event: String) {
        guard !isInvalidated else { return }
        isReady = false
        isLoadFailed = false
        didLandOnLogin = true
        onPageEvent?(event)
        rejectPending(with: DashboardTicketBridgeError.signInRequired)
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
        guard let expectedURL = URL(string: baseURL),
              processLanding(at: webView.url) else { return }
        if !isInvalidated {
            // Late cookie capture after disconnect must not resurrect the
            // durable mirror AppState just cleared: the write guard runs at
            // the moment of the keychain save, after the cookie-store await.
            // The mirror is dashboard-owned: without a dashboard identity
            // there is no record to write.
            if let dashboardID = self.dashboardID {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await DashboardCookiePersistence.capture(
                        from: self.webView.configuration.websiteDataStore.httpCookieStore,
                        for: expectedURL,
                        shouldPersist: { [weak self] in
                            guard let self else { return false }
                            return !self.isInvalidated
                        },
                        dashboardID: dashboardID
                    )
                }
            }
        }
    }

    /// Applies where the dashboard page settled. Returns whether the page is
    /// ready (the dashboard itself, signed in). Internal so tests can drive
    /// it.
    ///  - No URL at all: unknown, not "signed out". Marked failed so the
    ///    next mint reloads.
    ///  - Another origin (the auth proxy's sign-in host, the identity
    ///    provider) or a sign-in page on the dashboard's origin (Hermes'
    ///    /login, a proxy's /oauth2/sign_in): the session is gone. Sign-in
    ///    is required, never a misleading gateway ticket or a network
    ///    failure the reconnect loop would retry forever.
    ///  - Any other page on the dashboard's origin: ready.
    @discardableResult
    func processLanding(at landedURL: URL?) -> Bool {
        guard let expectedURL = URL(string: baseURL), let landedURL else {
            isReady = false
            isLoadFailed = true
            rejectPending(with: DashboardTicketBridgeError.notReady)
            onPageEvent?("Dashboard page landed nowhere")
            return false
        }
        if DashboardSignInRedirect.isSignIn(landedURL, forDashboard: expectedURL) {
            settleOnSignIn(event: ConnectionURLPolicy.originMatches(landedURL, expected: expectedURL)
                ? "Dashboard page landed on sign-in"
                : "Dashboard page landed on another site's sign-in")
            return false
        }
        guard ConnectionURLPolicy.originMatches(landedURL, expected: expectedURL) else {
            // Another scheme (an error document): unusable, reloadable.
            isReady = false
            isLoadFailed = true
            rejectPending(with: DashboardTicketBridgeError.notReady)
            onPageEvent?("Dashboard page landed off the dashboard")
            return false
        }
        isLoadFailed = false
        didLandOnLogin = false
        isReady = true
        onPageEvent?("Dashboard page ready")
        return true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // A failure for a navigation a reload has already replaced (or that
        // finished) must not fail the fresh load; remove-on-match keeps the
        // stale set from retaining superseded navigations. A nil identity on
        // either side processes the callback — failures without navigation
        // context still carry real signal.
        if let navigation, staleNavigations.remove(navigation) != nil { return }
        if let currentNavigation, let navigation, navigation !== currentNavigation { return }
        // The load the bridge stopped on its way to sign-in reports that
        // cancellation as a failure: the verdict stays sign-in required.
        if didLandOnLogin { return }
        isReady = false
        isLoadFailed = true
        rejectPending(with: error)
        onPageEvent?("Dashboard page failed: \(ConnectionTimeline.summary(of: error))")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let navigation, staleNavigations.remove(navigation) != nil { return }
        if let currentNavigation, let navigation, navigation !== currentNavigation { return }
        // The load the bridge stopped on its way to sign-in reports that
        // cancellation as a failure: the verdict stays sign-in required.
        if didLandOnLogin { return }
        isReady = false
        isLoadFailed = true
        rejectPending(with: error)
        onPageEvent?("Dashboard page failed: \(ConnectionTimeline.summary(of: error))")
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
        onPageEvent?("Dashboard page process ended")
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

        // The request was redirected to sign-in: off the dashboard's origin
        // (the page refused to follow it and its probe saw the redirect), or
        // to a sign-in page on it, whatever that page answered. Sign-in is
        // required, as for requests sent without the page, never a network
        // failure the reconnect loop retries forever.
        if payload["signInRedirect"] as? Bool == true
            || DashboardSignInRedirect.isSignIn(
                (payload["redirectedTo"] as? String).flatMap(URL.init(string:)),
                forDashboard: expectedURL
            ) {
            continuation.resume(throwing: DashboardTicketBridgeError.signInRequired)
            return
        }

        if payload["ok"] as? Bool == true {
            continuation.resume(returning: payload["body"] as? [String: Any] ?? [:])
            return
        }

        let status = payload["status"] as? Int ?? 0
        let detail = payload["error"] as? String ?? AppLocalization.string("Dashboard request failed (\(String(status))).")
        // Hermes' own 403 (its `detail` says why, such as a chat this
        // sign-in may not change or a file it won't serve) is a verdict on
        // the request, not an expired sign-in: signing in again can't change
        // it.
        let hermesDetail = (payload["body"] as? [String: Any])?["detail"] as? String
        if DashboardTicketBridgeError.meansSignIn(status: status, hermesDetail: hermesDetail),
           !SessionMutationIdentity.isRefusalDetail(detail) {
            continuation.resume(throwing: DashboardTicketBridgeError.signInRequired)
            return
        }
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
