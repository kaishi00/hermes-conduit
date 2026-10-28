//
//  SpokenMediaTagFilter.swift
//  Conduit
//
//  Keeps Hermes' `MEDIA:<path>` delivery tags and its `[[audio_as_voice]]`
//  style directives out of what a voice says. A reply that attaches a file
//  (Hermes' text_to_speech tool answers with one) would otherwise have its
//  path read aloud: a Local voice call on the farm said
//  "MEDIA:/opt/data/cache/audio/tts_….mp3", and its microphone heard
//  "media." back as the user. The chat keeps the tag and shows the file;
//  Local Live puts it on the call's screen (`files`).
//

import Foundation

/// Streaming: a tag can arrive split anywhere, so from where one may begin
/// (its `[label](` or emphasis included) to the end of its line is held,
/// then the whole line is read with GatewayMediaTags' grammar, as Read
/// Aloud does, and what wasn't said yet is said. Text that can't become a
/// tag ("social media: we shipped") is released as it comes.
struct SpokenMediaTagFilter {
    /// The current line from a possible tag on, not released yet.
    private var held = ""
    /// The current line's text already released.
    private var said = ""
    /// The files taken out of what was said, as tags the call's screen
    /// shows as files. `takeFiles()` empties it.
    private(set) var files: [String] = []

    mutating func reset() {
        self = SpokenMediaTagFilter()
    }

    /// Speakable text that can be released now.
    mutating func feed(_ text: String) -> String {
        var pending = held + text
        held = ""
        var spoken = ""
        while let newline = pending.firstIndex(where: \.isNewline) {
            // A "\r" may be the start of a "\r\n" still to come.
            if pending[newline] == "\r", pending.index(after: newline) == pending.endIndex { break }
            spoken += clean(String(pending[..<newline]), ended: true)
            pending = String(pending[pending.index(after: newline)...])
        }
        let cut = heldFrom(pending)
        let released = String(pending[..<cut])
        said += released
        spoken += released
        held = String(pending[cut...])
        return spoken
    }

    /// Everything still held, at the end of the reply.
    mutating func finish() -> String {
        let rest = clean(held, ended: false)
        held = ""
        return rest
    }

    /// The files found since the last call.
    mutating func takeFiles() -> [String] {
        defer { files = [] }
        return files
    }

    static func filter(_ text: String) -> String {
        var filter = SpokenMediaTagFilter()
        return filter.feed(text) + filter.finish()
    }

    /// The rest of a line (`part`, after what was said of it), as it's said.
    private mutating func clean(_ part: String, ended: Bool) -> String {
        let newline = ended ? "\n" : ""
        let earlier = said
        said = ""
        let line = earlier + part
        guard let segments = GatewayMediaTags.segments(in: line) else { return part + newline }
        var kept: [String] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                kept.append(text)
            case .media(let path, let alt):
                // A link's label is words the reply wrote; the path is not.
                if let alt { kept.append(alt) }
                files.append(path.contains(where: \.isWhitespace) ? "MEDIA:`\(path)`" : "MEDIA:\(path)")
            }
        }
        // A line that was only a tag says nothing; one whose words were
        // said already keeps its end.
        guard !kept.isEmpty else { return earlier.isEmpty ? "" : newline }
        let spoken = String(line.prefix(while: \.isWhitespace)) + kept.joined(separator: " ")
        if spoken.hasPrefix(earlier) { return String(spoken.dropFirst(earlier.count)) + newline }
        // Said differently already: the rest, without its tags.
        let rest = GatewayMediaTags.removingTags(from: part)
        return (part.first?.isWhitespace == true && rest.first?.isWhitespace != true ? " " : "") + rest + newline
    }

    /// Where the held part of a line starts: at a tag or directive, or at
    /// what may still become one; the end when there's none.
    private func heldFrom(_ text: String) -> String.Index {
        var held = text.endIndex
        var search = text.startIndex
        while let tag = text.range(of: "MEDIA:", options: .caseInsensitive, range: search..<text.endIndex) {
            if Self.mayStartPath(text[tag.upperBound...]) {
                held = min(held, Self.opening(of: tag.lowerBound, in: text))
                break
            }
            search = tag.upperBound
        }
        // "MEDI" may become a tag, even glued to a word, as the grammar reads it.
        let keyword = "MEDIA"
        for length in stride(from: min(keyword.count, text.count), through: 1, by: -1) {
            let start = text.index(text.endIndex, offsetBy: -length)
            guard text[start...].uppercased() == keyword.prefix(length) else { continue }
            held = min(held, Self.opening(of: start, in: text))
            break
        }
        // A Markdown link or image still open may wrap a tag, a "!" not
        // ending a word may open an image ("Hello!" is said), and emphasis
        // or a quote may open a tag.
        let range = NSRange(text.startIndex..., in: text)
        if let open = Self.openLink.firstMatch(in: text, range: range), let start = Range(open.range, in: text) {
            held = min(held, start.lowerBound)
        }
        var markup = text.endIndex
        while markup > text.startIndex, text.distance(from: markup, to: text.endIndex) < 3,
              Self.tagOpeners.contains(text[text.index(before: markup)]) {
            markup = text.index(before: markup)
        }
        if markup == text.endIndex, text.last == "!" {
            let bang = text.index(before: text.endIndex)
            if bang == text.startIndex || !(text[text.index(before: bang)].isLetter || text[text.index(before: bang)].isNumber) { markup = bang }
        }
        held = min(held, markup)
        // A directive, written or still being written, goes with its line.
        search = text.startIndex
        while let open = text.range(of: "[[", range: search..<text.endIndex) {
            let rest = text[open.lowerBound...]
            if GatewayMediaTags.directives.contains(where: { $0.hasPrefix(rest) || rest.hasPrefix($0) }) {
                held = min(held, open.lowerBound)
                break
            }
            search = open.upperBound
        }
        // Spaces go with a tag that may follow them, and a line's opening
        // markers ("- ", "**") with one too; with none, it's said as it came.
        if held < text.endIndex {
            while held > text.startIndex, text[text.index(before: held)].isWhitespace { held = text.index(before: held) }
        }
        if said.isEmpty, text[..<held].allSatisfy({ $0.isWhitespace || GatewayMediaTags.leftoverMarkers.contains($0) }) {
            return text.startIndex
        }
        return held
    }

    /// Emphasis or quotes the grammar takes as part of a tag.
    private static let tagOpeners: Set<Character> = ["`", "\"", "'", "*", "_"]

    /// `[label`, `[label]` or `[label](` at the end, which a tag may follow.
    /// A longer `[` run is prose ("arr[0 and more"), said as it comes.
    private static let openLink = try! NSRegularExpression(pattern: #"!?\[[^\[\]]{0,80}(?:\](?:\([^\S\n]*)?)?$"#)
    /// `[label](` just before a tag, which the tag's file takes.
    private static let linkBefore = try! NSRegularExpression(pattern: #"!?\[[^\[\]]*\]\([^\S\n]*$"#)

    /// Where a tag starting at `start` begins with what goes with it: up to
    /// three emphasis or quote characters, and a Markdown link's `[label](`.
    private static func opening(of start: String.Index, in text: String) -> String.Index {
        var begin = start
        while begin > text.startIndex, text.distance(from: begin, to: start) < 3,
              tagOpeners.contains(text[text.index(before: begin)]) {
            begin = text.index(before: begin)
        }
        let before = String(text[..<begin])
        if let link = linkBefore.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)),
           let range = Range(link.range, in: before) {
            return text.index(text.startIndex, offsetBy: before.distance(from: before.startIndex, to: range.lowerBound))
        }
        return begin
    }

    /// Whether what follows `MEDIA:` may still be a path: a quote or
    /// backtick, `/`, `~/` or a drive letter, or nothing yet.
    private static func mayStartPath(_ rest: Substring) -> Bool {
        let rest = rest.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return true }
        if "`\"'/".contains(first) { return true }
        let next = rest.dropFirst().first
        if first == "~" { return next == nil || next == "/" }
        guard first.isASCII, first.isLetter else { return false }
        guard let colon = next else { return true }
        guard colon == ":" else { return false }
        let slash = rest.dropFirst(2).first
        return slash == nil || slash == "/" || slash == "\\"
    }
}
