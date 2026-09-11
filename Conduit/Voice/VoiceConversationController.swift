//
//  VoiceConversationController.swift
//  Conduit
//

import Combine
import Foundation

@MainActor
final class VoiceConversationController: ObservableObject {
    struct Configuration: Equatable {
        /// Conservative acoustic barge-in threshold, unchanged from the
        /// legacy single VAD threshold. Listening-side speech detection no
        /// longer uses this value; it adapts via `speechDetector` instead.
        var bargeInActivityThreshold: Float = 0.075
        var trailingSilence: TimeInterval = 1.25
        var idleSilence: TimeInterval = 12
        var maximumUtterance: TimeInterval = 60
        var bargeInDuration: TimeInterval = 0.3
        var speechDetector = VoiceSpeechDetectorConstants()
    }

    @Published private(set) var state: VoiceConversationState = .idle
    @Published private(set) var latestTranscript = ""
    @Published private(set) var lastBargeInState: VoiceConversationState?
    @Published private(set) var isOutputMuted = false
    @Published private(set) var isMicrophonePaused = false
    /// Latest raw microphone input peak from the capture service. This is
    /// presentation state: it moves whenever audio reaches Conduit,
    /// regardless of whether the speech detector classifies it as speech,
    /// and returns to zero whenever capture is paused, stopped, suspended,
    /// or interrupted.
    @Published private(set) var microphoneLevel: Float = 0
    /// Publication clock for meter throttling: level events arrive at tap
    /// buffer rate (~50 Hz), far faster than any useful UI animation, and
    /// every @Published assignment re-renders observing surfaces.
    private var lastMeterPublication: Date?
    /// Automatic speaker-safe suspension while Hermes is audibly playing on
    /// a route whose output can feed the microphone. Deliberately separate
    /// from `isMicrophonePaused`: that flag is explicit user intent ("Microphone
    /// paused"), this one is Conduit protecting the barge-in detector from
    /// the assistant's own TTS and must never read as a user-selected pause.
    @Published private(set) var isPlaybackCaptureSuspended = false
    @Published private(set) var conversationTranscript: [VoiceConversationTranscriptEntry] = []
    private var preferences = VoiceProfilePreferences()

    let configuration: Configuration
    private let capture: AudioCaptureService
    private let playback: SpeechPlaybackService
    private let deviceTranscriber: DeviceSpeechTranscriptionService
    private var gateway: VoiceGatewayService?
    /// Decides whether acoustic barge-in is safe while Hermes speaks.
    /// Production reads the live AVAudioSession route; tests inject a fixed
    /// or mutable policy so route classification is deterministic.
    private let routePolicyProvider: @MainActor () -> VoiceBargeInRoutePolicy
    private let submit: @MainActor (String) async -> Bool
    private let interrupt: @MainActor () async -> Void
    /// Installed by AppState: the authoritative Voice Close teardown
    /// (persist mute → `endVoiceSession` → sheet dismissal). A spoken End
    /// Conversation phrase converges on it instead of a second teardown;
    /// nil falls back to the controller-owned `stop()`.
    private let endConversationRequest: (@MainActor () -> Void)?
    private var captureEventsTask: Task<Void, Never>?
    private var speechDeltas: [String] = []
    private var isDrainingSpeech = false
    private var speechStream: VoiceSpeechStream?
    private var assistantFinished = false
    private var receivedAssistantDelta = false
    private var utteranceStartedAt: Date?
    private var lastSpeechAt: Date?
    private var bargeInStartedAt: Date?
    private var isForegroundActive = true
    private var isVoiceSessionActive = false
    private var isAwaitingVoiceAssistant = false
    private var awaitedAssistantResponseStarted = false
    /// Every session id POSITIVELY confirmed to route this conversation's
    /// assistant stream: the id captured at `beginVoiceTurn` plus any runtime
    /// rebind admitted while the turn is live. Hermes events carry runtime
    /// routing ids, so raw equality with the captured id alone would silently
    /// drop the assistant's voice the moment a resume rebinds the runtime.
    private var expectedAssistantSessionIDs: Set<String> = []
    private var operationGeneration: UInt64 = 0
    private var utteranceTask: Task<Void, Never>?
    private var bargeInTask: Task<Void, Never>?
    private var speechDrainTask: Task<Void, Never>?
    private var speechDrainRevision: UInt64 = 0
    private var isProviderTestRunning = false
    private var activeAssistantTranscriptEntryID: UUID?
    /// Adaptive listening-side speech detector (issue #130). Acoustic
    /// barge-in does not use it; that path keeps the conservative fixed
    /// threshold in `configuration.bargeInActivityThreshold`.
    private var speechDetector: VoiceSpeechDetector

    init(
        capture: AudioCaptureService? = nil,
        playback: SpeechPlaybackService? = nil,
        deviceTranscriber: DeviceSpeechTranscriptionService? = nil,
        gateway: VoiceGatewayService? = nil,
        configuration: Configuration = Configuration(),
        routePolicyProvider: (@MainActor () -> VoiceBargeInRoutePolicy)? = nil,
        submit: @escaping @MainActor (String) async -> Bool,
        interrupt: @escaping @MainActor () async -> Void,
        onEndConversation: (@MainActor () -> Void)? = nil
    ) {
        let capture = capture ?? AVAudioCaptureService()
        self.capture = capture
        self.playback = playback ?? AVSpeechPlaybackService()
        self.deviceTranscriber = deviceTranscriber ?? AppleOnDeviceSpeechTranscriber()
        self.gateway = gateway
        self.configuration = configuration
        speechDetector = VoiceSpeechDetector(constants: configuration.speechDetector)
        // Built here (not as a default parameter value) so the live route
        // read stays in MainActor context, matching the capture default.
        if let routePolicyProvider {
            self.routePolicyProvider = routePolicyProvider
        } else {
            self.routePolicyProvider = { VoiceBargeInRoutePolicy.current() }
        }
        self.submit = submit
        self.interrupt = interrupt
        self.endConversationRequest = onEndConversation
        captureEventsTask = Task { [weak self, capture] in
            for await event in capture.events {
                guard !Task.isCancelled else { return }
                await self?.handleCaptureEvent(event)
            }
        }
    }

    deinit { captureEventsTask?.cancel() }

    /// Swaps the gateway for FUTURE operations only (pinned Option B
    /// semantics): an in-flight conversation keeps the gateway it captured at
    /// its operation boundaries, and the caller that replaces connection
    /// ownership must stop this controller first — the server-replacement
    /// boundary in `AppState.retireSpeechOperationsForServerReplacement`
    /// does. A plain swap is deliberately not an ownership change: capability
    /// refreshes install fresh-but-equivalent instances (same bridge, server,
    /// and profile) mid-conversation by design, so pointer inequality is not
    /// a signal that the old operation's server authority ended.
    func setGateway(_ gateway: VoiceGatewayService?) { self.gateway = gateway }

    /// Establishes explicit ownership of assistant events for one voice turn.
    /// UI integration should refresh this when a fresh session is created.
    func beginVoiceTurn(sessionID: String) {
        isVoiceSessionActive = true
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        expectedAssistantSessionIDs = [sessionID]
        conversationTranscript.removeAll(keepingCapacity: true)
        activeAssistantTranscriptEntryID = nil
    }

    /// Adds session ids an admitted resume positively rebound to this
    /// conversation while the voice turn is live (runtime-old → runtime-new).
    /// `ofConversationContaining` is the reconciled conversation's accepted
    /// id set: the extension only applies when the turn's captured ids
    /// POSITIVELY overlap it, so a reconcile belonging to a different
    /// conversation can never inject its runtime into this turn's ownership.
    /// Inactive sessions ignore the call: a fresh turn's capture starts from
    /// its own id only.
    func extendAssistantSessionIDs(
        _ sessionIDs: Set<String>,
        ofConversationContaining knownIDs: Set<String>
    ) {
        guard isVoiceSessionActive,
              !expectedAssistantSessionIDs.isEmpty,
              !expectedAssistantSessionIDs.isDisjoint(with: knownIDs) else { return }
        expectedAssistantSessionIDs.formUnion(sessionIDs.filter { !$0.isEmpty })
    }

    func endVoiceSession() { stop() }

    func setProfilePreferences(_ preferences: VoiceProfilePreferences) {
        self.preferences = preferences
        isOutputMuted = preferences.outputMuted
    }

    /// Whether a completed assistant response automatically opens the next
    /// listening turn. This is conversation continuation only — it does not
    /// control session lifetime, user pause, barge-in, or route policy.
    var isContinuousConversationEnabled: Bool {
        preferences.continuousConversation
    }

    /// Observability seam: the preference blob currently applied to the
    /// controller (mirrors the last `setProfilePreferences`), so hosts and
    /// tests can read back what a preference mutation path actually reapplied.
    var activePreferences: VoiceProfilePreferences {
        preferences
    }

    /// True while a voice session or provider test is armed or live — i.e.
    /// while voice audio ownership may exist or is being acquired — so
    /// audio-adjacent side features (response haptics) stand down.
    ///
    /// Deliberately does NOT key off `state != .idle`: a terminal
    /// `.failed("Audio was interrupted.")` has no live operation and must
    /// not suppress Core Haptics indefinitely. The explicit ownership flags
    /// cover every real ownership window: `startListening` raises
    /// `isVoiceSessionActive` before its permission await (arming window),
    /// all listening/thinking/speaking/muted/transcribing states occur with
    /// it raised, and provider tests raise `isProviderTestRunning`. A failed
    /// arming attempt keeps the flag until the session is stopped or
    /// re-armed — bounded by the voice sheet's lifetime and conservative in
    /// the safe direction.
    var hasLiveVoiceSession: Bool {
        isVoiceSessionActive || isProviderTestRunning
    }

    /// Observability seam: whether a gateway reference is currently installed.
    /// The server-replacement boundary clears this reference; tests pin the
    /// clearing through here because a stale gateway's failure mode (reaching
    /// the outgoing server's bridge) is behavioral and hard to observe.
    var isGatewayAttached: Bool { gateway != nil }

    func setForegroundActive(_ active: Bool) {
        isForegroundActive = active
        guard !active else { return }
        stop()
    }

    func requestOnDeviceTranscriptionPermissions() async -> VoiceProviderTestResult {
        guard isForegroundActive else {
            return .failure("Voice permissions can only be requested while Conduit is in the foreground.")
        }
        guard await capture.requestPermission() else {
            return .failure(VoiceAudioError.microphonePermissionDenied.localizedDescription)
        }
        guard await deviceTranscriber.requestPermission() else {
            return .failure("Speech Recognition permission is required for on-device transcription.")
        }
        return .success("On-device speech recognition is ready.")
    }

    func startListening(includePreRoll: Bool = false) async {
        guard isForegroundActive else { return }
        let generation = operationGeneration
        isVoiceSessionActive = true
        guard let gateway else { state = .failed("Voice is unavailable for this gateway."); return }
        _ = gateway // keeps the availability check explicit at the state edge.
        guard await capture.requestPermission() else {
            guard isCurrent(generation) else { return }
            state = .failed(VoiceAudioError.microphonePermissionDenied.localizedDescription)
            return
        }
        guard isCurrent(generation) else { return }
        do {
            try capture.startListening(includePreRoll: includePreRoll)
            // Defense in depth: capture must never end up live over audible
            // playback, whichever flag paused it.
            if isMicrophonePaused || isPlaybackCaptureSuspended { capture.pause() }
            // Fresh listening window: the detector must not inherit noise or
            // speech state from the previous one.
            speechDetector.reset()
            resetMicrophoneMeter()
            utteranceStartedAt = Date()
            lastSpeechAt = nil
            bargeInStartedAt = nil
            state = .listening
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func pauseMicrophone() {
        // Explicit user intent never discards the speaker-safety fact: while
        // the suspension flag survives, any later listen request during
        // audible playback still routes through the interrupt path instead
        // of resuming a live microphone over Hermes' voice. Presentation is
        // handled by the sheet, which shows the user-paused state whenever
        // `isMicrophonePaused` is set.
        capture.pause()
        speechDetector.reset()
        resetMicrophoneMeter()
        isMicrophonePaused = true
    }

    func resumeMicrophone() async {
        guard isForegroundActive else { return }
        if isPlaybackCaptureSuspended {
            // On a speaker-safe route there is no "listen while Hermes
            // speaks": a listen request during playback means interrupt.
            await interruptAssistantPlayback()
            return
        }
        if !isMicrophonePaused {
            switch state {
            case .idle, .failed:
                await startListening()
            default:
                break
            }
            return
        }
        guard isVoiceSessionActive else { return }
        do {
            try capture.resume()
            isMicrophonePaused = false
            // Pause is a real resource pause, so resume opens a fresh
            // listening window: speech timestamps from before the pause must
            // not immediately finish an utterance or idle-pause again, and
            // the detector must not inherit pre-pause noise/speech state.
            speechDetector.reset()
            utteranceStartedAt = Date()
            lastSpeechAt = nil
            bargeInStartedAt = nil
            // Listen from a settled continuous-OFF session: capture is live
            // again, so the state must not remain .idle.
            if state == .idle { state = .listening }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The speaker-safe manual override for when automatic playback
    /// suspension is active (the sheet's Interrupt control): stop playback,
    /// retire the in-flight assistant turn through the authoritative
    /// interruption seam, and open a fresh microphone window. Pre-roll is
    /// deliberately not reused — while Hermes spoke on an open speaker it
    /// may contain the assistant's own TTS.
    func interruptAssistantPlayback() async {
        guard isPlaybackCaptureSuspended else { return }
        cachedRoutePolicy = nil
        // Deliberately leaves lastBargeInState alone: that property records
        // acoustic barge-in provenance, and this path always lands in
        // .listening.
        let generation = operationGeneration
        playback.stop()
        cancelSpeechDrainAndStream()
        speechDeltas.removeAll()
        assistantFinished = false
        // The in-flight assistant response is intentionally interrupted; its
        // terminal event belongs to the retired turn, not the next one.
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        isPlaybackCaptureSuspended = false
        // The tap itself is an explicit request to speak now, so a pending
        // user pause ends with it.
        isMicrophonePaused = false
        await interrupt()
        // The interruption is a real re-entrant async boundary (Hermes
        // cancellation/recovery), and the sheet can close while it is in
        // flight — stop() then advances the generation and tears the session
        // down. The fence stops the stale continuation from resurrecting
        // capture (isCurrent also covers foreground loss and session teardown).
        guard isCurrent(generation) else { return }
        await startListening()
    }

    func stop() {
        operationGeneration &+= 1
        cachedRoutePolicy = nil
        utteranceTask?.cancel()
        utteranceTask = nil
        bargeInTask?.cancel()
        bargeInTask = nil
        cancelSpeechDrainAndStream()
        capture.stop()
        deviceTranscriber.cancel()
        playback.stop()
        speechDeltas.removeAll()
        assistantFinished = false
        isMicrophonePaused = false
        isPlaybackCaptureSuspended = false
        speechDetector.reset()
        resetMicrophoneMeter()
        isVoiceSessionActive = false
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        expectedAssistantSessionIDs = []
        state = .idle
    }

    func setOutputMuted(_ muted: Bool) {
        isOutputMuted = muted
        if muted {
            playback.stop()
            cancelSpeechDrainAndStream()
            speechDeltas.removeAll()
            if state == .speaking { state = .muted }
            endPlaybackCaptureSuspensionAfterMute()
        } else if state == .muted {
            state = .thinking
        }
    }

    /// Muting stops the audible playback that justified a playback capture
    /// suspension, so capture becomes live again for monitoring — unless the
    /// user explicitly paused it, which stays authoritative.
    private func endPlaybackCaptureSuspensionAfterMute() {
        guard isPlaybackCaptureSuspended else { return }
        isPlaybackCaptureSuspended = false
        guard !isMicrophonePaused, isVoiceSessionActive else { return }
        do {
            try capture.resume()
            beginBargeInMonitoring()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Records a short sample and transcribes it without creating a chat turn.
    /// This is used exclusively by profile settings to validate the configured
    /// Hermes provider end to end.
    func runTranscriptionTest(duration: TimeInterval = 4) async -> VoiceProviderTestResult {
        stop()
        guard isForegroundActive else {
            return .failure("Voice tests only run while Conduit is in the foreground.")
        }
        guard let gateway else {
            return .failure("Conduit could not connect this test to the selected profile.")
        }
        isVoiceSessionActive = true
        isProviderTestRunning = true
        let generation = operationGeneration
        defer {
            capture.stop()
            isProviderTestRunning = false
            // The test recording is over: the meter must not freeze at the
            // last captured level.
            resetMicrophoneMeter()
            if isCurrent(generation) { state = .idle }
            isVoiceSessionActive = false
        }
        guard await capture.requestPermission() else {
            return .failure(VoiceAudioError.microphonePermissionDenied.localizedDescription)
        }
        guard isCurrent(generation) else {
            return .failure("The speech-to-text test was cancelled.")
        }
        do {
            try capture.startListening(includePreRoll: false)
            state = .listening
            try await Task.sleep(for: .seconds(duration))
            guard isCurrent(generation) else {
                return .failure("The speech-to-text test was cancelled.")
            }
            let audio = try capture.finishUtterance()
            state = .transcribing
            // Recording is done: the settings meter must not freeze at the
            // last captured level while the provider transcribes.
            resetMicrophoneMeter()
            let transcript = try await transcribe(audio, gateway: gateway)
            guard isCurrent(generation) else {
                return .failure("The speech-to-text test was cancelled.")
            }
            guard !transcript.isEmpty else {
                return .failure("The selected speech-to-text provider returned an empty transcript.")
            }
            latestTranscript = transcript
            return .success("Transcribed: \(transcript)")
        } catch {
            if isCurrent(generation) { state = .failed(error.localizedDescription) }
            return .failure(error.localizedDescription)
        }
    }

    /// Speaks a fixed, non-chat phrase through the same streaming/fallback
    /// transport and playback services used by a conversation.
    func runSpeechTest(text: String) async -> VoiceProviderTestResult {
        stop()
        guard isForegroundActive else {
            return .failure("Voice tests only run while Conduit is in the foreground.")
        }
        guard let gateway else {
            return .failure("Conduit could not connect this test to the selected profile.")
        }
        isVoiceSessionActive = true
        isProviderTestRunning = true
        // The TTS provider test runs outside a voice conversation, so its
        // playback must claim standalone (output-only) session ownership.
        playback.ownershipIntent = .standalonePlayback
        let generation = operationGeneration
        defer {
            speechStream?.cancel()
            speechStream = nil
            playback.stop()
            isProviderTestRunning = false
            resetMicrophoneMeter()
            if isCurrent(generation) { state = .idle }
            isVoiceSessionActive = false
        }
        do {
            state = .thinking
            // The test passes only when the route actually delivered speech:
            // a stream that connects and finishes silently is a failed
            // provider test, not a passed one.
            var deliveredAudio = false
            let stream = try await gateway.openSpeechStream(
                onStart: { [weak self] rate in
                    guard let self else { return }
                    try self.playback.start(sampleRate: rate)
                    self.state = .speaking
                },
                onPCM16: { [weak self] data, rate in
                    guard let self else { return }
                    // Only PCM the playback service actually accepted and
                    // scheduled counts as delivered speech — an unaligned
                    // or empty chunk schedules zero bytes and must not
                    // turn the provider test into a false pass.
                    let acceptedBytes = try self.playback.enqueuePCM16(data, sampleRate: rate)
                    if acceptedBytes > 0 { deliveredAudio = true }
                },
                onEncodedAudio: { [weak self] data in
                    guard let self else { return }
                    // Mirror the PCM path: only audio that actually reaches
                    // playback counts as delivered, so an empty payload
                    // cannot turn the test into a false pass.
                    guard !data.isEmpty else { return }
                    try self.playback.playEncodedAudioData(data)
                    deliveredAudio = true
                    self.state = .speaking
                }
            )
            speechStream = stream
            try await stream.append(text)
            guard isCurrent(generation) else {
                return .failure("The speech playback test was cancelled.")
            }
            _ = try await stream.finish()
            guard isCurrent(generation) else {
                return .failure("The speech playback test was cancelled.")
            }
            try playback.finish()
            await playback.drain()
            guard isCurrent(generation) else {
                return .failure("The speech playback test was cancelled.")
            }
            guard deliveredAudio else {
                return .failure("Hermes connected, but the selected speech provider returned no audio.")
            }
            return .success("Speech playback completed.")
        } catch {
            if isCurrent(generation) { state = .failed(error.localizedDescription) }
            return .failure(error.localizedDescription)
        }
    }

    /// Public for deterministic state-machine tests and for capture services
    /// which coalesce level events differently on route changes.
    func ingestAudioLevel(_ level: Float, at date: Date = Date()) {
        switch state {
        case .listening:
            if utteranceStartedAt == nil { utteranceStartedAt = date }
            switch speechDetector.observe(level) {
            case .started, .continued: lastSpeechAt = date
            case .none: break
            }
            if let started = utteranceStartedAt, date.timeIntervalSince(started) >= configuration.maximumUtterance {
                scheduleFinishUtterance()
            } else if let speech = lastSpeechAt, date.timeIntervalSince(speech) >= configuration.trailingSilence {
                scheduleFinishUtterance()
            } else if lastSpeechAt == nil, let started = utteranceStartedAt,
                      date.timeIntervalSince(started) >= configuration.idleSilence {
                pauseMicrophone()
            }
        case .thinking, .speaking, .muted:
            // Speaker-safe suspension: while capture is suspended during
            // assistant playback, no acoustic barge-in may be scheduled —
            // even from a stale level event that slipped past the paused
            // tap.
            guard !isPlaybackCaptureSuspended else { break }
            if level >= configuration.bargeInActivityThreshold {
                if bargeInStartedAt == nil { bargeInStartedAt = date }
                if let started = bargeInStartedAt,
                   date.timeIntervalSince(started) >= configuration.bargeInDuration {
                    scheduleBargeIn()
                }
            } else {
                bargeInStartedAt = nil
            }
        default:
            break
        }
    }

    func receiveAssistantEvent(_ event: VoiceAssistantEvent) {
        let sessionID: String
        switch event {
        case .started(let id), .delta(let id, _), .completed(let id, _),
                .failed(let id, _), .interrupted(let id):
            sessionID = id
        }
        guard isVoiceSessionActive,
              isAwaitingVoiceAssistant,
              expectedAssistantSessionIDs.contains(sessionID) else { return }
        if case .idle = state { return }
        if case .failed = state { return }
        switch event {
        case .started:
            awaitedAssistantResponseStarted = true
            activeAssistantTranscriptEntryID = nil
            receivedAssistantDelta = false
            assistantFinished = false
            speechDeltas.removeAll()
            cancelSpeechDrainAndStream()
            if state == .thinking || state == .muted { beginBargeInMonitoring() }
        case .delta(_, let text):
            awaitedAssistantResponseStarted = true
            receivedAssistantDelta = true
            appendAssistantTranscriptDelta(text)
            guard !isOutputMuted else { return }
            speechDeltas.append(text)
            startSpeechDrainIfNeeded()
        case .completed(_, let content):
            // The gateway emits messageStart before a completion. Ignore a
            // late completion from the assistant turn we intentionally
            // interrupted while waiting for the next turn to begin.
            guard awaitedAssistantResponseStarted else { return }
            completeAssistantTranscript(content)
            // Hermes normally supplies both deltas and a final snapshot. The
            // final snapshot is a recovery value, not another utterance.
            if !receivedAssistantDelta, let content, !isOutputMuted { speechDeltas.append(content) }
            assistantFinished = true
            isAwaitingVoiceAssistant = false
            awaitedAssistantResponseStarted = false
            startSpeechDrainIfNeeded()
        case .failed(_, let message):
            // A barge-in can produce a terminal cancellation from the prior
            // assistant response after the next user turn has been submitted.
            // It has no message-start/delta for this newly awaited response,
            // so it must not fail the new voice turn.
            guard awaitedAssistantResponseStarted || !isCancellationMessage(message) else { return }
            isAwaitingVoiceAssistant = false
            awaitedAssistantResponseStarted = false
            state = .failed(message)
            playback.stop()
            cancelSpeechDrainAndStream()
            isPlaybackCaptureSuspended = false
        case .interrupted:
            guard awaitedAssistantResponseStarted else { return }
            isAwaitingVoiceAssistant = false
            awaitedAssistantResponseStarted = false
            playback.stop()
            cancelSpeechDrainAndStream()
            isPlaybackCaptureSuspended = false
            state = .idle
        }
    }

    private func handleCaptureEvent(_ event: VoiceCaptureEvent) {
        switch event {
        case .level(let level, let date, let generation):
            // Raw capture level always feeds the visible input meter —
            // including provider tests, where seeing "the microphone hears
            // me" distinguishes capture failure from detection failure —
            // while conversational VAD stays exclusive to the live Voice
            // Conversation. Publication is meter-resolution (~20 Hz), not
            // tap-buffer resolution: every assignment re-renders observing
            // surfaces.
            //
            // Generation identity first: a frame is valid only for the
            // input-tap generation that produced it, so queued frames from
            // a torn-down tap are rejected even when a new generation is
            // already live. Then defense in depth — logical capture state:
            // stale events must also not reach presentation or VAD during
            // a user pause, a #146 suspension, or after the voice session
            // ended. Provider tests are live capture and still count.
            guard generation == capture.captureGeneration else { return }
            let captureLive = !isMicrophonePaused
                && !isPlaybackCaptureSuspended
                && isVoiceSessionActive
            guard captureLive || isProviderTestRunning else { return }
            // A same-generation event can still surface after
            // finishUtterance() closed the turn: capture keeps running into
            // the transcription wait. The meter was reset for that state and
            // the UI hides it there, so republishing would only churn
            // @Published state.
            guard state != .transcribing else { return }
            if lastMeterPublication == nil || date.timeIntervalSince(lastMeterPublication!) >= 0.05 {
                microphoneLevel = level
                lastMeterPublication = date
            }
            guard !isProviderTestRunning else { return }
            ingestAudioLevel(level, at: date)
        case .interrupted:
            failForAudioInterruption()
        case .routeChanged:
            // Provider tests own the session exclusively; no capture is live
            // during the TTS test, so route-driven suspension would only
            // pollute speaker-safe state across the test boundary.
            guard !isProviderTestRunning else { return }
            // AVAudioEngine's tap remains valid across normal Bluetooth/wired
            // route changes. The next capture event re-establishes timing,
            // and a different microphone means a different noise floor.
            bargeInStartedAt = nil
            cachedRoutePolicy = nil
            if state == .listening { speechDetector.reset() }
            suspendIfRouteBecameOpenSpeaker()
        }
    }

    /// Zeroes the visible meter and clears the publication clock so the
    /// first event of a fresh capture window always publishes.
    private func resetMicrophoneMeter() {
        microphoneLevel = 0
        lastMeterPublication = nil
    }

    /// Safety net for routes that change while Hermes is audibly speaking:
    /// moving onto an open speaker must never leave live acoustic barge-in
    /// running. Moving onto a headset mid-utterance stays conservative — the
    /// suspension holds until the next playback boundary.
    private func suspendIfRouteBecameOpenSpeaker() {
        guard currentRoutePolicy() == .speakerSafeHalfDuplex else { return }
        guard state == .speaking || isPlaybackCaptureSuspended else { return }
        suspendCaptureForPlayback()
    }

    private func scheduleFinishUtterance() {
        guard utteranceTask == nil else { return }
        let generation = operationGeneration
        utteranceTask = Task { [weak self] in
            await self?.finishUtterance(generation: generation)
        }
    }

    private func finishUtterance(generation: UInt64) async {
        defer { if operationGeneration == generation { utteranceTask = nil } }
        guard state == .listening, let gateway else { return }
        do {
            let audio = try capture.finishUtterance()
            state = .transcribing
            // Utterance complete: the meter follows the now-inactive capture
            // and the detector must not carry this turn's noise/speech state
            // into the next one.
            resetMicrophoneMeter()
            speechDetector.reset()
            let transcript = try await transcribe(audio, gateway: gateway)
            guard isCurrent(generation) else { return }
            latestTranscript = transcript
            if transcript.isEmpty {
                await startListening()
                return
            }
            // Command boundary: spoken commands are recognized only on the
            // existing transcription completion path, never during raw
            // capture. End Conversation is checked first so a phrase present
            // in both lists deterministically takes the stronger action.
            if isWholeUtteranceEndConversationCommand(transcript) {
                await endConversationForSpokenCommand()
                return
            }
            conversationTranscript.append(
                VoiceConversationTranscriptEntry(speaker: .user, text: transcript)
            )
            if isWholeUtteranceStopCommand(transcript) {
                await interrupt()
                guard isCurrent(generation) else { return }
                playback.stop()
                await startListening()
                return
            }
            state = .thinking
            beginBargeInMonitoring()
            // Completion clears ownership for the previous response. Arm the
            // same authoritative session again immediately before each new
            // voice submission so continuous conversation accepts its reply.
            isAwaitingVoiceAssistant = true
            awaitedAssistantResponseStarted = false
            guard await submit(transcript) else {
                guard isCurrent(generation) else { return }
                isAwaitingVoiceAssistant = false
                state = .failed("Hermes could not submit the transcription.")
                return
            }
            guard isCurrent(generation) else { return }
        } catch is CancellationError {
            if isCurrent(generation) { state = .idle }
        } catch {
            if isCurrent(generation) { state = .failed(error.localizedDescription) }
        }
    }

    private func transcribe(_ audio: VoiceCapturedAudio, gateway: VoiceGatewayService) async throws -> String {
        switch preferences.resolvedTranscriptionMode {
        case .hermes:
            return try await gateway.transcribe(audio)
        case .appleOnDevice:
            return try await deviceTranscriber.transcribe(audio)
        }
    }

    private func beginBargeInMonitoring() {
        // Seam-level invariant: no barge-in monitoring affordance while a
        // playback suspension is active, so a future capture service cannot
        // reintroduce the feedback loop one layer down.
        guard !isPlaybackCaptureSuspended else { return }
        do {
            try capture.beginBargeInMonitoring()
            if isMicrophonePaused { capture.pause() }
        }
        catch { state = .failed(error.localizedDescription) }
    }

    /// Hermes begins audible playback. On routes where the output can feed
    /// the microphone, capture is suspended so the assistant's own TTS can
    /// never enter the level detector, pre-roll, or transcription input.
    /// Isolated headset routes keep live barge-in monitoring.
    private func applyPlaybackCapturePolicy() {
        // Fast path for the per-encoded-chunk callback: once suspended, the
        // policy can only flip back at a playback boundary.
        guard !isPlaybackCaptureSuspended else { return }
        if currentRoutePolicy() == .speakerSafeHalfDuplex {
            suspendCaptureForPlayback()
        } else {
            beginBargeInMonitoring()
        }
    }

    /// Route classification cached between capture `.routeChanged` events:
    /// `AVAudioSession.currentRoute` materializes port descriptions, which
    /// is too expensive to repeat on every encoded-audio chunk.
    private var cachedRoutePolicy: VoiceBargeInRoutePolicy?

    private func currentRoutePolicy() -> VoiceBargeInRoutePolicy {
        if let cachedRoutePolicy { return cachedRoutePolicy }
        let policy = routePolicyProvider()
        cachedRoutePolicy = policy
        return policy
    }

    /// Tears microphone rendering down for the duration of assistant
    /// playback. Uses the real resource pause (tap, engine, converter, and
    /// capture session lease all go away) without touching the explicit
    /// user-pause flag, and freezes barge-in timing so playback audio that
    /// leaked in before the suspension cannot half-schedule a barge-in.
    private func suspendCaptureForPlayback() {
        // A barge-in scheduled just before audible playback (or before a
        // route change) must not fire after suspension: it would stop
        // playback and reopen capture with speaker-contaminated pre-roll.
        bargeInTask?.cancel()
        bargeInTask = nil
        guard !isPlaybackCaptureSuspended else { return }
        isPlaybackCaptureSuspended = true
        bargeInStartedAt = nil
        // Capture is torn down for the duration of playback: the meter must
        // read zero (not frozen) and the detector must not carry state into
        // the next listening window.
        speechDetector.reset()
        resetMicrophoneMeter()
        capture.pause()
    }

    private func failForAudioInterruption() {
        operationGeneration &+= 1
        cachedRoutePolicy = nil
        utteranceTask?.cancel()
        utteranceTask = nil
        bargeInTask?.cancel()
        bargeInTask = nil
        cancelSpeechDrainAndStream()
        capture.stop()
        deviceTranscriber.cancel()
        playback.stop()
        speechDeltas.removeAll()
        assistantFinished = false
        isMicrophonePaused = false
        isPlaybackCaptureSuspended = false
        speechDetector.reset()
        resetMicrophoneMeter()
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        // Terminal path: release session-ownership bookkeeping so audio-
        // adjacent side features (response haptics) do not stand down
        // forever after an interruption.
        isVoiceSessionActive = false
        state = .failed("Audio was interrupted.")
    }

    private func scheduleBargeIn() {
        guard bargeInTask == nil else { return }
        let generation = operationGeneration
        bargeInTask = Task { [weak self] in
            await self?.beginBargeIn(generation: generation)
        }
    }

    private func beginBargeIn(generation: UInt64) async {
        // A cancelled task must neither act nor stomp a successor's handle.
        defer {
            if operationGeneration == generation, !Task.isCancelled { bargeInTask = nil }
        }
        // Cancellation is binding before the destructive prefix: a barge-in
        // that lost the race to a playback suspension must not stop the
        // playback or retire the turn it is supposed to protect.
        guard !Task.isCancelled else { return }
        guard !isPlaybackCaptureSuspended else { return }
        guard state == .thinking || state == .speaking || state == .muted else { return }
        lastBargeInState = state
        playback.stop()
        cancelSpeechDrainAndStream()
        speechDeltas.removeAll()
        assistantFinished = false
        // The in-flight assistant response is intentionally being interrupted.
        // Its terminal event belongs to the retired turn, not the next one.
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        await interrupt()
        // Cancellation is re-checked after the await: the suspension may have
        // engaged while the interruption was in flight, and reopening capture
        // now would hear the assistant's own speaker output.
        guard !Task.isCancelled else { return }
        guard isCurrent(generation) else { return }
        guard !isPlaybackCaptureSuspended else { return }
        await startListening(includePreRoll: true)
    }

    /// A spoken End Conversation phrase consumed the utterance locally: the
    /// session closes through the same effective teardown as the sheet's
    /// Close action — AppState installs that path here (persist mute →
    /// `endVoiceSession` → sheet dismissal); the fallback covers callers
    /// without the seam. This runs regardless of `continuousConversation`
    /// and is never followed by a relisten.
    ///
    /// Closing FIRST fences every stale continuation (the teardown bumps
    /// the operation generation and cancels the in-flight tasks) before the
    /// interrupt await, so a completion racing the Hermes cancellation
    /// cannot reopen capture or playback. One self-interaction needs care:
    /// this method runs INSIDE `utteranceTask`, and the teardown's
    /// `utteranceTask?.cancel()` would mark the current task cancelled —
    /// `HermesClient.rpc` throws `CancellationError` for cancelled tasks,
    /// which would abort the turn-cancel below exactly when there is a live
    /// Hermes turn to cancel. Clearing the handle first makes that cancel a
    /// no-op; the task ends on its own right after.
    private func endConversationForSpokenCommand() async {
        utteranceTask = nil
        if let endConversationRequest {
            endConversationRequest()
        } else {
            stop()
        }
        await interrupt()
    }

    private func isWholeUtteranceEndConversationCommand(_ transcript: String) -> Bool {
        VoiceSpokenCommands.matches(transcript, phrases: preferences.spokenEndConversationPhrases)
    }

    private func isWholeUtteranceStopCommand(_ transcript: String) -> Bool {
        VoiceSpokenCommands.matches(transcript, phrases: preferences.spokenStopPhrases)
    }

    private func appendAssistantTranscriptDelta(_ text: String) {
        guard !text.isEmpty else { return }
        if let id = activeAssistantTranscriptEntryID,
           let index = conversationTranscript.firstIndex(where: { $0.id == id }) {
            conversationTranscript[index].text += text
            return
        }
        let entry = VoiceConversationTranscriptEntry(speaker: .assistant, text: text)
        activeAssistantTranscriptEntryID = entry.id
        conversationTranscript.append(entry)
    }

    private func completeAssistantTranscript(_ content: String?) {
        if let content, !content.isEmpty {
            if let id = activeAssistantTranscriptEntryID,
               let index = conversationTranscript.firstIndex(where: { $0.id == id }) {
                conversationTranscript[index].text = content
            } else {
                let entry = VoiceConversationTranscriptEntry(speaker: .assistant, text: content)
                conversationTranscript.append(entry)
            }
        }
        activeAssistantTranscriptEntryID = nil
    }

    private func startSpeechDrainIfNeeded() {
        guard !isDrainingSpeech else { return }
        isDrainingSpeech = true
        let operation = operationGeneration
        let revision = speechDrainRevision
        speechDrainTask = Task { [weak self] in
            await self?.drainSpeechQueue(operation: operation, revision: revision)
        }
    }

    private func drainSpeechQueue(operation: UInt64, revision: UInt64) async {
        defer {
            if isSpeechDrainCurrent(operation: operation, revision: revision) {
                isDrainingSpeech = false
                speechDrainTask = nil
            }
        }
        do {
            guard isSpeechDrainCurrent(operation: operation, revision: revision), let gateway else { return }
            if speechStream == nil && !speechDeltas.isEmpty {
                // Assistant speech during a live voice conversation joins the
                // capture-owned session instead of reconfiguring it.
                playback.ownershipIntent = .conversationPlayback
                let openedStream = try await gateway.openSpeechStream(
                    onStart: { [weak self] rate in
                        guard let self,
                              self.isSpeechDrainCurrent(operation: operation, revision: revision),
                              !self.isOutputMuted else { return }
                        try self.playback.start(sampleRate: rate)
                        self.state = .speaking
                        self.applyPlaybackCapturePolicy()
                    },
                    onPCM16: { [weak self] data, rate in
                        guard let self,
                              self.isSpeechDrainCurrent(operation: operation, revision: revision),
                              !self.isOutputMuted else { return }
                        _ = try self.playback.enqueuePCM16(data, sampleRate: rate)
                    },
                    onEncodedAudio: { [weak self] data in
                        guard let self,
                              self.isSpeechDrainCurrent(operation: operation, revision: revision),
                              !self.isOutputMuted else { return }
                        try self.playback.playEncodedAudioData(data)
                        self.state = .speaking
                        self.applyPlaybackCapturePolicy()
                    }
                )
                guard isSpeechDrainCurrent(operation: operation, revision: revision) else {
                    openedStream.cancel()
                    return
                }
                speechStream = openedStream
            }
            while !speechDeltas.isEmpty, let speechStream, !isOutputMuted {
                try await speechStream.append(speechDeltas.removeFirst())
                guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
            }
            if assistantFinished, let speechStream {
                _ = try await speechStream.finish()
                guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
                try playback.finish()
                await playback.drain()
                guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
                self.speechStream = nil
            }
        } catch {
            guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
            if isSpeechCancellation(error) {
                speechStream = nil
                if assistantFinished {
                    assistantFinished = false
                    // Speaker-safe: a suspended capture must not resume
                    // while the cancelled stream's already-scheduled audio
                    // still renders out of the speaker.
                    if isPlaybackCaptureSuspended { playback.stop() }
                    isPlaybackCaptureSuspended = false
                    await startListening()
                }
                return
            }
            // Terminal drain failure: settle playback like every other
            // terminal path so the lease and engine do not outlive the turn.
            // (The cancellation branch above intentionally keeps ownership —
            // an interrupted stream's already-scheduled audio renders out.)
            playback.stop()
            isPlaybackCaptureSuspended = false
            if state == .speaking || state == .thinking { state = .failed(error.localizedDescription) }
            return
        }
        if assistantFinished && speechDeltas.isEmpty && speechStream == nil {
            assistantFinished = false
            guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
            // Conversation continuation only. Safety/recovery restarts
            // (barge-in, manual Interrupt, empty transcript, spoken stop,
            // stream cancellation after the assistant finished) always
            // re-listen and are intentionally not gated here.
            if preferences.continuousConversation {
                cachedRoutePolicy = nil
                isPlaybackCaptureSuspended = false
                await startListening()
            } else {
                settleOpenSessionAfterAssistantTurn()
            }
        }
    }

    /// Continuous conversation OFF: leave the voice session/sheet open after
    /// a completed assistant turn without opening the next listening window.
    /// Capture is paused without the user-pause flag so the sheet's Listen
    /// control remains "start the next turn", not "unpause".
    private func settleOpenSessionAfterAssistantTurn() {
        cachedRoutePolicy = nil
        isPlaybackCaptureSuspended = false
        // Full-duplex routes keep capture live through TTS for barge-in.
        if !isMicrophonePaused {
            capture.pause()
        }
        speechDetector.reset()
        resetMicrophoneMeter()
        state = .idle
    }

    private func cancelSpeechDrainAndStream() {
        speechDrainRevision &+= 1
        let task = speechDrainTask
        let stream = speechStream
        speechDrainTask = nil
        speechStream = nil
        isDrainingSpeech = false
        task?.cancel()
        stream?.cancel()
    }

    private func isSpeechDrainCurrent(operation: UInt64, revision: UInt64) -> Bool {
        isCurrent(operation) && revision == speechDrainRevision
    }

    private func isSpeechCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func isCancellationMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("cancelled") || normalized.contains("canceled")
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration && isForegroundActive && isVoiceSessionActive
    }
}
