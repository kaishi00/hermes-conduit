//
//  WatchBridgeCallModel.swift
//  Conduit Watch
//
//  A GPT-Live call on the Watch through the Hermes host's audio bridge
//  (designs/apple-watch-gpt-live.md). GPT-Live on the ChatGPT
//  subscription speaks WebRTC only, which watchOS doesn't have, so the
//  conduit_push plugin holds the WebRTC call and the Watch streams to it:
//  one WebSocket through the push relay, every message sealed with the
//  call's grant (WatchAudioBridgeWire). The iPhone only builds the call's
//  briefing and asks Hermes for the grant; after that the call runs
//  without it, wrist up or down.
//
//  The call shell is the direct Gemini call's (WatchDirectCallModel):
//  option E, the play-and-record audio session alone, activated
//  asynchronously and again every 25 s (the FB24377808 workaround the
//  device runs settled on); the URLSession socket; half duplex, since the
//  Watch can't cancel its own echo, with a tap to stop GPT-Live.
//
//  GPT-Live hands real work to the app as delegations. As on the phone,
//  each becomes a Hermes job, here through the grant's relay route, and
//  its outcome goes back on the delegation once nobody is speaking. A job
//  that asks for approval shows Approve and Deny on the Watch.
//
//  The bridge sends GPT-Live's audio as one continuous stream, silence
//  included: the Watch plays only stretches of speech, so the speaker
//  (and with it the microphone hold) follows what GPT-Live says.
//
//  Measures what the device test needs: each step of the start, each
//  reply's time from the end of the user's speech to audible speech and
//  from GPT-Live's transcript of it, rejoins, delegations and jobs, data
//  both ways, time with the screen off, gaps in the app's run.
//

import AVFAudio
import Foundation
import SwiftUI
import WatchKit

@MainActor
final class WatchBridgeCallModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Starting the Watch's audio and asking the iPhone for the call.
        case preparing
        case connecting
        case listening
        case speaking
        case reconnecting
        /// Siri or an alarm took the microphone: a tap brings it back.
        case needsTap
        case ending
        case ended(String?)
    }

    static let engine = WatchAudioBridgeWire.gptLive
    static let captureRate = WatchAudio.captureRate
    static let playbackRate: Double = 24_000
    static let sessionWait: TimeInterval = 30
    static let sessionRetryDelay: TimeInterval = 2
    static let flushInterval: TimeInterval = 0.1
    /// After GPT-Live stops playing, the microphone stays closed this long
    /// so the speaker's echo can't read as the user.
    static let echoTail: TimeInterval = 0.35
    static let reactivateEvery: TimeInterval = 25
    static let reactivationTimeout: TimeInterval = 10
    /// GPT-Live's start on the host: its WebRTC offer (ICE gathering
    /// included) and the connection after the answer, with one retry.
    static let startedWait: TimeInterval = 45
    /// The relay turns the Watch away until the host's bridge is there.
    static let hostOfflineRetries = 8
    static let maxRejoins = 3
    /// The relay closes a socket silent for a minute.
    static let pingInterval: TimeInterval = 20
    /// Pings failed or unanswered in a row before the socket counts as lost.
    static let pingMissLimit = 2
    /// Model audio louder than this (PCM16 peak) is speech.
    static let speechPeak = 600
    /// This much quiet ends a stretch of GPT-Live's speech.
    static let speechGap: TimeInterval = 0.6
    /// No loud audio for this long ends a stretch, chunks arriving or not.
    static let silentStretch: TimeInterval = 2
    /// Quiet audio kept before speech starts, so its first sound isn't cut.
    static let leadIn: TimeInterval = 0.1
    /// Results wait for this much quiet after the user and GPT-Live, as on
    /// the phone.
    static let userQuietInterval: TimeInterval = 2
    static let modelQuietInterval: TimeInterval = 1
    static let jobNewsWait = 15
    static let jobNewsPause: TimeInterval = 15
    static let jobNewsRetry: TimeInterval = 2
    /// A new job starts only with this many grant calls left, so its news
    /// can follow it to a result.
    static let callsForNewJob = 10
    /// Grant calls job news leaves for answering approvals.
    static let callsKeptForApprovals = 2
    /// Conversation a rejoined session is seeded with.
    static let historyTurns = 40
    static let endTimeout: TimeInterval = 4
    static let sendsInFlightLimit = 20
    static let timelineInterval: TimeInterval = 30

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var caption: String?
    @Published private(set) var isMuted = false
    @Published private(set) var relayJobsRunning = 0
    @Published private(set) var pendingApproval: WatchJobAnswer.Approval?

    private let link = WatchLink.shared
    private let audio = WatchAudio()
    private(set) var callID: UInt32 = 0
    private var callUUID = UUID()
    private var callStartedDate = Date()
    private var callStartedAt: TimeInterval = 0
    private var timers: [Timer] = []
    private var scenePhase: ScenePhase = .active

    // The call from the iPhone
    private var sessionRequests = 0
    private var sessionAt: TimeInterval?
    private var bridgeURL: URL?
    private var grantID: String?
    private var grantRoot: Data?
    private var watchKey: String?
    private var briefing: String?
    private var greeting: String?
    private var voice: String?
    private var relay: WatchToolRelayClient?

    // The connection
    private var socket: WatchBridgeSocket?
    private var stream: WatchAudioBridgeStream?
    private var connection = 0
    private var streamsOpened = 0
    private var live = false
    private var started: WatchAudioBridgeWire.Started?
    private var connectStartedAt: TimeInterval?
    private var socketOpenedAt: TimeInterval?
    private var startSentAt: TimeInterval?
    private var firstStartedAt: TimeInterval?
    private var hostOfflineTries = 0
    private var rejoins = 0
    private var rejoinStartedAt: TimeInterval?
    private var rejoinTimes: [Double] = []
    private var drops = 0
    private var lastPingAt: TimeInterval = 0
    private var pingFailures = 0
    /// This socket's pings failed or unanswered in a row.
    private var pingMisses = 0
    private var pingOutstanding = false
    private var openFailures = 0
    private var hostError: String?
    private var bytesUpBefore = 0
    private var bytesDownBefore = 0

    // Audio session
    private var audioSessionActivated: Bool?
    private var lastActivationAt: TimeInterval?
    private var reactivationStartedAt: TimeInterval?
    private var reactivations = 0
    private var reactivationFailures = 0
    private var reactivationTimes: [Double] = []
    private var restartingAudio = false
    private var restartAttempts = 0
    /// Siri or an alarm stopped the microphone, and nothing has started it
    /// again: the call needs a tap, whatever a reconnect did to the phase.
    private var microphoneStopped = false

    // Uplink
    private var pendingSamples: [Int16] = []
    private var sendsInFlight = 0
    private var chunksUp = 0
    private var chunksDropped = 0
    private var sendFailures = 0
    private var activity = WatchVoiceActivity()
    private var lastPlaybackEndedAt: TimeInterval?

    // Downlink
    private var modelSpeaking = false
    private var suppressingTurn = false
    private var lastLoudAt: TimeInterval?
    /// The audio's dropped-playback count when this call started.
    private var playbackStallsAtStart = 0
    private var leadInSamples: [Int16] = []
    private var audioChunksDown = 0
    private var speechStretches = 0
    private var speechEndAtTurnStart: TimeInterval?
    private var heardAtTurnStart: TimeInterval?
    private var awaitingFirstAudio = false
    private var replyTimes: [Double] = []
    private var heardReplyTimes: [Double] = []
    private var unopened = 0
    private var events: [String: Int] = [:]

    // Conversation
    /// The call's settled lines, for the transcript page and the saved call.
    @Published private(set) var transcript: [WatchVoiceWire.DirectTurn] = []
    /// Lines passed on with a delegation already.
    private var handledLines = 0
    private var userLine = ""
    /// A delegation already took the user's words still being heard: their
    /// line counts as handled when it lands, so it isn't sent again.
    private var openLineDelegated = false
    private var assistantLine = ""
    /// When GPT-Live's transcript of the user's last turn came.
    private var heardAt: TimeInterval?
    private var lastModelTurnEndedAt: TimeInterval?
    private var endRequestedAt: TimeInterval?

    // Delegations and jobs
    private struct Pending {
        var text: String
        var channel: GPTLiveProtocol.Channel
        var delegationID: String?
    }
    /// Answers waiting for a quiet moment.
    private var pendingSends: [Pending] = []
    private var seenDelegations: Set<String> = []
    /// Each delegation's connection: a rejoined session can't take an
    /// answer on the old one's delegations, so those go as session context.
    private var delegationConnection: [String: Int] = [:]
    /// Jobs answering a delegation, by job id.
    private var jobDelegations: [String: String] = [:]
    /// The host's job ids by their number in this call, as GPT-Live names
    /// them in a correction ("Job 2: …", #455).
    private var jobNumbers: [Int: String] = [:]
    private var delegations = 0
    private var delegationsAnswered = 0
    private var relayJobsStarted = 0
    private var lookupsInstead = 0
    private var followUps = 0
    private var followingJobs = false
    private var newsInFlight = false
    private var nextNewsAt: TimeInterval = 0
    private var jobNewsItems = 0
    private var approvals: [WatchJobAnswer.Approval] = []
    private var approvalsShown = 0
    private var approvalsAnswered = 0

    // Liveness and screen
    private var lastTickAt: TimeInterval?
    private var watchSuspendedMs = 0
    private var watchGaps = 0
    private var screenOffSince: TimeInterval?
    private var screenOffSeconds: TimeInterval = 0
    private var lastTimelineAt: TimeInterval?
    private var batteryAtStart: Float = -1

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var isActive: Bool {
        switch phase {
        case .idle, .ended: return false
        default: return true
        }
    }

    init() {
        audio.onCapture = { [weak self] samples, at in self?.captured(samples, at: at) }
        audio.onPlaybackStarted = { [weak self] at in self?.playbackStarted(at: at) }
        audio.onDrained = { [weak self] in self?.playbackDrained() }
        audio.onInterruption = { [weak self] began in self?.audioInterrupted(began: began) }
    }

    // MARK: Controls

    func start() async {
        guard !isActive else { return }
        reset()
        phase = .preparing
        let id = callID
        guard await WatchAudio.requestPermission() else {
            if callID == id { finish(WatchAudioError.permissionDenied.localizedDescription) }
            return
        }
        guard callID == id, phase == .preparing else { return }
        let activated = await activateAudioSession()
        guard callID == id, phase == .preparing else {
            if activated, !isActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            }
            return
        }
        audioSessionActivated = activated
        guard activated else {
            finish(String(localized: "The Watch's audio session didn't start. Try again."))
            return
        }
        lastActivationAt = now
        do {
            try audio.start(options: WatchAudio.Options(activatesSession: false), playbackRate: Self.playbackRate)
        } catch {
            finish(String(localized: "The microphone didn't start: \(error.localizedDescription)"))
            return
        }
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        batteryAtStart = WKInterfaceDevice.current().batteryLevel
        note("bridgeCallStart", [
            "callID": Int(callID),
            "engine": Self.engine,
            "keepAliveMs": Int((now - callStartedAt) * 1000),
            "reachable": link.isReachable,
        ])
        timers = [
            WatchVoiceMain.timer(every: Self.flushInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushUplink() }
            },
            WatchVoiceMain.timer(every: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
        ]
        requestSession()
    }

    func end() {
        guard isActive else { return }
        guard live, endRequestedAt == nil else {
            finish(WatchCallEnd.byUser)
            return
        }
        endRequestedAt = now
        phase = .ending
        audio.stopPlayback()
        send(WatchAudioBridgeWire.end, kind: .control)
    }

    /// The orb: stops GPT-Live while it speaks, brings the microphone back
    /// after Siri or an alarm.
    func tapOrb() {
        if phase == .needsTap || microphoneStopped {
            restartAudio()
            return
        }
        guard modelSpeaking || audio.isPlaying else { return }
        // Playback stops now and the rest of this stretch of speech is
        // dropped; the microphone opens, and GPT-Live stops when it hears
        // the user.
        audio.stopPlayback()
        suppressingTurn = true
        modelSpeaking = false
        lastPlaybackEndedAt = now
        awaitingFirstAudio = false
        if phase == .speaking { phase = .listening }
        note("bridgeInterrupt", ["screen": "\(scenePhase)"])
    }

    func toggleMute() {
        guard isActive else { return }
        isMuted.toggle()
        pendingSamples = []
        activity.reset()
    }

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        let previous = scenePhase
        scenePhase = newPhase
        guard isActive, previous != newPhase else { return }
        if newPhase == .active, let since = screenOffSince {
            screenOffSeconds += now - since
            screenOffSince = nil
        } else if newPhase != .active, screenOffSince == nil {
            screenOffSince = now
        }
        note("bridgeScenePhase", ["phase": "\(newPhase)", "live": live, "reachable": link.isReachable])
    }

    /// The Watch's Approve or Deny for the request on screen.
    func answerApproval(_ approval: WatchJobAnswer.Approval, approve: Bool) {
        // A second quick tap lands after the card moved on: it answers
        // nothing rather than the next command, which the user hasn't read.
        guard pendingApproval == approval, let relay else { return }
        approvals.removeAll { $0 == approval }
        pendingApproval = approvals.first
        let choice = approve ? WatchJobAnswer.approve : WatchJobAnswer.deny
        let id = callID
        Task { [weak self] in
            let outcome = await relay.run(name: WatchJobAnswer.answerApproval, arguments: [
                "job_id": approval.jobID,
                "request_id": approval.requestID,
                "choice": choice,
            ])
            guard let self, self.callID == id, self.isActive else { return }
            // The grant ran out (it isn't renewed: the bridge belongs to it),
            // so no card can be answered from the Watch any more.
            if case .unavailable(let reason, let grantGone, _) = outcome, Self.grantRanOut(reason: reason, grantGone: grantGone) {
                self.note("bridgeApproval", ["choice": choice, "taken": false, "outcome": outcome.label, "reason": reason])
                self.approvalsRanOut()
                return
            }
            var taken = false
            // Hermes answered, and turned it down (already handled, or
            // expired): asking again can't change that.
            var refused = false
            if case .answered(let body) = outcome {
                let result = WatchJobAnswer.result(body: body)
                taken = result["error"] == nil && result["status"] != "failed"
                refused = !taken
            }
            self.note("bridgeApproval", ["choice": choice, "taken": taken, "outcome": outcome.label])
            if taken {
                self.approvalsAnswered += 1
                let what = approve ? "approved" : "denied"
                self.pendingSends.append(Pending(
                    text: "[On their Watch, the user \(what) the command background job \"\(approval.title)\" asked to run.]",
                    channel: .commentary,
                    delegationID: nil
                ))
            } else if !refused, !self.approvals.contains(approval) {
                self.approvals.insert(approval, at: 0)
                self.pendingApproval = self.approvals.first
            }
            self.nextNewsAt = self.now
            self.flushPending()
        }
    }

    /// The grant is spent, closed or about to expire. It isn't renewed (the
    /// bridge belongs to it), so for this call it ran out.
    private static func grantRanOut(reason: String, grantGone: Bool) -> Bool {
        WatchBridgeDelegation.grantRanOut(reason: reason, grantGone: grantGone, sent: false)
    }

    /// As above, for a call that may have gone out: only the relay or
    /// Hermes turning it away for the grant says it didn't run.
    private static func grantRanOut(reason: String, grantGone: Bool, sent: Bool) -> Bool {
        WatchBridgeDelegation.grantRanOut(reason: reason, grantGone: grantGone, sent: sent)
    }

    private func approvalsRanOut() {
        approvals = []
        pendingApproval = nil
        stopFollowingJobs("approvalsRanOut")
        caption = String(localized: "This call's access to Hermes ran out, so it can't answer the job's request.")
    }

    // MARK: The call from the iPhone

    private func requestSession() {
        sessionRequests += 1
        let id = callID
        link.send(.bridgeStart(callID: id, version: WatchVoiceWire.version, engine: Self.engine), reply: { [weak self] answer in
            guard let self, self.callID == id, self.phase == .preparing else { return }
            switch answer {
            case .bridgeSession(_, let session)?:
                self.begin(session)
            case .callRefused(_, let reason)?:
                self.note("bridgeRefused", ["reason": reason])
                self.finish(reason)
            default:
                self.finish(String(localized: "Conduit on the iPhone sent something this Watch app can't read. Update both."))
            }
        }, failure: { [weak self] error in
            guard let self, self.callID == id, self.phase == .preparing else { return }
            self.note("bridgeStartFailed", [
                "error": error.localizedDescription,
                "reachable": self.link.isReachable,
                "attempt": self.sessionRequests,
            ])
            guard self.now - self.callStartedAt < Self.sessionWait else {
                self.finish(String(localized: "Couldn't reach Conduit on your iPhone."))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sessionRetryDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.callID == id, self.phase == .preparing else { return }
                    self.requestSession()
                }
            }
        })
    }

    private func begin(_ session: WatchVoiceWire.BridgeSession) {
        sessionAt = now
        guard let bridge = session.grant.audio,
              let url = URL(string: bridge.url), url.scheme == "wss",
              let root = WatchToolSeal.data(base64URL: session.grant.key), root.count == 32 else {
            finish(String(localized: "The iPhone's GPT-Live call couldn't be read. Update Conduit on both devices."))
            return
        }
        guard bridge.version == Int(WatchAudioBridgeWire.version) else {
            finish(String(localized: "Update the Hermes notifier plugin and Conduit to matching versions."))
            return
        }
        // Delegations, jobs and approvals all go through the grant.
        guard let relayClient = WatchToolRelayClient(session.grant) else {
            finish(String(localized: "The iPhone's GPT-Live call couldn't be read. Update Conduit on both devices."))
            return
        }
        bridgeURL = url
        grantID = session.grant.grantID
        grantRoot = root
        watchKey = session.grant.watchKey
        briefing = session.briefingText
        greeting = session.greeting
        voice = session.voice
        relay = relayClient
        note("bridgeSession", [
            "afterTapMs": Int((now - callStartedAt) * 1000),
            "requests": sessionRequests,
            "briefingBytes": session.briefingBytes,
            "compressedBytes": session.briefing.count,
            "briefingRead": briefing != nil,
            "greeting": greeting != nil,
            "engines": bridge.engines,
            "relayTools": relayClient.tools.sorted(),
            "maxJobs": relayClient.maxJobs,
            "grantExpiresInS": session.grant.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any,
        ])
        phase = .connecting
        connect()
    }

    // MARK: Connection

    private func connect() {
        guard isActive, let bridgeURL, let grantID, let grantRoot, let watchKey else { return }
        // A stream id is taken once per grant, and a grant takes 32.
        guard streamsOpened < 30, let stream = WatchAudioBridgeStream(grantID: grantID, root: grantRoot) else {
            finish(String(localized: "Couldn't reconnect to Hermes."))
            return
        }
        closeSocket()
        streamsOpened += 1
        connection += 1
        let number = connection
        // A host error explains only its own connection's failure.
        hostError = nil
        self.stream = stream
        live = false
        started = nil
        socketOpenedAt = nil
        startSentAt = nil
        connectStartedAt = now
        modelSpeaking = false
        suppressingTurn = false
        leadInSamples = []
        let socket = WatchBridgeSocket(url: bridgeURL, watchKey: watchKey)
        socket.onEvent = { [weak self] kind, fields in self?.socketEvent(number, kind, fields) }
        socket.onMessage = { [weak self] data in self?.received(data, connection: number) }
        self.socket = socket
        lastPingAt = now
    }

    private func socketEvent(_ number: Int, _ kind: String, _ fields: [String: Any]) {
        // A socket already given up on reports its close too.
        guard number == connection, socket != nil, isActive else { return }
        switch kind {
        case "open":
            socketOpenedAt = now
            note("bridgeSocketOpen", [
                "connection": number,
                "ms": connectStartedAt.map { Int((now - $0) * 1000) } as Any,
                "screen": "\(scenePhase)",
            ])
            sendStart()
        case "waiting":
            note("bridgeSocketWaiting", ["connection": number, "screen": "\(scenePhase)"])
        case "close", "complete", "receiveFailed":
            var details = fields
            details["connection"] = number
            details["event"] = kind
            details["live"] = live
            details["screen"] = "\(scenePhase)"
            note("bridgeSocketClosed", details)
            connectionLost(code: fields["code"] as? Int ?? socket?.closeCode, opened: socketOpenedAt != nil)
        default:
            break
        }
    }

    /// The hello in clear, then the sealed start. A rejoined session gets
    /// the conversation so far, and no second greeting.
    private func sendStart() {
        guard let stream else { return }
        socket?.send(WatchAudioBridgeWire.hello(streamID: stream.streamID))
        let rejoining = firstStartedAt != nil
        let history = rejoining
            ? transcript.suffix(Self.historyTurns).map { GPTLiveProtocol.historyItem(role: $0.role.rawValue, text: $0.text) }
            : []
        send(WatchAudioBridgeWire.start(
            engine: Self.engine,
            voice: voice,
            briefing: briefing,
            greeting: rejoining ? nil : greeting,
            history: history
        ), kind: .control)
        startSentAt = now
    }

    /// Counts the socket's data and lets it go; its own close is ignored.
    private func closeSocket() {
        guard let socket else { return }
        bytesUpBefore += socket.bytesUp
        bytesDownBefore += socket.bytesDown
        socket.close()
        self.socket = nil
        startSentAt = nil
        pingMisses = 0
        pingOutstanding = false
    }

    private func connectionLost(code: Int?, opened: Bool) {
        let wasLive = live
        live = false
        closeSocket()
        if endRequestedAt != nil {
            finish(WatchCallEnd.byUser)
            return
        }
        // The call's grant ended: closed on Hermes or the relay, or expired.
        if code == 4010 {
            // An error from before a live session isn't why the grant ended.
            finish((wasLive ? nil : hostError) ?? String(localized: "The call's access to Hermes ended."))
            return
        }
        if !opened { openFailures += 1 }
        // Turned away until the host's bridge reaches the relay.
        if code == 4503, !wasLive, firstStartedAt == nil, hostOfflineTries < Self.hostOfflineRetries {
            hostOfflineTries += 1
            retry(after: 1)
            return
        }
        if let hostError, !wasLive {
            finish(hostError)
            return
        }
        drops += 1
        guard rejoins < Self.maxRejoins else {
            finish(String(localized: "Lost the connection to Hermes."))
            return
        }
        rejoins += 1
        rejoinStartedAt = now
        phase = .reconnecting
        audio.stopPlayback()
        retry(after: 1)
    }

    private func retry(after delay: TimeInterval) {
        let id = callID
        let number = connection
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.callID == id, self.connection == number, self.isActive, self.endRequestedAt == nil else { return }
                self.connect()
            }
        }
    }

    private func received(_ data: Data, connection number: Int) {
        guard number == connection, socket != nil, isActive else { return }
        // The relay's notices go to the host only.
        guard WatchAudioBridgeWire.notice(data) == nil, var stream else { return }
        let opened: (kind: WatchAudioBridgeWire.Kind, plain: Data)
        do {
            opened = try stream.open(data)
            self.stream = stream
        } catch {
            unopened += 1
            if unopened <= 5 { note("bridgeUnopened", ["error": "\(error)", "bytes": data.count]) }
            return
        }
        switch opened.kind {
        case .control:
            if let control = WatchAudioBridgeWire.control(opened.plain) { handle(control) }
        case .event:
            handleEvent(String(decoding: opened.plain, as: UTF8.self))
        case .audio:
            handleAudio(WatchAudioBridgeWire.samples(opened.plain))
        }
    }

    private func handle(_ control: WatchAudioBridgeWire.Control) {
        switch control {
        case .started(let info):
            live = true
            started = info
            hostOfflineTries = 0
            phase = audio.isPlaying ? .speaking : .listening
            let rejoining = firstStartedAt != nil
            if !rejoining { firstStartedAt = now }
            if rejoining, let since = rejoinStartedAt { rejoinTimes.append(now - since) }
            rejoinStartedAt = nil
            note("bridgeStarted", [
                "connection": connection,
                "rejoin": rejoining,
                "afterTapMs": Int((now - callStartedAt) * 1000),
                "afterSocketMs": socketOpenedAt.map { Int((now - $0) * 1000) } as Any,
                "afterStartMs": startSentAt.map { Int((now - $0) * 1000) } as Any,
                "voice": info.voice as Any,
                "inputRate": info.inputRate,
                "outputRate": info.outputRate,
                "briefingApplied": info.briefingApplied,
                "greetingApplied": info.greetingApplied,
            ])
            // The host's rates are fixed for wire version 1; other rates
            // would play at the wrong speed and send mis-framed audio.
            if info.inputRate != Int(Self.captureRate) || info.outputRate != Int(Self.playbackRate) {
                note("bridgeRateMismatch", ["input": info.inputRate, "output": info.outputRate])
                finish(String(localized: "Hermes sends GPT-Live's audio in a format this Watch build can't play. Update Conduit and the conduit_push plugin together."))
                return
            }
            flushPending()
        case .ended(let reason):
            note("bridgeEnded", ["reason": reason as Any, "asked": endRequestedAt != nil, "connection": connection])
            if endRequestedAt != nil {
                finish(nil)
            } else {
                // GPT-Live or the host ended the session: a fresh one,
                // seeded with the conversation, unless the host said why
                // it can't.
                connectionLost(code: nil, opened: true)
            }
        case .error(let code, let message):
            note("bridgeHostError", ["code": code as Any, "message": String(message.prefix(200)), "live": live])
            let text = message.isEmpty ? String(localized: "GPT-Live failed on Hermes.") : message
            switch code ?? "" {
            case "unreachable", "failed":
                // Worth another try once it was working; "ended" follows.
                if firstStartedAt == nil { hostError = text }
            default:
                hostError = text
            }
            if !live, firstStartedAt == nil { finish(text) }
        }
    }

    // MARK: GPT-Live's events

    private func handleEvent(_ text: String) {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String {
            events[type, default: 0] += 1
        }
        guard let event = GPTLiveProtocol.decode(text) else { return }
        switch event {
        case .sessionStarted:
            break
        case .inputTranscript(let words):
            userLine += words
            caption = String(userLine.suffix(120))
        case .outputTranscript(let words):
            assistantLine += words
            caption = String(assistantLine.suffix(120))
        case .turnDone(let role, let words):
            let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
            if role == "user" {
                userLine = ""
                heardAt = now
            } else {
                assistantLine = ""
                lastModelTurnEndedAt = now
            }
            if !text.isEmpty {
                transcript.append(.init(role: role == "user" ? .user : .assistant, text: text, at: Date()))
                caption = String(text.suffix(120))
            }
            if role == "user", openLineDelegated {
                openLineDelegated = false
                if !text.isEmpty { handledLines = transcript.count }
            }
        case .delegation(let id, let text):
            delegated(id: id, itemText: text)
        case .error(let code, let message):
            note("bridgeEngineError", ["code": code as Any, "message": String(message.prefix(200))])
        case .sessionClosed(let reason):
            note("bridgeSessionClosed", ["reason": reason as Any])
        }
    }

    // MARK: Audio

    private func handleAudio(_ samples: [Int16]) {
        audioChunksDown += 1
        guard !samples.isEmpty, endRequestedAt == nil, phase != .needsTap else { return }
        let loud = samples.contains { abs(Int($0)) > Self.speechPeak }
        if loud { lastLoudAt = now }
        let quietFor = lastLoudAt.map { now - $0 } ?? .infinity
        if suppressingTurn {
            // Dropped until this stretch of speech ends.
            if quietFor > Self.speechGap { suppressingTurn = false }
            return
        }
        if modelSpeaking {
            audio.enqueue(samples, sampleRate: Self.playbackRate)
            if quietFor > Self.speechGap { modelSpeaking = false }
            return
        }
        guard loud else {
            leadInSamples.append(contentsOf: samples)
            let keep = Int(Self.playbackRate * Self.leadIn)
            if leadInSamples.count > keep { leadInSamples.removeFirst(leadInSamples.count - keep) }
            return
        }
        // A new stretch of speech.
        modelSpeaking = true
        speechStretches += 1
        if !audio.isPlaying {
            speechEndAtTurnStart = activity.lastVoicedAt
            heardAtTurnStart = heardAt
            heardAt = nil
            awaitingFirstAudio = true
        }
        audio.enqueue(leadInSamples + samples, sampleRate: Self.playbackRate)
        leadInSamples = []
        phase = .speaking
    }

    private func playbackStarted(at audibleAt: TimeInterval) {
        guard awaitingFirstAudio else { return }
        awaitingFirstAudio = false
        var fields: [String: Any] = ["screen": "\(scenePhase)", "connection": connection]
        if let speechEnd = speechEndAtTurnStart, audibleAt > speechEnd, audibleAt - speechEnd < 30 {
            let reply = audibleAt - speechEnd
            replyTimes.append(reply)
            fields["replyMs"] = Int(reply * 1000)
        }
        if let heard = heardAtTurnStart, audibleAt > heard, audibleAt - heard < 30 {
            heardReplyTimes.append(audibleAt - heard)
            fields["heardToAudioMs"] = Int((audibleAt - heard) * 1000)
        }
        speechEndAtTurnStart = nil
        heardAtTurnStart = nil
        note("bridgeTurn", fields)
    }

    /// A stretch of speech whose audio stopped coming: only a quiet chunk
    /// ends one in handleAudio, so with no chunks at all it would read as
    /// speaking, with the microphone held, until GPT-Live spoke again.
    private func endSilentStretchIfDue(at: TimeInterval) {
        // Speech still playing keeps its stretch; a playback that stopped
        // moving is dropped by the audio's stall check first.
        guard modelSpeaking, !audio.isPlaying, let lastLoudAt, at - lastLoudAt >= Self.silentStretch else { return }
        modelSpeaking = false
        note("bridgeSpeechStopped", ["quietMs": Int((at - lastLoudAt) * 1000)])
        playbackDrained()
    }

    private func playbackDrained() {
        lastPlaybackEndedAt = now
        guard isActive, phase == .speaking, !modelSpeaking else { return }
        phase = .listening
        flushPending()
    }

    private func captured(_ samples: [Int16], at time: TimeInterval) {
        guard isActive, live, endRequestedAt == nil, !isMuted, phase != .needsTap, !isMicrophoneHeld else { return }
        activity.process(samples, sampleRate: Self.captureRate, endingAt: time)
        pendingSamples.append(contentsOf: samples)
    }

    /// Half duplex: GPT-Live's voice from the speaker must not read as the
    /// user. The host sends silence meanwhile.
    private var isMicrophoneHeld: Bool {
        if audio.isPlaying || modelSpeaking { return true }
        if let lastPlaybackEndedAt, now - lastPlaybackEndedAt < Self.echoTail { return true }
        return false
    }

    private func flushUplink() {
        guard live, endRequestedAt == nil, !pendingSamples.isEmpty else { return }
        let samples = pendingSamples
        pendingSamples = []
        guard sendsInFlight < Self.sendsInFlightLimit else {
            chunksDropped += 1
            return
        }
        chunksUp += 1
        sendsInFlight += 1
        let id = callID
        send(WatchAudioBridgeWire.pcm(samples), kind: .audio) { [weak self] ok in
            guard let self, self.callID == id else { return }
            self.sendsInFlight = max(0, self.sendsInFlight - 1)
            if !ok { self.sendFailures += 1 }
        }
    }

    private func send(_ plain: Data, kind: WatchAudioBridgeWire.Kind, done: ((Bool) -> Void)? = nil) {
        guard let socket, var stream else {
            done?(false)
            return
        }
        do {
            let message = try stream.seal(plain, kind: kind)
            self.stream = stream
            socket.send(message, done: done)
        } catch {
            note("bridgeSealFailed", ["error": "\(error)", "bytes": plain.count])
            done?(false)
        }
    }

    private func sendEvent(_ message: [String: Any]) {
        guard let text = try? GPTLiveProtocol.encode(message) else { return }
        send(Data(text.utf8), kind: .event)
    }

    private func audioInterrupted(began: Bool) {
        guard isActive, endRequestedAt == nil else { return }
        note("bridgeAudioInterruption", ["began": began, "screen": "\(scenePhase)"])
        if began {
            pendingSamples = []
            activity.reset()
            audio.stopPlayback()
            modelSpeaking = false
            microphoneStopped = true
            // Still waiting for the iPhone's session: its reply, retries and
            // timeout all need .preparing. The tap prompt comes once live.
            if phase != .preparing { phase = .needsTap }
        } else if scenePhase == .active {
            restartAudio()
        }
    }

    /// The session activated again asynchronously first, as at the start;
    /// never with the synchronous call.
    private func restartAudio() {
        guard !restartingAudio, endRequestedAt == nil else { return }
        restartingAudio = true
        restartAttempts += 1
        let attempt = restartAttempts
        let id = callID
        let startedAt = now
        // An activation that never returns would swallow every later tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reactivationTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.restartingAudio, self.restartAttempts == attempt else { return }
                self.restartingAudio = false
                self.note("bridgeAudioRestartHung", ["ms": Int((self.now - startedAt) * 1000)])
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let activated = await self.activateAudioSession()
            // Given up on as hung, and maybe tapped again since: the newer
            // attempt carries on.
            guard self.restartAttempts == attempt, self.restartingAudio else { return }
            self.restartingAudio = false
            guard self.callID == id, self.isActive, self.endRequestedAt == nil else {
                if activated, !self.isActive {
                    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                }
                return
            }
            guard activated else {
                self.note("bridgeAudioRestartFailed", ["error": "activation failed"])
                return
            }
            self.lastActivationAt = self.now
            do {
                try self.audio.start(options: WatchAudio.Options(activatesSession: false), playbackRate: Self.playbackRate)
                self.microphoneStopped = false
                if self.live {
                    self.phase = .listening
                } else if self.phase == .needsTap {
                    self.phase = .reconnecting
                }
            } catch {
                self.note("bridgeAudioRestartFailed", ["error": error.localizedDescription])
            }
        }
    }

    /// Play and record with the default route policy, so the built-in
    /// speaker plays, activated asynchronously (option E).
    private func activateAudioSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        let startedAt = now
        do {
            try session.setCategory(.playAndRecord, mode: .default, policy: .default, options: [])
            let activated = try await session.activate(options: [])
            note("bridgeAudioSession", [
                "activated": activated,
                "ms": Int((now - startedAt) * 1000),
                "outputs": session.currentRoute.outputs.map { $0.portType.rawValue },
            ])
            return activated
        } catch {
            let error = error as NSError
            note("bridgeAudioSession", ["activated": false, "domain": error.domain, "code": error.code])
            return false
        }
    }

    // MARK: Delegations

    /// GPT-Live handed work to the app: a Hermes job through the grant, as
    /// the phone runs one; a web lookup when the user allows no jobs from
    /// the Watch.
    private func delegated(id: String, itemText: String) {
        guard seenDelegations.insert(id).inserted, endRequestedAt == nil else { return }
        delegations += 1
        delegationConnection[id] = connection
        var lines = transcript.enumerated().map { index, turn in
            WatchBridgeDelegation.Line(role: turn.role, text: turn.text, handled: index < handledLines)
        }
        let open = userLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !open.isEmpty { lines.append(.init(role: .user, text: open, handled: false)) }
        handledLines = transcript.count
        openLineDelegated = !open.isEmpty
        let request = WatchBridgeDelegation.request(itemText: itemText, lines: lines)
        let userWords = lines.filter { $0.role == .user && !$0.handled }.map(\.text).joined(separator: " ")
        let ownWords = itemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? userWords : itemText
        note("bridgeDelegation", [
            "hasText": !itemText.isEmpty,
            "requestChars": request.count,
            "jobs": relay?.hasJobs == true,
            "screen": "\(scenePhase)",
        ])
        guard !request.isEmpty else {
            answer(id, WatchBridgeDelegation.noRequest, channel: .speakable)
            return
        }
        guard let relay else {
            answer(id, WatchBridgeDelegation.notStarted("the Watch has no way to reach Hermes for this call."), channel: .speakable)
            return
        }
        // "Job 2: make it Alex" puts the user's words into job 2 while it
        // runs (#455). A number with no job is just new work.
        // Read where the phone reads it: the delegation's own text, else
        // the user's words GPT-Live left it in.
        if let marker = WatchBridgeDelegation.jobMarker(in: ownWords) {
            if let jobID = jobNumbers[marker.number] {
                let words = WatchBridgeDelegation.followUpWords(userWords: userWords, delegated: marker.rest)
                guard !words.isEmpty else {
                    answer(id, WatchBridgeDelegation.noRequest, channel: .speakable)
                    return
                }
                followUp(for: id, jobID: jobID, words: words, relay: relay)
                return
            }
            // A bare "Job 9:" asks for nothing, as on the phone: the user's
            // lines would only repeat the marker.
            let request = marker.rest.isEmpty ? "" : WatchBridgeDelegation.request(itemText: marker.rest, lines: lines)
            guard !request.isEmpty else {
                answer(id, WatchBridgeDelegation.noRequest, channel: .speakable)
                return
            }
            startNewWork(for: id, request: request, ownWords: marker.rest, relay: relay)
            return
        }
        startNewWork(for: id, request: request, ownWords: ownWords, relay: relay)
    }

    private func startNewWork(for id: String, request: String, ownWords: String, relay: WatchToolRelayClient) {
        let tool = relay.hasJobs ? WatchJobAnswer.startJob : WatchToolAnswer.webSearch
        guard relay.tools.contains(tool) else {
            answer(id, WatchBridgeDelegation.notStarted("jobs from the Watch are off in Conduit's Watch settings."), channel: .speakable)
            return
        }
        // The grant's half hour or its calls ran out. Renewing it wouldn't
        // keep the call: the audio bridge belongs to the grant.
        guard relay.canRun(tool) else {
            answer(id, WatchBridgeDelegation.notStarted(WatchBridgeDelegation.grantRanOut), channel: .speakable)
            return
        }
        if relay.hasJobs {
            // Too few calls left to follow a new job's news to its result.
            guard relay.callsLeft >= Self.callsForNewJob else {
                answer(id, WatchBridgeDelegation.notStarted(WatchBridgeDelegation.grantNearlyOut), channel: .speakable)
                return
            }
            guard relayJobsStarted < relay.maxJobs else {
                answer(id, WatchBridgeDelegation.notStarted("this call has started \(relay.maxJobs) jobs, the most the user allows per call. They can raise it in Conduit's Watch settings."), channel: .speakable)
                return
            }
            startJob(for: id, request: request, relay: relay)
        } else {
            lookUp(for: id, query: WatchBridgeDelegation.clipped(ownWords, bytes: 300), relay: relay)
        }
    }

    private func startJob(for delegationID: String, request: String, relay: WatchToolRelayClient) {
        let id = callID
        let sentAt = now
        Task { [weak self] in
            let outcome = await relay.run(name: WatchJobAnswer.startJob, arguments: ["instructions": request])
            guard let self, self.callID == id, self.isActive else { return }
            var fields: [String: Any] = ["outcome": outcome.label, "ms": Int((self.now - sentAt) * 1000), "screen": "\(self.scenePhase)"]
            switch outcome {
            case .answered(let body):
                let result = WatchJobAnswer.result(body: body)
                let status = result["status"] ?? ""
                fields["status"] = status.isEmpty ? (result["error"] == nil ? "" : "error") : status
                if status == "started" || status == "accepted" {
                    self.relayJobsStarted += 1
                    var number: Int?
                    if let jobID = result["job_id"] {
                        self.jobDelegations[jobID] = delegationID
                        // Numbered whatever the host: on an older plugin a
                        // correction then hears that it needs an update,
                        // rather than starting the job again.
                        let next = self.jobNumbers.count + 1
                        self.jobNumbers[next] = jobID
                        number = next
                    }
                    self.answer(delegationID, WatchBridgeDelegation.working(title: result["title"] ?? "Hermes job", number: number), channel: .commentary)
                    self.followJobs()
                } else {
                    let reason = result["message"] ?? result["error"] ?? "Hermes didn't take the job."
                    self.answer(delegationID, WatchBridgeDelegation.notStarted(reason), channel: .speakable)
                }
            case .timedOut:
                // Hermes has it: it may be running.
                self.relayJobsStarted += 1
                self.answer(delegationID, WatchJobAnswer.accepted["message"] ?? "", channel: .commentary)
                self.followJobs()
            case .unavailable(let reason, let grantGone, let sent):
                fields["reason"] = reason
                if Self.grantRanOut(reason: reason, grantGone: grantGone, sent: sent) {
                    self.answer(delegationID, WatchBridgeDelegation.notStarted(WatchBridgeDelegation.grantRanOut), channel: .speakable)
                } else if sent {
                    self.relayJobsStarted += 1
                    self.followJobs()
                    self.answer(delegationID, WatchBridgeDelegation.relay("Hermes didn't confirm the job. Tell the user it may or may not have started."), channel: .speakable)
                } else {
                    self.answer(delegationID, WatchBridgeDelegation.notStarted("Hermes couldn't be reached from the Watch."), channel: .speakable)
                }
            }
            self.note("bridgeJobStart", fields)
        }
    }

    /// A correction to a job this call started, into the job on the host.
    private func followUp(for delegationID: String, jobID: String, words: String, relay: WatchToolRelayClient) {
        followUps += 1
        guard relay.tools.contains(WatchJobAnswer.interruptJob) else {
            answer(delegationID, WatchBridgeDelegation.followUpsUnavailable, channel: .speakable)
            return
        }
        guard relay.canRun(WatchJobAnswer.interruptJob) else {
            answer(delegationID, WatchBridgeDelegation.relay("Hermes didn't get that (\(WatchBridgeDelegation.grantRanOutClause))"), channel: .speakable)
            return
        }
        guard let arguments = WatchJobAnswer.arguments(name: WatchJobAnswer.interruptJob, ["job_id": jobID, "message": words]) else {
            answer(delegationID, WatchBridgeDelegation.noRequest, channel: .speakable)
            return
        }
        let id = callID
        let sentAt = now
        Task { [weak self] in
            let outcome = await relay.run(name: WatchJobAnswer.interruptJob, arguments: arguments)
            guard let self, self.callID == id, self.isActive else { return }
            let result: WatchJobAnswer.FollowUp
            switch outcome {
            case .answered(let body): result = WatchJobAnswer.FollowUp(body: body)
            case .timedOut: result = .failed("it took too long to answer")
            case .unavailable(let reason, let grantGone, let sent):
                result = .failed(Self.grantRanOut(reason: reason, grantGone: grantGone, sent: sent)
                    ? WatchBridgeDelegation.grantRanOutClause
                    : sent ? "Hermes didn't confirm it got the words" : "Hermes couldn't be reached from the Watch")
            }
            let reply = WatchBridgeDelegation.followUpReply(result)
            self.note("bridgeFollowUp", ["outcome": outcome.label, "result": Self.label(result), "ms": Int((self.now - sentAt) * 1000)])
            self.answer(delegationID, reply.text, channel: reply.speakable ? .speakable : .commentary)
        }
    }

    /// The outcome's name for the log: never the words or the title.
    private static func label(_ outcome: WatchJobAnswer.FollowUp) -> String {
        switch outcome {
        case .interrupted: return "interrupted"
        case .queued: return "queued"
        case .finished: return "finished"
        case .failed: return "failed"
        case .unknownJob: return "unknownJob"
        }
    }

    private func lookUp(for delegationID: String, query: String, relay: WatchToolRelayClient) {
        let id = callID
        let sentAt = now
        lookupsInstead += 1
        Task { [weak self] in
            let outcome = await relay.run(name: WatchToolAnswer.webSearch, query: query)
            guard let self, self.callID == id, self.isActive else { return }
            let text: String
            switch outcome {
            case .answered(let body):
                let result = WatchToolAnswer.result(name: WatchToolAnswer.webSearch, body: body)
                text = WatchToolAnswer.fallbackText(for: result) ?? WatchBridgeDelegation.relay("The lookup found nothing.")
            case .timedOut:
                text = WatchBridgeDelegation.relay("The lookup took too long.")
            case .unavailable(let reason, let grantGone, let sent):
                if Self.grantRanOut(reason: reason, grantGone: grantGone, sent: sent) {
                    text = WatchBridgeDelegation.notStarted(WatchBridgeDelegation.grantRanOut)
                } else if sent {
                    text = WatchBridgeDelegation.relay("The lookup got no answer from Hermes.")
                } else {
                    text = WatchBridgeDelegation.relay("Hermes couldn't be reached from the Watch for the lookup.")
                }
            }
            self.note("bridgeLookup", ["outcome": outcome.label, "ms": Int((self.now - sentAt) * 1000)])
            self.answer(delegationID, text, channel: .speakable)
        }
    }

    /// Quiet notes go at once; anything GPT-Live should say waits for a
    /// quiet moment, as on the phone.
    private func answer(_ delegationID: String?, _ text: String, channel: GPTLiveProtocol.Channel) {
        guard !text.isEmpty else { return }
        if delegationID != nil, channel == .speakable { delegationsAnswered += 1 }
        pendingSends.append(Pending(text: text, channel: channel, delegationID: delegationID))
        flushPending()
    }

    private func flushPending() {
        guard live, endRequestedAt == nil, !pendingSends.isEmpty else { return }
        let quiet = isQuiet
        var kept: [Pending] = []
        for item in pendingSends {
            guard item.channel == .commentary || quiet else {
                kept.append(item)
                continue
            }
            // A rejoined session doesn't know the old one's delegations.
            let delegationID = item.delegationID.flatMap { delegationConnection[$0] == connection ? $0 : nil }
            for message in GPTLiveProtocol.contextAppendMessages(item.text, channel: item.channel, delegationID: delegationID) {
                sendEvent(message)
            }
        }
        pendingSends = kept
    }

    private var isQuiet: Bool {
        guard !modelSpeaking, !audio.isPlaying, userLine.isEmpty else { return false }
        if let voiced = activity.lastVoicedAt, now - voiced < Self.userQuietInterval { return false }
        if let ended = lastPlaybackEndedAt, now - ended < Self.modelQuietInterval { return false }
        return true
    }

    // MARK: Jobs

    private func followJobs() {
        followingJobs = true
        nextNewsAt = now
    }

    /// While jobs started through the relay may run, asks Hermes for their
    /// news, wrist up or down: one ask at a time.
    private func fetchJobNewsIfDue() {
        guard followingJobs, !newsInFlight, endRequestedAt == nil, now >= nextNewsAt, let relay else { return }
        // Job news stops before it spends the calls an approval on screen
        // needs; job results still come as notifications.
        guard !relay.isGone, !relay.expires(within: WatchToolRelayClient.expiryMargin),
              relay.callsLeft > Self.callsKeptForApprovals else {
            stopFollowingJobs(relay.isGone ? "grantGone" : "callsOrTimeLow")
            return
        }
        newsInFlight = true
        let id = callID
        Task { [weak self] in
            let outcome = await relay.run(name: WatchJobAnswer.jobNews, arguments: ["wait_s": Self.jobNewsWait])
            guard let self, self.callID == id, self.isActive else { return }
            self.newsInFlight = false
            // News stopped while this was out: its cards can't be answered.
            guard self.followingJobs else { return }
            switch outcome {
            case .answered(let body):
                guard let news = WatchJobAnswer.news(from: body, grantID: relay.grantID) else {
                    self.nextNewsAt = self.now + self.newsPause(Self.jobNewsPause, relay: relay)
                    return
                }
                self.jobNews(news)
                // More waiting comes at once; a quiet poll waits its turn.
                self.nextNewsAt = self.now + (news.items.isEmpty && !news.more ? self.newsPause(Self.jobNewsPause, relay: relay) : Self.jobNewsRetry)
            case .timedOut:
                self.nextNewsAt = self.now + self.newsPause(Self.jobNewsRetry, relay: relay)
            case .unavailable(let reason, let grantGone, _):
                self.note("bridgeJobNewsFailed", ["reason": reason, "grantGone": grantGone])
                if grantGone { self.stopFollowingJobs("grantGone") }
                self.nextNewsAt = self.now + self.newsPause(Self.jobNewsPause, relay: relay)
            }
        }
    }

    /// Job news ends for this call; the jobs' results still come as
    /// notifications, so their count is no longer known.
    private func stopFollowingJobs(_ reason: String) {
        guard followingJobs else { return }
        followingJobs = false
        relayJobsRunning = 0
        note("bridgeJobNewsStopped", ["reason": reason, "callsLeft": relay?.callsLeft as Any])
    }

    /// At least `base`, and spread so the grant's calls last as long as the
    /// grant does (its end ends the call): a job keeps getting news to
    /// the end of the call, later when calls run low.
    private func newsPause(_ base: TimeInterval, relay: WatchToolRelayClient) -> TimeInterval {
        let spare = relay.callsLeft - Self.callsKeptForApprovals
        guard let expiresAt = relay.expiresAt, spare > 0 else { return base }
        return max(base, expiresAt.timeIntervalSinceNow / Double(spare))
    }

    private func jobNews(_ news: WatchJobAnswer.News) {
        relayJobsRunning = news.running
        jobNewsItems += news.items.count
        let open = Set(news.openApprovals.map { "\($0.jobID)\n\($0.requestID)" })
        approvals.removeAll { !open.contains("\($0.jobID)\n\($0.requestID)") }
        var shown = 0
        for item in news.items {
            // A new request replaces the job's last one; news without one
            // leaves the card to the open-requests list above.
            if let approval = item.approval {
                approvals.removeAll { $0.jobID == item.jobID }
                approvals.append(approval)
                approvalsShown += 1
                shown += 1
            }
            // GPT-Live can't answer an approval here: the user taps it.
            guard let text = WatchJobAnswer.notice(for: item, voiceApprovals: false) else { continue }
            let settled = ["finished", "failed", "cancelled"].contains(item.status)
            let delegationID = settled ? jobDelegations.removeValue(forKey: item.jobID) : nil
            pendingSends.append(Pending(text: text, channel: .speakable, delegationID: delegationID))
        }
        pendingApproval = approvals.first
        if shown > 0 { WKInterfaceDevice.current().play(.notification) }
        if !news.items.isEmpty {
            note("bridgeJobNews", [
                "statuses": news.items.map(\.status),
                "resultChars": news.items.map { $0.result?.count ?? 0 },
                "running": news.running,
                "approvalsOnScreen": approvals.count,
                "screen": "\(scenePhase)",
            ])
        }
        if news.running == 0, !news.more, approvals.isEmpty { followingJobs = false }
        flushPending()
    }

    // MARK: Lifecycle

    private func tick() {
        guard isActive else { return }
        let at = now
        if let last = lastTickAt, at - last > 1.5 {
            let missed = Int((at - last - 1) * 1000)
            watchSuspendedMs += missed
            watchGaps += 1
            if watchGaps <= 20 { note("bridgeWatchGap", ["ms": missed, "screen": "\(scenePhase)"]) }
        }
        lastTickAt = at
        // A reconnect moved the phase on while the microphone stayed
        // stopped: the tap that brings it back has to show again.
        if microphoneStopped, endRequestedAt == nil, phase == .listening || phase == .speaking {
            phase = .needsTap
        }
        if phase == .preparing, at - callStartedAt >= Self.sessionWait + 15 {
            finish(String(localized: "Conduit on your iPhone didn't answer."))
            return
        }
        if !live, let sent = startSentAt, at - sent > Self.startedWait {
            note("bridgeStartTimedOut", ["connection": connection])
            startSentAt = nil
            connectionLost(code: nil, opened: true)
            return
        }
        if let endAt = endRequestedAt, at - endAt > Self.endTimeout {
            finish(nil)
            return
        }
        reactivateIfDue()
        audio.checkPlayback()
        endSilentStretchIfDue(at: at)
        pingIfDue()
        fetchJobNewsIfDue()
        flushPending()
        timelineIfDue()
    }

    /// The FB24377808 workaround: the session activated again before
    /// watchOS would revoke the network, 35 to 39 s after an activation.
    private func reactivateIfDue() {
        if let started = reactivationStartedAt, now - started > Self.reactivationTimeout {
            reactivationStartedAt = nil
            reactivationFailures += 1
            note("bridgeReactivateHung", ["ms": Int((now - started) * 1000)])
        }
        guard reactivationStartedAt == nil, !restartingAudio, let last = lastActivationAt, now - last >= Self.reactivateEvery else { return }
        let id = callID
        let startedAt = now
        reactivationStartedAt = startedAt
        let session = AVAudioSession.sharedInstance()
        Task { [weak self] in
            var activated = false
            do {
                activated = try await session.activate(options: [])
            } catch {}
            guard let self else { return }
            guard self.callID == id, self.isActive else {
                if !self.isActive { try? session.setActive(false, options: [.notifyOthersOnDeactivation]) }
                return
            }
            guard self.reactivationStartedAt == startedAt else {
                if activated { self.lastActivationAt = self.now }
                return
            }
            self.reactivationStartedAt = nil
            self.lastActivationAt = self.now
            self.reactivations += 1
            self.reactivationTimes.append(self.now - startedAt)
            if !activated {
                self.reactivationFailures += 1
                self.note("bridgeReactivateFailed", ["ms": Int((self.now - startedAt) * 1000), "screen": "\(self.scenePhase)"])
            }
        }
    }

    private func pingIfDue() {
        guard let socket, now - lastPingAt >= Self.pingInterval else { return }
        lastPingAt = now
        // Unanswered for a whole interval counts as failed: a socket that
        // died without closing (after a suspension) never fails its receive.
        if pingOutstanding {
            missedPing()
            guard self.socket === socket else { return }
        }
        pingOutstanding = true
        socket.ping { [weak self, weak socket] ok in
            guard let self, let socket, self.socket === socket else { return }
            self.pingOutstanding = false
            if ok {
                self.pingMisses = 0
            } else {
                self.missedPing()
            }
        }
    }

    private func missedPing() {
        pingFailures += 1
        pingMisses += 1
        // One miss can be a late pong after a suspension; two in a row is a
        // dead socket. Before the start, the start's own timeout covers it.
        guard pingMisses >= Self.pingMissLimit, live else { return }
        note("bridgeSocketSilent", ["misses": pingMisses, "connection": connection])
        connectionLost(code: nil, opened: true)
    }

    private func timelineIfDue() {
        let at = now
        guard at - (lastTimelineAt ?? callStartedAt) >= Self.timelineInterval else { return }
        lastTimelineAt = at
        note("bridgeTimeline", [
            "sinceStartS": Int(at - callStartedAt),
            "phase": "\(phase)",
            // Why the phase is speaking: speech still arriving, or audio
            // still queued.
            "modelSpeaking": modelSpeaking,
            "playing": audio.isPlaying,
            "live": live,
            "screen": "\(scenePhase)",
            "kbUp": (bytesUpBefore + (socket?.bytesUp ?? 0)) / 1024,
            "kbDown": (bytesDownBefore + (socket?.bytesDown ?? 0)) / 1024,
            "chunksUp": chunksUp,
            "audioChunksDown": audioChunksDown,
            "sendFailures": sendFailures,
            "engine": audio.isEngineRunning,
            "outputs": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue },
        ])
    }

    private func reset() {
        callID = UInt32.random(in: 1...UInt32.max)
        callUUID = UUID()
        callStartedDate = Date()
        callStartedAt = now
        playbackStallsAtStart = audio.playbackStalls
        closeSocket()
        stream = nil
        relay = nil
        caption = nil
        isMuted = false
        relayJobsRunning = 0
        pendingApproval = nil
        sessionRequests = 0
        sessionAt = nil
        bridgeURL = nil
        grantID = nil
        grantRoot = nil
        watchKey = nil
        briefing = nil
        greeting = nil
        voice = nil
        connection = 0
        streamsOpened = 0
        live = false
        started = nil
        connectStartedAt = nil
        socketOpenedAt = nil
        startSentAt = nil
        firstStartedAt = nil
        hostOfflineTries = 0
        rejoins = 0
        rejoinStartedAt = nil
        rejoinTimes = []
        drops = 0
        lastPingAt = 0
        pingFailures = 0
        openFailures = 0
        hostError = nil
        bytesUpBefore = 0
        bytesDownBefore = 0
        audioSessionActivated = nil
        lastActivationAt = nil
        reactivationStartedAt = nil
        reactivations = 0
        reactivationFailures = 0
        reactivationTimes = []
        restartingAudio = false
        microphoneStopped = false
        pendingSamples = []
        sendsInFlight = 0
        chunksUp = 0
        chunksDropped = 0
        sendFailures = 0
        activity = WatchVoiceActivity()
        lastPlaybackEndedAt = nil
        modelSpeaking = false
        suppressingTurn = false
        lastLoudAt = nil
        leadInSamples = []
        audioChunksDown = 0
        speechStretches = 0
        speechEndAtTurnStart = nil
        heardAtTurnStart = nil
        awaitingFirstAudio = false
        replyTimes = []
        heardReplyTimes = []
        unopened = 0
        events = [:]
        transcript = []
        handledLines = 0
        userLine = ""
        openLineDelegated = false
        assistantLine = ""
        heardAt = nil
        lastModelTurnEndedAt = nil
        endRequestedAt = nil
        pendingSends = []
        seenDelegations = []
        delegationConnection = [:]
        jobDelegations = [:]
        jobNumbers = [:]
        delegations = 0
        delegationsAnswered = 0
        followUps = 0
        relayJobsStarted = 0
        lookupsInstead = 0
        followingJobs = false
        newsInFlight = false
        nextNewsAt = 0
        jobNewsItems = 0
        approvals = []
        approvalsShown = 0
        approvalsAnswered = 0
        lastTickAt = nil
        watchSuspendedMs = 0
        watchGaps = 0
        screenOffSince = scenePhase == .active ? nil : now
        screenOffSeconds = 0
        lastTimelineAt = nil
        batteryAtStart = -1
    }

    private func finish(_ reason: String?) {
        guard isActive else { return }
        timers.forEach { $0.invalidate() }
        timers = []
        closeSocket()
        stream = nil
        live = false
        // Ends the grant on the relay and so on Hermes, which ends the
        // bridge; the iPhone revokes it too once the call's end reaches it.
        // Jobs still running keep running in Hermes, and their results
        // come as notifications.
        relay?.close()
        relay = nil
        approvals = []
        pendingApproval = nil
        audio.stop(deactivating: false)
        if audioSessionActivated == true {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        if let since = screenOffSince { screenOffSeconds += now - since }
        phase = .ended(reason)
        let saved = WatchVoiceWire.DirectTranscript.capped(transcript.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let queued = link.queue(.directEnd(callID: callID, transcript: .init(
            callUUID: callUUID.uuidString,
            startedAt: callStartedDate,
            endedAt: Date(),
            turns: saved,
            engine: Self.engine
        )))
        let battery = WKInterfaceDevice.current().batteryLevel
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
        WatchCallLog.shared.report("bridgeCallSummary", [
            "callID": Int(callID),
            "engine": Self.engine,
            "reason": reason as Any,
            "durationS": Int(now - callStartedAt),
            "sessionMs": sessionAt.map { Int(($0 - callStartedAt) * 1000) } as Any,
            "firstStartedMs": firstStartedAt.map { Int(($0 - callStartedAt) * 1000) } as Any,
            "sessionRequests": sessionRequests,
            "playbackStalls": audio.playbackStalls - playbackStallsAtStart,
            "streamsOpened": streamsOpened,
            "openFailures": openFailures,
            "drops": drops,
            "rejoins": rejoins,
            "rejoinMaxMs": WatchVoiceStats.milliseconds(rejoinTimes.max()) as Any,
            "turns": speechStretches,
            "replies": replyTimes.count,
            "replyP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(replyTimes, 0.5)) as Any,
            "replyP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(replyTimes, 0.95)) as Any,
            "heardReplyP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(heardReplyTimes, 0.5)) as Any,
            "heardReplyP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(heardReplyTimes, 0.95)) as Any,
            "delegations": delegations,
            "delegationsAnswered": delegationsAnswered,
            "followUps": followUps,
            "jobsStarted": relayJobsStarted,
            "lookupsInstead": lookupsInstead,
            "jobNewsItems": jobNewsItems,
            "approvalsShown": approvalsShown,
            "approvalsAnswered": approvalsAnswered,
            "unsentAnswers": pendingSends.count,
            "kbUp": bytesUpBefore / 1024,
            "kbDown": bytesDownBefore / 1024,
            "chunksUp": chunksUp,
            "chunksDropped": chunksDropped,
            "sendFailures": sendFailures,
            "pingFailures": pingFailures,
            "unopened": unopened,
            "events": events,
            "reactivations": reactivations,
            "reactivationFailures": reactivationFailures,
            "reactivationMaxMs": WatchVoiceStats.milliseconds(reactivationTimes.max()) as Any,
            "screenOffS": Int(screenOffSeconds),
            "watchSuspendedMs": watchSuspendedMs,
            "watchGaps": watchGaps,
            "transcriptLines": saved.count,
            "transcriptQueued": queued,
            "batteryStart": batteryAtStart,
            "batteryEnd": battery,
        ])
    }

    private func note(_ event: String, _ fields: [String: Any]) {
        WatchCallLog.shared.note(event, fields)
    }
}
