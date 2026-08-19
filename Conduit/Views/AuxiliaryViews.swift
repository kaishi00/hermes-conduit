//
//  AuxiliaryViews.swift
//  Conduit
//
//  Context and settings surfaces.
//

import SwiftUI

private enum ConduitAppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}
import UIKit

// MARK: - Context Sheet

struct ContextSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var breakdown: ContextBreakdown?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        ConduitSettingsSection(title: "Context", symbol: "circle.dotted.circle", tint: .conduitAura) {
                            SettingsMetricRow(label: "Used", value: "\(appState.runtime.contextUsed) tokens")
                            SettingsMetricRow(label: "Capacity", value: "\(appState.runtime.contextMax) tokens")
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text("Window usage")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(appState.runtime.contextPercent.rounded()))%")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                }
                                ProgressView(value: appState.runtime.contextPercent, total: 100)
                                    .tint(.conduitAccent)
                            }
                            .padding(.top, 4)
                        }

                        if let breakdown {
                            ConduitSettingsSection(title: "Breakdown", symbol: "chart.pie", tint: .conduitAccent) {
                                ForEach(breakdown.categories, id: \.id) { category in
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(colorFor(category.color))
                                            .frame(width: 9, height: 9)
                                        Text(category.label)
                                        Spacer()
                                        Text("\(category.tokens)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { await loadBreakdown() }
    }

    private func loadBreakdown() async {
        guard let client = appState.client, let sid = appState.activeSessionId else { return }
        do {
            let loaded = try await client.contextBreakdown(sid)
            breakdown = loaded
            appState.applyContextBreakdown(loaded)
        } catch {
            // Context detail is supplementary to the live ring in the composer.
        }
    }

    private func colorFor(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "purple": return .purple
        case "pink": return .pink
        case "cyan": return .cyan
        case "amber", "yellow": return .yellow
        default: return .conduitAccent
        }
    }
}

// MARK: - Settings

struct SettingsSnapshot: Identifiable {
    let id = UUID()
    let server: String?
    let isConnected: Bool
    let profile: String
    let defaultProfileName: String
    let theme: ThemePreference
    let busyInputMode: BusyInputMode
    let chatResumeBehavior: ChatResumeBehavior
    let chatReturnSurface: ChatReturnSurface
    let displayPreferences: ProfileDisplayPreferences
    let cloudflareAccess: CloudflareAccessCredentials?
}

private struct LegacySettingsView: View {
    let snapshot: SettingsSnapshot
    let saveTheme: (ThemePreference) -> Void
    let persistBusyInputMode: (BusyInputMode) async -> Bool
    let persistDisplayPreference: (DisplayPreferenceKey, Bool) async -> Bool
    let reconnect: () async -> Bool
    let disconnect: () -> Void

    @State private var theme: ThemePreference
    @State private var busyInputMode: BusyInputMode
    @State private var displayPreferences: ProfileDisplayPreferences
    @State private var isConnected: Bool
    @State private var isReconnecting = false
    @State private var isSavingBusyInputMode = false
    @State private var isRestoringBusyInputMode = false
    @State private var busyInputModeError: String?
    @State private var displayPreferenceError: String?
    @State private var savingDisplayPreference: DisplayPreferenceKey?
    @Environment(\.dismiss) private var dismiss

    init(
        snapshot: SettingsSnapshot,
        saveTheme: @escaping (ThemePreference) -> Void,
        saveBusyInputMode: @escaping (BusyInputMode) async -> Bool,
        saveDisplayPreference: @escaping (DisplayPreferenceKey, Bool) async -> Bool,
        reconnect: @escaping () async -> Bool,
        disconnect: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.saveTheme = saveTheme
        self.persistBusyInputMode = saveBusyInputMode
        self.persistDisplayPreference = saveDisplayPreference
        self.reconnect = reconnect
        self.disconnect = disconnect
        _theme = State(initialValue: snapshot.theme)
        _busyInputMode = State(initialValue: snapshot.busyInputMode)
        _displayPreferences = State(initialValue: snapshot.displayPreferences)
        _isConnected = State(initialValue: snapshot.isConnected)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()

                ScrollView {
                    VStack(spacing: 14) {
                        connectionSection
                        appearanceSection
                        chatSection
                        chatDisplaySection
                        aboutSection
                        disconnectButton
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: "Settings", close: { dismiss() })
            }
        }
        .preferredColorScheme(theme.colorScheme)
    }

    private var connectionSection: some View {
        ConduitSettingsSection(title: "Connection", symbol: "bolt.horizontal.circle", tint: .conduitAura) {
            SettingsMetricRow(label: "Server", value: snapshot.server ?? "—", lineLimit: 1)
            SettingsMetricRow(
                label: "Status",
                value: isConnected ? "Connected" : "Disconnected",
                valueColor: isConnected ? .green : .red,
                statusDot: isConnected ? .green : .red
            )

            Button {
                Task {
                    isReconnecting = true
                    isConnected = await reconnect()
                    isReconnecting = false
                }
            } label: {
                Label(isReconnecting ? "Reconnecting…" : "Reconnect", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .disabled(isReconnecting)
            .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.12))
            .padding(.top, 4)
        }
    }

    private var appearanceSection: some View {
        ConduitSettingsSection(title: "Appearance", symbol: "circle.lefthalf.filled", tint: .conduitAccent) {
            Text("Choose how Conduit appears across the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ConduitGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    themeChoice(.dark, title: "Dark", symbol: "moon.fill")
                    themeChoice(.light, title: "Light", symbol: "sun.max.fill")
                    themeChoice(.system, title: "System", symbol: "circle.lefthalf.filled")
                }
            }
        }
    }

    private var chatSection: some View {
        ConduitSettingsSection(title: "During a response", symbol: "bubble.left.and.bubble.right", tint: .conduitAccent) {
            Text("Choose what a typed message does while Hermes is still working.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ConduitGlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    busyModeChoice(.steer, symbol: "arrow.triangle.branch", detail: "Guide safely")
                    busyModeChoice(.interrupt, symbol: "arrow.uturn.backward", detail: "Stop and correct")
                }
            }
            .disabled(!isConnected || isSavingBusyInputMode)

            if isSavingBusyInputMode {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving preference…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let busyInputModeError {
                Label(busyInputModeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var aboutSection: some View {
        ConduitSettingsSection(title: "About", symbol: "info.circle", tint: .conduitAura) {
            SettingsMetricRow(label: "Profile", value: snapshot.profile.capitalized)
            SettingsMetricRow(label: "Version", value: ConduitAppVersion.display)
        }
    }

    private var chatDisplaySection: some View {
        ConduitSettingsSection(title: "Chat display", symbol: "text.bubble", tint: .conduitAura) {
            Text("These choices follow the active workspace.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            displayToggle(.reasoning, title: "Show reasoning", detail: "Include available agent reasoning in replies.")
            displayToggle(.toolProgress, title: "Show tool activity", detail: "Show tool calls and their progress in chat.")
            displayToggle(.expandTools, title: "Keep tool cards expanded", detail: "Open completed tool details by default.")

            if let displayPreferenceError {
                Label(displayPreferenceError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var disconnectButton: some View {
        Button(role: .destructive) {
            disconnect()
            dismiss()
        } label: {
            Label("Disconnect from Hermes", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .conduitGlassControl(cornerRadius: 18, tint: .red.opacity(0.18))
    }

    private func themeChoice(_ value: ThemePreference, title: String, symbol: String) -> some View {
        Button {
            withAnimation(ConduitMotion.response) {
                theme = value
                saveTheme(value)
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(theme == value ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        .conduitGlassControl(
            cornerRadius: 16,
            tint: theme == value ? .conduitAccent.opacity(0.26) : .clear,
            prominent: theme == value
        )
    }

    private func busyModeChoice(_ value: BusyInputMode, symbol: String, detail: String) -> some View {
        Button {
            guard busyInputMode != value else { return }
            let previousValue = busyInputMode
            withAnimation(ConduitMotion.response) {
                busyInputMode = value
            }
            saveBusyInputMode(value, restoring: previousValue)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if busyInputMode == value {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                }
                Text(value.title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 72)
            .padding(.horizontal, 12)
        }
        .foregroundStyle(busyInputMode == value ? .primary : .secondary)
        .conduitGlassControl(
            cornerRadius: 18,
            tint: busyInputMode == value ? .conduitAccent.opacity(0.23) : .clear,
            prominent: busyInputMode == value
        )
    }

    @ViewBuilder
    private func displayToggle(_ key: DisplayPreferenceKey, title: String, detail: String) -> some View {
        let isOn = displayValue(for: key)
        Toggle(isOn: Binding(
            get: { isOn },
            set: { saveDisplayPreference(key, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.conduitAccent)
        .disabled(!isConnected || savingDisplayPreference != nil)
        .padding(.vertical, 2)
    }

    private func displayValue(for key: DisplayPreferenceKey) -> Bool {
        switch key {
        case .reasoning: return displayPreferences.showReasoning
        case .toolProgress: return displayPreferences.showToolProgress
        case .expandTools: return displayPreferences.expandToolsByDefault
        }
    }

    private func saveDisplayPreference(_ key: DisplayPreferenceKey, enabled: Bool) {
        let previous = displayPreferences
        setDisplayValue(key, enabled: enabled)
        displayPreferenceError = nil
        Task {
            savingDisplayPreference = key
            let didSave = await persistDisplayPreference(key, enabled)
            guard !Task.isCancelled else { return }
            if !didSave {
                displayPreferences = previous
                displayPreferenceError = "Could not save this setting. Restored the previous choice."
            }
            savingDisplayPreference = nil
        }
    }

    private func setDisplayValue(_ key: DisplayPreferenceKey, enabled: Bool) {
        switch key {
        case .reasoning: displayPreferences.showReasoning = enabled
        case .toolProgress: displayPreferences.showToolProgress = enabled
        case .expandTools: displayPreferences.expandToolsByDefault = enabled
        }
    }

    private func saveBusyInputMode(_ value: BusyInputMode, restoring previousValue: BusyInputMode) {
        guard !isRestoringBusyInputMode else {
            isRestoringBusyInputMode = false
            return
        }

        Task {
            isSavingBusyInputMode = true
            busyInputModeError = nil
            let didSave = await persistBusyInputMode(value)
            guard !Task.isCancelled else { return }

            if !didSave {
                isRestoringBusyInputMode = true
                withAnimation(ConduitMotion.response) {
                    busyInputMode = previousValue
                }
                busyInputModeError = "Could not save this setting. Restored the previous choice."
            }
            isSavingBusyInputMode = false
        }
    }
}

// MARK: - Settings home and detail routes

private enum SettingsDestination: Hashable {
    case profile, model, chat, voice, workspace, memory, gateway, appearance, notifications, about
}

private enum ProfileSettingControl {
    case toggle(defaultValue: Bool)
    case textToggle(onValue: String, offValue: String, defaultValue: Bool)
    case options([String], defaultValue: String)
    case labeledOptions([(value: String, label: String)], defaultValue: String)
    case text(defaultValue: String)
    case number(defaultValue: Double)
}

private struct ProfileSettingField: Identifiable {
    let key: String
    let label: String
    let help: String
    let control: ProfileSettingControl
    var id: String { key }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    let snapshot: SettingsSnapshot
    let saveTheme: (ThemePreference) -> Void
    let persistBusyInputMode: (BusyInputMode) async -> Bool
    let persistChatResumeBehavior: (ChatResumeBehavior) -> Void
    let persistChatReturnSurface: (ChatReturnSurface) -> Void
    let loadProfileSettings: ([String]) async -> [String: ProfileSettingValue]
    let persistProfileSetting: (String, ProfileSettingValue) async -> Bool
    let loadProfileConfigOptions: () async -> ProfileConfigOptions
    let loadProfileModelDefaults: () async -> ProfileModelDefaults?
    let persistProfileMainModel: (String, String, String) async -> Bool
    let saveDefaultProfileName: (String) -> Void
    let reconnect: () async -> Bool
    let disconnect: () -> Void

    @State private var path: [SettingsDestination] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            SettingsHome(snapshot: snapshot, path: $path)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ConduitSheetHeader(title: "Settings", close: { dismiss() })
                }
                .navigationDestination(for: SettingsDestination.self) { destination in
                    destinationView(destination)
                }
        }
        .preferredColorScheme(appState.themePreference.colorScheme)
    }

    @ViewBuilder
    private func destinationView(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .profile:
            ProfileSettingsDetail(
                profile: snapshot.profile,
                displayName: snapshot.profile == "default" ? snapshot.defaultProfileName : snapshot.profile.capitalized,
                saveDefaultProfileName: saveDefaultProfileName
            )
        case .model:
            ProfileModelSettingsDetail(load: loadProfileModelDefaults, save: persistProfileMainModel)
        case .chat:
            ChatSettingsDetail(
                busyInputMode: snapshot.busyInputMode,
                persistBusyInputMode: persistBusyInputMode,
                chatResumeBehavior: snapshot.chatResumeBehavior,
                persistChatResumeBehavior: persistChatResumeBehavior,
                chatReturnSurface: snapshot.chatReturnSurface,
                persistChatReturnSurface: persistChatReturnSurface,
                load: loadProfileSettings,
                save: persistProfileSetting,
                loadOptions: loadProfileConfigOptions
            )
        case .voice:
            if let bridge = appState.dashboardTicketBridge {
                VoiceSettingsRoute(
                    bridge: bridge,
                    profile: snapshot.profile,
                    actions: VoiceSettingsActions(
                        runASRTest: { await appState.runVoiceASRTest() },
                        runTTSTest: { await appState.runVoiceTTSTest() }
                    ),
                    voiceEnabled: appState.isVoiceEnabled,
                    transcriptionMode: appState.voiceTranscriptionMode,
                    appleSpeechAvailability: appState.appleSpeechAvailability,
                    setVoiceEnabled: { enabled in
                        await appState.setVoiceEnabled(enabled)
                    },
                    setTranscriptionMode: { mode in
                        await appState.setVoiceTranscriptionMode(mode)
                    }
                )
            } else {
                SettingsDetailContainer {
                    ConduitSettingsSection(title: "Voice", symbol: "mic.slash", tint: .orange) {
                        Text("Connect to Hermes to configure voice for this profile.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .workspace:
            ProfileConfigSettingsPage(
                title: "Workspace & safety",
                subtitle: "Working defaults and safeguards for this profile.",
                fields: Self.workspaceFields,
                load: loadProfileSettings,
                save: persistProfileSetting
            )
        case .memory:
            MemorySettingsDetail(
                load: loadProfileSettings,
                save: persistProfileSetting,
                loadOptions: loadProfileConfigOptions,
                loadModels: loadProfileModelDefaults,
                fields: Self.memoryFields
            )
        case .gateway:
            GatewaySettingsDetail(snapshot: snapshot, reconnect: reconnect, disconnect: disconnect, close: { dismiss() }, saveCloudflareAccess: appState.saveCloudflareAccess, removeCloudflareAccess: appState.removeCloudflareAccess)
        case .appearance:
            AppearanceSettingsDetail(theme: appState.themePreference, saveTheme: saveTheme)
        case .notifications:
            NotificationsSettingsDetail()
        case .about:
            AboutSettingsDetail(profile: snapshot.profile)
        }
    }

    private static let workspaceFields: [ProfileSettingField] = [
        .init(key: "terminal.cwd", label: "Default working directory", help: "Server-side path for new workspaces.", control: .text(defaultValue: "")),
        .init(key: "code_execution.mode", label: "Code execution mode", help: "Default execution boundary.", control: .options(["project", "strict"], defaultValue: "project")),
        .init(key: "approvals.mode", label: "Approval mode", help: "Profile-wide default: manual asks every time; smart asks when risk warrants it; off is YOLO mode. When set to off, Hermes auto-approves everything and per-session YOLO toggles have no effect — that's a Hermes limitation, not a Conduit bug. To use per-session YOLO, set this to manual or smart.", control: .options(["manual", "smart", "off"], defaultValue: "smart")),
        .init(key: "security.redact_secrets", label: "Redact secrets", help: "Hide detected credentials from tool output where possible.", control: .toggle(defaultValue: true)),
        .init(key: "security.allow_private_urls", label: "Allow private URLs", help: "Permit tool access to private-network URLs.", control: .toggle(defaultValue: false)),
    ]

    private static let memoryFields: [ProfileSettingField] = [
        .init(key: "memory.provider", label: "Memory provider", help: "Provider used for long-term memory.", control: .options([], defaultValue: "")),
        .init(key: "memory.memory_enabled", label: "Long-term memory", help: "Allow Hermes to retain relevant working memory.", control: .toggle(defaultValue: true)),
        .init(key: "memory.user_profile_enabled", label: "User profile memory", help: "Allow Hermes to maintain user preferences.", control: .toggle(defaultValue: true)),
        .init(key: "context.engine", label: "Context engine", help: "Installed context-management engine.", control: .options([], defaultValue: "default")),
        .init(key: "compression.enabled", label: "Context compression", help: "Compress older context when the window becomes crowded.", control: .toggle(defaultValue: true)),
        .init(key: "compression.threshold", label: "Compression threshold", help: "Fraction of the context window that starts compression.", control: .number(defaultValue: 0.8)),
        .init(key: "compression.target_ratio", label: "Compression target", help: "Fraction retained after compression.", control: .number(defaultValue: 0.5)),
        .init(key: "compression.protect_last_n", label: "Protected recent messages", help: "Recent messages left intact by compression.", control: .number(defaultValue: 8)),
        .init(key: "delegation.max_concurrent_children", label: "Concurrent delegate agents", help: "Maximum child agents that can work at once.", control: .number(defaultValue: 2)),
    ]
}

private struct SettingsHome: View {
    let snapshot: SettingsSnapshot
    @Binding var path: [SettingsDestination]
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            ConduitBackdrop()
            ScrollView {
                VStack(spacing: 14) {
                    homeSection("Profile", tint: .conduitAccent) {
                        settingsLink(.profile, icon: "person.crop.circle", title: profileDisplayName, detail: "Profile-specific preferences")
                    }
                    homeSection("Hermes", tint: .conduitAura) {
                        settingsLink(.model, icon: "cpu", title: "Model", detail: "Default model and reasoning")
                        settingsLink(.chat, icon: "bubble.left.and.bubble.right", title: "Chat", detail: "Response behavior, visibility, and timezone")
                        settingsLink(.voice, icon: "mic.and.signal.meter", title: "Voice", detail: "Speech providers, credentials, and device opt-in")
                        settingsLink(.workspace, icon: "folder", title: "Workspace & safety", detail: "Working directory, approvals, and privacy")
                        settingsLink(.memory, icon: "brain.head.profile", title: "Memory & delegation", detail: "Memory, compression, and child agents")
                    }
                    homeSection("Connection", tint: .conduitAura) {
                        settingsLink(.gateway, icon: "radio", title: "Gateway", detail: snapshot.server ?? "Not connected")
                    }
                    homeSection("On this device", tint: .conduitAccent) {
                        settingsLink(.appearance, icon: "circle.lefthalf.filled", title: "Appearance", detail: "Theme and interface preferences")
                        settingsLink(.notifications, icon: "bell", title: "Notifications", detail: "Delivery status and setup")
                        settingsLink(.about, icon: "shield", title: "About & privacy", detail: "App information and data handling")
                    }
                    Text("Hermes settings follow the active profile. Appearance, notifications, and privacy controls stay on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }
                .padding(16)
            }
        }
    }

    private var profileDisplayName: String {
        snapshot.profile == "default" ? appState.defaultProfileName : snapshot.profile.capitalized
    }

    private func homeSection<Content: View>(_ title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        ConduitSettingsSection(title: title, symbol: title == "Profile" ? "person.crop.circle" : "gearshape.2", tint: tint, content: content)
    }

    private func settingsLink(_ destination: SettingsDestination, icon: String, title: String, detail: String) -> some View {
        Button {
            Haptics.selection()
            path.append(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.conduitAccent).frame(width: 25)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(detail)
    }
}

private struct ProfileSettingsDetail: View {
    let profile: String
    let displayName: String
    let saveDefaultProfileName: (String) -> Void
    @EnvironmentObject private var appState: AppState
    @State private var name: String
    @State private var didSave = false

    init(profile: String, displayName: String, saveDefaultProfileName: @escaping (String) -> Void) {
        self.profile = profile
        self.displayName = displayName
        self.saveDefaultProfileName = saveDefaultProfileName
        _name = State(initialValue: displayName)
    }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: "Active profile", symbol: "person.crop.circle.fill", tint: .conduitAccent) {
                SettingsMetricRow(label: "Profile", value: currentDisplayName)
                Text("Choose a different profile from the session drawer. Chat, model, workspace, and memory preferences on the other settings pages follow that profile.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if profile == "default" {
                ConduitSettingsSection(title: "On this device", symbol: "pencil", tint: .conduitAccent) {
                    Text("Display name").font(.subheadline.weight(.semibold))
                    TextField("Hermes", text: $name)
                        .textInputAutocapitalization(.words)
                        .padding(10)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("This only changes how the default profile is named in Conduit. Hermes itself still uses the default profile.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(didSave ? "Saved" : "Save display name") {
                        saveDefaultProfileName(name)
                        name = appState.defaultProfileName
                        didSave = true
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(.conduitAccent)
                }
            }
        }
        .navigationTitle("Profile")
    }

    private var currentDisplayName: String {
        profile == "default" ? appState.defaultProfileName : displayName
    }
}

private struct ChatSettingsDetail: View {
    let busyInputMode: BusyInputMode
    let persistBusyInputMode: (BusyInputMode) async -> Bool
    let chatResumeBehavior: ChatResumeBehavior
    let persistChatResumeBehavior: (ChatResumeBehavior) -> Void
    let chatReturnSurface: ChatReturnSurface
    let persistChatReturnSurface: (ChatReturnSurface) -> Void
    let load: ([String]) async -> [String: ProfileSettingValue]
    let save: (String, ProfileSettingValue) async -> Bool
    let loadOptions: () async -> ProfileConfigOptions
    @State private var options = ProfileConfigOptions()

    var body: some View {
        ProfileConfigSettingsPage(
            title: "Chat",
            subtitle: "",
            fields: Self.fields,
            load: load,
            save: save,
            showsNavigationTitle: false,
            optionOverrides: ["display.personality": ["", "helpful", "concise", "technical", "creative", "teacher", "kawaii", "catgirl", "pirate", "shakespeare", "surfer", "noir", "uwu", "philosopher", "hype"] + options.personalities],
            leadingSection: AnyView(
                VStack(spacing: 14) {
                    ChatReturnBehaviorSettings(
                        initialBehavior: chatResumeBehavior,
                        persistBehavior: persistChatResumeBehavior,
                        initialSurface: chatReturnSurface,
                        persistSurface: persistChatReturnSurface
                    )
                    ResponseBehaviorSettings(initialMode: busyInputMode, save: persistBusyInputMode)
                }
            ),
            trailingSection: AnyView(DeviceHapticsSettings())
        )
        .navigationTitle("Chat")
        .task { options = await loadOptions() }
    }

    private static let fields: [ProfileSettingField] = [
        .init(key: "display.personality", label: "Personality", help: "Default response style for new conversations.", control: .options([], defaultValue: "")),
        .init(key: "timezone", label: "Timezone", help: "Used for dates, reminders, and scheduled work.", control: .text(defaultValue: "")),
        .init(key: "display.show_reasoning", label: "Show thinking", help: "Show collapsible thinking blocks when provided.", control: .toggle(defaultValue: true)),
        .init(key: "display.tool_progress", label: "Tool cards", help: "Show tool calls and expandable details in conversations.", control: .textToggle(onValue: "all", offValue: "off", defaultValue: true)),
        .init(key: "display.expand_tools", label: "Keep tool cards expanded", help: "Keep completed tool details open by default.", control: .toggle(defaultValue: false)),
        .init(key: "display.memory_notifications", label: "Self-improvement updates", help: "Choose whether Conduit follows Hermes, always shows, or never shows maintenance updates.", control: .labeledOptions([(value: "default", label: "Use Hermes default"), (value: "on", label: "Always show"), (value: "off", label: "Never show")], defaultValue: "default")),
        .init(key: "agent.image_input_mode", label: "Image attachments", help: "How Hermes supplies images to a model.", control: .options(["auto", "native", "text"], defaultValue: "auto")),
    ]
}

private struct DeviceHapticsSettings: View {
    @AppStorage(Haptics.preferenceKey) private var enabled = true

    var body: some View {
        ConduitSettingsSection(
            title: "Haptic feedback",
            symbol: "waveform",
            tint: .conduitAura
        ) {
            Text("Conduit-generated vibration feedback for actions and response progress. iOS system controls can still provide their own feedback.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Haptic feedback", isOn: $enabled)
                .labelsHidden()
                .tint(.conduitAccent)
                .onChange(of: enabled) { _, enabled in
                    Haptics.enabled = enabled
                }
        }
    }
}

private struct ChatReturnBehaviorSettings: View {
    let persistBehavior: (ChatResumeBehavior) -> Void
    let persistSurface: (ChatReturnSurface) -> Void
    @State private var behavior: ChatResumeBehavior
    @State private var surface: ChatReturnSurface

    init(
        initialBehavior: ChatResumeBehavior,
        persistBehavior: @escaping (ChatResumeBehavior) -> Void,
        initialSurface: ChatReturnSurface,
        persistSurface: @escaping (ChatReturnSurface) -> Void
    ) {
        self.persistBehavior = persistBehavior
        self.persistSurface = persistSurface
        _behavior = State(initialValue: initialBehavior)
        _surface = State(initialValue: initialSurface)
    }

    var body: some View {
        ConduitSettingsSection(
            title: "When returning to Conduit",
            symbol: "arrow.uturn.backward.circle",
            tint: .conduitAccent
        ) {
            Text("Stored only on this device, not in your Hermes profile. Choose which surface Conduit opens to and whether it preserves your exact reading position or follows the newest conversation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Open to")
                    .font(.subheadline.weight(.semibold))
                Picker("Open to", selection: Binding(get: { surface }, set: chooseSurface)) {
                    ForEach(ChatReturnSurface.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Used if you dismiss the session list without choosing another conversation.")
                if surface == .sessions {
                    Text("Used if you dismiss the session list without choosing another conversation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Conversation")
                    .font(.subheadline.weight(.semibold))
                Picker("Conversation", selection: Binding(get: { behavior }, set: chooseBehavior)) {
                    Text("Continue").tag(ChatResumeBehavior.continueWhereLeftOff)
                    Text("Latest").tag(ChatResumeBehavior.latestActivity)
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Choose whether Conduit preserves your exact reading position or follows the newest conversation.")
            }
        }
    }

    private func chooseBehavior(_ next: ChatResumeBehavior) {
        guard next != behavior else { return }
        behavior = next
        persistBehavior(next)
    }

    private func chooseSurface(_ next: ChatReturnSurface) {
        guard next != surface else { return }
        surface = next
        persistSurface(next)
    }
}
private struct ResponseBehaviorSettings: View {
    let initialMode: BusyInputMode
    let save: (BusyInputMode) async -> Bool
    @State private var mode: BusyInputMode
    @State private var saving = false
    @State private var error: String?

    init(initialMode: BusyInputMode, save: @escaping (BusyInputMode) async -> Bool) {
        self.initialMode = initialMode
        self.save = save
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        ConduitSettingsSection(title: "During a response", symbol: "arrow.triangle.branch", tint: .conduitAccent) {
            Text("Steer adds guidance to the active turn. Interrupt stops it before handling the new message.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Messages during a response", selection: Binding(get: { mode }, set: choose)) {
                Text("Steer").tag(BusyInputMode.steer)
                Text("Interrupt").tag(BusyInputMode.interrupt)
            }
            .pickerStyle(.segmented)
            .disabled(saving)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func choose(_ next: BusyInputMode) {
        guard next != mode else { return }
        let previous = mode
        mode = next
        Task {
            saving = true
            guard await save(next) else {
                mode = previous
                error = "Could not save this setting. Restored the previous choice."
                saving = false
                return
            }
            saving = false
        }
    }
}

/// A custom menu picker matching the Chat settings selector style,
/// used by Model and Delegate model settings for visual consistency.
struct ConduitMenuPicker<Label: View>: View {
    let label: Label
    let value: String
    let choices: [(id: String, title: String)]
    let onSelect: (String) -> Void

    init(value: String, choices: [(id: String, title: String)], onSelect: @escaping (String) -> Void, @ViewBuilder label: () -> Label) {
        self.value = value
        self.choices = choices
        self.onSelect = onSelect
        self.label = label()
    }

    private var displayedTitle: String {
        choices.first(where: { $0.id == value })?.title ?? value
    }

    var body: some View {
        Menu {
            ForEach(choices, id: \.id) { choice in
                Button(choice.title) { onSelect(choice.id) }
            }
        } label: {
            HStack {
                label
                Spacer(minLength: 8)
                Text(displayedTitle.isEmpty ? "Default" : displayedTitle)
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .conduitGlassControl(cornerRadius: 14)
    }
}

private struct ProfileModelSettingsDetail: View {
    let load: () async -> ProfileModelDefaults?
    let save: (String, String, String) async -> Bool
    @State private var defaults: ProfileModelDefaults?
    @State private var provider = ""
    @State private var model = ""
    @State private var reasoning = "medium"
    @State private var saving = false
    @State private var error: String?

    private var models: [ModelInfo] { defaults?.providers.first(where: { $0.name == provider })?.models ?? [] }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: "Default model", symbol: "cpu", tint: .conduitAccent) {
                Text("Select a provider first, then one of its available models. These defaults apply to new sessions in this profile.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let defaults, !defaults.providers.isEmpty {
                    ConduitMenuPicker(
                        value: provider,
                        choices: defaults.providers.map { (id: $0.name, title: $0.name) },
                        onSelect: chooseProvider
                    ) {
                        Text("Provider").foregroundStyle(.secondary)
                    }
                    ConduitMenuPicker(
                        value: model,
                        choices: models.map { (id: $0.id, title: $0.label ?? $0.id) },
                        onSelect: { model = $0 }
                    ) {
                        Text("Model").foregroundStyle(.secondary)
                    }
                    .disabled(models.isEmpty)
                } else {
                    ProgressView("Loading available models…")
                }
            }
            ConduitSettingsSection(title: "Reasoning", symbol: "brain.head.profile", tint: .conduitAura) {
                ConduitMenuPicker(
                    value: reasoning,
                    choices: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].map { (id: $0, title: $0.capitalized) },
                    onSelect: { reasoning = $0 }
                ) {
                    Text("Default reasoning").foregroundStyle(.secondary)
                }
            }
            Button { persist() } label: { Label(saving ? "Saving…" : "Save model defaults", systemImage: "checkmark").frame(maxWidth: .infinity).frame(height: 46) }
                .disabled(saving || provider.isEmpty || model.isEmpty).conduitGlassControl(cornerRadius: 17, tint: .conduitAccent.opacity(0.18))
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Model")
        .task { await reload() }
    }

    private func reload() async {
        guard let loaded = await load() else { return }
        defaults = loaded
        provider = loaded.providers.contains(where: { $0.name == loaded.provider }) ? loaded.provider : loaded.providers.first?.name ?? ""
        let availableModels = loaded.providers.first(where: { $0.name == provider })?.models ?? []
        model = availableModels.contains(where: { $0.id == loaded.model }) ? loaded.model : availableModels.first?.id ?? ""
        reasoning = loaded.reasoning
    }
    private func chooseProvider(_ next: String) { provider = next; model = defaults?.providers.first(where: { $0.name == next })?.models.first?.id ?? "" }
    private func persist() {
        Task {
            saving = true
            error = nil
            if !(await save(provider, model, reasoning)) {
                error = "Could not save model defaults."
            }
            saving = false
        }
    }
}

private struct DelegationModelSettings: View {
    let loadModels: () async -> ProfileModelDefaults?
    let loadSettings: ([String]) async -> [String: ProfileSettingValue]
    let save: (String, ProfileSettingValue) async -> Bool
    @State private var defaults: ProfileModelDefaults?
    @State private var provider = ""
    @State private var model = ""
    @State private var reasoning = "medium"
    @State private var saving = false
    @State private var error: String?
    private var models: [ModelInfo] { defaults?.providers.first(where: { $0.name == provider })?.models ?? [] }

    var body: some View {
        ConduitSettingsSection(title: "Delegate model", symbol: "point.3.connected.trianglepath.dotted", tint: .conduitAccent) {
            Text("Leave both selections empty to inherit the chat model. Set a provider and model to route delegate agents separately.")
                .font(.footnote).foregroundStyle(.secondary)
            if let defaults, !defaults.providers.isEmpty {
                ConduitMenuPicker(
                    value: provider,
                    choices: [(id: "", title: "Inherit chat provider")] + defaults.providers.map { (id: $0.name, title: $0.name) },
                    onSelect: chooseProvider
                ) {
                    Text("Delegate provider").foregroundStyle(.secondary)
                }
                if !provider.isEmpty {
                    ConduitMenuPicker(
                        value: model,
                        choices: [(id: "", title: "Inherit chat model")] + models.map { (id: $0.id, title: $0.label ?? $0.id) },
                        onSelect: { model = $0 }
                    ) {
                        Text("Delegate model").foregroundStyle(.secondary)
                    }
                }
                ConduitMenuPicker(
                    value: reasoning,
                    choices: [(id: "", title: "Inherit chat reasoning")] + ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"].map { (id: $0, title: $0.capitalized) },
                    onSelect: { reasoning = $0 }
                ) {
                    Text("Delegate reasoning").foregroundStyle(.secondary)
                }
            } else { ProgressView("Loading available models…") }
            Button { persist() } label: { Label(saving ? "Saving…" : "Save delegate defaults", systemImage: "checkmark").frame(maxWidth: .infinity).frame(height: 42) }
                .disabled(saving).conduitGlassControl(cornerRadius: 15, tint: .conduitAccent.opacity(0.18))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { await reload() }
    }

    private func reload() async {
        async let modelRequest = loadModels()
        async let settingRequest = loadSettings(["delegation.provider", "delegation.model", "delegation.reasoning_effort"])
        let (loaded, settings) = await (modelRequest, settingRequest)
        defaults = loaded
        let configuredProvider = settings["delegation.provider"]?.textValue ?? ""
        provider = loaded?.providers.contains(where: { $0.name == configuredProvider }) == true ? configuredProvider : loaded?.providers.first?.name ?? ""
        let configuredModel = settings["delegation.model"]?.textValue ?? ""
        let availableModels = loaded?.providers.first(where: { $0.name == provider })?.models ?? []
        model = availableModels.contains(where: { $0.id == configuredModel }) ? configuredModel : availableModels.first?.id ?? ""
        reasoning = settings["delegation.reasoning_effort"]?.textValue ?? ""
    }
    private func chooseProvider(_ next: String) { provider = next; model = next.isEmpty ? "" : defaults?.providers.first(where: { $0.name == next })?.models.first?.id ?? "" }
    private func persist() {
        Task {
            saving = true
            error = nil
            let providerSaved = await save("delegation.provider", .text(provider))
            let modelSaved = providerSaved ? await save("delegation.model", .text(model)) : false
            let reasoningSaved = modelSaved ? await save("delegation.reasoning_effort", .text(reasoning)) : false
            if !reasoningSaved { error = "Could not save delegate defaults." }
            saving = false
        }
    }
}

private struct MemorySettingsDetail: View {
    let load: ([String]) async -> [String: ProfileSettingValue]
    let save: (String, ProfileSettingValue) async -> Bool
    let loadOptions: () async -> ProfileConfigOptions
    let loadModels: () async -> ProfileModelDefaults?
    let fields: [ProfileSettingField]
    @State private var options = ProfileConfigOptions()

    var body: some View {
        ProfileConfigSettingsPage(
            title: "Memory & delegation",
            subtitle: "Long-term context and delegate-agent defaults.",
            fields: fields,
            load: load,
            save: save,
            optionOverrides: ["memory.provider": options.memoryProviders, "context.engine": options.contextEngines],
            trailingSection: AnyView(DelegationModelSettings(loadModels: loadModels, loadSettings: load, save: save))
        )
        .task { options = await loadOptions() }
    }
}

private struct ProfileConfigSettingsPage: View {
    let title: String
    let subtitle: String
    let fields: [ProfileSettingField]
    let load: ([String]) async -> [String: ProfileSettingValue]
    let save: (String, ProfileSettingValue) async -> Bool
    var showsNavigationTitle = true
    var optionOverrides: [String: [String]] = [:]
    var leadingSection: AnyView? = nil
    var trailingSection: AnyView? = nil

    @State private var values: [String: ProfileSettingValue] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var loading = true
    @State private var savingKey: String?
    @State private var error: String?

    var body: some View {
        SettingsDetailContainer {
            if let leadingSection { leadingSection }
            if !subtitle.isEmpty {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            if loading {
                ProgressView("Loading profile settings…").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(fields) { field in
                    settingCard(field)
                }
            }
            if let trailingSection { trailingSection }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(showsNavigationTitle ? title : "")
        .task { await reload() }
    }

    @ViewBuilder
    private func settingCard(_ field: ProfileSettingField) -> some View {
        ConduitSettingsSection(title: field.label, symbol: fieldIcon(field.key), tint: .conduitAura) {
            Text(field.help).font(.footnote).foregroundStyle(.secondary)
            switch field.control {
            case .toggle(let defaultValue):
                Toggle("", isOn: Binding(get: { boolValue(field.key, defaultValue: defaultValue) }, set: { save(field, value: .bool($0)) }))
                    .labelsHidden().tint(.conduitAccent).disabled(savingKey != nil)
            case .textToggle(let onValue, let offValue, let defaultValue):
                Toggle("", isOn: Binding(
                    get: { textValue(field.key, defaultValue: defaultValue ? onValue : offValue) != offValue },
                    set: { save(field, value: .text($0 ? onValue : offValue)) }
                ))
                .labelsHidden().tint(.conduitAccent).disabled(savingKey != nil)
            case .options(let options, let defaultValue):
                let choices = optionOverrides[field.key] ?? options
                let selectedValue = textValue(field.key, defaultValue: defaultValue)
                let displayedValue = selectedValue.isEmpty ? choices.first ?? "" : selectedValue
                Menu {
                    ForEach(choices, id: \.self) { option in
                        Button(option.isEmpty ? "Default" : option) { save(field, value: .text(option)) }
                    }
                } label: {
                    HStack { Text(displayedValue.isEmpty ? "Default" : displayedValue); Spacer(); Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary) }
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(height: 42)
                }
                .disabled(savingKey != nil || choices.isEmpty).conduitGlassControl(cornerRadius: 14)
                if choices.isEmpty { Text("No configured choices are available.").font(.caption).foregroundStyle(.secondary) }
            case .labeledOptions(let options, let defaultValue):
                let selectedValue = textValue(field.key, defaultValue: defaultValue)
                let displayedValue = options.first(where: { $0.value == selectedValue })?.label ?? options.first?.label ?? ""
                Menu {
                    ForEach(options, id: \.value) { option in
                        Button(option.label) { save(field, value: .text(option.value)) }
                    }
                } label: {
                    HStack { Text(displayedValue); Spacer(); Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary) }
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(height: 42)
                }
                .disabled(savingKey != nil || options.isEmpty).conduitGlassControl(cornerRadius: 14)
            case .text(let defaultValue):
                textEditor(field, defaultValue: defaultValue, keyboard: .default)
            case .number(let defaultValue):
                textEditor(field, defaultValue: String(defaultValue), keyboard: .decimalPad)
            }
            if savingKey == field.key { HStack { ProgressView().controlSize(.small); Text("Saving…").font(.caption).foregroundStyle(.secondary) } }
        }
    }

    private func textEditor(_ field: ProfileSettingField, defaultValue: String, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 8) {
            TextField(field.label, text: Binding(get: { drafts[field.key] ?? textValue(field.key, defaultValue: defaultValue) }, set: { drafts[field.key] = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
                .padding(.horizontal, 12).frame(height: 42).conduitGlassSurface(cornerRadius: 14)
            Button("Save") {
                let raw = drafts[field.key] ?? textValue(field.key, defaultValue: defaultValue)
                if case .number = field.control, let number = Double(raw) { save(field, value: .number(number)) }
                else if case .number = field.control { error = "Enter a valid number for \(field.label)." }
                else { save(field, value: .text(raw)) }
            }
            .buttonStyle(.borderedProminent).tint(.conduitAccent).disabled(savingKey != nil)
        }
    }

    private func reload() async {
        loading = true
        values = await load(fields.map(\.key))
        for field in fields { drafts[field.key] = values[field.key]?.textValue }
        loading = false
    }

    private func save(_ field: ProfileSettingField, value: ProfileSettingValue) {
        let previous = values[field.key]
        values[field.key] = value
        error = nil
        Task {
            savingKey = field.key
            guard await save(field.key, value) else {
                values[field.key] = previous
                error = "Could not save \(field.label)."
                savingKey = nil
                return
            }
            savingKey = nil
        }
    }

    private func boolValue(_ key: String, defaultValue: Bool) -> Bool { values[key]?.boolValue ?? defaultValue }
    private func textValue(_ key: String, defaultValue: String) -> String { values[key]?.textValue ?? defaultValue }
    private func fieldIcon(_ key: String) -> String { key.hasPrefix("security") ? "lock" : key.hasPrefix("memory") ? "brain" : key.hasPrefix("delegation") ? "point.3.connected.trianglepath.dotted" : "slider.horizontal.3" }
}

private struct GatewaySettingsDetail: View {
    let snapshot: SettingsSnapshot
    let reconnect: () async -> Bool
    let disconnect: () -> Void
    let close: () -> Void
    let saveCloudflareAccess: (String, String) -> Void
    let removeCloudflareAccess: () -> Void
    @State private var connected: Bool
    @State private var reconnecting = false
    @State private var cloudflareEnabled: Bool
    @State private var clientID: String
    @State private var clientSecret = ""

    init(snapshot: SettingsSnapshot, reconnect: @escaping () async -> Bool, disconnect: @escaping () -> Void, close: @escaping () -> Void, saveCloudflareAccess: @escaping (String, String) -> Void, removeCloudflareAccess: @escaping () -> Void) {
        self.snapshot = snapshot; self.reconnect = reconnect; self.disconnect = disconnect; self.close = close
        self.saveCloudflareAccess = saveCloudflareAccess; self.removeCloudflareAccess = removeCloudflareAccess
        _connected = State(initialValue: snapshot.isConnected)
        _cloudflareEnabled = State(initialValue: snapshot.cloudflareAccess != nil)
        _clientID = State(initialValue: snapshot.cloudflareAccess?.clientID ?? "")
    }
    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: "Connection", symbol: "radio", tint: .conduitAura) {
                SettingsMetricRow(label: "Server", value: snapshot.server ?? "—", lineLimit: 1)
                SettingsMetricRow(label: "Status", value: connected ? "Connected" : "Disconnected", valueColor: connected ? .green : .red, statusDot: connected ? .green : .red)
                Button { Task { reconnecting = true; connected = await reconnect(); reconnecting = false } } label: { Label(reconnecting ? "Reconnecting…" : "Reconnect", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).frame(height: 44) }
                    .disabled(reconnecting).conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.12))
            }
            ConduitSettingsSection(title: "Cloudflare Access", symbol: "shield.lefthalf.filled", tint: .conduitAccent) {
                Toggle("Use service token", isOn: Binding(get: { cloudflareEnabled }, set: { enabled in
                    cloudflareEnabled = enabled
                    if !enabled { clientSecret = ""; removeCloudflareAccess() }
                }))
                if cloudflareEnabled {
                    TextField("Client ID", text: $clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                    Button("Save token") { saveCloudflareAccess(clientID, clientSecret); clientSecret = "" }
                        .buttonStyle(.borderedProminent).tint(.conduitAccent)
                    Text("The secret is stored only in Keychain. Reconnect after changing it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button(role: .destructive) { disconnect(); close() } label: { Label("Disconnect from Hermes", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity).frame(height: 48) }
                .conduitGlassControl(cornerRadius: 18, tint: .red.opacity(0.18))
        }
        .navigationTitle("Gateway")
    }
}

private struct AppearanceSettingsDetail: View {
    @EnvironmentObject private var appState: AppState
    let theme: ThemePreference
    let saveTheme: (ThemePreference) -> Void
    @State private var selected: ThemePreference
    @State private var isChangingIcon = false
    init(theme: ThemePreference, saveTheme: @escaping (ThemePreference) -> Void) { self.theme = theme; self.saveTheme = saveTheme; _selected = State(initialValue: theme) }
    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: "Theme", symbol: "circle.lefthalf.filled", tint: .conduitAccent) {
                Text("Choose how Conduit appears across this device.").font(.footnote).foregroundStyle(.secondary)
                Picker("Theme", selection: Binding(get: { selected }, set: {
                    selected = $0
                    Haptics.selection()
                    saveTheme($0)
                })) {
                    Text("Dark").tag(ThemePreference.dark); Text("Light").tag(ThemePreference.light); Text("System").tag(ThemePreference.system)
                }.pickerStyle(.segmented)
            }
            ConduitSettingsSection(title: "App icon", symbol: "app.badge", tint: .conduitAura) {
                Text("Choose the icon shown on your Home Screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Button {
                            Task {
                                isChangingIcon = true
                                let changed = await appState.selectAppIcon(choice)
                                isChangingIcon = false
                                changed ? Haptics.success() : Haptics.error()
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(choice.previewAssetName)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                HStack(spacing: 4) {
                                    Text(choice.title)
                                    if appState.appIconChoice == choice {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                                .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(appState.appIconChoice == choice ? Color.conduitAccent : .primary)
                            .conduitGlassSurface(
                                cornerRadius: 18,
                                tint: appState.appIconChoice == choice ? .conduitAccent.opacity(0.14) : .clear
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isChangingIcon)
                        .accessibilityLabel("Use \(choice.title.lowercased()) app icon")
                    }
                }
            }
        }.navigationTitle("Appearance")
    }
}

private struct NotificationsSettingsDetail: View {
    @ObservedObject private var notifications = PushNotificationService.shared
    @AppStorage("conduit.relayURL") private var customRelayURL: String = ""

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: "This iPhone", symbol: "bell.badge", tint: .conduitAura) {
                SettingsMetricRow(
                    label: "Status",
                    value: notifications.statusText,
                    valueColor: notifications.isEnabled ? .green : .secondary,
                    statusDot: notifications.isEnabled ? .green : nil
                )
                Button {
                    Task {
                        let wasEnabled = notifications.isEnabled
                        if notifications.isEnabled {
                            await notifications.disable()
                        } else {
                            await notifications.enable()
                        }
                        if notifications.lastError == nil && notifications.isEnabled != wasEnabled {
                            Haptics.success()
                        } else {
                            Haptics.error()
                        }
                    }
                } label: {
                    Label(
                        notifications.isWorking ? "Updating…" : (notifications.isEnabled ? "Turn off notifications" : "Enable notifications"),
                        systemImage: notifications.isEnabled ? "bell.slash" : "bell.badge.fill"
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(notifications.isEnabled ? Color.primary : Color.white)
                }
                .disabled(notifications.isWorking)
                .conduitGlassControl(
                    cornerRadius: 17,
                    tint: notifications.isEnabled ? .red.opacity(0.18) : .conduitAccent,
                    prominent: !notifications.isEnabled
                )
                if let error = notifications.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if notifications.isEnabled {
                ConduitSettingsSection(title: "Notify me when", symbol: "slider.horizontal.3", tint: .conduitAccent) {
                    notificationToggle("Approval needed", detail: "A tool is waiting for approval", keyPath: \.approvalNeeded)
                    notificationToggle("Input needed", detail: "Hermes needs your answer", keyPath: \.inputNeeded)
                    notificationToggle("Response ready", detail: "An active turn finishes", keyPath: \.responseReady)
                    notificationToggle("Turn failed", detail: "A turn stops with an error", keyPath: \.turnFailed)
                    notificationToggle("Background task finished", detail: "A delegated agent completes", keyPath: \.backgroundTaskFinished)
                    notificationToggle("Completion sound", detail: "Play a sound with notifications", keyPath: \.completionSound)
                    notificationToggle("Show previews", detail: "Include response text in notifications", keyPath: \.showPreviews)
                    notificationToggle("Approval cards in pushes", detail: "Include approval details so cards work from notifications. Disable for maximum privacy.", keyPath: \.decisionCards)
                }

                ConduitSettingsSection(title: "Compatibility", symbol: "checkmark.seal", tint: .conduitAura) {
                    if notifications.isFetchingMeta {
                        Text("Checking compatibility…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let meta = notifications.relayMeta {
                        compatibilityRow(
                            title: "Push relay",
                            version: meta.version,
                            isSupported: meta.supportsDecisionCards,
                            supportedDetail: "Supports decision cards",
                            outdatedDetail: "Decision cards need a relay update"
                        )
                        ForEach(meta.gateways) { gateway in
                            compatibilityRow(
                                title: gateway.name,
                                version: gateway.pluginVersion,
                                isSupported: gateway.supportsApprovalCards && gateway.supportsClarifyCards,
                                supportedDetail: "Notifier supports approval and clarify cards",
                                outdatedDetail: gateway.hasSentEventsButNeverReported
                                    ? "This profile's notifier predates decision cards — update it to receive them"
                                    : gateway.pluginVersion == nil
                                        ? "Waiting for the first notification from this profile"
                                        : "Notifier update available — approval and clarify cards need a newer plugin"
                            )
                            // The update prompt requires evidence of oldness:
                            // either a reported-but-old version, or events that
                            // never carried one (pre-0.2). A gateway that has
                            // sent nothing keeps only the "waiting" copy.
                            if gateway.hasSentEventsButNeverReported
                                || (gateway.pluginVersion != nil
                                    && (!gateway.supportsApprovalCards || !gateway.supportsClarifyCards)) {
                                NotificationSetupCommand(step: 1, title: "Update the notifier", command: "hermes plugins update conduit_push")
                                NotificationSetupCommand(step: 2, title: "Restart the gateway", command: "hermes gateway restart")
                            }
                        }
                    } else {
                        Text("Compatibility unknown. Your relay predates version reporting; decision cards may not be available until it updates.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .task { await notifications.refreshMeta() }

                ConduitSettingsSection(title: "Connect a Hermes profile", symbol: "link.badge.plus", tint: .conduitAura) {
                    Text("Install the notifier once on the gateway, then create a short-lived pairing code here for each Hermes profile you want to reach.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NotificationSetupCommand(step: 1, title: "Install the notifier", command: "hermes plugins install kaishi00/hermes-conduit-notifier --enable")
                    NotificationSetupCommand(step: 2, title: "Restart the gateway", command: "hermes gateway restart")
                    Button {
                        Task {
                            await notifications.createPairingCode()
                            notifications.pairingCode == nil ? Haptics.error() : Haptics.success()
                        }
                    } label: {
                        Label(notifications.isWorking ? "Creating code…" : "Create pairing code", systemImage: "number")
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                    }
                    .disabled(notifications.isWorking)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.16))

                    if let code = notifications.pairingCode {
                        NotificationSetupCommand(step: 3, title: "Pair the active profile", command: "hermes conduit-push pair \(code)")
                        if let expiry = notifications.pairingExpiry {
                            Text("This code expires \(expiry).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ConduitSettingsSection(title: "Verify pairing", symbol: "checkmark.seal", tint: .conduitAccent) {
                    Text("After pairing, run these on the same Hermes profile. First confirm the local relay credential, then send a test. You should receive the test notification on this iPhone within a few seconds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NotificationSetupCommand(step: 4, title: "Check pairing status", command: "hermes conduit-push status")
                    NotificationSetupCommand(step: 5, title: "Send a test notification", command: "hermes conduit-push test")
                }
                ConduitSettingsSection(title: "How it works", symbol: "hand.raised", tint: .conduitAura) {
                    Text("The notifier receives a revocable credential for this phone. Your gateway never needs the phone’s push token, and you can turn notifications off here at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ConduitSettingsSection(title: "Push relay", symbol: "server.rack", tint: .conduitAura) {
                    TextField("https://push.milim.dev", text: $customRelayURL)
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        .padding(.vertical, 4)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit {
                            Task { await notifications.refreshMeta() }
                        }
                    Text("Leave blank to use the default relay. Change this if you run your own push relay server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Notifications")
        .task {
            await notifications.refresh()
            await notifications.refreshMeta()
        }
    }

    @ViewBuilder
    private func compatibilityRow(
        title: String,
        version: String?,
        isSupported: Bool,
        supportedDetail: String,
        outdatedDetail: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isSupported ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isSupported ? .green : .orange)
                .accessibilityLabel(isSupported ? "Supported" : "Update needed")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    if let version {
                        Text("v\(version)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(isSupported ? supportedDetail : outdatedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func notificationToggle(
        _ title: String,
        detail: String,
        keyPath: WritableKeyPath<ConduitNotificationPreferences, Bool>
    ) -> some View {
        Toggle(isOn: Binding(
            get: { notifications.preferences[keyPath: keyPath] },
            set: { value in
                Haptics.selection()
                Task { await notifications.setPreference(keyPath, enabled: value) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.conduitAccent)
    }
}

private struct NotificationSetupCommand: View {
    let step: Int
    let title: String
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(step)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.conduitAccent, in: Circle())
                Text(title).font(.subheadline.weight(.semibold))
            }
            Button {
                UIPasteboard.general.string = command
                Haptics.light()
                copied = true
            } label: {
                HStack(spacing: 10) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            .conduitGlassSurface(cornerRadius: 14, tint: .conduitAccent.opacity(0.08))
            .accessibilityLabel("Copy \(title) command")
        }
        .padding(.top, 4)
    }
}

private struct AboutSettingsDetail: View {
    let profile: String
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: "Hermes Conduit", symbol: "info.circle", tint: .conduitAccent) {
                HStack(spacing: 12) {
                    ConduitAppIconArtwork(
                        assetName: appState.appIconChoice.previewAssetName,
                        size: 48
                    )
                    Text("A touch-first native client for your Hermes gateway.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                SettingsMetricRow(label: "Active profile", value: profile.capitalized)
                SettingsMetricRow(label: "Version", value: ConduitAppVersion.display)
            }
            ConduitSettingsSection(title: "Data handling", symbol: "hand.raised", tint: .conduitAura) {
                Text("Conduit connects to the dashboard and gateway you configure. Conversations and attachments are handled by that Hermes installation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ConduitSettingsSection(title: "Links", symbol: "link", tint: .conduitAccent) {
                Link(destination: URL(string: "https://kaishi00.github.io/hermes-conduit-notifier/privacy/")!) {
                    HStack {
                        Image(systemName: "lock.shield")
                        Text("Privacy policy")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Link(destination: URL(string: "https://kaishi00.github.io/hermes-conduit-notifier/support/")!) {
                    HStack {
                        Image(systemName: "lifepreserver")
                        Text("Support")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Link(destination: URL(string: "https://github.com/kaishi00/hermes-conduit-notifier")!) {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("GitHub")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            ConduitSettingsSection(title: "Disclaimer", symbol: "info.circle", tint: .conduitAura) {
                Text("Hermes Conduit is an independent client and is not affiliated with or endorsed by Nous Research. © 2026 Milim.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("About & privacy")
    }

}

private struct SettingsDetailContainer<Content: View>: View {
    var compact = false
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            ConduitBackdrop()
            ScrollView { VStack(alignment: .leading, spacing: compact ? 12 : 14) { content }.padding(16) }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

// MARK: - Shared settings components

struct ConduitSettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    private let content: Content

    init(
        title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .conduitGlassSurface(cornerRadius: 24, tint: tint.opacity(0.07))
    }
}

struct SettingsMetricRow: View {
    let label: String
    let value: String
    var valueColor: Color = .secondary
    var statusDot: Color?
    var lineLimit: Int? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            if let statusDot {
                Circle()
                    .fill(statusDot)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusDot.opacity(0.7), radius: 4)
            }
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(valueColor)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
