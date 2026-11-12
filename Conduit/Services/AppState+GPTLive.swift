//
//  AppState+GPTLive.swift
//  Conduit
//
//  GPT-Live: its settings and billing, its briefing, and opening and
//  closing a call, CarPlay included. Moved out of AppState.swift (issue
//  828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - GPT-Live

    func setGPTLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.gptLiveEnabled != enabled || (enabled && (preferences.qwenLiveEnabled || preferences.geminiLiveEnabled || preferences.grokLiveEnabled || preferences.localLiveEnabled)) else { return }
        objectWillChange.send()
        preferences.gptLiveEnabled = enabled
        // One live voice engine per profile: turning GPT-Live on turns the others off.
        if enabled {
            preferences.qwenLiveEnabled = false
            preferences.geminiLiveEnabled = false
            preferences.grokLiveEnabled = false
            preferences.localLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            closeClassicConversationForLiveMode()
            closeQwenLiveConversation()
            closeGeminiLiveConversation()
            closeGrokLiveConversation()
            closeLocalLiveConversation()
        } else {
            closeGPTLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// The voice GPT-Live speaks with on this profile; nil is the host's
    /// configured voice.
    var gptLiveVoice: String? {
        loadVoiceProfilePreferences(profile: activeProfile).gptLiveVoice
    }

    /// Applies from the next GPT-Live conversation.
    func setGPTLiveVoice(_ voice: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored = voice.flatMap { $0.isEmpty ? nil : $0 }
        guard preferences.gptLiveVoice != stored else { return }
        objectWillChange.send()
        preferences.gptLiveVoice = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    // MARK: GPT-Live billing (#559)

    /// Who pays for this profile's GPT-Live calls, as chosen in Settings.
    var gptLiveBilling: GPTLiveBilling {
        loadVoiceProfilePreferences(profile: activeProfile).resolvedGPTLiveBilling
    }

    /// Applies from the next GPT-Live conversation. Settings only calls it
    /// with `.api` after the user confirmed per-minute billing.
    func setGPTLiveBilling(_ billing: GPTLiveBilling) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: GPTLiveBilling? = billing == .subscription ? nil : billing
        guard preferences.gptLiveBilling != stored else { return }
        objectWillChange.send()
        preferences.gptLiveBilling = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The path the next GPT-Live call asks the host for. A call Hermes
    /// placed stays on the subscription unless the user allowed API-key
    /// calls for those too: nobody is billed for a call they didn't start
    /// without having said so.
    var gptLiveCallBilling: GPTLiveBilling {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.resolvedGPTLiveBilling == .api else { return .subscription }
        let hermesPlacedCall = liveHermesCall != nil || pendingHermesCall != nil
        if hermesPlacedCall, preferences.gptLiveAPIHermesCalls != true { return .subscription }
        return .api
    }

    /// The voice for the next call, from the list of the path it's billed on.
    var gptLiveCallVoice: String? {
        gptLiveCallBilling == .api ? gptLiveAPIVoice : gptLiveVoice
    }

    var gptLiveAPIVoice: String? {
        loadVoiceProfilePreferences(profile: activeProfile).gptLiveAPIVoice
    }

    func setGPTLiveAPIVoice(_ voice: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored = voice.flatMap { $0.isEmpty ? nil : $0 }
        guard preferences.gptLiveAPIVoice != stored else { return }
        objectWillChange.send()
        preferences.gptLiveAPIVoice = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    var gptLiveAPIHermesCalls: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).gptLiveAPIHermesCalls ?? false
    }

    func setGPTLiveAPIHermesCalls(_ allowed: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = allowed ? true : nil
        guard preferences.gptLiveAPIHermesCalls != stored else { return }
        objectWillChange.send()
        preferences.gptLiveAPIHermesCalls = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Minutes an API-key call may run; 0 is no limit.
    var gptLiveAPIMaxMinutes: Int {
        GPTLiveAPICallLimit.minutes(loadVoiceProfilePreferences(profile: activeProfile).gptLiveAPIMaxMinutes)
    }

    func setGPTLiveAPIMaxMinutes(_ minutes: Int) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Int? = minutes == GPTLiveAPICallLimit.defaultMinutes ? nil : max(0, minutes)
        guard preferences.gptLiveAPIMaxMinutes != stored else { return }
        objectWillChange.send()
        preferences.gptLiveAPIMaxMinutes = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether GPT-Live gets the Hermes host's memory on this profile. Off
    /// until the user turns it on: it sends that memory to OpenAI.
    var gptLiveMemoryEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).gptLiveMemory ?? false
    }

    /// Applies from the next GPT-Live conversation.
    func setGPTLiveMemoryEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.gptLiveMemory != stored else { return }
        objectWillChange.send()
        preferences.gptLiveMemory = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether GPT-Live speaks as the profile's SOUL.md persona. Off until
    /// the user turns it on: it sends SOUL.md to OpenAI.
    var gptLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).gptLivePersonality ?? false
    }

    /// Applies from the next GPT-Live conversation.
    func setGPTLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.gptLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.gptLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The host text the live modes hold between a call's start and close,
    /// by field.
    var liveVoiceHostContextForTesting: [String] {
        [
            geminiLiveMemoryContext != nil ? "geminiMemory" : nil,
            geminiLivePersonality != nil ? "geminiPersona" : nil,
            gptLiveMemoryContext != nil ? "gptMemory" : nil,
            gptLivePersonality != nil ? "gptPersona" : nil,
            grokLiveMemoryContext != nil ? "grokMemory" : nil,
            grokLivePersonality != nil ? "grokPersona" : nil,
            localLivePersonality != nil ? "localPersona" : nil,
        ].compactMap { $0 }
    }

    /// Fills every live mode's host text, as a call's start would.
    func installLiveVoiceHostContextForTesting() {
        let memory = GeminiLiveMemoryContext(text: "memory", canRecall: false)
        geminiLiveMemoryContext = memory
        geminiLivePersonality = "persona"
        gptLiveMemoryContext = memory
        gptLivePersonality = "persona"
        grokLiveMemoryContext = memory
        grokLivePersonality = "persona"
    }

    /// Local Live's SOUL.md, as an agent-mode call's start would read it.
    func installLocalLivePersonaForTesting(_ persona: String = "persona") {
        localLivePersonality = persona
    }

    /// GPT-Live's host routes for `profile` (see makeLiveTokenClient).
    func makeGPTLiveClient(profile: @escaping @MainActor () -> String) -> GPTLiveClient {
        GPTLiveClient(profile: profile, billing: { [weak self] in
            // Never the API key without an AppState to say the user chose it.
            self?.gptLiveCallBilling ?? .subscription
        }, request: { [weak self] path, method, body, timeout in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        })
    }

    /// Whether a GPT-Live conversation is running, without creating one.
    var isGPTLiveActive: Bool {
        gptLiveControllerCreated && gptLiveController.isActive
    }

    /// The phone's GPT-Live briefing: Conduit's rules, persona and memory,
    /// then this call's own blocks. One builder for the session request and
    /// the context a host that doesn't take briefings gets, so both fit the
    /// plugin's size limit the same way.
    func gptLiveBriefing() -> String {
        GPTLiveConversationController.briefing(
            memory: gptLiveMemoryContext,
            personality: gptLivePersonality,
            answerLength: liveVoiceStyle.answerLength,
            followedBy: (liveVoiceResumeContext?.summaryInstructionBlock ?? "")
                + liveHermesCallInstructions(delegation: true)
                + liveVoiceThreadInstructions(delegation: true) + phoneVoiceSettingHint(for: .gptLive)
                + hermesCallsInstructions(delegation: true)
                + VoiceHostTool.gptLiveRules(voiceBackgroundJobSupervisor.hostTools)
                + GPTLiveConversationController.jobApprovalRule
                + (gptLiveWebLookUps ? GPTLiveConversationController.webLookUpRule : "")
                + LiveVoiceStyle.askFirstInstructions(on: voiceBackgroundJobSupervisor.asksBeforeSending)
                + liveVoiceStyle.instructions
        )
    }

    /// Opens GPT-Live instead of the other voice modes, which (with Read
    /// Aloud) are closed first so they never share the audio session.
    @discardableResult
    func openGPTLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .gptLive { minimisedLiveVoice = nil }
        showGPTLiveSheet = true
        if !gptLiveController.isActive {
            gptLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            beginVoiceCallRecording(engine: .gptLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.gptLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.gptLive) else { return }
                await gptLiveController.start()
            }
        }
        return true
    }

    /// Starts GPT-Live for the CarPlay surface. CarPlay presents it, so no
    /// phone sheet opens; the other voice modes and read aloud stop first,
    /// as on the phone.
    func startGPTLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        guard !gptLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        beginVoiceCallRecording(engine: .gptLive)
        await gptLiveController.start()
    }

    /// CarPlay went away. A GPT-Live call only CarPlay was presenting ends;
    /// one the phone's sheet or minimised bar shows keeps going. A call that already failed
    /// drops its memory and persona too: nothing presents it, so nothing
    /// would close it.
    func releaseCarPlayGPTLive() {
        guard !(isSceneActive && (showGPTLiveSheet || minimisedLiveVoice == .gptLive)) else { return }
        if isGPTLiveActive {
            closeGPTLiveConversation()
        } else {
            // Its work lets go of the call too (#449).
            finishHermesCallbacks(engine: .gptLive)
            dropGPTLiveHostContext()
            if voiceCallRecorder?.engine == .gptLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .gptLive { minimisedLiveVoice = nil }
        }
    }

    func closeGPTLiveConversation() {
        callOffWaitingCall(.gptLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .gptLive)
        if gptLiveControllerCreated { gptLiveController.stop() }
        showGPTLiveSheet = false
        if minimisedLiveVoice == .gptLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        dropGPTLiveHostContext()
        if voiceCallRecorder?.engine == .gptLive { finishVoiceCallRecording() }
    }

    /// Personal text (the host's memory and persona) isn't kept around
    /// between conversations, nor once nothing presents one.
    private func dropGPTLiveHostContext() {
        gptLiveMemoryContext = nil
        gptLiveWebLookUps = false
        gptLivePersonality = nil
    }

    /// Boundary teardown (disconnect, server/profile change, sign-out, or
    /// another voice mode taking over).
    func stopGPTLiveConversation() {
        // A conversation that already failed with no sheet up has nothing
        // to close, but its host text still goes at the boundary.
        guard showGPTLiveSheet || minimisedLiveVoice == .gptLive || isGPTLiveActive else {
            dropGPTLiveHostContext()
            // Its recording still closes, so the call is saved, and its
            // work lets go of the call (#449).
            if voiceCallRecorder?.engine == .gptLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .gptLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.gptLive)
        closeGPTLiveConversation()
    }

    /// Grok Live through the host's SuperGrok sign-in: an opt-in, per-profile
    /// Voice mode (off by default), never on together with another live mode.
    var isGrokLiveEnabled: Bool {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        return preferences.grokLiveEnabled && !preferences.qwenLiveEnabled && !preferences.geminiLiveEnabled && !preferences.gptLiveEnabled
    }
}
