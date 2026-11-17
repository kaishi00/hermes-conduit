import Combine
import XCTest
@testable import Conduit

/// A profile switch's slide-in drops to a few fps when publishes land in it:
/// each one is a full SwiftUI pass. A write that changes nothing publishes
/// nothing, and the reads a switch starts begin after its slide-in
/// (`profileSwitchFollowUpDelay`), while a chat open's start at once.
@MainActor
extension AppStateChatResumeTests {

    private final class FollowUpCalls {
        var slashCommands = 0
        var contextRefreshes = 0
        var approvalReads = 0
        var onSlashCommands: (() -> Void)?
        var onContextRefresh: (() -> Void)?
        var onApprovalRead: (() -> Void)?
    }

    private func followUpSession(_ id: String, profile: String = "default", title: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: title ?? id,
            model: "Hermes",
            updatedLabel: "now",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    private func makeFollowUpDefaults() -> UserDefaults {
        let suiteName = "AppStateProfileSwitchFollowUpTests." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeFollowUpSwitchingAppState(calls: FollowUpCalls) -> (AppState, ChatResumeCoordinator) {
        let defaults = makeFollowUpDefaults()
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(.continueWhereLeftOff)
        let coordinator = ChatResumeCoordinator(store: store)
        let work = followUpSession("work-session", profile: "work")
        var operations = ChatResumeLifecycleOperations(
            connectClient: { _ in },
            loadCatalog: { client, _ in
                (client.profile ?? "default") == "work" ? [work] : []
            },
            mintTicket: { _ in "profile-ticket" },
            openSession: { _, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [ChatMessage(id: "w1", role: .assistant, content: "Work", timestamp: "ts-w1")],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in
                calls.contextRefreshes += 1
                calls.onContextRefresh?()
            },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {
                calls.slashCommands += 1
                calls.onSlashCommands?()
            }
        )
        operations.pendingApprovals = { _, _ in
            calls.approvalReads += 1
            calls.onApprovalRead?()
            return []
        }
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        coordinator.rememberSession(.dashboard(profile: "default", sessionID: "session-a"), for: "default")
        coordinator.rememberSession(.dashboard(profile: "work", sessionID: work.id), for: "work")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.showLogin = false
        appState.sessions = [followUpSession("session-a")]
        appState.activeSessionId = "session-a"
        return (appState, coordinator)
    }

    private func yieldFollowUpTurns() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Writes that change nothing

    func testAnUnchangedCatalogPublishesNothing() async {
        var rows = [followUpSession("a"), followUpSession("b")]
        let appState = AppState(
            defaults: makeFollowUpDefaults(),
            loadSavedConnection: false,
            sessionCatalogLoader: { _ in rows }
        )
        appState.isConnected = true
        await appState.loadSessions()
        XCTAssertEqual(appState.sessions.map(\.id), ["a", "b"])

        var published = 0
        let watch = appState.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }

        await appState.loadSessions()
        XCTAssertEqual(published, 0, "An equal list is not written")

        rows = [followUpSession("a", title: "Renamed"), followUpSession("b")]
        await appState.loadSessions()
        XCTAssertGreaterThan(published, 0, "A changed list still publishes")
        XCTAssertEqual(appState.sessions.first?.title, "Renamed")
    }

    func testAnEmptyRegistryInAnotherProfilePublishesNothing() {
        let appState = AppState(defaults: makeFollowUpDefaults(), loadSavedConnection: false)
        appState.liveTurnActivitiesRegistrySnapshot = { _, _, _ in false }
        var published = 0
        let watch = appState.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }

        // The outgoing profile's empty registry (its first read publishes:
        // the index learns its rows are one profile's).
        appState.recordActiveListEvidence([], profile: appState.activeProfile)
        appState.setActiveProfileForTesting("work")
        published = 0

        // The switch's first read under the new profile, nothing running.
        appState.recordActiveListEvidence([], profile: "work")
        XCTAssertEqual(published, 0, "An empty registry changes no row")

        let working = LiveSessionStatus(runtimeSessionId: "runtime", storedSessionId: "stored", status: "working")
        appState.recordActiveListEvidence([working], profile: "work")
        XCTAssertGreaterThan(published, 0, "A running chat still publishes")

        appState.setActiveProfileForTesting("default")
        published = 0
        appState.recordActiveListEvidence([working], profile: "default")
        XCTAssertGreaterThan(published, 0, "The same registry under another profile shows on its rows")
    }

    // MARK: - Follow-ups after the slide-in

    func testASwitchStartsItsSlashCommandsAfterTheSlideIn() async {
        let calls = FollowUpCalls()
        let (appState, _) = makeFollowUpSwitchingAppState(calls: calls)
        appState.profileSwitchFollowUpDelay = .milliseconds(300)
        addTeardownBlock { appState.client?.disconnect() }
        let loaded = expectation(description: "slash commands load after the delay")
        calls.onSlashCommands = { loaded.fulfill() }

        await appState.switchProfile(to: "work")
        XCTAssertEqual(appState.activeProfile, "work")
        await yieldFollowUpTurns()
        XCTAssertEqual(calls.slashCommands, 0, "Not during the slide-in")

        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(calls.slashCommands, 1)
    }

    func testASwitchStartsItsContextAndApprovalReadsAfterTheSlideIn() async {
        let calls = FollowUpCalls()
        let (appState, _) = makeFollowUpSwitchingAppState(calls: calls)
        appState.profileSwitchFollowUpDelay = .milliseconds(300)
        addTeardownBlock { appState.client?.disconnect() }
        let refreshed = expectation(description: "context refresh after the delay")
        let approvalsRead = expectation(description: "approvals read after the delay")
        calls.onContextRefresh = { refreshed.fulfill() }
        calls.onApprovalRead = { approvalsRead.fulfill() }

        await appState.switchProfile(to: "work")
        XCTAssertEqual(appState.activeProfile, "work")
        await yieldFollowUpTurns()
        XCTAssertEqual(calls.contextRefreshes, 0, "Not during the slide-in")
        XCTAssertEqual(calls.approvalReads, 0, "Not during the slide-in")

        await fulfillment(of: [refreshed, approvalsRead], timeout: 5)
    }

    func testAWaitOutlastsTheSlideInOfASwitchThatEndsDuringIt() async {
        let appState = AppState(defaults: makeFollowUpDefaults(), loadSavedConnection: false)
        appState.profileSwitchFollowUpDelay = .milliseconds(200)
        appState.endProfileSwitch()
        var waited = false
        let waiter = Task { @MainActor in
            await appState.waitOutProfileSwitchSlideIn()
            waited = true
        }

        // A second switch ends inside the first one's slide-in.
        try? await Task.sleep(for: .milliseconds(50))
        appState.profileSwitchFollowUpDelay = .seconds(60)
        appState.isProfileSwitching = true
        appState.endProfileSwitch()

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(waited, "The first slide-in is over, the second one's isn't")

        appState.profileSwitchSlideIn?.cancel()
        await waiter.value
        XCTAssertTrue(waited)
    }

    func testAReadOutsideASwitchStartsAtOnce() async throws {
        let calls = FollowUpCalls()
        let (appState, _) = makeFollowUpSwitchingAppState(calls: calls)
        appState.profileSwitchFollowUpDelay = .seconds(60)
        let client = try XCTUnwrap(appState.client)
        XCTAssertFalse(appState.isProfileSwitching)

        let task = appState.schedulePendingApprovalsRefresh(sessionId: "session-a", using: client)
        await yieldFollowUpTurns()
        XCTAssertEqual(calls.approvalReads, 1, "A chat open's read doesn't wait")
        task.cancel()
    }
}
