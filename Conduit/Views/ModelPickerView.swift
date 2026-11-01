//
//  ModelPickerView.swift
//  Conduit
//
//  Bottom sheet for model selection and reasoning effort control.
//

import SwiftUI
import UIKit

/// Whether a tapped row should ask Hermes to switch models. Re-sending the
/// current model (re-tapping the checked row) would re-trigger the gateway's
/// expensive-model confirmation for no reason.
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

    /// What to show for a runtime effort word: the level's title, or the
    /// raw gateway word made readable when Conduit doesn't list it.
    static func displayTitle(for runtimeEffort: String) -> String {
        if let level = ReasoningEffortLevel(runtimeEffort: runtimeEffort) { return level.title }
        return runtimeEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
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

/// The session's speed as Hermes' `/fast` words: normal, Fast (OpenAI
/// Priority / Anthropic Fast Mode) or OpenAI Ultrafast.
enum ModelSpeed: String, CaseIterable, Identifiable {
    case normal, fast, ultrafast

    var id: String { rawValue }

    /// The speed the runtime reports. Ultrafast needs `service_tier`; a
    /// gateway that only sends `fast` reads as Fast or normal.
    init(fast: Bool, serviceTier: String) {
        guard fast else { self = .normal; return }
        self = serviceTier.lowercased() == "ultrafast" ? .ultrafast : .fast
    }

    /// The tier word session info reports for this speed.
    var serviceTier: String {
        switch self {
        case .normal: return ""
        case .fast: return "priority"
        case .ultrafast: return "ultrafast"
        }
    }

    var title: String {
        switch self {
        case .normal: return AppLocalization.string("Off")
        case .fast: return AppLocalization.string("Fast")
        case .ultrafast: return AppLocalization.string("Ultrafast")
        }
    }
}

/// What tapping a model row got from Hermes.
enum ModelPickerSwitchResult: Equatable {
    /// The model Hermes resolved the pick to. A deferred switch (mid-turn)
    /// applies at the next turn start; Hermes' session.info reports the
    /// pending pick meanwhile.
    case switched(model: String, deferred: Bool)
    /// Nothing was switched; Hermes wants this message confirmed first.
    case needsConfirmation(String)
    case failed(String)
}

/// Sends one model switch. A guarded pick comes back as needing
/// confirmation, so cancelling it leaves the session on its model.
@MainActor
func runModelPickerSwitch(
    to model: String,
    confirmed: Bool,
    setModel: @MainActor (_ confirmed: Bool) async throws -> ModelSwitchOutcome
) async -> ModelPickerSwitchResult {
    do {
        let outcome = try await setModel(confirmed)
        guard outcome.confirmRequired else {
            return .switched(model: outcome.model, deferred: outcome.deferred)
        }
        // A gateway that still asks after a confirmed retry would loop the
        // alert forever; report it instead.
        if confirmed {
            return .failed(
                outcome.confirmMessage.isEmpty
                    ? AppLocalization.string("Hermes did not accept the model switch.")
                    : outcome.confirmMessage
            )
        }
        return .needsConfirmation(
            outcome.confirmMessage.isEmpty
                ? AppLocalization.string("Hermes asks you to confirm switching to \(model).")
                : outcome.confirmMessage
        )
    } catch {
        return .failed(UserFacingError.message(for: error))
    }
}

/// The speed to write after switching to a model: Ultrafast falls back to
/// Fast on a model that doesn't offer it (a row that says nothing counts as
/// lacking it). Nil leaves the speed alone.
func modelPickerSpeedAfterSwitch(_ speed: ModelSpeed, ultrafastOffered: Bool?) -> ModelSpeed? {
    speed == .ultrafast && ultrafastOffered != true ? .fast : nil
}

/// What this sheet last switched Hermes to: the catalog row picked and the
/// name Hermes resolved it to (an alias can resolve to another name).
struct ModelPickerSwitchedRow: Equatable {
    var selection: ModelPickerSelection
    var resolvedModel: String
}

/// Whether a tap sends a model switch for `selection`. A row this sheet
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

/// What a model list shows before it has rows to pick from: the model
/// sheet and the Model page's editors tell a fetch that failed (with Try
/// Again) from a gateway that lists no models, and neither from loading.
enum ModelCatalogState: Equatable {
    case loading
    case failed
    case empty
    case ready

    /// `providers` is nil until a load succeeds. A re-load that fails keeps
    /// the rows it already had.
    static func of(providers: [ProviderInfo]?, failed: Bool) -> ModelCatalogState {
        if let providers, !providers.isEmpty { return .ready }
        if failed { return .failed }
        return providers == nil ? .loading : .empty
    }
}

/// A model picker's catalog (the model sheet's, the bot editor's): the
/// models kept from Hermes' last answer until it answers again (#1533),
/// and whether a read failed.
struct KeptModelCatalog: Equatable {
    private(set) var providers: [ProviderInfo] = []
    /// There are rows to show, kept or Hermes'.
    private(set) var loaded = false
    /// Hermes answered since the picker opened. Only then can a row be
    /// picked: a list that didn't load is never picked from.
    private(set) var answered = false
    private(set) var failed = false

    var state: ModelCatalogState { .of(providers: loaded ? providers : nil, failed: failed) }
    /// A read failed under the kept rows: they stay up, saying so.
    var keptRowsFailed: Bool { failed && !answered && state == .ready }

    /// The models Hermes gave last, before the first frame. Nothing kept,
    /// or none, leaves the picker loading.
    mutating func showKept(_ kept: [ProviderInfo]) {
        guard !loaded, !kept.isEmpty else { return }
        providers = kept
        loaded = true
    }

    mutating func readStarted() {
        failed = false
    }

    mutating func hermesAnswered(_ providers: [ProviderInfo]) {
        self.providers = providers
        loaded = true
        answered = true
    }

    /// A read that fails keeps the rows shown.
    mutating func readFailed() {
        failed = true
    }
}

struct ModelPickerSelection: Equatable {
    var model: String
    var provider: String
}

/// A tapped row Hermes wants confirmed before it switches.
private struct ModelPickerConfirmation: Equatable {
    var selection: ModelPickerSelection
    /// The row checked before the tap, still the session's model.
    var previous: ModelPickerSelection
    var message: String
}

struct ModelPickerView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var selectedModel = ""
    @State private var selectedProvider = ""
    /// The runtime's effort word ("none" when off); set on tap.
    @State private var reasoningEffort = "none"
    @State private var isApplyingReasoning = false
    @State private var reasoningError: String?
    /// The speed or YOLO value being written, shown until Hermes answers.
    @State private var writingSpeed: ModelSpeed?
    @State private var writingYolo: Bool?
    @State private var runSettingsError: String?
    /// The models, kept from Hermes' last answer until it answers: an
    /// empty list alone can't tell loading, failed and none apart.
    @State private var catalog = KeptModelCatalog()
    @State private var expandedProvider: String?
    @State private var editingVisibility = false
    @State private var visibilityQuery = ""
    @State private var expandedVisibilityProvider: String?
    @State private var showAllModelsFor: Set<String> = []
    @State private var visibility = ModelVisibility()
    /// The row being switched to, while Hermes answers.
    @State private var switchingRow: ModelPickerSelection?
    @State private var modelError: String?
    /// Says a switch made mid-turn waits for the reply to finish.
    @State private var modelNote: String?
    /// A pick Hermes will not switch to unconfirmed, with its guard message.
    @State private var pendingConfirmation: ModelPickerConfirmation?
    /// The catalog row this sheet last switched Hermes to, so a retry does
    /// not switch to it again while the row id and `runtime.model` differ.
    @State private var switchedRow: ModelPickerSwitchedRow?
    /// The model search: its text, the row the arrow keys have reached, and
    /// whether the field has focus.
    @State private var searchQuery = ""
    @State private var highlightedMatch = 0
    @FocusState private var searchFocused: Bool
    /// On a Mac or with a hardware keyboard: the field takes focus on open,
    /// a match is highlighted and Return picks it. On touch, Return only
    /// puts the keyboard away.
    @State private var keyboardDriven = false
    /// Whether the search field has had focus since the sheet opened, so
    /// the focus retry never pulls it back from a user who moved on.
    @State private var searchWasFocused = false
    /// The Add a provider sheet is up; the models are read again when it closes.
    @State private var addingProvider = false

    var body: some View {
        NavigationStack {
            ZStack {
                // V2: a settings page's layout, each group's name over a
                // quiet card on the open chat's glow (a Bot Chat's bot's).
                ConduitBackdrop(glowTint: appState.profileGlowTint(appState.conversationIdentityProfile))

                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if editingVisibility {
                                visibilityEditor
                            } else {
                                searchField
                                if searching {
                                    // The matches lead; reasoning stays
                                    // below them, still at hand.
                                    searchResultsSection
                                    addProviderRow
                                    reasoningSection
                                } else {
                                    // Reasoning changes most often and the model
                                    // list can be long, so reasoning comes first.
                                    reasoningSection
                                    modelSection
                                    addProviderRow
                                }
                                runSettingsSection
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .modifier(V2SoftTopScrollEdge(isOn: true))
                    .onChange(of: highlightedMatch) { _, index in
                        let matches = searchMatches
                        guard searching, matches.indices.contains(index) else { return }
                        withAnimation(ConduitMotion.response) {
                            scroller.scrollTo(matches[index].id)
                        }
                    }
                }
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
                            searchFocused = false
                            visibilityQuery = ""
                            expandedVisibilityProvider = selectedProvider
                            editingVisibility = true
                        }
                    }
                    .scaledFont(.subheadline.weight(.semibold))
                    .tint(.conduitAccent)
                }
            }
        }
        .preferredColorScheme(appState.themePreference.colorScheme)
        .sheet(isPresented: $addingProvider, onDismiss: { Task { await loadModels() } }) {
            if let bridge = appState.dashboardTicketBridge {
                AddProviderSheetHost(
                    bridge: bridge,
                    profile: appState.conversationIdentityProfile,
                    profileName: appState.profileDisplayName(appState.conversationIdentityProfile),
                    answers: appState.screenAnswers(profile: appState.conversationIdentityProfile),
                    catalog: catalog.providers,
                    profiles: { appState.profiles }
                )
                .environmentObject(appState)
            }
        }
        .onAppear {
            // Seeded here, not after the catalog loads, so a failed catalog
            // fetch still shows the real level.
            reasoningEffort = appState.runtime.reasoningEffort.isEmpty ? "none" : appState.runtime.reasoningEffort
            // Seeded here, not after the catalog loads: a failed fetch would
            // leave it empty for Done to save, and a late one would replace
            // edits already made.
            visibility = appState.modelVisibility
            // The models Hermes gave last, kept on the phone, with the
            // chat's model checked, before the first frame; Hermes' answer
            // follows (#1533).
            catalog.showKept(appState.keptModelProviders())
            if switchingRow == nil {
                selectedModel = appState.runtime.model
                selectedProvider = appState.runtime.provider
            }
        }
        .task { await loadModels() }
        .task {
            // On a Mac or with a hardware keyboard, typing a model's name
            // comes first. Asked again once the sheet settles, since a focus
            // request made while it slides in can be dropped.
            keyboardDriven = modelSearchFocusesOnOpen()
            guard keyboardDriven else { return }
            searchFocused = true
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !searchWasFocused, !editingVisibility else { return }
            searchFocused = true
        }
        .onChange(of: searchQuery) { _, _ in highlightedMatch = 0 }
        // Edit can hide the highlighted match.
        .onChange(of: editingVisibility) { _, _ in highlightedMatch = 0 }
        .onChange(of: searchFocused) { _, focused in
            if focused { searchWasFocused = true }
        }
        // Esc closes the sheet, as the picker's taps already applied.
        .background {
            Button(AppLocalization.string("Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: appState.runtime.reasoningEffort) { _, effort in
            // Follow a level changed elsewhere (another device, a chat
            // switch), but not mid-tap, so the tapped pill doesn't flicker.
            guard !isApplyingReasoning else { return }
            reasoningEffort = effort.isEmpty ? "none" : effort
        }
        .onChange(of: modelError) { _, message in announce(message) }
        .onChange(of: runSettingsError) { _, message in announce(message) }
        .onChange(of: modelNote) { _, message in announce(message) }
        .alert(
            "Switch model?",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            presenting: pendingConfirmation
        ) { confirmation in
            Button("Switch") {
                Task { @MainActor in
                    await switchModel(to: confirmation.selection, from: confirmation.previous, confirmed: true)
                }
            }
            // The row was never switched, so the checkmark stays where it is.
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// Matches replace the provider list once the catalog is in; until then
    /// the list's loading or failed state shows as usual.
    private var searching: Bool {
        !ModelSearchQuery(searchQuery).isEmpty
            && catalog.state == .ready
    }

    private var searchMatches: [ModelSearchMatch] {
        modelSearchMatches(in: visibleProviders, query: searchQuery)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(AppLocalization.string("Search providers or models"), text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($searchFocused)
                .onSubmit { pickHighlightedMatch() }
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Clear"))
            }
        }
        .scaledFont(.subheadline)
        .padding(11)
        .background(rowFoundation, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func moveHighlight(_ step: Int) -> KeyPress.Result {
        guard keyboardDriven, searching else { return .ignored }
        let matches = searchMatches
        highlightedMatch = modelSearchHighlight(highlightedMatch, moving: step, count: matches.count)
        // The highlight is only drawn, so VoiceOver hears which match
        // Return will pick.
        if matches.indices.contains(highlightedMatch) {
            let match = matches[highlightedMatch]
            let spoken: String = "\(match.model.id), \(match.provider.title)"
            AccessibilityNotification.Announcement(spoken).post()
        }
        return .handled
    }

    /// Return picks the highlighted match, as a tap would, and keeps the
    /// field focused for the next search. On touch it puts the keyboard away.
    private func pickHighlightedMatch() {
        guard keyboardDriven else {
            searchFocused = false
            return
        }
        searchFocused = true
        let matches = searchMatches
        guard matches.indices.contains(highlightedMatch), !modelRowsLocked else { return }
        pick(matches[highlightedMatch].model, provider: matches[highlightedMatch].provider)
    }

    /// Each match names its provider: several providers often serve the
    /// same model, and the pick switches to that provider's route.
    private var searchResultsSection: some View {
        ModelPickerSection(title: AppLocalization.string("Model"), symbol: "cpu", tint: .conduitAccent, flush: true) {
            let matches = searchMatches
            if matches.isEmpty {
                Text(verbatim: AppLocalization.string("Nothing matches “\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))”."))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                modelRow(match.model, provider: match.provider, showsProvider: true, isHighlighted: keyboardDriven && index == highlightedMatch)
                    .id(match.id)
                if index < matches.count - 1 {
                    Divider()
                        .overlay(rowStroke)
                        .padding(.leading, 16)
                }
            }
            if catalog.keptRowsFailed {
                catalogFailedRow
            }
            modelStatusRows
        }
    }

    private var modelSection: some View {
        ModelPickerSection(title: AppLocalization.string("Model"), symbol: "cpu", tint: .conduitAccent, flush: true) {
            switch catalog.state {
            case .loading:
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity)
                    .padding(16)
            case .failed:
                catalogFailedRow
            case .empty:
                Text("No models are available from this gateway.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
            case .ready:
                let shown = visibleProviders
                ForEach(shown, id: \.name) { provider in
                    providerCard(provider)
                    if provider.name != shown.last?.name {
                        Divider().overlay(rowStroke).padding(.leading, 46)
                    }
                }
                if shown.isEmpty {
                    Text("All providers are hidden. Tap Edit to restore one.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
                if catalog.keptRowsFailed {
                    // The kept models stay up; Hermes didn't answer.
                    catalogFailedRow
                }
            }

            modelStatusRows
        }
    }

    /// A model missing from the list may need its provider connected first.
    @ViewBuilder
    private var addProviderRow: some View {
        if appState.dashboardTicketBridge != nil {
            Button {
                searchFocused = false
                addingProvider = true
            } label: {
                Label(AppLocalization.string("Add a provider"), systemImage: "plus")
                    .scaledFont(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.conduitAccent)
            .background(rowFoundation, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("modelPicker.addProvider")
        }
    }

    private var catalogFailedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string("Could not load models."))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Button(AppLocalization.string("Try Again")) { Task { await loadModels() } }
                .scaledFont(.subheadline.weight(.semibold))
                .tint(.conduitAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// The composer's error banner sits behind this sheet, so a failed
    /// switch is reported here.
    @ViewBuilder
    private var modelStatusRows: some View {
        if let modelError {
            Label(modelError, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        } else if let modelNote {
            Text(modelNote)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
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
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.conduitAccent)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(provider.name)
                        .scaledFont(.subheadline.weight(.semibold))
                    Spacer(minLength: 12)
                    Text("\(provider.models.count)")
                        .scaledFont(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded {
                Divider()
                    .overlay(rowStroke)
                    .padding(.leading, 46)

                ForEach(provider.models, id: \.id) { model in
                    modelRow(model, provider: provider)
                    if model.id != provider.models.last?.id {
                        Divider()
                            .overlay(rowStroke)
                            .padding(.leading, 46)
                    }
                }
            }
        }
    }

    /// `showsProvider` for a search match, which isn't under its provider's
    /// name; `isHighlighted` for the match the arrow keys have reached.
    private func modelRow(
        _ model: ModelInfo,
        provider: ProviderInfo,
        showsProvider: Bool = false,
        isHighlighted: Bool = false
    ) -> some View {
        // The provider too, by any of its spellings: two providers can list
        // the same model id.
        let isSelected = selectedModel == model.id && provider.matches(selectedProvider)
        let isSwitching = switchingRow.map { $0.model == model.id && provider.matches($0.provider) } ?? false
        return Button {
            pick(model, provider: provider)
        } label: {
            HStack(spacing: 10) {
                if showsProvider {
                    ModelSearchResultText(title: model.id, detail: model.label, provider: provider.title)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.id)
                            .scaledFont(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let label = model.label {
                            Text(label)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 12)
                if isSwitching {
                    ProgressView()
                        .accessibilityLabel(AppLocalization.string("Switching model"))
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.conduitAccent)
                        .accessibilityHidden(true)
                }
            }
            // Under the provider's name, unless the row names it.
            .padding(.leading, showsProvider ? 12 : 42)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.conduitAccent.opacity(colorScheme == .dark ? 0.14 : 0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.conduitAccent, lineWidth: 2)
                }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(modelRowsLocked)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Rows switch once Hermes answered, one at a time, and not under
    /// another write.
    private var modelRowsLocked: Bool {
        !catalog.answered || switchingRow != nil || isApplyingReasoning || writingSpeed != nil || writingYolo != nil
    }

    /// A tapped row, or the search match Return picked.
    private func pick(_ model: ModelInfo, provider: ProviderInfo) {
        let isSelected = selectedModel == model.id && provider.matches(selectedProvider)
        Haptics.selectionChanged(!isSelected)
        let previous = ModelPickerSelection(model: selectedModel, provider: selectedProvider)
        let selection = ModelPickerSelection(model: model.id, provider: provider.name)
        Task { @MainActor in await switchModel(to: selection, from: previous) }
    }

    private var reasoningSection: some View {
        // Flush, so the pills scroll to the card's edge rather than being
        // cut off inside its padding.
        ModelPickerSection(title: AppLocalization.string("Reasoning"), symbol: "brain.head.profile", tint: .conduitAura, flush: true) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    // A level Hermes reports that Conduit doesn't offer still
                    // shows, selected, so the row never looks unset.
                    if ReasoningEffortLevel(runtimeEffort: reasoningEffort) == nil {
                        reasoningPillLabel(ReasoningEffortLevel.displayTitle(for: reasoningEffort), isSelected: true)
                            .accessibilityAddTraits(.isSelected)
                    }
                    ForEach(ReasoningEffortLevel.allCases) { level in
                        reasoningPill(level)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)

            if let reasoningError {
                Label(reasoningError, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], 16)
            }
        }
    }

    private func reasoningPill(_ level: ReasoningEffortLevel) -> some View {
        let isSelected = ReasoningEffortLevel(runtimeEffort: reasoningEffort) == level
        return Button {
            Task { @MainActor in await applyReasoning(level) }
        } label: {
            reasoningPillLabel(level.title, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        // One write at a time: a model switch may change the level under it.
        .disabled(isApplyingReasoning || switchingRow != nil || appState.isWritingReasoningEffort)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// V2: the picked level is Settings' gold capsule (dark text on the
    /// dark-mode gold, white on the light-mode brown), the rest quiet.
    private func reasoningPillLabel(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .scaledFont(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? selectedPillText : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(
                isSelected ? Color.conduitAccent : rowFoundation,
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(isSelected ? Color.clear : rowStroke, lineWidth: 0.5)
            }
            .contentShape(Capsule())
    }

    private var selectedPillText: Color {
        colorScheme == .dark ? Color.black.opacity(0.85) : .white
    }

    private var runSettingsSection: some View {
        ModelPickerSection(title: AppLocalization.string("Run settings"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
            if ultrafastOffered == true || speed == .ultrafast {
                // Hermes offers Ultrafast for this model and account, so
                // the three speeds Desktop's picker has.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fast mode")
                        .accessibilityHidden(true)
                    Picker("Fast mode", selection: speedBinding) {
                        ForEach(ModelSpeed.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(Text("Fast mode"))
                }
                .disabled(speedLocked)
            } else {
                Toggle("Fast mode", isOn: Binding(
                    get: { speed != .normal },
                    set: { speedBinding.wrappedValue = $0 ? .fast : .normal }
                ))
                .tint(.conduitAccent)
                .disabled(speedLocked)
            }
            if globalYoloFloor {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("YOLO mode", isOn: .constant(true))
                        .tint(.conduitAccent)
                        .disabled(true)
                    Text(yoloHelpText)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                // VoiceOver can skim past disabled controls and their separate
                // footnotes; merge the locked toggle with its rationale so the
                // reason is always read with the control.
                .accessibilityElement(children: .combine)
            } else {
                Toggle("YOLO mode", isOn: Binding(
                    get: { writingYolo ?? appState.runtime.yolo },
                    set: { enabled in Task { @MainActor in await applyYolo(enabled) } }
                ))
                .tint(.conduitAccent)
                .disabled(writingYolo != nil || switchingRow != nil)
                Text(yoloHelpText)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let runSettingsError {
                Label(runSettingsError, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The speed shown: the one being written, else the session's.
    private var speed: ModelSpeed { writingSpeed ?? runtimeSpeed }

    /// Picking a speed writes it at once.
    private var speedBinding: Binding<ModelSpeed> {
        Binding(
            get: { speed },
            set: { new in Task { @MainActor in await applySpeed(new) } }
        )
    }

    /// One speed write at a time, and none while a model switch may drop
    /// Ultrafast.
    private var speedLocked: Bool { writingSpeed != nil || switchingRow != nil }

    /// Hermes auto-approves globally when the profile approval mode is "off", so
    /// a per-session YOLO toggle cannot require approvals. Lock the toggle on
    /// and explain why rather than offering a control that silently does nothing.
    private var globalYoloFloor: Bool {
        appState.runtime.approvalsMode?.lowercased() == "off"
    }

    private var yoloHelpText: String {
        if globalYoloFloor {
            return AppLocalization.string("Profile approval mode is off, so Hermes auto-approves this conversation regardless. This toggle is locked on until you change the profile mode in Workspace & safety.")
        }
        return AppLocalization.string("YOLO automatically approves tool actions for this conversation only. Set the profile default in Workspace & safety.")
    }

    private var visibleProviders: [ProviderInfo] {
        catalog.providers.map { provider in
            ProviderInfo(
                name: provider.name,
                models: provider.models.filter { !visibility.hiddenModels.contains(modelVisibilityKey(provider: provider.name, model: $0.id)) },
                // Kept so a saved provider spelled by alias still matches.
                displayName: provider.displayName,
                aliases: provider.aliases,
                isCurrent: provider.isCurrent
            )
        }.filter { !visibility.hiddenProviders.contains($0.name) }
    }

    private var visibilityEditor: some View {
        ModelPickerSection(title: AppLocalization.string("Model visibility"), symbol: "line.3.horizontal.decrease.circle", tint: .conduitAccent, flush: true) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Search providers or models", text: $visibilityQuery)
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
        let query = visibilityQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return catalog.providers }
        return catalog.providers.filter { provider in
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
                            .scaledFont(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).scaledFont(.subheadline.weight(.semibold))
                            Text("\(String(visibleModelCount(in: provider))) of \(String(provider.models.count)) shown")
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                Button(providerHidden ? AppLocalization.string("Hidden") : AppLocalization.string("Visible")) {
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
                    let key = modelVisibilityKey(provider: provider.name, model: model.id)
                    let hidden = visibility.hiddenModels.contains(key)
                    Button {
                        toggleModelVisibility(key)
                    } label: {
                        HStack {
                            Text(model.id).scaledFont(.footnote).lineLimit(2)
                            Spacer()
                            Text(hidden ? AppLocalization.string("Hidden") : AppLocalization.string("Visible"))
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

    private var runtimeSpeed: ModelSpeed {
        ModelSpeed(fast: appState.runtime.fast, serviceTier: appState.runtime.serviceTier)
    }

    /// Whether the selected model offers Ultrafast, from the catalog row's
    /// capabilities. Nil until the catalog says.
    private var ultrafastOffered: Bool? {
        catalog.providers.first { $0.matches(selectedProvider) }?.offersUltrafast(selectedModel)
    }

    private var rowFoundation: Color {
        Color.primary.opacity(0.05)
    }

    private var rowStroke: Color {
        Color.primary.opacity(0.07)
    }

    /// Hermes' models for this chat, kept for the sheet to open on next.
    /// A read that fails keeps the models shown, saying so: model options
    /// are supplementary to the session's state, but the list says it
    /// didn't load rather than that there are none.
    private func loadModels() async {
        catalog.readStarted()
        guard let loaded = await appState.loadModelProviders(sessionId: appState.activeSessionId) else {
            catalog.readFailed()
            return
        }
        catalog.hermesAnswered(loaded)
        // A row being switched to keeps its checkmark.
        guard switchingRow == nil else { return }
        selectedModel = appState.runtime.model
        selectedProvider = appState.runtime.provider
    }

    /// An error row appears silently; tell VoiceOver what failed.
    private func announce(_ message: String?) {
        guard let message else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// Reasoning applies to the live agent at once, so a tap sends it without
    /// waiting for Apply.
    private func applyReasoning(_ level: ReasoningEffortLevel) async {
        guard !isApplyingReasoning, switchingRow == nil else { return }
        // Re-tapping the live level sends nothing.
        guard ReasoningEffortLevel(runtimeEffort: reasoningEffort) != level else { return }
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

    /// A tapped row switches the model at once. A row Hermes wants
    /// confirmed asks first; a refused or failed switch leaves the
    /// checkmark on the model the session still runs.
    private func switchModel(
        to selection: ModelPickerSelection,
        from previous: ModelPickerSelection,
        confirmed: Bool = false
    ) async {
        // A switch waits for the other writes and they wait for it; the
        // Ultrafast fallback reads the speed the switch lands on.
        guard switchingRow == nil, !isApplyingReasoning, writingSpeed == nil, writingYolo == nil else { return }
        // A confirmed retry always re-sends: the runtime may have moved while
        // the alert was up, and the confirmation must reach Hermes.
        guard confirmed || modelPickerShouldSwitch(
            selection,
            lastSwitched: switchedRow,
            runtimeModel: appState.runtime.model,
            runtimeProvider: appState.runtime.provider
        ) else {
            selectedModel = selection.model
            selectedProvider = selection.provider
            return
        }
        modelError = nil
        modelNote = nil
        guard let client = appState.client, let sessionId = appState.activeSessionId else {
            modelError = AppLocalization.string("Not connected to a conversation.")
            return
        }
        selectedModel = selection.model
        selectedProvider = selection.provider
        switchingRow = selection
        defer { switchingRow = nil }

        let result = await runModelPickerSwitch(to: selection.model, confirmed: confirmed) { confirmed in
            try await client.setModel(sessionId, model: selection.model, provider: selection.provider, confirmed: confirmed)
        }
        // Another chat opened meanwhile (which also takes this sheet down):
        // what Hermes took belongs to the chat the tap started in, not to the
        // runtime the composer now shows.
        guard appState.client === client, appState.activeSessionId == sessionId else { return }
        switch result {
        case .switched(let model, let deferred):
            appState.runtime.model = model
            appState.runtime.provider = selection.provider
            switchedRow = ModelPickerSwitchedRow(selection: selection, resolvedModel: model)
            if deferred {
                modelNote = AppLocalization.string("Switches to \(model) when this reply finishes.")
            }
            if let fallback = modelPickerSpeedAfterSwitch(runtimeSpeed, ultrafastOffered: ultrafastOffered) {
                await applySpeed(fallback, unlocked: true)
            }
        case .needsConfirmation(let message):
            checkRunningModel(previous)
            pendingConfirmation = ModelPickerConfirmation(selection: selection, previous: previous, message: message)
        case .failed(let message):
            checkRunningModel(previous)
            modelError = message
        }
    }

    /// Puts the checkmark back on the model the session runs: the row
    /// checked before the tap, unless the model changed elsewhere meanwhile.
    private func checkRunningModel(_ previous: ModelPickerSelection) {
        let stillRunning = !modelPickerShouldSwitch(
            previous,
            lastSwitched: switchedRow,
            runtimeModel: appState.runtime.model,
            runtimeProvider: appState.runtime.provider
        )
        selectedModel = stillRunning ? previous.model : appState.runtime.model
        selectedProvider = stillRunning ? previous.provider : appState.runtime.provider
    }

    /// Picking a speed writes it at once; a failed write leaves the
    /// session's speed showing. `unlocked` lets a model switch write the
    /// Ultrafast fallback while it still holds the controls.
    private func applySpeed(_ new: ModelSpeed, unlocked: Bool = false) async {
        guard writingSpeed == nil, unlocked || switchingRow == nil, new != runtimeSpeed else { return }
        runSettingsError = nil
        guard let client = appState.client, let sessionId = appState.activeSessionId else {
            runSettingsError = AppLocalization.string("Not connected to a conversation.")
            return
        }
        writingSpeed = new
        defer { writingSpeed = nil }
        do {
            try await client.setSpeed(sessionId, speed: new)
        } catch {
            guard appState.client === client, appState.activeSessionId == sessionId else { return }
            runSettingsError = UserFacingError.message(for: error)
            return
        }
        guard appState.client === client, appState.activeSessionId == sessionId else { return }
        appState.runtime.fast = new != .normal
        appState.runtime.serviceTier = new.serviceTier
    }

    /// Flipping YOLO writes it at once, for this conversation only.
    private func applyYolo(_ enabled: Bool) async {
        guard writingYolo == nil, switchingRow == nil, !globalYoloFloor, enabled != appState.runtime.yolo else { return }
        runSettingsError = nil
        writingYolo = enabled
        defer { writingYolo = nil }
        // The composer banner sits behind this sheet; the failure is
        // reported here instead.
        if let message = await appState.setYoloModeReportingFailure(enabled)?.message {
            runSettingsError = message
        }
    }
}

private struct ModelPickerSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var flush = false
    private let content: Content

    init(title: String, symbol: String, tint: Color, flush: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.flush = flush
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: title, symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: flush ? 0 : 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(flush ? 0 : 16)
            .settingsCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
