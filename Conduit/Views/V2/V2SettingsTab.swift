//
//  V2SettingsTab.swift
//  Conduit
//
//  Settings as a tab: the same SettingsView the drawer presented as a
//  sheet, with the profile picker as its home page's bar and V2's grouping
//  (the selected profile first, then Voice, then App).
//

import SwiftUI

struct V2SettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    /// A settings link (`conduit://settings/voice`) waiting to open its page.
    @Binding var link: ConduitAppLink.SettingsLink?
    @State private var snapshot: SettingsSnapshot?

    var body: some View {
        ZStack {
            // Shows while the page loads; the home page draws its own over it.
            V2Backdrop(drifts: false)
            // Kept across profile switches, so the profile bar on the home
            // page stays and slides to the new profile while only the list
            // under it fades (SettingsHome), as on the other tabs.
            if let snapshot {
                settingsView(snapshot)
            }
        }
        .onAppear {
            if snapshot == nil { snapshot = appState.makeSettingsSnapshot() }
            openLinkIfNeeded()
        }
        .onChange(of: link) { _, _ in openLinkIfNeeded() }
        // The snapshot carries the dashboard and profile the home page
        // shows; a switch of either from the top bar starts the home page
        // over, so no page outlives its own (two dashboards' "default"
        // profiles included). The connection row reads the live state, so
        // a reconnect leaves the open page alone.
        .onChange(of: appState.activeProfile) { _, _ in snapshot = appState.makeSettingsSnapshot() }
        .onChange(of: appState.activeDashboardID) { _, _ in snapshot = appState.makeSettingsSnapshot() }
        // Leaving the tab is the old sheet's dismiss: voice settings the
        // user changed take effect. Hidden capsule tabs stay mounted, so
        // this follows the tab's active state rather than onDisappear.
        .onChange(of: shell.isTabActive) { _, active in
            guard !active else { return }
            Task { await appState.refreshVoiceCapabilities() }
        }
    }

    /// A link's page opens on a fresh Settings stack; a page this host
    /// doesn't offer opens the home page instead.
    private func openLinkIfNeeded() {
        guard let page = link else { return }
        link = nil
        var fresh = appState.makeSettingsSnapshot()
        switch page {
        case .calls: fresh.opensAt = appState.supportsHermesCalls ? page : nil
        case .voice, .plugin: fresh.opensAt = page
        case .health: fresh.opensAt = appState.showsHealthSettings ? page : nil
        case .location: fresh.opensAt = appState.showsLocationSettings ? page : nil
        case .phone: fresh.opensAt = appState.showsPhoneSettings ? page : nil
        }
        snapshot = fresh
    }

    private func settingsView(_ snapshot: SettingsSnapshot) -> some View {
        SettingsView(
            snapshot: snapshot,
            saveTheme: { appState.themePreference = $0 },
            persistBusyInputMode: { mode in await appState.setBusyInputMode(mode) },
            persistChatResumeBehavior: { appState.setChatResumeBehavior($0) },
            persistChatReturnSurface: { appState.setChatReturnSurface($0) },
            loadProfileSettings: { keys in await appState.loadProfileSettings(keys: keys) },
            persistProfileSetting: { key, value in await appState.setProfileSetting(key, value: value) },
            loadProfileConfigOptions: { await appState.loadProfileConfigOptions() },
            loadProfileModelDefaults: { await appState.loadProfileModelDefaults() },
            persistProfileMainModel: { provider, model, reasoning in
                await appState.setProfileMainModel(provider: provider, model: model, reasoning: reasoning)
            },
            reconnect: {
                await appState.reconnect()
                return appState.isConnected
            },
            disconnect: { appState.disconnect() },
            homeHeader: AnyView(V2TopBar())
        )
        // Pushed pages keep the home page's profile glow.
        .environment(\.settingsGlowTint, appState.profileGlowTint(appState.activeProfile))
    }
}
