import XCTest
@testable import Conduit

/// Regression tests for incremental target-cache fingerprinting (Fix 5):
/// appending or replacing a transcript tail must hash only the changed
/// suffix, and every incremental result must be identical to the existing
/// full-rebuild reference. Deterministic via TranscriptPerf counters.
final class ChatMessageScrollTargetCacheIncrementalTests: XCTestCase {

    private func message(_ id: String, _ content: String, role: MessageRole = .assistant) -> ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            content: content,
            timestamp: "2026-01-01T00:00:00Z"
        )
    }

    /// The full-rebuild reference: exactly what the pre-incremental
    /// implementation produced for any transcript.
    private func referenceTargets(for messages: [ChatMessage]) -> [ChatMessageScrollTarget] {
        ChatMessageScrollTargets.make(for: messages)
    }

    /// Drives the incremental cache through a sequence of transcripts and
    /// asserts each result equals the full-rebuild reference.
    private func assertSequence(
        _ transcripts: [[ChatMessage]],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        var cache = ChatMessageScrollTargetCache()
        for messages in transcripts {
            let result = cache.update(for: messages)
            XCTAssertNotEqual(
                result, .unchanged,
                "a real transcript change must not report unchanged",
                file: file, line: line
            )
            XCTAssertEqual(
                cache.targets, referenceTargets(for: messages),
                "incremental result must equal the full-rebuild reference",
                file: file, line: line
            )
        }
    }

    private func prime(_ messages: [ChatMessage]) -> ChatMessageScrollTargetCache {
        var cache = ChatMessageScrollTargetCache()
        _ = cache.update(for: messages)
        return cache
    }

    // MARK: - Incremental work bounds (counters)

    func testAppendHashesOnlyTheAppendedMessage() {
        let base = (0..<200).map { message("m\($0)", "settled content \($0) with some length") }
        var cache = prime(base)

        TranscriptPerf.reset()
        _ = cache.update(for: base + [message("m200", "the new final message")])

        XCTAssertEqual(
            TranscriptPerf.lastFingerprintedMessageCount, 1,
            "an append must fingerprint only the appended message"
        )
    }

    func testTailReplacementHashesOnlyTheChangedTail() {
        let base = (0..<200).map { message("m\($0)", "settled content \($0) with some length") }
        var cache = prime(base)

        var replaced = base
        replaced[199] = message("m199", "edited final message")

        TranscriptPerf.reset()
        _ = cache.update(for: replaced)

        XCTAssertEqual(
            TranscriptPerf.lastFingerprintedMessageCount, 1,
            "a tail replacement must fingerprint only the changed tail"
        )
    }

    func testUnchangedTranscriptHashesNothing() {
        let base = (0..<50).map { message("m\($0)", "content \($0)") }
        var cache = prime(base)

        TranscriptPerf.reset()
        let result = cache.update(for: base)
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(TranscriptPerf.lastFingerprintedMessageCount, 0)
    }

    // MARK: - Incremental equivalence vs full rebuild

    func testAppendResultMatchesFullRebuild() {
        assertSequence([
            [message("a", "one")],
            [message("a", "one"), message("b", "two")],
            [message("a", "one"), message("b", "two"), message("c", "three")],
        ])
    }

    func testTailReplacementResultMatchesFullRebuild() {
        assertSequence([
            [message("a", "one"), message("b", "two"), message("c", "three"), message("d", "four")],
            [message("a", "one"), message("b", "two"), message("c", "three"), message("d", "EDITED")],
        ])
    }

    func testRenderingOnlyReplacementPreservesSemanticIDsAndReportsRenderingChanged() {
        var cache = prime([message("a", "one"), message("b", "two")])
        let originalIDs = cache.targets.map(\.semanticID)

        // Same fingerprints (same content), different message object (e.g.
        // normalized attachment metadata elsewhere on the value).
        let reprojected = [
            ChatMessage(id: "a", role: .assistant, content: "one", timestamp: "2026-01-02T00:00:00Z"),
            ChatMessage(id: "b", role: .assistant, content: "two", timestamp: "2026-01-02T00:00:00Z"),
        ]

        TranscriptPerf.reset()
        let result = cache.update(for: reprojected)
        XCTAssertEqual(result, .renderingChanged)
        XCTAssertEqual(cache.targets.map(\.semanticID), originalIDs)
        XCTAssertEqual(cache.targets, referenceTargets(for: reprojected))
        // Fingerprinting still hashes only the diverging suffix (timestamp
        // differs from the first element, so the whole array is the suffix
        // here — but the reference comparison above proves correctness).
        XCTAssertGreaterThan(TranscriptPerf.lastFingerprintedMessageCount, 0)
    }

    func testDuplicateContentsFallBackToFullRebuildAndMatchReference() {
        // Appending a duplicate of an existing fingerprint must not take an
        // incremental path that would mis-number occurrences.
        let a1 = message("a1", "identical body")
        let a2 = message("a2", "identical body")
        let b = message("b", "different body")

        var cache = prime([a1, a2, b])
        XCTAssertEqual(cache.targets.map(\.semanticID), referenceTargets(for: [a1, a2, b]).map(\.semanticID))

        TranscriptPerf.reset()
        _ = cache.update(for: [a1, a2, b, message("a3", "identical body")])

        XCTAssertEqual(
            cache.targets, referenceTargets(for: [a1, a2, b, message("a3", "identical body")]),
            "duplicate-crossing append must still match the full-rebuild reference"
        )
        XCTAssertEqual(
            TranscriptPerf.lastFingerprintedMessageCount, 4,
            "duplicate-crossing mutations must fall back to a full rebuild"
        )
    }

    func testMiddleInsertionMatchesFullRebuild() {
        assertSequence([
            [message("a", "one"), message("c", "three")],
            [message("a", "one"), message("b", "inserted"), message("c", "three")],
        ])
    }

    func testDeletionMatchesFullRebuild() {
        assertSequence([
            [message("a", "one"), message("b", "two"), message("c", "three"), message("d", "four")],
            [message("a", "one"), message("b", "two"), message("d", "four")],
        ])
    }

    func testReorderFallsBackToFullRebuildAndMatchesReference() {
        assertSequence([
            [message("a", "one"), message("b", "two"), message("c", "three")],
            [message("c", "three"), message("a", "one"), message("b", "two")],
        ])
    }

    func testFullReplacementMatchesFullRebuild() {
        assertSequence([
            [message("a", "one"), message("b", "two")],
            [message("x", "completely"), message("y", "different"), message("z", "transcript")],
        ])
    }

    /// Property-style sweep: randomized mutations over a transcript with a
    /// colliding fingerprint pool, incremental vs reference, always equal.
    func testRandomizedMutationsAlwaysMatchFullRebuild() {
        var messages = (0..<40).map { message("m\($0)", "body \($0 % 7) of message \($0)") }
        var cache = prime(messages)
        XCTAssertEqual(cache.targets, referenceTargets(for: messages))

        // Deterministic pseudo-random sequence: seeded LCG.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed
        }

        for step in 0..<60 {
            switch next() % 5 {
            case 0: // append
                messages.append(message("s\(step)-append", "body \(next() % 9) appended"))
            case 1: // delete
                guard messages.count > 1 else { break }
                messages.remove(at: Int(next() % UInt64(messages.count)))
            case 2: // insert middle
                messages.insert(
                    message("s\(step)-insert", "body \(next() % 9) inserted"),
                    at: Int(next() % UInt64(messages.count))
                )
            case 3: // edit near the tail (clamped to valid indices)
                if !messages.isEmpty {
                    let idx = max(0, messages.count - 1 - Int(next() % 3))
                    messages[idx] = message(messages[idx].id, "body \(next() % 9) edited")
                }
            default: // duplicate an existing body
                if !messages.isEmpty {
                    let source = messages[Int(next() % UInt64(messages.count))]
                    messages.append(message("s\(step)-dup", source.content))
                }
            }
            _ = cache.update(for: messages)
            XCTAssertEqual(
                cache.targets, referenceTargets(for: messages),
                "step \(step): incremental result diverged from the full-rebuild reference"
            )
        }
    }
}
