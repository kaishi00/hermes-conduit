import XCTest
@testable import Conduit

final class WidgetConfigurationTests: XCTestCase {
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
