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
import Security

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
    /// The certificate chain may be trusted, but the certificate doesn't
    /// name the address Conduit connected to (an IP typed where the
    /// certificate lists a name, or the other way round).
    case tlsHostnameMismatch
    /// iOS refuses the server certificate itself whatever authority issued
    /// it: Apple's TLS certificate rules (validity, extended key usage, key
    /// size, signature hash).
    case tlsNotStandardsCompliant

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
    /// The native sign-in's page (ASWebAuthenticationSession) failed or
    /// didn't start. Not a cancellation: the user didn't close it.
    case signInPageFailed

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
        if let nativeError = error as? NativeOAuthError {
            return classify(nativeError)
        }
        if error is DashboardSignInError {
            // Discovery answered, but with no sign-in Conduit can use.
            return .unexpectedServerResponse
        }
        if let handshakeError = error as? DashboardSocketHandshakeError {
            return classify(handshakeError)
        }
        // URLSession surfaces transport failures as NSError values in the
        // NSURLErrorDomain (e.g. injected through URLProtocol test seams).
        // Recover the typed error so classification stays code-based even
        // for bridged errors.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return classify(URLError(URLError.Code(rawValue: nsError.code), userInfo: nsError.userInfo))
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
        case .notReady, .answeredAfterSwitch, .requestFailed, .oversizedResponse:
            return .unexpectedServerResponse
        }
    }

    /// Native (PKCE) sign-in failures, so Repair's Sign In to Reconnect and
    /// Settings' Sign In Again name them as the login screen does. Its
    /// requests are discovery-like: a 401/403 is never bad credentials.
    static func classify(_ nativeError: NativeOAuthError) -> ConnectionFailure {
        switch nativeError {
        case .browserFailed:
            return .signInPageFailed
        case .requestFailed(let status):
            return classifyHTTPStatus(status, stage: .providerDiscovery)
        case .invalidURL, .callbackMalformed, .stateMismatch, .tokenResponseMalformed:
            return .unexpectedServerResponse
        case .randomGenerationFailed, .listenerFailed, .callbackRejected, .tokenStorageFailed, .timedOut:
            return .unknown
        }
    }

    /// A refused dashboard WebSocket upgrade: the server wants a browser
    /// sign-in first (3xx). The remedy is a sign-in, never a password.
    static func classify(_ handshakeError: DashboardSocketHandshakeError) -> ConnectionFailure {
        switch handshakeError {
        case .browserSessionRequired:
            return .loginRequired
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
            return TLSTrustDiagnosis.failure(for: urlError) ?? .tlsBadDate
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            return TLSTrustDiagnosis.failure(for: urlError) ?? .tlsUntrusted
        case .secureConnectionFailed:
            return TLSTrustDiagnosis.failure(for: urlError) ?? .tlsFailure
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

/// Names which check iOS failed on a refused server certificate (issue
/// #129), so the copy can say "wrong name" or "rules iOS won't accept"
/// instead of a blanket "not trusted". Reads the peer trust URLSession left
/// on the error, already evaluated by the system; nothing here changes what
/// is accepted.
enum TLSTrustDiagnosis {
    /// Security's policy check names, as they appear in a trust result's
    /// per-certificate details.
    static let hostnameChecks: Set<String> = ["SSLHostname"]
    static let standardsChecks: Set<String> = [
        "ValidityPeriodMaximums", "SystemTrustValidityPeriod", "ExtendedKeyUsage",
        "KeySize", "WeakKeySize", "SystemTrustedWeakKey",
        "SignatureHashAlgorithms", "WeakSignature", "SystemTrustedWeakHash"
    ]
    static let dateChecks: Set<String> = ["TemporalValidity"]

    static func failure(for urlError: URLError) -> ConnectionFailure? {
        guard let value = (urlError as NSError).userInfo[NSURLErrorFailingURLPeerTrustErrorKey] else {
            return nil
        }
        let object = value as CFTypeRef
        // A CF type can't be checked with `as?` (it always succeeds), so the
        // type ID is the check and the cast after it can't fail.
        guard CFGetTypeID(object) == SecTrustGetTypeID() else { return nil }
        return failure(for: object as! SecTrust)
    }

    /// The trust is read as already evaluated; SecTrustCopyResult doesn't
    /// go back to the network for one that has been.
    static func failure(for trust: SecTrust) -> ConnectionFailure? {
        guard let result = SecTrustCopyResult(trust) as? [String: Any],
              let details = result["TrustResultDetails"] as? [[String: Any]] else {
            return nil
        }
        return failure(forFailedChecks: Set(details.flatMap { $0.keys }))
    }

    /// The most specific failure first: a wrong name or a certificate iOS
    /// refuses outright is the fix to make even when the root is also
    /// untrusted, since trusting the root wouldn't be enough.
    static func failure(forFailedChecks checks: Set<String>) -> ConnectionFailure? {
        guard !checks.isEmpty else { return nil }
        if !checks.isDisjoint(with: hostnameChecks) { return .tlsHostnameMismatch }
        if !checks.isDisjoint(with: standardsChecks) { return .tlsNotStandardsCompliant }
        if !checks.isDisjoint(with: dateChecks) { return .tlsBadDate }
        return .tlsUntrusted
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
    /// Round 5: the Settings entry for an already-connected user. Skips the
    /// first-run readiness questions and seeds the wizard from the current
    /// configuration instead.
    case currentConnection
    /// Round 6: the Repair entry for a failed existing connection. Distinct
    /// from `.currentConnection` so Settings (things may be working) and
    /// failure recovery (a connection actually failed) never share one
    /// semantic: Repair seeds from the failed target, routes near the
    /// classified problem, and owns the Reconnect Now / Sign In to
    /// Reconnect actions.
    case repairConnection

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
    /// Typed failure when this presentation wraps a classified connection
    /// error. Nil for hand-authored notices — a notice is not proof of a
    /// specific ConnectionFailure (e.g. login required).
    let classifiedFailure: ConnectionFailure?

    /// Presentation for a classified connection failure, with recovery
    /// actions and the classified help destination. Rate limiting is the one
    /// exception: a "Try Again" button would encourage exactly the immediate
    /// retry Hermes just throttled, so it offers no actions at all.
    static func presenting(_ failure: ConnectionFailure) -> ConnectionFailurePresentation {
        ConnectionFailurePresentation(
            title: failure.userTitle,
            message: failure.userMessage,
            helpDestination: failure.helpDestination,
            offersRecoveryActions: failure != .rateLimited,
            classifiedFailure: failure
        )
    }

    /// The dashboard's sign-in ended under a connection that had worked:
    /// Hermes or the sign-in service in front of it (an auth proxy whose
    /// session the identity provider no longer renews) now sends Conduit to
    /// sign in. Says so plainly; the login card's primary action for it is
    /// Sign In Again, which opens the dashboard's own sign-in.
    static var signInExpired: ConnectionFailurePresentation {
        ConnectionFailurePresentation(
            title: AppLocalization.string("Your dashboard sign-in expired"),
            message: AppLocalization.string("Conduit was signed out of this dashboard, so it can’t reach Hermes. Sign in again to reconnect."),
            helpDestination: ConnectionFailure.loginRequired.helpDestination,
            offersRecoveryActions: true,
            classifiedFailure: .loginRequired
        )
    }

    /// Whether this presentation asks the user to sign in to the dashboard
    /// again (its session is gone), as opposed to fixing an address,
    /// network or password.
    var asksToSignInAgain: Bool { classifiedFailure == .loginRequired }

    /// A validation notice (form-state feedback, not a connection failure).
    /// No recovery actions: the fix is editing the form, not retrying.
    static func notice(title: String, message: String = "") -> ConnectionFailurePresentation {
        ConnectionFailurePresentation(
            title: title,
            message: message,
            helpDestination: nil,
            offersRecoveryActions: false,
            classifiedFailure: nil
        )
    }
}

// MARK: - User-facing copy

extension ConnectionFailure {
    var userTitle: String {
        switch self {
        case .invalidAddress: return AppLocalization.string("Check the dashboard address")
        case .insecureTransport: return AppLocalization.string("Insecure dashboard address")
        case .hostNotFound: return AppLocalization.string("Dashboard not found")
        case .unreachable, .connectionRefused: return AppLocalization.string("Couldn’t reach Hermes")
        case .timedOut: return AppLocalization.string("Connection timed out")
        case .offline: return AppLocalization.string("No network connection")
        case .tlsUntrusted: return AppLocalization.string("Secure connection failed")
        case .tlsBadDate: return AppLocalization.string("Certificate date problem")
        case .tlsFailure: return AppLocalization.string("Secure connection failed")
        case .tlsHostnameMismatch: return AppLocalization.string("Certificate doesn’t match the address")
        case .tlsNotStandardsCompliant: return AppLocalization.string("Certificate not accepted by iOS")
        case .authenticationRejected: return AppLocalization.string("Login failed")
        case .rateLimited: return AppLocalization.string("Too many login attempts")
        case .loginRequired: return AppLocalization.string("Sign-in required")
        case .cloudflareTokenRejected: return AppLocalization.string("Cloudflare rejected the service token")
        case .sessionTicketFailure: return AppLocalization.string("Could not start the session")
        case .signInPageFailed: return AppLocalization.string("Sign-in page didn’t open")
        case .dashboardUnavailable: return AppLocalization.string("Dashboard unavailable")
        case .unexpectedServerResponse: return AppLocalization.string("Unexpected response")
        case .unknown: return AppLocalization.string("Couldn’t connect")
        }
    }

    var userMessage: String {
        switch self {
        case .invalidAddress:
            return AppLocalization.string("That doesn’t look like a dashboard URL Conduit can use. Check it for typos — it should look like https://hermes.example.")
        case .insecureTransport:
            return AppLocalization.string("Remote dashboards must use HTTPS. Plain HTTP is only accepted for local addresses like localhost, private LAN IPs, and Tailscale.")
        case .hostNotFound:
            return AppLocalization.string("Conduit could not find that host. Check the dashboard address and try again.")
        case .unreachable, .connectionRefused:
            return AppLocalization.string("Conduit could not connect to the dashboard at this address. Make sure the dashboard is running and that this device can reach it.")
        case .timedOut:
            return AppLocalization.string("The dashboard did not respond in time. Check the address, the network connection, and whether the Hermes dashboard is running.")
        case .offline:
            return AppLocalization.string("This device doesn’t appear to have a network connection. Reconnect to Wi-Fi or cellular and try again.")
        case .tlsUntrusted:
            return AppLocalization.string("Conduit reached the server, but iOS does not trust its TLS certificate. If you use your own certificate authority, make sure its root certificate is installed and trusted on this device.")
        case .tlsBadDate:
            return AppLocalization.string("The dashboard certificate is expired or not yet valid. Check the certificate dates and this device’s date and time.")
        case .tlsFailure:
            return AppLocalization.string("Conduit could not establish a secure connection to the dashboard. The server’s TLS certificate may be misconfigured.")
        case .tlsHostnameMismatch:
            return AppLocalization.string("Conduit reached the server, but its TLS certificate isn’t issued for this address. Connect with a name or IP address the certificate lists, or add this address to the certificate.")
        case .tlsNotStandardsCompliant:
            return AppLocalization.string("iOS refuses this server certificate, whichever authority issued it. Apple requires a validity of 825 days or less, the serverAuth extended key usage, an RSA key of at least 2048 bits (or ECC 256 bits) and a SHA-2 signature.")
        case .authenticationRejected:
            return AppLocalization.string("Hermes rejected that username or password. Check your dashboard credentials and try again.")
        case .rateLimited:
            return AppLocalization.string("Hermes temporarily blocked additional login attempts. Wait about a minute before trying again.")
        case .loginRequired:
            return AppLocalization.string("Conduit needs you to sign in to the dashboard to reconnect.")
        case .cloudflareTokenRejected:
            return AppLocalization.string("Cloudflare Access did not accept the configured service token. Verify the Client ID / Secret and that the token is allowed by a Service Auth policy for this Access application, or turn off \"Use Cloudflare Access service token\" to sign in interactively.")
        case .sessionTicketFailure:
            return AppLocalization.string("Signing in succeeded, but Conduit could not start a Hermes session. The dashboard may be busy, restarting, or it did not accept the new session — try again.")
        case .signInPageFailed:
            return AppLocalization.string("The sign-in page couldn’t open. Please try again.")
        case .dashboardUnavailable:
            return AppLocalization.string("The dashboard is reachable but reported a server error. It may be restarting or unhealthy — try again in a moment.")
        case .unexpectedServerResponse:
            return AppLocalization.string("The dashboard responded in a way Conduit didn’t expect. Make sure the address points at a Hermes dashboard.")
        case .unknown:
            return AppLocalization.string("Something went wrong while connecting to the dashboard. Try again.")
        }
    }

    /// Where Troubleshoot Connection should land. `nil` where help would be
    /// misleading (unknown failures) — no action is offered in that case.
    var helpDestination: ConnectionHelpDestination? {
        switch self {
        case .invalidAddress: return .start
        case .insecureTransport: return .dashboard
        case .hostNotFound, .unreachable, .connectionRefused, .timedOut, .offline: return .network
        case .tlsUntrusted, .tlsBadDate, .tlsFailure, .tlsHostnameMismatch, .tlsNotStandardsCompliant: return .tls
        case .authenticationRejected: return .credentials
        case .rateLimited: return nil
        case .loginRequired: return nil
        case .signInPageFailed: return nil
        case .cloudflareTokenRejected: return .cloudflare
        case .sessionTicketFailure, .dashboardUnavailable, .unexpectedServerResponse: return .dashboard
        case .unknown: return nil
        }
    }
}
