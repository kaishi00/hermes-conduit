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
    /// `text`, or nil while one is still open (or a tag, comment or script
    /// is still being written). A closing tag closes its element and any
    /// left open inside it, as a browser does; one with nothing to close is
    /// passed over.
    private static func closingOffset(in text: String) -> Int? {
        let ns = text as NSString
        var open: [String] = []
        var at = 0
        while true {
            guard let match = token.firstMatch(in: text, range: NSRange(location: at, length: ns.length - at)) else { return nil }
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
            if open.isEmpty, !found.hasPrefix("<!") { return at }
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

    /// The page starting at line `start` (which `startsPage`).
    static func page(in lines: [String], at start: Int) -> PageSpan {
        var line = start
        while true {
            let text = lines[line...].joined(separator: "\n")
            guard let offset = closingOffset(in: text) else {
                return PageSpan(start: start, end: lines.count, isComplete: false)
            }
            // The line holding the closing tag ends this part.
            let through = (text as NSString).substring(to: offset)
            let end = line + through.components(separatedBy: "\n").count
            var next = end
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            // Another page tag after blank lines continues the same page.
            if next < lines.count, startsPage(lines[next]) {
                line = next
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
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
            if startsPage(line) {
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

    private static let foldOpening = compiled(#"^ {0,3}<details(\s+open(?:=(?:"[^"]*"|'[^']*'|\S+))?)?\s*>\s*(?:<summary>(.*?)</summary>)?\s*$"#, [.caseInsensitive])
    private static let foldSummary = compiled(#"^ {0,3}<summary>(.*?)</summary>\s*$"#, [.caseInsensitive])
    private static let foldClosing = compiled(#"^ {0,3}</details\s*>\s*$"#, [.caseInsensitive])

    /// Whether `line` opens a fold.
    static func opensFold(_ line: String) -> Bool {
        line.contains("<") && matches(foldOpening, line)
    }

    /// The fold opening at line `start`, or nil when it doesn't open one.
    static func fold(in lines: [String], at start: Int) -> Fold? {
        let opening = lines[start] as NSString
        guard let match = foldOpening.firstMatch(in: lines[start], range: NSRange(location: 0, length: opening.length)) else { return nil }
        let isOpen = match.range(at: 1).location != NSNotFound
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
        #"</?(?:b|strong|i|em|u|ins|s|del|strike|mark|kbd|sub|sup|span|font|details|summary)(?:\s(?:[^<>"']|"[^"]*"|'[^']*')*)?/?>"#,
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
            var result = ""
            var at = 0
            for span in codeSpans(in: line) + [NSRange(location: ns.length, length: 0)] {
                let outside = ns.substring(with: NSRange(location: at, length: span.location - at))
                result += replacing(drawnTag, in: replacing(lineBreakTag, in: outside, with: " "), with: "")
                result += ns.substring(with: span)
                at = span.location + span.length
            }
            return result
        }.joined(separator: "\n")
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
