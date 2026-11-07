//
//  RichCardTests+Diff.swift
//  ConduitTests
//
//  Diff cards (Cards Hermes shows in docs/FEATURE_MAP.md): a diff as the
//  views read it, its line numbers and changed words, the rows a file
//  draws, the whole diff read from the host, and live models not offered
//  it. An extension of an existing class, so the test planner needs no new
//  entry.
//

import XCTest
@testable import Conduit

@MainActor
private final class AskedPaths {
    var paths: [String] = []
}

extension AppStateVoiceCapabilityTests {
    private static let diffCard: [String: Any] = [
        "type": "diff", "title": "Fix the login retry",
        "source": ["name": "PR #1713", "url": "https://github.com/example/app/pull/1713"],
        "diff": [
            "files": [
                ["path": "Sources/Login.swift", "status": "modified", "added": 2, "removed": 1, "hunks": [
                    ["old_start": 40, "new_start": 40, "context": "func retry() {",
                     "lines": ["     let delay = 2.0", "-    attempts += 2", "+    attempts += 1", "+    log(attempts)",
                               "     return delay"]] as [String: Any],
                    ["old_start": 90, "new_start": 91, "lines": ["-old()", "+brandNew()"]] as [String: Any],
                ]] as [String: Any],
                ["path": "docs/login.md", "old_path": "docs/sign-in.md", "status": "renamed", "added": 0, "removed": 0],
                ["path": "Assets/logo.png", "status": "added", "binary": true, "added": 0, "removed": 0],
            ],
            "added": 3, "removed": 2, "more_files": 4,
        ] as [String: Any],
    ]

    private func diff(_ json: [String: Any] = AppStateVoiceCapabilityTests.diffCard) throws -> RichDiff {
        let normalized = try XCTUnwrap(RichCardSchema.bundled?.normalizeCards([json]).first)
        return try XCTUnwrap(RichCard(normalized: normalized, id: 0)?.diff)
    }

    func testADiffCardReadsItsFilesAndTotals() throws {
        let diff = try diff()
        XCTAssertEqual(diff.files.map(\.path), ["Sources/Login.swift", "docs/login.md", "Assets/logo.png"])
        XCTAssertEqual(diff.fileCount, 7, "the files listed and those past them")
        XCTAssertEqual([diff.added, diff.removed], [3, 2])
        XCTAssertTrue(diff.hasLines)
        XCTAssertNil(diff.keptID, "a short diff travels whole")
        let login = diff.files[0]
        XCTAssertEqual(login.name, "Login.swift")
        XCTAssertEqual(login.folder, "Sources")
        XCTAssertEqual(diff.files[1].oldPath, "docs/sign-in.md")
        XCTAssertTrue(diff.files[2].binary)
        XCTAssertEqual(RichDiffFileRow.statusName(diff.files[2]), AppLocalization.string("Binary"))
        XCTAssertNil(RichDiffFileRow.statusName(login), "a modified file needs no word")
    }

    func testADiffNumbersItsLinesAndPicksOutTheChangedWords() throws {
        let hunk = try diff().files[0].hunks[0]
        XCTAssertEqual(hunk.lines.map(\.old), [40, 41, nil, nil, 42])
        XCTAssertEqual(hunk.lines.map(\.new), [40, nil, 41, 42, 43])
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(hunk.lines[1].text, "    attempts += 2", "the line keeps its indent")
        XCTAssertEqual(hunk.lines[1].changed, 16..<17, "only the 2 changed")
        XCTAssertEqual(hunk.lines[2].changed, 16..<17)
        XCTAssertNil(hunk.lines[3].changed, "an added line with no removed one beside it")
        XCTAssertEqual(hunk.header, "@@ -40,3 +40,4 @@ func retry() {")
        XCTAssertEqual(hunk.oldEnd, 43)
    }

    func testChangedWordsNeedSomethingInCommon() {
        let (before, after) = RichDiffLine.changedParts("old()", "brandNew()")
        XCTAssertEqual(before, 0..<3)
        XCTAssertEqual(after, 0..<8, "the shared () is enough")
        let (left, right) = RichDiffLine.changedParts("    alpha", "    bravo")
        XCTAssertNil(left, "an indent alone isn't a likeness: the whole line changed")
        XCTAssertNil(right)
        let (same, _) = RichDiffLine.changedParts("x", "x")
        XCTAssertNil(same)
        let (shorter, longer) = RichDiffLine.changedParts("call(a)", "call(a, b)")
        XCTAssertNil(shorter, "nothing removed from the old line")
        XCTAssertEqual(longer, 6..<9)
    }

    func testAFileDrawsItsHunksAndTheLinesBetweenThem() throws {
        let file = try diff().files[0]
        XCTAssertEqual(file.unchangedAfter(0), 47, "lines 43 to 89 didn't change")
        XCTAssertNil(file.unchangedAfter(1))
        let rows = RichDiffRow.rows(file)
        XCTAssertEqual(rows.count, 1 + 5 + 1 + 1 + 2)
        XCTAssertEqual(rows[6], .unchanged(47))
        let preview = RichDiffRow.rows(file, limit: 3)
        XCTAssertEqual(preview.count, 4, "the bar and three lines, nothing after")
        XCTAssertEqual(RichDiffRow.digits(file), 2)
        XCTAssertTrue(file.patch.hasPrefix("--- a/Sources/Login.swift\n+++ b/Sources/Login.swift\n@@ -40,3 +40,4 @@"))
    }

    func testTheSummaryBarShowsTheShareAddedAndRemoved() {
        XCTAssertEqual(RichDiffSummary.blocks(added: 30, removed: 10).added, 4)
        XCTAssertEqual(RichDiffSummary.blocks(added: 30, removed: 10).removed, 1)
        XCTAssertEqual(RichDiffSummary.blocks(added: 100, removed: 1).removed, 1, "a removal always shows")
        XCTAssertEqual(RichDiffSummary.blocks(added: 1, removed: 1).added, 1, "a small change doesn't fill the bar")
        XCTAssertEqual(RichDiffSummary.blocks(added: 1, removed: 1).removed, 1)
        XCTAssertEqual(RichDiffSummary.blocks(added: 0, removed: 0).added, 0)
    }

    @MainActor
    func testALongDiffListsItsFilesAndReadsTheRestFromTheHost() async throws {
        let id = "cd-0123456789abcdef"
        let listed = try diff([
            "type": "diff",
            "diff": ["files": [["path": "a.swift", "status": "modified", "added": 200, "removed": 0]],
                     "added": 200, "removed": 0, "id": id] as [String: Any],
        ])
        XCTAssertFalse(listed.hasLines)
        XCTAssertEqual(listed.keptID, id)
        XCTAssertTrue(listed.opensWhole)
        let unknown = try diff([
            "type": "diff",
            "diff": ["files": [["path": "a", "status": "modified", "added": 1, "removed": 0]],
                     "added": 1, "removed": 0, "id": "cd-nope"] as [String: Any],
        ])
        XCTAssertNil(unknown.keptID, "an id the host didn't give is left out")

        let loader = RichDiffLoader.shared
        let asked = AskedPaths()
        loader.read = { path in
            asked.paths.append(path)
            return ["diff": ["files": [["path": "a.swift", "status": "modified", "added": 1, "removed": 0,
                                        "hunks": [["old_start": 1, "new_start": 1, "lines": ["+let x = 1"]]]]],
                             "added": 1, "removed": 0]]
        }
        defer { loader.read = nil }
        let whole = try await loader.diff(id)
        XCTAssertEqual(whole.files[0].hunks[0].lines[0].text, "let x = 1")
        _ = try await loader.diff(id)
        XCTAssertEqual(asked.paths, ["/api/plugins/conduit_push/boards/diffs?id=\(id)"], "read once")
        do {
            _ = try await loader.diff("../etc")
            XCTFail("only a kept diff's id is read")
        } catch {}
    }

    func testLiveModelsAreNotOfferedDiffs() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(schema.liveToolParameter(description: "Cards.")["items"] as? [String: Any])
        let properties = try XCTUnwrap(card["properties"] as? [String: Any])
        XCTAssertNil(properties["diff"])
        let kinds = try XCTUnwrap((properties["type"] as? [String: Any])?["enum"] as? [String])
        XCTAssertFalse(kinds.contains("diff"))
        XCTAssertTrue(kinds.contains("callout"))
    }

    /// Issue 1852 (Trojan Source): an override in a line would draw it in
    /// another order than it runs, and Copy Changes would paste it.
    func testHiddenBidiCharactersShowAsMarksAndNeverReachCopyChanges() throws {
        let card: [String: Any] = [
            "type": "diff", "title": "\u{FEFF}Fix the \u{202E}admin\u{202C} check",
            "diff": [
                "files": [["path": "auth\u{200B}.py", "status": "modified", "added": 1, "removed": 0, "hunks": [
                    ["old_start": 1, "new_start": 1, "context": "def is\u{2066}_admin",
                     "lines": ["+ok = role != 'user\u{202E} \u{2066}'", " family = \"👨\u{200D}👩\u{200D}👧\""]]
                    as [String: Any],
                ]] as [String: Any]],
                "added": 1, "removed": 0,
            ] as [String: Any],
        ]
        let normalized = try XCTUnwrap(RichCardSchema.bundled?.normalizeCards([card]).first)
        XCTAssertEqual(normalized["title"] as? String, "Fix the admin check", "text drops them")
        let file = try XCTUnwrap(RichCard(normalized: normalized, id: 0)?.diff?.files.first)
        XCTAssertEqual(file.path, "auth.py")
        XCTAssertEqual(file.hunks[0].lines.map(\.text), ["ok = role != 'user\u{FFFD} \u{FFFD}'",
                                                         "family = \"👨\u{200D}👩\u{200D}👧\""],
                       "a line shows where each was; an emoji keeps its joiners")
        let hidden = file.patch.unicodeScalars.filter(RichCardSchema.isHidden)
        XCTAssertTrue(hidden.isEmpty, "Copy Changes pastes none of them")
        XCTAssertTrue(file.patch.contains("def is_admin"), "the hunk header drops them too")
    }

    func testAKeptDiffIsCheckedAsACardsIs() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let diff = try XCTUnwrap(schema.normalizeDiff([
            "files": [["path": "a", "status": "modified", "added": 1, "removed": 0,
                       "hunks": [["old_start": 1, "new_start": 1, "lines": ["  kept\tspaces", "nope", "+x"]]]]],
            "added": 1, "removed": 0,
        ] as [String: Any]))
        let file = try XCTUnwrap((diff["files"] as? [[String: Any]])?.first)
        let hunk = try XCTUnwrap((file["hunks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hunk["lines"] as? [String], ["  kept spaces", "+x"])
        XCTAssertNil(schema.normalizeDiff(["files": []]))
        XCTAssertTrue(RichCardSchema.isDiffID("cd-0123456789abcdef"))
        XCTAssertFalse(RichCardSchema.isDiffID("cd-0123456789ABCDEF"))
    }
}
