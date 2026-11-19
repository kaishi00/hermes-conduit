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

/// The search text as a model id the catalog doesn't list (issue 2841): a
/// model a provider serves but doesn't list, a preview its catalog lags
/// behind, or a snapshot id for the alias it shows. One word only, as a
/// model id never has a space; nil otherwise.
func modelSearchTypedID(_ query: String) -> String? {
    let id = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return nil }
    return id
}

/// The providers a typed model id can be put on: every one that doesn't
/// already list that exact id (its listed row is the pick there), the
/// provider holding the current pick first.
func modelSearchTypedIDProviders(_ providers: [ProviderInfo], id: String, preferred: String?) -> [ProviderInfo] {
    let offered = providers.filter { provider in
        !provider.models.contains { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
    guard let preferred, !preferred.isEmpty,
          let first = offered.first(where: { $0.name == preferred }) ?? offered.first(where: { $0.matches(preferred) })
    else { return offered }
    return [first] + offered.filter { $0.name != first.name }
}

/// "Use “…” as a model ID", under a picker's search matches: its menu names
/// the providers, and choosing one picks the typed id there as a listed
/// row would be picked. Hermes checks it like any other pick.
struct ModelTypedIDMenu: View {
    let id: String
    let providers: [ProviderInfo]
    let onPick: (ProviderInfo, ModelInfo) -> Void

    var body: some View {
        Menu {
            Section(AppLocalization.string("Provider")) {
                ForEach(providers, id: \.name) { provider in
                    Button {
                        Haptics.selection()
                        onPick(provider, ModelInfo(id: id, label: nil, reasoningCapable: false))
                    } label: {
                        Text(verbatim: provider.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "character.cursor.ibeam")
                    .foregroundStyle(Color.conduitAccent)
                    .accessibilityHidden(true)
                Text(verbatim: AppLocalization.string("Use “\(id)” as a model ID", table: .settings))
                    .scaledFont(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("modelSearch.typedID")
    }
}
