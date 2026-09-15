//
//  VoiceTestSupport.swift
//  Conduit
//
//  Shared deterministic harness for the Voice/CarPlay/AppState test suites.
//
//  Convention: tests never wait on the clock. Every asynchronous hop the
//  production code takes (capture-event pump, utterance task, speech drain,
//  barge-in task) is observed through an explicit signal:
//
//  - `AwaitableCounter` — "the Nth submission/transcription/stream-open has
//    happened" (its `waitUntil` timeout is a deadlock guard only; on expiry
//    the test's own assertions fail with real state — it is never the
//    synchronization mechanism).
//  - `SubmitSpy.waitUntilSubmitted(_:)` — the utterance pipeline submitted.
//  - `MockGateway.waitUntilTranscriptionStarted/ SpeechStreamOpened/
//    SpeechAppended` — the transcription/speech path reached the fake.
//  - `MockCapture.waitUntilStartCount(_:)` — a capture window opened.
//  - `VoiceConversationController.waitForState(...)` and friends — a
//    @Published value transitioned (Combine-driven, no polling).
//  - `GatedTranscriptionGateway` / `InterruptParkingGate` / `ControlledSuspension` /
//    `MockPlayback.drainGate` — parked operations the test releases by hand.
//
//  Negative assertions ("this event must never arrive") cannot wait on an
//  event; they prove the pipeline was drained with `drainPendingMainActorWork()`
//  (or a positive control) and then assert nothing changed.
//

import Combine
import XCTest
@testable import Conduit

// MARK: - Awaitable counting gate

/// A MainActor counting gate. `increment()` releases every waiter whose
/// target has been reached; `waitUntil(_:timeout:)` returns immediately when
/// the count already satisfies the target, so the signal cannot be missed
/// regardless of scheduling order (both sides are MainActor). The timeout is
/// a deadlock guard: on expiry the waiter returns and the surrounding
/// assertions report the miss with real state instead of hanging the lane.
@MainActor
final class AwaitableCounter {
    private(set) var value: Int
    private var waiters: [WaiterBox] = []

    private final class WaiterBox {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
        var timeoutTask: Task<Void, Never>?
        var isResumed = false

        init(target: Int, continuation: CheckedContinuation<Void, Never>) {
            self.target = target
            self.continuation = continuation
        }
    }

    init(initial: Int = 0) { value = initial }

    func increment() {
        value += 1
        releaseReachedWaiters()
    }

    private func releaseReachedWaiters() {
        var stillWaiting: [WaiterBox] = []
        for waiter in waiters {
            if value >= waiter.target {
                finish(waiter)
            } else {
                stillWaiting.append(waiter)
            }
        }
        waiters = stillWaiting
    }

    func waitUntil(_ target: Int, timeout: TimeInterval = 10) async {
        guard value < target else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = WaiterBox(target: target, continuation: continuation)
            waiters.append(waiter)
            waiter.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                self.expire(waiter)
            }
        }
    }

    private func finish(_ waiter: WaiterBox) {
        guard !waiter.isResumed else { return }
        waiter.isResumed = true
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume()
    }

    private func expire(_ waiter: WaiterBox) {
        guard !waiter.isResumed else { return }
        waiters.removeAll { $0 === waiter }
        waiter.isResumed = true
        waiter.continuation.resume()
    }
}

// MARK: - Submit seam

/// Awaitable submit seam: the controller's `submit` closure records every
/// transcription submission here, so tests await the utterance pipeline's
/// actual completion instead of a settling sleep.
@MainActor
final class SubmitSpy {
    private(set) var texts: [String] = []
    private let submissions = AwaitableCounter()
    /// Toggle for tests that exercise a failing submission.
    var succeeds = true

    var count: Int { submissions.value }

    func submit(_ text: String) async -> Bool {
        texts.append(text)
        submissions.increment()
        return succeeds
    }

    func waitUntilSubmitted(_ count: Int, timeout: TimeInterval = 10) async {
        await submissions.waitUntil(count, timeout: timeout)
    }
}

// MARK: - Published-value waits

/// Awaits a `@Published` value that satisfies `predicate`. The publisher's
/// emissions ARE the synchronization events — no polling, no wall-clock
/// settling. Returns immediately when the current value already satisfies
/// the predicate, so the signal cannot be missed. The timeout is a deadlock
/// guard: on expiry the call returns false and the test's assertions report
/// the actual value.
///
/// MainActor-only: production writes to these properties happen on the
/// MainActor, so the Combine sink fires there (asserted via
/// `MainActor.assumeIsolated`).
@MainActor
func awaitPublishedValue<Value>(
    _ publisher: Published<Value>.Publisher,
    initialValue: Value,
    where predicate: @escaping (Value) -> Bool,
    timeout: TimeInterval = 5
) async -> Bool {
    if predicate(initialValue) { return true }
    let waiter = PublishedValueWaiter(publisher: publisher, predicate: predicate)
    return await waiter.wait(timeout: timeout)
}

private final class PublishedValueWaiter<Value> {
    private let publisher: Published<Value>.Publisher
    private let predicate: (Value) -> Bool
    private var cancellable: AnyCancellable?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(publisher: Published<Value>.Publisher, predicate: @escaping (Value) -> Bool) {
        self.publisher = publisher
        self.predicate = predicate
    }

    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            // withCheckedContinuation runs its body before suspending, so
            // the subscription is installed before any production task can
            // run — no missed event.
            self.continuation = continuation
            self.cancellable = self.publisher.sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.receive(value)
                }
            }
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(returning: false)
            }
        }
    }

    @MainActor
    private func receive(_ value: Value) {
        guard predicate(value) else { return }
        finish(returning: true)
    }

    @MainActor
    private func finish(returning result: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        cancellable?.cancel()
        timeoutTask?.cancel()
        continuation.resume(returning: result)
    }
}

@MainActor
extension VoiceConversationController {
    /// Awaits the published conversation `state` reaching `target`.
    func waitForState(_ target: VoiceConversationState, timeout: TimeInterval = 5) async -> Bool {
        await awaitPublishedValue($state, initialValue: state, where: { $0 == target }, timeout: timeout)
    }

    /// Awaits any `.failed(message)` state (the message is asserted separately).
    func waitForFailedState(timeout: TimeInterval = 5) async -> Bool {
        await awaitPublishedValue($state, initialValue: state, where: { state in
            if case .failed = state { return true }
            return false
        }, timeout: timeout)
    }

    /// Awaits the published microphone meter satisfying `predicate`.
    func waitForMicrophoneLevel(
        where predicate: @escaping (Float) -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        await awaitPublishedValue($microphoneLevel, initialValue: microphoneLevel, where: predicate, timeout: timeout)
    }

    /// Awaits the speaker-safe playback capture suspension flag.
    func waitForPlaybackCaptureSuspension(_ suspended: Bool, timeout: TimeInterval = 5) async -> Bool {
        await awaitPublishedValue(
            $isPlaybackCaptureSuspended,
            initialValue: isPlaybackCaptureSuspended,
            where: { $0 == suspended },
            timeout: timeout
        )
    }
}

// MARK: - Negative-assertion drain

/// Bounded MainActor drain for NEGATIVE assertions: after yielding buffered
/// capture events (or parking/releasing a gate), a generous yield budget lets
/// every already-enqueued MainActor job — the capture-event pump, a cancelled
/// utterance task — finish before the test asserts that nothing changed.
/// There is no wall clock involved: a loaded runner cannot under-drain these
/// because each `Task.yield()` re-enqueues the test BEHIND the pending work.
/// Never use this to wait for a positive event — wait for that event.
@MainActor
func drainPendingMainActorWork(budget: Int = 50) async {
    for _ in 0..<budget {
        await Task.yield()
    }
}

// MARK: - Capture double

@MainActor
final class MockCapture: AudioCaptureService {
    let events: AsyncStream<VoiceCaptureEvent>
    /// Mirrors the production service: bumped on every lifecycle boundary
    /// (start/pause/resume/stop) so generation-tagged events can be tested.
    var captureGeneration: UInt64 = 0
    private var continuation: AsyncStream<VoiceCaptureEvent>.Continuation?
    private let permissionGranted: Bool
    private let startError: Error?
    var didStart = false
    var didBeginMonitoring = false
    var didPause = false
    private var mockPaused = false
    private(set) var lastStartIncludePreRoll: Bool?
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var finishUtteranceCount = 0
    private let starts = AwaitableCounter()

    var startCount: Int { starts.value }

    init(permissionGranted: Bool, startError: Error? = nil) {
        self.permissionGranted = permissionGranted
        self.startError = startError
        var captured: AsyncStream<VoiceCaptureEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured
    }
    func requestPermission() async -> Bool { permissionGranted }
    func startListening(includePreRoll: Bool) throws {
        didStart = true
        lastStartIncludePreRoll = includePreRoll
        mockPaused = false
        captureGeneration &+= 1
        starts.increment()
        if let startError { throw startError }
    }
    /// Awaits a capture window opening (fresh listen or recapture).
    func waitUntilStartCount(_ count: Int, timeout: TimeInterval = 10) async {
        await starts.waitUntil(count, timeout: timeout)
    }
    func beginBargeInMonitoring() throws { didBeginMonitoring = true }
    func pause() {
        didPause = true
        // The real service is idempotent (guard !paused); keep counts honest.
        guard !mockPaused else { return }
        mockPaused = true
        pauseCount += 1
        captureGeneration &+= 1
    }
    func resume() throws {
        mockPaused = false
        resumeCount += 1
        captureGeneration &+= 1
    }
    func finishUtterance() throws -> VoiceCapturedAudio {
        finishUtteranceCount += 1
        return VoiceCapturedAudio(wavData: Data([1]), pcm16Data: Data([1, 0]), sampleRate: 16_000, duration: 0.01)
    }
    func stop() {
        mockPaused = false
        stopCount += 1
        captureGeneration &+= 1
    }
    func emit(_ event: VoiceCaptureEvent) { continuation?.yield(event) }
    /// Emits a level event stamped with the current capture generation —
    /// the normal path for live frames.
    func emit(level: Float, at date: Date = Date()) {
        continuation?.yield(.level(level, date: date, generation: captureGeneration))
    }
    func emitInterrupted(generation: UInt64? = nil) {
        continuation?.yield(.interrupted(generation: generation ?? captureGeneration))
    }
}

// MARK: - Playback double

@MainActor
final class MockPlayback: SpeechPlaybackService {
    var isPlaying = false
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    /// When set, `drain()` parks until the gate is released, so tests can
    /// hold a playback operation open deterministically.
    var drainGate: InterruptParkingGate?
    /// Invoked from `stop()` so tests can count real playback teardowns.
    var onStop: (() -> Void)?
    /// The ownership intent in force when playback last started, so tests can
    /// assert which session policy a flow claimed.
    private(set) var intentAtLastStart: VoiceAudioIntent?
    func start(sampleRate: Double) throws {
        intentAtLastStart = ownershipIntent
        isPlaying = true
    }
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int { data.count - (data.count % 2) }
    func playEncodedAudioData(_ data: Data) throws {
        intentAtLastStart = ownershipIntent
        isPlaying = true
    }
    func finish() throws {}
    func drain() async {
        isPlaying = false
        await drainGate?.waitInInterrupt()
    }
    func stop() {
        isPlaying = false
        onStop?()
    }
}

// MARK: - Gateway double

@MainActor
final class MockGateway: VoiceGatewayService {
    let profile = "default"
    /// Mutable so multi-phase tests can pin what the recognizer returns
    /// per phase (normal turn, spoken command, follow-up).
    var transcript: String
    /// Invoked after each speech stream opens (before the call returns).
    var onStreamOpen: (() -> Void)?
    let startsPlaybackOnOpen: Bool
    /// When true, the FIRST opened stream parks inside its first `append`.
    let blocksFirstStreamAppend: Bool
    /// When true, opening a stream immediately delivers one PCM chunk (and
    /// the matching start control), mirroring a streaming provider that is
    /// actually producing speech.
    let deliversPCM: Bool
    /// When true, opening a stream immediately delivers whole-file encoded
    /// audio, mirroring the whole-file fallback route.
    let deliversEncodedAudio: Bool
    /// When true, opening a stream delivers a single unaligned PCM byte:
    /// the playback service accepts zero bytes, so nothing was actually
    /// scheduled for playback.
    let deliversPartialPCM: Bool
    private(set) var openCount = 0
    private(set) var stream: MockSpeechStream?
    private(set) var streams: [MockSpeechStream] = []

    private let transcriptions: AwaitableCounter
    private let streamOpens: AwaitableCounter
    private let appends: AwaitableCounter

    var transcriptionCount: Int { transcriptions.value }

    init(
        transcript: String = "test",
        startsPlaybackOnOpen: Bool = false,
        blocksFirstStreamAppend: Bool = false,
        deliversPCM: Bool = false,
        deliversEncodedAudio: Bool = false,
        deliversPartialPCM: Bool = false
    ) {
        self.transcript = transcript
        self.startsPlaybackOnOpen = startsPlaybackOnOpen
        self.blocksFirstStreamAppend = blocksFirstStreamAppend
        self.deliversPCM = deliversPCM
        self.deliversEncodedAudio = deliversEncodedAudio
        self.deliversPartialPCM = deliversPartialPCM
        transcriptions = AwaitableCounter()
        streamOpens = AwaitableCounter()
        appends = AwaitableCounter()
    }

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        transcriptions.increment()
        return transcript
    }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        openCount += 1
        if startsPlaybackOnOpen || deliversPCM || deliversEncodedAudio || deliversPartialPCM { try onStart(24_000) }
        if deliversPCM { try onPCM16(Data([0x01, 0x00, 0x02, 0x00]), 24_000) }
        if deliversEncodedAudio { try onEncodedAudio(Data([0xFF, 0xF3, 0x40, 0xC4])) }
        if deliversPartialPCM { try onPCM16(Data([0x01]), 24_000) }
        let stream = MockSpeechStream(
            blocksAppend: blocksFirstStreamAppend && openCount == 1,
            onAppend: { [appends] _ in appends.increment() }
        )
        self.stream = stream
        streams.append(stream)
        streamOpens.increment()
        onStreamOpen?()
        return stream
    }

    // Awaitable signals.

    func waitUntilTranscriptionStarted(timeout: TimeInterval = 10) async {
        await transcriptions.waitUntil(1, timeout: timeout)
    }

    func waitUntilTranscriptionCount(_ count: Int, timeout: TimeInterval = 10) async {
        await transcriptions.waitUntil(count, timeout: timeout)
    }

    func waitUntilSpeechStreamOpened(_ count: Int = 1, timeout: TimeInterval = 10) async {
        await streamOpens.waitUntil(count, timeout: timeout)
    }

    /// Awaits `count` total delta appends across all opened speech streams.
    /// An append is counted when the drain task hands the text to the stream
    /// (before a blocked append parks), so this also observes the parking
    /// handoff deterministically.
    func waitUntilSpeechAppended(_ count: Int = 1, timeout: TimeInterval = 10) async {
        await appends.waitUntil(count, timeout: timeout)
    }
}

@MainActor
final class MockSpeechStream: VoiceSpeechStream {
    private(set) var appended: [String] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private let blocksAppend: Bool
    private let onAppend: @MainActor (String) -> Void
    private var appendContinuation: CheckedContinuation<Void, Error>?
    private var isCancelled = false

    init(blocksAppend: Bool = false, onAppend: @escaping @MainActor (String) -> Void = { _ in }) {
        self.blocksAppend = blocksAppend
        self.onAppend = onAppend
    }

    func append(_ text: String) async throws {
        appended.append(text)
        onAppend(text)
        guard blocksAppend else { return }
        if isCancelled { throw URLError(.cancelled) }
        try await withCheckedThrowingContinuation { continuation in
            appendContinuation = continuation
            if isCancelled {
                appendContinuation = nil
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }

    func finish() async throws -> Bool {
        finishCount += 1
        return false
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelCount += 1
        let continuation = appendContinuation
        appendContinuation = nil
        continuation?.resume(throwing: URLError(.cancelled))
    }
}

/// Transcription that parks until released, so a test can suspend Voice
/// while a transcription is provably in flight (or assert mid-transcription
/// gates without a wall-clock window).
@MainActor
final class GatedTranscriptionGateway: VoiceGatewayService {
    let profile = "default"
    let transcript: String
    var transcriptionCount: Int { transcriptions.value }
    private let transcriptions = AwaitableCounter()
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var isReleased = false

    init(transcript: String) { self.transcript = transcript }

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        transcriptions.increment()
        if isReleased { return transcript }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingContinuation = continuation
                if self.isReleased || Task.isCancelled {
                    self.pendingContinuation = nil
                    continuation.resume(with: .success(self.transcript))
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.pendingContinuation else { return }
                self.pendingContinuation = nil
                continuation.resume(throwing: CancellationError())
            }
        })
    }

    func waitUntilTranscribing(timeout: TimeInterval = 10) async {
        await transcriptions.waitUntil(1, timeout: timeout)
    }

    func releaseTranscription() {
        // Guarded: the cancellation handler may already have consumed the
        // parked continuation when suspension cancelled the utterance task.
        guard !isReleased, let continuation = pendingContinuation else { return }
        isReleased = true
        pendingContinuation = nil
        continuation.resume(with: .success(transcript))
    }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        try onStart(24_000)
        return StubSpeechStream()
    }
}

@MainActor
final class StubSpeechStream: VoiceSpeechStream {
    func append(_ text: String) async throws {}
    func finish() async throws -> Bool { false }
    func cancel() {}
}

@MainActor
final class MockDeviceTranscriber: DeviceSpeechTranscriptionService {
    let transcript: String
    let permissionGranted: Bool
    private(set) var transcriptionCount = 0
    private(set) var permissionRequestCount = 0
    init(transcript: String, permissionGranted: Bool = true) {
        self.transcript = transcript
        self.permissionGranted = permissionGranted
    }
    func requestPermission() async -> Bool { permissionRequestCount += 1; return permissionGranted }
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        transcriptionCount += 1
        return transcript
    }
    func cancel() {}
}

// MARK: - Policy, gates, capability requester

/// Mutable route policy so tests can pin route classification
/// deterministically; production reads the live AVAudioSession route.
@MainActor
final class RoutePolicyBox {
    var policy: VoiceBargeInRoutePolicy
    init(_ policy: VoiceBargeInRoutePolicy) { self.policy = policy }
}

/// An interruption closure that parks mid-flight, so tests can interleave
/// suspension, teardown, and route changes into the cancel await. Entry is
/// signalled explicitly — `waitUntilEntered()` observes the operation
/// actually being parked instead of relying on fixed sleeps, and returns
/// immediately if entry already happened so the signal cannot be missed.
/// `release()` resumes every parked interruption exactly once and disarms
/// the gate (later interrupts pass through immediately); safe to call twice.
@MainActor
final class InterruptParkingGate {
    private(set) var count = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var isDisarmed = false

    func waitInInterrupt() async {
        count += 1
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isDisarmed else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func waitUntilEntered() async {
        guard count == 0 else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isDisarmed = true
        let parkedContinuations = parked
        parked.removeAll()
        parkedContinuations.forEach { $0.resume() }
    }
}

/// A parkable async step for hermetic reconciliation tests.
@MainActor
final class ControlledSuspension {
    private var suspension: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspension = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard suspension == nil else { return }
        await withCheckedContinuation { continuation in
            observer = continuation
        }
    }

    func resume() {
        suspension?.resume()
        suspension = nil
    }
}

/// Capability-requester double for capability-refresh paths: `.failing`
/// (default) keeps capability refreshes off the network and resolves the
/// snapshot to "no support"; `.fullSupport` answers a minimal config plus a
/// ready Edge TTS toolset row so a refreshed snapshot is genuinely capable.
@MainActor
final class ImmediateVoiceConfigRequester: VoiceConfigurationRequesting {
    enum Mode { case failing, fullSupport }

    private let mode: Mode

    init(mode: Mode = .failing) { self.mode = mode }

    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        switch mode {
        case .failing:
            throw URLError(.notConnectedToInternet)
        case .fullSupport:
            if path.hasSuffix("/api/config") {
                return ["stt": ["enabled": true], "tts": ["provider": "edge"]]
            }
            if path.hasSuffix("/api/tools/toolsets/tts/config") {
                return ["providers": [[
                    "name": "Microsoft Edge TTS",
                    "tts_provider": "edge",
                    "status": "ready",
                    "is_active": true,
                ]]]
            }
            throw URLError(.notConnectedToInternet)
        }
    }
}
