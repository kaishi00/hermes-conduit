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
    @ObservedObject var store: CapabilitiesStore
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
                        if index > 0 { CapabilityRowDivider() }
                        CapabilityToolsetRow(toolset: toolset, counts: store.toolCalls, store: store)
                    }
                }
            }
        }
        .task(id: store.profile) {
            if store.toolCalls == nil { await store.loadToolCalls() }
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
        } label: {
            if bulkRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(bulkRunning)
        .accessibilityLabel(Text("Tool options"))
    }

    private func setAll(enabled: Bool) {
        let targets = visible.filter { $0.enabled != enabled }.map(\.name)
        guard !bulkRunning, !targets.isEmpty else { return }
        Haptics.selection()
        bulkRunning = true
        Task {
            for name in targets {
                await appState.toggleToolset(name: name, enabled: enabled)
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
    @ObservedObject var store: CapabilitiesStore
    @State private var config: ToolsetConfig?
    @State private var configError: String?
    @State private var backends: [TerminalBackendOption]?
    @State private var backendsError: String?
    @State private var working: String?
    @State private var notice: String?
    @State private var keyPrompt: ToolsetConfig.EnvVar?
    @State private var keyValue = ""
    @State private var backendToConfirm: TerminalBackendOption?

    private var toolset: CapabilityToolset? { appState.toolsets.first { $0.name == name } }

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
            if let notice {
                Text(verbatim: notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }
            if name == "terminal" {
                terminalSection
            }
            if let config, config.hasCategory, !config.providers.isEmpty {
                ConduitSettingsSection(title: AppLocalization.string("Backends"), symbol: "server.rack", tint: .conduitAccent) {
                    ForEach(Array(config.providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { Divider().opacity(0.6) }
                        providerRow(provider, config: config)
                    }
                }
            } else if let configError {
                Text(verbatim: configError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            Text("Changes apply to new sessions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .navigationTitle(Text(verbatim: toolset.map(CapabilityToolsetOrdering.label) ?? name))
        .task(id: name) { await load() }
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
                    .font(.title3.weight(.semibold))
                if toolset.configured == false {
                    let pill = CapabilityToolsetStyle.needsKeysPill()
                    CapabilityPill(text: pill.text, tint: pill.tint)
                }
            }
            if let description = toolset.description, !description.isEmpty {
                Text(verbatim: description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let counts = store.toolCalls {
                let calls = CapabilityToolsetOrdering.calls(toolset, counts: counts)
                if calls > 0 {
                    Text(verbatim: CapabilityFormat.uses(calls))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(
                get: { toolset.enabled },
                set: { enabled in Task { await appState.toggleToolset(name: toolset.name, enabled: enabled) } }
            )) {
                Text("Turned on")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.conduitAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsCard()
    }

    private func toolChip(_ tool: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: tool)
                .font(.caption.monospaced())
            if let count = store.toolCalls?[tool], count > 0 {
                Text(verbatim: CapabilityFormat.uses(count))
                    .font(.caption2.monospacedDigit())
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
                                        .font(.subheadline.weight(.semibold))
                                    Self.backendPill(backend.status)
                                }
                                if !backend.description.isEmpty {
                                    Text(verbatim: backend.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let detail = backend.detail, backend.status != "ready" {
                                    Text(verbatim: detail)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            if working == backend.name {
                                ProgressView().controlSize(.small)
                            } else if backend.active {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
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
                .font(.footnote)
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
                    .font(.subheadline.weight(.semibold))
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(provider.envVars) { env in
                HStack(spacing: 8) {
                    Text(verbatim: env.key)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: env.isSet ? AppLocalization.string("Set") : AppLocalization.string("Not set"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(env.isSet ? Color.green : Color.orange)
                    Button(env.isSet ? AppLocalization.string("Replace") : AppLocalization.string("Add")) {
                        keyValue = ""
                        keyPrompt = env
                    }
                    .font(.caption.weight(.semibold))
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
                        .font(.caption.weight(.semibold))
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
                .font(.caption.weight(.semibold))
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
        if name == "terminal" {
            if let fresh = try? await store.terminalBackends() {
                backends = fresh
                backendsError = nil
            } else if backends == nil {
                backendsError = AppLocalization.string("Couldn't read where the terminal runs.")
            }
        }
        let loaded = await configLoad
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
        Task {
            do {
                let needsNous = try await store.selectProvider(toolset: name, provider: provider.name, capability: capability)
                if needsNous {
                    notice = AppLocalization.string("Sign in to Nous Portal on your host to use this backend.")
                }
                // A failed read keeps what's on screen.
                if let fresh = try? await store.toolsetConfig(name: name) { config = fresh }
                await appState.loadCapabilities()
            } catch {
                notice = UserFacingError.message(for: error)
            }
            working = nil
        }
    }

    private func select(_ backend: TerminalBackendOption) {
        Haptics.selection()
        working = backend.name
        notice = nil
        Task {
            do {
                try await store.selectTerminalBackend(backend.name)
                if let fresh = try? await store.terminalBackends() { backends = fresh }
            } catch {
                notice = UserFacingError.message(for: error)
            }
            working = nil
        }
    }

    private func save(_ value: String, for env: ToolsetConfig.EnvVar) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        keyValue = ""
        guard !trimmed.isEmpty else { return }
        notice = nil
        Task {
            do {
                try await store.saveKey(env.key, value: trimmed)
                Haptics.success()
                // A failed read keeps what's on screen.
                if let fresh = try? await store.toolsetConfig(name: name) { config = fresh }
                await appState.loadCapabilities()
            } catch {
                notice = UserFacingError.message(for: error)
            }
        }
    }
}
