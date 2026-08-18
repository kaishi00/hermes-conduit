import XCTest
import UIKit
import SwiftUI
@testable import Conduit

/// Reference-style links (`[text][id]` + `[id]: url`) must resolve across the
/// whole chat message even though Conduit parses each paragraph/list item/
/// table cell as an isolated Markdown fragment. The fix: definitions are
/// collected message-wide before block parsing and re-appended to each
/// fragment before Foundation parses it.
///
/// The Foundation tests below characterize `AttributedString(markdown:)` with
/// the exact options the production inline parsers use
/// (`.init(interpretedSyntax: .full)`). If Foundation ever stops resolving
/// reference links under those options, the extractor design in
/// `MarkdownParser` must be revisited — do not silently weaken these tests.
final class MarkdownReferenceLinkTests: XCTestCase {

    private let fullSyntaxOptions: AttributedString.MarkdownParsingOptions = .init(interpretedSyntax: .full)

    // MARK: - Foundation characterization

    func testFoundationFullDocumentResolvesReferenceLinkAndHidesDefinition() throws {
        let markdown = """
        See [the docs][docs].

        [docs]: https://example.com
        """
        let attributed = try AttributedString(markdown: markdown, options: fullSyntaxOptions)

        XCTAssertEqual(String(attributed.characters), "See the docs.")
        XCTAssertFalse(
            String(attributed.characters).contains("[docs]:"),
            "A consumed link reference definition must not remain visible"
        )

        let docsRange = try XCTUnwrap(attributed.characters.firstRange(of: "the docs"))
        let link = try XCTUnwrap(attributed[docsRange].link)
        XCTAssertEqual(link.absoluteString, "https://example.com")
    }

    func testFoundationFragmentCompositeResolvesReferenceLink() throws {
        // This is the exact composite the production inline parsers build:
        // one block's fragment, then the message's collected definitions.
        let fragment = "Read [the docs][docs]."
        let definitions = "[docs]: https://example.com/docs"
        let composite = fragment + "\n\n" + definitions

        let attributed = try AttributedString(markdown: composite, options: fullSyntaxOptions)

        XCTAssertEqual(String(attributed.characters), "Read the docs.")
        let docsRange = try XCTUnwrap(attributed.characters.firstRange(of: "the docs"))
        let link = try XCTUnwrap(attributed[docsRange].link)
        XCTAssertEqual(link.absoluteString, "https://example.com/docs")
    }

    func testFoundationCompositeLeavesFragmentsWithoutReferencesUnchanged() throws {
        let fragment = "Plain [inline](https://example.com/inline) text."
        let definitions = "[docs]: https://example.com/docs"

        let alone = try AttributedString(markdown: fragment, options: fullSyntaxOptions)
        let composite = try AttributedString(
            markdown: fragment + "\n\n" + definitions,
            options: fullSyntaxOptions
        )

        XCTAssertEqual(String(composite.characters), String(alone.characters))
        XCTAssertEqual(composite.runs.count, alone.runs.count)
        XCTAssertTrue(
            String(composite.characters).contains("inline text."),
            "Appending definitions must not disturb the fragment's visible text"
        )
    }

    func testFoundationCompositePreservesFragmentContentWithSoftLineBreaks() throws {
        // Paragraph accumulation keeps internal newlines in the fragment.
        // Foundation renders soft breaks as spaces under `.full` — the same
        // behavior production already relies on without definitions — and
        // appending definitions must not disturb it beyond resolving the link.
        let fragment = "first line\nsecond [link][id] line"
        let definitions = "[id]: https://example.com"

        let composite = try AttributedString(
            markdown: fragment + "\n\n" + definitions,
            options: fullSyntaxOptions
        )
        let alone = try AttributedString(markdown: fragment, options: fullSyntaxOptions)

        XCTAssertEqual(String(alone.characters), "first line second [link][id] line")
        XCTAssertEqual(String(composite.characters), "first line second link line")

        let linkRange = try XCTUnwrap(composite.characters.firstRange(of: "link"))
        let link = try XCTUnwrap(composite[linkRange].link)
        XCTAssertEqual(link.absoluteString, "https://example.com")
    }

    func testFoundationSupportsCommonMarkReferenceVariants() throws {
        let markdown = """
        Full [one][l1], collapsed [two][], shortcut [l3], titled [four][l4],
        angle [five][l5], case-insensitive [six][L6].

        [l1]: https://example.com/1
        [two]: https://example.com/2
        [l3]: https://example.com/3
        [l4]: https://example.com/4 "Optional title"
        [l5]: <https://example.com/5>
        [L6]: https://example.com/6
        """
        let attributed = try AttributedString(markdown: markdown, options: fullSyntaxOptions)

        let characters = String(attributed.characters)
        XCTAssertEqual(
            characters,
            "Full one, collapsed two, shortcut l3, titled four, angle five, case-insensitive six."
        )

        func link(on text: String) throws -> URL {
            let range = try XCTUnwrap(
                attributed.characters.firstRange(of: text),
                "Expected visible text \"\(text)\" in \"\(characters)\""
            )
            return try XCTUnwrap(
                attributed[range].link,
                "Expected a link on \"\(text)\""
            )
        }
        XCTAssertEqual(try link(on: "one").absoluteString, "https://example.com/1")
        XCTAssertEqual(try link(on: "two").absoluteString, "https://example.com/2")
        XCTAssertEqual(try link(on: "l3").absoluteString, "https://example.com/3")
        XCTAssertEqual(try link(on: "four").absoluteString, "https://example.com/4")
        XCTAssertEqual(try link(on: "five").absoluteString, "https://example.com/5")
        XCTAssertEqual(try link(on: "six").absoluteString, "https://example.com/6")
    }

    func testFoundationUnresolvedReferenceRendersLiteralTextWithoutInventingDestination() throws {
        let markdown = "See [missing][nope] and a lone [orphan].\n\n[other]: https://example.com"
        let attributed = try AttributedString(markdown: markdown, options: fullSyntaxOptions)

        let characters = String(attributed.characters)
        XCTAssertTrue(characters.contains("[missing][nope]"), "Unresolved references keep their literal text")
        XCTAssertTrue(characters.contains("[orphan]"))
        for run in attributed.runs {
            XCTAssertNil(run.link, "No destination may be invented for unresolved references")
        }
    }

    // MARK: - Document extraction (MarkdownParser.parseDocument)

    func testParseDocumentCollectsDefinitionAndOmitsItFromBlocks() {
        let document = MarkdownParser.parseDocument(
            "See [the docs][docs].\n\n[docs]: https://example.com",
            recognizesGatewayMedia: false
        )

        XCTAssertTrue(document.references.containsDefinitions)
        XCTAssertEqual(
            document.references.definitionsMarkdown,
            "[docs]: https://example.com"
        )
        XCTAssertEqual(document.blocks, [.paragraph("See [the docs][docs].")])
    }

    func testParseDocumentCollectsDefinitionUsedBeforeIt() {
        let document = MarkdownParser.parseDocument(
            "[first][one]\n\n[one]: https://example.com/one",
            recognizesGatewayMedia: false
        )

        XCTAssertTrue(document.references.containsDefinitions)
        XCTAssertEqual(document.blocks, [.paragraph("[first][one]")])
    }

    func testParseDocumentLeavesDefinitionsInsideFencedCodeBlocks() {
        let source = """
        Before [x][in-code].

        ```swift
        let docs = "[in-code]: https://example.com/not-a-definition"
        ```

        [in-code]: https://example.com/real
        """
        let document = MarkdownParser.parseDocument(source, recognizesGatewayMedia: false)

        XCTAssertEqual(
            document.references.definitionsMarkdown,
            "[in-code]: https://example.com/real",
            "Only the definition outside the fence may be collected"
        )
        XCTAssertEqual(document.blocks.count, 2)
        guard case .code(let language, let codeSource) = document.blocks[1] else {
            return XCTFail("Expected a code block, got \(document.blocks[1])")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(codeSource.contains("[in-code]: https://example.com/not-a-definition"))
    }

    func testParseDocumentLeavesDefinitionsInsideMathBlocks() {
        let source = """
        Before [x][in-math].

        $$
        [in-math]: https://example.com/not-a-definition
        $$

        [in-math]: https://example.com/real
        """
        let document = MarkdownParser.parseDocument(source, recognizesGatewayMedia: false)

        XCTAssertEqual(
            document.references.definitionsMarkdown,
            "[in-math]: https://example.com/real",
            "Only the definition outside the math block may be collected"
        )
        XCTAssertEqual(document.blocks.count, 2)
        guard case .math(let mathSource) = document.blocks[1] else {
            return XCTFail("Expected a math block, got \(document.blocks[1])")
        }
        XCTAssertTrue(mathSource.contains("[in-math]: https://example.com/not-a-definition"))
    }

    func testParseDocumentDoesNotSwallowFootnoteMarkers() {
        let source = "Text with a footnote[^1].\n\n[^1]: https://example.com/footnote"
        let document = MarkdownParser.parseDocument(source, recognizesGatewayMedia: false)

        XCTAssertFalse(
            document.references.containsDefinitions,
            "[^1]: footnote definitions are out of scope and must stay visible text"
        )
        XCTAssertEqual(
            document.blocks,
            [
                .paragraph("Text with a footnote[^1]."),
                .paragraph("[^1]: https://example.com/footnote")
            ]
        )
    }

    func testParseDocumentRemovingDefinitionDoesNotJoinNeighboringParagraphs() {
        let source = """
        First paragraph.

        [docs]: https://example.com

        Second paragraph.
        """
        let document = MarkdownParser.parseDocument(source, recognizesGatewayMedia: false)

        XCTAssertEqual(
            document.blocks,
            [.paragraph("First paragraph."), .paragraph("Second paragraph.")],
            "A removed definition must leave a blank-line boundary so paragraphs stay separate blocks"
        )
    }

    func testParseDocumentCollectsDefinitionAdjacentToParagraphWithoutBlankLine() {
        let document = MarkdownParser.parseDocument(
            "See [docs].\n[docs]: https://example.com",
            recognizesGatewayMedia: false
        )

        XCTAssertEqual(document.references.definitionsMarkdown, "[docs]: https://example.com")
        XCTAssertEqual(document.blocks, [.paragraph("See [docs].")])
    }

    func testParseDocumentSupportsDefinitionTitleForms() {
        let source = """
        [a][one] [b][two] [c][three]

        [one]: https://example.com/one "Quoted title"
        [two]: https://example.com/two 'Single title'
        [three]: <https://example.com/three> (Parenthesized title)
        """
        let document = MarkdownParser.parseDocument(source, recognizesGatewayMedia: false)

        XCTAssertEqual(
            document.references.definitionsMarkdown.split(separator: "\n").count,
            3,
            "All three single-line definition title forms must be collected"
        )
        XCTAssertEqual(document.blocks, [.paragraph("[a][one] [b][two] [c][three]")])
    }

    func testParseDocumentWithoutDefinitionsYieldsEmptyReferenceContext() {
        let document = MarkdownParser.parseDocument(
            "# Heading\n\nPlain paragraph with [inline](https://example.com) link.",
            recognizesGatewayMedia: false
        )

        XCTAssertFalse(document.references.containsDefinitions)
        XCTAssertEqual(
            document.blocks,
            [
                .heading(level: 1, text: "Heading"),
                .paragraph("Plain paragraph with [inline](https://example.com) link.")
            ]
        )
    }

    // MARK: - Simple selectable-flow path (MarkdownSelectionFormatter)

    func testSelectionFormatterResolvesReferenceLinksInSimpleFlow() throws {
        let source = "Read [the docs][docs].\n\n[docs]: https://example.com/docs"
        let document = MarkdownParser.parseDocument(source, recognizesGatewayMedia: false)
        let content = try XCTUnwrap(
            MarkdownSelectionFormatter.attributedText(
                for: document.blocks,
                references: document.references,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                newestCharacterOpacities: []
            )
        )

        XCTAssertEqual(content.string, "Read the docs.")

        let docsRange = (content.string as NSString).range(of: "the docs")
        XCTAssertNotEqual(docsRange.location, NSNotFound)
        let link = try XCTUnwrap(content.attribute(.link, at: docsRange.location, effectiveRange: nil) as? URL)
        XCTAssertEqual(link.absoluteString, "https://example.com/docs")

        XCTAssertFalse(content.string.contains("[docs]:"))
    }

    func testSelectionFormatterResolvesShortcutReferenceInListItem() throws {
        let source = """
        - See [docs].
        - Also [the guide][guide].

        [docs]: https://example.com/docs
        [guide]: https://example.com/guide "Guide"
        """
        let document = MarkdownParser.parseDocument(source, recognizesGatewayMedia: false)
        let content = try XCTUnwrap(
            MarkdownSelectionFormatter.attributedText(
                for: document.blocks,
                references: document.references,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                newestCharacterOpacities: []
            )
        )

        XCTAssertTrue(content.string.contains("See docs."), "Shortcut reference must resolve to its label text")
        let docsRange = (content.string as NSString).range(of: "docs.")
        let link = try XCTUnwrap(content.attribute(.link, at: docsRange.location, effectiveRange: nil) as? URL)
        XCTAssertEqual(link.absoluteString, "https://example.com/docs")

        let guideRange = (content.string as NSString).range(of: "the guide")
        let guideLink = try XCTUnwrap(content.attribute(.link, at: guideRange.location, effectiveRange: nil) as? URL)
        XCTAssertEqual(guideLink.absoluteString, "https://example.com/guide")
    }

    // MARK: - Rich block-view path (MarkdownText → blocks → InlineMarkdown)

    /// A table forces MarkdownText down the block-view path, so this pins the
    /// whole SwiftUI chain: MarkdownText → MarkdownTable → InlineMarkdown →
    /// SelectableTextView, including the reference context handoff. (The
    /// custom table parser requires two or more columns; single-column pipe
    /// tables fall through to Foundation's own table handling instead.)
    @MainActor
    func testTableCellResolvesReferenceLinkThroughBlockViewChain() throws {
        let source = """
        | Label | Resource |
        |---|---|
        | docs | [Docs][docs] |

        [docs]: https://example.com/docs
        """
        let host = UIHostingController(rootView: MarkdownText(source: source))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let cellTextView = try XCTUnwrap(
            allSubviews(of: host.view)
                .compactMap { $0 as? UITextView }
                .first { $0.attributedText.string == "Docs" },
            "The table cell's selectable text view must exist in the rendered hierarchy"
        )

        let link = try XCTUnwrap(
            cellTextView.attributedText.attribute(.link, at: 0, effectiveRange: nil) as? URL
        )
        XCTAssertEqual(link.absoluteString, "https://example.com/docs")
        XCTAssertFalse(cellTextView.attributedText.string.contains("[docs]:"))
    }

    /// Reference links must resolve in every container that ultimately routes
    /// through an inline parser. The trailing divider forces MarkdownText off
    /// the selectable-flow fast path and onto the block-view path, so these
    /// links resolve through InlineMarkdown + the message-level reference
    /// context, not MarkdownSelectionFormatter.
    @MainActor
    func testReferenceLinksResolveAcrossBlockContainers() throws {
        let source = """
        ## Notes on [release][r]

        - item with [full][r] form
        - item with [collapsed][] form

        > quoted [shortcut] usage

        ::: note
        Callout with [styled][r] link.
        :::

        ---

        [r]: https://example.com/r
        [collapsed]: https://example.com/collapsed
        [shortcut]: https://example.com/shortcut
        """
        let host = UIHostingController(rootView: MarkdownText(source: source))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let linkedURLs = Set(
            allSubviews(of: host.view)
                .compactMap { $0 as? UITextView }
                .flatMap { textView -> [URL] in
                    (0..<textView.attributedText.length).compactMap { offset in
                        textView.attributedText.attribute(.link, at: offset, effectiveRange: nil) as? URL
                    }
                }
                .map(\.absoluteString)
        )

        XCTAssertTrue(linkedURLs.contains("https://example.com/r"), "Heading/list/callout links must resolve; got \(linkedURLs)")
        XCTAssertTrue(linkedURLs.contains("https://example.com/collapsed"), "Collapsed reference must resolve; got \(linkedURLs)")
        XCTAssertTrue(linkedURLs.contains("https://example.com/shortcut"), "Quote shortcut reference must resolve; got \(linkedURLs)")
    }

    /// Ordinary inline links must be untouched by the reference work, and an
    /// unresolved reference must degrade to literal text (no invented URL).
    @MainActor
    func testOrdinaryInlineLinksAndUnresolvedReferencesThroughBlockViewChain() throws {
        let source = """
        | Kind | Detail |
        |---|---|
        | inline | [inline](https://example.com/inline) |
        | broken | [unresolved][missing] |

        [real]: https://example.com/real
        """
        let host = UIHostingController(rootView: MarkdownText(source: source))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let cellStrings = allSubviews(of: host.view)
            .compactMap { $0 as? UITextView }
            .map { $0.attributedText.string }
        XCTAssertTrue(cellStrings.contains(where: { $0 == "inline" }))
        XCTAssertTrue(cellStrings.contains(where: { $0.contains("[unresolved][missing]") }),
                      "Unresolved reference must stay literal, got \(cellStrings)")
        XCTAssertFalse(cellStrings.contains(where: { $0.contains("[real]:") }),
                       "The definition must not be visible anywhere in the rendered message")
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }
}
