//
//  WatchDirectBroker.swift
//  Conduit
//
//  The iPhone's part in a Watch call to Gemini Live
//  (designs/apple-watch-voice-direct.md). The Watch runs the session; this
//  side brokers it and runs its tools:
//  - builds the setup a Gemini Live call on this phone gets (instructions,
//    persona, memory, functions, voice) and a single-use token;
//  - fetches a new token for each later connection;
//  - runs the Watch's function calls through the phone's own tool bridge,
//    answering start_job as soon as Hermes takes the job (Grok Live's way),
//    never holding the answer for the job's lifetime;
//  - answers the Watch's polls while jobs run, with each finished job's
//    reply read from its chat (the phone sleeps through the completion
//    events, so the jobs' own news would only point at the chat);
//  - asks Hermes for the call's tool grant, so its lookups reach Hermes
//    through the push relay while the Watch can't reach this phone, and
//    its jobs run there wrist up or down (within the user's job
//    settings), and ends it with the call;
//  - saves the finished call in voice history.
//  A Watch call to GPT-Live (designs/apple-watch-gpt-live.md) goes through
//  the Hermes host's audio bridge instead: this side only builds its
//  briefing as the phone's GPT-Live call would, and asks Hermes for the
//  grant that opens the bridge and carries its jobs. A Watch call to Grok
//  is the two together: the Watch runs it as a Gemini call (this side
//  builds the setup and runs its tools), and xAI's session is on the
//  host, reached through the grant's audio bridge.
//  Each is a short answer to a Watch message, which wakes Conduit in the
//  background; nothing here runs between them.
//
//  A call belongs to the Hermes connection (dashboard and profile) it
//  began on, kept across a restart in WatchDirectCallLedger. Its tokens,
//  tools and polls are answered only while that connection is active; a
//  switch ends the call as it ends the phone's own. Its transcript is
//  saved to that connection whenever it arrives.
//
//  Nothing lasting goes to the Watch: no Hermes password, dashboard
//  session, Gemini API key, relay pairing or Cloudflare Access credential.
//  Only tokens that work for one session, the call's tool grant, the
//  setup, and tool results.
//

import Foundation
import UIKit

@MainActor
final class WatchDirectBroker {
    /// A start_job is answered once Hermes takes the job, or after this
    /// long whatever happens: its news comes with a later poll.
    static let jobStartWait: Duration = .seconds(8)
    /// Any other function call is answered within this long.
    static let toolWait: Duration = .seconds(20)
    /// A start_job's answer while Hermes is still taking the job. Written
    /// for the model, not shown.
    static let jobAccepted = ["status": "accepted", "message": "Hermes is starting the job. Its result will arrive later as a message; don't wait for it."]
    /// A start_job sent again after this phone lost the first one's answer
    /// (Conduit restarted, or the call ended here): Hermes may have the job
    /// already, so it isn't sent twice. Written for the model, not shown.
    static let jobAlreadySent = ["status": "already_sent", "message": "This job was already sent to Hermes before Conduit on the iPhone lost track of it, so it wasn't sent again. If it started, its result arrives in a Hermes chat. Don't start it again unless the user asks."]
    /// Start_job calls kept in memory for their repeats.
    static let jobCallLimit = 32
    /// How long a token, tool or poll waits for a Hermes connection the
    /// phone's suspension dropped.
    static let connectWait: Duration = .seconds(8)
    /// A call not heard from this long is over, whatever its end said.
    static let silenceLimit: TimeInterval = 30 * 60
    /// How long past its last grant's end a quiet call is kept: its Watch
    /// may still use the grant wrist down, through the relay, without a
    /// word to the phone.
    static let grantGrace: TimeInterval = 60
    /// Bytes of a bridge call's start reply as sent, under the Watch
    /// message limit of about 65 KB.
    static let bridgeReplyLimit = 60 * 1024

    private unowned let link: WatchVoiceLink
    private var callID: UInt32?
    /// The running call's voice mode; nil for one adopted after a restart.
    private var callMode: LiveVoiceModeName?
    /// Ends a bridge call whose Watch went quiet once its grant is over.
    private var grantWatchdog: Task<Void, Never>?
    /// Ends a call whose Watch went quiet (its app died, or the Watch did)
    /// once `silenceDeadline` passes, so recovery and grants stop.
    private var silenceWatchdog: Task<Void, Never>?
    /// When the running call's last grant ends.
    private var grantExpiresAt: Date?
    private var bridge: GeminiLiveToolBridge?
    private var preparing: (callID: UInt32, task: Task<WatchVoiceWire.Message, Never>)?
    /// The running call's connection.
    private var connection: WatchDirectConnection?
    private var lastHeardAt = Date.distantPast
    /// Each call's connection, whether it ended, and the start_job calls
    /// sent for it, kept across a restart: a late message from an ended
    /// call must not make it the running call again, and a start_job must
    /// not reach Hermes twice.
    private var ledger = WatchDirectCallLedger()
    /// What the bridge gave after its call's answer had gone (a slow
    /// start_job, or a call queued while the Watch couldn't wait): sent
    /// with the next poll.
    private var lateOutgoing: [GeminiLiveToolBridge.Outgoing] = []
    /// The phone's own tools the running call declared (the calendar,
    /// reminders, alarms and the like), and the voice mode whose consent
    /// each run checks.
    private var hostTools: [VoiceHostTool] = []
    private var hostToolsMode: LiveVoiceModeName?
    /// The phone's jobs each Watch call started, for its saved transcript.
    private var callJobs: [UInt32: [UUID]] = [:]
    /// The tools the running call's grants cover, and the grants it got:
    /// all revoked when it ends.
    private var grantTools: [String] = []
    private var grantIDs: [String] = []
    /// The job tools asked for with them, and the user's job settings as
    /// the call began. Empty once the host refused jobs (an older plugin).
    private var grantJobTools: [String] = []
    /// Asks for live_token with them: a fresh Gemini token Hermes mints
    /// for the Watch through the grant when the call's session breaks with
    /// the iPhone out of reach. False once the host refused it (a plugin
    /// before 0.8).
    private var grantLiveToken = false
    private var directProvider: DirectLiveProvider = .gemini
    private var grantMaxJobs = 0
    private var grantJobOptions: [String: String] = [:]
    /// The names the call's jobs may give the user's profiles.
    private var grantJobProfiles: [WatchVoiceWire.JobProfileName] = []
    private var grantVoiceApprovals = false
    /// The call's grants open the host's audio bridge (a GPT-Live call).
    private var grantAudio = false
    /// The chat of the call from Hermes the grant's answer_call answers.
    private var grantAnswerSessions: [String] = []
    /// Whether answer_call may approve or deny there: the user lets the
    /// Watch answer approvals by voice, and the call's voice may.
    private var grantAnswerApprovals = false
    /// Why the last grant request failed, for a call that can't start
    /// without one.
    private var lastGrantError: String?
    /// Start_job calls by call and id, the newest `jobCallLimit`, ended
    /// calls' too. The Watch sends one again when the link dropped before
    /// its answer came; it gets the first one's answer instead of a second
    /// job.
    private var jobCalls: [String: Task<[GeminiLiveToolBridge.Outgoing], Never>] = [:]
    private var jobCallOrder: [String] = []

    private lazy var grantClient = WatchToolGrantClient.activeDashboard()

    init(link: WatchVoiceLink) {
        self.link = link
        // Calls it can't read would pass for a fresh install: said once.
        if let bytes = ledger.unreadableBytes {
            link.log.note("watchDirectLedgerUnreadable", ["bytes": bytes])
        }
    }

    private var appState: AppState { AppStateRuntimeRegistry.shared.appState }

    func handle(_ message: WatchVoiceWire.Message, reply: (([String: Any]) -> Void)?) {
        func answer(_ message: WatchVoiceWire.Message) { reply?(WatchVoiceWire.encode(message)) }
        // A call from Hermes this phone kept on its headset (#1204): the
        // Watch's call screen controls it, whichever way its start came.
        if let id = message.watchCallID, let ring = message.watchCallRing, HermesNativeCalls.shared.keepsWatchAnswer(ringID: ring) {
            answer(.callOnPhone(callID: id))
            return
        }
        // Started on the Watch before this phone could keep it: it's the
        // Watch's now.
        if let ring = message.watchCallRing { HermesNativeCalls.shared.startedOnWatch(ringID: ring) }
        switch message {
        case .directStart(let id, let version, let ring, let requestedProvider):
            guard version == WatchVoiceWire.version else {
                answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.versionMismatch))
                return
            }
            let provider = requestedProvider ?? .gemini
            if let refusal = consentRefusal(provider == .qwen ? .qwenLive : .geminiLive) {
                answer(.callRefused(callID: id, reason: refusal))
                return
            }
            let end = Self.beginBackgroundTask("conduit.watchDirect.start")
            // Asked again while preparing (the Watch's request timed out):
            // the same answer.
            let task: Task<WatchVoiceWire.Message, Never>
            if let preparing, preparing.callID == id {
                task = preparing.task
            } else {
                task = Task { await self.prepare(id, ring: ring, provider: provider) }
                preparing = (id, task)
            }
            Task {
                let message = await task.value
                answer(message)
                if self.preparing?.callID == id { self.preparing = nil }
                end()
            }
        case .bridgeStart(let id, let version, let engine, let ring):
            guard version == WatchVoiceWire.version else {
                answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.versionMismatch))
                return
            }
            guard engine == WatchAudioBridgeWire.gptLive else {
                answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.versionMismatch))
                return
            }
            if let refusal = consentRefusal(.gptLive) {
                answer(.callRefused(callID: id, reason: refusal))
                return
            }
            let end = Self.beginBackgroundTask("conduit.watchBridge.start")
            let task: Task<WatchVoiceWire.Message, Never>
            if let preparing, preparing.callID == id {
                task = preparing.task
            } else {
                task = Task { await self.prepareBridge(id, engine: engine, ring: ring) }
                preparing = (id, task)
            }
            Task {
                let message = await task.value
                answer(message)
                if self.preparing?.callID == id { self.preparing = nil }
                end()
            }
        case .grokStart(let id, let version, let ring):
            guard version == WatchVoiceWire.version else {
                answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.versionMismatch))
                return
            }
            if let refusal = consentRefusal(.grokLive) {
                answer(.callRefused(callID: id, reason: refusal))
                return
            }
            let end = Self.beginBackgroundTask("conduit.watchGrok.start")
            let task: Task<WatchVoiceWire.Message, Never>
            if let preparing, preparing.callID == id {
                task = preparing.task
            } else {
                task = Task { await self.prepareGrok(id, ring: ring) }
                preparing = (id, task)
            }
            Task {
                let message = await task.value
                answer(message)
                if self.preparing?.callID == id { self.preparing = nil }
                end()
            }
        case .localLiveStart(let id, let version, let ring):
            guard version == WatchVoiceWire.version else {
                answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.versionMismatch))
                return
            }
            let end = Self.beginBackgroundTask("conduit.watchLocalLive.start")
            let task: Task<WatchVoiceWire.Message, Never>
            if let preparing, preparing.callID == id {
                task = preparing.task
            } else {
                task = Task { await self.prepareLocalLive(id, ring: ring) }
                preparing = (id, task)
            }
            Task {
                let message = await task.value
                answer(message)
                if self.preparing?.callID == id { self.preparing = nil }
                end()
            }
        case .directToken(let id):
            heard(id)
            guard onCallsConnection(id) else {
                answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged))
                return
            }
            // Restore the provider before checking consent or minting a token.
            adoptIfKnown(id)
            guard callID == id else {
                answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged))
                return
            }
            let provider = directProvider
            let consentMode: LiveVoiceModeName = provider == .qwen ? .qwenLive : .geminiLive
            if let refusal = consentRefusal(consentMode) {
                answer(.callRefused(callID: id, reason: refusal))
                return
            }
            let end = Self.beginBackgroundTask("conduit.watchDirect.token")
            Task {
                defer { end() }
                let startedAt = Date()
                do {
                    let token = try await self.appState.watchDirectToken(provider: provider)
                    // Minted while the phone switched: not this call's.
                    guard self.onCallsConnection(id) else {
                        answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged))
                        return
                    }
                    // Ended meanwhile (hung up, or the user took back the
                    // provider's consent): the token goes nowhere.
                    if let refusal = self.tokenRefusalAfterMint(id, mode: consentMode) {
                        answer(.callRefused(callID: id, reason: refusal))
                        self.link.log.note("watchDirectToken", ["ok": false, "dropped": true, "ms": Self.milliseconds(since: startedAt), "appState": WatchVoiceLink.appStateName])
                        return
                    }
                    answer(.directTokenIssued(callID: id, token: .init(token)))
                    self.link.log.note("watchDirectToken", ["ok": true, "ms": Self.milliseconds(since: startedAt), "appState": WatchVoiceLink.appStateName])
                } catch {
                    answer(.callRefused(callID: id, reason: UserFacingError.message(for: error)))
                    self.link.log.note("watchDirectToken", ["ok": false, "error": error.localizedDescription, "appState": WatchVoiceLink.appStateName])
                }
            }
        case .directTool(let id, let call):
            heard(id)
            let end = Self.beginBackgroundTask("conduit.watchDirect.tool")
            Task {
                defer { end() }
                let result = await self.runTool(call, callID: id, waiting: reply != nil)
                answer(.directToolResult(callID: id, result: result))
            }
        case .directToolCancel(let id, let ids):
            heard(id)
            if id == callID { bridge?.cancelCalls(ids) }
            reply?([:])
        case .directPoll(let id):
            heard(id)
            let end = Self.beginBackgroundTask("conduit.watchDirect.poll")
            Task {
                defer { end() }
                answer(.directToolResult(callID: id, result: await self.poll(id)))
            }
        case .directEnd(let id, let transcript):
            reply?([:])
            ended(id, transcript: transcript)
        case .directGrant(let id, let carryJobsFrom):
            heard(id)
            let end = Self.beginBackgroundTask("conduit.watchDirect.grant")
            Task {
                defer { end() }
                answer(await self.renewGrant(id, carryJobsFrom: carryJobsFrom))
            }
        default:
            reply?([:])
        }
    }

    // MARK: Start

    /// Why a call can't start until the user allows its provider to hear
    /// them (#827), or nil. The phone asks on its own sheet meanwhile.
    private func consentRefusal(_ mode: LiveVoiceModeName) -> String? {
        appState.requestLiveVoiceConsentIfMissing(mode).map { VoiceSetupIssue.providerConsentNeeded($0).message }
    }

    /// Why a token minted for call `id` must not reach the Watch after
    /// all: the user withdrew `mode`'s consent while the mint was in
    /// flight, the call is no longer the running one, or its ledger record
    /// ended. Nil when it may go. Reads consent without asking again.
    private func tokenRefusalAfterMint(_ id: UInt32, mode: LiveVoiceModeName) -> String? {
        Self.tokenRefusalAfterMint(
            id,
            running: callID,
            ledgerEnded: ledger.call(id)?.ended,
            consentMissing: LiveVoiceProviderConsent.missing(mode)
        )
    }

    static func tokenRefusalAfterMint(_ id: UInt32, running: UInt32?, ledgerEnded: Bool?, consentMissing: LiveVoiceModeName?) -> String? {
        if let consentMissing { return VoiceSetupIssue.providerConsentNeeded(consentMissing).message }
        guard running == id, ledgerEnded != true else { return WatchVoiceStartFailure.ended }
        return nil
    }

    private func prepare(_ id: UInt32, ring: String? = nil, provider: DirectLiveProvider = .gemini) async -> WatchVoiceWire.Message {
        let appState = self.appState
        if let active = callID, active != id { endCall() }
        callID = id
        callMode = provider == .qwen ? .qwenLive : .geminiLive
        bridge = nil
        lateOutgoing = []
        hostTools = []
        hostToolsMode = nil
        appState.watchCallUserTurn = nil
        grantExpiresAt = nil
        lastHeardAt = Date()
        watchSilence(id)
        // Lets transport recovery run with the phone locked, as for a
        // CarPlay call.
        appState.setWatchVoiceCallActive(true)
        appState.voiceBackgroundJobSupervisor.readsRepliesWhenSettling = true
        directProvider = provider
        let startedAt = Date()
        link.log.note("watchDirectStart", [
            "callID": Int(id),
            "answersHermesCall": ring != nil,
            "appState": WatchVoiceLink.appStateName,
            "phoneScreen": PhoneScenePresence.isInForeground,
            "connected": appState.isConnected,
        ])
        do {
            let plan = try await appState.prepareWatchDirectCall(answering: ring.flatMap { HermesNativeCalls.shared.answeredOnWatch(ringID: $0) }, provider: provider)
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            connection = plan.connection
            ledger.begin(id, connection: plan.connection, saveCalls: plan.saveCalls, mode: callMode)
            // Only the lookups and job tools the call declares, jobs only
            // as the user allows; the call goes on without a grant when the
            // host can't give one.
            let declared = plan.functions.map(\.name)
            grantTools = grantable(declared.filter { WatchToolAnswer.tools.contains($0) })
            // The user's answer to the call from Hermes goes to the host.
            grantAnswerSessions = plan.answerSessions
            grantAnswerApprovals = WatchJobSettings.voiceApprovals
            if !plan.answerSessions.isEmpty { grantTools.append(WatchCallAnswer.tool) }
            grantMaxJobs = WatchJobSettings.jobsPerCall
            grantJobTools = grantMaxJobs > 0 ? declared.filter { WatchJobAnswer.tools.contains($0) } : []
            grantJobOptions = plan.jobOptions
            grantJobProfiles = plan.jobProfiles
            grantVoiceApprovals = WatchJobSettings.voiceApprovals
            grantLiveToken = true
            grantAudio = false
            let grant = await requestGrant(id, profile: plan.connection.profile)
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            ledger.setGrant(grantScope, for: id)
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            // The model answers approvals only when the user allowed it and
            // the grant carries jobs.
            var functions = plan.functions
            // A call from Hermes about an approval declares answer_approval
            // already: one declaration serves it and the jobs' approvals.
            if grant?.voiceApprovals == true, !functions.contains(where: { $0.name == WatchJobAnswer.answerApproval }) {
                functions.append(WatchJobAnswer.answerApprovalDeclaration)
            }
            // With the phone's own tools when the start still fits a Watch
            // message; without them the call goes on as before.
            var chosen: (session: WatchVoiceWire.DirectSession, packed: (data: Data, bytes: Int))?
            for tools in Self.hostToolChoices(plan.hostTools) {
                let declared = functions + VoiceHostTool.declarations(tools)
                let instruction = tools.isEmpty ? plan.systemInstruction : plan.systemInstruction + plan.hostToolsBriefing
                let setup = WatchVoiceWire.DirectSetup(systemInstruction: instruction, functions: declared)
                guard setup.functions.count == declared.count, let attempt = setup.compressed() else { continue }
                let built = WatchVoiceWire.DirectSession(
                    token: .init(plan.token),
                    setup: attempt.data,
                    setupBytes: attempt.bytes,
                    googleSearch: plan.googleSearch,
                    voice: plan.voice,
                    openingPrompt: plan.openingPrompt,
                    toolGrant: grant,
                    endPhrases: plan.endPhrases
                )
                if !tools.isEmpty, !Self.fitsWatchMessage(.directSession(callID: id, session: built)) { continue }
                chosen = (built, attempt)
                functions = declared
                hostTools = tools
                hostToolsMode = provider == .qwen ? .qwenLive : .geminiLive
                break
            }
            guard let picked = chosen else {
                throw WatchDirectPrepareError(AppLocalization.string("The call's setup couldn't be packed for the Watch."))
            }
            let (session, packed) = picked
            link.log.note("watchDirectPrepared", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "setupBytes": packed.bytes,
                "compressedBytes": packed.data.count,
                "functions": functions.map(\.name),
                "hostTools": hostTools.count,
                "googleSearch": plan.googleSearch,
                "memory": plan.memoryIncluded,
                "personality": plan.personalityIncluded,
                "toolGrant": grant != nil,
                "appState": WatchVoiceLink.appStateName,
            ])
            return .directSession(callID: id, session: session)
        } catch {
            let reason = (error as? WatchDirectPrepareError)?.reason ?? UserFacingError.message(for: error)
            link.log.note("watchDirectPrepareFailed", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "error": reason,
                "appState": WatchVoiceLink.appStateName,
            ])
            if callID == id { endCall() }
            return .callRefused(callID: id, reason: reason)
        }
    }

    // MARK: Start through the audio bridge

    /// How long a start waits for Hermes to make GPT-Live's WebRTC runtime:
    /// about 5 s once its packages are cached, minutes the first time. Short,
    /// so the start's answer reaches the Watch within the background time a
    /// Watch message gives Conduit; a longer make is refused with "try again
    /// shortly", and the next start finds it ready.
    static let runtimeWait: TimeInterval = 8

    /// A GPT-Live call on the Watch: the phone's briefing, and a grant that
    /// opens the host's audio bridge, with jobs for GPT-Live's delegations
    /// as the user allows and web_search for when they don't. Nothing else
    /// runs here until the call ends.
    private func prepareBridge(_ id: UInt32, engine: String, ring: String? = nil) async -> WatchVoiceWire.Message {
        let appState = self.appState
        if let active = callID, active != id { endCall() }
        callID = id
        callMode = .gptLive
        bridge = nil
        lateOutgoing = []
        hostTools = []
        hostToolsMode = nil
        appState.watchCallUserTurn = nil
        grantExpiresAt = nil
        lastHeardAt = Date()
        watchSilence(id)
        appState.setWatchVoiceCallActive(true)
        let startedAt = Date()
        link.log.note("watchBridgeStart", [
            "callID": Int(id),
            "answersHermesCall": ring != nil,
            "engine": engine,
            "appState": WatchVoiceLink.appStateName,
            "phoneScreen": PhoneScenePresence.isInForeground,
            "connected": appState.isConnected,
        ])
        do {
            let plan = try await appState.prepareWatchBridgeCall(answering: ring.flatMap { HermesNativeCalls.shared.answeredOnWatch(ringID: $0) })
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            connection = plan.connection
            ledger.begin(id, connection: plan.connection, saveCalls: plan.saveCalls, mode: callMode)
            // GPT-Live delegates its lookups and chats to the Watch, which
            // runs them all through the grant.
            grantTools = grantable([WatchToolAnswer.webSearch] + WatchToolAnswer.chatTools.sorted())
            // "Answer:", "Approve:" and "Deny:" for the call from Hermes.
            grantAnswerSessions = plan.answerSessions
            // GPT-Live never approves on the Watch: the user taps.
            grantAnswerApprovals = false
            if !plan.answerSessions.isEmpty { grantTools.append(WatchCallAnswer.tool) }
            grantMaxJobs = WatchJobSettings.jobsPerCall
            grantJobTools = grantMaxJobs > 0 ? WatchJobAnswer.tools.sorted() : []
            grantJobOptions = plan.jobOptions
            grantJobProfiles = plan.jobProfiles
            // GPT-Live never answers a job's approval: the user taps it.
            grantVoiceApprovals = false
            grantLiveToken = false
            grantAudio = true
            lastGrantError = nil
            let grant = await requestGrant(id, profile: plan.connection.profile)
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            ledger.setGrant(grantScope, for: id)
            guard let grant, let audio = grant.audio else {
                throw WatchDirectPrepareError(lastGrantError.map { AppLocalization.string("Hermes couldn't open GPT-Live for the Watch: \($0)") }
                    ?? AppLocalization.string("Hermes couldn't open GPT-Live for the Watch. Update the Conduit notifier plugin and the push relay."))
            }
            if !audio.engines.contains(engine) {
                try await prepareRuntime(id, profile: plan.connection.profile)
                guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            guard let packed = WatchVoiceWire.BridgeSession.pack(plan.briefing) else {
                throw WatchDirectPrepareError(AppLocalization.string("The call's briefing couldn't be packed for the Watch."))
            }
            let reply = WatchVoiceWire.Message.bridgeSession(callID: id, session: .init(
                engine: engine,
                grant: grant,
                briefing: packed.data,
                briefingBytes: packed.bytes,
                greeting: plan.greeting,
                voice: plan.voice,
                endPhrases: plan.endPhrases,
                openingTurn: plan.openingTurn
            ))
            // The reply travels in one Watch message, which carries about
            // 65 KB as sent (the briefing as base64 in JSON).
            guard let replyBytes = (WatchVoiceWire.encode(reply)[WatchVoiceWire.messageKey] as? Data)?.count else {
                throw WatchDirectPrepareError(AppLocalization.string("The call's briefing couldn't be packed for the Watch."))
            }
            guard replyBytes <= Self.bridgeReplyLimit else {
                throw WatchDirectPrepareError(AppLocalization.string("The call's briefing (memory and persona) is too large to send to the Watch."))
            }
            link.log.note("watchBridgePrepared", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "briefingBytes": packed.bytes,
                "compressedBytes": packed.data.count,
                "replyBytes": replyBytes,
                "tools": grant.tools,
                "engines": audio.engines,
                "memory": plan.memoryIncluded,
                "personality": plan.personalityIncluded,
                "appState": WatchVoiceLink.appStateName,
            ])
            endWhenGrantDoes(id, expiresAt: grant.expiresAt)
            return reply
        } catch {
            let reason = (error as? WatchDirectPrepareError)?.reason ?? UserFacingError.message(for: error)
            link.log.note("watchBridgePrepareFailed", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "error": reason,
                "appState": WatchVoiceLink.appStateName,
            ])
            if callID == id { endCall() }
            return .callRefused(callID: id, reason: reason)
        }
    }

    // MARK: Start for Grok

    /// A Grok call on the Watch: the setup the phone's Grok Live call gets,
    /// and a grant that opens the host's audio bridge (xAI's session, on
    /// the host's sign-in) and carries the call's lookups and jobs. The
    /// Watch runs the conversation as it runs Gemini's, so its tools and
    /// polls come here as a Gemini call's do.
    private func prepareGrok(_ id: UInt32, ring: String? = nil) async -> WatchVoiceWire.Message {
        let appState = self.appState
        if let active = callID, active != id { endCall() }
        callID = id
        callMode = .grokLive
        bridge = nil
        lateOutgoing = []
        hostTools = []
        hostToolsMode = nil
        appState.watchCallUserTurn = nil
        grantExpiresAt = nil
        lastHeardAt = Date()
        watchSilence(id)
        appState.setWatchVoiceCallActive(true)
        appState.voiceBackgroundJobSupervisor.readsRepliesWhenSettling = true
        let startedAt = Date()
        link.log.note("watchGrokStart", [
            "callID": Int(id),
            "answersHermesCall": ring != nil,
            "appState": WatchVoiceLink.appStateName,
            "phoneScreen": PhoneScenePresence.isInForeground,
            "connected": appState.isConnected,
        ])
        do {
            let plan = try await appState.prepareWatchGrokCall(answering: ring.flatMap { HermesNativeCalls.shared.answeredOnWatch(ringID: $0) })
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            connection = plan.connection
            ledger.begin(id, connection: plan.connection, saveCalls: plan.saveCalls, mode: callMode)
            let declared = plan.functions.map(\.name)
            grantTools = grantable(declared.filter { WatchToolAnswer.tools.contains($0) })
            grantAnswerSessions = plan.answerSessions
            grantAnswerApprovals = WatchJobSettings.voiceApprovals
            if !plan.answerSessions.isEmpty { grantTools.append(WatchCallAnswer.tool) }
            grantMaxJobs = WatchJobSettings.jobsPerCall
            grantJobTools = grantMaxJobs > 0 ? declared.filter { WatchJobAnswer.tools.contains($0) } : []
            grantJobOptions = plan.jobOptions
            grantJobProfiles = plan.jobProfiles
            grantVoiceApprovals = WatchJobSettings.voiceApprovals
            grantLiveToken = false
            grantAudio = true
            lastGrantError = nil
            let grant = await requestGrant(id, profile: plan.connection.profile)
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            ledger.setGrant(grantScope, for: id)
            guard let grant, let audio = grant.audio, audio.engines.contains(WatchAudioBridgeWire.grok) else {
                throw WatchDirectPrepareError(lastGrantError.map { AppLocalization.string("Hermes couldn't open Grok for the Watch: \($0)") }
                    ?? AppLocalization.string("Hermes couldn't open Grok for the Watch. Update the Conduit notifier plugin and the push relay."))
            }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            var functions = plan.functions
            if grant.voiceApprovals == true, !functions.contains(where: { $0.name == WatchJobAnswer.answerApproval }) {
                functions.append(WatchJobAnswer.answerApprovalDeclaration)
            }
            // With the phone's own tools when the reply still fits; without
            // them the call goes on as before.
            var chosen: (reply: WatchVoiceWire.Message, packed: (data: Data, bytes: Int), replyBytes: Int)?
            for tools in Self.hostToolChoices(plan.hostTools) {
                let declared = functions + VoiceHostTool.declarations(tools)
                let instruction = tools.isEmpty ? plan.systemInstruction : plan.systemInstruction + plan.hostToolsBriefing
                let setup = WatchVoiceWire.DirectSetup(systemInstruction: instruction, functions: declared)
                guard setup.functions.count == declared.count, let packed = setup.compressed() else {
                    if tools.isEmpty { throw WatchDirectPrepareError(AppLocalization.string("The call's setup couldn't be packed for the Watch.")) }
                    continue
                }
                let reply = WatchVoiceWire.Message.grokSession(callID: id, session: .init(
                    setup: packed.data,
                    setupBytes: packed.bytes,
                    voice: plan.voice,
                    openingPrompt: plan.openingPrompt,
                    grant: grant,
                    endPhrases: plan.endPhrases
                ))
                guard let replyBytes = Self.messageBytes(reply) else {
                    if tools.isEmpty { throw WatchDirectPrepareError(AppLocalization.string("The call's setup couldn't be packed for the Watch.")) }
                    continue
                }
                guard replyBytes <= Self.bridgeReplyLimit else {
                    if tools.isEmpty { throw WatchDirectPrepareError(AppLocalization.string("The call's briefing (memory and persona) is too large to send to the Watch.")) }
                    continue
                }
                chosen = (reply, packed, replyBytes)
                functions = declared
                hostTools = tools
                hostToolsMode = .grokLive
                break
            }
            guard let picked = chosen else {
                throw WatchDirectPrepareError(AppLocalization.string("The call's setup couldn't be packed for the Watch."))
            }
            let (reply, packed, replyBytes) = picked
            link.log.note("watchGrokPrepared", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "setupBytes": packed.bytes,
                "compressedBytes": packed.data.count,
                "replyBytes": replyBytes,
                "functions": functions.map(\.name),
                "hostTools": hostTools.count,
                "tools": grant.tools,
                "engines": audio.engines,
                "memory": plan.memoryIncluded,
                "personality": plan.personalityIncluded,
                "appState": WatchVoiceLink.appStateName,
            ])
            endWhenGrantDoes(id, expiresAt: grant.expiresAt)
            return reply
        } catch {
            let reason = (error as? WatchDirectPrepareError)?.reason ?? UserFacingError.message(for: error)
            link.log.note("watchGrokPrepareFailed", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "error": reason,
                "appState": WatchVoiceLink.appStateName,
            ])
            if callID == id { endCall() }
            return .callRefused(callID: id, reason: reason)
        }
    }

    // MARK: Start for Local Live

    /// A Local Live call on the Watch: a grant that opens the host's audio
    /// bridge, where the host relays the Watch's session to the profile's
    /// speech server and runs the server's turns in a Hermes chat, as the
    /// phone's Local Live call runs them. The grant needs a tool; the call
    /// never uses it.
    private func prepareLocalLive(_ id: UInt32, ring: String? = nil) async -> WatchVoiceWire.Message {
        let appState = self.appState
        if let active = callID, active != id { endCall() }
        callID = id
        callMode = .localLive
        bridge = nil
        lateOutgoing = []
        hostTools = []
        hostToolsMode = nil
        appState.watchCallUserTurn = nil
        grantExpiresAt = nil
        lastHeardAt = Date()
        watchSilence(id)
        appState.setWatchVoiceCallActive(true)
        let startedAt = Date()
        link.log.note("watchLocalLiveStart", [
            "callID": Int(id),
            "answersHermesCall": ring != nil,
            "appState": WatchVoiceLink.appStateName,
            "phoneScreen": PhoneScenePresence.isInForeground,
            "connected": appState.isConnected,
        ])
        do {
            let plan = try await appState.prepareWatchLocalLiveCall(answering: ring.flatMap { HermesNativeCalls.shared.answeredOnWatch(ringID: $0) })
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            connection = plan.connection
            ledger.begin(id, connection: plan.connection, saveCalls: plan.saveCalls, mode: callMode)
            grantTools = grantable([WatchToolAnswer.webSearch])
            // The user's words answer the call from Hermes on the host.
            grantAnswerSessions = plan.answerSessions
            grantAnswerApprovals = WatchJobSettings.voiceApprovals
            if !plan.answerSessions.isEmpty { grantTools.append(WatchCallAnswer.tool) }
            grantMaxJobs = 0
            grantJobTools = []
            grantJobOptions = [:]
            grantJobProfiles = []
            grantVoiceApprovals = false
            grantLiveToken = false
            grantAudio = true
            lastGrantError = nil
            let grant = await requestGrant(id, profile: plan.connection.profile)
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            ledger.setGrant(grantScope, for: id)
            guard let grant, let audio = grant.audio, audio.engines.contains(WatchAudioBridgeWire.localLive) else {
                throw WatchDirectPrepareError(lastGrantError.map { AppLocalization.string("Hermes couldn't open Local Live for the Watch: \($0)") }
                    ?? AppLocalization.string("Hermes couldn't open Local Live for the Watch. Update the Conduit notifier plugin and the push relay."))
            }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            let reply = WatchVoiceWire.Message.localLiveSession(callID: id, call: .init(
                grant: grant,
                greeting: plan.greeting,
                endPhrases: plan.endPhrases
            ))
            link.log.note("watchLocalLivePrepared", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "greeting": plan.greeting != nil,
                "engines": audio.engines,
                "appState": WatchVoiceLink.appStateName,
            ])
            endWhenGrantDoes(id, expiresAt: grant.expiresAt)
            return reply
        } catch {
            let reason = (error as? WatchDirectPrepareError)?.reason ?? UserFacingError.message(for: error)
            link.log.note("watchLocalLivePrepareFailed", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "error": reason,
                "appState": WatchVoiceLink.appStateName,
            ])
            if callID == id { endCall() }
            return .callRefused(callID: id, reason: reason)
        }
    }

    /// A bridge call can't outlive its grant: the relay closes the bridge
    /// when the grant ends. If the Watch's end never arrives (its app was
    /// killed), the call ends here a minute later, so the phone stops
    /// keeping recovery running for it. An end that comes later still saves.
    private func endWhenGrantDoes(_ id: UInt32, expiresAt: Date?) {
        let at = expiresAt ?? Date().addingTimeInterval(Self.silenceLimit)
        let wait = max(0, at.timeIntervalSinceNow) + 60
        grantWatchdog?.cancel()
        grantWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self, self.callID == id else { return }
            self.link.log.note("watchBridgeOutlivedGrant", ["callID": Int(id)])
            self.endCall()
        }
    }

    /// Asks Hermes to make GPT-Live's WebRTC runtime (the plugin's own
    /// small environment) and waits for it a little; a start that can't
    /// wait longer is refused, and the next one finds it ready.
    private func prepareRuntime(_ id: UInt32, profile: String) async throws {
        let startedAt = Date()
        var status = try await grantClient.prepareAudio(profile: profile)
        while status.runtime == "preparing", Date().timeIntervalSince(startedAt) < Self.runtimeWait, callID == id {
            try await Task.sleep(for: .seconds(2))
            status = try await grantClient.audioStatus(profile: profile)
        }
        link.log.note("watchBridgeRuntime", [
            "callID": Int(id),
            "runtime": status.runtime,
            "ms": Self.milliseconds(since: startedAt),
        ])
        switch status.runtime {
        case "ready":
            return
        case "preparing":
            throw WatchDirectPrepareError(AppLocalization.string("Hermes is setting up GPT-Live for the Watch, which takes a few minutes the first time. Try again shortly."))
        default:
            throw WatchDirectPrepareError(status.reason ?? AppLocalization.string("Hermes couldn't set up GPT-Live for the Watch."))
        }
    }

    // MARK: Tools

    /// The bridge for the Watch's call, made again if Conduit restarted
    /// since the call began. A call that has ended (a job it queued
    /// arriving late) gets one of its own, so the running call is left
    /// alone. Only asked for a call on the active connection.
    private func bridge(for id: UInt32) -> GeminiLiveToolBridge {
        adoptIfKnown(id)
        guard callID == id else { return makeBridge(for: id) }
        if let bridge { return bridge }
        let bridge = makeBridge(for: id)
        self.bridge = bridge
        return bridge
    }

    private func makeBridge(for id: UInt32) -> GeminiLiveToolBridge {
        let tokens = appState.geminiLiveTokenClient
        let supervisor = WatchCallJobSupervisor(appState.voiceBackgroundJobSupervisor)
        // Noted in the saved call, as the phone's own calls note theirs.
        supervisor.onJobCreated = { [weak self] jobID in self?.callJobs[id, default: []].append(jobID) }
        supervisor.callIsLive = { [weak self] in self?.callID == id }
        // Only the running call's: a straggler from an ended one gets none.
        if callID == id, let mode = hostToolsMode {
            supervisor.hostTools = hostTools
            supervisor.runHostTool = { [weak appState] tool, arguments in
                await appState?.callVoiceHostTool(tool, arguments: arguments, mode: mode)
                    ?? ["error": "That isn't available on this call."]
            }
        }
        // Answered once each job runs, its outcome later as a text update:
        // a Watch message's answer can't stay open for a job.
        return GeminiLiveToolBridge(
            supervisor: supervisor,
            webSearch: tokens,
            memory: tokens,
            holdsJobCalls: false,
            opensChats: false
        )
    }

    private func runTool(_ call: WatchVoiceWire.DirectToolCall, callID id: UInt32, waiting: Bool) async -> WatchVoiceWire.DirectToolResult {
        guard onCallsConnection(id) else { return refused(call, waiting: waiting) }
        let bridge = bridge(for: id)
        let startedAt = Date()
        let functionCall = GeminiLiveProtocol.FunctionCall(id: call.id, name: call.name, arguments: call.arguments)
        let isJob = call.name == GeminiLiveToolBridge.Tool.startJob.rawValue
        // The user's own words for a change's yes; each turn has its own
        // id, so one yes answers one change.
        if callID == id {
            appState.watchCallUserTurn = call.userWords.map { (id: Self.userTurnID(call: id, turn: call.userTurn ?? 0), text: $0) }
        }
        let jobKey = WatchDirectCallLedger.jobKey(call.id, in: id)
        if isJob, let earlier = jobCalls[jobKey] {
            return await repeatedJobCall(call, earlier: earlier, waiting: waiting, startedAt: startedAt)
        }
        if isJob, ledger.hasSentJob(call.id, in: id) {
            return replayedJobCall(call, waiting: waiting)
        }
        // Both set up before the first wait, so a repeat arriving meanwhile
        // finds this call.
        let connecting = Task { await self.appState.connectForWatchDirectCall(timeout: Self.connectWait) }
        let handled = Task { () -> [GeminiLiveToolBridge.Outgoing] in
            _ = await connecting.value
            // The phone may have switched connections while it waited.
            guard self.onCallsConnection(id) else {
                return [.toolResponse(id: call.id, name: call.name, result: ["error": WatchVoiceStartFailure.connectionChanged], scheduling: nil), .endConversation]
            }
            // From here Hermes may get the job: a later repeat isn't sent.
            if isJob { self.ledger.recordJob(call.id, in: id) }
            return await bridge.handle(functionCall)
        }
        if isJob { rememberJobCall(handled, key: jobKey) }
        let connected = await connecting.value
        guard waiting else {
            // Queued while the Watch couldn't reach this phone: the Watch
            // answered the call itself, and nothing reads this answer. What
            // comes after the call's own answer waits for the next poll.
            let late = await handled.value
            if callID == id { lateOutgoing += lateAnswers(late, to: call, in: id, isJob: isJob) }
            var fields: [String: Any] = [
                "name": call.name,
                "ms": Self.milliseconds(since: startedAt),
                "connected": connected,
                "queued": true,
                "appState": WatchVoiceLink.appStateName,
            ]
            fields.merge(Self.answerSummary(late, answering: call.id)) { first, _ in first }
            link.log.note("watchDirectTool", fields)
            return WatchVoiceWire.DirectToolResult(outgoing: [], runningJobs: appState.voiceBackgroundJobSupervisor.activeJobCount)
        }
        let outgoing: [GeminiLiveToolBridge.Outgoing]
        if let answered = await Self.value(of: handled, within: isJob ? Self.jobStartWait : Self.toolWait) {
            outgoing = answered
            // Refused at once: nothing started, so a repeat may go again.
            if isJob, Self.refusedBeforeStarting(answered, answering: call.id) { ledger.forgetJob(call.id, in: id) }
        } else {
            // Still running: answer now, and keep whatever it gives later
            // except the answer to this call, which went already.
            Task { [weak self] in
                let late = await handled.value
                guard let self, self.callID == id else { return }
                self.lateOutgoing += self.lateAnswers(late, to: call, in: id, isJob: isJob)
            }
            let result: [String: String] = isJob ? Self.jobAccepted : WatchToolAnswer.tookTooLong
            outgoing = [.toolResponse(id: call.id, name: call.name, result: result, scheduling: isJob ? nil : .whenIdle)]
        }
        var fields: [String: Any] = [
            "name": call.name,
            "ms": Self.milliseconds(since: startedAt),
            "connected": connected,
            "queued": false,
            "outgoing": outgoing.count,
            "appState": WatchVoiceLink.appStateName,
        ]
        fields.merge(Self.answerSummary(outgoing, answering: call.id)) { first, _ in first }
        link.log.note("watchDirectTool", fields)
        return result(outgoing, bridge: bridge)
    }

    /// What a call's answer brought after the call was answered without
    /// it, minus that answer, which went already. A start_job Hermes then
    /// refused was answered as accepted: the refusal follows as news, so
    /// the model takes back what it said, and a repeat may be sent again
    /// since nothing started (#1008).
    private func lateAnswers(_ late: [GeminiLiveToolBridge.Outgoing], to call: WatchVoiceWire.DirectToolCall, in id: UInt32, isJob: Bool) -> [GeminiLiveToolBridge.Outgoing] {
        let rest = late.filter { !$0.answers(call.id) }
        guard isJob, let refusal = Self.jobRefusal(in: late, answering: call.id) else { return rest }
        let definite = Self.refusedBeforeStarting(late, answering: call.id)
        if definite { ledger.forgetJob(call.id, in: id) }
        link.log.note("watchDirectLateJobRefusal", ["chars": refusal.count, "definite": definite, "appState": WatchVoiceLink.appStateName])
        return [.textWhenIdle(Self.lateJobRefusalText(refusal, definite: definite))] + rest
    }

    /// The reason in a start_job's answer when the job didn't start; nil
    /// when it did (its answer names the job) or nothing answered it.
    static func jobRefusal(in outgoing: [GeminiLiveToolBridge.Outgoing], answering id: String) -> String? {
        for case .toolResponse(let responseID, _, let result, _) in outgoing where responseID == id {
            guard result["job_id"] == nil else { return nil }
            // The phone left the call's connection before Hermes got the
            // job: not Hermes' refusal, and the call is ending anyway.
            if result["error"] == WatchVoiceStartFailure.connectionChanged { return nil }
            if let error = result["error"], !error.isEmpty { return error }
            guard let status = result["status"], status == "not_started" || status == "not_sent" else { return nil }
            return result["message"] ?? "Hermes didn't take the job."
        }
        return nil
    }

    /// A start_job whose answer says Hermes never took it: its receipt
    /// may go. Any other error might have come after Hermes took the
    /// turn, so a repeat of it still isn't sent.
    static func refusedBeforeStarting(_ outgoing: [GeminiLiveToolBridge.Outgoing], answering id: String) -> Bool {
        for case .toolResponse(let responseID, _, let result, _) in outgoing where responseID == id {
            return result["job_id"] == nil && (result["status"] == "not_started" || result["status"] == "not_sent")
        }
        return false
    }

    /// Written for the model, not shown.
    /// `definite`: Hermes never took it; otherwise an error that may have
    /// come after it did.
    static func lateJobRefusalText(_ reason: String, definite: Bool = true) -> String {
        guard definite else {
            return GeminiLiveToolBridge.relayPrompt("Hermes didn't confirm the job you said it was starting: \(reason) It may not have started; the user can ask you to list their jobs. Don't start it again unless they ask.")
        }
        return GeminiLiveToolBridge.relayPrompt("The job you said Hermes was starting didn't start after all: \(reason) Don't start it again unless the user asks.")
    }

    private func rememberJobCall(_ task: Task<[GeminiLiveToolBridge.Outgoing], Never>, key: String) {
        jobCalls[key] = task
        jobCallOrder.append(key)
        while jobCallOrder.count > Self.jobCallLimit {
            jobCalls[jobCallOrder.removeFirst()] = nil
        }
    }

    /// A call on a connection the phone has left: refused, and the Watch's
    /// call ends, as the phone's own call does at a switch.
    private func refused(_ call: WatchVoiceWire.DirectToolCall, waiting: Bool) -> WatchVoiceWire.DirectToolResult {
        link.log.note("watchDirectTool", ["name": call.name, "connectionChanged": true, "queued": !waiting, "appState": WatchVoiceLink.appStateName])
        guard waiting else { return WatchVoiceWire.DirectToolResult(outgoing: [], runningJobs: 0) }
        let answer = GeminiLiveToolBridge.Outgoing.toolResponse(id: call.id, name: call.name, result: ["error": WatchVoiceStartFailure.connectionChanged], scheduling: nil)
        return WatchVoiceWire.DirectToolResult(outgoing: [Self.wire(answer), .endConversation], runningJobs: 0)
    }

    /// A start_job this phone sent toward Hermes before it lost the first
    /// one's answer (Conduit restarted, or the call ended here): Hermes may
    /// have the job, so it isn't sent again.
    private func replayedJobCall(_ call: WatchVoiceWire.DirectToolCall, waiting: Bool) -> WatchVoiceWire.DirectToolResult {
        let runningJobs = appState.voiceBackgroundJobSupervisor.activeJobCount
        link.log.note("watchDirectTool", ["name": call.name, "replay": true, "queued": !waiting, "appState": WatchVoiceLink.appStateName])
        guard waiting else { return WatchVoiceWire.DirectToolResult(outgoing: [], runningJobs: runningJobs) }
        let answer = GeminiLiveToolBridge.Outgoing.toolResponse(id: call.id, name: call.name, result: Self.jobAlreadySent, scheduling: nil)
        return WatchVoiceWire.DirectToolResult(outgoing: [Self.wire(answer)], runningJobs: runningJobs)
    }

    /// A start_job sent again: the first one's answer, nothing started.
    /// What came after that answer went with the first call already.
    private func repeatedJobCall(
        _ call: WatchVoiceWire.DirectToolCall,
        earlier: Task<[GeminiLiveToolBridge.Outgoing], Never>,
        waiting: Bool,
        startedAt: Date
    ) async -> WatchVoiceWire.DirectToolResult {
        let runningJobs = appState.voiceBackgroundJobSupervisor.activeJobCount
        guard waiting else {
            link.log.note("watchDirectTool", ["name": call.name, "repeat": true, "queued": true, "appState": WatchVoiceLink.appStateName])
            return WatchVoiceWire.DirectToolResult(outgoing: [], runningJobs: runningJobs)
        }
        let answer = (await Self.value(of: earlier, within: Self.jobStartWait) ?? []).filter { $0.answers(call.id) }
        let outgoing: [GeminiLiveToolBridge.Outgoing] = answer.isEmpty
            ? [.toolResponse(id: call.id, name: call.name, result: Self.jobAccepted, scheduling: nil)]
            : answer
        var fields: [String: Any] = [
            "name": call.name,
            "repeat": true,
            "ms": Self.milliseconds(since: startedAt),
            "queued": false,
            "appState": WatchVoiceLink.appStateName,
        ]
        fields.merge(Self.answerSummary(outgoing, answering: call.id)) { first, _ in first }
        link.log.note("watchDirectTool", fields)
        return WatchVoiceWire.DirectToolResult(outgoing: outgoing.map { Self.wire($0) }, runningJobs: runningJobs)
    }

    /// What the answer to `id` said, for the test log: its keys, its size
    /// and its error, never the results themselves.
    private static func answerSummary(_ outgoing: [GeminiLiveToolBridge.Outgoing], answering id: String) -> [String: Any] {
        for case .toolResponse(let responseID, _, let result, _) in outgoing where responseID == id {
            var fields: [String: Any] = [
                "resultKeys": result.keys.sorted(),
                "resultChars": result.values.reduce(0) { $0 + $1.count },
            ]
            if let error = result["error"] { fields["resultError"] = String(error.prefix(160)) }
            if let status = result["status"] { fields["resultStatus"] = status }
            return fields
        }
        return ["answered": false]
    }

    private func poll(_ id: UInt32) async -> WatchVoiceWire.DirectToolResult {
        // The supervisor's jobs are another connection's now.
        guard onCallsConnection(id) else { return WatchVoiceWire.DirectToolResult(outgoing: [.endConversation], runningJobs: 0) }
        adoptIfKnown(id)
        // An ended call's poll would take the running call's news.
        if callID != id {
            return WatchVoiceWire.DirectToolResult(outgoing: [], runningJobs: appState.voiceBackgroundJobSupervisor.activeJobCount)
        }
        let bridge = bridge(for: id)
        let supervisor = appState.voiceBackgroundJobSupervisor
        if await appState.connectForWatchDirectCall(timeout: Self.connectWait) {
            // Settles jobs whose completion the stream missed while Conduit
            // was suspended.
            await supervisor.pollOnce()
        }
        guard onCallsConnection(id) else { return WatchVoiceWire.DirectToolResult(outgoing: [.endConversation], runningJobs: 0) }
        let updates = bridge.pendingUpdates()
        // Job news sizes only, for the test log: a pointer to the chat is
        // a sentence, a result is its reply.
        let news = updates.compactMap { item -> Int? in
            if case .textWhenIdle(let text) = item { return text.count }
            return nil
        }
        if !news.isEmpty {
            link.log.note("watchDirectPoll", ["news": news.count, "newsChars": news, "appState": WatchVoiceLink.appStateName])
        }
        return result(updates, bridge: bridge)
    }

    /// What goes back to the Watch, with any late answers first. Handing
    /// them over counts as delivered, as a socket send does on the phone.
    private func result(_ outgoing: [GeminiLiveToolBridge.Outgoing], bridge: GeminiLiveToolBridge) -> WatchVoiceWire.DirectToolResult {
        // The late answers belong to the running call's bridge.
        let late = bridge === self.bridge ? lateOutgoing : []
        if bridge === self.bridge { lateOutgoing = [] }
        let items = late + outgoing
        let supervisor = appState.voiceBackgroundJobSupervisor
        var newsJobs: [WatchVoiceWire.DirectNewsJob] = []
        for item in items {
            switch item {
            case .toolResponse(_, _, let result, _):
                bridge.outcomeSent(jobID: GeminiLiveConversationController.jobID(of: result))
            case .textWhenIdle(let text):
                let jobID = bridge.textUpdateSending(text)
                // The Watch lists a settled job until its model says it.
                if let jobID, let job = supervisor.jobs.first(where: { $0.id == jobID }), !job.status.isActive {
                    newsJobs.append(.init(text: text, jobID: jobID.uuidString, title: job.title, status: GeminiLiveToolBridge.statusName(job.status)))
                }
                bridge.textUpdateDelivered(jobID: jobID)
            case .contextWhenIdle, .endConversation:
                break
            }
        }
        return WatchVoiceWire.DirectToolResult(
            outgoing: items.map { Self.wire($0) },
            runningJobs: supervisor.activeJobCount,
            newsJobs: newsJobs.isEmpty ? nil : newsJobs
        )
    }

    static func wire(_ item: GeminiLiveToolBridge.Outgoing) -> WatchVoiceWire.DirectOutgoing {
        switch item {
        case .toolResponse(let id, let name, let result, let scheduling):
            // What the phone's call says instead when the call is gone.
            let fallback = scheduling == .silent ? nil : GeminiLiveConversationController.fallbackText(for: result, name: name)
            return .toolResponse(id: id, name: name, result: result, scheduling: scheduling?.rawValue, fallback: fallback)
        case .textWhenIdle(let text):
            return .textWhenIdle(text)
        case .contextWhenIdle(let text):
            return .contextWhenIdle(text)
        case .endConversation:
            return .endConversation
        }
    }

    // MARK: Tool grant

    /// A grant for the running call's lookups, jobs and Gemini tokens; nil
    /// when the host can't give one. A host that refuses jobs (a plugin
    /// before 0.7) is asked again for the lookups alone. A renewal names
    /// the grant whose jobs move to the new one. The log has its outcome
    /// and limits, never its keys.
    private func requestGrant(_ id: UInt32, profile: String, carryJobsFrom: String? = nil) async -> WatchVoiceWire.DirectToolGrant? {
        if !grantJobTools.isEmpty {
            let withJobs = await requestGrantWithToken(id, profile: profile, withJobs: true, carryJobsFrom: carryJobsFrom)
            if case .success(let grant) = withJobs { return grant }
            guard callID == id, !grantTools.isEmpty || grantLiveToken || grantAudio else { return nil }
            // A plugin before 0.7 refuses job tools (400): renewals stop
            // asking. A timeout or a 5xx only costs this grant its jobs.
            if case .failure(let error) = withJobs, Self.isRefusedTool(error) { grantJobTools = [] }
        }
        guard !grantTools.isEmpty || grantLiveToken || grantAudio else { return nil }
        return try? await requestGrantWithToken(id, profile: profile, withJobs: false, carryJobsFrom: nil).get()
    }

    /// Asks with live_token while the host takes it. A plugin before 0.8
    /// refuses a tool it doesn't know (400): asked again without it, and
    /// this call's later grants leave it out.
    /// A plugin before 0.18 refuses the chat tools (400) the same way: asked
    /// again without them first, and this call's later grants leave them out.
    private func requestGrantWithToken(_ id: UInt32, profile: String, withJobs: Bool, carryJobsFrom: String?) async -> Result<WatchVoiceWire.DirectToolGrant, Error> {
        let asked = grantLiveToken
        var first = await requestGrant(id, profile: profile, withJobs: withJobs, liveToken: asked, carryJobsFrom: carryJobsFrom)
        if case .failure(let error) = first, callID == id, Self.isRefusedChatTool(error),
           grantTools.contains(where: { WatchToolAnswer.chatTools.contains($0) }) {
            grantTools.removeAll { WatchToolAnswer.chatTools.contains($0) }
            guard !grantTools.isEmpty || asked || (withJobs && !grantJobTools.isEmpty) || grantAudio else { return first }
            first = await requestGrant(id, profile: profile, withJobs: withJobs, liveToken: asked, carryJobsFrom: carryJobsFrom)
        }
        guard case .failure(let error) = first, asked, callID == id, Self.isRefusedTool(error) else { return first }
        grantLiveToken = false
        guard !grantTools.isEmpty || (withJobs && !grantJobTools.isEmpty) else { return first }
        return await requestGrant(id, profile: profile, withJobs: withJobs, liveToken: false, carryJobsFrom: carryJobsFrom)
    }

    /// The other profiles a grant may name: those that are Hermes profile
    /// names, up to the plugin's cap (WATCH_JOB_MAX_PROFILES); a job for
    /// any other goes through the iPhone.
    static func grantableJobProfiles(_ names: [WatchVoiceWire.JobProfileName]) -> [String] {
        var profiles: [String] = []
        for case let profile? in names.map(\.profile) {
            guard profiles.count < maxGrantJobProfiles else { break }
            if profile.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
               !profiles.contains(where: { $0.caseInsensitiveCompare(profile) == .orderedSame }) {
                profiles.append(profile)
            }
        }
        return profiles
    }

    /// The plugin's WATCH_JOB_MAX_PROFILES (and its name pattern above):
    /// it refuses a longer ask outright, so the two move together.
    static let maxGrantJobProfiles = 32

    /// `tools` less the chat tools when the host's plugin reported its
    /// features without them: it would refuse the whole grant.
    private func grantable(_ tools: [String]) -> [String] {
        guard !appState.notifierPlugin.mightSupport(WatchToolAnswer.chatCapability) else { return tools }
        return tools.filter { !WatchToolAnswer.chatTools.contains($0) }
    }

    /// A plugin before 0.18 refusing the chat tools: its 400 lists what the
    /// Watch can be granted, without them. Any other 400 keeps them.
    static func isRefusedChatTool(_ error: Error) -> Bool {
        guard case DashboardTicketBridgeError.http(let status, let detail) = error, status == 400 else { return false }
        return detail.contains("can only be granted") && !detail.contains(WatchToolAnswer.findChat)
    }

    static func isRefusedTool(_ error: Error) -> Bool {
        if case DashboardTicketBridgeError.http(let status, _) = error, status == 400 { return true }
        return false
    }

    private func requestGrant(_ id: UInt32, profile: String, withJobs: Bool, liveToken: Bool, carryJobsFrom: String?) async -> Result<WatchVoiceWire.DirectToolGrant, Error> {
        let startedAt = Date()
        let dashboard = appState.watchDirectConnection.dashboard
        do {
            var grant = try await grantClient.grant(
                tools: grantTools + (withJobs ? grantJobTools : []) + (liveToken ? [directProvider == .qwen ? WatchLiveToken.qwenTool : WatchLiveToken.tool] : []),
                profile: profile,
                maxJobs: withJobs ? grantMaxJobs : nil,
                jobOptions: withJobs ? grantJobOptions : [:],
                carryJobsFrom: withJobs ? carryJobsFrom : nil,
                jobProfiles: withJobs ? Self.grantableJobProfiles(grantJobProfiles) : [],
                audio: grantAudio,
                answerSessions: grantTools.contains(WatchCallAnswer.tool) ? grantAnswerSessions : [],
                answerApprovals: grantAnswerApprovals
            )
            grant.voiceApprovals = grantVoiceApprovals && grant.tools.contains(WatchJobAnswer.answerApproval)
            // Every name the user's profiles go by: the Watch tells a
            // profile the host doesn't take from a name that isn't one.
            grant.jobProfiles = grant.hostJobProfiles == nil ? nil : grantJobProfiles
            guard callID == id else {
                // The call ended while the host answered. Revoked through
                // the dashboard that gave it; another runs it out.
                if appState.watchDirectConnection.dashboard == dashboard {
                    let client = grantClient
                    let end = Self.beginBackgroundTask("conduit.watchDirect.lateRevoke")
                    Task {
                        defer { end() }
                        await client.revoke(grantID: grant.grantID, profile: profile)
                    }
                }
                return .failure(CancellationError())
            }
            grantIDs.append(grant.grantID)
            if let ends = grant.expiresAt { grantExpiresAt = max(grantExpiresAt ?? ends, ends) }
            link.log.note("watchToolGrant", [
                "callID": Int(id),
                "ok": true,
                "ms": Self.milliseconds(since: startedAt),
                "tools": grant.tools,
                "maxCalls": grant.maxCalls,
                "maxJobs": grant.maxJobs as Any,
                "voiceApprovals": grant.voiceApprovals == true,
                "askedJobs": withJobs,
                "askedToken": liveToken,
                "askedCarry": carryJobsFrom != nil,
                "askedAudio": grantAudio,
                "audioEngines": grant.audio?.engines as Any,
                // What the host said; the Watch logs whether it moved jobs.
                "hostCarried": grant.jobsCarriedFrom != nil,
                "expiresInS": grant.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any,
            ])
            return .success(grant)
        } catch {
            lastGrantError = UserFacingError.message(for: error)
            link.log.note("watchToolGrant", [
                "callID": Int(id),
                "ok": false,
                "ms": Self.milliseconds(since: startedAt),
                "askedJobs": withJobs,
                "askedToken": liveToken,
                "error": error.localizedDescription,
            ])
            return .failure(error)
        }
    }

    /// The Watch's ask for a new grant, before its grant runs out. Only a
    /// grant this phone got for the call can have its jobs carried over.
    private func renewGrant(_ id: UInt32, carryJobsFrom: String?) async -> WatchVoiceWire.Message {
        guard onCallsConnection(id) else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged) }
        adoptIfKnown(id)
        if let mode = callMode, let refusal = consentRefusal(mode) {
            endCall()
            return .callRefused(callID: id, reason: refusal)
        }
        guard id == callID, let profile = connection?.profile, !grantTools.isEmpty || !grantJobTools.isEmpty || grantLiveToken else {
            return .callRefused(callID: id, reason: AppLocalization.string("This call has no Watch lookups to renew."))
        }
        guard await appState.connectForWatchDirectCall(timeout: Self.connectWait) else {
            return .callRefused(callID: id, reason: WatchVoiceStartFailure.hermesUnreachable)
        }
        guard onCallsConnection(id) else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged) }
        let carry = carryJobsFrom.flatMap { grantIDs.contains($0) ? $0 : nil }
        let renewed = await requestGrant(id, profile: profile, carryJobsFrom: carry)
        if callID == id { ledger.setGrant(grantScope, for: id) }
        guard let grant = renewed else {
            return .callRefused(callID: id, reason: AppLocalization.string("Hermes couldn't renew the Watch lookups."))
        }
        // Ending the call revokes the new grant with the others.
        guard onCallsConnection(id) else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged) }
        return .directGrantIssued(callID: id, grant: grant)
    }

    /// After a restart: a running call the ledger knows becomes the running
    /// call again, with its connection and what its grants cover.
    private func adoptIfKnown(_ id: UInt32) {
        guard callID == nil, let known = ledger.call(id), !known.ended else { return }
        callID = id
        callMode = known.liveMode
        directProvider = known.directProvider
        connection = known.connection
        if let scope = known.grant {
            grantTools = scope.tools
            grantJobTools = scope.jobTools
            grantLiveToken = scope.liveToken
            grantMaxJobs = scope.maxJobs
            grantJobOptions = scope.jobOptions
            // A call stored before the names were kept gets today's, with
            // its own profile as the one jobs run on by default.
            grantJobProfiles = scope.jobProfiles
                ?? appState.watchJobProfileNames(callProfile: known.connection.profile)
            grantVoiceApprovals = scope.voiceApprovals
            grantIDs = scope.grantIDs
            grantAudio = scope.audio ?? false
            grantAnswerSessions = scope.answerSessions ?? []
            grantAnswerApprovals = scope.answerApprovals ?? false
            grantExpiresAt = scope.expiresAt
        }
        lateOutgoing = []
        lastHeardAt = Date()
        watchSilence(id)
        // A bridge call still can't outlive its grant after a restart.
        if grantAudio { endWhenGrantDoes(id, expiresAt: grantExpiresAt) }
        appState.setWatchVoiceCallActive(true)
        appState.voiceBackgroundJobSupervisor.readsRepliesWhenSettling = true
    }

    private var grantScope: WatchDirectCallLedger.GrantScope {
        .init(
            tools: grantTools,
            jobTools: grantJobTools,
            liveToken: grantLiveToken,
            maxJobs: grantMaxJobs,
            jobOptions: grantJobOptions,
            jobProfiles: grantJobProfiles,
            voiceApprovals: grantVoiceApprovals,
            grantIDs: grantIDs,
            audio: grantAudio,
            expiresAt: grantExpiresAt,
            answerSessions: grantAnswerSessions,
            answerApprovals: grantAnswerApprovals
        )
    }

    /// Ends the call's grants on Hermes, which closes them on the relay.
    /// Only through the call's own dashboard: after a switch to another,
    /// they run out on their own (30 minutes at most).
    private func revokeGrants() {
        let ids = grantIDs
        grantIDs = []
        grantTools = []
        grantJobTools = []
        grantLiveToken = false
        grantJobOptions = [:]
        grantJobProfiles = []
        grantAudio = false
        grantAnswerSessions = []
        grantAnswerApprovals = false
        guard !ids.isEmpty, let connection else { return }
        guard connection.dashboard == appState.watchDirectConnection.dashboard else {
            link.log.note("watchToolGrantsLeft", ["grants": ids.count])
            return
        }
        let profile = connection.profile
        let client = grantClient
        let end = Self.beginBackgroundTask("conduit.watchDirect.revoke")
        Task {
            for id in ids { await client.revoke(grantID: id, profile: profile) }
            end()
        }
    }

    // MARK: End

    /// The transcript goes to the connection the call began on, kept
    /// across a restart, whichever is active now. A call this phone has no
    /// record of isn't saved, rather than saved somewhere it didn't happen.
    private func ended(_ id: UInt32, transcript: WatchVoiceWire.DirectTranscript) {
        let isCurrent = id == callID
        let known = ledger.call(id)
        ledger.end(id)
        link.log.note("watchDirectEnd", [
            "callID": Int(id),
            "lines": transcript.turns.count,
            "current": isCurrent,
            "known": known != nil,
            "appState": WatchVoiceLink.appStateName,
        ])
        if isCurrent { endCall(keepRecovery: true) }
        let appState = self.appState
        // Jobs on another profile are filed there, so the call lists only
        // its own profile's.
        let started = callJobs.removeValue(forKey: id) ?? []
        let supervisor = appState.voiceBackgroundJobSupervisor
        let waiting = waitingJobs(started)
        let phoneJobs = supervisor.jobs.compactMap { job -> WatchVoiceWire.DirectJob? in
            guard started.contains(job.id), !waiting.contains(job.id), job.profile == nil,
                  !(job.continuesChat && job.status == .cancelled && !job.requestSent) else { return nil }
            let sessionID = [job.storedSessionID, job.runtimeSessionID].compactMap { $0 }.first { !$0.isEmpty }
            return .init(jobID: job.id.uuidString, title: job.title, sessionID: sessionID, startedAt: job.startedAt)
        }
        Task {
            for jobID in waiting { _ = await supervisor.cancel(jobID: jobID) }
            if let known {
                await appState.saveWatchVoiceCall(transcript, connection: known.connection, saveCalls: known.saveCalls, phoneJobs: phoneJobs)
            }
            // Recovery stays allowed until the save has had its chance.
            if self.callID == nil { appState.setWatchVoiceCallActive(false) }
        }
    }

    /// Whether `id`'s messages may be answered: it began on the connection
    /// active now. A running call whose connection the phone left ends.
    private func onCallsConnection(_ id: UInt32) -> Bool {
        let current = appState.watchDirectConnection
        let known = ledger.call(id)
        if let known, known.connection == current { return true }
        // The running call, or one still running when the phone restarted.
        if id == callID || (callID == nil && known?.ended == false) {
            link.log.note("watchDirectConnectionChanged", ["callID": Int(id), "known": known != nil])
            if id == callID { endCall() } else { ledger.end(id) }
        } else {
            link.log.note("watchDirectRefused", ["callID": Int(id), "known": known != nil, "straggler": true])
        }
        return false
    }

    /// The phone is leaving the running call's connection (another profile
    /// or dashboard, or signing out): the call ends with it, as the phone's
    /// own Gemini Live call does. Its grants are revoked while the call's
    /// dashboard is still the active one.
    func connectionRetiring(in appState: AppState) {
        guard let callID, appState === self.appState else { return }
        link.log.note("watchDirectConnectionChanged", ["callID": Int(callID), "known": true, "running": true, "boundary": true])
        endCall()
    }

    /// The user took back their OK for `mode`'s provider (#827): its running
    /// call ends here, and revoking its grants closes the host's audio
    /// bridge (GPT-Live, Grok Live) and the Watch's lookups. A Gemini call's
    /// socket is the Watch's own: it loses its tools and gets no new token,
    /// but its audio stops only when the Watch hangs up (no wire message
    /// ends it from here). A call of unknown mode ends too.
    func consentWithdrawn(for mode: LiveVoiceModeName) {
        guard callID != nil, callMode == nil || callMode == mode else { return }
        link.log.note("watchDirectConsentWithdrawn", ["callID": Int(callID ?? 0), "mode": mode.storageID])
        endCall()
    }

    /// A request still waiting its turn in the call's chat goes no further
    /// when the call ends, however it ends, as on the relay and in a phone
    /// call (#1250).
    private func waitingJobs(_ started: [UUID]) -> [UUID] {
        appState.voiceBackgroundJobSupervisor.jobs.filter {
            started.contains($0.id) && $0.continuesChat && !$0.requestSent && $0.status.isActive
        }.map(\.id)
    }

    /// Unspoken job news goes back to the jobs, which report it as usual.
    private func endCall(keepRecovery: Bool = false) {
        if let callID {
            let waiting = waitingJobs(callJobs[callID] ?? [])
            let supervisor = appState.voiceBackgroundJobSupervisor
            if !waiting.isEmpty { Task { for jobID in waiting { _ = await supervisor.cancel(jobID: jobID) } } }
        }
        grantWatchdog?.cancel()
        grantWatchdog = nil
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        grantExpiresAt = nil
        if let callID { ledger.end(callID) }
        if let bridge {
            bridge.returnUnsent(lateOutgoing.compactMap { item in
                if case .textWhenIdle(let text) = item { return text }
                return nil
            })
            bridge.beginEnding()
        }
        bridge = nil
        lateOutgoing = []
        hostTools = []
        hostToolsMode = nil
        callMode = nil
        appState.watchCallUserTurn = nil
        revokeGrants()
        appState.voiceBackgroundJobSupervisor.readsRepliesWhenSettling = false
        callID = nil
        connection = nil
        if !keepRecovery { appState.setWatchVoiceCallActive(false) }
    }

    private func heard(_ id: UInt32) {
        guard let callID else { return }
        if callID == id {
            lastHeardAt = Date()
            return
        }
        // Another call's message: a straggler from one that ended, unless
        // the running call has been silent so long that it ended without
        // its end arriving.
        if Date() > Self.silenceDeadline(lastHeardAt: lastHeardAt, grantExpiresAt: grantExpiresAt) {
            link.log.note("watchDirectStale", ["callID": Int(callID)])
            endCall()
        }
    }

    /// When a call not heard from since `lastHeardAt` is over: after the
    /// silence limit, and not while a grant its Watch may be using wrist
    /// down is still open.
    static func silenceDeadline(lastHeardAt: Date, grantExpiresAt: Date?) -> Date {
        let quiet = lastHeardAt.addingTimeInterval(silenceLimit)
        guard let grantExpiresAt else { return quiet }
        return max(quiet, grantExpiresAt.addingTimeInterval(grantGrace))
    }

    /// A Watch that dies sends nothing, not even its end: without this the
    /// call would stay running here until the next call's first message.
    /// Every message the call sends moves the deadline on.
    private func watchSilence(_ id: UInt32) {
        silenceWatchdog?.cancel()
        silenceWatchdog = Task { [weak self] in
            while let wait = self?.silenceWait(id) {
                guard wait > 0 else {
                    guard let self else { return }
                    self.link.log.note("watchDirectSilent", [
                        "callID": Int(id),
                        "quietS": Int(Date().timeIntervalSince(self.lastHeardAt)),
                    ])
                    self.endCall()
                    return
                }
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
        }
    }

    /// Seconds until the running call `id` is over for silence; nil once
    /// it isn't the running call.
    private func silenceWait(_ id: UInt32) -> TimeInterval? {
        guard callID == id else { return nil }
        return Self.silenceDeadline(lastHeardAt: lastHeardAt, grantExpiresAt: grantExpiresAt).timeIntervalSinceNow
    }

    // MARK: Helpers

    /// The task's value, or nil if it takes longer than `limit`; the task
    /// carries on either way.
    private static func value<Value>(of task: Task<Value, Never>, within limit: Duration) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = WatchDirectResumeOnce(continuation)
            Task { @MainActor in once.resume(await task.value) }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.resume(nil)
            }
        }
    }

    /// Keeps Conduit running while it answers the Watch; the expiration
    /// ends it early.
    private static func beginBackgroundTask(_ name: String) -> () -> Void {
        BackgroundTaskHold.begin(name)
    }

    /// A Watch call's user turn as an id, the same for every tool call it
    /// leads to. The turn comes off the wire: kept to the 12 hex digits
    /// the last group holds, so the id always reads.
    static func userTurnID(call: UInt32, turn: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-4000-8000-%012llX", call, UInt64(max(0, turn)) & 0xFFFF_FFFF_FFFF))!
    }

    /// A start's tries: with the phone's own tools, then without.
    private static func hostToolChoices(_ tools: [VoiceHostTool]) -> [[VoiceHostTool]] {
        tools.isEmpty ? [[]] : [tools, []]
    }

    private static func messageBytes(_ message: WatchVoiceWire.Message) -> Int? {
        (WatchVoiceWire.encode(message)[WatchVoiceWire.messageKey] as? Data)?.count
    }

    private static func fitsWatchMessage(_ message: WatchVoiceWire.Message) -> Bool {
        messageBytes(message).map { $0 <= bridgeReplyLimit } ?? false
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

/// The Hermes connection a Watch call belongs to: the dashboard and the
/// profile it began on.
struct WatchDirectConnection: Codable, Equatable {
    let profile: String
    let dashboard: String
}

/// What the phone keeps about its recent Watch calls across a restart:
/// the connection each began on and the "Save voice calls" setting then,
/// whether it ended, the start_job calls sent toward Hermes for it, and
/// what its grants cover. Profile names, dashboard and grant ids only,
/// never a key or a transcript.
struct WatchDirectCallLedger {
    struct Call: Codable, Equatable {
        let id: UInt32
        let connection: WatchDirectConnection
        let saveCalls: Bool
        /// Missing in ledgers written before providers had separate identities.
        var mode: String? = nil
        var liveMode: LiveVoiceModeName? {
            LiveVoiceModeName.all.first { $0.storageID == mode }
        }
        var directProvider: DirectLiveProvider { liveMode == .qwenLive ? .qwen : .gemini }
        var ended = false
        var jobs: [String] = []
        /// What its grants cover, so it can renew them after a restart.
        var grant: GrantScope?
    }

    /// The tools and limits a call's grants were asked for, and the grants'
    /// ids (for carrying jobs over and revoking): never their keys.
    struct GrantScope: Codable, Equatable {
        var tools: [String]
        var jobTools: [String]
        var liveToken: Bool
        var maxJobs: Int
        var jobOptions: [String: String]
        /// Missing in calls stored before jobs ran on other profiles.
        var jobProfiles: [WatchVoiceWire.JobProfileName]? = nil
        var voiceApprovals: Bool
        var grantIDs: [String]
        /// The grant carries the host's audio bridge. Missing in calls
        /// stored before the bridge.
        var audio: Bool? = nil
        /// When the call's last grant ends. Missing in calls stored before
        /// the phone kept it.
        var expiresAt: Date? = nil
        /// The chat of the call from Hermes its answer_call answers.
        /// Missing in calls stored before Watch answers.
        var answerSessions: [String]? = nil
        /// Whether that answer_call may approve. Missing in calls stored
        /// before it could.
        var answerApprovals: Bool? = nil
    }

    static let defaultsKey = "watchDirect.calls.v1"
    /// Calls kept, newest last.
    static let callLimit = 16
    /// Start_job calls kept per call: more than any job cap allows.
    static let jobLimit = 32

    private let defaults: UserDefaults
    private(set) var calls: [Call]
    /// The size of what was stored, when it couldn't be read.
    private(set) var unreadableBytes: Int?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            calls = []
            return
        }
        if let calls = try? JSONDecoder().decode([Call].self, from: data) {
            self.calls = calls
        } else {
            calls = []
            unreadableBytes = data.count
        }
    }

    static func jobKey(_ toolID: String, in id: UInt32) -> String {
        "\(id):\(toolID)"
    }

    func call(_ id: UInt32) -> Call? {
        calls.last { $0.id == id }
    }

    func hasSentJob(_ toolID: String, in id: UInt32) -> Bool {
        call(id)?.jobs.contains(toolID) == true
    }

    mutating func begin(_ id: UInt32, connection: WatchDirectConnection, saveCalls: Bool, mode: LiveVoiceModeName? = nil) {
        calls.removeAll { $0.id == id }
        calls.append(Call(id: id, connection: connection, saveCalls: saveCalls, mode: mode?.storageID))
        if calls.count > Self.callLimit { calls.removeFirst(calls.count - Self.callLimit) }
        store()
    }

    /// Only a call this phone began is kept.
    mutating func end(_ id: UInt32) {
        guard let index = calls.lastIndex(where: { $0.id == id }), !calls[index].ended else { return }
        calls[index].ended = true
        store()
    }

    mutating func setGrant(_ scope: GrantScope, for id: UInt32) {
        guard let index = calls.lastIndex(where: { $0.id == id }), calls[index].grant != scope else { return }
        calls[index].grant = scope
        store()
    }

    /// Written at once: the receipt is on disk before the start can reach
    /// Hermes.
    mutating func recordJob(_ toolID: String, in id: UInt32) {
        guard let index = calls.lastIndex(where: { $0.id == id }), !calls[index].jobs.contains(toolID) else { return }
        calls[index].jobs.append(toolID)
        if calls[index].jobs.count > Self.jobLimit { calls[index].jobs.removeFirst() }
        store()
    }

    /// Hermes refused the job: a repeat of its start may go again.
    mutating func forgetJob(_ toolID: String, in id: UInt32) {
        guard let index = calls.lastIndex(where: { $0.id == id }), let job = calls[index].jobs.firstIndex(of: toolID) else { return }
        calls[index].jobs.remove(at: job)
        store()
    }

    private func store() {
        guard let data = try? JSONEncoder().encode(calls) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Why a Watch call couldn't be prepared, in words the Watch shows.
struct WatchDirectPrepareError: Error {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}

@MainActor
private final class WatchDirectResumeOnce<Value> {
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// The phone's job supervisor as a Watch call sees it: the same jobs and
/// news, but no attached chat and no phone screen to show things on
/// (the phone is in a pocket), so start_job always starts a job and
/// show_on_screen says the screen isn't available.
@MainActor
final class WatchCallJobSupervisor: GeminiLiveJobSupervising {
    private let base: VoiceBackgroundJobSupervisor

    init(_ base: VoiceBackgroundJobSupervisor) {
        self.base = base
    }

    var jobs: [VoiceBackgroundJob] { base.jobs }

    /// Told of each job this call starts.
    var onJobCreated: (@MainActor (UUID) -> Void)?
    /// The chat this call's first ordinary job made: its later ordinary
    /// requests run there too, as the relay's do (#1250). The call has no
    /// attached chat on the phone, so each is still a job of the call.
    private(set) var callChat: VoiceThreadTarget?
    /// A first ordinary job is being started: ordinary requests said
    /// meanwhile wait for its chat rather than make their own.
    private var startingCallChat = false
    /// Whether the call is still on: a request that waited past its end
    /// goes no further.
    var callIsLive: (@MainActor () -> Bool)?
    private var callChatWaiters: [CheckedContinuation<Void, Never>] = []

    func startJob(instructions: String, profile: String?, joinsCall: Bool, onJobCreated: (@MainActor (UUID) -> Void)?) async -> String {
        let noted = self.onJobCreated
        let created: @MainActor (UUID) -> Void = { jobID in
            noted?(jobID)
            onJobCreated?(jobID)
        }
        let joins = joinsCall && (profile ?? "").isEmpty
        var waited = false
        while joins, callChat == nil, startingCallChat {
            waited = true
            await withCheckedContinuation { callChatWaiters.append($0) }
        }
        if waited, callIsLive?() == false { return "The call ended before Hermes took this request." }
        if joins, let callChat {
            return await base.continueJob(instructions: instructions, in: callChat, onJobCreated: created)
        }
        let claims = joins
        if claims { startingCallChat = true }
        defer {
            if claims {
                // Woken after callChat is set: a failed first start lets the
                // next waiter make the chat instead.
                startingCallChat = false
                let waiters = callChatWaiters
                callChatWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
        var startedID: UUID?
        let base = self.base
        let reply = await base.startJob(instructions: instructions, profile: profile, onJobCreated: { jobID in
            startedID = jobID
            // Marked before Hermes can answer, so its reply is matched
            // against replays from the start.
            if claims { base.markOpensCallChat(jobID) }
            created(jobID)
        })
        if joins, callChat == nil, let startedID, let job = base.jobs.first(where: { $0.id == startedID }), job.profile == nil,
           job.requestSent, let runtimeID = job.runtimeSessionID, !runtimeID.isEmpty {
            switch job.status {
            case .failed, .cancelled: break
            case .starting, .running, .needsInput, .finished:
                callChat = VoiceThreadTarget(runtimeSessionID: runtimeID, storedSessionID: job.storedSessionID, title: job.title)
            }
        }
        return reply
    }

    func statusSummary() -> String { base.statusSummary() }
    var listedJobs: [VoiceBackgroundJob] { base.listedJobs }
    func cancelAll() async -> String { await base.cancelAll() }
    func cancel(jobID: UUID) async -> String? { await base.cancel(jobID: jobID) }
    func markOutcomeDelivered(jobID: UUID) { base.markOutcomeDelivered(jobID: jobID) }
    func holdOutcome(jobID: UUID) { base.holdOutcome(jobID: jobID) }
    func takePendingNoticeForJob() -> (notice: VoiceBackgroundJobNotice, jobID: UUID)? { base.takePendingNoticeForJob() }
    func returnUndeliveredNotice(jobID: UUID) { base.returnUndeliveredNotice(jobID: jobID) }
    func noticeSent(jobID: UUID) { base.noticeSent(jobID: jobID) }
    var liveThread: VoiceThreadTarget? { nil }

    func startThreadTurn(request: String) -> (jobID: UUID?, refusal: String?) {
        (nil, "This call isn't attached to a chat.")
    }

    func namesOtherProfile(_ instructions: String) -> Bool { base.namesOtherProfile(instructions) }
    func lastThreadReply() async -> String? { nil }

    @discardableResult
    func showOnScreen(title: String, markdown: String, cards: [[String: Any]]) -> VoiceScreenCard? { nil }

    func takePendingChatContext() -> String? { nil }

    // No attached chat, so no chat request to follow up; background jobs
    // still take the user's corrections (#451).
    func threadFollowUpTarget() -> UUID? { nil }
    func backgroundJob(numbered number: Int) -> VoiceBackgroundJob? { base.backgroundJob(numbered: number) }
    func followUp(jobID: UUID, words: String, kind: String?) async -> VoiceFollowUpOutcome {
        await base.followUp(jobID: jobID, words: words, kind: kind)
    }

    // Chats are found and read as on the phone, for a call whose grant
    // can't (a plugin before 0.18); opening one stays on the phone.
    func findChats(query: String, retryingWords: Bool) async -> VoiceChatSearchOutcome {
        await base.findChats(query: query, retryingWords: retryingWords)
    }
    func openFoundChat(_ reference: String) -> VoiceChatOpenOutcome { .unavailable }
    func readFoundChat(_ reference: String) async -> VoiceChatReadOutcome { await base.readFoundChat(reference) }

    /// The phone's own tools the call declared, run on this iPhone.
    var hostTools: [VoiceHostTool] = []
    var runHostTool: (@MainActor (VoiceHostTool, [String: Any]) async -> [String: String])?

    func callHostTool(_ tool: VoiceHostTool, arguments: [String: Any]) async -> [String: String] {
        // Only a tool this call was given: its runner checks that tool's
        // consent, so another one must not reach it.
        guard hostTools.contains(where: { $0.name == tool.name && $0.key == tool.key }), let runHostTool else {
            return ["error": "That isn't available on this call."]
        }
        return await runHostTool(tool, arguments)
    }
}
