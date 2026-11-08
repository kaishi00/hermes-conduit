//
//  HTMLPreviewDocumentsTests.swift
//  Conduit
//
//  A `::preview` row read and decoded its HTML file again every time it
//  scrolled back into view, and two rows naming one file read it twice
//  (issue 1961). Pages are now kept briefly, reads for one file are
//  shared, and a file that couldn't be read isn't asked for again at once.
//  A kept page whose file stops reading is dropped (issue 2003).
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
        var gaveUp = false
        let fetch: () async -> String? = {
            reads += 1
            // A read that starts after the wait below gave up answers at once,
            // so the test can't hang on a continuation nobody resumes.
            if !gaveUp { await withCheckedContinuation { release = $0 } }
            return htmlDataURL("<p>shared</p>")
        }
        async let first = store.read("a", fetch: fetch)
        async let second = store.read("a", fetch: fetch)
        for _ in 0..<500 where release == nil { try? await Task.sleep(for: .milliseconds(2)) }
        guard let release else {
            gaveUp = true
            _ = await [first, second]
            XCTFail("the shared read never started")
            return
        }
        // Any fetch from here on answers at once: a second one would show
        // in `reads` rather than hang.
        gaveUp = true
        release.resume()
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

    func testAKeptPageWhoseFileNoLongerReadsIsDropped() async {
        // The file was deleted after its page was kept: the row falls back
        // to the file card instead of showing the dead file (issue 2003).
        let store = documents()
        _ = await store.read("a") { htmlDataURL("<p>one</p>") }
        XCTAssertNotNil(store.kept("a"))
        clock = clock.addingTimeInterval(HTMLPreviewDocuments.freshFor + 1)
        let html = await store.read("a") { nil }
        XCTAssertNil(html)
        XCTAssertNil(store.kept("a"), "no row shows the dead file's page again")
        // Once the file reads again, it's kept again.
        clock = clock.addingTimeInterval(HTMLPreviewDocuments.freshFor + 1)
        let back = await store.read("a") { htmlDataURL("<p>two</p>") }
        XCTAssertEqual(back, "<p>two</p>")
        XCTAssertEqual(store.kept("a")?.html, "<p>two</p>")
    }

    func testOnlyTheLatestPagesAreKept() {
        let store = documents()
        for index in 0...HTMLPreviewDocuments.capacity {
            store.keep("<p>\(index)</p>", for: "page\(index)")
        }
        XCTAssertNil(store.kept("page0"), "the page read longest ago goes")
        XCTAssertNotNil(store.kept("page\(HTMLPreviewDocuments.capacity)"))
    }

    func testAPageShownAgainIsKeptOverOnesShownLongerAgo() {
        let store = documents()
        for index in 0..<HTMLPreviewDocuments.capacity {
            store.keep("<p>\(index)</p>", for: "page\(index)")
        }
        XCTAssertNotNil(store.kept("page0"), "shown again")
        store.keep("<p>new</p>", for: "new")
        XCTAssertNotNil(store.kept("page0"), "a page just shown stays")
        XCTAssertNil(store.kept("page1"), "the page shown longest ago goes")
    }
}
