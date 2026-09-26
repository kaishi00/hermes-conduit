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
                XCTAssertEqual(threadID, "main")
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

    /// A DIFFERENT text typed after an ambiguous failure must NEVER be
    /// silently converted into a resend of the old pending text (the
    /// data-loss path): it is refused, the pending row stays visible, and
    /// the retry keeps the original event id.
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
}
