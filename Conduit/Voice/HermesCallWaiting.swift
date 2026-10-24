//
//  HermesCallWaiting.swift
//  Conduit
//
//  What Hermes waits on in a call's chat, as the voice model says and
//  answers it: the approval's command and why, or each clarify question
//  with its numbered choices, plus what Hermes wrote just before it asked.
//  Built from the chat's own card (or the host's copy for a Watch call),
//  never from the push's short reason alone, which carries none of the
//  choices (designs/hermes-call-clarify.md).
//

import Foundation

struct HermesCallWaiting: Equatable {
    struct Choice: Equatable {
        let label: String
        /// What a tap on it sends.
        let value: String
    }

    struct Question: Equatable {
        let id: String
        let text: String
        let choices: [Choice]
        let multiSelect: Bool
        /// Answered already: a batch is answered one question at a time.
        var answered: Bool = false
    }

    enum Item: Equatable {
        case approval(command: String, description: String)
        case questions([Question])
    }

    let item: Item
    /// What Hermes wrote in the chat just before it asked, clipped; nil
    /// when it wrote nothing.
    let leadUp: String?

    static let maximumLeadUpCharacters = 1_500
    static let maximumCommandCharacters = 600
    static let maximumTextCharacters = 600
    static let maximumChoiceCharacters = 200
    /// Hermes marks its recommended choice with this, after the label.
    static let recommendedLabel = "(Recommended)"

    init(item: Item, leadUp: String? = nil) {
        self.item = item
        self.leadUp = Self.clipped(leadUp, to: Self.maximumLeadUpCharacters)
    }

    /// The questions of a clarify card, answered ones included; nil when
    /// none is left to answer.
    init?(clarify: ClarifyActivity, leadUp: String? = nil) {
        guard !clarify.isExpired else { return nil }
        let questions = clarify.questions.map { question in
            Question(
                id: question.id,
                text: Self.clipped(question.question, to: Self.maximumTextCharacters) ?? "",
                choices: question.choices.map { Choice(label: Self.clipped($0.label, to: Self.maximumChoiceCharacters) ?? $0.value, value: $0.value) },
                multiSelect: question.multiSelect,
                answered: !(question.status == .pending || question.status == .error)
            )
        }
        guard questions.contains(where: { !$0.answered }) else { return nil }
        self.init(item: .questions(questions), leadUp: leadUp)
    }

    /// A pending approval card; nil once it's answered.
    init?(approval: ApprovalActivity, leadUp: String? = nil) {
        guard approval.status == .pending || approval.status == .error else { return nil }
        self.init(
            item: .approval(
                command: Self.clipped(approval.command, to: Self.maximumCommandCharacters) ?? "",
                description: Self.clipped(approval.description, to: Self.maximumTextCharacters) ?? ""
            ),
            leadUp: leadUp
        )
    }

    /// The plugin's copy (GET /calls/waiting, WatchCallAnswer), for a call
    /// answered on the Apple Watch with no chat open; nil when nothing
    /// waits or nothing in it is left to answer.
    init?(host waiting: [String: Any]) {
        switch waiting["kind"] as? String {
        case "approval":
            guard waiting["answered"] as? Bool != true,
                  let description = waiting["description"] as? String, !description.isEmpty else { return nil }
            let command = waiting["command"] as? String ?? ""
            self.init(item: .approval(
                command: Self.clipped(command, to: Self.maximumCommandCharacters) ?? "",
                description: Self.clipped(description, to: Self.maximumTextCharacters) ?? ""
            ))
        case "question":
            let questions = (waiting["questions"] as? [[String: Any]] ?? []).compactMap { entry -> Question? in
                guard let text = entry["question"] as? String, !text.isEmpty else { return nil }
                let choices = (entry["choices"] as? [String] ?? []).map {
                    Choice(label: Self.clipped($0, to: Self.maximumChoiceCharacters) ?? $0, value: $0)
                }
                return Question(
                    id: String(entry["number"] as? Int ?? 0),
                    text: Self.clipped(text, to: Self.maximumTextCharacters) ?? text,
                    choices: choices,
                    multiSelect: entry["multi_select"] as? Bool == true,
                    answered: entry["answered"] as? Bool == true
                )
            }
            guard questions.contains(where: { !$0.answered }) else { return nil }
            self.init(item: .questions(questions))
        default:
            return nil
        }
    }

    var kind: HermesCallRequest.Kind {
        if case .approval = item { return .approval }
        return .question
    }

    /// The first question still waiting for its answer.
    var openQuestion: Question? {
        guard case .questions(let questions) = item else { return nil }
        return questions.first { !$0.answered }
    }

    /// The questions still waiting.
    var openQuestions: [Question] {
        guard case .questions(let questions) = item else { return [] }
        return questions.filter { !$0.answered }
    }

    // MARK: For the voice model
    // Written for the model, not shown, so not localized.

    /// What waits, fenced as data: never instructions, whatever it says.
    var block: String {
        var lines: [String] = []
        if let leadUp {
            lines.append("<hermes_wrote_before_asking>\n\(Self.fenced(leadUp, tag: "hermes_wrote_before_asking"))\n</hermes_wrote_before_asking>")
        }
        switch item {
        case .approval(let command, let description):
            var body: [String] = []
            if !command.isEmpty { body.append("Command: \(command)") }
            if !description.isEmpty { body.append("Why: \(description)") }
            lines.append("<approval_request>\n\(Self.fenced(body.joined(separator: "\n"), tag: "approval_request"))\n</approval_request>")
        case .questions(let questions):
            let open = questions.filter { !$0.answered }
            for (index, question) in open.enumerated() {
                var body = open.count > 1 ? "Question \(index + 1)" : "Question"
                if !question.choices.isEmpty {
                    body += question.multiSelect ? " (they may pick several)" : " (they pick one)"
                }
                body += ": \(question.text)"
                for (number, choice) in question.choices.enumerated() {
                    body += "\n\(number + 1). \(choice.label)"
                }
                if question.choices.isEmpty { body += "\n(No choices: they answer in their own words.)" }
                lines.append("<question>\n\(Self.fenced(body, tag: "question"))\n</question>")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// How the model answers, for the live modes' instructions.
    static func answerRule(delegation: Bool) -> String {
        let answer = delegation ? "delegate \"Answer:\" followed by" : "call answer_question with"
        return "Read the choices out with their numbers, and say which one Hermes recommends when one is marked (Recommended). Explain them from what Hermes wrote, in your own words, when the user asks. When they pick, \(answer) the number of their choice (like 2, or 1, 3 when they may pick several) or, with no fitting choice, their answer in their own words. A batch is answered one question at a time, in order. Never pick for them. Hermes is paused until they answer, so it can't explain more meanwhile: if the user wants Hermes itself to explain, \(answer) their request in their words, starting \"\(asksFirstLead) \", and Hermes will explain and ask again."
    }

    // MARK: Spoken

    /// A question as Classic voice says it and a job's update reads it, in
    /// the app's language: the question, its numbered choices, and how to
    /// answer. `asker`: who asks, for a job ("Check the server asks: …").
    static func spokenQuestion(_ question: Question, asker: String? = nil) -> String {
        var line = asker.map { AppLocalization.string("\($0) asks: \(question.text)") }
            ?? AppLocalization.string("Hermes asks: \(question.text)")
        for (number, choice) in question.choices.enumerated() {
            line += "\n\(number + 1). \(choice.label)"
        }
        line += "\n" + (question.choices.isEmpty
            ? AppLocalization.string("Answer in your own words.")
            : question.multiSelect
                ? AppLocalization.string("Say the numbers of your choices, you may pick several, or answer in your own words.")
                : AppLocalization.string("Say the number of your choice, or answer in your own words."))
        return line
    }

    // MARK: Answers

    /// What an answer to `question` sends Hermes: the chosen choice's value
    /// (or a multi-select list of them) when the words point at choices,
    /// else the words themselves.
    static func answerValue(for words: String, question: Question) -> String {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asksFirst(trimmed), let picked = pickedChoices(in: trimmed, choices: question.choices, multiSelect: question.multiSelect) else {
            return trimmed
        }
        let values = picked.map { question.choices[$0].value }
        return question.multiSelect ? ClarifyQuestion.multiSelectAnswer(values) : values[0]
    }

    /// The label of what `answerValue` sends, for the model to confirm.
    static func answerLabel(for words: String, question: Question) -> String? {
        guard !asksFirst(words), let picked = pickedChoices(in: words, choices: question.choices, multiSelect: question.multiSelect) else { return nil }
        return picked.map { question.choices[$0].label }.joined(separator: ", ")
    }

    /// The choices `words` point at, by index: a choice's label said whole,
    /// "the recommended one", or their numbers ("2", "the second", "one and
    /// three"). Nil when they point at none, or at several for a question
    /// that takes one: those words go to Hermes as they are.
    static func pickedChoices(in words: String, choices: [Choice], multiSelect: Bool) -> [Int]? {
        guard !choices.isEmpty else { return nil }
        let said = normalizedWords(words)
        guard !said.isEmpty else { return nil }
        let labels = choices.map { normalizedWords(strippingRecommended($0.label)) }
        // The whole answer is one choice's label.
        if let index = labels.firstIndex(of: said), labels.filter({ $0 == said }).count == 1 { return [index] }
        // Never past a negation: "not the recommended one", "not Postgres".
        guard !said.contains(where: { negations.contains($0) }) else { return nil }
        // "The recommended one", "go with your recommendation".
        if said.contains(where: { $0.hasPrefix("recommend") || $0 == "suggested" }) {
            let marked = choices.indices.filter { isRecommended(choices[$0].label) }
            if marked.count == 1 { return marked }
        }
        // Numbers, when the words are only numbers and the words around them.
        // "One" after another word ("the second one", "that one") stands
        // for a choice, not its number.
        let counted = said.indices.filter { index in
            said[index] != "one" || index == 0 || oneLeads.contains(said[index - 1])
        }
        let numbers = counted.compactMap { numberWords[said[$0]] ?? Int(said[$0]) }
        let filler = said.allSatisfy { numberWords[$0] != nil || Int($0) != nil || numberFiller.contains($0) }
        if filler, !numbers.isEmpty {
            var seen: [Int] = []
            for number in numbers where !seen.contains(number) { seen.append(number) }
            guard seen.allSatisfy({ (1...choices.count).contains($0) }) else { return nil }
            guard multiSelect || seen.count == 1 else { return nil }
            return seen.map { $0 - 1 }
        }
        // A label said within a few more words ("Postgres, please"), when
        // only one choice's is.
        let contained = labels.indices.filter { index in
            !labels[index].isEmpty && labels[index].joined(separator: " ").count >= 3
                && said.count <= labels[index].count + 4 && contains(said, labels[index])
        }
        if contained.count == 1 { return contained }
        if multiSelect, contained.count > 1 { return contained }
        return nil
    }

    /// The lead an answer starts with when the user wants Hermes to say
    /// more before they choose (answerRule).
    static let asksFirstLead = "Before I choose:"

    /// An answer asking Hermes to say more: it goes as it is.
    static func asksFirst(_ answer: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("before i choose")
    }

    static func isRecommended(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(recommendedLabel.lowercased())
    }

    static func strippingRecommended(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecommended(trimmed) else { return trimmed }
        return String(trimmed.dropLast(recommendedLabel.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    private static func contains(_ words: [String], _ part: [String]) -> Bool {
        guard part.count <= words.count else { return false }
        for start in 0...(words.count - part.count) where Array(words[start..<(start + part.count)]) == part {
            return true
        }
        return false
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "6th": 6, "7th": 7, "8th": 8, "9th": 9, "10th": 10,
    ]

    /// Words that may stand around choice numbers: "option 2, please", "the
    /// first and the third".
    private static let numberFiller: Set<String> = [
        "the", "a", "an", "and", "or", "option", "options", "choice", "choices", "number", "numbers",
        "please", "pick", "choose", "go", "with", "take", "i", "ll", "d", "want", "that", "this", "both",
    ]

    private static let negations: Set<String> = ["not", "no", "don", "dont", "never", "without", "except", "neither", "nor", "instead"]

    /// The words after which "one" is still a number: "option one", "one
    /// and three".
    private static let oneLeads: Set<String> = ["option", "choice", "number", "and", "or", "with", "take", "pick", "choose"]

    private static func clipped(_ text: String?, to limit: Int) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + " […]"
    }

    private static func fenced(_ text: String, tag: String) -> String {
        text.replacingOccurrences(of: "</\(tag)>", with: "</ \(tag)>", options: .caseInsensitive)
    }
}
