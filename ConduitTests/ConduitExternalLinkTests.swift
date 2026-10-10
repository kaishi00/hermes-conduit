//
//  ConduitExternalLinkTests.swift
//  ConduitTests
//
//  `conduit://session/<id>` opened by another app (a notification, a
//  Shortcut): only plain chat links are accepted from outside. Written as
//  an extension of the existing link suite: the CI test planner is at
//  capacity for new XCTestCase classes.
//

import XCTest
@testable import Conduit

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testExternalSessionLinkOpensThatChat() throws {
        let url = try XCTUnwrap(URL(string: "conduit://session/20261009_160855_d213a4"))
        XCTAssertEqual(ConduitAppLink(externalURL: url), .session(id: "20261009_160855_d213a4"))
    }

    func testExternalLinkSchemeAndHostAreCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "CONDUIT://Session/20261009_160855_d213a4"))
        XCTAssertEqual(ConduitAppLink(externalURL: url), .session(id: "20261009_160855_d213a4"))
    }

    func testExternalBotLinksStayInsideTheApp() throws {
        let url = try XCTUnwrap(URL(string: "conduit://bot/researcher"))
        XCTAssertNotNil(ConduitAppLink(url: url))
        XCTAssertNil(ConduitAppLink(externalURL: url))
    }

    func testExternalMalformedOrForeignLinksAreIgnored() throws {
        for raw in [
            "conduit://session/",
            "conduit://session/a/b",
            "conduit://other/abc",
            "https://session/abc",
            "conduit://session/abc%20def",
            "conduit://session/abc%0Adef",
            "conduit://session/" + String(repeating: "a", count: 129)
        ] {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertNil(ConduitAppLink(externalURL: url), raw)
        }
    }

    func testExternalLinkLongestAcceptedIDStillOpens() throws {
        let id = String(repeating: "a", count: 128)
        let url = try XCTUnwrap(URL(string: "conduit://session/" + id))
        XCTAssertEqual(ConduitAppLink(externalURL: url), .session(id: id))
    }

    func testSessionLinkCarriesItsProfile() throws {
        let link = ConduitAppLink.session(id: "20261009_160855_d213a4", profile: "work")
        XCTAssertEqual(link.url.absoluteString, "conduit://session/20261009_160855_d213a4?profile=work")
        XCTAssertEqual(ConduitAppLink(url: link.url), link)
        XCTAssertEqual(ConduitAppLink(externalURL: link.url), link)
        let blank = try XCTUnwrap(URL(string: "conduit://session/abc?profile="))
        XCTAssertEqual(ConduitAppLink(externalURL: blank), .session(id: "abc"), "a blank profile is the profile in use")
    }

    func testExternalLinkWithAnOddProfileIsIgnored() throws {
        for raw in [
            "conduit://session/abc?profile=a%20b",
            "conduit://session/abc?profile=a%2Fb",
            "conduit://session/abc?profile=" + String(repeating: "a", count: 129)
        ] {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertNil(ConduitAppLink(externalURL: url), raw)
        }
    }

    func testLinkToAChatOnAnotherProfileOpensLikeItsNotification() async throws {
        let appState = try makeLinkAppState()
        defer { clearRoutedLink() }
        await appState.routeLinkedSession("work-chat", toProfile: "Work")
        XCTAssertNil(appState.errorMessage)
        XCTAssertEqual(
            PushNotificationService.shared.pendingTarget,
            ConduitNotificationTarget(
                profile: "work", sessionId: "work-chat", dashboardID: appState.activeDashboardID, type: nil, isChatLink: true
            )
        )
    }

    func testLinkToAnotherProfileNeverEndsACall() async throws {
        let appState = try makeLinkAppState()
        defer { clearRoutedLink() }
        appState.isNativeHermesCallActive = true
        await appState.routeLinkedSession("work-chat", toProfile: "work")
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("End the call to open a chat in another profile."))
        XCTAssertNotEqual(PushNotificationService.shared.pendingTarget?.sessionId, "work-chat")
        XCTAssertEqual(appState.activeProfile, "default")
    }

    func testLinkToABotsChatOpensItThroughItsBotWithoutASwitch() async throws {
        let appState = try makeLinkAppState()
        defer { clearRoutedLink() }
        appState.noteBotChatSessionForTesting("work-chat", profile: "atlas")
        appState.isNativeHermesCallActive = true
        await appState.routeLinkedSession("work-chat", toProfile: "work")
        XCTAssertNotEqual(appState.errorMessage, AppLocalization.string("End the call to open a chat in another profile."))
        XCTAssertNotEqual(PushNotificationService.shared.pendingTarget?.sessionId, "work-chat")
        XCTAssertEqual(appState.activeProfile, "default")
    }

    func testLinkToAProfileTheDashboardDoesNotListOpensNothing() async throws {
        let appState = try makeLinkAppState(listedOnHost: ["default", "work"])
        defer { clearRoutedLink() }
        await appState.routeLinkedSession("work-chat", toProfile: "ghost")
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("That chat is no longer available."))
        XCTAssertNotEqual(PushNotificationService.shared.pendingTarget?.sessionId, "work-chat")
    }

    func testLinkToAProfileNewerThanTheSavedListOpensOnceTheListIsRead() async throws {
        let appState = try makeLinkAppState(listedOnHost: ["default", "work", "Research"])
        defer { clearRoutedLink() }
        await appState.routeLinkedSession("work-chat", toProfile: "research")
        XCTAssertNil(appState.errorMessage)
        XCTAssertEqual(PushNotificationService.shared.pendingTarget?.profile, "Research")
        XCTAssertEqual(PushNotificationService.shared.pendingTarget?.sessionId, "work-chat")
    }

    func testLinkToAnUnlistedProfileWhileOfflineSaysSo() async throws {
        for appState in [try makeLinkAppState(), try makeLinkAppState(hostListFails: true)] {
            defer { clearRoutedLink() }
            await appState.routeLinkedSession("work-chat", toProfile: "research")
            XCTAssertEqual(
                appState.errorMessage,
                AppLocalization.string("Conduit isn't connected to Hermes right now. It reconnects on its own, so try again in a moment.")
            )
            XCTAssertNotEqual(PushNotificationService.shared.pendingTarget?.sessionId, "work-chat")
        }
    }

    func testLinkNamingTheProfileInUseStaysOnIt() throws {
        let appState = try makeLinkAppState()
        defer { clearRoutedLink() }
        appState.openAppLink(.session(id: "work-chat", profile: "default"))
        XCTAssertNotEqual(PushNotificationService.shared.pendingTarget?.sessionId, "work-chat")
        XCTAssertEqual(appState.activeProfile, "default")
    }

    /// Conduit on the default profile of a dashboard that also lists "work".
    /// With `listedOnHost` it is connected, and reading the host's profile
    /// list returns those names; with `hostListFails` it is connected and
    /// the read fails.
    private func makeLinkAppState(listedOnHost: [String]? = nil, hostListFails: Bool = false) throws -> AppState {
        let suite = "ConduitExternalLink.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var loader: (@MainActor () async throws -> [String: Any])?
        if hostListFails {
            loader = { throw URLError(.timedOut) }
        } else if let listedOnHost {
            loader = { ["profiles": listedOnHost] }
        }
        let appState = AppState(defaults: defaults, loadSavedConnection: false, profileDiscoveryLoader: loader)
        appState.profiles = ["default", "work"]
        if loader != nil {
            appState.installDashboardTicketBridgeForTesting(DashboardTicketBridge(
                baseURL: "https://links.example",
                pendingRequests: DashboardTicketBridgePendingRequests(),
                readinessPollAttempts: 0,
                readinessPollInterval: .milliseconds(1)
            ))
            appState.isConnected = true
        }
        return appState
    }

    /// Clears a link these tests routed, so it can't reach another test.
    private func clearRoutedLink() {
        if let target = PushNotificationService.shared.pendingTarget, target.sessionId == "work-chat" {
            PushNotificationService.shared.clearPendingTarget(target)
        }
    }

    func testExternalLinkSchemeIsRegistered() throws {
        let types = try XCTUnwrap(Bundle(for: AppState.self).object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(ConduitAppLink.scheme))
    }
}
