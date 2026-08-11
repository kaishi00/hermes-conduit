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
        XCTAssertEqual(NativeAuthURLProtocol.responseStatusCode(for: "redirect.example"), 302)
        XCTAssertEqual(
            NativeAuthURLProtocol.responseHeader(for: "redirect.example", name: "Location"),
            "https://tenant.cloudflareaccess.com/cdn-cgi/access/login"
        )
        XCTAssertEqual(NativeAuthURLProtocol.requestCount(for: "redirect.example"), 1)
        XCTAssertEqual(NativeAuthURLProtocol.requestCount(for: "tenant.cloudflareaccess.com"), 0)
    }

    func testProviderDiscoveryPreservesNonRedirect3xxResponses() async throws {
        let client = NativeAuthClient(
            baseURL: "https://multiple.example",
            sessionConfiguration: makeSessionConfiguration()
        )

        do {
            _ = try await client.authProviders()
            XCTFail("Expected provider discovery to fail for a non-redirect 3xx response")
        } catch let error as AuthClientError {
            guard case .providerDiscoveryFailed(let detail) = error else {
                return XCTFail("Expected provider discovery failure, got \(error)")
            }
            XCTAssertEqual(detail, "HTTP 300")
        }
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
    private struct ResponseRecord {
        let host: String
        let statusCode: Int?
        let headers: [String: String]
    }

    private static let recordLock = NSLock()
    private static var responseRecords: [ResponseRecord] = []

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return [
            "redirect.example",
            "providers.example",
            "server-error.example",
            "headers.example",
            "multiple.example",
            "tenant.cloudflareaccess.com"
        ].contains(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let fixture = fixture(for: request)
        Self.record(
            host: url.host ?? "",
            statusCode: fixture?.statusCode,
            headers: fixture?.headers ?? [:]
        )
        guard let fixture,
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

    static func responseStatusCode(for host: String) -> Int? {
        recordLock.lock()
        defer { recordLock.unlock() }
        return responseRecords.last(where: { $0.host == host })?.statusCode
    }

    static func responseHeader(for host: String, name: String) -> String? {
        recordLock.lock()
        defer { recordLock.unlock() }
        return responseRecords.last(where: { $0.host == host })?.headers[name]
    }

    static func requestCount(for host: String) -> Int {
        recordLock.lock()
        defer { recordLock.unlock() }
        return responseRecords.filter { $0.host == host }.count
    }

    private static func record(host: String, statusCode: Int?, headers: [String: String]) {
        recordLock.lock()
        responseRecords.append(ResponseRecord(host: host, statusCode: statusCode, headers: headers))
        recordLock.unlock()
    }

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
        case "multiple.example":
            return Fixture(statusCode: 300, headers: [:], body: Data())
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
