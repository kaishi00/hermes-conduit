//
//  ModelVisibilityEditor.swift
//  Conduit
//
//  Edit's list of providers and models to show or hide in the model
//  pickers: the chat's Model sheet and the Model page every setting opens
//  (ModelChooserPage). The filters stay on this device, per dashboard.
//

import SwiftUI

extension ModelVisibility {
    /// A hidden model's key: its provider row's name and its id.
    static func key(provider: String, model: String) -> String { "\(provider)\u{1F}\(model)" }

    func isHidden(provider: ProviderInfo) -> Bool {
        hiddenProviders.contains(provider.name)
    }

    func isHidden(model: String, provider: ProviderInfo) -> Bool {
        isHidden(provider: provider) || hiddenModels.contains(Self.key(provider: provider.name, model: model))
    }

    /// The providers and models Edit leaves shown, in catalog order.
    func visible(_ providers: [ProviderInfo]) -> [ProviderInfo] {
        providers.filter { !isHidden(provider: $0) }.map { provider in
            ProviderInfo(
                name: provider.name,
                models: provider.models.filter { !hiddenModels.contains(Self.key(provider: provider.name, model: $0.id)) },
                // Kept so a saved provider spelled by alias still matches.
                displayName: provider.displayName,
                aliases: provider.aliases,
                isCurrent: provider.isCurrent,
                speedCapabilities: provider.speedCapabilities,
                quota: provider.quota
            )
        }
    }
}

/// Shows or hides providers and models. The caller saves the edits when
/// it's done (the sheet's Done, or the page closing).
struct ModelVisibilityEditor: View {
    @Binding var visibility: ModelVisibility
    let providers: [ProviderInfo]
    @State private var query = ""
    @State private var expandedProvider: String?
    @State private var showAllModelsFor: Set<String> = []

    init(visibility: Binding<ModelVisibility>, providers: [ProviderInfo], expandedProvider: String? = nil) {
        _visibility = visibility
        self.providers = providers
        _expandedProvider = State(initialValue: expandedProvider)
    }

    var body: some View {
        ModelPickerSection(title: AppLocalization.string("Model visibility", table: .settings), symbol: "line.3.horizontal.decrease.circle", tint: .conduitAccent, flush: true) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Search providers or models", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(11)
                    .background(rowFoundation, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("Hiding a provider preserves its individual model choices. These filters stay on this device.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            let shown = visibilityProviders
            ForEach(shown, id: \.name) { provider in
                Divider().overlay(rowStroke).padding(.leading, provider.name == shown.first?.name ? 0 : 16)
                visibilityProviderCard(provider)
            }
        }
    }

    private var visibilityProviders: [ProviderInfo] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return providers }
        return providers.filter { provider in
            Self.namesMatch(provider, query) || provider.models.contains { $0.id.lowercased().contains(query) }
        }
    }

    private func visibilityProviderCard(_ provider: ProviderInfo) -> some View {
        let expanded = expandedProvider == provider.name
        let providerHidden = visibility.hiddenProviders.contains(provider.name)
        let models = matchingModels(in: provider)
        let displayAll = !query.isEmpty || showAllModelsFor.contains(provider.name)
        let shownModels = displayAll ? models : Array(models.prefix(8))

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(ConduitMotion.response) {
                        expandedProvider = expanded ? nil : provider.name
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .scaledFont(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ProviderLogoView(provider: provider)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: provider.title).scaledFont(.subheadline.weight(.semibold))
                            Text("\(String(visibleModelCount(in: provider))) of \(String(provider.models.count)) shown")
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                Button(providerHidden ? AppLocalization.string("Hidden") : AppLocalization.string("Visible", table: .settings)) {
                    toggleProviderVisibility(provider.name)
                }
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(providerHidden ? Color.secondary : Color.green)
                .padding(.horizontal, 12).frame(minHeight: 30)
                .background(providerHidden ? Color.secondary.opacity(0.12) : Color.green.opacity(0.12), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            if expanded {
                Divider().overlay(rowStroke)
                HStack {
                    Spacer()
                    Button("Show all") { setAllModels(in: provider, visible: true) }
                    Button("Hide all") { setAllModels(in: provider, visible: false) }
                }
                .scaledFont(.caption.weight(.semibold)).tint(.conduitAccent)
                .padding(.horizontal, 16).padding(.vertical, 8)

                ForEach(shownModels, id: \.id) { model in
                    let key = ModelVisibility.key(provider: provider.name, model: model.id)
                    let hidden = visibility.hiddenModels.contains(key)
                    Button {
                        toggleModelVisibility(key)
                    } label: {
                        HStack {
                            Text(model.id).scaledFont(.footnote).lineLimit(2)
                            Spacer()
                            Text(hidden ? AppLocalization.string("Hidden") : AppLocalization.string("Visible", table: .settings))
                                .scaledFont(.caption.weight(.semibold))
                                .foregroundStyle(hidden ? Color.secondary : Color.green)
                        }
                        .padding(.leading, 36).padding(.trailing, 16).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if model.id != shownModels.last?.id { Divider().overlay(rowStroke).padding(.leading, 36) }
                }
                if models.count > shownModels.count {
                    Button("Show \(models.count - shownModels.count) more") { showAllModelsFor.insert(provider.name) }
                        .scaledFont(.caption.weight(.semibold)).tint(.conduitAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
        }
    }

    private func matchingModels(in provider: ProviderInfo) -> [ModelInfo] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, !Self.namesMatch(provider, query) else { return provider.models }
        return provider.models.filter { $0.id.lowercased().contains(query) }
    }

    /// The slug, the name shown on the card or an alias holds the
    /// lowercased query.
    static func namesMatch(_ provider: ProviderInfo, _ query: String) -> Bool {
        ([provider.name, provider.title] + provider.aliases).contains { $0.lowercased().contains(query) }
    }

    private func visibleModelCount(in provider: ProviderInfo) -> Int {
        provider.models.filter { !visibility.hiddenModels.contains(ModelVisibility.key(provider: provider.name, model: $0.id)) }.count
    }

    private func toggleProviderVisibility(_ provider: String) {
        if visibility.hiddenProviders.contains(provider) { visibility.hiddenProviders.removeAll { $0 == provider } }
        else { visibility.hiddenProviders.append(provider) }
    }

    private func toggleModelVisibility(_ key: String) {
        if visibility.hiddenModels.contains(key) { visibility.hiddenModels.removeAll { $0 == key } }
        else { visibility.hiddenModels.append(key) }
    }

    private func setAllModels(in provider: ProviderInfo, visible: Bool) {
        let keys = Set(provider.models.map { ModelVisibility.key(provider: provider.name, model: $0.id) })
        if visible { visibility.hiddenModels.removeAll { keys.contains($0) } }
        else { visibility.hiddenModels = Array(Set(visibility.hiddenModels).union(keys)) }
    }

    private var rowFoundation: Color {
        Color.primary.opacity(0.05)
    }

    private var rowStroke: Color {
        Color.primary.opacity(0.07)
    }
}

/// Edit's page from the Model page settings open: the editor, saved as
/// the page closes.
struct ModelVisibilityEditorPage: View {
    @EnvironmentObject private var appState: AppState
    let providers: [ProviderInfo]
    var expandedProvider: String?
    @State private var visibility = ModelVisibility()
    @State private var started = false

    var body: some View {
        SettingsDetailContainer {
            ModelVisibilityEditor(visibility: $visibility, providers: providers, expandedProvider: expandedProvider)
        }
        .navigationTitle(AppLocalization.string("Model visibility", table: .settings))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !started else { return }
            started = true
            visibility = appState.modelVisibility
        }
        .onChange(of: visibility) { _, next in appState.saveModelVisibility(next) }
    }
}
