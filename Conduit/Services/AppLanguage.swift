//
//  AppLanguage.swift
//  Conduit
//
//  In-app App Language: a Conduit-only UI language preference that both
//  localization halves resolve through —
//
//    AppLanguage → selected Locale ─┬─ SwiftUI environment locale
//                                   │  (Text("…") literal keys)
//                                   └─ AppLocalization.string(…)
//                                      (explicit String-context copy)
//
//  Deliberately independent of speech/provider language configuration
//  (STT locale, TTS voice, Hermes/model language): those are protocol and
//  provider values and are never touched by this preference. Server-facing
//  configuration values are likewise never routed through localization.
//

import Foundation
import SwiftUI

/// The Conduit UI language. `.system` follows the device languages; the
/// explicit cases pin one localization for Conduit's interface only.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Language code backing the selection; nil when following the system.
    var languageCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        }
    }

    /// Locale driving resolution and formatting (plural rules, digits) for
    /// the pinned selection; nil when following the system.
    var locale: Locale? {
        languageCode.map { Locale(identifier: $0) }
    }

    /// The persisted selection, readable from any isolation domain. Reads
    /// through to `UserDefaults` so `AppLocalization.string` stays
    /// nonisolated and always reflects the newest selection without routing
    /// through the MainActor store.
    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: AppLanguageStore.defaultsKey),
              let language = AppLanguage(rawValue: raw) else { return .system }
        return language
    }
}

/// Observable holder for the App Language preference. Views that build
/// user-facing copy through `AppLocalization.string` observe the shared
/// store (`@ObservedObject var appLanguage = AppLanguageStore.shared`),
/// so a selection change re-renders exactly those views; the root sets
/// `.environment(\.locale, resolvedLocale)` so literal-key SwiftUI text
/// re-renders reactively as well. No view identity is ever replaced.
/// Resolution itself (`AppLanguage.current`) never depends on the store.
@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()
    static let defaultsKey = "conduit.appLanguage"

    @Published private(set) var selection: AppLanguage

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = {
            guard let raw = defaults.string(forKey: AppLanguageStore.defaultsKey),
                  let language = AppLanguage(rawValue: raw) else { return .system }
            return language
        }()
    }

    /// Persists the selection globally for Conduit (not profile-scoped) and
    /// publishes it, which immediately re-renders the running UI.
    func select(_ language: AppLanguage) {
        guard language != selection else { return }
        selection = language
        defaults.set(language.rawValue, forKey: Self.defaultsKey)
    }

    /// Locale for the SwiftUI environment so `Text("…")` literal keys resolve
    /// through the same selection as `AppLocalization`.
    var resolvedLocale: Locale {
        selection.locale ?? .autoupdatingCurrent
    }
}

/// Explicit localized-String creation that follows the in-app App Language.
/// `String(localized:)` resolves against the device languages, so every
/// explicit site in the app target routes through here instead; a pinned
/// language then re-resolves at use time.
///
/// Fallback contract: keys are the English source strings. A key missing
/// from the selected localization's catalog resolves to the key itself —
/// the English source, formatted with the call's arguments — so an
/// untranslated value can never surface as a key-looking token or an empty
/// label. (The l10n coverage checker additionally rejects catalogs whose
/// zh-Hans units are missing, empty, or untranslated.)
enum AppLocalization {
    /// App-bundle localization for a pinned language. Nil when following the
    /// system (the plain `String(localized:)` path) or when the pinned
    /// language's bundle is absent from the built app.
    nonisolated private static func bundle(for language: AppLanguage) -> Bundle? {
        guard language.languageCode != nil else { return nil }
        return languageBundles[language]
    }

    /// Bundles are immutable once loaded; one cache, built lazily and
    /// thread-safely by Swift's `static let` initialization.
    nonisolated private static let languageBundles: [AppLanguage: Bundle] = {
        var bundles: [AppLanguage: Bundle] = [:]
        for language in AppLanguage.allCases {
            guard let code = language.languageCode,
                  let path = Bundle.main.path(forResource: code, ofType: "lproj") else { continue }
            bundles[language] = Bundle(path: path)
        }
        return bundles
    }()

    nonisolated static func string(
        _ keyAndValue: String.LocalizationValue,
        table: String? = nil,
        language: AppLanguage? = nil
    ) -> String {
        let selected = language ?? AppLanguage.current
        guard let bundle = bundle(for: selected), let locale = selected.locale else {
            return String(localized: keyAndValue, table: table, locale: .current)
        }
        return String(localized: keyAndValue, table: table, bundle: bundle, locale: locale)
    }
}
