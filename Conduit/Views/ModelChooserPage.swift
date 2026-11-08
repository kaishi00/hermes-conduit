//
//  ModelChooserPage.swift
//  Conduit
//
//  The Model page every model setting opens (Eric, 2026-11-08): a bot's
//  model, Default, Delegate and Fallback models, Subagent routing's routes,
//  the helper models, Voice jobs, Pulse's model and the Kanban override.
//  It's built from the chat's Model sheet's pieces: the pick on top (with
//  its reasoning, where the setting has one), search, the models pinned and
//  used lately, then every provider, closed. Each setting keeps its own
//  reads and saves; the page shows what they hold and hands back a pick.
//

import SwiftUI

/// What a setting holds: a provider's model, or a provider alone (Hermes
/// runs its default model). Nil where the page takes it is the setting's
/// default choice.
struct ModelChooserPick: Equatable {
    var provider: String
    var model: String
}

/// The setting's own read of Hermes' models.
struct ModelChooserCatalog: Equatable {
    var providers: [ProviderInfo] = []
    /// There are rows to show, kept or Hermes'.
    var loaded = false
    /// Hermes answered: only then is a model picked, as a list that didn't
    /// load is never picked from.
    var answered = false
    /// The last read failed; the rows shown stay up.
    var failed = false

    init(providers: [ProviderInfo] = [], loaded: Bool = false, answered: Bool = false, failed: Bool = false) {
        self.providers = providers
        self.loaded = loaded
        self.answered = answered
        self.failed = failed
    }

    init(_ kept: KeptModelCatalog) {
        self.init(providers: kept.providers, loaded: kept.loaded, answered: kept.answered, failed: kept.failed)
    }
}

/// The setting's choice above the models: what it does with none of its own.
struct ModelChooserDefault {
    let title: String
    var detail: String? = nil
}

/// A setting's reasoning, shown as the Model sheet's rising bars in the
/// page's top card.
struct ModelChooserReasoning {
    /// Hermes' effort word; empty when it follows `inheritTitle`.
    let effort: String
    /// What an empty effort is called ("Same as chats"); nil when the
    /// setting has no such choice and empty means Off.
    var inheritTitle: String? = nil
    var levels: [ReasoningEffortLevel] = ReasoningEffortLevel.allCases
    var disabled = false
    /// An effort word, or empty for `inheritTitle`.
    let set: (String) -> Void
}

/// Refresh models in the page's toolbar.
struct ModelChooserRefresh {
    let refreshing: Bool
    let run: () -> Void
}

struct ModelChooserPage: View {
    var title = AppLocalization.string("Model")
    let catalog: ModelChooserCatalog
    let retry: () -> Void
    var refresh: ModelChooserRefresh? = nil
    var defaultChoice: ModelChooserDefault? = nil
    let pick: ModelChooserPick?
    /// Whether a listed row is the pick. By default a row of the pick's
    /// provider, under any of its spellings, with the pick's model id.
    var isPicked: ((ProviderInfo, ModelInfo) -> Bool)? = nil
    var reasoning: ModelChooserReasoning? = nil
    /// The setting is saving, or hasn't answered: nothing is picked meanwhile.
    var disabled = false
    /// What an empty catalog says; nil where the footer says it.
    var emptyNote: String? = AppLocalization.string("Hermes has no models set up yet.")
    let onDefault: () -> Void
    let onPick: (ProviderInfo, ModelInfo) -> Void
    /// The setting's own words and warnings, under the models.
    var footer: AnyView? = nil

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var query = ""
    /// The providers opened to their models: each starts closed, so a long
    /// list reads as its providers, except the one holding the pick.
    @State private var expandedProviders: Set<String> = []
    @State private var openedPicked = false

    private var searching: Bool { !ModelSearchQuery(query).isEmpty }
    private var visibleProviders: [ProviderInfo] { appState.modelVisibility.visible(catalog.providers) }

    var body: some View {
        SettingsDetailContainer {
            currentCard
            if let defaultChoice {
                SettingsCard {
                    row(title: defaultChoice.title, detail: defaultChoice.detail, isSelected: pick == nil) {
                        onDefault()
                    }
                    .disabled(disabled)
                    .accessibilityIdentifier("modelChooser.default")
                }
            }
            if catalog.loaded {
                if catalog.providers.isEmpty, catalog.answered, let emptyNote {
                    Text(verbatim: emptyNote)
                        .foregroundStyle(.secondary)
                }
                if searching {
                    SettingsCard {
                        searchResults
                    }
                } else {
                    quickPicks
                    providersSection
                }
                if catalog.failed {
                    failedRows
                }
            } else if catalog.failed {
                failedRows
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let footer {
                footer
            }
        }
        .searchable(text: $query, prompt: Text(AppLocalization.string("Search providers or models")))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let refresh {
                    RefreshModelsButton(refreshing: refresh.refreshing, action: refresh.run)
                        .accessibilityIdentifier("modelChooser.refreshModels")
                }
                NavigationLink {
                    ModelVisibilityEditorPage(providers: catalog.providers, expandedProvider: pickedProvider?.name)
                } label: {
                    Text(AppLocalization.string("Edit"))
                        .scaledFont(.subheadline.weight(.semibold))
                }
                .tint(.conduitAccent)
                .disabled(!catalog.loaded || catalog.providers.isEmpty)
                .accessibilityIdentifier("modelChooser.edit")
            }
        }
        .onAppear(perform: openPickedProvider)
        .onChange(of: catalog.providers.map(\.name)) { _, _ in openPickedProvider() }
    }

    // MARK: The pick

    private func picked(_ provider: ProviderInfo, _ model: ModelInfo) -> Bool {
        guard let pick else { return false }
        if let isPicked { return isPicked(provider, model) }
        return provider.matches(pick.provider) && model.id == pick.model
    }

    /// The listed row holding the pick, hidden with Edit or not.
    private var pickedRow: ModelSearchMatch? {
        for provider in catalog.providers {
            if let model = provider.models.first(where: { picked(provider, $0) }) {
                return ModelSearchMatch(provider: provider, model: model)
            }
        }
        return nil
    }

    private var pickedProvider: ProviderInfo? {
        pickedRow?.provider ?? pick.flatMap { catalog.providers.row(named: $0.provider) }
    }

    /// The pick and what it runs on: the top card's two lines.
    private var currentLines: (title: String, detail: String?) {
        guard let pick else {
            return (defaultChoice?.title ?? AppLocalization.string("Not set"), defaultChoice?.detail)
        }
        if let row = pickedRow {
            let hidden = appState.modelVisibility.isHidden(model: row.model.id, provider: row.provider)
            let provider = hidden ? row.provider.title + " · " + AppLocalization.string("Hidden") : row.provider.title
            return (row.model.label ?? row.model.id, provider)
        }
        if pick.model.isEmpty {
            // A provider pinned without a model runs on its default one.
            return (VoiceJobModelSettingsSection.providerDefaultTitle(pickedProvider?.title ?? pick.provider), nil)
        }
        let provider = pick.provider.isEmpty ? nil : (pickedProvider?.title ?? pick.provider)
        return (pick.model, catalog.answered ? [provider, AppLocalization.string("Not listed by Hermes")].compactMap { $0 }.joined(separator: " · ") : provider)
    }

    private var currentCard: some View {
        let lines = currentLines
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("In use"))
                    .scaledFont(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.conduitAccent)
                Text(verbatim: lines.title)
                    .scaledFont(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let detail = lines.detail {
                    Text(verbatim: detail)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            if let reasoning {
                ReasoningEffortBars(
                    effort: reasoning.effort,
                    disabled: reasoning.disabled,
                    levels: reasoning.levels,
                    unsetTitle: reasoning.inheritTitle,
                    onCommit: { reasoning.set($0.rawValue) }
                )
                if let inheritTitle = reasoning.inheritTitle {
                    inheritReasoningButton(inheritTitle, reasoning: reasoning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.conduitAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAccent.opacity(0.45), lineWidth: 1)
        }
    }

    /// Puts the reasoning back on the one it follows.
    private func inheritReasoningButton(_ title: String, reasoning: ModelChooserReasoning) -> some View {
        let inherits = reasoning.effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            Haptics.selection()
            reasoning.set("")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: inherits ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(inherits ? Color.conduitAccent : .secondary)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inherits || reasoning.disabled)
        .accessibilityLabel(Text(AppLocalization.string("Reasoning")))
        .accessibilityValue(Text(verbatim: title))
        .accessibilityAddTraits(inherits ? .isSelected : [])
        .accessibilityIdentifier("modelChooser.inheritReasoning")
    }

    // MARK: Lists

    /// Pinned models, then the ones used lately, as the Model sheet lists them.
    @ViewBuilder
    private var quickPicks: some View {
        let providers = visibleProviders
        let pinned = appState.modelQuickPicks.pinnedRows(in: providers)
        let recent = appState.modelQuickPicks.recentRows(
            in: providers,
            excluding: ModelPickerSelection(model: pick?.model ?? "", provider: pick?.provider ?? "")
        )
        if !pinned.isEmpty || !recent.isEmpty {
            ConduitSettingsSection(title: AppLocalization.string("Quick picks"), symbol: "pin", tint: .conduitAccent) {
                ForEach(pinned) { match in
                    matchRow(match, note: nil)
                }
                ForEach(recent) { match in
                    matchRow(match, note: nil)
                }
            }
        }
    }

    @ViewBuilder
    private var providersSection: some View {
        let providers = visibleProviders.filter { !$0.models.isEmpty }
        if !providers.isEmpty {
            // One card of providers, each opening its models under it.
            ConduitSettingsSection(title: AppLocalization.string("All providers"), symbol: "server.rack", tint: .purple) {
                ForEach(providers, id: \.name) { option in
                    providerRow(option)
                    if expandedProviders.contains(option.name) {
                        ForEach(option.models, id: \.id) { item in
                            row(title: item.label ?? item.id, isSelected: picked(option, item)) {
                                onPick(option, item)
                            }
                            .padding(.leading, 16)
                            .disabled(!catalog.answered || disabled)
                            .contextMenu { pinMenu(item, provider: option) }
                        }
                    }
                }
            }
        } else if catalog.answered, !catalog.providers.isEmpty, visibleProviders.isEmpty {
            Text("All providers are hidden. Tap Edit to restore one.")
                .scaledFont(.caption).foregroundStyle(.secondary)
        } else if catalog.answered, !visibleProviders.isEmpty {
            Text("No models are available from this gateway.")
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    /// Matches across providers, each naming its provider: several often
    /// serve the same model. Models hidden with Edit are found too, marked
    /// Hidden, so a setting can still be put on one.
    @ViewBuilder
    private var searchResults: some View {
        let matches = modelSearchMatches(in: catalog.providers, query: query)
        if matches.isEmpty {
            Text(verbatim: AppLocalization.string("Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”."))
                .foregroundStyle(.secondary)
        }
        ForEach(matches) { match in
            let hidden = appState.modelVisibility.isHidden(model: match.model.id, provider: match.provider)
            matchRow(match, note: hidden ? AppLocalization.string("Hidden") : nil)
        }
    }

    /// A model under any provider, naming it: a search match or a quick pick.
    private func matchRow(_ match: ModelSearchMatch, note: String?) -> some View {
        row(
            title: match.model.label ?? match.model.id,
            detail: match.model.label == nil ? nil : match.model.id,
            providerTitle: note.map { match.provider.title + " · " + $0 } ?? match.provider.title,
            isSelected: picked(match.provider, match.model)
        ) {
            onPick(match.provider, match.model)
        }
        .disabled(!catalog.answered || disabled)
        .contextMenu { pinMenu(match.model, provider: match.provider) }
    }

    /// A provider's row: its name and model count, opening or closing its
    /// models.
    private func providerRow(_ option: ProviderInfo) -> some View {
        let isExpanded = expandedProviders.contains(option.name)
        // A held model's provider holds it too.
        let holdsPick = option.models.contains { picked(option, $0) }
            || (pickedRow == nil && pickedProvider?.name == option.name)
        return Button {
            Haptics.selection()
            withAnimation(ConduitMotion.response) {
                if isExpanded {
                    expandedProviders.remove(option.name)
                } else {
                    expandedProviders.insert(option.name)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: option.title)
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if holdsPick, !isExpanded {
                    Image(systemName: "checkmark")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(Color.conduitAccent)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 12)
                Text(verbatim: "\(option.models.count)")
                    .scaledFont(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // Plain: a list tints a button's whole label with the accent, so
        // every row read as a link rather than a choice.
        .buttonStyle(.plain)
        .accessibilityValue(Text(isExpanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed")))
        // VoiceOver finds the pick without opening every provider.
        .accessibilityAddTraits(holdsPick ? .isSelected : [])
    }

    /// Opens the provider holding the pick, once, when it is first listed.
    private func openPickedProvider() {
        guard !openedPicked, let provider = pickedProvider else { return }
        openedPicked = true
        expandedProviders.insert(provider.name)
    }

    /// A read that failed, under the models shown or alone.
    @ViewBuilder
    private var failedRows: some View {
        Text(AppLocalization.string("Could not load models."))
            .foregroundStyle(.secondary)
        Button(AppLocalization.string("Try Again"), action: retry)
            .buttonStyle(.settings)
    }

    /// Pin or Unpin, shared with the chat's Model sheet's Quick picks.
    private func pinMenu(_ item: ModelInfo, provider option: ProviderInfo) -> some View {
        let pinned = appState.modelQuickPicks.isPinned(model: item.id, provider: option)
        return Button {
            Haptics.selection()
            appState.updateModelQuickPicks { $0.togglePin(model: item.id, provider: option) }
        } label: {
            Label(
                pinned ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"),
                systemImage: pinned ? "pin.slash" : "pin"
            )
        }
    }

    /// A choice. The page closes on a pick, except where it has reasoning
    /// to set after it.
    private func row(title: String, detail: String? = nil, providerTitle: String? = nil, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            select()
            if reasoning == nil { dismiss() }
        } label: {
            HStack {
                if let providerTitle {
                    ModelSearchResultText(title: title, detail: detail, provider: providerTitle)
                } else if let detail {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .foregroundStyle(.primary)
                        Text(verbatim: detail)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(verbatim: title)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.conduitAccent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A model setting's row in Settings: its name, then the model and the
/// provider it runs on, opening the setting's Model page.
struct ModelChooserLinkRow: View {
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            SettingsChevron()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The row's lines for a pick: the model's name, and its provider's,
    /// as the catalog spells them; a reasoning level after the provider.
    static func lines(
        pick: ModelChooserPick?,
        providers: [ProviderInfo],
        defaultTitle: String,
        reasoning: String? = nil
    ) -> (value: String, detail: String?) {
        guard let pick else {
            return (defaultTitle, reasoning)
        }
        let row = providers.row(named: pick.provider)
        let model = row?.models.first { $0.id == pick.model }
        let value = pick.model.isEmpty
            ? VoiceJobModelSettingsSection.providerDefaultTitle(row?.title ?? pick.provider)
            : model?.label ?? pick.model
        let provider = pick.model.isEmpty ? nil : (row?.title ?? (pick.provider.isEmpty ? nil : pick.provider))
        let detail = [provider, reasoning].compactMap { $0 }.joined(separator: " · ")
        return (value, detail.isEmpty ? nil : detail)
    }
}

extension Array where Element == ProviderInfo {
    /// The row a saved provider names: the one named exactly, else the
    /// first whose display name or alias it is (a `custom:key` pick beside
    /// both a `custom:key` row and a `custom` row aliased to it).
    func row(named provider: String) -> ProviderInfo? {
        first { $0.name == provider } ?? first { $0.matches(provider) }
    }
}
