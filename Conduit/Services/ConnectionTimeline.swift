//
//  ConnectionTimeline.swift
//  Conduit
//
//  Where the last cold launch, return to the app, or reconnect spent its
//  time (#417). Gateway Diagnostics shows it with a Copy button, so a slow
//  start on someone else's network arrives as numbers instead of a feeling.
//
//  The lines are a diagnostic log, English only like the gateway log lines
//  next to them, and they never carry hosts, session ids, titles or server
//  error text: people paste them into public issues.
//

import Foundation

struct ConnectionTimeline: Equatable {
    struct Event: Equatable {
        /// Seconds since the timeline began.
        let offset: TimeInterval
        let label: String
    }

    /// Steps after this window belong to ordinary use, not to getting ready.
    static let recordingWindow: TimeInterval = 120
    static let maximumEvents = 60

    let trigger: String
    let startedAt: Date
    private(set) var events: [Event] = []
    /// Steps that arrived after the window closed or the event cap was hit.
    private(set) var droppedEvents = 0

    init(trigger: String, startedAt: Date = Date()) {
        self.trigger = trigger
        self.startedAt = startedAt
    }

    func isRecording(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(startedAt) <= Self.recordingWindow
    }

    /// Records a step. With `since`, the label gains the step's own duration;
    /// with `error`, it reads as a failure after that long.
    mutating func record(
        _ label: String,
        since stepStartedAt: Date? = nil,
        error: Error? = nil,
        at date: Date = Date()
    ) {
        guard isRecording(at: date), events.count < Self.maximumEvents else {
            droppedEvents += 1
            return
        }
        var text = label
        if let error {
            let duration = stepStartedAt.map { " after \(Self.seconds(date.timeIntervalSince($0)))" } ?? ""
            text += " failed\(duration): \(Self.summary(of: error))"
        } else if let stepStartedAt {
            text += " (\(Self.seconds(date.timeIntervalSince(stepStartedAt))))"
        }
        events.append(Event(offset: max(0, date.timeIntervalSince(startedAt)), label: text))
    }

    /// The copyable report: one header line, then one line per step with its
    /// offset from the start.
    var report: String {
        var lines = ["Conduit connection timeline: \(trigger)"]
        lines += events.map { event -> String in
            let offset = Self.seconds(event.offset)
            let padding = String(repeating: " ", count: max(0, 9 - offset.count))
            return "+\(offset)\(padding)\(event.label)"
        }
        if droppedEvents > 0 {
            lines.append("(\(droppedEvents) later steps not recorded)")
        }
        return lines.joined(separator: "\n")
    }

    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f s", locale: Locale(identifier: "en_US_POSIX"), max(0, interval))
    }

    /// A short, host-free description of a failure for the report.
    static func summary(of error: Error) -> String {
        switch error {
        case let error as HermesError:
            switch error {
            case .invalidUrl: return "invalid address"
            case .invalidResponse: return "unreadable reply"
            case .notConnected: return "not connected"
            case .connectionClosed: return "connection closed"
            case .timeout: return "timed out"
            case .steerRejected: return "steer rejected"
            }
        case let error as DashboardTicketBridgeError:
            switch error {
            case .notReady: return "dashboard page not ready"
            case .signInRequired: return "sign-in required"
            case .requestFailed: return "request failed"
            case .http(let status, _): return "HTTP \(status)"
            case .oversizedResponse: return "response too large"
            }
        case let error as RpcError:
            return error.code.map { "gateway error \($0)" } ?? "gateway error"
        case is CancellationError:
            return "cancelled"
        case let error as URLError:
            return "network error \(error.code.rawValue)"
        default:
            let nsError = error as NSError
            return "\(nsError.domain) \(nsError.code)"
        }
    }
}
