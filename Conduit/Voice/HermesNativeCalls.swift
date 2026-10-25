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
//  A push that can't ring is still reported, then ended at once (on iOS
//  26.4+ only when iOS says it must be): one that arrives late (the phone
//  was offline) or can't be answered becomes a missed-call notification,
//  one that arrives while voice is in use the usual "Hermes wants to talk"
//  notification, and a replay nothing. A call
//  Do Not Disturb silences stays silent. A call the user declines or
//  doesn't get to answer is reported to the host too, so Hermes hears it in
//  that chat's next turn. With relay 0.10+ the call rings on the Apple
//  Watch too, and answering or declining on either stops the other
//  (designs/hermes-calls-watch.md); with relay 0.11+ a Watch answer's
//  start comes with the stop, and this phone hands the Watch call its
//  session through the relay (HermesRingHandoff). Answered on the Watch while
//  this phone has a headset on (AirPods), the call stays here instead, so
//  it plays on the headset as a phone call does, and the Watch's call
//  screen keeps Mute and End through the relay (HermesRingControl, #1204).
//  CallKit is off in China's App
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
import UIKit
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
    /// How long a call the Apple Watch answered keeps ringing here for the
    /// relay's stop.
    static let watchStopWait: Duration = .seconds(4)
    /// How long an answered call waits for Hermes' connection.
    static let connectionTimeout: Duration = .seconds(20)
    /// How long an answered call waits for CallKit's audio.
    static let audioTimeout: Duration = .seconds(3)
    /// How long the voice conversation it opens has to start.
    static let voiceStartTimeout: Duration = .seconds(15)
    /// How long an answered call waits for Conduit to come on screen.
    static let phoneScreenWait: Duration = .milliseconds(1500)

    /// Made once and kept: PushKit misbehaves when its registry is
    /// replaced, so "Ring like a phone call" turns its push types on and
    /// off instead.
    private var registry: PKPushRegistry?
    /// Whether calls ring through PushKit right now.
    private var isRinging = false
    private var provider: CXProvider?
    /// Answers and ends calls this phone keeps from the Watch's answer.
    private let callController = CXCallController()
    private var storefrontTask: Task<Void, Never>?
    private var isActivated = false

    /// How long a ringing call's target is kept for a Watch call that
    /// answers it, as long as the relay keeps its ring.
    static let ringTargetLife: TimeInterval = 600

    /// Calls ring through CallKit in this build. Off, every call comes as
    /// the "Hermes wants to talk" notification (#449's first step), for a
    /// build App Review wants without CallKit: set ConduitHermesCallsRing
    /// to NO in both apps' Info.plist and drop `voip` from their
    /// UIBackgroundModes.
    static var ringingBuilt: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ConduitHermesCallsRing") as? Bool ?? true
    }
    /// "Ring like a phone call" in Calls from Hermes, on this iPhone. Off,
    /// calls come as the notification.
    static let ringsKey = "hermesCalls.ringsLikeCall"
    static var ringingWanted: Bool { UserDefaults.standard.object(forKey: ringsKey) as? Bool ?? true }
    /// Whether "Ring like a phone call" is offered: a build that rings, in
    /// a storefront that allows it.
    static var offersRinging: Bool {
        let known = UserDefaults.standard.string(forKey: HermesNativeCallStorefront.defaultsKey)
        return ringingBuilt && HermesNativeCallStorefront.allowsCalls(known.flatMap { $0.isEmpty ? nil : $0 })
    }

    private struct Call {
        let target: ConduitNotificationTarget
        /// Who it said was calling, kept for a report again when it settles.
        var callerName: String = HermesCallerName.fallback
        /// When the relay sent it, if it said.
        var sentAt: Date?
        /// The ring it shares with the Apple Watch, when it rings there too.
        var ring: HermesRing? = nil
        /// This phone already told the relay to stop the Watch ringing (in
        /// the car). Answering or ending here still settles: a decline the
        /// relay never got is settled then, and a repeat is only refused.
        var watchStopped = false
        /// Telling the relay this phone answered it.
        var settling: Task<HermesRingSettleResult, Never>? = nil
        var answered = false
        /// The voice conversation the answer opened is running.
        var voiceStarted = false
        var unanswered: Task<Void, Never>?
        var work: Task<Void, Never>?
        /// Answered on the Watch with a headset on here, and kept here
        /// (#1204): the Watch's call screen controls it through the ring's
        /// control, and the ring is already the Watch's, so nothing settles.
        var keptFromWatch = false
        /// The ring's control as last read or posted here, so a change it
        /// brought isn't posted back.
        var controlMuted = false
        var controlEnded = false
        /// The call's voice's own mute as last seen (`nativeCallVoiceMuted`):
        /// only a change of it is the user's, and reaches the Watch.
        var inAppMuted: Bool? = nil
        /// Reads the Watch's Mute and End.
        var following: Task<Void, Never>? = nil
    }
    /// Calls reported to CallKit and not ended.
    private var calls: [UUID: Call] = [:]
    /// Each ring's call, for a Watch call that answers it, and the ring, to
    /// store that call's session at the relay.
    private var ringTargets: [String: (target: ConduitNotificationTarget, ring: HermesRing, at: Date)] = [:]
    private var audioActive = false
    /// Notes every route change of the call's audio in the call trace
    /// while CallKit has it, so a Speaker button that disagrees with where
    /// the sound comes out shows up in a copied trace.
    private var routeObserver: NSObjectProtocol?
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
        if Self.ringingBuilt, Self.ringingWanted, HermesNativeCallStorefront.allowsCalls(known) {
            startRinging()
        } else {
            // Where CallKit isn't allowed, calls on end too. Once the
            // setting has turned ringing off, a call still on carries on.
            stopRinging(endingCalls: isRinging)
        }
    }

    /// "Ring like a phone call" changed: calls ring, or come as the
    /// notification, from now on.
    func ringingSettingChanged() {
        // Not activated (unit tests): nothing rings.
        guard storefrontTask != nil else { return }
        // A call already ringing or on carries on: only new calls change.
        if Self.ringingWanted {
            storefrontChanged(nil)
        } else {
            stopRinging(endingCalls: false)
        }
    }

    private func startRinging() {
        guard !isRinging else { return }
        isRinging = true
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
        if let registry {
            registry.desiredPushTypes = [.voIP]
            // Ringing again: the token PushKit already gave goes back to
            // the relay.
            if let token = registry.pushToken(for: .voIP) { PushNotificationService.shared.updateVoIPToken(Self.hex(token)) }
        } else {
            let registry = PKPushRegistry(queue: .main)
            registry.delegate = self
            registry.desiredPushTypes = [.voIP]
            self.registry = registry
        }
        nativeCallsLogger.info("Hermes calls ring natively")
    }

    /// Calls go back to notifications: the relay forgets the token.
    private func stopRinging(endingCalls: Bool) {
        if isRinging {
            isRinging = false
            registry?.desiredPushTypes = []
            nativeCallsLogger.info("Hermes calls come as notifications")
        }
        PushNotificationService.shared.updateVoIPToken(nil)
        guard endingCalls else { return }
        for call in calls.values where call.answered {
            endVoice(of: call.target)
        }
        // Only a call that never connected was missed.
        for (id, call) in Array(calls) { finish(id, reason: .failed, notice: call.answered ? .none : .missed) }
    }

    // MARK: Ringing

    /// Who the call says is calling: its profile, the main one by the name
    /// the user gave it on the call's dashboard (the active one for a push
    /// from a relay that names none).
    private static func callerName(_ target: ConduitNotificationTarget?) -> String {
        HermesCallCopy.callerName(profile: target?.profile, mainName: mainProfileName(target), title: target?.call?.title)
    }

    /// The profile alone, as a missed call names it.
    private static func profileName(_ target: ConduitNotificationTarget) -> String {
        HermesCallerName.name(profile: target.profile, mainName: mainProfileName(target))
    }

    private static func mainProfileName(_ target: ConduitNotificationTarget?) -> String? {
        guard let target else { return nil }
        let dashboardID = target.dashboardID ?? AppStateRuntimeRegistry.shared.existing?.activeDashboardID
        return ProfileAppearanceStore().loadDefaultName(dashboardID: dashboardID)
    }

    /// `mustReport`: whether iOS needs a CallKit call for this push (iOS
    /// 26.4+ says; earlier, always). It doesn't while Conduit is in the
    /// foreground or already has a call, or when the push came too late
    /// to ring: then a push that wouldn't ring here shows no call at all.
    private func receive(_ userInfo: [AnyHashable: Any], mustReport: Bool = true, completion: @escaping () -> Void) {
        if let settled = HermesRingSettled.from(userInfo) {
            ringSettled(settled, mustReport: mustReport, completion: completion)
            return
        }
        let call = PushNotificationService.shared.receiveVoIPCall(userInfo)
        let ring = HermesRing.from(userInfo)
        if let ring, let target = call.target {
            pruneRingTargets()
            ringTargets[ring.id] = (target, ring, Date())
        }
        // Never created here: reporting comes first.
        let appState = AppStateRuntimeRegistry.shared.existing
        let busy = appState.map { $0.isVoiceInUse || $0.isWatchVoiceCallActive } ?? false
        let plan = HermesNativeCallPlan.plan(for: call, now: Date(), voiceInUse: busy || !calls.isEmpty)
        // Read once, as the call arrives: CarPlay coming up while it rings
        // leaves the Watch ringing too.
        let inCar = CarPlayVoiceCoordinator.shared.isConnected || WakeRoutePolicy.currentRouteIsCarPlay()
        // Busy in voice or another call here, or in the car: the Apple Watch
        // stops ringing it.
        let watchStops = ring != nil && Self.stopsWatchRing(plan: plan, inCar: inCar)
        // In the car the call rings here, so its settle is kept on the call:
        // `connect` still hears a Watch that answered first.
        var carSettling: Task<HermesRingSettleResult, Never>?
        if watchStops, let ring {
            let settling = settleRing(ring, outcome: .declined)
            if plan == .ring { carSettling = settling }
        }
        // A push while a call is live ends at once: the live call keeps
        // its trace.
        let traced = plan.startsTrace && calls.isEmpty
        if traced {
            HermesCallTrace.shared.begin(
                "Push received: \(plan.traceLabel) (app \(appState == nil ? "starting" : "running"), voice busy: \(busy), in the car: \(inCar))"
            )
        }
        let id = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "hermes")
        let callerName = Self.callerName(call.target)
        update.localizedCallerName = callerName
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
        guard Self.showsCall(plan, mustReport: mustReport) else {
            // Nothing to ring, and iOS doesn't need a call reported: none
            // is shown and ended, which only gives CallKit more to do.
            if traced { HermesCallTrace.shared.note("Not shown: iOS needs no call for it") }
            endedAtOnce(plan, target: call.target, sentAt: call.sentAt)
            completion()
            return
        }
        if plan == .ring, let target = call.target {
            calls[id] = Call(target: target, callerName: callerName, sentAt: call.sentAt, ring: ring, watchStopped: watchStops, settling: carSettling)
        }
        provider.reportNewIncomingCall(with: id, update: update) { error in
            Task { @MainActor in
                // A ring already settled here needs no settling again.
                self.reported(id, plan: plan, traced: traced, target: call.target, sentAt: call.sentAt, ring: watchStops ? nil : ring, error: error)
                completion()
            }
        }
    }

    /// Whether the Apple Watch, which the relay rings alongside this
    /// iPhone, stops ringing as soon as the call reaches here. In the car
    /// the call is the car's: CallKit shows it on CarPlay and talks through
    /// the car, while a call answered on the wrist talks through the Watch.
    nonisolated static func stopsWatchRing(plan: HermesNativeCallPlan, inCar: Bool) -> Bool {
        switch plan {
        case .endAtOnce(.talk): return true
        case .ring: return inCar
        default: return false
        }
    }

    /// Whether the Apple Watch stops ringing a call CallKit wouldn't show
    /// here: a Focus (Driving too) or a blocked caller silences it on the
    /// iPhone, and the Watch keeps that quiet. Hermes has already heard it
    /// went unanswered.
    nonisolated static func stopsWatchRing(after code: CXErrorCodeIncomingCallError.Code?) -> Bool {
        code == .filteredByDoNotDisturb || code == .filteredByBlockList
    }

    private func reported(_ id: UUID, plan: HermesNativeCallPlan, traced: Bool, target: ConduitNotificationTarget?, sentAt: Date?, ring: HermesRing?, error: Error?) {
        if let error {
            calls[id] = nil
            let code = (error as? CXErrorCodeIncomingCallError)?.code
            nativeCallsLogger.notice("Hermes call not shown: \(LogRedaction.message(error), privacy: .public)")
            if traced {
                HermesCallTrace.shared.note("CallKit didn't show it (code \(code.map { String($0.rawValue) } ?? "unknown"))")
            }
            // A call that should have rung didn't (one CallKit already has
            // is no new call): Hermes hears it went unanswered.
            if code != .callUUIDAlreadyExists, plan == .ring || plan == .endAtOnce(.missed) {
                report(.missed, for: target, sentAt: sentAt)
            }
            if let ring, plan == .ring, Self.stopsWatchRing(after: code) {
                if traced { HermesCallTrace.shared.note("Silenced here: the Watch stops ringing too") }
                settleRing(ring, outcome: .declined)
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
            endedAtOnce(plan, target: target, sentAt: sentAt)
        case .ring:
            guard calls[id] != nil else { return }
            HermesCallTrace.shared.note(calls[id]?.watchStopped == true ? "Ringing (in the car: not on the Watch)" : "Ringing")
            calls[id]?.unanswered = Task {
                do { try await Task.sleep(for: Self.unansweredAfter) } catch { return }
                guard self.calls[id]?.answered == false else { return }
                self.finish(id, reason: .unanswered, notice: .missed)
            }
            // Hermes' connection starts coming up while it rings.
            AppStateRuntimeRegistry.shared.appState.setNativeHermesCallActive(true)
        }
    }

    /// Whether a push is reported to CallKit: every one that rings, and
    /// every one iOS needs a call for.
    static func showsCall(_ plan: HermesNativeCallPlan, mustReport: Bool) -> Bool {
        mustReport || plan == .ring
    }

    /// A push that doesn't ring: its notice instead.
    private func endedAtOnce(_ plan: HermesNativeCallPlan, target: ConduitNotificationTarget?, sentAt: Date?) {
        guard case .endAtOnce(let notice) = plan else { return }
        post(notice, for: target)
        // A call that arrived too late never rang, so no one could have
        // answered it: Hermes hears it was missed.
        if notice == .missed { report(.missed, for: target, sentAt: sentAt) }
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
        // Answering is the go-ahead for the call's voice to listen, locked
        // or not.
        AppStateRuntimeRegistry.shared.appState.setNativeHermesCallAnswered(true)
        let id = action.callUUID
        // The Apple Watch stops ringing (Conduit is running the call, so no
        // background time is needed). A call kept from the Watch's answer
        // is the Watch's ring already.
        if let ring = calls[id]?.ring, calls[id]?.keptFromWatch != true {
            calls[id]?.settling = Task { await HermesRingSettler.settle(ring, by: .phone, outcome: .answered) }
        }
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
        // The Apple Watch rang too and was answered first: the call is there.
        // Declined there first, the answer here still stands: the user
        // picked up on the iPhone.
        if let settling = calls[id]?.settling, case .alreadySettled(.answered, by: .watch) = await settling.value {
            guard calls[id] != nil else { return }
            HermesCallTrace.shared.note("Answered on the Watch first")
            finish(id, reason: .answeredElsewhere, notice: .none, end: .elsewhere(.answered))
            return
        }
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

    /// An answered call's own voice conversation is running. Until then,
    /// voice an interruption ended isn't the call's, and restarting it
    /// would take the call's place (its open finds voice in use).
    var isCallVoiceRunning: Bool { calls.values.contains { $0.voiceStarted } }

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
                calls[id]?.voiceStarted = true
                inAppMuteChanged(id, muted: appState.nativeCallVoiceMuted)
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
    /// `end`: how it ended when not by `notice` alone (on the Watch).
    private func finish(_ id: UUID, reason: CXCallEndedReason, notice: HermesNativeCallPlan.Notice, end: HermesCallEnd? = nil) {
        guard let call = calls.removeValue(forKey: id) else { return }
        HermesCallTrace.shared.note("Call ended (\(Self.traceLabel(reason)))")
        call.unanswered?.cancel()
        call.work?.cancel()
        endOnWatch(call)
        provider?.reportCall(with: id, endedAt: Date(), reason: reason)
        post(notice, for: call.target)
        // It rang out, or stopped ringing, before the user picked up.
        report(HermesCallOutcome.of(end ?? .finished(notice), answered: call.answered), for: call.target, sentAt: call.sentAt)
        settle()
    }

    /// The Apple Watch answered or declined a call that rang on both: this
    /// one stops ringing. Reported to CallKit when iOS needs it (always
    /// before iOS 26.4): a call still on the phone is reported again under
    /// its own id, which CallKit already has; any other is reported and
    /// ended at once. Where iOS needs no call for the push (`mustReport`
    /// false: a call is still on here, or Conduit is in the foreground),
    /// none is reported.
    private func ringSettled(_ settled: HermesRingSettled, mustReport: Bool = true, completion: @escaping () -> Void) {
        guard let provider else {
            completion()
            return
        }
        let match = calls.first { $0.value.ring?.id == settled.id }
        let reason: CXCallEndedReason = settled.outcome == .answered ? .answeredElsewhere : .declinedElsewhere
        guard mustReport else {
            if let match, !match.value.answered, keepWatchAnswer(match.key, settled: settled) {
                completion()
                return
            }
            if let match, !match.value.answered {
                HermesCallTrace.shared.note(settled.outcome == .answered ? "Answered on the Watch" : "Declined on the Watch")
                finish(match.key, reason: reason, notice: settled.outcome == .answered ? .none : .missed, end: .elsewhere(settled.outcome))
            }
            if let start = settled.start {
                pruneRingTargets()
                startWatchCall(start, ringID: settled.id, ring: match?.value.ring ?? ringTargets[settled.id]?.ring)
            }
            completion()
            return
        }
        let id = match?.key ?? UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "hermes")
        update.localizedCallerName = match?.value.callerName ?? HermesCallerName.fallback
        update.hasVideo = false
        provider.reportNewIncomingCall(with: id, update: update) { _ in
            // CallKit calls back on its own queue: the provider is read again
            // on the main actor rather than carried over from there.
            Task { @MainActor in
                if match != nil, self.calls[id]?.answered == false, self.keepWatchAnswer(id, settled: settled) {
                    completion()
                    return
                }
                if match != nil {
                    // Answered here too: the race in `connect` settles it.
                    if self.calls[id]?.answered == false {
                        HermesCallTrace.shared.note(settled.outcome == .answered ? "Answered on the Watch" : "Declined on the Watch")
                        // Declined there, it leaves the same missed call a decline here does.
                        self.finish(id, reason: reason, notice: settled.outcome == .answered ? .none : .missed, end: .elsewhere(settled.outcome))
                    } else if self.calls[id] == nil {
                        // Ended meanwhile: the report above may have rung it again.
                        self.provider?.reportCall(with: id, endedAt: Date(), reason: reason)
                    }
                } else {
                    self.provider?.reportCall(with: id, endedAt: Date(), reason: reason)
                }
                if let start = settled.start {
                    self.pruneRingTargets()
                    self.startWatchCall(start, ringID: settled.id, ring: match?.value.ring ?? self.ringTargets[settled.id]?.ring)
                }
                completion()
            }
        }
    }

    /// The Apple Watch answered, and its link to this phone is down under
    /// its call screen: its call's start came with the stop. It's answered
    /// as if it had come over the link, and the answer (the session, or why
    /// not) goes to the relay, sealed, for the Watch to fetch.
    private func startWatchCall(_ sealedStart: String, ringID: String, ring: HermesRing?) {
        let log = WatchVoiceLink.shared.log
        guard let ring else {
            log.note("watchAnswerHandoff", ["ok": false, "why": "unknownRing"])
            return
        }
        guard let key = HermesRingHandoffKey.load() else {
            log.note("watchAnswerHandoff", ["ok": false, "why": "noKey"])
            return
        }
        guard let start = HermesRingHandoff.openStart(sealedStart, key: key, ringID: ringID) else {
            log.note("watchAnswerHandoff", ["ok": false, "why": "unreadableStart"])
            return
        }
        var taskID = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard taskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "conduit.hermesCall.watchStart", expirationHandler: end)
        let startedAt = Date()
        WatchVoiceLink.shared.startAnsweredCall(start) { reply in
            guard let data = reply[WatchVoiceWire.messageKey] as? Data,
                  let sealed = try? HermesRingHandoff.seal(data, root: key, direction: .session, ringID: ringID) else {
                log.note("watchAnswerHandoff", ["ok": false, "why": "unsealable", "bytes": (reply[WatchVoiceWire.messageKey] as? Data)?.count ?? 0])
                end()
                return
            }
            Task { @MainActor in
                let status = await HermesRingHandoff.store(ring, sealed: sealed)
                log.note("watchAnswerHandoff", [
                    "ok": status == 200,
                    "status": status,
                    "bytes": sealed.count,
                    "ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                ])
                end()
            }
        }
    }

    // MARK: Kept from the Watch (#1204)

    /// Where this phone's audio goes that keeps a call the Watch answered
    /// here: a headset, wired or Bluetooth (AirPods), which also says the
    /// phone is near. Never the car's (there the Watch doesn't ring).
    nonisolated static let headsetPorts: Set<AVAudioSession.Port> = [.headphones, .usbAudio, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE]

    nonisolated static func keepsWatchAnswer(watchControls: Bool, outputs: [AVAudioSession.Port]) -> Bool {
        watchControls && outputs.contains(where: headsetPorts.contains) && !outputs.contains(.carAudio)
    }

    /// The Watch said with its call token that it can leave an answered
    /// call on this phone's headset and control it (`callsToken`'s
    /// `phoneHeadset`); an older Watch can't.
    static let watchControlsKey = "hermesCalls.watchControlsPhoneCalls"

    /// The Watch answered a call still ringing here, with a headset on
    /// here: this phone answers its own ring instead, so the voice plays
    /// on the headset, and the Watch's call screen keeps Mute and End
    /// (HermesRingControl). Whether it does; false leaves the answer to the
    /// Watch, as before.
    private func keepWatchAnswer(_ id: UUID, settled: HermesRingSettled) -> Bool {
        // The same stop again (a repeated push): already being kept.
        if calls[id]?.keptFromWatch == true { return true }
        guard settled.outcome == .answered, let sealedStart = settled.start,
              let ring = calls[id]?.ring, calls[id]?.answered == false, !watchStartedRings.contains(ring.id),
              let key = HermesRingHandoffKey.load(),
              let start = HermesRingHandoff.openStart(sealedStart, key: key, ringID: ring.id),
              let callID = start.watchCallID else { return false }
        // The route as the call would have it.
        VoiceAudioSessionCoordinator.shared.configureForIncomingCall()
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        let watchControls = UserDefaults.standard.bool(forKey: Self.watchControlsKey)
        guard Self.keepsWatchAnswer(watchControls: watchControls, outputs: route) else {
            HermesCallTrace.shared.note(route.isEmpty ? "Answered on the Watch, no audio route here yet" : "Answered on the Watch, audio here on \(HermesCallAudioRoute.describe(.sharedInstance()))")
            return false
        }
        HermesCallTrace.shared.note("Answered on the Watch with a headset on here: keeping it here")
        calls[id]?.keptFromWatch = true
        calls[id]?.unanswered?.cancel()
        var taskID = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard taskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "conduit.hermesCall.keepFromWatch", expirationHandler: end)
        Task {
            defer { end() }
            await self.keepFromWatch(id, ring: ring, key: key, callID: callID, sealedStart: sealedStart)
        }
        return true
    }

    private func keepFromWatch(_ id: UUID, ring: HermesRing, key: Data, callID: UInt32, sealedStart: String) async {
        let log = WatchVoiceLink.shared.log
        // A relay that can't carry the Watch's Mute and End (older than
        // 0.17) leaves the call to the Watch: its End must end this one.
        // Read first, so a mute the Watch already sent stands; written
        // only for a ring the relay lost. A relay it can't read leaves the
        // call to the Watch rather than write over what it may hold.
        var control: HermesRingControl.State?
        switch await HermesRingControl.current(ring) {
        case .state(let state): control = state
        case .gone: control = await HermesRingControl.set(ring, by: .phone, muted: false, attempts: 2)
        case .notYet, .retry: control = nil
        }
        guard let control else {
            log.note("watchAnswerKept", ["ok": false, "why": "noControl"])
            handBackToWatch(id, ring: ring, sealedStart: sealedStart)
            return
        }
        guard calls[id] != nil else {
            // Ended here meanwhile: so is the Watch's.
            _ = await HermesRingControl.set(ring, by: .phone, ended: true, attempts: 5)
            return
        }
        do {
            try await callController.request(CXTransaction(action: CXAnswerCallAction(call: id)))
        } catch {
            log.note("watchAnswerKept", ["ok": false, "why": "answer", "error": error.localizedDescription])
            handBackToWatch(id, ring: ring, sealedStart: sealedStart)
            return
        }
        // Muted or ended on the Watch already: so is this call, and an
        // ended one needs no call screen there.
        if control.seq > 0 { await watchControlChanged(id, state: control) }
        guard !control.ended, calls[id] != nil else { return }
        // The Watch's start waits on this, for its call screen to control
        // this call.
        guard let data = try? JSONEncoder().encode(WatchVoiceWire.Message.callOnPhone(callID: callID)),
              let sealed = try? HermesRingHandoff.seal(data, root: key, direction: .session, ringID: ring.id) else { return }
        // The Watch can only hear it this way while it's on its call screen.
        var status = 0
        for attempt in 1...3 {
            status = await HermesRingHandoff.store(ring, sealed: sealed)
            let retryable = status == 0 || status == 429 || (500..<600).contains(status)
            guard retryable, attempt < 3, calls[id] != nil else { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        log.note("watchAnswerKept", ["ok": status == 200, "status": status])
        guard calls[id] != nil else { return }
        calls[id]?.following = Task {
            await HermesRingControl.follow(ring, after: control.seq, rewrite: {
                // The relay restarted: this call's mute again, or its end.
                guard let call = self.calls[id] else { return await HermesRingControl.set(ring, by: .phone, ended: true, attempts: 5) != nil }
                return await HermesRingControl.set(ring, by: .phone, muted: call.controlMuted, attempts: 5) != nil
            }, changed: { state in
                await self.watchControlChanged(id, state: state)
            })
        }
    }

    /// Whether the call answering this ring is kept here from the Watch's
    /// answer: a Watch start for it gets `callOnPhone`, never a session.
    func keepsWatchAnswer(ringID: String) -> Bool {
        calls.values.contains { $0.keptFromWatch && $0.ring?.id == ringID }
    }

    /// Rings whose Watch call already started over the link: never kept
    /// here after that, or both would answer.
    private var watchStartedRings: [String] = []

    func startedOnWatch(ringID: String) {
        guard !watchStartedRings.contains(ringID) else { return }
        watchStartedRings = Array((watchStartedRings + [ringID]).suffix(16))
    }

    /// Kept from the Watch, then couldn't be: the Watch takes the call, as
    /// when it answers with no headset here.
    private func handBackToWatch(_ id: UUID, ring: HermesRing, sealedStart: String) {
        guard calls[id]?.answered == false else { return }
        HermesCallTrace.shared.note("Couldn't keep it here: the Watch takes it")
        calls[id]?.keptFromWatch = false
        finish(id, reason: .answeredElsewhere, notice: .none, end: .elsewhere(.answered))
        startWatchCall(sealedStart, ringID: ring.id, ring: ring)
    }

    /// The Watch's Mute or End, for a call kept from its answer.
    private func watchControlChanged(_ id: UUID, state: HermesRingControl.State) async {
        guard calls[id]?.keptFromWatch == true else { return }
        if state.ended {
            calls[id]?.controlEnded = true
            HermesCallTrace.shared.note("Ended on the Watch")
            try? await callController.request(CXTransaction(action: CXEndCallAction(call: id)))
            return
        }
        guard calls[id]?.controlMuted != state.muted else { return }
        calls[id]?.controlMuted = state.muted
        HermesCallTrace.shared.note(state.muted ? "Muted on the Watch" : "Unmuted on the Watch")
        try? await callController.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: state.muted)))
    }

    /// Muted or unmuted here: the Watch's call screen hears it.
    private func muteOnWatch(_ id: UUID, muted: Bool) {
        guard let call = calls[id], call.keptFromWatch, let ring = call.ring, call.controlMuted != muted else { return }
        calls[id]?.controlMuted = muted
        var taskID = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard taskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "conduit.hermesCall.muteOnWatch", expirationHandler: end)
        Task {
            defer { end() }
            // Until it lands, or a newer mute or the call's end takes over.
            var rounds = 0
            while self.calls[id]?.controlMuted == muted {
                if await HermesRingControl.set(ring, by: .phone, muted: muted, attempts: 5) != nil { return }
                rounds += 1
                if rounds == 1 { HermesCallTrace.shared.note("The Watch didn't hear the \(muted ? "mute" : "unmute") yet") }
                guard rounds < 12 else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// The call's voice was muted or unmuted by its own controls in
    /// Conduit (the call screen's Mute, the minimised bar, Classic's
    /// microphone): the Watch hears it, and CallKit's Mute shows it.
    private func inAppMuteChanged(_ id: UUID, muted: Bool?) {
        guard let muted, let call = calls[id], call.keptFromWatch else { return }
        let before = call.inAppMuted
        calls[id]?.inAppMuted = muted
        // Its first reading counts only as a mute (made before the voice
        // was in use): the voice may not show a mute from the Watch yet.
        guard before.map({ $0 != muted }) ?? muted, call.controlMuted != muted else { return }
        HermesCallTrace.shared.note(muted ? "Muted in Conduit" : "Unmuted in Conduit")
        muteOnWatch(id, muted: muted)
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) { _ in }
    }

    /// A call kept from the Watch's answer ended here: so does the Watch's.
    private func endOnWatch(_ call: Call) {
        guard call.keptFromWatch, let ring = call.ring else { return }
        call.following?.cancel()
        guard !call.controlEnded else { return }
        var taskID = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard taskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "conduit.hermesCall.endOnWatch", expirationHandler: end)
        Task {
            _ = await HermesRingControl.set(ring, by: .phone, ended: true, attempts: 10)
            end()
        }
    }

    /// The call a Watch call answers (designs/hermes-calls-watch.md), kept
    /// from its push. A phone call still ringing for it is left for the
    /// relay's stop, which comes as a VoIP push: ended here first, that push
    /// would have to show a call of its own and end it at once, and iOS has
    /// killed Conduit in the background for that. It stops here after
    /// `watchStopWait`, in case the relay's word never comes.
    func answeredOnWatch(ringID: String) -> ConduitNotificationTarget? {
        pruneRingTargets()
        if let match = calls.first(where: { $0.value.ring?.id == ringID }), !match.value.answered {
            let id = match.key
            HermesCallTrace.shared.note("Answered on the Watch, waiting for the relay's stop")
            match.value.unanswered?.cancel()
            calls[id]?.unanswered = Task {
                do { try await Task.sleep(for: Self.watchStopWait) } catch { return }
                guard self.calls[id]?.answered == false else { return }
                HermesCallTrace.shared.note("Answered on the Watch, no stop from the relay")
                self.finish(id, reason: .answeredElsewhere, notice: .none, end: .elsewhere(.answered))
            }
        }
        return ringTargets[ringID]?.target
    }

    private func pruneRingTargets(now: Date = Date()) {
        ringTargets = ringTargets.filter { now.timeIntervalSince($0.value.at) < Self.ringTargetLife }
    }

    /// Tells the relay how this phone settled the ring, with the time to
    /// finish if Conduit goes back to the background meanwhile.
    @discardableResult
    private func settleRing(_ ring: HermesRing, outcome: HermesRingOutcome) -> Task<HermesRingSettleResult, Never> {
        var taskID = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard taskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "conduit.hermesCall.settle", expirationHandler: end)
        return Task {
            let result = await HermesRingSettler.settle(ring, by: .phone, outcome: outcome)
            end()
            return result
        }
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
        endOnWatch(call)
        action.fulfill()
        // Declined here: the Apple Watch stops ringing too.
        if !call.answered, let ring = call.ring { settleRing(ring, outcome: .declined) }
        if call.answered {
            endVoice(of: call.target)
        } else {
            post(.missed, for: call.target)
        }
        report(HermesCallOutcome.of(.declined, answered: call.answered), for: call.target, sentAt: call.sentAt)
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

    private func observeRoute() {
        stopObservingRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            // On main: the block's assumeIsolated depends on it.
            queue: .main
        ) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                HermesCallTrace.shared.note(
                    "Audio route: \(HermesCallAudioRoute.describe(.sharedInstance())) (\(HermesCallAudioRoute.describe(reason)))"
                )
            }
        }
    }

    private func stopObservingRoute() {
        guard let routeObserver else { return }
        NotificationCenter.default.removeObserver(routeObserver)
        self.routeObserver = nil
    }

    private func settle() {
        guard calls.isEmpty else { return }
        stopObservingRoute()
        VoiceAudioSessionCoordinator.shared.nativeCallEnded()
        AppStateRuntimeRegistry.shared.existing?.setNativeHermesCallActive(false)
    }

    /// The user didn't pick up: the host that placed the call hears so,
    /// now if it can be reached, else once it's connected again. Timed from
    /// when the relay sent it: one that reached an offline phone hours
    /// later was placed then, not now.
    private func report(_ outcome: HermesCallOutcome?, for target: ConduitNotificationTarget?, sentAt: Date?) {
        guard let outcome, let target,
              let entry = HermesCallOutcomeOutbox.Entry(outcome, target: target, at: sentAt ?? Date()) else { return }
        HermesCallOutcomeOutbox.record(entry, in: .standard)
        AppStateRuntimeRegistry.shared.existing?.deliverHermesCallOutcomes()
    }

    private func post(_ notice: HermesNativeCallPlan.Notice, for target: ConduitNotificationTarget?) {
        let request: UNNotificationRequest?
        switch notice {
        case .none: request = nil
        case .missed: request = target.flatMap { HermesCallNotifications.callRequest(for: $0, missed: true, callerName: Self.profileName($0)) }
        case .talk: request = target.flatMap { HermesCallNotifications.callRequest(for: $0, missed: false) }
        case .unreadable: request = HermesCallNotifications.unreadableMissedCallRequest()
        }
        guard let request else { return }
        Task { await HermesCallNotifications.post(request) }
    }
}

// MARK: - PushKit

extension HermesNativeCalls: PKPushRegistryDelegate {
    private nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = Self.hex(pushCredentials.token)
        MainActor.assumeIsolated {
            guard registry === self.registry, self.isRinging else { return }
            PushNotificationService.shared.updateVoIPToken(token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated {
            guard registry === self.registry, self.isRinging else { return }
            PushNotificationService.shared.updateVoIPToken(nil)
        }
    }

    /// iOS 26.4+ calls this one instead, saying whether the push needs a
    /// CallKit call: one that can't ring here and needn't be reported
    /// shows none.
    @available(iOS 26.4, *)
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload, metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping @Sendable () -> Void) {
        let userInfo = payload.dictionaryPayload
        let mustReport = metadata.mustReport
        MainActor.assumeIsolated {
            self.receive(userInfo, mustReport: mustReport, completion: completion)
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
                self.endOnWatch(call)
                // A call still ringing leaves its trace, as on every other end.
                if !call.answered { self.post(.missed, for: call.target) }
                self.report(HermesCallOutcome.of(.reset, answered: call.answered), for: call.target, sentAt: call.sentAt)
            }
            self.calls = [:]
            self.audioActive = false
            VoiceAudioSessionCoordinator.shared.nativeCallAudioDeactivated()
            self.stopObservingRoute()
            NotificationCenter.default.post(name: .hermesCallAudioDeactivated, object: nil)
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
            self.muteOnWatch(action.callUUID, muted: action.isMuted)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            HermesCallTrace.shared.note("CallKit audio on")
            VoiceAudioSessionCoordinator.shared.nativeCallAudioActivated()
            HermesCallTrace.shared.note("Audio route: \(HermesCallAudioRoute.describe(audioSession))")
            self.audioActive = true
            self.observeRoute()
            self.resumeAudioWaiters()
            NotificationCenter.default.post(name: .hermesCallAudioActivated, object: nil)
            AppStateRuntimeRegistry.shared.existing?.hermesCallAudioActivated()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            HermesCallTrace.shared.note("CallKit audio off")
            VoiceAudioSessionCoordinator.shared.nativeCallAudioDeactivated()
            self.audioActive = false
            self.stopObservingRoute()
            NotificationCenter.default.post(name: .hermesCallAudioDeactivated, object: nil)
        }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
    }
}

extension Notification.Name {
    /// CallKit gave a call from Hermes its audio: at the answer, or back
    /// after an interruption. Under CallKit the system's interruption end
    /// isn't promised, so voice an interruption paused resumes on this.
    /// Answered in the car, CallKit's audio can also come on after the
    /// call's voice started on a session Conduit activated itself (#1145).
    static let hermesCallAudioActivated = Notification.Name("conduit.hermesCall.audioActivated")
    /// CallKit took the call's audio back (an interruption, or the call
    /// ending): nothing plays or records until it's activated again.
    static let hermesCallAudioDeactivated = Notification.Name("conduit.hermesCall.audioDeactivated")
}

/// Where a call's audio goes, in a call trace's words.
enum HermesCallAudioRoute {
    static func describe(_ session: AVAudioSession) -> String {
        let outputs = session.currentRoute.outputs.map { describe($0.portType) }
        let speakerDefault = session.categoryOptions.contains(.defaultToSpeaker) ? ", speaker by default" : ""
        return (outputs.isEmpty ? "no output" : outputs.joined(separator: " + ")) + speakerDefault
    }

    static func describe(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInSpeaker: return "Speaker"
        case .builtInReceiver: return "Earpiece"
        case .headphones: return "Headphones"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "Bluetooth"
        case .carAudio: return "CarPlay"
        default: return port.rawValue
        }
    }

    static func describe(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable?: return "device added"
        case .oldDeviceUnavailable?: return "device removed"
        case .categoryChange?: return "category"
        case .override?: return "override"
        case .wakeFromSleep?: return "wake"
        case .noSuitableRouteForCategory?: return "no route"
        case .routeConfigurationChange?: return "configuration"
        default: return "other"
        }
    }
}
