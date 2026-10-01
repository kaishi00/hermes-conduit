//
//  HermesSpeechStreamRequestTests.swift
//  Conduit
//
//  The speak-stream WebSocket upgrade must carry the Cloudflare Access
//  service-token headers like every other native request to the host.
//  Without them Access refuses the handshake and spoken replies fail
//  whenever no CF_Authorization cookie happens to be cached.
//

import XCTest
@testable import Conduit

final class HermesSpeechStreamRequestTests: XCTestCase {
    private let credentials = CloudflareAccessCredentials(
        clientID: "test-client-id",
        clientSecret: "test-client-secret"
    )

    func testSecureStreamCarriesCloudflareAccessHeaders() throws {
        let request = try HermesVoiceGateway.speechStreamRequest(
            baseURL: "https://hermes.example/",
            ticket: "abc",
            profile: "default",
            cloudflareAccess: credentials
        )
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/api/audio/speak-stream")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "ticket" }?.value, "abc")
        XCTAssertEqual(query.first { $0.name == "profile" }?.value, "default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "test-client-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "test-client-secret")
    }

    func testStreamWithoutCloudflareAccessHasNoAccessHeaders() throws {
        let request = try HermesVoiceGateway.speechStreamRequest(
            baseURL: "https://hermes.example",
            ticket: "abc",
            profile: "default",
            cloudflareAccess: nil
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }

    func testCleartextStreamNeverCarriesTheServiceToken() throws {
        let request = try HermesVoiceGateway.speechStreamRequest(
            baseURL: "http://192.168.1.20:9119",
            ticket: "abc",
            profile: "default",
            cloudflareAccess: credentials
        )
        XCTAssertEqual(request.url?.scheme, "ws")
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }
}
