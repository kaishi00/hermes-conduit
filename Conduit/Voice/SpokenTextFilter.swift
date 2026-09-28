//
//  SpokenTextFilter.swift
//  Conduit
//
//  Drops what a persona writes but nobody should hear: emoji and narrated
//  actions in single asterisks or underscores ("*sets down the gavel*").
//  Hermes' own speech cleanup strips the markers but keeps the words, so the
//  action would still be read aloud. The chat transcript is never filtered.
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
    /// The last character released, so a marker at the start of the next
    /// delta still knows whether it sits inside a word (snake_case).
    private var before: Character?

    mutating func reset() {
        pending = []
        before = nil
    }

    /// Speakable text that can be released now.
    mutating func feed(_ text: String) -> String {
        pending.append(contentsOf: text)
        return drain(final: false)
    }

    /// Everything still held, at the end of the reply.
    mutating func finish() -> String {
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
            if let close = Self.closingMarker(marker, in: afterOpen, final: final) {
                if Self.isAction(afterOpen[..<close]) {
                    output.append(" ")
                } else {
                    output.append(contentsOf: remaining[open...close])
                }
                remaining = afterOpen[(close + 1)...]
                continue
            }
            let held = remaining[open...]
            if final || held.contains(where: \.isNewline) || held.count > Self.maximumHeldCharacters {
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
    /// run (bold), and an underscore only at a word start (never snake_case).
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
            let wordStart = previous.map { !isWordCharacter($0) } ?? true
            if character == "*" || wordStart { return index }
            index += 1
        }
        return nil
    }

    private static func closingMarker(_ marker: Character, in text: ArraySlice<Character>, final: Bool) -> Int? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline { return nil }
            guard character == marker else {
                index += 1
                continue
            }
            let next = index + 1
            if next < text.endIndex, text[next] == marker {
                index = next + 1
                continue
            }
            if marker == "_" {
                // Whether "_" ends a word is only known once the next
                // character arrives.
                if next >= text.endIndex, !final { return nil }
                if next < text.endIndex, isWordCharacter(text[next]) {
                    index = next
                    continue
                }
            }
            return index
        }
        return nil
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
