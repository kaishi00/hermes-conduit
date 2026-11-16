import Foundation

/// A live call keeps its profile (all-live stage 2, issue 2390). A switch
/// to another profile on the same dashboard keeps the open socket, and the
/// socket isn't tied to a profile, so a live call (Gemini, Qwen, GPT-Live,
/// Grok, Local Live) goes on through it: its jobs, its chat, its searches
/// and its host reads name the call's profile, never the one on screen.
/// So does a call from Hermes answered in a live mode. Classic voice (a
/// call from Hermes answered in it too), CarPlay and the Watch still end
/// with the switch, which asks first as before.
extension AppState {
    /// A live call's engine, sheet or minimised bar is up.
    var isLiveCallUp: Bool {
        isLiveVoiceCallActive || minimisedLiveVoice != nil
            || showQwenLiveSheet || showGeminiLiveSheet || showGPTLiveSheet || showGrokLiveSheet || showLocalLiveSheet
    }

    /// The profile voice runs on: the live call's own while one is up, or
    /// while a call that ended off its profile hands its jobs back, else
    /// the profile on screen.
    var voiceCallProfile: String {
        if isLiveCallUp, let liveCallProfile, !liveCallProfile.isEmpty { return liveCallProfile }
        if let callProfileHandingBack, !callProfileHandingBack.isEmpty { return callProfileHandingBack }
        return activeProfile
    }

    /// The call's style (tone, answer length, greeting): the call's own
    /// profile's, where Settings shows the profile on screen's.
    var liveCallStyle: LiveVoiceStyle {
        loadVoiceProfilePreferences(profile: voiceCallProfile).liveVoiceStyle
    }

    /// The call's profile's voice settings. A running call reads its own
    /// settings here (memory, persona, voice, look-ups, Local Live's agent
    /// mode), as its reconnects run setup again: the settings getters read
    /// the profile on screen, which Settings edits.
    var callVoicePreferences: VoiceProfilePreferences {
        loadVoiceProfilePreferences(profile: voiceCallProfile)
    }

    /// Local Live in agent mode on the call's profile (`isLocalLiveAgent`
    /// for the call, the same outside one).
    var callRunsLocalLiveAgent: Bool {
        callVoicePreferences.localLiveAgent
    }

    /// `voiceCallProfile` when it isn't the profile on screen: what a call's
    /// request that names no profile names, so it reaches the call's
    /// profile rather than the client's. Nil while they're the same.
    var callProfileOffScreen: String? {
        let profile = voiceCallProfile
        return Self.profilesMatch(profile, activeProfile) ? nil : profile
    }

    /// The profile a request about the call's chat names: a Bot Chat's bot,
    /// else the call's profile when it isn't the one on screen.
    func callThreadProfile(_ thread: VoiceThreadTarget) -> String? {
        thread.profile ?? callProfileOffScreen
    }

    /// A link to the call's chat, naming the call's profile while another
    /// one is on screen, so opening it switches back rather than looking
    /// for the chat on the profile shown.
    func callChatLink(_ link: ConduitAppLink) -> ConduitAppLink {
        guard case .session(let id, .none, let dashboard) = link, let profile = callProfileOffScreen else { return link }
        return .session(id: id, profile: profile, dashboard: dashboard)
    }

    /// What the minimised call's bar names after the mode: the call's chat,
    /// and the call's profile while another one is on screen.
    func liveCallBarSubject(thread: String?) -> String? {
        guard let profile = callProfileOffScreen else { return thread }
        let name = profileDisplayName(profile)
        return thread.map { "\(name) · \($0)" } ?? name
    }

    /// Whether a switch to another profile now leaves the running call
    /// going: a live call on the phone (shown or minimised), one Hermes
    /// placed included once its voice has opened, with the open socket
    /// kept for the switch. Every other call ends with the switch: Classic
    /// voice, CarPlay, the Watch, and a call from Hermes still ringing or
    /// opening its voice.
    var callSurvivesProfileSwitch: Bool {
        guard isLiveCallUp, let liveCallProfile, !liveCallProfile.isEmpty,
              !showVoiceSheet, !voiceConversationController.hasLiveVoiceSession,
              !isCarPlayVoiceSurfaceActive, !isWatchVoiceCallActive,
              pendingHermesCall == nil, hermesCallOpenTask == nil,
              let connection, socketToKeepForProfileSwitch(within: connection) != nil
        else { return false }
        return true
    }

    /// A call runs that a switch to another profile would end.
    var isCallEndingProfileSwitch: Bool {
        isVoiceCallInProgress && !callSurvivesProfileSwitch
    }

    /// A live call start for `profile` while a live call runs on another
    /// one: that call isn't the one asked for, and since it goes on across
    /// a profile switch the engine's own "already running" check would
    /// keep it. It ends first and hands its jobs back. A call on the
    /// profile asked for is kept, as before.
    func endLiveCallOnAnotherProfile(than profile: String) {
        guard isLiveCallUp, !Self.profilesMatch(voiceCallProfile, profile) else { return }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        handBackEndedCallJobsNow()
    }

    /// A client made for a reconnect while a live call is up (a failed
    /// switch drops the one that held them): the call's sessions name its
    /// profile on this one too.
    func keepCallSessionsOnTheirProfile(afterReconnect client: HermesClient) {
        guard isLiveCallUp || callProfileHandingBack != nil else { return }
        keepCallSessionsOnTheirProfile(voiceCallProfile, for: client)
    }

    /// The call's own sessions as a switch changes the profile on screen:
    /// the next client names the call's profile for each, so a turn, a
    /// cancel or a read about one still reaches it (and forgets them again
    /// when the switch goes back to the call's profile, its own).
    func keepCallSessionsOnTheirProfile(_ profile: String, for nextClient: HermesClient) {
        nextClient.noteSessionProfile(profile, for: callSessionIDsOnActiveProfile)
        // And a job's or a Bot Chat's own profile for theirs: the client
        // that held them forgot the ones naming its own profile.
        for named in voiceBackgroundJobSupervisor.sessionIDsNamingAProfile {
            nextClient.noteSessionProfile(named.profile, for: named.ids)
        }
        // Local Live's own chat in place of a deleted Bot Chat is its bot's.
        if let own = localLiveOwnChat, let ownProfile = own.profile {
            nextClient.noteSessionProfile(ownProfile, for: [own.runtimeSessionID, own.storedSessionID])
        }
    }

    /// The call's sessions that name no profile of their own (its jobs',
    /// its thread's and Local Live's own chat): the ones a switch names the
    /// call's profile for. Not "the profile on screen's": they are the
    /// call's profile's, wherever the screen is. `callSessionIDs` is all
    /// of them, a job's on a profile it named included.
    var callSessionIDsOnActiveProfile: [String?] {
        voiceBackgroundJobSupervisor.sessionIDsOnActiveProfile + localLiveOwnChatSessionIDs
    }

    /// Every session the live call uses, a job's on a profile it named
    /// included. A switch the call goes on across carries their requests
    /// in flight to the new client.
    var callSessionIDs: Set<String> {
        var ids = voiceBackgroundJobSupervisor.callSessionIDs
        if let own = localLiveOwnChat { ids += [own.runtimeSessionID, own.storedSessionID] }
        return Set(ids.compactMap { $0 })
    }

    /// A Local Live call's own chat (one it made with no chat attached).
    private var localLiveOwnChatSessionIDs: [String?] {
        guard let own = localLiveOwnChat, own.profile == nil else { return [] }
        return [own.runtimeSessionID, own.storedSessionID]
    }

    /// The call that kept its profile across a switch has ended: voice
    /// jobs go back to the profile on screen, as the switch would have
    /// done, once its ledger is saved under the call's.
    ///
    /// The hand-back waits for the hang-up's callback pass
    /// (`finishCallbacks`): it releases the watches the call told, holds
    /// the ones still to tell, and the reset would cancel it. Its ledger
    /// isn't saved meanwhile, as the restored key is still the call's.
    func callEndedOffItsProfile() {
        guard !isLiveCallUp, let ended = liveCallProfile else { return }
        liveCallProfile = nil
        guard !Self.profilesMatch(ended, activeProfile) else { return }
        // Until the hand-back the jobs, their ledger and their requests stay
        // the call's profile's.
        callProfileHandingBack = ended
        guard let hangUp = voiceBackgroundJobSupervisor.callbackSyncInFlight else {
            handBackCallJobs()
            return
        }
        callEndedOffProfileHandBack?.cancel()
        callEndedOffProfileHandBack = Task { @MainActor [weak self] in
            await hangUp.value
            guard !Task.isCancelled else { return }
            self?.handBackCallJobs()
        }
    }

    /// A voice start while a call's hand-back waits: it happens now, before
    /// the new voice touches the jobs. (A boundary's reset,
    /// `retireVoiceBackgroundJobs`, drops the wait itself.)
    func handBackEndedCallJobsNow() {
        guard callEndedOffProfileHandBack != nil || callProfileHandingBack != nil else { return }
        handBackCallJobs()
    }

    private func handBackCallJobs() {
        callEndedOffProfileHandBack?.cancel()
        callEndedOffProfileHandBack = nil
        // A hang-up's callback pass still on the wire: its ended jobs'
        // watches are settled on their own, as the reset cancels the pass.
        if let settles = voiceBackgroundJobSupervisor.detachEndedCallbackSettles(callProfile: callProfileHandingBack ?? voiceCallProfile) {
            let end = beginVoiceTranscriptBackgroundTask(named: "conduit.hermesCalls.handBack")
            Task {
                await settles.value
                end()
            }
        }
        // The hang-up's last changes (the thread let go, outcomes settled)
        // go into the call's ledger now: the save it scheduled would come
        // after the reset, under the profile on screen's key, and be refused.
        saveVoiceJobLedger(voiceBackgroundJobSupervisor.savedLedger())
        callProfileHandingBack = nil
        voiceJobLedgerRestoredKey = nil
        voiceBackgroundJobSupervisor.reset()
        scheduleVoiceJobLedgerRestore()
        voiceJobSessionListRefreshTask?.cancel()
        voiceJobSessionListRefreshTask = nil
    }
}
