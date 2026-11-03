//
//  RichChecklistMemory.swift
//  Conduit
//
//  Ticks on a checklist card. In a chat they're kept on the host (the
//  plugin's /boards/checklists route), so every one of the user's devices
//  shows the same ones and Hermes hears what changed at the chat's next
//  turn; the phone keeps its own copy so a tick shows at once and survives
//  a lost connection, and sends it again when the card is next drawn.
//  Elsewhere (a call's screen) ticks stay on this phone.
//

import SwiftUI

/// Where a chat's checklists are kept on the host.
struct RichChecklistContext {
    /// The profile and chat, as one key for the phone's copy.
    let scope: String
    /// Every id the chat is known by.
    let sessionIDs: [String]
    /// The chat's ticks on the host, by checklist key.
    let read: @MainActor () async throws -> [String: [String]]
    /// Sends one checklist's whole state; answers the chat's ticks.
    let save: @MainActor (_ body: [String: Any]) async throws -> [String: [String]]

    static let capability = "board-checklists"
    static let path = "/api/plugins/conduit_push/boards/checklists"

    static func readPath(profile: String, sessionIDs: [String]) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
            + sessionIDs.map { URLQueryItem(name: "session", value: $0) }
        return path + "?" + (components.percentEncodedQuery ?? "")
    }

    static func savePath(profile: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        return path + "?" + (components.percentEncodedQuery ?? "")
    }

    /// The route's answer, read: each checklist's ticked items.
    static func ticks(_ answer: [String: Any]) -> [String: [String]] {
        var ticks: [String: [String]] = [:]
        for (key, value) in answer["ticks"] as? [String: Any] ?? [:] {
            if let items = value as? [String] { ticks[key] = items }
        }
        return ticks
    }
}

private struct RichChecklistContextKey: EnvironmentKey {
    static let defaultValue: RichChecklistContext? = nil
}

extension EnvironmentValues {
    /// The open chat's checklists on the host; nil where ticks stay on the phone.
    var richChecklistContext: RichChecklistContext? {
        get { self[RichChecklistContextKey.self] }
        set { self[RichChecklistContextKey.self] = newValue }
    }
}

@MainActor
final class RichChecklistMemory: ObservableObject {
    static let shared = RichChecklistMemory()

    static let localScope = "local"
    private static let defaultsKey = "richCards.checklistTicks"
    /// Checklists whose ticks are kept on the phone; the oldest go first.
    private static let keptLists = 300

    struct Entry: Codable, Equatable {
        /// Ticked items, compared without regard to case.
        var ticked: Set<String>
        var at: Date
        /// Changed here and not yet saved on the host.
        var unsent: Bool
        var items: [String]
        var title: String
    }

    @Published private(set) var entries: [String: Entry]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// The key a checklist's ticks are kept under, as the plugin's
    /// checklist_store.list_key: its live name, else its title, else
    /// "checklist", lowercased.
    static func listKey(for card: RichCard) -> String {
        for name in [card.live, card.title] {
            if let name {
                let clean = RichCardSchema.cleanText(name)
                if !clean.isEmpty { return String(String.UnicodeScalarView(clean.unicodeScalars.prefix(80))).lowercased() }
            }
        }
        return "checklist"
    }

    private static func id(_ scope: String, _ key: String) -> String { "\(scope)\u{1F}\(key)" }

    func ticked(scope: String, key: String) -> Set<String> {
        entries[Self.id(scope, key)]?.ticked ?? []
    }

    /// The host's ticks for the chat, taken over the phone's copy, unless
    /// a change made here hasn't reached the host yet: that one goes now.
    func refresh(context: RichChecklistContext?, key: String) async {
        guard let context else { return }
        let id = Self.id(context.scope, key)
        if let entry = entries[id], entry.unsent {
            await send(entry, key: key, context: context)
            return
        }
        guard let ticks = try? await context.read() else { return }
        apply(ticks, scope: context.scope)
    }

    func toggle(_ text: String, card: RichCard, key: String, context: RichChecklistContext?) {
        let scope = context?.scope ?? Self.localScope
        let id = Self.id(scope, key)
        var entry = entries[id] ?? Entry(ticked: [], at: .now, unsent: false, items: [], title: "")
        let folded = text.lowercased()
        if entry.ticked.contains(folded) {
            entry.ticked.remove(folded)
        } else {
            entry.ticked.insert(folded)
        }
        entry.at = .now
        entry.items = card.checklist.map(\.text)
        entry.title = card.title ?? ""
        entry.unsent = context != nil
        store(entry, id: id)
        guard let context else { return }
        Task { await send(entry, key: key, context: context) }
    }

    private func send(_ entry: Entry, key: String, context: RichChecklistContext) async {
        let body: [String: Any] = [
            "sessions": Array(context.sessionIDs.prefix(4)), "key": key, "title": entry.title,
            "items": entry.items, "ticked": entry.items.filter { entry.ticked.contains($0.lowercased()) },
        ]
        guard let ticks = try? await context.save(body) else { return }
        let id = Self.id(context.scope, key)
        // A tick made while this one was on its way goes next time.
        guard entries[id]?.at == entry.at else { return }
        var sent = entry
        sent.unsent = false
        store(sent, id: id)
        apply(ticks, scope: context.scope)
    }

    private func apply(_ ticks: [String: [String]], scope: String) {
        for (key, items) in ticks {
            let id = Self.id(scope, key)
            var entry = entries[id] ?? Entry(ticked: [], at: .now, unsent: false, items: [], title: "")
            guard !entry.unsent else { continue }
            let ticked = Set(items.map { $0.lowercased() })
            guard ticked != entry.ticked else { continue }
            entry.ticked = ticked
            store(entry, id: id)
        }
    }

    private func store(_ entry: Entry, id: String) {
        entries[id] = entry
        if entries.count > Self.keptLists, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
            entries.removeValue(forKey: oldest)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
