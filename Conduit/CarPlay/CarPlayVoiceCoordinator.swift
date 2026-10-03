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
    /// What the template's buttons currently offer.
    private(set) var controls: CarPlayVoiceControls = .initial
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
        showsBrowseButtons = false
        jobsObservation?.cancel()
        jobsObservation = nil
        jobsTemplate = nil
        self.interfacing = interfacing
        lastActivatedState = nil
        isTemplatePresented = false
        pendingPresentationState = nil

        // The template install satisfies the scene time budget first; it
        // needs no AppState. Registry resolution (which may construct the
        // AppState and run its cold-launch bootstrap) happens right after.
        installRootTemplate()

        let appState = appStateProvider()
        lastBoundAppState = appState
        appState.setCarPlayVoiceSurfaceActive(true)
        // Re-assert the Voice gate: the phone may be locked/backgrounded with
        // a gate left false by an earlier CarPlay-only disconnect, and the
        // driver's next Listen must be able to re-arm capture.
        appState.handleCarPlayVoiceSurfaceActivated()
        observeCurrentVoiceMode(appState)

        if autoEstablishOnConnect {
            Task { @MainActor [weak self] in
                await self?.establishVoice(generation: generation)
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
        showsBrowseButtons = false
        jobsObservation?.cancel()
        jobsObservation = nil
        jobsTemplate = nil
        lastActivatedState = nil
        isTemplatePresented = false
        pendingPresentationState = nil

        let appState = lastBoundAppState ?? appStateProvider()
        appState.setCarPlayVoiceSurfaceActive(false)
        appState.handleCarPlayVoiceSurfaceRemoved()
        appState.releaseCarPlayGeminiLive()
        appState.releaseCarPlayGPTLive()
        appState.releaseCarPlayGrokLive()
    }

    // MARK: - Template

    private func installRootTemplate() {
        guard let interfacing else { return }
        let generation = connectionGeneration
        let template = CarPlayVoiceTemplateFactory.makeTemplate(controls: controls, handlers: makeHandlers())
        self.template = template
        // The template opens on Ready.
        updateBrowseButtons(for: .ready)
        interfacing.setRootTemplate(template, animated: false) { [weak self] success, error in
            // MainActor Task hop (never a trapping assumeIsolated): the
            // completion is expected on the main queue, but a wrong-queue
            // delivery must degrade to a hop, not crash the process in a car.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A completion from a superseded connection must never mark
                // the new connection's template presented.
                guard self.isCurrent(generation), self.interfacing === interfacing else {
                    carPlayLogger.notice("stale root-template install completion ignored")
                    return
                }
                guard success, error == nil else {
                    carPlayLogger.error("root template install failed: \(String(describing: error), privacy: .public)")
                    return
                }
                self.isTemplatePresented = true
                // Re-assert the top bar for the presented state, so it never
                // rests on buttons set before the template was on screen.
                self.updateBrowseButtons(for: self.pendingPresentationState ?? .ready, force: true)
                // The template is installed before the AppState resolves,
                // so its buttons were built for the classic mode; they are
                // re-applied for the mode the profile actually uses.
                CarPlayVoiceTemplateFactory.apply(self.controls, to: template, handlers: self.makeHandlers())
                // The template presents its FIRST state (ready) by default;
                // activate a retained pending state exactly once when it
                // differs, then resume normal dedupe against the presented
                // state. If the factory ever changes its default first state,
                // keep this coupling in sync.
                let pending = self.pendingPresentationState ?? .ready
                self.pendingPresentationState = nil
                self.lastActivatedState = pending
                if pending != .ready {
                    self.stateActivator(template, pending)
                }
            }
        }
    }

    private func makeHandlers() -> CarPlayVoiceActionHandlers {
        CarPlayVoiceActionHandlers(
            startListening: { [weak self] in self?.startListeningTurn() },
            startNewChat: { [weak self] in self?.startNewChat() },
            toggleMicrophone: { [weak self] in self?.toggleMicrophone() },
            endConversation: { [weak self] in self?.endConversation() }
        )
    }

    /// Replaces the buttons when the mode or the microphone changes. The
    /// buttons carry no state of their own (Mute and Unmute both toggle the
    /// live value), so a label that lags never sends the wrong action.
    func updateControls(_ newControls: CarPlayVoiceControls) {
        guard newControls != controls else { return }
        controls = newControls
        guard isConnected, let template else { return }
        CarPlayVoiceTemplateFactory.apply(newControls, to: template, handlers: makeHandlers())
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
                self?.updateControls(CarPlayVoiceControls(isClassic: mode == .classic, isMicrophoneMuted: isMuted))
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

    private func forward(_ target: CarPlayVoiceState) {
        guard isConnected else { return }
        guard let template else { return }
        updateBrowseButtons(for: target)
        guard isTemplatePresented else {
            // Pre-presentation: activateVoiceControlState has no effect, so
            // only RETAIN the latest desired state. Recording it as
            // activated would suppress the real post-presentation activation
            // and freeze the surface on the template's default state.
            pendingPresentationState = target
            return
        }
        guard let activated = CarPlayVoiceStateActivation.activationTarget(
            lastActivated: lastActivatedState,
            newState: target
        ) else { return }
        let previous = lastActivatedState
        lastActivatedState = activated
        stateActivator(template, activated)
        playEarcon(from: previous, to: activated)
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

    private func makeBrowseHandlers() -> CarPlayBrowseHandlers {
        CarPlayBrowseHandlers(
            openChat: { [weak self] row in self?.openChat(row) },
            replayJob: { [weak self] jobID in self?.replayJob(jobID) },
            runShortcut: { [weak self] shortcut in self?.runShortcut(shortcut) },
            selectMode: { [weak self] mode in self?.selectVoiceMode(mode) },
            selectAgent: { [weak self] index in self?.selectAgent(at: index) }
        )
    }

    private func push(_ browseTemplate: CPTemplate) {
        // Only the Jobs list is kept current, and only while it is the
        // newest screen (the car's back button reports nothing).
        jobsObservation?.cancel()
        jobsObservation = nil
        jobsTemplate = nil
        guard let interfacing else { return }
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

    /// Back to the voice screen before Voice starts.
    private func returnToVoiceScreen() {
        jobsObservation?.cancel()
        jobsObservation = nil
        jobsTemplate = nil
        interfacing?.popToRootTemplate(animated: true, completion: nil)
    }

    func showChats() {
        guard isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        let rows = CarPlayBrowse.recentChats(from: appState.activeProfileSessions)
        push(CarPlayBrowseTemplateFactory.chatsTemplate(rows: rows, handlers: makeBrowseHandlers()))
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

    func performOpenChat(_ row: CarPlayChatRow, generation: UInt64) async {
        guard isCurrent(generation), isConnected else { return }
        let appState = lastBoundAppState ?? appStateProvider()
        observeCurrentVoiceMode(appState)
        let mode = CarPlayVoiceMode.current(in: appState)
        if let liveMode = CarPlayLiveVoiceMode(mode) {
            endConversation()
            // The phone shows the chat the call is attached to, as when the
            // call starts from that chat there.
            let opened = await appState.openSessionOutcome(row.sessionID)
            guard isCurrent(generation), isConnected else { return }
            guard opened == .opened else {
                settleUnopenedChat(opened)
                return
            }
            await establishLiveVoice(liveMode, appState: appState, generation: generation, attachingTo: row.thread)
            return
        }
        if appState.voiceConversationController.hasLiveVoiceSession {
            appState.closeVoiceConversation()
        }
        let opened = await appState.openSessionOutcome(row.sessionID)
        guard opened == .opened else {
            if isCurrent(generation), isConnected { settleUnopenedChat(opened) }
            return
        }
        let outcome = await prepareWaitingForConnection(appState: appState, generation: generation)
        await completeListenTurn(generation: generation, outcome: outcome)
    }

    /// A chat open that did not land: a superseded one (another chat was
    /// opened meanwhile) is navigation, so the car returns to Ready; only a
    /// failed one shows Error.
    private func settleUnopenedChat(_ outcome: AppState.SessionOpenOutcome) {
        handleControllerState(outcome == .superseded ? .idle : .failed(""))
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
        switch CarPlayVoiceMode.current(in: appState) {
        case .classic:
            break
        case .geminiLive:
            let gemini = appState.geminiLiveController
            switch CarPlayGeminiLiveListenAction.forPhase(gemini.phase) {
            case .start: await establishLiveVoice(.geminiLive, appState: appState, generation: generation)
            case .interrupt: gemini.interruptSpeaking()
            case .nothing: break
            }
            return
        case .gptLive:
            let gpt = appState.gptLiveController
            switch CarPlayGPTLiveListenAction.forPhase(gpt.phase) {
            case .start: await establishLiveVoice(.gptLive, appState: appState, generation: generation)
            case .nothing: break
            }
            return
        case .grokLive:
            let grok = appState.grokLiveController
            switch CarPlayGeminiLiveListenAction.forPhase(grok.phase) {
            case .start: await establishLiveVoice(.grokLive, appState: appState, generation: generation)
            case .interrupt: grok.interruptSpeaking()
            case .nothing: break
            }
            return
        }
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
                guard isCurrent(generation), isConnected else { return }
                // The car may show an Error the controller never had, so the
                // reopened listening window is shown again; a controller
                // that did not reach listening (it had failed) starts a
                // listening turn, so one tap always listens or errors.
                if controller.state == .listening {
                    handleControllerState(.listening)
                    return
                }
                // A resume that failed leaves the microphone paused, and a
                // listening turn would open with it closed, so the car shows
                // the error instead.
                guard !controller.isMicrophonePaused else {
                    handleControllerState(.failed(""))
                    return
                }
            }
        } else {
            outcome = await prepareWaitingForConnection(appState: appState, generation: generation)
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
        let outcome = await prepareWaitingForConnection(
            appState: appState,
            generation: generation,
            startsFreshConversation: true
        )
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
            case .connecting, .listening, .speaking: return true
            case .idle, .failed, .ending: return false
            }
        case .grokLive:
            return Self.canTakeNotice(appState.grokLiveController.phase)
        }
    }

    /// A call that is ending never speaks a notice, so it is not open.
    private static func canTakeNotice(_ phase: GeminiLiveConversationController.Phase) -> Bool {
        switch phase {
        case .connecting, .reconnecting, .listening, .speaking: return true
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

    // MARK: - Voice establishment

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
        let outcome = await prepareWaitingForConnection(appState: appState, generation: generation)
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
        if !appState.isConnected {
            appState.recoverTransportForCarPlayIfNeeded()
            forward(.processing)
            let waiter = connectionWaiter
            let timeout = connectionWaitTimeout
            connectionWaitTask?.cancel()
            let waitTask = Task { @MainActor () -> Bool in
                if let waiter { return await waiter(appState) }
                return await Self.awaitConnection(of: appState, timeout: timeout)
            }
            connectionWaitTask = waitTask
            let connected = await waitTask.value
            if connectionWaitTask == waitTask { connectionWaitTask = nil }
            guard connected else {
                if isCurrent(generation), isConnected { forward(.error) }
                return
            }
        }
        // The setting may have changed while Hermes was being reached; the
        // controls start whichever mode is current on the next tap.
        guard isCurrent(generation), isConnected, CarPlayVoiceMode.current(in: appState) == mode.voiceMode else { return }
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
        guard connected, isCurrent(generation), isConnected else {
            return .deferred
        }
        return await appState.prepareVoiceConversation(
            profile: nil,
            startsFreshConversation: startsFreshConversation
        )
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
