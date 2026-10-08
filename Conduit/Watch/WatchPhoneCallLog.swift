//
//  WatchPhoneCallLog.swift
//  Conduit
//
//  The Apple Watch call log on the iPhone: this side's events and the
//  Watch's, as JSON lines in one file that Voice settings > Apple Watch
//  can share for a support question. Never a token or key.
//  Kept to its newest few megabytes.
//

import Foundation

@MainActor
final class WatchPhoneCallLog: ObservableObject {
    static let shared = WatchPhoneCallLog()

    let fileURL: URL
    private static let maxFileBytes = 4_000_000
    /// Bytes written since the file was last trimmed: it is trimmed again
    /// after another eighth of its cap.
    private var bytesSinceTrim = 0

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // The proof of concept's log, which nothing reads any more.
        try? FileManager.default.removeItem(at: base.appendingPathComponent("WatchProbe", isDirectory: true))
        let directory = base.appendingPathComponent("WatchCalls", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("conduit-watch-call-log.jsonl")
        WatchVoiceStats.trimLog(at: fileURL, maxBytes: Self.maxFileBytes)
        // Shared from Voice settings before anything was logged too.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func note(_ event: String, _ fields: [String: Any] = [:]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "phone"
        append(WatchVoiceStats.jsonLine(fields))
    }

    /// A call's summary.
    func summary(_ event: String, _ fields: [String: Any]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "phone"
        let line = WatchVoiceStats.jsonLine(fields)
        append(line)
    }

    /// A call summary the Watch sent.
    func watchReport(_ line: String) {
        append(line)
    }

    /// Any other event line the Watch sent: logged, not shown.
    func watchNote(_ line: String) {
        append(line)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
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
