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
//  Do Not Disturb silences stays silent. CallKit is off in China's App
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

    private var registry: PKPushRegistry?
    private var provider: CXProvider?
    private var storefrontTask: Task<Void, Never>?
    private var isActivated = false

    private struct Call {
        let target: ConduitNotificationTarget
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
        if calls.values.contains(where: \.answered) {
            AppStateRuntimeRegistry.shared.existing?.endVoiceForNativeCall()
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
            completion()
            return
        }
        if plan == .ring, let target = call.target { calls[id] = Call(target: target) }
        provider.reportNewIncomingCall(with: id, update: update) { error in
            Task { @MainActor in
                self.reported(id, plan: plan, target: call.target, error: error)
                completion()
            }
        }
    }

    private func reported(_ id: UUID, plan: HermesNativeCallPlan, target: ConduitNotificationTarget?, error: Error?) {
        if let error {
            calls[id] = nil
            let code = (error as? CXErrorCodeIncomingCallError)?.code
            nativeCallsLogger.notice("Hermes call not shown: \(error.localizedDescription, privacy: .public)")
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
            provider?.reportCall(with: id, endedAt: Date(), reason: notice == .missed ? .unanswered : .failed)
            post(notice, for: target)
        case .ring:
            guard calls[id] != nil else { return }
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
            action.fail()
            return
        }
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
            finish(id, reason: .failed, notice: .missed)
            return
        }
        let appState = AppStateRuntimeRegistry.shared.appState
        appState.setNativeHermesCallActive(true)
        await waitForAudio()
        let connected = await CarPlayVoiceCoordinator.awaitConnection(of: appState, timeout: Self.connectionTimeout)
        guard calls[id] != nil, !Task.isCancelled else { return }
        guard connected, await appState.openNotificationTarget(target), calls[id] != nil else {
            nativeCallsLogger.notice("Hermes call answered but not opened (connected: \(connected, privacy: .public))")
            finish(id, reason: .failed, notice: .missed)
            return
        }
        // Another voice conversation started while it rang: the job's news
        // reaches the user there, never as this call.
        guard appState.answerHermesCall(request) else {
            finish(id, reason: .failed, notice: .talk)
            return
        }
        var started = false
        let startBy = ContinuousClock.now + Self.voiceStartTimeout
        while calls[id] != nil, !Task.isCancelled {
            if appState.isVoiceInUse {
                started = true
            } else if started || ContinuousClock.now > startBy {
                break
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
        guard calls[id] != nil else { return }
        // Voice ended in the app, or never started: the CallKit call ends,
        // and voice still opening doesn't. The user picked up, so what's
        // left is "Hermes wants to talk", not a missed call.
        if !started { appState.endVoiceForNativeCall() }
        finish(id, reason: started ? .remoteEnded : .failed, notice: started ? .none : .talk)
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
        call.unanswered?.cancel()
        call.work?.cancel()
        provider?.reportCall(with: id, endedAt: Date(), reason: reason)
        post(notice, for: call.target)
        settle()
    }

    /// The user declined or hung up in CallKit.
    private func end(_ action: CXEndCallAction) {
        guard let call = calls.removeValue(forKey: action.callUUID) else {
            action.fulfill()
            return
        }
        call.unanswered?.cancel()
        call.work?.cancel()
        action.fulfill()
        if call.answered {
            AppStateRuntimeRegistry.shared.existing?.endVoiceForNativeCall()
        } else {
            post(.missed, for: call.target)
        }
        settle()
    }

    private func settle() {
        guard calls.isEmpty else { return }
        AppStateRuntimeRegistry.shared.existing?.setNativeHermesCallActive(false)
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
            let answered = self.calls.values.contains { $0.answered }
            for call in self.calls.values {
                call.unanswered?.cancel()
                call.work?.cancel()
                // A call still ringing leaves its trace, as on every other end.
                if !call.answered { self.post(.missed, for: call.target) }
            }
            self.calls = [:]
            self.audioActive = false
            self.resumeAudioWaiters()
            if answered { AppStateRuntimeRegistry.shared.existing?.endVoiceForNativeCall() }
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
            self.audioActive = true
            self.resumeAudioWaiters()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { self.audioActive = false }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
    }
}
