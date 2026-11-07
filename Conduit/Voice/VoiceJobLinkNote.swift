//
//  VoiceJobLinkNote.swift
//  Conduit
//
//  The line a saved voice call gets where it started a background job
//  ("Started a background job: <title>. [Open job](conduit://session/…)")
//  or sent work to its chat ("Asked the chat: <title>. [Open chat](…)"),
//  read back so the transcript can draw it as a card instead of a sentence
//  with a link in it.
//
//  The line was written in the app language of the day, so it is matched
//  against every shipped language's wording. A line that matches none of
//  them stays plain text. A reply in exactly that shape, ending in an app
//  link, would draw as a card too; that is accepted, as it opens the same
//  chat the link would.
//

import Foundation

struct VoiceJobLinkNote: Equatable {
    enum Kind: Hashable {
        /// A background job the call started: the link opens the job's chat.
        case job
        /// Work the call sent to its chat: the link opens that chat.
        case chat
    }

    let kind: Kind
    let title: String
    let link: ConduitAppLink

    init(kind: Kind, title: String, link: ConduitAppLink) {
        self.kind = kind
        self.title = title
        self.link = link
    }

    init?(text: String) {
        guard text.range(of: "](\(ConduitAppLink.scheme)://", options: .caseInsensitive) != nil, !text.contains("\n") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.trailingLink.firstMatch(in: text, range: range),
              let labelRange = Range(match.range(at: 1), in: text),
              let urlRange = Range(match.range(at: 2), in: text),
              let fullRange = Range(match.range, in: text),
              let url = URL(string: String(text[urlRange])),
              let link = ConduitAppLink(url: url) else { return nil }
        switch link {
        case .session, .bot: break
        case .settings, .file: return nil
        }
        let label = Self.unescaped(String(text[labelRange]))
        let line = text[..<fullRange.lowerBound].trimmingCharacters(in: .whitespaces)
        for template in Self.templates where template.label == label {
            guard line.count > template.head.count + template.tail.count,
                  line.hasPrefix(template.head), line.hasSuffix(template.tail) else { continue }
            let title = line.dropFirst(template.head.count).dropLast(template.tail.count)
                .trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            self.init(kind: template.kind, title: title, link: link)
            return
        }
        return nil
    }

    /// A Markdown link at the end of the line, as `ConduitAppLink.markdown`
    /// writes it.
    private static let trailingLink = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\]\\\n])*)\]\((conduit://[^)\s]*)\)\s*$"#,
        options: [.caseInsensitive]
    )

    private static func unescaped(_ label: String) -> String {
        label.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }

    private struct Template: Hashable {
        let kind: Kind
        /// The sentence's words before and after the title.
        let head: String
        let tail: String
        let label: String
    }

    /// Each shipped language's wording of both lines, built once: the
    /// bundles never change while the app runs.
    private static let templates: [Template] = {
        let marker = "\u{E000}"
        let languages = [AppLanguage.system] + AppLocalizations.main.shipped.map { AppLanguage.localization($0) }
        var seen: Set<Template> = []
        var templates: [Template] = []
        for language in languages {
            let lines: [(Kind, String, String)] = [
                (.job, AppLocalization.string("Started a background job: \(marker).", language: language),
                 AppLocalization.string("Open job", language: language)),
                (.chat, AppLocalization.string("Asked the chat: \(marker).", language: language),
                 AppLocalization.string("Open chat", language: language)),
            ]
            for (kind, sentence, label) in lines {
                let parts = sentence.components(separatedBy: marker)
                guard parts.count == 2 else { continue }
                let template = Template(kind: kind, head: parts[0], tail: parts[1], label: label)
                if seen.insert(template).inserted { templates.append(template) }
            }
        }
        return templates
    }()
}
