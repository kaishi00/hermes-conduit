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
            state: { _, roomID in (room, nil) },
            log: { _, roomID, sinceSeq in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
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
}
