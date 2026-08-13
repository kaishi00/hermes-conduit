//
//  ModelPickerView.swift
//  Conduit
//
//  Bottom sheet for model selection and reasoning effort control.
//

import SwiftUI

func sessionYoloSelectionChanged(from initial: Bool?, to selected: Bool) -> Bool {
    guard let initial else { return false }
    return initial != selected
}

struct ModelPickerYoloDraft: Equatable {
    let initial: Bool
    let selected: Bool

    init(runtimeYolo: Bool) {
        initial = runtimeYolo
        selected = runtimeYolo
    }

    static func seededIfNeeded(initial: Bool?, runtimeYolo: Bool) -> ModelPickerYoloDraft? {
        guard initial == nil else { return nil }
        return ModelPickerYoloDraft(runtimeYolo: runtimeYolo)
    }
}

struct ModelPickerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedModel = ""
    @State private var selectedProvider = ""
    @State private var reasoningEnabled = true
    @State private var reasoningEffort = "medium"
    @State private var fastEnabled = false
    @State private var yoloEnabled = false
    @State private var initialYoloEnabled: Bool?
    @State private var providers: [ProviderInfo] = []
    @State private var expandedProvider: String?
    @State private var editingVisibility = false
    @State private var visibilityQuery = ""
    @State private var expandedVisibilityProvider: String?
    @State private var showAllModelsFor: Set<String> = []
    @State private var visibility = ModelVisibility()

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()

                ScrollView {
                    VStack(spacing: 14) {
                        if editingVisibility {
                            visibilityEditor
                        } else {
                            modelSection
                            reasoningSection
                            runSettingsSection
                            applyButton
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editingVisibility ? "Done" : "Edit") {
                        if editingVisibility {
                            appState.saveModelVisibility(visibility)
                            editingVisibility = false
                        } else {
                            visibilityQuery = ""
                            expandedVisibilityProvider = selectedProvider
                            editingVisibility = true
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(.conduitAccent)
                }
            }
        }
        .preferredColorScheme(appState.themePreference.colorScheme)
        .onAppear {
            if let draft = ModelPickerYoloDraft.seededIfNeeded(
                initial: initialYoloEnabled,
                runtimeYolo: appState.runtime.yolo
            ) {
                yoloEnabled = draft.selected
                initialYoloEnabled = draft.initial
            }
        }
        .task { await loadModels() }
    }

    private var modelSection: some View {
        ModelPickerSection(title: "Model", symbol: "cpu", tint: .conduitAccent) {
            if providers.isEmpty {
                Text("No models are available from this gateway.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleProviders, id: \.name) { provider in
                    providerCard(provider)
                }
                if visibleProviders.isEmpty {
                    Text("All providers are hidden. Tap Edit to restore one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func providerCard(_ provider: ProviderInfo) -> some View {
        let isExpanded = expandedProvider == provider.name

        return VStack(spacing: 0) {
            Button {
                withAnimation(ConduitMotion.response) {
                    expandedProvider = isExpanded ? nil : provider.name
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.conduitAccent)
                        .frame(width: 20)
                    Text(provider.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 12)
                    Text("\(provider.models.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded {
                Divider()
                    .overlay(rowStroke)
                    .padding(.horizontal, 14)

                ForEach(provider.models, id: \.id) { model in
                    modelRow(model, providerName: provider.name)
                    if model.id != provider.models.last?.id {
                        Divider()
                            .overlay(rowStroke)
                            .padding(.leading, 48)
                    }
                }
            }
        }
        .background(rowFoundation, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(rowStroke, lineWidth: 1)
        }
    }

    private func modelRow(_ model: ModelInfo, providerName: String) -> some View {
        Button {
            Haptics.selectionChanged(selectedModel != model.id || selectedProvider != providerName)
            selectedModel = model.id
            selectedProvider = providerName
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.id)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let label = model.label {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                if selectedModel == model.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.conduitAccent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedModel == model.id ? Color.conduitAccent.opacity(colorScheme == .dark ? 0.14 : 0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var reasoningSection: some View {
        ModelPickerSection(title: "Reasoning", symbol: "brain.head.profile", tint: .conduitAura) {
            Toggle("Enabled", isOn: $reasoningEnabled)

            if reasoningEnabled {
                Picker("Effort", selection: $reasoningEffort) {
                    Text("Minimal").tag("minimal")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Extra High").tag("xhigh")
                    Text("Max").tag("max")
                    Text("Ultra").tag("ultra")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var runSettingsSection: some View {
        ModelPickerSection(title: "Run settings", symbol: "slider.horizontal.3", tint: .conduitAccent) {
            Toggle("Fast mode", isOn: $fastEnabled)
            Toggle("YOLO mode", isOn: $yoloEnabled)
            Text("YOLO automatically approves tool actions for this conversation only. Set the profile default in Workspace & safety.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var visibleProviders: [ProviderInfo] {
        providers.map { provider in
            ProviderInfo(
                name: provider.name,
                models: provider.models.filter { !visibility.hiddenModels.contains(modelVisibilityKey(provider: provider.name, model: $0.id)) }
            )
        }.filter { !visibility.hiddenProviders.contains($0.name) }
    }

    private var visibilityEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            ModelPickerSection(title: "Model visibility", symbol: "line.3.horizontal.decrease.circle", tint: .conduitAccent) {
                TextField("Search providers or models", text: $visibilityQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(11)
                    .background(rowFoundation, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("Hiding a provider preserves its individual model choices. These filters stay on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(visibilityProviders, id: \.name) { provider in
                    visibilityProviderCard(provider)
                }
            }
        }
    }

    private var visibilityProviders: [ProviderInfo] {
        let query = visibilityQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return providers }
        return providers.filter { provider in
            provider.name.lowercased().contains(query) || provider.models.contains { $0.id.lowercased().contains(query) }
        }
    }

    private func visibilityProviderCard(_ provider: ProviderInfo) -> some View {
        let expanded = expandedVisibilityProvider == provider.name
        let providerHidden = visibility.hiddenProviders.contains(provider.name)
        let models = matchingModels(in: provider)
        let displayAll = !visibilityQuery.isEmpty || showAllModelsFor.contains(provider.name)
        let shownModels = displayAll ? models : Array(models.prefix(8))

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(ConduitMotion.response) {
                        expandedVisibilityProvider = expanded ? nil : provider.name
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).font(.subheadline.weight(.semibold))
                            Text("\(visibleModelCount(in: provider)) of \(provider.models.count) models shown")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                Button(providerHidden ? "Hidden" : "Visible") {
                    toggleProviderVisibility(provider.name)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(providerHidden ? Color.secondary : Color.green)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .conduitGlassControl(cornerRadius: 11, tint: providerHidden ? .secondary.opacity(0.08) : .green.opacity(0.10))
            }
            .padding(12)

            if expanded {
                Divider().overlay(rowStroke)
                HStack {
                    Spacer()
                    Button("Show all") { setAllModels(in: provider, visible: true) }
                    Button("Hide all") { setAllModels(in: provider, visible: false) }
                }
                .font(.caption.weight(.semibold)).tint(.conduitAccent)
                .padding(.horizontal, 12).padding(.vertical, 8)

                ForEach(shownModels, id: \.id) { model in
                    let key = modelVisibilityKey(provider: provider.name, model: model.id)
                    let hidden = visibility.hiddenModels.contains(key)
                    Button {
                        toggleModelVisibility(key)
                    } label: {
                        HStack {
                            Text(model.id).font(.footnote).lineLimit(2)
                            Spacer()
                            Text(hidden ? "Hidden" : "Visible")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(hidden ? Color.secondary : Color.green)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if model.id != shownModels.last?.id { Divider().overlay(rowStroke).padding(.leading, 12) }
                }
                if models.count > shownModels.count {
                    Button("Show \(models.count - shownModels.count) more") { showAllModelsFor.insert(provider.name) }
                        .font(.caption.weight(.semibold)).tint(.conduitAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
        }
        .background(rowFoundation, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(rowStroke, lineWidth: 1) }
    }

    private func matchingModels(in provider: ProviderInfo) -> [ModelInfo] {
        let query = visibilityQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, !provider.name.lowercased().contains(query) else { return provider.models }
        return provider.models.filter { $0.id.lowercased().contains(query) }
    }

    private func visibleModelCount(in provider: ProviderInfo) -> Int {
        provider.models.filter { !visibility.hiddenModels.contains(modelVisibilityKey(provider: provider.name, model: $0.id)) }.count
    }

    private func modelVisibilityKey(provider: String, model: String) -> String { "\(provider)\u{1F}\(model)" }

    private func toggleProviderVisibility(_ provider: String) {
        if visibility.hiddenProviders.contains(provider) { visibility.hiddenProviders.removeAll { $0 == provider } }
        else { visibility.hiddenProviders.append(provider) }
    }

    private func toggleModelVisibility(_ key: String) {
        if visibility.hiddenModels.contains(key) { visibility.hiddenModels.removeAll { $0 == key } }
        else { visibility.hiddenModels.append(key) }
    }

    private func setAllModels(in provider: ProviderInfo, visible: Bool) {
        let keys = Set(provider.models.map { modelVisibilityKey(provider: provider.name, model: $0.id) })
        if visible { visibility.hiddenModels.removeAll { keys.contains($0) } }
        else { visibility.hiddenModels = Array(Set(visibility.hiddenModels).union(keys)) }
    }

    private var applyButton: some View {
        Button {
            Task { await applyModel() }
        } label: {
            Label("Apply configuration", systemImage: "checkmark")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent, prominent: true)
    }

    private var rowFoundation: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.035)
    }

    private var rowStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.075)
    }

    private func loadModels() async {
        guard let client = appState.client else { return }
        do {
            let (_, _, provs) = try await client.modelOptions(sessionId: appState.activeSessionId)
            providers = provs ?? []
            visibility = appState.modelVisibility
            selectedModel = appState.runtime.model
            selectedProvider = appState.runtime.provider
            reasoningEnabled = !appState.runtime.reasoningEffort.isEmpty
            if reasoningEnabled {
                reasoningEffort = appState.runtime.reasoningEffort
            }
            fastEnabled = appState.runtime.fast
            if initialYoloEnabled == nil {
                let draft = ModelPickerYoloDraft(runtimeYolo: appState.runtime.yolo)
                yoloEnabled = draft.selected
                initialYoloEnabled = draft.initial
            }
        } catch {
            // Model options are supplementary to the current session state.
        }
    }

    private func applyModel() async {
        guard let client = appState.client, let sessionId = appState.activeSessionId else { return }

        do {
            if !selectedModel.isEmpty && !selectedProvider.isEmpty {
                try await client.setModel(sessionId, model: selectedModel, provider: selectedProvider)
                appState.runtime.model = selectedModel
                appState.runtime.provider = selectedProvider
            }
            try await client.setReasoning(sessionId, effort: reasoningEnabled ? reasoningEffort : "none")
            appState.runtime.reasoningEffort = reasoningEnabled ? reasoningEffort : ""
            try await client.setFast(sessionId, enabled: fastEnabled)
            appState.runtime.fast = fastEnabled
            if sessionYoloSelectionChanged(from: initialYoloEnabled, to: yoloEnabled) {
                guard await appState.setYoloMode(yoloEnabled) else { return }
            }
            appState.showModelPicker = false
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}

/// Picker sheets use a stable standard surface rather than a large glass pane.
/// Native glass remains on compact controls, where it does not change the
/// readability of rows as the presentation moves between detents.
private struct ModelPickerSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            content
        }
        .padding(16)
        .background(sectionFoundation, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(sectionStroke, lineWidth: 1)
        }
    }

    private var sectionFoundation: Color {
        colorScheme == .dark
            ? Color(red: 0.072, green: 0.080, blue: 0.106).opacity(0.96)
            : Color.white.opacity(0.94)
    }

    private var sectionStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
    }
}
