import Foundation

/// What a chat's background delegate agents came back with, read from the
/// report Hermes writes into the chat when they finish (a row it marks
/// `async_delegation_complete`, issue 1553). The report is written for the
/// model; Conduit reads only the parts Hermes itself lays out, each task's
/// header and its result, as Hermes Desktop does (`asyncResultBody` in
/// apps/desktop/src/lib/chat-messages/hydration.ts), never the task's
/// preamble (context, toolsets, transcript paths) or the advice to the model.
struct DelegationReport: Equatable, Codable {
    struct Entry: Equatable, Codable {
        enum Outcome: String, Equatable, Codable {
            case completed
            /// Hit its step cap: the result may be unfinished.
            case incomplete
            case stopped
            case failed
        }

        /// Its place in the delegate_task call, from 1.
        var number: Int
        var goal: String
        var outcome: Outcome
        /// How long it ran, in seconds, when the report says.
        var duration: TimeInterval?
        /// The agent's summary, or what Hermes says about how it ended.
        var result: String
    }

    var entries: [Entry]

    /// The report in `text`, or nil when it isn't one Conduit can read: an
    /// older Hermes, a format it has since changed, or no tasks in it.
    static func parse(_ text: String) -> DelegationReport? {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let entries: [Entry]
        if text.hasPrefix("[ASYNC DELEGATION BATCH COMPLETE") {
            entries = batchEntries(text)
        } else if text.hasPrefix("[ASYNC DELEGATION COMPLETE") {
            entries = singleEntry(text).map { [$0] } ?? []
        } else if text.hasPrefix("[ASYNC DELEGATION TASK FAILED") {
            entries = failureNotice(text).map { [$0] } ?? []
        } else {
            entries = []
        }
        return entries.isEmpty ? nil : DelegationReport(entries: entries)
    }

    // `--- ✓ TASK 2/6: goal  (status=completed, api_calls=4, 12.5s) ---`.
    // A goal can run over lines, so it ends at the two spaces before
    // `(status=` on the header's last line (Desktop's split does the same),
    // never past the next task's header.
    private static let taskHeader = try! NSRegularExpression(
        pattern: #"^--- [✓✗⚠] TASK (\d+)/\d+(?:: ((?:(?!\n--- [✓✗⚠] TASK )[\s\S])*?))? {2}\(status=([^\n]*)\) ---\n?"#,
        options: [.anchorsMatchLines]
    )

    private static func batchEntries(_ text: String) -> [Entry] {
        let ns = text as NSString
        let matches = taskHeader.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // A header Conduit can't read would hide its task: the plain notice
        // then, never a list short of one.
        let headers = text.components(separatedBy: "\n").filter { $0.range(of: #"^--- [✓✗⚠] TASK \d+/\d+"#, options: .regularExpression) != nil }
        guard matches.count == headers.count else { return [] }
        return matches.enumerated().map { index, match in
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let goal = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            let header = ns.substring(with: match.range(at: 3))
            let fields = header.components(separatedBy: ", ")
            let status = fields.first ?? ""
            let duration = fields.dropFirst().lazy.compactMap(seconds(in:)).first
            let truncated = header.contains("TRUNCATED")
            return Entry(
                number: Int(ns.substring(with: match.range(at: 1))) ?? index + 1,
                goal: oneLine(goal),
                outcome: outcome(status: status, truncated: truncated),
                duration: duration,
                result: cleaned(ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))))
            )
        }
    }

    /// One agent's report: `Original goal:` in the preamble, a `Status:`
    /// line, then its result under `--- RESULT ---`.
    private static func singleEntry(_ text: String) -> Entry? {
        let lines = text.components(separatedBy: "\n")
        guard let resultIndex = lines.firstIndex(of: "--- RESULT ---"),
              let statusLine = lines[..<resultIndex].last(where: { $0.hasPrefix("Status: ") }) else { return nil }
        // A goal can run over lines, up to the preamble's next field.
        var goal = ""
        if let goalIndex = lines[..<resultIndex].firstIndex(where: { $0.hasPrefix("Original goal: ") }) {
            let rest = lines[(goalIndex + 1)..<resultIndex].prefix { line in
                !preambleFields.contains { line.hasPrefix($0) }
            }
            goal = ([String(lines[goalIndex].dropFirst("Original goal: ".count))] + rest).joined(separator: "\n")
        }
        return Entry(
            number: 1,
            goal: oneLine(goal),
            outcome: outcome(status: statusField(statusLine), truncated: statusLine.contains("[TRUNCATED")),
            duration: durationField(statusLine),
            result: cleaned(lines[(resultIndex + 1)...].joined(separator: "\n"))
        )
    }

    /// The lines `_preamble` writes after the goal, and the status line.
    private static let preambleFields = ["Context you provided: ", "Toolsets: ", "Role: ", "Status: "]

    /// Hermes' early word that one agent of a batch still running failed:
    /// `Task:`, `Status:` and the error.
    private static func failureNotice(_ text: String) -> Entry? {
        let lines = text.components(separatedBy: "\n")
        guard let statusIndex = lines.firstIndex(where: { $0.hasPrefix("Status: ") }) else { return nil }
        let statusLine = lines[statusIndex]
        let goal = lines.first(where: { $0.hasPrefix("Task: ") }).map { String($0.dropFirst("Task: ".count)) } ?? ""
        let number = text.range(of: #"task (\d+)/\d+\]"#, options: .regularExpression)
            .flatMap { Int(text[$0].dropFirst("task ".count).prefix { $0.isNumber }) } ?? 1
        let error = lines[(statusIndex + 1)...]
            .first(where: { $0.hasPrefix("Error: ") })
            .map { String($0.dropFirst("Error: ".count)) } ?? ""
        return Entry(
            number: number,
            goal: oneLine(goal),
            outcome: outcome(status: statusField(statusLine), truncated: false),
            duration: durationField(statusLine),
            result: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func outcome(status: String, truncated: Bool) -> Entry.Outcome {
        switch status.trimmingCharacters(in: .whitespaces).lowercased() {
        case "completed", "success": return truncated ? .incomplete : .completed
        case "interrupted", "cancelled": return .stopped
        default: return .failed
        }
    }

    /// `Status: completed   API calls: 3   Duration: 12.5s` → `completed`.
    private static func statusField(_ line: String) -> String {
        String(line.dropFirst("Status: ".count).prefix { !$0.isWhitespace })
    }

    private static func durationField(_ line: String) -> TimeInterval? {
        guard let range = line.range(of: #"Duration: [0-9.]+s"#, options: .regularExpression) else { return nil }
        return seconds(in: String(line[range].dropFirst("Duration: ".count)))
    }

    /// `12.5s` → 12.5.
    private static func seconds(in field: String) -> TimeInterval? {
        let field = field.trimmingCharacters(in: .whitespaces)
        guard field.hasSuffix("s"), let value = Double(field.dropLast()), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A task's result without the lines Hermes adds for the model: the
    /// step-cap warning (the entry says Incomplete), where its transcript
    /// is on the host, and its bookkeeping of background processes.
    private static let modelOnlyPrefixes = [
        "[TRUNCATED — ",
        "Full live transcript (complete tool/assistant trace): ",
        "Live transcript: ",
        "Handed off to you: ",
        "Child left ",
        "Child's process ",
        "This model's provider refused the task (content_policy_blocked).",
        "This failure (",
    ]

    private static func cleaned(_ body: String) -> String {
        body.components(separatedBy: "\n")
            .filter { line in !modelOnlyPrefixes.contains { line.hasPrefix($0) } }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
