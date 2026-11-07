import XCTest
@testable import Conduit

/// Two or more pictures in one message draw as a grid of square tiles
/// (issue 1801), in a sent message's attachments and a reply's pictures
/// alike. An extension, so the test plan gains no class.
extension ChatTypographyTests {
    func testPictureGridPutsTwoToARowOnAPhone() {
        let plan = PictureGrid.plan(count: 3, width: 290)

        XCTAssertEqual(plan.columns, 2)
        XCTAssertEqual(plan.rows, 2)
        XCTAssertEqual(plan.tile, 142)
        XCTAssertLessThanOrEqual(plan.size.width, 290)
    }

    func testPictureGridGoesSideBySideOnAWideChat() {
        // Three tall screenshots on a Mac's chat sit in one row.
        let three = PictureGrid.plan(count: 3, width: 640)
        XCTAssertEqual(three.columns, 3)
        XCTAssertEqual(three.rows, 1)
        XCTAssertEqual(three.tile, PictureGrid.maxTile)

        // Six even out as two rows of three, not five and one.
        let six = PictureGrid.plan(count: 6, width: 640)
        XCTAssertEqual(six.columns, 3)
        XCTAssertEqual(six.rows, 2)
    }

    func testPictureGridWithoutAWidthAsksForARowOfLargestTiles() {
        // Asked for its ideal size, the grid wants every tile in a row at
        // its largest, so a bubble hugging that ideal (a group room's)
        // still offers it the room's width.
        let plan = PictureGrid.plan(count: 3, width: nil)

        XCTAssertEqual(plan.columns, 3)
        XCTAssertEqual(plan.rows, 1)
        XCTAssertEqual(plan.tile, PictureGrid.maxTile)
        XCTAssertEqual(PictureGrid.plan(count: 3, width: .infinity), plan)
        XCTAssertEqual(PictureGrid.plan(count: 0, width: 300).size, .zero)
    }

    func testPictureGridPutsSixInOneRowOnAWideColumn() {
        let six = PictureGrid.plan(count: 6, width: 760)

        XCTAssertEqual(six.columns, 6)
        XCTAssertEqual(six.rows, 1)
        XCTAssertLessThanOrEqual(six.size.width, 760)
    }

    func testPictureGridShowsSixTilesTheLastSayingHowManyMore() {
        XCTAssertEqual(PictureGrid.shownCount(4), 4)
        XCTAssertNil(PictureGrid.moreCount(total: 6))
        XCTAssertEqual(PictureGrid.shownCount(9), 6)
        // The badge covers the sixth picture, so it counts it too.
        XCTAssertEqual(PictureGrid.moreCount(total: 9), 4)
    }

    func testRepliesGroupTwoOrMorePicturesInARow() {
        let blocks: [MarkdownBlock] = [
            .paragraph("Here they are"),
            .image(url: "https://example.com/a.png", alt: "A"),
            .image(url: "MEDIA: /tmp/b.png", alt: "B"),
            .paragraph("And one more"),
            .image(url: "https://example.com/c.png", alt: "C"),
            .image(url: "MEDIA: /tmp/clip.mp4", alt: "Clip"),
            .image(url: "MEDIA: /tmp/d.jpg", alt: "D"),
            .image(url: "MEDIA: /tmp/e.jpg", alt: "E")
        ]

        // A lone picture keeps its own shape, and a video Hermes sent
        // keeps its card between pictures.
        let pictures = MarkdownProseRun.pictureRanges(in: blocks)
        XCTAssertEqual(pictures, [1..<3, 6..<8])

        let pieces = MarkdownProseRun.pieces(blockCount: blocks.count, runs: [], pictures: pictures)
        XCTAssertEqual(pieces.map(\.blocks), [0..<1, 1..<3, 3..<4, 4..<5, 5..<6, 6..<8])
        XCTAssertEqual(pieces.map(\.isPictures), [false, true, false, false, false, true])
        XCTAssertFalse(pieces.contains { $0.isPictures && $0.isRun })
    }

    func testPictureGridsSitBetweenProseRuns() {
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Shots"),
            .paragraph("Alpha"),
            .image(url: "https://example.com/a.png", alt: ""),
            .image(url: "https://example.com/b.png", alt: ""),
            .paragraph("Bravo"),
            .unorderedList(["One", "Two"])
        ]

        let pieces = MarkdownProseRun.pieces(
            blockCount: blocks.count,
            runs: MarkdownProseRun.ranges(in: blocks),
            pictures: MarkdownProseRun.pictureRanges(in: blocks)
        )
        XCTAssertEqual(pieces.map(\.blocks), [0..<2, 2..<4, 4..<6])
        XCTAssertEqual(pieces.map(\.isRun), [true, false, true])
        XCTAssertEqual(pieces.map(\.isPictures), [false, true, false])
    }

    /// A large document or a budgeted reply mounts some blocks only: a
    /// grid draws the run's pictures that are mounted, at the first of them.
    func testPictureSlotsGridTheMountedPicturesOfARun() {
        let runs = [2..<6]

        XCTAssertEqual(MarkdownProseRun.pictureSlot(at: 1, in: runs, shown: 0..<10), .single)
        XCTAssertEqual(MarkdownProseRun.pictureSlot(at: 2, in: runs, shown: 0..<10), .grid(2..<6))
        XCTAssertEqual(MarkdownProseRun.pictureSlot(at: 3, in: runs, shown: 0..<10), .covered)
        // A window ending inside the run grids what it shows of it.
        XCTAssertEqual(MarkdownProseRun.pictureSlot(at: 2, in: runs, shown: 0..<4), .grid(2..<4))
        // A tail starting inside the run starts its own grid there.
        XCTAssertEqual(MarkdownProseRun.pictureSlot(at: 4, in: runs, shown: 4..<10), .grid(4..<6))
        // One picture of the run shown alone keeps its own shape.
        XCTAssertEqual(MarkdownProseRun.pictureSlot(at: 2, in: runs, shown: 0..<3), .single)
        XCTAssertEqual(MarkdownProseRun.pictureRanges(flags: [true, false, true, true, true]), [2..<5])
    }
}
