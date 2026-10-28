import XCTest
@testable import Conduit

@MainActor
final class WidgetSnapshotPublisherTests: XCTestCase {
    private var root: URL!
    private var store: WidgetSnapshotStore!
    private var writeCount = 0
    private var reloadCount = 0
    private var publisher: WidgetSnapshotPublisher!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetSnapshotPublisherTests.\(UUID().uuidString)", isDirectory: true)
        writeCount = 0
        store = WidgetSnapshotStore(directory: root, writeObserver: { [weak self] in self?.writeCount += 1 })
        reloadCount = 0
        publisher = WidgetSnapshotPublisher(store: store) { [weak self] in self?.reloadCount += 1 }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testIdenticalProjectionDoesNotWriteOrReload() throws {
        let value = workspace(dashboard: dashboardA, profile: "work", title: "Report")
        try publisher.publish(value, current: value.id, language: "system")
        let original = try XCTUnwrap(Data(contentsOf: root.appendingPathComponent(WidgetSnapshotStore.filename)))
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(writeCount, 1)

        try publisher.publish(value, current: value.id, language: "system")

        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(WidgetSnapshotStore.filename)), original)
    }

    func testOfflineKeepsOtherDashboardRecords() throws {
        let first = workspace(dashboard: dashboardA, profile: "work", title: "A")
        let second = workspace(dashboard: dashboardB, profile: "work", title: "B")
        try publisher.publish(first, current: first.id, language: "en")
        try publisher.publish(second, current: nil, language: "en")

        let saved = try XCTUnwrap(store.read())
        XCTAssertEqual(Set(saved.workspaces.map(\.id)), [first.id, second.id])
        XCTAssertEqual(writeCount, 2)
        XCTAssertEqual(reloadCount, 2)
    }

    func testSignOutPurgesOnlyItsDashboard() throws {
        let first = workspace(dashboard: dashboardA, profile: "work", title: "A")
        let second = workspace(dashboard: dashboardB, profile: "work", title: "B")
        try publisher.publish(first, current: first.id, language: "en")
        try publisher.publish(second, current: second.id, language: "en")

        try publisher.remove(dashboardID: dashboardA)

        XCTAssertEqual(store.read()?.workspaces.map(\.id), [second.id])
        XCTAssertEqual(writeCount, 3)
        XCTAssertEqual(reloadCount, 3)
    }

    func testAuthoritativeProfileRemovalPrunesButRefreshFailureDoesNot() throws {
        let first = workspace(dashboard: dashboardA, profile: "work", title: "A")
        let second = workspace(dashboard: dashboardA, profile: "personal", title: "B")
        let otherDashboard = workspace(dashboard: dashboardB, profile: "work", title: "C")
        try publisher.publish(first, current: first.id, language: "en")
        try publisher.publish(second, current: first.id, language: "en")
        try publisher.publish(otherDashboard, current: first.id, language: "en")

        // A refresh that does not produce an authoritative inventory only
        // republishes the known projection; absent profiles remain cached.
        try publisher.publish(first, current: first.id, language: "en")
        XCTAssertTrue(store.read()?.workspaces.contains { $0.id == second.id } == true)

        try publisher.retainProfiles(["work"], dashboardID: dashboardA)

        XCTAssertEqual(Set(store.read()?.workspaces.map(\.id) ?? []), [first.id, otherDashboard.id])
        XCTAssertEqual(reloadCount, 4)
    }

    func testBotDisplayLabelChangeWritesEvenWhenRouteIdentityIsEqual() throws {
        let id = WidgetWorkspaceID(dashboardID: dashboardA, profile: "Atlas")
        let before = WidgetConversationReference(kind: .bot, scopeProfile: "Atlas", botName: "Atlas", botLabel: "Research", sessionID: "canonical", isUnverified: false)
        let after = WidgetConversationReference(kind: .bot, scopeProfile: "Atlas", botName: "Atlas", botLabel: "Planner", sessionID: "canonical", isUnverified: false)
        XCTAssertEqual(before, after, "botLabel is display metadata rather than route identity")
        let old = WidgetWorkspaceSnapshot(id: id, dashboardLabel: "D", profileLabel: "Atlas", lastConversation: before, choices: [], recency: 1)
        let updated = WidgetWorkspaceSnapshot(id: id, dashboardLabel: "D", profileLabel: "Atlas", lastConversation: after, choices: [], recency: 1)

        try publisher.publish(old, current: id, language: "en")
        try publisher.publish(updated, current: id, language: "en")

        XCTAssertEqual(store.read()?.workspaces.first?.lastConversation?.botLabel, "Planner")
        XCTAssertEqual(reloadCount, 2)
    }

    func testBotReferenceRoundTripPreservesOwnerAndEvidence() throws {
        let original = SessionReference(kind: .bot, scopeProfile: "Atlas", botName: "Atlas", botLabel: "Research", sessionID: "canonical", isUnverified: true)

        let projected = AppState.widgetReference(from: original)
        let restored = AppState.sessionReference(from: projected)

        XCTAssertEqual(restored.kind, .bot)
        XCTAssertEqual(restored.scopeProfile, "Atlas")
        XCTAssertEqual(restored.botName, "Atlas")
        XCTAssertEqual(restored.botLabel, "Research")
        XCTAssertEqual(restored.sessionID, "canonical")
        XCTAssertTrue(restored.isUnverified)
        let saved = SessionReference(kind: .bot, scopeProfile: "default", botName: "default", botLabel: "Default", sessionID: "main", isUnverified: false)
        XCTAssertNil(AppState.widgetReference(from: saved).botLabel, "the main bot's \"Default\" saved before #1457 is no label")
    }

    func testBotEvidenceSurvivesMergeAndAuthoritativePrune() throws {
        let unverified = WidgetConversationReference(kind: .bot, scopeProfile: "Atlas", botName: "Atlas", botLabel: "Research", sessionID: "canonical", isUnverified: true)
        let verified = WidgetConversationReference(kind: .bot, scopeProfile: "Scout", botName: "Scout", botLabel: "Scout", sessionID: "other", isUnverified: false)
        let firstID = WidgetWorkspaceID(dashboardID: dashboardA, profile: "Atlas")
        let otherID = WidgetWorkspaceID(dashboardID: dashboardA, profile: "Scout")
        let retained = WidgetWorkspaceSnapshot(id: firstID, dashboardLabel: "A", profileLabel: "Atlas", lastConversation: unverified, choices: [WidgetConversationChoice(reference: unverified, title: "Research", isPinned: false, recency: 1)], recency: 1)
        let transient = WidgetWorkspaceSnapshot(id: otherID, dashboardLabel: "A", profileLabel: "Scout", lastConversation: verified, choices: [WidgetConversationChoice(reference: verified, title: "Scout", isPinned: false, recency: 2)], recency: 2)

        try publisher.publish(retained, current: firstID, language: "system")
        try publisher.publish(transient, current: firstID, language: "system")
        try publisher.retainProfiles(["Atlas"], dashboardID: dashboardA)

        let saved = try XCTUnwrap(store.read())
        XCTAssertEqual(saved.workspaces.map(\.id), [firstID])
        XCTAssertTrue(saved.workspaces[0].lastConversation?.isUnverified == true)
        XCTAssertTrue(saved.workspaces[0].choices[0].reference.isUnverified)
    }

    func testLanguageSelectionReloadsWithoutInventingSystemLocale() throws {
        let value = workspace(dashboard: dashboardA, profile: "work", title: "Report")
        try publisher.publish(value, current: value.id, language: "system")
        XCTAssertEqual(store.read()?.appLanguage, "system")
        try publisher.publish(value, current: value.id, language: "fr-CA")

        XCTAssertEqual(store.read()?.appLanguage, "fr-CA")
        XCTAssertEqual(reloadCount, 2)
        XCTAssertEqual(AppLanguage.system.rawValue, "system")
    }

    private let dashboardA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let dashboardB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func workspace(dashboard: UUID, profile: String, title: String) -> WidgetWorkspaceSnapshot {
        let id = WidgetWorkspaceID(dashboardID: dashboard, profile: profile)
        let reference = WidgetConversationReference(kind: .dashboard, scopeProfile: profile, botName: nil, botLabel: nil, sessionID: title, isUnverified: false)
        return WidgetWorkspaceSnapshot(
            id: id,
            dashboardLabel: "Dashboard",
            profileLabel: profile,
            lastConversation: reference,
            choices: [WidgetConversationChoice(reference: reference, title: title, isPinned: true, recency: 10)],
            recency: 10
        )
    }
}
