//
//  GatewayReadinessProbe.swift
//  Conduit
//
//  Whether a dashboard answers at all, for the reconnect's backoff while
//  Conduit is on screen. One HEAD to /api/status with a short timeout, no
//  cookies and no WebKit: a gateway restarting (a repin, a controller roll)
//  costs one cheap request per step instead of a ticket, an upgrade and the
//  socket's open timeout, and a gateway that is back is reconnected to at
//  the next step.
//

import Foundation

enum GatewayReadinessProbe {
    static let timeout: TimeInterval = 3

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Whether the dashboard at `baseURL` answered. Any HTTP answer counts
    /// (a sign-in redirect, an access page, 405 for HEAD), except a proxy's
    /// own 502, 503 or 504 for a backend that is down; a refused or timed
    /// out connection doesn't. An address it can't read counts as answered,
    /// so the full reconnect reports it as before.
    static func answers(_ baseURL: String) async -> Bool {
        guard var components = URLComponents(string: baseURL), components.host != nil else { return true }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/api/status"
        components.query = nil
        guard let url = components.url else { return true }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        do {
            let (_, response) = try await session.data(for: request)
            return Self.answered(status: (response as? HTTPURLResponse)?.statusCode)
        } catch {
            return false
        }
    }

    static func answered(status: Int?) -> Bool {
        guard let status else { return true }
        // A proxy's own page for a backend that is down; 520-524 and 530 are
        // Cloudflare's origin-unreachable statuses.
        return ![502, 503, 504, 520, 521, 522, 523, 524, 530].contains(status)
    }
}
