import Foundation
import XCTest
@testable import Conduit

/// Storage and normalization contracts behind the presentation cache's
/// main-thread cost fixes: the decoded store is reused instead of re-read on
/// every call, the app's instance writes to disk off the main thread, and
/// signatures come from a scalar pass instead of a regex.
///
/// An extension of the existing class, not a new one: the CI test planner is
/// at its class capacity and fails validation when a class is added.
extension SessionPresentationCacheTests {

    /// Stored signatures from earlier builds were made with the regex. The
    /// scalar pass must produce byte-identical text or every cached row would
    /// stop matching its fresh counterpart by content after an update.
    func testCollapsingWhitespaceMatchesRegexNormalization() {
        let samples = [
            "",
            " ",
            "plain",
            "  leading and trailing  ",
            "tabs\tand\nnewlines\r\nmixed \t \n here",
            "vertical\u{0B}tab and form\u{0C}feed",
            "next\u{85}line",
            "no-break\u{A0}space and ideographic\u{3000}space",
            "line\u{2028}separator and paragraph\u{2029}separator",
            "thin\u{2009}space, narrow\u{202F}no-break, medium\u{205F}math",
            "ogham\u{1680}space mark",
            "zero\u{200B}width is not whitespace",
            "e\u{301} combining after space: a \u{301}b",
            "emoji 👩‍👩‍👧 family   and flags 🇯🇵\n\n",
            "\n\n```swift\nlet x = 1\n    return x\n```\n",
            "info separators \u{1C}\u{1D}\u{1E}\u{1F} are not whitespace"
        ]
        for sample in samples {
            let expected = sample
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                SessionPresentationCache.collapsingWhitespace(sample),
                expected,
                "Mismatch for \(sample.debugDescription)"
            )
        }
    }

    func testAsynchronousWritesReachDiskInOrder() throws {
        let suiteName = "conduit.tests.presentation-async-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = SessionPresentationCache(defaults: defaults, writesAsynchronously: true)

        cache.save(
            [ChatMessage(id: "row-1", role: .assistant, content: "Hello", timestamp: "2024-01-01T10:00:00Z")],
            profile: "default",
            sessionIDs: ["session-a"]
        )
        // The writing instance answers from memory right away.
        XCTAssertEqual(
            cache.merge(
                [ChatMessage(id: "row-1", role: .assistant, content: "Hello", timestamp: "")],
                profile: "default",
                sessionIDs: ["session-a"]
            ).first?.timestamp,
            "2024-01-01T10:00:00Z"
        )

        // What landed on disk is what a fresh launch reads.
        cache.waitForPendingWrites()
        let relaunched = SessionPresentationCache(defaults: defaults)
        XCTAssertEqual(
            relaunched.merge(
                [ChatMessage(id: "row-1", role: .assistant, content: "Hello", timestamp: "")],
                profile: "default",
                sessionIDs: ["session-a"]
            ).first?.timestamp,
            "2024-01-01T10:00:00Z"
        )

        // A clear queued behind a save is never overtaken by it.
        cache.save(
            [ChatMessage(id: "row-2", role: .assistant, content: "Again", timestamp: "2024-01-02T10:00:00Z")],
            profile: "default",
            sessionIDs: ["session-b"]
        )
        cache.clear()
        cache.waitForPendingWrites()
        XCTAssertNil(defaults.data(forKey: "conduit.sessionPresentation.v1"))
        XCTAssertNil(defaults.data(forKey: "conduit.sessionPresentation.pendingTools.v1"))
        XCTAssertEqual(
            cache.merge(
                [ChatMessage(id: "row-2", role: .assistant, content: "Again", timestamp: "")],
                profile: "default",
                sessionIDs: ["session-b"]
            ).first?.timestamp,
            ""
        )
    }

    /// Synchronous instances reuse their decoded store only while the bytes
    /// on disk are the ones they read or wrote, so another writer's change
    /// is still seen.
    func testSynchronousCacheSeesAnotherInstancesWrite() throws {
        let suiteName = "conduit.tests.presentation-sync-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SessionPresentationCache(defaults: defaults)
        let second = SessionPresentationCache(defaults: defaults)
        let gatewayRow = [ChatMessage(id: "row-1", role: .assistant, content: "Hello", timestamp: "")]

        first.save(
            [ChatMessage(id: "row-1", role: .assistant, content: "Hello", timestamp: "2024-01-01T10:00:00Z")],
            profile: "default",
            sessionIDs: ["session-a"]
        )
        XCTAssertEqual(
            first.merge(gatewayRow, profile: "default", sessionIDs: ["session-a"]).first?.timestamp,
            "2024-01-01T10:00:00Z"
        )

        second.clear(profile: "default")
        XCTAssertEqual(
            first.merge(gatewayRow, profile: "default", sessionIDs: ["session-a"]).first?.timestamp,
            ""
        )
    }
}
