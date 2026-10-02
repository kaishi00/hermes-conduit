//
//  CarPlayPreferences.swift
//  Conduit
//
//  On-device CarPlay settings, edited in Settings > Voice on the phone:
//  the shortcuts the car's Shortcuts grid offers, and whether the voice
//  screen plays its status sounds. Device-wide, like the car itself.
//

import Combine
import Foundation

/// A prompt the driver starts with one tap. It runs as a Voice Job, and the
/// result is spoken in the conversation the tap opens.
struct CarPlayShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var prompt: String

    init(id: UUID = UUID(), title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

@MainActor
final class CarPlayPreferences: ObservableObject {
    static let shared = CarPlayPreferences()

    /// CarPlay's grid template shows at most eight buttons.
    static let maximumShortcuts = 8
    static let shortcutsKey = "conduit.carplay.shortcuts.v1"
    static let soundsKey = "conduit.carplay.sounds.v1"

    @Published private(set) var shortcuts: [CarPlayShortcut]
    @Published private(set) var playsSounds: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.shortcutsKey),
           let decoded = try? JSONDecoder().decode([CarPlayShortcut].self, from: data) {
            shortcuts = Array(decoded.prefix(Self.maximumShortcuts))
        } else {
            shortcuts = []
        }
        playsSounds = defaults.object(forKey: Self.soundsKey) as? Bool ?? true
    }

    var canAddShortcut: Bool { shortcuts.count < Self.maximumShortcuts }

    /// Adds a shortcut, or replaces the one with the same id. Blank titles
    /// or prompts are refused.
    @discardableResult
    func save(_ shortcut: CarPlayShortcut) -> Bool {
        var cleaned = shortcut
        cleaned.title = shortcut.title.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.prompt = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.title.isEmpty, !cleaned.prompt.isEmpty else { return false }
        var updated = shortcuts
        if let index = updated.firstIndex(where: { $0.id == cleaned.id }) {
            updated[index] = cleaned
        } else {
            guard canAddShortcut else { return false }
            updated.append(cleaned)
        }
        store(updated)
        return true
    }

    func delete(id: UUID) {
        store(shortcuts.filter { $0.id != id })
    }

    func setPlaysSounds(_ enabled: Bool) {
        playsSounds = enabled
        defaults.set(enabled, forKey: Self.soundsKey)
    }

    private func store(_ updated: [CarPlayShortcut]) {
        shortcuts = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.shortcutsKey)
        }
    }
}
