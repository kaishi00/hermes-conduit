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

    // MARK: - auth_flows on the provider answer

    func testAdvertisedNativeFlowDecidesWithoutACapabilityRequest() async throws {
        // A dashboard behind an auth edge may answer only the provider
        // route before sign-in; its `auth_flows` there decide, even when the
        // capability seam would fail (the edge refusing `/api/status`).
        let (mode, calls) = try await mode(
            .providers([selfHosted], authFlows: ["cookie", "native_pkce"]),
            capability: .failure(CapabilityFixture.serverError)
        )
        XCTAssertEqual(mode, .interactive(.nativeOAuth(provider: "self-hosted")))
        XCTAssertEqual(calls, 0, "The provider answer already said")
    }

    func testAdvertisedFlowsWithoutNativeLeaveTheDecisionToTheCapabilityRequest() async throws {
        // Only `native_pkce` decides from the provider answer. Any other
        // list is left to `/api/status`, so the provider answer never routes
        // a native-capable provider to the browser view on its own, and a
        // failed check stays an error.
        for flows in [["cookie"], []] {
            let native = try await mode(.providers([selfHosted], authFlows: flows), capability: .success(true))
            XCTAssertEqual(native.0, .interactive(.nativeOAuth(provider: "self-hosted")), "\(flows)")
            XCTAssertEqual(native.1, 1, "\(flows)")
            let older = try await mode(.providers([selfHosted], authFlows: flows), capability: .success(false))
            XCTAssertEqual(older.0, .interactive(.browser(.legacyOAuth)), "\(flows)")
            do {
                let (mode, _) = try await mode(
                    .providers([selfHosted], authFlows: flows),
                    capability: .failure(CapabilityFixture.serverError)
                )
                XCTFail("A failed capability check must not decide a mode, got \(mode)")
            } catch {
                XCTAssertEqual(error as? CapabilityFixture, .serverError, "\(flows)")
            }
        }
    }

    func testNoAdvertisedFlowsFallsBackToTheCapabilityRequest() async throws {
        // Stock Hermes advertises `auth_flows` only on `/api/status`.
        let supported = try await mode(.providers([selfHosted], authFlows: nil), capability: .success(true))
        XCTAssertEqual(supported.0, .interactive(.nativeOAuth(provider: "self-hosted")))
        XCTAssertEqual(supported.1, 1)
        do {
            let (mode, _) = try await mode(
                .providers([selfHosted], authFlows: nil),
                capability: .failure(CapabilityFixture.serverError)
            )
            XCTFail("A failed capability check must not decide a mode, got \(mode)")
        } catch {
            XCTAssertEqual(error as? CapabilityFixture, .serverError)
        }
    }

    func testOfferedBrowserSignInCarriesTheAdvertisedFlows() async throws {
        let (mode, calls) = try await mode(.providers([password, selfHosted], authFlows: ["cookie", "native_pkce"]))
        let offer = DashboardBrowserSignInOffer.nativeCapable(
            provider: "self-hosted",
            advertisedFlows: ["cookie", "native_pkce"]
        )
        XCTAssertEqual(mode, .passwordOrBrowser(offer))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(offer.decidedSignIn, .nativeOAuth(provider: "self-hosted"))

        let probe = CapabilityProbe(.failure(CapabilityFixture.serverError))
        let opened = try await probe.resolver.signIn(for: offer)
        XCTAssertEqual(opened, .nativeOAuth(provider: "self-hosted"))
        XCTAssertEqual(probe.calls, 0, "Picking it asks nothing more")

        let cookieOnly = DashboardBrowserSignInOffer.nativeCapable(provider: "self-hosted", advertisedFlows: ["cookie"])
        XCTAssertNil(cookieOnly.decidedSignIn, "Only native_pkce decides from the provider answer")
        let older = CapabilityProbe(.success(false))
        let olderOpened = try await older.resolver.signIn(for: cookieOnly)
        XCTAssertEqual(olderOpened, .browser(.legacyOAuth))
        XCTAssertEqual(older.calls, 1)
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
