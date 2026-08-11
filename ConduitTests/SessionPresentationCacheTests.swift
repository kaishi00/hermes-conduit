import Foundation
import XCTest
@testable import Conduit

/// Tests SessionPresentationCache.merge — the logic that decides which
/// presentation metadata (timestamps, tool previews, attachments) survives
/// a reconnect or session reopen. Getting this wrong means messages lose
/// their timestamps or tool calls lose their input text.
@MainActor
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
        defer { cache.clear(profile: profile) }

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
        defer { cache.clear(profile: profile) }

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: false
        )

        XCTAssertFalse(merged.contains { $0.role == .clarify },
                       "Clarification should not be restored when includePendingClarifications is false")
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
        defer { cache.clear(profile: profile) }

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )

        XCTAssertFalse(merged.contains { $0.role == .clarify },
                       "Answered clarification should not be restored as pending")
    }

    func testMergeRestoresClarificationWhenRunningIsNil() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-clarify-nil-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-nil",
            question: "Pick?",
            choices: [ClarifyChoice(label: "X", value: "x")],
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-nil",
                role: .clarify,
                content: "Pick?",
                timestamp: "2024-01-01",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        // Hermes versions that omit `running` can still be paused on this
        // clarification request. Nil must remain eligible for restoration;
        // explicit false is the only resolved/idle signal.
        let shouldRestore = AppState.shouldRestorePendingCards(running: nil)
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: shouldRestore
        )

        XCTAssertTrue(merged.contains { $0.role == .clarify },
                      "Clarification should be restored when running state is omitted (nil)")
    }

    // MARK: - Merge: pending approval restoration

    func testMergeRestoresPendingApprovalWhenRequested() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-approval-\(UUID().uuidString)"
        let profile = "test"

        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "rm -rf /tmp",
            description: "Delete temp files",
            choices: ["once", "session", "always", "deny"],
            allowPermanent: true,
            smartDenied: false,
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: "Delete temp files",
                timestamp: "2024-01-01T10:00:00Z",
                approval: approval
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        // Gateway resume omits the approval card
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: true
        )

        let restoredApproval = merged.first { $0.role == .approval }
        XCTAssertNotNil(restoredApproval, "Pending approval should be restored from cache")
        XCTAssertEqual(restoredApproval?.approval?.sessionId, sessionId)
        XCTAssertEqual(restoredApproval?.approval?.status, .pending)
    }

    func testMergeDoesNotRestoreApprovalWhenNotRequested() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-approval-off-\(UUID().uuidString)"
        let profile = "test"

        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: nil,
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: "List files",
                timestamp: "2024-01-01",
                approval: approval
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: false
        )

        XCTAssertFalse(merged.contains { $0.role == .approval },
                       "Approval should not be restored when includePendingApprovals is false")
    }

    // MARK: - restorePendingCards derivation

    func testShouldRestorePendingCardsWhenRunningIsTrue() {
        XCTAssertTrue(AppState.shouldRestorePendingCards(running: true),
                      "Must restore pending cards when gateway confirms turn is active")
    }

    func testShouldNotRestorePendingCardsWhenRunningIsFalse() {
        XCTAssertFalse(AppState.shouldRestorePendingCards(running: false),
                       "Must not restore pending cards when gateway reports turn is inactive")
    }

    func testShouldRestorePendingCardsWhenRunningIsNil() {
        // Hermes can omit `running` while a turn is paused on a user decision.
        // Only an explicit false is proof that the turn is no longer active.
        XCTAssertTrue(AppState.shouldRestorePendingCards(running: nil),
                      "Must restore pending cards when gateway omits running state")
    }

    // MARK: - Save preserves restored pending cards

    func testSavePreservesRestoredClarificationCard() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-save-clarify-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-save",
            question: "Which?",
            choices: [ClarifyChoice(label: "A", value: "a")],
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-save",
                role: .clarify,
                content: "Which?",
                timestamp: "2024-01-01T10:00:00Z",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        // Merge restores the pending card
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )
        XCTAssertTrue(merged.contains { $0.role == .clarify },
                      "Card should be restored from cache")

        // Save the merged result (as applyResume does when running == true)
        cache.save(merged, profile: profile, sessionIDs: [sessionId])

        // Re-merge: the card should survive because save persisted it
        let remerged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )
        XCTAssertTrue(remerged.contains { $0.role == .clarify },
                      "Restored clarification card must survive a save-then-merge cycle")
    }

    func testSavePreservesRestoredApprovalCard() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-save-approval-\(UUID().uuidString)"
        let profile = "test"

        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "session", "always", "deny"],
            allowPermanent: true,
            smartDenied: false,
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "approval-save",
                role: .approval,
                content: "List files",
                timestamp: "2024-01-01T10:00:00Z",
                approval: approval
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        // Merge restores the pending card
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: true
        )
        XCTAssertTrue(merged.contains { $0.role == .approval },
                      "Card should be restored from cache")

        // Save the merged result (as applyResume does when running == true)
        cache.save(merged, profile: profile, sessionIDs: [sessionId])

        // Re-merge: the card should survive
        let remerged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: true
        )
        XCTAssertTrue(remerged.contains { $0.role == .approval },
                      "Restored approval card must survive a save-then-merge cycle")
    }

    // MARK: - AppState resume integration

    func testApplyChatResumeRestoresPendingClarificationWhenRunningIsNil() {
        let suiteName = "conduit.tests.session-presentation-clarify-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-clarify-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-apply-resume",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "clarify-req-apply-resume",
                role: .clarify,
                content: clarify.question,
                timestamp: "2024-01-01",
                clarify: clarify
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertEqual(appState.messages.first?.clarify?.requestId, clarify.requestId)
        XCTAssertEqual(appState.messages.first?.clarify?.status, .pending)
        XCTAssertEqual(appState.turnState, TurnState.running,
                       "A restored pending clarification must keep the composer answerable")
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == clarify.requestId },
            "An omitted running state must retain an unconfirmed clarification card for the next foreground cycle"
        )
    }

    func testApplyChatResumeRestoresPendingApprovalWhenRunningIsNil() {
        let suiteName = "conduit.tests.session-presentation-approval-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-approval-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: approval.description,
                timestamp: "2024-01-01",
                approval: approval
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertEqual(appState.messages.first?.approval?.sessionId, sessionId)
        XCTAssertEqual(appState.messages.first?.approval?.status, .pending)
        XCTAssertEqual(appState.turnState, TurnState.running,
                       "A restored pending approval must keep the composer answerable")
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingApprovals: true
            ).contains { $0.approval?.sessionId == sessionId },
            "An omitted running state must retain an unconfirmed approval card for the next foreground cycle"
        )
    }

    func testApplyChatResumePreservesGatewayPendingDecisionWhenRunningIsNil() {
        let suiteName = "conduit.tests.session-presentation-gateway-pending-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-gateway-pending-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-gateway-pending",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        let gatewayMessage = ChatMessage(
            id: "clarify-gateway-pending",
            role: .clarify,
            content: clarify.question,
            timestamp: "2024-01-01",
            clarify: clarify
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        let persisted = cache.merge(
            [],
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )
        XCTAssertTrue(
            persisted.contains { $0.clarify?.requestId == clarify.requestId },
            "A pending decision sent by the gateway is authoritative and must remain cached"
        )
        XCTAssertEqual(appState.turnState, TurnState.running)
    }

    func testApplyChatResumePersistsGatewayMessagesAndRetainsRestoredCardsWhenRunningIsNil() {
        let suiteName = "conduit.tests.session-presentation-cache-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-cache-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: approval.description,
                timestamp: "2024-01-01",
                approval: approval
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let gatewayMessage = ChatMessage(
            id: "gateway-user",
            role: .user,
            content: "Fresh transcript row",
            timestamp: ""
        )
        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        let persisted = cache.merge(
            [],
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true,
            includePendingApprovals: true
        )
        XCTAssertTrue(persisted.contains { $0.approval?.sessionId == sessionId },
                      "An omitted running state must retain a restored pending card")
        XCTAssertEqual(
            cache.merge([gatewayMessage], profile: profile, sessionIDs: [sessionId]).first?.content,
            gatewayMessage.content
        )
    }

    func testApplyChatResumeDoesNotRestorePendingCardsWhenRunningIsFalse() {
        let suiteName = "conduit.tests.session-presentation-settled-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-settled-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-settled",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "clarify-settled",
                role: .clarify,
                content: clarify.question,
                timestamp: "2024-01-01",
                clarify: clarify
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        ))

        XCTAssertFalse(appState.messages.contains { $0.clarify?.requestId == clarify.requestId })
        XCTAssertEqual(appState.turnState, TurnState.idle)
        XCTAssertFalse(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == clarify.requestId },
            "An explicitly settled resume must remove the cached pending card"
        )
    }

    func testApplyChatResumeSuppressesCachedPendingApprovalWhenGatewayResolvedIt() {
        let suiteName = "conduit.tests.session-presentation-resolved-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-resolved-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let pendingApproval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: pendingApproval.description,
                timestamp: "2024-01-01",
                approval: pendingApproval
            )
        ], profile: profile, sessionIDs: [sessionId])
        let resolvedApproval = ApprovalActivity(
            sessionId: sessionId,
            command: pendingApproval.command,
            description: pendingApproval.description,
            choices: pendingApproval.choices,
            allowPermanent: pendingApproval.allowPermanent,
            smartDenied: pendingApproval.smartDenied,
            status: .approved,
            choice: "once"
        )
        let gatewayMessage = ChatMessage(
            id: "approval-\(sessionId)",
            role: .approval,
            content: resolvedApproval.description,
            timestamp: "2024-01-02",
            approval: resolvedApproval
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertEqual(
            appState.messages.filter { $0.approval?.sessionId == sessionId }.count,
            1,
            "A resolved gateway approval must replace, not coexist with, the cached pending card"
        )
        XCTAssertEqual(
            appState.messages.first?.approval?.status,
            ApprovalActivity.Status.approved
        )
        XCTAssertFalse(AppState.hasPendingDecision(in: appState.messages))
        XCTAssertFalse(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingApprovals: true
            ).contains { $0.approval?.status == .pending }
        )
    }
}
