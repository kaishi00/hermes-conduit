import Foundation

/// The user's own words, sent with the request a live voice model wrote
/// for Hermes (issue 3236; Eric, 2026-11-25). A model that calls a tool
/// writes the request itself, and can turn a remark into steps or a
/// go-ahead nobody said: Hermes gets what the user said beside it, marked
/// as theirs, on the phone and the Watch alike. GPT-Live's delegations
/// carry them in their recent conversation block already
/// (WatchBridgeDelegation.contextMarker). Not UI copy.
enum VoiceRequestWords {
    /// Starts the user's words, after the model's request. Hermes reads
    /// it, and Conduit for desktop writes the same line
    /// (desktop/src/renderer/src/state/requestWords.ts).
    static let marker = "\n\n[The user's own words on the call since their last request, as transcribed. The request above is the voice model's wording of them: where it adds steps, details or a go-ahead the user didn't say, go by the user's words.]\n"

    /// The most of what the user said that goes with one request: the
    /// newest things they said, whole, that fit in it (an older one that
    /// doesn't fit is left out, and the newest alone is cut to its end).
    static let maxCharacters = 1_000

    /// `request` with what the user `said` since their last one under the
    /// marker, a line for each thing they said. The request alone when
    /// they said nothing, when it already carries their words, when it is
    /// their words (a model that passed them on as they were), or when the
    /// two wouldn't fit in `maxBytes` (a Watch job's limit on the host).
    static func adding(_ said: [String], to request: String, maxBytes: Int? = nil) -> String {
        guard !request.contains(marker) else { return request }
        var lines: [String] = []
        var count = 0
        for line in said.reversed() {
            let words = line.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { continue }
            guard count + words.count <= maxCharacters else {
                // The newest thing alone is too long: its end is what the
                // request followed.
                if lines.isEmpty { lines.append("…" + String(words.suffix(maxCharacters))) }
                break
            }
            lines.insert(words, at: 0)
            count += words.count
        }
        guard !lines.isEmpty else { return request }
        let theirs = WatchBridgeDelegation.comparable(lines.joined(separator: " "))
        guard !theirs.isEmpty,
              !(" " + WatchBridgeDelegation.comparable(request) + " ").contains(" " + theirs + " ") else { return request }
        let whole = request + marker + lines.joined(separator: "\n")
        if let maxBytes, whole.utf8.count > maxBytes { return request }
        return whole
    }

    /// A Watch job's request may be 3,000 bytes as JSON on the host
    /// (WATCH_JOB_MAX_INSTRUCTION_BYTES): the user's words go with it only
    /// when both fit well inside that.
    static let watchMaxBytes = 2_400

    /// A Watch call's tool call with what the user said for it: the
    /// Watch has the transcript, so its start_job and interrupt_job
    /// carry them to the iPhone's bridge and to the relay alike.
    static func watchArguments(name: String, arguments: [String: String], said: String?) -> [String: String] {
        let key: String
        switch name {
        case WatchJobAnswer.startJob: key = "instructions"
        case WatchJobAnswer.interruptJob: key = "message"
        default: return arguments
        }
        guard let said, let request = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty else { return arguments }
        var carried = arguments
        carried[key] = adding([said], to: request, maxBytes: watchMaxBytes)
        return carried
    }

    /// The request as the model wrote it, without the user's words:
    /// routing reads only this.
    static func modelWords(of request: String) -> String {
        request.range(of: marker).map { String(request[..<$0.lowerBound]) } ?? request
    }
}
