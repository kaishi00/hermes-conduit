//
//  ConduitExternalLinkTests.swift
//  ConduitTests
//
//  `conduit://session/<id>` opened by another app (a notification, a
//  Shortcut): only plain chat links are accepted from outside. Written as
//  an extension of the existing link suite: the CI test planner is at
//  capacity for new XCTestCase classes.
//

import XCTest
@testable import Conduit

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testExternalSessionLinkOpensThatChat() throws {
        let url = try XCTUnwrap(URL(string: "conduit://session/20261009_160855_d213a4"))
        XCTAssertEqual(ConduitAppLink(externalURL: url), .session(id: "20261009_160855_d213a4"))
    }

    func testExternalLinkSchemeAndHostAreCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "CONDUIT://Session/20261009_160855_d213a4"))
        XCTAssertEqual(ConduitAppLink(externalURL: url), .session(id: "20261009_160855_d213a4"))
    }

    func testExternalBotLinksStayInsideTheApp() throws {
        let url = try XCTUnwrap(URL(string: "conduit://bot/researcher"))
        XCTAssertNotNil(ConduitAppLink(url: url))
        XCTAssertNil(ConduitAppLink(externalURL: url))
    }

    func testExternalMalformedOrForeignLinksAreIgnored() throws {
        for raw in [
            "conduit://session/",
            "conduit://session/a/b",
            "conduit://other/abc",
            "https://session/abc",
            "conduit://session/abc%20def",
            "conduit://session/abc%0Adef",
            "conduit://session/" + String(repeating: "a", count: 129)
        ] {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertNil(ConduitAppLink(externalURL: url), raw)
        }
    }

    func testExternalLinkLongestAcceptedIDStillOpens() throws {
        let id = String(repeating: "a", count: 128)
        let url = try XCTUnwrap(URL(string: "conduit://session/" + id))
        XCTAssertEqual(ConduitAppLink(externalURL: url), .session(id: id))
    }

    func testExternalLinkSchemeIsRegistered() throws {
        let types = try XCTUnwrap(Bundle(for: AppState.self).object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(ConduitAppLink.scheme))
    }
}
