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
        layout.setRows(ids.map { TranscriptRow(id: $0, kind: .empty) })
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

        layout.reserveContentHeight(0)
        view.layoutIfNeeded()
        XCTAssertEqual(view.contentSize.height, rowsBottom)
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
}
