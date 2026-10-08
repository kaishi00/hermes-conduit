//
//  VoiceReadBack.swift
//  Conduit
//
//  A reply the user asked to hear again or in full (#451), as the live
//  model reads it: Markdown flattened into plain speech, so nothing is
//  skipped or read out as symbols. Headings, list items and table rows
//  become sentences, links keep their words, a bare link becomes its site,
//  and code stays in the chat.
//

import Foundation

enum VoiceReadBack {
    /// Said in place of a code block. Read word for word like the rest of
    /// the reply, so it's in the app's language.
    static var codeBlockNote: String { AppLocalization.string("(There's code here; it's in the chat.)") }

    /// `markdown` as plain speech, paragraphs kept.
    static func plainSpeech(_ markdown: String) -> String {
        let note = codeBlockNote
        var lines: [String] = []
        var fence: String?
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
                // Back-to-back code blocks get one note.
                if lines.last(where: { !$0.isEmpty }) != note { lines.append(note) }
                continue
            }
            if let spoken = spokenLine(line) { lines.append(spoken) }
        }
        // Emoji go too; the spaces one leaves (before a full stop, at a
        // line's start, doubled) go with it.
        let text = SpokenTextFilter.speakable(lines.joined(separator: "\n"))
            .replacingOccurrences(of: #"[ \t]+([.,!?;:])(?=\s|$)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]+|[ \t]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line without its block markup: a heading, list item or table row
    /// becomes a sentence. Nil drops the line: a rule, a heading's "==="
    /// underline or a table's divider.
    private static func spokenLine(_ line: String) -> String? {
        guard !line.isEmpty else { return "" }
        if line.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil { return nil }
        if line.range(of: #"^=+$"#, options: .regularExpression) != nil { return nil }
        if line.contains("|"), line.contains("-"),
           line.range(of: #"^[|:\-\s]+$"#, options: .regularExpression) != nil { return nil }
        // A table row, with or without its outer pipes (but not a heading,
        // list item or quote that mentions a pipe).
        if line.hasPrefix("|")
            || (line.contains(" | ") && line.range(of: #"^(#{1,6}|[-*+>]|[0-9]{1,3}[.)])\s"#, options: .regularExpression) == nil) {
            let cells = line.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return sentence(inline(cells.joined(separator: ", ")))
        }
        var text = line.replacingOccurrences(of: #"^(>\s*)+"#, with: "", options: .regularExpression)
        if let heading = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            text.removeSubrange(heading)
            text = text.replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
            return sentence(inline(text))
        }
        if let bullet = text.range(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) {
            text.removeSubrange(bullet)
            return sentence(inline(text))
        }
        if text.range(of: #"^[0-9]{1,3}[.)]\s+"#, options: .regularExpression) != nil {
            // The number stays: steps are read in order.
            return sentence(inline(text))
        }
        return inline(text)
    }

    /// Inline markup: links and images keep their words, a bare link its
    /// site, an email address stays, and HTML tags, footnote marks,
    /// emphasis and code marks go.
    private static func inline(_ text: String) -> String {
        var text = text
        let rules: [(String, String)] = [
            // A link's address can hold parentheses ("Foo_(bar)").
            (#"!\[([^\]]*)\]\((?:[^()]|\([^()]*\))*\)"#, "$1"),
            (#"\[([^\]]+)\]\((?:[^()]|\([^()]*\))*\)"#, "$1"),
            (#"<(https?://[^>\s]+)>"#, "$1"),
            (#"<(?:mailto:)?([^\s<>@]+@[^\s<>]+)>"#, "$1"),
            (#"<br\s*/?>"#, " "),
            // Only HTML's own tags: "Vec<String>" in prose is not one.
            (#"</?(?:a|abbr|b|blockquote|center|code|del|details|div|em|font|h[1-6]|hr|i|img|ins|kbd|li|mark|ol|p|pre|s|small|span|strong|sub|summary|sup|table|tbody|td|th|thead|tr|u|ul)(?:\s[^<>]*)?/?>"#, ""),
            // A footnote's mark, and its definition's label.
            (#"\[\^[^\]\s]+\]:?"#, ""),
            // A pipe between words is a separator, not something to say.
            (#"\s+\|\s+"#, ", "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        text = replacingBareLinks(text)
        let marks: [(String, String)] = [
            (#"`([^`]+)`"#, "$1"),
            (#"\*\*(.+?)\*\*"#, "$1"),
            (#"__(.+?)__"#, "$1"),
            (#"~~(.+?)~~"#, "$1"),
            (#"(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])"#, "$1"),
            (#"(?<![\w_])_(?![\s_])(.+?)(?<![\s_])_(?![\w_])"#, "$1"),
        ]
        for (pattern, template) in marks {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    /// "https://www.example.com/a/b" → "example.com": a URL read out is
    /// noise, the site says where it goes. Balanced parentheses belong to
    /// the URL; a closing one that wraps it doesn't.
    private static func replacingBareLinks(_ text: String) -> String {
        let pattern = #"https?://(?:[^\s<>()\[\]]|\([^\s<>()\[\]]*\))*(?:[^\s<>()\[\].,;:!?'"]|\([^\s<>()\[\]]*\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let link = result.substring(with: match.range)
            var site = URL(string: link)?.host ?? ""
            if site.hasPrefix("www.") { site.removeFirst(4) }
            result = result.replacingCharacters(in: match.range, with: site.isEmpty ? AppLocalization.string("a link") : site) as NSString
        }
        return result as String
    }

    /// Ends `text` like a sentence, so it is read as one.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return trimmed }
        return ".!?:;,…。！？".contains(last) ? trimmed : trimmed + "."
    }
}
