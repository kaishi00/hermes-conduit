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

    func testSiriTakesTheHandsFreeProfileOnlyWhenTheShortcutNamesNone() {
        let siri = PendingVoiceIntent(profile: nil, startsFreshConversation: true, source: .siri)
        XCTAssertEqual(AppState.applyingHandsFreeProfile("personal", to: siri).profile, "personal")
        XCTAssertNil(AppState.applyingHandsFreeProfile(nil, to: siri).profile, "none picked: the iPhone's, as before")
        let named = PendingVoiceIntent(profile: "work", startsFreshConversation: true, source: .siri)
        XCTAssertEqual(AppState.applyingHandsFreeProfile("personal", to: named).profile, "work", "a named profile wins")
        let composer = PendingVoiceIntent(profile: nil, startsFreshConversation: false, source: .composer)
        XCTAssertNil(AppState.applyingHandsFreeProfile("personal", to: composer).profile, "a start on the iPhone's screen is left alone")
    }

    func testAWatchCallStartsOnTheHandsFreeProfileAndAnAnsweredOneOnItsCallers() {
        let profiles = ["default", "work", "Personal"]
        func profile(answers: Bool, caller: String? = nil, onActive: Bool = true) -> String {
            AppState.watchCallProfile(answers: answers, callerProfile: caller, callerOnActiveDashboard: onActive,
                                      handsFree: "Personal", active: "work", profiles: profiles)
        }
        XCTAssertEqual(profile(answers: false), "Personal")
        XCTAssertEqual(profile(answers: true, caller: "default"), "default", "the profile that called")
        XCTAssertEqual(profile(answers: true, caller: "PERSONAL"), "Personal", "in the dashboard's spelling")
        XCTAssertEqual(profile(answers: true, caller: nil), "work", "a push naming none is the iPhone's")
        XCTAssertEqual(profile(answers: true, caller: "default", onActive: false), "work", "another dashboard's caller")
    }

    func testASwitchOnTheIPhoneEndsAWatchCallOnAnotherProfile() {
        let call = WatchDirectConnection(profile: "personal", dashboard: "d1", phoneProfile: "work")
        XCTAssertTrue(AppState.watchConnection(call, isCurrentOn: "d1", phoneProfile: "work"))
        XCTAssertFalse(AppState.watchConnection(call, isCurrentOn: "d1", phoneProfile: "personal"),
                       "the iPhone's switch resets the jobs it runs for the call")
        XCTAssertFalse(AppState.watchConnection(call, isCurrentOn: "d2", phoneProfile: "work"))
        let stored = WatchDirectConnection(profile: "work", dashboard: "d1")
        XCTAssertTrue(AppState.watchConnection(stored, isCurrentOn: "d1", phoneProfile: "work"),
                      "a call stored before calls had their own profile")
    }

    func testAWatchCallOnAnotherProfileRunsItsJobsAndItsChatThere() async {
        let fake = FakeVoiceJobBackend()
        fake.profileTargets["personal"] = .other("personal")
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base, callProfile: "personal")

        _ = await watch.startJob(instructions: "add milk to the shopping list", profile: nil, joinsCall: true, onJobCreated: nil)
        XCTAssertEqual(fake.createdProfiles, ["personal"], "the call's profile, not the iPhone's")
        XCTAssertEqual(fake.createdCallsModel, [true], "on that profile's voice-job model")
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
        XCTAssertEqual(fake.createdCallsModel, [false])
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

    func testOnlyTheWatchCallsOwnJobsTakeItsVoiceJobModel() async {
        let fake = FakeVoiceJobBackend()
        fake.profileTargets["personal"] = .other("personal")
        fake.profileTargets["work"] = .other("work")
        let base = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base, callProfile: "personal")

        _ = await watch.startJob(instructions: "check my calendar", profile: "work", joinsCall: false, onJobCreated: nil)
        // The iPhone's own call naming the Watch call's profile.
        _ = await base.startJob(instructions: "add milk", profile: "personal")
        XCTAssertEqual(fake.createdProfiles, ["work", "personal"])
        XCTAssertEqual(fake.createdCallsModel, [false, false], "named work, and the iPhone's calls, run on the profile's own model")
    }

    func testAWatchCallOnAnotherProfileFindsAndReadsThatProfilesChats() async {
        let fake = FakeVoiceJobBackend()
        var backend = fake.backend
        let log = HandsFreeChatLog()
        backend.searchChats = { _, profile in
            log.searched.append(profile)
            return [VoiceChatMatch(sessionID: "s-1", title: "Router", snippet: "", lastActive: nil)]
        }
        backend.readChat = { _, profile in
            log.read.append(profile)
            return VoiceResumeContext(summary: "About the router.", recent: [])
        }
        let base = VoiceBackgroundJobSupervisor(backend: backend, pollInterval: .seconds(3_600), threadWaitInterval: .milliseconds(5))
        let watch = WatchCallJobSupervisor(base, callProfile: "personal")

        _ = await watch.findChats(query: "router", retryingWords: false)
        _ = await watch.readFoundChat("1")
        _ = await base.findChats(query: "router", retryingWords: false)
        _ = await base.readFoundChat("1")
        XCTAssertEqual(log.searched, ["personal", nil], "the iPhone's own call searches the profile it is on")
        XCTAssertEqual(log.read, ["personal", nil])
    }

    func testTheHandsFreeChoiceIsSavedPerDashboard() {
        let suite = "HandsFreeProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = UUID(), office = UUID()
        XCTAssertNil(AppState.handsFreeProfileChoice(in: defaults, dashboard: home))
        XCTAssertTrue(AppState.storeHandsFreeProfileChoice("  personal ", in: defaults, dashboard: home))
        XCTAssertEqual(AppState.handsFreeProfileChoice(in: defaults, dashboard: home), "personal")
        XCTAssertNil(AppState.handsFreeProfileChoice(in: defaults, dashboard: office), "another server keeps its own")
        XCTAssertFalse(AppState.storeHandsFreeProfileChoice("personal", in: defaults, dashboard: home), "unchanged")
        XCTAssertTrue(AppState.storeHandsFreeProfileChoice(" ", in: defaults, dashboard: home))
        XCTAssertNil(AppState.handsFreeProfileChoice(in: defaults, dashboard: home), "blank follows the iPhone again")
    }

    func testTheWatchsProfileNamesTreatTheCallsProfileAsItsOwn() {
        let suite = "HandsFreeProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.profiles = ["default", "personal"]
        let onPhone = appState.watchJobProfileNames()
        XCTAssertTrue(onPhone.contains { $0.profile == nil && $0.names == ["default"] })
        XCTAssertTrue(onPhone.contains { $0.profile == "personal" && $0.names == ["personal"] })
        let elsewhere = appState.watchJobProfileNames(callProfile: "personal")
        XCTAssertTrue(elsewhere.contains { $0.profile == nil && $0.names == ["personal"] }, "the call's own profile")
        XCTAssertTrue(elsewhere.contains { $0.profile == "default" && $0.names == ["default"] }, "the iPhone's own is named like any other")
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

private final class HandsFreeChatLog {
    var searched: [String?] = []
    var read: [String?] = []
}
