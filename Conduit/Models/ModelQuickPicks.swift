//
//  ModelQuickPicks.swift
//  Conduit
//
//  The model sheet's Quick picks: models the person pinned, then the ones
//  they switched between lately, so a switch rarely needs the full list of
//  providers (Eric, 2026-11-08). Kept per dashboard on this device, like
//  the models hidden with Edit.
//

import Foundation

/// A model as Quick picks keep it: the catalog row's id under the provider
/// that serves it, since several providers often list the same model.
struct ModelQuickPick: Codable, Hashable {
    var provider: String
    var model: String
}

struct ModelQuickPicks: Codable, Equatable {
    /// Recent models kept, newest first.
    static let recentLimit = 8
    /// Recent models the sheet shows under the pinned ones.
    static let recentShown = 3

    var pinned: [ModelQuickPick] = []
    var recent: [ModelQuickPick] = []

    func isPinned(model: String, provider: ProviderInfo) -> Bool {
        pinned.contains { $0.model == model && provider.matches($0.provider) }
    }

    /// Pins a model at the end of the pinned ones, or unpins it.
    mutating func togglePin(model: String, provider: ProviderInfo) {
        if isPinned(model: model, provider: provider) {
            pinned.removeAll { $0.model == model && provider.matches($0.provider) }
        } else {
            pinned.append(ModelQuickPick(provider: provider.name, model: model))
        }
    }

    /// A switch from `previous` to `current`: both lead the recent models,
    /// the one switched to first, so the one left is a tap away.
    mutating func recordSwitch(to current: ModelQuickPick, from previous: ModelQuickPick?) {
        for pick in [previous, current].compactMap({ $0 }) where !pick.model.isEmpty {
            recent.removeAll { $0.model == pick.model && $0.provider == pick.provider }
            recent.insert(pick, at: 0)
        }
        if recent.count > Self.recentLimit {
            recent.removeLast(recent.count - Self.recentLimit)
        }
    }

    /// The pinned models `providers` list, in pin order. A model a provider
    /// no longer lists, or one hidden with Edit, stays pinned but isn't shown.
    func pinnedRows(in providers: [ProviderInfo]) -> [ModelSearchMatch] {
        Self.rows(pinned, in: providers)
    }

    /// The recent models `providers` list that aren't pinned and aren't
    /// `current` (the sheet shows it above), newest first.
    func recentRows(in providers: [ProviderInfo], excluding current: ModelPickerSelection) -> [ModelSearchMatch] {
        let rows = Self.rows(recent, in: providers).filter { row in
            !isPinned(model: row.model.id, provider: row.provider)
                && !(row.model.id == current.model && row.provider.matches(current.provider))
        }
        return Array(rows.prefix(Self.recentShown))
    }

    private static func rows(_ picks: [ModelQuickPick], in providers: [ProviderInfo]) -> [ModelSearchMatch] {
        var seen = Set<String>()
        return picks.compactMap { pick in
            guard let provider = providers.first(where: { $0.matches(pick.provider) }),
                  let model = provider.models.first(where: { $0.id == pick.model }) else { return nil }
            let row = ModelSearchMatch(provider: provider, model: model)
            return seen.insert(row.id).inserted ? row : nil
        }
    }
}
