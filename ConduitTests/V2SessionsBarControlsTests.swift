//
//  V2SessionsBarControlsTests.swift
//  Conduit
//
//  Settings > Appearance > Sessions bar (issue #2012): the four preferences
//  and the resolve step that turns them, the stored Sessions/Projects page
//  and Pulse's own capability into what the bar shows. In an extension of
//  SidebarLayoutTests, so the test planner sees no new class.
//

import XCTest
@testable import Conduit

extension SidebarLayoutTests {
    func testSessionsBarUntouchedDefaultsKeepTodaysBar() {
        withSessionsBarDefaults { defaults in
            XCTAssertEqual(
                resolveSessionsBar(defaults),
                V2SessionsBarControls(
                    profiles: .all,
                    showsProjects: true,
                    showsPulse: true,
                    showsArtifacts: true,
                    presentation: .sessions
                )
            )
        }
    }

    /// The preference decodes to its own case; which chip that draws is the
    /// bar's business and a device check.
    func testSessionsBarCurrentOnlyDecodesTheStoredValue() {
        withSessionsBarDefaults { defaults in
            defaults.set("current", forKey: V2SessionsBarPreferences.Profiles.key)
            XCTAssertEqual(resolveSessionsBar(defaults).profiles, .currentOnly)
        }
    }

    func testSessionsBarUnknownProfilesPreferenceFallsBackToAll() {
        withSessionsBarDefaults { defaults in
            defaults.set("future", forKey: V2SessionsBarPreferences.Profiles.key)
            XCTAssertEqual(resolveSessionsBar(defaults).profiles, .all)
        }
    }

    func testSessionsBarHiddenProjectsResolveAStoredProjectsPageToSessions() {
        withSessionsBarDefaults { defaults in
            defaults.set("projects", forKey: V2ChatsView.presentationKey)
            defaults.set(false, forKey: V2SessionsBarPreferences.showsProjectsKey)
            let controls = resolveSessionsBar(defaults)
            XCTAssertFalse(controls.showsProjects)
            XCTAssertEqual(controls.presentation, .sessions)
            // Resolution is read-only: a stale or another window's write is safe too.
            XCTAssertEqual(defaults.string(forKey: V2ChatsView.presentationKey), "projects")
        }
    }

    func testSessionsBarVisibleProjectsKeepAStoredProjectsPage() {
        withSessionsBarDefaults { defaults in
            defaults.set("projects", forKey: V2ChatsView.presentationKey)
            defaults.set(true, forKey: V2SessionsBarPreferences.showsProjectsKey)
            XCTAssertEqual(resolveSessionsBar(defaults).presentation, .projects)
        }
    }

    func testSessionsBarAllProfilesAlwaysShowsSessions() {
        withSessionsBarDefaults { defaults in
            defaults.set("projects", forKey: V2ChatsView.presentationKey)
            defaults.set(true, forKey: V2SessionsBarPreferences.showsProjectsKey)
            XCTAssertEqual(resolveSessionsBar(defaults, allProfilesChatsOn: true).presentation, .sessions)
        }
    }

    func testSessionsBarUnknownPresentationFallsBackToSessions() {
        withSessionsBarDefaults { defaults in
            defaults.set("future", forKey: V2ChatsView.presentationKey)
            XCTAssertEqual(resolveSessionsBar(defaults).presentation, .sessions)
        }
    }

    func testSessionsBarPulsePreferenceCannotEnableAnUnavailableScreen() {
        withSessionsBarDefaults { defaults in
            defaults.set(true, forKey: V2SessionsBarPreferences.showsPulseKey)
            XCTAssertFalse(resolveSessionsBar(defaults, pulseAvailable: false).showsPulse)
        }
    }

    func testSessionsBarPulseCanBeHiddenWhenAvailable() {
        withSessionsBarDefaults { defaults in
            defaults.set(false, forKey: V2SessionsBarPreferences.showsPulseKey)
            XCTAssertFalse(resolveSessionsBar(defaults).showsPulse)
        }
    }

    func testSessionsBarArtifactsCanBeHiddenWithoutHidingOtherControls() {
        withSessionsBarDefaults { defaults in
            defaults.set(false, forKey: V2SessionsBarPreferences.showsArtifactsKey)
            let controls = resolveSessionsBar(defaults)
            XCTAssertFalse(controls.showsArtifacts)
            XCTAssertTrue(controls.showsProjects)
            XCTAssertTrue(controls.showsPulse)
        }
    }

    /// Greptile's P1 on #2020: with Current only on and All chats off the bar
    /// draws no All chip, so this row is the only way into All. It stays out
    /// while All is already on (that sheet carries the way back) and while
    /// All isn't offered at all, one profile being nothing to list together.
    func testSessionsBarAllChatsRowIsTheWayInUnderCurrentOnly() {
        XCTAssertTrue(V2SessionsBarControls.showsAllChatsRow(
            profiles: .currentOnly, allProfilesChatsOn: false, allProfilesAvailable: true))
        XCTAssertFalse(V2SessionsBarControls.showsAllChatsRow(
            profiles: .currentOnly, allProfilesChatsOn: true, allProfilesAvailable: true))
        XCTAssertFalse(V2SessionsBarControls.showsAllChatsRow(
            profiles: .currentOnly, allProfilesChatsOn: false, allProfilesAvailable: false))
        XCTAssertFalse(V2SessionsBarControls.showsAllChatsRow(
            profiles: .all, allProfilesChatsOn: false, allProfilesAvailable: true))
    }

    /// Its mirror in the All-profiles sheet, the only way back to one profile
    /// while All is on under Current only.
    func testSessionsBarShowOnlyRowIsTheWayOutUnderCurrentOnly() {
        XCTAssertTrue(V2SessionsBarControls.showsShowOnlyRow(
            profiles: .currentOnly, allProfilesChatsOn: true))
        XCTAssertFalse(V2SessionsBarControls.showsShowOnlyRow(
            profiles: .currentOnly, allProfilesChatsOn: false))
        XCTAssertFalse(V2SessionsBarControls.showsShowOnlyRow(
            profiles: .all, allProfilesChatsOn: true))
    }

    /// The list's write-back: a stored Projects page goes to Sessions once it
    /// sees Projects hidden, and only then. Showing Projects again starts on
    /// Sessions instead of resurrecting the page the user was moved off.
    func testSessionsBarStoredProjectsPageIsClearedOnceProjectsIsHidden() {
        XCTAssertTrue(V2SessionsBarControls.hidesStoredProjectsPage("projects", showsProjects: false))
        XCTAssertFalse(V2SessionsBarControls.hidesStoredProjectsPage("projects", showsProjects: true))
        XCTAssertFalse(V2SessionsBarControls.hidesStoredProjectsPage("sessions", showsProjects: false))
        XCTAssertFalse(V2SessionsBarControls.hidesStoredProjectsPage(nil, showsProjects: false))
    }

    /// The switch's own write, so a sequence the list can't see (off and on
    /// again while another tab or a chat covers it) still starts on Sessions
    /// when Projects comes back. Sync applies the same clear (DeepSeek, #2020).
    func testSessionsBarHidingProjectsClearsTheStoredPageAtTheWrite() {
        withSessionsBarDefaults { defaults in
            defaults.set("projects", forKey: V2ChatsView.presentationKey)
            V2SessionsBarControls.clearStoredProjectsPage(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: V2ChatsView.presentationKey), "sessions")

            defaults.set(false, forKey: V2SessionsBarPreferences.showsProjectsKey)
            V2SessionsBarControls.clearStoredProjectsPage(defaults: defaults)
            defaults.set(true, forKey: V2SessionsBarPreferences.showsProjectsKey)
            let controls = resolveSessionsBar(defaults)
            XCTAssertTrue(controls.showsProjects)
            XCTAssertEqual(controls.presentation, .sessions)
        }
    }

    /// Clearing is only ever the Projects page: a Sessions page, or none, stays
    /// as it is.
    func testSessionsBarClearingTheStoredPageLeavesOtherPagesAlone() {
        withSessionsBarDefaults { defaults in
            defaults.set("sessions", forKey: V2ChatsView.presentationKey)
            V2SessionsBarControls.clearStoredProjectsPage(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: V2ChatsView.presentationKey), "sessions")

            defaults.removeObject(forKey: V2ChatsView.presentationKey)
            V2SessionsBarControls.clearStoredProjectsPage(defaults: defaults)
            XCTAssertNil(defaults.string(forKey: V2ChatsView.presentationKey))
        }
    }

    /// The strip's own decision, so a regression that draws every chip under
    /// Current only fails a test rather than a device check.
    func testSessionsBarCurrentOnlyDrawsOneChip() {
        XCTAssertEqual(V2SessionsBarControls.stripStyle(profiles: .currentOnly, allChipDrawn: true), .allChip)
        XCTAssertEqual(V2SessionsBarControls.stripStyle(profiles: .currentOnly, allChipDrawn: false), .singleChip)
        XCTAssertEqual(V2SessionsBarControls.stripStyle(profiles: .all, allChipDrawn: true), .strip)
        XCTAssertEqual(V2SessionsBarControls.stripStyle(profiles: .all, allChipDrawn: false), .strip)
    }

    /// A throwaway defaults store, so a test never reads or writes the test
    /// host's own preferences.
    private func withSessionsBarDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "V2SessionsBarControlsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("No defaults store for \(suite)")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func resolveSessionsBar(
        _ defaults: UserDefaults,
        pulseAvailable: Bool = true,
        allProfilesChatsOn: Bool = false
    ) -> V2SessionsBarControls {
        V2SessionsBarControls.resolve(
            defaults: defaults,
            pulseAvailable: pulseAvailable,
            allProfilesChatsOn: allProfilesChatsOn
        )
    }
}
