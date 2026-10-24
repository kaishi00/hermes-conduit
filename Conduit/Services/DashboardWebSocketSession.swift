//
//  DashboardWebSocketSession.swift
//  Conduit
//
//  The transport every dashboard WebSocket opens on (chat, Kanban live
//  events, the dashboard voice streams, the Grok relay): an ephemeral
//  session that neither sends nor stores cookies and never follows a
//  redirect, plus the handshake status the server answered with.
//
//  A redirected upgrade would otherwise be followed with the request's own
//  headers (proxy headers included) to wherever `Location` points, and a
//  cookie jar would add whatever it holds for that host. The dashboard's
//  authority travels only in what the request builder put there for the
//  selected dashboard: its single-use ticket and, in cookie mode, its own
//  session cookies for that address (an auth proxy in front admits the
//  upgrade only with them), or in native mode its bearer.
//

import Foundation

/// The session configuration for dashboard WebSockets: no cookie jar, no
/// cache, no stored URL credentials.
enum DashboardWebSocketSessionPolicy {
    static func configuration(waitsForConnectivity: Bool = false) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = waitsForConnectivity
        return configuration
    }
}

/// How the server turned down a dashboard WebSocket upgrade, read from the
/// handshake's HTTP status.
enum DashboardSocketHandshakeError: LocalizedError, Equatable {
    /// A 3xx to a sign-in: the server wants a browser session first. The
    /// redirect is never followed, so the ticket never goes along.
    case browserSessionRequired(status: Int)

    /// The typed refusal for a handshake: a redirect counts as sign-in only
    /// when its target is one (`DashboardSignInRedirect`: another origin,
    /// or a sign-in page on the dashboard's own). A same-origin redirect to
    /// an ordinary address (a load balancer's 307, the same host moving to
    /// https/wss) and a redirect without a target stay a closed connection
    /// for the reconnect path, like a 401 or 403, which says nothing about
    /// the account (Hermes answers a spent ticket with 403).
    static func failure(status: Int?, redirectTarget: URL?, dashboardURL: String) -> DashboardSocketHandshakeError? {
        guard let status, (300...399).contains(status),
              let target = redirectTarget.map(httpEquivalent),
              let dashboard = URL(string: dashboardURL) else { return nil }
        return DashboardSignInRedirect.isSignIn(target, forDashboard: dashboard)
            ? .browserSessionRequired(status: status) : nil
    }

    /// A socket address as the page address it stands for (ws as http, wss
    /// as https), for the sign-in rule.
    private static func httpEquivalent(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: break
        }
        return components.url ?? url
    }

    var errorDescription: String? {
        switch self {
        case .browserSessionRequired:
            return AppLocalization.string("This server asked for a browser sign-in before connecting to Hermes. Conduit doesn't follow that redirect with your sign-in.")
        }
    }
}

/// Refuses every redirect on a dashboard WebSocket upgrade and reports how
/// each handshake ended. One delegate can serve many tasks (the shared
/// session) or one (a chat transport's own session).
final class DashboardWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// What a task's owner hears about its handshake. Both run on the
    /// session's delegate queue.
    struct Handlers {
        var onOpen: (() -> Void)?
        /// The task ended (or was closed) before its upgrade completed.
        /// `status` is the HTTP status that refused it, when there was one,
        /// and `redirectTarget` where a refused redirect pointed.
        var onEndBeforeOpen: ((_ status: Int?, _ redirectTarget: URL?) -> Void)?
    }

    private let lock = NSLock()
    private var handlers: [Int: Handlers] = [:]
    private var redirectStatuses: [Int: Int] = [:]
    private var redirectTargets: [Int: URL] = [:]
    private var openedTasks: Set<Int> = []

    /// Registers before `resume()`, so no callback can arrive first.
    func register(_ task: URLSessionTask, handlers: Handlers) {
        lock.lock()
        self.handlers[task.taskIdentifier] = handlers
        lock.unlock()
    }

    /// The HTTP status that refused this task's upgrade: the refused
    /// redirect's 3xx, or the final non-101 response. Nil for an upgrade
    /// that completed or a connection that never got an answer.
    func handshakeStatus(of task: URLSessionTask) -> Int? {
        lock.lock()
        let redirect = redirectStatuses[task.taskIdentifier]
        let opened = openedTasks.contains(task.taskIdentifier)
        lock.unlock()
        if let redirect { return redirect }
        guard !opened, let http = task.response as? HTTPURLResponse, http.statusCode != 101 else { return nil }
        return http.statusCode
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never followed: not to another origin, not to another path of the
        // same one. The upgrade fails here, carrying nothing further.
        lock.lock()
        redirectStatuses[task.taskIdentifier] = response.statusCode
        redirectTargets[task.taskIdentifier] = request.url
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        openedTasks.insert(webSocketTask.taskIdentifier)
        let onOpen = handlers[webSocketTask.taskIdentifier]?.onOpen
        lock.unlock()
        onOpen?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        endBeforeOpenIfNeeded(webSocketTask, forget: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        endBeforeOpenIfNeeded(task, forget: true)
    }

    private func endBeforeOpenIfNeeded(_ task: URLSessionTask, forget: Bool) {
        let status = handshakeStatus(of: task)
        lock.lock()
        let opened = openedTasks.contains(task.taskIdentifier)
        let onEnd = handlers[task.taskIdentifier]?.onEndBeforeOpen
        let target = redirectTargets[task.taskIdentifier]
        if forget {
            handlers.removeValue(forKey: task.taskIdentifier)
            redirectStatuses.removeValue(forKey: task.taskIdentifier)
            redirectTargets.removeValue(forKey: task.taskIdentifier)
            openedTasks.remove(task.taskIdentifier)
        }
        lock.unlock()
        guard !opened else { return }
        onEnd?(status, target)
    }
}

/// The one session the secondary dashboard sockets (Kanban live events,
/// the dashboard voice streams) open on. Never invalidated, like
/// `URLSession.shared`, but cookie-less and redirect-refusing.
final class DashboardWebSocketSession: @unchecked Sendable {
    static let shared = DashboardWebSocketSession()

    let delegate = DashboardWebSocketDelegate()
    private let session: URLSession

    init(configuration: URLSessionConfiguration = DashboardWebSocketSessionPolicy.configuration()) {
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// A task for `request`, not yet resumed. `onRefused` hears the HTTP
    /// status of an upgrade the server turned down.
    func webSocketTask(
        with request: URLRequest,
        onRefused: ((_ status: Int) -> Void)? = nil
    ) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: request)
        delegate.register(task, handlers: .init(onOpen: nil, onEndBeforeOpen: { status, _ in
            if let status { onRefused?(status) }
        }))
        return task
    }
}
