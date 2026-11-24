//
//  AppState+ChatMute.swift
//  Conduit
//
//  Muted chats (ChatMutes): read from the plugin with the list, set from a
//  row's menu, kept on the host so its turn-end hooks skip the pushes.
//

import Foundation

extension AppState {
    /// A list reads a profile's mutes at most this often; a mute set here
    /// shows at once.
    static let chatMutesReadInterval: TimeInterval = 30

    /// Mute is offered on a plugin that keeps muted chats.
    var chatMuteAvailable: Bool {
        notifierPlugin.reports(ChatMutes.capability)
    }

    /// Another combined dashboard's chat is muted on that dashboard, whose
    /// plugin says whether it keeps mutes.
    func canMuteSession(_ session: SessionSummary) -> Bool {
        guard session.combinedDashboardID != nil else { return chatMuteAvailable }
        return chatMarksHome(session)?.plugin.reports(ChatMutes.capability) == true
    }

    /// The chat's mute while it lasts.
    func sessionMute(_ session: SessionSummary, now: Date = Date()) -> ChatMutes.Mute? {
        guard let far = session.combinedDashboardID else {
            guard chatMutes.dashboardID == activeDashboardID else { return nil }
            return chatMutes.mute(for: session, profile: rowProfile(session), now: now)
        }
        guard far != dashboardIDOnScreen, let mutes = farChatMutes[far] else { return nil }
        let (row, owner) = farChatMarksRow(session, in: far)
        // As the mutes spell it: a dashboard that dropped lists no profiles.
        let profile = mutes.mutesByProfile.keys.first { Self.profilesMatch($0, owner) } ?? owner
        return mutes.mute(for: row, profile: profile, now: now)
    }

    /// Mutes the chat for `duration`, or unmutes it (nil): at once here,
    /// then on its host, whose answer replaces what this showed. One write
    /// at a time per profile, in the order they were made.
    func setSessionMute(_ session: SessionSummary, duration: ChatMutes.Duration?) {
        guard canMuteSession(session), let home = chatMarksHome(session) else { return }
        let (bridge, profile, dashboardID, row) = (home.bridge, home.profile, home.dashboardID, home.session)
        let key = chatDoneMarksKey(profile, dashboardID: dashboardID)
        keepChatMutes(mutes(of: dashboardID).setting(row, duration: duration, profile: profile, dashboardID: dashboardID),
                      of: dashboardID)
        chatMutesPendingWrites[key, default: 0] += 1
        chatMutesWrites[key, default: 0] += 1
        let body = ChatMutes.body(for: row, duration: duration)
        let previous = chatMutesWriteTail[key]
        let write = Task { @MainActor [weak self] in
            await previous?.value
            var answer: [String: Any]?
            do {
                answer = try await bridge.requestJSON(path: ChatMutes.path(profile: profile), method: "PUT", body: body)
            } catch {
                sessionCatalogLog.notice("Chat mute not saved: \(LogRedaction.describing(error), privacy: .public)")
                if !(error is CancellationError), self?.chatMarksBridge(dashboardID) != nil {
                    self?.errorMessage = AppLocalization.string(
                        "Could not change this chat's notifications: \(UserFacingError.message(for: error))", table: .chat)
                }
            }
            guard let self else { return }
            let pending = max((self.chatMutesPendingWrites[key] ?? 1) - 1, 0)
            self.chatMutesPendingWrites[key] = pending == 0 ? nil : pending
            // A dashboard switched or signed in again meanwhile has mutes of its own.
            guard pending == 0, let current = self.chatMarksBridge(dashboardID) else { return }
            guard current === bridge else {
                // Its answer isn't this connection's: read what the host keeps.
                self.readChatMutes(dashboardID: dashboardID, bridge: current, profiles: [profile], force: true)
                return
            }
            if let answer, let mutes = ChatMutes.mutes(from: answer) {
                self.keepChatMutes(
                    self.mutes(of: dashboardID).replacing(mutes, profile: profile, dashboardID: dashboardID),
                    of: dashboardID)
                self.chatMutesReadAt[key] = Date()
            } else {
                // Refused: read back what the host kept.
                self.readChatMutes(dashboardID: dashboardID, bridge: bridge, profiles: [profile], force: true)
            }
        }
        chatMutesWriteTail[key] = write
        Task { @MainActor [weak self] in
            await write.value
            if self?.chatMutesWriteTail[key] == write { self?.chatMutesWriteTail[key] = nil }
        }
    }

    /// Reads the mutes of the profiles the list shows (Done marks' list),
    /// each at most every `chatMutesReadInterval` unless `force`. A profile
    /// with a write on its way waits for its answer.
    func refreshChatMutes(profiles: [String]? = nil, force: Bool = false, now: Date = Date()) {
        guard chatMuteAvailable, let bridge = dashboardTicketBridge else { return }
        readChatMutes(dashboardID: activeDashboardID, bridge: bridge, profiles: profiles ?? chatDoneMarksProfiles,
                      force: force, now: now)
    }

    /// Reads a dashboard's profiles' mutes through its bridge: the one on
    /// screen's (`refreshChatMutes`) or another combined dashboard's
    /// (`refreshFarChatMarks`).
    func readChatMutes(dashboardID: UUID?, bridge: DashboardTicketBridge, profiles: [String], force: Bool = false,
                       now: Date = Date()) {
        for profile in profiles {
            let key = chatDoneMarksKey(profile, dashboardID: dashboardID)
            guard !chatMutesReads.contains(key), chatMutesPendingWrites[key] == nil else { continue }
            if !force, mutes(of: dashboardID).hasRead(profile, dashboardID: dashboardID), let last = chatMutesReadAt[key],
               now.timeIntervalSince(last) < Self.chatMutesReadInterval { continue }
            chatMutesReads.insert(key)
            chatMutesReadAt[key] = now
            let writes = chatMutesWrites[key] ?? 0
            Task { @MainActor [weak self] in
                let answer: [String: Any]?
                do {
                    answer = try await bridge.requestJSON(path: ChatMutes.path(profile: profile))
                } catch {
                    answer = nil
                    // Once per profile, as Done marks do: a missing bell is then explained.
                    if self?.chatMutesReadFailureLogged.insert(key).inserted == true {
                        sessionCatalogLog.notice("Chat mutes not read: \(LogRedaction.describing(error), privacy: .public)")
                    }
                }
                guard let self else { return }
                self.chatMutesReads.remove(key)
                guard self.chatMarksBridge(dashboardID) === bridge, self.chatMutesPendingWrites[key] == nil else { return }
                // A mute made since this read went out: dropped. Its write's
                // answer reads them again, or, when that answer came while
                // this read was out (so it read nothing), this does, as Done
                // marks do.
                guard (self.chatMutesWrites[key] ?? 0) == writes else {
                    self.readChatMutes(dashboardID: dashboardID, bridge: bridge, profiles: [profile], force: true)
                    return
                }
                guard let answer, let mutes = ChatMutes.mutes(from: answer) else { return }
                self.keepChatMutes(
                    self.mutes(of: dashboardID).replacing(mutes, profile: profile, dashboardID: dashboardID),
                    of: dashboardID)
            }
        }
    }

    /// Drops the mutes that ended when the next one ends, so its row's bell
    /// and "Unmute (Muted Until …)" go then, not at the next read.
    func scheduleChatMuteEnd(now: Date = Date()) {
        let next = chatMutes.nextEnd(after: now)
        guard chatMutesEnd?.at != next else { return }
        chatMutesEnd?.task.cancel()
        guard let next else {
            chatMutesEnd = nil
            return
        }
        chatMutesEnd = (next, Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.chatMutesEnd = nil
            let lasting = self.chatMutes.droppingEnded(at: Date())
            if lasting != self.chatMutes { self.chatMutes = lasting } else { self.scheduleChatMuteEnd() }
        })
    }
}
