//
//  CarPlayVoiceTemplateFactory.swift
//  Conduit
//
//  Builds the single CPVoiceControlTemplate that presents the shared Voice
//  conversation on CarPlay. Exactly five states (the template's documented
//  maximum), each with its state icon. Action buttons (iOS 26.4+, at most
//  two): Listen (plus New Chat in the classic mode) at Ready/Error, Mute or
//  Unmute next to End while the conversation is active. Handlers arrive from
//  the coordinator and converge on the existing shared teardown/listen/mute
//  paths — CarPlay adds no parallel Voice business logic.
//

import CarPlay
import UIKit

/// Handlers the template's buttons invoke. MainActor-facing; the coordinator
/// bridges them into the shared AppState/controller.
@MainActor
struct CarPlayVoiceActionHandlers {
    /// Start (or restart) a listening turn through the shared controller.
    var startListening: () -> Void
    /// Start listening in a new chat instead of the current one.
    var startNewChat: () -> Void
    /// Mute or unmute the microphone of the running conversation.
    var toggleMicrophone: () -> Void
    /// End the conversation through the authoritative Close teardown.
    var endConversation: () -> Void

    init(
        startListening: @escaping () -> Void,
        startNewChat: @escaping () -> Void = {},
        toggleMicrophone: @escaping () -> Void = {},
        endConversation: @escaping () -> Void
    ) {
        self.startListening = startListening
        self.startNewChat = startNewChat
        self.toggleMicrophone = toggleMicrophone
        self.endConversation = endConversation
    }
}

/// What the buttons depend on besides the state: the Voice mode and the
/// microphone. The template's states are fixed at creation, so their buttons
/// are replaced in place when this changes.
struct CarPlayVoiceControls: Equatable {
    /// The classic mode's Listen continues the current chat, so a new chat
    /// is its own button. A live call always starts fresh.
    var offersNewChat: Bool
    var isMicrophoneMuted: Bool

    static let initial = CarPlayVoiceControls(offersNewChat: true, isMicrophoneMuted: false)
}

enum CarPlayVoiceButton: Equatable {
    case listen
    case newChat
    case mute
    case unmute
    case end

    /// The buttons for one state, in display order.
    static func buttons(for state: CarPlayVoiceState, controls: CarPlayVoiceControls) -> [CarPlayVoiceButton] {
        switch state {
        case .ready, .error:
            return controls.offersNewChat ? [.listen, .newChat] : [.listen]
        case .listening, .processing, .responding:
            return [controls.isMicrophoneMuted ? .unmute : .mute, .end]
        }
    }

    var title: String {
        switch self {
        case .listen: return AppLocalization.string("Listen")
        case .newChat: return AppLocalization.string("New Chat")
        case .mute: return AppLocalization.string("Mute")
        case .unmute: return AppLocalization.string("Unmute")
        case .end: return AppLocalization.string("End")
        }
    }

    var symbol: String {
        switch self {
        case .listen: return "mic.fill"
        case .newChat: return "square.and.pencil"
        case .mute: return "mic.slash.fill"
        case .unmute: return "mic.fill"
        case .end: return "xmark.circle"
        }
    }
}

@MainActor
enum CarPlayVoiceTemplateFactory {
    static func makeVoiceControlState(
        for state: CarPlayVoiceState,
        controls: CarPlayVoiceControls = .initial,
        handlers: CarPlayVoiceActionHandlers
    ) -> CPVoiceControlState {
        let voiceControlState = CPVoiceControlState(
            identifier: state.identifier,
            titleVariants: state.titleVariants,
            image: CarPlayVoiceArtwork.image(for: state),
            repeats: CarPlayVoiceArtwork.isAnimated(state)
        )
        if #available(iOS 26.4, *) {
            voiceControlState.actionButtons = actionButtons(for: state, controls: controls, handlers: handlers)
        }
        return voiceControlState
    }

    static func makeTemplate(
        controls: CarPlayVoiceControls = .initial,
        handlers: CarPlayVoiceActionHandlers
    ) -> CPVoiceControlTemplate {
        let states = CarPlayVoiceState.allCases.map {
            makeVoiceControlState(for: $0, controls: controls, handlers: handlers)
        }
        return CPVoiceControlTemplate(voiceControlStates: states)
    }

    /// Replaces every state's buttons for new controls (a mode switch, or the
    /// microphone muted from the car or the phone).
    static func apply(
        _ controls: CarPlayVoiceControls,
        to template: CPVoiceControlTemplate,
        handlers: CarPlayVoiceActionHandlers
    ) {
        guard #available(iOS 26.4, *) else { return }
        for voiceControlState in template.voiceControlStates {
            guard let state = CarPlayVoiceState(rawValue: voiceControlState.identifier) else { continue }
            voiceControlState.actionButtons = actionButtons(for: state, controls: controls, handlers: handlers)
        }
    }

    private static func actionButtons(
        for state: CarPlayVoiceState,
        controls: CarPlayVoiceControls,
        handlers: CarPlayVoiceActionHandlers
    ) -> [CPButton] {
        CarPlayVoiceButton.buttons(for: state, controls: controls).map { button in
            makeButton(title: button.title, symbol: button.symbol) { _ in
                switch button {
                case .listen: handlers.startListening()
                case .newChat: handlers.startNewChat()
                case .mute, .unmute: handlers.toggleMicrophone()
                case .end: handlers.endConversation()
                }
            }
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
