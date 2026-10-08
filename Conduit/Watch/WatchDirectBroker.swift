//
//  WatchDirectBroker.swift
//  Conduit
//
//  The iPhone's part in a Watch call to Gemini Live (test T2 of
//  designs/apple-watch-voice-direct.md). The Watch runs the session; this
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

    private unowned let link: WatchVoiceLink
    private var callID: UInt32?
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
    private var grantMaxJobs = 0
    private var grantJobOptions: [String: String] = [:]
    private var grantVoiceApprovals = false
    /// Start_job calls by call and id, the newest `jobCallLimit`, ended
    /// calls' too. The Watch sends one again when the link dropped before
    /// its answer came; it gets the first one's answer instead of a second
    /// job.
    private var jobCalls: [String: Task<[GeminiLiveToolBridge.Outgoing], Never>] = [:]
    private var jobCallOrder: [String] = []

    private lazy var grantClient = WatchToolGrantClient(request: { path, method, body, timeout in
        guard let bridge = AppStateRuntimeRegistry.shared.appState.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
    })

    init(link: WatchVoiceLink) {
        self.link = link
    }

    private var appState: AppState { AppStateRuntimeRegistry.shared.appState }

    func handle(_ message: WatchVoiceWire.Message, reply: (([String: Any]) -> Void)?) {
        func answer(_ message: WatchVoiceWire.Message) { reply?(WatchVoiceWire.encode(message)) }
        switch message {
        case .directStart(let id, let version):
            guard version == WatchVoiceWire.version else {
                answer(.callRefused(callID: id, reason: "Update Conduit on your iPhone and Watch to the same build."))
                return
            }
            let end = Self.beginBackgroundTask("conduit.watchDirect.start")
            // Asked again while preparing (the Watch's request timed out):
            // the same answer.
            let task: Task<WatchVoiceWire.Message, Never>
            if let preparing, preparing.callID == id {
                task = preparing.task
            } else {
                task = Task { await self.prepare(id) }
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
            let end = Self.beginBackgroundTask("conduit.watchDirect.token")
            Task {
                defer { end() }
                let startedAt = Date()
                do {
                    let token = try await self.appState.watchDirectToken()
                    // Minted while the phone switched: not this call's.
                    guard self.onCallsConnection(id) else {
                        answer(.callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged))
                        return
                    }
                    answer(.directTokenIssued(callID: id, token: .init(token)))
                    self.link.log.note("watchDirectToken", ["ok": true, "ms": Self.milliseconds(since: startedAt), "appState": WatchProbeLiveness.appStateName])
                } catch {
                    answer(.callRefused(callID: id, reason: UserFacingError.message(for: error)))
                    self.link.log.note("watchDirectToken", ["ok": false, "error": error.localizedDescription, "appState": WatchProbeLiveness.appStateName])
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

    private func prepare(_ id: UInt32) async -> WatchVoiceWire.Message {
        let appState = self.appState
        if let active = callID, active != id { endCall() }
        callID = id
        bridge = nil
        lateOutgoing = []
        lastHeardAt = Date()
        // Lets transport recovery run with the phone locked, as for a
        // CarPlay call.
        appState.setWatchVoiceCallActive(true)
        appState.voiceBackgroundJobSupervisor.readsRepliesWhenSettling = true
        let startedAt = Date()
        link.log.note("watchDirectStart", [
            "callID": Int(id),
            "appState": WatchProbeLiveness.appStateName,
            "phoneScreen": PhoneScenePresence.isInForeground,
            "connected": appState.isConnected,
        ])
        do {
            let plan = try await appState.prepareWatchDirectCall()
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            connection = plan.connection
            ledger.begin(id, connection: plan.connection, saveCalls: plan.saveCalls)
            // Only the lookups and job tools the call declares, jobs only
            // as the user allows; the call goes on without a grant when the
            // host can't give one.
            let declared = plan.functions.map(\.name)
            grantTools = declared.filter { WatchToolAnswer.tools.contains($0) }
            grantMaxJobs = WatchJobSettings.jobsPerCall
            grantJobTools = grantMaxJobs > 0 ? declared.filter { WatchJobAnswer.tools.contains($0) } : []
            grantJobOptions = plan.jobOptions
            grantVoiceApprovals = WatchJobSettings.voiceApprovals
            grantLiveToken = true
            let grant = await requestGrant(id, profile: plan.connection.profile)
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
            guard appState.watchDirectConnection == plan.connection else {
                throw WatchDirectPrepareError(WatchVoiceStartFailure.connectionChanged)
            }
            // The model answers approvals only when the user allowed it and
            // the grant carries jobs.
            var functions = plan.functions
            if grant?.voiceApprovals == true { functions.append(WatchJobAnswer.answerApprovalDeclaration) }
            let setup = WatchVoiceWire.DirectSetup(systemInstruction: plan.systemInstruction, functions: functions)
            guard setup.functions.count == functions.count, let packed = setup.compressed() else {
                throw WatchDirectPrepareError("The call's setup couldn't be packed for the Watch.")
            }
            let session = WatchVoiceWire.DirectSession(
                token: .init(plan.token),
                setup: packed.data,
                setupBytes: packed.bytes,
                googleSearch: plan.googleSearch,
                voice: plan.voice,
                openingPrompt: plan.openingPrompt,
                toolGrant: grant
            )
            link.log.note("watchDirectPrepared", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "setupBytes": packed.bytes,
                "compressedBytes": packed.data.count,
                "functions": functions.map(\.name),
                "googleSearch": plan.googleSearch,
                "memory": plan.memoryIncluded,
                "personality": plan.personalityIncluded,
                "toolGrant": grant != nil,
                "appState": WatchProbeLiveness.appStateName,
            ])
            return .directSession(callID: id, session: session)
        } catch {
            let reason = (error as? WatchDirectPrepareError)?.reason ?? UserFacingError.message(for: error)
            link.log.note("watchDirectPrepareFailed", [
                "callID": Int(id),
                "ms": Self.milliseconds(since: startedAt),
                "error": reason,
                "appState": WatchProbeLiveness.appStateName,
            ])
            if callID == id { endCall() }
            return .callRefused(callID: id, reason: reason)
        }
    }

    // MARK: Tools

    /// The bridge for the Watch's call, made again if Conduit restarted
    /// since the call began. A call that has ended (a job it queued
    /// arriving late) gets one of its own, so the running call is left
    /// alone. Only asked for a call on the active connection.
    private func bridge(for id: UInt32) -> GeminiLiveToolBridge {
        if callID == nil, let known = ledger.call(id), !known.ended {
            callID = id
            connection = known.connection
            lateOutgoing = []
            lastHeardAt = Date()
            appState.setWatchVoiceCallActive(true)
            appState.voiceBackgroundJobSupervisor.readsRepliesWhenSettling = true
        }
        guard callID == id else { return makeBridge() }
        if let bridge { return bridge }
        let bridge = makeBridge()
        self.bridge = bridge
        return bridge
    }

    private func makeBridge() -> GeminiLiveToolBridge {
        let tokens = appState.geminiLiveTokenClient
        // Answered once each job runs, its outcome later as a text update:
        // a Watch message's answer can't stay open for a job.
        return GeminiLiveToolBridge(
            supervisor: WatchCallJobSupervisor(appState.voiceBackgroundJobSupervisor),
            webSearch: tokens,
            memory: tokens,
            holdsJobCalls: false
        )
    }

    private func runTool(_ call: WatchVoiceWire.DirectToolCall, callID id: UInt32, waiting: Bool) async -> WatchVoiceWire.DirectToolResult {
        guard onCallsConnection(id) else { return refused(call, waiting: waiting) }
        let bridge = bridge(for: id)
        let startedAt = Date()
        let functionCall = GeminiLiveProtocol.FunctionCall(id: call.id, name: call.name, arguments: call.arguments)
        let isJob = call.name == GeminiLiveToolBridge.Tool.startJob.rawValue
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
            if callID == id { lateOutgoing += late.filter { !$0.answers(call.id) } }
            var fields: [String: Any] = [
                "name": call.name,
                "ms": Self.milliseconds(since: startedAt),
                "connected": connected,
                "queued": true,
                "appState": WatchProbeLiveness.appStateName,
            ]
            fields.merge(Self.answerSummary(late, answering: call.id)) { first, _ in first }
            link.log.note("watchDirectTool", fields)
            return WatchVoiceWire.DirectToolResult(outgoing: [], runningJobs: appState.voiceBackgroundJobSupervisor.activeJobCount)
        }
        let outgoing: [GeminiLiveToolBridge.Outgoing]
        if let answered = await Self.value(of: handled, within: isJob ? Self.jobStartWait : Self.toolWait) {
            outgoing = answered
        } else {
            // Still running: answer now, and keep whatever it gives later
            // except the answer to this call, which went already.
            Task {
                let late = await handled.value
                guard self.callID == id else { return }
                self.lateOutgoing += late.filter { !$0.answers(call.id) }
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
            "appState": WatchProbeLiveness.appStateName,
        ]
        fields.merge(Self.answerSummary(outgoing, answering: call.id)) { first, _ in first }
        link.log.note("watchDirectTool", fields)
        return result(outgoing, bridge: bridge)
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
        link.log.note("watchDirectTool", ["name": call.name, "connectionChanged": true, "queued": !waiting, "appState": WatchProbeLiveness.appStateName])
        guard waiting else { return WatchVoiceWire.DirectToolResult(outgoing: [], runningJobs: 0) }
        let answer = GeminiLiveToolBridge.Outgoing.toolResponse(id: call.id, name: call.name, result: ["error": WatchVoiceStartFailure.connectionChanged], scheduling: nil)
        return WatchVoiceWire.DirectToolResult(outgoing: [Self.wire(answer), .endConversation], runningJobs: 0)
    }

    /// A start_job this phone sent toward Hermes before it lost the first
    /// one's answer (Conduit restarted, or the call ended here): Hermes may
    /// have the job, so it isn't sent again.
    private func replayedJobCall(_ call: WatchVoiceWire.DirectToolCall, waiting: Bool) -> WatchVoiceWire.DirectToolResult {
        let runningJobs = appState.voiceBackgroundJobSupervisor.activeJobCount
        link.log.note("watchDirectTool", ["name": call.name, "replay": true, "queued": !waiting, "appState": WatchProbeLiveness.appStateName])
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
            link.log.note("watchDirectTool", ["name": call.name, "repeat": true, "queued": true, "appState": WatchProbeLiveness.appStateName])
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
            "appState": WatchProbeLiveness.appStateName,
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
            link.log.note("watchDirectPoll", ["news": news.count, "newsChars": news, "appState": WatchProbeLiveness.appStateName])
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
        for item in items {
            switch item {
            case .toolResponse(_, _, let result, _):
                bridge.outcomeSent(jobID: GeminiLiveConversationController.jobID(of: result))
            case .textWhenIdle(let text):
                bridge.textUpdateDelivered(jobID: bridge.textUpdateSending(text))
            case .contextWhenIdle, .endConversation:
                break
            }
        }
        return WatchVoiceWire.DirectToolResult(
            outgoing: items.map { Self.wire($0) },
            runningJobs: appState.voiceBackgroundJobSupervisor.activeJobCount
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
            if let grant = await requestGrantWithToken(id, profile: profile, withJobs: true, carryJobsFrom: carryJobsFrom) { return grant }
            guard callID == id, !grantTools.isEmpty || grantLiveToken else { return nil }
            // Renewals don't ask for jobs again.
            grantJobTools = []
        }
        guard !grantTools.isEmpty || grantLiveToken else { return nil }
        return await requestGrantWithToken(id, profile: profile, withJobs: false, carryJobsFrom: nil)
    }

    /// Asks with live_token while the host takes it. A plugin before 0.8
    /// refuses a tool it doesn't know (400): asked again without it, and
    /// this call's later grants leave it out.
    private func requestGrantWithToken(_ id: UInt32, profile: String, withJobs: Bool, carryJobsFrom: String?) async -> WatchVoiceWire.DirectToolGrant? {
        let asked = grantLiveToken
        switch await requestGrant(id, profile: profile, withJobs: withJobs, liveToken: asked, carryJobsFrom: carryJobsFrom) {
        case .success(let grant):
            return grant
        case .failure(let error):
            guard asked, callID == id, Self.isRefusedTool(error) else { return nil }
            grantLiveToken = false
            guard !grantTools.isEmpty || (withJobs && !grantJobTools.isEmpty) else { return nil }
            return try? await requestGrant(id, profile: profile, withJobs: withJobs, liveToken: false, carryJobsFrom: carryJobsFrom).get()
        }
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
                tools: grantTools + (withJobs ? grantJobTools : []) + (liveToken ? [WatchLiveToken.tool] : []),
                profile: profile,
                maxJobs: withJobs ? grantMaxJobs : nil,
                jobOptions: withJobs ? grantJobOptions : [:],
                carryJobsFrom: withJobs ? carryJobsFrom : nil
            )
            grant.voiceApprovals = grantVoiceApprovals && grant.tools.contains(WatchJobAnswer.answerApproval)
            guard callID == id else {
                // The call ended while the host answered. Revoked through
                // the dashboard that gave it; another runs it out.
                if appState.watchDirectConnection.dashboard == dashboard {
                    let client = grantClient
                    Task { await client.revoke(grantID: grant.grantID, profile: profile) }
                }
                return .failure(CancellationError())
            }
            grantIDs.append(grant.grantID)
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
                // What the host said; the Watch logs whether it moved jobs.
                "hostCarried": grant.jobsCarriedFrom != nil,
                "expiresInS": grant.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any,
            ])
            return .success(grant)
        } catch {
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
        guard id == callID, let profile = connection?.profile, !grantTools.isEmpty || !grantJobTools.isEmpty || grantLiveToken else {
            return .callRefused(callID: id, reason: "This call has no Watch lookups to renew.")
        }
        guard await appState.connectForWatchDirectCall(timeout: Self.connectWait) else {
            return .callRefused(callID: id, reason: WatchVoiceStartFailure.hermesUnreachable)
        }
        guard onCallsConnection(id) else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged) }
        let carry = carryJobsFrom.flatMap { grantIDs.contains($0) ? $0 : nil }
        guard let grant = await requestGrant(id, profile: profile, carryJobsFrom: carry) else {
            return .callRefused(callID: id, reason: "Hermes couldn't renew the Watch lookups.")
        }
        // Ending the call revokes the new grant with the others.
        guard onCallsConnection(id) else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.connectionChanged) }
        return .directGrantIssued(callID: id, grant: grant)
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
            "appState": WatchProbeLiveness.appStateName,
        ])
        if isCurrent { endCall(keepRecovery: true) }
        let appState = self.appState
        Task {
            if let known {
                await appState.saveWatchVoiceCall(transcript, connection: known.connection, saveCalls: known.saveCalls)
            }
            // Recovery stays allowed until the save has had its chance.
            if self.callID == nil { appState.setWatchVoiceCallActive(false) }
        }
    }

    /// Whether `id`'s messages may be answered: it began on the connection
    /// active now. A running call whose connection the phone left ends.
    private func onCallsConnection(_ id: UInt32) -> Bool {
        let current = appState.watchDirectConnection
        if let known = ledger.call(id), known.connection == current { return true }
        link.log.note("watchDirectConnectionChanged", [
            "callID": Int(id),
            "known": ledger.call(id) != nil,
            "running": id == callID,
        ])
        if id == callID { endCall() }
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

    /// Unspoken job news goes back to the jobs, which report it as usual.
    private func endCall(keepRecovery: Bool = false) {
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
        if Date().timeIntervalSince(lastHeardAt) > Self.silenceLimit {
            link.log.note("watchDirectStale", ["callID": Int(callID)])
            endCall()
        }
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
        var taskID = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard taskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        taskID = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: end)
        return end
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
/// whether it ended, and the start_job calls sent toward Hermes for it.
/// Profile names and dashboard ids only, never a key or a transcript.
struct WatchDirectCallLedger {
    struct Call: Codable, Equatable {
        let id: UInt32
        let connection: WatchDirectConnection
        let saveCalls: Bool
        var ended = false
        var jobs: [String] = []
    }

    static let defaultsKey = "watchDirect.calls.v1"
    /// Calls kept, newest last.
    static let callLimit = 16
    /// Start_job calls kept per call: more than any job cap allows.
    static let jobLimit = 32

    private let defaults: UserDefaults
    private(set) var calls: [Call]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        calls = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Call].self, from: $0) } ?? []
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

    mutating func begin(_ id: UInt32, connection: WatchDirectConnection, saveCalls: Bool) {
        calls.removeAll { $0.id == id }
        calls.append(Call(id: id, connection: connection, saveCalls: saveCalls))
        if calls.count > Self.callLimit { calls.removeFirst(calls.count - Self.callLimit) }
        store()
    }

    /// Only a call this phone began is kept.
    mutating func end(_ id: UInt32) {
        guard let index = calls.lastIndex(where: { $0.id == id }), !calls[index].ended else { return }
        calls[index].ended = true
        store()
    }

    mutating func recordJob(_ toolID: String, in id: UInt32) {
        guard let index = calls.lastIndex(where: { $0.id == id }), !calls[index].jobs.contains(toolID) else { return }
        calls[index].jobs.append(toolID)
        if calls[index].jobs.count > Self.jobLimit { calls[index].jobs.removeFirst() }
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

    func startJob(instructions: String, profile: String?, onJobCreated: (@MainActor (UUID) -> Void)?) async -> String {
        await base.startJob(instructions: instructions, profile: profile, onJobCreated: onJobCreated)
    }

    func statusSummary() -> String { base.statusSummary() }
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
    func showOnScreen(title: String, markdown: String) -> VoiceScreenCard? { nil }

    func takePendingChatContext() -> String? { nil }
}
