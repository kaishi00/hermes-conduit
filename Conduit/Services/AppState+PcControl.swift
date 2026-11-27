//
//  AppState+PcControl.swift
//  Conduit
//
//  Control from Hermes on the phone: whether the open chat's bot is
//  controlling one of the user's computers, and Stop (plugin 0.205+).
//

import Foundation

extension AppState {
    /// The computer the open chat is controlling, read from its own
    /// dashboard and profile; nil when none is, or there's nothing to ask
    /// (no open chat, no connection, a plugin without `pc-asks`, a failed read).
    func loadOpenChatPcControl() async -> PcControlling? {
        guard let active = activeSessionId else { return nil }
        if let routed = await onChatRuntime(unreachable: PcControlling?.none, { await loadOpenChatPcControl() }) {
            return routed
        }
        guard isConnected, let owner = currentDashboardRuntimeOwner(), servesPcAsks else { return nil }
        let path = DashboardPath.withProfile(PcControlling.statePath, profile: conversationIdentityProfile)
        guard let response = try? await owner.bridge.requestJSON(path: path), ownsDashboardRuntime(owner) else { return nil }
        let ids = Set([active, openChatUsageSessionID()].compactMap { $0 })
        return PcControlling.forChat(PcControlling.all(response: response), sessionIDs: ids)
    }

    /// Stop: the chat's bot stops controlling that computer, whatever it was
    /// about to do is answered stopped, its next action asks again, and the
    /// computer's bar goes. False when it couldn't reach the plugin.
    func stopPcControl(_ controlling: PcControlling) async -> Bool {
        if let routed = await onChatRuntime(unreachable: false, { await stopPcControl(controlling) }) {
            return routed
        }
        guard isConnected, let owner = currentDashboardRuntimeOwner() else { return false }
        let path = DashboardPath.withProfile(PcControlling.stopPath, profile: conversationIdentityProfile)
        return (try? await owner.bridge.requestJSON(path: path, method: "POST", body: ["computer": controlling.computer])) != nil
    }

    /// The bot's name for the line: the chat's own.
    var openChatBotName: String { profileDisplayName(conversationIdentityProfile) }

    private var servesPcAsks: Bool {
        if case .reported(_, let capabilities) = notifierPlugin.state { return capabilities.contains(PcControlling.capability) }
        return false
    }
}
