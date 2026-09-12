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
}

extension CPInterfaceController: CarPlayInterfacing {}

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

    private var stateObservation: AnyCancellable?

    internal init() {}

    // MARK: - Scene lifecycle

    /// `CPTemplateApplicationSceneDelegate` connect. Installs the root
    /// template synchronously (before returning from the scene callback),
    /// binds the shared AppState, and starts async Voice establishment under
    /// the current generation.
    func handleConnect(_ interfacing: any CarPlayInterfacing) {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        // Defensive: never two live sinks, even for an unpaired re-connect.
        stateObservation?.cancel()
        stateObservation = nil
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
        beginObservingController(appState.voiceConversationController)

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
        interfacing = nil
        template = nil
        stateObservation?.cancel()
        stateObservation = nil
        lastActivatedState = nil
        isTemplatePresented = false
        pendingPresentationState = nil

        let appState = lastBoundAppState ?? appStateProvider()
        appState.setCarPlayVoiceSurfaceActive(false)
        appState.handleCarPlayVoiceSurfaceRemoved()
    }

    // MARK: - Template

    private func installRootTemplate() {
        guard let interfacing else { return }
        let generation = connectionGeneration
        let handlers = CarPlayVoiceActionHandlers(
            startListening: { [weak self] in self?.startListeningTurn() },
            endConversation: { [weak self] in self?.endConversation() }
        )
        let template = CarPlayVoiceTemplateFactory.makeTemplate(handlers: handlers)
        self.template = template
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

    private func beginObservingController(_ controller: VoiceConversationController) {
        stateObservation?.cancel()
        stateObservation = controller.$state
            .sink { [weak self] state in
                self?.handleControllerState(state)
            }
    }

    /// The single forwarding path from controller state to CarPlay. Internal
    /// so the duplicate-suppression policy is deterministically testable.
    func handleControllerState(_ state: VoiceConversationState) {
        guard isConnected else { return }
        guard let template else { return }
        let target = CarPlayVoiceState.map(state)
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
        lastActivatedState = activated
        stateActivator(template, activated)
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
        } else {
            outcome = await appState.prepareVoiceConversation(
                profile: nil,
                startsFreshConversation: false
            )
        }
        await completeListenTurn(generation: generation, outcome: outcome)
    }

    /// End button. Converges on the authoritative Close teardown — no
    /// parallel CarPlay teardown exists.
    func endConversation() {
        (lastBoundAppState ?? appStateProvider()).closeVoiceConversation()
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
        let controller = appState.voiceConversationController
        if controller.hasLiveVoiceSession {
            guard appState.attachToLiveVoiceConversation() else {
                handleControllerState(.failed(""))
                return
            }
            return
        }
        let outcome = await appState.prepareVoiceConversation(
            profile: nil,
            startsFreshConversation: false
        )
        await completeVoiceEstablishment(generation: generation, outcome: outcome)
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
