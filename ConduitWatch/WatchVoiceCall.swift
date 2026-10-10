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

    static func isNormal(_ reason: String?) -> Bool {
        guard let reason else { return true }
        return reason == byUser || reason == goodbye
    }
}

/// The voice a Watch call talks to, picked on the Watch.
enum WatchVoiceEngine: String, CaseIterable, Identifiable {
    case geminiLive
    case gptLive
    case grokLive

    static let storageKey = "watchVoice.engine"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geminiLive: return String(localized: "Gemini Live")
        case .gptLive: return String(localized: "GPT-Live")
        case .grokLive: return String(localized: "Grok")
        }
    }

    var detail: String {
        switch self {
        case .geminiLive: return String(localized: "Runs on your Watch")
        case .gptLive, .grokLive: return String(localized: "Runs on your Hermes host")
        }
    }

    var symbol: String {
        switch self {
        case .geminiLive: return "sparkles"
        case .gptLive: return "waveform.path.ecg"
        case .grokLive: return "bolt.fill"
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
    /// the iPhone opens it with.
    func start(ring: String? = nil) {
        guard !isActive else { return }
        callEngine = engine
        summaryDismissed = false
        liveSince = nil
        endedAt = nil
        caption = nil
        transcript = []
        phase = .preparing
        previousModelCall = modelCallID
        switch callEngine {
        case .geminiLive: Task { await direct.start(engine: .gemini, ring: ring) }
        case .grokLive: Task { await direct.start(engine: .grok, ring: ring) }
        case .gptLive: Task { await bridge.start(ring: ring) }
        }
    }

    func end() {
        switch callEngine {
        case .geminiLive, .grokLive: direct.end()
        case .gptLive: bridge.end()
        }
    }

    /// Stops the voice while it speaks; brings the microphone back after
    /// Siri or an alarm.
    func tap() {
        switch callEngine {
        case .geminiLive, .grokLive: direct.tapOrb()
        case .gptLive: bridge.tapOrb()
        }
    }

    func toggleMute() {
        switch callEngine {
        case .geminiLive, .grokLive: direct.toggleMute()
        case .gptLive: bridge.toggleMute()
        }
    }

    /// Answers the approval the card showed, never one queued behind it.
    func answerApproval(_ approval: WatchJobAnswer.Approval, approve: Bool) {
        switch callEngine {
        case .geminiLive, .grokLive: direct.answerApproval(approval, approve: approve)
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
    }

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        direct.scenePhaseChanged(newPhase)
        bridge.scenePhaseChanged(newPhase)
        // Opened: the first active since launch, or the first since the
        // app went to the background (either can pass through inactive on
        // the way). A wrist raise never left inactive and starts nothing.
        if newPhase == .background { wasBackgrounded = true }
        if newPhase == .active {
            if !hasBeenActive || wasBackgrounded { startOnOpenIfWanted() }
            hasBeenActive = true
            wasBackgrounded = false
        }
        // Call diagnostics only: an idle wrist raise isn't worth a line.
        guard isActive else { return }
        WatchCallLog.shared.note("scenePhase", ["phase": "\(newPhase)", "reachable": WatchLink.shared.isReachable])
    }

    static let openAfterEndPause: TimeInterval = 120

    private func startOnOpenIfWanted() {
        // A call from Hermes ringing or answered is the call.
        guard startsOnOpen, !isActive, !HermesWatchCalls.shared.holdsCall else { return }
        // Back in front soon after a call ended (the wrist went down on
        // its summary): the user is reading it, not calling again.
        if let endedAt, Date().timeIntervalSince(endedAt) < Self.openAfterEndPause { return }
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
        guard !summaryDismissed else { return }
        let next: Phase
        switch callEngine {
        case .geminiLive, .grokLive: next = Self.phase(direct.phase)
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
        case .geminiLive, .grokLive:
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
        case .geminiLive, .grokLive: return direct.callID
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
