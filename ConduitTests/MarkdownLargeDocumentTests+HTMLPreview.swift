import XCTest
@testable import Conduit

/// Hermes' `::preview{file="…"}` directive: an agent's HTML file drawn in
/// the reply. These cover the pure pieces: which lines hold a preview, how
/// they parse into blocks, and the page built around the file.
///
/// An extension rather than its own class, for the same CI planner reason
/// as the media preview tests.
extension MarkdownLargeDocumentTests {

    // MARK: - Directive grammar

    func testHTMLPreview_DirectiveAloneOnItsLine() {
        XCTAssertEqual(
            TranscriptDirectives.segments(in: #"::preview{file="/root/.hermes/cache/reports/patch-status-chart.html"}"#),
            [.preview(file: "/root/.hermes/cache/reports/patch-status-chart.html")]
        )
        XCTAssertEqual(
            TranscriptDirectives.segments(in: "::preview{file='chart.html' height=\"480\"}"),
            [.preview(file: "chart.html")]
        )
    }

    func testHTMLPreview_DirectiveInsideASentenceKeepsTheText() {
        XCTAssertEqual(
            TranscriptDirectives.segments(in: #"Here it is ::preview{file="/tmp/a.html"} as asked."#),
            [.text("Here it is"), .preview(file: "/tmp/a.html"), .text("as asked.")]
        )
    }

    func testHTMLPreview_NotADirective() {
        XCTAssertNil(TranscriptDirectives.segments(in: "Plain text"))
        XCTAssertNil(TranscriptDirectives.segments(in: #"std::preview{file="/tmp/a.html"}"#))
        XCTAssertNil(TranscriptDirectives.segments(in: #"`::preview{file="/tmp/a.html"}`"#))
        XCTAssertNil(TranscriptDirectives.segments(in: "::preview{file=/tmp/a.html}"))
        XCTAssertNil(TranscriptDirectives.segments(in: #"::preview{file=""}"#))
    }

    func testHTMLPreview_HTMLExtensions() {
        XCTAssertTrue(TranscriptDirectives.isHTML("/tmp/chart.html"))
        XCTAssertTrue(TranscriptDirectives.isHTML("/tmp/CHART.HTM"))
        XCTAssertTrue(TranscriptDirectives.isHTML("/tmp/page.xhtml"))
        XCTAssertFalse(TranscriptDirectives.isHTML("/tmp/chart.svg"))
        XCTAssertFalse(TranscriptDirectives.isHTML("/tmp/chart.html.txt"))
    }

    func testHTMLPreview_ReadAloudSkipsPreviews() {
        let text = "Chart below.\n::preview{file=\"/tmp/a.html\"}\nDone."
        XCTAssertEqual(TranscriptDirectives.removingPreviews(from: text), "Chart below.\nDone.")
        let quoted = "> Example: ::preview{file=\"/tmp/a.html\"}"
        XCTAssertEqual(TranscriptDirectives.removingPreviews(from: quoted), quoted)
        let table = "::preview{file=\"/tmp/a.html\"} | x\n--- | ---\n1 | 2"
        XCTAssertEqual(TranscriptDirectives.removingPreviews(from: table), table)
        let crlfTable = table.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(TranscriptDirectives.removingPreviews(from: crlfTable), table)
    }

    // MARK: - Parsing

    func testHTMLPreview_ParsesIntoAPreviewBlock() {
        let source = "Here is the chart:\n::preview{file=\"/root/report.html\"}\nAnything else?"
        let blocks = MarkdownParser.parse(source, recognizesGatewayMedia: true)
        XCTAssertEqual(blocks, [
            .paragraph("Here is the chart:"),
            .htmlPreview(path: "/root/report.html"),
            .paragraph("Anything else?")
        ])
    }

    func testHTMLPreview_OtherFilesGetTheirCard() {
        let blocks = MarkdownParser.parse("::preview{file=\"/tmp/plot.png\"}", recognizesGatewayMedia: true)
        XCTAssertEqual(blocks, [.image(url: "MEDIA: /tmp/plot.png", alt: "plot.png")])
    }

    func testHTMLPreview_StaysTextWithoutGatewayAccess() {
        let blocks = MarkdownParser.parse("::preview{file=\"/tmp/a.html\"}")
        XCTAssertEqual(blocks, [.paragraph("::preview{file=\"/tmp/a.html\"}")])
    }

    func testHTMLPreview_QuotedDirectiveIsAnExample() {
        let blocks = MarkdownParser.parse("> Example: ::preview{file=\"/tmp/a.html\"}", recognizesGatewayMedia: true)
        XCTAssertFalse(blocks.contains { if case .htmlPreview = $0 { return true } else { return false } }, "\(blocks)")
    }

    func testHTMLPreview_TableHeaderStaysATable() {
        let source = "::preview{file=\"/tmp/a.html\"} | x\n--- | ---\n1 | 2"
        let blocks = MarkdownParser.parse(source, recognizesGatewayMedia: true)
        XCTAssertFalse(blocks.contains { if case .htmlPreview = $0 { return true } else { return false } }, "\(blocks)")
    }

    func testHTMLPreview_CountsAsAWebPage() {
        XCTAssertEqual(MarkdownRichContentPolicy.webPageUnits(.htmlPreview(path: "/tmp/a.html")), MarkdownRichContentPolicy.diagramUnits)
        XCTAssertEqual(MarkdownRichContentPolicy.richUnits(.htmlPreview(path: "/tmp/a.html")), MarkdownRichContentPolicy.diagramUnits)
    }

    // MARK: - The page

    func testHTMLPreview_ThemeGoesIntoTheHeadAndScriptsBeforeBodyEnd() {
        let document = "<!DOCTYPE html><html><head><title>t</title></head><body><div>chart</div></body></html>"
        let page = HTMLPreviewPage.framed(document, theme: HTMLPreviewTheme(light: true), presentation: .inline)
        XCTAssertTrue(page.hasPrefix("<!DOCTYPE html><html><head><meta name=\"viewport\""), page)
        XCTAssertTrue(page.contains("--foreground:"))
        XCTAssertTrue(page.contains("color-scheme:light"))
        let scriptRange = page.range(of: HTMLPreviewPage.messageHandlerName)
        let bodyEnd = page.range(of: "</body>")
        XCTAssertNotNil(scriptRange)
        XCTAssertNotNil(bodyEnd)
        if let scriptRange, let bodyEnd { XCTAssertLessThan(scriptRange.lowerBound, bodyEnd.lowerBound) }
        XCTAssertTrue(page.hasSuffix("</body></html>"))
    }

    func testHTMLPreview_FragmentsAndDoctypeOnlyDocuments() {
        let fragment = HTMLPreviewPage.framed("<div>hi</div>", theme: HTMLPreviewTheme(light: false), presentation: .inline)
        XCTAssertTrue(fragment.hasPrefix("<meta name=\"viewport\""))
        XCTAssertTrue(fragment.contains("color-scheme:dark"))
        XCTAssertTrue(fragment.hasSuffix("</script>"))

        let doctype = HTMLPreviewPage.framed("<!doctype html>\n<div>hi</div>", theme: HTMLPreviewTheme(light: true), presentation: .inline)
        XCTAssertTrue(doctype.hasPrefix("<!doctype html><meta name=\"viewport\""), doctype)
    }

    func testHTMLPreview_FullScreenPageDoesNotReportHeight() {
        let page = HTMLPreviewPage.framed("<body>x</body>", theme: HTMLPreviewTheme(light: true), presentation: .fullScreen)
        XCTAssertFalse(page.contains("messageHandlers"))
        XCTAssertTrue(page.contains("window.hermes"))
    }

    func testHTMLPreview_DecodesTheDashboardDataURL() {
        let html = "<p>Ünïcode chart</p>"
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        XCTAssertEqual(HTMLPreviewPage.decodedDocument(fromDataURL: dataURL), html)
        XCTAssertNil(HTMLPreviewPage.decodedDocument(fromDataURL: "data:text/html;base64,"))
        XCTAssertNil(HTMLPreviewPage.decodedDocument(fromDataURL: "not a data url"))
        let tooLarge = "data:text/html;base64," + Data(count: HTMLPreviewPage.maximumDocumentBytes + 3).base64EncodedString()
        XCTAssertNil(HTMLPreviewPage.decodedDocument(fromDataURL: tooLarge))
        let notUTF8 = "data:text/html;base64," + Data([0x3C, 0x70, 0x3E, 0xFF, 0xFE, 0xC3]).base64EncodedString()
        XCTAssertNil(HTMLPreviewPage.decodedDocument(fromDataURL: notUTF8))
    }

    func testHTMLPreview_InlineHeightIsBounded() {
        XCTAssertEqual(HTMLPreviewPage.clampedInlineHeight(10), HTMLPreviewPage.minimumInlineHeight)
        XCTAssertEqual(HTMLPreviewPage.clampedInlineHeight(320.2), 321)
        XCTAssertEqual(HTMLPreviewPage.clampedInlineHeight(5_000), HTMLPreviewPage.maximumInlineHeight)
    }

    func testHTMLPreview_NavigationStaysOnThePage() {
        let link = URL(string: "https://example.com/details")!
        // The page itself loads.
        XCTAssertTrue(HTMLPreviewPage.navigationDecision(url: URL(string: "about:blank"), isMainFrame: true, userTapped: false).allow)
        // An embedded frame may load.
        XCTAssertTrue(HTMLPreviewPage.navigationDecision(url: link, isMainFrame: false, userTapped: false).allow)
        // A tapped link opens in the browser instead.
        let tapped = HTMLPreviewPage.navigationDecision(url: link, isMainFrame: true, userTapped: true)
        XCTAssertFalse(tapped.allow)
        XCTAssertEqual(tapped.openExternally, link)
        // A script moving the page away goes nowhere.
        let scripted = HTMLPreviewPage.navigationDecision(url: link, isMainFrame: true, userTapped: false)
        XCTAssertFalse(scripted.allow)
        XCTAssertNil(scripted.openExternally)
        // Other schemes never open.
        let phone = HTMLPreviewPage.navigationDecision(url: URL(string: "tel:123"), isMainFrame: true, userTapped: true)
        XCTAssertFalse(phone.allow)
        XCTAssertNil(phone.openExternally)
        XCTAssertFalse(HTMLPreviewPage.navigationDecision(url: URL(string: "file:///etc/hosts"), isMainFrame: false, userTapped: false).allow)
    }
}
