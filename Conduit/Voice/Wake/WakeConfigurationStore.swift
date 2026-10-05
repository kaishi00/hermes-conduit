//
//  WakeConfigurationStore.swift
//  Conduit
//

import Foundation

struct WakeProfilePreferences: Codable, Equatable {
    var enabledPhrases: [String]
    var startsFreshConversation: Bool

    init(enabledPhrases: [String] = [], startsFreshConversation: Bool = true) {
        self.enabledPhrases = enabledPhrases
        self.startsFreshConversation = startsFreshConversation
    }
}

/// Wake phrases are intentionally device-local: they control local microphone
/// inference and never become Hermes profile configuration.
final class WakeConfigurationStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private var values: [WakeProfileKey: WakeProfilePreferences]

    /// Device-wide: keep listening while the iPhone plays through CarPlay,
    /// recording from the iPhone's own microphone. On by default; turning it
    /// off stops wake listening on CarPlay entirely.
    var listensOnCarPlay: Bool {
        didSet {
            guard listensOnCarPlay != oldValue else { return }
            defaults.set(listensOnCarPlay, forKey: carPlayKey)
        }
    }

    /// Device-wide: keep listening while another app plays audio (music, a
    /// podcast). Off by default: recording, even mixed, moves that audio onto
    /// a record route where iOS can play it in mono and drop it briefly, so
    /// wake waits for it to stop instead.
    var listensOverOtherAudio: Bool {
        didSet {
            guard listensOverOtherAudio != oldValue else { return }
            defaults.set(listensOverOtherAudio, forKey: otherAudioKey)
        }
    }

    private var carPlayKey: String { storageKey + ".listensOnCarPlay" }
    private var otherAudioKey: String { storageKey + ".listensOverOtherAudio" }

    init(defaults: UserDefaults = .standard, storageKey: String = "conduit.wakeConfiguration.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        values = Self.decode(defaults.data(forKey: storageKey))
        listensOnCarPlay = defaults.object(forKey: storageKey + ".listensOnCarPlay") as? Bool ?? true
        listensOverOtherAudio = defaults.object(forKey: storageKey + ".listensOverOtherAudio") as? Bool ?? false
    }

    func preferences(for key: WakeProfileKey) -> WakeProfilePreferences {
        values[key] ?? WakeProfilePreferences()
    }

    func save(_ preferences: WakeProfilePreferences, for key: WakeProfileKey) {
        values[key] = WakeProfilePreferences(
            enabledPhrases: Self.uniquePhrases(preferences.enabledPhrases),
            startsFreshConversation: preferences.startsFreshConversation
        )
        persist()
    }

    func removePreferences(for key: WakeProfileKey) {
        values.removeValue(forKey: key)
        persist()
    }

    func enabledBindings() -> [WakePhraseBinding] {
        values.flatMap { key, preferences in
            preferences.enabledPhrases.map {
                WakePhraseBinding(key: key, phrase: $0, startsFreshConversation: preferences.startsFreshConversation)
            }
        }
        .sorted { $0.id < $1.id }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(values), forKey: storageKey)
    }

    private static func decode(_ data: Data?) -> [WakeProfileKey: WakeProfilePreferences] {
        guard let data, let decoded = try? JSONDecoder().decode([WakeProfileKey: WakeProfilePreferences].self, from: data) else { return [:] }
        return decoded
    }

    private static func uniquePhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        return phrases.compactMap { phrase in
            let normalized = WakePhraseCompiler.normalize(phrase)
            return normalized.isEmpty || !seen.insert(normalized).inserted ? nil : normalized
        }
    }
}
