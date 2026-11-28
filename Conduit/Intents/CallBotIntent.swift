//
//  CallBotIntent.swift
//  Conduit
//
//  "Hey Siri, call <bot> in Conduit" (issue 3421): a phone call to a bot,
//  through CallKit, so it starts with the iPhone locked and runs like a
//  call from Hermes does: the call screen, the Dynamic Island, hang up
//  from the lock screen. It runs in the background: nothing opens, the
//  call connects to Hermes and a fresh voice conversation with the bot
//  starts, on the speaker unless headphones or a car are connected. The
//  call goes in the Phone app's Recents, where a tap calls the bot back
//  (`HermesNativeCalls.callBack`).
//
//  Saved shortcuts bind to this type's name: never rename it.
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct CallBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Call a Bot"
    static let description = IntentDescription("Call a bot like a phone call, with your iPhone locked too.")

    /// iOS 17–25 declaration; see `StartVoiceConversationIntent`. Must stay
    /// a boolean literal for the App Intents metadata processor.
    @available(iOS, deprecated: 26.0, message: "Use supportedModes on iOS 26+; retained for iOS 17–25.")
    static let openAppWhenRun: Bool = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .background
    }

    /// The dashboard in use's bots: the call connects to it.
    @Parameter(title: "Profile", requestValueDialog: "Which bot should Conduit call?", optionsProvider: ConduitLocalProfileOptions())
    var profile: ConduitProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Call \(\.$profile)")
    }

    init() {}

    init(profile: ConduitProfileEntity) { self.profile = profile }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Siri's list holds the other combined dashboards' bots too.
        guard let id = try SendToHermesIntent.profileOnScreen(profile.id).profile else { throw ShortcutSendError.callNotStarted }
        switch await HermesNativeCalls.shared.startCall(profile: id) {
        case .started: return .result()
        case .unavailable: throw ShortcutSendError.callsUnavailable
        case .busy: throw ShortcutSendError.callAlreadyOn
        case .failed: throw ShortcutSendError.callNotStarted
        }
    }
}

extension ShortcutSendError {
    /// CallKit isn't offered here (a storefront that doesn't allow it).
    static var callsUnavailable: ShortcutSendError {
        ShortcutSendError(message: AppLocalization.string("Conduit can't make phone calls here. Say \"Talk to Conduit\" to talk to a bot instead.", table: .phone))
    }

    static var callAlreadyOn: ShortcutSendError {
        ShortcutSendError(message: AppLocalization.string("There's already a call on. End it, then call again.", table: .phone))
    }

    static var callNotStarted: ShortcutSendError {
        ShortcutSendError(message: AppLocalization.string("Conduit couldn't start the call. Try again.", table: .phone))
    }
}
