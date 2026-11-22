import Foundation

/// A live call keeps its dashboard (no-switch stage 2, calls and voice). A
/// combined dashboard switched away from stays connected in its own runtime
/// (`runtime(for:)`), so a live call on the phone (Gemini, Qwen, GPT-Live,
/// Grok, Local Live) goes on through it while another dashboard shows: its
/// requests, its host routes, its settings and its jobs' ledger are that
/// runtime's, never the screen's. Classic voice (a call from Hermes answered
/// in it too), CarPlay and the Watch still end with the switch, which asks
/// first, as they do for a profile switch.
extension AppState {
    /// The dashboard voice runs on: the live call's own while one is up, or
    /// while a call that ended off it hands its jobs back, else the
    /// dashboard on screen.
    var voiceCallDashboardID: UUID? {
        if isLiveCallUp, let liveCallDashboardID { return liveCallDashboardID }
        if callProfileHandingBack != nil, let callDashboardHandingBack { return callDashboardHandingBack }
        return activeDashboardID
    }

    /// The call's dashboard when it isn't the one on screen: its requests go
    /// through that dashboard's runtime. Nil while they're the same, or
    /// with no live call.
    var callDashboardOffScreen: UUID? {
        guard let id = voiceCallDashboardID, id != activeDashboardID else { return nil }
        return id
    }

    /// The runtime a call off its dashboard goes on through; nil once that
    /// dashboard's connection has gone (its requests then fail as a dropped
    /// connection's do), or with the call on screen.
    var callRuntimeOffScreen: DashboardRuntime? {
        callDashboardOffScreen.flatMap { runtime(for: $0) }
    }

    /// The bridge the call's host routes go through: its own dashboard's.
    /// The screen's while the call is on it, or with no call.
    var callBridge: DashboardTicketBridge? {
        callDashboardOffScreen == nil ? dashboardTicketBridge : callRuntimeOffScreen?.dashboardTicketBridge
    }

    /// The call's dashboard's connection, as `callBridge`.
    var callConnection: HermesConnection? {
        callDashboardOffScreen == nil ? connection : callRuntimeOffScreen?.connection
    }

    /// Whether the call's dashboard is connected, as `callBridge`.
    var callIsConnected: Bool {
        callDashboardOffScreen == nil ? isConnected : callRuntimeOffScreen?.client?.isConnected == true
    }

    /// The client of a call off its dashboard: that dashboard's runtime's,
    /// with no wait for the screen's connection (it isn't the call's).
    /// Throws as a dropped connection does once that connection has gone.
    func clientOfCallOffScreen() throws -> HermesClient? {
        guard callDashboardOffScreen != nil else { return nil }
        guard let client = callRuntimeOffScreen?.client, client.isConnected else { throw HermesError.notConnected }
        return client
    }

    /// Runs `body` with AppState's forwarders reading the call's own
    /// dashboard's runtime (its connection, its plugin report), or as it is
    /// with the call on screen. A call off its dashboard whose connection
    /// has dropped (before a quiet sign-in keeps it again) reads an empty
    /// runtime: no connection and no plugin report, never the screen's.
    /// Synchronous, as `act(onRuntime:)`.
    func onCallRuntime<T>(_ body: () throws -> T) rethrows -> T {
        guard callDashboardOffScreen != nil else { return try body() }
        return try act(onRuntime: callRuntimeOffScreen ?? DashboardRuntime(), body)
    }

    /// A profile's voice settings as the call reads them: kept per host,
    /// so a call off its dashboard reads its own host's (by its address,
    /// connected or not), not the screen's.
    func loadCallVoicePreferences(profile: String) -> VoiceProfilePreferences {
        guard let id = callDashboardOffScreen else { return loadVoiceProfilePreferences(profile: profile) }
        let gateway = callRuntimeOffScreen?.connection?.baseUrl
            ?? savedDashboardRegistry.dashboard(with: id)?.normalizedURL
        return loadVoiceProfilePreferences(profile: profile, gateway: gateway)
    }

    /// Whether a switch to dashboard `target` leaves the running call going:
    /// a live call on the phone that would go on across a profile switch
    /// (shown or minimised, one Hermes placed once its voice has opened),
    /// with its dashboard and the target in the combined group, so its
    /// runtime stays connected while the target shows (or is the target,
    /// switched back to). Every other call ends with the switch: Classic
    /// voice, CarPlay, the Watch, a call from Hermes still ringing or
    /// opening its voice, and any call across a dashboard outside the group.
    func callSurvivesDashboardSwitch(to target: UUID?) -> Bool {
        guard liveCallGoesOnWithoutTheScreen,
              let callDashboard = liveCallDashboardID, let target,
              isInCombinedGroup(callDashboard), isInCombinedGroup(target),
              // Its address edited since: its connection is to the old one,
              // and the switch lets it go.
              savedDashboardRegistry.dashboard(with: callDashboard)?.pendingURL == nil
        else { return false }
        // Back to its own dashboard: the call goes on there whether its
        // kept socket is open or dropped meanwhile (the switch signs in
        // again, and its requests wait for it as on any reconnect).
        if target == callDashboard { return true }
        // Away from it, its connection must stay to carry it.
        return runtime(for: callDashboard)?.client?.isConnected == true
    }

    /// A live call on the phone that needs no particular screen: shown or
    /// minimised, one Hermes placed once its voice has opened. Classic
    /// voice, CarPlay, the Watch and a ringing call from Hermes don't.
    var liveCallGoesOnWithoutTheScreen: Bool {
        guard isLiveCallUp, let liveCallProfile, !liveCallProfile.isEmpty,
              !showVoiceSheet, !voiceConversationController.hasLiveVoiceSession,
              !isCarPlayVoiceSurfaceActive, !isWatchVoiceCallActive,
              pendingHermesCall == nil, hermesCallOpenTask == nil
        else { return false }
        return true
    }

    /// A call runs that a switch to dashboard `target` would end.
    func isCallEndingDashboardSwitch(to target: UUID?) -> Bool {
        isVoiceCallInProgress && !callSurvivesDashboardSwitch(to: target)
    }

    /// Whether this dashboard's connection holds the running call, so it's
    /// kept through what would let a kept connection go on its own (the
    /// background grace, the cap): the audio keeps Conduit running.
    func liveCallHolds(dashboard id: UUID) -> Bool {
        isLiveCallUp && liveCallDashboardID == id && id != activeDashboardID
    }

    /// The call's dashboard was let go (signed out, removed, left the
    /// group): nothing carries the call any more, so it ends and hands its
    /// jobs back, as a dashboard switch outside the group ends it.
    func endLiveCallLosingItsDashboard(_ id: UUID) {
        guard liveCallHolds(dashboard: id) else { return }
        // Each stop's hang-up hands the call's jobs back (callEndedOffItsProfile).
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
    }

    /// What the minimised call's bar and its sheet's header name while
    /// another dashboard shows: the call's profile and its dashboard's name.
    var callDashboardSubject: String? {
        guard let id = callDashboardOffScreen else { return nil }
        // The name the call's dashboard gives its profile, in
        // profileDisplayName's order but from that dashboard's own store:
        // its main profile's name, a device name until its gateway keeps
        // bot looks (no bot titles stored), a bot's title, Hermes' own name,
        // else the profile's.
        var key = voiceCallProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMain = key.isEmpty || key.lowercased() == "default"
        let mainName = profileAppearanceStore.loadDefaultName(dashboardID: id)
        let titles = profileAppearanceStore.loadBotTitles(dashboardID: id)
        let profile: String
        if isMain, mainName != ProfileAppearanceStore.defaultName {
            profile = mainName
        } else {
            if isMain { key = "default" }
            let deviceName = isMain || !titles.isEmpty ? nil
                : profileAppearanceStore.loadDeviceNames(dashboardID: id)[key]
            profile = deviceName ?? titles[key]
                ?? profileAppearanceStore.loadHermesNames(dashboardID: id)[key]
                ?? (isMain ? mainName : String(key.prefix(1)).uppercased() + String(key.dropFirst()))
        }
        let name = savedDashboardRegistry.dashboard(with: id)?.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return [profile, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
