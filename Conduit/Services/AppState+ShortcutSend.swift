//
//  AppState+ShortcutSend.swift
//  Conduit
//
//  Binds the "Send to Hermes" Shortcuts action (SendToHermesIntent) to the
//  client in use. A run makes or resumes its own chat and talks to it over
//  the connection directly; when that chat is the one on screen, the text
//  goes through the composer so it shows and streams like a typed message.
//

import Foundation

@MainActor
extension AppState {
    func sendFromShortcut(_ request: ShortcutSendRequest, deadline: Date) async throws -> ShortcutSendOutcome {
        try await ShortcutSender(backend: makeShortcutSendBackend()).send(request, deadline: deadline)
    }

    func makeShortcutSendBackend() -> ShortcutSendBackend {
        // The error a failed composer try left, for the run to clear once
        // its retry lands.
        let failedTry = ShortcutFailedTry()
        return ShortcutSendBackend(
            connect: { [weak self] deadline in
                guard let self else { return false }
                // Leave time to send once connected.
                let wait = max(0, min(12, deadline.timeIntervalSinceNow - 8))
                guard await CarPlayVoiceCoordinator.awaitConnection(of: self, timeout: .seconds(wait)) else { return false }
                return self.client != nil
            },
            activeProfile: { [weak self] in self?.activeProfile ?? "default" },
            createChat: { [weak self] profile, title in
                guard let self, let client = self.client else { throw HermesError.notConnected }
                let inUse = self.profilesMatch(profile, self.activeProfile)
                // As a chat started from the composer: the profile's default
                // model, not the open chat's (#916).
                let created = try await client.createSession(inProfile: inUse ? nil : profile)
                if let returned = created.profile, !self.profilesMatch(returned, profile) {
                    throw HermesError.invalidResponse
                }
                try? await client.setSessionTitle(created.sessionId, title: title, profile: inUse ? nil : profile)
                return VoiceThreadTarget(runtimeSessionID: created.sessionId, storedSessionID: created.storedSessionId,
                                         title: title, profile: profile)
            },
            resumeChat: { [weak self] chat in
                guard let self else { throw HermesError.notConnected }
                return try await self.liveVoiceThreadRuntime(self.scopedShortcutChat(chat))
            },
            reopenChat: { [weak self] chat in
                guard let self else { throw HermesError.notConnected }
                return try await self.reopenVoiceThreadRuntime(self.scopedShortcutChat(chat))
            },
            submit: { [weak self] chat, runtimeID, text in
                guard let self, let client = self.client else { throw HermesError.notConnected }
                let scoped = self.scopedShortcutChat(chat)
                // Shortcut text is literal: "/…" never runs a composer command.
                if self.isOpenChat(scoped), self.activeSessionId == runtimeID,
                   !self.isBusy, Self.parseSlashCommand(text) == nil {
                    // Right after a cold launch the open chat's id is the one
                    // from before, until the chat's own resume. The composer
                    // only gets a runtime Hermes still has: a dead one would
                    // leave a failed send on screen and the text back in the
                    // composer. The run reopens the chat and sends again.
                    guard await self.voiceThreadRuntimeIsLive(runtimeID, profile: scoped.profile) else {
                        throw RpcError(code: 4001, message: "session not found")
                    }
                    // A turn the composer finds running is never steered or
                    // interrupted from here: it declines and the gateway queues.
                    self.submissionTurnSurface = (text, .shortcut)
                    defer { self.submissionTurnSurface = nil }
                    let errorBefore = self.errorMessage
                    if await self.submitComposer(text: text, onBusy: {}) { return .accepted }
                    // A runtime that died after the check (or a check that
                    // couldn't read): the composer showed "Failed to send".
                    if let error = self.errorMessage, error != errorBefore { failedTry.error = error }
                }
                // Off screen, a turn running there, or a composer that couldn't
                // take it (still synchronizing): Hermes takes it, queues it or
                // joins the turn running.
                await self.reportTurnSurface(.shortcut, runtimeSessionID: runtimeID, text: text)?.value
                return try await self.sendShortcutPrompt(runtimeID, text: text)
            },
            liveSessions: { [weak self] profile in
                guard let self, let client = self.client else { throw HermesError.notConnected }
                return try await client.activeSessions(inProfile: self.profilesMatch(profile, self.activeProfile) ? nil : profile)
            },
            latestReply: { [weak self] chat in
                guard let self,
                      let latest = await self.latestLiveVoiceThreadReplyMessage(self.scopedShortcutChat(chat)) else { return nil }
                return ShortcutReply(text: latest.message.content, rowID: latest.message.rowId,
                                     openChatID: latest.inOpenChat ? latest.message.id : nil)
            },
            retryLanded: { [weak self] in
                // The text went in after all: the failed try's error goes.
                guard let self, let error = failedTry.error else { return }
                failedTry.error = nil
                if self.errorMessage == error { self.errorMessage = nil }
            }
        )
    }

    /// The chat as the live-chat helpers expect it: no profile when it lives
    /// in the profile in use.
    private func scopedShortcutChat(_ chat: VoiceThreadTarget) -> VoiceThreadTarget {
        var scoped = chat
        if let profile = chat.profile, profilesMatch(profile, activeProfile) { scoped.profile = nil }
        return scoped
    }
}

/// The "Failed to send" a run's first composer try left on screen.
@MainActor
private final class ShortcutFailedTry {
    var error: String?
}
