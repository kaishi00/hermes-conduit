import Foundation

/// One conversation's identity inside a profile, separating the two kinds of
/// session identifier the app handles.
///
/// - `profile` is capture metadata for the owning workspace. `admit` does not
///   compare it: AppState's reconciliation guards (`profile == activeProfile`
///   at every resume await boundary) enforce profile currency before the gate
///   runs. Profile comparison styles differ across subsystems, so the fence
///   stays where it is already enforced.
/// - `durableSessionID` is the stable UI/persistence identity: the catalog
///   row's stored id, or the id the resume store persisted. It is present
///   only when positively established; a brand-new runtime-only conversation
///   has none until the catalog or a resume response names one.
/// - `runtimeSessionID` is the routing identity Hermes currently answers to.
///   It may rotate (`runtime-old` → `runtime-new`); rotation is a transport
///   rebind of the same conversation, never a navigation to a new one.
/// - `acceptedSessionIDs` holds every identifier POSITIVELY confirmed
///   equivalent to this conversation at capture time: the selected id, its
///   catalog row's ids, and the scroll identity's confirmed aliases. It must
///   be captured before any catalog replacement — a refreshed catalog is
///   allowed to have temporarily forgotten the runtime alias, and that
///   absence is not evidence about the conversation's identity.
///
/// Catalog absence is not navigation authority: this value, not the newest
/// catalog snapshot, decides what preserve-current recovery owns.
struct ConversationIdentity: Equatable {
    let profile: String
    let durableSessionID: String?
    let runtimeSessionID: String?
    let acceptedSessionIDs: Set<String>

    /// The id a resume request addresses: the durable identity when one is
    /// established, otherwise the only id the conversation has.
    var resumeTargetID: String? {
        durableSessionID ?? runtimeSessionID
    }

    func contains(_ sessionID: String?) -> Bool {
        guard let sessionID else { return false }
        return acceptedSessionIDs.contains(sessionID)
    }
}

/// What a `session.resume` response claims about the conversation it resumed.
/// The runtime id and the durable id are parsed and validated SEPARATELY: a
/// returned runtime id alone is never proof of durable conversation identity.
struct ResumeIdentityClaim: Equatable {
    let runtimeSessionID: String
    let durableSessionID: String?
}

enum ResumeIdentityAdmission: Equatable {
    /// The response's durable id explicitly matches the selected durable id.
    case durableIdentityMatch
    /// The returned id is already a positively confirmed alias of the
    /// selected conversation.
    case knownAlias
    /// Legacy/unknown identity: the request-scoped resume established a
    /// plausible runtime rebind under the compatibility rules.
    case legacyRuntimeRebind
}

enum ResumeIdentityRejection: Error, Equatable {
    /// The response explicitly names a different durable conversation.
    case durableContradiction(selected: String, returned: String)
    /// The returned runtime id positively belongs to another catalog row.
    case foreignRuntimeOwnership(returned: String, ownerSessionID: String)
    /// The durable key the response wants to establish is positively labeled
    /// as another catalog row's stored id.
    case foreignDurableOwnership(returned: String, ownerSessionID: String)
}

extension ResumeIdentityRejection {
    /// The case alone, for a public log line: the ids it carries are
    /// session ids, which are logged hashed.
    var logLabel: String {
        switch self {
        case .durableContradiction: return "durableContradiction"
        case .foreignRuntimeOwnership: return "foreignRuntimeOwnership"
        case .foreignDurableOwnership: return "foreignDurableOwnership"
        }
    }
}

/// Admission gate for adopting a resume result into the selected
/// conversation. A rejected claim must not be adopted into
/// conversation-owned state — `activeSessionId`, selected conversation
/// identity, transcript, scroll canonical identity, conversation persistence
/// key, composer ownership, presentation cache, or resume-store selected
/// identity — and callers settle the reconciliation and fail the resume.
/// The refreshed session catalog itself is independent discovery state and
/// needs no rollback: a rejection blocks adoption, not discovery.
enum ConversationIdentityGate {
    static func admit(
        claim: ResumeIdentityClaim,
        selected: ConversationIdentity,
        catalog: [SessionSummary]
    ) -> Result<ResumeIdentityAdmission, ResumeIdentityRejection> {
        // 1. An explicit durable identity outranks everything. Matching is
        //    acceptance; a mismatch is a contradiction unless the app
        //    already positively associates the returned id with the selected
        //    conversation (mixed-generation catalogs can label the durable id
        //    differently while still meaning the same row).
        if let returnedDurable = normalized(claim.durableSessionID) {
            if returnedDurable == selected.durableSessionID {
                return .success(.durableIdentityMatch)
            }
            if selected.acceptedSessionIDs.contains(returnedDurable) {
                return .success(.knownAlias)
            }
            if let selectedDurable = selected.durableSessionID {
                return .failure(.durableContradiction(
                    selected: selectedDurable,
                    returned: returnedDurable
                ))
            }
            // No established durable id (runtime-only conversation): the
            // response's stored key ESTABLISHES the durable identity — the
            // same adoption the create path performs. Unless the claimed key
            // is positively labeled as another row's stored id; the gateway
            // is trusted for runtime→durable mapping, not for renaming a
            // known foreign conversation into this one.
            if let owner = catalog.first(where: { $0.storedSessionId == returnedDurable }),
               !selected.acceptedSessionIDs.contains(owner.id),
               !selected.acceptedSessionIDs.contains(returnedDurable) {
                return .failure(.foreignDurableOwnership(
                    returned: returnedDurable,
                    ownerSessionID: owner.id
                ))
            }
        }
        // 2. A returned runtime id the conversation already answers to.
        if selected.acceptedSessionIDs.contains(claim.runtimeSessionID) {
            return .success(.knownAlias)
        }
        // 3. Foreign ownership: the returned runtime id positively belongs
        //    to a different catalog conversation. Check EVERY matching row —
        //    the first match must not decide when rows share a runtime id.
        //    A row's nil stored id is "unknown", never "equal" to the
        //    selected conversation's (possibly also absent) durable id.
        let ownerRows = catalog.filter {
            $0.id == claim.runtimeSessionID || $0.alternateIds.contains(claim.runtimeSessionID)
        }
        for owner in ownerRows {
            let ownerIsSelected = selected.acceptedSessionIDs.contains(owner.id)
            let ownerStoredMatches = owner.storedSessionId.map { stored in
                stored == selected.durableSessionID
            } ?? false
            if ownerIsSelected || ownerStoredMatches {
                return .success(.knownAlias)
            }
        }
        if let owner = ownerRows.first {
            return .failure(.foreignRuntimeOwnership(
                returned: claim.runtimeSessionID,
                ownerSessionID: owner.id
            ))
        }
        // 4. Legacy compatibility: the gateway returned only a request-scoped
        //    runtime id the app has never seen. This is the historical
        //    behavior for every resume and stays permitted; the rebind is
        //    recorded as routing state, never as navigation.
        return .success(.legacyRuntimeRebind)
    }

    private static func normalized(_ sessionID: String?) -> String? {
        guard let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
