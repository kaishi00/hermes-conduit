//
//  HermesWatchCalls.swift
//  Conduit Watch
//
//  Calls from Hermes ringing on the Watch (designs/hermes-calls-watch.md).
//  iOS doesn't pass Conduit's CallKit call to the Watch, so the relay sends
//  each call here too, on the Watch app's own PushKit token, and the Watch
//  shows its own incoming call. Answering here starts a Watch voice call
//  that opens with what Hermes called about: the iPhone got the same call
//  and builds the opening. Answering or declining on either device tells
//  the relay, which stops the other one ringing; the iPhone's ringing call
//  cuts its link to the Watch, so the two can't tell each other. The app
//  stays in the background under the call screen, where its link to the
//  iPhone is down too, so an answer's start goes to the iPhone with the
//  relay's stop, and the call's session comes back through the relay
//  (HermesRingHandoff).
//

import AVFAudio
import CallKit
import Combine
import Foundation
import PushKit

@MainActor
final class HermesWatchCalls: NSObject {
    static let shared = HermesWatchCalls()

    /// How long a call rings before it's missed, as on the iPhone.
    static let ringsFor: Duration = .seconds(45)
    /// A call this late has rung out on the iPhone already.
    static let lateAfter: TimeInterval = 90
    /// How long an answered call waits for CallKit's audio.
    static let audioWait: Duration = .seconds(3)

    /// Calls ring in this build: off (Info.plist ConduitHermesCallsRing, as
    /// on the iPhone), the Watch never asks for a call token.
    static var ringingBuilt: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ConduitHermesCallsRing") as? Bool ?? true
    }

    private var registry: PKPushRegistry?
    private var provider: CXProvider?
    private let callController = CXCallController()
    private var cancellables: Set<AnyCancellable> = []

    /// The Watch's PushKit token, once PushKit has answered this launch.
    private var token: String?
    private var tokenKnown = false
    /// What the iPhone was last sent this launch.
    private var sentToken: String?
    private var sentKey: Data?
    private var hasSentToken = false
    /// Seals an answered call's start and session at the relay; the iPhone
    /// gets it with the token. Nil while the Keychain can't be read.
    private var handoffKey: Data?

    private struct Call {
        let ring: HermesRing
        let title: String?
        var answered = false
        var unanswered: Task<Void, Never>?
        var work: Task<Void, Never>?
    }
    /// Calls reported to CallKit and not ended.
    private var calls: [UUID: Call] = [:]
    /// The call whose Watch voice call is running.
    private var voiceCall: UUID?
    /// Rings settled here or on the iPhone, for a call push that comes
    /// again, or after the stop.
    private var settledRings: [String: Date] = [:]
    private var audioActive = false
    private var audioWaiters: [CheckedContinuation<Void, Never>] = []

    /// A call from Hermes is ringing or answered: opening the app starts no
    /// other call.
    var holdsCall: Bool { !calls.isEmpty }

    /// At launch, before it returns: a call that launched the app waits on
    /// the PushKit registry.
    func activate() {
        guard registry == nil, Self.ringingBuilt else { return }
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        // A Hermes call can't be called back from the Phone app.
        configuration.includesCallsInRecents = false
        let provider = CXProvider(configuration: configuration)
        // On the main queue, like the PushKit registry: the delegate
        // methods assume it.
        provider.setDelegate(self, queue: .main)
        self.provider = provider
        handoffKey = HermesRingHandoffKey.loadOrCreate()
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        WatchLink.shared.$isActivated
            .filter { $0 }
            .sink { [weak self] _ in WatchVoiceMain.async { self?.sendToken() } }
            .store(in: &cancellables)
        WatchVoiceCall.shared.$phase
            .sink { [weak self] phase in self?.voicePhaseChanged(phase) }
            .store(in: &cancellables)
    }

    // MARK: The token

    /// Queued to the iPhone, which hands it to the relay, with the handoff
    /// key. Once a launch at least, so an iPhone that lost them gets them
    /// again.
    private func sendToken() {
        if handoffKey == nil { handoffKey = HermesRingHandoffKey.loadOrCreate() }
        guard tokenKnown, !hasSentToken || sentToken != token || sentKey != handoffKey else { return }
        // Not linked yet: sent once the link is up.
        guard WatchLink.shared.queue(.callsToken(token: token, key: handoffKey.map(WatchToolSeal.base64URL))) else { return }
        sentToken = token
        sentKey = handoffKey
        hasSentToken = true
        WatchCallLog.shared.note("hermesCallsToken", ["token": token != nil, "key": handoffKey != nil])
    }

    // MARK: Ringing

    private func receive(_ userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
        guard let provider else {
            completion()
            return
        }
        if let settled = HermesRingSettled.from(userInfo) {
            stopRinging(settled, provider: provider, completion: completion)
            return
        }
        let ring = HermesRing.from(userInfo)
        let late = HermesRingPush.sentAt(userInfo).map { Date().timeIntervalSince($0) > Self.lateAfter } ?? false
        // One call at a time; a Watch voice call already on keeps it.
        let busy = !calls.isEmpty || WatchVoiceCall.shared.isActive
        // The iPhone's stop came first.
        let settled = ring.map { settledRings[$0.id] != nil } ?? false
        let id = UUID()
        let rings = ring != nil && !late && !busy && !settled
        let title = HermesRingPush.title(userInfo)
        if rings, let ring { calls[id] = Call(ring: ring, title: title) }
        WatchCallLog.shared.note("hermesCallPush", ["ring": ring != nil, "late": late, "busy": busy, "settled": settled])
        // Every VoIP push is reported before this returns, even one that
        // can't ring here (the iPhone rings it).
        provider.reportNewIncomingCall(with: id, update: Self.update(title: title)) { error in
            Task { @MainActor in
                defer { completion() }
                if let error {
                    self.calls[id] = nil
                    WatchCallLog.shared.note("hermesCallNotShown", ["error": error.localizedDescription])
                    return
                }
                guard rings, self.calls[id] != nil else {
                    provider.reportCall(with: id, endedAt: Date(), reason: late ? .unanswered : .failed)
                    return
                }
                self.calls[id]?.unanswered = Task {
                    do { try await Task.sleep(for: Self.ringsFor) } catch { return }
                    guard self.calls[id]?.answered == false else { return }
                    WatchCallLog.shared.note("hermesCallUnanswered")
                    self.finish(id, reason: .unanswered)
                }
            }
        }
    }

    /// The iPhone answered or declined a call that rang on both: this one
    /// stops. Reported too, as every VoIP push is: a call still here again
    /// under its own id, which CallKit already has; any other is reported
    /// and ended at once.
    private func stopRinging(_ settled: HermesRingSettled, provider: CXProvider, completion: @escaping () -> Void) {
        let id = calls.first { $0.value.ring.id == settled.id }?.key ?? UUID()
        let reason: CXCallEndedReason = settled.outcome == .answered ? .answeredElsewhere : .declinedElsewhere
        noteSettled(settled.id)
        WatchCallLog.shared.note("hermesCallSettledOnPhone", ["outcome": settled.outcome.rawValue, "here": calls[id] != nil])
        provider.reportNewIncomingCall(with: id, update: Self.update(title: calls[id]?.title)) { _ in
            Task { @MainActor in
                if let call = self.calls[id] {
                    // Answered here too: `connect` settles that race.
                    if !call.answered { self.finish(id, reason: reason) }
                } else {
                    provider.reportCall(with: id, endedAt: Date(), reason: reason)
                }
                completion()
            }
        }
    }

    private func noteSettled(_ ringID: String) {
        let now = Date()
        settledRings = settledRings.filter { now.timeIntervalSince($0.value) < 600 }
        settledRings[ringID] = now
    }

    private static func update(title: String?) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "hermes")
        // The agent's name and the job, when the push carries them in the
        // clear; a sealed one only the iPhone can open.
        update.localizedCallerName = title.map { "Hermes · " + $0 } ?? "Hermes"
        update.hasVideo = false
        return update
    }

    // MARK: Answering

    private func answer(_ action: CXAnswerCallAction) {
        let id = action.callUUID
        guard let call = calls[id], !call.answered else {
            action.fail()
            return
        }
        calls[id]?.answered = true
        calls[id]?.unanswered?.cancel()
        // CallKit activates the audio session as it's set up here: the
        // Watch call's own setup, so its start changes nothing.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, policy: .default, options: [])
        } catch {
            WatchCallLog.shared.note("hermesCallSessionFailed", ["error": error.localizedDescription])
        }
        action.fulfill()
        calls[id]?.work = Task { await self.connect(id, ring: call.ring) }
    }

    /// Tells the relay (the iPhone stops ringing, and gets the call's
    /// start) while CallKit's audio comes up, then starts the Watch voice
    /// call, which fetches its session from the relay.
    private func connect(_ id: UUID, ring: HermesRing) async {
        // A Watch call the user started meanwhile keeps going, and the
        // iPhone goes on ringing: nothing is settled.
        guard !WatchVoiceCall.shared.isActive else {
            finish(id, reason: .failed)
            return
        }
        noteSettled(ring.id)
        let engine = WatchVoiceCall.shared.engine
        let answer = handoffKey.map { HermesRingAnswer(ring: ring, callID: UInt32.random(in: 1...UInt32.max), key: $0) }
        let start = answer.flatMap { HermesRingHandoff.sealStart(WatchVoiceCall.startRequest(engine: engine, callID: $0.callID, ring: ring.id), answer: $0) }
        let settling = Task { await HermesRingSettler.settle(ring, by: .watch, outcome: .answered, start: start) }
        await waitForAudio()
        let settled = await settling.value
        guard calls[id] != nil, !Task.isCancelled else { return }
        WatchCallLog.shared.note("hermesCallAnswered", ["settled": "\(settled)", "audio": audioActive, "start": start != nil])
        // The iPhone got there first: the call is there. Declined there
        // first, the decline stands, unlike on the iPhone: the iPhone has
        // already told Hermes the call was declined.
        if case .alreadySettled(let outcome, by: .phone) = settled {
            finish(id, reason: outcome == .answered ? .answeredElsewhere : .declinedElsewhere)
            return
        }
        // Or started while CallKit's audio came up.
        guard !WatchVoiceCall.shared.isActive else {
            finish(id, reason: .failed)
            return
        }
        voiceCall = id
        // Only a start the relay took reaches the iPhone.
        WatchVoiceCall.shared.start(ring: ring.id, answer: settled == .settled && start != nil ? answer : nil, engine: engine)
    }

    /// The Watch voice call ended (hung up on its screen, or it failed):
    /// so does the CallKit call.
    private func voicePhaseChanged(_ phase: WatchVoiceCall.Phase) {
        guard let id = voiceCall, case .ended = phase else { return }
        voiceCall = nil
        guard let call = calls.removeValue(forKey: id) else { return }
        call.work?.cancel()
        callController.request(CXTransaction(action: CXEndCallAction(call: id))) { [weak self] error in
            guard let error else { return }
            WatchVoiceMain.async {
                WatchCallLog.shared.note("hermesCallEndFailed", ["error": error.localizedDescription])
                self?.provider?.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
            }
        }
    }

    private func waitForAudio() async {
        guard !audioActive else { return }
        let timeout = Task {
            try? await Task.sleep(for: Self.audioWait)
            guard !Task.isCancelled else { return }
            self.resumeAudioWaiters()
        }
        await withCheckedContinuation { audioWaiters.append($0) }
        timeout.cancel()
    }

    private func resumeAudioWaiters() {
        let waiters = audioWaiters
        audioWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: Ending

    /// The Watch ends the call: CallKit hears why.
    private func finish(_ id: UUID, reason: CXCallEndedReason) {
        guard let call = calls.removeValue(forKey: id) else { return }
        // Rung out, or ended any other way: the same call never rings again.
        noteSettled(call.ring.id)
        call.unanswered?.cancel()
        call.work?.cancel()
        if voiceCall == id { voiceCall = nil }
        provider?.reportCall(with: id, endedAt: Date(), reason: reason)
    }

    /// The user declined, or hung up from the Watch's call controls.
    private func end(_ action: CXEndCallAction) {
        let id = action.callUUID
        guard let call = calls.removeValue(forKey: id) else {
            action.fulfill()
            return
        }
        call.unanswered?.cancel()
        call.work?.cancel()
        action.fulfill()
        if call.answered {
            WatchCallLog.shared.note("hermesCallHungUp")
            if voiceCall == id {
                voiceCall = nil
                WatchVoiceCall.shared.end()
            }
        } else {
            // Declined here: the iPhone stops ringing, and tells Hermes.
            WatchCallLog.shared.note("hermesCallDeclined")
            noteSettled(call.ring.id)
            Self.settleBeforeSuspending(call.ring, outcome: .declined)
        }
    }

    /// Tells the relay while watchOS may suspend the app right after (a
    /// decline from the call screen): asks for the time to finish.
    private static func settleBeforeSuspending(_ ring: HermesRing, outcome: HermesRingOutcome) {
        ProcessInfo.processInfo.performExpiringActivity(withReason: "conduit.hermesCall.settle") { expired in
            guard !expired else { return }
            let finished = DispatchSemaphore(value: 0)
            Task {
                _ = await HermesRingSettler.settle(ring, by: .watch, outcome: outcome)
                finished.signal()
            }
            _ = finished.wait(timeout: .now() + 12)
        }
    }
}

// MARK: - PushKit

extension HermesWatchCalls: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            guard registry === self.registry else { return }
            self.token = token
            self.tokenKnown = true
            self.sendToken()
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated {
            guard registry === self.registry else { return }
            self.token = nil
            self.tokenKnown = true
            self.sendToken()
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        let userInfo = payload.dictionaryPayload
        // The registry delivers on the main queue; the call is reported
        // before this returns.
        MainActor.assumeIsolated {
            self.receive(userInfo, completion: completion)
        }
    }
}

// MARK: - CallKit

extension HermesWatchCalls: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            WatchCallLog.shared.note("hermesCallReset")
            for call in self.calls.values {
                call.unanswered?.cancel()
                call.work?.cancel()
            }
            self.calls = [:]
            self.audioActive = false
            self.resumeAudioWaiters()
            if self.voiceCall != nil {
                self.voiceCall = nil
                WatchVoiceCall.shared.end()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated { self.answer(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated { self.end(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            guard self.calls[action.callUUID]?.answered == true, self.voiceCall == action.callUUID else {
                action.fail()
                return
            }
            if WatchVoiceCall.shared.isMuted != action.isMuted { WatchVoiceCall.shared.toggleMute() }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            WatchCallLog.shared.note("hermesCallAudioOn")
            self.audioActive = true
            self.resumeAudioWaiters()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            WatchCallLog.shared.note("hermesCallAudioOff")
            self.audioActive = false
        }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
    }
}
