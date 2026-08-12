import Foundation
import XCTest
@testable import Conduit

/// Foreground reconciliation buffers stream events while `session.resume`
/// runs, then replays them after the live bubble is seeded from the resume
/// snapshot's cumulative inflight projection. These tests cover the dedupe
/// that keeps replayed deltas from repeating text the snapshot already
/// contains.
final class BufferedEventDeduplicationTests: XCTestCase {

    private func deltaTexts(in events: [StreamEvent]) -> [String] {
        events.compactMap {
            if case .messageDelta(_, let text) = $0 { return text }
            return nil
        }
    }

    private func deltaSessionIDs(in events: [StreamEvent]) -> [String] {
        events.compactMap {
            if case .messageDelta(let sessionId, _) = $0 { return sessionId }
            return nil
        }
    }

    // MARK: - deduplicatingBufferedEvents

    func testDeltasFullyCoveredBySnapshotAreDropped() {
        // User foregrounds mid-turn; deltas D1+D2 arrive while resume runs,
        // and the snapshot's cumulative inflight already ends with them.
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "over the "),
            .messageDelta(sessionId: "s1", text: "lazy dog."),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "The fox jumps over the lazy dog.",
            knownPrefix: "The fox jumps ",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testUncoveredSuffixSurvivesAsSingleDelta() {
        // The snapshot was generated between the two buffered deltas: only
        // the portion beyond the snapshot tail may be replayed.
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "over the "),
            .messageDelta(sessionId: "s1", text: "lazy dog."),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "The fox jumps over the lazy",
            knownPrefix: "The fox jumps ",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )
        XCTAssertEqual(deltaTexts(in: result), [" dog."])
    }

    func testNoOverlapKeepsEventsUntouched() {
        // A gateway whose inflight projection is not cumulative (or a turn
        // that started after the snapshot) must keep its deltas.
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "fresh text"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "unrelated snapshot",
            knownPrefix: "The fox jumps ",
            sessionID: "s1"
        )
        XCTAssertEqual(deltaTexts(in: result), ["fresh text"])
    }

    func testNonDeltaEventsPassThroughInOrder() {
        let events: [StreamEvent] = [
            .toolStart(sessionId: "s1", toolName: "Bash", toolInput: "ls"),
            .messageDelta(sessionId: "s1", text: "done."),
            .messageComplete(sessionId: "s1", messageId: nil, content: "All done.", reasoning: nil),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "Everything is done.",
            knownPrefix: "Everything is ",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )
        XCTAssertEqual(result.count, 2)
        if case .toolStart = result[0] {} else {
            XCTFail("Expected toolStart to pass through first")
        }
        if case .messageComplete = result[1] {} else {
            XCTFail("Expected messageComplete to pass through last")
        }
    }

    func testPartialCoveragePreservesInterleavedEventOrder() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "abcd"),
            .toolStart(sessionId: "s1", toolName: "Bash", toolInput: "ls"),
            .messageDelta(sessionId: "s1", text: "ef"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "abc",
            knownPrefix: "",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(result.count, 3)
        if case .messageDelta(_, let text) = result[0] {
            XCTAssertEqual(text, "d")
        } else {
            XCTFail("Expected the uncovered first delta before toolStart")
        }
        if case .toolStart = result[1] {} else {
            XCTFail("Expected toolStart to remain between the deltas")
        }
        if case .messageDelta(_, let text) = result[2] {
            XCTAssertEqual(text, "ef")
        } else {
            XCTFail("Expected the second delta after toolStart")
        }
    }

    func testAmbiguousRepeatedTextIsNotDeduplicated() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "aaa"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "aaaa",
            knownPrefix: "aaaa",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(deltaTexts(in: result), ["aaa"])
    }

    func testExactBoundaryConsumesOnlyNewRepeatedText() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "aaa"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "aaaaaa",
            knownPrefix: "aaaa",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(deltaTexts(in: result), ["a"])
    }

    func testMismatchedInflightSuffixDoesNotDropNewText() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "C"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "AB",
            knownPrefix: "A",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(deltaTexts(in: result), ["C"])
    }

    func testWhitespaceAroundCoveredDeltaIsNotReplayed() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: " I found it. "),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "I found it.",
            knownPrefix: "",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testCoveredTrailingWhitespaceIsNotReplayedBeforeNewText() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "foo bar"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "foo ",
            knownPrefix: "",
            sessionID: "s1",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(deltaTexts(in: result), ["bar"])
    }

    func testSuffixAlignedCoveredDeltaIsNotReplayed() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "C"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "C",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "BC",
            hasBoundaryAnchor: true
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testMidWindowGapDropsSuffixAlignedBufferedDeltas() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "CD"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "CD",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "BCD",
            hasBoundaryAnchor: true
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testStraddledCoveredDeltaKeepsOnlyNewSuffix() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "CDE"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "CDE",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "BCD",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(deltaTexts(in: result), ["E"])
    }

    func testStraddledCoveragePreservesInterleavedEventOrder() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "CDE"),
            .toolStart(sessionId: "s1", toolName: "Bash", toolInput: "ls"),
            .messageDelta(sessionId: "s1", text: "F"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "CDEF",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "BCD",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(result.count, 3)
        if case .messageDelta(_, let text) = result[0] {
            XCTAssertEqual(text, "E")
        } else {
            XCTFail("Expected the uncovered suffix before toolStart")
        }
        if case .toolStart = result[1] {} else {
            XCTFail("Expected toolStart to remain between the deltas")
        }
        if case .messageDelta(_, let text) = result[2] {
            XCTAssertEqual(text, "F")
        } else {
            XCTFail("Expected the later delta after toolStart")
        }
    }

    func testAmbiguousRepeatedStraddleKeepsBufferedText() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "bcabc"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "bcabc",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "abcabc",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(deltaTexts(in: result), ["bcabc"])
    }

    func testNewTurnMarkerPreservesCoincidentallyRepeatedText() {
        let events: [StreamEvent] = [
            .messageStart(sessionId: "s1"),
            .messageDelta(sessionId: "s1", text: "xyz more"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "xyz",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "xyz"
        )

        XCTAssertEqual(deltaTexts(in: result), ["xyz more"])
    }

    func testNewTurnMarkerOnlyPreservesEventsAfterTheMarker() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "old"),
            .messageStart(sessionId: "s1"),
            .messageDelta(sessionId: "s1", text: "xyz more"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "old",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "old",
            hasBoundaryAnchor: true
        )

        XCTAssertEqual(deltaTexts(in: result), ["xyz more"])
        XCTAssertEqual(result.count, 2)
        if case .messageStart = result[0] {} else {
            XCTFail("Expected the new-turn marker to remain before its delta")
        }
    }

    func testNoMarkerPrefixCollisionPreservesBufferedTextWithoutBoundaryProof() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "xyz more"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "xyz",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "xyz"
        )

        XCTAssertEqual(deltaTexts(in: result), ["xyz more"])
    }

    func testNoMarkerExactCollisionPreservesBufferedTextWithoutBoundaryProof() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "xyz"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "xyz",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "xyz"
        )

        XCTAssertEqual(deltaTexts(in: result), ["xyz"])
    }

    func testExplicitCoverageMustMatchSeededInflightBeforeDeduplicating() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "covered"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "unrelated",
            knownPrefix: "boundary",
            sessionID: "s1",
            coveredText: "covered"
        )

        XCTAssertEqual(deltaTexts(in: result), ["covered"])
    }

    func testExplicitCoverageMustOverlapSeededInflightBeforeDeduplicating() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "coincidental"),
        ]

        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "seeded",
            knownPrefix: "",
            sessionID: "s1",
            coveredText: "coincidental"
        )

        XCTAssertEqual(deltaTexts(in: result), ["coincidental"])
    }

    func testMissingBoundaryDoesNotGuessFromText() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "aaa"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "aaaa",
            knownPrefix: nil,
            sessionID: "s1"
        )

        XCTAssertEqual(deltaTexts(in: result), ["aaa"])
    }

    func testMultipleSessionDeltasAreNotMerged() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "abc"),
            .messageDelta(sessionId: "s2", text: "def"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "abc",
            knownPrefix: "",
            sessionID: "s1"
        )

        XCTAssertEqual(deltaSessionIDs(in: result), ["s1", "s2"])
        XCTAssertEqual(deltaTexts(in: result), ["abc", "def"])
    }

    func testEmptyInflightKeepsEvents() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "hello"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "",
            knownPrefix: "prefix",
            sessionID: "s1"
        )
        XCTAssertEqual(deltaTexts(in: result), ["hello"])
    }

    func testRemainderKeepsSessionIdOfBufferedDeltas() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "runtime-42", text: "abc def"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "xyz abc",
            knownPrefix: "xyz ",
            sessionID: "runtime-42",
            hasBoundaryAnchor: true
        )
        guard case .messageDelta(let sessionId, let text)? = result.first else {
            return XCTFail("Expected a merged delta")
        }
        XCTAssertEqual(sessionId, "runtime-42")
        XCTAssertEqual(text, " def")
    }
}
