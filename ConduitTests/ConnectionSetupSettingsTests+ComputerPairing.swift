//
//  ConnectionSetupSettingsTests+ComputerPairing.swift
//  Conduit
//
//  Pair a Computer (ComputerPairing.swift): the QR code's link, the seal the
//  desktop app opens, the four words both screens show, and which saved
//  dashboards go. An extension, as the unit suite is at its class cap.
//

import CryptoKit
import XCTest
@testable import Conduit

extension ConnectionSetupSettingsTests {
    private func pairingLinkText(key: Data, expires: Int = 4_102_444_800, inbox: String = String(repeating: "A", count: 43)) -> String {
        let k = key.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "conduit://pair?v=1&m=https%3A%2F%2Frooms.example&i=\(inbox)&t=tok_en-1&k=\(k)&e=\(expires)"
    }

    private func fromBase64URL(_ text: String) -> Data {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)!
    }

    func testComputerPairingWordsMatchTheDesktopVector() {
        // The desktop app's test/pairCrypto.test.ts holds the same vector.
        let words = ComputerPairing.words(computerKey: Data(repeating: 0, count: 32), ephemeralPublic: Data(repeating: 1, count: 32))
        XCTAssertEqual(words, ["only", "notable", "gym", "rescue"])
        XCTAssertEqual(BIP39Words.english.count, 2048)
    }

    func testComputerPairingLinkReadsTheDesktopCode() throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let link = try XCTUnwrap(ComputerPairingLink(pairingLinkText(key: key)))
        XCTAssertEqual(link.mailbox.absoluteString, "https://rooms.example")
        XCTAssertEqual(link.token, "tok_en-1")
        XCTAssertEqual(link.key, key)
        XCTAssertFalse(link.hasExpired())
        XCTAssertFalse(String(describing: link).contains("tok_en-1"))
        XCTAssertTrue(ComputerPairingLink(pairingLinkText(key: key, expires: 1_000))!.hasExpired())

        XCTAssertNil(ComputerPairingLink("conduit://link/abc"))
        XCTAssertNil(ComputerPairingLink(pairingLinkText(key: Data(repeating: 1, count: 31))))
        XCTAssertNil(ComputerPairingLink(pairingLinkText(key: key, inbox: "short")))
        XCTAssertNil(ComputerPairingLink(pairingLinkText(key: key).replacingOccurrences(of: "v=1", with: "v=2")))
        XCTAssertNil(ComputerPairingLink(pairingLinkText(key: key).replacingOccurrences(of: "https%3A", with: "ftp%3A")))
    }

    func testComputerPairingSealOpensWithTheComputersKey() throws {
        let computer = Curve25519.KeyAgreement.PrivateKey()
        let computerKey = computer.publicKey.rawRepresentation
        let inbox = String(repeating: "B", count: 43)
        let payload = try ComputerPairing.payload([ComputerPairing.Host(url: "https://hermes.example", method: .password, username: "eric", password: "pw", name: "Home")])
        let sealed = try ComputerPairing.seal(payload, to: computerKey, inbox: inbox)

        // Open it as the desktop app does.
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed.envelope) as? [String: Any])
        XCTAssertEqual(envelope["v"] as? Int, 1)
        let epk = fromBase64URL(try XCTUnwrap(envelope["epk"] as? String))
        let nonce = fromBase64URL(try XCTUnwrap(envelope["n"] as? String))
        let box = fromBase64URL(try XCTUnwrap(envelope["c"] as? String))
        XCTAssertEqual(epk, sealed.ephemeralPublic)
        let shared = try computer.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("conduit-pair-v1".utf8), sharedInfo: Data("conduit-pair-v1 phone-to-computer".utf8) + epk + computerKey, outputByteCount: 32)
        let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: box.dropLast(16), tag: box.suffix(16))
        let opened = try AES.GCM.open(sealedBox, using: key, authenticating: Data("conduit-pair/1\n\(inbox)".utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: opened) as? [String: Any])
        XCTAssertEqual(json["v"] as? Int, 1)
        let hosts = try XCTUnwrap(json["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts.first?["method"] as? String, "password")
        XCTAssertEqual(hosts.first?["username"] as? String, "eric")
        XCTAssertNil(hosts.first?["token"] as? String)
        XCTAssertNil(hosts.first?["headers"])

        // Another inbox's box doesn't open.
        XCTAssertThrowsError(try AES.GCM.open(sealedBox, using: key, authenticating: Data("conduit-pair/1\nother".utf8)))
    }

    func testComputerPairingSendsSavedPasswordsAndSessionTokensActiveFirst() {
        let home = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "https://home.example")
        let work = SavedDashboard(id: UUID(), label: "", normalizedURL: "https://work.example:9443")
        let sso = SavedDashboard(id: UUID(), label: "Office", normalizedURL: "https://office.example")
        let registry = SavedDashboardRegistry(activeDashboardID: work.id, dashboards: [home, work, sso])
        let choices = ComputerPairingChoice.choices(
            registry: registry,
            credentials: { $0 == home.id ? DashboardCredentials(baseURL: home.normalizedURL, username: "eric", password: "pw", requiresFaceID: true) : nil },
            tokens: { id in
                if id == work.id { return .sessionToken("deploy-token") }
                if id == sso.id { return NativeOAuthTokenSet(accessToken: "a", refreshToken: "r", expiresAt: 0, provider: "oidc", userID: "u") }
                return nil
            }
        )
        XCTAssertEqual(choices.map(\.id), [work.id, home.id, sso.id])
        XCTAssertEqual(choices[0].host, ComputerPairing.Host(url: "https://work.example:9443", method: .token, token: "deploy-token"))
        XCTAssertEqual(choices[0].label, "work.example")
        XCTAssertTrue(choices[0].isActive)
        XCTAssertEqual(choices[1].host, ComputerPairing.Host(url: "https://home.example", method: .password, username: "eric", password: "pw", name: "Home"))
        // A browser sign-in's tokens stay on this phone.
        XCTAssertNil(choices[2].host)
        XCTAssertFalse(String(describing: choices[1]).contains("pw"))
    }

    func testComputerPairingSendsAProxysHeadersOverHTTPSOnly() throws {
        let secure = SavedDashboard(id: UUID(), label: "", normalizedURL: "https://hermes.example")
        let plain = SavedDashboard(id: UUID(), label: "", normalizedURL: "http://192.168.1.20:9119")
        let registry = SavedDashboardRegistry(activeDashboardID: secure.id, dashboards: [secure, plain])
        let access = ["CF-Access-Client-Id": "id.access", "CF-Access-Client-Secret": "shh"]
        let choices = ComputerPairingChoice.choices(
            registry: registry,
            credentials: { _ in nil },
            tokens: { _ in .sessionToken("t") },
            proxyHeaders: { _ in access }
        )
        XCTAssertEqual(choices[0].host?.headers, access)
        XCTAssertNil(choices[1].host?.headers)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ComputerPairing.payload(choices.compactMap(\.host))) as? [String: Any])
        let hosts = try XCTUnwrap(json["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts.first?["headers"] as? [String: String], access)
        XCTAssertFalse(String(describing: choices[0]).contains("shh"))
        // The service token wins over an extra header of the same name, in any case.
        let merged = ComputerPairing.proxyHeaders(
            extra: [CustomHeader(name: "cf-access-client-secret", value: "stale"), CustomHeader(name: "X-Pangolin", value: "p"), CustomHeader(name: "Cookie", value: "x")],
            access: CloudflareAccessCredentials(clientID: " id.access ", clientSecret: "shh")
        )
        XCTAssertEqual(merged, ["X-Pangolin": "p", "CF-Access-Client-Id": "id.access", "CF-Access-Client-Secret": "shh"])
        XCTAssertEqual(ComputerPairing.proxyHeaders(extra: [], access: CloudflareAccessCredentials(clientID: "", clientSecret: "")), [:])
    }

    @MainActor
    func testOpeningAPairingCodeOpensPairAComputerAndNothingElse() throws {
        let suite = "ConnectionSetupSettingsTests.Pairing.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("No test defaults") }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let url = try XCTUnwrap(URL(string: pairingLinkText(key: key)))

        XCTAssertTrue(appState.routeComputerPairingLink(url))
        XCTAssertEqual(appState.pendingComputerPairing?.key, key)
        // Nothing else reads it: not a chat, Settings, sign-in or Link.
        XCTAssertNil(ConduitAppLink(url: url))
        XCTAssertNil(ConduitAppLink(externalURL: url))
        XCTAssertFalse(appState.routeConnectLink(url))
        XCTAssertFalse(appState.routeRoomLink(url))

        // The scheme and host in any case.
        appState.pendingComputerPairing = nil
        let shouting = try XCTUnwrap(URL(string: pairingLinkText(key: key).replacingOccurrences(of: "conduit://pair", with: "CONDUIT://PAIR")))
        XCTAssertTrue(appState.routeComputerPairingLink(shouting))
        XCTAssertNotNil(appState.pendingComputerPairing)

        // A code Conduit can't read is still a code: it opens nothing.
        appState.pendingComputerPairing = nil
        XCTAssertTrue(appState.routeComputerPairingLink(try XCTUnwrap(URL(string: "conduit://pair?v=1"))))
        XCTAssertNil(appState.pendingComputerPairing)
        // Other links aren't codes.
        for other in ["conduit://link/abcde", "conduit://connect?url=example.com", "conduit://session/abc", "https://pair?v=1"] {
            XCTAssertFalse(appState.routeComputerPairingLink(try XCTUnwrap(URL(string: other))), other)
        }
        XCTAssertNil(appState.pendingComputerPairing)
    }
}
