import Foundation

@MainActor
final class ChatResumeStore {
    /// The storage key keeps its `v1` name deliberately: it is the key a
    /// previous build wrote, and the payload's own `version` field is what
    /// migrates. Bumping the KEY instead would silently strand every existing
    /// install's resume state.
    static let defaultStorageKey = "conduit.chatResume.v1"
    /// v2 adds the conversation KIND (and its profile scope) to the
    /// per-workspace selection, so restoration can tell a Bot Chat from an
    /// ordinary conversation. v1 payloads migrate their bare session ids to
    /// `.dashboard` references.
    static let schemaVersion = 2
    static let maximumSnapshots = 100

    private struct StoredSnapshot: Codable, Equatable {
        let key: ChatScrollSessionKey
        let snapshot: ChatScrollSnapshot
        let updatedAt: Date
    }

    /// The v1 payload shape, kept only to migrate it.
    private struct LegacyPayload: Codable, Equatable {
        let version: Int
        var behavior: ChatResumeBehavior
        var lastSessionIDsByProfile: [String: String]
        var snapshots: [StoredSnapshot]
    }

    private struct Payload: Codable, Equatable {
        let version: Int
        var behavior: ChatResumeBehavior
        /// The conversation the user was in, per dashboard workspace profile:
        /// id AND kind. A bot chat is recorded under the workspace that was
        /// active when it was opened — the workspace selection answers "what
        /// was I looking at here", never "which profile owns the session".
        var lastSessionByProfile: [String: SessionReference]
        var snapshots: [StoredSnapshot]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var payload: Payload

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = ChatResumeStore.defaultStorageKey,
        legacyActiveSessionsKey: String = "conduit.activeSessionIdsByProfile.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        guard defaults.object(forKey: storageKey) != nil else {
            payload = Payload(
                version: Self.schemaVersion,
                behavior: .continueWhereLeftOff,
                lastSessionByProfile: Self.migratedReferences(
                    from: defaults.dictionary(forKey: legacyActiveSessionsKey) as? [String: String] ?? [:]
                ),
                snapshots: []
            )
            persist()
            return
        }

        guard let data = defaults.data(forKey: storageKey) else {
            payload = Self.emptyPayload
            persist()
            return
        }

        if let storedPayload = try? JSONDecoder().decode(Payload.self, from: data),
           storedPayload.version == Self.schemaVersion {
            payload = Self.normalized(storedPayload)
            if payload != storedPayload {
                persist()
            }
            return
        }

        // A v1 (or unreadable) payload: migrate the bare session ids into
        // typed references. An unreadable payload keeps the historical
        // behavior — start clean — since a corrupt blob carries no identity
        // worth trusting.
        if let legacy = try? JSONDecoder().decode(LegacyPayload.self, from: data),
           legacy.version == 1 {
            payload = Self.normalized(Payload(
                version: Self.schemaVersion,
                behavior: legacy.behavior,
                lastSessionByProfile: Self.migratedReferences(
                    from: legacy.lastSessionIDsByProfile
                ),
                snapshots: legacy.snapshots
            ))
            persist()
            return
        }

        payload = Self.emptyPayload
        persist()
    }

    var behavior: ChatResumeBehavior {
        payload.behavior
    }

    func setBehavior(_ behavior: ChatResumeBehavior) {
        payload.behavior = behavior
        persist()
    }

    /// The conversation the user was in for this workspace profile, with its
    /// kind intact.
    func lastSession(for profile: String) -> SessionReference? {
        guard let normalizedProfile = Self.normalizedProfile(profile) else { return nil }
        return payload.lastSessionByProfile[normalizedProfile]
    }

    /// The persisted session id alone. Needed by identity comparisons (does
    /// the stored selection still name THIS conversation?), which is a
    /// different question from how it must be restored.
    func lastSessionID(for profile: String) -> String? {
        lastSession(for: profile)?.sessionID
    }

    /// Writes only a change: every chat open sets it, and a write to the
    /// defaults redraws each `@AppStorage` view.
    func setLastSession(_ reference: SessionReference?, for profile: String) {
        guard let normalizedProfile = Self.normalizedProfile(profile) else { return }
        guard let reference else {
            guard payload.lastSessionByProfile.removeValue(forKey: normalizedProfile) != nil else { return }
            persist()
            return
        }
        let key = ChatScrollSessionKey(
            profile: normalizedProfile,
            sessionID: reference.sessionID
        )
        guard key.isValid, let normalized = Self.normalized(reference),
              payload.lastSessionByProfile[key.profile] != normalized else { return }
        payload.lastSessionByProfile[key.profile] = normalized
        persist()
    }

    /// Records a conversation of this workspace's Sessions surface.
    ///
    /// FIXTURE-ONLY, and structural rather than documentary: a bare id cannot
    /// express a kind, so reaching for this in production would record a Bot
    /// Chat as an (untyped) ordinary conversation — the defect the v2 payload
    /// exists to prevent. Debug-only so the constraint cannot be relaxed by
    /// accident; tests reach it through `@testable import`.
    #if DEBUG
    func setLastSessionID(_ sessionID: String?, for profile: String) {
        guard let sessionID else {
            setLastSession(nil, for: profile)
            return
        }
        guard let normalizedProfile = Self.normalizedProfile(profile) else { return }
        setLastSession(.dashboard(profile: normalizedProfile, sessionID: sessionID), for: profile)
    }
    #endif

    func snapshot(for key: ChatScrollSessionKey) -> ChatScrollSnapshot? {
        guard key.isValid else { return nil }
        return payload.snapshots.first(where: { $0.key == key })?.snapshot
    }

    func save(_ snapshot: ChatScrollSnapshot, for key: ChatScrollSessionKey, at updatedAt: Date) {
        stageSnapshot(snapshot, for: key, at: updatedAt)
        persist()
    }

    func stageSnapshot(_ snapshot: ChatScrollSnapshot, for key: ChatScrollSessionKey, at updatedAt: Date) {
        guard key.isValid else { return }
        payload.snapshots.removeAll { $0.key == key }
        payload.snapshots.append(StoredSnapshot(key: key, snapshot: snapshot, updatedAt: updatedAt))
        payload.snapshots = Self.pruned(payload.snapshots)
    }

    func migrateSnapshot(from oldKey: ChatScrollSessionKey, to newKey: ChatScrollSessionKey) {
        guard migrateSnapshotInPayload(from: oldKey, to: newKey) else { return }
        persist()
    }

    func migrateSessionIdentity(from oldKey: ChatScrollSessionKey, to newKey: ChatScrollSessionKey) {
        guard oldKey.isValid,
              newKey.isValid,
              oldKey.profile == newKey.profile,
              oldKey != newKey else { return }

        let migratedSnapshot = migrateSnapshotInPayload(from: oldKey, to: newKey)
        let migratedLastSession: Bool
        if let existing = payload.lastSessionByProfile[oldKey.profile],
           existing.sessionID == oldKey.sessionID {
            payload.lastSessionByProfile[oldKey.profile] = SessionReference(
                kind: existing.kind,
                scopeProfile: existing.scopeProfile,
                botName: existing.botName,
                botLabel: existing.botLabel,
                sessionID: newKey.sessionID,
                isUnverified: existing.isUnverified
            )
            migratedLastSession = true
        } else {
            migratedLastSession = false
        }

        if migratedSnapshot || migratedLastSession {
            persist()
        }
    }

    func clearResumeState() {
        payload.lastSessionByProfile = [:]
        payload.snapshots = []
        persist()
    }

    /// Removes every trace of the given sessions inside `profile`: their
    /// scroll snapshots, and the profile's last-selected pointer when it
    /// names one of them. The delete path calls this so a deleted
    /// conversation cannot leave restorable state behind under any of its
    /// identities.
    func removeSessions(profile: String, sessionIDs: [String]) {
        let normalizedProfile = ChatScrollIdentityNormalization.profile(profile)
        let ids = Set(sessionIDs.compactMap(ChatScrollIdentityNormalization.sessionID))
        guard let normalizedProfile, !ids.isEmpty else { return }
        var changed = false
        let before = payload.snapshots.count
        payload.snapshots.removeAll {
            $0.key.profile == normalizedProfile && ids.contains($0.key.sessionID)
        }
        changed = changed || payload.snapshots.count != before
        if let last = payload.lastSessionByProfile[normalizedProfile],
           ids.contains(last.sessionID) {
            payload.lastSessionByProfile.removeValue(forKey: normalizedProfile)
            changed = true
        }
        if changed {
            persist()
        }
    }

    func flush() {
        persist()
    }

    private static var emptyPayload: Payload {
        Payload(
            version: schemaVersion,
            behavior: .continueWhereLeftOff,
            lastSessionByProfile: [:],
            snapshots: []
        )
    }

    @discardableResult
    private func migrateSnapshotInPayload(
        from oldKey: ChatScrollSessionKey,
        to newKey: ChatScrollSessionKey
    ) -> Bool {
        guard oldKey.isValid,
              newKey.isValid,
              oldKey != newKey,
              let source = payload.snapshots.first(where: { $0.key == oldKey }) else {
            return false
        }
        payload.snapshots.removeAll { $0.key == oldKey }
        payload.snapshots.append(
            StoredSnapshot(key: newKey, snapshot: source.snapshot, updatedAt: source.updatedAt)
        )
        payload.snapshots = Self.pruned(payload.snapshots)
        return true
    }

    private static func normalized(_ payload: Payload) -> Payload {
        Payload(
            version: schemaVersion,
            behavior: payload.behavior,
            lastSessionByProfile: normalizedLastSessions(payload.lastSessionByProfile),
            snapshots: pruned(payload.snapshots)
        )
    }

    /// A stored reference is trusted only as far as its own validity goes: its
    /// session id is normalized the way every comparison normalizes it (an
    /// untrimmed id would survive here and then fail the delete/not-found
    /// equality fences, leaving restorable state for a deleted conversation),
    /// and a `.bot` reference is repaired to name its own scope — nil when no
    /// scope survives, in which case the entry is dropped rather than kept
    /// half-addressed.
    ///
    /// CASE IS PRESERVED for the scope. This value is not a dictionary key: it
    /// becomes the `profile` parameter of `session.resume` and of the transcript
    /// hydration, and the gateway keys its per-profile store by the EXACT name.
    /// Case-folding belongs to `ChatScrollSessionKey` (which the caller derives
    /// from the same reference), never to a profile name that will be sent over
    /// RPC — the dashboard paths pass `activeProfile` verbatim for the same
    /// reason.
    private static func normalized(_ reference: SessionReference) -> SessionReference? {
        guard let sessionID = ChatScrollIdentityNormalization.sessionID(reference.sessionID) else {
            return nil
        }
        guard reference.kind == .bot else {
            return SessionReference(
                kind: .dashboard,
                scopeProfile: reference.scopeProfile.trimmingCharacters(in: .whitespacesAndNewlines),
                botName: nil,
                botLabel: nil,
                sessionID: sessionID,
                isUnverified: reference.isUnverified
            )
        }
        guard let scope = Self.rpcProfileName(reference.botName ?? reference.scopeProfile) else {
            return nil
        }
        return SessionReference(
            kind: .bot,
            scopeProfile: scope,
            botName: scope,
            botLabel: reference.botLabel,
            sessionID: sessionID,
            isUnverified: false
        )
    }

    /// A profile name destined for an RPC: whitespace-trimmed, spelling
    /// PRESERVED. Nil when nothing usable remains.
    static func rpcProfileName(_ profile: String?) -> String? {
        let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedLastSessions(
        _ values: [String: SessionReference]
    ) -> [String: SessionReference] {
        // `sortedEntries`, NOT `normalized`: a local named `normalized` shadows
        // the static repair function this closure calls, which some Swift
        // versions reject as "cannot call value of non-function type".
        let sortedEntries = values.compactMap { entry -> (String, SessionReference)? in
            let key = ChatScrollSessionKey(
                profile: entry.key,
                sessionID: entry.value.sessionID
            )
            guard key.isValid, let reference = normalized(entry.value) else { return nil }
            return (key.profile, reference)
        }.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1.sessionID < rhs.1.sessionID
        }
        return sortedEntries.reduce(into: [:]) { result, entry in
            if result[entry.0] == nil {
                result[entry.0] = entry.1
            }
        }
    }

    /// v1 → v2: a bare session id carries no kind, so it migrates as an
    /// ordinary conversation of its workspace. A reference that actually
    /// named a Bot Chat is reclassified by the restore path the first time
    /// positive bot evidence is available
    /// (`SessionBotOwnership.referenceIfBot`).
    ///
    /// Colliding profile spellings collapse deterministically (lexicographic
    /// profile, then session id) — the same rule the id-only store used, so a
    /// degraded cache cannot resolve differently between launches during
    /// dictionary iteration order.
    private static func migratedReferences(
        from ids: [String: String]
    ) -> [String: SessionReference] {
        let candidates: [(profile: String, sessionID: String)] = ids.compactMap { entry in
            let key = ChatScrollSessionKey(profile: entry.key, sessionID: entry.value)
            guard key.isValid else { return nil }
            return (key.profile, key.sessionID)
        }.sorted { lhs, rhs in
            if lhs.profile != rhs.profile { return lhs.profile < rhs.profile }
            return lhs.sessionID < rhs.sessionID
        }
        return candidates.reduce(into: [:]) { result, candidate in
            guard result[candidate.profile] == nil else { return }
            result[candidate.profile] = .dashboard(
                profile: candidate.profile,
                sessionID: candidate.sessionID,
                isUnverified: true
            )
        }
    }

    private static func normalizedProfile(_ profile: String) -> String? {
        let key = ChatScrollSessionKey(profile: profile, sessionID: "profile-normalization")
        return key.isValid ? key.profile : nil
    }

    private static func pruned(_ snapshots: [StoredSnapshot]) -> [StoredSnapshot] {
        let ordered = snapshots
            .map { snapshot in
                StoredSnapshot(
                    key: ChatScrollSessionKey(
                        profile: snapshot.key.profile,
                        sessionID: snapshot.key.sessionID
                    ),
                    snapshot: snapshot.snapshot,
                    updatedAt: snapshot.updatedAt
                )
            }
            .filter { $0.key.isValid }
            .sorted(by: isOrderedBefore)

        var seenKeys = Set<ChatScrollSessionKey>()
        return ordered.filter { seenKeys.insert($0.key).inserted }.prefix(maximumSnapshots).map { $0 }
    }

    private static func isOrderedBefore(_ lhs: StoredSnapshot, _ rhs: StoredSnapshot) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.key.profile != rhs.key.profile { return lhs.key.profile < rhs.key.profile }
        if lhs.key.sessionID != rhs.key.sessionID { return lhs.key.sessionID < rhs.key.sessionID }
        return isOrderedBefore(lhs.snapshot, rhs.snapshot)
    }

    private static func isOrderedBefore(_ lhs: ChatScrollSnapshot, _ rhs: ChatScrollSnapshot) -> Bool {
        if let result = optionalIsOrderedBefore(lhs.anchorMessageID, rhs.anchorMessageID) {
            return result
        }
        if lhs.followsLatest != rhs.followsLatest { return !lhs.followsLatest }
        if let result = optionalIsOrderedBefore(
            lhs.anchorMetadata?.fingerprint,
            rhs.anchorMetadata?.fingerprint
        ) {
            return result
        }
        if let result = optionalIsOrderedBefore(
            lhs.anchorMetadata?.duplicateCount,
            rhs.anchorMetadata?.duplicateCount
        ) {
            return result
        }
        return optionalIsOrderedBefore(lhs.anchorSourceMessageID, rhs.anchorSourceMessageID) ?? false
    }

    private static func optionalIsOrderedBefore<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (.some(lhs), .some(rhs)):
            guard lhs != rhs else { return nil }
            return lhs < rhs
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
