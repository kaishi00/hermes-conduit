//
//  IPhoneVoiceSettingsView.swift
//  Conduit
//
//  Settings > Voice > Assistant speech, when replies are spoken on this
//  iPhone: which iOS voice speaks each language (IPhoneVoices), and a nudge
//  to download a natural one when only basic voices are installed.
//

import AVFoundation
import Combine
import SwiftUI

struct IPhoneVoiceSettingsView: View {
    /// Plays Settings' speaking test after a pick in the app's language,
    /// the language that test speaks.
    var onPickedAppLanguageVoice: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var voices: [IPhoneVoiceOption] = []
    @State private var language = Self.appLanguageKey
    @State private var chosen: String?
    /// Nothing is said about missing voices before the list is read.
    @State private var loaded = false

    private static let automaticID = "automatic"
    private static var appLanguageKey: String { IPhoneVoices.languageKey(OnDeviceSpeechStream.appLanguage ?? "en") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if languageChoices.count > 1 {
                ConduitMenuPicker(value: language, choices: languageChoices, onSelect: { picked in
                    language = picked
                    chosen = IPhoneVoices.chosenVoice(for: picked)
                }) {
                    Text("Language").foregroundStyle(.secondary)
                }
            }
            if !candidates.isEmpty {
                ConduitMenuPicker(value: shownChoice, choices: voiceChoices, onSelect: pick) {
                    Text("Speaks with").foregroundStyle(.secondary)
                }
            }
            if loaded, candidates.isEmpty {
                Text(AppLocalization.string("No voice for \(languageName(language)) is installed on this iPhone yet. To download one, search iPhone Settings for “Voices”."))
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
            } else if loaded, candidates.allSatisfy(\.isScreenReaderVoice) {
                Text(AppLocalization.string("Only a screen-reader voice for \(languageName(language)) is installed on this iPhone, so replies sound robotic. To download a natural one, search iPhone Settings for “Voices”; it shows up here once it's done."))
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
            } else if loaded, !candidates.contains(where: \.isNatural) {
                Text(AppLocalization.string("This iPhone has no Enhanced or Premium voice for \(languageName(language)) yet, so replies use a basic one. To download one, search iPhone Settings for “Voices”; it shows up here once it's done."))
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification).receive(on: RunLoop.main)) { _ in
            reload()
        }
    }

    private func reload() {
        IPhoneVoices.forgetInstalled()
        voices = IPhoneVoices.installed()
        chosen = IPhoneVoices.chosenVoice(for: language)
        loaded = true
    }

    private func pick(_ id: String) {
        let identifier = id == Self.automaticID ? nil : id
        guard IPhoneVoices.pickChangesSaved(identifier, saved: chosen) else { return }
        IPhoneVoices.setChosenVoice(identifier, for: language)
        chosen = identifier
        if language == Self.appLanguageKey { onPickedAppLanguageVoice?() }
    }

    private var candidates: [IPhoneVoiceOption] {
        IPhoneVoices.candidates(voices, for: language)
    }

    /// The pick, while it's still installed.
    private var shownChosen: String? {
        candidates.contains(where: { $0.id == chosen }) ? chosen : nil
    }

    private var shownChoice: String { shownChosen ?? Self.automaticID }

    private var languageChoices: [(id: String, title: String)] {
        var keys = Set(voices.map(\.languageKey))
        keys.insert(language)
        let app = Self.appLanguageKey
        return keys
            .map { (id: $0, title: languageName($0)) }
            .sorted { left, right in
                if (left.id == app) != (right.id == app) { return left.id == app }
                return left.title.localizedCompare(right.title) == .orderedAscending
            }
    }

    private var voiceChoices: [(id: String, title: String)] {
        let automatic = IPhoneVoices.best(
            candidates,
            wanted: language,
            region: Locale.current.region?.identifier,
            systemDefault: IPhoneVoices.systemDefault(for: language)
        )
        let automaticTitle = automatic.map { AppLocalization.string("Automatic (\(title(for: $0)))") }
            ?? AppLocalization.string("Automatic")
        let regions = Set(candidates.map(\.language))
        // Screen-reader voices are listed only when nothing else is installed.
        let offered = candidates.contains(where: { !$0.isScreenReaderVoice })
            ? candidates.filter { !$0.isScreenReaderVoice || $0.id == shownChosen }
            : candidates
        let listed = offered.sorted { left, right in
            if left.quality != right.quality { return left.quality > right.quality }
            return left.name.localizedCompare(right.name) == .orderedAscending
        }
        return [(id: Self.automaticID, title: automaticTitle)]
            + listed.map { (id: $0.id, title: title(for: $0, showsRegion: regions.count > 1)) }
    }

    private func title(for voice: IPhoneVoiceOption, showsRegion: Bool = false) -> String {
        var name = voice.name
        if showsRegion, let region = Locale(identifier: voice.language).region?.identifier,
           let regionName = displayLocale.localizedString(forRegionCode: region) {
            name += " · " + regionName
        }
        switch voice.quality {
        case 3...: return AppLocalization.string("\(name) (Premium)")
        case 2: return AppLocalization.string("\(name) (Enhanced)")
        default: return name
        }
    }

    private var displayLocale: Locale { AppLanguage.current.locale ?? .current }

    private func languageName(_ key: String) -> String {
        // Chinese is split by script, the way its keys are.
        let identifier = ["zh-CN": "zh-Hans", "zh-TW": "zh-Hant"][key] ?? key
        return displayLocale.localizedString(forIdentifier: identifier) ?? key
    }
}
