//
//  ChatLiveWorkTests.swift
//  ConduitTests
//
//  A chat's turn running in the gateway on `hermes dashboard` (Eric,
//  2026-11-27): the plugin's read of it, the queue dock it fills without
//  buttons, and the user's waiting message back in the chat at its turn.
//

import XCTest
@testable import Conduit

@MainActor
final class ChatLiveWorkTests: XCTestCase {
    func testTheAnswerReadsTheTurnItsAgentsAndTheQueue() {
        let work = ChatLiveWork(response: [
            "running": true,
            "step": ["phase": "tool", "tool": "agents", "since": 11.0],
            "agents": [
                ["id": "child-1", "goal": "Generate the office still", "phase": "tool", "tool": "terminal", "since": 13.0, "started": 12.0],
                ["id": "", "goal": "no id", "phase": "thinking"],
                ["id": "child-2", "phase": "dancing"],
            ],
            "queued": [
                ["admission_id": "adm-3", "input_id": "in-3", "text": "second", "status": "queued", "sequence": 3],
                ["admission_id": "adm-2", "text": "first", "status": "queued", "sequence": 2],
                ["admission_id": "adm-1", "text": "running", "status": "started", "sequence": 1],
            ],
        ])
        XCTAssertTrue(work.running)
        XCTAssertEqual(work.step?.phase, .tool)
        XCTAssertEqual(work.step?.tool, .agents)
        XCTAssertEqual(work.agents.map(\.id), ["child-1"])
        XCTAssertEqual(work.agents.first?.goal, "Generate the office still")
        XCTAssertEqual(work.agents.first?.step.tool, .terminal)
        XCTAssertEqual(work.agents.first?.started, 12.0)
        XCTAssertEqual(work.queued.map(\.admissionID), ["adm-2", "adm-3"], "Oldest first, waiting rows only")
        XCTAssertEqual(work.queued.last?.inputID, "in-3")
        XCTAssertFalse(work.queued.contains { $0.canSendNow || $0.canEdit }, "The dashboard serves none of the verbs")
        XCTAssertTrue(work.isActive)
        XCTAssertFalse(ChatLiveWork(response: ["running": false, "queued": []]).isActive)
    }

    func testTheRouteNamesTheChat() {
        XCTAssertEqual(ChatLiveWork.route(sessionID: "api 1"), "/api/plugins/conduit_push/sessions/live-work?session_id=api%201")
    }

    func testTheGatewaysQueueShowsInTheDockWithoutButtons() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        let work = ChatLiveWork(running: true, queued: [QueuedPrompt(admissionID: "adm-2", text: "waiting", status: .queued, sequence: 2)])
        appState.applyChatLiveWork(work, previous: nil, for: "api-1")
        XCTAssertTrue(appState.authorityQueue.readOnly)
        XCTAssertEqual(appState.authorityQueue.queued.map(\.admissionID), ["adm-2"])
        // Another chat's read lands nowhere.
        appState.applyChatLiveWork(ChatLiveWork(), previous: nil, for: "other")
        XCTAssertEqual(appState.authorityQueue.queued.map(\.admissionID), ["adm-2"])
        // The Webapp's own `pending` takes the dock back, with its buttons.
        appState.authorityQueue.apply([QueuedPrompt(admissionID: "adm-9", text: "x", status: .queued)], for: "api-1")
        XCTAssertFalse(appState.authorityQueue.readOnly)
        appState.authorityQueue.apply([], for: "api-1", readOnly: true)
        appState.clearAuthorityQueueState()
        XCTAssertFalse(appState.authorityQueue.readOnly)
    }

    func testAWaitingMessageOfTheUsersComesBackWhenItLeavesTheQueue() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        appState.messages = [ChatMessage(id: "a-1", role: .assistant, content: "Earlier", timestamp: "0")]
        appState.holdQueuedSendRow(ChatMessage(id: "local-1", role: .user, content: "did you start them?", timestamp: "1"), admissionID: "adm-2")
        let waiting = QueuedPrompt(admissionID: "adm-2", text: "did you start them?", status: .queued, sequence: 2)
        appState.applyChatLiveWork(ChatLiveWork(running: true, queued: [waiting]), previous: nil, for: "api-1")
        XCTAssertEqual(appState.messages.map(\.id), ["a-1"], "Shown once: in the dock while it waits")
        appState.applyChatLiveWork(ChatLiveWork(running: true, startedAdmissions: ["adm-2"]),
                                   previous: ChatLiveWork(running: true, queued: [waiting]), for: "api-1")
        XCTAssertEqual(appState.messages.map(\.id), ["a-1", "local-1"], "Its turn started there")
        XCTAssertTrue(appState.authorityQueue.isEmpty)
    }

    func testAForwardedSendStaysInTheDockUntilAReadAskedAfterItSettlesIt() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        let other = QueuedPrompt(admissionID: "adm-1", text: "another app's", status: .queued, sequence: 1)
        appState.applyChatLiveWork(ChatLiveWork(running: true, queued: [other]), previous: nil, for: "api-1")
        appState.messages = [ChatMessage(id: "local-2", role: .user, content: "mine", timestamp: "1")]
        appState.holdForwardedSend(admissionID: "adm-2", rowID: "local-2", text: "mine", sessionID: "api-1")
        XCTAssertEqual(appState.messages.map(\.id), [], "In the dock, not the chat")
        XCTAssertEqual(appState.authorityQueue.queued.map(\.admissionID), ["adm-1", "adm-2"], "Behind the rows already waiting")
        // A read asked before the send can't list it: it stays held, its row kept.
        var stale = ChatLiveWork(running: true, queued: [other])
        stale.askedAt = .distantPast
        appState.applyChatLiveWork(stale, previous: nil, for: "api-1")
        XCTAssertEqual(appState.messages.map(\.id), [])
        XCTAssertEqual(appState.authorityQueue.queued.map(\.admissionID), ["adm-1", "adm-2"])
        // A later read without it, and not running it: it ran and ended, or was
        // withdrawn; the dock lets it go and the chat's stored rows tell which.
        appState.applyChatLiveWork(ChatLiveWork(running: true, queued: [other]), previous: stale, for: "api-1")
        XCTAssertEqual(appState.messages.map(\.id), [])
        XCTAssertEqual(appState.authorityQueue.queued.map(\.admissionID), ["adm-1"])
        XCTAssertTrue(appState.shownChat.queuedSendOrder.isEmpty)
    }

    func testAForwardedSendNoReadListedComesBackWhenARunningTurnIsItsOwn() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        appState.messages = [ChatMessage(id: "local-2", role: .user, content: "mine", timestamp: "1")]
        appState.holdForwardedSend(admissionID: "adm-2", rowID: "local-2", text: "mine", sessionID: "api-1")
        appState.applyChatLiveWork(ChatLiveWork(running: true, startedAdmissions: ["adm-2"]), previous: nil, for: "api-1")
        XCTAssertEqual(appState.messages.map(\.id), ["local-2"])
        XCTAssertTrue(appState.authorityQueue.isEmpty)
    }

    func testADashboardTurnStartNamesTheOldestForwardedMessage() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        XCTAssertEqual(appState.admissionStarting(named: "adm-7", by: nil), "adm-7")
        XCTAssertNil(appState.admissionStarting(named: nil, by: nil), "No client: nothing to name")
    }

    private func makeAppState() -> AppState {
        let suite = "ChatLiveWorkTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Failed to create test UserDefaults suite") }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        return AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            dashboardRegistry: nil,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: .live,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            conversationIdentityIndex: nil
        )
    }
}
