import Foundation

/// Hermes Bot Mode, Phase 1: the bot roster and the canonical Bot Chat.
///
/// A bot is an ordinary Hermes profile; its canonical DM is the profile's ONE
/// session titled exactly "Bot Chat" (born hidden). Identity is the NAME,
/// consulted on every open — never a stored client-side session pointer.
/// Everything here mirrors the upstream Desktop contract
/// (`apps/desktop/src/plugins/hermes-bots/canonical-chat.ts`,
/// `tui_gateway/methods_profiles.py`).
enum BotMode {
    /// The one canonical title. (profile, "Bot Chat") IS the bot's forever-chat
    /// identity; the gateway enforces title uniqueness on the profile. This is
    /// a wire constant, never a user-facing literal — do not localize it.
    static let canonicalChatTitle = "Bot Chat"

    /// Upper bound for the per-profile exact-title lookup, matching upstream's
    /// `PROFILE_SESSION_LIST_LIMIT`.
    static let lookupSessionLimit = 200
}

/// Lifecycle of the Bot Mode capability probe. `profiles.list` is the
/// capability call: `gatewayUnsupported` is the missing-method outcome (a
/// gateway old enough to lack the method has no Bot Mode), `failed` is an
/// ordinary transient failure.
enum BotModePhase: Equatable {
    case idle
    case loading
    case available
    case gatewayUnsupported
    case failed(message: String)
}

/// The roster's `canonical_session` field: the profile's canonical "Bot Chat"
/// row, resolved server-side by title on every `profiles.list`.
struct BotCanonicalSession: Equatable {
    /// The durable registry row.
    let id: String
    /// The compression-lineage tip — the live session a durable id currently
    /// maps to. Opens address the tip; the registry row stays the identity.
    let resolvedID: String?
    let lastActive: Double?
    let preview: String?
}

/// One roster row: a Hermes profile as Bot Mode presents it.
struct BotProfile: Identifiable, Equatable {
    /// The profile name — the wire identity every bot-scoped RPC addresses.
    let name: String
    /// `ui_meta['hermes-bots'].title`, the user's customized bot title.
    let botTitle: String?
    /// `display_name` from the profile itself.
    let displayName: String
    let profileDescription: String
    let model: String?
    let provider: String?
    let hasAvatar: Bool
    let isPinned: Bool
    /// `ui_meta['hermes-bots'].hidden` — presentation state only; Phase 1
    /// respects it by excluding the row.
    let isHiddenByMeta: Bool
    let appearanceColor: String?
    let canonicalSession: BotCanonicalSession?
    /// `last_session.last_active` — the freshest human conversation.
    let lastActive: Double?
    let lastPreview: String?
    /// `profiles.list` `previous_names` — profile names this bot answered to
    /// before renames. Mention resolution gap-fill only: a live name always
    /// outranks another bot's rename history (upstream `previous_names`).
    var previousNames: [String] = []

    var id: String { name }

    /// Upstream `displayName`: the bot's customized title, else the profile's
    /// display name, else the profile name.
    var displayLabel: String {
        let title = botTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? self.name : name
    }

    /// The canonical chat positively confirmed by the roster, if any.
    var canonicalSessionID: String? {
        let id = canonicalSession?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    /// Roster ordering: pinned rows first, then most-recent canonical (or
    /// ordinary) activity. Deterministic on ties via name.
    static func displayOrder(_ bots: [BotProfile]) -> [BotProfile] {
        bots.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            let lhsActivity = lhs.canonicalSession?.lastActive ?? lhs.lastActive ?? 0
            let rhsActivity = rhs.canonicalSession?.lastActive ?? rhs.lastActive ?? 0
            if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
            return lhs.name < rhs.name
        }
    }
}

/// A `profiles.list` answer reduced to what Phase 1 consumes.
struct BotRosterSnapshot: Equatable {
    var bots: [BotProfile]
    /// The backend injects the bot-to-bot messaging protocol server-side.
    /// Informational in Phase 1 — Conduit renders `message_agent` calls
    /// through its ordinary tool machinery.
    var supportsBotProtocol: Bool
}

enum BotRosterDecoder {
    /// Decodes a `profiles.list` RPC result. Nil when the payload is not a
    /// profiles envelope — callers must treat that as a decode failure, never
    /// as "no bots".
    static func decode(_ result: AnyCodable) -> BotRosterSnapshot? {
        guard let rows = result.objectValue?["profiles"]?.arrayValue else { return nil }
        let bots = rows.compactMap { row -> BotProfile? in
            guard let object = row.objectValue else { return nil }
            return decodeRow(object)
        }
        return BotRosterSnapshot(
            bots: bots,
            supportsBotProtocol: result.objectValue?["bot_mode_protocol"]?.boolValue ?? false
        )
    }

    private static func decodeRow(_ object: [String: AnyCodable]) -> BotProfile? {
        guard let name = object["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let meta = object["ui_meta"]?.objectValue?["hermes-bots"]?.objectValue
        var bot = BotProfile(
            name: name,
            botTitle: meta?["title"]?.stringValue,
            displayName: object["display_name"]?.stringValue ?? "",
            profileDescription: object["description"]?.stringValue ?? "",
            model: object["model"]?.stringValue,
            provider: object["provider"]?.stringValue,
            hasAvatar: object["has_avatar"]?.boolValue ?? false,
            isPinned: meta?["pinned"]?.boolValue ?? false,
            isHiddenByMeta: meta?["hidden"]?.boolValue ?? false,
            appearanceColor: meta?["color"]?.stringValue,
            canonicalSession: object["canonical_session"].flatMap(decodeCanonicalSession),
            lastActive: object["last_session"]?.objectValue?["last_active"]?.doubleValue,
            lastPreview: object["last_session"]?.objectValue?["preview"]?.stringValue
        )
        bot.previousNames = (object["previous_names"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
            .filter { !$0.isEmpty }
        return bot
    }

    private static func decodeCanonicalSession(_ value: AnyCodable?) -> BotCanonicalSession? {
        guard let object = value?.objectValue,
              let id = object["id"]?.stringValue?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return BotCanonicalSession(
            id: id,
            resolvedID: object["resolved_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            lastActive: object["last_active"]?.doubleValue,
            preview: object["preview"]?.stringValue
        )
    }
}

/// One `session.list` row as the canonical-chat lookup reads it.
struct BotChatLookupRow: Equatable {
    let id: String
    let resolvedID: String?
    let title: String?
    /// The durable lineage-root title reported by exact-lookup gateways; plain
    /// `title` covers windowed listings.
    let rootTitle: String?

    init(id: String, resolvedID: String? = nil, title: String? = nil, rootTitle: String? = nil) {
        self.id = id
        self.resolvedID = resolvedID
        self.title = title
        self.rootTitle = rootTitle
    }

    /// Upstream `isCanonicalBotChatHistory`: the root title wins when present.
    func isCanonicalTitle() -> Bool {
        let root = rootTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !root.isEmpty { return root == BotMode.canonicalChatTitle }
        let plain = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plain == BotMode.canonicalChatTitle
    }

    /// The lineage tip when present, else the durable row.
    var resumeTargetID: String? {
        let resolved = resolvedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return resolved.isEmpty ? id : resolved
    }
}

enum BotChatLookupDecoder {
    /// Decodes the exact-title `session.list` answer.
    ///
    /// FAIL-CLOSED on structure: a conforming gateway always returns a
    /// non-empty `id` per row (upstream `_session_row_summary`), but this
    /// decoder is the identity registry, not a listing — one structurally
    /// malformed row makes the WHOLE answer unreliable, and an unreliable
    /// lookup must read as failure (never silently discard the row and
    /// continue), because "empty" is what authorizes creating the forever
    /// chat. Nil therefore means "lookup failed", and every caller refuses
    /// to mint.
    static func decode(_ result: AnyCodable) -> [BotChatLookupRow]? {
        guard let rows = result.objectValue?["sessions"]?.arrayValue else { return nil }
        var decoded: [BotChatLookupRow] = []
        decoded.reserveCapacity(rows.count)
        for row in rows {
            guard let object = row.objectValue,
                  let id = object["id"]?.stringValue?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                return nil
            }
            decoded.append(BotChatLookupRow(
                id: id,
                resolvedID: object["resolved_id"]?.stringValue,
                title: object["title"]?.stringValue,
                rootTitle: object["root_title"]?.stringValue
            ))
        }
        return decoded
    }
}

/// What the canonical-chat consultation decided. The lookup is the bot's
/// identity registry: open the confirmed row, or — only once absence is
/// CONFIRMED — create the one hidden chat.
enum BotChatResolution: Equatable {
    case openExisting(registryID: String, resumeID: String)
    case create
}

enum BotChatResolver {
    /// Mirrors upstream `findExistingCanonicalChat`'s decision table. The
    /// roster's `canonical_session` is the last positive confirmation the
    /// profile HAD a canonical chat: an empty lookup while that exists is
    /// UNCONFIRMED absence (a profile backend mid-restart can answer an
    /// empty list), and must never read as "this bot never had a chat" —
    /// that read is the one remaining way to fork a forever chat.
    static func resolve(
        rows: [BotChatLookupRow],
        rosterCanonicalID: String?
    ) -> Result<BotChatResolution, BotChatRefusal> {
        let canonicalRows = rows.filter { $0.isCanonicalTitle() }
        if !canonicalRows.isEmpty {
            // Legacy forks can leave more than one canonical-titled row;
            // the roster's server-resolved registry breaks the tie when it
            // names one of them, so the open attaches to the SAME chat the
            // roster previewed.
            if let confirmed = rosterCanonicalID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !confirmed.isEmpty,
                let pinned = canonicalRows.first(where: {
                    $0.id == confirmed || $0.resolvedID == confirmed
                }) {
                return .success(.openExisting(
                    registryID: pinned.id,
                    resumeID: pinned.resumeTargetID ?? pinned.id
                ))
            }
            let match = canonicalRows[0]
            return .success(.openExisting(
                registryID: match.id,
                resumeID: match.resumeTargetID ?? match.id
            ))
        }
        if let confirmed = rosterCanonicalID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !confirmed.isEmpty {
            return .failure(.unconfirmedAbsence)
        }
        return .success(.create)
    }
}

enum BotChatRefusal: Error, Equatable {
    /// The lookup answered successfully but empty while the roster still
    /// positively confirms a canonical session — fail closed, never mint.
    case unconfirmedAbsence
}

/// Classifies the eager `session.title` rejection that means another writer
/// took the canonical title between our registry miss and the write. That is
/// the adopt-before-mint signal: re-run the lookup and adopt the winner.
enum BotChatTitleCollision {
    static func isError(_ error: Error) -> Bool {
        if let rpcError = error as? RpcError {
            if rpcError.code == 4022 { return true }
            return rpcError.message.lowercased().contains("already in use")
        }
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        return message.lowercased().contains("already in use")
    }
}

/// Sessions-list hygiene: canonical Bot Chats never surface as ordinary
/// sessions. Modern gateways keep hidden rows out of every listing server-side;
/// this projection filter closes the stale-data gap (a stray visible row that
/// still names a bot's canonical registry). A row is canonical when either:
///
/// 1. it positively matches a KNOWN bot's canonical registry ids, or
/// 2. its title is exactly "Bot Chat" AND its profile stamp names that bot.
///
/// Rule 2 is INTENTIONAL, not dead fallback weight: upstream identity for the
/// forever chat is the (profile, "Bot Chat") pair — the roster's
/// `canonical_session` pointer is an optimization, and stale/legacy listings
/// can surface the canonical row without one. The documented consequence: an
/// ordinary session that a user manually titled exactly "Bot Chat" under a
/// KNOWN bot's profile is indistinguishable from the canonical row on wire
/// data alone and is deliberately treated as reserved canonical presentation
/// state (hidden from Sessions). Every other session — including any session
/// owned by a bot profile under any other title — is never touched.
enum BotChatHygiene {
    static func isCanonicalBotChatRow(_ row: SessionSummary, roster: [BotProfile]) -> Bool {
        let rowIDs = Set([row.id, row.storedSessionId].compactMap { $0 } + row.alternateIds)
        for bot in roster {
            if let canonical = bot.canonicalSession {
                // Trimmed like `SessionBotOwnership` builds its registry ids, so
                // the hygiene rule and the ownership verdict cannot disagree about
                // a whitespace-padded server id.
                if let canonicalID = ChatScrollIdentityNormalization.sessionID(canonical.id),
                   rowIDs.contains(canonicalID) {
                    return true
                }
                if let resolved = canonical.resolvedID?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !resolved.isEmpty, rowIDs.contains(resolved) {
                    return true
                }
            }
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title == BotMode.canonicalChatTitle,
               let owner = row.profile?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !owner.isEmpty,
               // Case-insensitive, matching `ownsProfile` and the resume-scope
               // resolution: a mixed-case bot profile ("Atlas") whose row is
               // stamped "atlas" is still that bot's canonical chat, and two
               // hygiene checks disagreeing about it is the latent trap.
               owner.caseInsensitiveCompare(
                   bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
               ) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// The catalog an ordinary dashboard workspace may pick its automatic /
    /// preserve-current RESUME TARGET from: the raw catalog minus canonical
    /// Bot Chat presentation rows. Selection-only — the published catalog is
    /// never mutated, and ordinary list presentation keeps exactly the
    /// hygiene it had.
    ///
    /// Three independent signals, because they cover different moments:
    ///
    /// 1. `isCanonicalBotChatRow` — registry evidence, when a roster is
    ///    loaded (a bot's canonical ids, or the reserved title stamped on
    ///    that bot's profile).
    /// 2. the reserved exact title ALONE, which is load-bearing rather than
    ///    redundant: a stale/legacy visible row would otherwise be the
    ///    newest candidate, and the row's own profile stamp may name a bot
    ///    this client does not list.
    /// 3. `botOwnedSessionIDs` — positive bot ownership resolved by the
    ///    caller from the roster's canonical registries AND this process's
    ///    bot-chat registry. This is what catches a canonical row whose title
    ///    no longer names the canonical chat (a compaction moved the
    ///    conversation to a lineage tip) or whose profile stamp is missing.
    ///
    /// Selecting a canonical row builds the dashboard workspace's active
    /// conversation, cold-restore selection, and persisted title from a
    /// session that belongs to a bot's forever chat — the row must therefore
    /// be unselectable here regardless of client-side registry state.
    static func ordinaryResumeCandidates(
        _ rows: [SessionSummary],
        roster: [BotProfile],
        botOwnedSessionIDs: Set<String> = []
    ) -> [SessionSummary] {
        rows.filter { row in
            guard !isCanonicalBotChatRow(row, roster: roster),
                  !isReservedCanonicalTitleRow(row) else { return false }
            return !isBotOwnedRow(row, botOwnedSessionIDs: botOwnedSessionIDs)
        }
    }

    /// Row-level form of the ownership rule: a conversation the client
    /// positively attributes to Bot Mode, under ANY of its identities — the
    /// runtime id, the durable row, an alias, or the LINEAGE ROOT a compaction
    /// moved the conversation off of (a listing can link the tip row to the
    /// canonical registry only through that root). The caller supplies the
    /// evidence set (`SessionBotOwnership.botOwnedIDs`), so the sessions
    /// surface and the resume selection can never disagree about which rows are
    /// a bot's forever chat.
    static func isBotOwnedRow(
        _ row: SessionSummary,
        botOwnedSessionIDs: Set<String>
    ) -> Bool {
        guard !botOwnedSessionIDs.isEmpty else { return false }
        if botOwnedSessionIDs.contains(row.id) { return true }
        if let stored = row.storedSessionId, botOwnedSessionIDs.contains(stored) {
            return true
        }
        if let root = row.lineageRootId, botOwnedSessionIDs.contains(root) {
            return true
        }
        return row.alternateIds.contains { botOwnedSessionIDs.contains($0) }
    }

    /// The roster-independent half of the reservation: a row titled exactly
    /// "Bot Chat" is canonical presentation state on wire data alone.
    ///
    /// It stays unconditional even when a roster IS loaded (rather than
    /// deferring to `isCanonicalBotChatRow`) because the most likely stale
    /// shape — a legacy/foreign listing whose `profile` stamp is missing or
    /// names a profile this client does not have in its roster — cannot
    /// satisfy that rule anyway, and a roster fetched seconds ago is not
    /// evidence about a row the server is presenting right now.
    /// Consequence, identical in spirit to `isCanonicalBotChatRow`'s: such a
    /// session is never AUTOMATICALLY resumed. It stays listed and explicitly
    /// openable when it is an ordinary conversation.
    static func isReservedCanonicalTitleRow(_ row: SessionSummary) -> Bool {
        row.title.trimmingCharacters(in: .whitespacesAndNewlines) == BotMode.canonicalChatTitle
    }
}
