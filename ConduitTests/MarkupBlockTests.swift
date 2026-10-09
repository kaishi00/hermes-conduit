//
//  MarkupBlockTests.swift
//  ConduitTests
//
//  Diagrams and formulas draw in the message on their own once their block
//  is complete. An extension of an existing class, so the CI planner's
//  class inventory doesn't change.
//

import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Conduit

extension MarkdownFallbackTests {
    // MARK: Drawing in place

    @MainActor
    func testDiagramsAndFormulasDrawWithoutATap() {
        let diagram = "Intro.\n\n```mermaid\nflowchart TD\n  A --> B\n```"
        XCTAssertEqual(markupPageCount(in: MarkdownText(source: diagram)), 1)

        let formula = "Intro.\n\n$$\na^2 + b^2 = c^2\n$$"
        XCTAssertEqual(markupPageCount(in: MarkdownText(source: formula)), 1)
    }

    @MainActor
    func testOnlyAStreamingReplysLastBlockWaitsToDraw() {
        // Text after the fence means the diagram is finished.
        let finished = "Intro.\n\n```mermaid\nflowchart TD\n  A --> B\n```\n\nMore text."
        XCTAssertEqual(markupPageCount(in: MarkdownText(source: finished, isStreaming: true)), 1)

        let halfWritten = "Intro.\n\n```mermaid\nflowchart TD\n  A -->"
        XCTAssertEqual(
            markupPageCount(in: MarkdownText(source: halfWritten, isStreaming: true)),
            0,
            "the block still being written shows its source"
        )
        XCTAssertEqual(
            markupPageCount(in: MarkdownText(source: halfWritten)),
            1,
            "a settled reply draws whatever it ends with"
        )
        XCTAssertEqual(
            markupPageCount(in: MarkdownText(source: halfWritten, mayEndMidBlock: true)),
            0,
            "a large document's preview can cut a diagram short"
        )

        let halfWrittenFormula = "Intro.\n\n$$\na^2 +"
        XCTAssertEqual(markupPageCount(in: MarkdownText(source: halfWrittenFormula, isStreaming: true)), 0)
    }

    // MARK: Pages

    func testInlinePagesReportBackAndKeepTheSourceOutOfTheMarkup() {
        let hostile = "flowchart TD\n  A[\"</script><script>alert(1)</script>\"] --> B"
        let page = MarkupHTML.page(
            MarkupDocument(kind: .mermaid, source: hostile, light: true, fontSize: 0),
            presentation: .inline
        )
        XCTAssertTrue(page.contains("window.webkit.messageHandlers.\(MarkupHTML.messageHandlerName)"))
        XCTAssertTrue(page.contains("background:transparent"))
        XCTAssertTrue(page.contains("max-height:\(MarkupHTML.inlineDiagramMaximumHeight)px"))
        XCTAssertFalse(page.contains("<script>alert(1)"), "the source is a JSON string, never markup")
        // A failure shows as text: the renderer's message can quote the source.
        XCTAssertTrue(page.contains("error.textContent"))

        let fullScreen = MarkupHTML.page(
            MarkupDocument(kind: .mermaid, source: hostile, light: false, fontSize: 0),
            presentation: .fullScreen
        )
        XCTAssertFalse(fullScreen.contains("max-height"), "full screen shows a tall diagram at size")
        XCTAssertFalse(fullScreen.contains("background:transparent"))
    }

    func testInlineFormulasFollowTheChatTextSize() {
        let page = MarkupHTML.page(
            MarkupDocument(kind: .math, source: "E = mc^2", light: true, fontSize: 21.4),
            presentation: .inline
        )
        XCTAssertTrue(page.contains("body{font-size:21px}"))
        XCTAssertTrue(page.contains("function fit(){content.style.fontSize=''"), "a wide formula shrinks to fit")

        let fullScreen = MarkupHTML.page(
            MarkupDocument(kind: .math, source: "E = mc^2", light: true, fontSize: 21.4),
            presentation: .fullScreen
        )
        XCTAssertTrue(fullScreen.contains("body{font-size:1.2em}"))
    }

    func testMarkupPagesOnlyNavigateToThemselvesAndTheRendererCDN() {
        XCTAssertTrue(MarkupHTML.allowsNavigation(to: MarkupHTML.baseURL))
        XCTAssertTrue(MarkupHTML.allowsNavigation(to: URL(string: "about:blank")))
        XCTAssertTrue(MarkupHTML.allowsNavigation(to: URL(string: "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: "https://example.com/")))
    }

    // MARK: Mount budget

    func testDiagramsAndFormulasCountAsWebPagesInTheRichBudget() {
        let policy = MarkdownRichContentPolicy.self
        XCTAssertEqual(
            policy.richUnits(.code(language: "mermaid", source: "flowchart TD\n  A --> B")),
            policy.diagramUnits
        )
        XCTAssertEqual(policy.richUnits(.math("E = mc^2")), policy.formulaUnits)
        XCTAssertEqual(policy.richUnits(.code(language: "swift", source: "let x = 1")), 1)
        // A diagram too big to draw still counts its bytes.
        let huge = String(repeating: "A --> B\n", count: 15_000)
        XCTAssertGreaterThan(policy.richUnits(.code(language: "mermaid", source: huge)), policy.diagramUnits)
    }

    // MARK: Helpers

    /// Hosts the message in a phone-sized window and counts the pages its
    /// diagrams and formulas draw in.
    @MainActor
    private func markupPageCount(in view: MarkdownText) -> Int {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let count = Self.webViews(in: host.view).count

        window.isHidden = true
        window.rootViewController = nil
        host.view.removeFromSuperview()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !host.view.subviews.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return count
    }

    @MainActor
    private static func webViews(in view: UIView) -> [WKWebView] {
        if let webView = view as? WKWebView { return [webView] }
        return view.subviews.flatMap { webViews(in: $0) }
    }
}
