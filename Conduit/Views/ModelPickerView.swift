//
//  ModelPickerView.swift
//  Conduit
//
//  Bottom sheet for model selection and reasoning effort control.
//

import SwiftUI
import UIKit

func sessionYoloSelectionChanged(from initial: Bool?, to selected: Bool) -> Bool {
    guard let initial else { return false }
    return initial != selected
}

/// Whether an approval-mode change crosses the global "off" floor boundary.
/// Only such transitions affect the YOLO toggle; e.g. manual ↔ smart must not
/// discard an in-progress draft.
func yoloFloorBoundaryCrossed(from previousMode: String?, to newMode: String?) -> Bool {
    (previousMode?.lowercased() == "off") != (newMode?.lowercased() == "off")
}

/// Whether Apply should ask Hermes to switch models. Re-sending the current
/// model on every Apply (e.g. when only the reasoning level changed) would
/// re-trigger the gateway's expensive-model confirmation for no reason.
func modelPickerSelectionChanged(
    selectedModel: String,
    selectedProvider: String,
    runtimeModel: String,
    runtimeProvider: String
) -> Bool {
    let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty, !ProviderInfo.normalized(selectedProvider).isEmpty else { return false }
    return model != runtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        || ProviderInfo.normalized(selectedProvider) != ProviderInfo.normalized(runtimeProvider)
}

/// The reasoning levels offered in the Model sheet and on the composer chip,
/// lowest first. Hermes turns reasoning off with "none".
enum ReasoningEffortLevel: String, CaseIterable, Identifiable {
    case off = "none"
    case minimal, low, medium, high, xhigh, max, ultra

    var id: String { rawValue }

    /// The level for the runtime's effort word, where empty means off. Nil
    /// for a word Conduit doesn't offer.
    init?(runtimeEffort: String) {
        let word = runtimeEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.init(rawValue: word.isEmpty || word == "off" ? "none" : word)
    }

    var title: String {
        switch self {
        case .off: return AppLocalization.string("Off")
        case .minimal: return AppLocalization.string("Minimal")
        case .low: return AppLocalization.string("Low")
        case .medium: return AppLocalization.string("Medium")
        case .high: return AppLocalization.string("High")
        case .xhigh: return AppLocalization.string("Extra High")
        case .max: return AppLocalization.string("Max")
        case .ultra: return AppLocalization.string("Ultra")
        }
    }
}

/// The settings an Apply sends, captured from the sheet's draft.
struct ModelPickerApplyDraft: Equatable {
    var model: String
    var provider: String
    var yoloChanged: Bool
    var yolo: Bool
    /// The effort word sent to Hermes ("none" turns reasoning off), or nil
    /// to leave reasoning alone. The sheet sets reasoning on tap instead.
    var reasoningEffort: String?
    var fast: Bool
}

/// The gateway writes one Apply makes, in order. Injected so the apply flow
/// is testable without a gateway.
struct ModelPickerApplyActions {
    var setModel: @MainActor (_ model: String, _ provider: String, _ confirmed: Bool) async throws -> ModelSwitchOutcome
    var setYolo: @MainActor (_ enabled: Bool) async -> AppState.YoloWriteFailure?
    var setReasoning: @MainActor (_ effort: String) async throws -> Void
    var setFast: @MainActor (_ enabled: Bool) async throws -> Void
}

/// How far an Apply got. Steps already applied stay applied when a later one
/// fails, so the sheet records them and a retry does not send them again.
struct ModelPickerApplyProgress: Equatable {
    /// The model Hermes resolved the pick to, when this apply switched it.
    var switchedModel: String?
    var yoloApplied = false
    var reasoningApplied = false
    var fastApplied = false
}

enum ModelPickerApplyResult: Equatable {
    case completed(ModelPickerApplyProgress)
    /// Nothing was applied; Hermes wants this message confirmed first.
    case needsConfirmation(String)
    case failed(String, ModelPickerApplyProgress)
}

/// Runs one Apply: the model switch first, as the confirmation gate, then
/// YOLO, reasoning and fast. A guarded switch stops before anything else is
/// written, so cancelling its confirmation leaves the session untouched.
@MainActor
func runModelPickerApply(
    _ draft: ModelPickerApplyDraft,
    sendModelSwitch: Bool,
    confirmedModelSwitch: Bool,
    actions: ModelPickerApplyActions
) async -> ModelPickerApplyResult {
    var progress = ModelPickerApplyProgress()
    do {
        // A confirmed retry always re-sends: the runtime may have moved while
        // the alert was up, and the confirmation must reach Hermes.
        if sendModelSwitch || confirmedModelSwitch {
            let outcome = try await actions.setModel(draft.model, draft.provider, confirmedModelSwitch)
            if outcome.confirmRequired {
                // A gateway that still asks after a confirmed retry would
                // loop the alert forever; report it instead.
                if confirmedModelSwitch {
                    return .failed(
                        outcome.confirmMessage.isEmpty
                            ? AppLocalization.string("Hermes did not accept the model switch.")
                            : outcome.confirmMessage,
                        progress
                    )
                }
                return .needsConfirmation(
                    outcome.confirmMessage.isEmpty
                        ? AppLocalization.string("Hermes asks you to confirm switching to \(draft.model).")
                        : outcome.confirmMessage
                )
            }
            // A deferred switch (mid-turn) applies at the next turn start;
            // Hermes' session.info reports the pending pick meanwhile.
            progress.switchedModel = outcome.model
        }
        if draft.yoloChanged {
            if let failure = await actions.setYolo(draft.yolo) {
                return .failed(failure.message ?? AppLocalization.string("Unable to change YOLO mode."), progress)
            }
            progress.yoloApplied = true
        }
        if let effort = draft.reasoningEffort {
            try await actions.setReasoning(effort)
            progress.reasoningApplied = true
        }
        try await actions.setFast(draft.fast)
        progress.fastApplied = true
        return .completed(progress)
    } catch {
        return .failed(UserFacingError.message(for: error), progress)
    }
}

/// What this sheet last switched Hermes to: the catalog row picked and the
/// name Hermes resolved it to (an alias can resolve to another name).
struct ModelPickerSwitchedRow: Equatable {
    var selection: ModelPickerSelection
    var resolvedModel: String
}

/// Whether Apply sends a model switch for `selection`. A row this sheet
/// already switched to is skipped only while the runtime still runs what
/// Hermes resolved it to; any outside change re-syncs it.
func modelPickerShouldSwitch(
    _ selection: ModelPickerSelection,
    lastSwitched: ModelPickerSwitchedRow?,
    runtimeModel: String,
    runtimeProvider: String
) -> Bool {
    if let lastSwitched, lastSwitched.selection == selection,
       lastSwitched.resolvedModel == runtimeModel,
       ProviderInfo.normalized(selection.provider) == ProviderInfo.normalized(runtimeProvider) {
        return false
    }
    return modelPickerSelectionChanged(
        selectedModel: selection.model,
        selectedProvider: selection.provider,
        runtimeModel: runtimeModel,
        runtimeProvider: runtimeProvider
    )
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

struct ModelPickerSelection: Equatable {
    var model: String
    var provider: String
}

/// Everything an Apply would send. An error shown for one draft is stale as
/// soon as the draft changes.
private struct ModelPickerDraftKey: Equatable {
    var model: String
    var provider: String
    var fast: Bool
    var yolo: Bool
}

struct ModelPickerView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedModel = ""
    @State private var selectedProvider = ""
    /// The runtime's effort word ("none" when off); set on tap.
    @State private var reasoningEffort = "none"
    @State private var isApplyingReasoning = false
    @State private var reasoningError: String?
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
    @State private var isApplying = false
    @State private var applyError: String?
    /// The gateway's guard message for a pick it will not switch to unconfirmed.
    @State private var pendingModelConfirmation: String?
    /// The catalog row this sheet last switched Hermes to, so a retry does
    /// not switch to it again while the row id and `runtime.model` differ.
    @State private var switchedRow: ModelPickerSwitchedRow?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()

                ScrollView {
                    VStack(spacing: 14) {
                        if editingVisibility {
                            visibilityEditor
                        } else {
                            // Reasoning changes most often and the model
                            // list can be long, so reasoning comes first.
                            reasoningSection
                            modelSection
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
                    Button(editingVisibility ? AppLocalization.string("Done") : AppLocalization.string("Edit")) {
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
            // Seeded here, not after the catalog loads, so a failed catalog
            // fetch still shows the real level.
            reasoningEffort = appState.runtime.reasoningEffort.isEmpty ? "none" : appState.runtime.reasoningEffort
            refreshYoloToggle(force: false)
        }
        .onChange(of: appState.runtime.approvalsMode) { oldMode, newMode in
            // Only transitions into/out of the global floor affect the toggle;
            // other mode changes (manual ↔ smart) must not discard an
            // in-progress draft.
            guard yoloFloorBoundaryCrossed(from: oldMode, to: newMode) else { return }
            refreshYoloToggle(force: true)
        }
        .task { await loadModels() }
        .onChange(of: draftKey) { _, _ in
            applyError = nil
            reasoningError = nil
        }
        .onChange(of: appState.runtime.reasoningEffort) { _, effort in
            // Follow a level changed elsewhere (another device, a chat
            // switch), but not mid-tap, so the tapped pill doesn't flicker.
            guard !isApplyingReasoning else { return }
            reasoningEffort = effort.isEmpty ? "none" : effort
        }
        .onChange(of: applyError) { _, message in
            // The error row appears silently; tell VoiceOver the apply failed.
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .alert(
            "Switch model?",
            isPresented: Binding(
                get: { pendingModelConfirmation != nil },
                set: { if !$0 { pendingModelConfirmation = nil } }
            ),
            presenting: pendingModelConfirmation
        ) { _ in
            Button("Switch") {
                Task { @MainActor in await applyModel(confirmedModelSwitch: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var modelSection: some View {
        ModelPickerSection(title: AppLocalization.string("Model"), symbol: "cpu", tint: .conduitAccent) {
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
        ModelPickerSection(title: AppLocalization.string("Reasoning"), symbol: "brain.head.profile", tint: .conduitAura) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ReasoningEffortLevel.allCases) { level in
                        reasoningPill(level)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)

            if let reasoningError {
                Label(reasoningError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func reasoningPill(_ level: ReasoningEffortLevel) -> some View {
        let isSelected = ReasoningEffortLevel(runtimeEffort: reasoningEffort) == level
        return Button {
            Task { @MainActor in await applyReasoning(level) }
        } label: {
            Text(level.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(
                    isSelected ? AnyShapeStyle(Color.conduitAura) : AnyShapeStyle(rowFoundation),
                    in: Capsule()
                )
                .overlay {
                    Capsule().strokeBorder(isSelected ? Color.clear : rowStroke, lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // One write at a time: Apply may switch the model under this level.
        .disabled(isApplyingReasoning || isApplying)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var runSettingsSection: some View {
        ModelPickerSection(title: AppLocalization.string("Run settings"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
            Toggle("Fast mode", isOn: $fastEnabled)
            if globalYoloFloor {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("YOLO mode", isOn: $yoloEnabled)
                        .disabled(true)
                    Text(yoloHelpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // VoiceOver can skim past disabled controls and their separate
                // footnotes; merge the locked toggle with its rationale so the
                // reason is always read with the control.
                .accessibilityElement(children: .combine)
            } else {
                Toggle("YOLO mode", isOn: $yoloEnabled)
                Text(yoloHelpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Hermes auto-approves globally when the profile approval mode is "off", so
    /// a per-session YOLO toggle cannot require approvals. Lock the toggle on
    /// and explain why rather than offering a control that silently does nothing.
    private var globalYoloFloor: Bool {
        appState.runtime.approvalsMode?.lowercased() == "off"
    }

    private var yoloHelpText: String {
        if globalYoloFloor {
            return "Profile approval mode is off, so Hermes auto-approves this conversation regardless. This toggle is locked on until you change the profile mode in Workspace & safety."
        }
        return "YOLO automatically approves tool actions for this conversation only. Set the profile default in Workspace & safety."
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
            ModelPickerSection(title: AppLocalization.string("Model visibility"), symbol: "line.3.horizontal.decrease.circle", tint: .conduitAccent) {
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
                            Text("\(String(visibleModelCount(in: provider))) of \(String(provider.models.count)) shown")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                Button(providerHidden ? AppLocalization.string("Hidden") : AppLocalization.string("Visible")) {
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
                            Text(hidden ? AppLocalization.string("Hidden") : AppLocalization.string("Visible"))
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
        VStack(spacing: 10) {
            // The composer's error banner sits behind this sheet, so a failed
            // apply has to be reported here.
            if let applyError {
                Label(applyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { @MainActor in await applyModel() }
            } label: {
                Group {
                    if isApplying {
                        ProgressView()
                            .tint(.white)
                            .accessibilityLabel(AppLocalization.string("Applying configuration"))
                    } else {
                        Label("Apply configuration", systemImage: "checkmark")
                    }
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
            }
            .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent, prominent: true)
            .disabled(isApplying || isApplyingReasoning)
        }
    }

    private var draftKey: ModelPickerDraftKey {
        ModelPickerDraftKey(
            model: selectedModel,
            provider: selectedProvider,
            fast: fastEnabled,
            yolo: yoloEnabled
        )
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
            fastEnabled = appState.runtime.fast
            refreshYoloToggle(force: false)
        } catch {
            // Model options are supplementary to the current session state.
        }
    }

    /// Seed the YOLO toggle from the effective runtime value. While the global
    /// approval floor is active the toggle is pinned on (and marked unchanged so
    /// `applyModel` sends no spurious write). Otherwise it follows the runtime
    /// value, respecting an in-progress draft unless `force` re-seeds after a
    /// global approval-mode change.
    private func refreshYoloToggle(force: Bool) {
        if globalYoloFloor {
            yoloEnabled = true
            initialYoloEnabled = true
            return
        }
        if force {
            let draft = ModelPickerYoloDraft(runtimeYolo: appState.runtime.yolo)
            yoloEnabled = draft.selected
            initialYoloEnabled = draft.initial
        } else if let draft = ModelPickerYoloDraft.seededIfNeeded(
            initial: initialYoloEnabled,
            runtimeYolo: appState.runtime.yolo
        ) {
            yoloEnabled = draft.selected
            initialYoloEnabled = draft.initial
        }
    }

    /// Reasoning applies to the live agent at once, so a tap sends it without
    /// waiting for Apply.
    private func applyReasoning(_ level: ReasoningEffortLevel) async {
        guard !isApplyingReasoning, !isApplying else { return }
        Haptics.selection()
        reasoningEffort = level.rawValue
        reasoningError = nil
        isApplyingReasoning = true
        defer { isApplyingReasoning = false }
        let result = await appState.setReasoningEffort(level.rawValue)
        if result != .applied {
            // Back to the live level, which may have moved meanwhile.
            reasoningEffort = appState.runtime.reasoningEffort.isEmpty ? "none" : appState.runtime.reasoningEffort
        }
        if case .failed(let message) = result {
            reasoningError = message
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func applyModel(confirmedModelSwitch: Bool = false) async {
        guard !isApplying, !isApplyingReasoning else { return }
        guard let client = appState.client, let sessionId = appState.activeSessionId else {
            applyError = AppLocalization.string("Not connected to a conversation.")
            return
        }
        isApplying = true
        applyError = nil
        defer { isApplying = false }

        let selection = ModelPickerSelection(model: selectedModel, provider: selectedProvider)
        let draft = ModelPickerApplyDraft(
            model: selection.model,
            provider: selection.provider,
            yoloChanged: sessionYoloSelectionChanged(from: initialYoloEnabled, to: yoloEnabled),
            yolo: yoloEnabled,
            reasoningEffort: nil,
            fast: fastEnabled
        )
        let sendModelSwitch = modelPickerShouldSwitch(
            selection,
            lastSwitched: switchedRow,
            runtimeModel: appState.runtime.model,
            runtimeProvider: appState.runtime.provider
        )
        let actions = ModelPickerApplyActions(
            setModel: { model, provider, confirmed in
                try await client.setModel(sessionId, model: model, provider: provider, confirmed: confirmed)
            },
            // The composer banner sits behind this sheet; the failure is
            // reported here instead.
            setYolo: { enabled in await appState.setYoloModeReportingFailure(enabled) },
            setReasoning: { effort in try await client.setReasoning(sessionId, effort: effort) },
            setFast: { enabled in try await client.setFast(sessionId, enabled: enabled) }
        )

        let result = await runModelPickerApply(
            draft,
            sendModelSwitch: sendModelSwitch,
            confirmedModelSwitch: confirmedModelSwitch,
            actions: actions
        )
        switch result {
        case .completed(let progress):
            record(progress, for: selection, draft: draft)
            appState.showModelPicker = false
        case .needsConfirmation(let message):
            pendingModelConfirmation = message
        case .failed(let message, let progress):
            record(progress, for: selection, draft: draft)
            applyError = message
        }
    }

    /// Reflect the steps Hermes accepted, so the composer shows them and a
    /// retry does not send them again.
    private func record(_ progress: ModelPickerApplyProgress, for selection: ModelPickerSelection, draft: ModelPickerApplyDraft) {
        if let model = progress.switchedModel {
            appState.runtime.model = model
            appState.runtime.provider = selection.provider
            switchedRow = ModelPickerSwitchedRow(selection: selection, resolvedModel: model)
        }
        if progress.yoloApplied {
            initialYoloEnabled = draft.yolo
        }
        if progress.reasoningApplied, let effort = draft.reasoningEffort {
            appState.runtime.reasoningEffort = effort == "none" ? "" : effort
        }
        if progress.fastApplied {
            appState.runtime.fast = draft.fast
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
