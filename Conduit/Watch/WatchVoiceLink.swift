//
//  WatchVoiceLink.swift
//  Conduit
//
//  The iPhone end of the Apple Watch proof of concept
//  (designs/apple-watch-voice.md). WatchConnectivity carries a Watch call's
//  control messages and audio; the call itself is the profile's Gemini
//  Live or Grok Live conversation, started here with the Watch as its
//  microphone and speaker, so the profile, Hermes connection, tokens,
//  tools, jobs and saved transcript are the phone's own.
//
//  Also answers the Watch's link test and logs how long this app went
//  without running while a call or test was on (the P3 question: does
//  the iPhone app stay alive without its own audio session).
//

import Combine
import Foundation
import UIKit
import WatchConnectivity

@MainActor
final class WatchVoiceLink: ObservableObject {
    static let shared = WatchVoiceLink()

    @Published private(set) var isActivated = false
    @Published private(set) var isPaired = false
    @Published private(set) var isReachable = false
    private(set) var reachabilityChanges = 0

    let log = WatchProbePhoneLog.shared
    let liveness = WatchProbeLiveness()
    private(set) lazy var call = WatchCallHost(link: self)
    private lazy var soak = WatchSoakResponder(link: self)
    private let proxy = PhoneWatchSessionProxy()

    private init() {}

    func activate() {
        guard WCSession.isSupported() else { return }
        proxy.link = self
        WCSession.default.delegate = proxy
        WCSession.default.activate()
    }

    /// The running Watch call's microphone and speaker, for the live
    /// controller's audio selector. Nil when no Watch call is linked.
    func makeLiveAudio() -> LiveVoiceAudioSelector.Pair? {
        call.audioPair
    }

    // MARK: Sending

    func send(_ message: WatchVoiceWire.Message) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(WatchVoiceWire.encode(message), replyHandler: nil) { [weak self] error in
            WatchVoiceMain.async { self?.log.note("sendFailed", ["error": error.localizedDescription]) }
        }
    }

    /// `done` gets the round trip to the Watch's acknowledgement, or nil.
    func send(_ packet: WatchVoicePacket, done: @escaping (TimeInterval?) -> Void) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            done(nil)
            return
        }
        let sentAt = Date()
        session.sendMessageData(packet.encoded(), replyHandler: { _ in
            let roundTrip = Date().timeIntervalSince(sentAt)
            WatchVoiceMain.async { done(roundTrip) }
        }, errorHandler: { _ in
            WatchVoiceMain.async { done(nil) }
        })
    }

    // MARK: Receiving

    fileprivate func sessionChanged(_ session: WCSession, activation: Bool = false) {
        isActivated = session.activationState == .activated
        isPaired = session.isPaired
        let reachable = session.isReachable
        if reachable != isReachable {
            isReachable = reachable
            reachabilityChanges += 1
            if call.isLinked || soak.isRunning {
                log.note("reachability", ["reachable": reachable, "appState": WatchProbeLiveness.appStateName])
            }
        }
        if activation {
            log.note("linkActivated", ["paired": session.isPaired, "watchAppInstalled": session.isWatchAppInstalled])
        }
    }

    fileprivate func received(_ message: WatchVoiceWire.Message, reply: (([String: Any]) -> Void)?) {
        func answer(_ message: WatchVoiceWire.Message) { reply?(WatchVoiceWire.encode(message)) }
        switch message {
        case .callStart(let callID, let fullDuplex, let version):
            // The Watch starts a call only with no link test running, so
            // one still running here lost its stop. It would share the
            // channel with the call's audio: end it first.
            soak.endUnfinished()
            answer(call.start(callID: callID, fullDuplex: fullDuplex, version: version))
        case .ping(let callID):
            if let callID { call.heard(callID) }
            answer(.pong(phase: callID != nil && callID == call.callID ? call.phaseName : nil))
        case .soakStart(let plan):
            // A link test would share the channel with a call's audio.
            guard !call.isLinked else {
                log.note("soakStartRefused", ["runID": Int(plan.runID), "reason": "call"])
                reply?([:])
                return
            }
            soak.start(plan)
            answer(.pong(phase: nil))
        case .soakStop(let runID):
            if let result = soak.stop(runID: runID) {
                answer(.soakResult(result))
            } else {
                reply?([:])
            }
        case .report(let line):
            log.watchReport(line)
            reply?([:])
        case .note(let line):
            log.watchNote(line)
            reply?([:])
        default:
            call.handle(message)
            reply?([:])
        }
    }

    fileprivate func received(_ packet: WatchVoicePacket) {
        switch packet.kind {
        case .callAudio: call.uplink(packet)
        case .soak: soak.received(packet)
        }
    }
}

// MARK: - Call

/// The Watch's call on this side: starts the profile's live mode with
/// the Watch's audio, mirrors its state to the Watch, and routes the
/// Watch's buttons to the controller.
@MainActor
final class WatchCallHost {
    /// No word from the Watch this long ends the call.
    static let silenceLimit: TimeInterval = 120
    /// Captions don't go out more often than this; phase changes do.
    static let captionInterval: TimeInterval = 0.5

    private unowned let link: WatchVoiceLink
    private(set) var callID: UInt32?
    private(set) var fullDuplex = false
    private var mode: CarPlayLiveVoiceMode?
    private var input: WatchLiveVoiceInput?
    private var output: WatchLiveVoiceOutput?
    private weak var controller: GeminiLiveConversationController?
    /// Mute as the Watch last asked, kept for a conversation that is
    /// still starting: its start unmutes.
    private var watchMuted = false
    private var cancellables: Set<AnyCancellable> = []
    private var startedAt = Date()
    private var lastHeardAt = Date()
    private var watchdog: Timer?
    /// The newest call's start. A call that replaces one still starting
    /// waits for it, so the older start's cleanup can't close the newer
    /// call's conversation.
    private var establishing: Task<Void, Never>?
    private var activity = WatchVoiceActivity()
    private var lastTurnStartUptime: TimeInterval?
    private var lastSentState: WatchVoiceWire.CallState?
    private var pendingState: WatchVoiceWire.CallState?
    private var lastStateSentAt = Date.distantPast
    private var stateTimer: Timer?
    private var everActive = false
    private var suspendedAtStart = 0
    private var modelLatencies: [Double] = []
    private var uplinkPackets = 0
    private var uplinkUndecodable = 0
    private var downlinkSent = 0
    private var downlinkFailed = 0
    private var downlinkRoundTrips: [Double] = []
    /// The P3 fallback's CallKit call, made the first time Voice settings
    /// turn it on.
    private var phoneCall: WatchPhoneCall?

    init(link: WatchVoiceLink) {
        self.link = link
    }

    var isLinked: Bool { callID != nil }
    /// The linked call's phase for the Watch's pings; nil once there's
    /// no call, which ends the Watch's side of it.
    var phaseName: String? {
        guard isLinked else { return nil }
        return lastSentState?.phase.rawValue ?? WatchVoiceWire.CallState.Phase.connecting.rawValue
    }
    var millisecondsSinceStart: UInt32 { UInt32(max(0, Date().timeIntervalSince(startedAt) * 1000)) }

    var audioPair: LiveVoiceAudioSelector.Pair? {
        guard isLinked, let input, let output else { return nil }
        return (input, output)
    }

    func start(callID: UInt32, fullDuplex: Bool, version: Int) -> WatchVoiceWire.Message {
        let appState = AppStateRuntimeRegistry.shared.appState
        guard version == WatchVoiceWire.version else {
            return refuse(callID, "Update Conduit on your iPhone and Watch to the same build.")
        }
        if let active = self.callID {
            if active == callID { return .callAccepted(callID: callID, mode: Self.name(mode)) }
            // The Watch app started over: its earlier call is gone.
            finish(reason: "Replaced by a new call from the Watch.", failed: false)
        }
        guard let mode = CarPlayLiveVoiceMode(CarPlayVoiceMode.current(in: appState)), mode != .gptLive else {
            return refuse(callID, WatchVoiceStartFailure.unsupportedMode)
        }
        guard !appState.isLiveVoiceCallActive else {
            return refuse(callID, WatchVoiceStartFailure.callRunning)
        }
        self.callID = callID
        self.fullDuplex = fullDuplex
        self.mode = mode
        startedAt = Date()
        lastHeardAt = Date()
        activity = WatchVoiceActivity()
        lastTurnStartUptime = nil
        lastSentState = nil
        pendingState = nil
        watchMuted = false
        everActive = false
        modelLatencies = []
        uplinkPackets = 0
        uplinkUndecodable = 0
        downlinkSent = 0
        downlinkFailed = 0
        downlinkRoundTrips = []
        // Made now, so speech captured while the call connects is kept.
        input = WatchLiveVoiceInput(host: self)
        output = WatchLiveVoiceOutput(host: self)
        suspendedAtStart = link.liveness.suspendedMs
        link.liveness.begin("call")
        if WatchPhoneCall.isEnabled { startPhoneCall() }
        appState.setWatchVoiceCallActive(true)
        watchdog = WatchVoiceMain.timer(every: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatchdog() }
        }
        link.log.note("watchCallStart", [
            "callID": Int(callID),
            "mode": Self.name(mode),
            "fullDuplex": fullDuplex,
            "appState": WatchProbeLiveness.appStateName,
            "phoneScreen": PhoneScenePresence.isInForeground,
            "connected": appState.isConnected,
            "phoneCall": WatchPhoneCall.isEnabled,
        ])
        let previous = establishing
        establishing = Task { [weak self] in
            await previous?.value
            await self?.establish(appState, mode: mode, callID: callID)
        }
        return .callAccepted(callID: callID, mode: Self.name(mode))
    }

    private func startPhoneCall() {
        let phoneCall = self.phoneCall ?? WatchPhoneCall(log: link.log)
        if self.phoneCall == nil {
            phoneCall.onEndedOnPhone = { [weak self] in
                self?.finish(reason: "Ended on the iPhone.", failed: false)
            }
            self.phoneCall = phoneCall
        }
        phoneCall.start()
    }

    private func establish(_ appState: AppState, mode: CarPlayLiveVoiceMode, callID: UInt32) async {
        let failure = await appState.startLiveVoiceForWatch(mode, stillWanted: { [weak self] in self?.callID == callID })
        guard self.callID == callID else { return }
        if let failure {
            finish(reason: failure, failed: true)
            return
        }
        let controller = mode == .geminiLive ? appState.geminiLiveController : appState.grokLiveController
        self.controller = controller
        if watchMuted { controller.setMicrophoneMuted(true) }
        let jobs = appState.voiceBackgroundJobSupervisor
        controller.$phase
            .combineLatest(controller.$transcript, controller.$isMicrophoneMuted, jobs.$jobs)
            .sink { [weak self, weak jobs] phase, transcript, muted, _ in
                // @Published sends before the value is stored: read on.
                WatchVoiceMain.async {
                    self?.controllerChanged(phase: phase, caption: transcript.last?.text, muted: muted, jobs: jobs?.activeJobCount ?? 0)
                }
            }
            .store(in: &cancellables)
    }

    func handle(_ message: WatchVoiceWire.Message) {
        switch message {
        case .callEnd(let id) where id == callID:
            heard(id)
            finish(reason: "Ended on the Watch.", failed: false)
        case .interrupt(let id) where id == callID:
            heard(id)
            controller?.interruptSpeaking()
        case .mute(let id, let muted) where id == callID:
            heard(id)
            watchMuted = muted
            controller?.setMicrophoneMuted(muted)
        case .paused(let id, let reason) where id == callID:
            heard(id)
            link.log.note("watchPaused", ["reason": reason, "appState": WatchProbeLiveness.appStateName])
            input?.watchPaused()
        case .resumed(let id) where id == callID:
            heard(id)
            link.log.note("watchResumed", ["appState": WatchProbeLiveness.appStateName])
            input?.watchResumed()
        case .drained(let id, let turn, let seq) where id == callID:
            heard(id)
            output?.watchDrained(turn: turn, seq: seq)
        default:
            break
        }
    }

    func heard(_ id: UInt32) {
        guard id == callID else { return }
        lastHeardAt = Date()
    }

    func uplink(_ packet: WatchVoicePacket) {
        guard let callID, packet.callID == callID else { return }
        heard(callID)
        guard packet.codec == .imaADPCM, let samples = IMAADPCM.decode(packet.payload) else {
            uplinkUndecodable += 1
            return
        }
        uplinkPackets += 1
        activity.process(samples, sampleRate: Double(packet.sampleRate), endingAt: ProcessInfo.processInfo.systemUptime)
        input?.receive(WatchVoicePCM.data(samples))
    }

    /// The model started answering: how long it took here, from the end
    /// of the user's speech as it arrived from the Watch.
    func modelTurnStarted(_ turn: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTurnStartUptime = now }
        guard let callID, let voicedAt = activity.lastVoicedAt else { return }
        let latency = now - voicedAt
        // Split so `latency < 30, voicedAt >` can't parse as generics.
        guard latency > 0, latency < 30 else { return }
        guard voicedAt > (lastTurnStartUptime ?? 0) else { return }
        modelLatencies.append(latency)
        link.send(.turnMetrics(callID: callID, turn: turn, modelLatencyMs: Int(latency * 1000)))
    }

    func stopWatchPlayback(turn: UInt32) {
        guard let callID else { return }
        link.send(.stopPlayback(callID: callID, turn: turn))
    }

    func send(_ packet: WatchVoicePacket, done: @escaping (Bool) -> Void) {
        downlinkSent += 1
        let id = callID
        link.send(packet) { [weak self] roundTrip in
            // Acks that straddle a replacement belong to the earlier call.
            if let self, self.callID == id {
                if let roundTrip {
                    self.downlinkRoundTrips.append(roundTrip)
                } else {
                    self.downlinkFailed += 1
                }
            }
            done(roundTrip != nil)
        }
    }

    private func controllerChanged(phase: GeminiLiveConversationController.Phase, caption: String?, muted: Bool, jobs: Int) {
        guard let callID, let mode else { return }
        let mapped: WatchVoiceWire.CallState.Phase
        var detail: String?
        switch phase {
        case .idle:
            // Before the call first connects, idle is just "not yet".
            guard everActive else { return }
            mapped = .ended
        case .connecting: mapped = .connecting
        case .listening: mapped = .listening
        case .speaking: mapped = .speaking
        case .paused: mapped = .paused
        case .reconnecting: mapped = .reconnecting
        case .ending: mapped = .ending
        case .failed(let message):
            mapped = .failed
            detail = message
        }
        if mapped != .ended { everActive = true }
        let state = WatchVoiceWire.CallState(
            callID: callID,
            phase: mapped,
            detail: detail,
            caption: caption.map { String($0.suffix(140)) },
            mode: Self.name(mode),
            jobs: jobs,
            muted: muted
        )
        switch mapped {
        case .ended:
            finish(reason: nil, failed: false)
        case .failed:
            finish(reason: detail, failed: true)
        default:
            sendState(state)
        }
    }

    /// Phase changes go out at once; caption-only changes at most twice a
    /// second, so a streamed transcript doesn't flood the link.
    private func sendState(_ state: WatchVoiceWire.CallState) {
        guard state != lastSentState else { return }
        let phaseChanged = state.phase != lastSentState?.phase || state.muted != lastSentState?.muted
        if phaseChanged || Date().timeIntervalSince(lastStateSentAt) >= Self.captionInterval {
            stateTimer?.invalidate()
            stateTimer = nil
            pendingState = nil
            lastSentState = state
            lastStateSentAt = Date()
            link.send(.callState(state))
            return
        }
        pendingState = state
        guard stateTimer == nil else { return }
        stateTimer = WatchVoiceMain.timer(every: Self.captionInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stateTimer = nil
                if let pending = self.pendingState { self.sendState(pending) }
            }
        }
    }

    private func checkWatchdog() {
        guard isLinked, Date().timeIntervalSince(lastHeardAt) > Self.silenceLimit else { return }
        finish(reason: "Conduit lost the Watch.", failed: true)
    }

    private func finish(reason: String?, failed: Bool) {
        guard let callID, let mode else { return }
        // Cleared first: closing the conversation below reports the end
        // back through the controller observation.
        cancellables.removeAll()
        self.callID = nil
        watchdog?.invalidate()
        watchdog = nil
        stateTimer?.invalidate()
        stateTimer = nil
        let finalState = WatchVoiceWire.CallState(
            callID: callID,
            phase: failed ? .failed : .ended,
            detail: reason,
            caption: lastSentState?.caption,
            mode: Self.name(mode),
            jobs: 0,
            muted: false
        )
        link.send(.callState(finalState))
        let appState = AppStateRuntimeRegistry.shared.appState
        appState.finishLiveVoiceForWatch(mode)
        input?.stop()
        output?.stop()
        input = nil
        output = nil
        phoneCall?.end()
        link.liveness.end("call")
        link.log.summary("watchCallSummary", [
            "callID": Int(callID),
            "mode": Self.name(mode),
            "failed": failed,
            "reason": reason as Any,
            "durationS": Int(Date().timeIntervalSince(startedAt)),
            "turns": modelLatencies.count,
            "modelP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(modelLatencies, 0.5)) as Any,
            "modelP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(modelLatencies, 0.95)) as Any,
            "uplinkPackets": uplinkPackets,
            "uplinkUndecodable": uplinkUndecodable,
            "downlinkSent": downlinkSent,
            "downlinkFailed": downlinkFailed,
            "downlinkRttP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(downlinkRoundTrips, 0.5)) as Any,
            "downlinkRttP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(downlinkRoundTrips, 0.95)) as Any,
            "phoneSuspendedMs": link.liveness.suspendedMs - suspendedAtStart,
            "appState": WatchProbeLiveness.appStateName,
        ])
    }

    private func refuse(_ callID: UInt32, _ reason: String) -> WatchVoiceWire.Message {
        link.log.note("watchCallRefused", ["reason": reason])
        return .callRefused(callID: callID, reason: reason)
    }

    static func name(_ mode: CarPlayLiveVoiceMode?) -> String {
        switch mode {
        case .geminiLive?: return "Gemini Live"
        case .grokLive?: return "Grok Live"
        case .gptLive?: return "GPT-Live"
        case nil: return "Live"
        }
    }
}

// MARK: - Link test

/// The iPhone's half of the Watch's link test: sends the plan's packets
/// back at the same rate and measures what arrives.
@MainActor
final class WatchSoakResponder {
    private unowned let link: WatchVoiceLink
    private var plan: WatchVoiceWire.SoakPlan?
    private var timer: Timer?
    private var startedAt = Date()
    private var seq: UInt32 = 0
    private var inFlight = 0
    private var owed = 0
    private var sent = 0
    private var acked = 0
    private var failed = 0
    private var merged = 0
    private var roundTrips: [Double] = []
    private var receivedCount = 0
    private var lastReceivedAt: TimeInterval?
    private var gaps: [Double] = []
    private var reachabilityAtStart = 0
    private var suspendedAtStart = 0

    init(link: WatchVoiceLink) {
        self.link = link
    }

    var isRunning: Bool { plan != nil }

    /// Ends a test whose stop never arrived.
    func endUnfinished() {
        guard let plan else { return }
        link.log.note("soakEndedUnfinished", ["runID": Int(plan.runID)])
        _ = stop(runID: plan.runID)
    }

    func start(_ plan: WatchVoiceWire.SoakPlan) {
        endUnfinished()
        self.plan = plan
        startedAt = Date()
        seq = 0
        inFlight = 0
        owed = 0
        sent = 0
        acked = 0
        failed = 0
        merged = 0
        roundTrips = []
        receivedCount = 0
        lastReceivedAt = nil
        gaps = []
        reachabilityAtStart = link.reachabilityChanges
        suspendedAtStart = link.liveness.suspendedMs
        link.liveness.begin("soak")
        link.log.note("soakStart", ["runID": Int(plan.runID), "label": plan.label, "appState": WatchProbeLiveness.appStateName])
        timer = WatchVoiceMain.timer(every: plan.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func received(_ packet: WatchVoicePacket) {
        guard let plan, packet.callID == plan.runID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        receivedCount += 1
        if let lastReceivedAt { gaps.append(now - lastReceivedAt) }
        lastReceivedAt = now
    }

    func stop(runID: UInt32) -> WatchVoiceWire.SoakResult? {
        guard let plan, plan.runID == runID else { return nil }
        timer?.invalidate()
        timer = nil
        self.plan = nil
        link.liveness.end("soak")
        let result = WatchVoiceWire.SoakResult(
            side: "phone",
            runID: plan.runID,
            label: plan.label,
            sent: sent,
            acked: acked,
            failed: failed,
            merged: merged,
            rttP50Ms: WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(roundTrips, 0.5)),
            rttP95Ms: WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(roundTrips, 0.95)),
            rttP99Ms: WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(roundTrips, 0.99)),
            rttMaxMs: WatchVoiceStats.milliseconds(roundTrips.max()),
            received: receivedCount,
            maxGapMs: WatchVoiceStats.milliseconds(gaps.max()),
            stallsOver1s: gaps.filter { $0 > 1 }.count,
            reachabilityChanges: link.reachabilityChanges - reachabilityAtStart,
            suspendedMs: link.liveness.suspendedMs - suspendedAtStart,
            errors: []
        )
        link.log.summary("soakPhoneSummary", [
            "runID": Int(plan.runID),
            "label": plan.label,
            "sent": result.sent,
            "acked": result.acked,
            "failed": result.failed,
            "merged": result.merged,
            "rttP50Ms": result.rttP50Ms as Any,
            "rttP95Ms": result.rttP95Ms as Any,
            "rttP99Ms": result.rttP99Ms as Any,
            "received": result.received,
            "maxGapMs": result.maxGapMs as Any,
            "stallsOver1s": result.stallsOver1s,
            "reachabilityChanges": result.reachabilityChanges,
            "suspendedMs": result.suspendedMs,
        ])
        return result
    }

    private func tick() {
        guard let plan else { return }
        // A test whose stop never arrived ends on its own.
        if Date().timeIntervalSince(startedAt) > plan.duration + 60 {
            _ = stop(runID: plan.runID)
            return
        }
        owed += 1
        guard inFlight < plan.maxInFlight else { return }
        let count = owed
        owed = 0
        if count > 1 { merged += count - 1 }
        seq &+= 1
        let packet = WatchVoicePacket(
            kind: .soak,
            codec: .none,
            callID: plan.runID,
            seq: seq,
            sampleRate: 0,
            sentAtMs: UInt32(Date().timeIntervalSince(startedAt) * 1000),
            payload: Data(count: min(60_000, plan.downBytes * count))
        )
        inFlight += 1
        sent += 1
        let runID = plan.runID
        link.send(packet) { [weak self] roundTrip in
            // Acks that straddle a restart belong to the earlier run.
            guard let self, self.plan?.runID == runID else { return }
            self.inFlight = max(0, self.inFlight - 1)
            if let roundTrip {
                self.acked += 1
                self.roundTrips.append(roundTrip)
            } else {
                self.failed += 1
            }
        }
    }
}

// MARK: - Liveness

/// Whether this app kept running during a Watch call or link test: a
/// one-second ticker whose late ticks are time the app was suspended.
/// The continuous clock keeps counting while the iPhone sleeps, which
/// uptime doesn't: a locked phone's suspension would read short.
@MainActor
final class WatchProbeLiveness: ObservableObject {
    /// A Watch call or link test is running: the iPhone holds off
    /// auto-lock while Conduit is on screen, so "iPhone unlocked" tests
    /// stay unlocked.
    @Published private(set) var isRunning = false
    private var reasons: Set<String> = []
    private var timer: Timer?
    private var lastTick = ContinuousClock.now
    private var ticksSinceStateLog = 0
    private(set) var suspendedMs = 0

    static var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    func begin(_ reason: String) {
        reasons.insert(reason)
        isRunning = true
        guard timer == nil else { return }
        lastTick = ContinuousClock.now
        timer = WatchVoiceMain.timer(every: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func end(_ reason: String) {
        reasons.remove(reason)
        guard reasons.isEmpty else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ContinuousClock.now
        let elapsed = (now - lastTick).components
        let gap = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        lastTick = now
        if gap > 1.5 {
            let missed = Int((gap - 1) * 1000)
            suspendedMs += missed
            WatchProbePhoneLog.shared.note("phoneGap", ["ms": missed, "appState": Self.appStateName])
        }
        ticksSinceStateLog += 1
        if ticksSinceStateLog >= 30 {
            ticksSinceStateLog = 0
            let remaining = UIApplication.shared.backgroundTimeRemaining
            WatchProbePhoneLog.shared.note("phoneAlive", [
                "appState": Self.appStateName,
                "backgroundTimeRemainingS": remaining.isFinite && remaining < 1e6 ? Int(remaining) : -1,
                "reasons": Array(reasons).sorted(),
            ])
        }
    }
}

// MARK: - WCSession delegate

/// WCSession's delegate, off the main actor: acknowledges audio at once
/// (the Watch's flow control waits on it) and hands everything else to
/// the link in order.
private final class PhoneWatchSessionProxy: NSObject, WCSessionDelegate {
    weak var link: WatchVoiceLink?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        WatchVoiceMain.async { [weak self] in self?.link?.sessionChanged(session, activation: true) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Another Watch was chosen: start talking to it.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        WatchVoiceMain.async { [weak self] in self?.link?.sessionChanged(session) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        WatchVoiceMain.async { [weak self] in self?.link?.sessionChanged(session) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = WatchVoiceWire.decode(message) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(decoded, reply: nil) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let decoded = WatchVoiceWire.decode(message) else {
            replyHandler([:])
            return
        }
        WatchVoiceMain.async { [weak self] in
            guard let link = self?.link else {
                replyHandler([:])
                return
            }
            link.received(decoded, reply: replyHandler)
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let packet = WatchVoicePacket(data: messageData) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(packet) }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        replyHandler(Data())
        guard let packet = WatchVoicePacket(data: messageData) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(packet) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let decoded = WatchVoiceWire.decode(userInfo) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(decoded, reply: nil) }
    }
}
