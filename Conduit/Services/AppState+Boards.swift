//
//  AppState+Boards.swift
//  Conduit
//
//  Where the open chat's checklist cards keep their ticks: on the host,
//  through the plugin's /boards/checklists route (RichChecklistMemory);
//  and where a diff card reads the whole of a long diff (/boards/diffs)
//  and a review card its rounds (/boards/reviews): the chat's own Hermes.
//

import Foundation

extension AppState {
    /// The profile whose store keeps the open chat's checklist ticks and
    /// card taps: where its turns run, so its next turn hears them. A Bot
    /// Chat runs in its bot's profile whatever profile is in use (issue
    /// 2520); every other chat, a workstream's included, in the one in use.
    var activeChatStoreProfile: String {
        guard chatOnScreenIsInScope else { return onChatRuntimeValue(unreachable: composerOwnerProfile) { activeChatStoreProfile } }
        guard let sessionID = activeSessionId, !sessionID.isEmpty else { return activeProfile }
        return botChatStoreProfile(forSessionID: sessionID) ?? activeProfile
    }

    /// The open chat's checklists on the host, or nil where they stay on
    /// this phone: a plugin without the route, the saved copy, a chat on
    /// its way.
    /// A far chat's (another combined dashboard's open in place) are its
    /// own dashboard's, read and saved there.
    var richChecklistContext: RichChecklistContext? {
        guard chatOnScreenIsInScope else { return onChatRuntimeValue(unreachable: nil) { richChecklistContext } }
        guard notifierPlugin.reports(RichChecklistContext.capability), offlineChatPresentation == nil else { return nil }
        let sessionIDs = activeChatArtifactSessionIDs
        guard !sessionIDs.isEmpty else { return nil }
        let profile = activeChatStoreProfile
        let dashboardID = activeDashboardID
        let scope = RichChecklistContext.scope(
            profile: RichChecklistContext.keyProfile(profile, dashboard: dashboardID),
            sessionIDs: sessionIDs)
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
    /// The open chat as its cards know it (RichCardActionContext.chat): its
    /// dashboard, profile and durable id, which outlives the runtime id it's
    /// open by and which a runtime id moved to another chat doesn't carry,
    /// as for a waiting send (durableComposerSessionID).
    var richCardChat: String? {
        guard chatOnScreenIsInScope else { return onChatRuntimeValue(unreachable: nil) { richCardChat } }
        guard let activeSessionId, !activeSessionId.isEmpty else { return nil }
        return RichCardActionContext.chat(dashboard: "\(activeDashboardID)", profile: activeProfile,
                                          sessionID: durableComposerSessionID(for: activeSessionId))
    }

    func richCardActionContext(canSend: Bool) -> RichCardActionContext? {
        // A far chat's cards tap through its own dashboard's plugin.
        guard chatOnScreenIsInScope else { return onChatRuntimeValue(unreachable: nil) { richCardActionContext(canSend: canSend) } }
        guard offlineChatPresentation == nil else { return nil }
        let sessionIDs = activeChatArtifactSessionIDs
        guard !sessionIDs.isEmpty,
              let chat = richCardChat else { return nil }
        let profile = activeChatStoreProfile
        let dashboardID = activeDashboardID
        let tap: (@MainActor ([String: Any], String) async throws -> Void)?
        if notifierPlugin.reports(RichCardActionContext.capability) {
            let drops = notifierPlugin.reports(RichCardActionContext.dropCapability)
            tap = { [weak self] body, message in
                guard let self else { throw DashboardTicketBridgeError.notReady }
                let bridge = try self.richChecklistBridge(for: dashboardID)
                var body = body
                body["sessions"] = Array(sessionIDs.prefix(4))
                let answer: [String: Any] = try await bridge.requestJSON(
                    path: RichCardActionContext.tapPath(profile: profile), method: "POST", body: body)
                // The message goes only to the chat the card was tapped in, into
                // an empty composer: otherwise the host forgets the tap, so no
                // later message that starts with its label hears it.
                guard RichCardActionContext.mayFollowUp(
                    tappedIn: chat,
                    openChat: self.richCardChat,
                    composerIsEnabled: self.composerIsEnabled, draft: self.predictive.draft,
                    stagedAttachments: self.predictive.hasStagedAttachments,
                    sameChat: self.richCardChatsAreSame) else {
                    if let id = answer["id"] as? String, drops {
                        let _: [String: Any]? = try? await bridge.requestJSON(
                            path: RichCardActionContext.dropPath(profile: profile, id: id), method: "DELETE")
                    }
                    throw DashboardTicketBridgeError.notReady
                }
                self.requestBoardFollowUp(.send, text: message)
            }
        } else {
            tap = nil
        }
        var context = RichCardActionContext(sessionIDs: sessionIDs, chat: chat, canSend: canSend, composer: predictive,
                                            send: { [weak self] text in self?.requestBoardFollowUp(.send, text: text) },
                                            tap: tap)
        context.sameChat = { [weak self] old, new in self?.richCardChatsAreSame(old, new) ?? (old == new) }
        return context
    }

    /// Whether two of richCardChat's values are one chat: the same dashboard
    /// and profile, and the chat under another of its ids (a new chat's
    /// runtime id giving way to its durable one), as for a draft.
    func richCardChatsAreSame(_ old: String, _ new: String) -> Bool {
        if old == new { return true }
        guard let lhs = RichCardActionContext.parts(old), let rhs = RichCardActionContext.parts(new),
              lhs.dashboard == rhs.dashboard, lhs.profile == rhs.profile else { return false }
        // Read on the chat's own dashboard: a far chat's ids are its rows'.
        // (richCardChat names it as `activeDashboardID` reads in its scope.)
        let farID = farChatDashboardID
        let dashboard = farID != nil && String(describing: farID) == lhs.dashboard ? farID : activeDashboardID
        return composerDraftKeysAreSameChat(ComposerDraftKey(dashboard: dashboard, profile: lhs.profile, sessionID: lhs.sessionID),
                                            ComposerDraftKey(dashboard: dashboard, profile: rhs.profile, sessionID: rhs.sessionID))
    }

    /// The bridge a chat's checklists go through, taken when each read or
    /// save starts: only the chat's own dashboard's. After a switch the
    /// other Hermes would accept the chat's ids and answer as saved, so the
    /// tick stays unsent here and goes when the chat is drawn on its own
    /// dashboard again (#1745). A request already on its way when the
    /// switch lands is refused by the old bridge (answeredAfterSwitch).
    func richChecklistBridge(for dashboardID: UUID?) throws -> DashboardTicketBridge {
        if activeDashboardID == dashboardID, let bridge = dashboardTicketBridge { return bridge }
        // A far chat open in place (another combined dashboard's): its own
        // dashboard's kept connection, while the chat is still on screen.
        if let dashboardID, dashboardID == farChatDashboardID, let runtime = runtime(for: dashboardID),
           let bridge = act(onRuntime: runtime, { dashboardTicketBridge }) {
            return bridge
        }
        throw DashboardTicketBridgeError.notReady
    }

    /// The dashboard whose Hermes kept the open chat's cards
    /// (richCardHostDashboard in the environment): a far chat's own
    /// (another combined dashboard's open in place), the one on screen's
    /// id otherwise. A far chat whose runtime is gone names its dashboard
    /// still, so its cards' reads find no connection rather than asking the
    /// screen's Hermes.
    var richCardHostDashboard: UUID? {
        guard chatOnScreenIsInScope else { return onChatRuntimeValue(unreachable: farChatDashboardID) { richCardHostDashboard } }
        return activeDashboardID
    }

    /// Whether a card may read on `dashboard`, another combined dashboard
    /// than the one on screen: the far chat's or group room's open in
    /// place, or a live call's that goes on there (its cards and saved
    /// transcript).
    func richCardMayReadOffScreen(_ dashboard: UUID) -> Bool {
        dashboard == farChatDashboardID || dashboard == callDashboardOffScreen
            || dashboard == activeRoomSurface?.dashboardID
    }

    /// The bridge a card's read goes through: `dashboard`'s, the chat's or
    /// call's own (nil for the one on screen), while its plugin reports
    /// `capability`. Another dashboard's goes through its kept connection
    /// while its chat or call is still up, as richChecklistBridge does; nil
    /// otherwise.
    func richCardReadBridge(capability: String, on dashboard: UUID?) -> DashboardTicketBridge? {
        if dashboard == nil || dashboard == activeDashboardID {
            guard notifierPlugin.reports(capability) else { return nil }
            return dashboardTicketBridge
        }
        guard let dashboard, richCardMayReadOffScreen(dashboard), let runtime = runtime(for: dashboard) else { return nil }
        return act(onRuntime: runtime) { notifierPlugin.reports(capability) ? dashboardTicketBridge : nil }
    }

    /// A far chat's or call's plugin may not have said what it keeps yet
    /// (opening the chat doesn't ask): asked once before its cards' reads
    /// are gated.
    func readFarCardHostStatus(_ dashboard: UUID?) async {
        guard let dashboard, dashboard != activeDashboardID, richCardMayReadOffScreen(dashboard) else { return }
        await readKeptPluginStatusIfUnknown(dashboard)
    }

    /// The bridge a card's read goes through, once a far plugin not yet
    /// heard from has been asked what it keeps (the readers' path).
    func richCardReadBridgeAfterStatus(capability: String, on dashboard: UUID?) async -> DashboardTicketBridge? {
        await readFarCardHostStatus(dashboard)
        return richCardReadBridge(capability: capability, on: dashboard)
    }

    /// A diff card reads the whole of a long diff from its chat's Hermes,
    /// the one whose plugin kept it; an id from another Hermes is answered
    /// as gone there.
    func installRichDiffReader() {
        RichDiffLoader.shared.read = { [weak self] path, dashboard in
            guard let bridge = await self?.richCardReadBridgeAfterStatus(capability: RichDiffLoader.capability, on: dashboard) else {
                throw RichDiffLoader.LoadError.notConnected
            }
            return try await bridge.requestJSON(path: path)
        }
    }

    /// A review card reads its rounds' pages from its chat's Hermes, the
    /// one whose plugin kept them; an id from another Hermes is answered as
    /// gone there.
    func installRichReviewReader() {
        RichReviewLoader.shared.read = { [weak self] path, dashboard in
            guard let bridge = await self?.richCardReadBridgeAfterStatus(capability: RichReviewLoader.capability, on: dashboard) else {
                throw RichReviewLoader.LoadError.notConnected
            }
            return try await bridge.requestJSON(path: path)
        }
    }
}
