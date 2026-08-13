import Foundation

/// Stores explicit session-level YOLO choices independently from the
/// profile-wide approval setting returned by Hermes.
@MainActor
final class SessionYoloStore {
    nonisolated static let defaultStorageKey = "conduit.sessionYolo.v1"

    private struct Payload: Codable {
        var version: Int
        var overrides: [String: [String: Bool]]
    }

    private static let schemaVersion = 1
    private let defaults: UserDefaults
    private let storageKey: String
    private var payload: Payload

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = SessionYoloStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           decoded.version == Self.schemaVersion {
            payload = decoded
        } else {
            payload = Payload(version: Self.schemaVersion, overrides: [:])
        }
    }

    func storedOverride(for profile: String, sessionID: String) -> Bool? {
        guard let key = normalizedKey(profile: profile, sessionID: sessionID) else {
            return nil
        }
        return payload.overrides[key.profile]?[key.sessionID]
    }

    func setOverride(_ enabled: Bool, for profile: String, sessionID: String) {
        guard let key = normalizedKey(profile: profile, sessionID: sessionID) else {
            return
        }
        var profileOverrides = payload.overrides[key.profile] ?? [:]
        profileOverrides[key.sessionID] = enabled
        payload.overrides[key.profile] = profileOverrides
        persist()
    }

    private func normalizedKey(profile: String, sessionID: String) -> ChatScrollSessionKey? {
        let key = ChatScrollSessionKey(profile: profile, sessionID: sessionID)
        return key.isValid ? key : nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
