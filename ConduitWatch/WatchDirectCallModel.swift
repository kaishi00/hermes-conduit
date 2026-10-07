//
//  WatchDirectCallModel.swift
//  Conduit Watch
//
//  Test T2 of designs/apple-watch-voice-direct.md: the Watch calls Gemini
//  Live itself with the iPhone's own GeminiLiveSession (Shared/GeminiLive):
//  the same setup, resumption,
//  context-window compression, transcription, GoAway handoff and retries
//  as a call on the iPhone. The iPhone builds the session (instructions,
//  persona, memory, functions, voice) and hands over a single-use token;
//  after that it only runs the tools: each function call goes to it as a
//  Watch message, and while jobs run the Watch asks it for their news.
//  The audio goes straight between the Watch and Google, through the
//  iPhone's Bluetooth link or over Wi-Fi.
//
//  watchOS allows that socket only in TN3135's cases, so the call keeps
//  one of two going (picked on the call screen):
//  - option E, the audio session alone: play-and-record, no CallKit. TN3135
//    lets an app stream audio with low-level networking; whether a session
//    that also records counts is what the test finds out.
//  - option D, a CallKit call on the Watch, TN3135's VoIP case: the
//    fallback.
//
//  Half duplex: the microphone isn't sent while Gemini speaks, nor for a
//  short echo tail after (the Watch can't cancel its own echo), and a tap
//  stops Gemini.
//
//  Measures what the test needs: each step of the start, each reply's
//  time from the end of the user's speech to audible speech, reconnects
//  and GoAway handoffs, unanswered turns, tool calls that reached the
//  iPhone, data both ways, gaps in the audio, time with the screen off,
//  and battery.
//

import AVFAudio
import Foundation
import SwiftUI
import WatchKit

@MainActor
final class WatchDirectCallModel: ObservableObject {
    /// What keeps the app running, and its socket allowed, with the
    /// screen off.
    enum KeepAlive: String, CaseIterable, Identifiable {
        /// Option E: the play-and-record audio session alone.
        case audioSession
        /// Option D: a CallKit call on the Watch.
        case callKit

        static let key = "watchDirect.keepAlive"
        static var current: KeepAlive {
            UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .audioSession
        }

        var id: String { rawValue }

        var title: String {
            switch self {
            case .audioSession: return "Audio session (E)"
            case .callKit: return "CallKit call (D)"
            }
        }
    }

    /// Option E only: the audio session activated again on a timer. One
    /// developer report (FB24377808, open with Apple) has watchOS revoke the
    /// network path 35 to 39 s after an activation despite live audio, and
    /// activating again before then moved the deadline. Undocumented, so
    /// it's a measurement: off is the default, to see whether this Watch
    /// has the bug at all.
    enum Reactivation: Int, CaseIterable, Identifiable {
        case off = 0
        case every25s = 25

        static let key = "watchDirect.reactivate"
        static var current: Reactivation {
            Reactivation(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .off
        }

        var id: Int { rawValue }

        var title: String {
            self == .off ? "Off" : "Every \(rawValue) s"
        }
    }

    enum Phase: Equatable {
        case idle
        /// Starting the Watch's call and asking the iPhone for a session.
        case preparing
        case connecting
        case listening
        case speaking
        case reconnecting
        /// Siri or an alarm took the microphone: a tap brings it back.
        case needsTap
        /// Hermes said goodbye: the call closes once it has played.
        case ending
        case ended(String?)
    }

    /// How long the start keeps asking the iPhone for a session.
    static let sessionWait: TimeInterval = 30
    static let sessionRetryDelay: TimeInterval = 2
    /// How long a reconnect waits for a new token from the iPhone.
    static let tokenWait: TimeInterval = 10
    static let flushInterval: TimeInterval = 0.1
    /// After Gemini stops playing, the microphone stays closed this long so
    /// the speaker's echo can't read as the user (the iPhone's speaker
    /// value).
    static let echoTail: TimeInterval = 0.35
    /// Speech captured while the call connects, sent once it's ready.
    static let preRoll: TimeInterval = 3
    /// Audio waiting to go out beyond this many sends is dropped and
    /// counted: the link can't keep up.
    static let maxSendsInFlight = 20
    /// Job news waits for this much quiet after the user and the model,
    /// as on the iPhone.
    static let userQuietInterval: TimeInterval = 2
    static let modelQuietInterval: TimeInterval = 1
    /// A goodbye closes the call once Gemini has made no sound this long,
    /// or after the timeout whatever it's doing (the iPhone's values).
    static let endGrace: TimeInterval = 1
    static let endTimeout: TimeInterval = 8
    /// While this call's jobs run, the Watch asks the iPhone this often.
    static let pollInterval: TimeInterval = 20
    /// A turn the user spoke that gets no reply within this long counts
    /// as unanswered.
    static let unansweredAfter: TimeInterval = 15
    /// How often the call checks that a Watch message still reaches (and
    /// wakes) Conduit on the iPhone, whatever the screen and the phone do.
    static let linkProbeInterval: TimeInterval = 30
    /// A reactivation still running after this long counts as failed.
    static let reactivationTimeout: TimeInterval = 10
    /// Calls the iPhone answers once nobody speaks (NON_BLOCKING lookups).
    static let whenIdleTools: Set<String> = ["web_search", "recall_memory"]

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var caption: String?
    @Published private(set) var isMuted = false
    @Published private(set) var lastTurnSummary: String?
    /// Which way the traffic goes and which socket API worked.
    @Published private(set) var route: String?
    @Published private(set) var runningJobs = 0

    private let link = WatchLink.shared
    private let audio = WatchAudio()
    private var meter = WatchSocketMeter()
    private var session: GeminiLiveSession?
    private var tokens: WatchDirectTokens?
    private var openingPrompt: String?
    private var hasSentOpening = false
    private var callID: UInt32 = 0
    private var callUUID = UUID()
    private var callStartedDate = Date()
    private var timers: [Timer] = []
    private var scenePhase: ScenePhase = .active

    // Start
    private var callStartedAt: TimeInterval = 0
    private var keepAlive: KeepAlive = .audioSession
    private var audioSessionActivated: Bool?
    private var systemCallActivated: Bool?
    private var systemCallReadyAt: TimeInterval?
    private var sessionRequests = 0
    private var sessionAt: TimeInterval?
    private var connectStartedAt: TimeInterval?
    private var firstReadyAt: TimeInterval?

    // Connection
    private var reconnectStartedAt: TimeInterval?
    private var reconnectTimes: [Double] = []
    /// How long each connection served before it dropped.
    private var connectionReadyAt: TimeInterval?
    private var connectionLifetimes: [Double] = []
    private var pathNotes = 0
    private var reactivation: Reactivation = .off
    /// Option E: when the session was first activated, and last activated
    /// again; the revocation report times its deadline from activation.
    private var audioActivatedAt: TimeInterval?
    private var lastActivationAt: TimeInterval?
    private var reactivationStartedAt: TimeInterval?
    private var reactivating = false
    private var reactivations = 0
    private var reactivationFailures = 0
    private var reactivationTimes: [Double] = []
    /// The longest microphone gap within 3 s of a reactivation: a glitch.
    private var maxReactivationCaptureGap: TimeInterval = 0
    private var routeChangesAtStart = 0
    private var firstDropAt: TimeInterval?
    private var handoffStartedAt: TimeInterval?
    private var handoffTimes: [Double] = []
    private var drops = 0
    private var goAways = 0
    private var loggedResumable = false
    private var socketWaitNotes = 0
    private var tokensFromPhone = 0
    private var tokensReused = 0
    private var tokenFailures = 0

    // Conversation
    private var suppressingModelTurn = false
    private var modelTurnActive = false
    private var lastUserSpeechAt: TimeInterval?
    private var lastModelTurnEndedAt: TimeInterval?
    private var lastModelAudioAt: TimeInterval?
    private var awaitingReplySince: TimeInterval?
    private var unansweredTurns = 0
    private var endRequestedAt: TimeInterval?
    private var transcript: [WatchVoiceWire.DirectTurn] = []
    private var openUserLine: Int?
    private var openAssistantLine: Int?

    // Tools
    private var toolsInFlight: Set<String> = []
    private var withdrawnToolIDs: Set<String> = []
    private var quietQueue: [WatchVoiceWire.DirectOutgoing] = []
    private var toolCalls = 0
    private var toolsAnsweredLive = 0
    private var toolsUnreachable = 0
    private var jobsQueued = 0
    private var pollInFlight = false
    private var lastPollAt: TimeInterval = 0
    private var polls = 0
    private var pollsFailed = 0
    private var textUpdatesSent = 0

    // Audio
    private var pendingSamples: [Int16] = []
    private var sendsInFlight = 0
    private var lastPlaybackEndedAt: TimeInterval?
    private var activity = WatchVoiceActivity()
    private var speechEndAtTurnStart: TimeInterval?
    private var awaitingFirstAudio = false
    private var lastAudioChunkAt: TimeInterval?
    private var maxAudioGap: TimeInterval = 0
    private var lastCaptureAt: TimeInterval?
    private var maxCaptureGap: TimeInterval = 0
    private var replyTimes: [Double] = []
    private var turns = 0
    private var turnsWhileScreenOff = 0
    private var chunksUp = 0
    private var chunksDropped = 0
    private var sendFailures = 0
    private var liveSince: TimeInterval?

    // Liveness: gaps in the one-second ticker are time the Watch app
    // didn't run.
    private var lastTickAt: TimeInterval?

    // Watch → iPhone messages during the call.
    private var probeInFlight = false
    private var lastProbeAt: TimeInterval = 0
    private var probes = 0
    private var probesOK = 0
    private var probesScreenOff = 0
    private var probesOKScreenOff = 0
    private var probeTimes: [Double] = []
    private var watchSuspendedMs = 0
    private var watchGaps = 0

    // Screen and battery
    private var screenOffSince: TimeInterval?
    private var screenOffSeconds: TimeInterval = 0
    private var reachabilityChangesAtStart = 0
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
        // Each await below can outlast the call: ended, and maybe a new
        // one started, by the time it returns.
        let id = callID
        guard await WatchAudio.requestPermission() else {
            if callID == id { finish(WatchAudioError.permissionDenied.localizedDescription) }
            return
        }
        guard callID == id, phase == .preparing else { return }
        keepAlive = KeepAlive.current
        // What allows the socket comes first.
        var activatedHere = false
        switch keepAlive {
        case .callKit:
            let systemCall = WatchSystemCall.shared
            systemCall.onEndedBySystem = { [weak self] in self?.end(reason: "ended from the Watch's call controls") }
            let activated = await systemCall.start()
            guard callID == id else { return }
            systemCallActivated = activated
        case .audioSession:
            // A CallKit call left from an earlier test would grant the
            // network itself.
            if WatchSystemCall.isCreated { WatchSystemCall.shared.endStaleCalls() }
            activatedHere = await activateAudioSession()
            if callID == id {
                audioSessionActivated = activatedHere
                if activatedHere {
                    audioActivatedAt = now
                    lastActivationAt = now
                }
            }
        }
        // Ended meanwhile: `finish` ended its CallKit call too, but the
        // audio session activated here has no engine to stop, unless a new
        // call has it now.
        guard callID == id, phase == .preparing else {
            if activatedHere, !isActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            }
            return
        }
        systemCallReadyAt = now
        do {
            try audio.start(options: .init(), playbackRate: GeminiLiveProtocol.outputSampleRate)
        } catch {
            finish("The microphone didn't start: \(error.localizedDescription)")
            return
        }
        WatchProbeLog.shared.note("directCallStart", [
            "callID": Int(callID),
            "keepAlive": keepAlive.rawValue,
            "socket": meter.choice.rawValue,
            "reactivateEveryS": reactivation.rawValue,
            "audioSessionActivated": audioSessionActivated as Any,
            "systemCallActivated": systemCallActivated as Any,
            "keepAliveMs": Int(((systemCallReadyAt ?? now) - callStartedAt) * 1000),
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
        end(reason: "ended on the Watch")
    }

    /// Option E: the session activated the way the reports of a working
    /// socket did (asynchronously), before the engine starts in it. Play
    /// and record with the default route policy, so the built-in speaker
    /// plays; long-form audio would want Bluetooth and can't record.
    private func activateAudioSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        let startedAt = now
        do {
            try session.setCategory(.playAndRecord, mode: .default, policy: .default, options: [])
            let activated = try await session.activate(options: [])
            WatchProbeLog.shared.note("directAudioSession", [
                "activated": activated,
                "ms": Int((now - startedAt) * 1000),
                "outputs": session.currentRoute.outputs.map { $0.portType.rawValue },
                "inputs": session.currentRoute.inputs.map { $0.portType.rawValue },
            ])
            return activated
        } catch {
            let error = error as NSError
            WatchProbeLog.shared.note("directAudioSession", ["activated": false, "domain": error.domain, "code": error.code])
            return false
        }
    }

    /// The orb: stops Gemini while it speaks, brings the microphone back
    /// after Siri or an alarm.
    func tapOrb() {
        if phase == .needsTap {
            restartAudio()
            return
        }
        guard modelTurnActive || audio.isPlaying else { return }
        // As the iPhone's Interrupt button: playback stops now, and the
        // rest of this turn is dropped until Gemini ends or interrupts it.
        audio.stopPlayback()
        suppressingModelTurn = true
        modelTurnActive = false
        lastModelTurnEndedAt = now
        lastPlaybackEndedAt = now
        openAssistantLine = nil
        awaitingFirstAudio = false
        if phase == .speaking { phase = .listening }
        WatchProbeLog.shared.note("directInterrupt", ["callID": Int(callID), "screen": "\(scenePhase)"])
    }

    func toggleMute() {
        guard isActive else { return }
        isMuted.toggle()
        pendingSamples = []
        activity.reset()
        // The server ends the user's turn now instead of waiting for audio.
        if isMuted { session?.send(.audioStreamEnd, onSent: nil, onFailure: nil) }
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
        WatchProbeLog.shared.note("directScenePhase", [
            "phase": "\(newPhase)",
            "ready": session?.isReady == true,
            "systemCall": WatchSystemCall.isHoldingCall,
            "reachable": link.isReachable,
        ])
    }

    // MARK: Session from the iPhone

    private func requestSession() {
        sessionRequests += 1
        let id = callID
        link.send(.directStart(callID: id, version: WatchVoiceWire.version), reply: { [weak self] answer in
            guard let self, self.callID == id, self.phase == .preparing else { return }
            switch answer {
            case .directSession(_, let session)?:
                self.begin(session)
            case .callRefused(_, let reason)?:
                WatchProbeLog.shared.note("directRefused", ["reason": reason])
                self.finish(reason)
            default:
                self.finish("Conduit on the iPhone sent something this Watch app can't read. Update both.")
            }
        }, failure: { [weak self] error in
            guard let self, self.callID == id, self.phase == .preparing else { return }
            WatchProbeLog.shared.note("directStartFailed", [
                "error": error.localizedDescription,
                "reachable": self.link.isReachable,
                "attempt": self.sessionRequests,
            ])
            guard self.now - self.callStartedAt < Self.sessionWait else {
                self.finish("Couldn't reach Conduit on your iPhone.")
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

    private func begin(_ direct: WatchVoiceWire.DirectSession) {
        sessionAt = now
        guard let setup = WatchVoiceWire.DirectSetup(compressed: direct.setup),
              let functions = setup.declarations,
              let token = direct.token.geminiToken else {
            finish("The iPhone's session couldn't be read. Update Conduit on both devices.")
            return
        }
        openingPrompt = direct.openingPrompt
        let tokens = WatchDirectTokens(first: token)
        tokens.fetch = { [weak self] in
            guard let self else { throw WatchDirectError.ended }
            return try await self.requestToken()
        }
        tokens.onIssued = { [weak self] source, error in self?.tokenIssued(source, error: error) }
        let meter = self.meter
        meter.onFirstFrame = { [weak self] api in self?.socketHeard(api) }
        meter.onWaiting = { [weak self] api, reason in self?.socketWaiting(api, reason: reason) }
        meter.onPathEvent = { [weak self] kind, fields in self?.pathEvent(kind, fields) }
        let session = GeminiLiveSession(
            tokens: tokens,
            systemInstruction: setup.systemInstruction,
            functions: functions,
            googleSearch: direct.googleSearch,
            voice: direct.voice,
            openSocket: { url in meter.makeSocket(url) }
        )
        // A reconnect the iPhone can't serve resumes on the token in hand.
        tokens.canResume = { [weak session] in session?.resumptionHandle != nil }
        session.onEvent = { [weak self] in self?.handle($0) }
        session.onStateChange = { [weak self] in self?.sessionStateChanged($0) }
        session.onConnectionReplaced = { [weak self] in self?.connectionReplaced() }
        self.tokens = tokens
        self.session = session
        WatchProbeLog.shared.note("directSession", [
            "afterTapMs": Int((now - callStartedAt) * 1000),
            "requests": sessionRequests,
            "setupBytes": direct.setupBytes,
            "compressedBytes": direct.setup.count,
            "model": token.model,
            "functions": functions.map(\.name),
            "keepAlive": keepAlive.rawValue,
            "googleSearch": direct.googleSearch,
            "opening": direct.openingPrompt != nil,
            "tokenExpiresInS": token.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any,
        ])
        phase = .connecting
        connectStartedAt = now
        session.start()
    }

    /// A new single-use token for the next connection, from the iPhone.
    private func requestToken() async throws -> GeminiLiveToken {
        let id = callID
        let link = self.link
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GeminiLiveToken, Error>) in
            let once = WatchResumeOnce(continuation)
            link.send(.directToken(callID: id), reply: { answer in
                switch answer {
                case .directTokenIssued(_, let issued)?:
                    if let token = issued.geminiToken {
                        once.resume(.success(token))
                    } else {
                        once.resume(.failure(WatchDirectError.unreadable))
                    }
                case .callRefused(_, let reason)?:
                    once.resume(.failure(WatchDirectError.refused(reason)))
                default:
                    once.resume(.failure(WatchDirectError.unreadable))
                }
            }, failure: { error in
                once.resume(.failure(error))
            })
            _ = WatchVoiceMain.timer(every: Self.tokenWait, repeats: false) { _ in
                MainActor.assumeIsolated { once.resume(.failure(WatchDirectError.timedOut)) }
            }
        }
    }

    private func tokenIssued(_ source: WatchDirectTokens.Source, error: String?) {
        switch source {
        case .phone: tokensFromPhone += 1
        case .reused: tokensReused += 1
        case .failed: tokenFailures += 1
        case .first: break
        }
        WatchProbeLog.shared.note("directToken", [
            "source": source.rawValue,
            "error": error as Any,
            "screen": "\(scenePhase)",
            "reachable": link.isReachable,
        ])
    }

    // MARK: Connection

    private func sessionStateChanged(_ state: GeminiLiveSession.State) {
        guard isActive else { return }
        switch state {
        case .ready:
            let at = now
            if firstReadyAt == nil {
                firstReadyAt = at
                liveSince = at
                WatchProbeLog.shared.note("directReady", [
                    "sinceTapMs": Int((at - callStartedAt) * 1000),
                    "connectMs": connectStartedAt.map { Int((at - $0) * 1000) } as Any,
                    "api": meter.workingAPI?.rawValue as Any,
                    "route": route as Any,
                ])
            }
            if let since = reconnectStartedAt {
                reconnectTimes.append(at - since)
                reconnectStartedAt = nil
                WatchProbeLog.shared.note("directReconnected", ["ms": Int((at - since) * 1000), "screen": "\(scenePhase)"])
            }
            if let since = handoffStartedAt {
                handoffTimes.append(at - since)
                handoffStartedAt = nil
                WatchProbeLog.shared.note("directHandoff", ["ms": Int((at - since) * 1000), "screen": "\(scenePhase)"])
            }
            connectionReadyAt = at
            if phase == .connecting || phase == .reconnecting { phase = restingPhase }
            sendOpeningIfNeeded()
            flushQuietQueue()
        case .reconnecting:
            if phase == .listening || phase == .speaking || phase == .connecting { phase = .reconnecting }
            let alive = connectionReadyAt.map { now - $0 }
            if let alive { connectionLifetimes.append(alive) }
            connectionReadyAt = nil
            if reconnectStartedAt == nil {
                reconnectStartedAt = now
                if firstReadyAt != nil {
                    drops += 1
                    if firstDropAt == nil { firstDropAt = now }
                }
            }
            WatchProbeLog.shared.note("directReconnecting", [
                "aliveS": alive.map { Int($0) } as Any,
                "sinceActivationS": lastActivationAt.map { Int(now - $0) } as Any,
                "sinceFirstActivationS": audioActivatedAt.map { Int(now - $0) } as Any,
                "screen": "\(scenePhase)",
                "systemCall": WatchSystemCall.isHoldingCall,
                "reachable": link.isReachable,
            ])
        case .failed(let message):
            WatchProbeLog.shared.note("directFailed", ["message": message, "screen": "\(scenePhase)"])
            finish(message)
        case .idle, .connecting, .stopped:
            break
        }
    }

    /// A new connection took over: calls opened on the old one can't be
    /// answered on it, so their answers go out as text updates instead.
    private func connectionReplaced() {
        WatchProbeLog.shared.note("directConnectionReplaced", ["openCalls": toolsInFlight.count])
    }

    private func socketHeard(_ api: WatchSocketAPI) {
        if route == nil { route = api.rawValue }
    }

    private func socketWaiting(_ api: WatchSocketAPI, reason: String) {
        socketWaitNotes += 1
        guard socketWaitNotes <= 5 else { return }
        WatchProbeLog.shared.note("directSocketWaiting", ["api": api.rawValue, "reason": reason, "systemCall": WatchSystemCall.isHoldingCall])
    }

    private func pathEvent(_ kind: String, _ fields: [String: Any]) {
        if kind == "ready" {
            let uses = (fields["uses"] as? [String]) ?? []
            route = "network, " + (uses.isEmpty ? "unknown route" : uses.joined(separator: "+"))
        }
        pathNotes += 1
        guard pathNotes <= 150 else { return }
        var fields = fields
        fields["kind"] = kind
        fields["sinceReadyS"] = connectionReadyAt.map { Int(now - $0) } as Any
        fields["sinceActivationS"] = lastActivationAt.map { Int(now - $0) } as Any
        fields["sinceFirstActivationS"] = audioActivatedAt.map { Int(now - $0) } as Any
        fields["screen"] = "\(scenePhase)"
        WatchProbeLog.shared.note("directPath", fields)
    }

    private var restingPhase: Phase {
        if endRequestedAt != nil { return .ending }
        return audio.isPlaying ? .speaking : .listening
    }

    private func sendOpeningIfNeeded() {
        guard !hasSentOpening, let openingPrompt, let session, session.isReady else { return }
        hasSentOpening = true
        session.send(.textTurn(openingPrompt), onSent: nil, onFailure: { [weak self] in self?.hasSentOpening = false })
    }

    // MARK: Server events

    private func handle(_ event: GeminiLiveProtocol.ServerEvent) {
        guard isActive else { return }
        switch event {
        case .setupComplete:
            break
        case .resumptionUpdate(let handle, let resumable):
            if !loggedResumable, resumable, handle != nil {
                loggedResumable = true
                WatchProbeLog.shared.note("directResumable")
            }
        case .audio(let pcm, let sampleRate):
            guard !suppressingModelTurn else { return }
            let at = now
            if modelTurnActive, let last = lastAudioChunkAt {
                maxAudioGap = max(maxAudioGap, at - last)
            }
            lastAudioChunkAt = at
            lastModelAudioAt = at
            if !awaitingFirstAudio, speechEndAtTurnStart == nil, !audio.isPlaying {
                // The first audio of a reply: timed from the end of the
                // user's speech.
                speechEndAtTurnStart = activity.lastVoicedAt
                awaitingFirstAudio = true
            }
            modelTurnActive = true
            awaitingReplySince = nil
            audio.enqueue(Self.samples(pcm), sampleRate: sampleRate)
            if phase == .listening { phase = .speaking }
        case .inputTranscription(let text):
            lastUserSpeechAt = now
            if openUserLine == nil, awaitingReplySince == nil { awaitingReplySince = now }
            appendTranscript(.user, text)
        case .outputTranscription(let text):
            guard !suppressingModelTurn else { return }
            modelTurnActive = true
            awaitingReplySince = nil
            appendTranscript(.assistant, text)
            if let line = openAssistantLine { caption = String(transcript[line].text.suffix(160)) }
        case .interrupted:
            audio.stopPlayback()
            lastPlaybackEndedAt = now
            suppressingModelTurn = false
            modelTurnEnded()
        case .turnComplete:
            suppressingModelTurn = false
            modelTurnEnded()
        case .toolCall(let calls):
            for call in calls { toolCalled(call) }
        case .toolCallCancellation(let ids):
            // Answers still coming for these are dropped.
            withdrawnToolIDs.formUnion(toolsInFlight.intersection(ids))
            link.send(.directToolCancel(callID: callID, ids: ids))
        case .goAway(let timeLeft):
            goAways += 1
            if handoffStartedAt == nil { handoffStartedAt = now }
            WatchProbeLog.shared.note("directGoAway", ["timeLeftS": timeLeft as Any, "screen": "\(scenePhase)"])
        }
    }

    private func modelTurnEnded() {
        if modelTurnActive || openAssistantLine != nil {
            turns += 1
            if scenePhase != .active { turnsWhileScreenOff += 1 }
        }
        modelTurnActive = false
        lastModelTurnEndedAt = now
        openUserLine = nil
        openAssistantLine = nil
        speechEndAtTurnStart = nil
        lastAudioChunkAt = nil
        activity.reset()
        flushQuietQueue()
    }

    private func appendTranscript(_ role: WatchVoiceWire.DirectTurn.Role, _ text: String) {
        let open = role == .user ? openUserLine : openAssistantLine
        if let open, transcript.indices.contains(open) {
            transcript[open].text = role == .assistant
                ? Self.joinTranscriptChunk(transcript[open].text, text)
                : transcript[open].text + text
            return
        }
        transcript.append(.init(role: role, text: text, at: Date()))
        if role == .user {
            openUserLine = transcript.count - 1
            openAssistantLine = nil
        } else {
            openAssistantLine = transcript.count - 1
            openUserLine = nil
        }
    }

    static func samples(_ pcm: Data) -> [Int16] {
        var samples = [Int16](repeating: 0, count: pcm.count / 2)
        _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
        return samples.map { Int16(littleEndian: $0) }
    }

    /// The iPhone's seam repair for the model's streamed transcript
    /// (GeminiLiveConversationController.joinTranscriptChunk): Gemini
    /// sometimes drops the space between two chunks.
    static func joinTranscriptChunk(_ existing: String, _ chunk: String) -> String {
        guard let last = existing.last, let first = chunk.first else { return existing + chunk }
        if last.isWhitespace || first.isWhitespace { return existing + chunk }
        let needsSpace: Bool
        if isSpacedWordCharacter(last) {
            needsSpace = isSpacedWordCharacter(first)
        } else if ".,!?;:".contains(last) {
            needsSpace = first.isLetter && isSpacedWordCharacter(first)
        } else {
            needsSpace = false
        }
        return needsSpace ? existing + " " + chunk : existing + chunk
    }

    private static func isSpacedWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber,
              let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0EFF, // Thai, Lao
             0x1000...0x109F, // Myanmar
             0x1780...0x17FF, // Khmer
             0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK ideographs
             0xFF66...0xFF9F: // Half-width Katakana
            return false
        default:
            return true
        }
    }

    // MARK: Tools

    private func toolCalled(_ call: GeminiLiveProtocol.FunctionCall) {
        toolCalls += 1
        // The iPhone's bridge leaves end_conversation unanswered and the
        // call closes once the goodbye has played: nothing to ask it.
        if call.name == "end_conversation" {
            WatchProbeLog.shared.note("directTool", ["name": call.name, "local": true])
            requestEnd()
            return
        }
        let generation = session?.connectionGeneration
        let id = callID
        let sentAt = now
        let wire = WatchVoiceWire.DirectToolCall(id: call.id, name: call.name, arguments: call.arguments)
        toolsInFlight.insert(call.id)
        link.send(.directTool(callID: id, call: wire), reply: { [weak self] answer in
            guard let self, self.callID == id, self.isActive else { return }
            self.toolsInFlight.remove(call.id)
            let withdrawn = self.withdrawnToolIDs.remove(call.id) != nil
            guard case .directToolResult(_, let result)? = answer else {
                self.toolUnreachable(wire, generation: generation, error: "unreadable answer", withdrawn: withdrawn)
                return
            }
            self.toolsAnsweredLive += 1
            WatchProbeLog.shared.note("directTool", [
                "name": call.name,
                "live": true,
                "ms": Int((self.now - sentAt) * 1000),
                "outgoing": result.outgoing.count,
                "runningJobs": result.runningJobs,
                "withdrawn": withdrawn,
                "screen": "\(self.scenePhase)",
            ])
            self.apply(result, answering: call.id, generation: generation, withdrawn: withdrawn)
        }, failure: { [weak self] error in
            guard let self, self.callID == id, self.isActive else { return }
            self.toolsInFlight.remove(call.id)
            let withdrawn = self.withdrawnToolIDs.remove(call.id) != nil
            self.toolUnreachable(wire, generation: generation, error: error.localizedDescription, withdrawn: withdrawn)
        })
    }

    /// The iPhone didn't take the call: a job is queued for whenever it
    /// can, and anything else is answered with why it can't be done.
    /// Function results are written for the model, not shown.
    private func toolUnreachable(_ call: WatchVoiceWire.DirectToolCall, generation: Int?, error: String, withdrawn: Bool) {
        toolsUnreachable += 1
        var result: [String: String]
        var queued = false
        if call.name == "start_job" {
            queued = link.queue(.directTool(callID: callID, call: call))
            if queued {
                jobsQueued += 1
                runningJobs = max(runningJobs, 1)
                result = [
                    "status": "queued",
                    "message": "Conduit on the user's iPhone can't be reached right now. The job is queued and starts on Hermes once the iPhone takes it; its result comes as a Conduit notification. Tell the user in a sentence.",
                ]
            } else {
                result = [
                    "status": "not_started",
                    "message": "Conduit on the user's iPhone can't be reached right now, so the job didn't start. Tell the user in a sentence.",
                ]
            }
        } else {
            result = ["error": "Conduit on the user's iPhone can't be reached right now, so this isn't available. Tell the user in a few words."]
        }
        WatchProbeLog.shared.note("directTool", [
            "name": call.name,
            "live": false,
            "queued": queued,
            "error": error,
            "withdrawn": withdrawn,
            "screen": "\(scenePhase)",
            "reachable": link.isReachable,
        ])
        guard !withdrawn else { return }
        let scheduling = Self.whenIdleTools.contains(call.name) ? GeminiLiveProtocol.Scheduling.whenIdle.rawValue : nil
        answer(.toolResponse(id: call.id, name: call.name, result: result, scheduling: scheduling, fallback: nil), generation: generation)
    }

    private func apply(_ result: WatchVoiceWire.DirectToolResult, answering callID: String?, generation: Int?, withdrawn: Bool) {
        runningJobs = result.runningJobs
        for item in result.outgoing {
            switch item {
            case .endConversation:
                requestEnd()
            case .toolResponse(let id, _, _, _, _):
                // The model withdrew the call while it ran: no answer.
                if withdrawn, id == callID { continue }
                answer(item, generation: generation)
            case .textWhenIdle, .contextWhenIdle:
                quietQueue.append(item)
            }
        }
        flushQuietQueue()
    }

    /// Answers a call on the connection it was made on; once another took
    /// over, its fallback goes out as a text update, as on the iPhone.
    private func answer(_ item: WatchVoiceWire.DirectOutgoing, generation: Int?) {
        guard case .toolResponse(_, _, _, _, let fallback) = item, let message = item.clientMessage else { return }
        guard let session, session.isReady, generation == nil || session.connectionGeneration == generation else {
            if let fallback { quietQueue.append(.textWhenIdle(fallback)) }
            return
        }
        session.send(message, onSent: nil, onFailure: { [weak self] in
            guard let self, let fallback else { return }
            self.quietQueue.append(.textWhenIdle(fallback))
        })
    }

    /// Job news and the like go out only while nobody is speaking.
    private func flushQuietQueue() {
        guard !quietQueue.isEmpty, let session, session.isReady, isQuiet else { return }
        let item = quietQueue.removeFirst()
        guard let message = item.clientMessage else { return }
        textUpdatesSent += 1
        session.send(message, onSent: nil, onFailure: { [weak self] in self?.quietQueue.insert(item, at: 0) })
    }

    private var isQuiet: Bool {
        guard endRequestedAt == nil, phase != .needsTap, !modelTurnActive, !audio.isPlaying else { return false }
        let at = now
        if let spoke = lastUserSpeechAt, at - spoke < Self.userQuietInterval { return false }
        if let voiced = activity.lastVoicedAt, at - voiced < Self.userQuietInterval { return false }
        if let ended = lastModelTurnEndedAt, at - ended < Self.modelQuietInterval { return false }
        return true
    }

    /// While this call's jobs run, asks the iPhone for their news. Each ask
    /// wakes Conduit there briefly; none is made while no job runs.
    private func pollIfNeeded() {
        guard runningJobs > 0, !pollInFlight, now - lastPollAt >= Self.pollInterval else { return }
        pollInFlight = true
        lastPollAt = now
        polls += 1
        let id = callID
        link.send(.directPoll(callID: id), reply: { [weak self] answer in
            guard let self, self.callID == id, self.isActive else { return }
            self.pollInFlight = false
            guard case .directToolResult(_, let result)? = answer else {
                self.pollsFailed += 1
                return
            }
            if !result.outgoing.isEmpty || result.runningJobs != self.runningJobs {
                WatchProbeLog.shared.note("directPoll", ["runningJobs": result.runningJobs, "outgoing": result.outgoing.count, "screen": "\(self.scenePhase)"])
            }
            self.apply(result, answering: nil, generation: nil, withdrawn: false)
        }, failure: { [weak self] _ in
            guard let self, self.callID == id else { return }
            self.pollInFlight = false
            self.pollsFailed += 1
        })
    }

    // MARK: Audio

    private func captured(_ samples: [Int16], at time: TimeInterval) {
        guard isActive else { return }
        if let last = lastCaptureAt {
            maxCaptureGap = max(maxCaptureGap, time - last)
            // Any gap overlapping the 3 s after a reactivation, however long.
            if let reactivated = reactivationStartedAt, last < reactivated + 3, time > reactivated {
                maxReactivationCaptureGap = max(maxReactivationCaptureGap, time - last)
            }
        }
        lastCaptureAt = time
        guard endRequestedAt == nil, !isMuted, phase != .needsTap, !isMicrophoneHeld else { return }
        activity.process(samples, sampleRate: WatchAudio.captureRate, endingAt: time)
        pendingSamples.append(contentsOf: samples)
        // Before the session is ready, keep the newest few seconds only.
        let limit = Int(WatchAudio.captureRate * Self.preRoll)
        if session?.isReady != true, pendingSamples.count > limit {
            pendingSamples.removeFirst(pendingSamples.count - limit)
        }
    }

    /// Half duplex: Gemini's voice from the speaker must not read as the
    /// user.
    private var isMicrophoneHeld: Bool {
        if audio.isPlaying { return true }
        if let lastPlaybackEndedAt, now - lastPlaybackEndedAt < Self.echoTail { return true }
        return false
    }

    private func flushUplink() {
        guard let session, session.isReady, !pendingSamples.isEmpty else { return }
        let samples = pendingSamples
        pendingSamples = []
        guard sendsInFlight < Self.maxSendsInFlight else {
            chunksDropped += 1
            return
        }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        chunksUp += 1
        sendsInFlight += 1
        session.send(.audio(pcm), onSent: { [weak self] in
            self?.sendsInFlight -= 1
        }, onFailure: { [weak self] in
            guard let self else { return }
            self.sendsInFlight = max(0, self.sendsInFlight - 1)
            self.sendFailures += 1
        })
    }

    private func playbackStarted(at audibleAt: TimeInterval) {
        guard awaitingFirstAudio else { return }
        awaitingFirstAudio = false
        guard let speechEnd = speechEndAtTurnStart, audibleAt > speechEnd, audibleAt - speechEnd < 30 else { return }
        let reply = audibleAt - speechEnd
        replyTimes.append(reply)
        lastTurnSummary = String(format: "reply %.1fs", reply)
        WatchProbeLog.shared.note("directTurn", [
            "replyMs": Int(reply * 1000),
            "screen": "\(scenePhase)",
            "route": route as Any,
        ])
    }

    private func playbackDrained() {
        lastPlaybackEndedAt = now
        guard isActive, phase == .speaking else { return }
        phase = .listening
        flushQuietQueue()
    }

    private func audioInterrupted(began: Bool) {
        guard isActive else { return }
        WatchProbeLog.shared.note("directAudioInterruption", ["began": began, "screen": "\(scenePhase)"])
        if began {
            // Before the iPhone's session came, a tap would have no call
            // to go back to.
            guard session != nil else {
                finish("The microphone was interrupted before the call connected. Try again.")
                return
            }
            pendingSamples = []
            activity.reset()
            phase = .needsTap
        } else if scenePhase == .active {
            restartAudio()
        }
    }

    private func restartAudio() {
        do {
            try audio.start(options: .init(), playbackRate: GeminiLiveProtocol.outputSampleRate)
            phase = session?.isReady == true ? restingPhase : .reconnecting
            // The restart activated the session again: the revocation
            // timing and the reactivation cadence count from here.
            if keepAlive == .audioSession {
                WatchProbeLog.shared.note("directAudioRestarted", [
                    "sinceActivationS": lastActivationAt.map { Int(now - $0) } as Any,
                    "screen": "\(scenePhase)",
                ])
                lastActivationAt = now
            }
        } catch {
            WatchProbeLog.shared.note("directAudioRestartFailed", ["error": error.localizedDescription])
        }
    }

    // MARK: Lifecycle

    private func tick() {
        guard isActive else { return }
        let at = now
        if let last = lastTickAt, at - last > 1.5 {
            let missed = Int((at - last - 1) * 1000)
            watchSuspendedMs += missed
            watchGaps += 1
            if watchGaps <= 20 {
                WatchProbeLog.shared.note("directWatchGap", ["ms": missed, "screen": "\(scenePhase)"])
            }
        }
        lastTickAt = at
        if phase == .preparing, now - callStartedAt >= Self.sessionWait + 15 {
            finish("Conduit on your iPhone didn't answer.")
            return
        }
        if let since = awaitingReplySince, now - since >= Self.unansweredAfter, !modelTurnActive {
            awaitingReplySince = nil
            unansweredTurns += 1
            WatchProbeLog.shared.note("directUnanswered", ["screen": "\(scenePhase)", "ready": session?.isReady == true])
        }
        if let endAt = endRequestedAt {
            let lastSound = max(endAt, lastModelAudioAt ?? 0)
            if (!audio.isPlaying && now - lastSound >= Self.endGrace) || now - endAt >= Self.endTimeout {
                finish("Hermes said goodbye.")
                return
            }
        }
        pollIfNeeded()
        reactivateIfDue()
        probeLinkIfDue()
        flushQuietQueue()
    }

    /// Option E with reactivation on: activates the session again, as the
    /// FB24377808 workaround does, and logs what it cost: how long it
    /// took, the route either side, whether the engine kept running.
    private func reactivateIfDue() {
        // An activation that never returned would stop the cadence for good.
        if reactivating, let started = reactivationStartedAt, now - started > Self.reactivationTimeout {
            reactivating = false
            reactivationFailures += 1
            WatchProbeLog.shared.note("directReactivateHung", ["ms": Int((now - started) * 1000)])
        }
        guard keepAlive == .audioSession, reactivation != .off, !reactivating,
              let last = lastActivationAt, now - last >= TimeInterval(reactivation.rawValue) else { return }
        reactivating = true
        let id = callID
        let startedAt = now
        reactivationStartedAt = startedAt
        let session = AVAudioSession.sharedInstance()
        let routeBefore = session.currentRoute.outputs.map { $0.portType.rawValue }
        let engineBefore = audio.isEngineRunning
        Task { [weak self] in
            var activated = false
            var failure: String?
            do {
                activated = try await session.activate(options: [])
            } catch {
                let error = error as NSError
                failure = "\(error.domain) \(error.code)"
            }
            guard let self else { return }
            guard self.callID == id, self.isActive else {
                // The call ended meanwhile and let the session go: this
                // activation mustn't keep it.
                if !self.isActive { try? session.setActive(false, options: [.notifyOthersOnDeactivation]) }
                return
            }
            let at = self.now
            // Given up on as hung, and maybe followed by another: it only
            // moves the anchor.
            guard self.reactivationStartedAt == startedAt else {
                if activated { self.lastActivationAt = at }
                return
            }
            self.reactivating = false
            self.lastActivationAt = at
            self.reactivations += 1
            if !activated { self.reactivationFailures += 1 }
            self.reactivationTimes.append(at - startedAt)
            guard self.reactivations <= 40 || !activated else { return }
            WatchProbeLog.shared.note("directReactivate", [
                "activated": activated,
                "error": failure as Any,
                "ms": Int((at - startedAt) * 1000),
                "routeBefore": routeBefore,
                "routeAfter": session.currentRoute.outputs.map { $0.portType.rawValue },
                "engineBefore": engineBefore,
                "engineAfter": self.audio.isEngineRunning,
                "ready": self.session?.isReady == true,
                "speaking": self.audio.isPlaying,
                "screen": "\(self.scenePhase)",
            ])
        }
    }

    /// Whether a Watch message reaches (and wakes) Conduit on the iPhone
    /// in this state: the screen off, the phone locked.
    private func probeLinkIfDue() {
        guard !probeInFlight, now - lastProbeAt >= Self.linkProbeInterval else { return }
        probeInFlight = true
        lastProbeAt = now
        let id = callID
        let sentAt = now
        let screenOff = scenePhase != .active
        let reachable = link.isReachable
        probes += 1
        if screenOff { probesScreenOff += 1 }
        link.send(.ping(callID: nil), reply: { [weak self] _ in
            self?.probeDone(id, ok: true, sentAt: sentAt, screenOff: screenOff, reachable: reachable, error: nil)
        }, failure: { [weak self] error in
            self?.probeDone(id, ok: false, sentAt: sentAt, screenOff: screenOff, reachable: reachable, error: error.localizedDescription)
        })
    }

    private func probeDone(_ id: UInt32, ok: Bool, sentAt: TimeInterval, screenOff: Bool, reachable: Bool, error: String?) {
        guard callID == id, isActive else { return }
        probeInFlight = false
        let elapsed = now - sentAt
        if ok {
            probesOK += 1
            if screenOff { probesOKScreenOff += 1 }
            probeTimes.append(elapsed)
        }
        guard probes <= 60 else { return }
        WatchProbeLog.shared.note("directLinkProbe", [
            "ok": ok,
            "ms": Int(elapsed * 1000),
            "error": error as Any,
            "screenOff": screenOff,
            "reachableBefore": reachable,
            "reachableAfter": link.isReachable,
        ])
    }

    /// Hermes said goodbye (end_conversation): the microphone closes and
    /// the call ends once the goodbye has played.
    private func requestEnd() {
        guard endRequestedAt == nil, isActive else { return }
        endRequestedAt = now
        pendingSamples = []
        phase = .ending
    }

    private func end(reason: String) {
        guard isActive else { return }
        finish(reason)
    }

    private func reset() {
        callID = UInt32.random(in: 1...UInt32.max)
        callUUID = UUID()
        callStartedDate = Date()
        callStartedAt = now
        session?.stop()
        session = nil
        tokens = nil
        meter = WatchSocketMeter(choice: .current)
        openingPrompt = nil
        hasSentOpening = false
        caption = nil
        isMuted = false
        lastTurnSummary = nil
        route = nil
        runningJobs = 0
        keepAlive = KeepAlive.current
        audioSessionActivated = nil
        systemCallActivated = nil
        systemCallReadyAt = nil
        sessionRequests = 0
        sessionAt = nil
        connectStartedAt = nil
        firstReadyAt = nil
        reconnectStartedAt = nil
        reconnectTimes = []
        connectionReadyAt = nil
        connectionLifetimes = []
        pathNotes = 0
        lastTickAt = nil
        reactivation = .current
        audioActivatedAt = nil
        lastActivationAt = nil
        reactivationStartedAt = nil
        reactivating = false
        reactivations = 0
        reactivationFailures = 0
        reactivationTimes = []
        maxReactivationCaptureGap = 0
        routeChangesAtStart = audio.routeChanges
        firstDropAt = nil
        probeInFlight = false
        lastProbeAt = 0
        probes = 0
        probesOK = 0
        probesScreenOff = 0
        probesOKScreenOff = 0
        probeTimes = []
        watchSuspendedMs = 0
        watchGaps = 0
        handoffStartedAt = nil
        handoffTimes = []
        drops = 0
        goAways = 0
        loggedResumable = false
        socketWaitNotes = 0
        tokensFromPhone = 0
        tokensReused = 0
        tokenFailures = 0
        suppressingModelTurn = false
        modelTurnActive = false
        lastUserSpeechAt = nil
        lastModelTurnEndedAt = nil
        lastModelAudioAt = nil
        awaitingReplySince = nil
        unansweredTurns = 0
        endRequestedAt = nil
        transcript = []
        openUserLine = nil
        openAssistantLine = nil
        toolsInFlight = []
        withdrawnToolIDs = []
        quietQueue = []
        toolCalls = 0
        toolsAnsweredLive = 0
        toolsUnreachable = 0
        jobsQueued = 0
        pollInFlight = false
        lastPollAt = 0
        polls = 0
        pollsFailed = 0
        textUpdatesSent = 0
        pendingSamples = []
        sendsInFlight = 0
        lastPlaybackEndedAt = nil
        activity = WatchVoiceActivity()
        speechEndAtTurnStart = nil
        awaitingFirstAudio = false
        lastAudioChunkAt = nil
        maxAudioGap = 0
        lastCaptureAt = nil
        maxCaptureGap = 0
        replyTimes = []
        turns = 0
        turnsWhileScreenOff = 0
        chunksUp = 0
        chunksDropped = 0
        sendFailures = 0
        liveSince = nil
        screenOffSince = scenePhase == .active ? nil : now
        screenOffSeconds = 0
        reachabilityChangesAtStart = link.reachabilityChanges
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        batteryAtStart = WKInterfaceDevice.current().batteryLevel
    }

    private func finish(_ reason: String?) {
        guard isActive else { return }
        timers.forEach { $0.invalidate() }
        timers = []
        let systemCallHolding = WatchSystemCall.isHoldingCall
        session?.stop()
        session = nil
        tokens = nil
        // Asked to end before the audio stops; CallKit finishes later.
        if keepAlive == .callKit { WatchSystemCall.shared.end() }
        audio.stop()
        if let since = screenOffSince { screenOffSeconds += now - since }
        let liveSeconds = liveSince.map { now - $0 } ?? 0
        phase = .ended(reason)
        // Queued, not sent: the iPhone saves the call whenever Conduit next
        // runs there, asleep or not right now.
        let saved = transcript.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let queued = link.queue(.directEnd(callID: callID, transcript: .init(
            callUUID: callUUID.uuidString,
            startedAt: callStartedDate,
            endedAt: Date(),
            turns: saved
        )))
        let battery = WKInterfaceDevice.current().batteryLevel
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
        let liveForRate = max(1, liveSeconds)
        WatchProbeLog.shared.report("directCallSummary", [
            "callID": Int(callID),
            "reason": reason as Any,
            "durationS": Int(now - callStartedAt),
            "liveS": Int(liveSeconds),
            "keepAlive": keepAlive.rawValue,
            "socket": meter.choice.rawValue,
            "reactivateEveryS": reactivation.rawValue,
            "reactivations": reactivations,
            "reactivationFailures": reactivationFailures,
            "reactivationMaxMs": WatchVoiceStats.milliseconds(reactivationTimes.max()) as Any,
            "maxReactivationCaptureGapMs": Int(maxReactivationCaptureGap * 1000),
            "firstDropSinceActivationS": firstDropAt.flatMap { drop in audioActivatedAt.map { Int(drop - $0) } } as Any,
            "routeChanges": audio.routeChanges - routeChangesAtStart,
            "linkProbes": probes,
            "linkProbesOK": probesOK,
            "linkProbesScreenOff": probesScreenOff,
            "linkProbesOKScreenOff": probesOKScreenOff,
            "linkProbeP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(probeTimes, 0.5)) as Any,
            "audioSessionActivated": audioSessionActivated as Any,
            "systemCallActivated": systemCallActivated as Any,
            "systemCallHolding": systemCallHolding,
            "keepAliveMs": systemCallReadyAt.map { Int(($0 - callStartedAt) * 1000) } as Any,
            "sessionMs": sessionAt.map { Int(($0 - callStartedAt) * 1000) } as Any,
            "sessionRequests": sessionRequests,
            "connectMs": firstReadyAt.flatMap { ready in connectStartedAt.map { Int((ready - $0) * 1000) } } as Any,
            "firstReadyMs": firstReadyAt.map { Int(($0 - callStartedAt) * 1000) } as Any,
            "api": meter.workingAPI?.rawValue as Any,
            "socketsOpened": meter.opened,
            "route": route as Any,
            "turns": turns,
            "turnsWhileScreenOff": turnsWhileScreenOff,
            "unansweredTurns": unansweredTurns,
            "replies": replyTimes.count,
            "replyP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(replyTimes, 0.5)) as Any,
            "replyP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(replyTimes, 0.95)) as Any,
            "maxAudioGapMs": Int(maxAudioGap * 1000),
            "maxCaptureGapMs": Int(maxCaptureGap * 1000),
            "drops": drops,
            "reconnects": reconnectTimes.count,
            "reconnectP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(reconnectTimes, 0.5)) as Any,
            "reconnectMaxMs": WatchVoiceStats.milliseconds(reconnectTimes.max()) as Any,
            "connectionLifetimesS": connectionLifetimes.map { Int($0) },
            "goAways": goAways,
            "handoffs": handoffTimes.count,
            "handoffP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(handoffTimes, 0.5)) as Any,
            "tokensFromPhone": tokensFromPhone,
            "tokensReused": tokensReused,
            "tokenFailures": tokenFailures,
            "toolCalls": toolCalls,
            "toolsAnsweredLive": toolsAnsweredLive,
            "toolsUnreachable": toolsUnreachable,
            "jobsQueued": jobsQueued,
            "polls": polls,
            "pollsFailed": pollsFailed,
            "textUpdatesSent": textUpdatesSent,
            "kbpsUp": Int(Double(meter.bytesUp) * 8 / liveForRate / 1000),
            "kbpsDown": Int(Double(meter.bytesDown) * 8 / liveForRate / 1000),
            "bytesUp": meter.bytesUp,
            "bytesDown": meter.bytesDown,
            "chunksUp": chunksUp,
            "chunksDropped": chunksDropped,
            "sendFailures": sendFailures,
            "screenOffS": Int(screenOffSeconds),
            "watchSuspendedMs": watchSuspendedMs,
            "watchGaps": watchGaps,
            "reachabilityChanges": link.reachabilityChanges - reachabilityChangesAtStart,
            "transcriptLines": saved.count,
            "transcriptQueued": queued,
            "batteryStart": batteryAtStart,
            "batteryEnd": battery,
        ])
    }
}

/// The Watch call's tokens: the one that came with the session, then a
/// new one from the iPhone for each connection, as on the iPhone. When
/// the iPhone can't be reached, a resumption reuses the token in hand
/// while it lasts: Gemini accepts it for resumptions until it expires.
@MainActor
final class WatchDirectTokens: GeminiLiveTokenProviding {
    enum Source: String {
        case first
        case phone
        case reused
        case failed
    }

    /// A reused token needs this long left, so it doesn't expire mid-setup.
    static let reuseMargin: TimeInterval = 60

    var fetch: (@MainActor () async throws -> GeminiLiveToken)?
    var canResume: @MainActor () -> Bool = { false }
    var onIssued: ((Source, String?) -> Void)?
    private var first: GeminiLiveToken?
    private var latest: GeminiLiveToken

    init(first: GeminiLiveToken) {
        self.first = first
        latest = first
    }

    func availability() async throws -> GeminiLiveAvailability {
        .available(model: latest.model)
    }

    func freshToken() async throws -> GeminiLiveToken {
        if let first {
            self.first = nil
            onIssued?(.first, nil)
            return first
        }
        do {
            guard let fetch else { throw WatchDirectError.ended }
            let token = try await fetch()
            latest = token
            onIssued?(.phone, nil)
            return token
        } catch {
            let lasts = latest.expiresAt.map { $0.timeIntervalSinceNow > Self.reuseMargin } ?? true
            if canResume(), lasts {
                onIssued?(.reused, error.localizedDescription)
                return latest
            }
            onIssued?(.failed, error.localizedDescription)
            throw error
        }
    }
}

enum WatchDirectError: LocalizedError {
    case ended
    case unreadable
    case timedOut
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .ended: return "The call ended."
        case .unreadable: return "Conduit on the iPhone sent something this Watch app can't read."
        case .timedOut: return "Conduit on the iPhone didn't answer in time."
        case .refused(let reason): return reason
        }
    }
}
