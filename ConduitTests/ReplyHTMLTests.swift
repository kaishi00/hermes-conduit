import SwiftUI
import XCTest
@testable import Conduit

/// HTML a reply writes (ReplyHTML, Eric 2026-11-26): a page drawn in the
/// page card, a `<details>` fold, and the text tags drawn as text. The same
/// cases as Conduit for desktop's htmlInReplies tests and the plugin's push
/// text, so the three read a reply alike.
@MainActor
final class ReplyHTMLTests: XCTestCase {

    // MARK: - Pages

    func testAPageStartsAtAPageTagAtALineStartNeverAtATextTagOrProse() {
        XCTAssertTrue(ReplyHTML.startsPage(#"<div class="chart">"#))
        XCTAssertTrue(ReplyHTML.startsPage("   <table>"))
        XCTAssertTrue(ReplyHTML.startsPage("<!DOCTYPE html>"))
        XCTAssertTrue(ReplyHTML.startsPage(#"<svg viewBox="0 0 10 10">"#))
        XCTAssertFalse(ReplyHTML.startsPage("<details>"))
        XCTAssertFalse(ReplyHTML.startsPage(#"<span style="color:red">x</span>"#))
        XCTAssertFalse(ReplyHTML.startsPage("<Conversation>"))
        XCTAssertFalse(ReplyHTML.startsPage("Use a <div> here"))
        XCTAssertFalse(ReplyHTML.startsPage("    <div>"), "indented four spaces is code")
        XCTAssertFalse(ReplyHTML.startsPage("<divider>"))
    }

    func testAPageRunsToWhereItsElementsCloseBlankLinesAndAll() {
        let lines = ["<div>", "  <p>One</p>", "", "  <p>Two</p>", "</div>", "After"]
        XCTAssertEqual(ReplyHTML.page(in: lines, at: 0), .init(start: 0, end: 5, isComplete: true))
    }

    func testAPageTakesInThePageTagsThatFollowItAsOnePage() {
        let text = "<style>.a{color:red}</style>\n\n<div class=\"a\">Hi</div>\n<script>if (1 < 2) document.title = \"</div>\"</script>\nDone."
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks, [
            .htmlPage(html: "<style>.a{color:red}</style>\n\n<div class=\"a\">Hi</div>\n<script>if (1 < 2) document.title = \"</div>\"</script>", isComplete: true),
            .paragraph("Done.")
        ])
    }

    func testAPageIsIncompleteWhileAnElementIsOpenATagIsCutOrNothingFollowsIt() {
        XCTAssertEqual(MarkdownParser.parse("Here:\n<div>\n<p>One"), [
            .paragraph("Here:"),
            .htmlPage(html: "<div>\n<p>One", isComplete: false)
        ])
        XCTAssertEqual(MarkdownParser.parse("<div>Hi</div>\n<scr").first, .htmlPage(html: "<div>Hi</div>", isComplete: false))
        XCTAssertEqual(MarkdownParser.parse("<div>Hi</div>\n").first, .htmlPage(html: "<div>Hi</div>", isComplete: false))
        XCTAssertEqual(MarkdownParser.parse("<div><!-- note").first, .htmlPage(html: "<div><!-- note", isComplete: false))
        XCTAssertEqual(MarkdownParser.parse("<script>let a = 1").first, .htmlPage(html: "<script>let a = 1", isComplete: false))
    }

    func testAnElementLeftOpenInsideOneThatClosesIsClosedAsABrowserDoes() {
        XCTAssertEqual(MarkdownParser.parse("<div><p>One<p>Two</div>\nAfter").first, .htmlPage(html: "<div><p>One<p>Two</div>", isComplete: true))
    }

    func testAPageKeepsGoingWhenTheLineThatClosesOneElementOpensAnother() {
        XCTAssertEqual(MarkdownParser.parse("<div>A</div><div>\nB\n</div>\nAfter"), [
            .htmlPage(html: "<div>A</div><div>\nB\n</div>", isComplete: true),
            .paragraph("After")
        ])
    }

    func testAnOpenFoldCountsItsPagesTowardTheReplysBudget() {
        let fold = MarkdownBlock.fold(summary: "Chart", body: "<div>A</div>\n\nAfter", isOpen: true)
        XCTAssertEqual(MarkdownRichContentPolicy.richUnits(fold), MarkdownRichContentPolicy.diagramUnits)
        XCTAssertEqual(MarkdownRichContentPolicy.webPageUnits(fold), MarkdownRichContentPolicy.diagramUnits)
        XCTAssertEqual(MarkdownRichContentPolicy.richUnits(.fold(summary: "Chart", body: "<div>A</div>", isOpen: false)), 0)
        // A preview the fold's chat mounts counts too.
        let preview = MarkdownBlock.fold(summary: "Chart", body: "::preview{file=\"/tmp/a.html\"}", isOpen: true)
        XCTAssertEqual(MarkdownRichContentPolicy.richUnits(preview), MarkdownRichContentPolicy.diagramUnits)
    }

    func testAPageEndsAtProseAfterItsClosingTagEvenProseWithATag() {
        let lines = ["<div>x</div> as <code>y</code>", "<p>z</p>", "After"]
        XCTAssertEqual(ReplyHTML.page(in: ["<div>x</div> as <code>y", "z</code>", "After"], at: 0), .init(start: 0, end: 1, isComplete: true))
        XCTAssertEqual(ReplyHTML.page(in: lines, at: 0).end, 2)
    }

    func testAFoldWrittenOnOneLineFolds() {
        XCTAssertEqual(ReplyHTML.foldsApart(["<details><summary>S</summary>The body.</details>", "After."]),
                       ["<details><summary>S</summary>", "The body.", "</details>", "After."])
        XCTAssertEqual(ReplyHTML.foldsApart(["```", "<details><summary>S</summary>x</details>", "```"]),
                       ["```", "<details><summary>S</summary>x</details>", "```"], "code stays as written")
        XCTAssertEqual(ReplyHTML.foldsApart(["Write </details> to close one."]), ["Write </details> to close one."])
    }

    func testProseThatStartsWithDetailsStaysProse() {
        let prose = ["<details> and <summary> make a fold.", "", "After."]
        XCTAssertEqual(ReplyHTML.foldsApart(prose), prose)
        XCTAssertEqual(ReplyHTML.foldsApart(["<details> is the tag.", "After."]), ["<details> is the tag.", "After."])
        XCTAssertEqual(ReplyHTML.foldsApart(["<details data-x=\"a>b\"><summary>S</summary>Body</details>"]),
                       ["<details data-x=\"a>b\"><summary>S</summary>", "Body", "</details>"])
    }

    func testAOneLineFoldWhoseBodyStartsWithAFenceStaysAsWritten() {
        let line = ["<details><summary>S</summary>```code```</details>", "After"]
        XCTAssertEqual(ReplyHTML.foldsApart(line), line)
    }

    func testAPageInAOneLineFoldIsSaidAsAPage() {
        XCTAssertEqual(ReplyHTML.pagesSaid("<details><summary>S</summary><div>A</div></details>", as: "Page"),
                       "<details><summary>S</summary>\nPage\n</details>")
    }

    func testProseStartingWithDetailsStaysProseWhenLaterClosesAreOtherFoldsOrCode() {
        let other = ["<details> makes a section.", "", "<details>", "<summary>S</summary>", "body", "</details>"]
        XCTAssertEqual(ReplyHTML.foldsApart(other), other)
        let code = ["<details> makes a section.", "", "```", "</details>", "```"]
        XCTAssertEqual(ReplyHTML.foldsApart(code), code)
        let span = ["<details> makes a section.", "", "Wrap it with `</details>` to close."]
        XCTAssertEqual(ReplyHTML.foldsApart(span), span)
    }

    func testAOneLineFoldFoldsWhileItsCloseIsStillBeingWritten() {
        XCTAssertEqual(ReplyHTML.foldsApart(["<details><summary>S</summary>Body so far"]), ["<details><summary>S</summary>", "Body so far"])
    }

    func testACompactFoldWithAnArrowInItsBodyFolds() {
        XCTAssertEqual(ReplyHTML.foldsApart(["<details><summary>Flow</summary>input -> parse", "then render", "</details>"]),
                       ["<details><summary>Flow</summary>", "input -> parse", "then render", "</details>"])
    }

    func testOpenInsideAQuotedValueDoesNotOpenAFold() {
        XCTAssertEqual(ReplyHTML.fold(in: ["<details title=\"open me\">", "<summary>S</summary>", "</details>"], at: 0)?.isOpen, false)
    }

    func testAPageCarriesOnOnlyAtAPageElementRightAfterIt() {
        XCTAssertEqual(ReplyHTML.page(in: ["<div>x</div> Use <div> to wrap.", "More prose"], at: 0), .init(start: 0, end: 1, isComplete: true))
        XCTAssertEqual(ReplyHTML.page(in: ["<div>a</div> <div>b", "</div>", "After"], at: 0).end, 2)
    }

    func testReadersTakeOffOnlyTheTagsThatPairUp() {
        XCTAssertEqual(ReplyHTML.withoutTags("An <b>unclosed tag"), "An <b>unclosed tag")
        XCTAssertEqual(ReplyHTML.withoutTags("click <span hidden>secret</span> now"), "click secret now")
        XCTAssertEqual(ReplyHTML.withoutTags("Use <b>`make`</b> now."), "Use `make` now.")
        XCTAssertEqual(ReplyHTML.withoutTags("Write `<b>` then <i>x</i>"), "Write `<b>` then x")
    }

    func testAFoldTakesAttributesAndOpensOnlyWhenMarkedOpen() {
        XCTAssertEqual(ReplyHTML.fold(in: ["<details class=\"x\" open>", "<summary>Why</summary>", "Because.", "</details>"], at: 0)?.isOpen, true)
        XCTAssertEqual(ReplyHTML.fold(in: ["<details class=\"opener\">", "<summary>Why</summary>", "</details>"], at: 0)?.isOpen, false)
    }

    func testATableRowThatStartsWithATagIsTheTables() {
        let table = "Tag | Meaning\n--- | ---\n<div> | container\n\nNext steps"
        XCTAssertEqual(ReplyHTML.pagesSaid(table, as: "Page"), table)
        let header = "Results:\n<div> | A\n--- | ---\n1 | 2"
        XCTAssertEqual(ReplyHTML.pagesSaid(header, as: "Page"), header)
        XCTAssertFalse(MarkdownParser.parse(header).contains { if case .htmlPage = $0 { return true } else { return false } })
    }

    func testAVoidElementIsAOneLinePage() {
        XCTAssertEqual(MarkdownParser.parse("<img src=\"https://example.com/a.png\">\nA picture.").first,
                       .htmlPage(html: "<img src=\"https://example.com/a.png\">", isComplete: true))
    }

    func testAFencedHTMLBlockStaysCode() {
        XCTAssertEqual(MarkdownParser.parse("```html\n<div>Hi</div>\n```"), [.code(language: "html", source: "<div>Hi</div>")])
    }

    func testAPageEndsTheParagraphAboveIt() {
        XCTAssertEqual(MarkdownParser.parse("Failures jumped:\n<table><tr><td>Thu</td><td>9</td></tr></table>\nThat's #3326."), [
            .paragraph("Failures jumped:"),
            .htmlPage(html: "<table><tr><td>Thu</td><td>9</td></tr></table>", isComplete: true),
            .paragraph("That's #3326.")
        ])
    }

    func testAPageIsSaidToBeOneWhereAReplyIsReadNotDrawn() {
        let reply = "Here:\n<div><script>chart()</script>Sales</div>\nDone."
        XCTAssertEqual(TranscriptDirectives.readable(from: reply), "Here:\n\(ReplyHTML.spokenNote)\nDone.")
        XCTAssertEqual(TranscriptDirectives.naming(in: reply), "Here:\n(a page in the chat)\nDone.")
        XCTAssertEqual(PreviewText.plain(reply), "Here: \(ReplyHTML.previewNote) Done.")
        XCTAssertFalse(VoiceReadBack.plainSpeech(reply).contains("chart()"))
        XCTAssertEqual(ReplyHTML.pagesSaid("No page < here", as: "x"), "No page < here")
    }

    // MARK: - Folds

    func testAFoldTakesItsSummaryAndTheMarkdownInside() {
        let text = "<details>\n<summary>Full log</summary>\n\n```\nFAIL test_upload\n```\n</details>\n\nAfter."
        XCTAssertEqual(MarkdownParser.parse(text), [
            .fold(summary: "Full log", body: "```\nFAIL test_upload\n```", isOpen: false),
            .paragraph("After.")
        ])
    }

    func testAFoldTakesASummaryOnItsOwnLineAndOpensWhenWrittenOpen() {
        XCTAssertEqual(MarkdownParser.parse("<details open>\n\n<summary>Why</summary>\n\nBecause.\n\n</details>"),
                       [.fold(summary: "Why", body: "Because.", isOpen: true)])
    }

    func testAFoldTakesWhatsWrittenSoFarWhileItsCloseHasntCome() {
        XCTAssertEqual(MarkdownParser.parse("<details>\n<summary>Log</summary>\n\nline 1"),
                       [.fold(summary: "Log", body: "line 1", isOpen: false)])
    }

    func testANestedFoldStaysInsideItsParent() {
        let text = "<details>\n<summary>Outer</summary>\n<details>\n<summary>Inner</summary>\nx\n</details>\n</details>\nAfter"
        XCTAssertEqual(MarkdownParser.parse(text), [
            .fold(summary: "Outer", body: "<details>\n<summary>Inner</summary>\nx\n</details>", isOpen: false),
            .paragraph("After")
        ])
    }

    // MARK: - Text tags

    private func drawn(_ source: String) -> AttributedString {
        InlineMarkdownContent.attributed(source: source, references: .empty)
    }

    private func run(_ text: AttributedString, _ word: String) -> AttributedString.Runs.Run? {
        guard let range = text.range(of: word) else { return nil }
        return text.runs.first { $0.range.contains(range.lowerBound) }
    }

    func testTextTagsDrawAsTextAndLeaveNoMarks() {
        let text = drawn("A <b>bold</b> <i>idea</i>, <mark>marked</mark>, <kbd>Ctrl</kbd>, H<sub>2</sub>O and <u>x</u>.")
        XCTAssertEqual(String(text.characters), "A bold idea, marked, Ctrl, H2O and x.")
        XCTAssertEqual(run(text, "bold")?.inlinePresentationIntent?.contains(.stronglyEmphasized), true)
        XCTAssertEqual(run(text, "idea")?.inlinePresentationIntent?.contains(.emphasized), true)
        XCTAssertEqual(run(text, "Ctrl")?.inlinePresentationIntent?.contains(.code), true)
        XCTAssertNotNil(run(text, "marked")?[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self])
        XCTAssertNotNil(run(text, "2")?[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self])
        XCTAssertNotNil(run(text, "x.")?[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self])
    }

    func testTextTagsKeepTheMarkdownInsideThem() {
        let text = drawn("<mark>a **bold** word</mark>")
        XCTAssertEqual(String(text.characters), "a bold word")
        XCTAssertEqual(run(text, "bold")?.inlinePresentationIntent?.contains(.stronglyEmphasized), true)
        XCTAssertNotNil(run(text, "bold")?[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self])
    }

    func testASpanIsColoredOnlyWithASafeColor() {
        let text = drawn(#"Build is <span style="color:#e5484d; font-size: 90px">failing</span>, <font color="green">ok</font>."#)
        XCTAssertEqual(String(text.characters), "Build is failing, ok.")
        XCTAssertNotNil(run(text, "failing")?[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self])
        XCTAssertNotNil(run(text, "ok")?[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self])
        let unsafe = ReplyHTML.marking(#"<span style="color:url(x)">x</span>"#)
        XCTAssertEqual(unsafe?.text, "x", "a span with no color it may use draws its words plain")
        XCTAssertEqual(unsafe?.styles.isEmpty, true)
        XCTAssertEqual(ReplyHTML.safeColor(" Red "), "red")
        XCTAssertEqual(ReplyHTML.safeColor("#E5484D"), "#e5484d")
        XCTAssertEqual(ReplyHTML.safeColor("rgb(10, 20, 30)"), "rgb(10, 20, 30)")
        XCTAssertNil(ReplyHTML.safeColor("expression(alert(1))"))
        XCTAssertNil(ReplyHTML.safeColor("var(--x)"))
        XCTAssertNil(ReplyHTML.safeColor("hsl(10, 20%, 30%)"))
    }

    func testASpanWithNoColorStillPairsWithItsOwnClosingTag() {
        let text = drawn(#"<span style="color:red">a <span class="note">b</span> c</span>"#)
        XCTAssertEqual(String(text.characters), "a b c")
        XCTAssertNotNil(run(text, " c")?[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self], "the outer span's color reaches past the inner one")
    }

    func testTextHoldingAMarksCharacterIsDrawnAsWritten() {
        XCTAssertNil(ReplyHTML.marking("\u{F8FF} <b>x</b>"))
        XCTAssertNil(ReplyHTML.marking("\u{E000} <b>x</b>"))
    }

    func testABreakIsANewLine() {
        XCTAssertEqual(String(drawn("One<br>Two<br/>Three").characters), "One\nTwo\nThree")
    }

    func testAnyOtherTagOrOneNotClosedStaysText() {
        // Nothing for the chat to draw: the text goes to Foundation as written.
        XCTAssertNil(ReplyHTML.marking("Use a <video> tag"))
        XCTAssertNil(ReplyHTML.marking("An <b>unclosed tag"))
        XCTAssertNil(ReplyHTML.marking("Vec<String> and 1 < 2"))
        XCTAssertEqual(ReplyHTML.marking("</b> closes nothing <span class=\"x\">here</span>")?.text, "</b> closes nothing here", "a stray closing tag stays")
    }

    func testATagInACodeSpanIsWhatItShows() {
        XCTAssertEqual(String(drawn("`<b>x</b>` and <b>y</b>").characters), "<b>x</b> and y")
    }

    func testTheBridgeDrawsHighlightsUnderlinesAndSmallerRaisedText() {
        let bridged = SelectableTextView.bridge(
            drawn("<mark>a</mark> <u>b</u> x<sup>2</sup>"),
            defaultFont: .systemFont(ofSize: 17),
            defaultColor: .label,
            linkColor: .link
        )
        let string = bridged.string as NSString
        XCTAssertNotNil(bridged.attribute(.backgroundColor, at: string.range(of: "a").location, effectiveRange: nil))
        XCTAssertNotNil(bridged.attribute(.underlineStyle, at: string.range(of: "b").location, effectiveRange: nil))
        let raised = string.range(of: "2").location
        XCTAssertNotNil(bridged.attribute(.baselineOffset, at: raised, effectiveRange: nil))
        XCTAssertEqual((bridged.attribute(.font, at: raised, effectiveRange: nil) as? UIFont)?.pointSize ?? 0, 17 * 0.75, accuracy: 0.01)
    }

    func testReadersTakeOffOnlyTheTagsTheChatDraws() {
        XCTAssertEqual(ReplyHTML.withoutTags("a <b>b</b><br/>c"), "a b c")
        XCTAssertEqual(ReplyHTML.withoutTags("a <video> tag, Vec<String>, <me@example.com>"), "a <video> tag, Vec<String>, <me@example.com>")
        XCTAssertEqual(ReplyHTML.withoutTags("if a <b and y > z"), "if a <b and y > z")
        XCTAssertEqual(ReplyHTML.withoutTags("`<b>x</b>`"), "`<b>x</b>`")
        XCTAssertEqual(ReplyHTML.withoutTags("```\n<b>x</b>\n```"), "```\n<b>x</b>\n```")
    }

    func testTheExchangeSaysThisConduitDrawsReplyHTML() {
        XCTAssertTrue(PresentedScreensSync.features.contains("reply-html"))
    }
}
