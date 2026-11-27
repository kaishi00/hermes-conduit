//
//  ReplySpeeds.swift
//  Conduit
//
//  How fast each reply of the open chat was written, in tokens per second,
//  for the reply row while Settings > Chat > Show reply speed is on. The
//  notifier plugin measures it from Hermes' model calls (the provider's own
//  output tokens over the time the model spent writing, each call timed from
//  its first streamed token) and ties each turn to the reply it ended on
//  (`GET /sessions/reply-speeds`, plugin 0.204.0+). Hermes' own figure, the
//  one its desktop status bar shows, averages the chat's last ten calls with
//  the wait for the first token in, so Conduit doesn't use it.
//

import Foundation

struct ReplySpeeds: Equatable {
    static let capability = "reply-speeds"
    static let path = "/api/plugins/conduit_push/sessions/reply-speeds"
    /// Settings > Chat > Show reply speed, kept on this device; off by default.
    static let preferenceKey = "conduit.chat.showReplySpeed"

    /// The open chat it was read for (its id on screen).
    var chatID: String
    /// Each saved reply's speed, by Hermes' message id.
    var byRow: [Int: Double] = [:]
    /// The newest turn's speed while its reply isn't saved yet: the reply
    /// the chat still draws from the stream.
    var unsaved: Double?

    /// The route for one chat, without its profile, which the request adds
    /// (`DashboardPath.withProfile`).
    static func route(sessionID: String) -> String? {
        guard let id = DashboardPath.encodedQueryComponent(sessionID) else { return nil }
        return "\(path)?session_id=\(id)"
    }

    init(chatID: String, byRow: [Int: Double] = [:], unsaved: Double? = nil) {
        self.chatID = chatID
        self.byRow = byRow
        self.unsaved = unsaved
    }

    init(chatID: String, response: [String: Any]) {
        self.chatID = chatID
        let replies = (response["replies"] as? [[String: Any]]) ?? []
        for (index, reply) in replies.enumerated() {
            guard let rate = (reply["tokens_per_s"] as? NSNumber)?.doubleValue, rate.isFinite, rate > 0 else { continue }
            if let row = Self.rowID(reply["row_id"]) {
                byRow[row] = rate
            } else if index == replies.count - 1 {
                unsaved = rate
            }
        }
    }

    /// Hermes' message id: a whole positive number, never a Bool.
    private static func rowID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let row = Int(exactly: number.doubleValue), row > 0 else { return nil }
        return row
    }

    /// "42 tok/s"; one decimal under 10 ("4.5 tok/s").
    static func label(_ rate: Double) -> String {
        AppLocalization.string("\(number(rate)) tok/s", table: .chat)
    }

    /// What VoiceOver says: "Written at 42 tokens per second".
    static func spokenLabel(_ rate: Double) -> String {
        AppLocalization.string("Written at \(number(rate)) tokens per second", table: .chat)
    }

    static func number(_ rate: Double) -> String {
        rate < 10 ? rate.formatted(.number.precision(.fractionLength(1))) : rate.formatted(.number.precision(.fractionLength(0)))
    }
}
