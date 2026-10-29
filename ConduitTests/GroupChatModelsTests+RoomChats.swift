import XCTest

@testable import Conduit

/// A room's private chat with one of your agents (designs/cross-owner-agents,
/// C5b): Group Info opens it, in the agent's own profile, and tells your
/// Hermes which room it's about (`PUT /rooms/chats`, notifier 0.117). An
/// extension, so no new class to plan.
extension GroupChatModelsTests {
    /// A member of the open room: one of yours (local) or another Hermes'.
    func roomChatMember(_ name: String, profile: String? = nil, peer: Bool = false,
                        out: RoomMemberOut? = nil) -> GroupMember {
        var member = GroupMember(
            memberID: "m-\(name)",
            profile: profile,
            handle: name.lowercased(),
            displayName: name,
            target: ["kind": .string(peer ? "peer" : "local")],
            extra: [:]
        )
        member.out = out
        return member
    }

    /// The opener's steps, recorded, with each answer set beforehand.
    final class RoomChatSteps {
        var kept: [RoomChat] = []
        var failsChats = false
        var failsRegister = false
        /// The id Hermes keeps a new chat by (none from a Hermes that didn't say).
        var storedID: String? = "new-chat"
        /// What each open answers, by chat id (opened when unset).
        var opens: [String: RoomChatOpenOutcome] = [:]
        private(set) var log: [String] = []

        var opener: RoomChatOpener {
            RoomChatOpener(
                chats: { [unowned self] profile in
                    self.log.append("chats \(profile)")
                    if self.failsChats { throw HermesError.invalidResponse }
                    return self.kept
                },
                create: { [unowned self] profile in
                    self.log.append("create \(profile)")
                    return ("run-new", self.storedID)
                },
                register: { [unowned self] roomID, chatID, profile in
                    self.log.append("register \(roomID) \(chatID) \(profile)")
                    if self.failsRegister { throw HermesError.invalidResponse }
                    return RoomChat(roomID: roomID, chatID: chatID, notesSeq: 7)
                },
                title: { [unowned self] runtimeID, profile, title in
                    self.log.append("title \(runtimeID) \(title)")
                },
                open: { [unowned self] chatID, profile, title in
                    self.log.append("open \(chatID) \(profile)")
                    return self.opens[chatID] ?? .opened
                },
                send: { [unowned self] text in
                    self.log.append("send \(text)")
                    return true
                }
            )
        }
    }

    @MainActor
    func testTheRoomChatsRoutesArePerProfile() async throws {
        var asked: [(path: String, method: String, body: [String: Any]?)] = []
        let client = RoomChatsClient { path, method, body, _ in
            asked.append((path, method, body))
            if method == "PUT" {
                return ["ok": true, "chat": ["room_id": "conduit-9", "chat_id": "chat-a", "notes_seq": 12]]
            }
            return ["ok": true, "chats": [
                ["room_id": "conduit-9", "chat_id": "chat-a", "notes_seq": 12],
                ["room_id": "", "chat_id": "chat-b"],
            ]]
        }

        let chats = try await client.chats(profile: "research")
        XCTAssertEqual(chats, [RoomChat(roomID: "conduit-9", chatID: "chat-a", notesSeq: 12)],
                       "one without a room id is left out")
        XCTAssertEqual(asked.last?.path, "\(RoomChatsClient.path)?profile=research")
        XCTAssertEqual(asked.last?.method, "GET")

        let opened = try await client.open(roomID: "conduit-9", chatID: "chat-a", profile: "default")
        XCTAssertEqual(opened.notesSeq, 12)
        XCTAssertEqual(asked.last?.path, RoomChatsClient.path, "the default profile names none")
        XCTAssertEqual(asked.last?.method, "PUT")
        XCTAssertEqual(asked.last?.body?["room_id"] as? String, "conduit-9")
        XCTAssertEqual(asked.last?.body?["chat_id"] as? String, "chat-a")

        let refusing = RoomChatsClient { _, _, _, _ in ["ok": false] }
        do {
            _ = try await refusing.chats(profile: "default")
            XCTFail("an answer that isn't ok throws")
        } catch {}
    }

    @MainActor
    func testOnlyYourAgentsInARoomWithOtherPeoplesGetARoomChat() {
        let furina = roomChatMember("Furina", profile: "default")
        let kuro = roomChatMember("Kuro", profile: "research")
        let mona = roomChatMember("Mona", peer: true)
        XCTAssertEqual(RoomChatAgent.agents(in: [furina, kuro, mona]), [
            RoomChatAgent(profile: "default", name: "Furina"),
            RoomChatAgent(profile: "research", name: "Kuro"),
        ])
        // A room of your own agents only has nothing of other people's to ask about.
        XCTAssertEqual(RoomChatAgent.agents(in: [furina, kuro]), [])
        // An agent out of the room, or without a profile, gets none.
        let left = roomChatMember("Kuro", profile: "research", out: .left)
        let unnamed = roomChatMember("Nobody")
        XCTAssertEqual(RoomChatAgent.agents(in: [left, unnamed, mona]), [])
    }

    @MainActor
    func testARoomChatOpensTheOneYourHermesKeeps() async throws {
        let steps = RoomChatSteps()
        steps.kept = [RoomChat(roomID: "conduit-other", chatID: "chat-x", notesSeq: 0),
                      RoomChat(roomID: "conduit-9", chatID: "chat-a", notesSeq: 3)]

        let outcome = try await steps.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "research",
                                                 wrapUp: false)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(steps.log, ["chats research", "open chat-a research"])
    }

    @MainActor
    func testANewRoomChatIsToldItsRoomBeforeItOpens() async throws {
        let steps = RoomChatSteps()

        let outcome = try await steps.opener.run(roomID: "conduit-9", roomName: " Zoo trip ", profile: "research",
                                                 wrapUp: false)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(steps.log, [
            "chats research",
            "create research",
            "register conduit-9 new-chat research",
            "title run-new \(RoomChatText.chatTitle("Zoo trip"))",
            "open new-chat research",
        ])
        XCTAssertEqual(RoomChatText.chatTitle(" Zoo trip "), AppLocalization.string("About \("Zoo trip")"))
    }

    @MainActor
    func testAKeptChatHermesNoLongerHasIsReplaced() async throws {
        let steps = RoomChatSteps()
        steps.kept = [RoomChat(roomID: "conduit-9", chatID: "chat-a", notesSeq: 3)]
        steps.opens["chat-a"] = .gone

        let outcome = try await steps.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default",
                                                 wrapUp: false)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(steps.log.suffix(4), [
            "create default",
            "register conduit-9 new-chat default",
            "title run-new \(RoomChatText.chatTitle("Zoo trip"))",
            "open new-chat default",
        ])
    }

    @MainActor
    func testAKeptChatThatDidntOpenStaysTheRooms() async throws {
        let steps = RoomChatSteps()
        steps.kept = [RoomChat(roomID: "conduit-9", chatID: "chat-a", notesSeq: 3)]
        steps.opens["chat-a"] = .failed

        let outcome = try await steps.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default",
                                                 wrapUp: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(steps.log, ["chats default", "open chat-a default"], "no new chat, and nothing sent")
    }

    @MainActor
    func testUnreadableRoomChatsMakeNoNewChat() async throws {
        let steps = RoomChatSteps()
        steps.failsChats = true
        do {
            _ = try await steps.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default", wrapUp: false)
            XCTFail("the chats can't be read")
        } catch {}
        XCTAssertEqual(steps.log, ["chats default"])

        // A chat your Hermes wasn't told about isn't opened: its turns wouldn't know their room.
        let unregistered = RoomChatSteps()
        unregistered.failsRegister = true
        do {
            _ = try await unregistered.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default",
                                                  wrapUp: false)
            XCTFail("the chat wasn't registered")
        } catch {}
        XCTAssertFalse(unregistered.log.contains { $0.hasPrefix("open") })
        // Nor titled: untitled and unwritten, it's a lazy row Hermes prunes, not a stray chat.
        XCTAssertFalse(unregistered.log.contains { $0.hasPrefix("title") })
    }

    @MainActor
    func testANewChatHermesGaveNoStoredIDIsNeverTheRooms() async throws {
        let steps = RoomChatSteps()
        steps.storedID = nil
        do {
            _ = try await steps.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default", wrapUp: true)
            XCTFail("a chat known only by the id it runs under can't be the room's")
        } catch {}
        // Its runtime id names nothing once it closes: never registered, titled, opened or sent to.
        XCTAssertEqual(steps.log, ["chats default", "create default"])
    }

    @MainActor
    func testWrapUpAsksForNotesOnceTheChatOpens() async throws {
        let steps = RoomChatSteps()
        steps.kept = [RoomChat(roomID: "conduit-9", chatID: "chat-a", notesSeq: 3)]

        _ = try await steps.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default", wrapUp: true)

        XCTAssertEqual(steps.log.last, "send \(RoomChatText.wrapUpPrompt)")

        // A chat another navigation took over gets nothing sent.
        let superseded = RoomChatSteps()
        superseded.kept = steps.kept
        superseded.opens["chat-a"] = .superseded
        let outcome = try await superseded.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default",
                                                      wrapUp: true)
        XCTAssertEqual(outcome, .superseded)
        XCTAssertFalse(superseded.log.contains { $0.hasPrefix("send") })
    }

    @MainActor
    func testGroupInfoOffersRoomChatsOnlyWithThePlugin() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let older = try await postsOpenCopy(routes)
        XCTAssertFalse(older.canOpenRoomChats)
        XCTAssertEqual(older.activeRoomChatAgents, [], "a plugin before 0.117 keeps no room chats")

        var report = postsPluginReport
        report["capabilities"] = (report["capabilities"] as? [String] ?? []) + [RoomChatsClient.capability]
        let appState = try await postsOpenCopy(CopiesRoutes(copies: [copiesCopy()]), report: report)
        XCTAssertTrue(appState.canOpenRoomChats)
        XCTAssertEqual(appState.activeRoomChatAgents.map(\.profile), ["research"])
    }
}
