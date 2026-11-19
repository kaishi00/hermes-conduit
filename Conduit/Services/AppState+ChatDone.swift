//
//  AppState+ChatDone.swift
//  Conduit
//
//  Done chats (ChatDoneMarks): read from the plugin with the list, marked
//  from a row's menu or swipe, and shown dimmed with a check.
//

import Foundation

extension AppState {
    /// A list reads a profile's marks at most this often; a mark made here
    /// shows at once, and the agent's lands with its turn's list read.
    static let chatDoneMarksReadInterval: TimeInterval = 15

    /// Done is offered: V2's list, which has its filter, on a plugin that
    /// keeps the marks.
    var chatDoneAvailable: Bool {
        V2ShellPreference.isOn && notifierPlugin.reports(ChatDoneMarks.capability)
    }

    /// Another combined dashboard's chat keeps its marks on that dashboard.
    func canMarkSessionDone(_ session: SessionSummary) -> Bool {
        chatDoneAvailable && session.combinedDashboardID == nil
    }

    func isSessionDone(_ session: SessionSummary) -> Bool {
        guard session.combinedDashboardID == nil, chatDoneMarks.dashboardID == activeDashboardID else { return false }
        return chatDoneMarks.isDone(session, profile: rowProfile(session))
    }

    func toggleSessionDone(_ session: SessionSummary) {
        setSessionDone(session, done: !isSessionDone(session))
    }

    /// Marks the chat at once, then on the host; a refused write puts the
    /// mark back as the host has it.
    func setSessionDone(_ session: SessionSummary, done: Bool) {
        guard canMarkSessionDone(session), let bridge = dashboardTicketBridge else { return }
        let profile = rowProfile(session)
        let dashboardID = activeDashboardID
        let next = chatDoneMarks.setting(session, done: done, profile: profile, dashboardID: dashboardID)
        if next != chatDoneMarks { chatDoneMarks = next }
        Task { @MainActor [weak self] in
            do {
                _ = try await bridge.requestJSON(path: ChatDoneMarks.savePath(profile: profile), method: "POST",
                                                 body: ChatDoneMarks.body(for: session, done: done))
            } catch {
                guard let self else { return }
                sessionCatalogLog.notice("Done mark not saved: \(LogRedaction.describing(error), privacy: .public)")
                self.chatDoneMarksReadAt[profile] = nil
                self.refreshChatDoneMarks(profiles: [profile])
            }
        }
    }

    /// The profiles whose rows the list shows: the one in use, and All's.
    var chatDoneMarksProfiles: [String] {
        guard isAllProfilesChatsOn else { return [activeProfile] }
        let others = allProfilesIncluded.filter { !Self.profilesMatch($0, activeProfile) }
        return [activeProfile] + others
    }

    /// Reads the marks of the profiles the list shows, each at most every
    /// `chatDoneMarksReadInterval` unless `force`.
    func refreshChatDoneMarks(profiles: [String]? = nil, force: Bool = false, now: Date = Date()) {
        guard chatDoneAvailable, let bridge = dashboardTicketBridge else { return }
        let dashboardID = activeDashboardID
        for profile in profiles ?? chatDoneMarksProfiles {
            guard !chatDoneMarksReads.contains(profile) else { continue }
            if !force, let last = chatDoneMarksReadAt[profile],
               now.timeIntervalSince(last) < Self.chatDoneMarksReadInterval { continue }
            chatDoneMarksReads.insert(profile)
            chatDoneMarksReadAt[profile] = now
            Task { @MainActor [weak self] in
                let answer = try? await bridge.requestJSON(path: ChatDoneMarks.readPath(profile: profile))
                guard let self else { return }
                self.chatDoneMarksReads.remove(profile)
                // A dashboard switched meanwhile has marks of its own.
                guard self.activeDashboardID == dashboardID, self.dashboardTicketBridge === bridge,
                      let answer, let marks = ChatDoneMarks.marks(from: answer) else { return }
                let next = self.chatDoneMarks.replacing(marks, profile: profile, dashboardID: dashboardID)
                if next != self.chatDoneMarks { self.chatDoneMarks = next }
            }
        }
    }
}
