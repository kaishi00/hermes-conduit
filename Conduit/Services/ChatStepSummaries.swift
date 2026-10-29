import Foundation

/// A short train of thought for a finished turn's run of steps, under its
/// icons on the collapsed line: what Hermes set out to do and why each step
/// came next, about half a line per tool call. Automatic when switched on
/// (Settings > Chat), or asked from a run's menu (Explain these steps).
/// Conduit asks Hermes a hidden `/btw`: Hermes answers it from a copy of
/// the live conversation that reuses the prompt cache and can't call tools
/// or change the chat (`agent/side_question.py`), so the question costs the
/// cached prefix and some 150 tokens. The summary is kept on this device,
/// by dashboard and profile and the run's first tool call, and always
/// shows. Only a run whose tool calls have ids of their own is described:
/// an id a provider numbers per turn (`functions.web_search:0`) comes back
/// in other turns and chats.
enum ChatStepSummaries {
    /// Device-only, off by default: each summary is one more model call.
    static let preferenceKey = "conduit.describeStepRuns"
    static let defaultEnabled = false

    /// A run is described once it folds (two steps or more) and has a
    /// tool call in it: thinking alone already reads as itself.
    static let minimumSteps = 2

    /// How many summaries the device keeps; the oldest go first.
    static let savedLimit = 500
    private static let savedKey = "conduit.stepRunSummaries"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? defaultEnabled
    }

    /// Longer runs aren't summarized on their own (their menu still
    /// explains them): set in Settings > Chat.
    static let maxStepsKey = "conduit.stepRunSummaryMaxSteps"
    static let defaultMaxSteps = 20
    static let maxStepsRange = 5...100

    static func maxSteps(_ defaults: UserDefaults = .standard) -> Int {
        clampedMaxSteps(defaults.object(forKey: maxStepsKey) as? Int ?? defaultMaxSteps)
    }

    static func clampedMaxSteps(_ value: Int) -> Int {
        min(max(value, maxStepsRange.lowerBound), maxStepsRange.upperBound)
    }

    /// Whether a finished run gets an automatic summary, counted like the
    /// folded line's "N steps": the steps Settings > Chat shows (thoughts shown on request aside), enough
    /// to fold and no more than the limit.
    static func isAsked(
        _ run: [ChatMessage],
        showingTools: Bool,
        showingReasoning: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let shown = run.filter { $0.role == .tool ? showingTools : showingReasoning }.count
        return (minimumSteps...maxSteps(defaults)).contains(shown)
    }

    /// How long a question is remembered unanswered.
    static let answerWait: TimeInterval = 120

    /// A run's key: its first tool call's id, the same live and in history.
    /// Nil when that id isn't one of a kind.
    static func key(toolIDs: [String?]) -> String? {
        guard let first = toolIDs.lazy.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return isDistinct(first) ? first : nil
    }

    /// Provider ids (`call_…`, `toolu_…`) are random and long; a numbered
    /// one (`functions.web_search:0`) or a short one repeats.
    static func isDistinct(_ id: String) -> Bool {
        id.count >= 12 && id.range(of: #":\d+$"#, options: .regularExpression) == nil
    }

    /// The finished turn's last run of steps, when it folds and has a tool
    /// call to describe: the steps closest to the end, after the user's
    /// last message.
    static func lastRun(in messages: [ChatMessage]) -> [ChatMessage]? {
        var end = messages.endIndex
        while end > messages.startIndex, !ChatStepGroup.isStep(messages[end - 1]) {
            if messages[end - 1].role == .user { return nil }
            end -= 1
        }
        var start = end
        while start > messages.startIndex, ChatStepGroup.isStep(messages[start - 1]) {
            start -= 1
        }
        let run = Array(messages[start..<end])
        let tools = run.filter { $0.role == .tool }
        // A step still running means the turn hasn't settled.
        guard !tools.contains(where: { $0.tool?.status == .running }) else { return nil }
        return run.count >= minimumSteps && !tools.isEmpty ? run : nil
    }

    /// The summary's size: about half a line on the phone per tool call,
    /// two lines at least and four at most, so a long run doesn't make a
    /// page of it.
    static let wordsPerLine = 9
    static let minLines = 2
    static let maxLines = 4

    static let questionHead = "Look back at the tool calls you made just before your last reply"
    private static let questionTail = "Reply with the paragraph only."

    /// A retrospective train of thought, not a list of tools or a report
    /// of results: Hermes answers from the whole conversation, every call's
    /// arguments and results included, so it can say what it set out to
    /// do and why each step came next. The reply already gives the results.
    static func question(language: String, words: Int) -> String {
        "\(questionHead). \(questionScope) " + questionBody(language: language, words: words)
    }

    /// Without them Hermes tells neighbouring turns' steps too.
    private static let questionScope = "Only the calls since the user's last message: earlier turns are context, not part of this story."
    private static let explainScope = "Tell only this run, nothing that came before or after."

    private static func questionBody(language: String, words: Int) -> String {
        "In \(language), tell the user, looking back, the train of thought that led you through them: "
            + "what you set out to find, why each step came next, and how what you learned changed your course. "
            + "Tell it as one coherent story of intentions, not a report of outcomes: your reply already gives the results, "
            + "so mention a result only where it changed what you did next. "
            + "Name the real things you were after (the question, file, page or command), never the tool names: "
            + "not \"I ran the terminal and used search\", but \"I first wanted to know whether the sandbox was fresh, so…\". "
            + "One natural, flowing paragraph of at most \(words) words, first person, past tense: "
            + "no list, headings or preamble, and nothing about how many calls there were. "
            + "It labels those steps, folded, in the user's chat app. "
            + questionTail
    }

    static let explainHead = "Look back at these tool calls you made earlier in this chat"

    /// Asked from a run's menu, for any finished run: Hermes may no longer
    /// hold an older run (its /btw sees only up to the last reply, or a
    /// short digest once the chat's agent is gone), so the question carries
    /// each call's arguments and the start of its result.
    static func explainQuestion(language: String, words: Int, steps: [ToolActivity]) -> String {
        "\(explainHead):\n" + explainSteps(steps) + "\n\(explainScope) " + questionBody(language: language, words: words)
    }

    /// The calls as the question lists them, trimmed: enough to point at
    /// the run and recall it, not to replay it.
    static func explainSteps(_ steps: [ToolActivity]) -> String {
        var lines = steps.prefix(maxExplainedSteps).enumerated().map { index, step in
            var line = "\(index + 1). \(step.name)"
            if let input = trimmed(step.input, to: 300) { line += " \(input)" }
            if let output = trimmed(step.output, to: 400) { line += "\n   → \(output)" }
            return line
        }
        // A longer run is still the one to tell: say how it went on.
        if steps.count > maxExplainedSteps {
            lines.append("…and \(steps.count - maxExplainedSteps) more calls in the same run.")
        }
        return lines.joined(separator: "\n")
    }

    static let maxExplainedSteps = 30

    private static func trimmed(_ text: String?, to limit: Int) -> String? {
        guard let text else { return nil }
        // Cut first: a result can be megabytes, and this runs on the main actor.
        let flat = text.prefix(limit * 4).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// An explanation runs longer than the folded summary: half again,
    /// four lines at least and eight at most.
    static func explainWords(toolCount: Int) -> Int {
        min(max(words(toolCount: toolCount) * 3 / 2, 4 * wordsPerLine), maxExplainWords)
    }

    static let maxExplainWords = 8 * wordsPerLine

    /// The word budget for a run of this many tool calls.
    static func words(toolCount: Int) -> Int {
        let half = (toolCount * wordsPerLine + 1) / 2
        return min(max(half, minLines * wordsPerLine), maxLines * wordsPerLine)
    }

    /// Whether a /btw asked exactly this, or a run's explanation, in
    /// whichever language and word count it names, or the one-sentence
    /// question an earlier Conduit asked: its answer, late or replayed, or another device's, is never
    /// shown as a note.
    static func isQuestion(_ text: String?) -> Bool {
        guard let text else { return false }
        // From the end: an explanation's listed calls come first and may
        // say anything.
        if let tell = text.range(of: ", tell the user, looking back", options: .backwards),
           let lead = text.range(of: "In ", options: .backwards, range: text.startIndex..<tell.lowerBound),
           let words = text[tell.upperBound...].firstMatch(of: #/at most (\d+) words/#),
           let count = Int(words.1) {
            let body = questionBody(language: String(text[lead.upperBound..<tell.lowerBound]), words: count)
            if text.hasPrefix(questionHead) { return text == "\(questionHead). \(questionScope) " + body }
            if text.hasPrefix(explainHead + ":\n") { return text.hasSuffix("\n\(explainScope) " + body) }
            return false
        }
        // The question until 2.2.1.
        guard text.hasPrefix("Describe in one short sentence"),
              let start = text.range(of: "Write it in "),
              let end = text.range(of: ", in the past tense", range: start.upperBound..<text.endIndex)
        else { return false }
        return text == "Describe in one short sentence (at most 15 words) what you did in the tool calls just before your last reply. "
            + "It labels those steps, folded, in the user's chat app. "
            + "Write it in \(text[start.upperBound..<end.lowerBound]), in the past tense, like \"Searched three sites and compared their prices\". "
            + "Reply with the sentence only."
    }

    /// The app's language, named in English for the question.
    static var languageName: String {
        let locale = AppLocalization.formattingLocale
        let code = locale.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? "English"
    }

    /// The answer as one paragraph, without quotes, bold or a list's
    /// bullets. Nil for an error, an empty answer or one far past its
    /// budget.
    static func cleaned(_ text: String) -> String? {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.lowercased().hasPrefix("error:") else { return nil }
        var parts: [String] = []
        for raw in whole.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^([-•*·–—]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { parts.append(line) }
        }
        let paragraph = parts.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«»*").union(.whitespaces))
        guard !paragraph.isEmpty, paragraph.count <= maxExplainWords * 16 else { return nil }
        return paragraph
    }

    // MARK: - Saved summaries

    /// A run, as its summary is kept: the dashboard and profile it ran on
    /// (`AppState.toolCatalogKey`) and its first tool call.
    struct Run: Hashable {
        let scope: String
        let toolID: String
    }

    /// By scope, then by first tool call.
    static func saved(_ defaults: UserDefaults = .standard) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for entry in defaults.array(forKey: savedKey) as? [[String]] ?? [] where entry.count == 3 {
            result[entry[0], default: [:]][entry[1]] = entry[2]
        }
        return result
    }

    /// Adds one, oldest first in storage so the limit drops the oldest.
    static func save(_ summary: String, for run: Run, defaults: UserDefaults = .standard) {
        var entries = (defaults.array(forKey: savedKey) as? [[String]] ?? [])
            .filter { $0.count == 3 && !($0[0] == run.scope && $0[1] == run.toolID) }
        entries.append([run.scope, run.toolID, summary])
        defaults.set(Array(entries.suffix(savedLimit)), forKey: savedKey)
    }

    /// Forgets the summaries of scopes starting with `scopePrefix` (one
    /// dashboard's profiles), or all of them when it is nil.
    static func remove(scopePrefix: String?, defaults: UserDefaults = .standard) {
        guard let scopePrefix else {
            defaults.removeObject(forKey: savedKey)
            return
        }
        let entries = (defaults.array(forKey: savedKey) as? [[String]] ?? [])
            .filter { $0.count == 3 && !$0[0].hasPrefix(scopePrefix) }
        defaults.set(entries, forKey: savedKey)
    }
}
