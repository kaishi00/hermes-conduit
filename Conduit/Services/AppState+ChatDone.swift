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

    /// Another combined dashboard's chat keeps its marks on that dashboard,
    /// whose plugin says whether it has them.
    func canMarkSessionDone(_ session: SessionSummary) -> Bool {
        guard session.combinedDashboardID != nil else { return chatDoneAvailable }
        return V2ShellPreference.isOn && chatMarksHome(session)?.plugin.reports(ChatDoneMarks.capability) == true
    }

    func isSessionDone(_ session: SessionSummary) -> Bool {
        guard let far = session.combinedDashboardID else {
            guard chatDoneMarks.dashboardID == activeDashboardID else { return false }
            return chatDoneMarks.isDone(session, profile: rowProfile(session))
        }
        guard let marks = farChatDoneMarks[far], let home = chatMarksHome(session) else { return false }
        return marks.isDone(home.session, profile: home.profile)
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

    /// Marks the chat at once, then on its host. A read that went out
    /// before the write's answer is dropped, so it can't put the old mark
    /// back; once no write is pending the marks are read again, which also
    /// puts a refused mark back as the host has it.
    func setSessionDone(_ session: SessionSummary, done: Bool) {
        guard canMarkSessionDone(session), let home = chatMarksHome(session) else { return }
        let (bridge, profile, dashboardID, row) = (home.bridge, home.profile, home.dashboardID, home.session)
        let key = chatDoneMarksKey(profile, dashboardID: dashboardID)
        keepChatDoneMarks(doneMarks(of: dashboardID).setting(row, done: done, profile: profile, dashboardID: dashboardID),
                          of: dashboardID)
        chatDoneMarksPendingWrites[key, default: 0] += 1
        // The fence: a read that went out before this is dropped. No read
        // starts while the write is pending, so one move per write is enough.
        chatDoneMarksWrites[key, default: 0] += 1
        // One write at a time per profile, in the order they were made: each
        // sets done outright, so the last one the user made is the one kept.
        let previous = chatDoneMarksWriteTail[key]
        let write = Task { @MainActor [weak self] in
            await previous?.value
            do {
                _ = try await bridge.requestJSON(path: ChatDoneMarks.savePath(profile: profile), method: "POST",
                                                 body: ChatDoneMarks.body(for: row, done: done))
            } catch {
                sessionCatalogLog.notice("Done mark not saved: \(LogRedaction.describing(error), privacy: .public)")
            }
            guard let self else { return }
            let pending = max((self.chatDoneMarksPendingWrites[key] ?? 1) - 1, 0)
            self.chatDoneMarksPendingWrites[key] = pending == 0 ? nil : pending
            // Its dashboard as it's connected now (switched to or away from
            // meanwhile, it's still that dashboard's marks).
            if pending == 0, let current = self.chatMarksBridge(dashboardID) {
                self.readChatDoneMarks(dashboardID: dashboardID, bridge: current, profiles: [profile], force: true)
            }
        }
        chatDoneMarksWriteTail[key] = write
        Task { @MainActor [weak self] in
            await write.value
            if self?.chatDoneMarksWriteTail[key] == write { self?.chatDoneMarksWriteTail[key] = nil }
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
        readChatDoneMarks(dashboardID: activeDashboardID, bridge: bridge, profiles: profiles ?? chatDoneMarksProfiles,
                          force: force, now: now)
    }

    /// Reads a dashboard's profiles' marks through its bridge: the one on
    /// screen's (`refreshChatDoneMarks`) or another combined dashboard's
    /// (`refreshFarChatMarks`).
    func readChatDoneMarks(dashboardID: UUID?, bridge: DashboardTicketBridge, profiles: [String], force: Bool = false,
                           now: Date = Date()) {
        for profile in profiles {
            let key = chatDoneMarksKey(profile, dashboardID: dashboardID)
            guard !chatDoneMarksReads.contains(key), chatDoneMarksPendingWrites[key] == nil else { continue }
            // Marks another dashboard's read dropped are read again at once,
            // each profile's, even once this dashboard's marks are back.
            if !force, doneMarks(of: dashboardID).hasRead(profile, dashboardID: dashboardID),
               let last = chatDoneMarksReadAt[key],
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
                // A dashboard switched or signed in again meanwhile has
                // marks of its own.
                guard self.chatMarksBridge(dashboardID) === bridge else { return }
                // A mark made since this read went out: dropped. Its write's
                // answer reads them again, or, when that answer came while
                // this read was out (so it read nothing), this does.
                guard (self.chatDoneMarksWrites[key] ?? 0) == writes else {
                    if self.chatDoneMarksPendingWrites[key] == nil {
                        self.readChatDoneMarks(dashboardID: dashboardID, bridge: bridge, profiles: [profile], force: true)
                    }
                    return
                }
                guard let answer, let marks = ChatDoneMarks.marks(from: answer) else { return }
                self.chatDoneMarksReadFailureLogged.remove(key)
                self.keepChatDoneMarks(
                    self.doneMarks(of: dashboardID).replacing(marks, profile: profile, dashboardID: dashboardID),
                    of: dashboardID)
            }
        }
    }
}
