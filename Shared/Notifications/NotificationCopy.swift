import Foundation

/// The words on a Conduit notification, in the App Language (#1144).
///
/// The phone writes the chrome and the host sends the content: the title
/// names what happened ("Approval needed"), from the event type or the
/// host's `title_label`, and the host's own body, chat title
/// (`session_title`) and call details fill in the rest. Compiled into the
/// app and the Notification Service Extension, each with its own
/// `AppLocalization` over the app's String Catalog.
enum NotificationCopy {
    /// The private fallback for a notification that shows no content: Show
    /// previews off, or a push Conduit can't verify. Kept message for
    /// message with the relay's generic copy (`genericCopy` in
    /// hermes-conduit-notifier's relay/src/server.mjs), in the App Language:
    /// a change there belongs here too.
    static func generic(for type: String?) -> (title: String, body: String) {
        switch type {
        case "approval.needed":
            return (AppLocalization.string("Approval needed"), AppLocalization.string("Hermes is waiting for your approval."))
        case "input.needed":
            return (AppLocalization.string("Input needed"), AppLocalization.string("Hermes needs your response before it can continue."))
        case "turn.failed":
            return (AppLocalization.string("Turn failed"), AppLocalization.string("A Hermes turn could not be completed."))
        case "background_task.finished":
            return (AppLocalization.string("Background task finished"), AppLocalization.string("A delegated task has finished."))
        case "call.requested":
            return (AppLocalization.string("Hermes wants to talk"), AppLocalization.string("Tap to talk to Hermes."))
        case "phone.changes":
            return (AppLocalization.string("Hermes has a change for you"), AppLocalization.string("Tap to review it in Conduit."))
        default:
            return (AppLocalization.string("Response ready"), AppLocalization.string("Hermes has finished responding."))
        }
    }

    /// What a verified push shows with Show in notifications on Full
    /// previews: nil for a part the generic copy keeps.
    ///
    /// A push whose decrypted content names a `title_label` gets that
    /// label's title, joined with the chat's title when the host sent one;
    /// a call composes its line from the call's outcome. Any other title or
    /// body is the host's own text (an older plugin, a tool's prompt title).
    /// The subtitle names the profile (`profileLine`). A reply whose
    /// notification Hermes wrote shows its `headline` as the title.
    static func preview(_ content: [String: Any]) -> (title: String?, subtitle: String?, body: String?) {
        let hostTitle = nonEmpty(content["title"])
        let hostBody = nonEmpty(content["body"])
        guard let label = nonEmpty(content["title_label"]) else {
            return (hostTitle, profileLine(content, title: hostTitle), hostBody)
        }
        // A reply whose notification Hermes wrote (conduit_notify, #1415):
        // its heading is the title, and the subtitle says which chat.
        if label == "response.ready", let headline = nonEmpty(content["headline"]) {
            let chat = nonEmpty(content["session_title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = [chat, profileLine(content, title: chat)].compactMap { $0 }.joined(separator: " · ")
            return (headline, subtitle.isEmpty ? nil : subtitle, hostBody)
        }
        let title = labelTitle(label, content: content) ?? hostTitle
        let subtitle = profileLine(content, title: title)
        if label == "call.requested", let call = content["call"] as? [String: Any], let line = callLine(call) {
            return (title, subtitle, line)
        }
        return (title, subtitle, hostBody)
    }

    /// What a verified push shows with Chat names (#1415): the chat's title
    /// and the profile, and none of Hermes' words, so the body stays the
    /// generic one. Only a title Conduit writes from the `title_label`
    /// counts, never the host's own title, which may quote a tool's prompt.
    static func chatNames(_ content: [String: Any]) -> (title: String?, subtitle: String?) {
        let title = nonEmpty(content["title_label"]).flatMap { labelTitle($0, content: content) }
        return (title, profileLine(content, title: title))
    }

    /// The title a `title_label` gives, with the chat's title when the host
    /// sent one: nil for a label Conduit doesn't know.
    private static func labelTitle(_ label: String, content: [String: Any]) -> String? {
        let sessionTitle = nonEmpty(content["session_title"])
        if label == "response.ready" {
            return sessionTitle ?? AppLocalization.string("Response ready")
        } else if let heading = heading(for: label) {
            return sessionTitle.map { "\(heading) · \($0)" } ?? heading
        }
        return phoneTitle(for: label)
    }

    /// The push's content with the main bot named as Conduit names it
    /// (AppState.profileDisplayName, Eric 2026-10-28): the name given it in
    /// Conduit, `mainName`, wins over its bot's name, and an unnamed one is
    /// "Hermes", not "Default". The host titles a Bot Chat with the bot's
    /// name, so a chat title that is only that name is renamed with it.
    static let mainBotName = "Hermes"

    /// The name given the main profile on a push's dashboard: the one its
    /// key was made for, else the dashboard open in the app.
    static func mainName(dashboardID: String?, activeDashboardID: String?, names: [String: String]) -> String? {
        (dashboardID ?? activeDashboardID).flatMap(UUID.init(uuidString:)).flatMap { names[$0.uuidString] }
    }

    static func named(_ content: [String: Any], mainName: String?) -> [String: Any] {
        let profile = nonEmpty(content["profile"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard profile == "default" else { return content }
        // "Default" or "Hermes" names it no more than an unnamed main bot.
        let given = (nonEmpty(content["profile_name"])?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { ["default", mainBotName.lowercased()].contains($0.lowercased()) ? nil : $0 }
        let renamed = (mainName?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty || $0 == mainBotName ? nil : $0 }
        let name = renamed ?? given ?? mainBotName
        // An older plugin titles an unnamed main bot's chat "Default".
        let hostNames = given.map { [$0] } ?? ["Default", mainBotName]
        var content = content
        if renamed != nil || given != nil { content["profile_name"] = name } else { content.removeValue(forKey: "profile_name") }
        if let chat = nonEmpty(content["session_title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           hostNames.contains(where: { $0.caseInsensitiveCompare(chat) == .orderedSame }) {
            content["session_title"] = name
        }
        return content
    }

    /// Which profile the push came from (#1415): its bot's name
    /// (`profile_name`, unless it is only the id), else its id capitalized, left out for an unnamed default
    /// profile and when the title already ends with it (a Bot Chat's).
    static func profileLine(_ content: [String: Any], title: String?) -> String? {
        // Routing reads a profile id trimmed and lowercased, so "Default" is the default too.
        let profile = nonEmpty(content["profile"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name that is only the id names it no more than the id (BotProfile.displayLabel).
        let given = nonEmpty(content["profile_name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = given.flatMap({ $0.lowercased() == profile?.lowercased() ? nil : $0 })
            ?? profile.flatMap({ $0.lowercased() == "default" ? nil : String($0.prefix(1)).uppercased() + String($0.dropFirst()) })
        else { return nil }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           title == name.lowercased() || title.hasSuffix(" · \(name.lowercased())") { return nil }
        return name
    }

    private static func heading(for label: String) -> String? {
        switch label {
        case "approval.needed": return AppLocalization.string("Approval needed")
        case "input.needed": return AppLocalization.string("Input needed")
        case "turn.failed": return AppLocalization.string("Turn failed")
        case "background_task.finished": return AppLocalization.string("Task finished")
        case "call.requested": return AppLocalization.string("Hermes wants to talk")
        default: return nil
        }
    }

    /// A calendar, reminder or alarm change Hermes asks for
    /// (`phone.<kind>`) or makes on its own (`phone.auto.<kind>`).
    private static func phoneTitle(for label: String) -> String? {
        switch label {
        case "phone.add_event": return AppLocalization.string("Hermes wants to add an event")
        case "phone.update_event": return AppLocalization.string("Hermes has a calendar change")
        case "phone.delete_event": return AppLocalization.string("Hermes wants to remove an event")
        case "phone.add_reminder": return AppLocalization.string("Hermes wants to add a reminder")
        case "phone.update_reminder": return AppLocalization.string("Hermes wants to change a reminder")
        case "phone.complete_reminder": return AppLocalization.string("Hermes wants to complete a reminder")
        case "phone.delete_reminder": return AppLocalization.string("Hermes wants to remove a reminder")
        case "phone.set_alarm": return AppLocalization.string("Hermes wants to set an alarm")
        case "phone.set_timer": return AppLocalization.string("Hermes wants to start a timer")
        case "phone.cancel_alarm": return AppLocalization.string("Hermes wants to cancel an alarm")
        case "phone.auto.add_event": return AppLocalization.string("Hermes is adding an event")
        case "phone.auto.add_reminder": return AppLocalization.string("Hermes is adding a reminder")
        case "phone.auto.set_alarm": return AppLocalization.string("Hermes is setting an alarm")
        case "phone.auto.set_timer": return AppLocalization.string("Hermes is starting a timer")
        case "phone.change": return AppLocalization.string("Hermes has a change for you")
        default: return nil
        }
    }

    /// A call request's line, as the app's own call notification says it
    /// (HermesCallCopy.summary, which the extension can't link): what Hermes
    /// waits on, its reason, else how the job ended. Keep the two in step.
    static func callLine(_ call: [String: Any]) -> String? {
        let reason = nonEmpty(call["reason"])
        let job = nonEmpty(call["title"])
        let outcome: String
        switch call["kind"] as? String {
        case "approval": outcome = AppLocalization.string("Hermes needs your OK.")
        case "question": outcome = AppLocalization.string("Hermes has a question for you.")
        case let kind?:
            if call["origin"] as? String == "alert" {
                return AppLocalization.string("Hermes ran into a problem with your request.")
            }
            if let reason { return reason }
            switch (kind, job) {
            case ("done", let job?): return AppLocalization.string("“\(job)” finished.")
            case ("done", nil): return AppLocalization.string("Your job finished.")
            case ("failed", let job?): return AppLocalization.string("“\(job)” failed.")
            case ("failed", nil): return AppLocalization.string("Your job failed.")
            case ("stopped", let job?): return AppLocalization.string("“\(job)” stopped before finishing.")
            case ("stopped", nil): return AppLocalization.string("Your job stopped before finishing.")
            case (_, let job?): return AppLocalization.string("“\(job)” ended.")
            case (_, nil): return AppLocalization.string("Your job ended.")
            }
        case nil:
            return nil
        }
        return reason.map { outcome + " " + $0 } ?? outcome
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
