import XCTest
@testable import Conduit

/// The Watch's call-log lines go to the iPhone in batches
/// (WatchCallLogBatch), and Watch call timers may fire a little late
/// (WatchVoiceMain). An extension of an existing class, so the CI
/// planner's lanes stay within their batch budget.
extension HermesVoiceGatewayTimeoutTests {
    func testWatchCallLogLinesWaitForOneBatch() {
        var batch = WatchCallLogBatch()
        XCTAssertNil(batch.take())
        XCTAssertEqual(batch.add("{\"event\":\"a\"}", at: 0), .sendAfter(WatchCallLogBatch.maxDelay))
        XCTAssertEqual(batch.add("{\"event\":\"b\"}", at: 1), .wait)
        XCTAssertEqual(batch.take(), "{\"event\":\"a\"}\n{\"event\":\"b\"}")
        XCTAssertTrue(batch.isEmpty)
        // A new batch starts its own wait.
        XCTAssertEqual(batch.add("{\"event\":\"c\"}", at: 2), .sendAfter(WatchCallLogBatch.maxDelay))
    }

    func testWatchCallLogAFullBatchGoesAtOnce() {
        var batch = WatchCallLogBatch()
        for index in 1..<WatchCallLogBatch.maxLines {
            XCTAssertNotEqual(batch.add("{\"n\":\(index)}", at: 0), .sendNow)
        }
        XCTAssertEqual(batch.add("{\"n\":50}", at: 0), .sendNow)
        XCTAssertEqual(batch.take().map(WatchCallLogBatch.lines(in:))?.count, WatchCallLogBatch.maxLines)

        // Or a big one.
        let big = "{\"x\":\"" + String(repeating: "a", count: WatchCallLogBatch.maxBytes) + "\"}"
        XCTAssertEqual(batch.add(big, at: 0), .sendNow)
    }

    func testWatchCallLogTeardownLinesGoAtOnceAfterTheSummary() {
        var batch = WatchCallLogBatch()
        batch.callEnded(at: 100)
        XCTAssertEqual(batch.add("{\"event\":\"directEnd\"}", at: 101), .sendNow)
        XCTAssertNotNil(batch.take())
        XCTAssertEqual(batch.add("{\"event\":\"audioStopped\"}", at: 100 + WatchCallLogBatch.afterCallSpan - 1), .sendNow)
        XCTAssertNotNil(batch.take())
        // Later (the next call), lines wait again.
        XCTAssertEqual(batch.add("{\"event\":\"callRequested\"}", at: 100 + WatchCallLogBatch.afterCallSpan), .sendAfter(WatchCallLogBatch.maxDelay))
        XCTAssertEqual(batch.add("{\"event\":\"directCallStart\"}", at: 200), .wait)
    }

    func testWatchCallLogLinesWaitWhileTheLinkIsDownAndOutliveTheApp() {
        var batch = WatchCallLogBatch()
        _ = batch.add("{\"n\":1}", at: 0)
        _ = batch.add("{\"n\":2}", at: 1)
        var sent: [String] = []
        // Not activated: nothing is taken.
        XCTAssertFalse(batch.drain(deliverable: false) { sent.append($0) })
        XCTAssertEqual(batch.lines, ["{\"n\":1}", "{\"n\":2}"])
        XCTAssertEqual(sent, [])

        // A new run restores them, and sends them once it can.
        var restored = WatchCallLogBatch(restoring: batch.lines)
        XCTAssertTrue(restored.drain(deliverable: true) { sent.append($0) })
        XCTAssertEqual(sent, ["{\"n\":1}\n{\"n\":2}"])
        XCTAssertTrue(restored.isEmpty)
    }

    func testWatchCallLogALongBacklogGoesAsSeveralMessages() {
        let backlog = (1...120).map { "{\"n\":\($0)}" }
        var batch = WatchCallLogBatch(restoring: backlog)
        var sent: [String] = []
        batch.drain(deliverable: true) { sent.append($0) }
        XCTAssertEqual(sent.map { WatchCallLogBatch.lines(in: $0).count }, [50, 50, 20])
        XCTAssertEqual(sent.flatMap(WatchCallLogBatch.lines(in:)), backlog)

        // Big lines split by size, and one too big on its own still goes.
        let big = "{\"x\":\"" + String(repeating: "a", count: WatchCallLogBatch.maxBytes / 2) + "\"}"
        var large = WatchCallLogBatch(restoring: [big, big, big])
        sent = []
        large.drain(deliverable: true) { sent.append($0) }
        XCTAssertEqual(sent.count, 3)
        let huge = String(repeating: "b", count: WatchCallLogBatch.maxBytes * 2)
        var single = WatchCallLogBatch(restoring: [huge])
        XCTAssertEqual(single.take(), huge)
    }

    func testWatchCallLogBatchesSplitBackIntoTheirLines() {
        let lines = [
            WatchVoiceStats.jsonLine(["event": "directTimeline", "text": "two\nlines", "at": "now"]),
            WatchVoiceStats.jsonLine(["event": "directTurn", "replyMs": 820, "at": "now"]),
        ]
        // A log line never holds a raw newline, so the batch splits cleanly.
        XCTAssertFalse(lines[0].contains("\n"))
        var batch = WatchCallLogBatch()
        lines.forEach { _ = batch.add($0, at: 0) }
        let text = batch.take() ?? ""
        XCTAssertEqual(WatchCallLogBatch.lines(in: text), lines)
        // An older Watch's single line reads as one.
        XCTAssertEqual(WatchCallLogBatch.lines(in: lines[1]), [lines[1]])
        XCTAssertEqual(WatchCallLogBatch.lines(in: ""), [])
        // The batch travels as the message an older iPhone already reads.
        XCTAssertEqual(WatchVoiceWire.decode(WatchVoiceWire.encode(.note(text))), .note(text))
    }

    /// A typical 5-minute Watch call's lines, at the call models' rates:
    /// its timeline every 5 s for 2 minutes then every 30 s, an audio
    /// reactivation every 25 s, a turn's two lines every 15 s and the
    /// wrist going down or up every 30 s. Sent one by one that's over a
    /// hundred transfers; batched, about a dozen.
    func testWatchCallLogATypicalCallSendsAboutADozenTransfers() {
        var times: [TimeInterval] = Array(repeating: 0, count: 8)
        times += stride(from: 5.0, through: 120, by: 5)
        times += stride(from: 150.0, through: 300, by: 30)
        times += stride(from: 25.0, through: 300, by: 25)
        for turn in stride(from: 15.0, through: 300, by: 15) { times += [turn, turn + 1] }
        for wrist in stride(from: 10.0, through: 300, by: 30) { times += [wrist, wrist] }
        times.sort()

        var batch = WatchCallLogBatch()
        var transfers = 0
        var sendAt: TimeInterval?
        for time in times {
            if let due = sendAt, due <= time, batch.take() != nil {
                transfers += 1
                sendAt = nil
            }
            switch batch.add("{\"t\":\(time)}", at: time) {
            case .sendNow:
                _ = batch.take()
                transfers += 1
                sendAt = nil
            case .sendAfter(let delay):
                sendAt = time + delay
            case .wait:
                break
            }
        }
        // The summary sends what waits, then itself.
        if batch.take() != nil { transfers += 1 }
        transfers += 1
        XCTAssertGreaterThan(times.count + 1, 100)
        XCTAssertLessThanOrEqual(transfers, 13)
    }

    /// While WatchConnectivity never activates, the waiting lines keep to
    /// a budget, here and when the next run restores them, and the first
    /// one says how many older lines went (#1008).
    func testWatchCallLogWaitingLinesKeepToABudgetAndSayWhatWent() {
        var batch = WatchCallLogBatch()
        let extra = 25
        for index in 1...(WatchCallLogBatch.maxWaitingLines + extra) {
            _ = batch.add("{\"n\":\(index)}", at: 0)
        }
        XCTAssertFalse(batch.drain(deliverable: false) { _ in })
        XCTAssertEqual(batch.lines.count, WatchCallLogBatch.maxWaitingLines)
        XCTAssertEqual(batch.droppedLines, extra + 1)
        XCTAssertEqual(batch.lines.first, WatchCallLogBatch.droppedLine(extra + 1))
        XCTAssertEqual(batch.lines.last, "{\"n\":\(WatchCallLogBatch.maxWaitingLines + extra)}")

        // A restored backlog past the budget keeps counting.
        var restored = WatchCallLogBatch(restoring: batch.lines + ["{\"n\":\"a\"}", "{\"n\":\"b\"}"])
        XCTAssertEqual(restored.lines.count, WatchCallLogBatch.maxWaitingLines)
        XCTAssertEqual(restored.droppedLines, extra + 3)

        // Sent, the count goes first and then starts over.
        var sent: [String] = []
        XCTAssertTrue(restored.drain(deliverable: true) { sent.append($0) })
        XCTAssertEqual(sent.first.map(WatchCallLogBatch.lines(in:))?.first, WatchCallLogBatch.droppedLine(extra + 3))
        XCTAssertEqual(restored.droppedLines, 0)
        _ = restored.add("{\"n\":1}", at: 0)
        XCTAssertEqual(restored.lines, ["{\"n\":1}"])
        // The dropped line is a JSON line like the rest.
        let marker = try? JSONSerialization.jsonObject(with: Data(WatchCallLogBatch.droppedLine(7).utf8)) as? [String: Any]
        XCTAssertEqual(marker?["event"] as? String, WatchCallLogBatch.droppedEvent)
        XCTAssertEqual(marker?["lines"] as? Int, 7)

        // Big lines keep to the byte budget, the newest always kept.
        let big = "{\"x\":\"" + String(repeating: "a", count: WatchCallLogBatch.maxWaitingBytes / 4) + "\"}"
        var large = WatchCallLogBatch()
        for _ in 1...6 { _ = large.add(big, at: 0) }
        XCTAssertLessThanOrEqual(large.lines.reduce(0) { $0 + $1.utf8.count + 1 }, WatchCallLogBatch.maxWaitingBytes)
        XCTAssertEqual(large.lines.last, big)
        XCTAssertEqual(large.droppedLines, 3)
        let huge = String(repeating: "b", count: WatchCallLogBatch.maxWaitingBytes * 2)
        let single = WatchCallLogBatch(restoring: [big, huge])
        XCTAssertEqual(single.lines.last, huge)
        XCTAssertEqual(single.droppedLines, 1)
    }

    /// A running Watch call keeps the tail the saved call would keep, and
    /// never drops a line still in use (#1008).
    func testWatchCallTranscriptDropsItsOldestLinesPastTheSavedLimit() {
        let turn = { (text: String) in WatchVoiceWire.DirectTurn(role: .user, text: text, at: Date()) }
        let limit = WatchVoiceWire.DirectTranscript.maxTextBytes
        let quarter = String(repeating: "a", count: limit / 4)
        let turns = (1...6).map { _ in turn(quarter) }
        XCTAssertEqual(WatchVoiceWire.DirectTranscript.overflow(Array(turns.prefix(4))), 0)
        XCTAssertEqual(WatchVoiceWire.DirectTranscript.overflow(turns), 2)
        XCTAssertEqual(WatchVoiceWire.DirectTranscript.overflow(turns, protected: 1), 1)
        XCTAssertEqual(WatchVoiceWire.DirectTranscript.overflow(turns, protected: 0), 0)
        // A newest turn too long on its own stays, for the saved call to clip.
        let long = [turn(quarter), turn(String(repeating: "b", count: limit + 1))]
        XCTAssertEqual(WatchVoiceWire.DirectTranscript.overflow(long), 1)
        XCTAssertEqual(WatchVoiceWire.DirectTranscript.overflow([]), 0)
        // What stays is what the saved call keeps.
        let kept = Array(turns.dropFirst(WatchVoiceWire.DirectTranscript.overflow(turns)))
        XCTAssertEqual(WatchVoiceWire.DirectTranscript.capped(turns).count, kept.count)
    }

    /// A start_job answered as accepted before Hermes refused it: the
    /// refusal follows as news; a job that started doesn't (#1008).
    func testWatchLateJobRefusalFollowsAsNews() {
        typealias Outgoing = GeminiLiveToolBridge.Outgoing
        let refused: [Outgoing] = [.toolResponse(id: "c1", name: "start_job", result: ["status": "not_started", "message": "Too many jobs."], scheduling: .whenIdle)]
        XCTAssertEqual(WatchDirectBroker.jobRefusal(in: refused, answering: "c1"), "Too many jobs.")
        XCTAssertNil(WatchDirectBroker.jobRefusal(in: refused, answering: "c2"))
        let failed: [Outgoing] = [.toolResponse(id: "c1", name: "start_job", result: ["error": "Hermes isn't connected."], scheduling: nil)]
        XCTAssertEqual(WatchDirectBroker.jobRefusal(in: failed, answering: "c1"), "Hermes isn't connected.")
        let started: [Outgoing] = [.toolResponse(id: "c1", name: "start_job", result: ["job_id": "j", "title": "t", "status": "started"], scheduling: nil)]
        XCTAssertNil(WatchDirectBroker.jobRefusal(in: started, answering: "c1"))
        XCTAssertNil(WatchDirectBroker.jobRefusal(in: [], answering: "c1"))
        let moved: [Outgoing] = [.toolResponse(id: "c1", name: "start_job", result: ["error": WatchVoiceStartFailure.connectionChanged], scheduling: nil), .endConversation]
        XCTAssertNil(WatchDirectBroker.jobRefusal(in: moved, answering: "c1"))
        // Only a definite refusal lets a repeat go again.
        XCTAssertTrue(WatchDirectBroker.refusedBeforeStarting(refused, answering: "c1"))
        XCTAssertFalse(WatchDirectBroker.refusedBeforeStarting(failed, answering: "c1"))
        XCTAssertFalse(WatchDirectBroker.refusedBeforeStarting(started, answering: "c1"))
        let text = WatchDirectBroker.lateJobRefusalText("Too many jobs.")
        XCTAssertTrue(text.contains("didn't start after all: Too many jobs."))
        XCTAssertTrue(WatchDirectBroker.lateJobRefusalText("Hermes isn't connected.", definite: false).contains("It may not have started"))
    }

    func testWatchCallTimersTolerateATenthOfASecondOrLongerInterval() {
        XCTAssertEqual(WatchVoiceMain.tolerance(for: 0.1), 0)
        XCTAssertEqual(WatchVoiceMain.tolerance(for: 1), 0.1, accuracy: 1e-9)
        XCTAssertEqual(WatchVoiceMain.tolerance(for: 20), 2, accuracy: 1e-9)
        let timer = WatchVoiceMain.timer(every: 30, repeats: false) { _ in }
        defer { timer.invalidate() }
        XCTAssertEqual(timer.tolerance, 3, accuracy: 1e-9)
    }
}
