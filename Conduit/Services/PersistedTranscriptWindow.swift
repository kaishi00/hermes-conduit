import Foundation

/// Bounded persisted-history hydration for the active conversation, mirroring
/// Hermes Desktop's transcript window: `session.resume` stays compact and the
/// persisted transcript arrives as tail-anchored pages of
/// `GET /api/sessions/{id}/messages` instead of one unbounded payload.
enum PersistedTranscriptPagination {
    /// Rows per persisted-history page. Matches Hermes Desktop's
    /// `LATEST_SESSION_MESSAGES_LIMIT`: enough tail to fill the transcript
    /// window a few times over, small enough that opening a hundred-thousand-
    /// row session does not ship (and normalize) rows nobody scrolled to.
    static let pageSize = 120

    /// Query for one tail-anchored page. The backend measures `offset` back
    /// from the NEWEST persisted row and still returns the selected page in
    /// chronological order. `include_compacted=true` keeps compaction-
    /// preserved display rows reachable; without them the transcript
    /// silently ends at the compaction boundary.
    static func tailQuery(offset: Int) -> String {
        "?limit=\(pageSize)&offset=\(offset)&order=latest&include_compacted=true"
    }

    /// Legacy one-shot request: no paging parameters. Older Hermes builds
    /// answer it with the complete transcript, exactly as pre-pagination
    /// Conduit read them.
    static let legacyQuery = ""

    /// Pagination echo of one `/messages` response. Absent means the backend
    /// served the legacy one-shot full transcript.
    struct PageInfo: Equatable {
        let limit: Int?
        let offset: Int?
        let order: String?
        let returned: Int
        /// Rows actually present in the response — the offset bookkeeping
        /// source of truth. The echoed `returned` is retained for parity
        /// with the server's view but never trusted over the row array.
        let rawReturned: Int

        /// True only when the backend honored the tail-anchored contract by
        /// echoing the `order=latest` paging mode. Older dashboard builds
        /// that page from the OLDEST end also return a pagination object —
        /// without the order echo — so their echo must never be read as
        /// tail-truncation evidence.
        var honorsTailContract: Bool { order == "latest" }

        /// A full page means older history may still exist; a short (or
        /// empty) page means the beginning has been reached. Trusts the
        /// echoed `limit` as the backend's real page size — a lying echo
        /// only costs bounded extra no-op taps before a short or empty
        /// page retires the affordance.
        func mayHaveOlderRows(fetchedRowCount: Int) -> Bool {
            honorsTailContract && fetchedRowCount >= (limit ?? PersistedTranscriptPagination.pageSize)
        }
    }

    /// Parses the response's pagination echo. `rawRowCount` backs the
    /// `returned` field when a backend omits it — the row array itself is
    /// the direct evidence of how much was fetched.
    static func parse(_ payload: [String: Any], rawRowCount: Int) -> PageInfo? {
        guard let raw = payload["pagination"] as? [String: Any] else { return nil }
        let returned = Self.integerValue(raw["returned"])
        return PageInfo(
            limit: Self.integerValue(raw["limit"]),
            offset: Self.integerValue(raw["offset"]),
            order: raw["order"] as? String,
            returned: returned ?? rawRowCount,
            rawReturned: rawRowCount
        )
    }

    private static func integerValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Int64: return Int(number)
        case let number as Double: return Int(number)
        case let string as String: return Int(string)
        default: return nil
        }
    }
}

/// Identity-safe per-active-session state of the loaded persisted-transcript
/// window. One value describes "how much of this conversation's persisted
/// history is on screen and whether older pages remain" — the pagination
/// counterpart of the compact resume's runtime state, never mixed into it.
struct PersistedTranscriptWindowState: Equatable {
    /// Session ID the window was hydrated for (as requested). The resolved
    /// stored ID and the runtime ID are tracked separately because the
    /// endpoint may re-home a runtime alias and `session.resume` may answer
    /// with a fresh runtime ID.
    let requestedSessionID: String
    let profile: String
    let pageSize: Int
    /// Stored session ID the accepted hydration's `/messages` response
    /// echoed (`session_id`), when the backend supplied one — the durable
    /// identity of the persisted rows and the ID older-page requests
    /// continue against.
    var resolvedSessionID: String?
    /// Runtime session ID the same accepted `session.resume` returned —
    /// the identity `applyChatResume` made active.
    var runtimeSessionID: String?
    /// Number of newest persisted rows the local transcript already covers.
    /// Advances by the fetched row count of every page, which self-corrects
    /// the offset drift that live rows create under `order=latest` paging.
    /// Network coverage only — never used as evidence about what the visible
    /// transcript contains.
    var nextOffset: Int
    var canLoadEarlier: Bool
    var isLoadingEarlier = false
    /// The visible transcript starts with rows loaded through backfill.
    /// Explicit state because the reconnect graft must keep preserving that
    /// prefix across REPEATED reconciles, while the network coverage reset
    /// below erases the offset evidence after the first one. Set when a
    /// backfill prepends; kept by a reconcile that grafts onto the prefix;
    /// cleared when a refreshed tail is authoritative (no safe anchor).
    var hasBackfilledPrefix = false

    /// Every session identity the accepted hydration/resume transaction
    /// vouched for together: the requested ID, the persisted stored ID, and
    /// the runtime ID. Trusted as one conversation because they arrived in
    /// the SAME accepted transaction after the transcript ownership
    /// validation — never reconstructed from a later catalog refresh, whose
    /// freshness must not gate backfill (the production no-op regression).
    var trustedSessionIDs: Set<String> {
        PersistedTranscriptWindow.normalizingSessionIDs([
            requestedSessionID, resolvedSessionID, runtimeSessionID
        ])
    }
}

/// A legacy one-shot transcript that exceeded the client's safe response
/// bound. Distinguished from the bridge's generic oversized-response error
/// so the transcript layer can surface the compatibility copy — an old
/// backend attempting the entire transcript — without that copy leaking
/// into unrelated oversized dashboard operations.
struct LegacyTranscriptOversizedError: LocalizedError {
    let limit: Int

    var errorDescription: String? {
        "This conversation is too large to load safely with this Hermes version. Update Hermes to enable paginated conversation history."
    }
}

/// Pure algebra for older-page backfill: row merging, reconnect grafting,
/// tool-boundary reconstruction, and conversation-identity ownership.
enum PersistedTranscriptWindow {
    /// Whether a persisted-history window belongs to a conversation — the
    /// ONE identity rule shared by the backfill action, stale-response
    /// validation, the ChatView affordance, and the reconnect graft gate.
    ///
    /// Primary truth is explicit overlap between the window's
    /// transaction-captured IDs (`trustedSessionIDs`: requested + resolved
    /// stored + runtime) and the checked conversation's IDs. Catalog alias
    /// knowledge — pre-expanded by the caller into the alias sets — remains
    /// a secondary compatibility source, but its freshness is never
    /// required: a resume re-homes `activeSessionId` to the runtime ID long
    /// before (sometimes never before) the catalog learns the alias, and
    /// requiring it silently disabled "Load earlier messages".
    static func ownershipHolds(
        window: PersistedTranscriptWindowState,
        conversationSessionIds: Set<String>,
        profile: String,
        windowAliasIds: Set<String>,
        conversationAliasIds: Set<String>
    ) -> Bool {
        guard window.profile == profile else { return false }
        let windowIDs = window.trustedSessionIDs
        if !windowIDs.isDisjoint(with: conversationSessionIds) { return true }
        if !windowIDs.isDisjoint(with: conversationAliasIds) { return true }
        if !conversationSessionIds.isDisjoint(with: windowAliasIds) { return true }
        return false
    }

    /// Session-ID candidates reduced to a trusted identity set: nil and
    /// whitespace-only entries are dropped, everything else is kept as-is.
    /// One normalization rule for every identity set compared by
    /// `ownershipHolds`.
    static func normalizingSessionIDs(_ candidates: [String?]) -> Set<String> {
        var ids: Set<String> = []
        for candidate in candidates {
            guard let candidate,
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            ids.insert(candidate)
        }
        return ids
    }

    /// Prepends an older page onto the loaded transcript, dropping rows the
    /// transcript already holds. Offset drift under `order=latest` paging
    /// (rows persisted while the conversation is open shift the origin) makes
    /// overlap normal, so pages are never assumed disjoint. Deduplication
    /// keys on the durable message identity — `ChatMessage.id`, which for
    /// persisted rows is the database row id carried by the payload — never
    /// on visible text. (Rows without any payload id would fall back to a
    /// positional identity and defeat dedup; unreachable with Hermes, whose
    /// persisted rows always carry their SQLite row id.)
    ///
    /// Only the strictly-older region of the page is prepended: everything
    /// from the first already-held row onward is either duplicate or
    /// newer-side content that arrived outside the window, and prepending
    /// the latter would land it ABOVE older held rows. Newer-side rows
    /// reach the transcript through the live projection and the reconcile
    /// tail graft instead.
    ///
    /// Returns nil when nothing would change: an empty transcript means the
    /// session was swapped or wiped mid-fetch (prepending would paint the
    /// older page as the whole conversation), and a page with no fresh rows
    /// must not publish a redundant transcript replacement.
    static func prepending(
        _ olderPage: [ChatMessage],
        onto existing: [ChatMessage]
    ) -> [ChatMessage]? {
        guard !existing.isEmpty, !olderPage.isEmpty else { return nil }
        let knownIDs = Set(existing.map { $0.id })
        let olderRegion: ArraySlice<ChatMessage>
        if let firstKnown = olderPage.firstIndex(where: { knownIDs.contains($0.id) }) {
            olderRegion = olderPage[..<firstKnown]
        } else {
            olderRegion = olderPage[...]
        }
        var freshIDs = knownIDs
        var fresh: [ChatMessage] = []
        fresh.reserveCapacity(olderRegion.count)
        for message in olderRegion where freshIDs.insert(message.id).inserted {
            fresh.append(message)
        }
        guard !fresh.isEmpty else { return nil }
        return fresh + existing
    }

    /// Re-anchors a refreshed tail onto a transcript with backfilled older
    /// pages. A re-reconciliation re-reads only the newest page; replacing
    /// the transcript with it outright would silently drop everything
    /// "Load earlier messages" already loaded. The refreshed tail's first
    /// row locates where it begins inside the previous transcript and the
    /// older prefix is kept. When no anchor is found (compaction rewrite,
    /// session identity change) the refreshed tail is authoritative.
    ///
    /// Returns whether the graft applied, so the caller can carry the
    /// backfilled-prefix fact into the refreshed window and keep preserving
    /// the prefix across repeated reconciles.
    static func grafting(
        refreshedTail: [ChatMessage],
        ontoBackfilled previous: [ChatMessage],
        window: PersistedTranscriptWindowState?
    ) -> (messages: [ChatMessage], grafted: Bool) {
        guard let window, window.hasBackfilledPrefix,
              !previous.isEmpty, !refreshedTail.isEmpty,
              let first = refreshedTail.first,
              let anchor = previous.firstIndex(where: { $0.id == first.id }),
              anchor > 0 else {
            return (refreshedTail, false)
        }
        return (Array(previous[..<anchor]) + refreshedTail, true)
    }

    /// Reconciles a tool call/result pair that a page boundary split apart.
    /// The initial tail and each older page are normalized independently, so
    /// when a call row is the last row of an older page and its result row
    /// is the first row of the already-held newer page, the call normalizes
    /// to an unanswered call card and the result to a standalone result card
    /// — one logical tool run rendered as two. Both sides carry the durable
    /// tool-call identity (`ToolActivity.id` = Hermes `tool_call_id`), so
    /// the result is folded back into its call card by ID, never by visible
    /// text, and the duplicate standalone card is dropped from the held
    /// prefix.
    ///
    /// Returns the adjusted older page and how many leading held messages
    /// were folded into it. The caller must only drop those held rows when
    /// the prepend actually publishes (an empty held side means the session
    /// was swapped mid-fetch and nothing may be dropped).
    static func reconcilingToolCallsAcrossBoundary(
        olderPage: [ChatMessage],
        held: [ChatMessage]
    ) -> (olderPage: [ChatMessage], foldedFromHeld: Int) {
        var adjusted = olderPage
        var folded = 0
        // Bounded by the loaded inputs, with no arbitrary pair ceiling — a
        // single assistant turn can carry any number of tool calls. Each
        // iteration consumes exactly one held row and stops at the first
        // held row that is not a foldable result, so the scan covers only
        // the contiguous boundary region (at most the held transcript's
        // length; call cards and their results are matched by durable ID,
        // never by position or name).
        while folded < held.count {
            let heldIndex = folded
            guard held[heldIndex].role == .tool,
                  let resultTool = held[heldIndex].tool,
                  resultTool.status == .complete,
                  let callID = resultTool.id, !callID.isEmpty,
                  let callIndex = adjusted.lastIndex(where: { message in
                      guard message.role == .tool, let tool = message.tool else { return false }
                      return tool.id == callID && (tool.output?.isEmpty ?? true)
                  }),
                  adjusted[callIndex].id != held[heldIndex].id else {
                break
            }
            adjusted[callIndex].tool?.output = resultTool.output
            adjusted[callIndex].tool?.status = .complete
            folded += 1
        }
        return (adjusted, folded)
    }

    /// Paginated-contract pages are deduplicated and grafted by durable row
    /// identity, so every row must carry one. Real Hermes persisted rows
    /// always carry their SQLite `id`; a page without durable identity means
    /// normalization would fall back to page-local positional IDs that
    /// cannot survive across pages — reject it before it can silently
    /// corrupt overlap dedup.
    nonisolated static func rowsHaveDurableIdentity(_ rows: [Any]) -> Bool {
        rows.allSatisfy { row in
            guard let dict = row as? [String: Any] else { return false }
            for key in ["id", "message_id"] {
                switch dict[key] {
                case let string as String where !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    return true
                case let number as NSNumber where number.doubleValue != 0:
                    // SQLite AUTOINCREMENT ids start at 1; zero is never a
                    // real persisted row id.
                    return true
                default:
                    continue
                }
            }
            return false
        }
    }
}
