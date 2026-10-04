//
//  ConduitAppLink.swift
//  Conduit
//
//  Links Conduit writes into saved text that open inside the app, such as
//  the link to a background job a voice call started. They are handled by
//  the root view's `openURL` action, so no URL scheme is registered and
//  another app can't open them. A model's reply could write one too; a tap
//  on it only opens a chat on the profile in use or a bot's chat, as the
//  sidebar would.
//

import Foundation

enum ConduitAppLink: Equatable {
    /// A chat (Hermes session) on the profile the link was read in.
    case session(id: String)
    /// A bot's Bot Chat, by the bot's profile name: a bot has one chat, and
    /// it opens through the bot's profile.
    case bot(profile: String)

    static let scheme = "conduit"
    private static let sessionRoot = URL(string: "conduit://session")!

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        switch components.host?.lowercased() {
        case "session": self = .session(id: id)
        case "bot": self = .bot(profile: id)
        default: return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .session(let id):
            components.host = "session"
            components.path = "/" + id
        case .bot(let profile):
            components.host = "bot"
            components.path = "/" + profile
        }
        // A session id or profile name is a plain token; a URL that can't
        // be built is a programming error, never user input.
        return components.url ?? Self.sessionRoot
    }

    /// A Markdown link to this target. Brackets in the label are escaped
    /// so the link can't break.
    func markdown(label: String) -> String {
        let escaped = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url.absoluteString))"
    }

    /// `text` without Conduit's in-app links, for prompts: a voice model or
    /// a title generator has no use for them.
    static func removingLinks(from text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"[ \t]*\[(?:\\.|[^\]\\\n])*\]\(conduit://[^)\s]*\)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return stripped == text ? text : stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
