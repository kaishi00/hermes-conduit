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

    /// About the most of what the user said that goes with one request
    /// (the line breaks between them aren't counted): the
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
        guard !theirs.isEmpty, !carries(request, words: theirs) else { return request }
        let whole = request + marker + lines.joined(separator: "\n")
        if let maxBytes, whole.utf8.count > maxBytes { return request }
        return whole
    }

    /// Whether `request` already carries the user's `words` (`comparable`
    /// already): as whole words, or, for Chinese and Japanese, written
    /// without spaces, as their letters and numbers anywhere in it, with
    /// punctuation on either side left out (desktop#529). A short answer
    /// ("不", "好的") sits inside too many longer words to be found that way,
    /// so under `unspacedMinimum` letters it must stand as a run of its own.
    static func carries(_ request: String, words: String) -> Bool {
        if words.unicodeScalars.contains(where: isUnspaced) {
            let bare = { (text: String) in
                String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
            }
            let theirs = bare(words)
            if theirs.unicodeScalars.count >= unspacedMinimum { return bare(request).contains(theirs) }
        }
        return (" " + WatchBridgeDelegation.comparable(request) + " ").contains(" " + words + " ")
    }

    /// Letters an unspaced answer needs before it's looked for inside the request's words.
    static let unspacedMinimum = 3

    /// A Han, Hiragana or Katakana letter: scripts written without spaces.
    private static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x2FA1F: return true
        default: return false
        }
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

    /// Whether `watchArguments` gets `said` to Hermes with this call:
    /// under the marker, or in the model's own request already.
    static func watchCarries(name: String, arguments: [String: String], said: String) -> Bool {
        let key: String
        switch name {
        case WatchJobAnswer.startJob: key = "instructions"
        case WatchJobAnswer.interruptJob: key = "message"
        default: return false
        }
        guard let request = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty else { return false }
        return adding([said], to: request, maxBytes: watchMaxBytes) != request || adding([said], to: request) == request
    }

    /// The request as the model wrote it, without the user's words:
    /// routing reads only this.
    static func modelWords(of request: String) -> String {
        request.range(of: marker).map { String(request[..<$0.lowerBound]) } ?? request
    }
}
