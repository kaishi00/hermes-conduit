//
//  ClarifyHistoryRecord.swift
//  Conduit
//
//  A finished clarify call read back from persisted history (#394).
//

import Foundation

extension ClarifyActivity {
    /// The read-only card for a finished `clarify` tool row from persisted
    /// history. The live card is its own `.clarify` row, and a transcript
    /// reload only brings pending cards back, so without this an answered
    /// question came back as the bare tool call: its Input JSON and a green
    /// check (#394).
    ///
    /// Reads every result shape Hermes has written: the current
    /// `{"responses": [{question, choices_offered, status, user_response}],
    /// "outcome"}`, the older batch `{"responses": [...]}` (also what the
    /// notifier returns for a push answer) and the single-question
    /// `{question, choices_offered, user_response}`. Nil for anything else
    /// (a running call, an error, a compact resume row without its result),
    /// which keeps the ordinary tool card.
    static func historyRecord(for tool: ToolActivity, rowID: String) -> ClarifyActivity? {
        guard tool.name.lowercased() == "clarify",
              tool.status == .complete,
              let result = jsonObject(tool.output),
              result["error"] == nil else { return nil }
        let rows: [[String: Any]]
        if let responses = result["responses"] as? [[String: Any]] {
            rows = responses
        } else if result["question"] != nil {
            rows = [result]
        } else {
            return nil
        }
        // The call's arguments fill in what an older result row leaves out
        // (multi-select, choices). A compact resume row carries only a text
        // preview here, which simply contributes nothing.
        let asked = askedQuestions(in: jsonObject(tool.input))
        var questions: [ClarifyQuestion] = []
        for (index, row) in rows.enumerated() {
            let call = index < asked.count ? asked[index] : [:]
            guard let text = nonEmptyText(row["question"]) ?? nonEmptyText(call["question"]) else { continue }
            let offered = textList(row["choices_offered"]) ?? textList(call["choices"]) ?? []
            var question = ClarifyQuestion(
                id: "q\(index)",
                question: text,
                choices: offered.map { ClarifyChoice(label: $0, value: $0) },
                multiSelect: (call["multi_select"] as? Bool) == true,
                status: .expired,
                isSyntheticID: true
            )
            if (row["status"] as? String) == "skipped" {
                question.status = .answered
                question.answer = AppLocalization.string("Skipped")
            } else if let values = textList(row["user_response"]), !values.isEmpty {
                question.status = .answered
                question.multiSelect = true
                question.answer = ClarifyQuestion.multiSelectAnswer(values)
            } else if let answer = nonEmptyText(row["user_response"]) {
                question.status = .answered
                question.answer = answer
            }
            questions.append(question)
        }
        guard !questions.isEmpty else { return nil }
        var record = ClarifyActivity(requestId: "history-\(tool.id ?? rowID)", questions: questions)
        if questions.contains(where: { $0.status == .expired }) {
            // The same notice the live card shows once Hermes stops waiting.
            let timedOut = (result["outcome"] as? String) == "timed_out"
            switch (timedOut, questions.count > 1) {
            case (true, true):
                record.error = AppLocalization.string("These questions are no longer active — Hermes timed them out and continued.")
            case (true, false):
                record.error = AppLocalization.string("This question is no longer active — Hermes timed it out and continued.")
            case (false, true):
                record.error = AppLocalization.string("These questions are no longer active.")
            case (false, false):
                record.error = AppLocalization.string("This question is no longer active.")
            }
        }
        return record
    }

    private static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let data = text?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The call's questions: current `questions[]`, or one legacy scalar
    /// `{question, choices}`.
    private static func askedQuestions(in arguments: [String: Any]?) -> [[String: Any]] {
        guard let arguments else { return [] }
        if let questions = arguments["questions"] as? [[String: Any]] { return questions }
        return arguments["question"] != nil ? [arguments] : []
    }

    private static func nonEmptyText(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func textList(_ value: Any?) -> [String]? {
        guard let items = value as? [Any] else { return nil }
        return items.compactMap { nonEmptyText($0) }
    }
}

extension ChatMessage {
    /// This row presented with `clarify` attached, for a view that renders
    /// it as a clarify card. The stored transcript row is unchanged.
    func presenting(_ clarify: ClarifyActivity) -> ChatMessage {
        var copy = self
        copy.clarify = clarify
        return copy
    }
}
