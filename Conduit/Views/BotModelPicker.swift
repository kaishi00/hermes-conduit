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
    @State private var providers: [ProviderInfo]?
    @State private var loadFailed = false
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
            if let providers {
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
                        }
                    } header: {
                        Text(verbatim: option.title)
                    }
                }
            } else if loadFailed {
                Text(AppLocalization.string("Could not load models."))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $query, prompt: Text(AppLocalization.string("Search providers or models")))
        .navigationTitle(AppLocalization.string("Model"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard providers == nil else { return }
            if let loaded = await appState.loadBotModelProviders() {
                providers = loaded.filter { !$0.models.isEmpty }
            } else {
                loadFailed = true
            }
        }
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
