import Foundation

enum ChatResumeRestorationDestination: Equatable {
    case latest
    case snapshot(ChatScrollSnapshot)
    case pendingClarify(messageID: String, fallbackSnapshot: ChatScrollSnapshot?)
}

struct ChatResumeRestorationRequest: Identifiable, Equatable {
    let generation: UInt64
    let sessionKey: ChatScrollSessionKey
    let destination: ChatResumeRestorationDestination

    var id: UInt64 { generation }
}

struct ChatResumeAutomaticWorkToken: Equatable {
    fileprivate let cancellationEpoch: UInt64
}

@MainActor
final class ChatResumeCoordinator {
    private let store: ChatResumeStore
    private var pendingFallbackSelection = false
    private var pendingSessionKey: ChatScrollSessionKey?
    private var pendingFlushTask: Task<Void, Never>?
    private var viewportIsFrozen = false
    private var nextGeneration: UInt64 = 0
    private var automaticCancellationEpoch: UInt64 = 0

    private(set) var pendingRestoration: ChatResumeRestorationRequest?

    var behavior: ChatResumeBehavior {
        store.behavior
    }

    init(store: ChatResumeStore) {
        self.store = store
    }

    static func pendingClarifyMessageID(in messages: [ChatMessage]) -> String? {
        messages.last { message in
            guard let clarify = message.clarify, !clarify.isExpired else { return false }
            return clarify.questions.contains {
                $0.status == .pending || $0.status == .error
            }
        }?.id
    }

    func beginAutomaticWork() -> ChatResumeAutomaticWorkToken {
        ChatResumeAutomaticWorkToken(cancellationEpoch: automaticCancellationEpoch)
    }

    func isCurrent(_ token: ChatResumeAutomaticWorkToken) -> Bool {
        token.cancellationEpoch == automaticCancellationEpoch
    }

    func setBehavior(_ behavior: ChatResumeBehavior) {
        cancelViewportRestoration()
        store.setBehavior(behavior)
    }

    /// The conversation the user was in for this workspace profile — id AND
    /// kind. Restoration must act on the kind: a Bot Chat is not an ordinary
    /// conversation of the workspace that happened to be active when it was
    /// opened.
    func lastSession(for profile: String) -> SessionReference? {
        store.lastSession(for: profile)
    }

    func lastSessionID(for profile: String) -> String? {
        store.lastSessionID(for: profile)
    }

    func rememberSession(_ reference: SessionReference?, for profile: String) {
        store.setLastSession(reference, for: profile)
    }

    /// Reclassifies a stored reference in place (a legacy id-only selection
    /// that positive bot evidence now attributes to a Bot Chat). Returns the
    /// reference that must be used for restoration either way.
    func reclassifySession(
        _ reference: SessionReference,
        for profile: String,
        ownership: SessionBotOwnership
    ) -> SessionReference {
        guard let resolved = ownership.referenceIfBot(reference) else { return reference }
        if resolved != reference {
            store.setLastSession(resolved, for: profile)
        }
        return resolved
    }

    func missingSavedSessionID(
        in catalog: [SessionSummary],
        profile: String,
        purpose: ChatResumeSyncPurpose,
        botOwnedSessionIDs: Set<String> = [],
        savedSessionAliases: Set<String> = []
    ) -> String? {
        ChatResumeSessionResolver.missingSavedSessionID(
            in: catalog,
            behavior: store.behavior,
            purpose: purpose,
            savedSessionID: store.lastSessionID(for: profile),
            activeProfile: profile,
            botOwnedSessionIDs: botOwnedSessionIDs,
            savedSessionAliases: savedSessionAliases
        )
    }

    func selectTarget(
        in catalog: [SessionSummary],
        profile: String,
        purpose: ChatResumeSyncPurpose,
        currentSessionID: String?,
        botOwnedSessionIDs: Set<String> = [],
        savedSelectionIsAuthoritative: Bool = true
    ) -> SessionSummary? {
        let savedSessionID = store.lastSessionID(for: profile)
        let selected = ChatResumeSessionResolver.target(
            in: catalog,
            behavior: store.behavior,
            purpose: purpose,
            savedSessionID: savedSessionID,
            currentSessionID: currentSessionID,
            activeProfile: profile,
            botOwnedSessionIDs: botOwnedSessionIDs,
            savedSelectionIsAuthoritative: savedSelectionIsAuthoritative
        )

        guard purpose == .automaticReturn else { return selected }

        pendingRestoration = nil
        let savedSessionIsMissing = savedSessionID.map { savedSessionID in
            !catalog.contains { session in
                session.id == savedSessionID || session.alternateIds.contains(savedSessionID)
            }
        } ?? false
        pendingFallbackSelection = store.behavior == .continueWhereLeftOff && savedSessionIsMissing
        pendingSessionKey = selected.map {
            ChatScrollSessionKey(profile: profile, sessionID: $0.id)
        }.flatMap { $0.isValid ? $0 : nil }
        pendingFallbackSelection = pendingFallbackSelection && pendingSessionKey != nil
        // Freeze the viewport whenever we have a valid pending session.
        // If target is nil, preserve any existing freeze (e.g. set by
        // freezeViewport before the catalog loaded) rather than unfreezing,
        // which would let stale snapshots overwrite the pre-freeze state.
        if pendingSessionKey != nil {
            viewportIsFrozen = true
        }
        return selected
    }

    /// Records the same viewport-restoration ownership as `selectTarget` when
    /// a cold catalog has not indexed the saved session yet and AppState must
    /// resume that durable identity directly.
    func prepareDirectTarget(
        sessionID: String,
        profile: String,
        purpose: ChatResumeSyncPurpose
    ) {
        guard purpose == .automaticReturn else { return }
        pendingRestoration = nil
        let key = ChatScrollSessionKey(profile: profile, sessionID: sessionID)
        pendingSessionKey = key.isValid ? key : nil
        pendingFallbackSelection = false
        if pendingSessionKey != nil { viewportIsFrozen = true }
    }

    func recordViewport(_ snapshot: ChatScrollSnapshot, for key: ChatScrollSessionKey) {
        guard !viewportIsFrozen, key.isValid else { return }

        store.stageSnapshot(snapshot, for: key, at: Date())
        pendingFlushTask?.cancel()
        pendingFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.store.flush()
        }
    }

    func migrateSnapshot(from oldKey: ChatScrollSessionKey, to newKey: ChatScrollSessionKey) {
        store.migrateSnapshot(from: oldKey, to: newKey)
    }

    func migrateSessionIdentity(from oldKey: ChatScrollSessionKey, to newKey: ChatScrollSessionKey) {
        store.migrateSessionIdentity(from: oldKey, to: newKey)
    }

    func freezeViewport() {
        viewportIsFrozen = true
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        store.flush()
    }

    func captureViewportAndFreeze(
        _ snapshot: ChatScrollSnapshot?,
        for key: ChatScrollSessionKey?
    ) {
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        if let snapshot, let key, key.isValid {
            store.stageSnapshot(snapshot, for: key, at: Date())
        }
        viewportIsFrozen = true
        store.flush()
    }

    func unfreezeViewport() {
        viewportIsFrozen = false
    }

    /// Called when an automatic sync attempt ends without publishing a
    /// restoration request (reconcile failure, stale guard, exception).
    /// Clears pending state and unfreezes the viewport so scroll recording
    /// resumes. Does NOT cancel the automatic-work epoch so the reconnect
    /// retry can still proceed.
    func abandonPendingAutomaticSync() {
        pendingSessionKey = nil
        pendingFallbackSelection = false
        viewportIsFrozen = false
    }

    /// Like abandonPendingAutomaticSync but only acts if there was actually
    /// a pending session key. Used on success paths where reconciliationSettled
    /// returned nil — if there was no pending key, there's nothing to clean up
    /// and we must not unfreeze an existing freeze from a different source.
    func abandonPendingAutomaticSyncIfPending() {
        guard pendingSessionKey != nil else { return }
        pendingSessionKey = nil
        pendingFallbackSelection = false
        viewportIsFrozen = false
    }

    func reconciliationSettled(
        sessionKey: ChatScrollSessionKey,
        pendingClarifyMessageID: String? = nil
    ) -> ChatResumeRestorationRequest? {
        guard pendingSessionKey == sessionKey, pendingRestoration == nil else {
            // Mismatch: leave pendingSessionKey intact so the caller
            // (publishChatResumeRestorationIfReady) can detect it via
            // abandonPendingAutomaticSyncIfPending() and unfreeze.
            // If we clear it here, the caller can't distinguish "mismatch
            // that needs cleanup" from "no pending work at all".
            pendingFallbackSelection = false
            return nil
        }

        pendingSessionKey = nil
        let isFallbackSelection = pendingFallbackSelection
        pendingFallbackSelection = false
        let fallbackSnapshot: ChatScrollSnapshot?
        if isFallbackSelection || store.behavior == .latestActivity {
            fallbackSnapshot = nil
        } else if let snapshot = store.snapshot(for: sessionKey), !snapshot.followsLatest {
            fallbackSnapshot = snapshot
        } else {
            fallbackSnapshot = nil
        }

        let destination: ChatResumeRestorationDestination
        if let pendingClarifyMessageID, !pendingClarifyMessageID.isEmpty {
            destination = .pendingClarify(
                messageID: pendingClarifyMessageID,
                fallbackSnapshot: fallbackSnapshot
            )
        } else if let fallbackSnapshot {
            destination = .snapshot(fallbackSnapshot)
        } else {
            destination = .latest
        }

        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        let request = ChatResumeRestorationRequest(
            generation: nextGeneration,
            sessionKey: sessionKey,
            destination: destination
        )
        pendingRestoration = request
        viewportIsFrozen = true
        return request
    }

    func cancelViewportRestoration(
        invalidateAutomaticWork: Bool = true,
        keepViewportFrozen: Bool = false
    ) {
        if invalidateAutomaticWork {
            automaticCancellationEpoch &+= 1
            if automaticCancellationEpoch == 0 { automaticCancellationEpoch = 1 }
        }
        pendingFallbackSelection = false
        pendingSessionKey = nil
        pendingRestoration = nil
        viewportIsFrozen = keepViewportFrozen
    }

    func completeRestoration(generation: UInt64) {
        guard pendingRestoration?.generation == generation else { return }
        pendingRestoration = nil
        viewportIsFrozen = false
    }

    func abandonRestoration(generation: UInt64) {
        guard pendingRestoration?.generation == generation else { return }
        pendingRestoration = nil
        viewportIsFrozen = false
    }

    func isCurrent(generation: UInt64) -> Bool {
        pendingRestoration?.generation == generation
    }

    func clearResumeState() {
        cancelViewportRestoration()
        store.clearResumeState()
    }

    func removeSessions(profile: String, sessionIDs: [String]) {
        store.removeSessions(profile: profile, sessionIDs: sessionIDs)
        // Explicit deletion revokes restoration authority in memory as well
        // as on disk: a conversation deleted while an automatic restoration
        // targets it must never have that restoration published, completed,
        // or resurrected. Scoped strictly to the deleted identities — pending
        // work for any other conversation is untouched.
        let normalizedProfile = ChatScrollIdentityNormalization.profile(profile)
        let ids = Set(sessionIDs.compactMap(ChatScrollIdentityNormalization.sessionID))
        guard let normalizedProfile, !ids.isEmpty else { return }
        var invalidated = false
        if let pendingKey = pendingSessionKey,
           pendingKey.profile == normalizedProfile,
           ids.contains(pendingKey.sessionID) {
            // Staged (not yet published) automatic-return work for the
            // deleted conversation, including its fallback-selection state.
            pendingSessionKey = nil
            pendingFallbackSelection = false
            invalidated = true
        }
        if let restoration = pendingRestoration,
           restoration.sessionKey.profile == normalizedProfile,
           ids.contains(restoration.sessionKey.sessionID) {
            // A published request: clearing it makes isCurrent(generation:)
            // fail, so a late completion/abandon of the stale generation
            // cannot resurrect navigation into the deleted conversation.
            pendingRestoration = nil
            invalidated = true
        }
        guard invalidated else { return }
        // The deleted conversation can no longer own the freeze: unfreeze so
        // viewport recording resumes for whatever is selected next.
        viewportIsFrozen = false
        // Abort in-flight automatic work that could still publish navigation
        // for the deleted conversation. The epoch is deliberately coarse —
        // deletion is rare, an aborted automatic sync re-runs against the
        // live catalog, and per-conversation epochs would buy precision this
        // path never needs.
        automaticCancellationEpoch &+= 1
        if automaticCancellationEpoch == 0 { automaticCancellationEpoch = 1 }
    }

    func flush() {
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        store.flush()
    }
}
