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

    func testRestorationFallsBackWhenDuplicateMultiplicityChanges() {
        let originalTargets = ChatMessageScrollTargets.make(for: [
            ChatMessage(id: "live-first", role: .assistant, content: "Repeated", timestamp: "now"),
            ChatMessage(id: "live-second", role: .assistant, content: "Repeated", timestamp: "later")
        ])
        let compactedTargets = ChatMessageScrollTargets.make(for: [
            ChatMessage(id: "stored-second", role: .assistant, content: "Repeated", timestamp: "stored")
        ])
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: originalTargets[0].semanticID,
            followsLatest: false,
            anchorMetadata: originalTargets[0].restorationMetadata
        )

        XCTAssertEqual(originalTargets[0].semanticID, compactedTargets[0].semanticID)
        XCTAssertEqual(
            ChatResumeViewportResolver.destination(
                for: snapshot,
                availableTargets: ChatScrollTargetAvailability(targets: compactedTargets)
            ),
            .latest
        )
    }

    func testRestorationKeepsQualifiedAnchorWhenDuplicateMultiplicityIsUnchanged() {
        let liveTargets = ChatMessageScrollTargets.make(for: [
            ChatMessage(id: "live-first", role: .assistant, content: "Repeated", timestamp: "now"),
            ChatMessage(id: "live-second", role: .assistant, content: "Repeated", timestamp: "later")
        ])
        let storedTargets = ChatMessageScrollTargets.make(for: [
            ChatMessage(id: "stored-first", role: .assistant, content: "Repeated", timestamp: "stored"),
            ChatMessage(id: "stored-second", role: .assistant, content: "Repeated", timestamp: "stored later")
        ])
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: liveTargets[0].semanticID,
            followsLatest: false,
            anchorMetadata: liveTargets[0].restorationMetadata
        )

        XCTAssertEqual(
            ChatResumeViewportResolver.destination(
                for: snapshot,
                availableTargets: ChatScrollTargetAvailability(targets: storedTargets)
            ),
            .anchor(storedTargets[0].semanticID)
        )
    }

    func testQualifiedRestorationFallsBackForEmptyTranscript() {
        let target = ChatMessageScrollTargets.make(for: [
            ChatMessage(id: "live", role: .assistant, content: "Repeated", timestamp: "now")
        ])[0]
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: target.semanticID,
            followsLatest: false,
            anchorMetadata: target.restorationMetadata
        )

        XCTAssertEqual(
            ChatResumeViewportResolver.destination(
                for: snapshot,
                availableTargets: ChatScrollTargetAvailability(targets: [])
            ),
            .latest
        )
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
            tool: ToolActivity(id: "call-b", name: "write", input: "b.txt", output: nil, status: .running)
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

    func testToolSemanticAnchorsIgnoreProjectionSpecificInputPreviews() {
        let fullProjection = [
            ChatMessage(
                id: "live-1",
                role: .tool,
                content: "",
                timestamp: "now",
                tool: ToolActivity(
                    id: "call-1",
                    name: "read_file",
                    input: "A complete request body that only the durable transcript retains",
                    output: nil,
                    status: .running
                )
            ),
            ChatMessage(
                id: "live-2",
                role: .tool,
                content: "",
                timestamp: "later",
                tool: ToolActivity(
                    id: "call-2",
                    name: "read_file",
                    input: "A second complete request body",
                    output: nil,
                    status: .running
                )
            )
        ]
        let compactProjection = [
            ChatMessage(
                id: "stored-91",
                role: .tool,
                content: "",
                timestamp: "stored",
                tool: ToolActivity(
                    id: nil,
                    name: "read_file",
                    input: nil,
                    output: "first result",
                    status: .complete
                )
            ),
            ChatMessage(
                id: "stored-92",
                role: .tool,
                content: "",
                timestamp: "stored later",
                tool: ToolActivity(
                    id: nil,
                    name: "read_file",
                    input: "A second complete request…",
                    output: "second result",
                    status: .complete
                )
            )
        ]

        let fullIDs = ChatMessageScrollTargets.make(for: fullProjection).map(\.semanticID)
        let compactIDs = ChatMessageScrollTargets.make(for: compactProjection).map(\.semanticID)

        XCTAssertEqual(fullIDs, compactIDs)
        XCTAssertNotEqual(fullIDs[0], fullIDs[1])
    }

    func testTargetCacheDoesNotRegenerateForRepeatedUnchangedMessages() {
        let messages = [
            ChatMessage(id: "message-1", role: .assistant, content: "Stable", timestamp: "now")
        ]
        var cache = ChatMessageScrollTargetCache()

        XCTAssertEqual(cache.update(for: messages), .semanticsChanged)
        for _ in 0..<100 {
            XCTAssertEqual(cache.update(for: messages), .unchanged)
        }
    }

    func testTargetCacheRefreshesRenderingIdentityWithoutChangingScrollIdentity() {
        let live = [
            ChatMessage(
                id: "live-message",
                role: .assistant,
                content: "Same response",
                rawContent: "live projection",
                timestamp: "now",
                author: "Hermes"
            )
        ]
        let stored = [
            ChatMessage(
                id: "stored-message",
                role: .assistant,
                content: "Same response",
                rawContent: nil,
                timestamp: "stored timestamp",
                author: "assistant"
            )
        ]
        var cache = ChatMessageScrollTargetCache()

        XCTAssertEqual(cache.update(for: live), .semanticsChanged)
        let liveScrollID = cache.targets[0].semanticID

        XCTAssertEqual(cache.update(for: stored), .renderingChanged)
        XCTAssertEqual(cache.targets[0].id, "stored-message")
        XCTAssertEqual(cache.targets[0].semanticID, liveScrollID)
    }

    func testTargetCacheRegeneratesWhenMessageSemanticsChange() {
        var cache = ChatMessageScrollTargetCache()
        let original = [
            ChatMessage(id: "message", role: .assistant, content: "Before", timestamp: "now")
        ]
        let edited = [
            ChatMessage(id: "message", role: .assistant, content: "After", timestamp: "now")
        ]

        XCTAssertEqual(cache.update(for: original), .semanticsChanged)
        let originalScrollID = cache.targets[0].semanticID

        XCTAssertEqual(cache.update(for: edited), .semanticsChanged)
        XCTAssertNotEqual(cache.targets[0].semanticID, originalScrollID)
    }

    func testEqualCountProjectionReplacementReassertsLatestAfterCacheUpdate() {
        var cache = ChatMessageScrollTargetCache()
        cache.update(for: [
            ChatMessage(id: "live", role: .assistant, content: "Stable", timestamp: "now")
        ])

        let update = cache.update(for: [
            ChatMessage(id: "stored", role: .assistant, content: "Stable", timestamp: "stored")
        ])

        XCTAssertEqual(update, .renderingChanged)
        XCTAssertTrue(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update,
            followsLatest: true,
            hasPendingRestoration: false,
            hasNotificationHandoff: false
        ))
    }

    func testLatestReassertionYieldsToPendingRestoration() {
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: .semanticsChanged,
            followsLatest: true,
            hasPendingRestoration: true,
            hasNotificationHandoff: false
        ))
    }

    func testLatestReassertionYieldsToNotificationHandoff() {
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: .semanticsChanged,
            followsLatest: true,
            hasPendingRestoration: false,
            hasNotificationHandoff: true
        ))
    }

    func testEquivalentSessionIDsShareCanonicalIdentity() {
        let identity = ChatScrollSessionIdentity(
            profile: "alpha",
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

    func testEquivalentRawSessionIDsRemainSeparatedByProfile() {
        let identity = ChatScrollSessionIdentity(
            profile: "alpha",
            canonicalSessionID: "shared-id",
            equivalentSessionIDs: ["runtime-id"],
            isReconciling: false,
            settledRevision: 2
        )
        let alphaRuntime = ChatScrollSessionKey(profile: "alpha", sessionID: "runtime-id")
        let betaRuntime = ChatScrollSessionKey(profile: "beta", sessionID: "runtime-id")

        XCTAssertTrue(identity.contains(alphaRuntime))
        XCTAssertFalse(identity.contains(betaRuntime))
        XCTAssertFalse(identity.areEquivalent(alphaRuntime, betaRuntime))
    }

    func testResolverUsesCatalogCanonicalIDAndAliases() {
        let identity = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "runtime-id",
            catalog: [
                ChatScrollSessionCatalogIdentity(
                    profile: "alpha",
                    canonicalSessionID: "catalog-id",
                    alternateSessionIDs: ["runtime-id", "legacy-id"]
                )
            ],
            previousIdentity: .none,
            isReconciling: false
        )

        XCTAssertEqual(identity.canonicalSessionKey, ChatScrollSessionKey(
            profile: "alpha",
            sessionID: "catalog-id"
        ))
        XCTAssertTrue(identity.contains("runtime-id"))
        XCTAssertTrue(identity.contains("legacy-id"))
    }

    func testResolverTreatsUntaggedCatalogRowsAsBelongingToTheActiveProfile() {
        let identity = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "runtime-id",
            catalog: [
                ChatScrollSessionCatalogIdentity(
                    profile: "  ",
                    canonicalSessionID: "catalog-id",
                    alternateSessionIDs: ["runtime-id"]
                )
            ],
            previousIdentity: .none,
            isReconciling: false
        )

        XCTAssertEqual(identity.canonicalSessionKey, ChatScrollSessionKey(
            profile: "alpha",
            sessionID: "catalog-id"
        ))
    }

    func testResolverKeepsRuntimeRotationInTheExistingCanonicalIdentity() {
        let catalog = [
            ChatScrollSessionCatalogIdentity(
                profile: "alpha",
                canonicalSessionID: "catalog-id",
                alternateSessionIDs: ["runtime-old"]
            )
        ]
        let previous = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "runtime-old",
            catalog: catalog,
            previousIdentity: .none,
            isReconciling: false
        )

        let rotated = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "runtime-old",
            catalog: catalog,
            requestedSessionID: "catalog-id",
            resolvedSessionID: "runtime-new",
            previousIdentity: previous,
            isReconciling: true
        )

        XCTAssertEqual(rotated.canonicalSessionID, "catalog-id")
        XCTAssertTrue(rotated.areEquivalent("runtime-old", "runtime-new"))
    }

    func testResolverDropsPreviousAliasesForAnUnrelatedSession() {
        let catalog = [
            ChatScrollSessionCatalogIdentity(
                profile: "alpha",
                canonicalSessionID: "catalog-a",
                alternateSessionIDs: ["runtime-a"]
            ),
            ChatScrollSessionCatalogIdentity(
                profile: "alpha",
                canonicalSessionID: "catalog-b",
                alternateSessionIDs: ["runtime-b"]
            )
        ]
        let previous = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "runtime-a",
            catalog: catalog,
            previousIdentity: .none,
            isReconciling: false
        )

        let unrelated = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "runtime-b",
            catalog: catalog,
            previousIdentity: previous,
            isReconciling: false
        )

        XCTAssertEqual(unrelated.canonicalSessionID, "catalog-b")
        XCTAssertTrue(unrelated.contains("runtime-b"))
        XCTAssertFalse(unrelated.contains("runtime-a"))
    }

    func testResolverDoesNotCarryIdentityAcrossProfilesWithEqualRawIDs() {
        let previous = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "shared-runtime",
            catalog: [
                ChatScrollSessionCatalogIdentity(
                    profile: "alpha",
                    canonicalSessionID: "alpha-catalog",
                    alternateSessionIDs: ["shared-runtime"]
                )
            ],
            previousIdentity: .none,
            isReconciling: false
        )

        let switched = ChatScrollSessionIdentityResolver.resolve(
            profile: "beta",
            activeSessionID: "shared-runtime",
            catalog: [
                ChatScrollSessionCatalogIdentity(
                    profile: "alpha",
                    canonicalSessionID: "alpha-catalog",
                    alternateSessionIDs: ["shared-runtime"]
                ),
                ChatScrollSessionCatalogIdentity(
                    profile: "beta",
                    canonicalSessionID: "beta-catalog",
                    alternateSessionIDs: ["shared-runtime"]
                )
            ],
            previousIdentity: previous,
            isReconciling: false
        )

        XCTAssertEqual(switched.profile, "beta")
        XCTAssertEqual(switched.canonicalSessionID, "beta-catalog")
        XCTAssertFalse(switched.contains(ChatScrollSessionKey(
            profile: "alpha",
            sessionID: "shared-runtime"
        )))
        XCTAssertTrue(switched.contains(ChatScrollSessionKey(
            profile: "beta",
            sessionID: "shared-runtime"
        )))
    }

    func testResolverOwnsReconciliationStateAndSettledRevisionTransitions() {
        let settled = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "session",
            catalog: [],
            previousIdentity: .none,
            isReconciling: false
        )
        let reconciling = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "session",
            catalog: [],
            previousIdentity: settled,
            isReconciling: true
        )
        let resettled = ChatScrollSessionIdentityResolver.resolve(
            profile: "alpha",
            activeSessionID: "session",
            catalog: [],
            previousIdentity: reconciling,
            isReconciling: false,
            advanceSettledRevision: true
        )

        XCTAssertFalse(settled.isReconciling)
        XCTAssertEqual(settled.settledRevision, 0)
        XCTAssertTrue(reconciling.isReconciling)
        XCTAssertEqual(reconciling.settledRevision, 0)
        XCTAssertFalse(resettled.isReconciling)
        XCTAssertEqual(resettled.settledRevision, 1)
    }

    func testLatestSnapshotRemainsLatestRegardlessOfAvailableMessages() {
        XCTAssertEqual(
            ChatResumeViewportResolver.destination(
                for: .latest,
                availableTargets: .init(targets: [])
            ),
            .latest
        )
    }

    func testSessionKeysAreNormalized() {
        XCTAssertEqual(
            ChatScrollSessionKey(profile: "  Alpha  ", sessionID: "  session  "),
            ChatScrollSessionKey(profile: "alpha", sessionID: "session")
        )
        XCTAssertEqual(
            ChatScrollSessionKey(profile: "ALPHA", sessionID: "\n session \t"),
            ChatScrollSessionKey(profile: "alpha", sessionID: "session")
        )
    }

    func testWhitespaceOnlySessionKeysAreInvalid() {
        let key = ChatScrollSessionKey(profile: "default", sessionID: " \n\t ")

        XCTAssertFalse(key.isValid)
    }

    func testRestorationReanchorsBySourceMessageWhenContentProjectionChanges() {
        let original = ChatMessage(
            id: "stable-source-id",
            role: .assistant,
            content: "The response is still streaming",
            timestamp: "now"
        )
        let refreshed = ChatMessage(
            id: "stable-source-id",
            role: .assistant,
            content: "The response is still streaming, but now complete",
            timestamp: "stored"
        )
        let originalTarget = ChatMessageScrollTargets.make(for: [original])[0]
        let refreshedTarget = ChatMessageScrollTargets.make(for: [refreshed])[0]
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: originalTarget.semanticID,
            followsLatest: false,
            anchorMetadata: originalTarget.restorationMetadata,
            anchorSourceMessageID: originalTarget.id
        )

        let destination = ChatResumeViewportResolver.destination(
            for: snapshot,
            availableTargets: ChatScrollTargetAvailability(targets: [refreshedTarget])
        )

        XCTAssertEqual(destination, .anchor(refreshedTarget.semanticID))
    }

    func testRuntimeSessionIDPersistsAsCatalogCanonicalID() {
        let identity = ChatScrollSessionIdentity(
            profile: "default",
            canonicalSessionID: "catalog-session",
            equivalentSessionIDs: ["runtime-session"],
            isReconciling: true,
            settledRevision: 0
        )
        let catalog = [
            SessionSummary(
                id: "catalog-session",
                alternateIds: [],
                title: "Conversation",
                model: "Hermes",
                updatedLabel: "now",
                profile: "default",
                source: .chat,
                isActive: true,
                isArchived: false,
                lineageRootId: nil
            )
        ]

        XCTAssertEqual(
            ChatSessionPersistenceIdentity.canonicalID(
                for: "runtime-session",
                identity: identity,
                catalog: catalog
            ),
            "catalog-session"
        )
    }

}
