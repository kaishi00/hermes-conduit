//
//  IPhoneVoices.swift
//  Conduit
//
//  Which of iOS's own voices speaks a reply on this iPhone (Classic voice,
//  Read Aloud, and a failed Hermes voice's fallback, all through
//  OnDeviceSpeechStream): the one picked in Settings > Voice > Assistant
//  speech for the reply's language, or else the best one installed.
//
//  Siri's own voices aren't offered to apps (AVSpeechSynthesizer never lists
//  them, WWDC20 session 10022), so Premium voices are the closest there is.
//

import AVFoundation
import Foundation

/// One installed iOS voice, as Conduit ranks and lists it.
struct IPhoneVoiceOption: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// BCP 47, as iOS spells it ("en-US").
    let language: String
    /// AVSpeechSynthesisVoiceQuality's raw value: 1 default, 2 Enhanced, 3 Premium.
    let quality: Int

    var isNatural: Bool { quality >= 2 }

    /// iOS 17's Eloquence voices (Eddy, Flo, Reed…), made for screen readers.
    /// They rank like the default voice, so without this they could be picked
    /// over it, and they sound robotic.
    var isScreenReaderVoice: Bool { id.hasPrefix("com.apple.eloquence.") }

    var languageKey: String { IPhoneVoices.languageKey(language) }
}

enum IPhoneVoices {
    /// Picked voice identifiers by language key, for this device: voices are
    /// installed per device, not per profile or dashboard.
    static let choicesKey = "conduit.voice.iPhoneVoices.v1"

    /// "en-US", "en" and "EN_gb" all read as "en": one pick covers a language
    /// in every region. Chinese keeps its scripts apart, since replies are
    /// told apart by script (OnDeviceSpeechStream.language(of:), which tags
    /// a Cantonese one zh-HK):
    /// Simplified (zh-CN) and Traditional (zh-TW, where Cantonese voices go
    /// too, so a Hong Kong pick speaks Traditional replies).
    static func languageKey(_ language: String) -> String {
        let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { String($0) }
        let base = (parts.first ?? language).lowercased()
        guard base == "zh" else { return base }
        let rest = parts.dropFirst().map { $0.uppercased() }
        // A script named outright wins over the region (zh-Hans-HK is Simplified).
        if rest.contains("HANT") { return "zh-TW" }
        if rest.contains("HANS") { return "zh-CN" }
        if rest.contains(where: { ["TW", "HK", "MO"].contains($0) }) { return "zh-TW" }
        return "zh-CN"
    }

    /// The installed voices for `language`'s key.
    static func candidates(_ all: [IPhoneVoiceOption], for language: String) -> [IPhoneVoiceOption] {
        let key = languageKey(language)
        return all.filter { $0.languageKey == key }
    }

    /// The best of `candidates` for `wanted`: anything but a screen-reader
    /// voice, then the same Chinese dialect, then Premium, then Enhanced, then iOS's own default for the
    /// language, then the exact tag (Chinese keys and full tags only), then this iPhone's region. Names
    /// break the last ties so the pick never depends on iOS's list order.
    static func best(
        _ candidates: [IPhoneVoiceOption],
        wanted: String,
        region: String?,
        systemDefault: String?
    ) -> IPhoneVoiceOption? {
        func rank(_ voice: IPhoneVoiceOption) -> [Int] {
            [
                voice.isScreenReaderVoice ? 0 : 1,
                // Cantonese voices share Traditional Chinese's key; they speak
                // its replies only when picked or when nothing else is there.
                isCantonese(voice.language) == isCantonese(wanted) ? 1 : 0,
                voice.quality,
                voice.id == systemDefault ? 1 : 0,
                voice.language.caseInsensitiveCompare(wanted) == .orderedSame ? 1 : 0,
                region.map { voice.language.uppercased().hasSuffix("-" + $0.uppercased()) } == true ? 1 : 0,
            ]
        }
        return candidates.max { left, right in
            let (l, r) = (rank(left), rank(right))
            if l != r { return l.lexicographicallyPrecedes(r) }
            return left.name > right.name
        }
    }

    private static func isCantonese(_ language: String) -> Bool {
        let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.uppercased() }
        // iOS tags its Cantonese voices zh-HK (Sinji), never yue.
        return parts.first == "ZH" && (parts.contains("HK") || parts.contains("MO"))
    }

    /// Whether a pick in Settings changes what's saved. Against the saved
    /// pick, not the one shown: Automatic over a deleted voice still clears
    /// it, so a later download doesn't bring it back.
    static func pickChangesSaved(_ identifier: String?, saved: String?) -> Bool {
        identifier != saved
    }

    /// The picked voice when it's still installed, or else the best one.
    static func pick(
        _ all: [IPhoneVoiceOption],
        wanted: String,
        chosen: String?,
        region: String?,
        systemDefault: String?
    ) -> IPhoneVoiceOption? {
        let candidates = candidates(all, for: wanted)
        if let chosen, let voice = candidates.first(where: { $0.id == chosen }) { return voice }
        return best(candidates, wanted: wanted, region: region, systemDefault: systemDefault)
    }

    // MARK: - This iPhone

    static func chosenVoice(for language: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: choicesKey) as? [String: String])?[languageKey(language)]
    }

    /// Saves `identifier` for `language`'s key; nil goes back to automatic.
    static func setChosenVoice(_ identifier: String?, for language: String, defaults: UserDefaults = .standard) {
        var choices = (defaults.dictionary(forKey: choicesKey) as? [String: String]) ?? [:]
        choices[languageKey(language)] = identifier
        defaults.set(choices, forKey: choicesKey)
    }

    @MainActor private static var cachedInstalled: [IPhoneVoiceOption]?
    @MainActor private static var voicesChanged: NSObjectProtocol?

    /// Every voice installed on this iPhone that can speak a reply. Kept
    /// until iOS says the list changed (a voice downloaded or deleted while
    /// Conduit runs is used from the next sentence) or Settings asks again.
    @MainActor static func installed() -> [IPhoneVoiceOption] {
        if voicesChanged == nil {
            voicesChanged = NotificationCenter.default.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { IPhoneVoices.cachedInstalled = nil }
            }
        }
        if let cachedInstalled { return cachedInstalled }
        let voices = readInstalled()
        cachedInstalled = voices
        return voices
    }

    /// Reads the list again on the next use, as when Settings opens or
    /// Conduit comes back from iPhone Settings.
    @MainActor static func forgetInstalled() {
        cachedInstalled = nil
    }

    /// What installed() reads; tests swap it.
    @MainActor static var readInstalled: () -> [IPhoneVoiceOption] = readSystemVoices

    /// Novelty voices and Personal Voice are left out: one is a joke, the
    /// other the user's own voice.
    private static func readSystemVoices() -> [IPhoneVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            guard !voice.voiceTraits.contains(.isNoveltyVoice),
                  !voice.voiceTraits.contains(.isPersonalVoice) else { return nil }
            return IPhoneVoiceOption(
                id: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: voice.quality.rawValue
            )
        }
    }

    /// iOS's own default voice for `language`, if it has one.
    static func systemDefault(for language: String) -> String? {
        AVSpeechSynthesisVoice(language: language)?.identifier
    }

    @MainActor static func option(for language: String) -> IPhoneVoiceOption? {
        pick(
            installed(),
            wanted: language,
            chosen: chosenVoice(for: language),
            region: Locale.current.region?.identifier,
            systemDefault: systemDefault(for: language)
        )
    }

    /// The voice to speak `language` with.
    @MainActor static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let option = option(for: language), let voice = AVSpeechSynthesisVoice(identifier: option.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: language)
    }
}
