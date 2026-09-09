import Foundation

/// Device-local choices. A nil character follows the profile's generated identity.
struct AgentAvatarSelection: Codable, Equatable {
    var character: AgentAvatarAppearance?
    var usesPhoto: Bool = false
    var photoRevision: UUID?
}

struct AgentAvatarAppearance: Codable, Equatable {
    var shape: AgentCharacterKind
    var color: AgentAvatarColor
    var accessory: AgentCharacterAccessoryKind

    static func generated(for profile: String) -> Self {
        let seed = AgentAvatarIdentity.seed(for: profile)
        return Self(shape: AgentAvatarIdentity.shape(for: seed),
                    color: AgentAvatarColor.allCases[Int((seed / 6) % 6)],
                    accessory: AgentAvatarIdentity.accessory(for: seed))
    }
}

enum AgentAvatarColor: String, CaseIterable, Codable {
    case violet, blue, green, teal, orange, rose
    var label: String { rawValue.capitalized }
    var paletteSeed: UInt64 { UInt64(Self.allCases.firstIndex(of: self)!) * 6 }
}

enum AgentAvatarSelectionStore {
    static let key = "conduit.profileAvatarSelections.v1"

    static func selections(from data: Data) -> [String: AgentAvatarSelection] {
        // Decode entries separately so an unknown future option cannot erase other profiles.
        guard let entries = try? JSONDecoder().decode([String: Data].self, from: data) else { return [:] }
        return entries.compactMapValues { try? JSONDecoder().decode(AgentAvatarSelection.self, from: $0) }
    }

    static func load(for profile: String, defaults: UserDefaults = .standard) -> AgentAvatarSelection? {
        selections(from: defaults.data(forKey: key) ?? Data())[profile]
    }

    static func save(_ selection: AgentAvatarSelection, for profile: String,
                     defaults: UserDefaults = .standard) throws {
        var entries = (try? JSONDecoder().decode([String: Data].self, from: defaults.data(forKey: key) ?? Data())) ?? [:]
        entries[profile] = try JSONEncoder().encode(selection)
        defaults.set(try JSONEncoder().encode(entries), forKey: key)
    }
}
