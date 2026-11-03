import UIKit
import XCTest
@testable import Conduit

/// TranscriptLayout (#1533, the transcript rewrite): one column of rows
/// with the lazy stack's spacing, each as tall as it measured, a row
/// changing height moving the rows under it in the same pass, and the
/// heights kept for the conversation and width they were measured at.
@MainActor
final class TranscriptLayoutTests: XCTestCase {
    /// A cell that keeps the height the layout gives it: the heights here
    /// come from the tests, as a row's own measurement would.
    private final class Cell: UICollectionViewCell {
        override func preferredLayoutAttributesFitting(
            _ layoutAttributes: UICollectionViewLayoutAttributes
        ) -> UICollectionViewLayoutAttributes {
            layoutAttributes
        }
    }

    private final class Rows: NSObject, UICollectionViewDataSource {
        var count = 0

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
        }
    }

    private static let width: CGFloat = 390
    private var view: UICollectionView!
    private var layout: TranscriptLayout!
    /// The collection view holds its data source weakly.
    private var rows: Rows!

    override func setUp() async throws {
        try await super.setUp()
        layout = TranscriptLayout()
        view = UICollectionView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 800), collectionViewLayout: layout)
        view.register(Cell.self, forCellWithReuseIdentifier: "row")
        rows = Rows()
        view.dataSource = rows
        // Its own conversation: the heights measured are kept per scope.
        layout.setScope(UUID().uuidString)
    }

    override func tearDown() async throws {
        view = nil
        layout = nil
        rows = nil
        try await super.tearDown()
    }

    private func show(_ ids: [String]) {
        layout.setRows(ids.map { TranscriptRow(id: $0, kind: .empty) }, changed: [])
        rows.count = ids.count
        view.reloadData()
        view.layoutIfNeeded()
    }

    /// Each row as tall as `heights` says, its gap included, as a cell's
    /// measurement reports it.
    private func measure(_ heights: [String: CGFloat]) {
        for (id, height) in heights {
            layout.rowResized(id, to: CGSize(width: layout.itemWidth, height: height))
        }
        view.layoutIfNeeded()
    }

    /// An assistant's reply saying `text`, as the chat's rows draw it.
    private func reply(_ id: String, _ text: String) -> TranscriptRow {
        var cache = ChatMessageScrollTargetCache()
        cache.update(for: [ChatMessage(id: id, role: .assistant, content: text, timestamp: "2026-10-31T09:00:00Z")])
        return TranscriptRow(id: id, kind: .message(cache.targets[0]))
    }

    /// A row's item: its frame and the gap above it.
    private func itemHeight(_ id: String) throws -> CGFloat {
        let frame = try XCTUnwrap(layout.rowFrame(id))
        return frame.maxY - frame.minY + TranscriptLayout.rowGap
    }

    func testRowsStackDownOneColumnWithTheStacksSpacing() throws {
        show(["a", "b"])
        measure(["a": 100, "b": 60])

        let a = try XCTUnwrap(layout.rowFrame("a"))
        let b = try XCTUnwrap(layout.rowFrame("b"))
        XCTAssertEqual(a.minY, TranscriptLayout.topPadding + TranscriptLayout.rowGap)
        XCTAssertEqual(a.maxY, TranscriptLayout.topPadding + 100)
        XCTAssertEqual(b.minY, a.maxY + TranscriptLayout.rowGap)
        XCTAssertEqual(b.maxY, a.maxY + 60)
        XCTAssertEqual(view.contentSize.height, b.maxY + TranscriptLayout.bottomPadding)
        let cell = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        XCTAssertEqual(
            cell.frame,
            CGRect(x: TranscriptLayout.sideMargin, y: a.maxY, width: Self.width - 2 * TranscriptLayout.sideMargin, height: 60),
            "The cell spans its row and the gap above it, inside the margins"
        )
    }

    func testARowChangingHeightMovesTheRowsUnderItInTheSamePass() throws {
        show(["a", "b", "c"])
        measure(["a": 100, "b": 100, "c": 100])
        let aBottom = try XCTUnwrap(layout.rowFrame("a")).maxY
        let cTop = try XCTUnwrap(layout.rowFrame("c")).minY
        let generation = layout.generation

        measure(["b": 250])

        XCTAssertEqual(layout.rowFrame("a")?.maxY, aBottom, "A row above stays")
        XCTAssertEqual(layout.rowFrame("c")?.minY, cTop + 150)
        XCTAssertGreaterThan(layout.generation, generation, "The scroller hears of the pass")
    }

    /// Eric's report (build 246): an opened Thinking row drew over the rows
    /// under it, and a closed one left its old height empty. The layout had
    /// the new frames, but the context named only the row that resized, and
    /// UIKit asks again only for the items a context names: the cells under
    /// it kept their old frames until a scroll or another visit.
    func testTheCellsUnderARowThatResizedMoveWithIt() throws {
        show(["a", "b", "c", "d"])
        measure(["a": 100, "b": 100, "c": 100, "d": 100])
        let cTop = try XCTUnwrap(view.cellForItem(at: IndexPath(item: 2, section: 0))).frame.minY
        let dTop = try XCTUnwrap(view.cellForItem(at: IndexPath(item: 3, section: 0))).frame.minY

        measure(["b": 250])
        XCTAssertEqual(try XCTUnwrap(view.cellForItem(at: IndexPath(item: 1, section: 0))).frame.height, 250)
        XCTAssertEqual(try XCTUnwrap(view.cellForItem(at: IndexPath(item: 2, section: 0))).frame.minY, cTop + 150, "opened")
        XCTAssertEqual(try XCTUnwrap(view.cellForItem(at: IndexPath(item: 3, section: 0))).frame.minY, dTop + 150, "every row under it")

        measure(["b": 100])
        XCTAssertEqual(try XCTUnwrap(view.cellForItem(at: IndexPath(item: 2, section: 0))).frame.minY, cTop, "closed")
        XCTAssertEqual(try XCTUnwrap(view.cellForItem(at: IndexPath(item: 3, section: 0))).frame.minY, dTop)

        // A cell's own measurement names the rows under it too.
        let original = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        let preferred = try XCTUnwrap(original.copy() as? UICollectionViewLayoutAttributes)
        preferred.size.height = 180
        XCTAssertTrue(layout.shouldInvalidateLayout(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original))
        let context = layout.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        XCTAssertEqual(Set(context.invalidatedItemIndexPaths ?? []).intersection([IndexPath(item: 2, section: 0), IndexPath(item: 3, section: 0)]).count, 2)
    }

    func testAHeightMeasuredAtAnotherWidthIsNotTaken() throws {
        show(["a"])
        measure(["a": 100])

        layout.rowResized("a", to: CGSize(width: layout.itemWidth + 40, height: 300))
        view.layoutIfNeeded()

        XCTAssertEqual(try itemHeight("a"), 100)

        // Nor from a cell measured with its last width's attributes, as
        // around a rotation; one at the width it was given is taken.
        let original = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let preferred = try XCTUnwrap(original.copy() as? UICollectionViewLayoutAttributes)
        preferred.size = CGSize(width: original.size.width + 40, height: 300)
        XCTAssertFalse(layout.shouldInvalidateLayout(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original))
        view.layoutIfNeeded()
        XCTAssertEqual(try itemHeight("a"), 100)
        preferred.size = CGSize(width: original.size.width, height: 300)
        XCTAssertTrue(layout.shouldInvalidateLayout(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original))
    }

    func testRowsAddedAboveKeepTheHeightsOfTheRowsBelow() throws {
        show(["a", "b"])
        measure(["a": 100, "b": 140])
        let estimate = TranscriptLayout.estimatedHeight(of: TranscriptRow(id: "e", kind: .empty), width: layout.itemWidth)

        show(["e", "a", "b"])

        XCTAssertEqual(try itemHeight("e"), estimate, "A row never measured starts at its estimate")
        XCTAssertEqual(try itemHeight("a"), 100)
        XCTAssertEqual(try itemHeight("b"), 140)
        XCTAssertEqual(layout.rowFrame("a")?.minY, TranscriptLayout.topPadding + estimate + TranscriptLayout.rowGap)
    }

    func testAConversationOpenedAgainLaysOutAtTheHeightsItMeasured() throws {
        let scope = UUID().uuidString
        layout.setScope(scope)
        show(["a"])
        measure(["a": 120])
        let estimate = TranscriptLayout.estimatedHeight(of: TranscriptRow(id: "a", kind: .empty), width: layout.itemWidth)

        layout.setScope(UUID().uuidString)
        view.layoutIfNeeded()
        XCTAssertEqual(try itemHeight("a"), estimate, "Another conversation's row of the same id")

        layout.setScope(scope)
        view.layoutIfNeeded()
        XCTAssertEqual(try itemHeight("a"), 120)
    }

    func testTheRoomUnderASentMessageIsTheLeastContentHeight() throws {
        show(["a"])
        measure(["a": 100])
        let rowsBottom = try XCTUnwrap(layout.rowFrame("a")).maxY + TranscriptLayout.bottomPadding

        layout.reserveContentHeight(5_000)
        view.layoutIfNeeded()
        XCTAssertEqual(view.contentSize.height, 5_000)
        XCTAssertEqual(layout.appliedReserve, 5_000)

        XCTAssertEqual(layout.rowsHeight, rowsBottom, "The rows' own height leaves the room out")

        layout.reserveContentHeight(0)
        view.layoutIfNeeded()
        XCTAssertEqual(view.contentSize.height, rowsBottom)
        XCTAssertEqual(layout.rowsHeight, rowsBottom)
    }

    /// A pass for some rows never asks for the content size again: the
    /// content follows a row growing after it was measured (a reply
    /// streaming in) from the change its context carries, and stays the
    /// room held under a sent message until the rows pass it.
    func testTheContentFollowsARowGrowingAfterItWasMeasured() throws {
        let padding = TranscriptLayout.topPadding + TranscriptLayout.bottomPadding
        show(["a"])
        measure(["a": 100])
        XCTAssertEqual(view.contentSize.height, 100 + padding)

        measure(["a": 400])
        XCTAssertEqual(view.contentSize.height, 400 + padding)

        layout.reserveContentHeight(1_000)
        view.layoutIfNeeded()
        measure(["a": 600])
        XCTAssertEqual(view.contentSize.height, 1_000, "Under the room held for the reply")
        measure(["a": 1_200])
        XCTAssertEqual(view.contentSize.height, 1_200 + padding, "Past it")
    }

    func testTheRowsCrossingABandAreFoundTopFirst() throws {
        show(["a", "b", "c", "d"])
        measure(["a": 100, "b": 100, "c": 100, "d": 100])
        let b = try XCTUnwrap(layout.rowFrame("b"))
        let c = try XCTUnwrap(layout.rowFrame("c"))

        XCTAssertEqual(layout.rows(crossing: (b.minY + 1)...(c.minY + 1)).map(\.id), ["b", "c"])
        XCTAssertEqual(layout.rows(crossing: (b.maxY + 1)...(c.minY - 1)).map(\.id), [], "The gap between rows is no row's")
    }

    func testTheSafeAreaBesideTheTranscriptNarrowsTheColumn() throws {
        show(["a"])

        layout.setSideInsets(leading: 44, trailing: 0)
        view.layoutIfNeeded()

        XCTAssertEqual(layout.itemWidth, Self.width - 44 - 2 * TranscriptLayout.sideMargin)
        let cell = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(cell.frame.minX, 44 + TranscriptLayout.sideMargin)
    }

    /// A row that measures lays out every row under it again, so a long
    /// chat's rows not measured yet keep the guess made for them: one per
    /// row, width and scope, not one per pass.
    func testEachRowIsGuessedOncePerWidth() throws {
        let ids = (0..<200).map { "row-\($0)" }
        TranscriptPerf.reset()
        show(ids)
        XCTAssertEqual(TranscriptPerf.rowHeightEstimates, ids.count)

        measure(["row-0": 100])
        measure(["row-1": 150])
        measure(["row-2": 60])
        XCTAssertEqual(TranscriptPerf.rowHeightEstimates, ids.count, "The rows under a measurement aren't guessed again")

        // Another width guesses them again, each once.
        layout.setSideInsets(leading: 44, trailing: 0)
        view.layoutIfNeeded()
        XCTAssertEqual(TranscriptPerf.rowHeightEstimates, 2 * ids.count)
    }

    /// A row not measured yet that draws something else (an edit landing
    /// off screen) is guessed again from what it draws now, moving the
    /// rows under it in the snapshot's own pass.
    func testARowNotMeasuredIsGuessedAgainWhenItChanges() throws {
        // Rows above keep the reply off screen, where no cell measures it.
        let above = (0..<4).map { TranscriptRow(id: "e\($0)", kind: .empty) }
        let below = TranscriptRow(id: "b", kind: .empty)
        let short = reply("a", "Hi")
        layout.setRows(above + [short, below], changed: [])
        rows.count = above.count + 2
        view.reloadData()
        view.layoutIfNeeded()
        let shortGuess = TranscriptLayout.estimatedHeight(of: short, width: layout.itemWidth)
        XCTAssertEqual(try itemHeight("a"), shortGuess)
        let belowTop = try XCTUnwrap(layout.rowFrame("b")).minY

        let long = reply("a", String(repeating: "word ", count: 300))
        layout.setRows(above + [long, below], changed: ["a"])
        // The same rows by id: the pass lays none out again on its own.
        layout.invalidateLayout(with: UICollectionViewLayoutInvalidationContext())
        view.layoutIfNeeded()

        let longGuess = TranscriptLayout.estimatedHeight(of: long, width: layout.itemWidth)
        XCTAssertGreaterThan(longGuess, shortGuess)
        XCTAssertEqual(try itemHeight("a"), longGuess)
        XCTAssertEqual(layout.rowFrame("b")?.minY, belowTop + longGuess - shortGuess)
    }

    /// A guess counts characters, so text in a script of several bytes a
    /// character isn't guessed taller than as many in ASCII.
    func testAGuessCountsCharactersNotBytes() {
        let width: CGFloat = 300
        let ascii = TranscriptLayout.estimatedHeight(of: reply("a", String(repeating: "a", count: 400)), width: width)
        XCTAssertEqual(TranscriptLayout.estimatedHeight(of: reply("a", String(repeating: "字", count: 400)), width: width), ascii)
        XCTAssertEqual(TranscriptLayout.estimatedHeight(of: reply("a", String(repeating: "👋", count: 400)), width: width), ascii)
        XCTAssertGreaterThan(ascii, TranscriptLayout.estimatedHeight(of: reply("a", "a"), width: width))
    }

    /// A group room's rows are guessed from their text as a chat's are: a
    /// caption is a line, a member's message grows with its text beside
    /// its picture, and the message on its way is guessed as its event
    /// will be, so the event taking its row starts at the same height.
    func testARoomsRowsAreGuessedFromTheirText() {
        let width: CGFloat = 300
        func guess(_ row: GroupRoomRow) -> CGFloat {
            TranscriptLayout.estimatedHeight(of: TranscriptRow(id: "r", kind: .room(row)), width: width)
        }
        func event(_ kind: String, _ text: String?) -> GroupRoomRow {
            var payload: [String: AnyCodable] = [:]
            if let text { payload["text"] = .string(text) }
            let event = GroupEvent(
                roomID: "room-1", seq: 1, eventID: "e1", kind: kind,
                actor: GroupActor(kind: "member", id: "furina", profile: "furina", displayName: nil, connectionID: nil),
                authorityEpoch: nil, payload: payload, createdAt: 1
            )
            return .event(event, members: [], continuesRun: false)
        }
        XCTAssertEqual(guess(event("turn.failed", nil)), TranscriptLayout.rowGap + 24, "a caption is a line")
        let long = String(repeating: "A member's reply runs on for a while. ", count: 30)
        XCTAssertGreaterThan(guess(event("message.member", long)), guess(event("message.member", "Hi")))
        XCTAssertEqual(
            guess(.pending(text: long, members: [], isSending: true)),
            guess(event("message.user", long)),
            "the message on its way is guessed as its event"
        )
    }
}
