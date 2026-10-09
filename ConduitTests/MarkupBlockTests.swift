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

        let diagram = "Intro.\n\n```mermaid\nflowchart TD\n  A --> B\n```"
        XCTAssertEqual(
            markupPageCount(in: MarkdownText(source: diagram).environment(\.markupDrawsInPlace, false)),
            0,
            "where drawing waits, the block shows its source"
        )
    }

    @MainActor
    func testALargeStreamingReplyShowsSourcesUntilItSettles() {
        // Finished chunks of a very large stream pile up as it grows, so
        // none of their diagrams draws until the reply settles.
        var source = ""
        var diagram = 0
        while source.utf8.count < MarkdownLargeDocumentPolicy.documentThresholdBytes + 20_000 {
            for _ in 0..<8 {
                source += String(repeating: "Plain prose about the system. ", count: 14) + "\n\n"
            }
            source += "```mermaid\nflowchart TD\n  A\(diagram) --> B\(diagram)\n```\n\n"
            diagram += 1
        }
        let host = UIHostingController(rootView: StreamingText(text: source, active: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        let textViews = Self.subviews(of: UITextView.self, in: host.view)
        XCTAssertTrue(
            textViews.contains { ($0.text ?? "").contains("flowchart TD") },
            "the stream's diagrams show their source"
        )
        XCTAssertEqual(Self.subviews(of: WKWebView.self, in: host.view).count, 0)

        window.isHidden = true
        window.rootViewController = nil
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
        XCTAssertTrue(page.contains("throwOnError:true"), "a parse error reaches the failure card")

        let fullScreen = MarkupHTML.page(
            MarkupDocument(kind: .math, source: "E = mc^2", light: true, fontSize: 21.4),
            presentation: .fullScreen
        )
        XCTAssertTrue(fullScreen.contains("body{font-size:1.2em}"))
        XCTAssertTrue(fullScreen.contains("throwOnError:false"), "full screen shows KaTeX's own error")
    }

    func testMarkupPagesOnlyNavigateToThemselvesAndTheRendererCDN() {
        XCTAssertTrue(MarkupHTML.allowsNavigation(to: MarkupHTML.baseURL))
        XCTAssertTrue(MarkupHTML.allowsNavigation(to: URL(string: "about:blank")))
        XCTAssertTrue(MarkupHTML.allowsNavigation(to: URL(string: "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js")))
        XCTAssertTrue(MarkupHTML.allowsNavigation(to: URL(string: "https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.css")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: "https://cdn.jsdelivr.net/npm/other@1.0.0/index.js")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: "https://conduit.local/elsewhere")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: "https://example.com/")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: "http://conduit.local/")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: "javascript:alert(1)")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: "data:text/html,<p>")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: URL(string: "file:///etc/hosts")))
        XCTAssertFalse(MarkupHTML.allowsNavigation(to: nil))
    }

    func testAPageThatKeepsLosingItsProcessStopsReloading() {
        var reloads = MarkupReloads()
        for _ in 0..<MarkupReloads.limit {
            XCTAssertTrue(reloads.mayReload())
        }
        XCTAssertFalse(reloads.mayReload(), "the block shows the failure card instead")
        reloads.pageDrew()
        XCTAssertTrue(reloads.mayReload(), "a page that drew may lose its process again later")
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

    func testTenDiagramsShowWithoutAContinueTap() {
        // The first diagrams fit the eager budget and the last ones the live
        // tail, so a reply with up to ten of them hides nothing.
        let policy = MarkdownRichContentPolicy.self
        func reply(diagrams: Int) -> [Int] {
            (0..<diagrams).flatMap { _ in [0, policy.diagramUnits] }
        }
        XCTAssertEqual(policy.hiddenBlockCount(unitsByBlock: reply(diagrams: 6), unitBudget: policy.eagerRichUnitBudget), 0)
        XCTAssertEqual(policy.hiddenBlockCount(unitsByBlock: reply(diagrams: 10), unitBudget: policy.eagerRichUnitBudget), 0)
        XCTAssertGreaterThan(policy.hiddenBlockCount(unitsByBlock: reply(diagrams: 11), unitBudget: policy.eagerRichUnitBudget), 0)
    }

    func testLargeDocumentWindowsBoundTheirDiagramsAndFormulas() {
        let view = LargeMarkdownExpandedView.self
        let diagram = MarkdownRichContentPolicy.diagramUnits

        // Nothing but diagrams: each window mounts a budget's worth.
        let diagrams = Array(repeating: diagram, count: 40)
        XCTAssertEqual(view.initialWindowCount(webPageUnitsByChunk: diagrams), 5)
        XCTAssertEqual(view.nextWindowCount(current: 5, webPageUnitsByChunk: diagrams), 10)

        // A diagram every fourth chunk: the first batch is whole, the next
        // ends before its sixth diagram.
        let mixed = (0..<30).flatMap { _ in [0, 0, 0, diagram] }
        XCTAssertEqual(view.initialWindowCount(webPageUnitsByChunk: mixed), view.initialChunkBatch)
        XCTAssertEqual(view.nextWindowCount(current: 12, webPageUnitsByChunk: mixed), 35)

        // Every window moves on, even past a chunk over the budget alone.
        let heavy = [20, 20, 0]
        XCTAssertEqual(view.initialWindowCount(webPageUnitsByChunk: heavy), 1)
        XCTAssertEqual(view.nextWindowCount(current: 1, webPageUnitsByChunk: heavy), 3)

        // The prepared document counts diagrams and formulas, not text.
        XCTAssertEqual(MarkdownRichContentPolicy.webPageUnits(.math("E = mc^2")), MarkdownRichContentPolicy.formulaUnits)
        XCTAssertEqual(MarkdownRichContentPolicy.webPageUnits(.code(language: "Mermaid", source: "flowchart TD")), diagram)
        XCTAssertEqual(MarkdownRichContentPolicy.webPageUnits(.code(language: "swift", source: "let x = 1")), 0)
        XCTAssertEqual(MarkdownRichContentPolicy.webPageUnits(.paragraph("Text")), 0)
    }

    // MARK: Helpers

    /// Hosts the message in a phone-sized window and counts the pages its
    /// diagrams and formulas draw in.
    @MainActor
    private func markupPageCount(in view: some View) -> Int {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let count = Self.subviews(of: WKWebView.self, in: host.view).count

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
    private static func subviews<Match: UIView>(of type: Match.Type, in view: UIView) -> [Match] {
        if let match = view as? Match { return [match] }
        return view.subviews.flatMap { subviews(of: type, in: $0) }
    }
}
