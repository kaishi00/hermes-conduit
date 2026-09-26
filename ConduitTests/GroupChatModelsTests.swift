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
}
