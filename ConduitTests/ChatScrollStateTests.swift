import XCTest
@testable import Conduit

final class ChatScrollStateTests: XCTestCase {
    func testSemanticAnchorsIgnoreSourceSpecificMessageIdentity() {
        let localMessages = [
            ChatMessage(
                id: "local-user",
                role: .user,
                content: "Compare these files",
                timestamp: "2026-08-08T12:00:00Z",
                author: "Local user",
                attachments: [
                    Attachment(
                        id: "picker-attachment",
                        name: "diagram.png",
                        uri: "file:///tmp/diagram.png",
                        mimeType: "image/png",
                        kind: .image
                    )
                ]
            ),
            ChatMessage(
                id: "live-assistant",
                role: .assistant,
                content: "The files match.",
                rawContent: "live projection",
                timestamp: "2026-08-08T12:00:01Z",
                author: "Hermes",
                code: "diff --brief a b"
            )
        ]
        let persistedMessages = [
            ChatMessage(
                id: "481",
                role: .user,
                content: "Compare these files",
                timestamp: "2026-08-08 12:00:00",
                author: nil,
                attachments: [
                    Attachment(
                        id: "481-gateway-image-0",
                        name: "diagram.png",
                        uri: "/gateway/uploads/diagram.png",
                        mimeType: "image/png",
                        kind: .image
                    )
                ]
            ),
            ChatMessage(
                id: "482",
                role: .assistant,
                content: "The files match.",
                rawContent: nil,
                timestamp: "2026-08-08 12:00:01",
                author: "assistant",
                code: "diff --brief a b"
            )
        ]

        XCTAssertEqual(
            ChatMessageScrollTargets.make(for: localMessages).map(\.semanticID),
            ChatMessageScrollTargets.make(for: persistedMessages).map(\.semanticID)
        )
    }

    func testDuplicateSemanticRowsReceiveDistinctOccurrenceQualifiedAnchors() {
        let firstProjection = [
            ChatMessage(id: "live-1", role: .assistant, content: "Repeated", timestamp: "now"),
            ChatMessage(id: "live-2", role: .assistant, content: "Repeated", timestamp: "later")
        ]
        let secondProjection = [
            ChatMessage(id: "stored-91", role: .assistant, content: "Repeated", timestamp: "1"),
            ChatMessage(id: "stored-92", role: .assistant, content: "Repeated", timestamp: "2")
        ]

        let firstIDs = ChatMessageScrollTargets.make(for: firstProjection).map(\.semanticID)
        let secondIDs = ChatMessageScrollTargets.make(for: secondProjection).map(\.semanticID)

        XCTAssertNotEqual(firstIDs[0], firstIDs[1])
        XCTAssertEqual(firstIDs, secondIDs)
    }

    func testStableActivityAndAttachmentFieldsParticipateInSemanticFingerprint() {
        func semanticID(for message: ChatMessage) -> String {
            ChatMessageScrollTargets.make(for: [message])[0].semanticID
        }

        let toolA = ChatMessage(
            id: "tool-a",
            role: .tool,
            content: "",
            timestamp: "now",
            tool: ToolActivity(id: "call-a", name: "read", input: "a.txt", output: nil, status: .running)
        )
        let toolB = ChatMessage(
            id: "tool-b",
            role: .tool,
            content: "",
            timestamp: "now",
            tool: ToolActivity(id: "call-b", name: "read", input: "b.txt", output: nil, status: .running)
        )
        let clarifyA = ChatMessage(
            id: "clarify-a",
            role: .clarify,
            content: "Choose one",
            timestamp: "now",
            clarify: ClarifyActivity(
                requestId: "request-a",
                question: "Choose one",
                choices: [ClarifyChoice(label: "Alpha", value: "a")],
                status: .pending,
                answer: nil,
                error: nil
            )
        )
        let clarifyB = ChatMessage(
            id: "clarify-b",
            role: .clarify,
            content: "Choose one",
            timestamp: "now",
            clarify: ClarifyActivity(
                requestId: "request-b",
                question: "Choose one",
                choices: [ClarifyChoice(label: "Beta", value: "b")],
                status: .pending,
                answer: nil,
                error: nil
            )
        )
        let approvalA = ChatMessage(
            id: "approval-a",
            role: .approval,
            content: "Approval required",
            timestamp: "now",
            approval: ApprovalActivity(
                sessionId: "runtime-a",
                command: "git status",
                description: "Approval required",
                choices: ["allow", "deny"],
                allowPermanent: true,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        let approvalB = ChatMessage(
            id: "approval-b",
            role: .approval,
            content: "Approval required",
            timestamp: "now",
            approval: ApprovalActivity(
                sessionId: "runtime-b",
                command: "git diff",
                description: "Approval required",
                choices: ["allow", "deny"],
                allowPermanent: true,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        let reviewA = ChatMessage(
            id: "review-a",
            role: .system,
            content: "Review complete",
            timestamp: "now",
            review: ReviewActivity(summary: "Review complete", details: ["Memory updated"], fullSessionId: "child-a")
        )
        let reviewB = ChatMessage(
            id: "review-b",
            role: .system,
            content: "Review complete",
            timestamp: "now",
            review: ReviewActivity(summary: "Review complete", details: ["Skill updated"], fullSessionId: "child-b")
        )
        let attachmentA = ChatMessage(
            id: "attachment-a",
            role: .user,
            content: "Attached",
            timestamp: "now",
            attachments: [Attachment(id: "a", name: "a.pdf", uri: "/tmp/a.pdf", mimeType: "application/pdf", kind: .document)]
        )
        let attachmentB = ChatMessage(
            id: "attachment-b",
            role: .user,
            content: "Attached",
            timestamp: "now",
            attachments: [Attachment(id: "b", name: "b.pdf", uri: "/tmp/b.pdf", mimeType: "application/pdf", kind: .document)]
        )

        XCTAssertNotEqual(semanticID(for: toolA), semanticID(for: toolB))
        XCTAssertNotEqual(semanticID(for: clarifyA), semanticID(for: clarifyB))
        XCTAssertNotEqual(semanticID(for: approvalA), semanticID(for: approvalB))
        XCTAssertNotEqual(semanticID(for: reviewA), semanticID(for: reviewB))
        XCTAssertNotEqual(semanticID(for: attachmentA), semanticID(for: attachmentB))
    }

    func testVolatileActivityIdentityAndStateDoNotChangeSemanticAnchor() {
        let pending = ChatMessage(
            id: "live",
            role: .approval,
            content: "Run command?",
            timestamp: "now",
            approval: ApprovalActivity(
                sessionId: "runtime-old",
                command: "make test",
                description: "Run command?",
                choices: ["allow", "deny"],
                allowPermanent: true,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        let persisted = ChatMessage(
            id: "stored",
            role: .approval,
            content: "Run command?",
            timestamp: "stored timestamp",
            approval: ApprovalActivity(
                sessionId: "runtime-new",
                command: "make test",
                description: "Run command?",
                choices: ["allow", "deny"],
                allowPermanent: true,
                smartDenied: false,
                status: .approved,
                choice: "allow",
                error: nil
            )
        )

        XCTAssertEqual(
            ChatMessageScrollTargets.make(for: [pending]).map(\.semanticID),
            ChatMessageScrollTargets.make(for: [persisted]).map(\.semanticID)
        )
    }

    func testEquivalentSessionIDsShareCanonicalIdentity() {
        let identity = ChatScrollSessionIdentity(
            canonicalSessionID: "catalog-id",
            equivalentSessionIDs: ["runtime-old", "runtime-new"],
            isReconciling: false,
            settledRevision: 4
        )

        XCTAssertEqual(identity.canonicalSessionID, "catalog-id")
        XCTAssertTrue(identity.areEquivalent("catalog-id", "runtime-old"))
        XCTAssertTrue(identity.areEquivalent("runtime-old", "runtime-new"))
        XCTAssertFalse(identity.areEquivalent("runtime-old", "different-session"))
    }

    func testNonLatestRestorationWaitsForReconciliationToSettleAtNewRevision() {
        let activeIdentity = ChatScrollSessionIdentity(
            canonicalSessionID: "catalog-id",
            equivalentSessionIDs: ["runtime-id"],
            isReconciling: true,
            settledRevision: 7
        )
        let gate = ChatScrollRestorationGate(observing: activeIdentity)

        XCTAssertFalse(gate.allowsNonLatestRestoration(using: activeIdentity))
        XCTAssertFalse(gate.allowsNonLatestRestoration(using: ChatScrollSessionIdentity(
            canonicalSessionID: "catalog-id",
            equivalentSessionIDs: ["runtime-id"],
            isReconciling: false,
            settledRevision: 7
        )))
        XCTAssertTrue(gate.allowsNonLatestRestoration(using: ChatScrollSessionIdentity(
            canonicalSessionID: "catalog-id",
            equivalentSessionIDs: ["runtime-id"],
            isReconciling: false,
            settledRevision: 8
        )))
    }

    func testNonLatestRestorationCanUseCurrentRevisionWhenNoReconciliationIsExpected() {
        let settledIdentity = ChatScrollSessionIdentity(
            canonicalSessionID: "catalog-id",
            equivalentSessionIDs: [],
            isReconciling: false,
            settledRevision: 3
        )
        let gate = ChatScrollRestorationGate(observing: settledIdentity)

        XCTAssertTrue(gate.allowsNonLatestRestoration(using: settledIdentity))
    }

    func testSnapshotsAreIsolatedBySession() {
        var store = ChatScrollStateStore()
        store.save(
            ChatScrollSnapshot(anchorMessageID: "a-3", followsLatest: false),
            for: "session-a"
        )
        store.save(
            ChatScrollSnapshot(anchorMessageID: "b-1", followsLatest: false),
            for: "session-b"
        )

        XCTAssertEqual(store.snapshot(for: "session-a")?.anchorMessageID, "a-3")
        XCTAssertEqual(store.snapshot(for: "session-b")?.anchorMessageID, "b-1")
    }

    func testRestorationKeepsAnchorWhenMessageStillExists() {
        var store = ChatScrollStateStore()
        let expected = ChatScrollSnapshot(anchorMessageID: "message-4", followsLatest: false)
        store.save(expected, for: "session")

        XCTAssertEqual(
            store.restoration(
                for: "session",
                availableMessageIDs: ["message-3", "message-4", "message-5"]
            ),
            expected
        )
    }

    func testRestorationFallsBackToLatestWhenAnchorDisappears() {
        var store = ChatScrollStateStore()
        store.save(
            ChatScrollSnapshot(anchorMessageID: "deleted", followsLatest: false),
            for: "session"
        )

        XCTAssertEqual(
            store.restoration(for: "session", availableMessageIDs: ["message-1"]),
            .latest
        )
    }

    func testLatestSnapshotRemainsLatestRegardlessOfAvailableMessages() {
        var store = ChatScrollStateStore()
        store.save(ChatScrollSnapshot.latest, for: "session")

        XCTAssertEqual(
            store.restoration(for: "session", availableMessageIDs: []),
            .latest
        )
    }

    func testSessionKeysAreTrimmedForSaveAndLookup() {
        var store = ChatScrollStateStore()
        let expected = ChatScrollSnapshot(anchorMessageID: "message-1", followsLatest: false)
        store.save(expected, for: "  session  ")

        XCTAssertEqual(store.snapshot(for: "session"), expected)
        XCTAssertEqual(store.snapshot(for: "\n session \t"), expected)
    }

    func testWhitespaceOnlySessionKeysAreIgnored() {
        var store = ChatScrollStateStore()
        store.save(ChatScrollSnapshot.latest, for: " \n\t ")

        XCTAssertNil(store.snapshot(for: " \n\t "))
    }
}
