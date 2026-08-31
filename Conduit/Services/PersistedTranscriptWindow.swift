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
    /// Session ID the window was hydrated for (as requested; the resolved
    /// stored ID is tracked separately because the endpoint may re-home a
    /// runtime alias).
    let requestedSessionID: String
    let profile: String
    let pageSize: Int
    var resolvedSessionID: String?
    /// Number of newest persisted rows the local transcript covers. Advances
    /// by the fetched row count of every page, which self-corrects the
    /// offset drift that live rows create under `order=latest` paging.
    var nextOffset: Int
    var canLoadEarlier: Bool
    var isLoadingEarlier = false
}

/// Pure row-algebra for older-page backfill.
enum PersistedTranscriptWindow {
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
    static func grafting(
        refreshedTail: [ChatMessage],
        ontoBackfilled previous: [ChatMessage],
        window: PersistedTranscriptWindowState?
    ) -> [ChatMessage] {
        guard let window, window.nextOffset > window.pageSize,
              !previous.isEmpty, !refreshedTail.isEmpty,
              let first = refreshedTail.first,
              let anchor = previous.firstIndex(where: { $0.id == first.id }),
              anchor > 0 else {
            return refreshedTail
        }
        return Array(previous[..<anchor]) + refreshedTail
    }
}
