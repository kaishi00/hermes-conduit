//
//  TranscriptDirectives.swift
//  Conduit
//
//  Hermes Desktop's transcript directives in a reply: `::preview{file="…"}`
//  (HTMLPreviewBlock draws it) and a Desktop plugin's card such as
//  hermes-rich-ui's `::richui{id="…"}` (DesktopCardBlock shows it, #1522).
//  Foundation only: the Watch names them for its voice models too.
//

import Foundation

/// Finds Hermes Desktop's transcript directives in a line of a reply. The
/// grammar follows Hermes Desktop's (lib/transcript-directives.ts): the
/// directive starts a word (so `std::preview` isn't one), attributes are
/// `key="value"` or `key='value'`, and a preview without a file stays the
/// text it is. `::preview{file="…"}` draws its file; any other directive is
/// a Desktop plugin's card (#1522), which Conduit names instead of showing
/// the raw line.
enum TranscriptDirectives {
    enum Segment: Equatable {
        case text(String)
        case preview(file: String)
        case desktopCard(DesktopCardDirective)
    }

    private static let directiveExpression = try! NSRegularExpression(
        pattern: #"(?:^|(?<=\s))::([A-Za-z][\w-]{0,63})\{([^{}\n]{0,1024})\}"#
    )
    private static let attributeExpression = try! NSRegularExpression(
        pattern: #"([A-Za-z][\w-]{0,63})=(?:"([^"]*)"|'([^']*)')"#
    )
    /// A plugin's directive is only attributes, at least one, so prose and
    /// CSS (`::selection{color:red}`) stay text.
    private static let attributesOnlyExpression = try! NSRegularExpression(
        pattern: #"^\s*(?:[A-Za-z][\w-]{0,63}=(?:"[^"]*"|'[^']*')\s*)+$"#
    )
    private static let htmlExpression = try! NSRegularExpression(
        pattern: #"\.(?:html?|xhtml)$"#,
        options: [.caseInsensitive]
    )

    /// The line split into text, previews and Desktop cards, or nil when it
    /// holds none.
    static func segments(in line: String) -> [Segment]? {
        guard line.contains("::") else { return nil }
        let nsLine = line as NSString
        var segments: [Segment] = []
        var cursor = 0
        let codeSpans = inlineCodeSpans(in: line)
        for match in directiveExpression.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
            // One in a code span is an example.
            guard !codeSpans.contains(where: { $0.location < match.range.location && match.range.location < NSMaxRange($0) }) else { continue }
            let name = nsLine.substring(with: match.range(at: 1))
            let body = nsLine.substring(with: match.range(at: 2))
            let segment: Segment
            if name == "preview" {
                guard let file = attributes(in: body)["file"]?.trimmingCharacters(in: .whitespaces),
                      !file.isEmpty else { continue }
                segment = .preview(file: file)
            } else {
                guard attributesOnlyExpression.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil else { continue }
                segment = .desktopCard(DesktopCardDirective(
                    name: name,
                    attributes: attributes(in: body),
                    source: nsLine.substring(with: match.range)
                ))
            }
            appendText(nsLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &segments)
            segments.append(segment)
            cursor = NSMaxRange(match.range)
        }
        guard cursor > 0 else { return nil }
        appendText(nsLine.substring(from: cursor), to: &segments)
        return segments
    }

    /// Whether the file draws in place; anything else gets a file card.
    static func isHTML(_ path: String) -> Bool {
        htmlExpression.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }

    /// `text` for a voice model telling the user about a reply: it can say
    /// a file or a card is in the chat without reading the directive out.
    static func naming(in text: String) -> String {
        rewriting(
            text,
            preview: { file in "(a file in the chat: \(fileName(file)))" },
            card: { card in "(a card in the chat made for Hermes Desktop, from \(card.plugin))" }
        )
    }

    /// `text` with each directive written as `preview` and `card` say; nil
    /// drops it. A line left empty goes; a fenced code block is code.
    static func rewriting(_ text: String, preview: (String) -> String?, card: (DesktopCardDirective) -> String?) -> String {
        guard text.contains("::") else { return text }
        // Line endings normalized as the parser does, so its table check sees the same lines.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var fence = CodeFence()
        return lines.indices.compactMap { index -> String? in
            let line = lines[index]
            if fence.isCode(line) { return line }
            // A quoted directive is an example and a table header cell is
            // table text; the chat shows both as written.
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix(">"),
                  let segments = segments(in: line),
                  !isTableHeader(lines, at: index) else { return line }
            let kept = segments.compactMap { segment -> String? in
                switch segment {
                case .text(let value): return value
                case .preview(let file): return preview(file)
                case .desktopCard(let directive): return card(directive)
                }
            }
            return kept.isEmpty ? nil : kept.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// A file's name from its path.
    static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// Whether `lines[index]` heads a Markdown table (the next line is its
    /// rule); MarkdownParser reads tables by the same test.
    static func isTableHeader(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        return lines[index + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$"#, options: .regularExpression) != nil
    }

    private static func attributes(in body: String) -> [String: String] {
        let nsBody = body as NSString
        var attributes: [String: String] = [:]
        for match in attributeExpression.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
            let name = nsBody.substring(with: match.range(at: 1)).lowercased()
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            attributes[name] = valueRange.location != NSNotFound ? nsBody.substring(with: valueRange) : ""
        }
        return attributes
    }

    /// Ranges of code spans: a run of backticks closed by the next run of
    /// the same length, as Markdown reads them (`` `x` `` and ``` `` x `` ```).
    private static func inlineCodeSpans(in line: String) -> [NSRange] {
        guard line.contains("`") else { return [] }
        let nsLine = line as NSString
        var runs: [NSRange] = []
        var index = 0
        while index < nsLine.length {
            guard nsLine.character(at: index) == 0x60 else { index += 1; continue }
            let start = index
            while index < nsLine.length, nsLine.character(at: index) == 0x60 { index += 1 }
            runs.append(NSRange(location: start, length: index - start))
        }
        var spans: [NSRange] = []
        var next = 0
        while next < runs.count {
            let open = runs[next]
            guard let close = runs[(next + 1)...].firstIndex(where: { $0.length == open.length }) else { next += 1; continue }
            spans.append(NSRange(location: open.location, length: NSMaxRange(runs[close]) - open.location))
            next = close + 1
        }
        return spans
    }

    /// Text between directives, dropped when it is only list markers,
    /// emphasis or punctuation a directive left behind ("- ", "**", a
    /// numbered item's "2."), as around a MEDIA: tag.
    private static func appendText(_ text: String, to segments: inout [Segment]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(where: { !$0.isWhitespace && !GatewayMediaTags.leftoverMarkers.contains($0) }) else { return }
        if segments.isEmpty, trimmed.range(of: #"^\d{1,9}[.)]$"#, options: .regularExpression) != nil { return }
        segments.append(.text(trimmed))
    }
}

/// One `::name{…}` directive Conduit doesn't draw itself.
struct DesktopCardDirective: Equatable, Hashable {
    /// The directive's name, `richui` in `::richui{id="…"}`.
    let name: String
    let attributes: [String: String]
    /// The directive as the reply wrote it.
    let source: String

    /// Who made the card, as its plugin calls itself where known.
    var plugin: String {
        name == "richui" ? "hermes-rich-ui" : name
    }

    /// hermes-rich-ui's card id, when the directive names a well-formed
    /// one (its store's `ru-<12 hex>`).
    var richUICardID: String? {
        guard name == "richui", let id = attributes["id"],
              id.range(of: #"^ru-[0-9a-f]{12}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }
}

/// Fenced code blocks, line by line: a directive inside one is code, shown
/// and said as written. The closer is the opener's mark, at least as long,
/// with nothing after it.
struct CodeFence {
    private var open: (mark: Character, length: Int)?

    /// Whether `line` is a fence line or inside a fenced block. Call it
    /// for every line, in order.
    mutating func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let mark = trimmed.first, mark == "`" || mark == "~" {
            let run = trimmed.prefix { $0 == mark }.count
            if let fence = open {
                if mark == fence.mark, run >= fence.length, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) { open = nil }
                return true
            }
            if run >= 3, !(mark == "`" && trimmed.dropFirst(run).contains("`")) {
                open = (mark, run)
                return true
            }
        }
        return open != nil
    }
}
