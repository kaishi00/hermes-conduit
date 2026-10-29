//
//  CapabilityConnectorsTab.swift
//  Conduit
//
//  Settings > Capabilities > Connectors, as Hermes Desktop's Connectors
//  tab for the MCP servers on the host: the ones that are on (tested live,
//  broken ones first), the catalog's servers to install, and the ones that
//  are off. Each server's page tests it, signs it in, lists its tools and
//  removes it.
//

import SwiftUI

struct CapabilityConnectorsTab: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let store: CapabilitiesStore
    let query: String
    @State private var installing: ConnectorCatalogEntry?
    @State private var actionError: String?

    private var states: [String: ConnectorState] {
        Dictionary(store.servers.map { server in
            (server.name, ConnectorState.of(server, probe: store.probes[server.name], probing: store.probing.contains(server.name)))
        }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let states = self.states
        let groups = ConnectorGrouping.groups(
            servers: store.servers,
            catalog: store.connectorCatalog,
            states: states,
            query: query
        )
        CapabilityTabScroll(refresh: { await reload(force: true) }) {
            if !store.connectorsLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if let error = store.connectorsError, store.servers.isEmpty {
                CapabilityEmptyState(
                    title: AppLocalization.string("Couldn't read the MCP servers"),
                    symbol: "exclamationmark.triangle",
                    message: error
                ) {
                    Task { await reload(force: false) }
                }
            } else if groups.connected.isEmpty && groups.available.isEmpty && groups.off.isEmpty {
                CapabilityEmptyState(
                    title: query.isEmpty ? AppLocalization.string("No connectors yet") : AppLocalization.string("No matching connectors"),
                    symbol: "point.3.connected.trianglepath.dotted",
                    message: query.isEmpty
                        ? AppLocalization.string("Ask Hermes to add an MCP server, or install one from the catalog when it lists some.")
                        : AppLocalization.string("Nothing matches “\(query)”.")
                )
            } else {
                if let error = store.connectorsError {
                    CapabilityRefreshBanner(message: error)
                }
                if let actionError {
                    Text(verbatim: actionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
                if !groups.connected.isEmpty {
                    CapabilitySection(
                        title: AppLocalization.string("Connected"),
                        symbol: "bolt.horizontal.circle",
                        footer: AppLocalization.string("Each server is tested when this page opens. Changes apply to new sessions.")
                    ) {
                        serverRows(groups.connected, states: states)
                    }
                }
                if !groups.available.isEmpty {
                    CapabilitySection(
                        title: AppLocalization.string("Available"),
                        symbol: "square.grid.2x2",
                        tint: .conduitAura,
                        footer: AppLocalization.string("From Hermes' MCP catalog.")
                    ) {
                        ForEach(Array(groups.available.enumerated()), id: \.element.id) { index, entry in
                            CapabilityCardRow(divided: index > 0) {
                                ConnectorCatalogRow(entry: entry, store: store) {
                                    install(entry)
                                }
                            }
                        }
                    }
                }
                if !groups.off.isEmpty {
                    CapabilitySection(
                        title: AppLocalization.string("Turned off"),
                        symbol: "moon",
                        tint: .secondary,
                        footer: AppLocalization.string("Sign-ins and keys are kept.")
                    ) {
                        serverRows(groups.off, states: states)
                    }
                }
            }
        }
        .task(id: store.profile) {
            if !store.connectorsLoaded { await store.loadConnectors() }
            await store.probeServers()
        }
        .sheet(item: $installing) { entry in
            ConnectorInstallSheet(entry: entry) { env in
                Task { await store.installConnector(entry, env: env) }
            }
        }
    }

    private func serverRows(_ servers: [ConnectorServer], states: [String: ConnectorState]) -> some View {
        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
            CapabilityCardRow(divided: index > 0) {
                ConnectorServerRow(
                    server: server,
                    state: states[server.name] ?? .unknown,
                    catalogEntry: store.connectorCatalog.first { $0.name == server.name },
                    store: store
                ) { error in
                    actionError = error
                }
            }
        }
    }

    /// Reads the servers again, then tests them: all of them on a pull to
    /// refresh, the ones not tested lately otherwise.
    private func reload(force: Bool) async {
        await store.loadConnectors()
        await store.probeServers(force: force)
    }

    /// An entry that asks for nothing installs in one tap; one with keys
    /// asks for them first.
    private func install(_ entry: ConnectorCatalogEntry) {
        Haptics.selection()
        store.clearConnectorInstallFailure(entry.name)
        if entry.requiredEnv.isEmpty {
            Task { await store.installConnector(entry, env: [:]) }
        } else {
            installing = entry
        }
    }
}

enum ConnectorStyle {
    static func symbol(_ server: ConnectorServer) -> String {
        if server.isFromPlugin { return "puzzlepiece.extension" }
        switch server.transport {
        case "http": return "globe"
        case "stdio": return "terminal"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// MCP · Plugin x, MCP · Catalog or MCP · Custom, as Desktop says it.
    static func kind(_ server: ConnectorServer, inCatalog: Bool) -> String {
        if let plugin = server.plugin {
            return plugin.isEmpty ? AppLocalization.string("MCP · Plugin") : AppLocalization.string("MCP · Plugin \(plugin)")
        }
        return inCatalog ? AppLocalization.string("MCP · Catalog") : AppLocalization.string("MCP · Custom")
    }

    static func word(_ state: ConnectorState) -> String? {
        switch state {
        case .off: return AppLocalization.string("Off")
        case .checking: return AppLocalization.string("Checking…")
        case .unknown: return nil
        case .on(let toolCount): return toolCount > 0 ? AppLocalization.string("\(toolCount) tools") : AppLocalization.string("On")
        case .needsSignIn: return AppLocalization.string("Needs sign-in")
        case .failed: return AppLocalization.string("Error")
        }
    }

    static func dot(_ state: ConnectorState) -> Color? {
        switch state {
        case .off, .unknown: return nil
        case .checking: return .secondary
        case .on: return .green
        case .needsSignIn: return .orange
        case .failed: return .red
        }
    }

    /// The line under the name: why it's broken, or what it is.
    static func detail(_ server: ConnectorServer, state: ConnectorState, catalogEntry: ConnectorCatalogEntry?) -> String? {
        switch state {
        case .failed(let error) where !error.isEmpty:
            return error
        case .needsSignIn:
            return AppLocalization.string("Sign in to let this server answer.")
        default:
            if let description = catalogEntry?.description, !description.isEmpty { return description }
            return server.url ?? server.command
        }
    }
}

private struct ConnectorServerRow: View {
    let server: ConnectorServer
    let state: ConnectorState
    let catalogEntry: ConnectorCatalogEntry?
    let store: CapabilitiesStore
    let onError: (String?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink {
                ConnectorDetailPage(name: server.name, store: store)
                    .v2TabBarClearance()
            } label: {
                CapabilityRowLabel(
                    symbol: ConnectorStyle.symbol(server),
                    active: server.enabled,
                    title: server.name,
                    subtitle: ConnectorStyle.kind(server, inCatalog: catalogEntry != nil),
                    detail: ConnectorStyle.detail(server, state: state, catalogEntry: catalogEntry),
                    meta: ConnectorStyle.word(state),
                    metaDot: ConnectorStyle.dot(state)
                )
            }
            .buttonStyle(.plain)
            if !server.isFromPlugin {
                Toggle(isOn: Binding(
                    get: { server.enabled },
                    set: { enabled in
                        onError(nil)
                        Task {
                            do {
                                try await store.setServerEnabled(server.name, enabled: enabled)
                            } catch {
                                onError(UserFacingError.message(for: error))
                            }
                        }
                    }
                )) {
                    Text(verbatim: server.name)
                }
                .labelsHidden()
                .tint(.conduitAccent)
            }
        }
    }
}

private struct ConnectorCatalogRow: View {
    let entry: ConnectorCatalogEntry
    let store: CapabilitiesStore
    let install: () -> Void

    private var state: CapabilityInstallState? { store.connectorInstalls[entry.name] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CapabilityRowLabel(
                    symbol: entry.transport == "http" ? "globe" : "terminal",
                    active: false,
                    title: entry.name,
                    subtitle: AppLocalization.string("MCP · Catalog"),
                    pills: entry.authType == "oauth" ? [CapabilityPillModel(text: AppLocalization.string("Sign-in"))] : [],
                    detail: entry.description
                )
                CapabilityRowButton(title: AppLocalization.string("Install"), busy: state == .running, action: install)
                    .accessibilityLabel(Text("Install \(entry.name)"))
            }
            if case .failed(let reason) = state {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 41)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// A server's page: its state and switch, where it runs, test and sign-in,
/// the tools it brings, and Remove.
struct ConnectorDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String
    let store: CapabilitiesStore
    @State private var signInFlow: String?
    @State private var signInTask: Task<Void, Never>?
    @State private var message: String?
    @State private var confirmingRemove = false
    @State private var removing = false

    private var server: ConnectorServer? { store.servers.first { $0.name == name } }
    private var probe: ConnectorProbe? { store.probes[name] }
    private var catalogEntry: ConnectorCatalogEntry? { store.connectorCatalog.first { $0.name == name } }

    var body: some View {
        SettingsDetailContainer {
            if let server {
                let state = ConnectorState.of(server, probe: probe, probing: store.probing.contains(name))
                header(server, state: state)
                ConduitSettingsSection(title: AppLocalization.string("Connection"), symbol: "link", tint: .conduitAura) {
                    if let url = server.url {
                        SettingsMetricRow(label: AppLocalization.string("Address"), value: url, lineLimit: 2)
                    }
                    if let command = server.command {
                        SettingsMetricRow(label: AppLocalization.string("Command"), value: ([command] + server.args).joined(separator: " "), lineLimit: 3)
                    }
                    if server.enabled {
                        actions(server, state: state)
                    }
                    if let message {
                        Text(verbatim: message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                toolsSection(server, state: state)
                if !server.isFromPlugin {
                    Button(role: .destructive) {
                        confirmingRemove = true
                    } label: {
                        Label(AppLocalization.string("Remove Server"), systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                    }
                    .disabled(removing)
                    .conduitGlassControl(cornerRadius: 16, tint: .red.opacity(0.12))
                }
            } else {
                Text("This server isn't configured anymore.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            Text("Changes apply to new sessions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        // Turned on lands after the host answers, so the actions and tools
        // it reveals animate on the value, page-wide.
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: server?.enabled)
        .navigationTitle(Text(verbatim: name))
        .task(id: name) {
            if let server, server.enabled, probe == nil, !store.probing.contains(name) {
                await store.probe(name)
            }
        }
        .onDisappear {
            // The host finishes a sign-in on its own; this page stops
            // waiting for it, so it mustn't come back still saying so.
            signInTask?.cancel()
            if signInFlow != nil {
                signInFlow = nil
                message = nil
            }
        }
        .confirmationDialog(
            Text("Remove \(name)?"),
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Remove"), role: .destructive) { remove() }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text("The server leaves this profile's config on your host. Its keys stay in .env.")
        }
    }

    private func header(_ server: ConnectorServer, state: ConnectorState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: server.name)
                .font(.title3.weight(.semibold))
            Text(verbatim: ConnectorStyle.kind(server, inCatalog: catalogEntry != nil))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let description = catalogEntry?.description, !description.isEmpty {
                Text(verbatim: description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let word = ConnectorStyle.word(state) {
                HStack(spacing: 6) {
                    if let dot = ConnectorStyle.dot(state) {
                        Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(verbatim: word)
                        .font(.subheadline.weight(.semibold))
                }
            }
            if case .failed(let error) = state, !error.isEmpty {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let plugin = server.plugin {
                Text(verbatim: plugin.isEmpty
                    ? AppLocalization.string("A plugin provides this server. Change it from Plugins.")
                    : AppLocalization.string("The \(plugin) plugin provides this server. Change it from Plugins."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Toggle(isOn: Binding(
                    get: { server.enabled },
                    set: { enabled in
                        message = nil
                        Task {
                            do {
                                try await store.setServerEnabled(server.name, enabled: enabled)
                            } catch {
                                message = UserFacingError.message(for: error)
                            }
                        }
                    }
                )) {
                    Text("Turned on")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(.conduitAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsCard()
    }

    @ViewBuilder
    private func actions(_ server: ConnectorServer, state: ConnectorState) -> some View {
        Button {
            Haptics.selection()
            message = nil
            Task { await store.probe(server.name) }
        } label: {
            Label(
                state == .checking ? AppLocalization.string("Testing…") : AppLocalization.string("Test Connection"),
                systemImage: "arrow.clockwise"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
        }
        .disabled(state == .checking)
        .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.12))
        if server.canSignIn, state == .needsSignIn || server.auth == "oauth" {
            if signInFlow != nil {
                Button {
                    cancelSignIn()
                } label: {
                    Label(AppLocalization.string("Stop Waiting"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                }
                .conduitGlassControl(cornerRadius: 16, tint: .orange.opacity(0.12))
            } else {
                Button {
                    signIn()
                } label: {
                    Label(AppLocalization.string("Sign In"), systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                }
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
            }
        }
    }

    @ViewBuilder
    private func toolsSection(_ server: ConnectorServer, state: ConnectorState) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Tools"), symbol: "wrench.and.screwdriver", tint: .conduitAccent) {
            if !server.enabled {
                Text(verbatim: AppLocalization.string("\(server.name) is off. Turn it on to read the tools it brings."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if state == .checking || (probe == nil && state == .unknown) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the tool list…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let probe, probe.ok {
                if probe.tools.isEmpty {
                    Text("This server brings no tools.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(probe.tools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: tool.name)
                                .font(.caption.monospaced().weight(.semibold))
                            if !tool.description.isEmpty {
                                Text(verbatim: tool.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if state == .needsSignIn {
                Text(verbatim: AppLocalization.string("Sign in to \(server.name) to read its tools."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tool list unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Starts Hermes' OAuth flow, opens its page in the browser, and waits
    /// for the host to receive the callback.
    private func signIn() {
        Haptics.selection()
        message = nil
        signInTask?.cancel()
        signInTask = Task {
            do {
                let flow = try await store.startSignIn(name)
                // Leaving the page cancels this task; a request that finishes
                // anyway must not bring the wait back.
                try Task.checkCancellation()
                signInFlow = flow.flowID
                message = AppLocalization.string("Finish the sign-in in your browser.")
                openURL(flow.url)
                for _ in 0..<150 {
                    try await Task.sleep(for: .seconds(2))
                    guard signInFlow == flow.flowID else { return }
                    let status = try await store.signInStatus(flow.flowID)
                    try Task.checkCancellation()
                    if status.status == "approved" {
                        signInFlow = nil
                        message = AppLocalization.string("Signed in.")
                        Haptics.success()
                        await store.probe(name)
                        return
                    }
                    if status.status == "error" {
                        signInFlow = nil
                        message = status.error ?? AppLocalization.string("The sign-in didn't finish.")
                        return
                    }
                }
                signInFlow = nil
                message = AppLocalization.string("The sign-in timed out. Try again.")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                signInFlow = nil
                message = UserFacingError.message(for: error)
            }
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        guard let flow = signInFlow else { return }
        signInFlow = nil
        message = nil
        Task { await store.cancelSignIn(flow) }
    }

    private func remove() {
        removing = true
        Task {
            do {
                try await store.removeServer(name)
                Haptics.success()
                removing = false
                dismiss()
            } catch {
                message = UserFacingError.message(for: error)
                removing = false
            }
        }
    }
}

/// Install a catalog server: what it runs, and the keys it asks for. Takes
/// plain values (no AppState) as a sheet should.
struct ConnectorInstallSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    let entry: ConnectorCatalogEntry
    let install: ([String: String]) -> Void
    @State private var values: [String: String] = [:]

    private var canInstall: Bool {
        entry.requiredEnv.filter(\.required).allSatisfy {
            !(values[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !entry.description.isEmpty {
                    Section {
                        Text(verbatim: entry.description)
                            .font(.subheadline)
                    }
                }
                Section {
                    if let url = entry.url {
                        Text(verbatim: url)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if let command = entry.command {
                        Text(verbatim: ([command] + entry.args).joined(separator: " "))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Runs")
                } footer: {
                    Text("Check what it runs before you install it.")
                }
                Section {
                    ForEach(entry.requiredEnv) { field in
                        SecureField(
                            field.required ? field.prompt : AppLocalization.string("\(field.prompt) (optional)"),
                            text: Binding(
                                get: { values[field.name] ?? "" },
                                set: { values[field.name] = $0 }
                            )
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                } header: {
                    Text("Keys")
                } footer: {
                    Text("Saved to this profile on your host. Conduit never reads them back.")
                }
            }
            .navigationTitle(Text(verbatim: entry.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Install")) {
                        let filled = values.compactMapValues { value -> String? in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            return trimmed.isEmpty ? nil : trimmed
                        }
                        install(filled)
                        dismiss()
                    }
                    .disabled(!canInstall)
                }
            }
        }
    }
}
