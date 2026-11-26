//
//  ReplyHTML.swift
//  Conduit
//
//  HTML a reply writes (Eric 2026-11-26): one rule for Hermes, "HTML in
//  your reply draws". Conduit for desktop's htmlInReplies and the plugin's
//  push text read it the same way.
//
//  - A page: a line that starts with a page's tag (`<div`, `<table`,
//    `<svg`, `<style`, `<!doctype html`…) outside a code fence starts one.
//    It runs to where its elements close, taking in the page tags that
//    follow it (a `<style>`, then a `<div>`, then a `<script>`), and draws
//    in the page card `::preview` uses (HTMLPreviewBlock), sandboxed.
//  - A fold: `<details>` with its `<summary>` folds the Markdown up to its
//    `</details>`.
//  - Text tags: bold, italics, underline, strikethrough, `<mark>`, `<kbd>`,
//    `<sub>`, `<sup>`, a colored `<span>` or `<font>`, and `<br>` draw as
//    text. Any other tag, or one that isn't closed, stays text as it always
//    did; so does every tag in a code span or a fenced block.
//
//  This file is Foundation alone, as the Watch reads replies too
//  (project.yml); drawing the text tags is ReplyHTMLText.swift.
//

import Foundation

enum ReplyHTML {
    // MARK: Pages

    /// Tags that start a page when a line starts with one.
    static let pageTags: Set<String> = Set((
        "html head body style script div table svg canvas section article figure header footer main nav aside form "
        + "img picture video audio iframe center h1 h2 h3 h4 h5 h6 p ul ol dl blockquote pre button input select textarea "
        + "link meta template").split(separator: " ").map(String.init))
    private static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
    private static let rawTextTags: Set<String> = ["script", "style", "textarea", "title"]

    static func compiled(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static let pageStart = compiled(#"^ {0,3}(?:<!doctype\s+html\b|<([a-zA-Z][a-zA-Z0-9]*)(?=[\s/>]|$))"#, [.caseInsensitive])
    // A tag, a comment or a declaration; a tag's attributes may hold `>` inside quotes.
    private static let token = compiled(
        #"<!--[\s\S]*?(?:-->|$)|<![^>]*>?|</([a-zA-Z][a-zA-Z0-9-]*)\s*>|<([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(/?)>"#)
    private static let partialTag = compiled(#"^ {0,3}<[!a-zA-Z]*$"#)

    /// Whether `line` starts a page.
    static func startsPage(_ line: String) -> Bool {
        guard line.contains("<") else { return false }
        let ns = line as NSString
        guard let match = pageStart.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
        let name = match.range(at: 1)
        return name.location == NSNotFound || pageTags.contains(ns.substring(with: name).lowercased())
    }

    /// The UTF-16 offset just past the tag that leaves no element open in
    /// `text`, reading from `start`, or nil while one is still open (or a
    /// tag, comment or script is still being written). A closing tag closes
    /// its element and any left open inside it, as a browser does; one with
    /// nothing to close is passed over. Tags after it on its line are read
    /// too, so an element opened there keeps the page going.
    private static func closingOffset(in ns: NSString, from start: Int = 0) -> Int? {
        // Bridged once, so each read from `start` costs only the text it reads.
        let text = ns as String
        var open: [String] = []
        var at = start
        var emptied: Int?
        while true {
            let match = token.firstMatch(in: text, range: NSRange(location: at, length: ns.length - at))
            if let emptied {
                let lineEnd = ns.range(of: "\n", range: NSRange(location: emptied, length: ns.length - emptied)).location
                guard let match, lineEnd == NSNotFound || match.range.location <= lineEnd else { return emptied }
                // Only another page element right after it carries the page on; prose with a tag in it stays prose.
                guard match.range(at: 2).location != NSNotFound,
                      pageTags.contains(ns.substring(with: match.range(at: 2)).lowercased()),
                      ns.substring(with: NSRange(location: emptied, length: match.range.location - emptied))
                          .trimmingCharacters(in: .whitespaces).isEmpty else { return emptied }
            }
            guard let match else { return nil }
            let found = ns.substring(with: match.range)
            at = match.range.location + match.range.length
            if found.hasPrefix("<!--") {
                if !found.hasSuffix("-->") { return nil }
            } else if match.range(at: 1).location != NSNotFound {
                let name = ns.substring(with: match.range(at: 1)).lowercased()
                if let index = open.lastIndex(of: name) { open.removeSubrange(index...) }
            } else if match.range(at: 2).location != NSNotFound {
                let name = ns.substring(with: match.range(at: 2)).lowercased()
                let selfClosing = match.range(at: 4).length > 0
                if !voidTags.contains(name), !selfClosing {
                    if rawTextTags.contains(name) {
                        // Its text runs to its own closing tag: a script's `<` or `"</div>"` is not a tag.
                        let end = ns.range(of: "</\(name)", options: .caseInsensitive, range: NSRange(location: at, length: ns.length - at))
                        guard end.location != NSNotFound else { return nil }
                        let close = ns.range(of: ">", range: NSRange(location: end.location, length: ns.length - end.location))
                        guard close.location != NSNotFound else { return nil }
                        at = close.location + 1
                    } else {
                        open.append(name)
                    }
                }
            }
            if found.hasPrefix("<!") { continue }
            emptied = open.isEmpty ? at : nil
        }
    }

    struct PageSpan: Equatable {
        /// The page's first line and the line after its last.
        let start: Int
        let end: Int
        /// Its elements all closed, and something other than a page comes
        /// after it: nothing more will join it.
        let isComplete: Bool
    }

    private static let tableSeparator = compiled(#"^ {0,3}\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)+\|?\s*$"#)

    /// Whether line `index` starts a page: a table row or header that
    /// starts with a tag is the table's.
    static func startsPage(in lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        guard startsPage(line) else { return false }
        guard line.contains("|") else { return true }
        if index > 0, lines[index - 1].contains("|") { return false }
        return !(index + 1 < lines.count && matches(tableSeparator, lines[index + 1]))
    }

    /// The page starting at line `start` (which `startsPage`).
    static func page(in lines: [String], at start: Int) -> PageSpan {
        // Joined once; `from` is where the part being read starts in it.
        let text = lines[start...].joined(separator: "\n")
        let ns = text as NSString
        var line = start
        var from = 0
        while true {
            guard let offset = closingOffset(in: ns, from: from) else {
                return PageSpan(start: start, end: lines.count, isComplete: false)
            }
            // The line holding the closing tag ends this part.
            let through = ns.substring(with: NSRange(location: from, length: offset - from))
            let end = line + through.components(separatedBy: "\n").count
            var next = end
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            // Another page tag after blank lines continues the same page.
            if next < lines.count, startsPage(in: lines, at: next) {
                while line < next {
                    from += (lines[line] as NSString).length + 1
                    line += 1
                }
                continue
            }
            if next >= lines.count { return PageSpan(start: start, end: end, isComplete: false) }
            // The reply's last line may be a page tag still being written.
            if next == lines.count - 1, matches(partialTag, lines[next]) {
                return PageSpan(start: start, end: end, isComplete: false)
            }
            return PageSpan(start: start, end: end, isComplete: true)
        }
    }

    /// A page's HTML from its lines.
    static func html(of span: PageSpan, in lines: [String]) -> String {
        lines[span.start..<span.end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` with each page outside a code fence as `said`; nil drops it.
    static func pagesSaid(_ text: String, as said: String?) -> String {
        guard text.contains("<") else { return text }
        // Folds apart first, so a page inside a fold written on one line is said as a page too.
        let lines = foldsApart(text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        var out: [String] = []
        var fence = CodeFence()
        var index = 0
        var changed = false
        while index < lines.count {
            let line = lines[index]
            if fence.isCode(line) {
                out.append(line)
                index += 1
                continue
            }
            if startsPage(in: lines, at: index) {
                index = page(in: lines, at: index).end
                if let said { out.append(said) }
                changed = true
                continue
            }
            out.append(line)
            index += 1
        }
        return changed ? out.joined(separator: "\n") : text
    }

    // MARK: Folds

    struct Fold: Equatable {
        let summary: String
        /// The Markdown inside it.
        let body: String
        let isOpen: Bool
        /// The line after its `</details>`, or the reply's end while it's being written.
        let end: Int
    }

    private static let foldOpening = compiled(#"^ {0,3}<details((?:\s+[\w-]+(?:=(?:"[^"]*"|'[^']*'|[^\s"'>]+))?)*)\s*>\s*(?:<summary>(.*?)</summary>)?\s*$"#, [.caseInsensitive])
    private static let openAttribute = compiled(#"(?:^|\s)open(?=[\s=]|$)"#, [.caseInsensitive])
    private static let foldSummary = compiled(#"^ {0,3}<summary>(.*?)</summary>\s*$"#, [.caseInsensitive])
    private static let foldClosing = compiled(#"^ {0,3}</details\s*>\s*$"#, [.caseInsensitive])

    private static let foldOpeningStart = compiled(#"^ {0,3}(<details\b(?:[^>"']|"[^"]*"|'[^']*')*>(?:\s*<summary>.*?</summary>)?)(.*)$"#, [.caseInsensitive])
    private static let foldClosingEnd = compiled(#"^(.*?)</details\s*>\s*$"#, [.caseInsensitive])

    /// `lines` with a fold written on one line,
    /// `<details><summary>S</summary>body</details>`, taken apart into its
    /// opening, its body and its `</details>`, each a line of its own, as
    /// `fold(in:at:)` reads them. Code is left as written.
    static func foldsApart(_ lines: [String]) -> [String] {
        guard lines.contains(where: { $0.range(of: "details", options: .caseInsensitive) != nil }) else { return lines }
        var out: [String] = []
        var fence = CodeFence()
        var depth = 0
        // Whether a `</details>` comes after line `index`: a tag starting a line of prose opens a fold only then.
        var closedAfter = [Bool](repeating: false, count: lines.count)
        // A `</details>` in code (a fence, a code span) or a comment closes nothing.
        var codeFence = CodeFence()
        let inCode = lines.map { codeFence.isCode($0) }
        // More `</details>` after it than folds opened after it: one is left over for this line's.
        var closes = 0
        for index in lines.indices.reversed() {
            closedAfter[index] = closes > 0
            guard !inCode[index] else { continue }
            let line = withoutCode(lines[index])
            // Only a `</details>` ending its line closes a fold, as fold(in:at:) reads it; one in prose doesn't.
            if matches(foldClosingEnd, line) {
                closes += foldClosingTag.numberOfMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            }
            if matches(foldOpeningStart, line) { closes = max(0, closes - 1) }
        }
        for (index, line) in lines.enumerated() {
            if fence.isCode(line) {
                out.append(line)
                continue
            }
            var rest = line
            let ns = line as NSString
            if let opening = foldOpeningStart.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               opensFoldHere(after: ns.substring(with: opening.range(at: 2)),
                             closedLater: closedAfter[index],
                             withSummary: ns.substring(with: opening.range(at: 1)).range(of: "</summary>", options: .caseInsensitive) != nil) {
                let after = ns.substring(with: opening.range(at: 2))
                guard !after.trimmingCharacters(in: .whitespaces).isEmpty else {
                    out.append(line)
                    depth += 1
                    continue
                }
                out.append(ns.substring(with: opening.range(at: 1)))
                depth += 1
                rest = after
            } else if matches(foldClosing, line) {
                depth = max(0, depth - 1)
                out.append(line)
                continue
            }
            let restNS = rest as NSString
            if depth > 0, let closing = foldClosingEnd.firstMatch(in: rest, range: NSRange(location: 0, length: restNS.length)) {
                let body = restNS.substring(with: closing.range(at: 1))
                if !body.trimmingCharacters(in: .whitespaces).isEmpty { out.append(body) }
                out.append("</details>")
                depth -= 1
                continue
            }
            out.append(rest)
        }
        return out
    }

    private static let foldClosingTag = compiled(#"</details\s*>"#, [.caseInsensitive])
    private static let tagStart = compiled(#"<[a-zA-Z/!]"#)
    private static let comment = compiled(#"<!--.*?-->"#)

    /// `line` without its code spans and comments: a `</details>` in one closes nothing.
    private static func withoutCode(_ line: String) -> String {
        let ns = NSMutableString(string: line)
        for span in codeSpans(in: line).reversed() { ns.replaceCharacters(in: span, with: "") }
        return replacing(comment, in: ns as String, with: "")
    }

    /// Whether a `<details>` starting a line, followed by `after`, is a
    /// fold's opening: nothing after it, a body ending the fold on the line,
    /// a body after its own `<summary>` (its `</details>` later or still
    /// streaming in), or text with no
    /// tags that a later `</details>` closes. `<details> and <summary> make a
    /// fold.` and `<details> is the tag.` ending a reply stay prose.
    private static func opensFoldHere(after: String, closedLater: Bool, withSummary: Bool) -> Bool {
        let body = after.trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return true }
        // A body starting with a fence mark stays on the line, so it can't open a code block that runs on.
        if body.hasPrefix("```") || body.hasPrefix("~~~") { return false }
        if matches(foldClosingEnd, after) { return true }
        if withSummary { return true }
        return closedLater && !matches(tagStart, after)
    }

    /// Whether `line` opens a fold.
    static func opensFold(_ line: String) -> Bool {
        line.contains("<") && matches(foldOpening, line)
    }

    /// The fold opening at line `start`, or nil when it doesn't open one.
    static func fold(in lines: [String], at start: Int) -> Fold? {
        let opening = lines[start] as NSString
        guard let match = foldOpening.firstMatch(in: lines[start], range: NSRange(location: 0, length: opening.length)) else { return nil }
        let isOpen = match.range(at: 1).length > 0
            && matches(openAttribute, opening.substring(with: match.range(at: 1)).replacingOccurrences(of: #""[^"]*"|'[^']*'"#, with: "\"\"", options: .regularExpression))
        var summary = match.range(at: 2).location != NSNotFound ? untagged(opening.substring(with: match.range(at: 2))) : nil
        var index = start + 1
        if summary == nil {
            // A summary of its own, as the fold's first line.
            var next = index
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            if next < lines.count, let own = foldSummary.firstMatch(in: lines[next], range: NSRange(location: 0, length: (lines[next] as NSString).length)) {
                summary = untagged((lines[next] as NSString).substring(with: own.range(at: 1)))
                index = next + 1
            }
        }
        var body: [String] = []
        var depth = 0
        var fence = CodeFence()
        while index < lines.count {
            let line = lines[index]
            if !fence.isCode(line) {
                if opensFold(line) { depth += 1 }
                else if matches(foldClosing, line) {
                    if depth == 0 {
                        return Fold(summary: summary ?? "", body: joined(body), isOpen: isOpen, end: index + 1)
                    }
                    depth -= 1
                }
            }
            body.append(line)
            index += 1
        }
        return Fold(summary: summary ?? "", body: joined(body), isOpen: isOpen, end: lines.count)
    }

    private static func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static let anyTag = compiled(#"</?[a-zA-Z][a-zA-Z0-9-]*(?:\s[^<>]*)?/?>"#)
    private static let lineBreakTag = compiled(#"<br\s*/?>"#, [.caseInsensitive])
    /// The tags the chat draws; any other stays text there, so it stays here too.
    private static let drawnTag = compiled(
        #"</?(b|strong|i|em|u|ins|s|del|strike|mark|kbd|sub|sup|span|font|details|summary)(?:\s+[\w-]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'<>]+))?)*\s*/?>"#,
        [.caseInsensitive])

    private static func untagged(_ text: String) -> String {
        replacing(anyTag, in: text, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// `text` without the tags the chat draws, for places that read a reply
    /// rather than draw it; `<br>` a space. Tags in a code span or a fenced block stay:
    /// they are what it shows.
    static func withoutTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var fence = CodeFence()
        return text.components(separatedBy: "\n").map { line -> String in
            guard !fence.isCode(line), line.contains("<") else { return line }
            let ns = line as NSString
            var spaced = ""
            var at = 0
            for span in codeSpans(in: line) + [NSRange(location: ns.length, length: 0)] {
                spaced += replacing(lineBreakTag, in: ns.substring(with: NSRange(location: at, length: span.location - at)), with: " ")
                spaced += ns.substring(with: span)
                at = span.location + span.length
            }
            // Paired over the whole line, a code span's own tags left out: `<b>`make`</b>` pairs.
            return pairedTagsOut(spaced, outside: codeSpans(in: spaced))
        }.joined(separator: "\n")
    }

    /// `text` without the drawn tags that pair up, as the chat draws only
    /// those; an unclosed `<b>` stays, as it does there. A fold's
    /// `<details>` and `<summary>` always go.
    private static func pairedTagsOut(_ text: String, outside code: [NSRange] = []) -> String {
        let ns = text as NSString
        let found = drawnTag.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { match in !code.contains { NSLocationInRange(match.range.location, $0) } }
        guard !found.isEmpty else { return text }
        var dropped = Set<Int>()
        var opened: [(name: String, index: Int)] = []
        for (index, match) in found.enumerated() {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            if name == "details" || name == "summary" {
                dropped.insert(index)
            } else if !ns.substring(with: match.range).hasPrefix("</") {
                opened.append((name, index))
            } else if let at = opened.lastIndex(where: { $0.name == name }) {
                dropped.insert(opened[at].index)
                dropped.insert(index)
                opened.removeSubrange(at...)
            }
        }
        let result = NSMutableString(string: text)
        for (index, match) in found.enumerated().reversed() where dropped.contains(index) {
            result.replaceCharacters(in: match.range, with: "")
        }
        return result as String
    }

    /// The code spans in `text`: a run of backticks up to the next run of
    /// the same length.
    static func codeSpans(in text: String) -> [NSRange] {
        guard text.contains("`") else { return [] }
        let units = Array(text.utf16)
        var spans: [NSRange] = []
        var index = 0
        while index < units.count {
            guard units[index] == 0x60 else { index += 1; continue }
            var run = index
            while run < units.count, units[run] == 0x60 { run += 1 }
            let length = run - index
            var search = run
            var closed = false
            while search < units.count {
                guard units[search] == 0x60 else { search += 1; continue }
                var end = search
                while end < units.count, units[end] == 0x60 { end += 1 }
                if end - search == length {
                    spans.append(NSRange(location: index, length: end - index))
                    index = end
                    closed = true
                    break
                }
                search = end
            }
            if !closed { index = run }
        }
        return spans
    }

    static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func replacing(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}
