//
//  HTMLPreviewDocumentsTests.swift
//  Conduit
//
//  A `::preview` row read and decoded its HTML file again every time it
//  scrolled back into view, and two rows naming one file read it twice
//  (issue 1961). Pages are now kept briefly, reads for one file are
//  shared, and a file that couldn't be read isn't asked for again at once.
//

import XCTest
@testable import Conduit

private func htmlDataURL(_ html: String) -> String {
    "data:text/html;base64," + Data(html.utf8).base64EncodedString()
}

@MainActor
final class HTMLPreviewDocumentsTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func documents() -> HTMLPreviewDocuments {
        HTMLPreviewDocuments(now: { [unowned self] in self.clock })
    }

    func testAPageReadIsKeptAndFreshForAWhile() async {
        let store = documents()
        var reads = 0
        let html = await store.read("a") { reads += 1; return htmlDataURL("<p>one</p>") }
        XCTAssertEqual(html, "<p>one</p>")
        XCTAssertEqual(reads, 1)
        let kept = try? XCTUnwrap(store.kept("a"))
        XCTAssertEqual(kept?.html, "<p>one</p>")
        XCTAssertTrue(kept.map(store.isFresh) ?? false)
        clock = clock.addingTimeInterval(HTMLPreviewDocuments.freshFor + 1)
        XCTAssertFalse(kept.map(store.isFresh) ?? true, "an older copy is read again, so a rewritten file shows")
    }

    func testTwoRowsNamingOneFileShareOneRead() async {
        let store = documents()
        var reads = 0
        var release: CheckedContinuation<Void, Never>?
        let fetch: () async -> String? = {
            reads += 1
            await withCheckedContinuation { release = $0 }
            return htmlDataURL("<p>shared</p>")
        }
        async let first = store.read("a", fetch: fetch)
        async let second = store.read("a", fetch: fetch)
        for _ in 0..<100 where release == nil { await Task.yield() }
        release?.resume()
        let answers = await [first, second]
        XCTAssertEqual(answers, ["<p>shared</p>", "<p>shared</p>"])
        XCTAssertEqual(reads, 1)
    }

    func testAFileThatCouldNotBeReadWaitsBeforeAskingAgain() async {
        let store = documents()
        var reads = 0
        let failing: () async -> String? = { reads += 1; return nil }
        let first = await store.read("a", fetch: failing)
        let second = await store.read("a", fetch: failing)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(reads, 1)
        clock = clock.addingTimeInterval(HTMLPreviewDocuments.freshFor + 1)
        _ = await store.read("a", fetch: failing)
        XCTAssertEqual(reads, 2)
    }

    func testOnlyTheLatestPagesAreKept() {
        let store = documents()
        for index in 0...HTMLPreviewDocuments.capacity {
            store.keep("<p>\(index)</p>", for: "page\(index)")
        }
        XCTAssertNil(store.kept("page0"), "the page read longest ago goes")
        XCTAssertNotNil(store.kept("page\(HTMLPreviewDocuments.capacity)"))
    }
}
