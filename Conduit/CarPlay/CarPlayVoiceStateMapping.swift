//
//  CarPlayVoiceStateMapping.swift
//  Conduit
//
//  Pure mapping from the shared VoiceConversationController's published state
//  (or a live mode's phase) to the at-most-five states the CarPlay
//  CPVoiceControlTemplate displays.
//  CarPlay is a state/control surface, never a mirrored chat window: no
//  transcript text, reasoning, or failure detail ever crosses this boundary —
//  the associated failure message of `.failed` is deliberately dropped here.
//  The one piece of user text is a chat's title in Ready, shortened, which
//  says where Listen talks.
//  The Error state instead names what to fix (`VoiceSetupIssue`), which the
//  coordinator works out from the app's own state.
//

enum CarPlayVoiceState: String, CaseIterable, Equatable {
    case ready
    case listening
    case processing
    case responding
    case error

    /// Stable identifier used with
    /// `CPVoiceControlTemplate.activateVoiceControlState(withIdentifier:)`.
    var identifier: String { rawValue }

    /// Driver-safe title variants. CarPlay picks the longest variant that
    /// fits; keep them short and free of user content.
    var titleVariants: [String] {
        switch self {
        case .ready: return [AppLocalization.string("Ready")]
        case .listening: return [AppLocalization.string("Listening…")]
        case .processing: return [AppLocalization.string("Thinking…")]
        case .responding: return [AppLocalization.string("Responding…")]
        case .error: return [
            AppLocalization.string("Something went wrong. See your iPhone."),
            AppLocalization.string("Something went wrong"),
        ]
        }
    }

    /// The titles for this state, with the Error state naming what to fix
    /// when the cause is known. A bare "Voice unavailable" read as CarPlay
    /// itself not working to a driver who had never turned Voice on.
    func titleVariants(errorIssue: VoiceSetupIssue?) -> [String] {
        guard self == .error, let errorIssue else { return titleVariants }
        return errorIssue.carPlayTitleVariants
    }

    /// The titles for this state on a template built for `controls`. Ready
    /// also names the chat Listen talks in, so the driver knows where the
    /// next words go; the plain title stays as the short variant.
    func titleVariants(controls: CarPlayVoiceControls) -> [String] {
        guard self == .ready, let chatTitle = controls.chatTitle else {
            return titleVariants(errorIssue: controls.errorIssue)
        }
        let shortened = Self.shortenedChatTitle(chatTitle)
        return [AppLocalization.string("Ready · \(shortened)")] + titleVariants
    }

    /// Chat titles are any length; Ready keeps them to a glance.
    static let maximumChatTitleLength = 28

    static func shortenedChatTitle(_ title: String) -> String {
        guard title.count > maximumChatTitleLength else { return title }
        let kept = title.prefix(maximumChatTitleLength - 1).trimmingCharacters(in: .whitespaces)
        return kept + "…"
    }

    /// Approximate mapping from the authoritative controller state. Both
    /// `.transcribing` and `.thinking` are "the assistant is working";
    /// `.muted` is a playback presentation detail and maps to responding.
    static func map(_ state: VoiceConversationState) -> CarPlayVoiceState {
        switch state {
        case .idle: return .ready
        case .listening: return .listening
        case .transcribing, .thinking: return .processing
        case .speaking, .muted: return .responding
        case .failed: return .error
        }
    }

    /// The same mapping for a Gemini Live conversation, when the profile
    /// uses Gemini Live instead of the classic Voice pipeline.
    static func map(geminiLive phase: GeminiLiveConversationController.Phase) -> CarPlayVoiceState {
        switch phase {
        case .idle: return .ready
        case .connecting, .reconnecting, .paused, .ending: return .processing
        case .listening: return .listening
        case .speaking: return .responding
        case .failed: return .error
        }
    }

    /// The same mapping for a GPT-Live call.
    static func map(gptLive phase: GPTLiveConversationController.Phase) -> CarPlayVoiceState {
        switch phase {
        case .idle: return .ready
        case .connecting, .paused, .ending: return .processing
        case .listening: return .listening
        case .speaking: return .responding
        case .failed: return .error
        }
    }
}

/// What the CarPlay Listen button does in a GPT-Live call. The call is full
/// duplex (GPT-Live's own turn detection handles barge-in and WebRTC cancels
/// the car speakers' echo), so there is nothing to interrupt: the driver
/// just talks.
///
/// The template shows Listen only at Ready and Error (idle and failed), so
/// from the car only `.start` is reached today; the other phases are mapped
/// so the table stays total if Listen ever appears mid-call.
enum CarPlayGPTLiveListenAction: Equatable {
    /// Nothing running (or it failed): start a call.
    case start
    /// Already in a call the driver can talk into, or connecting/ending.
    case nothing

    static func forPhase(_ phase: GPTLiveConversationController.Phase) -> CarPlayGPTLiveListenAction {
        switch phase {
        case .idle, .failed: return .start
        case .connecting, .listening, .speaking, .paused, .ending: return .nothing
        }
    }
}

/// What the CarPlay Listen button does in a Gemini Live conversation, which
/// listens continuously instead of turn by turn.
enum CarPlayGeminiLiveListenAction: Equatable {
    /// Nothing running (or it failed): start a conversation.
    case start
    /// Gemini is talking: stop it so the driver can speak (on the car's
    /// speakers the microphone is closed while Gemini talks).
    case interrupt
    /// Already listening or connecting: nothing to do.
    case nothing

    static func forPhase(_ phase: GeminiLiveConversationController.Phase) -> CarPlayGeminiLiveListenAction {
        switch phase {
        case .idle, .failed: return .start
        case .speaking: return .interrupt
        case .connecting, .reconnecting, .listening, .paused, .ending: return .nothing
        }
    }
}

/// Duplicate-suppression policy for CarPlay state activation. The template
/// rate-limits activation internally and ignores rapid changes, so callers
/// must never forward an unchanged state (`.muted` ↔ `.speaking` oscillation
/// maps to the same CarPlay state and collapses here).
enum CarPlayVoiceStateActivation {
    /// The state to activate, or nil when the transition is a duplicate of
    /// the last activated state and must not be forwarded.
    static func activationTarget(
        lastActivated: CarPlayVoiceState?,
        newState: CarPlayVoiceState
    ) -> CarPlayVoiceState? {
        guard newState != lastActivated else { return nil }
        return newState
    }
}
