//
//  ChatVoiceButtonAction.swift
//  Conduit
//
//  What the big round button beside a chat's composer does: start a live
//  call (as it always has), record a voice message, or dictate into the
//  draft. One app-wide choice (Settings > Appearance), which a profile can
//  override (Settings > Voice). A live call stays one tap away in the
//  chat's top bar and in the button's touch-and-hold menu.
//

import Foundation

enum ChatVoiceButtonAction: String, CaseIterable, Equatable {
    case liveCall = "live_call"
    case voiceMessage = "voice_message"
    case dictation

    /// The app-wide choice, in UserDefaults (synced as
    /// `app.chat_voice_button`).
    static let key = "conduit.v2.chatVoiceButton"
    static let defaultValue = ChatVoiceButtonAction.liveCall

    /// The choices Settings offers.
    static var offered: [ChatVoiceButtonAction] {
        allCases.filter(\.isAvailable)
    }

    /// Whether this build can do it. Every choice can today; one added
    /// later reads as unknown to an older build instead.
    var isAvailable: Bool { true }

    /// The profile's override when it has one, else the app's choice. An
    /// unknown or unavailable value (written by a newer Conduit) reads as
    /// the next one down, then the default.
    static func resolved(profile: String?, app: String?) -> ChatVoiceButtonAction {
        if let profile, let action = ChatVoiceButtonAction(rawValue: profile), action.isAvailable {
            return action
        }
        if let app, let action = ChatVoiceButtonAction(rawValue: app), action.isAvailable {
            return action
        }
        return defaultValue
    }

    /// A stored profile choice as Settings offers it: nil for none, or
    /// for one this build can't do.
    static func offeredChoice(_ raw: String?) -> ChatVoiceButtonAction? {
        guard let raw, let action = ChatVoiceButtonAction(rawValue: raw), action.isAvailable else { return nil }
        return action
    }

    var title: String {
        switch self {
        case .liveCall: return AppLocalization.string("Live call")
        case .voiceMessage: return AppLocalization.string("Voice message")
        case .dictation: return AppLocalization.string("Dictation")
        }
    }

    var symbol: String {
        switch self {
        case .liveCall: return "waveform"
        case .voiceMessage: return "mic.fill"
        case .dictation: return "character.cursor.ibeam"
        }
    }
}

/// A request for the open chat's composer to start dictating.
struct ComposerDictationRequest: Equatable {
    let id = UUID()
    let sessionID: String?
}

extension AppState {
    func requestComposerDictation() {
        composerDictationRequest = ComposerDictationRequest(sessionID: activeSessionId)
    }

    /// The composer took the request: it started, or it belongs to another
    /// chat and dropped it.
    func consumeComposerDictationRequest(_ id: UUID) {
        guard composerDictationRequest?.id == id else { return }
        composerDictationRequest = nil
    }
}
