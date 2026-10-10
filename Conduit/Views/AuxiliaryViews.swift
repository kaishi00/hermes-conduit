//
//  AuxiliaryViews.swift
//  Conduit
//
//  Context and settings surfaces.
//

import SwiftUI

private enum ConduitAppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppLocalization.string("Unknown")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? AppLocalization.string("Unknown")
        return "\(version) (\(build))"
    }
}
import UIKit

// MARK: - Context Sheet

struct ContextSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @State private var breakdown: ContextBreakdown?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        ConduitSettingsSection(title: AppLocalization.string("Context"), symbol: "circle.dotted.circle", tint: .conduitAura) {
                            SettingsMetricRow(label: AppLocalization.string("Used"), value: AppLocalization.string("\(Int(appState.runtime.contextUsed)) tokens"))
                            SettingsMetricRow(label: AppLocalization.string("Capacity"), value: AppLocalization.string("\(Int(appState.runtime.contextMax)) tokens"))
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text("Window usage")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(String(Int(appState.runtime.contextPercent.rounded())))%")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                }
                                ProgressView(value: appState.runtime.contextPercent, total: 100)
                                    .tint(.conduitAccent)
                            }
                            .padding(.top, 4)
                        }

                        if let breakdown {
                            ConduitSettingsSection(title: AppLocalization.string("Breakdown"), symbol: "chart.pie", tint: .conduitAccent) {
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
    @ObservedObject var appLanguage = AppLanguageStore.shared
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
                ConduitSheetHeader(title: AppLocalization.string("Settings"), close: { dismiss() })
            }
        }
        .preferredColorScheme(theme.colorScheme)
    }

    private var connectionSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Connection"), symbol: "bolt.horizontal.circle", tint: .conduitAura) {
            SettingsMetricRow(label: AppLocalization.string("Server"), value: snapshot.server ?? "—", lineLimit: 1)
            SettingsMetricRow(
                label: AppLocalization.string("Status"),
                value: isConnected ? AppLocalization.string("Connected") : AppLocalization.string("Disconnected"),
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
                Label(isReconnecting ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Reconnect"), systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6).frame(minHeight: 44)
            }
            .disabled(isReconnecting)
            .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.12))
            .padding(.top, 4)
        }
    }

    private var appearanceSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Appearance"), symbol: "circle.lefthalf.filled", tint: .conduitAccent) {
            Text("Choose how Conduit appears across the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ConduitGlassGroup(spacing: 8) {
                AdaptiveStack(spacing: 8) {
                    themeChoice(.dark, title: AppLocalization.string("Dark"), symbol: "moon.fill")
                    themeChoice(.light, title: AppLocalization.string("Light"), symbol: "sun.max.fill")
                    themeChoice(.system, title: AppLocalization.string("System"), symbol: "circle.lefthalf.filled")
                }
            }
        }
    }

    private var chatSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("During a response"), symbol: "bubble.left.and.bubble.right", tint: .conduitAccent) {
            Text("Choose what a typed message does while Hermes is still working.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ConduitGlassGroup(spacing: 10) {
                AdaptiveStack(spacing: 10) {
                    busyModeChoice(.steer, symbol: BusyInputMode.steer.symbol, detail: AppLocalization.string("Guide safely"))
                    busyModeChoice(.interrupt, symbol: BusyInputMode.interrupt.symbol, detail: AppLocalization.string("Stop and correct"))
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
        ConduitSettingsSection(title: AppLocalization.string("About"), symbol: "info.circle", tint: .conduitAura) {
            SettingsMetricRow(label: AppLocalization.string("Profile"), value: snapshot.profile.capitalized)
            SettingsMetricRow(label: AppLocalization.string("Version"), value: ConduitAppVersion.display)
        }
    }

    private var chatDisplaySection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Chat display"), symbol: "text.bubble", tint: .conduitAura) {
            Text("These choices follow the active workspace.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            displayToggle(.reasoning, title: AppLocalization.string("Show reasoning"), detail: AppLocalization.string("Include available agent reasoning in replies."))
            displayToggle(.toolProgress, title: AppLocalization.string("Show tool activity"), detail: AppLocalization.string("Show tool calls and their progress in chat."))
            displayToggle(.expandTools, title: AppLocalization.string("Keep tool cards expanded"), detail: AppLocalization.string("Open completed tool details by default."))

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
                .padding(.vertical, 6).frame(minHeight: 48)
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
            .padding(.vertical, 6).frame(minHeight: 58)
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
            .padding(.vertical, 6).frame(minHeight: 72)
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
                displayPreferenceError = AppLocalization.string("Could not save this setting. Restored the previous choice.")
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
                busyInputModeError = AppLocalization.string("Could not save this setting. Restored the previous choice.")
            }
            isSavingBusyInputMode = false
        }
    }
}

// MARK: - Settings home and detail routes

private enum SettingsDestination: Hashable {
    case profile, model, chat, voice, workspace, memory, capabilities, gateway, savedDashboards, appearance, notifications, screenQuestion, about
}

enum ProfileSettingControl {
    case toggle(defaultValue: Bool)
    case textToggle(onValue: String, offValue: String, defaultValue: Bool)
    case options([String], defaultValue: String)
    case labeledOptions([(value: String, label: String)], defaultValue: String)
    case text(defaultValue: String)
    case number(defaultValue: Double)
}

struct ProfileSettingField: Identifiable {
    let key: String
    let label: String
    let help: String
    let control: ProfileSettingControl
    var id: String { key }
}

struct SettingsView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
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
                    ConduitSheetHeader(title: AppLocalization.string("Settings"), close: { dismiss() })
                }
                .navigationDestination(for: SettingsDestination.self) { destination in
                    destinationView(destination)
                }
        }
        .preferredColorScheme(appState.themePreference.colorScheme)
    }

    private func wakeSettings(profile: String) -> WakePhraseSettingsModel? {
        guard appState.wakeGatewayID != nil else { return nil }
        let preferences = appState.wakePreferences(forProfile: profile)
        return WakePhraseSettingsModel(
            phrases: preferences.enabledPhrases,
            suggestedPhrase: appState.suggestedWakePhrase(forProfile: profile),
            startsFreshConversation: preferences.startsFreshConversation,
            listensOnCarPlay: appState.wakeListensOnCarPlay,
            listensOverOtherAudio: appState.wakeListensOverOtherAudio,
            isPausedForOtherAudio: appState.isWakePausedForOtherAudio,
            failure: appState.wakeListeningFailure,
            save: { phrases, startsFresh in
                appState.setWakePreferences(
                    WakeProfilePreferences(enabledPhrases: phrases, startsFreshConversation: startsFresh),
                    forProfile: profile
                )
            },
            setListensOnCarPlay: { appState.setWakeListensOnCarPlay($0) },
            setListensOverOtherAudio: { appState.setWakeListensOverOtherAudio($0) }
        )
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
                // One decode per render, not one per seeded field.
                let voicePreferences = appState.activeProfileVoicePreferences
                VoiceSettingsRoute(
                    bridge: bridge,
                    profile: snapshot.profile,
                    conversationController: appState.voiceConversationController,
                    actions: VoiceSettingsActions(
                        runASRTest: { await appState.runVoiceASRTest() },
                        runTTSTest: { await appState.runVoiceTTSTest() }
                    ),
                    voiceEnabled: appState.isVoiceEnabled,
                    transcriptionMode: appState.voiceTranscriptionMode,
                    transcriptionModeChosen: voicePreferences.transcriptionMode != nil,
                    appleSpeechAvailability: appState.appleSpeechAvailability,
                    continuousConversation: appState.continuousConversationEnabled,
                    spokenStopPhrases: voicePreferences.resolvedSpokenStopPhrases,
                    spokenEndConversationPhrases: voicePreferences.resolvedSpokenEndConversationPhrases,
                    spokenPhrasesCustomized: voicePreferences.spokenStopPhrases != nil
                        || voicePreferences.spokenEndConversationPhrases != nil,
                    setVoiceEnabled: { enabled in
                        await appState.setVoiceEnabled(enabled)
                    },
                    setTranscriptionMode: { mode in
                        await appState.setVoiceTranscriptionMode(mode)
                    },
                    setContinuousConversation: { enabled in
                        appState.setContinuousConversation(enabled)
                    },
                    setStopPhrases: { phrases in
                        appState.setSpokenStopPhrases(phrases)
                    },
                    setEndConversationPhrases: { phrases in
                        appState.setSpokenEndConversationPhrases(phrases)
                    },
                    geminiLive: GeminiLiveSettingsModel(
                        enabled: appState.isGeminiLiveEnabled,
                        setEnabled: { appState.setGeminiLiveEnabled($0) },
                        checkAvailability: {
                            do {
                                return .success(try await appState.geminiLiveTokenClient.availability())
                            } catch {
                                return .failure(error)
                            }
                        },
                        search: appState.geminiLiveSearchMode,
                        setSearch: { appState.setGeminiLiveSearchMode($0) },
                        voice: appState.geminiLiveVoice,
                        setVoice: { appState.setGeminiLiveVoice($0) },
                        memory: appState.geminiLiveMemoryEnabled,
                        setMemory: { appState.setGeminiLiveMemoryEnabled($0) },
                        personality: appState.geminiLivePersonalityEnabled,
                        setPersonality: { appState.setGeminiLivePersonalityEnabled($0) },
                        saveCalls: appState.voiceCallSavingEnabled,
                        setSaveCalls: { appState.setVoiceCallSavingEnabled($0) },
                        speakerBargeIn: appState.liveVoiceSpeakerBargeInEnabled,
                        setSpeakerBargeIn: { appState.setLiveVoiceSpeakerBargeInEnabled($0) }
                    ),
                    gptLive: GPTLiveSettingsModel(
                        enabled: appState.isGPTLiveEnabled,
                        setEnabled: { appState.setGPTLiveEnabled($0) },
                        checkAvailability: {
                            do {
                                return .success(try await appState.gptLiveClient.availability())
                            } catch {
                                return .failure(error)
                            }
                        },
                        voice: appState.gptLiveVoice,
                        setVoice: { appState.setGPTLiveVoice($0) },
                        memory: appState.gptLiveMemoryEnabled,
                        setMemory: { appState.setGPTLiveMemoryEnabled($0) },
                        personality: appState.gptLivePersonalityEnabled,
                        setPersonality: { appState.setGPTLivePersonalityEnabled($0) },
                        saveCalls: appState.voiceCallSavingEnabled,
                        setSaveCalls: { appState.setVoiceCallSavingEnabled($0) }
                    ),
                    grokLive: GrokLiveSettingsModel(
                        enabled: appState.isGrokLiveEnabled,
                        setEnabled: { appState.setGrokLiveEnabled($0) },
                        checkAvailability: {
                            do {
                                return .success(try await appState.grokLiveClient.availability())
                            } catch {
                                return .failure(error)
                            }
                        },
                        memory: appState.grokLiveMemoryEnabled,
                        setMemory: { appState.setGrokLiveMemoryEnabled($0) },
                        personality: appState.grokLivePersonalityEnabled,
                        setPersonality: { appState.setGrokLivePersonalityEnabled($0) },
                        saveCalls: appState.voiceCallSavingEnabled,
                        setSaveCalls: { appState.setVoiceCallSavingEnabled($0) },
                        speakerBargeIn: appState.liveVoiceSpeakerBargeInEnabled,
                        setSpeakerBargeIn: { appState.setLiveVoiceSpeakerBargeInEnabled($0) }
                    ),
                    liveStyle: appState.isGeminiLiveEnabled || appState.isGPTLiveEnabled || appState.isGrokLiveEnabled
                        ? LiveVoiceStyleSettingsModel(
                            profile: appState.activeProfile,
                            style: appState.liveVoiceStyle,
                            setStyle: { [profile = appState.activeProfile] style in
                                appState.setLiveVoiceStyle(style, profile: profile)
                            },
                            preview: { [profile = appState.activeProfile] in
                                appState.liveVoiceInstructionsPreview(profile: profile)
                            }
                        )
                        : nil,
                    voiceJobs: VoiceJobModelSettingsModel(
                        provider: voicePreferences.voiceJobProvider,
                        model: voicePreferences.voiceJobModel,
                        reasoningEffort: voicePreferences.voiceJobReasoningEffort,
                        loadProviders: { await appState.loadVoiceJobModelProviders() },
                        save: { provider, model, reasoning in
                            appState.setVoiceJobModel(provider: provider, model: model, reasoningEffort: reasoning)
                        }
                    ),
                    voiceReplies: VoiceReplyModelSettingsModel(
                        load: { await appState.loadVoiceReplyModel() },
                        loadProviders: { await appState.loadVoiceJobModelProviders() },
                        save: { await appState.setVoiceReplyModel($0) }
                    ),
                    wake: wakeSettings(profile: snapshot.profile),
                    lockedListening: VoiceLockedListeningSettingsModel(
                        enabled: appState.keepVoiceListeningWhenLocked,
                        setEnabled: { appState.setKeepVoiceListeningWhenLocked($0) }
                    ),
                    speakerTalkOver: VoiceSpeakerTalkOverSettingsModel(
                        enabled: appState.liveVoiceSpeakerBargeInEnabled,
                        setEnabled: { appState.setLiveVoiceSpeakerBargeInEnabled($0) }
                    ),
                    callSaves: VoiceCallSaveStatusModel(
                        pendingCount: appState.pendingVoiceCallSaves,
                        blocked: appState.voiceCallSavesBlocked,
                        isSaving: appState.isSavingQueuedVoiceCalls,
                        isWaitingOnCall: appState.isLiveVoiceCallActive,
                        saveNow: { await appState.saveQueuedVoiceCallsNow() }
                    ),
                    hermesCalls: appState.supportsHermesCalls
                        ? HermesCallSettingsModel(
                            profile: appState.activeProfile,
                            status: appState.activeHermesCallsStatus,
                            load: {
                                await appState.refreshHermesCallsStatus()
                                return appState.activeHermesCallsStatus != nil
                            },
                            current: { appState.activeHermesCallsStatus?.settings },
                            save: { [profile = appState.activeProfile, dashboardID = appState.activeDashboardID] settings in
                                await appState.saveHermesCallSettings(settings, profile: profile, dashboardID: dashboardID)
                            }
                        )
                        : nil
                )
            } else {
                SettingsDetailContainer {
                    ConduitSettingsSection(title: AppLocalization.string("Voice"), symbol: "mic.slash", tint: .orange) {
                        Text("Connect to Hermes to configure voice for this profile.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .workspace:
            ProfileConfigSettingsPage(
                title: AppLocalization.string("Workspace & safety"),
                subtitle: AppLocalization.string("Working defaults and safeguards for this profile."),
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
        case .capabilities:
            CapabilitiesView()
        case .gateway:
            GatewaySettingsDetail(snapshot: snapshot, reconnect: reconnect, disconnect: disconnect, close: { dismiss() }, saveCloudflareAccess: appState.saveCloudflareAccess, removeCloudflareAccess: appState.removeCloudflareAccess, customHeaders: appState.customHeaders(), saveCustomHeaders: appState.saveCustomHeaders)
        case .savedDashboards:
            SavedDashboardsSettingsDetail(close: { dismiss() })
        case .appearance:
            AppearanceSettingsDetail(theme: appState.themePreference, saveTheme: saveTheme)
        case .notifications:
            NotificationsSettingsDetail()
        case .screenQuestion:
            SettingsDetailContainer {
                ScreenQuestionSettingsSection()
                ScreenQuestionHowItWorksSection()
            }
                .navigationTitle("Ask Hermes About Screen")
        case .about:
            AboutSettingsDetail(profile: snapshot.profile)
        }
    }

    static var workspaceFields: [ProfileSettingField] { [
        .init(key: "terminal.cwd", label: AppLocalization.string("Default working directory"), help: AppLocalization.string("Server-side path for new workspaces."), control: .text(defaultValue: "")),
        .init(key: "code_execution.mode", label: AppLocalization.string("Code execution mode"), help: AppLocalization.string("Default execution boundary."), control: .options(["project", "strict"], defaultValue: "project")),
        .init(key: "approvals.mode", label: AppLocalization.string("Approval mode"), help: AppLocalization.string("Profile-wide default: manual asks every time; smart asks when risk warrants it; off is YOLO mode. When set to off, Hermes auto-approves everything and per-session YOLO toggles have no effect — that's a Hermes limitation, not a Conduit bug. To use per-session YOLO, set this to manual or smart."), control: .options(["manual", "smart", "off"], defaultValue: "smart")),
        .init(key: "security.redact_secrets", label: AppLocalization.string("Redact secrets"), help: AppLocalization.string("Hide detected credentials from tool output where possible."), control: .toggle(defaultValue: true)),
        .init(key: "security.allow_private_urls", label: AppLocalization.string("Allow private URLs"), help: AppLocalization.string("Permit tool access to private-network URLs."), control: .toggle(defaultValue: false)),
    ]
    }

    static var memoryFields: [ProfileSettingField] { [
        .init(key: "memory.provider", label: AppLocalization.string("Memory provider"), help: AppLocalization.string("Provider used for long-term memory."), control: .options([], defaultValue: "")),
        .init(key: "memory.memory_enabled", label: AppLocalization.string("Long-term memory"), help: AppLocalization.string("Allow Hermes to retain relevant working memory."), control: .toggle(defaultValue: true)),
        .init(key: "memory.user_profile_enabled", label: AppLocalization.string("User profile memory"), help: AppLocalization.string("Allow Hermes to maintain user preferences."), control: .toggle(defaultValue: true)),
        .init(key: "context.engine", label: AppLocalization.string("Context engine"), help: AppLocalization.string("Installed context-management engine."), control: .options([], defaultValue: "default")),
        .init(key: "compression.enabled", label: AppLocalization.string("Context compression"), help: AppLocalization.string("Compress older context when the window becomes crowded."), control: .toggle(defaultValue: true)),
        .init(key: "compression.threshold", label: AppLocalization.string("Compression threshold"), help: AppLocalization.string("Fraction of the context window that starts compression."), control: .number(defaultValue: 0.8)),
        .init(key: "compression.target_ratio", label: AppLocalization.string("Compression target"), help: AppLocalization.string("Fraction retained after compression."), control: .number(defaultValue: 0.5)),
        .init(key: "compression.protect_last_n", label: AppLocalization.string("Protected recent messages"), help: AppLocalization.string("Recent messages left intact by compression."), control: .number(defaultValue: 8)),
        .init(key: "delegation.max_concurrent_children", label: AppLocalization.string("Concurrent delegate agents"), help: AppLocalization.string("Maximum child agents that can work at once."), control: .number(defaultValue: 2)),
    ]
    }
}

private struct SettingsHome: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: SettingsSnapshot
    @Binding var path: [SettingsDestination]
    @EnvironmentObject private var appState: AppState
    /// Round 5: the Settings entry into the existing Connection Setup
    /// assistant, seeded from the current configuration.
    @State private var connectionSetupSeed: ConnectionSetupSeed?
    /// Set by the wizard's completion when the applied plan changes the
    /// saved configuration; surfaced as an alert only after the wizard sheet
    /// has dismissed (one presentation context at a time).
    @State private var pendingAppliedNotice = false
    @State private var appliedConnectionNotice = false

    /// Per-presentation seed for the wizard, built once when the row is
    /// tapped so the Keychain reads stay off the render path.
    private struct ConnectionSetupSeed: Identifiable {
        let url: String
        let username: String
        let password: String
        let cloudflareAccess: CloudflareAccessCredentials?
        var id: String { url }
    }

    var body: some View {
        ZStack {
            ConduitBackdrop()
            ScrollView {
                VStack(spacing: 14) {
                    if appState.notifierPlugin.needsUpdate {
                        NotifierPluginUpdateNotice(status: appState.notifierPlugin, dashboardLabel: notifierDashboardLabel)
                    }
                    homeSection(AppLocalization.string("Profile"), symbol: "person.crop.circle", tint: .conduitAccent) {
                        settingsLink(.profile, icon: "person.crop.circle", title: profileDisplayName, detail: AppLocalization.string("Profile-specific preferences"))
                    }
                    homeSection("Hermes", tint: .conduitAura) {
                        settingsLink(.model, icon: "cpu", title: AppLocalization.string("Model"), detail: AppLocalization.string("Default model and reasoning"))
                        settingsLink(.chat, icon: "bubble.left.and.bubble.right", title: AppLocalization.string("Chat"), detail: AppLocalization.string("Response behavior, visibility, and timezone"))
                        settingsLink(.voice, icon: "mic.and.signal.meter", title: AppLocalization.string("Voice"), detail: AppLocalization.string("Speech providers, credentials, and device opt-in"))
                        settingsLink(.workspace, icon: "folder", title: AppLocalization.string("Workspace & safety"), detail: AppLocalization.string("Working directory, approvals, and privacy"))
                        settingsLink(.memory, icon: "brain.head.profile", title: AppLocalization.string("Memory & delegation"), detail: AppLocalization.string("Memory, compression, and child agents"))
                        settingsLink(.capabilities, icon: "puzzlepiece.extension", title: AppLocalization.string("Capabilities"), detail: AppLocalization.string("Skills, toolsets, and categories"))
                    }
                    homeSection(AppLocalization.string("Connection"), tint: .conduitAura) {
                        settingsLink(.savedDashboards, icon: "server.rack", title: AppLocalization.string("Saved Dashboards"), detail: savedDashboardsDetail, identifier: "settings.saved-dashboards")
                        settingsLink(.gateway, icon: "radio", title: AppLocalization.string("Gateway"), detail: snapshot.server ?? AppLocalization.string("Not connected"), identifier: "settings.gateway")
                        settingsActionRow(
                            icon: "checkmark.circle",
                            title: AppLocalization.string("Connection Setup"),
                            detail: AppLocalization.string("Test, troubleshoot, or change your connection"),
                            identifier: "settings.connection-setup"
                        ) {
                            let seedURL = currentDashboardURL
                            let saved = appState.savedCredentialsForDashboard(at: seedURL)
                            let seeded = ConnectionSetupSeeding.wizardCredentials(for: seedURL, saved: saved)
                            connectionSetupSeed = ConnectionSetupSeed(
                                url: seedURL,
                                username: seeded?.username ?? "",
                                password: seeded?.password ?? "",
                                cloudflareAccess: appState.dashboardScopedCloudflareAccess(for: seedURL)
                            )
                        }
                    }
                    homeSection(AppLocalization.string("On this device"), tint: .conduitAccent) {
                        settingsLink(.appearance, icon: "circle.lefthalf.filled", title: AppLocalization.string("Appearance"), detail: AppLocalization.string("Theme and interface preferences"))
                        settingsLink(.notifications, icon: "bell", title: AppLocalization.string("Notifications"), detail: AppLocalization.string("Delivery status and setup"))
                        settingsLink(.screenQuestion, icon: "camera.viewfinder", title: AppLocalization.string("Ask Hermes About Screen"), detail: AppLocalization.string("Action Button shortcut for screenshots"), identifier: "settings.screen-question")
                        settingsLink(.about, icon: "shield", title: AppLocalization.string("About & privacy"), detail: AppLocalization.string("App information and data handling"))
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
        .sheet(item: $connectionSetupSeed, onDismiss: {
            guard pendingAppliedNotice else { return }
            pendingAppliedNotice = false
            appliedConnectionNotice = true
        }) { seed in
            ConnectionSetupView(
                initialDestination: .currentConnection,
                initialDraft: ConnectionSetupDraft(
                    existingServerURL: seed.url,
                    username: seed.username,
                    password: seed.password
                ),
                // The probe may reuse this same-origin service token; the
                // wizard re-verifies the origin itself before sending it and
                // never displays, edits, or persists it.
                initialCloudflareAccess: seed.cloudflareAccess,
                initialCloudflareOriginURL: seed.url
            ) { result in
                // Reload the saved state at apply time: the plan must decide
                // against what exists NOW, not what existed when the sheet
                // was seeded.
                let plan = ConnectionSetupApplication.plan(
                    result: result,
                    currentDashboardURL: seed.url,
                    savedCredentials: appState.savedCredentialsForDashboard(at: seed.url),
                    savedCloudflareAccess: appState.dashboardScopedCloudflareAccess(for: seed.url)
                )
                plan.perform(appState: appState)
                pendingAppliedNotice = !plan.isEmpty
            }
        }
        .alert("Settings applied", isPresented: $appliedConnectionNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Saved for your next reconnect. Your current session stays connected.")
        }
        // Asked again on every visit and dashboard switch: the connect-time
        // check can miss (the dashboard was still loading), and the plugin
        // may have been updated since, which should clear the notice.
        .task(id: appState.activeDashboardID) {
            await appState.refreshNotifierPluginStatus()
        }
    }

    /// The active dashboard's name when several are saved, so the update
    /// notice says which host to update.
    private var notifierDashboardLabel: String? {
        let registry = appState.savedDashboardRegistry
        return registry.dashboards.count > 1 ? registry.activeDashboardLabel : nil
    }

    /// The active connection's address — the live connection when one exists,
    /// else the last configured dashboard. Seeding reads it; applying a
    /// tested result never writes to the live session itself.
    private var currentDashboardURL: String {
        appState.connection?.baseUrl ?? appState.lastDashboardURL
    }

    /// Saved Dashboards row detail: the active dashboard's label plus how
    /// many dashboards are saved.
    private var savedDashboardsDetail: String {
        let registry = appState.savedDashboardRegistry
        guard !registry.dashboards.isEmpty else {
            return AppLocalization.string("Add your first Hermes dashboard")
        }
        let activeLabel = registry.activeDashboardLabel
        let count = AppLocalization.string("\(registry.dashboards.count) dashboards")
        return activeLabel.map { "\($0) · \(count)" } ?? count
    }

    private var profileDisplayName: String {
        snapshot.profile == "default" ? appState.defaultProfileName : snapshot.profile.capitalized
    }

    private func homeSection<Content: View>(_ title: String, symbol: String = "gearshape.2", tint: Color, @ViewBuilder content: () -> Content) -> some View {
        ConduitSettingsSection(title: title, symbol: symbol, tint: tint, content: content)
    }

    private func settingsLink(_ destination: SettingsDestination, icon: String, title: String, detail: String, identifier: String = "") -> some View {
        Button {
            Haptics.selection()
            path.append(destination)
        } label: {
            settingsRowLabel(icon: icon, title: title, detail: detail)
        }
        .buttonStyle(.plain)
        .accessibilityHint(detail)
        .accessibilityIdentifier(identifier)
    }

    private func settingsActionRow(icon: String, title: String, detail: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            settingsRowLabel(icon: icon, title: title, detail: detail)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityHint(detail)
    }

    private func settingsRowLabel(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).conduitFixedGlyph().foregroundStyle(.conduitAccent).frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct ProfileSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
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
            ConduitSettingsSection(title: AppLocalization.string("Active profile"), symbol: "person.crop.circle.fill", tint: .conduitAccent) {
                SettingsMetricRow(label: AppLocalization.string("Profile"), value: currentDisplayName)
                Text("Choose a different profile from the session drawer. Chat, model, workspace, and memory preferences on the other settings pages follow that profile.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if profile == "default" {
                ConduitSettingsSection(title: AppLocalization.string("On this device"), symbol: "pencil", tint: .conduitAccent) {
                    Text("Display name").font(.subheadline.weight(.semibold))
                    TextField("Hermes", text: $name)
                        .textInputAutocapitalization(.words)
                        .padding(10)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("This only changes how the default profile is named in Conduit. Hermes itself still uses the default profile.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(didSave ? AppLocalization.string("Saved") : AppLocalization.string("Save display name")) {
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

struct ChatSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
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
            title: AppLocalization.string("Chat"),
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
            trailingSection: AnyView(
                VStack(spacing: 14) {
                    ChatTextSizeSettings()
                    ComposerReturnKeySettings()
                    AttachmentLimitSettings()
                    ChatTakeoverSettings()
                    DeviceHapticsSettings()
                }
            )
        )
        .navigationTitle("Chat")
        .task { options = await loadOptions() }
    }

    static var fields: [ProfileSettingField] { [
        .init(key: "display.personality", label: AppLocalization.string("Personality"), help: AppLocalization.string("Default response style for new conversations."), control: .options([], defaultValue: "")),
        .init(key: "timezone", label: AppLocalization.string("Timezone"), help: AppLocalization.string("Used for dates, reminders, and scheduled work."), control: .text(defaultValue: "")),
        .init(key: "display.show_reasoning", label: AppLocalization.string("Show thinking"), help: AppLocalization.string("Show collapsible thinking blocks when provided."), control: .toggle(defaultValue: true)),
        .init(key: "display.tool_progress", label: AppLocalization.string("Tool cards"), help: AppLocalization.string("Show tool calls and expandable details in conversations."), control: .textToggle(onValue: "all", offValue: "off", defaultValue: true)),
        .init(key: "display.expand_tools", label: AppLocalization.string("Keep tool cards expanded"), help: AppLocalization.string("Keep completed tool details open by default."), control: .toggle(defaultValue: false)),
        .init(key: "display.memory_notifications", label: AppLocalization.string("Self-improvement updates"), help: AppLocalization.string("Choose whether Conduit follows Hermes, always shows, or never shows maintenance updates."), control: .labeledOptions([(value: "default", label: AppLocalization.string("Use Hermes default")), (value: "on", label: AppLocalization.string("Always show")), (value: "off", label: AppLocalization.string("Never show"))], defaultValue: "default")),
        .init(key: "agent.image_input_mode", label: AppLocalization.string("Image attachments"), help: AppLocalization.string("How Hermes supplies images to a model."), control: .options(["auto", "native", "text"], defaultValue: "auto")),
    ]
    }
}

/// Local, device-only chat text-size preference (issue #85). Stored in
/// UserDefaults via @AppStorage with the same lifetime as
/// ComposerReturnKey — never part of the Hermes profile configuration and
/// never synchronized anywhere. A five-position stepped slider: the change
/// is live (the visible transcript re-renders as the slider moves), there
/// is no Save button, and `Default` keeps today's appearance.
private struct ChatTextSizeSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ChatTypography.preferenceKey) private var chatTextSizeRaw = ChatTypography.defaultSize.rawValue

    private var selected: ChatTextSize {
        ChatTypography.resolve(rawValue: chatTextSizeRaw)
    }

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Chat text size"),
            symbol: "textformat.size",
            tint: .conduitAura
        ) {
            Text("Readable conversation content only — messages, lists, tables, and code. Buttons, timestamps, and the rest of the interface keep their size, and iOS Dynamic Type still applies on top.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("A")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Spacer()
                    Text("A")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Slider(
                    value: Binding(
                        get: { Double(selected.rawValue) },
                        set: { chatTextSizeRaw = Int($0.rounded()) }
                    ),
                    in: 0...Double(ChatTextSize.allCases.count - 1),
                    step: 1
                )
                .tint(.conduitAccent)
                .accessibilityLabel("Chat text size")
                .accessibilityValue(selected.displayName)
                .accessibilityHint("Five steps from smallest to largest. Applies to conversation text immediately.")
                Text(selected.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

/// Local, device-only composer input preference. Stored in UserDefaults via
/// @AppStorage; never part of the Hermes profile configuration.
private struct ComposerReturnKeySettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ComposerReturnKey.preferenceKey) private var returnKeySends = false

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Keyboard"),
            symbol: "keyboard",
            tint: .conduitAura
        ) {
            Text("Press Return to send. Use Shift-Return for a new line.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Hardware keyboards only. The on-screen keyboard's Return key keeps inserting a new line.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Return key sends", isOn: $returnKeySends)
                .tint(.conduitAccent)
                .accessibilityHint("Applies to hardware keyboards only. The on-screen keyboard's Return key is unchanged.")
        }
    }
}

/// Device-only cap on files staged in the composer (#334). Mirrors Hermes
/// Desktop: 16 MB by default, up to the 256 MB the Hermes host accepts.
private struct AttachmentLimitSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(AttachmentSizeLimit.preferenceKey) private var megabytes = AttachmentSizeLimit.defaultMegabytes

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Attachments"),
            symbol: "paperclip",
            tint: .conduitAura
        ) {
            Text("Photos, videos and files larger than this are not attached.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ConduitMenuPicker(
                value: megabytes,
                choices: AttachmentSizeLimit.choices.map { (id: $0, title: "\($0) MB") },
                onSelect: { megabytes = $0 }
            ) {
                Text("Maximum file size").foregroundStyle(.secondary)
            }
            if AttachmentSizeLimit.isRisky(megabytes: megabytes) {
                Label {
                    Text("Large files are held in memory while they upload. A high limit may make Conduit freeze or crash.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Device-only: take a chat over from Hermes Desktop or a terminal as soon
/// as a send is refused, instead of offering a button (#304).
private struct ChatTakeoverSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ChatTakeoverPreference.automaticKey) private var automatic = false

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Chats open on your computer"),
            symbol: "desktopcomputer",
            tint: .conduitAura
        ) {
            Text("Hermes lets one app use a chat at a time. When a chat is open in Hermes Desktop or a terminal, Conduit offers to take it over when you send.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("A reply running there always finishes first. If you go back to that app, reopen the chat there to see what you sent from Conduit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Take over automatically", isOn: $automatic)
                .tint(.conduitAccent)
                .accessibilityHint("Sending in a chat open in Hermes Desktop or a terminal takes it over without asking. Needs the Conduit notifier plugin on your Hermes host.")
        }
    }
}

/// Shown at the top of Settings when the host's notifier plugin is older
/// than the features Conduit uses (chat takeover, live voice, call
/// transcripts), with the commands that update it.
private struct NotifierPluginUpdateNotice: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let status: NotifierPluginStatus
    /// Names the dashboard when several are saved: each has its own host.
    let dashboardLabel: String?

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Update the Conduit notifier"),
            symbol: "arrow.down.circle",
            tint: .orange
        ) {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            NotificationSetupCommand(step: 1, title: AppLocalization.string("Update the notifier"), command: "hermes plugins update conduit_push")
            NotificationSetupCommand(step: 2, title: AppLocalization.string("Restart the gateway"), command: "hermes gateway restart")
        }
        .accessibilityIdentifier("settings.notifier-update")
    }

    private var detail: String {
        switch (dashboardLabel, status.version) {
        case (let label?, let version?):
            return AppLocalization.string("The notifier plugin on \(label) (version \(version)) is missing features Conduit uses, such as taking chats over from Hermes Desktop. Run these on that dashboard's host.")
        case (let label?, .none):
            return AppLocalization.string("The notifier plugin on \(label) is missing or out of date, so features like taking chats over from Hermes Desktop won't work. Run these on that dashboard's host.")
        case (.none, let version?):
            return AppLocalization.string("The notifier plugin on your Hermes host (version \(version)) is missing features Conduit uses, such as taking chats over from Hermes Desktop. Run these on the host.")
        case (.none, .none):
            return AppLocalization.string("The notifier plugin on your Hermes host is missing or out of date, so features like taking chats over from Hermes Desktop won't work. Run these on the host.")
        }
    }
}

private struct DeviceHapticsSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(Haptics.preferenceKey) private var enabled = true

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Haptic feedback"),
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
    @ObservedObject var appLanguage = AppLanguageStore.shared
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
            title: AppLocalization.string("When returning to Conduit"),
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
                .accessibilityHint(
                    surface == .sessions
                        ? AppLocalization.string("Conduit opens to the session list. Used if you dismiss it without choosing another conversation.")
                        : AppLocalization.string("Conduit opens to your conversation.")
                )
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
    @ObservedObject var appLanguage = AppLanguageStore.shared
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
        ConduitSettingsSection(title: AppLocalization.string("During a response"), symbol: BusyInputMode.steer.symbol, tint: .conduitAccent) {
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
                error = AppLocalization.string("Could not save this setting. Restored the previous choice.")
                saving = false
                return
            }
            saving = false
        }
    }
}

/// A custom menu picker matching the Chat settings selector style,
/// used by Model and Delegate model settings for visual consistency.
/// The settings picker row: the setting's name on the left and its current
/// value on the right ("Provider    OpenRouter"), the whole row opening the
/// menu. Every menu-style choice in Settings uses it, so a bare value never
/// floats on its own. Choice titles arrive localized.
struct ConduitMenuPicker<ID: Hashable, Label: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let label: Label
    let value: ID
    let choices: [(id: ID, title: String)]
    let onSelect: (ID) -> Void

    init(value: ID, choices: [(id: ID, title: String)], onSelect: @escaping (ID) -> Void, @ViewBuilder label: () -> Label) {
        self.value = value
        self.choices = choices
        self.onSelect = onSelect
        self.label = label()
    }

    private var displayedTitle: String {
        choices.first(where: { $0.id == value })?.title ?? (value as? String) ?? ""
    }

    private var valueText: Text {
        Text(displayedTitle.isEmpty ? AppLocalization.string("Default") : displayedTitle)
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary).accessibilityHidden(true)
    }

    var body: some View {
        Menu {
            ForEach(choices.indices, id: \.self) { index in
                let choice = choices[index]
                Button {
                    onSelect(choice.id)
                } label: {
                    if choice.id == value {
                        SwiftUI.Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: choice.title)
                    }
                }
            }
        } label: {
            Group {
                // Large text: the value goes under the name, as in
                // SettingsMetricRow, instead of squeezing beside it.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        label
                        HStack {
                            valueText
                            Spacer(minLength: 8)
                            chevron
                        }
                    }
                } else {
                    HStack {
                        label
                        Spacer(minLength: 8)
                        valueText.multilineTextAlignment(.trailing)
                        chevron
                    }
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6).frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .conduitGlassControl(cornerRadius: 14)
    }
}

private struct ProfileModelSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let load: () async -> ProfileModelDefaults?
    let save: (String, String, String) async -> Bool
    @State private var defaults: ProfileModelDefaults?
    @State private var provider = ""
    @State private var model = ""
    @State private var reasoning = "medium"
    @State private var saving = false
    @State private var error: String?

    private var models: [ModelInfo] { defaults?.providers.first(where: { $0.name == provider })?.models ?? [] }
    /// Keeps a saved model the catalog no longer lists visible instead of
    /// silently showing a different one.
    private var modelChoices: [(id: String, title: String)] {
        let listed = models.map { (id: $0.id, title: $0.label ?? $0.id) }
        return model.isEmpty || models.contains(where: { $0.id == model }) ? listed : [(id: model, title: model)] + listed
    }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Default model"), symbol: "cpu", tint: .conduitAccent) {
                Text("Select a provider first, then one of its available models. These defaults apply to new sessions in this profile.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let defaults, !defaults.providers.isEmpty {
                    ConduitMenuPicker(
                        value: provider,
                        choices: defaults.providers.map { (id: $0.name, title: $0.title) },
                        onSelect: chooseProvider
                    ) {
                        Text("Provider").foregroundStyle(.secondary)
                    }
                    ConduitMenuPicker(
                        value: model,
                        choices: modelChoices,
                        onSelect: { model = $0 }
                    ) {
                        Text("Model").foregroundStyle(.secondary)
                    }
                    .disabled(modelChoices.isEmpty)
                } else {
                    ProgressView("Loading available models…")
                }
            }
            ConduitSettingsSection(title: AppLocalization.string("Reasoning"), symbol: "brain.head.profile", tint: .conduitAura) {
                ConduitMenuPicker(
                    value: reasoning,
                    choices: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].map { (id: $0, title: $0.capitalized) },
                    onSelect: { reasoning = $0 }
                ) {
                    Text("Default reasoning").foregroundStyle(.secondary)
                }
            }
            Button { persist() } label: { Label(saving ? AppLocalization.string("Saving…") : AppLocalization.string("Save model defaults"), systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 46) }
                .disabled(saving || provider.isEmpty || model.isEmpty).conduitGlassControl(cornerRadius: 17, tint: .conduitAccent.opacity(0.18))
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Model")
        .task { await reload() }
    }

    private func reload() async {
        guard let loaded = await load() else { return }
        defaults = loaded
        (provider, model) = loaded.selection
        reasoning = loaded.reasoning
    }
    /// Menus fire on the current item too; re-picking it must not swap out
    /// a saved model.
    private func chooseProvider(_ next: String) {
        guard next != provider else { return }
        provider = next
        model = defaults?.providers.first(where: { $0.name == next })?.models.first?.id ?? ""
    }
    private func persist() {
        Task {
            saving = true
            error = nil
            if !(await save(provider, model, reasoning)) {
                error = AppLocalization.string("Could not save model defaults.")
            }
            saving = false
        }
    }
}

private struct DelegationModelSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let loadModels: () async -> ProfileModelDefaults?
    let loadSettings: ([String]) async -> [String: ProfileSettingValue]
    let save: (String, ProfileSettingValue) async -> Bool
    @State private var defaults: ProfileModelDefaults?
    @State private var provider = ""
    @State private var model = ""
    @State private var reasoning = "medium"
    @State private var saving = false
    @State private var error: String?
    /// An inherited provider offers the chat row's models, since that is the
    /// provider the delegate will run on.
    private var models: [ModelInfo] {
        let row = provider.isEmpty
            ? defaults?.providers.first(where: \.isCurrent)
            : defaults?.providers.first(where: { $0.name == provider })
        return row?.models ?? []
    }
    /// A saved provider or model the catalog does not list stays visible
    /// instead of the picker silently showing a different one.
    private var providerChoices: [(id: String, title: String)] {
        let listed = (defaults?.providers ?? []).map { (id: $0.name, title: $0.title) }
        let unlisted = provider.isEmpty || listed.contains(where: { $0.id == provider }) ? [] : [(id: provider, title: provider)]
        return [(id: "", title: AppLocalization.string("Inherit chat provider"))] + unlisted + listed
    }
    private var modelChoices: [(id: String, title: String)] {
        let listed = models.map { (id: $0.id, title: $0.label ?? $0.id) }
        let unlisted = model.isEmpty || models.contains(where: { $0.id == model }) ? [] : [(id: model, title: model)]
        return [(id: "", title: AppLocalization.string("Inherit chat model"))] + unlisted + listed
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Delegate model"), symbol: "point.3.connected.trianglepath.dotted", tint: .conduitAccent) {
            Text("Leave both selections empty to inherit the chat model. Set a provider and model to route delegate agents separately.")
                .font(.footnote).foregroundStyle(.secondary)
            if let defaults, !defaults.providers.isEmpty {
                ConduitMenuPicker(
                    value: provider,
                    choices: providerChoices,
                    onSelect: chooseProvider
                ) {
                    Text("Delegate provider").foregroundStyle(.secondary)
                }
                if !provider.isEmpty || !model.isEmpty {
                    ConduitMenuPicker(
                        value: model,
                        choices: modelChoices,
                        onSelect: { model = $0 }
                    ) {
                        Text("Delegate model").foregroundStyle(.secondary)
                    }
                }
                ConduitMenuPicker(
                    value: reasoning,
                    choices: [(id: "", title: AppLocalization.string("Inherit chat reasoning"))] + ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"].map { (id: $0, title: $0.capitalized) },
                    onSelect: { reasoning = $0 }
                ) {
                    Text("Delegate reasoning").foregroundStyle(.secondary)
                }
            } else { ProgressView("Loading available models…") }
            Button { persist() } label: { Label(saving ? AppLocalization.string("Saving…") : AppLocalization.string("Save delegate defaults"), systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 42) }
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
        let configuredModel = settings["delegation.model"]?.textValue ?? ""
        (provider, model) = loaded?.delegateSelection(provider: configuredProvider, model: configuredModel)
            ?? (configuredProvider, configuredModel)
        reasoning = settings["delegation.reasoning_effort"]?.textValue ?? ""
    }
    private func chooseProvider(_ next: String) {
        guard next != provider else { return }
        provider = next
        model = next.isEmpty ? "" : defaults?.providers.first(where: { $0.name == next })?.models.first?.id ?? ""
    }
    private func persist() {
        Task {
            saving = true
            error = nil
            let providerSaved = await save("delegation.provider", .text(provider))
            let modelSaved = providerSaved ? await save("delegation.model", .text(model)) : false
            let reasoningSaved = modelSaved ? await save("delegation.reasoning_effort", .text(reasoning)) : false
            if !reasoningSaved { error = AppLocalization.string("Could not save delegate defaults.") }
            saving = false
        }
    }
}

private struct MemorySettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let load: ([String]) async -> [String: ProfileSettingValue]
    let save: (String, ProfileSettingValue) async -> Bool
    let loadOptions: () async -> ProfileConfigOptions
    let loadModels: () async -> ProfileModelDefaults?
    let fields: [ProfileSettingField]
    @State private var options = ProfileConfigOptions()

    var body: some View {
        ProfileConfigSettingsPage(
            title: AppLocalization.string("Memory & delegation"),
            subtitle: AppLocalization.string("Long-term context and delegate-agent defaults."),
            fields: fields,
            load: load,
            save: save,
            optionOverrides: ["memory.provider": options.memoryProviders, "context.engine": options.contextEngines],
            trailingSection: AnyView(DelegationModelSettings(loadModels: loadModels, loadSettings: load, save: save))
        )
        .task { options = await loadOptions() }
    }
}

/// 服务器配置值 → 英文显示名（走 String Catalog 翻译）；未收录的动态值原样显示。
/// 值本身绝不能翻译：它们会原样写回 Hermes 配置。
enum ProfileConfigValueDisplay {
    static let optionValueDisplay: [String: [String: String]] = [
        "approvals.mode": ["manual": "Manual", "smart": "Smart", "off": "YOLO mode"],
        "code_execution.mode": ["project": "Project", "strict": "Strict"],
        "agent.image_input_mode": ["auto": "Automatic", "native": "Native images", "text": "Text only"],
        "display.personality": [
            "": "Default", "helpful": "Helpful", "concise": "Concise", "technical": "Technical",
            "creative": "Creative", "teacher": "Teacher", "kawaii": "Kawaii", "catgirl": "Catgirl",
            "pirate": "Pirate", "shakespeare": "Shakespeare", "surfer": "Surfer", "noir": "Noir",
            "uwu": "uwu", "philosopher": "Philosopher", "hype": "Hype",
        ],
    ]

    static func label(forFieldKey key: String, _ value: String) -> String {
        if value.isEmpty { return AppLocalization.string("Default") }
        if let mapped = optionValueDisplay[key]?[value] {
            return AppLocalization.string(String.LocalizationValue(mapped))
        }
        return value
    }
}

struct ProfileConfigSettingsPage: View {
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
                let displayedValue = selectedValue
                Menu {
                    ForEach(choices, id: \.self) { option in
                        Button(ProfileConfigValueDisplay.label(forFieldKey: field.key, option)) { save(field, value: .text(option)) }
                    }
                } label: {
                    HStack { Text(ProfileConfigValueDisplay.label(forFieldKey: field.key, displayedValue)); Spacer(); Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary) }
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 42)
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
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 42)
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
        AdaptiveStack(spacing: 8) {
            TextField(field.label, text: Binding(get: { drafts[field.key] ?? textValue(field.key, defaultValue: defaultValue) }, set: { drafts[field.key] = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
                .padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 42).conduitGlassSurface(cornerRadius: 14)
            Button("Save") {
                let raw = drafts[field.key] ?? textValue(field.key, defaultValue: defaultValue)
                if case .number = field.control, let number = Double(raw) { save(field, value: .number(number)) }
                else if case .number = field.control { error = AppLocalization.string("Enter a valid number for \(field.label).") }
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
                error = AppLocalization.string("Could not save \(field.label).")
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
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let snapshot: SettingsSnapshot
    let reconnect: () async -> Bool
    let disconnect: () -> Void
    let close: () -> Void
    let saveCloudflareAccess: (String, String) -> Void
    let removeCloudflareAccess: () -> Void
    let saveCustomHeaders: ([CustomHeader]) -> Void
    @State private var customHeaders: [CustomHeader]
    @State private var showCustomHeaders = false
    @State private var connected: Bool
    @State private var reconnecting = false
    @State private var cloudflareEnabled: Bool
    @State private var clientID: String
    @State private var clientSecret = ""
    @State private var confirmingRestart = false

    init(snapshot: SettingsSnapshot, reconnect: @escaping () async -> Bool, disconnect: @escaping () -> Void, close: @escaping () -> Void, saveCloudflareAccess: @escaping (String, String) -> Void, removeCloudflareAccess: @escaping () -> Void, customHeaders: [CustomHeader], saveCustomHeaders: @escaping ([CustomHeader]) -> Void) {
        self.snapshot = snapshot; self.reconnect = reconnect; self.disconnect = disconnect; self.close = close
        self.saveCloudflareAccess = saveCloudflareAccess; self.removeCloudflareAccess = removeCloudflareAccess
        self.saveCustomHeaders = saveCustomHeaders
        _customHeaders = State(initialValue: customHeaders)
        _connected = State(initialValue: snapshot.isConnected)
        _cloudflareEnabled = State(initialValue: snapshot.cloudflareAccess != nil)
        _clientID = State(initialValue: snapshot.cloudflareAccess?.clientID ?? "")
    }
    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Connection"), symbol: "radio", tint: .conduitAura) {
                SettingsMetricRow(label: AppLocalization.string("Server"), value: snapshot.server ?? "—", lineLimit: 1)
                SettingsMetricRow(label: AppLocalization.string("Status"), value: connected ? AppLocalization.string("Connected") : AppLocalization.string("Disconnected"), valueColor: connected ? .green : .red, statusDot: connected ? .green : .red)
                Button { Task { reconnecting = true; connected = await reconnect(); reconnecting = false } } label: { Label(reconnecting ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Reconnect"), systemImage: "arrow.clockwise").frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 44) }
                    .disabled(reconnecting).conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.12))
                Button { confirmingRestart = true } label: { Label("Restart Gateway", systemImage: "restart").frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 44) }
                    .disabled(snapshot.server == nil || !appState.canRestartGateway)
                    .conduitGlassControl(cornerRadius: 16, tint: .orange.opacity(0.12))
                    .accessibilityIdentifier("settings.gateway.restart")
                GatewayRestartStatusView()
                Text("Reconnect only reconnects Conduit. Restart Gateway restarts Hermes' gateway on your host.")
                    .font(.footnote).foregroundStyle(.secondary)
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
            ConduitSettingsSection(title: AppLocalization.string("Extra headers"), symbol: "list.bullet.rectangle", tint: .conduitAccent) {
                Text(AppLocalization.string("For reverse proxies such as Pangolin, Traefik, or nginx that check a header. Sent only to this server, over HTTPS."))
                    .font(.footnote).foregroundStyle(.secondary)
                let configured = CustomHeaderPolicy.sendable(customHeaders)
                ForEach(configured) { header in
                    SettingsMetricRow(label: header.name, value: "••••••", lineLimit: 1)
                }
                Button(configured.isEmpty ? AppLocalization.string("Add headers") : AppLocalization.string("Edit headers")) { showCustomHeaders = true }
                    .disabled(snapshot.server == nil)
                    .accessibilityIdentifier("gateway.extra-headers")
                Text(AppLocalization.string("Reconnect after changing them."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { disconnect(); close() } label: { Label(AppLocalization.string("Sign Out of This Dashboard"), systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 48) }
                .conduitGlassControl(cornerRadius: 18, tint: .red.opacity(0.18))
        }
        .navigationTitle("Gateway")
        .gatewayRestartConfirmation(isPresented: $confirmingRestart)
        .sheet(isPresented: $showCustomHeaders) {
            CustomHeadersEditorSheet(serverURL: snapshot.server ?? "", headers: customHeaders) { headers in
                saveCustomHeaders(headers)
                customHeaders = headers.filter { !$0.trimmedName.isEmpty || !$0.value.isEmpty }
            }
        }
    }
}

private struct AppearanceSettingsDetail: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let theme: ThemePreference
    let saveTheme: (ThemePreference) -> Void
    @AppStorage("conduit.ipadPersistentSidebar") private var iPadPersistentSidebar = false
    @State private var selected: ThemePreference
    @State private var isChangingIcon = false
    init(theme: ThemePreference, saveTheme: @escaping (ThemePreference) -> Void) { self.theme = theme; self.saveTheme = saveTheme; _selected = State(initialValue: theme) }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Theme"), symbol: "circle.lefthalf.filled", tint: .conduitAccent) {
                Text("Choose how Conduit appears across this device.").font(.footnote).foregroundStyle(.secondary)
                Picker("Theme", selection: Binding(get: { selected }, set: {
                    selected = $0
                    Haptics.selection()
                    saveTheme($0)
                })) {
                    Text("Dark").tag(ThemePreference.dark); Text("Light").tag(ThemePreference.light); Text("System").tag(ThemePreference.system)
                }.pickerStyle(.segmented)
            }
            ConduitSettingsSection(title: AppLocalization.string("App language"), symbol: "globe", tint: .conduitAccent) {
                Text("Choose the language Conduit’s interface uses. Speech, transcription, and provider language settings are unaffected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // System Default plus two languages fit a segmented control;
                // more languages get the settings menu row.
                if AppLanguage.selectable.count <= 3 {
                    Picker("App language", selection: Binding(get: { appLanguage.selection }, set: {
                        Haptics.selection()
                        appLanguage.select($0)
                    })) {
                        ForEach(AppLanguage.selectable) { language in
                            Text(verbatim: language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    ConduitMenuPicker(
                        value: appLanguage.selection,
                        choices: AppLanguage.selectable.map { (id: $0, title: $0.displayName) },
                        onSelect: { language in
                            Haptics.selection()
                            appLanguage.select(language)
                        }
                    ) {
                        Text("Language").foregroundStyle(.secondary)
                    }
                }
            }
            ConduitSettingsSection(title: AppLocalization.string("App icon"), symbol: "app.badge", tint: .conduitAura) {
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
                            // The whole tile selects the icon: the tile's
                            // padding and the space beside the title are part
                            // of the hit region by declaration.
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isChangingIcon)
                        .accessibilityLabel("Use \(choice.title.lowercased()) app icon")
                    }
                }
            }

            if isPad {
                ConduitSettingsSection(title: AppLocalization.string("Layout"), symbol: "sidebar.left", tint: .conduitAura) {
                    Toggle("Persistent session sidebar", isOn: $iPadPersistentSidebar)
                        .tint(.conduitAccent)
                    Text("Keep Sessions, Cron, and Kanban visible beside the current conversation when the window is wide enough.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Appearance")
    }
}

private struct NotificationsSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject private var notifications = PushNotificationService.shared
    @EnvironmentObject private var appState: AppState
    @AppStorage(PushNotificationService.relayURLDefaultsKey) private var customRelayURL: String = ""
    // Seeded from the saved value so the first render doesn't read as an
    // unsaved edit (and flash Save or the re-pair warning).
    @State private var relayDraft = UserDefaults.standard.string(forKey: PushNotificationService.relayURLDefaultsKey) ?? ""
    @State private var relayDraftInvalid = false
    /// Starts true so the first render, before the check's task runs,
    /// reads as checking rather than as a failure.
    @State private var checkingNotifierPlugin = true

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var relayDraftIsUnsaved: Bool {
        trimmed(relayDraft) != trimmed(customRelayURL)
    }

    private func saveRelay(_ value: String) {
        // Return in the field reaches here too, so this mirrors the
        // disabled buttons: never start a second move mid-move.
        guard !notifications.isWorking else { return }
        let value = trimmed(value)
        guard PushNotificationService.isValidRelayInput(value) else {
            relayDraftInvalid = true
            Haptics.error()
            return
        }
        relayDraftInvalid = false
        relayDraft = value
        if value != customRelayURL {
            customRelayURL = value
            Haptics.light()
        }
        // Runs even when the value is unchanged, so a move that failed
        // earlier can be retried.
        Task { await notifications.applyRelayChange() }
    }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("This iPhone"), symbol: "bell.badge", tint: .conduitAura) {
                SettingsMetricRow(
                    label: AppLocalization.string("Status"),
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
                        notifications.isWorking ? AppLocalization.string("Updating…") : (notifications.isEnabled ? AppLocalization.string("Turn off notifications") : AppLocalization.string("Enable notifications")),
                        systemImage: notifications.isEnabled ? "bell.slash" : "bell.badge.fill"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6).frame(minHeight: 48)
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
                ConduitSettingsSection(title: AppLocalization.string("Notify me when"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
                    // The relay keeps one set of preferences per iPhone.
                    if appState.savedDashboardRegistry.dashboards.count > 1 {
                        Text(AppLocalization.string("These apply to every dashboard paired with this iPhone."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    notificationToggle(AppLocalization.string("Approval needed"), detail: AppLocalization.string("A tool is waiting for approval"), keyPath: \.approvalNeeded)
                    notificationToggle(AppLocalization.string("Input needed"), detail: AppLocalization.string("Hermes needs your answer"), keyPath: \.inputNeeded)
                    notificationToggle(AppLocalization.string("Response ready"), detail: AppLocalization.string("An active turn finishes"), keyPath: \.responseReady)
                    notificationToggle(AppLocalization.string("Turn failed"), detail: AppLocalization.string("A turn stops with an error"), keyPath: \.turnFailed)
                    notificationToggle(AppLocalization.string("Background task finished"), detail: AppLocalization.string("A delegated agent completes"), keyPath: \.backgroundTaskFinished)
                    notificationToggle(AppLocalization.string("Approval & input sound"), detail: AppLocalization.string("Play a sound when Hermes is waiting on you"), keyPath: \.attentionSound)
                    notificationToggle(AppLocalization.string("Completion sound"), detail: AppLocalization.string("Play a sound when a turn or task finishes"), keyPath: \.completionSound)
                    notificationToggle(AppLocalization.string("Show previews"), detail: AppLocalization.string("Include response text in notifications"), keyPath: \.showPreviews)
                    notificationToggle(AppLocalization.string("Approval cards in pushes"), detail: AppLocalization.string("Include approval details so cards work from notifications. Disable for maximum privacy."), keyPath: \.decisionCards)
                }

                // Everything here is the ACTIVE dashboard's: its host's
                // notifier and its pairings. Other dashboards' pairings
                // share this iPhone's relay list but never stand in for it.
                ConduitSettingsSection(title: AppLocalization.string("Compatibility"), symbol: "checkmark.seal", tint: .conduitAura) {
                    if appState.savedDashboardRegistry.dashboards.count > 1, let label = appState.savedDashboardRegistry.activeDashboardLabel {
                        Text("Showing \(label). Switch dashboards to check another one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    notifierPluginRow
                    if appState.notifierPlugin.needsUpdate {
                        NotificationSetupCommand(step: 1, title: AppLocalization.string("Update the notifier"), command: "hermes plugins update conduit_push")
                        NotificationSetupCommand(step: 2, title: AppLocalization.string("Restart the gateway"), command: "hermes gateway restart")
                    }
                    if notifications.isFetchingMeta {
                        Text("Checking compatibility…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let meta = notifications.relayMeta {
                        compatibilityRow(
                            title: AppLocalization.string("Push relay"),
                            version: meta.version,
                            mark: meta.supportsDecisionCards ? .supported : .updateNeeded,
                            detail: meta.supportsDecisionCards
                                ? AppLocalization.string("Supports decision cards")
                                : AppLocalization.string("Decision cards need a relay update")
                        )
                        let pairings = NotificationDashboardPairings(
                            gateways: meta.gateways,
                            activeDashboardID: appState.activeDashboardID,
                            savedDashboardIDs: appState.savedDashboardRegistry.dashboards.map(\.id)
                        )
                        // Without a selected dashboard there is nothing to
                        // pair yet (and `pairings` is empty); the pairing
                        // section says to connect.
                        if pairings.thisDashboard.isEmpty, appState.activeDashboardID != nil {
                            compatibilityRow(
                                title: AppLocalization.string("Not paired"),
                                version: nil,
                                mark: .actionNeeded,
                                detail: AppLocalization.string("Notifications from this dashboard don't reach this iPhone yet. Create a pairing code below.")
                            )
                        }
                        ForEach(pairings.thisDashboard) { gateway in
                            gatewayRow(gateway)
                        }
                        // One host, one set of commands, however many of its
                        // pairings are behind. The host row above already
                        // offers them when the plugin itself reports it is
                        // behind.
                        if !appState.notifierPlugin.needsUpdate,
                           pairings.thisDashboard.contains(where: Self.isOutdated) {
                            NotificationSetupCommand(step: 1, title: AppLocalization.string("Update the notifier"), command: "hermes plugins update conduit_push")
                            NotificationSetupCommand(step: 2, title: AppLocalization.string("Restart the gateway"), command: "hermes gateway restart")
                        }
                        ForEach(pairings.unscoped) { gateway in
                            compatibilityRow(
                                title: gateway.name,
                                version: gateway.pluginVersion,
                                mark: .actionNeeded,
                                detail: AppLocalization.string("Paired before Conduit supported several dashboards, so its notifications can't be opened. Pair it again from the dashboard it belongs to.")
                            )
                        }
                        if pairings.otherDashboardsCount > 0 {
                            Text("\(pairings.otherDashboardsCount) more pairings belong to your other dashboards.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if pairings.unrecognizedCount > 0 {
                            Text("\(pairings.unrecognizedCount) more pairings don't match any dashboard saved on this iPhone.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Compatibility unknown. Your relay predates version reporting; decision cards may not be available until it updates.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .task {
                    // A launch before first unlock couldn't read the keys.
                    notifications.refreshEncryptionState()
                    await notifications.refreshMeta()
                }
                // Asked again on every visit and dashboard switch: the
                // connect-time check can miss (bridge still loading), and
                // the plugin may have been updated since.
                .task(id: appState.activeDashboardID) {
                    checkingNotifierPlugin = true
                    await appState.refreshNotifierPluginStatus()
                    // A switch mid-check cancels this one; the new check
                    // owns the flag.
                    if !Task.isCancelled { checkingNotifierPlugin = false }
                }

                ConduitSettingsSection(title: AppLocalization.string("Connect a Hermes profile"), symbol: "link.badge.plus", tint: .conduitAura) {
                    Text("Install the notifier once on each gateway, then create a short-lived pairing code here for each Hermes dashboard you want to reach.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NotificationSetupCommand(step: 1, title: AppLocalization.string("Install the notifier"), command: "hermes plugins install kaishi00/hermes-conduit-notifier --enable")
                    NotificationSetupCommand(step: 2, title: AppLocalization.string("Restart the gateway"), command: "hermes gateway restart")
                    Button {
                        Task {
                            // Pairings are bound to the active dashboard
                            // (#148): pushes from the claimed gateway are
                            // stamped with its identity, so server A can
                            // never act against server B. The action is
                            // disabled without an active dashboard — Conduit
                            // never creates a new unscoped pairing.
                            guard let dashboardID = appState.activeDashboardID else { return }
                            await notifications.createPairingCode(dashboardID: dashboardID)
                            notifications.pairingCode == nil ? Haptics.error() : Haptics.success()
                        }
                    } label: {
                        Label(notifications.isWorking ? AppLocalization.string("Creating code…") : AppLocalization.string("Create pairing code"), systemImage: "number")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6).frame(minHeight: 46)
                    }
                    .disabled(notifications.isWorking || appState.activeDashboardID == nil)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.16))
                    if appState.activeDashboardID == nil {
                        Text("Connect to a dashboard before creating a pairing code.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let code = notifications.pairingCode {
                        NotificationSetupCommand(step: 3, title: AppLocalization.string("Pair the active dashboard"), command: "hermes conduit-push pair \(code)")
                        if let expiry = notifications.pairingExpiry {
                            Text("This code expires \(expiry).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ConduitSettingsSection(title: AppLocalization.string("Verify pairing"), symbol: "checkmark.seal", tint: .conduitAccent) {
                    Text("After pairing, run these on the same Hermes profile. First confirm the local relay credential, then send a test. You should receive the test notification on this iPhone within a few seconds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NotificationSetupCommand(step: 4, title: AppLocalization.string("Check pairing status"), command: "hermes conduit-push status")
                    NotificationSetupCommand(step: 5, title: AppLocalization.string("Send a test notification"), command: "hermes conduit-push test")
                }
                ConduitSettingsSection(title: AppLocalization.string("How it works"), symbol: "hand.raised", tint: .conduitAura) {
                    Text("The notifier receives a revocable credential for this phone. Your gateway never needs the phone’s push token, and you can turn notifications off here at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // Always visible (#255): an unreachable custom relay makes
            // enabling fail, so the field must stay editable while
            // notifications are off — otherwise there is no way back.
            ConduitSettingsSection(title: AppLocalization.string("Push relay"), symbol: "server.rack", tint: .conduitAura) {
                // Edits stay a draft until saved, so a half-typed URL never
                // becomes the relay; saving moves an active registration.
                TextField("https://push.milim.dev", text: $relayDraft)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .padding(.vertical, 4)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .accessibilityLabel(AppLocalization.string("Push relay URL"))
                    .disabled(notifications.isWorking)
                    .onSubmit { saveRelay(relayDraft) }
                    .onChange(of: relayDraft) { _, _ in relayDraftInvalid = false }
                if relayDraftInvalid {
                    Label(AppLocalization.string("Enter a full HTTPS relay URL, like https://push.example.com."), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text("Leave blank to use the default relay. A relay you run yourself only works with a Conduit build signed with your own Apple developer account, because Apple only delivers this app's notifications through its developer's key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if notifications.isEnabled && relayDraftIsUnsaved {
                    Text("Saving moves this iPhone to the new relay. You'll need to pair each Hermes profile again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // A failed move leaves the phone on the old relay with the
                // new one saved; the same button retries it.
                if relayDraftIsUnsaved || notifications.relayMovePending {
                    Button {
                        saveRelay(relayDraft)
                    } label: {
                        Label(
                            relayDraftIsUnsaved ? AppLocalization.string("Save relay") : AppLocalization.string("Retry relay move"),
                            systemImage: relayDraftIsUnsaved ? "checkmark" : "arrow.clockwise"
                        )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6).frame(minHeight: 44)
                    }
                    .disabled(notifications.isWorking)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.16))
                }
                // Raw, not trimmed: a whitespace-only value saved by an
                // older build can still be cleared.
                if !customRelayURL.isEmpty {
                    Button {
                        saveRelay("")
                    } label: {
                        Label(AppLocalization.string("Reset to default relay"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6).frame(minHeight: 44)
                    }
                    .disabled(notifications.isWorking)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.16))
                }
                if let notice = notifications.relayNotice {
                    Label(notice, systemImage: "info.circle.fill")
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

    /// The active dashboard's own notifier, asked through its host's
    /// capabilities route. Unlike the relay's gateway rows (the version the
    /// last push carried), this covers every feature Conduit uses.
    @ViewBuilder
    private var notifierPluginRow: some View {
        let status = appState.notifierPlugin
        let title = AppLocalization.string("Notifier plugin")
        switch status.state {
        case .unknown:
            compatibilityRow(
                title: title,
                version: nil,
                mark: .unknown,
                detail: checkingNotifierPlugin
                    ? AppLocalization.string("Checking this dashboard's notifier…")
                    : appState.isConnected
                        ? AppLocalization.string("Couldn't reach this dashboard's notifier. Open this page again to retry.")
                        : AppLocalization.string("Connect to this dashboard to check its notifier.")
            )
        case .predatesCapabilities:
            compatibilityRow(
                title: title,
                version: nil,
                mark: .updateNeeded,
                detail: AppLocalization.string("Missing or out of date on this dashboard's host, so features like taking chats over from Hermes Desktop won't work.")
            )
        case .reported:
            compatibilityRow(
                title: title,
                version: status.version,
                mark: status.needsUpdate ? .updateNeeded : .supported,
                detail: status.needsUpdate
                    ? AppLocalization.string("Update available. This dashboard's notifier is missing features Conduit uses.")
                    : AppLocalization.string("Up to date on this dashboard's host")
            )
        }
    }

    /// The update prompt requires evidence of oldness: either a
    /// reported-but-old version, or events that never carried one (pre-0.2).
    /// A gateway that has sent nothing is only "waiting".
    private static func isOutdated(_ gateway: RelayMetaInfo.Gateway) -> Bool {
        gateway.hasSentEventsButNeverReported
            || (gateway.pluginVersion != nil && !(gateway.supportsApprovalCards && gateway.supportsClarifyCards))
    }

    /// One relay pairing of the active dashboard: whether its notifier
    /// sends decision cards, from the plugin version its last push carried.
    @ViewBuilder
    private func gatewayRow(_ gateway: RelayMetaInfo.Gateway) -> some View {
        let isSupported = gateway.supportsApprovalCards && gateway.supportsClarifyCards
        let isOutdated = Self.isOutdated(gateway)
        compatibilityRow(
            title: gateway.name,
            version: gateway.pluginVersion,
            mark: isSupported ? .supported : (isOutdated ? .updateNeeded : .unknown),
            detail: isSupported
                ? AppLocalization.string("Notifier supports approval and clarify cards")
                : gateway.hasSentEventsButNeverReported
                    ? AppLocalization.string("This profile's notifier predates decision cards — update it to receive them")
                    : gateway.pluginVersion == nil
                        ? AppLocalization.string("Waiting for the first notification from this profile")
                        : AppLocalization.string("Notifier update available — approval and clarify cards need a newer plugin")
        )
        // #431: whether this pairing's notifications are sealed so the relay
        // can't read them. Keys are set up automatically over the dashboard
        // connection once the host's notifier supports it.
        if notifications.encryptedGatewayIDs.contains(gateway.id) {
            Label(AppLocalization.string("End-to-end encrypted"), systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if NotificationSharedSettings.keysProvisioned, notifications.encryptedGatewayIDs.isEmpty {
            // Keys were stored but none can be read (locked, or lost and
            // being set up again): every plaintext push shows generic text.
            Label(AppLocalization.string("Setting up encryption again, so notifications from this host show only generic text for now."), systemImage: "lock.open")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if NotificationSharedSettings.keysProvisioned,
                  !NotificationSharedSettings.knownGatewayIDs.contains(gateway.id) {
            // Paired after encryption went on elsewhere: its plaintext can't
            // be told from a relay's forgery, so it only shows generic text.
            // These shared settings aren't observable; the row re-renders
            // because every change to them also changes encryptedGatewayIDs
            // or relayMeta.
            Label(AppLocalization.string("Not end-to-end encrypted, so notifications from this host show only generic text and don't open the chat. Update this host's notifier to turn encryption on."), systemImage: "lock.open")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Label(AppLocalization.string("Not end-to-end encrypted yet, so the relay can read these notifications. Conduit turns encryption on by itself once notifications are on and this host's notifier supports it."), systemImage: "lock.open")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private enum CompatibilityMark {
        case supported
        case updateNeeded
        case actionNeeded
        case unknown
    }

    @ViewBuilder
    private func compatibilityRow(
        title: String,
        version: String?,
        mark: CompatibilityMark,
        detail: String
    ) -> some View {
        HStack(spacing: 10) {
            Group {
                switch mark {
                case .supported:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(AppLocalization.string("Supported"))
                case .updateNeeded:
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(AppLocalization.string("Update needed"))
                case .actionNeeded:
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(AppLocalization.string("Action needed"))
                case .unknown:
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(AppLocalization.string("Unknown"))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    if let version {
                        Text("v\(version)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail)
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

struct NotificationSetupCommand: View {
    let step: Int
    let title: String
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(step)")
                    .font(.caption.weight(.bold))
                    .conduitFixedGlyph()
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
                // Copying is the card's whole purpose: the card is the tap
                // target, not just the command text inside it.
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .conduitGlassSurface(cornerRadius: 14, tint: .conduitAccent.opacity(0.08))
            .accessibilityLabel("Copy \(title) command")
        }
        .padding(.top, 4)
    }
}

private struct AboutSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
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
                SettingsMetricRow(label: AppLocalization.string("Active profile"), value: profile.capitalized)
                SettingsMetricRow(label: AppLocalization.string("Version"), value: ConduitAppVersion.display)
            }
            ConduitSettingsSection(title: AppLocalization.string("Data handling"), symbol: "hand.raised", tint: .conduitAura) {
                Text("Conduit connects to the dashboard and gateway you configure. Conversations and attachments are handled by that Hermes installation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ConduitSettingsSection(title: AppLocalization.string("Links"), symbol: "link", tint: .conduitAccent) {
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
            ConduitSettingsSection(title: AppLocalization.string("Disclaimer"), symbol: "info.circle", tint: .conduitAura) {
                Text("Hermes Conduit is an independent client and is not affiliated with or endorsed by Nous Research. © 2026 Milim.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("About & privacy")
    }

}

struct SettingsDetailContainer<Content: View>: View {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Large text: the value goes under its label instead of squeezing
        // into a sliver beside it.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    statusIndicator
                    Text(value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(valueColor)
                        .lineLimit(lineLimit.map { $0 + 1 })
                        .truncationMode(.middle)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                statusIndicator
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(valueColor)
                    .lineLimit(lineLimit)
                    .multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if let statusDot {
            Circle()
                .fill(statusDot)
                .frame(width: 7, height: 7)
                .shadow(color: statusDot.opacity(0.7), radius: 4)
        }
    }
}
