//
//  AppState+FarChatSettings.swift
//  Conduit
//
//  Another combined dashboard's chat on screen draws and sends by its own
//  dashboard's profile settings: Show thinking, tool steps and reviews,
//  and the busy mode (Steer, Queue or Interrupt). AppState's own
//  `displayPreferences` and `busyInputMode` stay the dashboard on screen's,
//  which Settings shows and edits.
//

import Foundation

/// A far chat's profile settings, as last kept here or read on its
/// dashboard.
struct FarChatSettings: Equatable {
    let owner: FarChatOwner
    var display: ProfileDisplayPreferences
    var busyMode: BusyInputMode
}

extension AppState {
    /// The display settings the chat on screen draws with: a far chat's own
    /// dashboard's profile's, else this dashboard's.
    var chatDisplayPreferences: ProfileDisplayPreferences {
        guard let farChat else { return displayPreferences }
        if let settings = farChatSettings, settings.owner == farChat { return settings.display }
        return keptFarChatSettings(for: farChat).display
    }

    /// The busy mode a message to the chat on screen goes with while it
    /// runs: a far chat's own dashboard's profile's, else this dashboard's.
    var chatBusyInputMode: BusyInputMode {
        guard let farChat else { return busyInputMode }
        if let settings = farChatSettings, settings.owner == farChat { return settings.busyMode }
        return keptFarChatSettings(for: farChat).busyMode
    }

    /// What `owner`'s profile last had here, Hermes' defaults for one never
    /// read (interrupt, as `restoreBusyInputMode`).
    func keptFarChatSettings(for owner: FarChatOwner) -> FarChatSettings {
        FarChatSettings(
            owner: owner,
            display: storedDisplayPreferences(dashboardID: owner.dashboardID, profile: owner.profile)
                ?? ProfileDisplayPreferences(),
            busyMode: defaults.string(forKey: Self.farBusyInputModeKey(owner))
                .flatMap(BusyInputMode.init(rawValue:)) ?? .interrupt
        )
    }

    /// The busy mode kept for a dashboard's profile, under the key the
    /// dashboard keeps it under while on screen (its id is its server
    /// identity, `busyInputModeCacheKey`).
    static func farBusyInputModeKey(_ owner: FarChatOwner) -> String {
        "\(busyInputModeCachePrefix)\(owner.dashboardID.uuidString)|\(owner.profile)"
    }

    /// As the far chat changes: its kept settings at once, then its
    /// dashboard's own read through its kept connection.
    func noteFarChatSettings() {
        guard let farChat else {
            farChatSettingsTask?.cancel()
            farChatSettingsTask = nil
            if farChatSettings != nil { farChatSettings = nil }
            return
        }
        guard farChatSettings?.owner != farChat else { return }
        farChatSettings = keptFarChatSettings(for: farChat)
        farChatSettingsTask?.cancel()
        farChatSettingsTask = Task { [weak self] in await self?.loadFarChatSettings(for: farChat) }
    }

    /// Reads `owner`'s display config and busy mode on its own dashboard's
    /// kept connection. Each read that fails keeps what was kept here.
    func loadFarChatSettings(for owner: FarChatOwner) async {
        guard let runtime = keptDashboardRuntimes[owner.dashboardID]?.runtime else { return }
        if let bridge = runtime.dashboardTicketBridge,
           let config = try? await bridge.requestJSON(path: dashboardPath("/api/config", profile: owner.profile)) {
            guard !Task.isCancelled, farChat == owner, farChatSettings?.owner == owner else { return }
            let display = ProfileDisplayPreferences(display: config["display"] as? [String: Any] ?? [:])
            rememberDisplayPreferences(display, dashboardID: owner.dashboardID, profile: owner.profile)
            if farChatSettings?.display != display { farChatSettings?.display = display }
        }
        // The busy mode is the client's own profile's: only that profile's
        // chat takes it.
        if let client = runtime.client, profilesMatch(runtime.activeProfile, owner.profile),
           let mode = try? await client.busyInputMode() {
            guard !Task.isCancelled, farChat == owner, farChatSettings?.owner == owner else { return }
            defaults.set(mode.rawValue, forKey: Self.farBusyInputModeKey(owner))
            if farChatSettings?.busyMode != mode { farChatSettings?.busyMode = mode }
        }
    }
}
