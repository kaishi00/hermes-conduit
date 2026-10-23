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
                ForEach(providers, id: \.name) { option in
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

    private func row(title: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            select()
            dismiss()
        } label: {
            HStack {
                Text(verbatim: title)
                    .foregroundStyle(.primary)
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
