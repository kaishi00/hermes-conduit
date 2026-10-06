//
//  WatchCallModel.swift
//  Conduit Watch
//
//  A live voice call from the wrist: the Watch is the iPhone's remote
//  microphone and speaker. The iPhone runs the call itself (Gemini Live or
//  Grok Live, with the profile, tools and jobs); the Watch streams its
//  microphone as IMA ADPCM packets about four times a second and plays the
//  model's speech as it arrives.
//
//  Half duplex unless voice processing is on: while the Watch plays, and
//  for a short echo tail after, its microphone isn't sent.
//
//  Also measures the proof of concept's numbers (designs/apple-watch-voice.md,
//  P3/P4): start time, each turn's end of speech to first audible reply on
//  the Watch, the model's own share of that on the iPhone, link round
//  trips and battery.
//

import Foundation
import SwiftUI
import WatchKit

@MainActor
final class WatchCallModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case live(WatchVoiceWire.CallState.Phase)
        case unreachable
        case needsTap
        case ended(String?)
    }

    static let packetInterval: TimeInterval = 0.25
    static let maxInFlight = 3
    static let echoTail: TimeInterval = 0.35
    static let pingInterval: TimeInterval = 2
    static let downlinkRate: Double = 24_000

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var caption: String?
    @Published private(set) var mode: String?
    @Published private(set) var isMuted = false
    @Published private(set) var jobs = 0
    @Published private(set) var lastTurnSummary: String?
    @Published var fullDuplex = false
    @Published var keepStreamingWristDown = false

    private let link = WatchLink.shared
    private let audio = WatchAudio()
    private var callID: UInt32 = 0
    private var callStartedAt: TimeInterval = 0
    private var acceptedAt: TimeInterval?
    private var startInFlight = false
    /// The call's phase as the iPhone last reported it.
    private var phonePhase: WatchVoiceWire.CallState.Phase?
    private var listeningAt: TimeInterval?
    private var batteryAtStart: Float = -1

    // Uplink
    private var encoder = IMAADPCM.Encoder()
    private var pendingSamples: [Int16] = []
    private var uplinkSeq: UInt32 = 0
    private var inFlight = 0
    private var lastSendAt: TimeInterval = 0
    private var micPaused = false
    /// A mute the iPhone hasn't echoed yet, and a resume that didn't
    /// reach it.
    private var muteUnconfirmed = false
    private var resumeUnsent = false
    /// Why the Watch paused, while that pause hasn't reached the iPhone.
    private var pauseUnsent: String?
    private var lastPlaybackEndedAt: TimeInterval?
    private var activity = WatchVoiceActivity()
    private var uplinkSent = 0
    private var uplinkAcked = 0
    private var uplinkFailed = 0
    private var uplinkMerged = 0
    private var uplinkRoundTrips: [Double] = []

    // Downlink
    private var currentTurn: UInt32 = 0
    private var stoppedTurn: UInt32 = 0
    private var lastDownlinkSeq: UInt32 = 0
    private var downlinkReceived = 0
    private var lastDownlinkAt: TimeInterval?
    private var maxDownlinkGap: TimeInterval = 0
    private var turnSpeechEnd: [UInt32: TimeInterval] = [:]
    /// The speech end the last timed turn answered: a turn with no newer
    /// speech (a job result, an opening) is not a reply and isn't timed.
    private var lastTimedSpeechEnd: TimeInterval?
    private var turnEndToEnd: [UInt32: TimeInterval] = [:]
    private var turnModelLatency: [UInt32: TimeInterval] = [:]
    private var awaitingFirstAudio: UInt32?

    // Health
    private var pingFailures = 0
    private var pingRoundTrips: [Double] = []
    private var timers: [Timer] = []
    private var scenePhase: ScenePhase = .active

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
        resetCall()
        phase = .starting
        guard await WatchAudio.requestPermission() else {
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
            phase = .ended(WatchAudioError.permissionDenied.localizedDescription)
            return
        }
        do {
            try audio.start(options: .init(voiceProcessing: fullDuplex), playbackRate: Self.downlinkRate)
        } catch {
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
            phase = .ended("The microphone didn't start: \(error.localizedDescription)")
            WatchProbeLog.shared.note("callAudioFailed", ["error": error.localizedDescription])
            return
        }
        link.onMessage = { [weak self] in self?.received($0) }
        link.onCallPacket = { [weak self] in self?.received($0) }
        link.onReachabilityChange = { [weak self] reachable in self?.reachabilityChanged(reachable) }
        WatchProbeLog.shared.note("callStart", ["callID": Int(callID), "fullDuplex": fullDuplex, "reachable": link.isReachable])
        sendStart()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushUplink() }
            },
            Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.ping() }
            },
        ]
    }

    /// Tap on the orb while the model speaks: stop it here at once, and
    /// on the iPhone.
    func interrupt() {
        // Nothing to stop until the iPhone's call is live.
        guard case .live = phase else { return }
        let started = now
        audio.stopPlayback()
        stoppedTurn = currentTurn
        lastPlaybackEndedAt = now
        link.send(.interrupt(callID: callID))
        WatchProbeLog.shared.note("callInterrupt", ["turn": Int(currentTurn), "localStopMs": Int((now - started) * 1000)])
    }

    func toggleMute() {
        guard isActive else { return }
        isMuted.toggle()
        // The model never heard speech from before or during a mute: a
        // turn after it is timed from new speech only.
        activity.reset()
        sendMute()
    }

    /// "Tap to continue": watchOS lets recording restart only from a tap
    /// in the foreground.
    func continueAfterInterruption() {
        guard phase == .needsTap else { return }
        do {
            try audio.start(options: .init(voiceProcessing: fullDuplex), playbackRate: Self.downlinkRate)
            micPaused = false
            if acceptedAt == nil {
                // Interrupted before the iPhone took the call: ask again.
                phase = .starting
                sendStart()
            } else {
                phase = .live(phonePhase ?? .connecting)
            }
            sendResumed()
            WatchProbeLog.shared.note("callResumedByTap", ["accepted": acceptedAt != nil])
        } catch {
            WatchProbeLog.shared.note("callResumeFailed", ["error": error.localizedDescription])
        }
    }

    func end() {
        guard isActive else { return }
        link.send(.callEnd(callID: callID))
        finish(reason: "ended on the Watch")
    }

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        let previous = scenePhase
        scenePhase = newPhase
        guard isActive, previous != newPhase else { return }
        WatchProbeLog.shared.note("callScenePhase", ["phase": "\(newPhase)", "reachable": link.isReachable])
        if newPhase == .active {
            guard micPaused, audio.isRunning, phase != .needsTap else { return }
            micPaused = false
            sendResumed()
        } else if !keepStreamingWristDown, !micPaused {
            // The link to the iPhone only holds with the wrist up: stop
            // sending, keep playing what's here.
            micPaused = true
            pendingSamples = []
            // As with mute: a later turn is timed from new speech only.
            activity.reset()
            sendPaused("wristDown")
        }
    }

    // MARK: Uplink

    private func captured(_ samples: [Int16], at time: TimeInterval) {
        guard isActive, !micPaused, !isMuted, !isMicrophoneHeld else { return }
        activity.process(samples, sampleRate: WatchAudio.captureRate, endingAt: time)
        pendingSamples.append(contentsOf: samples)
    }

    /// Half duplex: the model's own voice from the speaker must not read
    /// as the user.
    private var isMicrophoneHeld: Bool {
        guard !fullDuplex else { return false }
        if audio.isPlaying { return true }
        if let lastPlaybackEndedAt, now - lastPlaybackEndedAt < Self.echoTail { return true }
        return false
    }

    private func flushUplink() {
        guard isActive, !pendingSamples.isEmpty else { return }
        let pendingDuration = Double(pendingSamples.count) / WatchAudio.captureRate
        guard pendingDuration >= Self.packetInterval || now - lastSendAt >= Self.packetInterval * 2 else { return }
        // Audio can overtake an unanswered callStart and be dropped; it
        // waits here (two seconds at most) until the iPhone takes the call.
        guard inFlight < Self.maxInFlight, acceptedAt != nil else {
            // Folded into the next packet instead of queueing more sends;
            // never more than two seconds held.
            let limit = Int(WatchAudio.captureRate * 2)
            if pendingSamples.count > limit { pendingSamples.removeFirst(pendingSamples.count - limit) }
            return
        }
        if pendingDuration >= Self.packetInterval * 1.5 { uplinkMerged += 1 }
        let samples = pendingSamples
        pendingSamples = []
        uplinkSeq &+= 1
        let packet = WatchVoicePacket(
            kind: .callAudio,
            codec: .imaADPCM,
            callID: callID,
            seq: uplinkSeq,
            sampleRate: UInt32(WatchAudio.captureRate),
            sentAtMs: UInt32(max(0, (now - callStartedAt) * 1000)),
            payload: encoder.encode(samples)
        )
        inFlight += 1
        uplinkSent += 1
        lastSendAt = now
        let id = callID
        link.send(packet) { [weak self] result in
            // Acks that straddle a new call belong to the earlier one.
            guard let self, self.callID == id else { return }
            self.inFlight = max(0, self.inFlight - 1)
            switch result {
            case .success(let roundTrip):
                self.uplinkAcked += 1
                self.uplinkRoundTrips.append(roundTrip)
            case .failure(let error):
                self.uplinkFailed += 1
                if self.uplinkFailed <= 5 || self.uplinkFailed % 20 == 0 {
                    WatchProbeLog.shared.note("uplinkFailed", ["error": error.localizedDescription, "count": self.uplinkFailed, "scene": "\(self.scenePhase)"])
                }
            }
        }
    }

    // MARK: Downlink

    private func received(_ packet: WatchVoicePacket) {
        guard isActive, packet.callID == callID, packet.kind == .callAudio else { return }
        let arrived = now
        downlinkReceived += 1
        if let lastDownlinkAt { maxDownlinkGap = max(maxDownlinkGap, arrived - lastDownlinkAt) }
        lastDownlinkAt = arrived
        // An interrupted turn's leftovers.
        guard packet.turn > stoppedTurn else { return }
        guard packet.codec == .imaADPCM, let samples = IMAADPCM.decode(packet.payload) else { return }
        if packet.turn != currentTurn {
            currentTurn = packet.turn
            // The end of what the user said before this answer.
            if let voicedAt = activity.lastVoicedAt, voicedAt > (lastTimedSpeechEnd ?? 0) {
                turnSpeechEnd[packet.turn] = voicedAt
                lastTimedSpeechEnd = voicedAt
            }
            awaitingFirstAudio = packet.turn
        }
        lastDownlinkSeq = packet.seq
        audio.enqueue(samples, sampleRate: Double(packet.sampleRate))
    }

    private func playbackStarted(at audibleAt: TimeInterval) {
        guard let turn = awaitingFirstAudio else { return }
        awaitingFirstAudio = nil
        if let speechEnd = turnSpeechEnd[turn], audibleAt > speechEnd, audibleAt - speechEnd < 30 {
            turnEndToEnd[turn] = audibleAt - speechEnd
        }
        summarizeTurn(turn)
    }

    private func playbackDrained() {
        lastPlaybackEndedAt = now
        guard isActive else { return }
        link.send(.drained(callID: callID, turn: currentTurn, seq: lastDownlinkSeq))
    }

    private func summarizeTurn(_ turn: UInt32) {
        let endToEnd = turnEndToEnd[turn]
        let model = turnModelLatency[turn]
        var parts: [String] = []
        if let endToEnd { parts.append(String(format: "reply %.1fs", endToEnd)) }
        if let endToEnd, let model { parts.append(String(format: "watch +%.1fs", endToEnd - model)) }
        if !parts.isEmpty { lastTurnSummary = parts.joined(separator: " · ") }
        guard endToEnd != nil || model != nil else { return }
        WatchProbeLog.shared.note("callTurn", [
            "callID": Int(callID),
            "turn": Int(turn),
            "endToEndMs": WatchVoiceStats.milliseconds(endToEnd) as Any,
            "modelMs": WatchVoiceStats.milliseconds(model) as Any,
            "watchOverheadMs": WatchVoiceStats.milliseconds(endToEnd.flatMap { e in model.map { e - $0 } }) as Any,
        ])
    }

    // MARK: Control messages

    /// Asks the iPhone for the call; again on each ping tick until it
    /// answers. The same call ID makes a repeat harmless.
    private func sendStart() {
        guard acceptedAt == nil, !startInFlight, phase == .starting || phase == .unreachable else { return }
        startInFlight = true
        let id = callID
        link.send(.callStart(callID: id, fullDuplex: fullDuplex, version: WatchVoiceWire.version), reply: { [weak self] answer in
            guard let self, self.callID == id else { return }
            self.startInFlight = false
            self.startAnswered(answer)
        }, failure: { [weak self] error in
            guard let self, self.callID == id else { return }
            self.startInFlight = false
            guard self.phase == .starting || self.phase == .unreachable else { return }
            WatchProbeLog.shared.note("callStartFailed", ["error": error.localizedDescription])
            self.phase = .unreachable
        })
    }

    private func startAnswered(_ answer: WatchVoiceWire.Message?) {
        // An answer that lands while paused for a tap still counts.
        guard phase == .starting || phase == .unreachable || phase == .needsTap else {
            WatchProbeLog.shared.note("callStartAnswerIgnored", ["phase": "\(phase)"])
            return
        }
        switch answer {
        case .callAccepted(let id, let mode)? where id == callID:
            acceptedAt = now
            self.mode = mode
            if phase != .needsTap { phase = .live(.connecting) }
            WatchProbeLog.shared.note("callAccepted", ["mode": mode, "afterMs": Int((now - callStartedAt) * 1000)])
        case .callRefused(let id, let reason)? where id == callID:
            WatchProbeLog.shared.note("callRefused", ["reason": reason])
            finish(reason: reason)
        default:
            WatchProbeLog.shared.note("callStartUnreadable")
            finish(reason: "Conduit on your iPhone didn't understand the request. Update both apps.")
        }
    }

    private func received(_ message: WatchVoiceWire.Message) {
        switch message {
        case .callState(let state) where state.callID == callID && isActive:
            caption = state.caption
            mode = state.mode
            jobs = state.jobs
            // A mute the iPhone hasn't echoed yet stays the Watch's.
            if !muteUnconfirmed {
                isMuted = state.muted
            } else if state.muted == isMuted {
                muteUnconfirmed = false
            }
            switch state.phase {
            case .ended, .failed:
                finish(reason: state.detail)
            default:
                phonePhase = state.phase
                if phase != .needsTap { phase = .live(state.phase) }
                if state.phase == .listening, listeningAt == nil {
                    listeningAt = now
                    WatchProbeLog.shared.note("callListening", ["afterMs": Int((now - callStartedAt) * 1000)])
                }
            }
        case .stopPlayback(let id, let turn) where id == callID:
            stoppedTurn = max(stoppedTurn, turn)
            if turn >= currentTurn {
                audio.stopPlayback()
                lastPlaybackEndedAt = now
            }
        case .turnMetrics(let id, let turn, let modelLatencyMs) where id == callID:
            turnModelLatency[turn] = Double(modelLatencyMs) / 1000
            if turnEndToEnd[turn] != nil { summarizeTurn(turn) }
        default:
            break
        }
    }

    private func ping() {
        guard isActive else { return }
        // The iPhone hasn't taken the call yet: ask again instead.
        guard acceptedAt != nil else {
            sendStart()
            return
        }
        let sentAt = now
        let id = callID
        link.send(.ping(callID: id), reply: { [weak self] answer in
            guard let self, self.isActive, self.callID == id else { return }
            self.pingRoundTrips.append(self.now - sentAt)
            // The iPhone has no call: its end was sent while the Watch
            // couldn't hear it.
            if case .pong(phase: .none)? = answer {
                WatchProbeLog.shared.note("callGoneOnPhone")
                self.finish(reason: "The call ended on your iPhone.")
                return
            }
            if self.phase == .unreachable {
                var phoneName: String?
                if case .pong(let name)? = answer { phoneName = name }
                self.phase = .live(phoneName.flatMap(WatchVoiceWire.CallState.Phase.init(rawValue:)) ?? .connecting)
            }
            self.resendUnsentControls()
        }, failure: { [weak self] error in
            guard let self, self.isActive, self.callID == id else { return }
            self.pingFailures += 1
            if self.pingFailures <= 5 || self.pingFailures % 10 == 0 {
                WatchProbeLog.shared.note("pingFailed", ["error": error.localizedDescription, "count": self.pingFailures, "scene": "\(self.scenePhase)"])
            }
        })
    }

    private func reachabilityChanged(_ reachable: Bool) {
        guard isActive else { return }
        if reachable {
            resendUnsentControls()
        } else if phase != .needsTap {
            phase = .unreachable
        }
    }

    /// Mute and resume go again if the iPhone didn't get them: the link
    /// often drops just as the wrist comes up.
    private func sendMute() {
        muteUnconfirmed = true
        link.send(.mute(callID: callID, muted: isMuted))
    }

    private func sendPaused(_ reason: String) {
        let id = callID
        pauseUnsent = nil
        resumeUnsent = false
        link.send(.paused(callID: id, reason: reason), failure: { [weak self] _ in
            guard let self, self.isActive, self.callID == id, self.micPaused else { return }
            self.pauseUnsent = reason
        })
    }

    private func sendResumed() {
        let id = callID
        pauseUnsent = nil
        resumeUnsent = false
        link.send(.resumed(callID: id), failure: { [weak self] _ in
            guard let self, self.isActive, self.callID == id, !self.micPaused else { return }
            self.resumeUnsent = true
        })
    }

    private func resendUnsentControls() {
        if muteUnconfirmed { sendMute() }
        if let reason = pauseUnsent, micPaused { sendPaused(reason) }
        if resumeUnsent, !micPaused { sendResumed() }
    }

    private func audioInterrupted(began: Bool) {
        guard isActive else { return }
        if began {
            micPaused = true
            pendingSamples = []
            activity.reset()
            sendPaused("audioInterruption")
            phase = .needsTap
        } else {
            // Recording can't restart in the background; in front it may.
            guard scenePhase == .active else { return }
            continueAfterInterruption()
        }
    }

    // MARK: Lifecycle

    private func resetCall() {
        callID = UInt32.random(in: 1...UInt32.max)
        callStartedAt = now
        acceptedAt = nil
        startInFlight = false
        phonePhase = nil
        listeningAt = nil
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        batteryAtStart = WKInterfaceDevice.current().batteryLevel
        encoder.reset()
        pendingSamples = []
        uplinkSeq = 0
        inFlight = 0
        lastSendAt = 0
        micPaused = false
        muteUnconfirmed = false
        resumeUnsent = false
        pauseUnsent = nil
        lastPlaybackEndedAt = nil
        activity = WatchVoiceActivity()
        uplinkSent = 0
        uplinkAcked = 0
        uplinkFailed = 0
        uplinkMerged = 0
        uplinkRoundTrips = []
        currentTurn = 0
        stoppedTurn = 0
        lastDownlinkSeq = 0
        downlinkReceived = 0
        lastDownlinkAt = nil
        maxDownlinkGap = 0
        turnSpeechEnd = [:]
        lastTimedSpeechEnd = nil
        turnEndToEnd = [:]
        turnModelLatency = [:]
        awaitingFirstAudio = nil
        pingFailures = 0
        pingRoundTrips = []
        caption = nil
        mode = nil
        isMuted = false
        jobs = 0
        lastTurnSummary = nil
    }

    private func finish(reason: String?) {
        guard isActive else { return }
        timers.forEach { $0.invalidate() }
        timers = []
        audio.stop()
        link.onMessage = nil
        link.onCallPacket = nil
        link.onReachabilityChange = nil
        phase = .ended(reason)
        let endToEnd = Array(turnEndToEnd.values)
        let overheads = turnEndToEnd.compactMap { turn, total in turnModelLatency[turn].map { total - $0 } }
        let battery = WKInterfaceDevice.current().batteryLevel
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
        WatchProbeLog.shared.report("callSummary", [
            "callID": Int(callID),
            "mode": mode as Any,
            "reason": reason as Any,
            "fullDuplex": fullDuplex,
            "durationS": Int(now - callStartedAt),
            "acceptedMs": WatchVoiceStats.milliseconds(acceptedAt.map { $0 - callStartedAt }) as Any,
            "listeningMs": WatchVoiceStats.milliseconds(listeningAt.map { $0 - callStartedAt }) as Any,
            "turns": endToEnd.count,
            "endToEndP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(endToEnd, 0.5)) as Any,
            "endToEndP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(endToEnd, 0.95)) as Any,
            "watchOverheadP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(overheads, 0.5)) as Any,
            "watchOverheadP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(overheads, 0.95)) as Any,
            "uplinkSent": uplinkSent,
            "uplinkAcked": uplinkAcked,
            "uplinkFailed": uplinkFailed,
            "uplinkMerged": uplinkMerged,
            "uplinkRttP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(uplinkRoundTrips, 0.5)) as Any,
            "uplinkRttP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(uplinkRoundTrips, 0.95)) as Any,
            "downlinkReceived": downlinkReceived,
            "downlinkMaxGapMs": Int(maxDownlinkGap * 1000),
            "pingFailures": pingFailures,
            "pingRttP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(pingRoundTrips, 0.5)) as Any,
            "reachabilityChanges": link.reachabilityChanges,
            "batteryStart": batteryAtStart,
            "batteryEnd": battery,
        ])
    }
}
