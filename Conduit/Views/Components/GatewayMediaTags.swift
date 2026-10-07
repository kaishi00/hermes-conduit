//
//  GatewayMediaTags.swift
//  Conduit
//
//  Finds Hermes' `MEDIA:<path>` delivery tags in assistant text (#195,
//  #439). Hermes itself turns these into native attachments on other
//  platforms; Conduit renders each one as inline media or a file card.
//
//  The tag grammar mirrors Hermes' own `MEDIA_TAG_CLEANUP_RE`
//  (gateway/platforms/base.py), so whatever Hermes would deliver renders
//  here too: paths with spaces ("/Users/me/My Files/report.pdf"), quoted or
//  backticked paths, `~/` and Windows drive paths, Markdown emphasis around
//  the tag, several tags on one line, and tags inside a sentence. A tag
//  alone on its line whose path has no known extension takes the rest of
//  the line as its path, so any file the agent names still gets a card.
//

import Foundation

enum GatewayMediaTags {
    /// One piece of a line that holds at least one tag.
    enum Segment: Equatable {
        case text(String)
        case media(String)
    }

    /// Hermes' `MEDIA_DELIVERY_EXTS` plus the Apple formats Conduit already
    /// recognised. A tag is matched mid-sentence only when its path ends in
    /// one of these, as on Hermes.
    static let knownExtensions: [String] = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "svg",
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp",
        "mp3", "m2a", "wav", "ogg", "oga", "opus", "m4a", "aac", "flac", "caf", "aiff", "aif",
        "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub",
        "xlsx", "xls", "ods", "csv", "tsv", "json", "xml", "yaml", "yml",
        "kmz", "kml", "geojson", "gpx",
        "pptx", "ppt", "odp", "key", "pages", "numbers",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa",
        "html", "htm"
    ]

    /// Message-wide Hermes directives. They only steer delivery on other
    /// platforms, so Conduit never shows them.
    static let directives = ["[[audio_as_voice]]", "[[as_document]]"]

    private static let cjkTerminators = "（）〈〉《》：，。；！？、\u{201C}\u{201D}\u{2018}\u{2019}【】"

    private static let tagExpression: NSRegularExpression = {
        // Longest first, so "tar" never wins over "tar.gz"'s "gz" or "m4a"
        // over a longer name.
        let alternation = knownExtensions.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"[`"'*_]{0,3}MEDIA:[^\S\n]*"#
            + #"(`[^`\n]+?`|"[^"\n]+?"|'[^'\n]+?'|"#
            + #"(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:"# + alternation + #"))"#
            + #"(?=[\s`"'*_,;:)\]}\["# + cjkTerminators + #"]|MEDIA:|\.(?:\s|$)|$)[`"'*_]{0,3}\.?"#
        // The pattern is a compile-time constant; a failure here is a
        // programming error caught by the parser tests.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// `MEDIA:` followed by an anchored path that runs to the end of the
    /// line, for a tag alone on its line whose path has an unknown (or no)
    /// extension.
    private static let wholeLineExpression = try! NSRegularExpression(
        pattern: #"^[`"'*_]{0,3}MEDIA:[^\S\n]*((?:~/|/|[A-Za-z]:[/\\]).*?)[`"'*_]{0,3}$"#,
        options: [.caseInsensitive]
    )

    /// `![alt](MEDIA:/path)`: a model dressing the tag up as a Markdown
    /// image. The whole line is the one file.
    private static let markdownImageExpression = try! NSRegularExpression(
        pattern: #"^!\[[^\]]*\]\([^\S\n]*MEDIA:[^\S\n]*(.+?)[^\S\n]*\)$"#,
        options: [.caseInsensitive]
    )

    /// Splits `line` into text and media, or returns nil when it holds no
    /// tag (and no directive) so the caller renders it unchanged. An empty
    /// array means the line held only directives and should be dropped.
    static func segments(in line: String) -> [Segment]? {
        guard line.range(of: "MEDIA:", options: .caseInsensitive) != nil
                || directives.contains(where: { line.contains($0) }) else { return nil }
        var source = line
        var removedDirective = false
        for directive in directives where source.contains(directive) {
            source = source.replacingOccurrences(of: directive, with: "")
            removedDirective = true
        }
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        // Hermes masks blockquotes: a quoted tag is an example, not a file.
        if trimmed.hasPrefix(">") { return removedDirective ? [.text(trimmed)] : nil }

        let nsLine = trimmed as NSString
        if let image = markdownImageExpression.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsLine.length)),
           let path = normalizedPath(nsLine.substring(with: image.range(at: 1))) {
            return [.media(path)]
        }
        let codeSpans = inlineCodeSpans(in: trimmed)
        var result: [Segment] = []
        var cursor = 0
        for match in tagExpression.matches(in: trimmed, range: NSRange(location: 0, length: nsLine.length)) {
            let keyword = nsLine.range(of: "MEDIA:", options: .caseInsensitive, range: match.range)
            if keyword.location != NSNotFound, codeSpans.contains(where: { $0.location < keyword.location && keyword.location < NSMaxRange($0) }) {
                continue
            }
            guard let path = normalizedPath(nsLine.substring(with: match.range(at: 1))) else { continue }
            appendText(nsLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &result)
            result.append(.media(path))
            cursor = NSMaxRange(match.range)
        }
        if result.contains(where: { if case .media = $0 { return true } else { return false } }) {
            appendText(nsLine.substring(from: cursor), to: &result)
            return result
        }
        if let path = wholeLinePath(trimmed), !codeSpans.contains(where: { $0.location == 0 }) {
            return [.media(path)]
        }
        if removedDirective {
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        }
        return nil
    }

    /// The path when `line` is exactly one tag and nothing else.
    static func soleMediaPath(_ line: String) -> String? {
        guard let segments = segments(in: line.trimmingCharacters(in: .whitespaces)),
              segments.count == 1, case .media(let path) = segments[0] else { return nil }
        return path
    }

    /// `text` with every tag and directive removed, for places that read a
    /// reply rather than render it (Read Aloud).
    static func removingTags(from text: String) -> String {
        guard text.range(of: "MEDIA:", options: .caseInsensitive) != nil
                || directives.contains(where: { text.contains($0) }) else { return text }
        return text.components(separatedBy: "\n").compactMap { line -> String? in
            guard let segments = segments(in: line) else { return line }
            let kept = segments.compactMap { segment -> String? in
                if case .text(let value) = segment { return value }
                return nil
            }
            return kept.isEmpty ? nil : kept.joined(separator: " ")
        }.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func wholeLinePath(_ line: String) -> String? {
        let nsLine = line as NSString
        guard let match = wholeLineExpression.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else { return nil }
        let raw = nsLine.substring(with: match.range(at: 1))
        // A second tag on the line means two files, not one spaced path.
        guard raw.range(of: "MEDIA:", options: .caseInsensitive) == nil,
              let path = normalizedPath(raw) else { return nil }
        // With spaces, only a name ending in an extension reads as a file;
        // "MEDIA: /tmp/out is where results go" stays prose.
        if path.contains(where: \.isWhitespace) {
            let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            guard name.range(of: #"\.[A-Za-z0-9]{1,10}$"#, options: .regularExpression) != nil else { return nil }
        }
        return path
    }

    /// Strips quoting and trailing punctuation, as Hermes'
    /// `_normalize_media_tag_path` does.
    private static func normalizedPath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.count >= 2, let first = path.first, first == path.last, "`\"'".contains(first) {
            path = String(path.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        while let first = path.first, "`\"'".contains(first) { path.removeFirst() }
        while let last = path.last, "`\"',.;:)}]".contains(last) { path.removeLast() }
        // A path that is only an anchor ("/", "~/") names no file.
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        guard !name.isEmpty, name != "~", !(name.count == 2 && name.hasSuffix(":")) else { return nil }
        return path
    }

    /// Text between tags, dropped when it is only list markers, emphasis or
    /// punctuation left behind by the tag ("- ", "**"). Anything else,
    /// emoji included, is kept.
    private static func appendText(_ raw: String, to result: inout [Segment]) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.contains(where: { !$0.isWhitespace && !leftoverMarkers.contains($0) }) else { return }
        result.append(.text(text))
    }

    private static let leftoverMarkers: Set<Character> = ["-", "+", "*", "_", "~", "`", "'", "\"", "(", ")", "[", "]", "{", "}", ".", ",", ";", ":", "!", "?", ">", "#"]

    /// Ranges of single-backtick inline code, so a tag shown as an example
    /// (`` `MEDIA:/path` ``) stays text.
    private static func inlineCodeSpans(in line: String) -> [NSRange] {
        let nsLine = line as NSString
        var spans: [NSRange] = []
        var open: Int?
        for index in 0..<nsLine.length where nsLine.character(at: index) == 0x60 {
            if let start = open {
                spans.append(NSRange(location: start, length: index - start + 1))
                open = nil
            } else {
                open = index
            }
        }
        return spans
    }
}
