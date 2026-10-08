//
//  VoiceSpokenCommands.swift
//  Conduit and the Conduit Watch app
//
//  The spoken commands a voice call answers itself, such as the end
//  phrases, shared so a Watch call ends on the same goodbye as a call on
//  the iPhone.
//

import Foundation

/// Shared canonicalization and whole-utterance matching for the spoken Voice
/// command phrase lists (Stop, End Conversation). Matching is deliberately
/// conservative: a command fires only when the ENTIRE transcribed utterance
/// equals an ENTIRE configured phrase after normalization — no substring,
/// fuzzy, or semantic matching. Both the transcript and the configured
/// phrases are normalized the same way, so stored phrases need not be
/// pre-trimmed or lowercased.
enum VoiceSpokenCommands {
    /// Built-in spoken commands. Additive across languages BY DESIGN: both
    /// the English and the Simplified Chinese commands are recognized no
    /// matter which App Language the interface uses — commands match the
    /// transcribed utterance, never the UI locale.
    static let defaultStopPhrases = [
        "stop", "stop talking", "be quiet",
        "停止", "别说了", "不要说了",
    ]
    static let defaultEndConversationPhrases = [
        "goodbye", "bye", "end conversation", "that's all",
        "再见", "拜拜", "结束对话", "就这样吧",
    ]

    /// Defaults as originally shipped. The spoken-phrase preferences have
    /// not shipped in a stable release, but development builds may have
    /// persisted the original lists verbatim.
    static let previousDefaultStopPhrases = ["stop", "stop talking", "be quiet"]
    static let previousDefaultEndConversationPhrases = ["goodbye", "bye", "end conversation", "that's all"]

    /// Persistence migration for extended built-ins: a stored list that is
    /// exactly a previous default (the user never customized it) upgrades
    /// to the current defaults, so multilingual commands appear for
    /// existing persisted blobs. A customized list — including one where
    /// the user deliberately removed a built-in — is preserved untouched.
    static func migratedDefaultPhrases(_ stored: [String], previous: [String], current: [String]) -> [String] {
        let canonicalStored = Set(stored.map(canonicalized))
        let canonicalPrevious = Set(previous.map(canonicalized))
        return canonicalStored == canonicalPrevious ? current : stored
    }

    /// The single normalization used on both utterances and configured
    /// phrases: case folding, typographic apostrophe folding (ASR emits
    /// U+2019 for the U+0027 in defaults like "that's all"), and
    /// leading/trailing whitespace and punctuation stripping (internal
    /// punctuation such as the folded apostrophe survives).
    static func canonicalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// True only when the whole utterance matches a whole configured phrase.
    /// An utterance that canonicalizes to empty never matches.
    static func matches(_ utterance: String, phrases: [String]) -> Bool {
        let normalized = canonicalized(utterance)
        guard !normalized.isEmpty else { return false }
        return phrases.contains { canonicalized($0) == normalized }
    }

    /// Spoken courtesies around an end phrase ("okay, goodbye", "bye,
    /// thanks"). Pairs are written as one entry, ahead of their single
    /// words so "for now" goes as a whole.
    private static let leadingCourtesies: [[String]] = [
        ["all", "right"], ["thank", "you"],
        ["ok"], ["okay"], ["alright"], ["thanks"], ["cool"], ["great"], ["well"], ["so"], ["好的"], ["好"], ["谢谢"],
    ]
    private static let trailingCourtesies: [[String]] = [
        ["for", "now"], ["thank", "you"],
        ["thanks"], ["now"], ["then"], ["谢谢"],
    ]

    /// Like `matches`, but for how a live model transcribes speech: inner
    /// spaces and punctuation don't count ("Good bye." is "goodbye"), a
    /// phrase may be repeated ("bye bye"), and courtesies around it are
    /// allowed ("Okay, goodbye.", "Bye, thanks!"). Anything else in the
    /// utterance still means it isn't a command ("goodbye to the old
    /// server" never matches).
    static func matchesSpokenCommand(_ utterance: String, phrases: [String]) -> Bool {
        if matches(utterance, phrases: phrases) { return true }
        var words = commandWords(utterance)
        stripCourtesies(&words)
        let spoken = words.joined()
        guard !spoken.isEmpty else { return false }
        return phrases.contains { phrase in
            var phraseWords = commandWords(phrase)
            stripCourtesies(&phraseWords)
            let key = phraseWords.joined()
            guard !key.isEmpty else { return false }
            return (1...3).contains { spoken == String(repeating: key, count: $0) }
        }
    }

    private static func commandWords(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .subtracting(CharacterSet(charactersIn: "'"))
        return canonicalized(text)
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    private static func stripCourtesies(_ words: inout [String]) {
        var changed = true
        while changed {
            changed = false
            for courtesy in leadingCourtesies where words.count > courtesy.count && Array(words.prefix(courtesy.count)) == courtesy {
                words.removeFirst(courtesy.count)
                changed = true
            }
            for courtesy in trailingCourtesies where words.count > courtesy.count && Array(words.suffix(courtesy.count)) == courtesy {
                words.removeLast(courtesy.count)
                changed = true
            }
        }
    }

    /// Save-time canonicalization for a phrase list: trim each entry, drop
    /// entries that canonicalize to empty, and de-duplicate by the same
    /// canonical form used at runtime — keeping the first occurrence's
    /// trimmed display form so user capitalization survives.
    static func canonicalizedPhraseList(_ phrases: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = canonicalized(trimmed)
            guard !canonical.isEmpty, seen.insert(canonical).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
