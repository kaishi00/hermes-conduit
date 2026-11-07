//
//  ProjectAndPrefetchFoldTests.swift
//  ConduitTests
//
//  A project page's reads across profiles fold back in the profiles'
//  order whichever answers first (issue 1966), and a file link's early
//  text read is only taken up by the same open (issue 1964).
//

import XCTest
@testable import Conduit

@MainActor
final class ProjectAndPrefetchFoldTests: XCTestCase {
    private func part(_ profile: String) -> ProjectProfileLanes {
        ProjectProfileLanes(profile: profile, lanes: [ProjectSessionLane(id: "\(profile)-lane", title: "Recent", sessions: [])])
    }

    func testProjectLanesFollowTheProfilesOrder() {
        // Outcomes are in `others`' order however the reads finished.
        let read = ProjectOtherProfilesRead(
            folding: [
                ProjectProfileRead(match: .some("p-b"), failed: false, part: part("b")),
                ProjectProfileRead(match: nil, failed: false, part: part("a")),
                ProjectProfileRead(match: .some("p-c"), failed: false, part: part("c")),
            ],
            of: ["b", "a", "c"],
            known: ["a": .some("p-a")]
        )
        XCTAssertEqual(read.parts.map(\.profile), ["b", "a", "c"])
        XCTAssertEqual(read.matches["a"], .some("p-a"))
        XCTAssertEqual(read.matches["b"], .some("p-b"))
        XCTAssertEqual(read.matches["c"], .some("p-c"))
        XCTAssertTrue(read.failed.isEmpty)
    }

    func testAKeptProjectThatStopsAnsweringIsForgottenAndNamedFailed() {
        let known: [String: String?] = ["a": "p-a", "b": nil]
        let read = ProjectOtherProfilesRead(
            folding: [
                ProjectProfileRead(match: .some(nil), failed: true, part: nil),
                ProjectProfileRead(match: nil, failed: true, part: nil),
                ProjectProfileRead(match: nil, failed: false, part: part("c")),
            ],
            of: ["a", "b", "c"],
            known: known
        )
        let forgotten: String?? = .some(nil)
        XCTAssertEqual(read.matches["a"], forgotten, "the kept match is looked up again next time")
        XCTAssertEqual(read.matches["b"], forgotten)
        XCTAssertEqual(read.failed, Set(["a", "b"]))
        XCTAssertEqual(read.parts.map { $0.profile }, ["c"])
    }

    func testAnEarlyTextReadIsTakenOnlyBySameOpenWithinItsLifetime() {
        let dashboard = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        func fits(path: String = "src/a.swift", profile: String = "default",
                  dashboard opening: UUID? = nil, after seconds: TimeInterval = 1) -> Bool {
            WorkspaceExplorer.prefetchedTextFits(
                path: "src/a.swift", profile: "default", dashboard: dashboard, readAt: start,
                openingPath: path, profile: profile, dashboard: opening ?? dashboard,
                now: start.addingTimeInterval(seconds)
            )
        }
        XCTAssertTrue(fits())
        XCTAssertFalse(fits(path: "src/b.swift"))
        XCTAssertFalse(fits(profile: "work"))
        XCTAssertFalse(fits(dashboard: UUID()))
        XCTAssertFalse(fits(after: WorkspaceExplorer.prefetchedTextLifetime))
    }
}
