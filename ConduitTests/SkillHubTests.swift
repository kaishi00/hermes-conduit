//
//  SkillHubTests.swift
//  ConduitTests
//
//  Browse Skill Hub: what Conduit reads from Hermes' hub routes (sources,
//  search, scan) and what the store asks for.
//

import XCTest
@testable import Conduit

@MainActor
final class SkillHubTests: XCTestCase {
    func testTheSourcesAnswerReadsAsHermesSendsIt() {
        let hub = SkillHubSnapshot([
            "sources": [
                ["id": "official", "label": "Official (Nous)", "searchable": true],
                ["id": "hermes-index", "label": "Hermes Index", "available": true, "searchable": true],
                ["id": "github", "label": "GitHub", "rate_limited": true, "searchable": false]
            ],
            "index_available": true,
            "featured": [
                ["name": "pdf", "identifier": "skills-sh/anthropics/pdf", "description": "PDFs", "source": "skills-sh", "trust_level": "trusted", "repo": "anthropics/skills", "tags": ["docs", 3]],
                ["name": "pdf again", "identifier": "skills-sh/anthropics/pdf"],
                ["name": "---", "identifier": "clawhub/someone/weather", "source": "clawhub"],
                ["description": "no name or identifier"]
            ],
            "installed": ["skills-sh/anthropics/pdf": ["name": "pdf", "trust_level": "trusted"], "github/x/y": [:]]
        ])
        XCTAssertTrue(hub.indexAvailable)
        XCTAssertEqual(hub.sources.map(\.id), ["official", "hermes-index", "github"])
        XCTAssertEqual(hub.searchableSources.map(\.id), ["official", "hermes-index"], "A source the index covers isn't searched on its own")
        XCTAssertTrue(hub.sources[2].rateLimited)
        XCTAssertEqual(hub.featured.map(\.identifier), ["skills-sh/anthropics/pdf", "clawhub/someone/weather"], "First of each identifier, rows without one dropped")
        XCTAssertEqual(hub.featured[0].tags, ["docs"])
        XCTAssertEqual(hub.featured[0].trustLevel, "trusted")
        XCTAssertEqual(hub.featured[1].name, "weather", "A stray front-matter delimiter reads as the identifier's last part")
        XCTAssertEqual(hub.featured[1].trustLevel, "community")
        XCTAssertEqual(hub.installed, ["skills-sh/anthropics/pdf": "pdf", "github/x/y": "github/x/y"])
    }

    func testASkillsSourcePageIsAWebAddressOnly() {
        XCTAssertEqual(HubSkill(name: "a", identifier: "a", repo: "anthropics/skills").repoURL?.absoluteString, "https://github.com/anthropics/skills")
        XCTAssertEqual(HubSkill(name: "a", identifier: "a", repo: "https://gitlab.com/x/y").repoURL?.absoluteString, "https://gitlab.com/x/y")
        XCTAssertNil(HubSkill(name: "a", identifier: "a", repo: "javascript:alert(1)").repoURL)
        XCTAssertNil(HubSkill(name: "a", identifier: "a", repo: "file:///etc/passwd").repoURL)
        XCTAssertNil(HubSkill(name: "a", identifier: "a", repo: "a/b/c").repoURL)
        XCTAssertNil(HubSkill(name: "a", identifier: "a").repoURL)
    }

    func testTheScanReadsWorstFirst() {
        let scan = SkillHubScan([
            "verdict": "warn",
            "summary": "2 findings",
            "policy": "ask",
            "policy_reason": "Community skill with findings",
            "findings": [
                ["severity": "low", "category": "style", "file": "SKILL.md", "description": "Long line"],
                ["severity": "HIGH", "category": "exfiltration", "file": "run.sh", "line": 12, "description": "Sends files out"],
                "not a finding"
            ]
        ])
        XCTAssertEqual(scan.policy, .ask)
        XCTAssertEqual(scan.policyReason, "Community skill with findings")
        XCTAssertEqual(scan.findings.map(\.severity), ["high", "low"])
        XCTAssertEqual(scan.findings[0].location, "run.sh:12")
        XCTAssertEqual(scan.findings[1].location, "SKILL.md")
        XCTAssertEqual(SkillHubScan(["policy": "block"]).policy, .block)
        XCTAssertEqual(SkillHubScan(["policy": "whatever"]).policy, .ask, "An answer Conduit doesn't know asks first")
    }

    func testTheSearchAsksHermesAndReadsWhatIsInstalled() async throws {
        let requester = SkillHubRequester(responses: [
            "/api/skills/hub/sources": ["sources": [["id": "official", "label": "Official (Nous)"]], "installed": [:]],
            "/api/skills/hub/search": [
                "results": [["name": "git", "identifier": "github/a/git", "source": "github", "trust_level": "community"]],
                "timed_out": ["clawhub"],
                "installed": ["github/a/git": ["name": "git"]]
            ]
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "work")
        await store.loadSkillHub()
        XCTAssertEqual(store.skillHub?.sources.first?.label, "Official (Nous)")

        let results = try await store.searchSkillHub("git tools", source: "github")
        XCTAssertEqual(results.results.map(\.identifier), ["github/a/git"])
        XCTAssertEqual(results.timedOut, ["clawhub"])
        XCTAssertEqual(store.hubInstalled, ["github/a/git": "git"], "A search's answer says what's installed now")
        let path = try XCTUnwrap(requester.paths.last)
        XCTAssertTrue(path.hasPrefix("/api/skills/hub/search?"))
        XCTAssertTrue(path.contains("q=git%20tools"))
        XCTAssertTrue(path.contains("source=github"))
        XCTAssertTrue(path.contains("limit=50"))
        XCTAssertTrue(path.contains("profile=work"), "The search is the profile's")
    }

    func testASearchMarksInstalledSkillsWhenTheSourcesReadFailed() async throws {
        let requester = SkillHubRequester(responses: [
            "/api/skills/hub/search": ["results": [["identifier": "github/a/git"]], "installed": ["github/a/git": ["name": "git"]]]
        ])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        await store.loadSkillHub()
        XCTAssertNil(store.skillHub)
        _ = try await store.searchSkillHub("git")
        XCTAssertEqual(store.hubInstalled, ["github/a/git": "git"])
    }

    func testAHermesWithoutTheHubOffersNone() async {
        let requester = SkillHubRequester(responses: [:])
        requester.failure = DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        await store.loadSkillHub()
        XCTAssertTrue(store.skillHubMissing)
        XCTAssertNil(store.skillHub)
        XCTAssertNil(store.skillHubError)
    }

    func testAFailedReadKeepsTheHubShown() async {
        let requester = SkillHubRequester(responses: ["/api/skills/hub/sources": ["sources": [["id": "github", "label": "GitHub"]]]])
        let store = CapabilitiesStore()
        store.configure(requester: requester, profile: "default")
        await store.loadSkillHub()
        requester.failure = URLError(.timedOut)
        await store.loadSkillHub()
        XCTAssertEqual(store.skillHub?.sources.map(\.id), ["github"])
        XCTAssertNotNil(store.skillHubError)
        XCTAssertFalse(store.skillHubMissing)
    }
}

private final class SkillHubRequester: DashboardJSONRequester {
    var responses: [String: [String: Any]]
    var failure: Error?
    private(set) var paths: [String] = []

    init(responses: [String: [String: Any]]) {
        self.responses = responses
    }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        paths.append(path)
        if let failure { throw failure }
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard let response = responses[bare] else { throw URLError(.fileDoesNotExist) }
        return response
    }
}
