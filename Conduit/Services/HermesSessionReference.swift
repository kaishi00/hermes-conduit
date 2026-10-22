//
//  HermesSessionReference.swift
//  Conduit
//
//  Hermes' own reference to a chat: `@session:<profile>/<id>`, or
//  `@session:<id>` when the profile can't be named. Hermes' session_search
//  tool tells the agent to write one inline when it points the user at an
//  earlier chat, and Hermes Desktop shows it as a link titled with the
//  chat's name. Conduit does the same: in a chat it becomes a link that opens
//  the chat (`conduit://session/<id>?profile=<profile>`), titled with the
//  chat's name when Conduit lists it; spoken, it is the chat's name, or
//  nothing. Also `[label](@session:…)`, a Markdown link with the reference as
//  its target.
//

import Foundation

struct HermesSessionReference: Equatable {
    let id: String
    let profile: String?

    var appLink: ConduitAppLink { .session(id: id, profile: profile) }

    /// Profile names are lowercase tokens; session ids are plain tokens
    /// (`20261011_142233_ab12cd`). A trailing `.` or `:` ends the sentence,
    /// not the id. Not inside a word, a path or inline code.
    private static let pattern = #"(?<![\w/`@])@session:(?:([A-Za-z0-9][A-Za-z0-9_-]{0,63})/)?([A-Za-z0-9_](?:[A-Za-z0-9_.:-]{0,126}[A-Za-z0-9_])?)"#
    private static let bare = try! NSRegularExpression(pattern: pattern)
    private static let target = #"\(\s*@session:(?:([A-Za-z0-9][A-Za-z0-9_-]{0,63})/)?([A-Za-z0-9_][A-Za-z0-9_.:-]{0,127})\s*\)"#
    private static let markdownTarget = try! NSRegularExpression(pattern: #"\]"# + target)
    /// The whole `[label](@session:…)` link; group 1 is the label.
    private static let markdownLink = try! NSRegularExpression(pattern: #"\[((?:\\.|[^\]\\\n])*)\]"# + target)

    /// The chats Conduit lists, by id, for link titles. Set on the main
    /// actor as the list changes; read wherever a message is parsed.
    private static let titleLock = NSLock()
    nonisolated(unsafe) private static var titles: [String: String] = [:]

    static func updateTitles(_ byID: [String: String]) {
        titleLock.lock()
        titles = byID
        titleLock.unlock()
    }

    static func title(for id: String) -> String? {
        titleLock.lock()
        defer { titleLock.unlock() }
        // One line: a label or a spoken name can't break the message's lines.
        let title = titles[id]?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return title?.isEmpty == false ? title : nil
    }

    /// The titles the references in `text` get now, for a cache of parsed
    /// messages to key on: a chat Conduit learns the name of later re-renders.
    /// Empty when `text` has none.
    static func titleKey(for text: String) -> String {
        guard text.contains("@session:") else { return "" }
        return references(in: text).map { title(for: $0.id) ?? "" }.joined(separator: "\u{1F}")
    }

    /// The references in `text`, in order.
    static func references(in text: String) -> [HermesSessionReference] {
        guard text.contains("@session:") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return bare.matches(in: text, range: range).compactMap { reference(from: $0, in: text) }
    }

    /// A prose line with each reference as a Markdown link to the chat.
    /// Inline code is left as written.
    static func linkingMarkdown(_ line: String) -> String {
        guard line.contains("@session:") else { return line }
        return outsideInlineCode(line) { segment in
            let targets = replacing(markdownTarget, in: segment) { reference in
                "](\(reference.appLink.url.absoluteString))"
            }
            // A reference inside a link's label stays as written: a link
            // can't hold another.
            return outsideLinks(targets) { prose in
                replacing(bare, in: prose) { reference in
                    reference.appLink.markdown(label: title(for: reference.id) ?? AppLocalization.string("Open chat"))
                }
            }
        }
    }

    /// `text` as it is said or shown as plain text: each reference is the
    /// chat's name, or nothing when Conduit doesn't list it.
    static func plain(_ text: String) -> String {
        guard text.contains("@session:") else { return text }
        return outsideInlineCode(text) { segment in
            guard segment.contains("@session:") else { return segment }
            var result = replacing(bare, in: replacingLinks(in: segment)) { reference in title(for: reference.id) ?? "" }
            while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
            for mark in [" .", " ,", " ;", " !", " ?"] {
                result = result.replacingOccurrences(of: mark, with: String(mark.dropFirst()))
            }
            return result
        }
    }

    /// `[label](@session:…)` as its label.
    private static func replacingLinks(in text: String) -> String {
        let matches = markdownLink.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), let label = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += text[label]
            cursor = range.upperBound
        }
        return result + text[cursor...]
    }

    private static func reference(from match: NSTextCheckingResult, in text: String) -> HermesSessionReference? {
        guard let idRange = Range(match.range(at: 2), in: text) else { return nil }
        let profile = Range(match.range(at: 1), in: text).map { String(text[$0]) }
        return HermesSessionReference(id: String(text[idRange]), profile: profile)
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String,
                                  with replacement: (HermesSessionReference) -> String) -> String {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text),
                  let reference = reference(from: match, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += replacement(reference)
            cursor = range.upperBound
        }
        return result + text[cursor...]
    }

    private static let anyLink = try! NSRegularExpression(pattern: #"!?\[(?:\\.|[^\]\\\n])*\]\([^)\n]*\)"#)

    /// Applies `transform` to the parts of `text` outside Markdown links.
    static func outsideLinks(_ text: String, _ transform: (String) -> String) -> String {
        let matches = anyLink.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return transform(text) }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += transform(String(text[cursor..<range.lowerBound]))
            result += text[range]
            cursor = range.upperBound
        }
        return result + transform(String(text[cursor...]))
    }

    /// Applies `transform` to the parts of `line` outside backtick code spans.
    static func outsideInlineCode(_ line: String, _ transform: (String) -> String) -> String {
        guard line.contains("`") else { return transform(line) }
        let parts = line.split(separator: "`", omittingEmptySubsequences: false)
        // An unmatched backtick leaves its tail as prose.
        let closed = parts.count % 2 == 1 ? parts.count : parts.count - 1
        return parts.enumerated().map { index, part in
            index % 2 == 0 || index >= closed ? transform(String(part)) : String(part)
        }.joined(separator: "`")
    }
}

/// Streaming: a reference split across reply deltas is held until it ends,
/// then said as `HermesSessionReference.plain` says it.
struct SessionReferenceSpeechFilter {
    private static let marker = "@session:"
    /// Longer than any reference (a 64-character profile and a 128-character
    /// id): text past it is said as it is, not held.
    private static let longest = 210
    private var pending = ""

    mutating func reset() { pending = "" }

    mutating func feed(_ text: String) -> String {
        pending += text
        guard var hold = holdStart() else {
            let ready = pending
            pending = ""
            return HermesSessionReference.plain(ready)
        }
        // The spaces before it too: a reference said as nothing drops them.
        while hold > pending.startIndex, pending[pending.index(before: hold)] == " " {
            hold = pending.index(before: hold)
        }
        let ready = String(pending[..<hold])
        pending = String(pending[hold...])
        return HermesSessionReference.plain(ready)
    }

    /// Where text that may still become a reference starts: the last "@"
    /// that may grow into one, or a Markdown link still open (its target
    /// may be one), within a short line's reach.
    private func holdStart() -> String.Index? {
        if let at = pending.lastIndex(of: "@") {
            let tail = pending[at...]
            let mayGrow = tail.count < Self.marker.count
                ? Self.marker.hasPrefix(tail)
                : tail.hasPrefix(Self.marker) && tail.count <= Self.longest
                    && !tail.contains(where: { $0.isWhitespace || $0 == ")" })
            if mayGrow {
                let before = pending[..<at]
                let link = before.range(of: #"\[[^\]\n]{0,300}\]\(\s*$"#, options: .regularExpression)
                return link?.lowerBound ?? at
            }
        }
        if let open = pending.lastIndex(of: "["),
           pending[open...].range(of: #"^\[[^\]\n]{0,300}(\](\(\s*)?)?$"#, options: .regularExpression) != nil {
            return open
        }
        return nil
    }

    mutating func finish() -> String {
        let ready = pending
        pending = ""
        return HermesSessionReference.plain(ready)
    }
}
