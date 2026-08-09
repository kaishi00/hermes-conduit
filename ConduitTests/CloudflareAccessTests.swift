import Foundation
import XCTest
@testable import Conduit

final class CloudflareAccessTests: XCTestCase {
    func testDisabledRequestIsUnchanged() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://hermes.example/api/status")))
        XCTAssertEqual(CloudflareAccessCredentials(clientID: "", clientSecret: "").applying(to: request), request)
    }

    func testConfiguredRequestReceivesOnlyBothAccessHeaders() throws {
        let credentials = CloudflareAccessCredentials(clientID: "client-id", clientSecret: "client-secret")
        let request = credentials.applying(to: URLRequest(url: try XCTUnwrap(URL(string: "https://hermes.example/api/status"))))
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "client-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "client-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDisabledRetainedFieldsDoNotAdmitCredentialsOrHeaders() throws {
        // LoginView uses @State which SwiftUI manages outside of view
        // lifecycle. Test the factory directly instead.
        // When disabled (isConfigured = false), no headers are applied.
        let disabled = CloudflareAccessCredentials(clientID: "", clientSecret: "")
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://hermes.example/api/status")))

        let disabledRequest = disabled.applying(to: request)
        XCTAssertEqual(disabledRequest, request)
        XCTAssertNil(disabledRequest.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(disabledRequest.value(forHTTPHeaderField: "CF-Access-Client-Secret"))

        // When enabled with the same retained values, headers appear.
        let enabled = try XCTUnwrap(CloudflareAccessCredentials.from(
            clientID: "retained-client-id",
            clientSecret: "retained-client-secret"
        ))
        let enabledRequest = enabled.applying(to: request)
        XCTAssertEqual(enabledRequest.value(forHTTPHeaderField: "CF-Access-Client-Id"), "retained-client-id")
        XCTAssertEqual(enabledRequest.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "retained-client-secret")
    }

    func testKeychainRecordRoundTripAndSecretIsNotARepresentation() throws {
        let record = CloudflareAccessKeychainRecord(clientID: "fixture-client", clientSecret: "fixture-client-secret", origin: "https://hermes.example")
        let reloaded = try JSONDecoder().decode(
            CloudflareAccessKeychainRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(reloaded.credentials, CloudflareAccessCredentials(clientID: "fixture-client", clientSecret: "fixture-client-secret"))
        XCTAssertEqual(reloaded.origin, "https://hermes.example")
        XCTAssertFalse(reloaded.credentials?.description.contains("fixture-client-secret") == true)
        XCTAssertFalse(String(describing: reloaded.credentials).contains("fixture-client-secret"))
    }

    func testIncompleteConfigurationIsAbsent() {
        XCTAssertNil(CloudflareAccessCredentials.from(clientID: "client-id", clientSecret: ""))
        XCTAssertNil(CloudflareAccessCredentials.from(clientID: "", clientSecret: "secret"))
    }

    // MARK: - Fetch Injection Script

    func testFetchInjectionContainsBothHeaders() throws {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        let script = credentials.fetchInjectionUserScript
        XCTAssertTrue(script.contains("CF-Access-Client-Id"))
        XCTAssertTrue(script.contains("CF-Access-Client-Secret"))
        XCTAssertTrue(script.contains("test-id"))
        XCTAssertTrue(script.contains("test-secret"))
    }

    func testFetchInjectionIsEmptyWhenUnconfigured() {
        let credentials = CloudflareAccessCredentials(clientID: "", clientSecret: "")
        XCTAssertTrue(credentials.fetchInjectionUserScript.isEmpty)
    }

    func testFetchInjectionEscapesSingleQuotes() throws {
        let credentials = CloudflareAccessCredentials(clientID: "id'with'quotes", clientSecret: "secret'val")
        let script = credentials.fetchInjectionUserScript
        XCTAssertTrue(script.contains("var cfId = \"id'with'quotes\";"))
        XCTAssertTrue(script.contains("var cfSecret = \"secret'val\";"))
    }

    func testFetchInjectionEscapesBackslashesAndControlCharacters() {
        let credentials = CloudflareAccessCredentials(
            clientID: "id\\with\"quote\n\t",
            clientSecret: "secret\\value\"quote\r\n"
        )

        let script = credentials.fetchInjectionUserScript

        XCTAssertTrue(script.contains(#"id\\with\"quote\n\t"#))
        XCTAssertTrue(script.contains(#"secret\\value\"quote\r\n"#))
    }

    // MARK: - Origin Binding

    /// The origin field must survive encode/decode so that
    /// loadCloudflareAccess(for:) can compare it against the current
    /// connection's base URL.
    func testKeychainRecordPreservesOrigin() throws {
        let record = CloudflareAccessKeychainRecord(
            clientID: "id", clientSecret: "secret",
            origin: "https://gateway.example:9119"
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: encoded)
        XCTAssertEqual(decoded.origin, "https://gateway.example:9119")
    }

    /// Simulates what loadCloudflareAccess(for:) does: compares the stored
    /// origin against the requested base URL. This is the actual security
    /// check that prevents a token saved for gateway A from being sent to
    /// gateway B.
    func testOriginMatchLogicAllowsSameGateway() throws {
        let savedOrigin = "https://gateway.example:9119"
        let requestURL = "https://gateway.example:9119"
        let normalized = try ConnectionURLPolicy.normalizedBaseURL(requestURL)
        XCTAssertEqual(savedOrigin, normalized, "Same gateway should match")
    }

    func testOriginMatchLogicRejectsDifferentGateway() throws {
        let savedOrigin = "https://gateway-a.example"
        let requestURL = "https://gateway-b.example"
        let normalized = try ConnectionURLPolicy.normalizedBaseURL(requestURL)
        XCTAssertNotEqual(savedOrigin, normalized, "Different gateway must NOT match")
    }

    func testOriginMatchLogicRejectsDifferentPort() throws {
        let savedOrigin = "https://gateway.example:9119"
        let requestURL = "https://gateway.example:9999"
        let normalized = try ConnectionURLPolicy.normalizedBaseURL(requestURL)
        XCTAssertNotEqual(savedOrigin, normalized, "Different port must NOT match")
    }

    /// Decoding a legacy record WITHOUT an origin field (from before the
    /// origin-binding feature was added) must not crash. The origin field
    /// is optional, so decoding succeeds but yields an empty origin —
    /// which loadCloudflareAccess(for:) will correctly reject on mismatch.
    func testDecodingLegacyRecordWithoutOriginDoesNotCrash() throws {
        let legacyJSON = #"{"clientID":"old-id","clientSecret":"old-secret"}"#
        let data = legacyJSON.data(using: .utf8)!
        // This MUST decode without throwing
        let decoded = try JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: data)
        // Origin must be empty so loadCloudflareAccess(for:) never matches
        XCTAssertEqual(decoded.origin, "", "Legacy record must have empty origin")
        // Credentials must still be present
        XCTAssertNotNil(decoded.credentials)
    }
}
