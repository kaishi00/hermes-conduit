//
//  WatchDirectCallModel.swift
//  Conduit Watch
//
//  A Gemini Live call the Watch makes itself
//  (designs/apple-watch-voice-direct.md), with the iPhone's own
//  GeminiLiveSession (Shared/GeminiLive): the same setup, resumption,
//  context-window compression, transcription, GoAway handoff and retries
//  as a call on the iPhone. The iPhone builds the session (instructions,
//  persona, memory, functions, voice) and hands over a single-use token;
//  after that it only runs the tools: each function call goes to it as a
//  Watch message, and while jobs run the Watch asks it for their news.
//  With the call's grant, lookups go through the push relay while the
//  iPhone can't be reached, and jobs always do (WatchJobRelay.swift): the
//  Watch asks Hermes for their news itself and shows a job's approval
//  request with Approve and Deny.
//  The audio goes straight between the Watch and Google, through the
//  iPhone's Bluetooth link or over Wi-Fi.
//
//  watchOS allows that socket only in TN3135's cases. The call's
//  play-and-record audio session is the one it uses: activated
//  asynchronously before the engine starts, and again every 25 s
//  (FB24377808). No CallKit, so no system call screen.
//
//  Half duplex: the microphone isn't sent while Gemini speaks, nor for a
//  short echo tail after (the Watch can't cancel its own echo), and a tap
//  stops Gemini.
//
//  A call to Grok runs here the same way, with the iPhone's own
//  GrokLiveSession: the iPhone builds the same setup and runs the same
//  tools, but xAI's session is held by the Hermes host on its own xAI
//  sign-in, and the Watch reaches it through the call grant's audio bridge
//  (WatchGrokBridgeSocket) instead of a token. xAI has no resumption: a
//  dropped connection is a new session, told the conversation so far.
//
//  Logs what a support question needs: each step of the start, each
//  reply's time from the end of the user's speech to audible speech,
//  reconnects and GoAway handoffs, unanswered turns, tool calls, data both
//  ways, gaps in the audio, time with the screen off, and battery.
//

import AVFAudio
import Foundation
import Network
import SwiftUI
import WatchKit

@MainActor
final class WatchDirectCallModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Starting the Watch's call and asking the iPhone for a session.
        case preparing
        case connecting
        case listening
        case speaking
        case reconnecting
        /// Gemini's session broke and couldn't be resumed, and a fresh one
        /// can't start yet: it waits for the iPhone (the wrist comes up)
        /// when Hermes couldn't send a token through the grant.
        case lost
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
    /// After a tool's answer or a text turn goes to the model, job news
    /// waits this long at most for the model's reply to start (round 6:
    /// news sent in that gap took the reply's place).
    static let replyWait: TimeInterval = 8
    /// The oldest tool call still running holds job news back this long at
    /// most: past the relay client's own wait, so a relayed call is
    /// answered or given up first.
    static let toolHoldLimit: TimeInterval = 40
    /// Gemini's session broke past resuming (round 6: 1011 "Internal error
    /// encountered", then the same on every resumption): the call starts a
    /// fresh session and tells it the conversation so far. Its token comes
    /// from the iPhone or, with the wrist down, from Hermes through the
    /// call's grant (live_token). Without either the call waits this long
    /// for the wrist, a few times a call at most.
    static let rejoinWait: TimeInterval = 120
    static let maxRejoins = 3
    /// A rejoin that hasn't come back by then gives up, as a failed one
    /// does. Its token can wait on the relay as long as a tool call.
    static let rejoinHangLimit: TimeInterval = sessionWait + WatchToolRelayClient.requestTimeout
    /// A goodbye closes the call once Gemini has made no sound this long,
    /// or after the timeout whatever it's doing (the iPhone's values).
    static let endGrace: TimeInterval = 1
    static let endTimeout: TimeInterval = 8
    /// While this call's jobs run, the Watch asks the iPhone this often.
    static let pollInterval: TimeInterval = 20
    /// A turn the user spoke that gets no reply within this long counts
    /// as unanswered.
    static let unansweredAfter: TimeInterval = 15
    /// The call's timeline: this often for the first 2 minutes after the
    /// audio session's activation (the reported revocation comes at 35 to
    /// 39 s), then every 30 s.
    static let earlyTimelineInterval: TimeInterval = 5
    static let lateTimelineInterval: TimeInterval = 30
    static let earlyTimelineSpan: TimeInterval = 120
    /// The audio session is activated again this often: watchOS revokes
    /// the network path 35 to 39 s after an activation despite live audio
    /// (FB24377808, open with Apple), and activating again before then
    /// moves the deadline. The device runs held calls for 13 minutes with
    /// the wrist down this way, and lost the path at 35 s without it.
    static let reactivateEvery: TimeInterval = 25
    /// A reactivation still running after this long counts as failed.
    static let reactivationTimeout: TimeInterval = 10
    /// Calls the iPhone answers once nobody speaks (NON_BLOCKING lookups).
    static let whenIdleTools: Set<String> = ["web_search", "recall_memory"]
    /// A tool grant this close to its end is renewed while the iPhone can
    /// be reached.
    static let grantRenewMargin: TimeInterval = 10 * 60
    /// A grant with this few calls left is renewed too, before job news
    /// spends it.
    static let grantRenewCallHeadroom = 10
    /// Between asks for a new grant, and how many a call makes at most.
    static let grantRequestInterval: TimeInterval = 60
    static let maxGrantRequests = 6
    /// Job news through the relay: Hermes holds each ask up to this long
    /// for news, and the next ask waits this long after one with none,
    /// so a running job costs about two of the grant's calls a minute.
    static let jobNewsWait = 15
    static let jobNewsPause: TimeInterval = 15
    /// After news, or an ask that failed.
    static let jobNewsRetry: TimeInterval = 2

    /// Who the Watch talks to: Gemini Live straight from the Watch, or
    /// Grok on the Hermes host through the call grant's audio bridge.
    enum Engine: Equatable {
        case gemini
        case grok
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var caption: String?
    @Published private(set) var isMuted = false
    @Published private(set) var runningJobs = 0
    /// Jobs started through the relay that Hermes reports running.
    @Published private(set) var relayJobsRunning = 0
    /// A job's approval request, for the Approve and Deny card.
    @Published private(set) var pendingApproval: WatchJobAnswer.Approval?

    private let link = WatchLink.shared
    private let audio = WatchAudio()
    private var meter = WatchSocketMeter()
    private var session: GeminiLiveSessionControlling?
    private(set) var engine: Engine = .gemini
    /// The call from Hermes this call answers, so the iPhone opens it with
    /// what Hermes called about (designs/hermes-calls-watch.md).
    private var ring: String?
    /// Grok's bridge streams opened on the call's grant, which takes 32.
    private var grokStreams = 0
    private var tokens: WatchDirectTokens?
    private var openingPrompt: String?
    /// The profile's spoken end phrases: the user saying one ends the
    /// call, as on the iPhone, even if the model doesn't call
    /// end_conversation.
    private var endPhrases: [String] = []
    /// The transcript line of the user's latest utterance.
    private var exchangeUserLine: Int?
    private var hasSentOpening = false
    private(set) var callID: UInt32 = 0
    private var callUUID = UUID()
    private var callStartedDate = Date()
    private var timers: [Timer] = []
    private var scenePhase: ScenePhase = .active

    // Start
    private var callStartedAt: TimeInterval = 0
    private var audioSessionActivated: Bool?
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
    /// When the audio session was first activated, and last activated
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
    private var playbackStallsAtStart = 0
    private var firstDropAt: TimeInterval?
    private var handoffStartedAt: TimeInterval?
    private var handoffTimes: [Double] = []
    private var drops = 0
    private var goAways = 0
    private var loggedResumable = false
    private var socketNotes = 0
    private var restartingAudio = false
    /// Siri or an alarm stopped the microphone, and nothing has started it
    /// again: the call needs a tap, whatever a rejoin did to the phase.
    private var microphoneStopped = false
    private var restartAttempts = 0
    /// The Watch's network path for the whole call, whichever socket runs:
    /// a refused WebSocket was reported with the path unsatisfied, and
    /// FB24377808 revokes it about 35 s after activation.
    private var pathMonitor: NWPathMonitor?
    private var monitorFirstStatus: String?
    private var monitorStatus: String?
    private var monitorUses: [String] = []
    private var monitorUpdates = 0
    private var firstUnsatisfiedAt: TimeInterval?
    private var tokensFromPhone = 0
    private var tokensReused = 0
    private var tokensFromRelay = 0
    private var tokenFailures = 0
    /// Waiting for the iPhone to start a fresh session after the old one
    /// broke, and why it broke (the call ends with it if the wait runs out).
    private var rejoinWaitingSince: TimeInterval?
    private var rejoinReason: String?
    /// A frozen session's replacement carries on without saying it's back.
    private var rejoinCause = WatchRejoin.Cause.broke
    /// A fresh session is starting: it's told the conversation once ready.
    private var rejoinStartedAt: TimeInterval?
    /// It started with the iPhone out of reach, so on a token from the
    /// relay; once one of those fails, the next waits for the wrist.
    private var rejoinWristDown = false
    private var wristDownRejoinFailed = false
    private var rejoins = 0
    private var rejoinTimes: [Double] = []
    private var rejoinsHung = 0
    /// Microphone audio dropped while the call had no session.
    private var samplesDroppedWhileDown = 0
    /// Added to the session's connection generation. A fresh session
    /// doesn't count as a new connection there, but calls made on the
    /// broken one can't be answered on it.
    private var generationOffset = 0

    // Conversation
    private var suppressingModelTurn = false
    private var modelTurnActive = false
    private var lastUserSpeechAt: TimeInterval?
    private var lastModelTurnEndedAt: TimeInterval?
    private var lastModelAudioAt: TimeInterval?
    private var awaitingReplySince: TimeInterval?
    /// A tool's answer or a text turn went to the model and its reply
    /// hasn't started yet.
    private var awaitingAnswerSince: TimeInterval?
    private var unansweredTurns = 0
    /// The user's words came back transcribed and the model hasn't spoken
    /// or called a tool since: a reply it owes (WatchStall). Counting the
    /// turn unanswered doesn't clear it.
    private var replyOwedSince: TimeInterval?
    /// A turn ended with nothing from the model after the user's words: it
    /// chose silence, so the session works.
    private var silentTurnSinceUser = false
    /// The stall prompt went out and nothing has come back from the model.
    private var stallPromptedAt: TimeInterval?
    private var stallPrompts = 0
    private var stallPromptsAnswered = 0
    private var stallPromptsSilent = 0
    private var stalls = 0
    private var silentTurns = 0
    /// The model's last audio, words, tool call or turn end; and the last
    /// message of any kind from Gemini.
    private var lastModelEventAt: TimeInterval?
    private var lastServerEventAt: TimeInterval?
    /// The model turn under way, for its log line: its first output and
    /// first audio, what it answered, and how much it said.
    private var turnStartedAt: TimeInterval?
    private var turnFirstAudioAt: TimeInterval?
    private var turnHeardAt: TimeInterval?
    private var turnVoicedAt: TimeInterval?
    private var turnAnswering: String?
    private var turnAudioSeconds: Double = 0
    private var turnTools = 0
    private var turnMaxGap: TimeInterval = 0
    private var turnEndedByInterruption = false
    private var modelTurnNotes = 0
    /// From the user's last transcribed words to the first audio of the
    /// reply: Gemini's side of the reply time.
    private var heardReplyTimes: [Double] = []
    private var endRequestedAt: TimeInterval?
    /// The call's settled lines, for the transcript page and the saved call.
    @Published private(set) var transcript: [WatchVoiceWire.DirectTurn] = []
    private var openUserLine: Int?
    private var openAssistantLine: Int?

    // Tools
    private var toolsInFlight: Set<String> = []
    /// When each call came, for the ones still running.
    private var toolCalledAt: [String: TimeInterval] = [:]
    /// Calls the model made after it had started speaking in that turn,
    /// or spoke after: it has acknowledged them.
    private var toolCallsSpokenFor: Set<String> = []
    private var startJobsTakenSilently = 0
    private var withdrawnToolIDs: Set<String> = []
    private var quietQueue: [WatchVoiceWire.DirectOutgoing] = []
    private var toolCalls = 0
    private var toolsAnsweredLive = 0
    private var toolsUnreachable = 0
    private var jobsQueued = 0
    /// Tools asked for with the wrist down (Eric's choice for Watch tools,
    /// 2026-10-07): each was answered at once with a request to raise the
    /// wrist, and runs on the iPhone once the link is back, so the model
    /// hears how it went. A job still waiting when the call ends goes by
    /// `transferUserInfo`, which outlives the call.
    private var wristQueue: [(call: WatchVoiceWire.DirectToolCall, at: TimeInterval, date: Date)] = []
    private var toolsWaitedForWrist = 0
    private var wristWaits: [TimeInterval] = []
    /// The call's lookups through the push relay while the iPhone can't be
    /// reached (WatchToolRelayClient). Nil without a grant, or once it
    /// ended; the iPhone's path then takes every call.
    private var toolRelay: WatchToolRelayClient?
    /// A Grok session that fails this close to its grant's end doesn't
    /// rejoin: the relay closes the bridge at the deadline anyway.
    static let grantEndMargin: TimeInterval = 5
    private var hadToolGrant = false
    private var grantRequestInFlight = false
    private var lastGrantRequestAt: TimeInterval = 0
    private var grantRequests = 0
    private var grantsRenewed = 0
    /// Relay lookups Hermes answered with results; its error answers (a
    /// search limit, a failed lookup) are counted apart, and neither kind
    /// of answer counts as a failure.
    private var toolsViaRelay = 0
    private var relayErrorAnswers = 0
    private var relayTimeouts = 0
    private var relayFallbacks = 0
    /// Relay calls that went out (spending one of the grant's calls) and
    /// came back without an answer. Timeouts have their own count, so the
    /// calls sent = answers + error answers + timeouts + failures.
    private var relayFailures = 0
    private var relayTimes: [TimeInterval] = []
    private var pollInFlight = false
    private var lastPollAt: TimeInterval = 0
    private var polls = 0
    private var pollsFailed = 0
    private var textUpdatesSent = 0
    /// Grants whose jobs may still run, asked for job news in turn. A
    /// renewal moves the call's jobs to the new grant; an old grant whose
    /// jobs Hermes kept stays here, open, while they run.
    private var jobRelays: [WatchToolRelayClient] = []
    /// The newest grant with jobs: a renewal asks Hermes to move its jobs
    /// to the new grant. Kept while gone (a spent budget) until a renewal
    /// answers, so its jobs aren't dropped meanwhile.
    private var jobsGrant: WatchToolRelayClient?
    /// Grants whose jobs moved, by id, to the grant they moved to: an
    /// answer still on its way from the old one counts for the new one.
    private var jobsMovedTo: [String: WatchToolRelayClient] = [:]
    private var jobsCarried = 0
    /// Running jobs per grant, as its last news said.
    private var relayRunning: [String: Int] = [:]
    /// Approval requests on screen, oldest first.
    private var approvals: [WatchJobAnswer.Approval] = []
    private var newsInFlight = false
    private var nextNewsAt: TimeInterval = 0
    /// Jobs this call started through the relay, for the user's cap.
    private var relayJobsStarted = 0
    /// The relay jobs this call started, for its saved transcript.
    private var jobLog = WatchVoiceWire.DirectJobLog()
    private var jobCallsViaRelay = 0
    private var jobNewsAsks = 0
    private var jobNewsFailed = 0
    private var jobNewsItems = 0
    private var approvalsShown = 0
    private var approvalsTapped = 0
    private var approvalsByVoice = 0
    private var approvalFailures = 0

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

    // The timeline: totals at the last entry, for each entry's deltas.
    private var lastTimelineAt: TimeInterval?
    private var timelineEntries = 0
    private var samplesCaptured = 0
    private var chunksSent = 0
    private var timelineMark = (captured: 0, chunksSent: 0, sendFailures: 0, bytesUp: 0, bytesDown: 0, framesDown: 0)
    private var windowMaxCaptureGap: TimeInterval = 0

    // Watch → iPhone messages during the call.
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

    func start(engine: Engine = .gemini, ring: String? = nil) async {
        guard !isActive else { return }
        reset()
        self.engine = engine
        self.ring = ring
        phase = .preparing
        // Before the audio session, to see what activating it changes.
        startPathMonitor()
        // Each await below can outlast the call: ended, and maybe a new
        // one started, by the time it returns.
        let id = callID
        guard await WatchAudio.requestPermission() else {
            if callID == id { finish(WatchAudioError.permissionDenied.localizedDescription) }
            return
        }
        guard callID == id, phase == .preparing else { return }
        // The audio session comes first: it's what allows the socket.
        let activatedHere = await activateAudioSession()
        if callID == id {
            audioSessionActivated = activatedHere
            if activatedHere {
                audioActivatedAt = now
                lastActivationAt = now
            }
        }
        // Ended meanwhile: the session activated here has no engine to
        // stop, unless a new call has it now.
        guard callID == id, phase == .preparing else {
            if activatedHere, !isActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            }
            return
        }
        // Never the synchronous activation: Apple DTS has a case where it
        // decided whether the network grant came.
        guard activatedHere else {
            finish(String(localized: "The Watch's audio didn't start. Try again."))
            return
        }
        do {
            try audio.start(options: audioOptions, playbackRate: GeminiLiveProtocol.outputSampleRate)
        } catch {
            finish(String(localized: "The microphone didn't start: \(error.localizedDescription)"))
            return
        }
        WatchCallLog.shared.note("directCallStart", [
            "callID": Int(callID),
            "audioSessionActivated": audioSessionActivated as Any,
            "audioMs": Int((now - callStartedAt) * 1000),
            "reachable": link.isReachable,
            "engine": "\(engine)",
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
        end(reason: WatchCallEnd.byUser)
    }

    /// The call activated the session itself, asynchronously; the engine
    /// only starts in it.
    private var audioOptions: WatchAudio.Options {
        WatchAudio.Options(activatesSession: false)
    }

    /// The session activated the way the reports of a working
    /// socket did (asynchronously), before the engine starts in it. Play
    /// and record with the default route policy, so the built-in speaker
    /// plays; long-form audio would want Bluetooth and can't record.
    private func activateAudioSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        let startedAt = now
        do {
            try session.setCategory(.playAndRecord, mode: .default, policy: .default, options: [])
            let activated = try await session.activate(options: [])
            WatchCallLog.shared.note("directAudioSession", [
                "activated": activated,
                "ms": Int((now - startedAt) * 1000),
                "outputs": session.currentRoute.outputs.map { $0.portType.rawValue },
                "inputs": session.currentRoute.inputs.map { $0.portType.rawValue },
            ])
            return activated
        } catch {
            let error = error as NSError
            WatchCallLog.shared.note("directAudioSession", ["activated": false, "domain": error.domain, "code": error.code])
            return false
        }
    }

    /// The orb: stops Gemini while it speaks, brings the microphone back
    /// after Siri or an alarm.
    func tapOrb() {
        if phase == .needsTap || microphoneStopped {
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
        WatchCallLog.shared.note("directInterrupt", ["callID": Int(callID), "screen": "\(scenePhase)"])
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
        WatchCallLog.shared.note("directScenePhase", [
            "phase": "\(newPhase)",
            "ready": session?.isReady == true,
            "reachable": link.isReachable,
        ])
    }

    // MARK: Session from the iPhone

    private func requestSession() {
        sessionRequests += 1
        let id = callID
        let request: WatchVoiceWire.Message = engine == .grok
            ? .grokStart(callID: id, version: WatchVoiceWire.version, ring: ring)
            : .directStart(callID: id, version: WatchVoiceWire.version, ring: ring)
        link.send(request, reply: { [weak self] answer in
            guard let self, self.callID == id, self.phase == .preparing else { return }
            switch answer {
            case .directSession(_, let session)? where self.engine == .gemini:
                self.begin(session)
            case .grokSession(_, let session)? where self.engine == .grok:
                self.begin(session)
            case .callRefused(_, let reason)?:
                WatchCallLog.shared.note("directRefused", ["reason": reason])
                self.finish(reason)
            default:
                self.finish(String(localized: "Conduit on the iPhone sent something this Watch app can't read. Update both."))
            }
        }, failure: { [weak self] error in
            guard let self, self.callID == id, self.phase == .preparing else { return }
            WatchCallLog.shared.note("directStartFailed", [
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

    private func begin(_ direct: WatchVoiceWire.DirectSession) {
        sessionAt = now
        guard let setup = WatchVoiceWire.DirectSetup(compressed: direct.setup),
              let functions = setup.declarations,
              let token = direct.token.geminiToken else {
            finish(String(localized: "The iPhone's session couldn't be read. Update Conduit on both devices."))
            return
        }
        openingPrompt = direct.openingPrompt
        endPhrases = direct.endPhrases ?? []
        let tokens = WatchDirectTokens(first: token)
        tokens.fetch = { [weak self] in
            guard let self else { throw WatchDirectError.ended }
            return try await self.requestToken()
        }
        tokens.relayFetch = { [weak self] in
            guard let self else { throw WatchDirectError.ended }
            return try await self.requestRelayToken()
        }
        tokens.onIssued = { [weak self] source, error in self?.tokenIssued(source, error: error) }
        let meter = self.meter
        meter.onSocketEvent = { [weak self] api, number, kind, fields in self?.socketEvent(api, number: number, kind: kind, fields) }
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
        if let grant = direct.toolGrant {
            hadToolGrant = true
            toolRelay = WatchToolRelayClient(grant)
            if toolRelay?.hasJobs == true { jobsGrant = toolRelay }
        }
        WatchCallLog.shared.note("directSession", [
            "afterTapMs": Int((now - callStartedAt) * 1000),
            "requests": sessionRequests,
            "setupBytes": direct.setupBytes,
            "compressedBytes": direct.setup.count,
            "model": token.model,
            "functions": functions.map(\.name),
            "googleSearch": direct.googleSearch,
            "opening": direct.openingPrompt != nil,
            "tokenExpiresInS": token.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any,
            "toolGrant": direct.toolGrant == nil ? "none" : (toolRelay == nil ? "unreadable" : "ok"),
            "relayTools": toolRelay.map { $0.tools.sorted() } as Any,
            "grantExpiresInS": toolRelay?.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any,
        ])
        phase = .connecting
        connectStartedAt = now
        session.start()
    }

    /// A Grok call: the same setup and tools as Gemini's, xAI's session
    /// on the Hermes host through the grant's audio bridge.
    private func begin(_ grok: WatchVoiceWire.GrokSession) {
        sessionAt = now
        guard let setup = WatchVoiceWire.DirectSetup(compressed: grok.setup),
              let functions = setup.declarations,
              let audioBridge = grok.grant.audio,
              let url = URL(string: audioBridge.url), url.scheme == "wss",
              let root = WatchToolSeal.data(base64URL: grok.grant.key), root.count == 32,
              let relay = WatchToolRelayClient(grok.grant) else {
            finish(String(localized: "The iPhone's session couldn't be read. Update Conduit on both devices."))
            return
        }
        guard audioBridge.version == Int(WatchAudioBridgeWire.version) else {
            finish(String(localized: "Update the Hermes notifier plugin and Conduit to matching versions."))
            return
        }
        openingPrompt = grok.openingPrompt
        endPhrases = grok.endPhrases ?? []
        let bridge = WatchGrokBridge(url: url, grantID: grok.grant.grantID, root: root, watchKey: grok.grant.watchKey, voice: grok.voice)
        let session = GrokLiveSession(
            client: WatchGrokConnection(url: url),
            instructions: setup.systemInstruction,
            functions: functions,
            voice: grok.voice,
            openSocket: { [weak self] _ in
                // A stream id is taken once per grant, and a grant takes 32.
                let stream: WatchAudioBridgeStream?
                var number = 0
                if let self, self.grokStreams < 30 {
                    self.grokStreams += 1
                    number = self.grokStreams
                    stream = WatchAudioBridgeStream(grantID: bridge.grantID, root: bridge.root)
                } else {
                    stream = nil
                }
                let socket = WatchGrokBridgeSocket(bridge: bridge, stream: stream)
                socket.onNote = { [weak self] kind, fields in self?.socketEvent(.grokBridge, number: number, kind: kind, fields) }
                return socket
            }
        )
        session.onEvent = { [weak self] in self?.handle($0) }
        session.onStateChange = { [weak self] in self?.sessionStateChanged($0) }
        session.onConnectionReplaced = { [weak self] in self?.connectionReplaced() }
        self.session = session
        // The bridge belongs to the grant, so the call keeps it: no renewal
        // (renewGrantIfDue skips Grok calls).
        hadToolGrant = true
        toolRelay = relay
        if relay.hasJobs { jobsGrant = relay }
        WatchCallLog.shared.note("directSession", [
            "engine": "grok",
            "afterTapMs": Int((now - callStartedAt) * 1000),
            "requests": sessionRequests,
            "setupBytes": grok.setupBytes,
            "compressedBytes": grok.setup.count,
            "functions": functions.map(\.name),
            "opening": grok.openingPrompt != nil,
            "engines": audioBridge.engines,
            "relayTools": relay.tools.sorted(),
            "grantExpiresInS": relay.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any,
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

    /// A new single-use token from Hermes through the grant's relay. The
    /// log has how it went, never the token.
    private func requestRelayToken() async throws -> GeminiLiveToken {
        guard let relay = toolRelay, relay.canRun(WatchLiveToken.tool) else { throw WatchDirectError.noRelayToken }
        let id = callID
        let sentAt = now
        let outcome = await relay.run(name: WatchLiveToken.tool, arguments: [:])
        guard callID == id, isActive else {
            WatchCallLog.shared.note("directRelayTokenAbandoned", [
                "outcome": outcome.logLabel,
                "reason": isActive ? "replaced" : "callEnded",
            ])
            throw WatchDirectError.ended
        }
        var fields: [String: Any] = [
            "ms": Int((now - sentAt) * 1000),
            "outcome": outcome.logLabel,
            "screen": "\(scenePhase)",
            "reachable": link.isReachable,
            "grantCalls": relay.callsSent,
        ]
        defer { WatchCallLog.shared.note("directRelayToken", fields) }
        switch outcome {
        case .answered(let body):
            if let token = WatchLiveToken.token(body: body) {
                fields["expiresInS"] = token.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any
                return token
            }
            let detail = (body["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            fields["status"] = body["status"] as Any
            throw WatchDirectError.relayToken(detail ?? String(localized: "Hermes sent no usable Gemini token."))
        case .timedOut:
            throw WatchDirectError.relayToken(String(localized: "Hermes didn't answer in time."))
        case .unavailable(let reason, let grantGone, _):
            fields["reason"] = reason
            fields["grantGone"] = grantGone
            if grantGone, toolRelay === relay {
                toolRelay = nil
                closeIfUnused(relay)
            }
            throw WatchDirectError.relayToken(String(localized: "The relay couldn't reach Hermes (\(reason))."))
        }
    }

    private func tokenIssued(_ source: WatchDirectTokens.Source, error: String?) {
        switch source {
        case .phone: tokensFromPhone += 1
        case .reused: tokensReused += 1
        case .relay: tokensFromRelay += 1
        case .failed: tokenFailures += 1
        case .first: break
        }
        var fields: [String: Any] = [
            "source": source.rawValue,
            "screen": "\(scenePhase)",
            "reachable": link.isReachable,
        ]
        switch source {
        case .reused, .relay:
            // Served anyway: the error is the iPhone's.
            fields["phoneError"] = error as Any
        case .first, .phone, .failed:
            fields["error"] = error as Any
        }
        WatchCallLog.shared.note("directToken", fields)
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
                WatchCallLog.shared.note("directReady", [
                    "sinceTapMs": Int((at - callStartedAt) * 1000),
                    "connectMs": connectStartedAt.map { Int((at - $0) * 1000) } as Any,
                ])
            }
            if let since = reconnectStartedAt {
                reconnectTimes.append(at - since)
                reconnectStartedAt = nil
                WatchCallLog.shared.note("directReconnected", ["ms": Int((at - since) * 1000), "screen": "\(scenePhase)"])
            }
            if let since = handoffStartedAt {
                handoffTimes.append(at - since)
                handoffStartedAt = nil
                WatchCallLog.shared.note("directHandoff", ["ms": Int((at - since) * 1000), "screen": "\(scenePhase)"])
            }
            connectionReadyAt = at
            // A later reconnect may ask the relay once again.
            tokens?.allowRelayTry()
            if phase == .connecting || phase == .reconnecting { phase = restingPhase }
            if let since = rejoinStartedAt {
                rejoinStartedAt = nil
                rejoinTimes.append(at - since)
                wristDownRejoinFailed = false
                let dropped = samplesDroppedWhileDown + pendingSamples.count
                WatchCallLog.shared.note("directRejoined", [
                    "ms": Int((at - since) * 1000),
                    "lines": transcript.count,
                    "wristDown": rejoinWristDown,
                    // What the user said meanwhile, never sent: the fresh
                    // session is told it wasn't heard.
                    "discardedAudioMs": Int(Double(dropped) / WatchAudio.captureRate * 1000),
                    "screen": "\(scenePhase)",
                ])
                sendRejoinContext()
            }
            samplesDroppedWhileDown = 0
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
            // The answer the drop cut off stops playing and its turn is
            // over, as on the iPhone, so job news and the unanswered check
            // don't wait for a turnComplete that never comes. Unlike the
            // iPhone, the turn's transcript lines close and it counts as a
            // turn: an answer the resumption finishes counts twice, which
            // `cutAnswer` in the log marks.
            let cutAnswer = modelTurnActive || audio.isPlaying
            if audio.isPlaying {
                audio.stopPlayback()
                lastPlaybackEndedAt = now
            }
            suppressingModelTurn = false
            if modelTurnActive { modelTurnEnded("cut") }
            turnRecordEnded("cut")
            // A prompt sent on the old connection can't be judged on this one.
            stallPromptedAt = nil
            WatchCallLog.shared.note("directReconnecting", [
                "cutAnswer": cutAnswer,
                "aliveS": alive.map { Int($0) } as Any,
                "sinceActivationS": lastActivationAt.map { Int(now - $0) } as Any,
                "sinceFirstActivationS": audioActivatedAt.map { Int(now - $0) } as Any,
                "screen": "\(scenePhase)",
                "reachable": link.isReachable,
            ])
        case .failed(let message):
            WatchCallLog.shared.note("directFailed", ["message": message, "screen": "\(scenePhase)", "rejoins": rejoins])
            // Once the call has been live, a fresh session carries it on;
            // not for Grok once its grant is over, which its bridge was.
            let grantOver = engine == .grok && (toolRelay.map { $0.isGone || $0.expires(within: Self.grantEndMargin) } ?? true)
            if firstReadyAt != nil, endRequestedAt == nil, rejoins < Self.maxRejoins, !grantOver {
                waitToRejoin(message)
            } else {
                finish(message)
            }
        case .idle, .connecting, .stopped:
            break
        }
    }

    /// The connection a tool call is answered on (see generationOffset).
    private var liveGeneration: Int? {
        session.map { $0.connectionGeneration + generationOffset }
    }

    /// The session broke past resuming. A fresh one needs a new token: at
    /// once from the iPhone if it can be reached, or from Hermes through
    /// the grant with the wrist down. Otherwise, or once a wrist-down
    /// rejoin has failed, it waits for the wrist, and a chime says so.
    private func waitToRejoin(_ reason: String, cause: WatchRejoin.Cause = .broke) {
        if rejoinStartedAt != nil, rejoinWristDown { wristDownRejoinFailed = true }
        rejoinStartedAt = nil
        if audio.isPlaying {
            audio.stopPlayback()
            lastPlaybackEndedAt = now
        }
        suppressingModelTurn = false
        if modelTurnActive { modelTurnEnded("cut") }
        turnRecordEnded("cut")
        // The fresh session is told the conversation, and asked to answer
        // what went unanswered.
        stallPromptedAt = nil
        replyOwedSince = nil
        awaitingReplySince = nil
        silentTurnSinceUser = false
        // Not a resumption: its time isn't one.
        reconnectStartedAt = nil
        rejoinWaitingSince = now
        rejoinReason = reason
        rejoinCause = cause
        samplesDroppedWhileDown += pendingSamples.count
        pendingSamples = []
        phase = .lost
        let relayToken = !wristDownRejoinFailed && canMintThroughRelay
        WatchCallLog.shared.note("directRejoinWaiting", [
            "reason": reason,
            "rejoins": rejoins,
            "reachable": link.isReachable,
            "relayToken": relayToken,
            "screen": "\(scenePhase)",
        ])
        // Grok's bridge goes through the relay: it never needs the iPhone.
        if link.isReachable || relayToken || engine == .grok {
            rejoin()
        } else {
            // The chime tells the user the call went, so the new session
            // says it's back.
            rejoinCause = .broke
            audio.enqueue(Self.lostChime(), sampleRate: GeminiLiveProtocol.outputSampleRate)
        }
    }

    /// The grant can bring a fresh Gemini token through the relay.
    private var canMintThroughRelay: Bool {
        toolRelay?.canRun(WatchLiveToken.tool) == true
    }

    /// From the tick: a rejoin that hasn't come back gives up, as a failed
    /// one does, and counts as one.
    private func rejoinHungIfDue() {
        guard let since = rejoinStartedAt, now - since >= Self.rejoinHangLimit, let session else { return }
        rejoinsHung += 1
        WatchCallLog.shared.note("directRejoinHung", [
            "ms": Int((now - since) * 1000),
            "rejoin": rejoins,
            "wristDown": rejoinWristDown,
            "waitingOnRelay": tokens?.relayInFlight == true,
            "screen": "\(scenePhase)",
        ])
        session.stop()
        let reason = engine == .grok
            ? String(localized: "Grok didn't come back after the connection broke.")
            : String(localized: "Gemini didn't come back after the connection broke.")
        if endRequestedAt == nil, rejoins < Self.maxRejoins {
            waitToRejoin(reason)
        } else {
            finish(reason)
        }
    }

    /// From the tick: the wrist came up, or the wait ran out.
    private func rejoinIfDue() {
        guard let since = rejoinWaitingSince else { return }
        // Hermes said goodbye meanwhile: no new session for it.
        guard endRequestedAt == nil else {
            rejoinWaitingSince = nil
            finish(WatchCallEnd.goodbye)
            return
        }
        if link.isReachable || engine == .grok {
            rejoin()
        } else if now - since >= Self.rejoinWait {
            finish(rejoinReason)
        }
    }

    private func rejoin() {
        guard let session else {
            // Nothing to start again: the call can't come back.
            rejoinWaitingSince = nil
            finish(rejoinReason)
            return
        }
        rejoinWaitingSince = nil
        // Each rejoin may ask Hermes for one token through the relay.
        tokens?.allowRelayTry()
        rejoins += 1
        rejoinStartedAt = now
        rejoinWristDown = !link.isReachable
        // Calls made on the broken session can't be answered on the fresh
        // one: their answers go out as text updates instead.
        generationOffset += 1
        phase = .reconnecting
        WatchCallLog.shared.note("directRejoin", ["rejoin": rejoins, "wristDown": rejoinWristDown, "screen": "\(scenePhase)"])
        // Starts over without the resumption handle, on a token from the
        // iPhone or the relay (a fresh session can't reuse the one in hand).
        session.start()
    }

    /// A fresh session knows nothing of the call: it's told the
    /// conversation so far, and says it's back (or, after a freeze, just
    /// answers).
    private func sendRejoinContext() {
        guard let session else { return }
        // Whatever the microphone kept while the call was down would
        // talk over that.
        pendingSamples = []
        let text = WatchRejoin.prompt(transcript, after: rejoinCause)
        awaitingAnswerSince = now
        textUpdatesSent += 1
        noteTextSent("rejoin", text)
        let id = callID
        session.send(.textTurn(text), onSent: nil, onFailure: { [weak self] in
            guard let self, self.callID == id else { return }
            self.quietQueue.insert(.textWhenIdle(text), at: 0)
        })
    }

    /// Two falling notes: the call lost Gemini and waits for the wrist.
    static func lostChime() -> [Int16] {
        let rate = GeminiLiveProtocol.outputSampleRate
        let noteLength = Int(rate * 0.18)
        let fade = Int(rate * 0.01)
        var samples: [Int16] = []
        for frequency in [880.0, 660.0] {
            for index in 0..<noteLength {
                let edge = min(index, noteLength - 1 - index)
                let envelope = edge < fade ? Double(edge) / Double(fade) : 1
                let value = sin(2 * Double.pi * frequency * Double(index) / rate) * 0.3 * envelope
                samples.append(Int16(value * Double(Int16.max)))
            }
            samples.append(contentsOf: [Int16](repeating: 0, count: Int(rate * 0.06)))
        }
        return samples
    }

    /// A new connection took over: calls opened on the old one can't be
    /// answered on it, so their answers go out as text updates instead.
    private func connectionReplaced() {
        WatchCallLog.shared.note("directConnectionReplaced", ["openCalls": toolsInFlight.count])
        // xAI has no resumption: the new session is told the conversation
        // once it's ready, as after a rejoin.
        if engine == .grok, rejoinStartedAt == nil {
            rejoinStartedAt = now
            rejoinWristDown = !link.isReachable
            rejoinCause = .broke
        }
    }

    /// Each socket's states or callbacks, timed from the audio session's
    /// activation like the path changes.
    private func socketEvent(_ api: WatchSocketAPI, number: Int, kind: String, _ fields: [String: Any]) {
        socketNotes += 1
        guard socketNotes <= 150 else { return }
        var fields = fields
        fields["api"] = api.rawValue
        fields["socket"] = number
        fields["kind"] = kind
        fields["t"] = Int(now - callStartedAt)
        fields["sinceActivationS"] = lastActivationAt.map { Int(now - $0) } as Any
        fields["sinceFirstActivationS"] = audioActivatedAt.map { Int(now - $0) } as Any
        fields["screen"] = "\(scenePhase)"
        fields["phase"] = "\(phase)"
        WatchCallLog.shared.note("directSocket", fields)
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        let id = callID
        monitor.pathUpdateHandler = { [weak self] path in
            WatchVoiceMain.async { self?.pathMonitorUpdate(path, callID: id) }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func pathMonitorUpdate(_ path: NWPath, callID id: UInt32) {
        guard callID == id, pathMonitor != nil else { return }
        var fields = WatchNetworkPath.describe(path)
        let status = fields["status"] as? String
        if monitorFirstStatus == nil { monitorFirstStatus = status }
        monitorStatus = status
        monitorUses = (fields["uses"] as? [String]) ?? []
        monitorUpdates += 1
        if path.status != .satisfied, firstUnsatisfiedAt == nil, audioActivatedAt != nil {
            firstUnsatisfiedAt = now
        }
        guard monitorUpdates <= 60 else { return }
        fields["t"] = Int(now - callStartedAt)
        fields["sinceActivationS"] = lastActivationAt.map { Int(now - $0) } as Any
        fields["sinceFirstActivationS"] = audioActivatedAt.map { Int(now - $0) } as Any
        fields["screen"] = "\(scenePhase)"
        fields["phase"] = "\(phase)"
        WatchCallLog.shared.note("directPathMonitor", fields)
    }

    private var restingPhase: Phase {
        if endRequestedAt != nil { return .ending }
        return audio.isPlaying ? .speaking : .listening
    }

    private func sendOpeningIfNeeded() {
        guard !hasSentOpening, let openingPrompt, let session, session.isReady else { return }
        hasSentOpening = true
        awaitingAnswerSince = now
        noteTextSent("opening", openingPrompt)
        let id = callID
        session.send(.textTurn(openingPrompt), onSent: nil, onFailure: { [weak self] in
            guard let self, self.callID == id else { return }
            self.hasSentOpening = false
        })
    }

    // MARK: Server events

    private func handle(_ event: GeminiLiveProtocol.ServerEvent) {
        guard isActive else { return }
        lastServerEventAt = now
        switch event {
        case .setupComplete:
            break
        case .resumptionUpdate(let handle, let resumable):
            if !loggedResumable, resumable, handle != nil {
                loggedResumable = true
                WatchCallLog.shared.note("directResumable")
            }
        case .audio(let pcm, let sampleRate):
            guard !suppressingModelTurn else { return }
            let at = now
            if modelTurnActive, let last = lastAudioChunkAt {
                maxAudioGap = max(maxAudioGap, at - last)
                turnMaxGap = max(turnMaxGap, at - last)
            }
            lastAudioChunkAt = at
            lastModelAudioAt = at
            modelActed(at)
            if turnFirstAudioAt == nil {
                turnFirstAudioAt = at
                if turnAnswering == "user", let heard = turnHeardAt, at - heard < 60 { heardReplyTimes.append(at - heard) }
            }
            turnAudioSeconds += Double(pcm.count / 2) / max(1, sampleRate)
            if !awaitingFirstAudio, speechEndAtTurnStart == nil, !audio.isPlaying {
                // The first audio of a reply: timed from the end of the
                // user's speech.
                speechEndAtTurnStart = activity.lastVoicedAt
                awaitingFirstAudio = true
            }
            modelTurnActive = true
            awaitingReplySince = nil
            awaitingAnswerSince = nil
            toolCallsSpokenFor.formUnion(toolsInFlight)
            audio.enqueue(Self.samples(pcm), sampleRate: sampleRate)
            if phase == .listening { phase = .speaking }
        case .inputTranscription(let text):
            lastUserSpeechAt = now
            if openUserLine == nil, awaitingReplySince == nil { awaitingReplySince = now }
            // Words still coming in while the model answers are that turn's.
            if !modelTurnActive, replyOwedSince == nil {
                replyOwedSince = now
                silentTurnSinceUser = false
            }
            appendTranscript(.user, text)
        case .outputTranscription(let text):
            guard !suppressingModelTurn else { return }
            modelActed(now)
            modelTurnActive = true
            awaitingReplySince = nil
            awaitingAnswerSince = nil
            appendTranscript(.assistant, text)
            if let line = openAssistantLine { caption = String(transcript[line].text.suffix(160)) }
        case .interrupted:
            audio.stopPlayback()
            lastPlaybackEndedAt = now
            suppressingModelTurn = false
            modelTurnEnded("interrupted")
            turnEndedByInterruption = true
        case .turnComplete:
            // A turn the orb stopped isn't a silent one.
            let wasSuppressed = suppressingModelTurn
            suppressingModelTurn = false
            if turnStartedAt == nil, !turnEndedByInterruption, !wasSuppressed { silentTurnEnded() }
            turnEndedByInterruption = false
            modelTurnEnded("complete")
            endIfUserSaidGoodbye(finished: true)
        case .toolCall(let calls):
            modelActed(now)
            turnTools += calls.count
            for call in calls { toolCalled(call) }
        case .toolCallCancellation(let ids):
            // Answers still coming for these are dropped.
            withdrawnToolIDs.formUnion(toolsInFlight.intersection(ids))
            wristQueue.removeAll { ids.contains($0.call.id) }
            link.send(.directToolCancel(callID: callID, ids: ids))
        case .goAway(let timeLeft):
            goAways += 1
            if handoffStartedAt == nil { handoffStartedAt = now }
            WatchCallLog.shared.note("directGoAway", ["timeLeftS": timeLeft as Any, "screen": "\(scenePhase)"])
        }
    }

    private func modelTurnEnded(_ end: String) {
        if modelTurnActive || openAssistantLine != nil {
            turns += 1
            if scenePhase != .active { turnsWhileScreenOff += 1 }
        }
        turnRecordEnded(end)
        modelTurnActive = false
        lastModelTurnEndedAt = now
        openUserLine = nil
        openAssistantLine = nil
        speechEndAtTurnStart = nil
        // A reply cut off before it played leaves no timing behind for
        // the next one to skip.
        awaitingFirstAudio = false
        lastAudioChunkAt = nil
        activity.reset()
        flushQuietQueue()
    }

    /// The model spoke or called a tool: whatever it owed, it's working.
    private func modelActed(_ at: TimeInterval) {
        lastModelEventAt = at
        turnEndedByInterruption = false
        if turnStartedAt == nil {
            turnStartedAt = at
            turnHeardAt = lastUserSpeechAt
            turnVoicedAt = activity.lastVoicedAt
            if stallPromptedAt != nil {
                turnAnswering = "stallPrompt"
            } else if let sent = awaitingAnswerSince, at - sent < Self.replyWait {
                turnAnswering = "update"
            } else {
                turnAnswering = replyOwedSince != nil ? "user" : "own"
            }
        }
        replyOwedSince = nil
        silentTurnSinceUser = false
        if let prompted = stallPromptedAt { stallPromptAnswered(after: at - prompted, silent: false) }
    }

    /// A turn ended with nothing from the model: it chose silence, and the
    /// session works.
    private func silentTurnEnded() {
        let at = now
        silentTurns += 1
        lastModelEventAt = at
        let owed = replyOwedSince != nil
        // A finished turn proves the session is alive, and a deliberate
        // silence owes no reply: no stall prompt follows it.
        if owed { silentTurnSinceUser = true }
        replyOwedSince = nil
        if silentTurns <= 20 {
            WatchCallLog.shared.note("directSilentTurn", [
                "sinceHeardMs": lastUserSpeechAt.map { Int((at - $0) * 1000) } as Any,
                "owed": owed,
                "prompted": stallPromptedAt != nil,
                "screen": "\(scenePhase)",
            ])
        }
        if let prompted = stallPromptedAt { stallPromptAnswered(after: at - prompted, silent: true) }
    }

    /// Gemini's side of each turn (round 7's slow replies): from the user's
    /// last transcribed words and from the end of their voice on the Watch
    /// to the reply's first audio, what the turn answered and how it ended.
    /// Never what was said.
    private func turnRecordEnded(_ end: String) {
        defer {
            turnStartedAt = nil
            turnFirstAudioAt = nil
            turnHeardAt = nil
            turnVoicedAt = nil
            turnAnswering = nil
            turnAudioSeconds = 0
            turnTools = 0
            turnMaxGap = 0
        }
        guard let started = turnStartedAt else { return }
        modelTurnNotes += 1
        guard modelTurnNotes <= 200 else { return }
        func ms(_ from: TimeInterval?, _ to: TimeInterval?) -> Int? {
            guard let from, let to, to >= from else { return nil }
            return Int((to - from) * 1000)
        }
        let answeringUser = turnAnswering == "user"
        WatchCallLog.shared.note("directModelTurn", [
            "end": end,
            "answering": turnAnswering as Any,
            "heardToAudioMs": (answeringUser ? ms(turnHeardAt, turnFirstAudioAt) : nil) as Any,
            "voiceToAudioMs": (answeringUser ? ms(turnVoicedAt, turnFirstAudioAt) : nil) as Any,
            "firstOutputToAudioMs": ms(started, turnFirstAudioAt) as Any,
            "audioMs": Int(turnAudioSeconds * 1000),
            "maxGapMs": Int(turnMaxGap * 1000),
            "tools": turnTools,
            "outChars": openAssistantLine.flatMap { transcript.indices.contains($0) ? transcript[$0].text.count : nil } as Any,
            "screen": "\(scenePhase)",
        ])
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
            exchangeUserLine = openUserLine
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
            WatchCallLog.shared.note("directTool", ["name": call.name, "local": true])
            requestEnd()
            return
        }
        // Only the running calls' times are kept.
        toolCalledAt = toolCalledAt.filter { toolsInFlight.contains($0.key) }
        toolCallsSpokenFor.formIntersection(toolsInFlight)
        toolCalledAt[call.id] = now
        if modelTurnActive { toolCallsSpokenFor.insert(call.id) }
        let generation = liveGeneration
        // Sampled as the call arrives: the link can drop later for other
        // reasons, with the wrist still up.
        let wristDown = scenePhase != .active
        let wire = WatchVoiceWire.DirectToolCall(id: call.id, name: call.name, arguments: call.arguments)
        if call.name == WatchJobAnswer.jobNews {
            // The Watch app's own call, never the model's.
            answer(.toolResponse(id: call.id, name: call.name, result: ["error": "unknown function"], scheduling: GeminiLiveProtocol.Scheduling.whenIdle.rawValue, fallback: nil), generation: generation)
            return
        }
        if call.name == WatchJobAnswer.answerApproval {
            answerApprovalByVoice(call, generation: generation)
            return
        }
        // Jobs go to Hermes through the relay wrist up or down: their news
        // and approvals come that way too.
        // A correction goes to the job where it runs: the grant's jobs
        // live on the host (#455). interrupt_job stays out of
        // WatchJobAnswer.tools, the tools a grant asks for by name.
        if WatchJobAnswer.tools.contains(call.name) || call.name == WatchJobAnswer.interruptJob, let relay = jobRelay(for: call) {
            runJobThroughRelay(wire, relay: relay, generation: generation, wristDown: wristDown)
            return
        }
        if call.name == WatchJobAnswer.interruptJob, let relay = toolRelay?.hasJobs == true ? toolRelay : jobRelays.last(where: { $0.hasJobs }), relay.hasJobs {
            // The jobs run on the host, which can't take the words just
            // now: the iPhone doesn't know them.
            let reason = !relay.tools.contains(WatchJobAnswer.interruptJob) ? WatchJobAnswer.followUpsNeedNewerPlugin
                : relay.isGone ? WatchBridgeDelegation.grantRanOut
                : "this call's access to Hermes is renewing or has run out. Try again in a moment."
            answer(.toolResponse(id: call.id, name: call.name, result: WatchJobAnswer.followUpResult(.failed(reason)), scheduling: GeminiLiveProtocol.Scheduling.whenIdle.rawValue, fallback: nil), generation: generation)
            return
        }
        if let relay = toolRelay, relay.canRun(call.name), WatchToolAnswer.tools.contains(call.name), wristDown || !link.isReachable {
            runThroughRelay(wire, relay: relay, generation: generation, wristDown: wristDown, phoneTried: false)
            return
        }
        sendToPhone(wire, generation: generation, wristDown: wristDown, relayTried: false)
    }

    /// The call through the iPhone's bridge; if the iPhone doesn't answer,
    /// through the relay when it hasn't been tried yet.
    private func sendToPhone(_ wire: WatchVoiceWire.DirectToolCall, generation: Int?, wristDown: Bool, relayTried: Bool) {
        let id = callID
        let sentAt = now
        toolsInFlight.insert(wire.id)
        link.send(.directTool(callID: id, call: wire), reply: { [weak self] answer in
            guard let self, self.callID == id, self.isActive else { return }
            self.toolsInFlight.remove(wire.id)
            let withdrawn = self.withdrawnToolIDs.remove(wire.id) != nil
            guard case .directToolResult(_, let result)? = answer else {
                self.phoneFailed(wire, generation: generation, error: "unreadable answer", withdrawn: withdrawn, wristDown: wristDown, relayTried: relayTried)
                return
            }
            self.toolsAnsweredLive += 1
            WatchCallLog.shared.note("directTool", [
                "name": wire.name,
                "live": true,
                "ms": Int((self.now - sentAt) * 1000),
                "outgoing": result.outgoing.count,
                "runningJobs": result.runningJobs,
                "withdrawn": withdrawn,
                "screen": "\(self.scenePhase)",
            ])
            self.apply(result, answering: wire.id, generation: generation, withdrawn: withdrawn)
        }, failure: { [weak self] error in
            guard let self, self.callID == id, self.isActive else { return }
            self.toolsInFlight.remove(wire.id)
            let withdrawn = self.withdrawnToolIDs.remove(wire.id) != nil
            self.phoneFailed(wire, generation: generation, error: error.localizedDescription, withdrawn: withdrawn, wristDown: wristDown, relayTried: relayTried)
        })
    }

    private func phoneFailed(_ wire: WatchVoiceWire.DirectToolCall, generation: Int?, error: String, withdrawn: Bool, wristDown: Bool, relayTried: Bool) {
        if !withdrawn, !relayTried, WatchToolAnswer.tools.contains(wire.name), let relay = toolRelay, relay.canRun(wire.name) {
            WatchCallLog.shared.note("directTool", ["name": wire.name, "live": false, "error": error, "next": "relay", "screen": "\(scenePhase)"])
            runThroughRelay(wire, relay: relay, generation: generation, wristDown: wristDown, phoneTried: true)
            return
        }
        toolUnreachable(wire, generation: generation, error: error, withdrawn: withdrawn, wristDown: wristDown)
    }

    /// A lookup through the push relay, answered as the iPhone's bridge
    /// would answer it. Whatever doesn't get Hermes' answer this way goes
    /// the iPhone's way, as without a grant, unless that was tried first.
    /// The log carries the tool, the time and how it went: never the query
    /// or the answer.
    private func runThroughRelay(_ wire: WatchVoiceWire.DirectToolCall, relay: WatchToolRelayClient, generation: Int?, wristDown: Bool, phoneTried: Bool) {
        guard let query = WatchToolAnswer.query(wire.arguments) else {
            // The bridge's answer, no lookup needed.
            answer(WatchToolAnswer.outgoing(id: wire.id, name: wire.name, result: WatchToolAnswer.missingQuery(name: wire.name)), generation: generation)
            return
        }
        let id = callID
        let sentAt = now
        toolsInFlight.insert(wire.id)
        Task { [weak self] in
            let outcome = await relay.run(name: wire.name, query: query)
            guard let self else { return Self.relayToolAbandoned(wire, outcome: outcome, callEnded: true) }
            guard self.callID == id, self.isActive else { return Self.relayToolAbandoned(wire, outcome: outcome, callEnded: !self.isActive) }
            self.toolsInFlight.remove(wire.id)
            let withdrawn = self.withdrawnToolIDs.remove(wire.id) != nil
            let elapsed = self.now - sentAt
            var fields: [String: Any] = [
                "name": wire.name,
                "ms": Int(elapsed * 1000),
                "withdrawn": withdrawn,
                "screen": "\(self.scenePhase)",
                "reachable": self.link.isReachable,
                "grantCalls": relay.callsSent,
            ]
            switch outcome {
            case .answered(let body):
                let result = WatchToolAnswer.result(name: wire.name, body: body)
                fields["outcome"] = "answered"
                if result["error"] != nil {
                    self.relayErrorAnswers += 1
                    fields["resultError"] = true
                } else {
                    self.toolsViaRelay += 1
                    self.relayTimes.append(elapsed)
                }
                WatchCallLog.shared.note("directToolRelay", fields)
                guard !withdrawn else { return }
                self.answer(WatchToolAnswer.outgoing(id: wire.id, name: wire.name, result: result), generation: generation)
            case .timedOut:
                // Hermes has the call: answered as the iPhone's broker
                // answers one that outlasts its wait.
                self.relayTimeouts += 1
                fields["outcome"] = "timedOut"
                WatchCallLog.shared.note("directToolRelay", fields)
                guard !withdrawn else { return }
                self.answer(WatchToolAnswer.outgoing(id: wire.id, name: wire.name, result: WatchToolAnswer.tookTooLong), generation: generation)
            case .unavailable(let reason, let grantGone, let sent):
                self.relayFallbacks += 1
                if sent { self.relayFailures += 1 }
                if grantGone, self.toolRelay === relay {
                    self.toolRelay = nil
                    self.closeIfUnused(relay)
                }
                fields["outcome"] = "fallback"
                fields["reason"] = reason
                fields["grantGone"] = grantGone
                fields["sent"] = sent
                WatchCallLog.shared.note("directToolRelay", fields)
                guard !withdrawn else { return }
                if phoneTried {
                    self.toolUnreachable(wire, generation: generation, error: "relay: \(reason)", withdrawn: false, wristDown: wristDown)
                } else {
                    self.sendToPhone(wire, generation: generation, wristDown: wristDown, relayTried: true)
                }
            }
        }
    }

    /// The iPhone didn't take the call. With the wrist down (the link is
    /// down whenever the Watch app isn't active), a job is queued and
    /// anything else waits for the wrist; either way Hermes asks for it.
    /// Otherwise the call is answered with why it can't be done. Function
    /// results are written for the model, not shown.
    private func toolUnreachable(_ call: WatchVoiceWire.DirectToolCall, generation: Int?, error: String, withdrawn: Bool, wristDown: Bool) {
        toolsUnreachable += 1
        var result: [String: String]
        var queued = false
        var waiting = false
        var duplicate = false
        if call.name == "start_job", wristDown, !withdrawn {
            // Sent as the wrist comes up, so the model hears that the job
            // started (a queued job's start is never heard) and doesn't
            // start it again meanwhile.
            waiting = true
            toolsWaitedForWrist += 1
            duplicate = wristQueue.contains { $0.call.name == call.name && $0.call.arguments == call.arguments }
            if !duplicate { wristQueue.append((call, now, Date())) }
            result = ["status": "waiting_for_wrist", "message": Self.wristJobMessage]
        } else if call.name == "start_job", !withdrawn {
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
        } else if wristDown, !withdrawn {
            waiting = true
            toolsWaitedForWrist += 1
            // The same lookup asked again runs once.
            duplicate = wristQueue.contains { $0.call.name == call.name && $0.call.arguments == call.arguments }
            if !duplicate { wristQueue.append((call, now, Date())) }
            result = ["status": "waiting_for_wrist", "message": Self.wristWaitMessage]
        } else {
            result = ["error": "Conduit on the user's iPhone can't be reached right now, so this isn't available. Tell the user in a few words."]
        }
        WatchCallLog.shared.note("directTool", [
            "name": call.name,
            "live": false,
            "queued": queued,
            "waitingForWrist": waiting,
            "duplicate": duplicate,
            "error": error,
            "withdrawn": withdrawn,
            "screen": "\(scenePhase)",
            "wristDownAtCall": wristDown,
            "reachable": link.isReachable,
        ])
        guard !withdrawn else { return }
        let scheduling = Self.whenIdleTools.contains(call.name) ? GeminiLiveProtocol.Scheduling.whenIdle.rawValue : nil
        answer(.toolResponse(id: call.id, name: call.name, result: result, scheduling: scheduling, fallback: nil), generation: generation)
    }

    // MARK: Jobs through the relay

    /// The grant to run a job tool through: the call's own, when it
    /// carries jobs. A job on another profile starts from the iPhone
    /// unless the host runs jobs on the user's other profiles.
    private func jobRelay(for call: GeminiLiveProtocol.FunctionCall) -> WatchToolRelayClient? {
        // A correction can still reach its job through another grant this
        // call follows while the current one renews: it answers until it closes.
        let candidate = call.name == WatchJobAnswer.interruptJob
            && !(toolRelay.map { $0.hasJobs && $0.canRun(call.name) } ?? false)
            ? jobRelays.last(where: { $0.hasJobs && $0.canRun(call.name) })
            : toolRelay
        guard let relay = candidate, relay.hasJobs, relay.canRun(call.name) else { return nil }
        if call.name == WatchJobAnswer.startJob,
           // The task as runJobThroughRelay routes it: without "Quick:".
           let route = relay.jobRoute(instructions: WatchBridgeDelegation.removingQuickMarker(call.arguments["instructions"] ?? ""), spokenProfile: call.arguments["profile"]) {
            // A profile the host doesn't run this call's jobs on, or a name
            // only the iPhone may know: the iPhone starts or answers it.
            if case .relay = route { return relay }
            return nil
        }
        let profile = call.arguments["profile"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return profile.isEmpty ? relay : nil
    }

    /// A job call through the push relay, answered as the iPhone's bridge
    /// answers it. A start_job that may have reached Hermes never goes the
    /// iPhone's way as well: that could start it twice. The log carries
    /// the tool, the time and how it went: never the task or the answer.
    private func runJobThroughRelay(_ wire: WatchVoiceWire.DirectToolCall, relay: WatchToolRelayClient, generation: Int?, wristDown: Bool) {
        let isStart = wire.name == WatchJobAnswer.startJob
        let whenIdle = GeminiLiveProtocol.Scheduling.whenIdle.rawValue
        let isFollowUp = wire.name == WatchJobAnswer.interruptJob
        guard var arguments = WatchJobAnswer.arguments(name: wire.name, wire.arguments) else {
            answer(.toolResponse(id: wire.id, name: wire.name, result: WatchJobAnswer.missingArguments(name: wire.name, wire.arguments), scheduling: whenIdle, fallback: nil), generation: generation)
            return
        }
        if isStart, let task = arguments["instructions"] as? String,
           let route = relay.jobRoute(instructions: task, spokenProfile: wire.arguments["profile"]) {
            // "for Fam, …" runs on Fam, as the iPhone's jobs do.
            switch route {
            case .relay(let instructions, let profile):
                arguments["instructions"] = instructions
                if let profile { arguments["profile"] = profile }
            case .viaPhone(let name), .unknown(let name):
                // jobRelay sends these to the iPhone; this is a backstop.
                let unknown = route == .unknown(name)
                WatchCallLog.shared.note("directJobRelay", ["name": wire.name, "outcome": unknown ? "unknownProfile" : "profileViaPhone"])
                answer(.toolResponse(id: wire.id, name: wire.name, result: [
                    "status": "not_started",
                    "message": unknown ? VoiceJobProfiles.unknownProfileReply(name) : VoiceJobProfiles.viaPhoneReply(name),
                ], scheduling: whenIdle, fallback: nil), generation: generation)
                return
            }
        }
        if isStart, relayJobsStarted >= relay.maxJobs {
            WatchCallLog.shared.note("directJobRelay", ["name": wire.name, "outcome": "capped", "maxJobs": relay.maxJobs])
            answer(.toolResponse(id: wire.id, name: wire.name, result: [
                "status": "not_started",
                "message": "This call has started \(relay.maxJobs) jobs, the most the user allows per call. Tell them; they can raise it in Conduit's Watch settings or start more from their iPhone.",
            ], scheduling: whenIdle, fallback: nil), generation: generation)
            return
        }
        let id = callID
        let sentAt = now
        toolsInFlight.insert(wire.id)
        jobCallsViaRelay += 1
        Task { [weak self] in
            let outcome = await relay.run(name: wire.name, arguments: arguments)
            guard let self else { return Self.relayToolAbandoned(wire, outcome: outcome, callEnded: true) }
            guard self.callID == id, self.isActive else { return Self.relayToolAbandoned(wire, outcome: outcome, callEnded: !self.isActive) }
            self.toolsInFlight.remove(wire.id)
            let withdrawn = self.withdrawnToolIDs.remove(wire.id) != nil
            var fields: [String: Any] = [
                "name": wire.name,
                "ms": Int((self.now - sentAt) * 1000),
                "withdrawn": withdrawn,
                "screen": "\(self.scenePhase)",
                "reachable": self.link.isReachable,
                "grantCalls": relay.callsSent,
            ]
            let result: [String: String]
            switch outcome {
            case .answered(let body):
                result = isFollowUp
                    ? WatchJobAnswer.followUpResult(WatchJobAnswer.FollowUp(body: body))
                    : WatchJobAnswer.result(body: body)
                fields["outcome"] = "answered"
                fields["status"] = isFollowUp
                    ? (body["outcome"] as? String ?? "error")
                    : result["status"] ?? (result["error"] == nil ? "" : "error")
                // "accepted": Hermes is still taking it, and its outcome
                // comes as news.
                if isStart, result["status"] == "started" || result["status"] == "accepted" {
                    self.relayJobsStarted += 1
                    if let jobID = result["job_id"] { self.jobLog.started(jobID: jobID, title: result["title"] ?? "") }
                    self.followJobs(on: self.jobsHolder(relay))
                } else if wire.name == WatchJobAnswer.cancelJob {
                    // The running count changed: ask for it now.
                    self.nextNewsAt = self.now
                }
            case .timedOut:
                // Hermes has the call: a start may be running there.
                self.relayTimeouts += 1
                fields["outcome"] = "timedOut"
                if isStart {
                    self.relayJobsStarted += 1
                    self.followJobs(on: self.jobsHolder(relay))
                    result = WatchJobAnswer.accepted
                } else if isFollowUp {
                    result = WatchJobAnswer.followUpResult(.failed("Hermes took too long to answer"))
                } else {
                    result = WatchToolAnswer.tookTooLong
                }
            case .unavailable(let reason, let grantGone, let sent):
                self.relayFallbacks += 1
                if sent { self.relayFailures += 1 }
                if grantGone, self.toolRelay === relay {
                    self.toolRelay = nil
                    self.closeIfUnused(relay)
                }
                fields["outcome"] = "fallback"
                fields["reason"] = reason
                fields["grantGone"] = grantGone
                fields["sent"] = sent
                WatchCallLog.shared.note("directJobRelay", fields)
                if isStart, sent {
                    // It may have reached Hermes.
                    self.relayJobsStarted += 1
                    if !grantGone || self.mayBeCarried(relay) { self.followJobs(on: self.jobsHolder(relay)) }
                    guard !withdrawn else { return }
                    self.answer(.toolResponse(id: wire.id, name: wire.name, result: [
                        "status": "unknown",
                        "message": "Hermes didn't confirm the job. Tell the user it may or may not have started; they can ask you to list their jobs.",
                    ], scheduling: whenIdle, fallback: nil), generation: generation)
                    return
                }
                guard !withdrawn else { return }
                if isFollowUp {
                    // The job runs on the host: the iPhone doesn't know it.
                    let message = WatchBridgeDelegation.grantRanOut(reason: reason, grantGone: grantGone, sent: sent)
                        ? WatchBridgeDelegation.grantRanOut
                        : sent ? "Hermes didn't confirm it got the words." : "Hermes couldn't be reached from the Watch."
                    self.answer(.toolResponse(id: wire.id, name: wire.name, result: WatchJobAnswer.followUpResult(.failed(message)), scheduling: whenIdle, fallback: nil), generation: generation)
                    return
                }
                // Not sent, or a list or cancel: the iPhone's way, as
                // without jobs in the grant.
                self.sendToPhone(wire, generation: generation, wristDown: wristDown, relayTried: true)
                return
            }
            WatchCallLog.shared.note("directJobRelay", fields)
            guard !withdrawn else { return }
            self.answer(.toolResponse(
                id: wire.id,
                name: wire.name,
                result: result,
                scheduling: WatchJobAnswer.scheduling(name: wire.name, result: result),
                fallback: WatchJobAnswer.fallbackText(name: wire.name, result: result)
            ), generation: generation)
        }
    }

    /// Asks this grant for job news from now on.
    private func followJobs(on relay: WatchToolRelayClient) {
        if !jobRelays.contains(where: { $0 === relay }) { jobRelays.append(relay) }
        // Renewals carry the grant with running jobs; a kept old one with
        // none left hands that over.
        if relay.hasJobs, relay !== jobsGrant, !jobRelays.contains(where: { $0 === jobsGrant }) { jobsGrant = relay }
        nextNewsAt = now
    }

    /// Done with a grant's jobs: its news, its approvals, and, for a
    /// renewed grant's old one, the grant itself.
    private func stopFollowing(_ relay: WatchToolRelayClient) {
        jobRelays.removeAll { $0 === relay }
        if relay === jobsGrant, relay !== toolRelay { jobsGrant = toolRelay?.hasJobs == true ? toolRelay : nil }
        relayRunning[relay.grantID] = nil
        relayJobsRunning = relayRunning.values.reduce(0, +)
        approvals.removeAll { $0.grantID == relay.grantID }
        pendingApproval = approvals.first
        closeIfUnused(relay)
    }

    /// Ends a grant on the relay once nothing needs it: not the call's
    /// grant, not followed for job news, and not the one whose jobs the
    /// next renewal moves. Closing a grant leaves its jobs running in
    /// Hermes, but Hermes then stops following them for the Watch, so a
    /// renewal could no longer move them.
    private func closeIfUnused(_ relay: WatchToolRelayClient) {
        guard relay !== toolRelay, relay !== jobsGrant, !jobRelays.contains(where: { $0 === relay }) else { return }
        relay.close()
    }

    /// Where `relay`'s jobs are now: the grant a renewal moved them to.
    private func jobsHolder(_ relay: WatchToolRelayClient) -> WatchToolRelayClient {
        var holder = relay
        var hops = 0
        while let next = jobsMovedTo[holder.grantID], hops < Self.maxGrantRequests {
            holder = next
            hops += 1
        }
        return holder
    }

    /// A gone grant (a spent budget) whose jobs a renewal can still move:
    /// followed but not asked until a renewal answers.
    private func mayBeCarried(_ relay: WatchToolRelayClient) -> Bool {
        relay === jobsGrant && endRequestedAt == nil && grantRequests < Self.maxGrantRequests
            && !relay.expires(within: WatchToolRelayClient.expiryMargin)
    }

    /// Hermes moved `old`'s jobs to the renewal `new`: their news, list,
    /// cancel and approvals go through it from now on.
    private func moveJobs(from old: WatchToolRelayClient, to new: WatchToolRelayClient) {
        jobsMovedTo[old.grantID] = new
        jobsCarried += 1
        if let index = jobRelays.firstIndex(where: { $0 === old }) {
            jobRelays[index] = new
            nextNewsAt = now
        } else if relayJobsStarted > 0 {
            // Dropped while it waited (its last seconds): followed again
            // on the new grant, which stops at once if nothing runs.
            followJobs(on: new)
        }
        if let running = relayRunning.removeValue(forKey: old.grantID) { relayRunning[new.grantID] = running }
        for index in approvals.indices where approvals[index].grantID == old.grantID {
            approvals[index].grantID = new.grantID
        }
        pendingApproval = approvals.first
    }

    /// While jobs started through the relay may run, asks Hermes for their
    /// news, wrist up or down: one ask at a time, each grant in turn.
    private func fetchJobNewsIfDue() {
        guard !newsInFlight, endRequestedAt == nil, now >= nextNewsAt, !jobRelays.isEmpty else { return }
        // A grant that ended or is about to can't be asked any more: what
        // its jobs do next reaches the user as Conduit notifications.
        // One a renewal may still move waits for it.
        for relay in jobRelays where (relay.isGone || relay.expires(within: WatchToolRelayClient.expiryMargin)) && !mayBeCarried(relay) {
            WatchCallLog.shared.note("directJobNewsStopped", ["gone": relay.isGone, "running": relayRunning[relay.grantID] as Any])
            stopFollowing(relay)
        }
        guard let relay = jobRelays.first(where: { !$0.isGone }) else { return }
        newsInFlight = true
        jobNewsAsks += 1
        let id = callID
        let sentAt = now
        Task { [weak self] in
            let outcome = await relay.run(name: WatchJobAnswer.jobNews, arguments: ["wait_s": Self.jobNewsWait])
            guard let self, self.callID == id, self.isActive else { return }
            self.newsInFlight = false
            // The next ask goes to the next grant.
            if let index = self.jobRelays.firstIndex(where: { $0 === relay }) {
                self.jobRelays.append(self.jobRelays.remove(at: index))
            }
            switch outcome {
            case .answered(let body):
                // Asked before a renewal moved the jobs: news of them now.
                let holder = self.jobsHolder(relay)
                guard let news = WatchJobAnswer.news(from: body, grantID: holder.grantID) else {
                    self.jobNewsFailed += 1
                    WatchCallLog.shared.note("directJobNewsFailed", ["reason": "unreadable", "ms": Int((self.now - sentAt) * 1000)])
                    self.nextNewsAt = self.now + Self.jobNewsPause
                    return
                }
                self.jobNews(news, from: holder, ms: Int((self.now - sentAt) * 1000))
                self.nextNewsAt = self.now + (news.items.isEmpty && !news.more ? Self.jobNewsPause : Self.jobNewsRetry)
            case .timedOut:
                self.nextNewsAt = self.now + Self.jobNewsRetry
            case .unavailable(let reason, let grantGone, _):
                self.jobNewsFailed += 1
                WatchCallLog.shared.note("directJobNewsFailed", ["reason": reason, "grantGone": grantGone, "screen": "\(self.scenePhase)"])
                if grantGone, !self.mayBeCarried(relay) { self.stopFollowing(relay) }
                self.nextNewsAt = self.now + Self.jobNewsPause
            }
        }
    }

    /// A grant's job news: results and failures for the model at the next
    /// quiet moment, approval requests on screen with a tap on the wrist.
    private func jobNews(_ news: WatchJobAnswer.News, from relay: WatchToolRelayClient, ms: Int) {
        relayRunning[relay.grantID] = news.running
        relayJobsRunning = relayRunning.values.reduce(0, +)
        jobNewsItems += news.items.count
        // Requests no longer open (answered elsewhere, timed out) leave the
        // screen.
        let open = Set(news.openApprovals.map { "\($0.jobID)\n\($0.requestID)" })
        approvals.removeAll { $0.grantID == relay.grantID && !open.contains("\($0.jobID)\n\($0.requestID)") }
        var shown = 0
        for item in news.items {
            jobLog.heard(jobID: item.jobID, title: item.title, sessionID: item.sessionID)
            // A new request replaces the job's last one; news without one
            // leaves the card to the open-requests list above.
            if let approval = item.approval {
                approvals.removeAll { $0.grantID == relay.grantID && $0.jobID == item.jobID }
                approvals.append(approval)
                approvalsShown += 1
                shown += 1
            }
            if let text = WatchJobAnswer.notice(for: item, voiceApprovals: relay.voiceApprovals) {
                quietQueue.append(.textWhenIdle(text))
            }
        }
        pendingApproval = approvals.first
        if shown > 0 { WKInterfaceDevice.current().play(.notification) }
        if !news.items.isEmpty {
            WatchCallLog.shared.note("directJobNews", [
                "ms": ms,
                "statuses": news.items.map(\.status),
                "resultChars": news.items.map { $0.result?.count ?? 0 },
                "running": news.running,
                "more": news.more,
                "approvalsOnScreen": approvals.count,
                "screen": "\(scenePhase)",
            ])
        }
        if news.running == 0, !news.more, !approvals.contains(where: { $0.grantID == relay.grantID }) {
            stopFollowing(relay)
        }
        flushQuietQueue()
    }

    /// The Watch's Approve or Deny for the request on screen.
    func answerApproval(_ approval: WatchJobAnswer.Approval, approve: Bool) {
        // Only the card the user read; a late tap never answers the next one.
        guard pendingApproval == approval else { return }
        let choice = approve ? WatchJobAnswer.approve : WatchJobAnswer.deny
        resolveApproval(approval, choice: choice, byVoice: false) { [weak self] result in
            guard let self, result["error"] == nil, result["status"] != "failed" else { return }
            // The model hears it without replying, so it doesn't ask again.
            let what = approve ? "approved" : "denied"
            self.quietQueue.append(.contextWhenIdle("[On their Watch, the user \(what) the command background job \"\(approval.title)\" asked to run.]"))
            self.flushQuietQueue()
        }
    }

    /// The model's answer to an approval request, when the user allowed
    /// voice approvals for this call; only ever once or deny.
    private func answerApprovalByVoice(_ call: GeminiLiveProtocol.FunctionCall, generation: Int?) {
        let jobID = call.arguments["job_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let choice = call.arguments["choice"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let candidates = approvals.filter { jobID.isEmpty || $0.jobID == jobID }
        var refusal: String?
        if candidates.count != 1 {
            refusal = "No job is waiting for that approval."
        } else if jobRelays.first(where: { $0.grantID == candidates[0].grantID })?.voiceApprovals != true {
            refusal = "The user answers approvals on their Watch screen. Ask them to tap Approve or Deny."
        } else if choice != WatchJobAnswer.approve, choice != WatchJobAnswer.deny {
            refusal = "choice must be once or deny"
        }
        if let refusal {
            WatchCallLog.shared.note("directApproval", ["byVoice": true, "refused": refusal])
            answer(.toolResponse(id: call.id, name: call.name, result: ["error": refusal], scheduling: nil, fallback: nil), generation: generation)
            return
        }
        toolsInFlight.insert(call.id)
        resolveApproval(candidates[0], choice: choice, byVoice: true) { [weak self] result in
            guard let self else { return }
            self.toolsInFlight.remove(call.id)
            guard self.withdrawnToolIDs.remove(call.id) == nil else { return }
            self.answer(.toolResponse(id: call.id, name: call.name, result: result, scheduling: nil, fallback: nil), generation: generation)
        }
    }

    /// Sends an approval's answer to Hermes. The card leaves the screen at
    /// once and comes back if Hermes didn't take the answer.
    private func resolveApproval(_ approval: WatchJobAnswer.Approval, choice: String, byVoice: Bool, done: @escaping ([String: String]) -> Void) {
        approvals.removeAll { $0 == approval }
        pendingApproval = approvals.first
        guard let relay = jobRelays.first(where: { $0.grantID == approval.grantID }) else {
            done(["status": "not_pending", "message": "That job isn't waiting for an approval any more."])
            return
        }
        let id = callID
        let sentAt = now
        Task { [weak self] in
            let outcome = await relay.run(name: WatchJobAnswer.answerApproval, arguments: [
                "job_id": approval.jobID,
                "request_id": approval.requestID,
                "choice": choice,
            ])
            guard let self else { return Self.approvalAbandoned(choice: choice, byVoice: byVoice, outcome: outcome, callEnded: true) }
            guard self.callID == id, self.isActive else {
                return Self.approvalAbandoned(choice: choice, byVoice: byVoice, outcome: outcome, callEnded: !self.isActive)
            }
            var fields: [String: Any] = ["choice": choice, "byVoice": byVoice, "ms": Int((self.now - sentAt) * 1000), "screen": "\(self.scenePhase)"]
            let result: [String: String]
            var taken = false
            // Hermes answered, and turned it down (already handled, or
            // expired): asking again can't change that.
            var refused = false
            switch outcome {
            case .answered(let body):
                result = WatchJobAnswer.result(body: body)
                fields["status"] = result["status"] ?? (result["error"] == nil ? "" : "error")
                taken = result["error"] == nil && result["status"] != "failed"
                refused = !taken
            case .timedOut:
                fields["status"] = "timedOut"
                result = WatchToolAnswer.tookTooLong
            case .unavailable(let reason, let grantGone, _):
                fields["status"] = "unavailable"
                fields["reason"] = reason
                result = ["error": "The answer didn't reach Hermes. Tell the user to try again on their Watch screen or in Conduit."]
                if grantGone, !self.mayBeCarried(relay) { self.stopFollowing(relay) }
            }
            if taken {
                if byVoice { self.approvalsByVoice += 1 } else { self.approvalsTapped += 1 }
            } else {
                self.approvalFailures += 1
                // Back on screen, through the grant its job is on now.
                let holder = self.jobsHolder(relay)
                var again = approval
                again.grantID = holder.grantID
                if !refused, self.jobRelays.contains(where: { $0 === holder }), !self.approvals.contains(again) {
                    self.approvals.insert(again, at: 0)
                    self.pendingApproval = self.approvals.first
                }
            }
            WatchCallLog.shared.note("directApproval", fields)
            // The job moves on: its news is worth asking for now.
            self.nextNewsAt = self.now
            done(result)
        }
    }

    /// Written for the model, not shown.
    static let wristJobMessage = "The user's iPhone can only be reached while their wrist is raised. The job starts on Hermes as soon as they raise it, and you'll get a message once it has started. Ask them, in a few words, to raise their wrist. Don't call start_job again for this request."
    static let wristWaitMessage = "The user's iPhone can only be reached while their wrist is raised. Ask them, in a few words, to raise their wrist; this runs as soon as they do, and its result follows as a message. Don't call it again."

    /// Runs the tools that waited for the wrist, now that the iPhone can be
    /// reached. Their calls were answered already, so each result goes to
    /// the model as a text update at the next quiet moment.
    private func runWristQueueIfReachable() {
        // Ending: nothing new goes to the model.
        guard !wristQueue.isEmpty, link.isReachable, endRequestedAt == nil else { return }
        let waiting = wristQueue
        wristQueue = []
        let id = callID
        for (call, parkedAt, parkedDate) in waiting {
            // In flight again, so a cancellation from the model reaches it.
            toolsInFlight.insert(call.id)
            link.send(.directTool(callID: id, call: call), reply: { [weak self] answer in
                guard let self else { return Self.wristToolAbandoned(call, callEnded: true) }
                guard self.callID == id, self.isActive else { return Self.wristToolAbandoned(call, callEnded: !self.isActive) }
                self.toolsInFlight.remove(call.id)
                let withdrawn = self.withdrawnToolIDs.remove(call.id) != nil
                guard case .directToolResult(_, let result)? = answer else {
                    WatchCallLog.shared.note("directToolAfterWristFailed", ["name": call.name, "error": "unreadable answer"])
                    return
                }
                let waited = self.now - parkedAt
                self.wristWaits.append(waited)
                WatchCallLog.shared.note("directToolAfterWrist", [
                    "name": call.name,
                    "waitedMs": Int(waited * 1000),
                    "waitedWallMs": Int(Date().timeIntervalSince(parkedDate) * 1000),
                    "outgoing": result.outgoing.count,
                    "withdrawn": withdrawn,
                    "screen": "\(self.scenePhase)",
                ])
                // The call's own answer becomes a text update, unless the
                // model withdrew the call meanwhile; anything else is
                // handled as a poll's would be.
                let outgoing: [WatchVoiceWire.DirectOutgoing] = result.outgoing.compactMap { item in
                    guard case .toolResponse(let responseID, let name, let response, _, let fallback) = item, responseID == call.id else { return item }
                    return withdrawn ? nil : .textWhenIdle(fallback ?? Self.wristResultText(name: name, result: response))
                }
                self.apply(WatchVoiceWire.DirectToolResult(outgoing: outgoing, runningJobs: result.runningJobs), answering: nil, generation: nil, withdrawn: false)
            }, failure: { [weak self] error in
                guard let self else { return Self.wristToolAbandoned(call, callEnded: true) }
                guard self.callID == id, self.isActive else { return Self.wristToolAbandoned(call, callEnded: !self.isActive) }
                self.toolsInFlight.remove(call.id)
                WatchCallLog.shared.note("directToolAfterWristFailed", ["name": call.name, "error": error.localizedDescription])
                // The link went again: wait for the next raise, unless the
                // model withdrew the call meanwhile.
                guard self.withdrawnToolIDs.remove(call.id) == nil else { return }
                self.wristQueue.append((call, parkedAt, parkedDate))
            })
        }
    }

    /// A wrist-queued tool whose answer came after its call was over.
    private static func wristToolAbandoned(_ call: WatchVoiceWire.DirectToolCall, callEnded: Bool) {
        WatchCallLog.shared.note("directToolAfterWristAbandoned", ["name": call.name, "reason": callEnded ? "callEnded" : "replaced"])
    }

    /// A relay lookup whose answer came after its call was over.
    private static func relayToolAbandoned(_ call: WatchVoiceWire.DirectToolCall, outcome: WatchToolRelayClient.Outcome, callEnded: Bool) {
        var fields: [String: Any] = ["name": call.name, "outcome": outcome.logLabel, "reason": callEnded ? "callEnded" : "replaced"]
        if case .unavailable(let why, let grantGone, let sent) = outcome {
            fields["why"] = why
            fields["grantGone"] = grantGone
            fields["sent"] = sent
        }
        WatchCallLog.shared.note("directToolRelayAbandoned", fields)
    }

    /// An approval's answer that came after its call was over: Hermes may
    /// have taken it, and the log says how it went.
    private static func approvalAbandoned(choice: String, byVoice: Bool, outcome: WatchToolRelayClient.Outcome, callEnded: Bool) {
        var fields: [String: Any] = ["choice": choice, "byVoice": byVoice, "outcome": outcome.logLabel, "reason": callEnded ? "callEnded" : "replaced"]
        if case .answered(let body) = outcome {
            let result = WatchJobAnswer.result(body: body)
            fields["status"] = result["status"] ?? (result["error"] == nil ? "" : "error")
        }
        if case .unavailable(let why, let grantGone, let sent) = outcome {
            fields["why"] = why
            fields["grantGone"] = grantGone
            fields["sent"] = sent
        }
        WatchCallLog.shared.note("directApprovalAbandoned", fields)
    }

    /// A grant renewal whose answer came after its call was over. A grant
    /// it brought is closed on the relay: nothing will use it.
    private static func grantRenewalAbandoned(_ answer: WatchVoiceWire.Message?, error: String?, callEnded: Bool) {
        var fields: [String: Any] = ["reason": callEnded ? "callEnded" : "replaced"]
        if case .directGrantIssued(_, let grant)? = answer, let relay = WatchToolRelayClient(grant) {
            relay.close()
            fields["closedGrant"] = true
        }
        if let error { fields["error"] = error }
        WatchCallLog.shared.note("directGrantRenewalAbandoned", fields)
    }

    /// While the iPhone can be reached, a new tool grant for one that ends
    /// soon or ended early (a host restart, a spent budget). The old one is
    /// closed once nothing waits on it.
    private func renewGrantIfDue() {
        guard hadToolGrant, engine != .grok, endRequestedAt == nil, !grantRequestInFlight, link.isReachable,
              grantRequests < Self.maxGrantRequests,
              now - lastGrantRequestAt >= Self.grantRequestInterval else { return }
        if let relay = toolRelay, !relay.isGone, relay.callsLeft > Self.grantRenewCallHeadroom,
           !relay.expires(within: Self.grantRenewMargin) { return }
        grantRequestInFlight = true
        grantRequests += 1
        lastGrantRequestAt = now
        let id = callID
        let sentAt = now
        // Its jobs move to the new grant, if Hermes still has it open.
        let carry = jobsGrant
        link.send(.directGrant(callID: id, carryJobsFrom: carry?.grantID), reply: { [weak self] answer in
            guard let self else { return Self.grantRenewalAbandoned(answer, error: nil, callEnded: true) }
            guard self.callID == id, self.isActive else { return Self.grantRenewalAbandoned(answer, error: nil, callEnded: !self.isActive) }
            self.grantRequestInFlight = false
            var fields: [String: Any] = ["ms": Int((self.now - sentAt) * 1000), "screen": "\(self.scenePhase)", "askedCarry": carry != nil]
            switch answer {
            case .directGrantIssued(_, let grant)?:
                guard let relay = WatchToolRelayClient(grant) else {
                    fields["ok"] = false
                    fields["error"] = "unreadable grant"
                    WatchCallLog.shared.note("directGrantRenewed", fields)
                    return
                }
                let carried = relay.hasJobs && carry != nil && grant.jobsCarriedFrom == carry?.grantID
                if carried, let carry { self.moveJobs(from: carry, to: relay) }
                let previous = self.toolRelay
                self.toolRelay = relay
                // Hermes kept the old grant's jobs: later renewals name it
                // again until they're done or move.
                let keptOld = !carried && carry.map { old in self.jobRelays.contains { $0 === old } } == true
                self.jobsGrant = keptOld ? carry : (relay.hasJobs ? relay : nil)
                // An old grant whose jobs Hermes kept stays open while they
                // run, for their news; one with nothing left is ended.
                for old in [previous, carry].compactMap({ $0 }) { self.closeIfUnused(old) }
                self.grantsRenewed += 1
                fields["ok"] = true
                fields["carried"] = carried
                fields["expiresInS"] = relay.expiresAt.map { Int($0.timeIntervalSinceNow) } as Any
            case .callRefused(_, let reason)?:
                fields["ok"] = false
                fields["error"] = reason
            default:
                fields["ok"] = false
                fields["error"] = "unreadable answer"
            }
            WatchCallLog.shared.note("directGrantRenewed", fields)
        }, failure: { [weak self] error in
            guard let self else { return Self.grantRenewalAbandoned(nil, error: error.localizedDescription, callEnded: true) }
            guard self.callID == id, self.isActive else { return Self.grantRenewalAbandoned(nil, error: error.localizedDescription, callEnded: !self.isActive) }
            self.grantRequestInFlight = false
            WatchCallLog.shared.note("directGrantRenewed", ["ok": false, "error": error.localizedDescription])
        })
    }

    /// A tool's answer as a text update, for a call already answered with
    /// "raise your wrist". Not UI copy.
    static func wristResultText(name: String, result: [String: String]) -> String {
        let lines = result.keys.sorted().map { "\($0): \(result[$0] ?? "")" }.joined(separator: "\n")
        if name == "start_job" {
            return "[The job the user asked for earlier reached Hermes now that their wrist is raised. Hermes' answer:\n\(lines)\nTell them in a few words whether it started. Its result comes later as a message.]"
        }
        return "[The \(name) the user asked for earlier has run now that their wrist is raised. Its result:\n\(lines)\nTell them in a sentence or two.]"
    }

    private func apply(_ result: WatchVoiceWire.DirectToolResult, answering toolCallID: String?, generation: Int?, withdrawn: Bool) {
        runningJobs = result.runningJobs
        for item in result.outgoing {
            switch item {
            case .endConversation:
                requestEnd()
            case .toolResponse(let id, _, _, _, _):
                // The model withdrew the call while it ran: no answer.
                if withdrawn, id == toolCallID { continue }
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
        // A started job the model already said it's starting goes in
        // silently (WatchJobAnswer.scheduling(name:result:acknowledged:)).
        var item = item
        let silent = GeminiLiveProtocol.Scheduling.silent.rawValue
        if case .toolResponse(let id, let name, let result, .none, let fallback) = item,
           WatchJobAnswer.scheduling(name: name, result: result, acknowledged: toolCallsSpokenFor.contains(id)) == silent {
            startJobsTakenSilently += 1
            item = .toolResponse(id: id, name: name, result: result, scheduling: silent, fallback: fallback)
        }
        guard case .toolResponse(_, _, _, let scheduling, let fallback) = item, let message = item.clientMessage else { return }
        guard let session, session.isReady, generation == nil || liveGeneration == generation else {
            if let fallback { quietQueue.append(.textWhenIdle(fallback)) }
            return
        }
        // The model talks about it next: job news waits for that.
        if scheduling != GeminiLiveProtocol.Scheduling.silent.rawValue { awaitingAnswerSince = now }
        let id = callID
        session.send(message, onSent: nil, onFailure: { [weak self] in
            guard let self, self.callID == id, let fallback else { return }
            self.quietQueue.append(.textWhenIdle(fallback))
        })
    }

    /// Gemini heard the user and has said nothing since, with nothing else
    /// owed (round 7: the user's words transcribed, then 40 s of silence on
    /// an open socket). Prompted once for that turn, with their words.
    private func promptIfStalled() {
        guard stallPromptedAt == nil, endRequestedAt == nil, phase == .listening,
              let session, session.isReady,
              !modelTurnActive, !audio.isPlaying, toolsInFlight.isEmpty,
              WatchStall.isDue(owedSince: replyOwedSince, lastHeardAt: lastUserSpeechAt, now: now) else { return }
        // A tool's answer or an update just went out: its reply comes first.
        if let sent = awaitingAnswerSince, now - sent < Self.replyWait { return }
        let at = now
        let text = WatchStall.prompt(lastUserLine: transcript.last { $0.role == .user }?.text)
        WatchCallLog.shared.note("directStallPrompt", [
            "owedMs": replyOwedSince.map { Int((at - $0) * 1000) } as Any,
            "sinceHeardMs": lastUserSpeechAt.map { Int((at - $0) * 1000) } as Any,
            "sinceModelMs": lastModelEventAt.map { Int((at - $0) * 1000) } as Any,
            "sinceServerMs": lastServerEventAt.map { Int((at - $0) * 1000) } as Any,
            "silentTurn": silentTurnSinceUser,
            "reachable": link.isReachable,
            "screen": "\(scenePhase)",
        ])
        let owed = replyOwedSince
        replyOwedSince = nil
        stallPromptedAt = at
        stallPrompts += 1
        awaitingAnswerSince = at
        noteTextSent("stallPrompt", text)
        let id = callID
        session.send(.textTurn(text), onSent: nil, onFailure: { [weak self] in
            guard let self, self.callID == id, self.stallPromptedAt == at else { return }
            self.stallPromptedAt = nil
            // Never sent: the user's words still wait for a reply.
            if self.replyOwedSince == nil { self.replyOwedSince = owed }
            WatchCallLog.shared.note("directStallPromptFailed", ["screen": "\(self.scenePhase)"])
        })
    }

    private func stallPromptAnswered(after wait: TimeInterval, silent: Bool) {
        stallPromptedAt = nil
        if silent { stallPromptsSilent += 1 } else { stallPromptsAnswered += 1 }
        WatchCallLog.shared.note("directStallPromptAnswered", [
            "ms": Int(wait * 1000),
            "silent": silent,
            "screen": "\(scenePhase)",
        ])
    }

    /// Nothing at all came back from the model for the prompt: the session
    /// stopped working, and a fresh one carries the call on, told the
    /// conversation so far, as after a session that broke.
    private func rejoinIfStallUnanswered() {
        guard let prompted = stallPromptedAt, now - prompted >= WatchStall.answerWait else { return }
        stallPromptedAt = nil
        guard let session, session.isReady, endRequestedAt == nil else { return }
        stalls += 1
        WatchCallLog.shared.note("directStalled", [
            "sinceServerMs": lastServerEventAt.map { Int((now - $0) * 1000) } as Any,
            "sinceModelMs": lastModelEventAt.map { Int((now - $0) * 1000) } as Any,
            "rejoins": rejoins,
            "reachable": link.isReachable,
            "relayToken": canMintThroughRelay,
            "screen": "\(scenePhase)",
        ])
        session.stop()
        let reason = engine == .grok
            ? String(localized: "Grok stopped answering.")
            : String(localized: "Gemini stopped answering.")
        if rejoins < Self.maxRejoins {
            waitToRejoin(reason, cause: .froze)
        } else {
            finish(reason)
        }
    }

    /// Each text turn the model is sent, by kind and size: never its words.
    private func noteTextSent(_ kind: String, _ text: String) {
        let at = now
        WatchCallLog.shared.note("directTextSent", [
            "kind": kind,
            "chars": text.count,
            "sinceHeardMs": lastUserSpeechAt.map { Int((at - $0) * 1000) } as Any,
            "sinceModelMs": lastModelEventAt.map { Int((at - $0) * 1000) } as Any,
            "screen": "\(scenePhase)",
        ])
    }

    /// Job news and the like go out only while nobody is speaking.
    private func flushQuietQueue() {
        guard !quietQueue.isEmpty, let session, session.isReady, isQuiet else { return }
        let item = quietQueue.removeFirst()
        guard let message = item.clientMessage else { return }
        textUpdatesSent += 1
        // A text turn is answered; the next update waits for that.
        switch item {
        case .textWhenIdle(let text):
            awaitingAnswerSince = now
            noteTextSent("update", text)
        case .contextWhenIdle(let text):
            noteTextSent("context", text)
        case .toolResponse, .endConversation:
            break
        }
        let id = callID
        session.send(message, onSent: nil, onFailure: { [weak self] in
            guard let self, self.callID == id else { return }
            self.quietQueue.insert(item, at: 0)
        })
    }

    private var isQuiet: Bool {
        guard endRequestedAt == nil, phase != .needsTap, !modelTurnActive, !audio.isPlaying else { return false }
        let at = now
        // The model owes an answer: to the user's turn (until it counts as
        // unanswered), to a tool it called and is waiting on, or to what
        // just went to it. A text turn sent meanwhile would take its place.
        if awaitingReplySince != nil { return false }
        if let oldest = toolsInFlight.compactMap({ toolCalledAt[$0] }).min(), at - oldest < Self.toolHoldLimit { return false }
        if let sent = awaitingAnswerSince, at - sent < Self.replyWait { return false }
        if let spoke = lastUserSpeechAt, at - spoke < Self.userQuietInterval { return false }
        if let voiced = activity.lastVoicedAt, at - voiced < Self.userQuietInterval { return false }
        if let ended = lastModelTurnEndedAt, at - ended < Self.modelQuietInterval { return false }
        return true
    }

    /// While this call's jobs run, asks the iPhone for their news. Each ask
    /// wakes Conduit there briefly; none is made while no job runs.
    private func pollIfNeeded() {
        // With the wrist down the link is down: a poll would only fail.
        // The first tick after the wrist comes up asks at once.
        guard runningJobs > 0, !pollInFlight, link.isReachable, now - lastPollAt >= Self.pollInterval else { return }
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
                WatchCallLog.shared.note("directPoll", ["runningJobs": result.runningJobs, "outgoing": result.outgoing.count, "screen": "\(self.scenePhase)"])
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
        samplesCaptured += samples.count
        if let last = lastCaptureAt {
            maxCaptureGap = max(maxCaptureGap, time - last)
            windowMaxCaptureGap = max(windowMaxCaptureGap, time - last)
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
            if firstReadyAt != nil { samplesDroppedWhileDown += pendingSamples.count - limit }
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
        let id = callID
        session.send(.audio(pcm), onSent: { [weak self] in
            guard let self, self.callID == id else { return }
            self.sendsInFlight = max(0, self.sendsInFlight - 1)
            self.chunksSent += 1
        }, onFailure: { [weak self] in
            guard let self, self.callID == id else { return }
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
        WatchCallLog.shared.note("directTurn", [
            "replyMs": Int(reply * 1000),
            "screen": "\(scenePhase)",
        ])
    }

    private func playbackDrained() {
        lastPlaybackEndedAt = now
        guard isActive, phase == .speaking else { return }
        phase = .listening
        flushQuietQueue()
    }

    private func audioInterrupted(began: Bool) {
        guard isActive, endRequestedAt == nil else { return }
        WatchCallLog.shared.note("directAudioInterruption", ["began": began, "screen": "\(scenePhase)"])
        if began {
            // Before the iPhone's session came, a tap would have no call
            // to go back to.
            guard session != nil else {
                finish(String(localized: "The microphone was interrupted before the call connected. Try again."))
                return
            }
            pendingSamples = []
            activity.reset()
            microphoneStopped = true
            phase = .needsTap
        } else if scenePhase == .active {
            restartAudio()
        }
    }

    /// The session is activated again asynchronously first, as at
    /// the start; never with the synchronous call.
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
                WatchCallLog.shared.note("directAudioRestartHung", ["ms": Int((self.now - startedAt) * 1000)])
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let activated = await self.activateAudioSession()
            guard self.callID == id, self.isActive else {
                if activated, !self.isActive {
                    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                }
                return
            }
            // The revocation timing and the reactivation cadence count from
            // the activation, whether or not the engine then starts.
            let sinceActivation = self.lastActivationAt.map { Int(self.now - $0) }
            if activated { self.lastActivationAt = self.now }
            // Given up on as hung, and maybe tapped again since: the newer
            // attempt carries on.
            guard self.restartAttempts == attempt, self.restartingAudio else { return }
            self.restartingAudio = false
            if activated {
                WatchCallLog.shared.note("directAudioRestarted", [
                    "sinceActivationS": sinceActivation as Any,
                    "ms": Int((self.now - startedAt) * 1000),
                    "screen": "\(self.scenePhase)",
                ])
            }
            guard activated else {
                // Still waiting for a tap, which tries again.
                WatchCallLog.shared.note("directAudioRestartFailed", ["error": "activation failed"])
                return
            }
            self.startAudioAgain()
        }
    }

    private func startAudioAgain() {
        do {
            try audio.start(options: audioOptions, playbackRate: GeminiLiveProtocol.outputSampleRate)
            microphoneStopped = false
            guard endRequestedAt == nil else { return }
            phase = session?.isReady == true ? restingPhase : .reconnecting
        } catch {
            WatchCallLog.shared.note("directAudioRestartFailed", ["error": error.localizedDescription])
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
                WatchCallLog.shared.note("directWatchGap", ["ms": missed, "screen": "\(scenePhase)"])
            }
        }
        lastTickAt = at
        // A rejoin moved the phase on while the microphone stayed stopped:
        // the tap that brings it back has to show again.
        if microphoneStopped, endRequestedAt == nil, phase == .listening || phase == .speaking {
            phase = .needsTap
        }
        if phase == .preparing, now - callStartedAt >= Self.sessionWait + 15 {
            finish(String(localized: "Conduit on your iPhone didn't answer."))
            return
        }
        if let since = awaitingReplySince, now - since >= Self.unansweredAfter, !modelTurnActive {
            awaitingReplySince = nil
            unansweredTurns += 1
            WatchCallLog.shared.note("directUnanswered", [
                "screen": "\(scenePhase)",
                "ready": session?.isReady == true,
                "sinceHeardMs": lastUserSpeechAt.map { Int((now - $0) * 1000) } as Any,
                "sinceModelMs": lastModelEventAt.map { Int((now - $0) * 1000) } as Any,
                "sinceServerMs": lastServerEventAt.map { Int((now - $0) * 1000) } as Any,
                "silentTurn": silentTurnSinceUser,
                "toolsRunning": toolsInFlight.count,
                "awaitingAnswer": awaitingAnswerSince != nil,
                "playing": audio.isPlaying,
                "prompted": stallPromptedAt != nil,
            ])
        }
        promptIfStalled()
        rejoinIfStallUnanswered()
        endIfUserSaidGoodbye(finished: false)
        if let endAt = endRequestedAt {
            let lastSound = max(endAt, lastModelAudioAt ?? 0)
            if (!audio.isPlaying && now - lastSound >= Self.endGrace) || now - endAt >= Self.endTimeout {
                finish(WatchCallEnd.goodbye)
                return
            }
        }
        rejoinHungIfDue()
        rejoinIfDue()
        runWristQueueIfReachable()
        renewGrantIfDue()
        fetchJobNewsIfDue()
        pollIfNeeded()
        reactivateIfDue()
        audio.checkPlayback()
        timelineIfDue()
        flushQuietQueue()
    }

    /// Activates the session again, as the
    /// FB24377808 workaround does, and logs what it cost: how long it
    /// took, the route either side, whether the engine kept running.
    private func reactivateIfDue() {
        // An activation that never returned would stop the cadence for good.
        if reactivating, let started = reactivationStartedAt, now - started > Self.reactivationTimeout {
            reactivating = false
            // Counted here: if it returns after all, it only moves the anchor.
            reactivationStartedAt = nil
            reactivationFailures += 1
            WatchCallLog.shared.note("directReactivateHung", ["ms": Int((now - started) * 1000)])
        }
        guard !reactivating, let last = lastActivationAt, now - last >= Self.reactivateEvery else { return }
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
            // Given up on as hung (and maybe followed by another): already
            // counted, so it only moves the anchor.
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
            WatchCallLog.shared.note("directReactivate", [
                "activated": activated,
                "error": failure as Any,
                "ms": Int((at - startedAt) * 1000),
                "routeBefore": routeBefore,
                "routeAfter": session.currentRoute.outputs.map { $0.portType.rawValue },
                "engineBefore": engineBefore,
                "engineAfter": self.audio.isEngineRunning,
                "ready": self.session?.isReady == true,
                "phase": "\(self.phase)",
                "speaking": self.audio.isPlaying,
                "screen": "\(self.scenePhase)",
            ])
        }
    }

    /// One timeline entry: the audio session, the screen, the socket and
    /// its path, and whether PCM kept flowing both ways since the last.
    private func timelineIfDue() {
        let at = now
        let anchor = audioActivatedAt ?? callStartedAt
        let interval = at - anchor < Self.earlyTimelineSpan ? Self.earlyTimelineInterval : Self.lateTimelineInterval
        guard at - (lastTimelineAt ?? anchor) >= interval else { return }
        let window = lastTimelineAt.map { at - $0 } ?? (at - anchor)
        lastTimelineAt = at
        timelineEntries += 1
        let audioSession = AVAudioSession.sharedInstance()
        let mark = timelineMark
        timelineMark = (samplesCaptured, chunksSent, sendFailures, meter.bytesUp, meter.bytesDown, meter.framesDown)
        let gap = windowMaxCaptureGap
        windowMaxCaptureGap = 0
        guard timelineEntries <= 80 else { return }
        let state = String((session.map(\.stateDescription) ?? "none").prefix(40))
        WatchCallLog.shared.note("directTimeline", [
            "t": Int(at - callStartedAt),
            "sinceActivationS": lastActivationAt.map { Int(at - $0) } as Any,
            "sinceFirstActivationS": audioActivatedAt.map { Int(at - $0) } as Any,
            "windowS": Int(window.rounded()),
            "screen": "\(scenePhase)",
            "phase": "\(phase)",
            "category": audioSession.category.rawValue,
            "outputs": audioSession.currentRoute.outputs.map { $0.portType.rawValue },
            "otherAudio": audioSession.isOtherAudioPlaying,
            "engine": audio.isEngineRunning,
            "playing": audio.isPlaying,
            "session": state,
            "socketState": meter.socketState,
            "connectionAgeS": connectionReadyAt.map { Int(at - $0) } as Any,
            "monitorPath": monitorStatus as Any,
            "monitorUses": monitorUses,
            "capturedMs": (samplesCaptured - mark.captured) * 1000 / Int(WatchAudio.captureRate),
            "maxCaptureGapMs": Int(gap * 1000),
            "chunksSent": chunksSent - mark.chunksSent,
            "sendFailures": sendFailures - mark.sendFailures,
            "bytesUp": meter.bytesUp - mark.bytesUp,
            "bytesDown": meter.bytesDown - mark.bytesDown,
            "framesDown": meter.framesDown - mark.framesDown,
            "lastFrameAgeMs": meter.lastFrameAt.map { Int((at - $0) * 1000) } as Any,
            "reachable": link.isReachable,
        ])
    }

    /// The user's latest utterance is one of the profile's end phrases, as
    /// on the iPhone. Checked when the model's turn completes, and, when
    /// no turn is coming (the transcript arrived after the reply, or the
    /// model didn't answer), once the words went quiet with the model not
    /// mid-turn. A quiet utterance must end like a sentence: a pause
    /// mid-sentence ("By" of "By the way…") never ends the call.
    private func endIfUserSaidGoodbye(finished: Bool) {
        guard isActive, endRequestedAt == nil, !endPhrases.isEmpty, let line = exchangeUserLine,
              transcript.indices.contains(line) else { return }
        let text = transcript[line].text
        if !finished {
            guard !modelTurnActive, let heard = lastUserSpeechAt, now - heard >= Self.quietGoodbyeDelay,
                  Self.endsAnUtterance(text) else { return }
        }
        guard VoiceSpokenCommands.matchesSpokenCommand(text, phrases: endPhrases) else { return }
        exchangeUserLine = nil
        WatchCallLog.shared.note("directGoodbyeHeard", ["afterTurn": finished])
        requestEnd()
    }

    static let quietGoodbyeDelay: TimeInterval = 1.5

    static func endsAnUtterance(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?。！？".contains(last)
    }

    /// Hermes said goodbye (end_conversation), or the user did: the
    /// microphone closes and the call ends once the goodbye has played.
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
        grokStreams = 0
        ring = nil
        callID = UInt32.random(in: 1...UInt32.max)
        callUUID = UUID()
        callStartedDate = Date()
        callStartedAt = now
        session?.stop()
        session = nil
        tokens = nil
        meter = WatchSocketMeter()
        stopPathMonitor()
        monitorFirstStatus = nil
        monitorStatus = nil
        monitorUses = []
        monitorUpdates = 0
        firstUnsatisfiedAt = nil
        socketNotes = 0
        restartingAudio = false
        microphoneStopped = false
        openingPrompt = nil
        endPhrases = []
        exchangeUserLine = nil
        hasSentOpening = false
        caption = nil
        isMuted = false
        runningJobs = 0
        audioSessionActivated = nil
        sessionRequests = 0
        sessionAt = nil
        connectStartedAt = nil
        firstReadyAt = nil
        reconnectStartedAt = nil
        reconnectTimes = []
        connectionReadyAt = nil
        connectionLifetimes = []
        lastTickAt = nil
        audioActivatedAt = nil
        lastActivationAt = nil
        reactivationStartedAt = nil
        reactivating = false
        reactivations = 0
        reactivationFailures = 0
        reactivationTimes = []
        maxReactivationCaptureGap = 0
        routeChangesAtStart = audio.routeChanges
        playbackStallsAtStart = audio.playbackStalls
        firstDropAt = nil
        lastTimelineAt = nil
        timelineEntries = 0
        samplesCaptured = 0
        chunksSent = 0
        timelineMark = (0, 0, 0, 0, 0, 0)
        windowMaxCaptureGap = 0
        watchSuspendedMs = 0
        watchGaps = 0
        handoffStartedAt = nil
        handoffTimes = []
        drops = 0
        goAways = 0
        loggedResumable = false
        tokensFromPhone = 0
        tokensReused = 0
        tokensFromRelay = 0
        tokenFailures = 0
        rejoinWaitingSince = nil
        rejoinReason = nil
        rejoinCause = .broke
        rejoinStartedAt = nil
        rejoinWristDown = false
        wristDownRejoinFailed = false
        rejoins = 0
        rejoinTimes = []
        rejoinsHung = 0
        samplesDroppedWhileDown = 0
        generationOffset = 0
        suppressingModelTurn = false
        modelTurnActive = false
        lastUserSpeechAt = nil
        lastModelTurnEndedAt = nil
        lastModelAudioAt = nil
        awaitingReplySince = nil
        awaitingAnswerSince = nil
        unansweredTurns = 0
        replyOwedSince = nil
        silentTurnSinceUser = false
        stallPromptedAt = nil
        stallPrompts = 0
        stallPromptsAnswered = 0
        stallPromptsSilent = 0
        stalls = 0
        silentTurns = 0
        lastModelEventAt = nil
        lastServerEventAt = nil
        turnStartedAt = nil
        turnFirstAudioAt = nil
        turnHeardAt = nil
        turnVoicedAt = nil
        turnAnswering = nil
        turnAudioSeconds = 0
        turnTools = 0
        turnMaxGap = 0
        turnEndedByInterruption = false
        modelTurnNotes = 0
        heardReplyTimes = []
        endRequestedAt = nil
        transcript = []
        openUserLine = nil
        openAssistantLine = nil
        toolsInFlight = []
        toolCalledAt = [:]
        toolCallsSpokenFor = []
        startJobsTakenSilently = 0
        withdrawnToolIDs = []
        quietQueue = []
        toolCalls = 0
        toolsAnsweredLive = 0
        toolsUnreachable = 0
        jobsQueued = 0
        wristQueue = []
        toolsWaitedForWrist = 0
        wristWaits = []
        toolRelay?.close()
        toolRelay = nil
        hadToolGrant = false
        grantRequestInFlight = false
        lastGrantRequestAt = 0
        grantRequests = 0
        grantsRenewed = 0
        toolsViaRelay = 0
        relayErrorAnswers = 0
        relayTimeouts = 0
        relayFallbacks = 0
        relayFailures = 0
        relayTimes = []
        pollInFlight = false
        lastPollAt = 0
        polls = 0
        pollsFailed = 0
        textUpdatesSent = 0
        jobRelays.forEach { $0.close() }
        jobRelays = []
        jobsGrant?.close()
        jobsGrant = nil
        jobsMovedTo = [:]
        jobsCarried = 0
        relayRunning = [:]
        relayJobsRunning = 0
        approvals = []
        pendingApproval = nil
        newsInFlight = false
        nextNewsAt = 0
        relayJobsStarted = 0
        jobLog.reset()
        jobCallsViaRelay = 0
        jobNewsAsks = 0
        jobNewsFailed = 0
        jobNewsItems = 0
        approvalsShown = 0
        approvalsTapped = 0
        approvalsByVoice = 0
        approvalFailures = 0
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
        session?.stop()
        session = nil
        tokens = nil
        // Ends the grants on the relay and so on Hermes; the iPhone revokes
        // them too once the call's end reaches it. Jobs still running keep
        // running in Hermes, and their results come as notifications.
        toolRelay?.close()
        toolRelay = nil
        let relayJobsLeft = relayJobsRunning
        jobRelays.forEach { $0.close() }
        jobRelays = []
        jobsGrant?.close()
        jobsGrant = nil
        jobsMovedTo = [:]
        approvals = []
        pendingApproval = nil
        stopPathMonitor()
        // A restart still waiting on its activation is over too.
        restartingAudio = false
        // The session is the call's own, ended below even when the engine
        // wasn't running (a start or restart that failed): `stop` only
        // deactivates a session whose engine ran.
        audio.stop(deactivating: false)
        if audioSessionActivated == true {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        if let since = screenOffSince { screenOffSeconds += now - since }
        let liveSeconds = liveSince.map { now - $0 } ?? 0
        phase = .ended(reason)
        // Jobs still waiting for the wrist start once the iPhone takes
        // them, after the call; queued ahead of its end.
        let jobsLeft = wristQueue.filter { $0.call.name == "start_job" }
        var jobsNotQueued = 0
        for job in jobsLeft {
            if link.queue(.directTool(callID: callID, call: job.call)) {
                jobsQueued += 1
            } else {
                jobsNotQueued += 1
            }
        }
        if jobsNotQueued > 0 {
            WatchCallLog.shared.note("directJobQueueFailed", ["count": jobsNotQueued])
        }
        // Queued, not sent: the iPhone saves the call whenever Conduit next
        // runs there, asleep or not right now.
        let saved = WatchVoiceWire.DirectTranscript.capped(
            transcript.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        let queued = link.queue(.directEnd(callID: callID, transcript: .init(
            callUUID: callUUID.uuidString,
            startedAt: callStartedDate,
            endedAt: Date(),
            turns: saved,
            engine: engine == .grok ? WatchAudioBridgeWire.grok : nil,
            jobs: jobLog.jobs.isEmpty ? nil : jobLog.jobs
        )))
        if !queued {
            WatchCallLog.shared.note("directEndQueueFailed", ["lines": saved.count])
        }
        let battery = WKInterfaceDevice.current().batteryLevel
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
        let liveForRate = max(1, liveSeconds)
        WatchCallLog.shared.report("directCallSummary", [
            "callID": Int(callID),
            "reason": reason as Any,
            "durationS": Int(now - callStartedAt),
            "liveS": Int(liveSeconds),
            "reactivateEveryS": Int(Self.reactivateEvery),
            "reactivations": reactivations,
            "reactivationFailures": reactivationFailures,
            "reactivationMaxMs": WatchVoiceStats.milliseconds(reactivationTimes.max()) as Any,
            "maxReactivationCaptureGapMs": Int(maxReactivationCaptureGap * 1000),
            "firstDropSinceActivationS": firstDropAt.flatMap { drop in audioActivatedAt.map { Int(drop - $0) } } as Any,
            "pathMonitorFirst": monitorFirstStatus as Any,
            "pathMonitorLast": monitorStatus as Any,
            "pathMonitorUpdates": monitorUpdates,
            "firstUnsatisfiedSinceActivationS": firstUnsatisfiedAt.flatMap { at in audioActivatedAt.map { Int(at - $0) } } as Any,
            "routeChanges": audio.routeChanges - routeChangesAtStart,
            "playbackStalls": audio.playbackStalls - playbackStallsAtStart,
            "audioSessionActivated": audioSessionActivated as Any,
            "sessionMs": sessionAt.map { Int(($0 - callStartedAt) * 1000) } as Any,
            "sessionRequests": sessionRequests,
            "connectMs": firstReadyAt.flatMap { ready in connectStartedAt.map { Int((ready - $0) * 1000) } } as Any,
            "firstReadyMs": firstReadyAt.map { Int(($0 - callStartedAt) * 1000) } as Any,
            "socketsOpened": meter.opened,
            "turns": turns,
            "turnsWhileScreenOff": turnsWhileScreenOff,
            "unansweredTurns": unansweredTurns,
            "silentTurns": silentTurns,
            "stallPrompts": stallPrompts,
            "stallPromptsAnswered": stallPromptsAnswered,
            "stallPromptsSilent": stallPromptsSilent,
            "stalls": stalls,
            "heardReplyP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(heardReplyTimes, 0.5)) as Any,
            "heardReplyP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(heardReplyTimes, 0.95)) as Any,
            "replies": replyTimes.count,
            "replyP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(replyTimes, 0.5)) as Any,
            "replyP95Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(replyTimes, 0.95)) as Any,
            "maxAudioGapMs": Int(maxAudioGap * 1000),
            "maxCaptureGapMs": Int(maxCaptureGap * 1000),
            "drops": drops,
            "reconnects": reconnectTimes.count,
            "reconnectP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(reconnectTimes, 0.5)) as Any,
            "reconnectMaxMs": WatchVoiceStats.milliseconds(reconnectTimes.max()) as Any,
            "rejoins": rejoins,
            "rejoinMaxMs": WatchVoiceStats.milliseconds(rejoinTimes.max()) as Any,
            "rejoinsHung": rejoinsHung,
            "connectionLifetimesS": connectionLifetimes.map { Int($0) },
            "goAways": goAways,
            "handoffs": handoffTimes.count,
            "handoffP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(handoffTimes, 0.5)) as Any,
            "tokensFromPhone": tokensFromPhone,
            "tokensReused": tokensReused,
            "tokensFromRelay": tokensFromRelay,
            "tokenFailures": tokenFailures,
            "startJobsTakenSilently": startJobsTakenSilently,
            "toolCalls": toolCalls,
            "toolsAnsweredLive": toolsAnsweredLive,
            "toolsUnreachable": toolsUnreachable,
            "jobsQueued": jobsQueued,
            "toolsWaitedForWrist": toolsWaitedForWrist,
            "toolsStillWaiting": wristQueue.count,
            "wristWaitP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(wristWaits, 0.5)) as Any,
            "wristWaitMaxMs": WatchVoiceStats.milliseconds(wristWaits.max()) as Any,
            "toolGrant": hadToolGrant,
            "toolsViaRelay": toolsViaRelay,
            "relayErrorAnswers": relayErrorAnswers,
            "relayP50Ms": WatchVoiceStats.milliseconds(WatchVoiceStats.percentile(relayTimes, 0.5)) as Any,
            "relayMaxMs": WatchVoiceStats.milliseconds(relayTimes.max()) as Any,
            "relayTimeouts": relayTimeouts,
            "relayFallbacks": relayFallbacks,
            "relayFailures": relayFailures,
            "grantRequests": grantRequests,
            "grantsRenewed": grantsRenewed,
            "polls": polls,
            "pollsFailed": pollsFailed,
            "jobCallsViaRelay": jobCallsViaRelay,
            "jobsViaRelay": relayJobsStarted,
            "jobsCarried": jobsCarried,
            "relayJobsStillRunning": relayJobsLeft,
            "jobNewsAsks": jobNewsAsks,
            "jobNewsFailed": jobNewsFailed,
            "jobNewsItems": jobNewsItems,
            "approvalsShown": approvalsShown,
            "approvalsTapped": approvalsTapped,
            "approvalsByVoice": approvalsByVoice,
            "approvalFailures": approvalFailures,
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
        case relay
        case failed
    }

    /// A reused token needs this long left, so it doesn't expire mid-setup.
    static let reuseMargin: TimeInterval = 60

    var fetch: (@MainActor () async throws -> GeminiLiveToken)?
    /// Hermes' token through the call's grant, for when the iPhone can't
    /// answer and the token in hand can't serve: a fresh session, or one
    /// about to expire. Nil, or throwing, when the grant can't mint one.
    var relayFetch: (@MainActor () async throws -> GeminiLiveToken)?
    var canResume: @MainActor () -> Bool = { false }
    var onIssued: ((Source, String?) -> Void)?
    private var first: GeminiLiveToken?
    private var latest: GeminiLiveToken
    /// One try through the relay per rejoin, or per connection lost: the
    /// session's next connect attempt doesn't spend another of the grant's
    /// tokens.
    private var relayTried = false
    /// A token is on its way through the relay.
    private(set) var relayInFlight = false

    /// A rejoin may ask the relay once more.
    func allowRelayTry() {
        relayTried = false
    }

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
            // A stopped session mustn't spend one of Hermes' tokens.
            if Task.isCancelled { throw CancellationError() }
            guard let relayFetch, !relayTried else {
                onIssued?(.failed, error.localizedDescription)
                throw error
            }
            relayTried = true
            relayInFlight = true
            defer { relayInFlight = false }
            do {
                let token = try await relayFetch()
                latest = token
                onIssued?(.relay, error.localizedDescription)
                return token
            } catch let relayError {
                onIssued?(.failed, "\(error.localizedDescription) Relay: \(relayError.localizedDescription)")
                throw relayError
            }
        }
    }
}

enum WatchDirectError: LocalizedError {
    case ended
    case unreadable
    case timedOut
    case refused(String)
    /// The call's grant can't bring a Gemini token through the relay.
    case noRelayToken
    case relayToken(String)

    var errorDescription: String? {
        switch self {
        case .ended: return String(localized: "The call ended.")
        case .unreadable: return String(localized: "Conduit on the iPhone sent something this Watch app can't read.")
        case .timedOut: return String(localized: "Conduit on the iPhone didn't answer in time.")
        case .refused(let reason): return reason
        case .noRelayToken: return String(localized: "This call can't get a Gemini token through the relay.")
        case .relayToken(let reason): return String(localized: "No Gemini token through the relay: \(reason)")
        }
    }
}
