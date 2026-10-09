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
    /// Whether the host holds calls back while the user is in a live call
    /// (plugin 0.14+).
    var supportsHermesCallPresence: Bool {
        if case .reported(_, let capabilities) = notifierPlugin.state { return capabilities.contains("hermes-call-presence") }
        return false
    }

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
        guard dashboardID == activeDashboardID else {
            hermesCallsStateLogger.notice("Call settings not saved: the server changed since the edit")
            return false
        }
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
        endHermesCallPresence()
        guard let task = voiceBackgroundJobSupervisor.finishCallbacks() else { return }
        let end = beginVoiceTranscriptBackgroundTask(named: "conduit.hermesCalls.hangUp")
        Task {
            await task.value
            end()
        }
    }

    /// Answers a call from Hermes (#449). Its chat is on screen: voice opens
    /// there and starts with what came of the job instead of a greeting.
    /// False when it can't open the call's own voice.
    @discardableResult
    func answerHermesCall(_ call: HermesCallRequest) -> Bool {
        // Voice already running (or no gateway): the job's news reaches the
        // user the usual way.
        guard isConnected, !isVoiceInUse else { return false }
        // The call tells the user how the job went; no voice conversation
        // announces it again.
        voiceBackgroundJobSupervisor.noteCallAnswered(sessionIDs: call.sessionIDs)
        let thread = liveVoiceThreadForOpenChat()
        // Every id the chat is known by, so a spoken answer finds its cards
        // there and nowhere else.
        let chatIDs = activeSessionId.map { hermesCallChatIDs(for: $0) } ?? []
        let opening = HermesCallOpening(
            kind: call.kind,
            title: call.title ?? thread?.title,
            result: thread.flatMap { latestReplyInOpenChat($0) },
            reason: call.reason,
            sessionIDs: call.sessionIDs + chatIDs.subtracting(call.sessionIDs).sorted()
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
        return true
    }

    // MARK: Presence (#449)

    /// How long the host holds calls back past a renewal: the most a lost
    /// phone keeps Hermes from calling.
    static let hermesCallPresenceSeconds = 90
    static let hermesCallPresenceRenewal: Duration = .seconds(30)

    /// A live call is starting: nothing Hermes calls about rings over it
    /// (it sends the usual notification instead). Renewed while voice is
    /// in use.
    func beginHermesCallPresence() {
        guard supportsHermesCallPresence else { return }
        let profile = activeProfile
        // The same call reconnecting keeps the presence it has.
        if hermesCallPresenceTask != nil, hermesCallPresenceProfile == profile { return }
        endHermesCallPresence()
        hermesCallPresenceProfile = profile
        let client = hermesCallsClient
        // A call started right after the last one hung up: its "away" lands
        // first, never over this call's presence.
        let release = hermesCallPresenceRelease
        hermesCallPresenceTask = Task { [weak self] in
            await release?.value
            while !Task.isCancelled {
                do {
                    try await client.setPresence(profile: profile, seconds: Self.hermesCallPresenceSeconds)
                } catch {
                    hermesCallsStateLogger.notice("Call presence not set: \(error.localizedDescription, privacy: .public)")
                }
                do { try await Task.sleep(for: Self.hermesCallPresenceRenewal) } catch { return }
                // A call that ended some other way lets go too.
                guard let self else { return }
                if !self.isVoiceInUse {
                    self.endHermesCallPresence()
                    return
                }
            }
        }
    }

    /// The live call hung up: Hermes may call again. Sent after any renewal
    /// still on its way, so it lands last.
    func endHermesCallPresence() {
        guard let task = hermesCallPresenceTask, let profile = hermesCallPresenceProfile else { return }
        task.cancel()
        hermesCallPresenceTask = nil
        hermesCallPresenceProfile = nil
        let client = hermesCallsClient
        let end = beginVoiceTranscriptBackgroundTask(named: "conduit.hermesCalls.presence")
        let previous = hermesCallPresenceRelease
        hermesCallPresenceRelease = Task {
            await previous?.value
            await task.value
            try? await client.setPresence(profile: profile, seconds: 0)
            end()
        }
    }

    // MARK: Answering by voice (#449 step 4)

    /// The call's chat ids while that chat is still the open one; nil once
    /// the user moved to another, whose cards the call never answers.
    private func hermesCallOpenChatIDs(_ call: HermesCallOpening) -> Set<String>? {
        guard let sessionId = activeSessionId, !sessionId.isEmpty else { return nil }
        let open = hermesCallChatIDs(for: sessionId)
        return open.isDisjoint(with: call.sessionIDs) ? nil : open.union(call.sessionIDs)
    }

    /// The newest approval in the call's chat waiting on the user.
    private func hermesCallApprovalMessage(_ call: HermesCallOpening) -> ChatMessage? {
        guard let ids = hermesCallOpenChatIDs(call) else { return nil }
        return messages.last { message in
            guard let approval = message.approval, approval.status == .pending || approval.status == .error else { return false }
            return ids.contains(approval.sessionId)
        }
    }

    /// The question in the call's chat the call is about. A question names
    /// no session: the open chat's are all its own. With more than one
    /// waiting, only the one Hermes' reason quotes.
    private func hermesCallQuestionMessage(_ call: HermesCallOpening) -> ChatMessage? {
        guard hermesCallOpenChatIDs(call) != nil else { return nil }
        let waiting = messages.filter { message in
            guard let clarify = message.clarify, !clarify.isExpired else { return false }
            return clarify.questions.contains { $0.status == .pending || $0.status == .error }
        }
        guard waiting.count > 1 else { return waiting.first }
        guard let reason = call.reason else { return nil }
        return waiting.last { message in
            message.clarify?.questions.contains { question in
                // The reason is the question, or "2 questions, first: …",
                // cleaned and clipped as a reason is.
                guard let quoted = HermesCallRequest.cleanedReason(question.question) else { return false }
                return reason.contains(String(quoted.prefix(40)))
            } ?? false
        }
    }

    /// The live call Hermes made about an approval answers it with the
    /// user's spoken decision: `once` or `deny`.
    func answerHermesCallApproval(choice: String) async -> VoiceCallDecisionOutcome {
        guard let call = liveHermesCall, call.kind == .approval, choice == "once" || choice == "deny" else { return .nothingPending }
        guard let message = hermesCallApprovalMessage(call) else { return .nothingPending }
        let requestID = message.approval?.requestId
        await respondToApproval(messageId: message.id, choice: choice)
        // The chat may have reloaded meanwhile: the same approval, by its
        // request id. Gone from it, nothing waits any more.
        let after = messages.first { $0.id == message.id }
            ?? requestID.flatMap { id in messages.first { $0.approval?.requestId == id } }
        guard let approval = after?.approval else { return .nothingPending }
        switch approval.status {
        case .approved: return .approved
        case .rejected: return .denied
        case .expired: return .expired
        default: return .failed
        }
    }

    /// The live call Hermes made about a question gives it the user's
    /// answer.
    func answerHermesCallQuestion(_ answer: String) async -> VoiceCallDecisionOutcome {
        guard let call = liveHermesCall, call.kind == .question else { return .nothingPending }
        guard let message = hermesCallQuestionMessage(call), let clarify = message.clarify,
              let question = clarify.questions.first(where: { $0.status == .pending || $0.status == .error }) else { return .nothingPending }
        // The first question still open, as the card would answer it.
        await respondToClarify(requestId: clarify.requestId, questionId: clarify.questions.count == 1 ? nil : question.id, answer: answer)
        // The chat may have reloaded meanwhile: the same question, by its
        // request id. Gone from it, nothing waits any more.
        let reloaded = messages.first { $0.id == message.id } ?? messages.first { $0.clarify?.requestId == clarify.requestId }
        guard let after = reloaded?.clarify else { return .nothingPending }
        switch after.questions.first(where: { $0.id == question.id })?.status {
        case .answered?: return .answered
        case .expired?: return .expired
        default: return after.isExpired ? .expired : .failed
        }
    }

    // MARK: Native calls (#449 step 2)

    /// A call from Hermes rings or runs in CallKit: transport recovery runs
    /// with the phone locked until it's over.
    func setNativeHermesCallActive(_ active: Bool) {
        guard isNativeHermesCallActive != active else { return }
        isNativeHermesCallActive = active
        if active { recoverTransportForCarPlayIfNeeded(immediately: true) }
    }

    /// The user hung up the CallKit call: the voice conversation it opened
    /// ends as its End button would.
    func endVoiceForNativeCall() {
        if isLiveVoiceCallActive || minimisedLiveVoice != nil {
            endLiveVoiceCall()
        } else if showVoiceSheet || voiceConversationController.hasLiveVoiceSession {
            closeVoiceConversation()
        }
    }

    /// The CallKit call's mute button.
    func setVoiceMutedForNativeCall(_ muted: Bool) {
        if isGeminiLiveActive {
            geminiLiveController.setMicrophoneMuted(muted)
        } else if isGPTLiveActive {
            gptLiveController.setMicrophoneMuted(muted)
        } else if isGrokLiveActive {
            grokLiveController.setMicrophoneMuted(muted)
        } else if voiceConversationController.hasLiveVoiceSession {
            if muted {
                voiceConversationController.pauseMicrophone()
            } else {
                Task { await voiceConversationController.resumeMicrophone() }
            }
        }
    }
}
