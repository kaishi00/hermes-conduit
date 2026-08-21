//
//  MarkdownRichContentTests.swift
//  Conduit
//
//  Regression coverage for the watchdog crash reproduced by opening a
//  session whose single Markdown-heavy response is comfortably below the
//  100 KB large-document threshold yet structurally pathological: many
//  tables (aligned), Mermaid diagrams, images, math, code fences, and the
//  usual headings/lists/quotes.
//
//  The fixture proves the ordinary-size path is protected by STRUCTURE:
//  complex tables page, per-block Mermaid/math/code guards apply, and the
//  aggregate rich-layout budget bounds eager mounts — without lowering
//  documentThresholdBytes and without touching ordinary messages.
//

import SwiftUI
import UIKit
import XCTest
@testable import Conduit

// MARK: - Fixtures

/// Deterministic Markdown showcase generators. The pathological showcase
/// mirrors the TestFlight reproduction: ONE assistant response that
/// demonstrates lots of Markdown features, byte count well under the
/// large-document threshold.
enum MarkdownShowcaseFixtures {
    /// A GFM table with every alignment form, `rows` rows × `columns`
    /// columns. Cell text is ASCII so the byte math stays predictable.
    static func alignedTable(section: Int, rows: Int, columns: Int) -> String {
        let header = (0..<columns).map { "H\($0)" }.joined(separator: " | ")
        let alignment = (0..<columns).map { c in
            [":---", ":---:", "---:"][c % 3]
        }.joined(separator: " | ")
        var lines = [
            "| \(header) |",
            "| \(alignment) |",
        ]
        for r in 0..<rows {
            let cells = (0..<columns)
                .map { "s\(section)-r\(r)c\($0)" }
                .joined(separator: " | ")
            lines.append("| \(cells) |")
        }
        return lines.joined(separator: "\n")
    }

    /// One showcase section: heading, prose, a table (structurally varying
    /// by section), Mermaid diagram, math, code fence, quote, lists, task
    /// items, a callout, and a divider. Images every third section.
    static func section(index: Int, includeImages: Bool = true) -> String {
        var parts: [String] = []
        parts.append("## Feature tour \(index)")
        parts.append(
            "Paragraph \(index) with **bold**, *italic*, `inline code`, and a [docs link](https://example.com/docs/\(index)) so inline parsing stays exercised."
        )
        if index % 4 == 3 {
            // Complex by row count (46 ≥ complexTableRowCount).
            parts.append(alignedTable(section: index, rows: 46, columns: 6))
        } else if index % 6 == 5 {
            // Complex by total cells (22 × 10 = 220 ≥ complexTableCellCount)
            // with a moderate row count.
            parts.append(alignedTable(section: index, rows: 22, columns: 10))
        } else {
            // Moderate table: complex by neither measure on its own.
            parts.append(alignedTable(section: index, rows: 22, columns: 5))
        }
        parts.append(
            """
            ```mermaid
            flowchart TD
                S\(index)[Start \(index)] --> G{Gate \(index)}
                G -->|fast| C[Commit]
                G -->|slow| R[Retry]
                C --> F((Finish \(index)))
            ```
            """
        )
        parts.append(
            """
            $$
            \\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2} \\quad (\\text{case } \(index))
            $$
            """
        )
        parts.append(
            """
            ```swift
            struct Section\(index) {
                let value = \(index)
                func render() -> String { "section \\(value)" }
            }
            ```
            """
        )
        if includeImages, index % 3 == 0 {
            parts.append("![Chart \(index)](https://example.com/charts/chart-\(index).png)")
        }
        parts.append(
            "> Quoted insight \(index) about the showcase.\n> Second quoted line with *emphasis*."
        )
        parts.append(
            "- bullet one for \(index)\n- bullet two with detail\n- [ ] task item \(index)\n- [x] completed task"
        )
        parts.append("::: tip\nCallout \(index): tables and diagrams stay interactive.\n:::")
        parts.append("---")
        return parts.joined(separator: "\n\n")
    }

    /// The reproduction: one response, many rich blocks, well below the
    /// 100 KB large-document threshold.
    static func pathologicalShowcase(
        sections: Int = 18,
        includeImages: Bool = true
    ) -> String {
        (0..<sections).map { section(index: $0, includeImages: includeImages) }
            .joined(separator: "\n\n")
    }

    /// An ordinary feature-tour answer: one of everything, the kind of
    /// message rich Markdown must keep rendering exactly as before.
    static func ordinaryShowcase() -> String {
        [
            "## Ordinary answer",
            "A paragraph with **bold** and a [link](https://example.com/a).",
            alignedTable(section: 0, rows: 4, columns: 3),
            """
            ```mermaid
            flowchart LR
                A --> B --> C
            ```
            """,
            "$$\na^2 + b^2 = c^2\n$$",
            """
            ```swift
            let answer = 42
            ```
            """,
            "![Diagram](https://example.com/diagram.png)",
            "> One quoted line.",
            "- a bullet\n- another bullet",
            "::: note\nA callout.\n:::",
        ].joined(separator: "\n\n")
    }
}

// MARK: - Pure policy tests

final class MarkdownRichContentPolicyTests: XCTestCase {
    private func headers(_ count: Int) -> [String] {
        (0..<count).map { "H\($0)" }
    }

    private func rows(_ count: Int, _ columns: Int) -> [[String]] {
        (0..<count).map { r in (0..<columns).map { "r\(r)c\($0)" } }
    }

    // MARK: Table complexity is structural

    func testTableComplexityUsesRowsCellsAndBytes() {
        let policy = MarkdownRichContentPolicy.self

        // Row count alone.
        XCTAssertTrue(policy.isComplexTable(headers: headers(6), rows: rows(46, 6)))
        // Cell count with a moderate row count (22 × 10 = 220).
        XCTAssertTrue(policy.isComplexTable(headers: headers(10), rows: rows(22, 10)))
        XCTAssertTrue(policy.isComplexTable(headers: headers(10), rows: rows(20, 10)))
        XCTAssertFalse(policy.isComplexTable(headers: headers(10), rows: rows(19, 10)))
        // Ordinary tables stay ordinary.
        XCTAssertFalse(policy.isComplexTable(headers: headers(4), rows: rows(8, 4)))
        XCTAssertFalse(policy.isComplexTable(headers: headers(6), rows: rows(30, 6)))
        // Byte-based qualification from #88 is preserved: few cells, huge
        // content still pages.
        let hugeCell = String(repeating: "x", count: 2_700)
        let hugeRows = (0..<6).map { _ in (0..<2).map { _ in hugeCell } }
        XCTAssertTrue(
            policy.isComplexTable(headers: ["A", "B"], rows: hugeRows),
            "a byte-heavy table keeps its #88 paged qualification"
        )
    }

    // MARK: Block-local guards are independent of document bytes

    func testMermaidMathCodeGuardsApplyToTheBlockItself() {
        // All of these live in messages far below the 100 KB document
        // threshold; the guards must still apply.
        let mermaidPastGuard = String(repeating: "A --> B\n", count: 15_000)
        XCTAssertGreaterThan(
            mermaidPastGuard.utf8.count,
            MarkdownLargeDocumentPolicy.mermaidGuardBytes
        )
        XCTAssertEqual(
            MarkdownBlockView.codePresentation(language: "mermaid", source: mermaidPastGuard),
            .guardedMermaid
        )
        // Ordinary diagrams keep their normal render path.
        XCTAssertEqual(
            MarkdownBlockView.codePresentation(
                language: "mermaid",
                source: "flowchart TD\n  A --> B"
            ),
            .mermaid
        )

        let codePastThreshold = String(repeating: "let value = 1;\n", count: 4_000)
        XCTAssertGreaterThan(
            codePastThreshold.utf8.count,
            MarkdownLargeDocumentPolicy.codeBlockThresholdBytes
        )
        XCTAssertEqual(
            MarkdownBlockView.codePresentation(language: "swift", source: codePastThreshold),
            .slicedCode
        )
        XCTAssertEqual(
            MarkdownBlockView.codePresentation(language: "swift", source: "let value = 1;"),
            .code
        )

        XCTAssertTrue(
            MarkdownBlockView.mathNeedsGuard(String(repeating: "x", count: 100_001))
        )
        XCTAssertFalse(MarkdownBlockView.mathNeedsGuard("E = mc^2"))
    }

    // MARK: Aggregate budget

    func testOrdinaryMessagesStayUnderTheRichBudget() {
        // Case 1: plain prose never even reaches the block-view path.
        let prose = "Just prose.\n\nMore prose here."
        let proseDocument = MarkdownParser.parseDocument(prose)
        XCTAssertTrue(
            proseDocument.blocks.allSatisfy(\.isSelectableFlowBlock),
            "plain prose renders through the single selectable text view"
        )

        // Case 2: one ordinary table.
        let oneTable = "Intro.\n\n" + MarkdownShowcaseFixtures.alignedTable(section: 0, rows: 6, columns: 3)
        XCTAssertFalse(
            MarkdownRichContentPolicy.needsBounding(MarkdownParser.parse(oneTable))
        )

        // Case 3: one ordinary Mermaid diagram.
        let oneMermaid = "Intro.\n\n```mermaid\nflowchart TD\n  A --> B\n```"
        XCTAssertFalse(
            MarkdownRichContentPolicy.needsBounding(MarkdownParser.parse(oneMermaid))
        )

        // A full ordinary feature-tour answer (one of everything).
        let ordinary = MarkdownShowcaseFixtures.ordinaryShowcase()
        XCTAssertFalse(MarkdownLargeDocumentPolicy.isLargeDocument(ordinary))
        let ordinaryBlocks = MarkdownParser.parse(ordinary)
        XCTAssertFalse(MarkdownRichContentPolicy.needsBounding(ordinaryBlocks))
        XCTAssertNil(
            MarkdownRichContentPolicy.gateCut(
                blocks: ordinaryBlocks,
                unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
            ),
            "an ordinary rich message mounts everything eagerly"
        )
    }

    func testPathologicalShowcaseIsBelowThresholdButOverBudget() {
        let source = MarkdownShowcaseFixtures.pathologicalShowcase()

        // THE reproduction shape: rich beyond reason, byte count ordinary.
        XCTAssertLessThan(source.utf8.count, MarkdownLargeDocumentPolicy.documentThresholdBytes)
        XCTAssertGreaterThan(source.utf8.count, 35_000)
        XCTAssertFalse(MarkdownLargeDocumentPolicy.isLargeDocument(source))

        let blocks = MarkdownParser.parse(source)

        // Rich-block inventory: many tables, many Mermaid diagrams, math,
        // code, images.
        let tables = blocks.filter {
            if case .table = $0 { return true }
            return false
        }
        let mermaidBlocks = blocks.filter {
            if case .code(let language, _) = $0 {
                return MarkdownLanguage.normalized(language) == "mermaid"
            }
            return false
        }
        XCTAssertEqual(tables.count, 18, "one table per showcase section")
        XCTAssertGreaterThanOrEqual(mermaidBlocks.count, 18)
        XCTAssertTrue(blocks.contains { block in
            if case .math = block { return true }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .image = block { return true }
            return false
        })

        // Structural complexity is detected on the tables that have it.
        let complexTableCount = tables.filter { block in
            if case .table(let headers, _, let rows) = block {
                return MarkdownRichContentPolicy.isComplexTable(headers: headers, rows: rows)
            }
            return false
        }.count
        XCTAssertGreaterThanOrEqual(complexTableCount, 5)

        // The aggregate rich budget engages for the whole response.
        XCTAssertTrue(MarkdownRichContentPolicy.needsBounding(blocks))
        let cut = MarkdownRichContentPolicy.gateCut(
            blocks: blocks,
            unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
        )
        XCTAssertNotNil(cut)
        XCTAssertLessThan(cut!, blocks.count)
        // The eager mount is a small fraction of the response.
        XCTAssertLessThan(cut!, blocks.count / 2)

        // Reveal batches eventually mount the whole response.
        XCTAssertNil(
            MarkdownRichContentPolicy.gateCut(
                blocks: blocks,
                unitBudget: MarkdownRichContentPolicy.totalRichUnits(blocks)
            )
        )
    }

    func testRevealBatchesProgressivelyCoverTheShowcase() {
        let source = MarkdownShowcaseFixtures.pathologicalShowcase()
        let blocks = MarkdownParser.parse(source)

        var lastCut = 0
        var budget = MarkdownRichContentPolicy.eagerRichUnitBudget
        var cuts: [Int] = []
        while let cut = MarkdownRichContentPolicy.gateCut(blocks: blocks, unitBudget: budget) {
            cuts.append(cut)
            lastCut = cut
            budget += MarkdownRichContentPolicy.revealUnitBatch
            if cuts.count > 100 { XCTFail("reveal never completes"); break }
        }
        // Monotonically increasing mounts, ending with everything fitting.
        XCTAssertEqual(cuts.sorted(), cuts)
        XCTAssertGreaterThan(lastCut, 0)
        XCTAssertNil(
            MarkdownRichContentPolicy.gateCut(blocks: blocks, unitBudget: budget),
            "the final reveal state mounts every block"
        )
    }
}

// MARK: - Hosted rendering tests

@MainActor
final class MarkdownRichContentHostedTests: XCTestCase {
    /// Retained for the full lifetime of each measurement so the hosted
    /// hierarchy stays genuinely mounted; torn down explicitly per test.
    private var testWindow: UIWindow?

    override func setUp() {
        super.setUp()
        RichBudgetedMarkdownBody.resetDebugInstrumentation()
    }

    override func tearDown() {
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        RunLoop.current.run(until: Date())
        testWindow = nil
        RichBudgetedMarkdownBody.resetDebugInstrumentation()
        super.tearDown()
    }

    /// Hosts one MarkdownText in a phone-sized window and lets the first
    /// layout pass (the one the watchdog used to die in) complete.
    private func mountMarkdown(
        _ makeView: () -> MarkdownText
    ) -> UIHostingController<MarkdownText> {
        let host = UIHostingController(rootView: makeView())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        testWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    /// Performance case 4: the <100 KB pathological showcase opens through
    /// the bounded path — the eagerly mounted block set is the gate's
    /// bounded prefix, not the whole response.
    func testPathologicalShowcaseMountsBoundedBlockSet() throws {
        // Images excluded here: their web-backed fallbacks (WKWebView) add
        // process-level cost unsuitable for a unit-test window; the pure
        // budget tests cover image accounting.
        let source = MarkdownShowcaseFixtures.pathologicalShowcase(includeImages: false)
        let blocks = MarkdownParser.parse(source)
        XCTAssertFalse(MarkdownLargeDocumentPolicy.isLargeDocument(source))
        XCTAssertTrue(MarkdownRichContentPolicy.needsBounding(blocks))

        _ = mountMarkdown { MarkdownText(source: source) }

        let mounted = RichBudgetedMarkdownBody.debugMountedBlockCount
        XCTAssertEqual(
            mounted,
            MarkdownRichContentPolicy.gateCut(
                blocks: blocks,
                unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
            )!,
            "the hosted render mounts exactly the gate's bounded prefix"
        )
        XCTAssertLessThan(mounted, blocks.count)
        XCTAssertLessThan(mounted, blocks.count / 2)
    }

    /// Ordinary rich messages keep mounting everything (performance cases
    /// 1–3): the budgeted body never even engages.
    func testOrdinaryShowcaseMountsEverything() throws {
        let ordinary = MarkdownShowcaseFixtures.ordinaryShowcase()
        let blocks = MarkdownParser.parse(ordinary)
        XCTAssertFalse(MarkdownRichContentPolicy.needsBounding(blocks))

        _ = mountMarkdown { MarkdownText(source: ordinary) }

        XCTAssertEqual(
            RichBudgetedMarkdownBody.debugMountedBlockCount,
            0,
            "the budgeted body must not engage for ordinary rich messages"
        )
        XCTAssertGreaterThan(blocks.count, 5)
    }

    /// While streaming, the gate is bypassed so the live tail can never sit
    /// behind a reveal button; growth stays incremental per frame
    /// (performance case 6 companion).
    func testStreamingShowcaseBypassesTheGate() throws {
        let source = MarkdownShowcaseFixtures.pathologicalShowcase(sections: 6, includeImages: false)
        let blocks = MarkdownParser.parse(source)
        XCTAssertTrue(MarkdownRichContentPolicy.needsBounding(blocks))

        _ = mountMarkdown { MarkdownText(source: source, isStreaming: true) }

        XCTAssertEqual(
            RichBudgetedMarkdownBody.debugMountedBlockCount,
            blocks.count,
            "streaming renders through the ungated body"
        )
    }
}
