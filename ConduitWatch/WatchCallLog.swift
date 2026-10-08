//
//  WatchCallLog.swift
//  Conduit Watch
//
//  The Watch side of the call log: every event is a JSON line kept on the
//  Watch and also sent to the iPhone (queued, so it arrives even when the
//  iPhone isn't reachable right now), where Voice settings > Apple Watch
//  can share it for a support question. Kept to its newest megabyte.
//

import Foundation
import WatchConnectivity

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

    private init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        fileURL = directory?.appendingPathComponent("watch-call-log.jsonl")
        if let directory {
            // The proof of concept's log, which nothing reads any more.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("watch-probe.jsonl"))
        }
        if let fileURL { WatchVoiceStats.trimLog(at: fileURL, maxBytes: Self.maxFileBytes) }
    }

    /// Records one event, here and in the iPhone's log.
    func note(_ event: String, _ fields: [String: Any] = [:]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "watch"
        let line = WatchVoiceStats.jsonLine(fields)
        append(line)
        sendToPhone(.note(line))
    }

    /// Records a call's summary, which the iPhone also lists.
    func report(_ event: String, _ fields: [String: Any]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "watch"
        let line = WatchVoiceStats.jsonLine(fields)
        append(line)
        sendToPhone(.report(line))
    }

    private func sendToPhone(_ message: WatchVoiceWire.Message) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(WatchVoiceWire.encode(message))
    }

    func clear() {
        firstLineNumber += lines.count
        lines = []
        bytesSinceTrim = 0
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
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
