import Foundation

/// Wire models for the hosted Group Chat JSON-RPC contract
/// (`tui_gateway/methods_groups.py`; shapes from
/// `tui_gateway/contracts/groups_bot_relay.py` / `gateway/hosted_rooms.py`,
/// pinned upstream SHA fdec926e, protocol version 2).
///
/// Decoding is defensive by contract: unknown event kinds decode to their
/// raw string and render generically; malformed identity fields stay raw
/// instead of being silently attributed to another member; the raw payload
/// survives for diagnostics. A decode failure must never crash the app or
/// fabricate room state.
enum GroupWire {
    /// `groups.capabilities.protocol_version` this client was built against.
    /// Negotiation is by METHOD LIST, not by this constant: a gateway
    /// reporting a newer protocol still works for the methods it advertises.
    static let protocolVersion = 2

    /// The methods the foundation slice needs. Each feature checks its own
    /// method before surfacing UI; a gateway advertising none of these has
    /// no Group Chat.
    static let requiredMethods: Set<String> = [
        "groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.disband",
    ]

    /// Methods this slice degrades without (stop surfaces only when present).
    static let optionalMethods: Set<String> = ["groups.stop", "groups.rename", "groups.approve", "groups.retry"]
}

/// The `groups.capabilities` result, reduced to what the client consumes.
struct GroupCapabilities: Equatable {
    let protocolVersion: Int
    /// The gateway runs the hosted-room worker: same-gateway rooms execute
    /// their own rounds server-side and keep running without this client.
    let driverReady: Bool
    let authorityGatewayID: String
    let features: [String]
    let methods: Set<String>
    let maxLogLimit: Int

    func supports(_ method: String) -> Bool { methods.contains(method) }
    var foundationSupported: Bool { GroupWire.requiredMethods.isSubset(of: methods) }
}

enum GroupCapabilitiesDecoder {
    /// Nil when the payload is not a capabilities envelope — callers treat
    /// that as a protocol failure, never as "no groups".
    static func decode(_ result: AnyCodable?) -> GroupCapabilities? {
        guard let object = result?.objectValue else { return nil }
        let methods = Set((object["methods"]?.arrayValue ?? []).compactMap { $0.stringValue })
        guard !methods.isEmpty else { return nil }
        return GroupCapabilities(
            protocolVersion: object["protocol_version"]?.intValue ?? 0,
            driverReady: object["driver"]?.boolValue ?? false,
            authorityGatewayID: object["authority_gateway_id"]?.stringValue ?? "",
            features: (object["features"]?.arrayValue ?? []).compactMap { $0.stringValue },
            methods: methods,
            maxLogLimit: object["max_log_limit"]?.intValue ?? 500
        )
    }
}

/// One room member. `RoomMember` is an OPEN set upstream (legacy rooms may
/// carry pre-normalization rows), so unknown fields are preserved in
/// `extra` — never dropped, never used for identity.
struct GroupMember: Equatable {
    let memberID: String?
    let profile: String?
    let handle: String?
    let displayName: String?
    /// Routing metadata (`{kind: local|peer, …}`), preserved verbatim so
    /// cross-gateway parity needs no model migration.
    let target: [String: AnyCodable]?
    let extra: [String: AnyCodable]

    /// Stable display identity: the member id when present, else the
    /// profile, else the handle. Display names are NEVER identity — two
    /// members may share one, and a rename must not re-route history.
    var identityKey: String {
        for candidate in [memberID, profile, handle] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

/// One room-log actor. `kind` ∈ user|member|gateway|system upstream; an
/// unknown kind is kept verbatim and renders as a neutral system row.
struct GroupActor: Equatable {
    let kind: String
    let id: String
    let profile: String?
    let displayName: String?
    let connectionID: String?

    /// The member display label for transcript rendering. Identity-matched
    /// on `id`/`profile` only — a bare `display_name` never alone decides
    /// who spoke.
    func displayLabel(members: [GroupMember]) -> String {
        let idKey = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "member", !idKey.isEmpty {
            if let member = members.first(where: {
                $0.memberID?.caseInsensitiveCompare(idKey) == .orderedSame
                    || $0.profile?.caseInsensitiveCompare(idKey) == .orderedSame
            }) {
                let name = member.displayName ?? member.handle ?? member.profile ?? member.memberID
                if let name, !name.isEmpty { return name }
            }
        }
        if let profile, !profile.isEmpty, kind == "member" { return profile }
        return displayName ?? ""
    }
}

/// One room-log event. `kind` is kept RAW: the gateway appends kinds this
/// client may predate (`turn.started`, `room.members_changed`, future
/// kinds), and an unknown kind is a generic row, never a crash.
struct GroupEvent: Equatable, Identifiable {
    let roomID: String
    let seq: Int
    let eventID: String
    let kind: String
    let actor: GroupActor
    let authorityEpoch: Int?
    let payload: [String: AnyCodable]
    let createdAt: Double

    var id: String { eventID.isEmpty ? "seq-\(seq)" : eventID }

    var isUserMessage: Bool { kind == "message.user" }
    var isMemberMessage: Bool { kind == "message.member" }
    var isChatMessage: Bool { isUserMessage || isMemberMessage }

    /// The message text of a chat-message event (payload key `text`).
    var messageText: String? {
        guard isChatMessage else { return nil }
        return payload["text"]?.stringValue
    }

    /// The thread a chat/turn event belongs to (`thread_id` payload key).
    var threadID: String? { payload["thread_id"]?.stringValue }
}

/// A hosted room, as `groups.list`/`groups.state` return it.
struct GroupRoom: Equatable, Identifiable {
    let roomID: String
    let name: String
    let members: [GroupMember]
    let authorityGatewayID: String
    let authorityEpoch: Int
    let revision: Int
    let createdAt: Double
    let updatedAt: Double
    /// Non-nil once tombstoned; a disbanded room never reopens.
    let disbandedAt: Double?
    /// The replay horizon: the highest seq the room log ever assigned.
    let latestSeq: Int?

    var id: String { roomID }
    var isDisbanded: Bool { disbandedAt != nil }
}

/// `HostedRoomService.status(room_id)` — the live driver view. Unknown
/// `pending_actions` rows are preserved raw for the next parity slice.
struct GroupDriverStatus: Equatable {
    let running: Bool
    let working: Bool
    /// The driver is blocked on something the room owes it (approval or
    /// clarify pending) — the presentation-level "needs you" signal.
    let blocked: Bool
    let counts: [String: Int]
    let pendingActions: [[String: AnyCodable]]
}

/// One `groups.log` page.
struct GroupLogPage: Equatable {
    let events: [GroupEvent]
    /// The server-provided resume cursor (diagnostics; the replay engine
    /// advances its own cursor only over accepted events).
    let cursor: Int
    let latestSeq: Int
    let hasMore: Bool
    let authorityGatewayID: String
    let authorityEpoch: Int
}

/// `groups.send` result.
struct GroupSendResult: Equatable {
    let event: GroupEvent
    let accepted: Bool
    let driverStarted: Bool
}

// MARK: - Decoders

/// Field-by-field decoders. A room or event row missing its identity decodes
/// to nil and is DROPPED at listing level (a listing tolerates one bad row);
/// identity fields that ARE present are never rewritten, so an actor is
/// never silently conflated with another member.
enum GroupDecoders {
    static func member(_ value: AnyCodable?) -> GroupMember? {
        guard let object = value?.objectValue else { return nil }
        let knownKeys: Set<String> = ["member_id", "profile", "handle", "display_name", "target"]
        var extra: [String: AnyCodable] = [:]
        for (key, field) in object where !knownKeys.contains(key) {
            extra[key] = field
        }
        return GroupMember(
            memberID: object["member_id"]?.stringValue,
            profile: object["profile"]?.stringValue,
            handle: object["handle"]?.stringValue,
            displayName: object["display_name"]?.stringValue,
            target: object["target"]?.objectValue,
            extra: extra
        )
    }

    static func actor(_ value: AnyCodable?) -> GroupActor {
        let object = value?.objectValue ?? [:]
        return GroupActor(
            kind: object["kind"]?.stringValue ?? "unknown",
            id: object["id"]?.stringValue ?? "",
            profile: object["profile"]?.stringValue,
            displayName: object["display_name"]?.stringValue,
            connectionID: object["connection_id"]?.stringValue
        )
    }

    static func event(_ value: AnyCodable?) -> GroupEvent? {
        guard let object = value?.objectValue,
              let roomID = object["room_id"]?.stringValue,
              let seq = object["seq"]?.intValue, seq >= 1 else { return nil }
        return GroupEvent(
            roomID: roomID,
            seq: seq,
            eventID: object["event_id"]?.stringValue ?? "",
            kind: object["kind"]?.stringValue ?? "unknown",
            actor: actor(object["actor"]),
            authorityEpoch: object["authority_epoch"]?.intValue,
            payload: object["payload"]?.objectValue ?? [:],
            createdAt: object["created_at"]?.doubleValue ?? 0
        )
    }

    static func room(_ value: AnyCodable?) -> GroupRoom? {
        guard let object = value?.objectValue,
              let roomID = object["room_id"]?.stringValue?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !roomID.isEmpty else { return nil }
        return GroupRoom(
            roomID: roomID,
            name: object["name"]?.stringValue ?? roomID,
            members: (object["members"]?.arrayValue ?? []).compactMap(member),
            authorityGatewayID: object["authority_gateway_id"]?.stringValue ?? "",
            authorityEpoch: object["authority_epoch"]?.intValue ?? 1,
            revision: object["revision"]?.intValue ?? 0,
            createdAt: object["created_at"]?.doubleValue ?? 0,
            updatedAt: object["updated_at"]?.doubleValue ?? 0,
            disbandedAt: object["disbanded_at"]?.doubleValue,
            latestSeq: object["latest_seq"]?.intValue
        )
    }

    static func driverStatus(_ value: AnyCodable?) -> GroupDriverStatus? {
        guard let object = value?.objectValue else { return nil }
        var counts: [String: Int] = [:]
        for (key, count) in object["counts"]?.objectValue ?? [:] {
            if let number = count.intValue { counts[key] = number }
        }
        let pending = (object["pending_actions"]?.arrayValue ?? []).compactMap { $0.objectValue }
        return GroupDriverStatus(
            running: object["running"]?.boolValue ?? false,
            working: object["working"]?.boolValue ?? false,
            blocked: object["blocked"]?.boolValue ?? false,
            counts: counts,
            pendingActions: pending
        )
    }

    static func logPage(_ result: AnyCodable?) -> GroupLogPage? {
        guard let object = result?.objectValue,
              let latest = object["latest_seq"]?.intValue else { return nil }
        let events = (object["events"]?.arrayValue ?? []).compactMap(event)
        let authority = object["authority"]?.objectValue ?? [:]
        return GroupLogPage(
            events: events,
            cursor: object["cursor"]?.intValue ?? events.last?.seq ?? 0,
            latestSeq: latest,
            hasMore: object["has_more"]?.boolValue ?? false,
            authorityGatewayID: authority["gateway_id"]?.stringValue ?? "",
            authorityEpoch: authority["epoch"]?.intValue ?? 0
        )
    }
}

// MARK: - Replay assembly

/// The room-log replay engine: turns `groups.log` pages into one ordered,
/// duplicate-free event list. Pure and deterministic so initial history,
/// incremental polling, reconnect, and retries are unit-pinned.
///
/// Rules:
/// - The cursor advances ONLY over accepted events; an event at or below the
///   cursor is a replay and is dropped (identity is the monotonic `seq`,
///   never event text).
/// - Pages arrive ascending from the gateway; an out-of-order page is
///   defensively sorted. A GAP (the first accepted event past cursor+1)
///   adopts the events AND raises `hasGap` so the caller can resync through
///   `groups.state` instead of silently rendering a truncated room.
/// - Events for a different room are refused outright.
/// - `replaceAll` is the reconnect resync: authoritative tail rebuild.
struct GroupRoomReplay: Equatable {
    /// Events accepted so far, ascending by seq. Includes every accepted
    /// kind; presentation filters.
    private(set) var events: [GroupEvent] = []
    private(set) var cursor = 0
    private(set) var hasGap = false
    /// The last page authority seen (`groups.log` `authority` block).
    private(set) var authorityGatewayID = ""
    private(set) var authorityEpoch = 0

    /// The room this replay is bound to; a foreign page never bleeds in.
    let roomID: String

    /// The `since_seq` the next `groups.log` call must send.
    var sinceSeq: Int { cursor }

    var lastChatMessage: GroupEvent? { events.last(where: \.isChatMessage) }

    init(roomID: String) {
        self.roomID = roomID
    }

    /// Adopt the INITIAL bounded tail (the room open path). The window's
    /// truncation point is by design, not a gap: the cursor jumps straight
    /// to the page's last accepted event and `hasGap` stays false no matter
    /// how much older history exists above the window.
    mutating func adoptInitialTail(page: GroupLogPage) {
        let incoming = page.events
            .filter { $0.roomID == roomID }
            .sorted { $0.seq < $1.seq }
        events = incoming
        cursor = incoming.last?.seq ?? 0
        hasGap = false
        if !page.authorityGatewayID.isEmpty {
            authorityGatewayID = page.authorityGatewayID
            authorityEpoch = page.authorityEpoch
        }
    }

    /// Adopt one incremental page. An empty page (fresh room, or nothing
    /// new) is a no-op.
    mutating func adopt(page: GroupLogPage) {
        let incoming = page.events
            .filter { $0.roomID == roomID && $0.seq > cursor }
            .sorted { $0.seq < $1.seq }
        for event in incoming {
            // Re-checked per event: duplicates inside one page lose to the
            // advancing cursor.
            guard event.seq > cursor else { continue }
            if event.seq > cursor + 1 { hasGap = true }
            events.append(event)
            cursor = event.seq
        }
        if !page.authorityGatewayID.isEmpty {
            authorityGatewayID = page.authorityGatewayID
            authorityEpoch = page.authorityEpoch
        }
    }

    /// Full resync: rebuild from an authoritative page (a reconnect after a
    /// gap, or a moved authority). The gap flag clears — the new page IS the
    /// new truth.
    mutating func replaceAll(page: GroupLogPage) {
        events = []
        cursor = 0
        hasGap = false
        adopt(page: page)
    }
}

// MARK: - Send outbox

/// The room composer's retry-key keeper. `groups.send` is idempotent by the
/// CLIENT event id, so one logical message keeps its id until an ACCEPTED
/// send replaces it: a retry of the SAME text after an ambiguous failure
/// reuses the id and the gateway deduplicates instead of posting a twin.
/// A DIFFERENT text is a new logical message and is refused while one is
/// pending — the caller surfaces the pending row for an explicit retry, so
/// no text is ever silently swallowed or silently replaced.
struct GroupRoomOutbox: Equatable {
    struct Pending: Equatable {
        let text: String
        let eventID: String
    }

    private(set) var pending: Pending?

    /// Whether `text` may be sent right now: yes when nothing is pending or
    /// when it IS the pending text (a retry).
    func accepts(text: String) -> Bool {
        guard let pending else { return true }
        return pending.text == text
    }

    /// Begin (or re-begin) a send of `text`. A retry of the still-pending
    /// message returns the SAME pending row untouched; a fresh text mints a
    /// fresh id.
    mutating func beginSend(text: String, mintEventID: () -> String) -> Pending {
        if let pending { return pending }
        let created = Pending(text: text, eventID: mintEventID())
        pending = created
        return created
    }

    /// The gateway accepted the event: the logical message is settled.
    mutating func accept(eventID: String) {
        if pending?.eventID == eventID { pending = nil }
    }

    mutating func discard() { pending = nil }
}

// MARK: - Room mention presentation

/// Semantic @mention classification for room transcripts and the room
/// composer, mirroring upstream `group-rounds.parseGroupChatMentions` +
/// `group-mention-text.tsx`: a token is STYLED exactly when routing would
/// honor it — unknown handles, e-mail addresses, and Matrix-style ids stay
/// plain prose. Recognized mentions render as inline accent text, never
/// pills.
enum GroupRoomMentions {
    /// Upstream's transcript scan charset (`[a-z0-9][a-z0-9._:-]*`). The
    /// wider set (dots/colons) is what makes e-mails and `@user:matrix.id`
    /// classify as UNKNOWN (their token never equals a member handle)
    /// instead of splitting into a false mention.
    static let mentionScanRegex = try? NSRegularExpression(
        pattern: "@([a-z0-9][a-z0-9._:-]*)",
        options: [.caseInsensitive]
    )

    enum Kind {
        case agent
        case broadcast
        case human
    }

    /// What a lone `@token` means in this room, or nil when routing ignores
    /// it. Room routing belongs to the gateway driver; this is presentation
    /// only.
    static func classify(token: String, members: [GroupMember]) -> Kind? {
        let handle = token.lowercased()
        if handle == "user" { return .human }
        if handle == "all" || handle == "everyone" { return .broadcast }
        if members.contains(where: { member in
            [member.handle, member.memberID, member.profile]
                .compactMap { $0 }
                .contains(where: { $0.caseInsensitiveCompare(handle) == .orderedSame })
        }) { return .agent }
        return nil
    }
}
