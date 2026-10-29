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
        var failsTitle = false
        /// The titles the profile already has.
        var takenTitles: Set<String> = []
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
                    if self.failsTitle { throw HermesError.invalidResponse }
                    if self.takenTitles.contains(title) { throw RpcError(code: 4022, message: "title already in use") }
                },
                open: { [unowned self] chatID, profile, title in
                    self.log.append("open \(chatID) \(profile)")
                    return self.opens[chatID] ?? .opened
                },
                send: { [unowned self] _, text in
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
    func testANewChatWhoseTitleDidntLandIsNotOpened() async throws {
        let steps = RoomChatSteps()
        steps.failsTitle = true
        do {
            _ = try await steps.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default", wrapUp: true)
            XCTFail("an untitled chat is a lazy row its stored id doesn't open")
        } catch {}
        // Registered, so the next try finds it gone and replaces it.
        XCTAssertEqual(steps.log.last, "title run-new \(RoomChatText.chatTitle("Zoo trip"))")
        XCTAssertFalse(steps.log.contains { $0.hasPrefix("open") || $0.hasPrefix("send") })
    }

    @MainActor
    func testANewChatTakesTheNextFreeTitle() async throws {
        let steps = RoomChatSteps()
        let title = RoomChatText.chatTitle("Zoo trip")
        steps.takenTitles = [title, "\(title) (2)"]

        let outcome = try await steps.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default",
                                                 wrapUp: false)

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(steps.log.suffix(4), [
            "title run-new \(title)",
            "title run-new \(title) (2)",
            "title run-new \(title) (3)",
            "open new-chat default",
        ])

        // Only so many tries: then it says why, and nothing opens.
        let full = RoomChatSteps()
        full.takenTitles = Set((1...RoomChatOpener.titleTries).map { $0 == 1 ? title : "\(title) (\($0))" })
        do {
            _ = try await full.opener.run(roomID: "conduit-9", roomName: "Zoo trip", profile: "default", wrapUp: false)
            XCTFail("no free title")
        } catch {}
        XCTAssertFalse(full.log.contains { $0.hasPrefix("open") })
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

    /// The plugin's answer once it keeps rooms' chats.
    var roomChatsPluginReport: [String: Any] {
        var report = postsPluginReport
        report["capabilities"] = (report["capabilities"] as? [String] ?? []) + [RoomChatsClient.capability]
        return report
    }

    @MainActor
    func testGroupInfoOffersRoomChatsOnlyWithThePlugin() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let older = try await postsOpenCopy(routes)
        XCTAssertFalse(older.canOpenRoomChats)
        XCTAssertEqual(older.activeRoomChatAgents, [], "a plugin before 0.117 keeps no room chats")

        let appState = try await postsOpenCopy(CopiesRoutes(copies: [copiesCopy()]), report: roomChatsPluginReport)
        XCTAssertTrue(appState.canOpenRoomChats)
        XCTAssertEqual(appState.activeRoomChatAgents.map(\.profile), ["research"])
    }

    /// The app's steps behind a room's chat, recorded: the opens (a kept
    /// "chat-old" is gone, 4007), the creates and the titles.
    final class RoomChatSessions {
        var opens: [(id: String, profile: String?)] = []
        var created: [String?] = []
        var titles: [(id: String, title: String, profile: String?)] = []

        @MainActor
        var operations: ChatResumeLifecycleOperations {
            var operations = ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [] },
                openSessionWithProfile: { [unowned self] _, id, _, profile in
                    self.opens.append((id, profile))
                    if id == "chat-old" { throw RpcError(code: 4007, message: "session not found") }
                    return SessionResumeResult(
                        sessionId: id, storedSessionId: id,
                        messages: [ChatMessage(id: "\(id)-m", role: .user, content: "hi", timestamp: "1")],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
            operations.createRoomChat = { [unowned self] _, profile in
                self.created.append(profile)
                return (sessionId: "run-new", storedSessionId: "chat-new", profile: profile ?? "default")
            }
            operations.titleRoomChat = { [unowned self] _, id, title, profile in
                self.titles.append((id, title, profile))
            }
            return operations
        }
    }

    /// Kuro's kept chat in the dashboard's profile is gone from Hermes
    /// (4007): a new one is made, registered, titled by the id it runs
    /// under and opened, as an ordinary chat, and the gone chat's restore
    /// error isn't left on screen.
    @MainActor
    func testAGoneRoomChatIsReplacedWithNoStaleError() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(yours: [["member_id": "m-kuro", "profile": "default", "handle": "kuro"]])])
        routes.roomChats = [["room_id": "conduit-9", "chat_id": "chat-old", "notes_seq": 3]]
        let steps = RoomChatSessions()
        let appState = try await postsOpenCopy(routes, report: roomChatsPluginReport, chatResume: steps.operations)
        let kuro = try XCTUnwrap(appState.activeRoomChatAgents.first)
        XCTAssertEqual(kuro.profile, "default")

        let failure = await appState.openRoomChat(with: kuro, wrapUp: false)

        XCTAssertNil(failure)
        XCTAssertNil(appState.errorMessage, "the gone chat's restore error went with it")
        XCTAssertEqual(steps.opens.map(\.id), ["chat-old", "chat-new"])
        XCTAssertEqual(steps.created, [nil], "the dashboard's profile is named by none")
        XCTAssertEqual(routes.roomChatPuts.last?["chat_id"] as? String, "chat-new")
        XCTAssertEqual(steps.titles.map(\.id), ["run-new"])
        XCTAssertEqual(appState.activeSessionId, "chat-new")
        XCTAssertNil(appState.botConversationProfileForTesting("chat-new"), "an ordinary chat, never a Bot Chat")
    }
}
