import Foundation

/// Hermes' silence markers: a reply that is only `[SILENT]` (or `NO_REPLY`,
/// and the rest of `LIVE_GATEWAY_SILENT_MARKERS`) is the model saying it has
/// nothing to tell the user, as a Bot Chat's work update often is. The same
/// rule as Hermes' `gateway/response_filters.py` (0.23): case and inner
/// spaces don't matter, stray punctuation at the edges (`*[SILENT]*`,
/// `.NO_REPLY`) doesn't either, and a marker on its own last line after a
/// real reply is dropped from it. A marker inside a sentence is prose.
enum SilenceMarkers {
    static let markers: Set<String> = [
        "[SILENT]", "SILENT", "NO_REPLY", "NO REPLY", "[静默]", "静默", "[沉默]", "沉默"
    ]

    /// Longer than any marker could be, even with stray punctuation.
    private static let lengthCap = 64

    /// Whether `text` is exactly a silence marker (`is_intentional_silence_response`).
    static func isMarker(_ text: String) -> Bool {
        candidates(text).contains { markers.contains($0) }
    }

    /// `text` without a marker that closes a real reply on its own line
    /// (`strip_trailing_silence_marker`). A bare marker comes back as it is:
    /// `isMarker` decides that one.
    static func strippingTrailingMarker(_ text: String) -> String {
        let (head, tail) = splitTrailingLine(text)
        return !trimmed(head).isEmpty && isMarker(tail) ? head : text
    }

    /// What a finished reply shows: nothing for a bare marker, else the
    /// reply without a closing one.
    static func shown(_ text: String) -> String {
        isMarker(text) ? "" : strippingTrailingMarker(text)
    }

    /// Whether streamed `text` could still become a marker (`is_partial_silence_marker`).
    static func couldBecomeMarker(_ text: String) -> Bool {
        candidates(text).contains { candidate in
            !candidate.isEmpty && markers.contains { $0.hasPrefix(candidate) }
        }
    }

    /// Whether a streamed reply's last line could still become a closing
    /// marker (`ends_with_partial_silence_marker`).
    static func endsWithPartialMarker(_ text: String) -> Bool {
        let (head, tail) = splitTrailingLine(text)
        return !trimmed(head).isEmpty && couldBecomeMarker(tail)
    }

    // MARK: - Hermes' helpers

    private static func candidates(_ text: String) -> [String] {
        let stripped = trimmed(text)
        let length = stripped.unicodeScalars.count
        guard length > 0, length <= lengthCap else { return [] }
        let depunctuated = trimmed(strippingEdgePunctuation(stripped))
        let forms = depunctuated == stripped ? [stripped] : [stripped, depunctuated]
        return forms.map(canonical)
    }

    private static func canonical(_ text: String) -> String {
        text.uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Square brackets stay, so a malformed `[SILENT` can't become `SILENT`.
    private static func isEdgePunctuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar != "[" && scalar != "]" && CharacterSet.punctuationCharacters.contains(scalar)
    }

    private static func strippingEdgePunctuation(_ text: String) -> String {
        var scalars = text.unicodeScalars[...]
        while let first = scalars.first, isEdgePunctuation(first) { scalars = scalars.dropFirst() }
        while let last = scalars.last, isEdgePunctuation(last) { scalars = scalars.dropLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmingTrailing(_ text: String) -> String {
        var scalars = text.unicodeScalars[...]
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars = scalars.dropLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// `(head, last line)` with trailing blank space ignored; head is "" for
    /// one line. Head is always a prefix of `text`.
    static func splitTrailingLine(_ text: String) -> (head: String, tail: String) {
        let scalars = Array(trimmingTrailing(text).unicodeScalars)
        guard let newline = scalars.lastIndex(of: "\n") else {
            return ("", String(String.UnicodeScalarView(scalars)))
        }
        let head = String(String.UnicodeScalarView(scalars[..<newline]))
        let tail = String(String.UnicodeScalarView(scalars[(newline + 1)...]))
        return (trimmingTrailing(head), tail)
    }
}

/// Hermes' `SilenceMarkerStreamHold`, per chat, for every reply stream the
/// app reads. Hermes holds a Bot Chat's deltas on its own dashboard, but the
/// session authority (gateway-hosted chats, Hermes 0.23) streams them as the
/// model writes them and ends the turn with an empty reply, so a bare
/// `[SILENT]` streamed into the chat and stayed there as the reply (issue
/// 2700). Held here, a marker is never shown, spoken or counted, on any
/// surface, and text that turns out not to be one arrives in full.
struct SilenceMarkerStreamFilter {
    private struct Hold {
        var buffer = ""
        /// Scalars of `buffer` already passed on.
        var sent = 0

        mutating func feed(_ delta: String) -> String {
            buffer += delta
            if SilenceMarkers.couldBecomeMarker(buffer) { return "" }
            if SilenceMarkers.endsWithPartialMarker(buffer) {
                return release(upTo: SilenceMarkers.splitTrailingLine(buffer).head.unicodeScalars.count)
            }
            return release(upTo: buffer.unicodeScalars.count)
        }

        mutating func finish() -> String {
            if SilenceMarkers.isMarker(buffer) { return "" }
            return release(upTo: SilenceMarkers.strippingTrailingMarker(buffer).unicodeScalars.count)
        }

        private mutating func release(upTo end: Int) -> String {
            guard end > sent else { return "" }
            let scalars = buffer.unicodeScalars
            let from = scalars.index(scalars.startIndex, offsetBy: sent)
            let to = scalars.index(scalars.startIndex, offsetBy: end)
            sent = end
            return String(String.UnicodeScalarView(scalars[from..<to]))
        }
    }

    private var holds: [String: Hold] = [:]

    /// The events to deliver for `event`: none for a held delta, the held
    /// rest ahead of whatever ends a segment, and a turn's interim or final
    /// text without a marker.
    mutating func filter(_ event: StreamEvent) -> [StreamEvent] {
        switch event {
        case .messageStart(let sessionId):
            holds[sessionId] = nil
            return [event]
        case .messageDelta(let sessionId, let text):
            var hold = holds[sessionId] ?? Hold()
            let shown = hold.feed(text)
            holds[sessionId] = hold
            return shown.isEmpty ? [] : [.messageDelta(sessionId: sessionId, text: shown)]
        case .messageInterim(let sessionId, let text, let alreadyStreamed):
            // The interim carries the segment's whole text: what was held
            // of it isn't needed.
            holds[sessionId] = nil
            let shown = SilenceMarkers.shown(text)
            guard !SilenceMarkers.trimmed(shown).isEmpty else { return [] }
            return [.messageInterim(sessionId: sessionId, text: shown, alreadyStreamed: alreadyStreamed)]
        case .messageComplete(let sessionId, let messageId, let content, let reasoning, let alreadyShown):
            let rest = endSegment(sessionId)
            let completed = StreamEvent.messageComplete(
                sessionId: sessionId, messageId: messageId, content: content.map(SilenceMarkers.shown),
                reasoning: reasoning, alreadyShown: alreadyShown
            )
            return rest + [completed]
        case .toolStart(let sessionId, _, _, _),
             .messageError(let sessionId, _),
             .messageInterrupted(let sessionId):
            return endSegment(sessionId) + [event]
        default:
            return [event]
        }
    }

    /// Releases what a segment held that never became a marker.
    private mutating func endSegment(_ sessionId: String) -> [StreamEvent] {
        guard var hold = holds.removeValue(forKey: sessionId) else { return [] }
        let rest = hold.finish()
        return rest.isEmpty ? [] : [.messageDelta(sessionId: sessionId, text: rest)]
    }

    mutating func reset() {
        holds = [:]
    }
}
