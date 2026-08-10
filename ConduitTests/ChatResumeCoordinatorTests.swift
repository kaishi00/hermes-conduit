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

        let request = harness.coordinator.reconciliationSettled(sessionKey: key)
        XCTAssertEqual(request?.destination, .snapshot(reading))
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
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key))

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

        XCTAssertEqual(recreated.reconciliationSettled(sessionKey: key)?.destination, .snapshot(snapshot))
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
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key))
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
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key))

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
        let request = harness.coordinator.reconciliationSettled(sessionKey: fallbackKey)

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
        let request = harness.coordinator.reconciliationSettled(sessionKey: createdKey)
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
        XCTAssertNil(harness.coordinator.reconciliationSettled(sessionKey: key))
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
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key))

        harness.coordinator.setBehavior(.latestActivity)

        XCTAssertFalse(harness.coordinator.isCurrent(generation: request.generation))
        XCTAssertEqual(harness.store.behavior, .latestActivity)
    }

    func testClearResumeStateCancelsRequestAndPreservesBehavior() throws {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        harness.coordinator.setBehavior(.latestActivity)
        harness.coordinator.rememberSessionID("stored-a", for: "default")
        harness.coordinator.recordViewport(.latest, for: key)
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = try XCTUnwrap(harness.coordinator.reconciliationSettled(sessionKey: key))

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

    func testReconciliationSettledWithMismatchedKeyClearsPendingButDoesNotUnfreeze() {
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

        // Settle with the wrong key → nil. Pending is cleared but freeze
        // stays intact (avoids `.latest` overwriting old readings during
        // ID remapping). Use abandonPendingAutomaticSync to unfreeze.
        XCTAssertNil(harness.coordinator.reconciliationSettled(sessionKey: wrongKey))

        // Still frozen — recordViewport is still a no-op.
        harness.coordinator.recordViewport(.latest, for: wrongKey)
        XCTAssertNil(harness.store.snapshot(for: wrongKey))

        // Abandon to unfreeze.
        harness.coordinator.abandonPendingAutomaticSync()
        harness.coordinator.recordViewport(.latest, for: wrongKey)
        XCTAssertEqual(harness.store.snapshot(for: wrongKey), .latest)
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
