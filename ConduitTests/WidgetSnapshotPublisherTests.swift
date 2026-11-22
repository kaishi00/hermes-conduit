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

    func testARenamedDashboardIsRelabelledInEveryWorkspaceOfIt() throws {
        let first = workspace(dashboard: dashboardA, profile: "work", title: "A")
        let firstHome = workspace(dashboard: dashboardA, profile: "home", title: "A home")
        let second = workspace(dashboard: dashboardB, profile: "work", title: "B")
        try publisher.publish(first, current: first.id, language: "en")
        try publisher.publish(firstHome, current: firstHome.id, language: "en")
        try publisher.publish(second, current: second.id, language: "en")

        try publisher.relabel(dashboardID: dashboardA, label: "Studio")
        let saved = try XCTUnwrap(store.read())
        XCTAssertEqual(saved.workspaces.first { $0.id == first.id }?.dashboardLabel, "Studio")
        XCTAssertEqual(saved.workspaces.first { $0.id == firstHome.id }?.dashboardLabel, "Studio")
        XCTAssertEqual(saved.workspaces.first { $0.id == second.id }?.dashboardLabel, second.dashboardLabel)
        XCTAssertEqual(saved.workspaces.first { $0.id == first.id }?.choices, first.choices)
        XCTAssertEqual(reloadCount, 4)
        try publisher.relabel(dashboardID: dashboardA, label: "Studio")
        XCTAssertEqual(reloadCount, 4, "the same name writes nothing")
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

    func testAnotherCombinedDashboardsWorkspacesKeepTheCurrentOne() throws {
        let onScreen = workspace(dashboard: dashboardA, profile: "work", title: "A")
        try publisher.publish(onScreen, current: onScreen.id, language: "en")
        let other = workspace(dashboard: dashboardB, profile: "home", title: "B")
        try publisher.publish(others: [other], over: store.read(), language: "en")

        let saved = try XCTUnwrap(store.read())
        XCTAssertEqual(saved.currentWorkspaceID, onScreen.id)
        XCTAssertEqual(Set(saved.workspaces.map(\.id)), [onScreen.id, other.id])
        try publisher.publish(others: [other], over: store.read(), language: "en")
        XCTAssertEqual(writeCount, 2, "the same workspaces again write nothing")
    }

    /// No-switch plan stage 2: another combined dashboard's chats reach
    /// Siri, Spotlight and the widgets from its kept reads, a workspace per
    /// profile, its Bot Chats in the profile a switch there resumes on.
    func testAnotherCombinedDashboardsReadsBecomeAWorkspacePerProfile() {
        func chat(_ id: String, _ profile: String, source: SessionSource = .chat, pinned: Bool? = nil) -> SessionSummary {
            var row = SessionSummary(id: id, alternateIds: [], title: "Title \(id)", model: "model", updatedLabel: "",
                                     lastActivityAt: 5, profile: profile, source: source, isActive: false, isArchived: false)
            row.isPinned = pinned
            return row
        }
        let bot = BotProfile(name: "coder", botTitle: nil, displayName: "Coder", profileDescription: "", model: nil,
                             provider: nil, hasAvatar: false, isPinned: true, isHiddenByMeta: false, appearanceColor: nil,
                             canonicalSession: BotCanonicalSession(id: "bot-chat", resolvedID: nil, lastActive: 9, preview: nil),
                             lastActive: nil, lastPreview: nil)
        let sessions = [chat("a", "default", pinned: true), chat("b", "coder"), chat("bot-chat", "coder"),
                        chat("cron", "default", source: .cron), chat("old", "default")]
        let earlier = WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil, botLabel: nil,
                                                  sessionID: "old", isUnverified: false)
        let before = WidgetWorkspaceSnapshot(
            id: WidgetWorkspaceID(dashboardID: dashboardB, profile: "default"), dashboardLabel: "Old name", profileLabel: "Eric",
            lastConversation: earlier, choices: [WidgetConversationChoice(reference: earlier, title: "Old", isPinned: true, recency: 1)],
            recency: 1
        )

        let built = AppState.combinedWidgetWorkspaces(
            dashboardID: dashboardB, dashboardLabel: "Studio", profiles: ["default", "coder"], sessions: sessions,
            bots: [bot], botsProfile: "default", previous: [before.id: before]
        )

        XCTAssertEqual(built.map(\.id.profile), ["default", "coder"])
        let main = built[0]
        XCTAssertEqual(main.dashboardLabel, "Studio")
        XCTAssertEqual(main.profileLabel, "Eric", "the label a visit there gave")
        XCTAssertEqual(main.lastConversation, earlier)
        XCTAssertEqual(Set(main.choices.map(\.reference.sessionID)), ["a", "old", "bot-chat"], "no cron run")
        XCTAssertEqual(main.choices.first { $0.reference.sessionID == "a" }?.isPinned, true, "Hermes' pin")
        XCTAssertEqual(main.choices.first { $0.reference.sessionID == "old" }?.isPinned, true, "the pin it showed")
        XCTAssertEqual(main.choices.first { $0.reference.kind == .bot }?.reference.botName, "coder")
        XCTAssertFalse(main.choices.contains { $0.reference.isUnverified }, "its roster was read")
        let coder = built[1]
        XCTAssertEqual(coder.profileLabel, "Coder")
        XCTAssertEqual(coder.choices.map(\.reference.sessionID), ["b"], "its Bot Chat isn't a chat of its own")

        let unread = AppState.combinedWidgetWorkspaces(
            dashboardID: dashboardB, dashboardLabel: "Studio", profiles: ["default"], sessions: sessions,
            bots: nil, botsProfile: "default", previous: [:]
        )
        XCTAssertTrue(unread[0].choices.allSatisfy { $0.reference.isUnverified && $0.reference.kind == .dashboard })
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
