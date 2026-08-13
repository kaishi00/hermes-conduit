import Foundation
import OSLog

enum SessionYoloStoreDiagnostic: Equatable {
    case decodeFailure
    case unsupportedVersion(Int)
    case encodeFailure
}

private let sessionYoloStoreLog = Logger(
    subsystem: "com.milim.conduit",
    category: "SessionYoloStore"
)

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
    private let diagnosticHandler: (@MainActor (SessionYoloStoreDiagnostic) -> Void)?
    private var payload: Payload

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = SessionYoloStore.defaultStorageKey,
        diagnosticHandler: (@MainActor (SessionYoloStoreDiagnostic) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.diagnosticHandler = diagnosticHandler

        let loadedPayload: Payload
        let diagnostic: SessionYoloStoreDiagnostic?
        if let data = defaults.data(forKey: storageKey) {
            do {
                let decoded = try JSONDecoder().decode(Payload.self, from: data)
                if decoded.version == Self.schemaVersion {
                    loadedPayload = decoded
                    diagnostic = nil
                } else {
                    loadedPayload = Payload(version: Self.schemaVersion, overrides: [:])
                    diagnostic = .unsupportedVersion(decoded.version)
                }
            } catch {
                loadedPayload = Payload(version: Self.schemaVersion, overrides: [:])
                diagnostic = .decodeFailure
            }
        } else {
            loadedPayload = Payload(version: Self.schemaVersion, overrides: [:])
            diagnostic = nil
        }
        payload = loadedPayload
        if let diagnostic {
            report(diagnostic)
        }
    }

    func storedOverride(for profile: String, sessionID: String) -> Bool? {
        storedOverride(for: profile, sessionIDs: [sessionID])
    }

    func storedOverride(for profile: String, sessionIDs: [String]) -> Bool? {
        for sessionID in sessionIDs {
            guard let key = normalizedKey(profile: profile, sessionID: sessionID) else {
                continue
            }
            if let override = payload.overrides[key.profile]?[key.sessionID] {
                return override
            }
        }
        return nil
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

    func canonicalizeOverride(
        for profile: String,
        canonicalSessionID: String,
        aliases: [String]
    ) {
        guard let canonicalKey = normalizedKey(
            profile: profile,
            sessionID: canonicalSessionID
        ) else {
            return
        }

        var canonicalValue = payload.overrides[canonicalKey.profile]?[canonicalKey.sessionID]
        var changed = false
        for alias in aliases {
            guard let aliasKey = normalizedKey(profile: profile, sessionID: alias),
                  aliasKey != canonicalKey,
                  let aliasValue = payload.overrides[aliasKey.profile]?[aliasKey.sessionID] else {
                continue
            }

            if canonicalValue == nil {
                var profileOverrides = payload.overrides[canonicalKey.profile] ?? [:]
                profileOverrides[canonicalKey.sessionID] = aliasValue
                payload.overrides[canonicalKey.profile] = profileOverrides
                canonicalValue = aliasValue
            }
            payload.overrides[aliasKey.profile]?.removeValue(forKey: aliasKey.sessionID)
            if payload.overrides[aliasKey.profile]?.isEmpty == true {
                payload.overrides.removeValue(forKey: aliasKey.profile)
            }
            changed = true
        }

        if changed {
            persist()
        }
    }

    func clearOverride(for profile: String, sessionID: String) {
        clearOverride(for: profile, sessionIDs: [sessionID])
    }

    func clearOverride(for profile: String, sessionIDs: [String]) {
        var changed = false
        for sessionID in sessionIDs {
            guard let key = normalizedKey(profile: profile, sessionID: sessionID),
                  payload.overrides[key.profile]?[key.sessionID] != nil else {
                continue
            }
            payload.overrides[key.profile]?.removeValue(forKey: key.sessionID)
            if payload.overrides[key.profile]?.isEmpty == true {
                payload.overrides.removeValue(forKey: key.profile)
            }
            changed = true
        }
        if changed {
            persist()
        }
    }

    private func normalizedKey(profile: String, sessionID: String) -> ChatScrollSessionKey? {
        let key = ChatScrollSessionKey(profile: profile, sessionID: sessionID)
        return key.isValid ? key : nil
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(payload)
            defaults.set(data, forKey: storageKey)
        } catch {
            report(.encodeFailure)
        }
    }

    private func report(_ diagnostic: SessionYoloStoreDiagnostic) {
        switch diagnostic {
        case .decodeFailure:
            sessionYoloStoreLog.error("Unable to decode persisted session YOLO overrides; starting empty")
        case .unsupportedVersion(let version):
            sessionYoloStoreLog.error("Ignoring unsupported session YOLO override schema version \(version, privacy: .public)")
        case .encodeFailure:
            sessionYoloStoreLog.error("Unable to persist session YOLO overrides")
        }
        diagnosticHandler?(diagnostic)
    }
}
