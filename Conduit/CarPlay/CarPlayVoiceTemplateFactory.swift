//
//  CarPlayVoiceTemplateFactory.swift
//  Conduit
//
//  Builds the single CPVoiceControlTemplate that presents the shared Voice
//  conversation on CarPlay. Exactly five states (the template's documented
//  maximum). Action buttons (iOS 26.4+) stay minimal: Listen at Ready/Error,
//  End while the conversation is active. Handlers arrive from the coordinator
//  and converge on the existing shared teardown/listen paths — CarPlay adds
//  no parallel Voice business logic.
//

import CarPlay
import UIKit

/// Handlers the template's buttons invoke. MainActor-facing; the coordinator
/// bridges them into the shared AppState/controller.
@MainActor
struct CarPlayVoiceActionHandlers {
    /// Start (or restart) a listening turn through the shared controller.
    var startListening: () -> Void
    /// End the conversation through the authoritative Close teardown.
    var endConversation: () -> Void
}

@MainActor
enum CarPlayVoiceTemplateFactory {
    static func makeVoiceControlState(
        for state: CarPlayVoiceState,
        handlers: CarPlayVoiceActionHandlers
    ) -> CPVoiceControlState {
        let voiceControlState = CPVoiceControlState(
            identifier: state.identifier,
            titleVariants: state.titleVariants,
            image: nil,
            repeats: false
        )
        if #available(iOS 26.4, *) {
            voiceControlState.actionButtons = actionButtons(for: state, handlers: handlers)
        }
        return voiceControlState
    }

    static func makeTemplate(
        handlers: CarPlayVoiceActionHandlers
    ) -> CPVoiceControlTemplate {
        let states = CarPlayVoiceState.allCases.map { makeVoiceControlState(for: $0, handlers: handlers) }
        return CPVoiceControlTemplate(voiceControlStates: states)
    }

    private static func actionButtons(
        for state: CarPlayVoiceState,
        handlers: CarPlayVoiceActionHandlers
    ) -> [CPButton] {
        switch state {
        case .ready, .error:
            return [makeButton(title: "Listen", symbol: "mic.fill") { _ in handlers.startListening() }]
        case .listening, .processing, .responding:
            return [makeButton(title: "End", symbol: "xmark.circle") { _ in handlers.endConversation() }]
        }
    }

    private static func makeButton(
        title: String,
        symbol: String,
        handler: @escaping (CPButton) -> Void
    ) -> CPButton {
        let button = CPButton(
            image: UIImage(systemName: symbol) ?? UIImage(),
            handler: handler
        )
        button.title = title
        return button
    }
}
