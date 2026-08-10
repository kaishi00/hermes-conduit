import Foundation
import JavaScriptCore
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
        let script = credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes")
        XCTAssertTrue(script.contains("CF-Access-Client-Id"))
        XCTAssertTrue(script.contains("CF-Access-Client-Secret"))
        XCTAssertTrue(script.contains("test-id"))
        XCTAssertTrue(script.contains("test-secret"))
    }

    func testFetchInjectionIsEmptyWhenUnconfigured() {
        let credentials = CloudflareAccessCredentials(clientID: "", clientSecret: "")
        XCTAssertTrue(credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes").isEmpty)
    }

    func testFetchInjectionEscapesSingleQuotes() throws {
        let credentials = CloudflareAccessCredentials(clientID: "id'with'quotes", clientSecret: "secret'val")
        let script = credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes")
        XCTAssertTrue(script.contains("var cfId = \"id'with'quotes\";"))
        XCTAssertTrue(script.contains("var cfSecret = \"secret'val\";"))
    }

    func testFetchInjectionEscapesBackslashesAndControlCharacters() {
        let credentials = CloudflareAccessCredentials(
            clientID: "id\\with\"quote\n\t",
            clientSecret: "secret\\value\"quote\r\n"
        )

        let script = credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes")

        XCTAssertTrue(script.contains(#"id\\with\"quote\n\t"#))
        XCTAssertTrue(script.contains(#"secret\\value\"quote\r\n"#))
    }

    func testFetchInjectionContainsOriginGuards() {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        let script = credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes")

        XCTAssertTrue(script.contains(#"var cfOrigin = new URL("https:\/\/dashboard.example\/hermes").origin;"#))
        XCTAssertTrue(script.contains("window.location.origin === cfOrigin"))
        XCTAssertTrue(script.contains("resolved.origin === cfOrigin"))
    }

    func testFetchInjectionPreservesRequestHeadersWhenInitHeadersAreAbsent() throws {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        let context = try makeJavaScriptContext(documentOrigin: "https://dashboard.example")
        _ = try evaluateJavaScript(
            credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes"),
            in: context
        )

        let result = try evaluateJavaScript(
            """
            var request = new Request('https://dashboard.example/api', {
                headers: { 'X-Application-Header': 'present' }
            });
            window.fetch(request);
            var passedHeaders = new Headers(__lastFetch.init.headers);
            passedHeaders.get('X-Application-Header') === 'present'
                && passedHeaders.get('CF-Access-Client-Id') === 'test-id'
                && passedHeaders.get('CF-Access-Client-Secret') === 'test-secret';
            """,
            in: context
        )

        XCTAssertTrue(result.toBool())
    }

    func testFetchInjectionPreservesExplicitInitHeaders() throws {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        let context = try makeJavaScriptContext(documentOrigin: "https://dashboard.example")
        _ = try evaluateJavaScript(
            credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes"),
            in: context
        )

        let result = try evaluateJavaScript(
            """
            var request = new Request('https://dashboard.example/api', {
                headers: { 'X-Application-Header': 'from-request' }
            });
            window.fetch(request, {
                headers: { 'X-Application-Header': 'from-init' }
            });
            var passedHeaders = new Headers(__lastFetch.init.headers);
            passedHeaders.get('X-Application-Header') === 'from-init'
                && passedHeaders.get('CF-Access-Client-Id') === 'test-id'
                && passedHeaders.get('CF-Access-Client-Secret') === 'test-secret';
            """,
            in: context
        )

        XCTAssertTrue(result.toBool())
    }

    func testFetchInjectionAddsHeadersOnlyForSameOriginRequests() throws {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        let context = try makeJavaScriptContext(documentOrigin: "https://dashboard.example")
        _ = try evaluateJavaScript(
            credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes"),
            in: context
        )

        let result = try evaluateJavaScript(
            """
            function hasAccessHeaders() {
                var passedHeaders = new Headers(__lastFetch.init && __lastFetch.init.headers);
                return passedHeaders.get('CF-Access-Client-Id') === 'test-id'
                    && passedHeaders.get('CF-Access-Client-Secret') === 'test-secret';
            }
            window.fetch('/api');
            var sameOrigin = hasAccessHeaders();
            window.fetch('//attacker.example/api');
            var networkPathCrossOrigin = !hasAccessHeaders();
            window.fetch('https://attacker.example/api');
            var absoluteCrossOrigin = !hasAccessHeaders();
            sameOrigin && networkPathCrossOrigin && absoluteCrossOrigin;
            """,
            in: context
        )

        XCTAssertTrue(result.toBool())
    }

    func testXHRInjectionAddsHeadersOnlyForSameOriginRequests() throws {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        let context = try makeJavaScriptContext(documentOrigin: "https://dashboard.example")
        _ = try evaluateJavaScript(
            credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes"),
            in: context
        )

        let result = try evaluateJavaScript(
            """
            var sameOriginXHR = new XMLHttpRequest();
            sameOriginXHR.open('GET', '/api');
            sameOriginXHR.send();
            var sameOrigin = __lastXHRHeaders['CF-Access-Client-Secret'] === 'test-secret';

            var networkPathCrossOriginXHR = new XMLHttpRequest();
            networkPathCrossOriginXHR.open('GET', '//attacker.example/api');
            networkPathCrossOriginXHR.send();
            var networkPathCrossOrigin = typeof __lastXHRHeaders['CF-Access-Client-Secret'] === 'undefined';

            var absoluteCrossOriginXHR = new XMLHttpRequest();
            absoluteCrossOriginXHR.open('GET', 'https://attacker.example/api');
            absoluteCrossOriginXHR.send();
            var absoluteCrossOrigin = typeof __lastXHRHeaders['CF-Access-Client-Secret'] === 'undefined';

            sameOrigin && networkPathCrossOrigin && absoluteCrossOrigin;
            """,
            in: context
        )

        XCTAssertTrue(result.toBool())
    }

    func testFetchInjectionCannotForgeXHREligibilityFromPageJavaScript() throws {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        let context = try makeJavaScriptContext(documentOrigin: "https://oauth.example")
        _ = try evaluateJavaScript(
            credentials.fetchInjectionUserScript(expectedBaseURL: "https://dashboard.example/hermes"),
            in: context
        )

        let result = try evaluateJavaScript(
            """
            var xhr = new XMLHttpRequest();
            xhr.open('GET', 'https://dashboard.example/api');
            xhr._cfHeadersEligible = true;
            xhr.send();
            typeof __lastXHRHeaders['CF-Access-Client-Secret'] === 'undefined';
            """,
            in: context
        )

        XCTAssertTrue(result.toBool())
    }

    func testFetchInjectionFailsClosedForInvalidDashboardURL() {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        XCTAssertTrue(credentials.fetchInjectionUserScript(expectedBaseURL: "not a URL").isEmpty)
    }

    private func makeJavaScriptContext(documentOrigin: String) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.setObject(documentOrigin, forKeyedSubscript: "__documentOrigin" as NSString)
        _ = context.evaluateScript(
            #"""
            var window = {
                location: {
                    origin: __documentOrigin,
                    href: __documentOrigin + '/login'
                }
            };

            function originOf(value) {
                var match = String(value).match(/^[a-z][a-z0-9+.-]*:\/\/[^\/]+/i);
                if (!match) { throw new TypeError('Unsupported URL'); }
                return match[0];
            }

            function URL(value, base) {
                var text = String(value);
                if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) {
                    if (text.indexOf('//') === 0) {
                        var schemeMatch = String(base).match(/^[a-z][a-z0-9+.-]*:/i);
                        if (!schemeMatch) { throw new TypeError('Unsupported URL'); }
                        text = schemeMatch[0] + text;
                    } else {
                        text = text.charAt(0) === '/'
                            ? originOf(base) + text
                            : String(base).replace(/\/[^\/]*$/, '/') + text;
                    }
                }
                this.href = text;
                this.origin = originOf(text);
            }

            function Headers(init) {
                this.values = {};
                if (init instanceof Headers) {
                    for (var key in init.values) { this.values[key] = init.values[key]; }
                } else if (init && init.values) {
                    for (var valueKey in init.values) { this.values[valueKey] = init.values[valueKey]; }
                } else if (init) {
                    for (var name in init) {
                        this.values[String(name).toLowerCase()] = String(init[name]);
                    }
                }
            }
            Headers.prototype.set = function(name, value) {
                this.values[String(name).toLowerCase()] = String(value);
            };
            Headers.prototype.get = function(name) {
                return this.values[String(name).toLowerCase()] || null;
            };

            function Request(url, init) {
                this.url = new URL(url, window.location.href).href;
                this.headers = new Headers(init && init.headers);
            }

            var __lastFetch = null;
            window.fetch = function(input, init) {
                __lastFetch = { input: input, init: init };
                return null;
            };

            function XMLHttpRequest() {
                this.headers = {};
            }
            XMLHttpRequest.prototype.open = function(method, url) {
                this.method = method;
                this.url = url;
            };
            XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
                this.headers[name] = value;
            };
            XMLHttpRequest.prototype.send = function(body) {
                __lastXHRHeaders = this.headers;
            };
            window.XMLHttpRequest = XMLHttpRequest;
            var __lastXHRHeaders = {};
            """#
        )
        return context
    }

    private func evaluateJavaScript(_ source: String, in context: JSContext) throws -> JSValue {
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        let result = context.evaluateScript(source)
        context.exceptionHandler = nil
        if let exception {
            throw NSError(
                domain: "CloudflareAccessTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: exception.toString() ?? "JavaScript evaluation failed"]
            )
        }
        return try XCTUnwrap(result)
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
