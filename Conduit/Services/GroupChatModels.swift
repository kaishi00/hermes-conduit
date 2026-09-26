import CryptoKit
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

    /// Whether adopting `page` would skip unseen events: this room's events
    /// past the cursor must run contiguously from `cursor + 1`. A contiguous
    /// multi-event delta is an ordinary poll, not a gap.
    func pageSkipsAhead(_ page: GroupLogPage) -> Bool {
        let seqs = Set(page.events.filter { $0.roomID == roomID && $0.seq > cursor }.map(\.seq))
        var expected = cursor + 1
        for seq in seqs.sorted() {
            if seq != expected { return true }
            expected += 1
        }
        return false
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
    /// new truth, and a bounded tail's truncation point is by design, so this
    /// shares the initial-tail semantics.
    mutating func replaceAll(page: GroupLogPage) {
        adoptInitialTail(page: page)
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

    /// The id the gateway files a user message under: `user:` plus the
    /// SHA-256 hex of the client event id — upstream
    /// `gateway.hosted_rooms.user_event_id`. The id is trimmed first because
    /// the gateway's `identifier()` validator strips it before hashing. It lets a polled or replayed
    /// event settle a send whose own response never arrived.
    static func serverEventID(forClientEventID clientEventID: String) -> String {
        let trimmed = clientEventID.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return "user:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Settle the pending send when `events` carry its server-side twin (an
    /// ambiguous send that did land). Returns whether it settled. Only the
    /// fetched events are searched, and the opening tail and resyncs are
    /// bounded to the replay window (200 events). A twin older than that
    /// stays pending, and its retry is still safe: it reuses the same id,
    /// so the gateway deduplicates it.
    @discardableResult
    mutating func settle(from events: [GroupEvent]) -> Bool {
        guard let pending else { return false }
        let serverID = Self.serverEventID(forClientEventID: pending.eventID)
        guard events.contains(where: { $0.eventID == serverID }) else { return false }
        self.pending = nil
        return true
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
    /// A tag must start the text or follow whitespace, so `a@all` or
    /// `name@user.example` stay plain prose.
    static let mentionScanRegex = try? NSRegularExpression(
        pattern: "(?<!\\S)@([a-z0-9][a-z0-9._:-]*)",
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

// MARK: - Room turn presentation

/// Turn-level presentation for a hosted room log, ported from the gateway's
/// Discussion policy (`gateway/hosted_room_discussion.py`, `plan_next_task`).
///
/// The log's `turn.*` events are PER MEMBER TURN (actor: the gateway;
/// `payload.member_id` names the member), while the room as a whole settles
/// only with `room.activity` (`status` settled|bounded). The driver status
/// says THAT the room is working but not WHO; the Discussion policy is a pure
/// function of the log, so replaying it here names the member whose turn is
/// running. Presentation only — routing stays the gateway's.
enum GroupRoomTurns {
    /// `MAX_DISCUSSION_ROUNDS` / `MAX_DISCUSSION_MESSAGES` upstream.
    static let maxRounds = 3
    static let maxMessages = 10

    /// Kinds that end a member's turn for this presentation. Upstream's
    /// policy also counts `turn.deferred`, but a deferred task stays in the
    /// driver's queue and runs again under a later execution generation
    /// (`_derive_member_watermarks` allows a later terminal for it), so the
    /// deferred member is still the one the room is waiting on.
    static let terminalKinds: Set<String> = ["turn.settled", "turn.failed", "turn.cancelled"]

    /// The gateway's `_MENTION_RE`: no leading-whitespace rule, exact handle.
    /// Deliberately looser than the styling regex: `a@all` routes as a
    /// broadcast upstream even though it renders as prose.
    private static let routingMentionRegex = try? NSRegularExpression(
        pattern: "@([A-Za-z0-9][A-Za-z0-9._:-]*)",
        options: [.caseInsensitive]
    )

    /// Whether a log event deserves its own transcript row. A member turn
    /// that posted a message settles silently — the bubble already says it —
    /// and a deferred turn is re-run by the driver, so neither is news.
    static func isVisible(_ event: GroupEvent) -> Bool {
        switch event.kind {
        case "turn.settled":
            return event.payload["passed"]?.boolValue == true
        case "turn.failed", "turn.cancelled":
            return true
        default:
            // Every other per-member turn kind, including ones this client
            // predates, is bookkeeping: the placeholder bubble covers it.
            return !event.kind.hasPrefix("turn.")
        }
    }

    enum RoomActivityOutcome: Equatable {
        case settled
        case bounded
        /// A status this client predates: neutral, never "settled".
        case other
    }

    /// What a `room.activity` event says about the room. Only `settled` and
    /// `bounded` end a Discussion upstream.
    static func roomActivityOutcome(_ event: GroupEvent) -> RoomActivityOutcome {
        switch event.payload["status"]?.stringValue {
        case "settled": return .settled
        case "bounded": return .bounded
        default: return .other
        }
    }

    /// The member a turn event is about, by `payload.member_id`.
    static func member(for event: GroupEvent, members: [GroupMember]) -> GroupMember? {
        guard let id = event.payload["member_id"]?.stringValue else { return nil }
        return member(withID: id, in: members)
    }

    /// The member's name for captions, never empty: a member with no name
    /// fields at all reads as "A member".
    static func displayName(of member: GroupMember) -> String {
        for candidate in [member.displayName, member.handle, member.profile, member.memberID] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty { return trimmed }
        }
        return AppLocalization.string("A member")
    }

    /// The member whose turn the driver is running (or will run next) for
    /// the room's pending Discussion, or nil when the log says the room is
    /// idle. Mirrors `plan_next_task` except the per-member watermark skip,
    /// which never changes the pick for a live Discussion: a round-0
    /// responder always has the new user message unseen, and a later-round
    /// responder was cited after it last spoke.
    static func pendingResponder(events: [GroupEvent], members: [GroupMember]) -> GroupMember? {
        guard !members.isEmpty, let discussion = pendingDiscussion(events) else { return nil }
        let threadID = discussion.threadID ?? ""
        let committed = Set(events.compactMap { event -> String? in
            guard event.kind == "turn.settled" else { return nil }
            return event.payload["message_event_id"]?.stringValue
        })
        let threadMessages = events.filter { event in
            (event.threadID ?? "") == threadID
                && (event.isUserMessage || (event.isMemberMessage && committed.contains(event.eventID)))
        }
        let discussionMessages = threadMessages.filter { $0.seq >= discussion.seq }
        let memberMessages = threadMessages.filter {
            $0.isMemberMessage && $0.payload["discussion_event_id"]?.stringValue == discussion.eventID
        }
        guard memberMessages.count < maxMessages else { return nil }

        var terminals = Set<String>()
        for event in events where terminalKinds.contains(event.kind)
            && event.payload["discussion_event_id"]?.stringValue == discussion.eventID {
            if let round = HermesClient.exactIntValue(event.payload["round_index"]),
               let memberID = event.payload["member_id"]?.stringValue {
                terminals.insert("\(round)|\(memberID.lowercased())")
            }
        }

        for round in 0..<maxRounds {
            let responders = round == 0
                ? resolveMentions(in: [discussion.payload["text"]?.stringValue ?? ""], members: members, defaultAll: true)
                : unaddressedMentions(discussionMessages, members: members)
            for member in rotate(responders, by: round)
            where !terminals.contains("\(round)|\(routingID(of: member))") {
                return member
            }
            let spokeThisRound = memberMessages.contains {
                HermesClient.exactIntValue($0.payload["round_index"]) == round
            }
            if !spokeThisRound { return nil }
        }
        return nil
    }

    /// Oldest latest-per-thread user message not stopped and not yet
    /// settled or bounded (`_pending_discussion`).
    private static func pendingDiscussion(_ events: [GroupEvent]) -> GroupEvent? {
        let stoppedThrough = events.filter { $0.kind == "room.stop_requested" }.map(\.seq).max() ?? 0
        let completed = Set(events.compactMap { event -> String? in
            guard event.kind == "room.activity",
                  let status = event.payload["status"]?.stringValue,
                  status == "settled" || status == "bounded" else { return nil }
            return event.payload["discussion_event_id"]?.stringValue
        })
        var latestByThread: [String: GroupEvent] = [:]
        for event in events where event.isUserMessage {
            let thread = event.threadID ?? ""
            if let existing = latestByThread[thread], existing.seq > event.seq { continue }
            latestByThread[thread] = event
        }
        return latestByThread.values
            .sorted { $0.seq < $1.seq }
            .first { $0.seq > stoppedThrough && !completed.contains($0.eventID) }
    }

    /// `resolve_mentions`: exact handle match against the frozen roster;
    /// `@all`/`@everyone`, or no mention at all when `defaultAll`, is everyone.
    static func resolveMentions(in texts: [String], members: [GroupMember], defaultAll: Bool) -> [GroupMember] {
        let handles = Set(members.compactMap { $0.handle?.lowercased() })
        var mentioned = Set<String>()
        var everyone = false
        if let regex = routingMentionRegex {
            for text in texts {
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    guard let tokenRange = Range(match.range(at: 1), in: text) else { continue }
                    let handle = text[tokenRange].lowercased()
                    if handle == "all" || handle == "everyone" {
                        everyone = true
                    } else if handles.contains(handle) {
                        mentioned.insert(handle)
                    }
                }
            }
        }
        if everyone || (defaultAll && mentioned.isEmpty) { return members }
        return members.filter { mentioned.contains($0.handle?.lowercased() ?? "") }
    }

    /// `_unaddressed_member_mentions`: peers a member cited and who have not
    /// posted since.
    private static func unaddressedMentions(_ messages: [GroupEvent], members: [GroupMember]) -> [GroupMember] {
        var citedAt: [String: Int] = [:]
        var lastPostAt: [String: Int] = [:]
        for event in messages where event.isMemberMessage {
            let speaker = event.payload["member_id"]?.stringValue?.lowercased() ?? ""
            lastPostAt[speaker] = event.seq
            let cited = resolveMentions(
                in: [event.payload["text"]?.stringValue ?? ""], members: members, defaultAll: false
            )
            for member in cited where routingID(of: member) != speaker {
                citedAt[routingID(of: member)] = event.seq
            }
        }
        return members.filter { member in
            let id = routingID(of: member)
            guard let cited = citedAt[id] else { return false }
            return (lastPostAt[id] ?? 0) <= cited
        }
    }

    private static func rotate(_ members: [GroupMember], by round: Int) -> [GroupMember] {
        guard !members.isEmpty else { return members }
        let shift = round % members.count
        return Array(members[shift...] + members[..<shift])
    }

    /// The id the gateway stamps on turn payloads (`member_id`), lowercased:
    /// every comparison against a payload id folds case.
    private static func routingID(of member: GroupMember) -> String {
        (member.memberID ?? member.identityKey).lowercased()
    }

    private static func member(withID id: String, in members: [GroupMember]) -> GroupMember? {
        let id = id.lowercased()
        return members.first(where: { routingID(of: $0) == id })
            ?? members.first(where: { $0.profile?.caseInsensitiveCompare(id) == .orderedSame })
    }
}

// MARK: - Composer @mention picker

/// The `@query` being typed at the end of a composer draft, and the members
/// or bots it could complete to. Pure so both composers share one rule.
enum MentionAutocomplete {
    struct Candidate: Equatable, Identifiable {
        /// The tag inserted after `@`.
        let tag: String
        let title: String

        var id: String { tag }
    }

    /// The partial tag after a trailing `@` that starts the draft or follows
    /// whitespace, lowercased; nil when the draft does not end in one. A bare
    /// `@` yields "".
    static func activeQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace else { return nil }
        }
        let query = text[text.index(after: at)...]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        guard query.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return query.lowercased()
    }

    /// Candidates whose tag or title starts with `query` (or has a word
    /// that does), in the given order.
    static func filter(_ candidates: [Candidate], query: String) -> [Candidate] {
        guard !query.isEmpty else { return candidates }
        return candidates.filter { candidate in
            if candidate.tag.lowercased().hasPrefix(query) { return true }
            return candidate.title.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .contains { $0.hasPrefix(query) }
        }
    }

    /// The draft with its trailing `@query` replaced by `@tag `.
    static func completing(_ text: String, with candidate: Candidate) -> String {
        guard activeQuery(in: text) != nil, let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + candidate.tag + " "
    }

    /// Room members, then `@all`. Members without a handle cannot be routed
    /// and are left out.
    static func roomCandidates(_ members: [GroupMember]) -> [Candidate] {
        // A member handle can never shadow the broadcast tags or the human
        // handoff (the create path reserves the same set).
        var seen: Set<String> = ["all", "everyone", "user"]
        var result: [Candidate] = []
        for member in members {
            guard let handle = member.handle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !handle.isEmpty, seen.insert(handle.lowercased()).inserted else { continue }
            result.append(Candidate(tag: handle, title: GroupRoomTurns.displayName(of: member)))
        }
        result.append(Candidate(tag: "all", title: AppLocalization.string("Everyone")))
        return result
    }

    /// Bot Mode roster bots other than the one listening, tagged the way
    /// the composer middleware resolves them.
    /// A tag two bots can claim is ambiguous to the middleware, which then
    /// resolves it for neither, so the picker falls back to the bot's
    /// profile handle, or leaves the bot out when that collides too. Hidden
    /// bots still claim their forms there, so they count here as well.
    static func botCandidates(_ roster: [BotProfile], activeProfileName: String?) -> [Candidate] {
        let active = activeProfileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let others = roster.filter {
            active.isEmpty || $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(active) != .orderedSame
        }
        var claims: [String: Int] = [:]
        for bot in others {
            for form in BotMentions.resolvableForms(of: bot) { claims[form, default: 0] += 1 }
        }
        var seen = Set<String>()
        return others.compactMap { bot in
            guard !bot.isHiddenByMeta else { return nil }
            let tag = [BotMentions.mentionTag(for: bot), BotMentions.handle(for: bot)]
                .first { claims[$0.lowercased(), default: 0] == 1 }
            guard let tag, seen.insert(tag.lowercased()).inserted else { return nil }
            return Candidate(tag: tag, title: bot.displayLabel)
        }
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
