//
//  AppState+GeminiQwenLive.swift
//  Conduit
//
//  Gemini Live and Qwen Live: their settings, opening and closing a call,
//  CarPlay, and the direct live controller they share. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Gemini Live and Qwen Live

    /// Applies from the next Gemini Live conversation.
    func setGeminiLiveSearchMode(_ mode: GeminiLiveSearchMode) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: GeminiLiveSearchMode? = mode == .automatic ? nil : mode
        guard preferences.geminiLiveSearch != stored else { return }
        objectWillChange.send()
        preferences.geminiLiveSearch = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The prebuilt voice Gemini Live speaks with on this profile; nil is
    /// Gemini's default voice.
    var geminiLiveVoice: String? {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLiveVoice
    }

    /// Applies from the next Gemini Live conversation.
    func setGeminiLiveVoice(_ voice: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored = voice.flatMap { $0.isEmpty ? nil : $0 }
        guard preferences.geminiLiveVoice != stored else { return }
        objectWillChange.send()
        preferences.geminiLiveVoice = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether Gemini Live gets the Hermes host's memory on this profile.
    /// Off until the user turns it on: it sends that memory to Google.
    var geminiLiveMemoryEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLiveMemory ?? false
    }

    /// Applies from the next Gemini Live conversation.
    func setGeminiLiveMemoryEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.geminiLiveMemory != stored else { return }
        objectWillChange.send()
        preferences.geminiLiveMemory = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether Gemini Live speaks as the profile's SOUL.md persona. Off
    /// until the user turns it on: it sends SOUL.md to Google.
    var geminiLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLivePersonality ?? false
    }

    /// Applies from the next Gemini Live conversation.
    func setGeminiLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.geminiLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.geminiLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Where Qwen Live's quick lookups search on this profile.
    var qwenLiveSearchMode: GeminiLiveSearchMode {
        loadVoiceProfilePreferences(profile: activeProfile).qwenLiveSearch ?? .automatic
    }

    /// Applies from the next Qwen Live conversation.
    func setQwenLiveSearchMode(_ mode: GeminiLiveSearchMode) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: GeminiLiveSearchMode? = mode == .automatic ? nil : mode
        guard preferences.qwenLiveSearch != stored else { return }
        objectWillChange.send()
        preferences.qwenLiveSearch = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The prebuilt voice Qwen Live speaks with on this profile; nil is
    /// Qwen's default voice.
    var qwenLiveVoice: String? {
        loadVoiceProfilePreferences(profile: activeProfile).qwenLiveVoice
    }

    /// Applies from the next Qwen Live conversation.
    func setQwenLiveVoice(_ voice: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored = voice.flatMap { $0.isEmpty ? nil : $0 }
        guard preferences.qwenLiveVoice != stored else { return }
        objectWillChange.send()
        preferences.qwenLiveVoice = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether Qwen Live gets the Hermes host's memory on this profile.
    /// Off until the user turns it on: it sends that memory to Alibaba Cloud.
    var qwenLiveMemoryEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).qwenLiveMemory ?? false
    }

    /// Applies from the next Qwen Live conversation.
    func setQwenLiveMemoryEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.qwenLiveMemory != stored else { return }
        objectWillChange.send()
        preferences.qwenLiveMemory = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether Qwen Live speaks as the profile's SOUL.md persona. Off
    /// until the user turns it on: it sends SOUL.md to Alibaba Cloud.
    var qwenLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).qwenLivePersonality ?? false
    }

    /// Applies from the next Qwen Live conversation.
    func setQwenLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.qwenLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.qwenLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    private func resolveGeminiLiveSearchSource() async -> GeminiLiveSearchSource {
        let mode = geminiLiveSearchMode
        let hermesAvailable = mode == .automatic ? await geminiLiveTokenClient.webSearchAvailable() : false
        return mode.resolved(hermesAvailable: hermesAvailable)
    }

    private func resolveQwenLiveSearchSource() async -> GeminiLiveSearchSource {
        guard qwenLiveSearchMode != .off else { return .none }
        return await qwenLiveTokenClient.webSearchAvailable() ? .hermes : .none
    }

    /// A live mode turned on (Settings > Voice, an agent's config write)
    /// while a classic conversation runs ends that conversation, as a mode
    /// switch from the call's menu or a live start from the car does.
    /// Otherwise the car followed the new mode while the classic call went
    /// on listening behind it, on no surface that showed or ended it (#1935).
    /// A call screen under push to talk waiting for its first press counts
    /// too: it has no session yet, and its press would open Classic's mic.
    func closeClassicConversationForLiveMode() {
        let waitsForFirstPress = showVoiceSheet && voiceConversationController.isPushToTalkActive
        guard voiceConversationController.hasConversationSession || waitsForFirstPress else { return }
        closeVoiceConversation()
    }

    func setGeminiLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.geminiLiveEnabled != enabled else { return }
        objectWillChange.send()
        preferences.geminiLiveEnabled = enabled
        // One live voice engine per profile: turning Gemini on turns the others off.
        if enabled {
            preferences.qwenLiveEnabled = false
            preferences.gptLiveEnabled = false
            preferences.grokLiveEnabled = false
            preferences.localLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            closeClassicConversationForLiveMode()
            closeQwenLiveConversation()
            closeGPTLiveConversation()
            closeGrokLiveConversation()
            closeLocalLiveConversation()
        } else {
            closeGeminiLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    func setQwenLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.qwenLiveEnabled != enabled || (enabled && (preferences.geminiLiveEnabled || preferences.gptLiveEnabled || preferences.grokLiveEnabled || preferences.localLiveEnabled)) else { return }
        objectWillChange.send()
        preferences.qwenLiveEnabled = enabled
        // One live voice engine per profile: turning Qwen on turns the others off.
        if enabled {
            preferences.geminiLiveEnabled = false
            preferences.gptLiveEnabled = false
            preferences.grokLiveEnabled = false
            preferences.localLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            closeClassicConversationForLiveMode()
            closeGeminiLiveConversation()
            closeGPTLiveConversation()
            closeGrokLiveConversation()
            closeLocalLiveConversation()
        } else {
            closeQwenLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// Gemini or Qwen Live's host routes for `profile`: the active
    /// profile's for the phone's calls, a Watch call's own profile for the
    /// Watch's, which may not be the one the iPhone is on (#1564).
    func makeLiveTokenClient(provider: DirectLiveProvider, profile: @escaping @MainActor () -> String) -> GeminiLiveTokenClient {
        GeminiLiveTokenClient(profile: profile, provider: { provider }, request: { [weak self] path, method, body, timeout in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        })
    }

    var isQwenLiveActive: Bool { qwenLiveControllerCreated && qwenLiveController.isActive }

    /// Whether a Gemini Live conversation is running, without creating one.
    var isGeminiLiveActive: Bool {
        geminiLiveControllerCreated && geminiLiveController.isActive
    }

    /// Provider-specific state and credentials, shared audio/tool machinery.
    func makeDirectLiveController(provider: DirectLiveProvider) -> GeminiLiveConversationController {
        let qwen = provider == .qwen
        let mode: LiveVoiceModeName = qwen ? .qwenLive : .geminiLive
        if qwen { qwenLiveControllerCreated = true } else { geminiLiveControllerCreated = true }
        let tokens = qwen ? qwenLiveTokenClient : geminiLiveTokenClient
        let audio = makeLiveVoiceAudio(outputSampleRate: GeminiLiveProtocol.outputSampleRate)
        let controller = GeminiLiveConversationController(
            makeSession: { [weak self] in
                let search = qwen ? (self?.qwenLiveSearchSource ?? .none) : (self?.geminiLiveSearchSource ?? .google)
                let memory = qwen ? self?.qwenLiveMemoryContext : self?.geminiLiveMemoryContext
                let session = GeminiLiveSession(
                    tokens: tokens,
                    systemInstruction: GeminiLiveConversationController.instructions(
                        search: search,
                        memory: memory,
                        personality: qwen ? self?.qwenLivePersonality : self?.geminiLivePersonality,
                        answerLength: self?.liveVoiceStyle.answerLength ?? .standard,
                        followedBy: (self?.liveVoiceResumeContext?.instructionBlock ?? "")
                            + (self?.liveHermesCallInstructions(delegation: false) ?? "")
                            + (self.map { $0.liveVoiceThreadInstructions(delegation: false) + $0.phoneVoiceSettingHint(for: mode) } ?? "")
                            + VoiceHostTool.functionToolsFirst(self?.voiceBackgroundJobSupervisor.hostTools ?? [])
                            + LiveVoiceStyle.askFirstInstructions(on: self?.voiceBackgroundJobSupervisor.asksBeforeSending == true)
                            + (self?.liveVoiceStyle.instructions ?? "")
                    ),
                    functions: GeminiLiveToolBridge.declarations(
                        webSearch: search == .hermes,
                        memoryRecall: memory?.canRecall == true,
                        thread: self?.voiceBackgroundJobSupervisor.liveThread != nil,
                        callback: self?.supportsHermesCalls == true,
                        waitsOn: self?.liveHermesCall?.kind,
                        chats: true,
                        jobApprovals: true
                    ) + VoiceHostTool.declarations(self?.voiceBackgroundJobSupervisor.hostTools ?? []),
                    googleSearch: search == .google,
                    voice: qwen ? self?.qwenLiveVoice : self?.geminiLiveVoice
                )
                if qwen { session.onTrace = { LiveCallTrace.shared.note($0) } }
                return session
            },
            availability: { [weak self] in
                guard let self else { return try await tokens.availability() }
                // Resolved before each conversation, so a changed setting or
                // a newly configured host backend applies on the next one.
                // The host calls run together: one after another they
                // stacked four round trips in front of every connection.
                let wantsMemory = qwen ? self.qwenLiveMemoryEnabled : self.geminiLiveMemoryEnabled
                let wantsPersonality = qwen ? self.qwenLivePersonalityEnabled : self.geminiLivePersonalityEnabled
                async let search = qwen ? self.resolveQwenLiveSearchSource() : self.resolveGeminiLiveSearchSource()
                async let memory = wantsMemory ? tokens.memoryContext() : nil
                async let loadedPersonality = wantsPersonality ? tokens.personality() : nil
                async let hostTools: Void = self.prepareVoiceHostTools(for: mode)
                let status = try await tokens.availability()
                // Unavailable: return now; leaving scope cancels the other
                // calls instead of waiting on them.
                guard status.isAvailable else { return status }
                let resolvedSearch = await search
                let resolvedMemory = await memory
                let resolvedPersonality = await loadedPersonality
                if qwen {
                    self.qwenLiveSearchSource = resolvedSearch
                    self.qwenLiveMemoryContext = resolvedMemory
                    self.qwenLivePersonality = resolvedPersonality
                } else {
                    self.geminiLiveSearchSource = resolvedSearch
                    self.geminiLiveMemoryContext = resolvedMemory
                    self.geminiLivePersonality = resolvedPersonality
                }
                await hostTools
                return status
            },
            // Fails closed: without the app state, the stored answer decides.
            missingConsent: { [weak self] in self?.requestLiveVoiceConsentIfMissing(mode) ?? LiveVoiceProviderConsent.missing(mode) },
            tools: GeminiLiveToolBridge(supervisor: self.voiceBackgroundJobSupervisor, webSearch: tokens, memory: tokens),
            input: audio.input,
            output: audio.output,
            // The same "End conversation" phrases as the classic Voice mode.
            endConversationPhrases: { [weak self] in
                guard let self else { return [] }
                return self.loadVoiceProfilePreferences(profile: self.activeProfile).resolvedSpokenEndConversationPhrases
            },
            // A call Hermes made opens with why it called, not a greeting (#449).
            openingPrompt: { [weak self] in self?.liveHermesCall?.openingTurn ?? self?.liveVoiceStyle.openingPrompt },
            provider: provider
        )
        controller.startsMuted = { [weak self] in self?.hermesCallStartsMuted ?? false }
        // Gemini sends no turn detection events, so only Qwen's calls are traced.
        if qwen { controller.traceName = "Qwen Live" }
        // A hands-free goodbye closes the sheet like the Close button.
        controller.onEndConversation = { [weak self] in
            if qwen { self?.closeQwenLiveConversation() } else { self?.closeGeminiLiveConversation() }
        }
        return controller
    }

    /// Opens Gemini Live instead of the classic Voice conversation. The
    /// classic conversation (and Read Aloud) is closed first so the two
    /// modes never share the audio session.
    @discardableResult
    func openGeminiLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .geminiLive { minimisedLiveVoice = nil }
        showGeminiLiveSheet = true
        if !geminiLiveController.isActive {
            geminiLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            beginVoiceCallRecording(engine: .geminiLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.geminiLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.geminiLive) else { return }
                await geminiLiveController.start()
            }
        }
        return true
    }

    /// Starts Gemini Live for the CarPlay surface. CarPlay presents it, so
    /// no phone sheet opens; the classic conversation and read aloud stop
    /// first, as on the phone.
    func startGeminiLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        guard !geminiLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        beginVoiceCallRecording(engine: .geminiLive)
        await geminiLiveController.start()
    }

    /// CarPlay went away. A Gemini Live conversation only CarPlay was
    /// presenting ends; one the phone's sheet or minimised bar shows keeps going. A
    /// conversation that already failed drops its memory and persona too:
    /// nothing presents it, so nothing would close it.
    func releaseCarPlayGeminiLive() {
        guard !(isSceneActive && (showGeminiLiveSheet || minimisedLiveVoice == .geminiLive)) else { return }
        if isGeminiLiveActive {
            closeGeminiLiveConversation()
        } else {
            // Its work lets go of the call too (#449).
            finishHermesCallbacks(engine: .geminiLive)
            dropGeminiLiveHostContext()
            if voiceCallRecorder?.engine == .geminiLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .geminiLive { minimisedLiveVoice = nil }
        }
    }

    func closeGeminiLiveConversation() {
        callOffWaitingCall(.geminiLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .geminiLive)
        if geminiLiveControllerCreated { geminiLiveController.stop() }
        showGeminiLiveSheet = false
        if minimisedLiveVoice == .geminiLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        dropGeminiLiveHostContext()
        if voiceCallRecorder?.engine == .geminiLive { finishVoiceCallRecording() }
    }

    /// Personal text (the host's memory and persona) isn't kept around
    /// between conversations, nor once nothing presents one.
    private func dropGeminiLiveHostContext() {
        geminiLiveMemoryContext = nil
        geminiLivePersonality = nil
    }

    /// Boundary teardown (disconnect, server/profile change, forced
    /// sign-out). Background jobs are retired by the same boundaries.
    func stopGeminiLiveConversation() {
        // A conversation that already failed with no sheet up has nothing
        // to close, but its host text still goes at the boundary.
        guard showGeminiLiveSheet || minimisedLiveVoice == .geminiLive || isGeminiLiveActive else {
            dropGeminiLiveHostContext()
            // Its recording still closes, so the call is saved, and its
            // work lets go of the call (#449).
            if voiceCallRecorder?.engine == .geminiLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .geminiLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.geminiLive)
        closeGeminiLiveConversation()
    }

    /// Opens Qwen Live instead of the classic Voice conversation. The
    /// classic conversation (and Read Aloud) is closed first so the two
    /// modes never share the audio session.
    @discardableResult
    func openQwenLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .qwenLive { minimisedLiveVoice = nil }
        showQwenLiveSheet = true
        if !qwenLiveController.isActive {
            qwenLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            beginVoiceCallRecording(engine: .qwenLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.qwenLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.qwenLive) else { return }
                await qwenLiveController.start()
            }
        }
        return true
    }

    /// Starts Qwen Live for the CarPlay surface. CarPlay presents it, so
    /// no phone sheet opens; the classic conversation and read aloud stop
    /// first, as on the phone.
    func startQwenLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        guard !qwenLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        beginVoiceCallRecording(engine: .qwenLive)
        await qwenLiveController.start()
    }

    /// CarPlay went away. A Qwen Live conversation only CarPlay was
    /// presenting ends; one the phone's sheet or minimised bar shows keeps going. A
    /// conversation that already failed drops its memory and persona too:
    /// nothing presents it, so nothing would close it.
    func releaseCarPlayQwenLive() {
        guard !(isSceneActive && (showQwenLiveSheet || minimisedLiveVoice == .qwenLive)) else { return }
        if isQwenLiveActive {
            closeQwenLiveConversation()
        } else {
            // Its work lets go of the call too (#449).
            finishHermesCallbacks(engine: .qwenLive)
            dropQwenLiveHostContext()
            if voiceCallRecorder?.engine == .qwenLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .qwenLive { minimisedLiveVoice = nil }
        }
    }

    func closeQwenLiveConversation() {
        callOffWaitingCall(.qwenLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .qwenLive)
        if qwenLiveControllerCreated { qwenLiveController.stop() }
        showQwenLiveSheet = false
        if minimisedLiveVoice == .qwenLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        dropQwenLiveHostContext()
        if voiceCallRecorder?.engine == .qwenLive { finishVoiceCallRecording() }
    }

    /// Personal text (the host's memory and persona) isn't kept around
    /// between conversations, nor once nothing presents one.
    private func dropQwenLiveHostContext() {
        qwenLiveMemoryContext = nil
        qwenLivePersonality = nil
    }

    /// Boundary teardown (disconnect, server/profile change, forced
    /// sign-out). Background jobs are retired by the same boundaries.
    func stopQwenLiveConversation() {
        // A conversation that already failed with no sheet up has nothing
        // to close, but its host text still goes at the boundary.
        guard showQwenLiveSheet || minimisedLiveVoice == .qwenLive || isQwenLiveActive else {
            dropQwenLiveHostContext()
            // Its recording still closes, so the call is saved, and its
            // work lets go of the call (#449).
            if voiceCallRecorder?.engine == .qwenLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .qwenLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.qwenLive)
        closeQwenLiveConversation()
    }

    /// GPT-Live on the host's ChatGPT subscription: an opt-in, per-profile
    /// Voice mode (off by default), never on together with Gemini Live.
    var isGPTLiveEnabled: Bool {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        return preferences.gptLiveEnabled && !preferences.qwenLiveEnabled && !preferences.geminiLiveEnabled
    }
}
