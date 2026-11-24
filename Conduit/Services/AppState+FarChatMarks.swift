//
//  AppState+FarChatMarks.swift
//  Conduit
//
//  Done marks and mutes of the other combined dashboards' chats: each
//  dashboard's plugin keeps its own, so a chat opened in place is marked
//  done and muted on its own dashboard, and its row shows it, without a
//  switch (AppState+ChatDone.swift and AppState+ChatMute.swift read and
//  write them through that dashboard's kept bridge).
//

import Foundation

extension AppState {
    /// Where a row's Done mark and mute are kept: its own dashboard's
    /// plugin, reached through that dashboard's bridge.
    struct ChatMarksHome {
        let dashboardID: UUID?
        let bridge: DashboardTicketBridge
        let profile: String
        /// The row as its own dashboard lists it.
        let session: SessionSummary
        let plugin: NotifierPluginStatus
    }

    /// Nil when the row's dashboard isn't connected: the one on screen
    /// without a bridge, or another combined one that isn't kept.
    func chatMarksHome(_ session: SessionSummary) -> ChatMarksHome? {
        guard let far = session.combinedDashboardID else {
            guard let bridge = dashboardTicketBridge else { return nil }
            return ChatMarksHome(dashboardID: activeDashboardID, bridge: bridge, profile: rowProfile(session),
                                 session: session, plugin: notifierPlugin)
        }
        guard far != dashboardIDOnScreen, let kept = keptDashboardRuntimes[far] else { return nil }
        var row = session
        row.combinedDashboardID = nil
        // Spelled as that dashboard lists its profiles, which its reads use.
        let owner = session.profile.flatMap { $0.isEmpty ? nil : $0 } ?? kept.runtime.activeProfile
        let profile = keptDashboardProfiles[far]?.profiles.first { Self.profilesMatch($0, owner) } ?? owner
        return ChatMarksHome(dashboardID: far, bridge: kept.bridge, profile: profile, session: row,
                             plugin: kept.runtime.notifierPlugin)
    }

    /// A dashboard's bridge as it's connected now: the one on screen's, or
    /// a kept one's.
    func chatMarksBridge(_ dashboardID: UUID?) -> DashboardTicketBridge? {
        guard dashboardID != dashboardIDOnScreen else { return runtimeOnScreen.dashboardTicketBridge }
        return dashboardID.flatMap { keptDashboardRuntimes[$0]?.bridge }
    }

    func doneMarks(of dashboardID: UUID?) -> ChatDoneMarks {
        guard dashboardID != dashboardIDOnScreen else { return chatDoneMarks }
        return dashboardID.flatMap { farChatDoneMarks[$0] } ?? ChatDoneMarks(dashboardID: dashboardID)
    }

    func keepChatDoneMarks(_ marks: ChatDoneMarks, of dashboardID: UUID?) {
        guard dashboardID != dashboardIDOnScreen else {
            if marks != chatDoneMarks { chatDoneMarks = marks }
            return
        }
        if let dashboardID, farChatDoneMarks[dashboardID] != marks { farChatDoneMarks[dashboardID] = marks }
    }

    func mutes(of dashboardID: UUID?) -> ChatMutes {
        guard dashboardID != dashboardIDOnScreen else { return chatMutes }
        return dashboardID.flatMap { farChatMutes[$0] } ?? ChatMutes(dashboardID: dashboardID)
    }

    func keepChatMutes(_ mutes: ChatMutes, of dashboardID: UUID?) {
        guard dashboardID != dashboardIDOnScreen else {
            if mutes != chatMutes { chatMutes = mutes }
            return
        }
        if let dashboardID, farChatMutes[dashboardID] != mutes { farChatMutes[dashboardID] = mutes }
    }

    /// Reads another combined dashboard's Done marks and mutes for
    /// `profiles`, with its chat list: each at its own interval, and only
    /// what its plugin keeps.
    func refreshFarChatMarks(_ dashboardID: UUID, profiles: [String], force: Bool = false, now: Date = Date()) {
        guard dashboardID != dashboardIDOnScreen, let kept = keptDashboardRuntimes[dashboardID] else { return }
        let plugin = kept.runtime.notifierPlugin
        if V2ShellPreference.isOn, plugin.reports(ChatDoneMarks.capability) {
            readChatDoneMarks(dashboardID: dashboardID, bridge: kept.bridge, profiles: profiles, force: force, now: now)
        }
        if plugin.reports(ChatMutes.capability) {
            readChatMutes(dashboardID: dashboardID, bridge: kept.bridge, profiles: profiles, force: force, now: now)
        }
    }

    /// Lets go of the marks of a dashboard that left the group or came on
    /// screen, where `chatDoneMarks` and `chatMutes` hold its own.
    func dropFarChatMarksOutsideTheGroup() {
        let gone = Set(farChatDoneMarks.keys).union(farChatMutes.keys)
            .filter { !isInCombinedGroup($0) || $0 == dashboardIDOnScreen }
        guard !gone.isEmpty else { return }
        farChatDoneMarks = farChatDoneMarks.filter { !gone.contains($0.key) }
        farChatMutes = farChatMutes.filter { !gone.contains($0.key) }
    }
}
