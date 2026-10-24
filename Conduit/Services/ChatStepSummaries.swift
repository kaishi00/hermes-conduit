import Foundation

/// One sentence for a finished turn's run of steps, in place of "7 steps"
/// on its collapsed line. Opt-in (Settings > Chat). Once a turn ends with a
/// long enough run, Conduit asks Hermes a hidden `/btw`: Hermes answers it
/// from a copy of the live conversation that reuses the prompt cache and
/// can't call tools or change the chat (`agent/side_question.py`), so the
/// question costs the cached prefix and a few dozen tokens. The sentence is
/// kept on this device, by dashboard and profile and the run's first tool
/// call; turning the switch off hides the kept ones. Only a run whose tool
/// calls have ids of their own is described: an id a provider numbers per
/// turn (`functions.web_search:0`) comes back in other turns and chats.
enum ChatStepSummaries {
    /// Device-only, off by default: each summary is one more model call.
    static let preferenceKey = "conduit.describeStepRuns"
    static let defaultEnabled = false

    /// Shorter runs say enough with their icons.
    static let minimumToolSteps = 3

    /// How many sentences the device keeps; the oldest go first.
    static let savedLimit = 500
    private static let savedKey = "conduit.stepRunSummaries"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? defaultEnabled
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

    /// The finished turn's last run of steps, when it has enough tool
    /// calls to describe: the steps closest to the end, after the user's
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
        return tools.count >= minimumToolSteps ? run : nil
    }

    static let questionHead = "Describe in one short sentence"
    private static let questionTail = "Reply with the sentence only."

    static func question(language: String) -> String {
        "\(questionHead) (at most 15 words) what you did in the tool calls just before your last reply. "
            + "It labels those steps, folded, in the user's chat app. "
            + "Write it in \(language), in the past tense, like \"Searched three sites and compared their prices\". "
            + questionTail
    }

    /// Whether a /btw asked exactly this, in whichever language it names:
    /// its answer, late or replayed, or another device's, is never shown
    /// as a note.
    static func isQuestion(_ text: String?) -> Bool {
        guard let text, text.hasPrefix(questionHead),
              let start = text.range(of: "Write it in "),
              let end = text.range(of: ", in the past tense", range: start.upperBound..<text.endIndex)
        else { return false }
        return text == question(language: String(text[start.upperBound..<end.lowerBound]))
    }

    /// The app's language, named in English for the question.
    static var languageName: String {
        let locale = AppLocalization.formattingLocale
        let code = locale.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? "English"
    }

    /// The answer as a line: its first line, without quotes or a label.
    /// Nil for an error, an empty answer or one too long to be a label.
    static func cleaned(_ text: String) -> String? {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.lowercased().hasPrefix("error:") else { return nil }
        line = line.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«»*"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= 200 else { return nil }
        return line
    }

    // MARK: - Saved sentences

    /// A run, as its sentence is kept: the dashboard and profile it ran on
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

    /// Forgets the sentences of scopes starting with `scopePrefix` (one
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
