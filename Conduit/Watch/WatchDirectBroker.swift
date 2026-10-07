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
//  - answers the Watch's polls while jobs run;
//  - asks Hermes for the call's tool grant, so its lookups reach Hermes
//    through the push relay while the Watch can't reach this phone, and
//    ends it with the call;
//  - saves the finished call in voice history.
//  Each is a short answer to a Watch message, which wakes Conduit in the
//  background; nothing here runs between them.
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
    /// How long a token, tool or poll waits for a Hermes connection the
    /// phone's suspension dropped.
    static let connectWait: Duration = .seconds(8)
    /// A call not heard from this long is over, whatever its end said.
    static let silenceLimit: TimeInterval = 30 * 60

    private unowned let link: WatchVoiceLink
    private var callID: UInt32?
    private var bridge: GeminiLiveToolBridge?
    private var preparing: (callID: UInt32, task: Task<WatchVoiceWire.Message, Never>)?
    private var profile: String?
    private var dashboard: String?
    private var lastHeardAt = Date.distantPast
    /// Calls that ended here: a late message from one must not make it the
    /// running call again.
    private var endedCallIDs: [UInt32] = []
    /// What the bridge gave after its call's answer had gone (a slow
    /// start_job, or a call queued while the Watch couldn't wait): sent
    /// with the next poll.
    private var lateOutgoing: [GeminiLiveToolBridge.Outgoing] = []
    /// The tools the running call's grants cover, and the grants it got:
    /// all revoked when it ends.
    private var grantTools: [String] = []
    private var grantIDs: [String] = []

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
            let end = Self.beginBackgroundTask("conduit.watchDirect.token")
            Task {
                defer { end() }
                let startedAt = Date()
                do {
                    let token = try await self.appState.watchDirectToken()
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
        case .directGrant(let id):
            heard(id)
            let end = Self.beginBackgroundTask("conduit.watchDirect.grant")
            Task {
                defer { end() }
                answer(await self.renewGrant(id))
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
            profile = plan.profile
            dashboard = plan.dashboard
            let setup = WatchVoiceWire.DirectSetup(systemInstruction: plan.systemInstruction, functions: plan.functions)
            guard setup.functions.count == plan.functions.count, let packed = setup.compressed() else {
                throw WatchDirectPrepareError("The call's setup couldn't be packed for the Watch.")
            }
            // Only the lookups the call declares; the call goes on without
            // a grant when the host can't give one.
            grantTools = plan.functions.map(\.name).filter { WatchToolAnswer.tools.contains($0) }
            let grant = grantTools.isEmpty ? nil : await requestGrant(id, profile: plan.profile)
            guard callID == id else { return .callRefused(callID: id, reason: WatchVoiceStartFailure.ended) }
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
                "functions": plan.functions.map(\.name),
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
    /// alone.
    private func bridge(for id: UInt32) -> GeminiLiveToolBridge {
        if callID == nil, !endedCallIDs.contains(id) {
            callID = id
            lateOutgoing = []
            lastHeardAt = Date()
            appState.setWatchVoiceCallActive(true)
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
        let bridge = bridge(for: id)
        let startedAt = Date()
        let connected = await appState.connectForWatchDirectCall(timeout: Self.connectWait)
        let functionCall = GeminiLiveProtocol.FunctionCall(id: call.id, name: call.name, arguments: call.arguments)
        let isJob = call.name == GeminiLiveToolBridge.Tool.startJob.rawValue
        let handled = Task { await bridge.handle(functionCall) }
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
            let result: [String: String] = isJob
                ? ["status": "accepted", "message": "Hermes is starting the job. Its result will arrive later as a message; don't wait for it."]
                : WatchToolAnswer.tookTooLong
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
        return result(bridge.pendingUpdates(), bridge: bridge)
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

    /// A grant for the running call's lookups; nil when the host can't
    /// give one. The log has its outcome and limits, never its keys.
    private func requestGrant(_ id: UInt32, profile: String) async -> WatchVoiceWire.DirectToolGrant? {
        let startedAt = Date()
        do {
            let grant = try await grantClient.grant(tools: grantTools, profile: profile)
            guard callID == id else {
                // The call ended while the host answered.
                let client = grantClient
                Task { await client.revoke(grantID: grant.grantID, profile: profile) }
                return nil
            }
            grantIDs.append(grant.grantID)
            link.log.note("watchToolGrant", [
                "callID": Int(id),
                "ok": true,
                "ms": Self.milliseconds(since: startedAt),
                "tools": grant.tools,
                "maxCalls": grant.maxCalls,
                "expiresInS": grant.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any,
            ])
            return grant
        } catch {
            link.log.note("watchToolGrant", [
                "callID": Int(id),
                "ok": false,
                "ms": Self.milliseconds(since: startedAt),
                "error": error.localizedDescription,
            ])
            return nil
        }
    }

    /// The Watch's ask for a new grant, before its grant runs out.
    private func renewGrant(_ id: UInt32) async -> WatchVoiceWire.Message {
        guard id == callID, let profile, !grantTools.isEmpty else {
            return .callRefused(callID: id, reason: "This call has no Watch lookups to renew.")
        }
        guard await appState.connectForWatchDirectCall(timeout: Self.connectWait) else {
            return .callRefused(callID: id, reason: WatchVoiceStartFailure.hermesUnreachable)
        }
        guard let grant = await requestGrant(id, profile: profile) else {
            return .callRefused(callID: id, reason: "Hermes couldn't renew the Watch lookups.")
        }
        return .directGrantIssued(callID: id, grant: grant)
    }

    /// Ends the call's grants on Hermes, which closes them on the relay.
    private func revokeGrants() {
        let ids = grantIDs
        grantIDs = []
        grantTools = []
        guard !ids.isEmpty, let profile else { return }
        let client = grantClient
        let end = Self.beginBackgroundTask("conduit.watchDirect.revoke")
        Task {
            for id in ids { await client.revoke(grantID: id, profile: profile) }
            end()
        }
    }

    // MARK: End

    private func ended(_ id: UInt32, transcript: WatchVoiceWire.DirectTranscript) {
        let isCurrent = id == callID
        markEnded(id)
        let profile = isCurrent ? self.profile : nil
        let dashboard = isCurrent ? self.dashboard : nil
        link.log.note("watchDirectEnd", [
            "callID": Int(id),
            "lines": transcript.turns.count,
            "current": isCurrent,
            "appState": WatchProbeLiveness.appStateName,
        ])
        if isCurrent { endCall(keepRecovery: true) }
        let appState = self.appState
        Task {
            await appState.saveWatchVoiceCall(transcript, profile: profile, dashboard: dashboard)
            // Recovery stays allowed until the save has had its chance.
            if self.callID == nil { appState.setWatchVoiceCallActive(false) }
        }
    }

    private func markEnded(_ id: UInt32) {
        guard !endedCallIDs.contains(id) else { return }
        endedCallIDs.append(id)
        if endedCallIDs.count > 16 { endedCallIDs.removeFirst() }
    }

    /// Unspoken job news goes back to the jobs, which report it as usual.
    private func endCall(keepRecovery: Bool = false) {
        if let callID { markEnded(callID) }
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
        callID = nil
        profile = nil
        dashboard = nil
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
