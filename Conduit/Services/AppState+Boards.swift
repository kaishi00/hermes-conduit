//
//  AppState+Boards.swift
//  Conduit
//
//  Where the open chat's checklist cards keep their ticks: on the host,
//  through the plugin's /boards/checklists route (RichChecklistMemory).
//

import Foundation

extension AppState {
    /// The open chat's checklists on the host, or nil where they stay on
    /// this phone: a plugin without the route, the saved copy, a chat on
    /// its way.
    var richChecklistContext: RichChecklistContext? {
        guard notifierPlugin.reports(RichChecklistContext.capability), offlineChatPresentation == nil else { return nil }
        let sessionIDs = activeChatArtifactSessionIDs
        guard !sessionIDs.isEmpty else { return nil }
        let profile = activeProfile
        let dashboardID = activeDashboardID
        let scope = "\(profile)\u{1E}\(sessionIDs.joined(separator: "\u{1D}"))"
        return RichChecklistContext(
            scope: scope,
            sessionIDs: sessionIDs,
            read: { [weak self] in
                guard let bridge = try self?.richChecklistBridge(for: dashboardID) else { throw DashboardTicketBridgeError.notReady }
                return RichChecklistContext.ticks(try await bridge.requestJSON(
                    path: RichChecklistContext.readPath(profile: profile, sessionIDs: sessionIDs)))
            },
            save: { [weak self] body in
                guard let bridge = try self?.richChecklistBridge(for: dashboardID) else { throw DashboardTicketBridgeError.notReady }
                return RichChecklistContext.ticks(try await bridge.requestJSON(
                    path: RichChecklistContext.savePath(profile: profile), method: "POST", body: body))
            })
    }

    /// The bridge a chat's checklists go through, taken when each read or
    /// save starts: only the chat's own dashboard's. After a switch the
    /// other Hermes would accept the chat's ids and answer as saved, so the
    /// tick stays unsent here and goes when the chat is drawn on its own
    /// dashboard again (#1745). A request already on its way when the
    /// switch lands is refused by the old bridge (answeredAfterSwitch).
    func richChecklistBridge(for dashboardID: UUID?) throws -> DashboardTicketBridge {
        guard activeDashboardID == dashboardID, let bridge = dashboardTicketBridge else {
            throw DashboardTicketBridgeError.notReady
        }
        return bridge
    }
}
