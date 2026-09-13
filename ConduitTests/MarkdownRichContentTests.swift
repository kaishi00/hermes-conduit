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
    static func alignedTable(
        section: Int,
        rows: Int,
        columns: Int,
        cellPadding: Int = 0
    ) -> String {
        let header = (0..<columns).map { "H\($0)" }.joined(separator: " | ")
        let alignment = (0..<columns).map { c in
            [":---", ":---:", "---:"][c % 3]
        }.joined(separator: " | ")
        let filler = cellPadding > 0 ? String(repeating: "x", count: cellPadding) : ""
        var lines = [
            "| \(header) |",
            "| \(alignment) |",
        ]
        for r in 0..<rows {
            let cells = (0..<columns)
                .map { "s\(section)-r\(r)c\($0)\(filler)" }
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
        let units = MarkdownRichContentPolicy.richUnitsByBlock(blocks)
        let cut = MarkdownRichContentPolicy.gateCut(
            unitsByBlock: units,
            unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
        )
        XCTAssertNotNil(cut)
        XCTAssertLessThan(cut!, blocks.count)
        // The eager mount is a small fraction of the response.
        XCTAssertLessThan(cut!, blocks.count / 2)

        // Reveal batches eventually mount the whole response.
        XCTAssertNil(
            MarkdownRichContentPolicy.gateCut(
                unitsByBlock: units,
                unitBudget: MarkdownRichContentPolicy.totalRichUnits(units)
            )
        )
    }

    func testRevealBatchesProgressivelyCoverTheShowcase() {
        let source = MarkdownShowcaseFixtures.pathologicalShowcase()
        let blocks = MarkdownParser.parse(source)
        let units = MarkdownRichContentPolicy.richUnitsByBlock(blocks)

        var lastCut = 0
        var budget = MarkdownRichContentPolicy.eagerRichUnitBudget
        var cuts: [Int] = []
        while let cut = MarkdownRichContentPolicy.gateCut(unitsByBlock: units, unitBudget: budget) {
            cuts.append(cut)
            lastCut = cut
            budget = MarkdownRichContentPolicy.revealBudget(
                unitsByBlock: units,
                currentBudget: budget
            )
            if cuts.count > 100 { XCTFail("reveal never completes"); break }
        }
        // Monotonically increasing mounts, ending with everything fitting.
        XCTAssertEqual(cuts.sorted(), cuts)
        XCTAssertGreaterThan(lastCut, 0)
        XCTAssertNil(
            MarkdownRichContentPolicy.gateCut(unitsByBlock: units, unitBudget: budget),
            "the final reveal state mounts every block"
        )
    }

    /// Item: reveal forward progress. A single gated block can cost more
    /// than one reveal batch; one tap must still mount at least that block,
    /// so the UI can never appear stuck.
    func testRevealTapAdvancesPastBlockCostingMoreThanOneBatch() {
        // Prefix that fills the eager budget, then ONE hugely expensive
        // table (46 rows × 8 columns ≈ 6 units? no — make it expensive via
        // a giant single-table unit cost: many complex tables in sequence
        // is unrealistic; instead use code bytes, which scale without bound).
        var blocks: [MarkdownBlock] = []
        // ~16 units of ordinary tables (5×5 cells ≈ 25/64 → 1 unit each).
        for index in 0..<16 {
            blocks.append(.table(
                headers: ["A", "B", "C", "D", "E"],
                alignments: [.leading, .center, .trailing, .leading, .center],
                rows: (0..<4).map { row in (0..<5).map { "r\(row)c\($0)-i\(index)" } }
            ))
        }
        // One block worth many batches: 80_000 × 16 B ≈ 1.28 MB of code
        // ≈ 160 units — far beyond one 16-unit reveal batch.
        let giantCode = String(
            repeating: "let value = 1;\n",
            count: 80_000
        )
        blocks.append(.code(language: "swift", source: giantCode))
        // More gated content after it, so the gate persists past the jump.
        for index in 0..<3 {
            blocks.append(.table(
                headers: ["A", "B", "C", "D", "E"],
                alignments: [.leading, .center, .trailing, .leading, .center],
                rows: (0..<4).map { row in (0..<5).map { "after\(index)-r\(row)c\($0)" } }
            ))
        }
        blocks.append(.divider)

        let units = MarkdownRichContentPolicy.richUnitsByBlock(blocks)
        XCTAssertGreaterThan(
            units[16],
            MarkdownRichContentPolicy.revealUnitBatch,
            "the gated block must cost more than one reveal batch"
        )

        let firstCut = MarkdownRichContentPolicy.gateCut(
            unitsByBlock: units,
            unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
        )
        XCTAssertEqual(firstCut, 16, "the gate sits exactly at the expensive block")

        // One tap: the budget must advance far enough to INCLUDE it.
        let nextBudget = MarkdownRichContentPolicy.revealBudget(
            unitsByBlock: units,
            currentBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
        )
        let nextCut = MarkdownRichContentPolicy.gateCut(
            unitsByBlock: units,
            unitBudget: nextBudget
        )
        XCTAssertGreaterThan(
            nextCut ?? 0,
            firstCut ?? 0,
            "one reveal tap must mount at least the expensive block"
        )
        // Bounded: the jump covers exactly that block, not the document.
        XCTAssertEqual(nextCut, firstCut! + 1)
    }

    /// Item: the live tail is always mounted regardless of the reveal
    /// budget — that is what keeps streaming content visible and makes the
    /// streaming → settled transition non-collapsing.
    func testLiveTailAlwaysMountedRegardlessOfBudget() {
        let source = MarkdownShowcaseFixtures.pathologicalShowcase()
        let blocks = MarkdownParser.parse(source)
        let units = MarkdownRichContentPolicy.richUnitsByBlock(blocks)

        let tail = MarkdownRichContentPolicy.liveTailStart(unitsByBlock: units)
        XCTAssertGreaterThan(tail, 0, "pathological showcase has a real tail window")
        // With a zero tail budget the tail is smallest but STILL covers the
        // final block: the newest content is always mounted, whatever it
        // costs. (Flow blocks cost nothing, so the zero-budget tail keeps
        // every trailing zero-unit block and stops at the first rich one.)
        let zeroTail = MarkdownRichContentPolicy.liveTailStart(unitsByBlock: units, unitBudget: 0)
        XCTAssertLessThan(zeroTail, blocks.count, "the zero-budget tail still excludes earlier rich blocks")
        XCTAssertLessThanOrEqual(tail, zeroTail, "a bigger tail budget only ever mounts more blocks")
        // The hidden gap is what the reveal button accounts for: exactly
        // the blocks between the mounted prefix and the tail.
        let hidden = MarkdownRichContentPolicy.hiddenBlockCount(
            unitsByBlock: units,
            unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
        )
        let cut = MarkdownRichContentPolicy.gateCut(
            unitsByBlock: units,
            unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
        ) ?? 0
        XCTAssertEqual(
            hidden,
            tail - cut,
            "hidden blocks are exactly the gap between prefix and tail"
        )
        XCTAssertGreaterThan(hidden, 0)
    }
    /// Review item: mounted-plan union semantics. The live tail must
    /// stay mounted in EVERY gate state; the ranges must never overlap;
    /// the footer must exist IFF a strictly positive hidden gap exists.
    /// Uses the SAME shared plan the production body renders from, so a
    /// regression here is a regression in the view.
    func testMountedPlanKeepsTailInEveryGateState() throws {
        // Uniform 1-unit blocks make every threshold exact:
        // gateCut = 16 (first index where cumulative > 16),
        // liveTailStart = count - 16 (clamped so the final block always
        // stays mounted).
        func units(_ count: Int) -> [Int] { Array(repeating: 1, count: count) }

        // Case A: cut < tail (60 blocks: cut 16, tail 44) — real gap.
        XCTAssertEqual(
            MarkdownRichContentPolicy.mountedPlan(
                unitsByBlock: units(60),
                unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
            ),
            .split(prefixEnd: 16, tailStart: 44),
            "60 uniform blocks must produce the split plan 0..<16 + 44..<60"
        )
        let splitPlan = MarkdownRichContentPolicy.RichMountedPlan.split(prefixEnd: 16, tailStart: 44)
        XCTAssertEqual(
            MarkdownRichContentPolicy.mountedIndices(plan: splitPlan, totalBlocks: 60),
            Array(0..<16) + Array(44..<60)
        )

        // Case B: cut == tail (32 blocks: cut 16, tail 16) — empty gap
        // collapses to ONE contiguous range covering the tail.
        XCTAssertEqual(
            MarkdownRichContentPolicy.mountedPlan(
                unitsByBlock: units(32),
                unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
            ),
            .contiguous(end: 32),
            "cut == tail must mount everything once, keeping the tail"
        )

        // Case C: cut > tail (30 blocks: cut 16, tail 14) — the prefix
        // has overlapped the tail; still one contiguous range.
        XCTAssertEqual(
            MarkdownRichContentPolicy.mountedPlan(
                unitsByBlock: units(30),
                unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
            ),
            .contiguous(end: 30),
            "cut > tail must mount everything once, never unmounting the tail"
        )

        // Case D: cut == nil (15 blocks fit the eager budget) — ungated.
        XCTAssertEqual(
            MarkdownRichContentPolicy.mountedPlan(
                unitsByBlock: units(15),
                unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
            ),
            .contiguous(end: 15),
            "an ungated message mounts everything once with no footer"
        )
    }

    /// The footer exists IFF a strictly positive hidden gap exists, and
    /// reveal progression is monotonic: every larger budget mounts a
    /// superset, the newest block is always included, and no index ever
    /// appears twice.
    func testMountedPlanRevealMonotonicityAndNoDuplicates() {
        let count = 60
        let unitVector = Array(repeating: 1, count: count)
        var previous: Set<Int> = []
        var sawFooter = false
        var sawFooterless = false
        var budget = MarkdownRichContentPolicy.eagerRichUnitBudget
        for _ in 0..<20 {
            let plan = MarkdownRichContentPolicy.mountedPlan(
                unitsByBlock: unitVector,
                unitBudget: budget
            )
            let indices = MarkdownRichContentPolicy.mountedIndices(
                plan: plan,
                totalBlocks: count
            )
            let mounted = Set(indices)
            XCTAssertEqual(mounted.count, indices.count, "no duplicate mounts")
            XCTAssertTrue(mounted.isSuperset(of: previous), "reveal only adds blocks")
            XCTAssertTrue(mounted.contains(count - 1), "the newest block stays mounted")
            switch plan {
            case .split(let prefixEnd, let tailStart):
                XCTAssertGreaterThan(tailStart - prefixEnd, 0, "split implies a real gap")
                sawFooter = true
            case .contiguous:
                sawFooterless = true
            }
            previous = mounted
            if case .contiguous(let end) = plan, end == count { break }
            budget = MarkdownRichContentPolicy.revealBudget(
                unitsByBlock: unitVector,
                currentBudget: budget
            )
        }
        XCTAssertTrue(sawFooter, "the progression must pass through a gated state")
        XCTAssertTrue(sawFooterless, "the progression must reach a fully revealed state")
    }

    /// Review item: budgetToInclude bounds. index == count must be
    /// rejected (the inclusive walk would read past the end); the valid
    /// final index still computes exactly.
    func testBudgetToIncludeBoundsContract() {
        let unitVector = Array(repeating: 4, count: 10)

        // Invalid: one past the end.
        XCTAssertEqual(
            MarkdownRichContentPolicy.budgetToInclude(unitsByBlock: unitVector, index: 10),
            MarkdownRichContentPolicy.eagerRichUnitBudget,
            "index == count is out of contract and falls back"
        )
        // Invalid: zero and negative.
        XCTAssertEqual(
            MarkdownRichContentPolicy.budgetToInclude(unitsByBlock: unitVector, index: 0),
            MarkdownRichContentPolicy.eagerRichUnitBudget
        )
        // Valid final index: cumulative 10 × 4 = 40.
        XCTAssertEqual(
            MarkdownRichContentPolicy.budgetToInclude(unitsByBlock: unitVector, index: 9),
            40,
            "the valid last index still computes the inclusive sum"
        )
        // Valid interior index.
        XCTAssertEqual(
            MarkdownRichContentPolicy.budgetToInclude(unitsByBlock: unitVector, index: 3),
            16
        )
    }
}

// MARK: - Hosted rendering tests

@MainActor
final class MarkdownRichContentHostedTests: XCTestCase {
    /// Retained for the full lifetime of each measurement so the hosted
    /// hierarchy stays genuinely mounted; torn down explicitly per test.
    private var testWindow: UIWindow?
    private var testHost: UIHostingController<MarkdownText>?

    override func setUp() {
        super.setUp()
        RichBudgetedMarkdownBody.resetDebugInstrumentation()
    }

    override func tearDown() {
        dismountCurrentWindow()
        RichBudgetedMarkdownBody.resetDebugInstrumentation()
        super.tearDown()
    }

    /// Deterministically tears down the current hosted window INSIDE this
    /// test. Hiding a window and dropping the reference leaves the
    /// UIHostingController's appearance transition PENDING: the deferred
    /// work lands in whichever suite runs next, where each leftover
    /// transition logs an unbalanced-appearance warning and — on a slow
    /// CI runner processing a whole batch of them — saturates the main
    /// thread long enough to starve XCTest main-queue waits (CI #384/#385:
    /// MarkdownTableLayoutTests' 2 s "width probe settles" expectation
    /// timed out under a stack of these). The teardown therefore:
    ///   1. removes the hosted view from the window SYNCHRONOUSLY
    ///      (forcing the appearance transition to begin now, not later),
    ///   2. detaches the root view controller, and
    ///   3. drains the run loop until the hosting view's SwiftUI
    ///      subview hierarchy is actually dismantled (bounded).
    /// Draining to an observed completion signal is deterministic
    /// synchronization, not a padded delay.
    private func dismountCurrentWindow() {
        guard let window = testWindow else { return }
        let host = testHost
        window.isHidden = true
        window.rootViewController = nil
        host?.view.removeFromSuperview()

        // Completion signal: the hosting view's SwiftUI subviews are
        // gone. NOTE: controller DEALLOCATION was tried as the signal
        // and is empirically unsound here — SwiftUI retains the hosting
        // controller internally well past any reasonable budget, so a
        // deallocation wait always expires (and an assert on it always
        // fails) even though the deferred teardown work has long since
        // completed. Subview dismantling is the observable that tracks
        // the actual teardown work and completes promptly (verified
        // locally and on CI).
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let host, host.view.subviews.isEmpty { break }
        }
        testWindow = nil
        testHost = nil
    }

    /// Hosts one MarkdownText in a phone-sized window and lets the first
    /// layout pass (the one the watchdog used to die in) complete. Any
    /// previously mounted window is dismounted first so sequential mounts
    /// never drop a live window mid-transition.
    private func mountMarkdown(
        _ makeView: () -> MarkdownText
    ) -> UIHostingController<MarkdownText> {
        dismountCurrentWindow()
        let host = UIHostingController(rootView: makeView())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        testWindow = window
        testHost = host
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    /// Advances the reveal through the production action: the DEBUG-only
    /// notification inlet on RichBudgetedMarkdownBody invokes the EXACT
    /// advanceReveal() method the footer button executes (SwiftUI
    /// Buttons expose neither a UIControl bridge nor a reachable
    /// accessibility-activation surface to unit tests, so the inlet is
    /// the faithful deterministic path).
    private func advanceRevealThroughProductionPath() {
        NotificationCenter.default.post(
            name: RichBudgetedMarkdownBody.advanceRevealForTesting,
            object: nil
        )
        // Let the SwiftUI state update commit and re-render, then force
        // the layout pass so the recorded instrumentation reflects it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let root = testWindow?.rootViewController?.view {
            root.setNeedsLayout()
            root.layoutIfNeeded()
        }
        RunLoop.current.run(until: Date())
    }

    /// Performance case 4: the <100 KB pathological showcase opens through
    /// the bounded path — the eagerly mounted block set is exactly the
    /// bounded prefix plus the always-visible live tail, never the whole
    /// response.
    func testPathologicalShowcaseMountsBoundedBlockSet() throws {
        // Images excluded here: their web-backed fallbacks (WKWebView) add
        // process-level cost unsuitable for a unit-test window; the pure
        // budget tests cover image accounting.
        let source = MarkdownShowcaseFixtures.pathologicalShowcase(includeImages: false)
        let blocks = MarkdownParser.parse(source)
        let units = MarkdownRichContentPolicy.richUnitsByBlock(blocks)
        XCTAssertFalse(MarkdownLargeDocumentPolicy.isLargeDocument(source))
        XCTAssertTrue(MarkdownRichContentPolicy.needsBounding(unitsByBlock: units))

        _ = mountMarkdown { MarkdownText(source: source) }

        let cut = try XCTUnwrap(
            MarkdownRichContentPolicy.gateCut(
                unitsByBlock: units,
                unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
            )
        )
        let tail = MarkdownRichContentPolicy.liveTailStart(unitsByBlock: units)
        let expectedMounted = cut + (blocks.count - tail)
        let mounted = RichBudgetedMarkdownBody.debugMountedBlockCount
        XCTAssertEqual(
            mounted,
            expectedMounted,
            "the hosted render mounts exactly the bounded prefix plus the live tail"
        )
        // Bounded: well under the whole pathological response, even though
        // the newest content stays visible.
        XCTAssertLessThan(mounted, blocks.count)
        XCTAssertLessThan(mounted, blocks.count * 3 / 5)
        // The live tail really is the tail: the final block is mounted.
        XCTAssertTrue(
            RichBudgetedMarkdownBody.debugMountedBlockIndices.contains(blocks.count - 1),
            "the newest block (streaming read position) must stay mounted"
        )
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

    /// The streaming → settled transition never unmounts visible content:
    /// the mounted set is derived from block structure and reveal budget
    /// alone, so a response that was streaming mounts EXACTLY what the
    /// settled render mounts — no collapse to the initial budget.
    func testStreamingToSettledKeepsTheMountedSet() throws {
        let source = MarkdownShowcaseFixtures.pathologicalShowcase(sections: 6, includeImages: false)
        let blocks = MarkdownParser.parse(source)
        let units = MarkdownRichContentPolicy.richUnitsByBlock(blocks)
        XCTAssertTrue(MarkdownRichContentPolicy.needsBounding(unitsByBlock: units))

        _ = mountMarkdown { MarkdownText(source: source, isStreaming: true) }
        let streamingIndices = RichBudgetedMarkdownBody.debugMountedBlockIndices
        XCTAssertFalse(streamingIndices.isEmpty)

        _ = mountMarkdown { MarkdownText(source: source) }
        let settledIndices = RichBudgetedMarkdownBody.debugMountedBlockIndices

        XCTAssertEqual(
            settledIndices,
            streamingIndices,
            "settling must not unmount any block the streaming render showed"
        )
        // And both are bounded: not the whole pathological response.
        XCTAssertLessThan(streamingIndices.count, blocks.count)
    }

    /// Crossing the structural complexity threshold must not change whether
    /// a fitting table fits: the paged LargeMarkdownTable resolves columns
    /// from the same real container width as the ordinary MarkdownTable, so
    /// a table that fits 390 pt keeps fitting (no horizontal scroll), while
    /// a genuinely wide table still overflows and scrolls.
    func testPagedTablePreservesViewportFitBehavior() throws {
        // Complex by row count (46 rows), content whose ideal column widths
        // exceed the container but SHRINK to fit when the real width is
        // known. With the pre-fix unknown/zero width these columns capped
        // instead of shrinking and the table became horizontally scrollable.
        let fitting = MarkdownShowcaseFixtures.alignedTable(
            section: 0, rows: 46, columns: 3, cellPadding: 24
        )
        _ = mountMarkdown { MarkdownText(source: fitting) }
        let fittingWidth = try XCTUnwrap(widestLaidOutSubviewWidth())
        XCTAssertLessThanOrEqual(
            fittingWidth,
            392,
            "a table that fits the 390 pt container must keep fitting when paged"
        )

        // Genuinely wide table (8 columns of the same cells): must still
        // overflow into horizontal scrolling.
        let wide = MarkdownShowcaseFixtures.alignedTable(
            section: 1, rows: 46, columns: 8, cellPadding: 24
        )
        _ = mountMarkdown { MarkdownText(source: wide) }
        let wideWidth = try XCTUnwrap(widestLaidOutSubviewWidth())
        XCTAssertGreaterThan(
            wideWidth,
            395,
            "a genuinely wide table must still horizontally scroll"
        )
    }

    /// Widest UIView frame in the currently hosted hierarchy — the honest
    /// signal for "did table content overflow the container", since a
    /// horizontal ScrollView's own frame always matches the proposal while
    /// its content views lay out at natural width.
    private func widestLaidOutSubviewWidth() -> CGFloat? {
        guard let root = testWindow?.rootViewController?.view else { return nil }
        var widest: CGFloat?
        func walk(_ view: UIView) {
            if view.frame.width > (widest ?? 0) {
                widest = view.frame.width
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(root)
        return widest
    }
    /// Hosted live-tail regression: when the reveal cut starts PAST the
    /// tail boundary (30 moderate tables: cut 16 > tail 14), the union
    /// must still mount EVERY block exactly once — the pre-fix body
    /// dropped the tail entirely in this state (mounted 0..<16 only,
    /// losing the newest blocks) and showed no path to them.
    func testHostedCutBeyondTailKeepsNewestBlocksMounted() throws {
        let source = (0..<30).map { index in
            "Section \(index) intro paragraph.\n\n"
                + MarkdownShowcaseFixtures.alignedTable(section: index, rows: 4, columns: 5)
        }.joined(separator: "\n\n")
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.count, 60, "30 paragraphs + 30 tables")

        _ = mountMarkdown { MarkdownText(source: source) }

        let mounted = RichBudgetedMarkdownBody.debugMountedBlockIndices
        XCTAssertEqual(
            Set(mounted).count,
            mounted.count,
            "no block may be mounted twice when prefix and tail overlap"
        )
        XCTAssertEqual(mounted.count, blocks.count, "cut > tail mounts everything once")
        XCTAssertTrue(
            mounted.contains(blocks.count - 1),
            "the newest block must stay mounted when the cut passes the tail"
        )
    }

    /// Hosted live-tail regression through the REAL reveal action: with
    /// 30 tables (cut < tail initially), repeated Continue Reading taps
    /// must only ever ADD mounted blocks — including across the
    /// cut == tail and cut > tail transitions — and the footer must
    /// disappear exactly when the hidden gap is gone. Kept small on
    /// purpose: the fully revealed state is the most expensive teardown
    /// this suite defers, and CI runners process deferred teardowns far
    /// slower than a dev Mac (see dismountCurrentWindow).
    func testHostedRevealNeverRetractsTailAndFooterDisappearsWhenRevealed() throws {
        let source = (0..<36).map { index in
            "Section \(index) intro paragraph.\n\n"
                + MarkdownShowcaseFixtures.alignedTable(section: index, rows: 4, columns: 5)
        }.joined(separator: "\n\n")
        let blocks = MarkdownParser.parse(source)
        let units = MarkdownRichContentPolicy.richUnitsByBlock(blocks)
        // Precondition: the fixture must start GATED (cut < tail) so the
        // reveal progression really crosses cut == tail and cut > tail.
        let initialPlan = MarkdownRichContentPolicy.mountedPlan(
            unitsByBlock: units,
            unitBudget: MarkdownRichContentPolicy.eagerRichUnitBudget
        )
        guard case .split = initialPlan else {
            return XCTFail("fixture must start gated: \(initialPlan)")
        }

        _ = mountMarkdown { MarkdownText(source: source) }

        var previous = Set(RichBudgetedMarkdownBody.debugMountedBlockIndices)
        XCTAssertTrue(
            previous.contains(blocks.count - 1),
            "the newest block is mounted from the start (live tail)"
        )
        // Initially gated: fewer than all blocks mounted, footer present.
        XCTAssertLessThan(previous.count, blocks.count)

        XCTAssertTrue(
            RichBudgetedMarkdownBody.debugFooterVisible,
            "the footer is shown while a hidden gap exists"
        )

        var taps = 0
        while previous.count < blocks.count {
            advanceRevealThroughProductionPath()
            taps += 1
            let mounted = Set(RichBudgetedMarkdownBody.debugMountedBlockIndices)
            XCTAssertEqual(
                mounted.count,
                RichBudgetedMarkdownBody.debugMountedBlockIndices.count,
                "no duplicate mounts across the overlap transition"
            )
            XCTAssertTrue(
                mounted.isSuperset(of: previous),
                "a reveal tap must never retract mounted content (tap \(taps))"
            )
            XCTAssertTrue(
                mounted.contains(blocks.count - 1),
                "the newest block stays mounted through every tap"
            )
            previous = mounted
            if taps > 20 { XCTFail("reveal never completes"); break }
        }

        // Fully revealed: footer is gone and the mounted set is exactly
        // everything, once.
        XCTAssertEqual(previous.count, blocks.count)
        XCTAssertFalse(
            RichBudgetedMarkdownBody.debugFooterVisible,
            "the footer must disappear once no hidden gap remains"
        )
    }

    /// Hosted: the streaming -> settled transition does not reduce the
    /// mounted newest content when the gate sits beyond the tail
    /// boundary — the exact state the pre-fix union computation broke.
    func testHostedStreamingToSettledBeyondTailKeepsNewestMounted() throws {
        let source = (0..<30).map { index in
            "Section \(index) intro paragraph.\n\n"
                + MarkdownShowcaseFixtures.alignedTable(section: index, rows: 4, columns: 5)
        }.joined(separator: "\n\n")
        let blocks = MarkdownParser.parse(source)

        _ = mountMarkdown { MarkdownText(source: source, isStreaming: true) }
        let streaming = Set(RichBudgetedMarkdownBody.debugMountedBlockIndices)

        _ = mountMarkdown { MarkdownText(source: source) }
        let settled = Set(RichBudgetedMarkdownBody.debugMountedBlockIndices)

        XCTAssertEqual(
            settled,
            streaming,
            "settling must not reduce the mounted set in the beyond-tail gate state"
        )
        XCTAssertEqual(settled.count, blocks.count)
        XCTAssertTrue(settled.contains(blocks.count - 1))
    }

}
