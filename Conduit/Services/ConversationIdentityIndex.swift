import Foundation
import OSLog

private let conversationIdentityLog = Logger(
    subsystem: "com.milim.relay",
    category: "ConversationIdentityIndex"
)

/// Profile-scoped index of POSITIVELY confirmed runtime→durable conversation
/// mappings. It answers exactly two questions:
///
///     What durable conversation is runtime-a positively known to belong to?
///     (lookups — consumers such as notification routing)
///
/// and nothing more. It is NOT a second session state machine:
/// `ConversationIdentity` remains the ownership value, and the index only
/// centralizes the alias evidence that used to live exclusively inside
/// per-operation `acceptedSessionIDs` captures, so it survives across
/// operations instead of dying with each capture.
///
/// Evidence policy: mappings are recorded ONLY from positively verified
/// sources (admitted resume results, explicitly labeled catalog rows,
/// `session.active_list` rows, verified create/branch responses, and
/// notification payloads that carry both identities). Catalog ordering,
/// timestamps, title equality, string resemblance, and profile co-membership
/// are NEVER evidence, and no caller may synthesize a mapping from them.
///
/// Authority rules — who may establish, and who may REBIND a mapping that
/// historical evidence already confirmed. Callers pick the API by authority,
/// never by convenience:
///
///     Evidence                          API                   May establish?  May rebind?
///     -------------------------------------------------------------------------------------
///     historical confirmed alias        record(...)           yes             no
///     dual-ID notification payload      record(...)           yes             no
///     admitted session.resume           recordAuthoritative() yes             yes
///     authoritative catalog snapshot    recordCatalogIdentity yes             yes (first claim per snapshot)
///     session.active_list row           recordAuthoritative() yes             yes
///     verified create result            recordAuthoritative() yes             yes (created conversation)
///     verified branch result            recordAuthoritative() yes             yes (branched conversation)
///
/// The rule behind the table: when the app has already ACCEPTED fresh
/// routing evidence into conversation-owned state (an admitted resume, the
/// live registry, a response the catalog now reflects), the index must not
/// disagree with it — the app cannot say one thing while its own shared
/// index says another. Historical observations and unverified payload
/// claims, by contrast, never overwrite a fresher confirmed mapping; they
/// surface a conflict for the caller to log and resolve.
///
/// Scope: every mapping is keyed by the normalized profile. Runtime ids from
/// one profile can never establish or resolve ownership in another, and
/// `removeAll()` (the server-change boundary) drops everything so mappings
/// from one Hermes server are never usable on another.
@MainActor
final class ConversationIdentityIndex {
    /// Where a recorded mapping came from. Mirrors the diagnostics
    /// vocabulary; ids are the only content ever logged with it.
    enum EvidenceSource: String {
        case catalog
        case resume
        case activeList = "active_list"
        case create
        case branch
        case notification
    }

    /// An incoming positive claim disagreed with the confirmed mapping for a
    /// runtime id. Reported to the caller; never silently resolved.
    struct IdentityConflict: Equatable {
        let runtimeID: String
        let confirmedDurableID: String
        let incomingDurableID: String
        let source: EvidenceSource
    }

    private var runtimeToDurable: [String: [String: String]] = [:]

    func durableID(
        forRuntime runtimeID: String,
        profile: String
    ) -> String? {
        guard let normalizedProfile = ChatScrollIdentityNormalization.profile(profile),
              let normalizedRuntime = ChatScrollIdentityNormalization.sessionID(runtimeID) else {
            return nil
        }
        return runtimeToDurable[normalizedProfile]?[normalizedRuntime]
    }

    /// Records positive evidence that `runtimeID` routes to `durableID`.
    /// Returns the existing mapping as a conflict when different positive
    /// evidence is already confirmed; the confirmed mapping stays and the
    /// caller decides what the disagreement means for its own flow.
    ///
    /// This is the LOW-authority API: historical observations and dual-ID
    /// notification payloads (see the authority table in the type docs).
    /// Fresh evidence the app has already adopted into conversation-owned
    /// state must go through `recordAuthoritative` instead.
    @discardableResult
    func record(
        runtimeID: String,
        durableID: String,
        profile: String,
        source: EvidenceSource
    ) -> IdentityConflict? {
        guard let normalizedProfile = ChatScrollIdentityNormalization.profile(profile),
              let normalizedRuntime = ChatScrollIdentityNormalization.sessionID(runtimeID),
              let normalizedDurable = ChatScrollIdentityNormalization.sessionID(durableID) else {
            return nil
        }
        guard normalizedRuntime != normalizedDurable else {
            // Self-mappings carry no routing information.
            return nil
        }
        if let confirmed = runtimeToDurable[normalizedProfile]?[normalizedRuntime] {
            guard confirmed != normalizedDurable else { return nil }
            let conflict = IdentityConflict(
                runtimeID: normalizedRuntime,
                confirmedDurableID: confirmed,
                incomingDurableID: normalizedDurable,
                source: source
            )
            conversationIdentityLog.fault(
                "Identity conflict: runtime \(normalizedRuntime, privacy: .private(mask: .hash)) confirmed for \(confirmed, privacy: .private(mask: .hash)), incoming evidence (\(source.rawValue, privacy: .public)) claims \(normalizedDurable, privacy: .private(mask: .hash)) — keeping confirmed mapping"
            )
            return conflict
        }
        runtimeToDurable[normalizedProfile, default: [:]][normalizedRuntime] = normalizedDurable
        conversationIdentityLog.debug(
            "Confirmed alias: runtime \(normalizedRuntime, privacy: .private(mask: .hash)) → durable \(normalizedDurable, privacy: .private(mask: .hash)) (\(source.rawValue, privacy: .public))"
        )
        return nil
    }

    /// Records FRESH authoritative routing evidence the app has already
    /// accepted into conversation-owned state: an admitted `session.resume`
    /// result, a `session.active_list` row, a verified create/branch
    /// response. Where it disagrees with a historical confirmed mapping, the
    /// rebind WINS — the app cannot act on one answer while its shared index
    /// holds another — and the displaced mapping is returned and logged as
    /// the conflict record. Suspended operations are unaffected: they hold
    /// capture-time alias sets and can never gain ownership through the
    /// rebind.
    @discardableResult
    func recordAuthoritative(
        runtimeID: String,
        durableID: String,
        profile: String,
        source: EvidenceSource
    ) -> IdentityConflict? {
        guard let normalizedProfile = ChatScrollIdentityNormalization.profile(profile),
              let normalizedRuntime = ChatScrollIdentityNormalization.sessionID(runtimeID),
              let normalizedDurable = ChatScrollIdentityNormalization.sessionID(durableID),
              normalizedRuntime != normalizedDurable else {
            return nil
        }
        if let confirmed = runtimeToDurable[normalizedProfile]?[normalizedRuntime] {
            guard confirmed != normalizedDurable else { return nil }
            let conflict = IdentityConflict(
                runtimeID: normalizedRuntime,
                confirmedDurableID: confirmed,
                incomingDurableID: normalizedDurable,
                source: source
            )
            conversationIdentityLog.fault(
                "Authoritative rebind: runtime \(normalizedRuntime, privacy: .private(mask: .hash)) \(confirmed, privacy: .private(mask: .hash)) → \(normalizedDurable, privacy: .private(mask: .hash)) (\(source.rawValue, privacy: .public)); suspended work keeps its captured sets"
            )
            runtimeToDurable[normalizedProfile]?[normalizedRuntime] = normalizedDurable
            return conflict
        }
        runtimeToDurable[normalizedProfile, default: [:]][normalizedRuntime] = normalizedDurable
        conversationIdentityLog.debug(
            "Confirmed alias: runtime \(normalizedRuntime, privacy: .private(mask: .hash)) → durable \(normalizedDurable, privacy: .private(mask: .hash)) (\(source.rawValue, privacy: .public))"
        )
        return nil
    }

    /// Records explicitly labeled catalog rows. The live registry is the
    /// freshest authority on what a runtime id currently routes to, so a
    /// disagreement here overwrites the stale confirmed mapping (a routing
    /// identity change, logged by id) instead of keeping it. Within ONE
    /// snapshot the FIRST claim wins — the committed catalog can contain
    /// cached rows merged after fresh ones, and routing (`catalog.first`)
    /// reads that same order, so the index must not pin a later stale row
    /// the resolver would never route to. Catalog rows without a stored id
    /// contribute nothing: their primary id is already the legacy durable
    /// identity, so the self-mapping is information-free. Rows labeled with
    /// a different profile are skipped (nil stays caller-scoped).
    func recordCatalogIdentity(_ catalog: [SessionSummary], profile: String) {
        guard let normalizedProfile = ChatScrollIdentityNormalization.profile(profile) else {
            return
        }
        var claimedInSnapshot = Set<String>()
        for row in catalog {
            if let rowProfile = ChatScrollIdentityNormalization.profile(row.profile ?? ""),
               rowProfile != normalizedProfile {
                continue
            }
            guard let stored = ChatScrollIdentityNormalization.sessionID(row.storedSessionId) else {
                continue
            }
            let runtimeIDs = Set(
                ([row.id] + row.alternateIds)
                    .compactMap(ChatScrollIdentityNormalization.sessionID)
            ).subtracting([stored])
            for runtimeID in runtimeIDs.sorted() {
                if let confirmed = runtimeToDurable[normalizedProfile]?[runtimeID],
                   confirmed != stored {
                    conversationIdentityLog.fault(
                        "Identity conflict: runtime \(runtimeID, privacy: .private(mask: .hash)) confirmed for \(confirmed, privacy: .private(mask: .hash)), catalog row \(stored, privacy: .private(mask: .hash)) claims it — \(claimedInSnapshot.contains(runtimeID) ? "ignored, earlier row in this snapshot won" : "routing identity changed")"
                    )
                }
                guard !claimedInSnapshot.contains(runtimeID) else { continue }
                claimedInSnapshot.insert(runtimeID)
                // default: so a first catalog commit into an empty profile
                // scope actually lands (chained optional assignment into a
                // missing key is a silent no-op).
                runtimeToDurable[normalizedProfile, default: [:]][runtimeID] = stored
            }
        }
    }

    /// Removes every mapping touching any of `sessionIDs` (as runtime or as
    /// durable) inside `profile`. The delete path uses this so a deleted
    /// conversation's aliases cannot route anything to it afterward.
    func removeSessionIDs(_ sessionIDs: Set<String>, profile: String) {
        guard let normalizedProfile = ChatScrollIdentityNormalization.profile(profile) else {
            return
        }
        let ids = Set(sessionIDs.compactMap(ChatScrollIdentityNormalization.sessionID))
        guard !ids.isEmpty, var scoped = runtimeToDurable[normalizedProfile] else { return }
        scoped = scoped.filter { runtimeID, durableID in
            !ids.contains(runtimeID) && !ids.contains(durableID)
        }
        if scoped.isEmpty {
            runtimeToDurable.removeValue(forKey: normalizedProfile)
        } else {
            runtimeToDurable[normalizedProfile] = scoped
        }
    }

    /// Drops every mapping in every profile. The server-change boundary
    /// calls this: mappings confirmed against one Hermes server must never
    /// answer lookups against another.
    func removeAll() {
        runtimeToDurable.removeAll()
    }
}
