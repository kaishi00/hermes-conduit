//
//  AppState+WakePhrase.swift
//  Conduit
//
//  Foreground wake phrase (#174). A detected phrase only enqueues a
//  PendingVoiceIntent for its profile; openVoiceConversation then picks the
//  profile's voice engine (Gemini Live, GPT Live, Grok Live or classic)
//  exactly as it does for Siri.
//

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

    var wakeLifecycleSnapshot: WakeLifecycleSnapshot {
        WakeLifecycleSnapshot(
            isForegroundActive: isSceneActive,
            isAuthenticated: connection != nil,
            isGatewayConnected: isConnected && !isProfileSwitching,
            microphonePermitted: AppleSpeechWakeWordService.isSpeechAuthorized
                && AppleSpeechWakeWordService.isMicrophoneAuthorized,
            isVoiceIdle: isVoiceIdleForWake,
            hasWakePhrases: !activeWakeBindings.isEmpty
        )
    }

    private var isVoiceIdleForWake: Bool {
        !showVoiceSheet
            && !showGeminiLiveSheet
            && !showGPTLiveSheet
            && !showGrokLiveSheet
            && !isCarPlayVoiceSurfaceActive
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
            self?.wakeListeningFailure = message
        }
        VoiceAudioSessionCoordinator.shared.onOwnersChanged = { [weak self] in
            self?.scheduleWakeRefresh()
        }
        wakeObservations = [
            objectWillChange.sink { [weak self] _ in self?.scheduleWakeRefresh() },
            PendingVoiceIntentStore.shared.objectWillChange.sink { [weak self] _ in self?.scheduleWakeRefresh() }
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
        let snapshot = wakeLifecycleSnapshot
        if snapshot.canArm { wakeWordService.bindings = activeWakeBindings }
        // Only act on a change: a failed arm is not retried on every
        // unrelated publish, only once something relevant moves.
        guard snapshot != lastAppliedWakeSnapshot else { return }
        lastAppliedWakeSnapshot = snapshot
        wakeLifecycle.update(for: snapshot)
        if snapshot.canArm {
            let failure = wakeLifecycle.lastFailureReason
            if wakeListeningFailure != failure { wakeListeningFailure = failure }
        }
    }

    /// Synchronous: the microphone must stop before the app leaves the
    /// foreground, not on a later turn.
    func disarmWakeListeningForBackground() {
        guard !wakeObservations.isEmpty else { return }
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

    /// The phrase offered when wake listening is first turned on.
    func suggestedWakePhrase(forProfile profile: String) -> String {
        AppLocalization.string("Hey \(profileDisplayName(profile))")
    }
}
