//
//  CapabilityToolsTab.swift
//  Conduit
//
//  Settings > Capabilities > Tools, as Hermes Desktop's Tools tab: the
//  profile's toolsets, the most called first, each with its switch and its
//  own page: its tools, which backend serves it, and the keys it needs.
//

import SwiftUI

struct CapabilityToolsTab: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let store: CapabilitiesStore
    let query: String
    let refresh: () async -> Void
    @AppStorage("capabilities.tools.mostUsedFirst") private var mostUsedFirst = true
    @State private var bulkRunning = false

    private var visible: [CapabilityToolset] {
        appState.toolsets.filter(CapabilityToolsetOrdering.isVisible)
    }

    private var toolsets: [CapabilityToolset] {
        CapabilityToolsetOrdering.sorted(
            visible.filter { CapabilityToolsetOrdering.matches($0, query: query) },
            counts: store.toolCalls ?? [:],
            mostUsedFirst: mostUsedFirst
        )
    }

    var body: some View {
        let toolsets = self.toolsets
        CapabilityTabScroll(refresh: {
            await refresh()
            await store.loadToolCalls()
        }) {
            if toolsets.isEmpty {
                CapabilityEmptyState(
                    title: query.isEmpty ? AppLocalization.string("No tools yet") : AppLocalization.string("No matching tools"),
                    symbol: "wrench.and.screwdriver",
                    message: query.isEmpty ? nil : AppLocalization.string("Nothing matches “\(query)”.")
                )
            } else {
                CapabilitySection(
                    title: AppLocalization.string("Toolsets"),
                    symbol: "wrench.and.screwdriver",
                    footer: AppLocalization.string("Changes apply to new sessions.")
                ) {
                    optionsMenu
                } content: {
                    ForEach(Array(toolsets.enumerated()), id: \.element.name) { index, toolset in
                        CapabilityCardRow(divided: index > 0) {
                            CapabilityToolsetRow(toolset: toolset, counts: store.toolCalls, store: store)
                        }
                    }
                }
            }
        }
        .task(id: store.profile) {
            if store.toolCalls == nil || store.showsKept.contains(.toolCalls) { await store.loadToolCalls() }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker(selection: $mostUsedFirst) {
                Text("Most used first").tag(true)
                Text("Least used first").tag(false)
            } label: {
                Text("Sort")
            }
            Divider()
            // They pick their toolsets from the list shown: a kept one waits
            // for Hermes' answer.
            Group {
                Button {
                    setAll(enabled: true)
                } label: {
                    Label(AppLocalization.string("Turn All On"), systemImage: "checkmark.circle")
                }
                Button {
                    setAll(enabled: false)
                } label: {
                    Label(AppLocalization.string("Turn All Off"), systemImage: "circle")
                }
            }
            .disabled(appState.capabilitiesAreKept || !appState.canChangeCapabilities)
        } label: {
            if bulkRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis.circle")
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(bulkRunning)
        .accessibilityLabel(Text("Tool options"))
    }

    /// One switch at a time; a dashboard or profile switch midway stops it.
    private func setAll(enabled: Bool) {
        let targets = visible.filter { $0.enabled != enabled }.map(\.name)
        guard !bulkRunning, !appState.capabilitiesAreKept, !targets.isEmpty, let rows = appState.capabilitiesOwner else { return }
        Haptics.selection()
        bulkRunning = true
        Task {
            for name in targets {
                await appState.toggleToolset(name: name, enabled: enabled, rows: rows)
            }
            bulkRunning = false
        }
    }
}

enum CapabilityToolsetStyle {
    static func symbol(_ name: String) -> String {
        switch name {
        case "web": return "globe"
        case "browser": return "safari"
        case "terminal": return "terminal"
        case "file": return "doc"
        case "vision": return "eye"
        case "image_gen": return "photo"
        case "video_gen": return "film"
        case "tts": return "speaker.wave.2"
        case "memory": return "brain"
        case "skills": return "puzzlepiece.extension"
        case "session_search": return "magnifyingglass"
        case "todo": return "checklist"
        case "clarify": return "questionmark.bubble"
        case "code_execution": return "chevron.left.forwardslash.chevron.right"
        case "delegation": return "person.2"
        case "cronjob": return "clock"
        case "messaging": return "paperplane"
        case "homeassistant": return "house"
        case "computer_use": return "cursorarrow.rays"
        case "kanban": return "rectangle.split.3x1"
        default: return "wrench.and.screwdriver"
        }
    }

    static func needsKeysPill() -> CapabilityPillModel {
        CapabilityPillModel(text: AppLocalization.string("Needs keys"), tint: .orange)
    }
}

private struct CapabilityToolsetRow: View {
    @EnvironmentObject private var appState: AppState
    let toolset: CapabilityToolset
    /// Nil while the counts load.
    let counts: [String: Int]?
    let store: CapabilitiesStore

    private var meta: String? {
        if let counts {
            let calls = CapabilityToolsetOrdering.calls(toolset, counts: counts)
            if calls > 0 { return CapabilityFormat.uses(calls) }
        }
        let toolCount = toolset.tools?.count ?? 0
        return toolCount > 0 ? AppLocalization.string("\(toolCount) tools") : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink {
                CapabilityToolsetDetailPage(name: toolset.name, store: store)
                    .v2TabBarClearance()
            } label: {
                CapabilityRowLabel(
                    symbol: CapabilityToolsetStyle.symbol(toolset.name),
                    active: toolset.enabled,
                    title: CapabilityToolsetOrdering.label(toolset),
                    pills: toolset.configured == false ? [CapabilityToolsetStyle.needsKeysPill()] : [],
                    detail: toolset.description,
                    meta: meta
                )
            }
            .buttonStyle(.plain)
            Toggle(isOn: Binding(
                get: { toolset.enabled },
                set: { enabled in Task { await appState.toggleToolset(name: toolset.name, enabled: enabled) } }
            )) {
                Text(verbatim: CapabilityToolsetOrdering.label(toolset))
            }
            .labelsHidden()
            .disabled(!appState.canChangeCapabilities)
            .tint(.conduitAccent)
        }
    }
}

/// A toolset's page: its switch and tools, where the terminal runs, and
/// which backend serves it with the keys each needs.
struct CapabilityToolsetDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let name: String
    let store: CapabilitiesStore
    @State private var config: ToolsetConfig?
    @State private var configError: String?
    @State private var backends: [TerminalBackendOption]?
    @State private var backendsError: String?
    @State private var working: String?
    @State private var notice: String?
    @State private var keyPrompt: ToolsetConfig.EnvVar?
    @State private var keyValue = ""
    @State private var backendToConfirm: TerminalBackendOption?

    /// Reads again for another dashboard or profile, and once the store
    /// has been pointed at it.
    private var detailScope: CapabilityDetailScope {
        let owner = appState.currentCapabilitiesOwner
        return CapabilityDetailScope(owner: owner, ready: store.serves(owner))
    }

    /// Only while the list is this dashboard's and profile's.
    private var toolset: CapabilityToolset? {
        appState.capabilitiesAreCurrent ? appState.toolsets.first { $0.name == name } : nil
    }

    var body: some View {
        SettingsDetailContainer {
            if let toolset {
                header(toolset)
                if let tools = toolset.tools, !tools.isEmpty {
                    ConduitSettingsSection(title: AppLocalization.string("Tools"), symbol: "wrench.and.screwdriver", tint: .conduitAura) {
                        CapabilityFlowLayout {
                            ForEach(tools, id: \.self) { tool in
                                toolChip(tool)
                            }
                        }
                    }
                }
            }
            if appState.capabilitiesAreCurrent, let notice {
                Text(verbatim: notice)
                    .scaledFont(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }
            if appState.capabilitiesAreCurrent, name == "terminal" {
                terminalSection
            }
            if appState.capabilitiesAreCurrent, let config, config.hasCategory, !config.providers.isEmpty {
                ConduitSettingsSection(title: AppLocalization.string("Backends"), symbol: "server.rack", tint: .conduitAccent) {
                    ForEach(Array(config.providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { Divider().opacity(0.6) }
                        providerRow(provider, config: config)
                    }
                }
            } else if appState.capabilitiesAreCurrent, let configError {
                Text(verbatim: configError)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            Text("Changes apply to new sessions.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .navigationTitle(Text(verbatim: toolset.map(CapabilityToolsetOrdering.label) ?? name))
        // Read again for another dashboard or profile: what the last one
        // answered never stays on screen to be acted on.
        .task(id: detailScope) {
            config = nil
            configError = nil
            backends = nil
            backendsError = nil
            notice = nil
            // A key prompt or backend confirmation still open belongs to
            // the last one.
            keyPrompt = nil
            keyValue = ""
            backendToConfirm = nil
            guard store.serves(appState.currentCapabilitiesOwner) else { return }
            await load()
        }
        .alert(
            Text(verbatim: keyPrompt?.key ?? ""),
            isPresented: Binding(get: { keyPrompt != nil }, set: { if !$0 { keyPrompt = nil } }),
            presenting: keyPrompt
        ) { env in
            SecureField(AppLocalization.string("API key"), text: $keyValue)
            Button(AppLocalization.string("Save")) { save(keyValue, for: env) }
            Button(AppLocalization.string("Cancel"), role: .cancel) { keyValue = "" }
        } message: { env in
            Text(verbatim: env.prompt == env.key ? AppLocalization.string("Saved to this profile on your host. Conduit never reads it back.") : env.prompt)
        }
        .confirmationDialog(
            Text("Use \(backendToConfirm?.label ?? "") anyway?"),
            isPresented: Binding(get: { backendToConfirm != nil }, set: { if !$0 { backendToConfirm = nil } }),
            titleVisibility: .visible,
            presenting: backendToConfirm
        ) { backend in
            Button(AppLocalization.string("Use Anyway")) { select(backend) }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: { backend in
            Text(verbatim: backend.detail ?? AppLocalization.string("It still needs setting up on your host."))
        }
    }

    private func header(_ toolset: CapabilityToolset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(verbatim: CapabilityToolsetOrdering.label(toolset))
                    .scaledFont(.title3.weight(.semibold))
                if toolset.configured == false {
                    let pill = CapabilityToolsetStyle.needsKeysPill()
                    CapabilityPill(text: pill.text, tint: pill.tint)
                }
            }
            if let description = toolset.description, !description.isEmpty {
                Text(verbatim: description)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let counts = store.toolCalls {
                let calls = CapabilityToolsetOrdering.calls(toolset, counts: counts)
                if calls > 0 {
                    Text(verbatim: CapabilityFormat.uses(calls))
                        .scaledFont(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(
                get: { toolset.enabled },
                set: { enabled in Task { await appState.toggleToolset(name: toolset.name, enabled: enabled) } }
            )) {
                Text("Turned on")
                    .scaledFont(.subheadline.weight(.semibold))
            }
            .disabled(!appState.canChangeCapabilities)
            .tint(.conduitAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsCard()
    }

    private func toolChip(_ tool: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: tool)
                .scaledFont(.caption.monospaced())
            if let count = store.toolCalls?[tool], count > 0 {
                Text(verbatim: CapabilityFormat.uses(count))
                    .scaledFont(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private var terminalSection: some View {
        if let backends, !backends.isEmpty {
            ConduitSettingsSection(title: AppLocalization.string("Runs commands in"), symbol: "terminal", tint: .conduitAura) {
                ForEach(Array(backends.enumerated()), id: \.element.id) { index, backend in
                    if index > 0 { Divider().opacity(0.6) }
                    Button {
                        guard !backend.active else { return }
                        if backend.status == "ready" {
                            select(backend)
                        } else {
                            backendToConfirm = backend
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(verbatim: backend.label)
                                        .scaledFont(.subheadline.weight(.semibold))
                                    Self.backendPill(backend.status)
                                }
                                if !backend.description.isEmpty {
                                    Text(verbatim: backend.description)
                                        .scaledFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let detail = backend.detail, backend.status != "ready" {
                                    Text(verbatim: detail)
                                        .scaledFont(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            if working == backend.name {
                                ProgressView().controlSize(.small)
                            } else if backend.active {
                                Image(systemName: "checkmark")
                                    .scaledFont(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.conduitAccent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(working != nil || backend.status == "unavailable")
                    .accessibilityAddTraits(backend.active ? .isSelected : [])
                }
            }
        } else if let backendsError {
            Text(verbatim: backendsError)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private static func backendPill(_ status: String) -> some View {
        switch status {
        case "ready":
            CapabilityPill(text: AppLocalization.string("Ready"), tint: .green)
        case "needs_setup":
            CapabilityPill(text: AppLocalization.string("Needs setup"), tint: .orange)
        case "unavailable":
            CapabilityPill(text: AppLocalization.string("Unavailable"))
        default:
            EmptyView()
        }
    }

    private static func providerStatusPill(_ status: String) -> CapabilityPillModel? {
        switch status {
        case "ready": return CapabilityPillModel(text: AppLocalization.string("Ready"), tint: .green)
        case "needs_setup": return CapabilityPillModel(text: AppLocalization.string("Needs setup"), tint: .orange)
        case "needs_auth": return CapabilityPillModel(text: AppLocalization.string("Needs sign-in"), tint: .orange)
        case "needs_keys": return CapabilityToolsetStyle.needsKeysPill()
        default: return nil
        }
    }

    private func providerRow(_ provider: ToolsetConfig.Provider, config: ToolsetConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(verbatim: provider.name)
                    .scaledFont(.subheadline.weight(.semibold))
                if !provider.badge.isEmpty {
                    CapabilityPill(text: provider.badge, tint: .conduitAura)
                }
                if let pill = Self.providerStatusPill(provider.status) {
                    CapabilityPill(text: pill.text, tint: pill.tint)
                }
                Spacer(minLength: 4)
                if working == provider.name {
                    ProgressView().controlSize(.small)
                }
            }
            if !provider.tag.isEmpty {
                Text(verbatim: provider.tag)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(provider.envVars) { env in
                HStack(spacing: 8) {
                    Text(verbatim: env.key)
                        .scaledFont(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: env.isSet ? AppLocalization.string("Set") : AppLocalization.string("Not set"))
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(env.isSet ? Color.green : Color.orange)
                    Button(env.isSet ? AppLocalization.string("Replace") : AppLocalization.string("Add")) {
                        keyValue = ""
                        keyPrompt = env
                    }
                    .scaledFont(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(.conduitAccent)
                    .accessibilityLabel(Text(verbatim: env.isSet ? AppLocalization.string("Replace \(env.key)") : AppLocalization.string("Add \(env.key)")))
                }
            }
            providerActions(provider, config: config)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func providerActions(_ provider: ToolsetConfig.Provider, config: ToolsetConfig) -> some View {
        if name == "web", !provider.capabilities.isEmpty {
            HStack(spacing: 8) {
                ForEach(provider.capabilities, id: \.self) { capability in
                    if config.serves(capability, provider: provider) {
                        Label(
                            capability == "extract" ? AppLocalization.string("Used for Extract") : AppLocalization.string("Used for Search"),
                            systemImage: "checkmark"
                        )
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(Color.conduitAccent)
                    } else {
                        CapabilityRowButton(
                            title: capability == "extract" ? AppLocalization.string("Use for Extract") : AppLocalization.string("Use for Search")
                        ) {
                            choose(provider, capability: capability)
                        }
                        .disabled(working != nil)
                    }
                }
            }
        } else if provider.isActive {
            Label(AppLocalization.string("In use"), systemImage: "checkmark")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
        } else {
            CapabilityRowButton(title: AppLocalization.string("Use This Backend")) {
                choose(provider, capability: nil)
            }
            .disabled(working != nil)
        }
    }

    private func load() async {
        async let configLoad = try? store.toolsetConfig(name: name)
        // A read a switch cancelled leaves the next one's page alone.
        if name == "terminal" {
            let fresh = try? await store.terminalBackends()
            guard !Task.isCancelled else { return }
            if let fresh {
                backends = fresh
                backendsError = nil
            } else if backends == nil {
                backendsError = AppLocalization.string("Couldn't read where the terminal runs.")
            }
        }
        let loaded = await configLoad
        guard !Task.isCancelled else { return }
        if let loaded {
            config = loaded
            configError = nil
        } else if config == nil {
            configError = AppLocalization.string("Couldn't read this toolset's backends.")
        }
    }

    private func choose(_ provider: ToolsetConfig.Provider, capability: String?) {
        Haptics.selection()
        working = provider.name
        notice = nil
        let owner = appState.currentCapabilitiesOwner
        Task {
            defer { working = nil }
            do {
                guard serves(owner) else { return }
                let needsNous = try await store.selectProvider(toolset: name, provider: provider.name, capability: capability)
                guard serves(owner) else { return }
                if needsNous {
                    notice = AppLocalization.string("Sign in to Nous Portal on your host to use this backend.")
                }
                // A failed read keeps what's on screen.
                let fresh = try? await store.toolsetConfig(name: name)
                guard serves(owner) else { return }
                if let fresh { config = fresh }
                await appState.loadCapabilities()
            } catch {
                guard serves(owner) else { return }
                notice = UserFacingError.message(for: error)
            }
        }
    }

    private func select(_ backend: TerminalBackendOption) {
        Haptics.selection()
        working = backend.name
        notice = nil
        let owner = appState.currentCapabilitiesOwner
        Task {
            defer { working = nil }
            do {
                guard serves(owner) else { return }
                try await store.selectTerminalBackend(backend.name)
                let fresh = try? await store.terminalBackends()
                guard serves(owner) else { return }
                if let fresh { backends = fresh }
            } catch {
                guard serves(owner) else { return }
                notice = UserFacingError.message(for: error)
            }
        }
    }

    private func save(_ value: String, for env: ToolsetConfig.EnvVar) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        keyValue = ""
        guard !trimmed.isEmpty else { return }
        notice = nil
        let owner = appState.currentCapabilitiesOwner
        Task {
            do {
                guard serves(owner) else { return }
                try await store.saveKey(env.key, value: trimmed)
                Haptics.success()
                // A failed read keeps what's on screen.
                let fresh = try? await store.toolsetConfig(name: name)
                guard serves(owner) else { return }
                if let fresh { config = fresh }
                await appState.loadCapabilities()
            } catch {
                guard serves(owner) else { return }
                notice = UserFacingError.message(for: error)
            }
        }
    }

    /// Whether an answer started for `owner` may still land on this page:
    /// after a dashboard or profile switch it belongs to the old one.
    private func serves(_ owner: CapabilitySnapshotOwner) -> Bool {
        appState.currentCapabilitiesOwner == owner && store.serves(owner)
    }
}
