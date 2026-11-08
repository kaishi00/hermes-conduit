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

    /// The phone's key for a chat's checklists: its profile and every id
    /// it's known by, which grows as the chat's ids are confirmed.
    static func scope(profile: String, sessionIDs: [String]) -> String {
        "\(profile)\u{1E}\(sessionIDs.joined(separator: "\u{1D}"))"
    }

    /// A chat scope's profile and ids; nil for any other scope.
    static func parts(of scope: String) -> (profile: String, sessionIDs: Set<String>)? {
        let halves = scope.split(separator: "\u{1E}", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let ids = Set(halves[1].split(separator: "\u{1D}").map(String.init))
        return ids.isEmpty ? nil : (String(halves[0]), ids)
    }
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

private struct RichChecklistInChatKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The open chat's checklists on the host; nil where ticks stay on the phone.
    var richChecklistContext: RichChecklistContext? {
        get { self[RichChecklistContextKey.self] }
        set { self[RichChecklistContextKey.self] = newValue }
    }

    /// A chat's or a saved call's checklist: ticked only where the host
    /// keeps its ticks, so one in the saved copy, a chat on its way or a
    /// saved call reads but can't be ticked (its ticks would land on the
    /// live call screen's, and never reach the chat).
    var richChecklistInChat: Bool {
        get { self[RichChecklistInChatKey.self] }
        set { self[RichChecklistInChatKey.self] = newValue }
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
        /// Ticks made here, oldest first, still to reach the host.
        var changes: [Change]?
    }

    struct Change: Codable, Equatable {
        let item: String
        let ticked: Bool
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
        carryOver(to: context, key: key)
        let id = Self.id(context.scope, key)
        if let entry = entries[id], entry.unsent {
            await send(entry, key: key, context: context)
            return
        }
        // A tick made while the read was on its way is newer than its answer.
        let before = entries.mapValues(\.at)
        guard let ticks = try? await context.read() else { return }
        apply(ticks, scope: context.scope, unchangedSince: before)
    }

    func toggle(_ text: String, card: RichCard, key: String, context: RichChecklistContext?) {
        let scope = context?.scope ?? Self.localScope
        if let context { carryOver(to: context, key: key) }
        let id = Self.id(scope, key)
        var entry = entries[id] ?? Entry(ticked: [], at: .now, unsent: false, items: [], title: "")
        let folded = text.lowercased()
        let ticks = !entry.ticked.contains(folded)
        if ticks {
            entry.ticked.insert(folded)
        } else {
            entry.ticked.remove(folded)
        }
        entry.at = .now
        entry.items = card.checklist.map(\.text)
        entry.title = card.title ?? ""
        if context != nil {
            entry.unsent = true
            entry.changes = (entry.changes ?? []) + [Change(item: text, ticked: ticks)]
        }
        store(entry, id: id)
        guard let context else { return }
        Task { await send(entry, key: key, context: context) }
    }

    /// The chat's ids grow while it's open (its durable id confirmed, an
    /// alias read from the catalog, a Bot Chat's ids from the roster), and
    /// with them its scope. This checklist kept under the chat's earlier
    /// ids, the same profile's with any id in common, moves to the new
    /// scope: ticks not yet sent go on to the host from there, after any
    /// made under it, and the others show until the host's read lands.
    private func carryOver(to context: RichChecklistContext, key: String) {
        let id = Self.id(context.scope, key)
        guard let profile = RichChecklistContext.parts(of: context.scope)?.profile else { return }
        let ids = Set(context.sessionIDs)
        let suffix = "\u{1F}\(key)"
        let earlier = entries.filter { other, _ in
            guard other != id, other.hasSuffix(suffix),
                  let parts = RichChecklistContext.parts(of: String(other.dropLast(suffix.count)))
            else { return false }
            return parts.profile == profile && !parts.sessionIDs.isDisjoint(with: ids)
        }
        guard !earlier.isEmpty else { return }
        for other in earlier.keys { entries.removeValue(forKey: other) }
        // Oldest first, the new scope's own copy last: it's the newest.
        var sources = earlier.values.sorted { $0.at < $1.at }
        if let existing = entries[id] { sources.append(existing) }
        var entry = sources.removeLast()
        if sources.contains(where: \.unsent) {
            // Every tick not yet sent goes, in the order made; the last one
            // made to an item is the one it shows.
            let changes = sources.filter(\.unsent).flatMap { $0.changes ?? [] } + (entry.changes ?? [])
            for change in changes {
                if change.ticked {
                    entry.ticked.insert(change.item.lowercased())
                } else {
                    entry.ticked.remove(change.item.lowercased())
                }
            }
            entry.changes = changes.isEmpty ? nil : changes
            entry.unsent = true
            entry.at = max(entry.at, sources.map(\.at).max() ?? entry.at)
            // A copy the host's read made has no items or title to send.
            if entry.items.isEmpty, let items = sources.last(where: { !$0.items.isEmpty })?.items { entry.items = items }
            if entry.title.isEmpty, let title = sources.last(where: { !$0.title.isEmpty })?.title { entry.title = title }
        }
        // Otherwise the newest copy shows until the host's read lands.
        store(entry, id: id)
    }

    /// Checklists whose ticks are on their way to the host.
    private var sending: Set<String> = []

    /// Sends the ticks made here one after another, each applied on the
    /// host to the newest ticks any device saved, so two quick taps arrive
    /// in order and a tick from elsewhere is kept.
    private func send(_ entry: Entry, key: String, context: RichChecklistContext) async {
        let id = Self.id(context.scope, key)
        guard !sending.contains(id) else { return }
        sending.insert(id)
        defer { sending.remove(id) }
        while let current = entries[id], current.unsent {
            var body: [String: Any] = [
                "sessions": Array(context.sessionIDs.prefix(4)), "key": key, "title": current.title,
                "items": current.items,
            ]
            let change = current.changes?.first
            if let change {
                body["change"] = ["item": change.item, "ticked": change.ticked]
            } else {
                body["ticked"] = current.items.filter { current.ticked.contains($0.lowercased()) }
            }
            guard let ticks = try? await context.save(body), var sent = entries[id] else { return }
            if change != nil, sent.changes?.first == change {
                sent.changes?.removeFirst()
            }
            if sent.changes?.isEmpty ?? true {
                sent.unsent = false
                sent.changes = nil
                store(sent, id: id)
                apply(ticks, scope: context.scope)
            } else {
                store(sent, id: id)
            }
        }
    }

    private func apply(_ ticks: [String: [String]], scope: String, unchangedSince: [String: Date]? = nil) {
        for (key, items) in ticks {
            let id = Self.id(scope, key)
            if let unchangedSince, entries[id]?.at != unchangedSince[id] { continue }
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
        // The oldest list goes first, one the host has before one it doesn't.
        if entries.count > Self.keptLists,
           let oldest = entries.min(by: { ($0.value.unsent ? 1 : 0, $0.value.at) < ($1.value.unsent ? 1 : 0, $1.value.at) })?.key {
            entries.removeValue(forKey: oldest)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
