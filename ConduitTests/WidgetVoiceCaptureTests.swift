import XCTest
@testable import Conduit

@MainActor
final class WidgetVoiceCaptureTests: XCTestCase {
    func testRevokedWidgetStartAfterPermissionDoesNotCaptureAndManualListenStillWorks() async {
        let capture = SuspendedWidgetCapture()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            submit: { _ in true },
            interrupt: { true }
        )
        controller.setGateway(MockGateway())
        controller.beginVoiceTurn(sessionID: "widget-session")
        var current = true
        let lease = WidgetLaunchLease(isCurrent: { current })
        controller.installInitialWidgetCaptureAuthorization(lease.initialCaptureAuthorization())

        let widgetListen = Task { await controller.startListening() }
        await capture.permissionRequestEntered.wait()
        current = false
        capture.completePermissionRequest(true)
        await widgetListen.value

        XCTAssertEqual(capture.startCount, 0, "revocation after permission must stop at the actual capture boundary")
        capture.permissionSuspended = false
        await controller.startListening()
        XCTAssertEqual(capture.startCount, 1, "a stale widget lease must not block a later manual Listen")
    }

    func testConsumedCaptureAuthorizationDoesNotExpireEstablishedVoice() {
        var current = true
        let lease = WidgetLaunchLease(isCurrent: { current })
        let authorization = lease.initialCaptureAuthorization()
        XCTAssertTrue(authorization.mayStartCapture)
        authorization.captureDidStart()
        current = false
        XCTAssertTrue(authorization.mayStartCapture, "the one-shot authorization ends its deadline at first capture")
    }

    func testGeminiAndGrokPermissionWaitCannotStartInputAfterRevocation() async {
        let input = SuspendedWidgetLiveInput()
        let session = FakeGeminiLiveSessionControl()
        let supervisor = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
        let controller = GeminiLiveConversationController(
            makeSession: { session },
            availability: { .available(model: "gemini-live") },
            tools: GeminiLiveToolBridge(supervisor: supervisor, webSearch: nil),
            input: input,
            output: FakeGeminiLiveOutput(),
            headsetMute: HeadsetMicrophoneMute(system: FakeSystemInputMute())
        )
        var current = true
        let lease = WidgetLaunchLease(isCurrent: { current })
        let authorization = lease.initialCaptureAuthorization()
        controller.installInitialWidgetCaptureAuthorization(authorization)

        let starting = Task { await controller.start() }
        await input.permissionRequestEntered.wait()
        current = false
        input.completePermissionRequest(true)
        await starting.value

        XCTAssertEqual(input.startCount, 0, "the shared Gemini/Grok path must re-check after permission")
        XCTAssertEqual(session.started, 0)
    }

    func testGeminiAndGrokConsumeLeaseAtFirstReadyInputAndKeepCallAlive() async {
        let input = SuspendedWidgetLiveInput(permissionSuspended: false)
        let session = FakeGeminiLiveSessionControl()
        let supervisor = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
        let controller = GeminiLiveConversationController(
            makeSession: { session },
            availability: { .available(model: "gemini-live") },
            tools: GeminiLiveToolBridge(supervisor: supervisor, webSearch: nil),
            input: input,
            output: FakeGeminiLiveOutput(),
            headsetMute: HeadsetMicrophoneMute(system: FakeSystemInputMute())
        )
        var current = true
        let lease = WidgetLaunchLease(isCurrent: { current })
        let authorization = lease.initialCaptureAuthorization()
        controller.installInitialWidgetCaptureAuthorization(authorization)

        await controller.start()
        session.becomeReady()
        XCTAssertEqual(input.startCount, 1)
        current = false
        XCTAssertTrue(authorization.mayStartCapture, "the established call no longer depends on widget ownership")
        XCTAssertTrue(controller.isActive)
        controller.stop()
    }

    func testGeminiAndGrokPausedFirstCaptureRetryRejectsRevokedOrExpiredLease() async {
        for expiresAtDeadline in [false, true] {
            let input = SuspendedWidgetLiveInput(permissionSuspended: false)
            input.startFailuresRemaining = 1
            let session = FakeGeminiLiveSessionControl()
            let supervisor = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
            let controller = GeminiLiveConversationController(
                makeSession: { session },
                availability: { .available(model: "gemini-live") },
                tools: GeminiLiveToolBridge(supervisor: supervisor, webSearch: nil),
                input: input,
                output: FakeGeminiLiveOutput(),
                headsetMute: HeadsetMicrophoneMute(system: FakeSystemInputMute())
            )
            var current = true
            var elapsed = Duration.zero
            let lease = WidgetLaunchLease(isCurrent: { current && elapsed < .seconds(30) })
            let authorization = lease.initialCaptureAuthorization()
            controller.installInitialWidgetCaptureAuthorization(authorization)

            await controller.start()
            session.becomeReady()
            XCTAssertEqual(input.startAttempts, 1)
            XCTAssertEqual(input.startCount, 0, "a thrown first start must retain the one-shot gate")
            XCTAssertEqual(controller.phase, .paused)

            if expiresAtDeadline { elapsed = .seconds(30) } else { current = false }
            session.becomeReady() // A ready/reconnect event synchronously retries paused audio.

            XCTAssertEqual(input.startAttempts, 1, "the retry must check ownership before touching the microphone")
            XCTAssertEqual(input.startCount, 0)
            XCTAssertFalse(authorization.mayStartCapture)
            controller.stop()
        }
    }

    func testGeminiAndGrokValidFirstCaptureRetryConsumesOnceAndLaterResumeSurvivesRevocation() async {
        let input = SuspendedWidgetLiveInput(permissionSuspended: false)
        input.startFailuresRemaining = 1
        let session = FakeGeminiLiveSessionControl()
        let supervisor = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
        let controller = GeminiLiveConversationController(
            makeSession: { session },
            availability: { .available(model: "gemini-live") },
            tools: GeminiLiveToolBridge(supervisor: supervisor, webSearch: nil),
            input: input,
            output: FakeGeminiLiveOutput(),
            headsetMute: HeadsetMicrophoneMute(system: FakeSystemInputMute())
        )
        var current = true
        var capturesConsumed = 0
        let lease = WidgetLaunchLease(isCurrent: { current }, captureDidStart: { capturesConsumed += 1 })
        let authorization = lease.initialCaptureAuthorization()
        controller.installInitialWidgetCaptureAuthorization(authorization)

        await controller.start()
        session.becomeReady()
        XCTAssertEqual(input.startAttempts, 1)
        XCTAssertEqual(input.startCount, 0)
        XCTAssertEqual(capturesConsumed, 0, "a thrown input start must not consume authorization")

        session.becomeReady() // Retry while the lease is still valid.
        XCTAssertEqual(input.startCount, 1)
        XCTAssertEqual(capturesConsumed, 1, "the first successful capture consumes the lease once")
        XCTAssertTrue(authorization.mayStartCapture)

        current = false
        input.onInterrupted?()
        XCTAssertTrue(controller.isAudioPausedForTesting)
        session.becomeReady() // An established call may resume after launch ownership changes.
        XCTAssertEqual(input.startCount, 2)
        XCTAssertEqual(capturesConsumed, 1)
        XCTAssertEqual(controller.phase, .listening)
        controller.stop()
    }

    func testGPTSessionChecksOwnershipAtMakeOfferAudioBoundary() async {
        let peer = SuspendedWidgetGPTPeer()
        let client = WidgetGPTClient()
        let session = GPTLiveSession(client: client, makePeer: { peer })
        let failed = WidgetVoiceGate()
        session.onStateChange = { state in
            if case .failed = state { Task { await failed.signal() } }
        }
        var current = true
        let lease = WidgetLaunchLease(isCurrent: { current })
        let authorization = lease.initialCaptureAuthorization()

        session.start(initialCaptureAuthorization: authorization)
        current = false
        await failed.wait()

        XCTAssertEqual(peer.offerCount, 0, "the makeOffer boundary must observe revocation after the controller's task scheduling")
        session.stop()
    }

    func testGPTCaptureConsumesAuthorizationBeforeSuspendingMakeOffer() async {
        let peer = SuspendedWidgetGPTPeer()
        let session = GPTLiveSession(client: WidgetGPTClient(), makePeer: { peer })
        var current = true
        let lease = WidgetLaunchLease(isCurrent: { current })
        let authorization = lease.initialCaptureAuthorization()

        session.start(initialCaptureAuthorization: authorization)
        await peer.offerEntered.wait()
        XCTAssertEqual(peer.offerCount, 1)
        current = false
        XCTAssertTrue(authorization.mayStartCapture, "deadline and later routing changes cannot end a captured call")
        session.stop()
    }
}

@MainActor
private final class SuspendedWidgetCapture: AudioCaptureService {
    let events = AsyncStream<VoiceCaptureEvent> { _ in }
    var captureGeneration: UInt64 = 0
    var permissionSuspended = true
    let permissionRequestEntered = WidgetVoiceGate()
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private(set) var startCount = 0
    var isHeldForPlayback = false
    var recordedPCM16 = Data()

    func requestPermission() async -> Bool {
        guard permissionSuspended else { return true }
        await permissionRequestEntered.signal()
        return await withCheckedContinuation { permissionContinuation = $0 }
    }
    func completePermissionRequest(_ allowed: Bool) {
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume(returning: allowed)
    }
    func startListening(includePreRoll: Bool) throws { startCount += 1; captureGeneration += 1 }
    func beginBargeInMonitoring() throws {}
    func pause() {}
    func holdForPlayback() {}
    func resume() throws {}
    func finishUtterance() throws -> VoiceCapturedAudio { throw VoiceAudioError.noAudioCaptured }
    func stop() {}
}

@MainActor
private final class WidgetVoiceGate {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() async {
        signalled = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        if signalled { signalled = false; return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class SuspendedWidgetLiveInput: GeminiLiveAudioInput {
    private struct Interrupted: Error {}
    var onChunk: (@MainActor (Data) -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    var cancelsEcho = false
    let permissionRequestEntered = WidgetVoiceGate()
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private let permissionSuspended: Bool
    private(set) var startCount = 0
    private(set) var startAttempts = 0
    var startFailuresRemaining = 0

    init(permissionSuspended: Bool = true) { self.permissionSuspended = permissionSuspended }
    func requestPermission() async -> Bool {
        guard permissionSuspended else { return true }
        await permissionRequestEntered.signal()
        return await withCheckedContinuation { permissionContinuation = $0 }
    }
    func completePermissionRequest(_ allowed: Bool) {
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume(returning: allowed)
    }
    func start() throws {
        startAttempts += 1
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw Interrupted()
        }
        startCount += 1
    }
    func stop() {}
}

@MainActor
private final class WidgetGPTClient: GPTLiveSessionProviding {
    func availability() async throws -> GPTLiveAvailability { .available(model: "gpt-live", voice: nil) }
    func createSession(offer: String, history: [[String: Any]], voice: String?, briefing: String?, greeting: String?, callOpening: Bool) async throws -> GPTLiveSessionAnswer {
        GPTLiveSessionAnswer(sessionID: "widget-gpt", sdp: "answer")
    }
}

@MainActor
private final class SuspendedWidgetGPTPeer: GPTLivePeer {
    var onMessage: (@MainActor (String) -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onConnectionInterrupted: (@MainActor (Bool) -> Void)?
    var onAudioPaused: (@MainActor (Bool) -> Void)?
    let offerEntered = WidgetVoiceGate()
    private(set) var offerCount = 0
    func makeOffer() async throws -> String { offerCount += 1; await offerEntered.signal(); return "offer" }
    func acceptAnswer(_ sdp: String) async throws {}
    func send(_ text: String) -> Bool { true }
    func setMicrophoneEnabled(_ enabled: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) {}
    func close() {}
}
