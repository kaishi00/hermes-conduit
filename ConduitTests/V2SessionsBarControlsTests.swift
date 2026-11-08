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
