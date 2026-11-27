//
//  AppState+ReplySpeeds.swift
//  Conduit
//
//  The open chat's reply speeds (ReplySpeeds.swift), read from the plugin's
//  `GET /sessions/reply-speeds` while Settings > Chat > Show reply speed is on.
//

import Foundation

extension AppState {
    /// The open chat's reply speeds, by the id Hermes stores it under, in the
    /// profile it runs under, as the Context sheet reads its usage
    /// (`openChatUsageSessionID`). Nil when there's nothing to show: no open
    /// chat, no connection, a plugin without the route, a chat Hermes has no
    /// row for yet, a failed read, or a dashboard that changed while it was out.
    func loadOpenChatReplySpeeds() async -> ReplySpeeds? {
        guard let chatID = activeSessionId else { return nil }
        // Another combined dashboard's chat on screen: read on its own
        // runtime, from its own dashboard and profile (AppState+FarChat.swift).
        if let routed = await onChatRuntime(unreachable: ReplySpeeds?.none, { await loadOpenChatReplySpeeds() }) {
            return routed
        }
        guard let sessionID = openChatUsageSessionID(),
              let route = ReplySpeeds.route(sessionID: sessionID),
              isConnected, let owner = currentDashboardRuntimeOwner() else { return nil }
        if case .reported(_, let capabilities) = notifierPlugin.state,
           !capabilities.contains(ReplySpeeds.capability) { return nil }
        if case .predatesCapabilities = notifierPlugin.state { return nil }
        let path = DashboardPath.withProfile(route, profile: conversationIdentityProfile)
        guard let response = try? await owner.bridge.requestJSON(path: path), ownsDashboardRuntime(owner) else { return nil }
        return ReplySpeeds(chatID: chatID, response: response)
    }

    /// The speeds the rows show: the open chat's, never another's left over.
    var replySpeedsOnScreen: ReplySpeeds? {
        guard let speeds = openChatReplySpeeds, speeds.chatID == activeSessionId else { return nil }
        return speeds
    }
}
