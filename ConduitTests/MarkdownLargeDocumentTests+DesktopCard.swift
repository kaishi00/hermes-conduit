import XCTest
@testable import Conduit

/// A Hermes Desktop plugin's directive (`::richui{id="…"}`, #1522): Conduit
/// shows a card in its place, never the raw line, and names it wherever a
/// reply is read rather than drawn.
///
/// An extension rather than its own class, for the same CI planner reason
/// as the media preview tests.
extension MarkdownLargeDocumentTests {

    private static let richUILine = #"::richui{id="ru-c91286278685"}"#

    // MARK: - Directive grammar

    func testDesktopCard_RichUIDirectiveIsACard() {
        let segments = TranscriptDirectives.segments(in: Self.richUILine)
        guard case .desktopCard(let card)? = segments?.first, segments?.count == 1 else {
            return XCTFail("\(String(describing: segments))")
        }
        XCTAssertEqual(card.plugin, "hermes-rich-ui")
        XCTAssertEqual(card.richUICardID, "ru-c91286278685")
        XCTAssertEqual(card.source, Self.richUILine)
    }

    func testDesktopCard_AnyPluginsDirectiveIsACard() {
        let segments = TranscriptDirectives.segments(in: #"Here: ::widget{name='x' size="2"} done"#)
        XCTAssertEqual(segments?.count, 3)
        guard case .desktopCard(let card)? = segments?[1] else { return XCTFail("\(String(describing: segments))") }
        XCTAssertEqual(card.plugin, "widget")
        XCTAssertNil(card.richUICardID)
    }

    func testDesktopCard_ProseAndCodeStayText() {
        XCTAssertNil(TranscriptDirectives.segments(in: "::selection{color:red}"))
        XCTAssertNil(TranscriptDirectives.segments(in: "::richui{}"))
        XCTAssertNil(TranscriptDirectives.segments(in: #"std::richui{id="ru-c91286278685"}"#))
        XCTAssertNil(TranscriptDirectives.segments(in: #"`::richui{id="ru-c91286278685"}`"#))
        XCTAssertNil(TranscriptDirectives.segments(in: "Use Foo::bar to call it."))
        XCTAssertNil(TranscriptDirectives.segments(in: #"Run `echo ::richui{id="ru-c91286278685"}` here"#))
    }

    func testDesktopCard_MalformedRichUIIDIsNotRead() {
        guard case .desktopCard(let card)? = TranscriptDirectives.segments(in: #"::richui{id="../../etc"}"#)?.first else {
            return XCTFail("not a card")
        }
        XCTAssertNil(card.richUICardID)
    }

    // MARK: - Parsing

    func testDesktopCard_ParsesIntoACardOnEverySurface() {
        let source = "Here are the numbers:\n\(Self.richUILine)\nAnything else?"
        for recognizesGatewayMedia in [true, false] {
            let blocks = MarkdownParser.parse(source, recognizesGatewayMedia: recognizesGatewayMedia)
            XCTAssertEqual(blocks.count, 3, "\(blocks)")
            XCTAssertEqual(blocks.first, .paragraph("Here are the numbers:"))
            guard case .desktopCard(let card) = blocks[1] else { return XCTFail("\(blocks)") }
            XCTAssertEqual(card.richUICardID, "ru-c91286278685")
            XCTAssertEqual(blocks.last, .paragraph("Anything else?"))
        }
    }

    func testDesktopCard_QuotedDirectiveIsAnExample() {
        let blocks = MarkdownParser.parse("> Example: \(Self.richUILine)", recognizesGatewayMedia: true)
        XCTAssertFalse(blocks.contains { if case .desktopCard = $0 { return true } else { return false } }, "\(blocks)")
    }

    func testDesktopCard_PreviewStaysTextWithoutGatewayBesideACard() {
        let blocks = MarkdownParser.parse(#"::preview{file="/tmp/a.html"} \#(Self.richUILine)"#)
        XCTAssertEqual(blocks.first, .paragraph(#"::preview{file="/tmp/a.html"}"#))
        XCTAssertFalse(blocks.contains { if case .htmlPreview = $0 { return true } else { return false } }, "\(blocks)")
    }

    // MARK: - The card's read

    /// What a read answered and how often it was asked.
    private final class CardReads {
        var answer: [String: Any]?
        var count = 0
        var now = Date(timeIntervalSince1970: 1_000)
    }

    @MainActor
    func testDesktopCard_AReadIsKeptAndAFailedOneAskedAgainLater() async {
        let key = UUID().uuidString
        let reads = CardReads()
        func read() async -> DesktopCardContent? {
            await DesktopCardContents.content(key: key, path: "/cards/x", now: { reads.now }) { _ in
                reads.count += 1
                return reads.answer
            }
        }
        // Not there: kept as missing, not asked again inside the interval.
        let missing = await read()
        XCTAssertNil(missing)
        let soon = await read()
        XCTAssertNil(soon)
        XCTAssertEqual(reads.count, 1)
        XCTAssertNil(DesktopCardContents.cached(key: key))
        // Asked again once the interval has passed, and kept for the launch.
        reads.answer = ["ok": true, "card": ["surface": ["createSurface": ["dataModel": ["meta": ["title": " Rents ", "summary": "Up 4%."]]]]]]
        reads.now += DesktopCardContents.retryInterval
        let found = await read()
        XCTAssertEqual(found, DesktopCardContent(title: "Rents", summary: "Up 4%."))
        reads.answer = nil
        let again = await read()
        XCTAssertEqual(again, found)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(DesktopCardContents.cached(key: key)?.title, "Rents")
    }

    @MainActor
    func testDesktopCard_ACardWithNothingToShowIsMissing() async {
        let key = UUID().uuidString
        let empty = await DesktopCardContents.content(key: key, path: "/cards/x") { _ in
            ["ok": true, "card": ["surface": ["createSurface": ["dataModel": ["meta": ["title": "  "]]]]]]
        }
        XCTAssertNil(empty)
        XCTAssertNil(DesktopCardContents.cached(key: key))
    }

    // MARK: - Read, named and previewed

    func testDesktopCard_ReadAloudSaysACardIsThere() {
        let text = "Numbers below.\n\(Self.richUILine)\nDone."
        XCTAssertEqual(TranscriptDirectives.readable(from: text), "Numbers below.\n\(DesktopCardDirective.spokenNote)\nDone.")
        XCTAssertFalse(VoiceReadBack.plainSpeech(text).contains("::richui"))
        // A file tag inside the directive doesn't break it up before it's read.
        let tagged = "Here:\n::widget{file=\"MEDIA:/tmp/a.png\"}"
        XCTAssertTrue(VoiceReadBack.plainSpeech(tagged).contains(DesktopCardDirective.spokenNote))
    }

    func testDesktopCard_VoiceModelsHearItNamed() {
        let named = GatewayMediaTags.namingFiles(in: "Numbers:\n\(Self.richUILine)\n::preview{file=\"/tmp/chart.html\"}")
        XCTAssertEqual(named, "Numbers:\n(a card in the chat made for Hermes Desktop, from hermes-rich-ui)\n(a file in the chat: chart.html)")
    }

    func testDesktopCard_ChatPreviewNamesTheCard() {
        XCTAssertEqual(PreviewText.plain("Done. \(Self.richUILine)"), "Done. \(DesktopCardDirective.previewNote)")
    }

    func testDesktopCard_QuoteChipNamesTheCard() {
        XCTAssertEqual(ChatQuote.excerpt(of: "Rents:\n\(Self.richUILine)"), "Rents: \(DesktopCardDirective.previewNote)")
    }

    func testDesktopCard_FencedCodeStaysAsWritten() {
        let text = "Example:\n```\n\(Self.richUILine)\n```\n\(Self.richUILine)"
        XCTAssertEqual(
            TranscriptDirectives.rewriting(text, preview: { _ in nil }, card: { _ in "CARD" }),
            "Example:\n```\n\(Self.richUILine)\n```\nCARD"
        )
    }

    func testDesktopCard_ListMarkerLeftBehindDrops() {
        let blocks = MarkdownParser.parse("- \(Self.richUILine)")
        XCTAssertEqual(blocks.count, 1, "\(blocks)")
        guard case .desktopCard = blocks.first else { return XCTFail("\(blocks)") }
    }

    func testDesktopCard_ALaterListItemIsACardToo() {
        for marker in ["-", "2."] {
            let blocks = MarkdownParser.parse("\(marker == "-" ? "-" : "1.") Here are the results:\n\(marker) \(Self.richUILine)\n\(marker == "-" ? "-" : "3.") Done")
            XCTAssertEqual(blocks.count, 3, "\(blocks)")
            guard case .desktopCard = blocks[1] else { return XCTFail("\(blocks)") }
        }
    }

    // MARK: - The card's text

    func testDesktopCard_ReadsTitleAndSummaryFromTheRecord() {
        let json: [String: Any] = [
            "ok": true,
            "card": [
                "envelope": ["card_id": "ru-c91286278685"],
                "surface": [
                    "version": "v1.0",
                    "createSurface": [
                        "components": [["id": "root", "component": "Card", "title": "Root title"]],
                        "dataModel": ["data": [:], "meta": ["title": " Rent comps ", "summary": "Median rent is $2,100 across 12 listings."]]
                    ]
                ]
            ]
        ]
        XCTAssertEqual(DesktopCardContent(richUIResponse: json), DesktopCardContent(title: "Rent comps", summary: "Median rent is $2,100 across 12 listings."))
    }

    func testDesktopCard_RootTitleWhenMetaHasNone() {
        let json: [String: Any] = [
            "ok": true,
            "card": ["surface": ["createSurface": [
                "components": [["id": "root", "component": "Card", "title": "Root title"]],
                "dataModel": ["meta": ["title": "  "]]
            ]]]
        ]
        XCTAssertEqual(DesktopCardContent(richUIResponse: json), DesktopCardContent(title: "Root title", summary: ""))
    }

    func testDesktopCard_NotFoundIsNoContent() {
        XCTAssertNil(DesktopCardContent(richUIResponse: ["ok": false, "error": "not found"]))
        XCTAssertNil(DesktopCardContent(richUIResponse: ["ok": true, "card": ["surface": ["createSurface": ["dataModel": ["meta": [:]]]]]]))
    }
}
