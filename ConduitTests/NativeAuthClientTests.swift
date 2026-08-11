import Foundation
import XCTest
@testable import Conduit

final class NativeAuthClientTests: XCTestCase {
    func testProviderDiscoveryRedirectFallsBackToWebView() async throws {
        let client = NativeAuthClient(
            baseURL: "https://redirect.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        let providers = try await client.authProviders()

        XCTAssertTrue(providers.isEmpty)
    }

    func testProviderDiscoveryParsesPasswordProvider() async throws {
        let client = NativeAuthClient(
            baseURL: "https://providers.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        let providers = try await client.authProviders()

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0]["name"] as? String, "basic")
        XCTAssertEqual(providers[0]["supports_password"] as? Bool, true)
    }

    func testProviderDiscoveryPreservesServerErrors() async throws {
        let client = NativeAuthClient(
            baseURL: "https://server-error.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        do {
            _ = try await client.authProviders()
            XCTFail("Expected provider discovery to fail for a server error")
        } catch let error as AuthClientError {
            guard case .providerDiscoveryFailed(let detail) = error else {
                return XCTFail("Expected provider discovery failure, got \(error)")
            }
            XCTAssertEqual(detail, "origin unavailable")
        }
    }

    func testProviderDiscoverySendsCloudflareAccessHeaders() async throws {
        let credentials = CloudflareAccessCredentials(
            clientID: "test-client-id",
            clientSecret: "test-client-secret"
        )
        let client = NativeAuthClient(
            baseURL: "https://headers.example",
            cloudflareAccess: credentials,
            sessionConfiguration: makeSessionConfiguration()
        )

        let providers = try await client.authProviders()

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0]["name"] as? String, "basic")
    }

    private func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeAuthURLProtocol.self]
        return configuration
    }
}

private final class NativeAuthURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".example") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let fixture = fixture(for: request),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: fixture.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: fixture.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private struct Fixture {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private func fixture(for request: URLRequest) -> Fixture? {
        guard let host = request.url?.host else { return nil }

        switch host {
        case "redirect.example":
            return Fixture(
                statusCode: 302,
                headers: [
                    "Location": "https://tenant.cloudflareaccess.com/cdn-cgi/access/login"
                ],
                body: Data()
            )
        case "providers.example":
            return Fixture(statusCode: 200, headers: [:], body: providerBody())
        case "server-error.example":
            return Fixture(statusCode: 500, headers: [:], body: Data(#"{"error":"origin unavailable"}"#.utf8))
        case "headers.example":
            let hasExpectedHeaders = request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "test-client-id"
                && request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "test-client-secret"
            return hasExpectedHeaders
                ? Fixture(statusCode: 200, headers: [:], body: providerBody())
                : Fixture(statusCode: 403, headers: [:], body: Data(#"{"error":"missing Cloudflare service token"}"#.utf8))
        default:
            return nil
        }
    }

    private func providerBody() -> Data {
        Data(#"{"providers":[{"name":"basic","supports_password":true}]}"#.utf8)
    }
}
