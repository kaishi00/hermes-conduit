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

    func testNonLatestRestorationWaitsForReconciliationToSettleAtNewRevision() {
        let activeIdentity = ChatScrollSessionIdentity(
            profile: "default",
            canonicalSessionID: "catalog-id",
            equivalentSessionIDs: ["runtime-id"],
            isReconciling: true,
            settledRevision: 7
        )
        let gate = ChatScrollRestorationGate(observing: activeIdentity)

        XCTAssertFalse(gate.allowsNonLatestRestoration(using: activeIdentity))
        XCTAssertFalse(gate.allowsNonLatestRestoration(using: ChatScrollSessionIdentity(
            profile: "default",
            canonicalSessionID: "catalog-id",
            equivalentSessionIDs: ["runtime-id"],
            isReconciling: false,
            settledRevision: 7
        )))
        XCTAssertTrue(gate.allowsNonLatestRestoration(using: ChatScrollSessionIdentity(
            profile: "default",
            canonicalSessionID: "catalog-id",
            equivalentSessionIDs: ["runtime-id"],
            isReconciling: false,
            settledRevision: 8
        )))
    }

    func testNonLatestRestorationCanUseCurrentRevisionWhenNoReconciliationIsExpected() {
        let settledIdentity = ChatScrollSessionIdentity(
            profile: "default",
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
        let sessionA = ChatScrollSessionKey(profile: "default", sessionID: "session-a")
        let sessionB = ChatScrollSessionKey(profile: "default", sessionID: "session-b")
        store.save(
            ChatScrollSnapshot(anchorMessageID: "a-3", followsLatest: false),
            for: sessionA
        )
        store.save(
            ChatScrollSnapshot(anchorMessageID: "b-1", followsLatest: false),
            for: sessionB
        )

        XCTAssertEqual(store.snapshot(for: sessionA)?.anchorMessageID, "a-3")
        XCTAssertEqual(store.snapshot(for: sessionB)?.anchorMessageID, "b-1")
    }

    func testSnapshotsWithEqualRawSessionIDsAreIsolatedByProfile() {
        var store = ChatScrollStateStore()
        let alpha = ChatScrollSessionKey(profile: "alpha", sessionID: "shared-session")
        let beta = ChatScrollSessionKey(profile: "beta", sessionID: "shared-session")
        store.save(
            ChatScrollSnapshot(anchorMessageID: "alpha-anchor", followsLatest: false),
            for: alpha
        )
        store.save(
            ChatScrollSnapshot(anchorMessageID: "beta-anchor", followsLatest: false),
            for: beta
        )

        XCTAssertEqual(store.snapshot(for: alpha)?.anchorMessageID, "alpha-anchor")
        XCTAssertEqual(store.snapshot(for: beta)?.anchorMessageID, "beta-anchor")
    }

    func testRestorationKeepsAnchorWhenMessageStillExists() {
        var store = ChatScrollStateStore()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "session")
        let expected = ChatScrollSnapshot(anchorMessageID: "message-4", followsLatest: false)
        store.save(expected, for: key)

        XCTAssertEqual(
            store.restoration(
                for: key,
                availableMessageIDs: ["message-3", "message-4", "message-5"]
            ),
            expected
        )
    }

    func testRestorationFallsBackToLatestWhenAnchorDisappears() {
        var store = ChatScrollStateStore()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "session")
        store.save(
            ChatScrollSnapshot(anchorMessageID: "deleted", followsLatest: false),
            for: key
        )

        XCTAssertEqual(
            store.restoration(for: key, availableMessageIDs: ["message-1"]),
            .latest
        )
    }

    func testSettledPendingRestorationFallsBackToLatestForEmptyTranscript() {
        var store = ChatScrollStateStore()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "session")
        let reconcilingIdentity = ChatScrollSessionIdentity(
            profile: "default",
            canonicalSessionID: "session",
            equivalentSessionIDs: [],
            isReconciling: true,
            settledRevision: 3
        )
        let settledIdentity = ChatScrollSessionIdentity(
            profile: "default",
            canonicalSessionID: "session",
            equivalentSessionIDs: [],
            isReconciling: false,
            settledRevision: 4
        )
        let snapshot = ChatScrollSnapshot(anchorMessageID: "deleted", followsLatest: false)
        store.save(snapshot, for: key)
        let pending = ChatScrollPendingRestoration(
            sessionKey: key,
            snapshot: snapshot,
            gate: ChatScrollRestorationGate(observing: reconcilingIdentity)
        )

        XCTAssertEqual(
            ChatScrollRestorationResolver.decision(
                for: pending,
                identity: settledIdentity,
                activeSessionKey: key,
                store: store,
                availableMessageIDs: []
            ),
            .latest
        )
    }

    func testPendingRestorationCancelsAcrossProfilesWithEqualSessionIDs() {
        var store = ChatScrollStateStore()
        let alphaKey = ChatScrollSessionKey(profile: "alpha", sessionID: "shared-session")
        let betaKey = ChatScrollSessionKey(profile: "beta", sessionID: "shared-session")
        let alphaIdentity = ChatScrollSessionIdentity(
            profile: "alpha",
            canonicalSessionID: "shared-session",
            equivalentSessionIDs: [],
            isReconciling: false,
            settledRevision: 1
        )
        let betaIdentity = ChatScrollSessionIdentity(
            profile: "beta",
            canonicalSessionID: "shared-session",
            equivalentSessionIDs: [],
            isReconciling: false,
            settledRevision: 1
        )
        let snapshot = ChatScrollSnapshot(anchorMessageID: "alpha-anchor", followsLatest: false)
        store.save(snapshot, for: alphaKey)
        let pending = ChatScrollPendingRestoration(
            sessionKey: alphaKey,
            snapshot: snapshot,
            gate: ChatScrollRestorationGate(observing: alphaIdentity)
        )

        XCTAssertEqual(
            ChatScrollRestorationResolver.decision(
                for: pending,
                identity: betaIdentity,
                activeSessionKey: betaKey,
                store: store,
                availableMessageIDs: ["alpha-anchor"]
            ),
            .cancel
        )
    }

    func testLatestSnapshotRemainsLatestRegardlessOfAvailableMessages() {
        var store = ChatScrollStateStore()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "session")
        store.save(ChatScrollSnapshot.latest, for: key)

        XCTAssertEqual(
            store.restoration(for: key, availableMessageIDs: []),
            .latest
        )
    }

    func testSessionKeysAreTrimmedForSaveAndLookup() {
        var store = ChatScrollStateStore()
        let expected = ChatScrollSnapshot(anchorMessageID: "message-1", followsLatest: false)
        store.save(
            expected,
            for: ChatScrollSessionKey(profile: "  Alpha  ", sessionID: "  session  ")
        )

        XCTAssertEqual(
            store.snapshot(for: ChatScrollSessionKey(profile: "alpha", sessionID: "session")),
            expected
        )
        XCTAssertEqual(
            store.snapshot(for: ChatScrollSessionKey(profile: "ALPHA", sessionID: "\n session \t")),
            expected
        )
    }

    func testWhitespaceOnlySessionKeysAreIgnored() {
        var store = ChatScrollStateStore()
        let key = ChatScrollSessionKey(profile: "default", sessionID: " \n\t ")
        store.save(ChatScrollSnapshot.latest, for: key)

        XCTAssertNil(store.snapshot(for: key))
    }
}
