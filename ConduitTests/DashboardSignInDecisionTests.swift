//
//  DashboardSignInDecisionTests.swift
//  Conduit
//
//  The shared sign-in mode decision: every discovery answer maps to exactly
//  one mode or error, the native capability seam is consulted only for a
//  native-capable provider (and, on a dashboard that also takes a password,
//  only once its browser sign-in is picked), and a failed capability answer
//  is an error, never a downgrade to password or the embedded browser.
//

import XCTest
@testable import Conduit

final class DashboardSignInDecisionTests: XCTestCase {
    private enum CapabilityFixture: Error { case serverError }

    /// Records how often the capability seam was consulted.
    private final class CapabilityProbe {
        var calls = 0
        let answer: Result<Bool, Error>

        init(_ answer: Result<Bool, Error>) {
            self.answer = answer
        }

        var resolver: DashboardSignInResolver {
            DashboardSignInResolver(supportsNativeOAuth: { [self] in
                calls += 1
                return try answer.get()
            })
        }
    }

    private let password: [String: Any] = ["name": "basic", "supports_password": true]
    private let selfHosted: [String: Any] = ["name": "self-hosted", "display_name": "Self-Hosted OIDC", "supports_password": false]
    private let google: [String: Any] = ["name": "google", "supports_password": false]
    /// Hermes before password sign-in listed providers without the field.
    private let legacy: [String: Any] = ["name": "nous", "display_name": "Nous Research"]

    private func mode(
        _ discovery: AuthProviderDiscoveryResult,
        capability: Result<Bool, Error> = .success(true)
    ) async throws -> (DashboardSignInMode, Int) {
        let probe = CapabilityProbe(capability)
        let mode = try await probe.resolver.mode(for: discovery)
        return (mode, probe.calls)
    }

    func testPasswordOnlyIsPasswordWithoutACapabilityRequest() async throws {
        let (mode, calls) = try await mode(.providers([password]))
        XCTAssertEqual(mode, .password)
        XCTAssertEqual(calls, 0, "A password-only dashboard has nothing native to ask about")
    }

    func testNativeCapableOAuthIsNativeOAuthWithThePinnedProvider() async throws {
        let (mode, calls) = try await mode(.providers([selfHosted]))
        XCTAssertEqual(mode, .interactive(.nativeOAuth(provider: "self-hosted")))
        XCTAssertEqual(calls, 1)
    }

    func testSeveralNativeProvidersLeaveTheChoiceToHermes() async throws {
        let (mode, _) = try await mode(.providers([selfHosted, google]))
        XCTAssertEqual(mode, .interactive(.nativeOAuth(provider: nil)))
    }

    func testOAuthWithoutNativeCapabilityIsLegacyBrowserSignIn() async throws {
        let (mode, calls) = try await mode(.providers([selfHosted]), capability: .success(false))
        XCTAssertEqual(mode, .interactive(.browser(.legacyOAuth)))
        XCTAssertEqual(calls, 1)
    }

    func testProvidersWithoutThePasswordFieldAreLegacyBrowserSignIn() async throws {
        let (mode, calls) = try await mode(.providers([legacy]))
        XCTAssertEqual(mode, .interactive(.browser(.legacyOAuth)))
        XCTAssertEqual(calls, 0, "Pre-password Hermes has no native capability to ask about")
    }

    func testMixedProvidersOfferAChoiceWithoutACapabilityRequest() async throws {
        // The password needs nothing from the capability check, so the
        // decision does not wait for it (or fail with it).
        let native = try await mode(.providers([password, selfHosted]))
        XCTAssertEqual(native.0, .passwordOrBrowser(.nativeCapable(provider: "self-hosted")))
        XCTAssertEqual(native.1, 0)
        let failing = try await mode(.providers([password, selfHosted]), capability: .failure(CapabilityFixture.serverError))
        XCTAssertEqual(failing.0, .passwordOrBrowser(.nativeCapable(provider: "self-hosted")))
        XCTAssertEqual(failing.1, 0)
        let legacyMix = try await mode(.providers([password, legacy]))
        XCTAssertEqual(legacyMix.0, .passwordOrBrowser(.legacyOAuth))
        XCTAssertEqual(legacyMix.1, 0)
    }

    func testPickingTheOfferedBrowserSignInRunsTheCapabilityCheckThen() async throws {
        let native = CapabilityProbe(.success(true))
        let opened = try await native.resolver.signIn(for: .nativeCapable(provider: "self-hosted"))
        XCTAssertEqual(opened, .nativeOAuth(provider: "self-hosted"))
        XCTAssertEqual(native.calls, 1)

        let older = CapabilityProbe(.success(false))
        let olderOpened = try await older.resolver.signIn(for: .nativeCapable(provider: "self-hosted"))
        XCTAssertEqual(olderOpened, .browser(.legacyOAuth))

        let legacyOffer = CapabilityProbe(.success(true))
        let legacyOpened = try await legacyOffer.resolver.signIn(for: .legacyOAuth)
        XCTAssertEqual(legacyOpened, .browser(.legacyOAuth))
        XCTAssertEqual(legacyOffer.calls, 0, "A pre-password provider has no native capability to ask about")
        XCTAssertEqual(DashboardBrowserSignInOffer.legacyOAuth.decidedSignIn, legacyOpened)
        XCTAssertNil(DashboardBrowserSignInOffer.nativeCapable(provider: nil).decidedSignIn)
    }

    func testCrossOriginRedirectIsAuthProxyBrowserSignInWithoutACapabilityRequest() async throws {
        let (mode, calls) = try await mode(.interactiveSignInRequired)
        XCTAssertEqual(mode, .interactive(.browser(.authProxyRedirect)))
        XCTAssertEqual(calls, 0, "Nothing past the sign-in service is visible to ask about")
    }

    func testUnrecognizedAndEmptyAnswersAreErrorsNotSignInModes() async {
        for (discovery, expected) in [
            (AuthProviderDiscoveryResult.unrecognized, DashboardSignInError.unrecognizedServer),
            (.providers([]), .noSignInMethod),
            (.providers([["name": "drain", "supports_password": false, "supports_session": false]]), .noSignInMethod)
        ] {
            do {
                let (mode, _) = try await mode(discovery)
                XCTFail("\(discovery) must not become a sign-in mode, got \(mode)")
            } catch {
                XCTAssertEqual(error as? DashboardSignInError, expected)
                XCTAssertEqual(ConnectionFailureClassifier.classify(error), .unexpectedServerResponse)
            }
        }
    }

    func testFailedCapabilityCheckIsAnErrorNeverADowngrade() async {
        // Neither the OAuth-only dashboard nor a picked browser sign-in may
        // fall back to password or the embedded browser when the capability
        // answer fails.
        do {
            let (mode, _) = try await mode(.providers([selfHosted]), capability: .failure(CapabilityFixture.serverError))
            XCTFail("A failed capability check must not decide a mode, got \(mode)")
        } catch {
            XCTAssertEqual(error as? CapabilityFixture, .serverError)
        }
        do {
            let opened = try await CapabilityProbe(.failure(CapabilityFixture.serverError)).resolver
                .signIn(for: .nativeCapable(provider: "self-hosted"))
            XCTFail("A failed capability check must not open a sign-in, got \(opened)")
        } catch {
            XCTAssertEqual(error as? CapabilityFixture, .serverError)
        }
    }
}
