//
//  WatchCallLogBatch.swift
//  Conduit and the Conduit Watch app
//
//  The Watch's call-log lines on their way to the iPhone. Each queued
//  WatchConnectivity transfer wakes both devices' radios and Conduit on
//  the iPhone, and a call writes a line every few seconds, so the Watch
//  sends them together: about `maxDelay` after the oldest, once enough
//  have piled up, and whenever the call ends or the app leaves the
//  screen. Once a call has ended, its last lines go at once for a while:
//  they come as the app winds down and may be suspended.
//
//  A batch travels as the existing `.note` message, its lines joined by
//  newlines. A log line is one JSON object written without a raw newline
//  (WatchVoiceStats.jsonLine), so an iPhone from before batching, which
//  appends the text as one line, still writes valid JSON lines, and a
//  newer one splits it.
//
//  While the link can't deliver (WatchConnectivity never activated), the
//  lines wait within a budget, here, on disk and when a new run restores
//  them: past it the oldest go, and a first line says how many (#1008).
//

import Foundation

struct WatchCallLogBatch: Equatable {
    /// The oldest waiting line goes out about this long after it came
    /// (its timer's tolerance allows a tenth more).
    static let maxDelay: TimeInterval = 30
    /// A batch this long goes out at once.
    static let maxLines = 50
    /// A batch this big goes out at once: a queued transfer is meant for
    /// small payloads.
    static let maxBytes = 32_000
    /// After a call's summary, lines go at once for this long.
    static let afterCallSpan: TimeInterval = 60
    /// The most lines kept waiting while none can be sent, the dropped
    /// line's included...
    static let maxWaitingLines = 600
    /// ...and their bytes, a newline each.
    static let maxWaitingBytes = 300_000
    /// The event of the first waiting line once older ones were dropped.
    static let droppedEvent = "watchLogDropped"

    /// What the caller does after adding a line.
    enum Action: Equatable {
        /// The batch is full, or a call just ended: send it now.
        case sendNow
        /// The first line of a new batch: send it after `maxDelay`.
        case sendAfter(TimeInterval)
        /// A send is already due for this batch.
        case wait
    }

    private(set) var lines: [String] = []
    private var sendsAtOnceUntil: TimeInterval?

    /// Lines kept from a run that ended before sending them, within the
    /// budget.
    init(restoring lines: [String] = []) {
        self.lines = lines
        keepWithinBudget()
    }

    /// Lines dropped to keep the budget, as the first waiting line says.
    var droppedLines: Int { lines.first.flatMap(Self.droppedCount(in:)) ?? 0 }

    var isEmpty: Bool { lines.isEmpty }

    mutating func add(_ line: String, at now: TimeInterval) -> Action {
        let wasEmpty = lines.isEmpty
        lines.append(line)
        keepWithinBudget()
        if let until = sendsAtOnceUntil, now < until { return .sendNow }
        sendsAtOnceUntil = nil
        if lines.count >= Self.maxLines || Self.bytes(of: lines) >= Self.maxBytes { return .sendNow }
        return wasEmpty ? .sendAfter(Self.maxDelay) : .wait
    }

    /// A call's summary was logged at `now`: its teardown lines that
    /// follow go at once.
    mutating func callEnded(at now: TimeInterval) {
        sendsAtOnceUntil = now + Self.afterCallSpan
    }

    /// The oldest waiting lines that fit one message (`maxLines`,
    /// `maxBytes`, and always at least one), as its text; nil when
    /// nothing waits.
    mutating func take() -> String? {
        guard !lines.isEmpty else { return nil }
        var count = 0
        var bytes = 0
        for line in lines {
            let size = line.utf8.count + 1
            if count > 0, count >= Self.maxLines || bytes + size > Self.maxBytes { break }
            count += 1
            bytes += size
        }
        let text = lines[..<count].joined(separator: "\n")
        lines.removeFirst(count)
        return text
    }

    /// Hands every waiting line to `send`, a message's worth at a time,
    /// when it can be delivered; otherwise they keep waiting. True when
    /// anything was sent.
    @discardableResult
    mutating func drain(deliverable: Bool, _ send: (String) -> Void) -> Bool {
        guard deliverable else { return false }
        var sent = false
        while let text = take() {
            send(text)
            sent = true
        }
        return sent
    }

    /// The lines in a `.note` text: one from an older Watch, several from
    /// a batch.
    static func lines(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func bytes<Lines: Collection>(of lines: Lines) -> Int where Lines.Element == String {
        lines.reduce(0) { $0 + $1.utf8.count + 1 }
    }

    /// Drops the oldest waiting lines past the budget, counting them in
    /// the first line. The newest line always stays.
    private mutating func keepWithinBudget() {
        guard lines.count > Self.maxWaitingLines || Self.bytes(of: lines) > Self.maxWaitingBytes else { return }
        let earlier = lines.first.flatMap(Self.droppedCount(in:))
        var waiting = earlier == nil ? lines[...] : lines.dropFirst()
        var dropped = earlier ?? 0
        var total = Self.bytes(of: waiting)
        // Room for the dropped line at its longest count.
        let marker = Self.droppedLine(Int.max).utf8.count + 1
        while waiting.count > 1, waiting.count + 1 > Self.maxWaitingLines || total + marker > Self.maxWaitingBytes {
            total -= waiting[waiting.startIndex].utf8.count + 1
            waiting = waiting.dropFirst()
            dropped += 1
        }
        lines = (dropped > 0 ? [Self.droppedLine(dropped)] : []) + Array(waiting)
    }

    /// The line that says how many older lines were dropped.
    static func droppedLine(_ count: Int) -> String {
        "{\"event\":\"\(droppedEvent)\",\"lines\":\(count),\"side\":\"watch\"}"
    }

    /// The count in a dropped line; nil for any other line.
    static func droppedCount(in line: String) -> Int? {
        let prefix = "{\"event\":\"\(droppedEvent)\",\"lines\":"
        guard line.hasPrefix(prefix) else { return nil }
        return Int(line.dropFirst(prefix.count).prefix { $0.isNumber })
    }
}
