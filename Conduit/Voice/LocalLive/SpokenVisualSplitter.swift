//
//  SpokenVisualSplitter.swift
//  Conduit
//
//  A Local Live reply that writes something better seen than heard (a
//  table, code, an image, links) without showing it with `conduit_show`:
//  those parts are kept out of what the speech server says and collected
//  for the call's screen instead. A link is said by its title and listed on
//  the screen; a bare address isn't said at all. A `MEDIA:` file tag isn't
//  said either (SpokenMediaTagFilter): its file goes on the screen, as the
//  chat shows it. The chat keeps the whole reply.
//

import Foundation

/// Streaming: deltas split anywhere, so a line that may start a block is
/// held until it ends, and a possible link until it closes. Prose is
/// released as it comes.
struct SpokenVisualSplitter {
    /// The Markdown collected for the screen so far.
    private(set) var visual: [String] = []
    /// The files a reply's tags attached, also in `visual`: they go on the
    /// screen even when the model showed its own card.
    private(set) var files: [String] = []

    /// The current line's text not released yet.
    private var pending = ""
    /// Part of the current line was released as speech: it's prose.
    private var lineIsProse = false
    /// The fence an open code block ends with.
    private var fence: String?
    /// The kind of block the last collected line belongs to, so blocks of
    /// different kinds are kept apart on screen.
    private var lastBlock: Block?
    /// What's said, without file tags, whose files go on the screen.
    private var mediaTags = SpokenMediaTagFilter()

    private enum Block { case code, table, image, link, file }

    /// The collected Markdown.
    var visualMarkdown: String { visual.joined(separator: "\n") }

    /// The attached files' Markdown alone.
    var fileMarkdown: String { files.joined(separator: "\n") }

    mutating func reset() {
        self = SpokenVisualSplitter()
    }

    /// Drops what the reply still had to say, when the call says its own
    /// line instead; the files it attached still go on the screen.
    mutating func dropSpeech() {
        _ = finish()
        let files = self.files
        self = SpokenVisualSplitter()
        guard !files.isEmpty else { return }
        visual = files
        self.files = files
        lastBlock = .file
    }

    /// Speakable text that can be released now.
    mutating func feed(_ text: String) -> String {
        pending += text
        var spoken = ""
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending = String(pending[pending.index(after: newline)...])
            spoken += take(line, ended: true)
            lineIsProse = false
        }
        spoken += releaseProse()
        return withoutTags(mediaTags.feed(spoken))
    }

    /// Everything still held, at the end of the reply.
    mutating func finish() -> String {
        var spoken = ""
        if !pending.isEmpty {
            spoken = take(pending, ended: false)
            pending = ""
        }
        lineIsProse = false
        if let open = fence {
            // A block the reply never closed still shows as code.
            visual.append(open)
            fence = nil
        }
        return withoutTags(mediaTags.feed(spoken) + mediaTags.finish())
    }

    /// `spoken`, after the files its tags named went on the screen.
    private mutating func withoutTags(_ spoken: String) -> String {
        let files = mediaTags.takeFiles()
        if !files.isEmpty {
            if lastBlock != nil, lastBlock != .file { visual.append("") }
            lastBlock = .file
            visual.append(contentsOf: files)
            self.files += files
        }
        return spoken
    }

    /// The start of the line in progress, released when it can't open a
    /// block, up to a possible link.
    private mutating func releaseProse() -> String {
        guard fence == nil, !pending.isEmpty else { return "" }
        if !lineIsProse {
            let start = pending.drop { $0 == " " || $0 == "\t" }
            // Too short to tell yet, or the start of a block.
            guard start.count >= 3, Self.blockKind(String(start)) == nil else { return "" }
        }
        let cut = Self.heldFrom(pending)
        guard cut > pending.startIndex else { return "" }
        let released = String(pending[..<cut])
        pending = String(pending[cut...])
        lineIsProse = true
        return speakable(released)
    }

    /// One whole line (or the reply's last): said, or collected.
    private mutating func take(_ line: String, ended: Bool) -> String {
        let newline = ended ? "\n" : ""
        if let open = fence {
            visual.append(line)
            // Only a bare marker closes it; ```bash inside a block is content.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = open.first, trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == marker }) { fence = nil }
            return ""
        }
        if !lineIsProse, let kind = Self.blockKind(line.trimmingCharacters(in: .whitespaces)) {
            if lastBlock != nil, lastBlock != kind || kind == .code { visual.append("") }
            lastBlock = kind
            // A bare address is listed like the links said in a sentence.
            visual.append(kind == .link ? "- " + line.trimmingCharacters(in: .whitespaces) : line)
            // An image of Hermes' own (`![x](MEDIA:…)`) is an attached file too.
            if kind == .image, GatewayMediaTags.soleMediaPath(line) != nil { files.append(line.trimmingCharacters(in: .whitespaces)) }
            if kind == .code {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                fence = String(trimmed.prefix { $0 == "`" || $0 == "~" })
            }
            return ""
        }
        return speakable(line) + newline
    }

    /// What a line starting with `text` is, if it's a block for the screen.
    private static func blockKind(_ text: String) -> Block? {
        if text.hasPrefix("```") || text.hasPrefix("~~~") { return .code }
        if text.hasPrefix("|") { return .table }
        if text.hasPrefix("![") { return .image }
        if (text.hasPrefix("http://") || text.hasPrefix("https://")) && !text.contains(" ") { return .link }
        return nil
    }

    /// Where the held part of a line starts: at an unclosed link or image,
    /// a bare address still being written, or what may begin one; the end
    /// when there's none.
    private static func heldFrom(_ text: String) -> String.Index {
        var held = text.endIndex
        if let open = text.lastIndex(of: "["), !text[open...].contains(")") {
            held = open > text.startIndex && text[text.index(before: open)] == "!" ? text.index(before: open) : open
        }
        // An address inside a link is the link's to hold.
        if let address = text.range(of: "http", options: .backwards),
           address.lowerBound == text.startIndex || text[text.index(before: address.lowerBound)] != "(",
           !text[address.lowerBound...].contains(" "), address.lowerBound < held {
            held = address.lowerBound
        }
        // "ht" starting a word may become an address, "!" an image; a "!"
        // ending a word ("Hello!") is the sentence's.
        let scheme = "https://"
        for length in stride(from: min(scheme.count, text.count), through: 1, by: -1)
        where text.hasSuffix(scheme.prefix(length)) || (length == 1 && text.hasSuffix("!")) {
            let start = text.index(text.endIndex, offsetBy: -length)
            let startsWord = start == text.startIndex || !text[text.index(before: start)].isLetter
            if startsWord { held = min(held, start) }
            break
        }
        return held
    }

    /// `text` as it's said: links by their titles and bare addresses left
    /// out, each listed for the screen.
    private mutating func speakable(_ text: String) -> String {
        let (spoken, found) = Self.withoutLinks(text)
        guard !found.isEmpty else { return text }
        if lastBlock != nil, lastBlock != .link { visual.append("") }
        lastBlock = .link
        visual.append(contentsOf: found.map { "- " + $0 })
        return spoken
    }

    /// `text` with its links said by their titles and its images and bare
    /// addresses taken out, and what was taken, in order.
    /// A `MEDIA:` target is a file, which the tag filter puts on the screen.
    private static let link = try? NSRegularExpression(pattern: #"(!?)\[([^\]]*)\]\((?![^\S\n]*MEDIA:)([^)\s]+)\)"#, options: [])
    // An address's closing full stop or comma is the sentence's.
    private static let bareAddress = try? NSRegularExpression(pattern: #"https?://[^\s)]*[^\s).,;:!?]"#)

    private static func withoutLinks(_ text: String) -> (spoken: String, found: [String]) {
        guard text.contains("](") || text.contains("http") else { return (text, []) }
        var spoken = text
        var found: [String] = []
        if let link = Self.link {
            for match in link.matches(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)).reversed() {
                guard let whole = Range(match.range, in: spoken),
                      let title = Range(match.range(at: 2), in: spoken) else { continue }
                found.insert(String(spoken[whole]), at: 0)
                let isImage = match.range(at: 1).length > 0
                spoken.replaceSubrange(whole, with: isImage ? "" : String(spoken[title]))
            }
        }
        if let bare = Self.bareAddress {
            var addresses: [String] = []
            for match in bare.matches(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)).reversed() {
                guard let whole = Range(match.range, in: spoken) else { continue }
                addresses.insert(String(spoken[whole]), at: 0)
                spoken.removeSubrange(whole)
            }
            found += addresses
        }
        return (spoken, found)
    }
}
