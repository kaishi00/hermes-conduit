import XCTest
import SwiftUI
import UIKit
@testable import Conduit

@MainActor
final class ComposerDraftLifetimeTests: XCTestCase {
    func testShellOwnedStoreSurvivesComposerBarTeardown() throws {
        let suite = "ComposerDraftLifetimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let key = ComposerBar.composerDraftKey(for: "sess-1", profile: "default")
        appState.composerDraftStore.save(
            ComposerDraft(text: "keep me", attachments: []),
            for: key
        )

        // Simulate ChatView / ComposerBar unmount by dropping the only view
        // reference while the shell-owned store remains on AppState.
        var host: UIHostingController<AnyView>? = UIHostingController(
            rootView: AnyView(ComposerBar().environmentObject(appState))
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = host
        window.isHidden = false
        host?.view.setNeedsLayout()
        host?.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        window.rootViewController = nil
        host = nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(appState.composerDraftStore.draft(for: key).text, "keep me")
    }

    func testDisconnectClearsComposerDrafts() throws {
        let suite = "ComposerDraftLifetimeDisconnect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let key = ComposerBar.composerDraftKey(for: "sess-1", profile: "default")
        appState.composerDraftStore.save(
            ComposerDraft(text: "gone on sign-out", attachments: []),
            for: key
        )

        appState.disconnect()

        XCTAssertTrue(appState.composerDraftStore.draft(for: key).isEmpty)
    }
}

@MainActor
final class AgentAvatarIdentityTests: XCTestCase {
    func testSeedIsDeterministicAndIndependentOfDisplayName() {
        let a = AgentAvatarIdentity.seed(for: "research")
        let b = AgentAvatarIdentity.seed(for: "research")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(
            AgentAvatarIdentity.seed(for: "research"),
            AgentAvatarIdentity.seed(for: "ops")
        )
        XCTAssertEqual(
            AgentAvatarIdentity.shape(for: a),
            AgentAvatarIdentity.shape(for: b)
        )
    }

    func testSidebarTabDisplayTitlesPreserveRawValues() {
        XCTAssertEqual(SidebarTab.sessions.rawValue, "Sessions")
        XCTAssertEqual(SidebarTab.sessions.title, "Chats")
        XCTAssertEqual(SidebarTab.cron.title, "Scheduled")
        XCTAssertEqual(SidebarTab.kanban.title, "Boards")
    }

    func testChatsHomePaneTitlesPreserveRawValues() {
        XCTAssertEqual(ChatsHomePane.bots.rawValue, "bots")
        XCTAssertEqual(ChatsHomePane.sessions.rawValue, "sessions")
        XCTAssertEqual(ChatsHomePane.bots.title, "Bots")
        XCTAssertEqual(ChatsHomePane.sessions.title, "Sessions")
    }

    func testAccessoryIsStableForSeed() {
        let research = AgentAvatarIdentity.seed(for: "research")
        let ops = AgentAvatarIdentity.seed(for: "ops")
        XCTAssertEqual(
            AgentAvatarIdentity.accessory(for: research),
            AgentAvatarIdentity.accessory(for: research)
        )
        // Distinct profiles should differ in shape, accessory, or palette slot.
        XCTAssertTrue(
            AgentAvatarIdentity.accessory(for: research) != AgentAvatarIdentity.accessory(for: ops)
                || AgentAvatarIdentity.shape(for: research) != AgentAvatarIdentity.shape(for: ops)
                || (research % 6) != (ops % 6)
        )
    }
}

@MainActor
final class ProfilePinTests: XCTestCase {
    func testPinOrderIsStableAndPersists() throws {
        let suite = "ProfilePinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["default", "research", "ops"], forKey: "conduit.knownProfiles.v1")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        XCTAssertTrue(Set(appState.profiles).isSuperset(of: ["default", "research", "ops"]))

        appState.toggleProfilePinned("research")
        appState.toggleProfilePinned("ops")
        XCTAssertEqual(appState.pinnedProfileIDs, ["research", "ops"])
        XCTAssertTrue(appState.isProfilePinned("research"))
        XCTAssertFalse(appState.isProfilePinned("default"))

        appState.toggleProfilePinned("research")
        XCTAssertEqual(appState.pinnedProfileIDs, ["ops"])

        let reloaded = AppState(defaults: defaults, loadSavedConnection: false)
        XCTAssertEqual(reloaded.pinnedProfileIDs, ["ops"])
    }

    func testPruneDropsUnknownPinsPreservingOrder() throws {
        let suite = "ProfilePinPrune.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["default", "research", "ops"], forKey: "conduit.knownProfiles.v1")
        defaults.set(["research", "ghost", "ops"], forKey: "conduit.pinnedProfileIds.v1")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        XCTAssertEqual(appState.pinnedProfileIDs, ["research", "ops"])
    }

    func testDisconnectClearsProfilePins() throws {
        let suite = "ProfilePinDisconnect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.toggleProfilePinned("default")
        XCTAssertFalse(appState.pinnedProfileIDs.isEmpty)
        appState.disconnect()
        XCTAssertTrue(appState.pinnedProfileIDs.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: "conduit.pinnedProfileIds.v1"))
    }
}

@MainActor
final class ConversationActivityCopyTests: XCTestCase {
    func testSecondaryLineNeverIncludesModel() {
        let session = makeSession(source: .chat, model: "gpt-test")
        let line = ConversationActivityCopy.secondaryLine(
            session: session,
            cachedSnippet: nil,
            liveMessages: nil
        )
        XCTAssertEqual(line, session.source.label)
        XCTAssertFalse(line.contains("gpt-test"))
    }

    func testSecondaryLinePrefersLiveSnippetOverSource() {
        let session = makeSession(source: .api, model: "gpt-test")
        let messages = [
            ChatMessage(id: "1", role: .user, content: "Ship the inbox polish", timestamp: ""),
            ChatMessage(id: "2", role: .tool, content: "tool noise", timestamp: ""),
        ]
        let line = ConversationActivityCopy.secondaryLine(
            session: session,
            cachedSnippet: "stale cache",
            liveMessages: messages
        )
        XCTAssertEqual(line, "Ship the inbox polish")
    }

    func testSecondaryLineUsesCacheWhenLiveEmpty() {
        let session = makeSession(source: .discord, model: "gpt-test")
        let line = ConversationActivityCopy.secondaryLine(
            session: session,
            cachedSnippet: "Cached activity",
            liveMessages: []
        )
        XCTAssertEqual(line, "Cached activity")
    }

    private func makeSession(source: SessionSource, model: String) -> SessionSummary {
        SessionSummary(
            id: "s1",
            alternateIds: [],
            title: "Planning",
            model: model,
            updatedLabel: "now",
            profile: "default",
            source: source,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}

final class AgentAvatarStateTests: XCTestCase {
    private func resolve(turn: TurnState = .idle, connected: Bool = true, switching: Bool = false,
                         input: Bool = false, failure: Bool = false, tool: Bool = false,
                         output: Bool = false, reply: Bool = false) -> AgentAvatarState {
        AgentAvatarState.resolve(turn: turn, connected: connected, switching: switching,
                                 needsInput: input, hasFailure: failure, hasTool: tool,
                                 hasOutput: output, hasReply: reply)
    }

    func testRunningDistinguishesThinkingFromExecution() {
        XCTAssertEqual(resolve(turn: .running), .thinking)
        XCTAssertEqual(resolve(turn: .running, tool: true), .working)
        XCTAssertEqual(resolve(turn: .running, output: true), .working)
    }

    func testAttentionTakesPrecedenceOverRunningAndOldReply() {
        XCTAssertEqual(resolve(turn: .running, input: true, output: true), .waiting)
        XCTAssertEqual(resolve(turn: .running, input: true, failure: true), .blocked)
        XCTAssertEqual(resolve(connected: false, reply: true), .blocked)
        XCTAssertEqual(resolve(turn: .unsupportedGateway, reply: true), .blocked)
    }

    func testSynchronizationNeverClaimsCompletionOrFailure() {
        XCTAssertEqual(resolve(turn: .synchronizing, connected: false, reply: true), .waiting)
        XCTAssertEqual(resolve(turn: .reconnecting, connected: false), .waiting)
        XCTAssertEqual(resolve(switching: true, failure: true), .waiting)
    }

    func testCompletionRequiresAReplyAndAnIdleTurn() {
        XCTAssertEqual(resolve(), .idle)
        XCTAssertEqual(resolve(reply: true), .done)
        XCTAssertEqual(resolve(turn: .running, reply: true), .thinking)
    }
}

@MainActor
final class AgentAvatarProfileStateTests: XCTestCase {
    func testLiveStateNeverLeaksIntoAnotherProfile() {
        let app = AppState(loadSavedConnection: false)
        app.isConnected = false
        XCTAssertEqual(app.avatarState(for: app.activeProfile), .blocked)
        XCTAssertEqual(app.avatarState(for: "another-profile"), .idle)
    }

    func testOldAttentionCardsDoNotBlockANewCompletedTurn() {
        let app = AppState(loadSavedConnection: false)
        app.isConnected = true
        app.messages = [
            ChatMessage(id: "approval", role: .approval, content: "", timestamp: "", approval:
                ApprovalActivity(sessionId: "session", command: "test", description: "test",
                                 allowPermanent: false, smartDenied: false, status: .error)),
            ChatMessage(id: "new-turn", role: .user, content: "Try again", timestamp: ""),
            ChatMessage(id: "reply", role: .assistant, content: "Done", timestamp: "")
        ]
        XCTAssertEqual(app.avatarState(for: app.activeProfile), .done)
    }

    func testCurrentApprovalWaitsInsteadOfClaimingCompletion() {
        let app = AppState(loadSavedConnection: false)
        app.isConnected = true
        app.messages = [
            ChatMessage(id: "user", role: .user, content: "Run this", timestamp: ""),
            ChatMessage(id: "reply", role: .assistant, content: "Let me check", timestamp: ""),
            ChatMessage(id: "approval", role: .approval, content: "", timestamp: "", approval:
                ApprovalActivity(sessionId: "session", command: "test", description: "test",
                                 allowPermanent: false, smartDenied: false, status: .pending))
        ]
        XCTAssertEqual(app.avatarState(for: app.activeProfile), .waiting)
    }
}
