import XCTest
@testable import Conduit

final class WidgetSnapshotTests: XCTestCase {
    func testSnapshotRoundTripKeepsDashboardAndBotIdentity() throws {
        let first = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, profile: "家庭")
        let second = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, profile: "家庭")
        let dashboard = WidgetConversationReference(kind: .dashboard, scopeProfile: "家庭", botName: nil, botLabel: nil, sessionID: "same-id", isUnverified: false)
        let bot = WidgetConversationReference(kind: .bot, scopeProfile: "家庭", botName: "家庭", botLabel: "研究者", sessionID: "same-id", isUnverified: false)
        let one = WidgetWorkspaceSnapshot(id: first, dashboardLabel: "One", profileLabel: "家庭", lastConversation: dashboard, choices: [], recency: 2)
        let two = WidgetWorkspaceSnapshot(id: second, dashboardLabel: "Two", profileLabel: "家庭", lastConversation: bot, choices: [], recency: 1)
        let original = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: first, workspaces: [one, two])
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testSnapshotBoundsPrioritizeLastPinnedRecent() {
        let workspaces = (0..<105).map { index in
            let ref = WidgetConversationReference(kind: .dashboard, scopeProfile: "p", botName: nil, botLabel: nil, sessionID: "s\(index)", isUnverified: false)
            let choices = (0..<25).map { n in
                WidgetConversationChoice(reference: WidgetConversationReference(kind: .dashboard, scopeProfile: "p", botName: nil, botLabel: nil, sessionID: "c\(n)", isUnverified: false), title: "c\(n)", isPinned: n == 23, recency: Double(n))
            }
            let last = WidgetConversationChoice(reference: ref, title: "last", isPinned: false, recency: 0)
            return WidgetWorkspaceSnapshot(id: WidgetWorkspaceID(dashboardID: UUID(), profile: "p\(index)"), dashboardLabel: "D", profileLabel: "P", lastConversation: ref, choices: choices + [last], recency: Double(index))
        }
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: nil, workspaces: workspaces)
        XCTAssertEqual(snapshot.workspaces.count, 100)
        XCTAssertEqual(snapshot.workspaces[0].choices.count, 20)
        XCTAssertTrue(snapshot.workspaces[0].choices.contains { $0.title == "last" })
        XCTAssertTrue(snapshot.workspaces[0].choices.contains { $0.isPinned })
    }

    func testAtomicStoreRetainsValidSnapshotWhenWriteFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let previous = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: nil, workspaces: [])
        XCTAssertTrue(try store.write(previous))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try store.write(WidgetSnapshot(appLanguage: "fr", currentWorkspaceID: nil, workspaces: [])))
        XCTAssertEqual(store.read(), previous)
    }

    func testMalformedOrUnknownSchemaProducesSetup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("launcher-v1.json")
        let store = WidgetSnapshotStore(directory: directory)
        try Data(#"{"schemaVersion":1,"appLanguage":"en","currentWorkspaceID":null,"workspaces":[]}"#.utf8).write(to: url)
        XCTAssertNotNil(store.read())
        try Data("{ truncated".utf8).write(to: url)
        XCTAssertNil(store.read())
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: url)
        XCTAssertNil(store.read())
    }

    func testSelectionCapturesDisplayedWorkspaceAndDoesNotReplaceEvictedTarget() {
        let displayed = WidgetWorkspaceID(dashboardID: UUID(), profile: "p")
        let target = WidgetConversationReference(kind: .bot, scopeProfile: "bot", botName: "bot", botLabel: "B", sessionID: "gone", isUnverified: false)
        let workspace = WidgetWorkspaceSnapshot(id: displayed, dashboardLabel: "Dash", profileLabel: "Profile", lastConversation: target, choices: [], recency: 1)
        let entry = WidgetSelection.resolve(snapshot: WidgetSnapshot(appLanguage: "en", currentWorkspaceID: nil, workspaces: [workspace]), workspace: displayed, conversation: target)
        XCTAssertEqual(entry.resumeLink.workspace, displayed)
        XCTAssertEqual(entry.resumeLink.reference, target)
        let missing = WidgetSelection.resolve(snapshot: WidgetSnapshot(appLanguage: "en", currentWorkspaceID: nil, workspaces: []), workspace: displayed, conversation: target)
        XCTAssertEqual(missing.title, "Open Conduit to refresh")
        XCTAssertEqual(missing.resumeLink.workspace, displayed)
        XCTAssertEqual(missing.resumeLink.reference, target)
    }

    func testLabeledBotChoiceMatchesLabelFreeConfiguredIdentityAndDeduplicates() {
        let workspaceID = WidgetWorkspaceID(dashboardID: UUID(), profile: "dash")
        let labeled = WidgetConversationReference(kind: .bot, scopeProfile: "bot", botName: "bot", botLabel: "Researcher", sessionID: "same", isUnverified: false)
        let labelFree = WidgetConversationReference(kind: .bot, scopeProfile: "bot", botName: "bot", botLabel: nil, sessionID: "same", isUnverified: false)
        let choices = [
            WidgetConversationChoice(reference: labeled, title: "Research", isPinned: false, recency: 1),
            WidgetConversationChoice(reference: labelFree, title: "Duplicate", isPinned: false, recency: 2)
        ]
        let workspace = WidgetWorkspaceSnapshot(id: workspaceID, dashboardLabel: "Dash", profileLabel: "Profile", lastConversation: nil, choices: choices, recency: 1)
        XCTAssertEqual(workspace.choices.count, 1)
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: workspaceID, workspaces: [workspace])
        let entry = WidgetSelection.resolve(snapshot: snapshot, workspace: workspaceID, conversation: labelFree)
        XCTAssertEqual(entry.title, "Duplicate")
        XCTAssertEqual(entry.resumeLink.reference?.botName, "bot")
        XCTAssertNil(entry.resumeLink.reference?.botLabel)
    }

    func testMissingCurrentWorkspaceKeepsKnownIdentityInSafeRecoveryLinks() {
        let workspace = WidgetWorkspaceID(dashboardID: UUID(), profile: "current")
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: workspace, workspaces: [])
        let entry = WidgetSelection.resolve(snapshot: snapshot, workspace: nil, conversation: nil)
        XCTAssertEqual(entry.title, "Open Conduit to refresh")
        XCTAssertEqual(entry.newChatLink?.workspace, workspace)
        XCTAssertEqual(entry.talkLink?.workspace, workspace)
        XCTAssertEqual(entry.resumeLink.action, .open)
        XCTAssertEqual(entry.resumeLink.workspace, workspace)
    }

    func testInvalidWorkspaceIdentityShowsGenericRecoveryWithoutCachedActions() {
        for profile in ["", String(repeating: "p", count: 513)] {
            let invalidID = WidgetWorkspaceID(dashboardID: UUID(), profile: profile)
            let reference = WidgetConversationReference(kind: .dashboard, scopeProfile: profile, botName: nil, botLabel: nil, sessionID: "private-session", isUnverified: false)
            let choice = WidgetConversationChoice(reference: reference, title: "Cached private title", isPinned: true, recency: 1)
            let workspace = WidgetWorkspaceSnapshot(id: invalidID, dashboardLabel: "Private dashboard", profileLabel: "Private profile", lastConversation: reference, choices: [choice], recency: 1)
            let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: invalidID, workspaces: [workspace])
            let entry = WidgetSelection.resolve(snapshot: snapshot, workspace: nil, conversation: nil)
            XCTAssertEqual(entry.title, "Open Conduit to refresh")
            XCTAssertEqual(entry.dashboardLabel, "")
            XCTAssertEqual(entry.profileLabel, "")
            XCTAssertEqual(entry.resumeLink.action, .open)
            XCTAssertNil(entry.resumeLink.workspace)
            XCTAssertNil(entry.newChatLink)
            XCTAssertNil(entry.talkLink)
        }
    }

    func testNoWorkspaceOffersOnlyUnscopedOpenRecovery() {
        let entry = WidgetSelection.resolve(snapshot: nil, workspace: nil, conversation: nil)
        XCTAssertEqual(entry.title, "Open Conduit")
        XCTAssertNil(entry.newChatLink)
        XCTAssertNil(entry.talkLink)
        XCTAssertEqual(entry.resumeLink, WidgetLaunchLink(url: URL(string: "conduit://widget/v1/open")!))
    }

    func testLongRTLTitleRoundTripsAndHiddenTitleRedactsDisplay() throws {
        let workspaceID = WidgetWorkspaceID(dashboardID: UUID(), profile: "عربي/家庭")
        let reference = WidgetConversationReference(kind: .dashboard, scopeProfile: workspaceID.profile, botName: nil, botLabel: nil, sessionID: "s", isUnverified: false)
        let title = String(repeating: "مرحبا 世界 ", count: 80)
        let choice = WidgetConversationChoice(reference: reference, title: title, isPinned: true, recency: 10)
        XCTAssertEqual(try JSONDecoder().decode(WidgetConversationChoice.self, from: JSONEncoder().encode(choice)).title, title)
        let workspace = WidgetWorkspaceSnapshot(id: workspaceID, dashboardLabel: "Dashboard", profileLabel: "Profile", lastConversation: reference, choices: [choice], recency: 1)
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: workspaceID, workspaces: [workspace])
        let visible = WidgetSelection.resolve(snapshot: snapshot, workspace: nil, conversation: nil)
        let hidden = WidgetSelection.resolve(snapshot: snapshot, workspace: nil, conversation: nil, hideTitle: true)
        XCTAssertEqual(hidden.title, "Resume chat")
        XCTAssertFalse([hidden.title, hidden.dashboardLabel, hidden.profileLabel].contains { $0.contains(title) })
        XCTAssertEqual(hidden.resumeLink, visible.resumeLink)
    }

    func testFixedWorkspaceConfigurationDoesNotFollowCurrent() {
        let current = workspace("current")
        let fixed = workspace("fixed")
        let fixedReference = reference(profile: fixed.profile, session: "fixed-chat")
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: current, workspaces: [
            workspaceSnapshot(current, last: reference(profile: current.profile, session: "current-chat")),
            workspaceSnapshot(fixed, last: fixedReference)
        ])

        let entry = WidgetSelection.resolve(snapshot: snapshot, workspace: fixed, conversation: nil)

        XCTAssertEqual(entry.resumeLink.action, .resume)
        XCTAssertEqual(entry.resumeLink.workspace, fixed)
        XCTAssertEqual(entry.resumeLink.reference, fixedReference)
        XCTAssertEqual(entry.newChatLink?.workspace, fixed)
        XCTAssertEqual(entry.talkLink?.workspace, fixed)
    }

    func testUnknownConfiguredEntityShowsRefresh() {
        let configured = workspace("evicted")
        let current = workspace("current")
        let configuredReference = reference(profile: configured.profile, session: "configured")
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: current, workspaces: [
            workspaceSnapshot(current, last: reference(profile: current.profile, session: "other"))
        ])

        let entry = WidgetSelection.resolve(snapshot: snapshot, workspace: configured, conversation: configuredReference)

        XCTAssertEqual(entry.title, "Open Conduit to refresh")
        XCTAssertEqual(entry.resumeLink.action, .resume)
        XCTAssertEqual(entry.resumeLink.workspace, configured)
        XCTAssertEqual(entry.resumeLink.reference, configuredReference)
        XCTAssertEqual(entry.newChatLink?.workspace, configured)
        XCTAssertEqual(entry.talkLink?.workspace, configured)
    }

    func testConfiguredConversationBelongsToSelectedWorkspace() throws {
        let first = workspace("same-profile")
        let second = WidgetWorkspaceID(dashboardID: UUID(), profile: first.profile)
        let firstReference = WidgetConversationReference(kind: .bot, scopeProfile: "helper", botName: "helper", botLabel: nil, sessionID: "same-session", isUnverified: false)
        let secondReference = WidgetConversationReference(kind: .bot, scopeProfile: "helper", botName: "helper", botLabel: nil, sessionID: "same-session", isUnverified: false)

        let encoded = WidgetEntityIdentifier.conversation(workspace: first, reference: firstReference)
        let decoded = try XCTUnwrap(WidgetEntityIdentifier.decodeConversation(encoded))

        XCTAssertEqual(decoded.workspace, first)
        XCTAssertNotEqual(decoded.workspace, second)
        XCTAssertEqual(decoded.reference, firstReference)
        XCTAssertNotEqual(WidgetEntityIdentifier.conversation(workspace: first, reference: firstReference), WidgetEntityIdentifier.conversation(workspace: second, reference: secondReference))

        let selectedSnapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: second, workspaces: [
            workspaceSnapshot(second, last: secondReference)
        ])
        let mismatched = WidgetSelection.resolve(snapshot: selectedSnapshot, workspace: second, conversation: decoded.reference, conversationWorkspace: decoded.workspace)
        XCTAssertEqual(mismatched.title, "Open Conduit to refresh")
        XCTAssertEqual(mismatched.resumeLink.action, .open)
        XCTAssertEqual(mismatched.resumeLink.workspace, second)
        XCTAssertNil(mismatched.resumeLink.reference)
    }

    func testNoWorkspaceShowsSetup() {
        let entry = WidgetSelection.resolve(snapshot: nil, workspace: nil, conversation: nil)

        XCTAssertEqual(entry.title, "Open Conduit")
        XCTAssertEqual(entry.resumeLink.action, .open)
        XCTAssertNil(entry.resumeLink.workspace)
        XCTAssertNil(entry.newChatLink)
        XCTAssertNil(entry.talkLink)
    }

    func testKnownWorkspaceWithoutChatKeepsNewChatAndTalk() {
        let selected = workspace("ready")
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: selected, workspaces: [
            workspaceSnapshot(selected, last: nil)
        ])

        let entry = WidgetSelection.resolve(snapshot: snapshot, workspace: selected, conversation: nil)

        XCTAssertEqual(entry.title, "Open Conduit")
        XCTAssertEqual(entry.resumeLink.action, .open)
        XCTAssertEqual(entry.resumeLink.workspace, selected)
        XCTAssertEqual(entry.newChatLink?.action, .newChat)
        XCTAssertEqual(entry.newChatLink?.workspace, selected)
        XCTAssertEqual(entry.talkLink?.action, .talk)
        XCTAssertEqual(entry.talkLink?.workspace, selected)
    }

    func testHideTitleKeepsGenericExactTargetLink() {
        let selected = workspace("private")
        let target = reference(profile: selected.profile, session: "target")
        let cached = WidgetConversationChoice(reference: target, title: "Resume chat", isPinned: false, recency: 1)
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: selected, workspaces: [
            WidgetWorkspaceSnapshot(id: selected, dashboardLabel: "Dashboard", profileLabel: "Profile", lastConversation: target, choices: [cached], recency: 1)
        ])

        let visible = WidgetSelection.resolve(snapshot: snapshot, workspace: selected, conversation: target)
        let hidden = WidgetSelection.resolve(snapshot: snapshot, workspace: selected, conversation: target, hideTitle: true)

        XCTAssertEqual(hidden.title, "Resume chat")
        XCTAssertEqual(hidden.resumeLink.action, .resume)
        XCTAssertEqual(hidden.resumeLink.workspace, selected)
        XCTAssertEqual(hidden.resumeLink.reference, target)
        XCTAssertEqual(hidden.resumeLink, visible.resumeLink)
    }

    private func workspace(_ profile: String) -> WidgetWorkspaceID {
        WidgetWorkspaceID(dashboardID: UUID(), profile: profile)
    }

    private func reference(profile: String, session: String) -> WidgetConversationReference {
        WidgetConversationReference(kind: .dashboard, scopeProfile: profile, botName: nil, botLabel: nil, sessionID: session, isUnverified: false)
    }

    private func workspaceSnapshot(_ id: WidgetWorkspaceID, last: WidgetConversationReference?) -> WidgetWorkspaceSnapshot {
        let choices = last.map { [WidgetConversationChoice(reference: $0, title: "Cached title", isPinned: false, recency: 1)] } ?? []
        return WidgetWorkspaceSnapshot(id: id, dashboardLabel: id.profile, profileLabel: id.profile, lastConversation: last, choices: choices, recency: 1)
    }
}
