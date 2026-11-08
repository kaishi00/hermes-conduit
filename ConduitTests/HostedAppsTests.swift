//
//  HostedAppsTests.swift
//  ConduitTests
//
//  Capabilities > Connectors > Apps: what Conduit reads from Hermes'
//  hosted connector calls, how it joins them into apps, and what it sends.
//

import XCTest
@testable import Conduit

final class HostedAppsTests: XCTestCase {
    private func object(_ json: String) throws -> [String: AnyCodable] {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        return try XCTUnwrap(value.objectValue)
    }

    private func rows(_ json: String, _ key: String) throws -> [[String: AnyCodable]] {
        try XCTUnwrap(object(json)[key]?.arrayValue).compactMap(\.objectValue)
    }

    private var catalog: [HostedAppCatalogEntry] {
        get throws {
            try rows(#"""
            {"connectors": [
              {"slug": "gmail", "name": "Gmail", "description": "Mail", "category": "productivity", "logo_url": "https://cdn.example.com/gmail.svg"},
              {"slug": "google_calendar", "name": " ", "description": "", "category": ""},
              {"slug": "notion", "name": "Notion", "description": "Notes", "category": "productivity", "logo_url": "javascript:alert(1)"}
            ]}
            """#, "connectors").compactMap(HostedAppCatalogEntry.init(object:))
        }
    }

    func testTheCatalogReadsAsHermesSendsIt() throws {
        let catalog = try self.catalog
        XCTAssertEqual(catalog.map(\.slug), ["gmail", "google_calendar", "notion"])
        XCTAssertEqual(catalog[1].name, "Google Calendar", "A blank name reads from the slug")
        XCTAssertEqual(HostedApps.logoURL(slug: "gmail", catalogLogo: catalog[0].logo)?.absoluteString, "https://cdn.example.com/gmail.svg")
        // A logo that isn't a web address falls back to the vendor's mark.
        XCTAssertEqual(HostedApps.logoURL(slug: "notion", catalogLogo: catalog[2].logo)?.absoluteString, "https://logos.composio.dev/api/notion")
        XCTAssertEqual(HostedApps.logoURL(slug: "google_calendar", catalogLogo: nil)?.absoluteString, "https://logos.composio.dev/api/google_calendar")
        XCTAssertEqual(HostedApps.title("github_mcp"), "Github MCP")
    }

    func testAppsJoinTheCatalogTheListTheAccountsAndTheRules() throws {
        let statuses = try rows(#"""
        {"available": true, "connectors": [
          {"connector": "gmail", "enabled": true, "connected": true, "connection_status": "active", "status_reason": null, "gateway_disabled_tools": []},
          {"connector": "slack", "enabled": true, "connected": true, "connection_status": "expired", "status_reason": "Token revoked", "gateway_disabled_tools": ["SLACK_DELETE"]}
        ]}
        """#, "connectors").compactMap(HostedAppStatus.init(object:))
        let accounts = try rows(#"""
        {"accounts": [
          {"connection_id": "c1", "connector": "gmail", "status": "active", "label": "me@work.com", "alias": "work", "active": false, "disabled": false, "created_at": "2026-11-01T00:00:00Z", "updated_at": ""},
          {"connection_id": "c2", "connector": "gmail", "status": "active", "label": "me@home.com", "alias": null, "active": true, "disabled": false, "created_at": "2026-10-01T00:00:00Z", "updated_at": ""},
          {"connection_id": "c0", "connector": "gmail", "status": "revoked", "label": "old", "active": false, "disabled": true, "created_at": "2026-09-01T00:00:00Z", "updated_at": ""}
        ]}
        """#, "accounts").compactMap(HostedAppAccount.init(object:))
        let policy = try XCTUnwrap(HostedAppPolicy(object: object(#"""
        {"layers": [
          {"kind": "org", "revision": "01HZZZZZZZZZZZZZZZZZZZZZZZ", "body": {"mode": "deny", "disabled_connectors": ["notion"], "tools": {"gmail": ["GMAIL_DELETE"]}, "tags": {"disable": ["destructive"]}}},
          {"kind": "member", "revision": "01HAAAAAAAAAAAAAAAAAAAAAAA", "body": {"mode": "deny", "disabled_connectors": ["google_calendar"], "tools": {"gmail": ["GMAIL_SEND"]}}}
        ], "effective": {"mode": "unrestricted", "version": 1, "revision": "x", "issued_at_ms": 0}}
        """#)))
        let snapshot = HostedAppsSnapshot(available: true, catalog: try catalog, statuses: statuses, accounts: accounts, policy: policy)
        let apps = snapshot.apps
        XCTAssertEqual(apps.map(\.slug), ["gmail", "google_calendar", "notion", "slack"], "A connected app the catalog lacks still shows")

        let gmail = snapshot.app("gmail")
        XCTAssertEqual(gmail.state, .connected)
        XCTAssertEqual(gmail.accounts.map(\.connectionID), ["c2", "c1"], "Active first, then newest; retired left out")
        XCTAssertEqual(gmail.accounts.map(\.name), ["me@home.com", "work"])
        XCTAssertEqual(gmail.disabledTools, ["GMAIL_SEND"], "The member's own switches")
        XCTAssertTrue(gmail.isYours)

        XCTAssertEqual(snapshot.app("google_calendar").state, .off)
        XCTAssertTrue(snapshot.app("google_calendar").isYours, "An app turned off is still the user's to turn on")
        XCTAssertEqual(snapshot.app("notion").state, .offByOrganization)
        let slack = snapshot.app("slack")
        XCTAssertEqual(slack.state, .expired)
        XCTAssertTrue(slack.needsReconnect)
        XCTAssertEqual(slack.statusReason, "Token revoked")
        XCTAssertEqual(slack.title, "Slack")

        XCTAssertEqual(policy.revision, "01HAAAAAAAAAAAAAAAAAAAAAAA")
        let tools = [
            HostedAppTool(slug: "GMAIL_SEND", name: "Send"),
            HostedAppTool(slug: "GMAIL_DELETE", name: "Delete"),
            HostedAppTool(slug: "GMAIL_TRASH", name: "Trash", hints: ["destructive"]),
            HostedAppTool(slug: "GMAIL_READ", name: "Read", hints: ["readOnly"]),
        ]
        XCTAssertEqual(policy.organizationLockedTools("gmail", tools: tools), ["GMAIL_DELETE", "GMAIL_TRASH"])
    }

    func testWithoutRulesTheListSaysWhatIsOff() {
        let snapshot = HostedAppsSnapshot(
            available: true,
            catalog: [],
            statuses: [HostedAppStatus(connector: "slack", connected: true, connectionStatus: "pending", gatewayDisabledTools: ["A"])],
            accounts: [],
            policy: nil
        )
        let slack = snapshot.app("slack")
        XCTAssertEqual(slack.state, .connecting)
        XCTAssertEqual(slack.disabledTools, ["A"])
        XCTAssertEqual(HostedAppsSnapshot.unavailable.apps, [])
    }

    /// A layer Conduit can't read makes the rules unread, never a layer
    /// that isn't there: an organization's lock would show as on (issue
    /// 1998). The section then says the rules couldn't be read.
    func testRulesWithALayerConduitCantReadAreNotRead() throws {
        XCTAssertNil(HostedAppPolicy(object: try object(#"""
        {"layers": [
          {"kind": "org", "revision": "r1", "body": {"mode": "blocklist", "disabled_connectors": ["gmail"]}},
          {"kind": "member", "revision": "r2", "body": {"mode": "unrestricted"}}
        ]}
        """#)))
        XCTAssertNil(HostedAppPolicy(object: try object(#"""
        {"layers": [{"kind": "role", "revision": "r1", "body": {}}]}
        """#)), "A layer without a mode")

        let failed = HostedAppsSnapshot(available: true, catalog: [], statuses: [], accounts: [], policy: nil, rulesFailed: true)
        let kept = try JSONDecoder().decode(HostedAppsSnapshot.self, from: JSONEncoder().encode(failed))
        XCTAssertEqual(kept.rulesFailed, true)
        // Apps kept before rulesFailed came along still open.
        let older = try JSONDecoder().decode(HostedAppsSnapshot.self, from: Data(#"""
        {"available": true, "catalog": [], "statuses": [], "accounts": []}
        """#.utf8))
        XCTAssertNil(older.rulesFailed)
    }

    /// A connection that drops and comes back is the same Hermes: what the
    /// section said stays, as does a sign-in, which goes on asking it
    /// (issue 1997). Another dashboard or profile is another Hermes.
    @MainActor
    func testAReconnectKeepsTheSectionsHermes() {
        let model = HostedAppsModel()
        model.show(scope: "mac|default|client1|true", hermes: "mac|default", kept: nil)
        model.note("gmail", "Waiting")
        model.show(scope: "mac|default||false", hermes: "mac|default", kept: nil)
        model.show(scope: "mac|default|client2|true", hermes: "mac|default", kept: nil)
        XCTAssertEqual(model.notes["gmail"], "Waiting", "Kept over the reconnect")
        model.show(scope: "mac|work|client3|true", hermes: "mac|work", kept: nil)
        XCTAssertNil(model.notes["gmail"], "Another profile's section starts afresh")
    }

    func testAllowAndDenyAllRules() {
        let allow = HostedAppPolicy.Rules(revision: "r", allowed: ["gmail"])
        XCTAssertTrue(allow.allows("gmail"))
        XCTAssertFalse(allow.allows("slack"))
        let none = HostedAppPolicy(member: nil, others: [HostedAppPolicy.Rules(revision: "r", allowed: [])])
        XCTAssertTrue(none.organizationLocks("gmail"))
        XCTAssertTrue(none.memberEnables("gmail"))
        XCTAssertNil(none.revision, "No member layer: the switches only read")
    }

    func testASignInKeepsItsPageUntilHermesMintsANewOne() throws {
        let start = try XCTUnwrap(HostedAppOperation(object: object(#"""
        {"op_id": "op1", "seq": 1, "deadline_at": 0, "settled": false,
         "targets": [{"name": "gmail", "kind": "connector", "action": "connect", "state": "initiated", "connect_url": "https://portal.example.com/connect/abc", "connection_id": "c9"}]}
        """#)))
        XCTAssertEqual(start.target("gmail")?.connectURL?.absoluteString, "https://portal.example.com/connect/abc")
        let later = try XCTUnwrap(HostedAppOperation(object: object(#"""
        {"op_id": "op1", "seq": 2, "settled": false, "targets": [{"name": "gmail", "state": "initiated"}]}
        """#))).carryingLink(from: start)
        XCTAssertEqual(later.target("gmail")?.connectURL, start.target("gmail")?.connectURL)
        XCTAssertEqual(later.target("gmail")?.connectionID, "c9")
        let done = try XCTUnwrap(HostedAppOperation(object: object(#"""
        {"op_id": "op1", "seq": 3, "settled": true, "targets": [{"name": "gmail", "state": "connected"}]}
        """#)))
        XCTAssertTrue(done.target("gmail")?.connected == true)
        let failed = try XCTUnwrap(HostedAppOperation(object: object(#"""
        {"op_id": "op1", "seq": 4, "targets": [{"name": "gmail", "state": "expired", "connect_url": "file:///etc/passwd"}]}
        """#)))
        XCTAssertTrue(failed.target("gmail")?.retryable == true)
        XCTAssertNil(failed.target("gmail")?.connectURL, "Only a web page opens")
    }

    func testAccountNamesFollowThePortalsFormat() {
        let accounts = [HostedAppAccount(connectionID: "c1", connector: "gmail", label: "a", alias: "work")]
        XCTAssertNil(HostedApps.accountNameProblem("home", among: accounts))
        XCTAssertNotNil(HostedApps.accountNameProblem("work", among: accounts))
        XCTAssertNil(HostedApps.accountNameProblem("work", among: accounts, renaming: "c1"), "Keeping its own name")
        XCTAssertNotNil(HostedApps.accountNameProblem("Work", among: []))
        XCTAssertNotNil(HostedApps.accountNameProblem("-work", among: []))
        XCTAssertNotNil(HostedApps.accountNameProblem(String(repeating: "a", count: 33), among: []))
    }

    /// The section opens on the kept apps: they keep through the store's
    /// credential strip whole.
    func testTheKeptAppsSurviveTheCredentialStrip() throws {
        let snapshot = HostedAppsSnapshot(
            available: true,
            catalog: [HostedAppCatalogEntry(slug: "gmail", name: "Gmail")],
            statuses: [HostedAppStatus(connector: "gmail", connected: true)],
            accounts: [HostedAppAccount(connectionID: "c1", connector: "gmail", label: "me@x.com", alias: "work")],
            policy: HostedAppPolicy(member: .init(revision: "r", denied: ["slack"], tools: ["gmail": ["GMAIL_SEND"]]))
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        let kept = OfflineChatCacheStore.withoutCredentials(json)
        let back = try JSONDecoder().decode(HostedAppsSnapshot.self, from: JSONSerialization.data(withJSONObject: kept))
        XCTAssertEqual(back, snapshot)
    }

    func testSVGLogosAreToldApart() {
        XCTAssertTrue(HostedAppLogoLoader.isSVG(Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)))
        XCTAssertFalse(HostedAppLogoLoader.isSVG(Data([0x89, 0x50, 0x4E, 0x47])))
    }
}
