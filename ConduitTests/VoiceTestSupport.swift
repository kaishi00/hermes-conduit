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
//  event. Prefer a positive control that proves the pipeline passed the fence
//  — another event's `waitUntil*` signal, a `waitForState` transition, a
//  parked gate's release — and only then assert nothing changed. Where no such
//  control exists (a rejected event has no observable effect by design),
//  `drainPendingMainActorWork()` is best-effort cleanup between the handoff
//  and the assertion; it is not proof that asynchronous work has finished.
//

import Combine
import Foundation
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
                guard let self, !Task.isCancelled else { return }
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

    var count: Int { submissions.value }

    func submit(_ text: String) async -> Bool {
        texts.append(text)
        submissions.increment()
        return true
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

/// MainActor-isolated on purpose: `sink()` must subscribe on the main actor
/// because `@Published` replays the current value SYNCHRONOUSLY on the
/// subscribing thread, and every production write to these properties happens
/// on the MainActor. A nonisolated `wait()` would subscribe from the generic
/// executor and trip the `assumeIsolated` assert with the replayed value.
@MainActor
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
            // everything here is installed before any production task can
            // run — no missed event, and no suspension point between the
            // continuation and the subscription.
            self.continuation = continuation
            // Created BEFORE the subscription: a value replayed synchronously
            // inside `sink` would otherwise reach `finish` while `timeoutTask`
            // is still nil, leaving this timer to fire uncancelled later.
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(returning: false)
            }
            self.cancellable = self.publisher.sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.receive(value)
                }
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

/// Best-effort MainActor barrier for NEGATIVE assertions only.
///
/// Each round enqueues one block on the main queue and awaits it. The main
/// queue is FIFO, so every job that was already enqueued when a round started
/// — including the MainActor job for a capture event that has already been
/// yielded into a double's stream — has run by the time that round returns.
/// That is the reason for rounds instead of a plain `Task.yield()` loop:
/// `yield()` re-enqueues the yielding task without promising where it lands
/// relative to work that is already waiting, so a yield budget asserts a
/// scheduler contract that does not exist.
///
/// This is still NOT a synchronization primitive, and NOT a way to wait for
/// something that has not happened yet:
///
/// - An `AsyncStream` consumer that has not been resumed yet is not covered.
///   The pump advances about one event per round, so a multi-event handoff is
///   drained as a matter of practice, not of contract. Rounds bound the effort
///   and keep this best-effort; never read them as proof.
/// - It must never be the SOLE evidence for an important negative assertion.
///   When a positive event proves the relevant queue passed the fence — a
///   `waitUntil*` signal, `waitForState`, a parked gate's release, a counter —
///   wait on that instead. Use this only as cleanup between a volatile handoff
///   and an absence assertion, or where rejecting the event has no observable
///   effect by design.
@MainActor
func drainPendingMainActorWork(rounds: Int = 16) async {
    for _ in 0..<rounds {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
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
    /// Mutable so a test can revoke permission between turns.
    var permissionGranted: Bool
    private let startError: Error?
    /// Latches on the first successful `startListening` and is never cleared.
    /// It answers "did a capture window ever open", NOT production's
    /// `activelyRecording` (which flips false again on barge-in monitoring and
    /// on stop). For a per-window signal use `startCount`/`waitUntilStartCount`.
    var didStart = false
    var didBeginMonitoring = false
    var didPause = false
    private var mockPaused = false
    private(set) var lastStartIncludePreRoll: Bool?
    private(set) var pauseCount = 0
    /// Playback holds keep the running capture (no generation bump), like
    /// the real service; any later lifecycle call ends the hold.
    private(set) var holdCount = 0
    private(set) var isHeldForPlayback = false
    private(set) var resumeCount = 0
    /// When set, `resume()` throws it and the capture stays paused.
    var resumeError: Error?
    private(set) var stopCount = 0
    private(set) var finishUtteranceCount = 0
    /// What live transcription reads as the open utterance's recording.
    var recordedPCM16 = Data()
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
        if let startError {
            // A failed start opens no capture window. Production runs
            // `handleStartupFailure` -> `stop()`, so mirror that teardown
            // exactly (stopCount, pause cleared, generation bumped
            // fail-closed). No listen is recorded — `startCount` and
            // `lastStartIncludePreRoll` describe successful windows only.
            stop()
            throw startError
        }

        didStart = true
        lastStartIncludePreRoll = includePreRoll
        mockPaused = false
        isHeldForPlayback = false
        captureGeneration &+= 1
        starts.increment()
    }
    /// Awaits a successful capture window opening (fresh listen or recapture).
    /// A configured `startError` never satisfies this: a start that threw did
    /// not open a window.
    func waitUntilStartCount(_ count: Int, timeout: TimeInterval = 10) async {
        await starts.waitUntil(count, timeout: timeout)
    }
    func beginBargeInMonitoring() throws { didBeginMonitoring = true }
    func holdForPlayback() {
        guard !mockPaused, !isHeldForPlayback else { return }
        holdCount += 1
        isHeldForPlayback = true
    }
    func pause() {
        isHeldForPlayback = false
        didPause = true
        // The real service is idempotent (guard !paused); keep counts honest.
        guard !mockPaused else { return }
        mockPaused = true
        pauseCount += 1
        captureGeneration &+= 1
    }
    func resume() throws {
        if let resumeError { throw resumeError }
        mockPaused = false
        isHeldForPlayback = false
        resumeCount += 1
        captureGeneration &+= 1
    }
    func finishUtterance() throws -> VoiceCapturedAudio {
        finishUtteranceCount += 1
        return VoiceCapturedAudio(wavData: Data([1]), pcm16Data: Data([1, 0]), sampleRate: 16_000, duration: 0.01)
    }
    func stop() {
        mockPaused = false
        isHeldForPlayback = false
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
    func stop() { isPlaying = false }
}

// MARK: - Gateway double

@MainActor
final class MockGateway: VoiceGatewayService {
    let profile = "default"
    /// Mutable so multi-phase tests can pin what the recognizer returns
    /// per phase (normal turn, spoken command, follow-up).
    var transcript: String
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

/// Raised when a double is driven outside its documented contract, so the
/// misuse surfaces as a loud, testable failure instead of a stalled lane.
enum MockSpeechStreamError: Error, Equatable {
    /// A second append parked while one was already parked; the double
    /// supports a single parked append at a time.
    case concurrentParkedAppend
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
        // Acceptance is validated BEFORE the append is published: a refused
        // append must not look like a delivered one to `appended`, to
        // `onAppend` (and therefore MockGateway's append counter and a waiting
        // `waitUntilSpeechAppended`), or to anything else observing the stream.
        if isCancelled || Task.isCancelled { throw URLError(.cancelled) }
        // One parked append at a time. Overwriting the slot would leak the
        // earlier continuation and hang the drain, so a second concurrent park
        // fails loudly and testably instead. Checked here rather than inside
        // the continuation: there is no suspension point in between, so the
        // check and the park are one atomic MainActor step.
        if blocksAppend, appendContinuation != nil { throw MockSpeechStreamError.concurrentParkedAppend }

        appended.append(text)
        onAppend(text)

        guard blocksAppend else { return }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                appendContinuation = continuation
                // Cancellation can land before the continuation is installed;
                // this re-check keeps the park from outliving its task.
                if isCancelled || Task.isCancelled {
                    appendContinuation = nil
                    continuation.resume(throwing: URLError(.cancelled))
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.releaseParkedAppendAsCancelled()
            }
        })
    }

    /// Resumes the parked append with `.cancelled`. Every release path clears
    /// the slot before resuming and all of them run on the MainActor, so the
    /// continuation is resumed at most once.
    private func releaseParkedAppendAsCancelled() {
        guard let continuation = appendContinuation else { return }
        appendContinuation = nil
        continuation.resume(throwing: URLError(.cancelled))
    }

    func finish() async throws -> Bool {
        finishCount += 1
        return false
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelCount += 1
        releaseParkedAppendAsCancelled()
    }
}

/// Transcription that parks until released, so a test can suspend Voice
/// while a transcription is provably in flight (or assert mid-transcription
/// gates without a wall-clock window).
/// Single-release use: `releaseTranscription()` disarms the park, so a
/// second parked transcription needs a fresh gateway.
@MainActor
final class GatedTranscriptionGateway: VoiceGatewayService {
    let profile = "default"
    let transcript: String
    var transcriptionCount: Int { transcriptions.value }
    private let transcriptions = AwaitableCounter()
    private var pendingContinuation: CheckedContinuation<String, Error>?
    /// Whether `releaseTranscription()` has disarmed the gate. Readable so a
    /// test can assert the disarm contract directly — after a release, a later
    /// transcription returns from the early guard in `transcribe` instead of
    /// parking.
    private(set) var isReleased = false

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
        // Disarms unconditionally. The cancellation handler may already have
        // consumed the parked continuation when suspension cancelled the
        // utterance task, in which case there is nothing to resume — but the
        // gate must still stop accepting parks. Returning early on a nil
        // continuation left `isReleased` false, so the next transcription
        // parked on a gate the test had already released.
        guard !isReleased else { return }
        isReleased = true
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(with: .success(transcript))
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
/// Single-phase use: create a fresh gate per test phase — `count` never
/// resets, so a second `waitUntilEntered()` would observe the first entry.
@MainActor
final class InterruptParkingGate {
    private let entered = AwaitableCounter()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var isDisarmed = false

    /// How many interruptions have reached the gate.
    var count: Int { entered.value }

    func waitInInterrupt() async {
        entered.increment()
        guard !isDisarmed else { return }
        // Deliberately parked until `release()`: this models an operation held
        // mid-flight, so the park itself must not expire — the test owns the
        // release, and `waitUntilEntered` below is what fails loudly if entry
        // never happens.
        await withCheckedContinuation { parked.append($0) }
    }

    /// Awaits at least `count` entries. The multi-entry companion to
    /// `waitUntilEntered`, so a test can pin a two-entry phase without
    /// assuming anything about scheduling.
    func waitUntilEntryCount(_ count: Int, timeout: TimeInterval = 10) async {
        await entered.waitUntil(count, timeout: timeout)
    }

    /// Awaits the operation being parked — the semantic condition is "entered
    /// at least once", so a gate that was entered twice before this ran is
    /// satisfied, not failed. Bounded: a `timeout` expiry records an explicit
    /// failure naming the missing entry instead of stalling the lane until the
    /// watchdog kills it. A genuine "only once" invariant belongs at the call
    /// site that owns it, not in this generic waiter.
    func waitUntilEntered(timeout: TimeInterval = 10) async {
        await entered.waitUntil(1, timeout: timeout)
        XCTAssertGreaterThanOrEqual(
            entered.value, 1,
            "the parked operation was never entered within \(timeout)s"
        )
    }

    func release() {
        isDisarmed = true
        let parkedContinuations = parked
        parked.removeAll()
        parkedContinuations.forEach { $0.resume() }
    }
}

/// A parkable async step for hermetic reconciliation tests.
///
/// `suspend()` itself never expires: like the other parked-operation gates, the
/// parked operation is released by the test through `resume()`. What is bounded
/// is the *observation* — `waitUntilSuspended()` fails loudly on `timeout`
/// instead of leaving the lane for the watchdog when a suspension never
/// arrives. One waiter at a time: create a fresh gate per test phase.
@MainActor
final class ControlledSuspension {
    private var suspension: CheckedContinuation<Void, Never>?
    private var observer: Observer?
    /// Counts waits that parked an observer with nothing yet suspended, so a
    /// test can fence the "waiter installed before the suspension" phase.
    private let observersInstalled = AwaitableCounter()

    /// The single pending suspension wait: its continuation plus the
    /// deadlock-guard timer. `isResumed` makes the two release paths — the
    /// suspension arriving and the timeout expiring — mutually exclusive, and
    /// the slot is cleared before resuming, so the continuation is resumed at
    /// most once.
    private final class Observer {
        let continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>?
        var isResumed = false

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspension = continuation
            // Hand off to a live observer exactly once. A timed-out observer
            // was already detached, so it can never be resumed from here.
            guard let observer, !observer.isResumed else { return }
            self.observer = nil
            observer.isResumed = true
            observer.timeoutTask?.cancel()
            observer.continuation.resume(returning: true)
        }
    }

    /// The bounded core of `waitUntilSuspended`: whether the suspension was
    /// observed before `timeout` expired. Separate from the asserting wrapper
    /// so the expiry path can be exercised deliberately — a test asserting the
    /// `false` outcome is not itself reporting a failure.
    func awaitSuspension(timeout: TimeInterval = 10) async -> Bool {
        guard suspension == nil else { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let observer = Observer(continuation: continuation)
            self.observer = observer
            // Installed, and no suspension yet — publish the phase so a test
            // can pin this order instead of assuming it.
            observersInstalled.increment()
            observer.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.expire(observer)
            }
        }
    }

    /// How many waits have parked an observer without a suspension to consume.
    var observerInstallCount: Int { observersInstalled.value }

    /// Awaits `count` observers being installed while nothing is suspended. A
    /// phase signal for tests that must pin "the waiter is parked before the
    /// suspension arrives": without it, starting `suspend()` concurrently lets
    /// the waiter take the already-suspended fast path and the wakeup path
    /// under test is never exercised.
    func waitUntilObserverInstalled(_ count: Int = 1, timeout: TimeInterval = 10) async {
        await observersInstalled.waitUntil(count, timeout: timeout)
    }

    /// Awaits this gate being suspended, returning immediately when it already
    /// is. Bounded: on expiry the observer is detached and a failure naming the
    /// missing suspension is recorded, so a regression fails the test instead
    /// of stalling the lane.
    func waitUntilSuspended(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didSuspend = await awaitSuspension(timeout: timeout)
        XCTAssertTrue(
            didSuspend,
            "the suspension was never installed within \(timeout)s",
            file: file,
            line: line
        )
    }

    /// Timeout path: detach before resuming, so a later `suspend()` cannot find
    /// a stale observer and this continuation is resumed exactly once.
    private func expire(_ observer: Observer) {
        guard !observer.isResumed else { return }
        observer.isResumed = true
        if self.observer === observer { self.observer = nil }
        observer.continuation.resume(returning: false)
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

/// The system input mute (AirPods / headset gesture) without AVFAudio.
@MainActor
final class FakeSystemInputMute: SystemInputMuteControlling {
    private(set) var handler: (@MainActor (Bool) -> Void)?
    private(set) var muted = false

    func observeInputMute(_ handler: (@MainActor (Bool) -> Void)?) {
        self.handler = handler
    }

    func setInputMuted(_ muted: Bool) throws {
        self.muted = muted
    }

    /// The user pressing the headset's mute control.
    func press(muted: Bool) {
        self.muted = muted
        handler?(muted)
    }
}
