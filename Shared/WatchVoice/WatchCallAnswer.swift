//
//  WatchCallAnswer.swift
//  Conduit and the Conduit Watch app
//
//  A call from Hermes about a question or an approval, answered on the
//  Apple Watch (designs/hermes-call-clarify.md). The iPhone briefs the
//  call with what Hermes waits on, read from the plugin's copy
//  (GET /calls/waiting), and asks for `answer_call` on the call's grant,
//  bound to the call's chat. The model's answer_question and
//  answer_approval (GPT-Live's "Answer:", "Approve:" and "Deny:") then go
//  to the host through the push relay, wrist up or down, and the plugin
//  passes them to Hermes (plugin 0.70, capability hermes-call-answers).
//  Written for the model, not shown, so not localized.
//

import Foundation

enum WatchCallAnswer {
    /// The grant tool, and the plugin capability that serves it.
    static let tool = "answer_call"
    static let capability = "hermes-call-answers"
    /// HermesCallWaiting.asksFirstLead: an answer that asks Hermes to say
    /// more before the user chooses.
    static let asksFirstLead = "Before I choose:"

    /// Whether the model's `name` call answers the call from Hermes rather
    /// than a background job: a question always (the Watch's jobs take
    /// none), an approval only while no job's approval waits on the Watch.
    static func answersCall(_ name: String, jobApprovalsWaiting: Bool) -> Bool {
        name == "answer_question" || (name == "answer_approval" && !jobApprovalsWaiting)
    }

    /// What the host's answer_call takes for the model's call.
    static func arguments(name: String, arguments: [String: String]) -> [String: Any]? {
        if name == "answer_question" {
            let answer = arguments["answer"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return answer.isEmpty ? nil : ["answer": answer]
        }
        let choice = arguments["choice"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard choice == "once" || choice == "deny" else { return nil }
        return ["choice": choice]
    }

    /// The model's call without what it needs.
    static func missingArgument(name: String) -> [String: String] {
        ["error": name == "answer_question" ? "answer is required: the user's answer, or the number of their choice" : "choice must be once or deny"]
    }

    /// A GPT-Live delegation that answers the call: "Answer: 2",
    /// "Approve: …" or "Deny: …" (GPTLiveDelegationBridge's markers), as
    /// answer_call's arguments. A bare "Answer:" takes `userWords`, the
    /// user's own words since the last delegation, as the phone's does. A
    /// deny keeps what follows the marker as its reason, so "Deny: Before I
    /// choose: …" asks Hermes to explain. `approves`: false where the
    /// model may not answer an approval (GPT-Live on the Watch: the user taps).
    static func delegatedArguments(_ text: String, userWords: String, approves: Bool) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func rest(after marker: String) -> String? {
            guard trimmed.lowercased().hasPrefix(marker.lowercased()) else { return nil }
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let answer = rest(after: "Answer:") {
            let words = answer.isEmpty ? userWords.trimmingCharacters(in: .whitespacesAndNewlines) : answer
            return words.isEmpty ? nil : ["answer": words]
        }
        if rest(after: "Approve:") != nil { return approves ? ["choice": "once"] : nil }
        if let reason = rest(after: "Deny:") {
            guard approves else { return nil }
            return reason.lowercased().hasPrefix(asksFirstLead.lowercased()) ? ["choice": "deny", "reason": reason] : ["choice": "deny"]
        }
        return nil
    }

    /// The model's answer for the host's response.
    static func result(body: [String: Any]) -> [String: String] {
        guard body["ok"] as? Bool == true else {
            let detail = (body["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ["error": detail ?? "The answer didn't reach Hermes. Tell the user to answer in Conduit on their iPhone."]
        }
        let status = body["status"] as? String ?? ""
        let message = body["message"] as? String
        switch status {
        case "answered":
            if let choice = body["choice"] as? String {
                let said = choice == "once"
                    ? "Approved once: Hermes runs it now."
                    : "Denied: Hermes won't run it, and hears why if the user said."
                return ["status": choice == "once" ? "approved" : "denied", "message": said + " Tell the user in a few words."]
            }
            guard let answer = body["answer"] as? String else {
                return ["status": "answered", "message": message ?? "That's answered already."]
            }
            var result = ["status": "answered", "choice": answer]
            if let next = body["next"] as? [String: Any], let question = questionText(next) {
                result["message"] = "Hermes has the answer: \(answer). Next, read this question out with its numbered choices and take the user's answer the same way:\n<question>\n\(question)\n</question>"
            } else {
                result["message"] = "Hermes has the answer: \(answer). Say it back to the user in a few words; Hermes carries on with it."
            }
            return result
        case "refused":
            return ["error": message ?? "That can't be answered on the Watch. The user can answer it in Conduit on their iPhone."]
        default:
            return ["status": "not_pending", "message": message ?? "Hermes isn't waiting on the user any more."]
        }
    }

    /// The reply to a GPT-Live delegation: the result's message, or why it
    /// didn't go.
    static func delegatedReply(body: [String: Any]) -> String {
        let result = result(body: body)
        return result["message"] ?? result["error"] ?? "Hermes isn't waiting on the user any more."
    }

    /// One question of the host's copy as the call's briefing writes it
    /// (HermesCallWaiting.block), fenced as data.
    static func questionText(_ question: [String: Any]) -> String? {
        guard let text = question["question"] as? String, !text.isEmpty else { return nil }
        let choices = (question["choices"] as? [String]) ?? []
        var body = "Question"
        if !choices.isEmpty {
            body += question["multi_select"] as? Bool == true ? " (they may pick several)" : " (they pick one)"
        }
        body += ": \(text)"
        for (number, choice) in choices.enumerated() {
            body += "\n\(number + 1). \(choice)"
        }
        if choices.isEmpty { body += "\n(No choices: they answer in their own words.)" }
        return body.replacingOccurrences(of: "</question>", with: "</ question>", options: .caseInsensitive)
    }
}
