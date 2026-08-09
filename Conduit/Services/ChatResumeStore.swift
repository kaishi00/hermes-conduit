import Foundation

final class ChatResumeStore {
    static let defaultStorageKey = "conduit.chatResume.v1"
    static let schemaVersion = 1
    static let maximumSnapshots = 100

    private struct StoredSnapshot: Codable, Equatable {
        let key: ChatScrollSessionKey
        let snapshot: ChatScrollSnapshot
        let updatedAt: Date
    }

    private struct Payload: Codable, Equatable {
        let version: Int
        var behavior: ChatResumeBehavior
        var lastSessionIDsByProfile: [String: String]
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
                lastSessionIDsByProfile: Self.normalizedLastSessionIDs(
                    defaults.dictionary(forKey: legacyActiveSessionsKey) as? [String: String] ?? [:]
                ),
                snapshots: []
            )
            persist()
            return
        }

        guard let data = defaults.data(forKey: storageKey),
              let storedPayload = try? JSONDecoder().decode(Payload.self, from: data),
              storedPayload.version == Self.schemaVersion else {
            payload = Self.emptyPayload
            persist()
            return
        }

        payload = Self.normalized(storedPayload)
        if payload != storedPayload {
            persist()
        }
    }

    var behavior: ChatResumeBehavior {
        payload.behavior
    }

    func setBehavior(_ behavior: ChatResumeBehavior) {
        payload.behavior = behavior
        persist()
    }

    func lastSessionID(for profile: String) -> String? {
        guard let normalizedProfile = Self.normalizedProfile(profile) else { return nil }
        return payload.lastSessionIDsByProfile[normalizedProfile]
    }

    func setLastSessionID(_ sessionID: String?, for profile: String) {
        guard let normalizedProfile = Self.normalizedProfile(profile) else { return }
        guard let sessionID else {
            payload.lastSessionIDsByProfile.removeValue(forKey: normalizedProfile)
            persist()
            return
        }
        let key = ChatScrollSessionKey(profile: normalizedProfile, sessionID: sessionID)
        guard key.isValid else { return }
        payload.lastSessionIDsByProfile[key.profile] = key.sessionID
        persist()
    }

    func snapshot(for key: ChatScrollSessionKey) -> ChatScrollSnapshot? {
        guard key.isValid else { return nil }
        return payload.snapshots.first(where: { $0.key == key })?.snapshot
    }

    func save(_ snapshot: ChatScrollSnapshot, for key: ChatScrollSessionKey, at updatedAt: Date) {
        guard key.isValid else { return }
        payload.snapshots.removeAll { $0.key == key }
        payload.snapshots.append(StoredSnapshot(key: key, snapshot: snapshot, updatedAt: updatedAt))
        payload.snapshots = Self.pruned(payload.snapshots)
        persist()
    }

    func migrateSnapshot(from oldKey: ChatScrollSessionKey, to newKey: ChatScrollSessionKey) {
        guard oldKey.isValid,
              newKey.isValid,
              oldKey != newKey,
              let source = payload.snapshots.first(where: { $0.key == oldKey }) else {
            return
        }
        save(source.snapshot, for: newKey, at: source.updatedAt)
    }

    func clearResumeState() {
        payload.lastSessionIDsByProfile = [:]
        payload.snapshots = []
        persist()
    }

    func flush() {
        persist()
        defaults.synchronize()
    }

    private static var emptyPayload: Payload {
        Payload(
            version: schemaVersion,
            behavior: .continueWhereLeftOff,
            lastSessionIDsByProfile: [:],
            snapshots: []
        )
    }

    private static func normalized(_ payload: Payload) -> Payload {
        Payload(
            version: schemaVersion,
            behavior: payload.behavior,
            lastSessionIDsByProfile: normalizedLastSessionIDs(payload.lastSessionIDsByProfile),
            snapshots: pruned(payload.snapshots)
        )
    }

    private static func normalizedLastSessionIDs(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [:]) { result, entry in
            let key = ChatScrollSessionKey(profile: entry.key, sessionID: entry.value)
            guard key.isValid else { return }
            result[key.profile] = key.sessionID
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
            .sorted { $0.updatedAt > $1.updatedAt }

        var seenKeys = Set<ChatScrollSessionKey>()
        return ordered.filter { seenKeys.insert($0.key).inserted }.prefix(maximumSnapshots).map { $0 }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
