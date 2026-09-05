//
//  ConnectionFailureTests.swift
//  Conduit
//
//  Unit coverage for the login connection-failure classification and
//  presentation layer. Classification must be driven by real error types
//  and Foundation error codes — never by localized-description text.
//

import XCTest
@testable import Conduit

final class ConnectionFailureTests: XCTestCase {
    // MARK: - URL policy failures (real throw path)

    func testMalformedURLClassifiesAsInvalidAddressPresentation() {
        do {
            _ = try ConnectionURLPolicy.normalizedBaseURL("not a dashboard url")
            return XCTFail("Expected malformed URL to be rejected")
        } catch {
            let failure = ConnectionFailureClassifier.classify(error)
            XCTAssertEqual(failure, .invalidAddress)
            let presentation = ConnectionFailurePresentation.presenting(failure)
            XCTAssertEqual(presentation.title, "Check the dashboard address")
            XCTAssertFalse(presentation.message.isEmpty)
            XCTAssertEqual(presentation.helpDestination, .start)
            XCTAssertTrue(presentation.offersRecoveryActions)
        }
    }

    func testForbiddenRemoteHTTPClassifiesAsInsecureTransportPresentation() {
        do {
            _ = try ConnectionURLPolicy.normalizedBaseURL("http://203.0.113.10:9119")
            return XCTFail("Expected remote plain HTTP to be rejected")
        } catch {
            let failure = ConnectionFailureClassifier.classify(error)
            XCTAssertEqual(failure, .insecureTransport)
            let presentation = ConnectionFailurePresentation.presenting(failure)
            XCTAssertEqual(presentation.title, "Insecure dashboard address")
            // The message must explain the HTTPS rule without recommending
            // opening firewall ports.
            XCTAssertTrue(presentation.message.contains("HTTPS"))
            XCTAssertFalse(
                presentation.message.lowercased().contains("firewall"),
                "Insecure-transport guidance must not suggest opening ports"
            )
            XCTAssertEqual(presentation.helpDestination, .dashboard)
        }
    }

    func testLocalHTTPRemainsAllowedByPolicy() {
        // The transport policy itself must not be broadened or narrowed by
        // the classification work.
        XCTAssertNoThrow(try ConnectionURLPolicy.normalizedBaseURL("http://127.0.0.1:9119"))
        XCTAssertNoThrow(try ConnectionURLPolicy.normalizedBaseURL("http://192.168.1.42:9119"))
        XCTAssertNoThrow(try ConnectionURLPolicy.normalizedBaseURL("http://100.64.0.10"))
    }

    // MARK: - URLError codes (real Foundation codes)

    func testCannotFindHostClassifiesAsHostNotFoundWithNetworkHelp() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(URLError(.cannotFindHost))
        )
        XCTAssertEqual(presentation.title, "Dashboard not found")
        XCTAssertEqual(presentation.helpDestination, .network)
        XCTAssertTrue(presentation.offersRecoveryActions)
    }

    func testDNSLookupFailureClassifiesAsHostNotFound() {
        XCTAssertEqual(ConnectionFailureClassifier.classify(URLError(.dnsLookupFailed)), .hostNotFound)
    }

    func testCannotConnectToHostClassifiesAsRefusedStylePresentation() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(URLError(.cannotConnectToHost))
        )
        XCTAssertEqual(presentation.title, "Couldn’t reach Hermes")
        XCTAssertEqual(
            presentation.message,
            "Conduit could not connect to the dashboard at this address. Make sure the dashboard is running and that this device can reach it."
        )
        XCTAssertEqual(presentation.helpDestination, .network)
    }

    func testTimedOutClassifiesAsTimeoutPresentation() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(URLError(.timedOut))
        )
        XCTAssertEqual(presentation.title, "Connection timed out")
        XCTAssertEqual(presentation.helpDestination, .network)
    }

    func testNotConnectedToInternetClassifiesAsOffline() {
        XCTAssertEqual(ConnectionFailureClassifier.classify(URLError(.notConnectedToInternet)), .offline)
    }

    func testNetworkConnectionLostClassifiesAsUnreachable() {
        XCTAssertEqual(ConnectionFailureClassifier.classify(URLError(.networkConnectionLost)), .unreachable)
    }

    func testCertificateUntrustedClassifiesAsTLSTrustPresentation() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(URLError(.serverCertificateUntrusted))
        )
        XCTAssertEqual(presentation.title, "Secure connection failed")
        XCTAssertTrue(
            presentation.message.contains("iOS does not trust its TLS certificate"),
            "Untrusted-certificate copy must point at trust/installation guidance"
        )
        XCTAssertEqual(presentation.helpDestination, .tls)
    }

    func testCertificateUnknownRootClassifiesAsTLSUntrusted() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(URLError(.serverCertificateHasUnknownRoot)),
            .tlsUntrusted
        )
    }

    func testCertificateBadDateClassifiesAsCertificateDatePresentation() {
        let badDateCodes: [URLError.Code] = [.serverCertificateHasBadDate, .serverCertificateNotYetValid]
        for code in badDateCodes {
            let presentation = ConnectionFailurePresentation.presenting(
                ConnectionFailureClassifier.classify(URLError(code))
            )
            XCTAssertEqual(presentation.title, "Certificate date problem")
            XCTAssertTrue(presentation.message.contains("expired or not yet valid"))
            XCTAssertEqual(presentation.helpDestination, .tls)
        }
    }

    func testGenericSecureConnectionFailedClassifiesAsGenericTLSPresentation() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(URLError(.secureConnectionFailed))
        )
        XCTAssertEqual(presentation.title, "Secure connection failed")
        XCTAssertNotEqual(presentation.message, URLError(.secureConnectionFailed).localizedDescription)
        XCTAssertEqual(presentation.helpDestination, .tls)
    }

    func testBridgedNSURLErrorDomainNSErrorClassifiesByCode() {
        // URLSession can deliver transport failures as NSError values; the
        // classifier must recover the code instead of degrading to unknown.
        let bridged = NSError(
            domain: NSURLErrorDomain,
            code: URLError.Code.cannotFindHost.rawValue
        )
        XCTAssertEqual(ConnectionFailureClassifier.classify(bridged), .hostNotFound)
    }

    // MARK: - Authentication stages

    func testPasswordAuth401ClassifiesAsAuthenticationRejectedWithCredentialsHelp() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(
                AuthClientError.loginFailed(status: 401, detail: "HTTP 401")
            )
        )
        XCTAssertEqual(presentation.title, "Login failed")
        XCTAssertEqual(
            presentation.message,
            "Hermes rejected that username or password. Check your dashboard credentials and try again."
        )
        XCTAssertFalse(presentation.message.contains("HTTP 401"), "Raw status must not be the user-facing message")
        XCTAssertEqual(presentation.helpDestination, .credentials)
    }

    func testPasswordAuth403ClassifiesAsAuthenticationRejected() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(AuthClientError.loginFailed(status: 403, detail: "Forbidden")),
            .authenticationRejected
        )
    }

    func testPasswordAuthServerErrorIsNotPresentedAsBadCredentials() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(
                AuthClientError.loginFailed(status: 503, detail: "HTTP 503")
            )
        )
        XCTAssertEqual(presentation.title, "Dashboard unavailable")
        XCTAssertEqual(presentation.helpDestination, .dashboard)
        XCTAssertFalse(presentation.message.contains("password"))
    }

    func testTicketStageFailureIsNeverPresentedAsBadCredentials() {
        // Even a 401 at the ticket stage: the password was already accepted,
        // so credentials guidance would be wrong. 429 stays distinct too —
        // the ticket endpoint is not the rate-limited login endpoint.
        for status in [401, 429, 500, 502] {
            let presentation = ConnectionFailurePresentation.presenting(
                ConnectionFailureClassifier.classify(
                    AuthClientError.ticketFailed(status: status, detail: "HTTP \(status)")
                )
            )
            XCTAssertEqual(presentation.title, "Could not start the session")
            XCTAssertNotEqual(presentation.helpDestination, .credentials)
            XCTAssertFalse(presentation.message.lowercased().contains("username or password"))
        }
    }

    // MARK: - Password-login rate limiting (HTTP 429)

    func testPasswordAuth429ClassifiesAsRateLimited() {
        let failure = ConnectionFailureClassifier.classify(
            AuthClientError.loginFailed(status: 429, detail: "Too many login attempts. Try again shortly.")
        )
        XCTAssertEqual(failure, .rateLimited)
    }

    func testRateLimitedPresentationIsStableCopyWithoutCredentialBlame() {
        let presentation = ConnectionFailurePresentation.presenting(.rateLimited)
        XCTAssertEqual(presentation.title, "Too many login attempts")
        XCTAssertEqual(
            presentation.message,
            "Hermes temporarily blocked additional login attempts. Wait about a minute before trying again."
        )
        XCTAssertFalse(
            presentation.message.lowercased().contains("username"),
            "Rate limiting must not be presented as wrong credentials"
        )
        XCTAssertFalse(
            presentation.message.lowercased().contains("password"),
            "Rate limiting must not be presented as wrong credentials"
        )
        XCTAssertNil(presentation.helpDestination)
    }

    func testRateLimitedPresentationOffersNoImmediateRetryAction() {
        // A Try Again button would encourage exactly the rapid retry Hermes
        // just throttled; the copy alone must carry the "wait" guidance.
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(
                AuthClientError.loginFailed(status: 429, detail: "Too many login attempts")
            )
        )
        XCTAssertFalse(presentation.offersRecoveryActions)
    }

    func testTicketStage429DoesNotAdoptRateLimitedLoginCopy() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(
                AuthClientError.ticketFailed(status: 429, detail: "HTTP 429")
            )
        )
        XCTAssertEqual(presentation.title, "Could not start the session")
        XCTAssertNotEqual(presentation.title, "Too many login attempts")
    }

    func testAuthClient429ErrorDescriptionDoesNotBlameCredentials() {
        let description = AuthClientError.loginFailed(
            status: 429,
            detail: "Too many login attempts. Try again shortly."
        ).errorDescription
        XCTAssertEqual(description, "Too many login attempts. Try again shortly.")
    }

    func testPasswordAuth401And403RemainAuthenticationRejectedNextToRateLimiting() {
        // The 429 branch must not swallow the genuine credential rejections.
        for status in [401, 403] {
            XCTAssertEqual(
                ConnectionFailureClassifier.classify(
                    AuthClientError.loginFailed(status: status, detail: "HTTP \(status)")
                ),
                .authenticationRejected
            )
        }
    }

    func testProviderDiscoveryFailureDoesNotImplyBadCredentials() {
        // A 401/403 during provider discovery is a misrouted or odd
        // deployment, not evidence the credentials are wrong.
        for status in [401, 403, 404] {
            let presentation = ConnectionFailurePresentation.presenting(
                ConnectionFailureClassifier.classify(
                    AuthClientError.providerDiscoveryFailed(status: status, detail: "HTTP \(status)")
                )
            )
            XCTAssertEqual(presentation.title, "Unexpected response")
            XCTAssertNotEqual(presentation.helpDestination, .credentials)
        }
    }

    func testProviderDiscoveryServerErrorClassifiesAsDashboardUnavailable() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(
                AuthClientError.providerDiscoveryFailed(status: 500, detail: "boom")
            )
        )
        XCTAssertEqual(presentation.title, "Dashboard unavailable")
        XCTAssertEqual(presentation.helpDestination, .dashboard)
    }

    func testProviderDiscovery429AlsoClassifiesAsRateLimited() {
        // The documented throttle targets /auth/password-login, but a 429
        // from any auth endpoint is a throttle, never bad credentials.
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(
                AuthClientError.providerDiscoveryFailed(status: 429, detail: "HTTP 429")
            )
        )
        XCTAssertEqual(presentation.title, "Too many login attempts")
        XCTAssertNotEqual(presentation.helpDestination, .credentials)
    }

    func testDiscoveryWithoutHTTPResponseClassifiesAsUnexpectedServerResponse() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(
                AuthClientError.providerDiscoveryFailed(status: nil, detail: "No response")
            ),
            .unexpectedServerResponse
        )
    }

    func testCloudflareTokenRejectionPreservesSpecializedGuidance() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(AuthClientError.cloudflareServiceTokenRejected)
        )
        XCTAssertEqual(presentation.title, "Cloudflare rejected the service token")
        XCTAssertTrue(presentation.message.contains("Client ID / Secret"))
        XCTAssertTrue(presentation.message.contains("Service Auth policy"))
        XCTAssertTrue(presentation.message.contains("sign in interactively"))
        XCTAssertEqual(presentation.helpDestination, .cloudflare)
    }

    func testAuthInvalidURLClassifiesAsInvalidAddress() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(AuthClientError.invalidURL),
            .invalidAddress
        )
    }

    // MARK: - Unknown errors degrade gracefully

    func testUnknownErrorDegradesGracefullyWithoutDebugCopy() {
        struct OpaqueError: Error {}

        let raw = OpaqueError()
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(raw)
        )

        XCTAssertEqual(ConnectionFailureClassifier.classify(raw), .unknown)
        XCTAssertNil(presentation.helpDestination, "Unknown failures must not invent a misleading help destination")
        XCTAssertFalse(presentation.title.isEmpty)
        XCTAssertFalse(presentation.message.isEmpty)
        XCTAssertNotEqual(presentation.message, String(describing: raw))
    }

    func testUnknownURLErrorCodeHasNoHelpDestination() {
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(URLError(.unknown))
        )
        XCTAssertEqual(presentation.title, "Couldn’t connect")
        XCTAssertNil(presentation.helpDestination)
    }

    // MARK: - Presentation models

    func testValidationNoticeOffersNoRecoveryActions() {
        let notice = ConnectionFailurePresentation.notice(title: "Enter your dashboard username and password.")
        XCTAssertEqual(notice.title, "Enter your dashboard username and password.")
        XCTAssertTrue(notice.message.isEmpty)
        XCTAssertNil(notice.helpDestination)
        XCTAssertFalse(notice.offersRecoveryActions)
    }

    func testConnectionFailurePresentationCarriesDestinationAndActions() {
        let presentation = ConnectionFailurePresentation.presenting(.timedOut)
        XCTAssertTrue(presentation.offersRecoveryActions)
        XCTAssertEqual(presentation.helpDestination, .network)
        XCTAssertEqual(presentation.title, "Connection timed out")
    }
}
