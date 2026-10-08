//
//  SpeechRecognitionLocale.swift
//  Conduit
//

import Foundation
import Speech

/// The language speech recognition should listen for: the one the person
/// speaks, not the one the app's interface runs in. Conduit ships a few UI
/// languages, so on a device set to any other language `Locale.current` is
/// the development region's English and a recognizer built from it
/// transcribes Russian (or French, …) speech as English (#463).
enum SpeechRecognitionLocale {
    /// The first of the person's preferred languages Apple's recognizer
    /// supports, falling back to `current` when none is.
    static func preferred(
        preferredLanguages: [String] = Locale.preferredLanguages,
        current: Locale = .current,
        supported: Set<Locale> = SFSpeechRecognizer.supportedLocales()
    ) -> Locale {
        for identifier in preferredLanguages {
            if let match = bestMatch(for: Locale(identifier: identifier), current: current, supported: supported) {
                return match
            }
        }
        return current
    }

    private static func bestMatch(for wanted: Locale, current: Locale, supported: Set<Locale>) -> Locale? {
        guard let language = wanted.language.languageCode else { return nil }
        let script = maximal(wanted).script
        // Same language and writing system: zh-Hans never picks zh-TW.
        let candidates = supported
            .filter { $0.language.languageCode == language && maximal($0).script == script }
            .sorted { $0.identifier < $1.identifier }
        guard !candidates.isEmpty else { return nil }
        // The person's own region first, then the device region, then the
        // language's home region (ru → ru-RU, en → en-US).
        let regions = [wanted.region, current.region, maximal(wanted).region].compactMap { $0 }
        for region in regions {
            if let match = candidates.first(where: { $0.region == region }) {
                return match
            }
        }
        return candidates.first
    }

    /// The language with its likely script and region filled in
    /// (ru → ru-Cyrl-RU, zh-Hant → zh-Hant-TW).
    private static func maximal(_ locale: Locale) -> Locale.Language {
        Locale.Language(identifier: locale.language.maximalIdentifier)
    }
}
