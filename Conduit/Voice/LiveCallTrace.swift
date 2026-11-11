//
//  LiveCallTrace.swift
//  Conduit
//
//  The last Grok Live, Qwen Live or Local Live call's steps: the session setup, the
//  microphone and the turn detection the server applied, when it heard the
//  user start and stop with the microphone's levels (#1418), which functions
//  xAI took, each function call by name and how it was answered, and tool
//  markup cut from a spoken reply. Gateway Diagnostics shows it under the
//  connection timeline and copies it with it.
//  A GPT-Live call's steps are its setup (#1611): what the session request
//  carried, what the host says it applied, session.started, a briefing or
//  opening sent after the start, who spoke first, drops and error codes.
//
//  The last Read Aloud reading has a trace of its own (`readAloud`, issue
//  1641): which voice read it, how its text was split, why each sentence
//  ended, route changes and how playback ended.
//
//  Event kinds, levels and function names only: never what the user or the
//  model said, a call's arguments, or a tool's answer.
//

import Foundation
import OSLog

private let liveCallTraceLogger = Logger(subsystem: "com.milim.relay", category: "LiveCallTrace")

@MainActor
final class LiveCallTrace {
    static let shared = LiveCallTrace()
    /// The last Read Aloud reading (issue 1641). Its steps are taken only
    /// while the reading runs: the iPhone voice and the playback service
    /// it notes from serve Classic and the speech test too.
    static let readAloud = LiveCallTrace(noun: "")
    static let maximumSteps = 200
    /// The call's first steps (its setup and microphone) are always kept;
    /// past the cap, the oldest after them make way for the newest, so a
    /// late turn that never ends is still there (#1418).
    static let keptFirstSteps = 20

    private(set) var name: String?
    /// What one run is called in the report ("Last Grok Live call").
    private let noun: String
    /// Steps are taken from `begin` until `end`.
    private(set) var isOpen = false
    /// Which run is open, counted by `begin`: a speech stream keeps the one
    /// it was opened in, so a stream a stopped reading left behind never
    /// notes into the next one.
    private(set) var run = 0
    private var startedAt = Date()
    private(set) var steps: [String] = []
    private var droppedSteps = 0

    init(noun: String = "call") {
        self.noun = noun
    }

    /// A call starts: a new trace.
    func begin(_ name: String, at date: Date = Date(), first label: String? = nil) {
        self.name = name
        startedAt = date
        steps = []
        droppedSteps = 0
        run += 1
        isOpen = true
        note(label ?? "Starting \(noun)", at: date)
    }

    /// The run is over: its last step, and later notes are left out.
    func end(_ label: String, at date: Date = Date()) {
        note(label, at: date)
        isOpen = false
    }

    /// A step of `run` only, when given: nothing once another run began.
    func note(_ label: String, run: Int? = nil, at date: Date = Date()) {
        guard name != nil, isOpen, run == nil || run == self.run else { return }
        if steps.count >= Self.maximumSteps {
            steps.remove(at: Self.keptFirstSteps)
            droppedSteps += 1
        }
        steps.append("+\(String(format: "%.1f", max(0, date.timeIntervalSince(startedAt))))s \(label)")
        liveCallTraceLogger.notice("\(self.name ?? "", privacy: .public) trace: \(label, privacy: .public)")
    }

    /// The copyable report, nil before any call.
    var report: String? {
        guard let name else { return nil }
        var lines = ["Last \(noun.isEmpty ? name : "\(name) \(noun)"): steps"] + steps
        if droppedSteps > 0 { lines.insert("… \(droppedSteps) steps not kept", at: 1 + Self.keptFirstSteps) }
        return lines.joined(separator: "\n")
    }
}
