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
            // V2: laid out as a settings page, its cards on the profile's
            // glow and fading under the bar; compact to fit the half sheet.
            SettingsDetailContainer(compact: true) {
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
                        ContextWindowBar(
                            segments: segments,
                            capacity: Double(max(Int(appState.runtime.contextMax), breakdown?.contextMax ?? 0)),
                            fallbackFraction: appState.runtime.contextPercent / 100
                        )
                        .accessibilityElement()
                        .accessibilityLabel(Text("Window usage"))
                        .accessibilityValue(Text("\(String(Int(appState.runtime.contextPercent.rounded())))%"))
                    }
                    .padding(.top, 4)
                }

                if breakdown != nil {
                    ConduitSettingsSection(title: AppLocalization.string("Breakdown"), symbol: "chart.pie", tint: .conduitAccent) {
                        ForEach(segments) { category in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(category.color)
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
            .navigationTitle("Context")
        }
        // The open chat's glow: a Bot Chat's is its bot's.
        .environment(\.settingsGlowTint, appState.profileGlowTint(appState.conversationIdentityProfile))
        .task { await loadBreakdown() }
    }

    private func loadBreakdown() async {
        // Only the open chat's breakdown, and only while it's still open.
        // Context detail is supplementary to the live ring in the composer.
        guard let loaded = await appState.refreshContextUsage() else { return }
        breakdown = loaded
    }

    /// The breakdown's categories with the color each takes in the bar and
    /// beside its row. Hermes's own colors only when each is one Conduit
    /// knows and no two share one; otherwise (it often names one for all,
    /// or names Conduit doesn't map) they take the palette in turn, so the
    /// categories never all come out amber.
    private var segments: [ContextWindowBar.Segment] {
        guard let categories = breakdown?.categories else { return [] }
        let named = categories.map { colorFor($0.color) }
        let useNamed = named.allSatisfy { $0 != nil }
            && Set(categories.map { $0.color.lowercased() }).count == categories.count
        return categories.enumerated().map { index, category in
            ContextWindowBar.Segment(
                id: category.id,
                label: category.label,
                tokens: category.tokens,
                color: (useNamed ? named[index] : nil)
                    ?? ContextWindowBar.palette[index % ContextWindowBar.palette.count]
            )
        }
    }

    private func colorFor(_ name: String) -> Color? {
        switch name.lowercased() {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "purple": return .purple
        case "pink": return .pink
        case "cyan": return .cyan
        case "amber", "yellow": return .yellow
        default: return nil
        }
    }
}

/// The context window as one bar: a segment per category, sized by its
/// share of the capacity, on a quiet track for what is still free. Before
/// the breakdown loads, one gold segment for the used share.
struct ContextWindowBar: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let tokens: Int
        let color: Color
    }

    static let palette: [Color] = [.conduitAccent, .conduitAura, .teal, .pink, .blue, .green, .orange, .purple]

    let segments: [Segment]
    let capacity: Double
    let fallbackFraction: Double

    var body: some View {
        GeometryReader { proxy in
            let shown = segments.filter { $0.tokens > 0 }
            let total = max(capacity, Double(shown.reduce(0) { $0 + $1.tokens }), 1)
            HStack(spacing: 2) {
                if shown.isEmpty {
                    Rectangle()
                        .fill(Color.conduitAccent)
                        .frame(width: proxy.size.width * min(max(fallbackFraction, 0), 1))
                } else {
                    ForEach(shown) { segment in
                        Rectangle()
                            .fill(segment.color)
                            // A sliver stays visible however small its share.
                            .frame(width: max(3, (proxy.size.width - CGFloat(shown.count) * 2) * Double(segment.tokens) / total))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.25), value: segments.map(\.tokens))
    }
}

// MARK: - Settings

struct SettingsSnapshot: Identifiable {
    let id = UUID()
    let server: String?
    let isConnected: Bool
    let profile: String
    let defaultProfileName: String
    /// The active profile as people see it: Hermes' display name when set.
    let profileDisplayName: String
    let theme: ThemePreference
    let busyInputMode: BusyInputMode
    let chatResumeBehavior: ChatResumeBehavior
    let chatReturnSurface: ChatReturnSurface
    let displayPreferences: ProfileDisplayPreferences
    let cloudflareAccess: CloudflareAccessCredentials?
    /// The page Settings opens at, for a link (`conduit://settings/calls`).
    var opensAt: ConduitAppLink.SettingsLink?
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
            Text("Touch and hold the send button to choose another way for one message.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ConduitGlassGroup(spacing: 10) {
                AdaptiveStack(spacing: 10) {
                    busyModeChoice(.steer, symbol: BusyInputMode.steer.symbol, detail: AppLocalization.string("Guide safely"))
                    busyModeChoice(.queue, symbol: BusyInputMode.queue.symbol, detail: AppLocalization.string("Send next"))
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
            SettingsMetricRow(label: AppLocalization.string("Profile"), value: snapshot.profileDisplayName)
            SettingsMetricRow(label: AppLocalization.string("Version"), value: ConduitAppVersion.display)
        }
    }

    private var chatDisplaySection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Chat display"), symbol: "text.bubble", tint: .conduitAura) {
            Text("These choices follow the active workspace.")
                .font(.footnote)
                .foregroundStyle(.secondary)

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
    case profile, model, usage, chat, voice, hermesCalls, workspace, memory, advanced, capabilities, gateway, conduitPlugin, savedDashboards, appearance, notifications, syncedPreferences, health, location, phone, shortcutInbox, screenQuestion, about

    init(_ link: ConduitAppLink.SettingsLink) {
        switch link {
        case .calls: self = .hermesCalls
        case .voice: self = .voice
        case .plugin: self = .conduitPlugin
        case .health: self = .health
        case .location: self = .location
        case .phone: self = .phone
        }
    }
}

enum ProfileSettingControl {
    case toggle(defaultValue: Bool)
    case textToggle(onValue: String, offValue: String, defaultValue: Bool)
    case options([String], defaultValue: String)
    case labeledOptions([(value: String, label: String)], defaultValue: String)
    case text(defaultValue: String)
    case number(defaultValue: Double)
    /// One string per line, saved as a list.
    case stringList
    /// An IANA time zone name, blank for the server's local time
    /// (ProfileTimeZone): a text field with this iPhone's zone one tap away,
    /// checked before it is saved.
    case timeZone
}

struct ProfileSettingField: Identifiable {
    let key: String
    let label: String
    let help: String
    let control: ProfileSettingControl
    /// Shown only when the gateway's config schema has the key, so an older
    /// Hermes doesn't offer a setting it would ignore. The schema failing to
    /// load shows it anyway.
    var requiresSchema = false
    var id: String { key }

    /// The field as this gateway's schema describes it: nil when the schema
    /// lacks a key it requires, and an empty choice list filled from the
    /// schema's own choices.
    func resolved(with schema: ProfileConfigSchema) -> ProfileSettingField? {
        guard !schema.isEmpty else { return self }
        guard let entry = schema[key] else { return requiresSchema ? nil : self }
        if case .options(let options, let defaultValue) = control, options.isEmpty, !entry.options.isEmpty {
            return ProfileSettingField(key: key, label: label, help: help, control: .options(entry.options, defaultValue: defaultValue), requiresSchema: requiresSchema)
        }
        return self
    }
}

/// A titled card of settings on a ProfileConfigSettingsPage.
struct ProfileSettingSection: Identifiable {
    let title: String
    let symbol: String
    let fields: [ProfileSettingField]
    var id: String { title }
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
    let reconnect: () async -> Bool
    let disconnect: () -> Void
    /// V2's Settings tab: the home page shows this bar (the profile picker)
    /// instead of the sheet's title and close button, in V2's grouping.
    var homeHeader: AnyView? = nil

    @State private var path: [SettingsDestination] = []
    @State private var openedAtLink = false
    /// Counts main-model saves, so Fast mode's model-dependent choices
    /// reload for the new model.
    @State private var mainModelSaves = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            SettingsHome(snapshot: snapshot, path: $path, v2Layout: homeHeader != nil)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let homeHeader {
                        homeHeader
                    } else {
                        ConduitSheetHeader(title: AppLocalization.string("Settings"), close: { dismiss() })
                    }
                }
                // On a wide window every page keeps to a readable column.
                // Inside the stack: a margin outside it doesn't reach the
                // pages it hosts.
                .readableContentWidth(ReadableWidth.settings)
                // V2's Settings tab: each screen stops above the floating
                // tab bar and fades under it. Nothing in the sheet.
                .v2TabBarClearance()
                .navigationDestination(for: SettingsDestination.self) { destination in
                    destinationView(destination)
                        .readableContentWidth(ReadableWidth.settings)
                        .v2TabBarClearance()
                }
        }
        .preferredColorScheme(appState.themePreference.colorScheme)
        .onAppear {
            // A link's page is already open as the sheet comes up; Back
            // leads to the Settings home.
            guard !openedAtLink, let page = snapshot.opensAt else { return }
            openedAtLink = true
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { path = [SettingsDestination(page)] }
        }
        // V2's tab keeps this view (and its profile bar) across snapshots:
        // a new one, from a profile switch or a settings link, starts the
        // stack over, at the link's page if it has one.
        .onChange(of: snapshot.id) { _, _ in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { path = snapshot.opensAt.map { [SettingsDestination($0)] } ?? [] }
        }
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
            setListensOverOtherAudio: { appState.setWakeListensOverOtherAudio($0) },
            listenedPhrases: { appState.wakeListenedPhrases(replacing: $0, forProfile: profile) }
        )
    }

    @ViewBuilder
    private func destinationView(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .profile:
            ProfileSettingsDetail(
                profile: snapshot.profile,
                displayName: snapshot.profileDisplayName
            )
        case .model:
            ProfileConfigSettingsPage(
                title: AppLocalization.string("Model"),
                subtitle: "",
                fields: Self.modelFields,
                load: loadProfileSettings,
                save: persistProfileSetting,
                fieldsHeader: AppLocalization.string("Speed & limits"),
                leadingSection: AnyView(ProfileModelSettingsDetail(load: loadProfileModelDefaults, save: { provider, model, reasoning in
                    let saved = await persistProfileMainModel(provider, model, reasoning)
                    if saved { await MainActor.run { mainModelSaves += 1 } }
                    return saved
                })),
                trailingSection: AnyView(FallbackModelsSettings(
                    loadModels: loadProfileModelDefaults,
                    load: { await appState.loadProfileFallbackModels() },
                    save: { await appState.setProfileFallbackModels($0) }
                )),
                loadSchema: { await appState.loadProfileConfigSchema() },
                loadExtraOptions: {
                    await loadProfileModelDefaults()?.mainModelOffersUltrafast == true
                        ? ["agent.service_tier": ["ultrafast"]] : [:]
                },
                extraOptionsRefresh: mainModelSaves
            )
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
                loadOptions: loadProfileConfigOptions,
                loadSchema: { await appState.loadProfileConfigSchema() }
            )
        case .voice:
            if let bridge = appState.dashboardTicketBridge {
                // One decode per render, not one per seeded field.
                let voicePreferences = appState.activeProfileVoicePreferences
                VoiceSettingsRoute(
                    bridge: bridge,
                    profile: snapshot.profile,
                    profileParameter: { appState.notifierPlugin.dashboardProfileParameter },
                    profileName: appState.profileDisplayName(snapshot.profile),
                    conversationController: appState.voiceConversationController,
                    actions: VoiceSettingsActions(
                        runASRTest: { await appState.runVoiceASRTest() },
                        runTTSTest: { await appState.runVoiceTTSTest() }
                    ),
                    // The saved switch: while Conduit reconnects, voice isn't
                    // usable yet, but it wasn't turned off.
                    voiceEnabled: appState.activeProfileVoiceSwitch,
                    transcriptionMode: appState.voiceTranscriptionMode,
                    transcriptionModeChosen: voicePreferences.transcriptionMode != nil,
                    speechOutput: voicePreferences.speechOutput,
                    appleSpeechAvailability: appState.appleSpeechAvailability,
                    continuousConversation: appState.continuousConversationEnabled,
                    spokenStopPhrases: voicePreferences.resolvedSpokenStopPhrases,
                    spokenEndConversationPhrases: voicePreferences.resolvedSpokenEndConversationPhrases,
                    setVoiceEnabled: { enabled in
                        await appState.setVoiceEnabled(enabled)
                    },
                    setTranscriptionMode: { mode in
                        await appState.setVoiceTranscriptionMode(mode)
                    },
                    setSpeechOutput: { output in
                        appState.setVoiceSpeechOutput(output)
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
                                let status = try await appState.geminiLiveTokenClient.availability()
                                await MainActor.run { appState.noteWatchCallVoice(.geminiLive, ready: status.isAvailable) }
                                return .success(status)
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
                    qwenLive: GeminiLiveSettingsModel(
                        enabled: appState.isQwenLiveEnabled,
                        setEnabled: { appState.setQwenLiveEnabled($0) },
                        checkAvailability: {
                            do {
                                let status = try await appState.qwenLiveTokenClient.availability()
                                await MainActor.run { appState.noteWatchCallVoice(.qwenLive, ready: status.isAvailable) }
                                return .success(status)
                            } catch {
                                return .failure(error)
                            }
                        },
                        search: appState.qwenLiveSearchMode,
                        setSearch: { appState.setQwenLiveSearchMode($0) },
                        voice: appState.qwenLiveVoice,
                        setVoice: { appState.setQwenLiveVoice($0) },
                        memory: appState.qwenLiveMemoryEnabled,
                        setMemory: { appState.setQwenLiveMemoryEnabled($0) },
                        personality: appState.qwenLivePersonalityEnabled,
                        setPersonality: { appState.setQwenLivePersonalityEnabled($0) },
                        saveCalls: appState.voiceCallSavingEnabled,
                        setSaveCalls: { appState.setVoiceCallSavingEnabled($0) },
                        speakerBargeIn: appState.liveVoiceSpeakerBargeInEnabled,
                        setSpeakerBargeIn: { appState.setLiveVoiceSpeakerBargeInEnabled($0) },
                        provider: .qwenLive
                    ),
                    gptLive: GPTLiveSettingsModel(
                        enabled: appState.isGPTLiveEnabled,
                        setEnabled: { appState.setGPTLiveEnabled($0) },
                        checkAvailability: {
                            do {
                                // The path the picker shows, even while a call Hermes placed
                                // would start on the subscription.
                                let billing = await MainActor.run { appState.gptLiveBilling }
                                let status = try await appState.gptLiveClient.availability(billing: billing)
                                // The Watch's GPT-Live is always the subscription's: an API-key
                                // check says nothing about it.
                                await MainActor.run {
                                    if billing == .subscription {
                                        appState.noteWatchCallVoice(.gptLive, ready: status.isAvailable)
                                    }
                                }
                                return .success(status)
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
                        setSaveCalls: { appState.setVoiceCallSavingEnabled($0) },
                        billing: appState.gptLiveBilling,
                        setBilling: { appState.setGPTLiveBilling($0) },
                        apiVoice: appState.gptLiveAPIVoice,
                        setAPIVoice: { appState.setGPTLiveAPIVoice($0) },
                        apiMaxMinutes: appState.gptLiveAPIMaxMinutes,
                        setAPIMaxMinutes: { appState.setGPTLiveAPIMaxMinutes($0) },
                        apiHermesCalls: appState.gptLiveAPIHermesCalls,
                        setAPIHermesCalls: { appState.setGPTLiveAPIHermesCalls($0) }
                    ),
                    grokLive: GrokLiveSettingsModel(
                        enabled: appState.isGrokLiveEnabled,
                        setEnabled: { appState.setGrokLiveEnabled($0) },
                        checkAvailability: {
                            do {
                                let status = try await appState.grokLiveClient.availability()
                                await MainActor.run { appState.noteWatchCallVoice(.grokLive, ready: status.isAvailable) }
                                return .success(status)
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
                    localLive: LocalLiveSettingsModel(
                        enabled: appState.isLocalLiveEnabled,
                        setEnabled: { appState.setLocalLiveEnabled($0) },
                        agent: appState.isLocalLiveAgent,
                        setAgent: { appState.setLocalLiveAgent($0) }
                    ),
                    liveStyle: appState.isQwenLiveEnabled || appState.isGeminiLiveEnabled || appState.isGPTLiveEnabled || appState.isGrokLiveEnabled
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
                    pushToTalk: VoicePushToTalkSettingsModel(
                        enabled: appState.voicePushToTalkEnabled,
                        setEnabled: { appState.setVoicePushToTalk($0) }
                    ),
                    // Only V2 has the big button beside a chat.
                    chatVoiceButton: V2ShellPreference.isOn ? ChatVoiceButtonSettingsModel(
                        choice: ChatVoiceButtonAction.offeredChoice(appState.chatVoiceButtonOverride),
                        appChoice: ChatVoiceButtonAction.resolved(
                            profile: nil,
                            app: UserDefaults.standard.string(forKey: ChatVoiceButtonAction.key)
                        ),
                        setChoice: { appState.setChatVoiceButtonOverride($0) }
                    ) : nil,
                    speakerTalkOver: VoiceSpeakerTalkOverSettingsModel(
                        enabled: appState.liveVoiceSpeakerBargeInEnabled,
                        setEnabled: { appState.setLiveVoiceSpeakerBargeInEnabled($0) }
                    ),
                    callSaves: VoiceCallSaveStatusModel(
                        pendingCount: appState.pendingVoiceCallSaves,
                        blocked: appState.voiceCallSavesBlocked,
                        isSaving: appState.isSavingQueuedVoiceCalls,
                        lastResult: appState.voiceCallSaveNowResult,
                        isWaitingOnCall: appState.isLiveVoiceCallActive,
                        saveNow: { await appState.saveQueuedVoiceCallsNow() }
                    ),
                    agentSettingsChanged: appState.notifierPlugin.reports(AgentSettingsSync.capability)
                        ? { Task { await appState.syncAgentSettings() } }
                        : nil
                )
                // A change Hermes made reseeds the page's values.
                .id(appState.agentSettings.revision)
                .task { await appState.syncAgentSettings() }
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
                fields: [],
                load: loadProfileSettings,
                save: persistProfileSetting,
                sections: Self.workspaceSections,
                loadSchema: { await appState.loadProfileConfigSchema() }
            )
        case .memory:
            MemorySettingsDetail(
                load: loadProfileSettings,
                save: persistProfileSetting,
                loadOptions: loadProfileConfigOptions,
                loadModels: loadProfileModelDefaults,
                loadSchema: { await appState.loadProfileConfigSchema() },
                sections: Self.memorySections,
                loadDelegationPaused: { await appState.loadDelegationPaused() },
                setDelegationPaused: { await appState.setDelegationPaused($0) }
            )
        case .advanced:
            ProfileConfigSettingsPage(
                title: AppLocalization.string("Advanced"),
                subtitle: AppLocalization.string("Limits and runtime defaults for this profile. Most profiles never need to change these."),
                fields: [],
                load: loadProfileSettings,
                save: persistProfileSetting,
                sections: Self.advancedSections,
                loadSchema: { await appState.loadProfileConfigSchema() }
            )
        case .usage:
            UsageSettingsDetail()
        case .capabilities:
            CapabilitiesView()
        case .gateway:
            // V2's Settings names this row Connection, so its page does too.
            GatewaySettingsDetail(title: homeHeader != nil ? AppLocalization.string("Connection") : AppLocalization.string("Gateway"), snapshot: snapshot, reconnect: reconnect, disconnect: disconnect, close: { dismiss() }, saveCloudflareAccess: appState.saveCloudflareAccess, removeCloudflareAccess: appState.removeCloudflareAccess, customHeaders: appState.customHeaders(), saveCustomHeaders: appState.saveCustomHeaders)
        case .conduitPlugin:
            ConduitPluginSettingsDetail()
        case .savedDashboards:
            SavedDashboardsSettingsDetail(close: { dismiss() })
        case .appearance:
            AppearanceSettingsDetail(theme: appState.themePreference, saveTheme: saveTheme)
        case .notifications:
            NotificationsSettingsDetail()
        case .syncedPreferences:
            SyncedPreferencesSettingsDetail(controller: appState.syncedPreferences)
        case .hermesCalls:
            HermesCallsSettingsPage(
                model: HermesCallSettingsModel(
                    profile: appState.activeProfile,
                    status: appState.activeHermesCallsStatus,
                    load: {
                        await appState.refreshHermesCallsStatus()
                        return appState.activeHermesCallsStatus != nil
                    },
                    current: { appState.activeHermesCallsStatus?.settings },
                    save: { [profile = appState.activeProfile, dashboardID = appState.activeDashboardID] settings in
                        await appState.saveHermesCallSettings(settings, profile: profile, dashboardID: dashboardID)
                    },
                    places: appState.locationPlacesForCalls
                ),
                hearsMissedCalls: appState.supportsHermesCallOutcomes,
                startTestCall: {
                    dismiss()
                    Task { await appState.startHermesTestCall() }
                },
                startWatch: { note in
                    dismiss()
                    Task { await appState.startHermesWatch(for: note) }
                }
            )
                .navigationTitle("Calls from Hermes")
        case .health:
            HealthSettingsPage(engine: appState.healthSync)
        case .location:
            LocationSettingsPage(controller: LocationSharingController.shared, engine: LocationSharingController.shared.engine)
        case .phone:
            PhoneSettingsPage(engine: appState.phoneSync)
        case .shortcutInbox:
            ShortcutInboxSettingsPage()
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

    static var workspaceFields: [ProfileSettingField] { workspaceSections.flatMap(\.fields) }

    static var workspaceSections: [ProfileSettingSection] { [
        ProfileSettingSection(title: AppLocalization.string("Workspace"), symbol: "folder", fields: [
            .init(key: "terminal.cwd", label: AppLocalization.string("Default working directory"), help: AppLocalization.string("Server-side path for new workspaces."), control: .text(defaultValue: "")),
            .init(key: "code_execution.mode", label: AppLocalization.string("Code execution mode"), help: AppLocalization.string("Default execution boundary."), control: .options(["project", "strict"], defaultValue: "project")),
            .init(key: "terminal.persistent_shell", label: AppLocalization.string("Persistent shell"), help: AppLocalization.string("SSH backend: keep exported variables between commands. The working directory always carries over."), control: .toggle(defaultValue: true), requiresSchema: true),
            .init(key: "terminal.env_passthrough", label: AppLocalization.string("Environment passthrough"), help: AppLocalization.string("Environment variables passed into tool commands, one per line."), control: .stringList, requiresSchema: true),
            .init(key: "file_read_max_chars", label: AppLocalization.string("File read limit"), help: AppLocalization.string("Most characters Hermes reads from a file in one request."), control: .number(defaultValue: 100_000), requiresSchema: true),
        ]),
        ProfileSettingSection(title: AppLocalization.string("Safety"), symbol: "checkmark.shield", fields: [
            .init(key: "approvals.mode", label: AppLocalization.string("Approval mode"), help: AppLocalization.string("Profile-wide default: manual asks every time; smart asks when risk warrants it; off is YOLO mode. When set to off, Hermes auto-approves everything and per-session YOLO toggles have no effect — that's a Hermes limitation, not a Conduit bug. To use per-session YOLO, set this to manual or smart."), control: .options(["manual", "smart", "off"], defaultValue: "smart")),
            .init(key: "approvals.timeout", label: AppLocalization.string("Approval timeout"), help: AppLocalization.string("Seconds an approval request waits before it times out."), control: .number(defaultValue: 300), requiresSchema: true),
            .init(key: "approvals.mcp_reload_confirm", label: AppLocalization.string("Confirm connector reloads"), help: AppLocalization.string("Ask before Hermes reloads its MCP connectors."), control: .toggle(defaultValue: true), requiresSchema: true),
            .init(key: "command_allowlist", label: AppLocalization.string("Command allowlist"), help: AppLocalization.string("Command patterns you approved permanently, one per line. Remove a line to be asked again."), control: .stringList, requiresSchema: true),
            .init(key: "security.redact_secrets", label: AppLocalization.string("Redact secrets"), help: AppLocalization.string("Hide detected credentials from tool output where possible."), control: .toggle(defaultValue: true)),
            .init(key: "security.allow_private_urls", label: AppLocalization.string("Allow private URLs"), help: AppLocalization.string("Permit tool access to private-network URLs."), control: .toggle(defaultValue: false)),
            .init(key: "checkpoints.enabled", label: AppLocalization.string("File checkpoints"), help: AppLocalization.string("Snapshot files before Hermes edits them, so changes can be rolled back."), control: .toggle(defaultValue: false), requiresSchema: true),
        ]),
        ProfileSettingSection(title: AppLocalization.string("Browser"), symbol: "globe", fields: [
            .init(key: "browser.use_real_profile", label: AppLocalization.string("Use my real browser profile"), help: AppLocalization.string("Browse with a copy of the host's default Chromium browser profile, including its logins."), control: .toggle(defaultValue: false), requiresSchema: true),
            .init(key: "browser.allow_private_urls", label: AppLocalization.string("Browser private URLs"), help: AppLocalization.string("Let the browser open private-network addresses."), control: .toggle(defaultValue: false), requiresSchema: true),
            .init(key: "browser.auto_local_for_private_urls", label: AppLocalization.string("Local browser for private URLs"), help: AppLocalization.string("Open private-network addresses in a local browser even when a cloud browser is set up."), control: .toggle(defaultValue: true), requiresSchema: true),
        ]),
    ]
    }

    static var memoryFields: [ProfileSettingField] { memorySections.flatMap(\.fields) }

    static var memorySections: [ProfileSettingSection] { [
        ProfileSettingSection(title: AppLocalization.string("Memory"), symbol: "brain.head.profile", fields: [
            .init(key: "memory.provider", label: AppLocalization.string("Memory provider"), help: AppLocalization.string("Provider used for long-term memory."), control: .options([], defaultValue: "")),
            .init(key: "memory.memory_enabled", label: AppLocalization.string("Long-term memory"), help: AppLocalization.string("Allow Hermes to retain relevant working memory."), control: .toggle(defaultValue: true)),
            .init(key: "memory.user_profile_enabled", label: AppLocalization.string("User profile memory"), help: AppLocalization.string("Allow Hermes to maintain user preferences."), control: .toggle(defaultValue: true)),
            .init(key: "memory.memory_char_limit", label: AppLocalization.string("Memory budget"), help: AppLocalization.string("Most characters of saved memory Hermes keeps."), control: .number(defaultValue: 2200), requiresSchema: true),
            .init(key: "memory.user_char_limit", label: AppLocalization.string("Profile budget"), help: AppLocalization.string("Most characters of user profile Hermes keeps."), control: .number(defaultValue: 1375), requiresSchema: true),
        ]),
        ProfileSettingSection(title: AppLocalization.string("Context"), symbol: "circle.dotted.circle", fields: [
            .init(key: "context.engine", label: AppLocalization.string("Context engine"), help: AppLocalization.string("Installed context-management engine."), control: .options([], defaultValue: "default")),
            .init(key: "compression.enabled", label: AppLocalization.string("Context compression"), help: AppLocalization.string("Compress older context when the window becomes crowded."), control: .toggle(defaultValue: true)),
            .init(key: "compression.threshold", label: AppLocalization.string("Compression threshold"), help: AppLocalization.string("Fraction of the context window that starts compression."), control: .number(defaultValue: 0.8)),
            .init(key: "compression.target_ratio", label: AppLocalization.string("Compression target"), help: AppLocalization.string("Fraction retained after compression."), control: .number(defaultValue: 0.5)),
            .init(key: "compression.protect_last_n", label: AppLocalization.string("Protected recent messages"), help: AppLocalization.string("Recent messages left intact by compression."), control: .number(defaultValue: 8)),
            .init(key: "compression.codex_gpt55_autoraise", label: AppLocalization.string("Codex compression auto-raise"), help: AppLocalization.string("Start compression at 85% for supported ChatGPT Codex sign-in models."), control: .toggle(defaultValue: true), requiresSchema: true),
            .init(key: "auxiliary.compression.timeout", label: AppLocalization.string("Compression timeout"), help: AppLocalization.string("Seconds to wait for the compression model on each call. Raise it for slow local models."), control: .number(defaultValue: 120), requiresSchema: true),
        ]),
        ProfileSettingSection(title: AppLocalization.string("Delegation"), symbol: "point.3.connected.trianglepath.dotted", fields: [
            .init(key: "delegation.max_concurrent_children", label: AppLocalization.string("Concurrent delegate agents"), help: AppLocalization.string("Maximum child agents that can work at once."), control: .number(defaultValue: 2)),
            .init(key: "delegation.max_iterations", label: AppLocalization.string("Delegate turn limit"), help: AppLocalization.string("Most turns one delegate agent can take."), control: .number(defaultValue: 250), requiresSchema: true),
            .init(key: "delegation.child_timeout_seconds", label: AppLocalization.string("Delegate timeout"), help: AppLocalization.string("Seconds before a delegate agent is stopped. 0 means no limit."), control: .number(defaultValue: 0), requiresSchema: true),
        ]),
    ]
    }

    static var modelFields: [ProfileSettingField] { [
        .init(key: "agent.service_tier", label: AppLocalization.string("Fast mode"), help: AppLocalization.string("When Hermes asks the provider for faster priority processing, on models that offer it."), control: .options([], defaultValue: ""), requiresSchema: true),
        .init(key: "model_context_length", label: AppLocalization.string("Context window"), help: AppLocalization.string("Overrides the main model's context window, in tokens. 0 uses the model's own size."), control: .number(defaultValue: 0), requiresSchema: true),
    ]
    }

    static var advancedFields: [ProfileSettingField] { advancedSections.flatMap(\.fields) }

    static var advancedSections: [ProfileSettingSection] { [
        ProfileSettingSection(title: AppLocalization.string("Runtime"), symbol: "cpu", fields: [
            .init(key: "agent.max_turns", label: AppLocalization.string("Turn limit"), help: AppLocalization.string("Most tool-calling turns before Hermes stops a run. 0 means no limit."), control: .number(defaultValue: 0), requiresSchema: true),
            .init(key: "agent.api_max_retries", label: AppLocalization.string("API retries"), help: AppLocalization.string("How many times Hermes retries a failed model request."), control: .number(defaultValue: 3), requiresSchema: true),
        ]),
        ProfileSettingSection(title: AppLocalization.string("Terminal"), symbol: "terminal", fields: [
            .init(key: "terminal.timeout", label: AppLocalization.string("Command timeout"), help: AppLocalization.string("Seconds a terminal command can run."), control: .number(defaultValue: 180), requiresSchema: true),
            .init(key: "terminal.docker_image", label: AppLocalization.string("Docker image"), help: AppLocalization.string("Image used when the terminal backend is Docker."), control: .text(defaultValue: ""), requiresSchema: true),
            .init(key: "terminal.singularity_image", label: AppLocalization.string("Singularity image"), help: AppLocalization.string("Image used when the terminal backend is Singularity."), control: .text(defaultValue: ""), requiresSchema: true),
            .init(key: "terminal.modal_image", label: AppLocalization.string("Modal image"), help: AppLocalization.string("Image used when the terminal backend is Modal."), control: .text(defaultValue: ""), requiresSchema: true),
            .init(key: "terminal.daytona_image", label: AppLocalization.string("Daytona image"), help: AppLocalization.string("Image used when the terminal backend is Daytona."), control: .text(defaultValue: ""), requiresSchema: true),
        ]),
        ProfileSettingSection(title: AppLocalization.string("Files & output"), symbol: "doc.text", fields: [
            .init(key: "tool_output.max_bytes", label: AppLocalization.string("Terminal output limit"), help: AppLocalization.string("Most bytes of command output Hermes reads."), control: .number(defaultValue: 50_000), requiresSchema: true),
            .init(key: "tool_output.max_lines", label: AppLocalization.string("File page limit"), help: AppLocalization.string("Most lines Hermes reads from a file at once."), control: .number(defaultValue: 2000), requiresSchema: true),
            .init(key: "tool_output.max_line_length", label: AppLocalization.string("Line length limit"), help: AppLocalization.string("Longer lines are cut to this many characters."), control: .number(defaultValue: 2000), requiresSchema: true),
            .init(key: "checkpoints.max_snapshots", label: AppLocalization.string("Checkpoint limit"), help: AppLocalization.string("Most file snapshots kept for rolling back."), control: .number(defaultValue: 20), requiresSchema: true),
        ]),
        ProfileSettingSection(title: AppLocalization.string("Updates"), symbol: "arrow.down.circle", fields: [
            .init(key: "updates.non_interactive_local_changes", label: AppLocalization.string("Local changes on update"), help: AppLocalization.string("When Hermes updates itself from an app, keep local source edits or throw them away. Terminal updates always ask."), control: .options(["stash", "discard"], defaultValue: "stash"), requiresSchema: true),
        ]),
    ]
    }
}

private struct SettingsHome: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// Redraws when an inbox's key or waiting events change (showsShortcutInboxSettings).
    @ObservedObject private var shortcutInbox = ShortcutInboxLocalState.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: SettingsSnapshot
    @Binding var path: [SettingsDestination]
    /// V2's grouping: the selected profile first, then Voice, Hermes, App.
    var v2Layout = false
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @State private var showProfileManager = false
    /// Round 5: the Settings entry into the existing Connection Setup
    /// assistant, seeded from the current configuration.
    @State private var connectionSetupSeed: ConnectionSetupSeed?
    /// Set by the wizard's completion when the applied plan changes the
    /// saved configuration; surfaced as an alert only after the wizard sheet
    /// has dismissed (one presentation context at a time).
    @State private var pendingAppliedNotice = false
    @State private var appliedConnectionNotice = false
    /// The saved dashboard an edited address already belongs to: the apply
    /// was refused, and says so the same way once the wizard has gone.
    @State private var pendingAddressOwner: String?
    @State private var addressOwner: String?

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
            // V2: the tab roots' backdrop in the profile's glow, held still
            // like a settings page's.
            if v2Layout {
                V2Backdrop(drifts: false)
            } else {
                ConduitBackdrop()
            }
            ScrollView {
                VStack(spacing: v2Layout ? 24 : 14) {
                    if appState.notifierPlugin.needsAttention {
                        NotifierPluginUpdateNotice(status: appState.notifierPlugin, dashboardLabel: notifierDashboardLabel) {
                            Haptics.selection()
                            path.append(.conduitPlugin)
                        }
                    }
                    if v2Layout {
                        v2Sections
                    } else {
                    homeSection(AppLocalization.string("Profile"), symbol: "person.crop.circle", tint: .conduitAccent) {
                        settingsLink(.profile, icon: "person.crop.circle", title: profileDisplayName, detail: AppLocalization.string("Profile-specific preferences"))
                    }
                    homeSection("Hermes", tint: .conduitAura) {
                        settingsLink(.model, icon: "cpu", title: AppLocalization.string("Model"), detail: AppLocalization.string("Default model and reasoning"))
                        settingsLink(.usage, icon: "chart.bar", title: AppLocalization.string("Usage"), detail: AppLocalization.string("Tokens, cost, and provider quota"), identifier: "settings.usage")
                        settingsLink(.chat, icon: "bubble.left.and.bubble.right", title: AppLocalization.string("Chat"), detail: AppLocalization.string("Response behavior, visibility, and timezone"))
                        settingsLink(.voice, icon: "mic.and.signal.meter", title: AppLocalization.string("Voice"), detail: AppLocalization.string("Speech providers, credentials, and device opt-in"))
                        if appState.supportsHermesCalls {
                            settingsLink(.hermesCalls, icon: "phone.arrow.down.left", title: AppLocalization.string("Calls from Hermes"), detail: AppLocalization.string("When Hermes may phone you"), identifier: "settings.hermes-calls")
                        }
                        settingsLink(.workspace, icon: "folder", title: AppLocalization.string("Workspace & safety"), detail: AppLocalization.string("Working directory, approvals, and privacy"))
                        settingsLink(.memory, icon: "brain.head.profile", title: AppLocalization.string("Memory & delegation"), detail: AppLocalization.string("Memory, compression, and child agents"))
                        settingsLink(.advanced, icon: "wrench.and.screwdriver", title: AppLocalization.string("Advanced"), detail: AppLocalization.string("Turn limits, terminal, and tool output"))
                        settingsLink(.capabilities, icon: "puzzlepiece.extension", title: AppLocalization.string("Capabilities"), detail: AppLocalization.string("Skills, tools, connectors, and plugins"))
                    }
                    homeSection(AppLocalization.string("Connection"), tint: .conduitAura) {
                        settingsLink(.savedDashboards, icon: "server.rack", title: AppLocalization.string("Saved Dashboards"), detail: savedDashboardsDetail, identifier: "settings.saved-dashboards")
                        settingsLink(.gateway, icon: "radio", title: AppLocalization.string("Gateway"), detail: snapshot.server ?? AppLocalization.string("Not connected"), identifier: "settings.gateway")
                        settingsLink(.conduitPlugin, icon: "puzzlepiece.extension", title: AppLocalization.string("Conduit plugin"), detail: NotifierPluginSummary.detail(appState.notifierPlugin, update: appState.activeNotifierPluginUpdate), identifier: "settings.conduit-plugin")
                        settingsLink(.syncedPreferences, icon: "arrow.triangle.2.circlepath", title: AppLocalization.string("Sync across devices"), detail: syncedPreferencesDetail, identifier: "settings.sync")
                        settingsActionRow(
                            icon: "checkmark.circle",
                            title: AppLocalization.string("Connection Setup"),
                            detail: AppLocalization.string("Test, troubleshoot, or change your connection"),
                            identifier: "settings.connection-setup"
                        ) {
                            openConnectionSetup()
                        }
                    }
                    homeSection(AppLocalization.string("On this device"), tint: .conduitAccent) {
                        settingsLink(.appearance, icon: "circle.lefthalf.filled", title: AppLocalization.string("Appearance"), detail: AppLocalization.string("Theme and interface preferences"))
                        settingsLink(.notifications, icon: "bell", title: AppLocalization.string("Notifications"), detail: AppLocalization.string("Delivery status and setup"))
                        if appState.showsHealthSettings {
                            settingsLink(.health, icon: "heart.text.square", title: AppLocalization.string("Health"), detail: AppLocalization.string("Share Apple Health data with Hermes"), identifier: "settings.health")
                        }
                        if appState.showsLocationSettings {
                            settingsLink(.location, icon: "location", title: AppLocalization.string("Location"), detail: AppLocalization.string("Share where you are with Hermes"), identifier: "settings.location")
                        }
                        if appState.showsPhoneSettings {
                            settingsLink(.phone, icon: "calendar", title: AppLocalization.string("Calendar & phone"), detail: AppLocalization.string("Share your calendar, reminders, Focus and phone status with Hermes"), identifier: "settings.phone")
                        }
                        if appState.showsShortcutInboxSettings {
                            settingsLink(.shortcutInbox, icon: "tray.full", title: AppLocalization.string("Shortcuts inbox"), detail: AppLocalization.string("What your automations logged for Hermes"), identifier: "settings.shortcut-inbox")
                        }
                        settingsLink(.screenQuestion, icon: "camera.viewfinder", title: AppLocalization.string("Ask Hermes About Screen"), detail: AppLocalization.string("Action Button shortcut for screenshots"), identifier: "settings.screen-question")
                        settingsLink(.about, icon: "shield", title: AppLocalization.string("About & privacy"), detail: AppLocalization.string("App information and data handling"))
                    }
                    }
                    Text("Hermes settings follow the active profile. Appearance, notifications, and privacy controls stay on this device unless you turn on Sync across devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, v2Layout ? 16 : 10)
                        .padding(.top, v2Layout ? -12 : 2)
                }
                .padding(.horizontal, 16)
                .padding(.top, v2Layout ? 8 : 16)
                .padding(.bottom, v2Layout ? 24 : 16)
            }
            // A profile switch from the bar above slides the list out and
            // back in with the new profile's settings, from the top, as the
            // other tabs do; the bar stays put.
            .id(snapshot.id)
            .v2ProfileSwitchContent()
        }
        .sheet(isPresented: $showProfileManager) {
            ProfilePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
        .sheet(item: $connectionSetupSeed, onDismiss: {
            if let owner = pendingAddressOwner {
                pendingAddressOwner = nil
                addressOwner = owner
                return
            }
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
                initialCloudflareOriginURL: seed.url,
                onComplete: { result in
                    // Reload the saved state at apply time: the plan must
                    // decide against what exists NOW, not what existed when
                    // the sheet was seeded.
                    let plan = ConnectionSetupApplication.plan(
                        result: result,
                        currentDashboardURL: seed.url,
                        savedCredentials: appState.savedCredentialsForDashboard(at: seed.url),
                        savedCloudflareAccess: appState.dashboardScopedCloudflareAccess(for: seed.url)
                    )
                    switch plan.perform(appState: appState) {
                    case .applied:
                        pendingAppliedNotice = !plan.isEmpty
                    case .addressBelongsToDashboard(let label):
                        pendingAddressOwner = label
                    }
                },
                // Sign In Again (a test that found browser sign-in for this
                // dashboard) signs in and reconnects through the same
                // explicit activation as Repair.
                onRepair: appState.connectionRepairActivationHandler()
            )
            .environmentObject(appState)
        }
        .alert("Settings applied", isPresented: $appliedConnectionNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            // Only a connected session "stays connected".
            Text(appState.isConnected
                 ? AppLocalization.string("Saved for your next reconnect. Your current session stays connected.")
                 : AppLocalization.string("Saved for your next reconnect."))
        }
        .alert("Settings not applied", isPresented: Binding(
            get: { addressOwner != nil },
            set: { if !$0 { addressOwner = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(AppLocalization.string("This address is your saved dashboard “\(addressOwner ?? "")”. Switch to it from your dashboards instead."))
        }
        // Asked again on every visit and dashboard switch: the connect-time
        // check can miss (the dashboard was still loading), and the plugin
        // may have been updated since, which should clear the notice.
        .task(id: appState.activeDashboardID) {
            await appState.refreshNotifierPluginStatus()
        }
    }

    private func openConnectionSetup() {
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

    private var syncedPreferencesDetail: String {
        appState.syncedPreferences.isEnabled
            ? AppLocalization.string("On: shared with your other devices")
            : AppLocalization.string("Share preferences with your other devices")
    }

    /// V2's grouping: the selected profile (its connection, approvals and
    /// profile page), then Voice, Hermes, and App, each one card of rows
    /// with hairlines between them, as in the Scheduled list. Every page the
    /// drawer's Settings reached stays reachable.
    @ViewBuilder
    private var v2Sections: some View {
        v2Group(profileDisplayName, symbol: "person.crop.circle") {
            v2Link(
                .gateway,
                icon: "dot.radiowaves.left.and.right",
                title: AppLocalization.string("Connection"),
                detail: v2ConnectionDetail,
                identifier: "settings.gateway",
                statusDot: appState.isConnected ? Color.green : (appState.isRecoveringConnection ? Color.orange : Color.red),
                first: true
            )
            v2Link(.workspace, icon: "checkmark.shield", title: AppLocalization.string("Approvals"), detail: AppLocalization.string("Working directory, approvals, and privacy"))
            v2Link(.profile, icon: "person.crop.circle", title: AppLocalization.string("Edit profile"), detail: AppLocalization.string("Profile-specific preferences"))
        }
        v2Group(AppLocalization.string("Voice"), symbol: "waveform") {
            v2Link(.voice, icon: "mic.and.signal.meter", title: AppLocalization.string("Voice"), detail: AppLocalization.string("Speech providers, credentials, and device opt-in"), first: true)
            if appState.supportsHermesCalls {
                v2Link(.hermesCalls, icon: "phone.arrow.down.left", title: AppLocalization.string("Calls from Hermes"), detail: AppLocalization.string("When Hermes may phone you"), identifier: "settings.hermes-calls")
            }
        }
        v2Group(AppLocalization.string("Hermes"), symbol: "gearshape.2") {
            v2Link(.model, icon: "cpu", title: AppLocalization.string("Model"), detail: AppLocalization.string("Default model and reasoning"), first: true)
            v2Link(.usage, icon: "chart.bar", title: AppLocalization.string("Usage"), detail: AppLocalization.string("Tokens, cost, and provider quota"), identifier: "settings.usage")
            v2Link(.chat, icon: "bubble.left.and.bubble.right", title: AppLocalization.string("Chat"), detail: AppLocalization.string("Response behavior, visibility, and timezone"))
            v2Link(.memory, icon: "brain.head.profile", title: AppLocalization.string("Memory & delegation"), detail: AppLocalization.string("Memory, compression, and child agents"))
            v2Link(.advanced, icon: "wrench.and.screwdriver", title: AppLocalization.string("Advanced"), detail: AppLocalization.string("Turn limits, terminal, and tool output"))
            v2Link(.capabilities, icon: "puzzlepiece.extension", title: AppLocalization.string("Capabilities"), detail: AppLocalization.string("Skills, tools, connectors, and plugins"))
        }
        v2Group(AppLocalization.string("App"), symbol: "slider.horizontal.3") {
            v2Action(
                icon: "person.2.crop.square.stack",
                title: AppLocalization.string("Profiles"),
                detail: AppLocalization.string("Rename, reorder, or change profile photos"),
                identifier: "settings.profiles",
                first: true
            ) {
                showProfileManager = true
            }
            v2Link(.appearance, icon: "circle.lefthalf.filled", title: AppLocalization.string("Appearance"), detail: AppLocalization.string("Theme and interface preferences"))
            v2Link(.notifications, icon: "bell", title: AppLocalization.string("Notifications"), detail: AppLocalization.string("Delivery status and setup"))
            v2Link(.syncedPreferences, icon: "arrow.triangle.2.circlepath", title: AppLocalization.string("Sync across devices"), detail: syncedPreferencesDetail, identifier: "settings.sync")
            v2Link(.screenQuestion, icon: "camera.viewfinder", title: AppLocalization.string("Ask Hermes About Screen"), detail: AppLocalization.string("Action Button shortcut for screenshots"), identifier: "settings.screen-question")
        }
        if appState.showsHealthSettings || appState.showsLocationSettings || appState.showsPhoneSettings || appState.showsShortcutInboxSettings {
            v2Group(AppLocalization.string("On this device"), symbol: "iphone") {
                if appState.showsHealthSettings {
                    v2Link(.health, icon: "heart.text.square", title: AppLocalization.string("Health"), detail: AppLocalization.string("Share Apple Health data with Hermes"), identifier: "settings.health", first: true)
                }
                if appState.showsLocationSettings {
                    v2Link(.location, icon: "location", title: AppLocalization.string("Location"), detail: AppLocalization.string("Share where you are with Hermes"), identifier: "settings.location", first: !appState.showsHealthSettings)
                }
                if appState.showsPhoneSettings {
                    v2Link(.phone, icon: "calendar", title: AppLocalization.string("Calendar & phone"), detail: AppLocalization.string("Share your calendar, reminders, Focus and phone status with Hermes"), identifier: "settings.phone", first: !appState.showsHealthSettings && !appState.showsLocationSettings)
                }
                if appState.showsShortcutInboxSettings {
                    v2Link(.shortcutInbox, icon: "tray.full", title: AppLocalization.string("Shortcuts inbox"), detail: AppLocalization.string("What your automations logged for Hermes"), identifier: "settings.shortcut-inbox", first: !appState.showsHealthSettings && !appState.showsLocationSettings && !appState.showsPhoneSettings)
                }
            }
        }
        v2Group(AppLocalization.string("Server"), symbol: "server.rack") {
            v2Link(.savedDashboards, icon: "server.rack", title: AppLocalization.string("Saved Dashboards"), detail: savedDashboardsDetail, identifier: "settings.saved-dashboards", first: true)
            v2Link(.conduitPlugin, icon: "puzzlepiece.extension", title: AppLocalization.string("Conduit plugin"), detail: NotifierPluginSummary.detail(appState.notifierPlugin, update: appState.activeNotifierPluginUpdate), identifier: "settings.conduit-plugin")
            v2Action(
                icon: "checkmark.circle",
                title: AppLocalization.string("Connection Setup"),
                detail: AppLocalization.string("Test, troubleshoot, or change your connection"),
                identifier: "settings.connection-setup"
            ) {
                openConnectionSetup()
            }
        }
        v2Group(AppLocalization.string("About"), symbol: "info.circle") {
            v2Link(.about, icon: "shield", title: AppLocalization.string("About & privacy"), detail: AppLocalization.string("App information and data handling"), first: true)
        }
    }

    /// A V2 group: its name over one card of rows.
    private func v2Group<Rows: View>(_ title: String, symbol: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: title, symbol: symbol, tint: .conduitAccent)
            VStack(spacing: 0) {
                rows()
            }
            .settingsCard()
        }
    }

    private func v2Link(
        _ destination: SettingsDestination,
        icon: String,
        title: String,
        detail: String,
        identifier: String = "",
        statusDot: Color? = nil,
        first: Bool = false
    ) -> some View {
        Button {
            Haptics.selection()
            path.append(destination)
        } label: {
            v2RowLabel(icon: icon, title: title, detail: detail, statusDot: statusDot, first: first)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func v2Action(
        icon: String,
        title: String,
        detail: String,
        identifier: String,
        first: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            v2RowLabel(icon: icon, title: title, detail: detail, first: first)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// A row in a V2 group: the gold glyph, the name over a short detail,
    /// a chevron, and a hairline above every row but the first, from the
    /// text column.
    private func v2RowLabel(icon: String, title: String, detail: String, statusDot: Color? = nil, first: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .conduitFixedGlyph()
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    if let statusDot {
                        Circle().fill(statusDot).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.conduitTertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if !first { V2RowDivider(leadingInset: 56) }
        }
    }

    /// The Connection row's second line: the state in a word, and the host.
    private var v2ConnectionDetail: String {
        let state = appState.isConnected
            ? AppLocalization.string("Connected")
            : (appState.isRecoveringConnection ? AppLocalization.string("Connecting…") : AppLocalization.string("Not connected"))
        guard let server = snapshot.server, !server.isEmpty else { return state }
        let host = URL(string: server)?.host ?? server
        return "\(state) · \(host)"
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
        appState.profileDisplayName(snapshot.profile)
    }

    private func homeSection<Content: View>(_ title: String, symbol: String = "gearshape.2", tint: Color, @ViewBuilder content: () -> Content) -> some View {
        ConduitSettingsSection(title: title, symbol: symbol, tint: tint, content: content)
    }

    private func settingsLink(_ destination: SettingsDestination, icon: String, title: String, detail: String, identifier: String = "", statusDot: Color? = nil) -> some View {
        Button {
            Haptics.selection()
            path.append(destination)
        } label: {
            settingsRowLabel(icon: icon, title: title, detail: detail, statusDot: statusDot)
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

    private func settingsRowLabel(icon: String, title: String, detail: String, statusDot: Color? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).conduitFixedGlyph().foregroundStyle(.conduitAccent).frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                HStack(spacing: 5) {
                    if let statusDot {
                        Circle().fill(statusDot).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.conduitTertiary)
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
    @EnvironmentObject private var appState: AppState
    @State private var name: String
    /// The name the field last showed: Save writes nothing until it's edited.
    @State private var seeded: String
    @State private var didSave = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(profile: String, displayName: String) {
        self.profile = profile
        self.displayName = displayName
        _name = State(initialValue: displayName)
        _seeded = State(initialValue: displayName)
    }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Active profile"), symbol: "person.crop.circle.fill", tint: .conduitAccent) {
                SettingsMetricRow(label: AppLocalization.string("Profile"), value: currentDisplayName)
                Text("Choose a different profile from the session drawer. Chat, model, workspace, and memory preferences on the other settings pages follow that profile.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ConduitSettingsSection(title: namedOnDevice ? AppLocalization.string("On this device") : AppLocalization.string("Name"), symbol: "pencil", tint: .conduitAccent) {
                Text("Display name").font(.subheadline.weight(.semibold))
                TextField("Hermes", text: $name)
                    .textInputAutocapitalization(.words)
                    // What's typed mid-save would be replaced by the saved name.
                    .disabled(isSaving)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(BotManagement.isDefaultProfile(profile)
                     ? AppLocalization.string("This only changes how the default profile is named in Conduit. Hermes itself still uses the default profile.")
                     : namedOnDevice
                        ? AppLocalization.string("This only changes how the profile is named in Conduit.")
                        : AppLocalization.string("Chats and settings stay with the profile. Bots and Hermes Desktop show the new name too."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let saveError {
                    Text(saveError).font(.footnote).foregroundStyle(.red)
                }
                Button(didSave ? AppLocalization.string("Saved") : AppLocalization.string("Save display name")) {
                    save()
                }
                    .buttonStyle(.settingsPrimary)
                    .disabled(isSaving)
            }
        }
        .navigationTitle("Profile")
        // A rename elsewhere (Edit Bot, the Profiles sheet) shows here
        // unless the field is being edited.
        .onAppear(perform: followCurrentName)
        .onChange(of: currentDisplayName) { _, _ in followCurrentName() }
        .onChange(of: name) { _, _ in if name != seeded { didSave = false } }
    }

    private func followCurrentName() {
        guard name == seeded else { return }
        name = currentDisplayName
        seeded = currentDisplayName
    }

    private var currentDisplayName: String {
        appState.profileDisplayName(profile)
    }

    /// The main profile's name is Conduit's own; any other profile's is its
    /// bot title on Hermes, unless the gateway has no bot looks.
    private var namedOnDevice: Bool {
        BotManagement.isDefaultProfile(profile) || !appState.profilePhotosLiveOnHermes
    }

    private func save() {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines)
                != seeded.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            saveError = await appState.renameProfile(profile, to: name)
            isSaving = false
            // A failed save keeps what was typed, to try again.
            guard saveError == nil else { return }
            name = appState.profileDisplayName(profile)
            seeded = name
            didSave = true
        }
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
    var loadSchema: (() async -> ProfileConfigSchema)? = nil
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
            fieldsHeader: AppLocalization.string("Hermes"),
            leadingSection: AnyView(
                VStack(spacing: 24) {
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
                VStack(spacing: 24) {
                    ChatTextSizeSettings()
                    ChatFontStyleSettings()
                    ReplyStartSettings()
                    ComposerReturnKeySettings()
                    AttachmentLimitSettings()
                    ChatTakeoverSettings()
                    StepSummarySettings()
                    PredictiveSettingsSection()
                    DeviceHapticsSettings()
                }
            ),
            loadSchema: loadSchema
        )
        .navigationTitle("Chat")
        .task { options = await loadOptions() }
    }

    static var fields: [ProfileSettingField] { [
        .init(key: "display.personality", label: AppLocalization.string("Personality"), help: AppLocalization.string("Default response style for new conversations."), control: .options([], defaultValue: "")),
        .init(key: ProfileTimeZone.configKey, label: AppLocalization.string("Timezone"), help: AppLocalization.string("Used for dates, reminders, and scheduled work."), control: .timeZone),
        .init(key: ReasoningDisplayMode.settingKey, label: AppLocalization.string("Thinking"), help: AppLocalization.string("Show puts Hermes' thinking in every chat. On request hides it, with Show thinking in a run's menu and a reply's ⋯. Off hides it everywhere."), control: .labeledOptions([(value: ReasoningDisplayMode.show.rawValue, label: AppLocalization.string("Show in every chat")), (value: ReasoningDisplayMode.onRequest.rawValue, label: AppLocalization.string("On request")), (value: ReasoningDisplayMode.off.rawValue, label: AppLocalization.string("Off"))], defaultValue: ReasoningDisplayMode.show.rawValue)),
        .init(key: "display.tool_progress", label: AppLocalization.string("Tool cards"), help: AppLocalization.string("Show tool calls and expandable details in conversations."), control: .textToggle(onValue: "all", offValue: "off", defaultValue: true)),
        .init(key: "display.expand_tools", label: AppLocalization.string("Keep tool cards expanded"), help: AppLocalization.string("Keep completed tool details open by default."), control: .toggle(defaultValue: false)),
        .init(key: "display.memory_notifications", label: AppLocalization.string("Self-improvement updates"), help: AppLocalization.string("Choose whether Conduit follows Hermes, always shows, or never shows maintenance updates."), control: .labeledOptions([(value: "default", label: AppLocalization.string("Use Hermes default")), (value: "on", label: AppLocalization.string("Always show")), (value: "off", label: AppLocalization.string("Never show"))], defaultValue: "default")),
        .init(key: "agent.image_input_mode", label: AppLocalization.string("Image attachments"), help: AppLocalization.string("How Hermes supplies images to a model."), control: .options(["auto", "native", "text"], defaultValue: "auto")),
        .init(key: "sessions.auto_archive", label: AppLocalization.string("Auto-archive stale chats"), help: AppLocalization.string("Archive chats nobody has touched for a while. Pinned chats stay, and nothing is deleted."), control: .toggle(defaultValue: false), requiresSchema: true),
        .init(key: "sessions.auto_archive_days", label: AppLocalization.string("Archive after (days)"), help: AppLocalization.string("Days without activity before a chat is archived."), control: .number(defaultValue: 3), requiresSchema: true),
    ]
    }
}

/// Chat text-size preference (issue #85). Stored in UserDefaults via
/// @AppStorage with the same lifetime as ComposerReturnKey — never part of
/// the Hermes profile configuration, and shared only by Sync across
/// devices. A five-position stepped slider: the change
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
                    // Fixed size: the slider's small and large ends.
                    Text("A")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Spacer()
                    // Fixed size: the slider's small and large ends.
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

/// The typeface of conversation text: Apple's system designs, so Dynamic
/// Type and every language keep working. Code stays monospaced and the
/// interface stays in the system font.
private struct ChatFontStyleSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ChatTypography.fontStylePreferenceKey) private var styleRaw = ChatFontStyle.standard.rawValue

    private var selected: ChatFontStyle {
        ChatTypography.resolveStyle(rawValue: styleRaw)
    }

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Chat text style"),
            symbol: "textformat",
            tint: .conduitAura
        ) {
            Text("The typeface of messages in a chat. Code stays monospaced, and the rest of the interface keeps the system font.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Chat text style", selection: Binding(get: { selected }, set: {
                Haptics.selection()
                styleRaw = $0.rawValue
            })) {
                ForEach(ChatFontStyle.allCases, id: \.self) { style in
                    Text(verbatim: style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            Text("Hermes replies like this.")
                .font(.body)
                .fontDesign(selected.fontDesign)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .conduitGlassSurface(cornerRadius: 14, tint: .clear)
        }
    }
}

/// Local, device-only composer input preference. Stored in UserDefaults via
/// @AppStorage; never part of the Hermes profile configuration.
private struct ComposerReturnKeySettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ComposerReturnKey.preferenceKey) private var returnKeySends = ComposerReturnKey.sendsByDefault
    /// A Mac has no on-screen keyboard to mention, and starts with the
    /// preference on.
    private let onMac = ProcessInfo.processInfo.isiOSAppOnMac

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Keyboard"),
            symbol: "keyboard",
            tint: .conduitAura
        ) {
            Text("When on, Return sends and Shift-Return starts a new line.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(ComposerReturnKey.defaultFootnote(onMac: onMac))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !onMac {
                Text("Hardware keyboards only. The on-screen keyboard's Return key keeps inserting a new line.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Toggle("Return key sends", isOn: $returnKeySends)
                .tint(.conduitAccent)
                .accessibilityHint(onMac ? Text(verbatim: "") : Text("Applies to hardware keyboards only. The on-screen keyboard's Return key is unchanged."))
        }
    }
}

/// A reply longer than the screen stops at its start (#365), and an
/// unread chat opens there (ChatReplyStartPreference, ChatScrollEngine).
private struct ReplyStartSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ChatReplyStartPreference.key) private var stopsAtStart = ChatReplyStartPreference.defaultOn

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Long replies"),
            symbol: "arrow.up.to.line",
            tint: .conduitAura
        ) {
            Text("A reply longer than the screen stops at its first line, so you can read it from the top. The arrow button goes to its end.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("A chat with an unread reply also opens at the start of that reply.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Stop at the start of long replies", isOn: $stopsAtStart)
                .tint(.conduitAccent)
                .accessibilityHint("When off, the chat follows each reply to its end as it arrives.")
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
/// as a send is refused (#304), on until turned off (#1061). Off, the
/// composer offers a button instead; calls take over either way.
private struct ChatTakeoverSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ChatTakeoverPreference.automaticKey) private var automatic = ChatTakeoverPreference.automaticDefault

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Chats open on your computer"),
            symbol: "desktopcomputer",
            tint: .conduitAura
        ) {
            Text("Hermes lets one app use a chat at a time. When a chat is open in Hermes Desktop or a terminal, Conduit takes it over when you send. Calls always take it over; turn this off to be asked first when you type.")
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

/// Device-only and off by default: a few lines on a finished run of
/// steps, asked of Hermes with a hidden /btw (ChatStepSummaries). A run's
/// menu asks for one whatever the switch says.
private struct StepSummarySettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ChatStepSummaries.preferenceKey) private var enabled = ChatStepSummaries.defaultEnabled
    @AppStorage(ChatStepSummaries.maxStepsKey) private var maxSteps = ChatStepSummaries.defaultMaxSteps

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Step summaries"),
            symbol: "text.line.first.and.arrowtriangle.forward",
            tint: .conduitAura
        ) {
            Text("When a reply took several steps, Hermes looks back on them in a short paragraph: what it set out to do and why each step came next, shown under the folded steps.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Each summary is one more short request to your model. It reuses the chat's prompt cache and never changes the chat.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("On or off, you can touch and hold any folded steps and choose Explain these steps, or a single finished step and choose Explain this step.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Describe finished steps", isOn: $enabled)
                .tint(.conduitAccent)
                .accessibilityHint("Summaries are kept on this device.")
            Stepper(value: $maxSteps, in: ChatStepSummaries.maxStepsRange, step: 5) {
                // The limit the check uses, should a stored value be out of range.
                Text(AppLocalization.string("Skip runs over \(String(ChatStepSummaries.clampedMaxSteps(maxSteps))) steps"))
            }
            .disabled(!enabled)
        }
    }
}

/// Shown at the top of Settings when the host's Conduit plugin is older
/// than this build wants, or needs a restart to finish updating. Opens
/// Settings > Conduit plugin, where the update runs.
private struct NotifierPluginUpdateNotice: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let status: NotifierPluginStatus
    /// Names the dashboard when several are saved: each has its own host.
    let dashboardLabel: String?
    let open: () -> Void

    var body: some View {
        ConduitSettingsSection(
            // Missing, or on the host but not running: there's nothing to update.
            title: status.offersInstall || status.isNotServed
                ? AppLocalization.string("Conduit plugin")
                : AppLocalization.string("Update the Conduit plugin"),
            symbol: "arrow.down.circle",
            tint: .orange
        ) {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: open) {
                Label(AppLocalization.string("Open Conduit plugin"), systemImage: "puzzlepiece.extension")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .frame(minHeight: 44)
            }
            .conduitGlassControl(cornerRadius: 16, tint: .orange.opacity(0.14))
        }
        .accessibilityIdentifier("settings.notifier-update")
    }

    private var detail: String {
        if status.isNotServed {
            return AppLocalization.string("Installed on this dashboard's host, but the dashboard doesn't run it. Turn it on in Hermes, then restart the gateway and the dashboard.")
        }
        if status.offersInstall {
            return AppLocalization.string("Missing or out of date on this dashboard's host, so features like taking chats over from Hermes Desktop won't work.")
        }
        switch (dashboardLabel, status.restartPending && !status.updateRecommended) {
        case (let label?, true):
            return AppLocalization.string("The Conduit plugin on \(label) was updated, and Hermes needs a restart to use it.")
        case (.none, true):
            return AppLocalization.string("The Conduit plugin on your Hermes host was updated, and Hermes needs a restart to use it.")
        case (let label?, false):
            return AppLocalization.string("A newer Conduit plugin is available for \(label). Conduit can update it for you.")
        case (.none, false):
            return AppLocalization.string("A newer Conduit plugin is available for your Hermes host. Conduit can update it for you.")
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
    /// V2 always opens on the Chats list, so it has no "Open to" choice.
    @AppStorage(V2ShellPreference.key) private var usesV2 = V2ShellPreference.defaultValue

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
            if !usesV2 {
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
            Text("Steer adds guidance to the active turn. Queue sends the message once it finishes. Interrupt stops it before handling the new message.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Messages during a response", selection: Binding(get: { mode }, set: choose)) {
                Text("Steer").tag(BusyInputMode.steer)
                Text("Queue").tag(BusyInputMode.queue)
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
        choices.first(where: { $0.id == value })?.title ?? (value as? String) ?? String(describing: value)
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
                .accessibilityAddTraits(choice.id == value ? .isSelected : [])
            }
        } label: {
            Group {
                // Large text: the value goes under the name, as in
                // SettingsMetricRow, instead of squeezing beside it.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        label
                        HStack {
                            valueText.accessibilityHidden(true)
                            Spacer(minLength: 8)
                            chevron
                        }
                    }
                } else {
                    HStack {
                        label
                        Spacer(minLength: 8)
                        valueText.multilineTextAlignment(.trailing).accessibilityHidden(true)
                        chevron
                    }
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6).frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        // VoiceOver reads "Name, Value" like a picker instead of one run-on label.
        .accessibilityValue(valueText)
        .conduitGlassControl(cornerRadius: 14)
    }
}

/// A Model page editor's stand-in for its pickers until the catalog has
/// rows: loading, a failed fetch with Try Again, or a gateway with none.
private struct ModelCatalogPlaceholder: View {
    let state: ModelCatalogState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .loading:
            ProgressView("Loading available models…")
        case .ready:
            // Callers show their pickers instead; never a spinner that
            // can't end.
            EmptyView()
        case .failed:
            Text(AppLocalization.string("Could not load models."))
                .font(.footnote).foregroundStyle(.secondary)
            Button(AppLocalization.string("Try Again"), action: retry)
                .buttonStyle(.settings)
        case .empty:
            Text("No models are available from this gateway.")
                .font(.footnote).foregroundStyle(.secondary)
        }
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
    @State private var loadFailed = false

    private var models: [ModelInfo] { defaults?.providers.first(where: { $0.name == provider })?.models ?? [] }
    /// Keeps a saved model the catalog no longer lists visible instead of
    /// silently showing a different one.
    private var modelChoices: [(id: String, title: String)] {
        let listed = models.map { (id: $0.id, title: $0.label ?? $0.id) }
        return model.isEmpty || models.contains(where: { $0.id == model }) ? listed : [(id: model, title: model)] + listed
    }

    /// Keeps a saved provider the catalog does not list (e.g. `auto`)
    /// visible instead of showing the first provider. Exact `name` equality
    /// is enough: `provider` only ever holds a row's `name` (from `selection`
    /// or a menu pick) or a saved value no row matched.
    private func providerChoices(_ providers: [ProviderInfo]) -> [(id: String, title: String)] {
        let listed = providers.map { (id: $0.name, title: $0.title) }
        return provider.isEmpty || providers.contains(where: { $0.name == provider }) ? listed : [(id: provider, title: provider)] + listed
    }

    /// The top of the Model page; the page around it scrolls and titles it.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ConduitSettingsSection(title: AppLocalization.string("Default model"), symbol: "cpu", tint: .conduitAccent) {
                Text("Select a provider first, then one of its available models. These defaults apply to new sessions in this profile.")
                    .font(.footnote).foregroundStyle(.secondary)
                let catalog = ModelCatalogState.of(providers: defaults?.providers, failed: loadFailed)
                if catalog == .ready, let defaults {
                    ConduitMenuPicker(
                        value: provider,
                        choices: providerChoices(defaults.providers),
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
                    ModelCatalogPlaceholder(state: catalog) { Task { await reload() } }
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
        .task { await reload() }
    }

    private func reload() async {
        loadFailed = false
        guard let loaded = await load() else {
            loadFailed = true
            return
        }
        defaults = loaded
        (provider, model) = loaded.selection
        reasoning = loaded.reasoning
    }
    /// Menus fire on the current item too; re-picking it must not swap out
    /// a saved model.
    private func chooseProvider(_ next: String) {
        guard next != provider else { return }
        provider = next
        // The unlisted saved entry has no model list, so keep the model.
        // Otherwise keep a model the new provider also lists (e.g. one saved
        // with no provider) rather than swapping it for the row's first model.
        guard let models = defaults?.providers.first(where: { $0.name == next })?.models else { return }
        if !models.contains(where: { $0.id == model }) {
            model = models.first?.id ?? ""
        }
    }
    private func persist() {
        Task {
            guard defaults != nil else { return }
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
    @State private var loadFailed = false
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
            let catalog = ModelCatalogState.of(providers: defaults?.providers, failed: loadFailed)
            if catalog == .ready {
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
            } else {
                ModelCatalogPlaceholder(state: catalog) { Task { await reload() } }
            }
            Button { persist() } label: { Label(saving ? AppLocalization.string("Saving…") : AppLocalization.string("Save delegate defaults"), systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 42) }
                .disabled(saving || defaults == nil).conduitGlassControl(cornerRadius: 15, tint: .conduitAccent.opacity(0.18))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { await reload() }
    }

    private func reload() async {
        loadFailed = false
        async let modelRequest = loadModels()
        async let settingRequest = loadSettings(["delegation.provider", "delegation.model", "delegation.reasoning_effort"])
        let (loaded, settings) = await (modelRequest, settingRequest)
        // A catalog that didn't load says so, with Try Again, instead of
        // loading forever; a re-load that fails keeps the one it had.
        if let loaded { defaults = loaded } else { loadFailed = true }
        let configuredProvider = settings["delegation.provider"]?.textValue ?? ""
        let configuredModel = settings["delegation.model"]?.textValue ?? ""
        (provider, model) = loaded?.delegateSelection(provider: configuredProvider, model: configuredModel)
            ?? (configuredProvider, configuredModel)
        reasoning = settings["delegation.reasoning_effort"]?.textValue ?? ""
    }
    private func chooseProvider(_ next: String) {
        guard next != provider else { return }
        provider = next
        guard !next.isEmpty else {
            model = ""
            return
        }
        guard let models = defaults?.providers.first(where: { $0.name == next })?.models else { return }
        if !models.contains(where: { $0.id == model }) {
            model = models.first?.id ?? ""
        }
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

/// Holds new delegate agents on the whole Hermes (`delegation.pause`,
/// #820). Agents already working carry on.
private struct DelegationPauseSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let load: () async -> Bool?
    let save: (Bool) async -> Bool?
    @State private var paused: Bool?
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Pause delegation"), symbol: "pause.circle", tint: .orange) {
            if let paused {
                Toggle(isOn: Binding(get: { paused }, set: { change(to: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause new delegate agents").font(.subheadline.weight(.medium))
                        Text("Hermes starts no new delegate agents while this is on. Agents already working carry on. This applies to every profile on this Hermes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.conduitAccent)
                .disabled(saving)
                .padding(.vertical, 2)
                .accessibilityIdentifier("settings.delegationPause")
            } else if loaded {
                Text("This Hermes can't pause delegation, or Conduit isn't connected.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { Task { await reload() } } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.settings)
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { await reload() }
    }

    private func reload() async {
        loaded = false
        paused = await load()
        loaded = true
    }

    private func change(to next: Bool) {
        guard !saving else { return }
        saving = true
        Task {
            error = nil
            if let state = await save(next) {
                paused = state
            } else {
                error = AppLocalization.string("Could not change the delegation pause.")
            }
            saving = false
        }
    }
}

/// The Model page's `fallback_providers`: the models Hermes tries, in
/// order, when the default model fails.
private struct FallbackModelsSettings: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let loadModels: () async -> ProfileModelDefaults?
    let load: () async -> [ProfileFallbackModel]?
    let save: ([ProfileFallbackModel]) async -> Bool
    @State private var defaults: ProfileModelDefaults?
    @State private var entries: [ProfileFallbackModel] = []
    @State private var saved: [ProfileFallbackModel] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    private var providers: [ProviderInfo] { defaults?.providers ?? [] }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Fallback models"), symbol: "arrow.triangle.branch", tint: .conduitAura) {
            Text("If the default model fails, Hermes tries these in order.")
                .font(.footnote).foregroundStyle(.secondary)
            if !loaded {
                // A list that didn't load is never edited: saving it would
                // replace the real one.
                if error == nil {
                    ProgressView("Loading available models…")
                } else {
                    Button(AppLocalization.string("Try Again")) { Task { await reload() } }
                        .buttonStyle(.settings)
                }
            } else {
                if entries.isEmpty {
                    Text("No fallback models yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    entryRow(index: index, entry: entry)
                }
                AdaptiveStack(spacing: 8) {
                    Button { addEntry() } label: { Label(AppLocalization.string("Add fallback"), systemImage: "plus") }
                        .buttonStyle(.settings)
                        .disabled(saving || providers.isEmpty)
                    Button(saving ? AppLocalization.string("Saving…") : AppLocalization.string("Save fallbacks")) { persist() }
                        .buttonStyle(.settingsPrimary)
                        .disabled(saving || entries == saved || entries.contains { !$0.isComplete })
                }
                if entries.contains(where: { !$0.isComplete }) {
                    Text("Pick a provider and model for every fallback to save.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { await reload() }
    }

    private func entryRow(index: Int, entry: ProfileFallbackModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppLocalization.string("Fallback \(String(index + 1))"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    if index > 0 {
                        Button { move(entry.id, by: -1) } label: { Label(AppLocalization.string("Move up"), systemImage: "arrow.up") }
                    }
                    if index < entries.count - 1 {
                        Button { move(entry.id, by: 1) } label: { Label(AppLocalization.string("Move down"), systemImage: "arrow.down") }
                    }
                    Button(role: .destructive) { entries.removeAll { $0.id == entry.id } } label: { Label(AppLocalization.string("Delete"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(AppLocalization.string("More")))
                .accessibilityValue(Text(verbatim: entry.model))
            }
            ConduitMenuPicker(value: entry.provider, choices: providerChoices(entry), onSelect: { chooseProvider($0, for: entry.id) }) {
                Text("Provider").foregroundStyle(.secondary)
            }
            ConduitMenuPicker(value: entry.model, choices: modelChoices(entry), onSelect: { chooseModel($0, for: entry.id) }) {
                Text("Model").foregroundStyle(.secondary)
            }
            .disabled(modelChoices(entry).isEmpty)
        }
    }

    /// A provider or model the catalog doesn't list stays visible, so a
    /// hand-written entry is never shown as a different one.
    private func providerChoices(_ entry: ProfileFallbackModel) -> [(id: String, title: String)] {
        let listed = providers.map { (id: $0.name, title: $0.title) }
        return entry.provider.isEmpty || listed.contains(where: { $0.id == entry.provider }) ? listed : [(id: entry.provider, title: entry.provider)] + listed
    }

    private func modelChoices(_ entry: ProfileFallbackModel) -> [(id: String, title: String)] {
        let models = providers.first(where: { $0.name == entry.provider })?.models ?? []
        let listed = models.map { (id: $0.id, title: $0.label ?? $0.id) }
        return entry.model.isEmpty || listed.contains(where: { $0.id == entry.model }) ? listed : [(id: entry.model, title: entry.model)] + listed
    }

    /// Menus act on the entry they were drawn for, found again by id: the
    /// row may have moved or gone while the menu was open.
    private func chooseModel(_ next: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].model = next
    }

    private func chooseProvider(_ next: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), next != entries[index].provider else { return }
        entries[index].provider = next
        let models = providers.first(where: { $0.name == next })?.models ?? []
        if !models.contains(where: { $0.id == entries[index].model }) {
            entries[index].model = models.first?.id ?? ""
        }
        // Routing written for the old provider would send the new one to
        // the wrong endpoint.
        entries[index].extras = [:]
    }

    private func addEntry() {
        guard let row = providers.first(where: { !$0.isCurrent }) ?? providers.first else { return }
        entries.append(ProfileFallbackModel(provider: row.name, model: row.models.first?.id ?? ""))
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }

    private func reload() async {
        error = nil
        async let modelRequest = loadModels()
        async let entryRequest = load()
        let (models, loadedEntries) = await (modelRequest, entryRequest)
        // Without the model catalog no fallback can be added or changed, so
        // a half-loaded list fails with Try Again instead of a silently
        // disabled Add. A re-load (the editor re-appearing) that fails keeps
        // the catalog and rows it already had: only the error is new.
        guard let loadedEntries, let models else {
            error = AppLocalization.string("Could not load fallback models.")
            return
        }
        defaults = models
        // A re-load keeps fallbacks the user is still editing, but what
        // they compare against is what the host holds now: an edit changed
        // back to the old list still differs from another client's save.
        if !loaded || entries == saved {
            entries = loadedEntries
        }
        saved = loadedEntries
        loaded = true
    }

    private func persist() {
        Task {
            saving = true
            error = nil
            let next = entries
            if await save(next) {
                saved = next
            } else {
                error = AppLocalization.string("Could not save fallback models.")
            }
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
    let loadSchema: () async -> ProfileConfigSchema
    let sections: [ProfileSettingSection]
    let loadDelegationPaused: () async -> Bool?
    let setDelegationPaused: (Bool) async -> Bool?
    @State private var options = ProfileConfigOptions()

    var body: some View {
        ProfileConfigSettingsPage(
            title: AppLocalization.string("Memory & delegation"),
            subtitle: AppLocalization.string("Long-term context and delegate-agent defaults."),
            fields: [],
            load: load,
            save: save,
            optionOverrides: ["memory.provider": options.memoryProviders, "context.engine": options.contextEngines],
            trailingSection: AnyView(
                VStack(spacing: 24) {
                    DelegationModelSettings(loadModels: loadModels, loadSettings: load, save: save)
                    DelegationPauseSettings(load: loadDelegationPaused, save: setDelegationPaused)
                }
            ),
            sections: sections,
            loadSchema: loadSchema
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
        "agent.service_tier": ["normal": "Off", "fast": "Always", "auto": "Start of each turn", "cold": "First turn only", "ultrafast": "Ultrafast"],
        "updates.non_interactive_local_changes": ["stash": "Keep them", "discard": "Throw them away"],
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
    /// Names the fields' card when other sections share the page.
    var fieldsHeader: String? = nil
    var leadingSection: AnyView? = nil
    var trailingSection: AnyView? = nil
    /// More titled cards after the fields' card, loaded and saved with it.
    var sections: [ProfileSettingSection] = []
    /// The gateway's config schema, which hides settings this Hermes lacks
    /// and fills in runtime choices.
    var loadSchema: (() async -> ProfileConfigSchema)? = nil
    /// Choices a field gains beyond its schema's, loaded with the page.
    var loadExtraOptions: (() async -> [String: [String]])? = nil
    /// Changing it reloads the extra choices.
    var extraOptionsRefresh = 0

    @State private var extraOptions: [String: [String]] = [:]
    @State private var values: [String: ProfileSettingValue] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var schema = ProfileConfigSchema()
    @State private var loading = true
    @State private var savingKey: String?
    /// Each field's last save problem, shown in its own card.
    @State private var fieldErrors: [String: String] = [:]
    /// The field whose save just landed, for a brief "Saved".
    @State private var savedKey: String?
    @State private var savedToken = UUID()
    @FocusState private var focusedKey: String?

    /// How long "Saved" stays up after a save lands.
    private static let savedConfirmationDuration: Duration = .seconds(2)

    var body: some View {
        SettingsDetailContainer {
            if let leadingSection { leadingSection }
            if !subtitle.isEmpty {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            if loading {
                ProgressView("Loading profile settings…").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(cards) { card in
                    fieldsCard(card)
                }
            }
            if let trailingSection { trailingSection }
        }
        .navigationTitle(showsNavigationTitle ? title : "")
        .task { await reload() }
        // Also the first load. A newer refresh cancels an older one, so a
        // slow read for the previous model can't land last.
        .task(id: extraOptionsRefresh) {
            let options = await loadExtras()
            guard !Task.isCancelled else { return }
            extraOptions = options
        }
    }

    private struct FieldsCard: Identifiable {
        let id: Int
        let title: String?
        let symbol: String
        let fields: [ProfileSettingField]
    }

    /// The fields' card, then each extra section, with the settings this
    /// gateway's schema lacks taken out and empty cards dropped.
    private var cards: [FieldsCard] {
        let all: [(title: String?, symbol: String, fields: [ProfileSettingField])] =
            [(title: fieldsHeader, symbol: "gearshape.2", fields: fields)]
            + sections.map { (title: $0.title, symbol: $0.symbol, fields: $0.fields) }
        return all.enumerated().compactMap { index, card -> FieldsCard? in
            let shown = card.fields.compactMap { $0.resolved(with: schema) }
            return shown.isEmpty ? nil : FieldsCard(id: index, title: card.title, symbol: card.symbol, fields: shown)
        }
    }

    private var allFields: [ProfileSettingField] { fields + sections.flatMap(\.fields) }

    /// One card of rows, a hairline between them, each setting's name and
    /// what it does beside its control.
    private func fieldsCard(_ card: FieldsCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = card.title {
                SettingsSectionHeader(title: title, symbol: card.symbol, tint: .conduitAura)
            }
            VStack(spacing: 0) {
                ForEach(Array(card.fields.enumerated()), id: \.element.id) { index, field in
                    fieldRow(field)
                        .padding(16)
                        .overlay(alignment: .top) {
                            if index > 0 { V2RowDivider(leadingInset: 16) }
                        }
                }
            }
            .settingsCard()
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: ProfileSettingField) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch field.control {
            case .toggle(let defaultValue):
                Toggle(isOn: Binding(get: { boolValue(field.key, defaultValue: defaultValue) }, set: { save(field, value: .bool($0)) })) {
                    fieldLabel(field)
                }
                .tint(.conduitAccent).disabled(savingKey != nil)
            case .textToggle(let onValue, let offValue, let defaultValue):
                Toggle(isOn: Binding(
                    get: { textValue(field.key, defaultValue: defaultValue ? onValue : offValue) != offValue },
                    set: { save(field, value: .text($0 ? onValue : offValue)) }
                )) {
                    fieldLabel(field)
                }
                .tint(.conduitAccent).disabled(savingKey != nil)
            case .options(let options, let defaultValue):
                fieldLabel(field)
                // A runtime list that came back empty falls back to the schema's.
                let baseChoices = optionOverrides[field.key].flatMap { $0.isEmpty ? nil : $0 } ?? options
                let choices = baseChoices + (extraOptions[field.key] ?? []).filter { !baseChoices.contains($0) }
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
                .accessibilityLabel(Text(field.label))
                .accessibilityValue(Text(ProfileConfigValueDisplay.label(forFieldKey: field.key, displayedValue)))
                if choices.isEmpty { Text("No configured choices are available.").font(.caption).foregroundStyle(.secondary) }
            case .labeledOptions(let options, let defaultValue):
                fieldLabel(field)
                let selectedValue = textValue(field.key, defaultValue: defaultValue)
                let displayedValue = options.first(where: { $0.value == selectedValue })?.label ?? selectedValue
                Menu {
                    ForEach(options, id: \.value) { option in
                        Button(option.label) { save(field, value: .text(option.value)) }
                    }
                } label: {
                    HStack { Text(displayedValue); Spacer(); Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary) }
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 42)
                }
                .disabled(savingKey != nil || options.isEmpty).conduitGlassControl(cornerRadius: 14)
                .accessibilityLabel(Text(field.label))
                .accessibilityValue(Text(displayedValue))
            case .text(let defaultValue):
                fieldLabel(field)
                textEditor(field, defaultValue: defaultValue, keyboard: .default)
            case .number(let defaultValue):
                fieldLabel(field)
                textEditor(field, defaultValue: ProfileSettingValue.numberText(defaultValue), keyboard: .decimalPad)
            case .stringList:
                fieldLabel(field)
                listEditor(field)
            case .timeZone:
                fieldLabel(field)
                textEditor(field, defaultValue: "", keyboard: .asciiCapable, placeholder: AppLocalization.string("Server's local time"))
                timeZoneShortcuts(field)
            }
            saveStatus(field)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A setting's name over what it does.
    private func fieldLabel(_ field: ProfileSettingField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(field.help)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Saving…, a brief Saved, or what went wrong, under the field it is about.
    @ViewBuilder
    private func saveStatus(_ field: ProfileSettingField) -> some View {
        if savingKey == field.key {
            HStack { ProgressView().controlSize(.small); Text("Saving…").font(.caption).foregroundStyle(.secondary) }
        } else if let message = fieldErrors[field.key] {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        } else if savedKey == field.key {
            Label(AppLocalization.string("Saved"), systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .transition(.opacity)
        }
    }

    private func textEditor(_ field: ProfileSettingField, defaultValue: String, keyboard: UIKeyboardType, placeholder: String? = nil) -> some View {
        AdaptiveStack(spacing: 8) {
            TextField(placeholder ?? field.label, text: Binding(
                get: { drafts[field.key] ?? textValue(field.key, defaultValue: defaultValue) },
                set: {
                    drafts[field.key] = $0
                    fieldErrors[field.key] = nil
                }
            ))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
                .focused($focusedKey, equals: field.key)
                .submitLabel(.done)
                .onSubmit { saveDraft(field, defaultValue: defaultValue) }
                .padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 42).conduitGlassSurface(cornerRadius: 14)
                // VoiceOver names the field, not its placeholder.
                .accessibilityLabel(Text(field.label))
            Button("Save") { saveDraft(field, defaultValue: defaultValue) }
                .buttonStyle(.settingsPrimary).disabled(savingKey != nil)
                .accessibilityLabel(Text(AppLocalization.string("Save \(field.label)")))
        }
    }

    /// One entry per line; blank lines are dropped on save.
    private func listEditor(_ field: ProfileSettingField) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField(field.label, text: Binding(get: { drafts[field.key] ?? textValue(field.key, defaultValue: "") }, set: { drafts[field.key] = $0 }), axis: .vertical)
                .lineLimit(3...8)
                .font(.subheadline.monospaced())
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 42).conduitGlassSurface(cornerRadius: 14)
            Button("Save") {
                let raw = drafts[field.key] ?? textValue(field.key, defaultValue: "")
                save(field, value: .list(Self.listEntries(raw)))
            }
            .buttonStyle(.settingsPrimary).disabled(savingKey != nil)
            .accessibilityLabel(Text(AppLocalization.string("Save \(field.label)")))
        }
    }

    nonisolated static func listEntries(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One tap to this iPhone's zone, or back to the server's own time.
    @ViewBuilder
    private func timeZoneShortcuts(_ field: ProfileSettingField) -> some View {
        let saved = textValue(field.key, defaultValue: "")
        let device = TimeZone.current.identifier
        VStack(alignment: .leading, spacing: 6) {
            if !ProfileTimeZone.matches(saved, device), case .identifier(let id) = ProfileTimeZone.resolve(device) {
                Button {
                    drafts[field.key] = id
                    commitText(field, value: id)
                } label: {
                    Label(AppLocalization.string("Use this iPhone's time zone (\(id))"), systemImage: "location")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(savingKey != nil)
            }
            if !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    drafts[field.key] = ""
                    commitText(field, value: "")
                } label: {
                    Label(AppLocalization.string("Use the server's local time"), systemImage: "server.rack")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(savingKey != nil)
            }
        }
        .buttonStyle(.borderless)
        .tint(.conduitAccent)
    }

    private func saveDraft(_ field: ProfileSettingField, defaultValue: String) {
        // Return in a field while a save is on its way: the buttons are
        // disabled, and this waits the same way.
        guard savingKey == nil else { return }
        let raw = drafts[field.key] ?? textValue(field.key, defaultValue: defaultValue)
        switch field.control {
        case .number:
            guard let number = ProfileSettingValue.parseNumber(raw) else {
                fieldErrors[field.key] = AppLocalization.string("Enter a valid number for \(field.label).")
                return
            }
            focusedKey = nil
            save(field, value: .number(number))
        case .timeZone:
            guard let value = ProfileTimeZone.resolve(raw).storedValue else {
                fieldErrors[field.key] = AppLocalization.string("That isn't a time zone name. Use one like America/Toronto or Europe/Paris, or leave it blank for the server's local time.")
                return
            }
            drafts[field.key] = value
            commitText(field, value: value)
        default:
            commitText(field, value: raw)
        }
    }

    private func commitText(_ field: ProfileSettingField, value: String) {
        focusedKey = nil
        save(field, value: .text(value))
    }

    private func reload() async {
        loading = true
        let fields = allFields
        async let valuesRequest = load(fields.map(\.key))
        schema = await loadSchema?() ?? ProfileConfigSchema()
        values = await valuesRequest
        for field in fields { drafts[field.key] = values[field.key]?.textValue }
        loading = false
    }

    private func loadExtras() async -> [String: [String]] {
        await loadExtraOptions?() ?? [:]
    }

    private func save(_ field: ProfileSettingField, value: ProfileSettingValue) {
        // One save at a time: an older one failing after a newer one landed
        // would put back the value from before both.
        guard savingKey == nil else { return }
        let previous = values[field.key]
        values[field.key] = value
        fieldErrors[field.key] = nil
        if savedKey == field.key { savedKey = nil }
        savingKey = field.key
        Task {
            guard await save(field.key, value) else {
                values[field.key] = previous
                fieldErrors[field.key] = AppLocalization.string("Could not save \(field.label).")
                savingKey = nil
                return
            }
            savingKey = nil
            let token = UUID()
            savedToken = token
            withAnimation { savedKey = field.key }
            try? await Task.sleep(for: Self.savedConfirmationDuration)
            guard savedToken == token else { return }
            withAnimation { savedKey = nil }
        }
    }

    private func boolValue(_ key: String, defaultValue: Bool) -> Bool { values[key]?.boolValue ?? defaultValue }
    private func textValue(_ key: String, defaultValue: String) -> String { values[key]?.textValue ?? defaultValue }
}

private struct GatewaySettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let title: String
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clientSecret = ""
    @State private var confirmingRestart = false

    init(title: String, snapshot: SettingsSnapshot, reconnect: @escaping () async -> Bool, disconnect: @escaping () -> Void, close: @escaping () -> Void, saveCloudflareAccess: @escaping (String, String) -> Void, removeCloudflareAccess: @escaping () -> Void, customHeaders: [CustomHeader], saveCustomHeaders: @escaping ([CustomHeader]) -> Void) {
        self.title = title; self.snapshot = snapshot; self.reconnect = reconnect; self.disconnect = disconnect; self.close = close
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
                // The gateway's state, connectors, last connection and logs,
                // which the chat header used to open.
                NavigationLink {
                    GatewayDiagnosticsSheet(embedded: true)
                        .v2TabBarClearance()
                } label: {
                    Label(AppLocalization.string("Diagnostics & logs"), systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                }
                .disabled(snapshot.server == nil)
                .accessibilityIdentifier("settings.gateway.diagnostics")
            }
            ConduitSettingsSection(title: "Cloudflare Access", symbol: "shield.lefthalf.filled", tint: .conduitAccent) {
                Toggle("Use service token", isOn: Binding(get: { cloudflareEnabled }, set: { enabled in
                    withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { cloudflareEnabled = enabled }
                    if !enabled { clientSecret = ""; removeCloudflareAccess() }
                }))
                if cloudflareEnabled {
                    TextField("Client ID", text: $clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                    Button("Save token") { saveCloudflareAccess(clientID, clientSecret); clientSecret = "" }
                        .buttonStyle(.settingsPrimary)
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
        .navigationTitle(title)
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
    @AppStorage(V2ShellPreference.key) private var usesV2 = V2ShellPreference.defaultValue
    @AppStorage(V2MainButtonPreference.key) private var mainButtonNewChat = V2MainButtonPreference.defaultValue
    @AppStorage(V2ChatListPreference.key) private var chatListBeside = V2ChatListPreference.defaultValue
    @AppStorage(ChatVoiceButtonAction.key) private var chatVoiceButton = ChatVoiceButtonAction.defaultValue.rawValue
    @AppStorage(ProjectChatsInChats.key) private var projectChats = ProjectChatsInChats.deviceDefault()
    @AppStorage(ConduitAccent.storageKey) private var accentChoice = ConduitAccent.defaultValue
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
            ConduitSettingsSection(title: AppLocalization.string("Accent color"), symbol: "paintpalette", tint: .conduitAccent) {
                Text("Choose the color of your own messages and Conduit’s highlights.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                AccentColorPicker(selection: $accentChoice)
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

            // The gold button beside V2's tabs: voice, or New chat for
            // people who'd rather not talk. A chat keeps its voice button.
            if usesV2 {
                ConduitSettingsSection(title: AppLocalization.string("Main button"), symbol: "circle.circle.fill", tint: .conduitAccent) {
                    Text("Choose what the round button beside the tabs does. The other one moves to the top bar, and a chat keeps its voice button.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Main button", selection: Binding(get: { mainButtonNewChat }, set: {
                        Haptics.selection()
                        mainButtonNewChat = $0
                    })) {
                        Text("Voice").tag(false)
                        Text("New Chat").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                // The big button beside a chat's composer. A profile can
                // choose its own in Settings > Voice.
                ConduitSettingsSection(title: AppLocalization.string("Chat voice button"), symbol: "mic.circle", tint: .conduitAccent) {
                    Text("Choose what the round button beside a chat's message box does. A live call stays in the chat's top bar and in the button's touch-and-hold menu. Each profile can choose its own in Voice settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Chat voice button", selection: Binding(
                        get: { ChatVoiceButtonAction.resolved(profile: nil, app: chatVoiceButton) },
                        set: {
                            Haptics.selection()
                            chatVoiceButton = $0.rawValue
                        }
                    )) {
                        ForEach(ChatVoiceButtonAction.offered, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    // Three choices whose names run long in some languages.
                    .pickerStyle(.menu)
                }

                // A project's chats otherwise show only on its page.
                ConduitSettingsSection(title: AppLocalization.string("Project chats"), symbol: "folder", tint: .conduitAccent) {
                    Text("Choose whether chats inside a project also appear in Chats, with the project’s name under the title. Recent shows the ones active today or yesterday. To leave some projects out, untick them in Filter > Projects.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Project chats", selection: Binding(get: { projectChats }, set: {
                        Haptics.selection()
                        projectChats = $0
                    })) {
                        Text("Off").tag(ProjectChatsInChats.hidden)
                        Text("Recent").tag(ProjectChatsInChats.recent)
                        Text("All").tag(ProjectChatsInChats.all)
                    }
                    .pickerStyle(.segmented)
                }
            }

            // V2's wide windows: the list beside the open chat, or the
            // chat on its own (#1164). The chat's top bar switches it too.
            if isPad, usesV2 {
                ConduitSettingsSection(title: AppLocalization.string("Layout"), symbol: "sidebar.left", tint: .conduitAura) {
                    Text("Choose whether Chats and Bots keep their list beside the open chat when the window is wide enough. The sidebar button at the top of a chat switches it too.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Chat list", selection: Binding(get: { chatListBeside }, set: {
                        Haptics.selection()
                        chatListBeside = $0
                    })) {
                        Text("Beside chat").tag(true)
                        Text("Hidden").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            } else if isPad {
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

/// One swatch per preset accent (#697), then a colour of the user's own;
/// the pick redraws the app in place.
private struct AccentColorPicker: View {
    @Binding var selection: ConduitAccent
    @Environment(\.colorScheme) private var colorScheme
    /// The last colour of the user's own, kept while a preset is picked so
    /// the custom swatch reopens on it.
    @AppStorage(CustomAccentColor.lastPickKey) private var lastCustomHex = CustomAccentColor.firstPick.hex

    private var isCustom: Bool {
        if case .custom = selection { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                ForEach(ConduitAccentChoice.allCases) { choice in
                    presetSwatch(choice)
                }
                customSwatch
            }
            .conduitFixedGlyph()
            if isCustom {
                Text("Your color is adjusted where needed so text stays readable in light and dark mode.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                AccentPreview()
            }
        }
        // A custom colour that arrives from another device is the one the
        // custom swatch reopens on too.
        .onChange(of: selection) { _, newSelection in
            if case .custom(let custom) = newSelection { lastCustomHex = custom.hex }
        }
    }

    private func presetSwatch(_ choice: ConduitAccentChoice) -> some View {
        let isSelected = selection == .preset(choice)
        let fill = choice.color(dark: colorScheme == .dark)
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            selection = .preset(choice)
        } label: {
            Circle()
                .fill(Color(uiColor: fill))
                .frame(width: 32, height: 32)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color(uiColor: ConduitAccentChoice.markColor(on: fill)))
                    }
                }
                .modifier(AccentSwatchFrame(isSelected: isSelected))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The system colour picker, its well in the swatch row. Picking in it
    /// selects the custom accent; tapping the well again reopens the pick.
    private var customSwatch: some View {
        ColorPicker(selection: customColor, supportsOpacity: false) {
            Text("Custom color")
        }
        .labelsHidden()
        .frame(width: 32, height: 32)
        .modifier(AccentSwatchFrame(isSelected: isCustom))
        .accessibilityAddTraits(isCustom ? .isSelected : [])
    }

    private var customColor: Binding<Color> {
        Binding(
            get: {
                let pick: CustomAccentColor
                if case .custom(let custom) = selection {
                    pick = custom
                } else {
                    pick = CustomAccentColor(hex: lastCustomHex) ?? CustomAccentColor.firstPick
                }
                return Color(uiColor: UIColor(pick.picked))
            },
            set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
                // The picker can hand back Display P3; stored components are sRGB.
                let srgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap {
                    UIColor(color).cgColor.converted(to: $0, intent: .defaultIntent, options: nil)
                }
                if let components = srgb?.components, components.count >= 3 {
                    (red, green, blue) = (components[0], components[1], components[2])
                }
                let pick = CustomAccentColor(red: red, green: green, blue: blue)
                guard selection != .custom(pick) else { return }
                if !isCustom { Haptics.selection() }
                lastCustomHex = pick.hex
                selection = .custom(pick)
            }
        )
    }
}

/// A swatch's ring when picked, and its full-width 44 pt hit region.
private struct AccentSwatchFrame: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(4)
            .overlay {
                Circle()
                    .strokeBorder(isSelected ? Color.primary.opacity(0.55) : .clear, lineWidth: 2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A sent message and accent text, drawn as the app will draw them, so a
/// colour of the user's own shows its adjusted shades.
private struct AccentPreview: View {
    var body: some View {
        HStack(spacing: 12) {
            Label("Highlights", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
            Spacer(minLength: 8)
            Text("Your messages")
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [.conduitUserBubble, .conduitUserBubbleShade],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
        .accessibilityElement(children: .combine)
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
    @State private var pairing = false
    @State private var pairingError: String?
    /// What the last Pair tap did, kept on screen: a haptic alone left
    /// people unsure anything happened.
    @State private var pairedProfile: String?
    @AppStorage(LiveTurnActivities.enabledDefaultsKey) private var liveActivitiesEnabled = true

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
                            // Just turned on: pair this dashboard's profile
                            // now rather than on the next connect.
                            if notifications.isEnabled { await appState.refreshNotifierPluginStatus() }
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
                .disabled(notifications.isWorking || notifications.isPairing)
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

            // #605: a running turn on the Lock Screen and in the Dynamic
            // Island. Updated by Conduit while it runs; in the background
            // only through the relay, so it needs notifications on.
            ConduitSettingsSection(title: AppLocalization.string("Lock Screen"), symbol: "lock.iphone", tint: .conduitAccent) {
                Toggle(isOn: Binding(
                    get: { liveActivitiesEnabled },
                    set: { value in
                        Haptics.selection()
                        liveActivitiesEnabled = value
                        if !value { LiveTurnActivities.shared.endAll() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalization.string("Show progress on the Lock Screen"))
                        Text(AppLocalization.string("While Hermes works on a message you sent: what it's doing, how long it has run, its tools and context. Keeps updating in the background when notifications are on."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.conduitAccent)
                .accessibilityIdentifier("notifications.live-activities")
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
                    notificationDetailPicker
                    notificationToggle(AppLocalization.string("Approval cards in pushes"), detail: AppLocalization.string("Include approval details so cards work from notifications. Disable for maximum privacy."), keyPath: \.decisionCards)
                }

                // #115: which sources' replies notify, per profile on the host.
                if notifications.preferences.responseReady, appState.activeDashboardID != nil,
                   appState.notifierPlugin.reports(ReplySourcesClient.capability) {
                    ReplySourcesSettingsSection()
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
                    // The plugin itself has its own page; here only a way there
                    // when it needs attention.
                    if appState.notifierPlugin.needsAttention {
                        // Missing, or on the host but not running: nothing to update.
                        pluginPageLink(appState.notifierPlugin.offersInstall || appState.notifierPlugin.isNotServed
                            ? AppLocalization.string("Open Conduit plugin")
                            : AppLocalization.string("Update the Conduit plugin"))
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
                            savedDashboardIDs: appState.savedDashboardRegistry.dashboards.map(\.id),
                            activeDashboardGatewayIDs: appState.activeDashboardRelayGatewayIDs
                        )
                        // Without a selected dashboard there is nothing to
                        // pair yet (and `pairings` is empty); the pairing
                        // section says to connect.
                        if pairings.thisDashboard.isEmpty, appState.activeDashboardID != nil {
                            compatibilityRow(
                                title: AppLocalization.string("Not paired"),
                                version: nil,
                                mark: .actionNeeded,
                                detail: appState.notifierPlugin.reports("pairing")
                                    ? AppLocalization.string("Notifications from this dashboard don't reach this iPhone yet. Pair it below.")
                                    : AppLocalization.string("Notifications from this dashboard don't reach this iPhone yet. Create a pairing code below.")
                            )
                        }
                        ForEach(pairings.thisDashboard) { gateway in
                            gatewayRow(gateway)
                        }
                        if notifications.canRotateEncryptionKeys(gatewayIDs: pairings.thisDashboard.map(\.id)) {
                            Button {
                                notifications.requestEncryptionKeyRotation()
                                Task { await appState.provisionNotificationEncryptionNow() }
                            } label: {
                                Label(AppLocalization.string("Rotate encryption keys"), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .font(.footnote)
                            // A tap while keys are being set up would only
                            // wait for the next connect.
                            .disabled(notifications.isProvisioningEncryption)
                            Text("Conduit gives this dashboard's hosts new keys by itself every 7 days. The old keys still open notifications already on their way for 7 days.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        // One host, one set of commands, however many of its
                        // pairings are behind. The host row above already
                        // offers them when the plugin itself reports it is
                        // behind.
                        if !appState.notifierPlugin.needsAttention,
                           pairings.thisDashboard.contains(where: Self.isOutdated) {
                            pluginPageLink(AppLocalization.string("Update the Conduit plugin"))
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
                    } else if notifications.relayMetaFetchFailed {
                        Text("Couldn't reach the push relay to check compatibility.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                    await appState.refreshNotifierPluginStatus()
                }

                ConduitSettingsSection(title: AppLocalization.string("Connect a Hermes profile"), symbol: "link.badge.plus", tint: .conduitAura) {
                    if appState.notifierPlugin.reports("pairing") {
                        oneTapPairing
                    } else {
                        // Installed but not running: installing again can't help.
                        if appState.notifierPlugin.isNotServed {
                            Text("Installed on this dashboard's host, but the dashboard doesn't run it. Turn it on in Hermes, then restart the gateway and the dashboard.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            pluginPageLink(AppLocalization.string("Open Conduit plugin"))
                        } else {
                            Text("Install the Conduit plugin on each dashboard's host, then create a short-lived pairing code here for each Hermes dashboard you want to reach.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            pluginPageLink(AppLocalization.string("Install or update the Conduit plugin"))
                        }
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
                        .disabled(notifications.isWorking || notifications.isPairing || appState.activeDashboardID == nil)
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
                TextField(PushNotificationService.defaultRelayURL.absoluteString, text: $relayDraft)
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

    /// A row that opens Settings > Conduit plugin.
    private func pluginPageLink(_ title: String) -> some View {
        NavigationLink(value: SettingsDestination.conduitPlugin) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("notifications.plugin-link")
    }

    /// Plugin 0.24+: this profile pairs with one tap, no code to type.
    /// Conduit also does it by itself on connect when nothing receives this
    /// profile's notifications yet.
    @ViewBuilder
    private var oneTapPairing: some View {
        let profile = appState.activeProfile
        Text("Conduit pairs this dashboard's profile by itself. If it says another iPhone is paired, pairing here moves its notifications to this one.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Button {
            Task {
                pairing = true
                pairingError = nil
                pairedProfile = nil
                do {
                    try await appState.pairProfileWithThisDevice(profile)
                    pairedProfile = profile
                    Haptics.success()
                } catch {
                    pairingError = UserFacingError.message(for: error)
                    Haptics.error()
                }
                pairing = false
            }
        } label: {
            Label(
                // The automatic pairing runs on the same flag and holds the
                // button too, so it says so rather than looking stuck.
                pairing || notifications.isPairing ? AppLocalization.string("Pairing…") : AppLocalization.string("Pair \(profile) with this iPhone"),
                systemImage: "link"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6).frame(minHeight: 46)
        }
        .disabled(pairing || notifications.isPairing || notifications.isWorking || appState.activeDashboardID == nil
                  || !notifications.isEnabled)
        .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.16))
        .accessibilityIdentifier("notifications.pair")
        if !notifications.isEnabled {
            Text("Turn on notifications above to pair this profile.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let pairingError {
            Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        } else if let pairedProfile, pairedProfile == profile {
            Label(AppLocalization.string("Paired. Notifications and calls from \(appState.profileDisplayName(pairedProfile)) now come to this iPhone."), systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .accessibilityIdentifier("notifications.paired")
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
        // The padlock is closed only when the host confirmed it seals with
        // the key this iPhone holds, and that key isn't long overdue.
        let assurance = notifications.encryptionAssurance(gatewayID: gateway.id)
        if notifications.unsavedRotationGatewayIDs.contains(gateway.id) {
            // A rotation the host took whose new key the Keychain refused:
            // said as it is, not as a generic mismatch.
            Label(AppLocalization.string("This host has a new encryption key that Conduit couldn't save on this iPhone, so its notifications show only generic text. Conduit asks for it again the next time it connects to this dashboard."), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if case .ensured(let createdAt, let rotates, let quantumSafe) = assurance {
            let date = createdAt.formatted(date: .abbreviated, time: .omitted)
            // The shield replaces the padlock once the key came from an
            // ML-KEM rotation: quantum-safe end to end.
            Label(
                quantumSafe
                    ? AppLocalization.string("End-to-end encrypted and quantum-safe, with a key from \(date). Only this iPhone can read these notifications; the relay sees when they arrive, not what they say. The key changes every 7 days.")
                    : !rotates
                        ? AppLocalization.string("End-to-end encrypted. Only this iPhone can read these notifications; the relay sees when they arrive, not what they say. Update this host's notifier so the key changes every 7 days.")
                        : NotificationKeyRotation.supportsPQ
                            ? AppLocalization.string("End-to-end encrypted with a key from \(date). Only this iPhone can read these notifications; the relay sees when they arrive, not what they say. The key changes every 7 days.")
                            : AppLocalization.string("End-to-end encrypted with a key from \(date). Only this iPhone can read these notifications; the relay sees when they arrive, not what they say. The key changes every 7 days; update to iOS 26 to make it quantum-safe."),
                systemImage: quantumSafe ? "lock.shield.fill" : "lock.fill"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if case .overdue = assurance {
            Label(AppLocalization.string("End-to-end encrypted, but the key is overdue for rotation. Open this host's dashboard in Conduit so it can hand over a new one."), systemImage: "lock.open")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if case .mismatched = assurance {
            Label(AppLocalization.string("This host's encryption key doesn't match this iPhone's, so its notifications show only generic text. Conduit sets up a new key the next time it connects to this dashboard."), systemImage: "lock.open")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if case .unconfirmed = assurance {
            Label(AppLocalization.string("End-to-end encryption is set up on this iPhone. Conduit checks it with the host the next time it connects to this dashboard."), systemImage: "lock.open")
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
    /// How much a notification says (#1415).
    private var notificationDetailPicker: some View {
        let detail = notifications.preferences.detail
        return VStack(alignment: .leading, spacing: 4) {
            ConduitMenuPicker(
                value: detail,
                choices: NotificationDetail.allCases.map { (id: $0, title: $0.title) },
                onSelect: { choice in
                    guard choice != detail else { return }
                    Haptics.selection()
                    Task { await notifications.setDetail(choice) }
                }
            ) {
                Text(AppLocalization.string("Show in notifications"))
            }
            .accessibilityIdentifier("notifications.detail")
            Text(detail.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if detail != .generic {
                Text(AppLocalization.string("To keep them off the Lock Screen, set Show Previews to When Unlocked in iOS Settings > Notifications > Conduit."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
                    // The sent-bubble fill: the dark-mode accent is too
                    // light under white text.
                    .background(Color.conduitUserBubble, in: Circle())
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
    @State private var confirmingSavedChatsDelete = false
    @State private var savedChatsDeleted = false

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
                SettingsMetricRow(label: AppLocalization.string("Active profile"), value: appState.profileDisplayName(profile))
                SettingsMetricRow(label: AppLocalization.string("Version"), value: ConduitAppVersion.display)
            }
            ConduitSettingsSection(title: AppLocalization.string("Data handling"), symbol: "hand.raised", tint: .conduitAura) {
                Text("Conduit connects to the dashboard and gateway you configure. Conversations and attachments are handled by that Hermes installation.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Conduit keeps your Chats lists and recent conversations on this device, so it opens straight to them while it connects. Each dashboard keeps its own until you sign out of it or remove it.")
                    .font(.footnote).foregroundStyle(.secondary)
                deleteSavedChatsButton
            }
            ConduitSettingsSection(title: AppLocalization.string("Links"), symbol: "link", tint: .conduitAccent) {
                Link(destination: URL(string: "https://kaishi00.github.io/hermes-conduit-notifier/privacy/")!) {
                    HStack {
                        Image(systemName: "lock.shield")
                        Text("Privacy policy")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.conduitTertiary)
                    }
                }
                Link(destination: URL(string: "https://kaishi00.github.io/hermes-conduit-notifier/support/")!) {
                    HStack {
                        Image(systemName: "lifepreserver")
                        Text("Support")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.conduitTertiary)
                    }
                }
                Link(destination: URL(string: "https://github.com/kaishi00/hermes-conduit-notifier")!) {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("GitHub")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.conduitTertiary)
                    }
                }
            }
            ConduitSettingsSection(title: AppLocalization.string("Disclaimer"), symbol: "info.circle", tint: .conduitAura) {
                Text("Hermes Conduit is an independent client and is not affiliated with or endorsed by Nous Research. © 2026 Milim.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("About & privacy")
    }

    private var deleteSavedChatsButton: some View {
        Button(role: .destructive) {
            confirmingSavedChatsDelete = true
        } label: {
            Label(
                savedChatsDeleted ? AppLocalization.string("Saved Chats Deleted") : AppLocalization.string("Delete Saved Chats"),
                systemImage: savedChatsDeleted ? "checkmark" : "trash"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6).frame(minHeight: 48)
        }
        .disabled(savedChatsDeleted)
        .conduitGlassControl(cornerRadius: 17, tint: .red.opacity(0.18), prominent: false)
        .accessibilityIdentifier("settings.about.delete-saved-chats")
        .confirmationDialog("Delete the chats saved on this device?", isPresented: $confirmingSavedChatsDelete, titleVisibility: .visible) {
            Button("Delete Saved Chats", role: .destructive) {
                appState.deleteSavedChats()
                savedChatsDeleted = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the saved Chats lists, conversation copies and pictures for every dashboard. Nothing changes on Hermes, and Conduit saves them again as you use it.")
        }
    }
}

/// A settings page: its sections on the backdrop, the title small in the
/// bar, and the list fading out under the bar (V2) rather than ending at a
/// line.
struct SettingsDetailContainer<Content: View>: View {
    var compact = false
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            SettingsBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 18 : 24) { content }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(V2SoftTopScrollEdge(isOn: true))
        }
        .navigationBarTitleDisplayMode(.inline)
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

    /// V2: the name over the card, as a Board lane's name sits over its
    /// cards, and a quiet card rather than a tinted glass slab.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: title, symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .settingsCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A settings page's still backdrop, its glow in `settingsGlowTint`: the
/// active profile's color in V2's Settings tab, as on its home page, so
/// pushing a page keeps it. An environment value rather than AppState, so a
/// sheet built on these pages needs nothing injected (check-sheet-environment).
struct SettingsBackdrop: View {
    @Environment(\.settingsGlowTint) private var glowTint

    var body: some View {
        ConduitBackdrop(glowTint: glowTint)
    }
}

private struct SettingsGlowTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The glow color of settings pages' backdrops; nil keeps the gold.
    var settingsGlowTint: Color? {
        get { self[SettingsGlowTintKey.self] }
        set { self[SettingsGlowTintKey.self] = newValue }
    }
}

/// A settings group's name over its card: a small symbol in the group's
/// color, then the name.
struct SettingsSectionHeader: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .conduitFixedGlyph()
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A settings group's card: a faint fill and hairline over the backdrop,
    /// like the V2 Scheduled list, so a page of them stays calm.
    func settingsCard(cornerRadius: CGFloat = 20) -> some View {
        background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
    }
}

/// Settings' action buttons: a gold capsule that shrinks a little on V2's
/// overshoot spring while pressed. `.settings` is any action in a card
/// (Add the shortcut, Check again, Set up); `.settingsPrimary` is the one
/// that commits what was typed (Save, Add key, Apply).
struct SettingsButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonLabel(configuration: configuration, isPrimary: isPrimary)
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsPrimary: SettingsButtonStyle { SettingsButtonStyle(isPrimary: true) }
}

private struct SettingsButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool

    /// Dark text on the bright dark-mode gold; white on the light-mode
    /// brown, where dark text read poorly.
    private var primaryText: Color {
        colorScheme == .dark ? Color.black.opacity(0.85) : .white
    }

    var body: some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isPrimary ? primaryText : Color.conduitAccent)
            .padding(.horizontal, isPrimary ? 16 : 14)
            .frame(minHeight: isPrimary ? 38 : 36)
            .background(isPrimary ? Color.conduitAccent : Color.conduitAccent.opacity(0.15), in: Capsule())
            .overlay {
                if !isPrimary {
                    Capsule().strokeBorder(Color.conduitAccent.opacity(0.4), lineWidth: 0.5)
                }
            }
            // A 44 pt touch target around the smaller capsule.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// A settings list row's ⋯ menu (Edit, Delete) in place of a gold pencil
/// and a red minus on every row.
struct SettingsRowMenu: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// The row's name, so VoiceOver says which row the menu acts on.
    let itemName: String
    var onEdit: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        Menu {
            if let onEdit {
                Button(action: onEdit) {
                    Label(AppLocalization.string("Edit"), systemImage: "pencil")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label(AppLocalization.string("Delete"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(AppLocalization.string("More")))
        .accessibilityValue(Text(verbatim: itemName))
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
