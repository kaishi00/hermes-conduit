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
            protocolVersion: HermesClient.exactIntValue(object["protocol_version"]) ?? 0,
            driverReady: object["driver"]?.boolValue ?? false,
            authorityGatewayID: object["authority_gateway_id"]?.stringValue ?? "",
            features: (object["features"]?.arrayValue ?? []).compactMap { $0.stringValue },
            methods: methods,
            maxLogLimit: HermesClient.exactIntValue(object["max_log_limit"]) ?? 500
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
    /// `previous_names` when the gateway supplies them — renamed members'
    /// old tags keep styling as mentions (presentation gap-fill only).
    var previousNames: [String] = []

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
        let knownKeys: Set<String> = ["member_id", "profile", "handle", "display_name", "target", "previous_names"]
        var extra: [String: AnyCodable] = [:]
        for (key, field) in object where !knownKeys.contains(key) {
            extra[key] = field
        }
        var member = GroupMember(
            memberID: object["member_id"]?.stringValue,
            profile: object["profile"]?.stringValue,
            handle: object["handle"]?.stringValue,
            displayName: object["display_name"]?.stringValue,
            target: object["target"]?.objectValue,
            extra: extra
        )
        member.previousNames = (object["previous_names"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
            .filter { !$0.isEmpty }
        return member
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
              let seq = HermesClient.exactIntValue(object["seq"]), seq >= 1 else { return nil }
        return GroupEvent(
            roomID: roomID,
            seq: seq,
            eventID: object["event_id"]?.stringValue ?? "",
            kind: object["kind"]?.stringValue ?? "unknown",
            actor: actor(object["actor"]),
            authorityEpoch: HermesClient.exactIntValue(object["authority_epoch"]),
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
            authorityEpoch: HermesClient.exactIntValue(object["authority_epoch"]) ?? 1,
            revision: HermesClient.exactIntValue(object["revision"]) ?? 0,
            createdAt: object["created_at"]?.doubleValue ?? 0,
            updatedAt: object["updated_at"]?.doubleValue ?? 0,
            disbandedAt: object["disbanded_at"]?.doubleValue,
            latestSeq: HermesClient.exactIntValue(object["latest_seq"])
        )
    }

    static func driverStatus(_ value: AnyCodable?) -> GroupDriverStatus? {
        guard let object = value?.objectValue else { return nil }
        var counts: [String: Int] = [:]
        for (key, count) in object["counts"]?.objectValue ?? [:] {
            if let number = HermesClient.exactIntValue(count) { counts[key] = number }
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
              let latest = HermesClient.exactIntValue(object["latest_seq"]) else { return nil }
        let events = (object["events"]?.arrayValue ?? []).compactMap(event)
        let authority = object["authority"]?.objectValue ?? [:]
        return GroupLogPage(
            events: events,
            cursor: HermesClient.exactIntValue(object["cursor"]) ?? events.last?.seq ?? 0,
            latestSeq: latest,
            hasMore: object["has_more"]?.boolValue ?? false,
            authorityGatewayID: authority["gateway_id"]?.stringValue ?? "",
            authorityEpoch: HermesClient.exactIntValue(authority["epoch"]) ?? 0
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
    /// message returns the SAME pending row untouched; the caller MUST have
    /// consulted `accepts(text:)` first — a different text is a new logical
    /// message and is refused there, never silently replaced here.
    mutating func beginSend(text: String, mintEventID: () -> String) -> Pending {
        if let pending {
            assert(pending.text == text, "Different text while a send is pending — refuse via accepts(text:), never replace")
            return pending
        }
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

// MARK: - Create idempotency

/// The create sheet's room-id keeper. `groups.create` deduplicates on the
/// client-minted `room_id`, so one id belongs to exactly one set of inputs:
/// a retry of an ambiguous create with the SAME name and roster reuses it
/// (the gateway returns the room it may already have made), while edited
/// inputs are a different room and get a fresh id — reusing the old one
/// would recover the first attempt's room or be refused.
enum GroupCreateAttempt {
    struct Inputs: Equatable {
        let name: String
        let members: Set<String>
    }

    static func mintRoomID() -> String {
        "conduit-\(UUID().uuidString.lowercased())"
    }

    static func roomID(for inputs: Inputs, current: String, attempted: Inputs?) -> String {
        guard let attempted, attempted != inputs else { return current }
        return mintRoomID()
    }
}

// MARK: - Room mention presentation

/// Semantic @mention classification for room transcripts and the room
/// composer, mirroring upstream `group-rounds.parseGroupChatMentions` +
/// `group-mention-text.tsx`: a token is STYLED exactly when upstream would
/// style it — unknown handles and e-mail addresses stay plain prose.
/// Recognized mentions render as inline accent text, never pills.
enum GroupRoomMentions {
    /// Upstream's styling regex is `[a-z0-9][a-z0-9._-]*`; this client also
    /// accepts `:`, matching the gateway driver's own `_MENTION_RE`. The
    /// result is one unknown token for a Matrix-style id (never a false
    /// mention split), at the cost of not styling the `@user` prefix of
    /// `@user:matrix.id` the way upstream's presentation-only path does.
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
    /// only. Like upstream's styling parser, membership is recognized by
    /// EVERY resolvable form of a member — the exact ids/handle/display
    /// name, their slug/collapsed reductions, the title's FIRST WORD
    /// ("Research Buddy" → @research), and `previous_names` gap-fill.
    static func classify(token: String, members: [GroupMember]) -> Kind? {
        let handle = token.lowercased()
        if handle == "user" { return .human }
        if handle == "all" || handle == "everyone" { return .broadcast }
        let collapsed = handle
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        for member in members {
            let candidates = [member.handle, member.memberID, member.profile, member.displayName]
                .compactMap { $0 } + member.previousNames
            for candidate in candidates {
                let lowered = candidate.lowercased()
                if lowered == handle || lowered == collapsed { return .agent }
                if BotMentions.mentionNameForms(candidate).contains(handle) { return .agent }
                // Upstream styles the title's first word too.
                if let firstWord = lowered.split(separator: " ").first,
                   String(firstWord) == handle { return .agent }
            }
            let stripped = candidateCollapsedForm(candidates)
            if !stripped.isEmpty, stripped == collapsed { return .agent }
        }
        return nil
    }

    /// The separator-stripped form of the member's most identity-bearing
    /// name (handle → profile → id), upstream's collapsed fallback.
    private static func candidateCollapsedForm(_ candidates: [String]) -> String {
        for candidate in candidates {
            let stripped = candidate
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .lowercased()
            if !stripped.isEmpty { return stripped }
        }
        return ""
    }
}

// MARK: - Desktop-synced group chats

/// A Group Chat created in Hermes Desktop. Desktop rooms are NOT hosted
/// rooms: Desktop orchestrates every round client-side and never calls
/// `groups.create`, so `groups.list` cannot see them. What reaches the
/// gateway is Desktop's bounded cross-client projection, stored under the
/// `default` profile's `ui_meta['hermes-bots-groups']` (upstream
/// `apps/desktop/src/plugins/hermes-bots/group-chat.ts`,
/// `groupChatSyncSnapshot`). The projection carries the room identity,
/// members, and the latest compacted messages — enough to list and read the
/// room, not to drive its rounds, so this client presents it read-only.
struct DesktopGroupChat: Equatable, Identifiable {
    struct Member: Equatable {
        let name: String
        let handle: String?
    }

    struct Message: Equatable, Identifiable {
        let id: String
        /// `from.kind == "member"`; everything else is the human.
        let isMember: Bool
        let speaker: String
        let text: String
        /// Seconds since 1970 (the projection stores milliseconds).
        let timestamp: Double?
        /// The projection cut `text` to its sync budget.
        let truncated: Bool
    }

    /// The projection's durable room key: `id:<roomId>` for current rooms,
    /// `name:<name>` for legacy ones.
    let key: String
    let name: String
    let members: [Member]
    let messages: [Message]
    /// At least this many earlier entries exist that the projection omits.
    let omitted: Int

    var id: String { key }
    var lastActivity: Double { messages.last?.timestamp ?? 0 }
}

enum DesktopGroupChatDecoder {
    /// The `ui_meta` key Desktop publishes the projection under.
    static let metaKey = "hermes-bots-groups"
    /// Desktop publishes to (and reads from) the `default` profile only.
    static let profileName = "default"

    /// The projection from a `profiles.list` answer's rows. Absent, empty,
    /// or malformed projections decode to no rooms — never an error.
    static func decode(profileRows rows: [AnyCodable]) -> [DesktopGroupChat] {
        let row = rows.first { $0.objectValue?["name"]?.stringValue == profileName }
        return decode(snapshot: row?.objectValue?["ui_meta"]?.objectValue?[metaKey])
    }

    /// Normalizes every historical envelope (v1 wall-clock tombstones, v2
    /// name-keyed rooms, v3 room-keyed rooms) the way upstream's
    /// `normalizeGroupChatSyncSnapshot` does, then applies its tombstone
    /// rules: an `id:` tombstone is final; a `name:` tombstone hides the room
    /// only while its revision is at least the room's.
    static func decode(snapshot: AnyCodable?) -> [DesktopGroupChat] {
        guard let object = snapshot?.objectValue else { return [] }
        let version = object["version"]?.doubleValue ?? 0
        let rawRooms = object["rooms"]?.objectValue ?? [:]
        let rawDeleted = object["deleted"]?.objectValue ?? [:]

        var deleted: [String: Double] = [:]
        for (key, value) in rawDeleted {
            let revision = max(0, value.doubleValue ?? 0)
            if version >= 3 {
                deleted[key] = revision
            } else {
                // v1 tombstones carried wall-clock ms, never a revision.
                deleted["name:\(key)"] = version >= 2 ? revision : 0
            }
        }

        var rooms: [DesktopGroupChat] = []
        for (rawKey, value) in rawRooms {
            guard let room = value.objectValue,
                  let log = room["log"]?.arrayValue else { continue }
            let key = version >= 3 ? rawKey : "name:\(rawKey)"
            let roomID = room["roomId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let idKey = roomID.isEmpty ? (key.hasPrefix("id:") ? key : nil) : "id:\(roomID)"
            if let idKey, deleted[idKey] != nil { continue }
            if key.hasPrefix("name:"), let tombstone = deleted[key],
               tombstone >= max(0, room["revision"]?.doubleValue ?? 0) { continue }

            let fallbackName: String = {
                if key.hasPrefix("name:") { return String(key.dropFirst(5)) }
                return key
            }()
            let rawName = room["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let members = (room["members"]?.arrayValue ?? []).compactMap { member -> DesktopGroupChat.Member? in
                guard let fields = member.objectValue,
                      let name = fields["name"]?.stringValue, !name.isEmpty else { return nil }
                return DesktopGroupChat.Member(name: name, handle: fields["handle"]?.stringValue)
            }
            let messages = log.enumerated().compactMap { index, entry -> DesktopGroupChat.Message? in
                guard let fields = entry.objectValue else { return nil }
                let from = fields["from"]?.objectValue ?? [:]
                let isMember = from["kind"]?.stringValue == "member"
                let speaker = from["name"]?.stringValue ?? ""
                let at = fields["at"]?.doubleValue ?? 0
                return DesktopGroupChat.Message(
                    id: fields["id"]?.stringValue ?? "entry-\(index)",
                    isMember: isMember,
                    speaker: speaker,
                    text: fields["text"]?.stringValue ?? "",
                    timestamp: at > 0 ? at / 1000 : nil,
                    truncated: fields["truncated"]?.boolValue ?? false
                )
            }
            rooms.append(DesktopGroupChat(
                key: key,
                name: rawName.isEmpty ? fallbackName : rawName,
                members: members,
                messages: messages,
                omitted: max(0, HermesClient.exactIntValue(room["omitted"]) ?? 0)
            ))
        }
        // Most recently active first; the key breaks ties deterministically.
        return rooms.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.key < rhs.key
        }
    }
}
