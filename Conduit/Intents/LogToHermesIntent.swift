//
//  LogToHermesIntent.swift
//  Conduit
//
//  The "Log to Hermes" Shortcuts action: the end of an automation that
//  keeps what happened (a notification from an app the user picks, a
//  message, an email, a Wallet payment, an NFC tag, a sound the phone
//  hears) for Hermes to look up later, without a chat, a reply or a push.
//  Send to Hermes is the one that talks to Hermes; this one only keeps.
//
//  Shared shortcuts bind to this type's name and to its parameter names:
//  never rename them, and add new parameters only as optional.
//

import AppIntents
import Foundation

/// The kinds the plugin's inbox takes (ShortcutEvent.Kind).
enum ShortcutEventKindEntity: String, AppEnum {
    case notification, message, email, transaction, nfc, sound, other

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Event Kind"
    static let caseDisplayRepresentations: [ShortcutEventKindEntity: DisplayRepresentation] = [
        .notification: "Notification",
        .message: "Message",
        .email: "Email",
        .transaction: "Wallet Payment",
        .nfc: "NFC Tag",
        .sound: "Sound",
        .other: "Something Else",
    ]

    var kind: ShortcutEvent.Kind { ShortcutEvent.Kind(rawValue: rawValue) ?? .other }
}

/// Background-only: the event goes to the host without Conduit opening.
@available(iOS 16.0, *)
struct LogToHermesIntent: AppIntent {
    static let title: LocalizedStringResource = "Log to Hermes"
    static let description = IntentDescription(
        "Keep what an automation hands over, such as a notification, a message, an email or a payment, for Hermes to look up later. Hermes doesn't reply, and sign-in codes are never kept."
    )

    /// iOS 17–25 declaration; see `StartVoiceConversationIntent`. Must stay
    /// a boolean literal for the App Intents metadata processor.
    @available(iOS, deprecated: 26.0, message: "Use supportedModes on iOS 26+; retained for iOS 17–25.")
    static let openAppWhenRun: Bool = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .background
    }

    @Parameter(title: "Kind", default: .other)
    var kind: ShortcutEventKindEntity

    @Parameter(
        title: "Details",
        requestValueDialog: "What should Hermes keep?",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var details: String?

    @Parameter(title: "From")
    var source: String?

    @Parameter(title: "Title or Subject")
    var subject: String?

    @Parameter(title: "Amount")
    var amount: String?

    @Parameter(title: "When")
    var happenedAt: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$details) to Hermes as \(\.$kind)") {
            \.$source
            \.$subject
            \.$amount
            \.$happenedAt
        }
    }

    init() {}

    /// iOS lets an action run in the background for about 30 seconds.
    static let runTime: TimeInterval = 25

    func perform() async throws -> some IntentResult {
        let event = ShortcutEvent(kind: kind.kind, at: happenedAt ?? Date(), source: source, title: subject,
                                  text: details, amount: amount)
        _ = try await Self.log(event, deadline: Date().addingTimeInterval(Self.runTime))
        return .result()
    }

    @MainActor
    private static func log(_ event: ShortcutEvent, deadline: Date) async throws -> ShortcutLogOutcome {
        try await AppStateRuntimeRegistry.shared.appState.logShortcutEvent(event, deadline: deadline)
    }
}
