//
//  CarPlayVoiceStateMapping.swift
//  Conduit
//
//  Pure mapping from the shared VoiceConversationController's published state
//  to the at-most-five states the CarPlay CPVoiceControlTemplate displays.
//  CarPlay is a state/control surface, never a mirrored chat window: no
//  transcript text, reasoning, or failure detail ever crosses this boundary —
//  the associated failure message of `.failed` is deliberately dropped here.
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
        case .ready: return ["Ready"]
        case .listening: return ["Listening…"]
        case .processing: return ["Thinking…"]
        case .responding: return ["Responding…"]
        case .error: return ["Voice unavailable"]
        }
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
