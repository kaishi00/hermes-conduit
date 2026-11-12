//
//  LiveTranscriptPublishPacerTests.swift
//  Conduit
//
//  A live call published its transcript per word, re-rendering the call
//  screen and its timeline each time (issue 1960). A new line still
//  publishes at once; a growing line at most ten times a second, with a
//  trailing publish so its last words show.
//

import XCTest
@testable import Conduit

@MainActor
final class LiveTranscriptPublishPacerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var publishes = 0

    private func pacer(sleep: @escaping @Sendable (TimeInterval) async -> Void = { _ in }) -> LiveTranscriptPublishPacer {
        LiveTranscriptPublishPacer(now: { [unowned self] in self.clock }, sleep: sleep) { [unowned self] in
            self.publishes += 1
        }
    }

    func testANewLinePublishesAtOnce() {
        let pacer = pacer(sleep: { _ in try? await Task.sleep(for: .seconds(60)) })
        pacer.changed(count: 1)
        pacer.changed(count: 2)
        XCTAssertEqual(publishes, 2)
    }

    func testAGrowingLinePublishesAtMostTenTimesASecondAndLastWordsShow() async {
        let pacer = pacer()
        pacer.changed(count: 1)
        XCTAssertEqual(publishes, 1)
        // Words 20 ms apart: held back, then one trailing publish.
        for _ in 0..<4 {
            clock = clock.addingTimeInterval(0.02)
            pacer.changed(count: 1)
        }
        XCTAssertEqual(publishes, 1, "words inside the spacing wait")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(publishes, 2, "the trailing publish shows the last words")
        // Past the spacing, a word publishes straight away.
        clock = clock.addingTimeInterval(LiveTranscriptPublishPacer.spacing + 0.01)
        pacer.changed(count: 1)
        XCTAssertEqual(publishes, 3)
    }
}
