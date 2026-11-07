import XCTest

@testable import Conduit

/// Group Chat wire-model decoding, the replay engine, the send outbox, and
/// room-mention classification — contract tests against the pinned upstream
/// Hermes SHA fdec926e (`tui_gateway/methods_groups.py`,
/// `gateway/hosted_rooms.py`).
final class GroupChatModelsTests: XCTestCase {
    private func any(_ value: Any) -> AnyCodable { AnyCodable.from(value) }

    private func eventJSON(
        roomID: String = "room-1",
        seq: Int,
        kind: String,
        actor: [String: Any] = ["kind": "user", "id": "human"],
        payload: [String: Any] = [:],
        eventID: String? = nil
    ) -> [String: Any] {
        [
            "room_id": roomID,
            "seq": seq,
            "event_id": eventID ?? "e\(seq)",
            "kind": kind,
            "actor": actor,
            "payload": payload,
            "created_at": 1000.0 + Double(seq),
        ]
    }

    private func logPage(_ events: [[String: Any]], latest: Int? = nil) -> GroupLogPage {
        let payload: [String: Any] = [
            "events": events,
            "cursor": events.last?["seq"] ?? 0,
            "latest_seq": latest ?? (events.last?["seq"] as? Int ?? 0),
            "has_more": false,
            "authority": ["gateway_id": "gw-a", "epoch": 1],
        ]
        return GroupDecoders.logPage(any(payload))!
    }

    // MARK: - Capabilities

    func testCapabilitiesDecodeAndNegotiation() {
        let payload = any([
            "protocol_version": 2,
            "driver": true,
            "persistent_process": true,
            "authority_gateway_id": "gw-a",
            "features": ["monotonic_log", "typed_events", "idempotent_send"],
            "methods": [
                "groups.capabilities", "groups.list", "groups.create", "groups.state", "groups.send",
                "groups.log", "groups.disband", "groups.stop", "groups.rename", "groups.approve",
                "groups.retry", "groups.replicate", "groups.replica_state", "groups.promote",
                "groups.demote", "groups.peer.invite", "groups.peer.revoke", "groups.peer.register",
            ],
            "max_log_limit": 500,
        ])
        let capabilities = GroupCapabilitiesDecoder.decode(payload)
        XCTAssertNotNil(capabilities)
        XCTAssertEqual(capabilities?.protocolVersion, 2)
        XCTAssertEqual(capabilities?.driverReady, true)
        XCTAssertEqual(capabilities?.authorityGatewayID, "gw-a")
        XCTAssertEqual(capabilities?.maxLogLimit, 500)
        XCTAssertEqual(capabilities?.foundationSupported, true)
        XCTAssertTrue(capabilities?.supports("groups.stop") ?? false)
    }

    func testPartialMethodListIsNotFoundationSupported() {
        let payload = any([
            "protocol_version": 2,
            "methods": ["groups.capabilities", "groups.list", "groups.state"],
            "max_log_limit": 500,
        ])
        let capabilities = GroupCapabilitiesDecoder.decode(payload)
        XCTAssertEqual(capabilities?.foundationSupported, false)
    }

    func testMalformedCapabilitiesDecodeToNil() {
        XCTAssertNil(GroupCapabilitiesDecoder.decode(nil))
        XCTAssertNil(GroupCapabilitiesDecoder.decode(any(["nope": 1])))
        XCTAssertNil(GroupCapabilitiesDecoder.decode(any(["methods": []])))
        XCTAssertNil(GroupCapabilitiesDecoder.decode(any(["methods": "not-a-list"])))
    }

    // MARK: - Room / member / event decode

    private func roomPayload(disbanded: Bool = false) -> [String: Any] {
        var payload: [String: Any] = [
            "room_id": "room-1",
            "name": "Planning",
            "members": [
                [
                    "member_id": "researcher",
                    "profile": "researcher",
                    "handle": "research-buddy",
                    "display_name": "Research Buddy",
                ],
                [
                    "member_id": "writer",
                    "profile": "writer",
                    "handle": "writer",
                    "display_name": "Writer",
                    "custom_future_field": 17,
                ],
            ],
            "authority_gateway_id": "gw-a",
            "authority_epoch": 1,
            "revision": 4,
            "created_at": 10.0,
            "updated_at": 20.0,
            "latest_seq": 9,
        ]
        if disbanded {
            payload["disbanded_at"] = 30.0
        }
        return payload
    }

    func testRoomDecode() {
        let room = GroupDecoders.room(any(roomPayload()))
        XCTAssertEqual(room?.roomID, "room-1")
        XCTAssertEqual(room?.name, "Planning")
        XCTAssertEqual(room?.members.count, 2)
        XCTAssertEqual(room?.authorityGatewayID, "gw-a")
        XCTAssertEqual(room?.authorityEpoch, 1)
        XCTAssertEqual(room?.revision, 4)
        XCTAssertEqual(room?.latestSeq, 9)
        XCTAssertEqual(room?.isDisbanded, false)
    }

    func testDisbandedRoomDecode() {
        let room = GroupDecoders.room(any(roomPayload(disbanded: true)))
        XCTAssertEqual(room?.disbandedAt, 30.0)
        XCTAssertEqual(room?.isDisbanded, true)
    }

    func testRoomWithoutIdentityDecodesToNil() {
        XCTAssertNil(GroupDecoders.room(any(["name": "no identity"])))
        XCTAssertNil(GroupDecoders.room(any(["room_id": "   "])))
        XCTAssertNil(GroupDecoders.room(nil))
    }

    func testMemberIdentityKeyPrefersMemberIDAndPreservesExtraFields() {
        let members = GroupDecoders.room(any(roomPayload()))?.members ?? []
        XCTAssertEqual(members[0].identityKey, "researcher")
        XCTAssertEqual(members[1].identityKey, "writer")
        XCTAssertEqual(members[1].extra["custom_future_field"]?.intValue, 17)
        // A member with no ids degrades to an empty key, never a display name.
        let anonymous = GroupDecoders.member(any(["display_name": "Someone"]))
        XCTAssertEqual(anonymous?.identityKey, "")
    }

    func testEventDecodeKeepsUnknownKindsAndRawPayload() {
        let event = GroupDecoders.event(any(eventJSON(
            seq: 3,
            kind: "message.user",
            payload: ["text": "hello @all", "thread_id": "main"]
        )))
        XCTAssertEqual(event?.seq, 3)
        XCTAssertEqual(event?.eventID, "e3")
        XCTAssertEqual(event?.kind, "message.user")
        XCTAssertEqual(event?.isUserMessage, true)
        XCTAssertEqual(event?.messageText, "hello @all")
        XCTAssertEqual(event?.threadID, "main")
        XCTAssertEqual(event?.actor.kind, "user")

        let future = GroupDecoders.event(any(eventJSON(
            seq: 4, kind: "room.somefuturekind", actor: ["kind": "gateway", "id": "driver"]
        )))
        XCTAssertEqual(future?.kind, "room.somefuturekind")
        XCTAssertEqual(future?.isChatMessage, false)
        XCTAssertEqual(future?.actor.kind, "gateway")
    }

    func testEventRejectsMissingSeqOrRoom() {
        XCTAssertNil(GroupDecoders.event(any(["seq": 1])))
        XCTAssertNil(GroupDecoders.event(any(["room_id": "r"])))
        XCTAssertNil(GroupDecoders.event(any(eventJSON(roomID: "room-1", seq: 0, kind: "message.user"))))
    }

    /// Gateway numbers go through the exact-integer reader: an out-of-range
    /// value must never trap the app, and a fractional one is refused
    /// instead of being truncated into a different seq.
    func testOutOfRangeOrFractionalNumbersNeverDecodeAsIntegers() {
        XCTAssertNil(GroupDecoders.event(any([
            "room_id": "room-1", "seq": 1e20, "kind": "message.user",
        ])))
        XCTAssertNil(GroupDecoders.event(any([
            "room_id": "room-1", "seq": 2.7, "kind": "message.user",
        ])))
        let room = GroupDecoders.room(any([
            "room_id": "room-1", "revision": 1e30, "latest_seq": 3.5, "authority_epoch": -1e25,
        ]))
        XCTAssertEqual(room?.revision, 0)
        XCTAssertNil(room?.latestSeq)
        XCTAssertEqual(room?.authorityEpoch, 1)
        XCTAssertNil(GroupDecoders.logPage(any(["latest_seq": 1e20, "events": []])))
        let status = GroupDecoders.driverStatus(any(["counts": ["queued": 2, "huge": 1e40]]))
        XCTAssertEqual(status?.counts, ["queued": 2])
    }

    // MARK: - Create idempotency

    func testCreateRetryKeepsTheRoomIDOnlyForUnchangedInputs() {
        let first = GroupCreateAttempt.Inputs(name: "Planning", members: ["a", "b"])
        // First attempt: nothing attempted yet, the minted id is kept.
        XCTAssertEqual(GroupCreateAttempt.roomID(for: first, current: "room-x", attempted: nil), "room-x")
        // Retry of the same inputs after an ambiguous failure: same id.
        XCTAssertEqual(GroupCreateAttempt.roomID(for: first, current: "room-x", attempted: first), "room-x")
        // Edited name or roster: a different room, so a fresh id.
        let renamed = GroupCreateAttempt.Inputs(name: "Planning 2", members: ["a", "b"])
        let reseated = GroupCreateAttempt.Inputs(name: "Planning", members: ["a", "c"])
        let renamedID = GroupCreateAttempt.roomID(for: renamed, current: "room-x", attempted: first)
        let reseatedID = GroupCreateAttempt.roomID(for: reseated, current: "room-x", attempted: first)
        XCTAssertNotEqual(renamedID, "room-x")
        XCTAssertNotEqual(reseatedID, "room-x")
        XCTAssertTrue(renamedID.hasPrefix("conduit-"))
    }

    // MARK: - Desktop-synced group chats

    private func desktopRoom(
        name: String,
        roomId: String? = nil,
        revision: Int = 1,
        messages: [[String: Any]] = []
    ) -> [String: Any] {
        var room: [String: Any] = [
            "name": name,
            "log": messages,
            "revision": revision,
            "members": [
                ["name": "Research Buddy", "handle": "research"],
                ["name": "Writer"],
            ],
        ]
        if let roomId { room["roomId"] = roomId }
        return room
    }

    func testDesktopProjectionDecodesRoomsNewestFirst() {
        let snapshot: [String: Any] = [
            "version": 3,
            "rooms": [
                "id:r-old": desktopRoom(name: "Old", roomId: "r-old", messages: [
                    ["id": "m1", "from": ["kind": "user", "name": "You"], "text": "hi", "at": 1_000_000.0],
                ]),
                "id:r-new": desktopRoom(name: "New", roomId: "r-new", messages: [
                    ["id": "m2", "from": ["kind": "user", "name": "You"], "text": "hey @research", "at": 2_000_000.0],
                    ["from": ["kind": "member", "name": "Research Buddy"], "text": "on it",
                     "at": 3_000_000.0, "truncated": true],
                ]),
                "id:broken": ["name": "No log"],
            ],
        ]
        let groups = DesktopGroupChatDecoder.decode(snapshot: any(snapshot))
        XCTAssertEqual(groups.map(\.name), ["New", "Old"])
        let newest = groups[0]
        XCTAssertEqual(newest.key, "id:r-new")
        XCTAssertEqual(newest.members.map(\.name), ["Research Buddy", "Writer"])
        XCTAssertEqual(newest.members.first?.handle, "research")
        XCTAssertEqual(newest.messages.count, 2)
        XCTAssertEqual(newest.messages[0].isMember, false)
        XCTAssertEqual(newest.messages[1].isMember, true)
        XCTAssertEqual(newest.messages[1].speaker, "Research Buddy")
        XCTAssertEqual(newest.messages[1].truncated, true)
        // Milliseconds on the wire, seconds in the model.
        XCTAssertEqual(newest.messages[1].timestamp, 3_000)
        XCTAssertEqual(newest.messages[1].id, "entry-1")
    }

    func testDesktopProjectionHonorsTombstones() {
        let snapshot: [String: Any] = [
            "version": 3,
            "rooms": [
                "id:gone": desktopRoom(name: "Gone", roomId: "gone", revision: 9),
                "name:Legacy": desktopRoom(name: "Legacy", revision: 5),
                "name:Recreated": desktopRoom(name: "Recreated", revision: 7),
            ],
            // id: tombstones are final, whatever the revision; a name:
            // tombstone only hides a room at or below its revision.
            "deleted": ["id:gone": 1, "name:Legacy": 5, "name:Recreated": 6],
        ]
        let groups = DesktopGroupChatDecoder.decode(snapshot: any(snapshot))
        XCTAssertEqual(groups.map(\.name), ["Recreated"])
    }

    func testDesktopProjectionLiftsOlderNameKeyedEnvelopes() {
        let snapshot: [String: Any] = [
            "version": 2,
            "rooms": ["Weekly": desktopRoom(name: "Weekly", revision: 3)],
            "deleted": ["Retired": 1],
        ]
        let groups = DesktopGroupChatDecoder.decode(snapshot: any(snapshot))
        XCTAssertEqual(groups.map(\.key), ["name:Weekly"])
        XCTAssertTrue(DesktopGroupChatDecoder.decode(snapshot: nil).isEmpty)
        XCTAssertTrue(DesktopGroupChatDecoder.decode(snapshot: any(["version": 3])).isEmpty)
    }

    /// The roster answer carries the projection on the `default` profile
    /// only — the same row Desktop publishes to and reads from.
    func testRosterDecodeReadsDesktopGroupsFromTheDefaultProfile() {
        let projection: [String: Any] = [
            "version": 3,
            "rooms": ["id:r1": desktopRoom(name: "From Desktop", roomId: "r1")],
        ]
        let result = any([
            "profiles": [
                ["name": "default", "ui_meta": ["hermes-bots-groups": projection]],
                ["name": "writer", "ui_meta": ["hermes-bots-groups": [
                    "version": 3, "rooms": ["id:x": desktopRoom(name: "Wrong profile", roomId: "x")],
                ]]],
            ],
        ])
        let snapshot = BotRosterDecoder.decode(result)
        XCTAssertEqual(snapshot?.desktopGroups.map(\.name), ["From Desktop"])
        XCTAssertEqual(snapshot?.bots.count, 2)
    }

    func testActorDisplayLabelRoutesByIdentityNeverByBareName() {
        let members = GroupDecoders.room(any(roomPayload()))?.members ?? []
        // actor.id matches member_id → its display label.
        let actor = GroupDecoders.actor(any([
            "kind": "member", "id": "researcher", "profile": "researcher",
            "display_name": "WRONG NAME",
        ]))
        XCTAssertEqual(actor.displayLabel(members: members), "Research Buddy")
        // Unknown member id → profile, then the actor's own display name.
        let stranger = GroupDecoders.actor(any([
            "kind": "member", "id": "ghost", "profile": "ghost",
        ]))
        XCTAssertEqual(stranger.displayLabel(members: members), "ghost")
        // A non-member actor with no labels → empty (rendered as fallback).
        let system = GroupDecoders.actor(any(["kind": "system", "id": "room"]))
        XCTAssertEqual(system.displayLabel(members: members), "")
    }

    func testDriverStatusDecode() {
        let status = GroupDecoders.driverStatus(any([
            "running": true,
            "working": true,
            "blocked": true,
            "counts": ["queued": 2],
            "pending_actions": [["kind": "approval", "task_id": "t1"]],
        ]))
        XCTAssertEqual(status?.running, true)
        XCTAssertEqual(status?.working, true)
        XCTAssertEqual(status?.blocked, true)
        XCTAssertEqual(status?.counts["queued"], 2)
        XCTAssertEqual(status?.pendingActions.first?["task_id"]?.stringValue, "t1")
        XCTAssertNil(GroupDecoders.driverStatus(nil))
    }

    func testPendingApprovalsDecodeOnlyCompleteApprovalRows() {
        let status = GroupDecoders.driverStatus(any([
            "running": true,
            "working": true,
            "blocked": false,
            "pending_actions": [
                ["kind": "retry", "task_id": "t0"],
                [
                    "kind": "approval", "task_id": "t1", "execution_generation": 2,
                    "member_id": "researcher", "request_id": "req-1", "session_id": "s1",
                    "approval": [
                        "command": "rm -rf build", "description": "recursive delete",
                        "choices": ["once", "session", "deny"], "request_id": "req-1",
                    ],
                ],
                // No request id: groups.approve could not name it.
                ["kind": "approval", "task_id": "t2", "execution_generation": 1, "member_id": "writer"],
            ],
        ]))
        let approvals = status?.pendingApprovals ?? []
        XCTAssertEqual(approvals.count, 1)
        let approval = approvals[0]
        XCTAssertEqual(approval.memberID, "researcher")
        XCTAssertEqual(approval.taskID, "t1")
        XCTAssertEqual(approval.executionGeneration, 2)
        XCTAssertEqual(approval.requestID, "req-1")
        XCTAssertEqual(approval.command, "rm -rf build")
        XCTAssertEqual(approval.description, "recursive delete")
        // Rooms answer once or deny only.
        XCTAssertEqual(approval.choices, ["once", "deny"])
        XCTAssertFalse(approval.allows("session"))
    }

    func testPendingApprovalWithoutChoicesOffersRunAndReject() {
        let approval = GroupPendingApproval(action: [
            "kind": AnyCodable.from("approval"),
            "task_id": AnyCodable.from("t1"),
            "execution_generation": AnyCodable.from(1),
            "member_id": AnyCodable.from("researcher"),
            "request_id": AnyCodable.from("req-1"),
        ])
        XCTAssertEqual(approval?.choices, ["once", "deny"])
        XCTAssertEqual(approval?.command, "")
    }

    func testPendingApprovalFallsBackToTheApprovalsOwnRequestID() {
        let approval = GroupPendingApproval(action: [
            "kind": AnyCodable.from("approval"),
            "task_id": AnyCodable.from("t1"),
            "execution_generation": AnyCodable.from(1),
            "member_id": AnyCodable.from("researcher"),
            "approval": AnyCodable.from(["request_id": "req-9", "command": "ls"]),
        ])
        XCTAssertEqual(approval?.requestID, "req-9")
    }

    // MARK: - Replay

    func testReplayInitialHistoryAndCursor() {
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([
            eventJSON(seq: 1, kind: "message.user", payload: ["text": "a", "thread_id": "main"]),
            eventJSON(seq: 2, kind: "message.member",
                      actor: ["kind": "member", "id": "researcher"],
                      payload: ["text": "b", "thread_id": "main"]),
        ]))
        XCTAssertEqual(replay.events.count, 2)
        XCTAssertEqual(replay.cursor, 2)
        XCTAssertEqual(replay.sinceSeq, 2)
        XCTAssertEqual(replay.authorityGatewayID, "gw-a")
        XCTAssertEqual(replay.lastChatMessage?.messageText, "b")
    }

    func testReplayIncrementalPageAppendsWithoutDuplicates() {
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([eventJSON(seq: 1, kind: "message.user", payload: ["text": "a"])]))
        // The next poll replays seq 1 (defensive server retry) and adds 2.
        replay.adopt(page: logPage([
            eventJSON(seq: 1, kind: "message.user", payload: ["text": "a"]),
            eventJSON(seq: 2, kind: "message.user", payload: ["text": "b"]),
        ]))
        XCTAssertEqual(replay.events.map(\.seq), [1, 2])
        XCTAssertEqual(replay.cursor, 2)
    }

    func testReplayOutOfOrderPageIsSorted() {
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([
            eventJSON(seq: 3, kind: "message.user", payload: ["text": "c"]),
            eventJSON(seq: 2, kind: "message.user", payload: ["text": "b"]),
        ]))
        XCTAssertEqual(replay.events.map(\.seq), [2, 3])
        XCTAssertEqual(replay.cursor, 3)
    }

    func testReplayFlagsGapButStillAdoptsContiguousPrefixSemantics() {
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([eventJSON(seq: 1, kind: "message.user", payload: ["text": "a"])]))
        replay.adopt(page: logPage([eventJSON(seq: 5, kind: "message.user", payload: ["text": "e"])]))
        XCTAssertEqual(replay.hasGap, true)
        XCTAssertEqual(replay.events.map(\.seq), [1, 5])
        XCTAssertEqual(replay.cursor, 5)
    }

    func testContiguousMultiEventDeltaIsNotAGap() {
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([eventJSON(seq: 1, kind: "message.user", payload: ["text": "a"])]))
        let delta = logPage([
            eventJSON(seq: 1, kind: "message.user", payload: ["text": "a"]),
            eventJSON(seq: 3, kind: "message.user", payload: ["text": "c"]),
            eventJSON(seq: 2, kind: "message.user", payload: ["text": "b"]),
        ])
        XCTAssertFalse(replay.pageSkipsAhead(delta))
        XCTAssertFalse(replay.pageSkipsAhead(logPage([])))
        XCTAssertTrue(replay.pageSkipsAhead(logPage([
            eventJSON(seq: 3, kind: "message.user", payload: ["text": "c"]),
        ])))
        XCTAssertTrue(replay.pageSkipsAhead(logPage([
            eventJSON(seq: 2, kind: "message.user", payload: ["text": "b"]),
            eventJSON(seq: 4, kind: "message.user", payload: ["text": "d"]),
        ])))
        // Another room's events never count toward this room's sequence.
        XCTAssertFalse(replay.pageSkipsAhead(logPage([
            eventJSON(roomID: "room-2", seq: 9, kind: "message.user", payload: ["text": "x"]),
        ])))
    }

    func testReplayRefusesForeignRoomEvents() {
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([
            eventJSON(roomID: "room-OTHER", seq: 1, kind: "message.user", payload: ["text": "x"])
        ]))
        XCTAssertTrue(replay.events.isEmpty)
        XCTAssertEqual(replay.cursor, 0)
    }

    func testReplayResyncReplacesStateAndClearsGap() {
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([eventJSON(seq: 1, kind: "message.user", payload: ["text": "a"])]))
        replay.adopt(page: logPage([eventJSON(seq: 9, kind: "message.user", payload: ["text": "e"])]))
        XCTAssertEqual(replay.hasGap, true)
        replay.replaceAll(page: logPage([
            eventJSON(seq: 1, kind: "message.user", payload: ["text": "a"]),
            eventJSON(seq: 2, kind: "message.user", payload: ["text": "b"]),
        ]))
        XCTAssertEqual(replay.hasGap, false)
        XCTAssertEqual(replay.events.map(\.seq), [1, 2])
        XCTAssertEqual(replay.cursor, 2)

        // A bounded authoritative tail that starts past the old cursor is
        // the new truth, not a gap.
        replay.replaceAll(page: logPage([
            eventJSON(seq: 40, kind: "message.user", payload: ["text": "x"]),
            eventJSON(seq: 41, kind: "message.user", payload: ["text": "y"]),
        ]))
        XCTAssertEqual(replay.hasGap, false)
        XCTAssertEqual(replay.events.map(\.seq), [40, 41])
        XCTAssertEqual(replay.cursor, 41)
    }

    func testInitialTailAdoptionDoesNotFlagTheWindowTruncationAsAGap() {
        // A room with 500 events opens on a bounded last-200 tail: events
        // 301...500. The truncation is by design — never a gap.
        var replay = GroupRoomReplay(roomID: "room-1")
        let events = (301...500).map { seq in
            eventJSON(seq: seq, kind: "message.user", payload: ["text": "m\(seq)", "thread_id": "main"])
        }
        replay.adoptInitialTail(page: logPage(events, latest: 500))
        XCTAssertEqual(replay.hasGap, false)
        XCTAssertEqual(replay.events.count, 200)
        XCTAssertEqual(replay.events.first?.seq, 301)
        XCTAssertEqual(replay.cursor, 500)
        XCTAssertEqual(replay.sinceSeq, 500)
    }

    func testPollingTrimsTheReplayBackToTheTailWindow() {
        // A busy open room: polling past the retained limit drops the
        // oldest events back to the tail window, and the cursor still
        // refuses anything already seen.
        var replay = GroupRoomReplay(roomID: "room-1")
        let limit = GroupRoomReplay.retainedLimit
        replay.adopt(page: logPage((1...limit).map { seq in
            eventJSON(seq: seq, kind: "message.user", payload: ["text": "m\(seq)"])
        }))
        XCTAssertEqual(replay.events.count, limit)

        replay.adopt(page: logPage([
            eventJSON(seq: limit + 1, kind: "message.user", payload: ["text": "new"]),
        ]))
        XCTAssertEqual(replay.events.count, GroupRoomReplay.tailWindow)
        XCTAssertEqual(replay.events.last?.seq, limit + 1)
        XCTAssertEqual(replay.events.first?.seq, limit + 2 - GroupRoomReplay.tailWindow)
        XCTAssertEqual(replay.cursor, limit + 1)

        replay.adopt(page: logPage([
            eventJSON(seq: 1, kind: "message.user", payload: ["text": "old"]),
        ]))
        XCTAssertEqual(replay.events.count, GroupRoomReplay.tailWindow)
        XCTAssertEqual(replay.hasGap, false)
    }

    func testANewMemberMessageIsWhereTheRoomLands() {
        let log = [
            userMessage(seq: 1, text: "Hello everyone"),
            memberMessage(seq: 2, member: "ayaka", round: 0, text: "Hi"),
            userMessage(seq: 3, text: "Plan the trip", id: "user:d2"),
            memberMessage(seq: 4, member: "zhongli", round: 0, text: "A long plan"),
            memberMessage(seq: 5, member: "ayaka", round: 0, text: "More"),
        ]
        // The first member message after the row that was last before.
        XCTAssertEqual(GroupRoomTranscript.replyStart(in: log, after: "dmessage:2"), "dmessage:4")
        XCTAssertEqual(GroupRoomTranscript.replyStart(in: log, after: "dmessage:4"), "dmessage:5")
        // Only the user's own message is new, or nothing is: the bottom.
        XCTAssertNil(GroupRoomTranscript.replyStart(in: Array(log.prefix(3)), after: "dmessage:2"))
        XCTAssertNil(GroupRoomTranscript.replyStart(in: log, after: "dmessage:5"))
        // No row from before (the room just opened, or it's gone): the bottom.
        XCTAssertNil(GroupRoomTranscript.replyStart(in: log, after: nil))
        XCTAssertNil(GroupRoomTranscript.replyStart(in: log, after: "dmessage:99"))
    }

    /// The room's transcript rows (#1533): its events, the message on its
    /// way under the id its event will have, the member responding, or the
    /// empty room's welcome.
    func testRoomTranscriptRowsKeepTheMessageOnItsWayUnderItsEventsID() {
        let members = roomMembers()
        let log = [
            userMessage(seq: 1, text: "Hello everyone"),
            memberMessage(seq: 2, member: "furina", round: 0, text: "Hi"),
            memberMessage(seq: 3, member: "furina", round: 0, text: "Again"),
            memberMessage(seq: 4, member: "zhongli", round: 0, text: "Greetings"),
        ]
        // The id the client mints, and the one the gateway files it under.
        let pending = GroupRoomOutbox.Pending(text: "Plan the trip", eventID: "conduit-abc")
        let landedID = GroupRoomOutbox.serverEventID(forClientEventID: "conduit-abc")
        let rows = GroupRoomTranscript.rows(
            events: log, roomID: "room-1", members: members,
            pending: pending, isSending: true, responder: members[1]
        )
        XCTAssertEqual(
            rows.map(\.id),
            ["user:d1", "dmessage:2", "dmessage:3", "dmessage:4", landedID, GroupRoomTranscript.respondingID]
        )
        // A member's run shows its picture and name once.
        guard case .room(.event(_, _, let runContinues, _)) = rows[2].kind,
              case .room(.event(_, _, let otherContinues, _)) = rows[3].kind else { return XCTFail("\(rows)") }
        XCTAssertTrue(runContinues)
        XCTAssertFalse(otherContinues)
        XCTAssertEqual(rows[4].kind, .room(.pending(text: "Plan the trip", members: members, isSending: true)))

        // The send landed while its row still shows: the event's row, once.
        let landed = GroupRoomTranscript.rows(
            events: log + [userMessage(seq: 5, text: "Plan the trip", id: landedID)], roomID: "room-1",
            members: members, pending: pending, isSending: false, responder: nil
        )
        XCTAssertEqual(landed.map(\.id), ["user:d1", "dmessage:2", "dmessage:3", "dmessage:4", landedID])
        guard case .room(.event(_, _, _, _)) = landed[4].kind else { return XCTFail("the event's row, not the pending one") }

        // Nothing in the room yet: its welcome.
        let empty = GroupRoomTranscript.rows(
            events: [], roomID: "room-1", members: members, pending: nil, isSending: false, responder: nil
        )
        XCTAssertEqual(empty.map(\.kind), [.room(.empty(roomID: "room-1", members: members))])
    }

    /// GroupChatView's rows box (#1533) tells the room's scroller of new
    /// events as it builds their rows: a new member message arms the stop
    /// at its start, a member starting its turn is followed to the end, and
    /// a room that didn't change builds nothing. What the log adds without
    /// a row, and the oldest row going, leave the stop where it is.
    @MainActor
    func testTheRoomBoxTellsTheScrollerOfANewMemberMessage() {
        let scroller = TranscriptScroller()
        scroller.holdsRepliesAtStart = { true }
        let box = GroupRoomTranscriptBox()
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([eventJSON(seq: 1, kind: "message.user", payload: ["text": "Hello"])]))
        var input = GroupRoomTranscriptBox.Input(replay: replay, members: roomMembers())
        XCTAssertEqual(box.update(input, scroller: scroller).map(\.id), ["e1"])
        XCTAssertFalse(scroller.replyHoldArmed, "the room's first events are its history")

        let memberHi = eventJSON(
            seq: 2, kind: "message.member",
            actor: ["kind": "member", "id": "furina", "profile": "furina"],
            payload: ["text": "Hi", "member_id": "furina"]
        )
        replay.adopt(page: logPage([memberHi]))
        input.replay = replay
        let rows = box.update(input, scroller: scroller)
        XCTAssertEqual(rows.map(\.id), ["e1", "e2"])
        XCTAssertTrue(scroller.replyHoldArmed, "a new member message is where the room stops")
        let same = box.update(input, scroller: scroller)
        XCTAssertTrue(rows.withUnsafeBufferPointer { built in
            same.withUnsafeBufferPointer { built.baseAddress == $0.baseAddress }
        }, "the rows it built, not new ones")

        replay.adopt(page: logPage([eventJSON(
            seq: 3, kind: "turn.heartbeat", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["member_id": "furina"]
        )]))
        input.replay = replay
        XCTAssertEqual(box.update(input, scroller: scroller).map(\.id), ["e1", "e2"])
        XCTAssertTrue(scroller.replyHoldArmed, "the log's bookkeeping adds no row and moves nothing")
        var trimmed = GroupRoomReplay(roomID: "room-1")
        trimmed.adoptInitialTail(page: logPage([memberHi]))
        input.replay = trimmed
        XCTAssertEqual(box.update(input, scroller: scroller).map(\.id), ["e2"])
        XCTAssertTrue(scroller.replyHoldArmed, "the oldest row going adds nothing at the end")

        input.responder = roomMembers()[1]
        XCTAssertEqual(box.update(input, scroller: scroller).map(\.id), ["e2", GroupRoomTranscript.respondingID])
        XCTAssertFalse(scroller.replyHoldArmed, "a member starting its turn is followed to the end")
    }

    func testSendResultAdoptionAdvancesCursorExactlyOnce() {
        // The accepted `groups.send` event rides the same engine: the poll
        // that later returns it must not duplicate it.
        var replay = GroupRoomReplay(roomID: "room-1")
        replay.adopt(page: logPage([eventJSON(seq: 1, kind: "message.user", payload: ["text": "a"])]))
        let accepted = logPage([eventJSON(seq: 2, kind: "message.user", payload: ["text": "mine"])])
        replay.adopt(page: accepted)
        replay.adopt(page: accepted)
        XCTAssertEqual(replay.events.map(\.seq), [1, 2])
    }

    // MARK: - Send outbox

    func testOutboxMintsOnceAndReusesOnRetry() {
        var outbox = GroupRoomOutbox()
        var mintCount = 0
        let first = outbox.beginSend(text: "hello") {
            mintCount += 1
            return "conduit-abc"
        }
        XCTAssertEqual(first.eventID, "conduit-abc")
        // A retry (still pending) reuses the SAME id and never mints again.
        let retry = outbox.beginSend(text: "hello") {
            mintCount += 1
            return "conduit-never"
        }
        XCTAssertEqual(retry.eventID, "conduit-abc")
        XCTAssertEqual(mintCount, 1)
        XCTAssertTrue(outbox.pending != nil)
    }

    func testOutboxAcceptsOnlyThePendingIDThenFreesIt() {
        var outbox = GroupRoomOutbox()
        _ = outbox.beginSend(text: "hello") { "conduit-abc" }
        outbox.accept(eventID: "conduit-other")
        XCTAssertTrue(outbox.pending != nil)
        outbox.accept(eventID: "conduit-abc")
        XCTAssertTrue(outbox.pending == nil)
        // A fresh message mints fresh.
        let next = outbox.beginSend(text: "again") { "conduit-def" }
        XCTAssertEqual(next.eventID, "conduit-def")
    }

    func testOutboxSettlesFromTheGatewaysServerSideEventID() {
        // Upstream `user_event_id`: "user:" + sha256 hex of the client id.
        XCTAssertEqual(
            GroupRoomOutbox.serverEventID(forClientEventID: "conduit-abc"),
            "user:af2b48a15035625368f5e79d8610b31e83a85c6d853a55440f3b636d26698de6"
        )
        var outbox = GroupRoomOutbox()
        _ = outbox.beginSend(text: "hello") { "conduit-abc" }
        let other = logPage([eventJSON(seq: 1, kind: "message.user", payload: ["text": "hello"],
                                       eventID: "user:someone-else")])
        XCTAssertFalse(outbox.settle(from: other.events))
        XCTAssertNotNil(outbox.pending)
        let landed = logPage([eventJSON(
            seq: 2, kind: "message.user", payload: ["text": "hello"],
            eventID: GroupRoomOutbox.serverEventID(forClientEventID: "conduit-abc")
        )])
        XCTAssertTrue(outbox.settle(from: landed.events))
        XCTAssertNil(outbox.pending)
    }

    // MARK: - Room mention classification

    func testLeadingPunctuationTokensAreRejectedByTheMentionCharset() {
        // Upstream's charset is ^[a-z0-9][a-z0-9_-]*$ — a handle can never
        // start with - or _ (the gateway's roster validator would refuse or
        // route it differently).
        XCTAssertFalse(BotMentions.isValidMentionToken("-x"))
        XCTAssertFalse(BotMentions.isValidMentionToken("_admin"))
        XCTAssertEqual(BotMentions.mentionNameForms("_admin"), [])
        XCTAssertTrue(BotMentions.isValidMentionToken("a_b-c9"))
        // Case folds: a profile-cased fallback handle is still legal.
        XCTAssertTrue(BotMentions.isValidMentionToken("Researcher"))
    }

    func testRoomMentionClassification() {
        let researcher = GroupDecoders.member(any([
            "member_id": "researcher", "profile": "researcher",
            "handle": "research-buddy", "display_name": "Research Buddy",
        ]))!
        let members = [researcher]
        XCTAssertEqual(GroupRoomMentions.classify(token: "research-buddy", members: members), .agent)
        XCTAssertEqual(GroupRoomMentions.classify(token: "RESEARCH-BUDDY", members: members), .agent)
        XCTAssertEqual(GroupRoomMentions.classify(token: "all", members: members), .broadcast)
        XCTAssertEqual(GroupRoomMentions.classify(token: "everyone", members: members), .broadcast)
        XCTAssertEqual(GroupRoomMentions.classify(token: "user", members: members), .human)
        XCTAssertNil(GroupRoomMentions.classify(token: "nobody", members: members))
        // E-mail-ish tokens classify as nothing (plain prose), matching the
        // driver's routing which also ignores them.
        XCTAssertNil(GroupRoomMentions.classify(token: "example.com", members: members))
    }

    func testRoomMentionsLinkForMarkdownOutsideCode() {
        let researcher = GroupDecoders.member(any([
            "member_id": "researcher", "profile": "researcher",
            "handle": "research-buddy", "display_name": "Research Buddy",
        ]))!
        let members = [researcher]
        XCTAssertEqual(
            GroupRoomMentions.linkingMarkdown("ask @research-buddy and @all, not @nobody", members: members),
            "ask [@research-buddy](conduit-mention://agent) and [@all](conduit-mention://broadcast), not @nobody"
        )
        // Inline code and fenced blocks keep their tags as written.
        XCTAssertEqual(
            GroupRoomMentions.linkingMarkdown("run `@all` then @user", members: members),
            "run `@all` then [@user](conduit-mention://human)"
        )
        let fenced = "```\n@all\n```\n@all"
        XCTAssertEqual(
            GroupRoomMentions.linkingMarkdown(fenced, members: members),
            "```\n@all\n```\n[@all](conduit-mention://broadcast)"
        )
        // A ```` block's ``` line is code, as MarkdownText draws it.
        XCTAssertEqual(
            GroupRoomMentions.linkingMarkdown("````md\n```\n@all\n````\n@all", members: members),
            "````md\n```\n@all\n````\n[@all](conduit-mention://broadcast)"
        )
        // A link's label can't hold another link, and a quoted fence is a fence.
        XCTAssertEqual(
            GroupRoomMentions.linkingMarkdown("see [the @all notes](https://example.com) @all", members: members),
            "see [the @all notes](https://example.com) [@all](conduit-mention://broadcast)"
        )
        XCTAssertEqual(
            GroupRoomMentions.linkingMarkdown("> ```\n> @all\n> ```\n@user", members: members),
            "> ```\n> @all\n> ```\n[@user](conduit-mention://human)"
        )
        XCTAssertEqual(
            GroupRoomMentions.kind(ofLink: URL(string: "conduit-mention://agent")!), .agent
        )
        XCTAssertNil(GroupRoomMentions.kind(ofLink: URL(string: "https://agent")!))
    }

    func testAgentMentionLinksCarryTheBotsColor() throws {
        let scout = GroupDecoders.member(any(["member_id": "scout", "profile": "scout", "handle": "scout"]))!
        let tint = CustomAccentColor(red: 0.2, green: 0.4, blue: 0.8)
        let linked = GroupRoomMentions.linkingMarkdown("hi @scout and @all", members: [scout], tints: ["scout": tint])
        XCTAssertEqual(
            linked,
            "hi [@scout](conduit-mention://agent?c=\(tint.hex.dropFirst())) and [@all](conduit-mention://broadcast)"
        )
        let url = try XCTUnwrap(URL(string: "conduit-mention://agent?c=\(tint.hex.dropFirst())"))
        XCTAssertEqual(GroupRoomMentions.kind(ofLink: url), .agent)
        XCTAssertEqual(GroupRoomMentions.tint(ofLink: url), tint)
        XCTAssertNil(GroupRoomMentions.tint(ofLink: URL(string: "conduit-mention://broadcast")!))
    }

    func testRoomMembersTakeTheirBotsCurrentNames() {
        let furina = GroupDecoders.member(any([
            "member_id": "m1", "profile": "furina", "handle": "furina", "display_name": "Furina",
        ]))!
        let peer = GroupDecoders.member(any([
            "member_id": "m2", "profile": "furina", "handle": "remote", "display_name": "Remote Furina",
            "target": ["kind": "peer"],
        ]))!
        let stranger = GroupDecoders.member(any(["member_id": "m3", "profile": "zhongli", "display_name": "zhongli"]))!
        var bot = BotProfile(
            name: "furina", botTitle: "Focalors", displayName: "Furina", profileDescription: "",
            model: nil, provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false,
            appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil
        )
        bot.previousNames = []
        let named = GroupRoomTurns.members([furina, peer, stranger], namedBy: [bot])
        XCTAssertEqual(named.map(GroupRoomTurns.displayName(of:)), ["Focalors", "Remote Furina", "zhongli"])
        // Identity and routing are untouched; the old name stays known.
        XCTAssertEqual(named[0].identityKey, furina.identityKey)
        XCTAssertEqual(named[0].handle, "furina")
        XCTAssertEqual(named[0].previousNames, ["Furina"])
        XCTAssertEqual(GroupRoomTurns.members([furina], namedBy: []), [furina])
    }

    func testAMembersFilesAreReadFromItsOwnLocalProfile() {
        let local = GroupDecoders.member(any(["member_id": "m1", "profile": " furina ", "handle": "furina"]))
        let explicit = GroupDecoders.member(any(["member_id": "m2", "profile": "nahida", "target": ["kind": "local"]]))
        let peer = GroupDecoders.member(any(["member_id": "m3", "profile": "furina", "target": ["kind": "peer"]]))
        let noProfile = GroupDecoders.member(any(["member_id": "m4", "handle": "raiden"]))
        XCTAssertEqual(GroupRoomTurns.localProfile(of: local), "furina")
        XCTAssertEqual(GroupRoomTurns.localProfile(of: explicit), "nahida")
        XCTAssertNil(GroupRoomTurns.localProfile(of: peer), "another gateway's bot names files on its own host")
        XCTAssertNil(GroupRoomTurns.localProfile(of: noProfile))
        XCTAssertNil(GroupRoomTurns.localProfile(of: nil))
    }

    func testAMessagesSpeakerIsFoundByItsActorWithoutAMemberID() throws {
        let furina = try XCTUnwrap(GroupDecoders.member(any(["member_id": "m1", "profile": "furina", "handle": "furina"])))
        let message = GroupEvent(
            roomID: "room", seq: 1, eventID: "e1", kind: "message.member",
            actor: GroupActor(kind: "member", id: "furina", profile: "furina", displayName: "Furina", connectionID: nil),
            authorityEpoch: nil, payload: ["text": .string("Hi")], createdAt: 0
        )
        XCTAssertEqual(GroupRoomTurns.speaker(of: message, members: [furina])?.memberID, "m1")
        let user = GroupEvent(
            roomID: "room", seq: 2, eventID: "e2", kind: "message.user",
            actor: GroupActor(kind: "user", id: "furina", profile: nil, displayName: nil, connectionID: nil),
            authorityEpoch: nil, payload: ["text": .string("Hi")], createdAt: 0
        )
        XCTAssertNil(GroupRoomTurns.speaker(of: user, members: [furina]), "only a member's actor names a member")
        let peer = try XCTUnwrap(GroupDecoders.member(any(["member_id": "m2", "profile": "furina", "target": ["kind": "peer"]])))
        XCTAssertNil(GroupRoomTurns.speaker(of: message, members: [furina, peer]),
                     "a profile two members share names neither")
        let unnamed = try XCTUnwrap(GroupDecoders.member(any(["profile": "furina", "handle": "furina"])))
        XCTAssertNil(GroupRoomTurns.speaker(of: message, members: [unnamed, peer]),
                     "a member without a member id doesn't take a shared profile as its own id")
        let named = GroupEvent(
            roomID: "room", seq: 3, eventID: "e3", kind: "message.member",
            actor: GroupActor(kind: "member", id: "furina", profile: "furina", displayName: "Furina", connectionID: nil),
            authorityEpoch: nil, payload: ["text": .string("Hi"), "member_id": .string("gone")], createdAt: 0
        )
        XCTAssertNil(GroupRoomTurns.speaker(of: named, members: [furina]),
                     "a payload naming a member the room no longer lists isn't matched by its actor instead")
    }

    func testRecipientsLeadTheMessageOnce() {
        let scout = GroupDecoders.member(any(["member_id": "scout", "profile": "scout", "handle": "scout"]))!
        let atlas = GroupDecoders.member(any(["member_id": "atlas", "profile": "atlas", "handle": "atlas"]))!
        let members = [scout, atlas]
        XCTAssertEqual(
            GroupRoomRecipients.addressing("what now?", to: ["atlas", "scout"], members: members),
            "@atlas @scout what now?"
        )
        // A tag already typed isn't repeated; nothing picked leaves the text.
        XCTAssertEqual(
            GroupRoomRecipients.addressing("@scout what now?", to: ["scout", "atlas", "ATLAS"], members: members),
            "@atlas @scout what now?"
        )
        XCTAssertEqual(GroupRoomRecipients.addressing("hi", to: [], members: members), "hi")
        // Files sent alone still go only to the picked bots.
        XCTAssertEqual(GroupRoomRecipients.addressing("", to: ["scout"], members: members), "@scout")
        // A bot that left since it was picked is dropped, not tagged.
        XCTAssertEqual(GroupRoomRecipients.addressing("hi", to: ["gone", "atlas"], members: members), "@atlas hi")
        XCTAssertEqual(GroupRoomRecipients.addressing("hi", to: ["gone"], members: members), "hi")
        let routed = GroupRoomTurns.resolveMentions(
            in: [GroupRoomRecipients.addressing("hi", to: ["atlas"], members: members)],
            members: members,
            defaultAll: true
        )
        XCTAssertEqual(routed, [atlas])
        // Members without a tag, or reusing a reserved one, can't be picked.
        let untagged = GroupDecoders.member(any(["member_id": "x", "profile": "x"]))!
        let reserved = GroupDecoders.member(any(["member_id": "y", "profile": "y", "handle": "all"]))!
        XCTAssertEqual(GroupRoomRecipients.pickable([scout, untagged, reserved, atlas]), [scout, atlas])
    }

    func testDefangedTagsNoLongerRoute() {
        let researcher = GroupDecoders.member(any([
            "member_id": "researcher", "profile": "researcher", "handle": "scout",
        ]))!
        let defanged = GroupRoomMentions.defanged("@scout and @all, mail a@b.c")
        XCTAssertEqual(GroupRoomTurns.resolveMentions(in: [defanged], members: [researcher], defaultAll: false), [])
        XCTAssertEqual(GroupRoomMentions.refanged(defanged), "@scout and @all, mail a@b.c")
    }

    func testRoomReplyQuoteRoundTripsWithoutAddressingTheQuote() {
        let scout = GroupDecoders.member(any([
            "member_id": "scout", "profile": "scout", "handle": "scout",
        ]))!
        let atlas = GroupDecoders.member(any([
            "member_id": "atlas", "profile": "atlas", "handle": "atlas",
        ]))!
        let sent = GroupRoomReplyQuote.outboundText(
            quoting: "I think @atlas knows.\nSecond line",
            author: "Scout",
            message: "@scout why?"
        )
        XCTAssertTrue(sent.hasPrefix("[Replying to Scout]\n> I think @"))
        // Only the user's own words address anyone.
        XCTAssertEqual(GroupRoomTurns.resolveMentions(in: [sent], members: [scout, atlas], defaultAll: false), [scout])
        let parsed = GroupRoomReplyQuote.parse(sent)
        XCTAssertEqual(parsed?.author, "Scout")
        XCTAssertEqual(parsed?.quote, "I think @atlas knows.\nSecond line")
        XCTAssertEqual(parsed?.message, "@scout why?")
        XCTAssertNil(GroupRoomReplyQuote.parse("[Replying to Scout] no quote"))
        XCTAssertNil(GroupRoomReplyQuote.parse("plain message"))
    }

    func testRoomMentionScanNeedsALeadingBoundary() throws {
        let regex = try XCTUnwrap(GroupRoomMentions.mentionScanRegex)
        func tokens(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        XCTAssertEqual(tokens("@all hi @user\n@scout"), ["all", "user", "scout"])
        XCTAssertEqual(tokens("a@all x@user name@example.com"), [])
    }

    func testRoomMentionClassificationCoversRenamedAndTitleFirstWordForms() {
        let renamed = GroupDecoders.member(any([
            "member_id": "researcher",
            "profile": "researcher",
            "handle": "researcher",
            "display_name": "Research Buddy",
            "previous_names": ["scout"],
        ]))!
        XCTAssertEqual(GroupRoomMentions.classify(token: "scout", members: [renamed]), .agent)

        // The title's first word styles upstream ("Research Buddy" → @research).
        XCTAssertEqual(GroupRoomMentions.classify(token: "research", members: [renamed]), .agent)

        // But reserved tokens are never shadowed by a member's names: a bot
        // titled "User Guide" cannot claim @user (the human handoff).
        let titled = GroupDecoders.member(any([
            "member_id": "guide", "profile": "guide",
            "handle": "guide", "display_name": "User Guide",
        ]))!
        XCTAssertEqual(GroupRoomMentions.classify(token: "user", members: [titled]), .human)
        XCTAssertEqual(GroupRoomMentions.classify(token: "user-guide", members: [titled]), .agent)
    }

    // MARK: - Room turns

    private func roomMembers() -> [GroupMember] {
        [
            GroupDecoders.member(any([
                "member_id": "furina", "profile": "furina", "handle": "furina", "display_name": "Furina",
            ]))!,
            GroupDecoders.member(any([
                "member_id": "zhongli", "profile": "zhongli", "handle": "zhongli", "display_name": "Zhongli",
            ]))!,
        ]
    }

    private func turnEvent(_ json: [String: Any]) -> GroupEvent {
        GroupDecoders.event(any(json))!
    }

    private func userMessage(seq: Int, text: String, id: String = "user:d1") -> GroupEvent {
        turnEvent(eventJSON(seq: seq, kind: "message.user", payload: ["text": text, "thread_id": "main"], eventID: id))
    }

    private func memberMessage(seq: Int, member: String, round: Int, text: String) -> GroupEvent {
        turnEvent(eventJSON(
            seq: seq, kind: "message.member",
            actor: ["kind": "member", "id": member, "profile": member],
            payload: [
                "text": text, "thread_id": "main", "discussion_event_id": "user:d1",
                "member_id": member, "round_index": round,
            ],
            eventID: "dmessage:\(seq)"
        ))
    }

    private func settled(seq: Int, member: String, round: Int, messageSeq: Int?) -> GroupEvent {
        turnEvent(eventJSON(
            seq: seq, kind: "turn.settled",
            actor: ["kind": "gateway", "id": "gw-a"],
            payload: [
                "thread_id": "main", "discussion_event_id": "user:d1", "member_id": member,
                "round_index": round, "passed": messageSeq == nil,
                "message_event_id": messageSeq.map { "dmessage:\($0)" as Any } ?? NSNull(),
            ]
        ))
    }

    func testPendingResponderFollowsTheDiscussionRounds() {
        let members = roomMembers()
        var log = [userMessage(seq: 1, text: "Hello everyone")]
        func responder() -> String? {
            GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID
        }
        // No mention means everyone, in roster order.
        XCTAssertEqual(responder(), "furina")

        log += [memberMessage(seq: 2, member: "furina", round: 0, text: "@zhongli, attend!"),
                settled(seq: 3, member: "furina", round: 0, messageSeq: 2)]
        XCTAssertEqual(responder(), "zhongli", "Furina's settled turn is not the room settling")

        // Zhongli cites Furina, who has not spoken since: she gets round 1.
        log += [memberMessage(seq: 4, member: "zhongli", round: 0, text: "@furina, verified."),
                settled(seq: 5, member: "zhongli", round: 0, messageSeq: 4)]
        XCTAssertEqual(responder(), "furina")

        // She passes, and nobody spoke in round 1: nothing left to run.
        log.append(settled(seq: 6, member: "furina", round: 1, messageSeq: nil))
        XCTAssertNil(responder())
    }

    func testPendingResponderHonorsMentionsAndRoomCompletion() {
        let members = roomMembers()
        let log = [userMessage(seq: 1, text: "@zhongli what do you think?")]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "zhongli")

        let done = log + [turnEvent(eventJSON(
            seq: 2, kind: "room.activity", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["status": "settled", "reason_code": "silent_round", "thread_id": "main",
                      "discussion_event_id": "user:d1"]
        ))]
        XCTAssertNil(GroupRoomTurns.pendingResponder(events: done, members: members))

        let stopped = log + [turnEvent(eventJSON(
            seq: 2, kind: "room.stop_requested", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["cancel_id": "c1"]
        ))]
        XCTAssertNil(GroupRoomTurns.pendingResponder(events: stopped, members: members))
    }

    // MARK: - Routing and Continue (Hermes 0.23)

    private let gateway: [String: Any] = ["kind": "gateway", "id": "gw-a"]

    private func contextSet(seq: Int, routing: String, lead: String = "") -> GroupEvent {
        turnEvent(eventJSON(
            seq: seq, kind: "room.context_set", actor: ["kind": "system", "id": "room-control"],
            payload: ["purpose": "", "notes": "", "routing": routing, "lead_member_id": lead]
        ))
    }

    private func roomEvent(seq: Int, kind: String, _ payload: [String: Any]) -> GroupEvent {
        turnEvent(eventJSON(seq: seq, kind: kind, actor: gateway, payload: payload))
    }

    func testALeadRoomWaitsOnTheLeadThenItsPick() {
        let members = roomMembers()
        var log = [contextSet(seq: 1, routing: "lead", lead: "zhongli"), userMessage(seq: 2, text: "Plan the trip")]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "zhongli")
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: log, members: members), .leadChoosing(members[1]))

        // The routing turn ends and the lead gave it to Furina alone.
        log += [
            roomEvent(seq: 3, kind: "room.assignment", [
                "discussion_event_id": "user:d1", "thread_id": "main", "task_id": "route-task",
                "lead_member_id": "zhongli", "member_ids": ["furina"], "fallback": false,
            ]),
            roomEvent(seq: 4, kind: "turn.settled", [
                "thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli",
                "round_index": 0, "passed": true, "task_id": "route-task",
            ]),
        ]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "furina")
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: log, members: members), .routed([members[0]], routingTaskID: "route-task"))

        // A message that names someone skips the lead.
        let named = [contextSet(seq: 1, routing: "lead", lead: "zhongli"), userMessage(seq: 2, text: "@furina hi")]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: named, members: members)?.memberID, "furina")
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: named, members: members), .unrouted)
    }

    func testEachNewThreadIsRoutedAndAReplyInItsThreadIsNot() {
        let members = roomMembers()
        func message(_ seq: Int, _ text: String, thread: String) -> GroupEvent {
            turnEvent(eventJSON(seq: seq, kind: "message.user", payload: ["text": text, "thread_id": thread],
                                eventID: "user:\(thread)-\(seq)"))
        }
        let settled = roomEvent(seq: 3, kind: "room.activity", [
            "status": "settled", "thread_id": "t1", "discussion_event_id": "user:t1-2",
        ])
        // A second message in a thread of its own goes to the lead again.
        let second = [contextSet(seq: 1, routing: "lead", lead: "zhongli"), message(2, "First", thread: "t1"),
                      settled, message(4, "Second", thread: "t2")]
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: second, members: members), .leadChoosing(members[1]))
        // One in the first message's thread is a reply, which goes to everyone.
        let reply = [contextSet(seq: 1, routing: "lead", lead: "zhongli"), message(2, "First", thread: "t1"),
                     settled, message(4, "More", thread: "t1")]
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: reply, members: members), .unrouted)
    }

    func testTheLeadsRoutingTurnIsNotItsAnswer() {
        let members = roomMembers()
        let log = [
            contextSet(seq: 1, routing: "lead", lead: "zhongli"),
            userMessage(seq: 2, text: "Who should take this?"),
            roomEvent(seq: 3, kind: "room.assignment", [
                "discussion_event_id": "user:d1", "thread_id": "main", "task_id": "route-task",
                "lead_member_id": "zhongli", "member_ids": ["zhongli"], "fallback": false,
            ]),
            roomEvent(seq: 4, kind: "turn.settled", [
                "thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli",
                "round_index": 0, "passed": true, "task_id": "route-task",
            ]),
        ]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "zhongli",
                       "a lead that gave the message to itself still answers it")
    }

    func testAnAutomaticRoomWaitsOnTheRouter() {
        let members = roomMembers()
        // Kept events from past the room's start, with no settings change in
        // them: the host's current settings were in force. The message opened
        // its own thread, as Conduit's and Desktop's do.
        let own = GroupRoomOutbox.serverEventID(forClientEventID: "conduit-w")
        func opener(_ seq: Int, _ text: String) -> GroupEvent {
            turnEvent(eventJSON(seq: seq, kind: "message.user", payload: ["text": text, "thread_id": "conduit-w"], eventID: own))
        }
        var log = [opener(101, "What's the weather?")]
        let auto = GroupRoomContext(routing: .auto)
        XCTAssertNil(GroupRoomTurns.pendingResponder(events: log, members: members, context: auto))
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: log, members: members, context: auto), .routerChoosing)

        log.append(roomEvent(seq: 102, kind: "room.routed", [
            "discussion_event_id": own, "thread_id": "conduit-w", "member_ids": ["zhongli"],
            "everyone": false, "fallback": false,
        ]))
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members, context: auto)?.memberID, "zhongli")

        let fallback = [opener(101, "Hi"), roomEvent(seq: 102, kind: "room.routed", [
            "discussion_event_id": own, "thread_id": "conduit-w", "member_ids": [String](),
            "everyone": true, "fallback": true,
        ])]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: fallback, members: members, context: auto)?.memberID, "furina")

        // A context event in the log wins over the host's current settings.
        let everyone = [contextSet(seq: 1, routing: "everyone"), userMessage(seq: 2, text: "Hi")]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: everyone, members: members, context: auto)?.memberID, "furina")
    }

    func testContinueReopensADiscussionPausedAtItsCap() {
        let members = roomMembers()
        var log = [
            userMessage(seq: 1, text: "Debate it"),
            memberMessage(seq: 2, member: "furina", round: 0, text: "No."),
            settled(seq: 3, member: "furina", round: 0, messageSeq: 2),
            memberMessage(seq: 4, member: "zhongli", round: 0, text: "Yes."),
            settled(seq: 5, member: "zhongli", round: 0, messageSeq: 4),
            roomEvent(seq: 6, kind: "room.activity", [
                "status": "bounded", "reason_code": "max_rounds", "thread_id": "main", "discussion_event_id": "user:d1",
            ]),
        ]
        XCTAssertNil(GroupRoomTurns.pendingResponder(events: log, members: members))
        XCTAssertEqual(GroupRoomTurns.continuablePauses(events: log)["e6"]?.discussionEventID, "user:d1")
        XCTAssertEqual(GroupRoomTurns.continuablePauses(events: log)["e6"]?.grant, 1)

        // Continue: the whole room picks it back up in the next round.
        log.append(roomEvent(seq: 7, kind: "room.continued", [
            "discussion_event_id": "user:d1", "thread_id": "main", "grant": 1,
        ]))
        XCTAssertTrue(GroupRoomTurns.continuablePauses(events: log).isEmpty)
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "zhongli",
                       "round 1 rotates the roster")

        // A Stop after the discussion's message ends the pause.
        let stopped = Array(log.prefix(6)) + [roomEvent(seq: 7, kind: "room.stop_requested", ["cancel_id": "c1"])]
        XCTAssertTrue(GroupRoomTurns.continuablePauses(events: stopped).isEmpty)

        // Paused again after its first Continue: the next one is the second grant.
        let again = log + [roomEvent(seq: 8, kind: "room.activity", [
            "status": "bounded", "reason_code": "max_rounds", "thread_id": "main", "discussion_event_id": "user:d1",
        ])]
        XCTAssertEqual(GroupRoomTurns.continuablePauses(events: again)["e8"]?.grant, 2)

        // A newer message in the thread ends a pause.
        let moved = Array(log.prefix(6)) + [userMessage(seq: 7, text: "Next topic", id: "user:d2")]
        XCTAssertTrue(GroupRoomTurns.continuablePauses(events: moved).isEmpty)
    }

    func testALeadWhoseRoutingTurnEndsWithoutAPickAnswersItself() {
        let members = roomMembers()
        // The routing turn reads up to just before the message (seq 2), so
        // its receipt says seen through 1; Desktop's Discard cancels it.
        let log = [
            contextSet(seq: 1, routing: "lead", lead: "zhongli"),
            userMessage(seq: 2, text: "Plan the trip"),
            roomEvent(seq: 3, kind: "turn.cancelled", [
                "thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli",
                "round_index": 0, "seen_through_seq": 1, "task_id": "route-task", "reason": "discarded",
            ]),
        ]
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: log, members: members),
                       .routed([members[1]], routingTaskID: "route-task"))
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "zhongli",
                       "the lead takes it alone, and its routing receipt is not its answer")
        // A routing turn discarded twice leaves two such receipts; neither
        // is the lead's answer.
        let twice = log + [roomEvent(seq: 4, kind: "turn.cancelled", [
            "thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli",
            "round_index": 0, "seen_through_seq": 1, "task_id": "route-task-2", "reason": "discarded",
        ])]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: twice, members: members)?.memberID, "zhongli")
        // A routing receipt without a task id is recognized the same way.
        let untasked = [log[0], log[1], roomEvent(seq: 3, kind: "turn.cancelled", [
            "thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli",
            "round_index": 0, "seen_through_seq": 1, "reason": "discarded",
        ])]
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: untasked, members: members), .routed([members[1]], routingTaskID: nil))
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: untasked, members: members)?.memberID, "zhongli")
        // Its own answer's receipt reads the message: the lead is done.
        let answered = log + [roomEvent(seq: 4, kind: "turn.settled", [
            "thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli",
            "round_index": 0, "seen_through_seq": 2, "task_id": "answer-task", "passed": true,
        ])]
        XCTAssertNil(GroupRoomTurns.pendingResponder(events: answered, members: members))
        // Its pill: nothing for the routing receipt, then its own answer.
        XCTAssertNil(GroupRoomTurns.memberStatuses(
            events: twice, activity: [], responder: nil, approvals: [], members: members
        )["zhongli"])
        XCTAssertEqual(GroupRoomTurns.memberStatuses(
            events: answered, activity: [], responder: nil, approvals: [], members: members
        )["zhongli"], .passed)
        // Outside a lead-routed discussion, or from another member, a
        // receipt that stopped short of the message (a bounded batch) is
        // that member's own turn.
        let batched = roomEvent(seq: 3, kind: "turn.settled", [
            "thread_id": "main", "discussion_event_id": "user:d1", "member_id": "furina",
            "round_index": 0, "seen_through_seq": 1, "task_id": "batch-task", "passed": true,
        ])
        XCTAssertEqual(GroupRoomTurns.memberStatuses(
            events: [log[0], log[1], batched], activity: [], responder: nil, approvals: [], members: members
        )["furina"], .passed)
        XCTAssertEqual(GroupRoomTurns.memberStatuses(
            events: [log[1], batched], activity: [], responder: nil, approvals: [], members: members
        )["furina"], .passed)
        // A message that names the lead skips routing, so the lead's own
        // batch that stopped short of it is its answer.
        let addressed = [log[0], userMessage(seq: 2, text: "@zhongli plan the trip"), roomEvent(seq: 3, kind: "turn.settled", [
            "thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli",
            "round_index": 0, "seen_through_seq": 1, "task_id": "batch-task", "passed": true,
        ])]
        XCTAssertEqual(GroupRoomTurns.memberStatuses(
            events: addressed, activity: [], responder: nil, approvals: [], members: members
        )["zhongli"], .passed)
    }

    func testTheLeadsPillCarriesTheCrownOnlyWhileTheRoomRoutesThroughIt() {
        let members = roomMembers()
        XCTAssertEqual(GroupRoomTurns.leadKey(
            context: GroupRoomContext(routing: .lead, leadMemberID: "Zhongli"), members: members
        ), members[1].identityKey)
        XCTAssertNil(GroupRoomTurns.leadKey(context: GroupRoomContext(routing: .everyone), members: members))
        XCTAssertNil(GroupRoomTurns.leadKey(context: nil, members: members))
        XCTAssertNil(GroupRoomTurns.leadKey(
            context: GroupRoomContext(routing: .lead, leadMemberID: "nahida"), members: members
        ), "a lead who left the room has no pill to crown")
        let unnamed = [GroupDecoders.member(any(["display_name": "Ghost"]))!]
        XCTAssertNil(GroupRoomTurns.leadKey(
            context: GroupRoomContext(routing: .lead, leadMemberID: ""), members: unnamed
        ), "a lead setting that names nobody crowns nobody")
    }

    func testTheKeptEventsDecideOnlyWhatTheyCanKnow() {
        let members = roomMembers()
        let lead = GroupRoomContext(routing: .lead, leadMemberID: "zhongli")
        func message(_ seq: Int, thread: String, id: String) -> GroupEvent {
            turnEvent(eventJSON(seq: seq, kind: "message.user", payload: ["text": "More", "thread_id": thread], eventID: id))
        }
        // Past the room's start: a message whose thread is its own client
        // event id opened it, whatever fell out before.
        let own = GroupRoomOutbox.serverEventID(forClientEventID: "conduit-x")
        let opened = [message(150, thread: "conduit-x", id: own)]
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: opened, members: members, context: lead), .leadChoosing(members[1]))
        // Any other thread's message with nothing earlier kept is a reply
        // whose start fell out: the host doesn't route it.
        let reply = [message(150, thread: "conduit-old", id: "user:r1")]
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: reply, members: members, context: lead), .unrouted)
        // A settings change after the discussion, and the one before it
        // gone: which applied is unknown, so nothing claims a choice.
        let changed = opened + [contextSet(seq: 151, routing: "everyone")]
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: changed, members: members, context: GroupRoomContext()), .unrouted)
        // From the room's start, no settings event means the defaults.
        let start = [roomEvent(seq: 1, kind: "room.created", [:]), message(2, thread: "conduit-x", id: own)]
        XCTAssertEqual(GroupRoomTurns.pendingRoute(events: start, members: members, context: lead), .unrouted)
    }

    func testContinueIsOfferedOnlyWhereItsCountIsKnown() {
        let bounded = roomEvent(seq: 160, kind: "room.activity", [
            "status": "bounded", "reason_code": "max_rounds", "thread_id": "main", "discussion_event_id": "user:d1",
        ])
        // The discussion's message left the kept events, and its Continues
        // with it: the next grant is unknown.
        XCTAssertTrue(GroupRoomTurns.continuablePauses(events: [bounded]).isEmpty)
        // With the message kept, every Continue after it is too.
        let kept = [userMessage(seq: 150, text: "Debate it"), bounded]
        XCTAssertEqual(GroupRoomTurns.continuablePauses(events: kept)["e160"]?.grant, 1)
    }

    func testTheHostsLiveTurnsNameWhoIsAnswering() {
        let members = roomMembers()
        let activity = [
            GroupMemberActivity(memberID: "furina", status: "queued"),
            GroupMemberActivity(memberID: "zhongli", status: "running"),
        ]
        XCTAssertEqual(GroupRoomTurns.activeResponder(activity: activity, members: members)?.memberID, "zhongli")
        XCTAssertEqual(GroupRoomTurns.activeResponder(activity: [activity[0]], members: members)?.memberID, "furina")
        XCTAssertNil(GroupRoomTurns.activeResponder(activity: [], members: members))
        // A turn being stopped is still the live one, ahead of a queued one.
        let stopping = [GroupMemberActivity(memberID: "zhongli", status: "stopping"), activity[0]]
        XCTAssertEqual(GroupRoomTurns.activeResponder(activity: stopping, members: members)?.memberID, "zhongli")
        // A host whose config allows one round: nobody is cited past it.
        let log = [
            userMessage(seq: 1, text: "Hello"),
            memberMessage(seq: 2, member: "furina", round: 0, text: "@zhongli?"),
            settled(seq: 3, member: "furina", round: 0, messageSeq: 2),
            memberMessage(seq: 4, member: "zhongli", round: 0, text: "@furina!"),
            settled(seq: 5, member: "zhongli", round: 0, messageSeq: 4),
        ]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "furina")
        XCTAssertNil(GroupRoomTurns.pendingResponder(events: log, members: members, roundLimit: 1))
    }

    func testStateCarriesTheRoomsSettingsAndRouting() {
        let status = GroupDecoders.driverStatus(
            any(["running": true, "working": false, "max_continues": 5, "routing_modes": ["everyone", "lead", "auto"]]),
            context: any(["purpose": "Trips", "notes": "Budget 2k", "routing": "lead", "lead_member_id": "zhongli"])
        )
        XCTAssertEqual(status?.maxContinues, 5)
        XCTAssertEqual(status?.routingModes, ["everyone", "lead", "auto"])
        XCTAssertEqual(status?.roomContext, GroupRoomContext(purpose: "Trips", notes: "Budget 2k", routing: .lead, leadMemberID: "zhongli"))
        // A host before routing: no modes, and a routing this client predates reads as everyone.
        let older = GroupDecoders.driverStatus(any(["running": true]), context: any(["purpose": "x", "routing": "vote"]))
        XCTAssertNil(older?.routingModes)
        XCTAssertNil(older?.maxContinues)
        XCTAssertEqual(older?.roomContext?.routing, .everyone)
        XCTAssertEqual(older?.roomContext?.newerRouting, "vote")
        XCTAssertNil(older?.memberActivity)
        let live = GroupDecoders.driverStatus(any([
            "running": true, "working": true, "max_rounds": 5,
            "member_activity": [["member_id": "zhongli", "status": "running", "thread_id": "t1"]],
        ]))
        XCTAssertEqual(live?.maxRounds, 5)
        XCTAssertEqual(live?.memberActivity, [GroupMemberActivity(memberID: "zhongli", status: "running", threadID: "t1")])
        XCTAssertEqual(status?.with(running: true, working: true).roomContext?.leadMemberID, "zhongli")
    }

    func testSettledTurnsAndASettledRoomLeaveTheTranscriptToThePills() {
        let spoke = settled(seq: 3, member: "furina", round: 0, messageSeq: 2)
        let passed = settled(seq: 6, member: "furina", round: 1, messageSeq: nil)
        func activity(_ status: String) -> GroupEvent {
            turnEvent(eventJSON(seq: 9, kind: "room.activity", actor: ["kind": "gateway", "id": "gw-a"],
                                payload: ["status": status, "discussion_event_id": "user:d1"]))
        }
        XCTAssertFalse(GroupRoomTurns.isVisible(spoke))
        XCTAssertFalse(GroupRoomTurns.isVisible(passed))
        XCTAssertFalse(GroupRoomTurns.isVisible(activity("settled")))
        // The turn limit keeps its row, with Continue under it.
        XCTAssertTrue(GroupRoomTurns.isVisible(activity("bounded")))
        XCTAssertTrue(GroupRoomTurns.isVisible(userMessage(seq: 1, text: "hi")))
    }

    func testEachPillShowsTheMembersLastTurnInItsThreadsDiscussion() {
        let members = roomMembers()
        let log = [
            userMessage(seq: 1, text: "Hello everyone"),
            memberMessage(seq: 2, member: "zhongli", round: 0, text: "Greetings."),
            settled(seq: 3, member: "zhongli", round: 0, messageSeq: 2),
            settled(seq: 4, member: "furina", round: 0, messageSeq: nil),
        ]
        let statuses = GroupRoomTurns.memberStatuses(
            events: log, activity: [], responder: nil, approvals: [], members: members
        )
        XCTAssertEqual(statuses["furina"], .passed)
        XCTAssertEqual(statuses["zhongli"], .replied)

        // A newer message in the same thread starts over: Zhongli runs,
        // Furina waits, and the last discussion's outcomes are gone.
        let next = log + [userMessage(seq: 5, text: "Again", id: "user:d2")]
        let live = GroupRoomTurns.memberStatuses(
            events: next,
            activity: [GroupMemberActivity(memberID: "zhongli", status: "running"),
                       GroupMemberActivity(memberID: "furina", status: "queued")],
            responder: nil, approvals: [], members: members
        )
        XCTAssertEqual(live["zhongli"], .responding)
        XCTAssertEqual(live["furina"], .waiting)
        XCTAssertNil(GroupRoomTurns.memberStatuses(
            events: next, activity: [], responder: nil, approvals: [], members: members
        )["furina"])
    }

    func testALongDiscussionKeepsItsPillsWhenItsMessageIsTrimmed() {
        let members = roomMembers()
        let stopped = turnEvent(eventJSON(
            seq: 250, kind: "turn.cancelled", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli"]
        ))
        // The kept events start after the message that opened the discussion.
        let kept = [settled(seq: 240, member: "furina", round: 2, messageSeq: nil), stopped]
        let statuses = GroupRoomTurns.memberStatuses(
            events: kept, activity: [], responder: nil, approvals: [], members: members
        )
        XCTAssertEqual(statuses["furina"], .passed)
        XCTAssertEqual(statuses["zhongli"], .stopped)
    }

    func testALeadsRoutingTurnIsNotItsPass() {
        let members = roomMembers()
        let routing = turnEvent(eventJSON(
            seq: 2, kind: "turn.settled", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["thread_id": "main", "discussion_event_id": "user:d1", "member_id": "zhongli",
                      "round_index": 0, "passed": true, "task_id": "route-1"]
        ))
        let assignment = turnEvent(eventJSON(
            seq: 3, kind: "room.assignment", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["thread_id": "main", "discussion_event_id": "user:d1", "lead_member_id": "zhongli",
                      "member_ids": ["furina"], "task_id": "route-1"]
        ))
        let log = [userMessage(seq: 1, text: "hi"), routing, assignment,
                   settled(seq: 4, member: "furina", round: 0, messageSeq: nil)]
        let statuses = GroupRoomTurns.memberStatuses(
            events: log, activity: [], responder: nil, approvals: [], members: members
        )
        XCTAssertNil(statuses["zhongli"])
        XCTAssertEqual(statuses["furina"], .passed)
    }

    func testAFailureInAnotherThreadStaysOnItsPill() {
        let members = roomMembers()
        let failed = turnEvent(eventJSON(
            seq: 2, kind: "turn.failed", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["thread_id": "main", "discussion_event_id": "user:d1", "member_id": "furina", "round_index": 0]
        ))
        let other = turnEvent(eventJSON(
            seq: 3, kind: "message.user", payload: ["text": "Elsewhere", "thread_id": "t2"], eventID: "user:d2"
        ))
        let unreachable = turnEvent(eventJSON(
            seq: 4, kind: "turn.deferred", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["thread_id": "t2", "discussion_event_id": "user:d2", "member_id": "zhongli",
                      "reason": "member_unavailable"]
        ))
        let log = [userMessage(seq: 1, text: "hi"), failed, other, unreachable]
        let statuses = GroupRoomTurns.memberStatuses(
            events: log, activity: nil, responder: nil, approvals: [], members: members
        )
        XCTAssertEqual(statuses["furina"], .failed)
        XCTAssertEqual(statuses["zhongli"], .unavailable)
    }

    func testAnApprovalOutranksTheTurnAndAnOlderHostNamesItsResponder() {
        let members = roomMembers()
        let approval = GroupPendingApproval(action: [
            "kind": AnyCodable.from("approval"), "member_id": AnyCodable.from("furina"),
            "task_id": AnyCodable.from("t"), "execution_generation": AnyCodable.from(1),
            "request_id": AnyCodable.from("r"),
        ])!
        let statuses = GroupRoomTurns.memberStatuses(
            events: [userMessage(seq: 1, text: "hi")],
            activity: [GroupMemberActivity(memberID: "furina", status: "running")],
            responder: nil, approvals: [approval], members: members
        )
        XCTAssertEqual(statuses["furina"], .needsApproval)
        // Before member_activity (0.22.5), the log's responder.
        let older = GroupRoomTurns.memberStatuses(
            events: [userMessage(seq: 1, text: "hi")], activity: nil,
            responder: members[1], approvals: [], members: members
        )
        XCTAssertEqual(older["zhongli"], .responding)
    }

    func testAnIdleDriverOrAStatusThisAppPredatesShowsNoLiveTurn() {
        let members = roomMembers()
        let rows = [GroupMemberActivity(memberID: "furina", status: "running"),
                    GroupMemberActivity(memberID: "zhongli", status: "queued")]
        // Idle: rows it still lists are stale, and the log's responder too.
        let idle = GroupRoomTurns.memberStatuses(
            events: [userMessage(seq: 1, text: "hi")], activity: rows, working: false,
            responder: members[0], approvals: [], members: members
        )
        XCTAssertTrue(idle.isEmpty)
        // How each turn went still shows once the room is idle.
        let done = GroupRoomTurns.memberStatuses(
            events: [userMessage(seq: 1, text: "hi"), settled(seq: 2, member: "furina", round: 0, messageSeq: nil)],
            activity: rows, working: false, responder: nil, approvals: [], members: members
        )
        XCTAssertEqual(done["furina"], .passed)
        XCTAssertNil(done["zhongli"])
        let working = GroupRoomTurns.memberStatuses(
            events: [userMessage(seq: 1, text: "hi")], activity: rows, working: true,
            responder: nil, approvals: [], members: members
        )
        XCTAssertEqual(working["furina"], .responding)
        XCTAssertEqual(working["zhongli"], .waiting)
        let future = GroupRoomTurns.memberStatuses(
            events: [userMessage(seq: 1, text: "hi")],
            activity: [GroupMemberActivity(memberID: "furina", status: "warming")], working: true,
            responder: nil, approvals: [], members: members
        )
        XCTAssertNil(future["furina"])
    }

    func testTheTitleSaysSettledUntilTheNextMessageOrAContinue() {
        func event(_ seq: Int, _ kind: String, _ payload: [String: Any]) -> GroupEvent {
            turnEvent(eventJSON(seq: seq, kind: kind, actor: ["kind": "gateway", "id": "gw-a"], payload: payload))
        }
        var log = [userMessage(seq: 1, text: "hi")]
        XCTAssertFalse(GroupRoomTurns.latestDiscussionSettled(log))
        log.append(event(2, "room.activity", ["status": "settled", "discussion_event_id": "user:d1"]))
        XCTAssertTrue(GroupRoomTurns.latestDiscussionSettled(log))
        // A message on its way, before the log has it.
        XCTAssertFalse(GroupRoomTurns.latestDiscussionSettled(log, sending: true))
        XCTAssertFalse(GroupRoomTurns.latestDiscussionSettled(
            log + [event(3, "room.continued", ["discussion_event_id": "user:d1"])]
        ))
        XCTAssertFalse(GroupRoomTurns.latestDiscussionSettled(log + [userMessage(seq: 3, text: "more", id: "user:d2")]))
        XCTAssertFalse(GroupRoomTurns.latestDiscussionSettled(log + [event(3, "room.stop_requested", [:])]))
        // The message trimmed from the kept events: its settling still counts.
        XCTAssertTrue(GroupRoomTurns.latestDiscussionSettled(Array(log.dropFirst())))
        XCTAssertFalse(GroupRoomTurns.latestDiscussionSettled(
            [log[0], event(2, "room.activity", ["status": "bounded", "discussion_event_id": "user:d1"])]
        ))
    }

    // MARK: - Mention autocomplete

    func testMentionQueryTracksATrailingTag() {
        XCTAssertEqual(MentionAutocomplete.activeQuery(in: "@"), "")
        XCTAssertEqual(MentionAutocomplete.activeQuery(in: "hey @Zho"), "zho")
        XCTAssertNil(MentionAutocomplete.activeQuery(in: "hey @zhongli "))
        XCTAssertNil(MentionAutocomplete.activeQuery(in: "mail me@example"))
        XCTAssertNil(MentionAutocomplete.activeQuery(in: "no tag"))
        XCTAssertNil(MentionAutocomplete.activeQuery(in: "hey @钟离"))
        XCTAssertNil(MentionAutocomplete.activeQuery(in: "hey @zé"))
        XCTAssertNil(MentionAutocomplete.activeQuery(in: "hey @.foo"))
        XCTAssertNil(MentionAutocomplete.activeQuery(in: "@-x"))
        XCTAssertEqual(MentionAutocomplete.activeQuery(in: "@zhong.li"), "zhong.li")
    }

    func testMentionCompletionReplacesOnlyTheTrailingTag() {
        let candidates = MentionAutocomplete.roomCandidates(roomMembers())
        XCTAssertEqual(candidates.map(\.tag), ["furina", "zhongli", "all"])
        let matches = MentionAutocomplete.filter(candidates, query: "zh")
        XCTAssertEqual(matches.map(\.tag), ["zhongli"])
        XCTAssertEqual(MentionAutocomplete.completing("@furina and @zh", with: matches[0]), "@furina and @zhongli ")
        XCTAssertEqual(MentionAutocomplete.filter(candidates, query: "").count, 3)
    }

    func testRoomActivityOnlySettlesOnSettledStatus() {
        func activity(_ status: String) -> GroupEvent {
            turnEvent(eventJSON(seq: 9, kind: "room.activity", actor: ["kind": "gateway", "id": "gw-a"],
                                payload: ["status": status]))
        }
        XCTAssertEqual(GroupRoomTurns.roomActivityOutcome(activity("settled")), .settled)
        XCTAssertEqual(GroupRoomTurns.roomActivityOutcome(activity("bounded")), .bounded)
        XCTAssertEqual(GroupRoomTurns.roomActivityOutcome(activity("resumed")), .other)
    }

    func testRoutingMentionsMatchTheGatewayWithoutABoundary() {
        // The gateway's _MENTION_RE has no leading-boundary rule, so a@all
        // still broadcasts there even though it renders as prose.
        let members = roomMembers()
        let routed = GroupRoomTurns.resolveMentions(in: ["a@zhongli"], members: members, defaultAll: false)
        XCTAssertEqual(routed.map(\.memberID), ["zhongli"])
    }

    func testRoomCandidatesNeverDuplicateTheBroadcastTag() {
        let shadow = GroupDecoders.member(any([
            "member_id": "all", "profile": "all", "handle": "all", "display_name": "All",
        ]))!
        let tags = MentionAutocomplete.roomCandidates(roomMembers() + [shadow]).map(\.tag)
        XCTAssertEqual(tags, ["furina", "zhongli", "all"])
    }

    func testBotCandidatesSkipTheListenerAndHiddenBots() {
        func bot(_ name: String, title: String? = nil, hidden: Bool = false) -> BotProfile {
            BotProfile(
                name: name, botTitle: title, displayName: "", profileDescription: "",
                model: nil, provider: nil, hasAvatar: false, isPinned: false,
                isHiddenByMeta: hidden, appearanceColor: nil, canonicalSession: nil,
                lastActive: nil, lastPreview: nil
            )
        }
        let roster = [bot("furina", title: "Furina"), bot("zhongli", title: "Zhongli"), bot("ghost", hidden: true)]
        let candidates = MentionAutocomplete.botCandidates(roster, activeProfileName: "Furina")
        XCTAssertEqual(candidates.map(\.tag), ["zhongli"])
        XCTAssertEqual(candidates.first?.title, "Zhongli")
        XCTAssertEqual(MentionAutocomplete.botCandidates(roster, activeProfileName: nil).count, 2)
    }

    func testPendingResponderRotatesThreeMembersAndStopsAtTheMessageCap() {
        let members = roomMembers() + [GroupDecoders.member(any([
            "member_id": "nahida", "profile": "nahida", "handle": "nahida", "display_name": "Nahida",
        ]))!]
        var log = [userMessage(seq: 1, text: "@all hello")]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "furina")
        log += [memberMessage(seq: 2, member: "furina", round: 0, text: "hi"),
                settled(seq: 3, member: "furina", round: 0, messageSeq: 2)]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "zhongli")

        // Ten committed member messages bound the Discussion: nobody is next.
        var capped = [userMessage(seq: 1, text: "@all hello")]
        var seq = 2
        for index in 0..<GroupRoomTurns.maxMessages {
            let member = ["furina", "zhongli", "nahida"][index % 3]
            capped += [memberMessage(seq: seq, member: member, round: 0, text: "@all again"),
                       settled(seq: seq + 1, member: member, round: 0, messageSeq: seq)]
            seq += 2
        }
        XCTAssertNil(GroupRoomTurns.pendingResponder(events: capped, members: members))
    }

    func testRoomCandidatesReserveTheHumanHandoff() {
        let shadow = GroupDecoders.member(any([
            "member_id": "user", "profile": "user", "handle": "user", "display_name": "User",
        ]))!
        XCTAssertFalse(MentionAutocomplete.roomCandidates([shadow]).map(\.tag).contains("user"))
    }

    func testTurnIdentityFoldsCase() {
        let members = roomMembers()
        let passed = turnEvent(eventJSON(
            seq: 4, kind: "turn.settled", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["thread_id": "main", "discussion_event_id": "user:d1", "member_id": "Zhongli",
                      "round_index": 0, "passed": true, "message_event_id": NSNull()]
        ))
        XCTAssertEqual(GroupRoomTurns.member(for: passed, members: members)?.memberID, "zhongli")
        // Zhongli's differently-cased terminal still ends Zhongli's turn.
        let log = [userMessage(seq: 1, text: "@zhongli hi"), passed]
        XCTAssertNil(GroupRoomTurns.pendingResponder(events: log, members: members))
    }

    func testUnknownTurnKindsStayOutOfTheTranscript() {
        let future = turnEvent(eventJSON(seq: 3, kind: "turn.heartbeat", actor: ["kind": "gateway", "id": "gw-a"]))
        let failed = turnEvent(eventJSON(seq: 4, kind: "turn.failed", actor: ["kind": "gateway", "id": "gw-a"]))
        XCTAssertFalse(GroupRoomTurns.isVisible(future))
        XCTAssertTrue(GroupRoomTurns.isVisible(failed))
    }

    func testBotCandidatesSkipTagsTheMiddlewareFindsAmbiguous() {
        func bot(_ name: String, title: String?, hidden: Bool = false) -> BotProfile {
            BotProfile(
                name: name, botTitle: title, displayName: "", profileDescription: "",
                model: nil, provider: nil, hasAvatar: false, isPinned: false,
                isHiddenByMeta: hidden, appearanceColor: nil, canonicalSession: nil,
                lastActive: nil, lastPreview: nil
            )
        }
        // Two bots titled alike: each falls back to its own profile handle.
        let roster = [bot("scout", title: "Research Buddy"), bot("finder", title: "Research Buddy", hidden: true)]
        XCTAssertEqual(MentionAutocomplete.botCandidates(roster, activeProfileName: nil).map(\.tag), ["scout"])
    }

    func testNamelessMemberStillReadsAsAMember() {
        let nameless = GroupDecoders.member(any(["target": ["kind": "local"]]))!
        XCTAssertFalse(GroupRoomTurns.displayName(of: nameless).isEmpty)
    }

    func testDeferredMemberIsStillTheResponder() {
        let members = roomMembers()
        let deferred = turnEvent(eventJSON(
            seq: 2, kind: "turn.deferred", actor: ["kind": "gateway", "id": "gw-a"],
            payload: ["thread_id": "main", "discussion_event_id": "user:d1", "member_id": "furina",
                      "round_index": 0, "execution_generation": 1, "reason": "busy"]
        ))
        let log = [userMessage(seq: 1, text: "hi"), deferred]
        XCTAssertEqual(GroupRoomTurns.pendingResponder(events: log, members: members)?.memberID, "furina")
        XCTAssertFalse(GroupRoomTurns.isVisible(deferred))
    }
}
