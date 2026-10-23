//
//  LocalLiveJobNoticeTests.swift
//  ConduitTests
//
//  A Local Live call that runs its own agent (Live > Local) has the fast
//  model on the front: a background job's result is news to it and must be
//  said, once, as the call's own turn. A Local Live call that hands each
//  utterance to Hermes (hermes_turns) still drops it: Hermes' reply is the
//  call's own turn and a notice said as well would be said twice.
//
//  The route itself is a pure function of what AppState reads off the call,
//  so these tests drive that same function rather than re-deciding here.
//

import AVFAudio
import XCTest
@testable import Conduit

@MainActor
final class LocalLiveJobNoticeTests: XCTestCase {
    private func settle(until done: () -> Bool, limit: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !done(), ContinuousClock.now < deadline { await Task.yield() }
    }

    private func makeSupervisor() -> VoiceBackgroundJobSupervisor {
        VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
    }

    /// Availability the test opens by hand, so a call can be caught with no
    /// session yet: the window the microphone prompt and the handshake keep
    /// open (`start()` asks before it makes one).
    @MainActor
    private final class GatedAvailability {
        private var opened = false

        func wait() async {
            while !opened { await Task.yield() }
        }

        func open() { opened = true }
    }

    private static let model = "qwen3.8-omni-flash-realtime"

    /// A Local Live call on the real session seam, driven by a fake socket.
    private func makeLocalLiveController(
        agent: Bool,
        supervisor: VoiceBackgroundJobSupervisor,
        notificationCenter: NotificationCenter = NotificationCenter(),
        availability: (@MainActor () async throws -> GeminiLiveAvailability)? = nil
    ) -> (controller: GeminiLiveConversationController, session: LocalLiveSession,
          input: FakeGeminiLiveInput, sockets: () -> [FakeGeminiLiveSocket]) {
        let availability = availability ?? { .available(model: LocalLiveJobNoticeTests.model) }
        var sockets: [FakeGeminiLiveSocket] = []
        let session = LocalLiveSession(
            client: FakeLocalLiveConnection(),
            openSocket: { request in
                let socket = FakeGeminiLiveSocket(url: request.url!)
                sockets.append(socket)
                return socket
            },
            setupTimeout: .seconds(10),
            readinessTimeout: .seconds(60),
            keepaliveInterval: .seconds(3_600),
            reconnectDelay: { _ in }
        )
        if agent {
            session.agentSetup = { .init(instructions: "Be brief.", functions: []) }
        }
        let input = FakeGeminiLiveInput()
        let controller = GeminiLiveConversationController(
            makeSession: { session },
            availability: availability,
            tools: GeminiLiveToolBridge(supervisor: supervisor, webSearch: nil, holdsJobCalls: false),
            input: input,
            output: FakeGeminiLiveOutput(),
            now: Date.init,
            headsetMute: HeadsetMicrophoneMute(system: FakeSystemInputMute()),
            notificationCenter: notificationCenter
        )
        return (controller, session, input, { sockets })
    }

    /// The frame types the call has sent so far.
    private func frameTypes(_ socket: FakeGeminiLiveSocket) -> [String] {
        socket.sent.map { $0["type"] as? String ?? "" }
    }

    /// The server's setup and readiness check, as the app drives them.
    private func makeReady(_ session: LocalLiveSession, _ socket: FakeGeminiLiveSocket) async throws {
        socket.deliver(["type": "session.updated"])
        await settle(until: { frameTypes(socket).contains("response.create") })
        let check = try XCTUnwrap(socket.sent.last { $0["type"] as? String == "response.create" })
        let response = try XCTUnwrap(check["response"] as? [String: Any])
        let item = try XCTUnwrap((response["input"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap((item["content"] as? [[String: Any]])?.first)
        let marker = try XCTUnwrap(content["text"] as? String)
        socket.deliver(["type": "conduit.turn", "turn_id": "ready", "text": marker])
        await settle(until: { session.state == .ready })
    }

    /// The call's own turns that carry `text`.
    private func turns(_ socket: FakeGeminiLiveSocket, containing text: String) -> [String] {
        socket.sent.compactMap { frame in
            guard frame["type"] as? String == "conversation.item.create",
                  let item = frame["item"] as? [String: Any],
                  let content = (item["content"] as? [[String: Any]])?.first,
                  let said = content["text"] as? String,
                  said.contains(text) else { return nil }
            return said
        }
    }

    private func finishAJob(_ supervisor: VoiceBackgroundJobSupervisor) async {
        _ = await supervisor.startJob(instructions: "check the mail")
        supervisor.observe(.messageComplete(sessionId: "st-1", messageId: nil, content: "3 unread.", reasoning: nil))
    }

    /// What AppState's `onNoticePending` does for this call, from the values
    /// it reads: the route decides, and only its `deliverAsUpdate` branch can
    /// settle a notice.
    private func handlePendingNotice(
        _ controller: GeminiLiveConversationController,
        supervisor: VoiceBackgroundJobSupervisor,
        configuredAgent: Bool
    ) {
        switch LocalLiveNoticeHandling.forCall(
            runsAgentTurns: controller.sessionRunsAgentTurns,
            sessionIsReady: controller.sessionIsReady,
            configuredAgent: configuredAgent
        ) {
        case .deliverAsUpdate:
            controller.deliverPendingJobUpdates()
        case .drop:
            supervisor.dropPendingNotices()
        }
    }

    // MARK: Routing

    func testTheRouteFollowsTheReadyConnectionAndOnlyUsesTheSettingBeforeThat() {
        // A ready connection is the truth: a call keeps the mode it
        // connected with, even if Settings was switched mid-conversation.
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: true, sessionIsReady: true, configuredAgent: true), .deliverAsUpdate)
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: true, sessionIsReady: true, configuredAgent: false), .deliverAsUpdate)
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: false, sessionIsReady: true, configuredAgent: true), .drop)
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: false, sessionIsReady: true, configuredAgent: false), .drop)

        // Before that, Settings says what the connection that arrives will
        // be. Agent mode keeps the notice for it; Classic drops it as it
        // always did (Hermes' own reply is the Classic turn).
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: false, sessionIsReady: false, configuredAgent: true), .deliverAsUpdate)
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: false, sessionIsReady: false, configuredAgent: false), .drop)
    }

    func testALocalLiveSessionSaysWhetherItsConnectionRunsAgentTurns() async throws {
        let agent = makeLocalLiveController(agent: true, supervisor: makeSupervisor())
        await agent.controller.start()
        await settle(until: { agent.sockets().isEmpty == false })
        let agentSocket = try XCTUnwrap(agent.sockets().first)
        XCTAssertFalse(agent.controller.sessionIsReady, "connecting: nothing can be sent yet")
        try await makeReady(agent.session, agentSocket)
        XCTAssertTrue(agent.session.runsAgentTurns)
        XCTAssertTrue(agent.controller.sessionRunsAgentTurns)
        XCTAssertTrue(agent.controller.sessionIsReady)
        agent.controller.stop()

        let plain = makeLocalLiveController(agent: false, supervisor: makeSupervisor())
        await plain.controller.start()
        await settle(until: { plain.sockets().isEmpty == false })
        let plainSocket = try XCTUnwrap(plain.sockets().first)
        try await makeReady(plain.session, plainSocket)
        XCTAssertFalse(plain.session.runsAgentTurns)
        XCTAssertFalse(plain.controller.sessionRunsAgentTurns)
        XCTAssertTrue(plain.controller.sessionIsReady)
        plain.controller.stop()
    }

    // MARK: Delivery

    func testALocalLiveAgentCallSaysAFinishedJobsResultOnce() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)
        await finishAJob(supervisor)

        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: true)
        await settle(until: { turns(socket, containing: "3 unread.").count == 1 })
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1, "the result is said once, on this call")
        XCTAssertTrue(supervisor.jobs.first?.outcomeDelivered == true, "settled only once the socket took it")

        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: true)
        call.controller.flushPendingTextIfIdle()
        await settle(until: { false }, limit: .milliseconds(150))
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1, "never said twice")
        call.controller.stop()
    }

    /// The gap this fix closes: the notice lands while the call has no
    /// session at all (microphone prompt, the handshake). It must wait for
    /// the connection the setting promises, then be said once — not be
    /// dropped as if the call were Classic.
    func testANoticeArrivingBeforeTheAgentCallHasAConnectionIsKeptForTheReadyOne() async throws {
        let gate = GatedAvailability()
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor, availability: {
            await gate.wait()
            return .available(model: LocalLiveJobNoticeTests.model)
        })
        let starting = Task { await call.controller.start() }
        await settle(until: { call.controller.isActive })
        XCTAssertTrue(call.controller.isActive, "the call is up; the session isn't made yet")
        XCTAssertFalse(call.controller.sessionIsReady)
        XCTAssertFalse(call.controller.sessionRunsAgentTurns, "no session to ask")

        await finishAJob(supervisor)
        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: true)
        XCTAssertFalse(supervisor.jobs.first?.outcomeDelivered == true, "kept, not spent")
        XCTAssertTrue(call.sockets().isEmpty)

        gate.open()
        await starting.value
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)

        // Ready: the controller redelivers what it kept.
        await settle(until: { turns(socket, containing: "3 unread.").count == 1 })
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1, "said once, on the call it was kept for")
        call.controller.stop()
    }

    func testALocalLiveAgentCallKeepsTheResultUntilItsConnectionIsReady() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        await finishAJob(supervisor)

        // Still connecting: nothing can be sent, so nothing is spent.
        XCTAssertFalse(call.session.isReady)
        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: true)
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty)
        XCTAssertFalse(supervisor.jobs.first?.outcomeDelivered == true)

        // Ready: the result goes out then, once.
        try await makeReady(call.session, socket)
        call.controller.deliverPendingJobUpdates()
        await settle(until: { turns(socket, containing: "3 unread.").count == 1 })
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1)
        call.controller.stop()
    }

    /// A reconnect is a new connection to the same mode: the next ready
    /// session says the result once, and only then is it settled.
    func testALocalLiveAgentCallSaysTheResultOnceOnTheConnectionAfterAReconnect() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)

        // The socket drops mid-call.
        socket.close()
        await settle(until: { !call.session.isReady })
        await settle(until: { call.sockets().count > 1 })
        XCTAssertFalse(call.session.isReady, "the new socket is still handshaking")

        await finishAJob(supervisor)
        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: true)
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty, "never the dropped socket")
        XCTAssertFalse(supervisor.jobs.first?.outcomeDelivered == true, "kept while reconnecting")

        let next = try XCTUnwrap(call.sockets().last)
        try await makeReady(call.session, next)
        await settle(until: { turns(next, containing: "3 unread.").count == 1 })
        XCTAssertEqual(turns(next, containing: "3 unread.").count, 1)
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty)
        call.controller.stop()
    }

    /// A send the socket never took goes back in the queue, and its job is
    /// not settled: the next ready connection says it, once.
    func testALocalLiveAgentCallKeepsTheResultWhenTheSendFails() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)
        await finishAJob(supervisor)

        // The next send on this socket fails, as a socket that went away does.
        socket.upgradeRefusal = GeminiLiveServerClose(code: 1006, reason: "gone", isHTTPStatus: false)
        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: true)
        await settle(until: { call.controller.pendingTextTurnCountForTesting == 1 })
        // Claimed (outcomeDelivered) but in flight: the requeued turn keeps it.
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty)

        await settle(until: { call.sockets().count > 1 })
        let next = try XCTUnwrap(call.sockets().last)
        try await makeReady(call.session, next)
        await settle(until: { turns(next, containing: "3 unread.").count == 1 })
        XCTAssertEqual(turns(next, containing: "3 unread.").count, 1)
        call.controller.stop()
    }

    func testALocalLiveAgentCallHoldsTheResultWhileTheAudioIsPaused() async throws {
        struct AlarmRinging: Error {}
        let center = NotificationCenter()
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor, notificationCenter: center)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)

        call.input.startError = AlarmRinging()
        call.input.stop()
        call.input.onInterrupted?()
        XCTAssertTrue(call.controller.isAudioPausedForTesting)

        await finishAJob(supervisor)
        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: true)
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty, "nothing is said over the alarm")
        XCTAssertFalse(supervisor.jobs.first?.outcomeDelivered == true, "still pending, not spent")

        call.input.startError = nil
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        await settle(until: { !call.controller.isAudioPausedForTesting })
        call.controller.deliverPendingJobUpdates()
        await settle(until: { turns(socket, containing: "3 unread.").count == 1 })
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1)
        call.controller.stop()
    }

    /// Ending: the call is closing, so the notice stays pending for Hermes
    /// to report rather than going out into a goodbye.
    func testALocalLiveAgentCallHoldsTheResultWhileItIsEnding() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)

        call.controller.requestEnd()
        XCTAssertTrue(call.controller.isEnding)

        await finishAJob(supervisor)
        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: true)
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty)
        XCTAssertFalse(supervisor.jobs.first?.outcomeDelivered == true)
        XCTAssertEqual(call.controller.pendingTextTurnCountForTesting, 0, "not even queued for a call that is closing")
        call.controller.stop()
    }

    func testALocalLiveHermesTurnCallDropsTheNoticeWithoutSayingIt() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: false, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)
        await finishAJob(supervisor)

        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: false)
        await settle(until: { false }, limit: .milliseconds(150))
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty)
        XCTAssertTrue(supervisor.jobs.first?.outcomeDelivered == true, "consumed, as Classic always did")
        XCTAssertNil(supervisor.takePendingNotice(), "dropped, not left for another call")

        // A drop is not a queue: reconnecting doesn't replay it.
        socket.close()
        await settle(until: { call.sockets().count > 1 })
        let next = try XCTUnwrap(call.sockets().last)
        try await makeReady(call.session, next)
        call.controller.deliverPendingJobUpdates()
        await settle(until: { false }, limit: .milliseconds(150))
        XCTAssertTrue(turns(next, containing: "3 unread.").isEmpty, "never said on the next connection either")
        call.controller.stop()
    }

    /// Classic, still connecting: dropped as before — Hermes' reply is the
    /// Classic turn, so there is nothing to keep for it.
    func testALocalLiveClassicCallStillConnectingDropsTheNotice() async throws {
        let gate = GatedAvailability()
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: false, supervisor: supervisor, availability: {
            await gate.wait()
            return .available(model: LocalLiveJobNoticeTests.model)
        })
        let starting = Task { await call.controller.start() }
        await settle(until: { call.controller.isActive })
        XCTAssertFalse(call.controller.sessionIsReady, "no session yet")

        await finishAJob(supervisor)
        handlePendingNotice(call.controller, supervisor: supervisor, configuredAgent: false)
        XCTAssertTrue(supervisor.jobs.first?.outcomeDelivered == true, "consumed")
        XCTAssertNil(supervisor.takePendingNotice())

        gate.open()
        await starting.value
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)
        await settle(until: { false }, limit: .milliseconds(150))
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty, "never said on a Classic call")
        call.controller.stop()
    }
}
