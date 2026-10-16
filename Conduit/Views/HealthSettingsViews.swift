//
//  HealthSettingsViews.swift
//  Conduit
//
//  Settings > Health: opt-in sharing of Apple Health data with one Hermes
//  profile. Off until the user picks what to share
//  and agrees on the consent sheet; turning it off can delete the host's copy.
//

import SwiftUI

struct HealthSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var engine: HealthSyncEngine
    @ObservedObject var appLanguage = AppLanguageStore.shared

    @State private var categories: Set<HealthCategory> = [.activity, .heart, .sleep, .workouts]
    @State private var detailed: Set<HealthCategory> = []
    @State private var history: HealthHistoryDepth = .default
    @State private var loadedPreferences = false
    @State private var showsConsent = false
    /// Agreed in the consent sheet: turning on waits for the sheet to go,
    /// since Apple Health's own permission sheet can't show over it.
    @State private var turnsOnAfterConsent = false
    @State private var showsTurnOff = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// The voice mode waiting for the user's yes before it may read health data.
    @State private var askingVoiceMode: LiveVoiceModeName?
    /// Loaded on appear (loading prunes and saves).
    @State private var voiceReads = HealthVoiceReadLog()

    private var preferences: HealthSyncPreferences { appState.healthSyncPreferences }
    private var pluginServesHealth: Bool { appState.notifierPlugin.reports(AppState.healthSyncCapability) }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Health data for Hermes"), symbol: "heart.text.square", tint: .pink) {
                Text("Share Apple Health data with Hermes so your agent can answer questions about your activity, sleep and workouts. It goes straight from this iPhone to your Hermes host, sealed end to end, and never through Conduit's notification relay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !engine.source.isAvailable {
                    Text("Apple Health isn't available on this device.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if preferences.isOn {
                    statusRows
                } else if !pluginServesHealth {
                    Text("Update the Conduit plugin on your Hermes host to share health data.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if engine.source.isAvailable, preferences.isOn || pluginServesHealth {
                categorySection
                historySection
            }
            if preferences.isOn, appState.notifierPlugin.reports(AppState.voiceToolsCapability) {
                voiceSection
            }
            // Turning off stays reachable even if Health becomes unavailable.
            if preferences.isOn || (engine.source.isAvailable && pluginServesHealth) {
                actionSection
            }
        }
        .navigationTitle("Health")
        .onAppear {
            loadPreferences()
            voiceReads = HealthVoiceReadLog.load()
        }
        .confirmationDialog(
            askingVoiceMode.map { Text(AppLocalization.string("Let \($0.displayName) read your health data?")) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { askingVoiceMode != nil }, set: { if !$0 { askingVoiceMode = nil } }),
            titleVisibility: .visible,
            presenting: askingVoiceMode
        ) { mode in
            Button("Allow") { setVoiceRead(mode, allowed: true) }
            Button("Cancel", role: .cancel) {}
        } message: { mode in
            Text(AppLocalization.string("On a call, what it reads goes to \(mode.company) under its terms. You can turn this off at any time."))
        }
        .sheet(isPresented: $showsConsent, onDismiss: {
            guard turnsOnAfterConsent else { return }
            turnsOnAfterConsent = false
            turnOn()
        }) {
            HealthSharingConsentSheet(profile: appState.activeProfile, host: hostLabel) {
                turnsOnAfterConsent = true
                showsConsent = false
            } cancel: {
                showsConsent = false
            }
        }
        .confirmationDialog("Turn off health sharing?", isPresented: $showsTurnOff, titleVisibility: .visible) {
            Button("Turn off and delete from the host", role: .destructive) { turnOff(delete: true) }
            Button("Turn off, keep data on the host") { turnOff(delete: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conduit stops sending health data. Deleting removes what this iPhone sent from the host; Hermes can no longer read it.")
        }
    }

    private var hostLabel: String {
        if let host = appState.connection?.baseUrl, let url = URL(string: host), let name = url.host { return name }
        return appState.connection?.baseUrl ?? ""
    }

    // MARK: Status

    @ViewBuilder
    private var statusRows: some View {
        if let destination = preferences.destination {
            Label(AppLocalization.string("Sharing with \(destination.profile) on \(destination.host)"), systemImage: "checkmark.shield")
                .font(.subheadline)
        }
        if engine.isSyncing {
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let pause = engine.state.pause {
            Text(pause.message)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let last = engine.state.lastSync {
            Text(AppLocalization.string("Last synced \(last.formatted(.relative(presentation: .named)))"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Not synced yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let cursor = engine.state.backfillCursor, let start = engine.state.historyStart, cursor > start {
            Text(AppLocalization.string("Bringing in history: back to \(cursor.formatted(date: .abbreviated, time: .omitted)) so far."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = engine.lastError, engine.state.pause == nil {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Voice

    /// Which live voice modes may read the shared data on a call. Each is
    /// its own yes: what it reads goes to that mode's company.
    private var voiceSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Live voice calls"), symbol: "waveform", tint: .conduitAccent) {
            ForEach(LiveVoiceModeName.all, id: \.storageID) { mode in
                Toggle(isOn: voiceReadBinding(mode)) {
                    Text(verbatim: "\(mode.displayName) (\(mode.company))")
                }
                .accessibilityIdentifier("settings.health.voice.\(mode.storageID)")
            }
            Text("Let a live voice call read your health data when you ask about it, straight from your Hermes host. What it reads goes to the company that runs that voice mode, under its terms. Classic voice is Hermes itself and needs nothing here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !voiceReads.entries.isEmpty {
                Text("Read by voice in the last 7 days")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(voiceReads.entries.suffix(20).reversed()) { entry in
                    HStack {
                        Text(verbatim: "\(entry.modeName): \(entry.action)")
                        Spacer()
                        Text(entry.at.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func voiceReadBinding(_ mode: LiveVoiceModeName) -> Binding<Bool> {
        Binding(
            get: { preferences.letsVoiceRead(mode) },
            set: { on in
                if on {
                    askingVoiceMode = mode
                } else {
                    setVoiceRead(mode, allowed: false)
                }
            }
        )
    }

    private func setVoiceRead(_ mode: LiveVoiceModeName, allowed: Bool) {
        Haptics.selection()
        appState.setHealthVoiceRead(mode, allowed: allowed)
    }

    // MARK: Choices

    private var categorySection: some View {
        ConduitSettingsSection(title: AppLocalization.string("What to share"), symbol: "checklist", tint: .conduitAccent) {
            ForEach(HealthCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: categoryBinding(category)) {
                        Label(category.title, systemImage: category.symbol)
                    }
                    // The last category stays on while sharing is on: turning
                    // sharing off is the button below.
                    .disabled(preferences.isOn && categories == [category])
                    .accessibilityIdentifier("settings.health.\(category.rawValue)")
                    Text(category.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if category.hasDetailedReadings, categories.contains(category) {
                        Toggle("Include detailed readings", isOn: detailedBinding(category))
                            .font(.subheadline)
                            .padding(.leading, 28)
                            .accessibilityLabel(AppLocalization.string("Include detailed readings for \(category.title)"))
                    }
                }
            }
            Text("Hermes gets hourly and daily summaries computed by Apple Health, a summary of each night's sleep, and each workout. Detailed readings add every individual measurement, such as each heart rate reading.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if preferences.isOn {
                keptOnHostNote
            }
        }
    }

    /// Narrowing what's shared doesn't delete what the host already has.
    private var keptOnHostNote: some View {
        Text("Unticking a category or shortening the history only stops new uploads. What was already sent stays on the host until you turn off sharing and delete it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var historySection: some View {
        ConduitSettingsSection(title: AppLocalization.string("History"), symbol: "clock.arrow.circlepath", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: historyBinding.wrappedValue,
                choices: HealthHistoryDepth.allCases.map { (id: $0, title: $0.title) },
                onSelect: { historyBinding.wrappedValue = $0 }
            ) {
                Text("Share history from").foregroundStyle(.secondary)
            }
            Text("How far back the first sync reaches. A long history comes in over a few days in the background. Hourly detail covers the last 30 days; older history is daily.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionSection: some View {
        VStack(spacing: 10) {
            if preferences.isOn {
                Button {
                    Haptics.selection()
                    Task {
                        await appState.runHealthSync(reason: .manual)
                        // Without a connection the pass can't start: say so.
                        errorMessage = appState.dashboardTicketBridge == nil || appState.activeDashboardID == nil
                            ? DashboardTicketBridgeError.notReady.errorDescription : nil
                    }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 48)
                }
                .disabled(engine.isSyncing || isWorking)
                .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent.opacity(0.18))
                .accessibilityIdentifier("settings.health.sync-now")
                Button {
                    showsTurnOff = true
                } label: {
                    Label("Turn off sharing", systemImage: "heart.slash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 48)
                }
                .disabled(isWorking)
                .conduitGlassControl(cornerRadius: 17, tint: .red.opacity(0.18), prominent: false)
                .accessibilityIdentifier("settings.health.turn-off")
            } else {
                Button {
                    Haptics.selection()
                    showsConsent = true
                } label: {
                    Label(isWorking ? AppLocalization.string("Turning on…") : AppLocalization.string("Turn on sharing"), systemImage: "heart.text.square")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 48)
                        .foregroundStyle(Color.white)
                }
                .disabled(categories.isEmpty || isWorking || appState.activeDashboardID == nil)
                .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent, prominent: true)
                .accessibilityIdentifier("settings.health.turn-on")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Bindings

    private func categoryBinding(_ category: HealthCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(category) },
            set: { on in
                var next = categories
                if on { next.insert(category) } else { next.remove(category) }
                // Sharing on with nothing chosen is sharing off: use the button.
                guard !(preferences.isOn && next.isEmpty) else { return }
                categories = next
                if !on { detailed.remove(category) }
                applyIfOn()
            }
        )
    }

    private func detailedBinding(_ category: HealthCategory) -> Binding<Bool> {
        Binding(
            get: { detailed.contains(category) },
            set: { on in
                if on { detailed.insert(category) } else { detailed.remove(category) }
                applyIfOn()
            }
        )
    }

    private var historyBinding: Binding<HealthHistoryDepth> {
        Binding(get: { history }, set: { history = $0; applyIfOn() })
    }

    // MARK: Actions

    private func loadPreferences() {
        guard !loadedPreferences else { return }
        loadedPreferences = true
        guard preferences.isOn else { return }
        categories = preferences.categories
        detailed = preferences.detailed
        history = preferences.history
    }

    private func applyIfOn() {
        guard preferences.isOn else { return }
        let categories = categories, detailed = detailed, history = history
        Task {
            do {
                try await appState.updateHealthSync(categories: categories, detailed: detailed, history: history)
                errorMessage = nil
            } catch {
                errorMessage = HealthSyncEngine.describe(error)
            }
        }
    }

    private func turnOn() {
        isWorking = true
        errorMessage = nil
        let categories = categories, detailed = detailed, history = history
        Task {
            do {
                try await appState.turnOnHealthSync(categories: categories, detailed: detailed, history: history)
                Haptics.success()
            } catch {
                errorMessage = HealthSyncEngine.describe(error)
                Haptics.error()
            }
            isWorking = false
        }
    }

    private func turnOff(delete: Bool) {
        isWorking = true
        errorMessage = nil
        Task {
            let done = await appState.turnOffHealthSync(deleteFromHost: delete)
            if !done {
                errorMessage = AppLocalization.string("Sharing is off. The host couldn't be reached, so Conduit deletes the data there the next time it connects.")
            }
            isWorking = false
        }
    }
}

/// What the user agrees to before anything leaves the phone. App Review
/// 5.1.2(i) asks for this before personal data reaches a third-party AI.
struct HealthSharingConsentSheet: View {
    let profile: String
    let host: String
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "heart.text.square")
                        .font(.system(size: 44))
                        .foregroundStyle(.pink)
                        .accessibilityHidden(true)
                    Text("Share health data with Hermes?")
                        .font(.title2.weight(.semibold))
                    Label(AppLocalization.string("Conduit sends the health data you chose to the \(profile) profile on \(host), sealed end to end. It never goes through Conduit's notification relay, and Conduit's developer can't see it."), systemImage: "lock.shield")
                    Label("Your agent reads it when you ask, or when a task needs it. Whatever it reads goes to the AI model provider your Hermes uses, under that provider's terms. If your Hermes is hosted by someone else, such as Hermes Cloud, they can read it too.", systemImage: "sparkles")
                    Label("Health data is never used for advertising and is not stored in iCloud by Conduit.", systemImage: "hand.raised")
                    Label("You can turn sharing off at any time in Settings > Health and delete what was sent from the host.", systemImage: "heart.slash")
                }
                .font(.subheadline)
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(action: accept) {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6).frame(minHeight: 48)
                            .foregroundStyle(Color.white)
                    }
                    .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent, prominent: true)
                    .accessibilityIdentifier("settings.health.consent.continue")
                    Button("Cancel", action: cancel)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .presentationDetents([.large])
    }
}
