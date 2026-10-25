//
//  WakeSpeechLocale.swift
//  Conduit
//
//  Which language's recognizer listens for a wake phrase (#1004). Wake
//  phrases are agent names, so a Latin-letter phrase is heard in the app's
//  own locale: a Russian recognizer would write "Hey Hermes" in Cyrillic,
//  which never matches. A phrase in another writing system ("小爱同学" on
//  an English iPhone) needs a recognizer that writes it: the person's own
//  language in that script when they have one, else the script's main
//  language. Pure apart from the recognizer lookup, so the choice is
//  unit-testable.
//

import Foundation

enum WakeSpeechLocale {
    /// The writing systems a phrase can need a recognizer of its own for.
    enum Script: Equatable {
        case han, kana, hangul, cyrillic, greek, arabic, hebrew, thai, devanagari

        /// Locale script codes that write this one.
        fileprivate var localeScripts: Set<String> {
            switch self {
            case .han: return ["Hans", "Hant", "Hani", "Jpan"]
            case .kana: return ["Jpan"]
            case .hangul: return ["Kore", "Hang"]
            case .cyrillic: return ["Cyrl"]
            case .greek: return ["Grek"]
            case .arabic: return ["Arab"]
            case .hebrew: return ["Hebr"]
            case .thai: return ["Thai"]
            case .devanagari: return ["Deva"]
            }
        }

        /// The languages tried when none of the person's own write it.
        fileprivate var defaultLanguages: [String] {
            switch self {
            case .han: return ["zh-Hans", "zh-Hant", "ja"]
            case .kana: return ["ja"]
            case .hangul: return ["ko"]
            case .cyrillic: return ["ru", "uk"]
            case .greek: return ["el"]
            case .arabic: return ["ar"]
            case .hebrew: return ["he"]
            case .thai: return ["th"]
            case .devanagari: return ["hi"]
            }
        }
    }

    /// The script a phrase is written in, or nil for Latin letters and
    /// digits, which the app's locale hears. Kana anywhere makes it
    /// Japanese, even with kanji beside it.
    static func script(of phrase: String) -> Script? {
        var found: Script?
        for scalar in phrase.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
            // Bopomofo spells Chinese, so a Chinese recognizer hears it.
            case 0x3007, 0x3105...0x312F, 0x31A0...0x31BF, 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: found = found ?? .han
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC: found = found ?? .hangul
            case 0x0400...0x052F: found = found ?? .cyrillic
            case 0x0370...0x03FF: found = found ?? .greek
            case 0x0600...0x06FF, 0x0750...0x077F: found = found ?? .arabic
            case 0x0590...0x05FF: found = found ?? .hebrew
            case 0x0E00...0x0E7F: found = found ?? .thai
            case 0x0900...0x097F: found = found ?? .devanagari
            default: continue
            }
        }
        return found
    }

    /// The recognizer locale for `phrase`. `onDevice` says whether a
    /// locale has an on-device model; the first one that does is picked.
    /// Nil when the phrase's script has no such recognizer here.
    static func locale(
        for phrase: String,
        appLocale: Locale = .current,
        preferredLanguages: [String] = Locale.preferredLanguages,
        supported: Set<Locale> = SpeechRecognitionLocale.recognizerLocales,
        onDevice: (Locale) -> Bool = SpeechRecognitionLocale.recognizesOnDevice
    ) -> Locale? {
        // The app's locale hears Latin letters and its own script, when it
        // has an on-device model. Without one, a phrase in another script
        // still tries the other languages that write it.
        guard let script = Self.script(of: phrase) else { return onDevice(appLocale) ? appLocale : nil }
        if writes(script, appLocale.identifier), onDevice(appLocale) { return appLocale }
        let own = preferredLanguages.filter { writes(script, $0) }
        for language in own + script.defaultLanguages {
            let wanted = Locale(identifier: language)
            let match = SpeechRecognitionLocale.preferred(
                preferredLanguages: [language],
                current: wanted,
                supported: supported,
                accepts: onDevice
            )
            // `preferred` falls back to `current` when nothing matched.
            if supported.contains(match), onDevice(match) { return match }
        }
        return nil
    }

    /// Whether the language `identifier` is written in `script`.
    static func writes(_ script: Script, _ identifier: String) -> Bool {
        let language = Locale(identifier: identifier).language
        guard let code = Locale.Language(identifier: language.maximalIdentifier).script?.identifier else {
            return false
        }
        return script.localeScripts.contains(code)
    }

    /// Each recognizer runs the whole time wake listens, so phrases in
    /// more languages than this are heard in the first ones only. Settings'
    /// "three languages at most" says this number.
    static let maximumLanguages = 3

    /// The languages wake listens in for `phrases`, in the phrases' order,
    /// each with its phrases: at most `maximumLanguages`, and none for a
    /// phrase no on-device recognizer here writes.
    static func listening(
        for phrases: [String],
        localeFor: (String) -> Locale? = { WakeSpeechLocale.locale(for: $0) }
    ) -> [(locale: Locale, phrases: [String])] {
        var groups: [(locale: Locale, phrases: [String])] = []
        for phrase in phrases {
            guard let found = localeFor(phrase) else { continue }
            if let index = groups.firstIndex(where: { $0.locale.identifier == found.identifier }) {
                groups[index].phrases.append(phrase)
            } else if groups.count < maximumLanguages {
                groups.append((found, [phrase]))
            }
        }
        return groups
    }

    /// What Settings says beside one of `phrases` that is heard in another
    /// language than the app's, or not heard at all. Nil for a phrase the
    /// app's locale hears.
    static func note(
        for phrase: String,
        among phrases: [String],
        appLocale: Locale = .current,
        localeFor: (String) -> Locale? = { WakeSpeechLocale.locale(for: $0) }
    ) -> (text: String, isUnheard: Bool)? {
        let heard = listening(for: phrases, localeFor: localeFor).contains { $0.phrases.contains(phrase) }
        if !heard, localeFor(phrase) != nil {
            return (AppLocalization.string("“\(phrase)” isn't heard: wake listens in three languages at most."), true)
        }
        let script = Self.script(of: phrase)
        let inAppLocale = script.map { writes($0, appLocale.identifier) } ?? true
        guard let locale = localeFor(phrase) else {
            var language = languageName(appLocale)
            if !inAppLocale, let main = script?.defaultLanguages.first {
                language = languageName(Locale(identifier: main))
            }
            return (AppLocalization.string("“\(phrase)” can't be heard: this iPhone has no on-device speech recognition for \(language)."), true)
        }
        guard locale.identifier != appLocale.identifier else { return nil }
        return (AppLocalization.string("Conduit listens for “\(phrase)” in \(languageName(locale))."), false)
    }

    /// The name of the language a phrase is heard in.
    static func languageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
