//
//  ServerSignOut.swift
//  Conduit
//
//  Sign Out and Remove Dashboard end the sign-in on the Hermes server too
//  (#889). Deleting the tokens from the Keychain alone left the refresh token
//  valid at the identity provider until it expired (30 days with common
//  settings), so a lost or sold phone kept a working sign-in.
//
//  Hermes' POST /auth/logout already revokes a refresh token with every
//  provider. It reads the token from the session cookie and is public, so the
//  app sends the native grant's refresh token (or the cookie session's own)
//  as that cookie. The access token is deleted with the rest of the dashboard's
//  sign-in at once; the refresh token is kept only in a separate "revoke
//  pending" record nothing signs in with, retried on launch and on returning to
//  the app until Hermes answers or the token is past its lifetime.
//

import Foundation
import OSLog

/// A refresh token waiting for Hermes to revoke it.
struct PendingServerSignOut: Codable, Equatable {
    let id: UUID
    let dashboardID: UUID
    let baseURL: String
    let refreshToken: String
    let signedOutAt: Date
    /// Answers that were an auth edge turning the request away, not Hermes.
    var refusals = 0
}

enum ServerSignOut {
    /// Hermes' session refresh cookie; /auth/logout reads the bare name and
    /// its `__Host-` / `__Secure-` variants.
    static let refreshCookieName = "hermes_session_rt"
    static let logoutPath = "/auth/logout"
    /// A refresh token outlives no common provider setting past this, so a
    /// record still pending then has nothing left to revoke.
    static let pendingLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// Records kept at most; the oldest go first.
    static let maximumPending = 32
    /// An edge that turned the request away this often won't pass it (Remove
    /// Dashboard deleted the Cloudflare token a retry would need).
    static let maximumRefusals = 5

    enum Outcome: Equatable {
        /// Hermes answered: the token is revoked, or the server has no logout
        /// route and nothing more can be done.
        case ended
        /// Not reached (offline, an auth edge, a server error): try again.
        case retryLater
    }

    /// The refresh tokens a dashboard's sign-in holds: the native grant's and
    /// the cookie session's own, without repeats.
    static func refreshTokens(
        native: NativeOAuthTokenSet?,
        cookies: [HTTPCookie],
        baseURL: String
    ) -> [String] {
        var tokens: [String] = []
        if let token = native?.refreshToken { tokens.append(token) }
        let host = URL(string: baseURL)?.host?.lowercased()
        for cookie in cookies where isRefreshCookie(cookie, host: host) {
            tokens.append(cookie.value)
        }
        var seen = Set<String>()
        return tokens.filter { isSendable($0) && seen.insert($0).inserted }
    }

    private static func isRefreshCookie(_ cookie: HTTPCookie, host: String?) -> Bool {
        guard ["", "__Host-", "__Secure-"].contains(where: { "\($0)\(refreshCookieName)" == cookie.name }),
              let host else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix(".\(domain)")
    }

    /// Whether the token can travel as a cookie value unchanged.
    static func isSendable(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value < 0x7F && !"\";,\\".unicodeScalars.contains(scalar)
        }
    }

    /// POST /auth/logout carrying the refresh token as Hermes' session cookie,
    /// with the dashboard's proxy headers. Nil for an address Conduit would
    /// not connect to.
    static func request(
        baseURL: String,
        refreshToken: String,
        cloudflare: CloudflareAccessCredentials?,
        headers: CustomHeaderStore = .shared
    ) -> URLRequest? {
        guard isSendable(refreshToken),
              let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)\(logoutPath)"),
              ConnectionURLPolicy.originMatches(url, expected: URL(string: normalized)) else { return nil }
        var request = URLRequest(url: url).applyingProxyHeaders(cloudflare: cloudflare, store: headers)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("\(refreshCookieName)=\(refreshToken)", forHTTPHeaderField: "Cookie")
        return request
    }

    /// Hermes answers /auth/logout with a redirect to its own sign-in page.
    /// A redirect anywhere else is an auth edge in front of it, which never
    /// passed the request on.
    static func outcome(status: Int, location: String?, requestURL: URL) -> Outcome {
        switch status {
        case 200...299:
            return .ended
        case 300...399:
            guard let location,
                  requestURL.path.hasSuffix(logoutPath),
                  let target = URL(string: location, relativeTo: requestURL)?.absoluteURL,
                  ConnectionURLPolicy.originMatches(target, expected: requestURL) else { return .retryLater }
            let logoutPrefix = String(requestURL.path.dropLast(logoutPath.count))
            return target.path == "\(logoutPrefix)/login" ? .ended : .retryLater
        case 404, 405:
            // A server without the logout route has nothing to revoke with.
            // An edge answering 404 for a hidden origin lands here too.
            return .ended
        default:
            return .retryLater
        }
    }
}

/// Holds refresh tokens until Hermes has revoked them. One send at a time.
@MainActor
final class ServerSignOutQueue {
    static let shared: ServerSignOutQueue = {
        // Unit tests never send a sign-out to an address or keep one in the
        // Keychain; the ones about it build their own queue.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            var stored: [PendingServerSignOut] = []
            return ServerSignOutQueue(send: { _ in nil }, load: { stored }, save: { stored = $0 })
        }
        return ServerSignOutQueue()
    }()

    /// The status and Location header Hermes answered with, or nil when the
    /// request never got an answer.
    typealias Send = @MainActor (URLRequest) async -> (status: Int, location: String?)?

    private let log = Logger(subsystem: "com.milim.relay", category: "ServerSignOut")
    private let send: Send
    private let now: () -> Date
    private let load: () -> [PendingServerSignOut]
    private let save: ([PendingServerSignOut]) -> Void
    private var drainTask: Task<Void, Never>?
    private var drainAgain = false
    /// Requests built at sign-out, while the dashboard's proxy headers still
    /// exist (Remove Dashboard deletes them next). Retries rebuild.
    private var preparedRequests: [UUID: URLRequest] = [:]

    init(
        send: Send? = nil,
        now: @escaping () -> Date = Date.init,
        load: @escaping () -> [PendingServerSignOut] = KeychainHelper.loadPendingServerSignOuts,
        save: @escaping ([PendingServerSignOut]) -> Void = KeychainHelper.savePendingServerSignOuts
    ) {
        self.send = send ?? ServerSignOutQueue.urlSessionSend
        self.now = now
        self.load = load
        self.save = save
    }

    var pending: [PendingServerSignOut] { load() }

    /// Records the tokens before the dashboard's sign-in is deleted, then
    /// asks Hermes to revoke them.
    func signOut(
        dashboardID: UUID,
        baseURL: String,
        refreshTokens: [String],
        cloudflare: CloudflareAccessCredentials?
    ) {
        let entries = refreshTokens.map {
            PendingServerSignOut(id: UUID(), dashboardID: dashboardID, baseURL: baseURL, refreshToken: $0, signedOutAt: now())
        }
        guard !entries.isEmpty else { return }
        for entry in entries {
            preparedRequests[entry.id] = ServerSignOut.request(
                baseURL: baseURL, refreshToken: entry.refreshToken, cloudflare: cloudflare
            )
        }
        let tokens = Set(refreshTokens)
        var stored = load().filter { !tokens.contains($0.refreshToken) }
        stored.append(contentsOf: entries)
        save(Array(stored.suffix(ServerSignOut.maximumPending)))
        retryPending()
    }

    /// Sends every pending revoke; called at sign-out, launch and return to
    /// the app.
    @discardableResult
    func retryPending() -> Task<Void, Never> {
        if let drainTask {
            drainAgain = true
            return drainTask
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.drainAgain = false
                await self.drain()
            } while self.drainAgain
            self.drainTask = nil
        }
        drainTask = task
        return task
    }

    private func drain() async {
        let cutoff = now().addingTimeInterval(-ServerSignOut.pendingLifetime)
        let current = load()
        let live = current.filter { $0.signedOutAt > cutoff }
        if live.count != current.count {
            log.notice("Server sign-out past its lifetime dropped")
            save(live)
        }
        let liveIDs = Set(live.map(\.id))
        preparedRequests = preparedRequests.filter { liveIDs.contains($0.key) }
        var ended = Set<UUID>()
        var refused = Set<UUID>()
        for entry in live {
            // The prepared request stays until Hermes or an edge answers: an
            // offline try must not lose the headers Remove Dashboard deleted.
            let request = preparedRequests[entry.id] ?? ServerSignOut.request(
                baseURL: entry.baseURL,
                refreshToken: entry.refreshToken,
                cloudflare: KeychainHelper.loadCloudflareAccess(dashboardID: entry.dashboardID, for: entry.baseURL)
            )
            guard let request, let url = request.url else {
                // Not an address Conduit can reach: nothing to send, ever.
                ended.insert(entry.id)
                continue
            }
            guard let answer = await send(request) else { continue }
            preparedRequests[entry.id] = nil
            if ServerSignOut.outcome(status: answer.status, location: answer.location, requestURL: url) == .ended {
                ended.insert(entry.id)
            } else if answer.status < 500, answer.status != 429 {
                refused.insert(entry.id)
            }
        }
        guard !ended.isEmpty || !refused.isEmpty else { return }
        // Re-read: a sign-out during the sends added its own records.
        let remaining: [PendingServerSignOut] = load().compactMap { entry in
            guard !ended.contains(entry.id) else { return nil }
            guard refused.contains(entry.id) else { return entry }
            var entry = entry
            entry.refusals += 1
            guard entry.refusals < ServerSignOut.maximumRefusals else {
                log.notice("Server sign-out given up after repeated refusals")
                return nil
            }
            return entry
        }
        save(remaining)
    }

    private static func urlSessionSend(_ request: URLRequest) async -> (status: Int, location: String?)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let answer = try? await session.data(for: request),
              let http = answer.1 as? HTTPURLResponse else { return nil }
        return (http.statusCode, http.value(forHTTPHeaderField: "Location"))
    }

    /// The redirect itself is the answer; following it would ask the sign-in
    /// page, or an edge's identity provider, for nothing.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
