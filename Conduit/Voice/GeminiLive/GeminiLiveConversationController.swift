//
//  GeminiLiveConversationController.swift
//  Conduit
//
//  Gemini Live voice mode: microphone audio streams to gemini-3.8-live and
//  its speech streams back, with Hermes background jobs as its tools. It is
//  a separate mode next to the classic Voice conversation (which it never
//  touches); AppState guarantees the two never run at once, and both share
//  VoiceAudioSessionCoordinator through their capture/playback services.
//
//  Not talking over the user: the server's activity detection interrupts
//  the model as soon as the user speaks (playback stops on `interrupted`),
//  and Conduit's own job updates are only sent while nobody is speaking.
//

import Foundation

// MARK: - Seams

@MainActor
protocol GeminiLiveSessionControlling: AnyObject {
    var onEvent: (@MainActor (GeminiLiveProtocol.ServerEvent) -> Void)? { get set }
    var onStateChange: (@MainActor (GeminiLiveSession.State) -> Void)? { get set }
    var onConnectionReplaced: (@MainActor () -> Void)? { get set }
    var isReady: Bool { get }
    func start()
    func stop()
    func send(_ message: [String: Any])
}

extension GeminiLiveSession: GeminiLiveSessionControlling {}

@MainActor
protocol GeminiLiveAudioInput: AnyObject {
    var onChunk: (@MainActor (Data) -> Void)? { get set }
    /// The system stopped capture (an audio interruption: a call, Siri…).
    var onInterrupted: (@MainActor () -> Void)? { get set }
    func requestPermission() async -> Bool
    func start() throws
    func stop()
}

@MainActor
protocol GeminiLiveAudioOutput: AnyObject {
    var isPlaying: Bool { get }
    func play(_ pcm: Data, sampleRate: Double) throws
    /// Drop everything queued now (the user started speaking).
    func interrupt()
    func stop()
}

/// 16 kHz PCM16 microphone stream over the shared capture service.
@MainActor
final class CaptureServiceGeminiLiveInput: GeminiLiveAudioInput {
    private let capture: AVAudioCaptureService
    private var eventsTask: Task<Void, Never>?
    var onChunk: (@MainActor (Data) -> Void)? {
        didSet { capture.onPCM16Chunk = onChunk }
    }
    var onInterrupted: (@MainActor () -> Void)?

    init(capture: AVAudioCaptureService) {
        self.capture = capture
        // This capture instance belongs to Gemini Live alone. Its event
        // stream buffers every frame's level until read, so it is always
        // drained; interruptions are the events that matter here.
        let events = capture.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if case .interrupted(let generation) = event, generation == self.capture.captureGeneration {
                    self.onInterrupted?()
                }
            }
        }
    }

    deinit { eventsTask?.cancel() }

    func requestPermission() async -> Bool { await capture.requestPermission() }

    func start() throws {
        capture.onPCM16Chunk = onChunk
        // Monitoring mode runs the engine without accumulating an utterance:
        // every chunk is streamed and nothing is kept.
        try capture.beginBargeInMonitoring()
    }

    func stop() {
        capture.onPCM16Chunk = nil
        capture.stop()
    }
}

/// 24 kHz model speech over the shared playback service, joining the
/// capture-owned conversation audio session.
@MainActor
final class PlaybackServiceGeminiLiveOutput: GeminiLiveAudioOutput {
    private let playback: AVSpeechPlaybackService

    init(playback: AVSpeechPlaybackService) {
        self.playback = playback
        playback.ownershipIntent = .conversationPlayback
    }

    var isPlaying: Bool { playback.isPlaying }

    func play(_ pcm: Data, sampleRate: Double) throws {
        _ = try playback.enqueuePCM16(pcm, sampleRate: sampleRate)
    }

    func interrupt() { playback.stop() }
    func stop() { playback.stop() }
}

// MARK: - Controller

@MainActor
final class GeminiLiveConversationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case speaking
        case reconnecting
        case failed(String)
    }

    /// Instructions for the live model. Written for the model, not shown as
    /// UI copy, so not localized.
    static let systemInstruction = """
    You are the voice of the user's Hermes agent, speaking with them through the Conduit iPhone app. Keep replies short and conversational: this is speech, not text.
    Never speak while the user is speaking. If they interrupt you, stop and listen. If you have nothing useful to add, stay silent rather than filling the pause.
    Answer quick questions yourself. For weather, news, sports, prices, and other quick facts from the web, use Google Search and answer directly.
    Call start_job only for work that needs the user's Hermes agent: their files, code, systems, accounts, or longer multi-step research. Pass the complete task. Every time you call start_job, first say a very short acknowledgement out loud, like "On it, I'll have Hermes look into that." Then carry on with the conversation; the job runs on Hermes in the background.
    Do not comment on how a job is progressing unless the user asks; use list_jobs when they do. When a job's result arrives, tell the user the outcome once, in a few spoken sentences, when the conversation is quiet.
    Never approve, deny, or answer anything on a job's behalf. If a job needs input, tell the user to open it in Conduit.
    Use cancel_job only when the user asks to cancel.
    """

    /// Quiet time after the user's last recognized speech before Conduit
    /// sends a job update of its own.
    static let userQuietInterval: TimeInterval = 2
    /// Quiet time after the model's last turn before a job update.
    static let modelQuietInterval: TimeInterval = 1

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript: [VoiceConversationTranscriptEntry] = []
    @Published private(set) var isMicrophoneMuted = false

    var isActive: Bool {
        switch phase {
        case .idle, .failed: return false
        case .connecting, .listening, .speaking, .reconnecting: return true
        }
    }

    private let makeSession: @MainActor () -> GeminiLiveSessionControlling
    private let availability: @MainActor () async throws -> GeminiLiveAvailability
    private let tools: GeminiLiveToolBridge
    private let input: GeminiLiveAudioInput
    private let output: GeminiLiveAudioOutput
    private let now: () -> Date
    private let routePolicy: @MainActor () -> VoiceBargeInRoutePolicy

    /// After the model stops playing on an open speaker, the mic stays
    /// closed this long so the room's echo tail can't read as user speech.
    static let speakerEchoTail: TimeInterval = 0.35
    /// How long the model has to acknowledge a start_job out loud before
    /// Conduit prompts it to.
    static let acknowledgementGrace: TimeInterval = 1.5

    private var session: GeminiLiveSessionControlling?
    /// Set by the Interrupt button: the rest of the current model turn is
    /// dropped locally until the server ends or interrupts it.
    private var suppressingModelTurn = false
    private var lastPlaybackAt: Date?
    private var lastModelAudioAt: Date?
    private var inputRunning = false
    private var modelTurnActive = false
    private var lastUserSpeechAt: Date?
    private var lastModelTurnEndedAt: Date?
    private var pendingTextTurns: [String] = []
    private var idleFlushTask: Task<Void, Never>?
    private var openUserEntry: UUID?
    private var openAssistantEntry: UUID?

    init(
        makeSession: @escaping @MainActor () -> GeminiLiveSessionControlling,
        availability: @escaping @MainActor () async throws -> GeminiLiveAvailability,
        tools: GeminiLiveToolBridge,
        input: GeminiLiveAudioInput,
        output: GeminiLiveAudioOutput,
        now: @escaping () -> Date = Date.init,
        routePolicy: @escaping @MainActor () -> VoiceBargeInRoutePolicy = { VoiceBargeInRoutePolicy.current() }
    ) {
        self.makeSession = makeSession
        self.availability = availability
        self.tools = tools
        self.input = input
        self.output = output
        self.now = now
        self.routePolicy = routePolicy
    }

    /// The Interrupt button: stop the model now. On an open speaker this is
    /// how the user barges in, since the mic is closed while it speaks.
    func interruptSpeaking() {
        guard modelTurnActive || output.isPlaying else { return }
        output.interrupt()
        suppressingModelTurn = true
        modelTurnActive = false
        lastModelTurnEndedAt = now()
        lastPlaybackAt = nil
        openAssistantEntry = nil
        phase = .listening
    }

    // MARK: Lifecycle

    /// Checks the host, the microphone, then connects. Any refusal leaves
    /// the controller `.failed` with the reason; it never falls back to
    /// another voice mode on its own.
    func start() async {
        guard !isActive else { return }
        phase = .connecting
        transcript = []
        pendingTextTurns = []
        // Nothing from a previous attempt may gate or attach to this one.
        modelTurnActive = false
        suppressingModelTurn = false
        lastUserSpeechAt = nil
        lastModelTurnEndedAt = nil
        lastPlaybackAt = nil
        lastModelAudioAt = nil
        closeOpenEntries()
        do {
            let status = try await availability()
            guard phase == .connecting else { return }
            guard status.isAvailable else {
                phase = .failed(status.userFacingReason ?? AppLocalization.string("Gemini Live is not available on this Hermes server."))
                return
            }
        } catch {
            guard phase == .connecting else { return }
            phase = .failed(error.localizedDescription)
            return
        }
        guard await input.requestPermission() else {
            guard phase == .connecting else { return }
            phase = .failed(VoiceAudioError.microphonePermissionDenied.localizedDescription)
            return
        }
        guard phase == .connecting else { return }
        let session = makeSession()
        session.onEvent = { [weak self] in self?.handle($0) }
        session.onStateChange = { [weak self] in self?.sessionStateChanged($0) }
        session.onConnectionReplaced = { [weak self] in self?.tools.connectionReplaced() }
        self.session = session
        input.onChunk = { [weak self] chunk in self?.microphoneChunk(chunk) }
        input.onInterrupted = { [weak self] in self?.captureInterrupted() }
        session.start()
    }

    func stop() {
        idleFlushTask?.cancel()
        idleFlushTask = nil
        session?.stop()
        session = nil
        stopInput()
        input.onChunk = nil
        output.stop()
        modelTurnActive = false
        suppressingModelTurn = false
        lastPlaybackAt = nil
        lastModelAudioAt = nil
        pendingTextTurns = []
        tools.connectionReplaced()
        closeOpenEntries()
        phase = .idle
    }

    func setMicrophoneMuted(_ muted: Bool) {
        guard muted != isMicrophoneMuted else { return }
        isMicrophoneMuted = muted
        if muted {
            stopInput()
            // End the user's turn now instead of waiting for more audio.
            if session?.isReady == true { session?.send(GeminiLiveProtocol.audioStreamEndMessage()) }
        } else if session?.isReady == true {
            startInput()
        }
    }

    /// Background-job updates became pending (the supervisor's
    /// onNoticePending, routed here while this mode is active).
    func deliverPendingJobUpdates() {
        // Only on a live connection: settling an open call marks the job
        // announced, so it must never happen while nothing can be sent. The
        // updates stay pending and go out when the session is ready again.
        guard isActive, session?.isReady == true else { return }
        dispatch(tools.pendingUpdates())
    }

    /// An audio interruption stopped the microphone. Restart it once the
    /// system lets go; if it can't, say so instead of showing "Listening".
    private func captureInterrupted() {
        guard inputRunning else { return }
        inputRunning = false
        guard !isMicrophoneMuted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.isActive, !self.isMicrophoneMuted, self.session?.isReady == true else { return }
            self.startInput()
        }
    }

    // MARK: Session

    private func sessionStateChanged(_ state: GeminiLiveSession.State) {
        switch state {
        case .ready:
            if !isMicrophoneMuted { startInput() }
            phase = modelTurnActive ? .speaking : .listening
            // Anything that settled while (re)connecting goes out now.
            dispatch(tools.pendingUpdates())
            scheduleIdleFlush()
        case .reconnecting:
            phase = .reconnecting
            output.interrupt()
            modelTurnActive = false
        case .failed(let message):
            stopInput()
            output.stop()
            phase = .failed(message)
        case .connecting:
            phase = .connecting
        case .idle, .stopped:
            break
        }
    }

    private func handle(_ event: GeminiLiveProtocol.ServerEvent) {
        switch event {
        case .audio(let pcm, let sampleRate):
            guard !suppressingModelTurn else { return }
            modelTurnActive = true
            lastModelAudioAt = now()
            phase = .speaking
            do {
                try output.play(pcm, sampleRate: sampleRate)
            } catch {
                output.interrupt()
            }
        case .outputTranscription(let text):
            guard !suppressingModelTurn else { return }
            modelTurnActive = true
            appendTranscript(text, speaker: .assistant)
        case .inputTranscription(let text):
            lastUserSpeechAt = now()
            appendTranscript(text, speaker: .user)
        case .interrupted:
            // The user started speaking: the model must stop immediately.
            output.interrupt()
            suppressingModelTurn = false
            modelTurnActive = false
            lastModelTurnEndedAt = now()
            openAssistantEntry = nil
            phase = .listening
        case .turnComplete:
            suppressingModelTurn = false
            modelTurnActive = false
            lastModelTurnEndedAt = now()
            closeOpenEntries()
            phase = .listening
            scheduleIdleFlush()
        case .toolCall(let calls):
            for call in calls {
                Task { [weak self] in
                    guard let self else { return }
                    let calledAt = self.now()
                    let outgoing = await self.tools.handle(call)
                    self.dispatch(outgoing)
                    // An empty answer means a start_job is running: make
                    // sure the user heard that it was taken.
                    if call.name == GeminiLiveToolBridge.Tool.startJob.rawValue, outgoing.isEmpty {
                        self.ensureAcknowledgement(since: calledAt)
                    }
                }
            }
        case .toolCallCancellation(let ids):
            tools.cancelCalls(ids)
        case .setupComplete, .goAway, .resumptionUpdate:
            break
        }
    }

    private func microphoneChunk(_ chunk: Data) {
        guard !isMicrophoneMuted, let session, session.isReady else { return }
        guard !isMicrophoneGatedForSpeaker else { return }
        session.send(GeminiLiveProtocol.audioMessage(pcm16: chunk))
    }

    /// On an open speaker (no headset), the model's own voice reaches the
    /// microphone; streamed, it reads as the user barging in and the model
    /// interrupts itself in a loop. So the mic is held back while the model
    /// speaks and for a short echo tail — the same half duplex the classic
    /// Voice mode uses on the speaker. Headsets stay full duplex.
    var isMicrophoneGatedForSpeaker: Bool {
        guard routePolicy() == .speakerSafeHalfDuplex else { return false }
        if output.isPlaying {
            lastPlaybackAt = now()
            return true
        }
        if modelTurnActive, !suppressingModelTurn { return true }
        if let lastPlaybackAt, now().timeIntervalSince(lastPlaybackAt) < Self.speakerEchoTail { return true }
        return false
    }

    /// The model is told to acknowledge every start_job out loud. If it
    /// stayed silent (it sometimes does while a NON_BLOCKING call runs),
    /// prompt a one-line acknowledgement once the conversation is quiet.
    private func ensureAcknowledgement(since calledAt: Date) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.acknowledgementGrace))
            guard let self, self.isActive else { return }
            self.acknowledgeIfSilent(since: calledAt)
        }
    }

    func acknowledgeIfSilent(since calledAt: Date) {
        if let lastModelAudioAt, lastModelAudioAt >= calledAt { return }
        pendingTextTurns.insert(Self.acknowledgementPrompt, at: 0)
        scheduleIdleFlush()
        flushPendingTextIfIdle()
    }

    /// Not UI copy (written for the model), so not localized.
    static let acknowledgementPrompt = "[You just started a background job on Hermes for the user's last request. Acknowledge it out loud in a few words, like \"On it, Hermes is checking.\" Do not start another job.]"

    var lastModelAudioAtForTesting: Date? { lastModelAudioAt }

    // MARK: Outgoing

    private func dispatch(_ outgoing: [GeminiLiveToolBridge.Outgoing]) {
        for item in outgoing {
            switch item {
            case .toolResponse(_, _, let result, _) where session?.isReady != true:
                // The connection dropped while this was being prepared: the
                // call can't be answered any more, so the outcome is kept as
                // a text update rather than lost.
                if let text = Self.fallbackText(for: result) { pendingTextTurns.append(text) }
            case .toolResponse(let id, let name, let result, let scheduling):
                session?.send(GeminiLiveProtocol.toolResponseMessage(
                    id: id,
                    name: name,
                    result: result,
                    scheduling: scheduling
                ))
            case .textWhenIdle(let text):
                pendingTextTurns.append(text)
            }
        }
        if !pendingTextTurns.isEmpty { scheduleIdleFlush() }
    }

    /// Whether Conduit may start a turn of its own right now: connected,
    /// the model silent (and done playing), and the user quiet.
    var isConversationIdle: Bool {
        guard session?.isReady == true, !modelTurnActive, !output.isPlaying else { return false }
        let current = now()
        if let lastUserSpeechAt, current.timeIntervalSince(lastUserSpeechAt) < Self.userQuietInterval { return false }
        if let lastModelTurnEndedAt, current.timeIntervalSince(lastModelTurnEndedAt) < Self.modelQuietInterval { return false }
        return true
    }

    /// Sends at most one queued update, and only while idle; the model's
    /// reply to it ends a turn, which schedules the next check.
    func flushPendingTextIfIdle() {
        guard !pendingTextTurns.isEmpty, isConversationIdle, let session else { return }
        let text = pendingTextTurns.removeFirst()
        modelTurnActive = true
        session.send(GeminiLiveProtocol.textTurnMessage(text))
    }

    private func scheduleIdleFlush() {
        guard idleFlushTask == nil, !pendingTextTurns.isEmpty else { return }
        idleFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.flushPendingTextIfIdle()
                if self.pendingTextTurns.isEmpty || !self.isActive {
                    self.idleFlushTask = nil
                    return
                }
            }
        }
    }

    var pendingTextTurnCountForTesting: Int { pendingTextTurns.count }

    /// A job outcome that can no longer go back on its call, as a text turn.
    /// Nil for answers only meaningful to the call (list_jobs, errors).
    static func fallbackText(for result: [String: String]) -> String? {
        guard let title = result["title"], let status = result["status"] else { return nil }
        if let outcome = result["result"] {
            return VoiceBackgroundJobSupervisor.completionPrompt(title: title, result: outcome)
        }
        let detail = result["error"].map { " (\($0))" } ?? ""
        return GeminiLiveToolBridge.relayPrompt("The background job \"\(title)\" is \(status)\(detail).")
    }

    // MARK: Audio input

    private func startInput() {
        guard !inputRunning else { return }
        do {
            try input.start()
            inputRunning = true
        } catch {
            phase = .failed(error.localizedDescription)
            session?.stop()
        }
    }

    private func stopInput() {
        guard inputRunning else { return }
        input.stop()
        inputRunning = false
    }

    // MARK: Transcript

    private func appendTranscript(_ text: String, speaker: VoiceConversationTranscriptEntry.Speaker) {
        let openID = speaker == .user ? openUserEntry : openAssistantEntry
        if let openID, let index = transcript.firstIndex(where: { $0.id == openID }) {
            transcript[index].text += text
            return
        }
        let entry = VoiceConversationTranscriptEntry(speaker: speaker, text: text.trimmingCharacters(in: .whitespaces))
        transcript.append(entry)
        if speaker == .user {
            openUserEntry = entry.id
            // The user speaking starts a new exchange.
            openAssistantEntry = nil
        } else {
            openAssistantEntry = entry.id
            openUserEntry = nil
        }
    }

    private func closeOpenEntries() {
        openUserEntry = nil
        openAssistantEntry = nil
    }
}
