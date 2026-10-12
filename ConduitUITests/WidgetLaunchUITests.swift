//
//  WidgetLaunchUITests.swift
//  ConduitUITests
//
//  These scenarios exercise the DEBUG-only fixture delivery path into the same
//  URL admission used by .onOpenURL. They do not simulate WidgetKit or prove
//  that an installed Home Screen widget delivered a tap.
//

import XCTest

final class WidgetLaunchUITests: XCTestCase {
    private enum Identity {
        static let connectedDashboard = "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD"
        static let seededProfiles = "-CONDUIT_UI_TEST_PROFILES"
        static let coldWidgetURL = "-CONDUIT_UI_TEST_WIDGET_URL"
        static let widgetDeliveryMode = "-CONDUIT_UI_TEST_WIDGET_DELIVERY"
        static let holdWidgetReadiness = "-CONDUIT_UI_TEST_WIDGET_HOLD_READINESS"
        static let deliverWidgetURL = "widgetUITestDeliverURL"

        // The DEBUG fixture seeds this deterministic workspace and one saved
        // conversation before it admits a launch URL. It must use the normal
        // app URL-ingestion/coordinator path, not fake the visible outcome.
        static let dashboardID = "8D516B21-6B3C-4F5A-A0D6-6F6E8B73A901"
        static let profile = "work"
        static let sessionID = "widget-ui-test-session"

        // Machine-readable outcome surfaces owned by the DEBUG fixture. They
        // expose app state/presentation, never claim that audio was captured.
        static let workspaceOutcome = "widgetUITestWorkspace"
        static let conversationOutcome = "widgetUITestConversation"
        static let freshConversationOutcome = "widgetUITestFreshConversation"
        static let deferredTalkOutcome = "widgetUITestTalkDeferred"
        static let recoveryOutcome = "widgetUITestRecovery"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdWidgetResumeOpensRequestedWorkspace() throws {
        let app = launchApp(coldURL: resumeURL)

        XCTAssertTrue(app.otherElements[Identity.workspaceOutcome].waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(app.otherElements[Identity.workspaceOutcome].value as? String, Identity.profile)
        XCTAssertTrue(app.otherElements[Identity.conversationOutcome].waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(app.otherElements[Identity.conversationOutcome].value as? String, Identity.sessionID)
    }

    func testWarmWidgetNewChatCreatesFreshConversation() throws {
        let app = launchApp(warmURL: newChatURL)
        let deliver = app.buttons[Identity.deliverWidgetURL]
        XCTAssertTrue(deliver.waitForExistence(timeout: 10), tree(app))

        deliver.tap()

        let freshConversation = app.otherElements[Identity.freshConversationOutcome]
        XCTAssertTrue(freshConversation.waitForExistence(timeout: 10), tree(app))
        XCTAssertTrue((freshConversation.value as? String)?.isEmpty == false, "New Chat must expose the identity created by the app operation. Tree:\n\(app.debugDescription)")
        XCTAssertNotEqual(freshConversation.value as? String, Identity.sessionID, "New Chat must not resume the seeded conversation")
    }

    func testWidgetTalkWaitsForForegroundReadiness() throws {
        let app = launchApp(warmURL: talkURL, holdReadiness: true)
        let deliver = app.buttons[Identity.deliverWidgetURL]
        XCTAssertTrue(deliver.waitForExistence(timeout: 10), tree(app))

        deliver.tap()

        let deferred = app.otherElements[Identity.deferredTalkOutcome]
        XCTAssertTrue(deferred.waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(deferred.value as? String, "waiting-for-foreground-readiness")
        // The fixture exposes this marker only while the real launch request
        // remains pending and the actual voice sheet/call are both inactive.
        // Audio non-activation is separately covered by Task 3's unit spies.
    }

    func testRemovedWidgetTargetShowsRecovery() throws {
        let app = launchApp(coldURL: missingConversationURL)

        let recovery = app.otherElements[Identity.recoveryOutcome]
        XCTAssertTrue(recovery.waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(recovery.value as? String, "conversation-unavailable")
        XCTAssertEqual(app.otherElements[Identity.workspaceOutcome].value as? String, Identity.profile, "Recovery must remain scoped to the requested workspace. Tree:\n\(app.debugDescription)")
        XCTAssertNotEqual(app.otherElements[Identity.conversationOutcome].value as? String, Identity.sessionID, "A missing conversation must not be replaced by the current conversation. Tree:\n\(app.debugDescription)")
    }

    // MARK: - Launch fixture

    private var resumeURL: URL {
        widgetURL(action: "resume", includeConversation: true)
    }

    private var missingConversationURL: URL {
        widgetURL(action: "resume", includeConversation: true, sessionID: "evicted-widget-ui-test-session")
    }

    private var newChatURL: URL {
        widgetURL(action: "newChat", includeConversation: false)
    }

    private var talkURL: URL {
        widgetURL(action: "talk", includeConversation: false)
    }

    private func widgetURL(action: String, includeConversation: Bool, sessionID: String = Identity.sessionID) -> URL {
        var components = URLComponents()
        components.scheme = "conduit"
        components.host = "widget"
        components.path = "/v1/\(action)"
        var items = [
            URLQueryItem(name: "dashboard", value: Identity.dashboardID.lowercased()),
            URLQueryItem(name: "profile", value: Identity.profile)
        ]
        if includeConversation {
            items += [
                URLQueryItem(name: "kind", value: "dashboard"),
                URLQueryItem(name: "scope", value: Identity.profile),
                URLQueryItem(name: "session", value: sessionID),
                URLQueryItem(name: "unverified", value: "false")
            ]
        }
        components.queryItems = items
        guard let url = components.url else { preconditionFailure("Widget fixture URL must be valid") }
        return url
    }

    private func launchApp(coldURL: URL? = nil, warmURL: URL? = nil, holdReadiness: Bool = false) -> XCUIApplication {
        precondition(coldURL == nil || warmURL == nil, "Choose cold or warm fixture delivery")
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments += [
            Identity.connectedDashboard, "https://conduit-ui-test.invalid",
            Identity.seededProfiles, "work,staging"
        ]
        if let coldURL {
            app.launchArguments += [Identity.coldWidgetURL, coldURL.absoluteString]
        } else if let warmURL {
            app.launchArguments += [Identity.coldWidgetURL, warmURL.absoluteString, Identity.widgetDeliveryMode, "warm"]
        }
        if holdReadiness {
            app.launchArguments.append(Identity.holdWidgetReadiness)
        }
        app.launch()
        return app
    }

    private func tree(_ app: XCUIApplication) -> String {
        "Widget launch outcome missing. Tree:\n\(app.debugDescription)"
    }
}
