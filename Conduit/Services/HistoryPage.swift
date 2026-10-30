import Foundation

/// A chat's page of persisted rows through the notifier plugin's history
/// page route (plugin 0.121+, #1525). The plugin reads Hermes' own
/// `/messages` page and sends each row the phone already holds as its
/// fingerprint alone; Conduit puts its copy of those rows back in place, so
/// the page it reads is Hermes' answer row for row. An edit, an /undo or a
/// compaction changes a row's fingerprint, and that row comes in full. On a
/// slow link most of a chat's open is that page's bytes.
enum HistoryPage {
    static let capability = "history-page"
    static let path = "/api/plugins/conduit_push/sessions/history-page"
    /// The key a held row is sent under, in place of the row.
    static let knownKey = "conduit_known"
    /// The most fingerprints the route reads.
    static let maxKnown = 500

    /// The rows of a chat's newest page as last read, kept on the phone with
    /// their fingerprints so the next read of the page sends only what
    /// changed. Raw rows, exactly as Hermes sent them: they only ever stand
    /// in for the same rows of a later answer, never for one on their own.
    /// Unchecked: the rows are JSON values, never changed once read.
    struct HeldRows: @unchecked Sendable {
        var sessionID: String
        var digests: [String]
        var rows: [Any]

        var byDigest: [String: Any] {
            var held: [String: Any] = [:]
            for (digest, row) in zip(digests, rows) { held[digest] = row }
            return held
        }
    }

    /// The route's body for a `/messages` query, or nil for a query it
    /// doesn't carry: the legacy one-shot read has no paging parameters.
    static func body(sessionId: String, query: String, known: [String]) -> [String: Any]? {
        guard let items = URLComponents(string: query)?.queryItems, !items.isEmpty else { return nil }
        var values: [String: String] = [:]
        for item in items { values[item.name] = item.value ?? "" }
        guard let limit = values["limit"].flatMap(Int.init) else { return nil }
        var body: [String: Any] = [
            "session_id": sessionId,
            "limit": limit,
            "offset": values["offset"].flatMap(Int.init) ?? 0,
            "include_compacted": values["include_compacted"] == "true",
            "inline_images": values["inline_images"] != "false",
            "known": Array(known.prefix(maxKnown)),
        ]
        if let order = values["order"] { body["order"] = order }
        return body
    }

    /// The route's answer with the phone's rows back in place, and the page's
    /// rows to keep; nil when it can't be Hermes' page: a fingerprint the
    /// phone doesn't hold, or fingerprints that don't line up with the rows.
    static func rebuild(
        _ response: [String: Any],
        held: [String: Any],
        sessionID: String
    ) -> (page: [String: Any], kept: HeldRows)? {
        guard let sent = response["messages"] as? [Any],
              let digests = response["row_digests"] as? [String],
              digests.count == sent.count else { return nil }
        var rows: [Any] = []
        rows.reserveCapacity(sent.count)
        for row in sent {
            if let object = row as? [String: Any], object.count == 1, let digest = object[knownKey] as? String {
                guard let heldRow = held[digest] else { return nil }
                rows.append(heldRow)
            } else {
                rows.append(row)
            }
        }
        var page = response
        page["messages"] = rows
        page["row_digests"] = nil
        return (page, HeldRows(sessionID: sessionID, digests: digests, rows: rows))
    }

    /// Whether a failed read should go to Hermes' own route instead: the
    /// plugin's route answered with a refusal of its own (an older Hermes, a
    /// profile that turned the plugin off). The link's own trouble (no
    /// answer, a timeout, a busy proxy) fails the read as Hermes' route would
    /// have, without a second wait on the same link.
    static func readsHermesRouteInstead(after error: Error) -> Bool {
        guard case let DashboardTicketBridgeError.http(status, _) = error else { return false }
        switch status {
        case 0, 408, 429, 502, 503, 504: return false
        default: return true
        }
    }
}
