//
//  DictationEngine.swift
//  Conduit
//
//  Which speech recognizer the composer's dictate button uses, and the
//  person's own words (names, companies, jargon) every engine is told to
//  expect. Both are device-only preferences.
//

import Foundation
import Speech

enum DictationEngine: String, CaseIterable, Identifiable {
    /// Apple's speech recognizer, on the device when the language allows.
    case apple
    /// Apple's newer on-device speech model (iOS 26).
    case appleSpeechAnalyzer
    /// The speech-to-text the connected Hermes uses.
    case hermes

    static let preferenceKey = "conduit.dictation.engine"

    var id: String { rawValue }

    var title: String {
        switch self {
        // Names, the same in every language.
        case .apple: return "Apple"
        case .appleSpeechAnalyzer: return AppLocalization.string("Apple (new model)")
        case .hermes: return "Hermes"
        }
    }

    var summary: String {
        switch self {
        case .apple:
            return AppLocalization.string("Apple's dictation, on this iPhone when your language allows. Words appear as you speak.")
        case .appleSpeechAnalyzer:
            return AppLocalization.string("Apple's newer speech model, on this iPhone. Better with long sentences, though it may not use your custom words. The first use may download it.")
        case .hermes:
            return AppLocalization.string("The speech to text your Hermes uses, such as Whisper. Audio goes to your Hermes. Words appear as you speak when Hermes streams them, otherwise when you stop.")
        }
    }

    /// The engines this device can run.
    static var available: [DictationEngine] {
        allCases.filter(\.isSupportedOnThisDevice)
    }

    var isSupportedOnThisDevice: Bool {
        switch self {
        case .apple, .hermes: return true
        case .appleSpeechAnalyzer:
            if #available(iOS 26.0, *) { return SpeechTranscriber.isAvailable }
            return false
        }
    }

    /// The stored choice. Anything missing, unknown or not supported on
    /// this device reads as Apple.
    static func current(defaults: UserDefaults = .standard) -> DictationEngine {
        resolved(defaults.string(forKey: preferenceKey), isSupported: { $0.isSupportedOnThisDevice })
    }

    static func resolved(_ raw: String?, isSupported: (DictationEngine) -> Bool) -> DictationEngine {
        guard let raw, let engine = DictationEngine(rawValue: raw), isSupported(engine) else { return .apple }
        return engine
    }
}

/// Words dictation should expect: names, companies, product names. Apple's
/// recognizers take them as contextual strings.
enum DictationCustomWords {
    static let preferenceKey = "conduit.dictation.customWords"
    /// Apple suggests keeping contextual strings to about a hundred.
    static let maximumCount = 100
    static let maximumLength = 60

    static func load(defaults: UserDefaults = .standard) -> [String] {
        canonicalized(defaults.stringArray(forKey: preferenceKey) ?? [])
    }

    static func save(_ words: [String], defaults: UserDefaults = .standard) {
        let words = canonicalized(words)
        if words.isEmpty {
            defaults.removeObject(forKey: preferenceKey)
        } else {
            defaults.set(words, forKey: preferenceKey)
        }
    }

    /// One entry as it is kept: spaces collapsed, ends trimmed, capitals
    /// left alone (they are how the word should be written).
    static func canonicalized(_ word: String) -> String {
        let collapsed = word
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(maximumLength))
    }

    /// Entries in order, empty ones dropped, and a repeat (ignoring case)
    /// keeping the first spelling.
    static func canonicalized(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            let word = canonicalized(word)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
            if result.count == maximumCount { break }
        }
        return result
    }
}
