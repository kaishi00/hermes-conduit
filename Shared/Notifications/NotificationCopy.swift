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
    /// notification Hermes wrote shows its `headline` as the title. A
    /// private Pulse push (`private`) answers with a generic line, not the
    /// host's own words.
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
        var title = labelTitle(label, content: content)
        if title == nil, label.hasPrefix("pulse.") {
            // Main's label list doesn't know pulse labels; pulse's table
            // does (the brief's count and friends).
            title = pulseTitle(for: label, count: content["count"] as? Int)
        }
        let finalTitle = title ?? hostTitle
        let subtitle = profileLine(content, title: finalTitle)
        if label == "call.requested", let call = content["call"] as? [String: Any], let line = callLine(call) {
            return (finalTitle, subtitle, line)
        }
        if label.hasPrefix("pulse."), content["private"] as? Bool == true {
            // A private Pulse push (a birthday, a gift, health or money;
            // notifier 0.104.0): the host sent only this line, in English.
            return (finalTitle, subtitle, AppLocalization.string("Pulse has something for you."))
        }
        return (finalTitle, subtitle, hostBody)
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

    /// Which profile the push came from (#1415): its bot's name
    /// (`profile_name`), else its id, left out for an unnamed default
    /// profile and when the title already ends with it (a Bot Chat's).
    static func profileLine(_ content: [String: Any], title: String?) -> String? {
        // Routing reads a profile id trimmed and lowercased, so "Default" is the default too.
        let profile = nonEmpty(content["profile"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = nonEmpty(content["profile_name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? profile.flatMap({ $0.lowercased() == "default" ? nil : $0 }) else { return nil }
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

    /// What Pulse brings (`pulse.<kind>`), titled by itself: its chat is
    /// hidden. A report says how many things it noticed (`count`).
    private static func pulseTitle(for label: String, count: Int?) -> String? {
        switch label {
        case "pulse.noticed":
            guard let count, count > 1 else { return AppLocalization.string("Pulse noticed something") }
            return AppLocalization.string("Pulse noticed \(count) things")
        case "pulse.brief": return AppLocalization.string("Your morning brief")
        case "pulse.followup": return AppLocalization.string("Pulse · Follow-up")
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
