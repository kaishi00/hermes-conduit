//
//  CapabilityPluginsTab.swift
//  Conduit
//
//  Settings > Capabilities > Plugins, the agent half of Hermes Desktop's
//  Plugins tab: the plugins installed for the profile with their switches,
//  each with a page to update or uninstall it, then Hermes' plugin catalog
//  to install from. A change Hermes applies on the gateway's next start
//  offers Restart Gateway.
//

import SwiftUI

struct CapabilityPluginsTab: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let store: CapabilitiesStore
    let query: String
    @State private var message: String?
    @State private var pendingInstall: PluginCatalogEntry?
    @State private var rowsMemo = CapabilityListMemo<RowsInput, Rows>()

    /// Hermes applies plugin changes to the dashboard's own profile, so they
    /// are made from the default profile only.
    private var canManage: Bool { store.canManagePlugins }

    private struct RowsInput: Equatable {
        let plugins: [AgentPluginRow]
        let catalog: [PluginCatalogEntry]
        let query: String
    }

    private struct Rows {
        let installed: [AgentPluginRow]
        let catalog: [PluginCatalogEntry]
        /// Each installed plugin's catalog entry, by plugin id.
        let entries: [AgentPluginRow.ID: PluginCatalogEntry]
    }

    private var currentRows: Rows {
        rowsMemo.value(for: RowsInput(plugins: store.plugins, catalog: store.pluginCatalog, query: query)) { input in
            let installed = CapabilityPluginFilter.installed(input.plugins, query: input.query)
            var entries: [AgentPluginRow.ID: PluginCatalogEntry] = [:]
            for plugin in installed {
                entries[plugin.id] = PluginCatalogEntry.entry(for: plugin, in: input.catalog)
            }
            return Rows(
                installed: installed,
                catalog: CapabilityPluginFilter.catalog(input.catalog, query: input.query),
                entries: entries
            )
        }
    }

    var body: some View {
        let rows = currentRows
        let installed = rows.installed
        let catalog = rows.catalog
        CapabilityTabScroll(refresh: { await store.loadPlugins() }) {
            if !store.pluginsLoaded && !store.showsKept.contains(.plugins) {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if let error = store.pluginsError, store.plugins.isEmpty {
                CapabilityEmptyState(
                    title: AppLocalization.string("Couldn't load agent plugins"),
                    symbol: "exclamationmark.triangle",
                    message: error
                ) {
                    Task { await store.loadPlugins() }
                }
            } else {
                if let error = store.pluginsError {
                    CapabilityRefreshBanner(message: error)
                }
                if !canManage {
                    Text("Hermes installs plugins for the host's default profile. Switch to it to change them.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                if store.pluginsNeedRestart {
                    // The card watches the restart, so this tab doesn't
                    // observe AppState.
                    PluginRestartCard {
                        store.pluginsNeedRestart = false
                    }
                }
                if let message {
                    Text(verbatim: message)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                CapabilitySection(
                    title: AppLocalization.string("Installed"),
                    symbol: "puzzlepiece.extension",
                    footer: AppLocalization.string("Plugins extend the agent with tools, hooks and providers.")
                ) {
                    if installed.isEmpty {
                        Text(verbatim: query.isEmpty ? AppLocalization.string("No agent plugins installed for this profile.") : AppLocalization.string("Nothing matches “\(query)”."))
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(installed.enumerated()), id: \.element.id) { index, plugin in
                            CapabilityCardRow(divided: index > 0) {
                                AgentPluginListRow(
                                    plugin: plugin,
                                    catalogEntry: rows.entries[plugin.id],
                                    canManage: canManage,
                                    store: store
                                ) { error in
                                    message = error
                                }
                            }
                        }
                    }
                }
                if !catalog.isEmpty {
                    CapabilitySection(
                        title: AppLocalization.string("Plugin catalog"),
                        symbol: "shippingbox",
                        tint: .conduitAura,
                        footer: AppLocalization.string("Reviewed plugins from Hermes' catalog.")
                    ) {
                        ForEach(Array(catalog.enumerated()), id: \.element.id) { index, entry in
                            CapabilityCardRow(divided: index > 0) {
                                HStack(spacing: 10) {
                                    CapabilityRowLabel(
                                        symbol: "shippingbox",
                                        active: false,
                                        title: entry.displayName,
                                        pills: [PluginStyle.tierPill(entry.tier)],
                                        detail: entry.description
                                    )
                                    if canManage {
                                        CapabilityRowButton(
                                            title: AppLocalization.string("Install"),
                                            busy: store.pluginBusy.contains(entry.name)
                                        ) {
                                            pendingInstall = entry
                                        }
                                        .accessibilityLabel(Text("Install \(entry.displayName)"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: store.profile) {
            if !store.pluginsLoaded || store.showsKept.contains(.plugins) { await store.loadPlugins() }
        }
        .confirmationDialog(
            Text("Install \(pendingInstall?.displayName ?? "")?"),
            isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }),
            titleVisibility: .visible,
            presenting: pendingInstall
        ) { entry in
            Button(AppLocalization.string("Install")) { install(entry) }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: { entry in
            Text(verbatim: entry.capabilitySummary.isEmpty ? entry.description : entry.capabilitySummary)
        }
    }

    private func install(_ entry: PluginCatalogEntry) {
        Haptics.selection()
        message = nil
        Task {
            do {
                let outcome = try await store.installPlugin(entry)
                if !outcome.missingEnv.isEmpty {
                    message = AppLocalization.string("\(outcome.name) is installed but needs a key before it works: \(outcome.missingEnv.joined(separator: ", ")).")
                } else if outcome.restartRequired {
                    message = AppLocalization.string("\(outcome.name) is installed. Restart the gateway to load it.")
                } else {
                    Haptics.success()
                    message = AppLocalization.string("\(outcome.name) is installed and loaded.")
                }
            } catch {
                message = UserFacingError.message(for: error)
            }
        }
    }
}

enum PluginStyle {
    static func tierPill(_ tier: String) -> CapabilityPillModel {
        tier == "official"
            ? CapabilityPillModel(text: AppLocalization.string("Official"), tint: .conduitAura)
            : CapabilityPillModel(text: AppLocalization.string("Community"))
    }

    /// Where an installed plugin came from: its catalog tier when it came
    /// from the catalog, else its source.
    static func sourcePill(_ plugin: AgentPluginRow, catalogEntry: PluginCatalogEntry?) -> CapabilityPillModel? {
        if let catalogEntry { return tierPill(catalogEntry.tier) }
        switch plugin.source {
        case "bundled": return CapabilityPillModel(text: AppLocalization.string("Built-in"))
        case "git": return CapabilityPillModel(text: AppLocalization.string("Git"))
        case "user": return CapabilityPillModel(text: AppLocalization.string("Local"))
        default: return nil
        }
    }

    static func version(_ plugin: AgentPluginRow) -> String? {
        plugin.version.map { "v\($0)" }
    }
}

private struct AgentPluginListRow: View {
    let plugin: AgentPluginRow
    let catalogEntry: PluginCatalogEntry?
    let canManage: Bool
    let store: CapabilitiesStore
    let onError: (String?) -> Void

    private var pills: [CapabilityPillModel] {
        var pills = [PluginStyle.sourcePill(plugin, catalogEntry: catalogEntry)].compactMap { $0 }
        if catalogEntry?.updateAvailable == true {
            pills.append(CapabilityPillModel(text: AppLocalization.string("Update available"), tint: .conduitAccent))
        }
        if plugin.authRequired {
            pills.append(CapabilityPillModel(text: AppLocalization.string("Needs sign-in"), tint: .orange))
        }
        return pills
    }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink {
                AgentPluginDetailPage(name: plugin.name, canManage: canManage, store: store)
                    .v2TabBarClearance()
            } label: {
                CapabilityRowLabel(
                    symbol: "puzzlepiece.extension",
                    active: plugin.isEnabled,
                    title: plugin.name,
                    subtitle: PluginStyle.version(plugin),
                    pills: pills,
                    detail: plugin.description
                )
            }
            .buttonStyle(.plain)
            if store.pluginBusy.contains(plugin.name) {
                ProgressView().controlSize(.small)
            } else {
                Toggle(isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { enabled in
                        onError(nil)
                        Task {
                            do {
                                try await store.setPluginEnabled(plugin, enabled: enabled)
                            } catch {
                                onError(UserFacingError.message(for: error))
                            }
                        }
                    }
                )) {
                    Text(verbatim: plugin.name)
                }
                .labelsHidden()
                .tint(.conduitAccent)
                .disabled(!canManage)
            }
        }
    }
}

/// Restart Gateway, offered after a plugin change Hermes applies on the
/// gateway's next start.
struct PluginRestartCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var confirmingRestart = false
    /// Called once the gateway has restarted.
    var onRestarted: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AppLocalization.string("Restart the gateway to apply plugin changes."), systemImage: "arrow.triangle.2.circlepath")
                .scaledFont(.subheadline.weight(.semibold))
            Button {
                confirmingRestart = true
            } label: {
                Label(AppLocalization.string("Restart Gateway"), systemImage: "restart")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .frame(minHeight: 44)
            }
            .disabled(!appState.canRestartGateway)
            .conduitGlassControl(cornerRadius: 16, tint: .orange.opacity(0.12))
            GatewayRestartStatusView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsCard()
        .gatewayRestartConfirmation(isPresented: $confirmingRestart)
        .onChange(of: appState.activeGatewayRestart) { _, state in
            if case .restarted = state { onRestarted() }
        }
    }
}

private struct PluginConsent: Identifiable {
    var id: String { plugin.name }
    let plugin: AgentPluginRow
    let lines: [String]
}

/// A plugin's page: what it is, its switch, Update and Uninstall.
struct AgentPluginDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    let name: String
    let canManage: Bool
    let store: CapabilitiesStore
    @State private var message: String?
    @State private var confirmingRemove = false
    @State private var consent: PluginConsent?

    private var plugin: AgentPluginRow? { store.plugins.first { $0.name == name } }

    var body: some View {
        SettingsDetailContainer {
            if let plugin {
                let catalogEntry = PluginCatalogEntry.entry(for: plugin, in: store.pluginCatalog)
                let busy = store.pluginBusy.contains(plugin.name)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(verbatim: plugin.name)
                            .scaledFont(.title3.weight(.semibold))
                        if let version = PluginStyle.version(plugin) {
                            Text(verbatim: version)
                                .scaledFont(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !plugin.description.isEmpty {
                        Text(verbatim: plugin.description)
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let pill = PluginStyle.sourcePill(plugin, catalogEntry: catalogEntry) {
                        CapabilityPill(text: pill.text, tint: pill.tint)
                    }
                    if plugin.authRequired {
                        Text(verbatim: plugin.authCommand.map { AppLocalization.string("It needs a sign-in on your host: \($0)") }
                            ?? AppLocalization.string("It needs a sign-in on your host."))
                            .scaledFont(.footnote)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    Toggle(isOn: Binding(
                        get: { plugin.isEnabled },
                        set: { enabled in
                            message = nil
                            Task {
                                do {
                                    try await store.setPluginEnabled(plugin, enabled: enabled)
                                } catch {
                                    message = UserFacingError.message(for: error)
                                }
                            }
                        }
                    )) {
                        Text("Turned on")
                            .scaledFont(.subheadline.weight(.semibold))
                    }
                    .tint(.conduitAccent)
                    .disabled(!canManage || busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .settingsCard()
                if store.pluginsNeedRestart {
                    PluginRestartCard {
                        store.pluginsNeedRestart = false
                    }
                }
                if let message {
                    Text(verbatim: message)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                if canManage, plugin.canUpdate {
                    Button {
                        update(plugin, accept: false)
                    } label: {
                        Label(
                            busy ? AppLocalization.string("Updating…")
                                : catalogEntry?.updateAvailable == true ? AppLocalization.string("Update") : AppLocalization.string("Check for Update"),
                            systemImage: "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                    }
                    .disabled(busy)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                }
                if canManage, plugin.canRemove {
                    Button(role: .destructive) {
                        confirmingRemove = true
                    } label: {
                        Label(AppLocalization.string("Uninstall"), systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                    }
                    .disabled(busy)
                    .conduitGlassControl(cornerRadius: 16, tint: .red.opacity(0.12))
                }
                if !canManage {
                    Text("Hermes installs plugins for the host's default profile. Switch to it to change them.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            } else {
                Text("This plugin isn't installed anymore.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .navigationTitle(Text(verbatim: name))
        .confirmationDialog(
            Text("Uninstall \(name)?"),
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Uninstall"), role: .destructive) { remove() }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text("This deletes the plugin's files from your host. Restart the gateway to unload it. You can install it again from the catalog.")
        }
        .alert(
            Text("\(name) asks for more"),
            isPresented: Binding(get: { consent != nil }, set: { if !$0 { consent = nil } }),
            presenting: consent
        ) { consent in
            Button(AppLocalization.string("Apply Update")) { update(consent.plugin, accept: true) }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: { consent in
            let added = consent.lines.joined(separator: "\n")
            if added.isEmpty {
                Text(verbatim: AppLocalization.string("The new version adds what the installed one doesn't have. Apply it only if you trust it."))
            } else {
                Text(verbatim: AppLocalization.string("The new version adds what the installed one doesn't have. Apply it only if you trust it:\n\n\(added)"))
            }
        }
    }

    private func update(_ plugin: AgentPluginRow, accept: Bool) {
        Haptics.selection()
        message = nil
        Task {
            do {
                switch try await store.updatePlugin(plugin, acceptCapabilities: accept) {
                case .upToDate:
                    message = AppLocalization.string("\(plugin.name) is up to date.")
                case .updated(let restartRequired):
                    Haptics.success()
                    message = restartRequired
                        ? AppLocalization.string("\(plugin.name) is updated. Restart the gateway to apply it.")
                        : AppLocalization.string("\(plugin.name) is updated.")
                case .needsConsent(let lines):
                    consent = PluginConsent(plugin: plugin, lines: lines)
                }
            } catch is CancellationError {
                return
            } catch {
                message = UserFacingError.message(for: error)
            }
        }
    }

    private func remove() {
        guard let plugin else { return }
        Task {
            do {
                try await store.removePlugin(plugin)
                Haptics.success()
                dismiss()
            } catch {
                message = UserFacingError.message(for: error)
            }
        }
    }
}
