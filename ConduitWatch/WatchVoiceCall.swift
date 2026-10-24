//
//  WatchVoiceCall.swift
//  Conduit Watch
//
//  The one call the Watch app shows, whichever engine runs it: Gemini Live
//  on the Watch itself or Grok on the Hermes host (WatchDirectCallModel,
//  which runs both conversations), or GPT-Live through the Hermes host's
//  audio bridge (WatchBridgeCallModel). The screens read the
//  call from here and send its controls here, so they never depend on the
//  engine.
//

import Combine
import SwiftUI
import WatchKit

/// Why a call ended, when nothing went wrong: the screens don't show
/// these as errors.
enum WatchCallEnd {
    static let byUser = "ended on the Watch"
    static let goodbye = "Hermes said goodbye."
    /// The call's grant has no audio streams left (the host refused one, or
    /// the Watch used them all): only a new call gets more.
    static let streamsSpent = String(localized: "This call can't reconnect to Hermes again. Start the call again.")

    static func isNormal(_ reason: String?) -> Bool {
        guard let reason else { return true }
        return reason == byUser || reason == goodbye
    }
}

/// The voice a Watch call talks to, picked on the Watch.
enum WatchVoiceEngine: String, CaseIterable, Identifiable {
    case geminiLive
    case qwenLive
    case gptLive
    case grokLive
    case localLive

    static let storageKey = "watchVoice.engine"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geminiLive: return String(localized: "Gemini Live")
        case .qwenLive: return String(localized: "Qwen Live")
        case .gptLive: return String(localized: "GPT-Live")
        case .grokLive: return String(localized: "Grok")
        case .localLive: return String(localized: "Local Live")
        }
    }

    var detail: String {
        switch self {
        case .geminiLive: return String(localized: "Connects directly from your Watch")
        case .qwenLive: return String(localized: "Connects directly from your Watch")
        case .gptLive, .grokLive: return String(localized: "Runs on your Hermes host")
        case .localLive: return String(localized: "Your own speech server")
        }
    }

    /// This voice as the iPhone names it (WatchCallVoices).
    var callVoice: WatchCallVoices.Voice {
        switch self {
        case .geminiLive: return .geminiLive
        case .qwenLive: return .qwenLive
        case .gptLive: return .gptLive
        case .grokLive: return .grokLive
        case .localLive: return .localLive
        }
    }

    var symbol: String {
        switch self {
        case .geminiLive: return "sparkles"
        case .qwenLive: return "sparkles"
        case .gptLive: return "waveform.path.ecg"
        case .grokLive: return "bolt.fill"
        case .localLive: return "house.fill"
        }
    }
}

@MainActor
final class WatchVoiceCall: ObservableObject {
    /// The app's one call: the screens and a call from Hermes answered on
    /// the Watch (HermesWatchCalls) share it.
    static let shared = WatchVoiceCall()

    enum Phase: Equatable {
        case idle
        /// Starting the Watch's audio and asking the iPhone for the call.
        case preparing
        case connecting
        case listening
        case speaking
        case reconnecting
        /// The connection broke and a fresh one waits for the iPhone: the
        /// wrist comes up.
        case lost
        /// Siri or an alarm took the microphone: a tap brings it back.
        case needsTap
        case ending
        case ended(String?)
    }

    @Published var engine: WatchVoiceEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: WatchVoiceEngine.storageKey) }
    }
    /// Opening Conduit starts a call, with no tap on the orb.
    @Published var startsOnOpen: Bool {
        didSet { UserDefaults.standard.set(startsOnOpen, forKey: Self.startsOnOpenKey) }
    }
    static let startsOnOpenKey = "watchStartsCallOnOpen"
    /// The app has been in front since launch.
    private var hasBeenActive = false
    /// The app went to the background since it was last in front.
    private var wasBackgrounded = false
    /// A call on open was skipped for the microphone permission: logged
    /// once a launch.
    private var loggedOpenSkip = false
    /// The scene's last phase, nil until SwiftUI reports the first.
    private var scenePhase: ScenePhase?
    /// A call asked for from outside the app (`requestCall`) while the app
    /// wasn't in front yet: it starts once the app is. Only the latest
    /// request is kept; every source asks for the same call.
    private var pendingRequest: (source: String, at: Date)?
    /// The engine of the call on screen, which a change of `engine` during
    /// the call doesn't move.
    @Published private(set) var callEngine: WatchVoiceEngine
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var caption: String?
    @Published private(set) var transcript: [WatchVoiceWire.DirectTurn] = []
    @Published private(set) var isMuted = false
    @Published private(set) var jobsRunning = 0
    @Published private(set) var pendingApproval: WatchJobAnswer.Approval?
    /// When the call connected, for the call timer.
    @Published private(set) var liveSince: Date?
    @Published private(set) var endedAt: Date?

    let direct = WatchDirectCallModel()
    let bridge = WatchBridgeCallModel()
    private var cancellables: Set<AnyCancellable> = []
    private var refreshQueued = false
    /// The ended call's summary was dismissed: its model's end is old news
    /// until the next call starts.
    private var summaryDismissed = false
    /// The model's previous call when a new one was started, until the
    /// model begins the new one: until then, what it shows is old news.
    private var previousModelCall: UInt32?

    init() {
        let stored = UserDefaults.standard.string(forKey: WatchVoiceEngine.storageKey).flatMap(WatchVoiceEngine.init(rawValue:))
        engine = stored ?? .geminiLive
        callEngine = stored ?? .geminiLive
        startsOnOpen = UserDefaults.standard.object(forKey: Self.startsOnOpenKey) as? Bool ?? true
        // Models publish before they change: read them once the change is in.
        for model in [direct.objectWillChange, bridge.objectWillChange] {
            model.sink { [weak self] _ in self?.queueRefresh() }.store(in: &cancellables)
        }
    }

    /// A call is starting, running or ending.
    var isActive: Bool {
        switch phase {
        case .idle, .ended: return false
        default: return true
        }
    }

    /// The call screen is up: a call is on, or one just ended and its
    /// summary hasn't been dismissed.
    var isPresenting: Bool { phase != .idle }

    var endedReason: String? {
        if case .ended(let reason) = phase { return reason }
        return nil
    }

    // MARK: Controls

    /// `ring`: the call from Hermes it answers (HermesWatchCalls), which
    /// the iPhone opens it with. `answer`: where its session comes through
    /// the relay, with the call id and engine the start sent to the iPhone
    /// named.
    func start(ring: String? = nil, answer: HermesRingAnswer? = nil, engine chosen: WatchVoiceEngine? = nil) {
        guard !isActive else { return }
        callEngine = chosen ?? engine
        summaryDismissed = false
        liveSince = nil
        endedAt = nil
        caption = nil
        transcript = []
        phase = .preparing
        previousModelCall = modelCallID
        switch callEngine {
        case .geminiLive: Task { await direct.start(engine: .gemini, ring: ring, answer: answer) }
        case .qwenLive: Task { await direct.start(engine: .qwen, ring: ring, answer: answer) }
        case .grokLive: Task { await direct.start(engine: .grok, ring: ring, answer: answer) }
        // Calls from Hermes don't ring a Watch on Local Live (WatchCallVoices).
        case .localLive: Task { await direct.start(engine: .localLive) }
        case .gptLive: Task { await bridge.start(ring: ring, answer: answer) }
        }
    }

    /// The start a call on `engine` asks the iPhone for its session with,
    /// as each model sends it.
    static func startRequest(engine: WatchVoiceEngine, callID: UInt32, ring: String?) -> WatchVoiceWire.Message {
        switch engine {
        case .geminiLive: return WatchDirectCallModel.startRequest(engine: .gemini, callID: callID, ring: ring)
        case .qwenLive: return WatchDirectCallModel.startRequest(engine: .qwen, callID: callID, ring: ring)
        case .grokLive: return WatchDirectCallModel.startRequest(engine: .grok, callID: callID, ring: ring)
        case .localLive: return WatchDirectCallModel.startRequest(engine: .localLive, callID: callID, ring: ring)
        case .gptLive: return WatchBridgeCallModel.startRequest(callID: callID, ring: ring)
        }
    }

    func end() {
        switch callEngine {
        case .geminiLive, .qwenLive, .grokLive, .localLive: direct.end()
        case .gptLive: bridge.end()
        }
    }

    /// Stops the voice while it speaks; brings the microphone back after
    /// Siri or an alarm.
    func tap() {
        switch callEngine {
        case .geminiLive, .qwenLive, .grokLive, .localLive: direct.tapOrb()
        case .gptLive: bridge.tapOrb()
        }
    }

    func toggleMute() {
        switch callEngine {
        case .geminiLive, .qwenLive, .grokLive, .localLive: direct.toggleMute()
        case .gptLive: bridge.toggleMute()
        }
    }

    /// Answers the approval the card showed, never one queued behind it.
    func answerApproval(_ approval: WatchJobAnswer.Approval, approve: Bool) {
        switch callEngine {
        case .geminiLive, .qwenLive, .grokLive, .localLive: direct.answerApproval(approval, approve: approve)
        case .gptLive: bridge.answerApproval(approval, approve: approve)
        }
    }

    /// Back to the home screen after a call's summary.
    func dismissEnded() {
        guard case .ended = phase else { return }
        summaryDismissed = true
        phase = .idle
        caption = nil
        transcript = []
        liveSince = nil
        endedAt = nil
    }

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        direct.scenePhaseChanged(newPhase)
        bridge.scenePhaseChanged(newPhase)
        // Opened: the first active since launch, or the first since the
        // app went to the background (either can pass through inactive on
        // the way). A wrist raise never left inactive and starts nothing:
        // watchOS keeps the app frontmost (inactive) with the wrist down,
        // and only backgrounds it on a press of the crown or once Return
        // to Clock runs out (WatchKit, "Taking advantage of frontmost app
        // state").
        scenePhase = newPhase
        if newPhase == .background { wasBackgrounded = true }
        if newPhase == .active {
            if let request = pendingRequest {
                pendingRequest = nil
                let age = Date().timeIntervalSince(request.at)
                if age < Self.requestLifetime {
                    startRequested(source: request.source)
                } else {
                    WatchCallLog.shared.note("callRequestExpired", ["source": request.source, "seconds": Int(age)])
                }
            }
            if !hasBeenActive || wasBackgrounded { startOnOpenIfWanted() }
            hasBeenActive = true
            wasBackgrounded = false
        }
        // Call diagnostics only: an idle wrist raise isn't worth a line.
        guard isActive else { return }
        WatchCallLog.shared.note("scenePhase", ["phase": "\(newPhase)", "reachable": WatchLink.shared.isReachable])
    }

    /// How long a call asked for before the app came to the front still
    /// starts when it does.
    static let requestLifetime: TimeInterval = 60

    /// A call asked for from outside the app: the Action button or a
    /// control (watchOS 26), the watch face complication or a shortcut
    /// (TalkToHermesIntent, WatchCallURL). It starts whatever Call on open
    /// says, and from a wrist raise too: the press asked for it.
    func requestCall(source: String) {
        WatchCallLog.shared.note("callRequested", ["source": source, "screen": scenePhase.map { "\($0)" } ?? "launching"])
        guard scenePhase == .active else {
            if let older = pendingRequest {
                WatchCallLog.shared.note("callRequestReplaced", ["source": older.source, "by": source])
            }
            pendingRequest = (source, Date())
            return
        }
        startRequested(source: source)
    }

    private func startRequested(source: String) {
        // A call from Hermes ringing or answered is the call.
        guard !isActive, !HermesWatchCalls.shared.holdsCall else {
            WatchCallLog.shared.note("callRequestDropped", ["source": source, "callOn": isActive, "hermesCall": HermesWatchCalls.shared.holdsCall])
            return
        }
        WatchCallLog.shared.note("callStartedOnRequest", ["source": source, "engine": engine.rawValue])
        dismissEnded()
        start()
    }

    private func startOnOpenIfWanted() {
        // A call from Hermes ringing or answered is the call.
        guard !isScreenshotFixture, startsOnOpen, !isActive, !HermesWatchCalls.shared.holdsCall else { return }
        // Back from the background is an open, however soon after a call
        // ended: reading the summary with the wrist down and up again
        // never leaves inactive. Return to Clock running out on the summary
        // does background the app; opening it after that is an open too
        // (the call is saved on the iPhone).
        // The microphone prompt is left to a tap on Start.
        guard WatchAudio.hasPermission else {
            if !loggedOpenSkip {
                loggedOpenSkip = true
                WatchCallLog.shared.note("callOnOpenSkipped", ["reason": "noMicrophonePermission"])
            }
            return
        }
        WatchCallLog.shared.note("callStartedOnOpen", ["engine": engine.rawValue])
        dismissEnded()
        start()
    }

    // MARK: Screenshot fixture

    /// Set by `-conduitScreenshotCall home|speaking|listening|ended|approval|approvalDenyOnly` (debug builds only):
    /// the App Store screenshot run (scripts/app-store) shows a call in that
    /// state with no audio or connection behind it.
    private(set) var isScreenshotFixture = false

    func applyScreenshotFixture(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-conduitScreenshotCall"), index + 1 < arguments.count else { return }
        isScreenshotFixture = true
        if arguments[index + 1] == "home" { return }
        // Demo content, English only like the rest of the demo world.
        let now = Date()
        callEngine = engine
        transcript = [
            .init(role: .user, text: "What's on my calendar this afternoon?", at: now.addingTimeInterval(-70)),
            .init(role: .assistant, text: "Two things: a dentist appointment at 3, and Maya's soccer practice at 5:30. Want me to set a reminder to leave by 2:40?", at: now.addingTimeInterval(-62)),
            .init(role: .user, text: "Yes, and text Maya's coach that we might be ten minutes late.", at: now.addingTimeInterval(-40)),
            .init(role: .assistant, text: "Reminder set for 2:40. I've drafted the text to Coach Rivera and started a job to send it.", at: now.addingTimeInterval(-30)),
        ]
        liveSince = now.addingTimeInterval(-83)
        jobsRunning = 1
        switch arguments[index + 1] {
        case "ended":
            endedAt = now
            phase = .ended(nil)
        case "listening":
            phase = .listening
        case "approval", "approvalDenyOnly":
            // A Local Live call's own request, on the job approvals' card.
            pendingApproval = WatchJobAnswer.Approval(
                grantID: "", jobID: "", title: "Delete the old build folder", requestID: "fixture",
                command: "rm -rf ~/Projects/site/build", description: "",
                canApproveOnce: arguments[index + 1] == "approval")
            phase = .speaking
        default:
            caption = transcript.last?.text
            phase = .speaking
        }
        #endif
    }

    // MARK: State

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        WatchVoiceMain.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func refresh() {
        guard !summaryDismissed, !isScreenshotFixture else { return }
        let next: Phase
        switch callEngine {
        case .geminiLive, .qwenLive, .grokLive, .localLive: next = Self.phase(direct.phase)
        case .gptLive: next = Self.phase(bridge.phase)
        }
        // Only a dismissed summary goes back to the home screen: a model
        // at rest before its start has run isn't the end of the call, and
        // still holds the last call's lines; nor is the end it still shows.
        if next == .idle { return }
        if let previous = previousModelCall {
            guard modelCallID != previous else { return }
            previousModelCall = nil
        }
        switch callEngine {
        case .geminiLive, .qwenLive, .grokLive, .localLive:
            caption = direct.caption
            transcript = direct.transcript
            isMuted = direct.isMuted
            jobsRunning = direct.runningJobs + direct.relayJobsRunning
            pendingApproval = direct.pendingApproval
        case .gptLive:
            caption = bridge.caption
            transcript = bridge.transcript
            isMuted = bridge.isMuted
            jobsRunning = bridge.relayJobsRunning
            pendingApproval = bridge.pendingApproval
        }
        if liveSince == nil, next == .listening || next == .speaking {
            liveSince = Date()
            WKInterfaceDevice.current().play(.start)
        }
        if case .ended(let reason) = next, endedAt == nil {
            endedAt = Date()
            WKInterfaceDevice.current().play(WatchCallEnd.isNormal(reason) ? .stop : .failure)
        }
        if phase != next { phase = next }
    }

    private var modelCallID: UInt32 {
        switch callEngine {
        case .geminiLive, .qwenLive, .grokLive, .localLive: return direct.callID
        case .gptLive: return bridge.callID
        }
    }

    private static func phase(_ phase: WatchDirectCallModel.Phase) -> Phase {
        switch phase {
        case .idle: return .idle
        case .preparing: return .preparing
        case .connecting: return .connecting
        case .listening: return .listening
        case .speaking: return .speaking
        case .reconnecting: return .reconnecting
        case .lost: return .lost
        case .needsTap: return .needsTap
        case .ending: return .ending
        case .ended(let reason): return .ended(reason)
        }
    }

    private static func phase(_ phase: WatchBridgeCallModel.Phase) -> Phase {
        switch phase {
        case .idle: return .idle
        case .preparing: return .preparing
        case .connecting: return .connecting
        case .listening: return .listening
        case .speaking: return .speaking
        case .reconnecting: return .reconnecting
        case .needsTap: return .needsTap
        case .ending: return .ending
        case .ended(let reason): return .ended(reason)
        }
    }
}
