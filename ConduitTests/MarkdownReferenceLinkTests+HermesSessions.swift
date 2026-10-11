import XCTest
@testable import Conduit

/// Hermes' `@session:<profile>/<id>` chat references (its session_search
/// tool writes them when it points at an earlier chat): a link that opens the
/// chat in a message, the chat's name when spoken.
extension MarkdownReferenceLinkTests {
    func testSessionReferencesBecomeLinksToTheChat() {
        defer { HermesSessionReference.updateTitles([:]) }
        HermesSessionReference.updateTitles(["20261011_142233_ab12cd": "GPU setup"])
        let open = AppLocalization.string("Open chat")
        XCTAssertEqual(
            HermesSessionReference.linkingMarkdown("We sorted it in @session:default/20261011_142233_ab12cd."),
            "We sorted it in [GPU setup](conduit://session/20261011_142233_ab12cd?profile=default)."
        )
        XCTAssertEqual(
            HermesSessionReference.linkingMarkdown("See @session:20261001_090000_ffffff: it has the plan"),
            "See [\(open)](conduit://session/20261001_090000_ffffff): it has the plan"
        )
        XCTAssertEqual(
            HermesSessionReference.linkingMarkdown("[That chat](@session:work/abc) and `@session:default/abc`"),
            "[That chat](conduit://session/abc?profile=work) and `@session:default/abc`",
            "a Markdown target too; inline code stays as written"
        )
        XCTAssertEqual(HermesSessionReference.linkingMarkdown("mail me@session:x or a/@session:y"), "mail me@session:x or a/@session:y")
        XCTAssertEqual(
            HermesSessionReference.references(in: "@session:default/a1 and @session:b2"),
            [HermesSessionReference(id: "a1", profile: "default"), HermesSessionReference(id: "b2", profile: nil)]
        )
    }

    func testAMessageLinksItsSessionReferencesButNotItsCode() {
        let blocks = MarkdownParser.parse("In @session:default/abc we chose.\n\n```\n@session:default/abc\n```")
        guard case .paragraph(let text)? = blocks.first else { return XCTFail("a paragraph first") }
        XCTAssertEqual(text, "In [\(AppLocalization.string("Open chat"))](conduit://session/abc?profile=default) we chose.")
        XCTAssertTrue(blocks.dropFirst().allSatisfy { if case .paragraph = $0 { return false }; return true }, "the fence stays code")
        let link = URL(string: "conduit://session/abc?profile=default")!
        XCTAssertEqual(ConduitAppLink(url: link), .session(id: "abc", profile: "default"))
    }

    func testSessionReferencesAreSpokenAsTheChatsName() {
        defer { HermesSessionReference.updateTitles([:]) }
        HermesSessionReference.updateTitles(["abc": "GPU setup"])
        XCTAssertEqual(HermesSessionReference.plain("It's in @session:default/abc."), "It's in GPU setup.")
        XCTAssertEqual(HermesSessionReference.plain("It's in @session:default/zzz."), "It's in.")
        XCTAssertEqual(HermesSessionReference.plain("See [the old chat](@session:default/zzz) now"), "See the old chat now")
        XCTAssertEqual(SpokenTextFilter.filter("Open @session:default/abc to see it."), "Open GPU setup to see it.")
        XCTAssertEqual(HermesSessionReference.plain("Type `@session:default/abc` as is"), "Type `@session:default/abc` as is",
                       "inline code stays as written")
    }

    func testAChatNamedLaterRendersAgain() {
        defer { HermesSessionReference.updateTitles([:]) }
        let text = "In @session:default/abc we chose."
        let before = HermesSessionReference.titleKey(for: text)
        HermesSessionReference.updateTitles(["abc": "GPU setup"])
        XCTAssertNotEqual(HermesSessionReference.titleKey(for: text), before, "the render cache keys on it")
        XCTAssertEqual(HermesSessionReference.titleKey(for: "No reference here"), "")
    }

    func testASessionReferenceSplitAcrossDeltasIsSaidWhole() {
        defer { HermesSessionReference.updateTitles([:]) }
        HermesSessionReference.updateTitles(["20261011_ab": "GPU setup"])
        var filter = SpokenTextFilter()
        var spoken = ""
        for delta in ["We did it in @ses", "sion:default/2026", "1011_ab", ". Then [the", " chat](@session:x/", "zz) again @", "home"] {
            spoken += filter.feed(delta)
        }
        spoken += filter.finish()
        XCTAssertEqual(spoken, "We did it in GPU setup. Then the chat again @home")
    }
}
