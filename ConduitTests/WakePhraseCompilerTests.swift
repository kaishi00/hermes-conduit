import XCTest
@testable import Conduit

final class WakePhraseCompilerTests: XCTestCase {
    private let compiler = WakePhraseCompiler(tables: .testFixtures)
    private let defaultKey = WakeProfileKey(gatewayID: "https://hermes.example", profileID: "default")

    func testCompilesEnglishAndChineseWithStableAlias() throws {
        let english = WakePhraseBinding(key: defaultKey, phrase: "  Hey   Conduit ", startsFreshConversation: true)
        let chinese = WakePhraseBinding(
            key: WakeProfileKey(gatewayID: "https://hermes.example", profileID: "chinese"),
            phrase: "小爱同学",
            startsFreshConversation: false
        )

        let compiled = try compiler.compile([english, chinese])

        XCTAssertEqual(compiled[0].phrase, "hey conduit")
        XCTAssertEqual(compiled[0].tokens, ["HH", "EY", "K", "AA", "N", "D", "UW", "IH", "T"])
        XCTAssertEqual(compiled[1].tokens, ["xiao3", "ai4", "tong2", "xue2"])
        XCTAssertEqual(compiled[0].alias, WakePhraseCompiler.stableAlias(for: defaultKey, phrase: "hey conduit"))
        XCTAssertNotEqual(compiled[0].alias, compiled[1].alias)
    }

    func testRejectsDuplicatePhraseAcrossProfiles() {
        XCTAssertThrowsError(try compiler.compile([
            WakePhraseBinding(key: defaultKey, phrase: "Hey Conduit", startsFreshConversation: true),
            WakePhraseBinding(
                key: WakeProfileKey(gatewayID: "https://hermes.example", profileID: "work"),
                phrase: "hey conduit",
                startsFreshConversation: true
            )
        ])) { error in
            XCTAssertEqual(error as? WakePhraseValidationError, .duplicatePhrase("hey conduit"))
        }
    }

    func testRejectsWordsAndCharactersOutsideInjectedFixtures() {
        XCTAssertThrowsError(try compiler.compile([
            WakePhraseBinding(key: defaultKey, phrase: "unknown", startsFreshConversation: true)
        ])) { error in
            XCTAssertEqual(error as? WakePhraseValidationError, .unsupportedEnglishWord("unknown"))
        }
        XCTAssertThrowsError(try compiler.compile([
            WakePhraseBinding(key: defaultKey, phrase: "你好!", startsFreshConversation: true)
        ])) { error in
            XCTAssertEqual(error as? WakePhraseValidationError, .unsupportedCharacter("!"))
        }
    }
}

extension WakePhraseCompilerTests {
    private func binding(_ phrase: String, profile: String = "default") -> WakePhraseBinding {
        WakePhraseBinding(
            key: WakeProfileKey(gatewayID: "dashboard", profileID: profile),
            phrase: phrase,
            startsFreshConversation: true
        )
    }

    func testMatcherFindsWholeWordPhraseInsideTranscript() {
        let fam = binding("hey fam", profile: "fam")
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "Okay, hey Fam! What's up", bindings: [fam]), fam)
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "HEY   FAM", bindings: [fam]), fam)
        XCTAssertNil(WakePhraseMatcher.match(transcript: "hey family dinner", bindings: [fam]))
        XCTAssertNil(WakePhraseMatcher.match(transcript: "fam hey", bindings: [fam]))
        XCTAssertNil(WakePhraseMatcher.match(transcript: "", bindings: [fam]))
    }

    func testMatcherPrefersTheMostSpecificPhrase() {
        let fam = binding("hey fam", profile: "fam")
        let famWork = binding("hey fam work", profile: "work")
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "hey fam work please", bindings: [fam, famWork]), famWork)
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "hey fam please", bindings: [fam, famWork]), fam)
    }

    func testMatcherFoldsAccentsAndMatchesUnspacedScripts() {
        let accented = binding("hola zoë")
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "Hola Zoe", bindings: [accented]), accented)
        let chinese = binding("小爱同学")
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "嗯小爱同学你好", bindings: [chinese]), chinese)
    }

    func testMatcherIgnoresSingleWordPhrases() {
        XCTAssertFalse(WakePhraseMatcher.isUsable("conduit"))
        XCTAssertFalse(WakePhraseMatcher.isUsable("  !! "))
        XCTAssertTrue(WakePhraseMatcher.isUsable("hey conduit"))
        XCTAssertFalse(WakePhraseMatcher.isUsable("爱"))
        XCTAssertTrue(WakePhraseMatcher.isUsable("小爱"))
        XCTAssertNil(WakePhraseMatcher.match(transcript: "conduit", bindings: [binding("conduit")]))
    }
}
