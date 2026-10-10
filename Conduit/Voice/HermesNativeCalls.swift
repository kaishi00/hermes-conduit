//
//  HermesNativeCalls.swift
//  Conduit
//
//  Hermes calls you, step 2 (#449): a call from Hermes rings like a phone
//  call. The relay sends it as a VoIP push (relay 0.9+, to the PushKit
//  token Conduit registers), and it is reported to CallKit before the
//  PushKit callback returns: iOS stops delivering VoIP pushes to an app
//  that doesn't. Answering opens voice in the call's chat, as the
//  notification's Talk button does, and the CallKit call lasts as long as
//  that voice conversation: ending either ends both.
//
//  A push that can't ring is still reported, then ended at once: one that
//  arrives late (the phone was offline) or can't be answered becomes a
//  missed-call notification, one that arrives while voice is in use the
//  usual "Hermes wants to talk" notification, and a replay nothing. A call
//  Do Not Disturb silences stays silent. A call the user declines or
//  doesn't get to answer is reported to the host too, so Hermes hears it in
//  that chat's next turn. CallKit is off in China's App
//  Store, so there Conduit never registers a PushKit token and calls keep
//  arriving as notifications.
//  (designs/hermes-calls-you-449.md)
//

import AVFAudio
import CallKit
import Foundation
import OSLog
import PushKit
import StoreKit
import UserNotifications

private let nativeCallsLogger = Logger(subsystem: "com.milim.relay", category: "HermesCalls")

/// Where calls may ring: CallKit isn't allowed in China's App Store.
enum HermesNativeCallStorefront {
    static let defaultsKey = "hermesCalls.storefront"

    /// `countryCode` is the App Store's ISO 3166-1 alpha-3 code; nil (no
    /// App Store account) rings.
    static func allowsCalls(_ countryCode: String?) -> Bool {
        countryCode?.uppercased() != "CHN"
    }
}

/// What a VoIP push does once it is reported to CallKit.
enum HermesNativeCallPlan: Equatable {
    case ring
    /// Ended at once, with this notification instead.
    case endAtOnce(Notice)

    enum Notice: Equatable {
        case none
        /// "Missed call from Hermes", answered like the call.
        case missed
        /// "Hermes wants to talk": the user is busy in voice.
        case talk
        /// A call Conduit couldn't read.
        case unreadable
    }

    /// A push this much older than when the relay sent it rings no more.
    static let lateAfter: TimeInterval = 90

    static func plan(for call: PushNotificationService.VoIPCall, now: Date, voiceInUse: Bool) -> HermesNativeCallPlan {
        guard call.target != nil else { return .endAtOnce(.unreadable) }
        guard !call.replayed else { return .endAtOnce(.none) }
        if let sentAt = call.sentAt, now.timeIntervalSince(sentAt) > lateAfter { return .endAtOnce(.missed) }
        return voiceInUse ? .endAtOnce(.talk) : .ring
    }

    /// Whether the push is a call of its own, with its own trace: a replay
    /// or a push Conduit couldn't read leaves the last call's trace alone.
    var startsTrace: Bool {
        switch self {
        case .ring, .endAtOnce(.missed), .endAtOnce(.talk): return true
        case .endAtOnce(.none), .endAtOnce(.unreadable): return false
        }
    }

    /// How the call trace names it.
    var traceLabel: String {
        switch self {
        case .ring: return "ring"
        case .endAtOnce(.none): return "end at once, nothing posted"
        case .endAtOnce(.missed): return "end at once, missed call"
        case .endAtOnce(.talk): return "end at once, wants to talk"
        case .endAtOnce(.unreadable): return "end at once, unreadable"
        }
    }
}

@MainActor
final class HermesNativeCalls: NSObject {
    static let shared = HermesNativeCalls()

    /// How long a call rings before it counts as missed.
    static let unansweredAfter: Duration = .seconds(45)
    /// How long an answered call waits for Hermes' connection.
    static let connectionTimeout: Duration = .seconds(20)
    /// How long an answered call waits for CallKit's audio.
    static let audioTimeout: Duration = .seconds(3)
    /// How long the voice conversation it opens has to start.
    static let voiceStartTimeout: Duration = .seconds(15)
    /// How long an answered call waits for Conduit to come on screen.
    static let phoneScreenWait: Duration = .milliseconds(1500)

    private var registry: PKPushRegistry?
    private var provider: CXProvider?
    private var storefrontTask: Task<Void, Never>?
    private var isActivated = false

    private struct Call {
        let target: ConduitNotificationTarget
        /// When the relay sent it, if it said.
        var sentAt: Date?
        var answered = false
        var unanswered: Task<Void, Never>?
        var work: Task<Void, Never>?
    }
    /// Calls reported to CallKit and not ended.
    private var calls: [UUID: Call] = [:]
    private var audioActive = false
    private var audioWaiters: [CheckedContinuation<Void, Never>] = []

    /// At launch, before it returns: a call that launched Conduit waits on
    /// the PushKit registry.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        // Unit tests run inside the app: no calls there.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Decided before this returns, so a call that launched Conduit
        // finds the registry (an empty value: no App Store answer yet).
        if let known = UserDefaults.standard.string(forKey: HermesNativeCallStorefront.defaultsKey) {
            storefrontChanged(known.isEmpty ? nil : known)
        }
        storefrontTask = Task {
            let current = await Storefront.current
            self.storefrontChanged(current?.countryCode)
            for await update in Storefront.updates {
                self.storefrontChanged(update.countryCode)
            }
        }
    }

    private func storefrontChanged(_ countryCode: String?) {
        let defaults = UserDefaults.standard
        let key = HermesNativeCallStorefront.defaultsKey
        // No answer (no App Store account, or offline): the last one known
        // stands.
        let known = countryCode ?? defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
        defaults.set(known ?? "", forKey: key)
        if HermesNativeCallStorefront.allowsCalls(known) {
            startRinging()
        } else {
            stopRinging()
        }
    }

    private func startRinging() {
        guard registry == nil else { return }
        if provider == nil {
            let configuration = CXProviderConfiguration()
            configuration.supportsVideo = false
            configuration.maximumCallGroups = 1
            configuration.maximumCallsPerCallGroup = 1
            configuration.supportedHandleTypes = [.generic]
            // A Hermes call can't be called back from the Phone app.
            configuration.includesCallsInRecents = false
            let provider = CXProvider(configuration: configuration)
            // On the main queue, like the PushKit registry: the delegate
            // methods below assume it.
            provider.setDelegate(self, queue: .main)
            self.provider = provider
        }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        nativeCallsLogger.info("Hermes calls ring natively")
    }

    /// Calls go back to notifications: the relay forgets the token.
    private func stopRinging() {
        if let registry {
            registry.desiredPushTypes = []
            registry.delegate = nil
            self.registry = nil
            nativeCallsLogger.info("Hermes calls don't ring in this storefront")
        }
        PushNotificationService.shared.updateVoIPToken(nil)
        for call in calls.values where call.answered {
            endVoice(of: call.target)
        }
        // Only a call that never connected was missed.
        for (id, call) in Array(calls) { finish(id, reason: .failed, notice: call.answered ? .none : .missed) }
    }

    // MARK: Ringing

    private func receive(_ userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
        let call = PushNotificationService.shared.receiveVoIPCall(userInfo)
        // Never created here: reporting comes first.
        let appState = AppStateRuntimeRegistry.shared.existing
        let busy = appState.map { $0.isVoiceInUse || $0.isWatchVoiceCallActive } ?? false
        let plan = HermesNativeCallPlan.plan(for: call, now: Date(), voiceInUse: busy || !calls.isEmpty)
        // A push while a call is live ends at once: the live call keeps
        // its trace.
        let traced = plan.startsTrace && calls.isEmpty
        if traced {
            HermesCallTrace.shared.begin(
                "Push received: \(plan.traceLabel) (app \(appState == nil ? "starting" : "running"), voice busy: \(busy))"
            )
        }
        let id = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "hermes")
        update.localizedCallerName = HermesCallCopy.callerName(title: call.target?.call?.title)
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        guard let provider else {
            // Never registered for VoIP pushes without a provider.
            if traced { HermesCallTrace.shared.note("No CallKit provider") }
            completion()
            return
        }
        if plan == .ring, let target = call.target { calls[id] = Call(target: target, sentAt: call.sentAt) }
        provider.reportNewIncomingCall(with: id, update: update) { error in
            Task { @MainActor in
                self.reported(id, plan: plan, traced: traced, target: call.target, sentAt: call.sentAt, error: error)
                completion()
            }
        }
    }

    private func reported(_ id: UUID, plan: HermesNativeCallPlan, traced: Bool, target: ConduitNotificationTarget?, sentAt: Date?, error: Error?) {
        if let error {
            calls[id] = nil
            let code = (error as? CXErrorCodeIncomingCallError)?.code
            nativeCallsLogger.notice("Hermes call not shown: \(error.localizedDescription, privacy: .public)")
            if traced {
                HermesCallTrace.shared.note("CallKit didn't show it (code \(code.map { String($0.rawValue) } ?? "unknown"))")
            }
            // A call that should have rung didn't (one CallKit already has
            // is no new call): Hermes hears it went unanswered.
            if code != .callUUIDAlreadyExists, plan == .ring || plan == .endAtOnce(.missed) {
                report(.missed, for: target, sentAt: sentAt)
            }
            // Do Not Disturb or a blocked caller: the user asked for quiet.
            if code == .filteredByDoNotDisturb || code == .filteredByBlockList || code == .callUUIDAlreadyExists { return }
            if case .endAtOnce(let notice) = plan {
                post(notice, for: target)
            } else {
                post(.talk, for: target)
            }
            return
        }
        switch plan {
        case .endAtOnce(let notice):
            if traced { HermesCallTrace.shared.note("Ended at once") }
            provider?.reportCall(with: id, endedAt: Date(), reason: notice == .missed ? .unanswered : .failed)
            post(notice, for: target)
            if notice == .missed { report(.missed, for: target, sentAt: sentAt) }
        case .ring:
            guard calls[id] != nil else { return }
            HermesCallTrace.shared.note("Ringing")
            calls[id]?.unanswered = Task {
                do { try await Task.sleep(for: Self.unansweredAfter) } catch { return }
                guard self.calls[id]?.answered == false else { return }
                self.finish(id, reason: .unanswered, notice: .missed)
            }
            // Hermes' connection starts coming up while it rings.
            AppStateRuntimeRegistry.shared.appState.setNativeHermesCallActive(true)
        }
    }

    // MARK: Answering

    private func answer(_ action: CXAnswerCallAction) {
        guard calls[action.callUUID] != nil else {
            HermesCallTrace.shared.note("Answered a call that had ended")
            action.fail()
            return
        }
        HermesCallTrace.shared.note("Answered")
        calls[action.callUUID]?.answered = true
        calls[action.callUUID]?.unanswered?.cancel()
        // CallKit activates the session once the action is fulfilled.
        VoiceAudioSessionCoordinator.shared.configureForIncomingCall()
        action.fulfill()
        let id = action.callUUID
        calls[id]?.work = Task { await self.connect(id) }
    }

    /// Brings Hermes up, opens the call's chat and its voice, then keeps
    /// the CallKit call for as long as that voice conversation runs.
    private func connect(_ id: UUID) async {
        guard let target = calls[id]?.target else { return }
        guard let request = target.call else {
            HermesCallTrace.shared.note("No call in the push")
            finish(id, reason: .failed, notice: .missed)
            return
        }
        let appState = AppStateRuntimeRegistry.shared.appState
        appState.setNativeHermesCallActive(true)
        let audioWait = Date()
        await waitForAudio()
        HermesCallTrace.shared.note(audioActive ? "Call audio ready" : "Call audio not ready, going on", since: audioWait)
        guard calls[id] != nil, !Task.isCancelled else { return }
        // Answered unlocked, Conduit comes to the front with the call, and
        // its return to the app (a connection check, maybe a reconnect, the
        // chat it restores) would race an open from here. The call opens
        // the way its notification's Talk button does instead: the route
        // that open waits behind, retries once, and answers the call.
        let onScreen = await waitForPhoneScreen()
        guard calls[id] != nil, !Task.isCancelled else { return }
        if onScreen {
            HermesCallTrace.shared.note("Conduit on screen: opening like the Talk button")
            await openThroughRoute(id, target: target, appState: appState)
            return
        }
        // Answered locked, Conduit stays in the background, where nothing
        // routes: the call opens its chat itself.
        HermesCallTrace.shared.note("Conduit in the background: opening from the call")
        let connectionWait = Date()
        let wasConnected = appState.isConnected
        let connected = await CarPlayVoiceCoordinator.awaitConnection(of: appState, timeout: Self.connectionTimeout)
        HermesCallTrace.shared.note(
            connected ? (wasConnected ? "Already connected" : "Connected") : "Not connected in time",
            since: connectionWait
        )
        guard calls[id] != nil, !Task.isCancelled else { return }
        // A cold launch can take longer to come on screen: once it has, the
        // same race holds.
        if PhoneScenePresence.isInForeground {
            HermesCallTrace.shared.note("Conduit came on screen: opening like the Talk button")
            await openThroughRoute(id, target: target, appState: appState)
            return
        }
        let chatWait = Date()
        let errorBefore = appState.errorMessage
        guard connected, await appState.openNotificationTarget(target) else {
            nativeCallsLogger.notice("Hermes call answered but not opened (connected: \(connected, privacy: .public))")
            if connected {
                let shown = appState.errorMessage != nil && appState.errorMessage != errorBefore
                HermesCallTrace.shared.note("Chat not opened\(shown ? ", error shown" : "")", since: chatWait)
            }
            // The user picked up: what's left is "Hermes wants to talk".
            finish(id, reason: .failed, notice: .talk)
            return
        }
        guard calls[id] != nil else {
            HermesCallTrace.shared.note("Chat opened, call already ended", since: chatWait)
            return
        }
        HermesCallTrace.shared.note("Chat opened", since: chatWait)
        // Another voice conversation started while it rang: the job's news
        // reaches the user there, never as this call.
        guard appState.answerHermesCall(request) else {
            finish(id, reason: .failed, notice: .talk)
            return
        }
        await keepCallWhileVoiceRuns(id, appState: appState, startTimeout: Self.voiceStartTimeout)
    }

    /// Opens the call as its notification's Talk button would, then keeps
    /// the CallKit call while the voice it opens runs.
    private func openThroughRoute(_ id: UUID, target: ConduitNotificationTarget, appState: AppState) async {
        PushNotificationService.shared.routeAnsweredHermesCall(target)
        await keepCallWhileVoiceRuns(id, appState: appState, startTimeout: Self.connectionTimeout + Self.voiceStartTimeout)
    }

    /// The route gave up on the call's chat, or opened it but couldn't open
    /// its voice (voice was already in use): the call ends now, not after
    /// its start wait, and its news waits in "Hermes wants to talk", as
    /// when the call opens the chat itself.
    func routedAnswerFailed(_ target: ConduitNotificationTarget) {
        for (id, call) in calls where call.answered && call.target == target {
            finish(id, reason: .failed, notice: .talk)
        }
    }

    /// Whether Conduit is on screen within a moment of the answer.
    private func waitForPhoneScreen() async -> Bool {
        let until = ContinuousClock.now + Self.phoneScreenWait
        while !PhoneScenePresence.isInForeground {
            guard ContinuousClock.now < until else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return true
    }

    /// Keeps the CallKit call for as long as the voice conversation it
    /// opened runs, once it starts within `startTimeout`.
    private func keepCallWhileVoiceRuns(_ id: UUID, appState: AppState, startTimeout: Duration) async {
        var started = false
        let voiceWait = Date()
        let startBy = ContinuousClock.now + startTimeout
        while calls[id] != nil, !Task.isCancelled {
            if appState.isVoiceInUse {
                if !started { HermesCallTrace.shared.note("Voice in use", since: voiceWait) }
                started = true
            } else if started || ContinuousClock.now > startBy {
                break
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
        guard calls[id] != nil else { return }
        HermesCallTrace.shared.note(
            started ? "Voice ended" : "Voice not in use in time (\(appState.hermesCallVoiceTraceSummary))",
            since: voiceWait
        )
        // Voice ended in the app, or never started: the CallKit call ends,
        // and voice still opening doesn't. The user picked up, so what's
        // left is "Hermes wants to talk", not a missed call.
        if !started { endVoice(of: calls[id]?.target) }
        finish(id, reason: started ? .remoteEnded : .failed, notice: started ? .none : .talk)
    }

    /// An answered call is over: the voice conversation it opened ends,
    /// and an open still on its way, from here or routed, doesn't happen.
    private func endVoice(of target: ConduitNotificationTarget?) {
        if let target { PushNotificationService.shared.clearPendingTarget(target) }
        AppStateRuntimeRegistry.shared.existing?.endVoiceForNativeCall()
    }

    private func waitForAudio() async {
        guard !audioActive else { return }
        let timeout = Task {
            do { try await Task.sleep(for: Self.audioTimeout) } catch { return }
            self.resumeAudioWaiters()
        }
        await withCheckedContinuation { continuation in
            audioWaiters.append(continuation)
        }
        timeout.cancel()
    }

    private func resumeAudioWaiters() {
        let waiters = audioWaiters
        audioWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Ending

    /// Conduit ends the call: CallKit hears why, and `notice` follows.
    private func finish(_ id: UUID, reason: CXCallEndedReason, notice: HermesNativeCallPlan.Notice) {
        guard let call = calls.removeValue(forKey: id) else { return }
        HermesCallTrace.shared.note("Call ended (\(Self.traceLabel(reason)))")
        call.unanswered?.cancel()
        call.work?.cancel()
        provider?.reportCall(with: id, endedAt: Date(), reason: reason)
        post(notice, for: call.target)
        // It rang out, or stopped ringing, before the user picked up.
        if !call.answered, notice == .missed { report(.missed, for: call.target, sentAt: call.sentAt) }
        settle()
    }

    /// The user declined or hung up in CallKit.
    private func end(_ action: CXEndCallAction) {
        guard let call = calls.removeValue(forKey: action.callUUID) else {
            action.fulfill()
            return
        }
        HermesCallTrace.shared.note(call.answered ? "Hung up" : "Declined")
        call.unanswered?.cancel()
        call.work?.cancel()
        action.fulfill()
        if call.answered {
            endVoice(of: call.target)
        } else {
            post(.missed, for: call.target)
            report(.declined, for: call.target, sentAt: call.sentAt)
        }
        settle()
    }

    private static func traceLabel(_ reason: CXCallEndedReason) -> String {
        switch reason {
        case .failed: return "failed"
        case .remoteEnded: return "ended by Conduit"
        case .unanswered: return "unanswered"
        case .answeredElsewhere: return "answered elsewhere"
        case .declinedElsewhere: return "declined elsewhere"
        @unknown default: return "reason \(reason.rawValue)"
        }
    }

    private func settle() {
        guard calls.isEmpty else { return }
        AppStateRuntimeRegistry.shared.existing?.setNativeHermesCallActive(false)
    }

    /// The user didn't pick up: the host that placed the call hears so,
    /// now if it can be reached, else once it's connected again. Timed from
    /// when the relay sent it: one that reached an offline phone hours
    /// later was placed then, not now.
    private func report(_ outcome: HermesCallOutcome, for target: ConduitNotificationTarget?, sentAt: Date?) {
        guard let target, let entry = HermesCallOutcomeOutbox.Entry(outcome, target: target, at: sentAt ?? Date()) else { return }
        HermesCallOutcomeOutbox.record(entry, in: .standard)
        AppStateRuntimeRegistry.shared.existing?.deliverHermesCallOutcomes()
    }

    private func post(_ notice: HermesNativeCallPlan.Notice, for target: ConduitNotificationTarget?) {
        let request: UNNotificationRequest?
        switch notice {
        case .none: request = nil
        case .missed: request = target.flatMap { HermesCallNotifications.callRequest(for: $0, missed: true) }
        case .talk: request = target.flatMap { HermesCallNotifications.callRequest(for: $0, missed: false) }
        case .unreadable: request = HermesCallNotifications.unreadableMissedCallRequest()
        }
        guard let request else { return }
        Task { await HermesCallNotifications.post(request) }
    }
}

// MARK: - PushKit

extension HermesNativeCalls: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            guard registry === self.registry else { return }
            PushNotificationService.shared.updateVoIPToken(token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated {
            guard registry === self.registry else { return }
            PushNotificationService.shared.updateVoIPToken(nil)
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

extension HermesNativeCalls: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            HermesCallTrace.shared.note("CallKit reset")
            let answered = self.calls.values.filter(\.answered).map(\.target)
            for call in self.calls.values {
                call.unanswered?.cancel()
                call.work?.cancel()
                // A call still ringing leaves its trace, as on every other end.
                if !call.answered {
                    self.post(.missed, for: call.target)
                    self.report(.missed, for: call.target, sentAt: call.sentAt)
                }
            }
            self.calls = [:]
            self.audioActive = false
            self.resumeAudioWaiters()
            for target in answered { self.endVoice(of: target) }
            self.settle()
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
            guard self.calls[action.callUUID]?.answered == true else {
                action.fail()
                return
            }
            AppStateRuntimeRegistry.shared.existing?.setVoiceMutedForNativeCall(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            HermesCallTrace.shared.note("CallKit audio on")
            self.audioActive = true
            self.resumeAudioWaiters()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            HermesCallTrace.shared.note("CallKit audio off")
            self.audioActive = false
        }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
    }
}
