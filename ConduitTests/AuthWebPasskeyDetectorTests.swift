import JavaScriptCore
import WebKit
import XCTest
@testable import Conduit

/// The sign-in WebView's passkey detector: the page world wrapper that
/// fires an event when a page asks for a passkey, the isolated world
/// listener that tells Conduit, and the message routing that shows the
/// notice. The scripts run in JavaScriptCore against stand-ins whose
/// methods live on prototypes, as WebKit's do, and once in a real
/// WKWebView.
@MainActor
final class AuthWebPasskeyDetectorTests: XCTestCase {
    // MARK: - Installing and routing

    func testTheScriptsRunAtDocumentStartInEveryFrame() {
        let controller = WKUserContentController()
        AuthWebPasskeyDetector.install(into: controller, handler: Handler())
        defer { AuthWebPasskeyDetector.uninstall(from: controller) }

        XCTAssertEqual(controller.userScripts.map(\.source), [
            AuthWebPasskeyDetector.listenerScriptSource,
            AuthWebPasskeyDetector.pageScriptSource,
        ])
        for script in controller.userScripts {
            XCTAssertEqual(script.injectionTime, .atDocumentStart)
            XCTAssertFalse(script.isForMainFrameOnly, "an identity provider's page can be framed")
        }
    }

    func testOnlyTheListenersMessageShowsTheNotice() {
        let name = AuthWebPasskeyDetector.messageName
        let body = AuthWebPasskeyDetector.messageBody
        let conduit = DashboardScriptWorld.world.name
        XCTAssertNotEqual(name, "ticket")
        XCTAssertTrue(AuthWebPasskeyDetector.isPasskeyRequest(name: name, worldName: conduit, body: body))
        XCTAssertFalse(AuthWebPasskeyDetector.isPasskeyRequest(name: name, worldName: nil, body: body), "the page world")
        XCTAssertFalse(AuthWebPasskeyDetector.isPasskeyRequest(name: name, worldName: conduit, body: "{}"))
        XCTAssertFalse(AuthWebPasskeyDetector.isPasskeyRequest(name: name, worldName: conduit, body: 1))
        XCTAssertFalse(AuthWebPasskeyDetector.isPasskeyRequest(name: "ticket", worldName: conduit, body: body))
    }

    // MARK: - The page world wrapper

    func testAPasskeySignInFiresTheEventForEachCall() throws {
        let context = try makePage()
        try evaluate("navigator.credentials.get({ publicKey: { challenge: 'c' } })", in: context)
        try evaluate("navigator.credentials.get({ publicKey: { challenge: 'c' } })", in: context)
        XCTAssertEqual(try events(in: context), [AuthWebPasskeyDetector.eventName, AuthWebPasskeyDetector.eventName])
    }

    func testAutofillOtherCredentialsAndRegistrationFireNothing() throws {
        let context = try makePage()
        for call in [
            "navigator.credentials.get({ publicKey: { challenge: 'c' }, mediation: 'conditional' })",
            "navigator.credentials.get({ password: true })",
            "navigator.credentials.get()",
            "navigator.credentials.get(null)",
            "navigator.credentials.create({ publicKey: { challenge: 'c' } })",
        ] {
            try evaluate(call, in: context)
        }
        XCTAssertEqual(try events(in: context), [])
        XCTAssertEqual(try evaluate("calls.length", in: context).toInt32(), 5, "every call still reaches the browser")
    }

    func testThePageGetsTheBrowsersOwnAnswer() throws {
        let context = try makePage()
        try evaluate("""
        var options = { publicKey: { challenge: 'c' } };
        var answer = navigator.credentials.get(options, 'extra');
        """, in: context)
        XCTAssertTrue(try evaluate("answer === browserAnswer", in: context).toBool())
        XCTAssertTrue(try evaluate("calls[0].receiver === navigator.credentials", in: context).toBool())
        XCTAssertTrue(try evaluate("calls[0].options === options", in: context).toBool())
        XCTAssertEqual(try evaluate("calls[0].count", in: context).toInt32(), 2)
        XCTAssertEqual(try evaluate("calls[0].name", in: context).toString(), "get")
    }

    func testTheWrapperLooksLikeTheBrowsersMethod() throws {
        let context = try makePage()
        try evaluate("var wrapped = Object.getOwnPropertyDescriptor(Credentials.prototype, 'get');", in: context)
        XCTAssertFalse(try evaluate("wrapped.value === browserGet", in: context).toBool())
        XCTAssertEqual(try evaluate("wrapped.value.name", in: context).toString(), "get")
        XCTAssertEqual(try evaluate("wrapped.value.length", in: context).toInt32(), 0)
        XCTAssertTrue(try evaluate("wrapped.value.prototype === undefined", in: context).toBool())
        XCTAssertTrue(try evaluate("wrapped.enumerable && wrapped.writable && wrapped.configurable", in: context).toBool())
        XCTAssertTrue(try evaluate("Credentials.prototype.create === browserCreate", in: context).toBool())
    }

    func testTheBrowsersErrorsReachThePage() throws {
        let context = try makePage()
        try evaluate("browserThrows = true", in: context)
        XCTAssertEqual(
            try evaluate("try { navigator.credentials.get({ publicKey: {} }); 'none' } catch (e) { e.name }", in: context).toString(),
            "NotAllowedError"
        )
    }

    func testAPageThatBreaksEventsStillGetsItsPasskeyRequest() throws {
        let context = try makePage()
        try evaluate("EventTarget.prototype.dispatchEvent = function () { throw new Error('gone'); }", in: context)
        try evaluate("navigator.credentials.get({ publicKey: {} })", in: context)
        XCTAssertEqual(try evaluate("calls.length", in: context).toInt32(), 1)
        XCTAssertEqual(try events(in: context), [AuthWebPasskeyDetector.eventName], "it kept the dispatch it found at document start")
    }

    func testTheWrapperOutlivesWebKitRecreatingTheCredentialsObject() throws {
        let context = try makePage()
        XCTAssertEqual(try evaluate("Object.getOwnPropertyNames(navigator.credentials).length", in: context).toInt32(), 0, "nothing on the object itself")
        // WebKit drops a DOM object's JavaScript wrapper and makes a new one
        // later, without anything a script set on the old one.
        try evaluate("window.navigator = { credentials: new Credentials() }; navigator = window.navigator;", in: context)
        try evaluate("navigator.credentials.get({ publicKey: {} })", in: context)
        XCTAssertEqual(try events(in: context), [AuthWebPasskeyDetector.eventName])
    }

    func testWithoutCredentialsTheScriptDoesNothing() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluate("var window = this; window.navigator = {}; var document = {};", in: context)
        try evaluate(AuthWebPasskeyDetector.pageScriptSource, in: context)
        XCTAssertTrue(try evaluate("navigator.credentials === undefined", in: context).toBool())
    }

    // MARK: - The isolated world listener

    func testTheListenerPostsOnlyTheFixedMessage() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluate("""
        var window = this;
        var posted = [];
        var listeners = {};
        var document = { addEventListener: function (type, listener) { listeners[type] = listener; } };
        window.webkit = { messageHandlers: { \(AuthWebPasskeyDetector.messageName): { postMessage: function (body) { posted.push(body); } } } };
        """, in: context)
        try evaluate(AuthWebPasskeyDetector.listenerScriptSource, in: context)
        try evaluate("listeners['\(AuthWebPasskeyDetector.eventName)']({ detail: 'from the page' })", in: context)
        XCTAssertEqual(try evaluate("posted", in: context).toArray() as? [String], [AuthWebPasskeyDetector.messageBody])
        XCTAssertEqual(try evaluate("Object.keys(listeners)", in: context).toArray() as? [String], [AuthWebPasskeyDetector.eventName])
    }

    func testWithoutItsHandlerTheListenerDoesNothing() throws {
        let context = try XCTUnwrap(JSContext())
        try evaluate("var window = this; var added = 0; var document = { addEventListener: function () { added++; } }; window.webkit = { messageHandlers: {} };", in: context)
        try evaluate(AuthWebPasskeyDetector.listenerScriptSource, in: context)
        XCTAssertEqual(try evaluate("added", in: context).toInt32(), 0)
    }

    // MARK: - In WebKit

    func testARealPageAskingForAPasskeyReachesConduitAndKeepsItsOwnWorld() async throws {
        let handler = Handler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        AuthWebPasskeyDetector.install(into: configuration.userContentController, handler: handler)
        defer { AuthWebPasskeyDetector.uninstall(from: configuration.userContentController) }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let delegate = LoadDelegate()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            #"<!DOCTYPE html><html><body><iframe id="frame" srcdoc="<p>framed</p>"></iframe></body></html>"#,
            baseURL: URL(string: "https://idp.conduit-tests.invalid/"))
        try await delegate.waitForLoad()

        let page = try await webView.callAsyncJavaScript("""
        return {
          webkit: typeof window.webkit,
          own: Object.getOwnPropertyNames(navigator.credentials).length,
          wrapped: !String(CredentialsContainer.prototype.get).includes('[native code]')
        };
        """, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(page?["webkit"] as? String, "undefined", "the page world gets no message handler")
        XCTAssertEqual(page?["own"] as? Int, 0)
        XCTAssertEqual(page?["wrapped"] as? Bool, true)

        // An already-aborted request settles without reaching an
        // authenticator; this app isn't entitled for the site either. Once
        // from the page, once from inside its frame.
        let outcomes = try await webView.callAsyncJavaScript("""
        async function ask(credentials) {
          const controller = new AbortController();
          controller.abort();
          try {
            await credentials.get({ publicKey: { challenge: new Uint8Array(16) }, signal: controller.signal });
            return 'resolved';
          } catch (error) {
            return error.name;
          }
        }
        const frame = document.getElementById('frame').contentWindow;
        return [await ask(navigator.credentials), await ask(frame.navigator.credentials)];
        """, contentWorld: .page) as? [String]
        XCTAssertEqual(outcomes?.count, 2)
        for outcome in outcomes ?? [] {
            XCTAssertTrue(["AbortError", "NotAllowedError"].contains(outcome), "the browser's own answer, got \(outcome)")
        }

        for _ in 0..<50 where handler.bodies.count < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(handler.bodies, [AuthWebPasskeyDetector.messageBody, AuthWebPasskeyDetector.messageBody])
        XCTAssertEqual(handler.worldNames, [DashboardScriptWorld.world.name, DashboardScriptWorld.world.name])
    }

    // MARK: - Helpers

    private final class Handler: NSObject, WKScriptMessageHandler {
        private(set) var bodies: [String] = []
        private(set) var worldNames: [String?] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            bodies.append(message.body as? String ?? "")
            worldNames.append(message.world.name)
        }
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private var finished = false
        private var failure: Error?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }

        func waitForLoad() async throws {
            for _ in 0..<100 where !finished {
                if let failure { throw failure }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(finished, "the probe page never loaded")
        }
    }

    /// A page whose `navigator.credentials` records each call and answers
    /// with `browserAnswer`, with the page script installed. `events`
    /// lists what it dispatched on the document.
    private func makePage() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        try evaluate("""
        var window = this;
        var calls = [];
        var events = [];
        var browserAnswer = { then: function () {} };
        var browserThrows = false;
        function EventTarget() {}
        EventTarget.prototype.dispatchEvent = function (event) { events.push(event.type); return true; };
        function Event(type) { this.type = type; }
        var document = new EventTarget();
        function Credentials() {}
        ['get', 'create'].forEach(function (name) {
          Credentials.prototype[name] = function () {
            calls.push({ name: name, receiver: this, options: arguments[0], count: arguments.length });
            if (browserThrows) { var error = new Error('denied'); error.name = 'NotAllowedError'; throw error; }
            return browserAnswer;
          };
          Object.defineProperty(Credentials.prototype[name], 'name', { value: name });
        });
        var browserGet = Credentials.prototype.get;
        var browserCreate = Credentials.prototype.create;
        window.navigator = { credentials: new Credentials() };
        var navigator = window.navigator;
        """, in: context)
        try evaluate(AuthWebPasskeyDetector.pageScriptSource, in: context)
        return context
    }

    private func events(in context: JSContext) throws -> [String] {
        try evaluate("events", in: context).toArray() as? [String] ?? []
    }

    @discardableResult
    private func evaluate(_ source: String, in context: JSContext) throws -> JSValue {
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        let result = context.evaluateScript(source)
        context.exceptionHandler = nil
        if let exception {
            throw NSError(domain: "AuthWebPasskeyDetectorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: exception.toString() ?? "JavaScript failed"])
        }
        return try XCTUnwrap(result)
    }
}
