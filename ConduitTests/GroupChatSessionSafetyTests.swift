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
            log: { _, roomID, sinceSeq in
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
            log: { _, _, sinceSeq in
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
            log: { _, roomID, sinceSeq in
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

    func testSuccessfulSendClearsThePendingRow() async {
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([room], nil) },
            state: { _, roomID in (self.roomWithLatest(4), nil) },
            log: { _, roomID, sinceSeq in
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
            log: { _, roomID, sinceSeq in
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
            log: { _, roomID, sinceSeq in
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
            log: { _, roomID, sinceSeq in
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

    /// A room the gateway reports as tombstoned (even with zero new log
    /// events) closes the surface instead of leaving a poller spinning
    /// against the tombstone.
    func testQuietlyDisbandedRoomClosesTheSurfaceOnTheNextStatusTick() async {
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in ([self.room()], nil) },
            state: { _, roomID in (self.disbandedRoom(roomID: roomID), nil) },
            log: { _, roomID, sinceSeq in
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
