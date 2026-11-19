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

    /// The read and write bookkeeping's key: a profile on one dashboard,
    /// so a switch to another with a profile of the same name reads its
    /// marks at once rather than after the last one's interval.
    func chatDoneMarksKey(_ profile: String, dashboardID: UUID?) -> String {
        "\(dashboardID?.uuidString ?? "-")\u{1F}\(profile.lowercased())"
    }

    /// Marks the chat at once, then on the host. A read that went out
    /// before the write's answer is dropped, so it can't put the old mark
    /// back; once no write is pending the marks are read again, which also
    /// puts a refused mark back as the host has it.
    func setSessionDone(_ session: SessionSummary, done: Bool) {
        guard canMarkSessionDone(session), let bridge = dashboardTicketBridge else { return }
        let profile = rowProfile(session)
        let dashboardID = activeDashboardID
        let key = chatDoneMarksKey(profile, dashboardID: dashboardID)
        let next = chatDoneMarks.setting(session, done: done, profile: profile, dashboardID: dashboardID)
        if next != chatDoneMarks { chatDoneMarks = next }
        chatDoneMarksPendingWrites[key, default: 0] += 1
        chatDoneMarksWrites[key, default: 0] += 1
        Task { @MainActor [weak self] in
            do {
                _ = try await bridge.requestJSON(path: ChatDoneMarks.savePath(profile: profile), method: "POST",
                                                 body: ChatDoneMarks.body(for: session, done: done))
            } catch {
                sessionCatalogLog.notice("Done mark not saved: \(LogRedaction.describing(error), privacy: .public)")
            }
            guard let self else { return }
            let pending = max((self.chatDoneMarksPendingWrites[key] ?? 1) - 1, 0)
            self.chatDoneMarksPendingWrites[key] = pending == 0 ? nil : pending
            self.chatDoneMarksWrites[key, default: 0] += 1
            if pending == 0, self.activeDashboardID == dashboardID {
                self.refreshChatDoneMarks(profiles: [profile], force: true)
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
    /// `chatDoneMarksReadInterval` unless `force`. A profile with a write
    /// on its way waits for it: its answer reads the marks again.
    func refreshChatDoneMarks(profiles: [String]? = nil, force: Bool = false, now: Date = Date()) {
        guard chatDoneAvailable, let bridge = dashboardTicketBridge else { return }
        let dashboardID = activeDashboardID
        for profile in profiles ?? chatDoneMarksProfiles {
            let key = chatDoneMarksKey(profile, dashboardID: dashboardID)
            guard !chatDoneMarksReads.contains(key), chatDoneMarksPendingWrites[key] == nil else { continue }
            if !force, let last = chatDoneMarksReadAt[key],
               now.timeIntervalSince(last) < Self.chatDoneMarksReadInterval { continue }
            chatDoneMarksReads.insert(key)
            chatDoneMarksReadAt[key] = now
            let writes = chatDoneMarksWrites[key] ?? 0
            Task { @MainActor [weak self] in
                let answer: [String: Any]?
                do {
                    answer = try await bridge.requestJSON(path: ChatDoneMarks.readPath(profile: profile))
                } catch {
                    answer = nil
                    // Once per profile: an empty Done list is then explained.
                    if self?.chatDoneMarksReadFailureLogged.insert(key).inserted == true {
                        sessionCatalogLog.notice("Done marks not read: \(LogRedaction.describing(error), privacy: .public)")
                    }
                }
                guard let self else { return }
                self.chatDoneMarksReads.remove(key)
                // A dashboard switched meanwhile has marks of its own.
                guard self.activeDashboardID == dashboardID, self.dashboardTicketBridge === bridge else { return }
                // A mark made since this read went out: dropped. Its write's
                // answer reads them again, or, when that answer came while
                // this read was out (so it read nothing), this does.
                guard (self.chatDoneMarksWrites[key] ?? 0) == writes else {
                    if self.chatDoneMarksPendingWrites[key] == nil {
                        self.refreshChatDoneMarks(profiles: [profile], force: true)
                    }
                    return
                }
                guard let answer, let marks = ChatDoneMarks.marks(from: answer) else { return }
                self.chatDoneMarksReadFailureLogged.remove(key)
                let next = self.chatDoneMarks.replacing(marks, profile: profile, dashboardID: dashboardID)
                if next != self.chatDoneMarks { self.chatDoneMarks = next }
            }
        }
    }
}
