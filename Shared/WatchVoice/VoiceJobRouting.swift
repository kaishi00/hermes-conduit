//
//  VoiceJobRouting.swift
//  Conduit and the Conduit Watch app
//
//  Which voice requests run as jobs of their own, on the phone and on the
//  Watch: work the user asked for in the background or in a separate chat,
//  and quick work. Everything else joins the call's chat, the one it was
//  started from or the one its first request made (#1250).
//

import Foundation

enum VoiceJobRouting {
    /// Phrases that keep work out of the chat, as a background job. Matched
    /// as whole words, and only ones that say where the work should run:
    /// "the new chat feature" is a request for this chat.
    static let backgroundPhrases = [
        "in the background",
        "as a background job",
        "in a background job",
        "start a background job",
        "in a separate chat",
        "in a new chat",
        "在后台",
        "后台运行",
        "后台任务",
    ]
    static let politePrefixes = ["please ", "can you ", "could you ", "would you ", "hey, ", "hey ", "ok, ", "ok ", "okay, ", "okay ", "so "]
    static let cjkPolitePrefixes = ["请", "麻烦", "帮我"]
    /// A request led by "quick" ("quick, what's on my calendar") runs as a
    /// fast job on the Voice Jobs model instead of in the chat.
    static let quickWords = ["quick", "quickly"]

    /// Whether `request` asks to run apart: in the background, in a
    /// separate chat, or quickly.
    static func wantsJobOfItsOwn(_ request: String) -> Bool {
        let folded = fold(request)
        return backgroundPhrases.contains { contains(folded, phrase: $0) } || startsQuick(folded: folded)
    }

    static func startsQuick(folded: String) -> Bool {
        var request = Substring(folded.trimmingCharacters(in: .whitespacesAndNewlines))
        while let prefix = politePrefixes.first(where: { request.hasPrefix($0) }) {
            request = request.dropFirst(prefix.count)
        }
        for word in quickWords where request.hasPrefix(word) {
            let rest = request.dropFirst(word.count)
            // A word of its own, with something asked after it.
            guard let next = rest.first, !(next.isLetter || next.isNumber) else { continue }
            // "Quick question, …" is a figure of speech, not a request for a job.
            let asked = rest.drop { !($0.isLetter || $0.isNumber) }
            if asked.hasPrefix("question"),
               asked.dropFirst("question".count).first.map({ !($0.isLetter || $0.isNumber) }) ?? true { continue }
            if !asked.isEmpty { return true }
        }
        var cjk = Substring(folded.filter { !$0.isWhitespace })
        while let prefix = cjkPolitePrefixes.first(where: { cjk.hasPrefix($0) }) {
            cjk = cjk.dropFirst(prefix.count)
        }
        // "快速" or "快" set off from the request: "快，查一下天气". Without
        // the separator it is a word of its own ("快速排序").
        for word in ["快速", "快"] where cjk.hasPrefix(word) {
            let rest = cjk.dropFirst(word.count)
            if let next = rest.first, "，,：:".contains(next), rest.count > 1 { return true }
        }
        return false
    }

    /// Lowercased, with a curly apostrophe made straight and the Turkish
    /// "İ" lowercased to a plain "i" ("İptal" is "iptal", not "i̇ptal").
    static func fold(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "i\u{307}", with: "i")
    }

    /// Whole-word match for Latin phrases ("read" isn't in "thread"); CJK
    /// phrases have no spaces, so a substring is a match.
    static func contains(_ text: String, phrase: String) -> Bool {
        guard phrase.unicodeScalars.allSatisfy({ $0.isASCII }) else { return text.contains(phrase) }
        var searchStart = text.startIndex
        while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let isWordCharacter: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
            if !isWordCharacter(before) && !isWordCharacter(after) { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }
}
