import UIKit
import XCTest
@testable import Conduit

@MainActor
final class WidgetSnapshotAppStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var root: URL!
    private var store: WidgetSnapshotStore!
    private var writeCount = 0
    private var reloadCount = 0
    private var appState: AppState!
    private let dashboardA = SavedDashboard(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!, label: "Alpha", normalizedURL: "https://alpha.example")
    private let dashboardB = SavedDashboard(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!, label: "Beta", normalizedURL: "https://beta.example")

    override func setUp() {
        super.setUp()
        suite = "WidgetSnapshotAppStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetSnapshotAppStateTests.\(UUID().uuidString)", isDirectory: true)
        writeCount = 0
        reloadCount = 0
        store = WidgetSnapshotStore(directory: root, writeObserver: { [weak self] in self?.writeCount += 1 })
        let catalog = [session("first", title: "First chat"), session("inactive", title: "Old title")]
        let appearanceRoot = root.appendingPathComponent("appearance", isDirectory: true)
        appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboardA.id, dashboards: [dashboardA, dashboardB]),
            clearSessionPresentationCache: {},
            sessionCatalogLoader: { _ in catalog },
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            profileAppearanceStore: ProfileAppearanceStore(defaults: defaults, avatarsRoot: appearanceRoot, legacyAvatarDirectories: [])
        )
        appState.widgetSnapshotStoreOverride = store
        appState.widgetSnapshotReloadOverride = { [weak self] in self?.reloadCount += 1 }
        appState.widgetSessionMutationRequestOverride = { _, _, _ in [:] }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testDashboardOfflineRoundTripRetainsMetadataAndMovesFollowCurrent() async throws {
        await appState.loadSessions(forceRefresh: true)
        let initial = try XCTUnwrap(store.read())
        let alpha = try XCTUnwrap(initial.workspaces.first { $0.id.dashboardID == dashboardA.id })
        XCTAssertTrue(alpha.choices.contains { $0.title == "First chat" })

        appState.selectDashboardTarget(dashboardB.id)
        XCTAssertEqual(store.read()?.currentWorkspaceID, WidgetWorkspaceID(dashboardID: dashboardB.id, profile: "default"))
        appState.sessions = [] // The target has no admitted catalog while offline.
        appState.selectDashboardTarget(dashboardA.id)
        appState.publishWidgetSnapshot()

        let returned = try XCTUnwrap(store.read())
        XCTAssertEqual(returned.currentWorkspaceID, WidgetWorkspaceID(dashboardID: dashboardA.id, profile: "default"))
        XCTAssertTrue(returned.workspaces.first { $0.id == alpha.id }?.choices.contains { $0.title == "First chat" } == true)
        XCTAssertEqual(writeCount, 3)
        XCTAssertEqual(reloadCount, 3)
    }

    func testProfileRollbackRetainsPreviouslySettledWorkspace() async throws {
        await appState.loadSessions(forceRefresh: true)
        let workspace = try XCTUnwrap(store.read()?.workspaces.first)

        appState.setActiveProfileForTesting("work")
        appState.sessions = []
        appState.setActiveProfileForTesting("default")
        appState.publishWidgetSnapshot()

        XCTAssertEqual(store.read()?.currentWorkspaceID, workspace.id)
        XCTAssertTrue(store.read()?.workspaces.first { $0.id == workspace.id }?.choices.contains { $0.title == "First chat" } == true)
        XCTAssertEqual(writeCount, 3)
        XCTAssertEqual(reloadCount, 3)
    }

    func testInactiveRenameUpdatesSavedChoiceImmediately() async throws {
        await appState.loadSessions(forceRefresh: true)
        appState.handleStreamEvent(.sessionTitle(runtimeSessionId: "inactive", storedSessionId: "inactive", title: "Renamed while away"))

        let snapshot = try XCTUnwrap(store.read())
        XCTAssertTrue(snapshot.workspaces.first?.choices.contains { $0.title == "Renamed while away" } == true)
        XCTAssertEqual(reloadCount, 2)
    }

    func testAdmittedRemovalDropsSavedChoiceImmediately() async throws {
        await appState.loadSessions(forceRefresh: true)
        guard let removed = appState.sessions.first(where: { $0.id == "inactive" }) else {
            return XCTFail("Expected inactive fixture row")
        }

        appState.removeSessionFromLiveCatalog(removed)

        XCTAssertFalse(store.read()?.workspaces.first?.choices.contains { $0.reference.sessionID == "inactive" } == true)
        XCTAssertEqual(reloadCount, 2)
    }

    func testLanguageUpdateWithoutSettledCatalogPreservesStoredWorkspacesAndCurrentSelection() async throws {
        await appState.loadSessions(forceRefresh: true)
        let seedPublisher = WidgetSnapshotPublisher(store: store, reload: {})
        try seedPublisher.updateLanguage("fr-CA")
        let before = try XCTUnwrap(store.read())
        let writesBefore = writeCount
        let reloadsBefore = reloadCount
        appState.widgetSettledCatalogOwner = nil

        appState.publishWidgetLanguage()

        let after = try XCTUnwrap(store.read())
        XCTAssertEqual(after.workspaces, before.workspaces)
        XCTAssertEqual(after.currentWorkspaceID, before.currentWorkspaceID)
        XCTAssertEqual(after.appLanguage, AppLanguageStore.shared.selection.rawValue)
        XCTAssertEqual(writeCount - writesBefore, 1)
        XCTAssertEqual(reloadCount - reloadsBefore, 1)
    }

    func testActiveArchivePublishesOnlySettledSnapshotOnce() async throws {
        await appState.loadSessions(forceRefresh: true)
        let active = try XCTUnwrap(appState.sessions.first(where: { $0.id == "first" }))
        appState.adoptActiveSessionForWidgetTesting(active.id)
        let beforeArchive = try XCTUnwrap(store.read())
        XCTAssertEqual(beforeArchive.workspaces.first?.lastConversation?.sessionID, active.id)
        let writesBeforeArchive = writeCount
        let reloadsBeforeArchive = reloadCount

        let archiveSucceeded = await appState.archiveSession(active)
        XCTAssertTrue(archiveSucceeded)

        let after = try XCTUnwrap(store.read())
        XCTAssertNil(after.workspaces.first?.lastConversation)
        XCTAssertFalse(after.workspaces.first?.choices.contains { $0.reference.sessionID == active.id } == true)
        XCTAssertEqual(writeCount - writesBeforeArchive, 1)
        XCTAssertEqual(reloadCount - reloadsBeforeArchive, 1)
    }

    private func session(_ id: String, title: String) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: title,
            model: "model",
            updatedLabel: "unused display time",
            lastActivityAt: 42,
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false
        )
    }
}
