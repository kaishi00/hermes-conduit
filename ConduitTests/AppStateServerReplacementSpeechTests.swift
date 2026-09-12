//
//  AppStateServerReplacementSpeechTests.swift
//  Conduit
//
//  Regression coverage for the server-replacement speech boundary: when
//  `prepareChatResumeForConnection(to:)` detects a normalized server change,
//  every Voice Conversation / Read Aloud / provider-test operation belonging
//  to the outgoing server is retired and its gateway references are cleared,
//  so no parked continuation can resurrect capture, playback, or a transport
//  against the previous server. Same-server identity calls must NOT touch
//  speech — that preserves the existing recovery model where speech survives
//  a same-server reconnect (the dashboard bridge is reused).
//

import XCTest
@testable import Conduit

@MainActor
final class AppStateServerReplacementSpeechTests: XCTestCase {
    private static let serverA = "https://one.example"
    private static let serverB = "https://two.example"

    // MARK: - 1. Voice conversation A -> B

    func testServerReplacementStopsActiveVoiceConversationAndClearsGateway() async {
        let harness = makeHarness()
        let listening = await harness.startVoiceListening()
        XCTAssertTrue(listening)
        XCTAssertEqual(harness.voiceController.state, .listening)
        harness.appState.showVoiceSheet = true

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        // Equivalent to the voice conversation having been explicitly ended:
        // idle state, capture retired, sheet closed.
        XCTAssertEqual(harness.voiceController.state, .idle)
        XCTAssertEqual(harness.voiceCapture.stopCount, 1)
        XCTAssertFalse(harness.appState.showVoiceSheet)
        // The outgoing gateway reference is gone — asserted directly, and
        // behaviorally: a later listen attempt with no new gateway fails
        // closed instead of reaching server A.
        XCTAssertFalse(harness.voiceController.isGatewayAttached)
        await harness.voiceController.startListening()
        XCTAssertEqual(
            harness.voiceController.state,
            .failed("Voice is unavailable for this gateway.")
        )
        harness.voiceController.stop()
    }

    // MARK: - 2. Read aloud A -> B

    func testServerReplacementStopsActiveReadAloudAndReleasesStandaloneOwnership() async throws {
        let harness = makeHarness()
        let message = ChatMessage(id: "msg-a", role: .assistant, content: "Response A", timestamp: "1")

        harness.appState.toggleReadAloud(message: message)
        await harness.awaitUntil("read aloud playing on A") {
            harness.readAloudController.state == .playing(messageID: "msg-a")
        }
        let stream = try XCTUnwrap(harness.readAloudGateway.streams.first)
        XCTAssertTrue(harness.readAloudPlayback.isPlaying)
        let stopBaseline = harness.readAloudPlayback.stopCount

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        XCTAssertEqual(harness.readAloudController.state, .idle)
        XCTAssertNil(harness.readAloudController.gateway)
        // Exactly one teardown: the boundary's setGateway(nil) triggers the
        // controller's authoritative Option-A stop.
        XCTAssertEqual(harness.readAloudPlayback.stopCount, stopBaseline + 1)
        XCTAssertFalse(harness.readAloudPlayback.isPlaying)
        XCTAssertEqual(stream.cancelCount, 1)
    }

    // MARK: - 3. Stale voice continuations cannot resurrect capture

    func testServerReplacementMakesAssistantSpeechDrainContinuationInert() async {
        let harness = makeHarness()
        _ = await harness.startVoiceWithAssistantDeltaParkedInDrain()

        let startBaseline = harness.voiceCapture.startListeningCount

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        // The stop cancelled the parked stream; the drain task resumes,
        // observes a stale generation/revision, and must settle without
        // restarting capture or reopening the old server's gateway.
        let oldStream = harness.voiceGateway.streams[0]
        await harness.awaitUntil("the parked drain continuation settled") {
            oldStream.isCancelled && oldStream.cancelCount == 1
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(harness.voiceController.state, .idle)
        XCTAssertEqual(harness.voiceCapture.startListeningCount, startBaseline)
        XCTAssertEqual(harness.voiceGateway.openCount, 1)
    }

    func testServerReplacementMakesParkedBargeInContinuationInert() async {
        let harness = makeHarness()
        _ = await harness.startVoiceWithAssistantResponseStarted()
        XCTAssertEqual(harness.voiceController.state, .thinking)

        // Acoustic barge-in begins and parks inside the injected interrupt
        // seam (the stand-in for Hermes cancellation/recovery work).
        let base = Date()
        harness.voiceController.ingestAudioLevel(0.5, at: base)
        harness.voiceController.ingestAudioLevel(0.5, at: base.addingTimeInterval(0.5))
        await harness.awaitUntil("barge-in entered the interrupt seam") {
            harness.interruptGate.events.contains("entered")
        }
        let startBaseline = harness.voiceCapture.startListeningCount

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)
        XCTAssertEqual(harness.voiceController.state, .idle)

        // Release the parked interruption after the replacement: the stale
        // continuation resumes into a bumped generation and must not reopen
        // the microphone.
        harness.interruptGate.release()
        await harness.awaitUntil("the parked interruption resumed") {
            harness.interruptGate.events.contains("released")
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(harness.voiceCapture.startListeningCount, startBaseline)
        XCTAssertEqual(harness.voiceController.state, .idle)
    }

    // MARK: - 4. Stale read aloud completion cannot touch a newer operation

    func testLateReadAloudStreamFailureAfterReplacementDoesNotDisturbNewOperation() async throws {
        let harness = makeHarness()
        let messageA = ChatMessage(id: "msg-a", role: .assistant, content: "Response A", timestamp: "1")

        harness.appState.toggleReadAloud(message: messageA)
        await harness.awaitUntil("read aloud playing on A") {
            harness.readAloudController.state == .playing(messageID: "msg-a")
        }
        let oldStream = try XCTUnwrap(harness.readAloudGateway.streams.first)

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        // A fresh operation belonging to server B starts normally. Installing
        // the incoming connection's bridge first models the capability
        // refresh that rebuilds gateway currency after a replacement: with a
        // B bridge the B-built mock counts as current. Deleting the
        // retirement's `readAloudGatewayBridge = nil` leaves the stale A
        // bridge here, the mock is replaced by a real A-bound gateway, and
        // this test fails — the line is pinned.
        let bridgeB = DashboardTicketBridge(baseURL: Self.serverB)
        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: bridgeB,
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )
        let gatewayB = GatedVoiceGateway()
        harness.readAloudController.setGateway(gatewayB)
        let messageB = ChatMessage(id: "msg-b", role: .assistant, content: "Response B", timestamp: "2")
        harness.appState.toggleReadAloud(message: messageB)
        await harness.awaitUntil("read aloud playing on B") {
            harness.readAloudController.state == .playing(messageID: "msg-b")
        }

        // The old stream's parked append settles (its cancel fired when the
        // boundary stopped it); the superseded operation must not stop the
        // newer playback or touch shared state.
        await harness.awaitUntil("the old stream settled") {
            oldStream.settled
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(harness.readAloudController.state, .playing(messageID: "msg-b"))
        XCTAssertTrue(harness.readAloudPlayback.isPlaying)
        XCTAssertEqual(oldStream.cancelCount, 1)
        XCTAssertEqual(gatewayB.openCount, 1)
        harness.readAloudController.stop()
    }

    // MARK: - 5/6. Fresh B operations are unaffected by late A callbacks

    func testNewVoiceConversationOnReplacedServerIsUnaffectedByLateOldCallbacks() async {
        let harness = makeHarness()
        _ = await harness.startVoiceWithAssistantDeltaParkedInDrain()

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        // Server B conversation: fresh gateway, fresh turn owning only B's
        // session id. The late A deltas are rejected twice over — B's turn
        // never submitted, so `isAwaitingVoiceAssistant` is false, and the
        // A session id is not in B's expected set.
        let gatewayB = GatedVoiceGateway()
        harness.voiceController.setGateway(gatewayB)
        let listening = await harness.startVoiceListening(sessionID: "b-session")
        XCTAssertTrue(listening)
        XCTAssertEqual(harness.voiceController.state, .listening)

        // The old A stream's cancellation settles its drain task; late A
        // assistant events carry A's session id, which B's turn never owned.
        await harness.awaitUntil("the old A stream settled") {
            harness.voiceGateway.streams[0].settled
        }
        harness.voiceController.receiveAssistantEvent(.delta(sessionID: "a-session", text: "late"))
        harness.voiceController.receiveAssistantEvent(.completed(sessionID: "a-session", content: "late"))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(harness.voiceController.state, .listening)
        XCTAssertTrue(harness.voiceController.conversationTranscript.isEmpty)
        XCTAssertEqual(gatewayB.openCount, 0)
        XCTAssertEqual(harness.voiceGateway.openCount, 1)
        harness.voiceController.stop()
    }

    func testNewReadAloudOnReplacedServerIsUnaffectedByLateOldCallbacks() async {
        let harness = makeHarness()
        let messageA = ChatMessage(id: "msg-a", role: .assistant, content: "Response A", timestamp: "1")
        harness.appState.toggleReadAloud(message: messageA)
        await harness.awaitUntil("read aloud playing on A") {
            harness.readAloudController.state == .playing(messageID: "msg-a")
        }

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        // Install the incoming connection's bridge so the B-built mock counts
        // as current (models the post-replacement capability refresh, and
        // pins the retirement's `readAloudGatewayBridge = nil`).
        let bridgeB = DashboardTicketBridge(baseURL: Self.serverB)
        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: bridgeB,
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )
        let gatewayB = GatedVoiceGateway()
        harness.readAloudController.setGateway(gatewayB)
        let messageB = ChatMessage(id: "msg-b", role: .assistant, content: "Response B", timestamp: "2")
        harness.appState.toggleReadAloud(message: messageB)
        await harness.awaitUntil("read aloud playing on B") {
            harness.readAloudController.state == .playing(messageID: "msg-b")
        }

        await harness.awaitUntil("the old A stream settled") {
            harness.readAloudGateway.streams[0].settled
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(harness.readAloudController.state, .playing(messageID: "msg-b"))
        XCTAssertTrue(harness.readAloudPlayback.isPlaying)
        XCTAssertEqual(gatewayB.openCount, 1)
        harness.readAloudController.stop()
    }

    // MARK: - 7. Audio-session ownership is released at the boundary

    func testServerReplacementRetiresPlaybackOwnershipAndAllowsFreshClaim() async {
        let harness = makeHarness()
        let message = ChatMessage(id: "msg-a", role: .assistant, content: "Response A", timestamp: "1")
        harness.appState.toggleReadAloud(message: message)
        await harness.awaitUntil("read aloud playing on A") {
            harness.readAloudController.state == .playing(messageID: "msg-a")
        }
        _ = await harness.startVoiceListening()
        let voiceStopBaseline = harness.voicePlayback.stopCount
        let readAloudStopBaseline = harness.readAloudPlayback.stopCount

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        // Each retired owner ends fully stopped with exactly one teardown —
        // the voice controller's stop() and the read aloud controller's
        // gateway-swap stop respectively.
        XCTAssertEqual(harness.voicePlayback.stopCount, voiceStopBaseline + 1)
        XCTAssertEqual(harness.readAloudPlayback.stopCount, readAloudStopBaseline + 1)
        XCTAssertFalse(harness.voicePlayback.isPlaying)
        XCTAssertFalse(harness.readAloudPlayback.isPlaying)
        XCTAssertFalse(harness.voiceController.isGatewayAttached)
        XCTAssertNil(harness.readAloudController.gateway)

        // A B-owned operation can claim playback normally afterwards: model
        // the incoming connection's capability refresh with a B bridge, then
        // start the fresh read aloud.
        let bridgeB = DashboardTicketBridge(baseURL: Self.serverB)
        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: bridgeB,
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )
        harness.readAloudController.setGateway(GatedVoiceGateway())
        let messageB = ChatMessage(id: "msg-b", role: .assistant, content: "Response B", timestamp: "2")
        harness.appState.toggleReadAloud(message: messageB)
        await harness.awaitUntil("B read aloud playing") {
            harness.readAloudController.state == .playing(messageID: "msg-b")
        }
        XCTAssertTrue(harness.readAloudPlayback.isPlaying)
        harness.readAloudController.stop()
    }

    // MARK: - 8. Failure after takeover keeps A speech retired

    func testSpeechStaysRetiredWhenReplacementIdentityPersistsAfterFailedActivation() async {
        let harness = makeHarness()
        _ = await harness.startVoiceListening()
        harness.appState.showVoiceSheet = true

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        // The boundary commits the identity before any transport exists; a
        // failed activation does not roll it back, and the retirement is not
        // undone. A repeat call for the same (failed) server is a same-server
        // call now and must not resurrect anything either.
        let repeated = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertFalse(repeated)
        // Literal mirrors AppState's private key; asserted behaviorally
        // everywhere else, here it pins that the replacement identity
        // committed even though no transport ever came up.
        XCTAssertEqual(
            harness.defaults.string(forKey: "conduit.chatResumeServerIdentity.v1"),
            Self.serverB
        )
        XCTAssertEqual(harness.voiceController.state, .idle)
        XCTAssertNil(harness.readAloudController.gateway)
        XCTAssertFalse(harness.appState.showVoiceSheet)
    }

    // MARK: - 9. Same-server control: the boundary is not overly broad

    func testSameServerIdentityCallPreservesActiveSpeech() async {
        let harness = makeHarness()

        // Read aloud first through AppState, THEN the voice conversation via
        // the controller directly: AppState's read-aloud entry enforces
        // mutual exclusion and would stop a live voice conversation, while
        // the controller's own listening start does not touch read aloud.
        // This setup is what makes both owners simultaneously live.
        let message = ChatMessage(id: "msg-a", role: .assistant, content: "Response A", timestamp: "1")
        harness.appState.toggleReadAloud(message: message)
        await harness.awaitUntil("read aloud playing") {
            harness.readAloudController.state == .playing(messageID: "msg-a")
        }
        let listening = await harness.startVoiceListening()
        XCTAssertTrue(listening)

        let voiceStopBaseline = harness.voicePlayback.stopCount
        let readAloudStopBaseline = harness.readAloudPlayback.stopCount

        // Identical normalized identity: recovery, not replacement.
        let same = harness.appState.prepareChatResumeForConnection(to: Self.serverA)
        XCTAssertFalse(same)

        // Default-port spelling folds to the same identity too.
        let folded = harness.appState.prepareChatResumeForConnection(to: "https://one.example:443")
        XCTAssertFalse(folded)

        XCTAssertEqual(harness.voiceController.state, .listening)
        XCTAssertEqual(harness.readAloudController.state, .playing(messageID: "msg-a"))
        XCTAssertEqual(harness.voicePlayback.stopCount, voiceStopBaseline)
        XCTAssertEqual(harness.readAloudPlayback.stopCount, readAloudStopBaseline)
        XCTAssertNotNil(harness.readAloudController.gateway)
        harness.readAloudController.stop()
    }

    // MARK: - 10. Provider tests are server-bound and retired by the boundary

    func testServerReplacementCancelsInFlightTTSSpeechTest() async {
        let harness = makeHarness()
        let speechTest = Task { @MainActor in
            await harness.voiceController.runSpeechTest(text: "Conduit voice is ready for this profile.")
        }
        await harness.awaitUntil("the speech test parked in its stream append") {
            harness.voiceGateway.streams.first?.parkedAppend == true
        }
        XCTAssertEqual(harness.voiceController.state, .speaking)

        let changed = harness.appState.prepareChatResumeForConnection(to: Self.serverB)
        XCTAssertTrue(changed)

        // Bounded settle: if the retirement ever regresses, this fails at the
        // awaitUntil timeout instead of hanging on the parked task.
        await harness.awaitUntil("the retired speech test to settle") {
            !harness.voiceController.hasLiveVoiceSession
        }
        // Test-only backstop so a broken implementation fails the assertions
        // instead of hanging the runner: the cancel is idempotent (a no-op
        // when the retirement already cancelled the stream) and guarantees
        // the parked task completes.
        harness.voiceGateway.streams.first?.cancel()
        let result = await speechTest.value
        XCTAssertFalse(result.passed, "a retired speech test must not report success")
        XCTAssertEqual(harness.voiceController.state, .idle)
        XCTAssertFalse(harness.voiceController.hasLiveVoiceSession)
        XCTAssertFalse(harness.voiceController.isGatewayAttached)
        XCTAssertEqual(harness.voiceGateway.streams[0].cancelCount, 1)
    }

    // MARK: - Harness

    private func makeHarness() -> Harness {
        let suite = "AppStateServerReplacementSpeechTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: Self.serverA, ticket: "test-ticket")
        appState.isConnected = true

        let voicePlayback = CountingPlayback()
        let voiceCapture = GatedCapture()
        let voiceGateway = GatedVoiceGateway()
        let interruptGate = InterruptGate()
        let voiceController = VoiceConversationController(
            capture: voiceCapture,
            playback: voicePlayback,
            deviceTranscriber: CountingTranscriber(),
            gateway: voiceGateway,
            // Hermetic route: full duplex keeps capture unsuspended during
            // assistant playback, so no assertion depends on the simulator's
            // real AVAudioSession route.
            routePolicyProvider: { .fullDuplex },
            submit: { _ in true },
            interrupt: { await interruptGate.wait(); return true }
        )
        appState.voiceConversationController = voiceController

        let readAloudPlayback = CountingPlayback()
        let readAloudGateway = GatedVoiceGateway()
        let readAloudController = MessageReadAloudController(
            playback: readAloudPlayback,
            gateway: readAloudGateway,
            reportError: { _ in }
        )
        appState.messageReadAloudController = readAloudController

        let bridge = DashboardTicketBridge(baseURL: Self.serverA)
        appState.installVoiceCapabilityStateForTesting(
            bridge: bridge,
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )

        // Seed server A's identity the way the resume boundary does: with no
        // stored identity the first call only records it (returns false).
        let seeded = appState.prepareChatResumeForConnection(to: Self.serverA)
        XCTAssertFalse(seeded)

        return Harness(
            appState: appState,
            defaults: defaults,
            voiceController: voiceController,
            voiceCapture: voiceCapture,
            voicePlayback: voicePlayback,
            voiceGateway: voiceGateway,
            interruptGate: interruptGate,
            readAloudController: readAloudController,
            readAloudPlayback: readAloudPlayback,
            readAloudGateway: readAloudGateway
        )
    }

    @MainActor
    private struct Harness {
        let appState: AppState
        let defaults: UserDefaults
        let voiceController: VoiceConversationController
        let voiceCapture: GatedCapture
        let voicePlayback: CountingPlayback
        let voiceGateway: GatedVoiceGateway
        let interruptGate: InterruptGate
        let readAloudController: MessageReadAloudController
        let readAloudPlayback: CountingPlayback
        let readAloudGateway: GatedVoiceGateway

        func awaitUntil(
            _ description: String,
            timeout: TimeInterval = 2.0,
            condition: @MainActor () -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() >= deadline {
                    XCTFail("Timed out waiting for \(description)")
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        /// Arms a live listening voice turn on the injected gateway.
        @discardableResult
        func startVoiceListening(sessionID: String = "a-session") async -> Bool {
            voiceController.beginVoiceTurn(sessionID: sessionID)
            await voiceController.startListening()
            return voiceController.state == .listening
        }

        /// Drives a turn to `.thinking`, reports the assistant start, then a
        /// delta whose speech-drain append is parked on the mock stream — the
        /// deterministic stand-in for in-flight assistant playback.
        func startVoiceWithAssistantDeltaParkedInDrain() async -> GatedVoiceStream {
            _ = await startVoiceListening()
            await finishUtteranceToThinking()
            voiceController.receiveAssistantEvent(.started(sessionID: "a-session"))
            voiceController.receiveAssistantEvent(.delta(sessionID: "a-session", text: "hello"))
            await awaitUntil("the drain parked in the stream append") {
                self.voiceGateway.streams.first?.parkedAppend == true
            }
            return voiceGateway.streams[0]
        }

        /// Drives a turn to `.thinking` with the assistant response started,
        /// so barge-in monitoring is armed and playback-suspension is not.
        func startVoiceWithAssistantResponseStarted() async {
            _ = await startVoiceListening()
            await finishUtteranceToThinking()
            voiceController.receiveAssistantEvent(.started(sessionID: "a-session"))
        }

        /// Utterance finish is date-driven: one speech sample followed by a
        /// later silent sample deterministically schedules `finishUtterance`,
        /// and the mock transcriber + submit closure land the turn in
        /// `.thinking`.
        private func finishUtteranceToThinking() async {
            let base = Date()
            voiceController.ingestAudioLevel(0.5, at: base)
            voiceController.ingestAudioLevel(0.0, at: base.addingTimeInterval(5))
            await awaitUntil("the turn to reach thinking") {
                self.voiceController.state == .thinking
            }
        }
    }
}

// MARK: - Deterministic test doubles

/// Interruption seam with an explicit gate: `wait()` records entry, parks
/// until `release()`, and records the resumption so tests can assert against
/// the exact resumption point instead of sleeping.
@MainActor
private final class InterruptGate {
    private(set) var events: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        events.append("entered")
        if released {
            events.append("released")
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        events.append("released")
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class GatedCapture: AudioCaptureService {
    let events = AsyncStream<VoiceCaptureEvent> { _ in }
    let captureGeneration: UInt64 = 0
    private(set) var startListeningCount = 0
    private(set) var stopCount = 0

    func requestPermission() async -> Bool { true }
    func startListening(includePreRoll: Bool) throws { startListeningCount += 1 }
    func beginBargeInMonitoring() throws {}
    func pause() {}
    func resume() throws {}
    func finishUtterance() throws -> VoiceCapturedAudio {
        VoiceCapturedAudio(wavData: Data(), pcm16Data: Data(), sampleRate: 16_000, duration: 0)
    }
    func stop() { stopCount += 1 }
}

@MainActor
private final class CountingPlayback: SpeechPlaybackService {
    var isPlaying = false
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    private(set) var stopCount = 0

    func start(sampleRate: Double) throws { isPlaying = true }
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int { data.count / 2 }
    func playEncodedAudioData(_ data: Data) throws { isPlaying = true }
    func finish() throws {}
    func drain() async { isPlaying = false }
    func stop() {
        isPlaying = false
        stopCount += 1
    }
}

@MainActor
private final class CountingTranscriber: DeviceSpeechTranscriptionService {
    func requestPermission() async -> Bool { true }
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String { "transcript" }
    func cancel() {}
}

@MainActor
private final class GatedVoiceGateway: VoiceGatewayService {
    let profile = "default"
    private(set) var openCount = 0
    private(set) var streams: [GatedVoiceStream] = []

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String { "transcript" }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        openCount += 1
        let stream = GatedVoiceStream()
        streams.append(stream)
        try onStart(24_000)
        try onPCM16(Data(repeating: 1, count: 8), 24_000)
        return stream
    }
}

/// A stream whose `append` parks on an explicit continuation, giving tests a
/// deterministic gate for "operation in flight across the boundary". `cancel`
/// resolves the parked append with a cancellation error, exactly like the
/// real speech websocket teardown.
@MainActor
private final class GatedVoiceStream: VoiceSpeechStream {
    private(set) var appended: [String] = []
    private(set) var parkedAppend = false
    private(set) var cancelCount = 0
    private(set) var isCancelled = false
    /// True while no append is parked mid-flight.
    private(set) var settled = true
    private var continuation: CheckedContinuation<Void, Error>?

    func append(_ text: String) async throws {
        appended.append(text)
        parkedAppend = true
        settled = false
        defer {
            parkedAppend = false
            settled = true
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() async throws -> Bool { true }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelCount += 1
        continuation?.resume(throwing: URLError(.cancelled))
        continuation = nil
    }
}
