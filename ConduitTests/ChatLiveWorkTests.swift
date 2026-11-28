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
        // Its unnamed start, still to come, is its own: it never brings back the next held send.
        XCTAssertEqual(appState.shownChat.readStartedAdmissions, ["adm-2"])
        appState.applyChatLiveWork(ChatLiveWork(running: false), previous: nil, for: "api-1")
        XCTAssertTrue(appState.shownChat.readStartedAdmissions.isEmpty, "No turn runs: no start is still to come")
    }

    func testAQueuedMessageNothingHoldsComesInFromItsWordsWhenItsTurnStarts() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        // Reopened while it waited: the dock row came from the read, no bubble is held.
        let listed = ChatLiveWork(running: true, queued: [QueuedPrompt(admissionID: "adm-7", text: "from before", status: .queued, sequence: 1)])
        appState.applyChatLiveWork(listed, previous: nil, for: "api-1")
        XCTAssertTrue(appState.messages.isEmpty)
        let turn = ChatLiveWork(running: true, startedAdmissions: ["adm-7"])
        appState.applyChatLiveWork(turn, previous: listed, for: "api-1")
        XCTAssertEqual(appState.messages.map(\.content), ["from before"])
        // Once: the next read naming it again draws nothing more.
        appState.applyChatLiveWork(turn, previous: listed, for: "api-1")
        XCTAssertEqual(appState.messages.map(\.content), ["from before"])
        XCTAssertTrue(appState.authorityQueue.isEmpty)
    }

    func testAReadOfAnotherChatLeavesThisChatsForwardedSendHeld() {
        let appState = makeAppState()
        appState.activeSessionId = "chat-a"
        appState.messages = [ChatMessage(id: "local-1", role: .user, content: "mine", timestamp: "1")]
        appState.holdForwardedSend(admissionID: "adm-1", rowID: "local-1", text: "mine", sessionID: "chat-a")
        appState.activeSessionId = "chat-b"
        appState.applyChatLiveWork(ChatLiveWork(running: false), previous: nil, for: "chat-b")
        XCTAssertEqual(appState.shownChat.queuedSendOrder, ["adm-1"], "chat-a's send waits for chat-a's reads")
    }

    func testADashboardTurnStartNamesTheOldestForwardedMessage() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        XCTAssertEqual(appState.admissionStarting(named: "adm-7", by: nil, in: "api-1"), "adm-7")
        XCTAssertNil(appState.admissionStarting(named: nil, by: nil, in: "api-1"), "No client: nothing to name")
    }

    func testAnUnnamedStartAReadAlreadyAnsweredBringsBackNoOtherSend() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        appState.messages = [ChatMessage(id: "local-1", role: .user, content: "first", timestamp: "1"),
                             ChatMessage(id: "local-2", role: .user, content: "second", timestamp: "2")]
        appState.holdForwardedSend(admissionID: "adm-1", rowID: "local-1", text: "first", sessionID: "api-1")
        appState.holdForwardedSend(admissionID: "adm-2", rowID: "local-2", text: "second", sessionID: "api-1")
        let second = QueuedPrompt(admissionID: "adm-2", text: "second", status: .queued, sequence: 2)
        appState.applyChatLiveWork(ChatLiveWork(running: true, queued: [second], startedAdmissions: ["adm-1"]), previous: nil, for: "api-1")
        XCTAssertEqual(appState.messages.map(\.id), ["local-1"])
        // adm-1's own start, coming after the read, is its own; the next one is adm-2's.
        XCTAssertEqual(appState.forwardedSendStarting(in: "api-1"), "adm-1")
        XCTAssertEqual(appState.forwardedSendStarting(in: "api-1"), "adm-2")
    }

    func testAStartForAnotherClientsQueuedMessageTakesNoHeldSend() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        let other = QueuedPrompt(admissionID: "adm-1", text: "another app's", status: .queued, sequence: 1)
        appState.applyChatLiveWork(ChatLiveWork(running: true, queued: [other]), previous: nil, for: "api-1")
        appState.messages = [ChatMessage(id: "local-2", role: .user, content: "mine", timestamp: "1")]
        appState.holdForwardedSend(admissionID: "adm-2", rowID: "local-2", text: "mine", sessionID: "api-1")
        XCTAssertEqual(appState.authorityQueue.queued.map(\.admissionID), ["adm-1", "adm-2"])
        // adm-1's turn starts first: the send behind it isn't claimed.
        XCTAssertNil(appState.forwardedSendStarting(in: "api-1"))
        XCTAssertEqual(appState.shownChat.queuedSendOrder, ["adm-2"])
        XCTAssertEqual(appState.messages.map(\.id), [])
        // The next read names adm-1 running and adm-2 still waiting: adm-1's
        // words come in from the queue, adm-2 stays in the dock.
        let mine = QueuedPrompt(admissionID: "adm-2", text: "mine", status: .queued, sequence: 2)
        let read = ChatLiveWork(running: true, queued: [mine], startedAdmissions: ["adm-1"])
        appState.applyChatLiveWork(read, previous: ChatLiveWork(running: true, queued: [other, mine]), for: "api-1")
        XCTAssertEqual(appState.authorityQueue.queued.map(\.admissionID), ["adm-2"])
        XCTAssertEqual(appState.shownChat.queuedSendOrder, ["adm-2"])
        XCTAssertTrue(appState.shownChat.readStartedAdmissions.isEmpty, "adm-1's start already came")
        // The next unnamed start, with nothing left ahead of it, is adm-2's.
        XCTAssertEqual(appState.forwardedSendStarting(in: "api-1"), "adm-2")
    }

    /// #3444: another app's start with no send held is recorded too, so a
    /// send held after it keeps its own start once the read brings the
    /// other app's words in.
    func testAnotherAppsStartWithNoSendHeldLeavesTheNextStartToALaterSend() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        let other = QueuedPrompt(admissionID: "adm-1", text: "another app's", status: .queued, sequence: 1)
        appState.applyChatLiveWork(ChatLiveWork(running: true, queued: [other]), previous: nil, for: "api-1")
        // adm-1's unnamed start, with nothing held here.
        XCTAssertNil(appState.forwardedSendStarting(in: "api-1"))
        XCTAssertEqual(appState.shownChat.otherAppStartsSeen, ["adm-1"])
        // A send forwarded after it, then the read naming adm-1 started.
        appState.messages = [ChatMessage(id: "local-2", role: .user, content: "mine", timestamp: "1")]
        appState.holdForwardedSend(admissionID: "adm-2", rowID: "local-2", text: "mine", sessionID: "api-1")
        let mine = QueuedPrompt(admissionID: "adm-2", text: "mine", status: .queued, sequence: 2)
        appState.applyChatLiveWork(ChatLiveWork(running: true, queued: [mine], startedAdmissions: ["adm-1"]),
                                   previous: ChatLiveWork(running: true, queued: [other]), for: "api-1")
        XCTAssertTrue(appState.shownChat.readStartedAdmissions.isEmpty, "adm-1's start already came")
        // The next unnamed start is adm-2's.
        XCTAssertEqual(appState.forwardedSendStarting(in: "api-1"), "adm-2")
    }

    func testAnUnheldQueuedMessageThatLeftUnrunReadsTheChatAgainOnceNoTurnRuns() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        let other = QueuedPrompt(admissionID: "adm-1", text: "another app's", status: .queued, sequence: 1)
        let listed = ChatLiveWork(running: true, queued: [other])
        // Still running there: its words may not be stored yet.
        XCTAssertFalse(appState.queuedMessageLeftUnrun(ChatLiveWork(running: true), previous: listed))
        // No turn runs and it's gone: it ran and ended, or was withdrawn.
        XCTAssertTrue(appState.queuedMessageLeftUnrun(ChatLiveWork(running: false), previous: listed))
        // Still waiting, or started: not gone.
        XCTAssertFalse(appState.queuedMessageLeftUnrun(ChatLiveWork(running: false, queued: [other]), previous: listed))
        XCTAssertFalse(appState.queuedMessageLeftUnrun(ChatLiveWork(running: false, startedAdmissions: ["adm-1"]), previous: listed))
        XCTAssertFalse(appState.queuedMessageLeftUnrun(ChatLiveWork(running: false), previous: nil))
        // One the app holds settles through its own row instead.
        appState.holdQueuedSendRow(ChatMessage(id: "local-1", role: .user, content: "another app's", timestamp: "1"), admissionID: "adm-1")
        XCTAssertFalse(appState.queuedMessageLeftUnrun(ChatLiveWork(running: false), previous: listed))
    }

    func testAnUnnamedStartInAnotherChatTakesNoneOfThisChatsSends() {
        let appState = makeAppState()
        appState.activeSessionId = "chat-a"
        appState.messages = [ChatMessage(id: "local-1", role: .user, content: "mine", timestamp: "1")]
        appState.holdForwardedSend(admissionID: "adm-1", rowID: "local-1", text: "mine", sessionID: "chat-a")
        XCTAssertNil(appState.forwardedSendStarting(in: "chat-b"), "chat-b's turn is none of chat-a's sends")
        XCTAssertEqual(appState.shownChat.queuedSendOrder, ["adm-1"])
        XCTAssertEqual(appState.forwardedSendStarting(in: "chat-a"), "adm-1")
    }

    func testAnUnnamedStartUnderTheChatsOtherIdTakesItsSend() {
        let appState = makeAppState()
        appState.activeSessionId = "chat-a"
        appState.sessions = [row("chat-a", alternateIds: ["runtime-a"])]
        appState.messages = [ChatMessage(id: "local-1", role: .user, content: "mine", timestamp: "1")]
        appState.holdForwardedSend(admissionID: "adm-1", rowID: "local-1", text: "mine", sessionID: "chat-a")
        XCTAssertEqual(appState.forwardedSendStarting(in: "runtime-a"), "adm-1")
    }

    func testAnUnnamedStartUnderABorrowedIdTakesNoneOfThatChatsSends() {
        let appState = makeAppState()
        appState.activeSessionId = "shared-runtime"
        appState.sessions = [row("bot-b", alternateIds: ["shared-runtime"]), row("shared-runtime", alternateIds: [])]
        appState.messages = [ChatMessage(id: "local-1", role: .user, content: "mine", timestamp: "1")]
        appState.holdForwardedSend(admissionID: "adm-1", rowID: "local-1", text: "mine", sessionID: "shared-runtime")
        XCTAssertNil(appState.forwardedSendStarting(in: "bot-b"), "bot-b only carries the other chat's id")
        XCTAssertEqual(appState.forwardedSendStarting(in: "shared-runtime"), "adm-1")
    }

    private func row(_ id: String, alternateIds: [String]) -> SessionSummary {
        SessionSummary(id: id, alternateIds: alternateIds, title: id, model: "Hermes", updatedLabel: "now",
                       profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
    }

    func testTheStampCapKeepsHeldSendsStamps() {
        let appState = makeAppState()
        appState.activeSessionId = "api-1"
        appState.messages = [ChatMessage(id: "local-h", role: .user, content: "held", timestamp: "1")]
        appState.messages.append(ChatMessage(id: "local-s", role: .user, content: "started", timestamp: "2"))
        appState.holdForwardedSend(admissionID: "adm-h", rowID: "local-h", text: "held", sessionID: "api-1")
        appState.holdForwardedSend(admissionID: "adm-s", rowID: "local-s", text: "started", sessionID: "api-1")
        // A read names adm-s started: it awaits its own unnamed start, its chat kept.
        let waiting = QueuedPrompt(admissionID: "adm-h", text: "held", status: .queued, sequence: 1)
        appState.applyChatLiveWork(ChatLiveWork(running: true, queued: [waiting], startedAdmissions: ["adm-s"]), previous: nil, for: "api-1")
        XCTAssertEqual(appState.shownChat.readStartedAdmissions, ["adm-s"])
        // Stamps for sends no longer held (their rows gone) fill the cap.
        for index in 0..<31 {
            appState.holdForwardedSend(admissionID: "adm-\(index)", rowID: "gone-\(index)", text: "x", sessionID: "api-1")
        }
        appState.holdForwardedSend(admissionID: "adm-new", rowID: "gone-new", text: "x", sessionID: "api-1")
        XCTAssertEqual(Set(appState.shownChat.forwardedSendTimes.keys), ["adm-h", "adm-new"])
        XCTAssertEqual(Set(appState.shownChat.forwardedSendChats.keys), ["adm-h", "adm-s", "adm-new"])
        XCTAssertEqual(appState.forwardedSendStarting(in: "api-1"), "adm-s", "Its own start still finds it")
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
