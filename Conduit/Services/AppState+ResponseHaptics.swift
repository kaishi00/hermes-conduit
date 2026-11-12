//
//  AppState+ResponseHaptics.swift
//  Conduit
//
//  The haptics that mark a reply's activity and its end. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Response haptics

    func applyResponseHapticSignal(_ signal: ResponseHapticPolicy.Signal) {
        switch signal {
        case .activity(let playsStart):
            registerResponseActivity(playsStart: playsStart)
        case .tool:
            registerToolHaptic()
        case .failure:
            failResponseHapticTurn()
        case .reset:
            resetResponseHapticTurn()
        }
    }

    private func registerResponseActivity(playsStart: Bool) {
        cancelPendingResponseHapticConclusion()
        performResponseHapticEffects(
            responseHaptics.registerActivity(playsStart: playsStart)
        )
    }

    private func registerToolHaptic() {
        cancelPendingResponseHapticConclusion()
        performResponseHapticEffects(responseHaptics.registerTool(at: Date()))
    }

    #if DEBUG
    var responseAwaitsUserInputForTesting: Bool { responseAwaitsUserInput }
    #endif

    var responseAwaitsUserInput: Bool {
        messages.contains { message in
            message.clarify.map { $0.hasPendingDecision } == true
                || message.approval.map { $0.status == .pending || $0.status == .submitting } == true
                || message.inputPrompt.map { $0.isAnswerable || $0.status == .submitting } == true
                || message.connection?.isOpen == true
        }
    }

    func scheduleResponseHapticConclusion(after delayMilliseconds: Int) {
        cancelPendingResponseHapticConclusion()
        guard let conclusion = responseHaptics.scheduleConclusion(
            sessionID: activeSessionId
        ) else { return }
        responseHapticConclusionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionId == conclusion.sessionID,
                  let effect = self.responseHaptics.finishConclusion(conclusion) else {
                return
            }
            self.responseHapticConclusionTask = nil
            self.performResponseHapticEffects([effect])
        }
    }

    private func failResponseHapticTurn() {
        responseHapticConclusionTask?.cancel()
        responseHapticConclusionTask = nil
        performResponseHapticEffects(responseHaptics.fail())
    }

    func resetResponseHapticTurn() {
        responseHapticConclusionTask?.cancel()
        responseHapticConclusionTask = nil
        performResponseHapticEffects(responseHaptics.reset())
    }

    func cancelPendingResponseHapticConclusion() {
        responseHapticConclusionTask?.cancel()
        responseHapticConclusionTask = nil
        responseHaptics.invalidateConclusion()
    }

    /// While a voice session may hold the audio session — Voice Conversation
    /// (listening, thinking, speaking, muted, transcribing, including a
    /// paused mic and the arming window) or a provider test — the custom
    /// Core Haptics response pattern is suppressed: Core Haptics must never
    /// contend with voice capture or reactivate the coordinator-owned
    /// session (issue #140). Response feedback falls back to the UIKit
    /// pattern in that state.
    var responseHapticsMayUseCoreHaptics: Bool {
        !voiceConversationController.hasLiveVoiceSession
    }

    /// Internal for testing: the response-haptic forwarding seam is the
    /// exact line that must degrade Core Haptics while a voice session is
    /// live, so tests drive it end to end.
    func performResponseHapticEffects(
        _ effects: [ResponseHapticState.Effect]
    ) {
        for effect in effects {
            switch effect {
            case .responseStarted:
                Haptics.responseStarted(coreHapticsAllowed: responseHapticsMayUseCoreHaptics)
            case .toolStarted:
                Haptics.toolStarted()
            case .responseConcluded:
                Haptics.responseConcluded()
            case .error:
                Haptics.error()
            case .cancelPattern:
                Haptics.cancelLifecyclePattern()
            }
        }
    }
}
