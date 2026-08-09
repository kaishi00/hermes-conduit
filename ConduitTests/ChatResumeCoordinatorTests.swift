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

    func testExplicitActionCancelsAnOlderGeneration() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = harness.coordinator.reconciliationSettled(sessionKey: key)!

        harness.coordinator.cancelRestoration()

        XCTAssertFalse(harness.coordinator.isCurrent(generation: request.generation))
    }

    func testLatestModeSelectsNewestAndEmitsLatest() {
        let harness = makeHarness()
        harness.coordinator.setBehavior(.latestActivity)
        let selected = harness.coordinator.selectTarget(
            in: [session("stored-b"), session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = harness.coordinator.reconciliationSettled(
            sessionKey: .init(profile: "default", sessionID: selected!.id)
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

    func testCompletingCurrentRequestAllowsViewportWritesAgain() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = harness.coordinator.reconciliationSettled(sessionKey: key)!
        harness.coordinator.completeRestoration(generation: request.generation)
        harness.coordinator.recordViewport(.latest, for: key)
        harness.coordinator.flush()

        XCTAssertEqual(harness.store.snapshot(for: key), .latest)
    }

    func testAbandoningCurrentRequestAllowsViewportWritesAgain() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = harness.coordinator.reconciliationSettled(sessionKey: key)!

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
        harness.coordinator.cancelRestoration()
        let recovery = harness.coordinator.selectTarget(
            in: catalog,
            profile: "default",
            purpose: .preserveCurrent,
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(automatic?.id, "stored-b")
        XCTAssertEqual(recovery?.id, "stored-a")
    }

    func testChangingBehaviorCancelsCurrentRequestBeforeSavingPreference() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = harness.coordinator.reconciliationSettled(sessionKey: key)!

        harness.coordinator.setBehavior(.latestActivity)

        XCTAssertFalse(harness.coordinator.isCurrent(generation: request.generation))
        XCTAssertEqual(harness.store.behavior, .latestActivity)
    }

    func testClearResumeStateCancelsRequestAndPreservesBehavior() {
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
        let request = harness.coordinator.reconciliationSettled(sessionKey: key)!

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

    private func makeHarness() -> (
        coordinator: ChatResumeCoordinator,
        store: ChatResumeStore,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "ChatResumeCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
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
