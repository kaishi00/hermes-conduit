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
    /// The recognizer's languages only change with an OS update.
    static let recognizerLocales = SFSpeechRecognizer.supportedLocales()

    /// The first of the person's preferred languages Apple's recognizer
    /// supports (and `accepts`, say on-device recognition), then the app's
    /// own language, falling back to `current` itself when neither is.
    static func preferred(
        preferredLanguages: [String] = Locale.preferredLanguages,
        current: Locale = .current,
        supported: Set<Locale> = recognizerLocales,
        accepts: (Locale) -> Bool = { _ in true }
    ) -> Locale {
        let languages = preferredLanguages.map { Locale(identifier: $0) } + [current]
        for wanted in languages {
            if let match = bestMatch(for: wanted, current: current, supported: supported, accepts: accepts) {
                return match
            }
        }
        return current
    }

    /// A locale whose language has an on-device model, so audio stays on
    /// the iPhone.
    static func recognizesOnDevice(_ locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

    private static func bestMatch(
        for wanted: Locale,
        current: Locale,
        supported: Set<Locale>,
        accepts: (Locale) -> Bool
    ) -> Locale? {
        guard let language = wanted.language.languageCode else { return nil }
        let script = maximal(wanted).script
        // Same language and writing system: zh-Hans never picks zh-TW. An
        // unknown script matches any.
        let candidates = supported
            .filter { candidate in
                candidate.language.languageCode == language
                    && (script == nil || maximal(candidate).script == nil || maximal(candidate).script == script)
            }
            .filter(accepts)
            .sorted { $0.identifier < $1.identifier }
        guard !candidates.isEmpty else { return nil }
        // The person's own region first, then the device region, then the
        // language's home region (ru → ru-RU, en → en-US).
        let home = Locale(identifier: script.map { "\(language.identifier)-\($0.identifier)" } ?? language.identifier)
        let regions = [wanted.region, current.region, maximal(home).region].compactMap { $0 }
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
