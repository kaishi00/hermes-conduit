//
//  WakePhraseMatcher.swift
//  Conduit
//

import Foundation

/// Finds a bound wake phrase inside a running speech transcript (#174).
/// Pure so the matching rules are unit-testable without audio.
///
/// Latin-script phrases match as whole words in order ("hey fam" matches
/// "ok hey fam what's up" but never "hey family"). Phrases written without
/// word spacing (Chinese, Japanese) match as a contiguous run of characters,
/// because the recognizer does not separate those words with spaces.
enum WakePhraseMatcher {
    /// A phrase needs at least two words (or two characters for scripts
    /// without word spacing): a single common word would fire constantly.
    static func isUsable(_ phrase: String) -> Bool {
        let words = tokens(phrase)
        guard !words.isEmpty else { return false }
        if usesWordSpacing(words) { return words.count >= 2 }
        return words.joined().count >= 2
    }

    static func match(transcript: String, bindings: [WakePhraseBinding]) -> WakePhraseBinding? {
        let transcriptWords = tokens(transcript)
        guard !transcriptWords.isEmpty else { return nil }
        let compactTranscript = transcriptWords.joined()
        var best: (binding: WakePhraseBinding, length: Int)?
        for binding in bindings {
            let phraseWords = tokens(binding.phrase)
            guard isUsable(binding.phrase) else { continue }
            let matched: Bool
            let length: Int
            if usesWordSpacing(phraseWords) {
                matched = containsRun(phraseWords, in: transcriptWords)
                length = phraseWords.count
            } else {
                let compactPhrase = phraseWords.joined()
                matched = compactTranscript.contains(compactPhrase)
                length = compactPhrase.count
            }
            guard matched else { continue }
            // The most specific phrase wins when several profiles match
            // ("hey fam" vs "hey fam work").
            if best == nil || length > best!.length {
                best = (binding, length)
            }
        }
        return best?.binding
    }

    /// Lowercased, accent-folded runs of letters and digits.
    static func tokens(_ text: String) -> [String] {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func usesWordSpacing(_ words: [String]) -> Bool {
        words.allSatisfy { word in
            word.unicodeScalars.allSatisfy { scalar in
                !(0x3040...0x30FF).contains(scalar.value) // Hiragana, Katakana
                    && !(0x3400...0x9FFF).contains(scalar.value) // CJK ideographs
                    && !(0xAC00...0xD7AF).contains(scalar.value) // Hangul syllables
            }
        }
    }

    private static func containsRun(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
