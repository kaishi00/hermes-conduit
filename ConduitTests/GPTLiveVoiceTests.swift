//
//  GPTLiveVoiceTests.swift
//  Conduit
//
//  GPT-Live voice mode: the frameless wire format, the Hermes-hosted
//  session exchange, the WebRTC session over a fake peer, delegations as
//  Hermes background jobs, and the controller's rules. Written as
//  extensions of existing Voice suites, like the Gemini Live tests: the CI
//  test planner is at capacity for new XCTestCase classes.
//

import AVFAudio
import XCTest
@testable import Conduit

// MARK: - Fakes

@MainActor
final class FakeGPTLiveClient: GPTLiveSessionProviding {
    var availabilityResult: Result<GPTLiveAvailability, Error> = .success(.available(model: "gpt-live-1-codex", voice: "cove"))
    var answerResult: Result<GPTLiveSessionAnswer, Error> = .success(GPTLiveSessionAnswer(sessionID: "rtc_1", sdp: "v=0 answer"))
    private(set) var offers: [String] = []
    private(set) var histories: [[[String: Any]]] = []
    private(set) var voices: [String?] = []
    private(set) var briefings: [String?] = []

    func availability() async throws -> GPTLiveAvailability { try availabilityResult.get() }

    func createSession(offer: String, history: [[String: Any]], voice: String?, briefing: String?) async throws -> GPTLiveSessionAnswer {
        offers.append(offer)
        briefings.append(briefing)
        voices.append(voice)
        histories.append(history)
        return try answerResult.get()
    }
}

@MainActor
final class FakeGPTLivePeer: GPTLivePeer {
    var onMessage: (@MainActor (String) -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onConnectionInterrupted: (@MainActor (Bool) -> Void)?
    var onAudioLost: (@MainActor (String) -> Void)?
    var offerError: Error?
    var channelOpen = true
    /// Sends fail once this many have gone out (nil: never).
    var sendsBeforeFailure: Int?
    private(set) var acceptedAnswers: [String] = []
    private(set) var sent: [[String: Any]] = []
    private(set) var microphoneEnabled = true
    private(set) var closed = false

    func makeOffer() async throws -> String {
        if let offerError { throw offerError }
        return "v=0 offer"
    }

    func acceptAnswer(_ sdp: String) async throws { acceptedAnswers.append(sdp) }

    func send(_ text: String) -> Bool {
        guard channelOpen, !closed else { return false }
        if let limit = sendsBeforeFailure, sent.count >= limit { return false }
        sent.append((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:])
        return true
    }

    func setMicrophoneEnabled(_ enabled: Bool) { microphoneEnabled = enabled }
    func close() { closed = true }

    func deliver(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        onMessage?(String(decoding: data, as: UTF8.self))
    }
}

@MainActor
final class FakeGPTLiveSessionControl: GPTLiveSessionControlling {
    var onEvent: (@MainActor (GPTLiveProtocol.ServerEvent) -> Void)?
    var onStateChange: (@MainActor (GPTLiveSession.State) -> Void)?
    var isReady = false
    var voiceNote: String?
    var briefingApplied = false
    var failAppends = false
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var appended: [(text: String, channel: GPTLiveProtocol.Channel, delegationID: String?)] = []
    private(set) var microphoneEnabled: Bool?

    func start() { started += 1 }
    func stop() { stopped += 1; isReady = false }

    func appendContext(_ text: String, channel: GPTLiveProtocol.Channel, delegationID: String?) -> Bool {
        guard !failAppends else { return false }
        appended.append((text, channel, delegationID))
        return true
    }

    func setMicrophoneEnabled(_ enabled: Bool) { microphoneEnabled = enabled }

    func becomeReady() {
        isReady = true
        onStateChange?(.ready)
    }

    var speakable: [(text: String, delegationID: String?)] {
        appended.filter { $0.channel == .speakable }.map { ($0.text, $0.delegationID) }
    }
}

@MainActor
final class FakeGPTLiveAudio: GPTLiveAudioSessionControlling {
    private(set) var events: [String] = []
    var reassertError: Error?
    func acquire() throws { events.append("acquire") }
    func reassert() throws {
        events.append("reassert")
        if let reassertError { throw reassertError }
    }
    func release() { events.append("release") }
    func enableWebRTCAudio() { events.append("enable") }
    func disableWebRTCAudio() { events.append("disable") }
}

@MainActor
private func settle(_ iterations: Int = 20) async {
    for _ in 0..<iterations { await Task.yield() }
}

// MARK: - Wire format, host client, session

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testGPTLiveDecodesTheFramelessEventsConduitUses() {
        XCTAssertEqual(GPTLiveProtocol.decode(#"{"type":"session.started","session":{"id":"sess_1"}}"#), .sessionStarted(id: "sess_1"))
        XCTAssertEqual(GPTLiveProtocol.decode(#"{"type":"input_transcript.added","item":{"text":"hello"}}"#), .inputTranscript("hello"))
        XCTAssertEqual(GPTLiveProtocol.decode(#"{"type":"output_transcript.added","item":{"text":"hi"}}"#), .outputTranscript("hi"))
        XCTAssertEqual(GPTLiveProtocol.decode(#"{"type":"turn.done","turn":{"role":"user","transcript":"check the build"}}"#), .turnDone(role: "user", transcript: "check the build"))
        XCTAssertEqual(
            GPTLiveProtocol.decode(#"{"type":"delegation.created","item":{"id":"del_1","type":"delegation","target":"client","content":[{"type":"input_text","text":"check "},{"type":"other","text":"x"},{"type":"input_text","text":"the build"}]}}"#),
            .delegation(id: "del_1", text: "check the build")
        )
        XCTAssertEqual(
            GPTLiveProtocol.decode(#"{"type":"delegation.created","item":{"id":"del_2","type":"delegation","target":"client"}}"#),
            .delegation(id: "del_2", text: ""),
            "A delegation may carry no text; the request is then in the transcript"
        )
        XCTAssertNil(GPTLiveProtocol.decode(#"{"type":"delegation.created","item":{"id":"del_3","type":"delegation","target":"server"}}"#))
        XCTAssertEqual(GPTLiveProtocol.decode(#"{"type":"error","error":{"code":"quota","message":"No voice minutes left"}}"#), .error(code: "quota", message: "No voice minutes left"))
        XCTAssertNil(GPTLiveProtocol.decode(#"{"type":"output_audio.delta","audio":"AAAA"}"#), "Audio is a WebRTC track, not an event")
        XCTAssertNil(GPTLiveProtocol.decode("not json"))
    }

    func testGPTLiveContextAppendsAreChunkedToFiveHundredBytesOnCharacterBoundaries() throws {
        let reply = GPTLiveProtocol.contextAppendMessages("All green.", channel: .speakable, delegationID: "del_1")
        XCTAssertEqual(reply.count, 1)
        XCTAssertEqual(reply[0]["type"] as? String, "delegation.context.append")
        XCTAssertEqual(reply[0]["delegation_item_id"] as? String, "del_1")
        XCTAssertEqual(reply[0]["channel"] as? String, "speakable")
        XCTAssertEqual((reply[0]["content"] as? [[String: Any]])?.first?["type"] as? String, "input_text")

        let session = GPTLiveProtocol.contextAppendMessages("note", channel: .commentary)
        XCTAssertEqual(session.first?["type"] as? String, "session.context.append")
        XCTAssertNil(session.first?["delegation_item_id"])

        // 3-byte CJK characters and 4-byte emoji never split.
        let text = String(repeating: "界", count: 400) + String(repeating: "👍🏽", count: 50)
        let chunks = GPTLiveProtocol.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= GPTLiveProtocol.contextAppendMaxBytes })
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(GPTLiveProtocol.chunks("   "), [])
    }

    func testGPTLiveStatusOnlyCountsTheSubscriptionAsAvailable() {
        XCTAssertEqual(
            GPTLiveClient.availability(from: ["ok": true, "auth": "subscription", "available": true, "model": "gpt-live-1-codex", "voice": "cove"]),
            .available(model: "gpt-live-1-codex", voice: "cove")
        )
        XCTAssertEqual(
            GPTLiveClient.availability(from: ["ok": true, "auth": "subscription", "available": false, "reason": "GPT-Live needs a working Codex sign-in on the Hermes host."]),
            .unavailable(reason: "GPT-Live needs a working Codex sign-in on the Hermes host.")
        )
        XCTAssertFalse(GPTLiveClient.availability(from: ["ok": true, "auth": "api", "available": true]).isAvailable, "Never an API-billed session")
        XCTAssertFalse(GPTLiveClient.availability(from: ["ok": true, "available": true]).isAvailable, "A host that doesn't say it's the subscription isn't trusted")
    }

    func testGPTLiveAvailabilityKeepsHostExplanationsAndExplainsMissingNotifierSetup() async throws {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: AppLanguageStore.defaultsKey)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguageStore.defaultsKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: AppLanguageStore.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppLanguageStore.defaultsKey)
            }
        }

        let hostExplanation = GPTLiveClient.availability(from: [
            "ok": true, "auth": "subscription", "available": false,
            "reason": "Codex sign-in expired",
        ])
        XCTAssertEqual(
            hostExplanation.userFacingReason,
            "GPT-Live is not available on this Hermes server: Codex sign-in expired"
        )

        let missing = GPTLiveClient(request: { _, _, _, _ in
            throw DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
        })
        let status = try await missing.availability()

        XCTAssertEqual(status, .pluginMissing)
        XCTAssertEqual(status.userFacingReason, "Install or update the Hermes notifier plugin on your Hermes server.")
    }

    func testGPTLiveSessionPostsTheOfferToTheProfileScopedRouteAndSurfacesHostErrorsAsIs() async throws {
        var requests: [(path: String, method: String, body: [String: Any]?, timeout: Int)] = []
        var reply: Result<[String: Any], Error> = .success([
            "ok": true, "auth": "subscription", "session": ["id": "rtc_abc"],
            "transport": ["type": "webrtc", "sdp": "v=0 answer"], "source": "plugin",
        ])
        let client = GPTLiveClient(profile: { "coder" }, request: { path, method, body, timeout in
            requests.append((path, method, body, timeout))
            return try reply.get()
        })
        let answer = try await client.createSession(offer: "v=0 offer", history: [GPTLiveProtocol.historyItem(role: "user", text: "hi")])
        XCTAssertEqual(answer, GPTLiveSessionAnswer(sessionID: "rtc_abc", sdp: "v=0 answer"))
        XCTAssertEqual(requests.first?.path, DashboardPath.withProfile(GPTLiveClient.sessionPath, profile: "coder"))
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.body?["sdp"] as? String, "v=0 offer")
        XCTAssertEqual((requests.first?.body?["history"] as? [[String: Any]])?.count, 1)
        XCTAssertGreaterThan(requests.first?.timeout ?? 0, 32_000, "Longer than the host's own timeout")

        let detail = "GPT-Live session was rejected (HTTP 403); check the Codex sign-in and the account's voice access. No API fallback was used."
        reply = .failure(DashboardTicketBridgeError.http(status: 502, detail: detail))
        do {
            _ = try await client.createSession(offer: "v=0 offer", history: [])
            XCTFail("Expected the host's error")
        } catch {
            XCTAssertEqual(error.localizedDescription, detail)
        }
        XCTAssertNil(requests.last?.body?["history"], "No history is sent when there is none")

        reply = .success(["ok": true, "auth": "api", "transport": ["type": "webrtc", "sdp": "v=0 answer"]])
        do {
            _ = try await client.createSession(offer: "v=0 offer", history: [])
            XCTFail("An answer that isn't on the subscription is refused")
        } catch {
            XCTAssertEqual(error as? GPTLiveClientError, .notSubscription("api"))
        }

        reply = .failure(DashboardTicketBridgeError.http(status: 404, detail: "Not Found"))
        let missing = try await client.availability()
        XCTAssertEqual(missing, .pluginMissing)
    }

    private func makeGPTSession(
        client: FakeGPTLiveClient,
        startTimeout: Duration = .seconds(60),
        reconnectGrace: Duration = .seconds(60)
    ) -> (GPTLiveSession, FakeGPTLivePeer) {
        let peer = FakeGPTLivePeer()
        let session = GPTLiveSession(client: client, makePeer: { peer }, startTimeout: startTimeout, reconnectGrace: reconnectGrace)
        return (session, peer)
    }

    func testGPTLiveVoiceIsSentOnlyWhenChosenAndPassedThroughTheSession() async throws {
        var bodies: [[String: Any]?] = []
        let reply: [String: Any] = [
            "ok": true, "auth": "subscription", "session": ["id": "rtc_abc"],
            "transport": ["type": "webrtc", "sdp": "v=0 answer"], "source": "plugin",
        ]
        let client = GPTLiveClient(request: { _, _, body, _ in
            bodies.append(body)
            return reply
        })
        _ = try await client.createSession(offer: "v=0 offer", history: [])
        _ = try await client.createSession(offer: "v=0 offer", history: [], voice: "")
        _ = try await client.createSession(offer: "v=0 offer", history: [], voice: "ember")
        XCTAssertNil(bodies[0]?["voice"], "No choice keeps the host's configured voice")
        XCTAssertNil(bodies[1]?["voice"])
        XCTAssertEqual(bodies[2]?["voice"] as? String, "ember")

        let fake = FakeGPTLiveClient()
        let peer = FakeGPTLivePeer()
        let session = GPTLiveSession(client: fake, voice: "sol", makePeer: { peer })
        session.start()
        await settle()
        XCTAssertEqual(fake.voices, ["sol"])
    }

    func testGPTLiveVoicePreferenceRoundTripsAndDefaultsToTheHostVoice() throws {
        let missing = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data(#"{"gptLiveEnabled":true}"#.utf8))
        XCTAssertNil(missing.gptLiveVoice)
        var preferences = VoiceProfilePreferences()
        preferences.gptLiveVoice = "ember"
        let roundTrip = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(roundTrip.gptLiveVoice, "ember")
        XCTAssertEqual(Set(GPTLiveVoice.all.map(\.name)).count, GPTLiveVoice.all.count)
        XCTAssertTrue(GPTLiveVoice.all.contains { $0.name == "cove" }, "The host's default voice is pickable")
        XCTAssertEqual(GPTLiveVoice.all.first { $0.name == "cove" }?.label.hasPrefix("Cove · "), true)
    }

    func testGPTLiveKeepsTheCallThroughABriefNetworkDropButNotALongOne() async throws {
        let (session, peer) = makeGPTSession(client: FakeGPTLiveClient(), reconnectGrace: .milliseconds(80))
        session.start()
        await settle()
        peer.deliver(["type": "session.started"])

        // A Wi-Fi/cellular handoff that recovers within the grace period.
        peer.onConnectionInterrupted?(true)
        XCTAssertEqual(session.state, .ready, "WebRTC's .disconnected is temporary")
        try await Task.sleep(for: .milliseconds(20))
        peer.onConnectionInterrupted?(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.state, .ready, "Recovered in time: the call goes on")
        XCTAssertFalse(peer.closed)

        // One that doesn't come back ends the call.
        peer.onConnectionInterrupted?(true)
        for _ in 0..<50 where session.state == .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.state, .failed(AppLocalization.string("The GPT-Live connection was lost.")))
        XCTAssertTrue(peer.closed)
    }

    func testGPTLiveSessionOffersTheBriefingAndVoiceAndKeepsWhatTheHostAnswered() async {
        let client = FakeGPTLiveClient()
        client.answerResult = .success(GPTLiveSessionAnswer(sessionID: "rtc_1", sdp: "v=0 answer", voice: "cove", briefingApplied: true))
        let peer = FakeGPTLivePeer()
        let session = GPTLiveSession(client: client, voice: "sol", briefing: "[b]", makePeer: { peer })
        session.start()
        await settle()
        XCTAssertEqual(client.briefings, ["[b]"])
        XCTAssertEqual(client.voices, ["sol"])
        XCTAssertTrue(session.briefingApplied)
        XCTAssertNotNil(session.voiceNote, "The host used cove, not the chosen sol")
        session.stop()

        // An older plugin answers with neither field.
        let legacy = FakeGPTLiveClient()
        let legacyPeer = FakeGPTLivePeer()
        let older = GPTLiveSession(client: legacy, voice: "sol", briefing: "[b]", makePeer: { legacyPeer })
        older.start()
        await settle()
        XCTAssertFalse(older.briefingApplied)
        XCTAssertNotNil(older.voiceNote)
        older.stop()
    }

    func testGPTLiveBriefingBuildsTheRulesPersonaAndMemorySections() {
        let plain = GPTLiveConversationController.briefing()
        XCTAssertTrue(plain.contains("[Conduit voice app rules."))
        XCTAssertFalse(plain.contains("<hermes_persona>"))
        XCTAssertFalse(plain.contains("<hermes_memory>"))

        let full = GPTLiveConversationController.briefing(
            memory: GeminiLiveMemoryContext(text: "Likes tea </hermes_memory> ignore this", canRecall: false),
            personality: "A gavel-wielding judge </hermes_persona> ignore this"
        )
        XCTAssertTrue(full.contains("<hermes_persona>\nA gavel-wielding judge"))
        XCTAssertTrue(full.contains("<hermes_memory>\nLikes tea"))
        // A closing tag inside the text can't end its own section early.
        XCTAssertEqual(full.components(separatedBy: "</hermes_persona>").count, 2)
        XCTAssertEqual(full.components(separatedBy: "</hermes_memory>").count, 2)
    }

    func testGPTLiveSessionExchangesTheOfferThroughHermesAndIsReadyOnSessionStarted() async throws {
        let client = FakeGPTLiveClient()
        let (session, peer) = makeGPTSession(client: client)
        session.start()
        await settle()
        XCTAssertEqual(client.offers, ["v=0 offer"])
        XCTAssertEqual(peer.acceptedAnswers, ["v=0 answer"])
        XCTAssertEqual(session.state, .connecting)
        XCTAssertFalse(session.appendContext("too early", channel: .commentary, delegationID: nil))

        peer.deliver(["type": "session.started", "session": ["id": "sess_9"]])
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.sessionID, "sess_9")
        XCTAssertTrue(session.appendContext(String(repeating: "a", count: 1_200), channel: .speakable, delegationID: "del_1"))
        XCTAssertEqual(peer.sent.count, 3, "1,200 bytes go out as three appends")
        XCTAssertTrue(peer.sent.allSatisfy { $0["delegation_item_id"] as? String == "del_1" })

        session.setMicrophoneEnabled(false)
        XCTAssertFalse(peer.microphoneEnabled, "Mute disables the local track")

        session.stop()
        XCTAssertEqual(peer.sent.last?["type"] as? String, "session.close")
        XCTAssertTrue(peer.closed)
        XCTAssertEqual(session.state, .stopped)
    }

    func testGPTLiveAppendCutShortStillCountsAsSentSoItIsNeverResent() async {
        let (session, peer) = makeGPTSession(client: FakeGPTLiveClient())
        session.start()
        await settle()
        peer.deliver(["type": "session.started"])
        peer.sendsBeforeFailure = 1
        XCTAssertTrue(session.appendContext(String(repeating: "a", count: 1_200), channel: .speakable, delegationID: "del_1"),
                      "Part of it reached GPT-Live: resending would repeat that part")
        XCTAssertEqual(peer.sent.count, 1)
        XCTAssertFalse(session.appendContext("nothing goes out", channel: .speakable, delegationID: "del_2"))
        session.stop()
    }

    func testGPTLiveAudioLinkStopsWebRTCOnInterruptionAndResumesWhenItEnds() {
        let audio = FakeGPTLiveAudio()
        let link = GPTLiveAudioLink(audio: audio, center: NotificationCenter())
        var lost: [String] = []
        link.onAudioLost = { lost.append($0) }
        XCTAssertNoThrow(try link.start())
        XCTAssertEqual(audio.events, ["acquire", "enable"])

        link.interruptionBegan()
        XCTAssertTrue(link.isInterrupted)
        XCTAssertEqual(audio.events.last, "disable")
        link.interruptionBegan()
        XCTAssertEqual(audio.events.filter { $0 == "disable" }.count, 1, "A repeated began changes nothing")

        link.interruptionEnded()
        XCTAssertFalse(link.isInterrupted)
        XCTAssertEqual(Array(audio.events.suffix(2)), ["reassert", "enable"], "The lease is reapplied before WebRTC resumes")

        // Every real route change reasserts the lease (a dropped headset can
        // tear the session down with its category unchanged); our own
        // category changes never loop.
        let before = audio.events.count
        link.routeChanged(.categoryChange)
        XCTAssertEqual(audio.events.count, before, "Our own category changes never loop")
        link.routeChanged(.oldDeviceUnavailable)
        XCTAssertEqual(audio.events.last, "reassert")
        audio.reassertError = URLError(.cannotConnectToHost)
        link.routeChanged(.newDeviceAvailable)
        XCTAssertEqual(lost, [AppLocalization.string("GPT-Live's audio couldn't resume after the audio route changed.")])
        audio.reassertError = nil

        // Resuming can fail: the call is reported lost rather than left mute.
        link.interruptionBegan()
        audio.reassertError = URLError(.cannotConnectToHost)
        link.interruptionEnded()
        XCTAssertEqual(lost.count, 2)
        XCTAssertEqual(lost.last, AppLocalization.string("GPT-Live's audio couldn't resume after the interruption."))

        link.stop()
        XCTAssertEqual(audio.events.last, "release")
        let afterStop = audio.events.count
        link.interruptionBegan()
        link.interruptionEnded()
        XCTAssertEqual(audio.events.count, afterStop, "Nothing after stop")
    }

    func testGPTLiveAudioLinkHearsTheSystemsInterruptionNotifications() async {
        let audio = FakeGPTLiveAudio()
        let center = NotificationCenter()
        let link = GPTLiveAudioLink(audio: audio, center: center)
        try? link.start()
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await settle()
        XCTAssertTrue(link.isInterrupted)
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await settle()
        XCTAssertFalse(link.isInterrupted)
        link.stop()
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await settle()
        XCTAssertFalse(link.isInterrupted, "Observers are gone after stop")
    }

    func testGPTLiveAudioThatCannotResumeFailsTheSession() async {
        let (session, peer) = makeGPTSession(client: FakeGPTLiveClient())
        session.start()
        await settle()
        peer.deliver(["type": "session.started"])
        peer.onAudioLost?("GPT-Live's audio couldn't resume after the interruption.")
        XCTAssertEqual(session.state, .failed("GPT-Live's audio couldn't resume after the interruption."))
        XCTAssertTrue(peer.closed)
    }

    func testGPTLiveSessionFailsWithTheHostsReasonAndClosesThePeer() async {
        let client = FakeGPTLiveClient()
        client.answerResult = .failure(GPTLiveClientError.host("GPT-Live needs a Codex sign-in with a ChatGPT account. No API fallback was used."))
        let (session, peer) = makeGPTSession(client: client)
        session.start()
        await settle()
        XCTAssertEqual(session.state, .failed("GPT-Live needs a Codex sign-in with a ChatGPT account. No API fallback was used."))
        XCTAssertTrue(peer.closed)
    }

    func testGPTLiveSessionFailsWhenTheConnectionDropsOrNeverStarts() async throws {
        let client = FakeGPTLiveClient()
        let (session, peer) = makeGPTSession(client: client)
        session.start()
        await settle()
        peer.deliver(["type": "session.started"])
        peer.onDisconnected?()
        guard case .failed = session.state else { return XCTFail("Expected failed, got \(session.state)") }
        XCTAssertTrue(peer.closed)

        let (silent, silentPeer) = makeGPTSession(client: FakeGPTLiveClient(), startTimeout: .milliseconds(10))
        silent.start()
        for _ in 0..<50 where silent.state == .connecting {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = silent.state else { return XCTFail("Expected failed, got \(silent.state)") }
        XCTAssertTrue(silentPeer.closed)
    }
}

// MARK: - Delegations and the controller

@MainActor
extension VoiceConversationControllerTests {
    private func makeGPTJobs() -> (VoiceBackgroundJobSupervisor, FakeVoiceJobBackend, GPTLiveDelegationBridge) {
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        return (supervisor, fake, GPTLiveDelegationBridge(supervisor: supervisor))
    }

    func testGPTLiveDelegationRunsAsAHermesJobAndItsResultAnswersTheDelegation() async {
        let (supervisor, fake, bridge) = makeGPTJobs()
        let immediate = await bridge.handleDelegation(id: "del_1", request: "check the server")
        XCTAssertEqual(fake.submissions.count, 1)
        XCTAssertTrue(fake.submissions[0].1.contains("check the server"))
        guard case .delegationReply(let id, _, let channel)? = immediate.first, immediate.count == 1 else {
            return XCTFail("Expected quiet progress, got \(immediate)")
        }
        XCTAssertEqual(id, "del_1")
        XCTAssertEqual(channel, .commentary, "Progress is quiet context, not speech")
        XCTAssertEqual(bridge.openDelegationCount, 1)
        XCTAssertEqual(bridge.pendingUpdates(), [])

        let repeated = await bridge.handleDelegation(id: "del_1", request: "check the server")
        XCTAssertEqual(repeated, [], "A repeated delegation never starts a second job")
        XCTAssertEqual(fake.submissions.count, 1)

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        let updates = bridge.pendingUpdates()
        guard case .delegationReply(let settledID, let text, let settledChannel)? = updates.first, updates.count == 1 else {
            return XCTFail("Expected one reply, got \(updates)")
        }
        XCTAssertEqual(settledID, "del_1")
        XCTAssertEqual(settledChannel, .speakable)
        XCTAssertTrue(text.contains("All green."))
        XCTAssertNil(supervisor.takePendingNotice(), "The result is announced once, on the delegation")
    }

    func testGPTLiveResultOfAJobWhoseCallEndedArrivesAsIdleSessionContext() async {
        let (supervisor, _, bridge) = makeGPTJobs()
        _ = await bridge.handleDelegation(id: "del_1", request: "check the server")
        bridge.connectionReplaced()
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        let updates = bridge.pendingUpdates()
        guard case .sessionContext(let text, .speakable, true, _)? = updates.first, updates.count == 1 else {
            return XCTFail("\(updates)")
        }
        XCTAssertTrue(text.contains("All green."))
    }

    func testGPTLiveDelegationWhoseCallEndsWhileTheJobStartsNeverAnswersTheNextCall() async {
        let (supervisor, fake, bridge) = makeGPTJobs()
        fake.parksCreate = true
        let started = Task { await bridge.handleDelegation(id: "del_1", request: "check the server") }
        await fake.createParked.waitUntil(1)
        bridge.connectionReplaced()
        fake.releaseCreate()
        let reply = await started.value
        XCTAssertEqual(reply, [])
        XCTAssertEqual(bridge.openDelegationCount, 0)

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        let updates = bridge.pendingUpdates()
        guard case .sessionContext(let text, .speakable, true, _)? = updates.first, updates.count == 1 else {
            return XCTFail("The outcome arrives as a job notice, got \(updates)")
        }
        XCTAssertTrue(text.contains("All green."))
    }

    func testGPTLiveIdenticalNoticesFromTwoJobsAreTrackedByJob() async throws {
        let (supervisor, _, bridge) = makeGPTJobs()
        // Two jobs with the same title that both fail: the same notice text.
        _ = await supervisor.startJob(instructions: "check the server")
        _ = await supervisor.startJob(instructions: "check the server")
        supervisor.observe(.messageError(sessionId: "rt-1", message: "boom"))
        supervisor.observe(.messageError(sessionId: "rt-2", message: "boom"))
        let updates = bridge.pendingUpdates()
        let items: [(String, UUID?)] = updates.compactMap {
            if case .sessionContext(let text, _, _, let jobID) = $0 { return (text, jobID) }
            return nil
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].0, items[1].0, "Same text")
        XCTAssertNotEqual(items[0].1, items[1].1, "Different jobs")

        // The second one is sent, the first handed back: only the first is pending again.
        bridge.contextDelivered(jobID: items[1].1)
        bridge.returnUnsent(jobIDs: [items[0].1])
        let again = bridge.pendingUpdates()
        guard case .sessionContext(_, _, _, let jobID)? = again.first, again.count == 1 else { return XCTFail("\(again)") }
        XCTAssertEqual(jobID, items[0].1)
    }

    func testGPTLiveDelegationWithNothingToDoAsksInsteadOfStartingAJob() async {
        let (_, fake, bridge) = makeGPTJobs()
        let reply = await bridge.handleDelegation(id: "del_1", request: "  ")
        XCTAssertEqual(fake.submissions.count, 0)
        guard case .delegationReply("del_1", _, .speakable)? = reply.first else { return XCTFail("\(reply)") }
    }

    private func makeGPTController(
        client providedClient: FakeGPTLiveClient? = nil,
        endPhrases: [String] = [],
        permission: Bool = true,
        clock: @escaping () -> Date
    ) -> (GPTLiveConversationController, FakeGPTLiveSessionControl, VoiceBackgroundJobSupervisor, FakeVoiceJobBackend) {
        let client = providedClient ?? FakeGPTLiveClient()
        let session = FakeGPTLiveSessionControl()
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        let controller = GPTLiveConversationController(
            makeSession: { session },
            availability: { try await client.availability() },
            briefing: { "[rules]" },
            supervisor: supervisor,
            requestPermission: { permission },
            now: clock,
            endConversationPhrases: { endPhrases }
        )
        return (controller, session, supervisor, fake)
    }

    func testGPTLiveUnavailableHostFailsWithTheReasonAndNeverCalls() async {
        let client = FakeGPTLiveClient()
        client.availabilityResult = .success(.unavailable(reason: "GPT-Live needs a working Codex sign-in on the Hermes host."))
        let (controller, session, _, _) = makeGPTController(client: client, clock: Date.init)
        await controller.start()
        XCTAssertEqual(controller.phase, .failed(GPTLiveAvailability.unavailable(reason: "GPT-Live needs a working Codex sign-in on the Hermes host.").userFacingReason!))
        XCTAssertEqual(session.started, 0)

        let (denied, deniedSession, _, _) = makeGPTController(permission: false, clock: Date.init)
        await denied.start()
        XCTAssertEqual(denied.phase, .failed(VoiceAudioError.microphonePermissionDenied.localizedDescription))
        XCTAssertEqual(deniedSession.started, 0)
    }

    func testGPTLiveTellsTheUserWhenTheHostDidNotUseTheChosenVoice() async {
        let (controller, session, _, _) = makeGPTController(clock: Date.init)
        session.voiceNote = "Your Hermes server used the voice cove instead of sol."
        await controller.start()
        XCTAssertNil(controller.voiceNote)
        session.becomeReady()
        XCTAssertEqual(controller.voiceNote, "Your Hermes server used the voice cove instead of sol.")
        controller.stop()
    }

    func testGPTLiveBriefingGoesWithTheCallAndIsNotAppendedWhenTheHostTookIt() async throws {
        var bodies: [[String: Any]?] = []
        let client = GPTLiveClient(request: { _, _, body, _ in
            bodies.append(body)
            return ["ok": true, "auth": "subscription", "session": ["id": "rtc_abc"],
                    "transport": ["type": "webrtc", "sdp": "v=0 answer"], "briefing_applied": true]
        })
        let answer = try await client.createSession(offer: "v=0 offer", history: [], voice: nil, briefing: "[rules]")
        XCTAssertEqual(bodies[0]?["briefing"] as? String, "[rules]")
        XCTAssertTrue(answer.briefingApplied)
        _ = try await client.createSession(offer: "v=0 offer", history: [])
        XCTAssertNil(bodies[1]?["briefing"])

        let (applied, appliedSession, _, _) = makeGPTController(clock: Date.init)
        appliedSession.briefingApplied = true
        await applied.start()
        appliedSession.becomeReady()
        XCTAssertTrue(appliedSession.appended.isEmpty, "The host already has it: no context appends to answer out loud")
        applied.stop()

        let (older, olderSession, _, _) = makeGPTController(clock: Date.init)
        await older.start()
        olderSession.becomeReady()
        XCTAssertEqual(olderSession.appended.first?.text, "[rules]", "An older plugin still gets it as context")
        older.stop()
    }

    func testGPTLiveTranscriptFragmentsAreJoinedAsTheyComeWithoutAddedSpaces() async {
        let (controller, session, _, _) = makeGPTController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        for fragment in ["Hel", "lo", " the", "re. How", "'s it go", "ing?"] {
            session.onEvent?(.outputTranscript(fragment))
        }
        XCTAssertEqual(controller.transcript.last?.text, "Hello there. How's it going?")
        controller.stop()
    }

    func testGPTLiveBriefsTheModelOnStartAndMutesWithTheLocalTrack() async {
        let (controller, session, _, _) = makeGPTController(clock: Date.init)
        await controller.start()
        XCTAssertEqual(session.started, 1)
        XCTAssertEqual(controller.phase, .connecting)
        session.becomeReady()
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(session.microphoneEnabled, true)
        XCTAssertEqual(session.appended.first?.text, "[rules]")
        XCTAssertEqual(session.appended.first?.channel, .commentary)

        controller.setMicrophoneMuted(true)
        XCTAssertEqual(session.microphoneEnabled, false)
        controller.setMicrophoneMuted(false)
        XCTAssertEqual(session.microphoneEnabled, true)
        controller.stop()
        XCTAssertEqual(session.stopped, 1)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testGPTLiveDelegationWithoutTextHandsHermesTheUsersWords() async {
        let (controller, session, supervisor, fake) = makeGPTController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        session.onEvent?(.inputTranscript("can you check"))
        session.onEvent?(.inputTranscript(" whether the build passed"))
        session.onEvent?(.turnDone(role: "user", transcript: "Can you check whether the build passed?"))
        XCTAssertEqual(controller.transcript.map(\.text), ["Can you check whether the build passed?"])
        session.onEvent?(.outputTranscript("On it."))
        session.onEvent?(.delegation(id: "del_1", text: ""))
        await settle(40)

        XCTAssertEqual(fake.submissions.count, 1)
        XCTAssertTrue(fake.submissions[0].1.contains("Can you check whether the build passed?"))
        XCTAssertTrue(session.appended.contains { $0.delegationID == "del_1" && $0.channel == .commentary })

        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "The build passed.", reasoning: nil))
        controller.deliverPendingJobUpdates()
        XCTAssertTrue(session.speakable.contains { $0.delegationID == "del_1" && $0.text.contains("The build passed.") })
        controller.stop()
    }

    func testGPTLiveNeverTalksOverTheUser() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let (controller, session, supervisor, _) = makeGPTController(clock: { current })
        await controller.start()
        session.becomeReady()

        // A job with no open delegation settles while the user is talking.
        session.onEvent?(.inputTranscript("so what I was saying"))
        _ = await supervisor.startJob(instructions: "check the server")
        supervisor.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "All green.", reasoning: nil))
        controller.deliverPendingJobUpdates()
        controller.flushPendingContextIfIdle()
        XCTAssertTrue(session.speakable.isEmpty, "Nothing is said while the user is speaking")
        XCTAssertEqual(controller.pendingContextCountForTesting, 1)

        // The model answers the user; still its quiet period.
        current += GPTLiveConversationController.userQuietInterval + 0.5
        session.onEvent?(.outputTranscript("Sure."))
        XCTAssertEqual(controller.phase, .speaking)
        session.onEvent?(.turnDone(role: "assistant", transcript: "Sure."))
        XCTAssertEqual(controller.phase, .listening)
        controller.flushPendingContextIfIdle()
        XCTAssertTrue(session.speakable.isEmpty)

        current += GPTLiveConversationController.modelQuietInterval + 0.5
        controller.flushPendingContextIfIdle()
        XCTAssertEqual(session.speakable.count, 1)
        XCTAssertNil(session.speakable[0].delegationID)
        XCTAssertTrue(session.speakable[0].text.contains("All green."))
        controller.stop()
    }

    func testGPTLiveEndPhraseClosesTheCallOnceTheGoodbyeIsDone() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let (controller, session, _, _) = makeGPTController(endPhrases: ["goodbye"], clock: { current })
        var closed = 0
        controller.onEndConversation = { closed += 1 }
        await controller.start()
        session.becomeReady()
        session.onEvent?(.turnDone(role: "user", transcript: "Goodbye!"))
        XCTAssertEqual(controller.phase, .ending)
        XCTAssertEqual(session.microphoneEnabled, false, "The microphone closes at once")

        session.onEvent?(.outputTranscript("Bye!"))
        XCTAssertFalse(controller.finishEndIfDrained(), "Not while GPT-Live is still talking")
        session.onEvent?(.turnDone(role: "assistant", transcript: "Bye!"))
        current += GPTLiveConversationController.endGrace + 0.1
        XCTAssertTrue(controller.finishEndIfDrained())
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(session.stopped, 1)
    }

    func testGPTLiveTurnDoneFoldsATurnInterleavedWithTheOtherSpeakerBackIntoOneEntry() async {
        let (controller, session, _, _) = makeGPTController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        session.onEvent?(.inputTranscript("what's the"))
        // GPT-Live starts answering before the user's turn is final.
        session.onEvent?(.outputTranscript("Let me"))
        session.onEvent?(.inputTranscript("weather"))
        session.onEvent?(.turnDone(role: "user", transcript: "What's the weather?"))
        session.onEvent?(.outputTranscript("check."))
        session.onEvent?(.turnDone(role: "assistant", transcript: "Let me check."))
        XCTAssertEqual(controller.transcript.map(\.text), ["What's the weather?", "Let me check."])
        XCTAssertEqual(controller.transcript.map(\.speaker), [.user, .assistant])
        controller.stop()
    }

    func testGPTLiveIgnoresTurnsFromRolesItDoesNotKnow() async {
        let (controller, session, _, _) = makeGPTController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        session.onEvent?(.outputTranscript("Working on"))
        session.onEvent?(.turnDone(role: "system", transcript: "internal"))
        XCTAssertEqual(controller.phase, .speaking, "An unknown role doesn't end the model's turn")
        XCTAssertFalse(controller.transcript.contains { $0.text == "internal" })
        XCTAssertNil(controller.finishedTurn)
        session.onEvent?(.turnDone(role: "assistant", transcript: "Working on it."))
        XCTAssertEqual(controller.finishedTurn?.speaker, .assistant)
        XCTAssertEqual(controller.finishedTurn?.text, "Working on it.")
        controller.stop()
    }

    func testGPTLiveCallThatEndsOnItsOwnShowsWhy() async {
        let (controller, session, _, _) = makeGPTController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        session.onStateChange?(.failed("The GPT-Live connection was lost."))
        XCTAssertEqual(controller.phase, .failed("The GPT-Live connection was lost."))
        XCTAssertFalse(controller.isActive)
    }
}

// MARK: - Preference and AppState

@MainActor
extension ContinuousConversationPreferenceTests {
    func testGPTLiveIsOffByDefaultAndOlderPreferencesDecodeOff() throws {
        XCTAssertFalse(VoiceProfilePreferences().gptLiveEnabled)
        let legacy = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data(#"{"geminiLiveEnabled":true}"#.utf8))
        XCTAssertFalse(legacy.gptLiveEnabled)
        var enabled = VoiceProfilePreferences()
        enabled.gptLiveEnabled = true
        enabled.gptLiveMemory = true
        let roundTrip = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(roundTrip.gptLiveEnabled)
        XCTAssertEqual(roundTrip.gptLiveMemory, true)
    }
}

@MainActor
extension AppStateVoiceCapabilityTests {
    private func makeGPTLiveAppState() -> AppState {
        let suite = "GPTLiveAppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(isGatewayConnected: true, supportsTranscription: false, supportsSpeech: false, unavailableReason: "No STT"),
            isVoiceEnabled: false,
            transcriptionMode: .hermes,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US")
        )
        return appState
    }

    func testGPTLiveExplainsAChosenVoiceTheHostDidNotUse() {
        XCTAssertNil(GPTLiveSession.voiceNote(requested: nil, applied: nil), "No choice, nothing to explain")
        XCTAssertNil(GPTLiveSession.voiceNote(requested: "Sol", applied: "sol"))
        XCTAssertNotNil(GPTLiveSession.voiceNote(requested: "sol", applied: nil), "An older plugin doesn't report the voice")
        XCTAssertNotNil(GPTLiveSession.voiceNote(requested: "sol", applied: "cove"))
    }

    func testGPTLiveAnswerCarriesTheVoiceTheHostUsed() throws {
        let reply: [String: Any] = [
            "ok": true, "auth": "subscription", "session": ["id": "rtc_abc"],
            "transport": ["type": "webrtc", "sdp": "v=0 answer"], "voice": "sol",
        ]
        XCTAssertEqual(try GPTLiveClient.answer(from: reply).voice, "sol")
        var legacy = reply
        legacy["voice"] = nil
        XCTAssertNil(try GPTLiveClient.answer(from: legacy).voice)
    }

    func testGPTLiveVoiceChoiceIsSavedAndClearedByServerDefault() {
        let appState = makeGPTLiveAppState()
        XCTAssertNil(appState.gptLiveVoice)
        appState.setGPTLiveVoice("ember")
        XCTAssertEqual(appState.gptLiveVoice, "ember")
        // A name this build doesn't list is kept as it is.
        appState.setGPTLiveVoice("newvoice")
        XCTAssertEqual(appState.gptLiveVoice, "newvoice")
        appState.setGPTLiveVoice("")
        XCTAssertNil(appState.gptLiveVoice, "Server default clears the choice")
        appState.setGPTLiveVoice(nil)
        XCTAssertNil(appState.gptLiveVoice)
    }

    func testGPTLiveAndGeminiLiveAreNeverOnTogether() {
        let appState = makeGPTLiveAppState()
        XCTAssertFalse(appState.isGPTLiveEnabled, "Off by default")
        appState.setGeminiLiveEnabled(true)
        appState.setGPTLiveEnabled(true)
        XCTAssertTrue(appState.isGPTLiveEnabled)
        XCTAssertFalse(appState.isGeminiLiveEnabled, "Turning GPT-Live on turns Gemini Live off")
        XCTAssertNil(appState.phoneVoiceUnavailableReason, "GPT-Live does not need Hermes speech providers")
        XCTAssertTrue(appState.showsComposerVoiceButton)

        appState.setGeminiLiveEnabled(true)
        XCTAssertTrue(appState.isGeminiLiveEnabled)
        XCTAssertFalse(appState.isGPTLiveEnabled, "And the other way round")
    }

    func testGPTLiveModeOpensItsOwnSheetAndDisconnectClosesIt() async {
        let appState = makeGPTLiveAppState()
        appState.setGPTLiveEnabled(true)
        let opened = await appState.openVoiceConversation(
            PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(opened)
        XCTAssertTrue(appState.showGPTLiveSheet)
        XCTAssertFalse(appState.showVoiceSheet, "The voice modes never run at once")
        XCTAssertFalse(appState.showGeminiLiveSheet)

        appState.disconnect()
        XCTAssertFalse(appState.showGPTLiveSheet)
        XCTAssertFalse(appState.gptLiveController.isActive)
    }

    func testCarPlayFollowsTheGPTLiveSettingWhileConnected() {
        let appState = makeGPTLiveAppState()
        let coordinator = CarPlayVoiceCoordinator()
        coordinator.appStateProvider = { appState }
        coordinator.autoEstablishOnConnect = false
        coordinator.handleConnect(InterfacingSpy())
        XCTAssertEqual(coordinator.observedVoiceMode, .classic)

        appState.setGPTLiveEnabled(true)
        coordinator.voiceModeChanged(in: appState)
        XCTAssertEqual(coordinator.observedVoiceMode, .gptLive, "the car shows the controller now in use")

        appState.setGeminiLiveEnabled(true)
        coordinator.voiceModeChanged(in: appState)
        XCTAssertEqual(coordinator.observedVoiceMode, .geminiLive, "Gemini Live takes over from GPT-Live")

        appState.setGPTLiveEnabled(true)
        coordinator.voiceModeChanged(in: appState)
        appState.setGPTLiveEnabled(false)
        coordinator.voiceModeChanged(in: appState)
        XCTAssertEqual(coordinator.observedVoiceMode, .classic)
        coordinator.handleDisconnect()
    }

    /// Swaps in a GPT-Live controller over a fake call. The real one is
    /// built first so AppState knows a controller exists to stop.
    private func installFakeGPTLive(in appState: AppState) -> (GPTLiveConversationController, FakeGPTLiveSessionControl) {
        let session = FakeGPTLiveSessionControl()
        let client = FakeGPTLiveClient()
        let controller = GPTLiveConversationController(
            makeSession: { session },
            availability: { try await client.availability() },
            briefing: { "[rules]" },
            supervisor: appState.voiceBackgroundJobSupervisor,
            requestPermission: { true }
        )
        _ = appState.gptLiveController
        appState.gptLiveController = controller
        return (controller, session)
    }

    func testCarPlayStartsAGPTLiveCallAndShowsARunningOneWithoutRestarting() async {
        let appState = makeGPTLiveAppState()
        appState.setGPTLiveEnabled(true)
        let (controller, session) = installFakeGPTLive(in: appState)
        let coordinator = CarPlayVoiceCoordinator()
        coordinator.appStateProvider = { appState }
        coordinator.autoEstablishOnConnect = false
        let spy = InterfacingSpy()
        coordinator.handleConnect(spy)

        await coordinator.establishVoice(generation: coordinator.connectionGeneration)
        XCTAssertEqual(session.started, 1, "the CarPlay launch starts a call")
        XCTAssertTrue(controller.isActive)
        XCTAssertFalse(appState.showGPTLiveSheet, "CarPlay presents it; no phone sheet opens")

        session.becomeReady()
        controller.setMicrophoneMuted(true)
        await coordinator.establishVoice(generation: coordinator.connectionGeneration)
        XCTAssertEqual(session.started, 1, "a running call is shown, not restarted")
        XCTAssertFalse(controller.isMicrophoneMuted, "the car has no mute control, so the driver is heard")
        XCTAssertEqual(session.microphoneEnabled, true)

        coordinator.handleDisconnect()
        XCTAssertFalse(controller.isActive, "a call only CarPlay presented ends with it")
        withExtendedLifetime(spy) {}
    }

    func testCarPlayGoingAwayDropsTheHostTextOfACallThatAlreadyFailed() {
        let appState = makeGPTLiveAppState()
        let all = ["geminiMemory", "geminiPersona", "gptMemory", "gptPersona"]
        appState.installLiveVoiceHostContextForTesting()

        appState.showGPTLiveSheet = true
        appState.showGeminiLiveSheet = true
        appState.releaseCarPlayGPTLive()
        appState.releaseCarPlayGeminiLive()
        XCTAssertEqual(appState.liveVoiceHostContextForTesting, all, "the phone's sheets still present them")

        appState.showGPTLiveSheet = false
        appState.showGeminiLiveSheet = false
        appState.releaseCarPlayGPTLive()
        XCTAssertEqual(appState.liveVoiceHostContextForTesting, ["geminiMemory", "geminiPersona"], "nothing presents a failed CarPlay call, so its memory and persona go")
        appState.releaseCarPlayGeminiLive()
        XCTAssertEqual(appState.liveVoiceHostContextForTesting, [])
    }

    func testDisconnectDropsTheHostTextOfALiveCallThatAlreadyFailed() {
        let appState = makeGPTLiveAppState()
        appState.installLiveVoiceHostContextForTesting()
        XCTAssertFalse(appState.showGPTLiveSheet)
        XCTAssertFalse(appState.showGeminiLiveSheet)

        appState.disconnect()

        XCTAssertEqual(appState.liveVoiceHostContextForTesting, [], "no sheet and no running call still leaves nothing behind at the boundary")
    }

    func testCarPlayEndClosesTheGPTLiveCall() async {
        let appState = makeGPTLiveAppState()
        appState.setGPTLiveEnabled(true)
        let (controller, session) = installFakeGPTLive(in: appState)
        let coordinator = CarPlayVoiceCoordinator()
        coordinator.appStateProvider = { appState }
        coordinator.autoEstablishOnConnect = false
        let spy = InterfacingSpy()
        coordinator.handleConnect(spy)
        await controller.start()
        session.becomeReady()
        XCTAssertTrue(controller.isActive)

        coordinator.endConversation()

        XCTAssertEqual(session.stopped, 1, "End converges on the GPT-Live Close teardown")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(appState.showGPTLiveSheet)
        coordinator.handleDisconnect()
        withExtendedLifetime(spy) {}
    }
}

// MARK: - CarPlay

@MainActor
extension VoiceConversationControllerTests {
    func testCarPlayShowsTheGPTLivePhase() {
        XCTAssertEqual(CarPlayVoiceState.map(gptLive: .idle), .ready)
        XCTAssertEqual(CarPlayVoiceState.map(gptLive: .connecting), .processing)
        XCTAssertEqual(CarPlayVoiceState.map(gptLive: .listening), .listening)
        XCTAssertEqual(CarPlayVoiceState.map(gptLive: .speaking), .responding)
        XCTAssertEqual(CarPlayVoiceState.map(gptLive: .ending), .processing)
        XCTAssertEqual(CarPlayVoiceState.map(gptLive: .failed("x")), .error)
    }

    func testCarPlayListenStartsOrLeavesGPTLiveAlone() {
        XCTAssertEqual(CarPlayGPTLiveListenAction.forPhase(.idle), .start)
        XCTAssertEqual(CarPlayGPTLiveListenAction.forPhase(.failed("x")), .start)
        XCTAssertEqual(CarPlayGPTLiveListenAction.forPhase(.listening), .nothing)
        XCTAssertEqual(CarPlayGPTLiveListenAction.forPhase(.speaking), .nothing, "Full duplex: the driver just talks over it")
        XCTAssertEqual(CarPlayGPTLiveListenAction.forPhase(.connecting), .nothing)
        XCTAssertEqual(CarPlayGPTLiveListenAction.forPhase(.ending), .nothing)
    }

    func testGPTLiveNewCallStartsWithTheMicrophoneOpen() async {
        let (controller, session, _, _) = makeGPTController(clock: Date.init)
        await controller.start()
        session.becomeReady()
        controller.setMicrophoneMuted(true)
        XCTAssertEqual(session.microphoneEnabled, false)
        controller.stop()

        await controller.start()
        session.becomeReady()
        XCTAssertFalse(controller.isMicrophoneMuted, "a mute belongs to the call it was set in")
        XCTAssertEqual(session.microphoneEnabled, true)
        controller.stop()
    }
}
