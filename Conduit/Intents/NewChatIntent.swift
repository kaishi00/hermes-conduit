//
//  NewChatIntent.swift
//  Conduit
//
//  New Chat for Siri, Shortcuts and the Action Button (issue 2860): opens
//  Conduit on a fresh chat with the keyboard up, ready to type. It is a
//  widget's New Chat (the same launch, which switches profile, waits for
//  the connection and says when it can't), on the dashboard in use.
//
//  Saved shortcuts and the Action Button bind to this type's name: never
//  rename it.
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Open Conduit on a new chat, ready to type.")

    /// iOS 17–25 declaration; see `StartVoiceConversationIntent`. Must stay
    /// a boolean literal for the App Intents metadata processor.
    @available(iOS, deprecated: 26.0, message: "Use supportedModes on iOS 26+; retained for iOS 17–25.")
    static let openAppWhenRun: Bool = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    /// The profile to start it in; the one on screen when left empty.
    @Parameter(title: "Profile") var profile: ConduitProfileEntity?

    init() {}

    init(profile: ConduitProfileEntity?) { self.profile = profile }

    @MainActor
    func perform() async throws -> some IntentResult {
        // With no dashboard signed in, Conduit opens on its sign-in.
        AppStateRuntimeRegistry.shared.appState.startNewChatFromShortcut(profile: profile?.id)
        return .result()
    }
}
