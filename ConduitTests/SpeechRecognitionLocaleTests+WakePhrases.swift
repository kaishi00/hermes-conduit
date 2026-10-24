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
        XCTAssertNil(WakeSpeechLocale.note(for: "Hey Hermes", appLocale: Locale(identifier: "en_US")))
        XCTAssertNil(WakeSpeechLocale.note(for: "小爱同学", appLocale: Locale(identifier: "zh_CN")))
    }
}
