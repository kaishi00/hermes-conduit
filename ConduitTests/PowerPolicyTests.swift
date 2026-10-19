//
//  PowerPolicyTests.swift
//  Conduit
//
//  Timed reads slow down while nothing changes, and stretch under Low
//  Power Mode and Low Data Mode (PowerPolicy.swift): the Chats list's poll,
//  the open chat's idle check, Tasks and the socket keepalive. They extend
//  ChatSyncTests, whose rules they pace.
//

import Combine
import XCTest
@testable import Conduit

private let lowPower = DeviceConditions(lowPowerMode: true)
private let lowData = DeviceConditions(lowDataMode: true)
private let cellular = DeviceConditions(expensivePath: true)
private let powerStart = Date(timeIntervalSince1970: 1_000_000)

extension ChatSyncTests {

    // MARK: - Conditions and cadence

    func testPowerLowPowerStretchesThreeTimesAndLowDataOrCellularTwice() {
        XCTAssertEqual(DeviceConditions().pollStretch, 1)
        XCTAssertEqual(lowPower.pollStretch, 3)
        XCTAssertEqual(lowData.pollStretch, 2)
        XCTAssertEqual(cellular.pollStretch, 2)
        XCTAssertEqual(
            DeviceConditions(lowPowerMode: true, lowDataMode: true, expensivePath: true).pollStretch, 3,
            "The stretches don't multiply"
        )
    }

    func testPowerAStretchedPollNeverWaitsPastThreeMinutes() {
        XCTAssertEqual(PollCadence.stretched(4, by: lowPower), 12)
        XCTAssertEqual(PollCadence.stretched(60, by: lowPower), 180)
        XCTAssertEqual(PollCadence.stretched(60, by: lowData), 120)
        XCTAssertEqual(PollCadence.stretched(PollCadence.kanbanWhileStreaming, by: lowPower), 180)
        XCTAssertEqual(PollCadence.stretched(4, by: DeviceConditions()), 4)
    }

    func testPowerAFailedReadWaitsUpToHalfAnIntervalMore() {
        XCTAssertEqual(PollCadence.afterFailure(8, random: 0), 8)
        XCTAssertEqual(PollCadence.afterFailure(8, random: 0.5), 10)
        XCTAssertEqual(PollCadence.afterFailure(8, random: 1), 12)
        XCTAssertEqual(PollCadence.afterFailure(8, random: 7), 12, "Out-of-range jitter is clamped")
        XCTAssertEqual(PollCadence.afterFailure(180, random: 1), 180, "Never past the longest poll")
    }

    func testPowerTheKeepaliveStaysUnderASixtySecondProxyLimit() {
        XCTAssertEqual(HermesClient.defaultKeepaliveInterval, 30)
        XCTAssertEqual(HermesClient.defaultBackgroundKeepaliveInterval, 45)
        // The ping goes out at the deadline; even unanswered once, a second
        // one is on the wire before a 60 s idle limit.
        XCTAssertLessThan(HermesClient.defaultBackgroundKeepaliveInterval + HermesClient.keepalivePingTimeout, 60)
    }

    func testPowerABackoffLengthensToItsLastStepAndResets() {
        var backoff = PollBackoff(steps: [4, 8, 15])
        XCTAssertEqual(backoff.interval, 4)
        backoff.lengthen()
        XCTAssertEqual(backoff.interval, 8)
        backoff.lengthen()
        backoff.lengthen()
        XCTAssertEqual(backoff.interval, 15)
        XCTAssertFalse(backoff.isAtShortest)
        backoff.reset()
        XCTAssertTrue(backoff.isAtShortest)
    }

    // MARK: - Chats list pacer

    private func observation(_ registry: Set<String>?, running: Bool = false, catalog: Int = 0) -> ChatListPollPacer.Observation {
        .init(registry: registry, turnRunning: running, catalogGeneration: catalog)
    }

    func testPowerAnUnchangedListBacksOffToAMinute() {
        var pacer = ChatListPollPacer()
        let quiet = observation(["a|rt|idle|4"])
        let waits = (0..<7).map { _ in pacer.next(after: quiet, conditions: DeviceConditions(), random: 0) }
        XCTAssertEqual(waits, [4, 8, 15, 30, 60, 60, 60])
    }

    func testPowerAChangedRegistryOrCatalogGoesBackToFourSeconds() {
        var pacer = ChatListPollPacer()
        for _ in 0..<5 { _ = pacer.next(after: observation(["a|rt|idle|4"]), conditions: DeviceConditions(), random: 0) }
        XCTAssertEqual(pacer.next(after: observation(["a|rt|idle|6"]), conditions: DeviceConditions(), random: 0), 4,
                       "A moved message count")
        XCTAssertEqual(pacer.next(after: observation(["a|rt|idle|6"]), conditions: DeviceConditions(), random: 0), 8)
        XCTAssertEqual(pacer.next(after: observation(["a|rt|idle|6"], catalog: 1), conditions: DeviceConditions(), random: 0), 4,
                       "A catalog read that changed the list")
        XCTAssertEqual(pacer.next(after: observation(["a|rt|idle|6", "new|rt2|starting|0"], catalog: 1),
                                  conditions: DeviceConditions(), random: 0), 4,
                       "A chat started on another device")
    }

    func testPowerARunningTurnKeepsTheListAtFourSeconds() {
        var pacer = ChatListPollPacer()
        let running = observation(["a|rt|working|4"], running: true)
        let waits = (0..<5).map { _ in pacer.next(after: running, conditions: DeviceConditions(), random: 0) }
        XCTAssertEqual(waits, [4, 4, 4, 4, 4])
    }

    func testPowerAResetGoesBackToFourSeconds() {
        var pacer = ChatListPollPacer()
        let quiet = observation([])
        for _ in 0..<6 { _ = pacer.next(after: quiet, conditions: DeviceConditions(), random: 0) }
        pacer.reset()
        XCTAssertEqual(pacer.next(after: quiet, conditions: DeviceConditions(), random: 0), 4)
        XCTAssertEqual(pacer.next(after: quiet, conditions: DeviceConditions(), random: 0), 8)
    }

    func testPowerAFailedRegistryReadBacksOffWithJitter() {
        var pacer = ChatListPollPacer()
        XCTAssertEqual(pacer.next(after: observation(nil), conditions: DeviceConditions(), random: 1), 12, "8 s plus half")
        XCTAssertEqual(pacer.next(after: observation(nil), conditions: DeviceConditions(), random: 0), 15)
        XCTAssertEqual(pacer.next(after: observation(["a|rt|idle|1"]), conditions: DeviceConditions(), random: 0), 4,
                       "The first answer is a change")
        _ = pacer.next(after: observation(["a|rt|idle|1"]), conditions: DeviceConditions(), random: 0)
        _ = pacer.next(after: observation(nil), conditions: DeviceConditions(), random: 0)
        XCTAssertEqual(pacer.next(after: observation(["a|rt|idle|1"]), conditions: DeviceConditions(), random: 0), 30,
                       "A failure in between leaves the last answer to compare with")
    }

    func testPowerLowPowerAndLowDataStretchTheListPoll() {
        var pacer = ChatListPollPacer()
        let quiet = observation([])
        let lowPowerWaits = (0..<6).map { _ in pacer.next(after: quiet, conditions: lowPower, random: 0) }
        XCTAssertEqual(lowPowerWaits, [12, 24, 45, 90, 180, 180])
        pacer.reset()
        let lowDataWaits = (0..<6).map { _ in pacer.next(after: quiet, conditions: lowData, random: 0) }
        XCTAssertEqual(lowDataWaits, [8, 16, 30, 60, 120, 120])
        pacer.reset()
        let running = observation(["a|rt|working|1"], running: true)
        XCTAssertEqual(pacer.next(after: running, conditions: lowPower, random: 0), 12)
    }

    func testPowerOnlyWorkingAndStartingRowsCountAsATurnInProgress() {
        func row(_ status: String) -> LiveSessionStatus {
            LiveSessionStatus(runtimeSessionId: "rt", storedSessionId: "s", status: status)
        }
        XCTAssertTrue(ChatListPollPacer.isTurnRunning(row("working")))
        XCTAssertTrue(ChatListPollPacer.isTurnRunning(row("starting")))
        XCTAssertFalse(ChatListPollPacer.isTurnRunning(row("waiting")), "An approval can wait for hours")
        XCTAssertFalse(ChatListPollPacer.isTurnRunning(row("idle")))
    }

    // MARK: - Open chat idle check

    private func idleLocal(_ id: String = "chat") -> OpenChatLocalTurn {
        OpenChatLocalTurn(sessionID: id, isRunning: false, hasRunningTool: false, ownTexts: ["hi"])
    }

    /// Runs the idle chat's checks for `seconds`, one tick a second, and
    /// returns the times (in seconds from the start) a check was due. Each
    /// due check observes `row(t)`.
    private func idleCheckTimes(
        _ sync: inout OpenChatSync,
        seconds: Int,
        conditions: DeviceConditions = DeviceConditions(),
        row: (Int) -> OpenChatRegistryRow? = { _ in nil }
    ) -> [Int] {
        var due: [Int] = []
        for t in 0...seconds {
            let now = powerStart.addingTimeInterval(TimeInterval(t))
            if sync.checkDue(idleLocal(), now: now, conditions: conditions) {
                due.append(t)
                _ = sync.observe(row(t), snapshotAt: now, local: idleLocal(), now: now, chatVisible: true)
            }
        }
        return due
    }

    func testPowerAnIdleChatChecksLessOftenWhileNothingChanges() {
        var sync = OpenChatSync()
        let times = idleCheckTimes(&sync, seconds: 300, row: { _ in OpenChatRegistryRow(isRunning: false, messageCount: 4) })
        // 15 s once, then 30 s, then every 60 s.
        XCTAssertEqual(Array(times.prefix(6)), [0, 15, 45, 105, 165, 225])
    }

    func testPowerATurnRunningElsewhereKeepsTheIdleCheckAtFifteenSeconds() {
        for conditions in [DeviceConditions(), lowPower, lowData] {
            assertATurnElsewhereIsCheckedEveryFifteenSeconds(conditions)
        }
    }

    private func assertATurnElsewhereIsCheckedEveryFifteenSeconds(_ conditions: DeviceConditions) {
        var sync = OpenChatSync()
        let times = idleCheckTimes(&sync, seconds: 400, conditions: conditions, row: { t in
            // Quiet for two minutes, then another device runs a turn.
            OpenChatRegistryRow(isRunning: t >= 100, messageCount: 4, preview: "another device's prompt")
        })
        // The first check after the turn begins comes at the backed-off
        // pace; from then on, every 15 s.
        let afterRun = Array(times.filter { $0 >= 100 })
        XCTAssertFalse(afterRun.isEmpty)
        let gaps = zip(afterRun.dropFirst(), afterRun).map { $0 - $1 }
        XCTAssertEqual(Set(gaps), [15], "A running turn elsewhere is checked every 15 s so it settles: \(afterRun) \(conditions)")
    }

    func testPowerASendHereOrAReturnToTheChatResetsTheIdleCheck() {
        var sync = OpenChatSync()
        _ = idleCheckTimes(&sync, seconds: 200)
        XCTAssertEqual(sync.idleBackoff.interval, 60)
        sync.noteSentHere()
        XCTAssertEqual(sync.idleBackoff.interval, 15)
        _ = idleCheckTimes(&sync, seconds: 200)
        sync.resetIdlePace()
        XCTAssertEqual(sync.idleBackoff.interval, 15)
    }

    func testPowerLowPowerStretchesTheIdleCheckButNotTheSilentTurnCheck() {
        var sync = OpenChatSync()
        let times = idleCheckTimes(&sync, seconds: 200, conditions: lowPower)
        XCTAssertEqual(Array(times.prefix(3)), [0, 45, 135], "15 s and 30 s, three times longer")

        // A silent turn here is still checked every 8 s.
        var running = OpenChatSync()
        let local = OpenChatLocalTurn(sessionID: "chat", isRunning: true, hasRunningTool: false, ownTexts: ["hi"])
        var due: [Int] = []
        for t in 0...60 where running.checkDue(local, now: powerStart.addingTimeInterval(TimeInterval(t)), conditions: lowPower) {
            due.append(t)
        }
        XCTAssertEqual(due, [20, 28, 36, 44, 52, 60])
    }

    // MARK: - Device conditions monitor

    func testPowerTheMonitorFollowsLowPowerModeAndPublishesOnlyChanges() {
        final class FakeProcessInfo: ProcessInfo {
            var fakeLowPowerMode = false
            override var isLowPowerModeEnabled: Bool { fakeLowPowerMode }
        }
        let center = NotificationCenter()
        let info = FakeProcessInfo()
        let monitor = DeviceConditionsMonitor(processInfo: info, notificationCenter: center)
        monitor.start(watchingPath: false)
        var published = 0
        let watch = monitor.objectWillChange.sink { published += 1 }

        center.post(name: .NSProcessInfoPowerStateDidChange, object: info)
        XCTAssertEqual(published, 0, "An unchanged state publishes nothing")
        info.fakeLowPowerMode = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: info)
        XCTAssertTrue(monitor.current.lowPowerMode)
        XCTAssertEqual(published, 1)

        monitor.update { $0.lowDataMode = true }
        monitor.update { $0.lowDataMode = true }
        XCTAssertEqual(published, 2)
        XCTAssertEqual(monitor.current.pollStretch, 3)
        watch.cancel()
    }

    // MARK: - Tasks

    func testPowerTasksPollAsABackstopWhileTheStreamIsConnected() {
        XCTAssertEqual(KanbanPollingPolicy.boardInterval(streaming: false, conditions: DeviceConditions()), 8_000_000_000)
        XCTAssertEqual(KanbanPollingPolicy.boardInterval(streaming: true, conditions: DeviceConditions()), 60_000_000_000)
        XCTAssertEqual(KanbanPollingPolicy.detailInterval(streaming: false, conditions: DeviceConditions()), 4_000_000_000)
        XCTAssertEqual(KanbanPollingPolicy.detailInterval(streaming: true, conditions: DeviceConditions()), 60_000_000_000)
        XCTAssertEqual(KanbanPollingPolicy.boardInterval(streaming: false, conditions: lowPower), 24_000_000_000)
        XCTAssertEqual(KanbanPollingPolicy.detailInterval(streaming: true, conditions: lowData), 120_000_000_000)
    }

    // MARK: - A wakeable sleep

    func testPowerAWakeCutsTheSleepShort() async {
        let sleep = WakeableSleep()
        let started = Date()
        let task = Task { await sleep.sleep(seconds: 30) }
        while !sleep.isSleeping { await Task.yield() }
        sleep.wake()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        // A wake while nothing sleeps cuts the next sleep short.
        sleep.wake()
        let early = Date()
        await sleep.sleep(seconds: 30)
        XCTAssertLessThan(Date().timeIntervalSince(early), 5)
    }
}
