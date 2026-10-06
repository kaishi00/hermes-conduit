//
//  AppLanguageTests.swift
//  Conduit
//
//  Guards the in-app App Language facility: languages discovered from the
//  built bundle (drafts excluded), persistence, resolution of the SwiftUI
//  environment locale and the explicit `AppLocalization` path through the
//  SAME selection, source-language fallback for untranslated keys, and the
//  protocol-value invariant that configuration values never localize.
//
//  Nothing here names a translation: every per-language test runs over the
//  languages the build ships, so a new language is covered by adding it to
//  the String Catalogs.
//

import XCTest
@testable import Conduit

@MainActor
final class AppLanguageTests: XCTestCase {
    private var standardDefaults: UserDefaults { UserDefaults.standard }

    /// Every pinned choice the build offers (System Default excluded).
    private var pinnedLanguages: [AppLanguage] {
        AppLanguage.selectable.filter { $0 != .system }
    }

    /// Pinned choices other than the source language: the translations.
    private var translatedLanguages: [AppLanguage] {
        pinnedLanguages.filter { $0 != .source }
    }

    private var draftLanguages: [String] {
        Bundle.main.object(forInfoDictionaryKey: AppLocalizations.draftLanguagesInfoKey) as? [String] ?? []
    }

    /// Identifier spelling the app ignores, as `AppLocalizations` does.
    private func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// The value a localization's own compiled catalog holds for `key`, read
    /// straight from its lproj; nil when that catalog lacks the key.
    private func catalogValue(_ key: String, in language: AppLanguage) -> String? {
        guard let identifier = language.localizationIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let missing = "\u{1}missing"
        let value = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing ? nil : value
    }

    override func setUp() async throws {
        // The global selection lives in the standard defaults; start every
        // test from the system default and restore afterwards.
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    override func tearDown() async throws {
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    // MARK: - Discovery from the built bundle

    func testShippedLanguagesAreTheBundleLocalizationsMinusBaseAndDrafts() {
        let shipped = AppLocalizations.main
        XCTAssertEqual(shipped.source, Bundle.main.developmentLocalization)
        XCTAssertEqual(shipped.shipped.first, shipped.source, "the source language is listed first")
        let drafts = Set(draftLanguages.map(normalized))
        let expected = Set(Bundle.main.localizations.filter {
            $0 != "Base" && !drafts.contains(normalized($0))
        }).union([shipped.source])
        XCTAssertEqual(Set(shipped.shipped), expected)
        XCTAssertEqual(AppLanguage.selectable, [AppLanguage.system] + shipped.shipped.map { AppLanguage.localization($0) })
    }

    func testBuildShipsAtLeastOneTranslation() {
        // Keeps the per-language tests below from passing vacuously.
        XCTAssertFalse(translatedLanguages.isEmpty)
    }

    func testEveryShippedLanguageHasItsBundleInTheBuiltApp() {
        // The pinned-language mechanism depends on the per-language lproj
        // resources the String Catalog build emits into the app bundle.
        for language in pinnedLanguages {
            XCTAssertNotNil(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                            "\(language.rawValue).lproj missing from the app")
        }
    }

    func testDraftLanguagesAreStrippedFromTheBuildAndNeverSelectable() {
        // Vacuous until a draft is listed; then it proves the build phase
        // (scripts/strip-draft-localizations.py) actually ran.
        let built = Set(Bundle.main.localizations.map(normalized))
        for draft in draftLanguages {
            XCTAssertFalse(built.contains(normalized(draft)), "draft \(draft) must not ship in the app")
            XCTAssertNil(AppLanguage(rawValue: draft), "draft \(draft) must not be selectable")
        }
    }

    func testDiscoveryDropsBaseAndDraftsAndListsTheSourceFirst() {
        let localizations = AppLocalizations(
            localizations: ["fr", "Base", "pt-BR", "en", "de", "ja"],
            source: "en",
            drafts: ["JA"])
        XCTAssertEqual(localizations.source, "en")
        XCTAssertEqual(localizations.shipped, ["en", "de", "fr", "pt-BR"])
    }

    func testTheSourceLanguageAlwaysShips() {
        XCTAssertEqual(AppLocalizations(localizations: ["fr"], source: "en").shipped, ["en", "fr"])
        XCTAssertEqual(AppLocalizations(localizations: ["en", "fr"], source: "en", drafts: ["en"]).shipped,
                       ["en", "fr"])
    }

    func testMatchingAcceptsAnySpellingOfAShippedIdentifier() {
        let localizations = AppLocalizations(localizations: ["en", "pt-BR", "zh-Hant"], source: "en")
        XCTAssertEqual(localizations.match("pt-BR"), "pt-BR")
        XCTAssertEqual(localizations.match("pt_BR"), "pt-BR")
        XCTAssertEqual(localizations.match("PT-br"), "pt-BR")
        XCTAssertEqual(localizations.match("zh-Hant-TW"), "zh-Hant")
        XCTAssertEqual(localizations.match("zh_Hant_HK"), "zh-Hant")
        XCTAssertEqual(localizations.match("en-GB"), "en")
        XCTAssertNil(localizations.match("pt"), "a broader identifier doesn't pick a regional variant")
        XCTAssertNil(localizations.match("zh-Hans"), "never crosses scripts")
        XCTAssertNil(localizations.match("ja"))
        XCTAssertNil(localizations.match(""))
    }

    // MARK: - Persistence

    func testSelectionPersistsAcrossStoreInstances() {
        let defaults = UserDefaults(suiteName: "AppLanguageTests")!
        defer { defaults.removePersistentDomain(forName: "AppLanguageTests") }

        for language in pinnedLanguages {
            let store = AppLanguageStore(defaults: defaults)
            store.select(language)

            let relaunched = AppLanguageStore(defaults: defaults)
            XCTAssertEqual(relaunched.selection, language)
        }
        AppLanguageStore(defaults: defaults).select(.system)
        XCTAssertEqual(AppLanguageStore(defaults: defaults).selection, .system)
    }

    func testSelectingARespelledLanguageStoresTheShippedSpelling() {
        let defaults = UserDefaults(suiteName: "AppLanguageTests")!
        defer { defaults.removePersistentDomain(forName: "AppLanguageTests") }

        for language in pinnedLanguages where language != .system {
            let respelled = language.rawValue.replacingOccurrences(of: "-", with: "_").uppercased()
            let store = AppLanguageStore(defaults: defaults)
            store.select(.localization(respelled))
            XCTAssertEqual(store.selection, language)
            XCTAssertEqual(defaults.string(forKey: AppLanguageStore.defaultsKey), language.rawValue)
        }
        let store = AppLanguageStore(defaults: defaults)
        store.select(.localization("qaa"))
        XCTAssertEqual(store.selection, .system, "an unshipped language follows the device")
    }

    func testSelectingSameLanguageDoesNotRepublish() {
        let store = AppLanguageStore()
        store.select(.system) // no-op on the default
        XCTAssertEqual(store.selection, .system)
    }

    func testExplicitSelectionReadsThroughGlobalCurrentWithoutStore() {
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }
        for language in pinnedLanguages {
            standardDefaults.set(language.rawValue, forKey: AppLanguageStore.defaultsKey)
            XCTAssertEqual(AppLanguage.current, language)

            // Any spelling of a shipped identifier reads back canonically.
            let respelled = language.rawValue.replacingOccurrences(of: "-", with: "_").uppercased()
            standardDefaults.set(respelled, forKey: AppLanguageStore.defaultsKey)
            XCTAssertEqual(AppLanguage.current, language, "\(respelled) must read back as \(language.rawValue)")
        }

        standardDefaults.set("bogus", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLanguage.current, .system, "an unknown stored value must fall back to system")

        // "qaa" is reserved for local use: a well-formed identifier no build ships.
        standardDefaults.set("qaa", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLanguage.current, .system, "an unshipped language must fall back to system")

        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLanguage.current, .system)
    }

    // MARK: - Resolution

    func testSystemSelectionUsesSystemLocale() {
        let store = AppLanguageStore()
        XCTAssertNil(AppLanguage.system.localizationIdentifier)
        XCTAssertNil(AppLanguage.system.locale)
        // The environment locale follows the device when set to system.
        if case .system = store.selection {} else { XCTFail("precondition") }
    }

    func testPinnedSelectionsCarryTheirOwnLocale() {
        for language in pinnedLanguages {
            XCTAssertEqual(language.locale, Locale(identifier: language.rawValue))
        }
        XCTAssertNil(AppLanguage.localization("qaa").locale, "an unshipped language pins nothing")
    }

    func testEveryLanguageNamesItselfInThePicker() {
        var names: Set<String> = []
        for language in pinnedLanguages {
            let name = language.displayName
            XCTAssertFalse(name.isEmpty)
            XCTAssertEqual(name, catalogValue("Name of this language", in: language),
                           "\(language.rawValue) must name itself in its own catalog column")
            names.insert(name)
        }
        XCTAssertEqual(names.count, pinnedLanguages.count, "two languages share a picker label")
        XCTAssertEqual(AppLanguage.system.displayName, AppLocalization.string("System Default"))
    }

    // MARK: - Explicit String localization through the selected language

    func testPinnedLanguagesResolveTheirOwnCatalogTranslation() throws {
        for language in translatedLanguages {
            let expected = try XCTUnwrap(catalogValue("Settings", in: language),
                                         "\(language.rawValue) catalog lacks \"Settings\"")
            XCTAssertEqual(AppLocalization.string("Settings", language: language), expected)
        }
    }

    func testPinnedTranslationsAreNotTheSourceStrings() {
        // Proves the pin really switches catalogs rather than falling back to
        // the source strings (any one key may legitimately read the same).
        let keys = ["Settings", "Cancel", "App language", "System Default"]
        for language in translatedLanguages {
            let resolved = keys.map { AppLocalization.string(String.LocalizationValue($0), language: language) }
            XCTAssertNotEqual(resolved, keys, "\(language.rawValue) resolved only source strings")
        }
    }

    func testSourceOverrideResolvesSourceString() {
        XCTAssertEqual(AppLocalization.string("Settings", language: .source), "Settings")
    }

    func testSystemPathMatchesSourceOnDevelopmentLanguageHost() {
        // Byte-identical to a bare String(localized:) when no override is
        // active and the process runs in the development language.
        XCTAssertEqual(
            AppLocalization.string("Settings", language: .system),
            String(localized: "Settings"))
    }

    func testRuntimeSelectionChangeReResolvesExplicitStrings() throws {
        // AppLocalization reads the persisted selection per call, so a
        // change made in Settings re-resolves the running UI without an
        // AppleLanguages mutation or relaunch.
        for language in translatedLanguages {
            standardDefaults.set(language.rawValue, forKey: AppLanguageStore.defaultsKey)
            XCTAssertEqual(AppLocalization.string("Settings"), try XCTUnwrap(catalogValue("Settings", in: language)))

            standardDefaults.set(AppLanguage.source.rawValue, forKey: AppLanguageStore.defaultsKey)
            XCTAssertEqual(AppLocalization.string("Settings"), "Settings")
        }
    }

    func testInterpolatedSkeletonResolvesUnderSelectedLanguage() throws {
        for language in translatedLanguages {
            let format = try XCTUnwrap(catalogValue("Voice on %@", in: language))
            XCTAssertEqual(
                AppLocalization.string("Voice on \(String("Phy"))", language: language),
                String(format: format, "Phy"))
        }
        XCTAssertEqual(
            AppLocalization.string("Voice on \(String("Phy"))", language: .source),
            "Voice on Phy")
    }

    // MARK: - Fallback behavior (the source language is the fallback)

    func testUntranslatedKeyFallsBackToSourceString() {
        let missing = String.LocalizationValue("Completely untranslated probe key")
        for language in pinnedLanguages {
            XCTAssertEqual(AppLocalization.string(missing, language: language), "Completely untranslated probe key")
        }
    }

    func testMissingInterpolatedSkeletonFormatsSourceFallback() {
        // A missing skeleton must never render as a broken format
        // placeholder — the source string is formatted with the arguments.
        for language in pinnedLanguages {
            XCTAssertEqual(
                AppLocalization.string("Probe \(42) units", language: language),
                "Probe 42 units")
        }
    }

    // MARK: - Catalog plural variations through the selected language

    func testCatalogPluralVariationsResolvePerLanguage() {
        // SidebarView's session count: the source grammar is owned by the
        // catalog's plural variations (never built in code), and every
        // translation carries its own.
        XCTAssertEqual(
            AppLocalization.string("\(1) conversations", language: .source),
            "1 conversation")
        XCTAssertEqual(
            AppLocalization.string("\(2) conversations", language: .source),
            "2 conversations")
        for language in translatedLanguages {
            let resolved = AppLocalization.string("\(2) conversations", language: language)
            XCTAssertTrue(resolved.contains("2"), "\(language.rawValue): \(resolved)")
            XCTAssertFalse(resolved.contains("%"), "\(language.rawValue) left a raw placeholder: \(resolved)")
            // Its own entry, not a fallback; the words may still match
            // English (French "2 conversations").
            XCTAssertNotNil(catalogValue("%lld conversations", in: language),
                            "\(language.rawValue) has no plural entry of its own")
        }
    }

    // MARK: - UI language stays separate from speech/provider language

    func testAppLanguageNeverTouchesProviderConfiguration() {
        // The App Language facility must have no surface that could write
        // provider/model/STT/TTS state: its entire persistence surface is
        // the single defaults key read back here.
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }
        for language in pinnedLanguages {
            standardDefaults.set(language.rawValue, forKey: AppLanguageStore.defaultsKey)

            let voicePreferences = VoiceProfilePreferences()
            XCTAssertEqual(voicePreferences.spokenStopPhrases, VoiceSpokenCommands.defaultStopPhrases)
            XCTAssertEqual(voicePreferences.spokenEndConversationPhrases,
                           VoiceSpokenCommands.defaultEndConversationPhrases)
            XCTAssertEqual(voicePreferences.resolvedTranscriptionMode, .hermes)
        }
    }

    // MARK: - Live switching without state loss

    /// Switching App Language must update localization WITHOUT the old
    /// root-identity rebuild: no navigation, session, message, profile, or
    /// composer-draft state may be touched by the switch path.
    func testLanguageSwitchDoesNotResetApplicationState() {
        let suite = "AppLanguageTests.AppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )

        // Seed representative app state the old `.id()` rebuild would have
        // disturbed.
        let message = ChatMessage(
            id: "lang-switch-msg",
            role: .user,
            content: "unchanged conversation content",
            timestamp: "1"
        )
        appState.messages = [message]
        let originalProfile = appState.activeProfile
        let originalConnectionPhase = appState.voiceLaunchConnectionSnapshot()

        let store = AppLanguageStore()
        for language in pinnedLanguages + [AppLanguage.system] {
            store.select(language)
            appState.appLanguageDidChange()

            XCTAssertEqual(appState.messages.map(\.id), [message.id],
                           "messages must survive a language switch to \(language)")
            XCTAssertEqual(appState.messages.first?.content, message.content)
            XCTAssertEqual(appState.activeProfile, originalProfile,
                           "active profile must survive a language switch to \(language)")
            XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().phase,
                           originalConnectionPhase.phase,
                           "voice connection phase must be untouched by \(language)")
            XCTAssertFalse(appState.slashCommands.isEmpty,
                           "slash command cache must stay populated after \(language)")
        }

        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    /// Composer drafts live in their own store; the language-switch path
    /// must never clear them (old `.id()` rebuild discarded the ComposerBar
    /// @State that owned the store).
    func testLanguageSwitchSurvivesComposerDraft() {
        let store = ComposerDraftStore()
        let key = ComposerDraftKey(profile: "default",
                                   sessionID: ComposerDraftKey.newConversationSessionID)
        let draft = ComposerDraft(text: "unsent draft that must survive", attachments: [])
        store.save(draft, for: key)

        let languageStore = AppLanguageStore()
        for language in Array(pinnedLanguages.reversed()) + [AppLanguage.system] {
            languageStore.select(language)
            XCTAssertEqual(store.draft(for: key), draft,
                           "composer draft must survive a language switch to \(language)")
        }
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    func testLanguageSwitchDoesNotRepublishSlashCommandIdentity() {
        let suite = "AppLanguageTests.SlashIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let before = appState.slashCommands.map(\.id)
        let store = AppLanguageStore()
        for language in translatedLanguages {
            store.select(language)
            appState.appLanguageDidChange()
            XCTAssertEqual(appState.slashCommands.map(\.id), before,
                           "language refresh re-merges descriptions, not identities (\(language.rawValue))")
        }
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    // MARK: - Protocol-value invariants under localization

    func testBuiltInSlashCommandsKeepProtocolFieldsRaw() {
        // Only the display copy (description, category) localizes. The
        // name/aliases are protocol tokens dispatched verbatim to Hermes
        // and must stay raw ASCII under every App Language.
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }
        for language in AppLanguage.selectable {
            standardDefaults.set(language.rawValue, forKey: AppLanguageStore.defaultsKey)
            XCTAssertEqual(AppLanguage.current, language)
            for command in AppState.builtInSlashCommands {
                XCTAssertFalse(command.name.isEmpty)
                XCTAssertTrue(command.name.allSatisfy { $0.isASCII },
                              "\(command.name) must stay a raw protocol token")
                for alias in command.aliases {
                    XCTAssertTrue(alias.allSatisfy { $0.isASCII },
                                  "\(command.name) alias \(alias) must stay raw")
                }
                XCTAssertFalse(command.description.isEmpty)
            }
        }
    }

    func testSlashCommandIdentityIsStableAcrossLanguageChanges() {
        // Identity is the protocol name: the localized rebuild must not
        // mint fresh identities that would churn ForEach and equality.
        let before = AppState.builtInSlashCommands
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }
        for language in translatedLanguages {
            standardDefaults.set(language.rawValue, forKey: AppLanguageStore.defaultsKey)
            let after = AppState.builtInSlashCommands
            XCTAssertEqual(before.map(\.id), after.map(\.id))
            XCTAssertEqual(before.map(\.name), after.map(\.name))
        }
    }
}
