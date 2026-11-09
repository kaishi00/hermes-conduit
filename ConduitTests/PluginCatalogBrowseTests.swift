//
//  PluginCatalogBrowseTests.swift
//  ConduitTests
//
//  The Plugins tab's catalog browser: what Conduit reads from Hermes'
//  plugin catalog, which pictures it shows, and how Browse All narrows and
//  orders the catalog.
//

import XCTest
@testable import Conduit

final class PluginCatalogBrowseTests: XCTestCase {
    private func catalog() -> [PluginCatalogEntry] {
        PluginCatalogEntry.list(from: ["entries": [
            [
                "name": "blender", "title": "Blender", "description": "3D scenes", "tier": "official",
                "maintainer": "Nous Research", "category": "creative", "version": "1.2.0",
                "repo": "https://github.com/NousResearch/blender-plugin", "docs_url": "https://example.com/docs",
                "image": "https://raw.githubusercontent.com/NousResearch/blender-plugin/abc/art.jpg",
                "screenshots": ["https://user-images.githubusercontent.com/1/shot.png", "https://evil.example.com/x.png", "http://github.com/a.png"],
                "platforms": ["macos", "linux"],
                "capabilities": ["provides_tools": ["blender_render"], "provides_hooks": [], "requires_env": ["BLENDER_PATH"]],
                "known_issues": ["Slow on first run"],
                "installed": false
            ],
            ["name": "aave-mcp", "description": "DeFi", "tier": "verified", "category": "finance", "maintainer": "Aave", "image": "https://aave.com/art.png"],
            ["name": "zeta", "description": "Community thing", "tier": "community", "category": "tools", "installed": true],
            ["name": "kanban", "description": "Boards", "tier": "bundled", "category": "desktop", "image": "https://github.com/NousResearch/hermes-agent/raw/main/kanban.png"],
            ["description": "no name"]
        ]])
    }

    func testTheCatalogReadsAsHermesSendsIt() throws {
        let entries = catalog()
        XCTAssertEqual(entries.map(\.name), ["blender", "aave-mcp", "zeta", "kanban"])
        let blender = try XCTUnwrap(entries.first)
        XCTAssertEqual(blender.maintainer, "Nous Research")
        XCTAssertEqual(blender.version, "1.2.0")
        XCTAssertEqual(blender.tools, ["blender_render"])
        XCTAssertEqual(blender.requiresEnv, ["BLENDER_PATH"])
        XCTAssertEqual(blender.platforms, ["macos", "linux"])
        XCTAssertEqual(blender.knownIssues, ["Slow on first run"])
        XCTAssertEqual(blender.docsURL?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(blender.repoURL?.host, "github.com")
    }

    func testPicturesComeOnlyFromGitHubOverHTTPS() {
        let entries = catalog()
        XCTAssertNotNil(entries[0].imageURL)
        XCTAssertEqual(entries[0].screenshotURLs.map(\.host), ["user-images.githubusercontent.com"], "Another host's or plain http's pictures never load")
        XCTAssertNil(entries[1].imageURL)
        XCTAssertNotNil(entries[3].imageURL)
        XCTAssertNil(PluginCatalogEntry.imageURL("https://githubusercontent.com.evil.example/x.png"))
        XCTAssertNil(PluginCatalogEntry.webURL("javascript:alert(1)"))
    }

    func testTiersReadInTrustOrderWithBundledAsOfficial() {
        let entries = catalog()
        XCTAssertEqual(entries.map(\.normalizedTier), ["official", "verified", "community", "official"])
        XCTAssertEqual(CapabilityPluginFilter.tiers(in: entries), ["official", "verified", "community"])
        XCTAssertEqual(CapabilityPluginFilter.categories(in: entries), ["creative", "desktop", "finance", "tools"])
    }

    func testASelectionARefreshTookAwayStaysListedInItsPlace() {
        let entries = catalog().filter { $0.normalizedTier != "verified" }
        XCTAssertEqual(CapabilityPluginFilter.tiers(in: entries, keeping: "verified"), ["official", "verified", "community"], "In trust order, not appended")
        XCTAssertEqual(CapabilityPluginFilter.categories(in: entries, keeping: "finance"), ["creative", "desktop", "finance", "tools"])
        XCTAssertEqual(CapabilityPluginFilter.tiers(in: entries, keeping: nil), ["official", "community"])
    }

    func testBrowseNarrowsAndOrdersTheCatalog() {
        let entries = catalog()
        XCTAssertEqual(CapabilityPluginFilter.browse(entries, query: "", tier: nil, category: nil).map(\.name), ["blender", "kanban", "aave-mcp", "zeta"], "Official first, then verified, then community; installed ones stay")
        XCTAssertEqual(CapabilityPluginFilter.browse(entries, query: "", tier: "official", category: nil).map(\.name), ["blender", "kanban"])
        XCTAssertEqual(CapabilityPluginFilter.browse(entries, query: "", tier: nil, category: "finance").map(\.name), ["aave-mcp"])
        XCTAssertEqual(CapabilityPluginFilter.browse(entries, query: "render", tier: nil, category: nil).map(\.name), ["blender"], "A search reads the tools it adds")
        XCTAssertEqual(CapabilityPluginFilter.browse(entries, query: " aave ", tier: nil, category: nil).map(\.name), ["aave-mcp"], "A search reads the maintainer")
    }

    func testTheShelfLeadsWithTheCuratedPicks() {
        let entries = catalog()
        XCTAssertEqual(CapabilityPluginFilter.featured(entries).map(\.name), ["blender", "kanban"], "Curated picks, then official entries with a picture")
        XCTAssertEqual(CapabilityPluginFilter.featured(entries, limit: 1).map(\.name), ["blender"])
    }
}
