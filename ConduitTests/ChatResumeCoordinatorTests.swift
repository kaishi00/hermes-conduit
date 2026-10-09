import XCTest
@testable import Conduit

@MainActor
final class ChatResumeCoordinatorTests: XCTestCase {
    func testInactiveFreezeRejectsLateGeometryOverwrite() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let reading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)

        harness.coordinator.recordViewport(reading, for: key)
        harness.coordinator.freezeViewport()
        harness.coordinator.recordViewport(.latest, for: key)
        harness.coordinator.flush()

        XCTAssertEqual(harness.store.snapshot(for: key), reading)
    }

    func testContinueRequestIsEmittedOnlyAfterReconciliationSettles() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let reading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
        harness.store.save(reading, for: key, at: Date())
        harness.store.setLastSessionID("stored-a", for: "default")

        _ = harness.coordinator.selectTarget(
            in: [session("stored-b"), session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        XCTAssertNil(harness.coordinator.pendingRestoration)

        let request = harness.coordinator.reconciliationSettled(sessionKey: key, pendingClarifyMessageID: nil)
        XCTAssertEqual(request?.destination, .snapshot(reading))
    }

    func testPendingClarifyOverridesSavedViewportAndRetainsItAsFallback() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let reading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
        harness.store.save(reading, for: key, at: Date())
        harness.store.setLastSessionID("stored-a", for: "default")

        _ = harness.coordinator.selectTarget(
            in: [session("stored-b"), session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )

        let request = harness.coordinator.reconciliationSettled(
            sessionKey: key,
            pendingClarifyMessageID: "clarify-pending"
        )
        XCTAssertEqual(
            request?.destination,
            .pendingClarify(messageID: "clarify-pending", fallbackSnapshot: reading)
        )
    }

    func testPendingClarifyMessageIDSelectsMostRecentAnswerableQuestion() {
        let messages = [
            clarifyMessage("first-pending", status: .pending),
            clarifyMessage("submitting", status: .submitting),
            clarifyMessage("answered", status: .answered),
            clarifyMessage("expired", status: .expired),
            clarifyMessage("retryable", status: .error)
        ]

        XCTAssertEqual(
            ChatResumeCoordinator.pendingClarifyMessageID(in: messages),
            "retryable"
        )
        XCTAssertNil(ChatResumeCoordinator.pendingClarifyMessageID(in: [
            clarifyMessage("submitting", status: .submitting),
            clarifyMessage("answered", status: .answered)
        ]))
    }

    func testPendingClarifyDoesNotOverrideLatestActivityPreference() throws {
        let harness = makeHarness()
        harness.coordinator.setBehavior(.latestActivity)
        let selected = harness.coordinator.selectTarget(
            in: [session("stored-b"), session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let selectedID = try XCTUnwrap(selected).id

        let request = harness.coordinator.reconciliationSettled(
            sessionKey: .init(profile: "default", sessionID: selectedID),
            pendingClarifyMessageID: "clarify-pending"
        )

        XCTAssertEqual(
            request?.destination,
            .latest
        )
    }

    func testMixedExpiredAndPendingClarifyBatchUsesQuestionAnswerability() {
        let message = ChatMessage(
            id: "clarify-mixed",
            role: .clarify,
            content: "Two questions",
            timestamp: "2026-01-01T00:00:00Z",
            clarify: ClarifyActivity(
                requestId: "request-mixed",
                questions: [
                    ClarifyQuestion(id: "expired", question: "Old?", choices: [], status: .expired),
                    ClarifyQuestion(id: "pending", question: "New?", choices: [], status: .pending)
                ]
            )
        )

        XCTAssertEqual(message.clarify?.status, .expired)
        XCTAssertEqual(message.clarify?.presentationStatus, .pending)
        XCTAssertEqual(ChatResumeCoordinator.pendingClarifyMessageID(in: [message]), "clarify-mixed")
    }

    func testFullyExpiredClarifyBatchIsNotAnswerable() {
        let message = ChatMessage(
            id: "clarify-expired",
            role: .clarify,
            content: "Expired request",
            timestamp: "2026-01-01T00:00:00Z",
            clarify: ClarifyActivity(
                requestId: "request-expired",
                questions: [
                    ClarifyQuestion(id: "q1", question: "Old?", choices: [], status: .pending)
                ],
                isExpired: true
            )
        )

        XCTAssertNil(ChatResumeCoordinator.pendingClarifyMessageID(in: [message]))
    }

    func testExplicitActionCancelsAnOlderGeneration() throws {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key, pendingClarifyMessageID: nil))

        harness.coordinator.cancelViewportRestoration()

        XCTAssertFalse(harness.coordinator.isCurrent(generation: request.generation))
    }

    func testLatestModeSelectsNewestAndEmitsLatest() throws {
        let harness = makeHarness()
        harness.coordinator.setBehavior(.latestActivity)
        let selected = harness.coordinator.selectTarget(
            in: [session("stored-b"), session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let selectedID = try XCTUnwrap(selected).id
        let request = harness.coordinator.reconciliationSettled(
            sessionKey: .init(profile: "default", sessionID: selectedID)
        )

        XCTAssertEqual(selected?.id, "stored-b")
        XCTAssertEqual(request?.destination, .latest)
    }

    func testColdLaunchRestoresPersistedSnapshot() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let snapshot = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
        harness.store.save(snapshot, for: key, at: Date())
        harness.store.setLastSessionID("stored-a", for: "default")
        harness.store.flush()
        let recreated = ChatResumeCoordinator(store: ChatResumeStore(defaults: harness.defaults))

        _ = recreated.selectTarget(
            in: [session("stored-b"), session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: nil
        )

        XCTAssertEqual(recreated.reconciliationSettled(sessionKey: key, pendingClarifyMessageID: nil)?.destination, .snapshot(snapshot))
    }

    func testCompletingCurrentRequestAllowsViewportWritesAgain() throws {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key, pendingClarifyMessageID: nil))
        harness.coordinator.completeRestoration(generation: request.generation)
        harness.coordinator.recordViewport(.latest, for: key)
        harness.coordinator.flush()

        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
    }

    func testAbandoningCurrentRequestAllowsViewportWritesAgain() throws {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key, pendingClarifyMessageID: nil))

        harness.coordinator.abandonRestoration(generation: request.generation)
        harness.coordinator.recordViewport(.latest, for: key)
        harness.coordinator.flush()

        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
    }

    func testMissingContinueTargetSelectsNewestChat() {
        let harness = makeHarness()
        harness.store.setLastSessionID("deleted-a", for: "default")

        let selected = harness.coordinator.selectTarget(
            in: [session("stored-b")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "deleted-a"
        )

        XCTAssertEqual(selected?.id, "stored-b")
    }

    func testMissingContinueTargetEmitsLatestDespiteFallbackSnapshot() {
        let harness = makeHarness()
        let fallbackKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-b")
        let oldReading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
        harness.store.setLastSessionID("deleted-a", for: "default")
        harness.store.save(oldReading, for: fallbackKey, at: Date())

        let selected = harness.coordinator.selectTarget(
            in: [session("stored-b")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "deleted-a"
        )
        let request = harness.coordinator.reconciliationSettled(sessionKey: fallbackKey, pendingClarifyMessageID: nil)

        XCTAssertEqual(selected?.id, "stored-b")
        XCTAssertEqual(request?.destination, .latest)
    }

    func testAutomaticNilTargetKeepsViewportFrozenUntilCreatedSessionSettles() {
        let harness = makeHarness()
        let oldKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let oldReading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
        harness.coordinator.recordViewport(oldReading, for: oldKey)
        harness.coordinator.freezeViewport()

        let missingTarget = harness.coordinator.selectTarget(
            in: [],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        XCTAssertNil(missingTarget)

        harness.coordinator.recordViewport(.latest, for: oldKey)
        let created = session("stored-created")
        _ = harness.coordinator.selectTarget(
            in: [created],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: nil
        )
        let createdKey = ChatScrollSessionKey(profile: "default", sessionID: created.id)
        let request = harness.coordinator.reconciliationSettled(sessionKey: createdKey, pendingClarifyMessageID: nil)
        harness.coordinator.flush()

        XCTAssertEqual(harness.store.snapshot(for: oldKey), oldReading)
        XCTAssertEqual(request?.destination, .latest)
    }

    func testViewportUpdatePersistsOnlyAfterExplicitFlush() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let reading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)

        harness.coordinator.recordViewport(reading, for: key)

        XCTAssertNil(ChatResumeStore(defaults: harness.defaults).snapshot(for: key))

        harness.coordinator.flush()

        XCTAssertEqual(ChatResumeStore(defaults: harness.defaults).snapshot(for: key), reading)
    }

    func testPreservingCurrentSessionDoesNotCreateARestorationRequest() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")

        let selected = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .preserveCurrent,
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(selected?.id, "stored-a")
        XCTAssertNil(harness.coordinator.reconciliationSettled(sessionKey: key, pendingClarifyMessageID: nil))
    }

    func testRecoverySyncPreservesCurrentWhileAutomaticReturnUsesPreference() {
        let harness = makeHarness()
        harness.coordinator.setBehavior(.latestActivity)
        let catalog = [session("stored-b"), session("stored-a")]

        let automatic = harness.coordinator.selectTarget(
            in: catalog,
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        harness.coordinator.cancelViewportRestoration()
        let recovery = harness.coordinator.selectTarget(
            in: catalog,
            profile: "default",
            purpose: .preserveCurrent,
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(automatic?.id, "stored-b")
        XCTAssertEqual(recovery?.id, "stored-a")
    }

    func testChangingBehaviorCancelsCurrentRequestBeforeSavingPreference() throws {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key, pendingClarifyMessageID: nil))

        harness.coordinator.setBehavior(.latestActivity)

        XCTAssertFalse(harness.coordinator.isCurrent(generation: request.generation))
        XCTAssertEqual(harness.store.behavior, .latestActivity)
    }

    func testClearResumeStateCancelsRequestAndPreservesBehavior() throws {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        harness.coordinator.setBehavior(.latestActivity)
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
        harness.coordinator.recordViewport(.latest, for: key)
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key, pendingClarifyMessageID: nil))

        harness.coordinator.clearResumeState()

        XCTAssertFalse(harness.coordinator.isCurrent(generation: request.generation))
        XCTAssertEqual(harness.coordinator.behavior, .latestActivity)
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
        XCTAssertNil(harness.store.snapshot(for: key))
    }

    func testMigratingSnapshotUsesStoreMigration() {
        let harness = makeHarness()
        let oldKey = ChatScrollSessionKey(profile: "default", sessionID: "runtime-a")
        let newKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let snapshot = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
        harness.coordinator.recordViewport(snapshot, for: oldKey)

        harness.coordinator.migrateSnapshot(from: oldKey, to: newKey)

        XCTAssertNil(harness.store.snapshot(for: oldKey))
        XCTAssertEqual(harness.store.snapshot(for: newKey), snapshot)
    }

    func testAbandonPendingAutomaticSyncUnfreezesViewport() {
        let harness = makeHarness()
        let pendingKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let otherKey = ChatScrollSessionKey(profile: "default", sessionID: "other")

        // Simulate selectTarget with a valid target → viewport frozen.
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        // recordViewport should be a no-op (frozen).
        harness.coordinator.recordViewport(.latest, for: otherKey)
        XCTAssertNil(harness.store.snapshot(for: otherKey))

        // Abandon: unfreeze without canceling automatic work epoch.
        harness.coordinator.abandonPendingAutomaticSync()

        // Now recordViewport should work again.
        harness.coordinator.recordViewport(.latest, for: otherKey)
        XCTAssertEqual(harness.store.snapshot(for: otherKey), .latest)
    }

    func testReconciliationSettledWithMismatchedKeyClearsPendingViaCaller() {
        let harness = makeHarness()
        let wrongKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-b")

        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        // recordViewport is a no-op while frozen.
        harness.coordinator.recordViewport(.latest, for: wrongKey)
        XCTAssertNil(harness.store.snapshot(for: wrongKey))

        // Settle with the wrong key → nil. pendingSessionKey stays set
        // so the caller can detect the mismatch and clean up.
        XCTAssertNil(harness.coordinator.reconciliationSettled(sessionKey: wrongKey, pendingClarifyMessageID: nil))

        // Caller detects pending key and unfreezes.
        harness.coordinator.abandonPendingAutomaticSyncIfPending()

        // Now recordViewport should work again.
        harness.coordinator.recordViewport(.latest, for: wrongKey)
        XCTAssertEqual(harness.store.snapshot(for: wrongKey), .latest)
    }

    func testDeletingStagedConversationBeforePublicationPreventsRestoration() {
        // Automatic return stages B (pendingSessionKey, viewport frozen).
        // Deleting B must invalidate the staged work: settling afterwards can
        // publish nothing for B, the viewport is not stuck frozen, and B's
        // persisted state is gone while unrelated state survives.
        let harness = makeHarness()
        let keyB = ChatScrollSessionKey(profile: "default", sessionID: "stored-b")
        let keyOther = ChatScrollSessionKey(profile: "default", sessionID: "other")
        let reading = ChatScrollSnapshot(anchorMessageID: "anchor-b", followsLatest: false)
        harness.store.save(reading, for: keyB, at: Date())
        harness.store.setLastSessionID("stored-b", for: "default")
        harness.store.setLastSessionID("other", for: "work")

        _ = harness.coordinator.selectTarget(
            in: [session("stored-a"), session("stored-b")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-b"
        )
        XCTAssertNil(harness.coordinator.pendingRestoration)
        // The staged key freezes recording.
        harness.coordinator.recordViewport(.latest, for: keyOther)
        XCTAssertNil(harness.store.snapshot(for: keyOther))

        harness.coordinator.removeSessions(profile: "default", sessionIDs: ["stored-b"])

        XCTAssertNil(harness.store.snapshot(for: keyB))
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
        XCTAssertEqual(
            harness.store.lastSessionID(for: "work"),
            "other",
            "Deletion is scoped: another profile's pointer survives"
        )
        // Settling the (now-deleted) conversation can produce no restoration.
        XCTAssertNil(harness.coordinator.reconciliationSettled(sessionKey: keyB, pendingClarifyMessageID: nil))
        // The viewport must not be left permanently frozen.
        harness.coordinator.recordViewport(.latest, for: keyOther)
        XCTAssertEqual(harness.store.snapshot(for: keyOther), .latest)
    }

    func testDeletingPublishedConversationInvalidatesItsRestorationRequest() throws {
        // After a restoration request for B is published, deleting B must
        // invalidate it: the stale generation is no longer current, and
        // completion/abandon of that generation cannot resurrect it.
        let harness = makeHarness()
        let keyB = ChatScrollSessionKey(profile: "default", sessionID: "stored-b")
        let reading = ChatScrollSnapshot(anchorMessageID: "anchor-b", followsLatest: false)
        harness.store.save(reading, for: keyB, at: Date())
        harness.store.setLastSessionID("stored-b", for: "default")

        _ = harness.coordinator.selectTarget(
            in: [session("stored-b")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-b"
        )
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: keyB, pendingClarifyMessageID: nil))

        harness.coordinator.removeSessions(profile: "default", sessionIDs: ["stored-b"])

        XCTAssertFalse(
            harness.coordinator.isCurrent(generation: request.generation),
            "The deleted conversation's published restoration is no longer current"
        )
        harness.coordinator.completeRestoration(generation: request.generation)
        harness.coordinator.abandonRestoration(generation: request.generation)
        XCTAssertNil(
            harness.coordinator.pendingRestoration,
            "A stale generation cannot resurrect the deleted request"
        )
        // Viewport recording works again for the surviving conversation.
        let keyOther = ChatScrollSessionKey(profile: "default", sessionID: "other")
        harness.coordinator.recordViewport(.latest, for: keyOther)
        XCTAssertEqual(harness.store.snapshot(for: keyOther), .latest)
    }

    func testDeletingUnrelatedConversationKeepsPendingRestoration() throws {
        // Deleting A while restoration B is staged+published leaves B's
        // pending work — and B's persisted state — fully intact.
        let harness = makeHarness()
        let keyA = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let keyB = ChatScrollSessionKey(profile: "default", sessionID: "stored-b")
        let readingB = ChatScrollSnapshot(anchorMessageID: "anchor-b", followsLatest: false)
        harness.store.save(readingB, for: keyB, at: Date())
        harness.store.setLastSessionID("stored-b", for: "default")

        _ = harness.coordinator.selectTarget(
            in: [session("stored-a"), session("stored-b")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-b"
        )
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: keyB, pendingClarifyMessageID: nil))

        harness.coordinator.removeSessions(profile: "default", sessionIDs: ["stored-a"])

        XCTAssertTrue(harness.coordinator.isCurrent(generation: request.generation))
        XCTAssertNotNil(harness.coordinator.pendingRestoration)
        XCTAssertEqual(harness.store.snapshot(for: keyB), readingB)
    }

    private func makeHarness() -> (
        coordinator: ChatResumeCoordinator,
        store: ChatResumeStore,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "ChatResumeCoordinatorTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = ChatResumeStore(defaults: defaults)
        return (ChatResumeCoordinator(store: store), store, defaults, suite)
    }

    private func clarifyMessage(
        _ id: String,
        status: ClarifyQuestion.Status
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .clarify,
            content: "",
            timestamp: "",
            clarify: ClarifyActivity(
                requestId: id,
                question: "Continue?",
                choices: [],
                status: status
            )
        )
    }

    private func session(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}
