//
//  WatchProbeLog.swift
//  Conduit Watch
//
//  The Watch side of the test log: every event is a JSON line kept on the
//  Watch, and finished results also go to the iPhone (queued, so they
//  arrive even when the iPhone isn't reachable right now), where the log
//  can be shared.
//

import Foundation
import WatchConnectivity

@MainActor
final class WatchProbeLog: ObservableObject {
    static let shared = WatchProbeLog()

    @Published private(set) var lines: [String] = []
    private let fileURL: URL?
    private static let keptLines = 300

    private init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        fileURL = directory?.appendingPathComponent("watch-probe.jsonl")
    }

    /// Records one event on the Watch.
    func note(_ event: String, _ fields: [String: Any] = [:]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "watch"
        append(WatchVoiceStats.jsonLine(fields))
    }

    /// Records a finished result and sends it to the iPhone's log too.
    func report(_ event: String, _ fields: [String: Any]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "watch"
        let line = WatchVoiceStats.jsonLine(fields)
        append(line)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(WatchVoiceWire.encode(.report(line)))
    }

    func clear() {
        lines = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > Self.keptLines { lines.removeFirst(lines.count - Self.keptLines) }
        guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
