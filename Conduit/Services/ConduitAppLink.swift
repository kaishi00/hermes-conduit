//
//  ConduitAppLink.swift
//  Conduit
//
//  Links Conduit writes into saved text that open inside the app, such as
//  the link to a background job a voice call started. They are handled by
//  the root view's `openURL` action. A model's reply could write one too; a
//  tap on it only opens a chat on the profile in use, a bot's chat or a
//  Settings page, as the sidebar would.
//
//  The `conduit` scheme is also registered, so another app (a notification
//  from ntfy, a Shortcut) can open a chat with `conduit://session/<id>`.
//  From outside the app only session links are honoured: opening a chat is
//  all they do, the same as tapping its row, and a bot link is not needed
//  there.
//
//  `?profile=<name>` puts the chat on a named Hermes profile; Conduit
//  switches to it first, as a notification for that chat does. Without it
//  the chat is on the profile in use.
//
//  `?dashboard=<uuid>` names the saved dashboard the chat ran on (a Live
//  Activity's card stays up after a dashboard switch): the chat opens
//  there, switching to that dashboard first, as a notification for it does.
//
//  `conduit://settings/calls` opens Settings at Calls from Hermes: Hermes
//  links it when the user asks for a call while calls are off.
//  `conduit://settings/voice` opens Voice, where the user lets Hermes
//  change settings. `conduit://settings/plugin` opens Conduit plugin and
//  `conduit://settings/location` opens Location sharing. Only inside the
//  app, like a bot link.
//
//  `conduit://connect?url=…` is a dashboard sign-in code, read by
//  DashboardConnectLink before these, inside the app and from outside.
//

import Foundation

enum ConduitAppLink: Equatable {
    /// A chat (Hermes session) on `profile`, or on the profile the link
    /// was read in when it names none. `dashboard` names the saved
    /// dashboard the chat ran on, so a link written on one opens it there
    /// instead of against the dashboard in use when it is tapped.
    case session(id: String, profile: String? = nil, dashboard: String? = nil)
    /// A bot's Bot Chat, by the bot's profile name: a bot has one chat, and
    /// it opens through the bot's profile.
    case bot(profile: String)
    /// A Settings page.
    case settings(SettingsLink)

    enum SettingsLink: String, Equatable {
        /// Calls from Hermes.
        case calls
        /// Voice, where "Let Hermes change settings" lives.
        case voice
        /// The Conduit plugin on the dashboard's host.
        case plugin
        /// Health, where sharing Apple Health data is turned on.
        case health
        /// Location, where sharing the user's location with Hermes is set up.
        case location
        /// Calendar & phone: calendar, reminders, Focus and phone status.
        case phone
    }

    static let scheme = "conduit"
    private static let sessionRoot = URL(string: "conduit://session")!

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        switch components.host?.lowercased() {
        case "session": self = .session(id: id, profile: Self.profile(in: components), dashboard: Self.dashboard(in: components))
        case "bot": self = .bot(profile: id)
        case "settings":
            guard let page = SettingsLink(rawValue: id.lowercased()) else { return nil }
            self = .settings(page)
        default: return nil
        }
    }

    /// A link another app opened Conduit with: only a chat link, and only
    /// one whose id, profile and dashboard are plain tokens.
    init?(externalURL url: URL) {
        guard let link = ConduitAppLink(url: url), case .session(let id, let profile, let dashboard) = link,
              Self.isPlainToken(id), profile.map(Self.isPlainToken) ?? true,
              dashboard.map(Self.isPlainToken) ?? true else { return nil }
        self = link
    }

    /// The link's first `profile` query item; nil when it has none or a
    /// blank one.
    private static func profile(in components: URLComponents) -> String? {
        let value = components.queryItems?.first { $0.name == "profile" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// The link's first `dashboard` query item; nil when it has none or a
    /// blank one.
    private static func dashboard(in components: URLComponents) -> String? {
        let value = components.queryItems?.first { $0.name == "dashboard" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func isPlainToken(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return scalars.count <= maxExternalTokenLength && scalars.allSatisfy(externalTokenCharacters.contains)
    }

    private static let maxExternalTokenLength = 128
    private static let externalTokenCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:")

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .session(let id, let profile, let dashboard):
            components.host = "session"
            components.path = "/" + id
            let items = [
                profile.map { URLQueryItem(name: "profile", value: $0) },
                dashboard.map { URLQueryItem(name: "dashboard", value: $0) },
            ].compactMap { $0 }
            if !items.isEmpty { components.queryItems = items }
        case .bot(let profile):
            components.host = "bot"
            components.path = "/" + profile
        case .settings(let page):
            components.host = "settings"
            components.path = "/" + page.rawValue
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
