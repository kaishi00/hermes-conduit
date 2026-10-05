//
//  AskHermesAboutScreenIntent.swift
//  Conduit
//
//  The Shortcuts action behind "Ask Hermes About Screen": the user's
//  shortcut runs Take Screenshot and hands the image here. Conduit opens on
//  a chat with the screenshot waiting, so the next question carries it.
//
//  The shared shortcut binds to this type's name and to its parameter
//  names: never rename them, and add new parameters only as optional.
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
enum ScreenQuestionStartAppEnum: String, AppEnum {
    case voice
    case keyboard

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Start with")
    static var caseDisplayRepresentations: [ScreenQuestionStartAppEnum: DisplayRepresentation] = [
        .voice: "Voice",
        .keyboard: "Keyboard"
    ]

    var start: ScreenQuestionStart {
        switch self {
        case .voice: return .voice
        case .keyboard: return .keyboard
        }
    }
}

/// When the action last ran, for the setup screen's "Last used". Conduit
/// can't see which shortcuts are installed; a run proves the whole chain.
enum ScreenQuestionUsage {
    static let lastUsedKey = "conduit.screenQuestion.lastUsedAt"

    static func recordUse(at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastUsedKey)
    }

    static func lastUsed(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastUsedKey) as? Date
    }
}

struct ScreenQuestionStagingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Foreground-first, like `StartVoiceConversationIntent`: `perform()` only
/// stages the image and records a pending request. The root scene opens
/// the chat once Hermes is connected.
@available(iOS 16.0, *)
struct AskHermesAboutScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Hermes About Screen"
    static var description = IntentDescription(
        "Open Conduit with this screenshot attached to a chat, ready for your question."
    )

    /// iOS 17–25 declaration; see `StartVoiceConversationIntent`. Must stay
    /// a boolean literal for the App Intents metadata processor.
    @available(iOS, deprecated: 26.0, message: "Use supportedModes on iOS 26+; retained for iOS 17–25.")
    static var openAppWhenRun: Bool = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @Parameter(
        title: "Screenshot",
        supportedTypeIdentifiers: ["public.image"],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var screenshot: IntentFile

    @Parameter(title: "Question")
    var question: String?

    @Parameter(title: "Start with")
    var startWith: ScreenQuestionStartAppEnum?

    @Parameter(title: "Profile")
    var profile: ConduitProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Hermes about \(\.$screenshot)") {
            \.$question
            \.$startWith
            \.$profile
        }
    }

    init() {}

    func perform() async throws -> some IntentResult {
        let limit = UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey)
        let outcome = AttachmentStaging.stageScreenshot(
            data: screenshot.data,
            filename: screenshot.filename,
            limitMegabytes: AttachmentSizeLimit.clampedMegabytes(limit)
        )
        let attachment: Attachment
        switch outcome {
        case .staged(let staged):
            attachment = staged
        case .tooLarge(let name):
            throw ScreenQuestionStagingError(
                message: AttachmentSizeLimit.tooLargeMessage(names: [name], megabytes: AttachmentSizeLimit.clampedMegabytes(limit))
            )
        case .failed:
            throw ScreenQuestionStagingError(
                message: AppLocalization.string("Conduit couldn't read that image. Ask Hermes About Screen needs a screenshot or another image.")
            )
        }
        ScreenQuestionUsage.recordUse()
        let request = ScreenQuestionRequest(
            attachment: attachment,
            question: question,
            startWith: startWith?.start,
            enqueuedAt: Date()
        )
        let pending = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(request, profile: profile?.id)
        await MainActor.run {
            PendingVoiceIntentStore.shared.enqueue(pending)
        }
        return .result()
    }
}
