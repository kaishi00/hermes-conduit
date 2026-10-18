//
//  DashboardRequestAuthorizer.swift
//  Conduit
//
//  What makes a WebSocket upgrade one the SELECTED dashboard accepts, and
//  nothing else. Owned by the dashboard's `DashboardTicketBridge`; every
//  dashboard socket (chat, Kanban live events, the dashboard voice streams,
//  the Grok relay) is authorized here. Sockets to external voice providers
//  never are.
//
//  Cookie mode: the bridge mints tickets through its page, and the upgrade
//  carries the ticket, the proxy headers and the selected dashboard's own
//  session cookies, the ones its page would send to that address. A
//  dashboard behind an auth proxy (oauth2-proxy, a Cloudflare Access
//  sign-in) admits the upgrade only with the proxy's session cookie. The
//  cookies come from the dashboard's own stores, never a process-wide jar.
//
//  Native mode (a Hermes native sign-in): tickets are minted with the
//  grant, and the upgrade carries the ticket, the proxy headers and the
//  grant's bearer, no cookie. An auth edge that admits a native client by
//  its bearer checks it on the upgrade too, as on every REST request; a
//  dashboard that does not ask for it ignores it. The bearer goes only to
//  this dashboard's own address.
//

import Foundation

/// The upgrade-authorization surface `HermesClient` depends on, so tests can
/// drive it without a dashboard.
@MainActor
protocol DashboardUpgradeAuthorizing: AnyObject {
    /// A fresh single-use ticket for this dashboard.
    func mintTicket() async throws -> String
    /// `request`, ready for this dashboard: in cookie mode it carries the
    /// dashboard's session cookies for its address and no other Cookie
    /// header; in native mode, the grant's bearer for its address and no
    /// cookie. Proxy headers must already be on the request.
    func authorizeUpgrade(_ request: URLRequest) async throws -> URLRequest
}

@MainActor
final class DashboardRequestAuthorizer: DashboardUpgradeAuthorizing {
    /// The selected dashboard's normalized address: its origin and base path.
    let baseURL: String
    let dashboardID: UUID?
    let cloudflareAccess: CloudflareAccessCredentials?
    /// The native grant's session, nil in cookie mode and after invalidation.
    private(set) var nativeSession: NativeOAuthSession?
    /// Cookie mode's ticket source (the bridge's page, or the background
    /// request while the page cannot run). Set by the owning bridge.
    var cookieTicketMinter: (@MainActor () async throws -> String)?
    /// Cookie mode's session cookies (the bridge's WebKit store, Keychain
    /// mirror and native jar). Set by the owning bridge.
    var cookieUpgradeCookies: (@MainActor () async -> [HTTPCookie])?
    /// The other saved dashboards' addresses. A request under one of them
    /// is not this dashboard's, even on the same origin (`/` and `/team`).
    private let otherDashboardURLs: @MainActor () -> [String]
    private(set) var isInvalidated = false

    init(
        baseURL: String,
        dashboardID: UUID?,
        cloudflareAccess: CloudflareAccessCredentials?,
        nativeSession: NativeOAuthSession?,
        otherDashboardURLs: @escaping @MainActor () -> [String] = { [] }
    ) {
        self.baseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? ""
        self.dashboardID = dashboardID
        self.cloudflareAccess = cloudflareAccess
        self.nativeSession = nativeSession
        self.otherDashboardURLs = otherDashboardURLs
    }

    /// The authorizer for a saved dashboard: native mode when its Keychain
    /// holds a native grant, cookie mode otherwise.
    static func forDashboard(
        baseURL: String,
        dashboardID: UUID?,
        cloudflareAccess: CloudflareAccessCredentials?,
        otherDashboardURLs: @escaping @MainActor () -> [String] = { [] }
    ) -> DashboardRequestAuthorizer {
        let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? ""
        let session = dashboardID.flatMap {
            NativeOAuthSession(baseURL: normalized, dashboardID: $0, cloudflareAccess: cloudflareAccess)
        }
        return DashboardRequestAuthorizer(
            baseURL: normalized,
            dashboardID: dashboardID,
            cloudflareAccess: cloudflareAccess,
            nativeSession: session,
            otherDashboardURLs: otherDashboardURLs
        )
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        nativeSession?.invalidate()
        nativeSession = nil
        cookieTicketMinter = nil
        cookieUpgradeCookies = nil
    }

    // MARK: Tickets

    func mintTicket() async throws -> String {
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        if let nativeSession {
            let ticket = try await nativeSession.mintTicket()
            guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
            return ticket
        }
        guard let cookieTicketMinter else { throw DashboardTicketBridgeError.notReady }
        return try await cookieTicketMinter()
    }

    // MARK: Upgrades

    /// The ticket and proxy headers stay as they are, and no upgrade
    /// carries a cookie but these. In cookie mode the dashboard's session
    /// cookies that its page would send to this address are attached
    /// (replacing any Cookie header already there). In native mode the
    /// grant's access token is attached as `Authorization: Bearer`
    /// (refreshed first once expired) in place of any Authorization header
    /// already there. A request for another address gets neither.
    func authorizeUpgrade(_ request: URLRequest) async throws -> URLRequest {
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        var authorized = request
        authorized.setValue(nil, forHTTPHeaderField: "Cookie")
        guard let url = request.url, covers(url) else { return authorized }
        if let nativeSession {
            let bearer = try await nativeSession.upgradeBearer()
            guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
            authorized.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            return authorized
        }
        guard let cookieUpgradeCookies else { return authorized }
        let cookies = await cookieUpgradeCookies()
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        if let header = Self.cookieHeader(for: cookies, url: url) {
            authorized.setValue(header, forHTTPHeaderField: "Cookie")
        }
        return authorized
    }

    /// The Cookie header a browser would send with `url` (RFC 6265 5.4): a
    /// host-only cookie for exactly its host, a Domain cookie for that
    /// domain and its subdomains, a path match on segment boundaries, a
    /// Secure cookie only over https or wss, nothing expired. Longer paths
    /// first. Nil when none applies.
    nonisolated static func cookieHeader(for cookies: [HTTPCookie], url: URL, now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let scheme = url.scheme?.lowercased()
        let secure = scheme == "https" || scheme == "wss"
        let requestPath = url.path.isEmpty ? "/" : url.path
        let applicable = cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && !secure { return false }
            let domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") {
                let bare = String(domain.dropFirst())
                guard !bare.isEmpty, host == bare || host.hasSuffix(domain) else { return false }
            } else {
                guard host == domain else { return false }
            }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            guard requestPath.hasPrefix(cookiePath) else { return false }
            if requestPath.count == cookiePath.count || cookiePath.hasSuffix("/") { return true }
            let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
            return requestPath[boundary] == "/"
        }.sorted { $0.path.count > $1.path.count }
        guard !applicable.isEmpty else { return nil }
        return applicable.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// A not-yet-resumed task for an authorized upgrade, on the cookie-less,
    /// redirect-refusing dashboard socket session.
    func webSocketTask(with request: URLRequest) -> URLSessionWebSocketTask {
        DashboardWebSocketSession.shared.webSocketTask(with: request)
    }

    // MARK: Origin gate

    /// Whether `url` addresses this dashboard: its origin (`ws`/`wss`
    /// compared as `http`/`https`), a path under its base path, and not a
    /// path under a longer base path another saved dashboard owns.
    func covers(_ url: URL?) -> Bool {
        guard let url, let target = Location(url: url),
              let base = Location(url: URL(string: baseURL)) else { return false }
        guard target.origin == base.origin, target.path.isWithin(base.path) else { return false }
        for other in otherDashboardURLs() {
            let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(other)) ?? other
            guard let sibling = Location(url: URL(string: normalized)),
                  sibling.origin == base.origin,
                  sibling.path.count > base.path.count,
                  target.path.isWithin(sibling.path) else { continue }
            return false
        }
        return true
    }

    private struct Location {
        let origin: String
        let path: String

        init?(url: URL?) {
            guard let url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.user == nil, components.password == nil,
                  let rawScheme = components.scheme?.lowercased(),
                  let host = components.host?.lowercased(), !host.isEmpty else { return nil }
            let scheme: String
            switch rawScheme {
            case "https", "wss": scheme = "https"
            case "http", "ws": scheme = "http"
            default: return nil
            }
            let port = components.port ?? (scheme == "https" ? 443 : 80)
            origin = "\(scheme)://\(host):\(port)"
            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            self.path = path
        }
    }
}

private extension String {
    /// Path containment on segment boundaries: `/team/api/ws` is within
    /// `/team`, `/teammate` is not. The empty base path contains every path.
    func isWithin(_ base: String) -> Bool {
        base.isEmpty || self == base || hasPrefix(base + "/")
    }
}
