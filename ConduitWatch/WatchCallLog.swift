//
//  WatchCallLog.swift
//  Conduit Watch
//
//  The Watch side of the call log: every event is a JSON line kept on the
//  Watch and also sent to the iPhone (queued, so it arrives even when the
//  iPhone isn't reachable right now), where Voice settings > Apple Watch
//  can share it for a support question. Kept to its newest megabyte.
//  Lines go to the iPhone in batches (WatchCallLogBatch), kept in a file
//  of their own until sent, so a batch outlives the app. While they
//  can't be sent, the batch's budget bounds them in memory, in that file
//  and when the next run restores them.
//

import Foundation
import WatchConnectivity
import WatchKit

@MainActor
final class WatchCallLog: ObservableObject {
    static let shared = WatchCallLog()

    @Published private(set) var lines: [String] = []
    /// The running number of `lines[0]`, so each line keeps one identity
    /// as newer lines arrive and older ones are dropped.
    private(set) var firstLineNumber = 0
    private let fileURL: URL?
    private static let keptLines = 300
    private static let maxFileBytes = 1_000_000
    /// Bytes written since the file was last trimmed: it is trimmed again
    /// after another eighth of its cap.
    private var bytesSinceTrim = 0
    /// Lines on their way to the iPhone, and the send due for them.
    private var batch: WatchCallLogBatch
    private var batchTimer: Timer?
    /// The batch's lines on disk until they are sent: the app can be
    /// stopped or suspended with some waiting.
    private let unsentURL: URL?
    /// The unsent file's size: once lines appended to it pass twice the
    /// batch's budget, it is written again from the batch.
    private var unsentFileBytes = 0

    private init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        fileURL = directory?.appendingPathComponent("watch-call-log.jsonl")
        unsentURL = directory?.appendingPathComponent("watch-call-log-unsent.jsonl")
        // What a previous run didn't send: the newest of it, sent once the
        // link is up (WatchLink).
        let unsentText = unsentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let unsent = unsentText.map(WatchCallLogBatch.lines(in:)) ?? []
        batch = WatchCallLogBatch(restoring: unsent)
        unsentFileBytes = unsentText?.utf8.count ?? 0
        if let directory {
            // The proof of concept's log, which nothing reads any more.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("watch-probe.jsonl"))
        }
        if let fileURL { WatchVoiceStats.trimLog(at: fileURL, maxBytes: Self.maxFileBytes) }
        if batch.lines != unsent { saveUnsent() }
        // A suspended app's timer doesn't fire: what waits goes first
        // (and again from the app's scene phase, ConduitWatchApp).
        NotificationCenter.default.addObserver(
            forName: WKApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WatchCallLog.shared.sendBatch() }
        }
    }

    /// Records one event, here and in the iPhone's log.
    func note(_ event: String, _ fields: [String: Any] = [:]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "watch"
        let line = WatchVoiceStats.jsonLine(fields)
        append(line)
        let action = batch.add(line, at: ProcessInfo.processInfo.systemUptime)
        appendUnsent(line)
        switch action {
        case .sendNow:
            sendBatch()
        case .sendAfter(let delay):
            batchTimer?.invalidate()
            batchTimer = WatchVoiceMain.timer(every: delay, repeats: false) { _ in
                MainActor.assumeIsolated { WatchCallLog.shared.sendBatch() }
            }
        case .wait:
            break
        }
    }

    /// Records a call's summary, which the iPhone also lists.
    func report(_ event: String, _ fields: [String: Any]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "watch"
        let line = WatchVoiceStats.jsonLine(fields)
        append(line)
        // The call is over: its lines go too, ahead of the summary, and
        // those of its teardown right after it.
        sendBatch()
        batch.callEnded(at: ProcessInfo.processInfo.systemUptime)
        sendToPhone(.report(line))
    }

    /// Sends the lines waiting for the iPhone, a transfer for each
    /// message's worth. Until the link is up they keep waiting.
    func sendBatch() {
        batchTimer?.invalidate()
        batchTimer = nil
        let sent = batch.drain(deliverable: Self.canSend) { text in
            sendToPhone(.note(text))
        }
        if sent { saveUnsent() }
    }

    private static var canSend: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
    }

    private func sendToPhone(_ message: WatchVoiceWire.Message) {
        guard Self.canSend else { return }
        WCSession.default.transferUserInfo(WatchVoiceWire.encode(message))
    }

    func clear() {
        firstLineNumber += lines.count
        lines = []
        bytesSinceTrim = 0
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        batchTimer?.invalidate()
        batchTimer = nil
        batch = WatchCallLogBatch()
        saveUnsent()
    }

    private func appendUnsent(_ line: String) {
        guard let unsentURL, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: unsentURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: unsentURL)
        }
        unsentFileBytes += data.count
        if unsentFileBytes > WatchCallLogBatch.maxWaitingBytes * 2 { saveUnsent() }
    }

    /// The unsent file holds what the batch still holds.
    private func saveUnsent() {
        guard let unsentURL else { return }
        if batch.isEmpty {
            try? FileManager.default.removeItem(at: unsentURL)
            unsentFileBytes = 0
        } else {
            let data = (batch.lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
            try? data.write(to: unsentURL, options: .atomic)
            unsentFileBytes = data.count
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > Self.keptLines {
            let dropped = lines.count - Self.keptLines
            firstLineNumber += dropped
            lines.removeFirst(dropped)
        }
        guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
        bytesSinceTrim += data.count
        if bytesSinceTrim >= Self.maxFileBytes / 8 {
            bytesSinceTrim = 0
            WatchVoiceStats.trimLog(at: fileURL, maxBytes: Self.maxFileBytes)
        }
    }
}
