//
//  CarPlayVoiceCoordinator.swift
//  Conduit
//
//  MainActor bridge between the UIKit CarPlay scene (scene delegate +
//  CPInterfaceController) and the process-wide AppState/Voice stack.
//
//  Responsibilities are deliberately narrow — a reference, presentation, and
//  lifecycle seam, NOT a second Voice owner:
//    • installs the root CPVoiceControlTemplate on connect;
//    • observes the shared VoiceConversationController's published state and
//      forwards DEDUPLICATED, mapped states to CarPlay (never mic-level or
//      transcript content);
//    • rotates a connection generation so a stale async readiness completion
//      after disconnect/reconnect can never reopen Voice or touch a dead
//      interface controller — and applies the no-surface release contract
//      when a prepare was in flight across a disconnect;
//    • reports CarPlay surface (de)activation to AppState, which owns the
//      Voice lifecycle policy (PR #161 rules stay authoritative).
//    • opens the browse screens (Chats, Jobs, Shortcuts, Voice) from the
//      top bar at Ready/Error, and routes their taps into the same
//      listen/call paths; plays the classic mode's status sounds.
//

import Combine
import CarPlay
import Foundation
import OSLog

private let carPlayLogger = Logger(subsystem: "com.milim.relay", category: "CarPlayVoice")

/// Seam over `CPInterfaceController` so coordinator behavior is testable
/// without a vehicle session.
@MainActor
protocol CarPlayInterfacing: AnyObject {
    func setRootTemplate(
        _ rootTemplate: CPTemplate,
        animated: Bool,
        completion: ((Bool, (any Error)?) -> Void)?
    )
    func pushTemplate(
        _ templateToPush: CPTemplate,
        animated: Bool,
        completion: ((Bool, (any Error)?) -> Void)?
    )
    func popToRootTemplate(
        animated: Bool,
        completion: ((Bool, (any Error)?) -> Void)?
    )
}

extension CPInterfaceController: CarPlayInterfacing {}

/// The Voice mode the profile uses, which decides the controller CarPlay
/// presents and drives. AppState keeps at most one live mode enabled.
enum CarPlayVoiceMode: Equatable {
    case classic
    case geminiLive
    case gptLive
    case grokLive

    @MainActor
    static func current(in appState: AppState) -> CarPlayVoiceMode {
        if appState.isGeminiLiveEnabled { return .geminiLive }
        if appState.isGPTLiveEnabled { return .gptLive }
        if appState.isGrokLiveEnabled { return .grokLive }
        return .classic
    }
}

/// The live modes CarPlay starts itself, after waiting for Hermes.
enum CarPlayLiveVoiceMode: Equatable {
    case geminiLive
    case gptLive
    case grokLive

    /// The live mode for a profile's Voice mode; nil for classic.
    init?(_ mode: CarPlayVoiceMode) {
        switch mode {
        case .classic: return nil
        case .geminiLive: self = .geminiLive
        case .gptLive: self = .gptLive
        case .grokLive: self = .grokLive
        }
    }

    var voiceMode: CarPlayVoiceMode {
        switch self {
        case .geminiLive: return .geminiLive
        case .gptLive: return .gptLive
        case .grokLive: return .grokLive
        }
    }
}

@MainActor
final class CarPlayVoiceCoordinator {
    static let shared = CarPlayVoiceCoordinator()

    private(set) weak var interfacing: (any CarPlayInterfacing)?
    private(set) var template: CPVoiceControlTemplate?
    /// Monotonic fence: every connect and disconnect rotates the generation;
    /// async completions captured under an older generation are discarded.
    private(set) var connectionGeneration: UInt64 = 0
    private(set) var lastActivatedState: CarPlayVoiceState?
    /// True once the root template's `setRootTemplate` completion reported
    /// success for the CURRENT generation. `activateVoiceControlState` is a
    /// documented no-op before presentation, and calling it early would
    /// poison duplicate suppression (the pre-presentation activation is
    /// ignored, then the dedupe never forwards the real transition) — so no
    /// state is forwarded until this flips.
    private(set) var isTemplatePresented = false
    /// Latest desired CarPlay state while the template is not yet presented.
    /// Retained (not activated); consumed exactly once on presentation.
    private(set) var pendingPresentationState: CarPlayVoiceState?
    /// The AppState this coordinator bound to on connect. Disconnect and the
    /// controls converge on THIS instance (never a fresh provider resolve),
    /// so a swapped provider cannot split surface bookkeeping across two
    /// AppStates. Test-only observability; intentionally retained.
    private(set) var lastBoundAppState: AppState?

    var isConnected: Bool { interfacing != nil }

    /// Test seam; production resolves the process-wide registry.
    var appStateProvider: @MainActor () -> AppState = { AppStateRuntimeRegistry.shared.appState }
    /// Production connects always spawn the establish task; tests disable
    /// this and call `establishVoice(generation:)` directly so async Voice
    /// establishment is deterministic.
    var autoEstablishOnConnect = true
    /// Test seam over template state activation (rate-limited by the system
    /// template and a no-op before the template is presented).
    var stateActivator: @MainActor (CPVoiceControlTemplate, CarPlayVoiceState) -> Void = {
        $0.activateVoiceControlState(withIdentifier: $1.identifier)
    }

    /// How long a CarPlay open waits for Hermes to (re)connect before it
    /// settles into the error state. In a car the phone is usually locked,
    /// so the connection is often still being restored or re-established
    /// when CarPlay connects; failing on the first `.deferred` reported
    /// Voice unavailable for a connection that was seconds away.
    var connectionWaitTimeout: Duration = .seconds(20)
    /// Test seam over the connection wait. nil (production) observes the
    /// bound AppState's `isConnected` for up to `connectionWaitTimeout`.
    var connectionWaiter: (@MainActor (AppState) async -> Bool)?
    /// The in-flight connection wait, cancelled at every connect and
    /// disconnect so a wait for a surface that is gone resolves at once
    /// instead of holding its observation for the rest of the timeout.
    private var connectionWaitTask: Task<Bool, Never>?

    private var stateObservation: AnyCancellable?
    /// Follows the microphone mute of the observed mode's controller.
    private var controlsObservation: AnyCancellable?
    /// Which mode's controller `stateObservation` follows.
    private(set) var observedVoiceMode: CarPlayVoiceMode?
    /// What the template's buttons should offer.
    private(set) var controls: CarPlayVoiceControls = .initial
    /// What the root template on the car was built with. Its states' action
    /// buttons are never changed in place (see `CarPlayVoiceTemplateFactory`),
    /// so new controls install a new template.
    private(set) var templateControls: CarPlayVoiceControls = .initial
    /// The chat list waits for the voice screen to be on the car before it
    /// is pushed over it.
    private(set) var isChatPickerPending = false
    /// The voice screen's last install failed, so nothing will be pushed
    /// over it.
    private(set) var didTemplateInstallFail = false
    /// A pending state whose sound already played as its replacement
    /// template began, so a failed replacement doesn't play it twice.
    private var soundedPendingState: CarPlayVoiceState?
    /// Whether the top bar's browse buttons are showing. They show only at
    /// Ready and Error: Apple requires the voice screen while Voice runs.
    private(set) var showsBrowseButtons = false
    /// The Voice Jobs list last opened, kept current as jobs change.
    private weak var jobsTemplate: CPListTemplate?
    private var jobsObservation: AnyCancellable?
    /// Whether the Jobs list on screen is being kept current.
    var isObservingJobs: Bool { jobsObservation != nil }
    /// The profiles the open Voice list offered, in row order.
    private var listedAgentProfiles: [String] = []
    /// The chat the driver picked from the chat list. A live call started
    /// from the car's Listen button is attached to it too, not only the
    /// call the pick starts (#378).
    private(set) var chosenChat: CarPlayChatRow?
    /// Rotated by every chat pick, so an earlier pick still opening never
    /// starts a call after a newer one.
    private var chatOpenRequest: UInt64 = 0
    /// Rotated by the End button. A start still waiting for Hermes (or for
    /// its chat to open) when End was tapped never goes on to start (#378).
    private(set) var voiceStartRequest: UInt64 = 0
    /// A list is pushed over the voice screen. A conversation that starts
    /// meanwhile (from the phone, say) brings the voice screen back (#378).
    private(set) var isBrowsing = false
    /// Test seam; production asks UIKit whether the phone screen is up.
    var phoneScreenProvider: @MainActor () -> Bool = { PhoneScenePresence.isInForeground }

    /// Test seam over what the Error state names as the thing to fix.
    var setupIssueProvider: @MainActor (AppState, CarPlayVoiceMode) -> VoiceSetupIssue? = {
        CarPlayVoiceCoordinator.setupIssue(in: $0, mode: $1)
    }
    /// Test seam; production reads the device's CarPlay settings.
    var preferencesProvider: @MainActor () -> CarPlayPreferences = { CarPlayPreferences.shared }
    /// Test seam over the status sounds.
    var earconPlayer: @MainActor (CarPlayEarcon) -> Void = { earcon in
        CarPlayVoiceCoordinator.sharedEarcons.play(earcon)
    }
    private static let sharedEarcons = CarPlayEarconPlayer()

    internal init() {}

    // MARK: - Scene lifecycle

    /// `CPTemplateApplicationSceneDelegate` connect. Installs the root
    /// template synchronously (before returning from the scene callback),
    /// binds the shared AppState, and starts async Voice establishment under
    /// the current generation.
    func handleConnect(_ interfacing: any CarPlayInterfacing) {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionWaitTask?.cancel()
        connectionWaitTask = nil
        // Defensive: never two live sinks, even for an unpaired re-connect.
        stateObservation?.cancel()
        stateObservation = nil
        controlsObservation?.cancel()
        controlsObservation = nil
        observedVoiceMode = nil
        controls = .initial
        templateControls = .initial
        isChatPickerPending = false
        didTemplateInstallFail = false
        showsBrowseButtons = false
        jobsObservation?.cancel()
        jobsObservation = nil
        jobsTemplate = nil
        chosenChat = nil
        isBrowsing = false
        self.interfacing = interfacing
        lastActivatedState = nil
        isTemplatePresented = false
        pendingPresentationState = nil
        soundedPendingState = nil

        // The template install satisfies the scene time budget first; it
        // needs no AppState. Registry resolution (which may construct the
        // AppState and run its cold-launch bootstrap) happens right after.
        installRootTemplate()

        let appState = appStateProvider()
        lastBoundAppState = appState
        appState.setCarPlayVoiceSurfaceActive(true)
        // The car may have launched Conduit with no phone screen at all.
        if !phoneScreenProvider() {
            appState.handleCarPlayConnectedWithoutPhoneScreen()
        }
        // Re-assert the Voice gate: the phone may be locked/backgrounded with
        // a gate left false by an earlier CarPlay-only disconnect, and the
        // driver's next Listen must be able to re-arm capture.
        appState.handleCarPlayVoiceSurfaceActivated()
        observeCurrentVoiceMode(appState)

        if autoEstablishOnConnect {
            Task { @MainActor [weak self] in
                await self?.establishOnConnect(generation: generation)
            }
        }
    }

    /// `CPTemplateApplicationSceneDelegate` disconnect. Rotates the fence so
    /// in-flight establishment becomes stale, unbinds presentation, and hands
    /// the lifecycle decision to the BOUND AppState: an active phone Voice
    /// surface keeps the conversation; a CarPlay-only conversation releases
    /// the runtime exactly like the PR #161 background boundary.
    func handleDisconnect() {
        connectionGeneration &+= 1
        connectionWaitTask?.cancel()
        connectionWaitTask = nil
        interfacing = nil
        template = nil
        stateObservation?.cancel()
        stateObservation = nil
        controlsObservation?.cancel()
        controlsObservation = nil
        observedVoiceMode = nil
        controls = .initial
        templateControls = .initial
        isChatPickerPending = false
        didTemplateInstallFail = false
        showsBrowseButtons = false
        jobsObservation?.cancel()
        jobsObservation = nil
        jobsTemplate = nil
        chosenChat = nil
        isBrowsing = false
        lastActivatedState = nil
        isTemplatePresented = false
        pendingPresentationState = nil
        soundedPendingState = nil

        let appState = lastBoundAppState ?? appStateProvider()
        appState.setCarPlayVoiceSurfaceActive(false)
        appState.handleCarPlayVoiceSurfaceRemoved()
        appState.releaseCarPlayGeminiLive()
        appState.releaseCarPlayGPTLive()
        appState.releaseCarPlayGrokLive()
    }

    // MARK: - Template

    /// Installs a voice template built for the current controls, opening on
    /// `initialState`. Used on connect, and again whenever the controls
    /// change (a template's buttons are never replaced on the car).
    private func installRootTemplate(
        presenting initialState: CarPlayVoiceState = .ready,
        replacing previous: PresentedTemplate? = nil
    ) {
        guard let interfacing else { return }
        let isReplacement = previous != nil
        let generation = connectionGeneration
        let builtControls = controls
        let template = CarPlayVoiceTemplateFactory.makeTemplate(
            controls: builtControls,
            presenting: initialState,
            handlers: makeHandlers()
        )
        self.template = template
        templateControls = builtControls
        isTemplatePresented = false
        didTemplateInstallFail = false
        updateBrowseButtons(for: initialState, force: true)
        interfacing.setRootTemplate(template, animated: false) { [weak self] success, error in
            // MainActor Task hop (never a trapping assumeIsolated): the
            // completion is expected on the main queue, but a wrong-queue
            // delivery must degrade to a hop, not crash the process in a car.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A completion from a superseded connection, or for a
                // template already replaced, must never mark the current
                // template presented.
                guard self.isCurrent(generation), self.interfacing === interfacing,
                      self.template === template else {
                    carPlayLogger.notice("stale root-template install completion ignored")
                    return
                }
                guard success, error == nil else {
                    carPlayLogger.error("root template install failed: \(String(describing: error), privacy: .public)")
                    // A replacement that failed leaves the previous
                    // template on the car, so it stays the one the car is
                    // driven through; the next change of controls tries
                    // again.
                    if let previous {
                        self.restore(previous)
                        return
                    }
                    self.didTemplateInstallFail = true
                    // A chat list waiting on this screen would never show,
                    // so Voice starts as it did before the list existed
                    // (`showChatPicker` does the same for a later request).
                    if self.isChatPickerPending {
                        self.isChatPickerPending = false
                        Task { @MainActor [weak self] in
                            await self?.establishVoice(generation: generation)
                        }
                    }
                    return
                }
                self.isTemplatePresented = true
                // The template presents its FIRST state (`initialState`) by
                // itself; activate a retained pending state exactly once when
                // it differs, then resume normal dedupe against it.
                let pending = self.pendingPresentationState ?? initialState
                self.pendingPresentationState = nil
                self.soundedPendingState = nil
                self.lastActivatedState = pending
                // Re-assert the top bar for the presented state, so it never
                // rests on buttons set before the template was on screen.
                self.updateBrowseButtons(for: pending, force: true)
                // The first template is installed before the AppState
                // resolves, so it was built for the classic mode; the
                // controls may also have changed while it was on its way.
                // Either way the car gets a template built for them.
                guard self.controls == builtControls else {
                    self.reinstallRootTemplate()
                    return
                }
                // A replacement template is also told its state outright,
                // Ready included, rather than relying only on it opening on
                // its first one. The first install keeps presenting Ready
                // by itself.
                if pending != initialState || isReplacement {
                    self.stateActivator(template, pending)
                }
                if self.isChatPickerPending {
                    self.isChatPickerPending = false
                    // Never over a conversation that started meanwhile.
                    let appState = self.lastBoundAppState ?? self.appStateProvider()
                    if !Self.hasRunningConversation(in: appState) {
                        self.showChats()
                    }
                }
            }
        }
    }

    /// The voice template on the car, kept while its replacement installs.
    struct PresentedTemplate {
        let template: CPVoiceControlTemplate
        let controls: CarPlayVoiceControls
        let shownState: CarPlayVoiceState
    }

    /// Replaces the voice template for new controls, opening on the state
    /// the car is showing.
    private func reinstallRootTemplate() {
        let shown = shownState ?? .ready
        let previous = template.map { PresentedTemplate(template: $0, controls: templateControls, shownState: shown) }
        pendingPresentationState = nil
        lastActivatedState = nil
        installRootTemplate(presenting: shown, replacing: previous)
    }

    /// Goes back to the template still on the car after its replacement
    /// failed, and shows it the state that arrived meanwhile.
    private func restore(_ previous: PresentedTemplate) {
        // A list still waiting is not opened from a failed replacement.
        isChatPickerPending = false
        template = previous.template
        templateControls = previous.controls
        isTemplatePresented = true
        lastActivatedState = previous.shownState
        let pending = pendingPresentationState
        pendingPresentationState = nil
        updateBrowseButtons(for: previous.shownState, force: true)
        // New controls this replacement carried (buttons, or the Error
        // title's cause) wait for the next controls change: retrying here
        // would loop while installs keep failing.
        // The failure sound already played when the replacement began.
        let sounded = soundedPendingState
        soundedPendingState = nil
        if let pending { forward(pending, playsEarcon: pending != sounded) }
    }

    /// The buttons' handlers, fenced to the connection whose template they
    /// are on: a tap queued across a reconnect never acts on the new
    /// connection's conversation. Internal so the stale-tap test can hold
    /// an earlier connection's handlers.
    func makeHandlers() -> CarPlayVoiceActionHandlers {
        let generation = connectionGeneration
        func fenced(_ action: @escaping (CarPlayVoiceCoordinator) -> Void) -> () -> Void {
            { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                action(self)
            }
        }
        return CarPlayVoiceActionHandlers(
            startListening: fenced { $0.startListeningTurn() },
            startNewChat: fenced { $0.startNewChat() },
            toggleMicrophone: fenced { $0.toggleMicrophone() },
            endConversation: fenced { $0.endTapped() }
        )
    }

    /// New buttons when the mode or the microphone changes, as a new
    /// template (#361). The buttons carry no state of their own (Mute and
    /// Unmute both toggle the live value), so a label that lags never sends
    /// the wrong action.
    func updateControls(_ newControls: CarPlayVoiceControls) {
        guard newControls != controls else { return }
        controls = newControls
        // Before presentation the install completion compares the controls
        // and reinstalls itself.
        guard isConnected, template != nil, isTemplatePresented,
              templateControls != newControls else { return }
        reinstallRootTemplate()
    }

    /// Follows the controller for the profile's current Voice mode. The
    /// live mode settings can change while CarPlay is connected, so the
    /// controls re-check them and AppState reports the change.
    private func observeCurrentVoiceMode(_ appState: AppState) {
        let mode = CarPlayVoiceMode.current(in: appState)
        guard observedVoiceMode != mode else { return }
        observedVoiceMode = mode
        switch mode {
        case .classic: beginObservingController(appState.voiceConversationController)
        case .geminiLive: beginObservingGeminiLive(appState.geminiLiveController)
        case .gptLive: beginObservingGPTLive(appState.gptLiveController)
        // Grok Live runs on Gemini Live's controller, so its phases map the same.
        case .grokLive: beginObservingGeminiLive(appState.grokLiveController)
        }
        let muted: AnyPublisher<Bool, Never>
        switch mode {
        case .classic: muted = appState.voiceConversationController.$isMicrophonePaused.eraseToAnyPublisher()
        case .geminiLive: muted = appState.geminiLiveController.$isMicrophoneMuted.eraseToAnyPublisher()
        case .gptLive: muted = appState.gptLiveController.$isMicrophoneMuted.eraseToAnyPublisher()
        case .grokLive: muted = appState.grokLiveController.$isMicrophoneMuted.eraseToAnyPublisher()
        }
        controlsObservation?.cancel()
        controlsObservation = muted
            .removeDuplicates()
            .sink { [weak self] isMuted in
                guard let self else { return }
                var updated = self.controls
                updated.isClassic = mode == .classic
                updated.isMicrophoneMuted = isMuted
                self.updateControls(updated)
            }
    }

    /// A live mode setting changed: show the controller now in use.
    func voiceModeChanged(in appState: AppState) {
        guard isConnected, lastBoundAppState === appState else { return }
        observeCurrentVoiceMode(appState)
    }

    private func beginObservingController(_ controller: VoiceConversationController) {
        stateObservation?.cancel()
        stateObservation = controller.$state
            .sink { [weak self] state in
                self?.handleControllerState(state)
            }
    }

    /// Gemini Live and Grok Live mode: CarPlay shows the conversation's phase
    /// instead of the classic controller's state.
    private func beginObservingGeminiLive(_ controller: GeminiLiveConversationController) {
        stateObservation?.cancel()
        stateObservation = controller.$phase
            .sink { [weak self] phase in
                self?.forward(CarPlayVoiceState.map(geminiLive: phase))
            }
    }

    /// GPT-Live mode: CarPlay shows the GPT-Live call's phase.
    private func beginObservingGPTLive(_ controller: GPTLiveConversationController) {
        stateObservation?.cancel()
        stateObservation = controller.$phase
            .sink { [weak self] phase in
                self?.forward(CarPlayVoiceState.map(gptLive: phase))
            }
    }

    /// The single forwarding path from controller state to CarPlay. Internal
    /// so the duplicate-suppression policy is deterministically testable.
    func handleControllerState(_ state: VoiceConversationState) {
        forward(CarPlayVoiceState.map(state))
    }

    private func forward(_ target: CarPlayVoiceState, playsEarcon: Bool = true) {
        guard isConnected, template != nil else { return }
        var replacedFrom: CarPlayVoiceState?
        if target == .error {
            // The Error title names what to fix. A different one than the
            // car's template was built with means a new template, opening
            // on the state the car shows; Error then follows it.
            let shownBefore = shownState
            let wasPresented = isTemplatePresented
            noteErrorIssue()
            if wasPresented, !isTemplatePresented { replacedFrom = shownBefore }
        }
        guard let template else { return }
        updateBrowseButtons(for: target)
        guard isTemplatePresented else {
            // Pre-presentation: activateVoiceControlState has no effect, so
            // only RETAIN the latest desired state. Recording it as
            // activated would suppress the real post-presentation activation
            // and freeze the surface on the template's default state.
            pendingPresentationState = target
            // The failure sound is not held back by the new template.
            // A restore replaying an Error that already sounded stays quiet
            // even when the Error's cause changed and starts another
            // replacement.
            if let replacedFrom {
                if playsEarcon { playEarcon(from: replacedFrom, to: target) }
                soundedPendingState = target
            }
            return
        }
        guard let activated = CarPlayVoiceStateActivation.activationTarget(
            lastActivated: lastActivatedState,
            newState: target
        ) else { return }
        let previous = lastActivatedState
        lastActivatedState = activated
        stateActivator(template, activated)
        if playsEarcon { playEarcon(from: previous, to: activated) }
        // A conversation is listening or talking (one started on the phone,
        // say): the voice screen shows it, rather than a list the driver has
        // to back out of first. Thinking alone doesn't count: a call that is
        // ending passes through it.
        if activated == .listening || activated == .responding, isBrowsing {
            returnToVoiceScreen()
        }
    }

    /// Records what the Error state should name as the thing to fix.
    private func noteErrorIssue() {
        let appState = lastBoundAppState ?? appStateProvider()
        var updated = controls
        // The mode whose controller reported the failure, even if the
        // setting changed a moment ago.
        updated.errorIssue = setupIssueProvider(appState, observedVoiceMode ?? CarPlayVoiceMode.current(in: appState))
        updateControls(updated)
    }

    /// What stops Voice in `mode`, as far as the app can tell: no Hermes
    /// connection, then for classic Voice its switch, a denied microphone
    /// and its speech providers; for a live mode its host, then a denied
    /// microphone. nil
    /// when nothing in the setup explains the failure.
    static func setupIssue(
        in appState: AppState,
        mode: CarPlayVoiceMode,
        isMicrophoneDenied: Bool = VoiceSetupIssue.isMicrophoneDenied
    ) -> VoiceSetupIssue? {
        if !appState.isConnected { return .notConnected }
        // Voice never turned on is the first thing to fix: until it is,
        // iOS never asked for the microphone.
        if mode == .classic, !appState.isVoiceEnabled { return .voiceOff }
        switch mode {
        case .classic:
            if isMicrophoneDenied { return .microphoneDenied }
            return appState.voiceSetupIssue
        // The controllers keep a host issue only while the call is failed
        // on it. Not gated on `phase` here: this runs inside the `$phase`
        // sink, where the property still reads the phase being replaced.
        // The host is checked before the microphone is asked for, so a
        // host issue is what stopped this call even with the mic denied.
        case .geminiLive:
            return liveIssue(appState.geminiLiveController.hostIssue, .geminiLive)
                ?? (isMicrophoneDenied ? .microphoneDenied : nil)
        case .gptLive:
            return liveIssue(appState.gptLiveController.hostIssue, .gptLive)
                ?? (isMicrophoneDenied ? .microphoneDenied : nil)
        case .grokLive:
            return liveIssue(appState.grokLiveController.hostIssue, .grokLive)
                ?? (isMicrophoneDenied ? .microphoneDenied : nil)
        }
    }

    private static func liveIssue(_ hostIssue: LiveVoiceHostIssue?, _ mode: LiveVoiceModeName) -> VoiceSetupIssue? {
        switch hostIssue {
        case .pluginMissing: return .notifierPluginMissing
        case .notSetUp: return .liveModeNotSetUp(mode)
        case nil: return nil
        }
    }

    /// Status sounds, classic mode only (see `CarPlayEarcon`).
    private func playEarcon(from previous: CarPlayVoiceState?, to state: CarPlayVoiceState) {
        guard observedVoiceMode == .classic,
              preferencesProvider().playsSounds,
              let earcon = CarPlayEarcon.forTransition(from: previous, to: state) else { return }
        earconPlayer(earcon)
    }

    // MARK: - Browse screens

    private func updateBrowseButtons(for state: CarPlayVoiceState, force: Bool = false) {
        let shows = state == .ready || state == .error
        guard force || shows != showsBrowseButtons else { return }
        showsBrowseButtons = shows
        guard let template, #available(iOS 26.4, *) else { return }
        if shows {
            template.leadingNavigationBarButtons = [
                CPBarButton(title: AppLocalization.string("Chats")) { [weak self] _ in self?.showChats() },
                CPBarButton(title: AppLocalization.string("Jobs")) { [weak self] _ in self?.showJobs() },
            ]
            template.trailingNavigationBarButtons = [
                CPBarButton(title: AppLocalization.string("Shortcuts")) { [weak self] _ in self?.showShortcuts() },
                CPBarButton(title: AppLocalization.string("Voice")) { [weak self] _ in self?.showVoiceOptions() },
            ]
        } else {
            template.leadingNavigationBarButtons = []
            template.trailingNavigationBarButtons = []
        }
    }

    /// The browse screens' row handlers, fenced like the voice buttons to
    /// the connection the screen was built for.
    func makeBrowseHandlers() -> CarPlayBrowseHandlers {
        let generation = connectionGeneration
        func fenced<Value>(_ action: @escaping (CarPlayVoiceCoordinator, Value) -> Void) -> (Value) -> Void {
            { [weak self] value in
                guard let self, self.isCurrent(generation) else { return }
                action(self, value)
            }
        }
        func fencedAction(_ action: @escaping (CarPlayVoiceCoordinator) -> Void) -> () -> Void {
            { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                action(self)
            }
        }
        return CarPlayBrowseHandlers(
            openChat: fenced { $0.openChat($1) },
            newVoiceChat: fencedAction { $0.startNewVoiceChat() },
            replayJob: fenced { $0.replayJob($1) },
            runShortcut: fenced { $0.runShortcut($1) },
            selectMode: fenced { $0.selectVoiceMode($1) },
            selectAgent: fenced { $0.selectAgent(at: $1) }
        )
    }

    private func push(_ browseTemplate: CPTemplate) {
        // A screen the driver opens wins over a chat list still waiting
        // for the voice screen.
        isChatPickerPending = false
        // Only the Jobs list is kept current, and only while it is the
        // newest screen (the car's back button reports nothing).
        jobsObservation?.cancel()
        jobsObservation = nil
        jobsTemplate = nil
        guard let interfacing else { return }
        isBrowsing = true
        interfacing.pushTemplate(browseTemplate, animated: true, completion: nil)
    }

    /// A screen left the car's display (the back button included). The Jobs
    /// list stops being kept current once it is gone.
    func handleTemplateDidDisappear(_ disappeared: CPTemplate) {
        guard let jobsTemplate, disappeared === jobsTemplate else { return }
        jobsObservation?.cancel()
        jobsObservation = nil
        self.jobsTemplate = nil
    }

    /// The voice screen is back on top (the car's back button included).
    func handleTemplateDidAppear(_ appeared: CPTemplate) {
        guard let template, appeared === template else { return }
        isBrowsing = false
    }

    /// Back to the voice screen before Voice starts.
    private func returnToVoiceScreen() {
        isBrowsing = false
        jobsObservation?.cancel()
        jobsObservation = nil
        jobsTemplate = nil
        interfacing?.popToRootTemplate(animated: true, completion: nil)
    }

    /// The chat list: New voice chat, then pinned chats, then recent ones.
    func showChats() {
        guard isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        let chats = CarPlayBrowse.chatList(
            from: appState.activeProfileSessions,
            isPinned: { appState.isSessionPinned($0) }
        )
        push(CarPlayBrowseTemplateFactory.chatsTemplate(chats: chats, handlers: makeBrowseHandlers()))
    }

    /// Shows the chat list over the voice screen once that is on the car.
    func showChatPicker() {
        guard isConnected else { return }
        guard !didTemplateInstallFail else {
            let generation = connectionGeneration
            Task { @MainActor [weak self] in
                await self?.establishVoice(generation: generation)
            }
            return
        }
        guard isTemplatePresented, templateControls == controls else {
            isChatPickerPending = true
            return
        }
        showChats()
    }

    /// New voice chat, from the chat list: Voice starts in a new chat, the
    /// one tap the car used to open with.
    func startNewVoiceChat() {
        returnToVoiceScreen()
        chosenChat = nil
        startNewChat()
    }

    func showJobs() {
        // A tap from a top bar left behind by a disconnect pushes nothing,
        // so it arms no observation either.
        guard isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        let supervisor = appState.voiceBackgroundJobSupervisor
        let handlers = makeBrowseHandlers()
        let list = CarPlayBrowseTemplateFactory.jobsTemplate(
            rows: CarPlayBrowse.jobRows(from: supervisor.jobs),
            handlers: handlers
        )
        push(list)
        jobsTemplate = list
        jobsObservation = supervisor.$jobs
            .dropFirst()
            .sink { [weak self] jobs in
                guard let self else { return }
                // A list CarPlay already released ends its own observation.
                guard let list = self.jobsTemplate else {
                    self.jobsObservation?.cancel()
                    self.jobsObservation = nil
                    return
                }
                list.updateSections(CarPlayBrowseTemplateFactory.jobSections(
                    rows: CarPlayBrowse.jobRows(from: jobs),
                    handlers: handlers
                ))
            }
    }

    func showShortcuts() {
        guard isConnected else { return }
        push(CarPlayBrowseTemplateFactory.shortcutsTemplate(
            shortcuts: preferencesProvider().shortcuts,
            handlers: makeBrowseHandlers()
        ))
    }

    func showVoiceOptions() {
        guard isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        listedAgentProfiles = appState.profiles.count > 1 ? appState.profiles : []
        push(CarPlayBrowseTemplateFactory.voiceTemplate(
            modes: CarPlayBrowse.modeRows(current: CarPlayVoiceMode.current(in: appState)),
            agents: CarPlayBrowse.agentRows(
                profiles: appState.profiles,
                active: appState.activeProfile,
                displayName: { appState.profileDisplayName($0) }
            ),
            handlers: makeBrowseHandlers()
        ))
    }

    /// A chat from the list: Voice continues in that chat. A live call is
    /// attached to it, as a call started from that chat on the phone is.
    func openChat(_ row: CarPlayChatRow) {
        returnToVoiceScreen()
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            await self?.performOpenChat(row, generation: generation)
        }
    }

    /// Voice starts as soon as the chat is picked, with no Listen tap
    /// (#378). Hermes may still be reconnecting (the phone is usually locked
    /// in a car), so the open waits for it rather than failing at once.
    func performOpenChat(_ row: CarPlayChatRow, generation: UInt64) async {
        guard isCurrent(generation), isConnected else { return }
        chosenChat = row
        chatOpenRequest &+= 1
        let request = chatOpenRequest
        let startRequest = voiceStartRequest
        // A newer pick, an End tap or a lost car ends this one.
        func isWanted() -> Bool {
            isCurrent(generation) && isConnected
                && chatOpenRequest == request && voiceStartRequest == startRequest
        }
        let appState = lastBoundAppState ?? appStateProvider()
        observeCurrentVoiceMode(appState)
        let mode = CarPlayVoiceMode.current(in: appState)
        if let liveMode = CarPlayLiveVoiceMode(mode) {
            endConversation()
            guard await waitForHermes(appState: appState, generation: generation), isWanted() else { return }
            // The phone shows the chat the call is attached to, as when the
            // call starts from that chat there.
            let opened = await appState.openSessionOutcome(row.sessionID)
            guard isWanted() else { return }
            if opened != .opened {
                // The phone not showing it doesn't change which chat the
                // driver picked: the call is still attached to it, so its
                // requests land there and not in new chats (#378).
                carPlayLogger.notice("picked chat did not open on the phone; the call still attaches to it")
            }
            await establishLiveVoice(liveMode, appState: appState, generation: generation, attachingTo: row.thread)
            return
        }
        if appState.voiceConversationController.hasLiveVoiceSession {
            appState.closeVoiceConversation()
        }
        guard await waitForHermes(appState: appState, generation: generation), isWanted() else { return }
        var opened = await appState.openSessionOutcome(row.sessionID)
        // Something on the phone (the automatic resume after reconnecting)
        // can take the chat view from the pick; the driver's pick wins.
        if opened == .superseded, isWanted() {
            opened = await appState.openSessionOutcome(row.sessionID)
        }
        guard isWanted() else { return }
        guard opened == .opened else {
            settleUnopenedChat(opened)
            return
        }
        let outcome = await prepareWaitingForConnection(appState: appState, generation: generation)
        guard voiceStartRequest == startRequest else {
            closeStartEndedMeanwhile(outcome)
            return
        }
        await completeListenTurn(generation: generation, outcome: outcome)
    }

    /// A chat open that did not land: only a failed one shows Error. A
    /// superseded one (another chat was opened meanwhile) is navigation, and
    /// the navigation that won publishes the car's next state, so nothing is
    /// shown over it.
    private func settleUnopenedChat(_ outcome: AppState.SessionOpenOutcome) {
        guard outcome == .failed else { return }
        handleControllerState(.failed(""))
    }

    /// A settled Voice Job: its outcome is spoken again in the conversation
    /// this starts (or the one already open).
    func replayJob(_ jobID: UUID) {
        returnToVoiceScreen()
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation), self.isConnected else { return }
            let appState = self.lastBoundAppState ?? self.appStateProvider()
            // The conversation opens first, so the replayed notice meets a
            // session that can speak it (a live call takes it once ready).
            await self.performStartListeningTurn(generation: generation)
            // A conversation that did not open shows its error; the outcome
            // is not queued for whichever chat Voice opens next.
            guard self.isCurrent(generation), self.isConnected,
                  self.hasOpenConversation(in: appState),
                  let shown = self.shownState, shown != .error else { return }
            appState.voiceBackgroundJobSupervisor.replayOutcome(jobID: jobID)
        }
    }

    /// A shortcut: its prompt starts as a Voice Job, and the conversation
    /// this opens speaks the result when the job is done.
    func runShortcut(_ shortcut: CarPlayShortcut) {
        returnToVoiceScreen()
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            await self?.performRunShortcut(shortcut, generation: generation)
        }
    }

    func performRunShortcut(_ shortcut: CarPlayShortcut, generation: UInt64) async {
        guard isCurrent(generation), isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        // A refused job (too many running) has no outcome to wait for, so
        // the car shows Error instead of opening a conversation.
        let created = CreatedJobBox()
        _ = await appState.voiceBackgroundJobSupervisor.startJob(
            instructions: shortcut.prompt,
            onJobCreated: { created.id = $0 }
        )
        guard isCurrent(generation), isConnected else { return }
        guard created.id != nil else {
            handleControllerState(.failed(""))
            return
        }
        await performStartListeningTurn(generation: generation)
    }

    /// Switches the profile's voice mode from the car. The running
    /// conversation ends first, as switching on the phone does.
    func selectVoiceMode(_ mode: CarPlayVoiceMode) {
        // A tap from a list left behind by a disconnect never changes the
        // saved mode.
        guard isConnected else { return }
        returnToVoiceScreen()
        let appState = lastBoundAppState ?? appStateProvider()
        guard mode != CarPlayVoiceMode.current(in: appState) else { return }
        endConversation()
        switch mode {
        case .classic:
            appState.setGeminiLiveEnabled(false)
            appState.setGPTLiveEnabled(false)
            appState.setGrokLiveEnabled(false)
        case .geminiLive: appState.setGeminiLiveEnabled(true)
        case .gptLive: appState.setGPTLiveEnabled(true)
        case .grokLive: appState.setGrokLiveEnabled(true)
        }
        observeCurrentVoiceMode(appState)
    }

    /// Switches the agent (Hermes profile) from the car.
    func selectAgent(at index: Int) {
        // A tap from a list left behind by a disconnect never ends the
        // conversation or switches the agent.
        guard isConnected else { return }
        returnToVoiceScreen()
        guard listedAgentProfiles.indices.contains(index) else { return }
        let profile = listedAgentProfiles[index]
        let appState = lastBoundAppState ?? appStateProvider()
        // A switch already under way would refuse this one, so the
        // conversation is left alone.
        guard profile != appState.activeProfile, !appState.isProfileSwitching else { return }
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation), self.isConnected else { return }
            // A profile change replaces the voice gateway, so the
            // conversation ends first, as switching on the phone does.
            self.endConversation()
            await appState.switchProfile(to: profile)
            guard self.isCurrent(generation), self.isConnected else { return }
            // A switch that failed (and rolled back) shows Error rather
            // than a closed conversation with no explanation.
            guard appState.activeProfile == profile else {
                self.handleControllerState(.failed(""))
                return
            }
            // The picked chat belongs to the agent left behind.
            self.chosenChat = nil
            self.observeCurrentVoiceMode(appState)
        }
    }

    // MARK: - Controls

    /// Listen button (Ready/Error states). Reuses the shared prepare/attach
    /// path — never forces Continuous Conversation on and never creates a
    /// parallel session decision.
    func startListeningTurn() {
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            await self?.performStartListeningTurn(generation: generation)
        }
    }

    func performStartListeningTurn(generation: UInt64) async {
        guard isCurrent(generation), isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        observeCurrentVoiceMode(appState)
        // A live call started here belongs to the chat the driver picked, as
        // the call the pick started did (#378).
        let thread = chosenChat?.thread
        switch CarPlayVoiceMode.current(in: appState) {
        case .classic:
            break
        case .geminiLive:
            let gemini = appState.geminiLiveController
            switch CarPlayGeminiLiveListenAction.forPhase(gemini.phase) {
            case .start: await establishLiveVoice(.geminiLive, appState: appState, generation: generation, attachingTo: thread)
            case .interrupt: gemini.interruptSpeaking()
            case .nothing: break
            }
            return
        case .gptLive:
            let gpt = appState.gptLiveController
            switch CarPlayGPTLiveListenAction.forPhase(gpt.phase) {
            case .start: await establishLiveVoice(.gptLive, appState: appState, generation: generation, attachingTo: thread)
            case .nothing: break
            }
            return
        case .grokLive:
            let grok = appState.grokLiveController
            switch CarPlayGeminiLiveListenAction.forPhase(grok.phase) {
            case .start: await establishLiveVoice(.grokLive, appState: appState, generation: generation, attachingTo: thread)
            case .interrupt: grok.interruptSpeaking()
            case .nothing: break
            }
            return
        }
        let startRequest = voiceStartRequest
        let controller = appState.voiceConversationController
        var outcome = AppState.VoiceConversationPrepareOutcome.handled
        if controller.hasLiveVoiceSession {
            // Attach (re-arm the gateway if the runtime was suspended); a
            // failed attach settles the surface into the error state instead
            // of a silent no-op listen.
            guard appState.attachToLiveVoiceConversation() else {
                handleControllerState(.failed(""))
                return
            }
            // A microphone the driver paused stays paused through a new
            // listening window, so Listen reopens it, as the phone's
            // microphone button does.
            if controller.isMicrophonePaused {
                await controller.resumeMicrophone()
                // A mode switch during the resume leaves the car to the new
                // mode's controller; End tapped meanwhile already closed it.
                guard isCurrent(generation), isConnected, voiceStartRequest == startRequest,
                      CarPlayVoiceMode.current(in: appState) == .classic else { return }
                // A resume that failed or was refused leaves the microphone
                // paused, and listening would run with it closed, so the car
                // shows the error instead. Otherwise the reopened listening
                // window is shown again (the car may show an Error the
                // controller never had), or a controller that did not reach
                // listening starts a listening turn.
                guard !controller.isMicrophonePaused else {
                    handleControllerState(.failed(""))
                    return
                }
                if controller.state == .listening {
                    handleControllerState(.listening)
                    return
                }
            }
        } else {
            outcome = await prepareWaitingForConnection(appState: appState, generation: generation)
            guard voiceStartRequest == startRequest else {
                closeStartEndedMeanwhile(outcome)
                return
            }
        }
        await completeListenTurn(generation: generation, outcome: outcome)
    }

    /// New Chat button (classic mode, Ready/Error states): the current chat's
    /// conversation closes and listening starts in a new chat, the same
    /// fresh prepare a wake phrase uses. A live mode has no chat to continue,
    /// so the button falls back to Listen there.
    func startNewChat() {
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            await self?.performStartNewChat(generation: generation)
        }
    }

    func performStartNewChat(generation: UInt64) async {
        guard isCurrent(generation), isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        observeCurrentVoiceMode(appState)
        guard CarPlayVoiceMode.current(in: appState) == .classic else {
            await performStartListeningTurn(generation: generation)
            return
        }
        if appState.voiceConversationController.hasLiveVoiceSession {
            appState.closeVoiceConversation()
        }
        // A new chat is no longer the one picked from the list.
        chosenChat = nil
        let startRequest = voiceStartRequest
        let outcome = await prepareWaitingForConnection(
            appState: appState,
            generation: generation,
            startsFreshConversation: true
        )
        guard voiceStartRequest == startRequest else {
            closeStartEndedMeanwhile(outcome)
            return
        }
        await completeListenTurn(generation: generation, outcome: outcome)
    }

    /// Mute/Unmute button. Toggles the same microphone mute the phone's
    /// controls use (the classic mode's microphone pause).
    func toggleMicrophone() {
        guard isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        switch CarPlayVoiceMode.current(in: appState) {
        case .classic:
            let controller = appState.voiceConversationController
            if controller.isMicrophonePaused {
                // A failed resume settles the controller into .failed, which
                // the state observation forwards to the car.
                let generation = connectionGeneration
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(generation), self.isConnected else { return }
                    await controller.resumeMicrophone()
                }
            } else {
                controller.pauseMicrophone()
            }
        case .geminiLive:
            let gemini = appState.geminiLiveController
            gemini.setMicrophoneMuted(!gemini.isMicrophoneMuted)
        case .gptLive:
            let gpt = appState.gptLiveController
            gpt.setMicrophoneMuted(!gpt.isMicrophoneMuted)
        case .grokLive:
            let grok = appState.grokLiveController
            grok.setMicrophoneMuted(!grok.isMicrophoneMuted)
        }
    }

    /// The state the car shows, or will show once the template is up.
    private var shownState: CarPlayVoiceState? {
        isTemplatePresented ? lastActivatedState : pendingPresentationState
    }

    /// Whether the current mode's conversation is open (or connecting), so
    /// it can take a notice.
    private func hasOpenConversation(in appState: AppState) -> Bool {
        switch CarPlayVoiceMode.current(in: appState) {
        case .classic:
            return appState.voiceConversationController.hasLiveVoiceSession
        case .geminiLive:
            return Self.canTakeNotice(appState.geminiLiveController.phase)
        case .gptLive:
            switch appState.gptLiveController.phase {
            case .connecting, .listening, .speaking, .paused: return true
            case .idle, .failed, .ending: return false
            }
        case .grokLive:
            return Self.canTakeNotice(appState.grokLiveController.phase)
        }
    }

    /// A call that is ending never speaks a notice, so it is not open.
    private static func canTakeNotice(_ phase: GeminiLiveConversationController.Phase) -> Bool {
        switch phase {
        case .connecting, .reconnecting, .listening, .speaking, .paused: return true
        case .idle, .failed, .ending: return false
        }
    }

    /// End button. Converges on the authoritative Close teardown — no
    /// parallel CarPlay teardown exists.
    func endConversation() {
        // A tap delivered across a disconnect never closes a conversation
        // the phone kept.
        guard isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        switch CarPlayVoiceMode.current(in: appState) {
        case .classic: appState.closeVoiceConversation()
        case .geminiLive: appState.closeGeminiLiveConversation()
        case .gptLive: appState.closeGPTLiveConversation()
        case .grokLive: appState.closeGrokLiveConversation()
        }
    }

    /// The End button. The conversation closes, and so does any start still
    /// waiting for Hermes or for its chat to open: before, a live call
    /// waiting to connect could not be ended from the car (#378). With
    /// "Choose a chat first" on, the chat list comes back so the driver can
    /// go on in another chat. The picked chat is kept on purpose: Listen
    /// after End continues in it, as the driver picked it.
    func endTapped() {
        guard isConnected else { return }
        voiceStartRequest &+= 1
        connectionWaitTask?.cancel()
        connectionWaitTask = nil
        endConversation()
        // A start that was only waiting leaves no controller state behind
        // to bring the car back to Ready.
        forward(.ready)
        if preferencesProvider().choosesChatFirst {
            showChatPicker()
        }
    }

    /// A classic start whose prepare finished after End was tapped: a
    /// conversation it opened is closed again rather than left open.
    private func closeStartEndedMeanwhile(_ outcome: AppState.VoiceConversationPrepareOutcome) {
        guard isConnected, outcome == .handled else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        guard CarPlayVoiceMode.current(in: appState) == .classic else { return }
        appState.closeVoiceConversation()
    }

    // MARK: - Voice establishment

    /// What CarPlay opening does. A conversation already running on the
    /// phone is shown as before; otherwise, with "Choose a chat first" on,
    /// the driver picks the chat Voice opens in (#361) instead of Voice
    /// starting straight away.
    func establishOnConnect(generation: UInt64) async {
        guard isCurrent(generation), isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        if preferencesProvider().choosesChatFirst, !Self.hasRunningConversation(in: appState) {
            showChatPicker()
            return
        }
        await establishVoice(generation: generation)
    }

    /// Whether the profile's Voice mode has a conversation going, which
    /// CarPlay shows rather than asking for a chat.
    static func hasRunningConversation(in appState: AppState) -> Bool {
        switch CarPlayVoiceMode.current(in: appState) {
        case .classic: return appState.voiceConversationController.hasLiveVoiceSession
        case .geminiLive: return appState.geminiLiveController.isActive
        case .gptLive: return appState.gptLiveController.isActive
        case .grokLive: return appState.grokLiveController.isActive
        }
    }

    /// Connect-time Voice establishment. A live conversation is attached
    /// display-only (no restart, no new session, no listen start — the phone
    /// may be mid-turn); otherwise the shared prepare path runs and, on
    /// success, listening starts: the CarPlay launcher tap is the listen
    /// intent, and Continuous Conversation governs only turn-to-turn
    /// continuation.
    func establishVoice(generation: UInt64) async {
        guard isCurrent(generation), isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        observeCurrentVoiceMode(appState)
        switch CarPlayVoiceMode.current(in: appState) {
        case .classic:
            break
        case .geminiLive:
            // A conversation already running (started on the phone) is
            // just shown; otherwise the CarPlay launch starts one.
            let gemini = appState.geminiLiveController
            guard !gemini.isActive else {
                // Unmuted for the driver as with GPT-Live.
                gemini.setMicrophoneMuted(false)
                return
            }
            await establishLiveVoice(.geminiLive, appState: appState, generation: generation)
            return
        case .gptLive:
            let gpt = appState.gptLiveController
            guard !gpt.isActive else {
                // A call running on the phone is shown, not restarted. A
                // call muted on the phone is opened up for the driver, who
                // just got in and expects to be heard.
                gpt.setMicrophoneMuted(false)
                return
            }
            await establishLiveVoice(.gptLive, appState: appState, generation: generation)
            return
        case .grokLive:
            let grok = appState.grokLiveController
            guard !grok.isActive else {
                // Shown, not restarted, and unmuted for the driver as with GPT-Live.
                grok.setMicrophoneMuted(false)
                return
            }
            await establishLiveVoice(.grokLive, appState: appState, generation: generation)
            return
        }
        let controller = appState.voiceConversationController
        if controller.hasLiveVoiceSession {
            guard appState.attachToLiveVoiceConversation() else {
                handleControllerState(.failed(""))
                return
            }
            return
        }
        let startRequest = voiceStartRequest
        let outcome = await prepareWaitingForConnection(appState: appState, generation: generation)
        guard voiceStartRequest == startRequest else {
            closeStartEndedMeanwhile(outcome)
            return
        }
        await completeVoiceEstablishment(generation: generation, outcome: outcome)
    }

    /// Starts a live mode (Gemini Live, GPT-Live or Grok Live) for this CarPlay surface
    /// once Hermes is connected (both start through the host), waiting the
    /// same bounded time as the classic prepare path.
    func establishLiveVoice(
        _ mode: CarPlayLiveVoiceMode,
        appState: AppState,
        generation: UInt64,
        attachingTo thread: VoiceThreadTarget? = nil
    ) async {
        let startRequest = voiceStartRequest
        guard await waitForHermes(appState: appState, generation: generation) else { return }
        // The setting may have changed while Hermes was being reached; the
        // controls start whichever mode is current on the next tap. End
        // tapped meanwhile starts nothing.
        guard isCurrent(generation), isConnected, voiceStartRequest == startRequest,
              CarPlayVoiceMode.current(in: appState) == mode.voiceMode else { return }
        switch mode {
        case .geminiLive:
            await appState.startGeminiLiveForCarPlay(attachingTo: thread)
            // The surface went away while connecting: nothing presents it now.
            if !isCurrent(generation) || !isConnected {
                appState.releaseCarPlayGeminiLive()
            }
        case .gptLive:
            await appState.startGPTLiveForCarPlay(attachingTo: thread)
            if !isCurrent(generation) || !isConnected {
                appState.releaseCarPlayGPTLive()
            }
        case .grokLive:
            await appState.startGrokLiveForCarPlay(attachingTo: thread)
            if !isCurrent(generation) || !isConnected {
                appState.releaseCarPlayGrokLive()
            }
        }
        // End tapped while the call was starting: the call it closed may
        // not have been running yet, so close whatever started after it.
        if isCurrent(generation), isConnected, voiceStartRequest != startRequest {
            endConversation()
            forward(.ready)
        }
    }

    /// Runs the shared prepare path; when it defers because Hermes is not
    /// connected yet, waits (bounded) for the connection and prepares once
    /// more. A connection that never arrives keeps `.deferred`, which the
    /// callers settle into the error state.
    func prepareWaitingForConnection(
        appState: AppState,
        generation: UInt64,
        startsFreshConversation: Bool = false
    ) async -> AppState.VoiceConversationPrepareOutcome {
        let outcome = await appState.prepareVoiceConversation(
            profile: nil,
            startsFreshConversation: startsFreshConversation
        )
        guard outcome == .deferred else { return outcome }
        carPlayLogger.notice("voice prepare deferred: waiting for Hermes to connect")
        // A lost transport is re-established by the CarPlay surface itself
        // while the phone is locked; make sure a cycle is armed.
        appState.recoverTransportForCarPlayIfNeeded()
        // Show that Hermes is being reached instead of sitting on Ready.
        handleControllerState(.thinking)
        let connected = await awaitConnectionCancellably(appState) ?? false
        guard connected, isCurrent(generation), isConnected else {
            return .deferred
        }
        return await appState.prepareVoiceConversation(
            profile: nil,
            startsFreshConversation: startsFreshConversation
        )
    }

    /// Waits (bounded) for Hermes when it isn't connected, showing Thinking
    /// meanwhile. False when it never connected: the car then shows Error,
    /// unless the car went away, End was tapped, or a newer start took the
    /// wait over.
    private func waitForHermes(appState: AppState, generation: UInt64) async -> Bool {
        guard !appState.isConnected else { return true }
        let startRequest = voiceStartRequest
        appState.recoverTransportForCarPlayIfNeeded()
        forward(.processing)
        guard let connected = await awaitConnectionCancellably(appState) else { return false }
        guard connected else {
            if isCurrent(generation), isConnected, voiceStartRequest == startRequest { forward(.error) }
            return false
        }
        return true
    }

    /// The connection wait, held where the next connect, disconnect, End
    /// tap or newer wait can cancel it. nil when one did.
    private func awaitConnectionCancellably(_ appState: AppState) async -> Bool? {
        let waiter = connectionWaiter
        let timeout = connectionWaitTimeout
        connectionWaitTask?.cancel()
        let waitTask = Task { @MainActor () -> Bool in
            if let waiter { return await waiter(appState) }
            return await Self.awaitConnection(of: appState, timeout: timeout)
        }
        connectionWaitTask = waitTask
        let connected = await waitTask.value
        // Clear the slot only if it still holds THIS wait: an overlapping
        // prepare on the same generation (connect-time establishment plus a
        // Listen tap) may have replaced it, and that newer wait must stay
        // cancellable by the next connect or disconnect.
        if connectionWaitTask == waitTask { connectionWaitTask = nil }
        if waitTask.isCancelled { return nil }
        return connected
    }

    /// Resolves true as soon as `appState.isConnected` is true, or false once
    /// `timeout` elapses first. Whenever the app is neither connected nor
    /// connecting during the wait (an in-flight restore failed), it hands off
    /// to CarPlay's own backoff recovery instead of leaving nothing armed for
    /// the rest of the wait.
    static func awaitConnection(of appState: AppState, timeout: Duration) async -> Bool {
        if appState.isConnected { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                let states = appState.$isConnected.combineLatest(appState.$isConnecting).values
                for await (connected, connecting) in states {
                    if connected { return true }
                    // Neither connected nor connecting — including on the
                    // first emission, so a restore that failed before this
                    // watcher subscribed is not missed. The recovery guard
                    // and planReconnect never double-arm an armed cycle.
                    if !connecting {
                        appState.recoverTransportForCarPlayIfNeeded()
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let connected = await group.next() ?? false
            group.cancelAll()
            return connected
        }
    }

    /// Post-prepare continuation of connect-time establishment, split out so
    /// the stale-completion fence is deterministically testable without
    /// racing a real in-flight prepare.
    func completeVoiceEstablishment(
        generation: UInt64,
        outcome: AppState.VoiceConversationPrepareOutcome
    ) async {
        guard fence(generation) else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        let controller = appState.voiceConversationController
        guard outcome == .handled, controller.hasLiveVoiceSession else {
            handleControllerState(.failed(""))
            return
        }
        await controller.startListening()
    }

    /// Post-prepare continuation of the Listen button, split out for the same
    /// deterministic fence coverage.
    func completeListenTurn(
        generation: UInt64,
        outcome: AppState.VoiceConversationPrepareOutcome
    ) async {
        guard fence(generation) else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        let controller = appState.voiceConversationController
        guard outcome == .handled, controller.hasLiveVoiceSession else {
            handleControllerState(.failed(""))
            return
        }
        await controller.startListening()
    }

    /// The stale-completion fence. A prepare that was in flight across a
    /// disconnect may have armed a live conversation (session acquisition +
    /// gateway + beginVoiceTurn) AFTER the surface disappeared; apply the
    /// no-surface release contract so a stale completion can never orphan a
    /// live session with nothing presenting it.
    private func fence(_ generation: UInt64) -> Bool {
        guard isCurrent(generation), isConnected else {
            let appState = lastBoundAppState ?? appStateProvider()
            if !appState.hasActiveVoiceSurface {
                appState.handleCarPlayVoiceSurfaceRemoved()
            }
            return false
        }
        return true
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        connectionGeneration == generation
    }
}

/// The id of the Voice Job a shortcut started, set when the supervisor
/// creates it.
@MainActor
private final class CreatedJobBox {
    var id: UUID?
}

