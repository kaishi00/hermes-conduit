import Foundation

enum ChatResumeRestorationDestination: Equatable {
    case latest
    case snapshot(ChatScrollSnapshot)
}

struct ChatResumeRestorationRequest: Identifiable, Equatable {
    let generation: UInt64
    let sessionKey: ChatScrollSessionKey
    let destination: ChatResumeRestorationDestination

    var id: UInt64 { generation }
}

@MainActor
final class ChatResumeCoordinator {
    private let store: ChatResumeStore
    private var pendingFallbackSelection = false
    private var pendingSessionKey: ChatScrollSessionKey?
    private var pendingFlushTask: Task<Void, Never>?
    private var viewportIsFrozen = false
    private var nextGeneration: UInt64 = 0

    private(set) var pendingRestoration: ChatResumeRestorationRequest?

    var behavior: ChatResumeBehavior {
        store.behavior
    }

    init(store: ChatResumeStore) {
        self.store = store
    }

    func setBehavior(_ behavior: ChatResumeBehavior) {
        cancelRestoration()
        store.setBehavior(behavior)
    }

    func lastSessionID(for profile: String) -> String? {
        store.lastSessionID(for: profile)
    }

    func rememberSessionID(_ sessionID: String?, for profile: String) {
        store.setLastSessionID(sessionID, for: profile)
    }

    func selectTarget(
        in catalog: [SessionSummary],
        profile: String,
        purpose: ChatResumeSyncPurpose,
        currentSessionID: String?
    ) -> SessionSummary? {
        let savedSessionID = store.lastSessionID(for: profile)
        let selected = ChatResumeSessionResolver.target(
            in: catalog,
            behavior: store.behavior,
            purpose: purpose,
            savedSessionID: savedSessionID,
            currentSessionID: currentSessionID
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
        viewportIsFrozen = pendingSessionKey != nil
        return selected
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

    func freezeViewport() {
        viewportIsFrozen = true
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        store.flush()
    }

    func reconciliationSettled(sessionKey: ChatScrollSessionKey) -> ChatResumeRestorationRequest? {
        guard pendingSessionKey == sessionKey, pendingRestoration == nil else { return nil }

        pendingSessionKey = nil
        let isFallbackSelection = pendingFallbackSelection
        pendingFallbackSelection = false
        let destination: ChatResumeRestorationDestination
        if isFallbackSelection || store.behavior == .latestActivity {
            destination = .latest
        } else if let snapshot = store.snapshot(for: sessionKey), !snapshot.followsLatest {
            destination = .snapshot(snapshot)
        } else {
            destination = .latest
        }

        nextGeneration &+= 1
        let request = ChatResumeRestorationRequest(
            generation: nextGeneration,
            sessionKey: sessionKey,
            destination: destination
        )
        pendingRestoration = request
        viewportIsFrozen = true
        return request
    }

    func cancelRestoration() {
        pendingFallbackSelection = false
        pendingSessionKey = nil
        pendingRestoration = nil
        viewportIsFrozen = false
    }

    func completeRestoration(generation: UInt64) {
        guard pendingRestoration?.generation == generation else { return }
        pendingRestoration = nil
        viewportIsFrozen = false
    }

    func isCurrent(generation: UInt64) -> Bool {
        pendingRestoration?.generation == generation
    }

    func clearResumeState() {
        cancelRestoration()
        store.clearResumeState()
    }

    func flush() {
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        store.flush()
    }
}
