import SwiftUI

/// The bot editor's Model page: the gateway's `model.options` inventory as a
/// provider-grouped list (upstream `model-picker.tsx`). A new bot can also
/// keep the main profile's model; an edited bot always has a pick of its own.
struct BotModelPicker: View {
    @Binding var provider: String
    @Binding var model: String
    /// Offers "Same as Main Profile" (empty provider and model).
    let allowsInherit: Bool

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// The models, kept from Hermes' last answer until it answers again
    /// (#1533). Kept ones wait for that answer before they can be picked:
    /// a bot's save pins its pick without Hermes checking it, and a kept
    /// model may be gone.
    @State private var catalog = KeptModelCatalog()
    @State private var query = ""

    var body: some View {
        List {
            if allowsInherit {
                Section {
                    row(
                        title: AppLocalization.string("Same as Main Profile"),
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
                    searchResults(providers)
                }
                ForEach(ModelSearchQuery(query).isEmpty ? providers : [], id: \.name) { option in
                    Section {
                        ForEach(option.models, id: \.id) { item in
                            row(
                                title: item.label ?? item.id,
                                isSelected: option.matches(provider) && item.id == model
                            ) {
                                provider = option.name
                                model = item.id
                            }
                            .disabled(!catalog.answered)
                        }
                    } header: {
                        Text(verbatim: option.title)
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
        // What Hermes listed last time, before the first frame; its answer
        // follows.
        .onAppear { catalog.showKept(Self.pickable(appState.keptModelProviders())) }
        .task {
            guard !catalog.answered else { return }
            await load()
        }
    }

    private func load() async {
        catalog.readStarted()
        if let loaded = await appState.loadModelProviders() {
            catalog.hermesAnswered(Self.pickable(loaded))
        } else {
            catalog.readFailed()
        }
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
        Button(AppLocalization.string("Try Again")) { Task { await load() } }
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
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.conduitAccent)
                        .accessibilityHidden(true)
                }
            }
        }
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
