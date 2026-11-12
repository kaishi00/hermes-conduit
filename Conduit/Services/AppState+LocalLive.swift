//
//  AppState+LocalLive.swift
//  Conduit
//
//  Local Live: its agent and persona, its settings, its client, and
//  opening and closing a call, CarPlay included. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Local Live

    /// The same for `profile`, which a call from Hermes and the voice start
    /// it asks for both read, so they pick the same voice.
    func usesLocalLiveAgent(profile: String) -> Bool {
        loadVoiceProfilePreferences(profile: profile).localLiveAgent
    }

    func setLocalLiveAgent(_ agent: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.localLiveAgent != agent else { return }
        objectWillChange.send()
        preferences.localLiveAgent = agent
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        // A running call keeps its mode until it next connects: a new call,
        // or a reconnect after the socket drops, picks this up.
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// A starting call's claim on the persona; any earlier claim goes stale.
    func claimLocalLivePersonaLookup() -> Int {
        localLivePersonaLookup &+= 1
        return localLivePersonaLookup
    }

    /// Personal text goes, and any lookup still running is dropped.
    private func dropLocalLivePersonality() {
        localLivePersonality = nil
        localLivePersonaLookup &+= 1
    }

    /// Whether Local Live's fast model speaks as the profile's SOUL.md
    /// persona (issue 583). Off until the user turns it on: it sends
    /// SOUL.md to the fast model's server, and a long one slows a small
    /// model's first words.
    var localLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).localLivePersonality ?? false
    }

    /// Applies from the next Local Live call.
    func setLocalLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.localLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.localLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// What an agent-mode call gives the host's fast model: the live
    /// instructions and Grok Live's tools, run here, with the phone's own
    /// tools the user lets Local Live use. Nil outside agent mode.
    func localLiveAgentSetup() -> LocalLiveProtocol.AgentSetup? {
        guard isLocalLiveAgent else { return nil }
        let supervisor = voiceBackgroundJobSupervisor
        var tail: String = LocalLiveProtocol.agentInstructions
        tail += GrokLiveProtocol.clockInstructions(now: Date(), timeZone: .current)
        tail += liveVoiceResumeContext?.instructionBlock ?? ""
        tail += liveHermesCallInstructions(delegation: false)
        tail += liveVoiceThreadInstructions(delegation: false)
        tail += phoneVoiceSettingHint(for: .localLive)
        tail += VoiceHostTool.functionToolsFirst(supervisor.hostTools)
        tail += LiveVoiceStyle.askFirstInstructions(on: supervisor.asksBeforeSending)
        tail += liveVoiceStyle.instructions
        let instructions = GeminiLiveConversationController.instructions(
            search: localLiveWebLookUps ? .hermes : .none,
            personality: localLivePersonality,
            answerLength: liveVoiceStyle.answerLength,
            acknowledgesOnceStarted: true,
            followedBy: tail
        )
        let functions = GeminiLiveToolBridge.declarations(
            webSearch: localLiveWebLookUps,
            thread: supervisor.liveThread != nil,
            waitsOn: liveHermesCall?.kind,
            chats: true,
            jobApprovals: true
        ) + VoiceHostTool.declarations(supervisor.hostTools)
        return LocalLiveProtocol.AgentSetup(instructions: instructions, functions: functions)
    }

    func setLocalLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let othersOn = preferences.qwenLiveEnabled || preferences.geminiLiveEnabled || preferences.gptLiveEnabled || preferences.grokLiveEnabled
        guard preferences.localLiveEnabled != enabled || (enabled && othersOn) else { return }
        objectWillChange.send()
        preferences.localLiveEnabled = enabled
        // One live voice engine per profile: turning Local Live on turns the others off.
        if enabled {
            preferences.qwenLiveEnabled = false
            preferences.geminiLiveEnabled = false
            preferences.gptLiveEnabled = false
            preferences.grokLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            // A running Classic call stays: the car follows it (#1378). A
            // push to talk screen still waiting for its first press has no
            // session for the car to follow, so it closes (#1935).
            if showVoiceSheet, voiceConversationController.isPushToTalkActive,
               !voiceConversationController.hasConversationSession {
                closeVoiceConversation()
            }
            closeQwenLiveConversation()
            closeGeminiLiveConversation()
            closeGPTLiveConversation()
            closeGrokLiveConversation()
        } else {
            closeLocalLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// Local Live's host routes for `profile` (see makeLiveTokenClient).
    func makeLocalLiveClient(profile: @escaping @MainActor () -> String) -> LocalLiveClient {
        LocalLiveClient(profile: profile, profileParameter: { [weak self] in
            self?.notifierPlugin.dashboardProfileParameter ?? "profile"
        }, dashboardBaseURL: { [weak self] in
            self?.connection?.baseUrl
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
            // dashboard's own session cookies (cookie mode), as for Grok's relay.
            let request = URLRequest(url: url).applyingProxyHeaders(cloudflare: bridge.cloudflareAccess)
            return try await bridge.requestAuthorizer.authorizeUpgrade(request)
        })
    }

    /// Whether a Local Live call is running, without creating one.
    var isLocalLiveActive: Bool {
        localLiveControllerCreated && localLiveController.isActive
    }

    /// Opens Local Live instead of the other voice modes, which (with Read
    /// Aloud) are closed first so they never share the audio session.
    @discardableResult
    func openLocalLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .localLive { minimisedLiveVoice = nil }
        showLocalLiveSheet = true
        if !localLiveController.isActive {
            localLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            localLiveTurns.reset()
            localLiveOwnChat = nil
            beginVoiceCallRecording(engine: .localLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.localLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.localLive) else { return }
                await localLiveController.start()
            }
        }
        return true
    }

    /// Starts Local Live for the CarPlay surface. CarPlay presents it, so no
    /// phone sheet opens; the other voice modes and read aloud stop first,
    /// as on the phone.
    func startLocalLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        guard !localLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        localLiveTurns.reset()
        localLiveOwnChat = nil
        beginVoiceCallRecording(engine: .localLive)
        await localLiveController.start()
    }

    /// CarPlay went away. A Local Live call only CarPlay was presenting
    /// ends; one the phone's sheet or minimised bar shows keeps going.
    func releaseCarPlayLocalLive() {
        guard !(isSceneActive && (showLocalLiveSheet || minimisedLiveVoice == .localLive)) else { return }
        if isLocalLiveActive {
            closeLocalLiveConversation()
        } else {
            // Its work lets go of the call too (#449), and no turn of it
            // runs on.
            finishHermesCallbacks(engine: .localLive)
            if localLiveControllerCreated { localLiveTurns.reset() }
            localLiveOwnChat = nil
            // Personal text goes with the call it was fetched for.
            dropLocalLivePersonality()
            if voiceCallRecorder?.engine == .localLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .localLive { minimisedLiveVoice = nil }
        }
    }

    func closeLocalLiveConversation() {
        callOffWaitingCall(.localLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .localLive)
        if localLiveControllerCreated {
            localLiveController.stop()
            localLiveTurns.reset()
        }
        localLiveOwnChat = nil
        dropLocalLivePersonality()
        showLocalLiveSheet = false
        if minimisedLiveVoice == .localLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        if voiceCallRecorder?.engine == .localLive { finishVoiceCallRecording() }
    }

    /// Boundary teardown (disconnect, server/profile change, sign-out, or
    /// another voice mode taking over).
    func stopLocalLiveConversation() {
        guard showLocalLiveSheet || minimisedLiveVoice == .localLive || isLocalLiveActive else {
            // Personal text goes at the boundary even with no call up.
            dropLocalLivePersonality()
            // Its recording still closes, so the call is saved.
            if voiceCallRecorder?.engine == .localLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .localLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.localLive)
        closeLocalLiveConversation()
    }

    /// Where the voice jobs' ledger is kept for this dashboard and profile
    /// (M5b): a relaunch follows the jobs a call left running.
    var voiceJobLedgerKey: String {
        "conduit.voiceJobLedger.\(activeDashboardID?.uuidString ?? "none").\(activeProfile)"
    }
}
