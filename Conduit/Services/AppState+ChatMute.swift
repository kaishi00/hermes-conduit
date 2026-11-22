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

    /// Another combined dashboard's chat is muted on that dashboard.
    func canMuteSession(_ session: SessionSummary) -> Bool {
        chatMuteAvailable && session.combinedDashboardID == nil
    }

    /// The chat's mute while it lasts.
    func sessionMute(_ session: SessionSummary, now: Date = Date()) -> ChatMutes.Mute? {
        guard session.combinedDashboardID == nil, chatMutes.dashboardID == activeDashboardID else { return nil }
        return chatMutes.mute(for: session, profile: rowProfile(session), now: now)
    }

    /// Mutes the chat for `duration`, or unmutes it (nil): at once here,
    /// then on the host, whose answer replaces what this showed. One write
    /// at a time per profile, in the order they were made.
    func setSessionMute(_ session: SessionSummary, duration: ChatMutes.Duration?) {
        guard canMuteSession(session), let bridge = dashboardTicketBridge else { return }
        let profile = rowProfile(session)
        let dashboardID = activeDashboardID
        let key = chatDoneMarksKey(profile, dashboardID: dashboardID)
        let next = chatMutes.setting(session, duration: duration, profile: profile, dashboardID: dashboardID)
        if next != chatMutes { chatMutes = next }
        chatMutesPendingWrites[key, default: 0] += 1
        chatMutesWrites[key, default: 0] += 1
        let body = ChatMutes.body(for: session, duration: duration)
        let previous = chatMutesWriteTail[key]
        let write = Task { @MainActor [weak self] in
            await previous?.value
            var answer: [String: Any]?
            do {
                answer = try await bridge.requestJSON(path: ChatMutes.path(profile: profile), method: "PUT", body: body)
            } catch {
                sessionCatalogLog.notice("Chat mute not saved: \(LogRedaction.describing(error), privacy: .public)")
                if !(error is CancellationError), self?.activeDashboardID == dashboardID {
                    self?.errorMessage = AppLocalization.string(
                        "Could not change this chat's notifications: \(UserFacingError.message(for: error))", table: .chat)
                }
            }
            guard let self else { return }
            let pending = max((self.chatMutesPendingWrites[key] ?? 1) - 1, 0)
            self.chatMutesPendingWrites[key] = pending == 0 ? nil : pending
            guard pending == 0, self.activeDashboardID == dashboardID else { return }
            if let answer, let mutes = ChatMutes.mutes(from: answer) {
                let kept = self.chatMutes.replacing(mutes, profile: profile, dashboardID: dashboardID)
                if kept != self.chatMutes { self.chatMutes = kept }
                self.chatMutesReadAt[key] = Date()
            } else {
                // Refused: read back what the host kept.
                self.refreshChatMutes(profiles: [profile], force: true)
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
        let dashboardID = activeDashboardID
        for profile in profiles ?? chatDoneMarksProfiles {
            let key = chatDoneMarksKey(profile, dashboardID: dashboardID)
            guard !chatMutesReads.contains(key), chatMutesPendingWrites[key] == nil else { continue }
            if !force, chatMutes.hasRead(profile, dashboardID: dashboardID), let last = chatMutesReadAt[key],
               now.timeIntervalSince(last) < Self.chatMutesReadInterval { continue }
            chatMutesReads.insert(key)
            chatMutesReadAt[key] = now
            let writes = chatMutesWrites[key] ?? 0
            Task { @MainActor [weak self] in
                let answer = try? await bridge.requestJSON(path: ChatMutes.path(profile: profile))
                guard let self else { return }
                self.chatMutesReads.remove(key)
                guard self.activeDashboardID == dashboardID, self.dashboardTicketBridge === bridge,
                      self.chatMutesPendingWrites[key] == nil else { return }
                // A mute made since this read went out: dropped. Its write's
                // answer reads them again, or, when that answer came while
                // this read was out (so it read nothing), this does, as Done
                // marks do.
                guard (self.chatMutesWrites[key] ?? 0) == writes else {
                    self.refreshChatMutes(profiles: [profile], force: true)
                    return
                }
                guard let answer, let mutes = ChatMutes.mutes(from: answer) else { return }
                let next = self.chatMutes.replacing(mutes, profile: profile, dashboardID: dashboardID)
                if next != self.chatMutes { self.chatMutes = next }
            }
        }
    }
}
