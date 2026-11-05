import SwiftUI

/// The bot editor's Model page: the gateway's `model.options` inventory as a
/// provider-grouped list (upstream `model-picker.tsx`). A new bot can also
/// keep the main profile's model; an edited bot always has a pick of its own.
struct BotModelPicker: View {
    @Binding var provider: String
    @Binding var model: String
    /// Offers "Same as Main Profile" (empty provider and model).
    let allowsInherit: Bool
    /// What that choice is called where it inherits something else (Edit
    /// Bot > Work's Workstream Model: the Bot Chat's).
    var inheritTitle: String? = nil

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// The models, kept from Hermes' last answer until it answers again
    /// (#1533). Kept ones wait for that answer before they can be picked:
    /// a bot's save pins its pick without Hermes checking it, and a kept
    /// model may be gone.
    @State private var catalog = KeptModelCatalog()
    @State private var query = ""
    /// The providers opened to their models: each starts closed, so a
    /// long list reads as its providers, except the one holding the pick.
    @State private var expandedProviders: Set<String> = []
    @State private var openedPicked = false
    /// Refresh models is asking Hermes for every provider's live list.
    @State private var refreshing = false
    /// Counts the catalog reads, so only the last one asked lands.
    @State private var catalogRead = 0
    /// A plain read was asked while Refresh models ran: it runs once the
    /// refresh lands.
    @State private var readAfterRefresh = false
    /// The read that failed was Refresh models, so Try Again asks for the
    /// live lists again rather than the cached ones.
    @State private var refreshFailed = false

    var body: some View {
        // Settings' own page, as Work and Edit Bot that push it.
        SettingsDetailContainer {
            if allowsInherit {
                SettingsCard {
                    row(
                        title: inheritTitle ?? AppLocalization.string("Same as Main Profile"),
                        isSelected: provider.isEmpty && model.isEmpty
                    ) {
                        provider = ""
                        model = ""
                    }
                }
            }
            if catalog.loaded {
                let providers = catalog.providers
                if providers.isEmpty {
                    Text(AppLocalization.string("Hermes has no models set up yet."))
                        .foregroundStyle(.secondary)
                }
                if !ModelSearchQuery(query).isEmpty {
                    SettingsCard {
                        searchResults(providers)
                    }
                }
                if ModelSearchQuery(query).isEmpty, !providers.isEmpty {
                    // One card of providers, each opening its models under it.
                    ConduitSettingsSection(title: AppLocalization.string("Providers"), symbol: "server.rack", tint: .purple) {
                        ForEach(providers, id: \.name) { option in
                            providerRow(option)
                            if expandedProviders.contains(option.name) {
                                ForEach(option.models, id: \.id) { item in
                                    row(
                                        title: item.label ?? item.id,
                                        isSelected: option.matches(provider) && item.id == model
                                    ) {
                                        provider = option.name
                                        model = item.id
                                    }
                                    .padding(.leading, 16)
                                    .disabled(!catalog.answered)
                                }
                            }
                        }
                    }
                }
                if catalog.failed {
                    loadFailedRows
                }
            } else if catalog.failed {
                loadFailedRows
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $query, prompt: Text(AppLocalization.string("Search providers or models")))
        .navigationTitle(AppLocalization.string("Model"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RefreshModelsButton(refreshing: refreshing) {
                    Task { await refreshModels() }
                }
                .accessibilityIdentifier("botModelPicker.refreshModels")
            }
        }
        // What Hermes listed last time, before the first frame; its answer
        // follows.
        .onAppear {
            catalog.showKept(Self.pickable(appState.keptModelProviders()))
            openPickedProvider()
        }
        .onChange(of: catalog.providers.map(\.name)) { _, _ in openPickedProvider() }
        .task {
            guard !catalog.answered else { return }
            await load()
            // Hermes fetches a stale provider list in the background
            // meanwhile (issue 1807).
            await ModelCatalogSettle.readAgain { await load() }
        }
    }

    /// Refresh models, from the toolbar or Try Again after one failed.
    private func refreshModels() async {
        guard !refreshing else { return }
        refreshing = true
        await load(refresh: true)
        refreshing = false
        // A refresh that failed stays said: Try Again asks again.
        let readSkipped = readAfterRefresh
        readAfterRefresh = false
        if readSkipped, !catalog.failed {
            await load()
        }
    }

    /// `refresh` is Refresh models: Hermes fetches every provider's live
    /// list first. The search and the pick stay as they are.
    private func load(refresh: Bool = false) async {
        // A Refresh models under way has the newer answer coming.
        guard refresh || !refreshing else {
            readAfterRefresh = true
            return
        }
        catalogRead += 1
        let read = catalogRead
        catalog.readStarted()
        let loaded = await appState.loadModelProviders(refresh: refresh)
        // A read asked since has the newer answer.
        guard read == catalogRead else { return }
        // A plain read that fails after a failed refresh keeps the refresh
        // owed, so Try Again still asks for the live lists.
        refreshFailed = loaded == nil && (refresh || refreshFailed)
        if let loaded {
            catalog.hermesAnswered(Self.pickable(loaded))
            // Hermes' answer can list the pick where the kept one didn't,
            // under the same provider names.
            openPickedProvider()
        } else {
            catalog.readFailed()
        }
    }

    /// Opens the provider holding the pick, once, when it is first listed.
    private func openPickedProvider() {
        guard !openedPicked, !model.isEmpty else { return }
        guard let held = catalog.providers.first(where: { option in
            option.matches(provider) && option.models.contains { $0.id == model }
        }) else { return }
        openedPicked = true
        expandedProviders.insert(held.name)
    }

    /// A provider's row: its name and model count, opening or closing its
    /// models, as the chat's Model sheet draws its providers.
    private func providerRow(_ option: ProviderInfo) -> some View {
        let isExpanded = expandedProviders.contains(option.name)
        let holdsPick = option.matches(provider) && option.models.contains { $0.id == model }
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
        // Plain: a List tints a button's whole label with the accent, so
        // every row read as a link rather than a choice.
        .buttonStyle(.plain)
        .accessibilityValue(Text(isExpanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed")))
        // VoiceOver finds the pick without opening every provider.
        .accessibilityAddTraits(holdsPick ? .isSelected : [])
    }

    /// A provider with no models has nothing to pick.
    private static func pickable(_ providers: [ProviderInfo]) -> [ProviderInfo] {
        providers.filter { !$0.models.isEmpty }
    }

    /// A read that failed, under the models kept or alone.
    @ViewBuilder
    private var loadFailedRows: some View {
        Text(AppLocalization.string("Could not load models."))
            .foregroundStyle(.secondary)
        Button(AppLocalization.string("Try Again")) {
            Task { if refreshFailed { await refreshModels() } else { await load() } }
        }
            .buttonStyle(.settings)
    }

    /// Matches across providers, each naming its provider: several often
    /// serve the same model.
    @ViewBuilder
    private func searchResults(_ providers: [ProviderInfo]) -> some View {
        let matches = modelSearchMatches(in: providers, query: query)
        if matches.isEmpty {
            Text(verbatim: AppLocalization.string("Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”."))
                .foregroundStyle(.secondary)
        }
        ForEach(matches) { match in
            row(
                title: match.model.label ?? match.model.id,
                detail: match.model.label == nil ? nil : match.model.id,
                providerTitle: match.provider.title,
                isSelected: match.provider.matches(provider) && match.model.id == model
            ) {
                provider = match.provider.name
                model = match.model.id
            }
            .disabled(!catalog.answered)
        }
    }

    private func row(title: String, detail: String? = nil, providerTitle: String? = nil, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            select()
            dismiss()
        } label: {
            HStack {
                if let providerTitle {
                    ModelSearchResultText(title: title, detail: detail, provider: providerTitle)
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

    /// The Model row's value: the pick, or what an empty pick means.
    static func summary(model: String, allowsInherit: Bool) -> String {
        if !model.isEmpty { return model }
        return allowsInherit
            ? AppLocalization.string("Same as Main Profile")
            : AppLocalization.string("Not set")
    }
}
