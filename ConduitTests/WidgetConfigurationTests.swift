import XCTest
@testable import Conduit

final class WidgetConfigurationTests: XCTestCase {
    // MARK: - Siri and Spotlight's chats (ConduitChatEntity)

    private func chatSnapshot() -> (WidgetSnapshot, WidgetWorkspaceID, WidgetWorkspaceID) {
        let home = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, profile: "default")
        let work = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, profile: "work")
        func chat(_ profile: String, _ id: String, _ title: String, recency: Double) -> WidgetConversationChoice {
            WidgetConversationChoice(reference: WidgetConversationReference(kind: .dashboard, scopeProfile: profile, botName: nil, botLabel: nil, sessionID: id, isUnverified: false),
                                     title: title, isPinned: false, recency: recency)
        }
        let bot = WidgetConversationChoice(reference: WidgetConversationReference(kind: .bot, scopeProfile: "furina", botName: "furina", botLabel: "Furina", sessionID: "bot-1", isUnverified: false),
                                           title: "Furina", isPinned: true, recency: 1)
        let homeRecord = WidgetWorkspaceSnapshot(id: home, dashboardLabel: "Home", profileLabel: "Default", lastConversation: nil,
                                                 choices: [chat("default", "a", "Trip planning", recency: 5), bot], recency: 1)
        let workRecord = WidgetWorkspaceSnapshot(id: work, dashboardLabel: "Office", profileLabel: "Work", lastConversation: nil,
                                                 choices: [chat("work", "b", "Quarterly trip report", recency: 9)], recency: 9)
        return (WidgetSnapshot(appLanguage: "en", currentWorkspaceID: home, workspaces: [workRecord, homeRecord]), home, work)
    }

    func testChatEntitiesListTheWorkspaceInUseFirstWithWhereEachLives() {
        let (snapshot, home, work) = chatSnapshot()
        let chats = ConduitChatCatalog.entities(in: snapshot)

        XCTAssertEqual(chats.map(\.title), ["Furina", "Trip planning", "Quarterly trip report"])
        XCTAssertEqual(chats.map(\.workspace), [home, home, work])
        XCTAssertEqual(chats.first?.place, "Home — Default")
        XCTAssertEqual(chats.first?.reference.kind, .bot)
        XCTAssertTrue(ConduitChatCatalog.entities(in: nil).isEmpty)
    }

    func testChatEntitiesMatchEveryWordOfTheTitleInAnyCase() {
        let (snapshot, _, _) = chatSnapshot()

        XCTAssertEqual(ConduitChatCatalog.matching("TRIP", in: snapshot).map(\.title), ["Trip planning", "Quarterly trip report"])
        XCTAssertEqual(ConduitChatCatalog.matching("trip report", in: snapshot).map(\.title), ["Quarterly trip report"])
        XCTAssertTrue(ConduitChatCatalog.matching("  ", in: snapshot).isEmpty)
    }

    func testASavedChatPickKeepsItsIdentityOnceTheSnapshotDropsIt() throws {
        let (snapshot, home, _) = chatSnapshot()
        let listed = try XCTUnwrap(ConduitChatCatalog.entities(in: snapshot).first { $0.title == "Trip planning" })
        let gone = WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil, botLabel: nil, sessionID: "old", isUnverified: false)
        let goneID = WidgetEntityIdentifier.conversation(workspace: home, reference: gone)

        XCTAssertEqual(ConduitChatCatalog.entity(id: listed.id, in: snapshot), listed)
        let kept = try XCTUnwrap(ConduitChatCatalog.entity(id: goneID, in: snapshot))
        XCTAssertEqual(kept.reference, gone)
        XCTAssertNil(kept.title)
        XCTAssertNil(ConduitChatCatalog.entity(id: "not-an-id", in: snapshot))
    }

    func testWorkspaceEntityIdentifierContainsVersionAndFullIdentity() throws {
        let identity = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!, profile: "CaseSensitive/Profile")
        let identifier = WidgetEntityIdentifier.workspace(identity)

        XCTAssertTrue(identifier.hasPrefix("widget-workspace-v1:"))
        XCTAssertEqual(WidgetEntityIdentifier.decodeWorkspace(identifier), identity)
        XCTAssertNil(WidgetEntityIdentifier.decodeWorkspace("widget-workspace-v2:unrecognized"))
        XCTAssertNil(WidgetEntityIdentifier.decodeWorkspace("widget-workspace-v1:not-base64"))
    }

    func testEvictedWorkspaceEntityRetainsItsConfiguredIdentity() throws {
        let identity = WidgetWorkspaceID(dashboardID: UUID(), profile: "fixed")
        let configured = try XCTUnwrap(WidgetWorkspaceEntity(id: WidgetEntityIdentifier.workspace(identity)))

        XCTAssertEqual(configured.workspaceID, identity)
        XCTAssertNil(configured.displayName)
    }

    func testEvictedConversationEntityRetainsOwnerAndTypedIdentity() throws {
        let workspace = WidgetWorkspaceID(dashboardID: UUID(), profile: "dashboard")
        let reference = WidgetConversationReference(kind: .bot, scopeProfile: "research-bot", botName: "research-bot", botLabel: "Research", sessionID: "same-id", isUnverified: true)
        let identifier = WidgetEntityIdentifier.conversation(workspace: workspace, reference: reference)
        let configured = try XCTUnwrap(WidgetConversationEntity(id: identifier))

        XCTAssertEqual(configured.workspaceID, workspace)
        XCTAssertEqual(configured.reference, reference)
        XCTAssertNil(configured.displayName)
    }

    func testEntityQueriesReturnLocalizedPlaceholdersAfterSnapshotEviction() async throws {
        let workspace = WidgetWorkspaceID(dashboardID: UUID(), profile: "evicted")
        let reference = WidgetConversationReference(kind: .bot, scopeProfile: "helper", botName: "helper", botLabel: nil, sessionID: "evicted-chat", isUnverified: false)
        let workspaceQuery = WidgetWorkspaceEntityQuery(snapshotReader: { nil })
        let conversationQuery = WidgetConversationEntityQuery(snapshotReader: { nil })

        let workspaces = try await workspaceQuery.entities(for: [WidgetEntityIdentifier.workspace(workspace)])
        let conversations = try await conversationQuery.entities(for: [WidgetEntityIdentifier.conversation(workspace: workspace, reference: reference)])
        let restoredWorkspace = try XCTUnwrap(workspaces.first)
        let restoredConversation = try XCTUnwrap(conversations.first)

        XCTAssertEqual(restoredWorkspace.workspaceID, workspace)
        XCTAssertNil(restoredWorkspace.displayName) // nil selects the localized static "Workspace" key.
        XCTAssertEqual(restoredConversation.workspaceID, workspace)
        XCTAssertEqual(restoredConversation.reference, reference)
        XCTAssertNil(restoredConversation.displayName) // nil selects the localized static "Conversation" key.
    }

    func testCachedTitleMatchingStaticCopyRemainsVerbatim() {
        let workspace = WidgetWorkspaceID(dashboardID: UUID(), profile: "p")
        let reference = WidgetConversationReference(kind: .dashboard, scopeProfile: "p", botName: nil, botLabel: nil, sessionID: "s", isUnverified: false)
        let choice = WidgetConversationChoice(reference: reference, title: "Resume chat", isPinned: false, recency: 1)
        let record = WidgetWorkspaceSnapshot(id: workspace, dashboardLabel: "Dashboard", profileLabel: "Profile", lastConversation: reference, choices: [choice], recency: 1)
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: workspace, workspaces: [record])

        let visible = WidgetSelection.resolve(snapshot: snapshot, workspace: workspace, conversation: reference)
        let hidden = WidgetSelection.resolve(snapshot: snapshot, workspace: workspace, conversation: reference, hideTitle: true)

        XCTAssertEqual(visible.titleCopy, .cached("Resume chat"))
        XCTAssertEqual(hidden.titleCopy, .resumeChat)
        XCTAssertEqual(WidgetLocalization.title(visible.titleCopy, language: "en"), "Resume chat")
        XCTAssertEqual(visible.resumeLink, hidden.resumeLink)
    }

    func testMissingHideTitleParameterDefaultsToVisibleTitle() {
        let configuration = LauncherWidgetConfigurationIntent()

        XCTAssertNil(configuration.hideTitle)
        XCTAssertFalse(configuration.shouldHideTitle)
        let hidden = LauncherWidgetConfigurationIntent()
        hidden.hideTitle = true
        XCTAssertTrue(hidden.shouldHideTitle)
    }
}
