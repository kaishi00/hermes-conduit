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

    private func makeAppState() -> AppState {
        let defaults = UserDefaults(suiteName: "settled-isolation-tests")!
        defaults.removePersistentDomain(forName: "settled-isolation-tests")
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

    /// Hosts an AssistantBubble row and returns the hosting controller.
    private func mountRow(
        message: ChatMessage,
        appState: AppState,
        resolver: GatewayMediaDataURLResolver?
    ) -> (UIHostingController<AnyView>, UIWindow) {
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
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return (host, window)
    }

    func testIdenticalRowRecreationSkipsSettledMarkdownPresentation() {
        let appState = makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let message = markdownMessage()

        let (host, _) = mountRow(message: message, appState: appState, resolver: resolver)

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

    func testContentChangeStillReRendersSettledContent() {
        let appState = makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")

        let (host, _) = mountRow(message: markdownMessage(), appState: appState, resolver: resolver)

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

    func testResolverChangeStillReRendersSettledContent() {
        let appState = makeAppState()
        let resolverA = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let resolverB = GatewayMediaDataURLResolver(appState: appState, profile: "other")

        let (host, _) = mountRow(message: markdownMessage(), appState: appState, resolver: resolverA)

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

    func testEquatableConformanceComparesMessageAndResolverIdentity() {
        let appState = makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let otherResolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")

        let a = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver
        )
        let sameInputs = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver
        )
        let differentResolver = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: otherResolver
        )
        let differentMessage = SettledAssistantMessageContent(
            message: markdownMessage(id: "m2"),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver
        )

        XCTAssertEqual(a, sameInputs, "equal message + same resolver identity must compare equal")
        XCTAssertNotEqual(a, differentResolver, "different resolver instance must compare unequal even with equal contents")
        XCTAssertNotEqual(a, differentMessage, "different message must compare unequal")
    }
}
