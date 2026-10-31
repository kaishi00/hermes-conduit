//
//  HandsFreeProfileTests.swift
//  ConduitTests
//
//  Calls started away from the iPhone's screen run on the hands-free
//  profile (#1564): a Watch call's jobs run there without the iPhone
//  switching, and a choice the dashboard no longer has follows the iPhone.
//

import XCTest
@testable import Conduit

@MainActor
extension VoiceConversationControllerTests {
    func testTheHandsFreeProfileFollowsTheIPhoneUntilOneIsPicked() {
        let profiles = ["default", "work", "Personal"]
        XCTAssertEqual(AppState.handsFreeProfile(choice: nil, profiles: profiles, active: "work"), "work")
        XCTAssertEqual(AppState.handsFreeProfile(choice: "personal", profiles: profiles, active: "work"), "Personal",
                       "the dashboard's own spelling")
        XCTAssertEqual(AppState.handsFreeProfile(choice: "gone", profiles: profiles, active: "work"), "work",
                       "a profile the dashboard no longer has follows the iPhone")
        XCTAssertEqual(AppState.handsFreeProfile(choice: "personal", profiles: [], active: "work"), "personal",
                       "kept until the list has loaded")
    }

    func testAWatchCallOnAnotherProfileRunsItsJobsAndItsChatThere() async {
        let fake = FakeVoiceJobBackend()
        fake.profileTargets["personal"] = .other("personal")
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base, callProfile: "personal")

        _ = await watch.startJob(instructions: "add milk to the shopping list", profile: nil, joinsCall: true, onJobCreated: nil)
        XCTAssertEqual(fake.createdProfiles, ["personal"], "the call's profile, not the iPhone's")
        XCTAssertEqual(watch.callChat?.runtimeSessionID, "rt-1")
        XCTAssertEqual(watch.callChat?.profile, "personal")

        _ = await watch.startJob(instructions: "and eggs", profile: nil, joinsCall: true, onJobCreated: nil)
        XCTAssertEqual(fake.created, 1, "the next request goes to the same chat")
        XCTAssertEqual(base.jobs.last?.profile, "personal")
        base.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Added.", reasoning: nil))
        guard await waitForHandsFree({ fake.submissions.count == 2 }) else { return }
        XCTAssertEqual(fake.submissions.last?.0, "rt-1")
    }

    func testAWatchCallOnAnotherProfileStillSendsNamedWorkWhereItWasNamed() async {
        let fake = FakeVoiceJobBackend()
        fake.profileTargets["personal"] = .other("personal")
        fake.profileTargets["work"] = .active
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base, callProfile: "personal")

        _ = await watch.startJob(instructions: "check my calendar", profile: "work", joinsCall: false, onJobCreated: nil)
        XCTAssertEqual(fake.createdProfiles, [nil], "work is the profile the iPhone is on")
        XCTAssertNil(watch.callChat, "work kept apart doesn't become the call's chat")
    }

    func testAWatchCallsJobsNamingTheCallsProfileCountAsItsOwn() {
        let base = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend)
        let onPhone = WatchCallJobSupervisor(base)
        XCTAssertTrue(onPhone.isCallsProfile(nil))
        XCTAssertFalse(onPhone.isCallsProfile("personal"))
        let elsewhere = WatchCallJobSupervisor(base, callProfile: "Personal")
        XCTAssertTrue(elsewhere.isCallsProfile("personal"))
        XCTAssertFalse(elsewhere.isCallsProfile(nil))
    }

    private func waitForHandsFree(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if condition() { return true }
        XCTFail("Timed out waiting for the condition", file: file, line: line)
        return false
    }
}
