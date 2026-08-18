import Foundation
import XCTest
@testable import Conduit

final class SecurityBoundaryTests: XCTestCase {
    func testAppTransportSecurityAllowsTailscaleCGNATRange() throws {
        let appInfo = try XCTUnwrap(Bundle(identifier: "com.milim.relay")?.infoDictionary)
        let appTransportSecurity = try XCTUnwrap(
            appInfo["NSAppTransportSecurity"] as? [String: Any]
        )
        let exceptionDomains = try XCTUnwrap(
            appTransportSecurity["NSExceptionDomains"] as? [String: Any]
        )
        let cgnatException = try XCTUnwrap(
            exceptionDomains["100.64.0.0/10"] as? [String: Any]
        )
        XCTAssertEqual(cgnatException["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true)
    }

    func testRemoteDashboardMustUseHTTPSButLoopbackAndTailscaleMayUseHTTP() throws {
        XCTAssertThrowsError(try ConnectionURLPolicy.normalizedBaseURL("http://gateway.example"))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://gateway.example")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://127.0.0.1:9120")))
        XCTAssertEqual(
            try ConnectionURLPolicy.normalizedBaseURL("http://localhost:9120/"),
            "http://localhost:9120"
        )
        XCTAssertEqual(
            try ConnectionURLPolicy.normalizedBaseURL("https://gateway.example/"),
            "https://gateway.example"
        )
        // Tailscale MagicDNS
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://my-server.tailnet-name.ts.net:9121")))
        XCTAssertEqual(
            try ConnectionURLPolicy.normalizedBaseURL("http://my-server.tailnet-name.ts.net:9121/"),
            "http://my-server.tailnet-name.ts.net:9121"
        )
        // Tailscale CGNAT IP (100.64.0.0/10)
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.85.1.2:9121")))
        XCTAssertEqual(
            try ConnectionURLPolicy.normalizedBaseURL("http://100.85.1.2:9121"),
            "http://100.85.1.2:9121"
        )
        // Outside CGNAT range still rejected
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.63.0.1:9121")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.128.0.1:9121")))
        // Non-IPv4 label-based bypass attempts must be rejected
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.64.attacker.example")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.64.not-an-ip")))
        // 3-octet partial addresses should not match (not a valid IPv4)
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.64.1")))
    }

    func testPrivateLANHTTPIsAllowed() {
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://192.168.1.42:9119")))
        XCTAssertEqual(
            try? ConnectionURLPolicy.normalizedBaseURL("http://192.168.1.42:9119/"),
            "http://192.168.1.42:9119"
        )
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://10.0.0.1")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://172.16.0.1")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://172.31.255.254")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://192.168.255.254")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://172.15.255.255")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://172.32.0.1")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://192.167.0.1")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://192.168.1.999")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://192.168.attacker.1")))
    }

    func testInsecureTransportErrorExplainsAllowedLocalNetworks() {
        XCTAssertEqual(
            ConnectionURLPolicyError.insecureTransport.errorDescription,
            "Remote dashboards must use HTTPS; HTTP is allowed only for local networks (localhost, private LAN, and Tailscale)."
        )
    }

    func testCGNATOctetBoundaryRejectsInvalidValues() {
        // Octet > 255 is not a valid IPv4 octet
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.64.256.1")))
        // Negative octets are invalid
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.-1.0.1")))
        // Non-numeric octets
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.64 abc.1")))
        // 5 octets is not valid IPv4
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.64.1.2.3")))
        // Boundary: 100.63.x.x is NOT CGNAT (below range)
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.63.255.255")))
        // Boundary: 100.128.x.x is NOT CGNAT (above range)
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.128.0.0")))
        // Boundary: 100.64.0.0 IS CGNAT (start of range)
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.64.0.0")))
        // Boundary: 100.127.255.255 IS CGNAT (end of range)
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.127.255.255")))
    }

    func testWebSocketURLUsesSecureTransportAndPreservesGatewayPath() throws {
        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: "https://gateway.example/hermes",
            path: "/api/ws",
            queryItems: [URLQueryItem(name: "ticket", value: "one")]
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "gateway.example")
        XCTAssertEqual(url.path, "/hermes/api/ws")
        XCTAssertEqual(url.query, "ticket=one")
    }

    func testProfilePathJoinsExistingQueryAndEscapesSeparators() {
        XCTAssertEqual(DashboardPath.encodedQueryComponent("/tmp/a&b"), "%2Ftmp%2Fa%26b")
        XCTAssertEqual(
            DashboardPath.withProfile("/api/fs/list?path=%2Ftmp", profile: "secondary&unsafe"),
            "/api/fs/list?path=%2Ftmp&profile=secondary%26unsafe"
        )
    }

    func testInlineScriptSerializationEscapesScriptTerminators() {
        let value = MarkupHTML.jsonString("</script>\u{2028}\u{2029}")
        XCTAssertTrue(value.contains("\\u003c/script>"))
        XCTAssertTrue(value.contains("\\u2028"))
        XCTAssertTrue(value.contains("\\u2029"))
    }

    func testDataURLLimitRejectsOversizedBase64BeforeDecoding() {
        XCTAssertFalse(DataURLLimits.isBase64CharacterCountWithinLimit(DataURLLimits.maxBase64Characters + 1))
        XCTAssertTrue(DataURLLimits.isBoundedBase64DataURL("data:image/png;base64,AAAA", prefix: "data:image/"))
    }
}
