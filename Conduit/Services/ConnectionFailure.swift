//
//  ConnectionFailure.swift
//  Conduit
//
//  Semantic classification of failed login/connection attempts (Round 1 of
//  the Connection Setup foundation). The login UI must never present raw
//  Foundation error strings: every failure that can surface on the login
//  screen is classified here from its underlying error TYPE or transport
//  code — never from localized text — and mapped to user-facing copy plus a
//  Connection Help destination for the future Connection Setup Assistant.
//

import Foundation

/// The semantic failure categories the login/connection pipeline can produce.
enum ConnectionFailure: Equatable {
    // Address/transport policy (ConnectionURLPolicy).
    case invalidAddress
    case insecureTransport

    // Network reachability.
    case hostNotFound
    case unreachable
    case connectionRefused
    case timedOut
    case offline

    // TLS (classified, never bypassed — issue #129).
    case tlsUntrusted
    case tlsBadDate
    case tlsFailure

    // Authentication stages.
    case authenticationRejected
    /// Hermes throttles `/auth/password-login` (10 attempts / 60s / client
    /// IP, HTTP 429). Distinct from `.authenticationRejected`: a throttle is
    /// not a wrong password, and the copy must not invite immediate retries.
    case rateLimited
    /// The dashboard bridge reports the WebKit session is gone (interactive
    /// sign-in has expired or never happened). The login form itself is the
    /// remedy — no troubleshooting destination would help.
    case loginRequired
    case cloudflareTokenRejected
    case sessionTicketFailure

    // Server-side responses.
    case dashboardUnavailable
    case unexpectedServerResponse

    case unknown
}

/// Maps the errors that can escape the login pipeline onto `ConnectionFailure`
/// by inspecting error types and `URLError` codes — never localized strings.
enum ConnectionFailureClassifier {
    /// Authentication stage context: the same HTTP status means different
    /// things at provider discovery than at password login. A 401 during
    /// provider discovery is NOT evidence of bad credentials.
    private enum AuthStage {
        case providerDiscovery
        case passwordLogin
        /// Dashboard-ticket bridge requests (WebKit-side ticket minting):
        /// like provider discovery, a 401/403 here is never bad credentials.
        case ticketMint
    }

    static func classify(_ error: Error) -> ConnectionFailure {
        if let policyError = error as? ConnectionURLPolicyError {
            return classify(policyError)
        }
        if let authError = error as? AuthClientError {
            return classify(authError)
        }
        if let urlError = error as? URLError {
            return classify(urlError)
        }
        if let bridgeError = error as? DashboardTicketBridgeError {
            return classify(bridgeError)
        }
        // URLSession surfaces transport failures as NSError values in the
        // NSURLErrorDomain (e.g. injected through URLProtocol test seams).
        // Recover the typed error so classification stays code-based even
        // for bridged errors.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return classify(URLError(URLError.Code(rawValue: nsError.code)))
        }
        return .unknown
    }

    static func classify(_ policyError: ConnectionURLPolicyError) -> ConnectionFailure {
        switch policyError {
        case .invalidURL: return .invalidAddress
        case .insecureTransport: return .insecureTransport
        }
    }

    static func classify(_ authError: AuthClientError) -> ConnectionFailure {
        switch authError {
        case .invalidURL:
            return .invalidAddress
        case .loginFailed(let status, _):
            return classifyHTTPStatus(status, stage: .passwordLogin)
        case .ticketFailed:
            // The password was accepted; whatever failed now is not a
            // credentials problem. Never present this as "wrong password".
            return .sessionTicketFailure
        case .providerDiscoveryFailed(let status, _):
            return classifyHTTPStatus(status, stage: .providerDiscovery)
        case .cloudflareServiceTokenRejected:
            return .cloudflareTokenRejected
        }
    }

    /// Dashboard-ticket bridge failures. signInRequired means the WebKit
    /// sign-in session is gone — the login form itself is the remedy, so it
    /// must classify as login-required rather than degrade to unknown.
    static func classify(_ bridgeError: DashboardTicketBridgeError) -> ConnectionFailure {
        switch bridgeError {
        case .signInRequired:
            return .loginRequired
        case .http(let status, _):
            return classifyHTTPStatus(status, stage: .ticketMint)
        case .notReady, .requestFailed, .oversizedResponse:
            return .unexpectedServerResponse
        }
    }

    static func classify(_ urlError: URLError) -> ConnectionFailure {
        switch urlError.code {
        case .badURL:
            return .invalidAddress
        case .appTransportSecurityRequiresSecureConnection:
            return .insecureTransport
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound
        case .cannotConnectToHost:
            return .connectionRefused
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return .offline
        case .networkConnectionLost:
            return .unreachable
        case .badServerResponse, .httpTooManyRedirects:
            // NativeAuthClient.perform throws badServerResponse when no
            // usable response arrives — a dashboard-behavior problem, not an
            // unknown one.
            return .unexpectedServerResponse
        case .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return .tlsBadDate
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            return .tlsUntrusted
        case .secureConnectionFailed:
            return .tlsFailure
        default:
            return .unknown
        }
    }

    private static func classifyHTTPStatus(_ status: Int?, stage: AuthStage) -> ConnectionFailure {
        guard let status else { return .unexpectedServerResponse }
        if stage == .passwordLogin {
            // Only the endpoint Hermes actually throttles (/auth/password-login,
            // 10 req/60s/IP) may claim the login-cooldown presentation. A 429
            // from any other auth endpoint is unexpected server behavior, not
            // a login cooldown — and retrying it does not consume the
            // password-login budget, so its presentation keeps recovery
            // actions.
            if status == 429 {
                return .rateLimited
            }
            // Only the password-authentication stage may claim "bad
            // credentials"; 401s elsewhere are a misrouted/odd deployment.
            if status == 401 || status == 403 {
                return .authenticationRejected
            }
        }
        if (500...599).contains(status) {
            return .dashboardUnavailable
        }
        return .unexpectedServerResponse
    }
}

/// Where the (future) Connection Setup Assistant should land when the user
/// asks for help with a classified failure. The assistant itself does not
/// exist yet; the destination is carried so adding it does not redesign
/// error classification.
enum ConnectionHelpDestination: Equatable, Hashable, Identifiable, CaseIterable {
    case start
    case dashboard
    case credentials
    case network
    case tls
    case cloudflare

    var id: Self { self }
}

/// The login screen's presentation of one failure: concise user-facing copy
/// plus, for classified connection failures, recovery actions. Validation
/// notices (missing fields, empty URL) carry no actions.
struct ConnectionFailurePresentation: Equatable {
    let title: String
    let message: String
    let helpDestination: ConnectionHelpDestination?
    /// Whether Try Again / Troubleshoot Connection actions accompany this
    /// failure.
    let offersRecoveryActions: Bool

    /// Presentation for a classified connection failure, with recovery
    /// actions and the classified help destination. Rate limiting is the one
    /// exception: a "Try Again" button would encourage exactly the immediate
    /// retry Hermes just throttled, so it offers no actions at all.
    static func presenting(_ failure: ConnectionFailure) -> ConnectionFailurePresentation {
        ConnectionFailurePresentation(
            title: failure.userTitle,
            message: failure.userMessage,
            helpDestination: failure.helpDestination,
            offersRecoveryActions: failure != .rateLimited
        )
    }

    /// A validation notice (form-state feedback, not a connection failure).
    /// No recovery actions: the fix is editing the form, not retrying.
    static func notice(title: String, message: String = "") -> ConnectionFailurePresentation {
        ConnectionFailurePresentation(
            title: title,
            message: message,
            helpDestination: nil,
            offersRecoveryActions: false
        )
    }
}

// MARK: - User-facing copy

extension ConnectionFailure {
    var userTitle: String {
        switch self {
        case .invalidAddress: return "Check the dashboard address"
        case .insecureTransport: return "Insecure dashboard address"
        case .hostNotFound: return "Dashboard not found"
        case .unreachable, .connectionRefused: return "Couldn’t reach Hermes"
        case .timedOut: return "Connection timed out"
        case .offline: return "No network connection"
        case .tlsUntrusted: return "Secure connection failed"
        case .tlsBadDate: return "Certificate date problem"
        case .tlsFailure: return "Secure connection failed"
        case .authenticationRejected: return "Login failed"
        case .rateLimited: return "Too many login attempts"
        case .loginRequired: return "Sign-in required"
        case .cloudflareTokenRejected: return "Cloudflare rejected the service token"
        case .sessionTicketFailure: return "Could not start the session"
        case .dashboardUnavailable: return "Dashboard unavailable"
        case .unexpectedServerResponse: return "Unexpected response"
        case .unknown: return "Couldn’t connect"
        }
    }

    var userMessage: String {
        switch self {
        case .invalidAddress:
            return "That doesn’t look like a dashboard URL Conduit can use. Check it for typos — it should look like https://hermes.example."
        case .insecureTransport:
            return "Remote dashboards must use HTTPS. Plain HTTP is only accepted for local addresses like localhost, private LAN IPs, and Tailscale."
        case .hostNotFound:
            return "Conduit could not find that host. Check the dashboard address and try again."
        case .unreachable, .connectionRefused:
            return "Conduit could not connect to the dashboard at this address. Make sure the dashboard is running and that this device can reach it."
        case .timedOut:
            return "The dashboard did not respond in time. Check the address, the network connection, and whether the Hermes dashboard is running."
        case .offline:
            return "This device doesn’t appear to have a network connection. Reconnect to Wi-Fi or cellular and try again."
        case .tlsUntrusted:
            return "Conduit reached the server, but iOS does not trust its TLS certificate. If you use your own certificate authority, make sure its root certificate is installed and trusted on this device."
        case .tlsBadDate:
            return "The dashboard certificate is expired or not yet valid. Check the certificate dates and this device’s date and time."
        case .tlsFailure:
            return "Conduit could not establish a secure connection to the dashboard. The server’s TLS certificate may be misconfigured."
        case .authenticationRejected:
            return "Hermes rejected that username or password. Check your dashboard credentials and try again."
        case .rateLimited:
            return "Hermes temporarily blocked additional login attempts. Wait about a minute before trying again."
        case .loginRequired:
            return "Your dashboard session has expired. Sign in again to reconnect."
        case .cloudflareTokenRejected:
            return "Cloudflare Access did not accept the configured service token. "
                + "Verify the Client ID / Secret and that the token is allowed by a "
                + "Service Auth policy for this Access application, or turn off "
                + "\"Use Cloudflare Access service token\" to sign in interactively."
        case .sessionTicketFailure:
            return "Signing in succeeded, but Conduit could not start a Hermes session. The dashboard may be busy, restarting, or it did not accept the new session — try again."
        case .dashboardUnavailable:
            return "The dashboard is reachable but reported a server error. It may be restarting or unhealthy — try again in a moment."
        case .unexpectedServerResponse:
            return "The dashboard responded in a way Conduit didn’t expect. Make sure the address points at a Hermes dashboard."
        case .unknown:
            return "Something went wrong while connecting to the dashboard. Try again."
        }
    }

    /// Where Troubleshoot Connection should land. `nil` where help would be
    /// misleading (unknown failures) — no action is offered in that case.
    var helpDestination: ConnectionHelpDestination? {
        switch self {
        case .invalidAddress: return .start
        case .insecureTransport: return .dashboard
        case .hostNotFound, .unreachable, .connectionRefused, .timedOut, .offline: return .network
        case .tlsUntrusted, .tlsBadDate, .tlsFailure: return .tls
        case .authenticationRejected: return .credentials
        case .rateLimited: return nil
        case .loginRequired: return nil
        case .cloudflareTokenRejected: return .cloudflare
        case .sessionTicketFailure, .dashboardUnavailable, .unexpectedServerResponse: return .dashboard
        case .unknown: return nil
        }
    }
}
