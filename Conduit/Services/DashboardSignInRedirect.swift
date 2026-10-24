//
//  DashboardSignInRedirect.swift
//  Conduit
//
//  When a dashboard request that should have reached the dashboard is sent
//  to sign in instead. An auth proxy in front of the dashboard (an
//  oauth2-proxy-style edge with an OIDC provider, a Cloudflare Access gate)
//  answers every request with a redirect once its session is gone: to its
//  own sign-in host, to the identity provider's authorize page, or to a
//  sign-in page on the dashboard's own origin. Each of those means the same
//  thing as Hermes' own /login: sign-in is required. A same-origin redirect
//  to an ordinary page never does.
//
//  One decision for the hidden dashboard page, requests sent without it and
//  the background session's redirect rule, so they can never disagree about
//  whether the user was signed out.
//

import Foundation

enum DashboardSignInRedirect {
    /// Whether `url`, a page or redirect target for a request to the
    /// dashboard at `dashboardURL`, is a sign-in: any web address on another
    /// origin, or a sign-in page on the dashboard's own. The dashboard's own
    /// host moving from http to https (an edge that forces TLS) counts as
    /// its own origin. Nil (no address at all) and other schemes are not
    /// evidence of anything.
    static func isSignIn(_ url: URL?, forDashboard dashboardURL: URL) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        guard ConnectionURLPolicy.originMatches(url, expected: dashboardURL)
                || isSecureUpgrade(url, of: dashboardURL) else { return true }
        return isSignInPath(url.path)
    }

    /// The dashboard's own host on https, its http address upgraded.
    private static func isSecureUpgrade(_ target: URL, of dashboard: URL) -> Bool {
        dashboard.scheme?.lowercased() == "http" && target.scheme?.lowercased() == "https"
            && target.host?.lowercased() == dashboard.host?.lowercased()
    }

    /// The redirect a response to `requestURL` answered with, resolved the
    /// way a browser would (a relative `Location` against the request), is a
    /// sign-in for the dashboard at `dashboardURL`.
    static func redirectIsSignIn(location: String?, from requestURL: URL, forDashboard dashboardURL: URL) -> Bool {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty,
              let target = URL(string: location, relativeTo: requestURL)?.absoluteURL else { return false }
        return isSignIn(target, forDashboard: dashboardURL)
    }

    /// A sign-in page's path on the dashboard's own origin: a sign-in path
    /// segment (Hermes' `/login`, `/signin`, `/sign_in`, `/sign-in`, under
    /// any base path), or an auth proxy's start endpoint (`/oauth2/start`,
    /// `/oauth2/sign_in`). Whole segments only: an ordinary page whose path
    /// merely contains "login" (`/docs/login-guide`) is not sign-in.
    static func isSignInPath(_ path: String) -> Bool {
        let segments = path.lowercased().split(separator: "/").map(String.init)
        if segments.contains(where: { signInSegments.contains($0) }) { return true }
        return zip(segments, segments.dropFirst()).contains { $0 == "oauth2" && $1 == "start" }
    }

    private static let signInSegments: Set<String> = ["login", "signin", "sign_in", "sign-in"]
}
