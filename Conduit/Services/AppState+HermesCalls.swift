//
//  AppState+HermesCalls.swift
//  Conduit
//
//  Hermes calls you (#449): the host's call settings for Voice settings,
//  the job layer's watches on the host, and answering a call from Hermes,
//  which opens voice in the job's chat with what came of the job.
//  Design: /mnt/project-files/designs/hermes-calls-you-449.md
//

import Foundation
import OSLog

private let hermesCallsStateLogger = Logger(subsystem: "com.milim.relay", category: "HermesCalls")

extension AppState {
    /// Whether the host's notifier plugin takes call watches (plugin 0.13+).
    var supportsHermesCalls: Bool {
        if case .reported(_, let capabilities) = notifierPlugin.state { return capabilities.contains("hermes-calls") }
        return false
    }

    /// The active profile's call settings, once read from this dashboard.
    var activeHermesCallsStatus: HermesCallsStatus? {
        guard hermesCallsStatusKey == hermesCallsKey(profile: activeProfile) else { return nil }
        return hermesCallsStatus
    }

    /// Whether Hermes can call the user when a live call's work is done.
    /// Settings not read yet count as on: the host refuses the watch if
    /// they're off, and the call hears so.
    var hermesCallbackAvailability: VoiceCallbackAvailability {
        guard supportsHermesCalls else { return .unsupported }
        return activeHermesCallsStatus?.callbackAvailability ?? .available
    }

    private func hermesCallsKey(profile: String) -> String {
        (activeDashboardID?.uuidString ?? "") + "|" + profile
    }

    func refreshHermesCallsStatus() async {
        guard supportsHermesCalls else { return }
        let key = hermesCallsKey(profile: activeProfile)
        do {
            let status = try await hermesCallsClient.status(profile: activeProfile)
            guard key == hermesCallsKey(profile: activeProfile) else { return }
            hermesCallsStatus = status
            hermesCallsStatusKey = key
        } catch {
            hermesCallsStateLogger.notice("Call settings not read: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Saves a profile's call settings: the one shown when they were
    /// changed, even if another is active by the time the save goes. False
    /// when the host didn't take them; the settings shown stay the host's.
    @discardableResult
    func saveHermesCallSettings(_ settings: HermesCallSettings, profile: String, dashboardID: UUID?) async -> Bool {
        // Another server's host has no say over this one's profiles.
        guard dashboardID == activeDashboardID else { return false }
        let key = hermesCallsKey(profile: profile)
        do {
            let saved = try await hermesCallsClient.save(settings, profile: profile)
            // Saved; shown only while that profile still is.
            guard key == hermesCallsKey(profile: activeProfile) else { return true }
            if var status = activeHermesCallsStatus {
                status.settings = saved
                hermesCallsStatus = status
            } else {
                await refreshHermesCallsStatus()
            }
            return true
        } catch {
            hermesCallsStateLogger.error("Call settings not saved: \(error.localizedDescription, privacy: .public)")
            errorMessage = AppLocalization.string("Couldn't save Hermes' call settings. Check your connection and try again.")
            return false
        }
    }

    /// How GPT-Live asks for a call, when the host takes call watches.
    /// Gemini and Grok Live have the call_me_when_done tool instead.
    func hermesCallsInstructions(delegation: Bool) -> String {
        guard delegation, supportsHermesCalls else { return "" }
        return GPTLiveConversationController.callMeRule
    }

    /// The job layer's way to the host's call watches.
    func makeHermesCallbackBackend() -> VoiceCallbackBackend {
        VoiceCallbackBackend(
            availability: { [weak self] in self?.hermesCallbackAvailability ?? .unsupported },
            watch: { [weak self] target, holdSeconds, endedWithinSeconds in
                guard let self else { throw DashboardTicketBridgeError.notReady }
                return try await self.hermesCallsClient.watch(
                    sessionIDs: target.sessionIDs,
                    title: target.title,
                    profile: target.profile ?? self.activeProfile,
                    holdSeconds: holdSeconds,
                    endedWithinSeconds: endedWithinSeconds
                )
            },
            hold: { [weak self] watchID, profile, seconds in
                guard let self else { throw DashboardTicketBridgeError.notReady }
                return try await self.hermesCallsClient.hold(watchID: watchID, profile: profile ?? self.activeProfile, seconds: seconds)
            },
            cancel: { [weak self] watchID, profile in
                guard let self else { throw DashboardTicketBridgeError.notReady }
                try await self.hermesCallsClient.cancel(watchID: watchID, profile: profile ?? self.activeProfile)
            },
            notify: { [weak self] target, kind in
                guard let self else { return }
                await HermesCallNotifications.post(HermesCallNotifications.localRequest(
                    for: target,
                    kind: kind,
                    profile: target.profile ?? self.activeProfile,
                    dashboardID: self.activeDashboardID
                ))
            }
        )
    }

    /// The live call on `engine` is hanging up: the job layer lets go of
    /// what it asked to be called about. Called before the call stops,
    /// while its transcript still reads; runs on in the background.
    func finishHermesCallbacks(engine: VoiceCallEngine) {
        guard hermesCallbackEngine == engine else { return }
        hermesCallbackEngine = nil
        guard let task = voiceBackgroundJobSupervisor.finishCallbacks() else { return }
        let end = beginVoiceTranscriptBackgroundTask(named: "conduit.hermesCalls.hangUp")
        Task {
            await task.value
            end()
        }
    }

    /// Answers a call from Hermes (#449). Its chat is on screen: voice opens
    /// there and starts with what came of the job instead of a greeting.
    func answerHermesCall(_ call: HermesCallRequest) {
        // Voice already running (or no gateway): the job's news reaches the
        // user the usual way.
        guard isConnected, !isVoiceInUse else { return }
        // The call tells the user how the job went; no voice conversation
        // announces it again.
        voiceBackgroundJobSupervisor.noteCallAnswered(sessionIDs: call.sessionIDs)
        let thread = liveVoiceThreadForOpenChat()
        let opening = HermesCallOpening(
            kind: call.kind,
            title: call.title ?? thread?.title,
            result: thread.flatMap { latestReplyInOpenChat($0) }
        )
        let profile = activeProfile
        let intent = PendingVoiceIntent(profile: profile, startsFreshConversation: false, source: .hermesCall)
        Task { [weak self] in
            guard let self else { return }
            if self.configuredLiveVoiceEngine(profile: profile) != nil {
                self.pendingHermesCall = opening
                _ = await self.openVoiceConversation(intent)
                // Starting the call took it; a later unrelated call must not.
                self.pendingHermesCall = nil
            } else {
                // Classic voice says it at its first listening window.
                self.voiceBackgroundJobSupervisor.queueCallOpening(opening.spokenBrief)
                if !(await self.openVoiceConversation(intent)) || !self.showVoiceSheet {
                    self.voiceBackgroundJobSupervisor.clearCallOpening()
                }
            }
        }
    }
}
