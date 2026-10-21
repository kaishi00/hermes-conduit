//
//  VoiceModeChoice.swift
//  Conduit
//
//  The profile's voice mode as Settings > Voice > Voice mode lists it. The
//  call screens offer the same list, so a call that won't connect (or one
//  that would be better in another mode) switches without leaving the call.
//

import Foundation

enum VoiceModeChoice: String, CaseIterable, Identifiable {
    case classic, gemini, gpt, grok, local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return AppLocalization.string("Classic")
        case .gemini: return AppLocalization.string("Gemini Live")
        case .gpt: return AppLocalization.string("GPT-Live")
        case .grok: return AppLocalization.string("Grok Live")
        case .local: return AppLocalization.string("Local")
        }
    }

    /// The live engine the mode runs on; nil for Classic.
    var engine: VoiceCallEngine? {
        switch self {
        case .classic: return nil
        case .gemini: return .geminiLive
        case .gpt: return .gptLive
        case .grok: return .grokLive
        case .local: return .localLive
        }
    }

    /// The mode a running call is in. Local Live outside agent mode is
    /// Classic's hands-free option, so Settings lists it as Classic.
    init(engine: VoiceCallEngine?, localAgent: Bool = true) {
        switch engine {
        case nil: self = .classic
        case .geminiLive: self = .gemini
        case .gptLive: self = .gpt
        case .grokLive: self = .grok
        case .localLive: self = localAgent ? .local : .classic
        }
    }
}

/// The call screens' mode menu: the mode the call is in, and what picking
/// another does.
struct VoiceModeSwitch {
    let current: VoiceModeChoice
    /// The call runs on another engine than `current` names (Local Live's
    /// hands-free option, listed as Classic), so picking `current` still
    /// moves it.
    var movesOnCurrent = false
    let select: (VoiceModeChoice) -> Void

    /// Whether picking `choice` moves the call.
    func moves(to choice: VoiceModeChoice) -> Bool {
        choice != current || movesOnCurrent
    }
}
