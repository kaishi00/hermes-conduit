import XCTest
@testable import Conduit

final class WidgetLaunchLinkTests: XCTestCase {
    private let workspace = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, profile: "家庭/Work & café")
    private let reference = WidgetConversationReference(kind: .bot, scopeProfile: "研究者", botName: "研究者", botLabel: "Private Label", sessionID: "session-1", isUnverified: true)

    func testWidgetLinkRoundTripAndStrictNamespace() throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .resume, workspace: workspace, reference: reference))
        XCTAssertEqual(WidgetLaunchLink(url: link.url), link)
        XCTAssertNil(WidgetLaunchLink(url: try XCTUnwrap(URL(string: "conduit://session/session-1"))))
        let setup = try XCTUnwrap(WidgetLaunchLink(action: .open, workspace: nil, reference: nil))
        XCTAssertEqual(WidgetLaunchLink(url: setup.url), setup)
        XCTAssertFalse(link.url.absoluteString.contains("Private"))
        XCTAssertFalse(link.url.absoluteString.contains("label"))
    }

    func testMalformedShapesAndForeignURLsAreRejected() throws {
        for raw in [
            "https://widget/v1/open",
            "conduit://session/abc",
            "conduit://widget/v2/open",
            "conduit://widget/v1/unknown",
            "conduit://widget/v1//open",
            "conduit://widget/v1/open/",
            "conduit://widget/v1/resume?profile=x",
            "conduit://widget/v1/newChat",
            "conduit://widget/v1/talk",
            "conduit://widget/v1/resume?dashboard=00000000-0000-0000-0000-000000000001",
            "conduit://widget/v1/open?dashboard=00000000-0000-0000-0000-000000000001&profile=p&profile=q",
            "conduit://widget/v1/open?dashboard=00000000-0000-0000-0000-000000000001&profile=p&extra=x",
            "conduit://widget/v1/resume?dashboard=00000000-0000-0000-0000-000000000001&profile=p",
            "conduit://widget/v1/newChat?dashboard=00000000-0000-0000-0000-000000000001&profile=p&kind=dashboard&scope=p&session=s",
            "conduit://widget/v1/talk?dashboard=00000000-0000-0000-0000-000000000001&profile=p&kind=dashboard&scope=p&session=s",
            "conduit://widget/v1/resume?dashboard=00000000-0000-0000-0000-000000000001&profile=p&kind=bot&scope=b&bot=b&session=s&unverified=perhaps"
        ] {
            XCTAssertNil(WidgetLaunchLink(url: try XCTUnwrap(URL(string: raw), raw)), raw)
        }
    }

    func testAllActionsHaveStrictIdentityShapes() throws {
        let open = try XCTUnwrap(WidgetLaunchLink(action: .open, workspace: workspace, reference: nil))
        let fresh = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let talk = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))
        XCTAssertEqual(WidgetLaunchLink(url: open.url), open)
        XCTAssertEqual(WidgetLaunchLink(url: fresh.url), fresh)
        XCTAssertEqual(WidgetLaunchLink(url: talk.url), talk)
        XCTAssertNil(WidgetLaunchLink(url: URL(string: "conduit://widget/v1/resume")!))
        XCTAssertNil(WidgetLaunchLink(action: .resume, workspace: workspace, reference: nil))
        XCTAssertNil(WidgetLaunchLink(action: .resume, workspace: nil, reference: reference))
        XCTAssertNil(WidgetLaunchLink(action: .newChat, workspace: nil, reference: nil))
        XCTAssertNil(WidgetLaunchLink(action: .talk, workspace: nil, reference: nil))
        XCTAssertNil(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: reference))
        XCTAssertNil(WidgetLaunchLink(action: .talk, workspace: workspace, reference: reference))
        XCTAssertNil(WidgetLaunchLink(action: .open, workspace: workspace, reference: reference))
        let mismatchedBot = WidgetConversationReference(kind: .bot, scopeProfile: "owner", botName: "other", botLabel: nil, sessionID: "s", isUnverified: false)
        XCTAssertNil(WidgetLaunchLink(action: .resume, workspace: workspace, reference: mismatchedBot))
        let mismatchedDashboard = WidgetConversationReference(kind: .dashboard, scopeProfile: "another-profile", botName: nil, botLabel: nil, sessionID: "s", isUnverified: false)
        XCTAssertNil(WidgetLaunchLink(action: .resume, workspace: workspace, reference: mismatchedDashboard))
    }
}
