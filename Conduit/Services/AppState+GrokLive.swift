//
//  AppState+GrokLive.swift
//  Conduit
//
//  Grok Live: its settings, its client, and opening and closing a call,
//  CarPlay included. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Grok Live

    func setGrokLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let othersOn = preferences.qwenLiveEnabled || preferences.geminiLiveEnabled || preferences.gptLiveEnabled || preferences.localLiveEnabled
        guard preferences.grokLiveEnabled != enabled || (enabled && othersOn) else { return }
        objectWillChange.send()
        preferences.grokLiveEnabled = enabled
        // One live voice engine per profile: turning Grok Live on turns the others off.
        if enabled {
            preferences.qwenLiveEnabled = false
            preferences.geminiLiveEnabled = false
            preferences.gptLiveEnabled = false
            preferences.localLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            closeClassicConversationForLiveMode()
            closeQwenLiveConversation()
            closeGeminiLiveConversation()
            closeGPTLiveConversation()
            closeLocalLiveConversation()
        } else {
            closeGrokLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// Whether Grok Live gets the Hermes host's memory on this profile. Off
    /// until the user turns it on: it sends that memory to xAI.
    var grokLiveMemoryEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).grokLiveMemory ?? false
    }

    /// Applies from the next Grok Live conversation.
    func setGrokLiveMemoryEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.grokLiveMemory != stored else { return }
        objectWillChange.send()
        preferences.grokLiveMemory = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether Grok Live speaks as the profile's SOUL.md persona. Off until
    /// the user turns it on: it sends SOUL.md to xAI.
    var grokLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).grokLivePersonality ?? false
    }

    /// Applies from the next Grok Live conversation.
    func setGrokLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.grokLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.grokLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Grok Live's host routes for `profile` (see makeLiveTokenClient).
    func makeGrokLiveClient(profile: @escaping @MainActor () -> String) -> GrokLiveClient {
        GrokLiveClient(profile: profile, profileParameter: { [weak self] in
            self?.notifierPlugin.dashboardProfileParameter ?? "profile"
        }, request: { [weak self] path, method, body, timeout in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }, mintTicket: { [weak self] in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.mintTicket()
        }, socketRequest: { [weak self] path, queryItems in
            guard let bridge = self?.dashboardTicketBridge, let connection = self?.connection else {
                throw DashboardTicketBridgeError.notReady
            }
            let url = try ConnectionURLPolicy.webSocketURL(baseURL: connection.baseUrl, path: path, queryItems: queryItems)
            // Behind Cloudflare Access the upgrade needs the service-token
            // headers, like the speech stream's. The authorizer then adds the
            // dashboard's own session cookies (cookie mode).
            let request = URLRequest(url: url).applyingProxyHeaders(cloudflare: bridge.cloudflareAccess)
            return try await bridge.requestAuthorizer.authorizeUpgrade(request)
        })
    }

    /// Whether a Grok Live conversation is running, without creating one.
    var isGrokLiveActive: Bool {
        grokLiveControllerCreated && grokLiveController.isActive
    }

    /// Opens Grok Live instead of the other voice modes, which (with Read
    /// Aloud) are closed first so they never share the audio session.
    @discardableResult
    func openGrokLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopLocalLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .grokLive { minimisedLiveVoice = nil }
        showGrokLiveSheet = true
        if !grokLiveController.isActive {
            grokLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            // Grok's start_job answers at once: a job's result has to be
            // read from its chat for the call to hear it (#599).
            voiceBackgroundJobSupervisor.liveCallReadsReplies = true
            beginVoiceCallRecording(engine: .grokLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.grokLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.grokLive) else { return }
                await grokLiveController.start()
            }
        }
        return true
    }

    /// Starts Grok Live for the CarPlay surface. CarPlay presents it, so no
    /// phone sheet opens; the other voice modes and read aloud stop first,
    /// as on the phone.
    func startGrokLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopLocalLiveConversation()
        guard !grokLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        voiceBackgroundJobSupervisor.liveCallReadsReplies = true
        beginVoiceCallRecording(engine: .grokLive)
        await grokLiveController.start()
    }

    /// CarPlay went away. A Grok Live call only CarPlay was presenting ends;
    /// one the phone's sheet or minimised bar shows keeps going. A call that already failed
    /// drops its memory and persona too: nothing presents it, so nothing
    /// would close it.
    func releaseCarPlayGrokLive() {
        guard !(isSceneActive && (showGrokLiveSheet || minimisedLiveVoice == .grokLive)) else { return }
        if isGrokLiveActive {
            closeGrokLiveConversation()
        } else {
            // Its work lets go of the call too (#449).
            finishHermesCallbacks(engine: .grokLive)
            dropGrokLiveHostContext()
            voiceBackgroundJobSupervisor.liveCallReadsReplies = false
            if voiceCallRecorder?.engine == .grokLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .grokLive { minimisedLiveVoice = nil }
        }
    }

    func closeGrokLiveConversation() {
        callOffWaitingCall(.grokLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .grokLive)
        if grokLiveControllerCreated { grokLiveController.stop() }
        showGrokLiveSheet = false
        if minimisedLiveVoice == .grokLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        dropGrokLiveHostContext()
        voiceBackgroundJobSupervisor.liveCallReadsReplies = false
        if voiceCallRecorder?.engine == .grokLive { finishVoiceCallRecording() }
    }

    /// Personal text (the host's memory and persona) isn't kept around
    /// between conversations, nor once nothing presents one.
    private func dropGrokLiveHostContext() {
        grokLiveMemoryContext = nil
        grokLivePersonality = nil
    }

    /// Boundary teardown (disconnect, server/profile change, sign-out, or
    /// another voice mode taking over).
    func stopGrokLiveConversation() {
        // A conversation that already failed with no sheet up has nothing
        // to close, but its host text still goes at the boundary.
        guard showGrokLiveSheet || minimisedLiveVoice == .grokLive || isGrokLiveActive else {
            dropGrokLiveHostContext()
            voiceBackgroundJobSupervisor.liveCallReadsReplies = false
            // Its recording still closes, so the call is saved, and its
            // work lets go of the call (#449).
            if voiceCallRecorder?.engine == .grokLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .grokLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.grokLive)
        closeGrokLiveConversation()
    }

    /// Local Live through the user's own speech server: an opt-in,
    /// per-profile Voice mode (off by default), never on together with
    /// another live mode.
    var isLocalLiveEnabled: Bool {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        return preferences.localLiveEnabled && !preferences.qwenLiveEnabled && !preferences.geminiLiveEnabled
            && !preferences.gptLiveEnabled && !preferences.grokLiveEnabled
    }

    /// Local Live in agent mode (Live > Local) rather than Classic's
    /// hands-free option on the speech server.
    var isLocalLiveAgent: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).localLiveAgent
    }
}
