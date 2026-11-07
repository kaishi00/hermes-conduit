//
//  AuthorityQueueAppStateTests.swift
//  ConduitTests
//
//  The user's own message while it waits in a chat's queue on the
//  gateway's own listener: in the dock, never in the transcript too, and
//  back in the transcript when its turn starts.
//

import XCTest
@testable import Conduit

@MainActor
final class AuthorityQueueAppStateTests: XCTestCase {
    func testAnOwnSendTheQueueListsAsWaitingMovesToTheDockAndBackAtItsTurn() {
        let appState = makeAppState()
        appState.activeSessionId = "sess-q"
        let mine = ChatMessage(id: "local-1", role: .user, content: "later", timestamp: "1")
        appState.messages = [ChatMessage(id: "r1", role: .assistant, content: "Earlier", timestamp: "0"), mine]
        appState.noteOwnSend(admissionID: "adm-2", rowID: "local-1")

        // Held behind a turn a restart cut off, or behind another client's turn.
        appState.adoptOwnQueuedSends([
            QueuedPrompt(admissionID: "adm-1", text: "cut off", status: .unknown, executionGeneration: 1, sequence: 1),
            QueuedPrompt(admissionID: "adm-2", text: "later", status: .queued, sequence: 2)
        ])
        XCTAssertEqual(appState.messages.map(\.id), ["r1"], "Shown once: in the dock while it waits")

        appState.noteQueuedTurnStarted(sessionID: "sess-q", admissionID: "adm-2")
        XCTAssertEqual(appState.messages.map(\.id), ["r1", "local-1"], "Back above its reply when its turn starts")
        XCTAssertNil(appState.takeQueuedSendRow(admissionID: "adm-2"))
    }

    func testAMessageAlreadyRunningOrAnotherClientsStaysWhereItIs() {
        let appState = makeAppState()
        appState.activeSessionId = "sess-q"
        appState.messages = [ChatMessage(id: "local-1", role: .user, content: "now", timestamp: "1")]
        appState.noteOwnSend(admissionID: "adm-1", rowID: "local-1")
        appState.adoptOwnQueuedSends([
            QueuedPrompt(admissionID: "adm-1", text: "now", status: .started, sequence: 1),
            QueuedPrompt(admissionID: "adm-9", text: "someone else", status: .queued, sequence: 2)
        ])
        XCTAssertEqual(appState.messages.map(\.id), ["local-1"])
        // Another client's queued turn starting adds nothing of ours.
        appState.noteQueuedTurnStarted(sessionID: "sess-q", admissionID: "adm-9")
        XCTAssertEqual(appState.messages.map(\.id), ["local-1"])
    }

    private func makeAppState() -> AppState {
        let suite = "AuthorityQueueAppStateTests.\(UUID().uuidString)"
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
