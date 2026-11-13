//
//  BackgroundProcess.swift
//  Conduit
//
//  A process Hermes started in the background for a chat (a dev server, a
//  watcher, a long build): one `process.list` row (upstream
//  tools/process_registry.py `list_sessions`), shown in the Agents sheet
//  under the delegate agents, as Hermes Desktop's /agents lists both.
//

import Foundation

struct BackgroundProcess: Identifiable, Equatable {
    /// Hermes' process id (the row's `session_id`), what `process.kill` takes.
    let id: String
    let command: String
    let cwd: String?
    let pid: Int?
    /// running, or exited.
    let status: String
    let uptimeSeconds: Int?
    /// The newest output, at most a few lines.
    let output: String

    var isRunning: Bool { status != "exited" }

    init?(_ row: [String: AnyCodable]?) {
        guard let row,
              let id = row["session_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        self.id = id
        command = row["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cwd = row["cwd"]?.stringValue
        pid = row["pid"]?.intValue
        status = row["status"]?.stringValue ?? "running"
        uptimeSeconds = row["uptime_seconds"]?.intValue
        let tail = row["output_tail"]?.stringValue ?? row["output_preview"]?.stringValue ?? ""
        output = Self.lastLines(tail, count: 4)
    }

    init(id: String, command: String, cwd: String? = nil, pid: Int? = nil, status: String = "running", uptimeSeconds: Int? = nil, output: String = "") {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.pid = pid
        self.status = status
        self.uptimeSeconds = uptimeSeconds
        self.output = output
    }

    static func lastLines(_ text: String, count: Int) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }
}
