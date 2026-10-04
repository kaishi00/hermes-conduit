import XCTest
@testable import Conduit

final class MarkdownFallbackTests: XCTestCase {

    func testResolveAcceptsValidHTTPURLWithoutChangingEscapes() throws {
        let destination = try XCTUnwrap(
            WebFallbackImageDestination.resolve(
                "https://example.com/assets/100%20photos.png?size=2#preview"
            )
        )

        XCTAssertEqual(
            destination.absoluteString,
            "https://example.com/assets/100%20photos.png?size=2#preview"
        )
    }

    func testResolveRepairsPathCharactersWithoutCorruptingURLDelimiters() throws {
        let destination = try XCTUnwrap(
            WebFallbackImageDestination.resolve("https://example.com/assets/a b.png#preview")
        )

        XCTAssertEqual(destination.absoluteString, "https://example.com/assets/a%20b.png#preview")
    }

    func testResolvePreservesExistingEscapesWhenRepairingInvalidPercentCharacters() throws {
        let destination = try XCTUnwrap(
            WebFallbackImageDestination.resolve("https://example.com/assets/100%20photos%ZZ.png")
        )

        XCTAssertEqual(
            destination.absoluteString,
            "https://example.com/assets/100%20photos%25ZZ.png"
        )
    }

    func testResolvePreservesEncodedPathWhenAnotherComponentNeedsRepair() throws {
        let destination = try XCTUnwrap(
            WebFallbackImageDestination.resolve(
                "https://example.com/assets/a%2Fb.png?caption=bad value"
            )
        )

        XCTAssertEqual(
            destination.absoluteString,
            "https://example.com/assets/a%2Fb.png?caption=bad%20value"
        )
    }

    func testResolveRejectsMissingHostAndUnsupportedScheme() {
        XCTAssertNil(WebFallbackImageDestination.resolve("https:///image.png"))
        XCTAssertNil(WebFallbackImageDestination.resolve("javascript:alert(1)"))
    }

    func testUnparseableDestinationUsesUnavailableCopy() {
        let destination = WebFallbackImageDestination.resolve("https://[invalid")

        XCTAssertNil(destination)
        XCTAssertEqual(
            WebFallbackImageLabel.title(alt: "", destinationAvailable: destination != nil),
            "Image unavailable"
        )
    }

    func testUnlinkedImageWithoutAltUsesNonActionCopy() {
        XCTAssertEqual(
            WebFallbackImageLabel.title(alt: "", destinationAvailable: false),
            "Image unavailable"
        )
    }

    func testLinkedImageWithoutAltKeepsOpenActionCopy() {
        XCTAssertEqual(
            WebFallbackImageLabel.title(alt: "", destinationAvailable: true),
            "Open image"
        )
    }

    func testLinkedImageWithAltRetainsAccessibleDescription() {
        XCTAssertEqual(
            WebFallbackImageLabel.title(alt: "Sunset over the bay", destinationAvailable: true),
            "Sunset over the bay — image unavailable; open source"
        )
    }
}

extension MarkdownFallbackTests {
    func testMermaidXYChartAxisRangeWrittenWithToIsRepaired() {
        let source = """
        xychart-beta
            title "Running Containers by Node"
            x-axis ["pve", "seele"]
            y-axis "Count" 0 to 20
            bar [16, 7]
        """
        let repaired = MermaidSourceRepair.repaired(source)
        XCTAssertTrue(repaired.contains("y-axis \"Count\" 0 --> 20"))
        XCTAssertTrue(repaired.contains("bar [16, 7]"))
        XCTAssertEqual(MermaidSourceRepair.repaired(repaired), repaired, "a correct range is left alone")
        let pie = "pie\n    \"a\" : 1 to 2"
        XCTAssertEqual(MermaidSourceRepair.repaired(pie), pie, "only xychart axes are touched")
    }
}
