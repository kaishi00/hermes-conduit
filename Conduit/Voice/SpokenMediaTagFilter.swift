//
//  SpokenMediaTagFilter.swift
//  Conduit
//
//  Keeps Hermes' `MEDIA:<path>` delivery tags and its `[[audio_as_voice]]`
//  style directives out of what a voice says. A reply that attaches a file
//  (Hermes' text_to_speech tool answers with one) would otherwise have its
//  path read aloud: a Local voice call on the farm said
//  "MEDIA:/opt/data/cache/audio/tts_….mp3", and its microphone heard
//  "media." back as the user. The chat keeps the tag and shows the file.
//

import Foundation

/// Streaming: a tag can arrive split anywhere, so from where one may begin
/// to the end of its line is held, then said without the tag
/// (GatewayMediaTags' grammar, as Read Aloud uses).
struct SpokenMediaTagFilter {
    /// The current line from a possible tag on, not released yet.
    private var held = ""

    mutating func reset() {
        held = ""
    }

    /// Speakable text that can be released now.
    mutating func feed(_ text: String) -> String {
        var pending = held + text
        held = ""
        var spoken = ""
        while let newline = pending.firstIndex(of: "\n") {
            spoken += Self.clean(String(pending[..<newline]), ended: true)
            pending = String(pending[pending.index(after: newline)...])
        }
        let cut = Self.heldFrom(pending)
        spoken += String(pending[..<cut])
        held = String(pending[cut...])
        return spoken
    }

    /// Everything still held, at the end of the reply.
    mutating func finish() -> String {
        let rest = Self.clean(held, ended: false)
        held = ""
        return rest
    }

    static func filter(_ text: String) -> String {
        var filter = SpokenMediaTagFilter()
        return filter.feed(text) + filter.finish()
    }

    /// One line (or the start of one held from a tag on), as it's said.
    private static func clean(_ line: String, ended: Bool) -> String {
        let newline = ended ? "\n" : ""
        guard line.range(of: "MEDIA:", options: .caseInsensitive) != nil || line.contains("[[") else {
            return line + newline
        }
        let kept = GatewayMediaTags.removingTags(from: line)
        // A line that was only a tag goes entirely.
        if kept.trimmingCharacters(in: .whitespaces).isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
            return ""
        }
        // What came before the tag was said already, with its own spacing.
        let space = line.first?.isWhitespace == true && kept.first?.isWhitespace != true ? " " : ""
        return space + kept + newline
    }

    /// Where the held part of a line starts: at a tag or directive, or at
    /// what may begin one; the end when there's none.
    private static func heldFrom(_ text: String) -> String.Index {
        var held = text.endIndex
        if let tag = text.range(of: "MEDIA:", options: .caseInsensitive) {
            held = tag.lowerBound
        }
        if let directive = text.range(of: "[["), directive.lowerBound < held {
            held = directive.lowerBound
        }
        // "MEDI" starting a word may become a tag, "[" a directive.
        let keyword = "MEDIA"
        for length in stride(from: min(keyword.count, text.count), through: 1, by: -1) {
            let start = text.index(text.endIndex, offsetBy: -length)
            guard text[start...].uppercased() == keyword.prefix(length) else { continue }
            if start == text.startIndex || !text[text.index(before: start)].isLetter { held = min(held, start) }
            break
        }
        if text.hasSuffix("[") { held = min(held, text.index(before: text.endIndex)) }
        return held
    }
}
