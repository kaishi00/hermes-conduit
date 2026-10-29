//
//  ModelSearch.swift
//  Conduit
//
//  Searching a model catalog from the model pickers (#1388). Several
//  providers often serve the same model, so a result always carries the
//  provider it comes from and shows it.
//

import GameController
import SwiftUI

/// What the user typed into a model search. Every word has to appear in the
/// model's id or label or in its provider's names, so "sonnet openrouter"
/// narrows a model several providers serve down to one of them.
struct ModelSearchQuery {
    let words: [String]

    init(_ text: String) {
        words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { words.isEmpty }

    func matches(_ fields: [String?]) -> Bool {
        let haystack = fields.compactMap { $0?.lowercased() }
        return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
    }
}

/// One model a search found, with the provider row that serves it.
struct ModelSearchMatch: Equatable, Identifiable {
    let provider: ProviderInfo
    let model: ModelInfo

    var id: String { "\(provider.name)\u{1F}\(model.id)" }
}

/// The models matching `query`, in catalog order. Empty for an empty query.
func modelSearchMatches(in providers: [ProviderInfo], query: String) -> [ModelSearchMatch] {
    let search = ModelSearchQuery(query)
    guard !search.isEmpty else { return [] }
    return providers.flatMap { provider in
        provider.models.compactMap { model in
            search.matches([model.id, model.label, provider.name, provider.displayName] + provider.aliases)
                ? ModelSearchMatch(provider: provider, model: model)
                : nil
        }
    }
}

/// The keyboard-highlighted result after an arrow key, kept on the list.
func modelSearchHighlight(_ index: Int, moving step: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index + step, 0), count - 1)
}

/// Whether a picker's search field takes focus when it opens: on a Mac or
/// with a hardware keyboard, where typing comes first. A touch-only phone
/// keeps its keyboard down, since the sheet is often opened for reasoning.
func modelSearchFocusesOnOpen(
    onMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
    hardwareKeyboard: Bool = GCKeyboard.coalesced != nil
) -> Bool {
    onMac || hardwareKeyboard
}

/// A search result's text: the model, then the provider serving it.
struct ModelSearchResultText: View {
    let title: String
    var detail: String?
    let provider: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .scaledFont(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "cube.transparent")
                    .accessibilityHidden(true)
                Text(verbatim: provider)
                    .lineLimit(1)
            }
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(.conduitAccent)
            if let detail, !detail.isEmpty, detail != title {
                Text(verbatim: detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
