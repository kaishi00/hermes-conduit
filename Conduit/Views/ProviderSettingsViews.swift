//
//  ProviderSettingsViews.swift
//  Conduit
//
//  Settings > Models & providers: the Providers section at the top of the
//  page, the Add a provider sheet (also offered under the Model sheet's
//  list) and a provider's own page. Each reads and writes through
//  ProviderSettingsService; keys go up once and are never shown again.
//

import SwiftUI
import UIKit

/// What the provider screens need from the page around them: Hermes'
/// model catalog for the profile, and the default model save.
struct ProviderModelContext {
    /// The catalog Hermes gave last, or nil while it hasn't answered.
    var catalog: ProfileModelDefaults?
    /// Hermes gave the catalog since the page opened, not only the kept one.
    var catalogAnswered = false
    /// Hermes' last catalog read failed.
    var catalogFailed = false
    /// Reads the catalog again.
    var reloadCatalog: () async -> Void = {}
    /// Makes `model` on the catalog row `provider` the profile's default.
    var makeDefault: (_ provider: String, _ model: String) async -> Bool
    /// What else on the profile uses the provider (its delegate or fallback
    /// models), named for Remove's confirmation.
    var usage: (ProviderEntry) -> [String]
    /// The order a provider's keys are used in on this profile.
    var keyOrder: KeyOrderAccess?
}

// MARK: - On the Model page

/// The Providers section as the Model page shows it: it owns the provider
/// list for the profile and reads Hermes' model catalog for the models each
/// provider offers. `onChange` tells the page a provider changed, so the
/// model editors below read the catalog again.
struct ModelPageProviders: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var service: ProviderSettingsService
    let kept: () -> ProfileModelDefaults?
    let load: () async -> ProfileModelDefaults?
    let makeDefault: (_ provider: String, _ model: String, _ reasoning: String) async -> Bool
    let onChange: () -> Void
    /// Raised when the page saved model defaults, so the catalog (its
    /// default and reasoning) is read again.
    var refresh = 0
    @State private var catalog: ProfileModelDefaults?
    @State private var catalogAnswered = false
    @State private var catalogFailed = false
    @State private var catalogGeneration = 0
    /// A model pick on a provider's page is saving and reads the catalog
    /// itself, so the page's refresh for that save doesn't start another
    /// read that would end the pick's spinner early.
    @State private var picking = false

    init(
        bridge: DashboardJSONRequester, profile: String, profileName: String,
        answers: KeptAnswers?, profiles: @escaping () -> [String],
        kept: @escaping () -> ProfileModelDefaults?, load: @escaping () async -> ProfileModelDefaults?,
        makeDefault: @escaping (String, String, String) async -> Bool, onChange: @escaping () -> Void,
        refresh: Int = 0
    ) {
        self.refresh = refresh
        _service = StateObject(wrappedValue: ProviderSettingsService(
            requester: bridge, profile: profile, profileName: profileName, answers: answers, profiles: profiles
        ))
        self.kept = kept
        self.load = load
        self.makeDefault = makeDefault
        self.onChange = onChange
    }

    var body: some View {
        ProvidersSettingsSection(service: service, context: ProviderModelContext(
            catalog: catalog,
            catalogAnswered: catalogAnswered,
            catalogFailed: catalogFailed,
            reloadCatalog: { await reloadCatalog() },
            makeDefault: { provider, model in
                // Read here, so the page's spinner stays until the new default
                // shows; the refresh the save raises is skipped meanwhile.
                picking = true
                defer { picking = false }
                let saved = await makeDefault(provider, model, catalog?.reasoning ?? "medium")
                if saved { await reloadCatalog() }
                return saved
            },
            usage: { entry in Self.usage(of: entry, catalog: catalog, settings: appState.keptProfileSettings(keys: Self.usageKeys),
                                         fallbacks: appState.keptProfileFallbackModels()) },
            keyOrder: KeyOrderAccess(
                kept: { appState.keptProfileSettings(keys: $0) },
                load: { await appState.readProfileSettings(keys: $0) },
                save: { await appState.setProfileSetting($0, value: $1) }
            )
        ))
        .onAppear { if catalog == nil { catalog = kept() } }
        .task { await reloadCatalog() }
        .onChange(of: service.changes) { _, _ in
            onChange()
            Task { await reloadCatalog() }
        }
        .onChange(of: refresh) { _, _ in
            guard !picking else { return }
            Task { await reloadCatalog() }
        }
    }

    /// Reads Hermes' catalog. A read that a later one overtook is dropped,
    /// so a save's reload can't be undone by an older answer.
    private func reloadCatalog() async {
        catalogGeneration += 1
        let generation = catalogGeneration
        let loaded = await load()
        guard generation == catalogGeneration else { return }
        catalogFailed = loaded == nil
        if let loaded {
            catalog = loaded
            catalogAnswered = true
            service.reserve(catalog: loaded.providers)
        }
    }

    static let usageKeys = ["delegation.provider", "delegation.model"]

    /// The other model picks on the profile that run on `entry`: its
    /// delegate model and fallback models.
    static func usage(of entry: ProviderEntry, catalog: ProfileModelDefaults? = nil, settings: [String: ProfileSettingValue]?,
                      fallbacks: [ProfileFallbackModel]?) -> [String] {
        // A pick can name the provider by its catalog row's display name or
        // an alias, so it's matched the way the catalog matches.
        let row = catalog.flatMap { entry.catalogRow(in: $0.providers) }
        let names = entry.catalogNames.map(ProviderInfo.normalized)
        func runsOn(_ provider: String) -> Bool {
            row?.matches(provider) == true || names.contains(ProviderInfo.normalized(provider))
        }
        var uses: [String] = []
        if let provider = settings?["delegation.provider"]?.textValue, !provider.isEmpty, runsOn(provider) {
            uses.append(AppLocalization.string("Delegate model"))
        }
        for fallback in fallbacks ?? [] where runsOn(fallback.provider) {
            uses.append(AppLocalization.string("Fallback \(fallback.model)"))
        }
        return uses
    }
}

// MARK: - Providers section

/// The top of the Model page: each provider this profile is connected to,
/// and Add a provider.
struct ProvidersSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: ProviderSettingsService
    let context: ProviderModelContext
    @State private var adding = false

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Providers"), symbol: "key.horizontal", tint: .conduitAccent) {
            Text(AppLocalization.string("Where this profile's models come from. Keys are saved on your Hermes host and are never shown again."))
                .scaledFont(.footnote).foregroundStyle(.secondary)
            let connected = service.connected
            if !service.hasList {
                if service.loadFailed {
                    failedRow
                } else {
                    ProgressView().frame(maxWidth: .infinity).accessibilityLabel(AppLocalization.string("Loading…"))
                }
            } else {
                if connected.isEmpty {
                    Text(AppLocalization.string("No providers yet."))
                        .scaledFont(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(connected) { entry in
                    NavigationLink {
                        ProviderDetailPage(service: service, entryID: entry.id, context: context)
                            .v2TabBarClearance()
                    } label: {
                        ProviderRow(entry: entry, isDefault: isDefault(entry))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.providers.\(entry.id)")
                }
                if service.loadFailed { failedRow }
            }
            Button { adding = true } label: {
                Label(AppLocalization.string("Add a provider"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
            }
            .disabled(!service.answered)
            .accessibilityIdentifier("settings.providers.add")
        }
        .task { await service.reload() }
        .sheet(isPresented: $adding) {
            AddProviderSheet(service: service, retryCatalog: { await context.reloadCatalog() })
        }
    }

    private var failedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("Could not load providers."))
                .scaledFont(.footnote).foregroundStyle(.secondary)
            Button(AppLocalization.string("Try Again")) { Task { await service.reload() } }
                .scaledFont(.subheadline.weight(.semibold))
                .tint(.conduitAccent)
        }
    }

    private func isDefault(_ entry: ProviderEntry) -> Bool {
        guard let catalog = context.catalog else { return entry.endpoint?.isCurrent == true }
        return entry.catalogRow(in: catalog.providers)?.name == catalog.selection.provider
    }
}

/// A provider's name and how it's connected.
private struct ProviderRow: View {
    let entry: ProviderEntry
    var isDefault = false
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ProviderText.symbol(entry))
                .foregroundStyle(ProviderText.color(entry))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(verbatim: isDefault ? ProviderText.status(entry) + " · " + AppLocalization.string("Default model") : ProviderText.status(entry))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The words for a provider's state, kept in one place.
enum ProviderText {
    static func status(_ entry: ProviderEntry) -> String {
        switch entry.status {
        case .customEndpoint: return AppLocalization.string("Custom endpoint")
        case .signedIn: return AppLocalization.string("Signed in")
        case .sharedKey: return AppLocalization.string("Shared key")
        case .ownKey: return AppLocalization.string("This profile's own key")
        case .oldCopy: return AppLocalization.string("Old copy of the shared key")
        case .mainProfileOnly: return AppLocalization.string("Saved for the main profile only")
        case .configured:
            return entry.key == nil ? AppLocalization.string("Settings saved") : AppLocalization.string("Settings saved, no key yet")
        case .notConnected: return ways(entry)
        }
    }

    /// How a provider not connected yet can be.
    static func ways(_ entry: ProviderEntry) -> String {
        var ways: [String] = []
        if entry.account?.flow == .deviceCode { ways.append(AppLocalization.string("Sign in")) }
        if entry.account?.flow == .external { ways.append(AppLocalization.string("Sign in on the host")) }
        if entry.key != nil { ways.append(AppLocalization.string("API key")) }
        if entry.key == nil, entry.account == nil, !entry.settings.isEmpty { ways.append(AppLocalization.string("Settings")) }
        return ways.joined(separator: " · ")
    }

    static func symbol(_ entry: ProviderEntry) -> String {
        switch entry.status {
        case .customEndpoint: return "server.rack"
        case .signedIn: return "person.crop.circle.badge.checkmark"
        case .sharedKey, .ownKey: return "checkmark.shield.fill"
        case .oldCopy, .mainProfileOnly: return "exclamationmark.shield"
        case .configured: return "slider.horizontal.3"
        case .notConnected: return entry.key != nil ? "key" : (entry.account != nil ? "person.crop.circle" : "slider.horizontal.3")
        }
    }

    static func color(_ entry: ProviderEntry) -> Color {
        switch entry.status {
        case .oldCopy, .mainProfileOnly: return .orange
        case .notConnected: return .secondary
        default: return .green
        }
    }

    static func apiModes() -> [(id: String, title: String)] {
        [
            (id: "", title: AppLocalization.string("Automatic")),
            (id: "chat_completions", title: "Chat Completions"),
            (id: "codex_responses", title: "Responses"),
            (id: "anthropic_messages", title: "Anthropic Messages"),
        ]
    }
}

// MARK: - Add a provider

/// Hermes' providers to pick from, with a custom endpoint first. Picking
/// one opens its form; connecting closes the sheet.
struct AddProviderSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: ProviderSettingsService
    /// Reads Hermes' model catalog again, which Custom endpoint waits for.
    var retryCatalog: () async -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [ProviderEntry] {
        let listed = service.entries.filter { $0.endpoint == nil && ($0.key != nil || $0.account != nil || !$0.settings.isEmpty) }
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return listed }
        return listed.filter { $0.name.localizedCaseInsensitiveContains(wanted) || $0.id.localizedCaseInsensitiveContains(wanted) }
    }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer(compact: true) {
                Text(AppLocalization.string("For the \(service.profileName) profile. Sign-ins and shared keys reach every profile."))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                ConduitSettingsSection(title: AppLocalization.string("Your own server"), symbol: "server.rack", tint: .conduitAura) {
                    NavigationLink {
                        CustomEndpointForm(service: service, existing: nil, onSaved: { dismiss() })
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.string("Custom endpoint"))
                                .scaledFont(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(AppLocalization.string("Any OpenAI-compatible server, such as vLLM, LM Studio or Ollama"))
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // A new endpoint's key is kept clear of the listed
                    // providers and Hermes' model catalog.
                    .disabled(!service.answered || !service.catalogReserved)
                    .accessibilityIdentifier("settings.providers.add.custom")
                    if service.answered, !service.catalogReserved {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppLocalization.string("Custom endpoints wait for Hermes' model list."))
                                .scaledFont(.footnote).foregroundStyle(.secondary)
                            Button(AppLocalization.string("Try Again")) { Task { await retryCatalog() } }
                                .scaledFont(.subheadline.weight(.semibold))
                                .tint(.conduitAccent)
                        }
                    }
                }
                ConduitSettingsSection(title: AppLocalization.string("Providers"), symbol: "key.horizontal", tint: .conduitAccent) {
                    let matches = matches
                    let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !service.hasList {
                        if service.loadFailed {
                            Button(AppLocalization.string("Try Again")) { Task { await service.reload() } }
                                .scaledFont(.subheadline.weight(.semibold))
                                .tint(.conduitAccent)
                        } else {
                            ProgressView().frame(maxWidth: .infinity).accessibilityLabel(AppLocalization.string("Loading…"))
                        }
                    } else if matches.isEmpty, !wanted.isEmpty {
                        Text(verbatim: AppLocalization.string("Nothing matches “\(wanted)”."))
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                    } else if matches.isEmpty {
                        Text(AppLocalization.string("No providers yet."))
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(matches) { entry in
                        NavigationLink {
                            ProviderConnectPage(service: service, entryID: entry.id, onConnected: { dismiss() })
                        } label: {
                            ProviderRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.providers.add.\(entry.id)")
                    }
                    if service.hasList, service.loadFailed {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppLocalization.string("Could not load providers."))
                                .scaledFont(.footnote).foregroundStyle(.secondary)
                            Button(AppLocalization.string("Try Again")) { Task { await service.reload() } }
                                .scaledFont(.subheadline.weight(.semibold))
                                .tint(.conduitAccent)
                        }
                    }
                }
            }
            .navigationTitle(AppLocalization.string("Add a provider"))
            .searchable(text: $query, prompt: AppLocalization.string("Search providers"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        .task { if !service.answered { await service.reload() } }
    }
}

/// The Add a provider sheet with a provider list of its own, for where
/// there's no Providers section to share one with (the Model sheet).
struct AddProviderSheetHost: View {
    @StateObject private var service: ProviderSettingsService
    /// Reads the picker's model catalog again, for when it had none.
    let loadCatalog: () async -> [ProviderInfo]?

    /// `catalog` is the picker's model catalog: a new endpoint's key stays
    /// clear of its providers.
    init(bridge: DashboardJSONRequester, profile: String, profileName: String, answers: KeptAnswers?,
         catalog: [ProviderInfo]?, loadCatalog: @escaping () async -> [ProviderInfo]?,
         profiles: @escaping () -> [String]) {
        self.loadCatalog = loadCatalog
        _service = StateObject(wrappedValue: {
            let service = ProviderSettingsService(
                requester: bridge, profile: profile, profileName: profileName, answers: answers, profiles: profiles
            )
            if let catalog { service.reserve(catalog: catalog) }
            return service
        }())
    }

    var body: some View {
        AddProviderSheet(service: service, retryCatalog: readCatalog)
            .task {
                // The picker had no catalog when the sheet opened: Custom
                // endpoint waits for one.
                if !service.catalogReserved { await readCatalog() }
            }
    }

    private func readCatalog() async {
        if let catalog = await loadCatalog() { service.reserve(catalog: catalog) }
    }
}

/// Connecting one provider: its sign-in, its key, or both.
private struct ProviderConnectPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: ProviderSettingsService
    let entryID: String
    let onConnected: () -> Void

    var body: some View {
        SettingsDetailContainer {
            if let entry = service.entry(entryID) {
                if let account = entry.account {
                    ConduitSettingsSection(title: AppLocalization.string("Sign in"), symbol: "person.crop.circle", tint: .conduitAccent) {
                        ProviderSignInView(service: service, entry: entry, account: account, onSignedIn: onConnected)
                    }
                }
                if let key = entry.key {
                    ConduitSettingsSection(title: AppLocalization.string("API key"), symbol: "key", tint: .conduitAura) {
                        ProviderKeyEditor(service: service, entry: entry, key: key, onSaved: onConnected)
                    }
                }
                ProviderSettingsRows(service: service, entry: entry)
            }
        }
        .navigationTitle(service.entry(entryID)?.name ?? "")
    }
}

// MARK: - A provider's page

/// A connected provider: its models, its key or account, and Remove.
struct ProviderDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: ProviderSettingsService
    let entryID: String
    let context: ProviderModelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showsAllModels = false
    @State private var settingDefault: String?
    @State private var removing = false
    @State private var confirmingRemove = false
    @State private var error: String?

    private static let shortModelList = 8

    var body: some View {
        SettingsDetailContainer {
            if let entry = service.entry(entryID) {
                ConduitSettingsSection(title: AppLocalization.string("Status"), symbol: ProviderText.symbol(entry), tint: .conduitAura) {
                    SettingsMetricRow(label: AppLocalization.string("Status"), value: ProviderText.status(entry),
                                      valueColor: ProviderText.color(entry))
                    if let endpoint = entry.endpoint {
                        SettingsMetricRow(label: AppLocalization.string("Address"), value: endpoint.baseURL, lineLimit: 1)
                    }
                }
                if service.loadFailed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppLocalization.string("Could not load providers."))
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                        Button(AppLocalization.string("Try Again")) { Task { await service.reload() } }
                            .scaledFont(.subheadline.weight(.semibold))
                            .tint(.conduitAccent)
                    }
                }
                modelsSection(entry)
                if let endpoint = entry.endpoint {
                    ConduitSettingsSection(title: AppLocalization.string("Custom endpoint"), symbol: "server.rack", tint: .conduitAccent) {
                        SettingsMetricRow(label: AppLocalization.string("API key"),
                                          value: endpoint.keySaved ? AppLocalization.string("Key saved") : AppLocalization.string("None"))
                        NavigationLink {
                            CustomEndpointForm(service: service, existing: (name: entry.name, endpoint: endpoint), onSaved: {})
                        } label: {
                            Label(AppLocalization.string("Edit endpoint"), systemImage: "pencil")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        // The kept address has no path; editing waits for Hermes' full one.
                        .disabled(!service.answered)
                        .accessibilityIdentifier("settings.providers.endpoint.edit")
                    }
                }
                if let account = entry.account {
                    ConduitSettingsSection(title: AppLocalization.string("Account"), symbol: "person.crop.circle", tint: .conduitAccent) {
                        ProviderSignInView(service: service, entry: entry, account: account, onSignedIn: {})
                    }
                }
                if let key = entry.key {
                    ConduitSettingsSection(title: AppLocalization.string("API key"), symbol: "key", tint: .conduitAura) {
                        ProviderKeyEditor(service: service, entry: entry, key: key, onSaved: {},
                                          keyRemovable: context.catalogAnswered && !runsDefault(entry),
                                          usage: context.usage(entry))
                    }
                    if key.keysInUse > 1, let order = context.keyOrder, KeyOrder.settingKey(for: entry.id) != nil {
                        KeyOrderSection(entry: entry, keys: key.keysInUse, access: order)
                    }
                }
                ProviderSettingsRows(service: service, entry: entry)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote).foregroundStyle(.red)
                }
                if context.catalogAnswered, runsDefault(entry) {
                    Text(AppLocalization.string("This provider runs the default model. Pick another default to remove it."))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
                if canRemove(entry) {
                    Button(role: .destructive) { confirmingRemove = true } label: {
                        Label(removing ? AppLocalization.string("Removing…") : AppLocalization.string("Remove provider"), systemImage: "trash")
                            .frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 46)
                    }
                    .disabled(removing)
                    .conduitGlassControl(cornerRadius: 17, tint: .red.opacity(0.16))
                    .accessibilityIdentifier("settings.providers.remove")
                    .confirmationDialog(
                        AppLocalization.string("Remove \(entry.name)?"),
                        isPresented: $confirmingRemove,
                        titleVisibility: .visible
                    ) {
                        Button(AppLocalization.string("Remove"), role: .destructive) { remove(entry) }
                        Button(AppLocalization.string("Cancel"), role: .cancel) {}
                    } message: {
                        Text(verbatim: removeMessage(entry))
                    }
                }
            } else if service.answered {
                Text(AppLocalization.string("This provider was removed."))
                    .scaledFont(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(service.entry(entryID)?.name ?? "")
    }

    @ViewBuilder
    private func modelsSection(_ entry: ProviderEntry) -> some View {
        let row = context.catalog.flatMap { entry.catalogRow(in: $0.providers) }
        let models = row?.models ?? []
        if let row, !models.isEmpty {
            ConduitSettingsSection(title: AppLocalization.string("Models"), symbol: "cpu", tint: .conduitAccent) {
                if context.catalogFailed { catalogFailedRow }
                Text(AppLocalization.string("Tap a model to make it this profile's default."))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                let shown = showsAllModels ? models : Array(models.prefix(Self.shortModelList))
                ForEach(shown, id: \.id) { model in
                    let isDefault = context.catalog?.selection.provider == row.name && context.catalog?.selection.model == model.id
                    Button {
                        makeDefault(provider: row.name, model: model.id)
                    } label: {
                        HStack {
                            Text(verbatim: model.label ?? model.id)
                                .scaledFont(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if settingDefault == model.id {
                                ProgressView().accessibilityLabel(AppLocalization.string("Saving…"))
                            } else if isDefault {
                                Image(systemName: "checkmark").foregroundStyle(Color.conduitAccent)
                                    .accessibilityLabel(AppLocalization.string("Default model"))
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Picks only from a catalog Hermes gave since the page opened.
                    .disabled(settingDefault != nil || isDefault || !context.catalogAnswered)
                }
                if models.count > Self.shortModelList {
                    Button(showsAllModels ? AppLocalization.string("Show fewer") : AppLocalization.string("Show all models")) {
                        showsAllModels.toggle()
                    }
                    .scaledFont(.subheadline.weight(.semibold))
                    .tint(.conduitAccent)
                }
            }
        } else if context.catalogFailed {
            ConduitSettingsSection(title: AppLocalization.string("Models"), symbol: "cpu", tint: .conduitAccent) {
                catalogFailedRow
            }
        }
    }

    /// The Model lists ruling: a failed read says so and offers Try Again.
    private var catalogFailedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("Could not load models."))
                .scaledFont(.footnote).foregroundStyle(.secondary)
            Button(AppLocalization.string("Try Again")) { Task { await context.reloadCatalog() } }
                .scaledFont(.subheadline.weight(.semibold))
                .tint(.conduitAccent)
        }
    }

    /// A provider that runs the default model can't go: the profile would be
    /// left without one. It says so instead of offering Remove.
    private func runsDefault(_ entry: ProviderEntry) -> Bool {
        if entry.endpoint?.isCurrent == true { return true }
        guard let catalog = context.catalog, let row = entry.catalogRow(in: catalog.providers) else { return false }
        return row.name == catalog.selection.provider
    }

    /// Remove takes away an endpoint or a sign-in. A key is changed or
    /// removed in its own section, which says which profiles it reaches.
    private func canRemove(_ entry: ProviderEntry) -> Bool {
        // Until the catalog answers, whether it runs the default is unknown.
        guard context.catalogAnswered, !runsDefault(entry) else { return false }
        if entry.endpoint != nil { return true }
        return entry.account?.signedIn == true && entry.account?.signsOutHere == true
    }

    private func removeMessage(_ entry: ProviderEntry) -> String {
        let what = entry.endpoint != nil
            ? AppLocalization.string("The endpoint is removed from this profile on your Hermes host.")
            : AppLocalization.string("Hermes signs out of it for every profile.")
        let uses = context.usage(entry)
        guard !uses.isEmpty else { return what }
        return what + " " + AppLocalization.string("These stop working until you pick another model: \(uses.joined(separator: ", ")).")
    }

    private func makeDefault(provider: String, model: String) {
        guard settingDefault == nil else { return }
        settingDefault = model
        error = nil
        Task {
            if !(await context.makeDefault(provider, model)) {
                error = AppLocalization.string("Could not save model defaults.")
            }
            settingDefault = nil
        }
    }

    private func remove(_ entry: ProviderEntry) {
        guard !removing else { return }
        removing = true
        error = nil
        Task {
            defer { removing = false }
            do {
                if let endpoint = entry.endpoint {
                    try await service.remove(endpoint: endpoint.endpointID)
                } else {
                    try await service.signOut(entry.id)
                }
                dismiss()
            } catch {
                self.error = AppLocalization.string("Could not remove the provider: \(UserFacingError.message(for: error))")
            }
        }
    }
}

// MARK: - A key

/// Which profiles a key reaches.
enum ProviderKeyScope: Hashable {
    /// The main profile's pool, used by every profile without its own key.
    case allProfiles
    /// This profile's pool only.
    case thisProfile
}

/// A provider's key: which one the profile uses, a field to add or replace
/// it (for every profile, or just this one), going back to the shared key,
/// and the base URL override. Hermes tries a key before it's saved.
private struct ProviderKeyEditor: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: ProviderSettingsService
    let entry: ProviderEntry
    let key: ProviderEntry.KeyAccess
    let onSaved: () -> Void
    /// Hermes' catalog answered and the provider doesn't run the default
    /// model, so its key may go. Off on the Add sheet's pages.
    var keyRemovable = false
    /// The profile's delegate and fallback models on the provider, named
    /// when its key is removed.
    var usage: [String] = []
    @Environment(\.openURL) private var openURL
    @State private var draft = ""
    @State private var editing = false
    @State private var scope: ProviderKeyScope?
    @State private var saving = false
    @State private var note: String?
    @State private var error: String?
    @State private var confirmingUnshare = false
    @State private var confirmingRemoveKey = false

    private var state: ProviderEntry.KeyAccess.State { entry.keyState }
    private var onMain: Bool { service.isSharedProfile }
    private var hasKey: Bool { state != .none }
    /// A key the other profiles can't read yet is pasted again to share it.
    private var showsField: Bool { state == .none || state == .mainProfileOnly || editing }
    /// A replacement for a profile's own key stays its own; anything else
    /// is shared unless picked otherwise.
    private var chosenScope: ProviderKeyScope {
        if onMain { return .allProfiles }
        return scope ?? (state == .own ? .thisProfile : .allProfiles)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hasKey ? ProviderText.symbol(entry) : "key")
                .foregroundStyle(hasKey ? ProviderText.color(entry) : Color.secondary)
                .accessibilityHidden(true)
            Text(verbatim: hasKey ? ProviderText.status(entry) : AppLocalization.string("No key yet"))
                .scaledFont(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            if !showsField {
                Button(AppLocalization.string("Replace")) { editing = true }
                    .buttonStyle(.settings)
                    .disabled(saving)
                    .accessibilityIdentifier("settings.providers.key.replace")
            }
        }
        Text(verbatim: explanation)
            .scaledFont(.caption).foregroundStyle(.secondary)
        if showsField {
            SecureField(AppLocalization.string("Paste API key"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(saving)
                .submitLabel(.done)
                .onSubmit { save() }
                .accessibilityIdentifier("settings.providers.key.field")
            if !onMain {
                ConduitMenuPicker(value: chosenScope, choices: [
                    (id: ProviderKeyScope.allProfiles, title: AppLocalization.string("All profiles")),
                    (id: ProviderKeyScope.thisProfile, title: AppLocalization.string("Only this profile")),
                ], onSelect: { scope = $0 }) {
                    Text(AppLocalization.string("Use for")).foregroundStyle(.secondary)
                }
                .disabled(saving)
                .accessibilityIdentifier("settings.providers.key.scope")
            }
            HStack {
                if editing {
                    Button(AppLocalization.string("Cancel"), role: .cancel) {
                        draft = ""
                        error = nil
                        scope = nil
                        editing = false
                    }
                    .buttonStyle(.settings)
                    .disabled(saving)
                }
                Spacer()
                Button { save() } label: {
                    if saving { ProgressView().accessibilityLabel(AppLocalization.string("Saving…")) } else { Text(AppLocalization.string("Save key")) }
                }
                .buttonStyle(.settingsPrimary)
                // What a save replaces comes from Hermes' answer, not the kept one.
                .disabled(saving || !service.answered || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.providers.key.save")
            }
            if let signup = key.signupURL.flatMap(URL.init(string:)) {
                Button(AppLocalization.string("Get a key")) { openURL(signup) }
                    .scaledFont(.subheadline.weight(.semibold))
                    .tint(.conduitAccent)
            }
        }
        if !editing { keyActions }
        if !key.heldVars.isEmpty {
            Text(AppLocalization.string("Another provider reads this key too, so Conduit leaves it in this profile's settings."))
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
        if let note {
            Text(verbatim: note).scaledFont(.caption).foregroundStyle(.secondary)
        }
        if let error {
            Text(verbatim: error).scaledFont(.caption).foregroundStyle(.red)
        }
    }

    private var explanation: String {
        switch state {
        case .none:
            return onMain
                ? AppLocalization.string("A key saved here is shared with every profile that has no key of its own.")
                : AppLocalization.string("Share a key with every profile, or save one only this profile uses.")
        case .shared:
            return onMain
                ? AppLocalization.string("Every profile without a key of its own uses this one.")
                : AppLocalization.string("This profile uses the key shared by all profiles.")
        case .own:
            return AppLocalization.string("This profile uses its own key instead of the shared one.")
        case .oldCopy:
            return AppLocalization.string("This profile still uses a shared key that was replaced since.")
        case .mainProfileOnly:
            return AppLocalization.string("This key is in the main profile's settings file, which other profiles can't read. Paste it again to share it.")
        }
    }

    @ViewBuilder
    private var keyActions: some View {
        if onMain {
            if state == .shared, keyRemovable {
                Button(role: .destructive) { confirmingUnshare = true } label: {
                    Text(AppLocalization.string("Remove shared key"))
                }
                .buttonStyle(.settings)
                .disabled(saving || !service.answered)
                .accessibilityIdentifier("settings.providers.key.unshare")
                .confirmationDialog(AppLocalization.string("Remove the shared key?"), isPresented: $confirmingUnshare, titleVisibility: .visible) {
                    Button(AppLocalization.string("Remove"), role: .destructive) { run { try await service.unshare(entry) } }
                    Button(AppLocalization.string("Cancel"), role: .cancel) {}
                } message: {
                    Text(verbatim: AppLocalization.string("Every profile without a key of its own stops using \(entry.name).") + usageLine)
                }
            } else if state == .mainProfileOnly, !key.removableVars.isEmpty, keyRemovable {
                Button(role: .destructive) { confirmingRemoveKey = true } label: {
                    Text(AppLocalization.string("Remove key"))
                }
                .buttonStyle(.settings)
                .disabled(saving || !service.answered)
                .confirmationDialog(AppLocalization.string("Remove \(entry.name)?"), isPresented: $confirmingRemoveKey, titleVisibility: .visible) {
                    Button(AppLocalization.string("Remove"), role: .destructive) {
                        run { try await service.remove(variables: key.removableVars) }
                    }
                    Button(AppLocalization.string("Cancel"), role: .cancel) {}
                } message: {
                    Text(verbatim: AppLocalization.string("Conduit never shows a key, so you'd paste it again to use it.") + usageLine)
                }
            }
        } else if state == .own || state == .oldCopy, key.shared || keyRemovable, leavesItsOwnKey {
            // Back on the shared key the default model still runs; with no
            // shared key, removing this one would leave it none.
            Button {
                if key.shared { run { try await service.useShared(entry) } } else { confirmingRemoveKey = true }
            } label: {
                Text(key.shared ? AppLocalization.string("Use the shared key") : AppLocalization.string("Remove this profile's key"))
            }
            .buttonStyle(.settings)
            .disabled(saving || !service.answered)
            .accessibilityIdentifier("settings.providers.key.useShared")
            .confirmationDialog(AppLocalization.string("Remove \(entry.name)?"), isPresented: $confirmingRemoveKey, titleVisibility: .visible) {
                Button(AppLocalization.string("Remove"), role: .destructive) { run { try await service.useShared(entry) } }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: {
                Text(verbatim: AppLocalization.string("Conduit never shows a key, so you'd paste it again to use it.") + usageLine)
            }
        }
    }

    /// Going back to the shared key changes what the profile uses: the row
    /// it uses first is one Conduit may remove, or there are no rows and a
    /// `.env` variable to remove.
    private var leavesItsOwnKey: Bool {
        if let first = key.ownRows.first { return key.removableRows.contains(first) }
        return !key.removableVars.isEmpty
    }

    private var usageLine: String {
        guard !usage.isEmpty else { return "" }
        return " " + AppLocalization.string("These stop working until you pick another model: \(usage.joined(separator: ", ")).")
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !saving else { return }
        let scope = chosenScope
        // Set before the task starts, so a second tap can't start another.
        saving = true
        error = nil
        note = nil
        Task {
            defer { saving = false }
            // A key read only through another provider's variable can't be
            // tried under it: Hermes would try it on that provider.
            let check: ProviderCheck
            if key.borrowedOnly {
                check = ProviderCheck(ok: true, reachable: true, message: "")
            } else {
                check = await service.check(key: value, for: key.writeVar)
            }
            if check.blocksSave {
                error = check.message.isEmpty ? AppLocalization.string("The provider didn't take this key.") : check.message
                return
            }
            do {
                let cleaned: Bool
                switch scope {
                case .allProfiles: cleaned = try await service.share(key: value, for: entry)
                case .thisProfile: cleaned = try await service.override(key: value, for: entry)
                }
                draft = ""
                self.scope = nil
                editing = false
                var notes: [String] = []
                if !cleaned {
                    notes.append(scope == .allProfiles
                        ? AppLocalization.string("Saved, but the old key couldn't be removed everywhere. A profile still using it says Old copy of the shared key.")
                        : AppLocalization.string("Saved, but this profile's old key couldn't be removed, so it may still be used first."))
                }
                // The key another provider also reads stays, and Hermes
                // reads it ahead of the saved one on this profile.
                if !key.heldVars.isEmpty {
                    notes.append(AppLocalization.string("Saved, but this profile still has a key another provider reads, and Hermes uses that one first here."))
                }
                if cleaned, !check.ok {
                    notes.append(AppLocalization.string("Saved. Hermes couldn't reach the provider to check the key."))
                }
                note = notes.isEmpty ? nil : notes.joined(separator: " ")
                // A note stays in view: the Add sheet closes on onSaved.
                if note == nil { onSaved() }
            } catch {
                self.error = AppLocalization.string("Could not save credential: \(UserFacingError.message(for: error))")
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !saving else { return }
        saving = true
        error = nil
        note = nil
        Task {
            defer { saving = false }
            do {
                try await work()
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }
}

// MARK: - Settings that aren't keys

/// A provider's settings in this profile's `.env` that aren't keys: a base
/// URL override, Bedrock's AWS region, Vertex's credentials file. Their
/// values are never shown; each can be set again or cleared.
private struct ProviderSettingsRows: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: ProviderSettingsService
    let entry: ProviderEntry
    @State private var editing: String?
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?

    private static let urlPlaceholder = "https://"

    var body: some View {
        if !entry.settings.isEmpty {
            ConduitSettingsSection(title: AppLocalization.string("Settings"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
                if entry.key == nil, entry.account == nil {
                    Text(AppLocalization.string("This provider needs no key here. Hermes reaches it with these settings for this profile."))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(entry.settings.enumerated()), id: \.element.variable) { index, setting in
                    if index > 0 { Divider() }
                    row(setting)
                }
                if let error {
                    Text(verbatim: error).scaledFont(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ setting: ProviderEntry.Setting) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title(setting))
                    .scaledFont(.subheadline)
                Text(verbatim: status(setting))
                    .scaledFont(.caption).foregroundStyle(.secondary)
                if !setting.description.isEmpty, !setting.isBaseURL {
                    Text(verbatim: setting.description)
                        .scaledFont(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if editing != setting.variable {
                Button(setting.saved ? AppLocalization.string("Change") : AppLocalization.string("Set")) {
                    draft = ""
                    error = nil
                    editing = setting.variable
                }
                .buttonStyle(.settings)
                .disabled(saving)
                .accessibilityLabel(Text(verbatim: (setting.saved ? AppLocalization.string("Change") : AppLocalization.string("Set")) + ", " + title(setting)))
            }
        }
        if editing == setting.variable {
            let placeholder = setting.isBaseURL ? Self.urlPlaceholder : setting.variable
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .keyboardType(setting.isBaseURL ? .URL : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(saving)
            HStack {
                if setting.saved {
                    Button(AppLocalization.string("Clear"), role: .destructive) {
                        run { try await service.remove(variables: [setting.variable]) }
                    }
                    .buttonStyle(.settings)
                    .disabled(saving || !service.answered)
                    .accessibilityLabel(Text(verbatim: AppLocalization.string("Clear") + ", " + title(setting)))
                }
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    draft = ""
                    editing = nil
                }
                .buttonStyle(.settings)
                .disabled(saving)
                .accessibilityLabel(Text(verbatim: AppLocalization.string("Cancel") + ", " + title(setting)))
                Spacer()
                Button(AppLocalization.string("Save")) {
                    let value = draft
                    run { try await service.save(key: value, for: setting.variable) }
                }
                .buttonStyle(.settingsPrimary)
                .disabled(saving || !service.answered || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(Text(verbatim: AppLocalization.string("Save") + ", " + title(setting)))
            }
        }
    }

    private func title(_ setting: ProviderEntry.Setting) -> String {
        setting.isBaseURL ? AppLocalization.string("Base URL override") : setting.variable
    }

    private func status(_ setting: ProviderEntry.Setting) -> String {
        if setting.saved { return AppLocalization.string("Set for this profile") }
        return setting.isBaseURL ? AppLocalization.string("Not set, uses the provider's own") : AppLocalization.string("Not set")
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await work()
                draft = ""
                editing = nil
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }
}

// MARK: - Key order

/// How Hermes picks among a provider's keys on a profile
/// (`credential_pool_strategies.<provider>` in its config).
enum KeyOrder: String, CaseIterable {
    /// Hermes' default: the first key until it hits a limit, then the next.
    case fillFirst = "fill_first"
    case roundRobin = "round_robin"
    case random
    case leastUsed = "least_used"

    /// The profile setting for `provider`, nil for an id a dotted config
    /// key can't name (a custom provider like `custom:together.ai`).
    static func settingKey(for provider: String) -> String? {
        provider.isEmpty || provider.contains(".") ? nil : "credential_pool_strategies.\(provider)"
    }

    /// Hermes' reading of a stored value: anything else is the default.
    init(stored: String?) {
        self = KeyOrder(rawValue: (stored ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? .fillFirst
    }

    var title: String {
        switch self {
        case .fillFirst: return AppLocalization.string("First key until it runs out")
        case .roundRobin: return AppLocalization.string("Take turns")
        case .random: return AppLocalization.string("Random")
        case .leastUsed: return AppLocalization.string("Least used first")
        }
    }
}

/// What the key order needs from the page: the profile's settings.
struct KeyOrderAccess {
    var kept: ([String]) -> [String: ProfileSettingValue]?
    /// Nil when Hermes didn't answer.
    var load: ([String]) async -> [String: ProfileSettingValue]?
    var save: (String, ProfileSettingValue) async -> Bool
}

/// The key order section's state, apart from its view so the order of
/// Hermes' answers and the saves can be tested.
struct KeyOrderPicks: Equatable {
    /// What's shown: Hermes' order, or the kept one until it answers. Nil
    /// shows none, Hermes' default included.
    private(set) var order: KeyOrder?
    private(set) var answered = false
    private(set) var loadFailed = false
    private(set) var saving = false
    private(set) var error: String?
    /// Counts finished saves: a read asked before one ended is dropped.
    private var writes = 0
    private var beforeSave: KeyOrder?

    /// A read, as it was asked.
    struct Read: Equatable {
        fileprivate let writes: Int
    }

    /// The kept order, until Hermes answers.
    mutating func showKept(_ stored: String?) {
        guard order == nil else { return }
        order = KeyOrder(stored: stored)
    }

    mutating func readAsked() -> Read {
        loadFailed = false
        return Read(writes: writes)
    }

    /// Hermes' answer to `read`, unless a save was out or ended since it
    /// was asked: the pick stays then.
    mutating func hermesAnswered(_ stored: String?, to read: Read) {
        guard !saving, read.writes == writes else { return }
        order = KeyOrder(stored: stored)
        answered = true
    }

    mutating func readFailed() {
        loadFailed = true
    }

    /// A save writes the setting, so it waits for Hermes' answer.
    var canPick: Bool {
        KeptAnswerGate.canSave(answered: answered, saving: saving, ready: order != nil)
    }

    /// The order to save, shown while it's written; nil when there's
    /// nothing to save or the picker waits.
    mutating func choose(_ next: KeyOrder) -> KeyOrder? {
        guard canPick, next != order else { return nil }
        beforeSave = order
        order = next
        saving = true
        error = nil
        return next
    }

    /// A save that fails puts back the order shown before it.
    mutating func saveEnded(saved: Bool) {
        saving = false
        writes += 1
        guard !saved else { return }
        order = beforeSave
        error = AppLocalization.string("Could not save the key order.")
    }
}

/// The order a profile's keys for a provider are used in, once it has
/// more than one.
private struct KeyOrderSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let entry: ProviderEntry
    let keys: Int
    let access: KeyOrderAccess
    @State private var picks = KeyOrderPicks()

    private var settingKey: String { KeyOrder.settingKey(for: entry.id) ?? "" }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Key order"), symbol: "arrow.triangle.2.circlepath", tint: .conduitAura) {
            Text(AppLocalization.string("This profile has \(String(keys)) keys for \(entry.name). Hermes moves to another when one hits its limit."))
                .scaledFont(.footnote).foregroundStyle(.secondary)
            if let order = picks.order {
                ConduitMenuPicker(
                    value: order,
                    choices: KeyOrder.allCases.map { (id: $0, title: $0.title) },
                    onSelect: choose
                ) {
                    Text(AppLocalization.string("Use keys")).foregroundStyle(.secondary)
                }
                .disabled(!picks.canPick)
            } else if !picks.loadFailed {
                // Nothing kept and Hermes not answered yet: no order is
                // shown as the profile's, Hermes' default included.
                ProgressView().frame(maxWidth: .infinity).accessibilityLabel(AppLocalization.string("Loading…"))
            }
            if picks.loadFailed && !picks.answered {
                // The picker waits for Hermes: a kept or default order may not be its own.
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalization.string("Could not load the key order."))
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                    Button(AppLocalization.string("Try Again")) { Task { await read() } }
                        .scaledFont(.subheadline.weight(.semibold))
                        .tint(.conduitAccent)
                }
            }
            if let error = picks.error {
                Text(verbatim: error).scaledFont(.caption).foregroundStyle(.red)
            }
        }
        .onAppear {
            guard let kept = access.kept([settingKey]) else { return }
            picks.showKept(kept[settingKey]?.textValue)
        }
        .task { await read() }
    }

    private func read() async {
        let asked = picks.readAsked()
        guard let loaded = await access.load([settingKey]) else {
            picks.readFailed()
            return
        }
        picks.hermesAnswered(loaded[settingKey]?.textValue, to: asked)
    }

    private func choose(_ next: KeyOrder) {
        guard let next = picks.choose(next) else { return }
        Task {
            let saved = await access.save(settingKey, .text(next.rawValue))
            picks.saveEnded(saved: saved)
        }
    }
}

// MARK: - Signing in

/// An account: signed in with Sign out, a code to enter on the provider's
/// page while Hermes waits, or the host command for one that signs in there.
private struct ProviderSignInView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: ProviderSettingsService
    let entry: ProviderEntry
    let account: ProviderEntry.AccountAccess
    let onSignedIn: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var signIn: ProviderSignIn?
    @State private var starting = false
    @State private var error: String?
    @State private var signingOut = false
    /// Check again ran and the host still has no sign-in.
    @State private var stillSignedOut = false

    private static let pollFailureLimit = 3

    var body: some View {
        if account.signedIn {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.green).accessibilityHidden(true)
                Text(AppLocalization.string("Signed in")).scaledFont(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
            }
            if !account.signsOutHere, let command = account.command {
                Text(AppLocalization.string("Sign out on the host with \(command)."))
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
        } else if account.flow == .external {
            Text(AppLocalization.string("This provider signs in on your Hermes host. Run this there, then check again:"))
                .scaledFont(.footnote).foregroundStyle(.secondary)
            if let command = account.command {
                HStack {
                    Text(verbatim: command)
                        .scaledFont(.subheadline.monospaced())
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(AppLocalization.string("Copy")) { UIPasteboard.general.string = command }
                        .buttonStyle(.settings)
                }
            }
            if stillSignedOut {
                Text(AppLocalization.string("Not signed in yet."))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
            }
            Button(AppLocalization.string("Check again")) {
                Task {
                    stillSignedOut = false
                    await service.reload()
                    let signedIn = service.entry(entry.id)?.account?.signedIn == true
                    stillSignedOut = !signedIn
                    if signedIn { onSignedIn() }
                }
            }
            .buttonStyle(.settingsPrimary)
        } else if let signIn {
            Text(AppLocalization.string("Enter this code on the sign-in page:"))
                .scaledFont(.footnote).foregroundStyle(.secondary)
            HStack {
                Text(verbatim: signIn.userCode)
                    .scaledFont(.title2.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.providers.signin.code")
                Spacer(minLength: 8)
                Button(AppLocalization.string("Copy")) { UIPasteboard.general.string = signIn.userCode }
                    .buttonStyle(.settings)
            }
            if let url = signIn.verificationURL {
                Button(AppLocalization.string("Open sign-in page")) { openURL(url) }
                    .buttonStyle(.settingsPrimary)
            }
            HStack(spacing: 8) {
                // The text beside it says what it waits for.
                ProgressView().accessibilityHidden(true)
                Text(AppLocalization.string("Waiting for you to finish…"))
                    .scaledFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { cancel() }
                    .buttonStyle(.settings)
            }
            .task(id: signIn.sessionID) { await waitForSignIn(signIn) }
        } else {
            Button { start() } label: {
                if starting { ProgressView().accessibilityLabel(AppLocalization.string("Starting…")) } else { Text(AppLocalization.string("Sign in")) }
            }
            .buttonStyle(.settingsPrimary)
            .disabled(starting)
            .accessibilityIdentifier("settings.providers.signin.start")
        }
        if let error {
            Text(verbatim: error).scaledFont(.caption).foregroundStyle(.red)
        }
    }

    private func start() {
        guard !starting else { return }
        starting = true
        error = nil
        Task {
            defer { starting = false }
            do {
                let started = try await service.startSignIn(entry.id)
                signIn = started
                if let url = started.verificationURL { openURL(url) }
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    private func waitForSignIn(_ started: ProviderSignIn) async {
        var failures = 0
        while !Task.isCancelled, signIn == started {
            let asked = ContinuousClock.now
            do {
                let outcome = try await service.poll(entry.id, signIn: started)
                failures = 0
                switch outcome {
                case .pending:
                    // A Hermes that answers at once instead of waiting is
                    // asked again only after the provider's interval.
                    let wait = Duration.seconds(started.pollInterval) - (ContinuousClock.now - asked)
                    if wait > .zero { try? await Task.sleep(for: wait) }
                    continue
                case .approved:
                    signIn = nil
                    onSignedIn()
                    return
                case .failed(let message):
                    signIn = nil
                    error = message
                    return
                }
            } catch {
                // A dropped long-poll is retried after the provider's
                // interval; one that keeps failing (Hermes restarted, the
                // sign-in gone) says so instead of waiting on.
                failures += 1
                if failures >= Self.pollFailureLimit, !Task.isCancelled {
                    // Its own task, started before signIn goes: clearing it
                    // ends this one, whose request would never be sent.
                    let service = service
                    Task { await service.cancel(started) }
                    signIn = nil
                    self.error = UserFacingError.message(for: error)
                    return
                }
                try? await Task.sleep(for: .seconds(started.pollInterval))
                continue
            }
        }
        // The page went away mid-sign-in: Hermes stops waiting too.
        if Task.isCancelled, signIn == started {
            // Its own task: this one is cancelled, and a request from it
            // would never be sent.
            let service = service
            Task { await service.cancel(started) }
        }
    }

    private func cancel() {
        guard let started = signIn else { return }
        signIn = nil
        Task { await service.cancel(started) }
    }
}

// MARK: - A custom endpoint

/// Adding or editing a custom endpoint. Find models asks the server what
/// it offers before anything is saved.
private struct CustomEndpointForm: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: ProviderSettingsService
    let existing: (name: String, endpoint: ProviderEntry.EndpointAccess)?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CustomEndpointDraft()
    @State private var keyDraft = ""
    @State private var checking = false
    @State private var saving = false
    @State private var checkMessage: String?
    @State private var checkFailed = false
    @State private var error: String?
    @State private var seeded = false

    private static let urlPlaceholder = "https://example.com/v1"

    private var isNew: Bool { existing == nil }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Server"), symbol: "server.rack", tint: .conduitAccent) {
                TextField(AppLocalization.string("Name"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.providers.endpoint.name")
                TextField(Self.urlPlaceholder, text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("settings.providers.endpoint.url")
                SecureField(isNew || existing?.endpoint.keySaved != true
                            ? AppLocalization.string("API key (optional)")
                            : AppLocalization.string("New API key (leave empty to keep the saved one)"),
                            text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                ConduitMenuPicker(value: draft.apiMode, choices: ProviderText.apiModes(), onSelect: { draft.apiMode = $0 }) {
                    Text(AppLocalization.string("API mode")).foregroundStyle(.secondary)
                }
            }
            ConduitSettingsSection(title: AppLocalization.string("Models"), symbol: "cpu", tint: .conduitAura) {
                Button { check() } label: {
                    if checking { ProgressView().accessibilityLabel(AppLocalization.string("Checking…")) } else { Text(AppLocalization.string("Find models")) }
                }
                .buttonStyle(.settings)
                .disabled(checking || draft.trimmedBaseURL.isEmpty)
                .accessibilityIdentifier("settings.providers.endpoint.check")
                if let checkMessage {
                    Text(verbatim: checkMessage).scaledFont(.caption).foregroundStyle(checkFailed ? .orange : .secondary)
                }
                if !draft.models.isEmpty {
                    ConduitMenuPicker(value: draft.model, choices: draft.models.map { (id: $0, title: $0) }, onSelect: { draft.model = $0 }) {
                        Text(AppLocalization.string("Model")).foregroundStyle(.secondary)
                    }
                } else {
                    TextField(AppLocalization.string("Model name"), text: $draft.model)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Toggle(AppLocalization.string("Use as default model"), isOn: $draft.makeDefault)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").scaledFont(.footnote).foregroundStyle(.red)
            }
            Button { save() } label: {
                Label(saving ? AppLocalization.string("Saving…") : AppLocalization.string("Save endpoint"), systemImage: "checkmark")
                    .frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 46)
            }
            .disabled(saving || !draft.canSave)
            .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent.opacity(0.18))
            .accessibilityIdentifier("settings.providers.endpoint.save")
        }
        .navigationTitle(isNew ? AppLocalization.string("Custom endpoint") : (existing?.name ?? ""))
        .onAppear(perform: seed)
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        guard let existing else { return }
        draft = CustomEndpointDraft(editing: existing.name, endpoint: existing.endpoint)
    }

    /// The typed key goes up with the check and the save, nowhere else.
    private func withKey() -> CustomEndpointDraft {
        var withKey = draft
        if withKey.endpointID.isEmpty {
            // A new endpoint's config key comes from its name.
            withKey.endpointID = service.newEndpointID(forName: draft.trimmedName)
        }
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        withKey.key = typed.isEmpty ? nil : typed
        return withKey
    }

    private func check() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            let result = await service.check(endpoint: withKey())
            checkFailed = !result.ok
            if !result.models.isEmpty {
                draft.models = result.models
                // A model typed by hand that the server doesn't list stays.
                if draft.model.isEmpty {
                    draft.model = result.models[0]
                } else if !result.models.contains(draft.model) {
                    draft.models = [draft.model] + result.models
                }
            }
            if result.ok {
                checkMessage = AppLocalization.string("The server answered.")
            } else {
                checkMessage = result.message.isEmpty ? AppLocalization.string("Hermes couldn't reach the server.") : result.message
            }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await service.save(endpoint: withKey())
                keyDraft = ""
                onSaved()
                dismiss()
            } catch {
                self.error = AppLocalization.string("Could not save the endpoint: \(UserFacingError.message(for: error))")
            }
        }
    }
}
