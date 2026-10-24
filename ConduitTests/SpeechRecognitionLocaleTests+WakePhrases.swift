//
//  SpeechRecognitionLocaleTests+WakePhrases.swift
//  ConduitTests
//
//  A wake phrase in another writing system is heard by a recognizer for a
//  language that writes it (#1004).
//

import XCTest
@testable import Conduit

extension SpeechRecognitionLocaleTests {
    private var wakeLocales: Set<Locale> {
        Set(["en-US", "ru-RU", "zh-CN", "zh-TW", "ja-JP", "ko-KR"].map { Locale(identifier: $0) })
    }

    private func wakeLocale(
        _ phrase: String,
        app: String = "en_US",
        preferred: [String] = ["en-US"],
        onDevice: @escaping (Locale) -> Bool = { _ in true }
    ) -> String? {
        WakeSpeechLocale.locale(
            for: phrase,
            appLocale: Locale(identifier: app),
            preferredLanguages: preferred,
            supported: wakeLocales,
            onDevice: onDevice
        )?.identifier.replacingOccurrences(of: "_", with: "-")
    }

    func testWakePhraseScripts() {
        XCTAssertNil(WakeSpeechLocale.script(of: "Hey Hermes"))
        XCTAssertNil(WakeSpeechLocale.script(of: "Hola Zoë 2"))
        XCTAssertEqual(WakeSpeechLocale.script(of: "小爱同学"), .han)
        XCTAssertEqual(WakeSpeechLocale.script(of: "ねえ花子"), .kana)
        XCTAssertEqual(WakeSpeechLocale.script(of: "안녕 헤르메스"), .hangul)
        XCTAssertEqual(WakeSpeechLocale.script(of: "Привет Гермес"), .cyrillic)
    }

    func testLatinWakePhrasesStayInTheAppLocale() {
        // A Russian recognizer would write "Hey Hermes" in Cyrillic.
        XCTAssertEqual(wakeLocale("Hey Hermes", app: "en_US", preferred: ["ru-RU", "en-US"]), "en-US")
        XCTAssertEqual(wakeLocale("Hey Hermes", app: "zh_CN", preferred: ["zh-Hans-CN"]), "zh-CN")
    }

    func testAChineseWakePhraseOnAnEnglishIPhoneIsHeardInChinese() {
        XCTAssertEqual(wakeLocale("小爱同学"), "zh-CN")
        // The person's own Han-script language comes first.
        XCTAssertEqual(wakeLocale("小爱同学", preferred: ["en-US", "zh-Hant-TW"]), "zh-TW")
        XCTAssertEqual(wakeLocale("花子さん"), "ja-JP")
        XCTAssertEqual(wakeLocale("안녕 헤르메스"), "ko-KR")
        XCTAssertEqual(wakeLocale("Привет Гермес"), "ru-RU")
    }

    func testAWakePhraseInTheAppsOwnScriptKeepsTheAppLocale() {
        XCTAssertEqual(wakeLocale("小爱同学", app: "zh_TW", preferred: ["zh-Hant-TW"]), "zh-TW")
        XCTAssertEqual(wakeLocale("小爱同学", app: "ja_JP", preferred: ["ja-JP"]), "ja-JP")
    }

    func testAWakePhraseNoOnDeviceRecognizerWritesIsNotHeard() {
        XCTAssertNil(wakeLocale("小爱同学", onDevice: { $0.language.languageCode != "zh" && $0.language.languageCode != "ja" }))
        XCTAssertNil(wakeLocale("Γεια σου Ερμή"), "no Greek recognizer is offered here")
        XCTAssertNil(WakeSpeechLocale.note(for: "Hey Hermes", among: ["Hey Hermes"], appLocale: Locale(identifier: "en_US"), localeFor: { _ in Locale(identifier: "en_US") }))
        XCTAssertEqual(WakeSpeechLocale.note(for: "Hey Hermes", among: ["Hey Hermes"], appLocale: Locale(identifier: "en_US"), localeFor: { _ in nil })?.isUnheard, true, "no on-device model for the app locale")
        XCTAssertNil(WakeSpeechLocale.note(for: "小爱同学", among: ["小爱同学"], appLocale: Locale(identifier: "zh_CN"), localeFor: { _ in Locale(identifier: "zh_CN") }))
        XCTAssertEqual(WakeSpeechLocale.script(of: "ﾊﾅｺ"), .kana, "halfwidth katakana")
    }

    func testWakeListensInThreeLanguagesAtMost() {
        let languages = ["Hey Hermes": "en_US", "小爱同学": "zh_CN", "안녕 헤르메스": "ko_KR", "Привет Гермес": "ru_RU"]
        let phrases = ["Hey Hermes", "小爱同学", "안녕 헤르메스", "Привет Гермес", "Hey Hermes work"]
        let localeFor: (String) -> Locale? = { Locale(identifier: languages[$0] ?? "en_US") }
        let groups = WakeSpeechLocale.listening(for: phrases, localeFor: localeFor)
        XCTAssertEqual(groups.map { $0.locale.identifier }, ["en_US", "zh_CN", "ko_KR"])
        XCTAssertEqual(groups[0].phrases, ["Hey Hermes", "Hey Hermes work"])
        // Settings says the fourth language's phrase isn't heard, rather
        // than naming a recognizer the listener left out.
        let note = WakeSpeechLocale.note(for: "Привет Гермес", among: phrases, appLocale: Locale(identifier: "en_US"), localeFor: localeFor)
        XCTAssertEqual(note?.isUnheard, true)
        XCTAssertEqual(WakeSpeechLocale.note(for: "小爱同学", among: phrases, appLocale: Locale(identifier: "en_US"), localeFor: localeFor)?.isUnheard, false)
    }
}
