import ObjectiveC
import WebKit
import XCTest
@testable import Conduit

/// Each navigation delegate's policy method must keep matching
/// WKNavigationDelegate. A method that only nearly matches (a decision
/// handler without @MainActor @Sendable, under strict concurrency) is not
/// exposed to Objective-C: WebKit never calls it, and every navigation it
/// would cancel is allowed. The default (minimal) checking still matches a
/// plain closure, so this catches that slip once the tests build with
/// complete checking or Swift 6; today it pins the selector and the list.
final class WebKitNavigationPolicyConformanceTests: XCTestCase {
    /// The selector WebKit asks the delegate about.
    private let policySelector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")

    private let delegates: [(name: String, type: AnyClass)] = [
        ("AuthWebView.Coordinator", AuthWebView.Coordinator.self),
        ("DashboardTicketBridge", DashboardTicketBridge.self),
        ("HTMLPreviewWebView.Coordinator", HTMLPreviewWebView.Coordinator.self),
        ("MarkupWebView.Coordinator", MarkupWebView.Coordinator.self),
        ("SafeMarkupWebView.Coordinator", SafeMarkupWebView.Coordinator.self),
        ("RemoteImageWebView.Coordinator", RemoteImageWebView.Coordinator.self),
    ]

    func testTheSelectorIsWebKitsPolicyRequirement() {
        let method = protocol_getMethodDescription(WKNavigationDelegate.self, policySelector, false, true)
        XCTAssertNotNil(method.name, "WKNavigationDelegate no longer declares \(policySelector)")
    }

    func testEveryNavigationDelegateAnswersThePolicySelector() {
        for delegate in delegates {
            XCTAssertTrue(
                class_conformsToProtocol(delegate.type, WKNavigationDelegate.self),
                "\(delegate.name) is no WKNavigationDelegate"
            )
            XCTAssertTrue(
                class_respondsToSelector(delegate.type, policySelector),
                "WebKit would never ask \(delegate.name) before a navigation"
            )
        }
    }

    /// A new navigation delegate in the app is listed above, so its policy
    /// method is checked too.
    func testNoNavigationDelegateIsLeftUnchecked() throws {
        // The image holding the app's code (Conduit, or Conduit.debug.dylib
        // in a debug build).
        let image = try XCTUnwrap(class_getImageName(DashboardTicketBridge.self))
        var count: UInt32 = 0
        let names = try XCTUnwrap(objc_copyClassNamesForImage(image, &count))
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        let listed = Set(delegates.map { ObjectIdentifier($0.type) })
        var found = 0
        for index in 0 ..< Int(count) {
            guard let type = objc_getClass(names[index]) as? AnyClass,
                  class_conformsToProtocol(type, WKNavigationDelegate.self) else { continue }
            found += 1
            XCTAssertTrue(listed.contains(ObjectIdentifier(type)), "\(NSStringFromClass(type)) is not listed")
        }
        XCTAssertEqual(found, delegates.count, "the sweep missed a listed delegate")
    }
}
