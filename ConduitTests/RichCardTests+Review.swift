//
//  RichCardTests+Review.swift
//  ConduitTests
//
//  Review cards (Cards Hermes shows in docs/FEATURE_MAP.md): options to
//  look at and mark, as the views read them, the marks' tap and message,
//  a round read from the host, and live models not offered them. An
//  extension of an existing class, so the test planner needs no new entry.
//

import XCTest
@testable import Conduit

@MainActor
private final class AskedReviewPaths {
    var paths: [String] = []
}

extension AppStateVoiceCapabilityTests {
    private static let reviewCard: [String: Any] = [
        "type": "review", "title": "Recipe app home",
        "review": [
            "id": "rv-0123456789abcdef", "round": 2, "for": "W3",
            "decisions": [
                ["id": "d1", "title": "Home layout", "layout": "switch", "options": [
                    ["id": "A", "label": "Cards", "kind": "page", "recommended": true],
                    ["id": "B", "label": "List", "kind": "page", "text": "Denser"],
                    ["id": "C", "label": "Photo", "kind": "image", "url": "https://img.test/c.png"],
                ]] as [String: Any],
                ["id": "d2", "title": "Save button colour", "options": [
                    ["id": "A", "label": "Amber", "kind": "page"],
                    ["id": "B", "label": "Green", "kind": "page"],
                ]] as [String: Any],
            ],
            "settled": [["title": "Icons", "mark": "approve", "choice": "Outline", "round": 1]],
        ] as [String: Any],
    ]

    private func reviewCard(_ json: [String: Any] = AppStateVoiceCapabilityTests.reviewCard) throws -> RichCard {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        return try XCTUnwrap(RichCard.cards(raw: [json], schema: schema).first)
    }

    func testAReviewCardReadsItsDecisionsOptionsAndWorkstream() throws {
        let card = try reviewCard()
        XCTAssertEqual(card.kind, .review)
        let review = try XCTUnwrap(card.review)
        XCTAssertEqual(review.id, "rv-0123456789abcdef")
        XCTAssertEqual(review.round, 2)
        XCTAssertEqual(review.forRef, "W3")
        XCTAssertFalse(review.isQuickPick)
        XCTAssertEqual(review.decisions[0].layout, .switch)
        XCTAssertEqual(review.decisions[1].layout, .side, "side is the default")
        XCTAssertEqual(review.decisions[0].options.map(\.name), ["A · Cards", "B · List", "C · Photo"])
        XCTAssertEqual(review.decisions[0].options[2].url?.absoluteString, "https://img.test/c.png")
        XCTAssertNil(review.decisions[0].options[0].url, "a page opens from the host")
        XCTAssertEqual(review.settled, [RichReviewSettled(json: ["title": "Icons", "mark": "approve", "choice": "Outline"])!])
    }

    func testAReviewWithoutTheHostsIdIsNotDrawn() throws {
        var json = Self.reviewCard
        var review = try XCTUnwrap(json["review"] as? [String: Any])
        review["id"] = "review-1"
        json["review"] = review
        XCTAssertTrue(RichCard.cards(raw: [json]).isEmpty)
    }

    func testTheMarksTapCarriesTheRoundAndTheMessageNamesThePick() throws {
        let card = try reviewCard()
        let review = try XCTUnwrap(card.review)
        let marks: [String: RichReviewMark] = [
            "d1": RichReviewMark(kind: .change, option: "B", note: "  More photos "),
            "d2": RichReviewMark(kind: .approve, option: nil),
        ]
        let body = RichReviewTap.body(card: card, review: review, marks: marks, note: "Warmer", label: "Sent review")
        XCTAssertEqual(body["action"] as? String, "review")
        let given = try XCTUnwrap(body["review"] as? [String: Any])
        XCTAssertEqual(given["round"] as? Int, 2)
        XCTAssertEqual(given["note"] as? String, "Warmer")
        XCTAssertEqual(given["label"] as? String, "Sent review")
        let sent = try XCTUnwrap(given["marks"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 1, "an approval with no option isn't sent")
        XCTAssertEqual(sent[0]["decision"] as? String, "d1")
        XCTAssertEqual(sent[0]["note"] as? String, "More photos")
        XCTAssertEqual(RichReviewTap.message(label: "Sent review", review: review, marks: marks, title: card.title),
                       "Sent review · Recipe app home")

        let pick = try reviewCard([
            "type": "review", "title": "Chart",
            "review": ["id": "rv-0123456789abcdef", "round": 1, "decisions": [
                ["id": "d1", "title": "Chart", "options": [["id": "A", "label": "Bars", "kind": "page"],
                                                           ["id": "B", "label": "Line", "kind": "page"]]] as [String: Any],
            ]] as [String: Any],
        ])
        let quick = try XCTUnwrap(pick.review)
        XCTAssertTrue(quick.isQuickPick)
        XCTAssertEqual(RichReviewTap.message(label: "Picked", review: quick,
                                             marks: ["d1": RichReviewMark(kind: .approve, option: "B")], title: "Chart"),
                       "Picked B · Line")
    }

    func testARoundIsReadFromTheHostOnceWithItsPagesAndMarks() async throws {
        let id = "rv-0123456789abcdef"
        let loader = RichReviewLoader.shared
        let asked = AskedReviewPaths()
        loader.read = { path in
            asked.paths.append(path)
            return ["review": ["id": id, "round": 1, "rounds": 2, "title": "T", "pages": ["d1/A": "<p>A</p>"],
                               "decisions": [["id": "d1", "title": "Chart", "options": [
                                   ["id": "A", "label": "Bars", "kind": "page"], ["id": "B", "label": "Line", "kind": "page"],
                               ]]],
                               "marks": ["decisions": [["decision": "d1", "mark": "approve", "option": "A"]], "at": 1.0]]]
        }
        defer {
            loader.read = nil
            loader.forget(id, 1)
        }
        let round = try await loader.round(id, 1)
        XCTAssertEqual(round.page(decision: "d1", option: "A"), "<p>A</p>")
        XCTAssertEqual(round.marks["d1"], RichReviewMark(kind: .approve, option: "A"))
        XCTAssertTrue(round.wasSent)
        XCTAssertEqual(round.decisions.map(\.id), ["d1"])
        _ = try await loader.round(id, 1)
        XCTAssertEqual(asked.paths, ["/api/plugins/conduit_push/boards/reviews?id=\(id)&round=1"], "read once")
        XCTAssertNotNil(loader.kept(id, 1))
        loader.forget(id, 1)
        XCTAssertNil(loader.kept(id, 1), "a forgotten round isn't kept")
        _ = try await loader.round(id, 1)
        XCTAssertEqual(asked.paths.count, 2, "a forgotten round is read again")
        _ = try await loader.round(id, 1, fresh: true)
        XCTAssertEqual(asked.paths.count, 3, "fresh asks again")
        // Issue 2149: a card's row drawn again within its window takes the
        // round it just read; past it, it asks again.
        _ = try await loader.round(id, 1, fresh: true, freshFor: RichReviewLoader.rowFreshFor,
                                   now: Date().addingTimeInterval(5))
        XCTAssertEqual(asked.paths.count, 3, "a row scrolled back within its window reads nothing")
        _ = try await loader.round(id, 1, fresh: true, freshFor: RichReviewLoader.rowFreshFor,
                                   now: Date().addingTimeInterval(RichReviewLoader.rowFreshFor + 1))
        XCTAssertEqual(asked.paths.count, 4, "past it, the row asks again")
        do {
            _ = try await loader.round("../etc", 1)
            XCTFail("only a kept review's id is read")
        } catch {}
    }

    /// Issue 2062: a round is host content, checked as the card is and
    /// bounded as every page Conduit previews.
    func testARoundIsCheckedAsTheCardIsAndItsPagesBounded() throws {
        let id = "rv-0123456789abcdef"
        let options: [[String: Any]] = (0..<9).map { ["id": "o\($0)", "label": String(repeating: "L", count: 200), "kind": "page"] }
        let decisions: [[String: Any]] = (0..<9).map { ["id": "d\($0)", "title": "Decision \($0)", "options": options] }
        let huge = String(repeating: "x", count: HTMLPreviewPage.maximumDocumentBytes + 1)
        let fits = String(repeating: "y", count: 1_000)
        let long = String(repeating: "n", count: RichReviewMark.maxNote + 50)
        let round = try XCTUnwrap(RichReviewLoader.checkedRound([
            "round": 1, "rounds": 1, "decisions": decisions,
            "pages": ["d0/o0": huge, "d0/o1": fits],
            "marks": ["decisions": [["decision": "d0", "mark": "change", "option": "o1", "note": long]], "note": long],
        ] as [String: Any], id: id))
        XCTAssertEqual(round.decisions.count, 6, "the schema's six decisions")
        XCTAssertEqual(round.decisions.first?.options.count, 6, "and six options each")
        XCTAssertEqual(round.decisions.first?.options.first?.label.count, 60, "labels at the schema's length")
        XCTAssertNil(round.page(decision: "d0", option: "o0"), "a page over the preview's ceiling isn't drawn")
        XCTAssertEqual(round.page(decision: "d0", option: "o1"), fits)
        XCTAssertEqual(round.pageBytes, fits.utf8.count)
        XCTAssertEqual(round.marks["d0"]?.note.unicodeScalars.count, RichReviewMark.maxNote)
        XCTAssertEqual(round.note?.unicodeScalars.count, RichReviewMark.maxNote)
        let invalid = try XCTUnwrap(RichReviewLoader.checkedRound(
            ["round": 1, "rounds": 1, "decisions": [["id": "d1", "title": "One option", "options": [options[0]]]]] as [String: Any],
            id: id))
        XCTAssertTrue(invalid.decisions.isEmpty, "a decision the card wouldn't take isn't drawn")
        XCTAssertNil(RichReviewLoader.checkedRound(["pages": [String: String]()] as [String: Any], id: id))
    }

    func testANoteIsCappedInUnicodeScalarsAsTheHostCounts() throws {
        let max = RichReviewMark.maxNote
        let below = String(repeating: "a", count: max - 1)
        XCTAssertEqual(RichReviewMark.capped(below), below)
        let at = String(repeating: "a", count: max)
        XCTAssertEqual(RichReviewMark.capped(at), at)
        XCTAssertEqual(RichReviewMark.capped(at + "b").unicodeScalars.count, max)
        // A flag is one Character but two scalars: the cap counts scalars.
        let flags = String(repeating: "\u{1F1EF}\u{1F1F5}", count: max / 2 + 5)
        XCTAssertEqual(RichReviewMark.capped(flags).unicodeScalars.count, max)
        let mark = RichReviewMark(kind: .change, option: "A", note: flags)
        XCTAssertEqual((mark.json["note"] as? String)?.unicodeScalars.count, max)
        let card = try reviewCard()
        let body = RichReviewTap.body(card: card, review: try XCTUnwrap(card.review), marks: ["d1": mark], note: flags,
                                      label: "Sent review")
        let given = try XCTUnwrap(body["review"] as? [String: Any])
        XCTAssertEqual((given["note"] as? String)?.unicodeScalars.count, max, "the round's note too")
    }

    func testLiveModelsAreNotOfferedReviews() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(schema.liveToolParameter(description: "Cards.")["items"] as? [String: Any])
        let properties = try XCTUnwrap(card["properties"] as? [String: Any])
        XCTAssertNil(properties["review"])
        let kinds = try XCTUnwrap((properties["type"] as? [String: Any])?["enum"] as? [String])
        XCTAssertFalse(kinds.contains("review"))
    }
}
