//
//  AppState+WakePhrase.swift
//  Conduit
//
//  Foreground wake phrase (#174). A detected phrase only enqueues a
//  PendingVoiceIntent for its profile; openVoiceConversation then picks the
//  profile's voice engine (Gemini Live, Qwen Live, GPT Live, Grok Live,
//  Local Live or classic) exactly as it does for Siri.
//

import AVFAudio
import Combine
import Foundation

extension AppState {
    /// The dashboard key wake phrases are stored under.
    var wakeGatewayID: String? { activeDashboardID?.uuidString }

    /// Bindings that can fire right now: on the current dashboard, for a
    /// profile that still exists, with a usable phrase.
    var activeWakeBindings: [WakePhraseBinding] {
        guard let gatewayID = wakeGatewayID else { return [] }
        let known = Set(profiles)
        return wakeConfiguration.enabledBindings().filter {
            $0.key.gatewayID == gatewayID
                && known.contains($0.key.profileID)
                && WakePhraseMatcher.isUsable($0.phrase)
        }
    }

    /// Every phrase wake listens for, in the listener's order, with
    /// `profile`'s replaced by `phrases`: Settings checks the language cap
    /// against what the listener will get, other profiles' phrases included.
    func wakeListenedPhrases(replacing phrases: [String], forProfile profile: String) -> [String] {
        guard let gatewayID = wakeGatewayID else { return phrases.filter(WakePhraseMatcher.isUsable) }
        let key = WakeProfileKey(gatewayID: gatewayID, profileID: profile)
        let edited = phrases.filter(WakePhraseMatcher.isUsable).map {
            WakePhraseBinding(key: key, phrase: $0, startsFreshConversation: false)
        }
        return (activeWakeBindings.filter { $0.key != key } + edited)
            .sorted { $0.id < $1.id }
            .map(\.phrase)
    }

    var wakeLifecycleSnapshot: WakeLifecycleSnapshot {
        WakeLifecycleSnapshot(
            isForegroundActive: isSceneActive,
            isAuthenticated: connection != nil,
            isGatewayConnected: isConnected && !isProfileSwitching,
            microphonePermitted: AppleSpeechWakeWordService.isSpeechAuthorized
                && AppleSpeechWakeWordService.isMicrophoneAuthorized,
            isVoiceIdle: isVoiceIdleForWake,
            hasWakePhrases: !activeWakeBindings.isEmpty,
            isRouteSuitable: isWakeRouteAllowed,
            otherAudioAllowsListening: isWakeOtherAudioAllowed
        )
    }

    /// CarPlay allows listening only while the user keeps wake on there.
    private var isWakeRouteAllowed: Bool {
        !isWakeRouteCarPlay || wakeConfiguration.listensOnCarPlay
    }

    /// Another app's music or podcast pauses wake unless the user keeps it
    /// listening over other audio.
    private var isWakeOtherAudioAllowed: Bool {
        wakeConfiguration.listensOverOtherAudio || !isWakeOtherAudioPlaying
    }

    private var isVoiceIdleForWake: Bool {
        !showVoiceSheet
            && !showQwenLiveSheet && !showGeminiLiveSheet
            && !showGPTLiveSheet
            && !showGrokLiveSheet
            && !showLocalLiveSheet
            && minimisedLiveVoice == nil
            && !isCarPlayVoiceSurfaceActive
            && !voiceConversationController.hasLiveVoiceSession
            && voiceLaunchesInFlight == 0
            && !PendingVoiceIntentStore.shared.hasPendingIntent
            && !VoiceAudioSessionCoordinator.shared.hasOwnersOtherThanWakeListening
    }

    /// Starts following app state. Called once by the primary window.
    func startWakeListeningLifecycle() {
        guard wakeObservations.isEmpty else { return }
        wakeWordService.onDetection = { [weak self] binding in
            self?.handleWakeDetection(binding)
        }
        wakeWordService.onFailure = { [weak self] message in
            guard let self else { return }
            self.wakeListeningFailure = message
            // The listener stopped on its own; the snapshot did not change,
            // so retry once after a pause instead of waiting for one.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.lastAppliedWakeSnapshot = nil
                self.scheduleWakeRefresh()
            }
        }
        VoiceAudioSessionCoordinator.shared.onOwnersChanged = { [weak self] in
            self?.scheduleWakeRefresh()
        }
        VoiceAudioSessionCoordinator.shared.onWakeListenerMustYield = { [weak self] in
            self?.yieldWakeListening()
        }
        isWakeRouteCarPlay = WakeRoutePolicy.currentRouteIsCarPlay()
        wakeObservations = [
            objectWillChange.sink { [weak self] _ in self?.scheduleWakeRefresh() },
            PendingVoiceIntentStore.shared.objectWillChange.sink { [weak self] _ in self?.scheduleWakeRefresh() },
            voiceConversationController.objectWillChange.sink { [weak self] _ in self?.scheduleWakeRefresh() },
            // Connecting or leaving CarPlay changes whether wake may listen.
            NotificationCenter.default.publisher(
                for: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance()
            )
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isWakeRouteCarPlay = WakeRoutePolicy.currentRouteIsCarPlay()
                    self.scheduleWakeRefresh()
                }
            },
            // Another app's music or podcast starting or stopping. Delivered
            // only while wake holds an active session, so it stops wake at
            // once; the monitor notices when that audio ends.
            NotificationCenter.default.publisher(
                for: AVAudioSession.silenceSecondaryAudioHintNotification,
                object: AVAudioSession.sharedInstance()
            )
            .sink { [weak self] notification in
                let rawType = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
                let began = rawType.flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init(rawValue:)) == .begin
                Task { @MainActor [weak self] in
                    guard let self, !self.wakeConfiguration.listensOverOtherAudio else { return }
                    self.noteWakeOtherAudio(playing: began || self.wakeOtherAudioProbe())
                }
            }
        ]
        scheduleWakeRefresh()
    }

    /// Coalesces a burst of state changes into one lifecycle update on the
    /// next main-actor turn, after the published values have settled.
    func scheduleWakeRefresh() {
        guard !wakeObservations.isEmpty, !isWakeRefreshScheduled else { return }
        isWakeRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isWakeRefreshScheduled = false
            self.refreshWakeListening()
        }
    }

    func refreshWakeListening() {
        var snapshot = wakeLifecycleSnapshot
        // Route changes while suspended are never delivered, and other apps'
        // audio is only polled, so confirm both right before arming (rare:
        // only when wake would start). Arming under a playing podcast would
        // move it onto a record route for a moment.
        if snapshot.canArm, !wakeWordService.isArmed, snapshot != lastAppliedWakeSnapshot {
            isWakeRouteCarPlay = WakeRoutePolicy.currentRouteIsCarPlay()
            snapshot.isRouteSuitable = isWakeRouteAllowed
            if !wakeConfiguration.listensOverOtherAudio {
                isWakeOtherAudioPlaying = wakeOtherAudioProbe()
                snapshot.otherAudioAllowsListening = isWakeOtherAudioAllowed
            }
        }
        updateWakeOtherAudioMonitor(for: snapshot)
        if snapshot.canArm { wakeWordService.bindings = activeWakeBindings }
        // Only act on a change: a failed arm is not retried on every
        // unrelated publish, only once something relevant moves.
        guard snapshot != lastAppliedWakeSnapshot else { return }
        lastAppliedWakeSnapshot = snapshot
        wakeLifecycle.update(for: snapshot)
        let failure = snapshot.canArm ? wakeLifecycle.lastFailureReason : nil
        if wakeListeningFailure != failure { wakeListeningFailure = failure }
        if isWakePausedForOtherAudio != snapshot.isPausedForOtherAudio {
            isWakePausedForOtherAudio = snapshot.isPausedForOtherAudio
        }
    }

    /// Polls other apps' audio while wake is armed (to step aside when a
    /// podcast starts) or only waiting for that audio to stop (to listen
    /// again). Off whenever wake could not listen anyway, and when the user
    /// keeps it listening over other audio.
    func updateWakeOtherAudioMonitor(for snapshot: WakeLifecycleSnapshot) {
        guard snapshot.canArmIgnoringOtherAudio, !wakeConfiguration.listensOverOtherAudio else {
            stopWakeOtherAudioMonitor()
            return
        }
        guard wakeOtherAudioMonitor == nil else { return }
        wakeOtherAudioMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollWakeOtherAudio() else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopWakeOtherAudioMonitor() {
        wakeOtherAudioMonitor?.cancel()
        wakeOtherAudioMonitor = nil
    }

    /// One poll: records whether other audio plays and returns the delay
    /// before the next one.
    private func pollWakeOtherAudio() -> Duration {
        noteWakeOtherAudio(playing: wakeOtherAudioProbe())
        return wakeOtherAudioPollInterval
    }

    func noteWakeOtherAudio(playing: Bool) {
        guard isWakeOtherAudioPlaying != playing else { return }
        isWakeOtherAudioPlaying = playing
        scheduleWakeRefresh()
    }

    /// Synchronous: the microphone must stop before the app leaves the
    /// foreground, not on a later turn.
    func disarmWakeListeningForBackground() {
        guard !wakeObservations.isEmpty else { return }
        wakeLifecycle.disarmImmediately()
        stopWakeOtherAudioMonitor()
        lastAppliedWakeSnapshot = nil
        // Re-read on the next foreground: CarPlay may connect meanwhile, and
        // another app may start or stop playing.
        isWakeRouteCarPlay = false
        isWakeOtherAudioPlaying = false
        if isWakePausedForOtherAudio { isWakePausedForOtherAudio = false }
    }

    /// Another audio owner is taking the session now: stop listening before
    /// its microphone starts. The refresh after it lets go arms wake again.
    private func yieldWakeListening() {
        wakeLifecycle.disarmImmediately()
        lastAppliedWakeSnapshot = nil
    }

    private func handleWakeDetection(_ binding: WakePhraseBinding) {
        lastAppliedWakeSnapshot = nil
        Haptics.medium()
        PendingVoiceIntentStore.shared.enqueue(PendingVoiceLaunchPolicy.makeWakePhrasePendingIntent(
            profile: binding.key.profileID,
            startsFreshConversation: binding.startsFreshConversation
        ))
    }

    // MARK: - Settings

    func wakePreferences(forProfile profile: String) -> WakeProfilePreferences {
        guard let gatewayID = wakeGatewayID else { return WakeProfilePreferences() }
        return wakeConfiguration.preferences(for: WakeProfileKey(gatewayID: gatewayID, profileID: profile))
    }

    func setWakePreferences(_ preferences: WakeProfilePreferences, forProfile profile: String) {
        guard let gatewayID = wakeGatewayID else { return }
        let key = WakeProfileKey(gatewayID: gatewayID, profileID: profile)
        if preferences.enabledPhrases.isEmpty {
            wakeConfiguration.removePreferences(for: key)
        } else {
            wakeConfiguration.save(preferences, for: key)
        }
        wakeListeningFailure = nil
        wakeSettingsRevision &+= 1
    }

    var wakeListensOnCarPlay: Bool { wakeConfiguration.listensOnCarPlay }

    func setWakeListensOnCarPlay(_ enabled: Bool) {
        wakeConfiguration.listensOnCarPlay = enabled
        // Judge the change against the live route, not a cache that may
        // have missed a route change.
        isWakeRouteCarPlay = WakeRoutePolicy.currentRouteIsCarPlay()
        wakeListeningFailure = nil
        wakeSettingsRevision &+= 1
    }

    var wakeListensOverOtherAudio: Bool { wakeConfiguration.listensOverOtherAudio }

    func setWakeListensOverOtherAudio(_ enabled: Bool) {
        wakeConfiguration.listensOverOtherAudio = enabled
        // The monitor stops while the setting is on, so judge turning it off
        // against what plays now, not a stale cache.
        if !enabled { isWakeOtherAudioPlaying = wakeOtherAudioProbe() }
        wakeListeningFailure = nil
        wakeSettingsRevision &+= 1
    }

    /// The phrase offered when wake listening is first turned on.
    func suggestedWakePhrase(forProfile profile: String) -> String {
        AppLocalization.string("Hey \(profileDisplayName(profile))", table: .voice)
    }
}

extension AppState {
    // MARK: - Wake phrase (#174)

    func setCarPlayVoiceSurfaceActive(_ active: Bool) {
        isCarPlayVoiceSurfaceActive = active
        if active { noteVoiceCallStartedForLocation() }
        // CarPlay feeds BOTH gates (`hasActiveVoiceSurface` and
        // `hasForegroundApplicationSurface`), so this publishes both rather
        // than only the app-foreground one: the adjacent
        // `handleCarPlayVoiceSurfaceActivated/Removed` handlers then re-state
        // the same capture value as they own the suspension side-effect, and
        // no reader can observe a CarPlay edge half-applied.
        publishVoiceRuntimeGates()
    }

    /// Whether at least one legitimate Voice presentation surface is
    /// actually presenting Voice: the phone scene counts only while the
    /// Voice sheet is up (a foreground phone with the sheet closed presents
    /// nothing), while a connected CarPlay surface presents Voice by
    /// itself. This — not the raw phone scene phase — is the Voice runtime's
    /// foreground gate: live Voice audio is allowed exactly while this is
    /// true. It deliberately does NOT fake phone `.active`:
    /// transport/chat reconciliation continues to read `isSceneActive` for
    /// phone-specific behavior.
    var hasActiveVoiceSurface: Bool {
        (isSceneActive && showVoiceSheet) || isCarPlayVoiceSurfaceActive || isLockedVoiceSurfaceActive
            || isNativeCallVoiceSurfaceActive
    }

    /// A call from Hermes the user answered in CallKit presents the classic
    /// Voice it opened, with the phone locked or Conduit in the background
    /// (#558): answering was the user's go-ahead, and the CallKit screen
    /// keeps mute and hang-up in reach. Only while that Voice sheet is open;
    /// hanging up closes it.
    var isNativeCallVoiceSurfaceActive: Bool {
        isNativeHermesCallAnswered && showVoiceSheet
    }

    /// Off screen, nobody can tap Listen: the conversation keeps listening
    /// on its own while it is kept running locked or carried by a call.
    private var isBackgroundVoiceListeningSurfaceActive: Bool {
        !isSceneActive && (isLockedVoiceSurfaceActive || isNativeCallVoiceSurfaceActive)
    }

    /// "Keep listening when locked": an open classic Voice conversation that
    /// is already running keeps presenting with the phone locked or Conduit
    /// in the background, the way CarPlay keeps it live. A conversation that
    /// isn't running (never listened, settled idle, paused, failed, or
    /// already suspended) doesn't count: it suspends as usual instead.
    var isLockedVoiceSurfaceActive: Bool {
        keepVoiceListeningWhenLocked
            && showVoiceSheet
            && voiceConversationController.isConversationRunning
    }

    /// Whether the app itself has a foreground presentation surface: the
    /// phone scene is on screen, or CarPlay presents the shared conversation
    /// while the phone is locked.
    ///
    /// This is the `hasActiveVoiceSurface` meaning from before the CarPlay
    /// surface work, and it is deliberately kept separate: that property is
    /// now a *capture* gate (it also requires the phone Voice sheet), while
    /// permission alerts and the settings-launched provider tests only ever
    /// needed "the app is on screen". Voice settings is reachable only from
    /// the foreground and presents no Voice sheet, so reading the capture
    /// gate there refused legitimate actions.
    var hasForegroundApplicationSurface: Bool {
        isSceneActive || isCarPlayVoiceSurfaceActive || isLockedVoiceSurfaceActive
            || isNativeCallVoiceSurfaceActive
    }

    /// Publishes every Voice runtime gate from the current surface
    /// bookkeeping. Used at the lifecycle boundaries that can change both
    /// facts at once; a boundary that changes only one (the CarPlay surface
    /// edges) publishes by the same rule.
    ///
    /// INVARIANT for every other writer: the two gates must never be left
    /// inconsistent *across* an await. A writer either publishes both through
    /// here, or writes both facts explicitly in one synchronous run (the
    /// `.background` branch does), or writes only the capture gate because
    /// the same step tears the runtime down — `stop()` and
    /// `suspendRuntimeForLifecycle()` both bump `operationGeneration`, so
    /// in-flight work is fenced even while the app-foreground gate stays
    /// open.
    func publishVoiceRuntimeGates() {
        voiceConversationController.setForegroundActive(hasActiveVoiceSurface)
        voiceConversationController.setApplicationForegroundActive(hasForegroundApplicationSurface)
        voiceConversationController.setBackgroundListening(isBackgroundVoiceListeningSurfaceActive)
    }

    /// Re-asserts the Voice runtime gates from the current surface
    /// bookkeeping. Presenting the phone Voice sheet must call this BEFORE
    /// auto-listen: with CarPlay absent the capture gate is false while the
    /// sheet is closed (`hasActiveVoiceSurface` requires the sheet), and
    /// `startListening` is gated on it. Both gates are published: a Voice
    /// surface presenting at all also means the app is on screen, so this
    /// heals a stale app-foreground gate left by a scene-phase event that
    /// never fired (the phone may be locked throughout a CarPlay session).
    func reassertVoiceSurfaceGate() {
        publishVoiceRuntimeGates()
    }
}
