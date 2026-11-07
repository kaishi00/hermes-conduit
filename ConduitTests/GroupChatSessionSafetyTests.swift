import CryptoKit
import XCTest

@testable import Conduit

/// Group Chat room-surface behavior at the AppState boundary: a room is NOT
/// a session (opening one never touches session state), and an ambiguous
/// send keeps its retry key so the gateway's idempotent send can never
/// produce a twin message.
@MainActor
final class GroupChatSessionSafetyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() async throws {
        defaultsSuite = "GroupChatSessionSafetyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    private struct TestError: Error {}

    private func makeAppState(operations: GroupChatLifecycleOperations) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: .live,
            groupChatOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    private func connect(_ appState: AppState) {
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://groups.example", ticket: "groups-test"),
            profile: "default"
        )
        appState.isConnected = true
        _ = appState.adoptDashboard(forNormalizedURL: "https://groups.example")
    }

    private func capabilities(supported: Bool) -> GroupCapabilities {
        let methods: Set<String> = supported
            ? ["groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.disband", "groups.stop"]
            : ["groups.capabilities"]
        return GroupCapabilities(
            protocolVersion: 2,
            driverReady: true,
            authorityGatewayID: "gw-a",
            features: [],
            methods: methods,
            maxLogLimit: 500
        )
    }

    private func room(name: String = "Planning", disbanded: Bool = false) -> GroupRoom {
        GroupRoom(
            roomID: "room-1",
            name: name,
            members: [
                GroupMember(
                    memberID: "researcher",
                    profile: "researcher",
                    handle: "research-buddy",
                    displayName: "Research Buddy",
                    target: nil,
                    extra: [:]
                )
            ],
            authorityGatewayID: "gw-a",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            disbandedAt: disbanded ? 1 : nil,
            latestSeq: 0
        )
    }

    private func sendResult(roomID: String, seq: Int) -> GroupSendResult {
        let event = GroupDecoders.event(AnyCodable.from([
            "room_id": roomID,
            "seq": seq,
            "event_id": "srv-\(seq)",
            "kind": "message.user",
            "actor": ["kind": "user", "id": "human"],
            "payload": ["text": "hello", "thread_id": "main"],
            "created_at": 1.0,
        ]))!
        return GroupSendResult(event: event, accepted: true, driverStarted: true)
    }

    // MARK: - Session isolation

    func testOpeningRoomNeverTouchesSessionState() async {
        final class LogBox {
            var calls: [Int] = []
        }
        let logBox = LogBox()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, roomID, sinceSeq, _ in
                logBox.calls.append(sinceSeq)
                return GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)

        XCTAssertEqual(appState.activeSessionId, nil)
        XCTAssertTrue(appState.messages.isEmpty)

        await appState.refreshGroupChatSupport()
        XCTAssertEqual(appState.groupChatPhase, .available)
        await appState.openGroupRoom(room)

        // The room surface is up…
        XCTAssertEqual(appState.activeRoomSurface?.room.roomID, "room-1")
        XCTAssertEqual(appState.groupRooms.first?.roomID, "room-1")
        // …and NOT ONE piece of session state moved.
        XCTAssertEqual(appState.activeSessionId, nil)
        XCTAssertTrue(appState.messages.isEmpty)
        XCTAssertEqual(appState.turnState.isRunning, false)

        appState.closeGroupRoom()
        XCTAssertEqual(appState.activeRoomSurface, nil)
        XCTAssertEqual(appState.activeSessionId, nil)
        XCTAssertTrue(appState.messages.isEmpty)
    }

    func testUnsupportedGatewayHidesGroupChatAndRefusesRoomOpen() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: false) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)

        await appState.refreshGroupChatSupport()
        XCTAssertEqual(appState.groupChatPhase, .gatewayUnsupported)
        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomSurface, nil)
        XCTAssertEqual(appState.activeSessionId, nil)
    }

    func testFailedRoomLoadStillLeavesSessionStateUntouched() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            state: { _, _ in throw TestError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)

        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeSessionId, nil)
        XCTAssertTrue(appState.messages.isEmpty)
        appState.closeGroupRoom()
    }

    // MARK: - Send retry key

    func testAmbiguousSendFailureReusesTheSameEventIDOnRetry() async {
        final class SendRecorder {
            var ids: [String] = []
            var failFirst = true
        }
        let recorder = SendRecorder()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, roomID in (room, nil) },
            log: { _, roomID, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, eventID, text, threadID in
                recorder.ids.append(eventID)
                XCTAssertEqual(roomID, "room-1")
                XCTAssertEqual(text, "hello room")
                // Each message opens its own thread, as Desktop's do, so
                // the host can route it; a retry keeps it.
                XCTAssertEqual(threadID, eventID)
                if recorder.failFirst {
                    recorder.failFirst = false
                    throw TestError()
                }
                return self.sendResult(roomID: roomID, seq: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        // First attempt fails ambiguously: the pending row (and its retry
        // key) must survive.
        await appState.sendGroupRoomMessage("hello room")
        XCTAssertEqual(recorder.ids.count, 1)
        let firstID = recorder.ids[0]
        XCTAssertNotNil(appState.pendingRoomMessage)
        XCTAssertEqual(appState.pendingRoomMessage?.eventID, firstID)

        // The retry reuses the SAME id — the gateway deduplicates; a twin
        // message is impossible.
        await appState.sendGroupRoomMessage("hello room")
        XCTAssertEqual(recorder.ids, [firstID, firstID])
        // Accepted: the optimistic row reconciles and clears.
        XCTAssertEqual(appState.pendingRoomMessage, nil)
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1])
        XCTAssertEqual(appState.activeRoomReplay.cursor, 1)

        appState.closeGroupRoom()
    }

    /// A reply goes in the thread of the message it answers, as Desktop's
    /// do, and its retry keeps that thread.
    func testAReplyIsSentInTheThreadItAnswers() async {
        final class SendRecorder {
            var threads: [String] = []
            var failFirst = true
        }
        let recorder = SendRecorder()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, roomID in (room, nil) },
            log: { _, roomID, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, _, _, threadID in
                recorder.threads.append(threadID)
                if recorder.failFirst {
                    recorder.failFirst = false
                    throw TestError()
                }
                return self.sendResult(roomID: roomID, seq: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        await appState.sendGroupRoomMessage("> quoted\n\nagreed", threadID: "conduit-first")
        // The retry, from the room's row, names no thread: the pending one keeps it.
        await appState.sendGroupRoomMessage("> quoted\n\nagreed")
        XCTAssertEqual(recorder.threads, ["conduit-first", "conduit-first"])
        appState.closeGroupRoom()
    }

    /// An ambiguous send that DID land settles when the next poll brings its
    /// server-side twin: no stale "Not delivered" row beside the real one.
    func testAmbiguousSendThatLandedSettlesFromThePoll() async {
        final class RoomBox {
            var landed: GroupEvent?
            var limits: [Int?] = []
        }
        let box = RoomBox()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (self.roomWithLatest(box.landed == nil ? 0 : 1), nil) },
            log: { _, _, sinceSeq, limit in
                box.limits.append(limit)
                let events = [box.landed].compactMap { $0 }.filter { $0.seq > sinceSeq }
                return GroupLogPage(events: events, cursor: events.last?.seq ?? sinceSeq,
                                    latestSeq: box.landed?.seq ?? 0, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, eventID, text, _ in
                // The gateway stored it; only the response was lost.
                box.landed = GroupEvent(
                    roomID: roomID,
                    seq: 1,
                    // Computed here, not via the code under test: upstream
                    // `user_event_id` is "user:" + sha256 hex of the id.
                    eventID: "user:" + SHA256.hash(data: Data(eventID.utf8))
                        .map { String(format: "%02x", $0) }.joined(),
                    kind: "message.user",
                    actor: GroupActor(kind: "user", id: "human", profile: nil,
                                      displayName: nil, connectionID: nil),
                    authorityEpoch: nil,
                    payload: ["text": .string(text), "thread_id": .string("main")],
                    createdAt: 0
                )
                throw TestError()
            },
            stop: { _, _ in 0 }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        // The opening tail is bounded by the upstream 200-event window.
        XCTAssertEqual(box.limits, [200])

        await appState.sendGroupRoomMessage("hello room")
        XCTAssertNotNil(appState.pendingRoomMessage)
        XCTAssertNotNil(appState.errorMessage)

        await appState.stopActiveRoomWork()  // runs one poll tick
        XCTAssertNil(appState.pendingRoomMessage, "the polled twin settles the pending send")
        XCTAssertNil(appState.errorMessage)
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1])

        appState.closeGroupRoom()
    }

    /// Leaving a room with an unsettled send parks its retry key; reopening
    /// restores the SAME pending row, so the text survives and a retry still
    /// deduplicates. The room's composer draft survives the same way.
    func testLeavingParksThePendingSendAndDraftForTheReopen() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, _, _, _, _ in throw TestError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        await appState.sendGroupRoomMessage("still pending")
        let pending = appState.pendingRoomMessage
        XCTAssertNotNil(pending)
        appState.saveActiveRoomDraft("half a thought")

        appState.closeGroupRoom()
        XCTAssertNil(appState.pendingRoomMessage)

        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.pendingRoomMessage, pending)
        XCTAssertEqual(appState.activeRoomDraft(), "half a thought")

        appState.closeGroupRoom()
    }

    /// A room opened again shows the events it had at once, while its tail
    /// loads, and the tail replaces them (#1352).
    func testReopenedRoomShowsItsEventsWhileItsTailLoads() async throws {
        final class LogBox {
            var events = 1
            var gate: ControlledSuspension?
        }
        let box = LogBox()
        let room = self.room()
        func message(_ seq: Int) -> GroupEvent {
            GroupDecoders.event(AnyCodable.from([
                "room_id": room.roomID,
                "seq": seq,
                "event_id": "srv-\(seq)",
                "kind": "message.user",
                "actor": ["kind": "user", "id": "human"],
                "payload": ["text": "hello \(seq)", "thread_id": "main"],
                "created_at": Double(seq),
            ]))!
        }
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                if let gate = box.gate { await gate.suspend() }
                let events = (1...box.events).map(message).filter { $0.seq > sinceSeq }
                return GroupLogPage(events: events, cursor: box.events, latestSeq: box.events, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1])
        appState.closeGroupRoom()

        box.events = 2
        let gate = ControlledSuspension()
        box.gate = gate
        let reopening = Task { @MainActor in await appState.openGroupRoom(room) }
        await gate.waitUntilSuspended()
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1], "What it had shows while the tail loads")

        box.gate = nil
        gate.resume()
        await reopening.value
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1, 2])
        appState.closeGroupRoom()
    }

    /// A room's boards are read when it opens and when one of its agents
    /// posts, not when the user does, go under the agent's message, and are
    /// gone once the room closes; a plugin without the route isn't asked.
    func testRoomBoardsAreReadWhenTheRoomOpensAndWhenAnAgentPosts() async throws {
        final class Box {
            var events: [GroupEvent] = []
            var reads: [String] = []
        }
        let box = Box()
        let room = self.room()
        func message(_ seq: Int, fromMember: Bool) -> GroupEvent {
            let actor: [String: String] = fromMember ? ["kind": "member", "id": "researcher", "profile": "researcher"]
                : ["kind": "user", "id": "human"]
            return GroupDecoders.event(AnyCodable.from([
                "room_id": room.roomID,
                "seq": seq,
                "event_id": "srv-\(seq)",
                "kind": fromMember ? "message.member" : "message.user",
                "actor": actor,
                "payload": ["text": "hello \(seq)", "thread_id": "main"],
                "created_at": Double(seq) * 100,
            ]))!
        }
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                let latest = box.events.last?.seq ?? 0
                return GroupLogPage(events: box.events.filter { $0.seq > sinceSeq }, cursor: latest,
                                    latestSeq: latest, hasMore: false, authorityGatewayID: "gw-a", authorityEpoch: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        appState.roomBoardsReadOverride = { path in
            box.reads.append(path)
            return ["boards": [["profile": "researcher", "at": 190.0, "board": [
                "cards": [["type": "callout", "callout": ["text": "Book early", "tone": "tip"]]],
                "markdown": "Book early",
            ]]]]
        }
        await appState.refreshGroupChatSupport()

        box.events = [message(1, fromMember: false), message(2, fromMember: true)]
        await appState.openGroupRoom(room)
        await appState.roomBoardsTask?.value
        XCTAssertTrue(box.reads.isEmpty, "A plugin without the route isn't asked")

        appState.setNotifierPluginStateForTesting(.reported(version: "0.129.0", capabilities: [RoomBoard.capability]))
        await appState.roomBoardsTask?.value
        XCTAssertEqual(box.reads.count, 1, "Read once the plugin says it keeps them, the room still open")
        XCTAssertTrue(box.reads.first?.contains("room_id=room-1") == true)
        XCTAssertEqual(appState.activeRoomPlacedBoards["srv-2"]?.count, 1, "Under the agent's message")
        appState.closeGroupRoom()
        XCTAssertTrue(appState.activeRoomBoards.isEmpty, "Gone once the room closes")

        // Reopened: the kept events show (read once), then the tail lands.
        await appState.openGroupRoom(room)
        await appState.roomBoardsTask?.value
        XCTAssertEqual(box.reads.count, 2, "Read when the room opens")
        XCTAssertEqual(appState.activeRoomPlacedBoards["srv-2"]?.count, 1)
        appState.closeGroupRoom()

        box.events.append(message(3, fromMember: false))
        await appState.openGroupRoom(room)
        await appState.roomBoardsTask?.value
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(box.reads.count, 3, "The user's message doesn't read them again")
        appState.closeGroupRoom()

        box.events.append(message(4, fromMember: true))
        await appState.openGroupRoom(room)
        await appState.roomBoardsTask?.value
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1, 2, 3, 4])
        XCTAssertGreaterThan(box.reads.count, 3, "Read again when the agent's message lands")
        appState.closeGroupRoom()
    }

    /// A dictation Retry that lands after its room was left: the words go
    /// after the room's kept draft and are there on reopen.
    func testRetriedDictationWordsReachALeftRoomsDraft() async throws {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        appState.saveActiveRoomDraft("half a thought")
        let dashboardID = try XCTUnwrap(appState.activeRoomSurface?.dashboardID)
        appState.closeGroupRoom()

        XCTAssertTrue(appState.appendToRoomDraft("and the rest", dashboardID: dashboardID, roomID: room.roomID))
        XCTAssertFalse(
            appState.appendToRoomDraft("lost", dashboardID: dashboardID, roomID: "room-gone"),
            "A room off the list can't be reopened: the recording stays"
        )

        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomDraft(), "half a thought and the rest")
        appState.closeGroupRoom()
    }

    /// A send still in flight when the user leaves: the response settles the
    /// retry key wherever it now lives — the reopened room's active outbox
    /// (leave then reopen before the answer) or the parked copy.
    func testSendAcceptedAfterLeavingSettlesTheReopenedAndTheParkedCopy() async {
        final class SendGate: @unchecked Sendable {
            var started = 0
            var released = 0
        }
        let gate = SendGate()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, _, _, _ in
                gate.started += 1
                let mine = gate.started
                while gate.released < mine {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return self.sendResult(roomID: roomID, seq: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        func waitForSend(_ count: Int) async {
            for _ in 0..<500 where gate.started < count {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(gate.started, count)
        }

        // Leave, reopen, THEN the response lands: the active copy settles.
        let first = Task { @MainActor in await appState.sendGroupRoomMessage("hello room") }
        await waitForSend(1)
        appState.closeGroupRoom()
        await appState.openGroupRoom(room)
        XCTAssertNotNil(appState.pendingRoomMessage, "the parked send came back with the room")
        XCTAssertTrue(appState.activeRoomSendInFlight, "still sending, so no retry is offered yet")
        gate.released = 1
        _ = await first.value
        XCTAssertNil(appState.pendingRoomMessage, "the delivered send never offers a retry")
        XCTAssertFalse(appState.activeRoomSendInFlight)

        // Leave, the response lands, THEN reopen: the parked copy settled.
        let second = Task { @MainActor in await appState.sendGroupRoomMessage("second note") }
        await waitForSend(2)
        appState.closeGroupRoom()
        gate.released = 2
        _ = await second.value
        await appState.openGroupRoom(room)
        XCTAssertNil(appState.pendingRoomMessage)
        XCTAssertFalse(appState.activeRoomSendInFlight)

        appState.closeGroupRoom()
    }

    /// A room that leaves the room list (disbanded elsewhere) drops its
    /// parked send and draft.
    func testRoomLeavingTheListDropsItsParkedSendAndDraft() async {
        final class ListBox {
            var rooms: [GroupRoom] = []
        }
        let box = ListBox()
        let room = self.room()
        box.rooms = [room]
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in (box.rooms, nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, _, _, _, _ in throw TestError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        await appState.sendGroupRoomMessage("still pending")
        appState.saveActiveRoomDraft("half a thought")
        appState.closeGroupRoom()

        box.rooms = []
        await appState.refreshGroupRooms()

        await appState.openGroupRoom(room)
        XCTAssertNil(appState.pendingRoomMessage)
        XCTAssertEqual(appState.activeRoomDraft(), "")
        appState.closeGroupRoom()
    }

    /// A room's staged files are kept with its text: leaving and reopening
    /// brings them back, and a room that leaves the list deletes their
    /// local copies.
    func testRoomDraftKeepsItsStagedFilesUntilTheRoomIsGone() async throws {
        final class ListBox {
            var rooms: [GroupRoom] = []
        }
        let box = ListBox()
        let room = self.room()
        box.rooms = [room]
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in (box.rooms, nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        let url = try AttachmentStaging.destination(for: "notes.pdf")
        try Data("%PDF-1.7".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let file = Attachment(id: UUID().uuidString, name: "notes.pdf", uri: url.absoluteString,
                              mimeType: "application/pdf", kind: .document)
        appState.saveActiveRoomDraft("see attached")
        appState.saveActiveRoomAttachments([file])
        appState.closeGroupRoom()

        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomDraft(), "see attached")
        XCTAssertEqual(appState.activeRoomAttachments(), [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        appState.closeGroupRoom()

        box.rooms = []
        await appState.refreshGroupRooms()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the gone room's file is deleted")

        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomAttachments(), [])
        appState.closeGroupRoom()
    }

    /// A partial room-list page (next_offset set) does not prove a room is
    /// gone, so the room keeps its parked send.
    func testPartialRoomListKeepsAMissingRoomsParkedSend() async {
        final class ListBox {
            var page: ([GroupRoom], Int?) = ([], nil)
        }
        let box = ListBox()
        let room = self.room()
        box.page = ([room], nil)
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in box.page },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, _, _, _, _ in throw TestError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        await appState.sendGroupRoomMessage("still pending")
        appState.closeGroupRoom()

        box.page = ([], 50)
        await appState.refreshGroupRooms()

        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.pendingRoomMessage?.text, "still pending")
        appState.closeGroupRoom()
    }

    /// A send that outlives an identity teardown must not unlock a newer
    /// send to the same room when its answer finally lands.
    func testLateSendAfterTeardownKeepsTheNewerSendInFlight() async {
        final class SendGate: @unchecked Sendable {
            var started = 0
            var released = 0
        }
        let gate = SendGate()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, _, _, _ in
                gate.started += 1
                let mine = gate.started
                while gate.released < mine {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return self.sendResult(roomID: roomID, seq: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        func waitForSend(_ count: Int) async {
            for _ in 0..<500 where gate.started < count {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(gate.started, count)
        }

        let old = Task { @MainActor in await appState.sendGroupRoomMessage("before sign-out") }
        await waitForSend(1)
        appState.disconnect()
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        let newer = Task { @MainActor in await appState.sendGroupRoomMessage("after sign-in") }
        await waitForSend(2)
        XCTAssertTrue(appState.activeRoomSendInFlight)

        gate.released = 1
        _ = await old.value
        XCTAssertTrue(appState.activeRoomSendInFlight, "the late answer must not unlock the newer send")

        gate.released = 2
        _ = await newer.value
        XCTAssertFalse(appState.activeRoomSendInFlight)
        appState.closeGroupRoom()
    }

    func testSuccessfulSendClearsThePendingRow() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, roomID in (self.roomWithLatest(4), nil) },
            log: { _, roomID, sinceSeq, _ in
                // The authoritative tail the resync reads after the send
                // landed past unseen events (seq 4 > cursor 0 + 1).
                let events = sinceSeq == 0 ? [self.memberEvent(roomID: roomID, seq: 4)] : []
                return GroupLogPage(events: events, cursor: 4, latestSeq: 4, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, eventID, _, _ in
                self.sendResult(roomID: roomID, seq: 4)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        await appState.sendGroupRoomMessage("first")
        XCTAssertEqual(appState.pendingRoomMessage, nil)
        XCTAssertEqual(appState.activeRoomReplay.cursor, 4)

        appState.closeGroupRoom()
    }

    // MARK: - Approvals

    private func approvalStatus(requestID: String?) -> GroupDriverStatus {
        var actions: [[String: AnyCodable]] = []
        if let requestID {
            actions.append([
                "kind": AnyCodable.from("approval"),
                "task_id": AnyCodable.from("t1"),
                "execution_generation": AnyCodable.from(3),
                "member_id": AnyCodable.from("researcher"),
                "request_id": AnyCodable.from(requestID),
                "approval": AnyCodable.from(["command": "rm -rf build", "description": "recursive delete"]),
            ])
        }
        return GroupDriverStatus(running: true, working: true, blocked: false, counts: [:], pendingActions: actions)
    }

    private func approvingCapabilities() -> GroupCapabilities {
        let base = capabilities(supported: true)
        return GroupCapabilities(
            protocolVersion: base.protocolVersion,
            driverReady: base.driverReady,
            authorityGatewayID: base.authorityGatewayID,
            features: base.features,
            methods: base.methods.union(["groups.approve"]),
            maxLogLimit: base.maxLogLimit
        )
    }

    func testRoomApprovalIsShownAndAnsweredWithItsExactIdentity() async {
        final class Box {
            var pending = true
            var calls: [(String, GroupPendingApproval, String)] = []
        }
        let box = Box()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.approvingCapabilities() },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, self.approvalStatus(requestID: box.pending ? "req-1" : nil)) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            approve: { _, roomID, approval, choice in
                box.calls.append((roomID, approval, choice))
                box.pending = false
                return true
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        XCTAssertEqual(appState.activeRoomPendingApprovals.count, 1)
        guard let approval = appState.activeRoomPendingApprovals.first else {
            return XCTFail("expected a pending approval")
        }
        XCTAssertEqual(approval.command, "rm -rf build")

        // A choice rooms don't offer is never sent.
        await appState.respondToRoomApproval(approval, choice: "session")
        XCTAssertTrue(box.calls.isEmpty)

        await appState.respondToRoomApproval(approval, choice: "once")
        XCTAssertEqual(box.calls.count, 1)
        XCTAssertEqual(box.calls.first?.0, "room-1")
        XCTAssertEqual(box.calls.first?.1.taskID, "t1")
        XCTAssertEqual(box.calls.first?.1.executionGeneration, 3)
        XCTAssertEqual(box.calls.first?.1.requestID, "req-1")
        XCTAssertEqual(box.calls.first?.2, "once")
        XCTAssertTrue(appState.activeRoomPendingApprovals.isEmpty)
        // The sent answer outlives the poll, so a stale status can't revive it.
        XCTAssertEqual(appState.roomApprovalAnswers[approval.id], .sent)

        appState.closeGroupRoom()
    }

    func testSentRoomApprovalStaysHiddenWhileAStaleStatusStillListsIt() async {
        final class Box { var approved = 0 }
        let box = Box()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.approvingCapabilities() },
            list: { _ in ([room], nil) },
            // The gateway keeps listing it (a status read before the answer).
            state: { _, _ in (room, self.approvalStatus(requestID: "req-1")) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            approve: { _, _, _, _ in
                box.approved += 1
                return true
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        guard let approval = appState.activeRoomPendingApprovals.first else {
            return XCTFail("expected a pending approval")
        }

        await appState.respondToRoomApproval(approval, choice: "deny")
        XCTAssertEqual(box.approved, 1)
        XCTAssertTrue(appState.activeRoomPendingApprovals.isEmpty)
        // A second tap on the same request never goes out.
        await appState.respondToRoomApproval(approval, choice: "deny")
        XCTAssertEqual(box.approved, 1)

        appState.closeGroupRoom()
    }

    func testFailedRoomApprovalKeepsTheCardWithItsError() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.approvingCapabilities() },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, self.approvalStatus(requestID: "req-1")) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            approve: { _, _, _, _ in throw TestError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        guard let approval = appState.activeRoomPendingApprovals.first else {
            return XCTFail("expected a pending approval")
        }

        await appState.respondToRoomApproval(approval, choice: "once")
        XCTAssertEqual(appState.activeRoomPendingApprovals.count, 1)
        guard case .failed = appState.roomApprovalAnswers[approval.id] else {
            return XCTFail("expected a failed answer, got \(String(describing: appState.roomApprovalAnswers[approval.id]))")
        }

        appState.closeGroupRoom()
        XCTAssertTrue(appState.roomApprovalAnswers.isEmpty)
    }

    func testRoomApprovalThatResolvedNothingReadsAsNoLongerActive() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.approvingCapabilities() },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, self.approvalStatus(requestID: "req-1")) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            approve: { _, _, _, _ in false }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        guard let approval = appState.activeRoomPendingApprovals.first else {
            return XCTFail("expected a pending approval")
        }

        await appState.respondToRoomApproval(approval, choice: "once")
        XCTAssertEqual(
            appState.roomApprovalAnswers[approval.id],
            .failed(AppLocalization.string("This approval is no longer active."))
        )
        appState.closeGroupRoom()
    }

    func testAnIdleRoomsPillsShowNoLiveTurn() async {
        let room = self.room()
        func statuses(working: Bool) async -> (AppState, [String: GroupMemberStatus]) {
            let driver = GroupDecoders.driverStatus(AnyCodable.from([
                "running": true, "working": working, "blocked": false,
                "member_activity": [["member_id": "researcher", "status": "running"]],
            ] as [String: Any]))
            let operations = GroupChatLifecycleOperations(
                capabilities: { _ in self.capabilities(supported: true) },
                list: { _ in ([room], nil) },
                state: { _, _ in (room, driver) },
                log: { _, _, sinceSeq, _ in
                    GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                                 authorityGatewayID: "gw-a", authorityEpoch: 1)
                }
            )
            let appState = makeAppState(operations: operations)
            connect(appState)
            await appState.refreshGroupChatSupport()
            await appState.openGroupRoom(room)
            let result = appState.activeRoomMemberStatuses
            appState.closeGroupRoom()
            return (appState, result)
        }
        let (_, working) = await statuses(working: true)
        XCTAssertEqual(working["researcher"], .responding)
        // The driver went idle while still listing the turn.
        let (_, idle) = await statuses(working: false)
        XCTAssertNil(idle["researcher"])
    }

    func testGatewayWithoutGroupsApproveShowsNoApprovalCards() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, self.approvalStatus(requestID: "req-1")) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomDriverStatus?.pendingApprovals.count, 1)
        XCTAssertTrue(appState.activeRoomPendingApprovals.isEmpty)
        appState.closeGroupRoom()
    }

    /// A DIFFERENT text typed after an ambiguous failure must NEVER be
    /// silently converted into a resend of the old pending text (the
    /// data-loss path): it is refused, the pending row stays visible, and
    /// the retry keeps the original event id.
    // MARK: - Room settings and Continue (Hermes 0.23)

    private func settingsCapabilities() -> GroupCapabilities {
        let base = capabilities(supported: true)
        return GroupCapabilities(
            protocolVersion: base.protocolVersion,
            driverReady: base.driverReady,
            authorityGatewayID: base.authorityGatewayID,
            features: base.features,
            methods: base.methods.union(["groups.context", "groups.continue"]),
            maxLogLimit: base.maxLogLimit
        )
    }

    func testRoomSettingsSaveSendsRoutingOnlyWhereTheHostRoutes() async {
        final class Box {
            var routes = true
            var newer = false
            var saves: [(String, String, GroupRoomContext, Bool)] = []
        }
        let box = Box()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.settingsCapabilities() },
            list: { _ in ([room], nil) },
            state: { _, _ in
                var status = GroupDriverStatus(running: true, working: false, blocked: false, counts: [:], pendingActions: [])
                status.routingModes = box.newer ? ["vote"] : box.routes ? ["everyone", "lead", "auto"] : nil
                var context = GroupRoomContext(purpose: "Plans")
                if box.newer { context.newerRouting = "vote" }
                status.roomContext = context
                return (room, status)
            },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            context: { _, roomID, eventID, context, includesRouting in
                box.saves.append((roomID, eventID, context, includesRouting))
                return context
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        XCTAssertTrue(appState.canEditActiveRoomSettings)
        XCTAssertEqual(appState.activeRoomRoutingModes, [.everyone, .lead, .auto])

        let lead = GroupRoomContext(purpose: "Plans", routing: .lead, leadMemberID: "researcher")
        let error = await appState.saveActiveRoomSettings(lead, eventID: "context-1", roomID: "room-1")
        XCTAssertNil(error)
        XCTAssertEqual(box.saves.first?.0, "room-1")
        XCTAssertEqual(box.saves.first?.1, "context-1")
        XCTAssertEqual(box.saves.first?.2, lead)
        XCTAssertEqual(box.saves.first?.3, true)

        // A save that leaves who answers as it opened keeps the room's own
        // routing, a mode this client predates included.
        var purposeOnly = appState.activeRoomContext ?? GroupRoomContext()
        purposeOnly.purpose = "Trips"
        _ = await appState.saveActiveRoomSettings(purposeOnly, eventID: "context-1b", roomID: "room-1")
        XCTAssertEqual(box.saves.last?.3, false)
        // Drafted from settings another client has changed since: who
        // answers was left as it opened, so the newer routing stays.
        let opened = GroupRoomContext(purpose: "Plans")
        var drafted = opened
        drafted.purpose = "Trips"
        _ = await appState.saveActiveRoomSettings(drafted, eventID: "context-1c", roomID: "room-1", original: opened)
        XCTAssertEqual(box.saves.last?.3, false)

        // A host before routing keeps the room's routing as it is.
        box.routes = false
        appState.closeGroupRoom()
        await appState.openGroupRoom(room)
        XCTAssertTrue(appState.activeRoomRoutingModes.isEmpty)
        _ = await appState.saveActiveRoomSettings(GroupRoomContext(purpose: "New"), eventID: "context-2", roomID: "room-1")
        XCTAssertEqual(box.saves.last?.3, false)
        // A host listing only a mode newer than this app, with the room on
        // it: picking Everyone in its place sends it.
        box.newer = true
        appState.closeGroupRoom()
        await appState.openGroupRoom(room)
        XCTAssertTrue(appState.activeRoomRoutingModes.isEmpty)
        XCTAssertEqual(appState.activeRoomContext?.newerRouting, "vote")
        _ = await appState.saveActiveRoomSettings(GroupRoomContext(purpose: "Plans"), eventID: "context-2b", roomID: "room-1")
        XCTAssertEqual(box.saves.last?.3, true)
        // Drafted for another room: refused, nothing sent.
        let count = box.saves.count
        let refused = await appState.saveActiveRoomSettings(GroupRoomContext(purpose: "X"), eventID: "context-3", roomID: "room-2")
        XCTAssertNotNil(refused)
        XCTAssertEqual(box.saves.count, count)
        appState.closeGroupRoom()
    }

    func testContinueIsOfferedUnderAPauseAndSendsItsDiscussion() async {
        final class Box {
            var continued: [String] = []
            var maxContinues = 5
        }
        let box = Box()
        let room = self.room()
        let events = [
            GroupDecoders.event(AnyCodable.from([
                "room_id": "room-1", "seq": 1, "event_id": "user:d1", "kind": "message.user",
                "actor": ["kind": "user", "id": "human"], "payload": ["text": "Debate", "thread_id": "main"],
                "created_at": 1.0,
            ]))!,
            GroupDecoders.event(AnyCodable.from([
                "room_id": "room-1", "seq": 2, "event_id": "cap-1", "kind": "room.activity",
                "actor": ["kind": "gateway", "id": "gw-a"],
                "payload": ["status": "bounded", "thread_id": "main", "discussion_event_id": "user:d1"],
                "created_at": 2.0,
            ]))!,
        ]
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.settingsCapabilities() },
            list: { _ in ([room], nil) },
            state: { _, _ in
                var status = GroupDriverStatus(running: true, working: false, blocked: false, counts: [:], pendingActions: [])
                status.maxContinues = box.maxContinues
                return (self.roomWithLatest(2), status)
            },
            log: { _, _, sinceSeq, _ in
                let fresh = events.filter { $0.seq > sinceSeq }
                return GroupLogPage(events: fresh, cursor: fresh.last?.seq ?? sinceSeq, latestSeq: 2, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            continueDiscussion: { _, _, discussionID in box.continued.append(discussionID) }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        XCTAssertEqual(appState.activeRoomContinuablePauses["cap-1"]?.discussionEventID, "user:d1")
        // A cap of one still offers the first Continue.
        box.maxContinues = 1
        appState.closeGroupRoom()
        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomContinuablePauses["cap-1"]?.grant, 1)
        // The host's cap decides: a pause whose next grant is past it offers nothing.
        box.maxContinues = 0
        appState.closeGroupRoom()
        await appState.openGroupRoom(room)
        XCTAssertTrue(appState.activeRoomContinuablePauses.isEmpty)
        // A tap that lands after the pause ended sends nothing.
        await appState.continueActiveRoomDiscussion("user:d1")
        XCTAssertTrue(box.continued.isEmpty)
        box.maxContinues = 5
        appState.closeGroupRoom()
        await appState.openGroupRoom(room)
        XCTAssertNotNil(appState.activeRoomContinuablePauses["cap-1"])
        await appState.continueActiveRoomDiscussion("user:d1")
        XCTAssertEqual(box.continued, ["user:d1"])
        appState.closeGroupRoom()
    }

    func testNewTextAfterAmbiguousFailureIsRefusedNotSwallowed() async {
        final class SendRecorder {
            var ids: [String] = []
            var failFirst = true
        }
        let recorder = SendRecorder()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, roomID in (room, nil) },
            log: { _, roomID, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, eventID, text, _ in
                recorder.ids.append(eventID)
                XCTAssertEqual(text, "original message")
                if recorder.failFirst {
                    recorder.failFirst = false
                    throw TestError()
                }
                return self.sendResult(roomID: roomID, seq: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)

        // First send fails ambiguously → pending keeps its retry key.
        await appState.sendGroupRoomMessage("original message")
        XCTAssertEqual(recorder.ids.count, 1)
        let pendingID = appState.pendingRoomMessage?.eventID
        XCTAssertEqual(pendingID, recorder.ids[0])

        // The user types something NEW: refused — nothing reaches the RPC,
        // the pending row (old text, old id) stays exactly as it was.
        await appState.sendGroupRoomMessage("a brand new thought")
        XCTAssertEqual(recorder.ids.count, 1, "the new text must not hit the wire")
        XCTAssertEqual(appState.pendingRoomMessage?.text, "original message")
        XCTAssertEqual(appState.pendingRoomMessage?.eventID, pendingID)
        XCTAssertNotNil(appState.errorMessage)

        // The explicit retry of the ORIGINAL text still dedupes server-side.
        await appState.sendGroupRoomMessage("original message")
        XCTAssertEqual(recorder.ids, [pendingID ?? "", pendingID ?? ""])
        XCTAssertEqual(appState.pendingRoomMessage, nil)

        appState.closeGroupRoom()
    }

    /// A send accepted at a seq PAST unseen events (the room moved between
    /// polls) must resync from the room's authoritative cursor, never adopt
    /// a hole into the transcript.
    func testSendLandingPastUnseenEventsResyncsInsteadOfGapping() async {
        final class RoomBox {
            var latestSeq = 0
        }
        let box = RoomBox()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, roomID in
                (self.roomWithLatest(box.latestSeq), nil)
            },
            log: { _, roomID, sinceSeq, _ in
                let first = max(1, sinceSeq)
                let events: [GroupEvent] = box.latestSeq >= first
                    ? (first...box.latestSeq).map { self.memberEvent(roomID: roomID, seq: $0) }
                    : []
                return GroupLogPage(events: events, cursor: box.latestSeq,
                                    latestSeq: box.latestSeq, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, eventID, _, _ in
                // The room moved on while we were sending: our event is seq 5.
                box.latestSeq = 5
                return self.sendResult(roomID: roomID, seq: 5)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomReplay.cursor, 0)

        await appState.sendGroupRoomMessage("hello room")
        XCTAssertEqual(appState.pendingRoomMessage, nil)
        // The transcript is the AUTHORITATIVE tail 1...5 — not a hole 1→5.
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1, 2, 3, 4, 5])
        XCTAssertEqual(appState.activeRoomReplay.hasGap, false)

        appState.closeGroupRoom()
    }

    /// A poll that returns several new, contiguous events adopts them as a
    /// delta: no `groups.state` + bounded-tail resync on a busy tick.
    func testContiguousMultiEventPollAdoptsWithoutResync() async {
        final class RoomBox {
            var latestSeq = 1
            var logCalls: [Int] = []
        }
        let box = RoomBox()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (self.roomWithLatest(box.latestSeq), nil) },
            log: { _, roomID, sinceSeq, _ in
                box.logCalls.append(sinceSeq)
                let first = sinceSeq + 1
                let events: [GroupEvent] = box.latestSeq >= first
                    ? (first...box.latestSeq).map { self.memberEvent(roomID: roomID, seq: $0) }
                    : []
                return GroupLogPage(events: events, cursor: box.latestSeq,
                                    latestSeq: box.latestSeq, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            stop: { _, _ in 0 }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1])

        // Three members answer between ticks; stop runs one poll tick.
        box.latestSeq = 4
        box.logCalls.removeAll()
        await appState.stopActiveRoomWork()
        XCTAssertEqual(box.logCalls, [1], "one incremental groups.log, no resync tail")
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(appState.activeRoomReplay.hasGap, false)

        appState.closeGroupRoom()
    }

    /// The V2 shell keeps a hidden tab's room mounted: its poll stops while
    /// no room screen shows, and catches up once when one shows again
    /// (#1827).
    func testRoomPollStopsWhileHiddenAndCatchesUpWhenShown() async throws {
        final class RoomBox {
            var latestSeq = 1
            var logCalls: [Int] = []
        }
        let box = RoomBox()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (self.roomWithLatest(box.latestSeq), nil) },
            log: { _, roomID, sinceSeq, _ in
                box.logCalls.append(sinceSeq)
                let first = sinceSeq + 1
                let events: [GroupEvent] = box.latestSeq >= first
                    ? (first...box.latestSeq).map { self.memberEvent(roomID: roomID, seq: $0) }
                    : []
                return GroupLogPage(events: events, cursor: box.latestSeq,
                                    latestSeq: box.latestSeq, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            stop: { _, _ in 0 }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        let screen = UUID()
        appState.noteRoomView(screen, shows: true)
        XCTAssertTrue(appState.roomSurfaceShows)

        box.logCalls.removeAll()
        await appState.stopActiveRoomWork()
        XCTAssertEqual(box.logCalls, [1])

        // Hidden: no reads.
        appState.noteRoomView(screen, shows: false)
        XCTAssertFalse(appState.roomSurfaceShows)
        box.latestSeq = 3
        box.logCalls.removeAll()
        await appState.stopActiveRoomWork()
        XCTAssertEqual(box.logCalls, [], "no groups.log while the room is hidden")

        // Shown again: one read at once, with what came meanwhile.
        appState.noteRoomView(screen, shows: true)
        for _ in 0..<200 where box.logCalls.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(box.logCalls, [1])
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1, 2, 3])

        // Its screen gone while the room stays open (a page pushed over it):
        // hidden, until a screen shows it again.
        appState.noteRoomView(screen, shows: nil)
        XCTAssertFalse(appState.roomSurfaceShows)
        let next = UUID()
        appState.noteRoomView(next, shows: true)
        XCTAssertTrue(appState.roomSurfaceShows)
        appState.noteRoomView(next, shows: nil)

        // Another room opened before its screen appears counts as showing.
        appState.closeGroupRoom()
        XCTAssertTrue(appState.roomSurfaceShows)
    }

    /// `groups.create` REQUIRES a client-minted `room_id` (it is the room's
    /// identity and its create idempotency key). Assert the outgoing params
    /// carry a non-empty, validator-legal one — the injected seam sees the
    /// exact payload the production path builds.
    func testCreateMintsAValidatorLegalRoomIDAndMemberRows() async {
        let room = self.room()
        final class CreateRecorder {
            var roomIDs: [String] = []
            var name: String?
            var members: [[String: Any]] = []
        }
        let recorder = CreateRecorder()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, roomID in (self.roomWithLatest(0), nil) },
            log: { _, roomID, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            create: { _, roomID, name, members in
                recorder.roomIDs.append(roomID)
                recorder.name = name
                recorder.members = members
                return room
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        let bots = [Self.makeBot("alpha"), Self.makeBot("beta")]
        let created = await appState.createGroupRoom(
            name: "Planning", bots: bots, roomID: "conduit-test-room-001"
        )
        XCTAssertEqual(created, true)

        XCTAssertEqual(recorder.roomIDs.count, 1)
        let roomID = recorder.roomIDs[0]
        XCTAssertEqual(roomID, "conduit-test-room-001")
        // Gateway validator: ^[A-Za-z0-9][A-Za-z0-9._:-]*$, <=128 chars.
        XCTAssertFalse(roomID.isEmpty)
        XCTAssertLessThanOrEqual(roomID.count, 128)
        XCTAssertTrue(roomID.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == ":" || $0 == "-"
        })
        XCTAssertEqual(recorder.name, "Planning")
        XCTAssertEqual(recorder.members.count, 2)
        for member in recorder.members {
            XCTAssertNotNil(member["member_id"])
            XCTAssertNotNil(member["profile"])
            XCTAssertNotNil(member["handle"])
            XCTAssertNotNil(member["display_name"])
        }
        XCTAssertEqual(Set(recorder.members.compactMap { $0["display_name"] as? String }), ["Alpha", "Beta"],
                       "an unnamed bot joins by its id capitalized, as Bots names it (#1448)")
        // Creation opens the fresh room; closing leaves session state alone.
        XCTAssertEqual(appState.activeRoomSurface?.room.roomID, "room-1")
        appState.closeGroupRoom()
        XCTAssertEqual(appState.activeSessionId, nil)
    }

    /// The real tombstone signal on the wire is an ERROR: `groups.state`
    /// with the tombstone not opted into answers "hosted room not found"
    /// (4114/4112) instead of a disbanded room. The surface must close on
    /// that answer, not spin forever.
    func testRoomNotFoundAnswerClosesTheSurface() async {
        struct RoomGoneError: LocalizedError {
            var errorDescription: String? { "hosted room not found" }
        }
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([self.room()], nil) },
            state: { _, _ in throw RoomGoneError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(self.room())
        XCTAssertEqual(appState.activeRoomSurface, nil)
        XCTAssertEqual(appState.activeSessionId, nil)
    }

    private static func makeBot(_ name: String) -> BotProfile {
        BotProfile(
            name: name,
            botTitle: nil,
            displayName: "",
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: false,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: nil,
            lastActive: nil,
            lastPreview: nil
        )
    }

    /// A room reported as tombstoned during open closes the surface.
    func testDisbandedRoomClosesTheSurfaceDuringOpen() async {
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([self.room()], nil) },
            state: { _, roomID in (self.disbandedRoom(roomID: roomID), nil) },
            log: { _, roomID, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        // groups.state answers a TOMBSTONED room for an open attempt…
        await appState.openGroupRoom(self.room())
        // …so the surface closes instead of haunting a disbanded room.
        XCTAssertEqual(appState.activeRoomSurface, nil)
        XCTAssertEqual(appState.activeSessionId, nil)
    }

    /// Sign-out ends the room surface: its poller, transcript, and pending
    /// outbox belong to the outgoing session. A same-dashboard sign-in never
    /// crosses the server-identity boundary, so disconnect itself must tear
    /// the room down.
    func testDisconnectTearsDownTheRoomSurfaceAndGroupState() async {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, _, _, _, _ in throw TestError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        await appState.sendGroupRoomMessage("still pending")
        XCTAssertNotNil(appState.activeRoomSurface)
        XCTAssertNotNil(appState.pendingRoomMessage)
        let draftKey = ComposerDraftKey(profile: "default", sessionID: "stored-1")
        appState.composerDraftStore.save(
            ComposerDraft(text: "unsent words", attachments: []),
            for: draftKey
        )

        appState.disconnect()

        XCTAssertTrue(appState.composerDraftStore.draft(for: draftKey).isEmpty,
                      "sign-out clears the signed-out user's drafts")
        XCTAssertEqual(appState.activeRoomSurface, nil)
        XCTAssertEqual(appState.pendingRoomMessage, nil)
        XCTAssertTrue(appState.activeRoomReplay.events.isEmpty)
        XCTAssertEqual(appState.groupChatPhase, .idle)
        XCTAssertTrue(appState.groupRooms.isEmpty)
    }

    /// A send the guards decline (no open room) reports that nothing holds
    /// the text, so the composer keeps its draft; a registered send reports
    /// true even when its outcome is ambiguous (the pending row owns it).
    func testSendReportsWhetherThePendingRowOwnsTheText() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, _, _, _, _ in throw TestError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()

        let declined = await appState.sendGroupRoomMessage("no room open")
        XCTAssertFalse(declined)
        XCTAssertEqual(appState.pendingRoomMessage, nil)

        await appState.openGroupRoom(room)
        let registered = await appState.sendGroupRoomMessage("ambiguous")
        XCTAssertTrue(registered)
        XCTAssertEqual(appState.pendingRoomMessage?.text, "ambiguous")

        appState.closeGroupRoom()
    }

    private func disbandedRoom(roomID: String) -> GroupRoom {
        GroupRoom(
            roomID: roomID,
            name: "Planning",
            members: [],
            authorityGatewayID: "gw-a",
            authorityEpoch: 1,
            revision: 2,
            createdAt: 0,
            updatedAt: 0,
            disbandedAt: 99,
            latestSeq: 0
        )
    }

    private func roomWithLatest(_ latest: Int) -> GroupRoom {
        GroupRoom(
            roomID: "room-1",
            name: "Planning",
            members: [],
            authorityGatewayID: "gw-a",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            disbandedAt: nil,
            latestSeq: latest
        )
    }

    private func memberEvent(roomID: String, seq: Int) -> GroupEvent {
        GroupEvent(
            roomID: roomID,
            seq: seq,
            eventID: "srv-\(seq)",
            kind: "message.member",
            actor: GroupActor(kind: "member", id: "researcher", profile: "researcher",
                              displayName: "Research Buddy", connectionID: nil),
            authorityEpoch: nil,
            payload: ["text": .string("m\(seq)"), "thread_id": .string("main")],
            createdAt: 0
        )
    }

    // MARK: - Talking rooms (Bots Home's live rooms)

    /// Bots Home asks each room whether its bots are talking: a working
    /// driver is talking, a room that doesn't answer keeps what it was,
    /// and a disconnect clears them.
    func testTalkingRoomsAreTheRoomsWhoseDriverWorks() async {
        final class Box {
            var working: Set<String> = []
            var failing: Set<String> = []
            var rooms: [GroupRoom] = []
            var asked: [String] = []
        }
        let box = Box()
        let planning = room(name: "Planning")
        let quiet = GroupRoom(roomID: "room-2", name: "Quiet", members: planning.members, authorityGatewayID: "gw-a",
                              authorityEpoch: 1, revision: 1, createdAt: 0, updatedAt: 5, disbandedAt: nil, latestSeq: 0)
        box.rooms = [planning, quiet]
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in (box.rooms, nil) },
            state: { _, roomID in
                box.asked.append(roomID)
                if box.failing.contains(roomID) { throw TestError() }
                let room = box.rooms.first { $0.roomID == roomID } ?? planning
                return (room, GroupDriverStatus(running: true, working: box.working.contains(roomID), blocked: false,
                                                counts: [:], pendingActions: []))
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        await appState.refreshGroupChatSupport()

        box.working = [planning.roomID]
        await appState.refreshTalkingRooms()
        XCTAssertEqual(appState.talkingRoomIDs, [planning.roomID])
        XCTAssertEqual(appState.talkingRooms(of: "Researcher").map(\.name), ["Planning"])
        XCTAssertEqual(BotPortraitStatus.of(nil, talkingIn: ["Planning"]).title,
                       AppLocalization.string("In \("Planning")"))

        box.working = [quiet.roomID]
        box.failing = [planning.roomID]
        await appState.refreshTalkingRooms()
        XCTAssertEqual(appState.talkingRoomIDs, [planning.roomID, quiet.roomID])
        // Talked in last first.
        XCTAssertEqual(appState.talkingRooms.map(\.name), ["Quiet", "Planning"])

        // A room that keeps failing drops out after its third miss.
        await appState.refreshTalkingRooms()
        XCTAssertEqual(appState.talkingRoomIDs, [planning.roomID, quiet.roomID])
        await appState.refreshTalkingRooms()
        XCTAssertEqual(appState.talkingRoomIDs, [quiet.roomID])

        // Only the rooms talked in last are asked: Planning (the oldest)
        // falls outside them once eight newer rooms are listed.
        box.failing = []
        box.working = [planning.roomID]
        box.rooms = [planning] + (1...AppState.talkingRoomsRead).map { index in
            GroupRoom(roomID: "room-n\(index)", name: "Newer \(index)", members: planning.members,
                      authorityGatewayID: "gw-a", authorityEpoch: 1, revision: 1, createdAt: 0,
                      updatedAt: Double(10 + index), disbandedAt: nil, latestSeq: 0)
        }
        await appState.refreshGroupRooms()
        box.asked = []
        await appState.refreshTalkingRooms()
        XCTAssertFalse(box.asked.contains(planning.roomID))
        XCTAssertEqual(box.asked.count, AppState.talkingRoomsRead)
        XCTAssertTrue(appState.talkingRoomIDs.isEmpty)

        // Bots Home and an overview asking in the same round read once.
        box.asked = []
        await appState.refreshTalkingRoomsIfDue(every: .seconds(12))
        await appState.refreshTalkingRoomsIfDue(every: .seconds(12))
        XCTAssertEqual(box.asked.count, AppState.talkingRoomsRead)

        // Dropped and back within the round: asked at once on return,
        // through the same ask Bots Home makes.
        appState.isConnected = false
        await appState.refreshTalkingRoomsIfDue(every: .seconds(12))
        XCTAssertTrue(appState.talkingRoomIDs.isEmpty)
        appState.isConnected = true
        box.asked = []
        await appState.refreshTalkingRoomsIfDue(every: .seconds(12))
        XCTAssertEqual(box.asked.count, AppState.talkingRoomsRead)
    }
}
