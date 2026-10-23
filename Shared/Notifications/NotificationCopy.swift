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

    /// What a verified push shows with Show previews on: nil for a part the
    /// generic copy keeps.
    ///
    /// A push whose decrypted content names a `title_label` gets that
    /// label's title, joined with the chat's title when the host sent one;
    /// a call composes its line from the call's outcome. Any other title or
    /// body is the host's own text (an older plugin, a tool's prompt title).
    static func preview(_ content: [String: Any]) -> (title: String?, body: String?) {
        let hostTitle = nonEmpty(content["title"])
        let hostBody = nonEmpty(content["body"])
        guard let label = nonEmpty(content["title_label"]) else { return (hostTitle, hostBody) }
        let sessionTitle = nonEmpty(content["session_title"])
        let title: String?
        if label == "response.ready" {
            title = sessionTitle ?? AppLocalization.string("Response ready")
        } else if let heading = heading(for: label) {
            title = sessionTitle.map { "\(heading) · \($0)" } ?? heading
        } else if let phoneTitle = phoneTitle(for: label) {
            title = phoneTitle
        } else if let pulse = pulseTitle(for: label, count: content["count"] as? Int) {
            title = pulse
        } else {
            title = hostTitle
        }
        if label == "call.requested", let call = content["call"] as? [String: Any], let line = callLine(call) {
            return (title, line)
        }
        return (title, hostBody)
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
