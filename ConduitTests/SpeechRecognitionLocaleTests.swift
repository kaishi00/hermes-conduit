//
//  SpeechRecognitionLocaleTests.swift
//  ConduitTests
//
//  Dictation listens in the person's language, not the app's UI language (#463).
//

import XCTest
@testable import Conduit

final class SpeechRecognitionLocaleTests: XCTestCase {
    private var recognizerLocales: Set<Locale> {
        Set(["en-US", "en-GB", "ru-RU", "zh-CN", "zh-TW", "yue-CN", "fr-FR", "fr-CA"].map { Locale(identifier: $0) })
    }

    func testDictationUsesTheDeviceLanguageOverTheAppLocale() {
        // A Russian iPhone: Conduit has no Russian UI, so its own locale is English.
        let locale = SpeechRecognitionLocale.preferred(
            preferredLanguages: ["ru-RU", "en-US"],
            current: Locale(identifier: "en_RU"),
            supported: recognizerLocales
        )
        XCTAssertEqual(locale.bcp47, "ru-RU")
    }

    func testDictationFillsInTheRegionAndScript() {
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["ru"], current: Locale(identifier: "en"), supported: recognizerLocales).bcp47,
            "ru-RU",
            "a bare language picks its home region"
        )
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["fr"], current: Locale(identifier: "en_CA"), supported: recognizerLocales).bcp47,
            "fr-CA",
            "the device region wins over the language's home region"
        )
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["zh-Hant-HK"], current: Locale(identifier: "en_HK"), supported: recognizerLocales).bcp47,
            "zh-TW",
            "Traditional Chinese never falls into Simplified"
        )
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["zh-Hans-CN"], current: Locale(identifier: "zh_CN"), supported: recognizerLocales).bcp47,
            "zh-CN"
        )
    }

    func testOnDeviceTranscriptionSkipsServerOnlyLanguages() {
        // Russian is only on Apple's servers here; English has a model.
        let locale = SpeechRecognitionLocale.preferred(
            preferredLanguages: ["ru-RU", "en-GB"],
            current: Locale(identifier: "en_RU"),
            supported: recognizerLocales,
            accepts: { $0.language.languageCode != "ru" }
        )
        XCTAssertEqual(locale.bcp47, "en-GB")
    }

    func testCantoneseNeverStandsInForMandarin() {
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["yue-Hans-CN"], current: Locale(identifier: "en_US"), supported: recognizerLocales).bcp47,
            "yue-CN"
        )
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["zh-Hans"], current: Locale(identifier: "en_US"), supported: recognizerLocales).bcp47,
            "zh-CN"
        )
    }

    func testDictationSkipsLanguagesTheRecognizerLacks() {
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["eo", "en-GB"], current: Locale(identifier: "en_US"), supported: recognizerLocales).bcp47,
            "en-GB"
        )
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["eo"], current: Locale(identifier: "en_US"), supported: recognizerLocales).bcp47,
            "en-US",
            "nothing supported falls back to the app's language"
        )
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["eo"], current: Locale(identifier: "en_RU"), supported: recognizerLocales).bcp47,
            "en-US",
            "an app locale the recognizer doesn't list still gets a supported region"
        )
    }
}

private extension Locale {
    /// The identifier with either separator, so tests don't depend on how
    /// Foundation spells it.
    var bcp47: String { identifier.replacingOccurrences(of: "_", with: "-") }
}
