//
//  ConnectionFailureTests.swift
//  Conduit
//
//  Unit coverage for the login connection-failure classification and
//  presentation layer. Classification must be driven by real error types
//  and Foundation error codes — never by localized-description text.
//

import Security
import XCTest
@testable import Conduit

final class ConnectionFailureTests: XCTestCase {
    // MARK: - Native sign-in page

    func testNativeSignInBrowserFailureClassifiesAsSignInPageFailed() {
        let failure = ConnectionFailureClassifier.classify(NativeOAuthError.browserFailed)
        XCTAssertEqual(failure, .signInPageFailed)
        XCTAssertEqual(failure.userTitle, "Sign-in page didn’t open")
        XCTAssertEqual(failure.userMessage, "The sign-in page couldn’t open. Please try again.")
        XCTAssertNil(failure.helpDestination)
    }

    func testNativeSignInFailuresNeverClaimBadCredentials() {
        XCTAssertEqual(ConnectionFailureClassifier.classify(NativeOAuthError.requestFailed(status: 401)), .unexpectedServerResponse)
        XCTAssertEqual(ConnectionFailureClassifier.classify(NativeOAuthError.requestFailed(status: 503)), .dashboardUnavailable)
        XCTAssertEqual(ConnectionFailureClassifier.classify(NativeOAuthError.tokenResponseMalformed), .unexpectedServerResponse)
        XCTAssertEqual(ConnectionFailureClassifier.classify(NativeOAuthError.timedOut), .unknown)
    }

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

    func testBadURLClassifiesAsInvalidAddress() {
        XCTAssertEqual(ConnectionFailureClassifier.classify(URLError(.badURL)), .invalidAddress)
    }

    func testATSErrorClassifiesAsInsecureTransport() {
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(URLError(.appTransportSecurityRequiresSecureConnection)),
            .insecureTransport
        )
    }

    func testOfflineFamilyCodesClassifyAsOffline() {
        // notConnectedToInternet is covered above; pin the rest of the family.
        XCTAssertEqual(ConnectionFailureClassifier.classify(URLError(.dataNotAllowed)), .offline)
        XCTAssertEqual(ConnectionFailureClassifier.classify(URLError(.internationalRoamingOff)), .offline)
    }

    func testBadServerResponseClassifiesAsUnexpectedServerResponse() {
        // NativeAuthClient.perform throws this when no usable response
        // arrives; it must not degrade to the unknown bucket.
        XCTAssertEqual(ConnectionFailureClassifier.classify(URLError(.badServerResponse)), .unexpectedServerResponse)
    }

    func testRefusedDashboardSocketUpgradesClassifyAsSignInNeverCredentials() {
        // A refused upgrade is remedied by a sign-in in a browser, never by
        // retyping a password.
        for error in [DashboardSocketHandshakeError.browserSessionRequired(status: 302)] {
            XCTAssertEqual(ConnectionFailureClassifier.classify(error), .loginRequired, "\(error)")
            XCTAssertNotEqual(ConnectionFailurePresentation.presenting(ConnectionFailureClassifier.classify(error)).helpDestination, .credentials)
        }
    }

    func testRefusedUpgradeStatusIsTypedOnlyWhenItSaysSomething() {
        let dashboard = "http://dashboard.example.test:9119"
        func failure(_ status: Int?, _ target: String?) -> DashboardSocketHandshakeError? {
            DashboardSocketHandshakeError.failure(status: status, redirectTarget: target.flatMap(URL.init(string:)), dashboardURL: dashboard)
        }
        // A redirect to a sign-in: another origin, or a sign-in page on the
        // dashboard's own.
        XCTAssertEqual(failure(302, "https://sso.example.test/authorize"), .browserSessionRequired(status: 302))
        XCTAssertEqual(failure(302, "http://dashboard.example.test:9119/oauth2/sign_in?rd=%2Fapi%2Fws"), .browserSessionRequired(status: 302))
        XCTAssertEqual(failure(307, "https://dashboard.example.test/login"), .browserSessionRequired(status: 307))
        // A same-origin redirect to an ordinary address, the same host moved
        // to wss/https, or no target at all: the reconnect path.
        XCTAssertNil(failure(307, "ws://dashboard.example.test:9119/other/ws"))
        XCTAssertNil(failure(301, "wss://dashboard.example.test/api/ws"))
        XCTAssertNil(failure(302, nil))
        // A 401/403 says nothing about an account: Hermes answers a spent
        // ticket with 403.
        XCTAssertNil(failure(401, nil))
        XCTAssertNil(failure(403, nil))
        XCTAssertNil(failure(502, nil))
        XCTAssertNil(failure(nil, nil))
    }

    func testCancelledURLErrorClassifiesAsUnknownNotCredentials() {
        // LoginView intercepts CancellationError before classification (and
        // NativeAuthClient converts URLError.cancelled into CancellationError),
        // so a cancelled transport that ever escaped would land here: generic
        // copy, never a credentials or rate-limit claim. This pins that.
        let presentation = ConnectionFailurePresentation.presenting(
            ConnectionFailureClassifier.classify(URLError(.cancelled))
        )
        XCTAssertEqual(presentation.title, "Couldn’t connect")
        XCTAssertNotEqual(presentation.helpDestination, .credentials)
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

    func testFailedTrustChecksNameTheMostSpecificTLSFailure() {
        XCTAssertEqual(TLSTrustDiagnosis.failure(forFailedChecks: ["SSLHostname", "AnchorTrusted"]), .tlsHostnameMismatch)
        XCTAssertEqual(TLSTrustDiagnosis.failure(forFailedChecks: ["ValidityPeriodMaximums", "AnchorTrusted"]), .tlsNotStandardsCompliant)
        XCTAssertEqual(TLSTrustDiagnosis.failure(forFailedChecks: ["ExtendedKeyUsage"]), .tlsNotStandardsCompliant)
        XCTAssertEqual(TLSTrustDiagnosis.failure(forFailedChecks: ["TemporalValidity"]), .tlsBadDate)
        XCTAssertEqual(TLSTrustDiagnosis.failure(forFailedChecks: ["AnchorTrusted"]), .tlsUntrusted)
        XCTAssertNil(TLSTrustDiagnosis.failure(forFailedChecks: []))
    }

    func testPeerTrustOnTheErrorNamesAWrongAddress() throws {
        let trust = try Self.evaluatedTrust(hostname: "192.168.1.28")
        let error = URLError(.serverCertificateUntrusted, userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: trust])
        let failure = ConnectionFailureClassifier.classify(error)
        XCTAssertEqual(failure, .tlsHostnameMismatch)
        XCTAssertEqual(failure.helpDestination, .tls)
        XCTAssertEqual(ConnectionFailurePresentation.presenting(failure).title, "Certificate doesn’t match the address")
    }

    func testPeerTrustWithTheRightNameStaysUntrusted() throws {
        let trust = try Self.evaluatedTrust(hostname: "hermes.home.arpa")
        let bridged = NSError(
            domain: NSURLErrorDomain,
            code: URLError.serverCertificateUntrusted.rawValue,
            userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: trust]
        )
        XCTAssertEqual(ConnectionFailureClassifier.classify(bridged), .tlsUntrusted)
    }

    func testPeerTrustAfterTheCertificateExpiredIsADateProblem() throws {
        let trust = try Self.evaluatedTrust(hostname: "hermes.home.arpa", on: Date(timeIntervalSince1970: 1830000000))
        let error = URLError(.serverCertificateUntrusted, userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: trust])
        XCTAssertEqual(ConnectionFailureClassifier.classify(error), .tlsBadDate)
    }

    func testPeerTrustWithAWeakKeyIsNotStandardsCompliant() throws {
        let trust = try Self.evaluatedTrust(hostname: "hermes.home.arpa", certificate: Self.weakKeyCertificate)
        let error = URLError(.serverCertificateUntrusted, userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: trust])
        XCTAssertEqual(ConnectionFailureClassifier.classify(error), .tlsNotStandardsCompliant)
    }

    /// The same as `certificate` with a 1024-bit RSA key, below Apple's
    /// 2048-bit minimum.
    private static let weakKeyCertificate =
        "MIICRjCCAa+gAwIBAgIUZX74TVd1dVUBVU4lCZpyoKhJ3TowDQYJKoZIhvcNAQELBQAwGzEZMBcG" +
        "A1UEAwwQaGVybWVzLmhvbWUuYXJwYTAeFw0yNjEwMjcyMjUzMTlaFw0yNzEwMjcyMjUzMTlaMBsx" +
        "GTAXBgNVBAMMEGhlcm1lcy5ob21lLmFycGEwgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBANs7" +
        "oerFw5oAfn+LXaXlT8GXUNzWVqliq044ozJ2mEPECUHKRfASsDnXopy1XyY0UZvx5t/lDdz9D/Wc" +
        "Mu6dJqUNqM/HzZGDT7zXi7xlkSLeBMee37vsM9v68ikOfeSiq2pY8qTgrUNz7S5wKkEd6W6KnuV9" +
        "ZFv6WMOljJvxaqFLAgMBAAGjgYYwgYMwHQYDVR0OBBYEFNnXDUX3LitLN0bYqHssxM9zXVfrMB8G" +
        "A1UdIwQYMBaAFNnXDUX3LitLN0bYqHssxM9zXVfrMA8GA1UdEwEB/wQFMAMBAf8wGwYDVR0RBBQw" +
        "EoIQaGVybWVzLmhvbWUuYXJwYTATBgNVHSUEDDAKBggrBgEFBQcDATANBgkqhkiG9w0BAQsFAAOB" +
        "gQADryXpuOqwRyPEreaXCNfJJ3gU4StW+5sWSxTu7nnV/TZrvXdmBNxYnN5XKnP7q0/mPgbQ5hM3" +
        "GJO4sHxTZkr9+w8ZszSX2RrAFQj4sicBKALHuzwELYAt4R2U58RjJAQGkaIsUQ6EDquQelQa6sLG" +
        "o4qwQkdsPK+H/W3lgNfKxg=="

    /// A self-signed certificate for hermes.home.arpa (one year, serverAuth),
    /// evaluated on a day inside its validity, so only the anchor and, for
    /// another address, the name fail.
    private static let certificate =
        "MIIDSzCCAjOgAwIBAgIUbQ5H1KF/cv+y+qpxtm1fYzTo6UgwDQYJKoZIhvcNAQELBQAwGzEZMBcG" +
        "A1UEAwwQaGVybWVzLmhvbWUuYXJwYTAeFw0yNjEwMjcyMjQzMjNaFw0yNzEwMjcyMjQzMjNaMBsx" +
        "GTAXBgNVBAMMEGhlcm1lcy5ob21lLmFycGEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB" +
        "AQCn8FAFlVnkm3yoeUtOPzIaCh5YqNWQGCm/lVqxUoX+SyhmQ/KqAfTo1mCwZLz0fJ5Z7ns5Q3hC" +
        "b02wNTR4tiMeY5H5fSR3WJv8atumhA+ElG9jdjKevcC0LbNRowPqEQ+o9uH3Xs+RsgEbknOIOohH" +
        "One9mYMx/UxCoi6YHVtAI72tpqLIqfpCl6GGZhMcLelvZMefw5oaLze4Z3JEOJe+KHMt2XVoYSAy" +
        "b9CLCDaAoA6MfK0PcxIH8ARwAcCNZkvGPxpM54j35DqCVK/L1ZMVXDv1ZDdUv+LN44iiNLx60UK8" +
        "jfiV0AGGXhbDd+VMxsEa8NKg/TmmHvy56l3CX28DAgMBAAGjgYYwgYMwHQYDVR0OBBYEFHOE5PWP" +
        "YymjHn5/sQHHv9fancasMB8GA1UdIwQYMBaAFHOE5PWPYymjHn5/sQHHv9fancasMA8GA1UdEwEB" +
        "/wQFMAMBAf8wGwYDVR0RBBQwEoIQaGVybWVzLmhvbWUuYXJwYTATBgNVHSUEDDAKBggrBgEFBQcD" +
        "ATANBgkqhkiG9w0BAQsFAAOCAQEAGjttsf+A0gisH98+TYGYSC6oLO7RyfcqZ4eTEQUfoQH87mhN" +
        "A8e/DAuo0xrG0bWvDTCKPAPzzVpuaHZmrsdBfQuWtsLHdvyaZg3PgPST8rKoFWoWFzCi5nAbWr/b" +
        "j18nkumUTjH1Mz8sCbUS8Pq7JIFfUpJNa3a2trao9EpUFlD4LrTF4GUnw8hx/CFuJnUKjA//i9qG" +
        "li7/gv0skSi3DfG3E0XFZc1d8hs4S2wkyOWBabyFc5UTJZ1muKuxDs6yq7oBkyN/ygGTOox2TlaS" +
        "7bcXGUqhpE+KZZOnVnR5ZQgKlW8gyT4YFLELv1cf7xA9+3wxNHlB4YM+ep1Jp4Smbg=="

    private static func evaluatedTrust(
        hostname: String, certificate base64: String = certificate,
        on day: Date = Date(timeIntervalSince1970: 1793145600)
    ) throws -> SecTrust {
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, hostname as CFString), &trust), errSecSuccess)
        let evaluated = try XCTUnwrap(trust)
        SecTrustSetVerifyDate(evaluated, day as CFDate)
        XCTAssertFalse(SecTrustEvaluateWithError(evaluated, nil))
        return evaluated
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

    func testProviderDiscovery429DoesNotAdoptLoginCooldownPresentation() {
        // Only /auth/password-login is throttled by Hermes (10/60s/IP). A 429
        // from provider discovery is unexpected server behavior — not a login
        // cooldown — and retrying it consumes no password-login budget, so
        // the login-cooldown presentation (no actions) must not apply.
        let failure = ConnectionFailureClassifier.classify(
            AuthClientError.providerDiscoveryFailed(status: 429, detail: "HTTP 429")
        )
        XCTAssertEqual(failure, .unexpectedServerResponse)
        let presentation = ConnectionFailurePresentation.presenting(failure)
        XCTAssertEqual(presentation.title, "Unexpected response")
        XCTAssertNotEqual(presentation.title, "Too many login attempts")
        XCTAssertFalse(presentation.message.contains("Wait about a minute"))
        XCTAssertTrue(presentation.offersRecoveryActions)
    }

    func testPasswordLogin429StillAdoptsLoginCooldownPresentation() {
        // The stage-gating above must not dilute the real throttled endpoint.
        let failure = ConnectionFailureClassifier.classify(
            AuthClientError.loginFailed(status: 429, detail: "Too many login attempts. Try again shortly.")
        )
        XCTAssertEqual(failure, .rateLimited)
        let presentation = ConnectionFailurePresentation.presenting(failure)
        XCTAssertEqual(presentation.title, "Too many login attempts")
        XCTAssertFalse(presentation.offersRecoveryActions)
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
        // Try-only behavior: recovery actions render, but no Troubleshoot
        // button without a trustworthy destination.
        XCTAssertTrue(presentation.offersRecoveryActions)
        XCTAssertNil(presentation.helpDestination)
    }

    func testAuthClientNoResponseLoginFailureDoesNotBlameCredentials() {
        let description = AuthClientError.loginFailed(
            status: nil,
            detail: "No response"
        ).errorDescription
        XCTAssertFalse(
            description?.lowercased().contains("credentials") ?? true,
            "A no-response login failure must not read as a credentials problem"
        )
    }

    // MARK: - AuthWebView failure routing (fixed classified copy)

    func testAuthWebViewTicketFailurePresentationIsFixedClassifiedCopy() {
        // The dashboard controls the ticket-payload text (payload["error"]).
        // The login card must render only Conduit's fixed session-ticket
        // copy — the exact-equality assertions break if payload text is ever
        // interpolated into the presentation again.
        let presentation = ConnectionFailurePresentation.presenting(.sessionTicketFailure)
        XCTAssertEqual(presentation.title, "Could not start the session")
        XCTAssertEqual(
            presentation.message,
            "Signing in succeeded, but Conduit could not start a Hermes session. The dashboard may be busy, restarting, or it did not accept the new session — try again."
        )
        XCTAssertEqual(presentation.helpDestination, .dashboard)
        XCTAssertTrue(presentation.offersRecoveryActions)
    }

    func testAuthWebViewNormalizationFailureClassifiesAsInvalidAddress() {
        // AuthWebView's request-construction failures classify through the
        // same ConnectionURLPolicyError mapping as the login form.
        XCTAssertEqual(
            ConnectionFailureClassifier.classify(ConnectionURLPolicyError.invalidURL),
            .invalidAddress
        )
        XCTAssertEqual(
            ConnectionFailurePresentation.presenting(.invalidAddress).title,
            "Check the dashboard address"
        )
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
