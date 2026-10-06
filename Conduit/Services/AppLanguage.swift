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
//  The languages are data, not code: `AppLocalizations` reads them from the
//  built app bundle (one lproj per String Catalog language), so adding a
//  language is a catalog change. scripts/check-l10n-coverage.py holds every
//  shipped language to complete, placeholder-correct coverage, and the
//  drafts Info.plist lists under `ConduitDraftLanguages` are stripped from
//  the build and never offered (see docs/LOCALIZATION.md).
//
//  Deliberately independent of speech/provider language configuration
//  (STT locale, TTS voice, Hermes/model language): those are protocol and
//  provider values and are never touched by this preference. Server-facing
//  configuration values are likewise never routed through localization.
//

import Foundation
import SwiftUI

/// The UI localizations this build ships, read from the app bundle instead
/// of enumerated in code: every lproj the String Catalogs compiled, except
/// `Base` and the drafts Info.plist lists under `ConduitDraftLanguages`. The
/// build already strips draft lprojs (scripts/strip-draft-localizations.py);
/// the filter here keeps a draft out of the picker even if one slips in.
struct AppLocalizations: Equatable, Sendable {
    /// Info.plist array of localization identifiers whose translation is
    /// still in progress.
    static let draftLanguagesInfoKey = "ConduitDraftLanguages"

    /// The development localization: catalog keys are its strings, and every
    /// other language falls back to it.
    let source: String
    /// Every shipped localization identifier, spelled as its lproj is: the
    /// source first, then the rest in identifier order.
    let shipped: [String]

    init(localizations: [String], source: String, drafts: [String] = []) {
        let excluded = Set((drafts + ["Base"]).map(Self.normalized))
        var seen: Set<String> = [Self.normalized(source)]
        var others: [String] = []
        for identifier in localizations {
            let key = Self.normalized(identifier)
            guard !excluded.contains(key), seen.insert(key).inserted else { continue }
            others.append(identifier)
        }
        self.source = source
        shipped = [source] + others.sorted()
    }

    init(bundle: Bundle) {
        self.init(
            localizations: bundle.localizations,
            source: bundle.developmentLocalization ?? bundle.localizations.first ?? "en",
            drafts: bundle.object(forInfoDictionaryKey: Self.draftLanguagesInfoKey) as? [String] ?? []
        )
    }

    /// The running app's localizations; fixed for the life of the process.
    static let main = AppLocalizations(bundle: .main)

    /// The shipped localization for an arbitrary locale identifier, or nil
    /// when none ships. Case and `_`/`-` spelling don't matter, and a more
    /// specific identifier falls back by dropping trailing subtags (RFC 4647
    /// lookup): "zh_Hans", "zh-Hans-CN" and "ZH-hans" all find "zh-Hans",
    /// "en-GB" finds "en". It never crosses to another language or script.
    func match(_ identifier: String) -> String? {
        if shipped.contains(identifier) { return identifier }
        var candidate = Self.normalized(identifier)
        while !candidate.isEmpty {
            if let hit = shipped.first(where: { Self.normalized($0) == candidate }) {
                return hit
            }
            guard let cut = candidate.lastIndex(of: "-") else { return nil }
            candidate = String(candidate[..<cut])
        }
        return nil
    }

    private static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

/// The Conduit UI language. `.system` follows the device languages; a
/// `.localization` pins one shipped localization (by identifier) for
/// Conduit's interface only.
enum AppLanguage: Hashable, Identifiable {
    case system
    case localization(String)

    private static let systemRawValue = "system"

    /// Persisted form: "system", or the localization identifier.
    var rawValue: String {
        switch self {
        case .system: return Self.systemRawValue
        case .localization(let identifier): return identifier
        }
    }

    /// Parses a persisted value. A localization this build doesn't ship (a
    /// draft, or one since removed) is nil, so the stored choice falls back
    /// to System Default instead of pinning a language that can't resolve.
    init?(rawValue: String) {
        if rawValue == Self.systemRawValue {
            self = .system
        } else if let identifier = AppLocalizations.main.match(rawValue) {
            self = .localization(identifier)
        } else {
            return nil
        }
    }

    var id: String { rawValue }

    /// Every choice the picker offers: System Default, then each shipped
    /// localization.
    static let selectable: [AppLanguage] =
        [AppLanguage.system] + AppLocalizations.main.shipped.map { AppLanguage.localization($0) }

    /// The source localization (the catalogs' development language).
    static var source: AppLanguage { .localization(AppLocalizations.main.source) }

    /// Shipped localization identifier backing the selection; nil when
    /// following the system, or when the identifier doesn't ship.
    var localizationIdentifier: String? {
        guard case .localization(let identifier) = self else { return nil }
        return AppLocalizations.main.match(identifier)
    }

    /// Locale driving resolution and formatting (plural rules, digits) for
    /// the pinned selection; nil when following the system.
    var locale: Locale? {
        localizationIdentifier.map { Locale(identifier: $0) }
    }

    /// Picker label. Each localization names itself in its own catalog
    /// column ("Name of this language"), so a new language brings its own
    /// label, and it reads the same whatever the current UI language is.
    var displayName: String {
        switch self {
        case .system:
            return AppLocalization.string("System Default")
        case .localization(let identifier):
            if localizationIdentifier != nil {
                // A missing entry resolves to the key itself (the fallback
                // contract above AppLocalization), so getting the key back
                // means the language hasn't named itself yet.
                let name = AppLocalization.string("Name of this language", language: self)
                if name != "Name of this language" { return name }
            }
            return Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
        }
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
        // Store the shipped spelling ("zh_hans" becomes "zh-Hans") so the
        // picker's tags match the selection; an unshipped one follows the device.
        let language = AppLanguage(rawValue: language.rawValue) ?? .system
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
/// Fallback contract: keys are the source-language strings. A key missing
/// from the selected localization's catalog resolves to the key itself —
/// the source string, formatted with the call's arguments — so an
/// untranslated value can never surface as a key-looking token or an empty
/// label. (The l10n coverage checker additionally rejects catalogs where a
/// shipped language's units are missing, empty, or untranslated.)
enum AppLocalization {
    /// App-bundle localization for a pinned language. Nil when following the
    /// system (the plain `String(localized:)` path) or when the pinned
    /// language's bundle is absent from the built app.
    nonisolated private static func bundle(for identifier: String) -> Bundle? {
        localizationBundles[identifier]
    }

    /// Bundles are immutable once loaded; one cache per shipped localization,
    /// built lazily and thread-safely by Swift's `static let` initialization.
    nonisolated private static let localizationBundles: [String: Bundle] = {
        var bundles: [String: Bundle] = [:]
        for identifier in AppLocalizations.main.shipped {
            guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            bundles[identifier] = bundle
        }
        return bundles
    }()

    nonisolated static func string(
        _ keyAndValue: String.LocalizationValue,
        table: String? = nil,
        language: AppLanguage? = nil
    ) -> String {
        let selected = language ?? AppLanguage.current
        guard let identifier = selected.localizationIdentifier,
              let bundle = bundle(for: identifier) else {
            return String(localized: keyAndValue, table: table, locale: .current)
        }
        return String(localized: keyAndValue, table: table, bundle: bundle, locale: Locale(identifier: identifier))
    }
}
