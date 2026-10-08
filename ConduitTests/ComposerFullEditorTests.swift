//
//  ComposerFullEditorTests.swift
//  ConduitTests
//
//  When the composer offers its full-screen editor (#335).
//

import XCTest
@testable import Conduit

final class ComposerFullEditorTests: XCTestCase {
    func testShortDraftsHaveNoExpandButton() {
        XCTAssertFalse(ComposerBar.showsFullEditorButton(measuredHeight: ComposerPasteTextView.minimumHeight))
        XCTAssertFalse(ComposerBar.showsFullEditorButton(measuredHeight: 60), "two lines read fine in place")
    }

    func testLongDraftsOfferTheFullEditor() {
        XCTAssertTrue(ComposerBar.showsFullEditorButton(measuredHeight: ComposerBar.fullEditorThreshold))
        XCTAssertTrue(ComposerBar.showsFullEditorButton(measuredHeight: ComposerPasteTextView.maximumHeight))
    }

    func testTheFullEditorTellsDictationFromTyping() {
        let dictated = ComposerDictation.draft(before: "Note:", dictated: "buy milk")
        XCTAssertFalse(ComposerDictation.isTyping(dictated, dictationWrote: dictated), "dictation's own write keeps it going")
        XCTAssertTrue(ComposerDictation.isTyping(dictated + "s", dictationWrote: dictated), "a keystroke after it is typing")
        XCTAssertTrue(ComposerDictation.isTyping("Note:", dictationWrote: nil), "no dictation write to match: every change is typing")
    }

    func testADictationResultNeverWritesOverTyping() {
        XCTAssertTrue(ComposerDictation.draftIsAsDictationLeftIt("Note:", prefix: "Note:", lastWrite: nil), "before its first words")
        let dictated = ComposerDictation.draft(before: "Note:", dictated: "buy")
        XCTAssertTrue(ComposerDictation.draftIsAsDictationLeftIt(dictated, prefix: "Note:", lastWrite: dictated))
        XCTAssertFalse(
            ComposerDictation.draftIsAsDictationLeftIt(dictated + "x", prefix: "Note:", lastWrite: dictated),
            "a keystroke the sheet hasn't reported yet"
        )
        XCTAssertFalse(ComposerDictation.draftIsAsDictationLeftIt("Note: x", prefix: "Note:", lastWrite: nil), "typed before the first words")
    }
}

/// Dictation listens in the person's language, not the app's UI language (#463).
extension ComposerFullEditorTests {
    private var recognizerLocales: Set<Locale> {
        Set(["en-US", "en-GB", "ru-RU", "zh-CN", "zh-TW", "yue-CN", "fr-FR", "fr-CA"].map(Locale.init(identifier:)))
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

    func testDictationSkipsLanguagesTheRecognizerLacks() {
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["eo", "en-GB"], current: Locale(identifier: "en_US"), supported: recognizerLocales).bcp47,
            "en-GB"
        )
        XCTAssertEqual(
            SpeechRecognitionLocale.preferred(preferredLanguages: ["eo"], current: Locale(identifier: "en_US"), supported: recognizerLocales).bcp47,
            "en-US",
            "nothing supported keeps the app's locale"
        )
    }
}

private extension Locale {
    /// The identifier with either separator, so tests don't depend on how
    /// Foundation spells it.
    var bcp47: String { identifier.replacingOccurrences(of: "_", with: "-") }
}
