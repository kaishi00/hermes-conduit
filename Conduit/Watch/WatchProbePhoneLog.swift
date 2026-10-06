//
//  WatchProbePhoneLog.swift
//  Conduit
//
//  The Apple Watch proof of concept's test log on the iPhone
//  (designs/apple-watch-voice.md): the iPhone's own events and the
//  results the Watch sends over, as JSON lines in one file that Voice
//  settings can share.
//

import Foundation

@MainActor
final class WatchProbePhoneLog: ObservableObject {
    static let shared = WatchProbePhoneLog()

    /// The newest result lines, for Voice settings.
    @Published private(set) var summaries: [String] = []
    let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("WatchProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("conduit-watch-test-log.jsonl")
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

    /// A finished result: logged and shown in Voice settings.
    func summary(_ event: String, _ fields: [String: Any]) {
        var fields = fields
        fields["event"] = event
        fields["side"] = "phone"
        let line = WatchVoiceStats.jsonLine(fields)
        append(line)
        remember(line)
    }

    /// A result line the Watch sent.
    func watchReport(_ line: String) {
        append(line)
        remember(line)
    }

    func clear() {
        summaries = []
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    private func remember(_ line: String) {
        summaries.append(line)
        if summaries.count > 30 { summaries.removeFirst(summaries.count - 30) }
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
    }
}
