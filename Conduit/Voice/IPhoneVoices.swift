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
    /// too, so a Hong Kong pick speaks Traditional replies). iOS tags some
    /// Cantonese voices zh-HK (Sinji) and newer ones yue (Wing); both are
    /// Traditional unless Simplified is named outright.
    static func languageKey(_ language: String) -> String {
        let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { String($0) }
        let base = (parts.first ?? language).lowercased()
        let rest = parts.dropFirst().map { $0.uppercased() }
        if base == "yue" { return rest.contains("HANS") ? "zh-CN" : "zh-TW" }
        guard base == "zh" else { return base }
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

    static func isCantonese(_ language: String) -> Bool {
        let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.uppercased() }
        // iOS tags its Cantonese voices zh-HK (Sinji) or yue (Wing).
        return parts.first == "YUE" || (parts.first == "ZH" && (parts.contains("HK") || parts.contains("MO")))
    }

    /// A voice's name without the quality iOS adds to Enhanced and Premium
    /// ones ("Wing (Enhanced)", in the iPhone's language), since Settings
    /// names the quality itself, in the app's language.
    static func plainName(_ name: String, quality: Int) -> String {
        guard quality >= 2 else { return name }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("(", ")"), ("（", "）")] where trimmed.hasSuffix(close) {
            guard let start = trimmed.range(of: open, options: .backwards) else { continue }
            let plain = trimmed[..<start.lowerBound].trimmingCharacters(in: .whitespaces)
            if !plain.isEmpty { return plain }
        }
        return name
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

    /// Builds before Cantonese yue voices joined Traditional Chinese saved
    /// their pick under its own key, where no reply ever looked.
    private static let legacyCantoneseKey = "yue"

    static func chosenVoice(for language: String, defaults: UserDefaults = .standard) -> String? {
        let choices = defaults.dictionary(forKey: choicesKey) as? [String: String]
        let key = languageKey(language)
        if let chosen = choices?[key] { return chosen }
        return key == "zh-TW" ? choices?[legacyCantoneseKey] : nil
    }

    /// Saves `identifier` for `language`'s key; nil goes back to automatic.
    static func setChosenVoice(_ identifier: String?, for language: String, defaults: UserDefaults = .standard) {
        var choices = (defaults.dictionary(forKey: choicesKey) as? [String: String]) ?? [:]
        let key = languageKey(language)
        choices[key] = identifier
        if key == "zh-TW" { choices[legacyCantoneseKey] = nil }
        defaults.set(choices, forKey: choicesKey)
    }

    @MainActor private static var cachedInstalled: [IPhoneVoiceOption]?
    @MainActor private static var reading: Task<[IPhoneVoiceOption], Never>?
    @MainActor private static var voicesChanged: NSObjectProtocol?
    /// The voice found for a language and its pick, so a reply's sentences
    /// don't each ask iOS's speech service again. Forgotten with the list.
    @MainActor private static var foundVoices: [String: FoundVoice] = [:]
    /// Counts forgets, so a voice found from a forgotten list isn't kept.
    @MainActor private static var generation = 0

    /// Every voice installed on this iPhone that can speak a reply. Kept
    /// until iOS says the list changed (a voice downloaded or deleted while
    /// Conduit runs is used from the next sentence) or Settings asks again.
    ///
    /// Read off the main thread: iOS's speech service can keep
    /// speechVoices() waiting for many seconds, and on the main thread that
    /// froze Conduit until the watchdog ended it (relay crash reports,
    /// builds 276 to 281). Callers waiting at once share one read.
    @MainActor static func installed() async -> [IPhoneVoiceOption] {
        if voicesChanged == nil {
            voicesChanged = NotificationCenter.default.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { IPhoneVoices.forgetInstalled() }
            }
        }
        if let cachedInstalled { return cachedInstalled }
        let task: Task<[IPhoneVoiceOption], Never>
        if let reading {
            task = reading
        } else {
            nonisolated(unsafe) let read = readInstalled
            task = Task.detached(priority: .userInitiated) { read() }
            reading = task
        }
        let voices = await task.value
        // A list forgotten while it was read is read again next time.
        if reading == task {
            reading = nil
            cachedInstalled = voices
        }
        return voices
    }

    /// Reads the list again on the next use, as when Settings opens or
    /// Conduit comes back from iPhone Settings.
    @MainActor static func forgetInstalled() {
        cachedInstalled = nil
        reading = nil
        foundVoices = [:]
        generation += 1
    }

    /// What installed() reads, off the main thread; tests swap it.
    @MainActor static var readInstalled: () -> [IPhoneVoiceOption] = readSystemVoices

    /// Novelty voices and Personal Voice are left out: one is a joke, the
    /// other the user's own voice.
    private static func readSystemVoices() -> [IPhoneVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            guard !voice.voiceTraits.contains(.isNoveltyVoice),
                  !voice.voiceTraits.contains(.isPersonalVoice) else { return nil }
            return IPhoneVoiceOption(
                id: voice.identifier,
                name: plainName(voice.name, quality: voice.quality.rawValue),
                language: voice.language,
                quality: voice.quality.rawValue
            )
        }
    }

    /// iOS's own default voice for `language`, if it has one, asked off the
    /// main thread like the list.
    @MainActor static func systemDefault(for language: String) async -> String? {
        nonisolated(unsafe) let ask = systemVoice
        return await Task.detached(priority: .userInitiated) { ask(language)?.identifier }.value
    }

    /// iOS's own voice for a language; tests swap it, since the
    /// simulator's speech service can take minutes to answer.
    @MainActor static var systemVoice: (String) -> AVSpeechSynthesisVoice? = { AVSpeechSynthesisVoice(language: $0) }

    /// The voice to speak `language` with: the pick or the best installed
    /// one, or else iOS's own. Every call into iOS's speech service here runs
    /// off the main thread, the voice's own init included.
    @MainActor static func voice(for language: String) async -> AVSpeechSynthesisVoice? {
        let chosen = chosenVoice(for: language)
        let key = "\(language)|\(chosen ?? "")"
        if let found = foundVoices[key] { return found.voice }
        let started = generation
        let installed = await installed()
        let region = Locale.current.region?.identifier
        nonisolated(unsafe) let ask = systemVoice
        let found = await Task.detached(priority: .userInitiated) { () -> FoundVoice in
            let system = ask(language)
            let option = pick(installed, wanted: language, chosen: chosen, region: region, systemDefault: system?.identifier)
            if let option, let voice = AVSpeechSynthesisVoice(identifier: option.id) { return FoundVoice(voice: voice) }
            return FoundVoice(voice: system)
        }.value
        if generation == started { foundVoices[key] = found }
        return found.voice
    }

    /// A voice handed back from the read off the main thread; the voice
    /// isn't changed after it's made.
    private struct FoundVoice: @unchecked Sendable {
        let voice: AVSpeechSynthesisVoice?
    }
}
