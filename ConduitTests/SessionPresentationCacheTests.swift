import Foundation
import XCTest
@testable import Conduit

/// Tests SessionPresentationCache.merge — the logic that decides which
/// presentation metadata (timestamps, tool previews, attachments) survives
/// a reconnect or session reopen. Getting this wrong means messages lose
/// their timestamps or tool calls lose their input text.
final class SessionPresentationCacheTests: XCTestCase {

    // MARK: - Merge: timestamp restoration

    func testMergeRestoresMissingTimestamp() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-timestamp-\(UUID().uuidString)"
        let profile = "test"

        // Save messages WITH timestamps
        let savedMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Hello", timestamp: "2024-01-01T10:00:00Z"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        // Gateway sends messages WITHOUT timestamps (compact history)
        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Hello", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertEqual(merged[0].timestamp, "2024-01-01T10:00:00Z")

        cache.clear(profile: profile)
    }

    func testMergeDoesNotOverrideExistingTimestamp() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-no-override-\(UUID().uuidString)"
        let profile = "test"

        let savedMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Hello", timestamp: "2024-01-01T10:00:00Z"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Hello", timestamp: "2024-06-01T12:00:00Z"),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertEqual(merged[0].timestamp, "2024-06-01T12:00:00Z")

        cache.clear(profile: profile)
    }

    // MARK: - Merge: tool input restoration

    func testMergeRestoresToolInputFromPreview() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-tool-\(UUID().uuidString)"
        let profile = "test"

        let savedMessages = [
            ChatMessage(
                id: "msg-tool", role: .tool, content: "",
                timestamp: "2024-01-01",
                tool: ToolActivity(id: nil, name: "terminal", input: "ls -la", output: "output", status: .complete)
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        // Gateway sends tool with empty input (compact history)
        let gatewayMessages = [
            ChatMessage(
                id: "msg-tool", role: .tool, content: "",
                timestamp: "",
                tool: ToolActivity(id: nil, name: "terminal", input: nil, output: "output", status: .complete)
            ),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertNotNil(merged[0].tool?.input)
        XCTAssertFalse(merged[0].tool?.input?.isEmpty ?? true)

        cache.clear(profile: profile)
    }

    // MARK: - Merge: attachment restoration

    func testMergeRestoresAttachments() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-attach-\(UUID().uuidString)"
        let profile = "test"

        let attachment = Attachment(id: "att-1", name: "image.png", uri: "file:///tmp/image.png", mimeType: "image/png", kind: .image)
        let savedMessages = [
            ChatMessage(id: "msg-1", role: .user, content: "Look", timestamp: "2024-01-01", attachments: [attachment]),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .user, content: "Look", timestamp: "", attachments: nil),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertEqual(merged[0].attachments?.count, 1)
        XCTAssertEqual(merged[0].attachments?.first?.id, "att-1")

        cache.clear(profile: profile)
    }

    // MARK: - Merge: no cache available

    func testMergeReturnsOriginalWhenNoCache() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-no-cache-\(UUID().uuidString)"

        let messages = [
            ChatMessage(id: "msg-1", role: .user, content: "Hello", timestamp: "2024-01-01"),
        ]
        let merged = cache.merge(messages, profile: "test", sessionIDs: [sessionId])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].content, "Hello")
    }

    // MARK: - Merge: ID-based matching

    func testMergeMatchesByExactId() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-id-\(UUID().uuidString)"
        let profile = "test"

        let savedMessages = [
            ChatMessage(id: "unique-id-123", role: .assistant, content: "Response", timestamp: "2024-01-01T10:00:00Z"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "unique-id-123", role: .assistant, content: "Response", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertEqual(merged[0].timestamp, "2024-01-01T10:00:00Z")

        cache.clear(profile: profile)
    }

    // MARK: - Merge: role mismatch prevention

    func testMergeDoesNotMatchAcrossRoles() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-role-\(UUID().uuidString)"
        let profile = "test"

        let savedMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Response", timestamp: "2024-01-01"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .user, content: "Response", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        // Different role = no match = timestamp not restored
        XCTAssertEqual(merged[0].timestamp, "")

        cache.clear(profile: profile)
    }

    // MARK: - Save + clear isolation

    func testClearRemovesSpecificProfile() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-clear-\(UUID().uuidString)"
        let profile = "test-clear-profile"

        let messages = [
            ChatMessage(id: "msg-1", role: .user, content: "data", timestamp: "2024-01-01"),
        ]
        cache.save(messages, profile: profile, sessionIDs: [sessionId])
        cache.clear(profile: profile)

        let merged = cache.merge(messages, profile: profile, sessionIDs: [sessionId])
        // After clear, no cache to restore from, but messages still returned
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: - Multiple session IDs

    func testSaveAndMergeAcrossLineageSessionIds() {
        let cache = SessionPresentationCache.shared
        let primaryId = "test-lineage-primary-\(UUID().uuidString)"
        let altId = "test-lineage-alt-\(UUID().uuidString)"
        let profile = "test"

        let messages = [
            ChatMessage(id: "msg-1", role: .user, content: "Hello", timestamp: "2024-01-01"),
        ]
        cache.save(messages, profile: profile, sessionIDs: [primaryId, altId])

        // Merging with altId should still find the cache
        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .user, content: "Hello", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [altId])

        XCTAssertEqual(merged[0].timestamp, "2024-01-01")

        cache.clear(profile: profile)
    }

    // MARK: - Merge: pending clarification restoration

    func testMergeRestoresPendingClarificationWhenRequested() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-clarify-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-123",
            question: "Which color?",
            choices: [
                ClarifyChoice(label: "Red", value: "red"),
                ClarifyChoice(label: "Blue", value: "blue"),
            ],
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-123",
                role: .clarify,
                content: "Which color?",
                timestamp: "2024-01-01T10:00:00Z",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        // Gateway resume omits the clarify card (compact history)
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )

        let restoredClarify = merged.first { $0.role == .clarify }
        XCTAssertNotNil(restoredClarify, "Pending clarification should be restored from cache")
        XCTAssertEqual(restoredClarify?.clarify?.requestId, "req-123")
        XCTAssertEqual(restoredClarify?.clarify?.status, .pending)
        XCTAssertEqual(restoredClarify?.clarify?.choices.count, 2)

        cache.clear(profile: profile)
    }

    func testMergeDoesNotRestoreClarificationWhenNotRequested() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-clarify-off-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-456",
            question: "Pick one",
            choices: [ClarifyChoice(label: "A", value: "a")],
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-456",
                role: .clarify,
                content: "Pick one",
                timestamp: "2024-01-01",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: false
        )

        XCTAssertFalse(merged.contains { $0.role == .clarify },
                       "Clarification should not be restored when includePendingClarifications is false")

        cache.clear(profile: profile)
    }

    func testMergeDoesNotRestoreAnsweredClarification() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-clarify-answered-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-789",
            question: "Done?",
            choices: [ClarifyChoice(label: "Yes", value: "yes")],
            status: .answered,
            answer: "yes"
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-789",
                role: .clarify,
                content: "Done?",
                timestamp: "2024-01-01",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )

        XCTAssertFalse(merged.contains { $0.role == .clarify },
                       "Answered clarification should not be restored as pending")

        cache.clear(profile: profile)
    }
}
