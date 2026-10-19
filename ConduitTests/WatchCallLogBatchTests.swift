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

    func testWatchCallTimersTolerateATenthOfASecondOrLongerInterval() {
        XCTAssertEqual(WatchVoiceMain.tolerance(for: 0.1), 0)
        XCTAssertEqual(WatchVoiceMain.tolerance(for: 1), 0.1, accuracy: 1e-9)
        XCTAssertEqual(WatchVoiceMain.tolerance(for: 20), 2, accuracy: 1e-9)
        let timer = WatchVoiceMain.timer(every: 30, repeats: false) { _ in }
        defer { timer.invalidate() }
        XCTAssertEqual(timer.tolerance, 3, accuracy: 1e-9)
    }
}
