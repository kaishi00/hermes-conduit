import Foundation
import JavaScriptCore
import XCTest
@testable import Conduit

final class CustomHeadersTests: XCTestCase {
    private func makeStore(
        initial: [String: [CustomHeader]] = [:],
        persisted: ((([String: [CustomHeader]]) -> Void))? = nil
    ) -> CustomHeaderStore {
        CustomHeaderStore(load: { initial }, persist: { persisted?($0) })
    }

    private func request(_ string: String) throws -> URLRequest {
        URLRequest(url: try XCTUnwrap(URL(string: string)))
    }

    // MARK: - Validation

    func testValidHeaderHasNoIssue() {
        XCTAssertNil(CustomHeaderPolicy.issue(for: CustomHeader(name: "X-Pangolin-Key", value: "secret value")))
        XCTAssertNil(CustomHeaderPolicy.issue(for: CustomHeader(name: "  Authorization ", value: "Basic dXNlcjpwYXNz")))
    }

    func testInvalidNamesAreRejected() {
        XCTAssertEqual(CustomHeaderPolicy.issue(for: CustomHeader(name: "  ", value: "v")), .emptyName)
        XCTAssertEqual(CustomHeaderPolicy.issue(for: CustomHeader(name: "X Key", value: "v")), .invalidName)
        XCTAssertEqual(CustomHeaderPolicy.issue(for: CustomHeader(name: "X-Key:", value: "v")), .invalidName)
        XCTAssertEqual(CustomHeaderPolicy.issue(for: CustomHeader(name: "X-Kéy", value: "v")), .invalidName)
    }

    func testTransportOwnedNamesAreReserved() {
        for name in ["Host", "cookie", "Content-Length", "Connection", "Upgrade", "Origin", "Sec-WebSocket-Key"] {
            XCTAssertEqual(CustomHeaderPolicy.issue(for: CustomHeader(name: name, value: "v")), .reservedName, name)
        }
    }

    func testLineBreaksInValuesAreRejected() {
        XCTAssertEqual(CustomHeaderPolicy.issue(for: CustomHeader(name: "X-Key", value: "a\r\nX-Evil: 1")), .invalidValue)
        XCTAssertEqual(CustomHeaderPolicy.issue(for: CustomHeader(name: "X-Key", value: "a\nb")), .invalidValue)
        XCTAssertNil(CustomHeaderPolicy.issue(for: CustomHeader(name: "X-Key", value: "a\tb")))
    }

    func testSendableDropsInvalidRowsAndRepeatedNames() {
        let headers = [
            CustomHeader(name: " X-Key ", value: "first"),
            CustomHeader(name: "x-key", value: "second"),
            CustomHeader(name: "Host", value: "evil"),
            CustomHeader(name: "X-Other", value: "o"),
        ]
        let sendable = CustomHeaderPolicy.sendable(headers)
        XCTAssertEqual(sendable.map(\.name), ["X-Key", "X-Other"])
        XCTAssertEqual(sendable.first?.value, "first")
    }

    // MARK: - Origin binding

    func testOriginIsSecureOnlyAndIgnoresDefaultPort() throws {
        XCTAssertEqual(CustomHeaderPolicy.origin(forServerURL: "https://Hermes.Example/dash"), "https://hermes.example")
        XCTAssertEqual(CustomHeaderPolicy.origin(forServerURL: "https://hermes.example:443"), "https://hermes.example")
        XCTAssertEqual(CustomHeaderPolicy.origin(forServerURL: "https://hermes.example:8443"), "https://hermes.example:8443")
        XCTAssertEqual(CustomHeaderPolicy.origin(for: try XCTUnwrap(URL(string: "wss://hermes.example/api/ws"))), "https://hermes.example")
        XCTAssertNil(CustomHeaderPolicy.origin(forServerURL: "http://192.168.1.20:9119"))
        XCTAssertNil(CustomHeaderPolicy.origin(forServerURL: "not a url"))
    }

    // MARK: - Store

    func testHeadersApplyOnlyToTheirOriginOverSecureTransports() throws {
        let store = makeStore()
        XCTAssertTrue(store.setHeaders([CustomHeader(name: "X-Proxy-Key", value: "k1")], forServerURL: "https://hermes.example/dash"))

        let api = store.applying(to: try request("https://hermes.example/api/status"))
        XCTAssertEqual(api.value(forHTTPHeaderField: "X-Proxy-Key"), "k1")
        let socket = store.applying(to: try request("wss://hermes.example/api/ws?ticket=t"))
        XCTAssertEqual(socket.value(forHTTPHeaderField: "X-Proxy-Key"), "k1")

        for other in ["https://other.example/api", "https://hermes.example:8443/api", "http://hermes.example/api", "ws://hermes.example/api/ws"] {
            XCTAssertNil(store.applying(to: try request(other)).value(forHTTPHeaderField: "X-Proxy-Key"), other)
        }
    }

    func testCleartextAddressCannotStoreHeaders() {
        let store = makeStore()
        XCTAssertFalse(store.setHeaders([CustomHeader(name: "X-Key", value: "v")], forServerURL: "http://192.168.1.20:9119"))
        XCTAssertTrue(store.headers(forServerURL: "http://192.168.1.20:9119").isEmpty)
    }

    func testExistingRequestHeadersAlwaysWin() throws {
        let store = makeStore()
        store.setHeaders([
            CustomHeader(name: "Authorization", value: "Basic proxy"),
            CustomHeader(name: "CF-Access-Client-Id", value: "override"),
        ], forServerURL: "https://hermes.example")
        var bearer = try request("https://hermes.example/api/oauth")
        bearer.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(store.applying(to: bearer).value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(store.applying(to: try request("https://hermes.example/api")).value(forHTTPHeaderField: "Authorization"), "Basic proxy")

        let cloudflare = CloudflareAccessCredentials(clientID: "cf-id", clientSecret: "cf-secret")
        let combined = try request("https://hermes.example/api").applyingProxyHeaders(cloudflare: cloudflare, store: store)
        XCTAssertEqual(combined.value(forHTTPHeaderField: "CF-Access-Client-Id"), "cf-id")
        XCTAssertEqual(combined.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "cf-secret")
        XCTAssertEqual(combined.value(forHTTPHeaderField: "Authorization"), "Basic proxy")
    }

    func testCloudflareOnlyRequestsAreUnchangedWithoutExtraHeaders() throws {
        let store = makeStore()
        let cloudflare = CloudflareAccessCredentials(clientID: "cf-id", clientSecret: "cf-secret")
        let base = try request("https://hermes.example/api")
        XCTAssertEqual(base.applyingProxyHeaders(cloudflare: cloudflare, store: store), cloudflare.applying(to: base))
        XCTAssertEqual(base.applyingProxyHeaders(cloudflare: nil, store: store), base)
    }

    func testInvalidRowsAreKeptForEditingButNeverSent() throws {
        let store = makeStore()
        store.setHeaders([
            CustomHeader(name: "Bad Name", value: "v"),
            CustomHeader(name: "", value: ""),
            CustomHeader(name: "X-Good", value: "g"),
        ], forServerURL: "https://hermes.example")
        XCTAssertEqual(store.headers(forServerURL: "https://hermes.example").map(\.name), ["Bad Name", "X-Good"])
        let applied = store.applying(to: try request("https://hermes.example/api"))
        XCTAssertNil(applied.value(forHTTPHeaderField: "Bad Name"))
        XCTAssertEqual(applied.value(forHTTPHeaderField: "X-Good"), "g")
    }

    func testChangesPersistAndRemovalDropsTheOrigin() {
        var persisted: [String: [CustomHeader]]?
        let store = makeStore(
            initial: ["https://keep.example": [CustomHeader(name: "X-Keep", value: "1")]],
            persisted: { persisted = $0 }
        )
        store.setHeaders([CustomHeader(name: "X-Key", value: "v")], forServerURL: "https://hermes.example")
        XCTAssertEqual(persisted?.keys.sorted(), ["https://hermes.example", "https://keep.example"])
        store.removeHeaders(forServerURL: "https://hermes.example/")
        XCTAssertEqual(persisted?.keys.sorted(), ["https://keep.example"])
    }

    func testKeychainRoundTrip() {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let headers = ["https://hermes.example": [CustomHeader(name: "X-Key", value: "secret")]]
        KeychainHelper.saveCustomHeaders(headers)
        XCTAssertEqual(KeychainHelper.loadCustomHeaders(), headers)
        KeychainHelper.saveCustomHeaders([:])
        XCTAssertEqual(KeychainHelper.loadCustomHeaders(), [:])
    }

    @MainActor
    func testSharedStoreReachesKanbanUpgradeRequests() throws {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock {
            CustomHeaderStore.shared.removeHeaders(forServerURL: "https://kanban-headers.example")
            KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        }
        CustomHeaderStore.shared.setHeaders([CustomHeader(name: "X-Proxy-Key", value: "k")], forServerURL: "https://kanban-headers.example")
        let upgrade = URLSessionKanbanEventSocket.upgradeRequest(
            url: try XCTUnwrap(URL(string: "wss://kanban-headers.example/api/kanban/ws")),
            cloudflareAccess: nil
        )
        XCTAssertEqual(upgrade.value(forHTTPHeaderField: "X-Proxy-Key"), "k")
    }

    // MARK: - WebView injection

    func testInjectionIsEmptyForCleartextOrUnconfiguredOrigins() {
        let store = makeStore(initial: ["https://hermes.example": [CustomHeader(name: "X-Key", value: "v")]])
        XCTAssertTrue(store.fetchInjectionUserScript(expectedBaseURL: "http://hermes.example").isEmpty)
        XCTAssertTrue(store.fetchInjectionUserScript(expectedBaseURL: "https://other.example").isEmpty)
        XCTAssertFalse(store.fetchInjectionUserScript(expectedBaseURL: "https://hermes.example/dash").isEmpty)
    }

    func testInjectionAddsHeadersToSameOriginFetchAndXHROnly() throws {
        let store = makeStore(initial: ["https://hermes.example": [
            CustomHeader(name: "X-Proxy-Key", value: "it's \"quoted\""),
            CustomHeader(name: "Authorization", value: "Basic proxy"),
        ]])
        let context = try makeJavaScriptContext(documentOrigin: "https://hermes.example")
        _ = try evaluate(store.fetchInjectionUserScript(expectedBaseURL: "https://hermes.example/dash"), in: context)

        let result = try evaluate(
            """
            function sent() { return new Headers(__lastFetch.init && __lastFetch.init.headers); }
            window.fetch('/api');
            var sameOrigin = sent().get('X-Proxy-Key') === "it's \\"quoted\\"" && sent().get('Authorization') === 'Basic proxy';
            window.fetch('/api', { headers: { Authorization: 'Bearer page' } });
            var pageWins = sent().get('Authorization') === 'Bearer page' && sent().get('X-Proxy-Key') !== null;
            window.fetch('https://attacker.example/api');
            var crossOrigin = sent().get('X-Proxy-Key') === null;

            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/api');
            xhr.setRequestHeader('Authorization', 'Bearer page');
            xhr.send();
            var xhrSame = __lastXHRHeaders['X-Proxy-Key'] !== undefined && __lastXHRHeaders['Authorization'] === 'Bearer page';
            var crossXHR = new XMLHttpRequest();
            crossXHR.open('GET', 'https://attacker.example/api');
            crossXHR.send();
            var xhrCross = __lastXHRHeaders['X-Proxy-Key'] === undefined;
            [sameOrigin, pageWins, crossOrigin, xhrSame, xhrCross].join(',');
            """,
            in: context
        )
        XCTAssertEqual(result.toString(), "true,true,true,true,true")
    }

    private func makeJavaScriptContext(documentOrigin: String) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.setObject(documentOrigin, forKeyedSubscript: "__documentOrigin" as NSString)
        _ = context.evaluateScript(
            #"""
            var window = { location: { origin: __documentOrigin, href: __documentOrigin + '/login' } };
            function originOf(value) {
                var match = String(value).match(/^[a-z][a-z0-9+.-]*:\/\/[^\/]+/i);
                if (!match) { throw new TypeError('Unsupported URL'); }
                return match[0];
            }
            function URL(value, base) {
                var text = String(value);
                if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) {
                    text = text.charAt(0) === '/' ? originOf(base) + text : String(base).replace(/\/[^\/]*$/, '/') + text;
                }
                this.href = text;
                this.origin = originOf(text);
            }
            function Headers(init) {
                this.values = {};
                if (init && init.values) {
                    for (var key in init.values) { this.values[key] = init.values[key]; }
                } else if (init) {
                    for (var name in init) { this.values[String(name).toLowerCase()] = String(init[name]); }
                }
            }
            Headers.prototype.set = function(name, value) { this.values[String(name).toLowerCase()] = String(value); };
            Headers.prototype.get = function(name) {
                var value = this.values[String(name).toLowerCase()];
                return value === undefined ? null : value;
            };
            Headers.prototype.has = function(name) { return this.values[String(name).toLowerCase()] !== undefined; };
            var __lastFetch = null;
            window.fetch = function(input, init) { __lastFetch = { input: input, init: init }; return null; };
            function XMLHttpRequest() { this.headers = {}; }
            XMLHttpRequest.prototype.open = function(method, url) { this.url = url; };
            XMLHttpRequest.prototype.setRequestHeader = function(name, value) { this.headers[name] = value; };
            XMLHttpRequest.prototype.send = function(body) { __lastXHRHeaders = this.headers; };
            var __lastXHRHeaders = {};
            """#
        )
        return context
    }

    private func evaluate(_ source: String, in context: JSContext) throws -> JSValue {
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        let result = context.evaluateScript(source)
        context.exceptionHandler = nil
        if let exception {
            throw NSError(domain: "CustomHeadersTests", code: 1, userInfo: [NSLocalizedDescriptionKey: exception.toString() ?? "JavaScript failed"])
        }
        return try XCTUnwrap(result)
    }
}
