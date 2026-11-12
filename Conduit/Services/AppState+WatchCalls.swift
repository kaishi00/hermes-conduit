//
//  AppState+WatchCalls.swift
//  Conduit
//
//  Calls from the Watch: planning a direct, bridged, Grok or local live
//  call, its connection and host tools, and saving the call. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Watch calls

    func setWatchVoiceCallActive(_ active: Bool) {
        if active { releaseLaunchDashboardChoice(for: "the Apple Watch") }
        isWatchVoiceCallActive = active
    }

    /// What a Watch call to Gemini Live starts with: the setup this
    /// profile's Gemini Live call gets on the phone, and the session's
    /// first single-use token (designs/apple-watch-voice-direct.md).
    struct WatchDirectPlan {
        let systemInstruction: String
        let functions: [GeminiLiveProtocol.FunctionDeclaration]
        let googleSearch: Bool
        let voice: String?
        let openingPrompt: String?
        let token: GeminiLiveToken
        /// The connection the setup, token and tools came from.
        let connection: WatchDirectConnection
        /// The profile's "Save voice calls" setting as the call began.
        let saveCalls: Bool
        let memoryIncluded: Bool
        let personalityIncluded: Bool
        /// The voice-job model settings for jobs the Watch starts through
        /// the push relay, as `createSession` sends them for a phone job.
        let jobOptions: [String: String]
        /// The profile's spoken end phrases, as the phone's call uses them.
        let endPhrases: [String]
        /// The names the call's jobs may give the user's profiles.
        let jobProfiles: [WatchVoiceWire.JobProfileName]
        /// The phone's own tools the call may use, and the instructions with
        /// the lines that brief the model on them (before the call's
        /// language, issue 1868); left out when the setup doesn't fit the Watch.
        var hostTools: [VoiceHostTool] = []
        var systemInstructionWithHostTools = ""
        /// The chat of the call from Hermes the Watch may answer (the
        /// grant's answer_call), or none.
        var answerSessions: [String] = []
    }

    /// Builds a Watch call's setup as `geminiLiveController` builds the
    /// phone's: the same search, memory and persona lookups, instructions,
    /// functions and voice. The call has no attached chat and no phone
    /// screen, so it gets no chat tools and no resume context. `target`:
    /// the call from Hermes it answers, which it opens with.
    func prepareWatchDirectCall(answering target: ConduitNotificationTarget? = nil, provider: DirectLiveProvider = .gemini) async throws -> WatchDirectPlan {
        // Woken (or launched) by the Watch with no phone screen up.
        if isSceneActive, !PhoneScenePresence.isInForeground {
            isSceneActive = false
            publishVoiceRuntimeGates()
        }
        guard await connectForWatchDirectCall(timeout: .seconds(20)) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.hermesUnreachable)
        }
        // The phone's microphone and the Watch's would both feed Hermes.
        guard !isLiveVoiceCallActive else { throw WatchDirectPrepareError(WatchVoiceStartFailure.callRunning) }
        // Every lookup below goes to the call's own profile, which may not
        // be the one open on the iPhone (#1564).
        let connection = watchDirectConnection(answering: target)
        let profile = connection.profile
        let preferences = loadVoiceProfilePreferences(profile: profile)
        let qwen = provider == .qwen
        let tokens = makeLiveTokenClient(provider: provider) { profile }
        let wantsMemory = (qwen ? preferences.qwenLiveMemory : preferences.geminiLiveMemory) ?? false
        let wantsPersonality = (qwen ? preferences.qwenLivePersonality : preferences.geminiLivePersonality) ?? false
        async let searchLookup = Self.watchCallSearchSource(qwen: qwen, preferences: preferences, tokens: tokens)
        async let memoryLookup = wantsMemory ? tokens.memoryContext() : nil
        async let personalityLookup = wantsPersonality ? tokens.personality() : nil
        async let hermesCallLookup = watchHermesCallOpening(for: target)
        async let waitingLookup = watchHermesCallWaiting(for: target, approvals: WatchJobSettings.voiceApprovals)
        async let hostToolsLookup = watchCallHostTools(for: qwen ? .qwenLive : .geminiLive, profile: profile)
        let status = try await tokens.availability()
        noteWatchCallVoice(qwen ? .qwenLive : .geminiLive, ready: status.isAvailable, profile: profile)
        guard status.isAvailable else {
            // The reason is worded for the active host's plugin.
            guard watchConnectionIsCurrent(connection) else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            throw WatchDirectPrepareError(PluginUpdateAsk.reason(status.userFacingReason(for: provider)) ?? GeminiLiveAvailability.notAvailable(for: provider))
        }
        let search = await searchLookup
        let memory = await memoryLookup
        let personality = await personalityLookup
        let hermesCall = await hermesCallLookup
        // With the chat's choices or command, answered through the host.
        let waiting = await waitingLookup
        let hostTools = await hostToolsLookup
        let token = try await tokens.freshToken()
        let style = preferences.liveVoiceStyle
        let jobSession = watchCallJobSession(preferences, profile: profile)
        var jobOptions: [String: String] = [:]
        if let model = jobSession.model {
            jobOptions["model"] = model
            if let provider = jobSession.provider { jobOptions["provider"] = provider }
        }
        if let effort = jobSession.reasoningEffort { jobOptions["reasoning_effort"] = effort }
        // A switch while the lookups ran would mix two connections' setup.
        guard watchConnectionIsCurrent(connection) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
        }
        func instruction(_ hostToolsBriefing: String) -> String {
            GeminiLiveConversationController.instructions(
                search: search,
                memory: memory,
                personality: personality,
                answerLength: style.answerLength,
                asksFirst: false,
                onWatch: true,
                followedBy: (hermesCall?.instructionBlock(delegation: false, canAnswer: waiting != nil, waiting: waiting?.waiting) ?? "")
                    + style.instructions + hostToolsBriefing
            )
        }
        return WatchDirectPlan(
            systemInstruction: instruction(""),
            functions: GeminiLiveToolBridge.watchDeclarations(
                webSearch: search == .hermes,
                memoryRecall: memory?.canRecall == true,
                chats: true,
                answers: waiting?.waiting.kind
            ),
            googleSearch: search == .google,
            voice: qwen ? preferences.qwenLiveVoice : preferences.geminiLiveVoice,
            openingPrompt: hermesCall?.watchOpeningTurn(canAnswer: waiting != nil) ?? style.openingPrompt,
            token: token,
            connection: connection,
            saveCalls: preferences.saveVoiceCalls ?? true,
            memoryIncluded: memory != nil,
            personalityIncluded: personality != nil,
            jobOptions: jobOptions,
            endPhrases: preferences.resolvedSpokenEndConversationPhrases,
            jobProfiles: watchJobProfileNames(callProfile: profile),
            hostTools: hostTools.tools,
            systemInstructionWithHostTools: hostTools.tools.isEmpty ? "" : instruction(hostTools.briefing),
            answerSessions: waiting?.sessionIDs ?? []
        )
    }

    /// What a Watch call to GPT-Live through the host's audio bridge
    /// starts with (designs/apple-watch-gpt-live.md): what the phone's own
    /// GPT-Live call sends the host, built the same way.
    struct WatchBridgePlan {
        let briefing: String
        let greeting: String?
        /// A call from Hermes opens with this turn instead of a greeting.
        var openingTurn: String? = nil
        let voice: String?
        let connection: WatchDirectConnection
        let saveCalls: Bool
        let memoryIncluded: Bool
        let personalityIncluded: Bool
        let jobOptions: [String: String]
        let endPhrases: [String]
        let jobProfiles: [WatchVoiceWire.JobProfileName]
        /// The chat of the call from Hermes the Watch may answer (the
        /// grant's answer_call), or none.
        var answerSessions: [String] = []
    }

    /// Builds a Watch GPT-Live call's briefing as `gptLiveController`
    /// builds the phone's: the same availability check, memory and persona
    /// lookups, answer length and style. The call has no attached chat and
    /// no resume context. `target`: the call from Hermes it answers.
    func prepareWatchBridgeCall(answering target: ConduitNotificationTarget? = nil) async throws -> WatchBridgePlan {
        if isSceneActive, !PhoneScenePresence.isInForeground {
            isSceneActive = false
            publishVoiceRuntimeGates()
        }
        guard await connectForWatchDirectCall(timeout: .seconds(20)) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.hermesUnreachable)
        }
        guard !isLiveVoiceCallActive else { throw WatchDirectPrepareError(WatchVoiceStartFailure.callRunning) }
        let connection = watchDirectConnection(answering: target)
        let profile = connection.profile
        let preferences = loadVoiceProfilePreferences(profile: profile)
        let hostContext = makeLiveTokenClient(provider: .gemini) { profile }
        let wantsMemory = preferences.gptLiveMemory ?? false
        let wantsPersonality = preferences.gptLivePersonality ?? false
        async let memoryLookup = wantsMemory ? hostContext.memoryContext() : nil
        async let personalityLookup = wantsPersonality ? hostContext.personality() : nil
        async let hermesCallLookup = watchHermesCallOpening(for: target)
        async let waitingLookup = watchHermesCallWaiting(for: target, approvals: false)
        // The host's Watch bridge only starts GPT-Live on the subscription.
        let status = try await makeGPTLiveClient { profile }.availability(billing: .subscription)
        noteWatchCallVoice(.gptLive, ready: status.isAvailable, profile: profile)
        guard status.isAvailable else {
            // The reason is worded for the active host's plugin.
            guard watchConnectionIsCurrent(connection) else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            throw WatchDirectPrepareError(status.userFacingReason ?? AppLocalization.string("GPT-Live is not available on this Hermes server."))
        }
        let memory = await memoryLookup
        let personality = await personalityLookup
        let hermesCall = await hermesCallLookup
        // "Answer:", "Approve:" and "Deny:" go to the host (WatchCallAnswer).
        let waiting = await waitingLookup
        let style = preferences.liveVoiceStyle
        let jobSession = watchCallJobSession(preferences, profile: profile)
        var jobOptions: [String: String] = [:]
        if let model = jobSession.model {
            jobOptions["model"] = model
            if let provider = jobSession.provider { jobOptions["provider"] = provider }
        }
        if let effort = jobSession.reasoningEffort { jobOptions["reasoning_effort"] = effort }
        guard watchConnectionIsCurrent(connection) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
        }
        return WatchBridgePlan(
            briefing: GPTLiveConversationController.briefing(
                memory: memory,
                personality: personality,
                answerLength: style.answerLength,
                onWatch: true,
                // GPT-Live on the Watch finds chats only through the grant,
                // and has no phone to fall back on: briefed only once the host
                // has reported them.
                watchChats: notifierPlugin.reports(WatchToolAnswer.chatCapability),
                followedBy: (hermesCall?.instructionBlock(delegation: true, canAnswer: waiting != nil, waiting: waiting?.waiting) ?? "") + style.instructions
            ),
            // A call Hermes made opens with its brief instead (#449).
            greeting: hermesCall == nil ? style.greeting : nil,
            openingTurn: hermesCall?.watchOpeningTurn(canAnswer: waiting != nil),
            voice: preferences.gptLiveVoice,
            connection: connection,
            saveCalls: preferences.saveVoiceCalls ?? true,
            memoryIncluded: memory != nil,
            personalityIncluded: personality != nil,
            jobOptions: jobOptions,
            endPhrases: preferences.resolvedSpokenEndConversationPhrases,
            jobProfiles: watchJobProfileNames(callProfile: profile),
            answerSessions: waiting?.sessionIDs ?? []
        )
    }

    /// What a Watch call to Grok starts with: the setup this profile's
    /// Grok Live call gets on the phone. Unlike Gemini there's no token:
    /// the Hermes host holds xAI's session, on its own xAI sign-in, and the
    /// Watch reaches it through the call grant's audio bridge.
    struct WatchGrokPlan {
        let systemInstruction: String
        let functions: [GeminiLiveProtocol.FunctionDeclaration]
        let voice: String?
        let openingPrompt: String?
        let connection: WatchDirectConnection
        let saveCalls: Bool
        let memoryIncluded: Bool
        let personalityIncluded: Bool
        let jobOptions: [String: String]
        let endPhrases: [String]
        let jobProfiles: [WatchVoiceWire.JobProfileName]
        var hostTools: [VoiceHostTool] = []
        var systemInstructionWithHostTools = ""
        /// The chat of the call from Hermes the Watch may answer (the
        /// grant's answer_call), or none.
        var answerSessions: [String] = []
    }

    /// Builds a Watch Grok call's setup as `grokLiveController` builds the
    /// phone's: the same availability check, search, memory and persona
    /// lookups, instructions, functions and voice. The call has no attached
    /// chat and no resume context. `target`: the call from Hermes it
    /// answers, which it opens with.
    func prepareWatchGrokCall(answering target: ConduitNotificationTarget? = nil) async throws -> WatchGrokPlan {
        if isSceneActive, !PhoneScenePresence.isInForeground {
            isSceneActive = false
            publishVoiceRuntimeGates()
        }
        guard await connectForWatchDirectCall(timeout: .seconds(20)) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.hermesUnreachable)
        }
        guard !isLiveVoiceCallActive else { throw WatchDirectPrepareError(WatchVoiceStartFailure.callRunning) }
        let connection = watchDirectConnection(answering: target)
        let profile = connection.profile
        let preferences = loadVoiceProfilePreferences(profile: profile)
        let hostContext = makeLiveTokenClient(provider: .gemini) { profile }
        let wantsMemory = preferences.grokLiveMemory ?? false
        let wantsPersonality = preferences.grokLivePersonality ?? false
        async let memoryLookup = wantsMemory ? hostContext.memoryContext() : nil
        async let personalityLookup = wantsPersonality ? hostContext.personality() : nil
        async let hermesCallLookup = watchHermesCallOpening(for: target)
        async let waitingLookup = watchHermesCallWaiting(for: target, approvals: WatchJobSettings.voiceApprovals)
        async let hostToolsLookup = watchCallHostTools(for: .grokLive, profile: profile)
        let status = try await makeGrokLiveClient { profile }.availability()
        noteWatchCallVoice(.grokLive, ready: status.isAvailable, profile: profile)
        guard case .available(_, let voice, _) = status else {
            // The reason is worded for the active host's plugin.
            guard watchConnectionIsCurrent(connection) else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            throw WatchDirectPrepareError(PluginUpdateAsk.reason(status.userFacingReason) ?? AppLocalization.string("Grok Live is not available on this Hermes server."))
        }
        // xAI's own search (#598), as on the phone.
        let search = GeminiLiveSearchSource.grok
        let memory = await memoryLookup
        let personality = await personalityLookup
        let hermesCall = await hermesCallLookup
        let waiting = await waitingLookup
        let hostTools = await hostToolsLookup
        let style = preferences.liveVoiceStyle
        let jobSession = watchCallJobSession(preferences, profile: profile)
        var jobOptions: [String: String] = [:]
        if let model = jobSession.model {
            jobOptions["model"] = model
            if let provider = jobSession.provider { jobOptions["provider"] = provider }
        }
        if let effort = jobSession.reasoningEffort { jobOptions["reasoning_effort"] = effort }
        guard watchConnectionIsCurrent(connection) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
        }
        func instruction(_ hostToolsBriefing: String) -> String {
            GeminiLiveConversationController.instructions(
                search: search,
                memory: memory,
                personality: personality,
                answerLength: style.answerLength,
                asksFirst: false,
                onWatch: true,
                acknowledgesOnceStarted: true,
                followedBy: GrokLiveProtocol.grokInstructions(now: Date(), timeZone: .current)
                    + (hermesCall?.instructionBlock(delegation: false, canAnswer: waiting != nil, waiting: waiting?.waiting) ?? "")
                    + style.instructions + hostToolsBriefing
            )
        }
        return WatchGrokPlan(
            systemInstruction: instruction(""),
            functions: GeminiLiveToolBridge.watchDeclarations(
                webSearch: false,
                memoryRecall: memory?.canRecall == true,
                chats: true,
                answers: waiting?.waiting.kind
            ),
            voice: voice,
            openingPrompt: hermesCall?.watchOpeningTurn(canAnswer: waiting != nil) ?? style.openingPrompt,
            connection: connection,
            saveCalls: preferences.saveVoiceCalls ?? true,
            memoryIncluded: memory != nil,
            personalityIncluded: personality != nil,
            jobOptions: jobOptions,
            endPhrases: preferences.resolvedSpokenEndConversationPhrases,
            jobProfiles: watchJobProfileNames(callProfile: profile),
            hostTools: hostTools.tools,
            systemInstructionWithHostTools: hostTools.tools.isEmpty ? "" : instruction(hostTools.briefing),
            answerSessions: waiting?.sessionIDs ?? []
        )
    }

    /// The phone's own tools a Watch call on `mode` may use, as its phone
    /// call would get them (the calendar, reminders and alarms, health,
    /// location and maps, each as the user lets `mode` use it), and their
    /// briefing. Not the on-screen confirmations: nobody is looking at the
    /// phone. Run here, wrist up; the wrist-down relay doesn't carry them.
    func watchCallHostTools(for mode: LiveVoiceModeName, profile: String) async -> (tools: [VoiceHostTool], briefing: String) {
        let fetched = await voiceHostTools(for: mode, profile: profile)
        let tools = ((fetched.host ?? []) + fetched.local).filter { $0.key != PresentVoiceTool.key }
        return (tools, phoneVoiceSettingHint(for: mode, profile: profile) + VoiceHostTool.functionToolsFirst(tools))
    }

    /// What a Watch call to Local Live starts with. The host relays the
    /// Watch's session to the profile's speech server and runs its turns in
    /// a Hermes chat, so only what the speech server says first, the
    /// profile's end phrases and the saving choice come from here.
    struct WatchLocalLivePlan {
        let greeting: String?
        let connection: WatchDirectConnection
        let saveCalls: Bool
        let endPhrases: [String]
        /// The chat of the call from Hermes whose waiting question or
        /// approval the user's words answer on the host, or none.
        var answerSessions: [String] = []
    }

    /// Checks Local Live as the phone's call does, and resolves the
    /// greeting setting as `localLiveController` does.
    /// `target`: the call from Hermes the Watch answered, whose news the
    /// speech server says in place of the greeting.
    func prepareWatchLocalLiveCall(answering target: ConduitNotificationTarget? = nil) async throws -> WatchLocalLivePlan {
        if isSceneActive, !PhoneScenePresence.isInForeground {
            isSceneActive = false
            publishVoiceRuntimeGates()
        }
        guard await connectForWatchDirectCall(timeout: .seconds(20)) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.hermesUnreachable)
        }
        guard !isLiveVoiceCallActive else { throw WatchDirectPrepareError(WatchVoiceStartFailure.callRunning) }
        let connection = watchDirectConnection(answering: target)
        let profile = connection.profile
        let preferences = loadVoiceProfilePreferences(profile: profile)
        async let hermesCallLookup = watchHermesCallOpening(for: target)
        async let waitingLookup = watchHermesCallWaiting(for: target, approvals: WatchJobSettings.voiceApprovals)
        let status = try await makeLocalLiveClient { profile }.status()
        noteWatchCallVoice(.localLive, ready: status.available, profile: profile)
        if let reason = LocalLiveClient.unavailableReason(status) {
            // The reason is worded for the active host's plugin.
            guard watchConnectionIsCurrent(connection) else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            throw WatchDirectPrepareError(PluginUpdateAsk.reason(reason) ?? reason)
        }
        guard watchConnectionIsCurrent(connection) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
        }
        var greeting = preferences.liveVoiceStyle.greeting.map { $0.isEmpty ? AppLocalization.string("Hi, I'm listening.") : $0 }
        let hermesCall = await hermesCallLookup
        let waiting = await waitingLookup
        if let hermesCall {
            // Why Hermes called, with the question's choices or the
            // command; one the Watch can't answer is answered on the iPhone.
            greeting = hermesCall.spokenBrief(waiting: waiting?.waiting)
            if hermesCall.waitsOnUser, waiting == nil {
                greeting = (greeting ?? "") + " " + LocalLiveTurnRunner.needsInputLine
            }
        }
        return WatchLocalLivePlan(
            greeting: greeting,
            connection: connection,
            saveCalls: preferences.saveVoiceCalls ?? true,
            endPhrases: preferences.resolvedSpokenEndConversationPhrases,
            answerSessions: hermesCall == nil ? [] : waiting?.sessionIDs ?? []
        )
    }

    /// What a Watch call that answers a call from Hermes opens with
    /// (designs/hermes-calls-watch.md): the news the phone's own answer
    /// gives, with the reply read from the call's chat. Nil for any other
    /// Watch call. The call tells the user how the job went, so no voice
    /// conversation announces it again.
    private func watchHermesCallOpening(for target: ConduitNotificationTarget?) async -> HermesCallOpening? {
        guard let target, let call = target.call else { return nil }
        voiceBackgroundJobSupervisor.noteCallAnswered(sessionIDs: call.sessionIDs)
        var result: String?
        // Read on the dashboard in use only: another's chat isn't there.
        if target.dashboardID == nil || target.dashboardID == activeDashboardID {
            result = await latestLiveVoiceThreadReply(VoiceThreadTarget(
                runtimeSessionID: target.sessionId,
                storedSessionID: target.durableSessionID,
                title: call.title ?? "",
                profile: target.profile.map { profilesMatch($0, activeProfile) } == true ? nil : target.profile
            ))
        }
        return HermesCallOpening(kind: call.kind, title: call.title, result: result, reason: call.reason, sessionIDs: call.sessionIDs)
    }

    /// The connection a Watch call started now would belong to: the
    /// hands-free profile, or the profile of the call from Hermes it
    /// answers (#1564), with the profile the iPhone is on.
    func watchDirectConnection(answering target: ConduitNotificationTarget? = nil) -> WatchDirectConnection {
        WatchDirectConnection(
            profile: watchCallProfile(answering: target),
            dashboard: activeDashboardID?.uuidString ?? "-",
            phoneProfile: activeProfile
        )
    }

    /// The connection a Watch call started now would belong to.
    var watchDirectConnection: WatchDirectConnection { watchDirectConnection() }

    /// Whether a Watch call that began on `connection` still may run: the
    /// iPhone is on the dashboard and profile it was on then. A switch on
    /// the iPhone resets the jobs it runs for the call, so the call ends,
    /// as it always has; the call's own profile needn't be the iPhone's.
    func watchConnectionIsCurrent(_ connection: WatchDirectConnection) -> Bool {
        Self.watchConnection(connection, isCurrentOn: activeDashboardID?.uuidString ?? "-", phoneProfile: activeProfile)
    }

    nonisolated static func watchConnection(_ connection: WatchDirectConnection, isCurrentOn dashboard: String, phoneProfile: String) -> Bool {
        connection.dashboard == dashboard && profilesMatch(connection.phoneProfile ?? connection.profile, phoneProfile)
    }

    /// A single-use token for the Watch call's next connection, on the
    /// call's own profile.
    func watchDirectToken(provider: DirectLiveProvider = .gemini, profile: String) async throws -> GeminiLiveToken {
        guard await connectForWatchDirectCall(timeout: WatchDirectBroker.connectWait) else {
            throw WatchDirectPrepareError(WatchVoiceStartFailure.hermesUnreachable)
        }
        return try await makeLiveTokenClient(provider: provider) { profile }.freshToken()
    }

    /// The model a Watch call's jobs run on, as `createSession` sends a
    /// phone job's: the profile's voice-job model, else the model the
    /// iPhone runs, which is only the call's when it's on that profile.
    func watchCallJobSession(_ preferences: VoiceProfilePreferences, profile: String) -> (model: String?, provider: String?, reasoningEffort: String?) {
        let onPhonesProfile = profilesMatch(profile, activeProfile)
        return preferences.voiceJobSessionOptions(
            runtimeModel: onPhonesProfile ? runtime.model : "",
            runtimeProvider: onPhonesProfile ? runtime.provider : ""
        )
    }

    /// Where a Watch call's quick lookups search, as the phone's Gemini or
    /// Qwen Live call resolves it, for the call's profile.
    static func watchCallSearchSource(qwen: Bool, preferences: VoiceProfilePreferences, tokens: GeminiLiveTokenClient) async -> GeminiLiveSearchSource {
        if qwen {
            guard (preferences.qwenLiveSearch ?? .automatic) != .off else { return .none }
            return await tokens.webSearchAvailable() ? .hermes : .none
        }
        let mode = preferences.geminiLiveSearch ?? .automatic
        let hermesAvailable = mode == .automatic ? await tokens.webSearchAvailable() : false
        return mode.resolved(hermesAvailable: hermesAvailable)
    }

    /// Reconnects to Hermes if the phone's suspension dropped the
    /// connection, as a CarPlay call does. True once connected.
    func connectForWatchDirectCall(timeout: Duration) async -> Bool {
        if isConnected { return true }
        recoverTransportForCarPlayIfNeeded(immediately: true)
        return await CarPlayVoiceCoordinator.awaitConnection(of: self, timeout: timeout)
    }

    private static let watchDirectSavedCallsKey = "watchDirect.savedCalls"

    /// Saves a finished Watch call in voice history through the same
    /// outbox as the phone's calls: queued first, so a save Hermes can't
    /// take now is retried later. The Watch sends the transcript once the
    /// call ends, by a transfer that arrives whenever the phone next runs;
    /// one that arrives twice is saved once. It goes to the connection the
    /// call began on, whichever is active when it arrives.
    func saveWatchVoiceCall(_ transcript: WatchVoiceWire.DirectTranscript, connection: WatchDirectConnection, saveCalls: Bool, phoneJobs: [WatchVoiceWire.DirectJob] = []) async {
        let profile = connection.profile
        let dashboard = connection.dashboard
        guard saveCalls, !transcript.turns.isEmpty else { return }
        var saved = defaults.stringArray(forKey: Self.watchDirectSavedCallsKey) ?? []
        guard !saved.contains(transcript.callUUID) else { return }
        saved.append(transcript.callUUID)
        defaults.set(Array(saved.suffix(50)), forKey: Self.watchDirectSavedCallsKey)
        // The Watch's relay jobs and the ones the phone ran for the call.
        var jobs = transcript.jobs ?? []
        for job in phoneJobs where !jobs.contains(where: { $0.jobID == job.jobID }) { jobs.append(job) }
        jobs.sort { $0.startedAt < $1.startedAt }
        let turns = Self.watchCallTurns(transcript.turns, jobs: jobs)
        let jobSessions = jobs.compactMap(\.sessionID)
        queueVoiceTranscript(
            VoiceTranscriptSaveRequest(
                callID: transcript.callUUID,
                engine: transcript.engine.flatMap(VoiceCallEngine.watchBridge) ?? .geminiLive,
                sessionID: nil,
                title: Self.fallbackVoiceCallTitle(at: transcript.startedAt),
                turns: turns
            ),
            dashboard: dashboard,
            profile: profile,
            jobs: jobSessions
        )
        // Only the active dashboard's outbox drains; another's waits until
        // it's active again, as the phone's own calls do, and keeps the
        // time-stamped title.
        guard dashboard == activeDashboardID?.uuidString ?? "-" else { return }
        let end = beginVoiceTranscriptBackgroundTask()
        defer { end() }
        // Held back from other drains until it has its title.
        voiceTranscriptsSaving.insert(transcript.callUUID)
        let connected = await connectForWatchDirectCall(timeout: .seconds(20))
        // A title from the call's opening, as the phone's calls get; the
        // queued time-stamped one stays if Hermes can't make one.
        if connected, !isLiveVoiceCallActive, dashboard == activeDashboardID?.uuidString ?? "-" {
            if let title = await generatedVoiceCallTitle(turns: turns, profile: profile) {
                retitleQueuedVoiceTranscript(callID: transcript.callUUID, title: title)
            }
        }
        voiceTranscriptsSaving.remove(transcript.callUUID)
        guard connected else { return }
        await drainVoiceTranscriptOutbox(profile: profile, key: voiceHistoryKey(profile: profile))
    }
}
