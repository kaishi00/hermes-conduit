//
//  SessionStars.swift
//  Conduit
//
//  Starred chats (#757): a working list kept apart from pins. Pins are for
//  the chats opened every day; a star marks one being worked on, and the
//  Chats list's Starred filter lists them. Hermes has no flag for it, so
//  stars stay on this phone, per profile, under the conversation's lineage
//  id like a pin, so a compacted chat keeps its star.
//

import Foundation

struct SessionStars: Equatable {
    static let storageKey = "conduit.starredSessionIdsByProfile.v1"

    private(set) var idsByProfile: [String: [String]]

    init(idsByProfile: [String: [String]] = [:]) {
        self.idsByProfile = idsByProfile.filter { !$0.value.isEmpty }
    }

    init(defaults: UserDefaults) {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            self.init()
            return
        }
        self.init(idsByProfile: stored)
    }

    func save(to defaults: UserDefaults) {
        if idsByProfile.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(idsByProfile) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func isStarred(_ session: SessionSummary, profile: String) -> Bool {
        guard let ids = idsByProfile[profile] else { return false }
        let sessionIDs = SessionPinSync.pinIDs(for: session)
        return ids.contains { sessionIDs.contains($0) }
    }

    mutating func set(_ session: SessionSummary, starred: Bool, profile: String) {
        let sessionIDs = SessionPinSync.pinIDs(for: session)
        var ids = idsByProfile[profile] ?? []
        ids.removeAll { sessionIDs.contains($0) }
        if starred { ids.append(SessionPinSync.pinID(for: session)) }
        idsByProfile[profile] = ids.isEmpty ? nil : ids
    }

    mutating func forget(profile: String) {
        idsByProfile.removeValue(forKey: profile)
    }
}
