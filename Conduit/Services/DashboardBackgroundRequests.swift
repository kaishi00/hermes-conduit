//
//  DashboardBackgroundRequests.swift
//  Conduit
//
//  Dashboard requests while the phone app is in the background (#378).
//
//  The ticket bridge normally runs every dashboard request inside its hidden
//  WebKit page, so the HttpOnly session cookie never leaves WebKit. WebKit
//  suspends that page once Conduit's phone screen leaves the foreground, and
//  never runs it when CarPlay launched the app without one. Ticket mints and
//  live-call starts then hung, and CarPlay kept trying to connect until the
//  phone app was opened. Without the page, the same request goes out through
//  URLSession carrying the page's cookies, the way the page's fetch would.
//

import Foundation
import WebKit

extension DashboardTicketBridge {
    /// The request the page's `fetch` would send, without the page: same
    /// path (resolved against the page's origin), method, JSON body and
    /// proxy headers, with the dashboard's cookies attached. Same error
    /// contract as `requestJSON`, except that having no cookies at all is
    /// `.notReady`: nothing proves the sign-in expired.
    func requestJSONWithoutPage(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        guard let url = Self.pageRequestURL(path: path, baseURL: baseURL) else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("Could not encode dashboard request."))
        }
        let cookies = await cookiesForRequestsWithoutPage()
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        let cookieHeader = NativeAuthCookiePolicy.headerFields(for: cookies, url: url)
        guard !cookieHeader.isEmpty else { throw DashboardTicketBridgeError.notReady }

        var request = URLRequest(url: url).applyingProxyHeaders(cloudflare: cloudflareAccess)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(max(1_000, timeoutMilliseconds)) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in cookieHeader {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if method.uppercased() != "GET", method.uppercased() != "HEAD",
           let scheme = url.scheme, let host = url.host {
            // The page's fetch is same-origin, so the browser sends Origin
            // on everything but GET and HEAD.
            let port = url.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let result: (Data, URLResponse)
        do {
            result = try await Self.load(request, deadline: .milliseconds(max(1_000, timeoutMilliseconds)))
        } catch let error as URLError {
            // A cancelled caller hears cancellation, as from the page path.
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            // What the page's fetch reports for a network failure or its
            // abort: status 0.
            throw DashboardTicketBridgeError.http(status: 0, detail: error.localizedDescription)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw DashboardTicketBridgeError.http(status: 0, detail: "No response from the dashboard.")
        }
        let issued = NativeAuthCookiePolicy.acceptedCookies(from: http)
        if !issued.isEmpty, !isInvalidated {
            backgroundIssuedCookies = NativeAuthCookiePolicy.merged(backgroundIssuedCookies + issued)
            // The page picks the new cookies up when it runs again.
            let store = webView.configuration.websiteDataStore.httpCookieStore
            for cookie in issued {
                store.setCookie(cookie, completionHandler: nil)
            }
        }
        if (300...399).contains(http.statusCode) {
            // Same-origin redirects are followed, as the page's fetch does.
            // One that comes back is to sign-in or another origin: a
            // sign-in redirect means the session is gone, as the page
            // landing on /login does.
            let location = http.value(forHTTPHeaderField: "Location") ?? ""
            if location.contains("/login") { throw DashboardTicketBridgeError.signInRequired }
            throw DashboardTicketBridgeError.http(
                status: http.statusCode,
                detail: AppLocalization.string("Dashboard request failed (\(String(http.statusCode))).")
            )
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DashboardTicketBridgeError.signInRequired
        }
        guard data.count <= maxResponseBytes else {
            throw DashboardTicketBridgeError.oversizedResponse(limit: maxResponseBytes)
        }
        let value = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard (200...299).contains(http.statusCode) else {
            let object = value as? [String: Any]
            let detail = (object?["error"] ?? object?["message"] ?? object?["detail"]) as? String
            throw DashboardTicketBridgeError.http(
                status: http.statusCode,
                detail: detail ?? AppLocalization.string("Dashboard request failed (\(String(http.statusCode))).")
            )
        }
        // Shaped as the page's response: objects as they are, arrays under
        // `_array`, anything else under `value`.
        if let object = value as? [String: Any] { return object }
        if let array = value as? [Any] { return ["_array": array] }
        if data.isEmpty { return [:] }
        return ["value": value ?? String(decoding: data, as: UTF8.self)]
    }

    /// The response, or `URLError(.timedOut)` once `deadline` passes in
    /// total, as the page's AbortController does. A request's own timeout
    /// only limits the wait between bytes.
    private static func load(_ request: URLRequest, deadline: Duration) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await DashboardBackgroundSession.shared.data(for: request) }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.unknown) }
            return first
        }
    }

    /// Where the page's `fetch(path)` goes: `path` resolved against the
    /// page the bridge loads.
    nonisolated static func pageRequestURL(path: String, baseURL: String) -> URL? {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let page = URL(string: "\(normalized)/api/status"),
              let url = URL(string: path, relativeTo: page)?.absoluteURL,
              ConnectionURLPolicy.originMatches(url, expected: page) else { return nil }
        return url
    }

    /// The dashboard's cookies from every store that holds them: the
    /// Keychain mirror, WebKit's own store (when it answers in time), the
    /// native sign-in jar (a silent re-sign-in lands there), and cookies
    /// issued to requests sent without the page.
    private func cookiesForRequestsWithoutPage() async -> [HTTPCookie] {
        var cookies = DashboardCookiePersistence.mirroredCookies(dashboardID: dashboardID)
        if let webKit = await webKitCookies(timeout: .seconds(2)) {
            cookies += webKit
        }
        cookies += DashboardCookiePersistence.nativeCookieStorage(for: dashboardID).cookies ?? []
        cookies += backgroundIssuedCookies
        return Self.freshestCookies(cookies)
    }

    /// One copy of each cookie (name, domain, path): the one that expires
    /// last, since a newer sign-in or a renewed session runs longer. A
    /// session cookie (no expiry, the usual live dashboard session) counts
    /// as never expiring, so a dated copy never displaces it. Ties go to
    /// the later source.
    nonisolated static func freshestCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var order: [String] = []
        var chosen: [String: HTTPCookie] = [:]
        for cookie in cookies {
            let key = [
                cookie.name,
                cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                cookie.path.isEmpty ? "/" : cookie.path,
            ].joined(separator: "\u{0}")
            guard let current = chosen[key] else {
                order.append(key)
                chosen[key] = cookie
                continue
            }
            let held = current.expiresDate ?? .distantFuture
            let offered = cookie.expiresDate ?? .distantFuture
            if offered < held { continue }
            chosen[key] = cookie
        }
        return order.compactMap { chosen[$0] }
    }

    /// WebKit's cookie store, or nil when it doesn't answer within
    /// `timeout` (its process may be suspended too).
    private func webKitCookies(timeout: Duration) async -> [HTTPCookie]? {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let once = DashboardCookieAnswer()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            store.getAllCookies { cookies in
                // A hop rather than assuming the main queue: a wrong-queue
                // callback must not trap in a car.
                Task { @MainActor in once.resume(cookies) }
            }
            once.timeout = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
    }
}

/// Resumes a cookie read exactly once: with the cookies, or nil on timeout.
@MainActor
private final class DashboardCookieAnswer {
    var continuation: CheckedContinuation<[HTTPCookie]?, Never>?
    var timeout: Task<Void, Never>?

    func resume(_ cookies: [HTTPCookie]?) {
        continuation?.resume(returning: cookies)
        continuation = nil
        timeout?.cancel()
        timeout = nil
    }
}

/// The URLSession for requests sent without the page. Cookies are set by
/// hand from the dashboard's own stores, so the session keeps none.
/// Same-origin redirects are followed with the same headers, as the page's
/// fetch follows them; a redirect to sign-in or another origin comes back
/// as the response.
enum DashboardBackgroundSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()

    private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(DashboardBackgroundSession.redirect(
                from: task.originalRequest,
                to: request
            ))
        }
    }

    /// The redirect to follow, carrying the original request's headers
    /// (its cookies and proxy headers), or nil to return the redirect as
    /// the response: one to sign-in or to another origin.
    static func redirect(from original: URLRequest?, to proposed: URLRequest) -> URLRequest? {
        guard let original, let source = original.url, let destination = proposed.url,
              ConnectionURLPolicy.isAllowedTransport(destination),
              ConnectionURLPolicy.originMatches(destination, expected: source),
              !destination.path.contains("/login") else { return nil }
        var followed = proposed
        for (name, value) in original.allHTTPHeaderFields ?? [:]
            where followed.value(forHTTPHeaderField: name) == nil {
            followed.setValue(value, forHTTPHeaderField: name)
        }
        return followed
    }
}
