//
//  AppState+Boards.swift
//  Conduit
//
//  Where the open chat's checklist cards keep their ticks: on the host,
//  through the plugin's /boards/checklists route (RichChecklistMemory);
//  and where a diff card reads the whole of a long diff (/boards/diffs).
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
        let scope = RichChecklistContext.scope(profile: profile, sessionIDs: sessionIDs)
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

    /// What the open chat's cards' send and tap buttons go through, or nil
    /// where they can't (the saved copy, a chat on its way). A tap posts to
    /// the plugin's /boards/taps on the chat's own dashboard, then sends the
    /// user's message about it, which hears the tap (issue 1946).
    func richCardActionContext(canSend: Bool) -> RichCardActionContext? {
        guard offlineChatPresentation == nil else { return nil }
        let sessionIDs = activeChatArtifactSessionIDs
        guard !sessionIDs.isEmpty else { return nil }
        let profile = activeProfile
        let dashboardID = activeDashboardID
        let tap: (@MainActor ([String: Any], String) async throws -> Void)?
        if notifierPlugin.reports(RichCardActionContext.capability) {
            tap = { [weak self] body, message in
                guard let self else { throw DashboardTicketBridgeError.notReady }
                let bridge = try self.richChecklistBridge(for: dashboardID)
                var body = body
                body["sessions"] = Array(sessionIDs.prefix(4))
                let _: [String: Any] = try await bridge.requestJSON(
                    path: RichCardActionContext.tapPath(profile: profile), method: "POST", body: body)
                // The message goes only to the chat the card was tapped in: after
                // a switch the tap waits unheard and is forgotten on the host.
                guard RichCardActionContext.mayFollowUp(
                    tappedIn: sessionIDs, profile: profile, openSessionIDs: self.activeChatArtifactSessionIDs,
                    openProfile: self.activeProfile, composerIsEnabled: self.composerIsEnabled,
                    draft: self.predictive.draft) else {
                    throw DashboardTicketBridgeError.notReady
                }
                self.requestBoardFollowUp(.send, text: message)
            }
        } else {
            tap = nil
        }
        return RichCardActionContext(sessionIDs: sessionIDs, canSend: canSend, composer: predictive,
                                     send: { [weak self] text in self?.requestBoardFollowUp(.send, text: text) },
                                     tap: tap)
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

    /// A diff card reads the whole of a long diff from the connected
    /// Hermes, the one whose plugin kept it; an id from another Hermes is
    /// answered as gone there.
    func installRichDiffReader() {
        RichDiffLoader.shared.read = { [weak self] path in
            guard let self, self.notifierPlugin.reports(RichDiffLoader.capability),
                  let bridge = self.dashboardTicketBridge else { throw RichDiffLoader.LoadError.notConnected }
            return try await bridge.requestJSON(path: path)
        }
    }
}
