//
//  HermesCallTrace.swift
//  Conduit
//
//  The last call from Hermes, step by step (#449). An answered call that
//  opens no voice leaves no error to show, so Gateway Diagnostics shows
//  where it stopped, under the connection timeline and copied with it.
//  Reconnects and scene changes while it runs are steps on it too, since
//  the call races them.
//
//  The same rules as the connection timeline: English only, and never
//  hosts, session ids, titles or server error text.
//

import Foundation
import OSLog

private let callTraceLogger = Logger(subsystem: "com.milim.relay", category: "HermesCalls")

@MainActor
final class HermesCallTrace {
    static let shared = HermesCallTrace()

    private(set) var timeline: ConnectionTimeline?

    /// A VoIP push arrived: a new trace.
    func begin(_ label: String) {
        timeline = ConnectionTimeline(trigger: "call from Hermes")
        note(label)
    }

    /// A step. What happens long after the call is ordinary use: the trace
    /// only says that it stopped recording.
    func note(_ label: String, since startedAt: Date? = nil, error: Error? = nil) {
        guard timeline != nil else { return }
        let recorded = timeline?.events.count
        timeline?.record(label, since: startedAt, error: error)
        guard let event = timeline?.events.last, timeline?.events.count != recorded else { return }
        callTraceLogger.notice("Call trace: \(event.label, privacy: .public)")
    }
}
