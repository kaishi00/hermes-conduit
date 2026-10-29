//
//  SpokenTextFilter.swift
//  Conduit
//
//  Drops what a persona writes but nobody should hear: emoji and narrated
//  actions in single asterisks or underscores ("*sets down the gavel*"),
//  and Hermes' `MEDIA:` file tags (SpokenMediaTagFilter).
//  Hermes' own speech cleanup strips the markers but keeps the words, so the
//  action would still be read aloud. Hermes' `@session:<id>` chat links
//  are said as the chat's name (HermesSessionReference). The chat
//  transcript is never filtered.
//

import Foundation

/// Streaming: reply deltas split anywhere, so an opened marker holds text
/// back until it closes, the line ends, or the hold grows past what an
/// action plausibly is (then it is released unchanged).
struct SpokenTextFilter {
    /// An emphasised word or two ("*really*") is speech; an action is longer.
    static let minimumActionWords = 3
    static let maximumHeldCharacters = 400

    private var pending: [Character] = []
    private var sessionReferences = SessionReferenceSpeechFilter()
    private var mediaTags = SpokenMediaTagFilter()
    /// The last character released, so a marker at the start of the next
    /// delta still knows whether it sits inside a word (snake_case).
    private var before: Character?

    mutating func reset() {
        pending = []
        before = nil
        sessionReferences.reset()
        mediaTags.reset()
    }

    /// Speakable text that can be released now.
    mutating func feed(_ text: String) -> String {
        pending.append(contentsOf: sessionReferences.feed(mediaTags.feed(text)))
        return drain(final: false)
    }

    /// Everything still held, at the end of the reply.
    mutating func finish() -> String {
        pending.append(contentsOf: sessionReferences.feed(mediaTags.finish()) + sessionReferences.finish())
        let text = drain(final: true)
        reset()
        return text
    }

    static func filter(_ text: String) -> String {
        var filter = SpokenTextFilter()
        return filter.feed(text) + filter.finish()
    }

    private mutating func drain(final: Bool) -> String {
        var output: [Character] = []
        var remaining = pending[...]
        while let open = Self.firstActionMarker(in: remaining, before: output.last ?? before) {
            let marker = remaining[open]
            output.append(contentsOf: remaining[..<open])
            let afterOpen = remaining[(open + 1)...]
            switch Self.closingMarker(marker, in: afterOpen, final: final) {
            case .close(let close):
                if Self.isAction(afterOpen[..<close]) {
                    output.append(" ")
                } else {
                    output.append(contentsOf: remaining[open...close])
                }
                remaining = afterOpen[(close + 1)...]
                continue
            case .reopen(let reopen):
                // A later marker opens again before this one closes: this
                // one is text, and scanning goes on from that one.
                output.append(contentsOf: remaining[open..<reopen])
                remaining = remaining[reopen...]
                continue
            case .none:
                break
            }
            let held = remaining[open...]
            if final || held.count > Self.maximumHeldCharacters || held.contains(where: \.isNewline) {
                // Never closed: not an action. Release the marker as text
                // and keep scanning after it.
                output.append(marker)
                remaining = afterOpen
                continue
            }
            pending = Array(held)
            return release(output)
        }
        if !final, let last = remaining.last, last == "*" || last == "_" {
            // A trailing run of markers may grow into "**" or open an action
            // with the next delta: hold it with the character before it.
            let run = remaining.reversed().prefix { $0 == last }.count
            let keep = min(run + 1, remaining.count)
            output.append(contentsOf: remaining.dropLast(keep))
            pending = Array(remaining.suffix(keep))
        } else {
            output.append(contentsOf: remaining)
            pending = []
        }
        return release(output)
    }

    private mutating func release(_ output: [Character]) -> String {
        if let last = output.last { before = last }
        return Self.speakable(String(output))
    }

    /// A single `*` or `_` that can open an action: not part of a doubled
    /// run (bold), not followed by a space (as in Markdown, "price * units"
    /// is a multiplication, not an opened action), and only at a word start
    /// (never snake_case or "2*3").
    private static func firstActionMarker(in text: ArraySlice<Character>, before: Character?) -> Int? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "*" || character == "_" else {
                index += 1
                continue
            }
            let previous = index > text.startIndex ? text[index - 1] : before
            let doubled = (index + 1 < text.endIndex && text[index + 1] == character) || previous == character
            if doubled {
                while index < text.endIndex, text[index] == character { index += 1 }
                continue
            }
            if index + 1 < text.endIndex, text[index + 1].isWhitespace {
                index += 1
                continue
            }
            let wordStart = previous.map { !isWordCharacter($0) } ?? true
            if wordStart { return index }
            index += 1
        }
        return nil
    }

    private enum Closing {
        case close(Int)
        case reopen(Int)
        case none
    }

    private static func closingMarker(_ marker: Character, in text: ArraySlice<Character>, final: Bool) -> Closing {
        var index = text.startIndex
        let limit = min(text.endIndex, text.startIndex + maximumHeldCharacters - 1)
        while index < limit {
            let character = text[index]
            if character.isNewline { return .none }
            guard character == marker else {
                index += 1
                continue
            }
            let next = index + 1
            if next < text.endIndex, text[next] == marker {
                index = next + 1
                continue
            }
            // After a space it closes nothing ("width * height"), but it
            // opens again when a word follows it.
            if index > text.startIndex, text[index - 1].isWhitespace {
                if next < text.endIndex, !text[next].isWhitespace { return .reopen(index) }
                index = next
                continue
            }
            // Whether it closes ("**" doesn't, nor one inside a word like
            // "4*5") is only known once the next character arrives.
            if next >= text.endIndex, !final { return .none }
            if next < text.endIndex, isWordCharacter(text[next]),
               index > text.startIndex, isWordCharacter(text[index - 1]) {
                index = next
                continue
            }
            return .close(index)
        }
        return .none
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isAction(_ inner: ArraySlice<Character>) -> Bool {
        String(inner).split(whereSeparator: \.isWhitespace).count >= minimumActionWords
    }

    /// Removes emoji and collapses the double spaces they and dropped
    /// actions leave.
    static func speakable(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isEmojiScalar(scalar) {
            scalars.append(scalar)
        }
        var result = String(scalars)
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200D, 0xFE0E, 0xFE0F, 0x20E3: return true
        case 0x1F3FB...0x1F3FF: return true  // skin tones
        case 0xE0020...0xE007F: return true  // tag sequences (flags)
        default: break
        }
        let properties = scalar.properties
        if properties.isEmojiPresentation { return true }
        // Text-default pictographs (☀, ♥, ✔) read as labels too; digits, #,
        // *, ©, ® and ™ are "emoji" only with a variation selector.
        return properties.isEmoji && scalar.value >= 0x2190
    }
}
