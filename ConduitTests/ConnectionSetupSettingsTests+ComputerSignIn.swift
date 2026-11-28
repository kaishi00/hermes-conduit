//
//  ConnectionSetupSettingsTests+ComputerSignIn.swift
//  Conduit
//
//  Sign In from Your Computer (ComputerSignIn.swift): Conduit for desktop's
//  code, the request it opens, the box it seals to this phone, the mailbox
//  owner's signature, and the sign-in code each dashboard opens.
//

import CryptoKit
import XCTest
@testable import Conduit

extension ConnectionSetupSettingsTests {
    private func signInLinkText() -> String {
        let key = ComputerPairing.base64URL(Data(repeating: 2, count: 32))
        return "conduit://signin?v=1&m=https%3A%2F%2Frooms.example&i=\(String(repeating: "B", count: 43))&t=tok_en-1&k=\(key)&e=4102444800"
    }

    func testComputerSignInCodeIsReadOnlyAsASignInCode() throws {
        let link = try XCTUnwrap(ComputerPairingLink(signInLinkText(), kind: .signIn))
        XCTAssertEqual(link.mailbox.absoluteString, "https://rooms.example")
        XCTAssertNil(ComputerPairingLink(signInLinkText()), "Pair a Computer never reads a sign-in code")
        guard case .computerSignIn = DashboardConnectLink.scan(signInLinkText()) else {
            return XCTFail("Scan Code on the sign-in screen reads Conduit for desktop's code")
        }
    }

    func testComputerSignInOpensTheDesktopVector() throws {
        // Sealed by the desktop app's sealForPhone (src/main/pairCrypto.ts) to
        // the X25519 key whose private bytes are 1...32.
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data((1...32).map { UInt8($0) }))
        XCTAssertEqual(ComputerPairing.base64URL(key.publicKey.rawRepresentation), "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw")
        let envelope = Data(#"{"v":1,"epk":"pMEPW7HaQ5WoW7DTMBVWdvns3INYvoq5TvjebWvBl0M","n":"FsObpK_x-QNROrW1","c":"I7xIIjdLtE1lrkAStwVf_Ha045D5wso9uo5vyrY8mEL1_HhUle6KTSq3EdQBUrlEpjGs90-Dw6a4pUfUyYx-EVoNDEo_XdQn0xbNwGed0y5H_-6KfCFM2HT39aZU03PZW2JBOwgHgs8Z70c6qlW958wlqxcQgGcG_n6ewgfVEgs1en3Ga4cQlrCmWLh730CEfYOxugvA1fC-B2vj_7cOG_MJ74AG40vjsKTogYKJ0QCr-h1cgAXL0R4arYc8Vrbt6PGQVg9A7erhxiRAVUZ492RrIMK00EHOP1AF6hnQnMcjaUOPQ3bp9h3drN9JbP1mPoRUV3kxvD4yO2DMf011dF1nMkpViEbLtv6_ABxqfTVBjy6FmA"}"#.utf8)
        let hosts = ComputerSignIn.hosts(from: try ComputerSignIn.open(envelope, with: key, inbox: "inbox-for-tests"))
        XCTAssertEqual(hosts.map(\.url), ["https://hermes.example", "http://100.64.0.2:9119"])
        XCTAssertThrowsError(try ComputerSignIn.open(envelope, with: key, inbox: "another-inbox"))

        let link = hosts[0].connectLink
        XCTAssertEqual(link.address, "https://hermes.example")
        XCTAssertEqual(link.username, "eric")
        XCTAssertEqual(link.password, "pw")
        XCTAssertEqual(link.cloudflare, LoginCloudflareState(isEnabled: true, clientID: "id", clientSecret: "secret"))
        let open = hosts[1].connectLink
        XCTAssertNil(open.password)
        XCTAssertNil(open.cloudflare)
    }

    func testASessionTokenHostFillsTheSessionTokensForm() throws {
        let data = Data(#"{"v":1,"hosts":[{"url":"https://token.example","method":"token","token":"tk-1","name":"Lab"},{"url":"https://empty.example","method":"token","token":""}]}"#.utf8)
        let hosts = ComputerSignIn.hosts(from: data)
        XCTAssertEqual(hosts.map(\.url), ["https://token.example", "https://empty.example"])
        let link = hosts[0].connectLink
        XCTAssertEqual(link.sessionToken, "tk-1")
        XCTAssertNil(link.password)
        XCTAssertNil(link.username)
        XCTAssertFalse(link.description.contains("tk-1"), "the token never shows in a description")
        XCTAssertNil(hosts[1].connectLink.sessionToken)
    }

    @MainActor
    func testOpeningASignInCodeOpensSignInFromYourComputerAndNothingElse() throws {
        let suite = "ConnectionSetupSettingsTests.SignIn.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("No test defaults") }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let url = try XCTUnwrap(URL(string: signInLinkText()))

        XCTAssertTrue(appState.routeComputerSignInLink(url))
        XCTAssertEqual(appState.pendingComputerSignIn?.mailbox.absoluteString, "https://rooms.example")
        // Pair a Computer doesn't take it, nor does anything else.
        XCTAssertFalse(appState.routeComputerPairingLink(url))
        XCTAssertNil(ConduitAppLink(url: url))
        XCTAssertFalse(appState.routeConnectLink(url))

        // A code Conduit can't read is still a code: it opens nothing.
        appState.pendingComputerSignIn = nil
        XCTAssertTrue(appState.routeComputerSignInLink(try XCTUnwrap(URL(string: "conduit://signin?v=1"))))
        XCTAssertNil(appState.pendingComputerSignIn)
        // Other links, a pairing code included, aren't sign-in codes.
        for other in ["conduit://pair?v=1", "conduit://connect?url=example.com", "https://signin?v=1"] {
            XCTAssertFalse(appState.routeComputerSignInLink(try XCTUnwrap(URL(string: other))), other)
        }
        XCTAssertNil(appState.pendingComputerSignIn)
    }

    func testComputerSignInRequestNamesThisPhonesInboxAndKey() throws {
        let inbox = ComputerSignIn.Inbox(mailbox: try XCTUnwrap(URL(string: "https://rooms.example")))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: ComputerSignIn.request(inbox)) as? [String: Any])
        XCTAssertEqual(body["v"] as? Int, 1)
        XCTAssertEqual(body["want"] as? String, "signins")
        let reply = try XCTUnwrap(body["reply"] as? [String: String])
        XCTAssertEqual(reply["inbox"], inbox.id)
        XCTAssertEqual(reply["inbox"]?.count, 43)
        XCTAssertEqual(reply["token"], inbox.token)
        XCTAssertEqual(reply["key"], ComputerPairing.base64URL(inbox.sealing.publicKey.rawRepresentation))
    }

    func testMailboxOwnerSignsWhatTheMailboxChecks() throws {
        let key = Curve25519.Signing.PrivateKey()
        let header = try ComputerSignIn.authorization(key, method: "get", host: "rooms.example", pathAndQuery: "/v1/inboxes/x/envelopes?after=0&wait=25", body: Data(), now: Date(timeIntervalSince1970: 1_700_000_000))
        let fields = Dictionary(uniqueKeysWithValues: header.dropFirst("Mailbox-Ed25519 ".count).split(separator: ",").map { part -> (String, String) in
            let pieces = part.split(separator: "=", maxSplits: 1)
            return (String(pieces[0]), String(pieces[1]))
        })
        XCTAssertEqual(fields["ts"], "1700000000")
        let message = ComputerSignIn.signedMessage(method: "GET", host: "rooms.example", pathAndQuery: "/v1/inboxes/x/envelopes?after=0&wait=25", timestamp: 1_700_000_000, nonce: try XCTUnwrap(fields["nonce"]), body: Data())
        // The mailbox's own string (mailbox/src/auth.mjs signedString); the empty body's hash.
        XCTAssertTrue(String(decoding: message, as: UTF8.self).hasPrefix("mailbox-v1\nGET\nrooms.example\n/v1/inboxes/x/envelopes?after=0&wait=25\n1700000000\n"))
        XCTAssertTrue(String(decoding: message, as: UTF8.self).hasSuffix("\n47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU"))
        let signature = try XCTUnwrap(ComputerPairing.data(base64URL: try XCTUnwrap(fields["sig"])))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: message))
    }
}
