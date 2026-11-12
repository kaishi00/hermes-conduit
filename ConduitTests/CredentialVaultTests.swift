//
//  CredentialVaultTests.swift
//  ConduitTests
//
//  Settings > Passwords & logins' Add form: what it sends `vault.add`.
//

import XCTest
@testable import Conduit

final class CredentialVaultTests: XCTestCase {
    func testOriginsAreKeyedAsHermesKeysThem() {
        XCTAssertEqual(VaultItemDraft.normalizedOrigin("github.com"), "https://github.com")
        XCTAssertEqual(VaultItemDraft.normalizedOrigin(" https://GitHub.com/login?next=1 "), "https://github.com")
        XCTAssertEqual(VaultItemDraft.normalizedOrigin("https://example.com:443"), "https://example.com")
        XCTAssertEqual(VaultItemDraft.normalizedOrigin("http://192.168.1.4:8080/admin"), "http://192.168.1.4:8080")
        XCTAssertEqual(VaultItemDraft.normalizedOrigin("https://[2001:DB8::1]:8080/x"), "https://[2001:db8::1]:8080")
        XCTAssertNil(VaultItemDraft.normalizedOrigin(""))
        XCTAssertNil(VaultItemDraft.normalizedOrigin("not a site"))
        XCTAssertNil(VaultItemDraft.normalizedOrigin("ftp://files.example.com"))
    }

    func testALoginNeedsItsSiteIdentifierAndPassword() {
        var draft = VaultItemDraft()
        XCTAssertEqual(draft.request(), .failure(.origin))
        draft.origin = "github.com"
        XCTAssertEqual(draft.request(), .failure(.login))
        draft.identifier = "  me@example.com "
        draft.password = "   "
        XCTAssertEqual(draft.request(), .failure(.login), "Spaces alone are no password")
        draft.password = " p@ss word "
        guard case .success(let request) = draft.request() else { return XCTFail("A full login saves") }
        XCTAssertEqual(request.kind, "login")
        XCTAssertEqual(request.label, "github.com", "A login with no label is named for its site")
        XCTAssertEqual(request.origin, "https://github.com")
        XCTAssertEqual(request.secret, ["identifier_type": "email", "identifier": "me@example.com", "password": " p@ss word "], "The password goes as typed")

        draft.otpSecret = " JBSW Y3DP-EHPK 3PXP "
        draft.label = "Work"
        guard case .success(let withCode) = draft.request() else { return XCTFail("A login with a key saves") }
        XCTAssertEqual(withCode.label, "Work")
        XCTAssertEqual(withCode.secret["otp_secret"], "JBSWY3DPEHPK3PXP")
    }

    func testACardSendsItsDigitsAndATwoDigitMonth() {
        var draft = VaultItemDraft()
        draft.kind = .payment
        draft.label = "Visa"
        draft.cardNumber = "4242 4242-4242 4242"
        draft.expMonth = "13"
        draft.expYear = "2029"
        draft.cvc = "123"
        XCTAssertEqual(draft.request(), .failure(.expiry))
        draft.expMonth = "3"
        guard case .success(let request) = draft.request() else { return XCTFail("A full card saves") }
        XCTAssertNil(request.origin, "A card's site is optional")
        XCTAssertEqual(request.secret, ["card_number": "4242424242424242", "exp_month": "03", "exp_year": "2029", "cvc": "123"])
        draft.cardNumber = "4242 abcd"
        XCTAssertEqual(draft.request(), .failure(.cardNumber))
    }

    func testAnAddressNeedsStreetCityPostalCodeAndCountry() {
        var draft = VaultItemDraft()
        draft.kind = .address
        draft.label = "Home"
        draft.addressLine1 = "1 Main St"
        draft.city = "Springfield"
        draft.postalCode = "12345"
        XCTAssertEqual(draft.request(), .failure(.address))
        draft.country = "US"
        guard case .success(let request) = draft.request() else { return XCTFail("A full address saves") }
        XCTAssertEqual(request.secret, ["address_line1": "1 Main St", "city": "Springfield", "postal_code": "12345", "country": "US"])
        draft.origin = "shop example"
        XCTAssertEqual(draft.request(), .failure(.origin), "A site typed wrong isn't dropped")
    }

    func testTheKeptListSurvivesTheStoresCredentialFilter() throws {
        // The page opens on the list kept as Conduit's own JSON, which the
        // store filters for credential-shaped names: none of its fields may
        // be dropped, or the kept list would reopen without them.
        let snapshot = CredentialVaultSnapshot(
            items: [VaultItem(id: "a1", kind: "login", label: "GitHub", origin: "https://github.com", identifier: "me@example.com", identifierType: "email", created: "2026-11-07T19:22:43.888123+00:00", hasOTP: true)],
            sources: [VaultSource(name: "bitwarden", displayName: "Bitwarden", enabled: true, needsUnlock: true, unlocked: false, installed: true)]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        let kept = OfflineChatCacheStore.withoutCredentials(json)
        let decoded = try JSONDecoder().decode(CredentialVaultSnapshot.self, from: JSONSerialization.data(withJSONObject: kept))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(AppState.credentialVaultRoute, "rpc:vault.list")
    }

    func testAPasswordManagerSaysWhatItsStateMeans() {
        let missing = VaultSource(name: "onepassword", displayName: "1Password", enabled: false, needsUnlock: true, unlocked: false, installed: false)
        let locked = VaultSource(name: "bitwarden", displayName: "Bitwarden", enabled: true, needsUnlock: true, unlocked: false, installed: true)
        XCTAssertEqual(missing.status, "Not detected")
        XCTAssertEqual(locked.status, "Locked")
        XCTAssertTrue(missing.caption.contains("1Password"))
    }

    /// What a change Hermes took leaves in the kept list (issue 1995): a
    /// saved item with its metadata only, and an off or locked manager's
    /// items gone, as `vault.list` leaves them out.
    func testAChangeHermesTookIsWhatTheKeptListShows() throws {
        var draft = VaultItemDraft()
        draft.origin = "github.com"
        draft.identifier = "me@example.com"
        draft.password = "hunter2"
        draft.otpSecret = "JBSW Y3DP"
        let request = try draft.request().get()
        let bitwarden = VaultSource(name: "bitwarden", displayName: "Bitwarden", enabled: true, needsUnlock: true, unlocked: true, installed: true)
        var kept = CredentialVaultSnapshot(
            items: [VaultItem(id: "bw1", kind: "login", label: "Bank", source: "bitwarden")],
            sources: [VaultSource(name: VaultSource.localName, displayName: "Hermes", enabled: true, needsUnlock: false, unlocked: true, installed: true), bitwarden]
        )

        kept.add(id: "n1", request)
        kept.add(id: "n1", request)
        XCTAssertEqual(kept.items.map(\.id), ["bw1", "n1"], "Added once")
        let added = try XCTUnwrap(kept.items.last)
        XCTAssertEqual(added.label, "github.com")
        XCTAssertEqual(added.origin, "https://github.com")
        XCTAssertEqual(added.identifier, "me@example.com")
        XCTAssertTrue(added.hasOTP)
        XCTAssertTrue(added.isLocal)
        let json = String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)
        XCTAssertFalse(json.contains("hunter2"), "The password is never kept")
        XCTAssertFalse(json.contains("JBSW"), "Nor the authenticator key")

        kept.changeSource("bitwarden", unlocked: false)
        XCTAssertEqual(kept.items.map(\.id), ["n1"], "A locked manager's items go")
        XCTAssertEqual(kept.managers.first?.unlocked, false)
        XCTAssertEqual(kept.managers.first?.enabled, true)

        kept.items.insert(VaultItem(id: "bw1", kind: "login", label: "Bank", source: "bitwarden"), at: 0)
        kept.changeSource("bitwarden", enabled: false, unlocked: false)
        XCTAssertEqual(kept.items.map(\.id), ["n1"], "So do an off one's")
        XCTAssertEqual(kept.managers.first?.enabled, false)
        kept.changeSource("bitwarden", enabled: true)
        XCTAssertEqual(kept.managers.first?.enabled, true)
        XCTAssertEqual(kept.managers.first?.unlocked, false, "Turned on, it stays locked")
    }
}
