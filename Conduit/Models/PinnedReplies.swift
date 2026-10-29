//
//  PinnedReplies.swift
//  Conduit
//
//  Replies pinned to the top of their chat (#918), like a pinned message in
//  Telegram or WhatsApp: a long answer worked through point by point stays
//  one tap away however far the chat has moved on. A pin can hold the
//  whole reply or just a passage of it, and can carry a label (#1147).
//  Pins are kept on this device, per profile. Pure list shaping, so
//  finding a pin's row in a transcript and the bar's order stay testable
//  without a view.
//

import Foundation

/// One pinned reply. Saved with enough of the reply to show it in the bar
/// and the overview before its chat is open, and to find it again after
/// the transcript reloads.
struct PinnedReply: Codable, Equatable, Identifiable, Hashable {
    let id: String
    /// The chat it was pinned in: the chat's row id when it had one, else
    /// its durable id, else the open session's id. A pin made before the
    /// chat had a row moves to the row's id once it has one.
    var sessionID: String
    /// Hermes' durable `messages.id`, once the row has one. A reply pinned
    /// as it arrived gets it when the transcript reloads.
    var rowId: Int?
    /// The transcript row's id when it was pinned (or last found).
    var messageID: String
    /// The start of the reply, whitespace folded, for the bar and the list.
    /// It also finds the reply again when neither id matches any more.
    let excerpt: String
    /// The chat's title when it was pinned; the overview shows the current
    /// one while the chat is in the list.
    var chatTitle: String
    let pinnedAt: Date
    /// The text selected when this pin was made, when it pins a passage of
    /// the reply rather than all of it (#1147): what the bar and the list
    /// show, and what the jump finds and flashes in the reply. Nil pins the
    /// whole reply.
    let passage: String?
    /// A short name for the pin, shown in place of its text in the bar and
    /// at the top of its row in the list.
    var label: String?

    /// How much of a reply a pin keeps.
    static let excerptLength = 280
    /// How much of a selection a passage pin keeps.
    static let passageLength = 2000
    /// How long a label can be.
    static let labelLength = 80

    init(
        id: String = UUID().uuidString,
        sessionID: String,
        message: ChatMessage,
        chatTitle: String,
        passage: String? = nil,
        label: String? = nil,
        pinnedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.rowId = message.rowId
        self.messageID = message.id
        self.excerpt = Self.excerpt(of: message.content)
        self.chatTitle = chatTitle
        self.passage = passage.flatMap(Self.normalizedPassage)
        self.label = label.flatMap(Self.normalizedLabel)
        self.pinnedAt = pinnedAt
    }

    /// Whether this pin holds a passage of its reply rather than all of it.
    var isPassage: Bool { passage != nil }

    /// The pinned text on one line: the passage, else the reply's start.
    var shownText: String {
        passage.map { Self.excerpt(of: $0) } ?? excerpt
    }

    /// What the bar shows for the pin: its label, else its text.
    var title: String { label ?? shownText }

    /// Whether `text` is this pin's passage, whitespace aside.
    func holdsPassage(_ text: String) -> Bool {
        guard let passage, let other = Self.normalizedPassage(text) else { return false }
        return Self.folded(passage, limit: .max) == Self.folded(other, limit: .max)
    }

    /// A selection as a passage pin keeps it: trimmed and cut to
    /// `passageLength`; nil when nothing but whitespace was selected.
    static func normalizedPassage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(passageLength))
    }

    /// A label on one line, cut to `labelLength`; nil when blank, which
    /// clears it.
    static func normalizedLabel(_ text: String) -> String? {
        let label = folded(text, limit: labelLength)
        return label.isEmpty ? nil : label
    }

    /// The reply's text on one line, cut to `excerptLength`. Reads only as
    /// much of a long reply as the excerpt needs.
    static func excerpt(of content: String) -> String {
        folded(content, limit: excerptLength)
    }

    /// `content` on one line, whitespace runs folded to a space, cut to
    /// `limit` characters.
    static func folded(_ content: String, limit: Int) -> String {
        var folded = ""
        var count = 0
        var pendingSpace = false
        for character in content {
            if character.isWhitespace {
                pendingSpace = count > 0
                continue
            }
            if pendingSpace {
                folded.append(" ")
                count += 1
                pendingSpace = false
                if count >= limit { break }
            }
            folded.append(character)
            count += 1
            if count >= limit { break }
        }
        return folded
    }

    /// Whether `message` is the reply this pin was made on, by id alone.
    func isExactly(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        if let rowId, let other = message.rowId { return rowId == other }
        return message.id == messageID
    }

    /// Whether `message` reads as this pin's reply: the fallback for a reply
    /// pinned before it had a durable id, which a reload gave a new row id.
    func matchesText(of message: ChatMessage) -> Bool {
        guard rowId == nil, message.role == .assistant, !excerpt.isEmpty else { return false }
        return Self.excerpt(of: message.content) == excerpt
    }
}

enum PinnedReplies {
    /// The transcript row each pin shows, by pin id; a pin whose reply
    /// isn't loaded (an older part of a long chat) has none. Whole-reply
    /// pins are resolved in one pass so no two of them land on the same
    /// reply: ids claim their rows first, then a pin matched by its text
    /// takes the latest reply reading that way that no other pin has, the
    /// newest pin first. Passage pins share their reply with any other pin
    /// (#1147), so each finds its own.
    static func resolved(_ pins: [PinnedReply], in messages: [ChatMessage]) -> [String: String] {
        guard !pins.isEmpty else { return [:] }
        var result = resolvedWholeReplies(pins.filter { !$0.isPassage }, in: messages)
        for pin in pins where pin.isPassage {
            let exact: ChatMessage?
            if let rowId = pin.rowId {
                exact = messages.first { $0.role == .assistant && $0.rowId == rowId }
            } else {
                exact = messages.first { pin.isExactly($0) }
            }
            // Replies opening alike: the latest one holding the passage,
            // else the latest (the reply's source can mark up the text).
            let byText = exact == nil ? messages.filter { pin.matchesText(of: $0) } : []
            let holding = byText.last { message in
                pin.passage.map { !PinnedPassageMatch.ranges(of: $0, in: message.content).isEmpty } ?? false
            }
            if let match = exact ?? holding ?? byText.last {
                result[pin.id] = match.id
            }
        }
        return result
    }

    private static func resolvedWholeReplies(_ pins: [PinnedReply], in messages: [ChatMessage]) -> [String: String] {
        guard !pins.isEmpty else { return [:] }
        var result: [String: String] = [:]
        var claimed = Set<String>()
        for pin in pins where result[pin.id] == nil {
            // A durable id is exact: a reply with the same opening words
            // never wins over it.
            let exact: ChatMessage?
            if let rowId = pin.rowId {
                exact = messages.first { $0.role == .assistant && $0.rowId == rowId }
            } else {
                exact = messages.first { pin.isExactly($0) }
            }
            if let exact, !claimed.contains(exact.id) {
                result[pin.id] = exact.id
                claimed.insert(exact.id)
            }
        }
        // Replies that open the same way: a pin without a durable id was
        // made recently, so the latest reply is the likelier, and the
        // newest pin gets it.
        let byText = pins.enumerated()
            .filter { result[$0.element.id] == nil && $0.element.rowId == nil }
            .sorted { lhs, rhs in
                lhs.element.pinnedAt == rhs.element.pinnedAt
                    ? lhs.offset > rhs.offset
                    : lhs.element.pinnedAt > rhs.element.pinnedAt
            }
            .map(\.element)
        for pin in byText {
            guard let match = messages.last(where: { !claimed.contains($0.id) && pin.matchesText(of: $0) })
            else { continue }
            result[pin.id] = match.id
            claimed.insert(match.id)
        }
        return result
    }

    /// The transcript row `pin` shows among `pins` (the chat's other pins,
    /// which may already have claimed a reply reading the same), or nil
    /// when the reply isn't loaded.
    static func messageID(
        for pin: PinnedReply,
        in messages: [ChatMessage],
        among pins: [PinnedReply] = []
    ) -> String? {
        let all = pins.contains(where: { $0.id == pin.id }) ? pins : pins + [pin]
        return resolved(all, in: messages)[pin.id]
    }

    /// The rows of `messages` pinned whole; a passage pin leaves its reply
    /// free to be pinned whole as well.
    static func pinnedMessageIDs(_ pins: [PinnedReply], in messages: [ChatMessage]) -> Set<String> {
        Set(resolvedWholeReplies(pins.filter { !$0.isPassage }, in: messages).values)
    }

    /// The whole-reply pin that is `message` in this transcript, if any:
    /// the pin whose reply resolves to it, so a second reply reading like a
    /// pinned one is not taken for it.
    static func pin(for message: ChatMessage, in pins: [PinnedReply], messages: [ChatMessage]) -> PinnedReply? {
        let whole = pins.filter { !$0.isPassage }
        let ids = resolvedWholeReplies(whole, in: messages)
        return whole.first { ids[$0.id] == message.id }
    }

    /// The pin holding `passage` of `message`, if it has been pinned.
    static func pin(
        forPassage passage: String,
        of message: ChatMessage,
        in pins: [PinnedReply],
        messages: [ChatMessage]
    ) -> PinnedReply? {
        let candidates = pins.filter { $0.holdsPassage(passage) }
        guard !candidates.isEmpty else { return nil }
        let ids = resolved(candidates, in: messages)
        return candidates.first { ids[$0.id] == message.id }
    }

    /// The pins with the ids their rows have now: a reply pinned as it
    /// arrived takes its durable id once the transcript has it, so a later
    /// reload finds it exactly. Nil when nothing changed.
    static func refreshed(_ pins: [PinnedReply], in messages: [ChatMessage]) -> [PinnedReply]? {
        let ids = resolved(pins, in: messages)
        guard !ids.isEmpty else { return nil }
        var byID: [String: ChatMessage] = [:]
        for message in messages { byID[message.id] = message }
        var changed = false
        let refreshed = pins.map { pin -> PinnedReply in
            guard let id = ids[pin.id], let message = byID[id] else { return pin }
            var updated = pin
            if updated.rowId == nil, let rowId = message.rowId { updated.rowId = rowId }
            if updated.messageID != message.id { updated.messageID = message.id }
            if updated != pin { changed = true }
            return updated
        }
        return changed ? refreshed : nil
    }

    /// The bar's order, oldest first, as the replies sit in the chat. A pin
    /// whose reply isn't loaded is further back, so it comes first; those
    /// keep the order they were pinned in.
    static func barOrder(_ pins: [PinnedReply], in messages: [ChatMessage]) -> [PinnedReply] {
        guard pins.count > 1 else { return pins }
        var position: [String: Int] = [:]
        for (index, message) in messages.enumerated() { position[message.id] = index }
        let ids = resolved(pins, in: messages)
        let placed = pins.enumerated().map { offset, pin -> (pin: PinnedReply, index: Int?, offset: Int) in
            (pin, ids[pin.id].flatMap { position[$0] }, offset)
        }
        func pinnedEarlier(_ lhs: (pin: PinnedReply, index: Int?, offset: Int), _ rhs: (pin: PinnedReply, index: Int?, offset: Int)) -> Bool {
            lhs.pin.pinnedAt == rhs.pin.pinnedAt
                ? lhs.offset < rhs.offset
                : lhs.pin.pinnedAt < rhs.pin.pinnedAt
        }
        return placed.sorted { lhs, rhs in
            switch (lhs.index, rhs.index) {
            case let (l?, r?):
                if l != r { return l < r }
                // Pins on one reply: the whole reply, then its passages
                // in the order they were pinned.
                if lhs.pin.isPassage != rhs.pin.isPassage { return !lhs.pin.isPassage }
                return pinnedEarlier(lhs, rhs)
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil): return pinnedEarlier(lhs, rhs)
            }
        }.map(\.pin)
    }

    /// The bar's next pin after jumping to `current` (an index into the bar's
    /// order): the one before it in the chat, back to the latest after the
    /// first, as Telegram cycles.
    static func nextBarIndex(after current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(current, 0), count - 1)
        return clamped == 0 ? count - 1 : clamped - 1
    }

    /// The overview: a section per chat, the chat with the latest pin
    /// first, each chat's pins newest first. A section holding any of
    /// `firstPins` (the open chat's) comes before the rest (#1267).
    static func overview(
        _ pins: [PinnedReply],
        firstPins: Set<String> = []
    ) -> [(sessionID: String, pins: [PinnedReply])] {
        var bySession: [String: [PinnedReply]] = [:]
        var order: [String] = []
        for pin in pins {
            if bySession[pin.sessionID] == nil { order.append(pin.sessionID) }
            bySession[pin.sessionID, default: []].append(pin)
        }
        let sections = order.map { id in
            (sessionID: id, pins: bySession[id, default: []].sorted { $0.pinnedAt > $1.pinnedAt })
        }
        return sections.sorted { lhs, rhs in
            let lhsFirst = lhs.pins.contains { firstPins.contains($0.id) }
            let rhsFirst = rhs.pins.contains { firstPins.contains($0.id) }
            if lhsFirst != rhsFirst { return lhsFirst }
            return (lhs.pins.first?.pinnedAt ?? .distantPast) > (rhs.pins.first?.pinnedAt ?? .distantPast)
        }
    }
}

/// Where a pinned passage sits in a block of a reply's shown text (#1147),
/// so the jump can flash it. Whitespace is folded on both sides: a
/// selection's line breaks and the text's need not agree.
enum PinnedPassageMatch {
    /// Lines shorter than this are too common to flash on their own.
    static let minimumLineLength = 4

    /// The UTF-16 ranges of `text` that show `passage`: all of it when the
    /// block holds all of it, else each of its lines the block holds (a
    /// passage selected across several blocks shows a part in each).
    static func ranges(of passage: String, in text: String) -> [NSRange] {
        let haystack = Folded(text)
        guard !haystack.characters.isEmpty else { return [] }
        let whole = PinnedReply.folded(passage, limit: .max)
        guard !whole.isEmpty else { return [] }
        if let range = haystack.range(of: whole) { return [range] }
        var ranges: [NSRange] = []
        var seen = Set<String>()
        for line in passage.split(whereSeparator: \.isNewline) {
            let folded = PinnedReply.folded(String(line), limit: .max)
            guard folded.count >= minimumLineLength, seen.insert(folded).inserted,
                  let range = haystack.range(of: folded) else { continue }
            ranges.append(range)
        }
        return ranges.sorted { $0.location < $1.location }
    }

    /// `text` with whitespace folded as `PinnedReply.folded` does, and
    /// where each kept character sits in the original's UTF-16.
    private struct Folded {
        var characters: [Character] = []
        var starts: [Int] = []
        var ends: [Int] = []

        init(_ text: String) {
            var offset = 0
            var pendingSpace: (start: Int, end: Int)?
            for character in text {
                let length = character.utf16.count
                defer { offset += length }
                if character.isWhitespace {
                    guard !characters.isEmpty else { continue }
                    pendingSpace = (pendingSpace?.start ?? offset, offset + length)
                    continue
                }
                if let space = pendingSpace {
                    characters.append(" ")
                    starts.append(space.start)
                    ends.append(space.end)
                    pendingSpace = nil
                }
                characters.append(character)
                starts.append(offset)
                ends.append(offset + length)
            }
        }

        func range(of needle: String) -> NSRange? {
            let target = Array(needle)
            guard !target.isEmpty, target.count <= characters.count else { return nil }
            var index = 0
            while index + target.count <= characters.count {
                if characters[index] == target[0],
                   characters[index..<(index + target.count)].elementsEqual(target) {
                    let start = starts[index]
                    return NSRange(location: start, length: ends[index + target.count - 1] - start)
                }
                index += 1
            }
            return nil
        }
    }
}

/// A pinned reply to scroll to once its chat's transcript has it.
struct PinnedReplyReveal: Equatable {
    let pin: PinnedReply
    /// The chat being opened for it; nil when it's the open chat.
    let opening: String?
    let expires: Date

    init(pin: PinnedReply, opening: String? = nil, now: Date = Date()) {
        self.pin = pin
        self.opening = opening
        // As ArtifactReveal: a chat that takes long to open doesn't jump
        // later, out of nowhere.
        self.expires = now.addingTimeInterval(20)
    }
}
