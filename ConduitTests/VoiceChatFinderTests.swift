//
//  VoiceChatFinderTests.swift
//  Conduit
//
//  A live call finds one of the user's earlier chats and opens it while the
//  call goes on: Hermes' search response, the supervisor's numbered
//  matches, Gemini/Grok's find_chat and open_chat, and GPT-Live's "Find
//  chat:" and "Open chat:" delegations. An extension of an existing suite:
//  the CI test planner is at capacity for new XCTestCase classes.
//

import SwiftUI
import XCTest
@testable import Conduit

@MainActor
extension VoiceConversationControllerTests {
    /// A supervisor whose chat search answers from `results` by query, and
    /// whose opens are recorded.
    private func makeChatFinder(
        _ results: [String: [VoiceChatMatch]],
        canOpen: Bool = true
    ) -> (VoiceBackgroundJobSupervisor, ChatFinderLog) {
        let log = ChatFinderLog()
        let backend = VoiceBackgroundJobBackend(
            createSession: { _ in ("rt-1", "st-1") },
            setTitle: { _, _ in },
            submit: { _, _ in },
            cancel: { _ in },
            liveSessions: { _ in [] },
            searchChats: { query in
                log.queries.append(query)
                return results[query] ?? []
            }
        )
        let supervisor = VoiceBackgroundJobSupervisor(backend: backend, pollInterval: .seconds(3_600))
        supervisor.openChat = { match in
            log.opened.append(match.sessionID)
            return canOpen
        }
        return (supervisor, log)
    }

    private static func chat(_ id: String, _ title: String, snippet: String = "") -> VoiceChatMatch {
        VoiceChatMatch(sessionID: id, title: title, snippet: snippet, lastActive: nil)
    }

    func testChatSearchResponseKeepsHermesOrderWithoutMatchMarkers() {
        let response: [String: Any] = ["results": [
            ["session_id": "s-tip", "id": "s-tip", "title": "GPU setup", "snippet": "we put the >>>GPU<<< in\nslot two", "last_active": 1_700_000_000.5],
            ["session_id": "s-tip", "title": "Duplicate lineage row"],
            ["session_id": "s-2", "title": NSNull(), "snippet": "", "session_started": 1_690_000_000],
            ["title": "No id"],
        ]]
        let matches = VoiceChatFinder.matches(from: response)
        XCTAssertEqual(matches.map(\.sessionID), ["s-tip", "s-2"])
        XCTAssertEqual(matches[0].title, "GPU setup")
        XCTAssertEqual(matches[0].snippet, "we put the GPU in slot two")
        XCTAssertEqual(matches[0].lastActive, Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(matches[1].title, "")
        XCTAssertEqual(matches[1].lastActive, Date(timeIntervalSince1970: 1_690_000_000), "a content hit carries only when it started")
        XCTAssertTrue(VoiceChatFinder.matches(from: ["ok": true]).isEmpty)
    }

    func testChatSearchQueryIsWordsOnly() {
        XCTAssertEqual(VoiceChatFinder.searchQuery("  \"GPU\" set-up: drivers*  "), "GPU set up drivers")
        XCTAssertEqual(VoiceChatFinder.searchQuery("??"), "")
        XCTAssertEqual(VoiceChatFinder.fallbackWords("GPU home setup"), ["setup", "home"], "longest first, two at most, short words skipped")
        XCTAssertEqual(VoiceChatFinder.fallbackWords("GPU"), [], "a single word was already tried")
        XCTAssertEqual(
            VoiceChatFinder.path(query: "GPU setup", profile: "work"),
            "/api/sessions/search?q=GPU%20setup&limit=\(VoiceChatFinder.resultLimit)&profile=work"
        )
        XCTAssertEqual(VoiceChatFinder.path(query: "x", profile: "default"), "/api/sessions/search?q=x&limit=\(VoiceChatFinder.resultLimit)")
    }

    func testTitleFallbackFindsListedChatsNewestFirst() {
        func row(_ id: String, _ title: String, at time: TimeInterval?, archived: Bool = false) -> SessionSummary {
            SessionSummary(
                id: id, storedSessionId: "st-\(id)", alternateIds: [], title: title, model: "", updatedLabel: "",
                lastActivityAt: time, profile: nil, source: .chat, isActive: false, isArchived: archived, lineageRootId: nil
            )
        }
        let rows = [
            row("a", "GPU setup notes", at: 100),
            row("b", "Home GPU setup", at: 300),
            row("c", "GPU setup (old)", at: 500, archived: true),
            row("d", "Groceries", at: 900),
        ]
        let matches = VoiceChatFinder.titleMatches(in: rows, query: "gpu SETUP")
        XCTAssertEqual(matches.map(\.sessionID), ["st-b", "st-a"], "every word, any case, archived chats left out")
    }

    func testChatSummaryNumbersEachMatchWithItsAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let matches = [
            VoiceChatMatch(sessionID: "1", title: "GPU setup", snippet: "the 4090 drivers", lastActive: now.addingTimeInterval(-3 * 86_400)),
            VoiceChatMatch(sessionID: "2", title: "", snippet: "", lastActive: nil),
        ]
        XCTAssertEqual(
            VoiceChatFinder.summary(matches, now: now),
            "1. \"GPU setup\", last active 3 days ago: the 4090 drivers\n2. Untitled chat"
        )
        XCTAssertEqual(VoiceChatFinder.spokenAge(of: now, now: now), "today")
        XCTAssertEqual(VoiceChatFinder.spokenAge(of: now.addingTimeInterval(-86_400), now: now), "yesterday")
        XCTAssertEqual(VoiceChatFinder.spokenAge(of: now.addingTimeInterval(-21 * 86_400), now: now), "3 weeks ago")
        XCTAssertEqual(VoiceChatFinder.plainSnippet(String(repeating: "a", count: 400)).count, VoiceChatFinder.maximumSnippetCharacters + 1)
    }

    func testSupervisorRetriesWordByWordAndOpensByNumber() async {
        let gpu = Self.chat("s-gpu", "GPU setup")
        let home = Self.chat("s-home", "Home server")
        let (supervisor, log) = makeChatFinder(["setup": [gpu], "home": [home, gpu]])

        let outcome = await supervisor.findChats(query: "home setup")
        XCTAssertEqual(log.queries, ["home setup", "setup", "home"], "the whole query matched nothing, so each word is tried")
        XCTAssertEqual(outcome, .found([gpu, home]), "merged without duplicates, in the order found")

        XCTAssertEqual(supervisor.openFoundChat("2"), .opened(title: "Home server"))
        XCTAssertEqual(supervisor.openFoundChat("number 1"), .opened(title: "GPU setup"))
        XCTAssertEqual(supervisor.openFoundChat("s-home"), .opened(title: "Home server"), "an id from the list opens too")
        XCTAssertEqual(log.opened, ["s-home", "s-gpu", "s-home"])
        XCTAssertEqual(supervisor.openFoundChat("3"), .unknownChat)
        XCTAssertEqual(supervisor.openFoundChat("s-elsewhere"), .unknownChat, "never a chat the search didn't find")

        supervisor.beginLiveCall()
        XCTAssertEqual(supervisor.openFoundChat("1"), .unknownChat, "a new call starts with no matches")
    }

    func testSupervisorReportsNoMatchesAndChatsThatCantOpen() async {
        let (supervisor, _) = makeChatFinder(["router": [Self.chat("s-1", "Router")]], canOpen: false)
        let none = await supervisor.findChats(query: "printer")
        XCTAssertEqual(none, .noMatches)
        let blank = await supervisor.findChats(query: "  ?? ")
        XCTAssertEqual(blank, .failed("query is required"))
        _ = await supervisor.findChats(query: "router")
        XCTAssertEqual(supervisor.openFoundChat("1"), .unavailable)
    }

    func testGeminiLiveFindsAChatThenOpensItWithoutEndingTheCall() async {
        let (supervisor, log) = makeChatFinder(["GPU setup": [Self.chat("s-gpu", "GPU setup", snippet: "drivers"), Self.chat("s-old", "Old rig")]])
        let bridge = GeminiLiveToolBridge(supervisor: supervisor)
        supervisor.beginLiveCall()

        let found = await bridge.handle(.init(id: "f1", name: "find_chat", arguments: ["query": "GPU setup"]))
        guard case .toolResponse(let id, _, let result, let scheduling)? = found.first, found.count == 1 else { return XCTFail("\(found)") }
        XCTAssertEqual(id, "f1")
        XCTAssertEqual(scheduling, .whenIdle, "the matches are spoken once the model's \"let me look\" is done")
        XCTAssertEqual(result["chats"], "1. \"GPU setup\": drivers\n2. \"Old rig\"")
        XCTAssertTrue(result["message"]?.contains("ask which one") == true)

        let opened = await bridge.handle(.init(id: "o1", name: "open_chat", arguments: ["number": "1"]))
        guard case .toolResponse(_, _, let openResult, let openScheduling)? = opened.first else { return XCTFail("\(opened)") }
        XCTAssertEqual(openResult["status"], "opened")
        XCTAssertNil(openScheduling, "open_chat is a quick BLOCKING answer")
        XCTAssertEqual(log.opened, ["s-gpu"])
        XCTAssertFalse(opened.contains(.endConversation))

        let wrong = await bridge.handle(.init(id: "o2", name: "open_chat", arguments: ["number": "9"]))
        guard case .toolResponse(_, _, let wrongResult, _)? = wrong.first else { return XCTFail("\(wrong)") }
        XCTAssertNotNil(wrongResult["error"])

        let empty = await bridge.handle(.init(id: "f2", name: "find_chat", arguments: ["query": " "]))
        guard case .toolResponse(_, _, let emptyResult, _)? = empty.first else { return XCTFail("\(empty)") }
        XCTAssertEqual(emptyResult["error"], "query is required")
    }

    func testChatToolsAreOfferedOnlyOnThePhone() {
        XCTAssertFalse(GeminiLiveToolBridge.declarations(webSearch: false).contains { $0.name == "find_chat" })
        let phone = GeminiLiveToolBridge.declarations(webSearch: false, chats: true).map(\.name)
        XCTAssertTrue(phone.contains("find_chat"))
        XCTAssertTrue(phone.contains("open_chat"))
        XCTAssertEqual(GeminiLiveToolBridge.chatDeclarations.map(\.behavior), [.nonBlocking, .blocking])
        let watch = GeminiLiveToolBridge.watchDeclarations(webSearch: true, memoryRecall: true).map(\.name)
        XCTAssertFalse(watch.contains("find_chat"), "the chat opens on the phone, which a Watch call isn't using")
        XCTAssertTrue(GeminiLiveConversationController.instructions(search: .hermes).contains("find_chat"))
        XCTAssertFalse(GeminiLiveConversationController.instructions(search: .hermes, asksFirst: false, onWatch: true).contains("find_chat"))
        XCTAssertTrue(GPTLiveConversationController.briefing(onWatch: false).contains("\"Find chat:\""))
        XCTAssertFalse(GPTLiveConversationController.briefing(onWatch: true).contains("Find chat"))
    }

    func testGPTLiveChatMarkers() {
        XCTAssertEqual(GPTLiveDelegationBridge.findChatMarker(in: "Find chat: GPU setup"), "GPU setup")
        XCTAssertEqual(GPTLiveDelegationBridge.findChatMarker(in: " find the chat:GPU"), "GPU")
        XCTAssertNil(GPTLiveDelegationBridge.findChatMarker(in: "Find out about the chat app"))
        XCTAssertEqual(GPTLiveDelegationBridge.openChatMarker(in: "Open chat: 2"), "2")
        XCTAssertEqual(GPTLiveDelegationBridge.openChatMarker(in: "open chat 3: the GPU one"), "3")
        XCTAssertEqual(GPTLiveDelegationBridge.openChatMarker(in: "Open chat: number 1"), "1")
        XCTAssertNil(GPTLiveDelegationBridge.openChatMarker(in: "Open chat: the GPU one"), "a number, or nothing")
        XCTAssertNil(GPTLiveDelegationBridge.openChatMarker(in: "Open the chat app and check"))
    }

    func testGPTLiveFindsAndOpensAChatWithoutStartingAJob() async {
        let (supervisor, log) = makeChatFinder(["GPU": [Self.chat("s-gpu", "GPU setup")]])
        let bridge = GPTLiveDelegationBridge(supervisor: supervisor)
        supervisor.beginLiveCall()

        let found = await bridge.handleDelegation(id: "d1", request: "Find chat: GPU" + GPTLiveConversationController.delegationContextMarker + "user: find the GPU chat")
        guard case .delegationReply(let id, let text, let channel)? = found.first, found.count == 1 else { return XCTFail("\(found)") }
        XCTAssertEqual(id, "d1")
        XCTAssertEqual(channel, .commentary)
        XCTAssertTrue(text.contains("1. \"GPU setup\""), text)
        XCTAssertEqual(log.queries, ["GPU"], "the conversation added for context isn't searched")

        let opened = await bridge.handleDelegation(id: "d2", request: "Open chat: 1")
        guard case .delegationReply(_, let openText, _)? = opened.first else { return XCTFail("\(opened)") }
        XCTAssertTrue(openText.contains("is open in Conduit"), openText)
        XCTAssertEqual(log.opened, ["s-gpu"])
        XCTAssertTrue(supervisor.jobs.isEmpty, "finding or opening a chat is never work for Hermes")
    }
}

@MainActor
private final class ChatFinderLog {
    var queries: [String] = []
    var opened: [String] = []
}

@MainActor
extension VoiceConversationControllerTests {
    func testChatSearchLostWithItsConnectionStillReachesTheModel() {
        let text = GeminiLiveConversationController.fallbackText(for: ["chats": "1. \"GPU setup\"", "message": "Open it."], name: "find_chat")
        XCTAssertEqual(text, "[The chat search you just made found these:\n1. \"GPU setup\"\nOpen it.]")
        XCTAssertNil(GeminiLiveConversationController.fallbackText(for: ["chats": "", "message": "No chats match that."], name: "find_chat"))
    }
}
