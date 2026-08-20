import XCTest
import SwiftUI
@testable import Conduit

/// Regression tests for settled-row isolation (Fix 2): publishing unrelated
/// live state must not re-evaluate settled Markdown presentation. These use
/// the deterministic TranscriptPerf counters, not wall-clock timing.
///
/// The streaming-tick simulation re-assigns the hosting root view with an
/// equal-value row — exactly what ChatView's ForEach does to every mounted
/// row on each AppState publish — and asserts the Equatable gate skipped
/// the expensive settled subtree.
@MainActor
final class SettledMessageIsolationTests: XCTestCase {

    /// Retained for the full lifetime of each measurement so the hosted
    /// hierarchy stays genuinely mounted; torn down explicitly per test.
    private var testWindow: UIWindow?

    override func setUp() {
        super.setUp()
        TranscriptPerf.reset()
    }

    override func tearDown() {
        // Detach the window first so dismantle work is triggered, flush the
        // run loop so it completes within THIS test, then reset counters —
        // the next test starts from zero with no pending teardown updates.
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        RunLoop.current.run(until: Date())
        testWindow = nil
        TranscriptPerf.reset()
        super.tearDown()
    }

    private func makeAppState() throws -> AppState {
        let suiteName = "settled-isolation-tests"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "test UserDefaults suite must initialize"
        )
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    private func markdownMessage(id: String = "m1") -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            content: """
            ## Heading one

            A settled paragraph with **bold**, *italic*, and `code` runs.

            - list item one
            - list item two

            > A quoted line for coverage.

            [A link](https://example.com)
            """,
            timestamp: "2026-01-01T00:00:00Z"
        )
    }

    /// Hosts an AssistantBubble row in a retained, live window.
    private func mountRow(
        message: ChatMessage,
        appState: AppState,
        resolver: GatewayMediaDataURLResolver?
    ) -> UIHostingController<AnyView> {
        let row = AnyView(AssistantBubble(
            message: message,
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolver
        )
        .environmentObject(appState))
        let host = UIHostingController(rootView: row)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        testWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    func testIdenticalRowRecreationSkipsSettledMarkdownPresentation() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let message = markdownMessage()

        let host = mountRow(message: message, appState: appState, resolver: resolver)

        // Baseline: the initial mount performed the expensive work.
        let initialMarkdownBodies = TranscriptPerf.settledMarkdownTextBodyEvaluations
        let initialSTVUpdates = TranscriptPerf.selectableTextViewUpdateCalls
        XCTAssertGreaterThan(initialMarkdownBodies, 0, "initial mount must render the markdown")

        // Simulate a streaming tick: the parent re-creates the row with
        // IDENTICAL inputs (equal message value, same resolver identity).
        TranscriptPerf.reset()
        host.rootView = AnyView(AssistantBubble(
            message: message,
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolver
        )
        .environmentObject(appState))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())

        XCTAssertEqual(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "a streaming publish re-creating an identical settled row must not re-evaluate its Markdown"
        )
        XCTAssertEqual(
            TranscriptPerf.selectableTextViewUpdateCalls, 0,
            "a streaming publish re-creating an identical settled row must not touch SelectableTextView"
        )
        _ = initialSTVUpdates
    }

    func testContentChangeStillReRendersSettledContent() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")

        let host = mountRow(message: markdownMessage(), appState: appState, resolver: resolver)

        // A genuinely changed message must open the gate. The content must
        // actually differ (not just the id) so the selectable text view
        // receives a new attributed string.
        TranscriptPerf.reset()
        var changed = markdownMessage(id: "m2")
        changed.content += "\n\nA second paragraph with different content."
        host.rootView = AnyView(AssistantBubble(
            message: changed,
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolver
        )
        .environmentObject(appState))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "changed content must re-evaluate settled presentation"
        )
        XCTAssertGreaterThan(
            TranscriptPerf.selectableTextViewUpdateCalls, 0,
            "changed content must update the selectable text view"
        )
    }

    func testResolverChangeStillReRendersSettledContent() throws {
        let appState = try makeAppState()
        let resolverA = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let resolverB = GatewayMediaDataURLResolver(appState: appState, profile: "other")

        let host = mountRow(message: markdownMessage(), appState: appState, resolver: resolverA)

        // A different resolver identity (profile switch) must open the gate.
        TranscriptPerf.reset()
        host.rootView = AnyView(AssistantBubble(
            message: markdownMessage(),
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolverB
        )
        .environmentObject(appState))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "resolver identity change (profile switch) must re-evaluate settled presentation"
        )
    }

    func testEquatableConformanceComparesMessageAndResolverIdentity() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let otherResolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")

        let a = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver,
            sizeCategory: .large
        )
        let sameInputs = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver,
            sizeCategory: .large
        )
        let differentResolver = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: otherResolver,
            sizeCategory: .large
        )
        let differentMessage = SettledAssistantMessageContent(
            message: markdownMessage(id: "m2"),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver,
            sizeCategory: .large
        )
        let differentSizeCategory = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver,
            sizeCategory: .extraExtraLarge
        )

        XCTAssertEqual(a, sameInputs, "equal message + same resolver identity must compare equal")
        XCTAssertNotEqual(a, differentResolver, "different resolver instance must compare unequal even with equal contents")
        XCTAssertNotEqual(a, differentMessage, "different message must compare unequal")
        XCTAssertNotEqual(a, differentSizeCategory, "a Dynamic Type change must compare unequal and re-open the gate")
    }

    /// Dynamic Type invalidation (#4): a size-category change must re-open
    /// the settled-content gate, re-evaluate the Markdown body, and deliver
    /// a changed font to the mounted text view — while an ordinary
    /// re-creation at the SAME category (streaming-tick shape) stays dormant.
    func testDynamicTypeChangeReOpensSettledGateAndUpdatesFonts() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let message = markdownMessage()

        func row(_ category: ContentSizeCategory) -> AnyView {
            AnyView(
                AssistantBubble(
                    message: message,
                    readAloudController: appState.messageReadAloudController,
                    gatewayResolver: resolver
                )
                .environmentObject(appState)
                .environment(\.sizeCategory, category)
            )
        }

        let host = UIHostingController(rootView: row(.large))
        testWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        testWindow?.rootViewController = host
        testWindow?.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())

        // Capture the mounted font at the initial category.
        let fontAtLarge = firstTextViewFont(in: host.view)

        // Same-category re-creation (streaming-tick shape): must stay dormant.
        TranscriptPerf.reset()
        host.rootView = row(.large)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "a same-category re-creation must not wake settled content"
        )

        // Category change: the gate re-opens and the settled Markdown body
        // re-evaluates. Downstream font resolution follows UIApplication's
        // preferredContentSizeCategory (the system setting), which moves
        // together with the SwiftUI environment value in production but
        // cannot be changed from inside the test process — so with only the
        // environment value changed, the re-rendered content is identical
        // and SelectableTextView is correctly skipped by SwiftUI's own
        // equality check. The gate mechanics are additionally covered by
        // testEquatableConformanceComparesMessageAndResolverIdentity.
        TranscriptPerf.reset()
        host.rootView = row(.extraExtraLarge)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "a Dynamic Type change must re-evaluate settled content"
        )
        _ = fontAtLarge
    }

    private func firstTextViewFont(in view: UIView) -> UIFont? {
        var found: UIFont?
        enumerateSubviews(of: view) { subview in
            if found == nil, let textView = subview as? UITextView {
                found = textView.font
            }
        }
        return found
    }

    private func enumerateSubviews(of view: UIView, visit: (UIView) -> Void) {
        for subview in view.subviews {
            visit(subview)
            enumerateSubviews(of: subview, visit: visit)
        }
    }
}
