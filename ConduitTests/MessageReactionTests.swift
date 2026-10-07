import Foundation
import XCTest
@testable import Conduit

/// Tapback reactions: history parsing, the agent's live `message.reaction`
/// event, and the optimistic `message.react` flow. An extension of an
/// existing class so CI's shard timings need no new entry.
extension MessageNormalizerTests {

    private func rows(_ json: String) -> [AnyCodable] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            XCTFail("Invalid JSON: \(json)")
            return []
        }
        return array.map { AnyCodable.from($0) }
    }

    private func makeReactionAppState() -> AppState {
        let suite = "MessageReactionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.activeSessionId = "sess-react"
        return appState
    }

    // MARK: - History

    func testReactionHistoryResumeRowCarriesRowIdAndReactions() {
        let messages = MessageNormalizer.normalizeMessages(rows(#"""
        [
          {"role": "user", "text": "Ship it?", "row_id": 41,
           "display_metadata": {"reactions": [{"emoji": "👍", "author": "agent", "at": 1700000000.5}]}},
          {"role": "assistant", "text": "Shipped.", "row_id": 42,
           "display_metadata": {"reactions": [{"emoji": "❤️", "author": "user"}]}}
        ]
        """#))

        XCTAssertEqual(messages.map(\.rowId), [41, 42])
        XCTAssertEqual(messages[0].reactions, [MessageReaction(emoji: "👍", author: "agent", at: 1700000000.5)])
        XCTAssertEqual(messages[1].reactions, [MessageReaction(emoji: "❤️", author: "user", at: nil)])
    }

    func testReactionHistoryRestRowUsesNumericIdAndStringMetadata() {
        let messages = MessageNormalizer.normalizeMessages(rows(#"""
        [
          {"id": 7, "role": "assistant", "content": "Hi",
           "display_metadata": "{\"reactions\": [{\"emoji\": \"😂\", \"author\": \"user\"}, {\"author\": \"agent\"}]}"}
        ]
        """#))

        XCTAssertEqual(messages.first?.rowId, 7)
        XCTAssertEqual(messages.first?.reactions.map(\.emoji), ["😂"], "An entry without an emoji is skipped")
    }

    func testReactionHistoryRowWithoutDurableIdHasNone() {
        let messages = MessageNormalizer.normalizeMessages(rows(#"""
        [
          {"id": "msg-abc", "role": "assistant", "content": "Hi"},
          {"role": "assistant", "content": "Again", "display_metadata": {"reactions": "nope"}}
        ]
        """#))

        XCTAssertEqual(messages.map(\.rowId), [nil, nil])
        XCTAssertEqual(messages.map(\.reactions), [[], []])
    }

    // MARK: - Tapback rules

    func testReactionTapbackRulesMatchHermes() {
        let agent = MessageReaction(emoji: "👍", author: "agent", at: 1)
        let picked = MessageReaction.applying("❤️", author: "user", to: [agent], at: 2)
        XCTAssertEqual(picked, [agent, MessageReaction(emoji: "❤️", author: "user", at: 2)])

        let replaced = MessageReaction.applying("😂", author: "user", to: picked, at: 3)
        XCTAssertEqual(replaced, [agent, MessageReaction(emoji: "😂", author: "user", at: 3)])

        XCTAssertEqual(MessageReaction.applying("😂", author: "user", to: replaced), [agent], "Same emoji retracts")
        XCTAssertEqual(MessageReaction.applying(nil, author: "user", to: replaced), [agent], "Nil clears")
    }

    func testReactionChipsGroupSharedEmoji() {
        let groups = MessageReactionChips.groups(for: [
            MessageReaction(emoji: "👍", author: "agent", at: nil),
            MessageReaction(emoji: "❤️", author: "user", at: nil),
            MessageReaction(emoji: "👍", author: "user", at: nil)
        ])
        XCTAssertEqual(groups, [
            .init(emoji: "👍", count: 2, includesUser: true, includesOthers: true),
            .init(emoji: "❤️", count: 1, includesUser: true, includesOthers: false)
        ])
    }

    // MARK: - Live event

    func testReactionEventParses() {
        let event = StreamEventParser.parse(params: AnyCodable.from([
            "type": "message.reaction",
            "session_id": "sess-react",
            "payload": [
                "row_id": 12,
                "role": "user",
                "reactions": [["emoji": "👍", "author": "agent"]]
            ] as [String: Any]
        ] as [String: Any]))
        guard case .messageReaction(let sessionId, let rowId, let reactions, let role) = event else {
            return XCTFail("Expected messageReaction, got \(String(describing: event))")
        }
        XCTAssertEqual(sessionId, "sess-react")
        XCTAssertEqual(rowId, 12)
        XCTAssertEqual(role, "user")
        XCTAssertEqual(reactions.map(\.emoji), ["👍"])

        let missingRow = StreamEventParser.parse(params: AnyCodable.from([
            "type": "message.reaction",
            "session_id": "sess-react",
            "payload": ["reactions": []] as [String: Any]
        ] as [String: Any]))
        XCTAssertNil(missingRow, "A reaction with no row can't be placed")
    }

    func testReactionEventPaintsByRowIdThenNewestLiveRow() {
        let appState = makeReactionAppState()
        appState.messages = [
            ChatMessage(id: "u1", role: .user, content: "First", timestamp: "1", rowId: 5),
            ChatMessage(id: "a1", role: .assistant, content: "Reply", timestamp: "2", rowId: 6),
            ChatMessage(id: "local-u2", role: .user, content: "Second", timestamp: "3")
        ]
        let thumbs = [MessageReaction(emoji: "👍", author: "agent", at: nil)]

        appState.handleStreamEvent(.messageReaction(sessionId: "sess-react", rowId: 5, reactions: thumbs, role: "user"))
        XCTAssertEqual(appState.messages[0].reactions, thumbs)
        XCTAssertEqual(appState.messages[2].reactions, [])

        appState.handleStreamEvent(.messageReaction(sessionId: "sess-react", rowId: 9, reactions: thumbs, role: "user"))
        XCTAssertEqual(appState.messages[2].rowId, 9, "The live row learns its durable id")
        XCTAssertEqual(appState.messages[2].reactions, thumbs)

        appState.handleStreamEvent(.messageReaction(sessionId: "other-session", rowId: 6, reactions: thumbs, role: "assistant"))
        XCTAssertEqual(appState.messages[1].reactions, [], "Another conversation's event is ignored")

        appState.messages.append(ChatMessage(id: "local-u3", role: .user, content: "Third", timestamp: "4"))
        appState.handleStreamEvent(.messageReaction(sessionId: "sess-react", rowId: 11, reactions: thumbs, role: ""))
        XCTAssertNil(appState.messages[3].rowId, "An unknown role never guesses a live row")
        XCTAssertEqual(appState.messages[3].reactions, [])
    }

    func testFailedReactionKeepsAnAgentReactionThatArrivedMeanwhile() async {
        let appState = makeReactionAppState()
        appState.messages = [
            ChatMessage(id: "a1", role: .assistant, content: "Hello", timestamp: "2", rowId: 2)
        ]
        let agent = MessageReaction(emoji: "👍", author: "agent", at: 1)
        appState.messageReactionSender = { _, _, _ in
            appState.handleStreamEvent(.messageReaction(
                sessionId: "sess-react",
                rowId: 2,
                reactions: [agent, MessageReaction(emoji: "❤️", author: "user", at: 2)],
                role: "assistant"
            ))
            throw HermesError.notConnected
        }

        await appState.react(to: "a1", with: "❤️")

        XCTAssertEqual(appState.messages[0].reactions, [agent])
    }

    // MARK: - Reacting

    func testReactingPaintsThenAdoptsTheServerList() async {
        let appState = makeReactionAppState()
        appState.messages = [
            ChatMessage(id: "u1", role: .user, content: "Hi", timestamp: "1", rowId: 1),
            ChatMessage(id: "a1", role: .assistant, content: "Hello", timestamp: "2", rowId: 2)
        ]
        var calls: [(String, MessageReactionTarget, String?)] = []
        appState.messageReactionSender = { sessionId, target, emoji in
            calls.append((sessionId, target, emoji))
            XCTAssertEqual(appState.messages[1].reactions.map(\.emoji), ["❤️"], "Painted before the reply")
            return MessageReactionResult(rowId: 2, reactions: [MessageReaction(emoji: "❤️", author: "user", at: 10)])
        }

        await appState.react(to: "a1", with: "❤️")

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "sess-react")
        XCTAssertEqual(calls.first?.1, .row(2))
        XCTAssertEqual(calls.first?.2, "❤️")
        XCTAssertEqual(appState.messages[1].reactions, [MessageReaction(emoji: "❤️", author: "user", at: 10)])
    }

    func testReactingToTheLatestLiveReplyNamesTheNewestAssistantRow() async {
        let appState = makeReactionAppState()
        appState.messages = [
            ChatMessage(id: "a0", role: .assistant, content: "Earlier", timestamp: "1"),
            ChatMessage(id: "local-a1", role: .assistant, content: "Just now", timestamp: "2")
        ]
        XCTAssertNil(appState.reactionTarget(for: appState.messages[0]), "An older live reply can't be addressed")
        XCTAssertEqual(appState.reactionTarget(for: appState.messages[1]), .newest(role: "assistant"))
        appState.messageReactionSender = { _, _, _ in
            MessageReactionResult(rowId: 88, reactions: [MessageReaction(emoji: "👍", author: "user", at: nil)])
        }

        await appState.react(to: "local-a1", with: "👍")

        XCTAssertEqual(appState.messages[1].rowId, 88, "Later tapbacks address the row directly")
        XCTAssertEqual(appState.reactionTarget(for: appState.messages[1]), .row(88))
    }

    func testFailedReactionRollsBackAndSaysSo() async {
        let appState = makeReactionAppState()
        let agent = MessageReaction(emoji: "👍", author: "agent", at: 1)
        appState.messages = [
            ChatMessage(id: "a1", role: .assistant, content: "Hello", timestamp: "2", rowId: 2, reactions: [agent])
        ]
        appState.messageReactionSender = { _, _, _ in throw HermesError.notConnected }

        await appState.react(to: "a1", with: "😂")

        XCTAssertEqual(appState.messages[0].reactions, [agent])
        XCTAssertNotNil(appState.errorMessage)
    }

    func testAgentReactionDuringASaveKeepsTheUsersPick() async {
        let appState = makeReactionAppState()
        appState.messages = [
            ChatMessage(id: "a1", role: .assistant, content: "Hello", timestamp: "2", rowId: 2)
        ]
        let agent = MessageReaction(emoji: "👍", author: "agent", at: 1)
        let mine = MessageReaction(emoji: "❤️", author: "user", at: 3)
        appState.messageReactionSender = { [weak appState] _, _, _ in
            appState?.handleStreamEvent(.messageReaction(
                sessionId: "sess-react", rowId: 2, reactions: [agent], role: "assistant"
            ))
            XCTAssertEqual(appState?.messages[0].reactions.map(\.emoji), ["👍", "❤️"], "The pick survives a stale event")
            return MessageReactionResult(rowId: 2, reactions: [agent, mine])
        }

        await appState.react(to: "a1", with: "❤️")

        XCTAssertEqual(appState.messages[0].reactions, [agent, mine])
    }

    func testUserReactionReplacementKeepsItsPlace() {
        let agent = MessageReaction(emoji: "👍", author: "agent", at: 1)
        let old = MessageReaction(emoji: "😂", author: "user", at: 0)
        let new = MessageReaction(emoji: "❤️", author: "user", at: 2)
        XCTAssertEqual(AppState.reactions([old, agent], withUserReaction: new), [new, agent])
        XCTAssertEqual(AppState.reactions([old, agent], withUserReaction: nil), [agent])
        XCTAssertEqual(AppState.reactions([agent], withUserReaction: new), [agent, new])
    }
}
