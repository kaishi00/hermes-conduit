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

/// The shortcut's Chat option. Unset, the recent-chat rule decides.
@available(iOS 16.0, *)
enum ScreenQuestionChatAppEnum: String, AppEnum {
    case recent
    case new

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat")
    static var caseDisplayRepresentations: [ScreenQuestionChatAppEnum: DisplayRepresentation] = [
        .recent: "Recent Chat",
        .new: "New Chat"
    ]
}

/// When the action last ran, for the setup screen's "Last used". Conduit
/// can't see which shortcuts are installed; a run proves the shortcut ran.
enum ScreenQuestionUsage {
    static let lastUsedKey = "conduit.screenQuestion.lastUsedAt"

    static func recordUse(at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastUsedKey)
    }

    static func lastUsed(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastUsedKey) as? Date
    }
}

/// Where "Add the shortcut" goes. The app never names the iCloud link
/// itself: a small JSON on Conduit's own site does, so a new version of
/// the shortcut needs no app update. The page beside it explains the
/// shortcut and redirects to the same link.
enum ScreenQuestionShortcutLink {
    static let configURL = URL(string: "https://kaishi00.github.io/hermes-conduit-notifier/shortcuts/ask-hermes-about-screen.json")!
    static let pageURL = URL(string: "https://kaishi00.github.io/hermes-conduit-notifier/shortcuts/ask-hermes-about-screen/")!

    typealias Fetch = (URL) async throws -> Data

    /// The shared shortcut link the JSON names, only if it is an iCloud
    /// Shortcuts link: nothing else is opened from it.
    static func shortcutURL(fromConfig data: Data) -> URL? {
        struct Config: Decodable { let url: String? }
        guard let raw = (try? JSONDecoder().decode(Config.self, from: data))?.url,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https",
              url.host?.lowercased() == "www.icloud.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil
        else { return nil }
        let path = url.path.split(separator: "/", omittingEmptySubsequences: true)
        // The id is letters, digits, "-" or "_": no "..", no escapes.
        guard path.count == 2, path[0] == "shortcuts",
              path[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return url
    }

    /// The iCloud link when the JSON has one, otherwise the page, which
    /// shows how to build the shortcut by hand.
    static func resolve(fetch: Fetch = fetchConfig) async -> URL {
        guard let data = try? await fetch(configURL), let url = shortcutURL(fromConfig: data) else {
            return pageURL
        }
        return url
    }

    static func fetchConfig(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
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

    @Parameter(title: "Chat")
    var chat: ScreenQuestionChatAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Hermes about \(\.$screenshot)") {
            \.$question
            \.$startWith
            \.$profile
            \.$chat
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
            enqueuedAt: Date(),
            startsNewChat: chat == .new
        )
        let pending = PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(request, profile: profile?.id)
        await MainActor.run {
            PendingVoiceIntentStore.shared.enqueue(pending)
        }
        return .result()
    }
}
